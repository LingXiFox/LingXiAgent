package api

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"lingxi/registry/internal/discovery"
	"lingxi/registry/internal/model"
	"lingxi/registry/internal/registry"
)

const (
	vendorsSrc = `{"version":1,"items":[
		{"id":"openai","displayName":"OpenAI"},
		{"id":"google","displayName":"Google"}]}`
	profilesSrc = `{"version":1,"items":[]}`
	oauthSrc    = `{"version":1,"items":[]}`
	overlaysSrc = `{"version":1,"items":[]}`
	productsSrc = `{"version":1,"items":[
		{"id":"openai-api","vendorID":"openai","displayName":"OpenAI API","type":"cloudAPI",
		 "authStrategy":"apiKey","protocolFamily":"openai_responses",
		 "discoveryStrategy":"apiModels","runtimeSupport":"implemented"},
		{"id":"gemini-api","vendorID":"google","displayName":"Gemini API","type":"cloudAPI",
		 "authStrategy":"apiKey","protocolFamily":"openai_chat",
		 "discoveryStrategy":"apiModels","runtimeSupport":"implemented"}]}`
)

func newTestServer(t *testing.T) (*Server, string) {
	t.Helper()

	dir := t.TempDir()
	registryDir := filepath.Join(dir, "registry")
	cacheDir := filepath.Join(dir, "cache")
	for _, d := range []string{registryDir, cacheDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}

	files := map[string]string{
		registry.FileVendors:   vendorsSrc,
		registry.FileProviders: productsSrc,
		registry.FileOAuth:     oauthSrc,
		registry.FileOverlays:  overlaysSrc,
		registry.FileProfiles:  profilesSrc,
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(registryDir, name), []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	reg, err := registry.Load(registryDir)
	if err != nil {
		t.Fatalf("load registry: %v", err)
	}

	disc := discovery.NewManager(cacheDir)
	seedDiscoveryCache(t, disc, "openai-api", []string{"model-a", "model-b"})
	seedDiscoveryCache(t, disc, "gemini-api", []string{"gemini-x"})

	srv := New(reg, disc, Options{Logger: log.New(io.Discard, "", 0)})
	if err := srv.Rebuild(); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	return srv, dir
}

func seedDiscoveryCache(t *testing.T, disc *discovery.Manager, productID string, ids []string) {
	t.Helper()
	now := time.Now().UTC()
	models := make([]model.DiscoveredModel, 0, len(ids))
	for _, id := range ids {
		models = append(models, model.DiscoveredModel{ID: id, DisplayName: id, DiscoveredAt: now})
	}
	if err := disc.Save(model.DiscoveryCacheRecord{
		ProductID: productID,
		FetchedAt: now,
		ExpiresAt: now.Add(time.Hour),
		Status:    model.CacheFresh,
		Source:    "test",
		Models:    models,
	}); err != nil {
		t.Fatalf("seed cache: %v", err)
	}
}

func get(t *testing.T, h http.Handler, path string, headers map[string]string) *http.Response {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Result()
}

// TestUnchangedCatalogReturns304 covers spec test G: a client that already
// holds the current revision gets a 304 with no body instead of a re-download.
func TestUnchangedCatalogReturns304(t *testing.T) {
	srv, _ := newTestServer(t)
	h := srv.Handler()

	first := get(t, h, "/v1/catalog", nil)
	if first.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", first.StatusCode)
	}
	etag := first.Header.Get("ETag")
	if etag == "" {
		t.Fatal("catalog response carries no ETag")
	}

	second := get(t, h, "/v1/catalog", map[string]string{"If-None-Match": etag})
	if second.StatusCode != http.StatusNotModified {
		t.Fatalf("want 304 for an unchanged catalog, got %d", second.StatusCode)
	}
	body, _ := io.ReadAll(second.Body)
	if len(body) != 0 {
		t.Errorf("a 304 must carry no body, got %d bytes", len(body))
	}

	// A stale validator must not be honoured.
	third := get(t, h, "/v1/catalog", map[string]string{"If-None-Match": `"stale-revision"`})
	if third.StatusCode != http.StatusOK {
		t.Errorf("want 200 for an unknown validator, got %d", third.StatusCode)
	}
}

// TestFilteredViewsHaveDistinctValidators checks that each narrowed view is
// cacheable on its own terms rather than sharing the full catalog's ETag.
func TestFilteredViewsHaveDistinctValidators(t *testing.T) {
	srv, _ := newTestServer(t)
	h := srv.Handler()

	full := get(t, h, "/v1/catalog", nil)
	openai := get(t, h, "/v1/catalog?provider=openai", nil)
	google := get(t, h, "/v1/catalog?provider=google", nil)

	if openai.Header.Get("ETag") == full.Header.Get("ETag") {
		t.Error("a filtered view must not reuse the full catalog ETag")
	}
	if openai.Header.Get("ETag") == google.Header.Get("ETag") {
		t.Error("different filtered views must have different ETags")
	}

	// Each filtered view revalidates against its own ETag.
	revalidated := get(t, h, "/v1/catalog?provider=openai",
		map[string]string{"If-None-Match": openai.Header.Get("ETag")})
	if revalidated.StatusCode != http.StatusNotModified {
		t.Errorf("want 304 on filtered revalidation, got %d", revalidated.StatusCode)
	}
}

// TestCatalogQueryParametersFilter verifies provider, product and status all
// narrow the same underlying catalog.
func TestCatalogQueryParametersFilter(t *testing.T) {
	srv, _ := newTestServer(t)
	h := srv.Handler()

	var payload struct {
		Products []struct {
			ID string `json:"id"`
		} `json:"products"`
		Models []struct {
			ID        string `json:"id"`
			ProductID string `json:"productID"`
		} `json:"models"`
	}

	byProvider := get(t, h, "/v1/catalog?provider=google", nil)
	if err := json.NewDecoder(byProvider.Body).Decode(&payload); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(payload.Products) != 1 || payload.Products[0].ID != "gemini-api" {
		t.Errorf("provider filter leaked products: %+v", payload.Products)
	}
	if len(payload.Models) != 1 || payload.Models[0].ID != "gemini-x" {
		t.Errorf("provider filter leaked models: %+v", payload.Models)
	}

	byProduct := get(t, h, "/v1/catalog?product=openai-api", nil)
	payload = struct {
		Products []struct {
			ID string `json:"id"`
		} `json:"products"`
		Models []struct {
			ID        string `json:"id"`
			ProductID string `json:"productID"`
		} `json:"models"`
	}{}
	if err := json.NewDecoder(byProduct.Body).Decode(&payload); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(payload.Models) != 2 {
		t.Errorf("product filter: want 2 models, got %d", len(payload.Models))
	}
	for _, m := range payload.Models {
		if m.ProductID != "openai-api" {
			t.Errorf("product filter leaked model %q from %q", m.ID, m.ProductID)
		}
	}

	// No model carries an overlay-backed status yet, so an active filter
	// legitimately yields nothing — and must still be a well-formed document.
	byStatus := get(t, h, "/v1/catalog?status=active", nil)
	if byStatus.StatusCode != http.StatusOK {
		t.Fatalf("status filter: want 200, got %d", byStatus.StatusCode)
	}
	var statusPayload struct {
		Models []json.RawMessage `json:"models"`
	}
	if err := json.NewDecoder(byStatus.Body).Decode(&statusPayload); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if statusPayload.Models == nil {
		t.Error("an empty model set must marshal as [] rather than null")
	}
}

// TestStatusDocumentReportsCountsAndDigest checks the /v1/catalog/status shape
// required of clients that want to detect catalog changes cheaply.
func TestStatusDocumentReportsCountsAndDigest(t *testing.T) {
	srv, _ := newTestServer(t)
	h := srv.Handler()

	resp := get(t, h, "/v1/catalog/status", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	var status struct {
		SchemaVersion   int    `json:"schemaVersion"`
		CatalogRevision string `json:"catalogRevision"`
		GeneratedAt     string `json:"generatedAt"`
		ProviderCount   int    `json:"providerCount"`
		ProductCount    int    `json:"productCount"`
		ModelCount      int    `json:"modelCount"`
		Sha256          string `json:"sha256"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if status.SchemaVersion != model.SchemaVersion {
		t.Errorf("schemaVersion: want %d, got %d", model.SchemaVersion, status.SchemaVersion)
	}
	if status.ProviderCount != 2 {
		t.Errorf("providerCount: want 2, got %d", status.ProviderCount)
	}
	if status.ProductCount != 2 {
		t.Errorf("productCount: want 2, got %d", status.ProductCount)
	}
	if status.ModelCount != 3 {
		t.Errorf("modelCount: want 3, got %d", status.ModelCount)
	}
	if len(status.Sha256) != 64 {
		t.Errorf("sha256 should be a full digest, got %q", status.Sha256)
	}
	if status.CatalogRevision == "" || status.GeneratedAt == "" {
		t.Error("catalogRevision and generatedAt must be present")
	}
}

// TestCatalogViewsShareOneAuthority checks that the convenience endpoints and
// /v1/catalog describe the same catalog rather than maintaining their own.
func TestCatalogViewsShareOneAuthority(t *testing.T) {
	srv, _ := newTestServer(t)
	h := srv.Handler()

	var catalogDoc struct {
		Metadata model.CatalogMetadata `json:"metadata"`
	}
	if err := json.NewDecoder(get(t, h, "/v1/catalog", nil).Body).Decode(&catalogDoc); err != nil {
		t.Fatalf("decode catalog: %v", err)
	}

	var productDoc struct {
		Metadata model.CatalogMetadata `json:"metadata"`
		Product  struct {
			ID string `json:"id"`
		} `json:"product"`
		Models []model.ModelRecord `json:"models"`
	}
	if err := json.NewDecoder(get(t, h, "/v1/products/openai-api", nil).Body).Decode(&productDoc); err != nil {
		t.Fatalf("decode product: %v", err)
	}
	if productDoc.Metadata.Sha256 != catalogDoc.Metadata.Sha256 {
		t.Error("/v1/products must report the same catalog digest as /v1/catalog")
	}
	if len(productDoc.Models) != 2 {
		t.Errorf("want 2 models for openai-api, got %d", len(productDoc.Models))
	}

	var modelDoc struct {
		Records []model.ModelRecord `json:"records"`
	}
	if err := json.NewDecoder(get(t, h, "/v1/models/model-a", nil).Body).Decode(&modelDoc); err != nil {
		t.Fatalf("decode model: %v", err)
	}
	if len(modelDoc.Records) != 1 || modelDoc.Records[0].ProductID != "openai-api" {
		t.Errorf("unexpected model lookup result: %+v", modelDoc.Records)
	}

	if resp := get(t, h, "/v1/models/no-such-model", nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("unknown model: want 404, got %d", resp.StatusCode)
	}
	if resp := get(t, h, "/v1/products/no-such-product", nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("unknown product: want 404, got %d", resp.StatusCode)
	}
}

// TestDiscoveryEndpointPublishesFreshness checks that cache state is visible,
// so clients can tell a stale model list from a current one.
func TestDiscoveryEndpointPublishesFreshness(t *testing.T) {
	srv, _ := newTestServer(t)
	h := srv.Handler()

	resp := get(t, h, "/v1/discovery", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	var doc struct {
		Cache map[string]model.CacheSummary `json:"cache"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	summary, ok := doc.Cache["openai-api"]
	if !ok {
		t.Fatal("openai-api missing from the discovery report")
	}
	if summary.Status != model.CacheFresh {
		t.Errorf("want fresh, got %q", summary.Status)
	}
	if summary.ModelCount != 2 {
		t.Errorf("want modelCount 2, got %d", summary.ModelCount)
	}
}

// TestHealthReportsReadiness checks the endpoint an operator or supervisor
// would poll.
func TestHealthReportsReadiness(t *testing.T) {
	srv, _ := newTestServer(t)
	h := srv.Handler()

	resp := get(t, h, "/v1/health", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	var doc map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if doc["status"] != "ok" {
		t.Errorf("want status ok, got %v", doc["status"])
	}
	if doc["catalogRevision"] == "" {
		t.Error("health should report the catalog revision")
	}
}

// TestRebuildMovesDigestWhenModelsChange checks that the served validator tracks
// discovery results rather than being frozen at startup.
func TestRebuildMovesDigestWhenModelsChange(t *testing.T) {
	srv, dir := newTestServer(t)
	h := srv.Handler()

	before := get(t, h, "/v1/catalog", nil).Header.Get("ETag")

	disc := discovery.NewManager(filepath.Join(dir, "cache"))
	seedDiscoveryCache(t, disc, "openai-api", []string{"model-a", "model-b", "model-c"})
	srv.discovery = disc
	if err := srv.Rebuild(); err != nil {
		t.Fatalf("rebuild: %v", err)
	}

	after := get(t, h, "/v1/catalog", nil).Header.Get("ETag")
	if before == after {
		t.Error("ETag did not move after the model set changed")
	}

	revalidated := get(t, h, "/v1/catalog", map[string]string{"If-None-Match": before})
	if revalidated.StatusCode != http.StatusOK {
		t.Error("a superseded validator must not produce a 304")
	}
}
