/**
 * Non-interactive mock agent probe for CI / verification.
 * Usage: tsx scripts/cli-oneshot.ts <workdir> [prompt]
 */
import { runOneShot } from "../src/cli/main.js";

const workdir = process.argv[2] ?? process.cwd();
const text = process.argv[3] ?? "create a notes file";

const r = await runOneShot({ text, workdir, mock: true });
const assistant = r.messages
  .filter((m) => m.type === "assistant_delta")
  .map((m) => (m.type === "assistant_delta" ? m.text : ""))
  .join("");
const tools = r.messages
  .filter((m) => m.type === "tool_call")
  .map((m) => (m.type === "tool_call" ? m.tool : ""));

console.log(
  JSON.stringify({
    ok: r.ok,
    types: r.messages.map((m) => m.type),
    tools,
    assistant,
  }),
);
process.exit(r.ok && tools.length > 0 ? 0 : 1);
