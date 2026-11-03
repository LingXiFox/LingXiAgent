import { BaseEdge, type EdgeProps } from "@xyflow/react";
import { createContext, useContext, useEffect, useMemo, type ReactNode } from "react";

import { excludeEndpoints, type ObstacleIndex } from "../lib/edgeGeometry";
import { laneForEdge, routeEdge } from "../lib/edgeRouter";

const EdgeRoutingContext = createContext<ObstacleIndex | null>(null);

export function EdgeRoutingProvider({
  index,
  children,
}: {
  index: ObstacleIndex;
  children: ReactNode;
}) {
  return <EdgeRoutingContext.Provider value={index}>{children}</EdgeRoutingContext.Provider>;
}

export function SmartEdge({
  id,
  source,
  target,
  sourceX,
  sourceY,
  targetX,
  targetY,
  sourceHandleId,
  targetHandleId,
  data,
  markerEnd,
}: EdgeProps) {
  const index = useContext(EdgeRoutingContext);
  const lane = laneForEdge(id, sourceHandleId, targetHandleId);
  const control = Boolean((data as { control?: boolean } | undefined)?.control);

  const route = useMemo(() => {
    const obstacles = index
      ? excludeEndpoints(
          index.queryAround(sourceX, sourceY, targetX, targetY),
          source,
          target,
        )
      : [];
    return routeEdge({
      sx: sourceX,
      sy: sourceY,
      tx: targetX,
      ty: targetY,
      obstacles,
      lane,
    });
  }, [index, lane, source, sourceX, sourceY, target, targetX, targetY]);

  useEffect(() => {
    if (route.fallback) {
      console.warn(
        "smart edge " + id + " fell back to a route crossing " + route.blocked + " obstacle(s)",
      );
    }
  }, [id, route]);

  const className =
    "edge-path " +
    (control ? "edge-path--control" : "edge-path--data") +
    (route.fallback ? " edge-path--fallback" : "");

  return (
    <g className="smart-edge" data-routing={route.kind}>
      <BaseEdge
        path={route.path}
        className={className}
        markerEnd={markerEnd}
        interactionWidth={18}
      />
      {route.fallback ? (
        <title>
          Edge routing fallback: no obstacle-free path was found ({route.blocked} crossing
          {route.blocked === 1 ? "" : "s"})
        </title>
      ) : null}
    </g>
  );
}
