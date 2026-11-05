import { useCallback, useEffect, useMemo, type DragEvent } from "react";
import {
  Background,
  BackgroundVariant,
  Controls,
  MiniMap,
  ReactFlow,
  useReactFlow,
  useStore,
  type Connection,
  type Edge,
  type EdgeTypes,
  type NodeTypes,
  type OnEdgesChange,
  type OnNodesChange,
  type OnSelectionChangeParams,
  type Viewport,
} from "@xyflow/react";

import { nodeObstacles, ObstacleIndex } from "../lib/edgeGeometry";
import type { LingXiNode } from "../lib/nodeData";
import type { ViewportDoc } from "../lib/types";
import { LingXiNode as LingXiNodeView } from "./LingXiNode";
import { NODE_DRAG_TYPE, TEMPLATE_DRAG_TYPE } from "./NodeLibrary";
import { EdgeRoutingProvider, SmartEdge } from "./SmartEdge";

const nodeTypes: NodeTypes = { lingxi: LingXiNodeView };
const edgeTypes: EdgeTypes = { smart: SmartEdge };

interface CanvasProps {
  nodes: LingXiNode[];
  edges: Edge[];
  running: boolean;
  viewport?: ViewportDoc | null;
  viewportKey: number;
  onNodesChange: OnNodesChange<LingXiNode>;
  onEdgesChange: OnEdgesChange;
  onConnect: (connection: Connection) => void;
  onDropNode: (kind: string, position: { x: number; y: number }) => void;
  onDropTemplate: (id: string, position: { x: number; y: number }) => void;
  onNodeDoubleClick: (nodeId: string) => void;
  onSelectionChange: (nodeIds: string[]) => void;
  onViewportChange: (viewport: Viewport) => void;
  focus?: { nodeId: string; nonce: number } | null;
}

export function Canvas({
  nodes,
  edges,
  running,
  viewport,
  viewportKey,
  onNodesChange,
  onEdgesChange,
  onConnect,
  onDropNode,
  onDropTemplate,
  onNodeDoubleClick,
  onSelectionChange,
  onViewportChange,
  focus,
}: CanvasProps) {
  const { screenToFlowPosition, setViewport, getNode, setCenter } = useReactFlow();
  const nodeLookup = useStore((state) => state.nodeLookup);
  const routingIndex = useMemo(
    () => new ObstacleIndex(nodeObstacles(nodeLookup.values())),
    [nodeLookup, nodes],
  );
  const displayNodes = useMemo(
    () =>
      running
        ? nodes.map((node) => ({
            ...node,
            draggable: false,
            connectable: false,
            deletable: false,
            data: { ...node.data, readOnly: true },
          }))
        : nodes,
    [nodes, running],
  );

  // Applying the stored viewport happens only on explicit loads (viewportKey),
  // never on every render, so panning is not fought by a re-sync loop.
  useEffect(() => {
    if (!viewport) return;
    void setViewport({ x: viewport.x, y: viewport.y, zoom: viewport.zoom }, { duration: 0 });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewportKey]);

  // Workbench -> canvas locating. Runs after the layer has rendered so the
  // target node is in the React Flow store; a nonce makes repeated requests work.
  useEffect(() => {
    if (!focus) return;
    const node = getNode(focus.nodeId);
    if (!node) return;
    const width = node.measured?.width ?? 260;
    const height = node.measured?.height ?? 180;
    void setCenter(node.position.x + width / 2, node.position.y + height / 2, {
      zoom: 1.05,
      duration: 260,
    });
  }, [focus, getNode, setCenter, nodes.length]);

  const onDragOver = useCallback((event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
  }, []);

  const onDrop = useCallback(
    (event: DragEvent<HTMLDivElement>) => {
      event.preventDefault();
      const templateId = event.dataTransfer.getData(TEMPLATE_DRAG_TYPE);
      const kind = event.dataTransfer.getData(NODE_DRAG_TYPE);
      if (!templateId && !kind) return;
      const position = screenToFlowPosition({ x: event.clientX, y: event.clientY });
      const drop = { x: position.x - 130, y: position.y - 30 };
      if (templateId) onDropTemplate(templateId, drop);
      else onDropNode(kind, drop);
    },
    [onDropNode, onDropTemplate, screenToFlowPosition],
  );

  return (
    <div
      className={"canvas" + (running ? " canvas--running" : "")}
      data-testid="canvas"
      onDrop={(event) => {
        // A run executes an immutable document snapshot; dropping a node here
        // would change the canvas without changing the active run.
        if (!running) onDrop(event);
      }}
      onDragOver={onDragOver}
    >
      {running ? (
        <div className="canvas__lock" data-testid="canvas-lock">
          运行中 · 结构已锁定
        </div>
      ) : null}
      <EdgeRoutingProvider index={routingIndex}>
        <ReactFlow
          nodes={displayNodes}
          edges={edges}
          onNodesChange={onNodesChange}
          onEdgesChange={onEdgesChange}
          onConnect={onConnect}
          onMoveEnd={(_event, viewport) => onViewportChange(viewport)}
          onNodeDoubleClick={(_event, node) => onNodeDoubleClick(node.id)}
          onSelectionChange={(selection: OnSelectionChangeParams) =>
            onSelectionChange(selection.nodes.map((node) => node.id))
          }
          nodeTypes={nodeTypes}
          edgeTypes={edgeTypes}
          defaultEdgeOptions={{ type: "smart" }}
          multiSelectionKeyCode={["Meta", "Shift", "Control"]}
          fitView
          fitViewOptions={{ padding: 0.25, maxZoom: 1 }}
          minZoom={0.2}
          maxZoom={2.5}
          snapToGrid
          snapGrid={[16, 16]}
          proOptions={{ hideAttribution: true }}
          deleteKeyCode={running ? null : ["Backspace", "Delete"]}
          nodesDraggable={!running}
          nodesConnectable={!running}
          edgesReconnectable={!running}
          edgesFocusable={!running}
        >
          <Background variant={BackgroundVariant.Dots} gap={22} size={1} color="#262c35" />
          <Controls showInteractive={false} position="bottom-right" />
          <MiniMap
            pannable
            zoomable
            position="top-right"
            maskColor="rgba(8, 10, 14, 0.72)"
            nodeColor="#4a5563"
            style={{ width: 132, height: 88 }}
          />
        </ReactFlow>
      </EdgeRoutingProvider>
      {nodes.length === 0 ? (
        <div className="canvas__empty">
          <p className="canvas__empty-title">拖拽左侧节点到画布开始</p>
          <p className="canvas__empty-hint">连接端口 · 节点内可直接编辑参数 · Delete 删除选中项</p>
        </div>
      ) : null}
    </div>
  );
}
