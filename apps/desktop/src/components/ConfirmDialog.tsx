interface ConfirmDialogProps {
  open: boolean;
  title: string;
  message: string;
  confirmLabel?: string;
  onConfirm: () => void;
  onCancel: () => void;
}

export function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel = "继续",
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  if (!open) return null;

  return (
    <div className="modal" role="dialog" aria-modal="true" aria-label={title}>
      <div className="modal__card modal__card--narrow">
        <header className="modal__head">
          <h2 className="modal__title">{title}</h2>
        </header>
        <p className="modal__prompt">{message}</p>
        <div className="modal__actions">
          <button type="button" className="btn btn--ghost" onClick={onCancel}>
            取消
          </button>
          <button type="button" className="btn btn--run" onClick={onConfirm}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
