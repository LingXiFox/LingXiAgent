// Package api exposes the registry over HTTP.
//
// Every handler reads the same in-memory catalog, which is rebuilt from the one
// registry plus the one discovery cache. No endpoint has a private data source,
// so no endpoint can drift into being a separate authority.
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"lingxi/registry/internal/catalog"
	"lingxi/registry/internal/discovery"
	"lingxi/registry/internal/model"
	"lingxi/registry/internal/registry"
)

// Server serves the registry HTTP API.
type Server struct {
	registry  *registry.Registry
	discovery *discovery.Manager
	builder   *catalog.Builder
	logger    *log.Logger

	refreshInterval time.Duration

	mu      sync.RWMutex
	cat     *model.Catalog
	etag    string
	views   map[string]cachedView
	lastErr error
}

type cachedView struct {
	body []byte
	etag string
}

// Options configures a Server.
type Options struct {
	RefreshInterval time.Duration
	Logger          *log.Logger
}

// New creates a Server over a loaded registry.
func New(reg *registry.Registry, disc *discovery.Manager, opts Options) *Server {
	if opts.RefreshInterval <= 0 {
		opts.RefreshInterval = 30 * time.Minute
	}
	if opts.Logger == nil {
		opts.Logger = log.Default()
	}
	return &Server{
		registry:        reg,
		discovery:       disc,
		builder:         catalog.NewBuilder(reg),
		logger:          opts.Logger,
		refreshInterval: opts.RefreshInterval,
		views:           map[string]cachedView{},
	}
}

// Handler returns the HTTP routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", s.handleHealth)
	mux.HandleFunc("GET /v1/catalog", s.handleCatalog)
	mux.HandleFunc("GET /v1/catalog/status", s.handleStatus)
	mux.HandleFunc("GET /v1/providers", s.handleProviders)
	mux.HandleFunc("GET /v1/products", s.handleProducts)
	mux.HandleFunc("GET /v1/products/{id}", s.handleProduct)
	mux.HandleFunc("GET /v1/models/{id}", s.handleModel)
	mux.HandleFunc("GET /v1/discovery", s.handleDiscovery)
	return s.withCommonHeaders(s.withLogging(mux))
}

// Rebuild regenerates the published catalog from the current registry and
// discovery cache. Called at startup and after every refresh pass.
func (s *Server) Rebuild() error {
	cache, err := s.discovery.LoadAll()
	if err != nil {
		return err
	}
	cat, err := s.builder.Build(cache)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.cat = cat
	s.etag = quoteETag(cat.Metadata.Sha256)
	s.views = map[string]cachedView{}
	s.lastErr = nil
	s.mu.Unlock()
	return nil
}

// Dump writes the canonical catalog artifact to path. The snapshot carries the
// same digest the API serves, so an on-disk snapshot and an API response for
// the same revision are byte-identical.
func (s *Server) Dump(path string) error {
	cat := s.currentCatalog()
	if cat == nil {
		return fmt.Errorf("catalog not built")
	}
	body, err := catalog.Marshal(cat)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// RefreshOnce runs one discovery pass over every product with a public profile
// and rebuilds the catalog.
func (s *Server) RefreshOnce(ctx context.Context) {
	for _, product := range s.registry.Products {
		profile, ok := s.registry.PublicProfileFor(product)
		if !ok {
			// No public profile: this product's model list is resolved on the
			// client against the user's own credential.
			continue
		}
		rec, err := s.discovery.Refresh(ctx, product, profile)
		switch {
		case err != nil:
			s.logger.Printf("discovery: product=%s profile=%s status=%s err=%v",
				product.ID, profile.ID, rec.Status, err)
		default:
			s.logger.Printf("discovery: product=%s profile=%s models=%d",
				product.ID, profile.ID, len(rec.Models))
		}
	}
	if err := s.Rebuild(); err != nil {
		s.mu.Lock()
		s.lastErr = err
		s.mu.Unlock()
		s.logger.Printf("catalog rebuild failed: %v", err)
	}
}

// RunRefreshLoop refreshes on a ticker until ctx is cancelled.
func (s *Server) RunRefreshLoop(ctx context.Context) {
	ticker := time.NewTicker(s.refreshInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.RefreshOnce(ctx)
		}
	}
}

// ---------------------------------------------------------------------------
// handlers
// ---------------------------------------------------------------------------

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	cat := s.cat
	lastErr := s.lastErr
	s.mu.RUnlock()

	if cat == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "starting"})
		return
	}
	out := map[string]any{
		"status":          "ok",
		"catalogRevision": cat.Metadata.CatalogRevision,
		"generatedAt":     cat.Metadata.GeneratedAt,
	}
	if lastErr != nil {
		out["lastError"] = lastErr.Error()
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleCatalog(w http.ResponseWriter, r *http.Request) {
	cat := s.currentCatalog()
	if cat == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "catalog not ready"})
		return
	}

	q := r.URL.Query()
	provider := strings.TrimSpace(q.Get("provider"))
	product := strings.TrimSpace(q.Get("product"))
	status := strings.TrimSpace(q.Get("status"))

	if provider == "" && product == "" && status == "" {
		s.serveCached(w, r, "catalog", func() ([]byte, string, error) {
			body, err := catalog.Marshal(cat)
			return body, quoteETag(cat.Metadata.Sha256), err
		})
		return
	}

	key := "catalog|" + provider + "|" + product + "|" + status
	s.serveCached(w, r, key, func() ([]byte, string, error) {
		filtered, err := catalog.Filter(cat, provider, product, status)
		if err != nil {
			return nil, "", err
		}
		body, err := catalog.Marshal(filtered)
		return body, quoteETag(filtered.Metadata.Sha256), err
	})
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	cat := s.currentCatalog()
	if cat == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "catalog not ready"})
		return
	}

	s.serveCached(w, r, "status", func() ([]byte, string, error) {
		out := map[string]any{
			"schemaVersion":   cat.Metadata.SchemaVersion,
			"catalogRevision": cat.Metadata.CatalogRevision,
			"generatedAt":     cat.Metadata.GeneratedAt,
			"sourceRevision":  cat.Metadata.SourceRevision,
			"providerCount":   len(cat.Vendors),
			"productCount":    len(cat.Products),
			"modelCount":      len(cat.Models),
			"sha256":          cat.Metadata.Sha256,
		}
		body, err := json.MarshalIndent(out, "", "  ")
		if err != nil {
			return nil, "", err
		}
		// The status document describes the catalog, so it is revalidated
		// against the catalog digest rather than its own bytes.
		return body, quoteETag(cat.Metadata.Sha256), nil
	})
}

func (s *Server) handleProviders(w http.ResponseWriter, r *http.Request) {
	cat := s.currentCatalog()
	if cat == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "catalog not ready"})
		return
	}
	s.serveCached(w, r, "providers", func() ([]byte, string, error) {
		body, err := json.MarshalIndent(map[string]any{
			"metadata": cat.Metadata,
			"vendors":  cat.Vendors,
		}, "", "  ")
		return body, quoteETag(cat.Metadata.Sha256), err
	})
}

func (s *Server) handleProducts(w http.ResponseWriter, r *http.Request) {
	cat := s.currentCatalog()
	if cat == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "catalog not ready"})
		return
	}
	vendor := strings.TrimSpace(r.URL.Query().Get("provider"))
	s.serveCached(w, r, "products|"+vendor, func() ([]byte, string, error) {
		products := cat.Products
		if vendor != "" {
			filtered := make([]model.CatalogProduct, 0, len(products))
			for _, p := range products {
				if p.VendorID == vendor {
					filtered = append(filtered, p)
				}
			}
			products = filtered
		}
		body, err := json.MarshalIndent(map[string]any{
			"metadata": cat.Metadata,
			"products": products,
		}, "", "  ")
		return body, quoteETag(cat.Metadata.Sha256), err
	})
}

func (s *Server) handleProduct(w http.ResponseWriter, r *http.Request) {
	cat := s.currentCatalog()
	if cat == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "catalog not ready"})
		return
	}
	id := r.PathValue("id")
	product, records, ok := catalog.ProductView(cat, id)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "unknown product", "product": id})
		return
	}
	s.serveCached(w, r, "product|"+id, func() ([]byte, string, error) {
		body, err := json.MarshalIndent(map[string]any{
			"metadata": cat.Metadata,
			"product":  product,
			"models":   records,
		}, "", "  ")
		return body, quoteETag(cat.Metadata.Sha256), err
	})
}

func (s *Server) handleModel(w http.ResponseWriter, r *http.Request) {
	cat := s.currentCatalog()
	if cat == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "catalog not ready"})
		return
	}
	id := r.PathValue("id")
	records := catalog.ModelView(cat, id)
	if len(records) == 0 {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "unknown model", "model": id})
		return
	}
	s.serveCached(w, r, "model|"+id, func() ([]byte, string, error) {
		body, err := json.MarshalIndent(map[string]any{
			"metadata": cat.Metadata,
			"model":    id,
			"records":  records,
		}, "", "  ")
		return body, quoteETag(cat.Metadata.Sha256), err
	})
}

// handleDiscovery reports the freshness of each product's model discovery.
func (s *Server) handleDiscovery(w http.ResponseWriter, r *http.Request) {
	cat := s.currentCatalog()
	if cat == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "catalog not ready"})
		return
	}
	s.serveCached(w, r, "discovery", func() ([]byte, string, error) {
		body, err := json.MarshalIndent(map[string]any{
			"metadata": cat.Metadata,
			"cache":    cat.Cache,
		}, "", "  ")
		return body, quoteETag(cat.Metadata.Sha256), err
	})
}

// ---------------------------------------------------------------------------
// plumbing
// ---------------------------------------------------------------------------

func (s *Server) currentCatalog() *model.Catalog {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cat
}

// serveCached renders a view once and reuses it until the catalog is rebuilt.
// It handles If-None-Match so an unchanged catalog costs a 304 with no body.
func (s *Server) serveCached(w http.ResponseWriter, r *http.Request, key string, render func() ([]byte, string, error)) {
	s.mu.RLock()
	view, ok := s.views[key]
	s.mu.RUnlock()

	if !ok {
		body, etag, err := render()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		view = cachedView{body: body, etag: etag}
		s.mu.Lock()
		// Another goroutine may have filled it in the meantime; either value
		// is equivalent, so last write wins without further coordination.
		s.views[key] = view
		s.mu.Unlock()
	}

	if matchesETag(r.Header.Get("If-None-Match"), view.etag) {
		w.Header().Set("ETag", view.etag)
		w.WriteHeader(http.StatusNotModified)
		return
	}

	w.Header().Set("ETag", view.etag)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.Header().Set("Content-Length", strconv.Itoa(len(view.body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(view.body)
}

// matchesETag implements the If-None-Match comparison, including the "*" and
// comma-separated-list forms.
func matchesETag(header, etag string) bool {
	if header == "" || etag == "" {
		return false
	}
	header = strings.TrimSpace(header)
	if header == "*" {
		return true
	}
	for _, candidate := range strings.Split(header, ",") {
		candidate = strings.TrimSpace(candidate)
		if candidate == etag {
			return true
		}
		if strings.TrimPrefix(candidate, "W/") == etag {
			return true
		}
	}
	return false
}

func quoteETag(sha string) string {
	if sha == "" {
		return ""
	}
	if len(sha) > 32 {
		sha = sha[:32]
	}
	return `"` + sha + `"`
}

func (s *Server) withCommonHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, If-None-Match, If-Modified-Since")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		s.logger.Printf("%s %s %d %s", r.Method, r.URL.RequestURI(), rec.status, time.Since(start).Round(time.Millisecond))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	body, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
