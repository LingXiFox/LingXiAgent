import type { UiRunStatus } from "../lib/log";

interface ToolbarProps {
  name: string;
  status: UiRunStatus;
  nodeCount: number;
  edgeCount: number;
  busy: boolean;
  preview: boolean;
  onNameChange: (name: string) => void;
  onNew: () => void;
  onOpen: () => void;
  onSave: () => void;
  onValidate: () => void;
  onRun: () => void;
  onStop: () => void;
}

const STATUS_TEXT: Record<UiRunStatus, string> = {
  idle: "就绪",
  running: "运行中",
  completed: "已完成",
  failed: "失败",
  cancelled: "已终止",
};

export function Toolbar({
  name,
  status,
  nodeCount,
  edgeCount,
  busy,
  preview,
  onNameChange,
  onNew,
  onOpen,
  onSave,
  onValidate,
  onRun,
  onStop,
}: ToolbarProps) {
  const running = status === "running";

  return (
    <header className="toolbar">
      <div className="toolbar__left">
        <input
          className="toolbar__name"
          value={name}
          spellCheck={false}
          onChange={(event) => onNameChange(event.target.value)}
          placeholder="Workflow name"
          aria-label="Workflow name"
        />
        <span className={"status status--" + status}>
          <span className="status__dot" />
          {STATUS_TEXT[status]}
        </span>
        <span className="toolbar__counts">
          {nodeCount} 节点 · {edgeCount} 连线
        </span>
        {preview ? <span className="toolbar__badge">浏览器预览</span> : null}
      </div>

      <div className="toolbar__right">
        <button type="button" className="btn btn--ghost" onClick={onNew} disabled={running}>
          新建
        </button>
        <button type="button" className="btn btn--ghost" onClick={onOpen} disabled={running}>
          打开
        </button>
        <button type="button" className="btn btn--ghost" onClick={onSave} disabled={running || busy}>
          保存
        </button>
        <button type="button" className="btn btn--ghost" onClick={onValidate} disabled={busy}>
          校验
        </button>
        <button
          type="button"
          className="btn btn--run"
          onClick={onRun}
          disabled={running || busy}
        >
          <span className="btn__glyph">▶</span> 运行
        </button>
        <button
          type="button"
          className="btn btn--stop"
          onClick={onStop}
          disabled={!running}
        >
          <span className="btn__glyph">■</span> 终止
        </button>
      </div>
    </header>
  );
}
