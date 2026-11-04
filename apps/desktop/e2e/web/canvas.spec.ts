import { expect, test, type Locator, type Page } from "@playwright/test";

async function ready(page: Page) {
  await page.goto("/");
  await expect(page.getByTestId("canvas")).toBeVisible();
  await expect(page.locator('[data-testid^="library-item-"]').first()).toBeVisible();
  await expect(page.getByTestId("log-panel")).toBeVisible();
}

async function addNode(page: Page, kind: string): Promise<Locator> {
  const before = await page.locator(".react-flow__node").count();
  await page.getByTestId("library-item-" + kind).click();
  await expect(page.locator(".react-flow__node")).toHaveCount(before + 1);
  return page.locator('[data-node-kind="' + kind + '"]').last();
}


async function place(page: Page, node: Locator, x: number, y: number) {
  const header = node.locator(".node__header");
  const box = await header.boundingBox();
  if (!box) throw new Error("node header is not visible");
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(x, y, { steps: 10 });
  await page.mouse.up();
  await page.waitForTimeout(120);
}

async function connect(page: Page, source: Locator, target: Locator) {
  const from = await source.boundingBox();
  const to = await target.boundingBox();
  if (!from || !to) throw new Error("handle is not visible");
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
  await page.mouse.down();
  await page.mouse.move(from.x + 28, from.y + 18, { steps: 4 });
  await page.waitForTimeout(60);
  await page.mouse.move(to.x + to.width / 2, to.y + to.height / 2, { steps: 20 });
  // Give React Flow a frame to register the hovered target before releasing.
  // Without it a loaded runner can drop the connection on an empty canvas.
  await page.waitForTimeout(80);
  await page.mouse.up();
  await page.waitForTimeout(80);
}

test.describe("LingXiAgent web canvas", () => {
  test("creates, connects, edits, runs and persists a DAG", async ({ page }) => {
    await ready(page);
    await page.getByTestId("workflow-name").fill("E2E 基础流程");

    const input = await addNode(page, "core.text_input");
    await place(page, input, 390, 180);
    const upper = await addNode(page, "core.text_uppercase");
    await place(page, upper, 700, 180);
    const log = await addNode(page, "core.log");
    await place(page, log, 1000, 180);

    await input.getByTestId(/^param-.*-text$/).fill("hello e2e");

    await connect(
      page,
      input.locator('[data-testid^="handle-out-"]').first(),
      upper.locator('[data-testid^="handle-in-"]').first(),
    );
    await connect(
      page,
      upper.locator('[data-testid^="handle-out-"]').first(),
      log.locator('[data-testid^="handle-in-"]').first(),
    );
    await expect(page.locator(".react-flow__edge")).toHaveCount(2);

    await page.getByTestId("toolbar-save").click();
    await expect(page.getByTestId("log-line").filter({ hasText: "saved E2E 基础流程" })).toBeVisible();

    await page.getByTestId("toolbar-run").click();
    await expect(page.getByTestId("log-line").filter({ hasText: "HELLO E2E" })).toBeVisible();
    await expect(page.getByTestId("log-line").filter({ hasText: "run completed" })).toBeVisible();

    await page.getByTestId("toolbar-new").click();
    await page.getByTestId("confirm-accept").click();
    await expect(page.locator(".react-flow__node")).toHaveCount(0);

    await page.getByTestId("toolbar-open").click();
    await expect(page.getByTestId("workflow-dialog")).toBeVisible();
    await page.getByTestId("workflow-load-E2E 基础流程").click();
    await expect(page.getByTestId("workflow-name")).toHaveValue("E2E 基础流程");
    await expect(page.locator(".react-flow__node")).toHaveCount(3);
    await expect(page.locator(".react-flow__edge")).toHaveCount(2);
  });

  test("moves and deletes a node without per-frame IPC", async ({ page }) => {
    await ready(page);
    const node = await addNode(page, "core.number_input");
    const header = node.locator(".node__header");
    const before = await node.boundingBox();
    if (!before) throw new Error("node not visible");
    const start = await header.boundingBox();
    if (!start) throw new Error("header not visible");
    await page.mouse.move(start.x + 40, start.y + 12);
    await page.mouse.down();
    await page.mouse.move(start.x + 160, start.y + 92, { steps: 12 });
    await page.mouse.up();
    const after = await node.boundingBox();
    expect(after && after.x).toBeGreaterThan(before.x + 40);

    await header.click();
    await page.keyboard.press("Delete");
    await expect(page.locator(".react-flow__node")).toHaveCount(0);
  });

  test("groups, expands, returns and templates a composite", async ({ page }) => {
    await ready(page);
    const input = await addNode(page, "core.text_input");
    await place(page, input, 340, 180);
    const upper = await addNode(page, "core.text_uppercase");
    await place(page, upper, 600, 180);

    await input.locator(".node__header").click();
    const multiKey = process.platform === "darwin" ? "Meta" : "Control";
    await page.keyboard.down(multiKey);
    await upper.locator(".node__header").click();
    await page.keyboard.up(multiKey);
    await expect(page.getByTestId("toolbar-group")).toBeEnabled();
    await page.getByTestId("toolbar-group").click();

    const composite = page.locator('[data-node-kind="core.composite"]').first();
    await expect(composite).toBeVisible();
    await expect(page.locator(".react-flow__node")).toHaveCount(1);

    await composite.locator(".node__header").dblclick();
    await expect(page.getByTestId("canvasbar")).toContainText("组合内部");
    await expect(page.locator(".react-flow__node")).toHaveCount(2);
    await page.getByTestId("crumb-0").click();
    await expect(page.getByTestId("canvasbar")).toContainText("自由画布");

    await composite.locator(".node__header").click();
    await page.getByTestId("toolbar-template").click();
    await expect(page.getByTestId("template-dialog")).toBeVisible();
    await page.getByTestId("template-name").fill("E2E 组合模板");
    await page.getByTestId("template-save").click();
    await expect(page.getByTestId("log-line").filter({ hasText: "saved composite template" })).toBeVisible();
    await expect(page.getByTestId("library-template-E2E 组合模板")).toBeVisible();

    await page.getByTestId("library-template-E2E 组合模板").click();
    await expect(page.locator(".react-flow__node")).toHaveCount(2);
  });

  test("inserts the standard agent template and streams tool events in preview", async ({ page }) => {
    await ready(page);
    await page.getByTestId("toolbar-agent").click();
    const composite = page.locator('[data-node-kind="core.composite"]').first();
    await expect(composite).toBeVisible();
    await page.getByTestId("toolbar-run").click();
    await expect(page.getByTestId("log-line").filter({ hasText: "calculator" })).toBeVisible();
    await expect(page.getByTestId("log-line").filter({ hasText: "32768" }).first()).toBeVisible();
    await expect(
      page.getByTestId("log-line").filter({ hasText: "The answer is 32768." }).first(),
    ).toBeVisible();
    await expect(page.getByTestId("log-line").filter({ hasText: "run completed" })).toBeVisible();
  });

  test("validates and surfaces static errors", async ({ page }) => {
    await ready(page);
    const upper = await addNode(page, "core.text_uppercase");
    await expect(upper).toBeVisible();
    await page.getByTestId("toolbar-validate").click();
    await expect(page.getByTestId("log-line").filter({ hasText: "validation" })).toBeVisible();
  });
});
