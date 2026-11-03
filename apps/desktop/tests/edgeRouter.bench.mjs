import { performance } from "node:perf_hooks";

import { nodeObstacles, ObstacleIndex } from "../src/lib/edgeGeometry.ts";
import { clearRouteCache, routeEdge } from "../src/lib/edgeRouter.ts";

const NODE_WIDTH = 252;
const NODE_HEIGHT = 180;
const GAP_X = 80;
const GAP_Y = 60;

function makeGraph(count) {
  const columns = Math.ceil(Math.sqrt(count * 1.6));
  const nodes = [];
  for (let index = 0; index < count; index += 1) {
    const column = index % columns;
    const row = Math.floor(index / columns);
    nodes.push({
      id: "n" + index,
      position: { x: column * (NODE_WIDTH + GAP_X), y: row * (NODE_HEIGHT + GAP_Y) },
      measured: { width: NODE_WIDTH, height: NODE_HEIGHT },
    });
  }
  const edges = [];
  for (let index = 0; index < count; index += 1) {
    const column = index % columns;
    const row = Math.floor(index / columns);
    if (column + 1 < columns) {
      edges.push({ source: "n" + index, target: "n" + (index + 1) });
    }
    if (row + 2 < Math.ceil(count / columns)) {
      edges.push({ source: "n" + index, target: "n" + (index + columns * 2) });
    }
  }
  return { nodes, edges };
}

function routeAll(graph, index, nodesById) {
  const started = performance.now();
  let fallbacks = 0;
  const kinds = { smooth: 0, orthogonal: 0, fallback: 0 };
  for (const edge of graph.edges) {
    const source = nodesById.get(edge.source);
    const target = nodesById.get(edge.target);
    if (!source || !target) continue;
    const sx = source.position.x + NODE_WIDTH;
    const sy = source.position.y + NODE_HEIGHT / 2;
    const tx = target.position.x;
    const ty = target.position.y + NODE_HEIGHT / 2;
    const obstacles = index
      .queryAround(sx, sy, tx, ty)
      .filter((obstacle) => obstacle.id !== edge.source && obstacle.id !== edge.target);
    const route = routeEdge({ sx, sy, tx, ty, obstacles, lane: 0 });
    if (route.fallback) fallbacks += 1;
    kinds[route.kind] += 1;
  }
  return { ms: performance.now() - started, fallbacks, kinds };
}

for (const count of [100, 500, 1000]) {
  const graph = makeGraph(count);
  const indexStarted = performance.now();
  const obstacles = nodeObstacles(graph.nodes);
  const index = new ObstacleIndex(obstacles);
  const indexMs = performance.now() - indexStarted;
  const nodesById = new Map(graph.nodes.map((node) => [node.id, node]));

  clearRouteCache();
  const cold = routeAll(graph, index, nodesById);
  const warm = routeAll(graph, index, nodesById);

  console.log(
    [
      String(count).padStart(4) + " nodes",
      String(graph.edges.length).padStart(4) + " edges",
      "index " + indexMs.toFixed(1) + "ms",
      "cold " + cold.ms.toFixed(1) + "ms (" + (cold.ms / graph.edges.length).toFixed(3) + "ms/edge)",
      "warm " + warm.ms.toFixed(1) + "ms (" + (warm.ms / graph.edges.length).toFixed(3) + "ms/edge)",
      "fallbacks " + cold.fallbacks,
      JSON.stringify(cold.kinds),
    ].join("  "),
  );
}