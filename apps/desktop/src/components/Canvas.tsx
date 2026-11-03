import { useCallback, useEffect, type DragEvent } from "react";
import {
  Background,
  BackgroundVariant,
  Controls,
  MiniMap,
  ReactFlow,
  useReactFlow,
  type Connection,
  type Edge,
  type NodeTypes,
  type OnEdgesChange,
  type OnNodesChange,
  type Viewport,
} from "@xyflow/react";

import type { LingXiNode } from "../lib/nodeData";
import type { ViewportDoc } from "../lib/types";
import { LingXiNode as LingXiNodeView } from "./LingXiNode";
import { NODE_DRAG_TYPE } from "./NodeLibrary";

const nodeTypes: NodeTypes = { lingxi: LingXiNodeView };

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
  onViewportChange: (viewport: Viewport) => void;
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
  onViewportChange,
}: CanvasProps) {
  const { screenToFlowPosition, setViewport } = useReactFlow();

  // Applying the stored viewport happens only on explicit loads (viewportKey),
  // never on every render, so panning is not fought by a re-sync loop.
  useEffect(() => {
    if (!viewport) return;
    void setViewport({ x: viewport.x, y: viewport.y, zoom: viewport.zoom }, { duration: 0 });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewportKey]);

  const onDragOver = useCallback((event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
  }, []);

  const onDrop = useCallback(
    (event: DragEvent<HTMLDivElement>) => {
      event.preventDefault();
      const kind = event.dataTransfer.getData(NODE_DRAG_TYPE);
      if (!kind) return;
      const position = screenToFlowPosition({ x: event.clientX, y: event.clientY });
      onDropNode(kind, { x: position.x - 130, y: position.y - 30 });
    },
    [onDropNode, screenToFlowPosition],
  );

  return (
    <div
      className={"canvas" + (running ? " canvas--running" : "")}
      onDrop={onDrop}
      onDragOver={onDragOver}
    >
      <ReactFlow
        nodes={nodes}
        edges={edges}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        onConnect={onConnect}
        onMoveEnd={(_event, viewport) => onViewportChange(viewport)}
        nodeTypes={nodeTypes}
        defaultEdgeOptions={{ type: "smoothstep" }}
        fitView
        fitViewOptions={{ padding: 0.25, maxZoom: 1 }}
        minZoom={0.2}
        maxZoom={2.5}
        snapToGrid
        snapGrid={[16, 16]}
        proOptions={{ hideAttribution: true }}
        deleteKeyCode={["Backspace", "Delete"]}
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
      {nodes.length === 0 ? (
        <div className="canvas__empty">
          <p className="canvas__empty-title">拖拽左侧节点到画布开始</p>
          <p className="canvas__empty-hint">连接端口 · 节点内可直接编辑参数 · Delete 删除选中项</p>
        </div>
      ) : null}
    </div>
  );
}
