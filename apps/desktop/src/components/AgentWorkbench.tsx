import { useEffect, useMemo, useState } from "react";

import type {
  AgentConfigRevision,
  AgentConfigSnapshot,
  AgentInstance,
  AgentUsage,
  ConfigChange,
  RunEvent,
  TaskSession,
} from "../lib/types";
import type { UiRunStatus } from "../lib/log";

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
  const payload = event.event;
  return "agentInstanceId" in payload ? (payload.agentInstanceId ?? null) : null;
}

function agentLabel(session: TaskSession | null, instanceId: string): string {
  return session?.agents[instanceId]?.label ?? instanceId;
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
  return { ...agent.config, toolset: [...agent.config.toolset], skills: [...agent.config.skills], lsp: [...agent.config.lsp] };
}

interface AgentWorkbenchProps {
  session: TaskSession | null;
  events: RunEvent[];
  status: UiRunStatus;
  selected: string | null;
  onSelect: (agentInstanceId: string | null) => void;
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

export function AgentWorkbench({
  session,
  events,
  status,
  selected,
  onSelect,
  onPauseAgent,
  onResumeAgent,
  onCancelAgent,
  onPauseWorkflow,
  onResumeWorkflow,
  onDirective,
  onPreviewConfig,
  onApplyConfig,
  onLocateNode,
}: AgentWorkbenchProps) {
  const agents = useMemo(
    () => (session ? Object.values(session.agents).sort((a, b) => a.createdAtMs - b.createdAtMs) : []),
    [session],
  );
  const [seen, setSeen] = useState<Record<string, number>>({});
  const [activationChoice, setActivationChoice] = useState<Record<string, string>>({});
  const [directive, setDirective] = useState("");
  const [draft, setDraft] = useState<AgentConfigSnapshot | null>(null);
  const [preview, setPreview] = useState<ConfigChange[] | null>(null);
  const [configBusy, setConfigBusy] = useState(false);
  const [configNote, setConfigNote] = useState("");
  const [actionError, setActionError] = useState("");

  const active = agents.find((agent) => agent.instanceId === selected) ?? null;

  useEffect(() => {
    if (!active) {
      setDraft(null);
      setPreview(null);
      setConfigNote("");
      return;
    }
    setDraft(configFrom(active));
    setPreview(null);
    setConfigNote("");
    setDirective("");
    setSeen((current) => ({ ...current, [active.instanceId]: events.length }));
    // Re-seed only when the chosen agent or its applied revision changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active?.instanceId, active?.config.revision]);

  useEffect(() => {
    if (!selected) return;
    setSeen((current) => ({ ...current, [selected]: events.length }));
  }, [events.length, selected]);

  const agentEvents = useMemo(() => {
    if (!active) return [];
    return events.filter((event) => eventAgentId(event) === active.instanceId);
  }, [active, events]);

  const activation = useMemo(() => {
    if (!active) return null;
    const choice = activationChoice[active.instanceId];
    return (
      active.activations.find((entry) => entry.activationId === choice) ??
      active.activations.find((entry) => entry.activationId === active.currentActivation) ??
      active.activations[active.activations.length - 1] ??
      null
    );
  }, [active, activationChoice]);

  const stream = useMemo(() => {
    if (!activation) return "";
    return agentEvents
      .filter(
        (event) =>
          event.type === "agent.event" &&
          activation &&
          "activationId" in event.event &&
          event.event.activationId === activation.activationId &&
          event.event.type === "agent.delta",
      )
      .map((event) => (event.type === "agent.event" && event.event.type === "agent.delta" ? event.event.delta : ""))
      .join("");
  }, [activation, agentEvents]);

  const toolEvents = useMemo(() => {
    if (!activation) return [];
    return agentEvents.filter(
      (event) =>
        event.type === "agent.event" &&
        (event.event.type === "agent.tool.started" || event.event.type === "agent.tool.finished") &&
        event.event.activationId === activation.activationId,
    );
  }, [activation, agentEvents]);

  const unread = useMemo(() => {
    const counts: Record<string, number> = {};
    if (!session) return counts;
    for (const agent of agents) {
      const total = events.filter((event) => eventAgentId(event) === agent.instanceId).length;
      counts[agent.instanceId] = Math.max(0, total - (seen[agent.instanceId] ?? 0));
    }
    return counts;
  }, [agents, events, seen, session]);

  const totals = useMemo(() => {
    const total = { modelCalls: 0, toolCalls: 0, tokens: 0, elapsedMs: 0 };
    for (const agent of agents) {
      total.modelCalls += agent.usage.modelCalls;
      total.toolCalls += agent.usage.toolCalls;
      total.tokens += usageTotal(agent.usage);
      total.elapsedMs += agent.usage.elapsedMs;
    }
    return total;
  }, [agents]);

  const messages = useMemo(() => {
    if (!session) return [];
    const ids = new Set(agents.map((agent) => agent.instanceId));
    return session.messages.filter((message) => ids.has(message.sender) || ids.has(message.recipient) || message.recipient === "broadcast");
  }, [agents, session]);

  const reviews = session?.pendingReviews.filter((review) => !review.resolved) ?? [];

  if (!session) {
    return (
      <section className="workbench workbench--empty" data-testid="agent-workbench">
        <div>
          <h2>Agent 工作台</h2>
          <p>运行包含 Agent 节点的工作流后，这里会按 Agent 列出执行过程、消息和成本。</p>
          <p className="workbench__hint">本视图只观察真实运行事件；空闲时不会显示伪造的进度。</p>
        </div>
      </section>
    );
  }

  const apply = async () => {
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

  const commit = async () => {
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

  const setField = <K extends keyof AgentConfigSnapshot>(key: K, value: AgentConfigSnapshot[K]) => {
    setDraft((current) => (current ? { ...current, [key]: value } : current));
    setPreview(null);
    setConfigNote("");
  };

  const listValue = (value: string[]) => value.join(", ");

  return (
    <section className="workbench" data-testid="agent-workbench">
      <div className="workbench__tabs" role="tablist" data-testid="agent-tabs">
        <button
          type="button"
          role="tab"
          aria-selected={selected === null}
          className={"workbench__tab" + (selected === null ? " is-active" : "")}
          data-testid="agent-tab-overview"
          onClick={() => onSelect(null)}
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
            onClick={() => onSelect(agent.instanceId)}
          >
            <span className={"agent-state agent-state--" + agent.state}>{stateText(agent.state)}</span>
            <span className="workbench__tab-label">{agent.label}</span>
            {unread[agent.instanceId] > 0 && selected !== agent.instanceId ? (
              <span className="workbench__unread">{unread[agent.instanceId]}</span>
            ) : null}
            {agent.pendingDirectives.length > 0 ? <span className="workbench__pip" title="有待投递的纠偏指令" /> : null}
          </button>
        ))}
        <span className="workbench__spacer" />
        <span className={"status status--" + status}>
          <span className="status__dot" />
          {status === "running" ? "运行中" : status === "completed" ? "已完成" : status === "failed" ? "失败" : status === "cancelled" ? "已终止" : status === "interrupted" ? "已中断" : "空闲"}
        </span>
        <button
          type="button"
          className="btn btn--ghost btn--compact"
          data-testid="workbench-pause-workflow"
          onClick={onPauseWorkflow}
          disabled={status !== "running"}
        >
          暂停工作流
        </button>
        <button
          type="button"
          className="btn btn--ghost btn--compact"
          data-testid="workbench-resume-workflow"
          onClick={onResumeWorkflow}
          disabled={status !== "running"}
        >
          继续工作流
        </button>
      </div>

      {active ? (
        <div className="workbench__body">
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
              <button
                type="button"
                className="btn btn--ghost btn--compact"
                data-testid="agent-pause"
                onClick={() => onPauseAgent(active.instanceId)}
                disabled={active.state !== "running"}
              >
                暂停
              </button>
              <button
                type="button"
                className="btn btn--ghost btn--compact"
                data-testid="agent-resume"
                onClick={() => onResumeAgent(active.instanceId)}
                disabled={active.state !== "paused" && active.state !== "pausing"}
              >
                继续
              </button>
              <button
                type="button"
                className="btn btn--ghost btn--compact"
                data-testid="agent-cancel"
                onClick={() => onCancelAgent(active.instanceId)}
                disabled={active.state === "completed" || active.state === "failed" || active.state === "cancelled"}
              >
                取消
              </button>
            </div>
          </header>

          <div className="agent-columns">
            <div className="agent-column">
              <section className="agent-card">
                <h3>执行记录</h3>
                {active.activations.length === 0 ? <p className="muted">尚未开始执行</p> : null}
                <div className="agent-activations">
                  {active.activations.map((entry) => (
                    <button
                      type="button"
                      key={entry.activationId}
                      className={"agent-activation" + (activation?.activationId === entry.activationId ? " is-active" : "")}
                      onClick={() => setActivationChoice((current) => ({ ...current, [active.instanceId]: entry.activationId }))}
                    >
                      <span>第 {entry.index} 次执行</span>
                      <span className={"agent-state agent-state--" + entry.state}>{stateText(entry.state)}</span>
                    </button>
                  ))}
                </div>
                {activation ? (
                  <dl className="agent-facts">
                    <dt>激活</dt><dd>{activation.activationId.split("#").pop()}</dd>
                    <dt>配置版本</dt><dd>{activation.configRevision}</dd>
                    <dt>迭代</dt><dd>{activation.iterations}</dd>
                    {activation.error ? (<><dt>错误</dt><dd className="error-text">{activation.error}</dd></>) : null}
                  </dl>
                ) : null}
                {activation?.userResponse ? (
                  <div className="agent-result">
                    <h4>用户可读结果</h4>
                    <p>{activation.userResponse}</p>
                  </div>
                ) : null}
              </section>

              <section className="agent-card">
                <h3>模型输出流</h3>
                {stream ? <pre className="agent-stream" data-testid="agent-stream">{stream}</pre> : <p className="muted">当前激活暂无增量输出。未公开的推理不会被伪造。</p>}
                <h3>工具调用</h3>
                {toolEvents.length === 0 ? <p className="muted">没有工具调用</p> : (
                  <ul className="agent-tools">
                    {toolEvents.map((event) => {
                      if (event.type !== "agent.event") return null;
                      const payload = event.event;
                      if (payload.type === "agent.tool.started") {
                        return <li key={payload.toolCallId + "-start"} data-testid="agent-tool"><strong>{payload.toolName}</strong><code>{payload.arguments}</code></li>;
                      }
                      if (payload.type === "agent.tool.finished") {
                        return <li key={payload.toolCallId + "-end"} className={payload.ok ? "is-ok" : "is-failed"}>{payload.ok ? "完成" : "失败"} · {payload.durationMs}ms<code>{payload.result || payload.error || ""}</code></li>;
                      }
                      return null;
                    })}
                  </ul>
                )}
              </section>

              <section className="agent-card">
                <h3>与团队的通信</h3>
                {messages.length === 0 ? <p className="muted">还没有跨 Agent 消息</p> : (
                  <ul className="agent-messages" data-testid="agent-messages">
                    {messages.filter((message) => message.sender === active.instanceId || message.recipient === active.instanceId || message.recipient === "broadcast").map((message) => (
                      <li key={message.messageId}>
                        <div className="agent-message__head">
                          <span>{message.sender === active.instanceId ? "发出" : "收到"}</span>
                          <span>{message.type}</span>
                          <span className={"agent-message__status"}>{message.status}</span>
                        </div>
                        <p>{summarize(message.payload)}</p>
                        <small>{message.artifactRefs.length} 个交付物引用 · {message.messageId.slice(0, 18)}</small>
                      </li>
                    ))}
                  </ul>
                )}
              </section>
            </div>

            <div className="agent-column">
              <section className="agent-card">
                <h3>成本</h3>
                <div className="agent-costs">
                  <span><strong>{active.usage.iterations}</strong>迭代</span>
                  <span><strong>{active.usage.modelCalls}</strong>模型调用</span>
                  <span><strong>{active.usage.toolCalls}</strong>工具调用</span>
                  <span><strong>{usageTotal(active.usage)}</strong>Token</span>
                  <span><strong>{active.usage.elapsedMs}</strong>ms</span>
                </div>
              </section>

              <section className="agent-card">
                <h3>纠偏指令</h3>
                <p className="muted">通过消息总线提交，在最近的安全执行点生效。不会重启整个任务。</p>
                <textarea
                  className="agent-input"
                  data-testid="agent-directive"
                  rows={3}
                  value={directive}
                  placeholder="例如：改用 SQLite 而不是 JSON 文件"
                  onChange={(event) => setDirective(event.target.value)}
                />
                <div className="agent-card__actions">
                  <button type="button" className="btn btn--ghost btn--compact" data-testid="agent-send-directive" onClick={() => void sendDirective()} disabled={!directive.trim()}>
                    发送指令
                  </button>
                  {active.pendingDirectives.length > 0 ? <span className="muted">{active.pendingDirectives.length} 条待投递</span> : null}
                </div>
              </section>

              <section className="agent-card">
                <h3>运行配置</h3>
                {draft ? (
                  <div className="agent-config" data-testid="agent-config">
                    <label>模型<input value={draft.model} onChange={(event) => setField("model", event.target.value)} /></label>
                    <label>Temperature<input type="number" step="0.1" value={draft.temperature} onChange={(event) => setField("temperature", Number(event.target.value))} /></label>
                    <label>角色提示词<textarea rows={3} value={draft.rolePrompt} onChange={(event) => setField("rolePrompt", event.target.value)} /></label>
                    <label>系统提示词<textarea rows={3} value={draft.systemPrompt} onChange={(event) => setField("systemPrompt", event.target.value)} /></label>
                    <label>最大迭代<input type="number" min={1} value={draft.maxIterations} onChange={(event) => setField("maxIterations", Number(event.target.value))} /></label>
                    <label>最大工具调用<input type="number" min={0} value={draft.maxToolCalls} onChange={(event) => setField("maxToolCalls", Number(event.target.value))} /></label>
                    <label>Token 预算<input type="number" min={0} value={draft.maxTotalTokens} onChange={(event) => setField("maxTotalTokens", Number(event.target.value))} /></label>
                    <label>超时 ms<input type="number" min={1} value={draft.timeoutMs} onChange={(event) => setField("timeoutMs", Number(event.target.value))} /></label>
                    <label>工具集<input value={listValue(draft.toolset)} onChange={(event) => setField("toolset", event.target.value.split(",").map((item) => item.trim()).filter(Boolean))} /></label>
                    <label>Skills<input value={listValue(draft.skills)} onChange={(event) => setField("skills", event.target.value.split(",").map((item) => item.trim()).filter(Boolean))} /></label>
                    <label>LSP<input value={listValue(draft.lsp)} onChange={(event) => setField("lsp", event.target.value.split(",").map((item) => item.trim()).filter(Boolean))} /></label>
                    <div className="agent-card__actions">
                      <button type="button" className="btn btn--ghost btn--compact" data-testid="agent-preview-config" onClick={() => void apply()} disabled={configBusy}>
                        预览影响
                      </button>
                      <button type="button" className="btn btn--run btn--compact" data-testid="agent-apply-config" onClick={() => void commit()} disabled={configBusy || preview === null}>
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
                  </div>
                ) : null}
                {active.configRevisions.length > 0 ? (
                  <div className="agent-revisions">
                    <h4>版本记录</h4>
                    <ul>
                      {active.configRevisions.slice().reverse().map((revision) => (
                        <li key={revision.revision} className={"revision revision--" + revision.status}>
                          v{revision.revision} · {revision.status}
                          {revision.appliedAtMs ? " · " + new Date(revision.appliedAtMs).toLocaleTimeString() : ""}
                          {revision.detail ? " · " + revision.detail : ""}
                        </li>
                      ))}
                    </ul>
                  </div>
                ) : null}
              </section>

              {actionError ? <p className="error-text" data-testid="agent-action-error">{actionError}</p> : null}
            </div>
          </div>
        </div>
      ) : (
        <div className="workbench__body workbench__overview" data-testid="agent-overview">
          <div className="overview-grid">
            <section className="agent-card">
              <h3>团队状态</h3>
              <p className="overview-lead">{session.state === "running" ? "任务执行中" : "任务" + stateText(session.state)} · {agents.length} 个 Agent</p>
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
              {agents.length === 0 ? <p className="muted">当前运行还没有注册 Agent 实例。</p> : null}
            </section>

            <section className="agent-card">
              <h3>成本与交付</h3>
              <div className="agent-costs">
                <span><strong>{totals.modelCalls}</strong>模型调用</span>
                <span><strong>{totals.toolCalls}</strong>工具调用</span>
                <span><strong>{totals.tokens}</strong>Token</span>
                <span><strong>{Math.round(totals.elapsedMs)}</strong>ms</span>
              </div>
              <h4>最近的终态结果</h4>
              {messages.filter((message) => message.type === "task.result" || message.type === "task.blocked").slice(-3).reverse().map((message) => (
                <div className="overview-result" key={message.messageId}>
                  <span>{agentLabel(session, message.sender)}</span>
                  <p>{summarize(message.payload)}</p>
                </div>
              ))}
              {messages.filter((message) => message.type === "task.result").length === 0 ? <p className="muted">还没有 Agent 交付结果。</p> : null}
            </section>

            <section className="agent-card overview-timeline">
              <h3>跨 Agent 消息时间线</h3>
              {messages.length === 0 ? <p className="muted">消息总线为空。</p> : (
                <ol>
                  {messages.slice(-20).map((message) => (
                    <li key={message.messageId}>
                      <span>{message.type}</span>
                      <span>
                        {agentLabel(session, message.sender)} →{" "}
                        {message.recipient === "broadcast" ? "团队" : agentLabel(session, message.recipient)}
                      </span>
                      <small>{message.status} · {new Date(message.createdAtMs).toLocaleTimeString()}</small>
                    </li>
                  ))}
                </ol>
              )}
            </section>

            <section className="agent-card">
              <h3>待处理审批 / 核对</h3>
              {reviews.length === 0 ? <p className="muted">没有待处理项。</p> : (
                <ul className="overview-reviews">
                  {reviews.map((review) => (
                    <li key={review.reviewId}>
                      <strong>{review.toolName || "未知工具"}</strong>
                      <p>{review.reason}</p>
                      <small>{review.agentInstanceId.split(": ").pop()}</small>
                    </li>
                  ))}
                </ul>
              )}
            </section>
          </div>
        </div>
      )}
    </section>
  );
}
