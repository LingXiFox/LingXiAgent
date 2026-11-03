import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ReactFlowProvider,
  type Connection,
  type Edge,
  useEdgesState,
  useNodesState,
} from "@xyflow/react";

import { Canvas } from "./components/Canvas";
import { ConfirmDialog } from "./components/ConfirmDialog";
import { InteractionDialog, type InteractionRequest } from "./components/InteractionDialog";
import { LogPanel } from "./components/LogPanel";
import { NodeLibrary } from "./components/NodeLibrary";
import { ProblemsPanel } from "./components/ProblemsPanel";
import { RunHistoryDialog } from "./components/RunHistoryDialog";
import { Toolbar } from "./components/Toolbar";
import { WorkflowDialog } from "./components/WorkflowDialog";
import { api, isPreview } from "./lib/api";
import type { LogEntry, LogLevel, UiRunStatus } from "./lib/log";
import type { LingXiNode } from "./lib/nodeData";
import {
  accepts,
  defaultParams,
  newWorkflow,
  SCHEMA_VERSION,
  toDocEdge,
  type WorkflowMeta,
} from "./lib/workflow";
import type {
  NodeSpec,
  PositionDoc,
  RunEvent,
  RunStatus,
  ValidationReport,
  WorkflowDoc,
  WorkflowNodeDoc,
  WorkflowSummary,
} from "./lib/types";

const UNKNOWN_SPEC = (kind: string): NodeSpec => ({
  kind,
  title: kind,
  category: "Unknown",
  description: "This node kind is not registered in the current build.",
  inputs: [],
  outputs: [],
  params: [],
  capabilities: [],
  control: "normal",
});

function edgeIsControl(edge: Edge): boolean {
  return Boolean((edge.data as { control?: boolean } | undefined)?.control);
}

function demoWorkflow(): WorkflowDoc {
  const document = newWorkflow("计数器循环示例");
  const node = (
    id: string,
    kind: string,
    label: string,
    x: number,
    y: number,
    params: Record<string, unknown>,
  ): WorkflowNodeDoc => ({
    id,
    kind,
    label,
    position: { x, y },
    params,
    enabled: true,
  });
  document.nodes = [
    node("demo-seed", "core.number_input", "起始值", 20, 160, { value: 0 }),
    node("demo-gate", "core.loop_gate", "循环门", 300, 160, {
      maxIterations: 10,
      timeoutMs: 60000,
    }),
    node("demo-counter", "core.counter", "计数器", 580, 160, {
      start: 0,
      step: 1,
      threshold: 3,
    }),
    node("demo-condition", "core.condition", "条件", 860, 160, {}),
    node("demo-log", "core.log", "输出", 1140, 300, { prefix: "count: " }),
  ];
  document.edges = [
    toDocEdge("demo-seed", "number", "demo-gate", "start", "control"),
    toDocEdge("demo-gate", "continue", "demo-counter", "value", "control"),
    toDocEdge("demo-counter", "number", "demo-condition", "payload", "data"),
    toDocEdge("demo-counter", "done", "demo-condition", "condition", "data"),
    toDocEdge("demo-condition", "false", "demo-gate", "next", "control"),
    toDocEdge("demo-condition", "true", "demo-gate", "stop", "control"),
    toDocEdge("demo-gate", "exit", "demo-log", "value", "control"),
  ];
  document.viewport = { x: 20, y: 140, zoom: 0.8 };
  return document;
}

function buildNode(
  id: string,
  spec: NodeSpec,
  position: PositionDoc,
  params: Record<string, unknown>,
  label: string | null,
  enabled: boolean,
  onParamChange: LingXiNode["data"]["onParamChange"],
  onToggleEnabled: LingXiNode["data"]["onToggleEnabled"],
): LingXiNode {
  return {
    id,
    type: "lingxi",
    position,
    data: {
      kind: spec.kind,
      label,
      params,
      enabled,
      spec,
      onParamChange,
      onToggleEnabled,
    },
  };
}

export default function App() {
  const [specs, setSpecs] = useState<NodeSpec[]>([]);
  const [nodes, setNodes, onNodesChange] = useNodesState<LingXiNode>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge>([]);
  const [meta, setMeta] = useState<WorkflowMeta>(() => {
    const workflow = newWorkflow("未命名工作流");
    return {
      id: workflow.id,
      name: workflow.name,
      description: workflow.description,
      metadata: workflow.metadata,
      viewport: workflow.viewport,
    };
  });
  const [status, setStatus] = useState<UiRunStatus>("idle");
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [logOpen, setLogOpen] = useState(true);
  const [report, setReport] = useState<ValidationReport | null>(null);
  const [problemsOpen, setProblemsOpen] = useState(false);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [dialogBusy, setDialogBusy] = useState(false);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [workflows, setWorkflows] = useState<WorkflowSummary[]>([]);
  const [pending, setPending] = useState<InteractionRequest | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [viewportKey, setViewportKey] = useState(0);
  const [catalogReady, setCatalogReady] = useState(false);
  const [bridgeReady, setBridgeReady] = useState(false);
  const [recovering, setRecovering] = useState(true);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [persistenceError, setPersistenceError] = useState<string | null>(null);
  // Terminal events can arrive before runWorkflow resolves; remember them so the
  // late `setStatus("running")` does not overwrite the real outcome.
  const finishedRunsRef = useRef(new Map<string, RunStatus>());

  const specMap = useMemo(() => new Map(specs.map((spec) => [spec.kind, spec])), [specs]);
  const nodesRef = useRef(nodes);
  const edgesRef = useRef(edges);
  const metaRef = useRef(meta);
  const statusRef = useRef(status);
  const runIdRef = useRef<string | null>(null);
  const logSeq = useRef(0);
  const toastTimer = useRef<number | null>(null);
  // Events are applied strictly by seq. Live events that arrive while the
  // initial snapshot is loading are queued, then merged with replayed history
  // in one sorted queue so a terminal event can never overtake its history.
  const appliedSeqRef = useRef(new Map<string, number>());
  const eventQueueRef = useRef<RunEvent[]>([]);
  const drainingRef = useRef(false);
  const recoveringRef = useRef(true);
  const reconnectedLogRef = useRef<string | null>(null);
  const applyEventRef = useRef<(event: RunEvent) => void>(() => {});

  nodesRef.current = nodes;
  edgesRef.current = edges;
  metaRef.current = meta;
  statusRef.current = status;

  const pushLog = useCallback((level: LogLevel, text: string, at = Date.now()) => {
    setLogs((previous) => {
      const next = [...previous, { id: ++logSeq.current, at, level, text }];
      return next.length > 600 ? next.slice(next.length - 600) : next;
    });
  }, []);

  const flash = useCallback((message: string) => {
    setToast(message);
    if (toastTimer.current !== null) window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 2400);
  }, []);

  const handleParamChange = useCallback(
    (nodeId: string, name: string, value: unknown) => {
      setNodes((current) =>
        current.map((node) =>
          node.id === nodeId
            ? { ...node, data: { ...node.data, params: { ...node.data.params, [name]: value } } }
            : node,
        ),
      );
    },
    [setNodes],
  );

  const handleToggleEnabled = useCallback(
    (nodeId: string) => {
      setNodes((current) =>
        current.map((node) =>
          node.id === nodeId ? { ...node, data: { ...node.data, enabled: !node.data.enabled } } : node,
        ),
      );
    },
    [setNodes],
  );

  const setNodeRun = useCallback(
    (nodeId: string, run: LingXiNode["data"]["run"]) => {
      setNodes((current) =>
        current.map((node) =>
          node.id === nodeId ? { ...node, data: { ...node.data, run } } : node,
        ),
      );
    },
    [setNodes],
  );

  const addNode = useCallback(
    (kind: string, position: PositionDoc) => {
      const spec = specMap.get(kind);
      if (!spec) {
        pushLog("warn", "node kind " + kind + " is not in the catalog");
        return;
      }
      const id = "n-" + crypto.randomUUID().slice(0, 8);
      const node = buildNode(
        id,
        spec,
        position,
        defaultParams(spec),
        null,
        true,
        handleParamChange,
        handleToggleEnabled,
      );
      setNodes((current) => [...current, node]);
    },
    [handleParamChange, handleToggleEnabled, pushLog, setNodes, specMap],
  );

  const addFromLibrary = useCallback(
    (kind: string) => {
      const index = nodesRef.current.length;
      addNode(kind, { x: 160 + (index % 4) * 60, y: 120 + (index % 5) * 50 });
    },
    [addNode],
  );

  const onConnect = useCallback(
    (connection: Connection) => {
      const source = connection.source;
      const target = connection.target;
      const sourceHandle = connection.sourceHandle;
      const targetHandle = connection.targetHandle;
      if (!source || !target || !sourceHandle || !targetHandle) return;
      if (source === target) {
        flash("不能连接自身");
        return;
      }
      const sourceNode = nodesRef.current.find((node) => node.id === source);
      const targetNode = nodesRef.current.find((node) => node.id === target);
      const sourcePort = sourceNode?.data.spec.outputs.find((port) => port.name === sourceHandle);
      const targetPort = targetNode?.data.spec.inputs.find((port) => port.name === targetHandle);
      if (!sourcePort || !targetPort) return;
      if (!accepts(targetPort.dataType, sourcePort.dataType)) {
        flash("端口类型不兼容：" + sourcePort.dataType + " → " + targetPort.dataType);
        return;
      }
      const control = sourcePort.control || targetPort.control;
      const docEdge = toDocEdge(
        source,
        sourceHandle,
        target,
        targetHandle,
        control ? "control" : "data",
      );
      setEdges((current) => {
        if (current.some((edge) => edge.id === docEdge.id)) return current;
        const withoutOccupied = current.filter(
          (edge) => !(edge.target === target && edge.targetHandle === targetHandle),
        );
        return [
          ...withoutOccupied,
          {
            id: docEdge.id,
            source,
            sourceHandle,
            target,
            targetHandle,
            type: "smart",
            data: { control },
          },
        ];
      });
    },
    [flash, setEdges],
  );

  const buildDoc = useCallback((): WorkflowDoc => {
    return {
      schemaVersion: SCHEMA_VERSION,
      id: metaRef.current.id,
      name: metaRef.current.name,
      description: metaRef.current.description,
      nodes: nodesRef.current.map<WorkflowNodeDoc>((node) => ({
        id: node.id,
        kind: node.data.kind,
        label: node.data.label,
        position: { x: node.position.x, y: node.position.y },
        params: node.data.params,
        enabled: node.data.enabled,
      })),
      edges: edgesRef.current.map((edge) => ({
        id: edge.id,
        source: edge.source,
        sourcePort: edge.sourceHandle ?? "",
        target: edge.target,
        targetPort: edge.targetHandle ?? "",
        kind: edgeIsControl(edge) ? "control" : "data",
      })),
      viewport: metaRef.current.viewport,
      metadata: metaRef.current.metadata,
    };
  }, []);

  const applyDoc = useCallback(
    (document: WorkflowDoc) => {
      const missing: string[] = [];
      const nextNodes = document.nodes.map((node) => {
        const known = specMap.get(node.kind);
        if (!known) missing.push(node.kind);
        return buildNode(
          node.id,
          known ?? UNKNOWN_SPEC(node.kind),
          { x: node.position.x, y: node.position.y },
          node.params ?? {},
          node.label ?? null,
          node.enabled ?? true,
          handleParamChange,
          handleToggleEnabled,
        );
      });
      setNodes(nextNodes);
      setEdges(
        document.edges.map((edge) => {
          const control = edge.kind === "control";
          return {
            id: edge.id,
            source: edge.source,
            sourceHandle: edge.sourcePort,
            target: edge.target,
            targetHandle: edge.targetPort,
            type: "smart",
            data: { control },
          };
        }),
      );
      setMeta({
        id: document.id,
        name: document.name,
        description: document.description ?? "",
        metadata: document.metadata ?? {},
        viewport: document.viewport ?? { x: 0, y: 0, zoom: 1 },
      });
      setReport(null);
      setProblemsOpen(false);
      setViewportKey((key) => key + 1);
      setPending(null);
      runIdRef.current = null;
      setStatus("idle");
      if (missing.length > 0) {
        pushLog("warn", "loaded workflow references unregistered kinds: " + missing.join(", "));
      }
    },
    [handleParamChange, handleToggleEnabled, pushLog, setEdges, setNodes, specMap],
  );

  const applyEvent = useCallback(
    (event: RunEvent) => {
      const activeRunId = runIdRef.current;
      // A late event from a previous run must not overwrite the current one.
      // A new run.started is allowed to take over explicitly.
      if (
        event.type !== "run.started" &&
        activeRunId !== null &&
        event.runId !== activeRunId
      ) {
        return;
      }
      switch (event.type) {
        case "run.started":
          runIdRef.current = event.runId;
          pushLog("info", "run started · " + event.workflowName + " · " + event.nodeCount + " nodes");
          setNodes((current) =>
            current.map((node) =>
              node.data.run ? { ...node, data: { ...node.data, run: undefined } } : node,
            ),
          );
          setStatus("running");
          break;
        case "node.started":
          pushLog("info", "▶ " + event.label + " · " + event.kind);
          setNodeRun(event.nodeId, {
            state: "running",
            activation: event.activation,
            iteration: event.iteration,
          });
          break;
        case "node.finished": {
          const names = Object.keys(event.outputs);
          const detail = names.length > 0 ? " · " + JSON.stringify(event.outputs) : "";
          pushLog("success", "✓ " + event.label + " · " + event.durationMs + "ms" + detail);
          setNodeRun(event.nodeId, {
            state: "completed",
            activation: event.activation,
            iteration: event.iteration,
          });
          break;
        }
        case "node.failed":
          pushLog("error", "✕ " + event.label + " · " + event.code + ": " + event.message);
          if (event.code === "loop.budget_exhausted") flash("循环预算耗尽，运行失败");
          if (event.code === "loop.timeout") flash("循环超时，运行已终止");
          setNodeRun(event.nodeId, {
            state: "failed",
            activation: event.activation,
            iteration: event.iteration,
          });
          break;
        case "node.skipped":
          pushLog("warn", "⤼ " + event.label + " skipped · " + event.reason);
          setNodeRun(event.nodeId, {
            state: "skipped",
            activation: event.activation,
            iteration: event.iteration,
          });
          break;
        case "node.cancelled":
          pushLog("warn", "⏹ " + event.label + " cancelled");
          setNodeRun(event.nodeId, {
            state: "cancelled",
            activation: event.activation,
            iteration: event.iteration,
          });
          break;
        case "log":
          pushLog(event.level === "debug" ? "info" : event.level, event.message, event.atMs);
          break;
        case "interaction.requested":
          pushLog("warn", "⏸ waiting for approval · " + event.prompt);
          setPending({ requestId: event.requestId, nodeId: event.nodeId, prompt: event.prompt });
          setLogOpen(true);
          break;
        case "interaction.resolved":
          pushLog("info", "interaction " + event.decision + " · " + event.nodeId);
          setPending((current) =>
            current && current.requestId === event.requestId ? null : current,
          );
          break;
        case "run.finished":
          pushLog(
            event.status === "completed" ? "success" : event.status === "cancelled" ? "warn" : "error",
            "run " + event.status + " · " + event.durationMs + "ms" + (event.detail ? " · " + event.detail : ""),
          );
          finishedRunsRef.current.set(event.runId, event.status);
          setStatus(event.status);
          runIdRef.current = null;
          setPending(null);
          break;
      }
    },
    [flash, pushLog, setNodeRun, setNodes],
  );
  applyEventRef.current = applyEvent;

  const enqueueEvent = useCallback((event: RunEvent) => {
    const queue = eventQueueRef.current;
    let index = queue.length;
    // Keep same-run events ordered even if a live event beats its snapshot.
    while (index > 0) {
      const previous = queue[index - 1];
      if (previous.runId !== event.runId || previous.seq <= event.seq) break;
      index -= 1;
    }
    queue.splice(index, 0, event);
  }, []);

  const drainEvents = useCallback(async () => {
    if (drainingRef.current) return;
    drainingRef.current = true;
    try {
      while (eventQueueRef.current.length > 0) {
        const event = eventQueueRef.current[0];
        const applied = appliedSeqRef.current.get(event.runId);
        if (applied !== undefined && event.seq <= applied) {
          eventQueueRef.current.shift();
          continue;
        }
        const expected = applied === undefined ? 0 : applied + 1;
        if (event.seq > expected) {
          try {
            const missing = await api.runEvents(event.runId, applied);
            const unseen = missing.filter(
              (candidate) => candidate.seq >= expected && candidate.seq < event.seq,
            );
            if (unseen.length > 0) {
              unseen.forEach((candidate) => enqueueEvent(candidate));
              continue;
            }
            pushLog(
              "warn",
              "event gap " + event.runId + " · seq " + expected + ".." + (event.seq - 1) + " missing",
            );
          } catch (error) {
            pushLog("error", "event recovery failed: " + String(error));
          }
          // Never stall the queue on an unrecoverable gap: advance explicitly.
          appliedSeqRef.current.set(event.runId, event.seq - 1);
          continue;
        }
        applyEventRef.current(event);
        appliedSeqRef.current.set(event.runId, event.seq);
        eventQueueRef.current.shift();
      }
    } finally {
      drainingRef.current = false;
    }
  }, [enqueueEvent, pushLog]);

  const receiveEvent = useCallback(
    (event: RunEvent) => {
      enqueueEvent(event);
      if (!recoveringRef.current) void drainEvents();
    },
    [drainEvents, enqueueEvent],
  );

  useEffect(() => {
    let cancelled = false;
    let disposeRun: (() => void) | undefined;
    let disposeError: (() => void) | undefined;
    const subscriptions: Promise<void>[] = [];

    subscriptions.push(
      api
        .onRunEvent(receiveEvent)
        .then((cleanup) => {
          if (cancelled) cleanup();
          else disposeRun = cleanup;
        })
        .catch((error: unknown) => pushLog("error", "event bridge failed: " + String(error))),
    );
    subscriptions.push(
      api
        .onPersistenceError((error) => {
          setPersistenceError(error.message);
          pushLog("error", "持久化失败 · " + error.message);
        })
        .then((cleanup) => {
          if (cancelled) cleanup();
          else disposeError = cleanup;
        })
        .catch((error: unknown) =>
          pushLog("error", "persistence bridge failed: " + String(error)),
        ),
    );
    void Promise.all(subscriptions).then(() => {
      if (!cancelled) setBridgeReady(true);
    });

    return () => {
      cancelled = true;
      disposeRun?.();
      disposeError?.();
    };
  }, [pushLog, receiveEvent]);

  useEffect(() => {
    api
      .listNodeSpecs()
      .then((catalog) => {
        setSpecs(catalog);
        pushLog("info", "node catalog ready · " + catalog.length + " kinds");
      })
      .catch((error: unknown) => pushLog("error", "failed to load node catalog: " + String(error)))
      .finally(() => setCatalogReady(true));
  }, [pushLog]);

  useEffect(() => {
    if (!catalogReady || !bridgeReady) return;
    let cancelled = false;
    recoveringRef.current = true;
    setRecovering(true);

    void (async () => {
      try {
        const snapshot = await api.activeRun();
        if (cancelled) return;
        if (snapshot) {
          applyDoc(snapshot.workflow);
          runIdRef.current = snapshot.run.runId;
          setStatus(snapshot.run.status === "running" ? "running" : snapshot.run.status);
          if (reconnectedLogRef.current !== snapshot.run.runId) {
            reconnectedLogRef.current = snapshot.run.runId;
            pushLog(
              "info",
              "reconnected to run · " +
                (snapshot.run.workflowName || "未命名工作流") +
                " · " +
                snapshot.events.length +
                " events replayed",
            );
          }
          snapshot.events.forEach((event) => enqueueEvent(event));
        }
      } catch (error) {
        pushLog("error", "run recovery failed: " + String(error));
      } finally {
        if (!cancelled) {
          recoveringRef.current = false;
          setRecovering(false);
          void drainEvents();
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [applyDoc, bridgeReady, catalogReady, drainEvents, enqueueEvent, pushLog]);

  const resetCanvas = useCallback(() => {
    const workflow = newWorkflow("未命名工作流");
    setNodes([]);
    setEdges([]);
    setReport(null);
    setProblemsOpen(false);
    setMeta({
      id: workflow.id,
      name: workflow.name,
      description: workflow.description,
      metadata: workflow.metadata,
      viewport: workflow.viewport,
    });
    setViewportKey((key) => key + 1);
    setPending(null);
    runIdRef.current = null;
    setStatus("idle");
    pushLog("info", "new workflow");
  }, [pushLog, setEdges, setNodes]);

  const [confirmAction, setConfirmAction] = useState<"new" | "demo" | null>(null);

  const handleNew = useCallback(() => {
    if (nodesRef.current.length > 0) {
      setConfirmAction("new");
      return;
    }
    resetCanvas();
  }, [resetCanvas]);

  const handleDemo = useCallback(() => {
    if (nodesRef.current.length > 0) {
      setConfirmAction("demo");
      return;
    }
    applyDoc(demoWorkflow());
    pushLog("info", "loaded demo workflow · counter → condition → loop gate");
  }, [applyDoc, pushLog]);

  const confirmReplace = useCallback(() => {
    const action = confirmAction;
    setConfirmAction(null);
    if (action === "new") {
      resetCanvas();
      return;
    }
    if (action === "demo") {
      applyDoc(demoWorkflow());
      pushLog("info", "loaded demo workflow · counter → condition → loop gate");
    }
  }, [applyDoc, confirmAction, pushLog, resetCanvas]);

  const handleSave = useCallback(async () => {
    const name = metaRef.current.name.trim();
    if (!name) {
      pushLog("error", "workflow name is empty");
      setToast("请先填写工作流名称");
      return;
    }
    setBusy(true);
    try {
      const summary = await api.saveWorkflow(name, buildDoc());
      flash("已保存 · " + summary.name);
      pushLog("success", "saved " + summary.name + " · " + summary.nodeCount + " nodes");
    } catch (error) {
      pushLog("error", "save failed: " + String(error));
      flash("保存失败");
    } finally {
      setBusy(false);
    }
  }, [buildDoc, flash, pushLog]);

  const openDialog = useCallback(async () => {
    setDialogOpen(true);
    setDialogBusy(true);
    setDialogError(null);
    try {
      setWorkflows(await api.workflowList());
    } catch (error) {
      setDialogError(String(error));
    } finally {
      setDialogBusy(false);
    }
  }, []);

  const loadNamed = useCallback(
    async (name: string) => {
      setDialogBusy(true);
      setDialogError(null);
      try {
        const document = await api.loadWorkflow(name);
        applyDoc(document);
        setDialogOpen(false);
        pushLog("success", "loaded " + name);
      } catch (error) {
        setDialogError(String(error));
      } finally {
        setDialogBusy(false);
      }
    },
    [applyDoc, pushLog],
  );

  const deleteNamed = useCallback(
    async (name: string) => {
      try {
        await api.deleteWorkflow(name);
        setWorkflows((current) => current.filter((item) => item.name !== name));
        pushLog("info", "deleted " + name);
      } catch (error) {
        setDialogError(String(error));
      }
    },
    [pushLog],
  );

  const handleValidate = useCallback(async () => {
    setBusy(true);
    try {
      const result = await api.validateWorkflow(buildDoc());
      setReport(result);
      setProblemsOpen(true);
      pushLog(
        result.ok ? "success" : "error",
        "validation · " + result.errors + " errors · " + result.warnings + " warnings",
      );
    } catch (error) {
      pushLog("error", "validation failed: " + String(error));
    } finally {
      setBusy(false);
    }
  }, [buildDoc, pushLog]);

  const handleRun = useCallback(async () => {
    if (recoveringRef.current || statusRef.current === "running") return;
    if (nodesRef.current.length === 0) {
      flash("画布还是空的");
      return;
    }
    setBusy(true);
    setPending(null);
    setPersistenceError(null);
    try {
      const response = await api.runWorkflow(buildDoc());
      setReport(response.report);
      setProblemsOpen(!response.report.ok);
      if (!response.started || !response.runId) {
        pushLog("error", "run rejected · " + response.report.errors + " validation errors");
        setStatus("failed");
        return;
      }
      runIdRef.current = response.runId;
      setStatus(finishedRunsRef.current.get(response.runId) ?? "running");
      setLogOpen(true);
    } catch (error) {
      pushLog("error", "run failed: " + String(error));
      setStatus("failed");
    } finally {
      setBusy(false);
    }
  }, [buildDoc, flash, pushLog]);

  const handleStop = useCallback(async () => {
    const runId = runIdRef.current;
    if (!runId) return;
    try {
      const stopped = await api.stopWorkflow(runId);
      pushLog(stopped ? "warn" : "info", stopped ? "stop requested" : "run already finished");
    } catch (error) {
      pushLog("error", "stop failed: " + String(error));
    }
  }, [pushLog]);

  const decide = useCallback(
    async (approved: boolean) => {
      if (!pending) return;
      const requestId = pending.requestId;
      setPending(null);
      try {
        await api.respondInteraction(requestId, approved);
      } catch (error) {
        pushLog("error", "interaction failed: " + String(error));
      }
    },
    [pending, pushLog],
  );

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        void handleSave();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [handleSave]);

  return (
    <div className="app">
      <NodeLibrary
        specs={specs}
        onAdd={addFromLibrary}
        disabled={status === "running" || recovering}
      />

      <Toolbar
        name={meta.name}
        status={status}
        nodeCount={nodes.length}
        edgeCount={edges.length}
        busy={busy || recovering}
        preview={isPreview}
        onNameChange={(name) => setMeta((current) => ({ ...current, name }))}
        onNew={handleNew}
        onDemo={handleDemo}
        onOpen={() => void openDialog()}
        onSave={() => void handleSave()}
        onValidate={() => void handleValidate()}
        onHistory={() => setHistoryOpen(true)}
        onRun={() => void handleRun()}
        onStop={() => void handleStop()}
      />

      <main className="stage">
        <ReactFlowProvider>
          <Canvas
            nodes={nodes}
            edges={edges}
            running={status === "running"}
            viewport={meta.viewport}
            viewportKey={viewportKey}
            onNodesChange={onNodesChange}
            onEdgesChange={onEdgesChange}
            onConnect={onConnect}
            onDropNode={addNode}
            onViewportChange={(viewport) =>
              setMeta((current) => ({
                ...current,
                viewport: { x: viewport.x, y: viewport.y, zoom: viewport.zoom },
              }))
            }
          />
        </ReactFlowProvider>
        {problemsOpen && report ? (
          <ProblemsPanel report={report} onClose={() => setProblemsOpen(false)} />
        ) : null}
      </main>

      <LogPanel
        entries={logs}
        open={logOpen}
        status={status}
        onToggle={() => setLogOpen((open) => !open)}
        onClear={() => setLogs([])}
      />

      <WorkflowDialog
        open={dialogOpen}
        workflows={workflows}
        busy={dialogBusy}
        error={dialogError}
        onClose={() => setDialogOpen(false)}
        onLoad={(name) => void loadNamed(name)}
        onDelete={(name) => void deleteNamed(name)}
      />

      <InteractionDialog request={pending} onDecide={(approved) => void decide(approved)} />

      <RunHistoryDialog open={historyOpen} onClose={() => setHistoryOpen(false)} />

      <ConfirmDialog
        open={confirmAction !== null}
        title={confirmAction === "demo" ? "载入示例" : "新建工作流"}
        message={
          confirmAction === "demo"
            ? "载入示例会替换当前画布，未保存的修改将丢失。"
            : "新建会清空当前画布，未保存的修改将丢失。"
        }
        confirmLabel={confirmAction === "demo" ? "载入示例" : "清空并新建"}
        onConfirm={confirmReplace}
        onCancel={() => setConfirmAction(null)}
      />

      {persistenceError ? (
        <div className="persistence-alert" role="alert">
          <div>
            <div className="persistence-alert__title">持久化失败</div>
            <div className="persistence-alert__body">{persistenceError}</div>
          </div>
          <button
            type="button"
            className="persistence-alert__close"
            onClick={() => setPersistenceError(null)}
            aria-label="关闭持久化错误提示"
          >
            ×
          </button>
        </div>
      ) : null}

      {toast ? <div className="toast">{toast}</div> : null}
    </div>
  );
}
