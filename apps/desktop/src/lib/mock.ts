// Dev-only stand-in for the Rust side, used when the UI runs in a plain
// browser. It mirrors the builtin node kinds but makes no execution
// guarantees: real runs always go through the Rust runtime.

import type { Transport } from "./transport";
import type {
  NodeSpec,
  RunDetail,
  SkillSummary,
  RunEvent,
  RunStartResponse,
  TemplateBundle,
  TemplateSummary,
  ValidationIssue,
  ValidationReport,
  WorkflowDoc,
  WorkflowSummary,
} from "./types";

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
    ],
    outputs: [
      { name: "text", label: "Text", dataType: "text", required: false },
      { name: "toolCalls", label: "Tool Calls", dataType: "json", required: false },
      { name: "hasToolCalls", label: "Has Tool Calls", dataType: "boolean", required: false },
      { name: "assistant", label: "Assistant Message", dataType: "json", required: false },
      { name: "usage", label: "Usage", dataType: "json", required: false },
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

interface MockTemplateFile {
  name: string;
  bundle: TemplateBundle;
}

export function createMockTransport(): Transport {
  const files = new Map<string, WorkflowDoc>();
  const templateFiles = new Map<string, MockTemplateFile>();
  const listeners = new Set<(event: RunEvent) => void>();
  const pending = new Map<string, (approved: boolean) => void>();
  const runs = new Map<string, RunDetail>();
  let counter = 0;

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

  return {
    async listNodeSpecs() {
      return specs;
    },

    async validateWorkflow(workflow) {
      return validate(workflow);
    },

    async runWorkflow(workflow): Promise<RunStartResponse> {
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
      if (!agent && usesControlFlow(workflow)) {
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
      const runEvents: RunEvent[] = [];
      let seq = 0;
      const emitRun = (event: RunEventInput) => {
        const sequenced = { ...event, seq: seq++ } as RunEvent;
        runEvents.push(sequenced);
        emit(sequenced);
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

    async providerModels() {
      return ["mock-calculator", "mock-final", "mock-stream"];
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

    async onPersistenceError() {
      return () => {};
    },
  };
}

const stopHandlers = new Map<string, () => void>();
