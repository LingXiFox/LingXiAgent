import { useMemo, useState, type DragEvent } from "react";

import type { NodeSpec, TemplateSummary } from "../lib/types";

export const NODE_DRAG_TYPE = "application/lingxi-node";
export const TEMPLATE_DRAG_TYPE = "application/lingxi-template";

interface NodeLibraryProps {
  specs: NodeSpec[];
  templates: TemplateSummary[];
  onAdd: (kind: string) => void;
  onAddTemplate: (id: string) => void;
  disabled: boolean;
}

const CATEGORY_ORDER = ["Input", "Text", "Number", "Control", "Output"];

export function NodeLibrary({
  specs,
  templates,
  onAdd,
  onAddTemplate,
  disabled,
}: NodeLibraryProps) {
  const [query, setQuery] = useState("");

  const visibleTemplates = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return templates;
    return templates.filter((template) =>
      (template.name + " composite template").toLowerCase().includes(needle),
    );
  }, [query, templates]);

  const groups = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const filtered = needle
      ? specs.filter((spec) => {
          const haystack = (spec.kind + " " + spec.title + " " + spec.category + " " + spec.description).toLowerCase();
          return haystack.includes(needle);
        })
      : specs;
    const map = new Map<string, NodeSpec[]>();
    for (const spec of filtered) {
      const list = map.get(spec.category) ?? [];
      list.push(spec);
      map.set(spec.category, list);
    }
    return [...map.entries()].sort((a, b) => {
      const ai = CATEGORY_ORDER.indexOf(a[0]);
      const bi = CATEGORY_ORDER.indexOf(b[0]);
      return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi) || a[0].localeCompare(b[0]);
    });
  }, [specs, query]);

  const onDragStart = (event: DragEvent<HTMLDivElement>, spec: NodeSpec) => {
    if (disabled) {
      event.preventDefault();
      return;
    }
    event.dataTransfer.setData(NODE_DRAG_TYPE, spec.kind);
    event.dataTransfer.effectAllowed = "copy";
  };

  const onTemplateDragStart = (event: DragEvent<HTMLDivElement>, id: string) => {
    if (disabled) {
      event.preventDefault();
      return;
    }
    event.dataTransfer.setData(TEMPLATE_DRAG_TYPE, id);
    event.dataTransfer.effectAllowed = "copy";
  };

  const onKeyDown = (event: React.KeyboardEvent<HTMLDivElement>, kind: string) => {
    if (disabled) return;
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      onAdd(kind);
    }
  };

  return (
    <aside className="library">
      <div className="library__brand">
        <span className="library__mark" />
        <div>
          <h1 className="library__title">泠溪</h1>
          <p className="library__subtitle">LingXiAgent 3.0</p>
        </div>
      </div>

      <div className="library__search">
        <input
          type="search"
          placeholder="搜索节点 / Search nodes"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
      </div>

      <div className="library__scroll">
        {visibleTemplates.length > 0 ? (
          <section className="library__group">
            <h2 className="library__group-title">我的组合</h2>
            {visibleTemplates.map((template) => (
              <div
                key={template.id}
                role="button"
                tabIndex={disabled ? -1 : 0}
                aria-disabled={disabled}
                className={
                  "library__item library__item--template" +
                  (disabled ? " library__item--disabled" : "")
                }
                title={
                  "组合模板 · " +
                  template.nodeCount +
                  " 个内部节点 · 拖入画布创建独立实例"
                }
                draggable={!disabled}
                onDragStart={(event) => onTemplateDragStart(event, template.id)}
                onClick={() => {
                  if (!disabled) onAddTemplate(template.id);
                }}
                onKeyDown={(event) => {
                  if (disabled) return;
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    onAddTemplate(template.id);
                  }
                }}
              >
                <span className="library__item-title">{template.name}</span>
                <span className="library__item-meta">
                  {template.nodeCount} nodes · {template.inputCount} in · {template.outputCount} out
                </span>
              </div>
            ))}
          </section>
        ) : null}
        {groups.length === 0 && visibleTemplates.length === 0 ? (
          <p className="library__empty">没有匹配的节点</p>
        ) : null}
        {groups.map(([category, items]) => (
          <section className="library__group" key={category}>
            <h2 className="library__group-title">{category}</h2>
            {items.map((spec) => (
              // A div rather than a button: WebKit does not reliably start an
              // HTML5 drag from a <button>, and dragging is the primary way to
              // place a node.
              <div
                key={spec.kind}
                role="button"
                tabIndex={disabled ? -1 : 0}
                aria-disabled={disabled}
                className={"library__item" + (disabled ? " library__item--disabled" : "")}
                title={spec.description}
                draggable={!disabled}
                onDragStart={(event) => onDragStart(event, spec)}
                onClick={() => {
                  if (!disabled) onAdd(spec.kind);
                }}
                onKeyDown={(event) => onKeyDown(event, spec.kind)}
              >
                <span className="library__item-title">{spec.title}</span>
                <span className="library__item-meta">
                  {spec.inputs.length} in · {spec.outputs.length} out
                </span>
              </div>
            ))}
          </section>
        ))}
      </div>

      <p className="library__footnote">
        {disabled ? "运行中不可修改结构" : "拖拽或单击添加节点"}
      </p>
    </aside>
  );
}
