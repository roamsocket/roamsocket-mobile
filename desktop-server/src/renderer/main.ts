/**
 * Code Mobile AI — desktop renderer.
 *
 * Vanilla-TS SPA styled after the Claude desktop app. Two real tabs:
 *   - Home: chat with the local agent (free-form `user_message`)
 *   - Code: a real coding session composer (repo + branch + model pickers,
 *           streaming tool calls / diffs / PR)
 *
 * The settings modal exposes provider keys, GitHub token, pairing info,
 * and window close behaviour — all backed by IPC to the main process.
 *
 * No fake features: Projects / Artifacts / Scheduled / Dispatch / Cowork /
 * Skills / Connectors / Plugins are intentionally absent because nothing
 * in the protocol or main process backs them.
 */

import type { CmaiApi } from "../electron/preload";

declare global {
  interface Window {
    cmai: CmaiApi;
  }
}

const PROVIDERS = [
  { id: "anthropic", label: "Anthropic" },
  { id: "openai", label: "OpenAI" },
  { id: "google", label: "Google Gemini" },
  { id: "groq", label: "Groq" },
  { id: "openrouter", label: "OpenRouter" },
  { id: "xai", label: "xAI" },
  { id: "mistral", label: "Mistral" },
] as const;

const EFFORTS = ["low", "medium", "high"] as const;
type Effort = (typeof EFFORTS)[number];

type Tab = "home" | "code";

// ───── State ─────
const state = {
  bootstrap: null as Awaited<ReturnType<CmaiApi["bootstrap"]>> | null,
  secrets: null as Awaited<ReturnType<CmaiApi["secrets"]["get"]>> | null,
  tab: "home" as Tab,
  // Chat state
  chatSessionId: null as string | null,
  chatWs: null as WebSocket | null,
  // Code session state
  code: {
    repo: "",
    baseBranch: "",
    workBranch: "",
    provider: "anthropic" as string,
    model: "",
    effort: "high" as Effort,
  },
  codeSessionId: null as string | null,
  codeWs: null as WebSocket | null,
  codeRunning: false,
  // History (real, protocol-backed)
  history: [] as HistoryEntry[],
  // Settings modal
  settingsOpen: false,
  settingsSection: "general",
};

interface HistoryEntry {
  id: string;
  kind: "chat" | "code";
  title: string;
  startedAt: number;
  status: "running" | "done" | "error";
}

// ───── Tiny DOM helpers ─────
function $(id: string) {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} missing`);
  return el as HTMLElement;
}
function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  children: (string | Node)[] = [],
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else node.setAttribute(k, v);
  }
  for (const c of children) node.append(typeof c === "string" ? document.createTextNode(c) : c);
  return node;
}

// ───── Tabs ─────
function setTab(tab: Tab): void {
  state.tab = tab;
  for (const t of Array.from(document.querySelectorAll<HTMLElement>(".tab"))) {
    t.classList.toggle("active", t.dataset.tab === tab);
  }
  $("view-home").classList.toggle("hidden", tab !== "home");
  $("view-code").classList.toggle("hidden", tab !== "code");
  const crumb = $("crumbs");
  crumb.textContent = tab === "home" ? "Home" : "Code";
  if (tab === "code") renderCodeView();
  // Update recents highlight
  for (const r of Array.from(document.querySelectorAll<HTMLElement>(".recent-item"))) {
    r.classList.remove("active");
  }
}

// ───── Recents ─────
function renderRecents(): void {
  const list = $("recents-list");
  list.innerHTML = "";
  if (state.history.length === 0) {
    list.append(el("div", { class: "recent-empty" }, ["No chats yet"]));
    return;
  }
  for (const h of state.history) {
    const row = el(
      "button",
      { class: "recent-item", type: "button", "data-id": h.id },
      [],
    );
    row.append(el("span", { class: "recent-icon" }, [h.kind === "code" ? "</>" : "○"]));
    row.append(el("span", { class: "recent-title" }, [h.title || "(untitled)"]));
    row.addEventListener("click", () => openRecent(h));
    list.append(row);
  }
}
function pushHistory(entry: HistoryEntry): void {
  const existing = state.history.findIndex((h) => h.id === entry.id);
  if (existing >= 0) state.history[existing] = { ...state.history[existing], ...entry };
  else state.history.unshift(entry);
  state.history = state.history.slice(0, 50);
  renderRecents();
}
function openRecent(h: HistoryEntry): void {
  setTab(h.kind === "code" ? "code" : "home");
}

// ───── Home view ─────
function renderHomeView(): void {
  const wrap = $("view-home").querySelector(".home-composer");
  if (!wrap) throw new Error("home composer wrap missing");
  wrap.innerHTML = "";
  wrap.append(buildComposer({ mode: "home", placeholder: "How can I help you today?" }));
}

function buildComposer(opts: {
  mode: "home" | "code";
  placeholder: string;
  showModelPicker?: boolean;
}): HTMLElement {
  const composer = el("div", { class: "composer" });

  const ta = el("textarea", { class: "composer-textarea", placeholder: opts.placeholder, rows: "1" }) as HTMLTextAreaElement;
  ta.addEventListener("input", () => autoSize(ta));
  ta.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      void onSend();
    }
  });
  composer.append(ta);

  const row = el("div", { class: "composer-row" });

  // Spacer on the left (no fake buttons — no attachment/voice/sound protocol).
  row.append(el("div", { class: "composer-spacer" }));

  if (opts.showModelPicker) {
    const providerSel = el("select", { class: "panel-input", id: "composer-provider" }) as HTMLSelectElement;
    for (const p of PROVIDERS) providerSel.append(el("option", { value: p.id }, [p.label]));
    providerSel.value = state.code.provider;
    providerSel.addEventListener("change", () => (state.code.provider = providerSel.value));
    row.append(providerSel);

    const modelSel = el("input", { class: "panel-input", id: "composer-model", placeholder: "model id" }) as HTMLInputElement;
    modelSel.style.flex = "1";
    modelSel.value = state.code.model;
    modelSel.addEventListener("input", () => (state.code.model = modelSel.value));
    row.append(modelSel);
  } else {
    const modelDisplay = el("button", { class: "composer-select", type: "button", id: "composer-model-display" }, []);
    modelDisplay.append(el("span", { id: "composer-model-text" }, [state.code.model || "Pick a model"]));
    modelDisplay.append(el("span", { class: "caret" }, ["▾"]));
    row.append(modelDisplay);
  }

  const effortSel = el("select", { class: "panel-input", id: "composer-effort" }) as HTMLSelectElement;
  effortSel.style.maxWidth = "90px";
  for (const e of EFFORTS) effortSel.append(el("option", { value: e }, [e]));
  effortSel.value = state.code.effort;
  effortSel.addEventListener("change", () => (state.code.effort = effortSel.value as Effort));
  row.append(effortSel);

  const send = el("button", { class: "composer-send", type: "button", title: "Send" }, []);
  send.innerHTML = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M3 8h10M9 4l4 4-4 4"/></svg>';
  send.addEventListener("click", () => void onSend());
  row.append(send);

  composer.append(row);
  return composer;

  async function onSend() {
    const text = ta.value.trim();
    if (!text) return;
    if (opts.mode === "home") await sendChat(text);
    else await sendCodeTask(text);
    ta.value = "";
    autoSize(ta);
  }
}

function autoSize(ta: HTMLTextAreaElement): void {
  ta.style.height = "auto";
  ta.style.height = Math.min(ta.scrollHeight, 240) + "px";
}

// ───── Chat (Home) WebSocket session ─────
async function sendChat(text: string): Promise<void> {
  const apiKey = await getApiKeyOrComplain("anthropic", "Home chat uses your Anthropic key. Add one in Settings.");
  if (!apiKey) return;
  const code = state.bootstrap?.pairingCode;
  if (!code) {
    appendChatBubble("error", "Server not paired", "Server isn't ready yet.");
    return;
  }
  const conn = await ensurePairedConnection(code).catch(() => null);
  if (!conn) {
    appendChatBubble("error", "Server unreachable", "Couldn't reach the local server.");
    return;
  }
  appendChatBubble("user", "You", text);
  pushHistory({ id: state.chatSessionId ?? `c_${Date.now()}`, kind: "chat", title: text.slice(0, 60), startedAt: Date.now(), status: "running" });
  if (!state.chatSessionId) {
    await conn.send({
      type: "create_session",
      repo: { fullName: "local/chat", workBranch: "code-mobile-ai/chat" },
      model: { provider: "anthropic", model: "claude-sonnet-4-5", effort: "medium", apiKey },
      permissionMode: "acceptEdits",
    });
  } else {
    await conn.send({ type: "user_message", sessionId: state.chatSessionId, text });
  }
}

function appendChatBubble(kind: string, meta: string, body: string): void {
  // Home view has no bubble list yet — for v1 the Home composer is
  // intentionally minimal. We log to history only. Future work: a
  // transcript strip under the composer.
  void kind; void meta; void body;
}

// ───── Code session ─────
function renderCodeView(): void {
  const view = $("view-code");
  view.innerHTML = "";

  const grid = el("div", { class: "code-grid" });

  // Pickers
  const pickerRow = el("div", { class: "picker-row" });
  pickerRow.append(
    pickerField("Repository", "code-repo", state.code.repo, "owner/name", (v) => (state.code.repo = v)),
    pickerField("Base branch", "code-base", state.code.baseBranch, "main", (v) => (state.code.baseBranch = v)),
    pickerField("Work branch", "code-work", state.code.workBranch, "code-mobile-ai/change", (v) => (state.code.workBranch = v)),
    providerPicker(),
    modelInput(),
    effortPicker(),
  );
  grid.append(pickerRow);

  // Session
  const session = el("div", { class: "session" });
  const head = el("div", { class: "session-header" }, []);
  head.append(el("span", { class: "session-status idle", id: "code-status" }, []));
  head.append(el("span", { id: "code-status-text" }, ["idle"]));
  session.append(head);
  const body = el("div", { class: "session-body", id: "code-body" }, []);
  body.append(el("div", { class: "empty-session" }, ["Pick a repo and a model, then send a task."]));
  session.append(body);
  grid.append(session);

  // Composer
  const wrap = el("div", { class: "composer-wrap" }, []);
  wrap.append(buildComposer({ mode: "code", placeholder: "Describe what you want to change…", showModelPicker: true }));
  grid.append(wrap);

  view.append(grid);
}

function pickerField(label: string, id: string, value: string, placeholder: string, onInput: (v: string) => void): HTMLElement {
  const wrap = el("div", { class: "field" }, []);
  wrap.append(el("label", {}, [label]));
  const input = el("input", { id, placeholder }) as HTMLInputElement;
  input.value = value;
  input.addEventListener("input", () => onInput(input.value));
  wrap.append(input);
  return wrap;
}
function providerPicker(): HTMLElement {
  const wrap = el("div", { class: "field" }, []);
  wrap.append(el("label", {}, ["Provider"]));
  const sel = el("select", { id: "code-provider" }) as HTMLSelectElement;
  for (const p of PROVIDERS) sel.append(el("option", { value: p.id }, [p.label]));
  sel.value = state.code.provider;
  sel.addEventListener("change", () => (state.code.provider = sel.value));
  wrap.append(sel);
  return wrap;
}
function modelInput(): HTMLElement {
  const wrap = el("div", { class: "field" }, []);
  wrap.append(el("label", {}, ["Model"]));
  const input = el("input", { id: "code-model", placeholder: "model id" }) as HTMLInputElement;
  input.value = state.code.model;
  input.addEventListener("input", () => (state.code.model = input.value));
  wrap.append(input);
  return wrap;
}
function effortPicker(): HTMLElement {
  const wrap = el("div", { class: "field" }, []);
  wrap.append(el("label", {}, ["Effort"]));
  const sel = el("select", { id: "code-effort" }) as HTMLSelectElement;
  for (const e of EFFORTS) sel.append(el("option", { value: e }, [e]));
  sel.value = state.code.effort;
  sel.addEventListener("change", () => (state.code.effort = sel.value as Effort));
  wrap.append(sel);
  return wrap;
}

async function sendCodeTask(text: string): Promise<void> {
  if (!state.code.repo) {
    appendCodeBubble("error", "missing repo", "Pick a repository first (e.g. owner/name).");
    return;
  }
  if (!state.code.model) {
    appendCodeBubble("error", "missing model", "Type a model id (e.g. claude-sonnet-4-5).");
    return;
  }
  const apiKey = await getApiKeyOrComplain(state.code.provider, `Add your ${state.code.provider} API key in Settings.`);
  if (!apiKey) return;
  const gh = await getGithubToken();
  const code = state.bootstrap?.pairingCode;
  if (!code) {
    appendCodeBubble("error", "Server not paired", "Server isn't ready yet.");
    return;
  }

  const conn = await ensurePairedConnection(code).catch(() => null);
  if (!conn) {
    appendCodeBubble("error", "Server unreachable", "Couldn't reach the local server.");
    return;
  }

  appendCodeBubble("user", "You", text);
  pushHistory({ id: state.codeSessionId ?? `s_${Date.now()}`, kind: "code", title: text.slice(0, 60), startedAt: Date.now(), status: "running" });
  setCodeStatus("running");

  if (!state.codeSessionId) {
    await conn.send({
      type: "create_session",
      repo: {
        fullName: state.code.repo,
        baseBranch: state.code.baseBranch || undefined,
        workBranch: state.code.workBranch || "code-mobile-ai/change",
        githubToken: gh || undefined,
      },
      model: {
        provider: state.code.provider as any,
        model: state.code.model,
        effort: state.code.effort,
        apiKey,
      },
      permissionMode: "acceptEdits",
      skills: [],
      mcpServers: [],
    });
    setTimeout(() => {
      if (state.codeSessionId) void conn.send({ type: "user_message", sessionId: state.codeSessionId, text });
    }, 200);
  } else {
    await conn.send({ type: "user_message", sessionId: state.codeSessionId, text });
  }
}

function appendCodeBubble(kind: string, meta: string, body: string): void {
  const bodyEl = $("code-body");
  bodyEl.querySelector(".empty-session")?.remove();
  const bubble = el("div", { class: `bubble ${kind}` });
  bubble.append(el("div", { class: "meta" }, [meta]));
  if (body) bubble.append(el("pre", {}, [body]));
  bodyEl.append(bubble);
  bodyEl.scrollTop = bodyEl.scrollHeight;
}

function setCodeStatus(state: "idle" | "running"): void {
  const dot = document.getElementById("code-status");
  const txt = document.getElementById("code-status-text");
  if (!dot || !txt) return;
  dot.classList.remove("idle", "running");
  dot.classList.add(state);
  txt.textContent = state;
}

// ───── WebSocket plumbing ─────
async function ensurePairedConnection(code: string): Promise<{
  send: (msg: unknown) => Promise<void>;
}> {
  const port = state.bootstrap?.serverPort;
  const host = state.bootstrap?.serverHost ?? "127.0.0.1";
  if (!port) throw new Error("no port");

  // Reuse existing socket if open
  if (state.codeWs && state.codeWs.readyState === WebSocket.OPEN) {
    return { send: async (m) => state.codeWs!.send(JSON.stringify(m)) };
  }

  const pairRes = await fetch(`http://${host}:${port}/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, deviceName: "Code Mobile AI (desktop)" }),
  });
  if (!pairRes.ok) throw new Error("pair failed");
  const { token } = (await pairRes.json()) as { token: string };

  const ws = new WebSocket(`ws://${host}:${port}/session?token=${token}`);
  state.codeWs = ws;
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error("ws failed"));
    ws.onclose = () => { if (state.codeWs === ws) state.codeWs = null; };
  });
  ws.onmessage = (ev) => handleCodeServerMessage(ev.data);
  return { send: async (m) => ws.send(JSON.stringify(m)) };
}

function handleCodeServerMessage(raw: unknown): void {
  let msg: any;
  try { msg = JSON.parse(String(raw)); } catch { return; }
  const body = $("code-body");
  if (msg.type === "session_created") {
    state.codeSessionId = msg.sessionId;
    appendCodeBubble("assistant", "session started", `workdir: ${msg.workdir}\nbranch: ${msg.workBranch}`);
    return;
  }
  if (msg.type === "assistant_delta") {
    body.querySelector(".empty-session")?.remove();
    let live = body.querySelector(".live-assistant") as HTMLElement | null;
    if (!live) {
      live = el("div", { class: "bubble assistant live-assistant" });
      live.append(el("div", { class: "meta" }, ["assistant"]));
      live.append(el("pre", {}, [""]));
      body.append(live);
      body.scrollTop = body.scrollHeight;
    }
    const pre = live.querySelector("pre")!;
    pre.textContent += msg.text;
    body.scrollTop = body.scrollHeight;
    return;
  }
  if (msg.type === "tool_call") {
    body.querySelector(".empty-session")?.remove();
    body.querySelector(".live-assistant")?.remove();
    appendCodeBubble("tool", `${msg.tool}: ${msg.summary}`, JSON.stringify(msg.input, null, 2));
    return;
  }
  if (msg.type === "tool_result") {
    appendCodeBubble("tool", msg.ok ? "✓ result" : "✗ result", msg.output);
    return;
  }
  if (msg.type === "diff") {
    appendCodeBubble("diff", `diff ${msg.path} (+${msg.added} -${msg.removed})`, msg.patch);
    return;
  }
  if (msg.type === "permission_request") {
    appendCodeBubble("permission", `permission: ${msg.tool}`, msg.summary);
    return;
  }
  if (msg.type === "session_done") {
    appendCodeBubble("assistant", "session done", msg.stopReason ?? "");
    setCodeStatus("idle");
    pushHistory({ id: state.codeSessionId ?? "", kind: "code", title: "code session", startedAt: Date.now(), status: "done" });
    return;
  }
  if (msg.type === "pr_created") {
    appendCodeBubble("pr", "PR opened", msg.url);
    return;
  }
  if (msg.type === "error") {
    appendCodeBubble("error", "error", msg.message);
    setCodeStatus("idle");
    pushHistory({ id: state.codeSessionId ?? "", kind: "code", title: "code session", startedAt: Date.now(), status: "error" });
    return;
  }
}

// ───── Settings modal ─────
function openSettings(): void {
  state.settingsOpen = true;
  state.settingsSection = "general";
  $("settings-backdrop").classList.remove("hidden");
  $("settings-modal").classList.remove("hidden");
  renderSettingsSection();
}
function closeSettings(): void {
  state.settingsOpen = false;
  $("settings-backdrop").classList.add("hidden");
  $("settings-modal").classList.add("hidden");
}

function renderSettingsSection(): void {
  for (const item of Array.from(document.querySelectorAll<HTMLElement>(".modal-nav-item"))) {
    item.classList.toggle("active", item.dataset.section === state.settingsSection);
  }
  const panel = $("settings-panel");
  panel.innerHTML = "";

  if (state.settingsSection === "general") panel.append(renderGeneralSection());
  else if (state.settingsSection === "providers") panel.append(renderProvidersSection());
  else if (state.settingsSection === "github") panel.append(renderGithubSection());
  else if (state.settingsSection === "pairing") panel.append(renderPairingSection());
  else if (state.settingsSection === "window") panel.append(renderWindowSection());
  else if (state.settingsSection === "about") panel.append(renderAboutSection());
}

function renderGeneralSection(): HTMLElement {
  const root = el("div", {}, []);
  root.append(el("h2", {}, ["General"]));
  root.append(panelRow("App version", el("span", {}, [state.bootstrap?.version ?? "—"])));
  root.append(panelRow("Platform", el("span", {}, [state.bootstrap?.platform ?? "—"])));
  root.append(panelRow("Close behaviour",
    el("span", {}, [state.bootstrap?.prefs.alwaysQuitOnClose
      ? "Always quit on close"
      : state.bootstrap?.prefs.closeBehaviorDecided
        ? "Always hide to tray"
        : "Ask on first close"])));
  root.append(panelRow("Storage",
    el("span", {}, [state.bootstrap?.secretsAvailable
      ? "OS keychain available"
      : "Keychain unavailable — secrets won't persist"])));
  return root;
}

// ───── In-app modal (replaces window.prompt / window.confirm) ─────
//
// Electron's renderer doesn't implement window.prompt — it returns null
// silently, which made the original API-key add/replace buttons (and our
// new "Add custom provider" flow) dead. This mini-modal renders an
// in-app dialog that resolves with the user input.

interface MiniModalField {
  id: string;
  label: string;
  placeholder?: string;
  defaultValue?: string;
  type?: "text" | "password" | "url";
  required?: boolean;
  hint?: string;
}

interface MiniModalResult {
  ok: boolean;
  values: Record<string, string>;
}

function miniModal(opts: {
  title: string;
  description?: string;
  fields: MiniModalField[];
  confirmLabel?: string;
  cancelLabel?: string;
  validate?: (values: Record<string, string>) => string | null;
}): Promise<MiniModalResult> {
  return new Promise((resolve) => {
    const backdrop = el("div", { class: "mini-modal-backdrop" });
    const modal = el("div", { class: "mini-modal", role: "dialog", "aria-modal": "true" });
    modal.append(el("div", { class: "mini-modal-title" }, [opts.title]));
    if (opts.description) {
      modal.append(el("div", { class: "mini-modal-desc" }, [opts.description]));
    }
    const inputs: Record<string, HTMLInputElement> = {};
    for (const f of opts.fields) {
      const wrap = el("div", { class: "mini-modal-field" });
      wrap.append(el("label", { for: `mm-${f.id}` }, [f.label]));
      const input = el("input", {
        id: `mm-${f.id}`,
        type: f.type ?? "text",
        placeholder: f.placeholder ?? "",
        value: f.defaultValue ?? "",
      }) as HTMLInputElement;
      input.autocomplete = "off";
      input.spellcheck = false;
      wrap.append(input);
      if (f.hint) wrap.append(el("div", { class: "mini-modal-hint" }, [f.hint]));
      modal.append(wrap);
      inputs[f.id] = input;
    }
    const error = el("div", { class: "mini-modal-error" });
    modal.append(error);

    const actions = el("div", { class: "mini-modal-actions" });
    const cancelBtn = el("button", { type: "button", class: "ghost-btn" }, [
      opts.cancelLabel ?? "Cancel",
    ]);
    const confirmBtn = el("button", { type: "button", class: "primary-btn" }, [
      opts.confirmLabel ?? "Save",
    ]);
    actions.append(cancelBtn, confirmBtn);
    modal.append(actions);

    const close = (result: MiniModalResult) => {
      backdrop.remove();
      document.removeEventListener("keydown", onKey, true);
      resolve(result);
    };
    const collect = (): Record<string, string> => {
      const out: Record<string, string> = {};
      for (const f of opts.fields) {
        const input = inputs[f.id];
        if (input) out[f.id] = input.value.trim();
      }
      return out;
    };
    const submit = () => {
      const values = collect();
      for (const f of opts.fields) {
        if (f.required && !values[f.id]) {
          error.textContent = `${f.label} is required.`;
          inputs[f.id]?.focus();
          return;
        }
      }
      if (opts.validate) {
        const err = opts.validate(values);
        if (err) {
          error.textContent = err;
          return;
        }
      }
      close({ ok: true, values });
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        close({ ok: false, values: {} });
      } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey || !e.shiftKey)) {
        e.preventDefault();
        submit();
      }
    };
    cancelBtn.addEventListener("click", () => close({ ok: false, values: {} }));
    confirmBtn.addEventListener("click", submit);
    backdrop.addEventListener("click", (e) => {
      if (e.target === backdrop) close({ ok: false, values: {} });
    });
    document.addEventListener("keydown", onKey, true);

    backdrop.append(modal);
    document.body.append(backdrop);
    // Focus the first field.
    const firstField = opts.fields[0];
    if (firstField) {
      queueMicrotask(() => inputs[firstField.id]?.focus());
    }
  });
}

async function miniConfirm(opts: {
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
}): Promise<boolean> {
  return new Promise((resolve) => {
    const backdrop = el("div", { class: "mini-modal-backdrop" });
    const modal = el("div", { class: "mini-modal", role: "alertdialog", "aria-modal": "true" });
    modal.append(el("div", { class: "mini-modal-title" }, [opts.title]));
    modal.append(el("div", { class: "mini-modal-desc" }, [opts.message]));
    const actions = el("div", { class: "mini-modal-actions" });
    const cancelBtn = el("button", { type: "button", class: "ghost-btn" }, [
      opts.cancelLabel ?? "Cancel",
    ]);
    const confirmBtn = el(
      "button",
      { type: "button", class: opts.destructive ? "danger-btn-solid" : "primary-btn" },
      [opts.confirmLabel ?? "Confirm"],
    );
    actions.append(cancelBtn, confirmBtn);
    modal.append(actions);

    const close = (ok: boolean) => {
      backdrop.remove();
      document.removeEventListener("keydown", onKey, true);
      resolve(ok);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close(false);
      else if (e.key === "Enter") close(true);
    };
    cancelBtn.addEventListener("click", () => close(false));
    confirmBtn.addEventListener("click", () => close(true));
    backdrop.addEventListener("click", (e) => {
      if (e.target === backdrop) close(false);
    });
    document.addEventListener("keydown", onKey, true);
    backdrop.append(modal);
    document.body.append(backdrop);
    queueMicrotask(() => confirmBtn.focus());
  });
}

function renderProvidersSection(): HTMLElement {
  const root = el("div", {}, []);
  root.append(el("h2", {}, ["Provider API keys"]));
  root.append(el("div", { class: "empty-block" }, [
    "Keys are stored locally via Electron safeStorage (OS keychain). They're never sent anywhere except the local server during a coding session.",
  ]));
  for (const p of PROVIDERS) {
    const present = !!state.secrets?.providerKeys[p.id]?.present;
    const row = el("div", { class: "panel-row" }, []);
    row.append(el("div", { class: "panel-label" }, [p.label]));
    const status = el("span", { class: "panel-status " + (present ? "ok" : "warn") }, [present ? "configured" : "empty"]);
    const value = el("div", { class: "panel-value" }, [status]);
    const actions = el("div", { class: "panel-actions" }, []);
    const setBtn = el("button", { class: "ghost-btn", type: "button" }, [present ? "Replace" : "Add"]);
    setBtn.addEventListener("click", async () => {
      const res = await miniModal({
        title: `${present ? "Replace" : "Add"} API key`,
        description: `Enter the API key for ${p.label}. It's stored locally in the OS keychain.`,
        fields: [
          {
            id: "apiKey",
            label: "API key",
            type: "password",
            placeholder: "sk-…",
            required: true,
          },
        ],
        confirmLabel: present ? "Replace" : "Save",
      });
      if (!res.ok) return;
      const apiKey = res.values.apiKey ?? "";
      if (!apiKey) return;
      await window.cmai.secrets.set({ providerKeys: { [p.id]: apiKey } as any });
      state.secrets = await window.cmai.secrets.get();
      renderSettingsSection();
    });
    actions.append(setBtn);
    if (present) {
      const clearBtn = el("button", { class: "danger-btn", type: "button" }, ["Clear"]);
      clearBtn.addEventListener("click", async () => {
        const ok = await miniConfirm({
          title: "Clear API key?",
          message: `Remove the API key for ${p.label}? You'll need to add it again to use this provider.`,
          confirmLabel: "Clear",
          destructive: true,
        });
        if (!ok) return;
        await window.cmai.secrets.clearProvider(p.id);
        state.secrets = await window.cmai.secrets.get();
        renderSettingsSection();
      });
      actions.append(clearBtn);
    }
    row.append(value, actions);
    root.append(row);
  }
  return root;
}

/** Prompt the user for label + base URL + optional API key, then persist. */
async function addCustomProviderPrompt(): Promise<void> {
  const result = await miniModal({
    title: "Add custom provider",
    description:
      "Custom providers talk any OpenAI-compatible /v1/models and /v1/chat/completions endpoint. The desktop agent uses your base URL.",
    fields: [
      {
        id: "label",
        label: "Display label",
        placeholder: "Internal LLM",
        required: true,
      },
      {
        id: "baseUrl",
        label: "Base URL",
        placeholder: "https://llm.example.com/v1",
        type: "url",
        required: true,
        hint: "Must be a valid http(s) URL ending in /v1.",
      },
      {
        id: "apiKey",
        label: "API key (optional)",
        placeholder: "Leave empty to add later",
        type: "password",
      },
    ],
    confirmLabel: "Save",
    validate: (vals) => {
      const label = vals.label ?? "";
      const baseUrl = vals.baseUrl ?? "";
      try {
        const u = new URL(baseUrl);
        if (u.protocol !== "http:" && u.protocol !== "https:") {
          return "Base URL must use http or https.";
        }
      } catch {
        return "Base URL is not a valid URL.";
      }
      const slug = slugify(label);
      if (!slug) return "Label must contain at least one letter or digit.";
      const taken = (state.secrets?.customProviders ?? []).some((c) => c.id === slug);
      if (taken) return `A custom provider with id "${slug}" already exists.`;
      return null;
    },
  });
  if (!result.ok) return;

  const slug = slugify(result.values.label ?? "");
  try {
    const parsed = new URL(result.values.baseUrl ?? "");
    await window.cmai.secrets.addCustomProvider({
      id: slug,
      label: result.values.label ?? "",
      baseUrl: parsed.toString(),
      apiKey: result.values.apiKey || undefined,
    });
    state.secrets = await window.cmai.secrets.get();
    renderSettingsSection();
  } catch (err) {
    await miniConfirm({
      title: "Couldn't add provider",
      message: `Reason: ${(err as Error).message}`,
      confirmLabel: "OK",
      cancelLabel: "Dismiss",
    });
  }
}

/** Lowercase + non-alphanumerics → dashes; trimmed. Used to derive ids. */
function slugify(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function renderGithubSection(): HTMLElement {
  const root = el("div", {}, []);
  root.append(el("h2", {}, ["GitHub"]));
  root.append(el("div", { class: "empty-block" }, [
    "Used by the server to clone your repo and push the work branch when opening a PR. Stored locally; never persisted on disk.",
  ]));
  const present = !!state.secrets?.githubTokenPresent;
  const row = el("div", { class: "panel-row" }, []);
  row.append(el("div", { class: "panel-label" }, ["Personal access token"]));
  const status = el("span", { class: "panel-status " + (present ? "ok" : "warn") }, [present ? "configured" : "empty"]);
  const value = el("div", { class: "panel-value" }, [status]);
  const actions = el("div", { class: "panel-actions" }, []);
  const setBtn = el("button", { class: "ghost-btn", type: "button" }, [present ? "Replace" : "Add"]);
  setBtn.addEventListener("click", async () => {
    const res = await miniModal({
      title: `${present ? "Replace" : "Add"} GitHub token`,
      description: "Used by the server to clone repos and push branches when opening PRs. Stored locally.",
      fields: [
        {
          id: "token",
          label: "Personal access token",
          type: "password",
          placeholder: "ghp_…",
          required: true,
        },
      ],
      confirmLabel: present ? "Replace" : "Save",
    });
    if (!res.ok) return;
    const token = res.values.token ?? "";
    if (!token) return;
    await window.cmai.secrets.set({ githubToken: token });
    state.secrets = await window.cmai.secrets.get();
    renderSettingsSection();
  });
  actions.append(setBtn);
  if (present) {
    const clearBtn = el("button", { class: "danger-btn", type: "button" }, ["Clear"]);
    clearBtn.addEventListener("click", async () => {
      const ok = await miniConfirm({
        title: "Clear GitHub token?",
        message: "Removing the GitHub token prevents the server from cloning or pushing until you add a new one.",
        confirmLabel: "Clear",
        destructive: true,
      });
      if (!ok) return;
      await window.cmai.secrets.clearGithub();
      state.secrets = await window.cmai.secrets.get();
      renderSettingsSection();
    });
    actions.append(clearBtn);
  }
  row.append(value, actions);
  root.append(row);
  return root;
}

function renderPairingSection(): HTMLElement {
  const root = el("div", {}, []);
  root.append(el("h2", {}, ["Pairing"]));
  root.append(el("div", { class: "empty-block" }, [
    "Open the iOS app and enter this address and pairing code in Settings → Pair with a server.",
  ]));
  const b = state.bootstrap;
  root.append(panelRow("Address",
    el("code", {}, [b?.serverHost && b?.serverPort ? `http://${b.serverHost}:${b.serverPort}` : "—"])));
  root.append(panelRow("Pairing code",
    el("code", {}, [b?.pairingCode ?? "—"])));
  const actionsRow = el("div", { class: "panel-row" }, []);
  actionsRow.append(el("div", { class: "panel-label" }, [""]));
  const actions = el("div", { class: "panel-actions" }, []);
  const copyAddr = el("button", { class: "ghost-btn", type: "button" }, ["Copy address"]);
  copyAddr.addEventListener("click", () => {
    const text = b?.serverHost && b?.serverPort ? `http://${b.serverHost}:${b.serverPort}` : "";
    if (text) void window.cmai.clipboard.write(text);
  });
  const copyCode = el("button", { class: "ghost-btn", type: "button" }, ["Copy code"]);
  copyCode.addEventListener("click", () => {
    if (b?.pairingCode) void window.cmai.clipboard.write(b.pairingCode);
  });
  actions.append(copyAddr, copyCode);
  actionsRow.append(actions);
  root.append(actionsRow);
  return root;
}

function renderWindowSection(): HTMLElement {
  const root = el("div", {}, []);
  root.append(el("h2", {}, ["Window"]));
  root.append(el("div", { class: "empty-block" }, [
    "When you close the window, the app can hide to the menu bar / task tray (server keeps running) or quit completely (server stops).",
  ]));
  const row = el("div", { class: "panel-row" }, []);
  row.append(el("div", { class: "panel-label" }, ["Close behaviour"]));
  const value = el("div", { class: "panel-value" }, []);
  const isQuitting = !!state.bootstrap?.prefs.alwaysQuitOnClose;
  const isDecided = !!state.bootstrap?.prefs.closeBehaviorDecided;
  const select = el("select", { class: "panel-input" }) as HTMLSelectElement;
  select.append(el("option", { value: "hide" }, ["Always hide to tray"]));
  select.append(el("option", { value: "quit" }, ["Always quit on close"]));
  select.value = isQuitting ? "quit" : "hide";
  const status = el("span", { class: "panel-status " + (isDecided ? "ok" : "warn") },
    [isDecided ? "saved" : "will ask on first close"]);
  value.append(select, status);
  row.append(value);
  select.addEventListener("change", async () => {
    const wantQuit = select.value === "quit";
    await window.cmai.prefs.set({
      closeBehaviorDecided: true,
      alwaysQuitOnClose: wantQuit,
    });
    // Refresh bootstrap snapshot so the UI shows the new state.
    state.bootstrap = await window.cmai.bootstrap();
    renderSettingsSection();
  });
  root.append(row);

  // Start minimized toggle
  const startRow = el("div", { class: "panel-row" }, []);
  startRow.append(el("div", { class: "panel-label" }, ["Start minimized"]));
  const startValue = el("div", { class: "panel-value" }, []);
  const startToggle = el("input", { type: "checkbox", class: "panel-input" }) as HTMLInputElement;
  startToggle.checked = !!state.bootstrap?.prefs.startMinimized;
  startToggle.style.width = "auto";
  startToggle.addEventListener("change", async () => {
    await window.cmai.prefs.set({ startMinimized: startToggle.checked });
    state.bootstrap = await window.cmai.bootstrap();
  });
  startValue.append(startToggle, el("span", { class: "panel-status" }, ["Launches hidden in tray; click the tray icon to open"]));
  startRow.append(startValue);
  root.append(startRow);

  return root;
}

function renderAboutSection(): HTMLElement {
  const root = el("div", {}, []);
  root.append(el("h2", {}, ["About"]));
  root.append(panelRow("App", el("span", {}, ["Code Mobile AI"])));
  root.append(panelRow("Version", el("code", {}, [state.bootstrap?.version ?? "—"])));
  root.append(panelRow("Server", el("code", {}, [`v${state.bootstrap?.version ?? "—"} on http://${state.bootstrap?.serverHost ?? "127.0.0.1"}:${state.bootstrap?.serverPort ?? "—"}`])));
  root.append(panelRow("Protocol", el("span", {}, ["WebSocket /session over Express — see docs/protocol.md"])));
  return root;
}

function panelRow(label: string, valueEl: Node): HTMLElement {
  const row = el("div", { class: "panel-row" }, []);
  row.append(el("div", { class: "panel-label" }, [label]));
  row.append(el("div", { class: "panel-value" }, [valueEl]));
  return row;
}

// ───── Secrets helpers ─────
async function getApiKeyOrComplain(provider: string, msg: string): Promise<string | null> {
  const cur = await window.cmai.secrets.get();
  if (!cur.providerKeys[provider]?.present) {
    appendCodeBubble("error", "missing API key", msg);
    return null;
  }
  const raw = await window.cmai.secrets.readProviderKey(provider);
  if (!raw) {
    appendCodeBubble("error", "missing API key", msg);
    return null;
  }
  return raw;
}
async function getGithubToken(): Promise<string | null> {
  const cur = await window.cmai.secrets.get();
  if (!cur.githubTokenPresent) return null;
  return (await window.cmai.secrets.readGithubToken()) || null;
}

// ───── Greeting ─────
function updateGreeting(): void {
  const hour = new Date().getHours();
  let greet = "Hello";
  if (hour < 5) greet = "Working late";
  else if (hour < 12) greet = "Good morning";
  else if (hour < 18) greet = "Good afternoon";
  else greet = "Good evening";
  const txt = $("greeting-text");
  txt.textContent = `${greet}, JC`;
}

// ───── Greeting ─────

// ───── Bootstrap ─────
async function main(): Promise<void> {
  state.bootstrap = await window.cmai.bootstrap();
  state.secrets = await window.cmai.secrets.get();

  // Sidebar
  if (state.bootstrap.pairingCode) {
    // not shown in new layout (it's in Settings)
  }

  // User chip
  $("user-avatar").textContent = "JC";
  $("user-name").textContent = "JC";

  // Tabs
  for (const t of Array.from(document.querySelectorAll<HTMLElement>(".tab"))) {
    t.addEventListener("click", () => setTab(t.dataset.tab as Tab));
  }

  // New chat button → go to Home and reset
  document.querySelector('[data-action="new"]')?.addEventListener("click", () => {
    state.chatSessionId = null;
    state.codeSessionId = null;
    state.codeWs?.close();
    state.codeWs = null;
    setTab("home");
  });

  // Settings button
  document.querySelector('[data-action="open-settings"]')?.addEventListener("click", () => openSettings());
  $("settings-close").addEventListener("click", () => closeSettings());
  $("settings-backdrop").addEventListener("click", () => closeSettings());

  // Settings nav
  for (const item of Array.from(document.querySelectorAll<HTMLElement>(".modal-nav-item"))) {
    item.addEventListener("click", () => {
      state.settingsSection = item.dataset.section ?? "general";
      renderSettingsSection();
    });
  }
  // Settings search (cosmetic filter for now)
  $("settings-search").addEventListener("input", (e) => {
    const q = (e.target as HTMLInputElement).value.toLowerCase();
    for (const item of Array.from(document.querySelectorAll<HTMLElement>(".modal-nav-item"))) {
      const matches = !q || item.textContent.toLowerCase().includes(q);
      item.classList.toggle("hidden", !matches);
    }
  });

  // Greeting
  updateGreeting();
  setInterval(updateGreeting, 60_000);

  // Initial view
  renderHomeView();
  renderRecents();

  // Tray navigation
  window.cmai.on("navigate", (path) => {
    if (path.startsWith("/settings")) openSettings();
    else setTab(path === "/code" ? "code" : "home");
  });
}

main().catch((err) => {
  console.error(err);
  document.body.innerHTML = `<pre style="padding:20px;color:#d96f6f">${String(err)}</pre>`;
});
