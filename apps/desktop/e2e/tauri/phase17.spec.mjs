import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Native Phase 1.7 E2E: projects, workspace binding, versioned files and live
// permission modes. Every command below is real Tauri IPC into the Rust host;
// the only deterministic part is the local OpenAI-compatible mock model.

const BASE_URL = "http://127.0.0.1:11434/v1";

async function invoke(command, args = {}) {
  return browser.tauri.execute(
    (tauri, cmd, payload) => tauri.core.invoke(cmd, payload),
    command,
    args,
  );
}

function tempProject(label) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "lingxi-p17-" + label + "-"));
  fs.mkdirSync(path.join(root, "src"), { recursive: true });
  fs.writeFileSync(path.join(root, "README.md"), "# Demo project\n");
  fs.writeFileSync(path.join(root, "src", "index.ts"), "export const value = 1;\n");
  fs.writeFileSync(path.join(root, "AGENTS.md"), "Root project rules.\n");
  fs.writeFileSync(path.join(root, "src", "AGENTS.md"), "Source directory rules.\n");
  return root;
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

function agentParams(model, mode, toolset) {
  return {
    providerId: "e2e-openai",
    baseUrl: BASE_URL,
    credentialRef: "env:OPENAI_API_KEY",
    protocol: "openai_chat",
    model,
    temperature: 0.1,
    reasoning: "off",
    rolePrompt: "You are a deterministic native Phase 1.7 agent.",
    systemPrompt: "",
    instruction: "",
    recipient: "user",
    maxIterations: 8,
    maxToolCalls: 16,
    maxTotalTokens: 0,
    timeoutMs: 120000,
    toolset,
    skills: "",
    lsp: "",
    maxTokens: 1024,
    permissionMode: mode,
  };
}

function projectWorkflow(name, projectId, model, mode, toolset) {
  return {
    schemaVersion: "1.2",
    id: "wf-" + name.replace(/[^a-z0-9]+/gi, "-").toLowerCase(),
    name,
    description: "Phase 1.7 native project E2E: " + name,
    nodes: [
      node("project", "core.project_workspace", "Project", 40, 160, {
        projectId,
        cwd: "",
      }),
      node("agent", "core.agent", "Agent", 380, 120, agentParams(model, mode, toolset)),
      node("log", "core.log", "Output", 760, 160, { prefix: "result: " }),
    ],
    edges: [
      edge("project", "workspace", "agent", "workspace"),
      edge("project", "ready", "agent", "start", "control"),
      edge("agent", "completed", "log", "run", "control"),
      edge("agent", "userResponse", "log", "value"),
    ],
    viewport: { x: 20, y: 20, zoom: 0.7 },
  };
}

async function startRun(workflow, conversationId, message, mode) {
  const started = await invoke("run_workflow", {
    workflow,
    conversationId,
    userMessage: message,
    permissionMode: mode,
  });
  assert.equal(started.started, true, JSON.stringify(started.report));
  assert.ok(started.runId);
  return started.runId;
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
      await invoke("respond_interaction", { requestId: event.requestId, approved: true });
      approved.add(event.requestId);
    }
    if (detail.run.status !== "running") return detail;
    await browser.pause(200);
  }
  throw new Error("run did not finish after approvals");
}

async function waitForRun(runId, timeout = 120000) {
  let detail;
  await browser.waitUntil(async () => {
    detail = await invoke("run_detail", { runId });
    return detail.run.status !== "running";
  }, { timeout, interval: 200, timeoutMsg: "run did not finish: " + runId });
  return detail;
}

async function projectConversation(root, label) {
  const opened = await invoke("project_open", { root });
  const conversation = await invoke("conversation_create", {
    projectId: opened.project.projectId,
    title: label,
  });
  return { opened, conversation };
}

describe("LingXiAgent native project workspace E2E", () => {
  before(async () => {
    // WKWebView localStorage survives a fresh LINGXI_DATA_DIR, so a previous
    // run may leave the app on the workbench tab. Start on canvas before IPC.
    const canvas = await $('[data-testid="canvas"]');
    if (!(await canvas.isDisplayed())) {
      const canvasTab = await $('[data-testid="view-canvas"]');
      if (await canvasTab.isExisting()) {
        await canvasTab.click();
      }
    }
    await canvas.waitForDisplayed({ timeout: 120000 });
    await $('[data-testid="log-line"]').waitForDisplayed({ timeout: 60000 });
  });

  it("A: opens a real folder, creates a default Agent session and edits its workspace", async () => {
    const root = tempProject("workspace");
    const opened = await invoke("project_open", { root });
    assert.ok(opened.project.projectId.startsWith("proj-"));
    assert.ok(opened.workspaceHandle.startsWith("ws-"));
    assert.equal(opened.project.root, fs.realpathSync(root));
    assert.ok(opened.tree.some((entry) => entry.name === "src" && entry.kind === "dir"));

    const conversation = await invoke("conversation_create", {
      projectId: opened.project.projectId,
      title: "Native project analysis",
    });
    assert.deepEqual(
      conversation.workflow.nodes.map((item) => item.kind),
      ["core.project_workspace", "core.agent", "core.log"],
      "the normal session is backed by the visible project -> Agent -> output workflow",
    );

    const workflow = projectWorkflow(
      "Native Phase17 Workspace",
      opened.project.projectId,
      "mock-coder",
      "workspace",
      "read_file,write_file,list_files",
    );
    await invoke("conversation_save_workflow", {
      conversationId: conversation.conversationId,
      workflow,
    });
    const runId = await startRun(workflow, conversation.conversationId, "Implement the feature in the project.", "workspace");
    const detail = await approvePersistedInteractions(runId);
    assert.equal(detail.run.status, "completed", JSON.stringify(detail.events.at(-1)));
    assert.equal(
      fs.readFileSync(path.join(root, "company-demo", "feature.txt"), "utf8"),
      "v1",
      "the Agent must write through the project-bound workspace, not an app-data fallback",
    );
    const snapshot = await invoke("project_read", {
      projectId: opened.project.projectId,
      path: "company-demo/feature.txt",
    });
    assert.equal(snapshot.content, "v1");
    assert.ok(snapshot.version);
    const messages = await invoke("conversation_messages", {
      conversationId: conversation.conversationId,
    });
    assert.equal(messages[0].role, "user");
    assert.match(messages[0].content, /Implement the feature/);
    assert.equal(messages.at(-1).role, "assistant");
    assert.ok(
      detail.events.some(
        (event) => event.type === "agent.event" && event.event?.type === "agent.activation.finished",
      ),
      "the run must expose the Agent activation lifecycle",
    );
  });

  it("B: enforces versioned writes, path containment and symlink escapes", async () => {
    const root = tempProject("versions");
    const opened = await invoke("project_open", { root });
    const readme = await invoke("project_read", {
      projectId: opened.project.projectId,
      path: "README.md",
    });
    const saved = await invoke("project_write", {
      projectId: opened.project.projectId,
      path: "README.md",
      content: "# Updated\n",
      expectedVersion: readme.version,
    });
    assert.equal(saved.content, "# Updated\n");
    await assert.rejects(
      invoke("project_write", {
        projectId: opened.project.projectId,
        path: "README.md",
        content: "stale write",
        expectedVersion: "sha256:stale",
      }),
      /changed since it was read/,
    );
    await assert.rejects(
      invoke("project_write", {
        projectId: opened.project.projectId,
        path: "../escape.txt",
        content: "escape",
        expectedVersion: "absent",
      }),
      /outside|escapes|project/i,
    );
    const outside = fs.mkdtempSync(path.join(os.tmpdir(), "lingxi-p17-outside-"));
    fs.writeFileSync(path.join(outside, "secret.txt"), "do not read");
    fs.symlinkSync(outside, path.join(root, "link"));
    await assert.rejects(
      invoke("project_read", { projectId: opened.project.projectId, path: "link/secret.txt" }),
      /escape|outside|symlink|project/i,
    );
    await assert.rejects(invoke("project_open", { root: path.join(root, "missing") }), /does not exist/);
  });

  it("C: scopes AGENTS.md and records workspace-mode authorization decisions", async () => {
    const root = tempProject("rules");
    const opened = await invoke("project_open", { root });
    const top = await invoke("project_rules", { projectId: opened.project.projectId, path: "" });
    assert.equal(top.documents.length, 1);
    assert.match(top.documents[0].content, /Root project rules/);
    const nested = await invoke("project_rules", {
      projectId: opened.project.projectId,
      path: "src/index.ts",
    });
    assert.equal(nested.documents.length, 2);
    assert.match(nested.documents[0].content, /Root project rules/);
    assert.match(nested.documents[1].content, /Source directory rules/);

    const conversation = await invoke("conversation_create", {
      projectId: opened.project.projectId,
      title: "Native permission audit",
    });
    const workflow = projectWorkflow(
      "Native Phase17 Workspace Audit",
      opened.project.projectId,
      "mock-coder",
      "workspace",
      "read_file,write_file",
    );
    const runId = await startRun(workflow, conversation.conversationId, "Implement it.", "workspace");
    const detail = await approvePersistedInteractions(runId);
    assert.equal(detail.run.status, "completed");
    const audit = await invoke("permission_audit", { runId, limit: 100 });
    assert.ok(
      audit.some((entry) => entry.capability === "network" && ["approved", "approved_once", "auto"].includes(entry.decision)),
      "network access must go through the authorization layer",
    );
    assert.ok(
      audit.some((entry) => entry.capability === "filesystem" && entry.decision === "auto"),
      "workspace mode may auto-allow in-root file writes",
    );
    assert.ok(!audit.some((entry) => entry.decision === "denied"));
  });

  it("D: keeps one conversation and its history across two runs", async () => {
    const root = tempProject("continuity");
    const { opened, conversation } = await projectConversation(root, "Native continuity");
    const workflow = projectWorkflow(
      "Native Phase17 Continuity",
      opened.project.projectId,
      "mock-agent",
      "workspace",
      "",
    );
    const first = await startRun(workflow, conversation.conversationId, "First task.", "workspace");
    const firstDetail = await approvePersistedInteractions(first);
    assert.equal(firstDetail.run.status, "completed");
    const second = await startRun(workflow, conversation.conversationId, "Second task.", "workspace");
    const secondDetail = await approvePersistedInteractions(second);
    assert.equal(secondDetail.run.status, "completed");
    assert.notEqual(first, second);

    const messages = await invoke("conversation_messages", {
      conversationId: conversation.conversationId,
    });
    assert.deepEqual(messages.map((message) => message.role), ["user", "assistant", "user", "assistant"]);
    assert.equal(messages[0].content, "First task.");
    assert.equal(messages[2].content, "Second task.");
    assert.notEqual(messages[0].runId, messages[2].runId);
    assert.ok(messages.every((message) => message.conversationId === conversation.conversationId));
    const conversations = await invoke("conversation_list", {
      projectId: opened.project.projectId,
      limit: 20,
    });
    assert.equal(conversations.length, 1, "two runs must not fork into two sessions");
  });

  it("E: rejects a workflow that points at a project outside the session catalog", async () => {
    const own = tempProject("own");
    const other = tempProject("other");
    const otherOpened = await invoke("project_open", { root: other });
    const { conversation } = await projectConversation(own, "Native isolation");
    const workflow = projectWorkflow(
      "Native Phase17 Isolation",
      otherOpened.project.projectId,
      "mock-agent",
      "workspace",
      "",
    );
    const runId = await startRun(workflow, conversation.conversationId, "This must not cross projects.", "workspace");
    const detail = await waitForRun(runId);
    assert.equal(detail.run.status, "failed");
    const failure = detail.events.find((event) => event.type === "node.failed");
    assert.ok(failure, JSON.stringify(detail.events));
    assert.equal(failure.nodeId, "project");
    assert.equal(failure.code, "workspace.not_found");
  });

  it("F: auto-allows routine work in YOLO and audits every decision", async () => {
    const root = tempProject("yolo");
    const { opened, conversation } = await projectConversation(root, "Native yolo");
    const workflow = projectWorkflow(
      "Native Phase17 Yolo",
      opened.project.projectId,
      "mock-coder",
      "yolo",
      "read_file,write_file",
    );
    const runId = await startRun(workflow, conversation.conversationId, "Implement it without prompts.", "yolo");
    const detail = await waitForRun(runId);
    assert.equal(detail.run.status, "completed");
    assert.equal(fs.readFileSync(path.join(root, "company-demo", "feature.txt"), "utf8"), "v1");
    const audit = await invoke("permission_audit", { runId, limit: 100 });
    assert.ok(audit.some((entry) => entry.capability === "network" && entry.decision === "auto"));
    assert.ok(audit.some((entry) => entry.capability === "filesystem" && entry.decision === "auto"));
    assert.ok(audit.every((entry) => entry.mode === "yolo"));
  });
});
