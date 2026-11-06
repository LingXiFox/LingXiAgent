import { expect, test, type Page } from "@playwright/test";

async function ready(page: Page) {
  // Seed the advanced canvas only when nothing was chosen yet. A reload after a
  // run must still observe the workbench persisted by the previous view.
  await page.addInitScript(() => {
    if (!window.localStorage.getItem("lingxi.view")) {
      window.localStorage.setItem("lingxi.view", "canvas");
    }
  });
  await page.goto("/");
  await expect(page.getByTestId("canvas")).toBeVisible();
  await expect(page.locator('[data-testid^="library-item-"]').first()).toBeVisible();
}

async function loadCompany(page: Page) {
  await page.getByTestId("toolbar-company").click();
  await page.waitForTimeout(200);
  if ((await page.getByTestId("confirm-dialog").count()) > 0) {
    await page.getByTestId("confirm-accept").click();
  }
  await expect(page.locator(".react-flow__node")).toHaveCount(5);
}

async function runCompany(page: Page) {
  await page.getByTestId("toolbar-run").click();
  await expect(page.getByTestId("agent-workbench")).toBeVisible();
  await expect(page.getByTestId("agent-tab-pm")).toBeVisible();
  await expect(page.getByTestId("agent-tab-coder")).toBeVisible();
  await expect(page.getByTestId("agent-tab-tester")).toBeVisible();
}

async function waitForCompletion(page: Page) {
  await expect(page.getByTestId("agent-workbench").locator(".status--completed")).toBeVisible({
    timeout: 20_000,
  });
}

test.describe("LingXiAgent phase 1.6 workbench", () => {
  test("runs a team and generates one tab per agent with a team overview", async ({ page }) => {
    await ready(page);
    await loadCompany(page);
    await runCompany(page);

    await expect(page.getByTestId("agent-tab-overview")).toBeVisible();
    await page.getByTestId("agent-tab-overview").click();
    await expect(page.getByTestId("agent-overview")).toBeVisible();
    await expect(page.getByTestId("agent-overview")).toContainText("3 个 Agent");
    await expect(page.getByTestId("agent-tab-coder")).toContainText("程序员");
    await expect(page.getByTestId("agent-tab-tester")).toContainText("测试");

    await page.getByTestId("agent-tab-coder").click();
    await expect(page.getByTestId("agent-stream")).toContainText("程序员");
    await page.getByTestId("agent-config-toggle").click();
    await expect(page.getByTestId("agent-config")).toBeVisible();
    await expect(page.getByTestId("agent-messages")).toBeVisible();
    await waitForCompletion(page);
  });

  test("previews and applies a config revision, sends a directive and locates the node", async ({ page }) => {
    await ready(page);
    await loadCompany(page);
    // Do not wait for every tab: later agents only appear when they start, and
    // PM would finish before this test could pause it.
    await page.getByTestId("toolbar-run").click();
    await expect(page.getByTestId("agent-workbench")).toBeVisible();
    await expect(page.getByTestId("agent-tab-pm")).toBeVisible();

    // Intervene while the agent is active: a finished activation has no active
    // run id, so config preview/apply must pause a live agent first.
    await page.getByTestId("agent-tab-pm").click();
    await expect(page.getByTestId("agent-tab-pm")).toContainText("执行中");
    await page.getByTestId("agent-pause").click();
    await expect(page.getByTestId("agent-tab-pm")).toContainText("已暂停");
    await page.getByTestId("agent-config-toggle").click();
    const config = page.getByTestId("agent-config");
    await config.getByLabel("模型").fill("mock-pm-v2");
    await config.getByLabel("角色提示词").fill("Keep the PRD structured and testable.");
    await page.getByTestId("agent-preview-config").click();
    await expect(page.getByTestId("agent-config-preview")).toContainText("model");
    await expect(page.getByTestId("agent-config-preview")).toContainText("mock-pm-v2");

    await page.getByTestId("agent-apply-config").click();
    await expect(page.getByTestId("agent-config")).toContainText("状态：applied");
    await expect(page.getByTestId("agent-config")).toContainText("版本 1");

    await page.getByTestId("agent-directive").fill("Switch to SQLite for persistence.");
    await page.getByTestId("agent-send-directive").click();
    await expect(page.getByTestId("agent-config")).toContainText("纠偏指令已进入总线");

    await page.getByTestId("agent-locate").click();
    await expect(page.getByTestId("agent-workbench")).toHaveCount(0);
    const pm = page.locator('.react-flow__node[data-id="pm"]');
    await expect(pm).toHaveClass(/selected/);

    await page.getByTestId("view-workbench").click();
    await expect(page.getByTestId("agent-tab-pm")).toHaveAttribute("aria-selected", "true");
  });

  test("pauses an agent, keeps the run alive across view switches, then resumes", async ({ page }) => {
    await ready(page);
    await loadCompany(page);
    await page.getByTestId("toolbar-run").click();
    await expect(page.getByTestId("agent-workbench")).toBeVisible();
    await expect(page.getByTestId("agent-tab-pm")).toBeVisible();

    await page.getByTestId("agent-tab-pm").click();
    await expect(page.getByTestId("agent-pause")).toBeEnabled();
    await page.getByTestId("agent-pause").click();
    await expect(page.getByTestId("agent-tab-pm")).toContainText("已暂停");

    await page.getByTestId("view-canvas").click();
    await expect(page.getByTestId("canvas")).toBeVisible();
    await page.waitForTimeout(400);
    await page.getByTestId("view-workbench").click();
    await expect(page.getByTestId("agent-tab-pm")).toContainText("已暂停");

    await page.getByTestId("agent-resume").click();
    // The paused activation resumes at the next safe point and may finish before
    // a transient 执行中 assertion can observe it; the run must complete instead.
    await waitForCompletion(page);
    await expect(page.getByTestId("agent-tab-pm")).toContainText("已完成");
  });

  test("locks canvas structure and node parameters while a run is active", async ({ page }) => {
    await ready(page);
    await loadCompany(page);
    await page.getByTestId("toolbar-run").click();
    await expect(page.getByTestId("agent-workbench")).toBeVisible();
    await expect(page.getByTestId("agent-tab-pm")).toBeVisible();
    await page.getByTestId("agent-tab-pm").click();
    await expect(page.getByTestId("agent-tab-pm")).toContainText("执行中");
    await page.getByTestId("agent-pause").click();
    await expect(page.getByTestId("agent-tab-pm")).toContainText("已暂停");

    // A paused run still owns its snapshot; structural edits must wait for it
    // to finish instead of silently diverging the canvas from the executing doc.
    await page.getByTestId("view-canvas").click();
    await expect(page.getByTestId("canvas-lock")).toContainText("结构已锁定");
    await expect(page.getByTestId("param-pm-model")).toBeDisabled();

    const nodes = page.locator(".react-flow__node");
    await expect(nodes).toHaveCount(5);
    await page.locator('.react-flow__node[data-id="pm"] .node__header').click();
    await page.keyboard.press("Delete");
    await expect(nodes).toHaveCount(5);

    await page.getByTestId("view-workbench").click();
    await expect(page.getByTestId("agent-tab-pm")).toContainText("已暂停");
  });

  test("restores the workbench, tabs and selected agent after a WebView refresh", async ({ page }) => {
    await ready(page);
    await loadCompany(page);
    await runCompany(page);

    await page.getByTestId("agent-tab-coder").click();
    await expect(page.getByTestId("agent-stream")).toContainText("程序员");
    await page.reload();

    await expect(page.getByTestId("canvas")).toBeHidden();
    await expect(page.getByTestId("agent-workbench")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("agent-tab-pm")).toBeVisible();
    await expect(page.getByTestId("agent-tab-coder")).toBeVisible();
    await expect(page.getByTestId("agent-tab-tester")).toBeVisible();
    await expect(page.getByTestId("agent-tab-coder")).toHaveAttribute("aria-selected", "true");
    await expect(page.getByTestId("agent-stream")).toContainText("程序员");
  });

  test("filters events per agent and shows the overview message timeline", async ({ page }) => {
    await ready(page);
    await loadCompany(page);
    await runCompany(page);
    await waitForCompletion(page);

    await page.getByTestId("agent-tab-coder").click();
    await expect(page.getByTestId("agent-stream")).toContainText("程序员");
    await expect(page.getByTestId("agent-messages")).toContainText("task.result");
    await expect(page.getByTestId("agent-stream")).not.toContainText("测试");

    await page.getByTestId("agent-tab-overview").click();
    await expect(page.getByTestId("agent-overview")).toContainText("跨 Agent 消息");
    await expect(page.getByTestId("agent-overview")).toContainText("task.result");
  });
});
