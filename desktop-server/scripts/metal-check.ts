/**
 * Metal path verification: catalog + runtime status + generate error paths.
 * Run: npx tsx scripts/metal-check.ts
 */
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  listChatMetalCatalog,
  METAL_PROVIDER_ID,
  MetalModelStore,
  getMetalRuntimeStatus,
  metalGenerate,
  resetMetalPythonCache,
} from "../src/metal/index.js";
import { isMetalProviderId, metalAgentAdapter } from "../src/providers/metal.js";

async function main() {
  console.log("=== Metal catalog ===");
  const cat = listChatMetalCatalog();
  assert.ok(cat.length > 0, "catalog must be non-empty");
  console.log(`entries: ${cat.length}`);
  console.log(
    cat
      .slice(0, 3)
      .map((e) => `${e.displayName} (${e.hubID})`)
      .join("\n"),
  );
  assert.equal(METAL_PROVIDER_ID, "localMetal");
  assert.ok(cat.every((e) => e.chatOnly === true));

  console.log("\n=== Runtime status ===");
  resetMetalPythonCache();
  const status = await getMetalRuntimeStatus();
  console.log(JSON.stringify(status, null, 2));
  assert.equal(status.providerId, "localMetal");
  assert.equal(status.chatOnly, true);
  assert.ok(status.detail.length > 10);

  const tmp = mkdtempSync(path.join(os.tmpdir(), "apc-metal-test-"));
  try {
    const store = new MetalModelStore(tmp);
    assert.equal(store.listDownloaded().length, 0);
    const hubID = cat[0]!.hubID;
    assert.equal(store.isDownloaded(hubID), false);

    console.log("\n=== Generate without download (must fail clearly) ===");
    let threw = false;
    try {
      await metalGenerate({
        hubID,
        messages: [{ role: "user", content: "hi" }],
      });
    } catch (err) {
      threw = true;
      const msg = String((err as Error).message);
      console.log(`error (expected): ${msg}`);
      // Must be a clear not-downloaded OR runtime-missing message, not silent success
      assert.ok(
        /not downloaded|not available|runtime|mlx-lm|Install mlx/i.test(msg),
        `unexpected error shape: ${msg}`,
      );
    }
    assert.ok(threw, "metalGenerate must throw when model/runtime missing");

    if (status.runtimeReady) {
      console.log("\n=== Runtime ready: download + generate smoke (optional) ===");
      // Skip multi-GB download in CI unless APC_METAL_DOWNLOAD=1
      if (process.env.APC_METAL_DOWNLOAD === "1") {
        const tiny =
          cat.find((e) => e.hubID.includes("270m") || e.hubID.includes("0.5B")) ?? cat[0]!;
        console.log(`downloading ${tiny.hubID}…`);
        await store.download(tiny.hubID, (p) => {
          if (p.fraction === 0 || p.fraction === 1) console.log(`  ${p.status}`);
        });
        assert.ok(store.isDownloaded(tiny.hubID));
        const result = await metalGenerate({
          hubID: tiny.hubID,
          messages: [{ role: "user", content: "Say hello in one short sentence." }],
          maxTokens: 32,
        });
        console.log(`generate: ${result.text.slice(0, 200)}`);
        assert.ok(result.text.length > 0);
      } else {
        console.log("skip download (set APC_METAL_DOWNLOAD=1 to exercise full path)");
      }
    } else {
      console.log("\nruntime not ready — clear missing-runtime error path verified above");
    }

    console.log("\n=== Metal agent adapter (tool_call parse) ===");
    assert.ok(isMetalProviderId("localMetal"));
    assert.ok(isMetalProviderId("local-metal"));
    assert.ok(!isMetalProviderId("anthropic"));

    // Without a downloaded model this throws — ensure adapter is wired.
    let adapterThrew = false;
    try {
      const gen = metalAgentAdapter.stream({
        model: hubID,
        apiKey: "local",
        system: "test",
        messages: [{ role: "user", text: "hi" }],
        tools: [],
        effort: "low",
      });
      // Drain — expect throw from metalGenerate (not downloaded / no runtime).
      // eslint-disable-next-line @typescript-eslint/no-unused-vars
      for await (const _ of gen) {
        /* empty */
      }
    } catch (err) {
      adapterThrew = true;
      const msg = String((err as Error).message);
      console.log(`adapter error (expected): ${msg.slice(0, 200)}`);
      assert.ok(
        /not downloaded|not available|runtime|mlx-lm|Install mlx/i.test(msg),
        `unexpected adapter error: ${msg}`,
      );
    }
    assert.ok(adapterThrew, "metal agent adapter must fail clearly without weights/runtime");

    console.log("\n=== Install module API exists ===");
  const {
    installMetalRuntime,
    managedMetalPythonPath,
    metalRuntimeRoot,
    metalInstallPlatformGate,
  } = await import("../src/metal/install.js");
  assert.equal(typeof installMetalRuntime, "function");
  assert.ok(metalRuntimeRoot().includes("metal-runtime"));
  assert.ok(managedMetalPythonPath().includes("venv"));
  console.log(`managed python path template: ${managedMetalPythonPath()}`);
  const blocked = metalInstallPlatformGate("win32");
  assert.ok(blocked && blocked.ok === false && blocked.error === "unsupported platform");
  assert.equal(metalInstallPlatformGate("darwin"), null);
  console.log("installMetalRuntime is exported; platform gate rejects non-darwin");
  console.log("installMetalRuntime is not fully invoked here — network/brew side effects");

  console.log("\nmetal checks passed");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
