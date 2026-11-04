// Wire types shared with the Rust crates. Field names mirror the serde
// camelCase contract in crates/lingxi-spec and crates/lingxi-runtime.

export type DataType =
  | "text"
  | "number"
  | "boolean"
  | "json"
  | "image"
  | "audio"
  | "video"
  | "document"
  | "any";

export type ParamKind = "text" | "text_area" | "number" | "boolean" | "select" | "asset";

export type ControlKind = "normal" | "branch" | "loop_gate";

export type EdgeKind = "data" | "control";

export interface ParamOption {
  value: string;
  label: string;
}

export interface ParamSpec {
  name: string;
  label: string;
  kind: ParamKind;
  defaultValue?: unknown;
  required: boolean;
  options: ParamOption[];
  help?: string | null;
}

export type AssetKind = "image" | "audio" | "video" | "document";

export interface AssetRef {
  id: string;
  name: string;
  mime: string;
  size: number;
  sha256: string;
  kind: AssetKind;
  source: string;
  metadata: Record<string, unknown>;
}

export type ProviderProtocol =
  | "openai_chat"
  | "openai_responses"
  | "anthropic_messages";

export interface PortSpec {
  name: string;
  label: string;
  dataType: DataType;
  required: boolean;
  /** Missing on older payloads means a data port. */
  control?: boolean;
}

export interface NodeSpec {
  kind: string;
  title: string;
  category: string;
  description: string;
  inputs: PortSpec[];
  outputs: PortSpec[];
  params: ParamSpec[];
  capabilities: string[];
  /** Missing on older payloads means a normal node. */
  control?: ControlKind;
}

export interface PositionDoc {
  x: number;
  y: number;
}

export interface WorkflowNodeDoc {
  id: string;
  kind: string;
  label?: string | null;
  position: PositionDoc;
  params: Record<string, unknown>;
  enabled: boolean;
  /** Present only on composite instances; points at a root subgraph definition. */
  subgraphId?: string;
}

export interface EdgeDoc {
  id: string;
  source: string;
  sourcePort: string;
  target: string;
  targetPort: string;
  kind: EdgeKind;
}

export interface ViewportDoc {
  x: number;
  y: number;
  zoom: number;
}

export interface WorkflowDoc {
  schemaVersion: string;
  id: string;
  name: string;
  description: string;
  nodes: WorkflowNodeDoc[];
  edges: EdgeDoc[];
  viewport?: ViewportDoc | null;
  metadata: Record<string, unknown>;
  /** Root-only definitions; a definition's own workflow never nests definitions. */
  subgraphs?: Record<string, Subgraph>;
  /** Root-only content-addressed media table. Large bytes never live here. */
  assets?: Record<string, AssetRef>;
}

export interface PortBindingDoc {
  nodeId: string;
  port: string;
  edgeId?: string;
}

export interface SubgraphInputDoc {
  port: PortSpec;
  targets: PortBindingDoc[];
}

export interface SubgraphOutputDoc {
  port: PortSpec;
  source: PortBindingDoc;
}

export interface Subgraph {
  id: string;
  version: number;
  name: string;
  description?: string | null;
  workflow: WorkflowDoc;
  inputs: SubgraphInputDoc[];
  outputs: SubgraphOutputDoc[];
}

export type Severity = "error" | "warning";

export interface ValidationIssue {
  code: string;
  severity: Severity;
  path: string;
  message: string;
}

export interface ValidationReport {
  ok: boolean;
  schemaVersion: string;
  nodeCount: number;
  edgeCount: number;
  errors: number;
  warnings: number;
  issues: ValidationIssue[];
}

export interface WorkflowSummary {
  name: string;
  nodeCount: number;
  updatedAtMs: number;
}

export interface TemplateSummary {
  id: string;
  name: string;
  nodeCount: number;
  inputCount: number;
  outputCount: number;
  updatedAtMs: number;
}

export interface SkillSummary {
  id: string;
  name: string;
  description: string;
  version?: string | null;
  path: string;
}

export interface TemplateBundle {
  rootId: string;
  subgraphs: Record<string, Subgraph>;
  assets?: Record<string, AssetRef>;
}

export interface RunStartResponse {
  started: boolean;
  runId: string | null;
  report: ValidationReport;
}

export type RunStatus = "completed" | "failed" | "cancelled" | "interrupted";

export type StoredRunStatus = "running" | RunStatus;

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface InteractionOption {
  value: string;
  label: string;
}

export interface ScopeFrame {
  instanceId: string;
  subgraphId: string;
  label: string;
}

interface RunEventBase {
  runId: string;
  /** Monotonic within a run; used for replay deduplication and gap recovery. */
  seq: number;
  /** Composite nesting stack, outermost first. Empty on top-level events. */
  scope?: ScopeFrame[];
}

export type RunEvent =
  | (RunEventBase & {
      type: "run.started";
      workflowId: string;
      workflowName: string;
      nodeCount: number;
    })
  | (RunEventBase & {
      type: "node.started";
      nodeId: string;
      kind: string;
      label: string;
      activation: number;
      iteration?: number;
    })
  | (RunEventBase & {
      type: "node.finished";
      nodeId: string;
      kind: string;
      label: string;
      outputs: Record<string, unknown>;
      durationMs: number;
      activation: number;
      iteration?: number;
    })
  | (RunEventBase & {
      type: "node.failed";
      nodeId: string;
      kind: string;
      label: string;
      code: string;
      message: string;
      durationMs: number;
      activation: number;
      iteration?: number;
    })
  | (RunEventBase & {
      type: "node.skipped";
      nodeId: string;
      kind: string;
      label: string;
      reason: string;
      activation: number;
      iteration?: number;
    })
  | (RunEventBase & {
      type: "node.cancelled";
      nodeId: string;
      kind: string;
      label: string;
      activation: number;
      iteration?: number;
    })
  | (RunEventBase & {
      type: "log";
      atMs: number;
      level: LogLevel;
      nodeId: string | null;
      message: string;
    })
  | (RunEventBase & {
      type: "interaction.requested";
      requestId: string;
      nodeId: string;
      prompt: string;
      options: InteractionOption[];
    })
  | (RunEventBase & {
      type: "interaction.resolved";
      requestId: string;
      nodeId: string;
      decision: "approved" | "rejected";
    })
  | (RunEventBase & {
      type: "model.delta";
      nodeId: string;
      label: string;
      delta: string;
    })
  | (RunEventBase & {
      type: "tool.started";
      nodeId: string;
      label: string;
      toolCallId: string;
      toolName: string;
      arguments: string;
    })
  | (RunEventBase & {
      type: "tool.finished";
      nodeId: string;
      label: string;
      toolCallId: string;
      toolName: string;
      ok: boolean;
      durationMs: number;
      error: string | null;
      result: string;
    })
  | (RunEventBase & {
      type: "run.finished";
      status: RunStatus;
      cause: string | null;
      detail: string | null;
      durationMs: number;
    });

export interface RunRecord {
  runId: string;
  workflowId: string;
  workflowName: string;
  status: StoredRunStatus;
  cause: string | null;
  detail: string | null;
  startedAtMs: number;
  finishedAtMs: number | null;
  durationMs: number | null;
  nodeCount: number;
  lastSeq: number;
}

export interface RunDetail {
  run: RunRecord;
  workflow: WorkflowDoc;
  events: RunEvent[];
}

export interface PersistenceError {
  runId: string;
  message: string;
}

export const RUN_EVENT_NAME = "lingxi:run-event";
export const PERSISTENCE_ERROR_NAME = "lingxi:persistence-error";
export const HOST_INTERACTION_NAME = "lingxi:host-interaction";
export const HOST_INTERACTION_RESOLVED_NAME = "lingxi:host-interaction-resolved";


export type Support = "native" | "preprocessed" | "unsupported" | "unknown";

export interface ModelCapabilities {
  input: {
    text: Support;
    image: Support;
    audio: Support;
    video: Support;
    document: Support;
    maxImages: number | null;
    maxFileSize: number | null;
    supportedMediaTypes: string[];
  };
  output: { text: Support; image: Support; audio: Support };
  features: { streaming: Support; toolCalling: Support; reasoning: Support; structuredOutput: Support };
  limits: { maxContextTokens: number | null; maxOutputTokens: number | null };
  reasoningLevels: string[];
  source: string;
}

export interface HostInteraction {
  requestId: string;
  runId: string;
  nodeId: string;
  prompt: string;
  options: { value: string; label: string }[];
}
