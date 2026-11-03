# Phase 1.1.1 · 智能连线与避障设计

状态：已实现。Rust 无改动；前端路由测试、真实 macOS Tauri 验收通过；Windows/Linux 未做运行时视觉验收。
范围：仅替换边渲染，不改变工作流 JSON、节点语义、执行器或四区布局。

## 一、目标与非目标

目标：让任意方向的边都从真实端口出发、落到真实端口，绕开节点矩形，并在拖拽、缩放、保存重载后保持稳定可读。

非目标：

- 不做全局边布局规划，不保证边与边之间零交叉。
- 不做手工折点编辑、边捆绑（bus）、锚点拖拽。
- 不改变 `schemaVersion`、不新增 `Edge` 字段、不触碰 Rust Runtime。
- 不为路由引入第三方依赖。

## 二、为什么替换默认 smoothstep

React Flow 默认 `smoothstep` 只按源/目标点的相对位置折线，不知道节点矩形。Phase 1.1 的 Condition 有两条反向控制边（`true/false -> Loop Gate`），Loop Gate 的 `exit` 又要绕到右下角 Log；默认路由会出现：

- 反向边在节点左侧原地折回、悬空结束；
- `gate.exit -> log.value` 直接穿过 Counter 节点；
- 相邻端口间距只有 28px 时，端口逃逸段戳进对侧节点。

Phase 1.1 的旧截图保留在 `Docs/phase-1.1.1/assets/before-smoothstep.png`。

## 三、模块边界

| 文件 | 职责 |
| --- | --- |
| `apps/desktop/src/lib/edgeGeometry.ts` | 点/矩形基础运算、线段与矩形相交、节点障碍物、空间哈希索引 |
| `apps/desktop/src/lib/edgeRouter.ts` | 候选路径生成、评分、A* 兜底、圆角 SVG path、缓存、lane 计算 |
| `apps/desktop/src/components/SmartEdge.tsx` | 单条边的 React 适配：取障碍物、调 router、输出 `BaseEdge` |
| `apps/desktop/src/components/Canvas.tsx` | 建立 `ObstacleIndex`，注册 `edgeTypes.smart`，提供 `EdgeRoutingProvider` |
| `apps/desktop/src/App.tsx` | 新建边与加载文档统一写 `type: "smart"`、`data.control` |
| `apps/desktop/src/styles.css` | data 实线、control 紫色虚线、fallback 降透明度、hover/selected |

坐标全部使用 React Flow 的 flow 坐标；节点尺寸取 `node.measured`，未测量时回退 `NODE_FALLBACK_WIDTH = 252`。路由不依赖 DOM 测量，因此缩放不会触发重新路由。

## 四、障碍物索引

```ts
interface NodeObstacle {
  id: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

class ObstacleIndex {
  constructor(obstacles: NodeObstacle[]);
  query(bounds: Rect): NodeObstacle[];
  queryAround(sx: number, sy: number, tx: number, ty: number, expand?: number): NodeObstacle[];
}
```

- 以 256px 网格分桶；`queryAround` 取源/目标包围盒外扩 440px 的桶，避免 A* 候选折点落在索引外。
- 索引由 `Canvas` 用 `useMemo` 随节点位置/尺寸变化重建；单条边只查询一次。
- `SmartEdge` 用 `excludeEndpoints` 排除源、目标自身，否则边永远“撞”自己的节点。

## 五、路径选择

```ts
interface RouteRequest {
  sx: number; sy: number; tx: number; ty: number;
  obstacles: readonly NodeObstacle[];
  lane?: number;
}

interface RouteResult {
  path: string;
  points: Point[];
  kind: "smooth" | "orthogonal" | "fallback";
  fallback: boolean;
  blocked: number;    // 真正穿过节点矩形
  clearance: number;  // 只进入 14px 安全边距，未穿模
}
```

### 5.1 常量

| 常量 | 值 | 用途 |
| --- | --- | --- |
| `STUB` | 10 | 端口逃逸段最大长度 |
| `CORNER_RADIUS` | 9 | 正交路径圆角 |
| `CLEARANCE` | 14 | 安全边距；`clearance` 计数用 |
| `TURN_COST` | 26 | 评分中的一次折弯代价 |
| `LANE_STEP` | 4 | 平行边车道间距 |
| `CACHE_LIMIT` | 4000 | 路由缓存条数上限 |
| `A_STAR_OBSTACLE_LIMIT` | 20 | A* 只取最近 20 个障碍物 |
| `A_STAR_EXPANSION_LIMIT` | 12000 | A* 扩展上限，防卡死 |

### 5.2 决策顺序

1. **正向且空间足够**：源在目标左侧，且水平距离大于两个逃逸段，先采样三次贝塞尔；只有 `blocked = 0 && clearance = 0` 才采用 `smooth`。这样普通短边保持 React Flow 的观感。
2. **正交候选**：生成 11 条候选（中轴、源/目标高度直接折线、上方/下方走廊、左/右外侧通道等），按“实际碰撞 → 安全边距 → 长度 + 折弯代价”排序。只要 `blocked = 0` 就可用；允许进入 14px 边距，但记录 `clearance` 供排序。
3. **A***：所有候选都穿模时，以障碍物边界 ±CLEARANCE 建稀疏网格，带转向代价搜索，扩展超限就放弃。
4. **兜底**：仍无解则选碰撞最少的一条，标记 `fallback = true`，加 `.edge-path--fallback`、`<title>` 和控制台 `console.warn`；不静默删边，也不假装成功。

反向边（目标在源左侧）不会走贝塞尔，强制走正交候选，避免曲线在节点内部回勾。反向候选给“外侧通道”负偏置，优先从节点外侧绕。

### 5.3 端口逃逸与 28px 间隙

`escapeStub = min(10, gap / 2)`，`gap = targetX - sourceX`。Phase 1.1 示例里 Seed 右边缘到 Loop Gate 左边缘只有 28px；固定 22px 逃逸段会顶进对侧节点，所以改为按可用间隙收缩。单测覆盖 28px 与更窄间隙下逃逸点单调、无越界。

### 5.4 平行边分离

`laneForEdge(edgeId, sourceHandle, targetHandle)` 用端口名做加权哈希，得到 -16..16 之间的 4px 倍数偏移。用端口而不是纯边 ID，是为了让“同一对节点、不同端口”的平行边也分开；同一组端口重载后偏移稳定。

### 5.5 缓存

缓存 key 包含源/目标坐标（0.5px 取整）、lane、以及每个障碍物的 id 与四元组。React Flow 拖拽时节点坐标变化会让 key 变化，旧 key 留在 Map 中；超过 4000 条按插入顺序淘汰。缩放不改变 flow 坐标，命中缓存。

## 六、视觉规范

- data 边：`#677283` 实线，1.6px。
- control 边：`#b98cff` 虚线 `5 4`，1.8px，圆头。
- hover / selected：琥珀色，不改变路径。
- fallback：透明度 `.72`，保留原线型，附 native title。
- 所有路径统一走 `pointsToRoundedPath`，转角半径 9px；短段自动收缩到段长一半，避免圆角过冲。

## 七、兼容与回滚

- `Edge.type` 是可选字段；旧文档没有 `type` 时 `Canvas` 的 `defaultEdgeOptions` 仍会落到 `smart`。JSON 不写路由结果，只写 `type: "smart"`。
- 旧文档的 `data.control` 保持原义；没有该字段按 data 边渲染。
- 回滚只需把 `edgeTypes` 与 `defaultEdgeOptions` 改回默认，Rust 与工作流文件不受影响。

## 八、已知边界

- 边与边仍可能交叉。Condition 两个输入端口顺序与 Counter 输出端口顺序相反时，两条 data 边会在两节点之间形成一个小交叉；强行绕开会让路径显著变长，当前接受。
- 在 fit 缩放（约 0.68）下，两条反向控制边与底部 exit 边会围成一个较大的虚线矩形。几何上无穿模、留白 14px，但视觉偏“电路板”；这是“严格避障 + 保持端口出发”的取舍。
- 障碍物完全包围端口时只能 fallback；当前没有“穿一个节点”的合法例外。
- 不做全局边捆绑，密集图里平行边仍逐条绘制。
- 路由是前端行为；Rust 测试与执行语义不受影响。
