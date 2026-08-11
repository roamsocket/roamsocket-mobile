/**
 * RoamSocket coding agent TUI (Ink + React).
 * Claude Code–style: status bar, stream, tools, permissions, composer,
 * slash commands + live completions.
 */
import React, { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { Box, Text, useApp, useInput, useWindowSize } from "ink";
import { writeFileSync } from "node:fs";
import path from "node:path";
import type { ServerMessage } from "../../protocol.js";
import type { LocalCliSession, PermissionDecision } from "../local-session.js";
import {
  type ModelCompletionCatalog,
  type SlashCompletion,
  applySlashCompletion,
  buildMobilePairingDisplay,
  cyclePermissionMode,
  formatHelpText,
  formatPairCode,
  getSlashCompletions,
  gitDiffSummary,
  loadModelCompletionCatalog,
  parseCliCommand,
  describeProjectMemory,
  writeAgentsInit,
} from "../commands.js";
import {
  formatDownloadProgress,
  formatMetalRuntimeStatus,
  metalHelpText,
  resolveMetalHubQuery,
} from "../metal-cli.js";
import { installMetalRuntime } from "../../metal/install.js";
import { getMetalStore } from "../../metal/store.js";
import {
  loadCliSecrets,
  resolveApiKey,
  resolveModelSelection,
  setProviderKey,
  updateCliSecrets,
} from "../secrets.js";
import { theme } from "./theme.js";
import {
  type StreamItem,
  type TuiState,
  deriveActivity,
  extractThinking,
  initialTuiState,
  reduceTui,
} from "./state.js";
import { MetalBrowser } from "./MetalBrowser.js";
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
} from "./composer-input.js";

export interface ServerStatus {
  port: number;
  host: string;
  pairingCode: string;
  getPairingCode: () => string;
  getTunnelUrl?: () => string | null;
  rotatePairingCode?: () => string;
}

export interface MessageBus {
  emit(msg: ServerMessage): void;
  subscribe(fn: (msg: ServerMessage) => void): () => void;
}

export function createMessageBus(): MessageBus {
  const listeners = new Set<(msg: ServerMessage) => void>();
  return {
    emit(msg) {
      for (const l of listeners) l(msg);
    },
    subscribe(fn) {
      listeners.add(fn);
      return () => {
        listeners.delete(fn);
      };
    },
  };
}

export interface PermissionBridge {
  onPermission: (req: {
    requestId: string;
    tool: string;
    summary: string;
  }) => Promise<PermissionDecision>;
  attach: (
    handler: (req: {
      requestId: string;
      tool: string;
      summary: string;
    }) => Promise<PermissionDecision>,
  ) => void;
}

export function createPermissionBridge(): PermissionBridge {
  let handler:
    | ((req: {
        requestId: string;
        tool: string;
        summary: string;
      }) => Promise<PermissionDecision>)
    | null = null;
  const queue: Array<{
    req: { requestId: string; tool: string; summary: string };
    resolve: (d: PermissionDecision) => void;
  }> = [];

  return {
    onPermission(req) {
      if (handler) return handler(req);
      return new Promise((resolve) => {
        queue.push({ req, resolve });
      });
    },
    attach(h) {
      handler = h;
      for (const item of queue.splice(0)) {
        void h(item.req).then(item.resolve);
      }
    },
  };
}

export interface AppProps {
  session: LocalCliSession;
  server: ServerStatus;
  mock: boolean;
  bus: MessageBus;
  permBridge: PermissionBridge;
  onQuit: () => void | Promise<void>;
}

function shortPath(p: string): string {
  const home = process.env.HOME;
  if (home && p.startsWith(home)) return `~${p.slice(home.length)}`;
  return p;
}

/** Slash commands that never need an agent turn — safe while busy. */
function isMetaSlash(text: string): boolean {
  const cmd = parseCliCommand(text);
  return cmd.kind !== "agent" && cmd.kind !== "unknown";
}

export function App({ session, server, mock, bus, permBridge, onQuit }: AppProps) {
  const { exit } = useApp();
  /** Full terminal size so the root layout fills the window (Yoga needs a fixed height for flexGrow). */
  const { columns, rows } = useWindowSize();
  const [state, dispatch] = useReducer(
    reduceTui,
    initialTuiState({
      workdir: session.workdir,
      provider: session.currentModel.provider,
      model: session.currentModel.model,
      permissionMode: session.currentPermissionMode,
      pairingCode: server.pairingCode,
      serverPort: server.port,
      serverHost: server.host,
      tunnelUrl: server.getTunnelUrl?.() ?? null,
    }),
  );

  const [draft, setDraft] = useState("");
  /** Cursor index into `draft` (0 = before first char, draft.length = after last). */
  const [cursor, setCursor] = useState(0);
  const [completionIndex, setCompletionIndex] = useState(0);
  /**
   * Transcript scroll: items held back from the live tail.
   * 0 = stick to bottom (follow new output). PgUp increases; PgDn decreases.
   */
  const [scrollBack, setScrollBack] = useState(0);
  /** Spinner frame for Thinking / Loading indicators (chat-style). */
  const [spinFrame, setSpinFrame] = useState(0);
  const [modelCatalog, setModelCatalog] = useState<ModelCompletionCatalog | null>(null);
  const sessionRef = useRef(session);
  sessionRef.current = session;
  const stateRef = useRef(state);
  stateRef.current = state;
  /** In-flight agent send(); kept so Esc can wait for drain before busy=false. */
  const activeSendRef = useRef<Promise<void> | null>(null);
  const catalogAbortRef = useRef<AbortController | null>(null);
  /** True while Metal download or runtime install is in flight. */
  const metalBusyRef = useRef(false);
  const metalDownloadAbortRef = useRef<AbortController | null>(null);
  const [metalBrowserOpen, setMetalBrowserOpen] = useState(false);
  const [metalBrowserBusy, setMetalBrowserBusy] = useState<string | null>(null);
  const [metalRefreshKey, setMetalRefreshKey] = useState(0);

  const replaceDraft = useCallback((text: string, nextCursor?: number) => {
    setDraft(text);
    setCursor(clampCursor(text, nextCursor ?? text.length));
  }, []);

  const applyEdit = useCallback(
    (edit: { text: string; cursor: number }) => {
      setDraft(edit.text);
      setCursor(clampCursor(edit.text, edit.cursor));
    },
    [],
  );

  const refreshModelCatalog = useCallback(async () => {
    catalogAbortRef.current?.abort();
    const ac = new AbortController();
    catalogAbortRef.current = ac;
    setModelCatalog((prev) =>
      prev
        ? { ...prev, loading: true }
        : { linked: [], byProvider: {}, loading: true },
    );
    try {
      const catalog = await loadModelCompletionCatalog({
        mock,
        signal: ac.signal,
      });
      if (ac.signal.aborted) return;
      setModelCatalog({ ...catalog, loading: false });
    } catch {
      if (ac.signal.aborted) return;
      setModelCatalog((prev) =>
        prev ? { ...prev, loading: false } : { linked: [], byProvider: {}, loading: false },
      );
    }
  }, [mock]);

  useEffect(() => {
    void refreshModelCatalog();
    return () => catalogAbortRef.current?.abort();
  }, [refreshModelCatalog]);

  const completions = useMemo(
    () => getSlashCompletions(draft, { modelCatalog }),
    [draft, modelCatalog],
  );
  const activeCompletion = completions[completionIndex] ?? completions[0] ?? null;

  useEffect(() => {
    setCompletionIndex(0);
  }, [draft, modelCatalog]);

  useEffect(() => {
    return bus.subscribe((msg) => {
      dispatch({ type: "server_message", msg });
    });
  }, [bus]);

  // Animate activity spinner while the agent is busy (Thinking / Loading model).
  useEffect(() => {
    if (!state.busy && !state.pendingPermission) return;
    const id = setInterval(() => setSpinFrame((n) => n + 1), 120);
    return () => clearInterval(id);
  }, [state.busy, state.pendingPermission]);

  useEffect(() => {
    const tick = setInterval(() => {
      dispatch({
        type: "server_info",
        port: server.port,
        host: server.host,
        pairingCode: server.getPairingCode(),
      });
      dispatch({ type: "tunnel", url: server.getTunnelUrl?.() ?? null });
    }, 2000);
    return () => clearInterval(tick);
  }, [server]);

  const permWaiters = useRef(
    new Map<string, (d: PermissionDecision) => void>(),
  );

  useEffect(() => {
    permBridge.attach(async (req) => {
      return new Promise<PermissionDecision>((resolve) => {
        permWaiters.current.set(req.requestId, resolve);
      });
    });
  }, [permBridge]);

  const resolvePerm = useCallback((decision: PermissionDecision) => {
    const pending = stateRef.current.pendingPermission;
    if (!pending) return;
    sessionRef.current.resolvePermission(pending.requestId, decision);
    const w = permWaiters.current.get(pending.requestId);
    if (w) {
      permWaiters.current.delete(pending.requestId);
      w(decision);
    }
    dispatch({ type: "permission_resolved" });
  }, []);

  const quit = useCallback(async () => {
    try {
      await onQuit();
    } finally {
      exit();
    }
  }, [exit, onQuit]);

  const metalInstallRuntime = useCallback(async () => {
    if (metalBusyRef.current) {
      const msg = "A Metal install/download is already running.";
      if (metalBrowserOpen) setMetalBrowserBusy(msg);
      else dispatch({ type: "system", text: msg, level: "warn" });
      return;
    }
    metalBusyRef.current = true;
    setMetalBrowserBusy("Installing Metal runtime (Python + mlx-lm)…");
    dispatch({
      type: "system",
      text: "Installing Metal runtime (Python + mlx-lm)… this can take several minutes.",
      level: "info",
    });
    dispatch({ type: "status", text: "Metal runtime install…" });
    try {
      let lastLog = 0;
      const result = await installMetalRuntime((line) => {
        const now = Date.now();
        if (now - lastLog > 1500) {
          lastLog = now;
          const short = line.slice(0, 80);
          dispatch({ type: "status", text: short });
          setMetalBrowserBusy(short);
        }
      });
      dispatch({
        type: "system",
        text: result.ok
          ? `Metal runtime ready.\n${result.detail}${result.pythonPath ? `\nPython: ${result.pythonPath}` : ""}`
          : `Metal runtime install failed.\n${result.detail}${result.error ? `\n${result.error}` : ""}`,
        level: result.ok ? "info" : "error",
      });
      setMetalBrowserBusy(result.ok ? "Runtime ready" : "Runtime install failed");
    } finally {
      metalBusyRef.current = false;
      dispatch({ type: "status", text: "Ready" });
      if (metalBrowserOpen) {
        setTimeout(() => setMetalBrowserBusy(null), 2000);
      } else {
        setMetalBrowserBusy(null);
      }
    }
  }, [metalBrowserOpen]);

  const metalDownload = useCallback(
    async (query: string) => {
      if (metalBusyRef.current) {
        const msg = "A Metal install/download is already running.";
        if (metalBrowserOpen) setMetalBrowserBusy(msg);
        else dispatch({ type: "system", text: msg, level: "warn" });
        return;
      }
      const resolved = resolveMetalHubQuery(query);
      if (!resolved.ok) {
        const extra = resolved.suggestions?.length
          ? `\n${resolved.suggestions.join("\n")}`
          : "";
        dispatch({
          type: "system",
          text: `${resolved.error}${extra}`,
          level: "warn",
        });
        if (metalBrowserOpen) setMetalBrowserBusy(resolved.error);
        return;
      }
      const store = getMetalStore();
      if (store.isDownloaded(resolved.hubID)) {
        dispatch({
          type: "system",
          text: `Already downloaded: ${resolved.displayName}\n${resolved.hubID}\nUse: /metal use ${resolved.hubID}`,
          level: "info",
        });
        if (metalBrowserOpen) setMetalBrowserBusy(`Already downloaded: ${resolved.displayName}`);
        return;
      }
      metalBusyRef.current = true;
      setMetalBrowserBusy(`Downloading ${resolved.displayName}…`);
      dispatch({
        type: "system",
        text: `Downloading ${resolved.displayName}…\n${resolved.hubID}`,
        level: "info",
      });
      dispatch({ type: "status", text: "Metal download…" });
      const ac = new AbortController();
      metalDownloadAbortRef.current = ac;
      try {
        let lastPct = -1;
        const rec = await store.download(
          resolved.hubID,
          (p) => {
            const pct = Math.round(p.fraction * 100);
            if (pct !== lastPct && (pct % 5 === 0 || pct === 100 || lastPct < 0)) {
              lastPct = pct;
              const line = formatDownloadProgress(p);
              dispatch({ type: "status", text: line });
              setMetalBrowserBusy(line);
            }
          },
          ac.signal,
        );
        dispatch({
          type: "system",
          text:
            `Downloaded ${rec.displayName}\n` +
            `${rec.hubID}\n` +
            `Path: ${rec.localPath}\n` +
            `Switch: /metal use ${rec.hubID}`,
          level: "info",
        });
        setMetalRefreshKey((k) => k + 1);
        void refreshModelCatalog();
        setMetalBrowserBusy(`Downloaded ${rec.displayName} — press u or Enter to use`);
      } catch (err) {
        dispatch({
          type: "system",
          text: `Metal download failed: ${(err as Error).message}`,
          level: "error",
        });
        setMetalBrowserBusy(`Download failed: ${(err as Error).message}`);
      } finally {
        metalBusyRef.current = false;
        metalDownloadAbortRef.current = null;
        dispatch({ type: "status", text: "Ready" });
      }
    },
    [metalBrowserOpen, refreshModelCatalog],
  );

  const metalCancelDownload = useCallback(() => {
    metalDownloadAbortRef.current?.abort();
    metalDownloadAbortRef.current = null;
    dispatch({ type: "system", text: "Metal download cancelled", level: "info" });
    setMetalBrowserBusy("Download cancelled");
    metalBusyRef.current = false;
    dispatch({ type: "status", text: "Ready" });
  }, []);

  const metalUse = useCallback(
    async (query: string) => {
      const resolved = resolveMetalHubQuery(query);
      if (!resolved.ok) {
        const extra = resolved.suggestions?.length
          ? `\n${resolved.suggestions.join("\n")}`
          : "";
        dispatch({
          type: "system",
          text: `${resolved.error}${extra}`,
          level: "warn",
        });
        return;
      }
      const store = getMetalStore();
      if (!store.isDownloaded(resolved.hubID)) {
        dispatch({
          type: "system",
          text:
            `Not downloaded yet: ${resolved.displayName}\n` +
            `Run: /metal download ${resolved.hubID}`,
          level: "warn",
        });
        if (metalBrowserOpen) {
          setMetalBrowserBusy(`Not downloaded — press d to download`);
        }
        return;
      }
      updateCliSecrets({ provider: "localMetal", model: resolved.hubID });
      const next = resolveModelSelection({
        provider: "localMetal",
        model: resolved.hubID,
        mock: false,
        secrets: loadCliSecrets(),
      });
      next.apiKey = next.apiKey || "none";
      await sessionRef.current.setModel(next);
      dispatch({ type: "model", provider: next.provider, model: next.model });
      dispatch({
        type: "system",
        text: `Model → localMetal/${resolved.hubID}\n${resolved.displayName}`,
        level: "info",
      });
      setMetalRefreshKey((k) => k + 1);
      if (metalBrowserOpen) {
        setMetalBrowserBusy(`Active: ${resolved.displayName}`);
      }
    },
    [metalBrowserOpen],
  );

  const metalDelete = useCallback(
    async (query: string) => {
      const resolved = resolveMetalHubQuery(query);
      if (!resolved.ok) {
        const extra = resolved.suggestions?.length
          ? `\n${resolved.suggestions.join("\n")}`
          : "";
        dispatch({
          type: "system",
          text: `${resolved.error}${extra}`,
          level: "warn",
        });
        return;
      }
      const store = getMetalStore();
      if (!store.isDownloaded(resolved.hubID)) {
        dispatch({
          type: "system",
          text: `Not downloaded: ${resolved.hubID}`,
          level: "warn",
        });
        return;
      }
      store.delete(resolved.hubID);
      dispatch({
        type: "system",
        text: `Deleted ${resolved.displayName}\n${resolved.hubID}`,
        level: "info",
      });
      setMetalRefreshKey((k) => k + 1);
      void refreshModelCatalog();
      if (metalBrowserOpen) {
        setMetalBrowserBusy(`Deleted ${resolved.displayName}`);
      }
    },
    [metalBrowserOpen, refreshModelCatalog],
  );

  const handleSubmit = useCallback(
    async (raw: string) => {
      const text = raw.trim();
      if (!text) return;

      // While agent is busy, only meta slash commands are allowed.
      if (
        (stateRef.current.busy || sessionRef.current.isRunning) &&
        !text.startsWith("/")
      ) {
        return;
      }
      if (
        (stateRef.current.busy || sessionRef.current.isRunning) &&
        text.startsWith("/") &&
        !isMetaSlash(text)
      ) {
        dispatch({
          type: "system",
          text: "Agent is busy — wait or Esc to interrupt. Meta commands: /mobile /pair /help /quit …",
          level: "warn",
        });
        return;
      }

      const cmd = parseCliCommand(text);

      switch (cmd.kind) {
        case "help":
          dispatch({ type: "toggle_help" });
          return;
        case "quit":
          await quit();
          return;
        case "clear":
        case "compact": {
          dispatch({ type: "clear" });
          await sessionRef.current.clear();
          dispatch({
            type: "system",
            text:
              cmd.kind === "compact"
                ? "Context compacted — new conversation (same workdir)."
                : "New conversation.",
            level: "info",
          });
          return;
        }
        case "mobile": {
          const code = server.getPairingCode();
          const display = await buildMobilePairingDisplay({
            host: server.host,
            port: server.port,
            pairingCode: code,
            publicUrl: server.getTunnelUrl?.() ?? null,
          });
          dispatch({ type: "system", text: display, level: "info" });
          return;
        }
        case "pair": {
          const code = server.getPairingCode();
          dispatch({
            type: "system",
            text: `Pairing code: ${formatPairCode(code)}  ·  port ${server.port}\nTip: /mobile shows the QR for the iOS app.`,
            level: "info",
          });
          return;
        }
        case "server": {
          const tunnel = server.getTunnelUrl?.();
          const lines = [
            `Server :${server.port} (${server.host})`,
            `Pairing: ${formatPairCode(server.getPairingCode())}`,
            tunnel ? `Tunnel: ${tunnel}` : "Tunnel: (none)",
            `Workdir: ${sessionRef.current.workdir}`,
            `Model: ${sessionRef.current.currentModel.provider}/${sessionRef.current.currentModel.model}`,
            `Permission: ${sessionRef.current.currentPermissionMode}`,
          ];
          dispatch({ type: "system", text: lines.join("\n"), level: "info" });
          return;
        }
        case "context": {
          const m = sessionRef.current.currentModel;
          const s = stateRef.current;
          const lines = [
            `Provider/model: ${m.provider}/${m.model}${mock ? " (mock)" : ""}`,
            `Effort: ${m.effort}`,
            `Permission: ${sessionRef.current.currentPermissionMode}`,
            `Workdir: ${sessionRef.current.workdir}`,
            `Tasks: ${s.tasks.length}`,
            `Transcript items: ${s.items.length}`,
            s.tunnelUrl ? `Tunnel: ${s.tunnelUrl}` : "Tunnel: (none)",
            `Pair: ${formatPairCode(server.getPairingCode())} · :${server.port}`,
          ];
          dispatch({ type: "system", text: lines.join("\n"), level: "info" });
          return;
        }
        case "doctor": {
          const keyOk =
            mock || Boolean(resolveApiKey(sessionRef.current.currentModel.provider));
          const lines = [
            `Server: listening :${server.port}`,
            `Pairing code: ${formatPairCode(server.getPairingCode())}`,
            `API key (${sessionRef.current.currentModel.provider}): ${keyOk ? "ok" : "MISSING — /keys <provider> <key>"}`,
            `Mock: ${mock ? "yes" : "no"}`,
            `Workdir exists: yes (${sessionRef.current.workdir})`,
            `Tunnel: ${server.getTunnelUrl?.() ?? "(none)"}`,
          ];
          dispatch({
            type: "system",
            text: lines.join("\n"),
            level: keyOk ? "info" : "warn",
          });
          return;
        }
        case "init": {
          const result = writeAgentsInit(sessionRef.current.workdir);
          dispatch({
            type: "system",
            text: result.created
              ? `Created ${result.path}`
              : `Already exists: ${result.path}`,
            level: "info",
          });
          return;
        }
        case "memory": {
          void describeProjectMemory(sessionRef.current.workdir).then((text) => {
            dispatch({
              type: "system",
              text,
              level: "info",
            });
          });
          return;
        }
        case "tasks": {
          const tasks = stateRef.current.tasks;
          if (tasks.length === 0) {
            dispatch({
              type: "system",
              text: "No agent tasks yet. The agent fills this list via update_tasks.",
              level: "info",
            });
            return;
          }
          const lines = tasks.map((t) => {
            const g =
              t.status === "completed"
                ? "✓"
                : t.status === "in_progress"
                  ? "►"
                  : t.status === "cancelled"
                    ? "✗"
                    : "○";
            return `${g} [${t.status}] ${t.content}`;
          });
          dispatch({ type: "system", text: lines.join("\n"), level: "info" });
          return;
        }
        case "diff": {
          dispatch({
            type: "system",
            text: gitDiffSummary(sessionRef.current.workdir),
            level: "info",
          });
          return;
        }
        case "export": {
          const items = stateRef.current.items;
          const body = items
            .map((it) => formatItemForExport(it))
            .filter(Boolean)
            .join("\n\n");
          const file = path.join(
            sessionRef.current.workdir,
            `roamsocket-transcript-${Date.now()}.txt`,
          );
          writeFileSync(file, body || "(empty transcript)\n", "utf8");
          dispatch({ type: "system", text: `Wrote ${file}`, level: "info" });
          return;
        }
        case "permission": {
          const mode =
            cmd.mode ?? cyclePermissionMode(sessionRef.current.currentPermissionMode);
          await sessionRef.current.setPermissionMode(mode);
          updateCliSecrets({ permissionMode: mode });
          dispatch({ type: "permission_mode", mode });
          dispatch({ type: "system", text: `Permission mode → ${mode}`, level: "info" });
          return;
        }
        case "effort": {
          if (!cmd.effort) {
            const m = sessionRef.current.currentModel;
            dispatch({
              type: "system",
              text: `Effort: ${m.effort}. Usage: /effort low|medium|high`,
              level: "info",
            });
            return;
          }
          updateCliSecrets({ effort: cmd.effort });
          const next = resolveModelSelection({
            provider: sessionRef.current.currentModel.provider,
            model: sessionRef.current.currentModel.model,
            mock,
            secrets: loadCliSecrets(),
          });
          // force effort from command
          next.effort = cmd.effort;
          await sessionRef.current.setModel(next);
          dispatch({ type: "model", provider: next.provider, model: next.model });
          dispatch({
            type: "system",
            text: `Effort → ${cmd.effort}`,
            level: "info",
          });
          return;
        }
        case "model": {
          if (!cmd.provider && !cmd.model) {
            const m = sessionRef.current.currentModel;
            dispatch({
              type: "system",
              text: `Model: ${m.provider}/${m.model} · effort ${m.effort}${mock ? " (mock)" : ""}`,
              level: "info",
            });
            return;
          }
          const secrets = loadCliSecrets();
          const provider =
            cmd.provider ?? secrets.provider ?? sessionRef.current.currentModel.provider;
          const modelId =
            cmd.model ?? secrets.model ?? sessionRef.current.currentModel.model;
          updateCliSecrets({ provider, model: modelId });
          const next = resolveModelSelection({
            provider,
            model: modelId,
            mock,
            secrets: loadCliSecrets(),
          });
          if (!mock && !next.apiKey) {
            dispatch({
              type: "system",
              text: `No API key for ${provider}. Set with /keys ${provider} <key> or env.`,
              level: "warn",
            });
          }
          await sessionRef.current.setModel(next);
          dispatch({ type: "model", provider: next.provider, model: next.model });
          dispatch({
            type: "system",
            text: `Model → ${next.provider}/${next.model}`,
            level: "info",
          });
          return;
        }
        case "keys": {
          if (!cmd.provider || !cmd.key) {
            const s = loadCliSecrets();
            const listed = Object.keys(s.providerKeys);
            dispatch({
              type: "system",
              text:
                listed.length > 0
                  ? `Stored keys: ${listed.join(", ")}. Usage: /keys <provider> <key>`
                  : "No stored keys. Usage: /keys <provider> <key>",
              level: "info",
            });
            return;
          }
          setProviderKey(cmd.provider, cmd.key);
          const next = resolveModelSelection({
            provider: cmd.provider,
            mock,
            secrets: loadCliSecrets(),
          });
          await sessionRef.current.setModel(next);
          dispatch({ type: "model", provider: next.provider, model: next.model });
          dispatch({
            type: "system",
            text: `Saved key for ${cmd.provider} (not shown). Fetching models for /model completions…`,
            level: "info",
          });
          void refreshModelCatalog();
          return;
        }
        case "metal": {
          const action = cmd.action;
          if (action.op === "help") {
            dispatch({ type: "system", text: metalHelpText(), level: "info" });
            return;
          }
          if (action.op === "browse" || action.op === "list") {
            setMetalBrowserBusy(null);
            setMetalBrowserOpen(true);
            return;
          }
          if (action.op === "runtime") {
            const text = await formatMetalRuntimeStatus();
            dispatch({ type: "system", text, level: "info" });
            return;
          }
          if (action.op === "install-runtime") {
            await metalInstallRuntime();
            return;
          }
          if (action.op === "download") {
            await metalDownload(action.query);
            return;
          }
          if (action.op === "delete") {
            await metalDelete(action.query);
            return;
          }
          if (action.op === "use") {
            await metalUse(action.query);
            return;
          }
          return;
        }
        case "unknown":
          dispatch({
            type: "system",
            text: `Unknown command: ${cmd.raw}. Try /help — Tab completes while typing /…`,
            level: "warn",
          });
          return;
        case "agent": {
          if (!mock) {
            const prov = sessionRef.current.currentModel.provider;
            const isMetal = prov === "localMetal" || prov === "local-metal";
            if (!isMetal) {
              const key = resolveApiKey(prov);
              if (!key) {
                dispatch({
                  type: "system",
                  text: "No API key. Use /keys <provider> <key>, set env, APC_MOCK=1, or /metal use <model>.",
                  level: "error",
                });
                return;
              }
            } else if (!sessionRef.current.currentModel.model?.trim()) {
              dispatch({
                type: "system",
                text: "No Metal model selected. /metal list then /metal use <name> or /metal download <name>.",
                level: "error",
              });
              return;
            }
          }
          dispatch({ type: "user_submit", text: cmd.text });
          const sendP = sessionRef.current.send(cmd.text);
          activeSendRef.current = sendP;
          try {
            await sendP;
          } catch (err) {
            dispatch({ type: "local_error", message: (err as Error).message });
          } finally {
            if (activeSendRef.current === sendP) activeSendRef.current = null;
          }
          return;
        }
      }
    },
    [
      mock,
      quit,
      refreshModelCatalog,
      server,
      metalInstallRuntime,
      metalDownload,
      metalDelete,
      metalUse,
    ],
  );

  useInput((input, key) => {
    // Metal browser owns most keys while open (see MetalBrowser useInput).
    // Still allow Ctrl+C to quit from the browser overlay.
    if (metalBrowserOpen) {
      if (key.ctrl && input === "c") void quit();
      return;
    }

    if (state.helpOpen && (key.escape || input === "q" || key.return)) {
      dispatch({ type: "toggle_help" });
      return;
    }

    if (state.pendingPermission) {
      if (input === "y" || input === "Y" || key.return) {
        resolvePerm("allow");
        return;
      }
      if (input === "n" || input === "N" || key.escape) {
        resolvePerm("deny");
        return;
      }
      return;
    }

    if (key.ctrl && input === "c") {
      void quit();
      return;
    }

    if (key.escape) {
      if (state.busy || sessionRef.current.isRunning) {
        sessionRef.current.interrupt();
        void (async () => {
          const inflight = activeSendRef.current;
          await sessionRef.current.waitUntilIdle();
          if (inflight) await inflight.catch(() => {});
          dispatch({ type: "interrupt" });
        })();
      }
      return;
    }

    // Tab: accept / cycle slash completions
    if (key.tab && completions.length > 0) {
      if (key.shift) {
        setCompletionIndex((i) =>
          i <= 0 ? completions.length - 1 : i - 1,
        );
      } else if (completions.length === 1 || activeCompletion) {
        // First Tab with multiple options: cycle highlight; second Tab on same?
        // UX: Tab applies highlighted completion; Shift+Tab cycles.
        // When multiple, Tab cycles then user hits Enter… better: Tab always applies.
        const pick = activeCompletion ?? completions[0]!;
        replaceDraft(applySlashCompletion(draft, pick.token));
        setCompletionIndex(0);
      }
      return;
    }

    // Arrow up/down cycle completions when slash menu open
    if (completions.length > 0 && key.upArrow) {
      setCompletionIndex((i) => (i <= 0 ? completions.length - 1 : i - 1));
      return;
    }
    if (completions.length > 0 && key.downArrow) {
      setCompletionIndex((i) => (i + 1) % completions.length);
      return;
    }

    // Transcript scroll (Claude Code–style history). Prefer PageUp/PageDown;
    // Ctrl+Up/Ctrl+Down also work. Wheel is not reliable across terminals.
    if (key.pageUp || (key.ctrl && key.upArrow)) {
      setScrollBack((n) => n + 8);
      return;
    }
    if (key.pageDown || (key.ctrl && key.downArrow)) {
      setScrollBack((n) => Math.max(0, n - 8));
      return;
    }
    // Ctrl+Home / g-style: jump to live tail
    if (key.ctrl && input === "g") {
      setScrollBack(0);
      return;
    }

    // —— Composer cursor navigation (macOS-style + readline) ——
    // Word left: Option/Alt+Left, Ctrl+Left, Meta+b (ESC b)
    // Word right: Option/Alt+Right, Ctrl+Right, Meta+f (ESC f)
    // Line start: Home, Cmd+Left (super), Ctrl+a
    // Line end: End, Cmd+Right (super), Ctrl+e
    const wordMod = key.meta || key.ctrl;

    if (key.home || (key.super && key.leftArrow) || (key.ctrl && input === "a")) {
      setCursor(moveLineStart());
      return;
    }
    if (key.end || (key.super && key.rightArrow) || (key.ctrl && input === "e")) {
      setCursor(moveLineEnd(draft));
      return;
    }
    if (
      (key.leftArrow && wordMod && !key.super) ||
      (key.meta && input === "b")
    ) {
      setCursor(moveWordLeft(draft, cursor));
      return;
    }
    if (
      (key.rightArrow && wordMod && !key.super) ||
      (key.meta && input === "f")
    ) {
      setCursor(moveWordRight(draft, cursor));
      return;
    }
    if (key.leftArrow) {
      setCursor(moveCharLeft(cursor));
      return;
    }
    if (key.rightArrow) {
      setCursor(moveCharRight(draft, cursor));
      return;
    }

    // Word/line deletes (Option+Backspace, Ctrl+w, Meta+d, Ctrl+k/u)
    if (
      (key.backspace && (key.meta || key.ctrl || key.super)) ||
      (key.ctrl && input === "w")
    ) {
      applyEdit(deleteWordBackward(draft, cursor));
      return;
    }
    if ((key.delete && (key.meta || key.ctrl)) || (key.meta && input === "d")) {
      applyEdit(deleteWordForward(draft, cursor));
      return;
    }
    if (key.ctrl && input === "k") {
      applyEdit(deleteToLineEnd(draft, cursor));
      return;
    }
    if (key.ctrl && input === "u") {
      applyEdit(deleteToLineStart(draft, cursor));
      return;
    }
    if (key.ctrl && input === "d") {
      applyEdit(deleteForward(draft, cursor));
      return;
    }
    if (key.ctrl && input === "b") {
      setCursor(moveCharLeft(cursor));
      return;
    }
    if (key.ctrl && input === "f") {
      setCursor(moveCharRight(draft, cursor));
      return;
    }

    // Busy: only allow starting a meta slash line in the draft, not agent text send.
    // Still allow editing draft while busy so user can type /mobile etc.
    const agentBusy = state.busy || sessionRef.current.isRunning;

    if (key.return) {
      const toSend = draft;
      // If slash menu open and draft is only a prefix, apply completion first
      if (completions.length > 0 && activeCompletion && toSend.startsWith("/")) {
        const onlyCmd = !toSend.includes(" ") || toSend.endsWith(" ");
        // Apply completion only when the draft is a pure prefix of the token
        if (
          activeCompletion.token.startsWith(toSend) &&
          activeCompletion.token !== toSend &&
          onlyCmd
        ) {
          replaceDraft(activeCompletion.token);
          return;
        }
      }
      replaceDraft("");
      void handleSubmit(toSend);
      return;
    }

    if (key.backspace) {
      applyEdit(deleteBackward(draft, cursor));
      return;
    }
    if (key.delete) {
      applyEdit(deleteForward(draft, cursor));
      return;
    }

    if (input && !key.ctrl && !key.meta && !key.super) {
      // While busy, still allow composing (especially /commands)
      void agentBusy;
      applyEdit(insertText(draft, cursor, input));
    }
  });

  // Full viewport under Ink alternateScreen (see main.ts). Yoga needs an
  // explicit height for flexGrow; clamp so we never pass 0 on teardown / odd TTYs.
  const termRows = Math.max(rows || 24, 4);
  const termCols = Math.max(columns || 80, 20);

  /**
   * Build the full item list (incl. live stream), then window it for the
   * terminal body. Compact tool/diff rows ≈ 1 line each so we can show more
   * history without flooding.
   */
  const activity = useMemo(() => deriveActivity(state), [state]);

  const allStreamItems = useMemo(() => {
    const items = [...state.items];
    if (state.streamingText) {
      const { thinking, content, isThinkingOpen } = extractThinking(state.streamingText);
      // Live thinking block (chat-style) while tags stream in.
      if (thinking !== null || isThinkingOpen) {
        items.push({
          id: "stream-thinking",
          kind: "thinking" as const,
          text: thinking ?? "",
          open: isThinkingOpen,
        });
      }
      if (content.trim()) {
        items.push({
          id: "stream",
          kind: "assistant" as const,
          text: content,
        });
      }
    }
    return items;
  }, [state.items, state.streamingText]);

  // Reserve rows for chrome: status bar (~3), composer (~2), footer (~1),
  // optional permission / completions / tasks / scroll hint.
  const chromeRows =
    6 +
    (state.pendingPermission ? 5 : 0) +
    (completions.length > 0 ? Math.min(completions.length, 6) + 2 : 0) +
    (state.tasks.length > 0 ? Math.min(state.tasks.length, 6) + 2 : 0) +
    (scrollBack > 0 ? 1 : 0);
  const bodyRows = Math.max(4, termRows - chromeRows);
  // Cap how many items we paint; each is mostly 1 line now.
  const maxVisibleItems = Math.max(bodyRows, 8);

  const { visibleItems, hiddenAbove, followingLive } = useMemo(() => {
    const total = allStreamItems.length;
    if (total === 0) {
      return { visibleItems: [] as StreamItem[], hiddenAbove: 0, followingLive: true };
    }
    const maxBack = Math.max(0, total - maxVisibleItems);
    const back = Math.min(scrollBack, maxBack);
    const end = total - back;
    const start = Math.max(0, end - maxVisibleItems);
    return {
      visibleItems: allStreamItems.slice(start, end),
      hiddenAbove: start,
      followingLive: back === 0,
    };
  }, [allStreamItems, maxVisibleItems, scrollBack]);

  // Clamp scrollBack when the stream shrinks (clear / fewer items).
  useEffect(() => {
    const total = allStreamItems.length;
    const maxBack = Math.max(0, total - maxVisibleItems);
    if (scrollBack > maxBack) setScrollBack(maxBack);
  }, [allStreamItems.length, maxVisibleItems, scrollBack]);

  // New user turn pins the transcript to the live tail.
  useEffect(() => {
    const last = state.items[state.items.length - 1];
    if (last?.kind === "user") setScrollBack(0);
  }, [state.items]);

  const activeMetalHub =
    state.provider === "localMetal" || state.provider === "local-metal"
      ? state.model
      : null;

  if (metalBrowserOpen) {
    return (
      <MetalBrowser
        width={termCols}
        height={termRows}
        activeHubID={activeMetalHub}
        busyLabel={metalBrowserBusy}
        refreshKey={metalRefreshKey}
        onClose={() => {
          setMetalBrowserOpen(false);
          setMetalBrowserBusy(null);
        }}
        onDownload={(hubID) => {
          void metalDownload(hubID);
        }}
        onCancelDownload={metalCancelDownload}
        onUse={(hubID) => {
          void metalUse(hubID);
        }}
        onDelete={(hubID) => {
          void metalDelete(hubID);
        }}
        onInstallRuntime={() => {
          void metalInstallRuntime();
        }}
      />
    );
  }

  if (state.helpOpen) {
    return (
      <Box flexDirection="column" height={termRows} width={termCols} padding={1}>
        <Text color={theme.accent} bold>
          RoamSocket — help
        </Text>
        <Box flexGrow={1} flexDirection="column" minHeight={0} overflow="hidden">
          <Text>{formatHelpText()}</Text>
        </Box>
        <Text color={theme.muted}>Press Enter or Esc to close</Text>
      </Box>
    );
  }

  return (
    <Box flexDirection="column" height={termRows} width={termCols} overflow="hidden">
      <StatusBar state={state} mock={mock} activity={activity} spinFrame={spinFrame} />
      {/* flexGrow fills remaining terminal height under the status bar; minHeight 0 lets Yoga shrink. */}
      <Box
        flexDirection="column"
        flexGrow={1}
        flexShrink={1}
        paddingX={1}
        minHeight={0}
        overflow="hidden"
      >
        {scrollBack > 0 && (
          <Text color={theme.muted}>
            ↑ {hiddenAbove > 0 ? `${hiddenAbove} older · ` : ""}
            scrolled · PgDn / Ctrl+↓ follow live · Ctrl+g tail
          </Text>
        )}
        {visibleItems.length === 0 ? (
          <Box flexDirection="column" marginY={1}>
            <Text color={theme.muted}>
              RoamSocket coding agent · work in {shortPath(state.workdir)}
            </Text>
            <Text color={theme.muted}>
              Type a task and press Enter. /help · /mobile for phone QR. Pair code{" "}
              {formatPairCode(state.pairingCode)}.
            </Text>
          </Box>
        ) : (
          visibleItems.map((item) => <StreamRow key={item.id} item={item} />)
        )}
        {/*
          Chat-style live chrome while waiting for tokens.
          Skip when a live thinking stream row or tool row already carries the signal.
        */}
        {followingLive &&
          (activity.kind === "loading" ||
            (activity.kind === "thinking" && !state.streamingText.trim())) && (
            <ActivityIndicator activity={activity} frame={spinFrame} />
          )}
        {!followingLive && state.busy && (
          <Text color={theme.muted}>… new output below · Ctrl+g to follow</Text>
        )}
        {state.tasks.length > 0 && (
          <Box
            flexDirection="column"
            marginTop={1}
            borderStyle="round"
            borderColor={theme.border}
            paddingX={1}
          >
            <Text color={theme.accent} bold>
              Tasks
            </Text>
            {state.tasks.slice(0, 8).map((t) => (
              <Text key={t.id} color={theme.muted}>
                {statusGlyph(t.status)} {t.content}
              </Text>
            ))}
            {state.tasks.length > 8 ? (
              <Text color={theme.muted}>… +{state.tasks.length - 8} more</Text>
            ) : null}
          </Box>
        )}
      </Box>

      {state.pendingPermission && (
        <Box
          flexDirection="column"
          borderStyle="round"
          borderColor={theme.warning}
          paddingX={1}
          marginX={1}
          flexShrink={0}
        >
          <Text color={theme.warning} bold>
            Allow tool?
          </Text>
          <Text>
            {state.pendingPermission.tool}: {state.pendingPermission.summary}
          </Text>
          <Text color={theme.muted}>[y] allow  [n] deny</Text>
        </Box>
      )}

      {completions.length > 0 && (
        <Box
          flexDirection="column"
          borderStyle="round"
          borderColor={theme.accent}
          paddingX={1}
          marginX={1}
          marginBottom={0}
          flexShrink={0}
        >
          <Text color={theme.muted}>
            Completions · Tab accept · ↑↓ cycle
          </Text>
          {completions.map((c, i) => (
            <CompletionRow
              key={`${c.token}-${i}`}
              item={c}
              active={i === (completionIndex % completions.length)}
            />
          ))}
        </Box>
      )}

      <Box borderStyle="single" borderColor={theme.border} paddingX={1} flexShrink={0}>
        <Text color={theme.accent}>{"> "}</Text>
        <ComposerText draft={draft} cursor={cursor} showCursor={!state.busy || draft.length > 0} />
      </Box>
      <Box paddingX={1} flexShrink={0}>
        <Text color={theme.muted}>
          {state.busy
            ? "Esc interrupt · PgUp/PgDn scroll · /mobile /pair /help"
            : "PgUp/PgDn scroll · Enter send · Tab complete · Ctrl+C quit"}
        </Text>
      </Box>
    </Box>
  );
}

function ComposerText({
  draft,
  cursor,
  showCursor,
}: {
  draft: string;
  cursor: number;
  showCursor: boolean;
}) {
  const c = clampCursor(draft, cursor);
  const before = draft.slice(0, c);
  const at = c < draft.length ? draft[c]! : " ";
  const after = c < draft.length ? draft.slice(c + 1) : "";

  if (!showCursor) {
    return <Text>{draft}</Text>;
  }

  return (
    <Text>
      {before}
      <Text backgroundColor={theme.accent} color={theme.background}>
        {at}
      </Text>
      {after}
    </Text>
  );
}

function CompletionRow({
  item,
  active,
}: {
  item: SlashCompletion;
  active: boolean;
}) {
  return (
    <Text>
      <Text color={active ? theme.accent : theme.muted} bold={active}>
        {active ? "› " : "  "}
        {item.token.trimEnd()}
      </Text>
      <Text color={theme.muted}>  {item.description}</Text>
    </Text>
  );
}

function statusGlyph(status: string): string {
  if (status === "completed") return "✓";
  if (status === "in_progress") return "►";
  if (status === "cancelled") return "✗";
  return "○";
}

function formatItemForExport(item: StreamItem): string {
  switch (item.kind) {
    case "user":
      return `you › ${item.text}`;
    case "assistant":
      return `assistant › ${item.text}`;
    case "thinking":
      return `thinking › ${item.text || "(in progress)"}`;
    case "tool": {
      const st =
        item.ok === true ? "ok" : item.ok === false ? "fail" : "…";
      const extra = item.result ? ` — ${item.result}` : "";
      return `${toolDisplayName(item.name)} ${item.summary} · ${st}${extra}`;
    }
    case "diff":
      return `± ${item.path}  +${item.added} −${item.removed}`;
    case "goal":
      return `goal › ${item.text}`;
    case "system":
      return `· ${item.text}`;
    default:
      return "";
  }
}

const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] as const;

function ActivityIndicator({
  activity,
  frame,
}: {
  activity: ReturnType<typeof deriveActivity>;
  frame: number;
}) {
  if (activity.kind === "idle" || activity.kind === "streaming" || activity.kind === "permission") {
    return null;
  }
  const spin = SPINNER_FRAMES[frame % SPINNER_FRAMES.length]!;
  const dots = ".".repeat((frame % 3) + 1).padEnd(3, " ");
  const color =
    activity.kind === "loading"
      ? theme.warning
      : activity.kind === "tool"
        ? theme.tool
        : theme.muted;

  if (activity.kind === "tool") {
    return (
      <Text color={color}>
        {spin} Running {toolDisplayName(activity.label)}
        {activity.detail ? ` ${activity.detail}` : ""}
      </Text>
    );
  }

  // loading | thinking — chat-style "Thinking …" / "Loading model …"
  return (
    <Text color={color}>
      {spin} {activity.label}
      {activity.detail ? ` · ${activity.detail}` : ""}
      {dots}
    </Text>
  );
}

/** Friendly tool labels (Claude Code: Read / Bash / Write). */
function toolDisplayName(name: string): string {
  switch (name) {
    case "read_file":
      return "Read";
    case "write_file":
      return "Write";
    case "edit_file":
    case "str_replace":
      return "Edit";
    case "bash":
      return "Bash";
    case "grep":
    case "search":
      return "Search";
    case "list_dir":
    case "glob":
      return "List";
    case "update_tasks":
      return "Tasks";
    default:
      return name;
  }
}

function StatusBar({
  state,
  mock,
  activity,
  spinFrame,
}: {
  state: TuiState;
  mock: boolean;
  activity: ReturnType<typeof deriveActivity>;
  spinFrame: number;
}) {
  const pair = formatPairCode(state.pairingCode);
  const spin =
    activity.kind !== "idle" && activity.kind !== "streaming"
      ? `${SPINNER_FRAMES[spinFrame % SPINNER_FRAMES.length]} `
      : "";
  const statusColor =
    activity.kind === "loading"
      ? theme.warning
      : activity.kind === "thinking" || activity.kind === "tool"
        ? theme.accent
        : theme.muted;
  const statusText =
    activity.kind === "idle"
      ? state.statusLine
      : activity.kind === "streaming"
        ? state.statusLine
        : activity.label + (activity.detail ? ` · ${activity.detail}` : "");

  return (
    <Box
      borderStyle="single"
      borderColor={theme.border}
      paddingX={1}
      width="100%"
      flexGrow={0}
      flexShrink={0}
      justifyContent="space-between"
      gap={1}
      overflow="hidden"
    >
      {/* minWidth 0 + truncate: long paths must shrink instead of clipping the bar */}
      <Box flexShrink={1} flexGrow={1} minWidth={0} overflow="hidden">
        <Text wrap="truncate">
          <Text color={theme.accent} bold>
            RoamSocket
          </Text>
          <Text color={theme.muted}> · </Text>
          <Text color={theme.text}>{shortPath(state.workdir)}</Text>
        </Text>
      </Box>
      <Box flexShrink={1} flexGrow={0} minWidth={0} overflow="hidden">
        <Text wrap="truncate">
          <Text color={theme.muted}>
            {state.provider}/{state.model}
            {mock ? " mock" : ""}
          </Text>
          <Text color={theme.muted}> · </Text>
          <Text color={theme.warning}>{state.permissionMode}</Text>
          <Text color={theme.muted}> · </Text>
          <Text color={theme.success}>:{state.serverPort}</Text>
          <Text color={theme.muted}> pair </Text>
          <Text color={theme.accent}>{pair}</Text>
          <Text color={theme.muted}> · </Text>
          <Text color={statusColor}>
            {spin}
            {statusText}
          </Text>
        </Text>
      </Box>
    </Box>
  );
}

function StreamRow({ item }: { item: TuiState["items"][number] }) {
  switch (item.kind) {
    case "user":
      return (
        <Box marginY={0}>
          <Text color={theme.user} bold>
            you ›{" "}
          </Text>
          <Text color={theme.text}>{item.text}</Text>
        </Box>
      );
    case "assistant":
      return (
        <Box marginY={0} flexDirection="column">
          <Text>
            <Text color={theme.accent}>✦ </Text>
            <Text color={theme.assistant}>{item.text}</Text>
          </Text>
        </Box>
      );
    case "thinking": {
      // Chat-style thinking row: muted clock + summary (or live "Thinking…")
      const body = item.text.trim();
      const preview = body
        ? body.length > 100
          ? `${body.slice(0, 100).replace(/\s+/g, " ")}…`
          : body.replace(/\s+/g, " ")
        : item.open
          ? "Thinking…"
          : "Thought process";
      return (
        <Text color={theme.muted}>
          ◐ {preview}
        </Text>
      );
    }
    case "tool": {
      // Single-line Claude Code style: "● Write path · ok" — no borders, no dumps.
      const status =
        item.ok === true ? "ok" : item.ok === false ? "fail" : "…";
      const statusColor =
        item.ok === true
          ? theme.success
          : item.ok === false
            ? theme.error
            : theme.muted;
      const label = toolDisplayName(item.name);
      const detail = item.summary
        .replace(/^(read|write|edit|bash|grep|search|list)\s*:\s*/i, "")
        .replace(new RegExp(`^${item.name}\\s*[:\\s]*`, "i"), "")
        .trim();
      return (
        <Text>
          <Text color={theme.tool}>● </Text>
          <Text color={theme.tool}>{label}</Text>
          {detail ? <Text color={theme.muted}> {detail}</Text> : null}
          <Text color={theme.muted}> · </Text>
          <Text color={statusColor}>{status}</Text>
          {item.result ? (
            <Text color={theme.error}> — {item.result}</Text>
          ) : null}
        </Text>
      );
    }
    case "diff":
      return (
        <Text>
          <Text color={theme.success}>± </Text>
          <Text color={theme.muted}>{item.path}</Text>
          <Text color={theme.success}> +{item.added}</Text>
          <Text color={theme.error}> −{item.removed}</Text>
        </Text>
      );
    case "goal":
      return <Text color={theme.accent}>◎ {item.text}</Text>;
    case "system": {
      const color =
        item.level === "error"
          ? theme.error
          : item.level === "warn"
            ? theme.warning
            : theme.muted;
      // Keep system blasts readable but don't force multi-line chrome.
      const text =
        item.text.length > 500 ? `${item.text.slice(0, 500)}…` : item.text;
      return <Text color={color}>{text}</Text>;
    }
    default:
      return null;
  }
}
