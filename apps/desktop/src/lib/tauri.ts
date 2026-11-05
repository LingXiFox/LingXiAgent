import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

import type { Transport } from "./transport";
import type {
  AgentConfigRevision,
  AssetRef,
  ConfigChange,
  HostInteraction,
  ModelCapabilities,
  NodeSpec,
  PersistenceError,
  RunDetail,
  RunEvent,
  RunRecord,
  RunStartResponse,
  SkillSummary,
  TaskSession,
  TemplateBundle,
  TemplateSummary,
  ValidationReport,
  WorkflowDoc,
  WorkflowSummary,
} from "./types";
import {
  HOST_INTERACTION_NAME,
  HOST_INTERACTION_RESOLVED_NAME,
  PERSISTENCE_ERROR_NAME,
  RUN_EVENT_NAME,
} from "./types";

export const isTauri = (): boolean =>
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export const tauriTransport: Transport = {
  listNodeSpecs: () => invoke<NodeSpec[]>("list_node_specs"),
  validateWorkflow: (workflow) =>
    invoke<ValidationReport>("validate_workflow", { workflow }),
  runWorkflow: (workflow) =>
    invoke<RunStartResponse>("run_workflow", { workflow }),
  stopWorkflow: (runId) => invoke<boolean>("stop_workflow", { runId }),
  pauseWorkflow: (runId) => invoke<boolean>("pause_workflow", { runId }),
  resumeWorkflow: (runId) => invoke<boolean>("resume_workflow", { runId }),
  pauseAgent: (runId, agentInstanceId) =>
    invoke<void>("pause_agent", { runId, agentInstanceId }),
  resumeAgent: (runId, agentInstanceId) =>
    invoke<void>("resume_agent", { runId, agentInstanceId }),
  cancelAgent: (runId, agentInstanceId) =>
    invoke<void>("cancel_agent", { runId, agentInstanceId }),
  sendAgentDirective: (runId, agentInstanceId, text) =>
    invoke<void>("send_agent_directive", { runId, agentInstanceId, text }),
  previewAgentConfig: (runId, agentInstanceId, config) =>
    invoke<ConfigChange[]>("preview_agent_config", { runId, agentInstanceId, config }),
  applyAgentConfig: (runId, agentInstanceId, config, expectedRevision) =>
    invoke<AgentConfigRevision>("apply_agent_config", {
      runId,
      agentInstanceId,
      config,
      expectedRevision,
    }),
  rejectAgentConfig: (runId, agentInstanceId, revision, detail) =>
    invoke<void>("reject_agent_config", { runId, agentInstanceId, revision, detail }),
  taskSession: (runId) => invoke<TaskSession | null>("task_session", { runId }),
  respondInteraction: (requestId, approved) =>
    invoke<boolean>("respond_interaction", { requestId, approved }),
  workflowList: () => invoke<WorkflowSummary[]>("workflow_list"),
  saveWorkflow: (name, workflow) =>
    invoke<WorkflowSummary>("save_workflow", { name, workflow }),
  loadWorkflow: (name) => invoke<WorkflowDoc>("load_workflow", { name }),
  deleteWorkflow: (name) => invoke<boolean>("delete_workflow", { name }),
  templateList: () => invoke<TemplateSummary[]>("template_list"),
  templateLoad: (id) => invoke<TemplateBundle>("template_load", { id }),
  templateSave: (name, bundle) => invoke<TemplateSummary>("template_save", { name, bundle }),
  templateDelete: (id) => invoke<boolean>("template_delete", { id }),
  runList: (limit) => invoke<RunRecord[]>("run_list", { limit }),
  runDetail: (runId) => invoke<RunDetail | null>("run_detail", { runId }),
  runEvents: (runId, afterSeq) => invoke<RunEvent[]>("run_events", { runId, afterSeq }),
  activeRun: () => invoke<RunDetail | null>("active_run"),
  credentialStatus: (reference) =>
    invoke<boolean>("credential_status", { reference }),
  credentialSet: (name, secret) => invoke<string>("credential_set", { name, secret }),
  credentialDelete: (name) => invoke<boolean>("credential_delete", { name }),
  providerModels: (baseUrl, credentialRef, protocol, capabilities) =>
    invoke<string[]>("provider_models", {
      baseUrl,
      credentialRef,
      protocol: protocol ?? null,
      capabilities: capabilities ?? null,
    }),
  modelCapabilities: (protocol, model, capabilities) =>
    invoke<ModelCapabilities>("model_capabilities", {
      protocol,
      model,
      capabilities: capabilities ?? null,
    }),
  assetImport: (path, kind) => invoke<AssetRef>("asset_import", { path, kind }),
  assetImportFile: async () => {
    throw new Error("desktop builds use the native file picker");
  },
  assetPreview: (id, mime) => invoke<string>("asset_preview", { id, mime }),
  respondHostInteraction: (requestId, approved) =>
    invoke<boolean>("respond_host_interaction", { requestId, approved }),
  skillList: () => invoke<SkillSummary[]>("skill_list"),
  agentTemplate: () => invoke<TemplateBundle>("agent_template"),
  onRunEvent: async (handler) =>
    listen<RunEvent>(RUN_EVENT_NAME, (event) => handler(event.payload)),
  onPersistenceError: async (handler) =>
    listen<PersistenceError>(PERSISTENCE_ERROR_NAME, (event) => handler(event.payload)),
  onHostInteraction: async (handler) =>
    listen<HostInteraction>(HOST_INTERACTION_NAME, (event) => handler(event.payload)),
  onHostInteractionResolved: async (handler) =>
    listen<string>(HOST_INTERACTION_RESOLVED_NAME, (event) => handler(event.payload)),
};
