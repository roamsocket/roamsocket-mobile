/**
 * Full desktop client shell: Chats, Projects, Artifacts, Code, Settings.
 * Vision is intentionally absent. Hosts chat BYOK + coding sessions via
 * the in-process server over WebSocket.
 */
import type { ApcApi } from "../electron/preload";
import {
  greetingPhrase,
  HistoryStore,
  ProjectsStore,
  ArtifactsStore,
  CodeSessionsStore,
  relativeTime,
  CHAT_PROVIDERS,
  defaultModelFor,
  EFFORTS,
  effortExplanation,
  type Effort,
  type SidebarDestination,
  isSidebarDestination,
  shouldCaptureAsArtifact,
  type CodeSessionRecord,
  parseGitHubPrUrl,
  prChipFromParts,
  fetchGitHubPrState,
  type PrChipModel,
  type GitHubPrState,
  loadDesktopUiPrefs,
  saveDesktopUiPrefs,
  type DesktopUiPrefs,
  loadLightweightPrefs,
  saveLightweightPrefs,
  lightweightModeLabel,
  type LightweightTasksPrefs,
  loadComposerTools,
  saveComposerTools,
  toggleConnector,
  setWebSearch,
  setResearch,
  activateSkill,
  applyMarketplaceConnectors,
  applyMarketplacePluginCategories,
  SkillsStore,
  UserMemoryStore,
  MEMORY_CATEGORY_ORDER,
  MEMORY_CATEGORY_LABELS,
  MEMORY_IMPORT_PROMPT,
  relativeMemoryTime,
  type MemoryEntry,
  buildUserContent,
  buildChatSystemContent,
  withSystemTurn,
  type ComposerToolsState,
  titleFromContent,
  friendlyModelLabel,
  listCloudModels,
  isUsableChatSelection,
  loadCustomProviders,
  addCustomProvider,
  updateCustomProvider,
  removeCustomProvider,
  customProviderId,
  resolveProviderEndpoint,
  mergeProviderCatalog,
  type CustomProvider,
  type CustomApiStyle,
  type ListedCloudModel,
} from "../client/index.js";
import { streamChat } from "./chat-stream.js";
import {
  openInstructionsModal,
  openMemoryModal,
  memoryPreview,
  memoryMeta,
  openContextAddMenu,
  openAddTextContextModal,
} from "./project-modals.js";
import { openComposerPlusMenu } from "./composer-menu.js";
import {
  buildSkillSlashChip,
  openSkillDetailModal,
  openEditSkillModal,
} from "./skill-ui.js";
import {
  appAlert,
  appChoice,
  appConfirm,
  appForm,
  appPrompt,
} from "./dialogs.js";
import {
  installMarketplaceSkill,
  installMarketplacePlugin,
  isMarketplaceSkillInstalled,
  resolvePluginSkills,
  type InstallTarget,
} from "../marketplace/install.js";
import { emptyCatalog } from "../marketplace/types.js";

declare global {
  interface Window {
    apc: ApcApi;
  }
}

// ---------------------------------------------------------------------------
// DOM helpers
// ---------------------------------------------------------------------------
function $(id: string): HTMLElement {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} missing`);
  return el;
}
function $app(): HTMLElement | null {
  return document.getElementById("app");
}
function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  children: (string | Node)[] = [],
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else node.setAttribute(k, v);
  }
  for (const c of children) {
    node.append(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return node;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
const history = new HistoryStore(window.localStorage);
const projects = new ProjectsStore(window.localStorage);
const artifacts = new ArtifactsStore(window.localStorage);
const codeSessions = new CodeSessionsStore(window.localStorage);
const skillsStore = new SkillsStore(window.localStorage);
const userMemory = new UserMemoryStore(window.localStorage);
let uiPrefs: DesktopUiPrefs = loadDesktopUiPrefs(window.localStorage);
let lightweightPrefs: LightweightTasksPrefs = loadLightweightPrefs(window.localStorage);
let composerTools: ComposerToolsState = loadComposerTools(window.localStorage);

// Prefer Apple Intelligence on Mac when walkthrough hasn't forced a choice yet.
if (
  !lightweightPrefs.walkthroughCompleted &&
  typeof navigator !== "undefined" &&
  /Mac/i.test(navigator.platform || navigator.userAgent)
) {
  lightweightPrefs = { ...lightweightPrefs, mode: "appleFoundation" };
}

/**
 * Short helper generation for titles / names via Lightweight Tasks
 * (Apple Intelligence on Mac, or a linked BYOK model).
 */
/** Refine sidebar chat title via Lightweight Tasks (Foundation on Mac / linked model). */
async function maybeRefineChatTitle(chatId: string): Promise<void> {
  const thread = history.get(chatId);
  if (!thread || thread.titleIsUserEdited) return;
  const users = thread.messages.filter((m) => m.role === "user").map((m) => m.content);
  const assistants = thread.messages
    .filter((m) => m.role === "assistant")
    .map((m) => m.content)
    .filter(Boolean);
  if (users.length === 0) return;

  let body = `User: ${users[0]!.slice(0, 500)}`;
  for (const u of users.slice(1, 3)) body += `\nUser: ${u.slice(0, 200)}`;
  for (const a of assistants.slice(0, 2)) body += `\nAssistant: ${a.slice(0, 200)}`;
  body += "\n\nTitle:";

  const named = await lightweightComplete({
    system:
      "You name chat conversations for a coding assistant app. Reply with ONLY a short title: 2 to 6 words. No quotes, no trailing punctuation, no emoji.",
    user: body,
    maxTokens: 24,
  });
  if (!named) return;
  const clean = named
    .split("\n")[0]!
    .replace(/^["'`*]+|["'`*]+$/g, "")
    .trim()
    .slice(0, 48);
  if (!clean || clean === thread.title) return;
  // Soft rename without marking as user-edited so future refreshes can still run.
  const t = history.get(chatId);
  if (!t || t.titleIsUserEdited) return;
  t.title = clean;
  history.persist();
  renderRecents();
  if (history.activeChatId === chatId && state.route === "chats") {
    const titleEl = document.getElementById("topbar-title");
    if (titleEl && !state.projectFilter) titleEl.textContent = clean;
  }
}

async function lightweightComplete(opts: {
  system: string;
  user: string;
  maxTokens?: number;
}): Promise<string | null> {
  const prefs = loadLightweightPrefs(window.localStorage);
  lightweightPrefs = prefs;

  const tryFoundation = async (): Promise<string | null> => {
    // macOS only; Windows callers skip via IPC detail.
    try {
      const res = await window.apc.lightweight.foundationGenerate({
        system: opts.system,
        user: opts.user,
        maxTokens: opts.maxTokens ?? 48,
      });
      if (res.ok && res.text.trim()) return res.text.trim();
    } catch {
      /* fall through */
    }
    return null;
  };

  const tryLinked = async (): Promise<string | null> => {
    if (!prefs.linkedProvider || !prefs.linkedModel) return null;
    try {
      const key = await window.apc.secrets.readProviderKey(prefs.linkedProvider);
      const ep = endpointFor(prefs.linkedProvider);
      if (!key && prefs.linkedProvider !== "localMetal" && !ep) return null;
      const text = await streamChat({
        provider: prefs.linkedProvider,
        model: prefs.linkedModel,
        apiKey: key || "local",
        messages: [
          { role: "system", content: opts.system },
          { role: "user", content: opts.user },
        ],
        baseUrl: ep?.baseUrl,
        apiStyle: ep?.apiStyle,
        onDelta: () => { },
      });
      const trimmed = text.trim();
      return trimmed || null;
    } catch {
      return null;
    }
  };

  if (prefs.mode === "appleFoundation") {
    return (await tryFoundation()) ?? (await tryLinked());
  }
  return (await tryLinked()) ?? (await tryFoundation());
}

function openSkillManage(skillId: string): void {
  openSkillDetailModal(skillId, skillsStore, el, {
    onChanged: () => {
      if (state.route === "settings" && state.settingsTab === "skills") {
        renderSettings();
      }
    },
    onTryInChat: (id) => {
      composerTools = activateSkill(window.localStorage, composerTools, id);
      window.location.hash = "#/chats";
      showRoute("chats");
    },
  });
}

/** Pending file/text attachments for the next chat send (composer chips). */
type PendingAttachment = { id: string; name: string; content: string };
let pendingAttachments: PendingAttachment[] = [];

type SettingsTab =
  | "general"
  | "providers"
  | "github"
  | "metal"
  | "lightweight"
  | "connection"
  | "skills"
  | "connectors"
  | "plugins"
  | "marketplace"
  | "memory"
  | "effort";

type MarketplaceStatus = Awaited<ReturnType<ApcApi["marketplace"]["status"]>>;

/** Apply marketplace catalog into renderer-local connector / plugin menus. */
function applyMarketplaceStatusToRenderer(status: MarketplaceStatus): void {
  state.marketplace = status;
  const connectors = status.catalog.connectors.map((c) => ({
    id: c.id,
    name: c.name,
    available: c.available === false ? false : true,
  }));
  if (connectors.length) applyMarketplaceConnectors(connectors);
  const cats = status.catalog.pluginCategories.map((c) => ({
    id: c.id,
    label: c.label,
  }));
  if (cats.length) applyMarketplacePluginCategories(cats);
  // Reload composer tools so new connector ids get default toggles.
  composerTools = loadComposerTools(window.localStorage);
}

const state = {
  bootstrap: null as Awaited<ReturnType<ApcApi["bootstrap"]>> | null,
  secrets: null as Awaited<ReturnType<ApcApi["secrets"]["get"]>> | null,
  marketplace: null as MarketplaceStatus | null,
  route: "chats" as SidebarDestination,
  settingsTab: "general" as SettingsTab,
  // Chat model selection — empty until the user picks a *real* model
  // (downloaded Metal or a model returned for a keyed cloud provider).
  provider: "" as string,
  model: "" as string,
  /** Cached downloaded Metal hub IDs for honest pill/selection checks. */
  metalDownloadedIds: new Set<string>(),
  // Code session pickers (empty until configured)
  code: {
    repo: "",
    baseBranch: "main",
    workBranch: "roamsocket/change",
    provider: "" as string,
    model: "" as string,
    effort: "high" as Effort,
  },
  sessionId: null as string | null,
  /** Local CodeSessionsStore id for the active coding session UI */
  codeSessionLocalId: null as string | null,
  /** When true, Code view shows the live session instead of Code home */
  codeInSession: false,
  ws: null as WebSocket | null,
  chatBusy: false,
  chatError: null as string | null,
  codeBusy: false,
  /** When set, Recents + new chats are scoped to this project. `undefined` = all. */
  projectFilter: undefined as string | undefined,
  /** Project id when viewing project detail (#/projects/:id) */
  openProjectId: null as string | null,
  /** Artifact open in the chat split panel (Claude-style). */
  openArtifactId: null as string | null,
  /** After opening an artifact, scroll this message into view once. */
  scrollToMessageId: null as string | null,
};

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------
type AppView = SidebarDestination | "metal";

function parseHash(): { view: AppView; parts: string[] } {
  const hash = window.location.hash || "#/chats";
  const parts = hash.replace(/^#\//, "").split("/").filter(Boolean);
  const head = parts[0] || "chats";
  if (head === "metal") return { view: "metal", parts };
  if (head === "home" || head === "history") return { view: "chats", parts: ["chats"] };
  if (isSidebarDestination(head)) return { view: head, parts };
  return { view: "chats", parts: ["chats"] };
}

function showRoute(name: AppView, parts?: string[]) {
  state.route = name === "metal" ? "settings" : name;
  for (const view of ["chats", "projects", "artifacts", "code", "settings", "metal"]) {
    const sec = document.getElementById(`view-${view}`);
    if (sec) sec.classList.toggle("hidden", view !== name);
  }
  for (const a of Array.from(document.querySelectorAll(".nav-item"))) {
    const route = (a as HTMLAnchorElement).dataset.route;
    a.classList.toggle(
      "active",
      route === name || (name === "metal" && route === "settings"),
    );
  }
  $app()?.classList.remove("sidebar-open");
  renderRecents();
  if (name === "chats") renderChat();
  if (name === "projects") {
    const projectId = parts?.[1];
    if (projectId) {
      state.openProjectId = projectId;
      renderProjectDetail(projectId);
    } else {
      state.openProjectId = null;
      renderProjects();
    }
  }
  if (name === "artifacts") renderArtifacts();
  if (name === "code") {
    // Clicking Code in the nav always lands on Code home (session list).
    if (!state.codeInSession || parts?.[0] === "code") {
      // keep session if deep-linked later; for now home unless mid-send
    }
    renderCode();
  }
  if (name === "settings") renderSettings();
  if (name === "metal") void renderMetalManage(parts ?? parseHash().parts);
}

function applyHashRoute() {
  const { view, parts } = parseHash();
  showRoute(view, parts);
}

window.addEventListener("hashchange", () => applyHashRoute());

// ---------------------------------------------------------------------------
// Sidebar recents
// ---------------------------------------------------------------------------
function renderRecents() {
  const list = $("recents-list");
  list.innerHTML = "";
  const items = history.listActive(state.projectFilter);
  if (items.length === 0) {
    list.append(el("div", { class: "settings-hint", style: "padding:8px" }, ["No chats yet"]));
    return;
  }
  for (const item of items) {
    const row = el("button", {
      class: `recent-row${history.activeChatId === item.id ? " active" : ""}`,
      type: "button",
    });
    if (item.starred) row.append(el("span", { class: "star" }, ["★"]));
    row.append(el("span", { class: "title" }, [item.title || "New chat"]));
    row.addEventListener("click", () => {
      history.setActive(item.id);
      if (item.provider) state.provider = item.provider;
      if (item.model) state.model = item.model;
      window.location.hash = "#/chats";
      showRoute("chats");
    });
    row.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      void (async () => {
        const action = await appChoice({
          title: item.title || "Chat",
          choices: [
            { id: "rename", label: "Rename" },
            { id: "star", label: item.starred ? "Unstar" : "Star" },
            { id: "archive", label: "Archive" },
            { id: "delete", label: "Delete", danger: true },
          ],
        });
        if (!action) return;
        if (action === "rename") {
          const t = await appPrompt({
            title: "Rename chat",
            defaultValue: item.title,
            required: true,
            okLabel: "Rename",
          });
          if (t != null) history.rename(item.id, t.trim());
        } else if (action === "star") {
          history.setStarred(item.id, !item.starred);
        } else if (action === "archive") {
          history.archive(item.id);
        } else if (action === "delete") {
          const ok = await appConfirm({
            title: "Delete chat",
            message: `Delete “${item.title || "New chat"}”? This cannot be undone.`,
            okLabel: "Delete",
            danger: true,
          });
          if (!ok) return;
          history.delete(item.id);
        }
        renderRecents();
        if (state.route === "chats") renderChat();
      })();
    });
    list.append(row);
  }
}

// ---------------------------------------------------------------------------
// Chat view
// ---------------------------------------------------------------------------
/** Custom providers configured in local storage (non-secret metadata). */
function customsList(): CustomProvider[] {
  return loadCustomProviders(window.localStorage);
}

function isCustomConfigured(providerId: string): boolean {
  return resolveProviderEndpoint(providerId, customsList()) != null;
}

/** Endpoint override for chat/code when provider is custom or has a stored base URL. */
function endpointFor(providerId: string) {
  return resolveProviderEndpoint(providerId, customsList());
}

/** True when current chat selection is a real available model (not a fake default). */
function hasUsableChatModel(): boolean {
  const hasKey =
    state.provider === "localMetal"
      ? true
      : !!state.secrets?.providerKeys[state.provider]?.present;
  return isUsableChatSelection(state.provider, state.model, {
    hasProviderKey: hasKey,
    metalDownloadedIds: state.metalDownloadedIds,
    customConfigured: isCustomConfigured(state.provider),
  });
}

function modelPillLabel(): string {
  if (!hasUsableChatModel()) return "+ Add a model";
  return friendlyModelLabel(state.provider, state.model);
}

/** Refresh downloaded Metal ids; clear selection if Metal model was removed. */
async function refreshMetalDownloadedCache(): Promise<void> {
  try {
    const entries = await window.apc.metal.catalog();
    state.metalDownloadedIds = new Set(
      entries.filter((e) => e.downloaded).map((e) => e.hubID),
    );
    if (
      state.provider === "localMetal" &&
      state.model &&
      !state.metalDownloadedIds.has(state.model)
    ) {
      state.model = "";
      state.provider = "";
    }
  } catch {
    state.metalDownloadedIds = new Set();
  }
}

function setTopbar(opts: {
  title: string;
  crumbs?: Array<{ label: string; href?: string }>;
}) {
  const crumbsHost = document.getElementById("topbar-crumbs");
  if (!crumbsHost) return;
  crumbsHost.innerHTML = "";
  if (opts.crumbs?.length) {
    for (let i = 0; i < opts.crumbs.length; i++) {
      const c = opts.crumbs[i]!;
      if (i > 0) crumbsHost.append(el("span", { class: "topbar-sep" }, ["/"]));
      if (c.href) {
        const b = el("button", { class: "topbar-crumb", type: "button" }, [c.label]);
        b.addEventListener("click", () => {
          window.location.hash = c.href!;
        });
        crumbsHost.append(b);
      } else {
        crumbsHost.append(el("span", { class: "topbar-crumb" }, [c.label]));
      }
    }
    crumbsHost.append(el("span", { class: "topbar-sep" }, ["/"]));
  }
  crumbsHost.append(el("span", { class: "topbar-title", id: "topbar-title" }, [opts.title]));
}

function renderChat() {
  const view = $("view-chats");
  view.innerHTML = "";
  const project =
    state.projectFilter != null ? projects.get(state.projectFilter) : undefined;
  const openArt = state.openArtifactId ? artifacts.get(state.openArtifactId) : undefined;
  const shell = el("div", {
    class: `chat-shell${project && !openArt ? " with-rail" : ""}${openArt ? " with-artifact" : ""}`,
  });
  const mainCol = el("div", { class: "chat-main-col" });

  let thread = history.activeChatId ? history.get(history.activeChatId) : undefined;
  if (!thread) {
    thread = undefined;
  }

  const title =
    project?.name ??
    (thread && thread.messages.some((m) => m.role === "user")
      ? thread.title
      : "New chat");
  if (project) {
    setTopbar({
      title: project.name,
      crumbs: [{ label: "Projects", href: "#/projects" }],
    });
  } else {
    setTopbar({ title });
  }

  const isEmpty =
    !thread ||
    (thread.messages.every((m) => m.role === "assistant") && thread.messages.length <= 1);

  if (isEmpty && project) {
    const hero = el("div", { class: "project-hero" });
    hero.append(el("h1", {}, [project.name]));
    hero.append(
      el("p", { class: "hint" }, [
        "Give RoamSocket a task and it’ll pick up your project context automatically.",
      ]),
    );
    mainCol.append(hero);
  } else if (isEmpty) {
    const empty = el("div", { class: "chat-empty" });
    empty.append(el("div", { class: "bulb" }, ["💡"]));
    empty.append(el("div", { class: "greeting" }, [greetingPhrase()]));
    mainCol.append(empty);
  } else {
    const msgs = el("div", { class: "chat-messages", id: "chat-messages" });
    const highlightId =
      state.scrollToMessageId ??
      openArt?.sourceMessageId ??
      (openArt ? findMessageIdForArtifact(thread!, openArt) : null);
    const lastMsg = thread!.messages[thread!.messages.length - 1];
    for (const m of thread!.messages) {
      const isLiveEmptyAssistant =
        state.chatBusy &&
        m.role === "assistant" &&
        m.id === lastMsg?.id &&
        !m.content.trim();
      const node = messageNode(
        m.role,
        m.content,
        state.chatBusy && m.role === "assistant" && m.id === lastMsg?.id,
        m.id,
      );
      if (isLiveEmptyAssistant) {
        // Clear empty text so the typing indicator is the only signal.
        const bubble = node.querySelector(".bubble");
        if (bubble) {
          bubble.textContent = "";
          bubble.classList.add("typing");
          bubble.append(typingIndicatorNode());
        }
      }
      if (highlightId && m.id === highlightId) {
        node.classList.add("msg-artifact-source");
      }
      // Open artifact from long assistant turns that match a stored capture.
      if (m.role === "assistant" && shouldCaptureAsArtifact(m.content)) {
        const art =
          artifacts.list().find(
            (a) =>
              a.sourceMessageId === m.id ||
              (a.sourceChatId === thread!.id && a.content === m.content),
          ) ?? null;
        if (art) {
          const openBtn = el("button", {
            class: "ghost-btn sm msg-open-artifact",
            type: "button",
            title: "Open artifact",
          }, ["Open artifact"]);
          openBtn.addEventListener("click", (ev) => {
            ev.stopPropagation();
            openArtifactInChat(art.id);
          });
          node.append(openBtn);
        }
      }
      msgs.append(node);
    }
    mainCol.append(msgs);
    const fab = el("button", {
      class: "scroll-fab",
      type: "button",
      title: "Scroll to bottom",
    }, ["↓"]);
    fab.addEventListener("click", () => {
      msgs.scrollTop = msgs.scrollHeight;
    });
    shell.append(fab);
    queueMicrotask(() => {
      const targetId = state.scrollToMessageId ?? highlightId;
      if (targetId) {
        const target = msgs.querySelector(`[data-message-id="${CSS.escape(targetId)}"]`) as HTMLElement | null;
        if (target) {
          target.scrollIntoView({ block: "center", behavior: "smooth" });
          state.scrollToMessageId = null;
          return;
        }
      }
      msgs.scrollTop = msgs.scrollHeight;
    });
  }

  if (state.chatError) {
    const banner = el("div", { class: "composer-error" });
    banner.append(el("span", {}, ["⚠ "]));
    banner.append(el("span", { style: "flex:1" }, [state.chatError]));
    const dismiss = el("button", { class: "ghost-btn sm", type: "button" }, ["Dismiss"]);
    dismiss.addEventListener("click", () => {
      state.chatError = null;
      renderChat();
    });
    banner.append(dismiss);
    mainCol.append(banner);
  }

  mainCol.append(buildChatComposer());
  shell.append(mainCol);

  if (project) {
    const rail = el("aside", { class: "project-rail" });
    const instr = el("div", { class: "rail-section" });
    instr.append(el("h4", {}, ["Instructions"]));
    instr.append(
      el("p", {}, [
        project.description || "Add project notes in Settings later — chats in this project share this scope.",
      ]),
    );
    rail.append(instr);
    const mem = el("div", { class: "rail-section" });
    mem.append(el("h4", {}, ["Memory"]));
    mem.append(el("p", {}, ["Project memory will show here after a few chats."]));
    rail.append(mem);
    const ctx = el("div", { class: "rail-section" });
    ctx.append(el("h4", {}, ["Context"]));
    const chatCount = history.listActive(project.id).length;
    ctx.append(
      el("p", {}, [
        `${chatCount} chat${chatCount === 1 ? "" : "s"} in this project`,
      ]),
    );
    const bar = el("div", { class: "rail-capacity" });
    bar.append(el("span", {}));
    ctx.append(bar);
    ctx.append(el("p", {}, ["Project context is local to this desktop."]));
    rail.append(ctx);
    shell.append(rail);
  }

  if (openArt) {
    shell.append(buildArtifactPanel(openArt));
  }

  view.append(shell);
}

function findMessageIdForArtifact(
  thread: { id: string; messages: Array<{ id: string; role: string; content: string }> },
  art: { sourceMessageId?: string; content: string; sourceChatId?: string },
): string | null {
  if (art.sourceMessageId) {
    if (thread.messages.some((m) => m.id === art.sourceMessageId)) return art.sourceMessageId;
  }
  const match = [...thread.messages]
    .reverse()
    .find((m) => m.role === "assistant" && m.content === art.content);
  return match?.id ?? null;
}

/** Jump to source chat, scroll to the producing message, open split artifact panel. */
function openArtifactInChat(artifactId: string): void {
  const art = artifacts.get(artifactId);
  if (!art) return;

  state.openArtifactId = artifactId;
  state.scrollToMessageId = art.sourceMessageId ?? null;

  if (art.sourceChatId) {
    const thread = history.get(art.sourceChatId);
    if (thread) {
      history.setActive(art.sourceChatId);
      if (thread.projectId) {
        state.projectFilter = thread.projectId;
      }
      if (!state.scrollToMessageId) {
        state.scrollToMessageId = findMessageIdForArtifact(thread, art);
      }
      // Restore model prefs for that thread when present.
      if (thread.provider) state.provider = thread.provider;
      if (thread.model) state.model = thread.model;
    }
  } else if (!state.scrollToMessageId && history.activeChatId) {
    const thread = history.get(history.activeChatId);
    if (thread) state.scrollToMessageId = findMessageIdForArtifact(thread, art);
  }

  window.location.hash = "#/chats";
  showRoute("chats");
  renderRecents();
}

function closeArtifactPanel(): void {
  state.openArtifactId = null;
  state.scrollToMessageId = null;
  if (state.route === "chats") renderChat();
}

function buildArtifactPanel(art: {
  id: string;
  title: string;
  content: string;
  createdAt: number;
}): HTMLElement {
  const panel = el("aside", { class: "artifact-panel", id: "artifact-panel" });
  const header = el("div", { class: "artifact-panel-header" });
  header.append(el("div", { class: "artifact-panel-kicker" }, ["Artifact"]));
  const actions = el("div", { class: "artifact-panel-actions" });
  const copy = el("button", { class: "ghost-btn sm", type: "button" }, ["Copy"]);
  copy.addEventListener("click", () => void window.apc.clipboard.write(art.content));
  const close = el("button", {
    class: "ghost-btn sm",
    type: "button",
    title: "Close",
    "aria-label": "Close artifact",
  }, ["✕"]);
  close.addEventListener("click", () => closeArtifactPanel());
  actions.append(copy, close);
  header.append(actions);
  panel.append(header);
  panel.append(el("h2", { class: "artifact-panel-title" }, [art.title]));
  const body = el("div", { class: "artifact-panel-body" });
  // Prefer readable prose; keep monospace for fenced-code-heavy content.
  const isCodeHeavy = (art.content.match(/```/g) ?? []).length >= 2
    || art.content.split(/\r?\n/).length > 8 && /^[\s`#\-|>*0-9.a-z{]/i.test(art.content.trim());
  body.append(
    el("pre", { class: isCodeHeavy ? "artifact-pre codey" : "artifact-pre" }, [art.content]),
  );
  panel.append(body);
  panel.append(
    el("div", { class: "artifact-panel-footer" }, [
      `Captured ${new Date(art.createdAt).toLocaleString()}`,
    ]),
  );
  return panel;
}

function messageNode(
  role: string,
  content: string,
  streaming: boolean,
  messageId?: string,
): HTMLElement {
  const wrap = el("div", {
    class: `msg ${role}`,
    ...(messageId ? { "data-message-id": messageId } : {}),
  });
  wrap.append(el("div", { class: "role" }, [role === "user" ? "You" : "Assistant"]));
  const bubble = el("div", { class: `bubble${streaming ? " streaming" : ""}` }, [content]);
  wrap.append(bubble);
  return wrap;
}

/** "Thinking" + three bouncing dots while the assistant has no text yet. */
function typingIndicatorNode(): HTMLElement {
  const row = el("div", {
    class: "typing-indicator",
    role: "status",
    "aria-label": "Assistant is thinking",
  });
  row.append(el("span", { class: "typing-label" }, ["Thinking"]));
  const dots = el("span", { class: "typing-dots", "aria-hidden": "true" });
  for (let i = 0; i < 3; i++) {
    dots.append(el("span", { class: "typing-dot" }));
  }
  row.append(dots);
  return row;
}

function goSettingsTab(tab: typeof state.settingsTab): void {
  state.settingsTab = tab;
  window.location.hash = "#/settings";
  showRoute("settings");
}

function buildChatComposer(): HTMLElement {
  const wrap = el("div", { class: "composer-wrap" });
  const composer = el("div", { class: "composer" });

  // Active skills as blue /slash chips + file attachments
  const chips = el("div", { class: "composer-chips" });
  for (const sid of composerTools.activeSkillIds) {
    const sk = skillsStore.get(sid);
    if (!sk) continue;
    const chip = buildSkillSlashChip(sk, el, {
      onOpen: (id) => openSkillManage(id),
      onRemove: () => {
        composerTools = {
          ...composerTools,
          activeSkillIds: composerTools.activeSkillIds.filter((id) => id !== sid),
        };
        saveComposerTools(window.localStorage, composerTools);
        chip.remove();
        if (!chips.querySelector(".skill-slash-chip, .composer-chip")) {
          chips.classList.add("hidden");
        }
      },
    });
    chips.append(chip);
  }
  for (const att of pendingAttachments) {
    const chip = el("span", { class: "composer-chip file" });
    chip.append(el("span", {}, [att.name]));
    const x = el("button", { class: "composer-chip-x", type: "button", title: "Remove" }, ["×"]);
    x.addEventListener("click", () => {
      pendingAttachments = pendingAttachments.filter((a) => a.id !== att.id);
      chip.remove();
      if (!chips.querySelector(".skill-slash-chip, .composer-chip")) {
        chips.classList.add("hidden");
      }
    });
    chip.append(x);
    chips.append(chip);
  }
  if (!chips.childElementCount) chips.classList.add("hidden");
  composer.append(chips);

  const ta = el("textarea", {
    id: "chat-input",
    placeholder: "Write a message…",
    rows: "1",
  }) as HTMLTextAreaElement;

  const fileInput = el("input", {
    type: "file",
    class: "hidden-file-input",
    multiple: "true",
    accept: "image/*,.txt,.md,.markdown,.json,.csv,.pdf,.ts,.js,.swift,.py",
  }) as HTMLInputElement;
  fileInput.style.display = "none";
  fileInput.addEventListener("change", async () => {
    const files = Array.from(fileInput.files ?? []);
    for (const file of files) {
      let content = "";
      try {
        if (
          file.type.startsWith("text/") ||
          /\.(txt|md|markdown|json|csv|ts|js|swift|py)$/i.test(file.name)
        ) {
          content = await file.text();
        } else if (file.type.startsWith("image/")) {
          content = `[Image attached: ${file.name}, ${Math.round(file.size / 1024)} KB]`;
        } else {
          content = `[File attached: ${file.name}, ${Math.round(file.size / 1024)} KB]`;
        }
      } catch {
        content = `[Could not read ${file.name}]`;
      }
      pendingAttachments.push({
        id: `att_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
        name: file.name,
        content,
      });
    }
    fileInput.value = "";
    // Re-render composer only via full chat/project render path
    if (state.openProjectId) renderProjectDetail(state.openProjectId);
    else renderChat();
  });
  composer.append(fileInput);

  const row = el("div", { class: "composer-row" });
  const plus = el("button", {
    class: "icon-btn",
    type: "button",
    title: "Add files, skills, connectors…",
    "aria-label": "Open attach menu",
  }, ["+"]);

  const openPlus = () => {
    openComposerPlusMenu(plus, el, {
      tools: composerTools,
      projects: projects.list(),
      skills: skillsStore.list().map((s) => ({ id: s.id, name: s.name })),
      currentProjectId: state.projectFilter ?? state.openProjectId,
      onAddFiles: () => fileInput.click(),
      onAddToProject: (projectId) => {
        state.projectFilter = projectId;
        state.openProjectId = projectId;
        if (history.activeChatId) {
          // Move active chat into project by ensuring a project-scoped thread
          const chat = history.get(history.activeChatId);
          if (chat && chat.projectId !== projectId) {
            history.ensureActive({
              provider: state.provider,
              model: state.model,
              projectId,
            });
          }
        }
        projects.touch(projectId);
        window.location.hash = `#/projects/${projectId}`;
        showRoute("projects", ["projects", projectId]);
      },
      onAddFromGitHub: () => {
        void (async () => {
          const url = await appPrompt({
            title: "Add from GitHub",
            message: "Paste a pull request or repository URL.",
            placeholder: "https://github.com/owner/repo/…",
            required: true,
            okLabel: "Add",
          });
          if (!url?.trim()) return;
          pendingAttachments.push({
            id: `att_gh_${Date.now()}`,
            name: url.replace(/^https?:\/\//, "").slice(0, 48),
            content: `GitHub reference: ${url.trim()}`,
          });
          if (state.openProjectId) renderProjectDetail(state.openProjectId);
          else renderChat();
        })();
      },
      onPickSkill: (skillId) => {
        // Insert blue /skill chip (active) — hover preview + click → manage
        composerTools = activateSkill(window.localStorage, composerTools, skillId);
        if (state.openProjectId) renderProjectDetail(state.openProjectId);
        else renderChat();
      },
      onManageSkills: () => goSettingsTab("skills"),
      onBrowseSkills: () => {
        void window.apc.shell.open("https://github.com/anthropics/skills");
      },
      onToggleConnector: (id) => {
        composerTools = toggleConnector(window.localStorage, composerTools, id);
      },
      onManageConnectors: () => goSettingsTab("connectors"),
      onAddConnector: () => goSettingsTab("connectors"),
      onToolAccess: () => goSettingsTab("connectors"),
      onManagePlugins: () => goSettingsTab("plugins"),
      onBrowsePlugins: () => goSettingsTab("plugins"),
      onPluginCategory: (id) => {
        state.chatError = `Plugin category “${id}” — browse installed plugins in Settings → Plugins.`;
        if (state.openProjectId) renderProjectDetail(state.openProjectId);
        else renderChat();
      },
      onToggleResearch: () => {
        composerTools = setResearch(window.localStorage, composerTools, !composerTools.research);
      },
      onToggleWebSearch: () => {
        composerTools = setWebSearch(window.localStorage, composerTools, !composerTools.webSearch);
      },
    });
  };

  plus.addEventListener("click", (e) => {
    e.stopPropagation();
    openPlus();
  });

  // Project folder pill (Claude: highlighted when chat is in a project)
  const projId = state.projectFilter ?? state.openProjectId;
  if (projId) {
    const proj = projects.get(projId);
    const folder = el("button", {
      class: "icon-btn project-folder-btn",
      type: "button",
      title: proj ? `Project: ${proj.name}` : "Project",
    }, ["📁"]);
    folder.addEventListener("click", (e) => {
      e.stopPropagation();
      if (projId) {
        window.location.hash = `#/projects/${projId}`;
        showRoute("projects", ["projects", projId]);
      }
    });
    row.append(plus, folder);
  } else {
    row.append(plus);
  }

  const usable = hasUsableChatModel();
  const pill = el("button", {
    class: `model-pill${usable ? "" : " empty"}`,
    type: "button",
    title: usable
      ? `${friendlyModelLabel(state.provider, state.model)} · ${state.model}`
      : "Add a model",
  });
  const effortLabel =
    uiPrefs.defaultEffort.charAt(0).toUpperCase() + uiPrefs.defaultEffort.slice(1);
  const labelText = usable
    ? `${modelPillLabel()} · ${effortLabel}`
    : "+ Add a model";
  pill.append(el("span", { class: "model-pill-label" }, [labelText]));
  if (usable) pill.append(el("span", { class: "caret" }, ["▾"]));
  // Always open the honest picker — even when empty — so after adding a key
  // the user can list real cloud models / download Metal. The picker itself
  // shows "+ Add a model" / "Download a model" CTAs when nothing is available.
  pill.addEventListener("click", () => openModelPicker());

  const spacer = el("div", { style: "flex:1" });
  const send = el("button", {
    class: `send-circle${ta.value.trim() || " will-update"}`,
    type: "button",
    id: "chat-send",
  }, ["↑"]);

  const syncSend = () => {
    const has = (!!ta.value.trim() || pendingAttachments.length > 0) && !state.chatBusy;
    send.classList.toggle("active", has);
    send.disabled = !has;
    send.textContent = state.chatBusy ? "…" : "↑";
  };
  ta.addEventListener("input", () => {
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 160)}px`;
    syncSend();
  });
  ta.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "u") {
      e.preventDefault();
      fileInput.click();
      return;
    }
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void onChatSend(ta);
    }
  });
  send.addEventListener("click", () => void onChatSend(ta));
  syncSend();

  row.append(pill, spacer, send);
  composer.append(ta, row);
  wrap.append(composer);
  return wrap;
}

/**
 * Model picker: only real, available models.
 * - Cloud: models returned by the provider API for a stored key (never static defaults).
 * - Metal: downloaded weights only.
 * - Empty: "+ Add a model" / "Download a model" CTAs.
 */
function openModelPicker() {
  const backdrop = el("div", { class: "modal-backdrop" });
  const modal = el("div", { class: "modal" });
  modal.append(el("h3", {}, ["Choose a model"]));

  const listHost = el("div", { class: "model-picker-list", id: "model-picker-list" });
  listHost.append(el("div", { class: "settings-hint" }, ["Loading available models…"]));
  modal.append(listHost);

  const close = el("button", {
    class: "ghost-btn",
    type: "button",
    style: "margin-top:12px;width:100%",
  }, ["Close"]);
  close.addEventListener("click", () => backdrop.remove());
  modal.append(close);
  backdrop.append(modal);
  backdrop.addEventListener("click", (ev) => {
    if (ev.target === backdrop) backdrop.remove();
  });
  document.body.append(backdrop);

  void populateModelPickerList(listHost, () => {
    backdrop.remove();
    renderChat();
  });
}

/**
 * A collapsible "submenu" row for the model picker. `target` is shown/hidden
 * when the row is clicked and the caret rotates to indicate state.
 * Colors match section headers (`settings-hint`) and model rows (`modal-option`).
 */
function makeSubmenuToggle(
  title: string,
  detail: string,
  target: HTMLElement,
  opts: { open?: boolean; level?: "provider" | "org" } = {},
): HTMLElement {
  const open = opts.open ?? false;
  const level = opts.level ?? "org";
  target.hidden = !open;
  const toggle = el("button", {
    class: `model-picker-toggle level-${level}`,
    type: "button",
  });
  const caret = el("span", { class: "model-picker-caret" }, ["▸"]);
  const label = el("span", { class: "model-picker-toggle-label" }, [title]);
  const count = el("span", { class: "model-picker-toggle-count" }, [detail]);
  toggle.append(caret, label, count);
  if (open) caret.classList.add("open");
  toggle.addEventListener("click", () => {
    const willOpen = target.hidden;
    target.hidden = !willOpen;
    caret.classList.toggle("open", willOpen);
  });
  return toggle;
}

async function populateModelPickerList(
  listHost: HTMLElement,
  onPicked: () => void,
): Promise<void> {
  listHost.innerHTML = "";
  let anyModel = false;

  const catalog = mergeProviderCatalog(customsList());

  // --- Cloud + custom providers: live model list when reachable ---
  for (const p of catalog) {
    if (p.id === "localMetal") continue;
    const custom = p.id.startsWith("custom:");
    const present = !!state.secrets?.providerKeys[p.id]?.present;
    const ep = endpointFor(p.id);
    if (!custom && !present) continue;
    if (custom && !ep) continue;

    const section = el("div", { class: "model-picker-section" });
    const body = el("div", { class: "model-picker-submenu" });
    const toggle = makeSubmenuToggle(
      custom ? `${p.label} (custom)` : p.label,
      "",
      body,
      { open: state.provider === p.id, level: "provider" },
    );
    const loading = el("div", { class: "settings-hint" }, ["Loading models…"]);
    body.append(loading);
    section.append(toggle, body);
    listHost.append(section);

    try {
      const key = (await window.apc.secrets.readProviderKey(p.id)) || "";
      const models = await listCloudModels(p.id, key, {
        baseUrl: ep?.baseUrl,
        apiStyle: ep?.apiStyle,
      });
      loading.remove();
      const countEl = toggle.querySelector(
        ".model-picker-toggle-count",
      ) as HTMLElement | null;
      if (models.length === 0) {
        // Custom endpoints may not expose /models — offer default / freeform.
        if (custom) {
          const fallback = p.defaultModel || "default";
          const opt = el("button", { class: "modal-option", type: "button" });
          const left = el("div", {});
          left.append(el("div", {}, [fallback]));
          left.append(
            el("div", { class: "sub" }, [
              ep?.baseUrl ? `Use model id at ${ep.baseUrl}` : "Enter model id",
            ]),
          );
          opt.append(left);
          opt.addEventListener("click", () => {
            void (async () => {
              const typed = await appPrompt({
                title: "Model id",
                message: "Enter the model id for this custom provider.",
                defaultValue: fallback,
                required: true,
                okLabel: "Use model",
              });
              if (!typed?.trim()) return;
              state.provider = p.id;
              state.model = typed.trim();
              if (history.activeChatId) {
                history.setModel(history.activeChatId, state.provider, state.model);
              }
              onPicked();
            })();
          });
          body.append(opt);
          if (countEl) countEl.textContent = "1";
          anyModel = true;
        } else {
          body.append(
            el("div", { class: "settings-hint" }, [
              "No models returned for this key. Check the key in Settings.",
            ]),
          );
          if (countEl) countEl.textContent = "0";
        }
        continue;
      }
      anyModel = true;
      if (countEl) {
        countEl.textContent = `${models.length} model${models.length === 1 ? "" : "s"}`;
      }
      const row = (m: ListedCloudModel, host: HTMLElement) => {
        const opt = el("button", { class: "modal-option", type: "button" });
        const left = el("div", {});
        const title = el("div", {});
        title.append(el("span", {}, [friendlyModelLabel(p.id, m.id) || m.displayName]));
        if (m.isFree) title.append(el("span", { class: "pill free" }, ["Free"]));
        left.append(title);
        left.append(el("div", { class: "sub" }, [m.id]));
        opt.append(left);
        if (state.provider === p.id && state.model === m.id) {
          opt.append(el("div", { class: "pill ok" }, ["selected"]));
        }
        opt.addEventListener("click", () => {
          state.provider = p.id;
          state.model = m.id;
          if (history.activeChatId) {
            history.setModel(history.activeChatId, state.provider, state.model);
          }
          onPicked();
        });
        host.append(opt);
      };

      if (p.id === "openrouter") {
        // OpenRouter's catalog is huge — nest it as submenus: one per
        // vendor / organization tag (e.g. OpenAI, Anthropic, Meta).
        const groups = new Map<string, ListedCloudModel[]>();
        for (const m of models) {
          const org = m.organization ?? m.id.split("/")[0] ?? "Other";
          if (!groups.has(org)) groups.set(org, []);
          groups.get(org)!.push(m);
        }
        const sorted = [...groups.entries()].sort((a, b) =>
          a[0].localeCompare(b[0]),
        );
        if (countEl) {
          countEl.textContent = `${sorted.length} vendor${sorted.length === 1 ? "" : "s"}`;
        }
        const selectedIsOpenRouter = state.provider === p.id;
        const selectedOrg = selectedIsOpenRouter
          ? state.model.split("/")[0] || ""
          : "";
        for (const [org, orgModels] of sorted) {
          const orgBody = el("div", { class: "model-picker-submenu nested" });
          const orgToggle = makeSubmenuToggle(
            org,
            `${orgModels.length}`,
            orgBody,
            {
              open: selectedIsOpenRouter && org === selectedOrg,
              level: "org",
            },
          );
          for (const m of orgModels) row(m, orgBody);
          body.append(orgToggle, orgBody);
        }
      } else {
        for (const m of models) row(m, body);
      }
    } catch {
      loading.textContent = "Could not list models for this provider.";
    }
  }

  // Built-ins without keys → single CTA (not fake models)
  const missingKeys = CHAT_PROVIDERS.filter(
    (p) => p.id !== "localMetal" && !state.secrets?.providerKeys[p.id]?.present,
  );
  if (missingKeys.length > 0 || customsList().length === 0) {
    const add = el("button", { class: "modal-option", type: "button" });
    add.append(el("div", {}, ["+ Add a model"]));
    add.append(
      el("div", { class: "sub" }, [
        "Add an API key or custom provider in Settings → Providers",
      ]),
    );
    add.addEventListener("click", () => {
      onPicked();
      window.location.hash = "#/settings";
      state.settingsTab = "providers";
      showRoute("settings");
    });
    listHost.append(add);
  }

  // --- Metal: downloaded only ---
  listHost.append(
    el("div", { class: "settings-hint", style: "margin:12px 0 4px" }, ["On-device Metal"]),
  );
  try {
    const st = await window.apc.metal.status();
    if (!st.runtimeReady) {
      const runtimeRow = el("div", { class: "metal-picker-install" });
      runtimeRow.append(
        el("div", { class: "settings-hint" }, [
          "Runtime not ready. Install Python + mlx-lm to run on-device models.",
        ]),
      );
      const installBtn = el("button", {
        class: "primary-btn sm",
        type: "button",
      }, [METAL_INSTALL_LABEL]);
      const log = el("pre", { class: "install-log hidden" }, [""]);
      installBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        void runMetalRuntimeInstall(installBtn, log);
      });
      runtimeRow.append(installBtn, log);
      listHost.append(runtimeRow);
    }

    const entries = await window.apc.metal.catalog();
    const ready = entries.filter((e) => e.downloaded);
    state.metalDownloadedIds = new Set(ready.map((e) => e.hubID));

    if (ready.length === 0) {
      const manage = el("button", { class: "modal-option", type: "button" });
      manage.append(el("div", {}, ["Download a model"]));
      manage.append(
        el("div", { class: "sub" }, [
          "No on-device Metal models installed · Manage models to download",
        ]),
      );
      manage.addEventListener("click", () => {
        onPicked();
        window.location.hash = "#/metal";
      });
      listHost.append(manage);
    } else {
      anyModel = true;
      for (const e of ready) {
        const opt = el("button", { class: "modal-option", type: "button" });
        const left = el("div", {});
        left.append(el("div", {}, [e.displayName]));
        left.append(
          el("div", { class: "sub" }, [`${e.family} · ${e.approxSize} · downloaded`]),
        );
        opt.append(left);
        if (state.provider === "localMetal" && state.model === e.hubID) {
          opt.append(el("div", { class: "pill ok" }, ["selected"]));
        }
        opt.addEventListener("click", () => {
          state.provider = "localMetal";
          state.model = e.hubID;
          state.metalDownloadedIds.add(e.hubID);
          if (history.activeChatId) {
            history.setModel(history.activeChatId, state.provider, state.model);
          }
          onPicked();
        });
        listHost.append(opt);
      }
      const manage = el("button", { class: "modal-option", type: "button" });
      manage.append(el("div", {}, ["Manage models…"]));
      manage.append(el("div", { class: "sub" }, ["Download more · install runtime"]));
      manage.addEventListener("click", () => {
        onPicked();
        window.location.hash = "#/metal";
      });
      listHost.append(manage);
    }
  } catch {
    listHost.append(
      el("div", { class: "settings-hint" }, ["Metal catalog unavailable"]),
    );
  }

  if (!anyModel && missingKeys.length === CHAT_PROVIDERS.filter((p) => p.id !== "localMetal").length) {
    // Only CTAs — no selectable fake rows.
    const hint = el("div", { class: "settings-hint", style: "margin-top:8px" }, [
      "No models available yet. Add an API key or download an on-device Metal model.",
    ]);
    listHost.prepend(hint);
  }
}

async function onChatSend(ta: HTMLTextAreaElement) {
  const text = ta.value.trim();
  const atts = [...pendingAttachments];
  if ((!text && atts.length === 0) || state.chatBusy) return;

  if (state.provider !== "localMetal") {
    const key = await window.apc.secrets.readProviderKey(state.provider);
    const customOk = isCustomConfigured(state.provider);
    if (!key && !customOk) {
      state.chatError = `Add an API key for ${state.provider} in Settings.`;
      renderChat();
      return;
    }
    if (state.provider.startsWith("custom:") && !customOk) {
      state.chatError = "This custom provider is missing a base URL. Fix it in Settings → Providers.";
      renderChat();
      return;
    }
  } else if (!state.model) {
    state.chatError = "Download and select an on-device Metal model in Settings.";
    renderChat();
    return;
  }

  // Prefer project from open project detail, then recents filter
  const projectId = state.openProjectId ?? state.projectFilter;
  const userContent = buildUserContent(
    text,
    atts.map((a) => ({ name: a.name, content: a.content })),
  );

  const thread = history.ensureActive({
    provider: state.provider,
    model: state.model,
    projectId,
  });
  history.appendMessage(thread.id, {
    id: `m_${Date.now()}`,
    role: "user",
    content: userContent,
    createdAt: Date.now(),
  });
  ta.value = "";
  pendingAttachments = [];
  state.chatError = null;
  state.chatBusy = true;
  renderChat();

  const assistantId = `m_${Date.now()}_a`;
  history.appendMessage(thread.id, {
    id: assistantId,
    role: "assistant",
    content: "",
    createdAt: Date.now(),
  });
  renderChat();

  const historyTurns: Array<{ role: "user" | "assistant" | "system"; content: string }> = history
    .get(thread.id)!
    .messages
    .filter((m) => m.id !== assistantId && m.content.trim())
    .map((m) => ({ role: m.role as "user" | "assistant", content: m.content }));

  // System: composer tools + user memory + project context
  const systemContent = buildChatSystemContent({
    tools: composerTools,
    project: projectId ? projects.get(projectId) : null,
    includeMemory: uiPrefs.memorySearchChats,
    userMemorySystem:
      uiPrefs.memorySearchChats || uiPrefs.memoryGenerateFromChats
        ? userMemory.formatForSystem()
        : "",
    resolveSkill: (id) => skillsStore.get(id),
  });
  const turns = withSystemTurn(historyTurns, systemContent);

  try {
    let full = "";
    if (state.provider === "localMetal") {
      const result = await window.apc.metal.generate({
        hubID: state.model,
        messages: turns,
      });
      full = result.text;
      history.updateLastAssistant(thread.id, full);
      renderChat();
    } else {
      const apiKey = (await window.apc.secrets.readProviderKey(state.provider)) || "";
      const ep = endpointFor(state.provider);
      full = await streamChat({
        provider: state.provider,
        model: state.model,
        apiKey,
        messages: turns,
        baseUrl: ep?.baseUrl,
        apiStyle: ep?.apiStyle,
        webSearch: composerTools.webSearch,
        onDelta: (chunk) => {
          full += chunk;
          history.updateLastAssistant(thread.id, full);
          const live = document.querySelector("#chat-messages .msg.assistant:last-child .bubble");
          if (live) {
            live.textContent = full;
            live.classList.add("streaming");
            live.classList.remove("typing");
          }
        },
      });
      history.updateLastAssistant(thread.id, full);
    }

    // Lightweight Tasks: chat title (same jobs as mobile Foundation / linked model).
    void maybeRefineChatTitle(thread.id);

    if (full && shouldCaptureAsArtifact(full)) {
      const lastAsst = history
        .get(thread.id)
        ?.messages.filter((m) => m.role === "assistant")
        .pop();
      const heuristic = titleFromContent(full);
      const art = artifacts.add(full, {
        sourceChatId: thread.id,
        sourceMessageId: lastAsst?.id ?? assistantId,
        title: heuristic,
      });
      // Rename with Lightweight Tasks (Apple Intelligence or linked model).
      if (art) {
        void (async () => {
          const named = await lightweightComplete({
            system:
              "You name saved chat artifacts. Reply with ONLY a short title: 3 to 8 words. No quotes or punctuation.",
            user: `Artifact content:\n${full.slice(0, 2400)}\n\nTitle:`,
            maxTokens: 28,
          });
          if (named && named !== art.title) {
            artifacts.add(full, {
              sourceChatId: thread.id,
              sourceMessageId: art.sourceMessageId,
              title: named.slice(0, 64),
            });
            if (state.openArtifactId === art.id && state.route === "chats") {
              renderChat();
            }
          }
        })();
      }
    }
  } catch (err) {
    const msg = String((err as Error).message ?? err);
    state.chatError = msg;
    history.updateLastAssistant(thread.id, fullOrError(history.get(thread.id), msg));
  } finally {
    state.chatBusy = false;
    renderChat();
    renderRecents();
  }
}

function fullOrError(
  thread: ReturnType<HistoryStore["get"]>,
  err: string,
): string {
  const last = thread?.messages.filter((m) => m.role === "assistant").pop();
  if (last?.content) return last.content;
  return `Error: ${err}`;
}

// ---------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------
function openProject(projectId: string) {
  state.openProjectId = projectId;
  state.projectFilter = projectId;
  projects.touch(projectId);
  window.location.hash = `#/projects/${projectId}`;
  showRoute("projects", ["projects", projectId]);
}

async function createProjectFlow() {
  const values = await appForm({
    title: "New project",
    fields: [
      {
        name: "name",
        label: "Name",
        placeholder: "Project name",
        required: true,
      },
      {
        name: "description",
        label: "Description (optional)",
        placeholder: "Short blurb",
      },
    ],
    okLabel: "Create",
  });
  if (!values) return;
  const p = projects.create((values.name ?? "").trim(), values.description ?? "");
  openProject(p.id);
}

function renderProjects() {
  setTopbar({ title: "Projects" });
  const view = $("view-projects");
  view.innerHTML = "";
  const page = el("div", { class: "page projects-page" });

  const head = el("div", { class: "page-header-row" });
  head.append(el("h2", {}, ["Projects"]));
  const tools = el("div", { class: "page-toolbar" });
  const search = el("input", {
    class: "search-input",
    type: "search",
    placeholder: "Search projects…",
    id: "projects-search",
  }) as HTMLInputElement;
  const create = el("button", { class: "primary-btn", type: "button" }, ["New project"]);
  create.addEventListener("click", () => void createProjectFlow());
  tools.append(search, create);
  head.append(tools);
  page.append(head);

  // Body holds either the full-width empty state or the project grid.
  // Empty state must not live inside the grid (grid tracks left-align it).
  const body = el("div", { class: "projects-body", id: "projects-body" });

  const paint = () => {
    body.innerHTML = "";
    const q = search.value.trim().toLowerCase();
    let list = projects.list();
    if (q) {
      list = list.filter(
        (p) =>
          p.name.toLowerCase().includes(q) ||
          p.description.toLowerCase().includes(q),
      );
    }
    if (list.length === 0) {
      const empty = el("div", { class: "empty-state" });
      empty.append(el("div", { class: "icon" }, ["▦"]));
      empty.append(el("h3", {}, [q ? "No matches" : "No projects yet"]));
      empty.append(
        el("p", {}, [
          q
            ? "Try a different search."
            : "Create a project to organize chats with shared instructions and context.",
        ]),
      );
      body.append(empty);
      return;
    }
    const grid = el("div", { class: "project-grid", id: "project-grid" });
    for (const p of list) {
      const card = el("button", { class: "project-card", type: "button" });
      card.append(el("div", { class: "project-card-title" }, [p.name]));
      if (p.description) {
        card.append(el("div", { class: "project-card-desc" }, [p.description]));
      }
      const n = history.listActive(p.id).length;
      card.append(
        el("div", { class: "project-card-meta" }, [
          n > 0
            ? `${n} chat${n === 1 ? "" : "s"} · ${relativeTime(p.updatedAt)}`
            : relativeTime(p.updatedAt),
        ]),
      );
      card.addEventListener("click", () => openProject(p.id));
      card.addEventListener("contextmenu", (e) => {
        e.preventDefault();
        void (async () => {
          const action = await appChoice({
            title: p.name,
            choices: [
              { id: "rename", label: "Rename" },
              { id: "delete", label: "Delete", danger: true },
            ],
          });
          if (action === "rename") {
            const t = await appPrompt({
              title: "Rename project",
              defaultValue: p.name,
              required: true,
              okLabel: "Rename",
            });
            if (t != null) {
              projects.rename(p.id, t.trim());
              paint();
            }
          } else if (action === "delete") {
            const ok = await appConfirm({
              title: "Delete project",
              message: `Delete “${p.name}”? Chats in this project are not deleted.`,
              okLabel: "Delete",
              danger: true,
            });
            if (!ok) return;
            projects.delete(p.id);
            paint();
          }
        })();
      });
      grid.append(card);
    }
    body.append(grid);
  };
  search.addEventListener("input", paint);
  paint();
  page.append(body);
  view.append(page);
}

/** Project home (ref: title, description, composer, project recents, right rail). */
function renderProjectDetail(projectId: string) {
  const project = projects.get(projectId);
  const view = $("view-projects");
  view.innerHTML = "";
  if (!project) {
    setTopbar({ title: "Projects" });
    view.append(el("div", { class: "page" }, [
      el("p", { class: "lead" }, ["Project not found."]),
    ]));
    return;
  }

  state.projectFilter = project.id;
  setTopbar({
    title: project.name,
    crumbs: [{ label: "Projects", href: "#/projects" }],
  });

  const shell = el("div", { class: "chat-shell with-rail project-detail-shell" });
  const mainCol = el("div", { class: "chat-main-col" });

  const hero = el("div", { class: "project-hero" });
  hero.append(el("h1", {}, [project.name]));
  if (project.description) {
    hero.append(el("p", { class: "project-desc" }, [project.description]));
  } else {
    hero.append(
      el("p", { class: "hint" }, [
        "Add a description so chats in this project share context.",
      ]),
    );
  }
  mainCol.append(hero);

  // Composer opens a new project chat and sends
  const composer = buildChatComposer();
  const ta = composer.querySelector("#chat-input") as HTMLTextAreaElement | null;
  if (ta) {
    ta.placeholder = "Write a message…";
    // Ensure send scopes to this project
    const orig = ta.onkeydown;
    void orig;
  }
  mainCol.append(composer);

  // Project recents under composer
  const recentWrap = el("div", { class: "project-recents" });
  recentWrap.append(el("div", { class: "project-recents-label" }, ["Recents"]));
  const projectChats = history.listActive(project.id);
  if (projectChats.length === 0) {
    recentWrap.append(
      el("div", { class: "settings-hint" }, ["No chats in this project yet."]),
    );
  } else {
    for (const c of projectChats.slice(0, 12)) {
      const row = el("button", { class: "project-recent-row", type: "button" });
      row.append(el("span", { class: "pr-icon" }, ["💬"]));
      row.append(el("span", { class: "pr-title" }, [c.title || "New chat"]));
      row.append(el("span", { class: "pr-time" }, [relativeTime(c.updatedAt)]));
      row.addEventListener("click", () => {
        history.setActive(c.id);
        if (c.provider) state.provider = c.provider;
        if (c.model) state.model = c.model;
        state.projectFilter = project.id;
        window.location.hash = "#/chats";
        showRoute("chats");
      });
      recentWrap.append(row);
    }
  }
  mainCol.append(recentWrap);
  shell.append(mainCol);

  // Right rail — Instructions / Memory / Context (Claude project home)
  const rail = el("aside", { class: "project-rail" });

  const instr = el("div", { class: "rail-section rail-card" });
  const instrHead = el("div", { class: "rail-section-head" });
  instrHead.append(el("h4", {}, ["Instructions"]));
  const editInstr = el("button", { class: "rail-icon-btn", type: "button", title: "Set instructions" }, ["+"]);
  editInstr.addEventListener("click", () => {
    openInstructionsModal(project, projects, el, () => renderProjectDetail(project.id));
  });
  instrHead.append(editInstr);
  instr.append(instrHead);
  instr.append(
    el("p", { class: "rail-copy" }, [
      project.instructions?.trim()
        ? project.instructions.trim().slice(0, 160) + (project.instructions.length > 160 ? "…" : "")
        : "Add instructions to tailor responses in this project.",
    ]),
  );
  rail.append(instr);

  const mem = el("div", { class: "rail-section rail-card" });
  const memHead = el("div", { class: "rail-section-head" });
  memHead.append(el("h4", {}, ["Memory"]));
  const memActions = el("div", { class: "rail-head-actions" });
  memActions.append(el("span", { class: "rail-lock" }, ["🔒 Only you"]));
  const editMem = el("button", { class: "rail-icon-btn", type: "button", title: "Manage memory" }, ["✎"]);
  editMem.addEventListener("click", () => {
    openMemoryModal(project, projects, el, () => renderProjectDetail(project.id));
  });
  memActions.append(editMem);
  memHead.append(memActions);
  mem.append(memHead);
  mem.append(el("p", { class: "rail-copy" }, [memoryPreview(project)]));
  mem.append(el("p", { class: "rail-meta" }, [memoryMeta(project)]));
  rail.append(mem);

  const ctx = el("div", { class: "rail-section rail-card" });
  const ctxHead = el("div", { class: "rail-section-head" });
  ctxHead.append(el("h4", {}, ["Context"]));
  const addCtx = el("button", { class: "rail-icon-btn", type: "button", title: "Add context" }, ["+"]);

  const fileInput = el("input", {
    type: "file",
    class: "hidden-file-input",
    multiple: "true",
    accept: ".txt,.md,.markdown,.json,.csv,.pdf,.png,.jpg,.jpeg,.webp",
  }) as HTMLInputElement;
  fileInput.style.display = "none";
  fileInput.addEventListener("change", async () => {
    const files = Array.from(fileInput.files ?? []);
    for (const file of files) {
      let content = "";
      try {
        if (file.type.startsWith("text/") || /\.(txt|md|markdown|json|csv|ts|js|swift)$/i.test(file.name)) {
          content = await file.text();
        } else {
          content = `[Binary file: ${file.name}, ${Math.round(file.size / 1024)} KB]`;
        }
      } catch {
        content = `[Could not read ${file.name}]`;
      }
      projects.addContextItem(project.id, {
        kind: "file",
        title: file.name,
        content,
        ref: file.name,
      });
    }
    fileInput.value = "";
    renderProjectDetail(project.id);
  });
  ctx.append(fileInput);

  const suggestions = [
    ...artifacts.list().map((a) => ({ title: a.title, content: a.content })),
    ...project.contextItems.map((c) => ({ title: c.title, content: c.content })),
  ];

  const openAddContext = (anchor: HTMLElement) => {
    openContextAddMenu(anchor, el, {
      artifactSuggestions: suggestions,
      onUploadFile: () => fileInput.click(),
      onAddText: () => {
        openAddTextContextModal(project.id, projects, el, () => renderProjectDetail(project.id));
      },
      onPickArtifact: (title, content) => {
        projects.addContextItem(project.id, {
          kind: "artifact",
          title,
          content,
        });
        renderProjectDetail(project.id);
      },
      onPasteUrl: (url) => {
        projects.addContextItem(project.id, {
          kind: "url",
          title: url.replace(/^https?:\/\//, "").slice(0, 60),
          content: `Linked resource: ${url}`,
          ref: url,
        });
        renderProjectDetail(project.id);
      },
      onConnector: (id) => {
        // Live connector auth is Settings → Connectors; flyout still lets users pick local resources.
        void id;
      },
    });
  };

  addCtx.addEventListener("click", (e) => {
    e.stopPropagation();
    openAddContext(addCtx);
  });
  ctxHead.append(addCtx);
  ctx.append(ctxHead);

  if (project.contextItems.length === 0) {
    const drop = el("div", {
      class: "context-drop",
      role: "button",
      tabindex: "0",
      title: "Add context",
    });
    drop.append(el("div", { class: "context-drop-title" }, ["Add PDFs, documents, or other text"]));
    drop.append(
      el("p", {}, ["Upload, paste text, or pick a resource from a connector."]),
    );
    drop.addEventListener("click", (e) => {
      e.stopPropagation();
      openAddContext(addCtx);
    });
    drop.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        openAddContext(addCtx);
      }
    });
    ctx.append(drop);
  } else {
    const list = el("div", { class: "context-item-list" });
    for (const item of project.contextItems) {
      const row = el("div", { class: "context-item-row" });
      const icon =
        item.kind === "file"
          ? "📎"
          : item.kind === "url"
            ? "🔗"
            : item.kind === "github"
              ? "⌘"
              : item.kind === "drive"
                ? "△"
                : "📄";
      row.append(el("span", { class: "ctx-ico" }, [icon]));
      row.append(el("span", { class: "context-item-title" }, [item.title]));
      const del = el("button", { class: "rail-icon-btn sm", type: "button", title: "Remove" }, ["×"]);
      del.addEventListener("click", () => {
        projects.removeContextItem(project.id, item.id);
        renderProjectDetail(project.id);
      });
      row.append(del);
      list.append(row);
    }
    // Sticky + row to add more
    const more = el("button", { class: "context-add-more", type: "button" }, ["+ Add more context"]);
    more.addEventListener("click", (e) => {
      e.stopPropagation();
      openAddContext(addCtx);
    });
    list.append(more);
    ctx.append(list);
  }
  rail.append(ctx);

  shell.append(rail);
  view.append(shell);
}

// ---------------------------------------------------------------------------
// Artifacts
// ---------------------------------------------------------------------------
function renderArtifacts() {
  setTopbar({ title: "Artifacts" });
  const view = $("view-artifacts");
  view.innerHTML = "";
  const page = el("div", { class: "page" });
  const head = el("div", { class: "page-header-row" });
  head.append(el("h2", {}, ["Artifacts"]));
  const tools = el("div", { class: "page-toolbar" });
  if (artifacts.list().length > 0) {
    const clear = el("button", { class: "ghost-btn", type: "button" }, ["Clear all"]);
    clear.addEventListener("click", () => {
      artifacts.clearAll();
      renderArtifacts();
    });
    tools.append(clear);
  }
  head.append(tools);
  page.append(head);
  page.append(
    el("p", { class: "lead" }, [
      "Long assistant replies and code blocks from chat appear here automatically. Tap a card to open it beside the original message.",
    ]),
  );

  const items = artifacts.list();
  if (items.length === 0) {
    const empty = el("div", { class: "empty-state" });
    empty.append(el("div", { class: "icon" }, ["⧉"]));
    empty.append(el("h3", {}, ["No artifacts yet"]));
    empty.append(
      el("p", {}, [
        "Long assistant replies and code blocks you receive in chat will appear here as cards.",
      ]),
    );
    page.append(empty);
  } else {
    const grid = el("div", { class: "artifact-grid" });
    for (const a of items) {
      const card = el("div", { class: "artifact-card" });
      card.append(el("div", { class: "tldr-label" }, ["TL;DR"]));
      const preview = a.content.trim().slice(0, 220).replace(/\s+/g, " ");
      card.append(el("div", { class: "tldr-body" }, [preview + (a.content.length > 220 ? "…" : "")]));
      card.append(el("div", { class: "art-title" }, [a.title]));
      card.append(
        el("div", { class: "art-meta" }, [
          `Edited ${new Date(a.createdAt).toLocaleDateString()}`,
        ]),
      );
      const actions = el("div", { class: "art-actions" });
      const copy = el("button", { class: "ghost-btn sm", type: "button" }, ["Copy"]);
      copy.addEventListener("click", (e) => {
        e.stopPropagation();
        void window.apc.clipboard.write(a.content);
      });
      const del = el("button", { class: "ghost-btn sm", type: "button" }, ["Delete"]);
      del.addEventListener("click", (e) => {
        e.stopPropagation();
        artifacts.delete(a.id);
        renderArtifacts();
      });
      actions.append(copy, del);
      card.append(actions);
      card.addEventListener("click", () => {
        openArtifactInChat(a.id);
      });
      card.title = a.sourceChatId
        ? "Open in original chat (split view)"
        : "Open in chat (split view)";
      grid.append(card);
    }
    page.append(grid);
  }
  view.append(page);
}

// ---------------------------------------------------------------------------
// Code (in-process server sessions)
// ---------------------------------------------------------------------------
async function ensurePairedAndConnected(): Promise<{ token: string; url: string } | null> {
  if (!state.bootstrap) return null;
  const port = state.bootstrap.serverPort;
  const host = state.bootstrap.serverHost === "0.0.0.0" || !state.bootstrap.serverHost
    ? "127.0.0.1"
    : state.bootstrap.serverHost;
  if (!port) return null;
  const code = state.bootstrap.pairingCode;
  if (!code) return null;

  const pairRes = await fetch(`http://${host}:${port}/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, deviceName: "RoamSocket (desktop)" }),
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
        reject(new Error("Server not ready — wait for pairing code, then try again."));
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

function sessionBody(): HTMLElement | null {
  return document.getElementById("session-body");
}

function handleServerMessage(raw: unknown): void {
  let msg: any;
  try {
    msg = JSON.parse(String(raw));
  } catch {
    return;
  }
  const body = sessionBody();
  if (!body) return;

  if (msg.type === "session_created") {
    state.sessionId = msg.sessionId;
    if (state.codeSessionLocalId) {
      codeSessions.update(state.codeSessionLocalId, {
        wireSessionId: msg.sessionId,
        status: "working",
        detail: msg.workdir ? `workdir: ${msg.workdir}` : undefined,
      });
    }
    body.querySelector(".empty-session")?.remove();
    appendCodeBubble(body, "assistant", "Session started", `workdir: ${msg.workdir}\nbranch: ${msg.workBranch}`);
    return;
  }
  if (msg.type === "assistant_delta") {
    body.querySelector(".empty-session")?.remove();
    let live = body.querySelector(".live-assistant") as HTMLElement | null;
    if (!live) {
      live = el("div", { class: "bubble-block assistant live-assistant" });
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
    body.querySelector(".live-assistant")?.classList.remove("live-assistant");
    appendCodeBubble(body, "tool", `${msg.tool}: ${msg.summary}`, JSON.stringify(msg.input, null, 2));
    return;
  }
  if (msg.type === "tool_result") {
    appendCodeBubble(body, "tool", msg.ok ? "✓ result" : "✗ result", msg.output);
    return;
  }
  if (msg.type === "diff") {
    appendCodeBubble(body, "diff", `diff ${msg.path} (+${msg.added} -${msg.removed})`, msg.patch);
    return;
  }
  if (msg.type === "permission_request") {
    appendCodeBubble(
      body,
      "tool",
      `permission: ${msg.tool}`,
      `${msg.summary}\n\n(Send "allow" or "deny" in the composer.)`,
    );
    return;
  }
  if (msg.type === "goal_status") {
    body.querySelector(".empty-session")?.remove();
    paintGoalBanner(msg);
    appendCodeBubble(body, "assistant", "goal", msg.message || msg.status);
    if (state.codeSessionLocalId && msg.status === "active") {
      codeSessions.update(state.codeSessionLocalId, {
        status: "working",
        detail: msg.condition ? `Goal: ${msg.condition}` : "Goal active",
      });
    }
    return;
  }
  if (msg.type === "session_done") {
    appendCodeBubble(body, "assistant", "session done", msg.stopReason ?? "");
    state.codeBusy = false;
    if (msg.stopReason === "goal_achieved") {
      // Keep achieved banner until cleared / next goal.
    } else if (msg.stopReason === "goal_cleared" || msg.stopReason === "goal_status") {
      // status-only commands
    }
    if (state.codeSessionLocalId) {
      codeSessions.update(state.codeSessionLocalId, {
        status: "ready_for_review",
        detail: msg.stopReason ?? "Session finished",
      });
    }
    const btn = document.getElementById("code-send") as HTMLButtonElement | null;
    if (btn) {
      btn.disabled = false;
      btn.textContent = "Send";
    }
    return;
  }
  if (msg.type === "pr_created") {
    appendCodeBubble(body, "assistant", "PR opened", msg.url);
    const parsed = parseGitHubPrUrl(msg.url);
    if (state.codeSessionLocalId) {
      codeSessions.update(state.codeSessionLocalId, {
        status: "ready_for_review",
        prUrl: msg.url,
        prNumber: parsed?.number,
        prState: "open",
        prBranch: state.code.workBranch || undefined,
        prDismissed: false,
      });
    }
    const chip = prChipFromParts({
      url: msg.url,
      state: "open",
      branch: state.code.workBranch || null,
      number: parsed?.number ?? null,
      repoLabel: parsed?.repoLabel ?? state.code.repo.split("/")[1] ?? state.code.repo,
    });
    paintPrBar(chip);
    void refreshPrBarFromGitHub(msg.url);
    return;
  }
  if (msg.type === "error") {
    appendCodeBubble(body, "error", "error", msg.message);
    state.codeBusy = false;
    if (state.codeSessionLocalId) {
      codeSessions.update(state.codeSessionLocalId, {
        status: "error",
        detail: msg.message,
      });
    }
    return;
  }
}

function appendCodeBubble(parent: HTMLElement, kind: string, meta: string, body: string) {
  const bubble = el("div", { class: `bubble-block ${kind}` });
  bubble.append(el("div", { class: "meta" }, [meta]));
  if (body) bubble.append(el("pre", {}, [body]));
  parent.append(bubble);
  parent.scrollTop = parent.scrollHeight;
}

/** Live `/goal` strip above the coding session transcript. */
function paintGoalBanner(msg: {
  status?: string;
  condition?: string;
  reason?: string;
  message?: string;
}): void {
  const host = document.getElementById("code-goal-bar");
  if (!host) return;
  const status = msg.status ?? "none";
  if (status === "cleared" || status === "none") {
    host.classList.add("hidden");
    host.innerHTML = "";
    return;
  }
  host.classList.remove("hidden");
  host.className = `code-goal-bar${status === "achieved" ? " is-achieved" : ""}`;
  host.innerHTML = "";
  const title =
    status === "achieved" ? "Goal achieved" : "◎ /goal active";
  const head = el("div", { class: "code-goal-head" });
  head.append(el("span", { class: "code-goal-title" }, [title]));
  if (status === "active") {
    const clear = el("button", { class: "ghost-btn sm", type: "button" }, ["Clear"]);
    clear.addEventListener("click", () => {
      const ta = document.getElementById("code-input") as HTMLTextAreaElement | null;
      if (ta) {
        ta.value = "/goal clear";
        void onCodeSend(ta);
      }
    });
    head.append(clear);
  }
  host.append(head);
  if (msg.condition) {
    host.append(el("div", { class: "code-goal-condition" }, [msg.condition]));
  }
  if (msg.reason) {
    host.append(el("div", { class: "code-goal-reason" }, [msg.reason]));
  } else if (msg.message && !msg.condition) {
    host.append(el("div", { class: "code-goal-reason" }, [msg.message]));
  }
}

const CODE_SLASH_COMMANDS: Array<{ token: string; detail: string }> = [
  { token: "/goal ", detail: "Keep working until a condition is met" },
  { token: "/goal", detail: "Show current goal status" },
  { token: "/goal clear", detail: "Clear the active goal" },
];

function filterCodeSlashCommands(raw: string): Array<{ token: string; detail: string }> {
  const t = raw.trim();
  if (!t.startsWith("/") || raw.includes("\n")) return [];
  const q = t.toLowerCase();
  return CODE_SLASH_COMMANDS.filter(
    (c) => c.token.toLowerCase().startsWith(q) || (q.startsWith("/g") && c.token.startsWith("/goal")),
  );
}

function paintCodeSlashMenu(ta: HTMLTextAreaElement, host: HTMLElement): void {
  const hits = filterCodeSlashCommands(ta.value);
  host.innerHTML = "";
  if (hits.length === 0) {
    host.classList.add("hidden");
    return;
  }
  host.classList.remove("hidden");
  for (const item of hits) {
    const row = el("button", { class: "code-slash-item", type: "button" });
    row.append(el("span", { class: "code-slash-token" }, [item.token.trimEnd()]));
    row.append(el("span", { class: "code-slash-detail" }, [item.detail]));
    row.addEventListener("click", () => {
      ta.value = item.token.endsWith(" ") ? item.token : `${item.token} `;
      ta.focus();
      paintCodeSlashMenu(ta, host);
    });
    host.append(row);
  }
}

// ---------------------------------------------------------------------------
// GitHub PR chip (state-colored bar under the session transcript)
// ---------------------------------------------------------------------------

function paintPrBar(chip: PrChipModel): void {
  const prBar = document.getElementById("code-pr-bar");
  if (!prBar) return;
  prBar.classList.remove("hidden");
  prBar.className = `code-pr-bar ${chip.toneClass}`;
  prBar.innerHTML = "";
  prBar.setAttribute("role", "status");
  prBar.title = chip.url;

  const left = el("div", { class: "pr-chip-left" });
  left.append(el("span", { class: "pr-chip-icon", "aria-hidden": "true" }, [chip.icon]));
  if (chip.number != null) {
    left.append(el("span", { class: "pr-chip-num" }, [`#${chip.number}`]));
  }
  left.append(el("span", { class: "pr-chip-repo" }, [chip.repoLabel]));
  if (chip.branch) {
    left.append(el("span", { class: "pr-chip-branch" }, [chip.branch]));
  } else {
    left.append(el("span", { class: "pr-chip-branch muted" }, [chip.url.replace(/^https:\/\/github\.com\//, "")]));
  }
  prBar.append(left);

  const right = el("div", { class: "pr-chip-right" });
  right.append(el("span", { class: "pr-chip-state" }, [chip.stateLabel]));
  const openBtn = el("button", {
    class: "pr-chip-open",
    type: "button",
    title: "Open on GitHub",
  }, ["↗"]);
  openBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    void window.apc.shell.open(chip.url);
  });
  const closeBtn = el("button", {
    class: "pr-chip-dismiss",
    type: "button",
    title: "Dismiss",
    "aria-label": "Dismiss PR chip",
  }, ["×"]);
  closeBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    prBar.classList.add("hidden");
    if (state.codeSessionLocalId) {
      codeSessions.update(state.codeSessionLocalId, { prDismissed: true });
    }
  });
  right.append(openBtn, closeBtn);
  prBar.append(right);

  prBar.onclick = () => {
    void window.apc.shell.open(chip.url);
  };
}

async function refreshPrBarFromGitHub(url: string): Promise<void> {
  try {
    const token = await window.apc.secrets.readGithubToken();
    const live = await fetchGitHubPrState(url, token);
    if (!live) return;
    const chip = prChipFromParts({
      url,
      state: live.state,
      branch: live.branch,
      number: live.number,
      repoLabel: live.repoLabel,
    });
    if (state.codeSessionLocalId) {
      codeSessions.update(state.codeSessionLocalId, {
        prUrl: url,
        prNumber: live.number,
        prState: live.state,
        prBranch: live.branch ?? undefined,
        status:
          live.state === "merged" || live.state === "closed"
            ? "done"
            : "ready_for_review",
      });
    }
    const rec = state.codeSessionLocalId
      ? codeSessions.get(state.codeSessionLocalId)
      : undefined;
    if (!rec?.prDismissed) paintPrBar(chip);
  } catch {
    // keep local open state
  }
}

function paintPrBarFromSession(rec: CodeSessionRecord | undefined): void {
  const prBar = document.getElementById("code-pr-bar");
  if (!prBar) return;
  if (!rec?.prUrl || rec.prDismissed) {
    prBar.classList.add("hidden");
    return;
  }
  const chip = prChipFromParts({
    url: rec.prUrl,
    state: (rec.prState as GitHubPrState) ?? "open",
    branch: rec.prBranch ?? rec.workBranch ?? null,
    number: rec.prNumber ?? null,
    repoLabel: rec.repo.includes("/") ? rec.repo.split("/")[1]! : rec.repo,
  });
  paintPrBar(chip);
  void refreshPrBarFromGitHub(rec.prUrl);
}

function renderCode() {
  const view = $("view-code");
  // Preserve live session transcript when re-rendering mid-session
  const existingBody = view.querySelector("#session-body");
  const preserved: Node[] = [];
  if (existingBody && state.codeInSession) {
    existingBody.childNodes.forEach((n) => preserved.push(n.cloneNode(true)));
  }

  if (state.codeInSession) {
    renderCodeSession(view, preserved);
  } else {
    renderCodeHome(view);
  }
}

function statusLabel(s: CodeSessionRecord["status"]): { text: string; cls: string } {
  switch (s) {
    case "working":
      return { text: "Working", cls: "st-working" };
    case "needs_input":
      return { text: "Needs input", cls: "st-needs" };
    case "ready_for_review":
      return { text: "Ready for review", cls: "st-ready" };
    case "done":
      return { text: "Done", cls: "st-done" };
    case "error":
      return { text: "Error", cls: "st-error" };
    default:
      return { text: s, cls: "" };
  }
}

function renderCodeHome(view: HTMLElement) {
  setTopbar({ title: "Code" });
  view.innerHTML = "";
  // Flex column: scrollable list body + dock pinned to the bottom of the view
  // (empty state used to leave the composer floating mid-page).
  const page = el("div", { class: "page code-home" });
  const body = el("div", { class: "code-home-body" });

  const hero = el("div", { class: "code-home-hero" });
  hero.append(el("h2", {}, ["Welcome back"]));
  body.append(hero);

  // Sessions
  const sec = el("div", { class: "code-home-section" });
  const secHead = el("div", { class: "code-home-section-head" });
  secHead.append(el("h3", {}, ["Sessions"]));
  const all = codeSessions.list();
  if (all.length > 5) {
    secHead.append(el("span", { class: "settings-hint" }, [`Show ${all.length} total`]));
  }
  sec.append(secHead);

  if (all.length === 0) {
    sec.append(
      el("p", { class: "settings-hint" }, [
        "No coding sessions yet. Describe a task below — the desktop agent runs locally against your repo.",
      ]),
    );
  } else {
    const list = el("div", { class: "code-session-list" });
    for (const s of all.slice(0, 12)) {
      const row = el("button", { class: "code-session-row", type: "button" });
      const st = statusLabel(s.status);
      row.append(el("span", { class: `code-status-pill ${st.cls}` }, [st.text]));
      row.append(el("span", { class: "code-session-title" }, [s.title]));
      if (s.detail) {
        row.append(el("span", { class: "code-session-detail" }, [s.detail.slice(0, 48)]));
      }
      row.append(el("span", { class: "code-session-repo" }, [s.repo || "—"]));
      row.append(el("span", { class: "code-session-time" }, [relativeTime(s.updatedAt)]));
      row.append(el("span", { class: "code-session-chev" }, [">"]));
      row.addEventListener("click", () => {
        state.codeInSession = true;
        state.codeSessionLocalId = s.id;
        state.sessionId = s.wireSessionId;
        state.code.repo = s.repo;
        state.code.baseBranch = s.baseBranch;
        state.code.workBranch = s.workBranch;
        state.code.provider = s.provider;
        state.code.model = s.model;
        renderCode();
      });
      list.append(row);
    }
    sec.append(list);
  }
  body.append(sec);

  // Pull requests
  const prs = all.filter((s) => s.prUrl);
  const prSec = el("div", { class: "code-home-section" });
  prSec.append(el("h3", {}, ["Pull requests"]));
  if (prs.length === 0) {
    prSec.append(
      el("p", { class: "settings-hint" }, [
        "PRs opened by coding sessions will show up here.",
      ]),
    );
  } else {
    const list = el("div", { class: "code-session-list" });
    for (const s of prs.slice(0, 8)) {
      const chip = prChipFromParts({
        url: s.prUrl!,
        state: s.prState ?? "open",
        branch: s.prBranch ?? s.workBranch,
        number: s.prNumber,
        repoLabel: s.repo.includes("/") ? s.repo.split("/")[1]! : s.repo,
      });
      const row = el("button", { class: "code-session-row", type: "button" });
      row.append(
        el("span", { class: `code-status-pill pr-list-${chip.toneClass}` }, [chip.stateLabel]),
      );
      row.append(
        el("span", { class: "code-session-title" }, [
          chip.number != null ? `#${chip.number} ${s.title}` : s.title,
        ]),
      );
      row.append(
        el("span", { class: "code-session-repo" }, [
          chip.branch ? `${chip.repoLabel} · ${chip.branch}` : chip.repoLabel,
        ]),
      );
      row.append(el("span", { class: "code-session-time" }, [relativeTime(s.updatedAt)]));
      row.addEventListener("click", () => {
        if (s.prUrl) void window.apc.shell.open(s.prUrl);
      });
      list.append(row);
    }
    prSec.append(list);
  }
  body.append(prSec);
  page.append(body);

  // Bottom task bar (repo pills + composer) — sibling of body so flex pins it
  const dock = el("div", { class: "code-dock" });
  const pills = el("div", { class: "code-dock-pills" });
  pills.append(el("span", { class: "code-pill" }, ["Local"]));
  const repoPill = el("span", { class: "code-pill code-pill-editable", title: "Repository" }, [
    state.code.repo || "repo",
  ]);
  repoPill.addEventListener("click", () => {
    void (async () => {
      const v = await appPrompt({
        title: "Repository",
        message: "owner/name",
        defaultValue: state.code.repo,
        placeholder: "owner/repo",
        okLabel: "Set",
      });
      if (v != null) {
        state.code.repo = v.trim();
        renderCodeHome(view);
      }
    })();
  });
  pills.append(repoPill);
  const branchPill = el("span", { class: "code-pill code-pill-editable" }, [
    state.code.workBranch || "branch",
  ]);
  branchPill.addEventListener("click", () => {
    void (async () => {
      const v = await appPrompt({
        title: "Work branch",
        defaultValue: state.code.workBranch,
        placeholder: "feature/my-change",
        okLabel: "Set",
      });
      if (v != null) {
        state.code.workBranch = v.trim();
        renderCodeHome(view);
      }
    })();
  });
  pills.append(branchPill);
  dock.append(pills);

  const composer = el("div", { class: "code-dock-composer" });
  const ta = el("textarea", {
    id: "code-input",
    placeholder: "Describe a task or ask a question",
    rows: "1",
  }) as HTMLTextAreaElement;
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void startCodeFromHome(ta);
    }
  });
  const send = el("button", { class: "send-circle active", type: "button", id: "code-send" }, ["↑"]);
  send.addEventListener("click", () => void startCodeFromHome(ta));
  composer.append(ta, send);
  dock.append(composer);

  const meta = el("div", { class: "code-dock-meta" });
  const modelBtn = el("button", { class: "ghost-btn sm", type: "button" }, [
    `${state.code.provider} · ${state.code.model || "model"} · ${state.code.effort}`,
  ]);
  modelBtn.addEventListener("click", () => {
    void (async () => {
      const catalog = mergeProviderCatalog(customsList()).filter((p) => p.id !== "localMetal");
      const providerOptions = catalog.map((p) => ({
        value: p.id,
        label: `${p.label} (${p.id})`,
      }));
      if (
        state.code.provider &&
        !providerOptions.some((o) => o.value === state.code.provider)
      ) {
        providerOptions.unshift({
          value: state.code.provider,
          label: state.code.provider,
        });
      }
      if (providerOptions.length === 0) {
        providerOptions.push({ value: "anthropic", label: "anthropic" });
      }
      const values = await appForm({
        title: "Code agent model",
        message: "Built-in or custom:<slug> providers from Settings.",
        fields: [
          {
            name: "provider",
            label: "Provider",
            type: "select",
            defaultValue: state.code.provider || providerOptions[0]!.value,
            options: providerOptions,
            required: true,
          },
          {
            name: "model",
            label: "Model id",
            defaultValue: state.code.model,
            placeholder: "claude-sonnet-4-…",
            required: true,
          },
          {
            name: "effort",
            label: "Effort",
            type: "select",
            defaultValue: state.code.effort,
            options: EFFORTS.map((e) => ({ value: e, label: e })),
            required: true,
          },
        ],
        okLabel: "Save",
      });
      if (!values) return;
      state.code.provider = (values.provider ?? "").trim();
      state.code.model = (values.model ?? "").trim();
      const effort = (values.effort ?? "") as Effort;
      if (EFFORTS.includes(effort)) state.code.effort = effort;
      renderCodeHome(view);
    })();
  });
  meta.append(modelBtn);
  dock.append(meta);

  page.append(dock);
  view.append(page);
}

async function startCodeFromHome(ta: HTMLTextAreaElement) {
  const text = ta.value.trim();
  if (!text) return;
  if (!state.code.repo) {
    const repo = await appPrompt({
      title: "Repository",
      message: "owner/name — required to start a coding session.",
      placeholder: "owner/repo",
      required: true,
      okLabel: "Continue",
    });
    if (!repo?.trim()) return;
    state.code.repo = repo.trim();
  }
  if (!state.code.model) {
    await appAlert({
      title: "Model required",
      message: "Set a model (click the model button under the composer).",
    });
    return;
  }
  const rec = codeSessions.create({
    title: text,
    repo: state.code.repo,
    baseBranch: state.code.baseBranch,
    workBranch: state.code.workBranch,
    provider: state.code.provider,
    model: state.code.model,
  });
  state.codeSessionLocalId = rec.id;
  state.codeInSession = true;
  state.sessionId = null;
  ta.value = "";
  renderCode();
  // Kick off send into the new session UI
  const input = document.getElementById("code-input") as HTMLTextAreaElement | null;
  if (input) {
    input.value = text;
    await onCodeSend(input);
  }
}

function renderCodeSession(view: HTMLElement, preserved: Node[]) {
  const rec = state.codeSessionLocalId
    ? codeSessions.get(state.codeSessionLocalId)
    : undefined;
  setTopbar({
    title: rec?.title?.slice(0, 48) || "Coding session",
    crumbs: [{ label: "Code", href: "#/code" }],
  });
  // Crumb "Code" should leave session
  view.innerHTML = "";

  const shell = el("div", { class: "code-shell code-session-shell" });

  // Toolbar: back + repo meta
  const bar = el("div", { class: "code-session-toolbar" });
  const back = el("button", { class: "ghost-btn sm", type: "button" }, ["← Sessions"]);
  back.addEventListener("click", () => {
    state.codeInSession = false;
    renderCode();
  });
  bar.append(back);
  bar.append(
    el("span", { class: "code-session-meta" }, [
      `${state.code.repo || "repo"} · ${state.code.workBranch}`,
    ]),
  );
  shell.append(bar);

  const prBar = el("div", {
    class: `code-pr-bar${rec?.prUrl && !rec.prDismissed ? "" : " hidden"}`,
    id: "code-pr-bar",
  });
  shell.append(prBar);
  if (rec?.prUrl && !rec.prDismissed) {
    // Defer so the node is in the DOM for paintPrBar
    queueMicrotask(() => paintPrBarFromSession(rec));
  }

  const goalBar = el("div", {
    class: "code-goal-bar hidden",
    id: "code-goal-bar",
  });
  shell.append(goalBar);

  const session = el("div", { class: "session code-session-panel" });
  const body = el("div", { class: "session-body", id: "session-body" });
  if (preserved.length) {
    for (const n of preserved) body.append(n);
  } else {
    body.append(
      el("div", { class: "empty-session" }, [
        "Agent output streams here — tools, diffs, and replies from the local coding server. Type /goal to set a completion condition.",
      ]),
    );
  }
  session.append(body);
  shell.append(session);

  const composerWrap = el("div", { class: "code-composer-wrap" });
  const slashMenu = el("div", {
    class: "code-slash-menu hidden",
    id: "code-slash-menu",
    role: "listbox",
  });
  const composer = el("div", { class: "code-composer" });
  const ta = el("textarea", {
    id: "code-input",
    placeholder: "Type / for commands (e.g. /goal), or continue the task…",
    rows: "2",
  }) as HTMLTextAreaElement;
  ta.addEventListener("input", () => paintCodeSlashMenu(ta, slashMenu));
  ta.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      slashMenu.classList.add("hidden");
      void onCodeSend(ta);
    }
  });
  const sendBtn = el("button", { class: "primary-btn", id: "code-send", type: "button" }, [
    "Send",
  ]);
  sendBtn.addEventListener("click", () => {
    slashMenu.classList.add("hidden");
    void onCodeSend(ta);
  });
  composer.append(ta, sendBtn);
  composerWrap.append(slashMenu, composer);
  shell.append(composerWrap);

  view.append(shell);

  // Fix breadcrumb Code click to leave session (hash already #/code)
  document.querySelector(".topbar-crumb")?.addEventListener("click", () => {
    state.codeInSession = false;
  });
}

async function onCodeSend(ta: HTMLTextAreaElement) {
  const text = ta.value.trim();
  if (!text || state.codeBusy) return;
  const body = sessionBody();
  if (!body) return;

  const isMetal = state.code.provider === "localMetal";
  const codeEp = endpointFor(state.code.provider);
  const apiKey = isMetal
    ? "local"
    : (await window.apc.secrets.readProviderKey(state.code.provider)) || "";
  if (!apiKey && !codeEp) {
    appendCodeBubble(
      body,
      "error",
      "missing API key",
      `Add a key for ${state.code.provider} in Settings before sending a coding task.`,
    );
    return;
  }
  if (state.code.provider.startsWith("custom:") && !codeEp) {
    appendCodeBubble(
      body,
      "error",
      "missing base URL",
      "This custom provider needs a base URL in Settings → Providers.",
    );
    return;
  }
  if (isMetal && !state.code.model) {
    appendCodeBubble(
      body,
      "error",
      "missing model",
      "Pick a downloaded Metal hub id (Settings → On-device Metal), then enter it as the model.",
    );
    return;
  }
  if (!state.code.repo) {
    appendCodeBubble(body, "error", "missing repo", "Pick a repository first (e.g. owner/name).");
    return;
  }
  if (!state.code.model) {
    appendCodeBubble(body, "error", "missing model", "Type a model id.");
    return;
  }

  body.querySelector(".empty-session")?.remove();
  appendCodeBubble(body, "user", "you", text);
  ta.value = "";
  state.codeBusy = true;
  const sendBtn = $("code-send") as HTMLButtonElement;
  sendBtn.disabled = true;
  sendBtn.textContent = "Working…";

  try {
    if (state.sessionId) {
      await sendClient({ type: "user_message", sessionId: state.sessionId, text });
    } else {
      const gh = await window.apc.secrets.readGithubToken();
      await sendClient({
        type: "create_session",
        repo: {
          fullName: state.code.repo,
          baseBranch: state.code.baseBranch || undefined,
          workBranch: state.code.workBranch || "roamsocket/change",
          githubToken: gh || undefined,
        },
        model: {
          provider: state.code.provider,
          model: state.code.model,
          effort: state.code.effort,
          apiKey: apiKey || "none",
          ...(codeEp
            ? { baseUrl: codeEp.baseUrl, apiStyle: codeEp.apiStyle }
            : {}),
        },
        permissionMode: "acceptEdits",
        skills: [],
        mcpServers: [],
      });
      // First message after session_created
      const waitForSession = async () => {
        for (let i = 0; i < 40; i++) {
          if (state.sessionId) {
            await sendClient({ type: "user_message", sessionId: state.sessionId, text });
            return;
          }
          await new Promise((r) => setTimeout(r, 100));
        }
        throw new Error("Timed out waiting for session_created");
      };
      void waitForSession().catch((err) => {
        appendCodeBubble(body, "error", "send failed", String((err as Error).message ?? err));
        state.codeBusy = false;
        sendBtn.disabled = false;
        sendBtn.textContent = "Send";
      });
    }
  } catch (err) {
    appendCodeBubble(body, "error", "send failed", String((err as Error).message ?? err));
    state.codeBusy = false;
    sendBtn.disabled = false;
    sendBtn.textContent = "Send";
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------
function renderSettings() {
  setTopbar({ title: "Settings" });
  const view = $("view-settings");
  view.innerHTML = "";

  const shell = el("div", { class: "settings-shell" });
  const nav = el("nav", { class: "settings-nav", "aria-label": "Settings sections" });
  const panel = el("div", { class: "settings-panel", id: "settings-panel" });

  const tabs: Array<{ id: SettingsTab; label: string; group?: string }> = [
    { id: "general", label: "General", group: "App" },
    { id: "providers", label: "Providers", group: "App" },
    { id: "github", label: "GitHub", group: "App" },
    { id: "metal", label: "Metal models", group: "App" },
    { id: "lightweight", label: "Lightweight Tasks", group: "App" },
    { id: "connection", label: "Connection", group: "App" },
    { id: "effort", label: "Effort", group: "Chat" },
    { id: "marketplace", label: "Marketplace", group: "Customize" },
    { id: "skills", label: "Skills", group: "Customize" },
    { id: "connectors", label: "Connectors", group: "Customize" },
    { id: "memory", label: "Manage memory", group: "Customize" },
    { id: "plugins", label: "Plugins", group: "Customize" },
  ];

  let lastGroup = "";
  for (const t of tabs) {
    if (t.group && t.group !== lastGroup) {
      nav.append(el("div", { class: "settings-nav-group" }, [t.group]));
      lastGroup = t.group;
    }
    const btn = el("button", {
      class: `settings-nav-item${state.settingsTab === t.id ? " active" : ""}`,
      type: "button",
      "data-tab": t.id,
    }, [t.label]);
    btn.addEventListener("click", () => {
      state.settingsTab = t.id;
      renderSettings();
    });
    nav.append(btn);
  }

  shell.append(nav, panel);
  view.append(shell);
  fillSettingsPanel(panel, state.settingsTab);
}

function fillSettingsPanel(panel: HTMLElement, tab: SettingsTab): void {
  panel.innerHTML = "";
  const title = el("div", { class: "settings-panel-title" }, [
    tab.charAt(0).toUpperCase() + tab.slice(1).replace(/([A-Z])/g, " $1"),
  ]);
  // prettier titles
  const titles: Record<SettingsTab, string> = {
    general: "General",
    providers: "Provider API keys",
    github: "GitHub",
    metal: "On-device Metal",
    lightweight: "Lightweight Tasks",
    connection: "Connection",
    effort: "Effort",
    memory: "Manage memory",
    marketplace: "Marketplace",
    skills: "Skills",
    connectors: "Connectors",
    plugins: "Plugins",
  };
  title.textContent = titles[tab];
  panel.append(title);

  if (tab === "general") fillSettingsGeneral(panel);
  else if (tab === "providers") fillSettingsProviders(panel);
  else if (tab === "github") fillSettingsGithub(panel);
  else if (tab === "metal") fillSettingsMetal(panel);
  else if (tab === "lightweight") void fillSettingsLightweight(panel);
  else if (tab === "connection") fillSettingsConnection(panel);
  else if (tab === "effort") fillSettingsEffort(panel);
  else if (tab === "memory") fillSettingsMemory(panel);
  else if (tab === "marketplace") void fillSettingsMarketplace(panel);
  else if (tab === "skills") fillSettingsSkills(panel);
  else if (tab === "connectors") fillSettingsConnectors(panel);
  else if (tab === "plugins") fillSettingsPlugins(panel);
}

function fillSettingsGeneral(panel: HTMLElement): void {
  const server = el("div", { class: "settings-section" });
  server.append(el("h3", {}, ["Server"]));
  if (state.bootstrap) {
    const b = state.bootstrap;
    const bindHost = b.serverHost ?? "0.0.0.0";
    server.append(el("div", {}, [`Listening: http://${bindHost}:${b.serverPort}`]));
    server.append(
      el("p", { class: "settings-hint" }, [
        "This desktop app hosts the coding server. Pair phones with the code below, or use Code mode locally without pairing.",
      ]),
    );
    const codeRow = el("div", { class: "provider-row" });
    codeRow.append(el("div", {}, [`Pairing code: ${b.pairingCode ?? "------"}`]));
    const showCode = el("button", { class: "ghost-btn", type: "button" }, ["Show popup"]);
    showCode.addEventListener("click", () => void window.apc.pairing.showCode());
    const rotateCode = el("button", { class: "ghost-btn", type: "button" }, ["Rotate"]);
    rotateCode.addEventListener("click", async () => {
      const next = await window.apc.pairing.rotateCode();
      if (next && state.bootstrap) {
        state.bootstrap.pairingCode = next;
        $("pairing-code").textContent = next;
        renderSettings();
      }
    });
    codeRow.append(el("div", {}, [showCode, " ", rotateCode]));
    server.append(codeRow);
  }
  panel.append(server);

  const perms = el("div", { class: "settings-section" });
  perms.append(el("h3", {}, ["Window & discovery"]));
  const p = state.bootstrap?.prefs;
  const addToggle = (
    parent: HTMLElement,
    label: string,
    key:
      | "allowLanDiscovery"
      | "autoTunnelOnPair"
      | "showPairingCodePopup"
      | "rotateCodeAfterPair"
      | "alwaysQuitOnClose"
      | "startMinimized",
    hint: string,
  ) => {
    const row = el("div", { class: "settings-toggle-row" });
    const left = el("div", { class: "settings-toggle-copy" });
    left.append(el("div", { class: "settings-toggle-title" }, [label]));
    left.append(el("div", { class: "settings-hint" }, [hint]));
    row.append(left);
    const on = !!(p as any)?.[key];
    const btn = el("button", { class: on ? "toggle-on" : "toggle-off", type: "button" }, [
      on ? "On" : "Off",
    ]);
    btn.addEventListener("click", async () => {
      const next = await window.apc.prefs.set({ [key]: !on });
      if (state.bootstrap) state.bootstrap.prefs = { ...state.bootstrap.prefs, ...next } as any;
      renderSettings();
    });
    row.append(btn);
    parent.append(row);
  };
  addToggle(perms, "LAN discovery (Bonjour)", "allowLanDiscovery", "Phones can find this machine on the same Wi‑Fi.");
  addToggle(perms, "Show pairing code popup", "showPairingCodePopup", "Large code window when the app starts.");
  addToggle(perms, "Start minimized", "startMinimized", "Launch hidden to the tray.");
  addToggle(perms, "Quit on window close", "alwaysQuitOnClose", "Otherwise closing keeps the server in the tray.");
  panel.append(perms);
}

function fillSettingsProviders(panel: HTMLElement): void {
  const providers = el("div", { class: "settings-section" });
  providers.append(
    el("p", { class: "settings-hint" }, [
      "BYOK keys stay on this machine (encrypted with the OS keychain when available).",
    ]),
  );
  for (const prov of CHAT_PROVIDERS) {
    if (prov.id === "localMetal") continue;
    const present = !!state.secrets?.providerKeys[prov.id]?.present;
    const row = el("div", { class: "provider-row" });
    row.append(el("div", {}, [prov.label]));
    row.append(el("div", { class: `pill ${present ? "ok" : "empty"}` }, [present ? "configured" : "empty"]));
    const setBtn = el("button", { class: "ghost-btn", type: "button" }, [present ? "Replace" : "Add"]);
    setBtn.addEventListener("click", async () => {
      const v = await appPrompt({
        title: `${present ? "Replace" : "Add"} API key`,
        message: `API key for ${prov.label}. Stored on this machine only.`,
        password: true,
        placeholder: "sk-…",
        required: true,
        okLabel: "Save key",
      });
      if (!v?.trim()) return;
      await window.apc.secrets.set({ providerKeys: { [prov.id]: v.trim() } as any });
      state.secrets = await window.apc.secrets.get();
      renderSettings();
    });
    const clearBtn = el("button", { class: "danger-btn", type: "button" }, ["Clear"]);
    clearBtn.disabled = !present;
    clearBtn.addEventListener("click", async () => {
      await window.apc.secrets.clearProvider(prov.id);
      state.secrets = await window.apc.secrets.get();
      renderSettings();
    });
    row.append(el("div", {}, [setBtn, " ", clearBtn]));
    providers.append(row);
  }
  panel.append(providers);

  // --- Custom / OpenAI-compatible & Anthropic proxy endpoints ---
  const customSec = el("div", { class: "settings-section" });
  customSec.append(el("h3", {}, ["Custom providers"]));
  customSec.append(
    el("p", { class: "settings-hint" }, [
      "Add OpenAI-compatible or Anthropic Messages endpoints (Ollama, LM Studio, proxies). Base URL should include the version segment (e.g. http://localhost:11434/v1). Keys are optional for local servers.",
    ]),
  );

  const customs = customsList();
  if (customs.length === 0) {
    customSec.append(
      el("p", { class: "settings-hint" }, ["No custom providers yet."]),
    );
  }
  for (const prov of customs) {
    const wireId = customProviderId(prov.id);
    const present = !!state.secrets?.providerKeys[wireId]?.present;
    const row = el("div", { class: "provider-row" });
    const title = el("div", {});
    title.append(document.createTextNode(prov.label));
    title.append(
      el("div", { class: "settings-hint", style: "margin:0" }, [
        `${wireId} · ${prov.apiStyle} · ${prov.baseUrl}`,
      ]),
    );
    row.append(title);
    row.append(
      el("div", { class: `pill ${present ? "ok" : "empty"}` }, [
        present ? "key set" : "no key",
      ]),
    );
    const actions = el("div", { class: "provider-row-actions" });
    const keyBtn = el("button", { class: "ghost-btn", type: "button" }, [
      present ? "Replace key" : "Add key",
    ]);
    keyBtn.addEventListener("click", async () => {
      const v = await appPrompt({
        title: `${present ? "Replace" : "Add"} API key`,
        message: `API key for ${prov.label}. Leave blank to clear (local servers often need none).`,
        password: true,
        placeholder: "optional",
        okLabel: "Save",
      });
      if (v == null) return;
      if (!v.trim()) {
        await window.apc.secrets.clearProvider(wireId);
      } else {
        await window.apc.secrets.set({ providerKeys: { [wireId]: v.trim() } as any });
      }
      state.secrets = await window.apc.secrets.get();
      renderSettings();
    });
    const editBtn = el("button", { class: "ghost-btn", type: "button" }, ["Edit"]);
    editBtn.addEventListener("click", () => {
      void promptEditCustomProvider(prov).then(() => renderSettings());
    });
    const delBtn = el("button", { class: "danger-btn", type: "button" }, ["Remove"]);
    delBtn.addEventListener("click", async () => {
      const ok = await appConfirm({
        title: "Remove provider",
        message: `Remove custom provider “${prov.label}”?`,
        okLabel: "Remove",
        danger: true,
      });
      if (!ok) return;
      removeCustomProvider(window.localStorage, prov.id);
      await window.apc.secrets.clearProvider(wireId);
      state.secrets = await window.apc.secrets.get();
      if (state.provider === wireId) {
        state.provider = "anthropic";
        state.model = "";
      }
      if (state.code.provider === wireId) {
        state.code.provider = "anthropic";
        state.code.model = "";
      }
      renderSettings();
    });
    actions.append(keyBtn, " ", editBtn, " ", delBtn);
    row.append(actions);
    customSec.append(row);
  }

  const addCustom = el("button", {
    class: "primary-btn",
    type: "button",
    style: "margin-top:12px",
  }, ["Add custom provider"]);
  addCustom.addEventListener("click", () => {
    void promptAddCustomProvider().then(() => renderSettings());
  });
  customSec.append(addCustom);
  panel.append(customSec);
}

async function promptAddCustomProvider(): Promise<void> {
  const values = await appForm({
    title: "Add custom provider",
    message:
      "OpenAI-compatible or Anthropic Messages endpoints (Ollama, LM Studio, proxies). Base URL should include the version segment.",
    fields: [
      {
        name: "label",
        label: "Display name",
        placeholder: "Ollama, Work proxy…",
        required: true,
      },
      {
        name: "baseUrl",
        label: "Base URL",
        defaultValue: "http://localhost:11434/v1",
        placeholder: "http://localhost:11434/v1",
        required: true,
        hint: "Include /v1 or equivalent path.",
      },
      {
        name: "apiStyle",
        label: "API style",
        type: "select",
        defaultValue: "openai",
        options: [
          { value: "openai", label: "OpenAI-compatible" },
          { value: "anthropic", label: "Anthropic Messages" },
        ],
      },
      {
        name: "defaultModel",
        label: "Default model id (optional)",
        placeholder: "llama3.2",
      },
      {
        name: "key",
        label: "API key (optional)",
        password: true,
        placeholder: "Leave blank for local servers",
      },
    ],
    okLabel: "Add provider",
  });
  if (!values) return;
  const label = (values.label ?? "").trim();
  const baseUrl = (values.baseUrl ?? "").trim();
  const apiStyle: CustomApiStyle =
    (values.apiStyle ?? "").trim().toLowerCase() === "anthropic" ? "anthropic" : "openai";
  const defaultModel = (values.defaultModel ?? "").trim() || undefined;
  const key = (values.key ?? "").trim();
  const rec = addCustomProvider(window.localStorage, {
    label,
    baseUrl,
    apiStyle,
    defaultModel,
  });
  if (!rec) {
    await appAlert({
      title: "Could not save",
      message: "Check the base URL (must be http or https).",
    });
    return;
  }
  if (key) {
    await window.apc.secrets.set({
      providerKeys: { [customProviderId(rec.id)]: key } as any,
    });
    state.secrets = await window.apc.secrets.get();
  }
}

async function promptEditCustomProvider(prov: CustomProvider): Promise<void> {
  const values = await appForm({
    title: "Edit custom provider",
    fields: [
      {
        name: "label",
        label: "Display name",
        defaultValue: prov.label,
        required: true,
      },
      {
        name: "baseUrl",
        label: "Base URL",
        defaultValue: prov.baseUrl,
        required: true,
        hint: "Include /v1 or equivalent path.",
      },
      {
        name: "apiStyle",
        label: "API style",
        type: "select",
        defaultValue: prov.apiStyle,
        options: [
          { value: "openai", label: "OpenAI-compatible" },
          { value: "anthropic", label: "Anthropic Messages" },
        ],
      },
      {
        name: "defaultModel",
        label: "Default model id (optional)",
        defaultValue: prov.defaultModel ?? "",
      },
    ],
    okLabel: "Save",
  });
  if (!values) return;
  const apiStyle: CustomApiStyle =
    (values.apiStyle ?? "").trim().toLowerCase() === "anthropic" ? "anthropic" : "openai";
  const updated = updateCustomProvider(window.localStorage, prov.id, {
    label: (values.label ?? "").trim() || prov.label,
    baseUrl: (values.baseUrl ?? "").trim() || prov.baseUrl,
    apiStyle,
    defaultModel: (values.defaultModel ?? "").trim(),
  });
  if (!updated) {
    await appAlert({
      title: "Could not update",
      message: "Check the base URL (must be http or https).",
    });
  }
}

function fillSettingsGithub(panel: HTMLElement): void {
  const gh = el("div", { class: "settings-section" });
  gh.append(
    el("p", { class: "settings-hint" }, [
      "Used to clone repos, open pull requests, and refresh PR status chips.",
    ]),
  );
  const ghRow = el("div", { class: "provider-row" });
  ghRow.append(el("div", {}, ["Personal access token"]));
  ghRow.append(
    el("div", { class: `pill ${state.secrets?.githubTokenPresent ? "ok" : "empty"}` }, [
      state.secrets?.githubTokenPresent ? "configured" : "empty",
    ]),
  );
  const ghSet = el("button", { class: "ghost-btn", type: "button" }, [
    state.secrets?.githubTokenPresent ? "Replace" : "Add",
  ]);
  ghSet.addEventListener("click", async () => {
    const v = await appPrompt({
      title: "GitHub token",
      message: "Personal access token for clone, PRs, and status chips.",
      password: true,
      placeholder: "ghp_… or github_pat_…",
      required: true,
      okLabel: "Save token",
    });
    if (!v?.trim()) return;
    await window.apc.secrets.set({ githubToken: v.trim() });
    state.secrets = await window.apc.secrets.get();
    renderSettings();
  });
  const ghClear = el("button", { class: "danger-btn", type: "button" }, ["Clear"]);
  ghClear.disabled = !state.secrets?.githubTokenPresent;
  ghClear.addEventListener("click", async () => {
    await window.apc.secrets.clearGithub();
    state.secrets = await window.apc.secrets.get();
    renderSettings();
  });
  ghRow.append(el("div", {}, [ghSet, " ", ghClear]));
  gh.append(ghRow);
  panel.append(gh);
}

function fillSettingsMetal(panel: HTMLElement): void {
  const metal = el("div", { class: "settings-section" });
  metal.append(
    el("p", { class: "settings-hint" }, [
      "On-device Metal chat uses a managed Python environment and the mlx-lm package. Install once, then download model families.",
    ]),
  );

  // Prominent one-click install (Python + mlx-lm)
  const installCard = el("div", { class: "metal-install-card" });
  installCard.append(el("div", { class: "metal-install-title" }, ["Metal runtime"]));
  installCard.append(
    el("p", { class: "settings-hint" }, [
      "Installs Python (via system/Homebrew if needed), creates a private venv under ~/.roamsocket/metal-runtime, and installs mlx-lm so models can run on this Mac.",
    ]),
  );
  const metalActions = el("div", {
    class: "tunnel-cli-actions",
    style: "justify-content:flex-start;margin-top:10px",
  });
  const installRuntimeBtn = el("button", {
    class: "primary-btn",
    type: "button",
    id: "btn-install-metal-runtime",
  }, ["Install Python + mlx-lm"]);
  installRuntimeBtn.title =
    "Install managed Python virtualenv and mlx-lm for on-device Metal models";
  const metalInstallLog = el("pre", { class: "install-log hidden" }, [""]);
  installRuntimeBtn.addEventListener("click", () => {
    void runMetalRuntimeInstall(installRuntimeBtn, metalInstallLog as HTMLPreElement, () => {
      renderSettings();
    });
  });
  const openMetal = el("button", { class: "ghost-btn", type: "button" }, ["Manage models…"]);
  openMetal.addEventListener("click", () => {
    window.location.hash = "#/metal";
  });
  metalActions.append(installRuntimeBtn, openMetal);
  installCard.append(metalActions);
  installCard.append(metalInstallLog);
  metal.append(installCard);

  void window.apc.metal.status().then((st) => {
    installCard.insertBefore(
      el("div", { class: `notice ${st.runtimeReady ? "ok" : "warn"}`, style: "margin-bottom:10px" }, [
        st.detail,
      ]),
      metalActions,
    );
    if (st.runtimeReady) {
      installRuntimeBtn.textContent = "Reinstall Python + mlx-lm";
      installRuntimeBtn.className = "ghost-btn";
      openMetal.className = "primary-btn";
    }
  }).catch(() => undefined);
  panel.append(metal);
}

async function fillSettingsLightweight(panel: HTMLElement): Promise<void> {
  lightweightPrefs = loadLightweightPrefs(window.localStorage);
  const sec = el("div", { class: "settings-section" });
  sec.append(
    el("p", { class: "settings-hint" }, [
      "Lightweight Tasks power short helpers: chat titles, artifact names, and similar. They stay separate from your main chat model. On Mac you can use Apple Intelligence; on Windows pick a linked model with an API key.",
    ]),
  );

  const modeRow = el("div", { class: "provider-row" });
  modeRow.append(el("div", {}, ["Backend"]));
  const modeSel = el("select") as HTMLSelectElement;
  modeSel.append(el("option", { value: "appleFoundation" }, ["Apple Intelligence"]));
  modeSel.append(el("option", { value: "linkedModel" }, ["Linked model"]));
  modeSel.value = lightweightPrefs.mode;
  modeSel.addEventListener("change", () => {
    lightweightPrefs = {
      ...lightweightPrefs,
      mode: modeSel.value as LightweightTasksPrefs["mode"],
    };
    saveLightweightPrefs(window.localStorage, lightweightPrefs);
    renderSettings();
  });
  modeRow.append(modeSel);
  sec.append(modeRow);

  const statusBox = el("div", { class: "notice warn" }, ["Checking Apple Intelligence…"]);
  sec.append(statusBox);
  try {
    const st = await window.apc.lightweight.foundationStatus();
    statusBox.className = `notice ${st.ready ? "ok" : "warn"}`;
    statusBox.textContent = st.detail;
    if (!st.supported && lightweightPrefs.mode === "appleFoundation") {
      lightweightPrefs = { ...lightweightPrefs, mode: "linkedModel" };
      saveLightweightPrefs(window.localStorage, lightweightPrefs);
      modeSel.value = "linkedModel";
    }
  } catch (err) {
    statusBox.textContent = String((err as Error).message ?? err);
  }

  const link = el("div", { class: "settings-section" });
  link.append(el("h3", {}, ["Linked model"]));
  link.append(
    el("p", { class: "settings-hint" }, [
      "Used when Apple Intelligence is off, unavailable, or you choose Linked model. Requires a provider API key in Providers.",
    ]),
  );

  const provRow = el("div", { class: "provider-row" });
  provRow.append(el("div", {}, ["Provider"]));
  const provSel = el("select") as HTMLSelectElement;
  provSel.append(el("option", { value: "" }, ["Select…"]));
  for (const p of CHAT_PROVIDERS) {
    if (p.id === "localMetal") continue;
    provSel.append(el("option", { value: p.id }, [p.label]));
  }
  if (lightweightPrefs.linkedProvider) provSel.value = lightweightPrefs.linkedProvider;
  provRow.append(provSel);
  link.append(provRow);

  const modelRow = el("div", { class: "provider-row" });
  modelRow.append(el("div", {}, ["Model id"]));
  const modelInput = el("input", {
    type: "text",
    placeholder: defaultModelFor(provSel.value || "anthropic"),
    value: lightweightPrefs.linkedModel || "",
  }) as HTMLInputElement;
  modelRow.append(modelInput);
  link.append(modelRow);

  provSel.addEventListener("change", () => {
    if (!modelInput.value) modelInput.value = defaultModelFor(provSel.value);
  });

  const saveBtn = el("button", { class: "primary-btn", type: "button" }, ["Save Lightweight Tasks"]);
  saveBtn.addEventListener("click", () => {
    lightweightPrefs = {
      ...lightweightPrefs,
      mode: modeSel.value as LightweightTasksPrefs["mode"],
      linkedProvider: provSel.value || null,
      linkedModel: modelInput.value.trim() || null,
    };
    saveLightweightPrefs(window.localStorage, lightweightPrefs);
    const ok = el("div", { class: "notice ok" }, [
      `Saved · ${lightweightModeLabel(lightweightPrefs.mode)}` +
      (lightweightPrefs.linkedModel ? ` · ${lightweightPrefs.linkedModel}` : ""),
    ]);
    panel.append(ok);
  });
  link.append(saveBtn);

  const replay = el("button", { class: "ghost-btn", type: "button", style: "margin-top:12px" }, [
    "Replay walkthrough…",
  ]);
  replay.addEventListener("click", () => {
    lightweightPrefs = { ...lightweightPrefs, walkthroughCompleted: false };
    saveLightweightPrefs(window.localStorage, lightweightPrefs);
    showWalkthrough();
  });
  link.append(replay);

  panel.append(sec, link);
}

function fillSettingsConnection(panel: HTMLElement): void {
  const p = state.bootstrap?.prefs;
  const perms = el("div", { class: "settings-section" });
  perms.append(el("h3", {}, ["Permissions"]));
  const addToggle = (
    parent: HTMLElement,
    label: string,
    key: "autoTunnelOnPair" | "rotateCodeAfterPair",
    hint: string,
  ) => {
    const row = el("div", { class: "settings-toggle-row" });
    const left = el("div", { class: "settings-toggle-copy" });
    left.append(el("div", { class: "settings-toggle-title" }, [label]));
    left.append(el("div", { class: "settings-hint" }, [hint]));
    row.append(left);
    const on = !!(p as any)?.[key];
    const btn = el("button", { class: on ? "toggle-on" : "toggle-off", type: "button" }, [
      on ? "On" : "Off",
    ]);
    btn.addEventListener("click", async () => {
      const next = await window.apc.prefs.set({ [key]: !on });
      if (state.bootstrap) state.bootstrap.prefs = { ...state.bootstrap.prefs, ...next } as any;
      renderSettings();
    });
    row.append(btn);
    parent.append(row);
  };
  addToggle(perms, "Auto tunnel after pair", "autoTunnelOnPair", "Start a public tunnel after phone pair.");
  addToggle(perms, "Rotate code after pair", "rotateCodeAfterPair", "Issue a new code after each pair.");
  panel.append(perms);

  const remote = el("div", { class: "settings-section" });
  remote.append(el("h3", {}, ["Remote access"]));
  remote.append(
    el("p", { class: "settings-hint" }, [
      "Expose this desktop’s coding server on a public HTTPS URL for phones off Wi‑Fi.",
    ]),
  );
  const remoteBody = el("div", { id: "remote-access-body" });
  remoteBody.append(el("div", { class: "settings-hint" }, ["Loading…"]));
  remote.append(remoteBody);
  panel.append(remote);
  void refreshRemoteAccess(remoteBody);

  const tunnels = el("div", { class: "settings-section" });
  tunnels.append(el("h3", {}, ["Tunnel tools"]));
  const tunnelList = el("div", { id: "tunnel-cli-list" });
  tunnelList.append(el("div", { class: "settings-hint" }, ["Loading…"]));
  tunnels.append(tunnelList);
  const installLog = el("pre", { class: "install-log hidden", id: "tunnel-install-log" }, [""]);
  tunnels.append(installLog);
  panel.append(tunnels);
  void refreshTunnelCliRows(tunnelList, installLog as HTMLPreElement);
}

function fillSettingsEffort(panel: HTMLElement): void {
  const sec = el("div", { class: "settings-section" });
  sec.append(
    el("p", { class: "settings-hint" }, [
      "Default reasoning depth for chat and coding. You can still change effort per session from the model control.",
    ]),
  );

  const sliderWrap = el("div", { class: "effort-control" });
  const labels = el("div", { class: "effort-labels" });
  for (const e of EFFORTS) {
    const lab = el("button", {
      class: `effort-label${uiPrefs.defaultEffort === e ? " active" : ""}`,
      type: "button",
    }, [effortExplanation(e).label]);
    lab.addEventListener("click", () => {
      uiPrefs.defaultEffort = e;
      state.code.effort = e;
      saveDesktopUiPrefs(window.localStorage, uiPrefs);
      renderSettings();
    });
    labels.append(lab);
  }
  sliderWrap.append(labels);

  const range = el("input", {
    type: "range",
    min: "0",
    max: "2",
    step: "1",
    class: "effort-range",
    value: String(EFFORTS.indexOf(uiPrefs.defaultEffort)),
  }) as HTMLInputElement;
  range.addEventListener("input", () => {
    const e = EFFORTS[Number(range.value)] ?? "high";
    uiPrefs.defaultEffort = e;
    state.code.effort = e;
    saveDesktopUiPrefs(window.localStorage, uiPrefs);
    renderSettings();
  });
  sliderWrap.append(range);

  const guide = effortExplanation(uiPrefs.defaultEffort);
  const card = el("div", { class: "effort-explain" });
  card.append(el("div", { class: "effort-explain-title" }, [guide.summary]));
  card.append(el("p", {}, [guide.detail]));
  sliderWrap.append(card);
  sec.append(sliderWrap);
  panel.append(sec);
}

function fillSettingsMemory(panel: HTMLElement): void {
  const wrap = el("div", { class: "settings-section memory-settings" });
  wrap.append(
    el("p", { class: "settings-hint" }, [
      "Memory stays on this device. Project Instructions and open chat history still apply when toggles are off.",
    ]),
  );

  const addMemToggle = (
    title: string,
    hint: string,
    key: "memorySearchChats" | "memoryGenerateFromChats",
  ) => {
    const row = el("div", { class: "settings-toggle-row" });
    const left = el("div", { class: "settings-toggle-copy" });
    left.append(el("div", { class: "settings-toggle-title" }, [title]));
    left.append(el("div", { class: "settings-hint" }, [hint]));
    row.append(left);
    const on = uiPrefs[key];
    const btn = el("button", {
      class: `settings-switch${on ? " on" : ""}`,
      type: "button",
      role: "switch",
      "aria-checked": on ? "true" : "false",
      "aria-label": title,
    });
    btn.addEventListener("click", () => {
      uiPrefs[key] = !on;
      saveDesktopUiPrefs(window.localStorage, uiPrefs);
      renderSettings();
    });
    row.append(btn);
    wrap.append(row);
  };

  addMemToggle(
    "Search and reference chats",
    "Allow the assistant to search for relevant details in past chats.",
    "memorySearchChats",
  );
  addMemToggle(
    "Generate memory from chats",
    "Allow the assistant to generate lasting memory from your chats.",
    "memoryGenerateFromChats",
  );

  // Import from other AI providers
  const importRow = el("div", { class: "settings-toggle-row memory-import-row" });
  const importLeft = el("div", { class: "settings-toggle-copy" });
  importLeft.append(
    el("div", { class: "settings-toggle-title" }, ["Import memory from other AI providers"]),
  );
  importLeft.append(
    el("div", { class: "settings-hint" }, [
      "Bring relevant context and data from another AI provider. Copy a prompt, paste the export, and add it to memory.",
    ]),
  );
  importRow.append(importLeft);
  const startImport = el("button", { class: "ghost-btn", type: "button" }, ["Start import"]);
  startImport.addEventListener("click", () => openMemoryImportModal());
  importRow.append(startImport);
  wrap.append(importRow);

  // Structured entries by category
  for (const cat of MEMORY_CATEGORY_ORDER) {
    const items = userMemory.byCategory(cat);
    if (items.length === 0) continue;
    wrap.append(el("div", { class: "memory-section-label" }, [MEMORY_CATEGORY_LABELS[cat]]));
    for (const entry of items) {
      wrap.append(memoryEntryRow(entry));
    }
  }

  if (userMemory.isEmpty()) {
    wrap.append(
      el("p", { class: "settings-hint memory-empty-hint" }, [
        "No saved memories yet. Type a fact below (for example “My dog’s name is Beans”) or import from another AI.",
      ]),
    );
  }

  // Freeform add
  const adjustRow = el("div", { class: "memory-adjust-row memory-settings-input" });
  const input = el("input", {
    class: "memory-adjust-input",
    type: "text",
    placeholder: "My dog’s name is Beans",
    autocomplete: "off",
  }) as HTMLInputElement;
  const send = el("button", {
    class: "memory-adjust-send",
    type: "button",
    "aria-label": "Add to memory",
  }, ["↑"]);
  const submit = () => {
    const text = input.value.trim();
    if (!text) return;
    userMemory.addFreeformFact(text);
    input.value = "";
    renderSettings();
  };
  send.addEventListener("click", submit);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      submit();
    }
  });
  adjustRow.append(input, send);
  wrap.append(adjustRow);

  panel.append(wrap);
}

function memoryEntryRow(entry: MemoryEntry): HTMLElement {
  const row = el("button", { class: "memory-entry-row", type: "button" });
  row.append(el("span", { class: "memory-entry-title" }, [entry.title]));
  row.append(
    el("span", { class: "memory-entry-summary" }, [
      entry.summary || entry.details[0] || "No summary",
    ]),
  );
  row.append(
    el("span", { class: "memory-entry-time" }, [relativeMemoryTime(entry.updatedAt)]),
  );
  row.addEventListener("click", () => openMemoryEntryDetail(entry.id));
  return row;
}

function openMemoryEntryDetail(entryId: string): void {
  const entry = userMemory.get(entryId);
  if (!entry) return;

  const backdrop = el("div", { class: "modal-backdrop project-modal-backdrop" });
  const modal = el("div", { class: "modal project-modal memory-detail-modal" });

  const paint = () => {
    modal.innerHTML = "";
    const cur = userMemory.get(entryId);
    if (!cur) {
      backdrop.remove();
      renderSettings();
      return;
    }

    const head = el("div", { class: "project-modal-head memory-detail-head" });
    const back = el("button", {
      class: "ghost-btn sm memory-back",
      type: "button",
    }, ["← Memory"]);
    back.addEventListener("click", () => {
      backdrop.remove();
      renderSettings();
    });
    head.append(back);
    const closeX = el("button", { class: "modal-x", type: "button", "aria-label": "Close" }, ["×"]);
    closeX.addEventListener("click", () => {
      backdrop.remove();
      renderSettings();
    });
    head.append(closeX);
    modal.append(head);

    const titleRow = el("div", { class: "memory-detail-title-row" });
    titleRow.append(el("h3", {}, [cur.title]));
    const del = el("button", { class: "ghost-btn sm", type: "button" }, ["Delete"]);
    del.addEventListener("click", () => {
      void (async () => {
        const ok = await appConfirm({
          title: "Delete memory",
          message: `Delete memory “${cur.title}”?`,
          okLabel: "Delete",
          danger: true,
        });
        if (!ok) return;
        userMemory.delete(cur.id);
        backdrop.remove();
        renderSettings();
      })();
    });
    titleRow.append(del);
    modal.append(titleRow);

    modal.append(el("div", { class: "memory-detail-label" }, ["Summary"]));
    modal.append(
      el("p", { class: "memory-detail-summary" }, [
        cur.summary || "No summary yet.",
      ]),
    );

    modal.append(el("div", { class: "memory-detail-label" }, ["Details"]));
    if (cur.details.length === 0) {
      modal.append(el("p", { class: "settings-hint" }, ["No details yet."]));
    } else {
      const list = el("ul", { class: "memory-detail-list" });
      for (const d of cur.details) {
        list.append(el("li", {}, [d]));
      }
      modal.append(list);
    }

    const adjustRow = el("div", { class: "memory-adjust-row" });
    const input = el("input", {
      class: "memory-adjust-input",
      type: "text",
      placeholder: "Tell the assistant what to change or remove",
      autocomplete: "off",
    }) as HTMLInputElement;
    const send = el("button", {
      class: "memory-adjust-send",
      type: "button",
      "aria-label": "Apply",
    }, ["↑"]);
    const apply = () => {
      const cmd = input.value.trim();
      if (!cmd) return;
      userMemory.applyEntryCommand(cur.id, cmd);
      input.value = "";
      paint();
    };
    send.addEventListener("click", apply);
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        apply();
      }
    });
    adjustRow.append(input, send);
    modal.append(adjustRow);
    queueMicrotask(() => input.focus());
  };

  paint();
  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) {
      backdrop.remove();
      renderSettings();
    }
  });
  backdrop.append(modal);
  document.body.append(backdrop);
}

function openMemoryImportModal(): void {
  const backdrop = el("div", { class: "modal-backdrop project-modal-backdrop" });
  const modal = el("div", { class: "modal project-modal memory-import-modal" });

  const head = el("div", { class: "project-modal-head" });
  head.append(el("h3", {}, ["Import memory"]));
  const closeX = el("button", { class: "modal-x", type: "button", "aria-label": "Close" }, ["×"]);
  head.append(closeX);
  modal.append(head);

  modal.append(
    el("div", { class: "memory-import-step" }, [
      el("div", { class: "memory-import-step-num" }, ["1"]),
      el("div", { class: "memory-import-step-body" }, [
        el("div", { class: "memory-import-step-title" }, [
          "Copy this prompt into a chat with your other AI provider",
        ]),
      ]),
    ]),
  );

  const promptBox = el("div", { class: "memory-import-prompt" });
  const promptPre = el("pre", {}, [MEMORY_IMPORT_PROMPT]);
  const copyBtn = el("button", { class: "ghost-btn sm", type: "button" }, ["Copy"]);
  copyBtn.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(MEMORY_IMPORT_PROMPT);
      copyBtn.textContent = "Copied";
      setTimeout(() => {
        copyBtn.textContent = "Copy";
      }, 1500);
    } catch {
      // Fallback
      const ta = document.createElement("textarea");
      ta.value = MEMORY_IMPORT_PROMPT;
      document.body.append(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
      copyBtn.textContent = "Copied";
      setTimeout(() => {
        copyBtn.textContent = "Copy";
      }, 1500);
    }
  });
  promptBox.append(promptPre, copyBtn);
  modal.append(promptBox);

  modal.append(
    el("div", { class: "memory-import-step" }, [
      el("div", { class: "memory-import-step-num" }, ["2"]),
      el("div", { class: "memory-import-step-body" }, [
        el("div", { class: "memory-import-step-title" }, [
          "Paste results below to add to memory",
        ]),
      ]),
    ]),
  );

  const paste = el("textarea", {
    class: "project-modal-textarea memory-import-paste",
    rows: "8",
    placeholder: "Paste your memory details here",
  }) as HTMLTextAreaElement;
  modal.append(paste);

  const actions = el("div", { class: "project-modal-actions" });
  const cancel = el("button", { class: "ghost-btn", type: "button" }, ["Cancel"]);
  const add = el("button", { class: "primary-btn", type: "button" }, ["Add to memory"]);
  actions.append(cancel, add);
  modal.append(actions);

  const close = () => backdrop.remove();
  closeX.addEventListener("click", close);
  cancel.addEventListener("click", close);
  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) close();
  });
  add.addEventListener("click", () => {
    const text = paste.value.trim();
    if (!text) return;
    const n = userMemory.importFromText(text);
    close();
    renderSettings();
    if (n > 0) {
      // Soft feedback without blocking
      const notice = el("div", { class: "notice ok" }, [
        n === 1 ? "Added 1 memory entry." : `Added ${n} memory entries.`,
      ]);
      notice.style.position = "fixed";
      notice.style.bottom = "24px";
      notice.style.right = "24px";
      notice.style.zIndex = "100";
      document.body.append(notice);
      setTimeout(() => notice.remove(), 2500);
    }
  });

  backdrop.append(modal);
  document.body.append(backdrop);
  queueMicrotask(() => paste.focus());
}

function fillSettingsSkills(panel: HTMLElement): void {
  const sec = el("div", { class: "settings-section" });
  sec.append(
    el("p", { class: "settings-hint" }, [
      "Skills are playbooks the model can follow. Pick one from the chat + menu to insert a blue /skill chip. Click a chip or a row below to manage.",
    ]),
  );

  const list = skillsStore.list();
  if (list.length === 0) {
    sec.append(
      el("div", { class: "settings-table-row muted" }, [
        el("span", {}, ["No skills installed"]),
      ]),
    );
  } else {
    const table = el("div", { class: "settings-table skills-table" });
    for (const s of list) {
      const row = el("button", { class: "settings-skill-row", type: "button" });
      const left = el("div", { class: "settings-skill-left" });
      left.append(el("div", { class: "settings-skill-name" }, [s.name]));
      left.append(el("div", { class: "settings-hint" }, [s.description]));
      row.append(left);
      row.append(el("span", { class: "settings-skill-meta" }, [s.builtin ? "Built-in" : "Custom"]));
      row.addEventListener("click", () => openSkillManage(s.id));
      table.append(row);
    }
    sec.append(table);
  }

  const actions = el("div", { class: "tunnel-cli-actions", style: "margin-top:14px;justify-content:flex-start" });
  const create = el("button", { class: "primary-btn", type: "button" }, ["New skill"]);
  create.addEventListener("click", () => {
    void (async () => {
      const name = await appPrompt({
        title: "New skill",
        message: "Short name used for /slash commands (e.g. my-helper).",
        placeholder: "my-helper",
        required: true,
        okLabel: "Create",
      });
      if (!name?.trim()) return;
      const rec = skillsStore.create({
        name: name.trim(),
        description: "Custom skill",
        instructions: `# ${name.trim()}\n\nDescribe what this skill should do.\n`,
      });
      openEditSkillModal(rec.id, skillsStore, el, {
        onSaved: () => renderSettings(),
      });
    })();
  });
  const browse = el("button", { class: "ghost-btn", type: "button" }, ["Marketplace"]);
  browse.addEventListener("click", () => {
    state.settingsTab = "marketplace";
    renderSettings();
  });
  const docs = el("button", { class: "ghost-btn", type: "button" }, ["Browse community"]);
  docs.addEventListener("click", () => {
    void window.apc.shell.open("https://github.com/anthropics/skills");
  });
  actions.append(create, browse, docs);

  const mpSkills = state.marketplace?.catalog.skills ?? [];
  if (mpSkills.length) {
    sec.append(el("div", { class: "settings-subhead", style: "margin-top:18px" }, ["From marketplace"]));
    const mpTable = el("div", { class: "settings-table skills-table" });
    for (const s of mpSkills.slice(0, 12)) {
      const row = el("div", { class: "settings-table-row", style: "align-items:center;gap:10px" });
      const left = el("div", { style: "flex:1;min-width:0" });
      left.append(el("span", {}, [s.name + (s.featured ? " ★" : "")]));
      left.append(el("span", { class: "settings-hint" }, [s.description.slice(0, 80)]));
      row.append(left);
      if (isMarketplaceSkillInstalled(skillsStore, s.id)) {
        row.append(el("span", { class: "pill ok" }, ["Installed"]));
      } else {
        const installBtn = el("button", { class: "ghost-btn sm", type: "button" }, ["Install"]);
        installBtn.addEventListener("click", () => {
          try {
            installMarketplaceSkill(skillsStore as InstallTarget, s);
            showToast(`Installed skill “${s.name}”`);
            renderSettings();
          } catch (e) {
            void appAlert({ title: "Install failed", message: String((e as Error).message ?? e) });
          }
        });
        row.append(installBtn);
      }
      mpTable.append(row);
    }
    sec.append(mpTable);
  }

  sec.append(actions);
  panel.append(sec);
}

function showToast(message: string): void {
  const notice = el("div", { class: "notice ok" }, [message]);
  notice.style.position = "fixed";
  notice.style.bottom = "24px";
  notice.style.right = "24px";
  notice.style.zIndex = "100";
  document.body.append(notice);
  setTimeout(() => notice.remove(), 2500);
}

async function fillSettingsMarketplace(panel: HTMLElement): Promise<void> {
  const sec = el("div", { class: "settings-section" });
  sec.append(
    el("p", { class: "settings-hint" }, [
      "Marketplaces publish connectors, skill listings, plugins, and recommended Metal models via catalog.json. The official source is the RoamSocket marketplace catalog — add your own GitHub repos anytime.",
    ]),
  );

  let status: MarketplaceStatus;
  try {
    status = state.marketplace ?? (await window.apc.marketplace.status());
    state.marketplace = status;
  } catch (err) {
    sec.append(
      el("div", { class: "notice warn" }, [
        `Could not load marketplaces: ${(err as Error).message ?? err}`,
      ]),
    );
    panel.append(sec);
    return;
  }

  const meta = el("div", { class: "settings-hint", style: "margin-bottom:12px" });
  meta.textContent = status.usingBundledOnly
    ? "Using bundled catalog (offline or no successful fetch yet)."
    : `Merged catalog: ${status.catalog.connectors.length} connectors · ${status.catalog.skills.length} skills · ${status.catalog.plugins.length} plugins · ${status.catalog.metalModels.length} Metal models`;
  sec.append(meta);

  const list = el("div", { class: "settings-table" });
  for (const src of status.sources) {
    const row = el("div", { class: "settings-table-row", style: "align-items:flex-start;gap:10px" });
    const left = el("div", { style: "flex:1;min-width:0" });
    left.append(
      el("div", { class: "settings-skill-name" }, [
        src.name + (src.isDefault ? " (default)" : ""),
      ]),
    );
    left.append(
      el("div", { class: "settings-hint", style: "word-break:break-all" }, [src.url]),
    );
    if (src.lastError) {
      left.append(el("div", { class: "settings-hint", style: "color:var(--warn,#e8a838)" }, [src.lastError]));
    } else if (src.catalogName) {
      left.append(el("div", { class: "settings-hint" }, [src.catalogName]));
    }
    row.append(left);

    const en = el("button", {
      class: `ghost-btn sm${src.enabled ? "" : ""}`,
      type: "button",
    }, [src.enabled ? "On" : "Off"]);
    en.addEventListener("click", async () => {
      try {
        const next = await window.apc.marketplace.setSourceEnabled(src.id, !src.enabled);
        applyMarketplaceStatusToRenderer(next);
        renderSettings();
      } catch (e) {
        await appAlert({
          title: "Marketplace error",
          message: String((e as Error).message ?? e),
        });
      }
    });
    row.append(en);

    if (!src.isDefault) {
      const rm = el("button", { class: "danger-btn sm", type: "button" }, ["Remove"]);
      rm.addEventListener("click", async () => {
        const ok = await appConfirm({
          title: "Remove marketplace",
          message: `Remove marketplace “${src.name}”?`,
          okLabel: "Remove",
          danger: true,
        });
        if (!ok) return;
        try {
          const next = await window.apc.marketplace.removeSource(src.id);
          applyMarketplaceStatusToRenderer(next);
          renderSettings();
        } catch (e) {
          await appAlert({
            title: "Marketplace error",
            message: String((e as Error).message ?? e),
          });
        }
      });
      row.append(rm);
    }
    list.append(row);
  }
  sec.append(list);

  // --- Skills (install from marketplace) ---
  const mpSkills = status.catalog.skills ?? [];
  if (mpSkills.length) {
    sec.append(el("div", { class: "settings-subhead", style: "margin-top:18px" }, ["Skills"]));
    const skTable = el("div", { class: "settings-table skills-table" });
    for (const s of mpSkills) {
      const row = el("div", { class: "settings-table-row", style: "align-items:center;gap:10px" });
      const left = el("div", { style: "flex:1;min-width:0" });
      left.append(el("span", {}, [s.name + (s.featured ? " ★" : "")]));
      left.append(el("span", { class: "settings-hint" }, [s.description.slice(0, 80)]));
      row.append(left);
      const already = isMarketplaceSkillInstalled(skillsStore, s.id);
      if (already) {
        row.append(el("span", { class: "pill ok" }, ["Installed"]));
      } else {
        const installBtn = el("button", { class: "ghost-btn sm", type: "button" }, ["Install"]);
        installBtn.addEventListener("click", () => {
          try {
            installMarketplaceSkill(skillsStore as InstallTarget, s);
            showToast(`Installed skill “${s.name}”`);
            renderSettings();
          } catch (e) {
            void appAlert({ title: "Install failed", message: String((e as Error).message ?? e) });
          }
        });
        row.append(installBtn);
      }
      skTable.append(row);
    }
    sec.append(skTable);
  }

  // --- Plugins (install all skills in a plugin) ---
  const mpPlugins = status.catalog.plugins ?? [];
  if (mpPlugins.length) {
    sec.append(el("div", { class: "settings-subhead", style: "margin-top:18px" }, ["Plugins"]));
    const plTable = el("div", { class: "settings-table" });
    for (const p of mpPlugins) {
      const row = el("div", { class: "settings-table-row", style: "align-items:center;gap:10px" });
      const left = el("div", { style: "flex:1;min-width:0" });
      left.append(el("span", {}, [p.name + (p.featured ? " ★" : "")]));
      const { available, missing } = resolvePluginSkills(p, status.catalog);
      const parts = [`${available.length} skill${available.length === 1 ? "" : "s"}`];
      if (missing.length) parts.push(`${missing.length} missing`);
      left.append(el("span", { class: "settings-hint" }, [parts.join(" · ")]));
      if (p.description) {
        left.append(el("span", { class: "settings-hint" }, [p.description.slice(0, 60)]));
      }
      row.append(left);
      if (available.length === 0) {
        row.append(el("span", { class: "pill empty" }, ["No skills"]));
      } else {
        const allInstalled = available.every((s) => isMarketplaceSkillInstalled(skillsStore, s.id));
        if (allInstalled) {
          row.append(el("span", { class: "pill ok" }, ["Installed"]));
        } else {
          const installBtn = el("button", { class: "ghost-btn sm", type: "button" }, ["Install"]);
          installBtn.addEventListener("click", () => {
            const res = installMarketplacePlugin(skillsStore as InstallTarget, p, status.catalog);
            const parts: string[] = [];
            if (res.installed) parts.push(`${res.installed} installed`);
            if (res.skipped) parts.push(`${res.skipped} already installed`);
            if (res.missing) parts.push(`${res.missing} missing`);
            showToast(parts.join(" · ") || "Nothing to install");
            renderSettings();
          });
          row.append(installBtn);
        }
      }
      plTable.append(row);
    }
    sec.append(plTable);
  }

  const actions = el("div", { class: "tunnel-cli-actions", style: "margin-top:14px;justify-content:flex-start" });
  const refresh = el("button", { class: "primary-btn", type: "button" }, ["Refresh all"]);
  refresh.addEventListener("click", async () => {
    refresh.disabled = true;
    refresh.textContent = "Refreshing…";
    try {
      const next = await window.apc.marketplace.refresh();
      applyMarketplaceStatusToRenderer(next);
      renderSettings();
    } catch (e) {
      await appAlert({
        title: "Refresh failed",
        message: String((e as Error).message ?? e),
      });
      refresh.disabled = false;
      refresh.textContent = "Refresh all";
    }
  });
  const add = el("button", { class: "ghost-btn", type: "button" }, ["Add marketplace"]);
  add.addEventListener("click", async () => {
    const values = await appForm({
      title: "Add marketplace",
      message:
        "Raw catalog.json URL, github.com blob/tree link, or owner/repo.",
      fields: [
        {
          name: "url",
          label: "Catalog URL or repo",
          placeholder: "owner/repo or https://…/catalog.json",
          required: true,
        },
        {
          name: "name",
          label: "Display name (optional)",
          placeholder: "My marketplace",
        },
      ],
      okLabel: "Add",
    });
    if (!values) return;
    try {
      const res = await window.apc.marketplace.addSource({
        url: (values.url ?? "").trim(),
        name: (values.name ?? "").trim() || undefined,
      });
      applyMarketplaceStatusToRenderer(res.status);
      renderSettings();
    } catch (e) {
      await appAlert({
        title: "Could not add marketplace",
        message: String((e as Error).message ?? e),
      });
    }
  });
  const docs = el("button", { class: "ghost-btn", type: "button" }, ["How to make one"]);
  docs.addEventListener("click", () => {
    void window.apc.shell.open("https://github.com/roamsocket-ai/roamsocket-marketplace");
  });
  actions.append(refresh, add, docs);
  sec.append(actions);
  panel.append(sec);
}

function fillSettingsConnectors(panel: HTMLElement): void {
  const sec = el("div", { class: "settings-section" });
  sec.append(
    el("p", { class: "settings-hint" }, [
      "Connectors from enabled marketplaces appear in the composer + menu. Wire live MCP servers via APC_MCP_REPO or the phone Connectors manager. Manage catalogs under Settings → Marketplace.",
    ]),
  );

  const catalog = state.marketplace?.catalog.connectors ?? [];
  const popular = el("div", { class: "connector-popular" });
  if (catalog.length === 0) {
    popular.append(
      el("div", { class: "settings-hint" }, [
        "No marketplace connectors loaded yet. Open Marketplace and Refresh.",
      ]),
    );
  } else {
    for (const c of catalog) {
      const card = el("div", { class: "connector-card" });
      card.append(el("span", { class: "connector-name" }, [c.name]));
      const badge = el(
        "span",
        { class: `pill ${c.available === false ? "empty" : "ok"}` },
        [c.available === false ? "soon" : c.category || "available"],
      );
      card.append(badge);
      popular.append(card);
    }
  }
  sec.append(el("div", { class: "settings-subhead" }, ["From marketplace"]));
  sec.append(popular);

  const openMp = el("button", { class: "ghost-btn", type: "button", style: "margin-top:16px" }, [
    "Manage marketplaces",
  ]);
  openMp.addEventListener("click", () => {
    state.settingsTab = "marketplace";
    renderSettings();
  });
  sec.append(openMp);

  const add = el("button", { class: "primary-btn", type: "button", style: "margin-top:12px" }, [
    "Add custom MCP reminder",
  ]);
  add.addEventListener("click", () => {
    void (async () => {
      const values = await appForm({
        title: "Custom MCP reminder",
        message:
          "This only saves a local reminder. Wire live MCP via APC_MCP_REPO or the phone Connectors manager.",
        fields: [
          {
            name: "name",
            label: "Connector name",
            required: true,
          },
          {
            name: "url",
            label: "Remote MCP server URL",
            placeholder: "https://…",
            required: true,
          },
        ],
        okLabel: "Save reminder",
      });
      if (!values) return;
      await appAlert({
        title: "Reminder saved",
        message: `Saved locally as a reminder. Wire MCP servers in desktop env / phone MCP manager:\n${(values.name ?? "").trim()}\n${(values.url ?? "").trim()}`,
      });
    })();
  });
  sec.append(add);
  panel.append(sec);
}

function fillSettingsPlugins(panel: HTMLElement): void {
  const sec = el("div", { class: "settings-section" });
  sec.append(
    el("p", { class: "settings-hint" }, [
      "Plugins are marketplace bundles of skills. Edit catalog.json in a marketplace repo to publish new packs. Browse sources under Settings → Marketplace.",
    ]),
  );
  const plugins = state.marketplace?.catalog.plugins ?? [];
  const table = el("div", { class: "settings-table" });
  table.append(
    el("div", { class: "settings-table-head" }, [
      el("span", {}, ["Plugin"]),
      el("span", {}, ["Skills"]),
      el("span", {}, [""]),
    ]),
  );
  if (plugins.length === 0) {
    table.append(
      el("div", { class: "settings-table-row muted" }, [
        el("span", {}, ["No plugins in merged catalog"]),
        el("span", {}, ["0"]),
        el("span", {}, [""]),
      ]),
    );
  } else {
    for (const p of plugins) {
      const row = el("div", { class: "settings-table-row", style: "align-items:center" });
      row.append(el("span", {}, [p.name + (p.featured ? " ★" : "")]));
      row.append(el("span", {}, [String(p.skillIds?.length ?? 0)]));
      const { available } = resolvePluginSkills(p, state.marketplace?.catalog ?? emptyCatalog());
      if (available.length === 0) {
        row.append(el("span", { class: "pill empty" }, ["—"]));
      } else {
        const allInstalled = available.every((s) => isMarketplaceSkillInstalled(skillsStore, s.id));
        if (allInstalled) {
          row.append(el("span", { class: "pill ok" }, ["Installed"]));
        } else {
          const installBtn = el("button", { class: "ghost-btn sm", type: "button" }, ["Install"]);
          installBtn.addEventListener("click", () => {
            const res = installMarketplacePlugin(
              skillsStore as InstallTarget,
              p,
              state.marketplace?.catalog ?? emptyCatalog(),
            );
            const parts: string[] = [];
            if (res.installed) parts.push(`${res.installed} installed`);
            if (res.skipped) parts.push(`${res.skipped} already installed`);
            showToast(parts.join(" · ") || "Nothing to install");
            renderSettings();
          });
          row.append(installBtn);
        }
      }
      table.append(row);
    }
  }
  sec.append(table);
  const openMp = el("button", { class: "ghost-btn", type: "button", style: "margin-top:14px" }, [
    "Manage marketplaces",
  ]);
  openMp.addEventListener("click", () => {
    state.settingsTab = "marketplace";
    renderSettings();
  });
  sec.append(openMp);
  panel.append(sec);
}

const METAL_INSTALL_LABEL = "Install Python + mlx-lm";
const METAL_REINSTALL_LABEL = "Reinstall Python + mlx-lm";

async function runMetalRuntimeInstall(
  btn: HTMLButtonElement,
  logEl: HTMLPreElement,
  onDone?: () => void,
): Promise<void> {
  btn.disabled = true;
  const prev = btn.textContent || METAL_INSTALL_LABEL;
  btn.textContent = "Installing Python + mlx-lm…";
  logEl.classList.remove("hidden");
  logEl.textContent = "Starting install…\n";

  const unsub = window.apc.on("metal:installLog", (payload: { line: string }) => {
    logEl.textContent += (logEl.textContent ? "\n" : "") + payload.line;
    logEl.scrollTop = logEl.scrollHeight;
  });

  try {
    const result = await window.apc.metal.installRuntime();
    logEl.textContent +=
      "\n" + (result.ok ? `✓ ${result.detail}` : `✗ ${result.error ?? result.detail}`);
    btn.textContent = result.ok ? METAL_REINSTALL_LABEL : prev;
    if (result.ok) {
      btn.classList.remove("primary-btn");
      btn.classList.add("ghost-btn");
    }
  } catch (err) {
    logEl.textContent += `\n✗ ${(err as Error).message ?? err}`;
    btn.textContent = prev;
  } finally {
    unsub();
    btn.disabled = false;
    onDone?.();
  }
}

// ---------------------------------------------------------------------------
// On-device Metal — Manage models (family browser, like iOS)
// ---------------------------------------------------------------------------

type MetalEntry = Awaited<ReturnType<ApcApi["metal"]["catalog"]>>[number];

interface MetalFamilyGroup {
  name: string;
  blurb: string;
  models: MetalEntry[];
  tags: string[];
}

/** In-flight / recent Metal downloads — survives Manage models re-renders. */
interface MetalDownloadTrack {
  hubID: string;
  displayName: string;
  fraction: number;
  status: string;
  error?: string;
  phase: "active" | "done" | "error" | "cancelled";
  updatedAt: number;
  bytesDownloaded?: number;
  bytesTotal?: number;
  startedAt?: number;
}

const metalDownloads = new Map<string, MetalDownloadTrack>();
const metalDownloadControllers = new Map<string, AbortController>();
let metalProgressListening = false;

function ensureMetalProgressListener(): void {
  if (metalProgressListening) return;
  metalProgressListening = true;
  window.apc.on(
    "metal:downloadProgress",
    (p: {
      hubID: string;
      fraction: number;
      status: string;
      file?: string;
      bytesDownloaded?: number;
      bytesTotal?: number;
    }) => {
      const cur = metalDownloads.get(p.hubID);
      if (!cur || cur.phase !== "active") return;
      cur.fraction = Math.max(cur.fraction, Math.min(1, p.fraction || 0));
      cur.status = p.status;
      cur.bytesDownloaded = p.bytesDownloaded ?? cur.bytesDownloaded;
      cur.bytesTotal = p.bytesTotal ?? cur.bytesTotal;
      cur.updatedAt = Date.now();
      paintMetalProgressBanner();
      paintMetalRowProgress(p.hubID);
    },
  );
}

function startMetalDownload(hubID: string, displayName: string): void {
  ensureMetalProgressListener();
  const existing = metalDownloads.get(hubID);
  if (existing?.phase === "active") return;

  const controller = new AbortController();
  metalDownloadControllers.set(hubID, controller);
  metalDownloads.set(hubID, {
    hubID,
    displayName,
    fraction: 0,
    status: "Starting…",
    phase: "active",
    updatedAt: Date.now(),
    startedAt: Date.now(),
  });
  paintMetalProgressBanner();
  paintMetalRowProgress(hubID);

  void window.apc.metal
    .download(hubID)
    .then(() => {
      const cur = metalDownloads.get(hubID);
      if (cur) {
        cur.fraction = 1;
        cur.status = "Ready";
        cur.phase = "done";
        cur.error = undefined;
        cur.updatedAt = Date.now();
      }
      metalDownloadControllers.delete(hubID);
      paintMetalProgressBanner();
      // Refresh catalog so Download → Delete / Use in chat.
      if (parseHash().view === "metal") {
        void renderMetalManage(parseHash().parts);
      }
      // Drop completed rows after a short delay so the banner stays useful.
      setTimeout(() => {
        const t = metalDownloads.get(hubID);
        if (t?.phase === "done") {
          metalDownloads.delete(hubID);
          paintMetalProgressBanner();
        }
      }, 4000);
    })
    .catch((err) => {
      const cur = metalDownloads.get(hubID);
      const message = String((err as Error)?.message ?? err);
      if (cur) {
        cur.phase = controller.signal.aborted || message.includes("cancelled") ? "cancelled" : "error";
        cur.status = cur.phase === "cancelled" ? "Cancelled" : "Failed";
        cur.error = message;
        cur.updatedAt = Date.now();
      }
      metalDownloadControllers.delete(hubID);
      paintMetalProgressBanner();
      paintMetalRowProgress(hubID);
    });
}

function cancelMetalDownload(hubID: string): void {
  const controller = metalDownloadControllers.get(hubID);
  if (controller) {
    controller.abort();
    metalDownloadControllers.delete(hubID);
  }
  void window.apc.metal.cancel(hubID);
  const cur = metalDownloads.get(hubID);
  if (cur && cur.phase === "active") {
    cur.phase = "cancelled";
    cur.status = "Cancelled";
    cur.error = "Download cancelled";
    cur.updatedAt = Date.now();
  }
  paintMetalProgressBanner();
  paintMetalRowProgress(hubID);
}

function activeMetalDownloads(): MetalDownloadTrack[] {
  return [...metalDownloads.values()].sort((a, b) => b.updatedAt - a.updatedAt);
}

/** Estimated seconds remaining for an active download, or null when unknown. */
function metalEtaSeconds(t: MetalDownloadTrack): number | null {
  if (!t.startedAt || !t.bytesDownloaded || t.bytesDownloaded <= 0) return null;
  if (!t.bytesTotal || t.bytesTotal <= t.bytesDownloaded) return null;
  const elapsed = (Date.now() - t.startedAt) / 1000;
  if (elapsed < 1) return null;
  const rate = t.bytesDownloaded / elapsed;
  if (rate <= 0) return null;
  return Math.round((t.bytesTotal - t.bytesDownloaded) / rate);
}

function formatMetalEta(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

/** MB rounded to the nearest tenth (e.g. `456.7 MB`). */
function formatMetalMB(bytes: number): string {
  return `${(Math.max(0, bytes) / 1_048_576).toFixed(1)} MB`;
}

/** Right-edge label for an active download: time remaining + MB to the tenth. */
function metalTrailingLabel(t: MetalDownloadTrack): string {
  const mb = formatMetalMB(t.bytesDownloaded ?? 0);
  const eta = metalEtaSeconds(t);
  return eta == null ? mb : `${formatMetalEta(eta)} · ${mb}`;
}

function paintMetalProgressBanner(): void {
  const host = document.getElementById("metal-progress-banner");
  if (!host) return;
  host.innerHTML = "";
  const tracks = activeMetalDownloads().filter(
    (t) => t.phase === "active" || t.phase === "error" || t.phase === "cancelled" || (t.phase === "done" && Date.now() - t.updatedAt < 5000),
  );
  if (tracks.length === 0) {
    host.classList.add("hidden");
    return;
  }
  host.classList.remove("hidden");
  host.append(el("div", { class: "metal-progress-title" }, ["Downloads"]));
  for (const t of tracks) {
    const row = el("div", { class: `metal-progress-item metal-progress-${t.phase}` });
    const head = el("div", { class: "metal-progress-item-head" });
    head.append(el("span", { class: "metal-progress-name" }, [t.displayName]));
    const pct =
      t.phase === "done" ? "100%" : t.phase === "error" ? "Error" : t.phase === "cancelled" ? "Cancelled" : metalTrailingLabel(t);
    head.append(el("span", { class: "metal-progress-pct" }, [pct]));
    row.append(head);
    const bar = el("div", { class: "metal-progress-bar" });
    const fill = el("div", { class: "metal-progress-fill" });
    fill.style.width = `${Math.round(Math.min(1, Math.max(0, t.fraction)) * 100)}%`;
    bar.append(fill);
    row.append(bar);
    row.append(
      el("div", { class: "metal-progress-status" }, [t.error ? t.error : t.status]),
    );
    if (t.phase === "active") {
      const cancel = el("button", { class: "ghost-btn sm", type: "button" }, ["Cancel"]);
      cancel.addEventListener("click", () => cancelMetalDownload(t.hubID));
      row.append(cancel);
    } else if (t.phase === "error" || t.phase === "cancelled") {
      const retry = el("button", { class: "ghost-btn sm", type: "button" }, ["Retry"]);
      retry.addEventListener("click", () => startMetalDownload(t.hubID, t.displayName));
      row.append(retry);
    }
    host.append(row);
  }
}

function metalProgressAttr(hubID: string): string {
  // Hub ids contain `/` which breaks CSS attribute selectors.
  return hubID.replace(/\//g, "__");
}

function paintMetalRowProgress(hubID: string): void {
  const node = document.querySelector(
    `[data-metal-progress="${metalProgressAttr(hubID)}"]`,
  ) as HTMLElement | null;
  if (!node) return;
  const t = metalDownloads.get(hubID);
  if (!t) {
    node.classList.add("hidden");
    return;
  }
  node.classList.remove("hidden");
  if (t.phase === "error") {
    node.textContent = t.error || "Download failed";
    node.classList.add("metal-row-progress-error");
  } else if (t.phase === "cancelled") {
    node.textContent = "Cancelled";
    node.classList.remove("metal-row-progress-error");
  } else if (t.phase === "done") {
    node.textContent = "Ready";
    node.classList.remove("metal-row-progress-error");
  } else {
    node.textContent = `${t.status} (${metalTrailingLabel(t)})`;
    node.classList.remove("metal-row-progress-error");
  }
}

const FAMILY_BLURBS: Record<string, string> = {
  Llama: "Meta’s Llama instruct models. Strong general chat in compact sizes for on-device Metal.",
  Qwen: "Qwen models from the Qwen team. Strong multilingual chat and instruction following.",
  Gemma: "Google Gemma models — compact chat variants optimized for Metal.",
  LFM: "Liquid AI LFM models. Efficient chat for on-device inference.",
  Phi: "Microsoft Phi instruct models. Compact reasoning and chat for smaller memory budgets.",
  Mistral: "Mistral instruct models. Capable chat; larger variants need more RAM.",
  SmolLM: "Ultra-small instruct models for quick replies and low storage use.",
  Granite: "IBM Granite instruct models for enterprise-style chat on device.",
  DeepSeek: "DeepSeek distill / reasoning models. Some variants emphasize chain-of-thought.",
};

const TAG_LABELS: Record<string, string> = {
  recommended: "Recommended",
  best: "Best",
  thinking: "Thinking",
  vision: "Vision",
  new: "New",
  experimental: "Experimental",
  legacy: "Legacy",
};

function metalFamilyGroups(entries: MetalEntry[]): MetalFamilyGroup[] {
  const by = new Map<string, MetalEntry[]>();
  for (const e of entries) {
    const name = e.family || "Other";
    const list = by.get(name) ?? [];
    list.push(e);
    by.set(name, list);
  }
  return [...by.keys()]
    .sort((a, b) => a.localeCompare(b))
    .map((name) => {
      const models = (by.get(name) ?? []).slice().sort((a, b) =>
        a.displayName.localeCompare(b.displayName),
      );
      const tags = [...new Set(models.flatMap((m) => m.tags))].sort();
      return {
        name,
        blurb: FAMILY_BLURBS[name] ?? "Open MLX models ready for on-device Metal chat.",
        models,
        tags,
      };
    });
}

function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v < 10 && i > 0 ? v.toFixed(2) : v < 100 && i > 0 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

function tagChips(tags: string[]): HTMLElement {
  const row = el("div", { class: "metal-tag-row" });
  for (const t of tags) {
    if (t === "vision") continue; // desktop catalog excludes vision primaries
    row.append(el("span", { class: `metal-tag metal-tag-${t}` }, [TAG_LABELS[t] ?? t]));
  }
  return row;
}

async function renderMetalManage(parts: string[]) {
  setTopbar({ title: "Manage models", crumbs: [{ label: "Settings", href: "#/settings" }] });
  ensureMetalProgressListener();
  const view = $("view-metal");
  view.innerHTML = "";
  const page = el("div", { class: "page metal-page" });

  const sub = parts[1]; // family | legacy | experimental | undefined
  const familyName = sub === "family" ? decodeURIComponent(parts[2] ?? "") : "";

  const back = el("button", { class: "ghost-btn metal-back", type: "button" }, ["← Back"]);
  if (sub) {
    back.addEventListener("click", () => {
      window.location.hash = "#/metal";
    });
  } else {
    back.addEventListener("click", () => {
      window.location.hash = "#/settings";
    });
  }
  page.append(back);

  // Sticky multi-download progress (updated in place while transfers run).
  const progressHost = el("div", {
    id: "metal-progress-banner",
    class: "metal-progress-banner hidden",
  });
  page.append(progressHost);

  try {
    const [status, entries, storage] = await Promise.all([
      window.apc.metal.status(),
      window.apc.metal.catalog(),
      window.apc.metal.storage(),
    ]);

    if (sub === "family" && familyName) {
      page.append(await renderMetalFamilyDetail(familyName, entries, status.runtimeReady));
    } else if (sub === "legacy" || sub === "experimental") {
      page.append(
        await renderMetalBucketDetail(
          sub,
          entries.filter((e) => e.section === sub || e.tags.includes(sub)),
          status.runtimeReady,
        ),
      );
    } else {
      page.append(renderMetalBrowseRoot(entries, status, storage));
    }
  } catch (err) {
    page.append(
      el("div", { class: "notice warn" }, [
        `Could not load Metal models: ${(err as Error).message ?? err}`,
      ]),
    );
  }

  view.append(page);
  paintMetalProgressBanner();
}

function renderMetalBrowseRoot(
  entries: MetalEntry[],
  status: Awaited<ReturnType<ApcApi["metal"]["status"]>>,
  storage: Awaited<ReturnType<ApcApi["metal"]["storage"]>>,
): HTMLElement {
  const root = el("div", { class: "metal-browse" });
  root.append(el("h2", {}, ["Manage models"]));
  root.append(
    el("p", { class: "settings-hint" }, [
      "Run open models on this Mac with Metal (MLX). Download a family, then pick a variant in the chat model pill. Coding sessions can use installed desktop models too.",
    ]),
  );
  root.append(
    el("div", { class: `notice ${status.runtimeReady ? "ok" : "warn"}` }, [status.detail]),
  );

  // One-click Python + mlx-lm
  const runtimeBox = el("div", { class: "settings-section metal-section metal-install-card" });
  runtimeBox.append(el("h3", {}, ["Runtime — Python + mlx-lm"]));
  runtimeBox.append(
    el("p", { class: "settings-hint" }, [
      status.runtimeReady
        ? "Python and mlx-lm are ready. Reinstall if you need a clean environment."
        : "Required before models can run. Installs Python (Homebrew only if missing), a private venv under ~/.roamsocket/metal-runtime, and the mlx-lm package. macOS Apple Silicon recommended.",
    ]),
  );
  const runtimeActions = el("div", {
    class: "tunnel-cli-actions",
    style: "justify-content:flex-start",
  });
  const installBtn = el("button", {
    class: status.runtimeReady ? "ghost-btn" : "primary-btn",
    type: "button",
    id: "btn-install-metal-runtime",
  }, [status.runtimeReady ? METAL_REINSTALL_LABEL : METAL_INSTALL_LABEL]);
  installBtn.title = "Install managed Python + mlx-lm for Metal models";
  const installLog = el("pre", {
    class: "install-log hidden",
    id: "metal-manage-install-log",
  }, [""]);
  installBtn.addEventListener("click", () => {
    void runMetalRuntimeInstall(installBtn, installLog as HTMLPreElement, () => {
      void renderMetalManage(["metal"]);
    });
  });
  runtimeActions.append(installBtn);
  runtimeBox.append(runtimeActions);
  runtimeBox.append(installLog);
  root.append(runtimeBox);

  const downloaded = entries.filter((e) => e.downloaded);
  if (downloaded.length > 0) {
    const onDev = el("div", { class: "settings-section metal-section" });
    onDev.append(el("h3", {}, ["On this device"]));
    for (const e of downloaded) {
      onDev.append(metalVariantRow(e, true));
    }
    root.append(onDev);
  }

  const featured = metalFamilyGroups(
    entries.filter((e) => e.section === "featured" || e.tags.includes("recommended")),
  );
  const featuredNames = new Set(featured.map((f) => f.name));
  const more = metalFamilyGroups(
    entries.filter((e) => e.section === "standard" && !featuredNames.has(e.family)),
  );

  const featuredSec = el("div", { class: "settings-section metal-section" });
  featuredSec.append(el("h3", {}, ["Featured"]));
  if (featured.length === 0) {
    featuredSec.append(el("p", { class: "settings-hint" }, ["No featured families in the catalog."]));
  } else {
    for (const fam of featured) {
      featuredSec.append(metalFamilyCard(fam));
    }
  }
  root.append(featuredSec);

  if (more.length > 0) {
    const moreSec = el("div", { class: "settings-section metal-section" });
    moreSec.append(el("h3", {}, ["More models"]));
    for (const fam of more) {
      moreSec.append(metalFamilyCard(fam));
    }
    root.append(moreSec);
  }

  const buckets = el("div", { class: "settings-section metal-section" });
  buckets.append(metalBucketLink("legacy", "Legacy models", "Older or larger variants that may be limited."));
  buckets.append(
    metalBucketLink(
      "experimental",
      "Experimental models",
      "Tagged experimental variants — may be less stable.",
    ),
  );
  root.append(buckets);

  const storageSec = el("div", { class: "settings-section metal-section" });
  const storRow = el("div", { class: "metal-kv-row" });
  storRow.append(el("span", {}, ["Storage used"]));
  storRow.append(el("span", { class: "metal-kv-value" }, [formatBytes(storage.bytes)]));
  storageSec.append(storRow);

  const dirRow = el("div", { class: "metal-kv-row" });
  dirRow.append(el("span", {}, ["Models directory"]));
  const openDir = el("button", { class: "ghost-btn sm", type: "button" }, ["Open in Finder"]);
  openDir.addEventListener("click", () => void window.apc.metal.openDir());
  dirRow.append(openDir);
  storageSec.append(dirRow);

  const delRow = el("div", { class: "metal-kv-row" });
  delRow.append(el("span", {}, ["Delete all models"]));
  const delAll = el("button", { class: "danger-btn sm", type: "button" }, ["Delete…"]);
  delAll.disabled = storage.count === 0;
  delAll.addEventListener("click", async () => {
    const ok = await appConfirm({
      title: "Delete all models",
      message: `Delete all ${storage.count} on-device Metal model(s)? This cannot be undone.`,
      okLabel: "Delete all",
      danger: true,
    });
    if (!ok) return;
    await window.apc.metal.deleteAll();
    window.location.hash = "#/metal";
    void renderMetalManage(["metal"]);
  });
  delRow.append(delAll);
  storageSec.append(delRow);
  storageSec.append(
    el("p", { class: "settings-hint" }, [
      "On-device models may produce inaccurate responses. Verify critical information. Models are provided via huggingface.co.",
    ]),
  );
  root.append(storageSec);

  return root;
}

function metalFamilyCard(fam: MetalFamilyGroup): HTMLElement {
  const card = el("button", { class: "metal-family-card", type: "button" });
  const head = el("div", { class: "metal-family-head" });
  head.append(el("div", { class: "metal-family-title" }, [fam.name]));
  const right = el("div", { class: "metal-family-meta" });
  if (fam.models.some((m) => m.downloaded)) {
    right.append(el("span", { class: "metal-check", title: "Downloaded" }, ["✓"]));
  }
  right.append(el("span", { class: "metal-chevron" }, [">"]));
  head.append(right);
  card.append(head);
  card.append(el("p", { class: "metal-family-blurb" }, [fam.blurb]));
  const dlCount = fam.models.filter((m) => m.downloaded).length;
  const countLabel =
    dlCount > 0
      ? `${fam.models.length} model${fam.models.length === 1 ? "" : "s"} (${dlCount} downloaded)`
      : `${fam.models.length} model${fam.models.length === 1 ? "" : "s"}`;
  card.append(el("div", { class: "metal-family-count" }, [countLabel]));
  if (fam.tags.length) card.append(tagChips(fam.tags));
  card.addEventListener("click", () => {
    window.location.hash = `#/metal/family/${encodeURIComponent(fam.name)}`;
  });
  return card;
}

function metalBucketLink(id: string, title: string, subtitle: string): HTMLElement {
  const card = el("button", { class: "metal-family-card metal-bucket-card", type: "button" });
  const head = el("div", { class: "metal-family-head" });
  head.append(el("div", { class: "metal-family-title" }, [title]));
  head.append(el("span", { class: "metal-chevron" }, [">"]));
  card.append(head);
  card.append(el("p", { class: "metal-family-blurb" }, [subtitle]));
  card.addEventListener("click", () => {
    window.location.hash = `#/metal/${id}`;
  });
  return card;
}

async function renderMetalFamilyDetail(
  name: string,
  entries: MetalEntry[],
  runtimeReady: boolean,
): Promise<HTMLElement> {
  const models = entries
    .filter((e) => e.family === name)
    .sort((a, b) => a.displayName.localeCompare(b.displayName));
  const root = el("div", { class: "metal-browse" });
  root.append(el("h2", {}, [name]));
  root.append(
    el("p", { class: "settings-hint" }, [
      FAMILY_BLURBS[name] ?? "Open MLX models ready for on-device Metal chat.",
    ]),
  );
  if (!runtimeReady) {
    const warn = el("div", { class: "notice warn metal-runtime-cta" });
    warn.append(
      document.createTextNode(
        "Metal runtime is not ready. You can still download models; install Python + mlx-lm to run them. ",
      ),
    );
    const installInline = el("button", {
      class: "primary-btn sm",
      type: "button",
    }, [METAL_INSTALL_LABEL]);
    const log = el("pre", { class: "install-log hidden" }, [""]);
    installInline.addEventListener("click", () => {
      void runMetalRuntimeInstall(installInline, log, () => {
        void renderMetalManage(["metal", encodeURIComponent(name)]);
      });
    });
    warn.append(installInline);
    root.append(warn);
    root.append(log);
  }
  const sec = el("div", { class: "settings-section metal-section" });
  if (models.length === 0) {
    sec.append(el("p", { class: "settings-hint" }, ["No variants in this family."]));
  } else {
    for (const m of models) {
      sec.append(metalVariantRow(m, false));
    }
  }
  root.append(sec);
  return root;
}

async function renderMetalBucketDetail(
  bucket: string,
  entries: MetalEntry[],
  runtimeReady: boolean,
): Promise<HTMLElement> {
  const title = bucket === "legacy" ? "Legacy models" : "Experimental models";
  const root = el("div", { class: "metal-browse" });
  root.append(el("h2", {}, [title]));
  root.append(
    el("p", { class: "settings-hint" }, [
      bucket === "legacy"
        ? "Older or larger variants that may be limited compared to current models."
        : "Experimental models may be unstable or produce unexpected results.",
    ]),
  );
  if (!runtimeReady) {
    root.append(el("div", { class: "notice warn" }, ["Metal runtime is not ready."]));
  }
  const sec = el("div", { class: "settings-section metal-section" });
  const list = entries.slice().sort((a, b) => a.displayName.localeCompare(b.displayName));
  if (list.length === 0) {
    sec.append(el("p", { class: "settings-hint" }, ["Nothing in this category yet."]));
  } else {
    for (const m of list) {
      sec.append(metalVariantRow(m, true));
    }
  }
  root.append(sec);
  return root;
}

function metalVariantRow(e: MetalEntry, showFamily: boolean): HTMLElement {
  const row = el("div", { class: "metal-variant-row" });
  const left = el("div", { class: "metal-variant-main" });
  left.append(el("div", { class: "metal-variant-title" }, [e.displayName]));
  const subParts = [e.approxSize || "", showFamily ? e.family : "", e.hubID].filter(Boolean);
  left.append(el("div", { class: "settings-hint" }, [subParts.join(" · ")]));
  if (e.blurb) {
    left.append(el("p", { class: "metal-variant-blurb" }, [e.blurb]));
  }
  if (e.tags.length) left.append(tagChips(e.tags));
  const progress = el("div", {
    class: "metal-row-progress hidden",
    "data-metal-progress": metalProgressAttr(e.hubID),
  }, [""]);
  left.append(progress);
  row.append(left);

  const track = metalDownloads.get(e.hubID);
  const actions = el("div", { class: "metal-variant-actions" });
  if (e.downloaded) {
    const use = el("button", { class: "primary-btn sm", type: "button" }, ["Use in chat"]);
    use.addEventListener("click", () => {
      state.provider = "localMetal";
      state.model = e.hubID;
      window.location.hash = "#/chats";
    });
    const del = el("button", { class: "danger-btn sm", type: "button" }, ["Delete"]);
    del.addEventListener("click", async () => {
      const ok = await appConfirm({
        title: "Delete model",
        message: `Delete ${e.displayName} from this Mac?`,
        okLabel: "Delete",
        danger: true,
      });
      if (!ok) return;
      await window.apc.metal.delete(e.hubID);
      applyHashRoute();
    });
    actions.append(use, del);
  } else if (track?.phase === "active") {
    const busy = el("button", { class: "ghost-btn sm", type: "button" }, ["Cancel"]);
    busy.addEventListener("click", () => cancelMetalDownload(e.hubID));
    actions.append(busy);
    paintMetalRowProgress(e.hubID);
  } else if (track?.phase === "error" || track?.phase === "cancelled") {
    const retry = el("button", { class: "primary-btn sm", type: "button" }, ["Retry"]);
    retry.addEventListener("click", () => startMetalDownload(e.hubID, e.displayName));
    actions.append(retry);
    paintMetalRowProgress(e.hubID);
  } else {
    const dl = el("button", { class: "primary-btn sm", type: "button" }, [
      "Download",
    ]);
    dl.addEventListener("click", () => {
      dl.disabled = true;
      dl.textContent = "Downloading…";
      startMetalDownload(e.hubID, e.displayName);
    });
    actions.append(dl);
  }
  row.append(actions);
  return row;
}

async function refreshRemoteAccess(container: HTMLElement): Promise<void> {
  container.innerHTML = "";
  let snapshot: Awaited<ReturnType<ApcApi["tools"]["tunnelCliStatus"]>>;
  try {
    snapshot = await window.apc.tools.tunnelCliStatus();
  } catch (err) {
    container.append(
      el("div", { class: "notice warn" }, [
        `Could not load remote access: ${(err as Error).message ?? err}`,
      ]),
    );
    return;
  }
  const ra = snapshot.remoteAccess;
  const row = el("div", { class: "provider-row" });
  const title = el("div", {});
  title.append(el("div", {}, ["Coding server tunnel"]));
  title.append(
    el("div", { class: "settings-hint" }, [
      ra.serverPort != null
        ? `Local port :${ra.serverPort} · provider ${ra.provider}`
        : "Server port unknown",
    ]),
  );
  row.append(title);
  row.append(el("div", { class: `pill ${ra.enabled ? "ok" : "empty"}` }, [ra.enabled ? "on" : "off"]));
  const actions = el("div", { class: "tunnel-cli-actions" });
  const toggle = el(
    "button",
    { class: ra.enabled ? "danger-btn" : "primary-btn", type: "button" },
    [ra.enabled ? "Turn off" : "Enable remote access"],
  );
  toggle.addEventListener("click", async () => {
    toggle.disabled = true;
    await window.apc.tools.setRemoteAccess({ enabled: !ra.enabled, provider: "auto" });
    await refreshRemoteAccess(container);
  });
  actions.append(toggle);
  row.append(actions);
  container.append(row);
  if (ra.url) {
    container.append(el("div", { class: "settings-hint", style: "margin-top:10px" }, [
      `Phone pair address: ${ra.url}`,
    ]));
    const copy = el("button", { class: "ghost-btn", type: "button" }, ["Copy URL"]);
    copy.addEventListener("click", () => void window.apc.clipboard.write(ra.url));
    container.append(copy);
  }
}

async function refreshTunnelCliRows(listEl: HTMLElement, logEl: HTMLPreElement): Promise<void> {
  listEl.innerHTML = "";
  let snapshot: Awaited<ReturnType<ApcApi["tools"]["tunnelCliStatus"]>>;
  try {
    snapshot = await window.apc.tools.tunnelCliStatus();
  } catch (err) {
    listEl.append(
      el("div", { class: "notice warn" }, [
        `Could not read tunnel CLI status: ${(err as Error).message ?? err}`,
      ]),
    );
    return;
  }
  for (const tool of snapshot.tools) {
    const row = el("div", { class: "provider-row" });
    const title = el("div", {});
    title.append(el("div", {}, [tool.label]));
    title.append(
      el("div", { class: "settings-hint" }, [
        tool.installed ? (tool.version ?? "installed") : "Not installed",
      ]),
    );
    row.append(title);
    row.append(
      el("div", { class: `pill ${tool.installed ? "ok" : "empty"}` }, [
        tool.installed ? "installed" : "missing",
      ]),
    );
    const actions = el("div", { class: "tunnel-cli-actions" });
    const installBtn = el(
      "button",
      { class: tool.installed ? "ghost-btn" : "primary-btn", type: "button" },
      [tool.installed ? "Reinstall" : `Install ${tool.id}`],
    );
    installBtn.addEventListener("click", async () => {
      installBtn.disabled = true;
      logEl.classList.remove("hidden");
      logEl.textContent = "";
      const unsub = window.apc.on("tools:installLog", (payload: { id: string; line: string }) => {
        if (payload.id !== tool.id) return;
        logEl.textContent += (logEl.textContent ? "\n" : "") + payload.line;
      });
      try {
        await window.apc.tools.installTunnelCli(tool.id, { force: tool.installed });
      } finally {
        unsub();
        await refreshTunnelCliRows(listEl, logEl);
      }
    });
    actions.append(installBtn);
    row.append(actions);
    listEl.append(row);
  }
}

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------
async function main() {
  state.bootstrap = await window.apc.bootstrap();
  state.secrets = await window.apc.secrets.get();
  uiPrefs = loadDesktopUiPrefs(window.localStorage);
  state.code.effort = uiPrefs.defaultEffort;

  // Title-bar inset padding (traffic lights) only on macOS hiddenInset chrome.
  document.body.classList.add(`platform-${state.bootstrap.platform}`);

  // Marketplace: apply cached merge into composer menus, then refresh remotes.
  try {
    const cached = await window.apc.marketplace.status();
    applyMarketplaceStatusToRenderer(cached);
  } catch {
    /* ignore */
  }
  void window.apc.marketplace
    .refresh()
    .then((s) => applyMarketplaceStatusToRenderer(s))
    .catch(() => {
      /* offline — keep cache / bundled */
    });

  // Refresh Metal inventory, then restore last model only if still usable
  // (downloaded Metal, cloud key, or configured custom endpoint — never a hard-coded default).
  await refreshMetalDownloadedCache();
  const prefs = state.secrets?.modelPrefs;
  if (prefs) {
    for (const [provider, pref] of Object.entries(prefs)) {
      if (!pref?.model) continue;
      const hasKey =
        provider === "localMetal" ||
        !!state.secrets?.providerKeys[provider]?.present;
      if (
        !isUsableChatSelection(provider, pref.model, {
          hasProviderKey: hasKey,
          metalDownloadedIds: state.metalDownloadedIds,
          customConfigured: isCustomConfigured(provider),
        })
      ) {
        continue;
      }
      state.provider = provider;
      state.model = pref.model;
      state.code.provider = provider;
      state.code.model = pref.model;
      if (pref.effort === "low" || pref.effort === "medium" || pref.effort === "high") {
        state.code.effort = pref.effort;
      }
      break;
    }
  }
  if (state.secrets?.lastRepo) {
    state.code.repo = state.secrets.lastRepo.fullName;
    state.code.baseBranch = state.secrets.lastRepo.baseBranch || "main";
    state.code.workBranch = state.secrets.lastRepo.workBranch || "roamsocket/change";
  }

  $("server-status").textContent = state.bootstrap.serverRunning
    ? `running on :${state.bootstrap.serverPort}`
    : "starting…";
  if (state.bootstrap.pairingCode) {
    $("pairing-code").textContent = state.bootstrap.pairingCode;
  }

  $("copy-code").addEventListener("click", () => {
    if (state.bootstrap?.pairingCode) {
      void window.apc.clipboard.write(state.bootstrap.pairingCode);
    }
  });
  $("btn-new-chat").addEventListener("click", () => {
    // Global New chat: show all recents again, start an unscoped draft.
    state.projectFilter = undefined;
    history.beginNewChat({ provider: state.provider, model: state.model });
    window.location.hash = "#/chats";
    showRoute("chats");
  });
  // Chats nav returns to the global (unscoped) recents list.
  document.querySelector('.nav-item[data-route="chats"]')?.addEventListener("click", () => {
    state.projectFilter = undefined;
  });
  document.querySelector('.nav-item[data-route="code"]')?.addEventListener("click", () => {
    state.codeInSession = false;
  });
  document.querySelector('.nav-item[data-route="projects"]')?.addEventListener("click", () => {
    state.openProjectId = null;
  });
  $("btn-settings").addEventListener("click", () => {
    window.location.hash = "#/settings";
    showRoute("settings");
  });
  $("sidebar-toggle").addEventListener("click", () => {
    $app()?.classList.toggle("sidebar-open");
  });

  window.apc.on("navigate", (path) => {
    const clean = String(path).replace(/^\//, "");
    const dest = clean === "home" || clean === "history" ? "chats" : clean;
    window.location.hash = `#/${isSidebarDestination(dest) ? dest : "chats"}`;
  });
  window.apc.on("pairing:code", (code: string) => {
    if (state.bootstrap) state.bootstrap.pairingCode = code;
    const node = document.getElementById("pairing-code");
    if (node) node.textContent = code;
  });

  // Resume last chat if any
  if (!history.activeChatId) {
    const first = history.listActive()[0];
    if (first) history.setActive(first.id);
  }

  applyHashRoute();

  lightweightPrefs = loadLightweightPrefs(window.localStorage);
  if (!lightweightPrefs.walkthroughCompleted) {
    // Defer so the first route paints under the modal.
    queueMicrotask(() => showWalkthrough());
  }
}

/** First-launch (or replay) walkthrough: product + Lightweight Tasks setup. */
function showWalkthrough(): void {
  const existing = document.getElementById("walkthrough-backdrop");
  if (existing) existing.remove();

  let step = 0;
  const total = 5;
  let draft = { ...loadLightweightPrefs(window.localStorage) };
  if (
    state.bootstrap?.platform === "darwin" &&
    !draft.walkthroughCompleted &&
    draft.mode === "linkedModel" &&
    !draft.linkedProvider
  ) {
    draft.mode = "appleFoundation";
  }

  const backdrop = el("div", { id: "walkthrough-backdrop", class: "walkthrough-backdrop" });
  const modal = el("div", { class: "walkthrough-modal" });
  const progress = el("div", { class: "walkthrough-progress" });
  const fill = el("div", { class: "walkthrough-progress-fill" });
  progress.append(fill);
  const body = el("div", { class: "walkthrough-body" });
  const nav = el("div", { class: "walkthrough-nav" });
  const back = el("button", { class: "ghost-btn", type: "button" }, ["Back"]);
  const next = el("button", { class: "primary-btn", type: "button" }, ["Continue"]);
  nav.append(back, next);
  modal.append(progress, body, nav);
  backdrop.append(modal);
  document.body.append(backdrop);

  const paint = () => {
    fill.style.width = `${((step + 1) / total) * 100}%`;
    back.style.visibility = step === 0 ? "hidden" : "visible";
    next.textContent = step === total - 1 ? "Get started" : "Continue";
    body.innerHTML = "";

    if (step === 0) {
      body.append(el("div", { class: "walkthrough-icon" }, ["✦"]));
      body.append(el("h2", {}, ["Welcome to RoamSocket"]));
      body.append(
        el("p", {}, [
          "Chat with the models you bring. Code pairs this desktop with your phone for real tools, diffs, and pull requests on your machine.",
        ]),
      );
    } else if (step === 1) {
      body.append(el("h2", {}, ["Chat and Code"]));
      body.append(
        el("p", {}, [
          "Chat is BYOK — Anthropic, OpenAI, OpenRouter, and more. Code runs the agent here: clone, edit, shell, and open PRs while you drive from the phone or this window.",
        ]),
      );
    } else if (step === 2) {
      body.append(el("h2", {}, ["Lightweight Tasks"]));
      body.append(
        el("p", {}, [
          "Short jobs — chat titles, artifact names, and similar helpers — use a separate backend so they stay cheap and fast:",
        ]),
      );
      const ul = el("ul", { class: "walkthrough-list" });
      for (const item of [
        "Apple Intelligence on Mac (when available)",
        "Or a linked model you choose (required on Windows)",
      ]) {
        ul.append(el("li", {}, [item]));
      }
      body.append(ul);
    } else if (step === 3) {
      body.append(el("h2", {}, ["Choose a backend"]));
      body.append(
        el("p", { class: "settings-hint" }, [
          "You can change this anytime in Settings → Lightweight Tasks.",
        ]),
      );

      const apple = el("button", {
        class: `walkthrough-choice${draft.mode === "appleFoundation" ? " selected" : ""}`,
        type: "button",
      });
      apple.append(el("strong", {}, ["Apple Intelligence"]));
      apple.append(
        el("span", {}, [
          state.bootstrap?.platform === "darwin"
            ? "On-device system model on this Mac (macOS 26+)."
            : "Only available on Mac — pick Linked model on this PC.",
        ]),
      );
      apple.disabled = state.bootstrap?.platform !== "darwin";
      apple.addEventListener("click", () => {
        draft.mode = "appleFoundation";
        paint();
      });
      body.append(apple);

      const linked = el("button", {
        class: `walkthrough-choice${draft.mode === "linkedModel" ? " selected" : ""}`,
        type: "button",
      });
      linked.append(el("strong", {}, ["Linked model"]));
      linked.append(el("span", {}, ["Any provider + model id with an API key in Providers."]));
      linked.addEventListener("click", () => {
        draft.mode = "linkedModel";
        paint();
      });
      body.append(linked);

      if (draft.mode === "linkedModel") {
        const form = el("div", { class: "walkthrough-form" });
        const prov = el("select") as HTMLSelectElement;
        prov.append(el("option", { value: "" }, ["Provider…"]));
        for (const p of CHAT_PROVIDERS) {
          if (p.id === "localMetal") continue;
          prov.append(el("option", { value: p.id }, [p.label]));
        }
        if (draft.linkedProvider) prov.value = draft.linkedProvider;
        const model = el("input", {
          type: "text",
          placeholder: "Model id (e.g. claude-sonnet-4-20250514)",
          value: draft.linkedModel || "",
        }) as HTMLInputElement;
        prov.addEventListener("change", () => {
          draft.linkedProvider = prov.value || null;
          if (!model.value) model.value = defaultModelFor(prov.value);
          draft.linkedModel = model.value || null;
        });
        model.addEventListener("input", () => {
          draft.linkedModel = model.value.trim() || null;
        });
        form.append(el("label", {}, ["Provider"]), prov, el("label", {}, ["Model"]), model);
        body.append(form);
      }
    } else {
      body.append(el("h2", {}, ["You’re set"]));
      body.append(
        el("p", {}, [
          `Lightweight Tasks → ${lightweightModeLabel(draft.mode)}` +
          (draft.linkedModel ? ` · ${draft.linkedModel}` : "") +
          ". Add API keys under Settings → Providers when you’re ready to chat.",
        ]),
      );
      body.append(
        el("p", { class: "settings-hint" }, [
          "Pair your phone from the sidebar code for Code sessions. Metal models are managed under Settings → Metal models.",
        ]),
      );
    }
  };

  back.addEventListener("click", () => {
    if (step > 0) {
      step -= 1;
      paint();
    }
  });
  next.addEventListener("click", () => {
    if (step < total - 1) {
      step += 1;
      paint();
      return;
    }
    draft.walkthroughCompleted = true;
    lightweightPrefs = draft;
    saveLightweightPrefs(window.localStorage, draft);
    backdrop.remove();
  });

  paint();
}

main().catch((err) => {
  console.error(err);
  document.body.innerHTML = `<pre style="padding:20px;color:#ef6f6c">${String(err)}</pre>`;
});
