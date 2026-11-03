import type { Node } from "@xyflow/react";

import type { NodeSpec } from "./types";

export type NodeRunState = "running" | "completed" | "failed" | "skipped" | "cancelled";

export interface NodeRunInfo {
  state: NodeRunState;
  activation: number;
  iteration?: number;
}

export interface LingXiNodeData extends Record<string, unknown> {
  kind: string;
  label: string | null;
  params: Record<string, unknown>;
  enabled: boolean;
  spec: NodeSpec;
  run?: NodeRunInfo;
  onParamChange: (nodeId: string, name: string, value: unknown) => void;
  onToggleEnabled: (nodeId: string) => void;
}

export type LingXiNode = Node<LingXiNodeData, "lingxi">;
