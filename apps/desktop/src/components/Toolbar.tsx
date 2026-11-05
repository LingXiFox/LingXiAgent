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
  canOpenAgent: boolean;
  view: "canvas" | "workbench";
  onNameChange: (name: string) => void;
  onViewChange: (view: "canvas" | "workbench") => void;
  onOpenAgent: () => void;
  onCompany: () => void;
  onNew: () => void;
  onDemo: () => void;
  onAgent: () => void;
  onSettings: () => void;
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
  canOpenAgent,
  view,
  onNameChange,
  onViewChange,
  onOpenAgent,
  onCompany,
  onNew,
  onDemo,
  onAgent,
  onSettings,
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
          data-testid="workflow-name"
        />
        <span className={"status status--" + status}>
          <span className="status__dot" />
          {RUN_STATUS_TEXT[status]}
        </span>
        <span className="toolbar__counts">
          {nodeCount} 节点 · {edgeCount} 连线
        </span>
        {preview ? <span className="toolbar__badge">浏览器预览</span> : null}
        <span className="toolbar__viewswitch" role="tablist" aria-label="顶层视图">
          <button
            type="button"
            role="tab"
            aria-selected={view === "canvas"}
            className={"toolbar__view" + (view === "canvas" ? " is-active" : "")}
            data-testid="view-canvas"
            onClick={() => onViewChange("canvas")}
          >
            节点编辑器
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={view === "workbench"}
            className={"toolbar__view" + (view === "workbench" ? " is-active" : "")}
            data-testid="view-workbench"
            onClick={() => onViewChange("workbench")}
          >
            Agent 工作台
          </button>
        </span>
      </div>

      <div className="toolbar__right">
        {selectionCount > 0 ? (
          <span className="toolbar__selection">
            <button
              type="button"
              className="btn btn--ghost btn--compact"
              data-testid="toolbar-group"
              onClick={onGroup}
              disabled={selectionCount < 2 || structuralLock}
              title="把选中的节点组合为可展开的组合节点"
            >
              组合
            </button>
            <button
              type="button"
              className="btn btn--ghost btn--compact"
              data-testid="toolbar-ungroup"
              onClick={onUngroup}
              disabled={!canUngroup || structuralLock}
              title="解组并把内部节点还原到当前画布"
            >
              解组
            </button>
            <button
              type="button"
              className="btn btn--ghost btn--compact"
              data-testid="toolbar-duplicate"
              onClick={onDuplicate}
              disabled={structuralLock}
              title="复制选中节点及其内部连线"
            >
              复制
            </button>
            <button
              type="button"
              className="btn btn--ghost btn--compact"
              data-testid="toolbar-template"
              onClick={onSaveTemplate}
              disabled={!canTemplate || structuralLock}
              title="把选中的组合存为本地模板"
            >
              存为模板
            </button>
            {canOpenAgent ? (
              <button
                type="button"
                className="btn btn--ghost btn--compact"
                data-testid="toolbar-open-agent"
                onClick={onOpenAgent}
                title="打开该 Agent 的运行详情"
              >
                查看 Agent 执行
              </button>
            ) : null}
            <span className="toolbar__divider" />
          </span>
        ) : null}
        <button type="button" className="btn btn--ghost" data-testid="toolbar-new" onClick={onNew} disabled={running}>
          新建
        </button>
        <button type="button" className="btn btn--ghost" data-testid="toolbar-demo" onClick={onDemo} disabled={running}>
          示例
        </button>
        <button type="button" className="btn btn--ghost" data-testid="toolbar-company" onClick={onCompany} disabled={running || busy}>
          团队示例
        </button>
        <button type="button" className="btn btn--ghost" data-testid="toolbar-agent" onClick={onAgent} disabled={running || busy}>
          Agent
        </button>
        <button type="button" className="btn btn--ghost" data-testid="toolbar-open" onClick={onOpen} disabled={running}>
          打开
        </button>
        <button type="button" className="btn btn--ghost" data-testid="toolbar-save" onClick={onSave} disabled={running || busy}>
          保存
        </button>
        <button type="button" className="btn btn--ghost" data-testid="toolbar-validate" onClick={onValidate} disabled={busy}>
          校验
        </button>
        <button type="button" className="btn btn--ghost" data-testid="toolbar-settings" onClick={onSettings}>
          设置
        </button>
        <button type="button" className="btn btn--ghost" data-testid="toolbar-history" onClick={onHistory}>
          历史
        </button>
        <button
          type="button"
          className="btn btn--run"
          data-testid="toolbar-run"
          onClick={onRun}
          disabled={running || busy}
        >
          <span className="btn__glyph">▶</span> 运行
        </button>
        <button
          type="button"
          className="btn btn--stop"
          data-testid="toolbar-stop"
          onClick={onStop}
          disabled={!running}
        >
          <span className="btn__glyph">■</span> 终止
        </button>
      </div>
    </header>
  );
}
