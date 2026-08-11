/**
 * Structural check: renderer source exposes destinations and theme tokens.
 * Does not require Electron.
 */
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const html = readFileSync(path.join(root, "src/renderer/index.html"), "utf8");
const css = readFileSync(path.join(root, "src/renderer/styles.css"), "utf8");
const main = readFileSync(path.join(root, "src/renderer/main.ts"), "utf8");

assert.ok(html.includes('data-route="chats"'), "chats nav");
assert.ok(html.includes('data-route="projects"'), "projects nav");
assert.ok(html.includes('data-route="artifacts"'), "artifacts nav");
assert.ok(html.includes('data-route="code"'), "code nav");
assert.ok(html.includes("btn-settings"), "settings entry");
assert.ok(!html.includes('data-route="vision"'), "vision must not be primary nav");
assert.ok(!main.includes('route === "vision"'), "no vision route handler");

assert.ok(/--bg:\s*#0b0d10/i.test(css), "bg token");
assert.ok(/--bg-elev:\s*#14181d/i.test(css), "surface token");
assert.ok(/--bg-elev-2:\s*#1b2026/i.test(css), "elevated token");
assert.ok(/--accent:\s*#6aa9ff/i.test(css), "accent token");

assert.ok(main.includes("greetingPhrase"), "chat greeting");
assert.ok(main.includes("HistoryStore"), "history");
assert.ok(main.includes("ProjectsStore"), "projects");
assert.ok(main.includes("ArtifactsStore"), "artifacts");
assert.ok(main.includes("create_session"), "code session protocol");
assert.ok(main.includes("metal"), "metal settings wiring");
assert.ok(main.includes("lightweight") || main.includes("Lightweight"), "lightweight tasks");
assert.ok(main.includes("showWalkthrough"), "first-launch walkthrough");
assert.ok(main.includes("populateModelPickerList") || main.includes("listCloudModels"), "honest model picker");
assert.ok(main.includes("hasUsableChatModel") || main.includes("isUsableChatSelection"), "usable model gate");
assert.ok(!/state\.model = p\.defaultModel/.test(main), "picker must not force static defaultModel");
assert.ok(main.includes("Download a model") || main.includes("+ Add a model"), "empty picker CTA");
// Empty pill must still open the model picker (CTAs live there). Must not be
// the only path: exclusive hard-route to settings when !usable.
assert.ok(
  /addEventListener\("click",\s*\(\)\s*=>\s*openModelPicker\(\)\)/.test(main),
  "pill click always opens openModelPicker",
);
// Forbid the prior bug: empty branch that only navigates to settings.
assert.ok(
  !/if\s*\(\s*usable\s*\)\s*openModelPicker\(\)\s*;\s*else\s*\{[^}]*settingsTab\s*=\s*"providers"/.test(main),
  "empty pill must not exclusively hard-route to settings",
);
assert.ok(html.includes("view-metal"), "metal manage view");
assert.ok(main.includes("renderMetalManage"), "metal manage renderer");
assert.ok(main.includes("metal-family-card") || main.includes("metalFamilyCard"), "family cards");
assert.ok(css.includes("metal-family-card"), "metal family styles");
assert.ok(
  main.includes("Install Python + mlx-lm") || main.includes("METAL_INSTALL_LABEL"),
  "install Python + mlx-lm button",
);
assert.ok(main.includes("installRuntime") || main.includes("runMetalRuntimeInstall"), "runtime install wiring");

assert.ok(existsSync(path.join(root, "src/metal/runtime.ts")));
assert.ok(existsSync(path.join(root, "src/client/greeting.ts")));

// Project rail: Context + dropdown (Claude project-home parity)
const projectModals = readFileSync(path.join(root, "src/renderer/project-modals.ts"), "utf8");
assert.ok(main.includes("openContextAddMenu"), "context + menu wiring");
assert.ok(main.includes("contextItems") || main.includes("addContextItem"), "context items store use");
assert.ok(projectModals.includes("Upload from device"), "upload menu item");
assert.ok(projectModals.includes("Add text content"), "add text menu item");
assert.ok(projectModals.includes("Search resources or paste URL"), "connector flyout search");
assert.ok(projectModals.includes("GitHub") && projectModals.includes("Figma"), "connector list");
assert.ok(projectModals.includes("GoDaddy") && projectModals.includes("Drive"), "connector list 2");
assert.ok(css.includes("context-add-menu"), "context menu styles");
assert.ok(css.includes("context-submenu"), "resource flyout styles");

// Chat composer + menu (Claude attach bar)
const composerMenu = readFileSync(path.join(root, "src/renderer/composer-menu.ts"), "utf8");
assert.ok(main.includes("openComposerPlusMenu"), "composer + menu wiring");
assert.ok(composerMenu.includes("Add files or photos"), "add files item");
assert.ok(composerMenu.includes("Add to project"), "add to project");
assert.ok(composerMenu.includes("Add from GitHub"), "add from github");
assert.ok(composerMenu.includes("Skills") && composerMenu.includes("Connectors"), "skills/connectors");
assert.ok(composerMenu.includes("Plugins") && composerMenu.includes("Research"), "plugins/research");
assert.ok(composerMenu.includes("Web search"), "web search toggle");
assert.ok(css.includes("composer-plus-menu"), "composer menu styles");
assert.ok(css.includes("cmi-switch"), "connector toggle styles");

console.log("client shell structural checks passed");
console.log("routes: chats, projects, artifacts, code, settings, metal");
console.log("theme: #0B0D10 / #14181D / #1B2026 / #6AA9FF");
console.log("vision: absent from primary nav");
console.log("project context: + menu (upload / text / connectors + search)");
console.log("composer +: files / project / github / skills / connectors / plugins / research / web");

// Skills slash chips + detail UI
const skillUi = readFileSync(path.join(root, "src/renderer/skill-ui.ts"), "utf8");
assert.ok(skillUi.includes("skill-slash-chip") || skillUi.includes("buildSkillSlashChip"), "slash chip");
assert.ok(skillUi.includes("openSkillDetailModal"), "skill detail");
assert.ok(skillUi.includes("openEditSkillModal"), "edit skill");
assert.ok(skillUi.includes("Try in chat") || skillUi.includes("Uninstall"), "overflow actions");
assert.ok(main.includes("buildSkillSlashChip"), "composer skill chips");
assert.ok(main.includes("SkillsStore"), "skills store wired");
assert.ok(css.includes("skill-slash-chip"), "skill chip styles");
assert.ok(css.includes("skill-detail-modal") || css.includes("skill-detail"), "skill detail styles");
console.log("skills: slash chips, hover preview, detail/edit modals");

// /goal slash command (coding session)
assert.ok(main.includes("goal_status") || main.includes("paintGoalBanner"), "goal status handler");
assert.ok(main.includes("paintGoalBanner") || main.includes("code-goal-bar"), "goal banner");
assert.ok(main.includes("CODE_SLASH_COMMANDS") || main.includes("/goal"), "slash menu commands");
assert.ok(css.includes("code-goal-bar"), "goal bar styles");
assert.ok(css.includes("code-slash-menu"), "slash menu styles");
assert.ok(existsSync(path.join(root, "src/agent/goal.ts")), "goal module");
console.log("goal: /goal slash command + banner + slash menu");

// Marketplace (connectors / skills / plugins / metal catalogs)
assert.ok(main.includes("fillSettingsMarketplace") || main.includes("marketplace"), "marketplace settings");
assert.ok(main.includes("applyMarketplaceStatusToRenderer"), "marketplace applied to renderer");
assert.ok(main.includes("applyMarketplaceConnectors"), "marketplace connectors wired");
assert.ok(main.includes("installMarketplaceSkill"), "marketplace install in renderer");
assert.ok(main.includes('"marketplace"'), "marketplace settings tab");
const marketplaceDir = path.join(root, "src/marketplace");
assert.ok(
  ["types.ts", "store.ts", "parse.ts", "apply.ts", "install.ts"].every((f) =>
    existsSync(path.join(marketplaceDir, f)),
  ),
  "marketplace module files",
);
console.log("marketplace: multi-source catalog + install for connectors/skills/plugins/metal");

// Chat send uses shipped pure turn builders (not inline-only stubs)
assert.ok(main.includes("buildUserContent"), "user content builder");
assert.ok(main.includes("buildChatSystemContent"), "system content builder");
assert.ok(main.includes("withSystemTurn"), "system turn prepend");
const projectModalsSrc = readFileSync(
  path.join(root, "src/renderer/project-modals.ts"),
  "utf8",
);
assert.ok(
  projectModalsSrc.includes("memoryTextFromEditor") ||
    projectModalsSrc.includes("readPersistableBody"),
  "memory modal must sanitize empty chrome before setMemory",
);
assert.ok(
  !main.includes("Attachments and connectors open from Settings on desktop"),
  "composer + must not be coming-soon stub",
);
assert.ok(main.includes("fillSettingsSkills") && main.includes("skillsStore.list"), "settings skills list store");
assert.ok(
  main.includes("window.apc.metal.installRuntime") || main.includes("metal.installRuntime"),
  "metal installRuntime IPC call",
);
console.log("chat-turn builders + metal installRuntime wired; no composer coming-soon stub");

// Custom providers: Settings CRUD + chat/code wiring
assert.ok(main.includes("addCustomProvider"), "settings add custom provider");
assert.ok(main.includes("updateCustomProvider"), "settings edit custom provider");
assert.ok(main.includes("removeCustomProvider"), "settings remove custom provider");
assert.ok(main.includes("promptAddCustomProvider"), "add custom provider UI");
assert.ok(main.includes("Custom providers"), "custom providers section copy");
assert.ok(main.includes("mergeProviderCatalog"), "picker includes custom catalog");
assert.ok(main.includes("baseUrl: ep?.baseUrl") || main.includes("baseUrl: codeEp.baseUrl"), "chat/code pass baseUrl");
assert.ok(main.includes("apiStyle"), "apiStyle threaded to stream/session");
assert.ok(
  /create_session[\s\S]*baseUrl/.test(main) || main.includes("baseUrl: codeEp.baseUrl"),
  "create_session model includes baseUrl for custom",
);
const customStore = readFileSync(path.join(root, "src/client/custom-providers.ts"), "utf8");
assert.ok(customStore.includes("loadCustomProviders"), "custom provider store");
assert.ok(customStore.includes("chatRequestTarget"), "chat request target resolver");
const chatStream = readFileSync(path.join(root, "src/renderer/chat-stream.ts"), "utf8");
assert.ok(chatStream.includes("baseUrl"), "chat-stream accepts baseUrl");
assert.ok(chatStream.includes("chatRequestTarget"), "chat-stream uses shared target resolver");
console.log("custom providers: settings CRUD + picker + baseUrl/apiStyle on chat and create_session");

// Electron does not implement window.prompt(); confirm/alert are unreliable.
// Renderer must use appPrompt / appConfirm / appAlert / appForm / appChoice.
const dialogs = readFileSync(path.join(root, "src/renderer/dialogs.ts"), "utf8");
assert.ok(existsSync(path.join(root, "src/renderer/dialogs.ts")), "dialogs.ts present");
assert.ok(dialogs.includes("export function appPrompt"), "appPrompt helper");
assert.ok(dialogs.includes("export function appConfirm"), "appConfirm helper");
assert.ok(main.includes("appPrompt") || main.includes("appForm"), "main uses electron-safe dialogs");
for (const [name, src] of [
  ["main.ts", main],
  ["skill-ui.ts", skillUi],
  ["project-modals.ts", projectModals],
  ["composer-menu.ts", composerMenu],
] as const) {
  assert.ok(!/\bprompt\s*\(/.test(src), `${name} must not call prompt()`);
  assert.ok(!/\bconfirm\s*\(/.test(src), `${name} must not call confirm()`);
  assert.ok(!/\balert\s*\(/.test(src), `${name} must not call alert()`);
}
assert.ok(css.includes("dialog-modal") || css.includes("dialog-backdrop"), "dialog styles");
console.log("electron-safe dialogs: no prompt/confirm/alert in renderer UI");
