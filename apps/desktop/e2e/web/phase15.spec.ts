import path from "node:path";

import { expect, test, type Locator, type Page } from "@playwright/test";

const FIXTURES = path.resolve(process.cwd(), "e2e/fixtures");

async function ready(page: Page) {
  await page.addInitScript(() => window.localStorage.setItem("lingxi.view", "canvas"));
  await page.goto("/");
  await expect(page.getByTestId("canvas")).toBeVisible();
  await expect(page.locator('[data-testid^="library-item-"]').first()).toBeVisible();
}

async function addAt(page: Page, kind: string, x: number, y: number): Promise<Locator> {
  const before = await page.locator(".react-flow__node").count();
  await page.getByTestId("library-item-" + kind).click();
  await expect(page.locator(".react-flow__node")).toHaveCount(before + 1);
  const node = page.locator('[data-node-kind="' + kind + '"]').last();
  const header = node.locator(".node__header");
  const box = await header.boundingBox();
  if (!box) throw new Error("node header is not visible");
  await page.mouse.move(box.x + 40, box.y + 12);
  await page.mouse.down();
  await page.mouse.move(x, y, { steps: 10 });
  await page.mouse.up();
  await page.waitForTimeout(100);
  return node;
}

async function connect(page: Page, source: Locator, target: Locator) {
  const from = await source.boundingBox();
  const to = await target.boundingBox();
  if (!from || !to) throw new Error("handle is not visible");
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
  await page.mouse.down();
  await page.mouse.move(from.x + 26, from.y + 16, { steps: 4 });
  await page.waitForTimeout(50);
  await page.mouse.move(to.x + to.width / 2, to.y + to.height / 2, { steps: 20 });
  await page.mouse.up();
}

async function addAsset(node: Locator, file: string) {
  await node.locator('[data-testid^="asset-file-"]').setInputFiles(path.join(FIXTURES, file));
  await expect(node.locator(".asset").first()).toBeVisible();
}

test.describe("LingXiAgent Phase 1.5 node library and multimodal UI", () => {
  test("collapses the node library to a rail and restores it", async ({ page }) => {
    await ready(page);
    await page.getByTestId("library-toggle").click();
    await expect(page.getByTestId("library")).toHaveClass(/library--rail/);
    await expect(page.getByTestId("library-search")).toHaveCount(0);
    await page.getByTestId("library-toggle").click();
    await expect(page.getByTestId("library-search")).toBeVisible();
  });

  test("remembers collapsed categories across a reload", async ({ page }) => {
    await ready(page);
    await page.getByTestId("library-group-input-media").locator(".library__group-head").click();
    await expect(page.getByTestId("library-item-core.input.image")).toHaveCount(0);
    await page.reload();
    await expect(page.getByTestId("canvas")).toBeVisible();
    await expect(page.getByTestId("library-item-core.input.image")).toHaveCount(0);
    await page.getByTestId("library-expand-all").click();
    await expect(page.getByTestId("library-item-core.input.image")).toBeVisible();
  });

  test("shows Chinese categories, node names, descriptions and port labels", async ({ page }) => {
    await ready(page);
    await expect(page.getByTestId("library-group-model-protocol")).toContainText("模型与协议");
    const item = page.getByTestId("library-item-core.model");
    await expect(item).toContainText("模型调用");
    await expect(item.locator(".library__item-desc")).toContainText("统一模型运行时");
    const node = await addAt(page, "core.model", 430, 220);
    await expect(node.locator(".node__title")).toContainText("模型调用");
    await expect(node.locator(".port__label").filter({ hasText: "服务提供方" })).toBeVisible();
  });

  test("searches in Chinese and English and auto-expands matches", async ({ page }) => {
    await ready(page);
    await page.getByTestId("library-group-input-media").locator(".library__group-head").click();
    await expect(page.getByTestId("library-item-core.input.image")).toHaveCount(0);
    await page.getByTestId("library-search").fill("图片");
    await expect(page.getByTestId("library-item-core.input.image")).toBeVisible();
    await page.getByTestId("library-search").fill("image");
    await expect(page.getByTestId("library-item-core.input.image")).toBeVisible();
    await page.getByTestId("library-search").fill("");
    await expect(page.getByTestId("library-item-core.input.image")).toHaveCount(0);
  });

  test("offers all three provider protocol nodes", async ({ page }) => {
    await ready(page);
    await addAt(page, "core.provider.openai_chat", 360, 190);
    await addAt(page, "core.provider.openai_responses", 660, 190);
    await addAt(page, "core.provider.anthropic_messages", 960, 190);
    await expect(page.locator('[data-node-kind="core.provider.openai_chat"]')).toHaveCount(1);
    await expect(page.locator('[data-node-kind="core.provider.openai_responses"]')).toHaveCount(1);
    await expect(page.locator('[data-node-kind="core.provider.anthropic_messages"]')).toHaveCount(1);
  });

  test("connects a reasoning node to the model", async ({ page }) => {
    await ready(page);
    const provider = await addAt(page, "core.provider.openai_chat", 300, 170);
    const model = await addAt(page, "core.model", 610, 170);
    const reasoning = await addAt(page, "core.reasoning", 610, 430);
    await connect(
      page,
      provider.locator('[data-testid^="handle-out-"][data-testid$="-provider"]'),
      model.locator('[data-testid^="handle-in-"][data-testid$="-provider"]'),
    );
    await connect(
      page,
      reasoning.locator('[data-testid^="handle-out-"][data-testid$="-config"]'),
      model.locator('[data-testid^="handle-in-"][data-testid$="-reasoning"]'),
    );
    await expect(page.locator(".react-flow__edge")).toHaveCount(2);
    await expect(page.getByTestId("log-line").filter({ hasText: "connected" })).toHaveCount(0);
  });

  test("shows model capability state from the connected provider", async ({ page }) => {
    await ready(page);
    const provider = await addAt(page, "core.provider.openai_chat", 300, 170);
    const model = await addAt(page, "core.model", 640, 170);
    await connect(
      page,
      provider.locator('[data-testid^="handle-out-"][data-testid$="-provider"]'),
      model.locator('[data-testid^="handle-in-"][data-testid$="-provider"]'),
    );
    await model.getByTestId(/^param-.*-model$/).fill("gpt-4o");
    const caps = model.getByTestId("model-capabilities");
    await expect(caps).toContainText("模型能力");
    await expect(caps.locator('[title="输入 · 图片 · 原生"]')).toBeVisible();
    await expect(caps.locator('[title="工具 · 原生"]')).toBeVisible();
  });

  test("imports and previews an image", async ({ page }) => {
    await ready(page);
    const node = await addAt(page, "core.input.image", 440, 200);
    await addAsset(node, "sample.png");
    await expect(node.locator(".asset__name")).toHaveText("sample.png");
    await expect(node.locator(".asset img")).toBeVisible();
  });

  test("imports and previews audio", async ({ page }) => {
    await ready(page);
    const node = await addAt(page, "core.input.audio", 440, 200);
    await addAsset(node, "sample.wav");
    await expect(node.locator(".asset__name")).toHaveText("sample.wav");
    await expect(node.locator("audio")).toBeVisible();
  });

  test("imports video and edits frame sampling settings", async ({ page }) => {
    await ready(page);
    const node = await addAt(page, "core.input.video", 440, 200);
    await addAsset(node, "sample.mp4");
    await expect(node.locator("video")).toBeVisible();
    await expect(node.getByTestId(/^param-.*-mode$/).locator("option")).toHaveCount(2);
    await node.getByTestId(/^param-.*-frameIntervalMs$/).fill("500");
    await node.getByTestId(/^param-.*-maxFrames$/).fill("4");
    await expect(node.getByTestId(/^param-.*-frameIntervalMs$/)).toHaveValue("500");
    await expect(node.getByTestId(/^param-.*-maxFrames$/)).toHaveValue("4");
  });

  test("imports and previews a document", async ({ page }) => {
    await ready(page);
    const node = await addAt(page, "core.input.document", 440, 200);
    await addAsset(node, "sample.pdf");
    await expect(node.locator(".asset__name")).toHaveText("sample.pdf");
    await expect(node.locator(".asset__doc")).toHaveText("DOC");
    await expect(node.getByTestId(/^param-.*-mode$/)).toHaveValue("extracted");
  });

  test("saves, reloads and restores multimodal asset references", async ({ page }) => {
    await ready(page);
    await page.getByTestId("workflow-name").fill("E2E 多模态流程");
    const image = await addAt(page, "core.input.image", 400, 200);
    const audio = await addAt(page, "core.input.audio", 780, 200);
    await addAsset(image, "sample.png");
    await addAsset(audio, "sample.wav");
    await page.getByTestId("toolbar-save").click();
    await expect(page.getByTestId("log-line").filter({ hasText: "saved E2E 多模态流程" })).toBeVisible();
    await page.getByTestId("toolbar-new").click();
    await page.getByTestId("confirm-accept").click();
    await expect(page.locator(".react-flow__node")).toHaveCount(0);
    await page.getByTestId("toolbar-open").click();
    await page.getByTestId("workflow-load-E2E 多模态流程").click();
    await expect(page.locator(".react-flow__node")).toHaveCount(2);
    await expect(page.getByText("sample.png", { exact: true })).toBeVisible();
    await expect(page.getByText("sample.wav", { exact: true })).toBeVisible();
  });

  test("rejects an incompatible modality connection with a visible error", async ({ page }) => {
    await ready(page);
    const image = await addAt(page, "core.input.image", 380, 200);
    const upper = await addAt(page, "core.text_uppercase", 760, 200);
    await connect(
      page,
      image.locator('[data-testid^="handle-out-"][data-testid$="-parts"]'),
      upper.locator('[data-testid^="handle-in-"][data-testid$="-text"]'),
    );
    await expect(page.locator(".toast")).toContainText("端口类型不兼容");
    await expect(page.locator(".react-flow__edge")).toHaveCount(0);
  });

  test("refreshes the capability panel after the model parameter changes", async ({ page }) => {
    await ready(page);
    const provider = await addAt(page, "core.provider.openai_chat", 300, 170);
    const model = await addAt(page, "core.model", 640, 170);
    await connect(
      page,
      provider.locator('[data-testid^="handle-out-"][data-testid$="-provider"]'),
      model.locator('[data-testid^="handle-in-"][data-testid$="-provider"]'),
    );
    const caps = model.getByTestId("model-capabilities");
    await expect(caps.locator('[title="输入 · 图片 · 未知"]')).toBeVisible();
    await model.getByTestId(/^param-.*-model$/).fill("gpt-4o");
    await expect(caps.locator('[title="输入 · 图片 · 原生"]')).toBeVisible();
  });
});
