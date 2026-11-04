import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e/web",
  fullyParallel: false,
  workers: 1,
  timeout: 45_000,
  expect: { timeout: 8_000 },
  reporter: [
    ["list"],
    ["html", { open: "never", outputFolder: "test-results/playwright-report" }],
  ],
  outputDir: "test-results/playwright",
  use: {
    baseURL: "http://127.0.0.1:1420",
    headless: true,
    viewport: { width: 1440, height: 900 },
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "off",
  },
  webServer: {
    command: "pnpm dev --host 127.0.0.1 --port 1420",
    url: "http://127.0.0.1:1420",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: "pipe",
    stderr: "pipe",
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        // Set PLAYWRIGHT_CHANNEL=chrome to reuse an installed Chrome when the
        // bundled Chromium download is unavailable. CI installs Chromium.
        ...(process.env.PLAYWRIGHT_CHANNEL
          ? { channel: process.env.PLAYWRIGHT_CHANNEL }
          : {}),
      },
    },
  ],
});
