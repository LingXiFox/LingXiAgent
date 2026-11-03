import { Handle, Position, type NodeProps } from "@xyflow/react";

import type { LingXiNode as LingXiNodeModel } from "../lib/nodeData";
import type { ParamSpec } from "../lib/types";

interface ParamFieldProps {
  nodeId: string;
  param: ParamSpec;
  params: Record<string, unknown>;
  onChange: (nodeId: string, name: string, value: unknown) => void;
}

function currentValue(param: ParamSpec, params: Record<string, unknown>): unknown {
  return params[param.name] !== undefined ? params[param.name] : param.defaultValue;
}

function ParamField({ nodeId, param, params, onChange }: ParamFieldProps) {
  const value = currentValue(param, params);
  const inputId = nodeId + "-" + param.name;

  if (param.kind === "boolean") {
    return (
      <label className="field field--boolean" htmlFor={inputId}>
        <input
          id={inputId}
          type="checkbox"
          className="nodrag"
          checked={Boolean(value)}
          onChange={(event) => onChange(nodeId, param.name, event.target.checked)}
        />
        <span>{param.label}</span>
      </label>
    );
  }

  if (param.kind === "select") {
    return (
      <label className="field" htmlFor={inputId}>
        <span className="field__label">{param.label}</span>
        <select
          id={inputId}
          className="field__control nodrag"
          value={String(value ?? "")}
          onChange={(event) => onChange(nodeId, param.name, event.target.value)}
        >
          {param.options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      </label>
    );
  }

  if (param.kind === "text_area") {
    return (
      <label className="field" htmlFor={inputId}>
        <span className="field__label">{param.label}</span>
        <textarea
          id={inputId}
          className="field__control field__control--area nodrag"
          rows={3}
          value={String(value ?? "")}
          onChange={(event) => onChange(nodeId, param.name, event.target.value)}
        />
      </label>
    );
  }

  if (param.kind === "number") {
    return (
      <label className="field" htmlFor={inputId}>
        <span className="field__label">{param.label}</span>
        <input
          id={inputId}
          type="number"
          className="field__control nodrag"
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
      <span className="field__label">{param.label}</span>
      <input
        id={inputId}
        type="text"
        className="field__control nodrag"
        value={String(value ?? "")}
        onChange={(event) => onChange(nodeId, param.name, event.target.value)}
      />
    </label>
  );
}

function categoryClass(category: string): string {
  switch (category.toLowerCase()) {
    case "input":
      return "amber";
    case "text":
      return "blue";
    case "number":
      return "teal";
    case "output":
      return "green";
    case "control":
      return "violet";
    default:
      return "slate";
  }
}

export function LingXiNode({ id, data, selected }: NodeProps<LingXiNodeModel>) {
  const { spec, params, enabled } = data;
  const title = data.label?.trim() ? data.label.trim() : spec.title;

  return (
    <div
      className={
        "node" +
        (selected ? " node--selected" : "") +
        (enabled ? "" : " node--disabled")
      }
    >
      <header className="node__header">
        <span className={"node__dot node__dot--" + categoryClass(spec.category)} />
        <div className="node__titles">
          <span className="node__title">{title}</span>
          <span className="node__kind">{spec.kind}</span>
        </div>
        <button
          type="button"
          className={"node__power nodrag" + (enabled ? " node__power--on" : "")}
          title={enabled ? "Disable node" : "Enable node"}
          onClick={() => data.onToggleEnabled(id)}
        >
          {enabled ? "on" : "off"}
        </button>
      </header>

      <div className="node__ports">
        <div className="node__col">
          {spec.inputs.map((port) => (
            <div className="port port--in" key={port.name}>
              <Handle
                type="target"
                position={Position.Left}
                id={port.name}
                className={"port__handle dt-" + port.dataType}
              />
              <span className={port.required ? "port__label port__label--required" : "port__label"}>
                {port.label}
              </span>
            </div>
          ))}
        </div>
        <div className="node__col node__col--out">
          {spec.outputs.map((port) => (
            <div className="port port--out" key={port.name}>
              <span className="port__label">{port.label}</span>
              <Handle
                type="source"
                position={Position.Right}
                id={port.name}
                className={"port__handle dt-" + port.dataType}
              />
            </div>
          ))}
        </div>
      </div>

      {spec.params.length > 0 ? (
        <div className="node__params">
          {spec.params.map((param) => (
            <ParamField
              key={param.name}
              nodeId={id}
              param={param}
              params={params}
              onChange={data.onParamChange}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}
