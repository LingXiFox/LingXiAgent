package discovery

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"lingxi/registry/internal/model"
)

func testProduct() model.ProviderProduct {
	return model.ProviderProduct{
		ID:                "test-api",
		VendorID:          "test",
		DisplayName:       "Test API",
		DiscoveryStrategy: model.DiscoveryAPIModels,
		RuntimeSupport:    model.RuntimeImplemented,
	}
}

func testProfile(url string) model.DiscoveryProfile {
	return model.DiscoveryProfile{
		ID:       "test-models",
		Kind:     KindOpenAIModels,
		URL:      url,
		Auth:     "none",
		Public:   true,
		CacheTTL: "1h",
	}
}

// TestRefreshFailureKeepsLastKnownGood covers spec test F: a failed refresh must
// leave the previously discovered models in place rather than emptying the
// catalog.
func TestRefreshFailureKeepsLastKnownGood(t *testing.T) {
	healthy := true
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !healthy {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[{"id":"model-a"},{"id":"model-b"}]}`))
	}))
	defer upstream.Close()

	m := NewManager(t.TempDir())
	product := testProduct()
	profile := testProfile(upstream.URL)

	good, err := m.Refresh(context.Background(), product, profile)
	if err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	if len(good.Models) != 2 || good.Status != model.CacheFresh {
		t.Fatalf("unexpected first result: %+v", good)
	}

	// Upstream goes down.
	healthy = false
	failed, err := m.Refresh(context.Background(), product, profile)
	if err == nil {
		t.Fatal("expected the refresh to report an error")
	}
	if failed.Status != model.CacheFailed {
		t.Errorf("want failed status, got %q", failed.Status)
	}
	if len(failed.Models) != 2 {
		t.Fatalf("last-known-good models were dropped: got %d", len(failed.Models))
	}
	if failed.FetchedAt != good.FetchedAt {
		t.Error("a failed refresh must not advance the fetch time of the retained data")
	}
	if failed.LastError == "" {
		t.Error("the failure reason should be recorded")
	}

	// The retained models survive a reload from disk too.
	reloaded, ok, err := m.Load(product.ID)
	if err != nil || !ok {
		t.Fatalf("reload: ok=%v err=%v", ok, err)
	}
	if len(reloaded.Models) != 2 {
		t.Errorf("cache on disk lost the last-known-good models: %d", len(reloaded.Models))
	}
	if StatusFor(reloaded, time.Now().UTC()) != model.CacheFailed {
		t.Error("a failed record must report as failed, not fresh")
	}
}

// TestRefreshRecoversAfterFailure checks that the cache returns to fresh once
// the upstream comes back.
func TestRefreshRecoversAfterFailure(t *testing.T) {
	healthy := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !healthy {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		_, _ = w.Write([]byte(`{"data":[{"id":"model-a"}]}`))
	}))
	defer upstream.Close()

	m := NewManager(t.TempDir())
	product := testProduct()
	profile := testProfile(upstream.URL)

	if _, err := m.Refresh(context.Background(), product, profile); err == nil {
		t.Fatal("expected the first refresh to fail")
	}

	healthy = true
	recovered, err := m.Refresh(context.Background(), product, profile)
	if err != nil {
		t.Fatalf("recovery refresh: %v", err)
	}
	if recovered.Status != model.CacheFresh {
		t.Errorf("want fresh after recovery, got %q", recovered.Status)
	}
	if recovered.LastError != "" {
		t.Errorf("the stale error should be cleared, got %q", recovered.LastError)
	}
	if len(recovered.Models) != 1 {
		t.Errorf("want 1 model, got %d", len(recovered.Models))
	}
}

// TestRefreshRejectsEmptyUpstreamListing checks that an upstream replying with
// an empty list is treated as a failure rather than as "no models exist", so a
// transient upstream bug cannot blank a product's catalog entry.
func TestRefreshRejectsEmptyUpstreamListing(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"data":[]}`))
	}))
	defer upstream.Close()

	m := NewManager(t.TempDir())
	if _, err := m.Refresh(context.Background(), testProduct(), testProfile(upstream.URL)); err == nil {
		t.Fatal("an empty upstream listing must not be accepted as success")
	}
}

// TestConditionalRequestRenewsWithoutRefetching checks that an unchanged
// upstream listing (304) renews the TTL without replacing the model set.
func TestConditionalRequestRenewsWithoutRefetching(t *testing.T) {
	const etag = `"v1"`
	var sawConditional bool

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("If-None-Match") == etag {
			sawConditional = true
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", etag)
		_, _ = w.Write([]byte(`{"data":[{"id":"model-a"}]}`))
	}))
	defer upstream.Close()

	m := NewManager(t.TempDir())
	product := testProduct()
	profile := testProfile(upstream.URL)

	first, err := m.Refresh(context.Background(), product, profile)
	if err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	if first.ETag != etag {
		t.Fatalf("upstream ETag not stored: %q", first.ETag)
	}

	second, err := m.Refresh(context.Background(), product, profile)
	if err != nil {
		t.Fatalf("second refresh: %v", err)
	}
	if !sawConditional {
		t.Error("the second refresh did not send If-None-Match")
	}
	if second.Status != model.CacheFresh {
		t.Errorf("want fresh after 304, got %q", second.Status)
	}
	if len(second.Models) != 1 {
		t.Errorf("model set changed on a 304: %d", len(second.Models))
	}
	if !second.ExpiresAt.After(first.ExpiresAt) {
		t.Error("a 304 should renew the TTL")
	}
}

// TestStatusForClassifiesFreshness checks the freshness vocabulary clients see.
func TestStatusForClassifiesFreshness(t *testing.T) {
	now := time.Now().UTC()

	fresh := model.DiscoveryCacheRecord{Status: model.CacheFresh, ExpiresAt: now.Add(time.Hour)}
	if got := StatusFor(fresh, now); got != model.CacheFresh {
		t.Errorf("want fresh, got %q", got)
	}

	expired := model.DiscoveryCacheRecord{Status: model.CacheFresh, ExpiresAt: now.Add(-time.Hour)}
	if got := StatusFor(expired, now); got != model.CacheStale {
		t.Errorf("want stale, got %q", got)
	}

	failed := model.DiscoveryCacheRecord{Status: model.CacheFailed, ExpiresAt: now.Add(time.Hour)}
	if got := StatusFor(failed, now); got != model.CacheFailed {
		t.Errorf("want failed, got %q", got)
	}
}

// TestCorruptCacheIsTreatedAsAbsent checks that a damaged cache file degrades to
// "no cache" instead of taking the service down.
func TestCorruptCacheIsTreatedAsAbsent(t *testing.T) {
	dir := t.TempDir()
	m := NewManager(dir)
	if err := os.WriteFile(m.CachePath("test-api"), []byte("{ this is not json"), 0o644); err != nil {
		t.Fatalf("write corrupt cache: %v", err)
	}
	rec, ok, err := m.Load("test-api")
	if err != nil {
		t.Fatalf("a corrupt cache must not be a hard error: %v", err)
	}
	if ok {
		t.Errorf("corrupt cache should read as absent, got %+v", rec)
	}
}
