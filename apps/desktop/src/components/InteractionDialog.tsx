export interface InteractionRequest {
  requestId: string;
  nodeId: string;
  prompt: string;
}

interface InteractionDialogProps {
  request: InteractionRequest | null;
  onDecide: (approved: boolean) => void;
}

export function InteractionDialog({ request, onDecide }: InteractionDialogProps) {
  if (!request) return null;

  return (
    <div className="modal" role="dialog" aria-modal="true" aria-label="Approval required">
      <div className="modal__card modal__card--narrow">
        <header className="modal__head">
          <h2 className="modal__title">需要确认</h2>
        </header>
        <p className="modal__prompt">{request.prompt}</p>
        <p className="modal__hint">节点 {request.nodeId} 正在等待你的决定，运行会保持暂停。</p>
        <div className="modal__actions">
          <button type="button" className="btn btn--ghost" onClick={() => onDecide(false)}>
            拒绝
          </button>
          <button type="button" className="btn btn--run" onClick={() => onDecide(true)}>
            批准
          </button>
        </div>
      </div>
    </div>
  );
}
