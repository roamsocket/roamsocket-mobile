import { defineConfig } from "vite";

// Renderer config. The Forge plugin sets `root` to the project root, which
// would mirror our nested renderer folder into the output (so HTML ends up
// under `.vite/renderer/${name}/src/renderer/index.html`). We change the
// build root to `src/renderer` so HTML lives at the renderer root, then
// override `outDir` so the plugin's `.vite/renderer/${name}` path stays
// correct relative to the project root.
export default defineConfig({
  root: "src/renderer",
  build: {
    target: "chrome128",
    outDir: "../../.vite/renderer/main_window",
    emptyOutDir: true,
  },
});
