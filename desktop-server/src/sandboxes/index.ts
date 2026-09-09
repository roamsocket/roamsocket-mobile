/**
 * Public surface of the desktop's E2B sandbox module.
 *
 * The desktop app uses these exports the same way the iOS app uses
 * `AnyProvCore/Sandboxes/*`. The protocol does NOT carry E2B
 * messages any more — see `src/protocol.ts` lines 397-405 — so the
 * desktop talks to e2b.dev directly with the user's own API key.
 */
export {
  DirectE2BClient,
  DirectE2BError,
  E2B_API_HOST,
  E2B_CODE_INTERPRETER_PORT,
  E2B_CODE_INTERPRETER_TEMPLATE,
  E2B_MAX_SANDBOX_TIMEOUT_MS,
  E2B_MAX_SANDBOX_TIMEOUT_SECONDS,
  friendlyE2BError,
  validateE2BKey,
  type DirectE2BErrorKind,
  type E2bExecResult,
  type E2bSandboxInfo,
} from './direct-e2b-client.js';
export {
  e2bKeyStatus,
  readE2BKey,
  writeE2BKey,
  clearE2BKey,
  type E2BKeyStatus,
} from './e2b-key-store.js';
export {
  appendSandboxRun,
  clearSandboxRuns,
  loadSandboxRuns,
  updateSandboxRun,
  type SandboxRun,
  type SandboxRunStatus,
} from './sandbox-store.js';
