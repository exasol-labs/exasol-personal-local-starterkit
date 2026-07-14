#!/usr/bin/env bash
# uninstall.sh — regression test for exakit_uninstall_run in setup/lib/common.sh.
# Runs the removal engine against a fully sandboxed fake $HOME so it never
# touches a real install. Verifies: dry-run removes nothing; a real run deletes
# skills, exapump, the kit home, and the CLI binaries AND invokes the database
# teardown + MCP config removal; and that it is idempotent on an empty machine.
#
#   bash tests/uninstall.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}
exists() { [ -e "$1" ] && echo yes || echo no; }

# Build the fake install tree and drive the engine inside one sandboxed bash.
# All state (fake HOME, stubs, markers) lives under $SANDBOX.
run_engine() { # run_engine <dry> ; prints nothing, side effects in $SANDBOX
    SANDBOX="$SANDBOX" ROOT="$ROOT" DRY="$1" bash <<'HARNESS'
set -u
HOME="$SANDBOX/home"
export HOME
EXAKIT_HOME="$HOME/.exasol-starter-kit"
EXAKIT_BIN_DIR="$HOME/.local/bin"
export EXAKIT_HOME EXAKIT_BIN_DIR

# --- stub the externals the engine calls ---------------------------------
info(){ :; }; warn(){ :; }; ok(){ :; }; die(){ echo "die: $*" >&2; exit 1; }
manifest_get(){ [ "$1" = "runtime.type" ] && echo personal || echo ""; }
exakit_repo_root(){ return 1; }   # force the fallback skill-name list
nano_teardown(){ echo "$SANDBOX/called_nano_teardown $*" > "$SANDBOX/marker_nano"; }
personal_teardown(){ printf '%s\n' "$*" > "$SANDBOX/marker_personal"; }
exakit_mcp_operation(){ printf '%s\n' "$*" > "$SANDBOX/marker_mcp"; }

# --- pull in only the function under test --------------------------------
eval "$(awk '/^exakit_uninstall_run\(\)/{f=1} f{print} f&&/^}/{exit}' "$ROOT/setup/lib/common.sh")"

exakit_uninstall_run "$DRY"
HARNESS
}

seed() { # (re)create the fake install artifacts
    rm -rf "$SANDBOX/home"
    mkdir -p "$SANDBOX/home/.local/bin" \
             "$SANDBOX/home/.claude/skills/local-agent-ready-starter" \
             "$SANDBOX/home/.claude/skills/trusted-ai-workflow" \
             "$SANDBOX/home/.agents/skills/local-agent-ready-starter" \
             "$SANDBOX/home/.exapump" \
             "$SANDBOX/home/.exasol-starter-kit/pyexasol-venv/bin" \
             "$SANDBOX/home/.exasol-starter-kit/credentials"
    : > "$SANDBOX/home/.local/bin/exasol"
    : > "$SANDBOX/home/.local/bin/exakit"
    : > "$SANDBOX/home/.local/bin/exapump"
    : > "$SANDBOX/home/.exapump/config.toml"
    : > "$SANDBOX/home/.exasol-starter-kit/manifest.json"
    # A bystander app must survive: exapump/kit removal must not touch it.
    : > "$SANDBOX/home/.local/bin/some-other-tool"
    rm -f "$SANDBOX"/marker_*
}

echo "exakit_uninstall_run:"

# --- dry run: nothing removed, no teardown invoked -------------------------
seed
run_engine 1
H="$SANDBOX/home"
check "dry: kit home kept"        yes "$(exists "$H/.exasol-starter-kit")"
check "dry: exasol bin kept"      yes "$(exists "$H/.local/bin/exasol")"
check "dry: skill kept"           yes "$(exists "$H/.claude/skills/local-agent-ready-starter")"
check "dry: no db teardown"       no  "$(exists "$SANDBOX/marker_personal")"

# --- real run: everything removed, teardown + mcp removal invoked ----------
seed
run_engine 0
check "real: db teardown called"  yes "$(exists "$SANDBOX/marker_personal")"
check "real: teardown got --data" "--data" "$(cat "$SANDBOX/marker_personal" 2>/dev/null)"
check "real: mcp removal called"  yes "$(exists "$SANDBOX/marker_mcp")"
check "real: mcp got uninstall"   "uninstall" "$(cat "$SANDBOX/marker_mcp" 2>/dev/null)"
check "real: kit home gone"       no  "$(exists "$H/.exasol-starter-kit")"
check "real: pyexasol venv gone"  no  "$(exists "$H/.exasol-starter-kit/pyexasol-venv")"
check "real: exapump gone"        no  "$(exists "$H/.exapump")"
check "real: exasol bin gone"     no  "$(exists "$H/.local/bin/exasol")"
check "real: exakit bin gone"     no  "$(exists "$H/.local/bin/exakit")"
check "real: exapump bin gone"    no  "$(exists "$H/.local/bin/exapump")"
check "real: skill A gone"        no  "$(exists "$H/.claude/skills/local-agent-ready-starter")"
check "real: skill B gone"        no  "$(exists "$H/.claude/skills/trusted-ai-workflow")"
check "real: bystander kept"      yes "$(exists "$H/.local/bin/some-other-tool")"

# --- idempotent: a second real run on the now-empty tree must not error ----
run_engine 0; check "idempotent second run" 0 "$?"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
