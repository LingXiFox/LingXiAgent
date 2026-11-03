import { useEffect, useRef } from "react";

import { RUN_STATUS_TEXT, type LogEntry, type UiRunStatus } from "../lib/log";

interface LogPanelProps {
  entries: LogEntry[];
  open: boolean;
  status: UiRunStatus;
  onToggle: () => void;
  onClear: () => void;
}

function formatTime(at: number): string {
  return new Date(at).toLocaleTimeString("zh-CN", { hour12: false });
}

export function LogPanel({ entries, open, status, onToggle, onClear }: LogPanelProps) {
  const bodyRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    const body = bodyRef.current;
    if (body) body.scrollTop = body.scrollHeight;
  }, [entries.length, open]);

  return (
    <section className={"logpanel" + (open ? " logpanel--open" : "")}>
      <div className="logpanel__bar">
        <button type="button" className="logpanel__toggle" onClick={onToggle}>
          <span className={"logpanel__chevron" + (open ? " logpanel__chevron--open" : "")}>▸</span>
          运行日志
          <span className="logpanel__count">{entries.length}</span>
        </button>
        <div className="logpanel__actions">
          <span className={"status status--" + status}>
            <span className="status__dot" />
            {status === "idle" ? "空闲" : RUN_STATUS_TEXT[status]}
          </span>
          <button type="button" className="btn btn--tiny" onClick={onClear} disabled={entries.length === 0}>
            清空
          </button>
        </div>
      </div>
      {open ? (
        <div className="logpanel__body" ref={bodyRef}>
          {entries.length === 0 ? (
            <p className="logpanel__empty">暂无事件。点击运行后，Rust 运行时的事件会实时显示在这里。</p>
          ) : (
            entries.map((entry) => (
              <div className={"logline logline--" + entry.level} key={entry.id}>
                <span className="logline__time">{formatTime(entry.at)}</span>
                <span className="logline__level">{entry.level}</span>
                <span className="logline__text">{entry.text}</span>
              </div>
            ))
          )}
        </div>
      ) : null}
    </section>
  );
}
