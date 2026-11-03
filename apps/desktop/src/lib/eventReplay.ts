//! Pure event replay ordering shared by the UI and unit tests.
//!
//! Live events and replayed rows can overlap, arrive out of order, or contain a
//! gap because the webview missed a bridge notification. This module makes the
//! sequencing rules explicit: deduplicate by seq, fill gaps from SQLite when
//! possible, and never stall on an unrecoverable gap.

import type { RunEvent } from "./types";

export type EventLogLevel = "warn" | "error";

export interface EventDrainHooks {
  apply(event: RunEvent): void;
  log(level: EventLogLevel, message: string): void;
}

export type MissingEventFetcher = (
  runId: string,
  afterSeq?: number,
) => Promise<RunEvent[]>;

export interface EventDrainSummary {
  applied: number;
  duplicates: number;
  recovered: number;
  skipped: number;
}

/** Insert a live or replayed event while keeping one run's seq order stable. */
export function enqueueRunEvent(queue: RunEvent[], event: RunEvent): void {
  let index = queue.length;
  while (index > 0) {
    const previous = queue[index - 1];
    if (previous.runId !== event.runId || previous.seq <= event.seq) break;
    index -= 1;
  }
  queue.splice(index, 0, event);
}

/**
 * Apply queued events strictly by seq. When a gap cannot be filled, advance
 * the applied cursor past the missing range so later events still apply.
 */
export async function drainEventQueue(
  queue: RunEvent[],
  applied: Map<string, number>,
  fetchMissing: MissingEventFetcher,
  hooks: EventDrainHooks,
): Promise<EventDrainSummary> {
  const summary: EventDrainSummary = {
    applied: 0,
    duplicates: 0,
    recovered: 0,
    skipped: 0,
  };

  while (queue.length > 0) {
    const event = queue[0];
    const current = applied.get(event.runId);
    if (current !== undefined && event.seq <= current) {
      queue.shift();
      summary.duplicates += 1;
      continue;
    }

    const expected = current === undefined ? 0 : current + 1;
    if (event.seq > expected) {
      const gap =
        "event gap " +
        event.runId +
        " · seq " +
        expected +
        ".." +
        (event.seq - 1);
      try {
        const missing = await fetchMissing(event.runId, current);
        const unseen = missing.filter(
          (candidate) =>
            candidate.runId === event.runId &&
            candidate.seq >= expected &&
            candidate.seq < event.seq,
        );
        if (unseen.length > 0) {
          unseen.forEach((candidate) => enqueueRunEvent(queue, candidate));
          summary.recovered += unseen.length;
          continue;
        }
      } catch (error) {
        hooks.log("error", "event recovery failed: " + String(error));
      }
      hooks.log("warn", gap + " missing · skipped");
      // Never stall the queue on an unrecoverable gap: advance explicitly.
      applied.set(event.runId, event.seq - 1);
      summary.skipped += 1;
      continue;
    }

    hooks.apply(event);
    applied.set(event.runId, event.seq);
    queue.shift();
    summary.applied += 1;
  }

  return summary;
}
