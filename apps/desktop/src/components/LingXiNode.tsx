import { useEffect, useRef, useState } from "react";
import { Handle, Position, type NodeProps } from "@xyflow/react";
import { open } from "@tauri-apps/plugin-dialog";

import { api } from "../lib/api";
import { useI18n } from "../lib/i18n";
import type { LingXiNode as LingXiNodeModel, NodeRunState } from "../lib/nodeData";
import { isTauri } from "../lib/tauri";
import type {
  AssetKind,
  AssetRef,
  ModelCapabilities,
  ParamSpec,
  ProjectOpenResponse,
  Support,
} from "../lib/types";

const RUN_STATE_TEXT: Record<NodeRunState, { zh: string; en: string }> = {
  running: { zh: "运行中", en: "Running" },
  completed: { zh: "完成", en: "Done" },
  failed: { zh: "失败", en: "Failed" },
  skipped: { zh: "跳过", en: "Skipped" },
  cancelled: { zh: "终止", en: "Cancelled" },
};

interface ParamFieldProps {
  nodeId: string;
  nodeKind: string;
  param: ParamSpec;
  params: Record<string, unknown>;
  assets: Record<string, AssetRef>;
  allowedValues?: string[];
  readOnly?: boolean;
  onChange: (nodeId: string, name: string, value: unknown) => void;
  onAssetImported?: (asset: AssetRef) => void;
  onProjectOpened?: (opened: ProjectOpenResponse) => void;
}

function currentValue(param: ParamSpec, params: Record<string, unknown>): unknown {
  return params[param.name] !== undefined ? params[param.name] : param.defaultValue;
}

function assetKindForNode(kind: string): AssetKind {
  if (kind === "core.input.audio") return "audio";
  if (kind === "core.input.video") return "video";
  if (kind === "core.input.document") return "document";
  return "image";
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / 1024 / 1024).toFixed(1) + " MB";
}

function AssetField({
  nodeId,
  nodeKind,
  param,
  value,
  assets,
  readOnly,
  onChange,
  onAssetImported,
}: {
  nodeId: string;
  nodeKind: string;
  param: ParamSpec;
  value: unknown;
  assets: Record<string, AssetRef>;
  readOnly?: boolean;
  onChange: (nodeId: string, name: string, value: unknown) => void;
  onAssetImported?: (asset: AssetRef) => void;
}) {
  const { tx } = useI18n();
  const kind = assetKindForNode(nodeKind);
  const ids = Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : [];
  const inputRef = useRef<HTMLInputElement>(null);
  const [previews, setPreviews] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    const missing = ids.filter((id) => !previews[id] && assets[id] && assets[id].size <= 8 * 1024 * 1024);
    if (missing.length === 0) return;
    void (async () => {
      for (const id of missing) {
        const asset = assets[id];
        if (!asset) continue;
        try {
          const dataUrl = await api.assetPreview(id, asset.mime);
          if (!cancelled) setPreviews((current) => ({ ...current, [id]: dataUrl }));
        } catch {
          // A missing preview must not block editing the workflow.
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [assets, ids, previews]);

  const append = (imported: AssetRef[]) => {
    if (imported.length === 0) return;
    const merged = [...ids];
    for (const asset of imported) {
      if (!merged.includes(asset.id)) merged.push(asset.id);
      onAssetImported?.(asset);
    }
    onChange(nodeId, param.name, merged);
  };

  const importFiles = async (files: File[]) => {
    if (files.length === 0) return;
    setBusy(true);
    setError("");
    try {
      const imported: AssetRef[] = [];
      for (const file of files) imported.push(await api.assetImportFile(file, kind));
      append(imported);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  const pick = async () => {
    setError("");
    if (!isTauri()) {
      inputRef.current?.click();
      return;
    }
    const filters =
      kind === "image"
        ? [{ name: "Images", extensions: ["png", "jpg", "jpeg", "webp", "gif"] }]
        : kind === "audio"
          ? [{ name: "Audio", extensions: ["mp3", "wav", "m4a", "ogg", "flac"] }]
          : kind === "video"
            ? [{ name: "Video", extensions: ["mp4", "mov", "webm", "mkv"] }]
            : [{ name: "Documents", extensions: ["pdf", "docx", "txt", "md"] }];
    try {
      const selected = await open({ multiple: true, directory: false, filters });
      if (!selected) return;
      const paths = Array.isArray(selected) ? selected : [selected];
      setBusy(true);
      const imported: AssetRef[] = [];
      for (const path of paths) imported.push(await api.assetImport(path, kind));
      append(imported);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="field field--asset" data-testid={"param-" + nodeId + "-" + param.name}>
      <div className="field__label-row">
        <span className="field__label">{tx(param.label, param.label)}</span>
        <button
          type="button"
          className="field__asset-add nodrag"
          data-testid={"asset-add-" + nodeId}
          disabled={busy || readOnly}
          onClick={() => void pick()}
        >
          {busy ? tx("导入中…", "Importing…") : tx("添加文件", "Add file")}
        </button>
        <input
          ref={inputRef}
          type="file"
          multiple
          hidden
          data-testid={"asset-file-" + nodeId}
          accept={
            kind === "image"
              ? "image/png,image/jpeg,image/webp,image/gif"
              : kind === "audio"
                ? "audio/*"
                : kind === "video"
                  ? "video/*"
                  : ".pdf,.docx,.txt,.md,application/pdf"
          }
          onChange={(event) => {
            const files = Array.from(event.target.files ?? []);
            event.target.value = "";
            void importFiles(files);
          }}
        />
      </div>
      {ids.length === 0 ? (
        <p className="field__asset-empty">{tx("尚未导入文件", "No files imported yet")}</p>
      ) : (
        <ul className="asset-list">
          {ids.map((id) => {
            const asset = assets[id];
            const preview = previews[id];
            return (
              <li className="asset" key={id} data-testid={"asset-" + nodeId + "-" + id}>
                <div className="asset__thumb">
                  {kind === "document" ? <span className="asset__doc">DOC</span> : null}
                  {preview && kind === "image" ? <img src={preview} alt={asset?.name ?? id} /> : null}
                  {preview && kind === "audio" ? <audio controls src={preview} /> : null}
                  {preview && kind === "video" ? <video controls src={preview} /> : null}
                  {!preview && kind !== "document" ? <span className="asset__pending">◌</span> : null}
                </div>
                <div className="asset__body">
                  <span className="asset__name" title={asset?.name ?? id}>
                    {asset?.name ?? id}
                  </span>
                  <span className="asset__meta">
                    {asset ? asset.mime + " · " + formatBytes(asset.size) : tx("资源缺失", "Missing asset")}
                  </span>
                </div>
                <button
                  type="button"
                  className="asset__remove nodrag"
                  data-testid={"asset-remove-" + nodeId + "-" + id}
                  title={tx("移除", "Remove")}
                  disabled={readOnly}
                  onClick={() => onChange(nodeId, param.name, ids.filter((entry) => entry !== id))}
                >
                  ×
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {error ? <p className="field__error">{error}</p> : null}
    </div>
  );
}

function ProjectField({
  nodeId,
  value,
  readOnly,
  onChange,
  onProjectOpened,
}: {
  nodeId: string;
  value: unknown;
  readOnly?: boolean;
  onChange: (nodeId: string, name: string, value: unknown) => void;
  onProjectOpened?: (opened: ProjectOpenResponse) => void;
}) {
  const { tx } = useI18n();
  const projectId = typeof value === "string" ? value : "";
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    if (!projectId) {
      setName("");
      return;
    }
    void api
      .projectList()
      .then((projects) => {
        if (!cancelled) {
          setName(projects.find((project) => project.projectId === projectId)?.name ?? projectId);
        }
      })
      .catch(() => {
        if (!cancelled) setName(projectId);
      });
    return () => {
      cancelled = true;
    };
  }, [projectId]);

  const pick = async () => {
    setBusy(true);
    setError("");
    try {
      const root = await api.pickProjectFolder();
      if (!root) return;
      const opened = await api.projectOpen(root);
      onChange(nodeId, "projectId", opened.project.projectId);
      onProjectOpened?.(opened);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="field">
      <span className="field__label">
        {tx("项目文件夹", "Project folder")}
      </span>
      <div className="field__row">
        <input
          className="field__control"
          data-testid={"param-" + nodeId + "-projectId"}
          readOnly
          value={projectId ? name || projectId : ""}
          placeholder={tx("尚未绑定项目", "No project bound")}
        />
        <button
          type="button"
          className="btn btn--ghost btn--compact nodrag"
          data-testid={"pick-project-" + nodeId}
          disabled={readOnly || busy}
          onClick={() => void pick()}
        >
          {tx("选择项目文件夹", "Choose folder")}
        </button>
      </div>
      <span className="field__hint">
        {tx(
          "工作流只保存 ProjectRef；绝对路径保留在本机注册表。",
          "The workflow stores a ProjectRef; absolute paths stay in the local registry.",
        )}
      </span>
      {error ? <p className="field__error">{error}</p> : null}
    </div>
  );
}

function ParamField({
  nodeId,
  nodeKind,
  param,
  params,
  assets,
  allowedValues,
  readOnly,
  onChange,
  onAssetImported,
  onProjectOpened,
}: ParamFieldProps) {
  const { tx, paramLabel, optionLabel } = useI18n();
  const value = currentValue(param, params);
  const inputId = nodeId + "-" + param.name;
  const label = paramLabel(param.name, param.label);

  if (nodeKind === "core.project_workspace" && param.name === "projectId") {
    return (
      <ProjectField
        nodeId={nodeId}
        value={value}
        readOnly={readOnly}
        onChange={onChange}
        onProjectOpened={onProjectOpened}
      />
    );
  }

  if (param.kind === "asset") {
    return (
      <AssetField
        nodeId={nodeId}
        nodeKind={nodeKind}
        param={{ ...param, label }}
        value={value}
        assets={assets}
        readOnly={readOnly}
        onChange={onChange}
        onAssetImported={onAssetImported}
      />
    );
  }

  if (param.kind === "boolean") {
    return (
      <label className="field field--boolean" htmlFor={inputId}>
        <input
          id={inputId}
          data-testid={"param-" + nodeId + "-" + param.name}
          type="checkbox"
          className="nodrag"
          disabled={readOnly}
          checked={Boolean(value)}
          onChange={(event) => onChange(nodeId, param.name, event.target.checked)}
        />
        <span>{label}</span>
      </label>
    );
  }

  if (param.kind === "select") {
    const options =
      allowedValues && allowedValues.length > 0
        ? param.options.filter((option) => allowedValues.includes(option.value))
        : param.options;
    return (
      <label className="field" htmlFor={inputId}>
        <span className="field__label">{label}</span>
        <select
          id={inputId}
          data-testid={"param-" + nodeId + "-" + param.name}
          className="field__control nodrag"
          disabled={readOnly}
          value={String(value ?? "")}
          onChange={(event) => onChange(nodeId, param.name, event.target.value)}
        >
          {options.map((option) => (
            <option key={option.value} value={option.value}>
              {optionLabel(option)}
            </option>
          ))}
        </select>
        {allowedValues && allowedValues.length < param.options.length ? (
          <span className="field__hint">
            {tx("仅显示当前模型支持的等级", "Only levels supported by the linked model are shown")}
          </span>
        ) : null}
      </label>
    );
  }

  if (param.kind === "text_area") {
    return (
      <label className="field" htmlFor={inputId}>
        <span className="field__label">{label}</span>
        <textarea
          id={inputId}
          data-testid={"param-" + nodeId + "-" + param.name}
          className="field__control field__control--area nodrag"
          rows={3}
          disabled={readOnly}
          value={String(value ?? "")}
          onChange={(event) => onChange(nodeId, param.name, event.target.value)}
        />
      </label>
    );
  }

  if (param.kind === "number") {
    return (
      <label className="field" htmlFor={inputId}>
        <span className="field__label">{label}</span>
        <input
          id={inputId}
          data-testid={"param-" + nodeId + "-" + param.name}
          type="number"
          className="field__control nodrag"
          disabled={readOnly}
          value={value === undefined || value === null ? "" : String(value)}
          onChange={(event) => {
            const raw = event.target.value;
            onChange(nodeId, param.name, raw === "" ? 0 : Number(raw));
          }}
        />
      </label>
    );
  }

  return (
    <label className="field" htmlFor={inputId}>
      <span className="field__label">{label}</span>
      <input
        id={inputId}
        data-testid={"param-" + nodeId + "-" + param.name}
        type="text"
        className="field__control nodrag"
        disabled={readOnly}
        value={String(value ?? "")}
        onChange={(event) => onChange(nodeId, param.name, event.target.value)}
      />
    </label>
  );
}

const SUPPORT_TEXT: Record<Support, { zh: string; en: string }> = {
  native: { zh: "原生", en: "Native" },
  preprocessed: { zh: "预处理", en: "Preprocessed" },
  unsupported: { zh: "不支持", en: "Unsupported" },
  unknown: { zh: "未知", en: "Unknown" },
};

const SUPPORT_ICON: Record<Support, string> = {
  native: "●",
  preprocessed: "◐",
  unsupported: "○",
  unknown: "?",
};

function CapabilityPanel({ data }: { data: LingXiNodeModel["data"] }) {
  const { tx, locale } = useI18n();
  const [caps, setCaps] = useState<ModelCapabilities | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    if (!data.protocol || !data.modelName) {
      setCaps(null);
      setError("");
      return;
    }
    void api
      .modelCapabilities(data.protocol, data.modelName, data.capabilitiesOverride)
      .then((next) => {
        if (!cancelled) {
          setCaps(next);
          setError("");
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) setError(cause instanceof Error ? cause.message : String(cause));
      });
    return () => {
      cancelled = true;
    };
  }, [data.protocol, data.modelName, data.capabilitiesOverride]);

  const supportLabel = (value: Support) =>
    locale === "en" ? SUPPORT_TEXT[value].en : SUPPORT_TEXT[value].zh;

  if (!data.protocol || !data.modelName) {
    return (
      <div className="node__caps node__caps--empty" data-testid="model-capabilities">
        {tx("连接服务提供方并填写模型后显示能力", "Connect a provider and set a model to see capabilities")}
      </div>
    );
  }
  if (error) {
    return (
      <div className="node__caps node__caps--error" data-testid="model-capabilities">
        {tx("能力读取失败：", "Capability lookup failed: ") + error}
      </div>
    );
  }
  if (!caps) {
    return (
      <div className="node__caps node__caps--empty" data-testid="model-capabilities">
        {tx("读取模型能力…", "Reading model capabilities…")}
      </div>
    );
  }

  const inputRows: Array<[string, Support]> = [
    [tx("文本", "Text"), caps.input.text],
    [tx("图片", "Image"), caps.input.image],
    [tx("音频", "Audio"), caps.input.audio],
    [tx("视频", "Video"), caps.input.video],
    [tx("文档", "Document"), caps.input.document],
  ];
  const featureRows: Array<[string, Support]> = [
    [tx("流式", "Streaming"), caps.features.streaming],
    [tx("工具", "Tools"), caps.features.toolCalling],
    [tx("思考", "Reasoning"), caps.features.reasoning],
    [tx("结构化输出", "Structured"), caps.features.structuredOutput],
  ];

  return (
    <div className="node__caps" data-testid="model-capabilities">
      <div className="node__caps-head">
        <span>{tx("模型能力", "Model capabilities")}</span>
        <span className="node__caps-source">{caps.source}</span>
      </div>
      <div className="node__caps-grid">
        {inputRows.map(([label, value]) => (
          <span
            key={label}
            className={"cap cap--" + value}
            title={tx("输入 · ", "Input · ") + label + " · " + supportLabel(value)}
          >
            <b>{SUPPORT_ICON[value]}</b>
            {label}
          </span>
        ))}
      </div>
      <div className="node__caps-grid node__caps-grid--features">
        {featureRows.map(([label, value]) => (
          <span key={label} className={"cap cap--" + value} title={label + " · " + supportLabel(value)}>
            <b>{SUPPORT_ICON[value]}</b>
            {label}
          </span>
        ))}
      </div>
      <div className="node__caps-limits">
        {caps.limits.maxContextTokens != null
          ? tx("上下文 " + caps.limits.maxContextTokens, "ctx " + caps.limits.maxContextTokens)
          : tx("上下文未知", "ctx unknown")}
        {" · "}
        {caps.limits.maxOutputTokens != null
          ? tx("输出 " + caps.limits.maxOutputTokens, "out " + caps.limits.maxOutputTokens)
          : tx("输出未知", "out unknown")}
      </div>
    </div>
  );
}

function categoryClass(category: string): string {
  switch (category.toLowerCase()) {
    case "input":
      return "amber";
    case "media":
      return "amber";
    case "text":
      return "blue";
    case "number":
      return "teal";
    case "output":
      return "green";
    case "control":
    case "logic":
      return "violet";
    case "composite":
      return "violet";
    case "agent":
      return "indigo";
    case "tools":
      return "cyan";
    default:
      return "slate";
  }
}

export function LingXiNode({ id, data, selected }: NodeProps<LingXiNodeModel>) {
  const { spec, params, enabled, run, assets } = data;
  const { tx, locale, nodeTitle, portLabel } = useI18n();
  const title = data.label?.trim() ? data.label.trim() : nodeTitle(spec);
  const [caps, setCaps] = useState<ModelCapabilities | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (spec.kind !== "core.reasoning" || !data.protocol || !data.modelName) {
      setCaps(null);
      return;
    }
    void api
      .modelCapabilities(data.protocol, data.modelName, data.capabilitiesOverride)
      .then((next) => {
        if (!cancelled) setCaps(next);
      })
      .catch(() => {
        if (!cancelled) setCaps(null);
      });
    return () => {
      cancelled = true;
    };
  }, [spec.kind, data.protocol, data.modelName, data.capabilitiesOverride]);

  const reasoningLevels =
    spec.kind === "core.reasoning" && caps && caps.reasoningLevels.length > 0
      ? caps.reasoningLevels
      : undefined;

  return (
    <div
      className={
        "node" +
        (selected ? " node--selected" : "") +
        (enabled ? "" : " node--disabled") +
        (data.readOnly ? " node--locked" : "") +
        (run ? " node--" + run.state : "")
      }
      data-testid={"node-" + id}
      data-node-kind={spec.kind}
      data-node-id={id}
      data-run-state={run?.state ?? "idle"}
    >
      <header className="node__header">
        <span className={"node__dot node__dot--" + categoryClass(spec.category)} />
        <div className="node__titles">
          <span className="node__title">{title}</span>
          <span className="node__kind">{spec.kind}</span>
        </div>
        {run ? (
          <span
            className={"node__run node__run--" + run.state}
            title={
              "activation " +
              run.activation +
              (run.iteration != null ? " · iteration " + run.iteration : "")
            }
          >
            {run.iteration != null
              ? tx("迭代 " + run.iteration, "iter " + run.iteration)
              : locale === "en"
                ? RUN_STATE_TEXT[run.state].en
                : RUN_STATE_TEXT[run.state].zh}
          </span>
        ) : null}
        <button
          type="button"
          className={"node__power nodrag" + (enabled ? " node__power--on" : "")}
          data-testid={"node-toggle-" + id}
          disabled={data.readOnly}
          title={enabled ? tx("停用节点", "Disable node") : tx("启用节点", "Enable node")}
          onClick={() => data.onToggleEnabled(id)}
        >
          {enabled ? "on" : "off"}
        </button>
      </header>

      {data.subgraphId ? (
        <div className="node__composite">
          <span className="node__composite-tag">{tx("组合", "Composite")}</span>
          <span>
            {tx(
              (data.innerNodeCount ?? 0) + " 个内部节点 · 双击展开",
              (data.innerNodeCount ?? 0) + " inner nodes · double-click to expand",
            )}
          </span>
        </div>
      ) : null}

      <div className="node__ports">
        <div className="node__col">
          {spec.inputs.map((port) => (
            <div className="port port--in" key={port.name}>
              <Handle
                type="target"
                position={Position.Left}
                id={port.name}
                data-testid={"handle-in-" + id + "-" + port.name}
                className={
                  "port__handle dt-" + port.dataType + (port.control ? " port__handle--control" : "")
                }
              />
              <span className={port.required ? "port__label port__label--required" : "port__label"}>
                {portLabel(port)}
              </span>
            </div>
          ))}
        </div>
        <div className="node__col node__col--out">
          {spec.outputs.map((port) => (
            <div className="port port--out" key={port.name}>
              <span className="port__label">{portLabel(port)}</span>
              <Handle
                type="source"
                position={Position.Right}
                id={port.name}
                data-testid={"handle-out-" + id + "-" + port.name}
                className={
                  "port__handle dt-" + port.dataType + (port.control ? " port__handle--control" : "")
                }
              />
            </div>
          ))}
        </div>
      </div>

      {spec.kind === "core.model" || spec.kind === "core.reasoning" ? (
        <CapabilityPanel data={data} />
      ) : null}

      {spec.params.length > 0 ? (
        <div className="node__params">
          {spec.params.map((param) => (
            <ParamField
              key={param.name}
              nodeId={id}
              nodeKind={spec.kind}
              param={param}
              params={params}
              assets={assets ?? {}}
              allowedValues={param.name === "level" ? reasoningLevels : undefined}
              readOnly={data.readOnly}
              onChange={data.onParamChange}
              onAssetImported={data.onAssetImported}
              onProjectOpened={data.onProjectOpened}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}
