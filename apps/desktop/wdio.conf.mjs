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

function lastToolResult(messages) {
  for (const message of [...messages].reverse()) {
    if (message?.role !== "tool") continue;
    try {
      return JSON.parse(String(message.content ?? "{}"));
    } catch {
      return null;
    }
  }
  return null;
}

function companyMessageText(messages) {
  return messages
    .filter((message) => ["system", "user", "tool"].includes(message?.role))
    .map((message) => String(message.content ?? ""))
    .join("\n");
}

/**
 * Deterministic company models for the native PM -> Coder -> Tester rework
 * scenario. They speak the same OpenAI Chat tool-call wire format as the
 * Python fixture used by Rust tests, but live in this process so the Tauri E2E
 * run needs no external interpreter.
 */
function companyToolCall(model, messages) {
  const last = lastToolResult(messages);
  const toolName = last?.name;
  const text = companyMessageText(messages).toLowerCase();
  const submit = (payload) => ({
    name: "submit_result",
    arguments: payload,
  });
  if (["mock-agent", "mock-agent-slow", "mock-agent-tool", "mock-agent-slow-tool", "mock-vision"].includes(model)) {
    if (["mock-agent-tool", "mock-agent-slow-tool"].includes(model) && last?.name !== "calculator") {
      return { name: "calculator", arguments: { expression: "6 * 7" } };
    }
    const answer = last?.result?.value ?? "none";
    const slowTool = model === "mock-agent-slow-tool";
    return submit({
      status: "completed",
      agentMessage: {
        summary: slowTool ? "slow tool agent" : "agent completed",
        value: String(answer),
      },
      userResponse: slowTool ? "Slow tool agent completed." : "Agent completed the task.",
      artifacts: [],
    });
  }
  if (model === "mock-pm") {
    return submit({
      status: "completed",
      agentMessage: {
        summary: "PRD ready",
        requirements: ["feature flag", "unit test"],
      },
      userResponse: "PRD: implement the feature flag with a unit test.",
      artifacts: [],
    });
  }
  if (model === "mock-coder") {
    const path = "company-demo/feature.txt";
    if (toolName === "write_file") {
      return submit({
        status: "completed",
        agentMessage: {
          summary: "implementation delivered",
          path,
          revision: text.includes("tests failed") || text.includes("v2") ? "v2" : "v1",
        },
        userResponse: "Implementation delivered for review.",
        artifacts: [],
      });
    }
    if (toolName === "read_file") {
      const snapshot = last?.result ?? {};
      return {
        name: "write_file",
        arguments: {
          path,
          content: "v2",
          expectedVersion: snapshot.version ?? "absent",
        },
      };
    }
    if (text.includes("tests failed")) {
      return { name: "read_file", arguments: { path } };
    }
    return {
      name: "write_file",
      arguments: { path, content: "v1", expectedVersion: "absent" },
    };
  }
  if (model === "mock-tester-pass") {
    return submit({
      status: "completed",
      agentMessage: { summary: "tests passed", verdict: "pass" },
      userResponse: "Tests passed on the first attempt.",
      artifacts: [],
    });
  }
  if (model === "mock-tester") {
    const path = "company-demo/feature.txt";
    if (toolName !== "read_file") {
      return { name: "read_file", arguments: { path } };
    }
    const content = String(last?.result?.content ?? "").trim();
    if (content === "v1") {
      return submit({
        status: "failed",
        agentMessage: {
          summary: "tests failed",
          verdict: "fail",
          reason: "feature is still revision 1",
        },
        userResponse: "Tests failed: the feature never changed; send it back for rework.",
        artifacts: [],
      });
    }
    return submit({
      status: "completed",
      agentMessage: { summary: "tests passed", verdict: "pass" },
      userResponse: "Tests passed; the feature is ready for delivery.",
      artifacts: [],
    });
  }
  return null;
}

async function openAiChat(response, payload) {
  // Match the Rust fixture's slow models so a native test can pause or refresh
  // while a model call is genuinely in flight.
  if (["mock-slow", "mock-agent-slow", "mock-agent-slow-tool"].includes(payload.model)) {
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  const messages = Array.isArray(payload.messages) ? payload.messages : [];
  const hasToolResult = messages.some((message) => message?.role === "tool");
  const wantsTool = payload.model === "mock-calculator" && !hasToolResult;
  const companyCall = companyToolCall(payload.model, messages);
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
  if (companyCall) {
    send({
      ...base,
      choices: [{
        index: 0,
        delta: {
          role: "assistant",
          tool_calls: [{
            index: 0,
            id: "call_lingxi_company",
            type: "function",
            function: {
              name: companyCall.name,
              arguments: JSON.stringify(companyCall.arguments),
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
  } else if (wantsTool) {
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
    // Native recovery tests restart the app themselves and need the exact same
    // binary and data directory as the embedded WebDriver instance.
    process.env.LINGXI_E2E_APP_BINARY = appBinary;
    process.env.LINGXI_E2E_DATA_DIR = dataDir;
    llmServer = await startLlmMock();
    console.log("mock LLM listening on http://127.0.0.1:" + LLM_PORT + "/v1 (chat/responses/messages)");
    console.log("tauri data dir: " + dataDir);
  },
  onComplete: async () => {
    // A recovery test relaunches the app outside the service on purpose. Stop
    // that process after WebDriver teardown so no test window is left behind.
    const pidFile = path.join(dataDir, "recovered-app.pid");
    if (fs.existsSync(pidFile)) {
      const pid = Number(fs.readFileSync(pidFile, "utf8").trim());
      if (Number.isInteger(pid) && pid > 0) {
        try {
          process.kill(pid, "SIGTERM");
        } catch {
          // Already exited.
        }
      }
    }
    if (llmServer) {
      await new Promise((resolve) => llmServer.close(resolve));
      llmServer = undefined;
    }
  },
};
