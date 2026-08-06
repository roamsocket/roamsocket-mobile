#!/usr/bin/env bash
# PostToolUse hook: regenerate the Xcode project whenever project.yml is edited.
#
# Wired in .claude/settings.json under hooks.PostToolUse for Edit | Write | MultiEdit.
# Rejects any other file path before doing work.

set -euo pipefail

# Tool input is piped on stdin as JSON. We only care about the file_path.
INPUT="$(cat)"

# Only act on ios/project.yml.
FILE_PATH="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    print("")
')"

if [[ "$FILE_PATH" != "ios/project.yml" ]]; then
  exit 0
fi

# Run from the repo root, regardless of where the parent agent is cd'd.
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

cd "$REPO_ROOT/ios"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found on PATH; skipped project regeneration." >&2
  exit 0
fi

echo "→ xcodegen generate (ios/project.yml changed)"
xcodegen generate
