import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

import type { Transport } from "./transport";
import type {
  NodeSpec,
  RunEvent,
  RunStartResponse,
  ValidationReport,
  WorkflowDoc,
  WorkflowSummary,
} from "./types";
import { RUN_EVENT_NAME } from "./types";

export const isTauri = (): boolean =>
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export const tauriTransport: Transport = {
  listNodeSpecs: () => invoke<NodeSpec[]>("list_node_specs"),
  validateWorkflow: (workflow) =>
    invoke<ValidationReport>("validate_workflow", { workflow }),
  runWorkflow: (workflow) =>
    invoke<RunStartResponse>("run_workflow", { workflow }),
  stopWorkflow: (runId) => invoke<boolean>("stop_workflow", { runId }),
  respondInteraction: (requestId, approved) =>
    invoke<boolean>("respond_interaction", { requestId, approved }),
  workflowList: () => invoke<WorkflowSummary[]>("workflow_list"),
  saveWorkflow: (name, workflow) =>
    invoke<WorkflowSummary>("save_workflow", { name, workflow }),
  loadWorkflow: (name) => invoke<WorkflowDoc>("load_workflow", { name }),
  deleteWorkflow: (name) => invoke<boolean>("delete_workflow", { name }),
  onRunEvent: async (handler) =>
    listen<RunEvent>(RUN_EVENT_NAME, (event) => handler(event.payload)),
};
