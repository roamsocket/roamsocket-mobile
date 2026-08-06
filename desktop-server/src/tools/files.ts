import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { glob as globFs } from "node:fs/promises";
import type { Tool, ToolContext, ToolResult } from "./types.js";
import { truncate, resolveInside } from "./types.js";

/** Read a file's contents. */
export const readFileTool: Tool = {
  name: "read_file",
  description: "Read the contents of a file in the repository.",
  inputSchema: {
    type: "object",
    properties: {
      path: { type: "string", description: "Repo-relative path to the file." },
    },
    required: ["path"],
  },
  summarize(input) {
    return `read: ${String(input.path ?? "")}`;
  },
  async execute(input, ctx: ToolContext): Promise<ToolResult> {
    try {
      const abs = resolveInside(ctx.workdir, String(input.path ?? ""));
      const text = await readFile(abs, "utf8");
      return { ok: true, output: truncate(text) };
    } catch (err) {
      return { ok: false, output: (err as Error).message };
    }
  },
};

/** Write (create or overwrite) a file. */
export const writeFileTool: Tool = {
  name: "write_file",
  description:
    "Create a new file or overwrite an existing one with the given contents. Parent directories are created as needed.",
  inputSchema: {
    type: "object",
    properties: {
      path: { type: "string", description: "Repo-relative path to write." },
      content: { type: "string", description: "Full file contents." },
    },
    required: ["path", "content"],
  },
  summarize(input) {
    return `write: ${String(input.path ?? "")}`;
  },
  async execute(input, ctx: ToolContext): Promise<ToolResult> {
    try {
      const abs = resolveInside(ctx.workdir, String(input.path ?? ""));
      await mkdir(path.dirname(abs), { recursive: true });
      await writeFile(abs, String(input.content ?? ""), "utf8");
      return { ok: true, output: `Wrote ${input.path}` };
    } catch (err) {
      return { ok: false, output: (err as Error).message };
    }
  },
};

/** Exact-string replacement, exact-string edit semantics. */
export const editTool: Tool = {
  name: "edit_file",
  description:
    "Replace an exact string in a file with new text. The old string must appear exactly once unless replaceAll is true.",
  inputSchema: {
    type: "object",
    properties: {
      path: { type: "string", description: "Repo-relative path to edit." },
      oldString: { type: "string", description: "Exact text to replace." },
      newString: { type: "string", description: "Replacement text." },
      replaceAll: { type: "boolean", description: "Replace every occurrence." },
    },
    required: ["path", "oldString", "newString"],
  },
  summarize(input) {
    return `edit: ${String(input.path ?? "")}`;
  },
  async execute(input, ctx: ToolContext): Promise<ToolResult> {
    try {
      const abs = resolveInside(ctx.workdir, String(input.path ?? ""));
      const oldString = String(input.oldString ?? "");
      const newString = String(input.newString ?? "");
      const replaceAll = Boolean(input.replaceAll);
      const text = await readFile(abs, "utf8");

      const count = oldString === "" ? 0 : text.split(oldString).length - 1;
      if (count === 0) {
        return { ok: false, output: "oldString not found in file." };
      }
      if (count > 1 && !replaceAll) {
        return {
          ok: false,
          output: `oldString appears ${count} times; pass replaceAll:true or make it unique.`,
        };
      }
      const updated = replaceAll
        ? text.split(oldString).join(newString)
        : text.replace(oldString, newString);
      await writeFile(abs, updated, "utf8");
      return { ok: true, output: `Edited ${input.path} (${count} replacement${count > 1 ? "s" : ""})` };
    } catch (err) {
      return { ok: false, output: (err as Error).message };
    }
  },
};

/** List files matching a glob pattern. */
export const globTool: Tool = {
  name: "glob",
  description: "Find files matching a glob pattern (e.g. src/**/*.ts).",
  inputSchema: {
    type: "object",
    properties: {
      pattern: { type: "string", description: "Glob pattern to match." },
    },
    required: ["pattern"],
  },
  summarize(input) {
    return `glob: ${String(input.pattern ?? "")}`;
  },
  async execute(input, ctx: ToolContext): Promise<ToolResult> {
    try {
      const pattern = String(input.pattern ?? "**/*");
      const matches: string[] = [];
      for await (const entry of globFs(pattern, { cwd: ctx.workdir })) {
        matches.push(typeof entry === "string" ? entry : String(entry));
        if (matches.length >= 500) break;
      }
      return { ok: true, output: truncate(matches.sort().join("\n") || "(no matches)") };
    } catch (err) {
      return { ok: false, output: (err as Error).message };
    }
  },
};
