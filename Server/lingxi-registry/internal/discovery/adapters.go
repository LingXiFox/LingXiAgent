package discovery

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"lingxi/registry/internal/model"
)

// Adapter normalizes one upstream model-listing wire format into the registry
// vocabulary. Every provider-specific shape lives here; nothing downstream of
// this file is allowed to branch on a provider or product name.
type Adapter interface {
	// Kind is the DiscoveryProfile.Kind this adapter handles.
	Kind() string
	// Parse converts a response body into discovered models.
	Parse(body []byte) ([]model.DiscoveredModel, error)
}

// adapters is the registry of known wire formats.
var adapters = map[string]Adapter{
	KindOpenAIModels:     openAIModelsAdapter{},
	KindOpenRouterModels: openRouterModelsAdapter{},
	KindOllamaTags:       ollamaTagsAdapter{},
	KindAnthropicModels:  anthropicModelsAdapter{},
	KindGeminiModels:     geminiModelsAdapter{},
	KindPlainArray:       plainArrayAdapter{},
}

// Discovery profile kinds.
const (
	KindOpenAIModels     = "openai-models"
	KindOpenRouterModels = "openrouter-models"
	KindOllamaTags       = "ollama-tags"
	KindAnthropicModels  = "anthropic-models"
	KindGeminiModels     = "gemini-models"
	KindPlainArray       = "plain-array"
)

// AdapterFor returns the adapter for a profile kind.
func AdapterFor(kind string) (Adapter, error) {
	a, ok := adapters[kind]
	if !ok {
		return nil, fmt.Errorf("no discovery adapter for kind %q", kind)
	}
	return a, nil
}

// ---------------------------------------------------------------------------
// OpenAI-style: {"data": [{"id": "...", "owned_by": "..."}]}
// ---------------------------------------------------------------------------

type openAIModelsAdapter struct{}

func (openAIModelsAdapter) Kind() string { return KindOpenAIModels }

func (openAIModelsAdapter) Parse(body []byte) ([]model.DiscoveredModel, error) {
	var doc struct {
		Data []struct {
			ID      string `json:"id"`
			Name    string `json:"name"`
			Created int64  `json:"created"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("openai-models: %w", err)
	}
	now := time.Now().UTC()
	out := make([]model.DiscoveredModel, 0, len(doc.Data))
	for _, m := range doc.Data {
		if m.ID == "" {
			continue
		}
		name := m.Name
		source := "name"
		if name == "" {
			name = m.ID
			source = "id"
		}
		out = append(out, model.DiscoveredModel{
			ID:                m.ID,
			DisplayName:       name,
			DiscoveredAt:      now,
			UpstreamModelID:   m.ID,
			DisplayNameSource: source,
		})
	}
	return dedupe(out), nil
}

// ---------------------------------------------------------------------------
// OpenRouter: {"data": [{"id": "...", "name": "...", "context_length": N,
//               "architecture": {"input_modalities": [...]},
//               "supported_parameters": [...]}]}
// ---------------------------------------------------------------------------

type openRouterModelsAdapter struct{}

func (openRouterModelsAdapter) Kind() string { return KindOpenRouterModels }

func (openRouterModelsAdapter) Parse(body []byte) ([]model.DiscoveredModel, error) {
	var doc struct {
		Data []struct {
			ID            string `json:"id"`
			Name          string `json:"name"`
			ContextLength *int   `json:"context_length"`
			Architecture  struct {
				InputModalities  []string `json:"input_modalities"`
				OutputModalities []string `json:"output_modalities"`
			} `json:"architecture"`
			SupportedParameters []string `json:"supported_parameters"`
			TopProvider         struct {
				MaxCompletionTokens *int `json:"max_completion_tokens"`
			} `json:"top_provider"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("openrouter-models: %w", err)
	}
	now := time.Now().UTC()
	out := make([]model.DiscoveredModel, 0, len(doc.Data))
	for _, m := range doc.Data {
		if m.ID == "" {
			continue
		}
		name := m.Name
		source := "name"
		if name == "" {
			name = m.ID
			source = "id"
		}
		caps := model.Capabilities{
			ContextWindow:   m.ContextLength,
			MaxOutputTokens: m.TopProvider.MaxCompletionTokens,
		}
		if len(m.Architecture.InputModalities) > 0 {
			caps.Modalities = append(append([]string{}, m.Architecture.InputModalities...),
				m.Architecture.OutputModalities...)
			caps.Modalities = dedupeStrings(caps.Modalities)
			caps.Vision = boolPtr(containsString(m.Architecture.InputModalities, "image"))
		}
		if len(m.SupportedParameters) > 0 {
			caps.ToolCalling = boolPtr(containsString(m.SupportedParameters, "tools"))
			if containsString(m.SupportedParameters, "reasoning") ||
				containsString(m.SupportedParameters, "reasoning_effort") {
				caps.Reasoning = boolPtr(true)
				caps.ReasoningMode = "effort"
			}
			caps.StructuredOutput = boolPtr(containsString(m.SupportedParameters, "response_format"))
			caps.ParallelToolCalling = boolPtr(containsString(m.SupportedParameters, "parallel_tool_calls"))
		}
		out = append(out, model.DiscoveredModel{
			ID:                m.ID,
			DisplayName:       name,
			Capabilities:      caps,
			DiscoveredAt:      now,
			UpstreamModelID:   m.ID,
			DisplayNameSource: source,
		})
	}
	return dedupe(out), nil
}

// ---------------------------------------------------------------------------
// Ollama: {"models": [{"name": "llama3.2:latest", "model": "llama3.2:latest"}]}
// ---------------------------------------------------------------------------

type ollamaTagsAdapter struct{}

func (ollamaTagsAdapter) Kind() string { return KindOllamaTags }

func (ollamaTagsAdapter) Parse(body []byte) ([]model.DiscoveredModel, error) {
	var doc struct {
		Models []struct {
			Name  string `json:"name"`
			Model string `json:"model"`
		} `json:"models"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("ollama-tags: %w", err)
	}
	now := time.Now().UTC()
	out := make([]model.DiscoveredModel, 0, len(doc.Models))
	for _, m := range doc.Models {
		id := m.Model
		if id == "" {
			id = m.Name
		}
		if id == "" {
			continue
		}
		name := m.Name
		source := "name"
		if name == "" {
			name = id
			source = "model"
		}
		out = append(out, model.DiscoveredModel{
			ID:                id,
			DisplayName:       name,
			DiscoveredAt:      now,
			UpstreamModelID:   id,
			DisplayNameSource: source,
		})
	}
	return dedupe(out), nil
}

// ---------------------------------------------------------------------------
// Anthropic: {"data": [{"id": "...", "display_name": "...",
//              "created_at": "...", "type": "model"}]}
// ---------------------------------------------------------------------------

type anthropicModelsAdapter struct{}

func (anthropicModelsAdapter) Kind() string { return KindAnthropicModels }

func (anthropicModelsAdapter) Parse(body []byte) ([]model.DiscoveredModel, error) {
	var doc struct {
		Data []struct {
			ID          string `json:"id"`
			DisplayName string `json:"display_name"`
			CreatedAt   string `json:"created_at"`
			Type        string `json:"type"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("anthropic-models: %w", err)
	}
	now := time.Now().UTC()
	out := make([]model.DiscoveredModel, 0, len(doc.Data))
	for _, m := range doc.Data {
		if m.ID == "" {
			continue
		}
		name := m.DisplayName
		source := "display_name"
		if name == "" {
			name = m.ID
			source = "id"
		}
		out = append(out, model.DiscoveredModel{
			ID:                m.ID,
			DisplayName:       name,
			DiscoveredAt:      now,
			UpstreamModelID:   m.ID,
			DisplayNameSource: source,
		})
	}
	return dedupe(out), nil
}

// ---------------------------------------------------------------------------
// Gemini: {"models": [{"name": "models/gemini-2.5-pro",
//          "displayName": "...", "inputTokenLimit": N, "outputTokenLimit": N,
//          "supportedGenerationMethods": [...]}]}
// ---------------------------------------------------------------------------

type geminiModelsAdapter struct{}

func (geminiModelsAdapter) Kind() string { return KindGeminiModels }

func (geminiModelsAdapter) Parse(body []byte) ([]model.DiscoveredModel, error) {
	var doc struct {
		Models []struct {
			Name                       string   `json:"name"`
			DisplayName                string   `json:"displayName"`
			Description                string   `json:"description"`
			InputTokenLimit            *int     `json:"inputTokenLimit"`
			OutputTokenLimit           *int     `json:"outputTokenLimit"`
			SupportedGenerationMethods []string `json:"supportedGenerationMethods"`
		} `json:"models"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("gemini-models: %w", err)
	}
	now := time.Now().UTC()
	out := make([]model.DiscoveredModel, 0, len(doc.Models))
	for _, m := range doc.Models {
		// Gemini prefixes every model with the "models/" collection segment;
		// the registry keys models by their bare ID, while upstreamModelID stores
		// the verbatim upstream string ("models/...").
		id := strings.TrimPrefix(m.Name, "models/")
		if id == "" {
			continue
		}
		name := m.DisplayName
		source := "displayName"
		if name == "" {
			name = id
			source = "name"
		}
		caps := model.Capabilities{
			ContextWindow:   m.InputTokenLimit,
			MaxOutputTokens: m.OutputTokenLimit,
		}
		if len(m.SupportedGenerationMethods) > 0 {
			caps.ToolCalling = boolPtr(containsString(m.SupportedGenerationMethods, "generateContent"))
		}
		out = append(out, model.DiscoveredModel{
			ID:                id,
			DisplayName:       name,
			Capabilities:      caps,
			DiscoveredAt:      now,
			UpstreamModelID:   m.Name,
			DisplayNameSource: source,
		})
	}
	return dedupe(out), nil
}

// ---------------------------------------------------------------------------
// Bare JSON array of model objects or of plain model ID strings.
// ---------------------------------------------------------------------------

type plainArrayAdapter struct{}

func (plainArrayAdapter) Kind() string { return KindPlainArray }

func (plainArrayAdapter) Parse(body []byte) ([]model.DiscoveredModel, error) {
	now := time.Now().UTC()

	var objects []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal(body, &objects); err == nil {
		out := make([]model.DiscoveredModel, 0, len(objects))
		for _, m := range objects {
			id := m.ID
			if id == "" {
				id = m.Name
			}
			if id == "" {
				continue
			}
			name := m.Name
			source := "name"
			if name == "" {
				name = id
				source = "id"
			}
			out = append(out, model.DiscoveredModel{
				ID:                id,
				DisplayName:       name,
				DiscoveredAt:      now,
				UpstreamModelID:   id,
				DisplayNameSource: source,
			})
		}
		if len(out) > 0 {
			return dedupe(out), nil
		}
	}

	var names []string
	if err := json.Unmarshal(body, &names); err != nil {
		return nil, fmt.Errorf("plain-array: %w", err)
	}
	out := make([]model.DiscoveredModel, 0, len(names))
	for _, n := range names {
		if n == "" {
			continue
		}
		out = append(out, model.DiscoveredModel{
			ID:                n,
			DisplayName:       n,
			DiscoveredAt:      now,
			UpstreamModelID:   n,
			DisplayNameSource: "name",
		})
	}
	return dedupe(out), nil
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// dedupe removes duplicate IDs and returns a stable, ID-sorted slice so that a
// discovery run produces byte-identical output for identical upstream data.
func dedupe(in []model.DiscoveredModel) []model.DiscoveredModel {
	seen := make(map[string]struct{}, len(in))
	out := make([]model.DiscoveredModel, 0, len(in))
	for _, m := range in {
		if _, dup := seen[m.ID]; dup {
			continue
		}
		seen[m.ID] = struct{}{}
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func dedupeStrings(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if s == "" {
			continue
		}
		if _, dup := seen[s]; dup {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	sort.Strings(out)
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

func boolPtr(v bool) *bool { return &v }
