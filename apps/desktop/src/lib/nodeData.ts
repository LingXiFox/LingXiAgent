import type { Node } from "@xyflow/react";

import type { AssetRef, NodeSpec, ProviderProtocol } from "./types";

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
  /** Root asset table, used by asset params for previews and metadata. */
  assets?: Record<string, AssetRef>;
  protocol?: ProviderProtocol;
  modelName?: string;
  capabilitiesOverride?: unknown;
  onAssetImported?: (asset: AssetRef) => void;
  /** Composite instance metadata; undefined for ordinary nodes. */
  subgraphId?: string;
  innerNodeCount?: number;
  onParamChange: (nodeId: string, name: string, value: unknown) => void;
  onToggleEnabled: (nodeId: string) => void;
}

export type LingXiNode = Node<LingXiNodeData, "lingxi">;
