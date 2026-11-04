import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

const desktopDir = path.dirname(new URL(import.meta.url).pathname);
const repoRoot = path.resolve(desktopDir, "../..");
const appBinary = path.join(repoRoot, "target/debug/lingxi-desktop");
const runStamp = new Date().toISOString().replace(/[:.]/g, "-");
const dataDir = path.join(desktopDir, ".tmp", "wdio-data-" + runStamp);
const logDir = path.join(desktopDir, ".tmp", "wdio-logs-" + runStamp);
fs.mkdirSync(dataDir, { recursive: true });
fs.mkdirSync(logDir, { recursive: true });

const LLM_PORT = 11434;
let llmServer;

function writeSse(response, events) {
  for (const event of events) {
    response.write("data: " + JSON.stringify(event) + "\n\n");
  }
  response.end();
}

function openAiChat(response, payload) {
  const hasToolResult = Array.isArray(payload.messages)
    && payload.messages.some((message) => message?.role === "tool");
  const wantsTool = payload.model === "mock-calculator" && !hasToolResult;
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
  });
  const send = (value) => response.write("data: " + JSON.stringify(value) + "\n\n");
  const base = {
    id: "chatcmpl-lingxi-e2e",
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model: payload.model || "e2e-tool-model",
  };
  if (wantsTool) {
    send({
      ...base,
      choices: [{
        index: 0,
        delta: {
          role: "assistant",
          tool_calls: [{
            index: 0,
            id: "call_lingxi_e2e",
            type: "function",
            function: {
              name: "calculator",
              arguments: JSON.stringify({ expression: "128 * 256" }),
            },
          }],
        },
        finish_reason: null,
      }],
    });
    send({
      ...base,
      choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }],
      usage: { prompt_tokens: 64, completion_tokens: 8, total_tokens: 72 },
    });
  } else if (hasToolResult) {
    send({
      ...base,
      choices: [{ index: 0, delta: { role: "assistant", content: "The answer is " }, finish_reason: null }],
    });
    send({
      ...base,
      choices: [{ index: 0, delta: { content: "32768." }, finish_reason: null }],
    });
    send({
      ...base,
      choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
      usage: { prompt_tokens: 96, completion_tokens: 6, total_tokens: 102 },
    });
  } else {
    send({
      ...base,
      choices: [{ index: 0, delta: { role: "assistant", content: "Mock OpenAI Chat accepted." }, finish_reason: null }],
    });
    send({
      ...base,
      choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
      usage: { prompt_tokens: 48, completion_tokens: 5, total_tokens: 53 },
    });
  }
  response.write("data: [DONE]\n\n");
  response.end();
}

function openAiResponses(response, payload) {
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
  });
  writeSse(response, [
    {
      type: "response.created",
      response: { id: "resp-lingxi-e2e", status: "in_progress", model: payload.model || "gpt-5" },
    },
    {
      type: "response.output_text.delta",
      item_id: "msg-lingxi-e2e",
      output_index: 0,
      content_index: 0,
      delta: "Mock OpenAI Responses accepted.",
    },
    {
      type: "response.completed",
      response: {
        id: "resp-lingxi-e2e",
        status: "completed",
        model: payload.model || "gpt-5",
        usage: { input_tokens: 48, output_tokens: 5, total_tokens: 53 },
        output: [],
      },
    },
  ]);
}

function anthropicMessages(response, payload) {
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
  });
  writeSse(response, [
    {
      type: "message_start",
      message: {
        id: "msg-lingxi-e2e",
        type: "message",
        role: "assistant",
        model: payload.model || "claude-sonnet-4-5",
        usage: { input_tokens: 48, output_tokens: 1 },
      },
    },
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text: "Mock Anthropic Messages accepted." },
    },
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "end_turn" },
      usage: { output_tokens: 6 },
    },
    { type: "message_stop" },
  ]);
}

/**
 * Deterministic multi-protocol LLM endpoint. Each route is an explicit wire
 * format mock; the OpenAI Chat route also serves the tool-loop Agent tests.
 * Nothing here is a model provider: it only proves Rust adapters and loops.
 */
function startLlmMock() {
  const server = http.createServer((request, response) => {
    if (request.method !== "POST") {
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: "not found" } }));
      return;
    }
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => {
      let payload = {};
      try {
        payload = JSON.parse(body || "{}");
      } catch {
        payload = {};
      }
      const url = request.url || "";
      if (url.endsWith("/chat/completions")) {
        openAiChat(response, payload);
      } else if (url.endsWith("/responses")) {
        openAiResponses(response, payload);
      } else if (url.endsWith("/messages")) {
        anthropicMessages(response, payload);
      } else {
        response.writeHead(404, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: { message: "not found" } }));
      }
    });
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(LLM_PORT, "127.0.0.1", () => resolve(server));
  });
}

export const config = {
  runner: "local",
  specs: ["./e2e/tauri/**/*.spec.mjs"],
  maxInstances: 1,
  capabilities: [{
    browserName: "tauri",
    "tauri:options": { application: appBinary },
  }],
  services: [[
    "@wdio/tauri-service",
    {
      driverProvider: "embedded",
      appBinaryPath: appBinary,
      env: {
        ...process.env,
        LINGXI_DATA_DIR: dataDir,
        OPENAI_API_KEY: process.env.OPENAI_API_KEY || "sk-e2e-local",
        RUST_BACKTRACE: "1",
      },
      captureBackendLogs: true,
      captureFrontendLogs: true,
      logDir,
      startTimeout: 120000,
    },
  ]],
  logLevel: "info",
  waitforTimeout: 15000,
  connectionRetryTimeout: 180000,
  connectionRetryCount: 1,
  framework: "mocha",
  reporters: ["spec"],
  mochaOpts: { ui: "bdd", timeout: 240000 },
  onPrepare: async () => {
    llmServer = await startLlmMock();
    console.log("mock LLM listening on http://127.0.0.1:" + LLM_PORT + "/v1 (chat/responses/messages)");
    console.log("tauri data dir: " + dataDir);
  },
  onComplete: async () => {
    if (llmServer) {
      await new Promise((resolve) => llmServer.close(resolve));
      llmServer = undefined;
    }
  },
};
