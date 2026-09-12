// Package catalog merges the registry source with discovery cache results into
// the single canonical artifact the server publishes.
//
// The merge rule that matters most: an overlay supplements metadata, it never
// gates model visibility. A model returned by an upstream listing but absent
// from every overlay is still published, marked MetadataIncomplete.
package catalog

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"time"

	"lingxi/registry/internal/discovery"
	"lingxi/registry/internal/model"
	"lingxi/registry/internal/registry"
)

// Source labels for ModelRecord.Source.
const (
	SourceUpstreamDiscovery = "upstream-discovery"
	SourceStaticMetadata    = "static-metadata"
)

// Builder produces catalog snapshots from a registry plus discovery state.
type Builder struct {
	registry *registry.Registry
	now      func() time.Time
}

// NewBuilder creates a Builder over a loaded registry.
func NewBuilder(reg *registry.Registry) *Builder {
	return &Builder{
		registry: reg,
		now:      func() time.Time { return time.Now().UTC() },
	}
}

// Build assembles the catalog.
//
// Discovery records are keyed by product ID; a product with no public
// discovery profile (or no successful run yet) contributes no model records —
// its availability is resolved on the client against the user's own account,
// which the public registry deliberately cannot see.
func (b *Builder) Build(cache map[string]model.DiscoveryCacheRecord) (*model.Catalog, error) {
	now := b.now()

	vendors := append([]model.Vendor{}, b.registry.Vendors...)
	sort.Slice(vendors, func(i, j int) bool { return vendors[i].ID < vendors[j].ID })

	products := append([]model.ProviderProduct{}, b.registry.Products...)
	sort.Slice(products, func(i, j int) bool { return products[i].ID < products[j].ID })

	var (
		catalogProducts []model.CatalogProduct
		modelRecords    []model.ModelRecord
		summaries       = map[string]model.CacheSummary{}
	)

	for _, product := range products {
		overlay, _ := b.registry.Overlay(product.ID)
		rec, hasCache := cache[product.ID]
		var profile *model.DiscoveryProfile
		if p, ok := b.registry.Profile(product.DiscoveryProfileID); ok {
			profile = &p
		}

		// Every model the upstream listing returned is published. The overlay
		// decides how much we know about it, not whether it exists.
		discovered := rec.Models
		if !hasCache {
			discovered = nil
		}

		records := make([]model.ModelRecord, 0, len(discovered))
		modelIDs := make([]string, 0, len(discovered))
		for _, d := range discovered {
			records = append(records, b.mergeRecord(product, overlay, d, profile))
			modelIDs = append(modelIDs, d.ID)
		}
		sort.Slice(modelIDs, func(i, j int) bool { return modelIDs[i] < modelIDs[j] })

		// Models the overlay knows about but which no public listing returned
		// are still published as static metadata. This is what lets a product
		// the registry understands be described even when its listing is
		// account-scoped, without the overlay ever acting as an allowlist.
		//
		// An overlay entry that a discovered model already resolved to — by ID
		// or through one of its aliases — is skipped, so a model can never be
		// published twice under two different identifiers.
		for id, ov := range overlay.Models {
			if consumedByDiscovery(overlay, id, discovered) {
				continue
			}
			records = append(records, b.staticRecord(product, id, ov))
			modelIDs = append(modelIDs, id)
		}
		sort.Strings(modelIDs)

		catalogProducts = append(catalogProducts, model.CatalogProduct{
			ProviderProduct:  product,
			ModelIDs:         modelIDs,
			DiscoveryProfile: profile,
		})
		modelRecords = append(modelRecords, records...)

		if hasCache {
			discoveredAt := rec.FetchedAt
			summaries[product.ID] = model.CacheSummary{
				Status:     discovery.StatusFor(rec, now),
				FetchedAt:  discoveredAt,
				ExpiresAt:  rec.ExpiresAt,
				Source:     rec.Source,
				ModelCount: len(rec.Models),
				LastError:  rec.LastError,
			}
		}
	}

	sort.Slice(modelRecords, func(i, j int) bool {
		if modelRecords[i].ProductID != modelRecords[j].ProductID {
			return modelRecords[i].ProductID < modelRecords[j].ProductID
		}
		return modelRecords[i].ID < modelRecords[j].ID
	})

	cat := &model.Catalog{
		Metadata: model.CatalogMetadata{
			SchemaVersion:  model.SchemaVersion,
			GeneratedAt:    now,
			SourceRevision: b.registry.SourceRevision,
		},
		Vendors:  vendors,
		Products: catalogProducts,
		Models:   modelRecords,
		Cache:    summaries,
	}

	digest, revision, err := fingerprint(cat)
	if err != nil {
		return nil, err
	}
	cat.Metadata.Sha256 = digest
	cat.Metadata.CatalogRevision = revision
	return cat, nil
}

// mergeRecord combines an upstream-discovered model with whatever the overlay
// knows about it. Absence from the overlay yields MetadataIncomplete, never
// exclusion.
func (b *Builder) mergeRecord(product model.ProviderProduct, overlay model.ModelOverlay, d model.DiscoveredModel, profile *model.DiscoveryProfile) model.ModelRecord {
	upstreamID := d.UpstreamModelID
	if upstreamID == "" {
		upstreamID = d.ID
	}

	sourceAuth := ""
	sourceAuthKind := ""
	discoveredFrom := ""
	if profile != nil {
		sourceAuthKind = profile.SourceAuthorityKind
		discoveredFrom = profile.URL
		if u, err := url.Parse(profile.URL); err == nil {
			sourceAuth = u.Host
		}
	}
	if sourceAuth == "" && product.Endpoint != "" {
		if u, err := url.Parse(product.Endpoint); err == nil {
			sourceAuth = u.Host
		}
	}
	if sourceAuthKind == "" {
		if product.Type == "cloudAPI" {
			sourceAuthKind = "vendorFirstParty"
		} else if product.Type == "gateway" {
			sourceAuthKind = "aggregator"
		}
	}

	displayNameSource := d.DisplayNameSource
	if displayNameSource == "" {
		displayNameSource = "name"
	}

	rec := model.ModelRecord{
		ID:                  d.ID,
		ProductID:           product.ID,
		DisplayName:         d.DisplayName,
		Status:              model.StatusUnknown,
		Capabilities:        d.Capabilities,
		Source:              SourceUpstreamDiscovery,
		DiscoveredAt:        timePtr(d.DiscoveredAt),
		UpstreamModelID:     upstreamID,
		ListingVerified:     true, // Verified returned by this product's actual listing
		SourceAuthority:     sourceAuth,
		SourceAuthorityKind: sourceAuthKind,
		DiscoveredFrom:      discoveredFrom,
		DisplayNameSource:   displayNameSource,
	}
	if rec.DisplayName == "" {
		rec.DisplayName = d.ID
	}

	ov, known := lookupOverlay(overlay, d.ID)

	if !known {
		rec.MetadataIncomplete = true
		if d.RawStatus != "" {
			rec.Status = d.RawStatus
		}
		return rec
	}

	rec.MetadataIncomplete = false
	rec.Capabilities = mergeCapabilities(d.Capabilities, ov.Capabilities)
	if ov.DisplayName != "" {
		rec.DisplayName = ov.DisplayName
		rec.DisplayNameSource = "overlay"
	}
	rec.Status = ov.Status
	if rec.Status == "" {
		rec.Status = model.StatusActive
	}
	now := b.now()
	rec.VerifiedAt = &now
	return rec
}

// staticRecord publishes an overlay-known model for which no public listing
// exists. It carries registry metadata only and is flagged as static so that
// clients can tell it apart from an upstream-confirmed entry.
func (b *Builder) staticRecord(product model.ProviderProduct, id string, ov model.OverlayRecord) model.ModelRecord {
	name := ov.DisplayName
	displayNameSource := "overlay"
	if name == "" {
		name = id
		displayNameSource = "id"
	}
	status := ov.Status
	if status == "" {
		status = model.StatusUnknown
	}
	return model.ModelRecord{
		ID:                  id,
		ProductID:           product.ID,
		DisplayName:         name,
		Status:              status,
		Capabilities:        ov.Capabilities,
		Source:              SourceStaticMetadata,
		UpstreamModelID:     id,
		ListingVerified:     false, // Static metadata is not listing-verified
		SourceAuthorityKind: "staticOverlay",
		DisplayNameSource:   displayNameSource,
	}
}

// consumedByDiscovery reports whether an overlay entry is already represented
// in the discovered set, either by its own ID or through one of its aliases.
func consumedByDiscovery(overlay model.ModelOverlay, canonicalID string, discovered []model.DiscoveredModel) bool {
	entry, ok := overlay.Models[canonicalID]
	if !ok {
		return false
	}
	for _, d := range discovered {
		if d.ID == canonicalID {
			return true
		}
		for _, alias := range entry.Aliases {
			if alias == d.ID {
				return true
			}
		}
	}
	return false
}

// lookupOverlay finds the overlay record describing an upstream model ID. The
// overlay is keyed by canonical ID and may list alternate IDs as aliases, so a
// dated upstream identifier still resolves to the metadata LingXi maintains.
func lookupOverlay(overlay model.ModelOverlay, modelID string) (model.OverlayRecord, bool) {
	if ov, ok := overlay.Models[modelID]; ok {
		return ov, true
	}
	for _, ov := range overlay.Models {
		for _, alias := range ov.Aliases {
			if alias == modelID {
				return ov, true
			}
		}
	}
	return model.OverlayRecord{}, false
}

// mergeCapabilities layers overlay facts over discovered facts. Only fields the
// overlay actually declares win; everything else stays as discovered.
func mergeCapabilities(base model.Capabilities, overlay model.Capabilities) model.Capabilities {
	out := base
	if overlay.ContextWindow != nil {
		out.ContextWindow = overlay.ContextWindow
	}
	if overlay.MaxOutputTokens != nil {
		out.MaxOutputTokens = overlay.MaxOutputTokens
	}
	if overlay.ToolCalling != nil {
		out.ToolCalling = overlay.ToolCalling
	}
	if overlay.ParallelToolCalling != nil {
		out.ParallelToolCalling = overlay.ParallelToolCalling
	}
	if overlay.Vision != nil {
		out.Vision = overlay.Vision
	}
	if overlay.Reasoning != nil {
		out.Reasoning = overlay.Reasoning
	}
	if overlay.ReasoningMode != "" {
		out.ReasoningMode = overlay.ReasoningMode
	}
	if len(overlay.SupportedReasoningLevel) > 0 {
		out.SupportedReasoningLevel = overlay.SupportedReasoningLevel
	}
	if overlay.StructuredOutput != nil {
		out.StructuredOutput = overlay.StructuredOutput
	}
	if overlay.Cache != nil {
		out.Cache = overlay.Cache
	}
	if len(overlay.Modalities) > 0 {
		out.Modalities = overlay.Modalities
	}
	return out
}

// catalogContent is the portion of a catalog that the digest covers.
//
// Generation time and discovery freshness are deliberately excluded: a refresh
// that finds the same models must not invalidate every client's cache. The
// digest moves when, and only when, the published model directory changes.
type catalogContent struct {
	Vendors  []model.Vendor         `json:"vendors"`
	Products []model.CatalogProduct `json:"products"`
	Models   []model.ModelRecord    `json:"models"`
}

// fingerprint computes the catalog digest over its content, then derives the
// revision from that digest plus the registry source revision so a change in
// either the source or the discovered models moves the revision.
func fingerprint(cat *model.Catalog) (digest string, revision string, err error) {
	data, err := json.Marshal(catalogContent{
		Vendors:  cat.Vendors,
		Products: cat.Products,
		Models:   cat.Models,
	})
	if err != nil {
		return "", "", fmt.Errorf("marshal catalog for fingerprint: %w", err)
	}
	sum := sha256.Sum256(data)
	digest = hex.EncodeToString(sum[:])
	revision = fmt.Sprintf("%s-%s", cat.Metadata.SourceRevision, digest[:12])
	return digest, revision, nil
}

// Marshal renders the catalog as the published artifact bytes.
func Marshal(cat *model.Catalog) ([]byte, error) {
	return json.MarshalIndent(cat, "", "  ")
}

// Filter narrows a catalog by provider, product and status. An empty filter
// matches everything. The filtered catalog keeps its identity metadata and
// carries a digest recomputed over the narrowed content.
func Filter(cat *model.Catalog, providerID, productID, status string) (*model.Catalog, error) {
	out := &model.Catalog{
		Metadata: cat.Metadata,
		Vendors:  cat.Vendors,
		Cache:    cat.Cache,
	}

	productIndex := make(map[string]model.CatalogProduct, len(cat.Products))
	for _, p := range cat.Products {
		productIndex[p.ID] = p
	}

	for _, p := range cat.Products {
		if productID != "" && p.ID != productID {
			continue
		}
		if providerID != "" && p.VendorID != providerID {
			continue
		}
		out.Products = append(out.Products, p)
	}
	if out.Products == nil {
		out.Products = []model.CatalogProduct{}
	}

	kept := make(map[string]struct{}, len(out.Products))
	for _, p := range out.Products {
		kept[p.ID] = struct{}{}
	}

	for _, m := range cat.Models {
		if _, ok := kept[m.ProductID]; !ok {
			continue
		}
		if status != "" && m.Status != status {
			continue
		}
		out.Models = append(out.Models, m)
	}
	if out.Models == nil {
		out.Models = []model.ModelRecord{}
	}

	if providerID != "" {
		want := map[string]struct{}{}
		for _, p := range out.Products {
			want[p.VendorID] = struct{}{}
		}
		filtered := out.Vendors[:0]
		for _, v := range out.Vendors {
			if _, ok := want[v.ID]; ok {
				filtered = append(filtered, v)
			}
		}
		out.Vendors = filtered
	}

	// A narrowed view carries its own digest so a client caching one filtered
	// view never confuses it with another.
	digest, revision, err := fingerprint(out)
	if err != nil {
		return nil, err
	}
	out.Metadata.Sha256 = digest
	out.Metadata.CatalogRevision = revision
	return out, nil
}

// ProductView renders a single product document for /v1/products/{id}.
func ProductView(cat *model.Catalog, productID string) (*model.CatalogProduct, []model.ModelRecord, bool) {
	var (
		found   model.CatalogProduct
		ok      bool
		records []model.ModelRecord
	)
	for _, p := range cat.Products {
		if p.ID == productID {
			found, ok = p, true
			break
		}
	}
	if !ok {
		return nil, nil, false
	}
	for _, m := range cat.Models {
		if m.ProductID == productID {
			records = append(records, m)
		}
	}
	return &found, records, true
}

// ModelView renders every record carrying a model ID, across all products.
func ModelView(cat *model.Catalog, modelID string) []model.ModelRecord {
	var out []model.ModelRecord
	for _, m := range cat.Models {
		if m.ID == modelID {
			out = append(out, m)
		}
	}
	return out
}

func containsString(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}

func timePtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}
