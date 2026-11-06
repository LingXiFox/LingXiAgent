import type {
  AgentConfigRevision,
  AgentConfigSnapshot,
  AssetKind,
  AssetRef,
  ConfigChange,
  ConversationMessage,
  ConversationRecord,
  FileEntry,
  FileMatch,
  FileSnapshot,
  GitCommit,
  GitEntry,
  InstructionDocument,
  PermissionAuditRecord,
  PermissionMode,
  ProjectOpenResponse,
  ProjectRecord,
  RunOptions,
  HostInteraction,
  ModelCapabilities,
  NodeSpec,
  ProviderProtocol,
  PersistenceError,
  SkillSummary,
  RunDetail,
  RunEvent,
  RunRecord,
  RunStartResponse,
  TemplateBundle,
  TemplateSummary,
  ValidationReport,
  TaskSession,
  WorkflowDoc,
  WorkflowSummary,
} from "./types";

/** Everything the UI needs from the Rust side, with no Tauri types leaking
 *  into components. A dev-only mock implements the same surface in the browser. */
export interface Transport {
  listNodeSpecs(): Promise<NodeSpec[]>;
  validateWorkflow(workflow: WorkflowDoc): Promise<ValidationReport>;
  runWorkflow(workflow: WorkflowDoc, options?: RunOptions): Promise<RunStartResponse>;
  stopWorkflow(runId: string): Promise<boolean>;
  pauseWorkflow(runId: string): Promise<boolean>;
  resumeWorkflow(runId: string): Promise<boolean>;
  pauseAgent(runId: string, agentInstanceId: string): Promise<void>;
  resumeAgent(runId: string, agentInstanceId: string): Promise<void>;
  cancelAgent(runId: string, agentInstanceId: string): Promise<void>;
  sendAgentDirective(runId: string, agentInstanceId: string, text: string): Promise<void>;
  previewAgentConfig(
    runId: string,
    agentInstanceId: string,
    config: AgentConfigSnapshot,
  ): Promise<ConfigChange[]>;
  applyAgentConfig(
    runId: string,
    agentInstanceId: string,
    config: AgentConfigSnapshot,
    expectedRevision: number,
  ): Promise<AgentConfigRevision>;
  rejectAgentConfig(
    runId: string,
    agentInstanceId: string,
    revision: number,
    detail: string,
  ): Promise<void>;
  taskSession(runId: string): Promise<TaskSession | null>;
  respondInteraction(requestId: string, approved: boolean): Promise<boolean>;
  workflowList(): Promise<WorkflowSummary[]>;
  saveWorkflow(name: string, workflow: WorkflowDoc): Promise<WorkflowSummary>;
  loadWorkflow(name: string): Promise<WorkflowDoc>;
  deleteWorkflow(name: string): Promise<boolean>;
  templateList(): Promise<TemplateSummary[]>;
  templateLoad(id: string): Promise<TemplateBundle>;
  templateSave(name: string, bundle: TemplateBundle): Promise<TemplateSummary>;
  templateDelete(id: string): Promise<boolean>;
  runList(limit?: number): Promise<RunRecord[]>;
  runDetail(runId: string): Promise<RunDetail | null>;
  runEvents(runId: string, afterSeq?: number): Promise<RunEvent[]>;
  activeRun(): Promise<RunDetail | null>;
  credentialStatus(reference: string): Promise<boolean>;
  credentialSet(name: string, secret: string): Promise<string>;
  credentialDelete(name: string): Promise<boolean>;
  providerModels(
    baseUrl: string,
    credentialRef: string,
    protocol?: ProviderProtocol,
    capabilities?: unknown,
  ): Promise<string[]>;
  modelCapabilities(
    protocol: ProviderProtocol,
    model: string,
    capabilities?: unknown,
  ): Promise<ModelCapabilities>;
  assetImport(path: string, kind: AssetKind): Promise<AssetRef>;
  assetImportFile(file: File, kind: AssetKind): Promise<AssetRef>;
  assetPreview(id: string, mime: string): Promise<string>;
  respondHostInteraction(requestId: string, approved: boolean): Promise<boolean>;
  skillList(): Promise<SkillSummary[]>;
  agentTemplate(): Promise<TemplateBundle>;
  pickProjectFolder(): Promise<string | null>;
  projectList(): Promise<ProjectRecord[]>;
  projectOpen(root: string): Promise<ProjectOpenResponse>;
  projectRemove(projectId: string): Promise<boolean>;
  projectTree(projectId: string, path?: string, showIgnored?: boolean): Promise<FileEntry[]>;
  projectRead(projectId: string, path: string): Promise<FileSnapshot>;
  projectWrite(
    projectId: string,
    path: string,
    content: string,
    expectedVersion?: string | null,
  ): Promise<FileSnapshot>;
  projectDelete(projectId: string, path: string, expectedVersion?: string | null): Promise<boolean>;
  projectSearch(projectId: string, query: string, path?: string, limit?: number): Promise<FileMatch[]>;
  projectGitStatus(projectId: string): Promise<GitEntry[]>;
  projectGitDiff(projectId: string, path?: string): Promise<string>;
  projectGitLog(projectId: string, limit?: number): Promise<GitCommit[]>;
  projectRules(projectId: string, path?: string): Promise<InstructionDocument[]>;
  projectReveal(projectId: string, path?: string): Promise<boolean>;
  conversationList(projectId?: string, limit?: number): Promise<ConversationRecord[]>;
  conversationCreate(
    projectId: string,
    title?: string,
    workflow?: WorkflowDoc,
  ): Promise<ConversationRecord>;
  conversationCreateTeam(projectId: string, title?: string): Promise<ConversationRecord>;
  conversationGet(conversationId: string): Promise<ConversationRecord | null>;
  conversationSaveWorkflow(
    conversationId: string,
    workflow: WorkflowDoc,
    title?: string,
  ): Promise<ConversationRecord>;
  conversationMessages(conversationId: string): Promise<ConversationMessage[]>;
  appendConversationMessage(
    conversationId: string,
    runId: string | null,
    agentNodeId: string | null,
    content: string,
  ): Promise<boolean>;
  permissionAudit(runId?: string, limit?: number): Promise<PermissionAuditRecord[]>;
  setPermissionMode(runId: string, mode: PermissionMode): Promise<boolean>;
  onRunEvent(handler: (event: RunEvent) => void): Promise<() => void>;
  onPersistenceError(handler: (error: PersistenceError) => void): Promise<() => void>;
  onHostInteraction(handler: (request: HostInteraction) => void): Promise<() => void>;
  onHostInteractionResolved(handler: (requestId: string) => void): Promise<() => void>;
}
