interface CanvasBarProps {
  labels: string[];
  depth: number;
  selectedCount: number;
  onNavigate: (depth: number) => void;
}

/** Breadcrumb and selection hint inside the canvas region. It is a thin
 *  overlay, not a side panel, so the four-region layout stays intact. */
export function CanvasBar({ labels, depth, selectedCount, onNavigate }: CanvasBarProps) {
  return (
    <div className="canvasbar" data-testid="canvasbar">
      <nav className="canvasbar__crumbs" aria-label="Composite layers">
        {labels.map((label, index) => (
          <span className="canvasbar__crumb-wrap" key={label + "-" + index}>
            {index > 0 ? <span className="canvasbar__sep">/</span> : null}
            <button
              type="button"
              data-testid={"crumb-" + index}
              className={
                "canvasbar__crumb" + (index === depth ? " canvasbar__crumb--current" : "")
              }
              onClick={() => onNavigate(index)}
              disabled={index === depth}
              title={index === 0 ? "返回顶层画布" : "返回 " + label}
            >
              {index === 0 ? "顶层" : label}
            </button>
          </span>
        ))}
      </nav>
      <span className="canvasbar__hint">
        {depth > 0 ? "组合内部" : "自由画布"}
        {selectedCount > 0 ? " · 已选 " + selectedCount : ""}
      </span>
    </div>
  );
}
