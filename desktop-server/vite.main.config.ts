import { defineConfig } from "vite";

// Main process config. We bundle all runtime deps into main.cjs so the
// packaged app doesn't need a full node_modules. Only `electron` and Node
// built-ins stay external — they always resolve at runtime.
//
// We also force a `.cjs` filename because the project is `"type": "module"`,
// which would otherwise refuse the CommonJS-shaped output.
//
// `bufferutil` and `utf-8-validate` are optional native peers of `ws`.
// Vite inlines a hard `throw` for missing optional peer deps, which kills
// the bundle at runtime. Marking them external makes `ws` fall back to its
// pure-JS path, which is plenty fast for a local WebSocket server.
export default defineConfig({
  build: {
    lib: {
      entry: "src/electron/main.ts",
      formats: ["cjs"],
    },
    rollupOptions: {
      external: ["electron", /^node:/, "bufferutil", "utf-8-validate"],
      output: {
        entryFileNames: "[name].cjs",
        chunkFileNames: "[name].cjs",
      },
    },
  },
});
