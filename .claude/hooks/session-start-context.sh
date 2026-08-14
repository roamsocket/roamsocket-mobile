#!/usr/bin/env bash
# SessionStart hook: print repo state so a fresh agent has live context.
#
# Wired in .claude/settings.json under hooks.SessionStart. Runs at the start
# of every agent session so the model sees:
#   - current branch + last commit
#   - working-tree status (uncommitted changes, stashes)
#   - toolchain versions on PATH (node, npm, xcodegen, swift, fswatch)
#   - whether desktop-server/node_modules + ios/.build exist (deps installed?)
#
# Output goes to stdout (Claude Code injects it as session context). Failures
# are silent — never block session start because a tool is missing.

set -uo pipefail

# Resolve repo root from our own location so this works in worktrees.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

emit() { printf '%s\n' "$*"; }

emit "── RoamSocket repo context ──"

# Git state
if command -v git >/dev/null 2>&1; then
  cd "$REPO_ROOT"
  branch="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo '(detached)')"
  emit "branch:   $branch"
  emit "last:     $(git log -1 --pretty='%h %s (%an, %ar)')"
  dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  stashes="$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$dirty" -gt 0 ]]; then
    emit "status:   $dirty uncommitted file(s)"
  else
    emit "status:   clean"
  fi
  if [[ "$stashes" -gt 0 ]]; then
    emit "stashes:  $stashes"
  fi
  # Surface .worktrees presence so agent knows other sessions are live.
  wt="$(find "$REPO_ROOT/.worktrees" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$wt" -gt 0 ]]; then
    emit "worktrees: $wt sibling worktree(s) under .worktrees/"
  fi
fi

# Toolchain versions — only emit if a tool is on PATH; missing is informative.
emit ""
emit "── toolchain ──"
for tool in node npm xcodegen swift swiftformat fswatch python3 jq rg; do
  if command -v "$tool" >/dev/null 2>&1; then
    case "$tool" in
      node|swift) v="$("$tool" --version 2>/dev/null | head -1)" ;;
      npm)        v="$("$tool" --version 2>/dev/null)" ;;
      xcodegen)   v="$("$tool" --version 2>/dev/null)" ;;
      swiftformat) v="$("$tool" --version 2>/dev/null)" ;;
      fswatch)    v="$("$tool" -h 2>&1 | head -1 | sed 's/^[^0-9]*//')" ;;
      python3)    v="$("$tool" --version 2>/dev/null)" ;;
      jq)         v="$("$tool" --version 2>/dev/null)" ;;
      rg)         v="$("$tool" --version 2>/dev/null | head -1)" ;;
    esac
    printf '  %-12s %s\n' "$tool" "$v"
  else
    printf '  %-12s (not on PATH)\n' "$tool"
  fi
done

# Dependency install state — the most common agent stumbling block.
emit ""
emit "── deps ──"
[[ -d "$REPO_ROOT/desktop-server/node_modules" ]] \
  && emit "  desktop-server/node_modules: installed" \
  || emit "  desktop-server/node_modules: MISSING — run: cd desktop-server && npm install"
[[ -d "$REPO_ROOT/ios/AnyProvCore/.build" ]] \
  && emit "  ios/AnyProvCore/.build:      built" \
  || emit "  ios/AnyProvCore/.build:      not built — run: cd ios/AnyProvCore && swift build"
[[ -d "$REPO_ROOT/node_modules" ]] \
  && emit "  root node_modules:           installed" \
  || emit "  root node_modules:           MISSING — run: npm install (root)"

emit ""
emit "── key paths ──"
emit "  docs:      $REPO_ROOT/AGENTS.md  (read this first)"
emit "  research:  $REPO_ROOT/.research/  (read the relevant file before editing that area)"
emit "  protocol:  $REPO_ROOT/docs/protocol.md  (canonical app ↔ server wire spec)"
emit "── end context ──"