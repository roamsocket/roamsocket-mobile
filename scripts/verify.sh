#!/usr/bin/env bash
# verify.sh — one-shot verification for the area you touched.
#
# Usage:
#   ./scripts/verify.sh                 # default: all checks
#   ./scripts/verify.sh --ios           # just iOS structural + core tests
#   ./scripts/verify.sh --server        # just desktop-server typecheck + smoke
#   ./scripts/verify.sh --protocol      # TS schema + Swift Codable + docs sanity
#   ./scripts/verify.sh --no-smoke      # skip the smoke (it's slow + uses ports)
#
# Why: agents need a single command that runs "the smallest relevant check"
# without having to remember each path. See AGENTS.md → "Verification checklist
# before claiming done" for the human version of this.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- args ----------
RUN_IOS=1
RUN_SERVER=1
RUN_PROTOCOL=1
RUN_SMOKE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ios)       RUN_SERVER=0; RUN_PROTOCOL=0; RUN_SMOKE=0 ;;
    --server)    RUN_IOS=0;    RUN_PROTOCOL=0 ;;
    --protocol)  RUN_IOS=0;    RUN_SERVER=0;  RUN_SMOKE=0 ;;
    --no-smoke)  RUN_SMOKE=0 ;;
    --help|-h)
      sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------- colors (only if attached to a TTY) ----------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

ok()    { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
fail()  { printf '  %s✗%s %s\n' "$RED"   "$RESET" "$*"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
section(){ printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }

FAILED=0
SKIPPED=0

run_step() {
  # run_step "<label>" <command...>
  local label="$1"; shift
  printf '%srunning: %s%s\n' "$DIM" "$label" "$RESET"
  if "$@"; then
    ok "$label"
  else
    fail "$label"
    FAILED=$((FAILED + 1))
  fi
}

# ---------- preflight ----------
section "preflight"
if ! command -v node >/dev/null 2>&1; then
  fail "node on PATH"; exit 1
fi
ok "node $(node --version)"
if ! command -v npm >/dev/null 2>&1; then
  fail "npm on PATH"; exit 1
fi
ok "npm $(npm --version)"
if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen $(xcodegen --version)"
else
  warn "xcodegen not on PATH (needed only if you touched ios/)"
fi
if command -v swift >/dev/null 2>&1; then
  ok "swift $(swift --version | head -1)"
else
  warn "swift not on PATH (needed only if you touched AnyProvCore)"
fi

# ---------- iOS ----------
if [[ "$RUN_IOS" -eq 1 ]]; then
  section "iOS"
  if command -v xcodegen >/dev/null 2>&1; then
    run_step "xcodegen generate (idempotent — should produce no diff if project.yml unchanged)" \
      bash -c "cd '$REPO_ROOT/ios' && xcodegen generate >/dev/null && git diff --exit-code RoamSocket.xcodeproj >/dev/null"
  fi
  if command -v swift >/dev/null 2>&1; then
    if [[ -d "$REPO_ROOT/ios/AnyProvCore" ]]; then
      run_step "swift test (AnyProvCore)" \
        bash -c "cd '$REPO_ROOT/ios/AnyProvCore' && swift test >/dev/null 2>&1"
    else
      warn "ios/AnyProvCore not found — skipping"
      SKIPPED=$((SKIPPED + 1))
    fi
  fi
fi

# ---------- desktop-server ----------
if [[ "$RUN_SERVER" -eq 1 ]]; then
  section "desktop-server"
  if [[ ! -d "$REPO_ROOT/desktop-server/node_modules" ]]; then
    warn "desktop-server/node_modules missing — skipping typecheck (run: cd desktop-server && npm install)"
    SKIPPED=$((SKIPPED + 1))
  else
    run_step "tsc --noEmit (server)" \
      bash -c "cd '$REPO_ROOT/desktop-server' && npx tsc -p tsconfig.json --noEmit >/dev/null 2>&1"
    run_step "tsc (electron)" \
      bash -c "cd '$REPO_ROOT/desktop-server' && npx tsc -p tsconfig.electron.json --noEmit >/dev/null 2>&1"
  fi
fi

# ---------- protocol ----------
if [[ "$RUN_PROTOCOL" -eq 1 ]]; then
  section "wire protocol sanity"
  PROTOCOL_TS="$REPO_ROOT/desktop-server/src/protocol.ts"
  PROTOCOL_SWIFT=$(find "$REPO_ROOT/ios/AnyProvCore" -name "Protocol.swift" -path "*/Server/*" 2>/dev/null | head -1)
  PROTOCOL_DOC="$REPO_ROOT/docs/protocol.md"

  if [[ -f "$PROTOCOL_TS" && -f "$PROTOCOL_SWIFT" && -f "$PROTOCOL_DOC" ]]; then
    ok "all three files present (TS + Swift + docs)"
    # Cheap sanity: extract union-member identifiers from TS and confirm at
    # least one matches the Swift Codable enum. Not exhaustive — catches
    # the most common "I only updated one side" mistake.
    TS_MEMBERS=$(grep -oE "z\.[a-zA-Z]+\.literal\(['\"][a-zA-Z_]+['\"]" "$PROTOCOL_TS" 2>/dev/null | sed -E "s/.*['\"]([a-zA-Z_]+)['\"]/\1/" | sort -u)
    SWIFT_MEMBERS=$(grep -oE "case [a-zA-Z_]+" "$PROTOCOL_SWIFT" 2>/dev/null | sed -E "s/case //" | sort -u)
    if [[ -n "$TS_MEMBERS" && -n "$SWIFT_MEMBERS" ]]; then
      MISSING=$(comm -23 <(echo "$TS_MEMBERS") <(echo "$SWIFT_MEMBERS") | head -5)
      if [[ -z "$MISSING" ]]; then
        ok "TS message identifiers all have Swift case counterparts (sample)"
      else
        warn "TS message identifiers with no Swift case counterpart (first 5): $MISSING"
      fi
    fi
  else
    warn "protocol triple incomplete: TS=$([[ -f "$PROTOCOL_TS" ]] && echo y || echo n) Swift=$([[ -f "$PROTOCOL_SWIFT" ]] && echo y || echo n) docs=$([[ -f "$PROTOCOL_DOC" ]] && echo y || echo n)"
    SKIPPED=$((SKIPPED + 1))
  fi
fi

# ---------- smoke ----------
if [[ "$RUN_SMOKE" -eq 1 ]]; then
  section "smoke (offline e2e)"
  if [[ ! -d "$REPO_ROOT/desktop-server/node_modules" ]]; then
    warn "desktop-server/node_modules missing — skipping smoke"
    SKIPPED=$((SKIPPED + 1))
  elif [[ -n "$(lsof -i :4319 2>/dev/null)" ]]; then
    warn "port 4319 already in use — skipping smoke (kill the holder or use --no-smoke)"
    SKIPPED=$((SKIPPED + 1))
  else
    run_step "APC_MOCK=1 npm run smoke" \
      bash -c "cd '$REPO_ROOT/desktop-server' && APC_MOCK=1 npm run smoke >/dev/null 2>&1"
  fi
fi

# ---------- summary ----------
section "summary"
if [[ "$FAILED" -eq 0 ]]; then
  printf '%s✓ all checks passed%s' "$GREEN$BOLD" "$RESET"
  [[ "$SKIPPED" -gt 0 ]] && printf ' %s(%d skipped)%s' "$DIM" "$SKIPPED" "$RESET"
  printf '\n'
  exit 0
else
  printf '%s✗ %d check(s) failed%s\n' "$RED$BOLD" "$FAILED" "$RESET"
  exit 1
fi