import type {
  NodeSpec,
  PersistenceError,
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
  onRunEvent(handler: (event: RunEvent) => void): Promise<() => void>;
  onPersistenceError(handler: (error: PersistenceError) => void): Promise<() => void>;
}
