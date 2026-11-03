import {
  inflateRect,
  pointInsideRect,
  segmentHitsAny,
  segmentHitsRect,
  type NodeObstacle,
  type Point,
} from "./edgeGeometry.ts";

const STUB = 10;
const CORNER_RADIUS = 9;
const CLEARANCE = 14;
const TURN_COST = 26;
const LANE_STEP = 4;
const CACHE_LIMIT = 4000;
const A_STAR_OBSTACLE_LIMIT = 20;
const A_STAR_EXPANSION_LIMIT = 12000;

export type RouteKind = "smooth" | "orthogonal" | "fallback";

export interface RouteRequest {
  sx: number;
  sy: number;
  tx: number;
  ty: number;
  obstacles: readonly NodeObstacle[];
  lane?: number;
}

export interface RouteResult {
  path: string;
  points: Point[];
  kind: RouteKind;
  fallback: boolean;
  /** Segments that cross an actual node rectangle. */
  blocked: number;
  /** Segments that only enter the safety margin around a node. */
  clearance: number;
}

interface Candidate {
  points: Point[];
  score: number;
  blocked: number;
  clearance: number;
}

const routeCache = new Map<string, RouteResult>();

export function clearRouteCache(): void {
  routeCache.clear();
}

/** Deterministic lane offset so parallel-ish edges do not share one trunk. */
export function laneForEdge(
  edgeId: string,
  sourceHandle: string | null | undefined,
  targetHandle: string | null | undefined,
): number {
  const seed = (text: string | null | undefined): number => {
    let value = 0;
    for (let i = 0; i < (text ?? "").length; i += 1) {
      value = (value * 31 + text!.charCodeAt(i)) >>> 0;
    }
    return value;
  };
  const sourceSeed = seed(sourceHandle);
  const targetSeed = seed(targetHandle);
  // Port names, not the edge id, decide the lane: parallel edges between the
  // same node pair but different ports must never share one trunk.
  const slot = ((sourceSeed * 7 + targetSeed * 13 + edgeId.length) >>> 0) % 9;
  return (slot - 4) * LANE_STEP;
}

function round(value: number): number {
  return Math.round(value * 2) / 2;
}

function routeCacheKey(request: RouteRequest): string {
  const lane = request.lane ?? 0;
  const parts = request.obstacles.map(
    (obstacle) =>
      obstacle.id +
      ":" +
      round(obstacle.x) +
      "," +
      round(obstacle.y) +
      "," +
      round(obstacle.width) +
      "," +
      round(obstacle.height),
  );
  return [
    round(request.sx),
    round(request.sy),
    round(request.tx),
    round(request.ty),
    lane,
    parts.join("|"),
  ].join(";");
}

function normalizePoints(points: readonly Point[]): Point[] {
  const deduped: Point[] = [];
  for (const point of points) {
    const last = deduped[deduped.length - 1];
    if (last && Math.abs(last.x - point.x) < 0.01 && Math.abs(last.y - point.y) < 0.01) {
      continue;
    }
    deduped.push({ x: point.x, y: point.y });
  }

  if (deduped.length < 3) return deduped;
  const result: Point[] = [deduped[0]];
  for (let i = 1; i < deduped.length - 1; i += 1) {
    const previous = result[result.length - 1];
    const current = deduped[i];
    const next = deduped[i + 1];
    const cross =
      (current.x - previous.x) * (next.y - current.y) -
      (current.y - previous.y) * (next.x - current.x);
    if (Math.abs(cross) > 1e-6) result.push(current);
  }
  result.push(deduped[deduped.length - 1]);
  return result;
}

export function pointsToRoundedPath(points: readonly Point[], radius = CORNER_RADIUS): string {
  const clean = normalizePoints(points);
  if (clean.length === 0) return "";
  if (clean.length === 1) return "M " + clean[0].x + " " + clean[0].y;
  if (clean.length === 2) {
    return "M " + clean[0].x + " " + clean[0].y + " L " + clean[1].x + " " + clean[1].y;
  }

  const chunks: string[] = ["M " + clean[0].x + " " + clean[0].y];
  for (let i = 1; i < clean.length - 1; i += 1) {
    const previous = clean[i - 1];
    const current = clean[i];
    const next = clean[i + 1];
    const inLength = Math.hypot(current.x - previous.x, current.y - previous.y);
    const outLength = Math.hypot(next.x - current.x, next.y - current.y);
    const corner = Math.min(radius, inLength / 2, outLength / 2);
    if (corner < 0.5) {
      chunks.push("L " + current.x + " " + current.y);
      continue;
    }
    const inX = current.x + ((previous.x - current.x) / inLength) * corner;
    const inY = current.y + ((previous.y - current.y) / inLength) * corner;
    const outX = current.x + ((next.x - current.x) / outLength) * corner;
    const outY = current.y + ((next.y - current.y) / outLength) * corner;
    chunks.push("L " + inX.toFixed(2) + " " + inY.toFixed(2));
    chunks.push("Q " + current.x + " " + current.y + " " + outX.toFixed(2) + " " + outY.toFixed(2));
  }
  const last = clean[clean.length - 1];
  chunks.push("L " + last.x + " " + last.y);
  return chunks.join(" ");
}

function cubicControlPoints(source: Point, target: Point): [Point, Point] {
  const dx = target.x - source.x;
  return [
    { x: source.x + dx * 0.5, y: source.y },
    { x: target.x - dx * 0.5, y: target.y },
  ];
}

function cubicPoint(source: Point, control1: Point, control2: Point, target: Point, t: number): Point {
  const mt = 1 - t;
  const a = mt * mt * mt;
  const b = 3 * mt * mt * t;
  const c = 3 * mt * t * t;
  const d = t * t * t;
  return {
    x: a * source.x + b * control1.x + c * control2.x + d * target.x,
    y: a * source.y + b * control1.y + c * control2.y + d * target.y,
  };
}

function cubicSamples(source: Point, target: Point, steps = 18): Point[] {
  const [control1, control2] = cubicControlPoints(source, target);
  const points: Point[] = [];
  for (let i = 0; i <= steps; i += 1) {
    points.push(cubicPoint(source, control1, control2, target, i / steps));
  }
  return points;
}

function cubicPath(source: Point, target: Point): string {
  const [control1, control2] = cubicControlPoints(source, target);
  return (
    "M " +
    source.x +
    " " +
    source.y +
    " C " +
    control1.x.toFixed(2) +
    " " +
    control1.y +
    " " +
    control2.x.toFixed(2) +
    " " +
    control2.y +
    " " +
    target.x +
    " " +
    target.y
  );
}

/**
 * A port escape must leave the node before the router turns. Adjacent nodes can
 * be closer than two full stubs (the demo has a 28px node gap), so the stub is
 * clamped to half the available gap instead of overshooting into the peer.
 */
function escapeStub(sourceX: number, targetX: number): number {
  const gap = targetX - sourceX;
  if (gap <= 0) return STUB;
  return Math.min(STUB, gap / 2);
}

function evaluate(points: readonly Point[], obstacles: readonly NodeObstacle[]): {
  length: number;
  bends: number;
  blocked: number;
  clearance: number;
} {
  const clean = normalizePoints(points);
  let length = 0;
  let bends = 0;
  let blocked = 0;
  let clearance = 0;
  let previousDirection = 0;
  for (let i = 1; i < clean.length; i += 1) {
    const a = clean[i - 1];
    const b = clean[i];
    length += Math.abs(b.x - a.x) + Math.abs(b.y - a.y);
    const direction = Math.abs(b.x - a.x) >= Math.abs(b.y - a.y) ? 1 : 2;
    if (previousDirection !== 0 && direction !== previousDirection) bends += 1;
    previousDirection = direction;
    let hit = false;
    let nearMiss = false;
    for (const obstacle of obstacles) {
      if (segmentHitsRect(a, b, obstacle)) {
        hit = true;
        break;
      }
      if (segmentHitsRect(a, b, inflateRect(obstacle, CLEARANCE))) {
        nearMiss = true;
      }
    }
    if (hit) blocked += 1;
    else if (nearMiss) clearance += 1;
  }
  return { length, bends, blocked, clearance };
}

function candidate(points: Point[], obstacles: readonly NodeObstacle[], bias = 0): Candidate {
  const clean = normalizePoints(points);
  const metrics = evaluate(clean, obstacles);
  return {
    points: clean,
    blocked: metrics.blocked,
    clearance: metrics.clearance,
    score: metrics.length + metrics.bends * TURN_COST + bias,
  };
}

function nearestObstacles(obstacles: readonly NodeObstacle[], center: Point, limit: number): NodeObstacle[] {
  if (obstacles.length <= limit) return [...obstacles];
  return [...obstacles]
    .sort((a, b) => {
      const da = Math.hypot(a.x + a.width / 2 - center.x, a.y + a.height / 2 - center.y);
      const db = Math.hypot(b.x + b.width / 2 - center.x, b.y + b.height / 2 - center.y);
      return da - db;
    })
    .slice(0, limit);
}

function uniqueCoordinates(values: readonly number[]): { values: number[]; indexes: Map<number, number> } {
  const byKey = new Map<string, number>();
  for (const value of values) {
    if (!Number.isFinite(value)) continue;
    const key = value.toFixed(3);
    if (!byKey.has(key)) byKey.set(key, value);
  }
  const sorted = [...byKey.values()].sort((a, b) => a - b);
  const indexes = new Map<number, number>();
  sorted.forEach((value, index) => indexes.set(value, index));
  return { values: sorted, indexes };
}

function gridRoute(source: Point, target: Point, obstacles: readonly NodeObstacle[]): Point[] | null {
  const relevant = nearestObstacles(obstacles, {
    x: (source.x + target.x) / 2,
    y: (source.y + target.y) / 2,
  }, A_STAR_OBSTACLE_LIMIT);

  const xValues = [source.x, target.x, (source.x + target.x) / 2];
  const yValues = [source.y, target.y, (source.y + target.y) / 2];
  for (const obstacle of relevant) {
    xValues.push(obstacle.x - CLEARANCE, obstacle.x + obstacle.width + CLEARANCE);
    yValues.push(obstacle.y - CLEARANCE, obstacle.y + obstacle.height + CLEARANCE);
  }
  xValues.push(Math.min(...xValues) - 80, Math.max(...xValues) + 80);
  yValues.push(Math.min(...yValues) - 80, Math.max(...yValues) + 80);

  const xAxis = uniqueCoordinates(xValues);
  const yAxis = uniqueCoordinates(yValues);
  const xs = xAxis.values;
  const ys = yAxis.values;
  const startX = xAxis.indexes.get(source.x);
  const startY = yAxis.indexes.get(source.y);
  const endX = xAxis.indexes.get(target.x);
  const endY = yAxis.indexes.get(target.y);
  if (startX === undefined || startY === undefined || endX === undefined || endY === undefined) {
    return null;
  }

  const pointAt = (xi: number, yi: number): Point => ({ x: xs[xi], y: ys[yi] });
  const nodeCount = xs.length * ys.length;
  const startNode = startX * ys.length + startY;
  const endNode = endX * ys.length + endY;
  if (startNode === endNode) return [source];

  const pointBlocked = (point: Point): boolean =>
    relevant.some((obstacle) => pointInsideRect(point, obstacle));

  const stateCount = nodeCount * 3;
  const g = new Float64Array(stateCount);
  g.fill(Infinity);
  const previous = new Int32Array(stateCount);
  previous.fill(-1);
  const closed = new Uint8Array(stateCount);

  interface HeapEntry {
    key: number;
    priority: number;
  }
  const heap: HeapEntry[] = [];
  const push = (entry: HeapEntry): void => {
    heap.push(entry);
    let index = heap.length - 1;
    while (index > 0) {
      const parent = Math.floor((index - 1) / 2);
      if (heap[parent].priority <= heap[index].priority) break;
      [heap[parent], heap[index]] = [heap[index], heap[parent]];
      index = parent;
    }
  };
  const pop = (): HeapEntry | undefined => {
    if (heap.length === 0) return undefined;
    const top = heap[0];
    const last = heap.pop() as HeapEntry;
    if (heap.length > 0) {
      heap[0] = last;
      let index = 0;
      for (;;) {
        const left = index * 2 + 1;
        const right = left + 1;
        let smallest = index;
        if (left < heap.length && heap[left].priority < heap[smallest].priority) smallest = left;
        if (right < heap.length && heap[right].priority < heap[smallest].priority) smallest = right;
        if (smallest === index) break;
        [heap[smallest], heap[index]] = [heap[index], heap[smallest]];
        index = smallest;
      }
    }
    return top;
  };

  const startKey = startNode * 3;
  g[startKey] = 0;
  push({ key: startKey, priority: Math.abs(source.x - target.x) + Math.abs(source.y - target.y) });

  let expansions = 0;
  let endKey = -1;
  while (heap.length > 0 && expansions < A_STAR_EXPANSION_LIMIT) {
    const entry = pop();
    if (!entry) break;
    if (closed[entry.key]) continue;
    closed[entry.key] = 1;
    expansions += 1;

    const node = Math.floor(entry.key / 3);
    const direction = entry.key % 3;
    if (node === endNode) {
      endKey = entry.key;
      break;
    }

    const xi = Math.floor(node / ys.length);
    const yi = node % ys.length;
    const current = pointAt(xi, yi);
    const neighbors: Array<{ x: number; y: number; moveDirection: number }> = [];
    if (xi > 0) neighbors.push({ x: xi - 1, y: yi, moveDirection: 1 });
    if (xi + 1 < xs.length) neighbors.push({ x: xi + 1, y: yi, moveDirection: 1 });
    if (yi > 0) neighbors.push({ x: xi, y: yi - 1, moveDirection: 2 });
    if (yi + 1 < ys.length) neighbors.push({ x: xi, y: yi + 1, moveDirection: 2 });

    for (const neighbor of neighbors) {
      const nextNode = neighbor.x * ys.length + neighbor.y;
      const nextPoint = pointAt(neighbor.x, neighbor.y);
      if (nextNode !== startNode && nextNode !== endNode && pointBlocked(nextPoint)) continue;
      if (segmentHitsAny(current, nextPoint, relevant)) continue;
      const nextDirection = neighbor.moveDirection;
      const nextKey = nextNode * 3 + nextDirection;
      if (closed[nextKey]) continue;
      const turn = direction !== 0 && direction !== nextDirection ? TURN_COST : 0;
      const nextG = g[entry.key] + Math.abs(nextPoint.x - current.x) + Math.abs(nextPoint.y - current.y) + turn;
      if (nextG >= g[nextKey]) continue;
      g[nextKey] = nextG;
      previous[nextKey] = entry.key;
      const heuristic = Math.abs(nextPoint.x - target.x) + Math.abs(nextPoint.y - target.y);
      push({ key: nextKey, priority: nextG + heuristic });
    }
  }

  if (endKey < 0) return null;
  const keys: number[] = [];
  let cursor = endKey;
  while (cursor !== -1) {
    keys.push(cursor);
    cursor = previous[cursor];
  }
  keys.reverse();
  return keys.map((key) => {
    const node = Math.floor(key / 3);
    return pointAt(Math.floor(node / ys.length), node % ys.length);
  });
}

function orthogonalCandidates(
  source: Point,
  target: Point,
  obstacles: readonly NodeObstacle[],
  lane: number,
  reverse: boolean,
): Candidate[] {
  const start = source;
  const stub = escapeStub(source.x, target.x);
  const sourceStub = { x: source.x + stub, y: source.y };
  const targetStub = { x: target.x - stub, y: target.y };
  const end = target;
  const midX = (sourceStub.x + targetStub.x) / 2 + lane;
  const candidates: Candidate[] = [];

  const innerBias = reverse ? 1000 : 0;
  candidates.push(
    candidate(
      [start, sourceStub, { x: midX, y: source.y }, { x: midX, y: target.y }, targetStub, end],
      obstacles,
      innerBias,
    ),
  );
  candidates.push(
    candidate(
      [start, sourceStub, { x: targetStub.x, y: source.y }, targetStub, end],
      obstacles,
      innerBias,
    ),
  );
  candidates.push(
    candidate(
      [start, sourceStub, { x: sourceStub.x, y: target.y }, targetStub, end],
      obstacles,
      innerBias,
    ),
  );

  const left = Math.min(sourceStub.x, targetStub.x);
  const right = Math.max(sourceStub.x, targetStub.x);
  const between = obstacles.filter((obstacle) => obstacle.x < right && obstacle.x + obstacle.width > left);
  const top = Math.min(source.y, target.y, ...between.map((obstacle) => obstacle.y)) - CLEARANCE + lane;
  const bottom =
    Math.max(source.y, target.y, ...between.map((obstacle) => obstacle.y + obstacle.height)) +
    CLEARANCE +
    lane;
  const reverseBias = reverse ? -20 : 0;

  for (const [corridorY, sideBias] of [
    [top, 0],
    [bottom, reverse ? 10 : 0],
  ] as const) {
    const bias = reverseBias + sideBias;
    candidates.push(
      candidate(
        [
          start,
          sourceStub,
          { x: sourceStub.x, y: corridorY },
          { x: targetStub.x, y: corridorY },
          targetStub,
          end,
        ],
        obstacles,
        bias,
      ),
    );
  }

  const channelObstacles = between.length > 0 ? between : obstacles;
  const leftChannel = Math.min(sourceStub.x, targetStub.x, ...channelObstacles.map((o) => o.x)) -
    CLEARANCE +
    lane;
  const rightChannel =
    Math.max(
      sourceStub.x,
      targetStub.x,
      ...channelObstacles.map((obstacle) => obstacle.x + obstacle.width),
    ) +
    CLEARANCE +
    lane;

  for (const channelX of [leftChannel, rightChannel]) {
    for (const [corridorY, sideBias] of [
      [top, 0],
      [bottom, reverse ? 10 : 0],
    ] as const) {
      candidates.push(
        candidate(
          [
            start,
            sourceStub,
            { x: channelX, y: source.y },
            { x: channelX, y: corridorY },
            { x: targetStub.x, y: corridorY },
            targetStub,
            end,
          ],
          obstacles,
          reverseBias + sideBias,
        ),
      );
    }
    candidates.push(
      candidate(
        [
          start,
          sourceStub,
          { x: channelX, y: source.y },
          { x: channelX, y: target.y },
          targetStub,
          end,
        ],
        obstacles,
      ),
    );
  }

  return candidates;
}

function fallbackRoute(
  source: Point,
  target: Point,
  obstacles: readonly NodeObstacle[],
  orthogonal: readonly Candidate[],
): { points: Point[]; blocked: number; clearance: number; smooth: boolean } {
  const smooth = cubicSamples(source, target);
  const smoothMetrics = evaluate(smooth, obstacles);
  let bestPoints = smooth;
  let bestBlocked = smoothMetrics.blocked;
  let bestClearance = smoothMetrics.clearance;
  let bestScore = smoothMetrics.length + smoothMetrics.bends * TURN_COST;
  let bestIsSmooth = true;

  for (const candidateValue of orthogonal) {
    const better =
      candidateValue.blocked < bestBlocked ||
      (candidateValue.blocked === bestBlocked && candidateValue.clearance < bestClearance) ||
      (candidateValue.blocked === bestBlocked &&
        candidateValue.clearance === bestClearance &&
        candidateValue.score < bestScore);
    if (better) {
      bestPoints = candidateValue.points;
      bestBlocked = candidateValue.blocked;
      bestClearance = candidateValue.clearance;
      bestScore = candidateValue.score;
      bestIsSmooth = false;
    }
  }

  return {
    points: bestPoints,
    blocked: bestBlocked,
    clearance: bestClearance,
    smooth: bestIsSmooth,
  };
}

function computeRoute(request: RouteRequest): RouteResult {
  const source = { x: request.sx, y: request.sy };
  const target = { x: request.tx, y: request.ty };
  const lane = request.lane ?? 0;
  const reverse = target.x < source.x;

  if (!reverse && target.x > source.x + escapeStub(source.x, target.x) * 2) {
    const samples = cubicSamples(source, target);
    const metrics = evaluate(samples, request.obstacles);
    if (metrics.blocked === 0 && metrics.clearance === 0) {
      return {
        path: cubicPath(source, target),
        points: samples,
        kind: "smooth",
        fallback: false,
        blocked: 0,
        clearance: 0,
      };
    }
  }

  const orthogonal = orthogonalCandidates(source, target, request.obstacles, lane, reverse);
  const clear = orthogonal.filter((candidateValue) => candidateValue.blocked === 0);
  if (clear.length > 0) {
    clear.sort((a, b) => a.clearance - b.clearance || a.score - b.score);
    return {
      path: pointsToRoundedPath(clear[0].points),
      points: clear[0].points,
      kind: "orthogonal",
      fallback: false,
      blocked: 0,
      clearance: clear[0].clearance,
    };
  }

  const stub = escapeStub(source.x, target.x);
  const sourceStub = { x: source.x + stub, y: source.y };
  const targetStub = { x: target.x - stub, y: target.y };
  const grid = gridRoute(sourceStub, targetStub, request.obstacles);
  if (grid) {
    const points = [source, ...grid, target];
    const metrics = evaluate(points, request.obstacles);
    if (metrics.blocked === 0) {
      return {
        path: pointsToRoundedPath(points),
        points: normalizePoints(points),
        kind: "orthogonal",
        fallback: false,
        blocked: 0,
        clearance: metrics.clearance,
      };
    }
  }

  const fallback = fallbackRoute(source, target, request.obstacles, orthogonal);
  return {
    path: fallback.smooth ? cubicPath(source, target) : pointsToRoundedPath(fallback.points),
    points: fallback.points,
    kind: "fallback",
    fallback: true,
    blocked: fallback.blocked,
    clearance: fallback.clearance,
  };
}

export function routeEdge(request: RouteRequest): RouteResult {
  const key = routeCacheKey(request);
  const cached = routeCache.get(key);
  if (cached) return cached;

  const result = computeRoute(request);
  routeCache.set(key, result);
  if (routeCache.size > CACHE_LIMIT) {
    const oldest = routeCache.keys().next().value;
    if (oldest !== undefined) routeCache.delete(oldest);
  }
  return result;
}
