#!/usr/bin/env bash
# setup-linux.sh — Exasol Personal Local Starter Kit, Linux path.
#
# Installs and connects the database, exapump, the Exasol MCP server, and
# pyexasol. Prints connection details when done. The database is an Exasol
# Personal local deployment, run by the Exasol launcher through Podman.
#
# Also the WSL path: a WSL2 distro is Linux to the launcher, so install.sh
# routes it here and the Podman check below is the one that applies.
#
# Usually launched by install.sh, but runs standalone from a checkout too:
#   bash setup/setup-linux.sh
#
# Safe to re-run: completed steps are skipped, failed steps are retried.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Core libraries must exist; a truncated/partial download otherwise collapses
# into a wall of "command not found". die() isn't defined until common.sh
# loads, so report with a plain printf.
for _lib in common.sh detect.sh runtime-personal.sh; do
    [ -f "$LIB_DIR/$_lib" ] || {
        printf '\033[1;31m  ✗\033[0m Kit file missing: %s — the download looks incomplete. Re-run the installer.\n' "$LIB_DIR/$_lib" >&2
        exit 1
    }
done
. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
. "$LIB_DIR/runtime-personal.sh"
if [ -f "$LIB_DIR/legacy-crossing.sh" ]; then . "$LIB_DIR/legacy-crossing.sh" || die "Could not load $LIB_DIR/legacy-crossing.sh (corrupted kit copy? re-download and re-run)"; fi
# Optional modules: a missing file legitimately skips its step, but a file
# that FAILS to load (e.g. CRLF-corrupted copy whose syntax breaks bash) must
# fail loudly - otherwise the step silently reports "not part of this
# installation" and the component is never installed.
if [ -f "$LIB_DIR/exapump.sh" ];  then . "$LIB_DIR/exapump.sh"  || die "Could not load $LIB_DIR/exapump.sh (corrupted kit copy? re-download and re-run)"; fi
if [ -f "$LIB_DIR/mcp.sh" ];      then . "$LIB_DIR/mcp.sh"      || die "Could not load $LIB_DIR/mcp.sh (corrupted kit copy? re-download and re-run)"; fi
if [ -f "$LIB_DIR/pyexasol.sh" ]; then . "$LIB_DIR/pyexasol.sh" || die "Could not load $LIB_DIR/pyexasol.sh (corrupted kit copy? re-download and re-run)"; fi

exakit_init_logging
# Where the bootstrap time went, in the log: the installer stamps its start,
# and this is the first line setup can write.
[ -n "${EXAKIT_INSTALL_T0:-}" ] && _exakit_log_file "INFO  setup started $(( $(date +%s) - EXAKIT_INSTALL_T0 ))s after the installer began (download, extraction and library load)"
manifest_init
exakit_enable_failure_handling
# The `exakit` command first, so `exakit status` answers from the first seconds
# of this install (AGENTS.md tells an agent to poll it). It used to be written
# by the LAST step, 105 s into a 107 s install.
exakit_install_helper_early "$SCRIPT_DIR"

[ "${EXAKIT_BANNER_SHOWN:-0}" = 1 ] || ui_banner "Personal Local Starter Kit"

manifest_set os "$(detect_os)"
manifest_set arch "$(detect_arch)"
# BEFORE kit.source is overwritten, because overwriting it is what erases the
# record of where this installation came from.
exakit_announce_kit_upgrade "${EXAKIT_KIT_SOURCE:-}" || true
manifest_set kit.source "${EXAKIT_KIT_SOURCE:-checkout:$KIT_ROOT}"
# The kit's own version comes from the versions manifest shipping with THIS
# tree, not from whatever copy an earlier install left under the kit home.
# Record the move BEFORE kit.version is overwritten: the "What's new" box at the
# end of the run reads that record, and it survives a run that dies partway.
exakit_note_kit_upgrade "$KIT_ROOT" || true
_kit_version="$(exakit_kit_version_at "$KIT_ROOT" 2>/dev/null || true)"
[ -n "$_kit_version" ] && manifest_set kit.version "$_kit_version"
exakit_resolve_install_versions

# --- step 0: an installation this kit cannot manage -------------------------
# An older kit could put the database in a container. This asks what to do with
# it, copies the data out while it is still readable, and stops it so the new
# deployment can have the port. A machine with no such installation - which is
# every fresh one - passes straight through.
if command -v legacy_crossing_before >/dev/null 2>&1; then legacy_crossing_before; fi

# --- step 1: requirements ---------------------------------------------------
EXAKIT_CURRENT_STEP="requirements"
personal_check_requirements

# --- step 1: the Exasol launcher ---------------------------------------------
# Its own step, matching the macOS shape and heading.
if begin_step launcher "Step 1/6  Exasol launcher"; then
    personal_install_launcher
    mark_step launcher
fi

# --- step 3: local deployment ------------------------------------------------
if begin_step runtime "Step 2/6  Local database deployment"; then
    # personal_deploy_local returns non-zero for ONE reason: Podman is not here
    # and the kit was not allowed, or not able, to install it. Everything else
    # in there still stops the run, because a deployment that half exists is
    # not something to carry on from. This one is: nothing has been changed,
    # and the steps that do not need a database still have value.
    if personal_deploy_local; then
        mark_step runtime
    else
        exakit_record_soft_failure runtime "$(exakit_install_command)" \
            "$(exakit_take_failure_note)" "the local database"
        warn "The database was not installed - carrying on so the rest of the install completes"
    fi
else
    # A deployment recorded by an earlier run can still carry the old
    # container's keys; this is the run that clears them.
    personal_clear_stale_record
    # The resume arms: redeploy what is gone (disarming the destroy the deploy
    # registers, since there is no mark_step here to do it), start what is
    # merely stopped - every later step talks SQL to the database.
    if ! personal_deployment_exists; then
        info "Deployment marked done but not reachable — redeploying"
        # Same one non-zero as the first-run arm above: Podman is not here, so
        # there is no database. Recorded, not fallen through - a redeploy that
        # quietly did nothing used to surface minutes later as a refused
        # connection in a step that had no idea why.
        if ! personal_deploy_local; then
            exakit_record_soft_failure runtime "$(exakit_install_command)" "$(exakit_take_failure_note)" "the local database"
            warn "The database was not installed - carrying on so the rest of the install completes"
        fi
        rollback_clear
    elif ! personal_deployment_running; then
        info "Database is deployed but not running — starting it"
        # Recorded, not fatal, and for the same reason as the arm above: the
        # steps that do not need a database still have value, and a start that
        # the launcher accepted without doing anything is repaired inside
        # personal_wait_ready_or_deploy rather than waited out here.
        # A SUBSHELL, because personal_start still ends the run on its own
        # failures - that is right for `exakit start`, which exists only to do
        # this, and wrong here, where it is one step of six. die exits, so the
        # subshell turns it into a false; the reason it leaves behind is in a
        # file, so it survives the subshell to reach the summary.
        if ( personal_start && personal_wait_ready_or_deploy ); then
            :
        else
            exakit_record_soft_failure runtime "exakit start" "$(exakit_take_failure_note)" "the local database"
            warn "The database was not started - carrying on so the rest of the install completes"
        fi
    fi
fi

# --- steps 3-6: exapump, MCP server, pyexasol, exakit helper (shared) ---------
kit_shared_steps 3 6 "$SCRIPT_DIR" "$KIT_ROOT"

# The other half of the crossing runs inside the shared steps, immediately
# before the sample-data load (see exakit_maybe_offer_data_load): a user's own
# tables come back before the kit's demo data, not after the whole install.
# This call is the safety net for a run that skipped that point altogether, and
# is a no-op once the restore has happened.
if command -v legacy_crossing_after >/dev/null 2>&1; then legacy_crossing_after; fi

exakit_finish
connection_summary
# Only when the kit version moved during this run, and never able to fail it: the
# trap is already released and every reader inside degrades to silence.
exakit_print_whats_new_box "$KIT_ROOT" || true
# Last on screen, after the payoff panel: anything that did not complete, with
# the one command that installs it. A step that failed mid-run scrolls away;
# this is what the user is still looking at when the installer exits.
exakit_print_soft_failures
# The install's one closing line, after the panel and after anything that did
# not finish. Silent when a soft failure was recorded.
exakit_print_ready_line
# The closing offer: optional marketplace add-ons, asked exactly once, only on
# an interactive run whose steps all completed, and only while something is
# actually on offer. The subshell keeps any failure inside it from ending an
# install that already succeeded.
# Automatic start defaults to ON for a fresh install: the kit's promise is a
# database that is simply there, and leaving it off meant a reboot quietly
# took it away. Only ever applied when the manifest has no opinion yet, so
# `exakit autostart off` survives a re-run of the installer. This runs BEFORE
# the marketplace offer so an add-on installed from it joins the boot set.
exakit_autostart_default_on || true
( exakit_marketplace_offer ) || true
# A rule, then a heading: the last line on screen is where the reader is left,
# and run together with whatever the marketplace printed it read as one more of
# its bullets. The rule gives it air; the green arrow says it is not a step.
ui_rule
heading "Run \"exakit help\" for support"
# Two blank lines before the shell prompt returns. The installer's last line was
# landing directly against it, so the prompt read as part of the output.
printf '\n\n'
