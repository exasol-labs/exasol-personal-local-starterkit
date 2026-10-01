#!/usr/bin/env bash
# Guard the ways an installer run can undo - or fail to explain - what the user
# already had.
#
# The first two are resume-path bugs: the first run is fine, and the damage only
# appears on the second run, which is the run nobody tests by hand. The Windows
# findings after them have the same shape: not one of them shows up on a first
# install, on the machine the developer happens to be sitting at.
#
#   1. A resumed runtime step leaves its destroy/volume-rm armed. mark_step is
#      the only thing that clears the rollback stack, and a resume branch has no
#      mark_step to make -- the step is already recorded as done. So the undo
#      registered by the redeploy stays armed for the rest of the run, and any
#      later die offers to run it under a prompt that calls it "the failed
#      step's changes".
#
#   2. The installer overwrites a recorded `exakit autostart off`. An
#      unconditional exakit_autostart_enable wrote autostart.enabled=true before
#      exakit_autostart_default_on -- the function whose whole job is to leave a
#      recorded answer alone -- ever looked at it.
#
#   3. The Windows installer replaces a named failure with a number. install.ps1
#      re-threw the setup script's exit code, so its trap printed "Setup failed
#      with exit code 1" over the cause and remedy the setup script had just
#      named, and then blamed the network for it.
#
#   4. The Windows installer writes to the machine before it checks it: the
#      download, the replaced kit directory and the setup script's logfile all
#      landed before a single requirement was looked at.
#
#   5. A failed re-install destroys the working kit: the old copy was deleted
#      before the replacement existed, and the installed exakit shim points
#      into it by absolute path.
#
#   6. Windows-on-ARM skips two steps without printing them - the step counter
#      jumps 1/5 to 4/5 - and then offers to connect AI clients to the bridge
#      it just skipped.
#
#   bash tests/install-resume-safety.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '\n== rollback_clear empties the stack without disabling it ==\n'

# The pure helpers, lifted out so this stays hermetic and never sources a file
# that would try to touch a real install.
eval "$(sed -n '/^rollback_init()/,/^}/p;/^push_rollback()/,/^}/p;/^rollback_discard()/,/^}/p;/^rollback_clear()/,/^}/p' "$ROOT/setup/lib/common.sh")"

if ! command -v rollback_clear >/dev/null 2>&1; then
    fail "rollback_clear does not exist - a resumed deploy cannot disarm its undo"
else
    EXAKIT_ROLLBACK_FILE="$WORK/rb"
    : > "$EXAKIT_ROLLBACK_FILE"
    push_rollback "echo one"
    push_rollback "exasol destroy --remove --auto-approve"
    if [ "$(wc -l < "$EXAKIT_ROLLBACK_FILE" | tr -d ' ')" = "2" ]; then
        pass "two undo commands registered"
    else
        fail "push_rollback did not register both commands"
    fi

    rollback_clear
    if [ ! -s "$EXAKIT_ROLLBACK_FILE" ]; then
        pass "rollback_clear emptied the stack"
    else
        fail "rollback_clear left commands armed: $(cat "$EXAKIT_ROLLBACK_FILE")"
    fi
    # The distinction from rollback_discard is the whole point: the run has more
    # steps to go and they still need an undo of their own.
    if [ -n "${EXAKIT_ROLLBACK_FILE:-}" ] && [ -f "$EXAKIT_ROLLBACK_FILE" ]; then
        pass "...and left the stack itself live for the steps still to come"
    else
        fail "rollback_clear discarded the stack - later steps lose their undo"
    fi
    push_rollback "echo later"
    if [ -s "$EXAKIT_ROLLBACK_FILE" ]; then
        pass "...so a later step can still register one"
    else
        fail "nothing can be registered after rollback_clear"
    fi
fi

printf '\n== every resume branch disarms what it re-registered ==\n'

# RUN, not grepped. This guard used to be
#   grep -A6 <anchor> setup-macos.sh | grep -q rollback_clear
# which is satisfied by the word appearing in a COMMENT -- and the comment block
# explaining the call sits directly above it. Deleting the call and leaving the
# explanation behind kept this suite at "51 passed, 0 failed". A guard that
# cannot fail on the thing it names is worse than no guard, because it is
# counted as coverage.
#
# Executing the branch cannot be fooled that way: a commented-out call registers
# nothing, so the stack stays armed and the check goes red. The stubs supply the
# two things the branch touches, with the deploy registering exactly the undo a
# real one does.
#
# The branch ends at the elif/else/fi of the ENCLOSING if, not at the first one
# it meets: the redeploy is itself wrapped in `if ! personal_deploy_local; then
# ... fi` now, and stopping at that inner fi handed eval half an if block. The
# enclosing keyword is the first one indented LESS than the branch body.
resume_branch() {
    awk '/Deployment marked done but not reachable/{
             inb=1; match($0, /^[[:space:]]*/); body=RLENGTH
         }
         inb && /^[[:space:]]*(elif|else|fi)([[:space:]]|$)/{
             match($0, /^[[:space:]]*/); if (RLENGTH < body) exit
         }
         inb{print}' "$1"
}

check_resume_disarms() {
    _crd_label="$1"; _crd_file="$2"
    _crd_body="$(resume_branch "$_crd_file")"
    if [ -z "$_crd_body" ]; then
        fail "$_crd_label resume branch not found - the anchor moved, so this guard is blind"
        return
    fi
    case "$_crd_body" in
        *personal_deploy_local*) : ;;
        *) fail "$_crd_label resume branch no longer redeploys - this guard is testing the wrong block"
           return ;;
    esac
    # An extract that does not parse used to pass: eval failed, nothing was
    # registered, and an empty stack reads exactly like a disarmed one.
    if ! printf '%s\n' "$_crd_body" | bash -n 2>/dev/null; then
        fail "$_crd_label resume branch did not extract as whole statements - this guard is blind"
        return
    fi
    EXAKIT_ROLLBACK_FILE="$WORK/rb-$_crd_label"
    : > "$EXAKIT_ROLLBACK_FILE"
    _crd_ran="$WORK/ran-$_crd_label"
    rm -f "$_crd_ran"
    (
        info() { :; }
        warn() { :; }
        exakit_take_failure_note() { :; }
        exakit_record_soft_failure() { :; }
        personal_deploy_local() {
            : > "$_crd_ran"
            push_rollback "exasol destroy --remove --auto-approve"
        }
        eval "$_crd_body"
    )
    if [ ! -f "$_crd_ran" ]; then
        fail "$_crd_label resume branch never reached the redeploy - this guard is blind"
    elif [ -s "$EXAKIT_ROLLBACK_FILE" ]; then
        fail "$_crd_label resume redeploys and leaves armed: $(cat "$EXAKIT_ROLLBACK_FILE")"
    else
        pass "$_crd_label resume clears the undo it re-registered (branch executed)"
    fi
}

check_resume_disarms "macOS" "$ROOT/setup/setup-macos.sh"
check_resume_disarms "Linux" "$ROOT/setup/setup-linux.sh"

# The first-run branches must NOT need it - they have a mark_step, which clears
# the stack as its side effect. A rollback_clear there would be noise that hides
# the fact that mark_step is what normally does this. The deploy may be bare or
# the condition of an `if` (it returns non-zero when Podman is unavailable, and
# the run carries on without a database); either way mark_step follows it.
_frd='^[[:space:]]*(if[[:space:]]+)?personal_deploy_local(;[[:space:]]*then)?[[:space:]]*$'
if grep -qE "$_frd" "$ROOT/setup/setup-macos.sh" && \
   grep -A1 -E "$_frd" "$ROOT/setup/setup-macos.sh" | grep -q 'mark_step runtime'; then
    pass "the first-run branch still relies on mark_step"
else
    fail "the first-run branch no longer marks the step"
fi

printf '\n== the installer does not overwrite a recorded autostart choice ==\n'

# exakit_autostart_enable writes autostart.enabled=true unconditionally, so
# calling it from the shared steps overrides an answer the user already gave.
# The setup scripts call exakit_autostart_default_on instead, near the end.
# Stated as an INVARIANT rather than "the bad line is gone": there must be
# exactly ONE call, and it must sit inside exakit_autostart_default_on. A guard
# that greps for the specific line that was removed passes the moment the same
# call comes back two lines higher, or spelled slightly differently -- which is
# exactly what happened when this check was first written.
_F="$ROOT/setup/lib/common.sh"
_calls="$(grep -n 'exakit_autostart_enable' "$_F" \
          | grep -v ':[[:space:]]*#' \
          | grep -v 'exakit_autostart_enable() {' \
          | cut -d: -f1)"
_ncalls="$(printf '%s\n' "$_calls" | grep -c '[0-9]' || true)"
_dstart="$(grep -n '^exakit_autostart_default_on()' "$_F" | cut -d: -f1)"
_dend="$(awk -v s="$_dstart" 'NR>=s && /^}/ { print NR; exit }' "$_F")"
if [ "$_ncalls" = "1" ]; then
    pass "exakit_autostart_enable has exactly one caller"
else
    fail "exakit_autostart_enable is called $_ncalls times - one of them overrides the user's choice (lines: $(printf '%s' "$_calls" | tr '\n' ' '))"
fi
_outside=0
for _l in $_calls; do
    if [ "$_l" -lt "$_dstart" ] || [ "$_l" -gt "$_dend" ]; then _outside=1; fi
done
if [ "$_outside" = "0" ]; then
    pass "...and it is inside exakit_autostart_default_on, which respects a recorded answer"
else
    fail "exakit_autostart_enable is called from outside exakit_autostart_default_on, so 'exakit autostart off' does not survive a re-run"
fi
for f in setup-macos.sh setup-linux.sh; do
    if grep -q 'exakit_autostart_default_on' "$ROOT/setup/$f"; then
        pass "$f still defaults it on for a fresh install"
    else
        fail "$f no longer sets an autostart default - a fresh install loses it"
    fi
done

# And the function itself must keep leaving a recorded answer alone. Run, not
# read: this is the behaviour the whole finding turns on.
eval "$(sed -n '/^exakit_autostart_default_on()/,/^}/p' "$ROOT/setup/lib/common.sh")"
_recorded=""
manifest_get() { printf '%s\n' "$_recorded"; }
exakit_autostart_enable() { printf 'ENABLE-CALLED\n'; }
for _want in true false; do
    _recorded="$_want"
    if [ -z "$(exakit_autostart_default_on 2>&1)" ]; then
        pass "a recorded '$_want' is left alone"
    else
        fail "a recorded '$_want' was overwritten by the installer"
    fi
done
_recorded=""
if [ "$(exakit_autostart_default_on 2>&1)" = "ENABLE-CALLED" ]; then
    pass "and a manifest with no opinion still defaults to on"
else
    fail "a fresh install no longer turns autostart on"
fi

# --- the Windows installer -------------------------------------------------
#
# Everything below guards install.ps1 and setup/setup-windows.ps1. They
# belong with the resume-path checks above for the same reason: none of these
# bugs shows up on the run that installs a kit for the first time. They show up
# on the second run, on the machine that cannot run the kit at all, and on the
# architecture nobody has on their desk.
_IPS="$ROOT/install.ps1"
_SWD="$ROOT/setup/setup-windows.ps1"
_RPS="$ROOT/setup/lib/runtime-personal.ps1"

# Line number of the first line holding a fixed string, or "" when absent.
_line_of() { grep -n -m1 -F "$2" "$1" | cut -d: -f1; }
# One guard for "this file still contains this exact text".
_has() {
    if grep -qF "$2" "$1"; then pass "$3"; else fail "$4"; fi
}

printf '\n== a failed Windows install ends with the reason, not with a number ==\n'

# install.sh execs its setup script, so on macOS/Linux/WSL the setup script's
# own last line IS the installer's last line. install.ps1 re-threw the child's
# exit code as "Setup failed with exit code 1", which the trap printed as THE
# reason -- over the top of the named cause and remedy the setup script had
# printed one line earlier -- and then added a network hypothesis to a failure
# that was, twice in the field, a stopped container engine.
_handoff="$(sed -n '/& powershell -ExecutionPolicy Bypass -File/,$p' "$_IPS")"
# The code is PASSED THROUGH, and the shape it is passed through in matters:
# install.ps1 is documented as `irm ... | iex`, which runs it in the caller's
# session, so a top-level `exit` closes the user's terminal - taking this very
# message with it. The invariant is the code reaching $LASTEXITCODE, with exit
# reserved for a real file invocation.
if printf '%s\n' "$_handoff" | grep -qF 'global:LASTEXITCODE = $setupExitCode' && \
   printf '%s\n' "$_handoff" | grep -qF 'if ($ExakitRanAsFile) { exit $setupExitCode }'; then
    pass "install.ps1 passes the setup script's own exit code through, without closing the terminal"
else
    fail "install.ps1 no longer passes the setup script's exit code through"
fi
# An invariant on the whole tail of the file, not on the one string that was
# removed: ANY throw after the handoff lands in the trap, and the trap's
# message is the last thing the user reads.
if printf '%s\n' "$_handoff" | grep -qE '^[[:space:]]*throw '; then
    fail "install.ps1 throws after the handoff again - the trap prints that instead of the cause the setup script named"
else
    pass "...and throws nothing after the handoff, so the setup script keeps the last word"
fi

# The range ends on /^}/ rather than /^}$/ so it still bounds the block in a
# Windows working tree, where the .ps1 files are CRLF and the "$" would not
# match. No line inside the trap starts in column 1.
_trap="$(sed -n '/^trap {/,/^}/p' "$_IPS")"
if printf '%s\n' "$_trap" | grep -qF 'check your network or proxy'; then
    if printf '%s\n' "$_trap" | grep -qF '$InstallPhase -eq "download"'; then
        pass "the network advice is limited to the phase that uses the network"
    else
        fail "the trap sends every failure off to check the network again, including the ones with a named cause"
    fi
else
    pass "the trap does not mention the network at all"
fi
if printf '%s\n' "$_trap" | grep -qF 'Fix the issue above and re-run." -ForegroundColor'; then
    pass "...and every other phase still gets a plain 'fix it and re-run'"
else
    fail "the trap lost its plain second line, so a non-download failure ends with no advice at all"
fi

# The phase has to be entered before the fetch and left behind after it, or
# every later failure inherits the download's advice.
_dl="$(_line_of "$_IPS" 'Invoke-WebRequest -Uri $url -OutFile $tmpZip')"
_phase_dl="$(_line_of "$_IPS" '$InstallPhase = "download"')"
_phase_plan="$(_line_of "$_IPS" '$InstallPhase = "plan"')"
_plan_render="$(_line_of "$_IPS" 'Write-ExakitInstallPlan')"
if [ -n "$_dl" ] && [ -n "$_phase_dl" ] && [ -n "$_phase_plan" ] && [ -n "$_plan_render" ] && \
   [ "$_phase_dl" -lt "$_dl" ] && [ "$_phase_plan" -gt "$_dl" ] && [ "$_phase_plan" -lt "$_plan_render" ]; then
    pass "the download phase is entered before the fetch and left before the plan"
else
    fail "the install phase no longer tracks the fetch (phase set at ${_phase_dl:-none}, fetch at ${_dl:-none}, plan phase at ${_phase_plan:-none}, plan render at ${_plan_render:-none})"
fi

printf '\n== the Windows installer checks the machine before it writes to it ==\n'

# install.ps1 checked only "is this Windows" before downloading the kit,
# replacing ~/.exasol-starter-kit/kit and handing off to a setup script that
# opens a logfile and writes five manifest entries -- all before
# Test-PersonalRequirements looked at memory or disk. Verified in the field:
# on a machine below the minimum, the refused install still left an install log.
_gate="$(_line_of "$_IPS" '$RequirementChecks = Get-ExakitRequirementChecks')"
_enforce="$(_line_of "$_IPS" 'throw $check.Reason')"
if [ -n "$_gate" ] && [ -n "$_enforce" ] && [ -n "$_dl" ] && \
   [ "$_gate" -lt "$_dl" ] && [ "$_enforce" -lt "$_dl" ]; then
    pass "the requirements gate runs, and refuses, before the download"
else
    fail "the requirements gate no longer runs before the download (gate at ${_gate:-none}, refusal at ${_enforce:-none}, fetch at ${_dl:-none})"
fi
# Each probe has to be CALLED by the check builder, not merely defined: a gate
# that quietly stopped asking about memory would still have the function
# sitting in the file for a grep to find.
_builder="$(sed -n '/^function Get-ExakitRequirementChecks {/,/^}/p' "$_IPS")"
for _probe in 'Get-Command podman' 'Get-ExakitTotalRamGb' 'Get-ExakitFreeGb'; do
    if printf '%s
' "$_builder" | grep -qF "$_probe"; then
        pass "...and the gate asks $_probe"
    else
        fail "the pre-download gate no longer asks $_probe"
    fi
done
# ...and everything those probes read is read before the download writes anything.
for _probe in 'Get-Command podman' 'TotalPhysicalMemory' 'AvailableFreeSpace'; do
    _l="$(_line_of "$_IPS" "$_probe")"
    if [ -n "$_l" ] && [ -n "$_dl" ] && [ "$_l" -lt "$_dl" ]; then
        pass "...reading $_probe while the machine is still untouched"
    else
        fail "the pre-download gate no longer reads $_probe"
    fi
done

# The gate borrows its refusals word for word from the library that owns them,
# so nobody meets two spellings of the same message. BOTH sides are checked:
# rewording runtime-personal.ps1 alone is exactly how they would drift apart in
# silence.
for _msg in \
    'This machine is not compatible: Exasol Personal needs at least' \
    'This machine is not compatible right now:'
do
    if grep -qF "$_msg" "$_IPS" && grep -qF "$_msg" "$_RPS"; then
        pass "the gate and runtime-personal.ps1 both say: $_msg"
    else
        fail "install.ps1 and setup/lib/runtime-personal.ps1 no longer share this refusal, so the same machine gets two spellings of it: $_msg"
    fi
done
# The two the gate owns alone: they are what the trap prints as the reason, and
# nothing in the runtime module has a peer for them.
for _msg in 'Insufficient memory: ' 'Insufficient free disk space on '
do
    _has "$_IPS" "$_msg" "the gate names its own refusal reason: $_msg" \
        "install.ps1 no longer names its refusal reason: $_msg"
done

# Permissive by design: this gate works from less information than the check it
# runs ahead of, so anything it cannot read has to pass.
if grep -A2 -F 'if ($ramGb -lt 0) {' "$_IPS" | grep -qF -e '-State "note"'; then
    pass "an unreadable memory reading is a note, not a refusal"
else
    fail "the gate now refuses a machine whose memory it merely could not read"
fi
if grep -A2 -F 'if ($freeGb -lt 0) {' "$_IPS" | grep -qF -e '-State "note"'; then
    pass "an unreadable disk reading is a note, not a refusal"
else
    fail "the gate now refuses a machine whose free disk it merely could not read"
fi

printf '\n== EXAKIT_PREFLIGHT exists on both installers ==\n'

# QUICKSTART.md and README.md offer "check first, it installs nothing" under a
# requirements table that includes Windows, and the only spelling of it was the
# sh one. install.ps1 answers to it at the same point in its own flow, and can
# do it before the download because -- unlike install.sh, whose checker lives
# in the kit -- it has everything it needs already.
_has "$ROOT/install.sh" 'EXAKIT_PREFLIGHT' \
    "install.sh supports EXAKIT_PREFLIGHT" \
    "install.sh lost EXAKIT_PREFLIGHT"
_pf="$(_line_of "$_IPS" '$env:EXAKIT_PREFLIGHT -eq "1"')"
if [ -n "$_pf" ] && [ -n "$_dl" ] && [ "$_pf" -lt "$_dl" ]; then
    pass "install.ps1 answers \$env:EXAKIT_PREFLIGHT, before it downloads anything"
else
    fail "install.ps1 has no \$env:EXAKIT_PREFLIGHT check ahead of the download - the docs offer Windows a check-only run that does not exist"
fi
# Stops at the report - by RETURNING, for the same reason as above: an `exit`
# here closed the window over the very report the run exists to print.
_has "$_IPS" '$preflightFailures = Write-ExakitRequirementReport' \
    "...and a preflight run stops at the report instead of installing" \
    "a preflight run on Windows no longer stops at the report"
_has "$_IPS" 'if ($ExakitRanAsFile) { exit $preflightFailures }' \
    "...leaving the session alive to read it" \
    "the preflight can close the user's terminal again"

printf '\n== a failed re-install never leaves the user without a kit ==\n'

# install.ps1 deleted ~/.exasol-starter-kit/kit and then moved the archive's
# entries in one at a time, so a corrupt archive, a full disk or antivirus
# holding a single file open left an empty or half-populated kit directory --
# and the installed exakit.cmd shim points into it by absolute path, so the
# user's working `exakit` command died with a re-install they had only run to
# get a newer version.
_sentinels="$(_line_of "$_IPS" 'foreach ($sentinel in')"
_aside="$(_line_of "$_IPS" 'Move-Item -LiteralPath $KitDir -Destination $kitBackup')"
if [ -n "$_sentinels" ] && [ -n "$_aside" ] && [ "$_sentinels" -lt "$_aside" ]; then
    pass "the incoming kit is verified before the working one is touched"
else
    fail "the working kit is moved or removed before the replacement is verified (verify at ${_sentinels:-none}, move at ${_aside:-none})"
fi
if [ -n "$_sentinels" ]; then
    _sent_line="$(sed -n "${_sentinels}p" "$_IPS")"
    for _sentinel in 'setup\exakit.ps1' 'setup\lib\exakit-common.ps1' 'versions.json'; do
        case "$_sent_line" in
            *"$_sentinel"*) pass "...checking it for $_sentinel" ;;
            *) fail "the incoming kit is no longer checked for $_sentinel - an archive without it would replace a working kit" ;;
        esac
    done
fi
_has "$_IPS" 'Move-Item -LiteralPath $kitBackup -Destination $KitDir' \
    "a failed swap puts the previous kit back" \
    "a failed swap leaves the user with no kit directory at all"
_has "$_IPS" 'your previous kit was put back' \
    "...and the message says so, so the user knows the exakit command still works" \
    "...and says nothing about it, so the user finds out by typing exakit"
# $StageBase is the kit home on a real run, and the dry run's own temp folder
# (which also holds that run's $KitDir) on a dry run: either way the incoming
# tree sits beside the $KitDir it is renamed into.
_has "$_IPS" 'Join-Path $StageBase "kit.incoming-' \
    "the new tree is staged beside the kit, where a rename can reach it" \
    "the new tree is staged where Move-Item may not be able to rename it from (a %TEMP% on another volume)"
_has "$_IPS" '$StageBase  = $ExakitHome' \
    "...and on a real install that is the kit home itself" \
    "...but a real install no longer stages under the kit home"
# The old shape was: delete first, ask questions later.
_kitrm="$(_line_of "$_IPS" 'Remove-Item -Recurse -Force $KitDir')"
if [ -z "$_kitrm" ] || { [ -n "$_sentinels" ] && [ "$_kitrm" -gt "$_sentinels" ]; }; then
    pass "nothing deletes the kit directory before the replacement is proven"
else
    fail "install.ps1 deletes the kit directory at line $_kitrm, before the archive is verified"
fi

printf '\n== the Windows-on-ARM install says what it is skipping ==\n'

# $exapumpSupported gates the exapump and AI bridge steps, and Begin-ExakitStep
# is the only thing that prints a step label -- so the screen jumped from
# "Step 2/6" to "Step 5/6", which reads as output that got lost rather than as
# two steps this machine does not need. bash names the step it is not running.
_has "$ROOT/setup/lib/common.sh" 'not part of this installation, skipping' \
    "bash names a step it is not running" \
    "bash no longer names a skipped step - the wording the Windows twin copies is gone"
_has "$_SWD" 'Info "Step 3/6  exapump - not part of this installation, skipping"' \
    "the Windows path names the skipped exapump step" \
    "Windows-on-ARM jumps from Step 2/6 to Step 5/6 again"
_has "$_SWD" 'Info "Step 4/6  AI bridge (MCP server, clients and skills) - not part of this installation, skipping"' \
    "...and the skipped AI bridge step" \
    "Windows-on-ARM skips the AI bridge step without printing it"

# The note said "MCP client setup" while the whole bridge was being skipped:
# step 3 installs and validates the MCP SERVER too, because the read-only
# database user it connects as is provisioned through exapump.
_has "$_SWD" 'the whole AI bridge' \
    "the skip note names the whole AI bridge, not just the clients" \
    "the skip note understates the skip again - the MCP server goes with it"
if grep -qF 'Skipping exapump, sample-data loading and MCP client setup' "$_SWD"; then
    fail "the old note is back: it implies an MCP server that this install never builds"
else
    pass "...and the old, narrower note is gone"
fi

# And the offer that points AI clients at the bridge has to be gated on the
# same condition as the step that builds it.
# Any condition that INCLUDES $exapumpSupported gates it -- the offer also waits
# for a ready database now ($dbReady -and $exapumpSupported).
if grep -B6 -F 'Request-ExakitMcpSetupOffer' "$_SWD" | grep -qE '^[[:space:]]*if \(.*\$exapumpSupported'; then
    pass "the MCP client offer is gated on the same condition as the bridge"
else
    fail "the installer skips building the AI bridge and then offers to connect clients to it"
fi
# The skills offer is not gated: skills are documents an AI client reads, and
# they are just as useful with the database alone.
if grep -B4 -F 'Request-ExakitSkillsInstallOffer' "$_SWD" | grep -qF 'exapumpSupported'; then
    fail "the skills offer got gated too - skills do not need exapump"
else
    pass "...and the skills offer stays unconditional"
fi


printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
