// Package registry loads the LingXi registry source files from disk and
// validates them into a single coherent Registry value.
//
// The source files are the only place providers, products, overlays and
// discovery profiles are declared. Every published view — /v1/catalog,
// /v1/providers, /v1/products, /v1/models/{id} — is derived from the one
// Registry this package returns, so no endpoint can become an independent
// authority.
package registry

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"lingxi/registry/internal/model"
)

// Source file names inside the registry directory.
const (
	FileVendors   = "vendors.json"
	FileProviders = "providers.json"
	FileOAuth     = "oauth-products.json"
	FileOverlays  = "overlays.json"
	FileProfiles  = "discovery-profiles.json"
	registryFiles = 5
)

// Registry is the validated, in-memory form of the registry source directory.
type Registry struct {
	Vendors  []model.Vendor
	Products []model.ProviderProduct
	Overlays []model.ModelOverlay
	Profiles []model.DiscoveryProfile

	// SourceRevision is a content hash over every source file. It changes if
	// and only if the registry source changes.
	SourceRevision string

	vendorsByID  map[string]model.Vendor
	productsByID map[string]model.ProviderProduct
	overlaysByID map[string]model.ModelOverlay
	profilesByID map[string]model.DiscoveryProfile
}

// Vendor returns a vendor by ID.
func (r *Registry) Vendor(id string) (model.Vendor, bool) {
	v, ok := r.vendorsByID[id]
	return v, ok
}

// Product returns a product by ID.
func (r *Registry) Product(id string) (model.ProviderProduct, bool) {
	p, ok := r.productsByID[id]
	return p, ok
}

// Overlay returns the overlay for a product, if one is declared.
func (r *Registry) Overlay(productID string) (model.ModelOverlay, bool) {
	o, ok := r.overlaysByID[productID]
	return o, ok
}

// Profile returns a discovery profile by ID.
func (r *Registry) Profile(id string) (model.DiscoveryProfile, bool) {
	p, ok := r.profilesByID[id]
	return p, ok
}

// PublicProfileFor returns the discovery profile a product should use for
// public catalog discovery. It returns false when the product relies on
// client-side account discovery instead — that is, when its profile requires a
// credential the public registry must never hold.
func (r *Registry) PublicProfileFor(product model.ProviderProduct) (model.DiscoveryProfile, bool) {
	if product.DiscoveryProfileID == "" {
		return model.DiscoveryProfile{}, false
	}
	profile, ok := r.profilesByID[product.DiscoveryProfileID]
	if !ok || !profile.Public {
		return model.DiscoveryProfile{}, false
	}
	return profile, true
}

// envelope is the on-disk wrapper for every registry source file.
type envelope[T any] struct {
	Version int `json:"version"`
	Items   []T `json:"items"`
}

// Load reads and validates the registry directory.
func Load(dir string) (*Registry, error) {
	revision, err := sourceRevision(dir)
	if err != nil {
		return nil, err
	}

	vendors, err := loadFile[model.Vendor](dir, FileVendors)
	if err != nil {
		return nil, err
	}
	products, err := loadFile[model.ProviderProduct](dir, FileProviders)
	if err != nil {
		return nil, err
	}
	oauthProducts, err := loadFile[model.ProviderProduct](dir, FileOAuth)
	if err != nil {
		return nil, err
	}
	overlays, err := loadFile[model.ModelOverlay](dir, FileOverlays)
	if err != nil {
		return nil, err
	}
	profiles, err := loadFile[model.DiscoveryProfile](dir, FileProfiles)
	if err != nil {
		return nil, err
	}

	products = append(products, oauthProducts...)

	r := &Registry{
		Vendors:        vendors,
		Products:       products,
		Overlays:       overlays,
		Profiles:       profiles,
		SourceRevision: revision,
	}
	if err := r.index(); err != nil {
		return nil, err
	}
	if err := r.validate(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *Registry) index() error {
	r.vendorsByID = make(map[string]model.Vendor, len(r.Vendors))
	for _, v := range r.Vendors {
		if _, dup := r.vendorsByID[v.ID]; dup {
			return fmt.Errorf("duplicate vendor id %q", v.ID)
		}
		r.vendorsByID[v.ID] = v
	}

	r.productsByID = make(map[string]model.ProviderProduct, len(r.Products))
	for _, p := range r.Products {
		if _, dup := r.productsByID[p.ID]; dup {
			return fmt.Errorf("duplicate product id %q", p.ID)
		}
		r.productsByID[p.ID] = p
	}

	r.overlaysByID = make(map[string]model.ModelOverlay, len(r.Overlays))
	for _, o := range r.Overlays {
		if _, dup := r.overlaysByID[o.ProductID]; dup {
			return fmt.Errorf("duplicate overlay for product %q", o.ProductID)
		}
		r.overlaysByID[o.ProductID] = o
	}

	r.profilesByID = make(map[string]model.DiscoveryProfile, len(r.Profiles))
	for _, p := range r.Profiles {
		if _, dup := r.profilesByID[p.ID]; dup {
			return fmt.Errorf("duplicate discovery profile id %q", p.ID)
		}
		r.profilesByID[p.ID] = p
	}
	return nil
}

// validate enforces the cross-file invariants. A dangling reference is a hard
// error rather than a silent skip, so a typo cannot quietly drop a product
// from the published catalog.
func (r *Registry) validate() error {
	for _, p := range r.Products {
		if p.ID == "" {
			return fmt.Errorf("product with empty id")
		}
		if p.VendorID == "" {
			return fmt.Errorf("product %q has empty vendorID", p.ID)
		}
		if _, ok := r.vendorsByID[p.VendorID]; !ok {
			return fmt.Errorf("product %q references unknown vendor %q", p.ID, p.VendorID)
		}
		if p.DiscoveryProfileID != "" {
			if _, ok := r.profilesByID[p.DiscoveryProfileID]; !ok {
				return fmt.Errorf("product %q references unknown discovery profile %q", p.ID, p.DiscoveryProfileID)
			}
		}
		switch p.DiscoveryStrategy {
		case model.DiscoveryStatic, model.DiscoveryAPIModels,
			model.DiscoveryAuthenticatedRemote, model.DiscoveryCustom:
		case "":
			return fmt.Errorf("product %q has empty discoveryStrategy", p.ID)
		default:
			return fmt.Errorf("product %q has unknown discoveryStrategy %q", p.ID, p.DiscoveryStrategy)
		}
		switch p.RuntimeSupport {
		case model.RuntimeImplemented, model.RuntimePartial, model.RuntimeUnsupported:
		case "":
			return fmt.Errorf("product %q has empty runtimeSupport", p.ID)
		default:
			return fmt.Errorf("product %q has unknown runtimeSupport %q", p.ID, p.RuntimeSupport)
		}
	}

	for _, o := range r.Overlays {
		if _, ok := r.productsByID[o.ProductID]; !ok {
			return fmt.Errorf("overlay references unknown product %q", o.ProductID)
		}
		for id, rec := range o.Models {
			if rec.Status == "" {
				continue
			}
			switch rec.Status {
			case model.StatusActive, model.StatusPreview, model.StatusDeprecated,
				model.StatusRetired, model.StatusUnknown:
			default:
				return fmt.Errorf("overlay %q model %q has unknown status %q", o.ProductID, id, rec.Status)
			}
		}
	}

	for _, p := range r.Profiles {
		if p.ID == "" {
			return fmt.Errorf("discovery profile with empty id")
		}
		if p.URL == "" {
			return fmt.Errorf("discovery profile %q has empty url", p.ID)
		}
		if !isAllowedURL(p.URL) {
			return fmt.Errorf("discovery profile %q must use https, or http on loopback", p.ID)
		}
	}
	return nil
}

// isAllowedURL permits HTTPS everywhere and plain HTTP only on loopback, which
// is what local model runtimes (Ollama, llama.cpp, LM Studio) expose. This
// mirrors the client's ConfigurationEndpointPolicy.
func isAllowedURL(raw string) bool {
	if strings.HasPrefix(raw, "https://") {
		return true
	}
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	if u.Scheme != "http" {
		return false
	}
	switch u.Hostname() {
	case "localhost", "127.0.0.1", "::1", "[::1]":
		return true
	default:
		return false
	}
}

func loadFile[T any](dir, name string) ([]T, error) {
	path := filepath.Join(dir, name)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", name, err)
	}
	var env envelope[T]
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, fmt.Errorf("parse %s: %w", name, err)
	}
	if env.Items == nil {
		env.Items = []T{}
	}
	return env.Items, nil
}

// sourceRevision hashes every registry source file in a stable order so the
// revision depends only on content, never on filesystem iteration order.
func sourceRevision(dir string) (string, error) {
	names := []string{FileVendors, FileProviders, FileOAuth, FileOverlays, FileProfiles}
	sort.Strings(names)

	h := sha256.New()
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return "", fmt.Errorf("read %s: %w", name, err)
		}
		// Normalize through JSON so whitespace-only edits do not move the
		// revision, then fold the canonical form into the running hash.
		var canonical any
		if err := json.Unmarshal(data, &canonical); err != nil {
			return "", fmt.Errorf("parse %s: %w", name, err)
		}
		encoded, err := json.Marshal(canonical)
		if err != nil {
			return "", fmt.Errorf("canonicalize %s: %w", name, err)
		}
		h.Write([]byte(name))
		h.Write([]byte{0})
		h.Write(encoded)
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))[:16], nil
}
