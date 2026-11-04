import type { WorkflowSummary } from "../lib/types";

interface WorkflowDialogProps {
  open: boolean;
  workflows: WorkflowSummary[];
  busy: boolean;
  error: string | null;
  onClose: () => void;
  onLoad: (name: string) => void;
  onDelete: (name: string) => void;
}

function formatDate(ms: number): string {
  return new Date(ms).toLocaleString("zh-CN", { hour12: false });
}

export function WorkflowDialog({
  open,
  workflows,
  busy,
  error,
  onClose,
  onLoad,
  onDelete,
}: WorkflowDialogProps) {
  if (!open) return null;

  return (
    <div
      className="modal"
      role="dialog"
      aria-modal="true"
      aria-label="Open workflow"
      data-testid="workflow-dialog"
    >
      <div className="modal__card">
        <header className="modal__head">
          <h2 className="modal__title">打开工作流</h2>
          <button type="button" className="btn btn--tiny" data-testid="workflow-close" onClick={onClose}>
            关闭
          </button>
        </header>

        {error ? <p className="modal__error">{error}</p> : null}

        <div className="modal__body">
          {busy ? <p className="modal__empty">读取中…</p> : null}
          {!busy && workflows.length === 0 ? (
            <p className="modal__empty">还没有保存过的工作流。</p>
          ) : null}
          {workflows.map((workflow) => (
            <div
              className="wfrow"
              key={workflow.name}
              data-testid={"workflow-row-" + workflow.name}
            >
              <div className="wfrow__meta">
                <span className="wfrow__name">{workflow.name}</span>
                <span className="wfrow__sub">
                  {workflow.nodeCount} 节点 · {formatDate(workflow.updatedAtMs)}
                </span>
              </div>
              <div className="wfrow__actions">
                <button
                  type="button"
                  className="btn btn--tiny"
                  data-testid={"workflow-load-" + workflow.name}
                  onClick={() => onLoad(workflow.name)}
                >
                  载入
                </button>
                <button
                  type="button"
                  className="btn btn--tiny btn--danger"
                  data-testid={"workflow-delete-" + workflow.name}
                  onClick={() => onDelete(workflow.name)}
                >
                  删除
                </button>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
