#!/usr/bin/env bash
# watch-xcode.sh — regenerate the Xcode project whenever files in ios/ change.
#
# Why: .xcodeproj is generated from project.yml (xcodegen). Any new Swift file
# dropped into App/Sources/ won't appear in Xcode until the project is regenerated.
# This script watches the iOS folder and reruns xcodegen on demand.
#
# Usage:
#   ./scripts/watch-xcode.sh          # foreground, Ctrl+C to stop
#   ./scripts/watch-xcode.sh --once   # run xcodegen once and exit (no watching)
#
# Notes:
# - Only triggers on files that affect the project (Swift, project.yml, assets).
# - Debounces bursts of writes (saves, git pull) so we don't regen 50 times.
# - Stops immediately on the first regen failure so you can see the error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Files that affect the project. Anything else (Pods, .build, derived data) is ignored.
WATCH_PATTERNS=(
  "*.swift"
  "*.m"
  "*.h"
  "*.c"
  "*.cpp"
  "*.modulemap"
  "project.yml"
  "*.xcassets"
  "*.storyboard"
  "*.xib"
)

IGNORE_PATTERNS=(
  "\\.build/"
  "build/"
  "DerivedData/"
  "RoamSocket\\.xcodeproj/"  # generated — don't watch the generated output
  "\\.swiftpm/"
  "\\.git/"
)

# Debounce window: collapse bursts of file events into one regen.
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-1}"

# Skip regen if the only changes were inside the just-regenerated xcodeproj.
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-2}"

regenerate() {
  echo "→ xcodegen generate"
  if ! (cd "$IOS_DIR" && xcodegen generate); then
    echo "✗ xcodegen failed; stopping watcher so you can see the error." >&2
    exit 1
  fi
  echo "✓ project regenerated"
}

run_once() {
  regenerate
  exit 0
}

run_watch() {
  if ! command -v fswatch >/dev/null 2>&1; then
    echo "fswatch not found. Install with: brew install fswatch" >&2
    exit 1
  fi

  # Mark the moment we last regenerated so we can ignore the burst of writes
  # xcodegen itself produces inside .xcodeproj/.
  LAST_REGEN=0

  echo "👀 watching $IOS_DIR (Ctrl+C to stop)"
  echo "   patterns: ${WATCH_PATTERNS[*]}"
  echo "   ignore:   ${IGNORE_PATTERNS[*]}"

  # Build fswatch args.
  local -a fsw_args=(-r -l "$DEBOUNCE_SECONDS" --event=Created --event=Updated --event=Removed)
  for p in "${IGNORE_PATTERNS[@]}"; do
    fsw_args+=(-e "$p")
  done
  for p in "${WATCH_PATTERNS[@]}"; do
    fsw_args+=(-i "$p")
  done

  fswatch "${fsw_args[@]}" "$IOS_DIR" | while read -r _; do
    local now
    now="$(date +%s)"
    if (( now - LAST_REGEN < COOLDOWN_SECONDS )); then
      continue
    fi
    LAST_REGEN=$now
    regenerate
  done
}

case "${1:-}" in
  --once) run_once ;;
  --help|-h)
    sed -n '2,12p' "$0"
    echo ""
    echo "Flags: --once (run once, no watch), --help"
    ;;
  "") run_watch ;;
  *) echo "Unknown arg: $1 (try --help)" >&2; exit 2 ;;
esac
