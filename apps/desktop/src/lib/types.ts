// Wire types shared with the Rust crates. Field names mirror the serde
// camelCase contract in crates/lingxi-spec and crates/lingxi-runtime.

export type DataType = "text" | "number" | "boolean" | "json" | "any";

export type ParamKind = "text" | "text_area" | "number" | "boolean" | "select";

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

interface RunEventBase {
  runId: string;
  /** Monotonic within a run; used for replay deduplication and gap recovery. */
  seq: number;
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
