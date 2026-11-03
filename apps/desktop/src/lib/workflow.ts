import type {
  DataType,
  EdgeDoc,
  NodeSpec,
  PositionDoc,
  WorkflowDoc,
  WorkflowNodeDoc,
} from "./types";

export const SCHEMA_VERSION = "1.0";

export type WorkflowMeta = Pick<
  WorkflowDoc,
  "id" | "name" | "description" | "metadata" | "viewport"
>;

export function newWorkflow(name = "untitled"): WorkflowDoc {
  return {
    schemaVersion: SCHEMA_VERSION,
    id: `wf-${crypto.randomUUID()}`,
    name,
    description: "",
    nodes: [],
    edges: [],
    viewport: { x: 0, y: 0, zoom: 1 },
    metadata: {},
  };
}

/** The type rule the validator applies, mirrored for instant feedback. */
export function accepts(target: DataType, source: DataType): boolean {
  return target === "any" || source === "any" || target === source;
}

export function defaultParams(spec: NodeSpec): Record<string, unknown> {
  const params: Record<string, unknown> = {};
  for (const param of spec.params) {
    if (param.defaultValue !== undefined) {
      params[param.name] = param.defaultValue;
    }
  }
  return params;
}

export function toDocEdge(
  source: string,
  sourcePort: string,
  target: string,
  targetPort: string,
): EdgeDoc {
  return {
    id: `${source}:${sourcePort}->${target}:${targetPort}`,
    source,
    sourcePort,
    target,
    targetPort,
  };
}

export function nodeLabel(node: WorkflowNodeDoc, spec: NodeSpec | undefined): string {
  const custom = node.label?.trim();
  if (custom) return custom;
  return spec?.title ?? node.kind;
}

export function viewportOf(viewport: WorkflowDoc["viewport"]): PositionDoc & { zoom: number } {
  return {
    x: viewport?.x ?? 0,
    y: viewport?.y ?? 0,
    zoom: viewport?.zoom ?? 1,
  };
}
