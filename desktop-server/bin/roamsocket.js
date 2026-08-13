#!/usr/bin/env node
/**
 * Primary global CLI entry for `roamsocket`.
 * Default (TTY): companion server + coding agent TUI.
 * Use --serve-only for headless pairing server only.
 * Legacy install aliases re-export this same entry.
 */
import { main } from '../dist/src/cli/main.js';

main().catch((err) => {
  console.error('Failed to start RoamSocket:', err);
  process.exit(1);
});
