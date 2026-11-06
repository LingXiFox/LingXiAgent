import { expect, test, type Page } from "@playwright/test";

async function ready(page: Page) {
  // A fresh profile must land on the normal-user workbench, not the canvas.
  await page.goto("/");
  await expect(page.getByTestId("project-open-folder")).toBeVisible();
}

async function openProject(page: Page) {
  await expect(page.getByTestId("project-open-folder")).toBeVisible();
  await page.getByTestId("project-open-folder").click();
  await expect(page.getByTestId("project-tree")).toBeVisible({ timeout: 10_000 });
  await expect(page.getByTestId("conversation-timeline")).toBeVisible();
}

async function send(page: Page, text: string) {
  await page.getByTestId("composer-input").fill(text);
  await page.getByTestId("composer-send").click();
}

test.describe("LingXiAgent phase 1.7 project workbench", () => {
  test("opens a project, creates a session and runs a normal Agent task", async ({ page }) => {
    await ready(page);
    await openProject(page);

    await expect(page.getByTestId("project-tree")).toContainText("src");
    await expect(page.getByTestId("agent-tab-overview")).toBeVisible();

    await send(page, "分析这个项目并告诉我它的主要结构。");
    await expect(page.getByTestId("conversation-timeline")).toContainText("分析这个项目");
    await expect(page.getByTestId("conversation-timeline")).toContainText("主要结构", {
      timeout: 10_000,
    });
    await expect(page.getByTestId("agent-tabs")).toContainText("总览");
  });

  test("keeps quick config as the real node config across a refresh", async ({ page }) => {
    await ready(page);
    await openProject(page);

    await page.getByTestId("permission-mode").selectOption("yolo");
    await expect(page.getByTestId("yolo-confirm")).toContainText("真实副作用");
    await expect(page.getByTestId("permission-mode")).toHaveValue("ask");
    await page.getByTestId("yolo-confirm-cancel").click();
    await expect(page.getByTestId("permission-mode")).toHaveValue("ask");

    await page.getByTestId("permission-mode").selectOption("yolo");
    await page.getByTestId("yolo-confirm-enable").click();
    await expect(page.getByTestId("yolo-warning")).toContainText("真实副作用");
    await expect(page.getByTestId("permission-mode")).toHaveValue("yolo");
    await page.getByTestId("workbench-model").selectOption("gpt-4.1");
    await page.getByTestId("workbench-reasoning").selectOption("high");
    await page.waitForTimeout(400);

    await page.reload();
    await expect(page.getByTestId("agent-workbench")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("project-tree")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("permission-mode")).toHaveValue("yolo");
    await expect(page.getByTestId("workbench-model")).toHaveValue("gpt-4.1");
    await expect(page.getByTestId("workbench-reasoning")).toHaveValue("high");
  });

  test("resizes and collapses the project sidebar", async ({ page }) => {
    await ready(page);
    await openProject(page);

    const sidebar = page.locator(".project-sidebar");
    const before = await sidebar.boundingBox();
    expect(before).not.toBeNull();
    const handle = page.getByTestId("sidebar-resizer");
    const box = await handle.boundingBox();
    expect(box).not.toBeNull();
    await page.mouse.move(box!.x + 2, box!.y + 120);
    await page.mouse.down();
    await page.mouse.move(box!.x + 102, box!.y + 120, { steps: 6 });
    await page.mouse.up();
    const after = await sidebar.boundingBox();
    expect(after!.width).toBeGreaterThan(before!.width + 60);

    await page.reload();
    await expect(page.getByTestId("project-tree")).toBeVisible({ timeout: 10_000 });
    const restored = await sidebar.boundingBox();
    expect(restored!.width).toBeGreaterThan(before!.width + 60);

    await page.getByTestId("sidebar-collapse").click();
    await expect(page.getByTestId("sidebar-expand")).toBeVisible();
    expect((await sidebar.boundingBox())!.width).toBeLessThan(50);
    await page.getByTestId("sidebar-expand").click();
    await expect(page.getByTestId("project-tree")).toBeVisible();
  });

  test("configures the send shortcut and keeps Enter as a newline in modifier mode", async ({ page }) => {
    await ready(page);
    await openProject(page);
    await page.getByTestId("composer-send-mode").selectOption("modifier");
    const input = page.getByTestId("composer-input");
    await input.fill("第一行");
    await input.press("Enter");
    await input.type("第二行");
    await expect(input).toHaveValue("第一行\n第二行");
    await expect(page.getByTestId("conversation-timeline")).not.toContainText("第一行");
    await input.press("Control+Enter");
    await expect(page.getByTestId("conversation-timeline")).toContainText("第一行", { timeout: 10_000 });
  });

  test("previews a pasted attachment before sending", async ({ page }) => {
    await ready(page);
    await openProject(page);
    await page.getByTestId("composer-file-input").setInputFiles({
      name: "pixel.png",
      mimeType: "image/png",
      buffer: Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
        "base64",
      ),
    });
    const chips = page.getByTestId("composer-attachments");
    await expect(chips).toBeVisible();
    await expect(chips).toContainText("pixel.png");
    await expect(chips.locator("img")).toBeVisible();
    await page.getByTestId("composer-input").fill("看一下这张图片");
    await page.getByTestId("composer-send").click();
    await expect(page.getByTestId("conversation-timeline")).toContainText("看一下这张图片", { timeout: 10_000 });
    await expect(chips).toHaveCount(0);
  });

  test("browses the project tree and edits a file with a version check", async ({ page }) => {
    await ready(page);
    await openProject(page);

    await page.getByTestId("file-entry-src").click();
    await page.getByTestId("file-entry-main.ts").click();
    const panel = page.getByTestId("aux-panel");
    await expect(panel).toBeVisible();
    const editor = panel.locator("textarea.file-editor");
    await expect(editor).toHaveValue(/greet/);
    await editor.fill('export function greet(name: string) {\n  return "hello " + name + "!";\n}\n');
    await panel.getByRole("button", { name: "保存（版本检查）" }).click();
    await expect(panel).toContainText("已保存");

    await panel.getByTestId("reveal-file").click();
    await expect(panel.getByTestId("reveal-file")).toBeVisible();

    await panel.getByRole("button", { name: "Git", exact: true }).click();
    await expect(panel).toContainText("工作区变更");

    await page.getByTestId("open-terminal").click();
    await expect(page.getByTestId("terminal-panel")).toContainText("命令与测试输出");
    await expect(page.getByTestId("terminal-panel")).toContainText("不是可交互 shell");
  });

  test("maps a workbench Agent to its real nodes and back", async ({ page }) => {
    await ready(page);
    await openProject(page);
    await send(page, "分析这个项目。");
    await expect(page.getByTestId("conversation-timeline")).toContainText("主要结构", {
      timeout: 10_000,
    });

    await page.getByTestId("view-canvas").click();
    const projectNode = page.locator('[data-node-kind="core.project_workspace"]');
    const agentNode = page.locator('[data-node-kind="core.agent"]');
    await expect(projectNode).toHaveCount(1);
    await expect(agentNode).toHaveCount(1);
    await agentNode.click();
    await page.getByTestId("toolbar-open-agent").click();
    await expect(page.getByTestId("agent-workbench")).toBeVisible();

    await expect(page.getByTestId("agent-raw-events")).toBeVisible();
    await page.getByTestId("agent-raw-events").locator("summary").click();
    await expect(page.getByTestId("agent-raw-events").locator("pre")).toContainText("agent.activation.finished");

    await page.getByTestId("agent-locate").click();
    await expect(page.getByTestId("agent-workbench")).toHaveCount(0);
    await expect(page.locator(".react-flow__node.selected")).toHaveCount(1);
  });

  test("creates a second session without reopening the project and restores it", async ({ page }) => {
    await ready(page);
    await openProject(page);
    await send(page, "第一个任务：分析项目。");
    await expect(page.getByTestId("conversation-timeline")).toContainText("主要结构", {
      timeout: 10_000,
    });

    const sessions = page.locator('.conversation-list [data-testid^="conversation-"]');
    const before = await sessions.count();
    await page.getByTestId("new-session").click();
    await expect(sessions).toHaveCount(before + 1);
    await send(page, "第二个任务：继续修改。");
    await expect(page.getByTestId("conversation-timeline")).toContainText("第二个任务");
    await page.waitForTimeout(500);

    await page.reload();
    await expect(page.getByTestId("agent-workbench")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("conversation-timeline")).toContainText("第二个任务", {
      timeout: 10_000,
    });
  });

  test("binds a project folder from inside the workspace node", async ({ page }) => {
    await ready(page);
    // Node editing is the advanced view; the normal entry point is the workbench.
    await page.getByTestId("view-canvas").click();
    await page.getByTestId("library-search").fill("project");
    await page.getByTestId("library-item-core.project_workspace").click();

    const projectNode = page.locator('[data-node-kind="core.project_workspace"]').last();
    await expect(projectNode).toBeVisible();
    await projectNode.locator('[data-testid^="pick-project-"]').click();
    await expect(projectNode.locator('input[data-testid$="-projectId"]')).toHaveValue("lingxi-demo");

    await page.getByTestId("view-workbench").click();
    await expect(page.getByTestId("project-tree")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("project-tree")).toContainText("src");
    await expect(page.getByTestId("conversation-timeline")).toBeVisible();
  });
});
