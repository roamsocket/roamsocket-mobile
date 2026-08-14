#!/usr/bin/env bash
# PostToolUse hook: auto-format edited TS/JS/JSON files with Biome.
#
# Wired in .claude/settings.json. Tool input is piped on stdin as JSON; we
# only act on files with an extension Biome owns, and only when biome + node
# modules are present (no-op otherwise — never block the agent).

set -uo pipefail

INPUT="$(cat)"

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    print("")
')"

# Only act on extensions Biome formats: .ts .tsx .js .jsx .json .mjs .cjs
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json) ;;
  *) exit 0 ;;
esac

# Locate repo root from our own location.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

# Skip if biome isn't installed at the root.
if [[ ! -x "$REPO_ROOT/node_modules/.bin/biome" ]]; then
  exit 0
fi

# Only format the file we just touched — cheap and predictable.
"$REPO_ROOT/node_modules/.bin/biome" format --write "$FILE_PATH" >/dev/null 2>&1 || true
exit 0