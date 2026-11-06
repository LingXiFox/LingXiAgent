import { useEffect, useMemo, useRef, useState } from "react";

import { api } from "../lib/api";
import type { UiRunStatus } from "../lib/log";
import type {
  AgentConfigRevision,
  AssetKind,
  AssetRef,
  AgentConfigSnapshot,
  AgentInstance,
  AgentUsage,
  ConfigChange,
  ConversationMessage,
  ConversationRecord,
  FileEntry,
  FileMatch,
  FileSnapshot,
  GitCommit,
  GitEntry,
  InstructionDocument,
  PermissionMode,
  PendingReview,
  ProjectRecord,
  RunEvent,
  TaskSession,
} from "../lib/types";
import "../styles-project.css";

const STATE_TEXT: Record<string, string> = {
  pending: "等待",
  running: "执行中",
  pausing: "等待安全暂停点",
  paused: "已暂停",
  waiting_approval: "等待审批",
  blocked: "受阻",
  completed: "已完成",
  failed: "失败",
  cancelled: "已取消",
  interrupted: "已中断",
};

function stateText(state: string): string {
  return STATE_TEXT[state] ?? state;
}

function usageTotal(usage: AgentUsage): number {
  return usage.promptTokens + usage.completionTokens;
}

function eventAgentId(event: RunEvent): string | null {
  if (event.type !== "agent.event") return null;
  return "agentInstanceId" in event.event ? (event.event.agentInstanceId ?? null) : null;
}

function summarize(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function configFrom(agent: AgentInstance): AgentConfigSnapshot {
  return {
    ...agent.config,
    toolset: [...agent.config.toolset],
    skills: [...agent.config.skills],
    lsp: [...agent.config.lsp],
  };
}

function Markdown({ text }: { text: string }) {
  const parts = text.split(/```/g);
  return (
    <div className="markdown">
      {parts.map((part, index) => {
        if (index % 2 === 1) {
          const newline = part.indexOf("\n");
          const language = newline > 0 ? part.slice(0, newline).trim() : "";
          const code = newline > 0 ? part.slice(newline + 1) : part;
          return (
            <div className="code-block" key={index}>
              <span className="code-block__lang">{language || "text"}</span>
              <pre>{code}</pre>
            </div>
          );
        }
        const lines = part.split("\n");
        return (
          <div key={index}>
            {lines.map((line, lineIndex) => {
              if (line.startsWith("### ")) return <h4 key={lineIndex}>{line.slice(4)}</h4>;
              if (line.startsWith("## ")) return <h3 key={lineIndex}>{line.slice(3)}</h3>;
              if (line.startsWith("# ")) return <h2 key={lineIndex}>{line.slice(2)}</h2>;
              if (line.startsWith("- ")) return <li key={lineIndex}>{line.slice(2)}</li>;
              if (!line.trim()) return <br key={lineIndex} />;
              return <p key={lineIndex}>{line}</p>;
            })}
          </div>
        );
      })}
    </div>
  );
}

interface ToolCard {
  toolCallId: string;
  name: string;
  arguments: string;
  result?: string;
  error?: string | null;
  ok?: boolean;
  durationMs?: number;
}

interface ProjectWorkbenchProps {
  session: TaskSession | null;
  events: RunEvent[];
  status: UiRunStatus;
  selected: string | null;
  projects: ProjectRecord[];
  project: ProjectRecord | null;
  conversations: ConversationRecord[];
  conversation: ConversationRecord | null;
  messages: ConversationMessage[];
  permissionMode: PermissionMode;
  model: string;
  reasoning: string;
  quickEditError: string | null;
  onSelect: (agentInstanceId: string | null) => void;
  onOpenProject: () => Promise<void>;
  onSelectProject: (project: ProjectRecord) => Promise<void>;
  onNewConversation: () => Promise<void>;
  onNewTeam: () => Promise<void>;
  onSelectConversation: (conversationId: string) => Promise<void>;
  onAssetImported: (asset: AssetRef) => void;
  onSend: (text: string, agentNodeId?: string | null, attachments?: AssetRef[]) => Promise<void>;
  onStop: () => Promise<void>;
  onQuickConfig: (params: Record<string, unknown>) => Promise<void>;
  onPauseAgent: (agentInstanceId: string) => void;
  onResumeAgent: (agentInstanceId: string) => void;
  onCancelAgent: (agentInstanceId: string) => void;
  onPauseWorkflow: () => void;
  onResumeWorkflow: () => void;
  onDirective: (agentInstanceId: string, text: string) => Promise<void>;
  onPreviewConfig: (agentInstanceId: string, config: AgentConfigSnapshot) => Promise<ConfigChange[]>;
  onApplyConfig: (
    agentInstanceId: string,
    config: AgentConfigSnapshot,
    expectedRevision: number,
  ) => Promise<AgentConfigRevision>;
  onLocateNode: (agent: AgentInstance) => void;
}

export function ProjectWorkbench({
  session,
  events,
  status,
  selected,
  projects,
  project,
  conversations,
  conversation,
  messages,
  permissionMode,
  model,
  reasoning,
  quickEditError,
  onSelect,
  onOpenProject,
  onSelectProject,
  onNewConversation,
  onNewTeam,
  onSelectConversation,
  onAssetImported,
  onSend,
  onStop,
  onQuickConfig,
  onPauseAgent,
  onResumeAgent,
  onCancelAgent,
  onPauseWorkflow,
  onResumeWorkflow,
  onDirective,
  onPreviewConfig,
  onApplyConfig,
  onLocateNode,
}: ProjectWorkbenchProps) {
  const agents = useMemo(
    () =>
      session
        ? Object.values(session.agents).sort((left, right) => left.createdAtMs - right.createdAtMs)
        : [],
    [session],
  );
  const active = agents.find((agent) => agent.instanceId === selected) ?? null;
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [sidebarWidth, setSidebarWidth] = useState(() => {
    if (typeof window === "undefined") return 250;
    const stored = Number(window.localStorage.getItem("lingxi.sidebarWidth"));
    return Number.isFinite(stored) && stored >= 210 && stored <= 460 ? stored : 250;
  });
  // The normal-user view opens on the conversation, not on the dashboard.
  // 总览 stays one click away and remains the team view for power users.
  const [overview, setOverview] = useState(false);
  const [tree, setTree] = useState<Record<string, FileEntry[]>>({});
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [showIgnored, setShowIgnored] = useState(false);
  const [query, setQuery] = useState("");
  const [matches, setMatches] = useState<FileMatch[]>([]);
  const [file, setFile] = useState<FileSnapshot | null>(null);
  const [fileDraft, setFileDraft] = useState("");
  const [fileError, setFileError] = useState("");
  const [fileSaved, setFileSaved] = useState("");
  const [gitStatus, setGitStatus] = useState<GitEntry[]>([]);
  const [gitLog, setGitLog] = useState<GitCommit[]>([]);
  const [gitDiff, setGitDiff] = useState("");
  const [rules, setRules] = useState<InstructionDocument[]>([]);
  const [panel, setPanel] = useState<"files" | "git" | "rules" | "config" | null>(null);
  const [composer, setComposer] = useState("");
  const [sending, setSending] = useState(false);
  const [sendMode, setSendMode] = useState<"enter" | "modifier">(() => {
    if (typeof window === "undefined") return "enter";
    return window.localStorage.getItem("lingxi.composerSend") === "modifier" ? "modifier" : "enter";
  });
  const [attachments, setAttachments] = useState<AssetRef[]>([]);
  const [attachmentPreviews, setAttachmentPreviews] = useState<Record<string, string>>({});
  const [attachmentError, setAttachmentError] = useState("");
  const [dragActive, setDragActive] = useState(false);
  const [directive, setDirective] = useState("");
  const [draft, setDraft] = useState<AgentConfigSnapshot | null>(null);
  const [preview, setPreview] = useState<ConfigChange[] | null>(null);
  const [configBusy, setConfigBusy] = useState(false);
  const [configNote, setConfigNote] = useState("");
  const [actionError, setActionError] = useState("");
  const [activationChoice, setActivationChoice] = useState<Record<string, string>>({});
  // Turning on YOLO is a deliberate, confirmed action; the select alone is
  // never enough because this mode changes what Rust may execute unattended.
  const [pendingYolo, setPendingYolo] = useState(false);
  const [seen, setSeen] = useState<Record<string, number>>({});
  const projectId = project?.projectId ?? null;
  const timelineRef = useRef<HTMLDivElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const projectKey = projectId ?? "";
  useEffect(() => {
    setTree({});
    setExpanded(new Set());
    setFile(null);
    setMatches([]);
    setGitDiff("");
    if (!projectId) return;
    let cancelled = false;
    void api
      .projectTree(projectId, "", showIgnored)
      .then((entries) => {
        if (!cancelled) setTree({ "": entries });
      })
      .catch((error) => {
        if (!cancelled) setFileError(String(error));
      });
    void api
      .projectGitStatus(projectId)
      .then((entries) => {
        if (!cancelled) setGitStatus(entries);
      })
      .catch(() => undefined);
    void api
      .projectGitLog(projectId, 8)
      .then((commits) => {
        if (!cancelled) setGitLog(commits);
      })
      .catch(() => undefined);
    void api
      .projectRules(projectId)
      .then((documents) => {
        if (!cancelled) setRules(documents);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [projectId, projectKey, showIgnored]);

  useEffect(() => {
    if (!projectId || query.trim().length < 2) {
      setMatches([]);
      return;
    }
    let cancelled = false;
    const timer = window.setTimeout(() => {
      void api
        .projectSearch(projectId, query.trim(), "", 40)
        .then((found) => {
          if (!cancelled) setMatches(found);
        })
        .catch(() => undefined);
    }, 220);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [projectId, query]);

  useEffect(() => {
    if (!active) {
      setDraft(null);
      setPreview(null);
      return;
    }
    setDraft(configFrom(active));
    setPreview(null);
    setSeen((current) => ({ ...current, [active.instanceId]: events.length }));
    // Re-seed only when the agent or its applied revision changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active?.instanceId, active?.config.revision]);

  useEffect(() => {
    if (!selected) return;
    setOverview(false);
    setSeen((current) => ({ ...current, [selected]: events.length }));
  }, [events.length, selected]);

  useEffect(() => {
    const node = timelineRef.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, [messages.length, events.length, selected]);

  const agentEvents = useMemo(
    () => (active ? events.filter((event) => eventAgentId(event) === active.instanceId) : []),
    [active, events],
  );
  const activation = useMemo(() => {
    if (!active) return null;
    const choice = activationChoice[active.instanceId];
    return (
      active.activations.find((entry) => entry.activationId === choice) ??
      active.activations.find((entry) => entry.activationId === active.currentActivation) ??
      active.activations[active.activations.length - 1] ??
      null
    );
  }, [activationChoice, active]);
  const stream = useMemo(() => {
    if (!activation) return "";
    return agentEvents
      .filter(
        (event) =>
          event.type === "agent.event" &&
          event.event.type === "agent.delta" &&
          event.event.activationId === activation.activationId,
      )
      .map((event) => (event.type === "agent.event" && event.event.type === "agent.delta" ? event.event.delta : ""))
      .join("");
  }, [activation, agentEvents]);
  const toolCards = useMemo(() => {
    const cards = new Map<string, ToolCard>();
    for (const event of agentEvents) {
      if (event.type !== "agent.event") continue;
      if (event.event.type === "agent.tool.started") {
        cards.set(event.event.toolCallId, {
          toolCallId: event.event.toolCallId,
          name: event.event.toolName,
          arguments: event.event.arguments,
        });
      }
      if (event.event.type === "agent.tool.finished") {
        const card = cards.get(event.event.toolCallId) ?? {
          toolCallId: event.event.toolCallId,
          name: event.event.toolName,
          arguments: "",
        };
        cards.set(event.event.toolCallId, {
          ...card,
          result: event.event.result,
          error: event.event.error,
          ok: event.event.ok,
          durationMs: event.event.durationMs,
        });
      }
    }
    return [...cards.values()];
  }, [agentEvents]);
  const unread = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const agent of agents) {
      const total = events.filter((event) => eventAgentId(event) === agent.instanceId).length;
      counts[agent.instanceId] = Math.max(0, total - (seen[agent.instanceId] ?? 0));
    }
    return counts;
  }, [agents, events, seen]);
  const totals = useMemo(() => {
    const total = { modelCalls: 0, toolCalls: 0, tokens: 0 };
    for (const agent of agents) {
      total.modelCalls += agent.usage.modelCalls;
      total.toolCalls += agent.usage.toolCalls;
      total.tokens += usageTotal(agent.usage);
    }
    return total;
  }, [agents]);
  const teamMessages = useMemo(() => {
    if (!session) return [];
    const ids = new Set(agents.map((agent) => agent.instanceId));
    return session.messages.filter(
      (message) => ids.has(message.sender) || ids.has(message.recipient) || message.recipient === "broadcast",
    );
  }, [agents, session]);
  const reviews = session?.pendingReviews.filter((review) => !review.resolved) ?? [];
  const visibleMessages = useMemo(() => {
    return messages.filter((message) => {
      if (message.role === "user") return true;
      if (!active) return true;
      return (
        message.agentNodeId === active.nodeId ||
        (!message.agentNodeId && message.agentInstanceId === active.instanceId)
      );
    });
  }, [active, messages]);

  const toggleDirectory = async (entry: FileEntry) => {
    if (!projectId) return;
    const next = new Set(expanded);
    if (next.has(entry.path)) {
      next.delete(entry.path);
      setExpanded(next);
      return;
    }
    next.add(entry.path);
    setExpanded(next);
    if (!tree[entry.path]) {
      try {
        const entries = await api.projectTree(projectId, entry.path, showIgnored);
        setTree((current) => ({ ...current, [entry.path]: entries }));
      } catch (error) {
        setFileError(String(error));
      }
    }
  };

  const openFile = async (path: string) => {
    if (!projectId) return;
    try {
      const snapshot = await api.projectRead(projectId, path);
      setFile(snapshot);
      setFileDraft(snapshot.content);
      setFileError("");
      setFileSaved("");
      setPanel("files");
    } catch (error) {
      setFileError(String(error));
    }
  };

  const saveFile = async () => {
    if (!projectId || !file) return;
    try {
      const saved = await api.projectWrite(projectId, file.path, fileDraft, file.version);
      setFile(saved);
      setFileDraft(saved.content);
      setFileSaved("已保存 · " + new Date().toLocaleTimeString());
      setFileError("");
    } catch (error) {
      setFileError("保存被拒绝：" + String(error));
    }
  };

  useEffect(() => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem("lingxi.composerSend", sendMode);
    }
  }, [sendMode]);

  useEffect(() => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem("lingxi.sidebarWidth", String(sidebarWidth));
    }
  }, [sidebarWidth]);

  const beginSidebarResize = (event: { clientX: number; preventDefault: () => void }) => {
    event.preventDefault();
    const startX = event.clientX;
    const startWidth = sidebarWidth;
    const move = (moveEvent: PointerEvent) => {
      setSidebarWidth(Math.max(210, Math.min(460, startWidth + moveEvent.clientX - startX)));
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      document.body.classList.remove("is-resizing-sidebar");
    };
    document.body.classList.add("is-resizing-sidebar");
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  const attachmentKind = (file: File): AssetKind => {
    if (file.type.startsWith("image/")) return "image";
    if (file.type.startsWith("audio/")) return "audio";
    if (file.type.startsWith("video/")) return "video";
    return "document";
  };

  const addFiles = async (files: File[]) => {
    setAttachmentError("");
    const room = 6 - attachments.length;
    if (room <= 0) {
      setAttachmentError("每次最多 6 个附件");
      return;
    }
    for (const file of files.slice(0, room)) {
      if (file.size > 8 * 1024 * 1024) {
        setAttachmentError(file.name + " 超过 8 MiB，未导入");
        continue;
      }
      try {
        const kind = attachmentKind(file);
        const asset = await api.assetImportFile(file, kind);
        onAssetImported(asset);
        setAttachments((current) =>
          current.some((entry) => entry.id === asset.id) ? current : [...current, asset],
        );
        if (kind === "image") {
          void api
            .assetPreview(asset.id, asset.mime)
            .then((url) => setAttachmentPreviews((current) => ({ ...current, [asset.id]: url })))
            .catch(() => undefined);
        }
      } catch (error) {
        setAttachmentError("附件导入失败：" + String(error));
      }
    }
  };

  const removeAttachment = (id: string) => {
    setAttachments((current) => current.filter((entry) => entry.id !== id));
    setAttachmentPreviews((current) => {
      const next = { ...current };
      delete next[id];
      return next;
    });
  };

  const sendComposer = async () => {
    const text = composer.trim();
    if (!text || sending) return;
    if (status === "running" && attachments.length > 0) {
      setAttachmentError("运行中只能发送文字纠偏指令；附件请在下一次运行前添加");
      return;
    }
    setSending(true);
    setAttachmentError("");
    try {
      await onSend(text, active?.nodeId ?? null, attachments);
      setComposer("");
      setAttachments([]);
      setAttachmentPreviews({});
    } catch (error) {
      setAttachmentError("发送失败：" + String(error));
    } finally {
      setSending(false);
    }
  };

  const changePermission = (next: string) => {
    if (next === "yolo" && permissionMode !== "yolo") {
      setPendingYolo(true);
      return;
    }
    void onQuickConfig({ permissionMode: next });
  };

  const enableYolo = () => {
    setPendingYolo(false);
    void onQuickConfig({ permissionMode: "yolo" });
  };

  const sendDirective = async () => {
    if (!active || !directive.trim()) return;
    setActionError("");
    try {
      await onDirective(active.instanceId, directive.trim());
      setDirective("");
      setConfigNote("纠偏指令已进入总线，将在最近的安全执行点交给 Agent");
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error));
    }
  };

  const previewConfig = async () => {
    if (!active || !draft) return;
    setConfigBusy(true);
    setActionError("");
    try {
      const changes = await onPreviewConfig(active.instanceId, draft);
      setPreview(changes);
      setConfigNote(changes.length === 0 ? "配置没有变化" : "预览完成，确认后应用到当前任务");
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error));
    } finally {
      setConfigBusy(false);
    }
  };

  const commitConfig = async () => {
    if (!active || !draft) return;
    setConfigBusy(true);
    setActionError("");
    try {
      const revision = await onApplyConfig(active.instanceId, draft, active.config.revision);
      setConfigNote(
        revision.status === "pending"
          ? "版本 " + revision.revision + " 已提交，等待安全执行点生效"
          : "版本 " + revision.revision + " 状态：" + revision.status,
      );
      setPreview(null);
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error));
    } finally {
      setConfigBusy(false);
    }
  };

  const setField = <K extends keyof AgentConfigSnapshot>(key: K, value: AgentConfigSnapshot[K]) => {
    setDraft((current) => (current ? { ...current, [key]: value } : current));
    setPreview(null);
    setConfigNote("");
  };

  const renderTree = (path: string, depth: number) => {
    const entries = tree[path] ?? [];
    return (
      <ul className="project-tree" style={{ paddingLeft: depth ? 12 : 0 }}>
        {entries.map((entry) => (
          <li key={entry.path}>
            <button
              type="button"
              className={"project-tree__row" + (file?.path === entry.path ? " is-active" : "")}
              onClick={() => (entry.kind === "dir" ? void toggleDirectory(entry) : void openFile(entry.path))}
              data-testid={"file-entry-" + entry.name}
            >
              <span className="project-tree__icon">{entry.kind === "dir" ? (expanded.has(entry.path) ? "▾" : "▸") : "·"}</span>
              <span>{entry.name}</span>
            </button>
            {entry.kind === "dir" && expanded.has(entry.path) ? renderTree(entry.path, depth + 1) : null}
          </li>
        ))}
      </ul>
    );
  };

  const renderOverview = () => (
    <div className="workbench__body workbench__overview" data-testid="agent-overview">
      <div className="overview-grid">
        <section className="agent-card">
          <h3>团队状态</h3>
          <p className="overview-lead">
            {session ? (session.state === "running" ? "任务执行中" : "任务" + stateText(session.state)) : "还没有运行记录"} ·{" "}
            {agents.length} 个 Agent
          </p>
          <ul className="overview-agents">
            {agents.map((agent) => (
              <li key={agent.instanceId}>
                <button type="button" className="overview-agent" onClick={() => onSelect(agent.instanceId)}>
                  <span className={"agent-state agent-state--" + agent.state}>{stateText(agent.state)}</span>
                  <span>{agent.label}</span>
                  <small>{agent.activations.length} 次执行 · {agent.usage.toolCalls} 次工具调用</small>
                </button>
              </li>
            ))}
          </ul>
          {agents.length === 0 ? <p className="muted">发送第一条任务后，真实 Agent 会出现在这里。</p> : null}
        </section>
        <section className="agent-card">
          <h3>成本与交付</h3>
          <div className="agent-costs">
            <span><strong>{totals.modelCalls}</strong>模型调用</span>
            <span><strong>{totals.toolCalls}</strong>工具调用</span>
            <span><strong>{totals.tokens}</strong>Token</span>
          </div>
          {teamMessages
            .filter((message) => message.type === "task.result" || message.type === "task.blocked")
            .slice(-3)
            .reverse()
            .map((message) => (
              <div className="overview-result" key={message.messageId}>
                <span>{session?.agents[message.sender]?.label ?? message.sender}</span>
                <p>{summarize(message.payload)}</p>
              </div>
            ))}
          {teamMessages.filter((message) => message.type === "task.result").length === 0 ? (
            <p className="muted">还没有 Agent 交付结果。</p>
          ) : null}
        </section>
        <section className="agent-card overview-timeline">
          <h3>跨 Agent 消息时间线</h3>
          {teamMessages.length === 0 ? (
            <p className="muted">消息总线为空。</p>
          ) : (
            <ol>
              {teamMessages.slice(-20).map((message) => (
                <li key={message.messageId}>
                  <span>{message.type}</span>
                  <span>
                    {session?.agents[message.sender]?.label ?? message.sender} →{" "}
                    {message.recipient === "broadcast" ? "团队" : session?.agents[message.recipient]?.label ?? message.recipient}
                  </span>
                  <small>{message.status} · {new Date(message.createdAtMs).toLocaleTimeString()}</small>
                </li>
              ))}
            </ol>
          )}
        </section>
        <section className="agent-card" data-testid="overview-artifacts">
          <h3>交付物</h3>
          {!session || session.artifacts.length === 0 ? (
            <p className="muted">本次运行还没有交付物。Artifact 只在 Rust 真实产出后出现。</p>
          ) : (
            <ul className="artifact-list">
              {session.artifacts.map((artifact) => (
                <li key={artifact.id}>
                  <strong>{artifact.name}</strong>
                  <span>{artifact.kind}{artifact.mime ? ` · ${artifact.mime}` : ""}</span>
                  {artifact.size ? <small>{artifact.size} bytes</small> : null}
                </li>
              ))}
            </ul>
          )}
        </section>
        <section className="agent-card">
          <h3>待处理审批 / 核对</h3>
          {reviews.length === 0 ? "没有待处理项。" : (
            <ul className="overview-reviews">
              {reviews.map((review: PendingReview) => (
                <li key={review.reviewId}>
                  <strong>{review.toolName || "未知工具"}</strong>
                  <p>{review.reason}</p>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </div>
  );

  return (
    <section className="project-workbench" data-testid="agent-workbench">
      <aside
        className={"project-sidebar" + (sidebarOpen ? "" : " is-collapsed")}
        style={sidebarOpen ? { width: sidebarWidth, flexBasis: sidebarWidth } : undefined}
      >
        {sidebarOpen ? (
          <>
            <div className="project-sidebar__head">
              <strong>项目</strong>
              <button type="button" className="btn btn--ghost btn--compact" onClick={() => setSidebarOpen(false)} title="收起侧栏" data-testid="sidebar-collapse">
                «
              </button>
            </div>
            <button type="button" className="btn btn--run project-open" data-testid="project-open-folder" onClick={() => void onOpenProject()}>
              打开项目文件夹
            </button>
            <div className="project-recent">
              {projects.map((entry) => (
                <button
                  type="button"
                  key={entry.projectId}
                  className={"project-recent__item" + (entry.projectId === projectId ? " is-active" : "")}
                  onClick={() => void onSelectProject(entry)}
                  title={entry.root}
                  data-testid={"project-recent-" + entry.projectId}
                >
                  {entry.name}
                </button>
              ))}
            </div>
            <div className="project-sidebar__section">
              <div className="project-sidebar__title">
                <span>会话</span>
                <button type="button" className="text-button" data-testid="new-session" onClick={() => void onNewConversation()}>
                  + 新会话
                </button>
              </div>
              <button type="button" className="text-button" data-testid="new-team" onClick={() => void onNewTeam()}>
                + 公司团队
              </button>
              <ul className="conversation-list">
                {conversations.map((entry) => (
                  <li key={entry.conversationId}>
                    <button
                      type="button"
                      className={"conversation-item" + (entry.conversationId === conversation?.conversationId ? " is-active" : "")}
                      onClick={() => void onSelectConversation(entry.conversationId)}
                      data-testid={"conversation-" + entry.conversationId}
                    >
                      <span>{entry.title}</span>
                      <small>{new Date(entry.updatedAtMs).toLocaleDateString()}</small>
                    </button>
                  </li>
                ))}
              </ul>
            </div>
            {project ? (
              <div className="project-sidebar__section project-files">
                <div className="project-sidebar__title"><span>文件</span></div>
                <input
                  className="project-search"
                  placeholder="搜索文件内容"
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  data-testid="project-search"
                />
                {matches.length > 0 ? (
                  <ul className="search-results" data-testid="project-search-results">
                    {matches.map((match) => (
                      <li key={match.path + ":" + match.line}>
                        <button type="button" onClick={() => void openFile(match.path)}>
                          {match.path}:{match.line}
                          <small>{match.text.slice(0, 60)}</small>
                        </button>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <>
                    <label className="project-ignore">
                      <input type="checkbox" checked={showIgnored} onChange={(event) => setShowIgnored(event.target.checked)} />
                      显示忽略文件
                    </label>
                    <div className="tree-scroll" data-testid="project-tree">{renderTree("", 0)}</div>
                  </>
                )}
                <div className="git-summary" data-testid="git-status">
                  <span>Git · {gitStatus.length} 个变更</span>
                  <button type="button" className="text-button" onClick={() => setPanel("git")}>查看</button>
                </div>
              </div>
            ) : (
              <p className="project-empty">打开一个已存在的项目文件夹后，文件、会话和 Agent 都会绑定到它。</p>
            )}
            <button type="button" className="btn btn--ghost btn--compact" onClick={() => setPanel("rules")}>
              项目规则
            </button>
          </>
        ) : (
          <button type="button" className="btn btn--ghost btn--compact sidebar-expand" onClick={() => setSidebarOpen(true)} title="展开侧栏" data-testid="sidebar-expand">
            »
          </button>
        )}
      </aside>
      {sidebarOpen ? (
        <div
          className="project-sidebar__resizer"
          role="separator"
          aria-orientation="vertical"
          aria-label="调整侧栏宽度"
          data-testid="sidebar-resizer"
          onPointerDown={beginSidebarResize}
        />
      ) : null}

      <section className="project-main">
        <div className="workbench__tabs" role="tablist" data-testid="agent-tabs">
          <button
            type="button"
            role="tab"
            aria-selected={overview && selected === null}
            className={"workbench__tab" + (overview && selected === null ? " is-active" : "")}
            data-testid="agent-tab-overview"
            onClick={() => {
              setOverview(true);
              onSelect(null);
            }}
          >
            总览
          </button>
          {agents.map((agent) => (
            <button
              type="button"
              role="tab"
              key={agent.instanceId}
              aria-selected={selected === agent.instanceId}
              className={"workbench__tab workbench__tab--agent" + (selected === agent.instanceId ? " is-active" : "")}
              data-testid={"agent-tab-" + agent.nodeId}
              onClick={() => {
                setOverview(false);
                onSelect(agent.instanceId);
              }}
            >
              <span className={"agent-state agent-state--" + agent.state}>{stateText(agent.state)}</span>
              <span className="workbench__tab-label">{agent.label}</span>
              {unread[agent.instanceId] > 0 && selected !== agent.instanceId ? (
                <span className="workbench__unread">{unread[agent.instanceId]}</span>
              ) : null}
            </button>
          ))}
          <span className="workbench__spacer" />
          <span className={"status status--" + status}>
            <span className="status__dot" />
            {status === "running" ? "运行中" : status === "completed" ? "已完成" : status === "failed" ? "失败" : status === "cancelled" ? "已终止" : status === "interrupted" ? "已中断" : "空闲"}
          </span>
        </div>

        <div className="project-body">
          <div className="chat-pane">
            {active ? (
              <header className="agent-head">
                <div>
                  <h2>{active.label}</h2>
                  <p className="agent-head__meta">
                    {active.nodeId} · {stateText(active.state)} · 版本 {active.config.revision}
                  </p>
                </div>
                <div className="agent-head__actions">
                  <button type="button" className="btn btn--ghost btn--compact" data-testid="agent-locate" onClick={() => onLocateNode(active)}>
                    定位节点
                  </button>
                  <button type="button" className="btn btn--ghost btn--compact" data-testid="agent-pause" onClick={() => onPauseAgent(active.instanceId)} disabled={active.state !== "running"}>
                    暂停
                  </button>
                  <button type="button" className="btn btn--ghost btn--compact" data-testid="agent-resume" onClick={() => onResumeAgent(active.instanceId)} disabled={active.state !== "paused" && active.state !== "pausing"}>
                    继续
                  </button>
                  <button type="button" className="btn btn--ghost btn--compact" data-testid="agent-cancel" onClick={() => onCancelAgent(active.instanceId)} disabled={active.state === "completed" || active.state === "failed" || active.state === "cancelled"}>
                    取消
                  </button>
                  <button type="button" className="btn btn--ghost btn--compact" data-testid="workbench-pause-workflow" onClick={onPauseWorkflow} disabled={status !== "running"}>
                    暂停工作流
                  </button>
                  <button type="button" className="btn btn--ghost btn--compact" data-testid="workbench-resume-workflow" onClick={onResumeWorkflow} disabled={status !== "running"}>
                    继续工作流
                  </button>
                  <div className="activation-switch">
                    {active.activations.map((entry) => (
                      <button
                        type="button"
                        key={entry.activationId}
                        className={"activation-pill" + (activation?.activationId === entry.activationId ? " is-active" : "")}
                        onClick={() => setActivationChoice((current) => ({ ...current, [active.instanceId]: entry.activationId }))}
                      >
                        第 {entry.index} 次
                      </button>
                    ))}
                  </div>
                </div>
              </header>
            ) : null}

            <div className="chat-timeline" ref={timelineRef} data-testid="conversation-timeline">
              {overview && !active && selected === null ? renderOverview() : (
                <>
                  {visibleMessages.map((message) => (
                    <article className={"chat-message chat-message--" + message.role} key={message.messageId}>
                      <div className="chat-message__meta">
                        <span>{message.role === "user" ? "你" : active?.label ?? "Agent"}</span>
                        <span>{new Date(message.createdAtMs).toLocaleTimeString()}</span>
                      </div>
                      <Markdown text={message.content} />
                    </article>
                  ))}
                  {active && toolCards.length > 0 ? (
                    <div className="tool-stack">
                      {toolCards.map((tool) => (
                        <details className={"tool-card" + (tool.ok === false ? " is-failed" : "")} key={tool.toolCallId} data-testid="agent-tool">
                          <summary>
                            <span>{tool.ok === false ? "✕" : tool.ok ? "✓" : "…"}</span>
                            <strong>{tool.name}</strong>
                            <code>{tool.arguments.slice(0, 110)}</code>
                            {tool.durationMs !== undefined ? <small>{tool.durationMs}ms</small> : null}
                          </summary>
                          <pre>{tool.result || tool.error || "执行中…"}</pre>
                        </details>
                      ))}
                    </div>
                  ) : null}
                  {stream ? (
                    <article className="chat-message chat-message--assistant chat-message--streaming" data-testid="agent-stream">
                      <div className="chat-message__meta"><span>{active?.label ?? "Agent"}</span><span>输出中…</span></div>
                      <Markdown text={stream} />
                    </article>
                  ) : null}
                  {active && active.activations.length === 0 && visibleMessages.length === 0 ? (
                    <p className="muted">等待该 Agent 第一次执行。这里只显示真实事件，不会伪造进度。</p>
                  ) : null}
                  {!active && selected !== null ? <p className="muted">所选 Agent 已不在当前运行中。</p> : null}
                  {!active && selected === null && visibleMessages.length === 0 ? (
                    <p className="muted">在下方输入第一条任务。项目、权限和模型都绑定到当前会话。</p>
                  ) : null}
                  {active ? (
                    <div className="agent-card agent-messages-card" data-testid="agent-messages">
                      <h3>Agent 通信</h3>
                      {teamMessages.filter(
                        (message) =>
                          message.sender === active.instanceId ||
                          message.recipient === active.instanceId ||
                          message.recipient === "broadcast",
                      ).length === 0 ? (
                        <p className="muted">该 Agent 还没有总线消息。</p>
                      ) : (
                        <ul className="agent-message-list">
                          {teamMessages
                            .filter(
                              (message) =>
                                message.sender === active.instanceId ||
                                message.recipient === active.instanceId ||
                                message.recipient === "broadcast",
                            )
                            .slice(-10)
                            .map((message) => (
                              <li key={message.messageId}>
                                <span>{message.type}</span>
                                <small>{message.status} · {new Date(message.createdAtMs).toLocaleTimeString()}</small>
                                <p>{summarize(message.payload)}</p>
                              </li>
                            ))}
                        </ul>
                      )}
                    </div>
                  ) : null}
                  {active ? (
                    <details className="agent-card raw-events" data-testid="agent-raw-events">
                      <summary>原始事件 · {agentEvents.length} 条（最近 40）</summary>
                      <pre>{JSON.stringify(agentEvents.slice(-40), null, 2)}</pre>
                    </details>
                  ) : null}
                  {active && active.activations.length > 0 && activation ? (
                    <div className="agent-card agent-facts-card">
                      <h3>执行状态</h3>
                      <dl className="agent-facts">
                        <dt>激活</dt><dd>{activation.activationId.split("#").pop()}</dd>
                        <dt>配置版本</dt><dd>{activation.configRevision}</dd>
                        <dt>迭代</dt><dd>{activation.iterations}</dd>
                        {activation.error ? (<><dt>错误</dt><dd className="error-text">{activation.error}</dd></>) : null}
                      </dl>
                    </div>
                  ) : null}
                </>
              )}
            </div>

            <footer
              className={"composer" + (dragActive ? " is-dragging" : "")}
              data-testid="agent-composer"
              onDragOver={(event) => {
                if (event.dataTransfer.types.includes("Files")) {
                  event.preventDefault();
                  setDragActive(true);
                }
              }}
              onDragLeave={() => setDragActive(false)}
              onDrop={(event) => {
                if (event.dataTransfer.files.length > 0) {
                  event.preventDefault();
                  setDragActive(false);
                  void addFiles(Array.from(event.dataTransfer.files));
                }
              }}
            >
              {attachments.length > 0 ? (
                <div className="composer__attachments" data-testid="composer-attachments">
                  {attachments.map((asset) => (
                    <div className="composer__attachment" key={asset.id} data-testid={"composer-attachment-" + asset.kind}>
                      {attachmentPreviews[asset.id] ? (
                        <img src={attachmentPreviews[asset.id]} alt={asset.name} />
                      ) : (
                        <span className="composer__attachment-kind">{asset.kind}</span>
                      )}
                      <div>
                        <strong>{asset.name}</strong>
                        <small>{Math.max(1, Math.round(asset.size / 1024))} KiB · {asset.mime}</small>
                      </div>
                      <button
                        type="button"
                        className="text-button"
                        onClick={() => removeAttachment(asset.id)}
                        aria-label={"移除 " + asset.name}
                      >
                        ×
                      </button>
                    </div>
                  ))}
                </div>
              ) : null}
              <textarea
                rows={3}
                value={composer}
                placeholder={
                  status === "running"
                    ? "运行中发送会作为纠偏指令进入当前 Agent"
                    : sendMode === "enter"
                      ? "描述任务，Enter 发送，Shift+Enter 换行；可拖入文件或粘贴图片"
                      : "描述任务，Ctrl/Cmd+Enter 发送，Enter 换行；可拖入文件或粘贴图片"
                }
                onChange={(event) => setComposer(event.target.value)}
                onPaste={(event) => {
                  const files = Array.from(event.clipboardData.files);
                  if (files.length > 0) {
                    event.preventDefault();
                    void addFiles(files);
                  }
                }}
                onKeyDown={(event) => {
                  const send =
                    event.key === "Enter" &&
                    (sendMode === "enter" ? !event.shiftKey : event.metaKey || event.ctrlKey);
                  if (send) {
                    event.preventDefault();
                    void sendComposer();
                  }
                }}
                data-testid="composer-input"
              />
              <input
                ref={fileInputRef}
                type="file"
                multiple
                hidden
                data-testid="composer-file-input"
                onChange={(event) => {
                  const files = Array.from(event.target.files ?? []);
                  event.target.value = "";
                  void addFiles(files);
                }}
              />
              <div className="composer__bar">
                <button
                  type="button"
                  className="btn btn--ghost btn--compact"
                  onClick={() => fileInputRef.current?.click()}
                  disabled={status === "running"}
                  title="添加图片、文档或其他附件"
                  data-testid="composer-attach"
                >
                  + 附件
                </button>
                <select
                  value={sendMode}
                  onChange={(event) => setSendMode(event.target.value === "modifier" ? "modifier" : "enter")}
                  data-testid="composer-send-mode"
                  title="发送快捷键"
                >
                  <option value="enter">Enter 发送</option>
                  <option value="modifier">Ctrl/Cmd+Enter 发送</option>
                </select>
                <select
                  value={permissionMode}
                  onChange={(event) => changePermission(event.target.value)}
                  data-testid="permission-mode"
                  title="权限模式由 Rust 执行层强制"
                >
                  <option value="ask">Ask · 每次询问</option>
                  <option value="workspace">Workspace · 项目内自动</option>
                  <option value="yolo">YOLO · 信任项目</option>
                </select>
                <select
                  value={model}
                  onChange={(event) => void onQuickConfig({ model: event.target.value })}
                  data-testid="workbench-model"
                  disabled={status === "running"}
                  title={status === "running" ? "运行中修改模型请在配置面板预览并应用" : undefined}
                >
                  <option value="gpt-4o-mini">gpt-4o-mini</option>
                  <option value="gpt-4.1">gpt-4.1</option>
                  <option value="claude-sonnet-4-5">claude-sonnet-4-5</option>
                  <option value="deepseek-chat">deepseek-chat</option>
                </select>
                <select
                  value={reasoning}
                  onChange={(event) => void onQuickConfig({ reasoning: event.target.value })}
                  data-testid="workbench-reasoning"
                  disabled={status === "running"}
                  title={status === "running" ? "运行中修改推理强度请在配置面板预览并应用" : undefined}
                >
                  <option value="auto">推理 auto</option>
                  <option value="low">推理 low</option>
                  <option value="medium">推理 medium</option>
                  <option value="high">推理 high</option>
                </select>
                <span className="composer__agent">{active ? active.label : "团队（默认第一个 Agent）"}</span>
                <span className="workbench__spacer" />
                <button type="button" className="btn btn--ghost btn--compact" onClick={() => setPanel(panel === "config" ? null : "config")} data-testid="agent-config-toggle">
                  配置
                </button>
                {status === "running" ? (
                  <button type="button" className="btn btn--danger btn--compact" data-testid="composer-stop" onClick={() => void onStop()}>
                    终止
                  </button>
                ) : null}
                {status === "running" ? (
                  <button type="button" className="btn btn--ghost btn--compact" data-testid="composer-interject" onClick={() => void sendComposer()} disabled={!composer.trim() || sending}>
                    发送指令
                  </button>
                ) : (
                  <button type="button" className="btn btn--run btn--compact" data-testid="composer-send" onClick={() => void sendComposer()} disabled={!composer.trim() || sending}>
                    发送
                  </button>
                )}
              </div>
              {permissionMode === "yolo" ? (
                <p className="composer__warning" data-testid="yolo-warning">
                  YOLO 会自动执行授权项目内的文件修改、构建与脚本，可能产生真实副作用。凭据、越界路径、破坏性 git 与高风险程序仍会被拦截；随时可切回 Ask。
                </p>
              ) : null}
              {attachmentError ? (
                <p className="error-text" data-testid="composer-attachment-error">{attachmentError}</p>
              ) : null}
              {quickEditError ? <p className="error-text">{quickEditError}</p> : null}
            </footer>
          </div>

          {panel ? (
            <aside className="aux-panel" data-testid="aux-panel">
              <div className="aux-panel__tabs">
                <button type="button" className={panel === "files" ? "is-active" : ""} onClick={() => setPanel("files")}>文件</button>
                <button type="button" className={panel === "git" ? "is-active" : ""} onClick={() => setPanel("git")}>Git</button>
                <button type="button" className={panel === "rules" ? "is-active" : ""} onClick={() => setPanel("rules")}>规则</button>
                <button type="button" className={panel === "config" ? "is-active" : ""} onClick={() => setPanel("config")}>运行配置</button>
                <button type="button" className="aux-panel__close" onClick={() => setPanel(null)}>×</button>
              </div>
              {panel === "files" ? (
                <div className="aux-panel__body">
                  {file ? (
                    <>
                      <div className="file-head">
                        <strong>{file.path}</strong>
                        <small>版本 {file.version.slice(0, 10)}</small>
                      </div>
                      <textarea className="file-editor" value={fileDraft} onChange={(event) => setFileDraft(event.target.value)} />
                      <div className="agent-card__actions">
                        <button type="button" className="btn btn--run btn--compact" onClick={() => void saveFile()}>保存（版本检查）</button>
                        <button type="button" className="btn btn--ghost btn--compact" onClick={() => void api.projectGitDiff(projectId ?? "", file.path).then(setGitDiff)}>查看差异</button>
                      </div>
                      {fileSaved ? <p className="muted">{fileSaved}</p> : null}
                      {fileError ? <p className="error-text">{fileError}</p> : null}
                      {gitDiff ? <pre className="diff-view">{gitDiff}</pre> : null}
                    </>
                  ) : (
                    <p className="muted">从左侧文件树或搜索结果打开文件。</p>
                  )}
                </div>
              ) : null}
              {panel === "git" ? (
                <div className="aux-panel__body">
                  <h3>工作区变更</h3>
                  {gitStatus.length === 0 ? <p className="muted">没有未提交变更。</p> : (
                    <ul className="git-list">
                      {gitStatus.map((entry) => (
                        <li key={entry.path}>
                          <button type="button" onClick={() => void api.projectGitDiff(projectId ?? "", entry.path).then(setGitDiff)}>
                            <span>{entry.status}</span>{entry.path}
                          </button>
                        </li>
                      ))}
                    </ul>
                  )}
                  {gitDiff ? <pre className="diff-view">{gitDiff}</pre> : null}
                  <h3>最近提交</h3>
                  <ul className="git-list">
                    {gitLog.map((commit) => (
                      <li key={commit.hash}><span>{commit.hash.slice(0, 7)}</span>{commit.subject}<small>{commit.author}</small></li>
                    ))}
                  </ul>
                </div>
              ) : null}
              {panel === "rules" ? (
                <div className="aux-panel__body">
                  <h3>适用规则</h3>
                  {rules.length === 0 ? <p className="muted">当前项目没有 AGENTS.md。</p> : rules.map((document) => (
                    <details key={document.path} open>
                      <summary>{document.path}</summary>
                      <pre className="rules-view">{document.content}</pre>
                    </details>
                  ))}
                </div>
              ) : null}
              {panel === "config" ? (
                <div className="aux-panel__body">
                  {active && draft ? (
                    <div className="agent-config" data-testid="agent-config">
                      <label>模型<input value={draft.model} onChange={(event) => setField("model", event.target.value)} /></label>
                      <label>Temperature<input type="number" step="0.1" value={draft.temperature} onChange={(event) => setField("temperature", Number(event.target.value))} /></label>
                      <label>角色提示词<textarea rows={3} value={draft.rolePrompt} onChange={(event) => setField("rolePrompt", event.target.value)} /></label>
                      <label>系统提示词<textarea rows={3} value={draft.systemPrompt} onChange={(event) => setField("systemPrompt", event.target.value)} /></label>
                      <label>最大迭代<input type="number" min={1} value={draft.maxIterations} onChange={(event) => setField("maxIterations", Number(event.target.value))} /></label>
                      <label>最大工具调用<input type="number" min={0} value={draft.maxToolCalls} onChange={(event) => setField("maxToolCalls", Number(event.target.value))} /></label>
                      <label>Token 预算<input type="number" min={0} value={draft.maxTotalTokens} onChange={(event) => setField("maxTotalTokens", Number(event.target.value))} /></label>
                      <label>超时 ms<input type="number" min={1} value={draft.timeoutMs} onChange={(event) => setField("timeoutMs", Number(event.target.value))} /></label>
                      <label>工具集<input value={draft.toolset.join(", ")} onChange={(event) => setField("toolset", event.target.value.split(",").map((item) => item.trim()).filter(Boolean))} /></label>
                      <label>Skills<input value={draft.skills.join(", ")} onChange={(event) => setField("skills", event.target.value.split(",").map((item) => item.trim()).filter(Boolean))} /></label>
                      <label>LSP<input value={draft.lsp.join(", ")} onChange={(event) => setField("lsp", event.target.value.split(",").map((item) => item.trim()).filter(Boolean))} /></label>
                      <div className="agent-card__actions">
                        <button type="button" className="btn btn--ghost btn--compact" data-testid="agent-preview-config" onClick={() => void previewConfig()} disabled={configBusy}>
                          预览影响
                        </button>
                        <button type="button" className="btn btn--run btn--compact" data-testid="agent-apply-config" onClick={() => void commitConfig()} disabled={configBusy || preview === null}>
                          应用到当前任务
                        </button>
                      </div>
                      {preview ? (
                        <div className="agent-preview" data-testid="agent-config-preview">
                          {preview.length === 0 ? <p>没有字段变化</p> : (
                            <ul>
                              {preview.map((change) => (
                                <li key={change.field}><strong>{change.field}</strong><span>{summarize(change.before)} → {summarize(change.after)}</span></li>
                              ))}
                            </ul>
                          )}
                        </div>
                      ) : null}
                      {configNote ? <p className="muted">{configNote}</p> : null}
                      {actionError ? <p className="error-text" data-testid="agent-action-error">{actionError}</p> : null}
                    </div>
                  ) : (
                    <p className="muted">选择一个 Agent 后可预览并应用运行中配置。</p>
                  )}
                  {active ? (
                    <section className="agent-card">
                      <h3>纠偏指令</h3>
                      <p className="muted">通过消息总线提交，在最近的安全执行点生效，不重启任务。</p>
                      <textarea className="agent-input" data-testid="agent-directive" rows={3} value={directive} onChange={(event) => setDirective(event.target.value)} />
                      <div className="agent-card__actions">
                        <button type="button" className="btn btn--ghost btn--compact" data-testid="agent-send-directive" onClick={() => void sendDirective()} disabled={!directive.trim()}>
                          发送指令
                        </button>
                        {active.pendingDirectives.length > 0 ? <span className="muted">{active.pendingDirectives.length} 条待投递</span> : null}
                      </div>
                    </section>
                  ) : null}
                </div>
              ) : null}
            </aside>
          ) : null}
        </div>
      </section>
      {pendingYolo ? (
        <div className="wb-modal-backdrop" role="presentation" onClick={() => setPendingYolo(false)}>
          <section
            className="wb-modal"
            role="dialog"
            aria-modal="true"
            aria-label="启用 YOLO 权限"
            data-testid="yolo-confirm"
            onClick={(event) => event.stopPropagation()}
          >
            <h2>启用 YOLO 权限？</h2>
            <p>
              启用后，Rust 执行层会自动允许当前项目内的文件修改、构建命令与脚本，不再逐项询问。
              这些操作可能产生真实副作用。
            </p>
            <ul>
              <li>仍会拦截：凭据读取、越界路径、破坏性 git、高风险程序。</li>
              <li>对当前会话的后续运行持续生效，直到切回 Ask 或 Workspace。</li>
              <li>随时可以切回 Ask，但已经获准的操作不会回滚。</li>
            </ul>
            <div className="wb-modal__actions">
              <button type="button" className="btn btn--ghost btn--compact" onClick={() => setPendingYolo(false)} data-testid="yolo-confirm-cancel">
                取消
              </button>
              <button type="button" className="btn btn--danger btn--compact" onClick={enableYolo} data-testid="yolo-confirm-enable">
                继续启用 YOLO
              </button>
            </div>
          </section>
        </div>
      ) : null}
    </section>
  );
}
