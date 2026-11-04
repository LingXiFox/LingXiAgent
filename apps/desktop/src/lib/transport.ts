import type {
  AssetKind,
  AssetRef,
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
  WorkflowDoc,
  WorkflowSummary,
} from "./types";

/** Everything the UI needs from the Rust side, with no Tauri types leaking
 *  into components. A dev-only mock implements the same surface in the browser. */
export interface Transport {
  listNodeSpecs(): Promise<NodeSpec[]>;
  validateWorkflow(workflow: WorkflowDoc): Promise<ValidationReport>;
  runWorkflow(workflow: WorkflowDoc): Promise<RunStartResponse>;
  stopWorkflow(runId: string): Promise<boolean>;
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
  onRunEvent(handler: (event: RunEvent) => void): Promise<() => void>;
  onPersistenceError(handler: (error: PersistenceError) => void): Promise<() => void>;
  onHostInteraction(handler: (request: HostInteraction) => void): Promise<() => void>;
  onHostInteractionResolved(handler: (requestId: string) => void): Promise<() => void>;
}
