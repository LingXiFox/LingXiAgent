import { createMockTransport } from "./mock";
import { isTauri, tauriTransport } from "./tauri";
import type { Transport } from "./transport";

// In a Tauri window every call goes to Rust. In a plain browser (pnpm dev
// without the shell) the dev-only mock keeps the editor usable.
const preview = import.meta.env.DEV && !isTauri();

export const api: Transport = preview ? createMockTransport() : tauriTransport;

export const isPreview = preview;
