import { RUN_STATUS_TEXT, type UiRunStatus } from "../lib/log";

interface ToolbarProps {
  name: string;
  status: UiRunStatus;
  nodeCount: number;
  edgeCount: number;
  busy: boolean;
  preview: boolean;
  selectionCount: number;
  canUngroup: boolean;
  canTemplate: boolean;
  onNameChange: (name: string) => void;
  onNew: () => void;
  onDemo: () => void;
  onOpen: () => void;
  onSave: () => void;
  onValidate: () => void;
  onHistory: () => void;
  onRun: () => void;
  onStop: () => void;
  onGroup: () => void;
  onUngroup: () => void;
  onDuplicate: () => void;
  onSaveTemplate: () => void;
}

export function Toolbar({
  name,
  status,
  nodeCount,
  edgeCount,
  busy,
  preview,
  selectionCount,
  canUngroup,
  canTemplate,
  onNameChange,
  onNew,
  onDemo,
  onOpen,
  onSave,
  onValidate,
  onHistory,
  onRun,
  onStop,
  onGroup,
  onUngroup,
  onDuplicate,
  onSaveTemplate,
}: ToolbarProps) {
  const running = status === "running";
  const structuralLock = running || busy;

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
          {RUN_STATUS_TEXT[status]}
        </span>
        <span className="toolbar__counts">
          {nodeCount} 节点 · {edgeCount} 连线
        </span>
        {preview ? <span className="toolbar__badge">浏览器预览</span> : null}
      </div>

      <div className="toolbar__right">
        {selectionCount > 0 ? (
          <span className="toolbar__selection">
            <button
              type="button"
              className="btn btn--ghost btn--compact"
              onClick={onGroup}
              disabled={selectionCount < 2 || structuralLock}
              title="把选中的节点组合为可展开的组合节点"
            >
              组合
            </button>
            <button
              type="button"
              className="btn btn--ghost btn--compact"
              onClick={onUngroup}
              disabled={!canUngroup || structuralLock}
              title="解组并把内部节点还原到当前画布"
            >
              解组
            </button>
            <button
              type="button"
              className="btn btn--ghost btn--compact"
              onClick={onDuplicate}
              disabled={structuralLock}
              title="复制选中节点及其内部连线"
            >
              复制
            </button>
            <button
              type="button"
              className="btn btn--ghost btn--compact"
              onClick={onSaveTemplate}
              disabled={!canTemplate || structuralLock}
              title="把选中的组合存为本地模板"
            >
              存为模板
            </button>
            <span className="toolbar__divider" />
          </span>
        ) : null}
        <button type="button" className="btn btn--ghost" onClick={onNew} disabled={running}>
          新建
        </button>
        <button type="button" className="btn btn--ghost" onClick={onDemo} disabled={running}>
          示例
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
        <button type="button" className="btn btn--ghost" onClick={onHistory}>
          历史
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
