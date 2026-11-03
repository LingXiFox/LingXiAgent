import assert from "node:assert/strict";
import test from "node:test";

import {
  drainEventQueue,
  enqueueRunEvent,
} from "../src/lib/eventReplay.ts";

function logEvent(seq, runId = "run-1") {
  return {
    runId,
    seq,
    type: "log",
    atMs: seq,
    level: "info",
    nodeId: null,
    message: "event " + seq,
  };
}

function collector() {
  const applied = [];
  const logs = [];
  return {
    applied,
    logs,
    hooks: {
      apply: (event) => applied.push(event.seq),
      log: (level, message) => logs.push({ level, message }),
    },
  };
}

test("replayed and live events are applied in seq order", async () => {
  const queue = [];
  enqueueRunEvent(queue, logEvent(2));
  enqueueRunEvent(queue, logEvent(0));
  const { applied, hooks } = collector();
  const calls = [];

  const summary = await drainEventQueue(
    queue,
    new Map(),
    async (runId, afterSeq) => {
      calls.push([runId, afterSeq]);
      return [logEvent(1)];
    },
    hooks,
  );

  assert.deepEqual(applied, [0, 1, 2]);
  assert.deepEqual(calls, [["run-1", 0]]);
  assert.equal(summary.recovered, 1);
  assert.equal(queue.length, 0);
});

test("duplicate live and snapshot events are ignored", async () => {
  const queue = [];
  [0, 1, 1, 0].forEach((seq) => enqueueRunEvent(queue, logEvent(seq)));
  const { applied, hooks } = collector();
  let fetches = 0;

  const summary = await drainEventQueue(
    queue,
    new Map(),
    async () => {
      fetches += 1;
      return [];
    },
    hooks,
  );

  assert.deepEqual(applied, [0, 1]);
  assert.equal(fetches, 0);
  assert.equal(summary.duplicates, 2);
});

test("a gap fetches only the missing same-run range", async () => {
  const queue = [];
  [0, 3].forEach((seq) => enqueueRunEvent(queue, logEvent(seq)));
  const { applied, hooks } = collector();
  const calls = [];

  const summary = await drainEventQueue(
    queue,
    new Map(),
    async (runId, afterSeq) => {
      calls.push([runId, afterSeq]);
      return [
        logEvent(1, "other-run"),
        logEvent(0),
        logEvent(1),
        logEvent(2),
        logEvent(5),
      ];
    },
    hooks,
  );

  assert.deepEqual(applied, [0, 1, 2, 3]);
  assert.deepEqual(calls, [["run-1", 0]]);
  assert.equal(summary.recovered, 2);
});

test("an empty recovery response skips the gap instead of stalling", async () => {
  const queue = [];
  [0, 3].forEach((seq) => enqueueRunEvent(queue, logEvent(seq)));
  const { applied, logs, hooks } = collector();

  const summary = await drainEventQueue(
    queue,
    new Map(),
    async () => [],
    hooks,
  );

  assert.deepEqual(applied, [0, 3]);
  assert.equal(summary.skipped, 1);
  assert.equal(queue.length, 0);
  assert.ok(
    logs.some(
      (entry) =>
        entry.level === "warn" &&
        entry.message.includes("event gap") &&
        entry.message.includes("skipped"),
    ),
    JSON.stringify(logs),
  );
});

test("a failed recovery keeps the queue moving and logs the failure", async () => {
  const queue = [];
  [0, 2].forEach((seq) => enqueueRunEvent(queue, logEvent(seq)));
  const { applied, logs, hooks } = collector();

  const summary = await drainEventQueue(
    queue,
    new Map(),
    async () => {
      throw new Error("run database unavailable");
    },
    hooks,
  );

  assert.deepEqual(applied, [0, 2]);
  assert.equal(summary.skipped, 1);
  assert.ok(
    logs.some(
      (entry) =>
        entry.level === "error" &&
        entry.message.includes("run database unavailable"),
    ),
    JSON.stringify(logs),
  );
  assert.ok(
    logs.some(
      (entry) =>
        entry.level === "warn" && entry.message.includes("missing · skipped"),
    ),
    JSON.stringify(logs),
  );
});

test("late replayed events are deduplicated after the cursor advanced", async () => {
  const queue = [];
  [0, 3].forEach((seq) => enqueueRunEvent(queue, logEvent(seq)));
  const applied = new Map();
  const { applied: appliedSeqs, hooks } = collector();
  let fetches = 0;

  await drainEventQueue(
    queue,
    applied,
    async () => {
      fetches += 1;
      return [logEvent(1), logEvent(2)];
    },
    hooks,
  );
  assert.deepEqual(appliedSeqs, [0, 1, 2, 3]);
  assert.equal(fetches, 1);

  [2, 3, 4].forEach((seq) => enqueueRunEvent(queue, logEvent(seq)));
  const summary = await drainEventQueue(
    queue,
    applied,
    async () => {
      fetches += 1;
      return [];
    },
    hooks,
  );

  assert.deepEqual(appliedSeqs, [0, 1, 2, 3, 4]);
  assert.equal(fetches, 1, "duplicates must not trigger another recovery");
  assert.equal(summary.duplicates, 2);
});
