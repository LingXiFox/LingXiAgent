import readline from "node:readline";
import fs from "node:fs";

const HOST_MODE = process.env.LINGXI_BROWSER_HOST_MODE || "real"; // "real" | "mock"
const DISABLE_SANDBOX = process.env.LINGXI_BROWSER_DISABLE_SANDBOX === "1";

let playwright = null;
if (HOST_MODE === "real") {
  try {
    playwright = await import("playwright");
  } catch {
    // Playwright not installed in environment
  }
}

let browserInstance = null;
// sessionID -> { sessionID, context, page, elementMap, nextIndex, version, currentURL, currentTitle }
const sessions = new Map();

const rl = readline.createInterface({
  input: process.stdin,
  terminal: false
});

function sendResponse(id, result, error = null) {
  const msg = { jsonrpc: "2.0" };
  if (id !== undefined && id !== null) msg.id = id;
  if (error) {
    msg.error = error;
  } else {
    msg.result = result;
  }
  const payload = JSON.stringify(msg) + "\n";
  process.stdout.write(payload);
}

async function ensureBrowser() {
  if (browserInstance) return browserInstance;
  if (!playwright) {
    throw new Error("Playwright is not installed in Node environment");
  }
  const launchArgs = [];
  if (DISABLE_SANDBOX) {
    launchArgs.push("--no-sandbox", "--disable-setuid-sandbox");
  }
  browserInstance = await playwright.chromium.launch({
    headless: true,
    args: launchArgs
  });
  return browserInstance;
}

function validateURLPolicy(rawURL) {
  try {
    const parsed = new URL(rawURL);
    const allowedProtocols = ["http:", "https:", "about:"];
    if (!allowedProtocols.includes(parsed.protocol)) {
      throw new Error(`Forbidden URL protocol '${parsed.protocol}'. Only http:, https: and about: are allowed.`);
    }
  } catch (err) {
    if (err.message && err.message.includes("Forbidden URL protocol")) {
      throw err;
    }
    throw new Error(`Invalid URL format: ${rawURL}`);
  }
}

async function cleanupSessionResources(session) {
  if (!session) return;
  if (session.page) {
    await session.page.close().catch(() => {});
    session.page = null;
  }
  if (session.context) {
    await session.context.close().catch(() => {});
    session.context = null;
  }
  if (session.elementMap) {
    session.elementMap.clear();
  }
}

async function showBrowserVirtualCursor(page, x, y, isClick = false) {
  try {
    const updatedCoord = await page.evaluate(({ targetX, targetY, click }) => {
      let targetEl = document.elementFromPoint(targetX, targetY);
      if (targetEl && targetEl.id === "lingxi-virtual-cursor") {
        targetEl = null;
      }

      let finalX = targetX;
      let finalY = targetY;

      if (targetEl && targetEl !== document.body && targetEl !== document.documentElement) {
        targetEl.scrollIntoView({ behavior: "instant", block: "nearest", inline: "nearest" });
        const rect = targetEl.getBoundingClientRect();
        finalX = rect.left + rect.width / 2;
        finalY = rect.top + rect.height / 2;

        targetEl.classList.add("lingxi-target-focused");
        setTimeout(() => {
          targetEl.classList.remove("lingxi-target-focused");
        }, 1200);
      }

      let cursor = document.getElementById("lingxi-virtual-cursor");
      if (!cursor) {
        cursor = document.createElement("div");
        cursor.id = "lingxi-virtual-cursor";
        cursor.style.cssText = `
          position: fixed;
          width: 24px;
          height: 24px;
          background: rgba(255, 120, 0, 0.9);
          border: 2px solid white;
          border-radius: 50%;
          box-shadow: 0 0 14px rgba(255, 120, 0, 0.9), 0 0 4px rgba(255, 255, 255, 0.9);
          pointer-events: none;
          z-index: 2147483647;
          transition: all 0.15s cubic-bezier(0.25, 1, 0.5, 1);
          transform: translate(-50%, -50%);
          display: flex;
          align-items: center;
          justify-content: center;
        `;
        const innerDot = document.createElement("div");
        innerDot.style.cssText = "width: 6px; height: 6px; background: white; border-radius: 50%;";
        cursor.appendChild(innerDot);
        document.body.appendChild(cursor);

        if (!document.getElementById("lingxi-cursor-styles")) {
          const style = document.createElement("style");
          style.id = "lingxi-cursor-styles";
          style.textContent = `
            @keyframes lingxiRipple {
              0% { transform: translate(-50%, -50%) scale(0.4); opacity: 1; }
              100% { transform: translate(-50%, -50%) scale(2.2); opacity: 0; }
            }
            .lingxi-ripple-effect {
              position: fixed;
              width: 50px;
              height: 50px;
              border: 2.5px solid #00f0ff;
              background: rgba(0, 240, 255, 0.25);
              border-radius: 50%;
              pointer-events: none;
              z-index: 2147483646;
              animation: lingxiRipple 0.35s ease-out forwards;
            }
            .lingxi-target-focused {
              outline: 2.5px dashed #ff7800 !important;
              outline-offset: 3px !important;
              box-shadow: 0 0 10px rgba(255, 120, 0, 0.6) !important;
              transition: outline 0.2s ease-in-out !important;
            }
          `;
          document.head.appendChild(style);
        }
      }

      cursor.style.left = `${finalX}px`;
      cursor.style.top = `${finalY}px`;
      cursor.style.opacity = "1";

      if (click) {
        const ripple = document.createElement("div");
        ripple.className = "lingxi-ripple-effect";
        ripple.style.left = `${finalX}px`;
        ripple.style.top = `${finalY}px`;
        document.body.appendChild(ripple);
        setTimeout(() => ripple.remove(), 400);
      }

      return { x: finalX, y: finalY };
    }, { targetX: x, targetY: y, click: isClick });

    return updatedCoord || { x, y };
  } catch {
    return { x, y };
  }
}

rl.on("line", async (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  process.stderr.write(`[Sidecar] Received line: ${trimmed.slice(0, 60)}\n`);

  let request;
  try {
    request = JSON.parse(trimmed);
  } catch (err) {
    sendResponse(null, null, { code: -32700, message: "Parse error" });
    return;
  }

  const { id, method, params } = request;

  try {
    switch (method) {
      case "initialize": {
        const isPlaywrightAvailable = Boolean(playwright);
        if (HOST_MODE === "real" && !isPlaywrightAvailable) {
          sendResponse(id, null, {
            code: -32001,
            message: "BrowserHost initialized in 'real' mode but Playwright is not available in Node runtime"
          });
          return;
        }

        sendResponse(id, {
          protocolVersion: "v1",
          hostVersion: "lingxi-browser-host-1.1.0",
          mode: HOST_MODE,
          playwrightAvailable: isPlaywrightAvailable,
          capabilities: ["navigation", "dom", "screenshot", "actions", "settle", "capture"]
        });
        break;
      }

      case "session.create": {
        const sessionID = params?.sessionID || `session-${Date.now()}`;
        
        // Defensive check: If session already exists, explicitly tear down old context & page
        const existing = sessions.get(sessionID);
        if (existing) {
          await cleanupSessionResources(existing);
          sessions.delete(sessionID);
        }

        if (HOST_MODE === "real" && !playwright) {
          throw new Error("Cannot create browser session in 'real' mode without Playwright installed");
        }

        let page = null;
        let context = null;

        if (playwright && HOST_MODE !== "mock") {
          const browser = await ensureBrowser();
          context = await browser.newContext({
            viewport: { width: 1280, height: 800 }
          });
          page = await context.newPage();
        }

        sessions.set(sessionID, {
          sessionID,
          context,
          page,
          elementMap: new Map(),
          version: 1,
          nextIndex: 1,
          currentURL: "about:blank",
          currentTitle: "New Tab"
        });

        sendResponse(id, { sessionID, status: "created", mode: HOST_MODE });
        break;
      }

      case "session.navigate": {
        const { sessionID, url } = params;
        validateURLPolicy(url);

        let session = sessions.get(sessionID);
        if (!session) {
          // If session doesn't exist yet, lazily create it instead of failing
          if (HOST_MODE === "real" && !playwright) {
            throw new Error("Cannot navigate in 'real' mode without Playwright installed");
          }
          let page = null;
          let context = null;
          if (playwright && HOST_MODE !== "mock") {
            const browser = await ensureBrowser();
            context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
            page = await context.newPage();
          }
          session = {
            sessionID,
            context,
            page,
            elementMap: new Map(),
            version: 1,
            nextIndex: 1,
            currentURL: "about:blank",
            currentTitle: "New Tab"
          };
          sessions.set(sessionID, session);
        }

        if (session.page) {
          await session.page.goto(url, { waitUntil: "domcontentloaded", timeout: 25000 });
          session.currentURL = session.page.url();
          session.currentTitle = await session.page.title();
        } else {
          session.currentURL = url;
          session.currentTitle = `Mock Page: ${url}`;
        }

        session.version += 1;
        session.elementMap.clear();
        session.nextIndex = 1;

        sendResponse(id, {
          url: session.currentURL,
          title: session.currentTitle,
          version: session.version
        });
        break;
      }

      case "session.snapshot": {
        const { sessionID, includeScreenshot = false } = params;
        const session = sessions.get(sessionID);
        if (!session) throw new Error(`Session ${sessionID} not found`);

        let elements = [];
        let screenshotBase64 = null;

        if (session.page) {
          // Bounded candidate scan (Max 300 candidates to prevent layout thrashing on large DOMs)
          elements = await session.page.evaluate(() => {
            const selector = "button, a, input, select, textarea, [role=button], [role=link], [role=searchbox], [role=combobox], [role=tab], [role=menuitem], [role=checkbox], [role=radio], [contenteditable='true'], [onclick], summary";
            const candidateElements = Array.from(document.querySelectorAll(selector)).slice(0, 300);
            
            const validItems = [];
            for (let i = 0; i < candidateElements.length; i++) {
              const el = candidateElements[i];
              const rect = el.getBoundingClientRect();
              
              // Fast reject zero-size or out-of-document elements
              if (rect.width < 3 || rect.height < 3) continue;

              const style = window.getComputedStyle(el);
              if (style.display === "none" || style.visibility === "hidden" || parseFloat(style.opacity) === 0) continue;

              const role = el.getAttribute("role") || el.tagName.toLowerCase();
              const name = (
                el.getAttribute("aria-label") ||
                el.getAttribute("placeholder") ||
                el.getAttribute("title") ||
                el.getAttribute("alt") ||
                el.innerText ||
                el.value ||
                el.getAttribute("name") ||
                ""
              ).trim();

              const inViewport = (rect.bottom >= 0 && rect.top <= window.innerHeight && rect.right >= 0 && rect.left <= window.innerWidth);

              validItems.push({
                id: el.id || `node-${i}`,
                role,
                name: name.slice(0, 100),
                value: el.value || null,
                isInteractable: true,
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
                inViewport,
                priority: (role === "input" || role === "textarea" || role.includes("search") ? 10 : (role === "button" || role.includes("btn") ? 8 : 5))
              });
            }

            validItems.sort((a, b) => {
              if (a.inViewport !== b.inViewport) return a.inViewport ? -1 : 1;
              return b.priority - a.priority;
            });

            return validItems.slice(0, 100);
          });

          if (includeScreenshot) {
            const buffer = await session.page.screenshot({ type: "jpeg", quality: 60 });
            screenshotBase64 = buffer.toString("base64");
          }
        } else {
          // Mock mode
          elements = [
            { id: "input-search", role: "input", name: "Search Query", value: "", isInteractable: true, x: 100, y: 100, width: 300, height: 36, inViewport: true },
            { id: "btn-submit", role: "button", name: "Submit", value: null, isInteractable: true, x: 420, y: 100, width: 80, height: 36, inViewport: true }
          ];
        }

        // Assign stable ElementRefs for this snapshot
        session.elementMap.clear();
        const refElements = {};
        for (const el of elements) {
          const index = session.nextIndex++;
          const refRecord = {
            ...el,
            refIndex: index,
            snapshotVersion: session.version
          };
          refElements[`ref_${index}`] = refRecord;
          session.elementMap.set(index, refRecord);
        }

        sendResponse(id, {
          sessionID: session.sessionID,
          version: session.version,
          url: session.currentURL,
          title: session.currentTitle,
          viewport: { width: 1280, height: 800 },
          elements: refElements,
          screenshotBase64
        });
        break;
      }

      case "session.capture": {
        const { sessionID, savePath } = params;
        const session = sessions.get(sessionID);
        if (!session) throw new Error(`Session ${sessionID} not found`);

        if (session.page) {
          if (savePath) {
            await session.page.screenshot({ path: savePath, type: "jpeg", quality: 75 });
            sendResponse(id, { path: savePath, success: true });
          } else {
            const buffer = await session.page.screenshot({ type: "jpeg", quality: 75 });
            sendResponse(id, { screenshotBase64: buffer.toString("base64"), success: true });
          }
        } else {
          sendResponse(id, { mock: true, success: true });
        }
        break;
      }

      case "session.act": {
        const { sessionID, action } = params;
        const session = sessions.get(sessionID);
        if (!session) throw new Error(`Session ${sessionID} not found`);

        let clickX = action.x;
        let clickY = action.y;

        // ElementRef validation and anti-stale protection
        if (action.refIndex !== undefined && action.refIndex !== null) {
          const recordedEl = session.elementMap.get(action.refIndex);
          if (!recordedEl) {
            sendResponse(id, null, {
              code: -32002,
              message: `Stale element reference: ref_${action.refIndex} no longer exists in current session snapshot table`
            });
            return;
          }

          if (action.version !== undefined && action.version !== session.version) {
            sendResponse(id, null, {
              code: -32002,
              message: `Stale version: action version v${action.version} does not match current page version v${session.version}`
            });
            return;
          }

          if (session.page) {
            // Verify DOM presence and get current live bounds
            const liveInfo = await session.page.evaluate((target) => {
              // Try finding element by ID or matching tag & role
              let el = document.getElementById(target.id);
              if (!el && target.name) {
                const candidates = document.querySelectorAll(target.role || "*");
                for (const c of candidates) {
                  const text = (c.innerText || c.getAttribute("aria-label") || c.value || "").trim();
                  if (text === target.name) {
                    el = c;
                    break;
                  }
                }
              }
              if (!el && !target.allowCoordinateFallback) {
                return { found: false };
              }
              if (el) {
                const rect = el.getBoundingClientRect();
                return {
                  found: true,
                  x: rect.x + rect.width / 2,
                  y: rect.y + rect.height / 2
                };
              }
              return { found: false, fallback: true };
            }, {
              id: recordedEl.id,
              name: recordedEl.name,
              role: recordedEl.role,
              allowCoordinateFallback: Boolean(action.allowCoordinateFallback)
            });

            if (!liveInfo.found && !action.allowCoordinateFallback) {
              sendResponse(id, null, {
                code: -32002,
                message: `Element ref_${action.refIndex} ('${recordedEl.name || recordedEl.id}') is disconnected or disappeared from current DOM. Coordinate fallback prohibited.`
              });
              return;
            }

            if (liveInfo.found) {
              clickX = liveInfo.x;
              clickY = liveInfo.y;
            }
          }
        }

        if (session.page) {
          if (clickX !== undefined && clickY !== undefined) {
            const coord = await showBrowserVirtualCursor(session.page, clickX, clickY, action.type === "click");
            if (coord && typeof coord.x === "number") {
              clickX = coord.x;
              clickY = coord.y;
            }
          }

          if (action.type === "click") {
            if (clickX !== undefined && clickY !== undefined) {
              await session.page.mouse.click(clickX, clickY);
            }
          } else if (action.type === "type") {
            if (clickX !== undefined && clickY !== undefined) {
              await session.page.mouse.click(clickX, clickY);
              await session.page.waitForTimeout(80);
            }
            if (action.text) {
              await session.page.keyboard.type(action.text);
            }
          } else if (action.type === "key" || action.type === "keypress") {
            await session.page.keyboard.press(action.key || "Enter");
          } else if (action.type === "wait") {
            await session.page.waitForTimeout(Math.min(action.milliseconds || 1000, 5000));
          }
        }

        sendResponse(id, { success: true });
        break;
      }

      case "session.close": {
        const { sessionID } = params;
        const session = sessions.get(sessionID);
        if (session) {
          await cleanupSessionResources(session);
          sessions.delete(sessionID);
        }
        sendResponse(id, { closed: true });
        break;
      }

      default:
        sendResponse(id, null, { code: -32601, message: `Method ${method} not found` });
    }
  } catch (err) {
    sendResponse(id, null, {
      code: -32000,
      message: err.message || "Internal Host error"
    });
  }
});

async function shutdownAll() {
  for (const session of sessions.values()) {
    await cleanupSessionResources(session);
  }
  sessions.clear();
  if (browserInstance) {
    await browserInstance.close().catch(() => {});
    browserInstance = null;
  }
}

process.on("SIGINT", async () => {
  await shutdownAll();
  process.exit(0);
});

process.on("SIGTERM", async () => {
  await shutdownAll();
  process.exit(0);
});
