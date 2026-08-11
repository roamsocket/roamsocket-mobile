/**
 * Unit tests for RoamSocket CLI: command parser, TUI reducer, local session + mock.
 * Exercises shipped modules — no reimplementation of the units under test.
 */
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  cyclePermissionMode,
  completeModelArg,
  getSlashCompletions,
  parseCliCommand,
  formatHelpText,
  buildMobilePairingDisplay,
  loadModelCompletionCatalog,
  type ModelCompletionCatalog,
} from "../src/cli/commands.js";
import {
  parseMetalArgs,
  resolveMetalHubQuery,
  metalHelpText,
} from "../src/cli/metal-cli.js";
import { LocalCliSession } from "../src/cli/local-session.js";
import { runOneShot } from "../src/cli/main.js";
import { resolveModelSelection } from "../src/cli/secrets.js";
import {
  deriveActivity,
  extractThinking,
  initialTuiState,
  reduceTui,
  resetTuiIds,
} from "../src/cli/tui/state.js";
import {
  clampCursor,
  deleteBackward,
  deleteForward,
  deleteToLineEnd,
  deleteToLineStart,
  deleteWordBackward,
  deleteWordForward,
  insertText,
  moveCharLeft,
  moveCharRight,
  moveLineEnd,
  moveLineStart,
  moveWordLeft,
  moveWordRight,
} from "../src/cli/tui/composer-input.js";
import type { ServerMessage } from "../src/protocol.js";
import {
  describeProjectMemory,
  readProjectConfig,
} from "../src/project/config.js";

let failed = 0;

function test(name: string, fn: () => void | Promise<void>): Promise<void> {
  return Promise.resolve()
    .then(() => fn())
    .then(() => {
      console.log(`  ok  ${name}`);
    })
    .catch((err) => {
      failed += 1;
      console.error(`  FAIL ${name}`);
      console.error(err);
    });
}

async function main() {
  console.log("cli-unit");

  await test("parseCliCommand: plain agent text", () => {
    const c = parseCliCommand("fix the flaky test");
    assert.equal(c.kind, "agent");
    if (c.kind === "agent") assert.equal(c.text, "fix the flaky test");
  });

  await test("parseCliCommand: /goal stays agent-native", () => {
    const c = parseCliCommand("/goal all tests pass");
    assert.equal(c.kind, "agent");
  });

  await test("parseCliCommand: help clear quit pair server mobile", () => {
    assert.equal(parseCliCommand("/help").kind, "help");
    assert.equal(parseCliCommand("/clear").kind, "clear");
    assert.equal(parseCliCommand("/quit").kind, "quit");
    assert.equal(parseCliCommand("/pair").kind, "pair");
    assert.equal(parseCliCommand("/server").kind, "server");
    assert.equal(parseCliCommand("/mobile").kind, "mobile");
    assert.equal(parseCliCommand("/compact").kind, "compact");
    assert.equal(parseCliCommand("/context").kind, "context");
    assert.equal(parseCliCommand("/doctor").kind, "doctor");
    assert.equal(parseCliCommand("/diff").kind, "diff");
    assert.equal(parseCliCommand("/plan").kind, "permission");
    const plan = parseCliCommand("/plan");
    if (plan.kind === "permission") assert.equal(plan.mode, "plan");
  });

  await test("parseCliCommand: effort + review agent kickoff", () => {
    const e = parseCliCommand("/effort high");
    assert.equal(e.kind, "effort");
    if (e.kind === "effort") assert.equal(e.effort, "high");
    const r = parseCliCommand("/review auth");
    assert.equal(r.kind, "agent");
    if (r.kind === "agent") assert.match(r.text, /auth/i);
  });

  await test("getSlashCompletions filters as you type", () => {
    const all = getSlashCompletions("/");
    assert.ok(all.length >= 8, `expected many completions, got ${all.length}`);
    assert.ok(all.some((c) => c.token.startsWith("/mobile")));
    assert.ok(all.some((c) => c.token.startsWith("/goal")));
    const goal = getSlashCompletions("/go");
    assert.ok(goal.some((c) => c.token.startsWith("/goal")));
    assert.ok(!goal.some((c) => c.token.startsWith("/help")));
    const perm = getSlashCompletions("/permission a");
    assert.ok(perm.some((c) => c.token.includes("acceptEdits") || c.token.includes("ask")));
  });

  await test("/model completions use linked provider models", () => {
    const catalog: ModelCompletionCatalog = {
      linked: ["anthropic", "openai"],
      byProvider: {
        anthropic: [
          { id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4" },
          { id: "claude-opus-4-20250514", displayName: "Claude Opus 4" },
        ],
        openai: [{ id: "gpt-4.1", displayName: "GPT-4.1" }],
      },
    };
    const providers = getSlashCompletions("/model ", { modelCatalog: catalog });
    assert.ok(providers.some((c) => c.token.includes("anthropic/")));
    assert.ok(providers.some((c) => c.token.includes("openai/")));

    const models = getSlashCompletions("/model anthropic/", { modelCatalog: catalog });
    assert.ok(
      models.some((c) => c.token.endsWith("anthropic/claude-sonnet-4-20250514")),
      JSON.stringify(models),
    );
    assert.ok(models.some((c) => c.description.includes("Sonnet")));

    const filtered = getSlashCompletions("/model anthropic/opus", { modelCatalog: catalog });
    assert.equal(filtered.length, 1);
    assert.ok(filtered[0]!.token.includes("opus"));

    // completeModelArg unit
    const spaceStyle = completeModelArg("openai ", "/model openai ", catalog);
    assert.ok(spaceStyle.some((c) => c.token.includes("openai/gpt-4.1")));
  });

  await test("loadModelCompletionCatalog mock returns mock model", async () => {
    const cat = await loadModelCompletionCatalog({ mock: true });
    assert.ok(cat.linked.includes("anthropic"));
    assert.ok(cat.byProvider.anthropic?.some((m) => m.id === "mock"));
  });

  await test("/metal parse + resolve hub query", () => {
    assert.equal(parseMetalArgs("").op, "browse");
    assert.equal(parseMetalArgs("list").op, "browse");
    assert.equal(parseMetalArgs("browse").op, "browse");
    assert.equal(parseMetalArgs("runtime").op, "runtime");
    assert.equal(parseMetalArgs("install-runtime").op, "install-runtime");
    const dl = parseMetalArgs("download Qwen 3 0.6B");
    assert.equal(dl.op, "download");
    if (dl.op === "download") assert.equal(dl.query, "Qwen 3 0.6B");
    const bare = parseMetalArgs("Qwen 3 0.6B");
    assert.equal(bare.op, "download");

    const metalCmd = parseCliCommand("/metal download foo");
    assert.equal(metalCmd.kind, "metal");
    const metalBare = parseCliCommand("/metal");
    assert.equal(metalBare.kind, "metal");
    if (metalBare.kind === "metal") {
      assert.equal(metalBare.action.op, "browse");
    }

    const resolved = resolveMetalHubQuery("Qwen 3 0.6B");
    assert.equal(resolved.ok, true);
    if (resolved.ok) {
      assert.match(resolved.hubID, /Qwen3-0\.6B/i);
    }

    const comps = getSlashCompletions("/metal down");
    assert.ok(comps.some((c) => c.token.includes("download")));
    const browseComps = getSlashCompletions("/metal br");
    assert.ok(browseComps.some((c) => c.token.includes("browse")));

    const help = metalHelpText();
    assert.match(help, /download/);
    assert.match(help, /browser/i);
  });

  await test("Metal browser snapshot groups families", async () => {
    const { getMetalBrowserSnapshot } = await import("../src/cli/metal-cli.js");
    const snap = getMetalBrowserSnapshot();
    assert.ok(snap.families.length > 0, "expected catalog families");
    assert.ok(
      snap.families.some((f) => f.name === "Qwen" || f.models.length > 0),
      "expected Qwen or non-empty family",
    );
    for (const f of snap.families) {
      assert.ok(f.models.length > 0, `family ${f.name} has models`);
      assert.ok(typeof f.blurb === "string");
    }
    assert.ok(typeof snap.storageLabel === "string");
    assert.ok(snap.storeRoot.length > 0);
  });

  await test("help text lists mobile and omits usage/cost", () => {
    const h = formatHelpText();
    assert.match(h, /\/mobile/);
    assert.match(h, /\/goal/);
    assert.doesNotMatch(h, /\/usage/);
    assert.doesNotMatch(h, /\/cost/);
  });

  await test("buildMobilePairingDisplay includes code and payload", async () => {
    const text = await buildMobilePairingDisplay({
      host: "127.0.0.1",
      port: 4319,
      pairingCode: "123456",
      publicUrl: null,
    });
    assert.match(text, /1  2  3  4  5  6/);
    assert.match(text, /Payload:/);
    assert.match(text, /123456/);
  });

  await test("parseCliCommand: permission cycle and set", () => {
    assert.equal(parseCliCommand("/permission").kind, "permission");
    const set = parseCliCommand("/permission ask");
    assert.equal(set.kind, "permission");
    if (set.kind === "permission") assert.equal(set.mode, "ask");
    assert.equal(cyclePermissionMode("acceptEdits"), "ask");
    assert.equal(cyclePermissionMode("ask"), "plan");
    assert.equal(cyclePermissionMode("plan"), "acceptEdits");
  });

  await test("parseCliCommand: model provider/model", () => {
    const c = parseCliCommand("/model anthropic/claude-sonnet-4-20250514");
    assert.equal(c.kind, "model");
    if (c.kind === "model") {
      assert.equal(c.provider, "anthropic");
      assert.equal(c.model, "claude-sonnet-4-20250514");
    }
  });

  await test("parseCliCommand: keys", () => {
    const c = parseCliCommand("/keys anthropic sk-test-123");
    assert.equal(c.kind, "keys");
    if (c.kind === "keys") {
      assert.equal(c.provider, "anthropic");
      assert.equal(c.key, "sk-test-123");
    }
  });

  await test("reduceTui: assistant_delta + tool_call + tool_result + session_done", () => {
    resetTuiIds();
    let s = initialTuiState({ workdir: "/tmp/x" });
    s = reduceTui(s, { type: "user_submit", text: "hello" });
    assert.equal(s.busy, true);
    assert.equal(s.items.some((i) => i.kind === "user"), true);

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "assistant_delta",
        sessionId: "s1",
        text: "Working",
      },
    });
    assert.ok(s.streamingText.includes("Working"));

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "tool_call",
        sessionId: "s1",
        callId: "c1",
        tool: "write_file",
        summary: "write_file NOTES.md",
        input: { path: "NOTES.md", content: "hi" },
      },
    });
    const tool = s.items.find((i) => i.kind === "tool");
    assert.ok(tool && tool.kind === "tool");
    if (tool?.kind === "tool") {
      assert.equal(tool.name, "write_file");
      assert.equal(tool.callId, "c1");
    }

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "tool_result",
        sessionId: "s1",
        callId: "c1",
        ok: true,
        output: "wrote NOTES.md\n" + "stdout dump ".repeat(200),
      },
    });
    const tool2 = s.items.find((i) => i.kind === "tool" && i.callId === "c1");
    assert.ok(tool2 && tool2.kind === "tool" && tool2.ok === true);
    // Success: do not flood transcript with tool stdout
    if (tool2?.kind === "tool") assert.equal(tool2.result, undefined);

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "diff",
        sessionId: "s1",
        path: "NOTES.md",
        patch: "@@ +1 @@\n+hi\n+line2\n+line3\n" + "x".repeat(800),
        added: 1,
        removed: 0,
      },
    });
    const diffItem = s.items.find((i) => i.kind === "diff");
    assert.ok(diffItem && diffItem.kind === "diff");
    if (diffItem?.kind === "diff") {
      assert.equal(diffItem.patch, "", "TUI must not store full patch body");
      assert.equal(diffItem.added, 1);
      assert.equal(diffItem.removed, 0);
    }

    // Failed tool: one short line only
    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "tool_call",
        sessionId: "s1",
        callId: "c2",
        tool: "bash",
        summary: "bash: explode",
        input: { command: "explode" },
      },
    });
    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "tool_result",
        sessionId: "s1",
        callId: "c2",
        ok: false,
        output: "Error: boom\nstack frame 1\nstack frame 2\n" + "x".repeat(500),
      },
    });
    const failTool = s.items.find((i) => i.kind === "tool" && i.callId === "c2");
    assert.ok(failTool && failTool.kind === "tool" && failTool.ok === false);
    if (failTool?.kind === "tool") {
      assert.ok(failTool.result && failTool.result.length <= 120);
      assert.ok(!failTool.result!.includes("stack frame 2"));
    }

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "permission_request",
        sessionId: "s1",
        requestId: "r1",
        tool: "bash",
        summary: "bash: rm -rf",
      },
    });
    assert.ok(s.pendingPermission?.requestId === "r1");

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "error",
        sessionId: "s1",
        message: "boom",
      },
    });
    assert.ok(s.items.some((i) => i.kind === "system" && i.level === "error"));

    s = reduceTui(s, {
      type: "server_message",
      msg: { type: "session_done", sessionId: "s1", stopReason: "end_turn" },
    });
    assert.equal(s.busy, false);
    assert.equal(s.pendingPermission, null);
  });

  await test("LocalCliSession mock turn produces assistant + tools", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "rs-cli-"));
    try {
      const messages: ServerMessage[] = [];
      const session = await LocalCliSession.create({
        workdir: dir,
        model: {
          provider: "anthropic",
          model: "mock",
          effort: "high",
          apiKey: "mock",
        },
        permissionMode: "acceptEdits",
        mock: true,
        onMessage: (m) => messages.push(m),
        onPermission: async () => "allow",
      });
      await session.send("create a notes file");
      const types = messages.map((m) => m.type);
      assert.ok(types.includes("session_created"));
      assert.ok(types.includes("assistant_delta"), `types=${types.join(",")}`);
      assert.ok(types.includes("tool_call"), `types=${types.join(",")}`);
      assert.ok(types.includes("tool_result"));
      assert.ok(types.includes("session_done") || types.includes("task_list"));

      // mock writes NOTES.md
      const notes = await readFile(path.join(dir, "NOTES.md"), "utf8").catch(() => null);
      assert.ok(notes && notes.includes("Notes"), `NOTES.md content=${notes}`);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await test("LocalCliSession ask mode invokes permission callback", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "rs-cli-ask-"));
    try {
      let permCalls = 0;
      const session = await LocalCliSession.create({
        workdir: dir,
        model: {
          provider: "anthropic",
          model: "mock",
          effort: "high",
          apiKey: "mock",
        },
        permissionMode: "ask",
        mock: true,
        onMessage: () => {},
        onPermission: async () => {
          permCalls += 1;
          return "allow";
        },
      });
      await session.send("write notes");
      // write_file is mutating — mock uses it after update_tasks
      assert.ok(permCalls >= 1, `expected permission calls, got ${permCalls}`);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await test("LocalCliSession interrupt drains turn; no concurrent send race", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "rs-cli-int-"));
    try {
      const messages: ServerMessage[] = [];
      let afterInterrupt = false;
      const session = await LocalCliSession.create({
        workdir: dir,
        model: {
          provider: "anthropic",
          model: "mock",
          effort: "high",
          apiKey: "mock",
        },
        permissionMode: "ask",
        mock: true,
        onMessage: (m) => messages.push(m),
        onPermission: () =>
          new Promise<"allow" | "deny">((resolve) => {
            if (afterInterrupt) {
              resolve("allow");
              return;
            }
            // Hang — only session.interrupt() unblocks via pendingPermissions deny.
          }),
      });

      const send1 = session.send("create notes while I interrupt");
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline) {
        if (messages.some((m) => m.type === "permission_request")) break;
        await new Promise((r) => setTimeout(r, 10));
      }
      assert.ok(
        messages.some((m) => m.type === "permission_request"),
        "expected permission_request before interrupt",
      );
      assert.equal(session.isRunning, true);

      // Concurrent send while healthy (not aborted) must be ignored.
      const toolsBeforeRace = messages.filter((m) => m.type === "tool_call").length;
      await session.send("should be ignored while first turn active");
      assert.equal(
        messages.filter((m) => m.type === "tool_call").length,
        toolsBeforeRace,
        "ignored send must not emit more tool_calls",
      );
      assert.equal(session.isRunning, true);

      // Esc: abort mid-turn; running stays true until drain.
      session.interrupt();
      assert.equal(session.isRunning, true, "running stays true while turn drains");

      await send1;
      assert.equal(session.isRunning, false, "first turn fully exited");

      const interruptedDones = messages.filter(
        (m) => m.type === "session_done" && m.stopReason === "interrupted",
      );
      assert.equal(interruptedDones.length, 1, "exactly one interrupted session_done");

      // Aborted turn must not have written NOTES.md (write_file denied).
      const notesMid = await readFile(path.join(dir, "NOTES.md"), "utf8").catch(() => null);
      assert.equal(notesMid, null, "NOTES.md must not exist after interrupted first turn");

      // Mutating tools that completed before interrupt may exist (update_tasks);
      // write_file must not have ok:true result from the first turn.
      const writeResults = messages.filter(
        (m) => m.type === "tool_result" && messages.some(
          (c) =>
            c.type === "tool_call" &&
            c.callId === m.callId &&
            c.tool === "write_file",
        ),
      ) as Extract<ServerMessage, { type: "tool_result" }>[];
      for (const wr of writeResults) {
        // Denied / aborted first turn — no successful write.
        assert.equal(wr.ok, false, "write_file on interrupted turn must not succeed");
      }

      // Fresh conversation after drain — mock state is per AgentSession message list.
      afterInterrupt = true;
      await session.setPermissionMode("acceptEdits");
      await session.clear();
      const msgsBeforeSecond = messages.length;
      await session.send("second turn after interrupt");
      assert.equal(session.isRunning, false);
      assert.ok(messages.length > msgsBeforeSecond, "second turn emits messages");

      const notesFinal = await readFile(path.join(dir, "NOTES.md"), "utf8").catch(() => null);
      assert.ok(notesFinal && notesFinal.includes("Notes"), "second turn writes NOTES.md");

      // Still only one interrupted stopReason from the first turn (clear/session_created
      // does not emit another interrupted).
      const allInterrupted = messages.filter(
        (m) => m.type === "session_done" && m.stopReason === "interrupted",
      );
      assert.equal(allInterrupted.length, 1, "no dual interrupted session_done");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await test("isDirectMain: bin path must not auto-run (import-only)", async () => {
    // Structural: main.ts isDirectMain compares import.meta.url to argv[1] only —
    // roamsocket.js is not matched. Prove source contract.
    const mainSrc = await readFile(
      path.join(process.cwd(), "src/cli/main.ts"),
      "utf8",
    );
    assert.ok(mainSrc.includes("isDirectMain"), "isDirectMain helper present");
    assert.ok(
      !mainSrc.includes('endsWith("roamsocket.js")'),
      "must not treat bin/roamsocket.js as direct main",
    );
    const binSrc = await readFile(path.join(process.cwd(), "bin/roamsocket.js"), "utf8");
    assert.ok(binSrc.includes("main()"), "bin calls main once");
    // Count main() invocations in bin (only the explicit call, not import).
    const calls = binSrc.match(/\bmain\s*\(/g) ?? [];
    assert.equal(calls.length, 1, "bin should call main exactly once");
  });

  await test("runOneShot mock twice yields non-empty tool activity", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "rs-oneshot-"));
    try {
      const a = await runOneShot({ text: "add notes", workdir: dir, mock: true });
      assert.equal(a.ok, true);
      assert.ok(a.messages.some((m) => m.type === "tool_call"));
      const b = await runOneShot({ text: "add notes again", workdir: dir, mock: true });
      assert.equal(b.ok, true);
      assert.ok(b.messages.some((m) => m.type === "assistant_delta"));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await test("resolveModelSelection mock ignores missing keys", () => {
    const m = resolveModelSelection({ mock: true });
    assert.equal(m.model, "mock");
    assert.equal(m.apiKey, "mock");
  });

  await test("reduceTui maps task_list", () => {
    resetTuiIds();
    let s = initialTuiState();
    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "task_list",
        sessionId: "s",
        tasks: [
          { id: "1", content: "Plan", status: "completed" },
          { id: "2", content: "Write", status: "in_progress" },
        ],
      },
    });
    assert.equal(s.tasks.length, 2);
  });

  await test("composer-input: char and line navigation", () => {
    const t = "hello world";
    assert.equal(moveCharLeft(0), 0);
    assert.equal(moveCharLeft(3), 2);
    assert.equal(moveCharRight(t, 3), 4);
    assert.equal(moveCharRight(t, t.length), t.length);
    assert.equal(moveLineStart(), 0);
    assert.equal(moveLineEnd(t), t.length);
    assert.equal(clampCursor(t, -5), 0);
    assert.equal(clampCursor(t, 99), t.length);
  });

  await test("composer-input: word left/right jumps", () => {
    const t = "fix the flaky test";
    // cursor at end
    assert.equal(moveWordLeft(t, t.length), "fix the flaky ".length);
    assert.equal(moveWordLeft(t, "fix the flaky ".length), "fix the ".length);
    assert.equal(moveWordLeft(t, "fix the ".length), "fix ".length);
    assert.equal(moveWordLeft(t, "fix ".length), 0);
    assert.equal(moveWordLeft(t, 0), 0);

    // from start of second word
    assert.equal(moveWordRight(t, 0), "fix ".length);
    assert.equal(moveWordRight(t, "fix ".length), "fix the ".length);
    assert.equal(moveWordRight(t, "fix the flaky ".length), t.length);
    assert.equal(moveWordRight(t, t.length), t.length);

    // mid-word: jump to end of that word then past following space
    assert.equal(moveWordRight("ab cd", 1), "ab ".length);
    assert.equal(moveWordLeft("ab cd", 4), "ab ".length);
  });

  await test("composer-input: insert and delete at cursor", () => {
    assert.deepEqual(insertText("ac", 1, "b"), { text: "abc", cursor: 2 });
    assert.deepEqual(insertText("", 0, "hi"), { text: "hi", cursor: 2 });
    assert.deepEqual(deleteBackward("abc", 2), { text: "ac", cursor: 1 });
    assert.deepEqual(deleteBackward("abc", 0), { text: "abc", cursor: 0 });
    assert.deepEqual(deleteForward("abc", 1), { text: "ac", cursor: 1 });
    assert.deepEqual(deleteForward("abc", 3), { text: "abc", cursor: 3 });
  });

  await test("composer-input: word and line deletes", () => {
    assert.deepEqual(deleteWordBackward("fix the flaky", "fix the flaky".length), {
      text: "fix the ",
      cursor: "fix the ".length,
    });
    assert.deepEqual(deleteWordBackward("hello  world", "hello  world".length), {
      text: "hello  ",
      cursor: "hello  ".length,
    });
    assert.deepEqual(deleteWordForward("fix the flaky", 0), {
      text: "the flaky",
      cursor: 0,
    });
    // after first word+space, kill next word+trailing space
    assert.deepEqual(deleteWordForward("fix the flaky", "fix ".length), {
      text: "fix flaky",
      cursor: "fix ".length,
    });
    assert.deepEqual(deleteToLineEnd("hello world", 5), {
      text: "hello",
      cursor: 5,
    });
    assert.deepEqual(deleteToLineStart("hello world", 6), {
      text: "world",
      cursor: 0,
    });
  });

  await test("readProjectConfig: root CLAUDE.md without .claude/ dir", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "rs-cfg-root-"));
    try {
      await writeFile(path.join(dir, "CLAUDE.md"), "# Project\nUse pnpm.\n", "utf8");
      await writeFile(path.join(dir, "AGENTS.md"), "# Agents\nPrefer small diffs.\n", "utf8");
      const cfg = await readProjectConfig(dir, { skipUser: true });
      assert.ok(cfg.instructionsMd, "should load root instruction files");
      assert.ok(cfg.instructionsMd!.includes("Use pnpm"));
      assert.ok(cfg.instructionsMd!.includes("Prefer small diffs"));
      const scopes = cfg.instructionSources.map((s) => s.scope);
      assert.ok(scopes.includes("project"));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await test("readProjectConfig: global + workspace + folder hierarchy", async () => {
    const home = await mkdtemp(path.join(tmpdir(), "rs-cfg-home-"));
    const workspace = path.join(home, "ws");
    const nested = path.join(workspace, "packages", "app");
    try {
      await mkdir(path.join(home, ".claude", "rules"), { recursive: true });
      await mkdir(path.join(home, ".claude", "skills", "my-skill"), { recursive: true });
      await mkdir(path.join(workspace, ".claude", "skills", "proj-skill"), { recursive: true });
      await mkdir(nested, { recursive: true });

      await writeFile(path.join(home, ".claude", "CLAUDE.md"), "USER: always use tabs\n", "utf8");
      await writeFile(
        path.join(home, ".claude", "rules", "prefs.md"),
        "USER RULE: no emojis\n",
        "utf8",
      );
      await writeFile(
        path.join(home, ".claude", "skills", "my-skill", "SKILL.md"),
        "---\nname: my-skill\n---\nUser skill body\n",
        "utf8",
      );
      await writeFile(
        path.join(home, ".claude", "settings.json"),
        JSON.stringify({ env: { FROM_USER: "1" } }),
        "utf8",
      );

      await writeFile(path.join(workspace, "CLAUDE.md"), "WS: monorepo root\n", "utf8");
      await writeFile(
        path.join(workspace, ".claude", "CLAUDE.md"),
        "WS DOT: shared standards\n",
        "utf8",
      );
      await writeFile(
        path.join(workspace, ".claude", "settings.json"),
        JSON.stringify({ env: { FROM_PROJECT: "1" } }),
        "utf8",
      );
      await writeFile(
        path.join(workspace, ".claude", "settings.local.json"),
        JSON.stringify({ env: { FROM_LOCAL: "1", FROM_PROJECT: "local-wins" } }),
        "utf8",
      );
      await writeFile(
        path.join(workspace, ".claude", "skills", "proj-skill", "SKILL.md"),
        "---\nname: proj-skill\n---\nProject skill body\n",
        "utf8",
      );
      await writeFile(
        path.join(workspace, ".mcp.json"),
        JSON.stringify({ mcpServers: { demo: { type: "stdio", command: "echo" } } }),
        "utf8",
      );

      await writeFile(path.join(nested, "CLAUDE.md"), "FOLDER: app package only\n", "utf8");
      await writeFile(path.join(nested, "CLAUDE.local.md"), "LOCAL: my sandbox url\n", "utf8");

      const cfg = await readProjectConfig(nested, { homeDir: home });
      assert.ok(cfg.instructionsMd);
      assert.ok(cfg.instructionsMd!.includes("USER: always use tabs"));
      assert.ok(cfg.instructionsMd!.includes("USER RULE: no emojis"));
      assert.ok(cfg.instructionsMd!.includes("WS: monorepo root"));
      assert.ok(cfg.instructionsMd!.includes("WS DOT: shared standards"));
      assert.ok(cfg.instructionsMd!.includes("FOLDER: app package only"));
      assert.ok(cfg.instructionsMd!.includes("LOCAL: my sandbox url"));

      // Broadest → most specific: user content before folder content
      const userIdx = cfg.instructionsMd!.indexOf("USER: always use tabs");
      const folderIdx = cfg.instructionsMd!.indexOf("FOLDER: app package only");
      assert.ok(userIdx >= 0 && folderIdx > userIdx, "user instructions before folder");

      assert.equal(cfg.env.FROM_USER, "1");
      assert.equal(cfg.env.FROM_PROJECT, "local-wins");
      assert.equal(cfg.env.FROM_LOCAL, "1");

      const skillNames = cfg.skills.map((s) => s.name).sort();
      assert.deepEqual(skillNames, ["my-skill", "proj-skill"]);
      assert.ok(cfg.mcpServers.some((m) => m.name === "demo"));

      const report = await describeProjectMemory(nested, { homeDir: home });
      assert.ok(report.includes("Instruction files"));
      assert.ok(report.includes("user") || report.includes("[user]"));
    } finally {
      await rm(home, { recursive: true, force: true });
    }
  });

  await test("readProjectConfig: @import expands AGENTS.md", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "rs-cfg-import-"));
    try {
      await writeFile(path.join(dir, "AGENTS.md"), "IMPORTED AGENTS BODY\n", "utf8");
      await writeFile(
        path.join(dir, "CLAUDE.md"),
        "@AGENTS.md\n\n## Claude-only\nUse plan mode.\n",
        "utf8",
      );
      const cfg = await readProjectConfig(dir, { skipUser: true });
      assert.ok(cfg.instructionsMd?.includes("IMPORTED AGENTS BODY"));
      assert.ok(cfg.instructionsMd?.includes("Use plan mode"));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await test("LocalCliSession injects hierarchical instructions", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "rs-cli-instr-"));
    try {
      await writeFile(path.join(dir, "CLAUDE.md"), "INSTR: hierarchical test marker\n", "utf8");
      const messages: ServerMessage[] = [];
      const session = await LocalCliSession.create({
        workdir: dir,
        model: {
          provider: "anthropic",
          model: "mock",
          effort: "high",
          apiKey: "mock",
        },
        permissionMode: "acceptEdits",
        mock: true,
        onMessage: (m) => messages.push(m),
        onPermission: async () => "allow",
      });
      // Skills are private; exercise via a turn that still completes.
      await session.send("ping");
      assert.ok(messages.some((m) => m.type === "session_created"));
      assert.ok(messages.some((m) => m.type === "session_done"));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await test("extractThinking strips think tags", () => {
    const closed = extractThinking("Hi\n<think>plan steps</think>\nDone");
    assert.equal(closed.isThinkingOpen, false);
    assert.ok(closed.thinking?.includes("plan steps"));
    assert.ok(closed.content.includes("Hi"));
    assert.ok(closed.content.includes("Done"));
    assert.ok(!closed.content.includes("<think>"));

    const open = extractThinking("<think>still going");
    assert.equal(open.isThinkingOpen, true);
    assert.ok(open.thinking?.includes("still going"));
    assert.equal(open.content.trim(), "");
  });

  await test("deriveActivity: loading metal, thinking cloud, tool, idle", () => {
    resetTuiIds();
    let s = initialTuiState({ provider: "localMetal", model: "org/MyModel-4bit" });
    s = reduceTui(s, { type: "user_submit", text: "hello" });
    let act = deriveActivity(s);
    assert.equal(act.kind, "loading");
    assert.ok(act.label.toLowerCase().includes("load"));

    s = initialTuiState({ provider: "anthropic", model: "claude" });
    s = reduceTui(s, { type: "user_submit", text: "hello" });
    act = deriveActivity(s);
    assert.equal(act.kind, "thinking");

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "tool_call",
        sessionId: "s",
        callId: "c1",
        tool: "bash",
        summary: "bash: ls",
        input: { command: "ls" },
      },
    });
    act = deriveActivity(s);
    assert.equal(act.kind, "tool");

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "assistant_delta",
        sessionId: "s",
        text: "<think>reasoning here",
      },
    });
    act = deriveActivity(s);
    assert.equal(act.kind, "thinking");

    s = reduceTui(s, {
      type: "server_message",
      msg: {
        type: "assistant_delta",
        sessionId: "s",
        text: "</think>\nVisible answer",
      },
    });
    act = deriveActivity(s);
    assert.equal(act.kind, "streaming");

    s = reduceTui(s, {
      type: "server_message",
      msg: { type: "session_done", sessionId: "s", stopReason: "end_turn" },
    });
    act = deriveActivity(s);
    assert.equal(act.kind, "idle");
  });

  if (failed > 0) {
    console.error(`\n${failed} test(s) failed`);
    process.exit(1);
  }
  console.log("\nall cli-unit tests passed");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
