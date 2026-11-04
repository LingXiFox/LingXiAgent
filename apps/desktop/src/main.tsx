import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import "@xyflow/react/dist/style.css";
import "./styles.css";
import App from "./App";
import { I18nProvider } from "./lib/i18n";

// E2E-only bridge for browser.tauri.execute(). The production build never
// sets VITE_E2E, so this module stays out of the release bundle.
if (import.meta.env.VITE_E2E === "1") {
  void import("@wdio/tauri-plugin");
}

const container = document.getElementById("root");
if (!container) throw new Error("#root is missing from index.html");

createRoot(container).render(
  <StrictMode>
    <I18nProvider>
      <App />
    </I18nProvider>
  </StrictMode>,
);
