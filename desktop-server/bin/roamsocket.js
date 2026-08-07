#!/usr/bin/env node
/**
 * Primary global CLI entry for `roamsocket`.
 * Legacy install aliases (codesocket / codesocket-server / anyprov-code-server)
 * re-export this same entry for continuity only.
 */
import { startServer } from "../dist/src/index.js";

startServer().catch((err) => {
  console.error("Failed to start server:", err);
  process.exit(1);
});
