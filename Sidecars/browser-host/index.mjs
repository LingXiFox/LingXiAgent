import readline from "node:readline";
import fs from "node:fs";

/**
 * LingXiAgent Browser Host Sidecar Runner (JSON-RPC 2.0 / Line-Delimited)
 * 具备协议握手、DOM 语义树提取、稳定 ElementRef 分配与标准动作执行能力。
 */

let playwright = null;
try {
  playwright = await import("playwright");
} catch {
  // Playwright not installed in local directory; will fallback to headless mock or cdp if needed
}

let browserInstance = null;
const sessions = new Map(); // sessionID -> { context, page, elementMap, nextIndex, version }

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
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
  process.stdout.write(JSON.stringify(msg) + "\n");
}

async function ensureBrowser() {
  if (browserInstance) return browserInstance;
  if (!playwright) {
    throw new Error("Playwright is not installed in Node environment");
  }
  browserInstance = await playwright.chromium.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"]
  });
  return browserInstance;
}

async function showBrowserVirtualCursor(page, x, y, isClick = false) {
  try {
    const updatedCoord = await page.evaluate(({ targetX, targetY, click }) => {
      // 1. 尝试根据坐标智能捕获并高亮贴合目标 DOM 元素
      let targetEl = document.elementFromPoint(targetX, targetY);
      if (targetEl && targetEl.id === "lingxi-virtual-cursor") {
        targetEl = null;
      }

      let finalX = targetX;
      let finalY = targetY;

      if (targetEl && targetEl !== document.body && targetEl !== document.documentElement) {
        // 将元素精准居中于视口
        targetEl.scrollIntoView({ behavior: "instant", block: "nearest", inline: "nearest" });
        const rect = targetEl.getBoundingClientRect();
        // 重新矫正为该元素真实中心点
        finalX = rect.left + rect.width / 2;
        finalY = rect.top + rect.height / 2;

        // 注入目标依附高亮外框
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
        sendResponse(id, {
          protocolVersion: "v1",
          hostVersion: "lingxi-browser-host-1.0.0",
          playwrightAvailable: Boolean(playwright),
          capabilities: ["navigation", "dom", "screenshot", "actions", "settle"]
        });
        break;
      }

      case "session.create": {
        const sessionID = params?.sessionID || `session-${Date.now()}`;
        let page = null;
        let context = null;

        if (playwright) {
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

        sendResponse(id, { sessionID, status: "created" });
        break;
      }

      case "session.navigate": {
        const { sessionID, url } = params;
        const session = sessions.get(sessionID);
        if (!session) throw new Error(`Session ${sessionID} not found`);

        if (session.page) {
          await session.page.goto(url, { waitUntil: "domcontentloaded", timeout: 15000 });
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
        const { sessionID } = params;
        const session = sessions.get(sessionID);
        if (!session) throw new Error(`Session ${sessionID} not found`);

        let elements = [];
        let screenshotBase64 = null;

        if (session.page) {
          // 提取可交互元素并打上 stable ref 标记 (全量现代组件与可见性过滤)
          elements = await session.page.evaluate(() => {
            const selector = "button, a, input, select, textarea, [role=button], [role=link], [role=searchbox], [role=combobox], [role=tab], [role=menuitem], [role=checkbox], [role=radio], [contenteditable='true'], [onclick], summary";
            const candidateElements = Array.from(document.querySelectorAll(selector));
            
            const validItems = [];
            for (let i = 0; i < candidateElements.length; i++) {
              const el = candidateElements[i];
              const rect = el.getBoundingClientRect();
              const style = window.getComputedStyle(el);

              // 过滤不可见、被隐藏或尺寸为零的元素
              if (style.display === "none" || style.visibility === "hidden" || parseFloat(style.opacity) === 0) continue;
              if (rect.width < 3 || rect.height < 3) continue;

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

            // 视口内且高优先级（如搜索框、核心按钮）排在最前
            validItems.sort((a, b) => {
              if (a.inViewport !== b.inViewport) return a.inViewport ? -1 : 1;
              return b.priority - a.priority;
            });

            return validItems.slice(0, 100);
          });

          // 截屏 (JPEG/PNG)
          const buffer = await session.page.screenshot({ type: "jpeg", quality: 70 });
          screenshotBase64 = buffer.toString("base64");
        } else {
          // Mock 模式
          elements = [
            { id: "input-search", role: "input", name: "Search Query", value: "", isInteractable: true, x: 100, y: 100, width: 300, height: 36 },
            { id: "btn-submit", role: "button", name: "Submit", value: null, isInteractable: true, x: 420, y: 100, width: 80, height: 36 }
          ];
        }

        // 分配稳定 ElementRef
        const refElements = {};
        for (const el of elements) {
          const index = session.nextIndex++;
          refElements[`ref_${index}`] = {
            ...el,
            refIndex: index
          };
          session.elementMap.set(index, el);
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

      case "session.act": {
        const { sessionID, action } = params;
        const session = sessions.get(sessionID);
        if (!session) throw new Error(`Session ${sessionID} not found`);

        if (session.page) {
          let clickX = action.x;
          let clickY = action.y;
          if (action.x !== undefined && action.y !== undefined) {
            const coord = await showBrowserVirtualCursor(session.page, action.x, action.y, action.type === "click");
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
            // Click-to-Focus 自动保护：输入前先点击目标控件激活焦点
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
          if (session.page) await session.page.close().catch(() => {});
          if (session.context) await session.context.close().catch(() => {});
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

process.on("SIGINT", async () => {
  if (browserInstance) await browserInstance.close().catch(() => {});
  process.exit(0);
});

process.on("SIGTERM", async () => {
  if (browserInstance) await browserInstance.close().catch(() => {});
  process.exit(0);
});
