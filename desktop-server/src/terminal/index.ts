/**
 * Terminal-over-WebSocket. The desktop spawns a child process in a
 * session's workdir and pipes its stdout/stderr to a WebSocket channel;
 * the iOS app writes keystrokes back over the same channel.
 *
 * NOTE: We use `child_process.spawn` here rather than `node-pty` so the
 * server has no native build step. This means we don't get a real PTY
 * (no `TERM=`, no `isatty`, no colors from `ls --color`). For a true
 * PTY experience, install `node-pty` and swap the implementation.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";

export interface TerminalSession {
  id: string;
  workdir: string;
  proc: ChildProcess;
  buffer: string;
}

const terminals = new Map<string, TerminalSession>();

export function startTerminal(workdir: string, ws: WebSocket): TerminalSession {
  const id = randomUUID();
  const proc = spawn(process.env.SHELL ?? "/bin/zsh", ["-i"], {
    cwd: workdir,
    env: {
      ...process.env,
      PS1: "$ ",
      TERM: "dumb",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const session: TerminalSession = { id, workdir, proc, buffer: "" };
  terminals.set(id, session);

  proc.stdout?.on("data", (data) => sendChunk(ws, id, "out", data));
  proc.stderr?.on("data", (data) => sendChunk(ws, id, "err", data));
  proc.on("exit", (code) => {
    sendControl(ws, id, "exit", code ?? 0);
    terminals.delete(id);
  });

  sendControl(ws, id, "ready", 0);
  return session;
}

export function writeToTerminal(id: string, data: string): void {
  const session = terminals.get(id);
  session?.proc.stdin?.write(data);
}

export function resizeTerminal(id: string, _cols: number, _rows: number): void {
  // child_process has no PTY resize; placeholder for node-pty path.
}

export function killTerminal(id: string): void {
  const session = terminals.get(id);
  if (!session) return;
  session.proc.kill("SIGTERM");
  terminals.delete(id);
}

function sendChunk(ws: WebSocket, id: string, stream: "out" | "err", data: Buffer | string) {
  if (ws.readyState !== ws.OPEN) return;
  ws.send(JSON.stringify({
    type: "terminal_data",
    terminalId: id,
    stream,
    data: typeof data === "string" ? data : data.toString("utf8"),
  }));
}

function sendControl(ws: WebSocket, id: string, event: "ready" | "exit", code: number) {
  if (ws.readyState !== ws.OPEN) return;
  ws.send(JSON.stringify({
    type: "terminal_control",
    terminalId: id,
    event,
    code,
  }));
}
