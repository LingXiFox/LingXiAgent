import assert from "node:assert/strict";

const DAG_NAME = "LingXi E2E DAG";
const AGENT_NAME = "LingXi E2E Agent";
const AGENT_RUN_NAME = "LingXi E2E Agent Run";
const RECOVERY_NAME = "LingXi E2E Agent Recovery";
const CANCEL_NAME = "LingXi E2E Agent Cancel";

async function invoke(command, args = {}) {
  return browser.tauri.execute(
    (tauri, cmd, payload) => tauri.core.invoke(cmd, payload),
    command,
    args,
  );
}

async function waitForLog(fragment, timeout = 30000) {
  await browser.waitUntil(async () => {
    const lines = await $$('[data-testid="log-line"]');
    for (const line of lines) {
      if ((await line.getText()).includes(fragment)) return true;
    }
    return false;
  }, {
    timeout,
    interval: 200,
    timeoutMsg: "log did not contain: " + fragment,
  });
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
}

async function approvePendingInteractions(timeout = 60000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const dialog = await $('[data-testid="interaction-dialog"]');
    if (await dialog.isDisplayed().catch(() => false)) {
      const prompt = await dialog.$('.modal__prompt').getText();
      console.log('approving interaction: ' + prompt);
      await $('[data-testid="interaction-approve"]').click();
      await browser.pause(250);
      continue;
    }
    if ((await logText()).includes('run completed')) return;
    await browser.pause(200);
  }
  throw new Error('run did not complete while approving interactions\n' + (await logText()));
}

async function waitForRunStatus(name, status, timeout = 30000) {
  await browser.waitUntil(async () => {
    const runs = await invoke('run_list', { limit: 50 });
    const run = runs.find((item) => item.workflowName === name);
    if (!run) return false;
    const detail = await invoke('run_detail', { runId: run.runId });
    return detail?.run?.status === status;
  }, { timeout, interval: 200, timeoutMsg: 'run ' + name + ' did not reach ' + status });
  const runs = await invoke('run_list', { limit: 50 });
  return runs.find((item) => item.workflowName === name);
}

async function waitForRunning(name, timeout = 15000) {
  const runs = await invoke("run_list", { limit: 50 });
  const run = runs.find((item) => item.workflowName === name);
  assert.ok(run, "run must be persisted before recovery: " + name);
  await browser.waitUntil(async () => {
    const detail = await invoke("run_detail", { runId: run.runId });
    return detail?.run?.status === "running";
  }, { timeout, interval: 100, timeoutMsg: "run " + name + " did not start" });
  return run;
}

async function approvePersistedInteractions(runId, timeout = 60000) {
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
      console.log("approving persisted interaction: " + event.prompt);
      await invoke("respond_interaction", { requestId: event.requestId, approved: true });
      approved.add(event.requestId);
    }
    if (detail.run.status === "completed") return;
    if (detail.run.status !== "running") {
      throw new Error("run ended while approving: " + detail.run.status + "\n" + (await logText()));
    }
    await browser.pause(200);
  }
  throw new Error("run did not complete after approvals\n" + (await logText()));
}

async function saveAgentVariant(name, model) {
  const document = await invoke('load_workflow', { name: AGENT_RUN_NAME });
  const composite = document.nodes.find((node) => node.kind === 'core.composite');
  assert.ok(composite?.subgraphId, 'agent composite must be loadable');
  const subgraph = document.subgraphs[composite.subgraphId];
  assert.ok(subgraph, 'agent subgraph must be loadable');
  const modelNode = subgraph.workflow.nodes.find((node) => node.kind === 'core.model');
  assert.ok(modelNode, 'agent subgraph must contain a model node');
  modelNode.params = { ...modelNode.params, model };
  document.name = name;
  await invoke('save_workflow', { name, workflow: document });
  return document;
}

async function waitForCounts(fragment, timeout = 15000) {
  await browser.waitUntil(async () => {
    const text = await $(".toolbar__counts").getText();
    return text.includes(fragment);
  }, { timeout, interval: 100, timeoutMsg: "toolbar counts did not contain: " + fragment });
}

function dagWorkflow() {
  return {
    schemaVersion: "1.1",
    id: "wf-e2e-dag",
    name: DAG_NAME,
    description: "Real Tauri E2E: text input -> uppercase -> log",
    nodes: [
      {
        id: "e2e-input",
        kind: "core.text_input",
        label: "Input",
        position: { x: 80, y: 160 },
        params: { text: "hello rust e2e" },
        enabled: true,
      },
      {
        id: "e2e-upper",
        kind: "core.text_uppercase",
        label: "Uppercase",
        position: { x: 440, y: 160 },
        params: {},
        enabled: true,
      },
      {
        id: "e2e-log",
        kind: "core.log",
        label: "Log",
        position: { x: 800, y: 160 },
        params: { prefix: "e2e" },
        enabled: true,
      },
    ],
    edges: [
      {
        id: "e2e-input:text->e2e-upper:text",
        source: "e2e-input",
        sourcePort: "text",
        target: "e2e-upper",
        targetPort: "text",
        kind: "data",
      },
      {
        id: "e2e-upper:text->e2e-log:value",
        source: "e2e-upper",
        sourcePort: "text",
        target: "e2e-log",
        targetPort: "value",
        kind: "data",
      },
    ],
    viewport: { x: 100, y: 80, zoom: 1 },
    metadata: {},
  };
}

describe("LingXiAgent native Tauri E2E", () => {
  before(async () => {
    await $('[data-testid="canvas"]').waitForDisplayed({ timeout: 120000 });
    await waitForLog("node catalog ready", 60000);
  });

  it("runs a saved DAG through the real Rust runtime and persists events", async () => {
    const saved = await invoke("save_workflow", { name: DAG_NAME, workflow: dagWorkflow() });
    assert.equal(saved.name, DAG_NAME);
    assert.equal(saved.nodeCount, 3);

    await openSaved(DAG_NAME);
    await waitForCounts("3 节点 · 2 连线");

    await $('[data-testid="toolbar-run"]').click();
    await waitForLog("HELLO RUST E2E", 30000);
    await waitForLog("run completed", 30000);

    const runs = await invoke("run_list", { limit: 20 });
    const run = runs.find((item) => item.workflowName === DAG_NAME);
    assert.ok(run, "run_list must contain the DAG run");

    await browser.waitUntil(async () => {
      const detail = await invoke("run_detail", { runId: run.runId });
      return detail?.run?.status === "completed";
    }, { timeout: 15000, interval: 200, timeoutMsg: "DAG run did not persist as completed" });

    const detail = await invoke("run_detail", { runId: run.runId });
    assert.equal(detail.run.nodeCount, 3);
    const finished = detail.events.filter((event) => event.type === "node.finished");
    assert.equal(finished.length, 3, "each of the three nodes must finish exactly once");
    const terminal = detail.events.filter((event) => event.type === "run.finished");
    assert.equal(terminal.length, 1);
    assert.equal(terminal[0].status, "completed");
    const logs = detail.events.filter((event) => event.type === "log").map((event) => event.message);
    assert.ok(logs.some((message) => message.includes("HELLO RUST E2E")), "log event must be persisted");

    const text = await logText();
    assert.match(text, /HELLO RUST E2E/);
    assert.match(text, /run completed/);
  });

  it("runs the standard Agent template with a live tool loop", async () => {
    await $('[data-testid="toolbar-new"]').click();
    const confirm = await $('[data-testid="confirm-accept"]');
    if (await confirm.isDisplayed().catch(() => false)) await confirm.click();
    await $('[data-testid="workflow-name"]').setValue(AGENT_NAME);
    await $('[data-testid="toolbar-agent"]').click();
    await waitForLog("instantiated standard agent template", 30000);
    await browser.waitUntil(async () => (await $$(".react-flow__node")).length === 1, {
      timeout: 15000,
      timeoutMsg: "agent composite node was not inserted",
    });

    await $('[data-testid="toolbar-save"]').click();
    await waitForLog("saved " + AGENT_NAME, 30000);

    const document = await invoke("load_workflow", { name: AGENT_NAME });
    const composite = document.nodes.find((node) => node.kind === "core.composite");
    assert.ok(composite, "standard agent must be a composite node");
    assert.ok(composite.subgraphId, "composite must reference a subgraph");
    const subgraph = document.subgraphs?.[composite.subgraphId];
    assert.ok(subgraph, "composite subgraph definition must be persisted");
    const kinds = subgraph.workflow.nodes.map((node) => node.kind);
    for (const kind of ["core.prompt", "core.loop_gate", "core.model", "core.condition", "core.tool_dispatch", "core.context", "core.tool_set", "core.provider", "core.log"]) {
      assert.ok(kinds.includes(kind), "agent subgraph must contain " + kind);
    }
    const provider = subgraph.workflow.nodes.find((node) => node.kind === "core.provider");
    assert.equal(provider.params.baseUrl, "http://127.0.0.1:11434/v1");

    // Seed the template with a prompt and a control trigger. This is the same
    // shape the UI produces when a text input is wired into a composite.
    const seed = {
      id: "e2e-seed",
      kind: "core.text_input",
      label: "Prompt",
      position: { x: -360, y: 120 },
      params: { text: "Use the calculator for 128 * 256 and reply with the final number." },
      enabled: true,
    };
    composite.position = { x: 120, y: 100 };
    document.nodes.push(seed);
    document.edges.push(
      {
        id: "e2e-seed:text->" + composite.id + ":start",
        source: "e2e-seed",
        sourcePort: "text",
        target: composite.id,
        targetPort: "start",
        kind: "control",
      },
      {
        id: "e2e-seed:text->" + composite.id + ":text",
        source: "e2e-seed",
        sourcePort: "text",
        target: composite.id,
        targetPort: "text",
        kind: "data",
      },
    );
    document.name = AGENT_RUN_NAME;
    document.viewport = { x: 40, y: 120, zoom: 0.9 };
    await invoke("save_workflow", { name: AGENT_RUN_NAME, workflow: document });

    await openSaved(AGENT_RUN_NAME);
    await waitForCounts("2 节点 · 2 连线");
    await $('[data-testid="toolbar-run"]').click();
    // Network access and the calculator target are approved through the same
    // InteractionBroker the desktop UI uses; the run stays paused until then.
    await approvePendingInteractions();
    await waitForLog("tool ✓ calculator", 60000);
    await waitForLog("The answer is 32768.", 60000);
    await waitForLog("run completed", 60000);

    const runs = await invoke("run_list", { limit: 20 });
    const run = runs.find((item) => item.workflowName === AGENT_RUN_NAME);
    assert.ok(run, "agent run must be persisted");
    await browser.waitUntil(async () => {
      const detail = await invoke("run_detail", { runId: run.runId });
      return detail?.run?.status === "completed";
    }, { timeout: 15000, interval: 200, timeoutMsg: "agent run did not persist as completed" });

    const detail = await invoke("run_detail", { runId: run.runId });
    assert.equal(detail.run.nodeCount, 2);
    const toolStarted = detail.events.filter(
      (event) => event.type === "tool.started" && event.toolName === "calculator",
    );
    assert.equal(toolStarted.length, 1, "calculator must be called once");
    assert.match(toolStarted[0].arguments, /128 \* 256/);
    const toolFinished = detail.events.filter(
      (event) => event.type === "tool.finished" && event.toolName === "calculator",
    );
    assert.equal(toolFinished.length, 1);
    assert.equal(toolFinished[0].ok, true);
    assert.match(toolFinished[0].result, /32768/);
    const nodeStarted = detail.events.filter((event) => event.type === "node.started");
    assert.ok(nodeStarted.some((event) => event.kind === "core.loop_gate"), "loop gate must execute");
    assert.ok(nodeStarted.some((event) => event.kind === "core.tool_dispatch"), "tool dispatch must execute");
    assert.ok(detail.events.some((event) => event.type === "model.delta"), "streaming model deltas must be recorded");
    const terminal = detail.events.filter((event) => event.type === "run.finished");
    assert.equal(terminal.length, 1);
    assert.equal(terminal[0].status, "completed");
  });

  it("reconnects to an in-flight run after a WebView reload without duplicating events", async () => {
    await saveAgentVariant(RECOVERY_NAME, "mock-calculator");
    await openSaved(RECOVERY_NAME);
    await waitForCounts("2 节点 · 2 连线");

    await $('[data-testid="toolbar-run"]').click();
    await waitForLog("waiting for approval", 30000);
    const run = await waitForRunning(RECOVERY_NAME);

    // Refreshing the WebView destroys the page but not the Rust run. The run is
    // paused on a persisted approval request, so recovery is deterministic.
    await browser.refresh();
    await $('[data-testid="canvas"]').waitForDisplayed({ timeout: 60000 });
    await waitForLog("reconnected to run", 60000);
    assert.match(await logText(), /reconnected to run/);

    await approvePersistedInteractions(run.runId, 60000);
    await waitForLog("run completed", 60000);
    const detail = await invoke("run_detail", { runId: run.runId });
    const terminal = detail.events.filter((event) => event.type === "run.finished");
    assert.equal(terminal.length, 1, "recovery must not duplicate the terminal event");
    assert.equal(terminal[0].status, "completed");
    const sequences = detail.events.map((event) => event.seq);
    assert.equal(new Set(sequences).size, sequences.length, "replayed events must be deduplicated by sequence");
    const modelStarted = detail.events.filter(
      (event) => event.type === "node.started" && event.kind === "core.model",
    );
    const modelFinished = detail.events.filter(
      (event) => event.type === "node.finished" && event.kind === "core.model",
    );
    assert.equal(modelFinished.length, modelStarted.length, "each model iteration must finish exactly once");
    assert.equal(modelFinished.length, 2, "the tool iteration and the final answer iteration must both finish");
  });

  it("cancels an in-flight Agent run through the Rust runtime", async () => {
    await saveAgentVariant(CANCEL_NAME, "mock-calculator");
    await openSaved(CANCEL_NAME);
    await waitForCounts("2 节点 · 2 连线");

    await $('[data-testid="toolbar-run"]').click();
    await waitForLog("waiting for approval", 30000);
    const run = await waitForRunning(CANCEL_NAME);
    // The approval modal covers the toolbar, so trigger the same button handler
    // through the DOM while keeping the pause deterministic.
    await browser.execute(() => {
      document.querySelector('[data-testid="toolbar-stop"]').click();
    });

    await waitForLog("run cancelled", 30000);
    const detail = await invoke("run_detail", { runId: run.runId });
    const terminal = detail.events.filter((event) => event.type === "run.finished");
    assert.equal(terminal.length, 1);
    assert.equal(terminal[0].status, "cancelled");
    assert.ok(
      detail.events.some((event) => event.type === "node.cancelled"),
      "the in-flight node must record a cancellation event",
    );
  });
});
