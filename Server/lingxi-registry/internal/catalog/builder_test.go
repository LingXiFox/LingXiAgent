package catalog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"lingxi/registry/internal/model"
	"lingxi/registry/internal/registry"
)

// writeRegistry materializes a registry source directory for a test.
func writeRegistry(t *testing.T, vendors, providers, oauth, overlays, profiles string) *registry.Registry {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		registry.FileVendors:   vendors,
		registry.FileProviders: providers,
		registry.FileOAuth:     oauth,
		registry.FileOverlays:  overlays,
		registry.FileProfiles:  profiles,
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	reg, err := registry.Load(dir)
	if err != nil {
		t.Fatalf("load registry: %v", err)
	}
	return reg
}

const (
	testVendors   = `{"version":1,"items":[{"id":"openai","displayName":"OpenAI"}]}`
	testOverlays  = `{"version":1,"items":[]}`
	testProfiles  = `{"version":1,"items":[]}`
	testOAuth     = `{"version":1,"items":[]}`
	testProviders = `{"version":1,"items":[{
		"id":"openai-api","vendorID":"openai","displayName":"OpenAI API","type":"cloudAPI",
		"authStrategy":"apiKey","protocolFamily":"openai_responses",
		"discoveryStrategy":"apiModels","runtimeSupport":"implemented"}]}`
)

func discovered(ids ...string) []model.DiscoveredModel {
	now := time.Now().UTC()
	out := make([]model.DiscoveredModel, 0, len(ids))
	for _, id := range ids {
		out = append(out, model.DiscoveredModel{ID: id, DisplayName: id, DiscoveredAt: now})
	}
	return out
}

// TestOverlayNeverFiltersUnknownModels covers spec test B: the overlay knows
// only A and B, the upstream listing returns C as well, and C must still be
// published — flagged metadataIncomplete rather than dropped.
func TestOverlayNeverFiltersUnknownModels(t *testing.T) {
	overlays := `{"version":1,"items":[{"productID":"openai-api","models":{
		"model-a":{"displayName":"Model A","status":"active","capabilities":{"contextWindow":1000}},
		"model-b":{"displayName":"Model B","status":"active"}}}]}`

	reg := writeRegistry(t, testVendors, testProviders, testOAuth, overlays, testProfiles)
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("model-a", "model-b", "model-c")},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	if len(cat.Models) != 3 {
		t.Fatalf("want 3 models published, got %d: %+v", len(cat.Models), cat.Models)
	}

	byID := map[string]model.ModelRecord{}
	for _, m := range cat.Models {
		byID[m.ID] = m
	}

	unknown, ok := byID["model-c"]
	if !ok {
		t.Fatal("upstream model 'model-c', absent from the overlay, was filtered out")
	}
	if !unknown.MetadataIncomplete {
		t.Error("model-c should be marked metadataIncomplete")
	}
	if unknown.Source != SourceUpstreamDiscovery {
		t.Errorf("model-c source: want %q, got %q", SourceUpstreamDiscovery, unknown.Source)
	}

	known, ok := byID["model-a"]
	if !ok {
		t.Fatal("model-a missing")
	}
	if known.MetadataIncomplete {
		t.Error("model-a is described by the overlay and must not be metadataIncomplete")
	}
	if known.DisplayName != "Model A" {
		t.Errorf("overlay display name not applied: %q", known.DisplayName)
	}
	if known.Capabilities.ContextWindow == nil || *known.Capabilities.ContextWindow != 1000 {
		t.Error("overlay capability not applied")
	}
}

// TestOverlayAliasesResolveToCanonicalMetadata checks that a dated upstream ID
// still picks up the metadata LingXi maintains under its canonical name.
func TestOverlayAliasesResolveToCanonicalMetadata(t *testing.T) {
	overlays := `{"version":1,"items":[{"productID":"openai-api","models":{
		"model-a":{"displayName":"Model A","status":"active","aliases":["model-a-2026-01-01"]}}}]}`

	reg := writeRegistry(t, testVendors, testProviders, testOAuth, overlays, testProfiles)
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("model-a-2026-01-01")},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if len(cat.Models) != 1 {
		t.Fatalf("want 1 model, got %d", len(cat.Models))
	}
	m := cat.Models[0]
	if m.ID != "model-a-2026-01-01" {
		t.Errorf("published id must stay the upstream id, got %q", m.ID)
	}
	if m.MetadataIncomplete {
		t.Error("alias match should resolve overlay metadata")
	}
	if m.DisplayName != "Model A" {
		t.Errorf("want alias-resolved display name, got %q", m.DisplayName)
	}
}

// TestDeprecatedStatusSurvivesButIsNotSelectable covers spec test E: a model the
// overlay marks deprecated is still published for metadata, but is excluded
// from default selection.
func TestDeprecatedStatusSurvivesButIsNotSelectable(t *testing.T) {
	overlays := `{"version":1,"items":[{"productID":"openai-api","models":{
		"model-old":{"displayName":"Model Old","status":"deprecated"},
		"model-new":{"displayName":"Model New","status":"active"}}}]}`

	reg := writeRegistry(t, testVendors, testProviders, testOAuth, overlays, testProfiles)
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("model-old", "model-new")},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	status := map[string]string{}
	for _, m := range cat.Models {
		status[m.ID] = m.Status
	}
	if status["model-old"] != model.StatusDeprecated {
		t.Errorf("want model-old deprecated, got %q", status["model-old"])
	}
	if status["model-new"] != model.StatusActive {
		t.Errorf("want model-new active, got %q", status["model-new"])
	}

	if model.IsSelectable(status["model-old"]) {
		t.Error("deprecated models must not be selectable by default")
	}
	if !model.IsSelectable(status["model-new"]) {
		t.Error("active models must be selectable")
	}
	if model.IsSelectable(model.StatusUnknown) {
		t.Error("unknown status must not be selectable")
	}
}

// TestUnknownStatusIsNotSelectable guards the default for a discovered model no
// overlay describes: it is published, but never auto-selected.
func TestUnknownStatusIsNotSelectable(t *testing.T) {
	reg := writeRegistry(t, testVendors, testProviders, testOAuth, testOverlays, testProfiles)
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("fresh-model")},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if cat.Models[0].Status != model.StatusUnknown {
		t.Fatalf("want unknown status, got %q", cat.Models[0].Status)
	}
	if model.IsSelectable(cat.Models[0].Status) {
		t.Error("an undescribed discovered model must not be selectable by default")
	}
}

// TestAPIAndOAuthProductsStayIsolated covers spec test D: an OAuth product and
// an API product of the same vendor keep separate model sets. A model
// discovered for one must never appear under the other.
func TestAPIAndOAuthProductsStayIsolated(t *testing.T) {
	providers := `{"version":1,"items":[{
		"id":"openai-api","vendorID":"openai","displayName":"OpenAI API","type":"cloudAPI",
		"authStrategy":"apiKey","protocolFamily":"openai_responses",
		"discoveryStrategy":"apiModels","runtimeSupport":"implemented"}]}`
	oauth := `{"version":1,"items":[{
		"id":"openai-codex","vendorID":"openai","displayName":"OpenAI Codex","type":"subscription",
		"authStrategy":"oauth","protocolFamily":"openai_responses",
		"discoveryStrategy":"authenticatedRemote","runtimeSupport":"partial"}]}`

	reg := writeRegistry(t, testVendors, providers, oauth, testOverlays, testProfiles)
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("api-model")},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	for _, m := range cat.Models {
		if m.ProductID == "openai-codex" {
			t.Fatalf("API discovery leaked into the OAuth product: %+v", m)
		}
	}
	if len(cat.Models) != 1 || cat.Models[0].ProductID != "openai-api" {
		t.Fatalf("unexpected model set: %+v", cat.Models)
	}

	// The OAuth product is still published as a product, with no models —
	// its availability is resolved on the client against the user's account.
	var found bool
	for _, p := range cat.Products {
		if p.ID == "openai-codex" {
			found = true
			if len(p.ModelIDs) != 0 {
				t.Errorf("OAuth product must publish no public models, got %v", p.ModelIDs)
			}
		}
	}
	if !found {
		t.Error("OAuth product missing from the catalog entirely")
	}
}

// TestFailedDiscoveryKeepsLastKnownGood covers spec test F: a refresh that fails
// must not empty the published model list.
func TestFailedDiscoveryKeepsLastKnownGood(t *testing.T) {
	reg := writeRegistry(t, testVendors, testProviders, testOAuth, testOverlays, testProfiles)

	// A failed record still carries the previously discovered models.
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"openai-api": {
			ProductID: "openai-api",
			Status:    model.CacheFailed,
			LastError: "upstream returned HTTP 503",
			Models:    discovered("model-a", "model-b"),
		},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if len(cat.Models) != 2 {
		t.Fatalf("last-known-good models were dropped on failure: got %d", len(cat.Models))
	}
	if summary, ok := cat.Cache["openai-api"]; !ok || summary.Status != model.CacheFailed {
		t.Errorf("failure state not published: %+v", cat.Cache["openai-api"])
	}
}

// TestCatalogDigestIsStableAndContentAddressed checks that identical inputs give
// an identical digest, and that a content change moves it.
func TestCatalogDigestIsStableAndContentAddressed(t *testing.T) {
	reg := writeRegistry(t, testVendors, testProviders, testOAuth, testOverlays, testProfiles)
	cache := map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("model-a")},
	}

	first, err := NewBuilder(reg).Build(cache)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	second, err := NewBuilder(reg).Build(cache)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if first.Metadata.Sha256 != second.Metadata.Sha256 {
		t.Error("digest is not stable across identical builds")
	}

	changed, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("model-a", "model-b")},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if changed.Metadata.Sha256 == first.Metadata.Sha256 {
		t.Error("digest did not move when catalog content changed")
	}
	if changed.Metadata.CatalogRevision == first.Metadata.CatalogRevision {
		t.Error("revision did not move when catalog content changed")
	}
}

// TestFilterNarrowsByProviderProductAndStatus checks the /v1/catalog query
// parameters all read the same catalog and narrow it consistently.
func TestFilterNarrowsByProviderProductAndStatus(t *testing.T) {
	overlays := `{"version":1,"items":[{"productID":"openai-api","models":{
		"model-old":{"status":"deprecated"},"model-new":{"status":"active"}}}]}`
	reg := writeRegistry(t, testVendors, testProviders, testOAuth, overlays, testProfiles)
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("model-old", "model-new")},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	byProvider, err := Filter(cat, "openai", "", "")
	if err != nil {
		t.Fatalf("filter by provider: %v", err)
	}
	if len(byProvider.Models) != 2 {
		t.Errorf("provider filter: want 2 models, got %d", len(byProvider.Models))
	}

	byProduct, err := Filter(cat, "", "openai-api", "")
	if err != nil {
		t.Fatalf("filter by product: %v", err)
	}
	if len(byProduct.Models) != 2 {
		t.Errorf("product filter: want 2 models, got %d", len(byProduct.Models))
	}

	byStatus, err := Filter(cat, "", "", model.StatusActive)
	if err != nil {
		t.Fatalf("filter by status: %v", err)
	}
	if len(byStatus.Models) != 1 || byStatus.Models[0].ID != "model-new" {
		t.Errorf("status filter: want only model-new, got %+v", byStatus.Models)
	}

	// A filtered view is its own document with its own digest.
	if byStatus.Metadata.Sha256 == cat.Metadata.Sha256 {
		t.Error("a narrowed view must not reuse the full catalog digest")
	}

	empty, err := Filter(cat, "nonexistent", "", "")
	if err != nil {
		t.Fatalf("filter unknown provider: %v", err)
	}
	if len(empty.Products) != 0 || len(empty.Models) != 0 {
		t.Errorf("unknown provider should yield an empty view, got %d products", len(empty.Products))
	}
	if empty.Products == nil || empty.Models == nil {
		t.Error("empty views must marshal as [] rather than null")
	}
}

// TestCatalogMarshalsDeterministically guards the published artifact's
// reproducibility.
func TestCatalogMarshalsDeterministically(t *testing.T) {
	reg := writeRegistry(t, testVendors, testProviders, testOAuth, testOverlays, testProfiles)
	cache := map[string]model.DiscoveryCacheRecord{
		"openai-api": {ProductID: "openai-api", Models: discovered("b", "a", "c")},
	}
	cat, err := NewBuilder(reg).Build(cache)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	body, err := Marshal(cat)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var round model.Catalog
	if err := json.Unmarshal(body, &round); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for i, want := range []string{"a", "b", "c"} {
		if round.Models[i].ID != want {
			t.Errorf("model %d: want %q, got %q", i, want, round.Models[i].ID)
		}
	}
}

// TestListingVerifiedSemantics verifies that listingVerified only asserts that
// (productID, upstreamModelID) was returned by an actual listing, while static
// metadata leaves it false, and upstreamModelID is preserved verbatim.
func TestListingVerifiedSemantics(t *testing.T) {
	providers := `{"version":1,"items":[{
		"id":"google-gemini-api","vendorID":"google","displayName":"Gemini API","type":"cloudAPI",
		"authStrategy":"apiKey","protocolFamily":"gemini_chat",
		"discoveryStrategy":"apiModels","discoveryProfileID":"gemini-profile",
		"runtimeSupport":"implemented",
		"discoveryImplementation":{"status":"implemented","backend":"gemini-models"},
		"namingVerification":"verified"}]}`
	profiles := `{"version":1,"items":[{
		"id":"gemini-profile","kind":"gemini-models","url":"https://generativelanguage.googleapis.com/v1beta/models",
		"sourceAuthorityKind":"vendorFirstParty","public":true}]}`
	overlays := `{"version":1,"items":[{"productID":"google-gemini-api","models":{
		"gemini-static-only":{"displayName":"Gemini Static","status":"active"}}}]}`

	vendors := `{"version":1,"items":[{"id":"google","displayName":"Google"}]}`
	reg := writeRegistry(t, vendors, providers, testOAuth, overlays, profiles)
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{
		"google-gemini-api": {
			ProductID: "google-gemini-api",
			Models: []model.DiscoveredModel{
				{
					ID:                "gemini-2.5-pro",
					DisplayName:       "Gemini 2.5 Pro",
					UpstreamModelID:   "models/gemini-2.5-pro",
					DisplayNameSource: "displayName",
					DiscoveredAt:      time.Now().UTC(),
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	byID := map[string]model.ModelRecord{}
	for _, m := range cat.Models {
		byID[m.ID] = m
	}

	discoveredModel, ok := byID["gemini-2.5-pro"]
	if !ok {
		t.Fatal("gemini-2.5-pro missing")
	}
	if !discoveredModel.ListingVerified {
		t.Error("model returned by real listing must have listingVerified=true")
	}
	if discoveredModel.UpstreamModelID != "models/gemini-2.5-pro" {
		t.Errorf("upstreamModelID must be preserved verbatim, got %q", discoveredModel.UpstreamModelID)
	}
	if discoveredModel.DisplayName != "Gemini 2.5 Pro" {
		t.Errorf("displayName must not mix reasoning/profile info, got %q", discoveredModel.DisplayName)
	}
	if discoveredModel.SourceAuthorityKind != "vendorFirstParty" {
		t.Errorf("sourceAuthorityKind want 'vendorFirstParty', got %q", discoveredModel.SourceAuthorityKind)
	}

	staticModel, ok := byID["gemini-static-only"]
	if !ok {
		t.Fatal("gemini-static-only missing")
	}
	if staticModel.ListingVerified {
		t.Error("static metadata must have listingVerified=false")
	}
	if staticModel.SourceAuthorityKind != "staticOverlay" {
		t.Errorf("static model sourceAuthorityKind want 'staticOverlay', got %q", staticModel.SourceAuthorityKind)
	}

	// Product-level discoveryImplementation and namingVerification
	var productFound bool
	for _, p := range cat.Products {
		if p.ID == "google-gemini-api" {
			productFound = true
			if p.DiscoveryImplementation == nil || p.DiscoveryImplementation.Status != "implemented" {
				t.Errorf("discoveryImplementation want status 'implemented', got %+v", p.DiscoveryImplementation)
			}
			if p.NamingVerification != "verified" {
				t.Errorf("namingVerification want 'verified', got %q", p.NamingVerification)
			}
		}
	}
	if !productFound {
		t.Error("product google-gemini-api missing from catalog products")
	}
}

// TestMissingDiscoveryOAuthProductHasNoModelRecords verifies that an OAuth
// product lacking discovery has no ModelRecords, but its ProviderProduct carries
// discoveryImplementation and namingVerification.
func TestMissingDiscoveryOAuthProductHasNoModelRecords(t *testing.T) {
	oauth := `{"version":1,"items":[{
		"id":"anthropic-claude-subscription","vendorID":"anthropic","displayName":"Claude Subscription",
		"type":"subscription","authStrategy":"oauth",
		"protocolFamily":"anthropic_messages","discoveryStrategy":"authenticatedRemote",
		"runtimeSupport":"partial",
		"discoveryImplementation":{"status":"missing","backend":"none"},
		"namingVerification":"unverified"}]}`

	vendors := `{"version":1,"items":[{"id":"openai","displayName":"OpenAI"},{"id":"anthropic","displayName":"Anthropic"}]}`
	reg := writeRegistry(t, vendors, testProviders, oauth, testOverlays, testProfiles)
	cat, err := NewBuilder(reg).Build(map[string]model.DiscoveryCacheRecord{})
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	for _, m := range cat.Models {
		if m.ProductID == "anthropic-claude-subscription" {
			t.Fatalf("OAuth product without discovery must have no ModelRecords, got: %+v", m)
		}
	}

	var productFound bool
	for _, p := range cat.Products {
		if p.ID == "anthropic-claude-subscription" {
			productFound = true
			if p.DiscoveryImplementation == nil || p.DiscoveryImplementation.Status != "missing" {
				t.Errorf("discoveryImplementation want status 'missing', got %+v", p.DiscoveryImplementation)
			}
			if p.NamingVerification != "unverified" {
				t.Errorf("namingVerification want 'unverified', got %q", p.NamingVerification)
			}
		}
	}
	if !productFound {
		t.Error("OAuth product missing from products")
	}
}
