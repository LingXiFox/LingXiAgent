package discovery

import (
	"testing"
)

// TestOpenAIModelsAdapterNormalizesUpstreamList covers spec test A: an upstream
// listing returns A B C and the adapter normalizes exactly those.
func TestOpenAIModelsAdapterNormalizesUpstreamList(t *testing.T) {
	body := []byte(`{"object":"list","data":[
		{"id":"model-a","object":"model","created":1},
		{"id":"model-b","object":"model","created":2},
		{"id":"model-c","object":"model","created":3}
	]}`)

	got, err := openAIModelsAdapter{}.Parse(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 models, got %d", len(got))
	}
	for i, want := range []string{"model-a", "model-b", "model-c"} {
		if got[i].ID != want {
			t.Errorf("model %d: want id %q, got %q", i, want, got[i].ID)
		}
		if got[i].DisplayName == "" {
			t.Errorf("model %d: display name must fall back to the id", i)
		}
	}
}

// TestAdaptersNormalizeDifferentWireFormats covers spec test H: each provider's
// listing shape is absorbed in the adapter layer, so nothing downstream needs
// to know which product a listing came from.
func TestAdaptersNormalizeDifferentWireFormats(t *testing.T) {
	cases := []struct {
		name    string
		kind    string
		body    string
		wantIDs []string
	}{
		{
			name:    "openai",
			kind:    KindOpenAIModels,
			body:    `{"data":[{"id":"a"},{"id":"b"}]}`,
			wantIDs: []string{"a", "b"},
		},
		{
			name:    "openrouter",
			kind:    KindOpenRouterModels,
			body:    `{"data":[{"id":"x/y","name":"Y","context_length":1000,"supported_parameters":["tools","reasoning"]}]}`,
			wantIDs: []string{"x/y"},
		},
		{
			name:    "anthropic",
			kind:    KindAnthropicModels,
			body:    `{"data":[{"id":"claude-x","display_name":"Claude X","type":"model"}]}`,
			wantIDs: []string{"claude-x"},
		},
		{
			name:    "gemini",
			kind:    KindGeminiModels,
			body:    `{"models":[{"name":"models/gemini-x","displayName":"Gemini X"}]}`,
			wantIDs: []string{"gemini-x"},
		},
		{
			name:    "ollama",
			kind:    KindOllamaTags,
			body:    `{"models":[{"name":"llama3.2:latest","model":"llama3.2:latest"}]}`,
			wantIDs: []string{"llama3.2:latest"},
		},
		{
			name:    "plain-array-of-strings",
			kind:    KindPlainArray,
			body:    `["m1","m2"]`,
			wantIDs: []string{"m1", "m2"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			adapter, err := AdapterFor(tc.kind)
			if err != nil {
				t.Fatalf("adapter for %q: %v", tc.kind, err)
			}
			got, err := adapter.Parse([]byte(tc.body))
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			if len(got) != len(tc.wantIDs) {
				t.Fatalf("want %d models, got %d (%v)", len(tc.wantIDs), len(got), got)
			}
			for i, want := range tc.wantIDs {
				if got[i].ID != want {
					t.Errorf("model %d: want %q, got %q", i, want, got[i].ID)
				}
			}
		})
	}
}

// TestGeminiAdapterStripsCollectionPrefix guards the one normalization that is
// easy to get wrong: Gemini listings prefix every ID with "models/".
func TestGeminiAdapterStripsCollectionPrefix(t *testing.T) {
	got, err := geminiModelsAdapter{}.Parse([]byte(
		`{"models":[{"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","inputTokenLimit":1000000,"outputTokenLimit":65000}]}`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got[0].ID != "gemini-2.5-pro" {
		t.Errorf("want bare id %q, got %q", "gemini-2.5-pro", got[0].ID)
	}
	if got[0].UpstreamModelID != "models/gemini-2.5-pro" {
		t.Errorf("want verbatim upstreamModelID %q, got %q", "models/gemini-2.5-pro", got[0].UpstreamModelID)
	}
	if got[0].DisplayName != "Gemini 2.5 Pro" {
		t.Errorf("want clean displayName %q, got %q", "Gemini 2.5 Pro", got[0].DisplayName)
	}
	if got[0].Capabilities.ContextWindow == nil || *got[0].Capabilities.ContextWindow != 1000000 {
		t.Errorf("context window not carried through: %+v", got[0].Capabilities)
	}
}

// TestOpenRouterAdapterExtractsCapabilities checks that capability facts the
// upstream actually states are preserved rather than dropped.
func TestOpenRouterAdapterExtractsCapabilities(t *testing.T) {
	body := []byte(`{"data":[{"id":"vendor/model","name":"Model","context_length":200000,
		"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
		"top_provider":{"max_completion_tokens":8192},
		"supported_parameters":["tools","parallel_tool_calls","reasoning_effort","response_format"]}]}`)

	got, err := openRouterModelsAdapter{}.Parse(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	c := got[0].Capabilities
	if c.Vision == nil || !*c.Vision {
		t.Error("image input modality should set vision")
	}
	if c.ToolCalling == nil || !*c.ToolCalling {
		t.Error("tools parameter should set tool calling")
	}
	if c.ParallelToolCalling == nil || !*c.ParallelToolCalling {
		t.Error("parallel_tool_calls should set parallel tool calling")
	}
	if c.Reasoning == nil || !*c.Reasoning {
		t.Error("reasoning_effort should set reasoning")
	}
	if c.StructuredOutput == nil || !*c.StructuredOutput {
		t.Error("response_format should set structured output")
	}
	if c.ReasoningMode != "effort" {
		t.Errorf("want reasoning mode effort, got %q", c.ReasoningMode)
	}
}

// TestAdaptersProduceStableOrdering ensures a refresh over identical upstream
// data yields byte-identical results, so the catalog digest only moves when the
// upstream content actually changes.
func TestAdaptersProduceStableOrdering(t *testing.T) {
	body := []byte(`{"data":[{"id":"c"},{"id":"a"},{"id":"b"},{"id":"a"}]}`)
	first, err := openAIModelsAdapter{}.Parse(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	second, err := openAIModelsAdapter{}.Parse(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	want := []string{"a", "b", "c"}
	if len(first) != len(want) {
		t.Fatalf("duplicates not removed: got %d models", len(first))
	}
	for i := range want {
		if first[i].ID != want[i] || second[i].ID != want[i] {
			t.Fatalf("unstable ordering: %v / %v", first, second)
		}
	}
}

// TestAdapterForUnknownKindFailsLoudly ensures a typo in a discovery profile is
// reported rather than silently producing an empty model list.
func TestAdapterForUnknownKindFailsLoudly(t *testing.T) {
	if _, err := AdapterFor("no-such-kind"); err == nil {
		t.Fatal("expected an error for an unknown adapter kind")
	}
}
