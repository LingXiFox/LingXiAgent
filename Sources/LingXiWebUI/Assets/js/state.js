/* LingXiAgent WebUI — thin projection of the Core Frontend contract.
   All agent state arrives from /api/stream (snapshot + revision-tagged deltas);
   this file only projects it and sends user intents back as FrontendCommand JSON. */

/* A remote bind hands the token over the URL fragment: the fragment never reaches the
   server, so it stays out of logs while sessionStorage keeps it across a refresh. */
const TOKEN = (() => {
  const fromHash = new URLSearchParams(location.hash.replace(/^#/, '')).get('t');
  if (fromHash) {
    try { sessionStorage.setItem('lingxi.token', fromHash); } catch { /* private mode */ }
    return fromHash;
  }
  try { return sessionStorage.getItem('lingxi.token') || ''; } catch { return ''; }
})();
const API = {
  hello: '/api/hello',
  state: '/api/state',
  stream: '/api/stream',
  command: '/api/command',
  exec: '/api/exec',
  references: '/api/references',
  upload: '/api/upload',
  shutdown: '/api/shutdown',
};

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
};
const nowMS = () => Date.now();

/* ---------------------------------------------------------------- transport */

async function post(path, payload) {
  const headers = { 'Content-Type': 'application/json', 'X-LingXi-Client': 'webui' };
  if (TOKEN) headers['X-LingXi-Token'] = TOKEN;
  const response = await fetch(path, { method: 'POST', headers, body: JSON.stringify(payload) });
  if (!response.ok) throw new Error(`${path} → HTTP ${response.status}`);
  return response.status === 204 ? null : response.json();
}

/** The single mutation path: a browser intent is a FrontendCommand for Core to apply. */
function command(payload) {
  return post(API.command, payload).catch((error) => toast(error.message, 'error'));
}

/* -------------------------------------------------------------------- store */

const store = {
  revision: 0,
  state: {},
  activeID: null,        // which session the projected transcript belongs to
  nodes: new Map(),      // TimelineNodeID -> node, always the newest revision of it
  order: [],             // TimelineNodeID[] in Core order
  commands: [],
  references: [],
  connected: false,
  openToolIDs: new Set(),
  openThinkingIDs: new Set(),
  panel: null,
  sessionFilter: '',
  attachments: [],       // { path, name, size }
  lastClientError: null,
};

function snapshotState(s) {
  if (!s || typeof s !== 'object') return;
  store.state = s;
}

/* A delta carries a trimmed state: its `activeSessionState.timelineNodes` is empty by
   contract, so switching which session is active can only be resolved by a snapshot.
   Without this, selecting another session left the transcript empty until a refresh. */
function trackActiveSession() {
  const id = idOf(activeSession()?.sessionID);
  if (!id) return;
  if (store.activeID && store.activeID !== id) { requestResync('active session changed'); return true; }
  store.activeID = id;
  return false;
}

function applySnapshot(frame) {
  if (typeof frame.revision === 'number') store.revision = frame.revision;
  snapshotState(frame.state);
  store.activeID = idOf(activeSession()?.sessionID) || store.activeID;
  store.commands = frame.commands || store.commands || [];
  /* `timelineNodes` is the only transcript container Core guarantees in order; the
     other five (committedNodes, activeCell, thinkingNodes, toolNodes) are lookup
     caches of the same payloads and would double-paint. */
  const timeline = activeSession()?.timelineNodes || [];
  store.nodes = new Map();
  store.order = [];
  for (const node of timeline) putNode(node);
  markDirty('all');
}

function applyDelta(frame) {
  if (frame.requiresSnapshot) { requestResync('core requested resync'); return; }
  if (typeof frame.revision === 'number') {
    // Duplicated or out-of-order frames are dropped; a jump needs a fresh snapshot.
    if (frame.revision <= store.revision) return;
    if (frame.revision > store.revision + 1 && store.revision > 0) {
      requestResync('revision gap');
      return;
    }
    store.revision = frame.revision;
  }
  snapshotState(frame.state);
  if (trackActiveSession()) return;
  for (const node of frame.changedNodes || []) {
    putNode(node);
    const id = node.id?.rawValue ?? node.id;
    if (typeof id === 'string') dirtyNodes.add(id);
  }
  const changes = frame.changes || {};
  if (changes.transcriptStructureChanged) reconcileOrder(activeSession()?.timelineNodes || null, changes.nodeChanges);
  markDirty(changes);
}

function putNode(node) {
  if (!node) return;
  const id = node.id?.rawValue ?? node.id;
  if (typeof id !== 'string') return;
  store.nodes.set(id, node);
  if (!store.order.includes(id)) store.order.push(id);
}

/** Structure changes can add, reorder and remove nodes. Deltas carry a trimmed
    timeline, so only trust an ordered list when Core actually sends one; otherwise
    apply the explicit per-node change kinds. */
function reconcileOrder(timeline, nodeChanges) {
  if (Array.isArray(timeline) && timeline.length) {
    const next = [];
    for (const node of timeline) {
      const id = idOf(node?.id);
      if (typeof id !== 'string') continue;
      putNode(node);
      next.push(id);
    }
    for (const id of store.order) if (!next.includes(id)) store.nodes.delete(id);
    store.order = next;
    return;
  }
  if (!Array.isArray(nodeChanges)) return;
  for (const change of nodeChanges) {
    const id = idOf(pick(change, 'nodeID', 'node_id', 'id'));
    const kind = typeof pick(change, 'kind') === 'object'
      ? Object.keys(pick(change, 'kind'))[0]
      : pick(change, 'kind');
    if (typeof id !== 'string') continue;
    if (kind === 'remove') {
      store.nodes.delete(id);
      store.order = store.order.filter((entry) => entry !== id);
    } else if (kind === 'reset') {
      requestResync('timeline reset');
      return;
    }
  }
}

function activeSession() {
  return store.state.activeSessionState || null;
}

function sessionCatalog() {
  return store.state.sessionCatalog || [];
}

/* dirty routing keeps a long timeline cheap */
const dirty = { all: true, timeline: true, sessions: true, composer: true, meta: true, panel: true, attention: true };
/* Which node ids Core reported as changed since the last painted frame, and the row
   element already in the document for every rendered node. Without these, a transcript
   patch has no choice but to rebuild every row, which is what made a streaming token
   look like a page refresh. */
const dirtyNodes = new Set();
const timelineRows = new Map();
let timelineFullRebuild = true;

function markDirty(changes) {
  if (changes === 'all') { Object.keys(dirty).forEach((k) => { dirty[k] = true; }); timelineFullRebuild = true; return; }
  dirty.sessions = dirty.sessions || changes.sessionChanged;
  dirty.timeline = dirty.timeline || changes.transcriptStructureChanged
    || (changes.nodeChanges || []).length > 0 || (changes.transcriptNodesChanged || []).length > 0;
  dirty.meta = dirty.meta || changes.statusChanged || changes.contextChanged || changes.providerStatusChanged;
  dirty.composer = dirty.composer || changes.inputChanged || changes.statusChanged || changes.contextChanged;
  dirty.attention = dirty.attention || changes.interactionChanged || changes.transcriptStructureChanged;
  dirty.panel = dirty.panel || changes.contextChanged || changes.workflowChanged || changes.backgroundTasksChanged;
}

let frameScheduled = false;
function scheduleRender() {
  if (frameScheduled) return;
  frameScheduled = true;
  requestAnimationFrame(() => {
    frameScheduled = false;
    render();
  });
}

function render() {
  $('workbench').hidden = false;
  $('boot').hidden = true;
  if (dirty.all) { store.openToolIDs = new Set(); store.openThinkingIDs = new Set(); dirty.all = false; }
  if (dirty.sessions) { renderSessions(); renderRail(); }
  if (dirty.meta) { renderHeader(); }
  if (dirty.attention) { renderAttention(); }
  if (dirty.timeline) { renderTimeline(); }
  if (dirty.composer) { renderComposer(); }
  if (dirty.panel) { renderPanel(); }
  dirty.sessions = dirty.meta = dirty.attention = dirty.timeline = dirty.composer = dirty.panel = false;
  renderConnection();
}

/* ----------------------------------------------------------------- stream */

let stream = null;
let streamRetry = 0;

function openStream() {
  if (stream) stream.close();
  stream = new EventSource(`${API.stream}?t=${nowMS()}`, { withCredentials: false });
  stream.onopen = () => {
    store.connected = true;
    streamRetry = 0;
    markDirty({ statusChanged: true });
    scheduleRender();
  };
  stream.addEventListener('snapshot', (event) => { withJSON(event.data, applySnapshot); });
  stream.addEventListener('delta', (event) => { withJSON(event.data, applyDelta); });
  stream.addEventListener('resync', (event) => {
    withJSON(event.data, (payload) => toast(payload.message || 'Core requested a resync', 'warn'));
    requestResync('core resync');
  });
  stream.onerror = () => {
    store.connected = false;
    renderConnection();
    // EventSource reconnects on its own and replays Last-Event-ID; only if it gives
    // up do we re-fetch a snapshot ourselves.
    if (++streamRetry > 12) { stream.close(); stream = null; setTimeout(bootstrapRetry, 1500); }
  };
}

function bootstrapRetry() {
  fetch(API.state, { headers: tokenHeaders() })
    .then((response) => response.ok ? response.json() : Promise.reject(new Error('state unavailable')))
    .then((frame) => { applySnapshot(frame); scheduleRender(); openStream(); })
    .catch(() => setTimeout(bootstrapRetry, 2000));
}

function tokenHeaders() {
  const headers = { 'X-LingXi-Client': 'webui' };
  if (TOKEN) headers['X-LingXi-Token'] = TOKEN;
  return headers;
}

async function requestResync(reason) {
  if (resyncInFlight) return;
  resyncInFlight = true;
  try {
    const response = await fetch(API.state, { headers: tokenHeaders() });
    if (response.ok) applySnapshot(await response.json());
  } catch (error) {
    console.warn('resync failed', reason, error);
  } finally {
    resyncInFlight = false;
    scheduleRender();
  }
}
let resyncInFlight = false;

function withJSON(text, apply) {
  try { apply(JSON.parse(text)); scheduleRender(); }
  catch (error) { console.error('bad frame', error, text && text.slice(0, 200)); }
}

/* ------------------------------------------------------------ selectors */

const pick = (object, ...keys) => {
  for (const key of keys) {
    const value = object?.[key];
    if (value !== undefined && value !== null) return value;
  }
  return null;
};

const idOf = (value) => {
  if (value === undefined || value === null) return null;
  if (typeof value === 'string') return value;
  return value.rawValue ?? value.id ?? value.value ?? null;
};

/* Core's canonical ids are Codable newtypes, so on the wire they are objects:
   `{"rawValue": "…"}`. The two exceptions are ModelID (a `String` typealias) and
   TimelineNodeID (encoded through a single value container), which stay bare.
   Anything PUT INTO a command therefore has to be re-wrapped. */
const wireID = (value) => ({ rawValue: String(idOf(value) ?? value ?? '') });
const wireModelID = (value) => String(idOf(value) ?? value ?? '');

/** A Swift enum arrives either as a bare `String` raw value or as `{tag: payload}`. */
const enumName = (value) => {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object') return Object.keys(value)[0];
  return null;
};

/** Swift synthesises `case tool(ToolNode)` as `{"tool":{"_0":ToolNode}}`: the payload
    sits under `_0` because the case has no label. Already-direct payloads pass through. */
function unwrapNodeKind(kind) {
  const tagged = kind && typeof kind === 'object' ? Object.values(kind)[0] : undefined;
  return tagged && typeof tagged === 'object' && '_0' in tagged ? tagged._0 : tagged;
}

function nodeParts(node) {
  const kinds = ['message', 'thinking', 'tool', 'interaction', 'subagent', 'runTerminal', 'run_terminal', 'error'];
  const kind = node?.kind;
  if (kind && typeof kind === 'object') {
    for (const key of kinds) {
      if (kind[key] !== undefined) {
        return { type: key === 'run_terminal' ? 'runTerminal' : key, body: unwrapNodeKind(kind) || {} };
      }
    }
  }
  if (typeof kind === 'string') return { type: kind, body: node };
  return { type: 'unknown', body: node || {} };
}

function pendingInteractions() {
  const authoritative = pick(activeSession(), 'pendingInteractions', 'pending_interactions');
  /* Core keeps the authoritative pending HITL set; scanning the timeline only finds
     interactions that were already committed, so it is a fallback, not the source. */
  if (Array.isArray(authoritative)) {
    return authoritative.map((body) => ({
      node: null,
      body,
      id: idOf(pick(body, 'interactionID', 'interaction_id')),
    }));
  }
  const found = [];
  for (const id of store.order) {
    const node = store.nodes.get(id);
    const { type, body } = nodeParts(node);
    if (type === 'interaction' && !pick(body, 'isResolved', 'is_resolved')) found.push({ node, body, id });
  }
  return found;
}

function contextState() {
  const session = activeSession();
  return pick(session, 'contextState', 'context_state') || {};
}

function prediction() {
  const context = contextState();
  return pick(context, 'prediction');
}

function todos() {
  return pick(activeSession(), 'todos') || [];
}

function subagentNodes() {
  /* `activeSessionState.subagents` is the authoritative delegation table (keyed by
     runID, same source the TUI and GUI read): real sessions carry no `subagent`
     timeline rows, so the timeline scan is only a fallback. */
  const map = pick(activeSession(), 'subagents');
  if (map && typeof map === 'object' && Object.keys(map).length) {
    return Object.values(map).map((body) => ({ body, node: null }));
  }
  const out = [];
  for (const id of store.order) {
    const node = store.nodes.get(id);
    const { type, body } = nodeParts(node);
    if (type === 'subagent') out.push({ body, node });
  }
  return out;
}

/* `ProductRuntimeStatus` is a `String` enum with Capitalized raw values; there is no
   lowercase "running"/"streaming"/"thinking" state on the wire to compare against. */
const RUNNING_STATUSES = ['Thinking', 'WaitingForProvider', 'RateLimited', 'RunningTool', 'RunningSubagents', 'Paging'];

function runtimeStatus() {
  return enumName(pick(store.state, 'status')) || enumName(pick(activeSession(), 'status')) || '';
}

function isRunning() {
  const status = runtimeStatus();
  if (status) return RUNNING_STATUSES.includes(status);
  return Boolean(idOf(pick(activeSession(), 'activeRootRunID', 'active_root_run_id')));
}

function connectionStatus() {
  return enumName(pick(store.state.connectionState, 'status')) || '';
}

/* ------------------------------------------------------------- formatting */

const fmtTokens = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return '—';
  if (number >= 1000000) return `${(number / 1000000).toFixed(1)}M`;
  if (number >= 1000) return `${(number / 1000).toFixed(number >= 10000 ? 0 : 1)}k`;
  return String(Math.round(number));
};

const fmtBytes = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return '—';
  const units = ['B', 'KB', 'MB', 'GB'];
  let index = 0;
  let size = number;
  while (size >= 1024 && index < units.length - 1) { size /= 1024; index += 1; }
  return `${size >= 100 || index === 0 ? Math.round(size) : size.toFixed(1)} ${units[index]}`;
};

const fmtDuration = (seconds) => {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value < 0) return '';
  if (value < 1) return `${Math.round(value * 1000)}ms`;
  if (value < 60) return `${value.toFixed(value < 10 ? 1 : 0)}s`;
  const minutes = Math.floor(value / 60);
  return `${minutes}m${String(Math.round(value % 60)).padStart(2, '0')}s`;
};

/* Swift's default Codable form for Date is one number of seconds since the *2001* Apple
   reference date, not since 1970, so reading it as a Unix timestamp lands every session
   stamp in January 1970. Add the offset between the two epochs. */
const SWIFT_DATE_EPOCH_OFFSET_SECONDS = 978307200;
const toDate = (value) => {
  if (value === undefined || value === null) return null;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return null;
    return new Date((value + SWIFT_DATE_EPOCH_OFFSET_SECONDS) * 1000);
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
};

const fmtTime = (value) => {
  const date = toDate(value);
  return date ? date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
};

const fmtRelative = (value) => {
  const date = toDate(value) || new Date();
  const delta = (nowMS() - date.getTime()) / 1000;
  if (delta < 60) return 'now';
  if (delta < 3600) return `${Math.floor(delta / 60)}m`;
  if (delta < 86400) return `${Math.floor(delta / 3600)}h`;
  if (delta < 604800) return `${Math.floor(delta / 86400)}d`;
  return date.toLocaleDateString([], { month: 'short', day: 'numeric' });
};

/* --------------------------------------------------- safe markdown subset */

/** `ContentRef` on the wire is `{id:{rawValue}, mediaType?, byteCount?, …}`: it has
    no path or title, so the chip label falls back to the ref id itself. */
const contentRefLabel = (ref) => {
  if (typeof ref === 'string') return ref;
  const id = idOf(pick(ref, 'id'));
  return String(pick(ref, 'mediaType') || (id ? String(id).slice(-8) : '') || 'ref');
};

const escapeHTML = (text) => String(text)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function inline(text) {
  let html = escapeHTML(text);
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  html = html.replace(/\*\*\*([^*]+)\*\*\*/g, '<strong><em>$1</em></strong>');
  html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/(^|[^\w*])\*([^*\n]+)\*(?=[^\w*]|$)/g, '$1<em>$2</em>');
  html = html.replace(/(^|[^~])~~([^~]+)~~/g, '$1<s>$2</s>');
  html = html.replace(/\[([^\]]+)\]\(((?:https?:|mailto:|#|\/)[^)\s]*)\)/g,
    '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  return html;
}

/** Renders Core text as escaped HTML: model output is never trusted with markup. */
function renderMarkdown(container, source) {
  const text = String(source ?? '');
  if (!text.trim()) { container.remove(); return container; }
  const lines = text.split('\n');
  let cursor = 0;
  while (cursor < lines.length) {
    const line = lines[cursor];
    if (/^\s*$/.test(line)) { cursor += 1; continue; }
    const fence = line.match(/^```(\w*)\s*$/);
    if (fence) {
      const body = [];
      cursor += 1;
      while (cursor < lines.length && !/^```\s*$/.test(lines[cursor])) { body.push(lines[cursor]); cursor += 1; }
      cursor += 1;
      const pre = el('pre');
      const code = el('code', null, body.join('\n'));
      pre.append(code);
      const copy = el('button', 'copy-btn', 'copy');
      copy.onclick = () => navigator.clipboard?.writeText(body.join('\n'));
      const wrap = el('div', 'code-block');
      wrap.style.position = 'relative';
      wrap.append(pre, copy);
      container.append(wrap);
      continue;
    }
    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      const node = el(`h${heading[1].length}`);
      node.innerHTML = inline(heading[2]);
      container.append(node);
      cursor += 1;
      continue;
    }
    if (/^\s*[-*+]\s+/.test(line)) {
      const list = el('ul');
      while (cursor < lines.length && /^\s*[-*+]\s+/.test(lines[cursor])) {
        const item = el('li');
        item.innerHTML = inline(lines[cursor].replace(/^\s*[-*+]\s+/, ''));
        list.append(item);
        cursor += 1;
      }
      container.append(list);
      continue;
    }
    if (/^\s*\d+[.)]\s+/.test(line)) {
      const list = el('ol');
      while (cursor < lines.length && /^\s*\d+[.)]\s+/.test(lines[cursor])) {
        const item = el('li');
        item.innerHTML = inline(lines[cursor].replace(/^\s*\d+[.)]\s+/, ''));
        list.append(item);
        cursor += 1;
      }
      container.append(list);
      continue;
    }
    if (/^\s*\|.*\|\s*$/.test(line) && cursor + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[cursor + 1])) {
      const table = el('table');
      const head = el('tr');
      for (const cell of line.trim().slice(1, -1).split('|')) head.append(el('th', null, cell.trim()));
      const headEl = el('thead');
      headEl.append(head);
      table.append(headEl);
      const bodyEl = el('tbody');
      cursor += 2;
      while (cursor < lines.length && /^\s*\|.*\|\s*$/.test(lines[cursor])) {
        const row = el('tr');
        for (const cell of lines[cursor].trim().slice(1, -1).split('|')) row.append(el('td', null, cell.trim()));
        bodyEl.append(row);
        cursor += 1;
      }
      table.append(bodyEl);
      container.append(table);
      continue;
    }
    if (/^\s*>\s?/.test(line)) {
      const quote = el('blockquote');
      while (cursor < lines.length && /^\s*>\s?/.test(lines[cursor])) {
        const para = el('p');
        para.innerHTML = inline(lines[cursor].replace(/^\s*>\s?/, ''));
        quote.append(para);
        cursor += 1;
      }
      container.append(quote);
      continue;
    }
    const paragraph = [];
    while (cursor < lines.length && !/^\s*$/.test(lines[cursor])
      && !/^```/.test(lines[cursor]) && !/^#{1,4}\s/.test(lines[cursor])
      && !/^\s*[-*+]\s+/.test(lines[cursor]) && !/^\s*\d+[.)]\s+/.test(lines[cursor])
      && !/^\s*>\s?/.test(lines[cursor]) && !/^\s*\|.*\|\s*$/.test(lines[cursor])) {
      paragraph.push(lines[cursor]);
      cursor += 1;
    }
    const para = el('p');
    para.innerHTML = inline(paragraph.join('\n'));
    container.append(para);
  }
  return container;
}

function renderDiff(container, text) {
  const wrap = el('div', 'diff');
  for (const line of String(text ?? '').split('\n')) {
    let cls = 'diff-line';
    if (line.startsWith('+') && !line.startsWith('+++')) cls += ' diff-add';
    else if (line.startsWith('-') && !line.startsWith('---')) cls += ' diff-del';
    else if (line.startsWith('@@')) cls += ' diff-hunk';
    else if (line.startsWith('diff ') || line.startsWith('index ') || line.startsWith('---') || line.startsWith('+++')) cls += ' diff-meta';
    wrap.append(el('span', cls, line || ' '));
  }
  container.append(wrap);
}

/* -------------------------------------------------------------- timeline */

const FAMILY_GLYPH = {
  mcp: 'MCP', skill: 'SKL', browser: 'WEB', computer: 'GUI', fileEdit: 'EDI', fileRead: 'RD',
  search: 'SRCH', shell: 'SH', git: 'GIT', subagent: 'AGT', network: 'NET', other: 'TOL',
};

function familyOf(tool) {
  /* `toolFamily` is encoded by ToolNode itself (shared ToolFamily rule), so it is
     authoritative; the name sniffing below is only a fallback for old frames. */
  const explicit = pick(tool, 'toolFamily', 'tool_family');
  if (typeof explicit === 'string') return explicit;
  if (explicit && typeof explicit === 'object') return Object.keys(explicit)[0];
  const name = String(pick(tool, 'toolName', 'tool_name') || '').toLowerCase();
  if (/^mcp[_.:]/.test(name)) return 'mcp';
  if (/skill|load_skill/.test(name)) return 'skill';
  if (/browser|chrome/.test(name)) return 'browser';
  if (/computer|desktop|screenshot|accessibilit/.test(name)) return 'computer';
  if (/edit|write|patch/.test(name)) return 'fileEdit';
  if (/read/.test(name)) return 'fileRead';
  if (/grep|glob|search|find/.test(name)) return 'search';
  if (/bash|shell|exec|command|terminal|process/.test(name)) return 'shell';
  if (/git|worktree|commit|diff/.test(name)) return 'git';
  if (/subagent|^agent|task|spawn/.test(name)) return 'subagent';
  if (/webfetch|websearch|fetch|http/.test(name)) return 'network';
  return 'other';
}

function renderTimeline() {
  const list = $('timeline');
  const scroller = list;
  const stick = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 90;
  const session = activeSession();
  $('timeline-empty').hidden = store.order.length > 0 || !session;

  if (timelineFullRebuild) {
    list.replaceChildren();
    timelineRows.clear();
    timelineFullRebuild = false;
  }

  let previous = null;
  for (const id of store.order) {
    const node = store.nodes.get(id);
    if (!node) continue;
    let element = timelineRows.get(id);
    if (element) {
      if (dirtyNodes.has(id)) {
        const rebuilt = buildRow(node, id);
        if (rebuilt) {
          element.replaceWith(rebuilt);
          timelineRows.set(id, rebuilt);
          element = rebuilt;
        }
      }
    } else {
      element = buildRow(node, id);
      if (!element) continue;
      timelineRows.set(id, element);
    }
    // Reorder only the rows that are not already where the transcript wants them.
    const wanted = previous ? previous.nextSibling : list.firstChild;
    if (wanted !== element) list.insertBefore(element, wanted);
    previous = element;
  }

  for (const [id, element] of timelineRows) {
    if (!store.nodes.has(id)) {
      element.remove();
      timelineRows.delete(id);
    }
  }
  dirtyNodes.clear();

  if (stick) scroller.scrollTop = scroller.scrollHeight;
  updateJumpButton();
}

function buildRow(node, id) {
  const { type, body } = nodeParts(node);
  return renderNode(type, body, node, id);
}

function renderNode(type, body, node, id) {
  switch (type) {
    case 'message': return renderMessage(body, id);
    case 'thinking': return renderThinking(body, id);
    case 'tool': return renderTool(body, id);
    case 'interaction': return renderInteraction(body, id);
    case 'subagent': return renderSubagent(body, id);
    case 'runTerminal': return renderRunTerminal(body);
    case 'error': return renderError(body);
    default: {
      const item = el('li', 'tl-node tl-rule');
      item.append(el('span', 'tl-rule-label', `unsupported node · ${type}`));
      return item;
    }
  }
}

function renderMessage(body, id) {
  const role = String(pick(body, 'role') || 'assistant').toLowerCase();
  const content = String(pick(body, 'content') || '');
  if (role === 'user') {
    const item = el('li', 'tl-node tl-user');
    item.dataset.id = id;
    const wrap = el('div', 'tl-user-body');
    const text = el('div', 'tl-user-text', content);
    if (content.length > 520) {
      text.classList.add('is-collapsed');
      const toggle = el('button', 'tl-user-toggle', '展开全文');
      toggle.onclick = () => {
        const collapsed = text.classList.toggle('is-collapsed');
        toggle.textContent = collapsed ? '展开全文' : '收起';
      };
      wrap.append(text, toggle);
    } else {
      wrap.append(text);
    }
    const citations = pick(body, 'citations');
    if (Array.isArray(citations) && citations.length) {
      const chips = el('div', 'tl-user-att');
      for (const cite of citations.slice(0, 12)) {
        chips.append(el('span', 'cite', contentRefLabel(cite)));
      }
      wrap.append(chips);
    }
    item.append(wrap);
    return item;
  }

  const item = el('li', 'tl-node tl-assistant');
  item.dataset.id = id;
  const md = el('div', 'md');
  renderMarkdown(md, content);
  if (pick(body, 'isStreaming', 'is_streaming')) md.append(el('span', 'cursor'));
  item.append(md);
  const metrics = pick(body, 'metrics');
  const meta = el('div', 'msg-meta');
  if (metrics) {
    /* MessageMetrics is `{model?, durationMs?, firstTokenMs?, tokenRate?, totalTokens?,
       completedAt?}` — there is no outputTokens / latency / costUSD on the wire. */
    const durationMs = Number(pick(metrics, 'durationMs', 'duration_ms'));
    const tokens = Number(pick(metrics, 'totalTokens', 'total_tokens'));
    const model = pick(metrics, 'model');
    if (Number.isFinite(durationMs) && durationMs > 0) meta.append(el('span', null, fmtDuration(durationMs / 1000)));
    if (Number.isFinite(tokens) && tokens > 0) meta.append(el('span', null, `${fmtTokens(tokens)} tok`));
    if (model) meta.append(el('span', null, String(model)));
  }
  if (pick(body, 'citations')?.length) {
    const chips = el('div', 'msg-citations');
    for (const cite of body.citations.slice(0, 16)) {
      chips.append(el('span', 'cite', contentRefLabel(cite)));
    }
    item.append(chips);
  }
  if (meta.childElementCount) item.append(meta);
  if (!content.trim() && !pick(body, 'isStreaming', 'is_streaming')) item.remove();
  return item;
}

function renderThinking(body, id) {
  const content = String(pick(body, 'content') || '');
  if (!content.trim()) return null;
  const details = el('details', 'tl-node tl-thinking');
  details.dataset.id = id;
  details.open = store.openThinkingIDs.has(id);
  details.ontoggle = () => { details.open ? store.openThinkingIDs.add(id) : store.openThinkingIDs.delete(id); };
  const streaming = Boolean(pick(body, 'isStreaming', 'is_streaming'));
  if (streaming) details.classList.add('is-streaming');
  const summary = el('summary');
  summary.append(el('span', null, streaming ? 'thinking…' : (pick(body, 'title') || 'thought')));
  /* `Duration` is not Codable, so ThinkingNode carries it as `durationSeconds` (a
     plain number of seconds). */
  const duration = Number(pick(body, 'durationSeconds', 'duration_seconds'));
  if (Number.isFinite(duration)) {
    summary.append(el('span', 'tool-dur', fmtDuration(duration)));
  }  details.append(summary);
  const bodyEl = el('div', 'thinking-body');
  renderMarkdown(bodyEl, content);
  details.append(bodyEl);
  // Keep only the live one expanded so the stream reads like a narrative.
  if (streaming) details.open = true;
  return details;
}

function parseArgs(json) {
  if (!json) return null;
  if (typeof json === 'object') return json;
  try { return JSON.parse(String(json)); } catch { return null; }
}

/* ToolNode has no duration field: prefer the executor timing carried by the result
   (`executionMilliseconds`), else the span between executorStartedAt and
   executorFinishedAt, which are seconds-since-1970 numbers. */
function toolDurationSeconds(body) {
  const exec = Number(pick(pick(body, 'result'), 'timing')?.executionMilliseconds);
  if (Number.isFinite(exec) && exec > 0) return exec / 1000;
  const started = toDate(pick(body, 'executorStartedAt', 'executor_started_at'));
  const finished = toDate(pick(body, 'executorFinishedAt', 'executor_finished_at'));
  if (started && finished) return Math.max(0, (finished.getTime() - started.getTime()) / 1000);
  return null;
}

/** RuntimeError is `{id, category, code, message, retryability, source, diagnosticsRef?}`. */
function runtimeErrorText(error) {
  if (!error) return '';
  if (typeof error === 'string') return error;
  const parts = [
    enumName(pick(error, 'category')),
    pick(error, 'code'),
    pick(error, 'message'),
    enumName(pick(error, 'source')),
  ].filter((value) => value !== null && value !== undefined && value !== '');
  return parts.join(' · ');
}

function renderTool(body, id) {
  const name = String(pick(body, 'toolName', 'tool_name') || 'tool');
  const phase = String(pick(body, 'phase') || 'requested');
  const family = familyOf(body);
  const item = el('li', `tl-node tl-tool tool-family-${family}`);
  item.dataset.id = id;

  const row = el('div', 'tool-row');
  row.append(el('span', 'tool-glyph', FAMILY_GLYPH[family] || 'TOL'));
  row.append(el('span', 'tool-name', name));
  const args = parseArgs(pick(body, 'argumentsJSON', 'arguments_json'));
  row.append(el('span', 'tool-summary', argsSummary(args)));
  const phaseLabel = el('span', 'tool-phase', phaseLabelFor(phase));
  phaseLabel.dataset.phase = phase;
  if (phase === 'running' || phase === 'scheduled') phaseLabel.prepend(el('span', 'spin'));
  row.append(phaseLabel);
  const seconds = toolDurationSeconds(body);
  row.append(el('span', 'tool-dur', seconds === null ? '' : fmtDuration(seconds)));
  item.append(row);

  const panel = el('div', 'tool-body');
  panel.hidden = !store.openToolIDs.has(id);
  const sections = [];
  if (args && Object.keys(args).length) {
    const grid = el('dl', 'tool-args-grid');
    for (const [key, value] of Object.entries(args).slice(0, 24)) {
      grid.append(el('dt', null, key));
      grid.append(el('dd', null, typeof value === 'string' ? value : JSON.stringify(value)));
    }
    sections.push(section('arguments', grid, () => JSON.stringify(args, null, 2)));
  }
  const diff = toolDiff(body, args);
  if (diff) {
    const wrap = el('div');
    renderDiff(wrap, diff);
    const stat = diffStat(diff);
    const label = el('div', 'tool-section-label');
    label.append(el('span', null, 'diff'));
    if (stat) {
      const span = el('span', 'diff-stat');
      span.append(el('span', 'add', `+${stat.add}`), el('span', 'del', `-${stat.del}`));
      label.append(span);
    }
    wrap.prepend(label);
    wrap.style.border = '1px solid var(--line-1)';
    wrap.style.borderRadius = 'var(--r-2)';
    wrap.style.background = 'var(--ink-950)';
    sections.push(wrap);
  }
  const stdout = pick(body, 'stdout');
  if (stdout) sections.push(section('stdout', preBlock(stdout), () => String(stdout)));
  const stderr = pick(body, 'stderr');
  if (stderr) sections.push(section('stderr', preBlock(stderr, true), () => String(stderr)));
  const result = pick(body, 'result');
  if (result) {
    /* ToolResultSnapshot is `{callID, toolName?, success, summary, preview?, contentRef?,
       error?, timing}`: the old output/content/text/message reads matched nothing. */
    const ok = pick(result, 'success') !== false;
    const parts = [];
    for (const value of [pick(result, 'summary'), pick(result, 'preview')]) {
      if (value) parts.push(String(value));
    }
    const failure = pick(result, 'error');
    if (failure) parts.push(runtimeErrorText(failure));
    const text = parts.join('\n\n');
    sections.push(section(ok ? 'result' : 'result · failed', preBlock(text, !ok), () => text));
  }
  const error = pick(body, 'error');
  if (error) {
    const text = runtimeErrorText(error);
    sections.push(section('error', preBlock(text, true), () => String(text)));
  }
  if (sections.length) {
    item.append(panel);
    panel.append(...sections);
  }
  panel.hidden = !store.openToolIDs.has(id);
  row.onclick = () => {
    const open = !store.openToolIDs.has(id);
    open ? store.openToolIDs.add(id) : store.openToolIDs.delete(id);
    panel.hidden = !open;
    item.classList.toggle('is-open', open);
  };
  item.classList.toggle('is-open', store.openToolIDs.has(id));
  return item;
}

function section(label, content, copySource) {
  const wrap = el('div', 'tool-section');
  const head = el('div', 'tool-section-label');
  head.append(el('span', null, label));
  if (copySource) {
    const button = el('button', 'copy-btn', 'copy');
    button.onclick = (event) => {
      event.stopPropagation();
      navigator.clipboard?.writeText(copySource());
      button.textContent = 'copied';
      setTimeout(() => { button.textContent = 'copy'; }, 1200);
    };
    head.append(button);
  }
  wrap.append(head, content);
  return wrap;
}

function preBlock(text, danger) {
  const pre = el('pre');
  if (danger) pre.style.color = 'var(--danger)';
  pre.textContent = String(text);
  return pre;
}

function argsSummary(args) {
  if (!args || typeof args !== 'object') return '';
  const preferred = ['path', 'file_path', 'command', 'query', 'pattern', 'url', 'prompt', 'description', 'title', 'goal'];
  for (const key of preferred) if (typeof args[key] === 'string') return truncate(args[key], 90);
  const first = Object.values(args).find((value) => typeof value === 'string' || typeof value === 'number');
  return first === undefined ? '' : truncate(String(first), 90);
}

const truncate = (text, limit) => {
  const single = String(text).replace(/\s+/g, ' ').trim();
  return single.length > limit ? `${single.slice(0, limit)}…` : single;
};

function toolDiff(body, args) {
  /* ToolNode has no `diff` field, so a diff can only ever come from the tool's own
     arguments or from the result text Core already rendered. */
  const looksLikeDiff = (value) => typeof value === 'string' && /(^|\n)(@@|\+\+\+|---|\+\S|\-\S)/.test(value);
  for (const value of [pick(args, 'diff'), pick(args, 'patch'), pick(args, 'unifiedDiff'), pick(args, 'unified_diff')]) {
    if (looksLikeDiff(value)) return value;
  }
  const result = pick(body, 'result');
  for (const value of [pick(result, 'preview'), pick(result, 'summary')]) {
    if (looksLikeDiff(value)) return value;
  }
  return null;
}

function diffStat(text) {
  let add = 0; let del = 0;
  for (const line of String(text).split('\n')) {
    if (line.startsWith('+') && !line.startsWith('+++')) add += 1;
    else if (line.startsWith('-') && !line.startsWith('---')) del += 1;
  }
  return add || del ? { add, del } : null;
}

/* The workspace delta is counted by Core (`git diff --numstat`, same range as the shown
   diff), so counting `+`/`-` here stays only the fallback for an older Core. */
function workspaceDiffStat(diff) {
  const add = Number(pick(diff, 'addedLines', 'added_lines'));
  const del = Number(pick(diff, 'deletedLines', 'deleted_lines'));
  if (Number.isFinite(add) && Number.isFinite(del)) return { add, del };
  return diffStat(String(diff.diff || ''));
}

function phaseLabelFor(phase) {
  return ({
    requested: 'queued', waitingPermission: 'waiting', scheduled: 'scheduled',
    running: 'running', completed: 'done', failed: 'failed', cancelled: 'cancelled',
  })[phase] || phase;
}

/* InteractionNode.kind is a bare `String` value ("permission" | "question" |
   "decision" | "unknown") and its request is NOT nested under the kind key: the
   payload lives in permissionRequest / questionRequest / decisionRequest. */
const interactionKind = (body) => String(enumName(pick(body, 'kind')) || 'permission');

function interactionPayload(body, kindName) {
  if (kindName === 'question') return pick(body, 'questionRequest', 'question_request');
  if (kindName === 'decision') return pick(body, 'decisionRequest', 'decision_request');
  if (kindName === 'permission') return pick(body, 'permissionRequest', 'permission_request');
  return null;
}

/** InteractionResolution is a `kind`-discriminated object, not an enum tag. */
function resolutionText(resolution) {
  if (!resolution) return '—';
  if (typeof resolution === 'string') return resolution;
  const kind = String(pick(resolution, 'kind') || 'unknown');
  const value = pick(resolution, kind, 'rawValue');
  return `${kind} · ${value && typeof value === 'object' ? JSON.stringify(value) : String(value ?? '')}`;
}

function renderInteraction(body, id) {
  const kindName = interactionKind(body);
  const payload = interactionPayload(body, kindName);
  const resolved = Boolean(pick(body, 'isResolved', 'is_resolved'));
  const item = el('li', `tl-node tl-interaction ${resolved ? 'interaction-resolved' : 'interaction-pending'}`);
  item.dataset.id = id;

  const head = el('div', 'interaction-head');
  head.append(el('span', 'interaction-tag', kindName));
  const owner = ownerLabel(body);
  if (owner) head.append(el('span', 'attention-owner', owner));
  if (!resolved) item.append(head);

  const detail = interactionDetail(payload, kindName);
  if (resolved) {
    /* An answered ask is history, not a decision still on the table: one quiet line keeps the
       timeline readable while the pending card above it stays the only thing that shouts. */
    const line = el('div', 'interaction-resolved-line');
    line.append(el('span', 'interaction-tag', kindName));
    line.append(el('span', 'interaction-resolution', resolutionText(pick(body, 'resolution'))));
    if (detail && (detail.title || detail.subject)) {
      line.append(el('span', 'interaction-summary', truncate(detail.subject || detail.title, 90)));
    }
    if (owner) line.append(el('span', 'attention-owner', owner));
    item.append(line);
    return item;
  }
  if (detail) {
    const bodyEl = el('div', 'interaction-body');
    if (detail.title) bodyEl.append(el('div', null, detail.title));
    if (detail.subject) bodyEl.append(el('div', 'attention-detail', detail.subject));
    item.append(bodyEl);
  }
  return item;
}

function ownerLabel(body) {
  const causal = pick(body, 'causal') || {};
  const session = idOf(pick(causal, 'sessionID', 'session_id'));
  const run = idOf(pick(causal, 'runID', 'run_id'));
  /* CausalContext has no isChild flag: a parent run, or a run that is not its own
     root run, is what makes this interaction belong to a child agent. */
  const rootRun = idOf(pick(causal, 'rootRunID', 'root_run_id'));
  const isChild = Boolean(pick(causal, 'parentRunID', 'parent_run_id')
    || (run && rootRun && run !== rootRun));
  if (!session && !run && !isChild) return null;
  const short = session ? `session ${String(session).slice(-6)}` : '';
  return [isChild ? 'child agent' : null, short].filter(Boolean).join(' · ');
}

function interactionDetail(payload, kindName) {
  if (kindName === 'question' || kindName === 'decision') {
    const question = String(pick(payload, 'question') || '');
    const options = optionList(payload);
    return {
      title: question || 'Agent is waiting for you',
      subject: options.map((option, index) => `${index + 1}. ${option.value}`).join('\n'),
    };
  }
  /* PermissionRequest = {permissionID, sessionID, runID?, toolCallID?, toolID?,
     capabilities: [String], resource?, description?}. */
  const description = pick(payload, 'description');
  const resource = pick(payload, 'resource');
  const tool = idOf(pick(payload, 'toolID', 'tool_id'));
  const capabilities = pick(payload, 'capabilities');
  const subject = [
    tool && `tool ${tool}`,
    resource && `path ${resource}`,
    (Array.isArray(capabilities) && capabilities.length) && `caps ${capabilities.map((item) => enumName(item)).filter(Boolean).join(' · ')}`,
  ].filter(Boolean).join('  ·  ');
  return { title: String(description || (subject ? 'Approval required' : 'Agent is waiting for you')), subject };
}

function renderSubagent(body, id) {
  const item = el('li', 'tl-node tl-subagent');
  item.dataset.id = id;
  const status = String(pick(body, 'status') || 'running');
  item.append(el('span', 'tool-glyph', 'AGT'));
  const meta = el('div');
  const runID = idOf(pick(body, 'runID', 'run_id'));
  meta.append(el('span', 'tool-name', runID ? `subagent ${String(runID).slice(-8)}` : 'subagent'));
  const preview = pick(body, 'resultPreview', 'result_preview');
  if (preview) meta.append(el('div', 'subagent-body', truncate(preview, 260)));
  item.append(meta);
  const badge = el('span', 'subagent-status', status);
  badge.dataset.status = status;
  item.append(badge);
  /* Core marks a child that terminated after its originating turn stopped waiting on it.
     Without that flag the outcome is indistinguishable from an on-time completion. */
  if (pick(body, 'late') === true) item.append(el('span', 'subagent-late', 'late result'));
  return item;
}

function renderRunTerminal(body) {
  /* `TerminalReason` has exactly 8 cases: cancelled reads as interrupted, the three
     failure cases as error, the three "stopped early" cases share the warn tone
     (CSS `recovery`), and `completed` is the plain rule. */
  const reason = String(enumName(pick(body, 'terminalReason', 'terminal_reason')) || 'completed');
  const tone = ({
    userCancelled: 'interrupt',
    providerFailure: 'error',
    runtimeFailure: 'error',
    blocked: 'error',
    deadlineExceeded: 'recovery',
    maxStepsReached: 'recovery',
    emptyCompletion: 'recovery',
    completed: 'plain',
  })[reason] || 'plain';
  const item = el('li', 'tl-node tl-rule');
  item.dataset.tone = tone;
  const label = { interrupt: 'interrupted', error: 'run failed', recovery: 'recovered', plain: 'run ended' }[tone];
  item.append(el('span', 'tl-rule-label', `${label} · ${reason}`));
  return item;
}

function renderError(body) {
  const item = el('li', 'tl-node tl-error');
  const code = pick(body, 'code') || 'error';
  item.append(el('span', 'err-code', String(code)));
  item.append(el('div', null, String(pick(body, 'message') || 'Unknown error')));
  const details = pick(body, 'details');
  if (details && Object.keys(details).length) {
    const fold = el('details');
    fold.append(el('summary', null, 'details'));
    const pre = el('pre');
    pre.textContent = Object.entries(details).map(([k, v]) => `${k}: ${v}`).join('\n');
    fold.append(pre);
    item.append(fold);
  }
  return item;
}

function updateJumpButton() {
  const scroller = $('timeline');
  const away = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight > 160;
  $('jump-latest').hidden = !away;
}

/* ------------------------------------------------------------ header/meta */

function renderConnection() {
  const button = $('rail-connection');
  /* Core publishes a six-state link (`ConnectionStatus`); the rail dot only has three
     slots in CSS, so they collapse. The EventSource socket is a second input: while it
     is down the link is never reported as connected, even if the last frame said so. */
  const core = connectionStatus();
  let state;
  if (core === 'failed') state = 'disconnected';
  else if (store.connected && (core === 'connected' || core === '')) state = 'connected';
  else state = 'connecting';
  button.dataset.state = state;
  const detail = pick(store.state.connectionState, 'detail');
  button.title = state === 'connected'
    ? 'Core 已连接'
    : (detail ? `${state === 'disconnected' ? 'Core 连接失败' : '正在重连 Core…'}：${detail}`
      : (state === 'disconnected' ? 'Core 连接失败' : '正在重连 Core…'));
}

function renderRail() {
  const rail = $('rail-projects');
  rail.replaceChildren();
  const rootPath = workspaceRoot();
  const groups = new Map();
  for (const session of sessionCatalog()) {
    const workspace = pick(session, 'workingDirectory', 'working_directory') || rootPath || '(no workspace)';
    groups.set(workspace, (groups.get(workspace) || 0) + 1);
  }
  const activeWorkspace = pick(activeSession(), 'workingDirectory', 'working_directory') || rootPath;
  let index = 0;
  for (const [workspace, count] of groups) {
    const button = el('button', 'rail-proj', workspaceLabel(workspace).slice(0, 2));
    button.title = `${workspace} · ${count} session${count > 1 ? `s` : ''}`;
    if (workspace === activeWorkspace) button.classList.add('is-active');
    button.onclick = () => {
      const first = sessionCatalog().find((session) => (
        (pick(session, 'workingDirectory', 'working_directory') || rootPath || '(no workspace)') === workspace
      ));
      const id = idOf(pick(first, 'sessionID', 'session_id'));
      if (id) command({ switchSession: { sessionID: wireID(id) } });
    };
    rail.append(button);
    if (++index >= 8) break;
  }
  const cwd = activeWorkspace || rootPath || FileManagerCWD();
  $('sidebar-cwd').title = cwd || '';
  $('sidebar-cwd').querySelector('.cwd-name').textContent = cwd ? workspaceLabel(cwd) : 'workspace';
}

/* WorkspaceSummary = {rootPath, isGitRepository, codebaseNodes?, codebaseEdges?,
   indexingState?}: there is no `path`, no branch and no dirty count. */
const workspaceRoot = () => {
  const root = pick(store.state.currentWorkspace, 'rootPath');
  return typeof root === 'string' ? root : '';
};

const FileManagerCWD = () => workspaceRoot();

function workspaceLabel(path) {
  const parts = String(path || '').split('/').filter(Boolean);
  return parts[parts.length - 1] || String(path || '/');
}

function renderHeader() {
  const session = activeSession();
  const summary = sessionCatalog().find((item) => (
    idOf(pick(item, 'sessionID', 'session_id')) === idOf(pick(store.state, 'activeSessionID', 'active_session_id'))
  )) || {};
  $('session-title').textContent = String(pick(summary, 'title') || pick(session, 'title') || 'Session');

  const meta = $('stage-meta');
  meta.replaceChildren();
  const workspace = pick(session, 'workingDirectory', 'working_directory') || workspaceRoot();
  if (workspace) meta.append(el('span', 'meta-mono', workspaceLabel(workspace)));
  const git = gitInfo();
  if (git.isRepository || git.branch) {
    const branch = el('span', 'meta-git', git.branch ? `  ${git.branch}` : '  git');
    if (git.dirty) branch.append(el('span', 'meta-dirty', ` · ${git.dirty} changed`));
    meta.append(branch);
  }
  const models = selectedModelLabel();
  if (models) meta.append(el('span', null, models));
  const counts = `${activeMCPCount()} MCP · ${activeSkillCount()} skills`;
  meta.append(el('span', null, counts));

  const run = $('stage-run');
  run.replaceChildren();
  const pending = pendingInteractions().length;
  const running = isRunning();
  const runtime = runtimeStatus();
  const status = el('span', 'run-pill');
  if (pending || runtime === 'ActionRequired') {
    status.dataset.tone = 'waiting';
    status.append(el('span', null, pending ? `${pending} 需要处理` : '需要处理'));
  } else if (running) {
    status.dataset.tone = 'running';
    status.append(el('span', 'spin'), el('span', null, 'running'));
  } else if (runtime === 'Error' || pick(store.state, 'hasActiveError', 'has_active_error')) {
    status.dataset.tone = 'error';
    status.append(el('span', null, 'error'));
  } else if (runtime === 'Disconnected' || runtime === 'Reconnecting') {
    status.dataset.tone = 'error';
    status.append(el('span', null, runtime.toLowerCase()));
  } else {
    status.append(el('span', null, 'idle'));
  }
  run.append(status);
}

function gitInfo() {
  const workspace = store.state.currentWorkspace || {};
  const branch = pick(workspace, 'gitBranch', 'git_branch', 'branch');
  const dirty = pick(workspace, 'changedFileCount', 'changed_file_count', 'dirtyCount', 'dirty_count');
  const worktree = pick(workspace, 'worktreeRoot', 'worktree_root');
  return {
    rootPath: typeof pick(workspace, 'rootPath') === 'string' ? pick(workspace, 'rootPath') : null,
    isRepository: Boolean(pick(workspace, 'isGitRepository', 'is_git_repository')),
    /* Core computes all of this: `gitBranch` is nil when detached or unknown, and a nil
       dirty count is "not measured yet", which is not the same claim as a dirty count of 0. */
    branch: typeof branch === 'string' ? branch : null,
    dirty: typeof dirty === 'number' ? dirty : null,
    linked: Boolean(pick(workspace, 'isLinkedWorktree', 'is_linked_worktree')),
    worktreeRoot: typeof worktree === 'string' ? worktree : null,
  };
}

function selectedModelLabel() {
  /* ModelSelectionInfo is `{modelID, providerID?}` — no displayName on the wire, so
     the human name has to come from the models[] entry that carries the same id. */
  const current = pick(store.state.selectedModel, 'modelID')
    || pick(store.state, 'currentModelID', 'current_model_id')
    || '';
  if (!current) return null;
  const info = (store.state.models || []).find((model) => (
    pick(model, 'modelID') === current || pick(model, 'id') === current
  ));
  return String(pick(info, 'displayName') || current);
}

function activeMCPCount() {
  return extensionCount('mcp');
}
function activeSkillCount() {
  return extensionCount('skill');
}
function extensionCount(kind) {
  const list = store.state.extensions || [];
  if (!list.length) return 0;
  return list.filter((item) => String(pick(item, 'kind') || '').toLowerCase() === kind).length;
}

/* ---------------------------------------------------------------- sessions */

function renderSessions() {
  const list = $('session-list');
  list.replaceChildren();
  const filter = store.sessionFilter.toLowerCase();
  const catalog = sessionCatalog().filter((session) => {
    if (!filter) return true;
    return String(pick(session, 'title', 'sessionID', 'session_id') || '').toLowerCase().includes(filter);
  });
  if (!catalog.length) {
    list.append(el('div', 'session-empty', sessionCatalog().length ? '无匹配 Session' : '还没有 Session'));
    return;
  }
  const active = idOf(pick(store.state, 'activeSessionID', 'active_session_id'));
  const buckets = new Map();
  for (const session of catalog) {
    /* Dates are epoch-second numbers, so `new Date(updatedAt)` would land in 1970. */
    const stamp = toDate(pick(session, 'updatedAt', 'updated_at', 'createdAt', 'created_at')) || new Date();
    const label = relativeBucket(stamp);
    if (!buckets.has(label)) buckets.set(label, []);
    buckets.get(label).push({ session, stamp });
  }
  for (const [label, items] of buckets) {
    list.append(el('div', 'session-group-label', label));
    for (const { session, stamp } of items.sort((a, b) => b.stamp - a.stamp)) {
      list.append(sessionRow(session, idOf(pick(session, 'sessionID', 'session_id')), active, stamp));
    }
  }
}

function relativeBucket(date) {
  const delta = (nowMS() - date.getTime()) / 86400000;
  if (delta < 1) return '今天';
  if (delta < 2) return '昨天';
  if (delta < 8) return '本周';
  return '更早';
}

function sessionRow(session, id, activeID, stamp) {
  const row = el('div', 'session-row');
  if (id === activeID) row.classList.add('is-active');
  row.setAttribute('role', 'option');
  const state = el('span', 'session-row-state');
  state.dataset.state = id === activeID ? (isRunning() ? 'running' : 'idle') : 'idle';
  row.append(state);
  row.append(el('span', 'session-row-title', String(pick(session, 'title') || id || 'untitled')));
  row.append(el('span', 'session-row-time', fmtRelative(stamp)));
  /* SessionSummary has no preview/lastMessage field; the per-session goal anchor is
     the only second line the projection actually carries. */
  const sub = pick(session, 'goal');
  if (sub) row.append(el('span', 'session-row-sub', truncate(sub, 80)));
  row.onclick = () => id && command({ switchSession: { sessionID: wireID(id) } });

  const actions = el('div', 'session-row-actions');
  const rename = el('button', 'icon-btn', '✎');
  rename.title = '重命名';
  rename.onclick = (event) => {
    event.stopPropagation();
    const title = window.prompt('Session 标题', String(pick(session, 'title') || ''));
    if (title) command({ renameSession: { sessionID: wireID(id), newTitle: title } });
  };
  const remove = el('button', 'icon-btn', '🗑');
  remove.title = '删除';
  remove.onclick = (event) => {
    event.stopPropagation();
    if (window.confirm(`删除 Session ${id}？`)) command({ deleteSession: { sessionID: wireID(id) } });
  };
  actions.append(rename, remove);
  row.append(actions);
  return row;
}

/* -------------------------------------------------------------- attention */

function renderAttention() {
  const dock = $('attention-dock');
  const pending = pendingInteractions();
  dock.hidden = pending.length === 0;
  dock.replaceChildren();
  for (const { body, id } of pending) {
    dock.append(attentionCard(body, id));
  }
}

function attentionCard(body, id) {
  const kindName = interactionKind(body);
  const payload = interactionPayload(body, kindName);
  const card = el('div', 'attention-card');
  const glyph = el('div', 'attention-glyph');
  glyph.append(el('span', null, kindName === 'question' ? '?' : '!'));
  card.append(glyph);

  const detail = interactionDetail(payload, kindName);
  const wrap = el('div', 'attention-body');
  const title = el('div', 'attention-title');
  title.append(el('span', null, kindName === 'question' ? 'Agent 在提问' : kindName === 'decision' ? 'Agent 需要选择' : '需要授权'));
  const owner = ownerLabel(body);
  if (owner) title.append(el('span', 'attention-owner', owner));
  wrap.append(title, el('div', 'attention-sub', detail.title));
  if (detail.subject) wrap.append(el('pre', 'attention-detail', detail.subject));
  const interactionID = idOf(pick(body, 'interactionID', 'interaction_id')) || id;
  wrap.append(questionControls(kindName, payload, interactionID));
  card.append(wrap);
  return card;
}

/* QuestionReply = {questionID, selectedOptionIndices, cancelled, text?}. The questionID
   comes from the request, never from the interactionID. */
function questionReply(request, indices, text) {
  const reply = {
    questionID: wireID(pick(request, 'questionID', 'question_id')),
    selectedOptionIndices: indices,
    cancelled: false,
  };
  if (text) reply.text = text;
  return reply;
}

const cancelledQuestionReply = (request) => ({
  questionID: wireID(pick(request, 'questionID', 'question_id')),
  selectedOptionIndices: [],
  cancelled: true,
});

/* InteractionResolution is an object discriminated by `kind`, so a bare
   `{cancelled:{}}` / `{deny:{}}` never decodes server-side. */
const permissionResolution = (decision) => ({ kind: 'permission', permission: decision });
const questionResolution = (reply) => ({ kind: 'question', question: reply });

function questionControls(kind, request, interactionID) {
  const actions = el('div', 'attention-actions');
  const row = el('div', 'row');
  const options = optionList(request);

  if (kind === 'question') {
    if (options.length) {
      const list = el('div', 'attention-options');
      const picked = { index: -1 };
      for (const [index, option] of options.entries()) {
        const button = el('button', 'btn', option.label);
        button.onclick = () => {
          for (const sibling of list.children) sibling.classList.remove('is-picked');
          button.classList.add('is-picked');
          picked.index = index;
        };
        list.append(button);
      }
      const input = el('input', 'attention-input');
      input.placeholder = '或直接输入回答…';
      const send = el('button', 'btn btn-primary', '回答');
      const submit = () => {
        const text = input.value.trim();
        if (picked.index < 0 && !text) return;
        const indices = picked.index >= 0 ? [picked.index] : [];
        command({
          replyQuestion: { interactionID: wireID(interactionID), reply: questionReply(request, indices, text) },
        });
      };
      send.onclick = submit;
      input.onkeydown = (event) => { if (event.key === 'Enter') submit(); };
      actions.append(list, input, row);
      row.append(send, cancelOption(interactionID, kind, request));
      return actions;
    }
    const input = el('input', 'attention-input');
    input.placeholder = '输入回答…';
    const send = el('button', 'btn btn-primary', '回答');
    const submit = () => {
      const text = input.value.trim();
      if (!text) return;
      command({
        replyQuestion: { interactionID: wireID(interactionID), reply: questionReply(request, [], text) },
      });
    };
    send.onclick = submit;
    input.onkeydown = (event) => { if (event.key === 'Enter') submit(); };
    actions.append(input, row);
    row.append(send, cancelOption(interactionID, kind, request));
    return actions;
  }

  if (kind === 'decision' && options.length) {
    for (const option of options) {
      const button = el('button', 'btn', option.label);
      button.onclick = () => command({
        submitDecision: { decision: option.value, interactionID: wireID(interactionID) },
      });
      row.append(button);
    }
    actions.append(row);
    return actions;
  }

  // Permission: only the user can grant, and the risky options stay visibly distinct.
  if (kind !== 'permission') return actions;
  for (const option of permissionOptions(request)) {
    const button = el('button', option.danger ? 'btn btn-danger' : (option.primary ? 'btn btn-primary' : 'btn'), option.label);
    button.onclick = () => command({
      grantPermission: { decision: option.value, interactionID: wireID(interactionID) },
    });
    row.append(button);
  }
  actions.append(row);
  return actions;
}

function cancelOption(interactionID, kind, request) {
  const button = el('button', 'btn btn-ghost', '取消');
  button.onclick = () => command({
    respondInteraction: {
      interactionID: wireID(interactionID),
      resolution: kind === 'question'
        ? questionResolution(cancelledQuestionReply(request))
        : permissionResolution('ask'),
    },
  });
  return button;
}

/* QuestionRequest.options and DecisionRequest.options are arrays of plain strings. */
function optionList(payload) {
  const raw = pick(payload, 'options');
  if (!Array.isArray(raw)) return [];
  return raw.map((item) => {
    if (typeof item === 'string') return { label: item, value: item };
    const value = pick(item, 'value', 'id', 'label', 'title') ?? '';
    return { label: String(pick(item, 'label', 'title', 'description') || value), value: String(value) };
  }).filter((item) => item.value);
}

/* PermissionDecision is exactly allow | ask | deny: `once`, `alwaysForSession` and
   `reject` decode to nil, so those buttons silently did nothing. */
function permissionOptions(payload) {
  const decisions = [
    permissionShape('allow', '允许', true),
    permissionShape('ask', '稍后询问'),
    permissionShape('deny', '拒绝', false, true),
  ];
  const raw = pick(payload, 'options', 'decisions');
  if (!Array.isArray(raw) || !raw.length) return decisions;
  const allowed = decisions.filter((option) => raw.some((item) => enumName(item) === option.value));
  return allowed.length ? allowed : decisions;
}

function permissionShape(value, label, primary = false, danger = false) {
  return { value, label, primary, danger };
}

/* --------------------------------------------------------------- composer */

function renderComposer() {
  const session = activeSession();
  const state = store.state;

  const mode = modeValue();
  setChip('chip-mode', mode, modeLabel(mode));
  const effort = effortValue();
  setChip('chip-effort', effort, effortLabel(effort));
  setChip('chip-model', selectedModelLabel() || 'model', truncate(selectedModelLabel() || '选择模型', 22));
  const permission = permissionLabel(state);
  setChip('chip-permission', permission.value, permission.label);
  if (permission.danger) $('chip-permission').dataset.tone = 'yolo';
  else delete $('chip-permission').dataset.tone;

  renderStrip();
  renderAttachments();

  const running = isRunning();
  /* A run parked on an ask is still a run. Hiding Stop there left an ActionRequired session
     with no way out except answering, while Core's stop path is built to clear the asks. */
  const parked = (session?.pendingInteractions || []).length > 0;
  $('btn-send').hidden = running;
  $('btn-stop').hidden = !(running || parked);
  $('prompt').disabled = false;

  const status = $('composer-status');
  status.replaceChildren();
  const context = contextState();
  const used = Number(pick(context, 'estimatedTokens', 'estimated_tokens') || 0);
  const target = Number(pick(pick(context, 'pCore', 'p_core') || {}, 'targetTokens', 'target_tokens') || 0);
  if (used) {
    status.append(el('span', null, `ctx ${fmtTokens(used)}${target ? ` / ${fmtTokens(target)}` : ''}`));
  }
  const cache = pick(context, 'providerCache', 'provider_cache');
  if (cache) {
    const read = Number(pick(cache, 'cacheReadTokens', 'cache_read_tokens') || 0);
    status.append(el('span', null, `cache ${fmtTokens(read)} read`));
  }
  const tasks = (store.state.backgroundTasks || []).length;
  if (tasks) status.append(el('span', null, `${tasks} bg`));
  if (!store.connected) status.append(el('span', 'warn', 'stream 已断开，正在重连…'));
  const revisionInfo = el('span', null, `rev ${store.revision}`);
  revisionInfo.style.marginLeft = 'auto';
  status.append(revisionInfo);
}

function setChip(id, value, label) {
  const chip = $(id);
  chip.dataset.value = value;
  chip.querySelector('.chip-label').textContent = label;
}

/* AgentMode and ReasoningEffort are `String` enums, so they read as bare values. */
const modeValue = () => String(enumName(pick(store.state, 'nextTurnMode', 'next_turn_mode')
  || pick(activeSession(), 'mode')) || 'build');

/* `effectiveReasoningEffort` is a computed property, so it never reaches the wire:
   the browser derives the same value from the next-turn override and the session. */
const effortValue = () => String(enumName(pick(store.state, 'nextTurnReasoningEffort', 'next_turn_reasoning_effort')
  || pick(activeSession(), 'reasoningEffort', 'reasoning_effort')) || 'auto');

const modeLabel = (mode) => ({
  build: 'Build', plan: 'Plan', explore: 'Explore', unknown: 'Unknown',
}[String(mode).toLowerCase()] || String(mode));
const effortLabel = (effort) => ({
  auto: 'Auto', off: 'Off', minimal: 'Min', low: 'Low', medium: 'Med', high: 'High',
  xhigh: 'X-High', max: 'Max', ultra: 'Ultra',
}[String(effort).toLowerCase()] || String(effort));

/* The four frozen PermissionConfiguration presets, sent verbatim: approvalPolicy uses
   ApprovalDecision (allow|ask|deny|unknown) and accessScope AccessScope. */
const PERMISSION_PRESETS = {
  askWorkspace: {
    accessScope: 'workspace',
    approvalPolicy: {
      externalMutation: 'deny', externalRead: 'deny', processExecution: 'ask',
      safeRead: 'allow', sensitiveAccess: 'deny', workspaceMutation: 'ask',
    },
    policy: 'ask',
    profile: 'workspace',
  },
  autoWorkspace: {
    accessScope: 'workspace',
    approvalPolicy: {
      externalMutation: 'deny', externalRead: 'deny', processExecution: 'allow',
      safeRead: 'allow', sensitiveAccess: 'deny', workspaceMutation: 'allow',
    },
    policy: 'auto',
    profile: 'workspace',
  },
  askFullAccess: {
    accessScope: 'fullAccess',
    approvalPolicy: {
      externalMutation: 'ask', externalRead: 'ask', processExecution: 'ask',
      safeRead: 'allow', sensitiveAccess: 'deny', workspaceMutation: 'ask',
    },
    policy: 'ask',
    profile: 'fullAccess',
  },
  yoloFullAccess: {
    accessScope: 'fullAccess',
    approvalPolicy: {
      externalMutation: 'allow', externalRead: 'allow', processExecution: 'allow',
      safeRead: 'allow', sensitiveAccess: 'deny', workspaceMutation: 'allow',
    },
    policy: 'auto',
    profile: 'fullAccess',
  },
};

const PERMISSION_CHIP_LABELS = {
  askWorkspace: 'Ask·Workspace',
  autoWorkspace: 'Auto·Workspace',
  askFullAccess: 'Ask·Full',
  yoloFullAccess: 'YOLO',
};

/* Selecting a preset is a switch on the decoded object, not on a stringified one:
   `policy` and `profile` are the two axes, and yolo is auto + fullAccess. */
function permissionKey(config) {
  if (!config || typeof config !== 'object') return 'askWorkspace';
  const profile = enumName(pick(config, 'profile'))
    || (enumName(pick(config, 'accessScope')) === 'fullAccess' ? 'fullAccess' : 'workspace');
  const policy = enumName(pick(config, 'policy')) || (String(
    pick(pick(config, 'approvalPolicy', 'approval_policy') || {}, 'workspaceMutation')
    ?? pick(pick(config, 'approvalPolicy', 'approval_policy') || {}, 'workspace_mutation')
    ?? 'ask',
  ) === 'allow' ? 'auto' : 'ask');
  if (profile === 'fullAccess') return policy === 'auto' ? 'yoloFullAccess' : 'askFullAccess';
  return policy === 'auto' ? 'autoWorkspace' : 'askWorkspace';
}

function permissionLabel(state) {
  const config = pick(state, 'nextTurnPermission', 'next_turn_permission')
    || pick(activeSession(), 'permissionConfiguration', 'permission_configuration');
  const key = permissionKey(config);
  return { value: key, label: PERMISSION_CHIP_LABELS[key], danger: key === 'yoloFullAccess' };
}

function renderStrip() {
  const strip = $('composer-strip');
  strip.replaceChildren();
  const context = contextState();
  const session = activeSession();

  /* Goal truth is the shared projection `SessionViewState.goal` ({text, since, steps}).
     ContextStateSnapshot.goal is the older string form and stays only as a fallback. */
  const anchored = pick(session, 'goal');
  const steps = Number(pick(anchored, 'steps'));
  const goal = anchored
    ? String(pick(anchored, 'text') || '')
    : String(pick(context, 'goal') || '');
  if (goal) {
    const item = el('span', 'strip-item');
    item.dataset.tone = 'goal';
    item.append(el('span', 'k', 'goal'));
    const label = truncate(goal, 88) || 'active';
    item.append(el('strong', null, Number.isFinite(steps) && steps > 0 ? `${label} · ${steps} steps` : label));
    strip.append(item);
  }

  const forecast = prediction();
  if (forecast) {
    const hint = pick(forecast, 'hint');
    const abstained = pick(forecast, 'abstained');
    if (hint || abstained) {
      const item = el('span', 'strip-item');
      item.dataset.tone = 'forecast';
      item.append(el('span', 'k', 'forecast'));
      item.append(el('strong', null, abstained ? 'abstain' : truncate(String(hint), 40)));
      const confidence = Number(pick(forecast, 'confidence'));
      if (Number.isFinite(confidence)) {
        const meter = el('span', 'strip-meter');
        const fill = el('i');
        fill.style.width = `${Math.round(Math.min(1, Math.max(0, confidence)) * 100)}%`;
        fill.style.background = 'var(--thinking)';
        meter.append(fill);
        item.append(meter, el('span', null, `${Math.round(confidence * 100)}%`));
      }
      /* PredictionRuntimeSnapshot = {abstained, confidence, hint, hits, matchedOrder,
         misses, steps, support}: no predictor and no source field exist. */
      const support = pick(forecast, 'support');
      const hits = pick(forecast, 'hits');
      const misses = pick(forecast, 'misses');
      const parts = [];
      if (support !== null) parts.push(`n${support}`);
      if (hits !== null || misses !== null) parts.push(`${hits ?? 0}/${misses ?? 0}`);
      if (parts.length) item.append(el('span', null, parts.join(' ')));
      strip.append(item);
    }
  }

  const pCore = pick(context, 'pCore', 'p_core');
  if (pCore) {
    const used = Number(pick(pCore, 'usedTokens', 'used_tokens') || 0);
    const target = Number(pick(pCore, 'targetTokens', 'target_tokens') || 0) || Number(pick(pCore, 'hardLimitTokens', 'hard_limit_tokens') || 0);
    const ratio = target > 0 ? Math.min(1.6, used / target) : 0;
    const item = el('span', 'strip-item');
    item.dataset.tone = 'context';
    item.append(el('span', 'k', 'P-Core'));
    const meter = el('span', 'strip-meter');
    const fill = el('i');
    fill.style.width = `${Math.round(Math.min(1, ratio) * 100)}%`;
    meter.append(fill);
    if (ratio > 0.92) meter.classList.add('is-hot');
    else if (ratio > 0.78) meter.classList.add('is-warn');
    item.append(meter, el('span', null, `${fmtTokens(used)}/${fmtTokens(target)}`));
    item.onclick = () => openPanel('context');
    strip.append(item);
  }

  const eCore = pick(context, 'eCore', 'e_core');
  if (eCore) {
    const item = el('span', 'strip-item');
    item.dataset.tone = 'context';
    item.append(el('span', 'k', 'E-Core'));
    item.append(el('strong', null, `${pick(eCore, 'objectCount', 'object_count') ?? 0} obj`));
    item.append(el('span', null, fmtBytes(pick(eCore, 'totalBytes', 'total_bytes'))));
    item.onclick = () => openPanel('context');
    strip.append(item);
  }

  const list = todos();
  if (list.length) {
    const done = list.filter((item) => String(pick(item, 'status') || '').toLowerCase() === 'completed').length;
    const item = el('span', 'strip-item');
    item.append(el('span', 'k', 'tasks'));
    item.append(el('strong', null, `${done}/${list.length}`));
    item.onclick = () => openPanel('tasks');
    strip.append(item);
  }

  const subs = subagentNodes();
  const live = subs.filter(({ body }) => !/complet|fail|cancel|finish/i.test(String(pick(body, 'status') || '')));
  if (subs.length) {
    const item = el('span', 'strip-item');
    item.append(el('span', 'k', 'agents'));
    item.append(el('strong', null, `${live.length}/${subs.length}`));
    item.onclick = () => openPanel('subagents');
    strip.append(item);
  }

  const diff = store.state.workspaceDiff;
  if (diff && pick(diff, 'diff')) {
    const stat = workspaceDiffStat(diff);
    if (stat) {
      const item = el('span', 'strip-item');
      item.append(el('span', 'k', 'diff'));
      item.append(el('strong', null, `+${stat.add} −${stat.del}`));
      item.onclick = () => { openPanel('diagnostics'); };
      strip.append(item);
    }
  }
}

function renderAttachments() {
  const wrap = $('composer-attachments');
  wrap.hidden = store.attachments.length === 0;
  wrap.replaceChildren();
  for (const attachment of store.attachments) {
    const pill = el('span', 'attach-pill', `@${attachment.name}`);
    pill.title = attachment.path;
    const remove = el('button', null, '×');
    remove.onclick = () => {
      store.attachments = store.attachments.filter((item) => item !== attachment);
      renderAttachments();
    };
    pill.append(remove);
    wrap.append(pill);
  }
}

/* ------------------------------------------------------------------ panel */

function openPanel(tab) {
  store.panel = store.panel === tab ? null : tab;
  $('panel').hidden = !store.panel;
  for (const button of document.querySelectorAll('.panel-tab')) {
    button.classList.toggle('is-active', button.dataset.panel === store.panel);
  }
  if (store.panel) renderPanel();
}

function renderPanel() {
  if (!store.panel) return;
  const body = $('panel-body');
  body.replaceChildren();
  const context = contextState();
  if (store.panel === 'context') {
    const grid = el('dl', 'kv-grid');
    const pCore = pick(context, 'pCore', 'p_core') || {};
    const eCore = pick(context, 'eCore', 'e_core') || {};
    const cache = pick(context, 'providerCache', 'provider_cache') || {};
    const session = activeSession() || {};
    const add = (key, value) => { if (value !== undefined && value !== null && value !== '') { grid.append(el('dt', null, key), el('dd', null, String(value))); } };
    add('P-Core used', `${fmtTokens(pick(pCore, 'usedTokens', 'used_tokens'))} / ${fmtTokens(pick(pCore, 'targetTokens', 'target_tokens'))}`);
    add('P-Core limits', `${fmtTokens(pick(pCore, 'softLimitTokens', 'soft_limit_tokens'))} soft · ${fmtTokens(pick(pCore, 'hardLimitTokens', 'hard_limit_tokens'))} hard`);
    add('E-Core objects', `${pick(eCore, 'objectCount', 'object_count') ?? 0} (${pick(eCore, 'hotObjectCount', 'hot_object_count') ?? 0} hot · ${pick(eCore, 'coldObjectCount', 'cold_object_count') ?? 0} cold)`);
    add('E-Core size', `${fmtBytes(pick(eCore, 'totalBytes', 'total_bytes'))} · rev ${pick(eCore, 'revision') ?? '—'}`);
    /* ContextStateSnapshot has 17 wire keys; the legacy l1Tokens/l2Tokens/cacheStatus
       style accessors are computed, so only estimatedTokens + compaction generation
       are readable here. */
    add('Tokens', `est ${fmtTokens(pick(context, 'estimatedTokens', 'estimated_tokens'))} · compact gen ${pick(context, 'compactionGeneration', 'compaction_generation') ?? '—'} · rev ${pick(context, 'revision') ?? '—'}`);
    add('Provider cache', `${fmtTokens(pick(cache, 'promptTokens', 'prompt_tokens'))} prompt · ${fmtTokens(pick(cache, 'previousPromptTokens', 'previous_prompt_tokens'))} prev · ${fmtTokens(pick(cache, 'cacheReadTokens', 'cache_read_tokens'))} read · epoch ${pick(cache, 'cacheEpoch', 'cache_epoch') ?? '—'}`);
    add('Cache health', `${pick(cache, 'clientHealthStatus', 'client_health_status') ?? '—'} · ${pick(cache, 'cacheStatus', 'cache_status') ?? '—'}${pick(cache, 'epochReason', 'epoch_reason') ? ` (${pick(cache, 'epochReason', 'epoch_reason')})` : ''}`);
    add('Cache debt', pick(cache, 'cacheDebt', 'cache_debt'));
    add('Prefix', `${pick(cache, 'stablePrefixHash', 'stable_prefix_hash') ?? '—'} · miss ${pick(cache, 'missDiagnostics', 'miss_diagnostics') ?? '—'}`);
    add('Stability', `prefix ${pick(context, 'structuralPrefixStability', 'structural_prefix_stability') ?? '—'} · bust rate ${pick(context, 'clientCausedBustRate', 'client_caused_bust_rate') ?? '—'} (${pick(context, 'clientCausedBusts', 'client_caused_busts') ?? 0}/${pick(context, 'comparableRequests', 'comparable_requests') ?? 0})`);
    add('Append-only', `ratio ${pick(context, 'appendOnlyContextRatio', 'append_only_context_ratio') ?? '—'} · violations ${pick(context, 'appendOnlyViolations', 'append_only_violations') ?? 0} · tail ${fmtBytes(pick(context, 'volatileTailBytes', 'volatile_tail_bytes'))} · granularity ${pick(context, 'observedGranularity', 'observed_granularity') ?? '—'}`);
    /* contextPolicy and contextCompacted live on SessionViewState, not on the
       context snapshot. */
    add('Context policy', JSON.stringify(pick(session, 'contextPolicy', 'context_policy') || {}));
    add('Compacted', JSON.stringify(pick(session, 'contextCompacted', 'context_compacted') || {}));
    body.append(grid);

    const forecast = prediction();
    if (forecast) {
      body.append(el('div', 'menu-label', 'branch prediction'));
      const inner = el('dl', 'kv-grid');
      for (const key of ['hint', 'confidence', 'support', 'matchedOrder', 'abstained', 'steps', 'hits', 'misses']) {
        const value = pick(forecast, key, key.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`));
        if (value !== null) inner.append(el('dt', null, key), el('dd', null, typeof value === 'object' ? JSON.stringify(value) : String(value)));
      }
      body.append(inner);
    }
  } else if (store.panel === 'tasks') {
    const list = todos();
    if (!list.length) { body.append(el('p', 'session-empty', '当前 Session 没有 Todo/Task')); return; }
    const wrap = el('div');
    for (const item of list) {
      const row = el('div', 'todo-row');
      row.dataset.status = String(pick(item, 'status') || 'pending');
      const mark = { completed: '[x]', in_progress: '[>]', failed: '[!]' }[row.dataset.status] || '[ ]';
      row.append(el('span', 'mark', mark), el('span', 'todo-text', String(pick(item, 'title', 'text', 'subject') || pick(item, 'id'))));
      wrap.append(row);
    }
    body.append(wrap);
  } else if (store.panel === 'subagents') {
    const subs = subagentNodes();
    if (!subs.length) { body.append(el('p', 'session-empty', '没有 Subagent 记录')); return; }
    const wrap = el('div', 'panel-list');
    for (const { body: agent, node } of subs) {
      const card = el('div', 'panel-card');
      const runID = idOf(pick(agent, 'runID', 'run_id')) || '';
      card.append(el('h4', null, `subagent ${String(runID).slice(-8) || '—'}`));
      card.append(el('p', null, `status ${pick(agent, 'status') || '—'} · parent ${String(idOf(pick(agent, 'parentRunID', 'parent_run_id')) || '—').slice(-8)}`));
      const preview = pick(agent, 'resultPreview', 'result_preview');
      if (preview) card.append(el('p', null, truncate(preview, 240)));
      const terminal = pick(agent, 'terminalReason', 'terminal_reason');
      if (terminal) card.append(el('p', null, `terminal ${terminal}`));
      wrap.append(card);
    }
    body.append(wrap);
    const tasks = store.state.backgroundTasks || [];
    if (tasks.length) {
      body.append(el('div', 'menu-label', 'background tasks'));
      const list = el('div', 'panel-list');
      for (const task of tasks) {
        const card = el('div', 'panel-card');
        /* BackgroundTaskSnapshot = {id, command, cwd, description?, status,
           elapsedSeconds, remainingTimeoutSeconds, timeoutSeconds, exitCode?, pid?,
           startedAt, completedAt?, stdout, stderr, stdoutCursor, stderrCursor}. */
        card.append(el('h4', null, String(pick(task, 'description') || pick(task, 'command') || pick(task, 'id') || 'task')));
        const exit = pick(task, 'exitCode', 'exit_code');
        card.append(el('p', null, [
          String(pick(task, 'status') || ''),
          fmtDuration(Number(pick(task, 'elapsedSeconds', 'elapsed_seconds'))),
          exit !== null ? `exit ${exit}` : null,
        ].filter(Boolean).join(' · ')));
        list.append(card);
      }
      body.append(list);
    }
  } else if (store.panel === 'diagnostics') {
    const diagnostics = store.state.latestDiagnostics;
    if (!diagnostics) {
      body.append(el('p', 'session-empty', '尚未拉取 Diagnostics'));
      const button = el('button', 'btn', 'refresh diagnostics');
      button.onclick = () => command({ refreshDiagnostics: {} });
      body.append(button);
      return;
    }
    const pre = el('pre', null, JSON.stringify(diagnostics, null, 2));
    pre.style.fontFamily = 'var(--font-mono)';
    body.append(pre);
    /* recoveryRequiredRunIDs / orphanRunIDs are `[AgentRunID]`, i.e. `[{rawValue}]`. */
    const recovery = pick(diagnostics, 'recoveryRequiredRunIDs', 'recovery_required_run_ids');
    if (Array.isArray(recovery) && recovery.length) {
      body.prepend(el('p', null, `recovery required: ${recovery.map((value) => idOf(value) ?? String(value)).join(', ')}`));
    }
  }
}

/* ------------------------------------------------------------------ menus */

const MENUS = {
  mode: {
    label: '运行模式',
    items: [
      { value: 'build', label: 'Build', desc: '直接实施' },
      { value: 'plan', label: 'Plan', desc: '先出方案' },
    ],
    command: (value) => ({ setMode: { mode: value } }),
    current: () => modeValue(),
  },
  effort: {
    label: '推理强度',
    items: [
      { value: 'auto', label: 'Auto' }, { value: 'minimal', label: 'Minimal' },
      { value: 'low', label: 'Low' }, { value: 'medium', label: 'Medium' },
      { value: 'high', label: 'High' }, { value: 'xhigh', label: 'X-High' },
    ],
    // `case setReasoningEffort(ReasoningEffort)` is unlabeled, hence the `_0` key.
    command: (value) => ({ setReasoningEffort: { _0: value } }),
    current: () => effortValue(),
  },
  permission: {
    label: '权限姿态',
    items: [
      { value: 'askWorkspace', label: 'Ask · Workspace', desc: '工作区内自动，越界询问' },
      { value: 'askFullAccess', label: 'Ask · Full', desc: '全部动作都询问' },
      { value: 'autoWorkspace', label: 'Auto · Workspace', desc: '工作区内免问' },
      { value: 'yoloFullAccess', label: 'YOLO · Full', desc: '不再询问（高风险）' },
    ],
    // The whole PermissionConfiguration goes under `_0`; the presets are frozen.
    command: (value) => ({ setPermissionConfiguration: { _0: PERMISSION_PRESETS[value] || PERMISSION_PRESETS.askWorkspace } }),
    // `current()` is the accessScope+policy+profile triple resolved by permissionKey(),
    // which is exactly one of the item values above, so the picker compares triples.
    current: () => permissionLabel(store.state).value,
  },
  model: {
    label: '模型',
    items: () => (store.state.models || []).map((model) => {
      /* ProviderModelInfo: `modelID` and `id` are plain strings, the display name
         lives in `displayName` and the provider in `providerID`. */
      const id = String(pick(model, 'modelID', 'id') || model);
      return { value: id, label: String(pick(model, 'displayName') || id), desc: pick(model, 'providerID') };
    }),
    // ModelID is a `String` typealias, so this one id stays bare.
    command: (value) => ({ selectModel: { modelID: wireModelID(value) } }),
    current: () => String(pick(store.state, 'currentModelID', 'current_model_id') || ''),
  },
};

function showMenu(kind, anchor) {
  const definition = MENUS[kind];
  if (!definition) return;
  const popover = $('menu-popover');
  popover.replaceChildren();
  popover.append(el('div', 'menu-label', definition.label));
  const items = typeof definition.items === 'function' ? definition.items() : definition.items;
  const current = String(definition.current() || '');
  for (const item of items) {
    const button = el('button', 'menu-item');
    button.append(el('span', null, item.label));
    if (item.desc) button.append(el('span', 'desc', String(item.desc)));
    if (String(item.value).toLowerCase() === current.toLowerCase()) button.classList.add('is-picked');
    button.onclick = () => {
      hideMenu();
      command(definition.command(item.value));
    };
    popover.append(button);
  }
  if (items.length === 0) popover.append(el('div', 'menu-label', '无可用项'));
  const rect = anchor.getBoundingClientRect();
  popover.hidden = false;
  popover.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - popover.offsetWidth - 12))}px`;
  popover.style.top = `${rect.top - popover.offsetHeight - 6}px`;
  if (rect.top - popover.offsetHeight - 6 < 8) popover.style.top = `${rect.bottom + 6}px`;
}

const hideMenu = () => { $('menu-popover').hidden = true; };

/* ----------------------------------------------------------------- toasts */

function toast(message, tone = 'info') {
  const stack = $('toast-stack');
  const node = el('div', 'toast', message);
  node.dataset.tone = tone === 'error' ? 'error' : (tone === 'warn' ? 'warn' : 'info');
  stack.append(node);
  setTimeout(() => { node.style.opacity = '0'; setTimeout(() => node.remove(), 250); }, tone === 'error' ? 6000 : 3600);
}

/* --------------------------------------------------------------- commands */

async function sendPrompt(text) {
  const trimmed = text.trim();
  if (!trimmed) return;
  const withAttachments = store.attachments.length
    ? `${trimmed}\n\n${store.attachments.map((item) => `@${item.path}`).join('\n')}`
    : trimmed;
  store.attachments = [];
  renderAttachments();
  if (withAttachments.startsWith('/')) {
    await post(API.exec, { input: withAttachments }).catch((error) => toast(error.message, 'error'));
    requestResync('after exec');
  } else {
    await command({ submitPrompt: { text: withAttachments } });
  }
}

function slashPalette(text) {
  const palette = document.querySelector('.palette');
  if (!text.startsWith('/') || text.includes('\n')) { palette?.remove(); return; }
  const token = text.slice(1).split(' ')[0].toLowerCase();
  /* ApplicationCommandDTO is `{name, aliases, description, category, argumentSchema}`:
     all five keys are always present, and `name` is the only id. */
  const commands = (store.commands || []).filter((command) => {
    const name = String(pick(command, 'name') || '');
    return !token || name.toLowerCase().startsWith(token);
  }).slice(0, 9);
  if (!commands.length) { palette?.remove(); return; }
  if (!palette) {
    const created = el('div', 'palette');
    document.body.append(created);
  }
  const open = document.querySelector('.palette');
  const box = $('composer').getBoundingClientRect();
  open.style.left = `${box.left + 22}px`;
  open.style.bottom = `${window.innerHeight - box.top + 8}px`;
  open.replaceChildren();
  commands.forEach((command, index) => {
    const name = String(pick(command, 'name') || '');
    const button = el('button', `menu-item${index === 0 ? ' is-cursor' : ''}`);
    button.append(el('span', null, `/${name}`));
    const description = pick(command, 'description');
    if (description) button.append(el('span', 'desc', truncate(description, 40)));
    button.onclick = () => {
      $('prompt').value = `/${name} `;
      open.remove();
      $('prompt').focus();
    };
    open.append(button);
  });
}

/* ---------------------------------------------------------------- wiring */

function autoResize(textarea) {
  textarea.style.height = 'auto';
  textarea.style.height = `${Math.min(textarea.scrollHeight, window.innerHeight * 0.42)}px`;
}

function wire() {
  const prompt = $('prompt');
  prompt.addEventListener('input', () => { autoResize(prompt); slashPalette(prompt.value); });
  prompt.addEventListener('keydown', (event) => {
    const palette = document.querySelector('.palette');
    if (palette && ['ArrowDown', 'ArrowUp', 'Enter', 'Escape'].includes(event.key)) {
      const items = [...palette.querySelectorAll('.menu-item')];
      let cursor = items.findIndex((item) => item.classList.contains('is-cursor'));
      if (event.key === 'ArrowDown') { event.preventDefault(); cursor = (cursor + 1) % items.length; }
      else if (event.key === 'ArrowUp') { event.preventDefault(); cursor = (cursor - 1 + items.length) % items.length; }
      else if (event.key === 'Escape') { palette.remove(); return; }
      else if (event.key === 'Enter' && cursor >= 0) { event.preventDefault(); items[cursor].click(); return; }
      items.forEach((item, index) => item.classList.toggle('is-cursor', index === cursor));
      return;
    }
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      const value = prompt.value;
      prompt.value = '';
      autoResize(prompt);
      palette?.remove();
      sendPrompt(value);
      return;
    }
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      const value = prompt.value;
      prompt.value = '';
      sendPrompt(value);
    }
  });
  $('btn-send').onclick = () => {
    const value = prompt.value;
    prompt.value = '';
    autoResize(prompt);
    sendPrompt(value);
  };
  $('btn-stop').onclick = () => command({ stopCurrentRun: {} });
  $('btn-new-session').onclick = () => command({ createSession: { title: null, mode: 'build' } });
  $('session-filter').addEventListener('input', (event) => {
    store.sessionFilter = event.target.value;
    renderSessions();
  });
  $('btn-collapse-sidebar').onclick = () => {
    $('workbench').classList.add('is-sidebar-collapsed');
    $('btn-expand-sidebar').hidden = false;
  };
  $('btn-expand-sidebar').onclick = () => {
    $('workbench').classList.remove('is-sidebar-collapsed');
    $('btn-expand-sidebar').hidden = true;
  };
  $('jump-latest').onclick = () => {
    const scroller = $('timeline');
    scroller.scrollTop = scroller.scrollHeight;
  };
  $('timeline').addEventListener('scroll', updateJumpButton);
  $('rail-theme').onclick = () => {
    const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    localStorage.setItem('lingxi.theme', next);
  };
  $('rail-connection').onclick = () => requestResync('manual');
  for (const chip of ['chip-mode', 'chip-model', 'chip-effort', 'chip-permission']) {
    $(chip).onclick = () => showMenu($(chip).dataset.menu, $(chip));
  }
  document.addEventListener('click', (event) => {
    if (!event.target.closest('.menu-popover') && !event.target.closest('.chip')) hideMenu();
    if (!event.target.closest('.palette') && !event.target.closest('#prompt')) document.querySelector('.palette')?.remove();
  });
  for (const button of document.querySelectorAll('.panel-tab')) {
    button.onclick = () => openPanel(button.dataset.panel);
  }
  $('panel-close').onclick = () => openPanel(null);
  $('btn-tasks').onclick = () => openPanel('tasks');
  $('btn-workflows').onclick = () => openPanel('subagents');
  $('btn-attach').onclick = () => $('file-input').click();
  $('file-input').addEventListener('change', async (event) => {
    for (const file of [...event.target.files]) {
      if (file.size > 8 * 1024 * 1024) { toast(`${file.name} 超过 8MB`, 'warn'); continue; }
      const buffer = await file.arrayBuffer();
      const headers = { 'Content-Type': 'application/octet-stream', 'X-LingXi-Client': 'webui' };
      if (TOKEN) headers['X-LingXi-Token'] = TOKEN;
      const response = await fetch(`${API.upload}?name=${encodeURIComponent(file.name)}`, { method: 'POST', headers, body: buffer });
      if (!response.ok) { toast(`上传失败 ${file.name}`, 'error'); continue; }
      const payload = await response.json();
      store.attachments.push({ path: payload.path, name: file.name, size: file.size });
    }
    event.target.value = '';
    renderAttachments();
    $('prompt').focus();
  });
  document.addEventListener('keydown', (event) => {
    const meta = event.metaKey || event.ctrlKey;
    if (meta && event.key.toLowerCase() === 'k') { event.preventDefault(); $('session-filter').focus(); }
    else if (meta && event.key.toLowerCase() === 'n') { event.preventDefault(); command({ createSession: { title: null, mode: 'build' } }); }
    else if (meta && event.key === '.') { event.preventDefault(); $('prompt').focus(); }
    else if (event.key === 'Escape') { hideMenu(); document.querySelector('.palette')?.remove(); if (store.panel) openPanel(null); }
  });
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && !store.connected) bootstrapRetry();
  });
  const stored = localStorage.getItem('lingxi.theme');
  if (stored) document.documentElement.dataset.theme = stored;
}

/* ------------------------------------------------------------------ boot */

async function boot() {
  wire();
  try {
    const response = await fetch(API.hello, { headers: tokenHeaders() });
    if (!response.ok) throw new Error(`hello → HTTP ${response.status}`);
    const hello = await response.json();
    document.title = `${hello.title || 'LingXiAgent'} · WebUI`;
  } catch (error) {
    $('boot').classList.add('is-error');
    $('boot').querySelector('.boot-text').textContent = `无法连接 serve：${error.message}`;
    return;
  }
  bootstrapRetry();
  openStream();
  command({ listSessions: {} });
  command({ listModels: {} });
  setInterval(() => { if (store.connected) renderSessions(); }, 30000);
}

boot();
