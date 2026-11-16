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
# THE FOURTH ONE, and it is the one that bites. The removal engine resolves
# ${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump} and rm -rf's it. Redirecting only
# three left that variable at whatever the DEVELOPER had exported, so running
# this suite on a machine that sets it deleted their real exapump profiles - and
# reported a false FAIL on top. Redirecting HOME hid it by luck, not by design:
# the fallback landed in the sandbox only while nobody had set the variable.
EXAKIT_EXAPUMP_CONFIG_DIR="$HOME/.exapump"
export EXAKIT_HOME EXAKIT_BIN_DIR EXAKIT_EXAPUMP_CONFIG_DIR

# --- stub the externals the engine calls ---------------------------------
info(){ :; }; warn(){ :; }; ok(){ :; }; die(){ echo "die: $*" >&2; exit 1; }
manifest_get(){
    case "$1" in
        runtime.type) echo personal ;;
        # What the install recorded — the only skills the kit may remove. Shaped
        # exactly as manifest_get renders a JSON list (json.dumps spacing).
        components.skills.installed) echo '["local-agent-ready-starter", "exasol-runtime"]' ;;
        *) echo "" ;;
    esac
}
exakit_repo_root(){ return 1; }   # kit copy gone: force the manifest fallback
personal_teardown(){ printf '%s\n' "$*" > "$SANDBOX/marker_personal"; }
exakit_mcp_operation(){ printf '%s\n' "$*" > "$SANDBOX/marker_mcp"; }
# The engine sweeps add-on launchers by registry id; mirror the real registry
# so a machine with the dash-server launcher gets it removed.
exakit_marketplace_addons(){ printf '%s\n' "dash-server|x"; }

# --- pull in only the functions under test --------------------------------
# The engine plus the skills-removal helper it delegates to (shared with the
# selectable uninstall menu).
eval "$(awk '/^_exakit_remove_installed_skills\(\)/{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
eval "$(awk '/^exakit_uninstall_run\(\)/{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"

exakit_uninstall_run "$DRY"
HARNESS
}

seed() { # (re)create the fake install artifacts
    rm -rf "$SANDBOX/home"
    mkdir -p "$SANDBOX/home/.local/bin" \
             "$SANDBOX/home/.claude/skills/local-agent-ready-starter" \
             "$SANDBOX/home/.claude/skills/exasol-runtime" \
             "$SANDBOX/home/.agents/skills/local-agent-ready-starter" \
             "$SANDBOX/home/.claude/skills/somebody-elses-skill" \
             "$SANDBOX/home/.exapump" \
             "$SANDBOX/home/.exasol-starter-kit/pyexasol-venv/bin" \
             "$SANDBOX/home/.exasol-starter-kit/dash-server-venv/bin" \
             "$SANDBOX/home/.exasol-starter-kit/dash-server/instance" \
             "$SANDBOX/home/.exasol-starter-kit/credentials"
    : > "$SANDBOX/home/.local/bin/exasol"
    : > "$SANDBOX/home/.local/bin/exakit"
    : > "$SANDBOX/home/.local/bin/exapump"
    : > "$SANDBOX/home/.local/bin/dash-server"
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
check "real: dash-server venv gone" no "$(exists "$H/.exasol-starter-kit/dash-server-venv")"
check "real: dash-server state gone" no "$(exists "$H/.exasol-starter-kit/dash-server")"
check "real: dash-server bin gone" no "$(exists "$H/.local/bin/dash-server")"
check "real: skill A gone"        no  "$(exists "$H/.claude/skills/local-agent-ready-starter")"
check "real: skill B gone"        no  "$(exists "$H/.claude/skills/exasol-runtime")"
# The discovery folders also hold skills the user installed themselves. The kit
# removes only what its own install recorded — never the whole folder.
check "real: foreign skill kept"  yes "$(exists "$H/.claude/skills/somebody-elses-skill")"
check "real: bystander kept"      yes "$(exists "$H/.local/bin/some-other-tool")"

# --- idempotent: a second real run on the now-empty tree must not error ----
run_engine 0; check "idempotent second run" 0 "$?"

# --- the farewell line has to be pasteable ON THIS PLATFORM ----------------
# THE BUG: a full uninstall on Windows ended by telling the reader to run
# `curl ... | sh`, which Windows does not have. Each side must hand back its
# own form, and neither may point at a raw repository URL - someone
# reinstalling months from now should be sent to the address the product
# publishes, not to a branch of whichever repository built their copy.
echo
echo "the reinstall hint:"
_ic="$( . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1; exakit_install_command )"
case "$_ic" in
    "curl -fsSL https://www.exasol.com/install/starter-kit.sh | sh") _ic_ok=yes ;;
    *) _ic_ok="$_ic" ;;
esac
check "the shell side curls the published installer into sh" "yes" "$_ic_ok"
case "$_ic" in *raw.githubusercontent.com*) _ic_raw=yes ;; *) _ic_raw=no ;; esac
check "and does not point at a raw repository URL" "no" "$_ic_raw"

# The PowerShell twin is asserted from source: this suite is bash, and the one
# thing that must never regress is Windows being handed the shell form.
_psc="$(grep -c 'irm \$(\$script:InstallUrl) | iex' "$ROOT/setup/lib/exakit-common.ps1" 2>/dev/null; true)"
check "the Windows twin hands back the irm form" "1" "$_psc"
_psbad="$(grep -c 'Install it again any time: curl' "$ROOT/setup/exakit.ps1" 2>/dev/null; true)"
check "and Windows is never told to curl into sh" "0" "$_psbad"

# The by-name form accepts exactly the MARKETPLACE ADD-ON ids (the selective
# removal an agent or script can call) and rejects every other piece by name:
# internal component keys like `database` or `mcp_configs` stay menu-only, and
# a rejection must say so rather than "Unknown option" — the id is not an
# option, it is a target uninstall does not take.
echo
echo "uninstall accepts add-on ids and rejects internal piece names:"
for _c in database mcp_configs skills exapump pyexasol; do
    _uout="$(/bin/bash "$ROOT/setup/exakit" uninstall "$_c" --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
    case "$_uout" in
        *"Unknown uninstall target"*) check "exakit uninstall $_c is rejected" "rejected" "rejected" ;;
        *)                            check "exakit uninstall $_c is rejected" "rejected" "ACCEPTED" ;;
    esac
done
# A registered add-on id is a real target. Any of the three honest answers
# passes; the one wrong answer is calling it unknown.
_uout="$(EXAKIT_HOME="$SANDBOX/none-such" /bin/bash "$ROOT/setup/exakit" uninstall dash-server --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
case "$_uout" in
    *"Unknown uninstall target"*|*"Unknown option"*)
        check "exakit uninstall dash-server is a real target" "accepted" "REJECTED" ;;
    *)  check "exakit uninstall dash-server is a real target" "accepted" "accepted" ;;
esac


echo
echo "the EXAKIT_HOME the engine will rm -rf has to be one the kit built:"
# EXAKIT_HOME comes from the ENVIRONMENT and reaches rm -rf. The kit's own WSL
# remedy tells people to export it and keep it exported, so the users most
# likely to have it set permanently are the ones an uninstall would aim
# wherever it happened to point. --yes takes no confirmation at all.
#
# BOTH DIRECTIONS ARE PINNED HERE, because getting the refusal right is only
# half of it: a first cut required manifest.json unconditionally, which refused
# to clean up exactly the broken installs uninstall exists for. The manifest
# proves the case; failing that the directory still has to carry one of the
# kit's own entries, or be empty - and a populated directory that carries
# neither is refused.
_guard() { # _guard <dir> -> ALLOW | REFUSE
    SANDBOX="$SANDBOX" ROOT="$ROOT" TARGET="$1" bash <<'GUARD'
set -u
HOME="$SANDBOX/guard-home"; export HOME
mkdir -p "$HOME"
# The predicate is defined inside exakit_uninstall_run, so pull that function
# out of the source and read the definition from it rather than restating it -
# a copy here would pass while the product drifted.
eval "$(awk '/^ *_un_safe_target\(\) \{/,/^ *\}/' "$ROOT/setup/lib/common.sh")"
if _un_safe_target "$TARGET"; then echo ALLOW; else echo REFUSE; fi
GUARD
}
G="$SANDBOX/guard"; rm -rf "$G"
mkdir -p "$G/installed" && : > "$G/installed/manifest.json"
mkdir -p "$G/broken/logs" "$G/broken/credentials"
mkdir -p "$G/empty"
mkdir -p "$G/etc-like" && : > "$G/etc-like/hosts" && : > "$G/etc-like/passwd"
mkdir -p "$G/project/.git" && : > "$G/project/README.md"
mkdir -p "$G/hidden-only" && : > "$G/hidden-only/.env"
check "a normal install is removable"          "ALLOW"  "$(_guard "$G/installed")"
check "a broken install is still removable"    "ALLOW"  "$(_guard "$G/broken")"
check "an empty kit home is removable"         "ALLOW"  "$(_guard "$G/empty")"
check "an /etc-shaped directory is refused"    "REFUSE" "$(_guard "$G/etc-like")"
check "someone's project directory is refused" "REFUSE" "$(_guard "$G/project")"
check "a directory of hidden files is refused" "REFUSE" "$(_guard "$G/hidden-only")"
check "a relative EXAKIT_HOME is refused"      "REFUSE" "$(_guard "relative/kit")"
check "the filesystem root is refused"         "REFUSE" "$(_guard "/")"
check "the home directory itself is refused"   "REFUSE" "$(_guard "$SANDBOX/guard-home")"

# --- the permission rules: every one the kit ever wrote, and only those ----
# THE BUG: --dry-run promised "the exakit permission rules" would go, and a
# real run left Bash(exakit mcp-validate:*) in all three spellings behind:
# the removal knew only the CURRENT rule set, and mcp-validate (merged into
# mcp-doctor) was written by earlier kits.
echo
echo "uninstall removes every permission rule the kit wrote, and no other:"
_rules() { # _rules -> the allow+deny lists after the removal, one per line
    SANDBOX="$SANDBOX" ROOT="$ROOT" bash <<'RULES'
set -u
HOME="$SANDBOX/rules-home"; export HOME
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "model": "keep-me",
  "permissions": {
    "allow": [
      "Bash(git status:*)",
      "Bash(exakit mcp-validate:*)",
      "Bash(~/.local/bin/exakit mcp-validate:*)",
      "Bash($HOME/.local/bin/exakit mcp-validate:*)",
      "Bash(exakit update-check:*)",
      "Bash(exakit status:*)",
      "Bash(~/.local/bin/exakit skills --json)",
      "mcp__exasol",
      "Bash(exakit-other mcp-validate:*)"
    ],
    "deny": ["Bash(rm -rf:*)", "Bash($HOME/.local/bin/exakit uninstall:*)"]
  }
}
JSON
exakit_can_run_python(){ return 0; }
run_python(){ python3 "$@"; }
eval "$(awk '/^exakit_remove_readonly_allowlist\(\)/{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
exakit_remove_readonly_allowlist
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("model="+d["model"]); [print(r) for r in d["permissions"]["allow"]+d["permissions"]["deny"]]' "$HOME/.claude/settings.json"
RULES
}
_r="$(_rules 2>&1)"
check "the removal counts all eight kit rules" "1" "$(printf '%s\n' "$_r" | grep -cx 'REMOVED 8')"
for _gone in "Bash(exakit mcp-validate:*)" "Bash(~/.local/bin/exakit mcp-validate:*)" \
             "Bash(\$HOME/.local/bin/exakit mcp-validate:*)" "Bash(exakit update-check:*)"; do
    check "legacy rule removed: $_gone" "0" "$(printf '%s\n' "$_r" | grep -cxF "$_gone")"
done
for _kept in "Bash(git status:*)" "Bash(rm -rf:*)" "Bash(exakit-other mcp-validate:*)" "model=keep-me"; do
    check "user entry kept: $_kept" "1" "$(printf '%s\n' "$_r" | grep -cxF "$_kept")"
done

# --- MCP servers the open AI clients still run for the kit -----------------
# THE BUG: Claude Desktop / Claude Code kept their exasol-mcp-server running,
# pointed at the database uninstall had just deleted. Only a process PROVEN to
# be the kit's may be stopped: its environment carries the kit's MCP user and
# a loopback DSN. A second exasol-mcp-server (someone else's) must survive.
# ps is a stub on PATH and the stop is recorded, never sent; the pids are above
# the kernel's pid_max, so no real /proc entry can answer for them.
echo
echo "uninstall stops only the kit's own exasol-mcp-server processes:"
mkdir -p "$SANDBOX/psbin"
cat > "$SANDBOX/psbin/ps" <<'PS'
#!/bin/sh
case "$*" in
    "-axww -o pid=,command=")
        printf '%s\n' "  101 /Applications/Claude.app/Contents/MacOS/Claude" \
            "4999991 /Users/u/.local/bin/uvx exasol-mcp-server@1.2.0" \
            "4999992 /opt/other/uvx exasol-mcp-server@1.2.0" \
            "4999993 grep exasol-mcp-server" ;;
    *"-p 4999991") printf '%s\n' "/Users/u/.local/bin/uvx exasol-mcp-server@1.2.0 PATH=/bin EXA_DSN=127.0.0.1:8563 EXA_USER=mcp_readonly EXA_PASSWORD=x" ;;
    *"-p 4999992") printf '%s\n' "/opt/other/uvx exasol-mcp-server@1.2.0 PATH=/bin EXA_DSN=db.example.com:8563 EXA_USER=analyst" ;;
    *"-p 4999993") printf '%s\n' "grep exasol-mcp-server PATH=/bin" ;;
esac
PS
chmod +x "$SANDBOX/psbin/ps"
_procs() { # _procs <dry> -> what the helper said, then the recorded stops
    SANDBOX="$SANDBOX" ROOT="$ROOT" DRY="$1" bash <<'PROCS'
set -u
PATH="$SANDBOX/psbin:$PATH"
info(){ printf 'INFO %s\n' "$*"; }; ok_step(){ printf 'OK %s\n' "$*"; }
for _fn in _exakit_kit_mcp_server_pids _exakit_stop_pid _exakit_uninstall_mcp_processes; do
    eval "$(awk -v n="$_fn" '$0 ~ ("^" n "\\(\\)") {f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
done
_exakit_stop_pid(){ printf 'KILL %s\n' "$1"; }
_exakit_uninstall_mcp_processes "$DRY"
PROCS
}
_p="$(_procs 1 2>&1)"
check "dry run names the kit's one process" "1" "$(printf '%s\n' "$_p" | grep -cxF 'INFO   will stop: 1 exasol-mcp-server processes (pids 4999991)')"
check "dry run stops nothing" "0" "$(printf '%s\n' "$_p" | grep -c '^KILL')"
_p="$(_procs 0 2>&1)"
check "real run stops the kit's process" "1" "$(printf '%s\n' "$_p" | grep -cx 'KILL 4999991')"
check "and only that one" "1" "$(printf '%s\n' "$_p" | grep -c '^KILL')"
check "and says so" "1" "$(printf '%s\n' "$_p" | grep -c '^OK Stopped .*4999991')"

# --- the closing hints: restart the clients, and uv's cache ----------------
echo
echo "uninstall ends with the restart advice and the uv cache hint:"
_hints() { # _hints <PATH> [dry]
    SANDBOX="$SANDBOX" ROOT="$ROOT" P="$1" D="${2:-0}" bash <<'HINTS'
set -u
HOME="$SANDBOX/hint-home"; EXAKIT_BIN_DIR="$HOME/.local/bin"
mkdir -p "$EXAKIT_BIN_DIR"; printf '#!/bin/sh\n' > "$EXAKIT_BIN_DIR/uv"; chmod +x "$EXAKIT_BIN_DIR/uv"
info(){ printf 'INFO %s\n' "$*"; }
eval "$(awk '/^_exakit_uninstall_closing_hints\(\)/{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
PATH="$P"
_exakit_uninstall_closing_hints "$D"
HINTS
}
_h="$(_hints "/usr/bin:/bin" 2>&1)"
check "the restart advice is printed" "1" "$(printf '%s\n' "$_h" | grep -c 'Restart any AI client that was open')"
check "uv not on PATH: the kit's uv is named" "1" "$(printf '%s\n' "$_h" | grep -cF "$SANDBOX/hint-home/.local/bin/uv cache clean exasol-mcp-server")"
mkdir -p "$SANDBOX/uvbin"; printf '#!/bin/sh\n' > "$SANDBOX/uvbin/uv"; chmod +x "$SANDBOX/uvbin/uv"
_h="$(_hints "$SANDBOX/uvbin:/usr/bin:/bin" 2>&1)"
check "uv on PATH: the bare command" "1" "$(printf '%s\n' "$_h" | grep -cF 'with: uv cache clean exasol-mcp-server')"
# A dry run says nothing: --yes runs the plan first, so hints there printed twice.
_h="$(_hints "$SANDBOX/uvbin:/usr/bin:/bin" 1 2>&1)"
check "dry run: no hints" "0" "$(printf '%s\n' "$_h" | grep -c 'Restart any AI client\|cache clean exasol-mcp-server')"
# Wired into the engine, after the spinner, on both sides.
check "the engine prints the hints (dry-aware)" "1" "$(grep -c '_exakit_uninstall_closing_hints "\$_dry"$' "$ROOT/setup/lib/common.sh")"
check "the engine stops the processes" "1" "$(grep -c '_exakit_uninstall_mcp_processes "\$_dry"$' "$ROOT/setup/lib/common.sh")"

# --- the leftover remedy survives a quote in the path ----------------------
echo
echo "the rm -rf remedy quotes a path that holds a single quote:"
_qdir="$SANDBOX/it's deploy"
mkdir -p "$_qdir/sub"
_r="$(SANDBOX="$SANDBOX" ROOT="$ROOT" Q="$_qdir" bash <<'QUOTE'
set -u
HOME="$SANDBOX/q-home"; EXAKIT_BIN_DIR="$HOME/.local/bin"; EXAKIT_HOME="$HOME/.exasol-starter-kit"
info(){ :; }; warn(){ :; }; error(){ :; }; ok(){ :; }; die(){ exit 1; }
manifest_get(){ :; }; manifest_set(){ :; }; manifest_del(){ :; }
detect_os(){ printf macos; }
EXAKIT_PERSONAL_DEPLOY_DIR="$Q"
source "$ROOT/setup/lib/runtime-personal.sh"
lsof(){ return 0; }
personal_teardown_leftovers "" 1 || :
printf '%s' "$EXAKIT_TEARDOWN_REMEDY"
QUOTE
)"
check "remedy escapes the quote" "rm -rf '$SANDBOX/it'\\''s deploy'" "$_r"
eval "$_r"
check "and pasted, it removes exactly that directory" "0" "$([ -e "$_qdir" ] && echo 1 || echo 0)"
# The no-runtime branch in the engine builds the same remedy the same way.
check "engine no-runtime remedy escapes quotes too" "1" "$(grep -c "EXAKIT_TEARDOWN_REMEDY=\"rm -rf '\$(printf '%s' \"\$_un_dd\" | sed \"s/'/'\\\\\\\\\\\\\\\\''/g\")'\"" "$ROOT/setup/lib/common.sh")"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
