#!/usr/bin/env node
/**
 * Global CLI entry for `codesocket` (aliases: codesocket-server, anyprov-code-server).
 * Starts the headless WebSocket companion server.
 */
import { startServer } from "../dist/src/index.js";

startServer().catch((err) => {
  console.error("Failed to start server:", err);
  process.exit(1);
});
