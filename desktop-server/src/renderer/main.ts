/**
 * Renderer entrypoint. Sandboxed; talks to the main process via `window.apc`
 * (exposed by the preload script) and to the local server over WebSocket.
 *
 * The renderer is a tiny vanilla-TS SPA with hash-based routing. Views:
 *   #/home      — repo + model pickers, composer, streaming session
 *   #/history   — recent tasks (in-memory for now)
 *   #/settings  — provider API keys, GitHub token, server status
 */

import type { ApcApi } from "../electron/preload";

declare global {
  interface Window {
    apc: ApcApi;
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

interface HistoryEntry {
  id: string;
  repo: string;
  prompt: string;
  startedAt: number;
  status: "running" | "done" | "error";
}

// ---------------------------------------------------------------------------
// State + helpers
// ---------------------------------------------------------------------------
const state = {
  bootstrap: null as Awaited<ReturnType<ApcApi["bootstrap"]>> | null,
  secrets: null as Awaited<ReturnType<ApcApi["secrets"]["get"]>> | null,
  picker: {
    repo: "",
    baseBranch: "",
    workBranch: "",
    provider: "anthropic" as string,
    model: "",
    effort: "high" as Effort,
  },
  sessionId: null as string | null,
  ws: null as WebSocket | null,
  history: [] as HistoryEntry[],
};

function $app() {
  return document.getElementById("app") as HTMLElement | null;
}
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
  for (const c of children) {
    node.append(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return node;
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------
function showRoute(name: string) {
  for (const view of ["home", "history", "settings"]) {
    const sec = $(`view-${view}`);
    sec.classList.toggle("hidden", view !== name);
  }
  for (const a of Array.from(document.querySelectorAll(".nav a"))) {
    a.classList.toggle("active", (a as HTMLAnchorElement).dataset.route === name);
  }
  document.querySelector(".mobile-topbar-title")!.textContent =
    name === "home" ? "Code" : name.charAt(0).toUpperCase() + name.slice(1);
  $("app").classList.remove("sidebar-open");
  if (name === "home") renderHome();
  if (name === "history") renderHistory();
  if (name === "settings") renderSettings();
}

function currentRoute(): string {
  const hash = window.location.hash || "#/home";
  return hash.replace(/^#\//, "").split("/")[0] || "home";
}

window.addEventListener("hashchange", () => showRoute(currentRoute()));

// ---------------------------------------------------------------------------
// Server connection (WebSocket to our own /session endpoint)
// ---------------------------------------------------------------------------
async function ensurePairedAndConnected(): Promise<{ token: string; url: string } | null> {
  if (!state.bootstrap) return null;
  const port = state.bootstrap.serverPort;
  const host = state.bootstrap.serverHost ?? "127.0.0.1";
  if (!port) return null;
  // The renderer's local client always pairs with the local server on this
  // machine using a well-known device name. The pairing code is the same one
  // the phone would enter; we read it from the bootstrap snapshot.
  const code = state.bootstrap.pairingCode;
  if (!code) return null;

  const pairRes = await fetch(`http://${host}:${port}/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, deviceName: "AnyProv Code (desktop)" }),
  });
  if (!pairRes.ok) return null;
  const json = (await pairRes.json()) as { token: string };
  return { token: json.token, url: `ws://${host}:${port}/session?token=${json.token}` };
}

function openSocket(): Promise<WebSocket> {
  return new Promise(async (resolve, reject) => {
    try {
      const conn = await ensurePairedAndConnected();
      if (!conn) {
        reject(new Error("Server not ready"));
        return;
      }
      const ws = new WebSocket(conn.url);
      ws.onopen = () => resolve(ws);
      ws.onerror = () => reject(new Error("WebSocket failed"));
      ws.onclose = () => {
        if (state.ws === ws) state.ws = null;
      };
      ws.onmessage = (ev) => handleServerMessage(ev.data);
    } catch (err) {
      reject(err);
    }
  });
}

async function sendClient(msg: unknown): Promise<void> {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
    state.ws = await openSocket();
    state.ws.onmessage = (ev) => handleServerMessage(ev.data);
  }
  state.ws.send(JSON.stringify(msg));
}

function handleServerMessage(raw: unknown): void {
  let msg: any;
  try { msg = JSON.parse(String(raw)); } catch { return; }
  const body = $("view-home");
  if (msg.type === "session_created") {
    state.sessionId = msg.sessionId;
    body.querySelector(".empty-session")?.remove();
    appendBubble(body, "assistant", "Session started", `workdir: ${msg.workdir}\nbranch: ${msg.workBranch}`);
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
    appendBubble(body, "tool", `${msg.tool}: ${msg.summary}`, JSON.stringify(msg.input, null, 2));
    return;
  }
  if (msg.type === "tool_result") {
    const ok = msg.ok ? "✓" : "�";
    appendBubble(body, "tool", `${ok} result`, msg.output);
    return;
  }
  if (msg.type === "diff") {
    appendBubble(body, "diff", `diff ${msg.path} (+${msg.added} -${msg.removed})`, msg.patch);
    return;
  }
  if (msg.type === "permission_request") {
    appendBubble(
      body,
      "tool",
      `permission: ${msg.tool}`,
      `${msg.summary}\n\n(Reply "allow" or "deny" in the composer to respond.)`,
    );
    return;
  }
  if (msg.type === "session_done") {
    appendBubble(body, "assistant", "session done", msg.stopReason ?? "");
    pushHistory({ status: "done" });
    return;
  }
  if (msg.type === "pr_created") {
    appendBubble(body, "assistant", "PR opened", msg.url);
    return;
  }
  if (msg.type === "error") {
    appendBubble(body, "error", "error", msg.message);
    pushHistory({ status: "error" });
    return;
  }
}

function appendBubble(parent: HTMLElement, kind: string, meta: string, body: string) {
  const bubble = el("div", { class: `bubble ${kind}` });
  bubble.append(el("div", { class: "meta" }, [meta]));
  if (body) bubble.append(el("pre", {}, [body]));
  parent.append(bubble);
  parent.scrollTop = parent.scrollHeight;
}

// ---------------------------------------------------------------------------
// Home view
// ---------------------------------------------------------------------------
function renderHome() {
  const view = $("view-home");
  view.innerHTML = "";

  const grid = el("div", { class: "home-grid" });

  // --- pickers ---
  const picker = el("div", { class: "picker-row" });

  const repoField = field("Repository", inputWithAutofill("repo", state.picker.repo, "owner/name"));
  const baseField = field("Base branch", inputWithAutofill("baseBranch", state.picker.baseBranch, "main"));
  const workField = field("Work branch", inputWithAutofill("workBranch", state.picker.workBranch, "anyprov-code/change"));

  const providerSel = el("select", { id: "provider" });
  for (const p of PROVIDERS) providerSel.append(el("option", { value: p.id }, [p.label]));
  providerSel.value = state.picker.provider;
  providerSel.addEventListener("change", () => {
    state.picker.provider = providerSel.value;
    state.picker.model = "";
    modelSel.value = "";
  });
  const modelSel = el("input", { id: "model", placeholder: "model id" });
  modelSel.value = state.picker.model;
  modelSel.addEventListener("input", () => (state.picker.model = modelSel.value));
  const effortSel = el("select", { id: "effort" });
  for (const e of EFFORTS) effortSel.append(el("option", { value: e }, [e]));
  effortSel.value = state.picker.effort;
  effortSel.addEventListener("change", () => (state.picker.effort = effortSel.value as Effort));

  picker.append(
    repoField.wrap, baseField.wrap, workField.wrap,
    wrap("Provider", providerSel),
    wrap("Model", modelSel),
    wrap("Effort", effortSel),
  );
  grid.append(picker);

  // --- session ---
  const session = el("div", { class: "session" });
  const sHeader = el("div", { class: "session-header" });
  sHeader.append(el("span", {}, ["Session"]));
  const status = el("span", { class: "status", id: "session-status" }, ["idle"]);
  sHeader.append(status);
  session.append(sHeader);
  const sBody = el("div", { class: "session-body", id: "session-body" });
  sBody.append(el("div", { class: "empty-session" }, ["Pick a repo and a model, then send a task."]));
  session.append(sBody);
  grid.append(session);

  // --- composer ---
  const composer = el("div", { class: "composer" });
  const ta = el("textarea", { id: "composer", placeholder: "Describe what you want to change…" });
  ta.rows = 2;
  ta.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      void onSend();
    }
  });
  const sendBtn = el("button", { class: "send-btn", id: "send-btn" }, ["Send"]);
  sendBtn.addEventListener("click", () => void onSend());
  composer.append(ta, sendBtn);
  grid.append(composer);

  view.append(grid);

  async function onSend() {
    const text = ta.value.trim();
    if (!text) return;
    const apiKey = await getApiKeyFor(state.picker.provider);
    if (!apiKey) {
      appendBubble(sBody, "error", "missing API key",
        `Add a key for ${state.picker.provider} in Settings before sending a coding task.`);
      return;
    }
    if (!state.picker.repo) {
      appendBubble(sBody, "error", "missing repo", "Pick a repository first (e.g. owner/name).");
      return;
    }
    if (!state.picker.model) {
      appendBubble(sBody, "error", "missing model", "Type a model id (e.g. gpt-4o or sonnet).");
      return;
    }
    appendBubble(sBody, "user", "you", text);
    pushHistory({ status: "running", prompt: text, repo: state.picker.repo });
    sendBtn.disabled = true;
    sendBtn.textContent = "Working…";
    status.textContent = "running";
    try {
      if (state.sessionId) {
        await sendClient({ type: "user_message", sessionId: state.sessionId, text });
      } else {
        const gh = await getGithubToken();
        await sendClient({
          type: "create_session",
          repo: {
            fullName: state.picker.repo,
            baseBranch: state.picker.baseBranch || undefined,
            workBranch: state.picker.workBranch || "anyprov-code/change",
            githubToken: gh || undefined,
          },
          model: { provider: state.picker.provider as any, model: state.picker.model, effort: state.picker.effort, apiKey },
          permissionMode: "acceptEdits",
          skills: [],
          mcpServers: [],
        });
        // The first message goes together with create_session for simplicity:
        setTimeout(() => {
          if (state.sessionId) {
            void sendClient({ type: "user_message", sessionId: state.sessionId, text });
          }
        }, 250);
      }
    } catch (err) {
      appendBubble(sBody, "error", "send failed", String((err as Error).message ?? err));
    } finally {
      ta.value = "";
      sendBtn.disabled = false;
      sendBtn.textContent = "Send";
      status.textContent = "idle";
    }
  }
}

function field(label: string, input: HTMLElement) {
  return { wrap: wrap(label, input), input };
}
function wrap(label: string, input: HTMLElement) {
  const w = el("div", { class: "field" });
  w.append(el("label", {}, [label]));
  w.append(input);
  return w;
}
function inputWithAutofill(key: keyof typeof state.picker, value: string, placeholder: string) {
  const i = el("input", { id: key, placeholder });
  i.value = value;
  i.addEventListener("input", () => ((state.picker as any)[key] = i.value));
  return i;
}

function pushHistory(partial: Partial<HistoryEntry>) {
  const entry: HistoryEntry = {
    id: state.sessionId ?? `h_${Date.now()}`,
    repo: state.picker.repo,
    prompt: "",
    startedAt: Date.now(),
    status: "running",
    ...partial,
  };
  // Update existing entry if it has the same id
  const existing = state.history.findIndex((h) => h.id === entry.id);
  if (existing >= 0) state.history[existing] = { ...state.history[existing], ...entry };
  else state.history.unshift(entry);
}

async function getApiKeyFor(provider: string): Promise<string | null> {
  const cur = await window.apc.secrets.get();
  if (!cur.providerKeys[provider]?.present) return null;
  const raw = await window.apc.secrets.readProviderKey(provider);
  return raw || null;
}

async function getGithubToken(): Promise<string | null> {
  const cur = await window.apc.secrets.get();
  if (!cur.githubTokenPresent) return null;
  return (await window.apc.secrets.readGithubToken()) || null;
}

// ---------------------------------------------------------------------------
// History view
// ---------------------------------------------------------------------------
function renderHistory() {
  const view = $("view-history");
  view.innerHTML = "";
  view.append(el("h2", {}, ["History"]));
  if (state.history.length === 0) {
    view.append(el("div", { class: "notice warn" }, ["No tasks yet — send one from Home."]));
    return;
  }
  const list = el("div", { class: "history-list" });
  for (const h of state.history) {
    const item = el("div", { class: "history-item" });
    item.append(el("div", { class: "title" }, [h.prompt.slice(0, 80) || "(no prompt)"]));
    const meta = el("div", { class: "meta" }, [`${h.repo} • ${new Date(h.startedAt).toLocaleString()} • ${h.status}`]);
    item.append(meta);
    list.append(item);
  }
  view.append(list);
}

// ---------------------------------------------------------------------------
// Settings view
// ---------------------------------------------------------------------------
function renderSettings() {
  const view = $("view-settings");
  view.innerHTML = "";
  view.append(el("h2", {}, ["Settings"]));

  // --- Server status ---
  const server = el("div", { class: "settings-section" });
  server.append(el("h3", {}, ["Server"]));
  if (state.bootstrap) {
    const b = state.bootstrap;
    server.append(el("div", {}, [`Address: http://${b.serverHost ?? "127.0.0.1"}:${b.serverPort}`]));
    server.append(el("div", {}, [`Pairing code: ${b.pairingCode ?? "------"}`]));
    server.append(el("div", {}, [`Platform: ${b.platform} • App v${b.version}`]));
  }
  view.append(server);

  // --- Provider API keys ---
  const providers = el("div", { class: "settings-section" });
  providers.append(el("h3", {}, ["Provider API keys"]));
  if (!state.secrets) providers.append(el("div", {}, ["Loading…"]));
  else {
    for (const p of PROVIDERS) {
      const present = !!state.secrets.providerKeys[p.id]?.present;
      const row = el("div", { class: "provider-row" });
      row.append(el("div", {}, [p.label]));
      row.append(el("div", { class: `pill ${present ? "ok" : "empty"}` }, [present ? "configured" : "empty"]));
      const setBtn = el("button", { class: "ghost-btn" }, [present ? "Replace" : "Add"]);
      setBtn.addEventListener("click", async () => {
        const v = prompt(`${present ? "Replace" : "Add"} API key for ${p.label}:`, "");
        if (!v) return;
        await window.apc.secrets.set({ providerKeys: { [p.id]: v } as any });
        state.secrets = await window.apc.secrets.get();
        renderSettings();
      });
      const clearBtn = el("button", { class: "danger-btn" }, ["Clear"]);
      clearBtn.disabled = !present;
      clearBtn.addEventListener("click", async () => {
        await window.apc.secrets.clearProvider(p.id);
        state.secrets = await window.apc.secrets.get();
        renderSettings();
      });
      row.append(el("div", {}, [setBtn, " ", clearBtn]));
      providers.append(row);
    }
  }
  view.append(providers);

  // --- GitHub ---
  const gh = el("div", { class: "settings-section" });
  gh.append(el("h3", {}, ["GitHub"]));
  const ghRow = el("div", { class: "provider-row" });
  ghRow.append(el("div", {}, ["Personal access token"]));
  ghRow.append(el("div", { class: `pill ${state.secrets?.githubTokenPresent ? "ok" : "empty"}` }, [state.secrets?.githubTokenPresent ? "configured" : "empty"]));
  const ghSet = el("button", { class: "ghost-btn" }, [state.secrets?.githubTokenPresent ? "Replace" : "Add"]);
  ghSet.addEventListener("click", async () => {
    const v = prompt("GitHub personal access token:", "");
    if (!v) return;
    await window.apc.secrets.set({ githubToken: v });
    state.secrets = await window.apc.secrets.get();
    renderSettings();
  });
  const ghClear = el("button", { class: "danger-btn" }, ["Clear"]);
  ghClear.disabled = !state.secrets?.githubTokenPresent;
  ghClear.addEventListener("click", async () => {
    await window.apc.secrets.clearGithub();
    state.secrets = await window.apc.secrets.get();
    renderSettings();
  });
  ghRow.append(el("div", {}, [ghSet, " ", ghClear]));
  gh.append(ghRow);
  view.append(gh);

  // --- Remote access (main focus: code away from home) ---
  const remote = el("div", { class: "settings-section" });
  remote.append(el("h3", {}, ["Remote access"]));
  remote.append(el("p", { class: "settings-hint" }, [
    "Expose this desktop’s coding server on a public HTTPS URL so your phone can pair and reconnect when you’re not on the same Wi‑Fi. Install cloudflared or ngrok below if needed.",
  ]));
  const remoteBody = el("div", { id: "remote-access-body" });
  remoteBody.append(el("div", { class: "settings-hint" }, ["Loading…"]));
  remote.append(remoteBody);
  view.append(remote);

  // --- Tunnel CLIs (macOS / Linux / Windows) ---
  const tunnels = el("div", { class: "settings-section" });
  tunnels.append(el("h3", {}, ["Tunnel tools"]));
  tunnels.append(el("p", { class: "settings-hint" }, [
    "Install cloudflared or ngrok (all OSes). Remote access and phone previews use these CLIs.",
  ]));
  const tunnelList = el("div", { class: "tunnel-cli-list", id: "tunnel-cli-list" });
  tunnelList.append(el("div", { class: "settings-hint" }, ["Loading…"]));
  tunnels.append(tunnelList);
  const installLog = el("pre", { class: "install-log hidden", id: "tunnel-install-log" }, [""]);
  tunnels.append(installLog);
  view.append(tunnels);
  void refreshTunnelCliRows(tunnelList, installLog);
  void refreshRemoteAccess(remoteBody);

  // --- Storage availability ---
  const storage = el("div", { class: "settings-section" });
  storage.append(el("h3", {}, ["Local storage"]));
  storage.append(el("div", {}, [
    state.bootstrap?.secretsAvailable
      ? "Secrets are encrypted with the OS keychain via Electron safeStorage."
      : "WARNING: OS keychain unavailable; secrets will not be persisted.",
  ]));
  view.append(storage);
}

async function refreshRemoteAccess(container: HTMLElement): Promise<void> {
  container.innerHTML = "";
  let snapshot: Awaited<ReturnType<ApcApi["tools"]["tunnelCliStatus"]>>;
  try {
    snapshot = await window.apc.tools.tunnelCliStatus();
  } catch (err) {
    container.append(el("div", { class: "notice warn" }, [
      `Could not load remote access: ${(err as Error).message ?? err}`,
    ]));
    return;
  }
  const ra = snapshot.remoteAccess;
  const row = el("div", { class: "provider-row tunnel-cli-row" });
  const title = el("div", {});
  title.append(el("div", { class: "tunnel-cli-name" }, ["Coding server tunnel"]));
  title.append(el("div", { class: "settings-hint" }, [
    ra.serverPort != null
      ? `Local port :${ra.serverPort} · provider ${ra.provider}`
      : "Server port unknown",
  ]));
  row.append(title);
  row.append(el("div", { class: `pill ${ra.enabled ? "ok" : "empty"}` }, [
    ra.enabled ? "on" : "off",
  ]));

  const actions = el("div", { class: "tunnel-cli-actions" });
  const toggle = el(
    "button",
    { class: ra.enabled ? "danger-btn" : "primary-btn", type: "button" },
    [ra.enabled ? "Turn off" : "Enable remote access"],
  );
  toggle.addEventListener("click", async () => {
    toggle.disabled = true;
    toggle.textContent = ra.enabled ? "Stopping…" : "Starting…";
    try {
      await window.apc.tools.setRemoteAccess({ enabled: !ra.enabled, provider: "auto" });
    } finally {
      await refreshRemoteAccess(container);
    }
  });
  actions.append(toggle);

  if (ra.enabled) {
    const refresh = el("button", { class: "ghost-btn", type: "button" }, ["Refresh URL"]);
    refresh.addEventListener("click", async () => {
      refresh.disabled = true;
      await window.apc.tools.refreshRemoteAccess();
      await refreshRemoteAccess(container);
    });
    actions.append(refresh);
  }
  row.append(actions);
  container.append(row);

  if (ra.url) {
    const urlRow = el("div", { class: "settings-hint", style: "margin-top:10px" });
    urlRow.append(document.createTextNode("Phone pair address: "));
    const code = el("code", {}, [ra.url]);
    urlRow.append(code);
    container.append(urlRow);
    const copy = el("button", { class: "ghost-btn", type: "button" }, ["Copy URL"]);
    copy.style.marginTop = "8px";
    copy.addEventListener("click", () => {
      void window.apc.clipboard.write(ra.url);
    });
    container.append(copy);
    container.append(el("p", { class: "settings-hint" }, [
      "On your phone, open Settings → Coding → Desktop server and paste this URL (plus the pairing code). The app will reconnect automatically on launch.",
    ]));
  } else if (ra.enabled) {
    container.append(el("div", { class: "notice warn" }, [
      "Tunnel is starting… install cloudflared or ngrok below if this stays empty.",
    ]));
  }
}

async function refreshTunnelCliRows(
  listEl: HTMLElement,
  logEl: HTMLPreElement,
): Promise<void> {
  listEl.innerHTML = "";
  let snapshot: Awaited<ReturnType<ApcApi["tools"]["tunnelCliStatus"]>>;
  try {
    snapshot = await window.apc.tools.tunnelCliStatus();
  } catch (err) {
    listEl.append(el("div", { class: "notice warn" }, [
      `Could not read tunnel CLI status: ${(err as Error).message ?? err}`,
    ]));
    return;
  }

  listEl.append(el("div", { class: "settings-hint" }, [
    `Platform: ${snapshot.platform ?? "unknown"} · ${snapshot.strategy ?? ""}`,
  ]));
  listEl.append(el("div", { class: "settings-hint" }, [
    `Managed binaries: ${snapshot.binDir}`,
  ]));

  for (const tool of snapshot.tools) {
    const row = el("div", { class: "provider-row tunnel-cli-row" });
    const title = el("div", {});
    title.append(el("div", { class: "tunnel-cli-name" }, [tool.label]));
    title.append(el("div", { class: "settings-hint" }, [
      tool.installed
        ? `${tool.version ?? tool.path ?? "installed"}${tool.source === "managed" ? " · app-managed" : ""}`
        : "Not installed",
    ]));
    row.append(title);
    row.append(el("div", { class: `pill ${tool.installed ? "ok" : "empty"}` }, [
      tool.installed ? "installed" : "missing",
    ]));

    const actions = el("div", { class: "tunnel-cli-actions" });
    const installBtn = el(
      "button",
      { class: tool.installed ? "ghost-btn" : "primary-btn", type: "button" },
      [tool.installed ? "Reinstall" : `Install ${tool.id}`],
    );
    installBtn.addEventListener("click", () => {
      void runTunnelInstall(tool.id, installBtn, logEl, listEl, tool.installed);
    });
    actions.append(installBtn);

    if (tool.id === "ngrok") {
      const docs = el("button", { class: "ghost-btn", type: "button" }, ["Auth docs"]);
      docs.addEventListener("click", () => {
        void window.apc.shell.open("https://dashboard.ngrok.com/get-started/your-authtoken");
      });
      actions.append(docs);
    } else {
      const docs = el("button", { class: "ghost-btn", type: "button" }, ["Docs"]);
      docs.addEventListener("click", () => {
        void window.apc.shell.open("https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/");
      });
      actions.append(docs);
    }
    row.append(actions);
    listEl.append(row);
  }
}

async function runTunnelInstall(
  id: "cloudflared" | "ngrok",
  btn: HTMLButtonElement,
  logEl: HTMLPreElement,
  listEl: HTMLElement,
  reinstall = false,
): Promise<void> {
  btn.disabled = true;
  const prev = btn.textContent;
  btn.textContent = reinstall ? "Reinstalling…" : "Installing…";
  logEl.classList.remove("hidden");
  logEl.textContent = "";

  const unsubLog = window.apc.on("tools:installLog", (payload: { id: string; line: string }) => {
    if (payload.id !== id) return;
    logEl.textContent += (logEl.textContent ? "\n" : "") + payload.line;
    logEl.scrollTop = logEl.scrollHeight;
  });

  try {
    const result = await window.apc.tools.installTunnelCli(id, { force: reinstall });
    if (result.ok) {
      logEl.textContent += `\n✓ ${id} installed successfully.`;
    } else {
      logEl.textContent += `\n✗ ${result.error}`;
    }
  } catch (err) {
    logEl.textContent += `\n✗ ${(err as Error).message ?? err}`;
  } finally {
    unsubLog();
    btn.disabled = false;
    btn.textContent = prev ?? "Install";
    await refreshTunnelCliRows(listEl, logEl);
  }
}

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------
async function main() {
  state.bootstrap = await window.apc.bootstrap();
  state.secrets = await window.apc.secrets.get();

  // Wire sidebar
  $("server-status").textContent = state.bootstrap.serverRunning
    ? `running on :${state.bootstrap.serverPort}`
    : "starting…";
  if (state.bootstrap.pairingCode) {
    ($("pairing-code") as HTMLElement).textContent = state.bootstrap.pairingCode;
  }
  $("copy-code").addEventListener("click", () => {
    if (state.bootstrap?.pairingCode) {
      void window.apc.clipboard.write(state.bootstrap.pairingCode);
    }
  });

  // React to navigation requests from the tray
  window.apc.on("navigate", (path) => {
    window.location.hash = `#/${path.replace(/^\//, "")}`;
  });

  $("sidebar-toggle").addEventListener("click", () => {
    $app()?.classList.toggle("sidebar-open");
  });

  showRoute(currentRoute());
}

main().catch((err) => {
  console.error(err);
  document.body.innerHTML = `<pre style="padding:20px;color:#ef6f6c">${String(err)}</pre>`;
});
