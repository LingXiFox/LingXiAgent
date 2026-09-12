// Package discovery runs public model-list discovery against upstream
// endpoints and keeps a last-known-good cache of the results.
//
// Only profiles explicitly marked Public are ever executed here. The public
// registry holds no vendor credentials: anything requiring auth belongs to
// client-side account discovery, performed with the user's own credential.
package discovery

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"lingxi/registry/internal/model"
)

// DefaultCacheTTL applies when a profile does not declare one.
const DefaultCacheTTL = 6 * time.Hour

// maxBodyBytes caps how much of an upstream response is read.
const maxBodyBytes = 8 << 20 // 8 MiB

// Manager performs discovery and persists the results.
type Manager struct {
	cacheDir string
	client   *http.Client
	now      func() time.Time
}

// NewManager creates a Manager writing cache records under cacheDir.
func NewManager(cacheDir string) *Manager {
	return &Manager{
		cacheDir: cacheDir,
		client: &http.Client{
			Timeout: 30 * time.Second,
		},
		now: func() time.Time { return time.Now().UTC() },
	}
}

// CachePath is the on-disk location of a product's discovery cache record.
func (m *Manager) CachePath(productID string) string {
	return filepath.Join(m.cacheDir, sanitize(productID)+".json")
}

// Load reads the cached discovery record for a product. The second return
// value is false when no cache exists yet.
func (m *Manager) Load(productID string) (model.DiscoveryCacheRecord, bool, error) {
	data, err := os.ReadFile(m.CachePath(productID))
	if err != nil {
		if os.IsNotExist(err) {
			return model.DiscoveryCacheRecord{}, false, nil
		}
		return model.DiscoveryCacheRecord{}, false, err
	}
	var rec model.DiscoveryCacheRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		// A corrupt cache file is treated as absent rather than fatal; the
		// next refresh rewrites it.
		return model.DiscoveryCacheRecord{}, false, nil
	}
	return rec, true, nil
}

// Save writes a discovery record atomically.
func (m *Manager) Save(rec model.DiscoveryCacheRecord) error {
	if err := os.MkdirAll(m.cacheDir, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return err
	}
	tmp := m.CachePath(rec.ProductID) + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, m.CachePath(rec.ProductID))
}

// LoadAll reads every cached discovery record, keyed by product ID.
func (m *Manager) LoadAll() (map[string]model.DiscoveryCacheRecord, error) {
	entries, err := os.ReadDir(m.cacheDir)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]model.DiscoveryCacheRecord{}, nil
		}
		return nil, err
	}
	out := make(map[string]model.DiscoveryCacheRecord)
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		productID := strings.TrimSuffix(e.Name(), ".json")
		rec, ok, err := m.Load(productID)
		if err != nil || !ok {
			continue
		}
		out[rec.ProductID] = rec
	}
	return out, nil
}

// Refresh runs one discovery pass for a product.
//
// On failure the previous model list is preserved and the record is marked
// failed, so a transient upstream outage can never empty the published catalog.
func (m *Manager) Refresh(ctx context.Context, product model.ProviderProduct, profile model.DiscoveryProfile) (model.DiscoveryCacheRecord, error) {
	adapter, err := AdapterFor(profile.Kind)
	if err != nil {
		return m.recordFailure(product, profile, err)
	}

	previous, hadPrevious, _ := m.Load(product.ID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, profile.URL, nil)
	if err != nil {
		return m.recordFailure(product, profile, err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "LingXiAgent-Registry/1.0 (+https://lingxiagent.lingxifox.cn)")
	for k, v := range profile.Headers {
		req.Header.Set(k, v)
	}
	// Conditional request: when the upstream listing has not changed we only
	// renew the TTL instead of rewriting the model list.
	if hadPrevious && previous.ETag != "" {
		req.Header.Set("If-None-Match", previous.ETag)
	}
	if hadPrevious && previous.LastModified != "" {
		req.Header.Set("If-Modified-Since", previous.LastModified)
	}

	resp, err := m.client.Do(req)
	if err != nil {
		return m.recordFailure(product, profile, err)
	}
	defer resp.Body.Close()

	ttl := parseTTL(profile.CacheTTL)
	now := m.now()

	if resp.StatusCode == http.StatusNotModified && hadPrevious {
		previous.FetchedAt = now
		previous.ExpiresAt = now.Add(ttl)
		previous.Status = model.CacheFresh
		previous.LastError = ""
		if err := m.Save(previous); err != nil {
			return previous, err
		}
		return previous, nil
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return m.recordFailure(product, profile,
			fmt.Errorf("upstream returned HTTP %d", resp.StatusCode))
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if err != nil {
		return m.recordFailure(product, profile, err)
	}

	models, err := adapter.Parse(body)
	if err != nil {
		return m.recordFailure(product, profile, err)
	}
	if len(models) == 0 {
		return m.recordFailure(product, profile,
			fmt.Errorf("upstream listing contained no models"))
	}

	rec := model.DiscoveryCacheRecord{
		ProductID:       product.ID,
		CredentialScope: "public",
		ProfileID:       profile.ID,
		FetchedAt:       now,
		ExpiresAt:       now.Add(ttl),
		Status:          model.CacheFresh,
		Source:          profile.URL,
		ETag:            resp.Header.Get("ETag"),
		LastModified:    resp.Header.Get("Last-Modified"),
		Models:          models,
	}
	if err := m.Save(rec); err != nil {
		return rec, err
	}
	return rec, nil
}

// recordFailure preserves the last-known-good model list while recording that
// the refresh failed.
func (m *Manager) recordFailure(product model.ProviderProduct, profile model.DiscoveryProfile, cause error) (model.DiscoveryCacheRecord, error) {
	now := m.now()
	previous, hadPrevious, _ := m.Load(product.ID)

	rec := model.DiscoveryCacheRecord{
		ProductID:       product.ID,
		CredentialScope: "public",
		ProfileID:       profile.ID,
		Status:          model.CacheFailed,
		Source:          profile.URL,
		LastError:       cause.Error(),
	}
	if hadPrevious {
		// Last-known-good: keep the models and their original fetch time, but
		// let the record go stale so readers can see the data is not current.
		rec.FetchedAt = previous.FetchedAt
		rec.ExpiresAt = previous.ExpiresAt
		rec.ETag = previous.ETag
		rec.LastModified = previous.LastModified
		rec.Models = previous.Models
	} else {
		rec.FetchedAt = now
		rec.ExpiresAt = now
		rec.Models = []model.DiscoveredModel{}
	}

	if err := m.Save(rec); err != nil {
		return rec, err
	}
	return rec, cause
}

// StatusFor classifies a cache record's freshness relative to now.
func StatusFor(rec model.DiscoveryCacheRecord, now time.Time) string {
	switch {
	case rec.Status == model.CacheFailed:
		return model.CacheFailed
	case now.After(rec.ExpiresAt):
		return model.CacheStale
	default:
		return model.CacheFresh
	}
}

func parseTTL(s string) time.Duration {
	if s == "" {
		return DefaultCacheTTL
	}
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return DefaultCacheTTL
	}
	return d
}

// sanitize keeps product IDs safe for use as a filename.
func sanitize(id string) string {
	var b strings.Builder
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '-', r == '_', r == '.':
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	if b.Len() == 0 {
		return "unknown"
	}
	return b.String()
}
