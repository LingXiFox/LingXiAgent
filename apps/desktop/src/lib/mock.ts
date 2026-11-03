// Dev-only stand-in for the Rust side, used when the UI runs in a plain
// browser. It mirrors the builtin node kinds but makes no execution
// guarantees: real runs always go through the Rust runtime.

import type { Transport } from "./transport";
import type {
  NodeSpec,
  RunEvent,
  RunStartResponse,
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
    ],
    outputs: [
      { name: "continue", label: "Continue", dataType: "any", required: false, control: true },
      { name: "exit", label: "Exit", dataType: "any", required: false, control: true },
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
    inputs: [{ name: "value", label: "Value", dataType: "any", required: true }],
    outputs: [],
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
];

const specs: NodeSpec[] = rawSpecs.map((spec) => ({
  ...spec,
  control: spec.control ?? "normal",
  inputs: spec.inputs.map((port) => ({ ...port, control: port.control ?? false })),
  outputs: spec.outputs.map((port) => ({ ...port, control: port.control ?? false })),
}));

const specByKind = new Map(specs.map((spec) => [spec.kind, spec]));

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

export function createMockTransport(): Transport {
  const files = new Map<string, WorkflowDoc>();
  const listeners = new Set<(event: RunEvent) => void>();
  const pending = new Map<string, (approved: boolean) => void>();
  let counter = 0;

  const emit = (event: RunEvent) => {
    for (const listener of listeners) listener(event);
  };

  const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  return {
    async listNodeSpecs() {
      return specs;
    },

    async validateWorkflow(workflow) {
      return validate(workflow);
    },

    async runWorkflow(workflow): Promise<RunStartResponse> {
      if (usesControlFlow(workflow)) {
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
      void (async () => {
        const outputs = new Map<string, Record<string, unknown>>();
        let cancelled = false;
        let finished = false;
        const startedAt = Date.now();
        const finish = (status: "completed" | "failed" | "cancelled", detail: string | null) => {
          finished = true;
          emit({
            type: "run.finished",
            runId,
            status,
            cause: status === "failed" ? "node_failed" : status === "cancelled" ? "cancelled" : null,
            detail,
            durationMs: Date.now() - startedAt,
          });
        };
        stopHandlers.set(runId, () => {
          cancelled = true;
        });
        emit({
          type: "run.started",
          runId,
          workflowId: workflow.id,
          workflowName: workflow.name,
          nodeCount: workflow.nodes.length,
        });
        for (const node of workflow.nodes) {
          if (cancelled) {
            emit({
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
            emit({
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
          emit({ type: "node.started", runId, nodeId: node.id, kind: node.kind, label, activation: 1 });
          await delay(240);
          if (node.kind === "core.approval") {
            const requestId = "req-" + ++counter;
            emit({
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
            emit({
              type: "interaction.resolved",
              runId,
              requestId,
              nodeId: node.id,
              decision: approved ? "approved" : "rejected",
            });
            if (!approved) {
              emit({
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
              emit({
                type: "log",
                runId,
                seq: ++counter,
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
          emit({
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

    async onRunEvent(handler) {
      listeners.add(handler);
      return () => {
        listeners.delete(handler);
      };
    },
  };
}

const stopHandlers = new Map<string, () => void>();
