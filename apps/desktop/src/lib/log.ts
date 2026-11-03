export type UiRunStatus = "idle" | "running" | "completed" | "failed" | "cancelled" | "interrupted";

export const RUN_STATUS_TEXT: Record<UiRunStatus, string> = {
  idle: "就绪",
  running: "运行中",
  completed: "已完成",
  failed: "失败",
  cancelled: "已终止",
  interrupted: "已中断",
};

export type LogLevel = "info" | "success" | "warn" | "error";

export interface LogEntry {
  id: number;
  at: number;
  level: LogLevel;
  text: string;
}
