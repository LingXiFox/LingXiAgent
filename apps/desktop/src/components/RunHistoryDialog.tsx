import { useCallback, useEffect, useState } from "react";

import { api } from "../lib/api";
import { RUN_STATUS_TEXT } from "../lib/log";
import type { RunDetail, RunEvent, RunRecord, StoredRunStatus } from "../lib/types";

interface RunHistoryDialogProps {
  open: boolean;
  onClose: () => void;
}

const STORED_STATUS_TEXT: Record<StoredRunStatus, string> = {
  ...RUN_STATUS_TEXT,
  running: "运行中",
};

function formatTime(ms: number): string {
  return new Date(ms).toLocaleString("zh-CN", { hour12: false });
}

function formatDuration(ms: number | null): string {
  if (ms === null) return "—";
  return ms < 1000 ? ms + "ms" : (ms / 1000).toFixed(2) + "s";
}

function eventText(event: RunEvent): string {
  switch (event.type) {
    case "run.started":
      return "run started · " + event.workflowName + " · " + event.nodeCount + " nodes";
    case "run.finished":
      return (
        "run " +
        event.status +
        " · " +
        event.durationMs +
        "ms" +
        (event.detail ? " · " + event.detail : "")
      );
    case "node.started":
      return "▶ " + event.label + " · " + event.kind;
    case "node.finished":
      return "✓ " + event.label + " · " + event.durationMs + "ms";
    case "node.failed":
      return "✕ " + event.label + " · " + event.code + ": " + event.message;
    case "node.skipped":
      return "⤼ " + event.label + " skipped · " + event.reason;
    case "node.cancelled":
      return "⏹ " + event.label + " cancelled";
    case "log":
      return event.message;
    case "interaction.requested":
      return "⏸ approval requested · " + event.prompt;
    case "interaction.resolved":
      return "interaction " + event.decision + " · " + event.nodeId;
  }
}

function eventLevel(event: RunEvent): string {
  switch (event.type) {
    case "node.failed":
      return "error";
    case "node.skipped":
    case "node.cancelled":
    case "interaction.requested":
      return "warn";
    case "node.finished":
      return "success";
    case "run.finished":
      return event.status === "completed"
        ? "success"
        : event.status === "cancelled"
          ? "warn"
          : "error";
    default:
      return "info";
  }
}

export function RunHistoryDialog({ open, onClose }: RunHistoryDialogProps) {
  const [runs, setRuns] = useState<RunRecord[]>([]);
  const [selected, setSelected] = useState<RunDetail | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const next = await api.runList(50);
      setRuns(next);
      setSelected((current) => {
        if (!current) return null;
        const refreshed = next.find((run) => run.runId === current.run.runId);
        return refreshed ? { ...current, run: refreshed } : current;
      });
    } catch (cause) {
      setError(String(cause));
    } finally {
      setBusy(false);
    }
  }, []);

  useEffect(() => {
    if (!open) return;
    void refresh();
  }, [open, refresh]);

  const select = useCallback(async (runId: string) => {
    setBusy(true);
    setError(null);
    try {
      setSelected(await api.runDetail(runId));
    } catch (cause) {
      setError(String(cause));
    } finally {
      setBusy(false);
    }
  }, []);

  if (!open) return null;

  return (
    <div className="modal" role="dialog" aria-modal="true" aria-label="运行历史">
      <div className="modal__card modal__card--wide">
        <div className="modal__head">
          <h2 className="modal__title">运行历史</h2>
          <div className="runhistory__head-actions">
            <button
              type="button"
              className="btn btn--tiny"
              onClick={() => void refresh()}
              disabled={busy}
            >
              刷新
            </button>
            <button type="button" className="btn btn--tiny" onClick={onClose}>
              关闭
            </button>
          </div>
        </div>

        {error ? <div className="modal__error">{error}</div> : null}

        <div className="runhistory">
          <div className="runhistory__list">
            {runs.length === 0 && !busy ? (
              <p className="modal__empty">还没有运行记录。</p>
            ) : (
              runs.map((run) => (
                <button
                  type="button"
                  key={run.runId}
                  className={
                    "runrow" + (selected?.run.runId === run.runId ? " runrow--active" : "")
                  }
                  onClick={() => void select(run.runId)}
                >
                  <span className="runrow__top">
                    <span className={"status status--" + run.status}>
                      <span className="status__dot" />
                      {STORED_STATUS_TEXT[run.status]}
                    </span>
                    <span className="runrow__time">{formatTime(run.startedAtMs)}</span>
                  </span>
                  <span className="runrow__name">{run.workflowName || "未命名工作流"}</span>
                  <span className="runrow__sub">
                    {run.nodeCount} 节点 · {formatDuration(run.durationMs)}
                  </span>
                </button>
              ))
            )}
          </div>

          <div className="runhistory__detail">
            {selected ? (
              <>
                <div className="runhistory__summary">
                  <div>
                    <h3 className="runhistory__name">{selected.run.workflowName || "未命名工作流"}</h3>
                    <p className="runhistory__meta">
                      {selected.run.runId} · {formatTime(selected.run.startedAtMs)} ·{" "}
                      {formatDuration(selected.run.durationMs)}
                    </p>
                  </div>
                  <span className={"status status--" + selected.run.status}>
                    <span className="status__dot" />
                    {STORED_STATUS_TEXT[selected.run.status]}
                  </span>
                </div>
                {selected.run.cause || selected.run.detail ? (
                  <p className="runhistory__cause">
                    {selected.run.cause ?? "cause unknown"}
                    {selected.run.detail ? " · " + selected.run.detail : ""}
                  </p>
                ) : null}
                <div className="runhistory__events">
                  {selected.events.map((event) => (
                    <div
                      className={"runhistory__event runhistory__event--" + eventLevel(event)}
                      key={event.seq}
                    >
                      <span className="runhistory__seq">#{event.seq}</span>
                      <span className="runhistory__event-text">{eventText(event)}</span>
                    </div>
                  ))}
                </div>
              </>
            ) : (
              <p className="modal__empty">选择左侧一次运行查看详情与历史事件。</p>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
