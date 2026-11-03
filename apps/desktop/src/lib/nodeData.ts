import type { Node } from "@xyflow/react";

import type { NodeSpec } from "./types";

export interface LingXiNodeData extends Record<string, unknown> {
  kind: string;
  label: string | null;
  params: Record<string, unknown>;
  enabled: boolean;
  spec: NodeSpec;
  onParamChange: (nodeId: string, name: string, value: unknown) => void;
  onToggleEnabled: (nodeId: string) => void;
}

export type LingXiNode = Node<LingXiNodeData, "lingxi">;
