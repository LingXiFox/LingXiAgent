import { useEffect, useState } from "react";

interface TemplateDialogProps {
  open: boolean;
  initialName: string;
  busy: boolean;
  error: string | null;
  onCancel: () => void;
  onSave: (name: string) => void;
}

export function TemplateDialog({
  open,
  initialName,
  busy,
  error,
  onCancel,
  onSave,
}: TemplateDialogProps) {
  const [name, setName] = useState(initialName);

  useEffect(() => {
    if (open) setName(initialName);
  }, [initialName, open]);

  if (!open) return null;

  return (
    <div className="modal" role="dialog" aria-modal="true" aria-label="Save composite template">
      <form
        className="modal__card modal__card--narrow"
        onSubmit={(event) => {
          event.preventDefault();
          if (name.trim() && !busy) onSave(name.trim());
        }}
      >
        <header className="modal__head">
          <h2 className="modal__title">存为本地组合模板</h2>
          <button type="button" className="btn btn--tiny" onClick={onCancel}>
            关闭
          </button>
        </header>
        <p className="modal__hint">
          模板保存在本机应用数据目录，仅影响之后拖入的实例；已有工作流不会被改写。
        </p>
        <div className="modal__body">
          <label className="template-field">
            <span>模板名称</span>
            <input
              autoFocus
              value={name}
              maxLength={64}
              spellCheck={false}
              onChange={(event) => setName(event.target.value)}
              placeholder="例如：计数器循环"
            />
          </label>
          {error ? <p className="modal__error">{error}</p> : null}
        </div>
        <div className="modal__actions">
          <button type="button" className="btn btn--ghost" onClick={onCancel}>
            取消
          </button>
          <button type="submit" className="btn" disabled={!name.trim() || busy}>
            {busy ? "保存中…" : "保存模板"}
          </button>
        </div>
      </form>
    </div>
  );
}
