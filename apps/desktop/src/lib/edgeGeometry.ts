// Pure geometry for the smart edge router. No React and no workflow protocol
// types live here: the router only sees measured rectangles and points.

export interface Point {
  x: number;
  y: number;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface NodeObstacle extends Rect {
  id: string;
}

export interface NodeGeometryLike {
  id: string;
  position: Point;
  width?: number | null;
  height?: number | null;
  measured?: { width?: number; height?: number };
  internals?: { positionAbsolute?: Point };
}

export const NODE_FALLBACK_WIDTH = 252;

export function rectRight(rect: Rect): number {
  return rect.x + rect.width;
}

export function rectBottom(rect: Rect): number {
  return rect.y + rect.height;
}

export function inflateRect(rect: Rect, padding: number): Rect {
  return {
    x: rect.x - padding,
    y: rect.y - padding,
    width: rect.width + padding * 2,
    height: rect.height + padding * 2,
  };
}

export function pointInsideRect(point: Point, rect: Rect, epsilon = 0.01): boolean {
  return (
    point.x > rect.x + epsilon &&
    point.x < rect.x + rect.width - epsilon &&
    point.y > rect.y + epsilon &&
    point.y < rect.y + rect.height - epsilon
  );
}

/** Liang-Barsky segment/rectangle test. Touching a boundary is not a hit. */
export function segmentHitsRect(a: Point, b: Point, rect: Rect, epsilon = 0.01): boolean {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  if (Math.abs(dx) < 1e-9 && Math.abs(dy) < 1e-9) return false;

  const p = [-dx, dx, -dy, dy];
  const q = [a.x - rect.x, rect.x + rect.width - a.x, a.y - rect.y, rect.y + rect.height - a.y];
  let t0 = 0;
  let t1 = 1;

  for (let i = 0; i < 4; i += 1) {
    if (Math.abs(p[i]) < 1e-9) {
      // Outside the slab, or exactly on its boundary: touching does not count
      // as crossing. The latter matters for collinear escape lanes at the
      // clearance boundary, which must stay a soft margin, not a collision.
      if (q[i] <= 0) return false;
      continue;
    }
    const t = q[i] / p[i];
    if (p[i] < 0) {
      if (t > t1) return false;
      if (t > t0) t0 = t;
    } else {
      if (t < t0) return false;
      if (t < t1) t1 = t;
    }
  }

  return t1 > epsilon && t0 < 1 - epsilon;
}

export function segmentHitsAny(a: Point, b: Point, rects: readonly Rect[]): boolean {
  for (const rect of rects) {
    if (segmentHitsRect(a, b, rect)) return true;
  }
  return false;
}

/** The edge itself owns its endpoints; they must never block its escape. */
export function excludeEndpoints(
  obstacles: readonly NodeObstacle[],
  sourceId: string,
  targetId: string,
): NodeObstacle[] {
  return obstacles.filter((obstacle) => obstacle.id !== sourceId && obstacle.id !== targetId);
}

export function pointsBoundingBox(points: readonly Point[]): Rect {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const point of points) {
    minX = Math.min(minX, point.x);
    minY = Math.min(minY, point.y);
    maxX = Math.max(maxX, point.x);
    maxY = Math.max(maxY, point.y);
  }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

export function rectsOverlap(a: Rect, b: Rect, padding = 0): boolean {
  return !(
    a.x + a.width + padding <= b.x ||
    b.x + b.width + padding <= a.x ||
    a.y + a.height + padding <= b.y ||
    b.y + b.height + padding <= a.y
  );
}

/** Measured node rectangles in flow coordinates. Unmeasured nodes are skipped. */
export function nodeObstacles(nodes: Iterable<NodeGeometryLike>): NodeObstacle[] {
  const obstacles: NodeObstacle[] = [];
  for (const node of nodes) {
    const width = node.measured?.width ?? node.width ?? NODE_FALLBACK_WIDTH;
    const height = node.measured?.height ?? node.height ?? 0;
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 1 || height <= 1) continue;
    const position = node.internals?.positionAbsolute ?? node.position;
    obstacles.push({
      id: node.id,
      x: position.x,
      y: position.y,
      width,
      height,
    });
  }
  return obstacles;
}

const INDEX_CELL = 256;

function cellKey(cx: number, cy: number): string {
  return cx + ":" + cy;
}

/** Uniform grid over node rectangles. Queries stay local as the graph grows. */
export class ObstacleIndex {
  readonly obstacles: NodeObstacle[];
  private readonly byId = new Map<string, NodeObstacle>();
  private readonly cells = new Map<string, NodeObstacle[]>();

  constructor(obstacles: readonly NodeObstacle[]) {
    this.obstacles = [...obstacles].sort((a, b) => a.id.localeCompare(b.id));
    for (const obstacle of this.obstacles) {
      this.byId.set(obstacle.id, obstacle);
      const minX = Math.floor(obstacle.x / INDEX_CELL);
      const maxX = Math.floor((obstacle.x + obstacle.width) / INDEX_CELL);
      const minY = Math.floor(obstacle.y / INDEX_CELL);
      const maxY = Math.floor((obstacle.y + obstacle.height) / INDEX_CELL);
      for (let cx = minX; cx <= maxX; cx += 1) {
        for (let cy = minY; cy <= maxY; cy += 1) {
          const key = cellKey(cx, cy);
          const bucket = this.cells.get(key);
          if (bucket) bucket.push(obstacle);
          else this.cells.set(key, [obstacle]);
        }
      }
    }
  }

  query(bounds: Rect): NodeObstacle[] {
    const ids = new Set<string>();
    const minX = Math.floor(bounds.x / INDEX_CELL);
    const maxX = Math.floor((bounds.x + bounds.width) / INDEX_CELL);
    const minY = Math.floor(bounds.y / INDEX_CELL);
    const maxY = Math.floor((bounds.y + bounds.height) / INDEX_CELL);
    for (let cx = minX; cx <= maxX; cx += 1) {
      for (let cy = minY; cy <= maxY; cy += 1) {
        const bucket = this.cells.get(cellKey(cx, cy));
        if (!bucket) continue;
        for (const obstacle of bucket) {
          if (rectsOverlap(obstacle, bounds)) ids.add(obstacle.id);
        }
      }
    }
    return [...ids]
      .map((id) => this.byId.get(id))
      .filter((obstacle): obstacle is NodeObstacle => obstacle !== undefined)
      .sort((a, b) => a.id.localeCompare(b.id));
  }

  queryAround(sx: number, sy: number, tx: number, ty: number, expand = 440): NodeObstacle[] {
    return this.query({
      x: Math.min(sx, tx) - expand,
      y: Math.min(sy, ty) - expand,
      width: Math.abs(tx - sx) + expand * 2,
      height: Math.abs(ty - sy) + expand * 2,
    });
  }
}
