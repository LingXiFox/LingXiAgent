import { useEffect, useMemo, useState, type DragEvent, type KeyboardEvent } from "react";

import { LIBRARY_GROUPS, useI18n, type LibraryGroupId } from "../lib/i18n";
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

const COLLAPSED_KEY = "lingxi.library.collapsed";
const SIDEBAR_KEY = "lingxi.library.sidebar";
const TEMPLATE_GROUP = "my-composite";

function readCollapsed(): Set<string> {
  if (typeof window === "undefined") return new Set();
  try {
    const raw = window.localStorage.getItem(COLLAPSED_KEY);
    const parsed = raw ? (JSON.parse(raw) as unknown) : [];
    return new Set(Array.isArray(parsed) ? parsed.filter((id): id is string => typeof id === "string") : []);
  } catch {
    return new Set();
  }
}

function groupSpecs(specs: NodeSpec[], groupFor: (spec: NodeSpec) => LibraryGroupId) {
  const map = new Map<LibraryGroupId, NodeSpec[]>();
  for (const spec of specs) {
    const id = groupFor(spec);
    const list = map.get(id) ?? [];
    list.push(spec);
    map.set(id, list);
  }
  for (const list of map.values()) list.sort((a, b) => a.title.localeCompare(b.title));
  return map;
}

export function NodeLibrary({
  specs,
  templates,
  onAdd,
  onAddTemplate,
  disabled,
}: NodeLibraryProps) {
  const { locale, setLocale, tx, nodeTitle, nodeDescription, groupFor, groupLabel, groupIcon } = useI18n();
  const [query, setQuery] = useState("");
  const [collapsed, setCollapsed] = useState<Set<string>>(readCollapsed);
  const [sidebarOpen, setSidebarOpen] = useState<boolean>(() => {
    if (typeof window === "undefined") return true;
    return window.localStorage.getItem(SIDEBAR_KEY) !== "closed";
  });
  const [dragging, setDragging] = useState<string | null>(null);

  useEffect(() => {
    window.localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...collapsed]));
  }, [collapsed]);

  useEffect(() => {
    window.localStorage.setItem(SIDEBAR_KEY, sidebarOpen ? "open" : "closed");
  }, [sidebarOpen]);

  const needle = query.trim().toLowerCase();
  const searching = needle.length > 0;

  const groups = useMemo(() => {
    const filtered = needle
      ? specs.filter((spec) => {
          const haystack = [
            spec.kind,
            spec.title,
            spec.description,
            spec.category,
            nodeTitle(spec),
            nodeDescription(spec),
            groupLabel(groupFor(spec)),
            LIBRARY_GROUPS.find((group) => group.id === groupFor(spec))?.en ?? "",
          ]
            .join(" ")
            .toLowerCase();
          return haystack.includes(needle);
        })
      : specs;
    return groupSpecs(filtered, groupFor);
  }, [specs, needle, groupFor, groupLabel, nodeTitle, nodeDescription]);

  const visibleTemplates = useMemo(() => {
    if (!needle) return templates;
    return templates.filter((template) =>
      (template.name + " composite template 我的组合").toLowerCase().includes(needle),
    );
  }, [needle, templates]);

  const visibleGroups = useMemo(
    () =>
      LIBRARY_GROUPS.filter((meta) => {
        if (meta.id === TEMPLATE_GROUP) return visibleTemplates.length > 0;
        return (groups.get(meta.id)?.length ?? 0) > 0;
      }),
    [groups, visibleTemplates.length],
  );

  const toggleGroup = (id: string) => {
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const expandAll = () => setCollapsed(new Set());
  const collapseAll = () => setCollapsed(new Set(visibleGroups.map((group) => group.id)));

  const onDragStart = (event: DragEvent<HTMLDivElement>, spec: NodeSpec) => {
    if (disabled) {
      event.preventDefault();
      return;
    }
    event.dataTransfer.setData(NODE_DRAG_TYPE, spec.kind);
    event.dataTransfer.effectAllowed = "copy";
    setDragging(spec.kind);
  };

  const onTemplateDragStart = (event: DragEvent<HTMLDivElement>, id: string) => {
    if (disabled) {
      event.preventDefault();
      return;
    }
    event.dataTransfer.setData(TEMPLATE_DRAG_TYPE, id);
    event.dataTransfer.effectAllowed = "copy";
    setDragging("template:" + id);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>, kind: string) => {
    if (disabled) return;
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      onAdd(kind);
    }
  };

  if (!sidebarOpen) {
    return (
      <aside className="library library--rail" data-testid="library">
        <button
          type="button"
          className="library__rail-toggle"
          data-testid="library-toggle"
          aria-label={tx("展开节点库", "Expand node library")}
          title={tx("展开节点库", "Expand node library")}
          onClick={() => setSidebarOpen(true)}
        >
          ›
        </button>
        <span className="library__rail-mark">泠</span>
        {visibleGroups.slice(0, 6).map((group) => (
          <span key={group.id} className="library__rail-icon" title={groupLabel(group.id)}>
            {groupIcon(group.id)}
          </span>
        ))}
      </aside>
    );
  }

  return (
    <aside className="library" data-testid="library">
      <div className="library__brand">
        <span className="library__mark" />
        <div className="library__brand-text">
          <h1 className="library__title">{tx("泠溪", "LingXi")}</h1>
          <p className="library__subtitle">LingXiAgent 3.0</p>
        </div>
        <button
          type="button"
          className="library__collapse"
          data-testid="library-toggle"
          aria-label={tx("收起节点库", "Collapse node library")}
          title={tx("收起节点库", "Collapse node library")}
          onClick={() => setSidebarOpen(false)}
        >
          ‹
        </button>
      </div>

      <div className="library__search">
        <input
          type="search"
          data-testid="library-search"
          placeholder={tx("搜索节点 / Search nodes", "Search nodes / 搜索")}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          aria-label={tx("搜索节点", "Search nodes")}
        />
        {searching ? (
          <button
            type="button"
            className="library__search-clear"
            aria-label={tx("清除搜索", "Clear search")}
            onClick={() => setQuery("")}
          >
            ×
          </button>
        ) : null}
      </div>

      <div className="library__tools">
        <button type="button" data-testid="library-expand-all" onClick={expandAll}>
          {tx("全部展开", "Expand all")}
        </button>
        <button type="button" data-testid="library-collapse-all" onClick={collapseAll}>
          {tx("全部收起", "Collapse all")}
        </button>
        <button
          type="button"
          data-testid="locale-toggle"
          title={tx("切换为英文界面", "切换到中文界面")}
          onClick={() => setLocale(locale === "zh-CN" ? "en" : "zh-CN")}
        >
          {locale === "zh-CN" ? "EN" : "中"}
        </button>
      </div>

      <div className="library__scroll">
        {visibleGroups.length === 0 ? (
          <p className="library__empty">{tx("没有匹配的节点", "No matching nodes")}</p>
        ) : null}
        {visibleGroups.map((group) => {
          const isCollapsed = collapsed.has(group.id) && !searching;
          const items = group.id === TEMPLATE_GROUP ? [] : groups.get(group.id) ?? [];
          const count = group.id === TEMPLATE_GROUP ? visibleTemplates.length : items.length;
          return (
            <section
              className={"library__group" + (isCollapsed ? " library__group--collapsed" : "")}
              key={group.id}
              data-testid={"library-group-" + group.id}
            >
              <button
                type="button"
                className="library__group-head"
                aria-expanded={!isCollapsed}
                onClick={() => toggleGroup(group.id)}
              >
                <span className="library__group-icon" aria-hidden="true">
                  {groupIcon(group.id)}
                </span>
                <span className="library__group-title">{groupLabel(group.id)}</span>
                <span className="library__group-count" data-testid={"library-count-" + group.id}>
                  {count}
                </span>
                <span className="library__chevron" aria-hidden="true">
                  {isCollapsed ? "›" : "⌄"}
                </span>
              </button>
              {!isCollapsed ? (
                <div className="library__items">
                  {group.id === TEMPLATE_GROUP
                    ? visibleTemplates.map((template) => (
                        <div
                          key={template.id}
                          data-testid={"library-template-" + template.id}
                          role="button"
                          tabIndex={disabled ? -1 : 0}
                          aria-disabled={disabled}
                          className={
                            "library__item library__item--template" +
                            (disabled ? " library__item--disabled" : "") +
                            (dragging === "template:" + template.id ? " library__item--dragging" : "")
                          }
                          title={tx(
                            "组合模板 · " + template.nodeCount + " 个内部节点 · 拖入画布创建独立实例",
                            "Composite template · " + template.nodeCount + " inner nodes · drag to instantiate",
                          )}
                          draggable={!disabled}
                          onDragStart={(event) => onTemplateDragStart(event, template.id)}
                          onDragEnd={() => setDragging(null)}
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
                          <span className="library__item-icon">⬚</span>
                          <span className="library__item-body">
                            <span className="library__item-title">{template.name}</span>
                            <span className="library__item-desc">
                              {tx(
                                template.nodeCount + " 个内部节点 · " + template.inputCount + " 入 / " + template.outputCount + " 出",
                                template.nodeCount + " inner nodes · " + template.inputCount + " in / " + template.outputCount + " out",
                              )}
                            </span>
                          </span>
                        </div>
                      ))
                    : items.map((spec) => (
                        // A div rather than a button: WebKit does not reliably start an
                        // HTML5 drag from a <button>, and dragging is the primary way to
                        // place a node.
                        <div
                          key={spec.kind}
                          data-testid={"library-item-" + spec.kind}
                          role="button"
                          tabIndex={disabled ? -1 : 0}
                          aria-disabled={disabled}
                          className={
                            "library__item" +
                            (disabled ? " library__item--disabled" : "") +
                            (dragging === spec.kind ? " library__item--dragging" : "")
                          }
                          title={nodeDescription(spec) + " · " + spec.kind}
                          draggable={!disabled}
                          onDragStart={(event) => onDragStart(event, spec)}
                          onDragEnd={() => setDragging(null)}
                          onClick={() => {
                            if (!disabled) onAdd(spec.kind);
                          }}
                          onKeyDown={(event) => onKeyDown(event, spec.kind)}
                        >
                          <span className="library__item-icon" aria-hidden="true">
                            {groupIcon(group.id)}
                          </span>
                          <span className="library__item-body">
                            <span className="library__item-title">{nodeTitle(spec)}</span>
                            <span className="library__item-desc">{nodeDescription(spec)}</span>
                          </span>
                          <span className="library__item-kind">{spec.kind.replace("core.", "")}</span>
                        </div>
                      ))}
                </div>
              ) : null}
            </section>
          );
        })}
      </div>

      <p className="library__footnote">
        {disabled
          ? tx("运行中不可修改结构", "Structure locked while running")
          : tx("拖拽或单击添加节点", "Drag or click to add a node")}
      </p>
    </aside>
  );
}
