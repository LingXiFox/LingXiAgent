import test from "node:test";
import assert from "node:assert/strict";

import {
  COMPOSITE_NODE_KIND,
  duplicateSelection,
  groupSelection,
  instantiateTemplate,
  nodeSpec,
  templateBundle,
  ungroupComposite,
} from "../src/lib/composite.ts";
import { newWorkflow, toDocEdge } from "../src/lib/workflow.ts";

const port = (name, dataType = "text", control = false, required = false) => ({
  name,
  label: name,
  dataType,
  required,
  control,
});

const catalog = new Map([
  [
    "test.seed",
    {
      kind: "test.seed",
      title: "Seed",
      category: "Input",
      description: "",
      inputs: [],
      outputs: [port("text")],
      params: [],
      capabilities: [],
      control: "normal",
    },
  ],
  [
    "test.upper",
    {
      kind: "test.upper",
      title: "Upper",
      category: "Text",
      description: "",
      inputs: [port("text", "text", false, true)],
      outputs: [port("text")],
      params: [],
      capabilities: [],
      control: "normal",
    },
  ],
  [
    "test.add",
    {
      kind: "test.add",
      title: "Add",
      category: "Number",
      description: "",
      inputs: [port("a", "number", false, true), port("b", "number", false, true)],
      outputs: [port("sum", "number")],
      params: [],
      capabilities: [],
      control: "normal",
    },
  ],
  [
    "test.log",
    {
      kind: "test.log",
      title: "Log",
      category: "Output",
      description: "",
      inputs: [port("value", "any", false, true)],
      outputs: [],
      params: [],
      capabilities: [],
      control: "normal",
    },
  ],
  [
    "test.gate",
    {
      kind: "test.gate",
      title: "Gate",
      category: "Control",
      description: "",
      inputs: [port("start", "any", true, true), port("next", "any", true, false)],
      outputs: [port("continue", "any", true), port("exit", "any", true)],
      params: [],
      capabilities: [],
      control: "loop_gate",
    },
  ],
  [
    "test.condition",
    {
      kind: "test.condition",
      title: "Condition",
      category: "Control",
      description: "",
      inputs: [port("payload", "any", false, true), port("condition", "boolean", false, true)],
      outputs: [port("true", "any", true), port("false", "any", true)],
      params: [],
      capabilities: [],
      control: "branch",
    },
  ],
]);

function node(id, kind, x, y, extra = {}) {
  return { id, kind, position: { x, y }, params: {}, enabled: true, ...extra };
}

function docs() {
  const doc = newWorkflow("wrap");
  doc.nodes = [
    node("seed", "test.seed", 0, 0),
    node("upper", "test.upper", 300, 0),
    node("log", "test.log", 600, 0),
  ];
  doc.edges = [
    toDocEdge("seed", "text", "upper", "text"),
    toDocEdge("upper", "text", "log", "value"),
  ];
  return doc;
}

const demoCatalog = new Map([
  ["core.number_input", { kind: "core.number_input", title: "Number", category: "Input", description: "", inputs: [], outputs: [port("number", "number")], params: [], capabilities: [], control: "normal" }],
  ["core.loop_gate", { kind: "core.loop_gate", title: "Loop Gate", category: "Control", description: "", inputs: [port("start", "any", true, true), port("next", "any", true)], outputs: [port("continue", "any", true), port("exit", "any", true)], params: [], capabilities: [], control: "loop_gate" }],
  ["core.counter", { kind: "core.counter", title: "Counter", category: "Number", description: "", inputs: [port("value", "number", false, true)], outputs: [port("number", "number"), port("done", "boolean")], params: [], capabilities: [], control: "normal" }],
  ["core.condition", { kind: "core.condition", title: "Condition", category: "Control", description: "", inputs: [port("payload", "any", false, true), port("condition", "boolean", false, true)], outputs: [port("true", "any", true), port("false", "any", true)], params: [], capabilities: [], control: "branch" }],
  ["core.log", { kind: "core.log", title: "Log", category: "Output", description: "", inputs: [port("value", "any", false, true)], outputs: [], params: [], capabilities: [], control: "normal" }],
]);

function demoDoc() {
  const doc = newWorkflow("Counter loop");
  doc.nodes = [
    node("demo-seed", "core.number_input", 20, 160, { params: { value: 0 } }),
    node("demo-gate", "core.loop_gate", 300, 160, { params: { maxIterations: 10, timeoutMs: 60000 } }),
    node("demo-counter", "core.counter", 580, 160, { params: { start: 0, step: 1, threshold: 3 } }),
    node("demo-condition", "core.condition", 860, 160),
    node("demo-log", "core.log", 1140, 300, { params: { prefix: "count: " } }),
  ];
  doc.edges = [
    toDocEdge("demo-seed", "number", "demo-gate", "start", "control"),
    toDocEdge("demo-gate", "continue", "demo-counter", "value", "control"),
    toDocEdge("demo-counter", "number", "demo-condition", "payload"),
    toDocEdge("demo-counter", "done", "demo-condition", "condition"),
    toDocEdge("demo-condition", "false", "demo-gate", "next", "control"),
    toDocEdge("demo-condition", "true", "demo-gate", "stop", "control"),
    toDocEdge("demo-gate", "exit", "demo-log", "value", "control"),
  ];
  doc.viewport = { x: 20, y: 140, zoom: 0.8 };
  return doc;
}

const specFor = (node) => nodeSpec(node, catalog, {});
const demoSpecFor = (node) => nodeSpec(node, demoCatalog, {});

test("groupSelection wraps a node and ungroup restores the original graph", () => {
  const doc = docs();
  const grouped = groupSelection(doc, [], ["upper"], specFor, "Upper box");
  assert.equal(grouped.doc.nodes.length, 3);
  assert.equal(grouped.doc.nodes[1].kind, COMPOSITE_NODE_KIND);
  assert.equal(grouped.doc.nodes[1].subgraphId, grouped.subgraphId);
  const definition = grouped.doc.subgraphs[grouped.subgraphId];
  assert.equal(definition.name, "Upper box");
  assert.equal(definition.workflow.nodes.length, 1);
  assert.equal(definition.inputs.length, 1);
  assert.equal(definition.outputs.length, 1);
  assert.equal(definition.inputs[0].port.name, "text");
  assert.equal(definition.outputs[0].port.name, "text");
  assert.equal(grouped.doc.edges.length, 2);

  const restored = ungroupComposite(grouped.doc, [], grouped.compositeNodeId);
  assert.deepEqual(
    restored.doc.nodes.map((item) => item.id),
    ["seed", "upper", "log"],
  );
  assert.equal(restored.doc.subgraphs[grouped.subgraphId], undefined);
  assert.deepEqual(
    restored.doc.edges.map((edge) => edge.id).sort(),
    docs().edges.map((edge) => edge.id).sort(),
  );
});

test("grouping two selected nodes keeps the internal edge inside the definition", () => {
  const doc = docs();
  const grouped = groupSelection(doc, [], ["seed", "upper"], specFor, "Pair");
  const definition = grouped.doc.subgraphs[grouped.subgraphId];
  assert.equal(definition.workflow.nodes.length, 2);
  assert.equal(definition.workflow.edges.length, 1);
  assert.equal(definition.inputs.length, 0);
  assert.equal(definition.outputs.length, 1);
  assert.equal(grouped.doc.edges.length, 1);
  assert.equal(grouped.doc.edges[0].source, grouped.compositeNodeId);
});

test("multi-input and multi-output boundaries become distinct composite ports", () => {
  const doc = newWorkflow("ports");
  doc.nodes = [
    node("left", "test.seed", 0, 0),
    node("right", "test.seed", 0, 120),
    node("add", "test.add", 300, 40),
    node("log", "test.log", 600, 40),
  ];
  doc.edges = [
    toDocEdge("left", "text", "add", "a"),
    toDocEdge("right", "text", "add", "b"),
    toDocEdge("add", "sum", "log", "value"),
  ];
  const grouped = groupSelection(doc, [], ["add"], specFor, "Adder");
  const definition = grouped.doc.subgraphs[grouped.subgraphId];
  assert.equal(definition.inputs.length, 2);
  assert.deepEqual(definition.inputs.map((input) => input.port.name).sort(), ["a", "b"]);
  assert.equal(definition.outputs.length, 1);
  assert.equal(grouped.doc.edges.filter((edge) => edge.target === grouped.compositeNodeId).length, 2);
});

test("control ports keep their control flag through group and ungroup", () => {
  const doc = newWorkflow("control");
  doc.nodes = [
    node("seed", "test.seed", -300, 0),
    node("gate", "test.gate", 0, 0, { params: { maxIterations: 3 } }),
    node("condition", "test.condition", 300, 0),
    node("log", "test.log", 600, 0),
  ];
  doc.edges = [
    toDocEdge("seed", "text", "gate", "start", "control"),
    toDocEdge("gate", "continue", "condition", "payload", "control"),
    toDocEdge("condition", "false", "gate", "next", "control"),
    toDocEdge("gate", "exit", "log", "value", "control"),
  ];
  const grouped = groupSelection(doc, [], ["gate", "condition"], specFor, "Loop");
  const definition = grouped.doc.subgraphs[grouped.subgraphId];
  assert.equal(definition.inputs.length, 1);
  assert.equal(definition.outputs.length, 1);
  assert.equal(definition.inputs[0].port.control, true);
  assert.equal(definition.outputs[0].port.control, true);
  const restored = ungroupComposite(grouped.doc, [], grouped.compositeNodeId);
  assert.equal(restored.doc.nodes.length, 4);
  assert.equal(restored.doc.edges.length, 4);
});

test("duplicateSelection copies only internal edges and gives fresh ids", () => {
  const doc = docs();
  const copied = duplicateSelection(doc, [], ["seed", "upper"]);
  assert.equal(copied.nodes.length, 5);
  const newIds = copied.nodes.slice(3).map((item) => item.id);
  assert.equal(new Set(copied.nodes.map((item) => item.id)).size, 5);
  assert.ok(newIds.every((id) => !doc.nodes.some((item) => item.id === id)));
  assert.equal(copied.edges.length, 3);
  assert.ok(copied.edges[2].source === newIds[0]);
  assert.ok(copied.edges[2].target === newIds[1]);
});

test("template instantiation remaps every definition and inner node id", () => {
  const doc = newWorkflow("nested");
  doc.nodes = [node("seed", "test.seed", 0, 0)];
  doc.subgraphs = {
    "sg-inner": {
      id: "sg-inner",
      version: 1,
      name: "Inner",
      workflow: {
        ...newWorkflow("inner"),
        nodes: [node("inner-node", "test.upper", 0, 0)],
        edges: [],
      },
      inputs: [
        { port: port("text", "text", false, true), targets: [{ nodeId: "inner-node", port: "text" }] },
      ],
      outputs: [
        { port: port("text"), source: { nodeId: "inner-node", port: "text" } },
      ],
    },
    "sg-outer": {
      id: "sg-outer",
      version: 1,
      name: "Outer",
      workflow: {
        ...newWorkflow("outer"),
        nodes: [node("nested", COMPOSITE_NODE_KIND, 0, 0, { subgraphId: "sg-inner" })],
        edges: [],
      },
      inputs: [],
      outputs: [],
    },
  };
  const bundle = templateBundle(doc, "sg-outer");
  assert.deepEqual(Object.keys(bundle.subgraphs).sort(), ["sg-inner", "sg-outer"]);
  const first = instantiateTemplate(bundle, { x: 10, y: 20 });
  const second = instantiateTemplate(bundle, { x: 30, y: 40 });
  assert.notEqual(first.node.subgraphId, "sg-outer");
  assert.notEqual(second.node.subgraphId, first.node.subgraphId);
  const firstOuter = first.subgraphs[first.node.subgraphId];
  const firstInnerId = firstOuter.workflow.nodes[0].subgraphId;
  assert.ok(firstInnerId);
  assert.notEqual(firstInnerId, "sg-inner");
  assert.ok(first.subgraphs[firstInnerId]);
  assert.notEqual(
    first.subgraphs[firstInnerId].workflow.nodes[0].id,
    second.subgraphs[second.node.subgraphId].workflow.nodes[0].id,
  );
});
test("wrapping and ungrouping the full Phase 1.1 counter loop preserves its graph", () => {
  const doc = demoDoc();
  const ids = ["demo-gate", "demo-counter", "demo-condition", "demo-log"];
  const grouped = groupSelection(doc, [], ids, demoSpecFor, "Counter loop");
  assert.equal(grouped.doc.nodes.length, 2);
  assert.equal(grouped.doc.edges.length, 1);
  const definition = grouped.doc.subgraphs[grouped.subgraphId];
  assert.equal(definition.workflow.nodes.length, 4);
  assert.equal(definition.workflow.edges.length, 6);
  assert.equal(definition.inputs.length, 1);
  assert.equal(definition.inputs[0].port.control, true);
  assert.equal(definition.outputs.length, 0);
  assert.equal(grouped.doc.edges[0].source, "demo-seed");
  assert.equal(grouped.doc.edges[0].target, grouped.compositeNodeId);

  const reloaded = JSON.parse(JSON.stringify(grouped.doc));
  assert.deepEqual(reloaded, grouped.doc);
  const instance = reloaded.nodes.find((item) => item.id === grouped.compositeNodeId);
  assert.equal(instance.subgraphId, grouped.subgraphId);

  const restored = ungroupComposite(reloaded, [], grouped.compositeNodeId);
  assert.deepEqual(restored.doc.nodes.map((item) => item.id), doc.nodes.map((item) => item.id));
  assert.deepEqual(
    restored.doc.edges.map((edge) => edge.id).sort(),
    doc.edges.map((edge) => edge.id).sort(),
  );
  assert.deepEqual(restored.doc.subgraphs, {});
  assert.deepEqual(
    restored.doc.nodes.find((item) => item.id === "demo-counter").params,
    { start: 0, step: 1, threshold: 3 },
  );
});

test("duplicating a composite gives it an independent definition closure", () => {
  const doc = demoDoc();
  const grouped = groupSelection(
    doc,
    [],
    ["demo-gate", "demo-counter", "demo-condition", "demo-log"],
    demoSpecFor,
    "Counter loop",
  );
  const copiedDoc = duplicateSelection(grouped.doc, [], [grouped.compositeNodeId]);
  assert.equal(copiedDoc.nodes.length, 3);
  const copied = copiedDoc.nodes.find(
    (item) => item.kind === COMPOSITE_NODE_KIND && item.id !== grouped.compositeNodeId,
  );
  assert.ok(copied);
  assert.notEqual(copied.subgraphId, grouped.subgraphId);
  assert.ok(copiedDoc.subgraphs[copied.subgraphId]);
  assert.equal(copiedDoc.subgraphs[copied.subgraphId].workflow.nodes.length, 4);
  assert.notEqual(
    copiedDoc.subgraphs[copied.subgraphId].workflow.nodes[0].id,
    grouped.doc.subgraphs[grouped.subgraphId].workflow.nodes[0].id,
  );

  const copiedCounter = copiedDoc.subgraphs[copied.subgraphId].workflow.nodes.find(
    (item) => item.kind === "core.counter",
  );
  copiedCounter.params.threshold = 99;
  const originalCounter = grouped.doc.subgraphs[grouped.subgraphId].workflow.nodes.find(
    (item) => item.kind === "core.counter",
  );
  assert.equal(originalCounter.params.threshold, 3);
});
