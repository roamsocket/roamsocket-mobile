/**
 * Unit checks against shipped desktop client pure modules.
 * Run: npx tsx scripts/client-unit.ts
 */
import assert from "node:assert/strict";
import {
  greetingPhrase,
  allGreetingPhrases,
  greetingPeriodAt,
  THEME,
  CHAT_PROVIDERS,
  SIDEBAR_DESTINATIONS,
  isSidebarDestination,
  HistoryStore,
  memoryStorage,
  autoTitleFromMessages,
  ProjectsStore,
  memoryPlaceholderAt,
  MEMORY_EDIT_PLACEHOLDERS,
  memoryTextFromEditor,
  isMemoryEmptyStateChrome,
  ArtifactsStore,
  CodeSessionsStore,
  relativeTime,
  shouldCaptureAsArtifact,
  titleFromContent,
  parseGitHubPrUrl,
  prStateFromGitHub,
  prChipFromParts,
  prStatePresentation,
  loadDesktopUiPrefs,
  saveDesktopUiPrefs,
  effortExplanation,
  loadComposerTools,
  setWebSearch,
  activateSkill,
  toggleConnector,
  composerToolsSystemHints,
  SKILL_CATALOG,
  CONNECTOR_CATALOG,
  PLUGIN_CATEGORIES,
  DEFAULT_CONNECTOR_CATALOG,
  applyMarketplaceConnectors,
  applyMarketplacePluginCategories,
  SkillsStore,
  skillSlashToken,
  setResearch,
  buildUserContent,
  buildChatSystemContent,
  withSystemTurn,
  projectSystemParts,
  UserMemoryStore,
  MEMORY_IMPORT_PROMPT,
  listCloudModels,
  isUsableChatSelection,
  loadCustomProviders,
  addCustomProvider,
  updateCustomProvider,
  removeCustomProvider,
  customProviderId,
  resolveProviderEndpoint,
  chatRequestTarget,
  mergeProviderCatalog,
  findCustomProvider,
} from "../src/client/index.js";
import { metalInstallPlatformGate } from "../src/metal/install.js";
import {
  listChatMetalCatalog,
  METAL_PROVIDER_ID,
  findMetalEntry,
  familyNameForHub,
  sectionForEntry,
  setRemoteMetalCatalog,
} from "../src/metal/catalog.js";
import {
  parseMarketplaceCatalog,
  mergeMarketplaceCatalogs,
  normalizeMarketplaceUrl,
  metalModelsForPlatform,
  BUNDLED_MARKETPLACE_CATALOG,
} from "../src/marketplace/index.js";
import { getAgentAdapter } from "../src/providers/index.js";

let failed = 0;
function check(name: string, fn: () => void) {
  try {
    fn();
    console.log(`ok  ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`FAIL ${name}: ${(err as Error).message}`);
  }
}

check("theme tokens match mobile cool blue-grey", () => {
  assert.equal(THEME.background.toLowerCase(), "#0b0d10");
  assert.equal(THEME.surface.toLowerCase(), "#14181d");
  assert.equal(THEME.surfaceElevated.toLowerCase(), "#1b2026");
  assert.equal(THEME.accent.toLowerCase(), "#6aa9ff");
});

check("product identity is CodeSocket", async () => {
  const { PRODUCT_NAME, PRODUCT_SLUG, productDataDir } = await import("../src/product.js");
  assert.equal(PRODUCT_NAME, "CodeSocket");
  assert.equal(PRODUCT_SLUG, "codesocket");
  assert.ok(
    productDataDir().includes(".codesocket") || productDataDir().includes(".anyprov-code"),
    "data dir is product or legacy path",
  );
});

check("sidebar destinations include required routes and exclude vision", () => {
  assert.deepEqual([...SIDEBAR_DESTINATIONS], [
    "chats",
    "projects",
    "artifacts",
    "code",
    "settings",
  ]);
  assert.equal(isSidebarDestination("vision"), false);
  assert.equal(isSidebarDestination("chats"), true);
  assert.ok(!(SIDEBAR_DESTINATIONS as readonly string[]).includes("vision"));
});

check("provider list includes anthropic and localMetal", () => {
  const ids = CHAT_PROVIDERS.map((p) => p.id);
  assert.ok(ids.includes("anthropic"));
  assert.ok(ids.includes("openai"));
  assert.ok(ids.includes("localMetal"));
});

check("greeting phrases non-empty and rotate by period", () => {
  const all = allGreetingPhrases();
  assert.ok(all.length >= 20);
  assert.ok(all.every((p) => p.length > 5));
  const morning = greetingPeriodAt(new Date(2026, 0, 1, 10));
  assert.equal(morning, "morning");
  const phrase = greetingPhrase(new Date(2026, 0, 1, 10));
  assert.ok(phrase.length > 0);
  assert.ok(typeof phrase === "string");
});

check("history store round-trip", () => {
  const store = new HistoryStore(memoryStorage());
  const t = store.beginNewChat({ provider: "anthropic", model: "claude-test" });
  assert.equal(t.title, "New chat");
  store.appendMessage(t.id, {
    id: "m1",
    role: "user",
    content: "Fix the login button padding",
    createdAt: Date.now(),
  });
  store.appendMessage(t.id, {
    id: "m2",
    role: "assistant",
    content: "Sure, I'll adjust the padding.",
    createdAt: Date.now(),
  });
  // Re-load from first store's persisted blob
  const raw = (store as any).storage.getItem("apc.chats.v1") as string;
  const reloaded = new HistoryStore(memoryStorage({ "apc.chats.v1": raw }));
  const hit = reloaded.get(t.id);
  assert.ok(hit);
  assert.equal(hit!.messages.length, 2);
  assert.equal(hit!.title, "Fix the login button padding");
  assert.equal(autoTitleFromMessages(hit!.messages), "Fix the login button padding");
});

check("listActive: undefined shows all; projectId scopes; ensureActive keeps project", () => {
  const store = new HistoryStore(memoryStorage());
  const global = store.beginNewChat({ provider: "anthropic", model: "m" });
  store.appendMessage(global.id, {
    id: "g1",
    role: "user",
    content: "global hello",
    createdAt: Date.now(),
  });
  const proj = store.beginNewChat({
    provider: "anthropic",
    model: "m",
    projectId: "proj_abc",
  });
  store.appendMessage(proj.id, {
    id: "p1",
    role: "user",
    content: "project hello",
    createdAt: Date.now(),
  });

  // undefined / omitted → every non-archived chat (including project ones)
  assert.equal(store.listActive().length, 2);
  assert.equal(store.listActive(undefined).length, 2);
  // scoped → only that project
  const scoped = store.listActive("proj_abc");
  assert.equal(scoped.length, 1);
  assert.equal(scoped[0]!.id, proj.id);
  // unknown project → empty, not "unassigned only"
  assert.equal(store.listActive("proj_missing").length, 0);

  // ensureActive with projectId when active is global → new project chat
  store.setActive(global.id);
  const ensured = store.ensureActive({
    provider: "anthropic",
    model: "m",
    projectId: "proj_abc",
  });
  assert.equal(ensured.projectId, "proj_abc");
  assert.notEqual(ensured.id, global.id);

  // ensureActive reuses active project chat when already in that project
  store.setActive(proj.id);
  const again = store.ensureActive({
    provider: "anthropic",
    model: "m",
    projectId: "proj_abc",
  });
  assert.equal(again.id, proj.id);
});

check("projects store create/list/delete", () => {
  const s = new ProjectsStore(memoryStorage());
  const p = s.create("Kind365", "Product work");
  assert.equal(s.list().length, 1);
  assert.equal(s.get(p.id)?.name, "Kind365");
  s.setDescription(p.id, "Updated blurb");
  assert.equal(s.get(p.id)?.description, "Updated blurb");
  s.delete(p.id);
  assert.equal(s.list().length, 0);
});

check("project instructions + memory commands + cycling placeholders", () => {
  const s = new ProjectsStore(memoryStorage());
  const p = s.create("Marketing Class", "Course notes");
  s.setInstructions(p.id, "Think step by step.");
  assert.equal(s.get(p.id)?.instructions, "Think step by step.");
  s.applyMemoryCommand(p.id, "remember that I am the founder of kind365");
  assert.ok(s.get(p.id)?.memory.toLowerCase().includes("kind365"));
  const before = s.get(p.id)!.memory;
  s.applyMemoryCommand(p.id, "forget kind365");
  assert.notEqual(s.get(p.id)!.memory, before);
  assert.ok(memoryPlaceholderAt(0).length > 5);
  assert.ok(MEMORY_EDIT_PLACEHOLDERS.length >= 4);
});

check("memory editor never persists empty-state chrome as project memory", () => {
  // Simulates contenteditable.innerText from empty Manage-memory UI
  const chrome =
    "Purpose & context\nNo project memory yet. Use the box below to add facts, or chat in this project and generate memory later.";
  assert.equal(isMemoryEmptyStateChrome(chrome), true);
  assert.equal(
    memoryTextFromEditor(chrome, { startedEmpty: true, userEdited: false }),
    "",
  );
  // Done without edit → empty store stays empty
  const s = new ProjectsStore(memoryStorage());
  const p = s.create("Empty Memory Proj");
  assert.equal(p.memory, "");
  const toSave = memoryTextFromEditor(chrome, { startedEmpty: true, userEdited: false });
  if (toSave !== (s.get(p.id)?.memory.trim() ?? "")) {
    s.setMemory(p.id, toSave);
  }
  assert.equal(s.get(p.id)?.memory, "");
  // applyCmd path: only remember command, no body chrome write
  s.applyMemoryCommand(p.id, "remember that I prefer concise answers");
  assert.ok(s.get(p.id)?.memory.toLowerCase().includes("concise"));
  assert.ok(!s.get(p.id)?.memory.includes("No project memory yet"));
  // Real edits still persist
  assert.equal(
    memoryTextFromEditor("JC is the founder of kind365", {
      startedEmpty: true,
      userEdited: true,
    }),
    "JC is the founder of kind365",
  );
});

check("project context items add/remove + persist", () => {
  const mem = memoryStorage();
  const s = new ProjectsStore(mem);
  const p = s.create("Marketing Class");
  assert.deepEqual(s.get(p.id)?.contextItems, []);
  const a = s.addContextItem(p.id, {
    kind: "text",
    title: "Prospect Research",
    content: "Target SMB educators.",
  });
  assert.ok(a);
  assert.equal(s.get(p.id)?.contextItems.length, 1);
  assert.equal(s.get(p.id)?.contextItems[0]?.title, "Prospect Research");
  s.addContextItem(p.id, {
    kind: "url",
    title: "docs.example.com",
    content: "Linked resource: https://docs.example.com",
    ref: "https://docs.example.com",
  });
  s.addContextItem(p.id, {
    kind: "file",
    title: "brief.md",
    content: "# Brief\nHello",
    ref: "brief.md",
  });
  assert.equal(s.get(p.id)?.contextItems.length, 3);
  // Newest first
  assert.equal(s.get(p.id)?.contextItems[0]?.title, "brief.md");
  s.removeContextItem(p.id, a!.id);
  assert.equal(s.get(p.id)?.contextItems.length, 2);
  assert.ok(!s.get(p.id)?.contextItems.some((c) => c.id === a!.id));
  // Persist / reload
  const s2 = new ProjectsStore(mem);
  assert.equal(s2.get(p.id)?.contextItems.length, 2);
});

check("code sessions store + relativeTime", () => {
  const store = new CodeSessionsStore(memoryStorage());
  const rec = store.create({
    title: "Fix login padding",
    repo: "acme/app",
    baseBranch: "main",
    workBranch: "fix/login",
    provider: "anthropic",
    model: "claude-sonnet",
  });
  assert.equal(store.list().length, 1);
  store.update(rec.id, { status: "ready_for_review", prUrl: "https://example.com/pr/1" });
  assert.equal(store.get(rec.id)?.prUrl, "https://example.com/pr/1");
  assert.equal(store.get(rec.id)?.status, "ready_for_review");
  const ago = relativeTime(Date.now() - 3_600_000);
  assert.ok(ago.includes("h ago") || ago === "just now" || ago.includes("m"));
});

check("desktop prefs + effort explanations", () => {
  const store = memoryStorage();
  const prefs = loadDesktopUiPrefs(store);
  assert.equal(prefs.memorySearchChats, true);
  prefs.defaultEffort = "low";
  prefs.memoryGenerateFromChats = false;
  saveDesktopUiPrefs(store, prefs);
  const again = loadDesktopUiPrefs(store);
  assert.equal(again.defaultEffort, "low");
  assert.equal(again.memoryGenerateFromChats, false);
  const high = effortExplanation("high");
  assert.ok(high.detail.length > 20);
  assert.equal(high.label, "High");
});

check("user memory store: freeform, detail command, import, system format", () => {
  const mem = memoryStorage();
  const store = new UserMemoryStore(mem);
  assert.equal(store.isEmpty(), true);
  store.addFreeformFact("My dog's name is Beans");
  const profile = store.byCategory("you").find((e) => e.title === "Profile");
  assert.ok(profile);
  assert.ok(profile!.details.some((d) => d.toLowerCase().includes("beans")));
  store.applyEntryCommand(profile!.id, "remember that I live in Colorado");
  assert.ok(
    store.get(profile!.id)!.details.some((d) => d.toLowerCase().includes("colorado")),
  );
  store.applyEntryCommand(profile!.id, "forget Beans");
  assert.ok(
    !store.get(profile!.id)!.details.some((d) => d.toLowerCase().includes("beans")),
  );
  const n = store.importFromText(`## Topics
### Gaming
Gaming interests and identity
- Plays indie games
- Prefers co-op

## Areas
### Kind365
kind365 app and foundation
- Free open-source kindness app
`);
  assert.ok(n >= 2);
  assert.ok(store.byCategory("topic").some((e) => e.title === "Gaming"));
  assert.ok(store.byCategory("area").some((e) => e.title === "Kind365"));
  const sys = store.formatForSystem();
  assert.ok(sys.includes("## Topics"));
  assert.ok(sys.includes("Kind365"));
  assert.ok(MEMORY_IMPORT_PROMPT.includes("Export all of my stored memories"));
  // Persist / reload
  const again = new UserMemoryStore(mem);
  assert.ok(again.list().length >= 2);
  again.delete(profile!.id);
  assert.ok(!again.get(profile!.id));
});

check("buildChatSystemContent injects user memory", () => {
  const system = buildChatSystemContent({
    tools: loadComposerTools(memoryStorage()),
    project: null,
    includeMemory: true,
    userMemorySystem: "## You\n### Profile\nName: JC",
  });
  assert.ok(system.includes("User memory"));
  assert.ok(system.includes("Name: JC"));
});

check("composer tools: web search, skills, connectors", () => {
  const store = memoryStorage();
  let tools = loadComposerTools(store);
  assert.equal(tools.webSearch, true);
  tools = setWebSearch(store, tools, false);
  assert.equal(loadComposerTools(store).webSearch, false);
  tools = setResearch(store, tools, true);
  assert.equal(loadComposerTools(store).research, true);
  assert.ok(SKILL_CATALOG.length >= 5);
  tools = activateSkill(store, tools, SKILL_CATALOG[0]!.id);
  assert.ok(tools.activeSkillIds.includes(SKILL_CATALOG[0]!.id));
  const conn = CONNECTOR_CATALOG[0]!;
  tools = toggleConnector(store, tools, conn.id);
  assert.equal(typeof tools.connectors[conn.id], "boolean");
  const hints = composerToolsSystemHints({
    ...tools,
    webSearch: true,
    research: true,
    activeSkillIds: [SKILL_CATALOG[0]!.id],
  });
  assert.ok(hints.some((h) => /web search/i.test(h)));
  assert.ok(hints.some((h) => /research/i.test(h)));
  assert.ok(hints.some((h) => h.includes(SKILL_CATALOG[0]!.name)));
});

check("skills store: list, edit, slash token, uninstall", () => {
  const store = memoryStorage();
  const skills = new SkillsStore(store);
  assert.ok(skills.list().length >= 5);
  const mcp = skills.get("mcp-builder");
  assert.ok(mcp);
  assert.equal(skillSlashToken(mcp!), "/mcp-builder");
  assert.ok(mcp!.instructions.toLowerCase().includes("mcp"));
  skills.update("mcp-builder", { description: "Updated MCP guide" });
  assert.equal(skills.get("mcp-builder")?.description, "Updated MCP guide");
  const custom = skills.create({
    name: "my-helper",
    description: "Help me",
    instructions: "# My helper\nDo the thing.",
  });
  assert.ok(skills.get(custom.id));
  skills.uninstall("my-helper");
  assert.equal(skills.get("my-helper"), undefined);
  skills.uninstall("mcp-builder");
  assert.equal(skills.get("mcp-builder"), undefined);
  assert.ok(skills.list().every((s) => s.id !== "mcp-builder"));
});

check("chat-turn: attachments + project + skills system content (shipped path)", () => {
  const mem = memoryStorage();
  const projects = new ProjectsStore(mem);
  const skills = new SkillsStore(mem);
  let tools = loadComposerTools(mem);

  const p = projects.create("Marketing Class");
  projects.setInstructions(p.id, "Be concise for coursework.");
  projects.applyMemoryCommand(p.id, "remember that I am JC the founder of kind365");
  projects.addContextItem(p.id, {
    kind: "text",
    title: "Prospect Research",
    content: "Target educators and workplaces.",
  });
  projects.addContextItem(p.id, {
    kind: "file",
    title: "brief.md",
    content: "# Brief\nLaunch plan",
  });

  const skill = skills.get("mcp-builder");
  assert.ok(skill);
  tools = activateSkill(mem, tools, skill!.id);
  tools = setWebSearch(mem, tools, true);
  tools = setResearch(mem, tools, true);

  const user = buildUserContent("Help me plan", [
    { name: "notes.txt", content: "Week 3 notes" },
  ]);
  assert.ok(user.includes("Help me plan"));
  assert.ok(user.includes("Attachment: notes.txt"));
  assert.ok(user.includes("Week 3 notes"));

  const proj = projects.get(p.id)!;
  const projParts = projectSystemParts(proj, { includeMemory: true });
  assert.ok(projParts.some((x) => x.includes("Be concise")));
  assert.ok(projParts.some((x) => /kind365/i.test(x)));
  assert.ok(projParts.some((x) => x.includes("Prospect Research")));

  const system = buildChatSystemContent({
    tools,
    project: proj,
    includeMemory: true,
    resolveSkill: (id) => skills.get(id),
  });
  assert.ok(/web search/i.test(system));
  assert.ok(/research mode/i.test(system));
  assert.ok(system.includes("/mcp-builder") || system.includes("mcp-builder"));
  assert.ok(system.toLowerCase().includes("mcp") || system.includes("Model Context"));
  assert.ok(system.includes("Be concise for coursework"));
  assert.ok(system.includes("Prospect Research"));

  const turns = withSystemTurn(
    [{ role: "user", content: user }],
    system,
  );
  assert.equal(turns[0]!.role, "system");
  assert.equal(turns[1]!.role, "user");
  assert.ok(turns[0]!.content.includes("Project instructions"));
});

check("metalInstallPlatformGate blocks non-darwin", () => {
  const linux = metalInstallPlatformGate("linux");
  assert.ok(linux);
  assert.equal(linux!.ok, false);
  assert.equal(linux!.error, "unsupported platform");
  assert.ok(/macOS/i.test(linux!.detail));
  const darwin = metalInstallPlatformGate("darwin");
  assert.equal(darwin, null);
});

check("GitHub PR parse + state presentation", () => {
  const p = parseGitHubPrUrl("https://github.com/kind365/app/pull/225");
  assert.ok(p);
  assert.equal(p!.owner, "kind365");
  assert.equal(p!.repo, "app");
  assert.equal(p!.number, 225);
  assert.equal(prStateFromGitHub({ state: "open", draft: true }), "draft");
  assert.equal(prStateFromGitHub({ state: "closed", merged: true }), "merged");
  assert.equal(prStateFromGitHub({ state: "closed", merged: false }), "closed");
  assert.equal(prStateFromGitHub({ state: "open" }), "open");
  const merged = prChipFromParts({
    url: "https://github.com/kind365/app/pull/225",
    state: "merged",
    branch: "claude/walkthrough-kids-spouse-steps-pa61mm",
  });
  assert.equal(merged.toneClass, "pr-merged");
  assert.equal(merged.stateLabel, "Merged");
  assert.equal(merged.number, 225);
  assert.equal(merged.repoLabel, "app");
  assert.equal(prStatePresentation("open").toneClass, "pr-open");
  assert.equal(prStatePresentation("closed").toneClass, "pr-closed");
});

check("artifacts capture heuristic + store", () => {
  assert.equal(shouldCaptureAsArtifact("short"), false);
  assert.equal(shouldCaptureAsArtifact("```ts\nconst x = 1\n```"), true);
  const long = Array.from({ length: 12 }, (_, i) => `line ${i}`).join("\n");
  assert.equal(shouldCaptureAsArtifact(long), true);
  const store = new ArtifactsStore(memoryStorage());
  const art = store.add(long, { sourceChatId: "c1" });
  assert.ok(art);
  assert.equal(store.list().length, 1);
  assert.ok(titleFromContent(long).length > 0);
});

check("metal catalog families group without vision primaries", () => {
  const cat = listChatMetalCatalog();
  assert.ok(cat.length >= 5);
  assert.equal(METAL_PROVIDER_ID, "localMetal");
  for (const e of cat) {
    assert.equal(e.chatOnly, true);
    assert.ok(!e.tags.includes("vision"), `unexpected vision tag on ${e.hubID}`);
    assert.ok(familyNameForHub(e.hubID).length > 0);
    assert.ok(["featured", "standard", "experimental", "legacy"].includes(sectionForEntry(e)));
  }
  assert.equal(familyNameForHub("lmstudio-community/Qwen3-1.7B-MLX-4bit"), "Qwen");
  assert.equal(familyNameForHub("lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit"), "LFM");
  assert.ok(findMetalEntry(cat[0]!.hubID));
});

check("isUsableChatSelection rejects empty and uninstalled Metal", () => {
  assert.equal(
    isUsableChatSelection("", "", { hasProviderKey: false }),
    false,
  );
  assert.equal(
    isUsableChatSelection("anthropic", "claude-sonnet-4", { hasProviderKey: false }),
    false,
  );
  assert.equal(
    isUsableChatSelection("anthropic", "claude-sonnet-4", { hasProviderKey: true }),
    true,
  );
  assert.equal(
    isUsableChatSelection("localMetal", "lmstudio-community/foo", {
      hasProviderKey: true,
      metalDownloadedIds: [],
    }),
    false,
  );
  assert.equal(
    isUsableChatSelection("localMetal", "lmstudio-community/foo", {
      hasProviderKey: true,
      metalDownloadedIds: ["lmstudio-community/foo"],
    }),
    true,
  );
  // Custom providers: usable when configured even without a key
  assert.equal(
    isUsableChatSelection("custom:ollama", "llama3.2", {
      hasProviderKey: false,
      customConfigured: true,
    }),
    true,
  );
  assert.equal(
    isUsableChatSelection("custom:ollama", "llama3.2", {
      hasProviderKey: false,
      customConfigured: false,
    }),
    false,
  );
});

check("custom providers: create / update / delete + load/save", () => {
  const store = memoryStorage();
  assert.deepEqual(loadCustomProviders(store), []);

  const created = addCustomProvider(store, {
    label: "Ollama",
    baseUrl: "http://localhost:11434/v1",
    apiStyle: "openai",
    defaultModel: "llama3.2",
  });
  assert.ok(created);
  assert.equal(created!.id, "ollama");
  assert.equal(created!.baseUrl, "http://localhost:11434/v1");
  assert.equal(created!.apiStyle, "openai");
  assert.equal(customProviderId(created!.id), "custom:ollama");

  const listed = loadCustomProviders(store);
  assert.equal(listed.length, 1);
  assert.equal(listed[0]!.label, "Ollama");

  // Persist round-trip
  const again = loadCustomProviders(store);
  assert.equal(again[0]!.baseUrl, "http://localhost:11434/v1");

  const updated = updateCustomProvider(store, "ollama", {
    label: "Local Ollama",
    baseUrl: "http://127.0.0.1:11434/v1/",
    apiStyle: "openai",
    defaultModel: "qwen2.5",
  });
  assert.ok(updated);
  assert.equal(updated!.label, "Local Ollama");
  assert.equal(updated!.baseUrl, "http://127.0.0.1:11434/v1");
  assert.equal(updated!.defaultModel, "qwen2.5");

  const anth = addCustomProvider(store, {
    label: "Anthropic Proxy",
    baseUrl: "https://proxy.example.com/v1",
    apiStyle: "anthropic",
    id: "anth-proxy",
  });
  assert.ok(anth);
  assert.equal(anth!.apiStyle, "anthropic");
  assert.equal(loadCustomProviders(store).length, 2);

  assert.equal(findCustomProvider(store, "custom:ollama")?.label, "Local Ollama");
  assert.equal(removeCustomProvider(store, "ollama"), true);
  assert.equal(findCustomProvider(store, "ollama"), undefined);
  assert.equal(loadCustomProviders(store).length, 1);

  // Invalid URL rejected
  assert.equal(
    addCustomProvider(store, { label: "Bad", baseUrl: "not-a-url" }),
    null,
  );
});

check("resolveProviderEndpoint + chatRequestTarget use custom base URL", () => {
  const customs = [
    {
      id: "ollama",
      label: "Ollama",
      baseUrl: "http://localhost:11434/v1",
      apiStyle: "openai" as const,
    },
    {
      id: "anth-proxy",
      label: "Proxy",
      baseUrl: "https://proxy.example.com/anthropic/v1",
      apiStyle: "anthropic" as const,
    },
  ];

  const ollama = resolveProviderEndpoint("custom:ollama", customs);
  assert.ok(ollama);
  assert.equal(ollama!.baseUrl, "http://localhost:11434/v1");
  assert.equal(ollama!.apiStyle, "openai");

  const target = chatRequestTarget("custom:ollama", ollama);
  assert.equal(target.style, "openai");
  if (target.style === "openai") {
    assert.equal(target.url, "http://localhost:11434/v1/chat/completions");
    assert.ok(!target.url.includes("api.openai.com"), "must not use built-in OpenAI host");
  }

  const anthEp = resolveProviderEndpoint("custom:anth-proxy", customs);
  assert.ok(anthEp);
  const anthTarget = chatRequestTarget("custom:anth-proxy", anthEp);
  assert.equal(anthTarget.style, "anthropic");
  if (anthTarget.style === "anthropic") {
    assert.equal(anthTarget.url, "https://proxy.example.com/anthropic/v1/messages");
    assert.ok(!anthTarget.url.includes("api.anthropic.com"));
  }

  // Missing custom config → error style, not silent OpenAI fallback
  const missing = chatRequestTarget("custom:missing", null);
  assert.equal(missing.style, "error");

  // Built-in anthropic without override
  const builtIn = chatRequestTarget("anthropic", null);
  assert.equal(builtIn.style, "anthropic");
  if (builtIn.style === "anthropic") {
    assert.ok(builtIn.url.includes("api.anthropic.com"));
  }

  // Explicit override wins over catalog
  const override = resolveProviderEndpoint("openai", [], {
    baseUrl: "http://proxy.local/v1",
    apiStyle: "openai",
  });
  assert.equal(override?.baseUrl, "http://proxy.local/v1");
  const overrideTarget = chatRequestTarget("openai", override);
  assert.equal(overrideTarget.style, "openai");
  if (overrideTarget.style === "openai") {
    assert.equal(overrideTarget.url, "http://proxy.local/v1/chat/completions");
  }
});

check("mergeProviderCatalog includes custom:<slug> rows", () => {
  const merged = mergeProviderCatalog([
    { id: "ollama", label: "Ollama", defaultModel: "llama3.2" },
  ]);
  assert.ok(merged.some((p) => p.id === "anthropic"));
  const custom = merged.find((p) => p.id === "custom:ollama");
  assert.ok(custom);
  assert.equal(custom!.label, "Ollama");
  assert.equal(custom!.defaultModel, "llama3.2");
});

check("getAgentAdapter custom: with baseUrl does not throw needs baseUrl", () => {
  // Without baseUrl → clear error (shipped path)
  assert.throws(
    () => getAgentAdapter("custom:ollama"),
    /needs a baseUrl/,
  );
  // With baseUrl + openai style → adapter that hits override host
  const openaiAdapter = getAgentAdapter("custom:ollama", {
    baseUrl: "http://localhost:11434/v1",
    apiStyle: "openai",
  });
  assert.equal(openaiAdapter.id, "custom:ollama");
  // With anthropic style
  const anthAdapter = getAgentAdapter("custom:proxy", {
    baseUrl: "https://proxy.example.com/v1",
    apiStyle: "anthropic",
  });
  assert.equal(anthAdapter.id, "custom:proxy");
});

check("marketplace: parse, merge, URL normalize, platform filter", () => {
  const raw = {
    schemaVersion: 1,
    name: "Test MP",
    connectors: [{ id: "notion", name: "Notion", available: true }],
    skills: [{ id: "s1", name: "s1", description: "d" }],
    plugins: [{ id: "p1", name: "P1", skillIds: ["s1"] }],
    pluginCategories: [{ id: "engineering", label: "Engineering" }],
    metalModels: [
      {
        hubID: "org/phone-only-MLX-4bit",
        displayName: "Phone",
        tags: ["recommended"],
        platforms: ["ios"],
      },
      {
        hubID: "org/desk-MLX-4bit",
        displayName: "Desk",
        tags: ["recommended"],
        platforms: ["desktop"],
      },
    ],
  };
  const cat = parseMarketplaceCatalog(raw);
  assert.ok(cat);
  assert.equal(cat!.connectors[0]!.id, "notion");
  assert.equal(metalModelsForPlatform(cat!, "ios").length, 1);
  assert.equal(metalModelsForPlatform(cat!, "desktop").length, 1);

  const merged = mergeMarketplaceCatalogs([BUNDLED_MARKETPLACE_CATALOG, cat!]);
  assert.ok(merged.connectors.some((c) => c.id === "notion"));
  assert.ok(merged.connectors.some((c) => c.id === "gmail"));

  assert.ok(
    normalizeMarketplaceUrl("kind365/my-mp").includes(
      "raw.githubusercontent.com/kind365/my-mp/main/catalog.json",
    ),
  );
  assert.ok(
    normalizeMarketplaceUrl(
      "https://github.com/o/r/blob/main/marketplace/catalog.json",
    ).includes("raw.githubusercontent.com/o/r/main/marketplace/catalog.json"),
  );
});

check("marketplace apply updates connector + metal catalogs", () => {
  applyMarketplaceConnectors([
    { id: "notion", name: "Notion" },
    { id: "gmail", name: "Gmail" },
  ]);
  assert.ok(CONNECTOR_CATALOG.some((c) => c.id === "notion"));
  applyMarketplacePluginCategories([{ id: "research", label: "Research" }]);
  assert.ok(PLUGIN_CATEGORIES.some((c) => c.id === "research"));
  // Restore defaults so later checks stay stable.
  applyMarketplaceConnectors([...DEFAULT_CONNECTOR_CATALOG]);

  setRemoteMetalCatalog([
    {
      hubID: "test/remote-MLX-4bit",
      displayName: "Remote Test",
      approxSize: "~1 GB",
      blurb: "from marketplace",
      tags: ["recommended"],
      chatOnly: true,
    },
  ]);
  assert.ok(listChatMetalCatalog().some((e) => e.hubID === "test/remote-MLX-4bit"));
  setRemoteMetalCatalog(null);
  assert.ok(!listChatMetalCatalog().some((e) => e.hubID === "test/remote-MLX-4bit"));
});

async function runAsyncChecks() {
  try {
    const none = await listCloudModels("anthropic", "");
    assert.deepEqual(none, []);
    const metal = await listCloudModels("localMetal", "x");
    assert.deepEqual(metal, []);

    const mockFetch = async (url: string) => {
      if (url.includes("api.anthropic.com")) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            data: [
              { id: "claude-sonnet-4-20250514", display_name: "Claude Sonnet 4" },
              { id: "claude-opus-4", display_name: "Claude Opus 4" },
            ],
          }),
        };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };
    const listed = await listCloudModels("anthropic", "sk-test", mockFetch);
    assert.equal(listed.length, 2);
    assert.equal(listed[0]!.id, "claude-sonnet-4-20250514");
    // Must not inject CHAT_PROVIDERS defaultModel unless the API returned it.
    assert.ok(listed.every((m) => typeof m.id === "string" && m.id.length > 0));
    const defaults = CHAT_PROVIDERS.map((p) => p.defaultModel).filter(Boolean);
    // A listing with only API rows is fine even if one matches a default —
    // the point is we never inject defaults without an API response.
    assert.ok(listed.length === 2);
    void defaults;
    console.log("ok  listCloudModels empty key + mock API (no fake defaults)");
  } catch (err) {
    failed += 1;
    console.error(
      `FAIL listCloudModels: ${(err as Error).message}`,
    );
  }

  // Custom base URL listing must hit the override host, not api.openai.com
  try {
    const seen: string[] = [];
    const mockCustom = async (url: string) => {
      seen.push(url);
      if (url.startsWith("http://localhost:11434/v1/models")) {
        return {
          ok: true,
          status: 200,
          json: async () => ({ data: [{ id: "llama3.2" }, { id: "qwen2.5" }] }),
        };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };
    const customListed = await listCloudModels("custom:ollama", "", {
      baseUrl: "http://localhost:11434/v1",
      apiStyle: "openai",
      fetchImpl: mockCustom,
    });
    assert.equal(customListed.length, 2);
    assert.equal(customListed[0]!.id, "llama3.2");
    assert.ok(seen.some((u) => u.includes("localhost:11434")));
    assert.ok(!seen.some((u) => u.includes("api.openai.com")));
    console.log("ok  listCloudModels custom baseUrl hits override host");
  } catch (err) {
    failed += 1;
    console.error(`FAIL listCloudModels custom baseUrl: ${(err as Error).message}`);
  }

  // Agent adapter with custom baseUrl must call that host (not cloud defaults)
  try {
    const seen: string[] = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input: string | URL | { url: string }, _init?: RequestInit) => {
      const url =
        typeof input === "string"
          ? input
          : input instanceof URL
            ? input.href
            : String((input as { url: string }).url);
      seen.push(url);
      return new Response(
        JSON.stringify({
          choices: [{ message: { content: "hi from custom", tool_calls: [] } }],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }) as typeof fetch;

    try {
      const adapter = getAgentAdapter("custom:ollama", {
        baseUrl: "http://127.0.0.1:9999/v1",
        apiStyle: "openai",
      });
      const events = [];
      for await (const ev of adapter.stream({
        model: "llama3.2",
        apiKey: "none",
        effort: "low",
        system: "test",
        messages: [{ role: "user", text: "hello" }],
        tools: [],
      })) {
        events.push(ev);
      }
      assert.ok(seen.some((u) => u.startsWith("http://127.0.0.1:9999/v1/chat/completions")));
      assert.ok(!seen.some((u) => u.includes("api.openai.com")));
      assert.ok(events.some((e) => e.kind === "text" && e.text.includes("hi from custom")));
      console.log("ok  getAgentAdapter custom baseUrl streams to override host");
    } finally {
      globalThis.fetch = originalFetch;
    }
  } catch (err) {
    failed += 1;
    console.error(`FAIL getAgentAdapter custom fetch: ${(err as Error).message}`);
  }
}

await runAsyncChecks();

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nall client unit checks passed");
