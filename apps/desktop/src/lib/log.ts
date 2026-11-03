export type UiRunStatus = "idle" | "running" | "completed" | "failed" | "cancelled";

export type LogLevel = "info" | "success" | "warn" | "error";

export interface LogEntry {
  id: number;
  at: number;
  level: LogLevel;
  text: string;
}
