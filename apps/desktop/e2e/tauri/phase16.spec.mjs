import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// Native Tauri E2E for the Phase 1.6 Agent node. Every workflow below is
// executed by the real Rust runtime; only the model endpoint is a deterministic
// local mock. Nothing here stubs AgentRunner, the message bus or SQLite.

const BASE_URL = "http://127.0.0.1:11434/v1";
const PASSED = "Tests passed";

async function invoke(command, args = {}) {
  return browser.tauri.execute(
    (tauri, cmd, payload) => tauri.core.invoke(cmd, payload),
    command,
    args,
  );
}

async function waitForLog(fragment, timeout = 60000) {
  await browser.waitUntil(async () => {
    const lines = await $$('[data-testid="log-line"]');
    for (const line of lines) {
      if ((await line.getText()).includes(fragment)) return true;
    }
    return false;
  }, { timeout, interval: 200, timeoutMsg: "log did not contain: " + fragment });
}

async function logText() {
  const lines = await $$('[data-testid="log-line"]');
  const text = [];
  for (const line of lines) text.push(await line.getText());
  return text.join("\n");
}

async function openSaved(name) {
  await $('[data-testid="toolbar-open"]').click();
  const row = await $('[data-testid="workflow-load-' + name + '"]');
  await row.waitForClickable({ timeout: 15000 });
  await row.click();
  const canvasTab = await $('[data-testid="view-canvas"]');
  if (await canvasTab.isExisting()) {
    await canvasTab.click();
  }
  await $('[data-testid="canvas"]').waitForDisplayed({ timeout: 15000 });
}

async function latestRun(name) {
  const runs = await invoke("run_list", { limit: 100 });
  return runs.find((item) => item.workflowName === name);
}

async function waitForRun(name, timeout = 30000) {
  let run;
  await browser.waitUntil(async () => {
    run = await latestRun(name);
    return Boolean(run);
  }, { timeout, interval: 200, timeoutMsg: "run did not start: " + name });
  return run;
}

async function approvePersistedInteractions(runId, timeout = 120000) {
  const approved = new Set();
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const detail = await invoke("run_detail", { runId });
    const resolved = new Set(
      detail.events
        .filter((event) => event.type === "interaction.resolved")
        .map((event) => event.requestId),
    );
    for (const event of detail.events) {
      if (event.type !== "interaction.requested" || resolved.has(event.requestId)) continue;
      if (approved.has(event.requestId)) continue;
      console.log("approving native interaction: " + event.prompt);
      await invoke("respond_interaction", {
        requestId: event.requestId,
        approved: true,
      });
      approved.add(event.requestId);
    }
    if (detail.run.status !== "running") return detail;
    await browser.pause(200);
  }
  throw new Error("run did not finish after approvals\n" + (await logText()));
}

async function waitForRunStatus(runId, status, timeout = 120000) {
  let detail;
  await browser.waitUntil(async () => {
    detail = await invoke("run_detail", { runId });
    return detail.run.status === status;
  }, { timeout, interval: 200, timeoutMsg: "run " + runId + " did not reach " + status });
  return detail;
}

async function waitForSession(runId, predicate, timeout = 60000, message = "session") {
  let session;
  await browser.waitUntil(async () => {
    session = await invoke("task_session", { runId });
    return Boolean(session) && predicate(session);
  }, { timeout, interval: 200, timeoutMsg: message });
  return session;
}

async function waitForWebDriver(port, timeout = 60000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      const response = await fetch("http://127.0.0.1:" + port + "/status", {
        signal: AbortSignal.timeout(1500),
      });
      const body = await response.json();
      if (body?.value?.ready) return;
    } catch {
      // The relaunched app is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("relaunched app did not expose its embedded WebDriver server");
}

function node(id, kind, label, x, y, params = {}) {
  return { id, kind, label, position: { x, y }, params, enabled: true };
}

function edge(source, sourcePort, target, targetPort, kind = "data") {
  return {
    id: source + ":" + sourcePort + "->" + target + ":" + targetPort,
    source,
    sourcePort,
    target,
    targetPort,
    kind,
  };
}

function agentParams(model, instruction, toolset = "") {
  return {
    providerId: "e2e-openai",
    baseUrl: BASE_URL,
    credentialRef: "env:OPENAI_API_KEY",
    protocol: "openai_chat",
    model,
    temperature: 0.1,
    reasoning: "off",
    rolePrompt: "You are a deterministic native E2E agent.",
    systemPrompt: "",
    instruction,
    recipient: "broadcast",
    maxIterations: 8,
    maxToolCalls: 16,
    maxTotalTokens: 0,
    timeoutMs: 120000,
    toolset,
    skills: "",
    lsp: "",
    maxTokens: 1024,
  };
}

function workflow(name, nodes, edges) {
  return {
    schemaVersion: "1.2",
    id: "wf-" + name.replace(/[^a-z0-9]+/gi, "-").toLowerCase(),
    name,
    description: "Phase 1.6 native Agent E2E: " + name,
    nodes,
    edges,
    viewport: { x: 20, y: 20, zoom: 0.7 },
  };
}

function soloWorkflow(name) {
  return workflow(name, [
    node("solo", "core.agent", "Solo Agent", 40, 120, agentParams(
      "mock-agent",
      "Complete the native E2E task.",
    )),
    node("solo-log", "core.log", "Delivery", 420, 120, { prefix: "solo: " }),
  ], [
    edge("solo", "completed", "solo-log", "run", "control"),
    edge("solo", "userResponse", "solo-log", "value"),
  ]);
}

function companyWorkflow(name, testerModel) {
  return workflow(name, [
    node("pm", "core.agent", "Product Manager", 40, 40, agentParams(
      "mock-pm",
      "Write a concise PRD and hand it to engineering.",
    )),
    node("gate", "core.loop_gate", "Rework Loop", 380, 40, {
      maxIterations: 4,
      timeoutMs: 120000,
    }),
    node("coder", "core.agent", "Coder", 700, 40, agentParams(
      "mock-coder",
      "Implement the PRD, then hand the implementation to QA.",
      "read_file,write_file",
    )),
    node("tester", "core.agent", "Tester", 1020, 40, agentParams(
      testerModel,
      "Verify the implementation and report a pass or fail verdict.",
      "read_file",
    )),
    node("log", "core.log", "Delivery", 1340, 40, { prefix: "delivery: " }),
  ], [
    edge("pm", "completed", "gate", "start", "control"),
    edge("gate", "continue", "coder", "start", "control"),
    edge("coder", "completed", "tester", "start", "control"),
    edge("tester", "failed", "gate", "next", "control"),
    edge("tester", "completed", "gate", "stop", "control"),
    edge("gate", "exit", "log", "run", "control"),
    edge("pm", "agentMessage", "coder", "task"),
    edge("coder", "agentMessage", "tester", "task"),
    edge("tester", "agentMessage", "coder", "messages"),
    edge("tester", "userResponse", "log", "value"),
  ]);
}

async function saveAndRun(name, definition) {
  const saved = await invoke("save_workflow", { name, workflow: definition });
  assert.equal(saved.name, name);
  await openSaved(name);
  await $('[data-testid="toolbar-run"]').click();
  await $('[data-testid="agent-workbench"]').waitForDisplayed({ timeout: 30000 });
  return waitForRun(name);
}

describe("LingXiAgent native Agent workbench E2E", () => {
  before(async () => {
    // WKWebView localStorage survives a fresh LINGXI_DATA_DIR, so a previous
    // run may leave the app on the workbench tab. Start every suite on canvas.
    const canvas = await $('[data-testid="canvas"]');
    if (!(await canvas.isDisplayed())) {
      const canvasTab = await $('[data-testid="view-canvas"]');
      if (await canvasTab.isExisting()) {
        await canvasTab.click();
      }
    }
    await canvas.waitForDisplayed({ timeout: 120000 });
    await waitForLog("node catalog ready", 60000);
  });

  it("A: runs one Agent node through the Rust runner", async () => {
    const name = "Native Phase16 Solo";
    const run = await saveAndRun(name, soloWorkflow(name));
    const detail = await approvePersistedInteractions(run.runId);
    assert.equal(detail.run.status, "completed");
    await waitForLog("solo: Agent completed the task.");
    const session = await invoke("task_session", { runId: run.runId });
    assert.equal(Object.keys(session.agents).length, 1);
    const solo = Object.values(session.agents)[0];
    assert.equal(solo.nodeId, "solo");
    assert.equal(solo.state, "completed");
    assert.equal(solo.activations.length, 1);
    assert.ok(solo.usage.modelCalls >= 1);
    const finishes = detail.events.filter((event) => event.type === "run.finished");
    assert.equal(finishes.length, 1);
    assert.equal(finishes[0].status, "completed");
  });

  it("B: hands a structured PRD from PM to Coder to Tester", async () => {
    const name = "Native Phase16 Handoff";
    const run = await saveAndRun(name, companyWorkflow(name, "mock-tester-pass"));
    const detail = await approvePersistedInteractions(run.runId);
    assert.equal(detail.run.status, "completed");
    await waitForLog("Tests passed on the first attempt.");
    const session = await invoke("task_session", { runId: run.runId });
    assert.equal(Object.keys(session.agents).length, 3);
    const byNode = (id) => Object.values(session.agents).find((item) => item.nodeId === id);
    assert.equal(byNode("pm").activations.length, 1);
    assert.equal(byNode("coder").activations.length, 1);
    assert.equal(byNode("tester").activations.length, 1);
    assert.equal(session.messages.length, 3, "each handoff message must be persisted");
    const senders = new Set(session.messages.map((message) => message.sender));
    assert.equal(senders.size, 3, "each agent must publish its own message");
    assert.ok(
      session.messages.every((message) => message.type === "task.result"),
      "handoff messages must use the structured task.result contract",
    );
  });

  it("C: fails QA, reworks the same Coder instance and passes", async () => {
    const name = "Native Phase16 Rework";
    const run = await saveAndRun(name, companyWorkflow(name, "mock-tester"));
    const detail = await approvePersistedInteractions(run.runId);
    assert.equal(detail.run.status, "completed");
    await waitForLog(PASSED);
    const session = await invoke("task_session", { runId: run.runId });
    assert.equal(Object.keys(session.agents).length, 3);
    const coder = Object.values(session.agents).find((item) => item.nodeId === "coder");
    const tester = Object.values(session.agents).find((item) => item.nodeId === "tester");
    assert.equal(coder.activations.length, 2, "same Coder instance reruns after QA failure");
    assert.equal(tester.activations.length, 2);
    assert.equal(new Set([coder.instanceId, tester.instanceId]).size, 2);
    assert.ok(session.messages.length >= 5, "rework feedback must travel through the bus");
  });

  it("D: pauses a Coder, applies a prompt revision and resumes the same activation", async () => {
    const name = "Native Phase16 Intervention";
    const definition = workflow(name, [
      node("coder", "core.agent", "Coder", 40, 120, agentParams(
        "mock-agent-slow-tool",
        "Implement the feature, then report the result.",
        "calculator",
      )),
      node("log", "core.log", "Delivery", 420, 120, { prefix: "coder: " }),
    ], [
      edge("coder", "completed", "log", "run", "control"),
      edge("coder", "userResponse", "log", "value"),
    ]);
    const run = await saveAndRun(name, definition);
    // The network permission prompt is raised before the first model call.
    // Approve it in the background so the pause below reaches an in-flight
    // activation instead of blocking on the approval prompt.
    const approvals = approvePersistedInteractions(run.runId);
    const session = await waitForSession(
      run.runId,
      (value) => Object.values(value.agents).some((item) => item.nodeId === "coder"),
      30000,
      "coder instance registration",
    );
    const instance = Object.values(session.agents).find((item) => item.nodeId === "coder");
    await invoke("pause_agent", { runId: run.runId, agentInstanceId: instance.instanceId });
    const paused = await waitForSession(
      run.runId,
      (value) => value.agents[instance.instanceId].state === "paused",
      60000,
      "agent did not reach a safe pause point",
    );
    const before = paused.agents[instance.instanceId];
    const next = JSON.parse(JSON.stringify(before.config));
    next.rolePrompt = "You are the Coder. Preserve the analysis and finish the revision.";
    const changes = await invoke("preview_agent_config", {
      runId: run.runId,
      agentInstanceId: instance.instanceId,
      config: next,
    });
    assert.ok(changes.some((change) => change.field === "rolePrompt"));
    const revision = await invoke("apply_agent_config", {
      runId: run.runId,
      agentInstanceId: instance.instanceId,
      config: next,
      expectedRevision: before.config.revision,
    });
    assert.equal(revision.status, "pending");
    await invoke("send_agent_directive", {
      runId: run.runId,
      agentInstanceId: instance.instanceId,
      text: "Keep the existing implementation and finish after the prompt update.",
    });
    await invoke("resume_agent", { runId: run.runId, agentInstanceId: instance.instanceId });
    const detail = await approvals;
    assert.equal(detail.run.status, "completed");
    const after = await invoke("task_session", { runId: run.runId });
    const coder = after.agents[instance.instanceId];
    assert.equal(coder.activations.length, 1, "resume must not start a new activation");
    assert.ok(coder.config.revision > before.config.revision);
    assert.ok(coder.config.rolePrompt.includes("Preserve the analysis"));
    assert.ok(
      coder.configRevisions.some((item) => item.status === "applied"),
      "runtime must mark the revision applied at a safe point",
    );
  });

  it("E: rejects an invalid or stale config change without corrupting the session", async () => {
    const name = "Native Phase16 Rejection";
    const run = await saveAndRun(name, soloWorkflow(name));
    const session = await waitForSession(
      run.runId,
      (value) => Object.keys(value.agents).length > 0,
      30000,
      "agent registration",
    );
    const instance = Object.values(session.agents)[0];
    const config = JSON.parse(JSON.stringify(instance.config));
    config.model = "";
    await assert.rejects(
      invoke("preview_agent_config", {
        runId: run.runId,
        agentInstanceId: instance.instanceId,
        config,
      }),
      /model must not be empty/,
    );
    const good = JSON.parse(JSON.stringify(instance.config));
    good.rolePrompt = "A stale revision must never be applied.";
    await assert.rejects(
      invoke("apply_agent_config", {
        runId: run.runId,
        agentInstanceId: instance.instanceId,
        config: good,
        expectedRevision: instance.config.revision + 99,
      }),
      /config revision/,
    );
    const unchanged = await invoke("task_session", { runId: run.runId });
    const same = unchanged.agents[instance.instanceId];
    assert.equal(same.config.revision, instance.config.revision);
    assert.equal(same.configRevisions.length, 0);
    await approvePersistedInteractions(run.runId);
  });

  it("F: switches canvas and workbench repeatedly without restarting the run", async () => {
    const name = "Native Phase16 Switching";
    const definition = workflow(name, [
      node("coder", "core.agent", "Coder", 40, 120, agentParams(
        "mock-agent-slow-tool",
        "Work slowly enough to observe view switching.",
        "calculator",
      )),
      node("log", "core.log", "Delivery", 420, 120, { prefix: "switch: " }),
    ], [
      edge("coder", "completed", "log", "run", "control"),
      edge("coder", "userResponse", "log", "value"),
    ]);
    const run = await saveAndRun(name, definition);
    await $('[data-testid="agent-tab-coder"]').waitForDisplayed({ timeout: 30000 });
    for (let index = 0; index < 3; index += 1) {
      await $('[data-testid="view-canvas"]').click();
      await $('[data-testid="canvas"]').waitForDisplayed({ timeout: 10000 });
      await $('[data-testid="view-workbench"]').click();
      await $('[data-testid="agent-workbench"]').waitForDisplayed({ timeout: 10000 });
    }
    const session = await invoke("task_session", { runId: run.runId });
    const coder = Object.values(session.agents).find((item) => item.nodeId === "coder");
    assert.equal(coder.activations.length, 1, "view switching must not recreate the agent");
    const detail = await approvePersistedInteractions(run.runId);
    assert.equal(detail.run.status, "completed");
    await waitForLog("switch: Slow tool agent completed.");
  });

  it("G: restores the workbench and selected agent after a WebView refresh", async () => {
    const name = "Native Phase16 Refresh";
    const definition = workflow(name, [
      node("coder", "core.agent", "Coder", 40, 120, agentParams(
        "mock-agent-slow-tool",
        "Stay active while the WebView is refreshed.",
        "calculator",
      )),
      node("log", "core.log", "Delivery", 420, 120, { prefix: "refresh: " }),
    ], [
      edge("coder", "completed", "log", "run", "control"),
      edge("coder", "userResponse", "log", "value"),
    ]);
    const run = await saveAndRun(name, definition);
    await $('[data-testid="agent-tab-coder"]').click();
    await $('[data-testid="agent-tab-coder"]').waitForDisplayed({ timeout: 30000 });
    await browser.refresh();
    await $('[data-testid="agent-workbench"]').waitForDisplayed({ timeout: 120000 });
    await $('[data-testid="agent-tab-coder"]').waitForDisplayed({ timeout: 30000 });
    const selected = await $('[data-testid="agent-tab-coder"]');
    assert.equal(await selected.getAttribute("aria-selected"), "true");
    const session = await invoke("task_session", { runId: run.runId });
    const coder = Object.values(session.agents).find((item) => item.nodeId === "coder");
    assert.equal(coder.activations.length, 1, "refresh must not restart the agent");
    const detail = await approvePersistedInteractions(run.runId);
    assert.equal(detail.run.status, "completed");
  });

  it("H: recovers an interrupted tool-using activation for manual review", async () => {
    const name = "Native Phase16 Recovery";
    const definition = workflow(name, [
      node("coder", "core.agent", "Coder", 40, 120, agentParams(
        "mock-agent-slow-tool",
        "Use a tool, then finish slowly enough to interrupt the process.",
        "calculator",
      )),
      node("log", "core.log", "Delivery", 420, 120, { prefix: "recovery: " }),
    ], [
      edge("coder", "completed", "log", "run", "control"),
      edge("coder", "userResponse", "log", "value"),
    ]);
    const run = await saveAndRun(name, definition);
    // Approve the network and calculator prompts while the activation runs.
    // The promise is expected to lose its WebDriver session when the process
    // is killed, so it must not reject the test.
    void approvePersistedInteractions(run.runId).catch(() => null);
    const session = await waitForSession(
      run.runId,
      (value) => Object.values(value.agents).some(
        (item) => item.usage.toolCalls >= 1 && item.state === "running",
      ),
      60000,
      "agent did not perform a tool call before interruption",
    );
    const instance = Object.values(session.agents).find((item) => item.nodeId === "coder");
    assert.equal(instance.activations.length, 1);

    const appBinary = process.env.LINGXI_E2E_APP_BINARY;
    const dataDir = process.env.LINGXI_E2E_DATA_DIR;
    assert.ok(appBinary, "native E2E binary path must be exported by wdio.conf.mjs");
    assert.ok(dataDir, "native E2E data directory must be exported by wdio.conf.mjs");
    const port = browser.options.port || 4445;
    const pids = execFileSync("pgrep", ["-f", appBinary], { encoding: "utf8" })
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .map(Number);
    assert.ok(pids.length >= 1, "native app process must be running");
    for (const pid of pids) process.kill(pid, "SIGKILL");
    await new Promise((resolve) => setTimeout(resolve, 1000));

    const child = spawn(appBinary, [], {
      env: {
        ...process.env,
        LINGXI_DATA_DIR: dataDir,
        TAURI_WEBDRIVER_PORT: String(port),
        WDIO_EMBEDDED_SERVER: "true",
        OPENAI_API_KEY: process.env.OPENAI_API_KEY || "sk-e2e-local",
      },
      stdio: "ignore",
    });
    assert.ok(child.pid, "relaunched app must have a pid");
    fs.writeFileSync(path.join(dataDir, "recovered-app.pid"), String(child.pid));
    await waitForWebDriver(port);
    await browser.reloadSession();
    await waitForLog("node catalog ready", 60000);

    const recovered = await invoke("task_session", { runId: run.runId });
    assert.equal(recovered.state, "interrupted");
    const interrupted = recovered.agents[instance.instanceId];
    assert.equal(interrupted.state, "interrupted");
    assert.equal(interrupted.activations.length, 1, "recovery must not replay the activation");
    assert.equal(interrupted.activations[0].state, "interrupted");
    assert.match(interrupted.activations[0].error, /process exited before the activation finished/);
    assert.equal(recovered.pendingReviews.length, 1, "tool side effects need manual review");
    assert.equal(recovered.pendingReviews[0].resolved, false);
    assert.equal(recovered.pendingReviews[0].agentInstanceId, instance.instanceId);
    assert.match(recovered.pendingReviews[0].reason, /Verify the external side effect/);
    const detail = await invoke("run_detail", { runId: run.runId });
    assert.equal(detail.run.status, "interrupted");
    const terminalEvents = detail.events.filter((event) => event.type === "run.finished");
    assert.equal(terminalEvents.length, 1, "recovery must write exactly one terminal event");
    assert.equal(
      terminalEvents[0].status,
      "interrupted",
      "a crashed run must be terminal but never presented as completed",
    );
  });
});
