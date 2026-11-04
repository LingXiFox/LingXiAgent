import assert from "node:assert/strict";
import path from "node:path";

const FIXTURES = path.resolve(process.cwd(), "e2e/fixtures");
const BASE_URL = "http://127.0.0.1:11434";
const PROVIDERS = [
  {
    label: "OpenAI Chat",
    kind: "core.provider.openai_chat",
    protocol: "openai_chat",
    baseUrl: BASE_URL + "/v1",
    providerId: "e2e-openai-chat",
    model: "gpt-5",
    expected: "Mock OpenAI Chat accepted.",
  },
  {
    label: "OpenAI Responses",
    kind: "core.provider.openai_responses",
    protocol: "openai_responses",
    baseUrl: BASE_URL + "/v1",
    providerId: "e2e-openai-responses",
    model: "gpt-5",
    expected: "Mock OpenAI Responses accepted.",
  },
  {
    label: "Anthropic Messages",
    kind: "core.provider.anthropic_messages",
    protocol: "anthropic_messages",
    baseUrl: BASE_URL,
    providerId: "e2e-anthropic",
    model: "claude-sonnet-4-5",
    expected: "Mock Anthropic Messages accepted.",
  },
];
let assets;

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
}

async function waitForCounts(fragment, timeout = 15000) {
  await browser.waitUntil(async () => {
    const text = await $(".toolbar__counts").getText();
    return text.includes(fragment);
  }, { timeout, interval: 100, timeoutMsg: "toolbar counts did not contain: " + fragment });
}

async function waitForRunning(name, timeout = 15000) {
  await browser.waitUntil(async () => {
    const runs = await invoke("run_list", { limit: 50 });
    const run = runs.find((item) => item.workflowName === name);
    if (!run) return false;
    const detail = await invoke("run_detail", { runId: run.runId });
    return detail?.run?.status === "running";
  }, { timeout, interval: 100, timeoutMsg: "run " + name + " did not start" });
  const runs = await invoke("run_list", { limit: 50 });
  return runs.find((item) => item.workflowName === name);
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
      await invoke("respond_interaction", {
        requestId: event.requestId,
        approved: true,
      });
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

async function importAsset(name, kind) {
  const asset = await invoke("asset_import", {
    path: path.join(FIXTURES, name),
    kind,
  });
  assert.ok(asset?.id, "asset_import must return an asset id for " + name);
  assert.equal(asset.kind, kind, "asset kind must match the import request");
  return asset;
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

function node(id, kind, label, x, y, params = {}) {
  return {
    id,
    kind,
    label,
    position: { x, y },
    params,
    enabled: true,
  };
}

function multimodalWorkflow(variant, name) {
  const nodes = [
    node("e2e-prompt", "core.prompt", "Prompt", 40, 40, {
      system: "Answer from the supplied multimodal context.",
      user: "Describe the attached media briefly.",
      variables: "{}",
    }),
    node("e2e-text", "core.text_input", "Text", 40, 220, {
      text: "Please describe the attached media in one sentence.",
    }),
    node("e2e-image", "core.input.image", "Image", 40, 400, {
      assets: [assets.image.id],
      maxDimension: 0,
      detail: "auto",
    }),
    node("e2e-audio", "core.input.audio", "Audio", 40, 580, {
      assets: [assets.audio.id],
      mode: "transcribed",
      transcript: "LingXi audio sample says hello.",
    }),
    node("e2e-video", "core.input.video", "Video", 40, 760, {
      assets: [assets.video.id],
      mode: "frames",
      frameIntervalMs: 500,
      maxFrames: 4,
      startMs: 0,
      endMs: 0,
    }),
    node("e2e-document", "core.input.document", "Document", 40, 940, {
      assets: [assets.pdf.id, assets.docx.id],
      mode: "extracted",
    }),
    node("e2e-context", "core.context", "Context", 360, 520, {
      maxMessages: 40,
      maxTokens: 12000,
      partOrder: "image,audio,video,document,text",
      overflow: "trim_oldest",
    }),
    node("e2e-reasoning", "core.reasoning", "Reasoning", 680, 520, {
      level: "high",
    }),
    node("e2e-model", "core.model", "Model", 980, 520, {
      model: variant.model,
      temperature: 0.2,
      maxTokens: 16384,
      reasoningEffort: "none",
      stream: true,
      capabilities: "{}",
      timeoutMs: 30000,
      maxCalls: 2,
      maxTotalTokens: 0,
    }),
    node("e2e-log", "core.log", "Log", 1280, 520, {
      prefix: "multimodal: ",
    }),
  ];

  // All three protocol nodes exist in the same workflow. Only the active one
  // feeds the model; this proves protocol selection is data-driven, not a
  // different model node per protocol.
  for (const [index, provider] of PROVIDERS.entries()) {
    nodes.push(node(
      "e2e-provider-" + provider.protocol,
      provider.kind,
      provider.label,
      680,
      60 + index * 130,
      {
        providerId: provider.providerId,
        baseUrl: provider.baseUrl,
        credentialRef: "env:OPENAI_API_KEY",
        organization: "",
        supportsReasoning: true,
        protocol: provider.protocol,
        capabilities: "{}",
      },
    ));
  }

  const edges = [
    edge("e2e-prompt", "done", "e2e-image", "run", "control"),
    edge("e2e-image", "done", "e2e-audio", "run", "control"),
    edge("e2e-audio", "done", "e2e-video", "run", "control"),
    edge("e2e-video", "done", "e2e-document", "run", "control"),
    edge("e2e-document", "done", "e2e-context", "run", "control"),
    edge("e2e-context", "done", "e2e-reasoning", "run", "control"),
    edge("e2e-reasoning", "done", "e2e-model", "run", "control"),
    edge("e2e-model", "done", "e2e-log", "run", "control"),
    edge("e2e-prompt", "messages", "e2e-context", "messages"),
    edge("e2e-image", "parts", "e2e-context", "image"),
    edge("e2e-audio", "parts", "e2e-context", "audio"),
    edge("e2e-video", "parts", "e2e-context", "video"),
    edge("e2e-document", "parts", "e2e-context", "document"),
    edge("e2e-text", "text", "e2e-context", "text"),
    edge("e2e-context", "context", "e2e-model", "context"),
    edge("e2e-reasoning", "config", "e2e-model", "reasoning"),
    edge("e2e-provider-" + variant.protocol, "provider", "e2e-model", "provider"),
    edge("e2e-model", "text", "e2e-log", "value"),
  ];

  return {
    schemaVersion: "1.2",
    id: "wf-phase15-" + variant.protocol,
    name,
    description: "Phase 1.5 native E2E: " + variant.label + " multimodal Agent input",
    nodes,
    edges,
    viewport: { x: 20, y: 20, zoom: 0.55 },
    assets: Object.fromEntries(
      Object.values(assets).map((asset) => [asset.id, asset]),
    ),
  };
}

describe("LingXiAgent native multimodal provider E2E", () => {
  before(async () => {
    await $('[data-testid="canvas"]').waitForDisplayed({ timeout: 120000 });
    await waitForLog("node catalog ready", 60000);
    assets = {
      image: await importAsset("sample.png", "image"),
      audio: await importAsset("sample.wav", "audio"),
      video: await importAsset("sample.mp4", "video"),
      pdf: await importAsset("sample.pdf", "document"),
      docx: await importAsset("sample.docx", "document"),
    };
  });

  for (const variant of PROVIDERS) {
    it("runs " + variant.label + " with image, audio, video frames, documents and reasoning", async () => {
      const name = "LingXi E2E Multimodal " + variant.label;
      const workflow = multimodalWorkflow(variant, name);
      assert.equal(workflow.nodes.length, 13);
      assert.equal(workflow.edges.length, 18);
      assert.equal(Object.keys(workflow.assets).length, 5);

      const saved = await invoke("save_workflow", { name, workflow });
      assert.equal(saved.name, name);
      assert.equal(saved.nodeCount, 13);

      const loaded = await invoke("load_workflow", { name });
      assert.equal(loaded.schemaVersion, "1.2");
      assert.equal(Object.keys(loaded.assets).length, 5, "asset refs must round-trip");
      const documentNode = loaded.nodes.find((item) => item.id === "e2e-document");
      assert.deepEqual(documentNode.params.assets.sort(), [assets.docx.id, assets.pdf.id].sort());
      assert.equal(
        loaded.edges.find((item) => item.target === "e2e-model" && item.targetPort === "reasoning").source,
        "e2e-reasoning",
      );

      await openSaved(name);
      await waitForCounts("13 节点 · 18 连线");
      // The imported assets are visible as real references after a reload,
      // not as base64 blobs inside the workflow JSON.
      for (const [nodeId, asset] of [
        ["e2e-image", assets.image],
        ["e2e-audio", assets.audio],
        ["e2e-video", assets.video],
        ["e2e-document", assets.pdf],
        ["e2e-document", assets.docx],
      ]) {
        assert.ok(
          await $('[data-testid="asset-' + nodeId + '-' + asset.id + '"]').isExisting(),
          "asset card must be restored for " + nodeId + "/" + asset.name,
        );
      }

      await $('[data-testid="toolbar-run"]').click();
      await waitForLog("waiting for approval", 30000);
      const run = await waitForRunning(name);
      await approvePersistedInteractions(run.runId);
      await waitForLog(variant.expected, 60000);

      const detail = await invoke("run_detail", { runId: run.runId });
      assert.equal(detail.run.status, "completed");
      assert.equal(detail.run.nodeCount, 13);
      const terminal = detail.events.filter((event) => event.type === "run.finished");
      assert.equal(terminal.length, 1, "exactly one terminal event");
      assert.equal(terminal[0].status, "completed");

      const finishedByKind = (kind) => detail.events.filter(
        (event) => event.type === "node.finished" && event.kind === kind,
      );
      const modelEvents = finishedByKind("core.model");
      assert.equal(modelEvents.length, 1, "model must finish once");
      assert.match(modelEvents[0].outputs.text, new RegExp(variant.expected.replace(".", "\\.")));
      assert.equal(finishedByKind("core.reasoning").length, 1, "reasoning config node must execute");
      assert.equal(finishedByKind("core.context").length, 1, "context node must execute");
      assert.equal(finishedByKind("core.input.image").length, 1);
      assert.equal(finishedByKind("core.input.audio").length, 1);
      assert.equal(finishedByKind("core.input.video").length, 1);
      assert.equal(finishedByKind("core.input.document").length, 1);

      const videoEvent = finishedByKind("core.input.video")[0];
      assert.ok(Array.isArray(videoEvent.outputs.frames), "video frames must be persisted");
      assert.ok(videoEvent.outputs.frames.length >= 1, "video frame extraction must produce frames");
      const documentEvent = finishedByKind("core.input.document")[0];
      assert.match(documentEvent.outputs.text, /LingXi sample page one/);
      assert.match(documentEvent.outputs.text, /LingXi document sample/);
      const audioEvent = finishedByKind("core.input.audio")[0];
      assert.match(audioEvent.outputs.summary, /sample\.wav/);
      const contextEvent = finishedByKind("core.context")[0];
      assert.ok(Array.isArray(contextEvent.outputs.parts));
      assert.ok(contextEvent.outputs.parts.length >= 5, "context must receive every media part plus text");
      assert.ok(
        detail.events.some((event) => event.type === "model.delta"),
        "the real streaming path must emit deltas",
      );

      // Reload again after execution: workflow, assets and run history remain
      // independently addressable.
      await openSaved(name);
      await waitForCounts("13 节点 · 18 连线");
      const reloaded = await invoke("load_workflow", { name });
      assert.equal(Object.keys(reloaded.assets).length, 5);
      const runs = await invoke("run_list", { limit: 50 });
      assert.equal(runs.filter((item) => item.workflowName === name).length, 1);
      const past = await invoke("run_detail", { runId: run.runId });
      assert.equal(past.events.filter((event) => event.type === "run.finished").length, 1);
      assert.equal(new Set(past.events.map((event) => event.seq)).size, past.events.length);
    });
  }
});
