import { spawn } from "node:child_process";
import type { Tool, ToolContext, ToolResult } from "./types.js";
import { truncate } from "./types.js";

/** Run a shell command in the session workdir, streaming stdout/stderr. */
export const bashTool: Tool = {
  name: "bash",
  description:
    "Run a bash command in the repository working directory. Use for building, testing, running scripts, and inspecting the project. Output is captured and returned.",
  inputSchema: {
    type: "object",
    properties: {
      command: { type: "string", description: "The bash command to run." },
      timeoutMs: {
        type: "number",
        description: "Optional timeout in milliseconds (default 120000).",
      },
    },
    required: ["command"],
  },
  summarize(input) {
    const cmd = String(input.command ?? "");
    return `bash: ${cmd.length > 80 ? cmd.slice(0, 80) + "…" : cmd}`;
  },
  execute(input, ctx: ToolContext): Promise<ToolResult> {
    const command = String(input.command ?? "");
    const timeoutMs = Number(input.timeoutMs ?? 120_000);
    return new Promise((resolve) => {
      const child = spawn("bash", ["-lc", command], {
        cwd: ctx.workdir,
        env: process.env,
      });
      let out = "";
      const append = (chunk: Buffer) => {
        const s = chunk.toString();
        out += s;
        ctx.onOutput?.(s);
      };
      child.stdout.on("data", append);
      child.stderr.on("data", append);

      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        out += `\n[timed out after ${timeoutMs}ms]`;
      }, timeoutMs);

      child.on("error", (err) => {
        clearTimeout(timer);
        resolve({ ok: false, output: truncate(`${out}\n${err.message}`) });
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        const status = code === 0 ? "" : `\n[exit code ${code}]`;
        resolve({ ok: code === 0, output: truncate(out + status) });
      });
    });
  },
};
