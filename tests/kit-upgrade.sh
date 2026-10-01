#!/usr/bin/env bash
# kit-upgrade.sh — installing this kit over a DIFFERENT starter kit.
#
# A machine can only hold one: both kits put their command in the same bin
# directory, their staged copy at ~/.exasol-starter-kit/kit, and their state in
# the same manifest. So an install over the official kit at
# exasol-labs/exasol-personal-local-starterkit is a REPLACEMENT.
#
# Two things have to be true of it, and they pull in opposite directions. It
# must actually replace: a module the new kit DELETED cannot go on living in the
# staged copy, because that copy is what an installed exakit loads. And it must
# not replace the part that matters: the database, its credentials and the
# deployment are the user's, both kits deploy the same Exasol Personal, and an
# install command that quietly destroyed a database would be indefensible.
#
#   bash tests/kit-upgrade.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 = $3"
          else FAIL=$((FAIL+1)); echo "  FAIL $1: expected $2, got $3"; fi; }
has()   { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/exakit-takeover.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OFFICIAL="exasol-labs/exasol-personal-local-starterkit"
OURS="Sheetaldharshan200/update-path"

seed() { # seed <kit.source>
    _s_home="$WORK/home"; rm -rf "$_s_home"; mkdir -p "$_s_home"
    printf '{"manifest_version":1,"kit":{"source":"%s","version":"0.1.0"}}\n' "$1" > "$_s_home/manifest.json"
    printf '%s\n' "$_s_home"
}
ask() { # ask <kit.source-installed> <repo-being-installed> <expression>
    # seed a kit copy alongside the record: these cases are about WHICH kit is
    # installed, not about whether one is, which the section below covers.
    _a_home="$(seed "$1")"; mkdir -p "$_a_home/kit"
    EXAKIT_HOME="$_a_home" EXAKIT_BIN_DIR="$_a_home/bin" ROOT="$ROOT" INSTALLING="$2" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        '"$3"'' </dev/null 2>&1 | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

echo "a different kit is recognised, an update is not:"
check "the official kit is foreign" "$OFFICIAL" \
    "$(ask "$OFFICIAL@0.1.0" "$OURS@main" 'exakit_previous_kit_repo "$INSTALLING" || echo none')"
check "the same repo at another tag is not" "none" \
    "$(ask "$OURS@0.2.0" "$OURS@main" 'exakit_previous_kit_repo "$INSTALLING" || echo none')"
# A local working-tree install belongs to nobody, so it is never called foreign.
check "a checkout install is not foreign" "none" \
    "$(ask "checkout:/some/path" "$OURS@main" 'exakit_previous_kit_repo "$INSTALLING" || echo none')"
check "no record at all is not foreign" "none" \
    "$(ask "" "$OURS@main" 'exakit_previous_kit_repo "$INSTALLING" || echo none')"

echo
echo "a record left behind by an uninstall is not an installation:"
# THE BUG THIS EXISTS FOR. An uninstall that is interrupted, cannot reach a
# file, or whose Windows half cleans up differently, leaves kit.source sitting
# in the manifest with nothing behind it. Trusting that record told a user their
# old kit was still installed immediately after they had removed it - and left
# them no way to argue with it. The record has to be corroborated by something
# the kit actually put on disk.
_bare="$(seed "$OFFICIAL@0.1.0")"          # a manifest, and nothing else
check "a bare record claims nothing" "none" \
    "$(EXAKIT_HOME="$_bare" EXAKIT_BIN_DIR="$_bare/bin" ROOT="$ROOT" INSTALLING="$OURS@main" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        exakit_previous_kit_repo "$INSTALLING" || echo none' </dev/null 2>&1)"
check "...and nothing is announced either" "" \
    "$(EXAKIT_HOME="$_bare" EXAKIT_BIN_DIR="$_bare/bin" ROOT="$ROOT" INSTALLING="$OURS@main" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        exakit_announce_kit_upgrade "$INSTALLING"' </dev/null 2>&1 | tr -d '[:space:]')"
# The staged kit copy is proof enough on its own...
mkdir -p "$_bare/kit"
check "a staged kit copy is corroboration" "$OFFICIAL" \
    "$(EXAKIT_HOME="$_bare" EXAKIT_BIN_DIR="$_bare/bin" ROOT="$ROOT" INSTALLING="$OURS@main" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        exakit_previous_kit_repo "$INSTALLING" || echo none' </dev/null 2>&1)"
# ...and so is the command it installed, on its own.
_bare2="$(seed "$OFFICIAL@0.1.0")"; mkdir -p "$_bare2/bin"
printf '#!/bin/sh\nexit 0\n' > "$_bare2/bin/exakit"; chmod +x "$_bare2/bin/exakit"
check "an installed exakit command is too" "$OFFICIAL" \
    "$(EXAKIT_HOME="$_bare2" EXAKIT_BIN_DIR="$_bare2/bin" ROOT="$ROOT" INSTALLING="$OURS@main" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        exakit_previous_kit_repo "$INSTALLING" || echo none' </dev/null 2>&1)"

echo
echo "the update is announced as an update, and scoped out loud:"
OUT="$(ask "$OFFICIAL@0.1.0" "$OURS@main" 'exakit_announce_kit_upgrade "$INSTALLING"')"
has "the other kit is named"              "$OFFICIAL" "$OUT"
has "...and the tooling is what changes"  "are replaced" "$OUT"
has "...and the data is said to be kept"  "the deployment are kept" "$OUT"
# Silence on a plain update: this line is for a takeover, not for every install.
OUT2="$(ask "$OURS@0.2.0" "$OURS@main" 'exakit_announce_kit_upgrade "$INSTALLING"')"
check "an update says nothing" "" "$(printf '%s' "$OUT2" | tr -d '[:space:]')"
# SAME PRODUCT, NOT A RIVAL. This repo is where the kit is developed and the
# exasol-labs one is where it is published, so a machine holding the published
# kit is behind, not wrong - and a line calling it "a different kit" told the
# reader they had a problem they do not have.
lacks "it never calls the other kit a different one" "A different Exasol starter kit" "$OUT"
has   "it reads as an update"                       "Updating the starter kit" "$OUT"

echo
echo "a module the new kit deleted does not survive the replacement:"
# The real hazard, with the real files: the official kit ships runtime-nano.sh,
# nano.ps1 and catalog.tsv, all three removed from this kit on purpose. A merge
# copy leaves them in lib/, where an installed exakit would still load them.
STAGE="$WORK/home2"; mkdir -p "$STAGE/kit/setup/lib" "$STAGE/kit/mcp"
for _leftover in runtime-nano.sh nano.ps1 catalog.tsv; do : > "$STAGE/kit/setup/lib/$_leftover"; done
: > "$STAGE/kit/setup/lib/common.sh"
check "the old kit's files are staged to begin with" "3" \
    "$(ls "$STAGE/kit/setup/lib" | grep -cE 'runtime-nano.sh|nano.ps1|catalog.tsv')"
# The clear the installer runs, exactly as kit_shared_steps spells it.
for _stale in "$STAGE/kit/setup/lib" "$STAGE/kit/setup/help" "$STAGE/kit/mcp" "$STAGE/kit/sql" "$STAGE/kit/skills"; do
    rm -rf "$_stale"
done
check "...and none of them is left afterwards" "0" \
    "$(ls "$STAGE/kit/setup/lib" 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "the installer really does clear before it copies:"
KSS="$(awk '/^kit_shared_steps\(\)/,/^}$/' "$ROOT/setup/lib/common.sh")"
has "the shell half clears the staged subtrees" 'rm -rf "$_kss_stale"' "$KSS"
has "...before the library is copied over"      'cp -R "$_script_dir/lib"' "$KSS"
WIN="$(cat "$ROOT/setup/setup-windows.ps1")"
has "the Windows half clears them too"          'Remove-Item -Recurse -Force $stale' "$WIN"
has "...and announces the takeover first"       "Show-ExakitKitUpgrade" "$WIN"
lacks "neither half removes the kit home itself" 'rm -rf "$EXAKIT_HOME"' "$KSS"

echo
echo "both setup scripts ask before they overwrite the evidence:"
for _s in setup-macos.sh setup-linux.sh; do
    _body="$(cat "$ROOT/setup/$_s")"
    _before="$(printf '%s\n' "$_body" | sed -n '1,/manifest_set kit.source/p')"
    has "$_s announces before recording" "exakit_announce_kit_upgrade" "$_before"
done

echo
echo "a re-run updates the components, it does not just skip them:"
# THE HALF THAT MATTERED MOST. A step tick means "this was installed", never
# "this is current", so re-running the installer over an older installation
# skipped every step whose artifact was on disk - and the run finished having
# updated the kit and nothing else. exapump, the MCP server and pyexasol all
# stayed where the previous kit left them, and the kit then disagreed with its
# own components.
drift() { # drift <step> <installed> <advertised>
    ROOT="$ROOT" S="$1" HAVE="$2" WANT="$3" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        EXAKIT_EXAPUMP_VERSION="$WANT"; EXAKIT_MCP_VERSION="$WANT"
        EXAKIT_PYEXASOL_VERSION="$WANT"; EXAKIT_PERSONAL_VERSION="$WANT"
        exakit_component_current() { [ -n "$HAVE" ] && printf "%s\n" "$HAVE"; }
        step_version_drift "$S" || echo none' </dev/null 2>&1
}
has   "a component behind is picked up"   "and this kit installs 0.14.0" "$(drift exapump 0.13.0 0.14.0)"
check "...and the same version is not"    "none" "$(drift exapump 0.14.0 0.14.0)"
# An installer is no place to argue with a machine that is ahead of it: a
# manifest can advertise an older set than the one already installed.
check "...nor is a component ahead"       "none" "$(drift exapump 0.15.0 0.14.0)"
check "an unknown version is left alone"  "none" "$(drift exapump unknown 0.14.0)"
check "a component with no version is too" "none" "$(drift exapump "" 0.14.0)"
# The deployment is a thing, not a version, and the helper refreshes by content.
check "the runtime step has no version to drift" "none" "$(drift runtime 1 2)"
for _c in mcp pyexasol launcher; do
    has "$_c drifts on its own version" "and this kit installs 9.9.9" "$(drift "$_c" 1.0.0 9.9.9)"
done
# And the gate itself asks the version question BEFORE the artifact one: a
# component that is merely behind is present on disk, so an artifact check
# would skip it every time.
_BS="$(awk '/^begin_step\(\)/,/^}$/' "$ROOT/setup/lib/common.sh")"
has "begin_step asks about drift"          'step_version_drift "$1"' "$_BS"
has "...before it asks about the artifact" 'elif [ "$(step_artifact_state "$1")" = "missing" ]' "$_BS"

echo
echo "an interrupted update leaves something that can be finished:"
# LIF-01/LIF-02. exakit_update_self renames the kit aside and then renames the
# new one in. Between those two there is NO kit directory, and every subcommand
# needs it to find setup/lib. The only recovery was an `if !` arm, which runs
# for a non-zero exit and nothing else - not Ctrl-C, not a closed laptop, not
# an OOM kill - and nothing anywhere looked for a stranded kit.backup-* later.
# So the one command users are told to run routinely could leave a machine with
# no tooling and the restore point sitting beside it, unmentioned.
_ku_up="$(sed -n '/^exakit_update_self()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "the stage is beside the kit, not in TMPDIR" 'mktemp -d "$EXAKIT_HOME/.kit-stage' "$_ku_up"
has "a marker names the backup before the swap"  '> "$_update_marker"' "$_ku_up"
has "...and a trap restores on Ctrl-C"           'trap ' "$_ku_up"
has "...and it is cleared once the swap is done" 'rm -f "$_update_marker"' "$_ku_up"
# LIF-02: the rollback must clear the destination first. Without it, a
# destination left as a partial directory by a failed cross-filesystem mv turns
# the "restore" into mv backup kit/ - the good copy buried one level down -
# while the message still claims it was restored.
# Asserted as the PROPERTY, not as a string: every move of the backup onto the
# kit path must be guarded by a clear of that path first. A bare `lacks` on the
# mv matches the correct use inside the restore helper too, and would fail on
# the fix rather than on the defect.
_ku_unguarded="$(printf '%s\n' "$_ku_up" | awk '
    /mv "\$_backup" "\$_kit_dir"/ { if (prev !~ /rm -rf "\$_kit_dir"/) print NR }
    { prev = $0 }')"
check "no rollback nests the backup inside the kit" "" "$(printf '%s' "$_ku_unguarded" | tr '\n' ' ' | sed 's/ $//')"
# ...and the guarded form is actually present, so the check above is not
# vacuously passing on a function that no longer restores at all.
_ku_restores="$(printf '%s\n' "$_ku_up" | grep -c 'mv "\$_backup" "\$_kit_dir"')"
check "...and the restore itself still exists" "yes" \
    "$([ "${_ku_restores:-0}" -ge 1 ] && echo yes || echo no)"

# The loader is the ONLY code that still runs once kit/ is gone, so that is
# where the recovery has to be. Driven for real: an installed exakit with no
# lib/ beside it, pointed at a kit home in the interrupted state.
_ku_w="$(mktemp -d)"; mkdir -p "$_ku_w/bin" "$_ku_w/home"
cp "$ROOT/setup/exakit" "$_ku_w/bin/exakit"; chmod +x "$_ku_w/bin/exakit"
mkdir -p "$_ku_w/home/kit.backup-20260101-000000/setup/lib"
printf '%s
' "$_ku_w/home/kit.backup-20260101-000000" > "$_ku_w/home/.update-in-progress"
_ku_out="$(EXAKIT_HOME="$_ku_w/home" "$_ku_w/bin/exakit" status 2>&1)"
has "the loader recognises it"        'an update was interrupted' "$_ku_out"
has "...and says the data is intact"  'database, its data and your credentials are untouched' "$_ku_out"
# The remedy has to be runnable AS WRITTEN - that is the agent contract, and it
# is also the difference between a one-command fix and a reinstall.
_ku_cmd="$(printf '%s' "$_ku_out" | grep -oE "mv '[^']*' '[^']*'" | head -1)"
check "...and names a runnable restore" "yes" "$([ -n "$_ku_cmd" ] && echo yes || echo no)"
eval "$_ku_cmd" 2>/dev/null
check "...which actually restores the kit" "yes" \
    "$([ -d "$_ku_w/home/kit/setup/lib" ] && echo yes || echo no)"
# --json callers get it in the field they parse.
mkdir -p "$_ku_w/home2"; cp -R "$_ku_w/home/kit" "$_ku_w/home2/kit.backup-20260101-000000"
printf '%s
' "$_ku_w/home2/kit.backup-20260101-000000" > "$_ku_w/home2/.update-in-progress"
check "--json carries the same remedy" "yes" \
    "$(EXAKIT_HOME="$_ku_w/home2" "$_ku_w/bin/exakit" status --json 2>/dev/null | python3 -c 'import json,sys
try:
    print("yes" if json.load(sys.stdin).get("remedy","").startswith("mv ") else "no")
except Exception:
    print("no")' 2>/dev/null)"
# And none of this may fire on a machine that is simply not installed.
mkdir -p "$_ku_w/home3"
lacks "a plain not-installed machine is unaffected" 'an update was interrupted' \
    "$(EXAKIT_HOME="$_ku_w/home3" "$_ku_w/bin/exakit" status 2>&1)"
rm -rf "$_ku_w"

echo
echo "kit-upgrade.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
