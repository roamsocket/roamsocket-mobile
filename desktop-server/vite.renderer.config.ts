import { defineConfig } from "vite";

// Renderer config. The Forge plugin sets `root` to the project root, which
// would mirror our nested renderer folder into the output (so HTML ends up
// under `.vite/renderer/${name}/src/renderer/index.html`). We change the
// build root to `src/renderer` so HTML lives at the renderer root, then
// override `outDir` so the plugin's `.vite/renderer/${name}` path stays
// correct relative to the project root.
//
// We also pin the dev server to IPv4 (`127.0.0.1`). On some macOS
// configurations `localhost` resolves to IPv6 (`::1`) in Node but
// Chromium's renderer tries IPv4 first, which fails with
// `ERR_FILE_NOT_FOUND` because the dev server isn't listening on IPv4.
export default defineConfig({
  root: "src/renderer",
  build: {
    target: "chrome128",
    outDir: "../../.vite/renderer/main_window",
    emptyOutDir: true,
  },
  server: {
    // Bind to all interfaces so the renderer (which loads
    // `http://localhost:5173/` via the Forge plugin's injected env var)
    // can reach the dev server regardless of whether `localhost`
    // resolves to IPv4 or IPv6 on this host.
    host: true,
  },
});
