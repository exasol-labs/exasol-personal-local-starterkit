#!/usr/bin/env bash
# Guard `exakit status`: every soft component reports its absence, not one.
#
# exapump, the MCP server and pyexasol all install through exakit_soft_step, so
# any of them can be missing from an install that "finished". The install-time
# report (exakit_print_soft_failures) prints once, from setup-macos.sh /
# setup-linux.sh, and is long gone by the time anyone types `exakit status`.
#
# The status screen used to hardcode a single pyexasol check. A failed exapump
# was then visible only as an absence from the steps_completed array, which is
# the kind of signal a reader does not notice, while a failed pyexasol got a
# dedicated line with a repair command. Same failure, three treatments.
#
# The trap is that the pyexasol case keeps working while the other two silently
# do not, so a targeted test on pyexasol alone would stay green through the
# whole regression. Each component is therefore checked on its own. Run:
#
#   bash tests/status-soft-components.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A kit home whose manifest says all three components were installed, so the
# "was it attempted" guard passes and absence is the only variable.
export HOME="$WORK/home"; mkdir -p "$HOME"
export EXAKIT_HOME="$WORK/kit-home"; mkdir -p "$EXAKIT_HOME"
export EXAKIT_BIN_DIR="$WORK/bin"; mkdir -p "$EXAKIT_BIN_DIR"
cat > "$EXAKIT_HOME/manifest.json" <<'JSON'
{
  "kit_level": 1,
  "runtime": { "type": "personal" },
  "steps_completed": ["launcher", "runtime", "exapump", "mcp", "pyexasol"],
  "components": {
    "exapump":    { "validated": true, "version": "0.12.0" },
    "mcp_server": { "validated": true, "version": "2.0.0" },
    "pyexasol":   { "validated": true, "version": "2.3.1" }
  }
}
JSON

# exakit with a stub that makes named components report absent. Injected after
# the library sourcing so it overrides the real probe.
STUB="$WORK/exakit"
# exakit resolves its library relative to its OWN directory, so the stub needs a
# lib/ beside it or it dies before printing a single row.
ln -s "$ROOT/setup/lib" "$WORK/lib"
{
    # Everything up to and including the last library source line...
    sed -n '1,/^\[ -f "\$_lib_dir\/json-tables.sh" \]/p' "$ROOT/setup/exakit"
    # ...then the override, so it wins over the real probe...
    cat <<'STUB_EOF'
if [ -n "${EXAKIT_TEST_ABSENT:-}${EXAKIT_TEST_PRESENT:-}" ]; then
    eval "exakit_component_current_real() $(declare -f exakit_component_current | tail -n +2)"
    exakit_component_current() {
        case " ${EXAKIT_TEST_ABSENT:-} " in *" $1 "*) return 1 ;; esac
        case " ${EXAKIT_TEST_PRESENT:-} " in *" $1 "*) printf '9.9.9\n'; return 0 ;; esac
        exakit_component_current_real "$@"
    }
fi
STUB_EOF
    # ...then the rest of the script.
    sed -n '/^\[ -f "\$_lib_dir\/json-tables.sh" \]/,$p' "$ROOT/setup/exakit" | tail -n +2
} > "$STUB"
chmod +x "$STUB"
# The stub is worthless if the injection missed, and a silent miss would make
# every check below "pass" by reporting nothing.
grep -q 'EXAKIT_TEST_ABSENT' "$STUB" || { printf 'FAIL could not build the test stub (injection point moved in setup/exakit)\n'; exit 1; }
bash -n "$STUB" || { printf 'FAIL the test stub does not parse\n'; exit 1; }

status_with_absent() { EXAKIT_TEST_ABSENT="$1" bash "$STUB" status 2>/dev/null; }

# 1. Each soft component, alone, must name itself AND its repair command.
while IFS='|' read -r id fix; do
    [ -n "$id" ] || continue
    out="$(status_with_absent "$id")"
    case "$out" in
        *"$id"*) : ;;
        *) fail "a missing $id is not reported by exakit status at all"; continue ;;
    esac
    case "$out" in
        *"$fix"*) pass "a missing $id is reported with: $fix" ;;
        *)        fail "a missing $id is named but its repair command ($fix) is not shown" ;;
    esac
done <<EOF
exapump|exakit update
mcp|exakit update
pyexasol|exakit update
EOF

# 2. All three at once must each get their own line, not just the first.
#
# Checked on the COMPONENT NAME, not on the repair command. Every component now
# repairs with the same bare `exakit update`, so counting that string once per
# loop pass would report three whatever the screen said -- a check that passes
# without reading anything. The name is what distinguishes the lines.
out="$(status_with_absent "exapump mcp pyexasol")"
missing_named=0
for id in exapump mcp pyexasol; do
    case "$out" in *"$id"*) missing_named=$((missing_named + 1)) ;; esac
done
case "$out" in
    *"exakit update"*) pass "the repair command is shown" ;;
    *)                 fail "no repair command is shown for the missing components" ;;
esac
if [ "$missing_named" -eq 3 ]; then
    pass "all three missing components are listed together"
else
    fail "only $missing_named of 3 missing components were listed"
fi

# 3. A healthy screen stays quiet: no "Missing:" block, and no component version
#    row. Versions belong to `exakit version`. Every soft component is forced
#    PRESENT here - the sandbox has none of them on disk, so an unforced run is
#    not a healthy install and would "pass" this for the wrong reason.
out="$(EXAKIT_TEST_PRESENT="exapump mcp pyexasol" bash "$STUB" status 2>/dev/null)"
case "$out" in
    *Missing:*) fail "a healthy install still prints a Missing: block" ;;
    *)          pass "a healthy install prints no Missing: block" ;;
esac

# 4. steps_completed is machine data and must stay OUT of the human screen but
#    IN --json: dropping it from both would break agents parsing the install.
case "$out" in
    *"Steps done"*) fail "steps_completed is back on the human status screen" ;;
    *)              pass "the human screen does not print the steps array" ;;
esac
json="$(EXAKIT_TEST_PRESENT="exapump mcp pyexasol" bash "$STUB" status --json 2>/dev/null || true)"
case "$json" in
    *steps_completed*) pass "status --json still carries steps_completed" ;;
    *)                 fail "status --json lost steps_completed - agents parse this" ;;
esac

# 5. Labels line up. "dash-server:" is 12 characters against the old 11-column
#    pad, so any label at or past the pad width pushed its value out of line.
misaligned=""
col=""
while IFS= read -r line; do
    # Only "Label: value" rows. Split on the FIRST colon: a value may contain
    # colons of its own ("repair: exakit update ..."), and splitting on ": "
    # measured the label instead of where the value starts.
    case "$line" in
        *:*) ;;
        *) continue ;;
    esac
    # PANEL rows are not "Label: value" rows. This loop is about the plain rows
    # printed under the panels, where the values must line up with each other;
    # a panel draws its own interior and a colon inside one ("connect one with:
    # exakit mcp-setup") is prose, not a label. Scanning them too compared a
    # column inside a box against a column outside it, which is why this failed
    # on main for as long as status has drawn panels.
    case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-3)" in
        '|'*|'+'*|'╭'*|'│'*|'╰'*|'─'*) continue ;;
    esac
    _lbl="${line%%:*}"
    _rest="${line#*:}"
    # the value column is the label, its colon, and the run of spaces after it
    _spaces="${_rest%%[! ]*}"
    _c=$(( ${#_lbl} + 1 + ${#_spaces} ))
    if [ -z "$col" ]; then col="$_c"
    elif [ "$_c" -ne "$col" ]; then misaligned="$misaligned ${_lbl}:@${_c}"
    fi
done <<EOF
$out
EOF
if [ -z "$misaligned" ]; then
    pass "every status row starts its value in the same column"
else
    fail "status rows are misaligned:$misaligned (label pad too narrow)"
fi

# ---------------------------------------------------------------------------
# PART 2: the audited faults in the manifest writers, the uninstall record, the
# add-on failure remedy, the Windows Python probe and the Windows kit home.
#
# These are not about `exakit status`, but they belong to the same family as the
# checks above: every one of them is a fault that is INVISIBLE from a passing
# install and only shows itself on a machine that has gone slightly wrong -- no
# manifest, no interpreter, a redirected home, a Store stub on PATH. A targeted
# test on the happy path stays green through all of them, which is exactly how
# they survived.
# ---------------------------------------------------------------------------

# fn_body <file> <opening line, verbatim> -- the text of one function, from its
# opening line to the first line that closes it at column 0. Both the shell and
# the PowerShell files indent everything inside a function, so column 0 is the
# boundary and no brace counting is needed. Carriage returns are stripped, so a
# CRLF .ps1 compares exactly like the LF .sh files.
fn_body() {
    tr -d '\r' < "$1" | awk -v open="$2" '
        $0 == open { inside = 1; next }
        inside && /^}/ { exit }
        inside { print }
    '
}

# has <text> <needle> -- substring test on a multi-line blob.
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# code_only <text> -- drop whole-line comments. A check that BANS a call has to
# read code and nothing else: the comment explaining why the call was removed
# names it too, and matching on that reports the fix as the fault.
code_only() { printf '%s\n' "$1" | sed 's/^[[:space:]]*#.*$//'; }

# The guarded manifest writers import fcntl for the lock. A Windows Python has
# no fcntl, so a run from a Git Bash checkout would fail these for a reason that
# has nothing to do with what is under test. A no-op stand-in goes on PYTHONPATH
# only where the real module is missing, so CI keeps the real one and the lock it
# provides.
PYSHIM="$WORK/pyshim"; mkdir -p "$PYSHIM"
if ! python3 -c "import fcntl" >/dev/null 2>&1; then
    printf 'LOCK_EX = 2\ndef flock(fd, op):\n    return None\n' > "$PYSHIM/fcntl.py"
fi

# common_sh <shell-code> -- run code with setup/lib/common.sh sourced against a
# throwaway kit home, and print everything it wrote to either stream. The home
# is rebuilt per call, so one case cannot leave state for the next.
common_sh() {
    rm -rf "$WORK/cs"
    mkdir -p "$WORK/cs/home" "$WORK/cs/kit" "$WORK/cs/bin"
    HOME="$WORK/cs/home" EXAKIT_HOME="$WORK/cs/kit" EXAKIT_BIN_DIR="$WORK/cs/bin" \
    EXAKIT_LOG_FILE="$WORK/cs/log" PYTHONPATH="$PYSHIM" \
        bash -c ". \"$ROOT/setup/lib/common.sh\"; $1" 2>&1
}

# 6. A failed manifest WRITE explains itself instead of printing a traceback.
#
#    An install interrupted before the manifest existed printed
#    "FileNotFoundError: [Errno 2] ... manifest.json" at the top of the terminal
#    and then a kit message underneath it that explained nothing. Checked on
#    each of the three writers separately: manifest_get has always caught these,
#    so a test that only read would have stayed green.
while IFS='|' read -r label code expect; do
    [ -n "$label" ] || continue
    out="$(common_sh "$code")"
    if has "$out" "Traceback"; then
        fail "$label prints a Python traceback"
    elif has "$out" "$expect"; then
        pass "$label explains itself ($expect)"
    else
        fail "$label says nothing actionable (wanted '$expect'), got: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
done <<'EOF'
manifest_set with no manifest|manifest_set components.exasol_vscode.version 1.2.3|re-run the installer
manifest_set on a manifest that does not parse|printf nope > "$EXAKIT_MANIFEST"; manifest_set components.a.b 1|re-run the installer
mark_step with no manifest|mark_step exapump|step exapump could not be recorded
manifest_del on a manifest that does not parse|printf nope > "$EXAKIT_MANIFEST"; manifest_del components.a|re-run the installer
EOF

# 7. The uninstall names what it removed, ON SCREEN, while the log still exists.
#
#    EXAKIT_QUIET_DETAIL is forced on here because that is the whole fault: the
#    bracket that routes path spam to the logfile also routed away every line
#    that named the database, the kit home and the add-ons -- and
#    step 5 of the same function deletes that logfile. An unquieted run would
#    print those lines from info() and pass this for the wrong reason.
un_out="$(common_sh '
manifest_get() { case "$1" in runtime.type) printf "personal\n" ;; *) return 1 ;; esac; }
personal_teardown() { return 0; }
exakit_mcp_operation() { return 0; }
: > "$EXAKIT_BIN_DIR/exakit"
EXAKIT_QUIET_DETAIL=1
exakit_uninstall_run 0
')"
while IFS='|' read -r what needle; do
    [ -n "$what" ] || continue
    if has "$un_out" "$needle"; then
        pass "a quiet uninstall still names $what"
    else
        fail "a quiet uninstall does not name $what (no '$needle' on screen)"
    fi
done <<'EOF'
the database it removed|Database removed
the kit home it removed|Kit home removed
the AI clients it edited|MCP entry removed
that the lines on screen are the only record|whole record of this uninstall
EOF

# The PowerShell twin carries the identical fault, and carried the identical
# stale comment claiming the outcomes stay on screen through OkStep.
ps_un="$(code_only "$(fn_body "$ROOT/setup/exakit.ps1" 'function Invoke-ExakitUninstallRun {')")"
# Checked on OkStep, not on the name of the helper that wraps it: a body can
# call Write-UninstallRecord all day with no such function defined in it, which
# is how removing the definition left this passing. OkStep is the thing that
# actually survives the quiet bracket, so it is what has to be there.
if has "$ps_un" "OkStep"; then
    pass "the PowerShell uninstall promotes a record line through OkStep"
else
    fail "the PowerShell uninstall still names nothing it removed (no OkStep in it)"
fi

# 8. ONE failure, ONE remedy. The wrapper used to print a generic "retry with:
#    exakit marketplace" moments after the module printed its own specific
#    remedy -- and the generic one then answered "Nothing to install", because
#    marketplace declines to act on an add-on that is already there.
for f in "setup/lib/common.sh|_exakit_marketplace_apply() {" "setup/lib/exakit-common.ps1|function Invoke-ExakitMarketplaceApply {"; do
    file="${f%%|*}"; opener="${f##*|}"
    body="$(code_only "$(fn_body "$ROOT/$file" "$opener")")"
    if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
        fail "could not read $opener out of $file (has it been renamed?)"
    elif has "$body" "retry with: exakit marketplace"; then
        fail "$file still prints a second, competing remedy for one add-on failure"
    else
        pass "$file leaves the failing module's own remedy to stand"
    fi
done

# ...and the declining answer says WHY it is declining, which is what makes it
# an answer rather than a contradiction of the failure just seen.
for file in setup/lib/common.sh setup/lib/exakit-common.ps1; do
    near="$(tr -d '\r' < "$ROOT/$file" | grep -A 3 'Nothing to install')"
    if has "$near" "exakit update"; then
        pass "$file tells the reader how to repair an add-on that is present but broken"
    else
        fail "$file answers 'Nothing to install' with no way forward"
    fi
done

# 9. The Windows Python probe is a probe, not a Get-Command.
#
#    %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe is on PATH by default on
#    Windows 10/11, is not an interpreter, and exits 9009. Accepting it meant uv
#    was never bootstrapped and every later call threw "Python exited with code
#    9009" -- which failed the MCP handshake on a machine that had no Python.
body="$(fn_body "$ROOT/setup/lib/exakit-common.ps1" 'function Test-ExakitSystemPython {')"
if has "$body" "version_info" && has "$body" "LASTEXITCODE"; then
    pass "Test-ExakitSystemPython runs the interpreter and reads its exit code"
else
    fail "Test-ExakitSystemPython accepts anything named python (the Store stub passes)"
fi

# 10. manifest.json is written as UTF-8 without a BOM.
#
#     Set-Content with no -Encoding is the ANSI code page on PowerShell 5.1, so a
#     home like C:\Users\Muller\... stored CP1252 bytes that the MCP runtime --
#     which opens the manifest with encoding="utf-8" -- refused to read.
body="$(code_only "$(fn_body "$ROOT/setup/lib/exakit-common.ps1" 'function Save-ExakitManifest($Manifest) {')")"
if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    fail "could not read Save-ExakitManifest (has its signature changed?)"
elif has "$body" "WriteAllText" && ! has "$body" "Set-Content"; then
    pass "Save-ExakitManifest writes the manifest as BOM-less UTF-8"
else
    fail "Save-ExakitManifest writes the manifest in the ANSI code page"
fi

# ...and the .cmd shim stops depending on a code page at all by letting cmd.exe
# expand %USERPROFILE% itself.
body="$(code_only "$(fn_body "$ROOT/setup/lib/exakit-common.ps1" 'function Get-ExakitCmdShimContent {')")"
if has "$body" '%USERPROFILE%'; then
    pass "the exakit.cmd shim resolves its target through %USERPROFILE%"
else
    fail "the exakit.cmd shim bakes in an absolute path (unreadable under a non-ASCII home)"
fi

# 11. Every manifest writer takes the lock, not just the one that documents why.
#
#     Set-ExakitManifestValue carries the measurement (17 of 20 parallel writes
#     lost); the step tick and the key removal did their own read-modify-write
#     with no lock at all, and the step tick is the write whose loss breaks
#     "completed steps are skipped".
for opener in 'function Set-ExakitManifestValue {' 'function Set-ExakitStepDone {' 'function Remove-ExakitManifestValue {'; do
    body="$(code_only "$(fn_body "$ROOT/setup/lib/exakit-common.ps1" "$opener")")"
    name="${opener#function }"; name="${name%% *}"
    if [ -z "$body" ]; then
        fail "could not read $name out of exakit-common.ps1"
    elif has "$body" "Enter-ExakitManifestLock"; then
        pass "$name holds the manifest lock across its read and its write"
    else
        fail "$name writes the manifest unlocked (concurrent writes are lost)"
    fi
done

# 12. The Windows kit home comes from the local profile, not from $HOME.
#
#     PowerShell's $HOME is the account's home-directory attribute, which on a
#     domain machine is H:\ or \\server\share\user -- neither can be
#     bind-mounted, so the install could not run at all.
head="$(code_only "$(tr -d '\r' < "$ROOT/setup/lib/exakit-common.ps1" | sed -n '1,200p')")"
if has "$head" 'USERPROFILE'; then
    pass "the Windows kit home prefers the local user profile"
else
    fail "the Windows kit home is still derived from PowerShell's \$HOME"
fi
if has "$head" 'EXAKIT_HOME to a folder on a local drive'; then
    pass "a non-local home is detected and EXAKIT_HOME is named as the fix"
else
    fail "a non-local home is never named, so the fix is never offered"
fi

# 13. Declining repair-runtime is a safe answer, not a fatal error.
#
#     die()/Fail() rendered it as a red error card, exited 1, and -- because
#     die() records a failure note -- left `exakit status --json` reporting a
#     last_failure on a machine where nothing had gone wrong.
for f in "setup/exakit|cmd_repair_runtime() {|die" "setup/exakit.ps1|function Invoke-CmdRepairRuntime {|Fail"; do
    file="${f%%|*}"; rest="${f#*|}"; opener="${rest%%|*}"; fatal="${rest##*|}"
    body="$(fn_body "$ROOT/$file" "$opener")"
    # 30 lines, not 12: the declined branch now answers in --json as well as in
    # prose, and the JSON object sits between the prompt and the human line.
    decline="$(printf '%s
' "$body" | grep -A 30 'Delete everything in the database and rebuild it empty?')"
    if [ -z "$decline" ]; then
        fail "could not find the repair-runtime confirmation in $file"
    elif has "$decline" "$fatal \"Nothing was changed"; then
        fail "$file still reports a declined repair as a fatal error"
    elif has "$decline" "Repair cancelled"; then
        pass "$file reports a declined repair as cancelled, not failed"
    else
        fail "$file no longer says what happened when a repair is declined"
    fi
done

# 14. Windows records WHY an install died, and status --json reports it.
#
#     Bash die() writes .last-failure and status --json surfaces it; the
#     PowerShell Fail() kept the reason in a variable that died with the
#     process, so nothing on Windows could say why an install stopped.
body="$(fn_body "$ROOT/setup/lib/exakit-common.ps1" 'function Fail([string]$Msg) {')"
if has "$body" "Write-ExakitFailureNote"; then
    pass "the PowerShell Fail() records the reason where the next process can read it"
else
    fail "the PowerShell Fail() leaves no record of why the install died"
fi
note_fn="$(fn_body "$ROOT/setup/lib/exakit-common.ps1" 'function Write-ExakitFailureNote {')"
if has "$note_fn" 'yyyy-MM-dd HH:mm:ss'; then
    pass "the failure note carries its timestamp on line 2"
else
    fail "the failure note is undated, so a stale one makes a healthy machine look broken"
fi
json_body="$(fn_body "$ROOT/setup/exakit.ps1" 'function Invoke-CmdStatus {')"
if has "$json_body" "last_failure" && has "$json_body" "last_failure_at"; then
    pass "the PowerShell status --json carries last_failure and last_failure_at"
else
    fail "the PowerShell status --json is missing the last_failure keys agents read"
fi

# 15. A manifest is quarantined for being unparseable, never for being unread.
#
#     The parse probe runs through run_python, which may try to bootstrap uv over
#     the network first -- so an offline machine with no system Python failed the
#     test for want of an INTERPRETER and a perfectly good manifest was renamed
#     .corrupt-<ts> under a message blaming the file.
# run_python is stubbed to fail alongside the can-run probe, because that is
# what "no interpreter" IS: with the gate in place manifest_init never reaches
# the probe, and without it the probe fails and takes a valid manifest down with
# it. Stubbing only the probe would pass on any machine that happens to have a
# Python, which is every machine this suite has ever run on.
out="$(common_sh '
printf "{\"kit_level\":1,\"steps_completed\":[\"runtime\"]}" > "$EXAKIT_MANIFEST"
exakit_can_run_python() { return 1; }
run_python() { return 1; }
manifest_init
cat "$EXAKIT_MANIFEST"
ls "$EXAKIT_HOME"
')"
if has "$out" "corrupt-"; then
    fail "a valid manifest is quarantined when there is no interpreter to read it with"
elif has "$out" '"steps_completed":["runtime"]'; then
    pass "with no interpreter the existing manifest is kept untouched"
else
    fail "the untouched manifest was not preserved: $(printf '%s' "$out" | tr '\n' ' ')"
fi
out="$(common_sh '
printf "{\"steps_completed\": [\"launcher\", \"runtime\"], \"components\": {oops" > "$EXAKIT_MANIFEST"
exakit_can_run_python() { return 0; }
manifest_init
cat "$EXAKIT_MANIFEST"
')"
if has "$out" "does not parse as JSON" && has "$out" '"launcher", "runtime"'; then
    pass "a genuinely unparseable manifest is named as such and its step ticks survive"
elif has "$out" "does not parse as JSON"; then
    fail "an unparseable manifest is rebuilt but its recoverable step ticks are thrown away"
else
    fail "an unparseable manifest is not reported for what it is: $(printf '%s' "$out" | tr '\n' ' ')"
fi

# 16. Write-ExakitError exists, and is not gated.
#
#     It was named in the note on ExakitQuietDetail and called from six places
#     while no function of that name existed
#     anywhere in the tree - so every one of those calls was a
#     CommandNotFoundException, on exactly the error paths they were written to
#     improve. Counted rather than merely looked for: a guard that stops having
#     call sites to protect is a guard watching nothing.
ps_files=""
for f in "$ROOT/setup"/*.ps1 "$ROOT/setup/lib"/*.ps1; do
    [ -f "$f" ] && ps_files="$ps_files $f"
done
err_defs=0
err_calls=0
for f in $ps_files; do
    _blob="$(tr -d '\r' < "$f")"
    # Anchored on a word boundary: a plain substring count also matches a
    # renamed Write-ExakitErrorSomething, and would then report a definition
    # that no call site can actually reach.
    _d="$(printf '%s\n' "$_blob" | grep -cE '^function Write-ExakitError([^A-Za-z0-9_-]|$)' || true)"
    _c="$(code_only "$_blob" | grep -c 'Write-ExakitError' || true)"
    err_defs=$((err_defs + _d))
    err_calls=$((err_calls + _c - _d))
done
if [ "$err_calls" -le 0 ]; then
    fail "no .ps1 calls Write-ExakitError any more - this guard is watching nothing"
elif [ "$err_defs" -gt 0 ]; then
    pass "all $err_calls Write-ExakitError call sites have a definition to reach"
else
    fail "$err_calls .ps1 call sites reach a Write-ExakitError that is defined nowhere"
fi
body="$(fn_body "$ROOT/setup/lib/exakit-common.ps1" 'function Write-ExakitError([string]$Msg) {')"
if [ -z "$body" ]; then
    fail "Write-ExakitError is not defined in exakit-common.ps1 beside Warn2"
elif has "$(code_only "$body")" "ExakitQuietDetail"; then
    fail "Write-ExakitError is gated by the quiet flag - a job that says nothing while it works must still speak when it fails"
else
    pass "Write-ExakitError is not gated by ExakitQuietDetail"
fi
if has "$body" "Suspend-ExakitSpinner" && has "$body" "UiErr"; then
    pass "Write-ExakitError hands the spinner its line back and uses the shared error palette"
else
    fail "Write-ExakitError prints into the spinner's line, or with a hardcoded colour"
fi

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
