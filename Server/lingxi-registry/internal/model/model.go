// Package model defines the unified LingXi Model Registry entities.
//
// These types are the single source of truth shared by the registry loader,
// the catalog builder, and the HTTP API. Everything the server publishes is
// derived from these structures — there is no per-provider authority file.
package model

import "time"

// SchemaVersion is the version of the published catalog document shape.
const SchemaVersion = 1

// Model status values. Only Active and Preview participate in default
// selection; the remaining states are kept for metadata and history.
const (
	StatusActive     = "active"
	StatusPreview    = "preview"
	StatusDeprecated = "deprecated"
	StatusRetired    = "retired"
	StatusUnknown    = "unknown"
)

// SelectableStatuses are the statuses eligible for default UI/agent selection.
var SelectableStatuses = []string{StatusActive, StatusPreview}

// IsSelectable reports whether a model status may take part in default
// recommendation and automatic selection.
func IsSelectable(status string) bool {
	return status == StatusActive || status == StatusPreview
}

// Runtime support values. These describe what LingXi has actually implemented,
// which is independent of what the upstream catalog advertises and of what a
// given account can reach.
const (
	RuntimeImplemented = "implemented"
	RuntimePartial     = "partial"
	RuntimeUnsupported = "unsupported"
)

// Discovery strategy values. The strategy selects *how* a product's model list
// is obtained; the wire format differences live in DiscoveryProfile, never in
// runtime branching on a provider name.
const (
	DiscoveryStatic              = "static"
	DiscoveryAPIModels           = "apiModels"
	DiscoveryAuthenticatedRemote = "authenticatedRemote"
	DiscoveryCustom              = "custom"
)

// Vendor is a model vendor (for example "openai" or "google").
type Vendor struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
}

// DiscoveryImplementation describes the implementation status and backend
// of model discovery for a product.
type DiscoveryImplementation struct {
	Status  string `json:"status"`            // "implemented", "missing", "custom"
	Backend string `json:"backend,omitempty"` // "apiModels", "chatgptBackend", "custom", "none"
}

// ProviderProduct is one connectable product. Product identity is deliberately
// separate from vendor identity: "openai-api" and "openai-codex" are distinct
// products of the same vendor, with different auth and discovery strategies.
type ProviderProduct struct {
	ID                 string   `json:"id"`
	VendorID           string   `json:"vendorID"`
	DisplayName        string   `json:"displayName"`
	Type               string   `json:"type,omitempty"`
	AuthStrategy       string   `json:"authStrategy"`
	AuthMethods        []string `json:"authMethods,omitempty"`
	ProtocolFamily     string   `json:"protocolFamily"`
	DiscoveryStrategy  string   `json:"discoveryStrategy"`
	DiscoveryProfileID string   `json:"discoveryProfileID,omitempty"`
	Endpoint           string   `json:"endpoint,omitempty"`
	RuntimeSupport     string   `json:"runtimeSupport"`
	ConcurrencyLimit   *int     `json:"concurrencyLimit,omitempty"`
	Quirks             []string `json:"quirks,omitempty"`
	VerificationStatus string   `json:"verificationStatus,omitempty"`

	// DiscoveryImplementation describes the implementation status and backend
	// of model discovery for this product.
	DiscoveryImplementation *DiscoveryImplementation `json:"discoveryImplementation,omitempty"`
	// NamingVerification records product-level naming verification status against official vendors.
	NamingVerification string `json:"namingVerification,omitempty"`

	// RequestProfileID names the entry in RequestProfiles that a client should
	// apply when talking to this product.
	RequestProfileID string `json:"requestProfileID,omitempty"`
	// RequestProfiles carries the wire-level compatibility knowledge for a
	// product: which headers are required, which user agent to present, and
	// how conservative to be about optional fields.
	RequestProfiles map[string]RequestProfile `json:"requestProfiles,omitempty"`
	// OAuth carries the authorization-server facts for OAuth products.
	OAuth *OAuthConfig `json:"oauth,omitempty"`
	// AccountFields names the non-secret account attributes a product needs
	// beyond its credential (for example a region or workspace selector).
	AccountFields []string `json:"accountFields,omitempty"`
}

// OAuthConfig describes an OAuth authorization provider.
type OAuthConfig struct {
	Provider         string   `json:"provider"`
	ClientID         string   `json:"clientID"`
	AuthURL          string   `json:"authURL"`
	TokenURL         string   `json:"tokenURL"`
	Scopes           []string `json:"scopes"`
	UsePKCE          bool     `json:"usePKCE"`
	RedirectURI      string   `json:"redirectURI,omitempty"`
	RequestProfileID string   `json:"requestProfileID,omitempty"`
}

// RequestProfile is one versioned request-compatibility profile.
type RequestProfile struct {
	ID                string            `json:"id"`
	Version           string            `json:"version"`
	CompatibilityMode string            `json:"compatibilityMode"`
	EndpointOverride  string            `json:"endpointOverride,omitempty"`
	RequiredHeaders   map[string]string `json:"requiredHeaders,omitempty"`
	DynamicHeaders    map[string]string `json:"dynamicHeaders,omitempty"`
	UserAgentProfile  string            `json:"userAgentProfile,omitempty"`
}

// Capabilities captures the per-model facts LingXi maintains. Every field is a
// pointer so that "unknown" is distinguishable from "false".
type Capabilities struct {
	ContextWindow           *int     `json:"contextWindow,omitempty"`
	MaxOutputTokens         *int     `json:"maxOutputTokens,omitempty"`
	ToolCalling             *bool    `json:"toolCalling,omitempty"`
	ParallelToolCalling     *bool    `json:"parallelToolCalling,omitempty"`
	Vision                  *bool    `json:"vision,omitempty"`
	Reasoning               *bool    `json:"reasoning,omitempty"`
	ReasoningMode           string   `json:"reasoningMode,omitempty"`
	SupportedReasoningLevel []string `json:"supportedReasoningEfforts,omitempty"`
	StructuredOutput        *bool    `json:"structuredOutput,omitempty"`
	Cache                   *bool    `json:"cache,omitempty"`
	Modalities              []string `json:"modalities,omitempty"`
}

// ModelRecord is one model as published in the catalog.
//
// Status is the lifecycle state, Source records where the record came from
// (an upstream listing, static metadata, or a registry declaration), and
// MetadataIncomplete marks a model that was discovered upstream but which the
// overlay does not describe. Such models are kept and surfaced — never filtered.
type ModelRecord struct {
	ID                 string       `json:"id"`
	ProductID          string       `json:"productID"`
	DisplayName        string       `json:"displayName"`
	Status             string       `json:"status"`
	Capabilities       Capabilities `json:"capabilities"`
	MetadataIncomplete bool       `json:"metadataIncomplete"`
	Source             string     `json:"source"`
	DiscoveredAt       *time.Time `json:"discoveredAt,omitempty"`
	VerifiedAt         *time.Time `json:"verifiedAt,omitempty"`

	// UpstreamModelID is the identifier exactly as the upstream listing spelled
	// it. It is stored verbatim and never normalized, so a reviewer can compare
	// it byte-for-byte against the endpoint named in DiscoveredFrom.
	UpstreamModelID string `json:"upstreamModelID"`

	// SourceAuthority is the host whose listing produced this record.
	SourceAuthority string `json:"sourceAuthority"`
	// SourceAuthorityKind classifies that host. It is declared on the discovery
	// profile rather than inferred from the domain, so a future reader never
	// has to guess whether a host resells other vendors' models.
	SourceAuthorityKind string `json:"sourceAuthorityKind"`
	// DiscoveredFrom is the concrete endpoint the record came from.
	DiscoveredFrom string `json:"discoveredFrom,omitempty"`

	// ListingVerified reports that this (productID, upstreamModelID) pair was
	// actually returned by the product's own listing.
	//
	// It asserts nothing about the model existing in general — a listing is
	// evidence about the endpoint that served it and nothing more. In
	// particular an aggregator's listing never verifies a first-party vendor's
	// catalogue. Static metadata always leaves this false: knowing a model's
	// name is not evidence that the model exists.
	ListingVerified bool `json:"listingVerified"`

	// NamingVerification records model-level naming verification status against official vendors.
	NamingVerification string `json:"namingVerification,omitempty"`

	// DisplayNameSource records which upstream field the display name came from
	// (for example "title" or "name"). It exists so a reviewer can confirm the
	// name was taken from the listing rather than assembled locally, and that no
	// reasoning or profile information was folded into it.
	DisplayNameSource string `json:"displayNameSource,omitempty"`
}

// Aliases maps alternate model identifiers onto a canonical model ID.
type Aliases struct {
	ProductID string            `json:"productID"`
	Aliases   map[string]string `json:"aliases,omitempty"`
}

// ModelOverlay supplements metadata for models it knows about. It must never
// act as an allowlist: a model absent from the overlay is still published, just
// with MetadataIncomplete set.
type ModelOverlay struct {
	ProductID string                   `json:"productID"`
	Models    map[string]OverlayRecord `json:"models"`
}

// OverlayRecord is the metadata an overlay contributes for a single model.
type OverlayRecord struct {
	DisplayName       string       `json:"displayName,omitempty"`
	Status            string       `json:"status,omitempty"`
	Aliases           []string     `json:"aliases,omitempty"`
	Capabilities      Capabilities `json:"capabilities,omitempty"`
	ProtocolOverride  string       `json:"protocolOverride,omitempty"`
	Quirks            []string     `json:"quirks,omitempty"`
	Notes             string       `json:"notes,omitempty"`
	DeprecationReason string       `json:"deprecationReason,omitempty"`
}

// DiscoveryProfile describes how to obtain a product's model list from an
// upstream wire format. The Kind field selects the parser; that selection is
// the only place provider-specific listing shapes are allowed to appear.
type DiscoveryProfile struct {
	ID                  string            `json:"id"`
	Kind                string            `json:"kind"`
	URL                 string            `json:"url"`
	Auth                string            `json:"auth,omitempty"`
	AuthKeyParam        string            `json:"authKeyParam,omitempty"`
	Headers             map[string]string `json:"headers,omitempty"`
	CacheTTL            string            `json:"cacheTTL,omitempty"`
	SourceAuthorityKind string            `json:"sourceAuthorityKind,omitempty"`
	// ModelArrayPath locates the model array in the response body when the
	// document is not already an array. Empty means "top level array" or the
	// parser's own default location.
	ModelArrayPath string `json:"modelArrayPath,omitempty"`
	// Public marks a profile reachable without any credential. The public
	// registry only ever executes public profiles.
	Public bool `json:"public"`
}

// Discovery cache states.
const (
	CacheFresh      = "fresh"
	CacheStale      = "stale"
	CacheRefreshing = "refreshing"
	CacheFailed     = "failed"
)

// DiscoveryCacheRecord is the persisted result of one discovery run for a
// product. A failed refresh keeps the previous model list so that the catalog
// always has a last-known-good value to fall back on.
type DiscoveryCacheRecord struct {
	ProductID       string            `json:"productID"`
	CredentialScope string            `json:"credentialScope"`
	ProfileID       string            `json:"profileID"`
	FetchedAt       time.Time         `json:"fetchedAt"`
	ExpiresAt       time.Time         `json:"expiresAt"`
	Status          string            `json:"status"`
	Source          string            `json:"source"`
	ETag            string            `json:"etag,omitempty"`
	LastModified    string            `json:"lastModified,omitempty"`
	LastError       string            `json:"lastError,omitempty"`
	Models          []DiscoveredModel `json:"models"`
}

// DiscoveredModel is a model as returned by an upstream listing, normalized
// into the registry vocabulary but not yet merged with overlay metadata.
type DiscoveredModel struct {
	ID                string       `json:"id"`
	DisplayName       string       `json:"displayName"`
	Capabilities      Capabilities `json:"capabilities,omitempty"`
	RawStatus         string       `json:"rawStatus,omitempty"`
	DiscoveredAt      time.Time    `json:"discoveredAt"`
	UpstreamModelID   string       `json:"upstreamModelID,omitempty"`
	DisplayNameSource string       `json:"displayNameSource,omitempty"`
}

// CatalogMetadata describes the published catalog document itself.
type CatalogMetadata struct {
	SchemaVersion   int       `json:"schemaVersion"`
	CatalogRevision string    `json:"catalogRevision"`
	GeneratedAt     time.Time `json:"generatedAt"`
	SourceRevision  string    `json:"sourceRevision"`
	Sha256          string    `json:"sha256"`
}

// Catalog is the canonical published artifact.
type Catalog struct {
	Metadata CatalogMetadata         `json:"metadata"`
	Vendors  []Vendor                `json:"vendors"`
	Products []CatalogProduct        `json:"products"`
	Models   []ModelRecord           `json:"models"`
	Cache    map[string]CacheSummary `json:"discoveryCache,omitempty"`
}

// CatalogProduct is a product together with its resolved model records.
type CatalogProduct struct {
	ProviderProduct
	ModelIDs []string `json:"modelIDs"`
	// DiscoveryProfile is the resolved profile detail, published so a client can
	// perform account discovery against the right endpoint and wire format
	// without hardcoding either. Absent when the product declares no profile.
	DiscoveryProfile *DiscoveryProfile `json:"discoveryProfile,omitempty"`
}

// CacheSummary is the per-product discovery state published alongside the
// catalog so clients can tell how fresh the model lists are.
type CacheSummary struct {
	Status     string    `json:"status"`
	FetchedAt  time.Time `json:"fetchedAt"`
	ExpiresAt  time.Time `json:"expiresAt"`
	Source     string    `json:"source"`
	ModelCount int       `json:"modelCount"`
	LastError  string    `json:"lastError,omitempty"`
}
