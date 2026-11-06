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
  /** Optional visual group on dense nodes such as core.agent. */
  group?: string | null;
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

/** Rust-enforced permission mode. The UI may only select a mode; it never
 *  decides whether an individual capability is allowed. */
export type PermissionMode = "ask" | "workspace" | "yolo";

export interface RunOptions {
  conversationId?: string | null;
  userMessage?: string | null;
  permissionMode?: PermissionMode | null;
  agentNodeId?: string | null;
  /** Asset ids already registered in the workflow asset table. */
  attachments?: AssetRef[] | null;
}

export interface ProjectRecord {
  projectId: string;
  name: string;
  /** Local registry only. Workflows carry opaque workspace handles. */
  root: string;
  createdAtMs: number;
  updatedAtMs: number;
  lastOpenedAtMs: number;
}

export interface ProjectOpenResponse {
  project: ProjectRecord;
  workspaceHandle: string;
  tree: FileEntry[];
  git: boolean;
}

export interface ConversationRecord {
  conversationId: string;
  projectId: string;
  title: string;
  workflow: WorkflowDoc;
  createdAtMs: number;
  updatedAtMs: number;
}

export interface ConversationMessage {
  messageId: string;
  conversationId: string;
  runId?: string | null;
  agentNodeId?: string | null;
  agentInstanceId?: string | null;
  role: "user" | "assistant" | string;
  content: string;
  createdAtMs: number;
}

export interface FileEntry {
  path: string;
  name: string;
  kind: "file" | "dir" | string;
  size: number;
  version?: string | null;
}

export interface FileSnapshot {
  path: string;
  version: string;
  content: string;
  bytes: number;
}

export interface FileMatch {
  path: string;
  line: number;
  text: string;
}

export interface GitEntry {
  path: string;
  status: string;
}

export interface GitCommit {
  hash: string;
  author: string;
  timestampMs: number;
  subject: string;
}

export interface InstructionDocument {
  path: string;
  content: string;
}

export interface PermissionAuditRecord {
  id: number;
  runId: string;
  nodeId: string;
  mode: string;
  capability: string;
  target: string;
  decision: string;
  detail: string;
  atMs: number;
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

export interface AgentUsage {
  iterations: number;
  modelCalls: number;
  toolCalls: number;
  promptTokens: number;
  completionTokens: number;
  elapsedMs: number;
}

export interface AgentConfigSnapshot {
  revision: number;
  model: string;
  temperature: number;
  reasoning: string;
  rolePrompt: string;
  systemPrompt: string;
  maxIterations: number;
  maxToolCalls: number;
  maxTotalTokens: number;
  timeoutMs: number;
  toolset: string[];
  skills: string[];
  lsp: string[];
}

export interface ConfigChange {
  field: string;
  before: unknown;
  after: unknown;
}

export interface AgentConfigRevision {
  revision: number;
  status: "draft" | "pending" | "applied" | "rejected" | "superseded";
  appliedAtMs?: number | null;
  before: AgentConfigSnapshot;
  after: AgentConfigSnapshot;
  changes: ConfigChange[];
  detail?: string | null;
}

export interface ArtifactRefDoc {
  id: string;
  name: string;
  kind: string;
  mime?: string | null;
  size?: number | null;
  digest?: string | null;
  uri?: string | null;
}

export interface AgentBudgetDoc {
  maxIterations: number;
  maxToolCalls: number;
  maxTotalTokens: number;
  timeoutMs: number;
}

export interface TaskEnvelopeDoc {
  schemaVersion: string;
  taskId: string;
  sessionId?: string | null;
  parentTaskId?: string | null;
  sender: string;
  recipient?: string | null;
  instruction: string;
  artifacts: ArtifactRefDoc[];
  budget?: AgentBudgetDoc | null;
  correlationId?: string | null;
  idempotencyKey?: string | null;
  createdAtMs: number;
  metadata: Record<string, unknown>;
}

export interface AgentMessageEnvelope {
  schemaVersion: string;
  messageId: string;
  taskId: string;
  sender: string;
  recipient: string;
  type: string;
  status: string;
  payload: unknown;
  artifactRefs: ArtifactRefDoc[];
  correlationId?: string | null;
  idempotencyKey?: string | null;
  createdAtMs: number;
}

export interface PendingReview {
  reviewId: string;
  agentInstanceId: string;
  activationId: string;
  toolName: string;
  toolCallId?: string | null;
  reason: string;
  arguments: string;
  createdAtMs: number;
  resolved: boolean;
}

export interface ActivationRecord {
  activationId: string;
  index: number;
  state: string;
  startedAtMs: number;
  finishedAtMs?: number | null;
  configRevision: number;
  iterations: number;
  userResponse?: string | null;
  agentMessageId?: string | null;
  error?: string | null;
}

export interface AgentInstance {
  instanceId: string;
  nodeId: string;
  label: string;
  scope: ScopeFrame[];
  state: string;
  currentActivation?: string | null;
  activations: ActivationRecord[];
  config: AgentConfigSnapshot;
  configRevisions: AgentConfigRevision[];
  usage: AgentUsage;
  pendingDirectives: string[];
  createdAtMs: number;
  updatedAtMs: number;
}

export interface TaskSession {
  sessionId: string;
  runId: string;
  workflowId: string;
  workflowName: string;
  workflowRevision: number;
  state: string;
  createdAtMs: number;
  updatedAtMs: number;
  agents: Record<string, AgentInstance>;
  messages: AgentMessageEnvelope[];
  pendingReviews: PendingReview[];
  artifacts: ArtifactRefDoc[];
}

export type AgentEvent =
  | {
      type: "agent.registered";
      agentInstanceId: string;
      nodeId: string;
      label: string;
      scope: ScopeFrame[];
      state: string;
      config: AgentConfigSnapshot;
    }
  | {
      type: "agent.state";
      agentInstanceId: string;
      activationId?: string | null;
      state: string;
      reason?: string | null;
    }
  | {
      type: "agent.activation.started";
      agentInstanceId: string;
      activationId: string;
      index: number;
      configRevision: number;
    }
  | {
      type: "agent.activation.finished";
      agentInstanceId: string;
      activationId: string;
      state: string;
      usage: AgentUsage;
      userResponse?: string | null;
      messageId?: string | null;
      error?: string | null;
    }
  | {
      type: "agent.message";
      agentInstanceId?: string | null;
      message: AgentMessageEnvelope;
    }
  | {
      type: "agent.delta";
      agentInstanceId: string;
      activationId: string;
      delta: string;
    }
  | {
      type: "agent.tool.started";
      agentInstanceId: string;
      activationId: string;
      toolCallId: string;
      toolName: string;
      arguments: string;
    }
  | {
      type: "agent.tool.finished";
      agentInstanceId: string;
      activationId: string;
      toolCallId: string;
      toolName: string;
      ok: boolean;
      durationMs: number;
      error?: string | null;
      result: string;
    }
  | {
      type: "agent.config";
      agentInstanceId: string;
      revision: AgentConfigRevision;
    }
  | {
      type: "agent.directive";
      agentInstanceId: string;
      activationId: string;
      text: string;
    }
  | {
      type: "agent.review";
      agentInstanceId: string;
      review: PendingReview;
    }
  | {
      type: "agent.usage";
      agentInstanceId: string;
      usage: AgentUsage;
    };

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
      type: "agent.event";
      event: AgentEvent;
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
