#!/usr/bin/env bash
# Core setup tasks: the work a kit release adds that only the installer can do,
# and how an already-installed kit picks it up through `exakit update`.
#
#   1. tasks.json vs core_tasks.completed - the bookkeeping, its exit codes,
#      and that its writes share the manifest lock with the shell's writers.
#   2. The installer rerun - found in the kit copy (or the checkout it came
#      from), told it is a rerun, never nested, its exit code passed back.
#   3. `exakit update`'s two checks - hand the run to a freshly downloaded
#      kit; then rerun the installer once when a task is pending, but never
#      for a scoped update, never inside a rerun, and never by starting a
#      stopped database behind the user's back.
#   4. The installer's seventh step - where it sits, that it never joins
#      steps_completed, what an update-started rerun does not ask again, and
#      that the kit copy carries what `exakit update` reads.
#
#   bash tests/core-setup.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; printf '         expected: %s\n         actual:   %s\n' "$2" "$3"; fi
}
has() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1"; printf '         missing: %s\n         in: %.300s\n' "$2" "$3" ;; esac
}
lacks() {
    case "$3" in *"$2"*) fail "$1"; printf '         unexpected: %s\n' "$2" ;; *) pass "$1" ;; esac
}

command -v python3 >/dev/null 2>&1 || { echo "python3 is required for this suite"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# HOME is the sandbox's too, and no profile edit. kit_shared_steps below runs
# the install's closing steps, whose exakit helper step ends in
# ensure_path_hint - an append to the user's shell profile. A stub is all that
# stood between that and the developer's own ~/.zshrc.
HOME="$WORK/userhome"
EXAKIT_NO_PROFILE_EDIT=1
export HOME EXAKIT_NO_PROFILE_EDIT
mkdir -p "$HOME"
MANAGE="$ROOT/setup/core/manage.py"
RERUN="$ROOT/setup/core/rerun-installer.py"

printf '\n== the shipped task list ==\n'
check "tasks.json lists the preprocessor as a database task" "preprocessor" \
    "$(python3 "$MANAGE" tasks --tasks "$ROOT/setup/core/tasks.json" --scope database)"
check "no kit-scope task yet" "" "$(python3 "$MANAGE" tasks --tasks "$ROOT/setup/core/tasks.json" --scope kit)"
for _t in $(python3 "$MANAGE" tasks --tasks "$ROOT/setup/core/tasks.json"); do
    if grep -q "^exakit_core_task_${_t}()" "$ROOT/setup/lib/core-setup.sh"; then
        pass "task $_t has a bash handler (exakit_core_task_$_t)"
    else
        fail "task $_t has no bash handler (exakit_core_task_$_t in core-setup.sh)"
    fi
    if grep -q "\"$_t\" *= *\"Invoke-ExakitCoreTask" "$ROOT/setup/lib/core-setup.ps1" 2>/dev/null; then
        pass "task $_t has a PowerShell handler"
    else
        fail "task $_t has no PowerShell handler in core-setup.ps1's handler map"
    fi
done

printf '\n== pending, complete, status ==\n'
T="$WORK/tasks.json"
cat > "$T" <<'EOF'
{"tasks": [{"name": "preprocessor", "scope": "database"}, {"name": "local_log_rotation", "scope": "kit"}]}
EOF
M="$WORK/manifest.json"
printf '{"components": {}, "steps_completed": ["launcher"]}\n' > "$M"
check "a manifest with no record: everything pending, in file order" "preprocessor local_log_rotation" \
    "$(python3 "$MANAGE" pending --tasks "$T" --manifest "$M" | tr '\n' ' ' | sed 's/ $//')"
check "...filtered by scope" "local_log_rotation" "$(python3 "$MANAGE" pending --tasks "$T" --manifest "$M" --scope kit)"
python3 "$MANAGE" complete --tasks "$T" --manifest "$M" preprocessor
python3 "$MANAGE" complete --tasks "$T" --manifest "$M" preprocessor
check "complete is idempotent" '["preprocessor"]' \
    "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["core_tasks"]["completed"]))' "$M")"
check "...and leaves steps_completed alone" '["launcher"]' \
    "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["steps_completed"]))' "$M")"
check "pending now names only what is left" "local_log_rotation" "$(python3 "$MANAGE" pending --tasks "$T" --manifest "$M")"
check "status says the same as JSON" '["local_log_rotation"]' \
    "$(python3 "$MANAGE" status --tasks "$T" --manifest "$M" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["pending"]))')"
python3 "$MANAGE" complete --tasks "$T" --manifest "$M" not_a_task 2>/dev/null
check "an unknown name is refused (exit 2) and not recorded" "2 1" \
    "$? $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["core_tasks"]["completed"]))' "$M")"
# GNU first: GNU stat -f is the FILESYSTEM form, succeeds and prints junk,
# so a BSD-first chain never reached its fallback on Linux.
check "the manifest stays owner-only" "600" "$(stat -c '%a' "$M" 2>/dev/null || stat -f '%Lp' "$M")"

python3 "$MANAGE" pending --tasks "$T" --manifest "$WORK/none.json" 2>/dev/null
check "no manifest: exit 3" "3" "$?"
printf '{"broken' > "$WORK/broken.json"
python3 "$MANAGE" pending --tasks "$T" --manifest "$WORK/broken.json" 2>/dev/null
check "a manifest that does not parse: exit 4" "4" "$?"
python3 "$MANAGE" complete --tasks "$T" --manifest "$WORK/broken.json" preprocessor 2>/dev/null
check "...and nothing is written over it" '{"broken' "$(cat "$WORK/broken.json")"
for _bad in '{"tasks": [{"name": "a", "scope": "database"}, {"name": "a", "scope": "kit"}]}' \
            '{"tasks": [{"name": "Bad-Name", "scope": "kit"}]}' \
            '{"tasks": [{"name": "a", "scope": "elsewhere"}]}' \
            '{"no_tasks": []}'; do
    printf '%s\n' "$_bad" > "$WORK/bad-tasks.json"
    python3 "$MANAGE" tasks --tasks "$WORK/bad-tasks.json" >/dev/null 2>&1
    check "a malformed task list is refused (exit 2): $_bad" "2" "$?"
done

printf '\n== core-task writes and the shell writers share one lock ==\n'
# common.sh derives the manifest path from the home, so the file lives there.
mkdir -p "$WORK/lock-home"
L="$WORK/lock-home/manifest.json"
printf '{"components": {}}\n' > "$L"
cat > "$WORK/many-tasks.json" <<'EOF'
{"tasks": [
EOF
_i=0; while [ "$_i" -lt 15 ]; do
    printf '{"name": "t%s", "scope": "kit"}%s\n' "$_i" "$([ "$_i" -lt 14 ] && echo ,)" >> "$WORK/many-tasks.json"
    _i=$((_i + 1))
done
printf ']}\n' >> "$WORK/many-tasks.json"
_pids=""
_i=0; while [ "$_i" -lt 15 ]; do
    python3 "$MANAGE" complete --tasks "$WORK/many-tasks.json" --manifest "$L" "t$_i" & _pids="$_pids $!"
    ( EXAKIT_HOME="$WORK/lock-home"
      . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
      manifest_set "components.c$_i.version" "1.$_i" >/dev/null 2>&1 ) & _pids="$_pids $!"
    _i=$((_i + 1))
done
for _p in $_pids; do wait "$_p"; done
check "15 task completions and 15 manifest_set writes in parallel: none lost" "15 15" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["core_tasks"]["completed"]), len([k for k in d["components"] if k.startswith("c")]))' "$L")"

printf '\n== the installer rerun ==\n'
FK="$WORK/fake-kit"
mkdir -p "$FK/setup"
cat > "$FK/setup/setup-macos.sh" <<EOF
printf 'RERUN=%s BANNER=%s SOURCE=%s EXAPUMP=%s\n' "\${EXAKIT_CORE_RERUN:-}" "\${EXAKIT_BANNER_SHOWN:-}" "\${EXAKIT_KIT_SOURCE:-}" "\${EXAKIT_EXAPUMP_VERSION:-}" > "$WORK/rerun-env"
if [ -t 0 ]; then echo tty; else read -r _l && echo "stdin:\$_l" || echo no-stdin; fi >> "$WORK/rerun-env"
exit \${FAKE_INSTALLER_RC:-0}
EOF
cp "$FK/setup/setup-macos.sh" "$FK/setup/setup-linux.sh"
EXAKIT_KIT_SOURCE="exasol-labs/kit@main" python3 "$RERUN" --platform macos --kit-root "$FK" --no-stdin </dev/null
check "the kit copy's installer runs, exit 0" "0" "$?"
has "...told it is a rerun" "RERUN=1" "$(cat "$WORK/rerun-env")"
has "...with the banner already shown" "BANNER=1" "$(cat "$WORK/rerun-env")"
has "...the kit source passed through" "SOURCE=exasol-labs/kit@main" "$(cat "$WORK/rerun-env")"
has "...and no stdin under --no-stdin" "no-stdin" "$(cat "$WORK/rerun-env")"
FAKE_INSTALLER_RC=5 python3 "$RERUN" --platform linux --kit-root "$FK" --no-stdin </dev/null
check "the installer's exit code comes back" "5" "$?"
python3 "$RERUN" --platform macos --kit-root "$WORK/empty" --fallback-root "$FK" --no-stdin </dev/null
check "a kit copy without setup scripts falls back to the checkout" "0" "$?"
python3 "$RERUN" --platform macos --kit-root "$WORK/empty" --no-stdin 2>/dev/null </dev/null
check "no installer anywhere: exit 7" "7" "$?"
EXAKIT_CORE_RERUN=1 python3 "$RERUN" --platform macos --kit-root "$FK" --no-stdin 2>/dev/null </dev/null
check "never from inside a rerun: exit 6" "6" "$?"

printf '\n== exakit update: the pending-task check ==\n'
# A sandboxed install whose kit copy carries the real setup/core and a stub
# installer that records how it was called and completes the task the way the
# real step does - through manage.py, after "its checks".
U="$WORK/upd"
mkdir -p "$U/home/kit/setup" "$U/home/kit/mcp" "$U/home/bin"
cp -R "$ROOT/setup/core" "$U/home/kit/setup/"
cat > "$U/home/kit/setup/setup-macos.sh" <<EOF
echo "ran \${EXAKIT_CORE_RERUN:-0} \${EXAKIT_PERSONAL_VERSION:-unpinned}" >> "$U/installer-calls"
[ "\${FAKE_TASK_FAILS:-0}" = 1 ] || python3 "$U/home/kit/setup/core/manage.py" complete --tasks "$U/home/kit/setup/core/tasks.json" --manifest "$U/home/manifest.json" preprocessor
exit 0
EOF
cp "$U/home/kit/setup/setup-macos.sh" "$U/home/kit/setup/setup-linux.sh"
upd() {
    ( EXAKIT_HOME="$U/home"
      EXAKIT_MANIFEST="$U/home/manifest.json"
      EXAKIT_BIN_DIR="$U/home/bin"
      . "$ROOT/setup/lib/common.sh"
      . "$ROOT/setup/lib/detect.sh"
      . "$ROOT/setup/lib/runtime-personal.sh"
      . "$ROOT/setup/lib/core-setup.sh"
      detect_os() { printf 'macos\n'; }
      personal_deployment_running() { [ "${FAKE_DB_UP:-1}" = 1 ]; }
      exakit_component_current() { case "$1" in personal) printf '2.3.0\n' ;; *) return 1 ;; esac; }
      EXAKIT_UPDATE_RESULTS="$U/results"; export EXAKIT_UPDATE_RESULTS
      "$@"
      printf 'RC=%s ACTED=%s\n' "$?" "${EXAKIT_CORE_UPDATE_ACTED:-unset}" )
}
fresh_upd() {
    printf '{"components": {}, "kit": {"source": "exasol-labs/kit@main"}}\n' > "$U/home/manifest.json"
    rm -f "$U/installer-calls" "$U/results"
}

fresh_upd
_o="$(upd exakit_core_update_check exapump 2>&1)"
check "a scoped update (exakit update exapump) never reruns the installer" "no" "$([ -f "$U/installer-calls" ] && echo yes || echo no)"

fresh_upd
_o="$(upd exakit_core_update_check "exapump mcp" 2>&1)"
check "...nor does one naming several components without the kit" "no" "$([ -f "$U/installer-calls" ] && echo yes || echo no)"

fresh_upd
_o="$(upd exakit_core_update_check "exapump exakit" 2>&1)"
check "several ids with the kit among them (exakit update exapump exakit) check the tasks" "ran 1 2.3.0" "$(cat "$U/installer-calls" 2>/dev/null)"

fresh_upd
_o="$(EXAKIT_CORE_RERUN=1 upd exakit_core_update_check all 2>&1)"
check "nor does a check inside a rerun" "no" "$([ -f "$U/installer-calls" ] && echo yes || echo no)"

fresh_upd
_o="$(FAKE_DB_UP=0 upd exakit_core_update_check all 2>&1)"
check "a database task with the database stopped is deferred, not forced" "no" "$([ -f "$U/installer-calls" ] && echo yes || echo no)"
has "...with the command that finishes it" "exakit start" "$_o"
has "...booked as deferred for --json" "core-setup|deferred||preprocessor|exakit start && exakit update" "$(cat "$U/results")"

fresh_upd
_o="$(upd exakit_core_update_check all 2>&1)"
check "a pending task reruns the installer exactly once" "ran 1 2.3.0" "$(cat "$U/installer-calls")"
has "...pinned to the installed versions, as a rerun" "RC=0 ACTED=1" "$_o"
has "...and says what it finished" "New setup completed: preprocessor" "$_o"
has "...booked as updated" "core-setup|updated||preprocessor|" "$(cat "$U/results")"

rm -f "$U/installer-calls" "$U/results"
_o="$(upd exakit_core_update_check all 2>&1)"
check "with nothing pending, nothing runs" "no" "$([ -f "$U/installer-calls" ] && echo yes || echo no)"
has "...and the run is not counted as work" "RC=0 ACTED=0" "$_o"

fresh_upd
_o="$(FAKE_TASK_FAILS=1 upd exakit_core_update_check all 2>&1)"
has "an installer that did not complete the task: exit 1" "RC=1" "$_o"
has "...with the retry" "Retry with: exakit update" "$_o"
has "...booked as failed" "core-setup|failed||preprocessor|exakit update" "$(cat "$U/results")"

printf '\n== exakit update: the handover to a freshly downloaded kit ==\n'
cat > "$U/home/bin/exakit" <<EOF
#!/bin/sh
echo "new-exakit \$* handover=\${EXAKIT_UPDATE_HANDOVER:-0}" >> "$U/handover-calls"
echo "\$#" > "$U/handover-argc"
echo "\${EXAKIT_UPDATE_ROW_FIELDS:-unset}" > "$U/handover-rowfields"
exit \$(cat "$U/handover-rc" 2>/dev/null || echo 4)
EOF
chmod +x "$U/home/bin/exakit"
# ho_run <kit-version-before> <handover-flag> <targets> — _exakit_update_run
# with every component's version and updater stubbed. Defined at top level:
# bash 3.2 cannot parse a case statement inside a command substitution.
ho_run() {
    ( EXAKIT_HOME="$U/home"
      EXAKIT_MANIFEST="$U/home/manifest.json"
      EXAKIT_BIN_DIR="$U/home/bin"
      EXAKIT_UPDATE_HANDOVER="$2"
      . "$ROOT/setup/lib/common.sh"
      . "$ROOT/setup/lib/core-setup.sh"
      printf '{"components": {}, "kit": {"version": "%s"}}\n' "$1" > "$EXAKIT_MANIFEST"
      EXAKIT_VERSION_POLICY=pinned
      exakit_print_versions_source_line() { :; }
      exakit_update_actual_target() { printf '%s\n' "$1"; }
      exakit_component_current() {
          case "$1" in
              exakit) manifest_get kit.version ;;
              *) printf '1.0\n' ;;
          esac
      }
      exakit_component_available() {
          case "$1" in
              exakit) printf '0.3.1\n' ;;
              *) printf '2.0\n' ;;
          esac
      }
      exakit_component_supported() { return 0; }
      exakit_component_is_ahead() { return 1; }
      exakit_component_is_heavy() { return 1; }
      exakit_component_min_kit() { return 1; }
      # Every component here is the kit's own: a component without an ownership
      # receipt is left alone by the update (prod's persona branch).
      exakit_component_is_managed() { return 0; }
      exakit_core_update_check() { echo "core-check $1" >> "$U/handover-calls"; }
      exakit_update_component() {
          echo "updater $1" >> "$U/handover-calls"
          if [ "$1" = exakit ]; then manifest_set kit.version 0.3.1 >/dev/null 2>&1; fi
          return 0
      }
      _exakit_update_run all "$3" >/dev/null 2>&1
      printf 'rc=%s' "$?" )
}
rm -f "$U/handover-calls"
_ho="$(ho_run 0.3.0 0 "exakit exapump mcp")"
check "the old updater updated the kit, then handed the rest over" \
    "updater exakit|new-exakit update all handover=1|" "$(tr '\n' '|' < "$U/handover-calls")"
check "...and its exit code is the new run's" "rc=4" "$_ho"
check "...told that this kit's reader takes the error and hint fields" "7" "$(cat "$U/handover-rowfields")"

# 127 IS THE NEW RUN'S OWN ANSWER. "Is there a new exakit" is asked before the
# handover, so a new run that ends in 127 is not read as "no handover": the old
# process neither defers the components the new run already handled nor runs
# anything after it.
rm -f "$U/handover-calls" "$U/ho-results"
printf '127' > "$U/handover-rc"
: > "$U/ho-results"
_ho="$(EXAKIT_UPDATE_RESULTS="$U/ho-results" ho_run 0.3.0 0 "exakit exapump mcp")"
rm -f "$U/handover-rc"
check "a new run that exits 127: its code stands" "rc=127" "$_ho"
check "...and the old process ran nothing after the handover" \
    "updater exakit|new-exakit update all handover=1|" "$(tr '\n' '|' < "$U/handover-calls")"
lacks "...and booked nothing deferred for it" "|deferred|" "$(cat "$U/ho-results")"

# NO NEW COMMAND: the rest is deferred to the next `exakit update`, and the
# new-setup check is NOT made by this process - it holds the old task list
# and would rerun the old installer.
rm -f "$U/handover-calls" "$U/ho-results"
chmod -x "$U/home/bin/exakit"
: > "$U/ho-results"
_ho="$(EXAKIT_UPDATE_RESULTS="$U/ho-results" ho_run 0.3.0 0 "exakit exapump mcp")"
chmod +x "$U/home/bin/exakit"
check "no new exakit: the kit is updated, nothing after it runs on the old code" \
    "updater exakit|" "$(tr '\n' '|' < "$U/handover-calls")"
has "...the rest is deferred to the next run" "exapump|deferred|1.0|2.0|exakit update" "$(cat "$U/ho-results")"
has "...every one of them" "mcp|deferred|1.0|2.0|exakit update" "$(cat "$U/ho-results")"
lacks "...and the old process makes no new-setup check" "core-check" "$(cat "$U/handover-calls")"

rm -f "$U/handover-calls"
_ho="$(ho_run 0.3.1 1 "exakit exapump mcp")"
check "the handed-over run skips the kit, updates the rest, then checks the tasks" \
    "updater exapump|updater mcp|core-check all|" "$(tr '\n' '|' < "$U/handover-calls")"

rm -f "$U/handover-calls"
_ho="$(ho_run 0.3.1 0 "exakit exapump")"
check "a kit that is already current hands nothing over" "updater exapump|core-check all|" \
    "$(tr '\n' '|' < "$U/handover-calls")"

# SEVERAL IDS (`exakit update exakit exapump`) arrive joined by spaces and must
# reach the new run as several arguments: one joined word is an unknown target.
rm -f "$U/handover-calls" "$U/handover-argc"
( EXAKIT_HOME="$U/home"; EXAKIT_MANIFEST="$U/home/manifest.json"; EXAKIT_BIN_DIR="$U/home/bin"
  . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/core-setup.sh"
  exakit_update_handover "exakit exapump" ) >/dev/null 2>&1
check "several ids reach the new run as several arguments" "3" "$(cat "$U/handover-argc" 2>/dev/null)"
has "...in the order they were typed" "new-exakit update exakit exapump handover=1" "$(cat "$U/handover-calls" 2>/dev/null)"

printf '\n== handover rows: five fields unless the reader declared seven ==\n'
# In a handover the OLD kit reads the rows the NEW kit writes. Kits before the
# error and hint fields unpack exactly five - a sixth field is a ValueError, no
# JSON at all, exit 1. That reader, verbatim from the kits that shipped it:
cat > "$WORK/old-reader.py" <<'EXAKIT_OLD_READER'
import sys
rows = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        parts = line.rstrip("\n").split("|")
        if len(parts) >= 5 and parts[0]:
            rows.append(parts)
out = []
for comp, outcome, cur, avail, remedy in rows:
    out.append("%s %s %s" % (comp, outcome, remedy))
print(";".join(out))
EXAKIT_OLD_READER
# rows_written <handover> <row-fields> - the rows _exakit_update_note writes.
rows_written() {
    ( EXAKIT_HOME="$U/home"
      EXAKIT_MANIFEST="$U/home/manifest.json"
      . "$ROOT/setup/lib/common.sh"
      EXAKIT_UPDATE_RESULTS="$WORK/rows"; : > "$EXAKIT_UPDATE_RESULTS"
      EXAKIT_UPDATE_HANDOVER="$1"; EXAKIT_UPDATE_ROW_FIELDS="$2"
      _exakit_update_note personal failed 2.3.0 2.4.0 "wsl --update" "nft|failed" "run wsl --update"
      _exakit_update_note uv updated 0.13.6 0.13.7
      cat "$EXAKIT_UPDATE_RESULTS" )
}
_rows="$(rows_written 1 "")"
check "a handed-over run with no marker writes five fields" "5;5" \
    "$(printf '%s\n' "$_rows" | awk -F'|' '{printf "%s%s", (NR > 1 ? ";" : ""), NF}')"
printf '%s\n' "$_rows" > "$WORK/rows"
check "...which a five-field reader parses, remedy intact" \
    "personal failed wsl --update;uv updated " "$(python3 "$WORK/old-reader.py" "$WORK/rows" 2>&1)"
_rows="$(rows_written 1 7)"
check "with the marker: seven fields, the separator taken out of the error" \
    "personal|failed|2.3.0|2.4.0|wsl --update|nft/failed|run wsl --update" "$(printf '%s\n' "$_rows" | head -n 1)"
_rows="$(rows_written 0 "")"
check "a run that reads its own rows writes seven" "7" "$(printf '%s\n' "$_rows" | head -n 1 | awk -F'|' '{print NF}')"
# And the reader this kit has takes both shapes.
printf 'personal|failed|2.3.0|2.4.0|wsl --update\nuv|updated|0.13.6|0.13.7|\n' > "$WORK/rows"
_json="$( ( EXAKIT_HOME="$U/home"; EXAKIT_MANIFEST="$U/home/manifest.json"; . "$ROOT/setup/lib/common.sh"
            _exakit_update_json_report "$WORK/rows" 1 ) 2>/dev/null)"
check "this kit's reader takes a five-field row" "failed wsl --update" \
    "$(printf '%s' "$_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["failed"][0]["remedy"])')"

printf '\n== the installer: seven steps, the database step fourth ==\n'
for _s in setup/setup-macos.sh setup/setup-linux.sh; do
    check "$_s delegates steps 3-7" "1" "$(grep -c 'kit_shared_steps 3 7 ' "$ROOT/$_s")"
    check "$_s loads core-setup.sh" "1" "$(grep -c 'LIB_DIR/core-setup.sh' "$ROOT/$_s" | awk '{print ($1 > 0)}')"
    # EVERY offer, not the first one grep finds: the persona close and the
    # plain close each make one.
    _offers="$(grep -c 'exakit_marketplace_offer )' "$ROOT/$_s")"
    _guarded=0
    for _ln in $(grep -n 'exakit_marketplace_offer )' "$ROOT/$_s" | cut -d: -f1); do
        _from=$((_ln - 12)); [ "$_from" -ge 1 ] || _from=1
        sed -n "${_from},${_ln}p" "$ROOT/$_s" | grep -q 'exakit_core_rerun_active' && _guarded=$((_guarded + 1))
    done
    check "$_s keeps every marketplace offer out of an update rerun" "$_offers" "$_guarded"
    lacks "$_s has no step counted out of six" "/6  " "$(cat "$ROOT/$_s")"
done
_win="$(cat "$ROOT/setup/setup-windows.ps1")"
has "Windows has the same fourth step" '"Step 4/7  Configure database features"' "$_win"
lacks "Windows has no step counted out of six" "/6  " "$_win"
has "the exakit command loads core-setup.sh" 'core-setup.sh' "$(cat "$ROOT/setup/exakit")"

K="$WORK/kss"
mkdir -p "$K/kit"
cp "$ROOT/versions.json" "$K/kit/versions.json"
_kss() {
    ( EXAKIT_HOME="$K/home"
      EXAKIT_MANIFEST="$K/home/manifest.json"
      EXAKIT_BIN_DIR="$K/home/bin"
      mkdir -p "$EXAKIT_HOME"
      . "$ROOT/setup/lib/common.sh"
      . "$ROOT/setup/lib/core-setup.sh"
      manifest_init >/dev/null 2>&1
      exapump_install() { :; }
      _exakit_install_exapump() { echo "exapump-step" >> "$K/order"; }
      exakit_core_task_preprocessor() { echo "preprocessor-task" >> "$K/order"; ok_step "fake framework ready"; }
      exakit_maybe_offer_data_load() { echo "data-load-offer" >> "$K/order"; }
      exakit_maybe_offer_mcp_setup() { echo "mcp-offer" >> "$K/order"; }
      exakit_maybe_offer_skills_install() { echo "skills-offer" >> "$K/order"; }
      mcp_install() { :; }
      # The AI bridge step is gated on the launcher's MCP server (prod's sidecar).
      mcp_sidecar_apply() { :; }
      _exakit_install_mcp() { echo "mcp-step" >> "$K/order"; }
      ensure_path_hint() { :; }
      # With persona.sh loaded the data follows the persona question instead.
      [ "${KSS_PERSONA:-0}" = 1 ] && exakit_persona_flow() { :; }
      kit_shared_steps 3 7 "$ROOT/setup" "$ROOT"
      # The exakit helper is the last step, after the persona's data.
      kit_helper_step 7 7 "$ROOT/setup" "$ROOT"
      printf 'COMPLETED=%s\n' "$(manifest_get core_tasks.completed 2>/dev/null | tr -d ' \n')" )
}
rm -rf "$K/home" "$K/order"
_o="$(_kss 2>&1)"
check "order: exapump, the database step, the data load, the AI bridge" \
    "exapump-step|preprocessor-task|data-load-offer|mcp-step|mcp-offer|skills-offer|" "$(tr '\n' '|' < "$K/order")"
for _lbl in "Step 3/7  exapump" "Step 4/7  Configure database features" "Step 5/7  AI bridge" "Step 7/7  exakit helper"; do
    has "the screen counts $_lbl" "$_lbl" "$_o"
done
has "the task is recorded after its step passed" 'COMPLETED=["preprocessor"]' "$_o"
check "the kit copy carries setup/core" "yes" "$([ -f "$K/home/kit/setup/core/tasks.json" ] && echo yes || echo no)"
check "...and setup/preprocessor" "yes" "$([ -f "$K/home/kit/setup/preprocessor/manage.py" ] && echo yes || echo no)"

rm -f "$K/order"
_o="$(_kss 2>&1)"
check "the database step runs again on the next pass (it verifies); finished steps skip" \
    "preprocessor-task|data-load-offer|mcp-offer|skills-offer|" "$(tr '\n' '|' < "$K/order")"

rm -f "$K/order"
_o="$(EXAKIT_CORE_RERUN=1 _kss 2>&1)"
check "an update-started rerun asks none of the first install's questions" \
    "preprocessor-task|" "$(tr '\n' '|' < "$K/order" | sed 's/exapump-step|//')"

# WITH THE PERSONAS the data is not offered inside the shared steps: it follows
# the persona question, which the setup scripts ask after them - and an
# update-started rerun asks neither.
rm -f "$K/order"
_o="$(KSS_PERSONA=1 _kss 2>&1)"
check "with persona.sh, the shared steps offer no data" \
    "preprocessor-task|mcp-offer|skills-offer|" "$(tr '\n' '|' < "$K/order" | sed 's/exapump-step|//')"
for _s in setup/setup-macos.sh setup/setup-linux.sh; do
    has "$_s keeps the persona question out of an update rerun" "exakit_core_rerun_active" \
        "$(grep -B3 'exakit_persona_flow "$KIT_ROOT"' "$ROOT/$_s")"
done
has "Windows keeps the persona question out of an update rerun" 'if ($coreRerun) {' \
    "$(grep -B3 'Invoke-ExakitPersonaFlow -KitRoot' "$ROOT/setup/setup-windows.ps1")"

# THE PERSONA'S ANSWERS ARE NOT APPLIED IN A RERUN EITHER. EXAKIT_PERSONA in
# exakit.env (or the environment) reached an update-started rerun: the persona
# was recorded again, its add-ons went through the scripted offer without a
# question, its services were started, and a persona switched off since made
# every update die. The two blocks are lifted out of each script and run with
# every call they make stood in for, a rerun and a first install side by side.
_persona_probe() { # _persona_probe <script> <rerun 0|1> -> what ran, and ACTIVE
    _pp_apply="$(awk '/^if command -v exakit_core_rerun_active .* exakit_core_rerun_active; then$/{p=1} p{print} p&&/^fi$/{exit}' "$ROOT/$1")"
    _pp_close="$(awk '/^if \[ -n "\$\{EXAKIT_PERSONA_ACTIVE:-\}" \] && \\$/{p=1} p{print} p&&/^fi$/{exit}' "$ROOT/$1")"
    ( exakit_core_rerun_active() { [ "$PP_RERUN" = 1 ]; }
      exakit_persona_apply_env() { printf 'apply|'; EXAKIT_PERSONA_ACTIVE=1; }
      exakit_acquire_lock() { :; }; exakit_release_lock() { :; }
      exakit_autostart_default_on() { printf 'autostart|'; }
      exakit_marketplace_offer() { printf 'offer|'; }
      _exakit_marketplace_cli() { printf 'services|'; }
      exakit_persona_marketplace_note() { :; }
      PP_RERUN="$2"; EXAKIT_PERSONA_ACTIVE=1; EXAKIT_BIN_DIR="$WORK/pp-bin"
      eval "$_pp_apply"; eval "$_pp_close"
      printf 'ACTIVE=%s' "${EXAKIT_PERSONA_ACTIVE:-}" )
}
for _s in setup/setup-macos.sh setup/setup-linux.sh; do
    check "$_s: a rerun applies no persona, offers and starts nothing" "ACTIVE=" "$(_persona_probe "$_s" 1)"
    check "$_s: a first install applies the persona, then offers and starts its add-ons" \
        "apply|autostart|offer|services|ACTIVE=1" "$(_persona_probe "$_s" 0)"
done
has "Windows applies no persona in a rerun" 'Remove-Item Env:\EXAKIT_PERSONA_ACTIVE' \
    "$(grep -B4 -A2 'Set-ExakitPersonaEnv$' "$ROOT/setup/setup-windows.ps1")"
has "...and its persona close (offer and services) is not reached in one" 'EXAKIT_PERSONA_ACTIVE -and -not $coreRerun' \
    "$(grep -B2 'Script installer_flow' "$ROOT/setup/setup-windows.ps1")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
