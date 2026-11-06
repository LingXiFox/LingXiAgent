// Dev-only stand-in for the Rust side, used when the UI runs in a plain
// browser. It mirrors the builtin node kinds but makes no execution
// guarantees: real runs always go through the Rust runtime.

import type { Transport } from "./transport";
import type {
  AgentConfigRevision,
  AgentConfigSnapshot,
  AgentEvent,
  ConfigChange,
  ConversationMessage,
  ConversationRecord,
  FileEntry,
  FileMatch,
  FileSnapshot,
  GitCommit,
  GitEntry,
  NodeSpec,
  PermissionAuditRecord,
  ProjectOpenResponse,
  ProjectRecord,
  RunDetail,
  SkillSummary,
  RunEvent,
  RunStartResponse,
  TaskSession,
  TemplateBundle,
  TemplateSummary,
  ValidationIssue,
  ValidationReport,
  WorkflowDoc,
  WorkflowSummary,
} from "./types";

const mockPreviews = new Map<string, string>();

function mockAsset(name: string, kind: string, mime: string, size: number) {
  let hash = 0;
  for (let index = 0; index < name.length; index += 1) {
    hash = (hash * 31 + name.charCodeAt(index)) >>> 0;
  }
  const sha = hash.toString(16).padStart(8, "0").repeat(8).slice(0, 64);
  return {
    id: "asset-" + sha,
    name,
    mime,
    size,
    sha256: sha,
    kind: kind as "image" | "audio" | "video" | "document",
    source: "browser-file",
    metadata: {},
  };
}

function mockPlaceholder(kind: string, name: string): string {
  const palette: Record<string, string> = { image: "#3f6f8f", audio: "#6f5a3f", video: "#4f3f6f", document: "#3f5f4f" };
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="96"><rect width="100%" height="100%" fill="' + (palette[kind] ?? "#333") + '"/><text x="80" y="54" font-size="11" fill="#fff" text-anchor="middle" font-family="sans-serif">' + name.replace(/[<>&]/g, "") + '</text></svg>';
  return "data:image/svg+xml;base64," + btoa(svg);
}

function readFileDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error ?? new Error("read failed"));
    reader.readAsDataURL(file);
  });
}

const rawSpecs: NodeSpec[] = [
  {
    kind: "core.text_input",
    title: "Text Input",
    category: "Input",
    description: "Emits a fixed text value.",
    inputs: [],
    outputs: [{ name: "text", label: "Text", dataType: "text", required: false }],
    params: [
      { name: "text", label: "Text", kind: "text_area", defaultValue: "", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.number_input",
    title: "Number Input",
    category: "Input",
    description: "Emits a fixed number.",
    inputs: [],
    outputs: [{ name: "number", label: "Number", dataType: "number", required: false }],
    params: [
      { name: "value", label: "Value", kind: "number", defaultValue: 0, required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.text_uppercase",
    title: "Uppercase",
    category: "Text",
    description: "Converts the incoming text to upper case.",
    inputs: [{ name: "text", label: "Text", dataType: "text", required: true }],
    outputs: [{ name: "text", label: "Text", dataType: "text", required: false }],
    params: [],
    capabilities: [],
  },
  {
    kind: "core.text_concat",
    title: "Concat",
    category: "Text",
    description: "Joins two text inputs with an optional separator.",
    inputs: [
      { name: "a", label: "A", dataType: "text", required: true },
      { name: "b", label: "B", dataType: "text", required: true },
    ],
    outputs: [{ name: "text", label: "Text", dataType: "text", required: false }],
    params: [
      { name: "separator", label: "Separator", kind: "text", defaultValue: " ", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.number_add",
    title: "Add",
    category: "Number",
    description: "Adds two numbers.",
    inputs: [
      { name: "a", label: "A", dataType: "number", required: true },
      { name: "b", label: "B", dataType: "number", required: true },
    ],
    outputs: [{ name: "number", label: "Number", dataType: "number", required: false }],
    params: [],
    capabilities: [],
  },
  {
    kind: "core.boolean_input",
    title: "Boolean Input",
    category: "Input",
    description: "Emits a fixed boolean value.",
    inputs: [],
    outputs: [{ name: "boolean", label: "Boolean", dataType: "boolean", required: false }],
    params: [
      { name: "value", label: "Value", kind: "boolean", defaultValue: false, required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.condition",
    title: "Condition",
    category: "Control",
    description: "Routes the payload to exactly one Boolean branch.",
    control: "branch",
    inputs: [
      { name: "condition", label: "Condition", dataType: "boolean", required: true },
      { name: "payload", label: "Payload", dataType: "any", required: false },
    ],
    outputs: [
      { name: "true", label: "True", dataType: "any", required: false, control: true },
      { name: "false", label: "False", dataType: "any", required: false, control: true },
    ],
    params: [],
    capabilities: [],
  },
  {
    kind: "core.loop_gate",
    title: "Loop Gate",
    category: "Control",
    description: "Drives a user-defined loop with an iteration and time budget.",
    control: "loop_gate",
    inputs: [
      { name: "start", label: "Start", dataType: "any", required: false, control: true },
      { name: "next", label: "Next", dataType: "any", required: false, control: true },
      { name: "stop", label: "Stop", dataType: "any", required: false, control: true },
      { name: "value", label: "Value", dataType: "any", required: false },
    ],
    outputs: [
      { name: "continue", label: "Continue", dataType: "any", required: false, control: true },
      { name: "exit", label: "Exit", dataType: "any", required: false, control: true },
      { name: "value", label: "Value", dataType: "any", required: false },
    ],
    params: [
      { name: "maxIterations", label: "Max iterations", kind: "number", defaultValue: 10, required: false, options: [] },
      { name: "timeoutMs", label: "Timeout (ms)", kind: "number", defaultValue: 60000, required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.counter",
    title: "Counter",
    category: "Logic",
    description: "Increments the incoming value and reports when a threshold is reached.",
    inputs: [{ name: "value", label: "Value", dataType: "number", required: false }],
    outputs: [
      { name: "number", label: "Number", dataType: "number", required: false },
      { name: "done", label: "Done", dataType: "boolean", required: false },
    ],
    params: [
      { name: "start", label: "Start", kind: "number", defaultValue: 0, required: false, options: [] },
      { name: "step", label: "Step", kind: "number", defaultValue: 1, required: false, options: [] },
      { name: "threshold", label: "Threshold", kind: "number", defaultValue: 3, required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.log",
    title: "Log",
    category: "Output",
    description: "Writes the incoming value to the run log.",
    inputs: [
      { name: "value", label: "Value", dataType: "any", required: true },
      { name: "run", label: "Run", dataType: "any", required: false, control: true },
    ],
    outputs: [{ name: "text", label: "Text", dataType: "text", required: false }],
    params: [
      { name: "prefix", label: "Prefix", kind: "text", defaultValue: "", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.approval",
    title: "Approval Gate",
    category: "Control",
    description: "Blocks the run until the user approves or rejects the step.",
    inputs: [{ name: "payload", label: "Payload", dataType: "any", required: false }],
    outputs: [{ name: "payload", label: "Payload", dataType: "any", required: false }],
    params: [
      {
        name: "prompt",
        label: "Prompt",
        kind: "text_area",
        defaultValue: "Approve this step?",
        required: false,
        options: [],
      },
    ],
    capabilities: ["interaction"],
  },
  {
    kind: "core.provider",
    title: "Provider",
    category: "Agent",
    description: "Declares an OpenAI-compatible model service. Secrets are referenced, never stored here.",
    inputs: [],
    outputs: [
      { name: "provider", label: "Provider", dataType: "text", required: false },
      { name: "config", label: "Config", dataType: "json", required: false },
    ],
    params: [
      { name: "providerId", label: "Provider ID", kind: "text", defaultValue: "openai", required: false, options: [] },
      { name: "baseUrl", label: "Base URL", kind: "text", defaultValue: "http://127.0.0.1:11434/v1", required: false, options: [] },
      { name: "credentialRef", label: "Credential", kind: "text", defaultValue: "env:OPENAI_API_KEY", required: false, options: [] },
      { name: "organization", label: "Organization", kind: "text", defaultValue: "", required: false, options: [] },
      { name: "supportsReasoning", label: "Reasoning support", kind: "boolean", defaultValue: true, required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.model",
    title: "Model",
    category: "Agent",
    description: "Calls one chat completion. Emits text, tool calls and a done control signal.",
    inputs: [
      { name: "run", label: "Run", dataType: "any", required: false, control: true },
      { name: "provider", label: "Provider", dataType: "text", required: true },
      { name: "context", label: "Context", dataType: "json", required: false },
      { name: "messages", label: "Messages", dataType: "json", required: false },
      { name: "toolset", label: "Tool Set", dataType: "text", required: false },
      { name: "reasoning", label: "Reasoning", dataType: "json", required: false },
      { name: "assets", label: "Media", dataType: "any", required: false },
    ],
    outputs: [
      { name: "text", label: "Text", dataType: "text", required: false },
      { name: "toolCalls", label: "Tool Calls", dataType: "json", required: false },
      { name: "hasToolCalls", label: "Has Tool Calls", dataType: "boolean", required: false },
      { name: "assistant", label: "Assistant Message", dataType: "json", required: false },
      { name: "usage", label: "Usage", dataType: "json", required: false },
      { name: "capabilities", label: "Capabilities", dataType: "json", required: false },
      { name: "reasoningSummary", label: "Reasoning Summary", dataType: "text", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "model", label: "Model", kind: "text", defaultValue: "llama3.2", required: false, options: [] },
      { name: "temperature", label: "Temperature", kind: "number", defaultValue: 0.7, required: false, options: [] },
      { name: "maxTokens", label: "Max Output Tokens", kind: "number", defaultValue: 1024, required: false, options: [] },
      { name: "reasoningEffort", label: "Reasoning Effort", kind: "select", defaultValue: "none", required: false, options: [{ value: "none", label: "None" }, { value: "low", label: "Low" }, { value: "medium", label: "Medium" }, { value: "high", label: "High" }] },
      { name: "stream", label: "Streaming", kind: "boolean", defaultValue: true, required: false, options: [] },
      { name: "timeoutMs", label: "Timeout (ms)", kind: "number", defaultValue: 60000, required: false, options: [] },
      { name: "maxCalls", label: "Max Calls", kind: "number", defaultValue: 8, required: false, options: [] },
      { name: "maxTotalTokens", label: "Max Total Tokens", kind: "number", defaultValue: 0, required: false, options: [] },
      { name: "capabilities", label: "Capability Overrides (JSON)", kind: "text_area", defaultValue: "{}", required: false, options: [] },
    ],
    capabilities: ["network", "credential"],
  },
  {
    kind: "core.prompt",
    title: "Prompt",
    category: "Agent",
    description: "Builds system/user messages from templates and upstream inputs.",
    inputs: [
      { name: "run", label: "Run", dataType: "any", required: false, control: true },
      { name: "input", label: "Input", dataType: "any", required: false },
      { name: "skill", label: "Skill", dataType: "text", required: false },
    ],
    outputs: [
      { name: "system", label: "System", dataType: "text", required: false },
      { name: "user", label: "User", dataType: "text", required: false },
      { name: "messages", label: "Messages", dataType: "json", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "system", label: "System Prompt", kind: "text_area", defaultValue: "You are a concise, helpful assistant. Use tools when they are needed.", required: false, options: [] },
      { name: "user", label: "User Prompt", kind: "text_area", defaultValue: "{{input}}", required: false, options: [] },
      { name: "variables", label: "Variables (JSON)", kind: "text", defaultValue: "{}", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.context",
    title: "Context",
    category: "Agent",
    description: "Owns the per-run message history. Each activation appends assistant/tool messages or initializes it.",
    inputs: [
      { name: "run", label: "Run", dataType: "any", required: false, control: true },
      { name: "messages", label: "Initial Messages", dataType: "json", required: false },
      { name: "assistant", label: "Assistant Message", dataType: "json", required: false },
      { name: "toolResults", label: "Tool Results", dataType: "json", required: false },
    ],
    outputs: [
      { name: "context", label: "Context", dataType: "json", required: false },
      { name: "handle", label: "Handle", dataType: "text", required: false },
      { name: "messages", label: "Messages", dataType: "json", required: false },
      { name: "trimmed", label: "Trimmed", dataType: "number", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "maxMessages", label: "Max Messages", kind: "number", defaultValue: 40, required: false, options: [] },
      { name: "maxTokens", label: "Max Estimated Tokens", kind: "number", defaultValue: 12000, required: false, options: [] },
      { name: "overflow", label: "Overflow Policy", kind: "select", defaultValue: "trim_oldest", required: false, options: [{ value: "trim_oldest", label: "Trim oldest" }, { value: "error", label: "Fail the run" }] },
    ],
    capabilities: [],
  },
  {
    kind: "core.tool_set",
    title: "Tool Set",
    category: "Tools",
    description: "Publishes a named tool set for a model and the dispatcher.",
    inputs: [{ name: "mcp", label: "MCP Tools", dataType: "json", required: false }],
    outputs: [
      { name: "toolset", label: "Tool Set", dataType: "text", required: false },
      { name: "tools", label: "Tools", dataType: "json", required: false },
      { name: "names", label: "Names", dataType: "json", required: false },
    ],
    params: [
      { name: "builtins", label: "Builtin tools", kind: "text", defaultValue: "calculator,text_transform,json_query", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.tool_dispatch",
    title: "Tool Dispatcher",
    category: "Tools",
    description: "Validates and executes model tool calls, one result per call id.",
    inputs: [
      { name: "run", label: "Run", dataType: "any", required: false, control: true },
      { name: "toolset", label: "Tool Set", dataType: "text", required: true },
      { name: "calls", label: "Tool Calls", dataType: "json", required: true },
    ],
    outputs: [
      { name: "results", label: "Results", dataType: "json", required: false },
      { name: "summary", label: "Summary", dataType: "text", required: false },
      { name: "failed", label: "Any Failed", dataType: "boolean", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [],
    capabilities: ["interaction"],
  },
  {
    kind: "core.mcp_server",
    title: "MCP Server",
    category: "Tools",
    description: "Connects to a local stdio or Streamable HTTP MCP server and discovers its tools.",
    inputs: [{ name: "run", label: "Run", dataType: "any", required: false, control: true }],
    outputs: [
      { name: "mcp", label: "MCP", dataType: "json", required: false },
      { name: "tools", label: "Tools", dataType: "json", required: false },
      { name: "handle", label: "Handle", dataType: "text", required: false },
      { name: "toolCount", label: "Tool Count", dataType: "number", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "transport", label: "Transport", kind: "select", defaultValue: "stdio", required: false, options: [{ value: "stdio", label: "stdio" }, { value: "http", label: "Streamable HTTP" }] },
      { name: "namespace", label: "Namespace", kind: "text", defaultValue: "local", required: false, options: [] },
      { name: "command", label: "Command", kind: "text", defaultValue: "python3", required: false, options: [] },
      { name: "args", label: "Arguments", kind: "text_area", defaultValue: "test-mcp-server.py", required: false, options: [] },
      { name: "url", label: "HTTP URL", kind: "text", defaultValue: "http://127.0.0.1:8765/mcp", required: false, options: [] },
      { name: "credentialRef", label: "Credential", kind: "text", defaultValue: "", required: false, options: [] },
    ],
    capabilities: ["process", "network", "interaction"],
  },
  {
    kind: "core.skill",
    title: "Skill",
    category: "Agent",
    description: "Loads a local SKILL.md and exposes its instructions as a system message.",
    inputs: [
      { name: "run", label: "Run", dataType: "any", required: false, control: true },
      { name: "input", label: "Input", dataType: "any", required: false },
    ],
    outputs: [
      { name: "skill", label: "Skill", dataType: "text", required: false },
      { name: "messages", label: "Messages", dataType: "json", required: false },
      { name: "resources", label: "Resources", dataType: "json", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "skillId", label: "Skill ID", kind: "text", defaultValue: "text-stats", required: false, options: [] },
    ],
    capabilities: ["filesystem", "interaction"],
  },
  {
    kind: "core.provider.openai_responses",
    title: "OpenAI Responses",
    category: "Agent",
    description: "Declares an OpenAI Responses API service. Secrets stay in credential references.",
    inputs: [],
    outputs: [
      { name: "provider", label: "Provider", dataType: "text", required: false },
      { name: "config", label: "Config", dataType: "json", required: false },
    ],
    params: [
      { name: "providerId", label: "Provider ID", kind: "text", defaultValue: "openai", required: false, options: [] },
      { name: "baseUrl", label: "Base URL", kind: "text", defaultValue: "https://api.openai.com/v1", required: false, options: [] },
      { name: "credentialRef", label: "Credential", kind: "text", defaultValue: "env:OPENAI_API_KEY", required: false, options: [] },
      { name: "organization", label: "Organization", kind: "text", defaultValue: "", required: false, options: [] },
      { name: "protocol", label: "Protocol", kind: "select", defaultValue: "openai_responses", required: false, options: [{ value: "openai_responses", label: "OpenAI Responses" }] },
      { name: "capabilities", label: "Capability Overrides (JSON)", kind: "text_area", defaultValue: "{}", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.provider.anthropic_messages",
    title: "Anthropic Messages",
    category: "Agent",
    description: "Declares an Anthropic Messages API service with x-api-key authentication.",
    inputs: [],
    outputs: [
      { name: "provider", label: "Provider", dataType: "text", required: false },
      { name: "config", label: "Config", dataType: "json", required: false },
    ],
    params: [
      { name: "providerId", label: "Provider ID", kind: "text", defaultValue: "anthropic", required: false, options: [] },
      { name: "baseUrl", label: "Base URL", kind: "text", defaultValue: "https://api.anthropic.com", required: false, options: [] },
      { name: "credentialRef", label: "Credential", kind: "text", defaultValue: "env:ANTHROPIC_API_KEY", required: false, options: [] },
      { name: "protocol", label: "Protocol", kind: "select", defaultValue: "anthropic_messages", required: false, options: [{ value: "anthropic_messages", label: "Anthropic Messages" }] },
      { name: "capabilities", label: "Capability Overrides (JSON)", kind: "text_area", defaultValue: "{}", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.provider.openai_chat",
    title: "OpenAI Chat",
    category: "Agent",
    description: "Declares an OpenAI Chat Completions compatible service.",
    inputs: [],
    outputs: [
      { name: "provider", label: "Provider", dataType: "text", required: false },
      { name: "config", label: "Config", dataType: "json", required: false },
    ],
    params: [
      { name: "providerId", label: "Provider ID", kind: "text", defaultValue: "openai", required: false, options: [] },
      { name: "baseUrl", label: "Base URL", kind: "text", defaultValue: "http://127.0.0.1:11434/v1", required: false, options: [] },
      { name: "credentialRef", label: "Credential", kind: "text", defaultValue: "env:OPENAI_API_KEY", required: false, options: [] },
      { name: "organization", label: "Organization", kind: "text", defaultValue: "", required: false, options: [] },
      { name: "protocol", label: "Protocol", kind: "select", defaultValue: "openai_chat", required: false, options: [{ value: "openai_chat", label: "OpenAI Chat Completions" }] },
      { name: "capabilities", label: "Capability Overrides (JSON)", kind: "text_area", defaultValue: "{}", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.reasoning",
    title: "Reasoning",
    category: "Agent",
    description: "Chooses a reasoning level and maps it through the model protocol.",
    inputs: [
      { name: "run", label: "Run", dataType: "any", required: false, control: true },
      { name: "level", label: "Level Override", dataType: "text", required: false },
      { name: "capabilities", label: "Capabilities", dataType: "json", required: false },
    ],
    outputs: [
      { name: "config", label: "Config", dataType: "json", required: false },
      { name: "level", label: "Level", dataType: "text", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "level", label: "Reasoning Level", kind: "select", defaultValue: "auto", required: false, options: [
        { value: "off", label: "Off" }, { value: "auto", label: "Auto" }, { value: "low", label: "Low" },
        { value: "medium", label: "Medium" }, { value: "high", label: "High" }, { value: "xhigh", label: "Extra high" },
      ] },
    ],
    capabilities: [],
  },
  {
    kind: "core.input.image",
    title: "Image Input",
    category: "Media",
    description: "Imports local images as multimodal content parts.",
    inputs: [{ name: "run", label: "Run", dataType: "any", required: false, control: true }],
    outputs: [
      { name: "parts", label: "Parts", dataType: "json", required: false },
      { name: "images", label: "Images", dataType: "image", required: false },
      { name: "count", label: "Count", dataType: "number", required: false },
      { name: "summary", label: "Summary", dataType: "text", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "assets", label: "Images", kind: "asset", defaultValue: [], required: false, options: [] },
      { name: "maxDimension", label: "Max dimension", kind: "number", defaultValue: 2048, required: false, options: [] },
      { name: "detail", label: "Detail", kind: "select", defaultValue: "auto", required: false, options: [{ value: "auto", label: "Auto" }, { value: "low", label: "Low" }, { value: "high", label: "High" }] },
    ],
    capabilities: [],
  },
  {
    kind: "core.input.audio",
    title: "Audio Input",
    category: "Media",
    description: "Imports audio natively or as an explicit transcript.",
    inputs: [{ name: "run", label: "Run", dataType: "any", required: false, control: true }],
    outputs: [
      { name: "parts", label: "Parts", dataType: "json", required: false },
      { name: "assets", label: "Assets", dataType: "audio", required: false },
      { name: "count", label: "Count", dataType: "number", required: false },
      { name: "summary", label: "Summary", dataType: "text", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "assets", label: "Audio", kind: "asset", defaultValue: [], required: false, options: [] },
      { name: "mode", label: "Mode", kind: "select", defaultValue: "native", required: false, options: [{ value: "native", label: "Native audio" }, { value: "transcribed", label: "Transcript" }] },
      { name: "transcript", label: "Transcript", kind: "text_area", defaultValue: "", required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.input.video",
    title: "Video Input",
    category: "Media",
    description: "Extracts timestamped frames or sends native video when supported.",
    inputs: [{ name: "run", label: "Run", dataType: "any", required: false, control: true }],
    outputs: [
      { name: "parts", label: "Parts", dataType: "json", required: false },
      { name: "frames", label: "Frames", dataType: "image", required: false },
      { name: "count", label: "Count", dataType: "number", required: false },
      { name: "summary", label: "Summary", dataType: "text", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "assets", label: "Video", kind: "asset", defaultValue: [], required: false, options: [] },
      { name: "mode", label: "Mode", kind: "select", defaultValue: "frames", required: false, options: [{ value: "frames", label: "Frame extraction" }, { value: "native", label: "Native video" }] },
      { name: "frameIntervalMs", label: "Frame interval (ms)", kind: "number", defaultValue: 1000, required: false, options: [] },
      { name: "maxFrames", label: "Max frames", kind: "number", defaultValue: 8, required: false, options: [] },
      { name: "startMs", label: "Start (ms)", kind: "number", defaultValue: 0, required: false, options: [] },
      { name: "endMs", label: "End (ms)", kind: "number", defaultValue: 0, required: false, options: [] },
    ],
    capabilities: [],
  },
  {
    kind: "core.input.document",
    title: "Document Input",
    category: "Media",
    description: "Extracts text from PDF, DOCX, TXT or Markdown.",
    inputs: [{ name: "run", label: "Run", dataType: "any", required: false, control: true }],
    outputs: [
      { name: "parts", label: "Parts", dataType: "json", required: false },
      { name: "text", label: "Text", dataType: "text", required: false },
      { name: "pages", label: "Pages", dataType: "number", required: false },
      { name: "summary", label: "Summary", dataType: "text", required: false },
      { name: "done", label: "Done", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "assets", label: "Documents", kind: "asset", defaultValue: [], required: false, options: [] },
      { name: "mode", label: "Mode", kind: "select", defaultValue: "extracted", required: false, options: [{ value: "native", label: "Native document" }, { value: "extracted", label: "Extracted text" }] },
    ],
    capabilities: [],
  },
  {
    kind: "core.agent",
    title: "Agent",
    category: "Agent",
    description: "Autonomous agent with tools, budgets and a structured result.",
    inputs: [
      { name: "provider", label: "Provider", dataType: "json", required: false, group: "Capabilities" },
      { name: "toolset", label: "ToolSet", dataType: "json", required: false, group: "Capabilities" },
      { name: "systemPrompt", label: "System Prompt", dataType: "text", required: false, group: "Instructions" },
      { name: "rolePrompt", label: "Role Prompt", dataType: "text", required: false, group: "Instructions" },
      { name: "userPrompt", label: "User Prompt", dataType: "text", required: false, group: "Instructions" },
      { name: "task", label: "Task", dataType: "json", required: false, group: "Collaboration" },
      { name: "messages", label: "Messages", dataType: "json", required: false, group: "Collaboration" },
      { name: "workspace", label: "Project Workspace", dataType: "text", required: false, group: "Control" },
      { name: "start", label: "Start", dataType: "any", required: false, control: true, group: "Control" },
      { name: "budget", label: "Budget", dataType: "json", required: false, group: "Control" },
    ],
    outputs: [
      { name: "agentMessage", label: "Agent Message", dataType: "json", required: false, group: "Result" },
      { name: "userResponse", label: "User Response", dataType: "text", required: false, group: "Result" },
      { name: "artifacts", label: "Artifacts", dataType: "json", required: false, group: "Result" },
      { name: "executionState", label: "Execution State", dataType: "json", required: false, group: "Result" },
      { name: "completed", label: "Completed", dataType: "any", required: false, control: true, group: "Control" },
      { name: "blocked", label: "Blocked", dataType: "any", required: false, control: true, group: "Control" },
      { name: "failed", label: "Failed", dataType: "any", required: false, control: true, group: "Control" },
    ],
    params: [
      { name: "model", label: "Model", kind: "text", defaultValue: "mock-agent", required: true, options: [] },
      { name: "rolePrompt", label: "Role", kind: "text_area", defaultValue: "", required: false, options: [] },
      { name: "instruction", label: "Instruction", kind: "text_area", defaultValue: "", required: false, options: [] },
      { name: "maxIterations", label: "Max Iterations", kind: "number", defaultValue: 12, required: false, options: [] },
      { name: "maxToolCalls", label: "Max Tool Calls", kind: "number", defaultValue: 48, required: false, options: [] },
      {
        name: "permissionMode",
        label: "Permission Mode",
        kind: "select",
        defaultValue: "ask",
        required: false,
        options: [
          { value: "ask", label: "Ask" },
          { value: "workspace", label: "Workspace" },
          { value: "yolo", label: "YOLO" },
        ],
      },
    ],
    capabilities: ["network"],
  },
  {
    kind: "core.project_workspace",
    title: "项目工作区",
    category: "Workspace",
    description: "Binds a real project folder to an opaque workspace handle.",
    inputs: [
      { name: "projectId", label: "Project Id", dataType: "text", required: false },
      { name: "cwd", label: "Relative CWD", dataType: "text", required: false },
      { name: "policy", label: "Access Policy", dataType: "json", required: false },
    ],
    outputs: [
      { name: "workspace", label: "Workspace", dataType: "text", required: false },
      { name: "project", label: "Project", dataType: "json", required: false },
      { name: "metadata", label: "Metadata", dataType: "json", required: false },
      { name: "ready", label: "Ready", dataType: "any", required: false, control: true },
    ],
    params: [
      { name: "projectId", label: "Project Id", kind: "text", defaultValue: "", required: true, options: [] },
      { name: "cwd", label: "Relative CWD", kind: "text", defaultValue: "", required: false, options: [] },
      { name: "showIgnored", label: "Show Ignored", kind: "boolean", defaultValue: false, required: false, options: [] },
    ],
    capabilities: ["filesystem"],
  },
  {
    kind: "core.composite",
    title: "Composite",
    category: "组合",
    description: "Groups nodes into an expandable subgraph.",
    inputs: [],
    outputs: [],
    params: [],
    capabilities: [],
  },
];

const specs: NodeSpec[] = rawSpecs.map((spec) => ({
  ...spec,
  control: spec.control ?? "normal",
  inputs: spec.inputs.map((port) => ({ ...port, control: port.control ?? false })),
  outputs: spec.outputs.map((port) => ({ ...port, control: port.control ?? false })),
}));

const specByKind = new Map(specs.map((spec) => [spec.kind, spec]));

type WithoutSeq<T> = T extends unknown ? Omit<T, "seq"> : never;
type RunEventInput = WithoutSeq<RunEvent>;

function reportFor(workflow: WorkflowDoc, issues: ValidationIssue[]): ValidationReport {
  const errors = issues.filter((issue) => issue.severity === "error").length;
  return {
    ok: errors === 0,
    schemaVersion: workflow.schemaVersion,
    nodeCount: workflow.nodes.length,
    edgeCount: workflow.edges.length,
    errors,
    warnings: issues.length - errors,
    issues,
  };
}

function usesControlFlow(workflow: WorkflowDoc): boolean {
  return (
    workflow.nodes.some((node) => {
      const control = specByKind.get(node.kind)?.control;
      return control === "branch" || control === "loop_gate";
    }) || workflow.edges.some((edge) => edge.kind === "control")
  );
}

function validate(workflow: WorkflowDoc): ValidationReport {
  const issues: ValidationIssue[] = [];
  const ids = new Set<string>();
  workflow.nodes.forEach((node, index) => {
    if (ids.has(node.id)) {
      issues.push({
        code: "node.duplicate_id",
        severity: "error",
        path: "nodes[" + index + "].id",
        message: "duplicate node id " + node.id,
      });
    }
    ids.add(node.id);
    if (!specByKind.has(node.kind)) {
      issues.push({
        code: "node.unknown_kind",
        severity: "error",
        path: "nodes[" + index + "].kind",
        message: "unknown node kind " + node.kind,
      });
    }
  });
  workflow.edges.forEach((edge) => {
    if (!ids.has(edge.source) || !ids.has(edge.target)) {
      issues.push({
        code: "edge.dangling_target",
        severity: "error",
        path: "edges." + edge.id,
        message: "edge references a node that is not in the workflow",
      });
    }
  });
  return reportFor(workflow, issues);
}

function inputOf(
  nodeId: string,
  port: string,
  workflow: WorkflowDoc,
  outputs: Map<string, Record<string, unknown>>,
): unknown {
  const edge = workflow.edges.find(
    (candidate) => candidate.target === nodeId && candidate.targetPort === port,
  );
  if (!edge) return undefined;
  return outputs.get(edge.source)?.[edge.sourcePort];
}

const MOCK_CREDENTIAL_PREFIX = "lingxi.mock.credential.";

function mockAgentTemplate(): TemplateBundle {
  const empty = (): WorkflowDoc => ({
    schemaVersion: "1.1",
    id: "wf-sg-agent-react",
    name: "标准 ReAct Agent",
    description: "",
    nodes: [],
    edges: [],
    metadata: {},
  });
  const workflow = empty();
  workflow.nodes = [
    {
      id: "provider",
      kind: "core.provider",
      label: "Provider",
      position: { x: 20, y: 360 },
      params: {
        providerId: "openai",
        baseUrl: "http://127.0.0.1:11434/v1",
        credentialRef: "env:OPENAI_API_KEY",
        organization: "",
        supportsReasoning: true,
      },
      enabled: true,
    },
    {
      id: "prompt",
      kind: "core.prompt",
      label: "Prompt",
      position: { x: 20, y: 140 },
      params: {
        system: "You are a concise, helpful assistant. Use tools when they are needed.",
        user: "{{input}}",
        variables: "{}",
      },
      enabled: true,
    },
    {
      id: "model",
      kind: "core.model",
      label: "Model",
      position: { x: 360, y: 140 },
      params: {
        model: "mock-calculator",
        temperature: 0.2,
        maxTokens: 1024,
        reasoningEffort: "none",
        stream: true,
        timeoutMs: 60000,
        maxCalls: 8,
        maxTotalTokens: 0,
      },
      enabled: true,
    },
    {
      id: "log",
      kind: "core.log",
      label: "Final Answer",
      position: { x: 700, y: 140 },
      params: { prefix: "" },
      enabled: true,
    },
  ];
  workflow.edges = [
    { id: "prompt:done->model:run", source: "prompt", sourcePort: "done", target: "model", targetPort: "run", kind: "control" },
    { id: "prompt:messages->model:messages", source: "prompt", sourcePort: "messages", target: "model", targetPort: "messages", kind: "data" },
    { id: "provider:provider->model:provider", source: "provider", sourcePort: "provider", target: "model", targetPort: "provider", kind: "data" },
    { id: "model:text->log:value", source: "model", sourcePort: "text", target: "log", targetPort: "value", kind: "data" },
  ];
  return {
    rootId: "sg-agent-react",
    subgraphs: {
      "sg-agent-react": {
        id: "sg-agent-react",
        version: 1,
        name: "标准 ReAct Agent",
        description: "Browser preview of the standard agent. Real execution is Rust-only.",
        workflow,
        inputs: [
          {
            port: { name: "start", label: "Start", dataType: "any", required: false, control: true },
            targets: [{ nodeId: "prompt", port: "run" }],
          },
          {
            port: { name: "text", label: "Input", dataType: "any", required: false },
            targets: [{ nodeId: "prompt", port: "input" }],
          },
        ],
        outputs: [
          {
            port: { name: "answer", label: "Answer", dataType: "text", required: false },
            source: { nodeId: "log", port: "text" },
          },
        ],
      },
    },
  };
}

const TEMPLATE_PREFIX = "lingxi.templates.";
const MOCK_RUNS_KEY = "lingxi.mock.runs";
const MOCK_SESSIONS_KEY = "lingxi.mock.sessions";

function loadMockRuns(): [string, RunDetail][] {
  try {
    const raw = window.localStorage.getItem(MOCK_RUNS_KEY);
    return raw ? (JSON.parse(raw) as [string, RunDetail][]) : [];
  } catch {
    return [];
  }
}

function loadMockSessions(): [string, TaskSession][] {
  try {
    const raw = window.localStorage.getItem(MOCK_SESSIONS_KEY);
    return raw ? (JSON.parse(raw) as [string, TaskSession][]) : [];
  } catch {
    return [];
  }
}

function mockCsv(value: unknown): string[] {
  if (Array.isArray(value)) return value.map(String).filter(Boolean);
  if (typeof value !== "string") return [];
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function mockNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function mockAgentConfig(node: WorkflowDoc["nodes"][number]): AgentConfigSnapshot {
  return {
    revision: 0,
    model: typeof node.params.model === "string" ? node.params.model : "mock-agent",
    temperature: mockNumber(node.params.temperature, 0.2),
    reasoning: typeof node.params.reasoning === "string" ? node.params.reasoning : "auto",
    rolePrompt: typeof node.params.rolePrompt === "string" ? node.params.rolePrompt : "",
    systemPrompt: typeof node.params.systemPrompt === "string" ? node.params.systemPrompt : "",
    maxIterations: mockNumber(node.params.maxIterations, 12),
    maxToolCalls: mockNumber(node.params.maxToolCalls, 48),
    maxTotalTokens: mockNumber(node.params.maxTotalTokens, 0),
    timeoutMs: mockNumber(node.params.timeoutMs, 300000),
    toolset: mockCsv(node.params.toolset),
    skills: mockCsv(node.params.skills),
    lsp: mockCsv(node.params.lsp),
  };
}

const AGENT_CONFIG_FIELDS: (keyof AgentConfigSnapshot)[] = [
  "model",
  "temperature",
  "reasoning",
  "rolePrompt",
  "systemPrompt",
  "maxIterations",
  "maxToolCalls",
  "maxTotalTokens",
  "timeoutMs",
  "toolset",
  "skills",
  "lsp",
];

function mockConfigDiff(
  before: AgentConfigSnapshot,
  after: AgentConfigSnapshot,
): ConfigChange[] {
  return AGENT_CONFIG_FIELDS.filter(
    (field) => JSON.stringify(before[field]) !== JSON.stringify(after[field]),
  ).map((field) => ({ field, before: before[field], after: after[field] }));
}

interface MockTemplateFile {
  name: string;
  bundle: TemplateBundle;
}

export function createMockTransport(): Transport {
  const files = new Map<string, WorkflowDoc>();
  const templateFiles = new Map<string, MockTemplateFile>();
  const listeners = new Set<(event: RunEvent) => void>();
  const pending = new Map<string, (approved: boolean) => void>();
  const runs = new Map<string, RunDetail>(loadMockRuns());
  const sessions = new Map<string, TaskSession>(loadMockSessions());
  const pausedRuns = new Set<string>();
  const pausedAgents = new Set<string>();
  let counter = 0;

  // The browser mock has no Rust backend to reconnect to. Persisting the
  // simulated session keeps a WebView refresh from wiping the workbench in UI
  // tests; native runs always recover from SQLite instead.
  const persistRuns = () => {
    try {
      window.localStorage.setItem(MOCK_RUNS_KEY, JSON.stringify([...runs.entries()]));
    } catch {
      // Quota failures must not break the simulated run.
    }
  };
  const persistSessions = () => {
    try {
      window.localStorage.setItem(MOCK_SESSIONS_KEY, JSON.stringify([...sessions.entries()]));
    } catch {
      // Quota failures must not break the simulated run.
    }
  };

  const emit = (event: RunEvent) => {
    for (const listener of listeners) listener(event);
  };

  const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  const templateSummary = (id: string, name: string, bundle: TemplateBundle): TemplateSummary => {
    const root = bundle.subgraphs[bundle.rootId];
    return {
      id,
      name,
      nodeCount: root?.workflow.nodes.length ?? 0,
      inputCount: root?.inputs.length ?? 0,
      outputCount: root?.outputs.length ?? 0,
      updatedAtMs: Date.now(),
    };
  };

  const templateKey = (id: string) => TEMPLATE_PREFIX + id;

  const saveMockTemplate = (name: string, bundle: TemplateBundle): TemplateSummary => {
    const id = name.trim();
    if (!id) throw new Error("template name must not be empty");
    const file = { name: id, bundle };
    localStorage.setItem(templateKey(id), JSON.stringify(file));
    templateFiles.set(id, file);
    return templateSummary(id, id, bundle);
  };

  const readMockTemplate = (id: string): TemplateBundle => {
    const cached = templateFiles.get(id);
    if (cached) return cached.bundle;
    const raw = localStorage.getItem(templateKey(id));
    if (!raw) throw new Error("template not found: " + id);
    const file = JSON.parse(raw) as MockTemplateFile;
    templateFiles.set(id, file);
    return file.bundle;
  };

  // Browser-only project fixture. The real desktop app always resolves the
  // folder through Rust and enforces workspace boundaries there.
  const mockProject: ProjectRecord = {
    projectId: "proj-mock-demo",
    name: "lingxi-demo",
    root: "/mock/lingxi-demo",
    createdAtMs: Date.now(),
    updatedAtMs: Date.now(),
    lastOpenedAtMs: Date.now(),
  };
  const mockFiles = new Map<string, string>([
    ["README.md", "# LingXi Demo\n\nA tiny project used by browser previews.\n"],
    ["AGENTS.md", "Keep changes focused and run the tests before reporting success.\n"],
    ["package.json", '{\n  "name": "lingxi-demo",\n  "private": true\n}\n'],
    ["src/main.ts", 'export function greet(name: string) {\n  return "hello " + name;\n}\n'],
    ["src/lib/util.ts", "export const answer = 42;\n"],
  ]);
  const mockVersions = new Map<string, string>();
  const versionOf = (content: string) => {
    let hash = 2166136261;
    for (let index = 0; index < content.length; index += 1) {
      hash ^= content.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16).padStart(8, "0");
  };
  const snapshot = (path: string): FileSnapshot => {
    const content = mockFiles.get(path);
    if (content === undefined) throw new Error("workspace.file_not_found: " + path);
    const version = mockVersions.get(path) ?? versionOf(content);
    mockVersions.set(path, version);
    return { path, version, content, bytes: content.length };
  };
  const mockTree = (path: string): FileEntry[] => {
    const prefix = path ? path.replace(/\/$/, "") + "/" : "";
    const names = new Map<string, FileEntry>();
    for (const file of mockFiles.keys()) {
      if (!file.startsWith(prefix)) continue;
      const rest = file.slice(prefix.length);
      const slash = rest.indexOf("/");
      const name = slash === -1 ? rest : rest.slice(0, slash);
      const childPath = prefix + name;
      if (names.has(childPath)) continue;
      if (slash === -1) {
        names.set(childPath, {
          path: childPath,
          name,
          kind: "file",
          size: (mockFiles.get(childPath) ?? "").length,
          version: mockVersions.get(childPath) ?? versionOf(mockFiles.get(childPath) ?? ""),
        });
      } else {
        names.set(childPath, { path: childPath, name, kind: "dir", size: 0, version: null });
      }
    }
    return [...names.values()].sort((left, right) =>
      left.kind === right.kind ? left.name.localeCompare(right.name) : left.kind === "dir" ? -1 : 1,
    );
  };
  // The browser preview has no Rust database, so mirror the durable session
  // store in localStorage. This keeps refresh/reload tests honest about the
  // UI restoring a saved conversation instead of keeping state only in React.
  const MOCK_SESSION_KEY = "lingxi.mock.sessions.v1";
  const loadMockConversationState = (): {
    conversations: ConversationRecord[];
    messages: Record<string, ConversationMessage[]>;
  } => {
    if (typeof window === "undefined") return { conversations: [], messages: {} };
    try {
      const raw = window.localStorage.getItem(MOCK_SESSION_KEY);
      if (!raw) return { conversations: [], messages: {} };
      const parsed = JSON.parse(raw) as {
        conversations?: ConversationRecord[];
        messages?: Record<string, ConversationMessage[]>;
      };
      return {
        conversations: Array.isArray(parsed.conversations) ? parsed.conversations : [],
        messages: parsed.messages ?? {},
      };
    } catch {
      return { conversations: [], messages: {} };
    }
  };
  const storedConversations = loadMockConversationState();
  const conversations = new Map<string, ConversationRecord>(
    storedConversations.conversations.map((record) => [record.conversationId, record]),
  );
  const conversationMessages = new Map<string, ConversationMessage[]>(
    Object.entries(storedConversations.messages),
  );
  const persistMockSessions = () => {
    if (typeof window === "undefined") return;
    try {
      window.localStorage.setItem(
        MOCK_SESSION_KEY,
        JSON.stringify({
          conversations: [...conversations.values()],
          messages: Object.fromEntries(conversationMessages),
        }),
      );
    } catch {
      // A locked-down webview can refuse storage; the preview still works in memory.
    }
  };
  let conversationCounter = conversations.size;

  const mockWorkflow = (projectId: string, mode: string): WorkflowDoc => {
    const suffix = (conversationCounter + 1).toString(36);
    const projectNode = "project-" + suffix;
    const agentNode = "agent-" + suffix;
    const logNode = "log-" + suffix;
    return {
      schemaVersion: "1.1",
      id: "wf-mock-" + suffix,
      name: "新建 Agent 会话",
      description: "",
      nodes: [
        {
          id: projectNode,
          kind: "core.project_workspace",
          position: { x: 40, y: 160 },
          params: { projectId, cwd: "" },
          enabled: true,
        },
        {
          id: agentNode,
          kind: "core.agent",
          position: { x: 360, y: 120 },
          params: {
            model: "gpt-4o-mini",
            reasoning: "auto",
            permissionMode: mode,
            instruction: "",
            recipient: "user",
          },
          enabled: true,
        },
        {
          id: logNode,
          kind: "core.log",
          position: { x: 720, y: 180 },
          params: { prefix: "agent: " },
          enabled: true,
        },
      ],
      edges: [
        { id: projectNode + ":workspace->" + agentNode + ":workspace", source: projectNode, sourcePort: "workspace", target: agentNode, targetPort: "workspace", kind: "data" },
        { id: projectNode + ":ready->" + agentNode + ":start", source: projectNode, sourcePort: "ready", target: agentNode, targetPort: "start", kind: "control" },
        { id: agentNode + ":userResponse->" + logNode + ":value", source: agentNode, sourcePort: "userResponse", target: logNode, targetPort: "value", kind: "data" },
        { id: agentNode + ":completed->" + logNode + ":run", source: agentNode, sourcePort: "completed", target: logNode, targetPort: "run", kind: "control" },
      ],
      viewport: { x: 0, y: 0, zoom: 1 },
      metadata: { projectId },
    };
  };

  const newConversation = (title: string, workflow?: WorkflowDoc): ConversationRecord => {
    conversationCounter += 1;
    const now = Date.now();
    const record: ConversationRecord = {
      conversationId: "conv-mock-" + conversationCounter,
      projectId: mockProject.projectId,
      title,
      workflow: workflow ?? mockWorkflow(mockProject.projectId, "ask"),
      createdAtMs: now,
      updatedAtMs: now,
    };
    conversations.set(record.conversationId, record);
    conversationMessages.set(record.conversationId, []);
    persistMockSessions();
    return record;
  };

  return {
    async listNodeSpecs() {
      return specs;
    },

    async validateWorkflow(workflow) {
      return validate(workflow);
    },

    async runWorkflow(workflow, options): Promise<RunStartResponse> {
      // Templates are cloned with fresh subgraph ids, so recognise the agent
      // preview by its shape rather than by the definition id.
      const agent = workflow.nodes.find((node) => {
        if (node.kind !== "core.composite" || !node.subgraphId) return false;
        return (
          workflow.subgraphs?.[node.subgraphId]?.workflow.nodes.some(
            (inner) => inner.kind === "core.model",
          ) ?? false
        );
      });
      const agentNodes = workflow.nodes.filter(
        (node) => node.kind === "core.agent" && node.enabled !== false,
      );
      if (!agent && agentNodes.length === 0 && usesControlFlow(workflow)) {
        const report = reportFor(workflow, [
          {
            code: "mock.control_flow_unsupported",
            severity: "error",
            path: "workflow",
            message:
              "control flow is executed by the Rust runtime; the browser preview cannot run this workflow",
          },
        ]);
        return { started: false, runId: null, report };
      }
      const report = validate(workflow);
      if (!report.ok) {
        return { started: false, runId: null, report };
      }
      const runId = "mock-" + ++counter;
      if (options?.conversationId && options.userMessage) {
        const history = conversationMessages.get(options.conversationId) ?? [];
        history.push({
          messageId: "user-" + runId,
          conversationId: options.conversationId,
          runId,
          agentNodeId: null,
          agentInstanceId: null,
          role: "user",
          content: options.userMessage,
          createdAtMs: Date.now(),
        });
        conversationMessages.set(options.conversationId, history);
        persistMockSessions();
      }
      if (options?.conversationId) {
        const conversationId = options.conversationId;
        window.setTimeout(() => {
          const history = conversationMessages.get(conversationId) ?? [];
          history.push({
            messageId: runId + ":activation-1",
            conversationId,
            runId,
            agentNodeId: agentNodes[0]?.id ?? null,
            agentInstanceId: null,
            role: "assistant",
            content:
              "我读取了项目目录。主要结构：`src/main.ts` 是入口，`src/lib/util.ts` 提供工具函数，`package.json` 描述项目。浏览器预览中的执行是模拟的，桌面版会用 Rust 工具读取真实文件。",
            createdAtMs: Date.now(),
          });
          conversationMessages.set(conversationId, history);
          persistMockSessions();
        }, 400);
      }
      const runEvents: RunEvent[] = [];
      let seq = 0;
      const emitRun = (event: RunEventInput) => {
        const sequenced = { ...event, seq: seq++ } as RunEvent;
        runEvents.push(sequenced);
        emit(sequenced);
        const checkpoint = runs.get(runId);
        if (checkpoint) {
          runs.set(runId, { ...checkpoint, events: [...runEvents] });
          persistRuns();
        }
      };
      void (async () => {
        const outputs = new Map<string, Record<string, unknown>>();
        let cancelled = false;
        let finished = false;
        const startedAt = Date.now();
        const finish = (status: "completed" | "failed" | "cancelled", detail: string | null) => {
          finished = true;
          const finishedAt = Date.now();
          const durationMs = finishedAt - startedAt;
          emitRun({
            type: "run.finished",
            runId,
            status,
            cause: status === "failed" ? "node_failed" : status === "cancelled" ? "cancelled" : null,
            detail,
            durationMs,
          });
          runs.set(runId, {
            run: {
              runId,
              workflowId: workflow.id,
              workflowName: workflow.name,
              status,
              cause:
                status === "failed"
                  ? "node_failed"
                  : status === "cancelled"
                    ? "cancelled"
                    : null,
              detail,
              startedAtMs: startedAt,
              finishedAtMs: finishedAt,
              durationMs,
              nodeCount: workflow.nodes.length,
              lastSeq: runEvents.length - 1,
            },
            workflow,
            events: [...runEvents],
          });
          persistRuns();
        };
        stopHandlers.set(runId, () => {
          cancelled = true;
        });
        emitRun({
          type: "run.started",
          runId,
          workflowId: workflow.id,
          workflowName: workflow.name,
          nodeCount: workflow.nodes.length,
        });
        runs.set(runId, {
          run: {
            runId,
            workflowId: workflow.id,
            workflowName: workflow.name,
            status: "running",
            cause: null,
            detail: null,
            startedAtMs: startedAt,
            finishedAtMs: null,
            durationMs: null,
            nodeCount: workflow.nodes.length,
            lastSeq: runEvents.length - 1,
          },
          workflow,
          events: [...runEvents],
        });
        persistRuns();
        if (agent) {
          const label = agent.label?.trim() || "标准 ReAct Agent";
          emitRun({ type: "node.started", runId, nodeId: agent.id, kind: agent.kind, label, activation: 1 });
          emitRun({ type: "model.delta", runId, nodeId: agent.id, label, delta: "正在调用模型…" });
          await delay(120);
          emitRun({
            type: "tool.started",
            runId,
            nodeId: agent.id,
            label,
            toolCallId: "call_1",
            toolName: "calculator",
            arguments: "{\"expression\":\"128 * 256\"}",
          });
          await delay(120);
          emitRun({
            type: "tool.finished",
            runId,
            nodeId: agent.id,
            label,
            toolCallId: "call_1",
            toolName: "calculator",
            ok: true,
            durationMs: 1,
            error: null,
            result: "32768",
          });
          emitRun({ type: "model.delta", runId, nodeId: agent.id, label, delta: "The answer is 32768." });
          emitRun({
            type: "log",
            runId,
            atMs: Date.now(),
            level: "info",
            nodeId: agent.id,
            message: "The answer is 32768.",
          });
          emitRun({
            type: "node.finished",
            runId,
            nodeId: agent.id,
            kind: agent.kind,
            label,
            outputs: { answer: "The answer is 32768." },
            durationMs: 240,
            activation: 1,
          });
          stopHandlers.delete(runId);
          if (!finished) finish("completed", null);
          return;
        }
        if (agentNodes.length > 0) {
          const createdAtMs = Date.now();
          const session: TaskSession = {
            sessionId: "session-" + runId,
            runId,
            workflowId: workflow.id,
            workflowName: workflow.name,
            workflowRevision: 1,
            state: "running",
            createdAtMs,
            updatedAtMs: createdAtMs,
            agents: {},
            messages: [],
            pendingReviews: [],
            artifacts: [],
          };
          sessions.set(runId, session);
          persistSessions();
          const agentEvent = (event: AgentEvent) => {
            emitRun({ type: "agent.event", runId, event });
            persistSessions();
          };
          for (const node of agentNodes) {
            if (cancelled) break;
            const label = node.label?.trim() || specByKind.get("core.agent")?.title || "Agent";
            const instanceId = "agent:" + runId + ":" + node.id;
            const config = mockAgentConfig(node);
            let instance = session.agents[instanceId];
            if (!instance) {
              instance = {
                instanceId,
                nodeId: node.id,
                label,
                scope: [],
                state: "pending",
                currentActivation: null,
                activations: [],
                config,
                configRevisions: [],
                usage: {
                  iterations: 0,
                  modelCalls: 0,
                  toolCalls: 0,
                  promptTokens: 0,
                  completionTokens: 0,
                  elapsedMs: 0,
                },
                pendingDirectives: [],
                createdAtMs: Date.now(),
                updatedAtMs: Date.now(),
              };
              session.agents[instanceId] = instance;
              agentEvent({
                type: "agent.registered",
                agentInstanceId: instanceId,
                nodeId: node.id,
                label,
                scope: [],
                state: "pending",
                config,
              });
            }
            const activationIndex = instance.activations.length + 1;
            const activationId = instanceId + "#activation-" + activationIndex;
            instance.currentActivation = activationId;
            instance.state = "running";
            instance.updatedAtMs = Date.now();
            instance.activations.push({
              activationId,
              index: activationIndex,
              state: "running",
              startedAtMs: Date.now(),
              finishedAtMs: null,
              configRevision: instance.config.revision,
              iterations: 0,
              userResponse: null,
              agentMessageId: null,
              error: null,
            });
            emitRun({
              type: "node.started",
              runId,
              nodeId: node.id,
              kind: node.kind,
              label,
              activation: activationIndex,
            });
            agentEvent({
              type: "agent.activation.started",
              agentInstanceId: instanceId,
              activationId,
              index: activationIndex,
              configRevision: instance.config.revision,
            });
            agentEvent({
              type: "agent.state",
              agentInstanceId: instanceId,
              activationId,
              state: "running",
              reason: "mock preview iteration",
            });
            // Keep mock agent work visible long enough for a human or an E2E
            // test to pause it, while staying far below the 20s wait budget.
            await delay(900);
            agentEvent({
              type: "agent.delta",
              agentInstanceId: instanceId,
              activationId,
              delta: label + " is working on: " + String(node.params.instruction ?? "the assigned task"),
            });
            await delay(700);
            while (!cancelled && (pausedRuns.has(runId) || pausedAgents.has(instanceId))) {
              await delay(80);
            }
            const usage = {
              iterations: 1,
              modelCalls: 1,
              toolCalls: 0,
              promptTokens: 48,
              completionTokens: 24,
              elapsedMs: Date.now() - instance.updatedAtMs + 460,
            };
            const toolName = instance.config.toolset[0];
            if (toolName) {
              usage.toolCalls = 1;
              const toolCallId = "call-" + instanceId + "-" + activationIndex;
              agentEvent({
                type: "agent.tool.started",
                agentInstanceId: instanceId,
                activationId,
                toolCallId,
                toolName,
                arguments: JSON.stringify({ path: "mock-preview.txt" }),
              });
              await delay(120);
              agentEvent({
                type: "agent.tool.finished",
                agentInstanceId: instanceId,
                activationId,
                toolCallId,
                toolName,
                ok: true,
                durationMs: 120,
                error: null,
                result: JSON.stringify({ ok: true, path: "mock-preview.txt" }),
              });
            }
            // A pause requested while the model/tool step was in flight takes
            // effect before the result is committed, matching the runner rule.
            while (!cancelled && (pausedRuns.has(runId) || pausedAgents.has(instanceId))) {
              await delay(80);
            }
            if (cancelled) {
              const activation = instance.activations[activationIndex - 1];
              activation.state = "cancelled";
              activation.finishedAtMs = Date.now();
              activation.error = "run cancelled";
              instance.state = "cancelled";
              instance.updatedAtMs = Date.now();
              agentEvent({
                type: "agent.state",
                agentInstanceId: instanceId,
                activationId,
                state: "cancelled",
                reason: "run cancelled",
              });
              emitRun({
                type: "node.cancelled",
                runId,
                nodeId: node.id,
                kind: node.kind,
                label,
                activation: activationIndex,
              });
              break;
            }
            const userResponse = label + " completed the mock preview task.";
            const message = {
              schemaVersion: "1.0",
              messageId: "msg-" + runId + "-" + node.id + "-" + activationIndex,
              taskId: "task-" + runId + "-" + node.id,
              sender: instanceId,
              recipient: "broadcast",
              type: "task.result",
              status: "queued",
              payload: {
                summary: userResponse,
                status: "completed",
                data: { value: userResponse },
              },
              artifactRefs: [],
              correlationId: null,
              idempotencyKey: null,
              createdAtMs: Date.now(),
            };
            session.messages.push(message);
            instance.usage = usage;
            instance.state = "completed";
            instance.currentActivation = null;
            instance.updatedAtMs = Date.now();
            const activation = instance.activations[activationIndex - 1];
            activation.state = "completed";
            activation.finishedAtMs = Date.now();
            activation.iterations = 1;
            activation.userResponse = userResponse;
            activation.agentMessageId = message.messageId;
            agentEvent({ type: "agent.message", agentInstanceId: instanceId, message });
            agentEvent({ type: "agent.usage", agentInstanceId: instanceId, usage });
            agentEvent({
              type: "agent.activation.finished",
              agentInstanceId: instanceId,
              activationId,
              state: "completed",
              usage,
              userResponse,
              messageId: message.messageId,
              error: null,
            });
            emitRun({
              type: "node.finished",
              runId,
              nodeId: node.id,
              kind: node.kind,
              label,
              outputs: {
                agentMessage: message,
                userResponse,
                artifacts: [],
                executionState: { state: "completed" },
                completed: true,
              },
              durationMs: 460,
              activation: activationIndex,
            });
          }
          session.state = cancelled ? "cancelled" : "completed";
          session.updatedAtMs = Date.now();
          persistSessions();
          stopHandlers.delete(runId);
          if (!finished) finish(cancelled ? "cancelled" : "completed", null);
          return;
        }
        for (const node of workflow.nodes) {
          if (cancelled) {
            emitRun({
              type: "node.cancelled",
              runId,
              nodeId: node.id,
              kind: node.kind,
              label: node.label ?? node.kind,
              activation: 1,
            });
            break;
          }
          const spec = specByKind.get(node.kind);
          if (!spec) continue;
          const label = node.label?.trim() || spec.title;
          if (!node.enabled) {
            emitRun({
              type: "node.skipped",
              runId,
              nodeId: node.id,
              kind: node.kind,
              label,
              reason: "node is disabled",
              activation: 1,
            });
            continue;
          }
          emitRun({ type: "node.started", runId, nodeId: node.id, kind: node.kind, label, activation: 1 });
          await delay(240);
          if (node.kind === "core.approval") {
            const requestId = "req-" + ++counter;
            emitRun({
              type: "interaction.requested",
              runId,
              requestId,
              nodeId: node.id,
              prompt: String(node.params.prompt ?? "Approve this step?"),
              options: [
                { value: "approve", label: "Approve" },
                { value: "reject", label: "Reject" },
              ],
            });
            const approved = await new Promise<boolean>((resolve) => pending.set(requestId, resolve));
            emitRun({
              type: "interaction.resolved",
              runId,
              requestId,
              nodeId: node.id,
              decision: approved ? "approved" : "rejected",
            });
            if (!approved) {
              emitRun({
                type: "node.failed",
                runId,
                nodeId: node.id,
                kind: node.kind,
                label,
                code: "node.interaction_denied",
                message: "approval was rejected",
                durationMs: 0,
                activation: 1,
              });
              finish("failed", "approval was rejected");
              return;
            }
          }
          const out: Record<string, unknown> = {};
          switch (node.kind) {
            case "core.text_input":
              out.text = String(node.params.text ?? "");
              break;
            case "core.number_input":
              out.number = Number(node.params.value ?? 0);
              break;
            case "core.text_uppercase":
              out.text = String(inputOf(node.id, "text", workflow, outputs) ?? "").toUpperCase();
              break;
            case "core.text_concat":
              out.text =
                String(inputOf(node.id, "a", workflow, outputs) ?? "") +
                String(node.params.separator ?? "") +
                String(inputOf(node.id, "b", workflow, outputs) ?? "");
              break;
            case "core.number_add":
              out.number =
                Number(inputOf(node.id, "a", workflow, outputs) ?? 0) +
                Number(inputOf(node.id, "b", workflow, outputs) ?? 0);
              break;
            case "core.log": {
              const value = inputOf(node.id, "value", workflow, outputs);
              emitRun({
                type: "log",
                runId,
                atMs: Date.now(),
                level: "info",
                nodeId: node.id,
                message: String(node.params.prefix ?? "") + String(value ?? ""),
              });
              break;
            }
            case "core.approval":
              out.payload = inputOf(node.id, "payload", workflow, outputs) ?? null;
              break;
            default:
              break;
          }
          outputs.set(node.id, out);
          emitRun({
            type: "node.finished",
            runId,
            nodeId: node.id,
            kind: node.kind,
            label,
            outputs: out,
            durationMs: 240,
            activation: 1,
          });
        }
        stopHandlers.delete(runId);
        if (!finished) finish(cancelled ? "cancelled" : "completed", null);
      })();
      return { started: true, runId, report };
    },

    async stopWorkflow(runId) {
      const stop = stopHandlers.get(runId);
      if (!stop) return false;
      stop();
      return true;
    },

    async pauseWorkflow(runId) {
      const session = sessions.get(runId);
      if (!session) return false;
      pausedRuns.add(runId);
      session.state = "paused";
      session.updatedAtMs = Date.now();
      persistSessions();
      return true;
    },

    async resumeWorkflow(runId) {
      const session = sessions.get(runId);
      if (!session) return false;
      pausedRuns.delete(runId);
      session.state = "running";
      session.updatedAtMs = Date.now();
      persistSessions();
      return true;
    },

    async pauseAgent(runId, agentInstanceId) {
      const instance = sessions.get(runId)?.agents[agentInstanceId];
      if (!instance) throw new Error("agent " + agentInstanceId + " is not part of run " + runId);
      pausedAgents.add(agentInstanceId);
      instance.state = "paused";
      instance.updatedAtMs = Date.now();
      persistSessions();
    },

    async resumeAgent(runId, agentInstanceId) {
      const instance = sessions.get(runId)?.agents[agentInstanceId];
      if (!instance) throw new Error("agent " + agentInstanceId + " is not part of run " + runId);
      pausedAgents.delete(agentInstanceId);
      instance.state = "running";
      instance.updatedAtMs = Date.now();
      persistSessions();
    },

    async cancelAgent(runId, agentInstanceId) {
      const instance = sessions.get(runId)?.agents[agentInstanceId];
      if (!instance) throw new Error("agent " + agentInstanceId + " is not part of run " + runId);
      pausedAgents.delete(agentInstanceId);
      instance.state = "cancelled";
      instance.updatedAtMs = Date.now();
      persistSessions();
    },

    async sendAgentDirective(runId, agentInstanceId, text) {
      const instance = sessions.get(runId)?.agents[agentInstanceId];
      if (!instance) throw new Error("agent " + agentInstanceId + " is not part of run " + runId);
      const trimmed = text.trim();
      if (!trimmed) throw new Error("directive must not be empty");
      instance.pendingDirectives.push(trimmed);
      instance.updatedAtMs = Date.now();
      persistSessions();
    },

    async previewAgentConfig(runId, agentInstanceId, config) {
      const instance = sessions.get(runId)?.agents[agentInstanceId];
      if (!instance) throw new Error("agent " + agentInstanceId + " is not part of run " + runId);
      return mockConfigDiff(instance.config, config);
    },

    async applyAgentConfig(runId, agentInstanceId, config, expectedRevision) {
      const instance = sessions.get(runId)?.agents[agentInstanceId];
      if (!instance) throw new Error("agent " + agentInstanceId + " is not part of run " + runId);
      if (instance.config.revision !== expectedRevision) {
        throw new Error(
          "config revision " + expectedRevision + " is stale; current revision is " + instance.config.revision,
        );
      }
      const before = instance.config;
      const after = { ...config, revision: before.revision + 1 };
      const revision: AgentConfigRevision = {
        revision: after.revision,
        status: "applied",
        appliedAtMs: Date.now(),
        before,
        after,
        changes: mockConfigDiff(before, after),
        detail: "applied in the browser preview",
      };
      for (const previous of instance.configRevisions) {
        if (previous.status === "pending") previous.status = "superseded";
      }
      instance.configRevisions.push(revision);
      instance.config = after;
      instance.updatedAtMs = Date.now();
      persistSessions();
      return revision;
    },

    async rejectAgentConfig(runId, agentInstanceId, revision, detail) {
      const instance = sessions.get(runId)?.agents[agentInstanceId];
      if (!instance) throw new Error("agent " + agentInstanceId + " is not part of run " + runId);
      const target = instance.configRevisions.find((entry) => entry.revision === revision);
      if (!target) throw new Error("config revision " + revision + " was not found");
      target.status = "rejected";
      target.detail = detail;
      instance.updatedAtMs = Date.now();
      persistSessions();
    },

    async taskSession(runId) {
      const session = sessions.get(runId);
      if (!session) return null;
      return JSON.parse(JSON.stringify(session)) as TaskSession;
    },

    async respondInteraction(requestId, approved) {
      const resolve = pending.get(requestId);
      if (!resolve) return false;
      pending.delete(requestId);
      resolve(approved);
      return true;
    },

    async workflowList(): Promise<WorkflowSummary[]> {
      return [...files.entries()].map(([name, workflow]) => ({
        name,
        nodeCount: workflow.nodes.length,
        updatedAtMs: Date.now(),
      }));
    },

    async saveWorkflow(name, workflow) {
      const document = { ...workflow, name };
      files.set(name, document);
      return { name, nodeCount: document.nodes.length, updatedAtMs: Date.now() };
    },

    async loadWorkflow(name) {
      const document = files.get(name);
      if (!document) throw new Error("workflow " + name + " not found");
      return document;
    },

    async deleteWorkflow(name) {
      return files.delete(name);
    },

    async templateList() {
      const summaries: TemplateSummary[] = [];
      for (let index = 0; index < localStorage.length; index += 1) {
        const key = localStorage.key(index);
        if (!key?.startsWith(TEMPLATE_PREFIX)) continue;
        try {
          const file = JSON.parse(localStorage.getItem(key) ?? "") as MockTemplateFile;
          summaries.push(templateSummary(key.slice(TEMPLATE_PREFIX.length), file.name, file.bundle));
        } catch {
          // Ignore corrupt browser-preview entries.
        }
      }
      return summaries.sort((a, b) => b.updatedAtMs - a.updatedAtMs);
    },

    async templateLoad(id) {
      return readMockTemplate(id);
    },

    async templateSave(name, bundle) {
      return saveMockTemplate(name, bundle);
    },

    async templateDelete(id) {
      templateFiles.delete(id);
      const existed = localStorage.getItem(templateKey(id)) !== null;
      localStorage.removeItem(templateKey(id));
      return existed;
    },

    async runList(limit) {
      return [...runs.values()]
        .map((detail) => detail.run)
        .sort((a, b) => b.startedAtMs - a.startedAtMs)
        .slice(0, limit ?? 50);
    },

    async runDetail(runId) {
      return runs.get(runId) ?? null;
    },

    async runEvents(runId, afterSeq) {
      const detail = runs.get(runId);
      if (!detail) return [];
      return detail.events.filter((event) => afterSeq === undefined || event.seq > afterSeq);
    },

    async activeRun() {
      for (const detail of runs.values()) {
        if (detail.run.status === "running") return detail;
      }
      return null;
    },

    async onRunEvent(handler) {
      // Each subscription needs its own identity: React StrictMode mounts and
      // unmounts effects with the same callback reference, and a late cleanup
      // from the first mount would otherwise remove the second subscription.
      const subscription = (event: RunEvent) => handler(event);
      listeners.add(subscription);
      return () => {
        listeners.delete(subscription);
      };
    },

    async credentialStatus(reference) {
      return localStorage.getItem(MOCK_CREDENTIAL_PREFIX + reference) !== null;
    },

    async credentialSet(name) {
      const reference = "keyring:" + name;
      localStorage.setItem(MOCK_CREDENTIAL_PREFIX + reference, "set");
      return reference;
    },

    async credentialDelete(name) {
      const reference = name.startsWith("keyring:") ? name : "keyring:" + name;
      localStorage.removeItem(MOCK_CREDENTIAL_PREFIX + reference);
      return true;
    },

    async providerModels(_baseUrl, _credentialRef, protocol) {
      if (protocol === "anthropic_messages") return ["claude-sonnet-4-5", "claude-opus-4-1"];
      if (protocol === "openai_responses") return ["gpt-5", "gpt-4.1"];
      return ["mock-calculator", "mock-final", "mock-stream", "gpt-4o"];
    },

    async modelCapabilities(protocol, model) {
      const anthropic = protocol === "anthropic_messages";
      const openai = protocol === "openai_responses" || protocol === "openai_chat";
      const vision = anthropic || /gpt-4o|gpt-4\.1|gpt-5/.test(model);
      const reasoning = anthropic || /^o[134]|gpt-5/.test(model);
      return {
        input: {
          text: "native",
          image: vision ? "native" : "unknown",
          audio: "preprocessed",
          video: "preprocessed",
          document: anthropic ? "native" : "preprocessed",
          maxImages: vision ? 8 : null,
          maxFileSize: 20 * 1024 * 1024,
          supportedMediaTypes: vision ? ["image/png", "image/jpeg", "image/webp"] : [],
        },
        output: { text: "native", image: "unsupported", audio: "unsupported" },
        features: {
          streaming: "native",
          toolCalling: openai || anthropic ? "native" : "unknown",
          reasoning: reasoning ? "native" : "unsupported",
          structuredOutput: openai ? "native" : "unknown",
        },
        limits: { maxContextTokens: anthropic ? 200000 : 128000, maxOutputTokens: anthropic ? 8192 : 16384 },
        reasoningLevels: reasoning ? ["off", "auto", "low", "medium", "high", "xhigh"] : ["off"],
        source: "builtin",
      };
    },

    async assetImport(path, kind) {
      const name = path.split("/").pop() ?? path;
      const mime = kind === "image" ? "image/png" : kind === "audio" ? "audio/mpeg" : kind === "video" ? "video/mp4" : "application/pdf";
      const asset = mockAsset(name, kind, mime, 1024);
      mockPreviews.set(asset.id, mockPlaceholder(kind, name));
      return asset;
    },

    async assetImportFile(file, kind) {
      const dataUrl = await readFileDataUrl(file);
      const asset = mockAsset(file.name, kind, file.type || "application/octet-stream", file.size);
      mockPreviews.set(asset.id, dataUrl);
      return asset;
    },

    async assetPreview(id) {
      return mockPreviews.get(id) ?? mockPlaceholder("image", id);
    },

    async respondHostInteraction() {
      return true;
    },

    async skillList(): Promise<SkillSummary[]> {
      return [
        {
          id: "text-stats",
          name: "Text statistics",
          description: "Counts words, lines and characters.",
          version: "1.0",
          path: "preview/text-stats/SKILL.md",
        },
      ];
    },

    async agentTemplate() {
      return mockAgentTemplate();
    },

    async pickProjectFolder() {
      return mockProject.root;
    },

    async projectList(): Promise<ProjectRecord[]> {
      return [mockProject];
    },

    async projectOpen(): Promise<ProjectOpenResponse> {
      return { project: mockProject, workspaceHandle: "ws-mock-demo", tree: mockTree(""), git: true };
    },

    async projectRemove() {
      return true;
    },

    async projectTree(_projectId, path, _showIgnored): Promise<FileEntry[]> {
      return mockTree(path ?? "");
    },

    async projectRead(_projectId, path): Promise<FileSnapshot> {
      return snapshot(path);
    },

    async projectWrite(_projectId, path, content, expectedVersion): Promise<FileSnapshot> {
      const current = mockFiles.get(path);
      const currentVersion = current === undefined ? "absent" : mockVersions.get(path) ?? versionOf(current);
      if (expectedVersion && expectedVersion !== currentVersion) {
        throw new Error("workspace.version_conflict: " + path);
      }
      mockFiles.set(path, content);
      const version = versionOf(content + ":" + Date.now());
      mockVersions.set(path, version);
      return { path, version, content, bytes: content.length };
    },

    async projectDelete(_projectId, path) {
      mockFiles.delete(path);
      mockVersions.delete(path);
      return true;
    },

    async projectSearch(_projectId, query, path, limit): Promise<FileMatch[]> {
      const prefix = path ? path.replace(/\/$/, "") + "/" : "";
      const matches: FileMatch[] = [];
      for (const [file, content] of mockFiles) {
        if (!file.startsWith(prefix)) continue;
        content.split("\n").forEach((text, index) => {
          if (text.toLowerCase().includes(query.toLowerCase()) && matches.length < (limit ?? 50)) {
            matches.push({ path: file, line: index + 1, text });
          }
        });
      }
      return matches;
    },

    async projectGitStatus(): Promise<GitEntry[]> {
      return [{ path: "src/main.ts", status: "M" }];
    },

    async projectGitDiff(_projectId, path): Promise<string> {
      return "diff --git a/" + (path ?? "src/main.ts") + "\n+// local change\n";
    },

    async projectGitLog(): Promise<GitCommit[]> {
      return [{ hash: "a1b2c3d", author: "LingXi", timestampMs: Date.now(), subject: "Initial demo project" }];
    },

    async projectRules() {
      return [{ path: "AGENTS.md", content: mockFiles.get("AGENTS.md") ?? "" }];
    },

    async projectReveal() {
      return true;
    },

    async conversationList(projectId): Promise<ConversationRecord[]> {
      return [...conversations.values()].filter((entry) => !projectId || entry.projectId === projectId);
    },

    async conversationCreate(projectId, title, workflow): Promise<ConversationRecord> {
      void projectId;
      return newConversation(title ?? "新会话", workflow);
    },

    async conversationCreateTeam(projectId, title): Promise<ConversationRecord> {
      void projectId;
      return newConversation(title ?? "公司团队");
    },

    async conversationGet(conversationId): Promise<ConversationRecord | null> {
      return conversations.get(conversationId) ?? null;
    },

    async conversationSaveWorkflow(conversationId, workflow, title): Promise<ConversationRecord> {
      const record = conversations.get(conversationId);
      if (!record) throw new Error("conversation not found");
      const next = { ...record, workflow, title: title ?? record.title, updatedAtMs: Date.now() };
      conversations.set(conversationId, next);
      persistMockSessions();
      return next;
    },

    async conversationMessages(conversationId): Promise<ConversationMessage[]> {
      // Copy the live array; returning it directly lets callers hold a reference
      // that later grows in place, which React cannot detect.
      return [...(conversationMessages.get(conversationId) ?? [])];
    },

    async permissionAudit(): Promise<PermissionAuditRecord[]> {
      return [];
    },

    async appendConversationMessage(conversationId, runId, agentNodeId, content) {
      const history = conversationMessages.get(conversationId) ?? [];
      history.push({
        messageId: "user-" + Date.now(),
        conversationId,
        runId,
        agentNodeId,
        agentInstanceId: null,
        role: "user",
        content,
        createdAtMs: Date.now(),
      });
      conversationMessages.set(conversationId, history);
      persistMockSessions();
      return true;
    },

    async setPermissionMode() {
      return true;
    },

    async onPersistenceError() {
      return () => {};
    },

    async onHostInteraction() {
      return () => {};
    },

    async onHostInteractionResolved() {
      return () => {};
    },
  };
}

const stopHandlers = new Map<string, () => void>();
