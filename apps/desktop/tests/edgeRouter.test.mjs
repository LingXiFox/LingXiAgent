import assert from "node:assert/strict";
import test from "node:test";

import { segmentHitsRect } from "../src/lib/edgeGeometry.ts";
import {
  clearRouteCache,
  laneForEdge,
  pointsToRoundedPath,
  routeEdge,
} from "../src/lib/edgeRouter.ts";

function obstacle(id, x, y, width, height) {
  return { id, x, y, width, height };
}

function obstacleContains(rect, point) {
  return (
    point.x > rect.x &&
    point.x < rect.x + rect.width &&
    point.y > rect.y &&
    point.y < rect.y + rect.height
  );
}

function assertClear(points, obstacles, label) {
  for (let i = 1; i < points.length; i += 1) {
    for (const rect of obstacles) {
      assert.equal(
        segmentHitsRect(points[i - 1], points[i], rect),
        false,
        label + ": segment " + i + " crosses " + rect.id,
      );
    }
  }
}

// Measured from the real Counter -> Condition -> Loop Gate demo at 0.693878
// zoom. Node rectangles are in flow coordinates; handle points are 4px outside
// the node edges. The seed and Loop Gate are only 28px apart, i.e. the two
// handle points are 20px apart, which is exactly the old two-stub width.
const DEMO_OBSTACLES = [
  obstacle("demo-seed", 20, 160, 252, 151),
  obstacle("demo-gate", 300, 160, 252, 247),
  obstacle("demo-counter", 580, 160, 252, 271),
  obstacle("demo-condition", 860, 160, 252, 113),
  obstacle("demo-log", 1140, 300, 252, 151),
];

const DEMO_EDGES = [
  {
    id: "demo-seed:number->demo-gate:start",
    source: "demo-seed",
    target: "demo-gate",
    sourceHandle: "number",
    targetHandle: "start",
    sx: 276,
    sy: 229,
    tx: 296,
    ty: 229,
  },
  {
    id: "demo-condition:false->demo-gate:next",
    source: "demo-condition",
    target: "demo-gate",
    sourceHandle: "false",
    targetHandle: "next",
    sx: 1116,
    sy: 253,
    tx: 296,
    ty: 253,
  },
  {
    id: "demo-condition:true->demo-gate:stop",
    source: "demo-condition",
    target: "demo-gate",
    sourceHandle: "true",
    targetHandle: "stop",
    sx: 1116,
    sy: 229,
    tx: 296,
    ty: 277,
  },
];

test.beforeEach(() => clearRouteCache());

test("adjacent forward ports get a smooth path", () => {
  const route = routeEdge({ sx: 0, sy: 100, tx: 300, ty: 100, obstacles: [] });
  assert.equal(route.kind, "smooth");
  assert.equal(route.fallback, false);
  assert.match(route.path, / C /);
  assertClear(route.points, [], "smooth");
});

test("a node on the direct corridor forces an orthogonal detour", () => {
  const obstacles = [obstacle("blocker", 200, 30, 120, 140)];
  const route = routeEdge({ sx: 0, sy: 100, tx: 500, ty: 100, obstacles });
  assert.equal(route.kind, "orthogonal");
  assert.equal(route.fallback, false);
  assert.ok(route.points.length >= 4);
  assertClear(route.points, obstacles, "detour");
  assert.match(route.path, / Q /);
});

test("reverse links leave the node group instead of cutting through it", () => {
  const obstacles = [obstacle("left", 380, 40, 120, 120), obstacle("right", 620, 40, 120, 120)];
  const route = routeEdge({ sx: 860, sy: 100, tx: 100, ty: 100, obstacles });
  assert.equal(route.kind, "orthogonal");
  assertClear(route.points, obstacles, "reverse");
  const ys = route.points.map((point) => point.y);
  assert.ok(Math.min(...ys) < 40 || Math.max(...ys) > 160, "route should use an outside corridor");
});

test("multiple edges to different ports get different lanes", () => {
  const a = laneForEdge("a", "true", "stop");
  const b = laneForEdge("b", "false", "next");
  assert.notEqual(a, b);
});

test("rounded orthogonal paths contain arcs and no duplicate points", () => {
  const path = pointsToRoundedPath([
    { x: 0, y: 0 },
    { x: 100, y: 0 },
    { x: 100, y: 100 },
    { x: 200, y: 100 },
  ]);
  assert.match(path, /^M 0 0 L 91\.00 0\.00 Q 100 0 100\.00 9\.00/);
  assert.match(path, / Q /);
});

test("a long reverse route around several rows stays clear", () => {
  const obstacles = [
    obstacle("a", 180, 40, 100, 100),
    obstacle("b", 360, 200, 100, 100),
    obstacle("c", 540, 40, 100, 100),
  ];
  const route = routeEdge({ sx: 780, sy: 140, tx: 80, ty: 140, obstacles });
  assertClear(route.points, obstacles, "multi-row reverse");
  assert.equal(route.fallback, false);
});

test("parallel routes with different lanes separate their trunks", () => {
  const obstacles = [obstacle("blocker", 200, 40, 120, 120)];
  const positive = routeEdge({ sx: 0, sy: 100, tx: 500, ty: 100, obstacles, lane: 8 });
  const negative = routeEdge({ sx: 0, sy: 100, tx: 500, ty: 100, obstacles, lane: -8 });
  assert.notDeepEqual(positive.points, negative.points);
  assertClear(positive.points, obstacles, "positive lane");
  assertClear(negative.points, obstacles, "negative lane");
});

test("random layouts never cross an unrelated node", () => {
  let seed = 7;
  const random = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 0x100000000;
  };
  let valid = 0;
  let attempts = 0;
  while (valid < 60 && attempts < 500) {
    attempts += 1;
    const obstacles = [];
    const count = 1 + Math.floor(random() * 6);
    for (let index = 0; index < count; index += 1) {
      obstacles.push(
        obstacle(
          "n" + index,
          80 + random() * 700,
          40 + random() * 400,
          80 + random() * 120,
          60 + random() * 120,
        ),
      );
    }
    const sx = 10 + random() * 760;
    const sy = 40 + random() * 400;
    const tx = 10 + random() * 760;
    const ty = 40 + random() * 400;
    if (obstacles.some((rect) => obstacleContains(rect, { x: sx, y: sy }))) continue;
    if (obstacles.some((rect) => obstacleContains(rect, { x: tx, y: ty }))) continue;

    valid += 1;
    const route = routeEdge({ sx, sy, tx, ty, obstacles, lane: Math.floor(random() * 9) - 4 });
    assert.equal(route.fallback, false, "random " + valid + " fell back");
    assert.equal(route.blocked, 0, "random " + valid + " crosses a node");
    assertClear(route.points, obstacles, "random " + valid);
    assert.ok(route.path.length > 0);
  }
  assert.ok(valid >= 60, "expected 60 layouts with free endpoints, got " + valid);
});

test("an endpoint trapped inside an obstacle is an explicit fallback", () => {
  const obstacles = [obstacle("wall", -20, 20, 300, 160)];
  const route = routeEdge({ sx: 120, sy: 100, tx: 1000, ty: 100, obstacles });
  assert.equal(route.fallback, true);
  assert.equal(route.kind, "fallback");
  assert.ok(route.blocked > 0, "fallback should report the crossing it cannot avoid");
  assert.ok(route.path.length > 0, "fallback must still render an edge");
});
test("real demo control edges to the Loop Gate never fall back", () => {
  for (const edge of DEMO_EDGES) {
    const obstacles = DEMO_OBSTACLES.filter(
      (rect) => rect.id !== edge.source && rect.id !== edge.target,
    );
    const lane = laneForEdge(edge.id, edge.sourceHandle, edge.targetHandle);
    const route = routeEdge({
      sx: edge.sx,
      sy: edge.sy,
      tx: edge.tx,
      ty: edge.ty,
      obstacles,
      lane,
    });
    assert.equal(route.fallback, false, edge.id + " fell back");
    assert.equal(route.kind, "orthogonal", edge.id + " should use the escape lane");
    assert.equal(route.blocked, 0, edge.id + " crosses a node");
    assert.equal(route.clearance, 0, edge.id + " violates the safety margin");
    assertClear(route.points, DEMO_OBSTACLES, edge.id);
  }
});

test("the 28px seed/gate gap keeps both escape stubs inside the gap", () => {
  const edge = DEMO_EDGES[0];
  const obstacles = DEMO_OBSTACLES.filter(
    (rect) => rect.id !== edge.source && rect.id !== edge.target,
  );
  const route = routeEdge({
    sx: edge.sx,
    sy: edge.sy,
    tx: edge.tx,
    ty: edge.ty,
    obstacles,
    lane: laneForEdge(edge.id, edge.sourceHandle, edge.targetHandle),
  });
  const xs = route.points.map((point) => point.x);
  assert.equal(Math.min(...xs), 276);
  assert.equal(Math.max(...xs), 296);
  assert.ok(
    xs.every((x, index) => index === 0 || x >= xs[index - 1]),
    "the escape must not backtrack through the 28px gap",
  );
});

test("a gap narrower than two stubs stays monotonic instead of overshooting", () => {
  const route = routeEdge({ sx: 276, sy: 229, tx: 286, ty: 229, obstacles: [] });
  const xs = route.points.map((point) => point.x);
  assert.equal(route.fallback, false);
  assert.ok(
    xs.every((x, index) => index === 0 || x >= xs[index - 1]),
    "clamped escape stubs must not cross each other",
  );
});

test("a safety-margin near miss is not treated as a node collision", () => {
  // The direct corridor passes 10px below this node: inside CLEARANCE (14px)
  // but outside the actual rectangle. It must remain a valid, non-fallback route.
  const obstacles = [obstacle("near", 180, 30, 100, 60)];
  const route = routeEdge({ sx: 0, sy: 100, tx: 400, ty: 100, obstacles });
  assert.equal(route.blocked, 0);
  assert.equal(route.fallback, false);
  assert.ok(route.clearance > 0 || route.kind === "orthogonal");
  assertClear(route.points, obstacles, "near miss");
});
