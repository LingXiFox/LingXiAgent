import type {
  EdgeDoc,
  NodeSpec,
  PortBindingDoc,
  PortSpec,
  PositionDoc,
  Subgraph,
  SubgraphInputDoc,
  SubgraphOutputDoc,
  TemplateBundle,
  ViewportDoc,
  WorkflowDoc,
  WorkflowNodeDoc,
} from "./types";
import { SCHEMA_VERSION, toDocEdge, viewportOf } from "./workflow.ts";

export const COMPOSITE_NODE_KIND = "core.composite";

export type LayerPath = string[];

export interface CompositeResult {
  doc: WorkflowDoc;
  compositeNodeId: string;
  subgraphId: string;
}

export interface UngroupResult {
  doc: WorkflowDoc;
  restoredNodeIds: string[];
}

export interface InstantiatedTemplate {
  node: WorkflowNodeDoc;
  subgraphs: Record<string, Subgraph>;
}

function freshId(prefix: string): string {
  return prefix + "-" + crypto.randomUUID().slice(0, 8);
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

export function subgraphsOf(doc: WorkflowDoc): Record<string, Subgraph> {
  return doc.subgraphs ?? {};
}

export function compositeSpec(subgraph: Subgraph): NodeSpec {
  return {
    kind: COMPOSITE_NODE_KIND,
    title: subgraph.name,
    category: "Composite",
    description:
      "Composite of " + subgraph.workflow.nodes.length + " node(s), defined by subgraph " + subgraph.id,
    inputs: subgraph.inputs.map((input) => clone(input.port)),
    outputs: subgraph.outputs.map((output) => clone(output.port)),
    params: [],
    capabilities: [],
    control: "normal",
  };
}

export function nodeSpec(
  node: Pick<WorkflowNodeDoc, "kind" | "subgraphId">,
  baseSpecs: ReadonlyMap<string, NodeSpec>,
  subgraphs: Record<string, Subgraph>,
): NodeSpec | undefined {
  if (node.kind === COMPOSITE_NODE_KIND && node.subgraphId) {
    const subgraph = subgraphs[node.subgraphId];
    return subgraph ? compositeSpec(subgraph) : undefined;
  }
  return baseSpecs.get(node.kind);
}

/** The workflow object at `path`; definitions always live on the root document. */
export function layerWorkflow(doc: WorkflowDoc, path: LayerPath): WorkflowDoc | null {
  let workflow = doc;
  for (const id of path) {
    const subgraph = subgraphsOf(doc)[id];
    if (!subgraph) return null;
    workflow = subgraph.workflow;
  }
  return workflow;
}

export function layerLabel(doc: WorkflowDoc, path: LayerPath): string[] {
  const labels = ["顶层"];
  for (const id of path) {
    const subgraph = subgraphsOf(doc)[id];
    labels.push(subgraph?.name ?? id);
  }
  return labels;
}

/**
 * Write the currently edited canvas back into its layer and return a complete
 * root document. Calling this before save/validate/run/navigation keeps the
 * serialized JSON canonical even though the canvas is stateful.
 */
export function writeLayer(
  doc: WorkflowDoc,
  path: LayerPath,
  nodes: WorkflowNodeDoc[],
  edges: EdgeDoc[],
  viewport: ViewportDoc | null | undefined,
): WorkflowDoc {
  const next = clone(doc);
  let workflow = next;
  for (const id of path) {
    const subgraph = next.subgraphs?.[id];
    if (!subgraph) throw new Error("unknown subgraph layer " + id);
    workflow = subgraph.workflow;
  }
  workflow.nodes = clone(nodes);
  workflow.edges = clone(edges);
  workflow.viewport = viewport ? clone(viewport) : workflow.viewport;
  next.schemaVersion = SCHEMA_VERSION;
  return next;
}

function fallbackPort(name: string, control: boolean): PortSpec {
  return {
    name,
    label: name,
    dataType: "any",
    required: false,
    control,
  };
}

function uniqueName(base: string, used: Set<string>): string {
  const clean = base.trim() || "port";
  if (!used.has(clean)) {
    used.add(clean);
    return clean;
  }
  let index = 2;
  while (used.has(clean + "-" + index)) index += 1;
  const name = clean + "-" + index;
  used.add(name);
  return name;
}

function portFromSpec(
  spec: NodeSpec | undefined,
  side: "inputs" | "outputs",
  name: string,
  fallbackControl: boolean,
): PortSpec {
  const port = spec?.[side].find((candidate) => candidate.name === name);
  if (port) {
    return {
      name: port.name,
      label: port.label,
      dataType: port.dataType,
      required: side === "outputs" ? false : port.required,
      control: Boolean(port.control),
    };
  }
  return fallbackPort(name, fallbackControl);
}

/** Frame the definition so the first entry into a composite shows every
 *  internal node instead of the negative coordinates around its centre. */
function innerViewport(nodes: PositionDoc[]): ViewportDoc {
  if (nodes.length === 0) return { x: 0, y: 0, zoom: 1 };
  const width = 252;
  const height = 160;
  const minX = Math.min(...nodes.map((node) => node.x));
  const maxX = Math.max(...nodes.map((node) => node.x)) + width;
  const minY = Math.min(...nodes.map((node) => node.y));
  const maxY = Math.max(...nodes.map((node) => node.y)) + height;
  const zoom = Math.min(1, 1000 / (maxX - minX + 80), 560 / (maxY - minY + 80));
  return { x: 40 - minX * zoom, y: 80 - minY * zoom, zoom };
}

function layoutPosition(nodes: WorkflowNodeDoc[], width = 252, height = 120): PositionDoc {
  const xs = nodes.map((node) => node.position.x);
  const ys = nodes.map((node) => node.position.y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  return {
    x: (minX + maxX + width) / 2 - width,
    y: (minY + maxY + height) / 2 - height,
  };
}

interface InboundGroup {
  source: string;
  sourcePort: string;
  kind: EdgeDoc["kind"];
  edges: EdgeDoc[];
}

interface OutboundGroup {
  source: string;
  sourcePort: string;
  kind: EdgeDoc["kind"];
  edges: EdgeDoc[];
}

function groupKey(edge: EdgeDoc): string {
  return edge.source + "\u0000" + edge.sourcePort + "\u0000" + edge.kind;
}

/**
 * Wrap the selected nodes of the current layer into a composite. Boundary
 * edges become port bindings, internal edges move into the definition, and all
 * surviving outer edges are rewritten to the new composite node.
 */
export function groupSelection(
  doc: WorkflowDoc,
  path: LayerPath,
  selectedIds: string[],
  specFor: (node: WorkflowNodeDoc) => NodeSpec | undefined,
  name?: string,
): CompositeResult {
  const layer = layerWorkflow(doc, path);
  if (!layer) throw new Error("unknown layer");
  const selectedSet = new Set(selectedIds);
  const selected = layer.nodes.filter((node) => selectedSet.has(node.id));
  if (selected.length === 0) throw new Error("select at least one node");

  const internal = layer.edges.filter(
    (edge) => selectedSet.has(edge.source) && selectedSet.has(edge.target),
  );
  const inboundEdges = layer.edges.filter(
    (edge) => selectedSet.has(edge.target) && !selectedSet.has(edge.source),
  );
  const outboundEdges = layer.edges.filter(
    (edge) => selectedSet.has(edge.source) && !selectedSet.has(edge.target),
  );

  const inboundGroups = new Map<string, InboundGroup>();
  for (const edge of inboundEdges) {
    const key = groupKey(edge);
    const group = inboundGroups.get(key) ?? {
      source: edge.source,
      sourcePort: edge.sourcePort,
      kind: edge.kind,
      edges: [],
    };
    group.edges.push(edge);
    inboundGroups.set(key, group);
  }
  const outboundGroups = new Map<string, OutboundGroup>();
  for (const edge of outboundEdges) {
    const key = groupKey(edge);
    const group = outboundGroups.get(key) ?? {
      source: edge.source,
      sourcePort: edge.sourcePort,
      kind: edge.kind,
      edges: [],
    };
    group.edges.push(edge);
    outboundGroups.set(key, group);
  }

  const subgraphId = freshId("sg");
  const compositeNodeId = freshId("comp");
  const label = name?.trim() || "组合 " + (Object.keys(subgraphsOf(doc)).length + 1);
  const position = layoutPosition(selected);

  const usedInputs = new Set<string>();
  const inputs: SubgraphInputDoc[] = [];
  for (const group of inboundGroups.values()) {
    const first = group.edges[0];
    const targetNode = selected.find((node) => node.id === first.target);
    const port = portFromSpec(
      targetNode ? specFor(targetNode) : undefined,
      "inputs",
      first.targetPort,
      group.kind === "control",
    );
    port.name = uniqueName(port.name, usedInputs);
    port.required = group.edges.some((edge) => {
      const node = selected.find((candidate) => candidate.id === edge.target);
      const spec = node ? specFor(node) : undefined;
      return Boolean(spec?.inputs.find((candidate) => candidate.name === edge.targetPort)?.required);
    });
    inputs.push({
      port,
      targets: group.edges.map<PortBindingDoc>((edge) => ({
        nodeId: edge.target,
        port: edge.targetPort,
        edgeId: edge.id,
      })),
    });
  }

  const usedOutputs = new Set<string>();
  const outputs: SubgraphOutputDoc[] = [];
  for (const group of outboundGroups.values()) {
    const first = group.edges[0];
    const sourceNode = selected.find((node) => node.id === first.source);
    const port = portFromSpec(
      sourceNode ? specFor(sourceNode) : undefined,
      "outputs",
      first.sourcePort,
      group.kind === "control",
    );
    port.name = uniqueName(port.name, usedOutputs);
    outputs.push({
      port,
      source: {
        nodeId: group.source,
        port: group.sourcePort,
        edgeId: first.id,
      },
    });
  }

  const compositeNode: WorkflowNodeDoc = {
    id: compositeNodeId,
    kind: COMPOSITE_NODE_KIND,
    label,
    position,
    params: {},
    enabled: true,
    subgraphId,
  };

  const nextNodes: WorkflowNodeDoc[] = [];
  let inserted = false;
  for (const node of layer.nodes) {
    if (!selectedSet.has(node.id)) {
      nextNodes.push(clone(node));
    } else if (!inserted) {
      nextNodes.push(compositeNode);
      inserted = true;
    }
  }

  const nextEdges: EdgeDoc[] = layer.edges
    .filter(
      (edge) =>
        !selectedSet.has(edge.source) &&
        !selectedSet.has(edge.target),
    )
    .map((edge) => clone(edge));

  for (const [key, group] of inboundGroups) {
    const portName = inputs.find((input) =>
      input.targets.some((binding) => binding.edgeId === group.edges[0].id),
    )?.port.name;
    if (!portName) throw new Error("missing inbound port for " + key);
    nextEdges.push(
      toDocEdge(group.source, group.sourcePort, compositeNodeId, portName, group.kind),
    );
  }
  for (const [key, group] of outboundGroups) {
    const portName = outputs.find((output) => output.source.edgeId === group.edges[0].id)?.port.name;
    if (!portName) throw new Error("missing outbound port for " + key);
    for (const edge of group.edges) {
      nextEdges.push(
        toDocEdge(compositeNodeId, portName, edge.target, edge.targetPort, edge.kind),
      );
    }
  }

  const definition: Subgraph = {
    id: subgraphId,
    version: 1,
    name: label,
    description: "Composite created from " + selected.length + " selected node(s).",
    workflow: {
      schemaVersion: SCHEMA_VERSION,
      id: "wf-" + subgraphId,
      name: label + " / inner",
      description: "",
      nodes: selected.map((node) => ({
        ...clone(node),
        position: {
          x: node.position.x - position.x,
          y: node.position.y - position.y,
        },
      })),
      edges: internal.map((edge) => clone(edge)),
      viewport: innerViewport(
        selected.map((node) => ({
          x: node.position.x - position.x,
          y: node.position.y - position.y,
        })),
      ),
      metadata: {},
    },
    inputs,
    outputs,
  };

  const next = clone(doc);
  const target = layerWorkflow(next, path);
  if (!target) throw new Error("unknown layer");
  target.nodes = nextNodes;
  target.edges = nextEdges;
  next.subgraphs = { ...subgraphsOf(doc), [subgraphId]: definition };
  next.schemaVersion = SCHEMA_VERSION;
  return { doc: next, compositeNodeId, subgraphId };
}

function definitionReferenced(doc: WorkflowDoc, id: string): boolean {
  const layers: WorkflowDoc[] = [doc];
  for (const subgraph of Object.values(subgraphsOf(doc))) {
    layers.push(subgraph.workflow);
  }
  return layers.some((layer) =>
    layer.nodes.some(
      (node) => node.kind === COMPOSITE_NODE_KIND && node.subgraphId === id,
    ),
  );
}

function uniqueNodeId(base: string, used: Set<string>): string {
  if (!used.has(base)) {
    used.add(base);
    return base;
  }
  let index = 2;
  while (used.has(base + "-" + index)) index += 1;
  const id = base + "-" + index;
  used.add(id);
  return id;
}

function uniqueEdgeId(base: string, used: Set<string>): string {
  if (!used.has(base)) {
    used.add(base);
    return base;
  }
  let index = 2;
  while (used.has(base + "#" + index)) index += 1;
  const id = base + "#" + index;
  used.add(id);
  return id;
}

/** Restore a composite node's internal graph and reconnect its boundary edges. */
export function ungroupComposite(
  doc: WorkflowDoc,
  path: LayerPath,
  compositeNodeId: string,
): UngroupResult {
  const layer = layerWorkflow(doc, path);
  if (!layer) throw new Error("unknown layer");
  const composite = layer.nodes.find((node) => node.id === compositeNodeId);
  if (!composite || composite.kind !== COMPOSITE_NODE_KIND || !composite.subgraphId) {
    throw new Error("not a composite node");
  }
  const definition = subgraphsOf(doc)[composite.subgraphId];
  if (!definition) throw new Error("unknown subgraph " + composite.subgraphId);

  const usedNodeIds = new Set(layer.nodes.map((node) => node.id));
  usedNodeIds.delete(compositeNodeId);
  const nodeIdMap = new Map<string, string>();
  const innerNodes = definition.workflow.nodes.map((node) => {
    const nextId = uniqueNodeId(node.id, usedNodeIds);
    nodeIdMap.set(node.id, nextId);
    return {
      ...clone(node),
      id: nextId,
      position: {
        x: node.position.x + composite.position.x,
        y: node.position.y + composite.position.y,
      },
    };
  });

  const usedEdgeIds = new Set(layer.edges.map((edge) => edge.id));
  const restored: EdgeDoc[] = [];
  for (const edge of definition.workflow.edges) {
    const source = nodeIdMap.get(edge.source);
    const target = nodeIdMap.get(edge.target);
    if (!source || !target) continue;
    const candidate = toDocEdge(source, edge.sourcePort, target, edge.targetPort, edge.kind);
    candidate.id = uniqueEdgeId(candidate.id, usedEdgeIds);
    restored.push(candidate);
  }

  for (const edge of layer.edges) {
    if (edge.target !== compositeNodeId) continue;
    const input = definition.inputs.find((candidate) => candidate.port.name === edge.targetPort);
    if (!input) continue;
    for (const binding of input.targets) {
      const target = nodeIdMap.get(binding.nodeId);
      if (!target) continue;
      const candidate = toDocEdge(edge.source, edge.sourcePort, target, binding.port, edge.kind);
      candidate.id = uniqueEdgeId(candidate.id, usedEdgeIds);
      restored.push(candidate);
    }
  }
  for (const edge of layer.edges) {
    if (edge.source !== compositeNodeId) continue;
    const output = definition.outputs.find((candidate) => candidate.port.name === edge.sourcePort);
    if (!output) continue;
    const source = nodeIdMap.get(output.source.nodeId);
    if (!source) continue;
    const candidate = toDocEdge(source, output.source.port, edge.target, edge.targetPort, edge.kind);
    candidate.id = uniqueEdgeId(candidate.id, usedEdgeIds);
    restored.push(candidate);
  }

  const next = clone(doc);
  const target = layerWorkflow(next, path);
  if (!target) throw new Error("unknown layer");
  const insertAt = layer.nodes.findIndex((node) => node.id === compositeNodeId);
  const remainingNodes = layer.nodes.filter((node) => node.id !== compositeNodeId).map((node) => clone(node));
  remainingNodes.splice(insertAt < 0 ? remainingNodes.length : insertAt, 0, ...innerNodes);
  target.nodes = remainingNodes;
  target.edges = [
    ...layer.edges
      .filter((edge) => edge.source !== compositeNodeId && edge.target !== compositeNodeId)
      .map((edge) => clone(edge)),
    ...restored,
  ];

  if (!definitionReferenced(next, definition.id)) {
    const remaining = { ...subgraphsOf(next) };
    delete remaining[definition.id];
    next.subgraphs = remaining;
  }
  return { doc: next, restoredNodeIds: innerNodes.map((node) => node.id) };
}

/** Copy selected nodes (and the edges between them) with fresh ids. */
export function duplicateSelection(
  doc: WorkflowDoc,
  path: LayerPath,
  selectedIds: string[],
): WorkflowDoc {
  const layer = layerWorkflow(doc, path);
  if (!layer) throw new Error("unknown layer");
  const selectedSet = new Set(selectedIds);
  const selected = layer.nodes.filter((node) => selectedSet.has(node.id));
  if (selected.length === 0) return doc;
  const used = new Set(layer.nodes.map((node) => node.id));
  const usedEdges = new Set(layer.edges.map((edge) => edge.id));
  const map = new Map<string, string>();
  for (const node of selected) map.set(node.id, uniqueNodeId(freshId("n"), used));

  // A copied composite must own its definition closure. Sharing the original
  // would make editing one copy silently rewrite the other.
  const definitionMap = new Map<string, string>();
  const copiedDefinitions: Record<string, Subgraph> = {};
  for (const node of selected) {
    if (node.kind !== COMPOSITE_NODE_KIND || !node.subgraphId) continue;
    if (definitionMap.has(node.subgraphId)) continue;
    const bundle = templateBundle(doc, node.subgraphId);
    const instance = instantiateTemplate(bundle, { x: 0, y: 0 });
    const rootId = instance.node.subgraphId;
    if (!rootId) continue;
    definitionMap.set(node.subgraphId, rootId);
    Object.assign(copiedDefinitions, instance.subgraphs);
  }

  const copies = selected.map((node) => {
    const copy = clone(node);
    copy.id = map.get(node.id)!;
    copy.position = { x: node.position.x + 36, y: node.position.y + 36 };
    if (copy.kind === COMPOSITE_NODE_KIND && copy.subgraphId) {
      copy.subgraphId = definitionMap.get(copy.subgraphId) ?? copy.subgraphId;
    }
    return copy;
  });
  const copiedEdges = layer.edges
    .filter((edge) => map.has(edge.source) && map.has(edge.target))
    .map((edge) => {
      const candidate = toDocEdge(
        map.get(edge.source)!,
        edge.sourcePort,
        map.get(edge.target)!,
        edge.targetPort,
        edge.kind,
      );
      candidate.id = uniqueEdgeId(candidate.id, usedEdges);
      return candidate;
    });
  const next = clone(doc);
  const target = layerWorkflow(next, path);
  if (!target) throw new Error("unknown layer");
  target.nodes = [...target.nodes, ...copies];
  target.edges = [...target.edges, ...copiedEdges];
  if (Object.keys(copiedDefinitions).length > 0) {
    next.subgraphs = { ...subgraphsOf(next), ...copiedDefinitions };
  }
  return next;
}

/** Copy a definition and every definition its nested composites reference. */
export function templateBundle(doc: WorkflowDoc, rootId: string): TemplateBundle {
  const definitions = subgraphsOf(doc);
  if (!definitions[rootId]) throw new Error("unknown subgraph " + rootId);
  const selected: Record<string, Subgraph> = {};
  const visit = (id: string) => {
    if (selected[id]) return;
    const definition = definitions[id];
    if (!definition) throw new Error("missing nested subgraph " + id);
    selected[id] = clone(definition);
    for (const node of definition.workflow.nodes) {
      if (node.kind === COMPOSITE_NODE_KIND && node.subgraphId) visit(node.subgraphId);
    }
  };
  visit(rootId);
  return { rootId, subgraphs: selected };
}

/** Instantiate a template with fresh definition ids so instances never share edits. */
export function instantiateTemplate(
  bundle: TemplateBundle,
  position: PositionDoc,
): InstantiatedTemplate {
  const root = bundle.subgraphs[bundle.rootId];
  if (!root) throw new Error("template root is missing");
  const definitionIds = new Map<string, string>();
  const nodeIds = new Map<string, Map<string, string>>();
  for (const id of Object.keys(bundle.subgraphs)) definitionIds.set(id, freshId("sg"));
  for (const [id, definition] of Object.entries(bundle.subgraphs)) {
    const map = new Map<string, string>();
    for (const node of definition.workflow.nodes) map.set(node.id, freshId("n"));
    nodeIds.set(id, map);
  }

  const subgraphs: Record<string, Subgraph> = {};
  for (const [id, definition] of Object.entries(bundle.subgraphs)) {
    const freshDefinitionId = definitionIds.get(id)!;
    const nodeMap = nodeIds.get(id)!;
    const nodes = definition.workflow.nodes.map((node) => ({
      ...clone(node),
      id: nodeMap.get(node.id)!,
      subgraphId:
        node.kind === COMPOSITE_NODE_KIND && node.subgraphId
          ? definitionIds.get(node.subgraphId)
          : node.subgraphId,
    }));
    const edges = definition.workflow.edges.map((edge) =>
      toDocEdge(
        nodeMap.get(edge.source) ?? edge.source,
        edge.sourcePort,
        nodeMap.get(edge.target) ?? edge.target,
        edge.targetPort,
        edge.kind,
      ),
    );
    const inputs = definition.inputs.map((input) => ({
      port: clone(input.port),
      targets: input.targets.map((binding) => ({
        nodeId: nodeMap.get(binding.nodeId) ?? binding.nodeId,
        port: binding.port,
        ...(binding.edgeId ? { edgeId: binding.edgeId } : {}),
      })),
    }));
    const outputs = definition.outputs.map((output) => ({
      port: clone(output.port),
      source: {
        nodeId: nodeMap.get(output.source.nodeId) ?? output.source.nodeId,
        port: output.source.port,
        ...(output.source.edgeId ? { edgeId: output.source.edgeId } : {}),
      },
    }));
    subgraphs[freshDefinitionId] = {
      ...clone(definition),
      id: freshDefinitionId,
      workflow: {
        ...clone(definition.workflow),
        id: freshId("wf"),
        nodes,
        edges,
      },
      inputs,
      outputs,
    };
  }

  return {
    node: {
      id: freshId("comp"),
      kind: COMPOSITE_NODE_KIND,
      label: root.name,
      position: { x: position.x, y: position.y },
      params: {},
      enabled: true,
      subgraphId: definitionIds.get(bundle.rootId)!,
    },
    subgraphs,
  };
}

export function layerViewport(doc: WorkflowDoc, path: LayerPath): ViewportDoc {
  const workflow = layerWorkflow(doc, path);
  return viewportOf(workflow?.viewport);
}
