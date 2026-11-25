#!/usr/bin/env bash
# runtime-personal.sh — Exasol Personal local runtime module (macOS and Linux).
#
# Sourced by setup scripts after common.sh and detect.sh. Installs the Exasol
# launcher from Exasol's versioned S3 binary (manifest SHA-256 verified), falling
# back to the checksum-verified GitHub release, and deploys a
# local database with `exasol install local`.
#
# Launcher facts:
#   - release assets: exasol-personal_{macOS,Linux}_{arm64,x86_64}.tar.gz
#     + checksums; Linux local deployments exist from launcher 2.3 and need
#     Podman (rootless is fine) — the launcher does not install it on Linux
#   - local deployment needs at least 8 GB RAM
#   - deployment state: ~/.exasol/launcher/deployments/<name> from 2.5.0,
#     ~/.exasol/personal/deployments/<name> before it; 2.5.0 moves the old
#     one itself (see personal_deploy_dir_refresh), and says where its
#     deployments are with `deployments list --json`
#     (personal_launcher_deployments). The kit's database is the deployment
#     named starter-kit-local (EXAKIT_PERSONAL_DEPLOYMENT); `default` is the
#     user's (a bare `exasol status` shows it)
#   - `exasol info` prints connection details for the current deployment
#   - rerunning `exasol install local` with the same preset is safe

EXAKIT_PERSONAL_PORT=8563
# THE KIT'S DATABASE IS THIS NAMED DEPLOYMENT, the folder <root>/deployments/
# starter-kit-local in the launcher's home, so `exasol deployments list` lists
# it by name and a bare `exasol status` (the launcher's `default`) never shows
# it. The kit still names it by its folder (--deployment-dir), never with -d:
# the launcher takes one or the other. Twin of $script:PersonalDeploymentName
# (PowerShell) and KIT_DEPLOYMENT (marketplace/runtime.py).
EXAKIT_PERSONAL_DEPLOYMENT="starter-kit-local"
# The one rule of exakit_personal_db_state (common.sh). A caller that loaded
# this file without common.sh (a test of one function) gets a guard that lets
# everything through, as before the rule; common.sh, sourced first or later,
# defines the real one.
command -v exakit_kit_database_guard >/dev/null 2>&1 || exakit_kit_database_guard() { return 0; }
command -v exakit_personal_db_state >/dev/null 2>&1 || exakit_personal_db_state() { return 0; }
EXAKIT_PERSONAL_MIN_RAM_GB="${EXAKIT_PERSONAL_MIN_RAM_GB:-8}"
EXAKIT_PERSONAL_MIN_DISK_GB="${EXAKIT_PERSONAL_MIN_DISK_GB:-20}"
# THE KIT'S OWN LAUNCHER NEVER LIVES ON PATH (Krishna, 24 Nov): it is
# EXAKIT_PERSONAL_KIT_BIN, in the kit folder, called by its full path by every
# kit command (personal_cli) and by `exakit exasol`. Mode K: the 2.5 binary
# there. Mode P: the wrapper there (below). The kit never writes
# ~/.local/bin/exasol: an `exasol` the user types is theirs. A 0.3.0 kit's own
# launcher at ~/.local/bin/exasol is still run until its update moves it.
# MODE P (macOS and Linux): the kit's own launcher in a home of its own, next
# to an Exasol Personal of the user's it must never touch (a 2.4, or a line
# newer than the pin, or 2.4 deployments with no launcher). Launcher 2.5 moves
# every deployment it can see under ~/.exasol/personal on any command, and has
# no flag for its root (only HOME), so the kit's copy runs only through a
# wrapper that sets HOME to the private home (personal_write_wrapper). The
# wrapper is EXAKIT_PERSONAL_BIN in mode P and the binary it runs is off PATH:
# `exasol` typed by the user stays theirs. The binary in libexec is the mode
# (detect_personal_deploy_roots reads the same file). See
# personal_launcher_mode_decide for modes K and U.
EXAKIT_PERSONAL_PRIVATE_DIR="${EXAKIT_HOME:-${HOME:-}/.exasol-starter-kit}/personal"
EXAKIT_PERSONAL_WRAPPER="$EXAKIT_PERSONAL_PRIVATE_DIR/bin/exasol"
EXAKIT_PERSONAL_PRIVATE_BIN="$EXAKIT_PERSONAL_PRIVATE_DIR/libexec/exasol"
EXAKIT_PERSONAL_PRIVATE_HOME="$EXAKIT_PERSONAL_PRIVATE_DIR/home"
EXAKIT_PERSONAL_KIT_BIN="$EXAKIT_PERSONAL_PRIVATE_DIR/bin/exasol"
EXAKIT_PERSONAL_BIN="$EXAKIT_PERSONAL_KIT_BIN"
EXAKIT_PERSONAL_MODE="${EXAKIT_PERSONAL_MODE:-}"
# The launcher's folders are spelled once, in detect.sh. Every setup script and
# exakit source it first; a caller that did not gets those functions from it
# here, and nothing else (its other functions may be a caller's own stubs).
command -v detect_personal_private_mode >/dev/null 2>&1 || \
    eval "$(sed -n '/^detect_personal_private_mode() {$/,/^}$/p' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect.sh")"
# Mode P is the kit's launcher running in the private home
# (detect_personal_private_mode): mode K has a launcher at the same kit-folder
# path, and no binary in libexec.
if detect_personal_private_mode; then
    EXAKIT_PERSONAL_MODE=P
fi
if [ "$EXAKIT_PERSONAL_MODE" = P ]; then
    EXAKIT_PERSONAL_BIN="$EXAKIT_PERSONAL_WRAPPER"
    EXAKIT_PERSONAL_LAUNCHER_HOME="${EXAKIT_PERSONAL_LAUNCHER_HOME:-$EXAKIT_PERSONAL_PRIVATE_HOME}"
fi
command -v detect_personal_deploy_roots >/dev/null 2>&1 || \
    eval "$(sed -n '/^detect_personal_deploy_roots() {$/,/^}$/p' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect.sh")"
command -v detect_personal_deploy_resolve >/dev/null 2>&1 || \
    eval "$(sed -n '/^detect_personal_deploy_resolve() {$/,/^}$/p' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect.sh")"
command -v detect_personal_deploy_found >/dev/null 2>&1 || \
    eval "$(sed -n '/^detect_personal_deploy_found() {$/,/^}$/p' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect.sh")"
command -v detect_personal_deployment_id >/dev/null 2>&1 || \
    eval "$(sed -n '/^detect_personal_deployment_id() {$/,/^}$/p' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect.sh")"
detect_personal_deploy_resolve "${EXAKIT_PERSONAL_DEPLOY_DIR:-}"
EXAKIT_PERSONAL_DEPLOY_DIR="$DETECT_PERSONAL_DEPLOY_DIR"

# personal_launcher_deployments [again] — the launcher's own deployments, one
# "<path><TAB><status>" line each, in the launcher's order (by name):
# `exasol deployments list --json` (launcher 2.5.0 and later), bounded by a
# short timeout and read with the kit's Python, never a pattern. THE ONE PLACE
# the shell side asks the launcher where its deployments are. The answer goes
# to detect.sh's resolver (DETECT_PERSONAL_LAUNCHER_LISTED=1,
# DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS), so detection, the follow of a moved
# folder, status and the uninstall all see the folders the launcher sees,
# wherever it keeps them. Each row's name and infrastructure preset too, for
# the installer's one question (personal_reuse_candidates), in
# PERSONAL_LAUNCHER_ROWS: "<name><TAB><infrastructure><TAB><status><TAB><path>".
# Non-zero, and the resolver keeps the two folders the kit knows, when there is
# no answer: a launcher without the command (2.4.x), one that fails, hangs or
# prints anything but that list, or no Python to read it with. Asked once per
# process (the launcher probes each database for its status, about 2.5 s
# while one runs); "again" asks anew. Twin of Get-PersonalLauncherDeployments.
EXAKIT_PERSONAL_LIST_TIMEOUT="${EXAKIT_PERSONAL_LIST_TIMEOUT:-6}"
personal_launcher_deployments() {
    if [ "${1:-}" != again ] && [ -n "${_EXAKIT_PERSONAL_LIST_ASKED:-}" ]; then
        [ "${DETECT_PERSONAL_LAUNCHER_LISTED:-0}" = 1 ] || return 1
        [ -z "${DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS:-}" ] || printf '%s\n' "$DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS"
        return 0
    fi
    _EXAKIT_PERSONAL_LIST_ASKED=1
    DETECT_PERSONAL_LAUNCHER_LISTED=0
    DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS=""
    PERSONAL_LAUNCHER_ROWS=""
    _pld_cli="$(personal_cli 2>/dev/null || true)"
    [ -n "$_pld_cli" ] && [ -x "$_pld_cli" ] || return 1
    # Mode P: only through its wrapper. A bare binary in its place would run in
    # the user's home and move their databases.
    [ "${EXAKIT_PERSONAL_MODE:-}" != P ] || personal_wrapper_runs || return 1
    command -v exakit_run_bounded >/dev/null 2>&1 && command -v run_python_any >/dev/null 2>&1 || return 1
    exakit_can_run_python_any 2>/dev/null || return 1
    _pld_json="$(exakit_run_bounded "$EXAKIT_PERSONAL_LIST_TIMEOUT" "$_pld_cli" deployments list --json 2>/dev/null)" || return 1
    _pld_out="$(run_python_any - "$_pld_json" <<'EXAKIT_PLD_PY'
import json, sys
# A JSON array of {"name", "path", "status", ...}, from the first line that
# opens one (a launcher notice may come before it). Anything else - a usage
# text, a half answer - is no answer.
text = sys.argv[1]
doc = None
for at in [i for i, line in enumerate(text.splitlines()) if line.lstrip().startswith("[")]:
    try:
        doc = json.JSONDecoder().raw_decode("\n".join(text.splitlines()[at:]).lstrip())[0]
        break
    except ValueError:
        continue
if not isinstance(doc, list):
    sys.exit(1)
# One row per deployment: "<path>\t<status>\t<name>\t<infrastructure>", in the
# order of the launcher. No deployment is put first: the one of the kit is
# found by its name (starter-kit-local), never by its place in this list.
def field(value):
    return value if isinstance(value, str) and not any(c in value for c in "\t\r\n") else ""
rows = []
for item in doc:
    if not isinstance(item, dict):
        sys.exit(1)
    path = item.get("path")
    if not isinstance(path, str) or not path.startswith("/") or any(c in path for c in "\t\r\n"):
        continue
    rows.append((path, field(item.get("status")), field(item.get("name")) or path.rstrip("/").rsplit("/", 1)[-1],
                 field(item.get("infrastructure"))))
sys.stdout.write("".join("%s\t%s\t%s\t%s\n" % row for row in rows))
EXAKIT_PLD_PY
)" || return 1
    DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS=""
    PERSONAL_LAUNCHER_ROWS=""
    _pld_t='	'
    while IFS= read -r _pld_row; do
        [ -n "$_pld_row" ] || continue
        _pld_path="${_pld_row%%"$_pld_t"*}"; _pld_rest="${_pld_row#*"$_pld_t"}"
        _pld_status="${_pld_rest%%"$_pld_t"*}"; _pld_rest="${_pld_rest#*"$_pld_t"}"
        _pld_name="${_pld_rest%%"$_pld_t"*}"; _pld_infra="${_pld_rest#*"$_pld_t"}"
        DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS="$DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS${DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS:+
}$_pld_path$_pld_t$_pld_status"
        PERSONAL_LAUNCHER_ROWS="$PERSONAL_LAUNCHER_ROWS${PERSONAL_LAUNCHER_ROWS:+
}$_pld_name$_pld_t$_pld_infra$_pld_t$_pld_status$_pld_t$_pld_path"
    done <<EXAKIT_PLD_ROWS
$_pld_out
EXAKIT_PLD_ROWS
    DETECT_PERSONAL_LAUNCHER_LISTED=1
    [ -z "$DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS" ] || printf '%s\n' "$DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS"
    return 0
}

# _personal_listed_roots — the folder each deployment the launcher listed is
# in, one per line, from the answer personal_launcher_deployments already has
# (it asks nothing itself: called in a $( ), it could not keep an answer).
_personal_listed_roots() {
    [ "${DETECT_PERSONAL_LAUNCHER_LISTED:-0}" = 1 ] || return 0
    printf '%s\n' "${DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS:-}" | while IFS= read -r _plr; do
        [ -n "$_plr" ] && dirname "${_plr%"$(printf '\t')"*}"
    done
    return 0
}

# personal_deploy_dir_refresh — point EXAKIT_PERSONAL_DEPLOY_DIR at the folder
# the deployment is in NOW, and make the kit's record follow it.
#
# Launcher 2.5.0 moves a stopped deployment from ~/.exasol/personal to
# ~/.exasol/launcher on its own, on the next command it runs (any but help),
# and keeps a running one where it is until later. A path computed once at
# load is therefore wrong after the first `exasol status` of a run: the kit
# read a folder that no longer existed, `exakit status` said "not deployed"
# and a re-run installer could deploy a second, empty database beside the
# moved one. So every reader of the folder calls this first; it costs two
# directory tests, no fork. A folder the user chose (EXAKIT_PERSONAL_DEPLOY_DIR
# naming neither of the launcher's own) is never moved, and is kept.
#
# THE RECORD FOLLOWS THE MOVE. When the folder now in use is the moved twin of
# the one the manifest names - the same deployment, from the launcher's old
# root to its new one (or back), the old one gone - runtime.deployment_dir and
# the ownership receipt runtime.ownership_path are rewritten in place. The
# receipt keeps its owner: a moved kit database stays the kit's, so update and
# uninstall keep managing it, and the scheduler and the virtual-schema engine,
# which read runtime.deployment_dir, find the sidecars.yaml and the bucket
# files where they now are. A second deployment that appears at the new path
# while the recorded one is still on disk is not a move and changes nothing.
#
# ONLY THE KIT'S OWN DEPLOYMENT IS FOLLOWED. That a folder exists proves
# nothing: with the kit's own gone, the deployment in the launcher's other
# folder may be one the user made, and a record that followed it would make
# `exakit uninstall` destroy it. So the record follows only when that folder's
# deployment id is the one the kit recorded (runtime.deployment_id, through
# exakit_personal_deploy_dir_now). Another id, or none recorded, leaves the
# record as it is, and exakit_personal_kit_missing names both folders. A kit
# that never recorded the id (before 0.3.1) gets it here, once per process,
# from its recorded folder while that is still where the record says.
# Twin of Update-PersonalDeployDir.
personal_deploy_dir_refresh() {
    # WHERE THE LAUNCHER KEEPS ITS DEPLOYMENTS, asked once per process
    # (personal_launcher_deployments), unless the folder the kit recorded is on
    # disk: the kit addresses its own deployment by that folder, with
    # --deployment-dir, and needs no launcher for it (the quick paths of
    # exakit sql and the status poll stay without a launcher call). That
    # recorded folder is then the folder, below.
    # A folder the user chose (EXAKIT_PERSONAL_DEPLOY_DIR naming neither of
    # the two the kit knows) is the folder: nothing to ask either.
    case "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" in
        ""|"${DETECT_PERSONAL_DEPLOY_NEW:-}"|"${DETECT_PERSONAL_DEPLOY_LEGACY:-}") ;;
        *) _EXAKIT_PERSONAL_LIST_DECIDED=1 ;;
    esac
    if [ -z "${_EXAKIT_PERSONAL_LIST_DECIDED:-}" ]; then
        _EXAKIT_PERSONAL_LIST_DECIDED=1
        _pddr_rec=""
        if [ -f "${EXAKIT_MANIFEST:-}" ] && grep -qF '"deployment_dir"' "$EXAKIT_MANIFEST" 2>/dev/null && \
           command -v manifest_get >/dev/null 2>&1 && exakit_can_run_python_any 2>/dev/null; then
            _pddr_rec="$(manifest_get runtime.deployment_dir 2>/dev/null || true)"
        fi
        # The recorded folder, on disk or gone: a gone one is followed by the
        # kit's id below, whatever its name (a 0.3.0 kit's `default`).
        _EXAKIT_PERSONAL_DEPLOY_REC="$_pddr_rec"
        [ -n "$_pddr_rec" ] && [ -d "$_pddr_rec" ] || personal_launcher_deployments >/dev/null 2>&1 || true
    fi
    # THE KIT'S OWN FOLDER WHILE IT IS THERE, even beside another deployment:
    # a 0.3.0 database the launcher could not move stays the kit's, and start,
    # stop, status and the sidecars act on it, never on the user's. Where it
    # was last seen (_EXAKIT_PERSONAL_DEPLOY_AT), so a follow is asked once.
    # A folder the user chose is kept as it is.
    case "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" in
        ""|"${DETECT_PERSONAL_DEPLOY_NEW:-}"|"${DETECT_PERSONAL_DEPLOY_LEGACY:-}"|"${_EXAKIT_PERSONAL_DEPLOY_REC:-}"|"${_EXAKIT_PERSONAL_DEPLOY_AT:-}")
            _pddr_at="${_EXAKIT_PERSONAL_DEPLOY_AT:-${_EXAKIT_PERSONAL_DEPLOY_REC:-}}"
            if [ -z "$_pddr_at" ]; then
                detect_personal_deploy_resolve "${EXAKIT_PERSONAL_DEPLOY_DIR:-}"
            elif [ -e "$_pddr_at" ] || [ "${_EXAKIT_PERSONAL_DEPLOY_LOST:-}" = "$_pddr_at" ]; then
                detect_personal_deploy_resolve "$_pddr_at" recorded
            else
                # Gone: followed to the folder whose deployment carries the
                # kit's id, once per folder per process (the id reads fork).
                personal_launcher_deployments >/dev/null 2>&1 || true
                _pddr_id=""
                if command -v manifest_get >/dev/null 2>&1 && exakit_can_run_python_any 2>/dev/null; then
                    _pddr_id="$(manifest_get runtime.deployment_id 2>/dev/null || true)"
                fi
                detect_personal_deploy_resolve "$_pddr_at" recorded "$_pddr_id"
                [ "$DETECT_PERSONAL_DEPLOY_DIR" != "$_pddr_at" ] || _EXAKIT_PERSONAL_DEPLOY_LOST="$_pddr_at"
            fi
            [ -z "$_pddr_at" ] || _EXAKIT_PERSONAL_DEPLOY_AT="$DETECT_PERSONAL_DEPLOY_DIR" ;;
        *) detect_personal_deploy_resolve "$EXAKIT_PERSONAL_DEPLOY_DIR" ;;
    esac
    EXAKIT_PERSONAL_DEPLOY_DIR="$DETECT_PERSONAL_DEPLOY_DIR"
    # The id, from the folder the record names, while it is still there.
    # Once per process, from the first refresh that sees a recorded folder.
    if [ -z "${_EXAKIT_PERSONAL_DEPLOY_ID_SEEN:-}" ] && [ -f "${EXAKIT_MANIFEST:-}" ] && \
       grep -qF '"deployment_dir"' "$EXAKIT_MANIFEST" 2>/dev/null; then
        _EXAKIT_PERSONAL_DEPLOY_ID_SEEN=1
        # One that is not text (a number, or Infinity, which an id like 3e082473
        # became in a build before this one) is no id: read again, of a database
        # of the user's too.
        if ! grep -qE '"deployment_id"[[:space:]]*:[[:space:]]*"' "$EXAKIT_MANIFEST" 2>/dev/null && \
           command -v exakit_personal_kit_dir >/dev/null 2>&1 && \
           command -v _personal_deployment_id_in >/dev/null 2>&1 && \
           exakit_can_run_python_any 2>/dev/null; then
            _pddr_kit="$(exakit_personal_kit_dir)"
            if [ -z "$_pddr_kit" ] && grep -qF '"deployment_id"' "$EXAKIT_MANIFEST" 2>/dev/null; then
                _pddr_kit="$(manifest_get runtime.deployment_dir 2>/dev/null || true)"
            fi
            if [ -n "$_pddr_kit" ] && [ -d "$_pddr_kit" ]; then
                _pddr_id="$(_personal_deployment_id_in "$_pddr_kit")"
                [ -z "$_pddr_id" ] || manifest_set runtime.deployment_id "$_pddr_id" 2>/dev/null || true
            fi
        fi
    fi
    # THE RECORD FOLLOWS: the recorded folder gone, the folder in use now
    # holding the deployment with the kit's id (exakit_personal_deploy_dir_now
    # proves it again). Once per folder per process: the proof forks.
    [ "${_EXAKIT_PERSONAL_DEPLOY_FOLLOWED:-}" = "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && return 0
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 0
    _EXAKIT_PERSONAL_DEPLOY_FOLLOWED="$EXAKIT_PERSONAL_DEPLOY_DIR"
    _pddr_old="${_EXAKIT_PERSONAL_DEPLOY_REC:-}"
    [ -n "$_pddr_old" ] && [ "$_pddr_old" != "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && [ ! -e "$_pddr_old" ] || return 0
    exakit_can_run_python_any 2>/dev/null || return 0
    command -v exakit_personal_deploy_dir_now >/dev/null 2>&1 || return 0
    # Not the kit's deployment (another id, or none recorded): no follow.
    [ "$(exakit_personal_deploy_dir_now "$_pddr_old")" = "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 0
    for _pddr_key in runtime.deployment_dir runtime.ownership_path; do
        [ "$(manifest_get "$_pddr_key" 2>/dev/null || true)" = "$_pddr_old" ] || continue
        manifest_set "$_pddr_key" "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || return 0
        # A follow across a rename names the folder it is in now.
        [ "$_pddr_key" != runtime.deployment_dir ] || \
            manifest_set runtime.deployment_name "$(basename "$EXAKIT_PERSONAL_DEPLOY_DIR")" 2>/dev/null || true
    done
    _EXAKIT_PERSONAL_DEPLOY_REC="$EXAKIT_PERSONAL_DEPLOY_DIR"
    return 0
}

# personal_check_requirements — the compatibility gate. Incompatible machines
# get a clear explanation and a graceful exit; machines at the bare minimum
# proceed with an explicit warning; comfortable machines get one quiet OK line.
# (Replaces the old "Detected environment" panel: users don't act on a table of
# facts — they act on "this will/won't work and why".)
EXAKIT_PERSONAL_COMFORT_RAM_GB="${EXAKIT_PERSONAL_COMFORT_RAM_GB:-12}"
EXAKIT_PERSONAL_COMFORT_DISK_GB="${EXAKIT_PERSONAL_COMFORT_DISK_GB:-40}"
# personal_heal_rootless_podman — fix what stops rootless Podman, instead of
# printing a command and walking away.
#
# THE KIT HAS NEVER RUN sudo, AND THIS IS THE ONE PLACE IT ASKS TO. Everything
# else it installs goes under ~/.local and ~/.exasol-starter-kit, which is why
# it needs no privilege at all. A rootless Podman gap is the exception: the
# sub-id ranges live in /etc/subuid and /etc/subgid and the uidmap helper is a
# system package, so there is no unprivileged fix to reach for. The old
# behaviour was to print the command in red and leave; the deploy then failed
# minutes later, inside a container start, with an error naming neither Podman
# nor the missing range.
#
# So: ask, run it, verify it, and say plainly what happened either way.
#
# CONSENT IS EXPLICIT AND NEVER ASSUMED. An interactive run is asked and
# defaults to yes, because it is the fix the reader came for. A run with no
# terminal is NOT: it must set EXAKIT_PODMAN_SELFHEAL=1 to opt in. A scripted
# install that silently edits /etc on a machine nobody is watching is not a
# self-heal, it is a surprise - and the kit's whole posture is that it does not
# touch anything outside the user's home without being told to.
#
# Never fatal. Podman can work in shapes this does not model, so a declined
# offer, a missing sudo, or a fix that does not take all leave the install to
# carry on and let the deploy be the judge.
personal_heal_rootless_podman() {
    _phr_kind="$(detect_rootless_podman_gap_kind 2>/dev/null || true)"
    [ -n "$_phr_kind" ] || return 0

    _phr_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
    _phr_why="$(detect_rootless_podman_gap 2>/dev/null || true)"

    case "$_phr_kind" in
        cgroups|pids)
            # No process can turn this on - cgroups v2 is a boot setting, and
            # a pids controller is a systemd delegation or, under WSL 2.9+, an
            # upstream fix. Say so, in the words of the platform the reader is
            # actually on, and let the deploy (and its container error) judge.
            warn "Rootless Podman: ${_phr_why}"
            return 0
            ;;
        subid)
            _phr_fix="usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $_phr_user"
            _phr_what="add a user-namespace range for $_phr_user"
            ;;
        uidmap)
            _phr_fix="$(_personal_uidmap_install_cmd)"
            _phr_what="install the uidmap package rootless Podman needs"
            [ -n "$_phr_fix" ] || { warn "Rootless Podman: ${_phr_why}"; return 0; }
            ;;
        *) return 0 ;;
    esac

    warn "Rootless Podman is not ready: ${_phr_why}"

    if ! command -v sudo >/dev/null 2>&1; then
        info "The kit can fix this, but 'sudo' is not on PATH. Run this as root, then re-run the installer:"
        info "  $_phr_fix"
        return 0
    fi

    # A terminal may be asked; a scripted run must have said so in advance.
    if [ -n "$(_exakit_prompt_tty)" ]; then
        confirm_env EXAKIT_PODMAN_SELFHEAL "Let the kit $_phr_what? It runs a command as administrator and will ask for your password" y || {
            info "Not changed. To do it yourself:  sudo $_phr_fix"
            return 0
        }
    else
        case "${EXAKIT_PODMAN_SELFHEAL:-}" in
            1|y|Y|yes|YES|Yes) : ;;
            *)
                info "The kit can fix this for you, but it edits system files, so an unattended run has to opt in:"
                info "  EXAKIT_PODMAN_SELFHEAL=1  (or run it yourself: sudo $_phr_fix)"
                return 0
                ;;
        esac
    fi

    info "Running: sudo $_phr_fix"
    # shellcheck disable=SC2086
    if ! sudo $_phr_fix; then
        warn "That did not go through. Run it yourself and re-run the installer:  sudo $_phr_fix"
        return 0
    fi

    # The ranges only take effect for Podman after it rebuilds its user
    # namespace, and a machine that has already run Podman keeps the old one.
    if [ "$_phr_kind" = subid ] && command -v podman >/dev/null 2>&1; then
        podman system migrate >/dev/null 2>&1 || true
    fi

    # VERIFY, never assume: usermod can succeed and still leave the gap when a
    # distribution manages its ranges somewhere else entirely.
    if [ -n "$(detect_rootless_podman_gap_kind 2>/dev/null || true)" ]; then
        warn "Rootless Podman still looks incomplete after the fix - carrying on, and the deploy will say if it matters."
        return 0
    fi
    ok "Rootless Podman is ready ($_phr_what)"
}

# _personal_uidmap_install_cmd — the install command for THIS distribution, or
# empty when its package manager is not one the kit knows. Named separately so
# the heal above reads as one decision.
# _personal_podman_install_cmd — the one command that installs Podman on this
# machine, or nothing when the package manager is not one the kit knows.
#
# uidmap rides along on Debian and Ubuntu: rootless Podman needs newuidmap and
# newgidmap, they ship in a separate package there, and without them the
# failure arrives much later, inside a container start, naming neither Podman
# nor the package. The same reasoning as _personal_uidmap_install_cmd below,
# which stays for the machine that has Podman but not those binaries.
# _personal_podman_install_cmd - the command to SHOW someone. Short enough to
# read, short enough to retype. What the kit actually runs is the hardened
# twin below; the two are kept apart because a wall of environment variables is
# the wrong thing to print at a reader who just wants to install Podman.
_personal_podman_install_cmd() {
    if command -v apt-get >/dev/null 2>&1; then printf 'apt-get install -y podman uidmap\n'; return 0; fi
    if command -v dnf     >/dev/null 2>&1; then printf 'dnf install -y podman\n'; return 0; fi
    if command -v yum     >/dev/null 2>&1; then printf 'yum install -y podman\n'; return 0; fi
    if command -v zypper  >/dev/null 2>&1; then printf 'zypper install -y podman\n'; return 0; fi
    if command -v pacman  >/dev/null 2>&1; then printf 'pacman -S --noconfirm podman\n'; return 0; fi
    if command -v apk     >/dev/null 2>&1; then printf 'apk add --no-cache podman\n'; return 0; fi
    return 1
}

# personal_podman_installable — can this machine be given Podman by the kit?
# A command to run and a way to become root: without either, the install stays
# the user's to do and the gate says so before anything is downloaded.
# _personal_podman_install_cmd_auto - the same command, hardened for a run
# whose output nobody is watching.
#
# THIS IS WHAT A CAPTURED INSTALL COSTS. With apt writing to the screen, a
# question from needrestart ("Which services should be restarted?" - installed
# by default on Ubuntu 22.04 and later) or from dpkg about a config file was
# visible and answerable. Behind a spinner it is not: the install waits on
# stdin for an answer nobody can see, for ever, and the only thing on screen is
# a spinner counting up. Measured at over 500 seconds before anyone gave up.
#
# So the prompts are turned off at the source. DEBIAN_FRONTEND stops debconf
# asking, NEEDRESTART_MODE=a restarts services without asking, and the two
# force-conf options keep the config files already on the machine, which is
# what a non-interactive apt should do. The redirect from /dev/null is the
# belt: ANY prompt that still gets through reads EOF and the command fails in
# a second instead of hanging, which is the failure a reader can act on.
_personal_podman_install_cmd_auto() {
    _ppica_cmd="$(_personal_podman_install_cmd 2>/dev/null || true)"
    [ -n "$_ppica_cmd" ] || return 1
    case "$_ppica_cmd" in
        apt-get*)
            # `apt-get update` first: a fresh Ubuntu image or container ships
            # with empty package lists, and the install then fails with
            # "Unable to locate package podman". Run inside the same `sh -c` so
            # sudo covers both halves. The printed command stays the short one.
            printf 'DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 %s -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold </dev/null\n' \
                "$_ppica_cmd"
            ;;
        *)
            # dnf, yum, zypper, pacman and apk all take their "assume yes" flag
            # above and have no debconf equivalent. The redirect still applies:
            # a prompt nobody can answer must fail, not wait.
            printf '%s </dev/null\n' "$_ppica_cmd"
            ;;
    esac
    return 0
}

personal_podman_installable() {
    _ppi_cmd="$(_personal_podman_install_cmd 2>/dev/null || true)"
    [ -n "$_ppi_cmd" ] || return 1
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && return 0
    command -v sudo >/dev/null 2>&1
}

# --- the container engine ---------------------------------------------------
# From launcher 2.4.0 a local deployment on Linux (and WSL) runs in Podman when
# Podman is installed, and otherwise in a Docker that runs Linux containers -
# the launcher's container_engine "auto". The kit follows the same rule rather
# than choosing for it: Podman is installed only where the launcher would need
# it, and every check the kit makes against a deployment asks the engine that
# deployment runs on. A deployment keeps the engine it first started on, which
# the launcher records in local/runtime/container-engine.json; one made before
# 2.4.0 has no record and runs in Podman. macOS has none of this: the launcher
# runs its own VM there, and personal_engine answers nothing.
PERSONAL_DOCKER_MIN_MAJOR=29

# personal_install_podman — Podman, when the database step finds it missing.
#
# WHERE THIS RUNS MATTERS. The launcher is installed first and the database is
# deployed second, and Podman is the thing the second step needs - so it is
# fetched between them, named, and installed once. Doing it in the gate instead
# would put a package install in front of a machine that has not yet agreed to
# anything, and refusing there (which is what happened before) sent a user off
# to a package manager and back to the beginning of the install.
#
# It asks first, because this is the one thing in the kit that touches the
# system rather than the user's home: same shape as the rootless self-heal
# above, same opt-in for an unattended run.
#
# AND IT RETURNS RATHER THAN ENDING THE RUN. Saying no used to close the whole
# install - the database step, and with it the launcher, exapump, the AI bridge
# and the exakit command itself, none of which the user had declined. Every
# other step in the kit that cannot finish records itself and lets the rest go
# on; this one now does too, and the closing summary names the one command that
# finishes it. 1 means "no database this time", and the caller stops there.
personal_install_podman() {
    command -v podman >/dev/null 2>&1 && return 0
    case "$(detect_os)" in
        linux|wsl) : ;;
        *) return 0 ;;   # macOS and Windows: the launcher brings its own
    esac
    # Docker runs this deployment: nothing to install.
    [ "${EXAKIT_PERSONAL_ENGINE:-$(personal_engine_recorded)}" = docker ] && return 0

    _pin_cmd="$(_personal_podman_install_cmd 2>/dev/null || true)"
    _pin_where="on this machine"
    [ "$(detect_os)" = wsl ] && _pin_where="inside this distro"

    warn "Podman is not installed $_pin_where, and the database runs through it."
    if [ -z "$_pin_cmd" ]; then
        info "This machine's package manager is not one the kit knows, so install Podman yourself and re-run."
        exakit_note_failure "Podman is not installed and the kit does not know this machine's package manager"
        return 1
    fi
    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ] && ! command -v sudo >/dev/null 2>&1; then
        info "The kit can install it, but 'sudo' is not on PATH. Run this as root, then re-run the installer:"
        info "  $_pin_cmd"
        exakit_note_failure "Podman is not installed and 'sudo' is not on PATH ($_pin_cmd)"
        return 1
    fi

    _pin_sudo=""
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || _pin_sudo="sudo "
    # PROMISED ONLY WHEN IT WILL HAPPEN. A machine with NOPASSWD, or one where
    # sudo was used a minute ago, is never asked for a password - and a
    # question that says it will be is a question that was not read carefully
    # enough to write.
    # NOT ASKED FOR ANY MORE. The database runs through Podman and the user
    # already asked for the database; a y/n whose only sensible answer is yes is
    # a question that buys nothing and costs a keystroke in the middle of an
    # install. It is still announced - the warn above says what is missing, and
    # the spinner below says what is being done about it - and the one command
    # it runs is in the logfile.
    #
    # EXAKIT_INSTALL_PODMAN=0 is the way out for anyone who needs one: a
    # scripted run on a machine where package installs are somebody else's job.
    # It is an opt-OUT rather than an opt-in, because the kit installing what
    # the database needs is now the default on every road.
    case "${EXAKIT_INSTALL_PODMAN:-}" in
        0|n|N|no|NO|No)
            info "Not installed (EXAKIT_INSTALL_PODMAN=0). To do it yourself:  ${_pin_sudo}$_pin_cmd"
            exakit_note_failure "Podman was not installed (EXAKIT_INSTALL_PODMAN=0); the database needs it"
            return 1
            ;;
    esac

    # THE PASSWORD AND THE PACKAGE MANAGER ARE TWO DIFFERENT THINGS, and
    # running them as one is what put three screens of apt through the middle
    # of an install that shows one line per step. A captured sudo asking for a
    # password behind a spinner is a machine that looks hung - so the password
    # is asked for FIRST, in the open and on its own, and the package manager
    # then runs behind the spinner with a credential it no longer has to ask
    # about. Nothing is hidden: every line apt printed is in the logfile.
    if [ -n "$_pin_sudo" ] && ! sudo -n true 2>/dev/null; then
        if [ -z "$(_exakit_prompt_tty)" ]; then
            # No terminal to type a password on. Said, not waited on: a
            # captured sudo would sit on stdin for ever behind a spinner.
            info "This run has no terminal to type an administrator password on. Run it yourself, then re-run:  ${_pin_sudo}$_pin_cmd"
            exakit_note_failure "Podman needs an administrator password and this run has no terminal to ask for one"
            return 1
        fi
        # "this one command" UNDERSTATED IT. What is obtained is a sudo
        # timestamp, reusable for the rest of its timeout, and what is run
        # under it is `sh -c "<package manager install>"` - a root shell
        # running the distro's own maintainer scripts. That is the ordinary
        # way to install a package and it is fine; describing it as one
        # command was what was not fine, because the reader sizing the request
        # was sizing the wrong thing.
        info "Your password, to install Podman as administrator (this grants sudo for the rest of its usual timeout):"
        if ! sudo -v; then
            info "Not installed. To do it yourself:  ${_pin_sudo}$_pin_cmd"
            exakit_note_failure "The administrator password for the Podman install was not given"
            return 1
        fi
    fi
    EXAKIT_ACTIVE_LABEL="Installing Podman"
    # -n on the RUN, never on the ask above: a sudoers with timestamp_timeout=0
    # caches nothing, and without this the captured command would hang on a
    # password prompt nobody can see. It fails in a second instead, with the
    # command to run by hand.
    _pin_run="$_pin_sudo"
    [ -n "$_pin_run" ] && _pin_run="sudo -n "
    # The hardened twin, never the printed one: see
    # _personal_podman_install_cmd_auto for what a captured apt costs without it.
    _pin_auto="$(_personal_podman_install_cmd_auto 2>/dev/null || printf '%s' "$_pin_cmd")"
    # shellcheck disable=SC2086
    if ! run_logged ${_pin_run}sh -c "$_pin_auto"; then
        EXAKIT_ACTIVE_LABEL=""
        info "Run it yourself and re-run the installer:  ${_pin_sudo}$_pin_cmd"
        exakit_note_failure "Podman could not be installed (${_pin_sudo}$_pin_cmd)"
        return 1
    fi
    EXAKIT_ACTIVE_LABEL=""
    if ! command -v podman >/dev/null 2>&1; then
        warn "The install reported success, but 'podman' is still not on PATH."
        info "Open a new shell and re-run the installer."
        exakit_note_failure "Podman installed but not on PATH in this shell"
        return 1
    fi
    ok "Podman installed ($(podman --version 2>/dev/null | head -1))"
    # The sub-id ranges and uidmap are checked the moment Podman exists, so a
    # machine that has just been given it is not left one container start away
    # from a failure that names neither.
    personal_heal_rootless_podman || true
    return 0
}

_personal_uidmap_install_cmd() {
    if command -v apt-get >/dev/null 2>&1; then printf 'apt-get install -y uidmap\n'; return 0; fi
    if command -v dnf     >/dev/null 2>&1; then printf 'dnf install -y shadow-utils\n'; return 0; fi
    if command -v zypper  >/dev/null 2>&1; then printf 'zypper install -y shadow\n'; return 0; fi
    if command -v pacman  >/dev/null 2>&1; then printf 'pacman -S --noconfirm shadow\n'; return 0; fi
    return 1
}

personal_check_requirements() {
    _pcr_os="$(detect_os)"
    case "$_pcr_os" in
        macos) : ;;
        linux|wsl)
            # ...WSL 2. WSL 1 is not Linux to anyone: it translates syscalls to
            # the NT kernel, so it has no cgroups, no user namespaces, and no
            # container runtime that can work. detect_wsl_version exists to
            # gate exactly this refusal - its own comment says so - and until
            # now nothing called it for that. Unrefused, a WSL 1 distro reached
            # the Podman branch below, `apt-get install podman` SUCCEEDED, and
            # the failure surfaced minutes later as a raw cgroups error, after
            # a sudo package install the user never needed.
            if [ "$_pcr_os" = wsl ] && [ "$(detect_wsl_version 2>/dev/null)" = "1" ]; then
                error "This is a WSL 1 distro. Exasol Personal runs the database in a container, and WSL 1 has no Linux kernel to run one with."
                info "Convert this distro to WSL 2, from PowerShell on the Windows side:"
                info "  wsl --list --verbose          (find this distro's name and see its version)"
                info "  wsl --set-version <distro> 2  (converts it; your files are kept)"
                info "Then reopen the distro and re-run the installer: $(exakit_install_command)"
                die "WSL 1 is not supported: Exasol Personal needs a real Linux kernel."
            fi
            # MUSL IS REFUSED BEFORE ANYTHING IS INSTALLED (LNX-06). Alpine and other
            # musl distros got a `sudo apk add podman` and then binaries - the
            # launcher, exapump, uv's Python - that are built for glibc and do not
            # run there. Said at the start, with the way that works.
            if detect_musl 2>/dev/null; then
                error "This Linux uses the musl C library (Alpine or similar). The Exasol launcher, exapump and the kit's Python are built for glibc and cannot run here."
                info "Use a glibc distribution (Ubuntu, Debian, Fedora, RHEL and its rebuilds), for example in a VM or a WSL 2 distro, and run the installer there."
                die "Unsupported C library: musl."
            fi
            # A KIT HOME ON A WINDOWS DRIVE, refused before the first password is
            # written (WSL-06). DrvFs mounts without Linux permissions, so the
            # chmod 600 on the database passwords is accepted and discarded: any
            # Windows user can read them, and OneDrive syncs them. The preflight
            # said so; the install itself only warned after writing them there.
            if [ "$_pcr_os" = wsl ] && detect_wsl_drvfs_path "$EXAKIT_HOME" 2>/dev/null; then
                error "The kit home $EXAKIT_HOME is on a Windows drive: WSL mounts those without Linux file permissions, so the database passwords stored there could not be protected (any Windows user could read them, and OneDrive would sync them)."
                info "Put the kit on the Linux filesystem and re-run the installer: EXAKIT_HOME=\$HOME/.exasol-starter-kit $(exakit_install_command)"
                die "Kit home on a Windows drive: $EXAKIT_HOME."
            fi
            # WSL IS LINUX TO THE LAUNCHER, AND THAT IS THE WHOLE STORY. A WSL2
            # distro is an AMD64 Linux with a real kernel, the launcher ships a
            # Linux build, and its Linux local runtime asks for exactly one
            # thing - a podman on PATH (linuxHostEnvironmentPreparer.EnsureReady
            # is a single exec.LookPath). No systemd, no cgroup check, no WSL
            # detection anywhere on that path.
            #
            # The kit used to refuse WSL outright, reasoning that "Personal's
            # Windows path is host Podman inside a Podman machine, not WSL".
            # That confused two different things: the WSL every launcher source
            # file mentions is the one podman-for-windows boots for ITSELF
            # (podman-machine-default), driven by the WINDOWS launcher. It says
            # nothing about a user's own Ubuntu distro, where the LINUX launcher
            # runs and the Linux requirements are the ones that apply.
            #
            # The launcher checked before anything is downloaded, so a machine
            # without podman is told once, at the start, and not mid-install.
            #
            # ONLY WHEN THE DEPLOYMENT WILL RUN ON PODMAN. Since 2.4 a usable
            # Docker takes a new deployment, and a Docker box was warned that
            # the database step would be skipped, or offered a sudo fix to a
            # Podman nothing would use. "Not docker" rather than "podman": an
            # answer that cannot be had keeps the checks, as before 2.4.
            # In THIS shell, not $(...): the Docker and launcher answers it
            # gets are kept for the deploy step, which then asks nobody again.
            personal_engine_planned >/dev/null 2>&1 || true
            _pcr_engine="${_PERSONAL_PLANNED:-}"
            if [ "$_pcr_engine" != docker ] && ! command -v podman >/dev/null 2>&1; then
                # "in WSL" / "on Linux": the same sentence with the platform
                # spelled the way its user would say it, not the way detect_os
                # returns it.
                _pcr_where="on Linux"
                [ "$_pcr_os" = wsl ] && _pcr_where="in WSL"
                if personal_podman_installable; then
                    # THE KIT CAN FETCH IT, so this is not a reason to stop -
                    # and not a reason to say anything either. The database
                    # step names it, asks, and installs it, all within a few
                    # seconds of here; saying it twice made the compatibility
                    # check carry a line about something it was not doing.
                    # Falling through rather than returning: the RAM and
                    # free-disk checks below are the rest of this gate, and a
                    # machine short of both would otherwise hear about neither.
                    :
                else
                    # THE KIT CANNOT FETCH IT HERE - and that used to end the
                    # run before a single file was written, taking the
                    # launcher, exapump, the AI bridge and the exakit command
                    # with it. None of those need Podman. ONE PLACE decides
                    # what a missing Podman costs, and it is the database step:
                    # it records the failure and the closing summary names the
                    # command that finishes the job. Still said here, though,
                    # because hearing it at the start is what saves someone
                    # watching a whole install to find out.
                    warn "Podman is not installed ${_pcr_where}, and the kit cannot install it on this machine."
                    info "The database step will be skipped; everything that does not need it still installs."
                    if [ "$_pcr_os" = wsl ]; then
                        # Inside WSL the package manager is the distro's own,
                        # and uidmap is the part people miss: without it
                        # rootless podman fails later, deep inside a container
                        # start, with an error that names neither podman nor
                        # the missing package.
                        info "Install it inside this distro (Debian/Ubuntu: 'sudo apt-get install -y podman uidmap'), then re-run the installer: $(exakit_install_command)"
                        info "Podman Desktop or Docker Desktop on the WINDOWS side does not count - the launcher runs in here and looks on this PATH."
                    else
                        info "Install it with your package manager (e.g. 'sudo apt-get install -y podman' or 'sudo dnf install -y podman'), then re-run the installer: $(exakit_install_command)"
                    fi
                fi
            fi
            # ROOTLESS IS CHECKED HERE, AND FIXED HERE. Nothing used to look
            # at it on the install path at all: the preflight knew, printed a
            # red line, and the installer went on to deploy anyway - so the
            # first a user heard of a missing sub-id range was a container
            # start failing minutes later, naming neither Podman nor the range.
            # Same place as the podman check above, so it happens before
            # anything is downloaded. Only once Podman exists, though: on a
            # machine that is about to be given it there is nothing yet to
            # check, and personal_install_podman runs this itself the moment
            # the package lands.
            if [ "$_pcr_engine" != docker ] && command -v podman >/dev/null 2>&1; then
                personal_heal_rootless_podman
            fi
            ;;
        *)
            error "Exasol Personal supports macOS, Linux (native or WSL) and Windows x86_64 - it does not support $_pcr_os."
            info "Nothing was installed. On Windows use install.ps1."
            die "Incompatible platform: $_pcr_os."
            ;;
    esac

    _arch="$(detect_arch)"
    if [ "$_arch" = "unsupported" ]; then
        error "This machine is not compatible: no Exasol Personal build exists for the '$(uname -m)' CPU architecture."
        # In the platform's own words: "Apple Silicon" told a Raspberry Pi
        # (armv7l) or a ppc64le box what a Mac would need (LNX-13).
        case "$_pcr_os" in
            macos) info "Supported on macOS: Apple Silicon (arm64) and Intel (x86_64)." ;;
            *)     info "Supported on Linux: 64-bit x86 (x86_64) and 64-bit Arm (aarch64/arm64) - not 32-bit Arm (armv7l), ppc64le, s390x or riscv64." ;;
        esac
        die "Incompatible CPU architecture: $(uname -m)."
    fi

    _ram="$(detect_ram_gb)"
    # Mode P keeps its database, downloads and all in the kit home.
    _pcr_disk="$HOME"
    if [ "${EXAKIT_PERSONAL_MODE:-}" = P ]; then
        _pcr_disk="$EXAKIT_PERSONAL_PRIVATE_DIR"
        while [ ! -e "$_pcr_disk" ] && [ "$_pcr_disk" != / ]; do _pcr_disk="$(dirname "$_pcr_disk")"; done
    fi
    _disk="$(detect_free_disk_gb "$_pcr_disk")"
    if [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        if [ "$_ram" -eq 0 ]; then
            die "Could not determine this machine's memory. Fix the environment or set EXAKIT_FORCE=1 to install anyway."
        fi
        if [ "$_ram" -lt "$EXAKIT_PERSONAL_MIN_RAM_GB" ]; then
            error "This machine is not compatible: Exasol Personal needs at least ${EXAKIT_PERSONAL_MIN_RAM_GB} GB RAM and this machine has ${_ram} GB."
            if [ "$_pcr_os" = wsl ]; then
                # /proc/meminfo in WSL reports the VM's share, not the PC's, so
                # "re-run on a bigger machine" would send someone to buy RAM
                # they already own. The knob is on the Windows side.
                info "That is what WSL was given, not what this PC has. Raise it in %USERPROFILE%\\.wslconfig on the WINDOWS side:"
                info "  [wsl2]"
                info "  memory=8GB"
                info "Then apply it from PowerShell: wsl --shutdown  (reopen this distro afterwards)"
                # The escape hatch belongs in BOTH arms. It was only in the else
                # branch, so it was invisible to exactly the users most likely to
                # be refused by a rounding edge on a machine that really does have
                # the memory.
                info "Already sized correctly? Force past this check with EXAKIT_FORCE=1."
            else
                info "Nothing was installed. Re-run on a machine with ${EXAKIT_PERSONAL_MIN_RAM_GB}+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            fi
            die "Insufficient memory: ${_ram} GB."
        fi
        if [ "$_disk" -eq 0 ]; then
            die "Could not determine free disk space at $HOME. Free up space or set EXAKIT_FORCE=1 to install anyway."
        fi
        if [ "$_disk" -lt "$EXAKIT_PERSONAL_MIN_DISK_GB" ]; then
            error "This machine is not compatible right now: the database needs at least ${EXAKIT_PERSONAL_MIN_DISK_GB} GB free disk and $HOME has ${_disk} GB."
            # WHERE THAT NUMBER CAME FROM, when it did not come from this
            # filesystem. Inside a WSL2 distro the root fs is a sparse VHDX
            # formatted to WSL's maximum, so `df` there can say 900 GB while
            # the Windows drive holding it has 6 - and a refusal quoting 6
            # reads as nonsense to someone whose own `df` says otherwise.
            _pcr_disk_note="$(detect_free_disk_note "$HOME" 2>/dev/null || true)"
            [ -n "$_pcr_disk_note" ] && info "Why: $_pcr_disk_note"
            info "Nothing was installed. Free up disk space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient free disk space: ${_disk} GB."
        fi
    fi

    # A knob that does nothing must say so, not be silently ignored: the README
    # and the preflight offer EXAKIT_DB_PORT for port conflicts, but only the
    # container deployments honour it - the launcher picks the port for a
    # personal deployment and the kit reads it back with personal_db_port.
    # EXAKIT_DB_PORT_EXPLICIT, not the value: common.sh defaults the value to
    # 8563, so testing it warned on a plain re-run whenever the launcher had
    # picked another port, about a variable the user never set.
    if [ -n "${EXAKIT_DB_PORT_EXPLICIT:-}" ] && [ "${EXAKIT_DB_PORT}" != "$(personal_db_port)" ]; then
        warn "EXAKIT_DB_PORT does not choose the port of an Exasol Personal deployment: the launcher selects it and the kit uses whatever it selected (currently $(personal_db_port))."
    fi

    # Bare minimum: run, but say what to expect.
    if [ "$_ram" -lt "$EXAKIT_PERSONAL_COMFORT_RAM_GB" ]; then
        warn "Memory is at the bare minimum (${_ram} GB; comfortable: ${EXAKIT_PERSONAL_COMFORT_RAM_GB}+ GB) — the database will run, but expect slower queries and keep other heavy apps closed."
    fi
    if [ "$_disk" -lt "$EXAKIT_PERSONAL_COMFORT_DISK_GB" ]; then
        warn "Free disk is tight (${_disk} GB; comfortable: ${EXAKIT_PERSONAL_COMFORT_DISK_GB}+ GB) — fine for the bundled datasets, but watch space before loading large files."
    fi
    ok "Compatibility check passed ($_pcr_os $_arch, ${_ram} GB RAM, ${_disk} GB free)"
}

personal_asset_name() {
    # The launcher's release spelling, verbatim: macOS capitalised mid-word,
    # Linux capitalised - a lowercased guess here is a 404 at download time.
    case "$(detect_os)" in
        macos) _pan_os="macOS" ;;
        *)     _pan_os="Linux" ;;
    esac
    case "$(detect_arch)" in
        arm64)  echo "exasol-personal_${_pan_os}_arm64.tar.gz" ;;
        x86_64) echo "exasol-personal_${_pan_os}_x86_64.tar.gz" ;;
    esac
}

personal_release_url() {
    echo "https://github.com/${EXAKIT_PERSONAL_REPO}/releases/download/v${EXAKIT_PERSONAL_VERSION}"
}

# The S3 URL and SHA-256 describe a RAW executable, not the GitHub archive.
# Never use a manifest pin for a different target version (including an env
# override or latest policy). Missing/invalid S3 metadata is a safe GitHub
# fallback, not permission to run an unchecked binary.
personal_s3_source() {
    # EXAKIT_PERSONAL_S3=0: the user's network blocks the bucket, or they want
    # the release path for its own sake; the GitHub download is as verified.
    [ "${EXAKIT_PERSONAL_S3:-1}" = "0" ] && return 1
    # The kit copy's own pins, never the fetched document (SEC-13).
    _pss_manifest_version="$(exakit_versions_pin components.personal.version 2>/dev/null || true)"
    [ "$_pss_manifest_version" = "$EXAKIT_PERSONAL_VERSION" ] || return 1
    _pss_base="$(exakit_versions_pin components.personal.s3.base_url 2>/dev/null || true)"
    case "$_pss_base" in https://*) : ;; *) return 1 ;; esac
    case "$(detect_os)" in
        macos) _pss_os=macos ;;
        linux|wsl) _pss_os=linux ;;
        *) return 1 ;;
    esac
    case "$(detect_arch)" in arm64|x86_64) _pss_arch="$(detect_arch)" ;; *) return 1 ;; esac
    _pss_hash="$(exakit_versions_pin "components.personal.s3.sha256.${_pss_os}-${_pss_arch}" 2>/dev/null || true)"
    case "$_pss_hash" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#_pss_hash}" -eq 64 ] || return 1
    printf '%s\n%s\n' "${_pss_base%/}/${_pss_os}/${_pss_arch}/${EXAKIT_PERSONAL_VERSION}/exasol" "$_pss_hash"
}

# personal_deployed_version — the launcher version that created the deployment
# currently on disk; empty (non-zero) when there is no deployment, or its
# version cannot be read.
#
# Read from deployment STATE, never by executing a launcher. The decision this
# feeds has to be made BEFORE any binary is downloaded or installed, and the
# only launcher that could answer `exasol info` may be the very one about to be
# overwritten — so asking it is both too late and unreliable. Two state files
# carry the version, both written into the deployment directory by the launcher:
#   .exasolLauncher.version    the bare version ("2.1.0"), no trailing newline
#   .exasolLauncherState.json  "deploymentVersion": "2.1.0"
# The bare file is preferred (nothing to parse); the JSON is the fallback for a
# deployment that only carries it there. Neither needs python3, so this works on
# a machine where the installer has not reached its Python step yet.
personal_deployed_version() {
    personal_deploy_dir_refresh
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 1

    _pdv_raw=""
    _pdv_file="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncher.version"
    if [ -f "$_pdv_file" ]; then
        _pdv_raw="$(tr -d '[:space:]' < "$_pdv_file" 2>/dev/null || true)"
    fi
    if [ -z "$_pdv_raw" ]; then
        _pdv_state="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json"
        if [ -f "$_pdv_state" ]; then
            # Plain BRE, no alternation and no -E: the state file is written as
            # one line, and tr keeps it one line even if that ever changes.
            _pdv_raw="$(tr -d '\012\015' < "$_pdv_state" 2>/dev/null | \
                sed -n 's/.*"deploymentVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        fi
    fi

    _pdv_raw="${_pdv_raw#v}"
    # Only answer with something that actually looks like a version. A truncated,
    # empty or garbage state file must read as "unknown" and let the install
    # proceed — never as a version that could wrongly block it.
    case "$_pdv_raw" in
        ""|*[!0-9A-Za-z.+_-]*) return 1 ;;
    esac
    case "$_pdv_raw" in
        [0-9]*) printf '%s\n' "$_pdv_raw" ;;
        *) return 1 ;;
    esac
}

# personal_launcher_version — the version of the launcher BINARY on this
# machine, asked of the binary itself ("exasol version" prints it bare).
#
# The deployment's version and the launcher's version are two different facts,
# and conflating them is what made a completed update advertise itself
# forever: `exakit update` swapped the launcher, personal_record_manifest then
# recorded the DEPLOYMENT's number (unchanged - a deployment keeps the version
# that created it until it is rebuilt), and every later `exakit version` saw
# the same gap and offered the same update again.
#
# Bounded like every other launcher probe, and empty when the launcher cannot
# answer - a caller that cannot learn this falls back to what it knew.
personal_launcher_version() {
    _plv="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" version 2>/dev/null | head -1 | tr -d '[:space:]')"
    _plv="${_plv#v}"
    case "$_plv" in
        ""|*[!0-9A-Za-z.+_-]*) return 1 ;;
        [0-9]*) printf '%s\n' "$_plv" ;;
        *) return 1 ;;
    esac
}

# personal_deployment_outranks <deployed> <advertised> — true ONLY when the
# deployed version is demonstrably higher, comparing dotted numeric components
# left to right and treating a missing component as 0 (so 2.1 > 2). Anything it
# cannot decide is false: this answer blocks an install, and a refusal must never
# be a guess.
#
# Deliberately not exakit_version_newer: without Python that helper falls back to
# "same major, different tag -> worth inspecting" and answers true in BOTH
# directions, which is the right bias for offering an update and exactly the
# wrong one here — it would refuse a legitimate 2.0.0 -> 2.1.0 upgrade on any
# machine that has no Python runtime yet. This comparison needs no Python at all.
personal_deployment_outranks() {
    # Only the numeric release matters for "can this launcher drive this
    # deployment"; drop any pre-release/build suffix.
    _pdo_a="${1#v}"
    _pdo_b="${2#v}"
    _pdo_a="${_pdo_a%%[!0-9.]*}"
    _pdo_b="${_pdo_b%%[!0-9.]*}"
    [ -n "$_pdo_a" ] && [ -n "$_pdo_b" ] || return 1
    while [ -n "$_pdo_a" ] || [ -n "$_pdo_b" ]; do
        _pdo_ha="${_pdo_a%%.*}"
        _pdo_hb="${_pdo_b%%.*}"
        [ -n "$_pdo_ha" ] || _pdo_ha=0
        [ -n "$_pdo_hb" ] || _pdo_hb=0
        case "$_pdo_ha$_pdo_hb" in *[!0-9]*) return 1 ;; esac
        [ "$_pdo_ha" -gt "$_pdo_hb" ] && return 0
        [ "$_pdo_ha" -lt "$_pdo_hb" ] && return 1
        case "$_pdo_a" in *.*) _pdo_a="${_pdo_a#*.}" ;; *) _pdo_a="" ;; esac
        case "$_pdo_b" in *.*) _pdo_b="${_pdo_b#*.}" ;; *) _pdo_b="" ;; esac
    done
    return 1
}

# personal_refuse_launcher_downgrade — never install a launcher older than the
# deployment already on disk.
#
# A launcher refuses to drive a deployment newer than itself, and says so in a
# wall of its own text ending in usage output:
#   deployment directory is incompatible with this launcher: Deployment version
#   2.1.0 is newer than launcher version 2.0.0 (command install)
# Installing the older launcher therefore does not merely fail — it leaves the
# database undriveable, and every re-run fails identically. The trigger is real:
# maintainers lower the advertised set to withdraw a faulty release, and the
# next installer re-run on a machine already carrying the newer deployment
# breaks it.
#
# `exakit update` already refuses a downgrade (and exakit_update_component
# refuses again at the choke point), but both compare the advertised version
# against the INSTALL RECORD, and neither is on this path: the installer calls
# personal_install_launcher directly and held no version opinion at all. This
# guard is not a copy of that one — it asks a different, more authoritative
# question (what is actually deployed on disk), and it answers it before the
# first byte is downloaded.
personal_refuse_launcher_downgrade() {
    personal_deploy_dir_refresh
    [ -n "${EXAKIT_PERSONAL_VERSION:-}" ] || return 0
    _prd_deployed="$(personal_deployed_version 2>/dev/null || true)"
    [ -n "$_prd_deployed" ] || return 0
    personal_deployment_outranks "$_prd_deployed" "$EXAKIT_PERSONAL_VERSION" || return 0

    error "The Exasol Personal deployment on this machine is version ${_prd_deployed}, which is newer than the launcher version this kit advertises (${EXAKIT_PERSONAL_VERSION})."
    info "A ${EXAKIT_PERSONAL_VERSION} launcher refuses to drive a ${_prd_deployed} deployment, so installing it would leave your database unusable. Nothing was installed or changed."
    info "Deployment: $(ui_tilde "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    info "To install the launcher that matches your deployment, re-run with: EXAKIT_PERSONAL_VERSION=${_prd_deployed}"
    info "To start over on ${EXAKIT_PERSONAL_VERSION} instead, remove the newer deployment first with 'exakit uninstall' — that deletes its data."
    die "Refusing to install launcher ${EXAKIT_PERSONAL_VERSION} over a newer ${_prd_deployed} deployment."
}

# personal_launcher_newer — is the launcher the kit would drive (personal_cli:
# the one at $EXAKIT_PERSONAL_BIN, else the one on PATH), whoever installed it,
# on a newer release line than the one this kit pins (a 2.6.x next to a 2.5.0
# pin)? 0 when it is, with its version in PERSONAL_LAUNCHER_NEWER_VERSION. A
# patch ahead on the pinned line is not newer: that is the kit's own update
# path. Only `version` is asked; nothing is started, stopped or moved.
# Twin of Test-PersonalLauncherNewer.
personal_launcher_newer() {
    PERSONAL_LAUNCHER_NEWER_VERSION=""
    _pln_pin="${EXAKIT_PERSONAL_VERSION:-${EXAKIT_PERSONAL_VERSION_FALLBACK:-}}"
    [ -n "$_pln_pin" ] || return 1
    _pln_cli="$(personal_cli 2>/dev/null || true)"
    [ -n "$_pln_cli" ] && [ -x "$_pln_cli" ] || return 1
    _pln_ver="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$_pln_cli" version 2>/dev/null | head -1 | tr -d '[:space:]')"
    _pln_ver="${_pln_ver#v}"
    case "$_pln_ver" in [0-9]*) : ;; *) return 1 ;; esac
    # The release line: 2.5.3 is 2.5, 2.6.0 is 2.6.
    personal_deployment_outranks "$(printf '%s' "$_pln_ver" | awk -F. '{print $1"."$2".0"}')" \
        "$(printf '%s' "$_pln_pin" | awk -F. '{print $1"."$2".0"}')" || return 1
    PERSONAL_LAUNCHER_NEWER_VERSION="$_pln_ver"
    return 0
}

# personal_warn_launcher_newer — the one line the installer says about such a
# launcher before its first step. The install goes on with it: the launcher
# stays the user's, never replaced or downgraded, and a database of theirs is
# offered for use as any other. ⇄ twin: Write-PersonalLauncherNewerWarning.
personal_warn_launcher_newer() {
    personal_launcher_newer || return 0
    warn "Exasol Personal $PERSONAL_LAUNCHER_NEWER_VERSION is on this computer. This kit is tested with Exasol Personal ${EXAKIT_PERSONAL_VERSION:-${EXAKIT_PERSONAL_VERSION_FALLBACK:-}} and uses the launcher it found."
}

# personal_kit_launcher_behind <path> — the version of the launcher at <path>
# when it is the KIT'S OWN (at $EXAKIT_PERSONAL_BIN, with the kit's receipt and
# digest: exakit_component_is_managed) and older than the version this run
# installs; nothing (status 1) otherwise. A launcher of the user's, one ahead of
# the pin or at it, and every launcher in an installer that `exakit update`
# started (that update decides the launcher itself) answer 1, and keep the
# reuse they always had. The kit's launcher while the kit's own database is
# missing (exakit_personal_db_state) answers its version too: the 0.3.0 kit
# whose `default` a hand-installed 2.5 moved keeps launcher 2.4.0, which
# cannot list that `default` for the installer's one question. Its caller
# then replaces the launcher only, with nothing stopped, and nothing acts on
# the deployment in the kit's place (personal_install_launcher). Twin of
# Get-PersonalKitLauncherBehind (MAC-01).
personal_kit_launcher_behind() {
    # The kit folder's launcher, or a 0.3.0 kit's own at ~/.local/bin/exasol
    # (its receipt the kit's), which the update moves into the kit folder.
    [ "$1" = "$EXAKIT_PERSONAL_BIN" ] || [ "$1" = "$EXAKIT_BIN_DIR/exasol" ] || return 1
    [ -n "${EXAKIT_PERSONAL_VERSION:-}" ] || return 1
    if command -v exakit_core_rerun_active >/dev/null 2>&1 && exakit_core_rerun_active; then return 1; fi
    exakit_component_is_managed personal || return 1
    _pklb="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$1" version 2>/dev/null | head -1 | tr -d '[:space:]')"
    _pklb="${_pklb#v}"
    case "$_pklb" in [0-9]*) : ;; *) return 1 ;; esac
    exakit_version_newer "$EXAKIT_PERSONAL_VERSION" "$_pklb" || return 1
    printf '%s\n' "$_pklb"
}

# personal_update_behind_launcher <installed> — the kit's own launcher, behind
# the pin, over a deployment the kit records: the installer brings it to the
# pin the way `exakit update` does (personal_update: a 0.3.0 `default` renamed
# to starter-kit-local, the launcher swap, the folder the 2.5.0 launcher moves,
# the 20-session limit, in one restart). A running database is
# stopped, updated and started again with no question, as `exakit update` does
# (exakit_offer_runtime_update). Only EXAKIT_CONFIRM_RUNTIME_UPDATE=0 keeps the
# launcher as it is. Twin of Update-PersonalBehindLauncher (MAC-01).
personal_update_behind_launcher() {
    _publ_have="$1"
    _publ_want="$EXAKIT_PERSONAL_VERSION"
    # personal_update exports these for its own install; the installer's
    # later steps read the first one, so both are put back.
    _publ_force="${EXAKIT_FORCE_COMPONENT_INSTALL-}"; _publ_force_set="${EXAKIT_FORCE_COMPONENT_INSTALL+set}"
    _publ_confirm="${EXAKIT_CONFIRM_RUNTIME_UPDATE-}"; _publ_confirm_set="${EXAKIT_CONFIRM_RUNTIME_UPDATE+set}"
    case "$(personal_status 2>/dev/null || true)" in
        running|starting)
            exakit_offer_runtime_update personal personal "$_publ_have" "$_publ_want" || true ;;
        *)
            if exakit_runtime_update_is_staged "$_publ_have" "$_publ_want"; then
                warn "personal $_publ_have -> $_publ_want is a major upgrade: it needs a backup and a data migration, so a routine update does not start it."
            else
                exakit_update_component personal || true
            fi ;;
    esac
    if [ -n "$_publ_force_set" ]; then EXAKIT_FORCE_COMPONENT_INSTALL="$_publ_force"; else unset EXAKIT_FORCE_COMPONENT_INSTALL; fi
    if [ -n "$_publ_confirm_set" ]; then EXAKIT_CONFIRM_RUNTIME_UPDATE="$_publ_confirm"; else unset EXAKIT_CONFIRM_RUNTIME_UPDATE; fi
    return 0
}

# personal_launcher_download — the launcher release this run installs
# (EXAKIT_PERSONAL_VERSION), downloaded into the folder $_tmp and verified:
# the raw binary from Exasol's S3 against the SHA-256 this kit pins, else the
# GitHub release archive against its checksums file. _binary names the
# verified binary. Ends the run (die) when it cannot be had or does not
# match: nothing is installed by it. personal_install_launcher installs it
# as the kit's; the update of a user's own launcher (personal_update_user)
# puts it in place of theirs.
personal_launcher_download() {
    # Re-assigned per phase rather than printed: fetch and run_logged read this
    # at their next ui_spin_begin, so the words change on the operation boundary
    # without a second animator and without restarting the one already running.
    EXAKIT_ACTIVE_LABEL="Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION}"
    _pil_source="github"
    _pil_s3="$(personal_s3_source 2>/dev/null || true)"
    if [ "${EXAKIT_PERSONAL_S3:-1}" = "0" ]; then
        info "Exasol S3 skipped (EXAKIT_PERSONAL_S3=0); using the verified GitHub release"
    elif [ -n "$_pil_s3" ]; then
        _pil_s3_url="${_pil_s3%%$'\n'*}"
        _pil_s3_hash="${_pil_s3#*$'\n'}"
        info "Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION} from Exasol S3"
        if fetch_soft "$_pil_s3_url" "$_tmp/exasol"; then
            _pil_actual="$(sha256_of "$_tmp/exasol")"
            if [ "$_pil_actual" = "$_pil_s3_hash" ]; then
                _pil_source="s3"
                ok "S3 launcher SHA-256 verified"
            else
                # A MISMATCH IS NOT A MISSING FILE (SEC-03). Falling back to
                # GitHub here traded a pin that failed for a checksum file that
                # sits beside the archive it vouches for - the weaker check, picked
                # exactly when the stronger one said something is wrong. Nothing
                # is installed; the person decides.
                _exakit_log_file "ERROR S3 launcher SHA-256 expected $_pil_s3_hash, got $_pil_actual"
                rm -f "$_tmp/exasol"
                error "The Exasol launcher from Exasol's server does not match the checksum this kit pins for v${EXAKIT_PERSONAL_VERSION}, so it was not installed."
                info "That is either a changed file on the server or a wrong pin: report it (exakit logs setup has both checksums)."
                info "To install from the GitHub release instead, checked against its own checksums file: EXAKIT_PERSONAL_S3=0 $(exakit_install_command)"
                die "Launcher checksum mismatch (Exasol S3)."
            fi
        else
            warn "Could not download the launcher from Exasol's server; getting the same version from the verified GitHub release instead."
        fi
    else
        info "Launcher v${EXAKIT_PERSONAL_VERSION} is not the version versions.json pins for Exasol's server; using the verified GitHub release"
    fi

    if [ "$_pil_source" = "github" ]; then
        rm -f "$_tmp/exasol"
        _asset="$(personal_asset_name)"
        _base="$(personal_release_url)"
        info "Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION} ($_asset)"
        fetch "$_base/$_asset" "$_tmp/$_asset"
        fetch "$_base/exasol-personal_${EXAKIT_PERSONAL_VERSION}_checksums.txt" "$_tmp/checksums.txt"
        verify_sha256_from_file "$_tmp/$_asset" "$_tmp/checksums.txt"
        # Into a folder of its own: the search below must never be able to
        # pick a discarded S3 candidate. Twin of the release folder in
        # Install-PersonalLauncher.
        mkdir -p "$_tmp/release"
        run_logged tar -xzf "$_tmp/$_asset" -C "$_tmp/release" || die "Could not extract $_asset"
        _binary="$(find "$_tmp/release" -name exasol -type f | head -1)"
        [ -n "$_binary" ] || die "The release archive did not contain an 'exasol' binary"
    else
        _binary="$_tmp/exasol"
    fi
}

# personal_retire_bin_launcher <old path> <old sha256> — a 0.3.0 kit's own
# launcher at ~/.local/bin/exasol, once the kit's launcher is in the kit
# folder: removed only when the receipt said it was the kit's (the caller
# read it) and the file is still the one the kit recorded (its sha256).
# Anything else there is left as it is. Nothing said: a log line.
personal_retire_bin_launcher() {
    [ -n "${1:-}" ] && [ -f "$1" ] && [ -n "${2:-}" ] && [ "$1" != "$EXAKIT_PERSONAL_KIT_BIN" ] || return 0
    # A link is never the file the kit installed.
    [ ! -L "$1" ] || return 0
    [ "$(sha256_of "$1" 2>/dev/null || true)" = "$2" ] || {
        _exakit_log_file "INFO  $1 is not the launcher the kit recorded: left as it is"
        return 0
    }
    rm -f "$1" && _exakit_log_file "INFO  the kit's old launcher at $1 removed: the kit's launcher is $EXAKIT_PERSONAL_KIT_BIN"
    return 0
}

# personal_retire_note <old path> <old sha256> — that launcher is retired once
# the kit's own is in the kit folder, on record before anything changes
# (components.personal.retire_*): an update cut short after that still retires
# it (personal_retire_pending). Nothing noted without the file's sha256.
personal_retire_note() {
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
    ( manifest_set components.personal.retire_sha256 "$2" && manifest_set components.personal.retire_path "$1" ) >/dev/null 2>&1 || true
    return 0
}
personal_retire_forget() {
    grep -qF '"retire_path"' "${EXAKIT_MANIFEST:-/nonexistent}" 2>/dev/null || return 0
    ( manifest_del components.personal.retire_path && manifest_del components.personal.retire_sha256 ) >/dev/null 2>&1 || true
    return 0
}

# personal_retire_pending — the launcher noted is retired now: the kit's own is
# in the kit folder, with the kit's receipt on it, and runs.
personal_retire_pending() {
    grep -qF '"retire_path"' "${EXAKIT_MANIFEST:-/nonexistent}" 2>/dev/null || return 0
    _personal_kit_bin_placed || return 0
    [ -n "$(personal_launcher_version 2>/dev/null || true)" ] || return 0
    _prp="$(manifest_get components.personal.retire_path 2>/dev/null || true)"
    [ "$_prp" = "$EXAKIT_BIN_DIR/exasol" ] && \
        personal_retire_bin_launcher "$_prp" "$(manifest_get components.personal.retire_sha256 2>/dev/null || true)"
    personal_retire_forget
}

# _personal_kit_bin_placed — 0 when the kit folder has a launcher with the
# kit's receipt on it. One without it is not there yet (an update or an install
# cut short between the file and its receipt).
_personal_kit_bin_placed() {
    [ -x "$EXAKIT_PERSONAL_KIT_BIN" ] && \
        [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = kit ] && \
        [ "$(manifest_get components.personal.ownership_path 2>/dev/null || true)" = "$EXAKIT_PERSONAL_KIT_BIN" ]
}

# personal_kit_launcher_finish <version> — an update cut short between the kit
# folder's launcher and its receipt, finished: the launcher there is the kit's
# by its place. The release the kit pins gets its receipt, anything else (half
# a file) is installed over, checksum checked; a launcher of the user's the
# receipt named stays recorded as theirs. And a receipt of the kit's an undo
# could not write again (a full disk) is written again, for the file it was on
# (its sha256). 1 when it could not be done: said. 12 when
# EXAKIT_CONFIRM_RUNTIME_UPDATE=0 holds it back.
personal_kit_launcher_finish() {
    [ -n "${1:-}" ] && [ "${EXAKIT_PERSONAL_MODE:-}" != P ] && \
        [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] || return 0
    if [ ! -e "$EXAKIT_PERSONAL_KIT_BIN" ]; then
        [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = unknown ] || return 0
        _pklf_old="$(manifest_get components.personal.retire_path 2>/dev/null || true)"
        if [ -n "$_pklf_old" ] && [ -f "$_pklf_old" ] && [ ! -L "$_pklf_old" ] && \
           [ "$(sha256_of "$_pklf_old" 2>/dev/null || true)" = "$(manifest_get components.personal.retire_sha256 2>/dev/null || true)" ]; then
            ( exakit_record_ownership personal kit "$_pklf_old" ) >/dev/null 2>&1 || true
        fi
        return 0
    fi
    _personal_kit_bin_placed && return 0
    if [ "$(exakit_runtime_update_preanswer)" = no ]; then
        warn "personal $(manifest_get runtime.version 2>/dev/null || true) -> $1 was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        info "Apply it when convenient:  exakit update --yes"
        return 12
    fi
    _pklf_theirs=""
    if [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = user ]; then
        _pklf_theirs="$(manifest_get components.personal.ownership_path 2>/dev/null || true)"
        [ "$_pklf_theirs" != "$EXAKIT_PERSONAL_KIT_BIN" ] || _pklf_theirs=""
    fi
    # The kit's own 0.3.0 one the receipt names still: noted, to be retired.
    if [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = kit ] && \
       [ "$(manifest_get components.personal.ownership_path 2>/dev/null || true)" = "$EXAKIT_BIN_DIR/exasol" ]; then
        personal_legacy_receipts
        [ "${PERSONAL_LEGACY_RECEIPT:-0}" != 0 ] || \
            personal_retire_note "$EXAKIT_BIN_DIR/exasol" "$(manifest_get components.personal.ownership_sha256 2>/dev/null || true)"
    fi
    _pklf_pin="$(EXAKIT_PERSONAL_VERSION="$1"; personal_s3_source 2>/dev/null | sed -n 2p)"
    if [ -z "$_pklf_pin" ] || [ "$(sha256_of "$EXAKIT_PERSONAL_KIT_BIN" 2>/dev/null || true)" != "$_pklf_pin" ] || \
       ! ( exakit_record_ownership personal kit "$EXAKIT_PERSONAL_KIT_BIN" ) >/dev/null 2>&1; then
        ( EXAKIT_PERSONAL_VERSION="$1"; EXAKIT_FORCE_COMPONENT_INSTALL=1; PERSONAL_UPDATE_RUNNING=1
          export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
          personal_install_launcher ) >/dev/null 2>&1 || true
    fi
    if ! _personal_kit_bin_placed; then
        warn "Exasol Personal was not updated to $1, because the new launcher could not be installed. The launcher and the database are as they were."
        exakit_note_failure "Exasol Personal was not updated to $1, because the new launcher could not be installed"
        info "The next exakit update tries again."
        return 1
    fi
    [ -z "$_pklf_theirs" ] || ( manifest_set components.personal.user_launcher "$_pklf_theirs" ) >/dev/null 2>&1 || true
    _personal_forget_followed
    return 0
}

# personal_legacy_receipts — the receipts a kit from before receipts (0.2.x)
# never wrote, written from what it recorded (_exakit_legacy_kit_owned) before
# anything changes. That proof is runtime.launcher at ~/.local/bin/exasol, and
# an update records the kit folder's launcher there: without the receipts, the
# kit's own database was no longer the kit's after it. The database first, its
# proof rests on the launcher's. A receipt written this way proves the place,
# not the file (PERSONAL_LEGACY_RECEIPT is 1, components.personal.ownership_legacy
# for the runs after it): that file is run, never deleted.
personal_legacy_receipts() {
    PERSONAL_LEGACY_RECEIPT="${PERSONAL_LEGACY_RECEIPT:-0}"
    [ -f "${EXAKIT_MANIFEST:-}" ] && command -v _exakit_legacy_kit_owned >/dev/null 2>&1 || return 0
    if [ -z "$(manifest_get runtime.ownership 2>/dev/null || true)" ] && _exakit_legacy_kit_owned database; then
        ( exakit_record_ownership database kit "$(exakit_personal_deploy_dir_now "$(manifest_get runtime.deployment_dir 2>/dev/null || true)")" ) >/dev/null 2>&1 || true
    fi
    if [ -z "$(manifest_get components.personal.ownership 2>/dev/null || true)" ] && _exakit_legacy_kit_owned personal; then
        ( manifest_set components.personal.ownership_legacy true && \
          exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol" ) >/dev/null 2>&1 && PERSONAL_LEGACY_RECEIPT=1
    fi
    # In every run after that one too, a first update that was put back included.
    [ -z "$(manifest_get components.personal.ownership_legacy 2>/dev/null || true)" ] || PERSONAL_LEGACY_RECEIPT=1
    return 0
}

# personal_kit_copy_ensure <version> — the kit's own launcher in the kit folder
# for a database of the kit's own that so far ran on the user's own launcher,
# already at <version> (nothing for personal_update_private to move): `exakit
# update` puts it there, as the installer does, so the kit runs only its own
# from then on. The pinned release, checksum checked. Theirs is left as it is,
# recorded as components.personal.user_launcher. A database of the user's is
# personal_update_user's. Non-zero when there is nothing to do or it could not
# be done (said in the log; the kit then runs theirs as before).
personal_kit_copy_ensure() {
    [ -n "${1:-}" ] && [ "${EXAKIT_PERSONAL_MODE:-}" != P ] && [ ! -e "$EXAKIT_PERSONAL_KIT_BIN" ] || return 1
    [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] || return 1
    [ "$(manifest_get runtime.ownership 2>/dev/null || true)" = kit ] || return 1
    [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = user ] || return 1
    [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] || return 1
    personal_deploy_dir_refresh
    [ -d "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || return 1
    _pkce_theirs="$(personal_cli)"
    [ -n "$_pkce_theirs" ] && [ -x "$_pkce_theirs" ] || return 1
    # Its id first, while its folder is where the record says: their launcher's
    # first command can move a stopped one (as in _personal_update_user_case).
    personal_update_record_id || true
    exakit_version_same "$(personal_launcher_version 2>/dev/null || true)" "$1" || return 1
    # In a subshell: a die() on a bad download or a full disk ends this step
    # only, with the receipt as it was.
    if ! ( EXAKIT_PERSONAL_VERSION="$1"; EXAKIT_FORCE_COMPONENT_INSTALL=1; PERSONAL_UPDATE_RUNNING=1
           export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
           personal_install_launcher ) || [ ! -x "$EXAKIT_PERSONAL_KIT_BIN" ]; then
        _exakit_log_file "WARN  the kit's own launcher could not be put in $(dirname "$EXAKIT_PERSONAL_KIT_BIN"): the kit still runs $_pkce_theirs"
        return 1
    fi
    _personal_forget_followed
    return 0
}

# personal_install_launcher — download, verify, and install the `exasol` CLI.
# An already-installed launcher is only accepted if it supports the 'local'
# preset (older releases do not); otherwise the resolved version is installed
# alongside it and preferred.
personal_install_launcher() {
    # THE LAUNCHER THE KIT RUNS (personal_cli), the one the newer-launcher
    # warning just named: the kit's own path first, else the one on PATH
    # (OWN-03, #41). Only PATH was looked at here, so a launcher the user put
    # at the kit's path, in a bin folder not on PATH yet, was invisible: the
    # warning said it uses the launcher it found and the install then wrote the
    # pinned release over it and recorded it as the kit's.
    personal_legacy_receipts
    _pil_found="$(personal_cli 2>/dev/null || true)"
    [ -n "$_pil_found" ] && [ -x "$_pil_found" ] || _pil_found=""
    # THE KIT FOLDER'S LAUNCHER IS THE KIT'S BY ITS PLACE, never recorded as
    # the user's: one with no kit receipt on it (a run cut short between the
    # file and the receipt, a launcher an uninstall left) is installed over,
    # checksum checked. So is a mode P wrapper whose binary is gone, or a file
    # in its place that is not the wrapper.
    if [ "$_pil_found" = "$EXAKIT_PERSONAL_KIT_BIN" ]; then
        if [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" != kit ] || \
           [ "$(manifest_get components.personal.ownership_path 2>/dev/null || true)" != "$EXAKIT_PERSONAL_KIT_BIN" ]; then
            _pil_found=""
        elif [ "${EXAKIT_PERSONAL_MODE:-}" = P ] && ! personal_wrapper_runs; then
            _pil_found=""
        fi
    fi
    if [ -n "$_pil_found" ]; then exakit_reuse_ownership personal "$_pil_found"; fi
    # A DATABASE THE USER LET THE 0.3.0 KIT USE, run by their own launcher:
    # re-running the installer moves it to the kit's own launcher and renames
    # it, as `exakit update` does (personal_update_user). Theirs stays (#41).
    # Done, or kept as it is and said: the launcher step is over. Never in an
    # installer that `exakit update` started (that update decided it).
    if [ -n "$_pil_found" ] && [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && \
       [ "$(manifest_get runtime.ownership 2>/dev/null || true)" = user ] && \
       ! { command -v exakit_core_rerun_active >/dev/null 2>&1 && exakit_core_rerun_active; }; then
        _pil_user_rc=0
        personal_update_user "$(manifest_get runtime.version 2>/dev/null || true)" "${EXAKIT_PERSONAL_VERSION:-}" || _pil_user_rc=$?
        [ "$_pil_user_rc" = 10 ] || return 0
    fi
    # THE KIT'S OWN DATABASE ON THE USER'S 2.4 (Q15): moved into the kit's
    # private home under the kit's own 2.5, as `exakit update` does
    # (personal_update_private). Never in an installer `exakit update` started.
    if [ -n "$_pil_found" ] && [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && \
       [ "${EXAKIT_PERSONAL_MODE:-}" != P ] && \
       ! { command -v exakit_core_rerun_active >/dev/null 2>&1 && exakit_core_rerun_active; }; then
        _pil_priv_rc=0
        personal_update_private "$(manifest_get runtime.version 2>/dev/null || true)" "${EXAKIT_PERSONAL_VERSION:-}" || _pil_priv_rc=$?
        [ "$_pil_priv_rc" = 10 ] || return 0
    fi
    # THE USER'S LAUNCHER A RECORDED DATABASE RUNS ON is left as it is, with its
    # receipt, in three cases. In an installer that `exakit update` started:
    # that update decides (personal_update_user, personal_update_private,
    # personal_kit_copy_ensure), and the kit's own installed now would replace
    # the receipt that tells it whose launcher it was. A database whose owner
    # the record does not name. And a launcher of theirs newer than the pin,
    # which the kit's own must not drive a database after.
    if [ -n "$_pil_found" ] && [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && \
       [ "$_pil_found" != "$EXAKIT_PERSONAL_BIN" ] && ! exakit_component_is_managed personal && \
       personal_kit_has_record && \
       { { command -v exakit_core_rerun_active >/dev/null 2>&1 && exakit_core_rerun_active; } || \
         { [ "$(manifest_get runtime.ownership 2>/dev/null || true)" != user ] && ! exakit_component_is_managed database; } || \
         personal_launcher_newer; }; then
        ok "Exasol launcher already installed: $_pil_found"
        return 0
    fi
    # THE KIT'S OWN LAUNCHER, BEHIND THE PIN (MAC-01). The reuse below kept it,
    # so re-running the installer over a 0.3.0 kit kept launcher 2.4.0: no
    # folder move, and the 20-session limit stayed. Over a deployment the kit
    # records, it is updated as `exakit update` does it; with none, it is
    # replaced like a first install, checksum and all. A user's launcher never
    # gets here (personal_kit_launcher_behind).
    # THE KIT'S OWN DATABASE MISSING (exakit_personal_db_state) is "none": a
    # hand-installed 2.5 moved a 0.3.0 kit's `default`, or another deployment
    # sits in the kit's folder. The launcher is replaced and nothing is
    # stopped or started: the deployment found is not the kit's, and the one
    # question of the deploy step needs a launcher that lists it.
    _pil_behind=""
    if [ -n "$_pil_found" ] && [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ]; then
        _pil_behind="$(personal_kit_launcher_behind "$_pil_found" 2>/dev/null || true)"
    fi
    if [ -n "$_pil_behind" ]; then
        personal_deploy_dir_refresh
        if [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] && \
           [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] && [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ]; then
            personal_update_behind_launcher "$_pil_behind"
            return 0
        fi
        info "Replacing the kit's launcher at $EXAKIT_PERSONAL_BIN with v${EXAKIT_PERSONAL_VERSION}"
    elif { [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] || ! exakit_component_is_managed personal; } && [ -n "$_pil_found" ] && \
         { [ "$_pil_found" = "$EXAKIT_PERSONAL_BIN" ] || exakit_component_is_managed personal; }; then
        # Only the kit's OWN launcher is kept here. A launcher of the user's
        # (a 0.3.0 owner user's, current already) is never the one the kit
        # runs: the kit's own is installed into the kit folder below, and
        # theirs is left as it is.
        _existing="$_pil_found"
        exakit_reuse_ownership personal "$_existing"
        # BOUNDED, and anchored to a subcommand line. Bounded because a wedged
        # launcher answers `install --help` no faster than it answers anything
        # else and this is the first thing the installer runs; anchored because
        # `grep -w local` matched the word ANYWHERE in free-form help text --
        # a description like "Stop a running local deployment" was enough to
        # accept a launcher that has no `local` preset at all.
        if exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$_existing" install --help 2>/dev/null \
                | personal_help_names_token "local"; then
            ok "Exasol launcher already installed: $_existing"
            return 0
        fi
        if ! exakit_component_is_managed personal; then
            warn "The user-owned Exasol launcher is not compatible with this kit; update it outside the kit. It was not replaced."
            return 1
        fi
        warn "The installed Exasol launcher ($_existing) does not support the 'local' preset (too old)."
        # Say what happens to it (#41): the kit's own launcher at the same path is replaced; one anywhere else
        # is only shadowed, never touched.
        if [ "$_existing" = "$EXAKIT_PERSONAL_BIN" ]; then
            info "Replacing the kit's launcher at $EXAKIT_PERSONAL_BIN with v${EXAKIT_PERSONAL_VERSION}"
        else
            info "Installing launcher v${EXAKIT_PERSONAL_VERSION} to $EXAKIT_PERSONAL_BIN — your launcher at $_existing is left untouched"
        fi
    fi

    # Refuse before acting: from here on the advertised version WILL be written
    # over whatever launcher this kit manages, so the deployment on disk gets its
    # veto now, while nothing has been downloaded or overwritten yet. Deliberately
    # after the early return above: a launcher already on PATH that is new enough
    # for the deployment is kept as it always was, and that case installs nothing
    # to object to.
    personal_refuse_launcher_downgrade

    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-personal.XXXXXX")"
    # Removed below once the launcher is in place; every die() between here and
    # there (a failed download, a bad checksum, a full disk) sweeps it instead.
    # Guarded: the suites load this module without common.sh.
    command -v exakit_track_tmp >/dev/null 2>&1 && exakit_track_tmp "$_tmp"

    # The whole step on ONE line. begin_step already set a spinner label, and
    # fetch/run_logged animate it, so every stage here was narrated twice: once
    # live by the spinner, then permanently by an info/ok pair repeating it --
    # four lines carrying two facts, each ✓ restating the bullet above it.
    # EXAKIT_QUIET_DETAIL routes that pair to the LOGFILE and leaves the spinner
    # as the narration. Same save-and-restore bracket as exakit_marketplace_install
    # in common.sh, and for the same reason; warn/error stay ungated there, so a
    # step that says nothing while it works still speaks when it goes wrong.
    #
    # Gated on a terminal: without one ui_spin_begin draws nothing, and quieting
    # the detail as well would leave a CI log silent for the length of a
    # download. Piped or redirected, the info lines stay and nothing changes.
    _pil_prev_label="${EXAKIT_ACTIVE_LABEL:-}"
    _pil_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    _pil_t0="$(date +%s 2>/dev/null || echo 0)"

    # The pinned release, downloaded and verified into $_tmp; _binary names
    # it (personal_launcher_download).
    personal_launcher_download

    EXAKIT_ACTIVE_LABEL="Installing launcher to $(ui_tilde "$EXAKIT_PERSONAL_BIN")"
    info "Installing launcher to $(ui_tilde "$EXAKIT_PERSONAL_BIN")"
    # MODE P: the binary goes to the kit's own folder, off PATH, and the
    # wrapper at EXAKIT_PERSONAL_BIN runs it in the private home
    # (personal_write_wrapper). The receipt names the wrapper, the path every
    # caller runs.
    _pil_target="$EXAKIT_PERSONAL_BIN"
    [ "${EXAKIT_PERSONAL_MODE:-}" = P ] && _pil_target="$EXAKIT_PERSONAL_PRIVATE_BIN"
    mkdir -p "$(dirname "$_pil_target")"
    # Only now, with the new binary downloaded and verified, is the old one
    # removed: a fresh file rather than one rewritten in place, which macOS's
    # code-signature cache would refuse to run.
    # Under a name of its own first, then in place in one step: a run cut short
    # never leaves half a launcher there.
    rm -f "$_pil_target.new"
    { install -m 755 "$_binary" "$_pil_target.new" && mv -f "$_pil_target.new" "$_pil_target"; } \
        || { rm -f "$_pil_target.new"; die "Could not install the Exasol launcher to $_pil_target (is it writable? is the disk full?)."; }
    push_rollback "rm -f \"$_pil_target\""
    if [ "${EXAKIT_PERSONAL_MODE:-}" = P ]; then
        # The home it runs with, on record before anything can run it: an
        # install cut short, or a binary lost later, is still mode P
        # (detect_personal_private_mode).
        manifest_set runtime.launcher_home "$EXAKIT_PERSONAL_PRIVATE_HOME"
        personal_write_wrapper || \
            die "Could not write the starter kit's Exasol launcher to $EXAKIT_PERSONAL_BIN (is it writable? is the disk full?)."
        push_rollback "rm -f \"$EXAKIT_PERSONAL_BIN\""
    fi
    # The receipt this install replaces: a 0.3.0 kit's own at ~/.local/bin,
    # retired below once this one is recorded (never inside an update, which
    # retires it only after the new launcher answered, personal_update).
    _pil_old_path="$(manifest_get components.personal.ownership_path 2>/dev/null || true)"
    _pil_old_sha="$(manifest_get components.personal.ownership_sha256 2>/dev/null || true)"
    [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = kit ] || _pil_old_path=""
    [ "${PERSONAL_LEGACY_RECEIPT:-0}" = 0 ] || _pil_old_sha=""
    # A launcher of the user's that ran the recorded database so far: theirs,
    # recorded by name only, as in mode U. Never run by the kit from here on.
    _pil_theirs=""
    if [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = user ] && \
       [ -n "$_pil_found" ] && [ "$_pil_found" != "$EXAKIT_PERSONAL_BIN" ] && personal_kit_has_record; then
        _pil_theirs="$_pil_found"
    fi
    [ "$_pil_old_path" != "$EXAKIT_BIN_DIR/exasol" ] || personal_retire_note "$_pil_old_path" "$_pil_old_sha"
    exakit_record_ownership personal kit "$EXAKIT_PERSONAL_BIN"
    [ -z "$_pil_theirs" ] || manifest_set components.personal.user_launcher "$_pil_theirs" 2>/dev/null || true
    # Mode U: the user's own 2.5, beside the kit's own, recorded by name only
    # (never run by the kit). Same key as Windows.
    if [ "${EXAKIT_PERSONAL_MODE:-}" = U ] && [ -n "${PERSONAL_USER_LAUNCHER:-}" ]; then
        manifest_set components.personal.user_launcher "$PERSONAL_USER_LAUNCHER" 2>/dev/null || true
    fi
    if [ "${PERSONAL_UPDATE_RUNNING:-0}" != 1 ] && [ "$_pil_old_path" = "$EXAKIT_BIN_DIR/exasol" ]; then
        personal_retire_bin_launcher "$_pil_old_path" "$_pil_old_sha"
        personal_retire_forget
    fi
    rm -rf "$_tmp"
    # WHAT THE OLD LAUNCHER ANSWERED IS DROPPED. The list of deployments is
    # asked once per process (personal_launcher_deployments), and the refresh
    # above asked it before this launcher was here: no launcher yet (a first
    # install), or a 2.4.0 without the command. That "no answer" hid the
    # user's 2.5 databases from the deploy step's one question. The next
    # reader asks the launcher just installed.
    _personal_forget_followed

    # Prove the downloaded binary can actually be executed before anything
    # treats its silence as an answer. A checksum says the bytes arrived
    # intact; it says nothing about whether this kernel will run them.
    exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$EXAKIT_PERSONAL_BIN" --version >/dev/null 2>&1
    _pil_rc=$?
    if exakit_unsigned_binary_hint "$_pil_target" "$_pil_rc"; then
        EXAKIT_QUIET_DETAIL="$_pil_prev_quiet"
        EXAKIT_ACTIVE_LABEL="$_pil_prev_label"
        die "The Exasol launcher was downloaded and verified but cannot be executed on this machine."
    fi

    EXAKIT_QUIET_DETAIL="$_pil_prev_quiet"
    EXAKIT_ACTIVE_LABEL="$_pil_prev_label"
    # After the restore, never inside it: this one can end in an `ok` reporting
    # that the kit edited the user's shell profile, which is not a line to send
    # to the logfile. Not in mode P: the kit's launcher is not the `exasol`
    # the user types (the kit's other commands put the bin folder on PATH).
    ok "Exasol launcher v${EXAKIT_PERSONAL_VERSION} installed to $(ui_tilde "$EXAKIT_PERSONAL_BIN") ($(( $(date +%s 2>/dev/null || echo 0) - _pil_t0 ))s)"
}

# personal_kit_has_record [launcher] — 0 when this machine's kit already
# records a database of its own or one it was allowed to use (a deployment
# folder, or a database receipt): the deploy step then uses that one, and
# asks nothing. With "launcher", a launcher receipt counts too: an install
# that has one keeps the launcher and the home it has (the mode decision
# reads a receipt of the user's launcher with no database record as a first
# install, personal_launcher_mode_decide). Non-zero on a first
# install. A file check (grep) before the manifest reader: no fork on a
# machine without a manifest.
# WHAT A DATABASE RECORD IS: runtime.deployment_dir or runtime.deployment_id,
# or runtime.ownership beside runtime.type personal. A receipt alone is not:
# the 0.3.0 kit wrote runtime.ownership for a stopped deployment of the
# user's BEFORE its "Start the existing database and keep its data?", so a
# "No" there left that receipt and nothing else (no type, no folder), and the
# installer run again must work as for a new user. Read with the manifest
# reader, never by a key's spelling anywhere in the file. Twin of
# Test-PersonalDatabaseRecorded.
personal_kit_has_record() {
    [ -f "${EXAKIT_MANIFEST:-}" ] || return 1
    grep -qE '"(deployment_dir|deployment_id|ownership)"' "$EXAKIT_MANIFEST" 2>/dev/null || return 1
    command -v manifest_get >/dev/null 2>&1 || return 1
    [ -n "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" ] && return 0
    [ -n "$(manifest_get runtime.deployment_id 2>/dev/null || true)" ] && return 0
    [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] && \
        [ -n "$(manifest_get runtime.ownership 2>/dev/null || true)" ] && return 0
    [ "${1:-}" = launcher ] && [ -n "$(manifest_get components.personal.ownership 2>/dev/null || true)" ]
}

# personal_user_launcher — the Exasol Personal launcher of the user's on this
# machine, printed: the one at the kit's path ($EXAKIT_BIN_DIR/exasol) when
# the kit has no receipt for it, else the one on PATH. Nothing when there is
# none. Only for a first install (personal_launcher_mode_decide): with no kit
# record, any launcher found is the user's.
personal_user_launcher() {
    if [ -x "$EXAKIT_BIN_DIR/exasol" ] && ! exakit_component_is_managed personal 2>/dev/null; then
        printf '%s\n' "$EXAKIT_BIN_DIR/exasol"
        return 0
    fi
    command -v exasol 2>/dev/null || true
}

# personal_user_legacy_deployments — the deployments a launcher before 2.5.0
# left in the user's own home (~/.exasol/personal/deployments, a folder that
# holds the launcher's state or deployment.json), one per line. A kit 2.5
# launcher run in that home would move every one of them on its first command.
personal_user_legacy_deployments() {
    detect_personal_deploy_roots
    [ -d "$DETECT_PERSONAL_USER_ROOT_LEGACY" ] || return 0
    for _puld in "$DETECT_PERSONAL_USER_ROOT_LEGACY"/*; do
        [ -d "$_puld" ] || continue
        if [ -f "$_puld/.exasolLauncherState.json" ] || [ -f "$_puld/deployment.json" ]; then
            printf '%s\n' "$_puld"
        fi
    done
    return 0
}

# personal_launcher_mode_decide — WHICH LAUNCHER AND WHICH HOME the kit's
# database runs with, decided once, before Step 1/4 of a first install (the
# setup scripts call it where the newer-launcher warning was):
#   K  no launcher of the user's and no legacy deployments of theirs: the kit
#      installs its own 2.5 in the kit folder (EXAKIT_PERSONAL_KIT_BIN), never
#      on PATH, in the user's home;
#   U  the user's launcher is on the pinned release line (2.5.x): the kit
#      installs its own 2.5 in the kit folder too, in the user's home, and
#      theirs is left as it is;
#   P  the user's launcher is 2.4.x or older, newer than the pinned line
#      (2.6+), answers no version, or there is none but legacy deployments of
#      theirs exist: the kit installs its own 2.5 under $EXAKIT_HOME/personal
#      and runs it only through the wrapper (personal_write_wrapper), with
#      $EXAKIT_HOME/personal/home as its home, so it never sees or moves the
#      user's Exasol Personal (D2). Not on PATH as `exasol`.
# An existing install keeps its mode: P while its wrapper is there, else the
# launcher and the home it recorded (a 0.3.0 kit's own, or the user's, both in
# the real home), never switched to P. A 0.3.0 kit with no database record and
# only a receipt for the user's launcher is not one: it is decided as a first
# install. Sets EXAKIT_PERSONAL_MODE, and
# PERSONAL_USER_LAUNCHER / PERSONAL_USER_LAUNCHER_VERSION for a first install
# (the user's launcher and its version, empty when none). The user's launcher
# is asked `version` only (a 2.5 or later of theirs moves its own legacy
# deployments on that command: its own behaviour, accepted). An existing
# install still gets the newer-launcher warning it always got.
personal_launcher_mode_decide() {
    PERSONAL_USER_LAUNCHER=""
    PERSONAL_USER_LAUNCHER_VERSION=""
    personal_private_move_recover
    if detect_personal_private_mode; then
        personal_use_mode P
        return 0
    fi
    # A LAUNCHER RECEIPT OF THE USER'S, WITH NO DATABASE RECORD, IS NOT AN
    # EXISTING INSTALL. A 0.3.0 kit that was told "No" (no database) kept only
    # the receipt of the launcher it found, usually the user's own 2.4 on
    # PATH; keeping it would deploy the kit's new database with their 2.4.
    # The installer run again works as for a new user: P next to their 2.4 or
    # a newer line, U with their 2.5 (then the one question). A receipt of the
    # kit's own launcher with no database keeps it: Step 1 brings it to the
    # pin (MAC-01).
    if personal_kit_has_record || { personal_kit_has_record launcher && \
         [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" != user ]; }; then
        [ "${EXAKIT_PERSONAL_MODE:-}" != P ] || EXAKIT_PERSONAL_MODE=""
        personal_warn_launcher_newer
        return 0
    fi
    _plmd_pin="${EXAKIT_PERSONAL_VERSION:-${EXAKIT_PERSONAL_VERSION_FALLBACK:-}}"
    PERSONAL_USER_LAUNCHER="$(personal_user_launcher)"
    if [ -z "$PERSONAL_USER_LAUNCHER" ]; then
        if [ -n "$(personal_user_legacy_deployments)" ]; then
            personal_use_mode P
        else
            personal_use_mode K
        fi
        return 0
    fi
    _plmd_ver="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$PERSONAL_USER_LAUNCHER" version 2>/dev/null | head -1 | tr -d '[:space:]')"
    _plmd_ver="${_plmd_ver#v}"
    case "$_plmd_ver" in [0-9]*.[0-9]*) PERSONAL_USER_LAUNCHER_VERSION="$_plmd_ver" ;; esac
    # The release line: 2.5.3 is 2.5, 2.6.0 is 2.6.
    _plmd_line="$(printf '%s' "$PERSONAL_USER_LAUNCHER_VERSION" | awk -F. '{print $1"."$2}')"
    _plmd_pin_line="$(printf '%s' "$_plmd_pin" | awk -F. '{print $1"."$2}')"
    if [ -n "$PERSONAL_USER_LAUNCHER_VERSION" ] && [ -n "$_plmd_pin_line" ] && [ "$_plmd_line" = "$_plmd_pin_line" ]; then
        personal_use_mode U
        return 0
    fi
    personal_use_mode P
    # One line, so the reader knows why the kit downloads a launcher of its
    # own next to theirs.
    if [ -n "$PERSONAL_USER_LAUNCHER_VERSION" ]; then
        info "Exasol Personal $PERSONAL_USER_LAUNCHER_VERSION is on this computer. The starter kit uses its own Exasol Personal ${_plmd_pin} in its own folder, so yours is not changed."
    fi
    return 0
}

# personal_use_mode <K|U|P> — run the kit's launcher in that mode from here
# on: EXAKIT_PERSONAL_BIN is the wrapper and the home the private one in P,
# the kit's path and the user's home otherwise. The deployment folder is
# found again in that home (a folder the user chose stays), and the
# launcher's list is asked again of that launcher.
personal_use_mode() {
    EXAKIT_PERSONAL_MODE="$1"
    if [ "$1" = P ]; then
        EXAKIT_PERSONAL_BIN="$EXAKIT_PERSONAL_WRAPPER"
        EXAKIT_PERSONAL_LAUNCHER_HOME="$EXAKIT_PERSONAL_PRIVATE_HOME"
    else
        EXAKIT_PERSONAL_BIN="$EXAKIT_PERSONAL_KIT_BIN"
        EXAKIT_PERSONAL_LAUNCHER_HOME=""
    fi
    case "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" in
        ""|"${DETECT_PERSONAL_DEPLOY_NEW:-}"|"${DETECT_PERSONAL_DEPLOY_LEGACY:-}")
            detect_personal_deploy_resolve ""
            EXAKIT_PERSONAL_DEPLOY_DIR="$DETECT_PERSONAL_DEPLOY_DIR" ;;
    esac
    unset _EXAKIT_PERSONAL_LIST_ASKED _EXAKIT_PERSONAL_LIST_DECIDED _EXAKIT_PERSONAL_DEPLOY_REC \
        _EXAKIT_PERSONAL_DEPLOY_AT _EXAKIT_PERSONAL_DEPLOY_LOST _EXAKIT_PERSONAL_DEPLOY_FOLLOWED
    DETECT_PERSONAL_LAUNCHER_LISTED=0
    DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS=""
    PERSONAL_LAUNCHER_ROWS=""
    return 0
}

# personal_write_wrapper — the mode P launcher at EXAKIT_PERSONAL_WRAPPER: a
# POSIX sh script with every path baked in, that runs the kit's own binary
# (EXAKIT_PERSONAL_PRIVATE_BIN) with the private home as HOME. XDG_DATA_HOME,
# XDG_CONFIG_HOME and DOCKER_CONFIG stay the user's (their own value, else the
# folder in the real home), so on Linux the launcher keeps the user's Podman
# storage and Docker contexts; harmless on macOS. Written to a new file and
# moved over the old one. Non-zero when it cannot be written.
# XDG_CACHE_HOME is the private home's own .cache, always, whatever the user
# set: the launcher keeps its downloads there (os.UserCacheDir on Linux), and
# 2.5.0 deletes the legacy cache and moves the SQL history it finds there on
# every command. With the user's XDG_CACHE_HOME it would delete their 2.4
# downloads and take their 2.4 SQL history into the kit's home, and the
# uninstall would remove a cache a launcher of theirs uses. No container
# engine keeps anything there.
personal_write_wrapper() {
    _pww_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    mkdir -p "$(dirname "$EXAKIT_PERSONAL_WRAPPER")" "$EXAKIT_PERSONAL_PRIVATE_HOME" || return 1
    _pww_tmp="$EXAKIT_PERSONAL_WRAPPER.new.$$"
    {
        printf '#!/bin/sh\n'
        printf "# The starter kit's own Exasol Personal launcher, run in the kit's own home folder\n"
        printf "# so it never sees or moves the user's own Exasol Personal deployments.\n"
        printf '_exakit_real_home=%s\n' "$(_pww_q "${HOME:-}")"
        printf 'export XDG_DATA_HOME="${XDG_DATA_HOME:-$_exakit_real_home/.local/share}"\n'
        printf 'export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$_exakit_real_home/.config}"\n'
        printf 'export DOCKER_CONFIG="${DOCKER_CONFIG:-$_exakit_real_home/.docker}"\n'
        printf 'XDG_CACHE_HOME=%s\n' "$(_pww_q "$EXAKIT_PERSONAL_PRIVATE_HOME/.cache")"
        printf 'export XDG_CACHE_HOME\n'
        printf 'HOME=%s exec %s "$@"\n' "$(_pww_q "$EXAKIT_PERSONAL_PRIVATE_HOME")" "$(_pww_q "$EXAKIT_PERSONAL_PRIVATE_BIN")"
    } > "$_pww_tmp" || { rm -f "$_pww_tmp"; return 1; }
    chmod 755 "$_pww_tmp" && mv -f "$_pww_tmp" "$EXAKIT_PERSONAL_WRAPPER" || { rm -f "$_pww_tmp"; return 1; }
    return 0
}

# personal_wrapper_runs — 0 when mode P's two files are there and belong
# together: the binary in libexec, and the wrapper that runs it.
personal_wrapper_runs() {
    [ -s "$EXAKIT_PERSONAL_PRIVATE_BIN" ] && [ -x "$EXAKIT_PERSONAL_PRIVATE_BIN" ] && [ -x "$EXAKIT_PERSONAL_WRAPPER" ] || return 1
    # As the wrapper spells it (a single quote in the path is escaped there).
    [ "$(head -c 9 "$EXAKIT_PERSONAL_WRAPPER" 2>/dev/null)" = '#!/bin/sh' ] && \
        grep -qF "$(printf '%s' "$EXAKIT_PERSONAL_PRIVATE_BIN" | sed "s/'/'\\\\''/g")" "$EXAKIT_PERSONAL_WRAPPER" 2>/dev/null
}

personal_cli() {
    # Mode P: the kit's wrapper, ALWAYS, installed or not yet. The launcher
    # on PATH is the user's own, which the kit never runs there.
    if [ "${EXAKIT_PERSONAL_MODE:-}" = P ]; then
        echo "$EXAKIT_PERSONAL_BIN"
        return 0
    fi
    # THE KIT ALWAYS RUNS ITS OWN LAUNCHER (Krishna, 24 Nov): the one in the
    # kit folder, in every mode, never one on PATH. Only a 0.3.0 install not
    # yet updated has none there: it runs the launcher its receipt names (its
    # own at ~/.local/bin/exasol, or the user's own it used) until its update
    # puts the kit's own in the kit folder.
    if [ -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "$EXAKIT_PERSONAL_BIN"
        return 0
    fi
    _pcli_rec="$(_personal_receipt_launcher)"
    if [ -n "$_pcli_rec" ] && [ -x "$_pcli_rec" ]; then
        echo "$_pcli_rec"
    else
        echo "$EXAKIT_PERSONAL_BIN"
    fi
}

# _personal_receipt_launcher — the launcher the kit's receipt names
# (components.personal.ownership_path): a 0.3.0 install's launcher until its
# update. Asked only while the kit folder has no launcher. A kit from before
# receipts (0.2.x) has none: the launcher it recorded as the one it runs
# (runtime.launcher), and a receipt whose file is gone falls back to that one
# too. Nothing without a manifest.
# A LAUNCHER OF THE USER'S THAT MOVED (the receipt theirs, its file gone, a
# database on record that has not been updated yet): the one on PATH now, as a
# 0.3.0 kit found it, while it is of a line before the pin. Without it the kit
# had no launcher at all, and the installer's new 2.5, run in their home, moved
# their other databases. "recorded": only the launchers the record names, by
# their files alone.
_personal_receipt_launcher() {
    [ -f "${EXAKIT_MANIFEST:-}" ] && command -v manifest_get >/dev/null 2>&1 || return 0
    grep -qE '"(ownership_path|launcher)"' "$EXAKIT_MANIFEST" 2>/dev/null || return 0
    _prl="$(manifest_get components.personal.ownership_path 2>/dev/null || true)"
    if [ -z "$_prl" ] || [ ! -x "$_prl" ]; then
        _prl_run="$(manifest_get runtime.launcher 2>/dev/null || true)"
        [ -n "$_prl_run" ] && [ -x "$_prl_run" ] && _prl="$_prl_run"
    fi
    if [ "${1:-}" != recorded ] && [ -n "$_prl" ] && [ ! -x "$_prl" ] && \
       [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = user ] && \
       [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] && \
       [ -n "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" ]; then
        _prl_run="$(command -v exasol 2>/dev/null || true)"
        case "$_prl_run" in
            "$EXAKIT_HOME"/*) ;;
            /*) if [ -x "$_prl_run" ]; then
                    _prl_ver="$(exakit_run_bounded "${EXAKIT_PERSONAL_PROBE_TIMEOUT:-10}" "$_prl_run" version 2>/dev/null | head -1 | tr -d '[:space:]')"
                    _prl_ver="${_prl_ver#v}"
                    case "$_prl_ver" in
                        [0-9]*.[0-9]*) personal_deployment_outranks "$(printf '%s' "${EXAKIT_PERSONAL_VERSION:-${EXAKIT_PERSONAL_VERSION_FALLBACK:-}}" | awk -F. '{print $1"."$2".0"}')" \
                                           "$(printf '%s' "$_prl_ver" | awk -F. '{print $1"."$2".0"}')" && _prl="$_prl_run" ;;
                    esac
                fi ;;
        esac
    fi
    [ -z "$_prl" ] || printf '%s\n' "$_prl"
}

# Launcher probes are BOUNDED. exakit_run_bounded was written because macOS has
# no timeout(1) - and then guarded only the container-engine probes, which run
# on the platforms that have it. Every macOS launcher probe stayed unbounded,
# so `exakit status` - the command AGENTS.md tells agents to poll - could hang
# forever on exactly the wedged launcher the module ships a reaper for.
EXAKIT_PERSONAL_PROBE_TIMEOUT="${EXAKIT_PERSONAL_PROBE_TIMEOUT:-10}"
# The bound of a NEW launcher's first command after an update's swap
# (_personal_update_launcher_answers): longer, because it does the 2.5 move.
EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT="${EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT:-120}"

# personal_db_port — the port THIS deployment is on, which is not necessarily
# EXAKIT_PERSONAL_PORT.
#
# Exasol Personal 2.3 selects and persists a concrete database port during
# initialization, keeps it stable across restarts and lets it be changed while
# the deployment is stopped. Every probe that asked the constant instead was
# wrong on a deployment that chose another port: status read a silent 8563 and
# reported the database stopped while it was running, and the conflict arm
# could fire on an unrelated listener.
#
# The launcher's own deployment.json is the answer; the constant is the answer
# only until one exists. No Python: this is on the status path, which must work
# on a machine whose interpreter is not up yet.
personal_db_port() {
    personal_deploy_dir_refresh
    _pdp_file="$EXAKIT_PERSONAL_DEPLOY_DIR/deployment.json"
    _pdp=""
    if [ -f "$_pdp_file" ]; then
        _pdp="$(tr -d '\012\015' < "$_pdp_file" 2>/dev/null | \
            sed -n 's/.*"dbPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    fi
    # No deployment yet: the port the kit picked for it (personal_pick_port),
    # else the launcher's own first choice.
    case "$_pdp" in
        ''|*[!0-9]*) _pdp="${PERSONAL_PICKED_PORT:-$EXAKIT_PERSONAL_PORT}" ;;
    esac
    printf '%s' "$_pdp"
}

personal_deployment_exists() {
    personal_deploy_dir_refresh
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && \
        exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" info --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" >/dev/null 2>&1
}

# personal_deployment_running — is a local Exasol deployment actually up and
# reachable right now? Some launcher versions can answer `exasol info` even
# before the SQL listener exists, so require both signals before reusing an
# existing database.
personal_deployment_running() {
    port_in_use "$(personal_db_port)" || return 1
    if personal_deployment_exists; then
        # THE LAUNCHER'S WORD OUTRANKS THE PORT. "stopped" can leave a runner
        # answering (see personal_status); "deployment_failed" is a first boot
        # the launcher gave up on - reconciled by personal_deploy_local, never
        # adopted as running, or its stop and start stay no-ops for good.
        case "$(personal_launcher_state 2>/dev/null || true)" in
            stopped|deployment_failed) return 1 ;;
        esac
        personal_db_answers
        return $?
    fi
    # NO DEPLOYMENT OF OURS: whatever answers on the port is not the kit's
    # database (D3). The kit's is the deployment starter-kit-local, on its own
    # port: a database of the user's, or one on the other side of a shared
    # Windows and WSL network stack, is never adopted by its port. Windows
    # and WSL share one network stack, so a database deployed on either side
    # holds 8563 for both - and adopting the other side's database here handed
    # the rest of the install a password that could never work against it.
    return 1
}

# personal_db_answers — is the thing on the SQL port actually Exasol? A real
# SELECT through the kit's exapump profile when that module is loaded (it is,
# in the CLI and the installer); without it, a completed TLS handshake
# (personal_tls_answers). Port open alone is never the answer: see
# personal_status - and under rootless Podman the open port is pasta's, there
# from the moment the container starts and a minute or more before the database
# inside it accepts a connection.
personal_db_answers() {
    # THE HANDSHAKE ALONE, for a deployment that is ours. Asking exapump for a
    # SELECT here made the database's liveness depend on a second tool: when a
    # virus scanner held the freshly installed exapump binary, every probe said
    # "not running" about a database that was up, and the installer went on to
    # "self-heal" it. Proving WHOSE database answers is a different question,
    # asked only where it arises — see personal_deployment_running.
    personal_tls_answers
}

# personal_tls_answers — does the database complete a TLS handshake on its
# port? The one probe that tells a database apart from the process publishing
# its port: pasta (rootless Podman) and the launcher's own runner accept the
# TCP connection themselves and reset it when nothing answers behind them,
# which every SQL client reports as "tls handshake eof" - the launcher's own
# 27-second first-boot budget ran out on exactly that, and a port-open wait
# returned the instant the container started. openssl where it exists (macOS,
# nearly every Linux), python3 otherwise, the bare port as the last resort.
#
# THE OUTPUT IS THE ANSWER, NEVER openssl's EXIT STATUS. macOS ships LibreSSL
# as /usr/bin/openssl, and its s_client exits 1 after a completed handshake
# when stdin reaches EOF. Piped into `grep -q` under the `set -o pipefail`
# of setup/exakit and the setup scripts, that 1 failed the probe against a
# database that was up - so a slow first boot was never recovered and
# `exakit status` called the database's own port "held by another process". `grep -q` also closes the
# pipe at its match and can SIGPIPE (141) the client: the same trap as
# personal_help_names_token. So the output is captured, then tested.
personal_tls_answers() {
    _pta_port="$(personal_db_port)"
    if command -v openssl >/dev/null 2>&1; then
        # WHAT THE HANDSHAKE PRINTED, NEVER THE CLIENT'S EXIT STATUS. This was a
        # pipeline into grep, and the installer and exakit run with pipefail:
        # macOS's own openssl (LibreSSL) exits 1 at the end of stdin after a
        # handshake that succeeded, so on every Mac without another openssl
        # first on PATH the probe said "no database" about one that answered.
        # The readiness wait then ran out its whole budget, the kit "repaired"
        # the running database by deploying over it, and the launcher recorded
        # the deployment as failed for good. Reported from a real install;
        # machines with Homebrew's openssl (exit 0) never showed it.
        _pta_out="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" openssl s_client -connect "127.0.0.1:$_pta_port" </dev/null 2>/dev/null || true)"
        case "$_pta_out" in *'BEGIN CERTIFICATE'*) return 0 ;; esac
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" python3 -c 'import socket, ssl, sys
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5) as s:
    ctx.wrap_socket(s, server_hostname="localhost").close()' "$_pta_port" >/dev/null 2>&1
        return $?
    fi
    port_in_use "$_pta_port"
}

# personal_foreign_db_hint — one sentence for a port that answers like Exasol
# but is not this kit's deployment; empty when nothing completes a handshake.
# Windows and WSL share one network stack, so a database deployed on either
# side holds 8563 for both; naming that spares the reader a hunt for an
# application that is not there.
personal_foreign_db_hint() {
    personal_tls_answers || return 0
    # NAME WHAT IS ACTUALLY THERE. A recorded container of this machine's own
    # previous kit is the commonest holder of this port, and telling that user
    # to go and stop something in WSL sends them looking for a database that
    # does not exist. The crossing is the road out of it.
    if command -v legacy_db_recorded >/dev/null 2>&1 && legacy_db_recorded && \
       [ "$(legacy_container_state 2>/dev/null || true)" = "running" ]; then
        printf ' It is the container database of your previous starter kit (%s), which this kit no longer manages. Stop it (%s stop %s) and re-run the installer, which then offers to copy its data across.' \
            "$(legacy_container)" "$(legacy_engine_name)" "$(legacy_container)"
        return 0
    fi
    # THE KIT'S OWN RUNNER IS NOT A FOREIGN DATABASE. A deployment the
    # launcher records as failed while its runner still runs the VM answers
    # here too, and telling that user to stop "a database this kit did not
    # deploy" sent them hunting for one that does not exist.
    if command -v _personal_port_held_by_own_runner >/dev/null 2>&1 && \
       _personal_port_held_by_own_runner; then
        _pfh_pids="$(printf '%s' "$_ppo_pids" | tr '\n' ' ' | sed 's/ *$//')"
        printf ' It is this kit'"'"'s own Exasol database process (pid %s), not another database. Stop it with: kill %s (your data stays), then run: exakit start' \
            "$_pfh_pids" "$_pfh_pids"
        return 0
    fi
    printf ' It answers like an Exasol database this kit did not deploy: stop that database first, then re-run.'
    detect_wsl_version >/dev/null 2>&1 && \
        printf ' WSL and Windows share this port, so one deployed on the Windows side holds it here too (stop it there with: exakit stop).'
    return 0
}

# personal_launcher_state — the LAUNCHER'S OWN WORD for this deployment, from
# `exasol status --json` ("stopped", "running", ...), empty when it cannot say.
#
# It exists because the port is not the owner. After `exasol stop` on 2.3 the
# deployment is stopped and its runner process can still be alive and still
# forwarding to a VM that still answers SQL - so a port probe reports a
# database the launcher has already let go of, `exakit start` says "already
# running", and the user cannot restart at all.
#
# --json since 2.3; the plain output is parsed as the fallback so a 2.2
# launcher still answers. Bounded like every other probe, and the launcher's
# own five-second ceiling keeps it honest on an unresponsive deployment.
personal_launcher_state() {
    personal_deploy_dir_refresh
    _pls_out="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" status --json --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true)"
    _pls="$(printf '%s' "$_pls_out" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$_pls" ]; then
        _pls_out="$(exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" status --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true)"
        _pls="$(printf '%s' "$_pls_out" | sed -n 's/^[[:space:]]*Status:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1)"
    fi
    printf '%s' "$_pls" | tr '[:upper:]' '[:lower:]'
}

# personal_port_holder_hint — " (pid N, name)" for the process on the port, or
# nothing when lsof cannot say. Suffix for a conflict message.
personal_port_holder_hint() {
    _pph_pid="$(personal_db_port_pids | head -1)"
    [ -n "$_pph_pid" ] || return 0
    _pph_name="$(ps -p "$_pph_pid" -o comm= 2>/dev/null | sed 's|.*/||')"
    printf ' (pid %s%s)' "$_pph_pid" "${_pph_name:+, $_pph_name}"
}

# personal_db_port_pids — PIDs currently LISTENing on the deployment port.
personal_db_port_pids() {
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -nP -iTCP:"$(personal_db_port)" -sTCP:LISTEN -t 2>/dev/null | sort -u
}

# personal_is_orphan_daemon PID — true only if PID is an Exasol Personal local
# runner. Scopes cleanup so we never kill an unrelated application that happens
# to hold the port.
#
# TWO SHAPES, because the launcher renamed its runner: 2.2 ran
# "mac-runner ... __daemon__", and 2.3 runs
# .../exasol-local-runner/<os>/<arch>/<hash>/unpack/launcher. Matching only the
# 2.2 spelling meant that on 2.3 the kit called its OWN leftover runner a
# foreign process, refused to touch it, and left the port held by something it
# had itself started - with the deploy path's hard stop as the only outcome.
# A matching daemon younger than this is presumed to be a healthy runner still
# coming up, not an orphan. Exasol Personal's own start budget is about two
# minutes; 180s leaves margin on a slow or loaded machine. Set to 0 to reap by
# name alone, which is what this code used to do unconditionally.
EXAKIT_PERSONAL_REAP_MIN_AGE="${EXAKIT_PERSONAL_REAP_MIN_AGE:-180}"

# _personal_proc_age_seconds <pid> - how long that process has been alive.
# `ps -o etime=` is the portable spelling ([[dd-]hh:]mm:ss); etimes is GNU-only
# and absent on the macOS ps. awk does the parsing so a zero-padded field
# ("08") is read as decimal rather than tripping shell octal arithmetic.
_personal_proc_age_seconds() {
    ps -p "$1" -o etime= 2>/dev/null | awk '
        {
            gsub(/ /, "", $0)
            if ($0 == "") exit 1
            d = 0
            if (index($0, "-") > 0) {
                d = substr($0, 1, index($0, "-") - 1) + 0
                $0 = substr($0, index($0, "-") + 1)
            }
            n = split($0, p, ":")
            if (n == 3)      { s = p[1] * 3600 + p[2] * 60 + p[3] }
            else if (n == 2) { s = p[1] * 60 + p[2] }
            else             { s = p[1] + 0 }
            print d * 86400 + s
            exit 0
        }'
}

# personal_is_orphan_daemon <pid> - is this process ours AND abandoned?
#
# THE NAME ALONE WAS THE WHOLE TEST, AND A HEALTHY RUNNER MID-START HAS THAT
# NAME. That made the worst path in the kit: personal_status answers `conflict`
# for any port that is bound while the database does not yet answer SQL - which
# is precisely a deployment's startup window - and cmd_start reads `conflict` as
# "probably our own orphan" and calls the reaper, which escalates to
# `pkill -9 -P` plus `kill -9`. So a second `exakit start` during startup (two
# shells, a user who thinks nothing happened, an agent that retries) SIGKILLed
# the starting runner. What that costs is recorded 900 lines away in setup/exakit:
# a SIGKILLed runner leaves the launcher's workflow state `interrupted`, after
# which every start fails identically forever, and the only documented cure is
# `exakit repair-runtime` - which deletes the database. For someone with three
# months of unbacked-up tables that is the difference between a pause and a loss.
#
# Two more questions before the kill, both cheap:
#   age    - a process that started seconds ago is starting, not stranded.
#   state  - the launcher's own word. A genuine orphan is one the launcher has
#            let go of (stopped / deployment_failed / interrupted), or one it
#            cannot speak for at all (empty). Anything else means it believes
#            this deployment is live, and we do not get to overrule it.
# Erring toward NOT reaping is the right bias: the cost of a missed reap is a
# clear "port is held" message and a manual stop. The cost of a wrong reap is
# the user's data.
# _personal_is_runner_process <pid> - does this process LOOK like our runner?
# The name test alone, shared by the reaper (which additionally needs it to be
# old and abandoned) and by personal_starting (which needs it to be young).
# One definition, so the two can never disagree about whose process it is.
# _personal_proc_command <pid> - the process's command line: /proc where there
# is one (BusyBox and procps-less images have no `ps -o command=`, LNX-10),
# else ps.
_personal_proc_command() {
    if [ -r "/proc/$1/cmdline" ]; then
        tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null
        return 0
    fi
    ps -p "$1" -o command= 2>/dev/null || true
}

_personal_is_runner_process() {
    case "$(_personal_proc_command "$1")" in
        *mac-runner*__daemon__*) return 0 ;;
        *exasol-local-runner*)   return 0 ;;
    esac
    return 1
}

# personal_starting - is the port held by OUR OWN runner, still within its
# start budget? Then the database is coming up, not in conflict with anything.
#
# personal_status had no such state: port bound + launcher not "stopped" + SQL
# not answering yet is exactly a deployment's startup window, and it was
# reported as `conflict` - which reads as "another program has your port" on a
# machine that has no such program. Two consequences. The post-update check in
# common.sh already had a `starting` arm that could never be reached, so it
# fell to the catch-all and warned about a conflict for a database that was
# simply booting. And `conflict` is what sends cmd_start into the reaper, which
# is the first step of the path that SIGKILLs a healthy starting runner.
personal_starting() {
    command -v personal_db_port_pids >/dev/null 2>&1 || return 1
    for _pst_pid in $(personal_db_port_pids 2>/dev/null || true); do
        _personal_is_runner_process "$_pst_pid" || continue
        _pst_age="$(_personal_proc_age_seconds "$_pst_pid" 2>/dev/null || true)"
        [ -n "$_pst_age" ] || continue
        [ "$_pst_age" -lt "${EXAKIT_PERSONAL_REAP_MIN_AGE:-180}" ] && return 0
    done
    return 1
}

# _personal_runner_proven_ours PID - 0 when the runner PID works for the kit's
# own deployment folder: its command line names that folder, or it works
# inside it (_personal_runner_of_this_deployment: its working directory or a
# file it holds open). The name alone proves nothing: every deployment's
# runner carries it, and two deployments can share a port while one is
# stopped (OWN-02).
_personal_runner_proven_ours() {
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    _prpo_dir="${EXAKIT_PERSONAL_DEPLOY_DIR:-}"
    while [ "${_prpo_dir%/}" != "$_prpo_dir" ]; do _prpo_dir="${_prpo_dir%/}"; done
    if [ -n "$_prpo_dir" ]; then
        _prpo_cmd=" $(_personal_proc_command "$1") "
        case "$_prpo_cmd" in
            *" $_prpo_dir "*|*" $_prpo_dir/"*|*"=$_prpo_dir "*|*"=$_prpo_dir/"*) return 0 ;;
        esac
    fi
    _personal_runner_of_this_deployment "$1"
}

personal_is_orphan_daemon() {
    _personal_is_runner_process "$1" || return 1
    # ONLY THE KIT'S OWN DEPLOYMENT'S RUNNER. The user's other deployment,
    # running on the same port while the kit's is stopped, carries the same
    # name: killing it lost that database's sessions and loads (OWN-02).
    if ! _personal_runner_proven_ours "$1"; then
        command -v _exakit_log_file >/dev/null 2>&1 &&
            _exakit_log_file "INFO  not reaping pid $1: not proven to work for ${EXAKIT_PERSONAL_DEPLOY_DIR:-the deployment of this kit}"
        return 1
    fi
    if [ "${EXAKIT_PERSONAL_REAP_MIN_AGE:-0}" -gt 0 ]; then
        _iod_age="$(_personal_proc_age_seconds "$1" 2>/dev/null || true)"
        if [ -n "$_iod_age" ] && [ "$_iod_age" -lt "$EXAKIT_PERSONAL_REAP_MIN_AGE" ]; then
            # Guarded: this predicate is reachable with runtime-personal.sh
            # sourced on its own, where common.sh's logger does not exist, and
            # a decision this important must not depend on a log line.
            command -v _exakit_log_file >/dev/null 2>&1 &&
                _exakit_log_file "INFO  not reaping pid $1: ${_iod_age}s old, still within the start budget"
            return 1
        fi
    fi
    case "$(personal_launcher_state 2>/dev/null || true)" in
        ''|stopped|deployment_failed|interrupted) return 0 ;;
        *) command -v _exakit_log_file >/dev/null 2>&1 &&
               _exakit_log_file "INFO  not reaping pid $1: the launcher still calls this deployment live"
           return 1 ;;
    esac
}

# personal_reap_orphan_daemon — the Exasol Personal launcher can leave an
# orphaned "mac-runner ... __daemon__" process bound to the database port after
# a failed deploy, or after a destroy that could not find its PID file (it logs
# "VM is not running (no PID file found)"). The orphan then makes the next
# deploy fail with "bind: operation not permitted" on vm.sock and makes MCP
# clients see "Connection reset by peer". Reap only that specific daemon; a
# genuinely foreign process on the port is reported and left untouched.
# Returns 0 if the port ends up free (or was never held), 1 otherwise.
personal_reap_orphan_daemon() {
    _rod_port="$(personal_db_port)"
    # Judge the port by whether a process is actually LISTENing on it, not by a
    # bare TCP connect: after a teardown, client sockets linger in
    # CLOSE_WAIT/TIME_WAIT and would make a connect test wrongly report "in use".
    if ! command -v lsof >/dev/null 2>&1; then
        if port_in_use "$_rod_port"; then
            warn "Port $_rod_port is in use but 'lsof' is unavailable to identify the process; cannot auto-clean a leftover Exasol daemon."
            return 1
        fi
        return 0
    fi

    _listeners="$(personal_db_port_pids)"
    [ -n "$_listeners" ] || return 0   # nothing listening → port is free

    # WHO HOLDS IT, for the caller's next step (set only when nothing is reaped):
    #   foreign       not an Exasol runner at all
    #   runner_young  an Exasol runner younger than the start budget (starting,
    #                 or the leftover of an install interrupted a moment ago);
    #                 PERSONAL_PORT_HOLDER_WAIT is what is left of that budget
    #   runner_live   an Exasol runner whose deployment the launcher calls live
    PERSONAL_PORT_HOLDER=""
    PERSONAL_PORT_HOLDER_PID=""
    PERSONAL_PORT_HOLDER_WAIT=0
    _reaped=""
    for _pid in $_listeners; do
        if personal_is_orphan_daemon "$_pid"; then
            info "Reaping orphaned Exasol runner daemon (pid $_pid) still holding port $_rod_port"
            pkill -P "$_pid" 2>/dev/null || true
            kill "$_pid" 2>/dev/null || true
            _reaped="$_reaped $_pid"
        elif _personal_is_runner_process "$_pid"; then
            # IT IS EXASOL'S OWN RUNNER, AND IT USED TO BE CALLED "a non-Exasol
            # process". The reaper spared it for a reason (its age, or the
            # launcher's word), and the message named neither: the reader was
            # told to go and stop an application that is the database itself.
            PERSONAL_PORT_HOLDER_PID="$_pid"
            _rod_age="$(_personal_proc_age_seconds "$_pid" 2>/dev/null || true)"
            if ! _personal_runner_proven_ours "$_pid"; then
                # Another deployment's runner (OWN-02): never touched.
                PERSONAL_PORT_HOLDER="runner_other"
                warn "Port $_rod_port is held by the Exasol Personal runner of another deployment (pid $_pid). The kit leaves it running."
            elif [ "${EXAKIT_PERSONAL_REAP_MIN_AGE:-0}" -gt 0 ] && [ -n "$_rod_age" ] && \
               [ "$_rod_age" -lt "$EXAKIT_PERSONAL_REAP_MIN_AGE" ]; then
                PERSONAL_PORT_HOLDER="runner_young"
                PERSONAL_PORT_HOLDER_WAIT=$((EXAKIT_PERSONAL_REAP_MIN_AGE - _rod_age))
                warn "Port $_rod_port is held by an Exasol Personal runner that started ${_rod_age}s ago (pid $_pid): it is still starting, or left by an install interrupted a moment ago; leaving it untouched."
            else
                PERSONAL_PORT_HOLDER="runner_live"
                _rod_state="$(personal_launcher_state 2>/dev/null || true)"
                warn "Port $_rod_port is held by an Exasol Personal runner (pid $_pid) whose deployment the launcher reports as ${_rod_state:-live}; leaving it untouched."
            fi
        else
            [ -n "$PERSONAL_PORT_HOLDER" ] || { PERSONAL_PORT_HOLDER="foreign"; PERSONAL_PORT_HOLDER_PID="$_pid"; }
            warn "Port $_rod_port is held by a non-Exasol process (pid $_pid: $(_personal_proc_command "$_pid" | cut -c1-80)); leaving it untouched."
        fi
    done

    # Only a foreign listener remains (nothing of ours to reap) → not our port.
    [ -n "$_reaped" ] || return 1

    # Wait for the listener to release the port (SIGTERM path, up to ~5s), then
    # force-kill any survivor and its children and give it a moment to settle.
    _waited=0
    while [ "$_waited" -lt 5 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done
    for _pid in $_reaped; do
        if kill -0 "$_pid" 2>/dev/null; then
            pkill -9 -P "$_pid" 2>/dev/null || true
            kill -9 "$_pid" 2>/dev/null || true
        fi
    done
    _waited=0
    while [ "$_waited" -lt 3 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done

    if [ -n "$(personal_db_port_pids)" ]; then
        warn "Port $_rod_port still has a listening process after reaping the Exasol daemon."
        return 1
    fi
    ok "Freed port $_rod_port (removed a leftover Exasol runner daemon)"
    return 0
}

# personal_stop_runner_of_failed_deployment - a deployment the launcher
# records as "deployment_failed" WHILE ITS OWN RUNNER STILL RUNS THE VM. An
# older kit could leave exactly that: the launcher gave up on a first boot,
# the runner kept the VM up and the database answers TLS, and from then on
# the launcher refuses every command - deploy, start, stop and destroy alike -
# with "VM is already running". The kit's deploy retry then failed, and the
# foreign-database hint told the user to stop a database that was the kit's
# own. The cure, proven by hand on a user's Mac: stop that runner (its VM
# exits with it), and the launcher's deploy then brings the deployment up.
#
# ONLY OUR RUNNER, ONLY WHEN CERTAIN. Every listener on this deployment's
# port must be the launcher's runner (_personal_is_runner_process) AND be
# executed from the launcher's own cache (personal_launcher_cache_dir). One
# listener that fails either test - a foreign process, a runner of unknown
# origin - and nothing is touched; the caller keeps its old behaviour. No
# lsof, no listener: nothing to do.
#
# DATA. Stopping the runner is stopping the VM: the deployment directory and
# its data disk are files the runner has open, not files it deletes, and the
# kit already stops this same process in personal_reap_orphan_daemon. SIGTERM
# first, which lets the VM exit on its own terms; SIGKILL only for a runner
# that has not exited and released the port within the budget.
#
# Returns 0 when a runner was stopped and the port is free, 1 otherwise
# (nothing of ours there, not certain, or the port is still held).
EXAKIT_PERSONAL_RUNNER_STOP_WAIT="${EXAKIT_PERSONAL_RUNNER_STOP_WAIT:-20}"
# _personal_runner_of_this_deployment PID - 0 when PID is proven to work for
# THIS deployment: its working directory is $EXAKIT_PERSONAL_DEPLOY_DIR (or
# below it), or it holds a file open under that directory. A runner from the
# same launcher cache can serve another deployment (another directory, another
# port mapping), and stopping it would stop someone else's VM. lsof is the
# only witness; where it cannot answer, nothing is proven and 1 is returned.
# A deploy dir that would prove everything - empty, "/", $HOME itself or an
# ancestor of $HOME such as /Users or /home (any process with a file open in
# the home folder would count) - proves nothing: 1. On macOS the HOME check
# ignores case: APFS is case-insensitive and bash 3.2's pwd -P keeps the case
# as typed, so /users/me is the same folder as /Users/me. A match is the directory itself or a path below it with a "/" after it,
# so a sibling like <dir>2 never counts.
_personal_runner_of_this_deployment() {
    personal_deploy_dir_refresh
    _prd_dir="${EXAKIT_PERSONAL_DEPLOY_DIR:-}"
    [ -n "$_prd_dir" ] && [ -d "$_prd_dir" ] || return 1
    while [ "${_prd_dir%/}" != "$_prd_dir" ]; do _prd_dir="${_prd_dir%/}"; done
    [ -n "$_prd_dir" ] || return 1
    _prd_phys="$(cd "$_prd_dir" 2>/dev/null && pwd -P)"
    [ -n "$_prd_phys" ] || return 1
    [ "$_prd_phys" != "/" ] || return 1
    if [ -n "${HOME:-}" ]; then
        _prd_home="$(cd "$HOME" 2>/dev/null && pwd -P)"
        _prd_cmp="$_prd_phys"
        if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
            _prd_home="$(printf '%s' "$_prd_home" | tr '[:upper:]' '[:lower:]')"
            _prd_cmp="$(printf '%s' "$_prd_cmp" | tr '[:upper:]' '[:lower:]')"
        fi
        if [ -n "$_prd_home" ]; then
            [ "$_prd_cmp" != "$_prd_home" ] || return 1
            case "$_prd_home" in "$_prd_cmp"/*) return 1 ;; esac
        fi
    fi
    _prd_paths="$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
$(lsof -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p')"
    _prd_hit=1
    while IFS= read -r _prd_path; do
        [ -n "$_prd_path" ] || continue
        case "$_prd_path" in
            "$_prd_dir"|"$_prd_dir"/*|"$_prd_phys"|"$_prd_phys"/*) _prd_hit=0; break ;;
        esac
    done <<EOF
$_prd_paths
EOF
    return "$_prd_hit"
}

# _personal_port_held_by_own_runner - 0 when the deployment port has at least
# one listener and EVERY listener is the launcher's runner executed from the
# launcher's own cache AND proven to belong to this deployment
# (_personal_runner_of_this_deployment). Sets _ppo_pids to those listeners.
_personal_port_held_by_own_runner() {
    _ppo_pids=""
    command -v lsof >/dev/null 2>&1 || return 1
    _ppo_cache="$(personal_launcher_cache_dir 2>/dev/null || true)"
    [ -n "$_ppo_cache" ] || return 1
    _ppo_found="$(personal_db_port_pids)"
    [ -n "$_ppo_found" ] || return 1
    for _ppo_pid in $_ppo_found; do
        _personal_is_own_runner_pid "$_ppo_pid" "$_ppo_cache" || return 1
    done
    _ppo_pids="$_ppo_found"
}

# _personal_is_own_runner_pid PID CACHE - 0 when PID is the launcher's runner,
# executed from CACHE, and proven to work for this deployment.
_personal_is_own_runner_pid() {
    _personal_is_runner_process "$1" || return 1
    case "$(ps -p "$1" -o command= 2>/dev/null || true)" in
        *"$2"/*exasol-local-runner*) ;;
        *) return 1 ;;
    esac
    _personal_runner_of_this_deployment "$1" || return 1
}

personal_stop_runner_of_failed_deployment() {
    _personal_port_held_by_own_runner || return 1
    _psr_pids="$_ppo_pids"
    info "Exasol marked this database as failed, but it is still running. Restarting it cleanly (your data is kept)..."
    command -v _exakit_log_file >/dev/null 2>&1 &&
        _exakit_log_file "INFO  stopping runner pid(s)$(printf ' %s' $_psr_pids) on port $(personal_db_port) (launcher state deployment_failed)"
    for _psr_pid in $_psr_pids; do
        kill -TERM "$_psr_pid" 2>/dev/null || true
    done
    _psr_waited=0
    while [ "$_psr_waited" -lt "$EXAKIT_PERSONAL_RUNNER_STOP_WAIT" ]; do
        _psr_alive=""
        for _psr_pid in $_psr_pids; do
            kill -0 "$_psr_pid" 2>/dev/null && _psr_alive=1
        done
        [ -z "$_psr_alive" ] && [ -z "$(personal_db_port_pids)" ] && break
        sleep 1
        _psr_waited=$((_psr_waited + 1))
    done
    _psr_cache="$(personal_launcher_cache_dir 2>/dev/null || true)"
    for _psr_pid in $_psr_pids; do
        if kill -0 "$_psr_pid" 2>/dev/null; then
            # Proven again before a KILL: after the wait the pid may be another
            # process. A proven runner that already let go of the port is still
            # forced: it may hold the VM, and the deploy that follows needs it.
            if [ -z "$_psr_cache" ] || ! _personal_is_own_runner_pid "$_psr_pid" "$_psr_cache"; then
                warn "Process $_psr_pid is still running but is no longer proven to be this deployment's runner - it was not forced."
                continue
            fi
            warn "The runner (pid $_psr_pid) did not exit within ${EXAKIT_PERSONAL_RUNNER_STOP_WAIT}s - forcing it."
            pkill -9 -P "$_psr_pid" 2>/dev/null || true
            kill -9 "$_psr_pid" 2>/dev/null || true
        fi
    done
    _psr_waited=0
    while [ "$_psr_waited" -lt 3 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _psr_waited=$((_psr_waited + 1))
    done
    [ -z "$(personal_db_port_pids)" ]
}

# _personal_vm_already_running <log-line> - did the launcher, since that line of
# this run's log, refuse a deploy or start because its VM is already running?
# Its own words ("Error: VM is already running"), read from the log the way
# _personal_start_network_blocked reads netavark's.
_personal_vm_already_running() {
    [ -n "${1:-}" ] && [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -f "$EXAKIT_LOG_FILE" ] || return 1
    tail -n "+$(( ${1} + 1 ))" "$EXAKIT_LOG_FILE" 2>/dev/null | grep -qi 'VM is already running'
}

# personal_vm_runner_pid - the Exasol runner (the process that IS the VM on
# macOS and Linux) listening on this deployment's database port; nothing when
# none does. A container deployment has no such process: its port is the
# engine's.
personal_vm_runner_pid() {
    for _vrp_pid in $(personal_db_port_pids); do
        if _personal_is_runner_process "$_vrp_pid"; then
            printf '%s' "$_vrp_pid"
            return 0
        fi
    done
    return 1
}

# personal_stuck_vm_hint <log-line> - one sentence for a deployment the
# launcher refuses to deploy because its VM runs: what it is and the command
# that ends it. Empty without the launcher's own "VM is already running".
personal_stuck_vm_hint() {
    _personal_vm_already_running "${1:-}" || return 0
    _svh_pid="$(personal_vm_runner_pid 2>/dev/null || true)"
    [ -n "$_svh_pid" ] || return 0
    printf ' Its VM is still running (pid %s) and the launcher will not deploy over it: stop it with kill %s, then re-run.' "$_svh_pid" "$_svh_pid"
}

# personal_clear_stale_vm - stop the Exasol runner an earlier, failed attempt
# left alive. For the caller that has the launcher's own "VM is already
# running" and a database that does not answer. Returns 0 only when a runner
# was stopped and is gone.
#
# WHICH PROCESS: only an Exasol runner LISTENING ON THIS DEPLOYMENT'S DATABASE
# PORT. Never one found by name alone: a machine can run a second deployment,
# its runner carries the same name, and the name cannot say whose it is - the
# port can. A leftover that never reached the port is left for the ladder
# below (the replace offer). NEVER A YOUNG ONE: inside
# EXAKIT_PERSONAL_REAP_MIN_AGE a runner is a VM still booting, and killing
# that is the data-loss path the reaper's age gate exists for
# (personal_is_orphan_daemon).
#
# AND ONLY THIS DEPLOYMENT'S OWN RUNNER: the port alone is not proof either
# (another deployment can be configured on the same port while this one is
# down). Each listener must pass the same proof as the deployment_failed
# recovery (_personal_is_own_runner_pid: the kit's runner, working inside
# this deployment), and is proven again before a KILL, since after the wait
# the pid may belong to another process. Nothing unproven is ever touched.
personal_clear_stale_vm() {
    _csv_pids=""
    _csv_cache="$(personal_launcher_cache_dir 2>/dev/null || true)"
    [ -n "$_csv_cache" ] || return 1
    for _csv_pid in $(personal_db_port_pids); do
        _personal_is_own_runner_pid "$_csv_pid" "$_csv_cache" && _csv_pids="$_csv_pids $_csv_pid"
    done
    [ -n "$_csv_pids" ] || return 1
    for _csv_pid in $_csv_pids; do
        _csv_age="$(_personal_proc_age_seconds "$_csv_pid" 2>/dev/null || true)"
        if [ "${EXAKIT_PERSONAL_REAP_MIN_AGE:-0}" -gt 0 ] && [ -n "$_csv_age" ] && \
           [ "$_csv_age" -lt "$EXAKIT_PERSONAL_REAP_MIN_AGE" ]; then
            command -v _exakit_log_file >/dev/null 2>&1 &&
                _exakit_log_file "INFO  not stopping runner pid $_csv_pid: ${_csv_age}s old, still within the start budget"
            return 1
        fi
    done
    for _csv_pid in $_csv_pids; do
        command -v _exakit_log_file >/dev/null 2>&1 &&
            _exakit_log_file "INFO  stopping the runner an earlier attempt left alive (pid $_csv_pid)"
        pkill -P "$_csv_pid" 2>/dev/null || true
        kill "$_csv_pid" 2>/dev/null || true
    done
    _csv_waited=0
    while [ "$_csv_waited" -lt 10 ]; do
        _csv_alive=0
        for _csv_pid in $_csv_pids; do kill -0 "$_csv_pid" 2>/dev/null && _csv_alive=1; done
        [ "$_csv_alive" = 1 ] || return 0
        sleep 1
        _csv_waited=$((_csv_waited + 1))
    done
    for _csv_pid in $_csv_pids; do
        if kill -0 "$_csv_pid" 2>/dev/null; then
            if ! _personal_is_own_runner_pid "$_csv_pid" "$_csv_cache"; then
                warn "Process $_csv_pid is still running but is no longer proven to be this deployment's runner - it was not forced."
                continue
            fi
            pkill -9 -P "$_csv_pid" 2>/dev/null || true
            kill -9 "$_csv_pid" 2>/dev/null || true
        fi
    done
    sleep 1
    for _csv_pid in $_csv_pids; do kill -0 "$_csv_pid" 2>/dev/null && return 1; done
    return 0
}

# personal_wait_out_young_runner <seconds> - wait for the port while a runner
# too young to judge holds it: until the port is free, or the rest of the
# runner's start budget (plus a margin) has passed. Says so once; never fails.
# Bounded by EXAKIT_PERSONAL_REAP_MIN_AGE, so at most about three minutes.
personal_wait_out_young_runner() {
    _wyr_left=$(( ${1:-0} + 5 ))
    [ "$_wyr_left" -gt 5 ] || return 0
    info "Waiting up to ${_wyr_left}s for it to finish starting or to stop, then checking the port again."
    while [ "$_wyr_left" -gt 0 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 5
        _wyr_left=$((_wyr_left - 5))
    done
    return 0
}

# --- deployment progress ----------------------------------------------------
# `exasol install local` narrates itself in structured JSON and then prints a
# forty-line connection overview -- none of which the person waiting for a
# database can act on, and all of whose useful parts the kit restates in its own
# closing panel. So the stream is consumed rather than shown: each line is
# matched against the launcher's own milestone messages, and one line is redrawn
# in place with a bar, a percentage and the phase in plain English.
#
# Nothing is lost by hiding it. Every raw line still goes to the logfile exactly
# as before; a copy is kept so a FAILED deploy can print the launcher's own last
# words instead of only a log path; and the launcher's EULA notice -- the one
# part of that output the user genuinely must see -- is replayed afterwards, in
# the launcher's own words rather than a copy of them that could go stale.

# _personal_deploy_milestone <line> — "<pct>|<phase>" for a line that marks
# progress, nothing for any other line.
#
# The strings are the launcher's own log messages, matched as plain substrings
# rather than as JSON so that a switch to text logging keeps working. An
# unrecognised line simply does not move the bar, which is what makes a launcher
# release that renames a message degrade to a slower-looking bar instead of to a
# wrong one. The percentages are milestone positions, not a measured fraction of
# the work: the bar moves only when the launcher has actually reached the next
# stage, and the elapsed counter -- which ticks every second whatever the
# launcher is doing -- is what says "still alive" in between.
#
# KEEP EVERY PHASE TO 21 CHARACTERS OR FEWER. The phase gets 30% of the progress
# line: 21 columns on an 80-column terminal, 27 on a 100, and never more than 33
# however wide the window is opened. Anything longer is ellipsed -- and a phrase
# cut mid-word tells the reader less than a shorter one would have said whole.
_personal_deploy_milestone() {
    case "$1" in
        *"validating presets"*)                    printf '5|10|2|Preparing to deploy' ;;
        *"extracting preset files"*)               printf '10|20|2|Preparing to deploy' ;;
        *"successfully initialized deployment"*)   printf '20|35|5|Preparing to deploy' ;;
        # The long one, and the only label that covers two different situations:
        # the launcher emits one of these whether it DOWNLOADED the resource or
        # found it already cached. It said "Fetching the Exasol runtime" for
        # both, which was wrong on the warm path twice over -- nothing is
        # fetched, and per the note below the launcher then goes quiet for the
        # VM boot, so "fetching" sat on screen through twenty-five seconds of
        # something else entirely. The wording now holds either way.
        #
        # On a warm cache the launcher says nothing at all between here and
        # "waiting for database to start" -- about twenty-five seconds of VM
        # boot -- so the ceiling is that next milestone rather than the
        # "starting deployment" one, which a warm run never emits. If it DOES
        # emit it, the line below picks the segment up mid-flight.
        #
        # It is also short, per the budget above: the first wording here ran to
        # 33 characters and was ellipsed on every terminal but the very widest.
        *"fetching resource"*|*"found resource in cache"*)
                                                   printf '35|65|25|Getting Exasol ready' ;;
        *"starting deployment"*)                   printf '45|65|15|Starting the database' ;;
        *"waiting for database to start"*)         printf '65|90|10|Waiting for Exasol' ;;
        *"installing script language container"*)  printf '80|90|15|Installing languages' ;;
        *"no installation steps defined"*)         printf '90|100|4|Finishing up' ;;
        *"Completed deploying"*)                   printf '100|100|0|Deployed' ;;
    esac
}

# Eighths of a block. A twenty-cell bar advancing in whole cells steps 5% at a
# time, which at five frames a second reads as a bar that is stuck and then
# jumps. The partial-block glyphs give the same bar eight times the resolution,
# so it creeps. Index 0 is a space: the frontier cell is EMPTY when there is no
# fraction to draw, which is what keeps the dim remainder unbroken.
# _personal_deploy_collect <state-file> <tail-file> <notice-file> — consume the
# launcher's output: log every line, keep the tail, keep the EULA notice, and
# turn the lines that mean something into progress. It runs on the right-hand
# side of the pipe, so everything it learns has to be handed back through files.
_personal_deploy_collect() {
    _pdc_pct=0
    _pdc_phase=""
    _pdc_shown=""
    _pdc_quiet=0
    _pdc_stalled=0
    while :; do
        _pdc_line=""
        # A bounded read, not a blocking one. The launcher re-attaches stdin to
        # the terminal so a first-run licence confirmation can read the
        # keyboard - but the PROMPT arrives here without a newline, so it never
        # leaves this pipe: the question sat invisible in the buffer while the
        # bar showed 5% forever, with nothing anywhere saying why. The install
        # cannot answer a licence question for the user (and must not), so the
        # bounded read exists to NOTICE the silence and put the situation on
        # screen, where the still-connected keyboard can resolve it.
        #
        # bash 3.2 returns the SAME code for a timeout and for EOF, so the two
        # are told apart by the clock: only a wait that consumed the whole
        # window was a timeout. (A final line without a trailing newline also
        # returns non-zero, with the line in the variable - kept, then EOF on
        # the next pass.)
        _pdc_win="${EXAKIT_PERSONAL_DEPLOY_STALL:-300}"
        [ "$_pdc_win" -gt 30 ] && _pdc_win=30
        # Floor of 2: the EOF discriminator below needs at least one full second
        # of difference between "returned instantly" and "waited the window".
        [ "$_pdc_win" -lt 2 ] && _pdc_win=2
        _pdc_t0=$SECONDS
        if IFS= read -r -t "$_pdc_win" _pdc_line; then
            _pdc_quiet=0
        elif [ -z "$_pdc_line" ] && [ $((SECONDS - _pdc_t0)) -lt $((_pdc_win - 1)) ]; then
            break   # EOF
        elif [ -z "$_pdc_line" ]; then
            _pdc_quiet=$((_pdc_quiet + (SECONDS - _pdc_t0)))
            if [ "$_pdc_quiet" -ge "${EXAKIT_PERSONAL_DEPLOY_STALL:-300}" ] && [ "$_pdc_stalled" -eq 0 ]; then
                _pdc_stalled=1
                # Stop the animation and switch to plain lines: a bar that
                # keeps creeping is the opposite of what a stalled launcher
                # should look like. warn is never gated by EXAKIT_QUIET_DETAIL.
                ui_progress_end
                EXAKIT_DEPLOY_LIVE=0
                if [ "$_pdc_quiet" -ge 120 ]; then
                    warn "The launcher has said nothing for $((_pdc_quiet / 60)) minutes."
                else
                    warn "The launcher has said nothing for $_pdc_quiet seconds."
                fi
                warn "It may be waiting for a first-run confirmation it could not display. Your keyboard is still connected to it - typing an answer here reaches it."
                _personal_deploy_print_tail "$2"
                warn "Still waiting. Full output: ${EXAKIT_LOG_FILE:-the install log}. Ctrl-C is safe - re-running the installer resumes, or run '$(personal_cli) install local -d $EXAKIT_PERSONAL_DEPLOYMENT' yourself to see the prompt."
            fi
            continue
        fi
        [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_pdc_line" >> "$EXAKIT_LOG_FILE"
        printf '%s\n' "$_pdc_line" >> "$2"
        case "$_pdc_line" in
            *"End User License Agreement"*|*"terms-and-conditions"*)
                printf '%s\n' "$_pdc_line" >> "$3" ;;
        esac
        _pdc_hit="$(_personal_deploy_milestone "$_pdc_line")"
        [ -n "$_pdc_hit" ] || continue
        # Monotonic: a message arriving out of the expected order never rewinds
        # the bar, and a repeated one never redraws it.
        [ "${_pdc_hit%%|*}" -gt "$_pdc_pct" ] 2>/dev/null || continue
        _pdc_pct="${_pdc_hit%%|*}"
        _pdc_rest="${_pdc_hit#*|}"
        _pdc_ceil="${_pdc_rest%%|*}"; _pdc_rest="${_pdc_rest#*|}"
        _pdc_secs="${_pdc_rest%%|*}"
        _pdc_phase="${_pdc_rest#*|}"
        ui_progress_state "$1" "$_pdc_pct" "$_pdc_ceil" "$_pdc_secs" "$_pdc_phase"
        # Nothing is animating (piped, CI, NO_COLOR, a dumb terminal): one plain
        # logged line per phase, rather than a line that redraws nothing. After
        # a stall the quiet-detail gate is bypassed - the launcher just came
        # back to life and the reader deserves to see it move again.
        if [ "${EXAKIT_DEPLOY_LIVE:-0}" != 1 ] && [ "$_pdc_phase" != "$_pdc_shown" ]; then
            if [ "$_pdc_stalled" -eq 1 ]; then
                info_step "$_pdc_phase"
            else
                info "$_pdc_phase"
            fi
            _pdc_shown="$_pdc_phase"
        fi
    done
}

# _personal_deploy_print_tail <file> — the launcher's own last words, in the dim
# gutter foreign output has always used here. A failed deploy used to leave the
# whole stream on screen; now that the stream is consumed, the end of it is what
# has to survive, or a failure would be left with nothing but a log path.
_personal_deploy_print_tail() {
    [ -s "$1" ] || return 0
    foreign_note "last lines from the exasol launcher"
    tail -n 12 "$1" | personal_launcher_words_for_kit | while IFS= read -r _pdt_line; do
        printf '      %s%s %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$_pdt_line" "${UI_RESET:-}"
    done
}

# personal_launcher_words_for_kit — the launcher's lines (stdin) as a kit user
# reads them (stdout). The launcher speaks to its own users: "Run `start` to
# restart or `destroy` to delete resources" was shown verbatim in the kit's
# failure box, and for a kit user `destroy` deletes their database. Its
# `start` becomes the kit's `exakit start`, and a sentence that tells the
# reader to destroy is left out. Only the screen copy: the log keeps the
# launcher's own words. ⇄ twin: ConvertTo-PersonalKitWords.
personal_launcher_words_for_kit() {
    awk -v q="'" '
        BEGIN { d = "`destroy`|" q "destroy" q "|exasol destroy" }
        {
            line = $0
            gsub(/Run `start` to restart or `destroy` to delete resources/, "Run `exakit start` to restart", line)
            gsub(/ or `destroy` to [^.]*/, "", line)
            if (line ~ d) {
                out = ""; rest = line
                while ((i = index(rest, ". ")) > 0) {
                    part = substr(rest, 1, i); rest = substr(rest, i + 2)
                    if (part !~ d) out = out (out == "" ? "" : " ") part
                }
                if (rest !~ d) out = out (out == "" ? "" : " ") rest
                line = out
            }
            gsub(/`start`/, "`exakit start`", line)
            if (line != "" || $0 == "") print line
        }'
}

# _personal_deploy_print_notice <file> — replay the launcher's EULA notice. It is
# the one part of the hidden output the user must still see, and it is replayed
# verbatim so this kit never states licence terms in words of its own.
_personal_deploy_print_notice() {
    [ -s "$1" ] || return 0
    _pdn_first=1
    while IFS= read -r _pdn_line; do
        [ -n "$_pdn_line" ] || continue
        if [ "$_pdn_first" = 1 ]; then
            info "$_pdn_line"
            _pdn_first=0
        else
            printf '      %s%s%s\n' "${UI_DIM:-}" "$_pdn_line" "${UI_RESET:-}"
            _exakit_log_file "INFO  $_pdn_line"
        fi
    done < "$1"
}

# personal_recover_slow_first_boot — the launcher gave up on a first boot that
# was merely slow; wait with the kit's budget and reconcile the launcher.
#
# When the launcher's 27-second wait runs out it records deployment_failed and,
# in that state, its own `stop` and `start` do nothing - so a database that came
# up ten seconds later was reported as a failed install, and every later
# `exakit start` waited the full 150 s for a port the launcher would never bring
# back. Observed four times in one day. The port answering is the evidence that
# matters; when it does, the launcher's own `deploy` retry (its advice on the
# failure) makes its record agree. If that retry still fails while the database
# answers, the kit says so and carries on with the database it can reach - the
# launcher's record is a bookkeeping problem, not a missing database.
# Returns 1 only when the database never answered within the budget.
personal_recover_slow_first_boot() {
    personal_deploy_dir_refresh
    _prs_budget="${EXAKIT_PERSONAL_READY_TIMEOUT:-150}"
    info "The launcher stopped waiting after its own short budget, but the deployment exists — waiting up to ${_prs_budget}s for the database"
    _prs_t0="$(date +%s 2>/dev/null || echo 0)"
    _prs_tries=0
    PERSONAL_CONTAINER_ERROR=""
    until personal_tls_answers; do
        _prs_tries=$(( _prs_tries + 1 ))
        _prs_elapsed=$(( $(date +%s 2>/dev/null || echo 0) - _prs_t0 ))
        [ "$_prs_elapsed" -ge "$_prs_budget" ] && return 1
        [ "$_prs_tries" -ge $(( _prs_budget / 5 + 1 )) ] && return 1
        # The same early exit as the readiness probe: a container that refused
        # to start is not slow.
        if [ $(( _prs_tries % 3 )) -eq 0 ]; then
            _personal_container_refused && return 1
        fi
        sleep 5
    done
    ok "The database answered after $(( $(date +%s 2>/dev/null || echo 0) - _prs_t0 ))s"
    personal_set_first_boot_pending 0
    # NOTHING TO RECONCILE when the launcher already says its database is up:
    # a deploy over a running VM is what the launcher answers with "VM is
    # already running" and a record that then refuses every command, stop
    # included. Its own ready state plus the handshake is the same evidence
    # personal_deployment_running accepts as ours. Any other answer - failed,
    # unknown, empty - still gets the reconcile below.
    case "$(personal_launcher_state 2>/dev/null || true)" in
        database_ready|running)
            ok "The launcher's record agrees with the running database"
            return 0
            ;;
    esac
    EXAKIT_ACTIVE_LABEL="Reconciling the launcher's record"
    # THE RECONCILE IS THE OWNERSHIP PROOF. A handshake says a database answers
    # on the port, not whose: with Windows and WSL sharing one network stack it
    # may be the other side's. The launcher's deploy connects with this
    # deployment's own credentials, so its success is the one signal that the
    # database that answered is this one - and its failure is a failure, not a
    # database "the kit can reach".
    if run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"; then
        ok "The launcher's record agrees with the running database"
        return 0
    fi
    warn "The launcher still records this deployment as failed although something answers on port $(personal_db_port).$(personal_foreign_db_hint)"
    return 1
}

# _personal_podman_answers - the smallest question that needs all of podman to
# work. Sets _ppr_said to the last thing it said, for the reason line.
_personal_podman_answers() {
    _ppr_said="$(exakit_run_bounded 30 podman info --format '{{.Host.Arch}}' 2>&1)" && return 0
    _ppr_said="$(printf '%s\n' "$_ppr_said" | grep -v '^[[:space:]]*$' | tail -1)"
    return 1
}

# personal_podman_running - INSTALLED IS NOT RUNNING, and the difference is a
# whole failed install. `command -v podman` answers whether the binary is on
# PATH; it says nothing about whether podman can start a container. A rootless
# podman with no sub-id range, a storage directory left behind by a different
# uid, a service the distro never enabled - each of those has podman on PATH
# and fails the instant the launcher asks it for anything, several minutes in,
# with an error that names neither podman nor the kit.
#
# Podman on Linux has no daemon to be "up", so `podman info` IS the check: it
# needs the binary, the storage, the sub-id ranges and the user namespace, and
# it is the same thing the launcher does first. Windows has a machine that can
# be stopped, which is why its twin (Test-PersonalPodmanRunning) starts one.
#
# 0 when podman answers, 1 when it does not - with the reason left behind for
# the step to record. Not installed is 0: that is a different failure, already
# named by personal_install_podman.
personal_podman_running() {
    # Linux and WSL only, like personal_install_podman above. The macOS launcher
    # brings its own container runtime, so a Podman Desktop the user installed
    # and left stopped has nothing to do with the deployment - checking it
    # skipped the database step on a Mac that could deploy.
    case "$(detect_os)" in
        linux|wsl) : ;;
        *) return 0 ;;
    esac
    command -v podman >/dev/null 2>&1 || return 0
    _personal_podman_answers && return 0
    # ONE REPAIR, THEN ASK AGAIN. Much the commonest reason a rootless podman
    # is installed and still cannot start anything is a missing sub-id range,
    # which the heal fixes with consent. Anything else is reported as it is.
    personal_heal_rootless_podman
    _personal_podman_answers && return 0
    warn "Podman is installed, but it cannot run containers on this machine."
    [ -n "${_ppr_said:-}" ] && info "What it said: $_ppr_said"
    info "Check it with 'podman info'; once that answers, re-run the installer to finish the install: $(exakit_install_command)"
    exakit_note_failure "Podman is installed but not usable ('podman info' failed): ${_ppr_said:-no output}"
    return 1
}

# personal_container_error — the error podman recorded for this deployment's
# container when it never ran ("created") or died ("exited"), first line only;
# empty otherwise. THE REAL ERROR, which the launcher never repeats: a
# container can sit in "created" with "crun: controller 'pids' is not
# available" while the kit waits out its whole budget and then says "never
# answered". Nothing is reported while any of the containers runs - a stale
# one from an earlier deployment is not this one's error. Linux and WSL only:
# the macOS launcher runs its own VM, and a podman there is somebody else's.
# Twin of Get-PersonalContainerError.
personal_container_error() {
    case "$(detect_os 2>/dev/null)" in
        linux|wsl) : ;;
        *) return 0 ;;
    esac
    _pce_engine="${EXAKIT_PERSONAL_ENGINE:-$(personal_engine_recorded)}"
    command -v "${_pce_engine:-podman}" >/dev/null 2>&1 || return 0
    _pce_list="$(exakit_run_bounded 15 "$_pce_engine" ps -a --filter name=exasol-db --format '{{.Names}} {{.State}}' 2>/dev/null)" || return 0
    case " $_pce_list " in
        *" running"*) return 0 ;;
    esac
    printf '%s\n' "$_pce_list" | head -3 | while read -r _pce_name _pce_state _pce_rest; do
        case "$_pce_state" in
            created|exited|stopped) : ;;
            *) continue ;;
        esac
        _pce_err="$(exakit_run_bounded 15 "$_pce_engine" inspect --format '{{.State.Error}}' "$_pce_name" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)"
        if [ -n "$_pce_err" ]; then
            printf '%s\n' "$_pce_err"
            break
        fi
    done
    return 0
}

# --- container engine ---------------------------------------------------------
# Exasol Personal 2.4 runs a local deployment on Docker or on Podman on Linux
# and Windows; macOS has the launcher's own VM runner and no engine to choose.
# The launcher keeps whatever engine a deployment first started on, and a
# deployment made by an earlier launcher keeps Podman - so the kit chooses only
# for a FRESH deployment, passes that choice explicitly, and records it as
# runtime.engine so every later health check reads one key.
#
# The kit's order is Docker when it is usable, else Podman. The launcher's own
# `auto` is the reverse (Podman first), which is why the flag is always passed
# rather than left to it. Usable means the daemon answers, runs Linux
# containers, and is Docker Engine 29 or newer - the launcher's floor. The kit
# never installs or starts Docker; it installs Podman, as it always has, when
# neither engine is there. EXAKIT_CONTAINER_ENGINE=docker|podman names one
# outright.
EXAKIT_PERSONAL_ENGINE="${EXAKIT_PERSONAL_ENGINE:-}"

# personal_engine_platform - true where there is an engine to choose at all.
personal_engine_platform() {
    case "$(detect_os)" in
        linux|wsl) return 0 ;;
        *) return 1 ;;
    esac
}

# personal_docker_usable - 0 when the launcher could deploy on this Docker now.
# Otherwise 1, with the one-line reason in _pdu_said for the caller to print
# and its kind in _pdu_kind: missing (no docker, or Podman's docker emulation),
# denied (the daemon refuses this user), down, type, version. Twin of
# Test-PersonalDockerUsable; detect_docker_reason asks the same for preflight.
#
# ASKED ONCE PER PROCESS. The compatibility gate, the engine choice, the
# adoption check and the deploy's own "is it running" all want this answer,
# and each `docker info` is bounded at 15 s: a daemon still starting held the
# install silent for that long, several times over. The verdict is kept here
# and dropped only where Docker is expected to have changed - the
# Docker-stopped prompt's re-probes (_personal_wait_for_docker) and
# _personal_docker_uncache. Kept in variables, so a caller that wants it
# shared must ask in the current shell, not inside $(...).
personal_docker_usable() {
    if [ -n "${_PERSONAL_PDU_RC:-}" ]; then
        _pdu_said="$_PERSONAL_PDU_SAID"
        _pdu_kind="$_PERSONAL_PDU_KIND"
        return "$_PERSONAL_PDU_RC"
    fi
    _PERSONAL_PDU_RC=0
    _personal_docker_probe || _PERSONAL_PDU_RC=1
    _PERSONAL_PDU_SAID="$_pdu_said"
    _PERSONAL_PDU_KIND="$_pdu_kind"
    return "$_PERSONAL_PDU_RC"
}

# _personal_docker_uncache - forget the Docker verdict: the next
# personal_docker_usable asks the daemon again.
_personal_docker_uncache() {
    _PERSONAL_PDU_RC=""
}

# _personal_docker_is_podman [probe output] - 0 when the `docker` on PATH is
# Podman's Docker emulation (podman-docker), banner or no banner: a quieted
# one (/etc/containers/nodocker) read as a stopped Docker and got a prompt to
# start a Docker that does not exist. Twin of detect_docker_is_podman.
_personal_docker_is_podman() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        *"emulate docker cli using podman"*|*"can't evaluate field ostype"*) return 0 ;;
    esac
    _pdp_path="$(command -v docker 2>/dev/null || true)"
    [ -n "$_pdp_path" ] || return 1
    _pdp_real="$(readlink -f "$_pdp_path" 2>/dev/null || true)"
    case "${_pdp_real##*/}" in podman|podman-remote*) return 0 ;; esac
    case "$(exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-15}" docker --version 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
        *podman*) return 0 ;;
    esac
    return 1
}

# _personal_docker_probe - the uncached question behind personal_docker_usable.
_personal_docker_probe() {
    _pdu_said=""
    _pdu_kind=""
    if ! command -v docker >/dev/null 2>&1; then
        _pdu_said="Docker is not on PATH"
        _pdu_kind="missing"
        return 1
    fi
    # One probe answers all three questions. STDERR IS KEPT, because "did not
    # answer" has causes that want different advice: a user outside the docker
    # group gets "permission denied" from a daemon that runs fine, and telling
    # them to start it sent them to Podman on a box whose Docker works.
    _pdu_errf="$(mktemp "${TMPDIR:-/tmp}/exakit-docker.XXXXXX" 2>/dev/null || true)"
    [ -n "$_pdu_errf" ] || _pdu_errf=/dev/null
    _pdu_info="$(exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-15}" \
        docker info --format '{{.OSType}} {{.ServerVersion}}' 2>"$_pdu_errf")" || _pdu_info=""
    _pdu_err=""
    if [ "$_pdu_errf" != /dev/null ]; then
        _pdu_err="$(cat "$_pdu_errf" 2>/dev/null || true)"
        rm -f "$_pdu_errf"
    fi
    _pdu_info="$(printf '%s' "$_pdu_info" | tr -d '\r' | head -1)"
    _pdu_type="${_pdu_info%% *}"
    _pdu_ver="${_pdu_info#* }"
    if [ -z "$_pdu_type" ] || [ "$_pdu_type" = "$_pdu_info" ]; then
        if _personal_docker_is_podman "$_pdu_err $_pdu_info"; then
            # Fedora/RHEL's podman-docker: there is no Docker here at all.
            _pdu_said="'docker' here is Podman's Docker emulation"
            _pdu_kind="missing"
            return 1
        fi
        case "$(printf '%s %s' "$_pdu_err" "$_pdu_info" | tr '[:upper:]' '[:lower:]')" in
            *"permission denied"*)
                # THE FACT, NOT A REMEDY: by the time this is said the install
                # is about to deploy, and joining the group afterwards does
                # not move the deployment. The remedy is the preflight's and
                # personal_resolve_engine's to say, with its consequence.
                _pdu_said="Docker is running but your user cannot use it (permission denied on its socket)"
                _pdu_kind="denied" ;;
            *"could not be found in this wsl"*)
                # Docker Desktop's WSL shim answers this while Desktop is stopped.
                _pdu_said="Docker Desktop is not running (its WSL integration answered, the daemon did not)"
                _pdu_kind="down" ;;
            *)
                _pdu_said="Docker is installed but not running ('docker info' did not answer)"
                _pdu_kind="down" ;;
        esac
        return 1
    fi
    _pdu_kind="type"
    if [ "$_pdu_type" != "linux" ]; then
        _pdu_said="Docker runs $_pdu_type containers here, and Exasol Personal needs Linux containers"
        return 1
    fi
    _pdu_kind="version"
    _pdu_major="${_pdu_ver%%.*}"
    case "$_pdu_major" in
        ''|*[!0-9]*)
            _pdu_said="Docker Engine version '$_pdu_ver' could not be read"
            return 1 ;;
    esac
    if [ "$_pdu_major" -lt 29 ]; then
        _pdu_said="Docker Engine $_pdu_ver is older than 29, the oldest Exasol Personal 2.4 runs on"
        return 1
    fi
    _pdu_kind=""
    return 0
}

# The one line said when the launcher in use cannot be handed --container-engine.
EXAKIT_PERSONAL_ENGINE_UNTOLD="this Exasol launcher cannot be told which engine to use, so the database runs on Podman"

# personal_launcher_takes_engine - true when the launcher that will deploy can
# be told the engine. One that is not there yet will be the kit's own download,
# which can; a kept launcher on PATH (a self-installed 2.3) cannot, and run
# without the flag it deploys on Podman whatever the kit chose.
#
# ONE `install local --help` PER LAUNCHER. The gate, the engine choice and
# the deploy's flag all ask, and each answer costs a launcher start. The verdict
# is kept against the launcher's path and its `ls -lniL` line (inode, size,
# time), so the launcher step replacing or downloading a launcher is a new
# question and nothing else is. Variables, so ask in the current shell.
personal_launcher_takes_engine() {
    _plt_cli="$(personal_cli)"
    [ -x "$_plt_cli" ] || return 0
    _plt_key="$_plt_cli|$(ls -lniL "$_plt_cli" 2>/dev/null || true)"
    if [ "${_PERSONAL_PLT_KEY:-}" != "$_plt_key" ]; then
        _PERSONAL_PLT_TAKES=1
        # `install local --help`, NOT `install --help`: --container-engine is
        # a variable of the `local` preset, and the launcher lists a preset's
        # variables only under that preset's help. Asking the bare command
        # read every 2.4 launcher as "cannot be told" and sent a Docker
        # machine to Podman. Seen on a real Windows install.
        if exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" \
                "$_plt_cli" install local --help 2>&1 \
                | personal_help_names_token "--container-engine"; then
            _PERSONAL_PLT_TAKES=0
        fi
        _PERSONAL_PLT_KEY="$_plt_key"
    fi
    return "$_PERSONAL_PLT_TAKES"
}

# _personal_wait_for_docker - after the user said Docker is starting: probe up
# to 3 times over about 30 s. Docker Desktop's WSL integration answers tens of
# seconds after its window appears, and one early Enter used to mean Podman.
# Each re-probe asks the daemon afresh: the kept verdict is the "not running"
# this prompt exists to get past.
_personal_wait_for_docker() {
    _pwd_n=0
    while [ "$_pwd_n" -lt 3 ]; do
        _personal_docker_uncache
        personal_docker_usable && return 0
        _pwd_n=$((_pwd_n + 1))
        if [ "$_pwd_n" -lt 3 ]; then
            [ "$_pwd_n" = 1 ] && info "Docker did not answer yet - trying again for about 30 s."
            sleep "${EXAKIT_DOCKER_WAIT_STEP:-10}" 2>/dev/null || true
        fi
    done
    _pdu_said="Docker still did not answer after about 30 s"
    return 1
}

# personal_resolve_engine - choose the engine for a FRESH deployment into
# EXAKIT_PERSONAL_ENGINE: "docker" or "podman", nothing on macOS. 1 only when
# EXAKIT_CONTAINER_ENGINE names docker and docker is not usable, or the
# launcher cannot be told to use it: a named engine is never silently swapped
# for the other one.
#
# DOCKER ONLY WHEN THE LAUNCHER CAN BE TOLD. A launcher kept on PATH that
# predates --container-engine deploys on Podman whatever the kit decides, and
# the kit used to announce and record Docker over it. Such a launcher means
# Podman, said in one line.
#
# Docker that is installed and not running is the one case worth a second
# look, and only where someone can act on it: with a terminal the kit asks
# for Docker to be started and, after Enter, probes up to 3 times over about
# 30 s. Without one (an agent, a piped install, CI) there is nobody to start
# it, so Podman it is - said, not silently. A daemon that refuses this user
# is not "not running" and is not offered the prompt: its reason names the
# docker group.
personal_resolve_engine() {
    EXAKIT_PERSONAL_ENGINE=""
    personal_engine_platform || return 0
    case "${EXAKIT_CONTAINER_ENGINE:-}" in
        podman)
            EXAKIT_PERSONAL_ENGINE="podman"
            return 0 ;;
        docker)
            if ! personal_docker_usable; then
                warn "EXAKIT_CONTAINER_ENGINE=docker, but $_pdu_said."
                info "Fix Docker and re-run the installer, or drop EXAKIT_CONTAINER_ENGINE to let the kit use Podman: $(exakit_install_command)"
                exakit_note_failure "EXAKIT_CONTAINER_ENGINE=docker but $_pdu_said"
                return 1
            fi
            # A LAUNCHER THAT CANNOT BE TOLD deploys on Podman whatever the kit
            # says, so a named Docker it cannot honour stops the step.
            if ! personal_launcher_takes_engine; then
                warn "EXAKIT_CONTAINER_ENGINE=docker, but $EXAKIT_PERSONAL_ENGINE_UNTOLD."
                info "Update the launcher ('exakit update personal'), or drop EXAKIT_CONTAINER_ENGINE: $(exakit_install_command)"
                exakit_note_failure "EXAKIT_CONTAINER_ENGINE=docker but $EXAKIT_PERSONAL_ENGINE_UNTOLD"
                return 1
            fi
            EXAKIT_PERSONAL_ENGINE="docker"
            return 0 ;;
        '') : ;;
        *) die "EXAKIT_CONTAINER_ENGINE must be docker or podman, not '${EXAKIT_CONTAINER_ENGINE}'." ;;
    esac
    _pre_docker=1
    _pre_said=0
    personal_docker_usable && _pre_docker=0
    if [ "$_pre_docker" != 0 ] && [ "$_pdu_kind" = denied ]; then
        # SAID BEFORE THE DATABASE EXISTS, WITH ITS CONSEQUENCE. The old line
        # named the docker group as the fix; people joined it, re-ran, and the
        # deployment stayed on Podman, because an existing deployment keeps
        # its engine.
        info "$_pdu_said, so this install continues on Podman."
        info "Joining the docker group and re-running will not move this deployment to Docker. To use Docker: stop now, add your user to the docker group (root-level access; log out and back in) and re-run - or later, 'exakit uninstall' and reinstall with EXAKIT_CONTAINER_ENGINE=docker."
        _pre_said=1
    fi
    if [ "$_pre_docker" != 0 ] && [ "$_pdu_kind" = down ] && [ -n "$(_exakit_prompt_tty)" ]; then
        # The platform's own words: native Linux has no Docker Desktop.
        if [ "$(detect_os)" = wsl ]; then
            info "Docker is installed but not running. Start Docker Desktop on Windows to deploy on it."
        else
            info "Docker is installed but not running. Start it ('sudo systemctl start docker') to deploy on it."
        fi
        _pre_answer="$(prompt_text "Press Enter once Docker is running, or type p to use Podman instead" "")"
        case "$_pre_answer" in
            # Chosen, so nothing more to say about Docker.
            p|P|podman) _pdu_kind="chosen" ;;
            *) _personal_wait_for_docker && _pre_docker=0 ;;
        esac
    fi
    if [ "$_pre_docker" = 0 ]; then
        if personal_launcher_takes_engine; then
            EXAKIT_PERSONAL_ENGINE="docker"
            return 0
        fi
        info "Docker is usable, but $EXAKIT_PERSONAL_ENGINE_UNTOLD."
    elif [ "$_pre_said" = 0 ] && [ "$_pdu_kind" != missing ] && [ "$_pdu_kind" != chosen ]; then
        info "$_pdu_said - the database will run on Podman."
    fi
    EXAKIT_PERSONAL_ENGINE="podman"
    return 0
}

# personal_engine_planned - the engine this run would reach, asking nobody and
# saying nothing: the compatibility gate's question, answered before the
# launcher step. Twin of Resolve-PersonalEngine -Probe. An existing deployment
# answers from personal_engine_existing; a fresh one the way
# personal_resolve_engine would without a terminal.
#
# The answer is printed AND kept in _PERSONAL_PLANNED: called in the current
# shell (`personal_engine_planned >/dev/null`), its Docker and launcher probes
# stay cached for the deploy step, so a fresh install asks each once.
personal_engine_planned() {
    _PERSONAL_PLANNED=""
    personal_engine_platform || return 0
    if personal_deployment_exists; then
        personal_engine_existing quiet >/dev/null
        _PERSONAL_PLANNED="$_PERSONAL_EXISTING"
    else
        case "${EXAKIT_CONTAINER_ENGINE:-}" in
            podman|docker) _PERSONAL_PLANNED="$EXAKIT_CONTAINER_ENGINE" ;;
            *)
                if personal_docker_usable && personal_launcher_takes_engine; then
                    _PERSONAL_PLANNED="docker"
                else
                    _PERSONAL_PLANNED="podman"
                fi ;;
        esac
    fi
    printf '%s' "$_PERSONAL_PLANNED"
}

# _personal_deployment_id - the launcher's id for the deployment on disk, from
# whichever of its state files names it; empty when none does.
_personal_deployment_id() {
    personal_deploy_dir_refresh
    _personal_deployment_id_in "$EXAKIT_PERSONAL_DEPLOY_DIR"
}

# _personal_deployment_id_in <dir> - the same, for the deployment in <dir>:
# detect_personal_deployment_id, the one reader (the state file first, the
# top-level key, never "local").
_personal_deployment_id_in() {
    detect_personal_deployment_id "${1:-}"
}

# _personal_short <text> — one line of foreign output, cut to what a terminal
# row can carry; the pids error alone names a cgroup path 150 characters deep.
_personal_short() {
    printf '%s\n' "$1" | head -1 | cut -c1-240
}

# personal_known_cause <text> — "cause|remedy" for an error the kit recognises
# in a container's State.Error or in the launcher's output, in the words of
# this platform; nothing, and 1, for anything else. Twin of
# Get-PersonalKnownCause (whose remedies are the Windows machine's).
personal_known_cause() {
    _pkc_os="$(detect_os 2>/dev/null || true)"
    case "$1" in
        *"controller "?"pids"?" is not available"*)
            printf "rootless Podman gets no 'pids' cgroup controller, so the database container cannot start (podman-container-tools/podman#29909)|"
            if [ "$_pkc_os" = "wsl" ]; then
                printf "this is a known WSL 2.9+ problem that only a WSL or Podman update fixes - follow the issue; 'podman info --format {{.Host.CgroupControllers}}' must list pids before a re-run can work\n"
            else
                printf "delegate it to your user ('[Service]' and 'Delegate=cpu cpuset io memory pids' in /etc/systemd/system/user@.service.d/delegate.conf, 'sudo systemctl daemon-reload', log in again), then re-run the installer\n"
            fi
            return 0
            ;;
        *"Temporary failure in name resolution"*|*"lookup registry"*)
            printf 'this machine cannot resolve registry-1.docker.io, so the database image cannot be downloaded|'
            if [ "$_pkc_os" = "wsl" ]; then
                printf "on the WINDOWS side add 'dnsTunneling=true' under [wsl2] in %%USERPROFILE%%\\\\.wslconfig, run 'wsl --shutdown', then re-run the installer\n"
            else
                printf "fix this machine's DNS ('getent hosts registry-1.docker.io' must answer), then re-run the installer\n"
            fi
            return 0
            ;;
    esac
    return 1
}

# personal_explain_failure [launcher-output-file] — after a deploy or start
# that failed: the container's own error when it has one, and the cause and
# the fix when the kit recognises it there or in what the launcher said. The
# cause is left in PERSONAL_FAILURE_CAUSE (": ..." form, empty when nothing
# more is known) for the caller's failure note. Twin of
# Show-PersonalFailureCause.
personal_explain_failure() {
    PERSONAL_FAILURE_CAUSE=""
    _pef_err="${PERSONAL_CONTAINER_ERROR:-}"
    if [ -z "$_pef_err" ]; then
        _pef_err="$(personal_container_error 2>/dev/null || true)"
        [ -n "$_pef_err" ] && warn "The database container could not start: $(_personal_short "$_pef_err")"
    fi
    [ -n "$_pef_err" ] && PERSONAL_FAILURE_CAUSE=": the database container could not start ($(_personal_short "$_pef_err"))"
    _pef_text="$_pef_err"
    if [ -n "${1:-}" ] && [ -s "$1" ]; then
        _pef_text="$_pef_text
$(cat "$1")"
    fi
    _pef_known="$(personal_known_cause "$_pef_text")" || return 0
    warn "${_pef_known%%|*}."
    # info_step, not info: this can be printed inside the deploy's quiet
    # bracket, and a fix nobody sees is no fix.
    if command -v info_step >/dev/null 2>&1; then info_step "Fix: ${_pef_known#*|}"; else info "Fix: ${_pef_known#*|}"; fi
    [ -n "$PERSONAL_FAILURE_CAUSE" ] || PERSONAL_FAILURE_CAUSE=": ${_pef_known%%|*}"
    return 0
}

# _personal_container_refused — has the database container failed for good?
# Asked from inside every wait, so a terminal error ends the wait at once
# instead of spending the rest of its budget. Kept in PERSONAL_CONTAINER_ERROR
# for the failure reason, said once. Twin of Test-PersonalContainerRefused.
_personal_container_refused() {
    _pcr_err="$(personal_container_error 2>/dev/null || true)"
    [ -n "$_pcr_err" ] || return 1
    PERSONAL_CONTAINER_ERROR="$_pcr_err"
    # The wait's spinner owns its line: paused for the warning, not ended -
    # ending it is the wait's own job.
    command -v ui_spin_pause >/dev/null 2>&1 && ui_spin_pause
    warn "The database container could not start: $(_personal_short "$_pcr_err")"
    command -v ui_spin_resume >/dev/null 2>&1 && ui_spin_resume
    return 0
}

# personal_first_boot_pending / personal_set_first_boot_pending 1|0 — did the
# KIT create this deployment and never see its database answer? Recorded right
# before the kit's own `install local` and cleared the first time the database
# answers, so a deployment the kit did not make - or one that has EVER
# answered, and so may hold data - never reads as pending. The never-booted
# branch of personal_deploy_local rests on it. Twin of
# Test-PersonalFirstBootPending.
personal_first_boot_pending() {
    case "$(manifest_get runtime.first_boot_pending 2>/dev/null || true)" in
        true|True|1) return 0 ;;
    esac
    return 1
}

personal_set_first_boot_pending() {
    [ -f "${EXAKIT_MANIFEST:-}" ] || return 0
    if [ "$1" = 1 ]; then
        ( manifest_set runtime.first_boot_pending true ) >/dev/null 2>&1 || true
    elif [ -n "$(manifest_get runtime.first_boot_pending 2>/dev/null || true)" ]; then
        ( manifest_del runtime.first_boot_pending ) >/dev/null 2>&1 || true
    fi
    return 0
}

# personal_engine_existing [quiet] - the engine an EXISTING deployment runs on.
# The record's word when it has one. A deployment the kit never recorded (made
# by hand with `exasol install local`, whose own `auto` lands on Docker on a
# Docker-only box) is asked of Docker: when Docker lists a container carrying
# the deployment's id it is Docker, otherwise Podman, as every deployment from
# before kit 0.2.4 is. Defaulting to Podman blindly installed Podman for a
# Docker deployment and recorded it as Podman.
#
# THE DEPLOYMENT'S OWN RECORD FIRST, over the kit's (_personal_engine_own): the
# launcher wrote it when it first prepared the deployment, and keeps to it. The
# kit's record can be another database's (the one before a picked one), or an
# older kit's guess. A record that cannot be read is "", as the launcher itself
# refuses it.
#
# THE LAUNCHER'S OWN STATE NEXT: an engine its state files name is the
# answer, Docker running or not. Only without one is a container list asked.
#
# A REBUILD NEVER GUESSES (EXAKIT_REUSE_DB=0, exakit repair-runtime): where
# every other run takes Podman with nothing to say so, the rebuild of a
# database of the user's answers "" and nothing is destroyed. The kit's own
# record is the kit's word for a database the kit made, not for one it picked.
#
# MADE BEFORE EXASOL PERSONAL 2.4, IT IS PODMAN, PERIOD: no launcher before
# 2.4 could deploy on Docker. The deployment's own version decides first (its
# state files, else the record's runtime.deployment_version), and a version
# that cannot be read with no engine in the launcher's state is Podman too -
# every deployment from before kit 0.2.4. Guessing Docker there recorded a
# Podman database as Docker for good, and let a replace skip the WSL check.
#
# ONLY A 2.4+ DEPLOYMENT CAN BE DOCKER, AND ONLY ON EVIDENCE: an engine its
# state files name, or Docker listing its containers. A STOPPED DOCKER IS NOT
# AN ANSWER: Docker down (or refusing this user) cannot list anything. Then
# Podman is asked; if it does not list the deployment either, the engine is
# UNKNOWN: "" is the answer, and the deploy step stops before any start,
# replace or record (_personal_engine_unknown_stop).
#
# The answer is printed and kept in _PERSONAL_EXISTING.
personal_engine_existing() {
    _PERSONAL_EXISTING="$(_personal_engine_own)"
    case "$_PERSONAL_EXISTING" in
        docker|podman) printf '%s' "$_PERSONAL_EXISTING"; return 0 ;;
        unread) _PERSONAL_EXISTING=""; return 0 ;;
    esac
    # With nothing that names it: Podman, or "" in the rebuild of a database of
    # the user's.
    _pee_none=podman
    if _personal_rebuild_of_users; then _pee_none=""
    else _PERSONAL_EXISTING="$(manifest_get runtime.engine 2>/dev/null || true)"; fi
    [ -n "$(manifest_get runtime.container 2>/dev/null || true)" ] && _PERSONAL_EXISTING=""
    case "$_PERSONAL_EXISTING" in
        docker|podman) printf '%s' "$_PERSONAL_EXISTING"; return 0 ;;
    esac
    _pee_ver="$(personal_deployed_version 2>/dev/null || true)"
    if [ -z "$_pee_ver" ]; then
        _pee_ver="$(manifest_get runtime.deployment_version 2>/dev/null || true)"
        case "$_pee_ver" in [0-9]*) : ;; *) _pee_ver="" ;; esac
    fi
    _PERSONAL_EXISTING="podman"
    if [ -n "$_pee_ver" ] && ! _personal_update_crosses_to_24 "$_pee_ver"; then
        printf 'podman'
        return 0
    fi
    _pee_state="$(_personal_deployment_engine)"
    case "$_pee_state" in
        docker|podman) _PERSONAL_EXISTING="$_pee_state"; printf '%s' "$_PERSONAL_EXISTING"; return 0 ;;
    esac
    _PERSONAL_EXISTING="$_pee_none"
    if [ -z "$_pee_ver" ]; then
        printf '%s' "$_pee_none"
        return 0
    fi
    _pee_id="$(_personal_deployment_id)"
    if [ -z "$_pee_id" ]; then
        printf '%s' "$_pee_none"
        return 0
    fi
    # The rebuild of a database of the user's asks Podman too: not listed by
    # Docker alone does not make it Podman.
    if [ -z "$_pee_none" ] && command -v podman >/dev/null 2>&1 && \
       exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-15}" podman ps -a --format '{{.Names}}' 2>/dev/null \
            | _personal_names_carry_id "$_pee_id"; then
        _PERSONAL_EXISTING="podman"
        printf 'podman'
        return 0
    fi
    if personal_docker_usable; then
        if exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-15}" docker ps -a --format '{{.Names}}' 2>/dev/null \
                | _personal_names_carry_id "$_pee_id"; then
            # stderr: callers read the engine from stdout.
            [ "${1:-}" = quiet ] || info "Adopting the existing deployment: Docker lists its containers, so it is recorded as running on Docker." >&2
            _PERSONAL_EXISTING="docker"
        fi
    elif [ "$_pdu_kind" = down ] || [ "$_pdu_kind" = denied ]; then
        if command -v podman >/dev/null 2>&1 && \
           exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-15}" podman ps -a --format '{{.Names}}' 2>/dev/null \
                | _personal_names_carry_id "$_pee_id"; then
            _PERSONAL_EXISTING="podman"
        else
            _PERSONAL_EXISTING=""
        fi
    fi
    printf '%s' "$_PERSONAL_EXISTING"
}

# _personal_engine_unknown_stop - the end of the database step for an existing
# 2.4+ deployment whose engine nothing could name (personal_engine_existing
# answered ""). Nothing is started, replaced or recorded: a guess here either
# records the wrong engine for good or destroys a database the rebuild cannot
# follow. Twin of Stop-PersonalEngineUnknown.
_personal_engine_unknown_stop() {
    warn "The existing deployment's engine cannot be read: it was made by Exasol Personal 2.4 or newer, its state does not name the engine, ${_pdu_said:-Docker did not answer}, and Podman does not list it."
    # THE REMEDY FOLLOWS THE REASON. "Start Docker" to a user whose Docker is
    # running but refuses them sends them to start what is already up.
    if [ "${_pdu_kind:-}" = denied ]; then
        info "If the deployment is on Docker, give your user access to it (the docker group; log out and back in), or check that 'podman ps -a' lists it, then re-run: $(exakit_install_command)"
    else
        info "Start Docker (if the deployment is on Docker), or check that 'podman ps -a' lists it, then re-run: $(exakit_install_command)"
    fi
    info "Nothing was changed."
    exakit_note_failure "The existing deployment's engine could not be read (Docker did not answer and Podman does not list it)"
    return 1
}

# _personal_engine_own - the engine the deployment itself says, by the launcher's
# own rule (2.4 and later): local/runtime/container-engine.json, written when it
# was first prepared; database data (local/runtime/exa) without one was made
# before engines were recorded, on Podman. "unread" for a record that names
# neither engine (the launcher refuses it too); nothing when neither is there,
# and on macOS, whose launcher has no engine to record.
# Twin of Get-PersonalEngineOwn.
_personal_engine_own() {
    personal_engine_platform || return 0
    personal_deploy_dir_refresh
    _peo_dir="${EXAKIT_PERSONAL_DEPLOY_DIR:-}/local/runtime"
    if [ -e "$_peo_dir/container-engine.json" ]; then
        _peo="$(tr -d '\012\015' < "$_peo_dir/container-engine.json" 2>/dev/null | \
            grep -oE '"engine"[[:space:]]*:[[:space:]]*"(docker|podman)"' | head -1 | sed -E 's/.*"(docker|podman)"$/\1/')"
        printf '%s' "${_peo:-unread}"
    elif [ -d "$_peo_dir/exa" ]; then
        printf 'podman'
    fi
    return 0
}

# _personal_deployment_engine - "docker" or "podman" when the launcher's state
# files name the deployment's engine; empty when none does.
_personal_deployment_engine() {
    personal_deploy_dir_refresh
    for _pde_f in "$EXAKIT_PERSONAL_DEPLOY_DIR/deployment.json" "$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json"; do
        [ -f "$_pde_f" ] || continue
        _pde="$(tr -d '\012\015' < "$_pde_f" 2>/dev/null | \
            grep -oE '"(containerEngine|container_engine|engine)"[[:space:]]*:[[:space:]]*"(docker|podman)"' | head -1 | \
            sed -E 's/.*"(docker|podman)"$/\1/')"
        [ -n "$_pde" ] && { printf '%s' "$_pde"; return 0; }
    done
    return 0
}

# _personal_names_carry_id <id> - 0 when a container name on stdin IS the
# deployment's id, or carries it as a whole leading or trailing segment
# (<id>-db-1, exasol_<id>). NOT A SUBSTRING: an id "exa" matched
# "exasol-nano" and "my-hexagon-app", and an unrelated container made a
# Podman deployment be recorded as Docker.
_personal_names_carry_id() {
    awk -v id="$1" '
        { n = $0; sub(/\r$/, "", n); li = length(id); ln = length(n) }
        n == id { f = 1 }
        ln > li && (substr(n, 1, li + 1) == id "-" || substr(n, 1, li + 1) == id "_") { f = 1 }
        ln > li && (substr(n, ln - li) == "-" id || substr(n, ln - li) == "_" id) { f = 1 }
        END { exit f ? 0 : 1 }'
}

# personal_engine_recorded - the engine the deployment runs on: what it says
# itself (_personal_engine_own), else the kit's record; "podman" when neither
# has one, which is every deployment made before kit 0.2.4. A record still
# carrying the nano kit's container names the OLD database's engine, not this
# deployment's, and is ignored.
personal_engine_recorded() {
    _per="$(_personal_engine_own)"
    case "$_per" in docker|podman) printf '%s' "$_per"; return 0 ;; esac
    _per="$(manifest_get runtime.engine 2>/dev/null || true)"
    [ -n "$(manifest_get runtime.container 2>/dev/null || true)" ] && _per=""
    case "$_per" in
        docker|podman) printf '%s' "$_per" ;;
        *) printf 'podman' ;;
    esac
}

# personal_engine_flag <engine> - "--container-engine <engine>" when this
# launcher's `install` takes it, nothing otherwise. Same shape, and the same
# reason, as personal_auto_approve_flag: a 2.3 launcher handed an unknown
# flag fails outright, and 2.3 deployments are still supported.
personal_engine_flag() {
    [ -n "${1:-}" ] || return 0
    # Never off an engine platform: macOS has no engine to name, and a record
    # that reads "podman" there describes nothing the launcher should be told.
    personal_engine_platform || return 0
    # The launcher's answer is personal_launcher_takes_engine's, kept per
    # launcher; one that is not there yet takes no flag.
    [ -x "$(personal_cli)" ] || return 0
    if personal_launcher_takes_engine; then
        printf -- '--container-engine %s' "$1"
    fi
    return 0
}

# personal_engine_running <engine> - the engine can run a container right now.
# Podman's answer is personal_podman_running, unchanged; Docker's is the probe
# above, with the failure said the same way.
personal_engine_running() {
    case "${1:-}" in
        docker)
            personal_docker_usable && return 0
            warn "The deployment runs on Docker, and $_pdu_said."
            info "Start Docker, then re-run: $(exakit_install_command)"
            exakit_note_failure "Docker is not usable: $_pdu_said"
            return 1 ;;
        *) personal_podman_running ;;
    esac
}

# personal_wsl_podman_network_ok [--replace] <re-run command> - Podman on this
# WSL kernel can build the network a 2.4 deployment needs. 0 anywhere but WSL.
#
# Exasol Personal 2.4 puts every local deployment on its own bridge network,
# and Podman builds that network through netavark with the nftables firewall
# driver. The kernel WSL 2.6 and older ship has no nftables, so the deploy -
# or, for a deployment made by 2.3, the first start after the launcher update
# - fails with:
#   Error: netavark: nftables error: "nft" did not return successfully while applying ruleset
# For a FRESH Podman deployment that is found here, before anything is
# downloaded, and before a replace destroys anything; the launcher update is
# not gated (it changes no data), and the start after it names the fix from
# that error (_personal_start_network_blocked). The fix named: `wsl --update`
# from Windows, or Podman's iptables firewall driver (with iptables installed)
# for a machine that cannot update WSL. Only a release READ below 2.7 refuses: a
# wsl.exe that is missing, cannot run (interop off), fails, times out or
# answers no release is warned about and let through - a guess must never be
# the thing that blocks a working install. Docker is not affected and never
# asks.
#
# --replace IS THE DESTRUCTIVE PATH, AND THERE UNKNOWN REFUSES. Replacing a
# deployment destroys it before its fresh deploy runs, and on a WSL that is in
# fact 2.6 that deploy fails after the data is gone. A guess let through costs
# a failed install on the install path; here it costs the database. Whoever
# has read 'wsl --version' themselves says so with EXAKIT_WSL_CHECKED=1.
personal_wsl_podman_network_ok() {
    _pwn_replace=0
    if [ "${1:-}" = "--replace" ]; then _pwn_replace=1; shift; fi
    [ "$(detect_os)" = "wsl" ] || return 0
    detect_podman_iptables_driver && return 0
    # A PODMAN THAT IS NOT ON NETAVARK CANNOT HIT THIS. The error is netavark's
    # nftables driver. Asked only when Podman is already here and answers; no
    # answer keeps the gate (detect_podman_backend_not_netavark).
    detect_podman_backend_not_netavark && return 0
    _pwn_rel="$(detect_wsl_release)" || _pwn_rel=""
    _pwn_major="${_pwn_rel%%.*}"
    _pwn_minor="${_pwn_rel#*.}"
    _pwn_minor="${_pwn_minor%%.*}"
    case "${_pwn_major}${_pwn_minor}" in ''|*[!0-9]*) _pwn_rel="" ;; esac
    if [ -z "$_pwn_rel" ]; then
        if [ "$_pwn_replace" = 1 ] && [ "${EXAKIT_WSL_CHECKED:-0}" != 1 ]; then
            warn "Could not read the WSL release from this distro (wsl.exe is missing, did not run, or answered no version), so replacing this Podman deployment is refused: its fresh deploy needs WSL 2.7 or newer, and on an older WSL it fails after the data is gone."
            info "Nothing was deleted: the deployment and its data stay. Replacing it needs WSL 2.7 or newer, and the release could not be read. In PowerShell on Windows run 'wsl --version'; if it shows 2.7 or newer, re-run with EXAKIT_WSL_CHECKED=1 set."
            exakit_note_failure "The WSL release could not be read, so replacing the Podman deployment was refused ('wsl --version' must show 2.7 or newer)"
            return 1
        fi
        [ "$_pwn_replace" = 1 ] && return 0
        warn "Could not read the WSL release from this distro (wsl.exe is missing, did not run, or answered no version), so it is unknown. Exasol Personal 2.4 on Podman needs WSL 2.7 or newer - check with 'wsl --version' in PowerShell."
        return 0
    fi
    if [ "$_pwn_major" -gt 2 ] || { [ "$_pwn_major" -eq 2 ] && [ "$_pwn_minor" -ge 7 ]; }; then
        return 0
    fi
    warn "Podman on WSL ${_pwn_rel} cannot create the network Exasol Personal 2.4 needs: this WSL kernel has no nftables, so Podman fails with 'nft did not return successfully while applying ruleset'."
    exakit_note_failure "WSL ${_pwn_rel} is older than 2.7, so Podman cannot create the deployment network (run: wsl --update)"
    if [ "$_pwn_replace" = 1 ]; then
        # ONE NEXT STEP: the deployment is intact, so after the update it
        # starts as it is - nothing needs replacing.
        info "Nothing was deleted: the deployment and its data stay. In PowerShell run 'wsl --update' then 'wsl --shutdown', reopen this distro, then: ${1:-exakit start}"
        [ "$(detect_podman_firewall_driver)" = "iptables" ] && \
            info "Podman is set to the iptables firewall driver, but iptables is not installed in this distro, so that setting cannot be used yet: install it (e.g. 'sudo apt-get install -y iptables')."
        return 1
    fi
    info "In PowerShell on Windows run:  wsl --update   then:  wsl --shutdown   - reopen this distro and re-run: ${1:-$(exakit_install_command)}"
    if [ "$(detect_podman_firewall_driver)" = "iptables" ]; then
        # The setting is there and the binary is not: say the missing half.
        info "Podman is set to the iptables firewall driver, but iptables is not installed in this distro: install it (e.g. 'sudo apt-get install -y iptables'), then re-run."
    else
        info "Without updating WSL: set  firewall_driver = \"iptables\"  under [network] in ~/.config/containers/containers.conf (the iptables package must be installed), then re-run."
    fi
    info "Nothing was changed."
    return 1
}

# _personal_update_crosses_to_24 <version> - true when a launcher update to
# <version> is the one that brings the 2.4 deployment network (and, on an
# engine platform, the first launcher that could be on Docker).
_personal_update_crosses_to_24() {
    case "${1:-}" in
        0.*|1.*|2.[0-3]|2.[0-3].*) return 1 ;;
        *) return 0 ;;
    esac
}

# personal_deploy_local — run the local deployment. This is the long step
# (usually under 2 minutes); output stays visible and is logged.
# --- the database port of a new starter-kit-local (D3) ----------------------
# The launcher binds one host port per local deployment, the database's, and
# saves it in the deployment (infrastructure/infrastructure.yaml `ports:
# db:<n>`, deployment.json dbPort). Its own `auto` skips only ports in use now,
# never the saved port of a stopped deployment, and a launcher in another home
# sees none of its deployments. So the kit picks the port of its own new
# database itself and passes it to `install local --ports db:<n>`.

# personal_saved_db_port <dir> — the database port the deployment in <dir> has
# saved, or nothing: its infrastructure.yaml first (what the launcher binds),
# else its deployment.json. No Python.
personal_saved_db_port() {
    _psdp=""
    if [ -f "$1/infrastructure/infrastructure.yaml" ]; then
        _psdp="$(grep -E '^[[:space:]]*ports:' "$1/infrastructure/infrastructure.yaml" 2>/dev/null | \
            sed -n 's/.*db:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
    fi
    if [ -z "$_psdp" ] && [ -f "$1/deployment.json" ]; then
        _psdp="$(tr -d '\012\015' < "$1/deployment.json" 2>/dev/null | \
            sed -n 's/.*"dbPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    fi
    printf '%s' "$_psdp"
}

# personal_saved_port_deployments — every deployment folder the kit can see other
# than its own, one per line: in the launcher root the kit uses, in the user's
# own two roots in the real home, and wherever the launcher lists one. Their
# saved ports are taken: the database port (personal_pick_port) and the MCP
# server's (_mcp_sidecar_saved_ports).
personal_saved_port_deployments() {
    _pod_seen=""
    while IFS= read -r _pod_root; do
        [ -n "$_pod_root" ] && [ -d "$_pod_root" ] || continue
        case "$_pod_seen
" in *"
$_pod_root
"*) continue ;; esac
        _pod_seen="$_pod_seen
$_pod_root"
        for _pod_dep in "$_pod_root"/*; do
            [ -d "$_pod_dep" ] && [ "$_pod_dep" != "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || continue
            printf '%s\n' "$_pod_dep"
        done
    done <<EXAKIT_POD_ROOTS
$(dirname "${EXAKIT_PERSONAL_DEPLOY_DIR:-/nonexistent/x}")
${DETECT_PERSONAL_DEPLOY_ROOT_NEW:-}
${DETECT_PERSONAL_DEPLOY_ROOT_LEGACY:-}
${DETECT_PERSONAL_USER_ROOT_NEW:-}
${DETECT_PERSONAL_USER_ROOT_LEGACY:-}
$(_personal_listed_roots 2>/dev/null)
EXAKIT_POD_ROOTS
}

# personal_pick_port — the database port for a NEW starter-kit-local, in
# PERSONAL_PICKED_PORT: 8563 when it is free, else the first free one of
# 8564..8663. Taken: the port every other deployment the kit can see has saved
# (in the launcher root the kit uses, and in the user's own two roots in the
# real home, and wherever the launcher lists one), and every port something
# listens on now. Non-zero, PERSONAL_PICKED_PORT empty, when none is free.
EXAKIT_PERSONAL_PORT_LAST="${EXAKIT_PERSONAL_PORT_LAST:-8663}"
personal_pick_port() {
    PERSONAL_PICKED_PORT=""
    personal_deploy_dir_refresh
    _ppp_taken=" "
    while IFS= read -r _ppp_dep; do
        [ -n "$_ppp_dep" ] || continue
        _ppp_port="$(personal_saved_db_port "$_ppp_dep")"
        [ -z "$_ppp_port" ] || _ppp_taken="$_ppp_taken$_ppp_port "
    done <<EXAKIT_PPP_DEPS
$(personal_saved_port_deployments)
EXAKIT_PPP_DEPS
    _ppp_try="$EXAKIT_PERSONAL_PORT"
    while [ "$_ppp_try" -le "$EXAKIT_PERSONAL_PORT_LAST" ]; do
        case "$_ppp_taken" in
            *" $_ppp_try "*) ;;
            *)  if ! port_in_use "$_ppp_try"; then
                    PERSONAL_PICKED_PORT="$_ppp_try"
                    return 0
                fi ;;
        esac
        _ppp_try=$((_ppp_try + 1))
    done
    return 1
}

# personal_ports_flag — "--ports db:<n>" for `install local`, with the port
# personal_pick_port chose, when the launcher takes it (`install local --help`
# names --ports, a variable of the local preset); nothing otherwise.
personal_ports_flag() {
    [ -n "${PERSONAL_PICKED_PORT:-}" ] || return 0
    [ -x "$(personal_cli)" ] || return 0
    if exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" install local --help 2>&1 \
            | personal_help_names_token "--ports"; then
        printf -- '--ports db:%s' "$PERSONAL_PICKED_PORT"
    fi
    return 0
}

# --- renaming a deployment to starter-kit-local ------------------------------
# The launcher has no rename command: a deployment's name is its folder's name,
# and nothing inside the folder names it (its containers and VM are keyed by
# its id). A STOPPED, unlocked folder renamed in the same root keeps its data
# and starts under the new name. These helpers are shared by the installer's
# one question (personal_reuse_rename) and the 0.3.0 update.

# _personal_forget_followed — the refresh's per-process memory of where the
# deployment was, dropped, so the next refresh reads the record anew.
_personal_forget_followed() {
    unset _EXAKIT_PERSONAL_LIST_ASKED _EXAKIT_PERSONAL_LIST_DECIDED _EXAKIT_PERSONAL_DEPLOY_REC \
        _EXAKIT_PERSONAL_DEPLOY_AT _EXAKIT_PERSONAL_DEPLOY_LOST _EXAKIT_PERSONAL_DEPLOY_FOLLOWED
    DETECT_PERSONAL_LAUNCHER_LISTED=0
    DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS=""
    PERSONAL_LAUNCHER_ROWS=""
}

# personal_point_record_at <dir> — the kit's database is the one in <dir> from
# now on: runtime.deployment_dir and runtime.deployment_name (its folder's
# name) recorded, EXAKIT_PERSONAL_DEPLOY_DIR set, the refresh's memory
# dropped. Ownership is the caller's (exakit_record_ownership). Non-zero when
# the manifest cannot be written.
personal_point_record_at() {
    manifest_set runtime.deployment_dir "$1" || return 1
    manifest_set runtime.deployment_name "$(basename "$1")" || return 1
    # Another folder: the rebuild noted for the one before is not this one's.
    [ "$(manifest_get runtime.rebuild_path 2>/dev/null || true)" = "$1" ] || _personal_rebuild_settled
    EXAKIT_PERSONAL_DEPLOY_DIR="$1"
    _personal_forget_followed
    return 0
}

# personal_rename_records <from> <to> — the kit's records follow a rename of
# its deployment folder, all in one step: runtime.deployment_dir and the
# ownership receipt runtime.ownership_path, each where it names <from> (the
# owner stays as recorded), runtime.deployment_name (the new folder's name),
# and EXAKIT_PERSONAL_DEPLOY_DIR when it named <from>. Called again with the
# two swapped, it puts them back. Non-zero when the manifest cannot be written.
personal_rename_records() {
    for _prrc_key in runtime.deployment_dir runtime.ownership_path; do
        [ "$(manifest_get "$_prrc_key" 2>/dev/null || true)" = "$1" ] || continue
        manifest_set "$_prrc_key" "$2" || return 1
    done
    if [ "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" = "$2" ]; then
        manifest_set runtime.deployment_name "$(basename "$2")" || return 1
    fi
    [ "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" != "$1" ] || EXAKIT_PERSONAL_DEPLOY_DIR="$2"
    _personal_forget_followed
    return 0
}

# personal_rename_deployment <from> <to> — rename the deployment folder <from>
# to <to> (the same root: <to> is <root>/starter-kit-local, or back), and make
# the kit's records follow (personal_rename_records). The deployment must be
# STOPPED: the caller stops it first, with the launcher that runs it. Refused,
# with nothing changed, when <from> is not a folder, <to> already exists, the
# launcher holds a lock on <from> (a .dirmutex.* marker: a command of its is
# running, or a stale one is left, `exasol diag unlock`), or the rename fails
# (in use, no permission, another filesystem). The reason is in
# PERSONAL_RENAME_ERROR: missing, exists, locked, failed or records. A record
# that cannot be written puts the folder back. Prints nothing: the caller says
# what happened. Call it with the two swapped to undo.
personal_rename_deployment() {
    PERSONAL_RENAME_ERROR=""
    [ -d "$1" ] || { PERSONAL_RENAME_ERROR=missing; return 1; }
    [ ! -e "$2" ] && [ ! -L "$2" ] || { PERSONAL_RENAME_ERROR=exists; return 1; }
    for _prd_lock in "$1"/.dirmutex.*; do
        [ -e "$_prd_lock" ] || continue
        PERSONAL_RENAME_ERROR=locked
        return 1
    done
    if ! mv "$1" "$2" 2>/dev/null; then
        PERSONAL_RENAME_ERROR=failed
        return 1
    fi
    command -v _exakit_log_file >/dev/null 2>&1 && _exakit_log_file "INFO  renamed the deployment folder $1 to $2"
    [ -f "${EXAKIT_MANIFEST:-}" ] || { _personal_forget_followed; return 0; }
    # THE RECORDS IN A SUBSHELL: manifest_set ends the run (die) when it
    # cannot write (a full disk, a kit home that is not writable), and that
    # left a stopped database under its new name with the records naming the
    # old one. In a subshell the failure is this step's: the folder and the
    # records are put back, and the caller starts the database again when it
    # ran. Then this shell takes the new folder too.
    if ! ( personal_rename_records "$1" "$2" ) >/dev/null 2>&1; then
        mv "$2" "$1" 2>/dev/null || true
        ( personal_rename_records "$2" "$1" ) >/dev/null 2>&1 || true
        PERSONAL_RENAME_ERROR=records
        return 1
    fi
    [ "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" != "$1" ] || EXAKIT_PERSONAL_DEPLOY_DIR="$2"
    _personal_forget_followed
    return 0
}

# personal_session_limit_remove <exasol.conf> [<launcher version>] — the
# 20-session limit line a launcher before 2.5.0 left
# (maxConnectionsLicenseLimit in [DB_PARAMS])
# removed from a STOPPED database's exasol.conf, every other byte kept, a
# backup beside it (<conf>.before-session-limit), runtime.session_limit
# recorded as lifted. Its next start applies it. Nothing to do (no line, or a
# launcher before 2.5.0) is 0. Non-zero when the file could not be changed:
# it is then as it was. The edit personal_lift_session_limit makes, for a
# caller that has already stopped the database (the one question's rename,
# the 0.3.0 update), so the database restarts once, not twice.
# <launcher version>, when the caller knows it, spares the `version` call.
# Without it, that call under launcher 2.5.0 can move the stopped folder out
# of the legacy root (~/.exasol/personal): the file is then read where it is
# now, the kit's database followed by its id (personal_session_limit_conf).
personal_session_limit_remove() {
    personal_session_limit_set "$1" || return 0
    _pslrm_ver="${2:-}"
    [ -n "$_pslrm_ver" ] || _pslrm_ver="$(personal_launcher_version 2>/dev/null || true)"
    [ -n "$_pslrm_ver" ] || return 0
    personal_deployment_outranks 2.5.0 "$_pslrm_ver" && return 0
    _pslrm_conf="$1"
    if [ ! -f "$_pslrm_conf" ]; then
        _personal_forget_followed
        _pslrm_conf="$(personal_session_limit_conf)"
        personal_session_limit_set "$_pslrm_conf" || return 1
    fi
    set -- "$_pslrm_conf"
    _pslrm_bak="$1.before-session-limit"
    cp -p "$1" "$_pslrm_bak" 2>/dev/null || return 1
    if ! run_python - "$1" <<'PY' >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
import os, re, shutil, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    data = handle.read()
kept = re.sub(rb"(?m)^[ \t]*maxConnectionsLicenseLimit[ \t]*=[^\r\n]*(?:\r\n|\n|\r)?", b"", data)
if kept == data:
    sys.exit(3)
temp = path + ".exakit-tmp"
with open(temp, "wb") as handle:
    handle.write(kept)
shutil.copymode(path, temp)
os.replace(temp, path)
PY
        rm -f "$1.exakit-tmp"
        cp -p "$_pslrm_bak" "$1" 2>/dev/null || true
        return 1
    fi
    manifest_set runtime.session_limit lifted 2>/dev/null || true
    manifest_set runtime.session_limit_lifted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
    return 0
}

# --- the one question: which database the starter kit uses ------------------
# Asked only on a first install (no kit record, or the kit's own database not
# found: exakit_personal_db_state), in modes K and U, when the launcher lists
# one or more databases of the user's the kit can use. Never in mode P: that
# launcher cannot see the user's (D2).

# _personal_status_of <dir> — the launcher's status of the deployment in <dir>
# (`status --json`, with the launcher's own 30 s), or nothing.
_personal_status_of() {
    _pso_out="$(exakit_run_bounded 40 "$(personal_cli)" status --json --timeout 30 --deployment-dir "$1" 2>/dev/null || true)"
    printf '%s' "$_pso_out" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# _personal_word_of <dir> [<launcher>] — that launcher's own word (the one the
# kit runs, when none is named) for the deployment in <dir>, asked now. Nothing
# when it cannot say.
_personal_word_of() {
    _pwo_cli="${2:-$(personal_cli)}"
    [ -n "$_pwo_cli" ] && [ -x "$_pwo_cli" ] && [ -d "$1" ] || return 0
    _pwo="$(exakit_run_bounded 40 "$_pwo_cli" status --json --deployment-dir "$1" 2>/dev/null || true)"
    printf '%s' "$_pwo" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# _personal_says_stopped <dir> [<launcher>] — 0 only when it says stopped (or
# never deployed): THE ONE ANSWER a folder may be renamed or moved on. No
# answer, an error, a launcher that is not there and every other word are not
# that answer. _personal_says_running: 0 when it says the database runs.
_personal_says_stopped() {
    case "$(_personal_word_of "$@")" in stopped|initialized) return 0 ;; esac
    return 1
}
_personal_says_running() {
    case "$(_personal_word_of "$@")" in database_ready|running|database_connection_failed) return 0 ;; esac
    return 1
}

# personal_reuse_candidates — the user's databases the one question offers,
# one per line, sorted by name: "<name><TAB><running|stopped><TAB><folder>".
# From the launcher's list (personal_launcher_deployments): a local deployment
# (infrastructure "local") that finished deploying, its state shown as
# "running" (database_ready, running, database_connection_failed) or
# "stopped". Never starter-kit-local itself, never a cloud deployment, never
# one that never finished deploying (initialized, deployment_failed,
# interrupted, operation_in_progress). One the list calls not_initialized
# (its 5 s status probe ran out) is asked again, with 30 s, before it is left
# out. Nothing when the launcher lists nothing or cannot answer.
personal_reuse_candidates() {
    personal_launcher_deployments >/dev/null 2>&1 || return 0
    _prc_t='	'
    _prc_out=""
    while IFS= read -r _prc_row; do
        [ -n "$_prc_row" ] || continue
        _prc_name="${_prc_row%%"$_prc_t"*}"; _prc_rest="${_prc_row#*"$_prc_t"}"
        _prc_infra="${_prc_rest%%"$_prc_t"*}"; _prc_rest="${_prc_rest#*"$_prc_t"}"
        _prc_status="${_prc_rest%%"$_prc_t"*}"; _prc_path="${_prc_rest#*"$_prc_t"}"
        [ "$_prc_name" != "$EXAKIT_PERSONAL_DEPLOYMENT" ] && [ -d "$_prc_path" ] || continue
        if [ "$_prc_status" = not_initialized ]; then
            _prc_status="$(_personal_status_of "$_prc_path")"
        fi
        # The preset: the list's, else (a row the list could not read) the
        # deployment's own infrastructure.yaml.
        if [ -z "$_prc_infra" ] && grep -Eq '^backend:[[:space:]]*local[[:space:]]*$' "$_prc_path/infrastructure/infrastructure.yaml" 2>/dev/null; then
            _prc_infra=local
        fi
        [ "$_prc_infra" = local ] || continue
        case "$_prc_status" in
            database_ready|running|database_connection_failed) _prc_shown=running ;;
            stopped) _prc_shown=stopped ;;
            *) continue ;;
        esac
        _prc_out="$_prc_out$_prc_name$_prc_t$_prc_shown$_prc_t$_prc_path
"
    done <<EXAKIT_PRC_ROWS
${PERSONAL_LAUNCHER_ROWS:-}
EXAKIT_PRC_ROWS
    [ -n "$_prc_out" ] || return 0
    printf '%s' "$_prc_out" | LC_ALL=C sort -t "$_prc_t" -k1,1
}

# _personal_reuse_names <candidates> — their names, ", " between them.
_personal_reuse_names() {
    _prn_out=""
    while IFS= read -r _prn; do
        [ -n "$_prn" ] || continue
        _prn_out="$_prn_out${_prn_out:+, }${_prn%%	*}"
    done <<EXAKIT_PRN_ROWS
$1
EXAKIT_PRN_ROWS
    printf '%s' "$_prn_out"
}

# personal_reuse_answer <candidates> — which database the starter kit uses,
# printed: "new", or the name of one of <candidates> (personal_reuse_candidates).
# The answer is, in order: EXAKIT_REUSE_DB when set (with or without a
# terminal), else the terminal's, else a new database (D1). EXAKIT_REUSE_DB:
#   0, n, no, new      a new database
#   1, y, yes          (0.3.0 scripts) `default` when it is one of them, else
#                      the only one when there is exactly one
#   <name>             that one
# Anything else ends the run (reject, exit 2), naming the ones it can be.
# The question (approved wording) goes to the terminal; the answer to stdout.
personal_reuse_answer() {
    _pra_list="$1"
    _pra_n="$(printf '%s\n' "$_pra_list" | grep -c .)"
    _pra_names="$(_personal_reuse_names "$_pra_list")"
    _pra_t='	'
    _pra_val="${EXAKIT_REUSE_DB:-}"
    if [ -n "$_pra_val" ]; then
        case "$_pra_val" in
            0|n|N|no|NO|No|new) printf 'new\n'; return 0 ;;
            1|y|Y|yes|YES|Yes)
                case "
$_pra_list" in
                    *"
default$_pra_t"*) printf 'default\n'; return 0 ;;
                esac
                if [ "$_pra_n" = 1 ]; then
                    printf '%s\n' "${_pra_list%%"$_pra_t"*}"
                    return 0
                fi
                reject "EXAKIT_REUSE_DB=$_pra_val does not say which of your databases the kit should use. Set it to one of these names: $_pra_names. Or set it to 0 for a new database." ;;
            *)  case "
$_pra_list" in
                    *"
$_pra_val$_pra_t"*) printf '%s\n' "$_pra_val"; return 0 ;;
                esac
                reject "EXAKIT_REUSE_DB=$_pra_val is not a database the kit can use. Set it to one of these names: $_pra_names. Or set it to 0 for a new database." ;;
        esac
    fi
    _pra_tty="$(_exakit_prompt_tty)"
    if [ -z "$_pra_tty" ]; then
        printf 'new\n'
        return 0
    fi
    _pra_last=$((_pra_n + 1))
    command -v ui_line_release >/dev/null 2>&1 && ui_line_release /dev/stderr
    {
        printf '    %s?%s %s\n' "${UI_ASK:-}" "${UI_RESET:-}" "Which database should the starter kit use?"
        printf '      %s\n' "1) A new database '$EXAKIT_PERSONAL_DEPLOYMENT' (recommended)"
        _pra_i=1
        printf '%s\n' "$_pra_list" | while IFS= read -r _pra_row; do
            [ -n "$_pra_row" ] || continue
            _pra_i=$((_pra_i + 1))
            _pra_rest="${_pra_row#*"$_pra_t"}"
            printf '      %s\n' "$_pra_i) ${_pra_row%%"$_pra_t"*} (${_pra_rest%%"$_pra_t"*})"
        done
    } >&2
    _pra_tries=0
    while :; do
        printf '    %s ' "Choose 1-$_pra_last [1]:" >&2
        _pra_answer=""
        if [ "$_pra_tty" = "/dev/tty" ]; then
            read -r _pra_answer < /dev/tty || _pra_answer=""
        else
            read -r _pra_answer || _pra_answer=""
        fi
        _pra_answer="$(printf '%s' "$_pra_answer" | tr -d '[:space:]')"
        [ -n "$_pra_answer" ] || _pra_answer=1
        # AS A NUMBER: 01 is 1 and 02 is 2. Kept as typed, a leading zero made
        # `sed -n 0p` (01) and octal arithmetic (08, 09) of it, and the pick
        # came back empty: a rename of '' that failed. All zeros is 0, asked
        # again. A number too long to be a choice is asked again too.
        case "$_pra_answer" in
            *[!0-9]*) ;;
            *)  _pra_answer="${_pra_answer#"${_pra_answer%%[!0]*}"}"
                [ -n "$_pra_answer" ] || _pra_answer=0
                [ "${#_pra_answer}" -le 6 ] || _pra_answer=0 ;;
        esac
        case "$_pra_answer" in
            *[!0-9]*) ;;
            *)  if [ "$_pra_answer" -ge 1 ] && [ "$_pra_answer" -le "$_pra_last" ]; then
                    if [ "$_pra_answer" = 1 ]; then
                        printf 'new\n'
                    else
                        _pra_row="$(printf '%s\n' "$_pra_list" | sed -n "$((_pra_answer - 1))p")"
                        printf '%s\n' "${_pra_row%%"$_pra_t"*}"
                    fi
                    return 0
                fi ;;
        esac
        _pra_tries=$((_pra_tries + 1))
        if [ "$_pra_tries" -ge 5 ]; then
            printf 'new\n'
            return 0
        fi
        printf '      %s\n' "Answer with a number from 1 to $_pra_last." >&2
    done
}

# personal_reuse_rename <name> <folder> <running|stopped> [<launcher version>]
# — REN: the user's database <name>,
# picked in the one question, becomes the kit's: stopped if
# it runs (`stop`, by its folder; the launcher itself must then say stopped),
# its folder renamed in place to
# <same root>/starter-kit-local (personal_rename_deployment), the records
# pointed at it, recorded as the USER's (the kit never destroys it) with its
# id, and its 20-session limit lifted while it is stopped. The deploy step then
# starts it as the kit's own (it restarts once). On a failure nothing of
# theirs is changed: the folder is as it was, a database that ran is started
# again, the reason is said, and the step ends (non-zero). Their other
# databases are never touched. <launcher version> is the version the caller
# already asked: no launcher command runs between the rename and the limit's
# edit, so launcher 2.5 cannot move a renamed folder of its legacy root
# (~/.exasol/personal) away from under that edit.
personal_reuse_rename() {
    _prr_name="$1"; _prr_from="$2"; _prr_ver="${4:-}"
    _prr_to="$(dirname "$_prr_from")/$EXAKIT_PERSONAL_DEPLOYMENT"
    _prr_old_id="$(manifest_get runtime.deployment_id 2>/dev/null || true)"
    _prr_old_dir="$(manifest_get runtime.deployment_dir 2>/dev/null || true)"
    if [ -e "$_prr_to" ]; then
        warn "Your database '$_prr_name' was not renamed, because $(ui_tilde "$_prr_to") already exists. Nothing was changed."
        exakit_note_failure "Your database '$_prr_name' was not renamed, because $_prr_to already exists"
        return 1
    fi
    # A DATABASE NEWER THAN THE KIT'S LAUNCHER is refused by it (its own rule),
    # so it is not stopped and not renamed.
    _prr_dver="$(personal_deploy_dir_refresh() { :; }; EXAKIT_PERSONAL_DEPLOY_DIR="$_prr_from"; personal_deployed_version 2>/dev/null || true)"
    if [ -n "$_prr_dver" ] && [ -n "$_prr_ver" ] && personal_deployment_outranks "$_prr_dver" "$_prr_ver"; then
        _prr_why="The Exasol Personal deployment on this machine is version $_prr_dver, which is newer than the launcher version this kit advertises ($_prr_ver)."
        error "$_prr_why"
        exakit_note_failure "$_prr_why"
        return 1
    fi
    # THE LAUNCHER'S WORD, ASKED NOW, not the one listed before the question:
    # minutes can pass on it, and the database can have been started since.
    # Its folder is renamed only on "stopped", and one that runs is asked to
    # stop and must then say so (a stop that answered 0 is no proof). Any other
    # answer (none, an error, an operation in progress) touches nothing.
    _prr_ran=0
    _prr_fid="$(_personal_deployment_id_in "$_prr_from" 2>/dev/null || true)"
    _prr_word="$(_personal_status_of "$_prr_from")"
    case "$_prr_word" in
        database_ready|running|database_connection_failed)
            _prr_ran=1
            EXAKIT_ACTIVE_LABEL="Stopping your database '$_prr_name'"
            if run_logged "$(personal_cli)" stop --deployment-dir "$_prr_from"; then
                _prr_word="$(_personal_status_of "$_prr_from")"
            fi ;;
    esac
    # A launcher 2.5 moves a stopped folder of the legacy root by the command
    # that asks it: the folder is followed there, by its id, and asked there.
    if [ ! -d "$_prr_from" ] && [ -n "$_prr_fid" ]; then
        detect_personal_deploy_roots
        _prr_moved="$DETECT_PERSONAL_DEPLOY_ROOT_NEW/$(basename "$_prr_from")"
        if [ "$(_personal_deployment_id_in "$_prr_moved" 2>/dev/null || true)" = "$_prr_fid" ]; then
            _prr_from="$_prr_moved"
            _prr_to="$DETECT_PERSONAL_DEPLOY_ROOT_NEW/$EXAKIT_PERSONAL_DEPLOYMENT"
            _prr_word="$(_personal_status_of "$_prr_from")"
        fi
    fi
    if [ "$_prr_word" != stopped ]; then
        warn "Your database '$_prr_name' did not stop, so it was not renamed. Nothing was changed."
        # One that went down without stopping as asked is started again.
        if [ "$_prr_ran" = 1 ]; then
            case "$(_personal_status_of "$_prr_from")" in
                database_ready|running|database_connection_failed) ;;
                *)  run_logged "$(personal_cli)" start --deployment-dir "$_prr_from" || \
                        warn "Your database '$_prr_name' did not start again. Start it with: exasol start -d $_prr_name" ;;
            esac
        fi
        exakit_note_failure "Your database '$_prr_name' did not stop, so it was not renamed"
        return 1
    fi
    if ! personal_rename_deployment "$_prr_from" "$_prr_to" || \
       ! exakit_record_ownership database user "$_prr_to"; then
        case "${PERSONAL_RENAME_ERROR:-}" in
            "") personal_rename_deployment "$_prr_to" "$_prr_from" >/dev/null 2>&1 || true
                _prr_why="the kit could not write its record" ;;
            exists) _prr_why="$(ui_tilde "$_prr_to") already exists" ;;
            locked) _prr_why="another Exasol Personal command is using it" ;;
            *) _prr_why="its folder could not be renamed" ;;
        esac
        warn "Your database '$_prr_name' was not renamed to '$EXAKIT_PERSONAL_DEPLOYMENT', because $_prr_why. Nothing was changed."
        if [ "$_prr_ran" = 1 ] && [ -d "$_prr_from" ] && \
           ! run_logged "$(personal_cli)" start --deployment-dir "$_prr_from"; then
            warn "Your database '$_prr_name' did not start again. Start it with: exasol start -d $_prr_name"
        fi
        exakit_note_failure "Your database '$_prr_name' was not renamed to '$EXAKIT_PERSONAL_DEPLOYMENT', because $_prr_why"
        return 1
    fi
    personal_point_record_at "$_prr_to" || true
    _prr_id="$(_personal_deployment_id_in "$_prr_to" 2>/dev/null || true)"
    personal_stamp_made_in "$_prr_old_id" "$_prr_id" "$_prr_old_dir" "$_prr_name"
    [ -z "$_prr_id" ] || manifest_set runtime.deployment_id "$_prr_id" 2>/dev/null || true
    personal_record_engine_own
    # Its 20-session limit, while it is stopped: the start below applies it.
    personal_session_limit_remove "$_prr_to/local/runtime/exa/exasol.conf" "$_prr_ver" || \
        warn "The 20-session limit of this database was not removed. Its file is as it was."
    # Its saved port, held now by another database of the user's (Q12): the
    # deploy step's start would fail on it. While it is stopped, it gets the
    # next free port (personal_pick_port: neither in use nor saved by another
    # deployment), set by the launcher itself.
    # One that ran a moment ago can hold its own port until its runner is gone.
    _prr_wait=0
    _prr_port="$(personal_saved_db_port "$_prr_to" 2>/dev/null || true)"
    while [ "$_prr_ran" = 1 ] && [ -n "$_prr_port" ] && [ "$_prr_wait" -lt 5 ] && port_in_use "$_prr_port"; do
        _prr_wait=$((_prr_wait + 1)); sleep 1
    done
    personal_reuse_free_port "$_prr_to" || true
    # A 0.3.0 kit's own `default` that a 2.5 of the user's moved, picked here
    # (kit_database_missing): the MCP server that kit set up in it is recorded
    # as the kit's when that is provable (mcp_sidecar_claim). Nothing for a
    # database the kit never set one up in. Offline: the database is stopped
    # until the deploy step starts it, and the claim never downloads then.
    command -v mcp_sidecar_claim >/dev/null 2>&1 && mcp_sidecar_claim offline
    ok "Your database '$_prr_name' is now '$EXAKIT_PERSONAL_DEPLOYMENT'. The kit uses it and never deletes it."
    return 0
}

# _personal_rebuild_noted — 0 when a rebuild of a database of the user's
# (Q19) in this very folder was begun and has not brought a new one up yet
# (runtime.rebuild_path, written right before its destroy): whoever deploys
# there next, the installer run again included, makes the USER's database.
_personal_rebuild_noted() {
    grep -qF '"rebuild_path"' "${EXAKIT_MANIFEST:-/nonexistent}" 2>/dev/null || return 1
    _prn_path="$(manifest_get runtime.rebuild_path 2>/dev/null || true)"
    [ -n "$_prn_path" ] && [ "$_prn_path" = "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ]
}
_personal_rebuild_settled() {
    grep -qF '"rebuild_path"' "${EXAKIT_MANIFEST:-/nonexistent}" 2>/dev/null || return 0
    ( manifest_del runtime.rebuild_path ) >/dev/null 2>&1 || true
}

# _personal_rebuild_of_users — 0 only for the rebuild of a database of the
# user's that exakit repair-runtime asked for and they confirmed (Q19): its
# three variables (EXAKIT_REBUILD_OWNER=user, EXAKIT_REUSE_DB=0,
# EXAKIT_REPLACE_DB=1), the folder in use is the one the kit records as theirs,
# and it carries the id on record, or is what a rebuild cut short left there
# (_personal_rebuild_noted). Nothing in the manifest ever says the kit's: a
# rebuild cut short leaves it theirs.
_personal_rebuild_of_users() {
    [ "${EXAKIT_REBUILD_OWNER:-}" = user ] && [ "${EXAKIT_REUSE_DB:-}" = 0 ] && [ "${EXAKIT_REPLACE_DB:-}" = 1 ] || return 1
    [ "$(manifest_get runtime.ownership 2>/dev/null || true)" = user ] || return 1
    [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] || return 1
    personal_deploy_dir_refresh
    [ -n "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] && \
        [ "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" = "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 1
    _personal_rebuild_noted && return 0
    _prou="$(manifest_get runtime.deployment_id 2>/dev/null || true)"
    [ -n "$_prou" ] && [ "$(_personal_deployment_id_in "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true)" = "$_prou" ]
}

# _personal_new_database_owner — who owns the database a deploy just made:
# the kit, or the user when `exakit repair-runtime` rebuilt a database of
# theirs (EXAKIT_REBUILD_OWNER=user, Q19), or its rebuild was cut short and
# this finishes it (_personal_rebuild_noted): it stays theirs, never deleted by
# uninstall.
_personal_new_database_owner() {
    _personal_rebuild_noted && { printf 'user\n'; return 0; }
    case "${EXAKIT_REBUILD_OWNER:-}" in user) printf 'user\n' ;; *) printf 'kit\n' ;; esac
}

# personal_reuse_free_port <dir> — the stopped database in <dir>, picked in
# the one question, moved off a saved port that something else holds now
# (Q12): to the next free one, with `exasol config set --ports db:<n>`, which
# the launcher allows on a stopped deployment. One line says the new port.
# Nothing done when the port is free, or when no other port is (the start
# then names the port held, as before).
personal_reuse_free_port() {
    _prfp_port="$(personal_saved_db_port "$1")"
    [ -n "$_prfp_port" ] && port_in_use "$_prfp_port" || return 0
    _prfp_prev="${EXAKIT_PERSONAL_DEPLOY_DIR:-}"
    EXAKIT_PERSONAL_DEPLOY_DIR="$1"
    personal_pick_port || { EXAKIT_PERSONAL_DEPLOY_DIR="$_prfp_prev"; return 1; }
    EXAKIT_PERSONAL_DEPLOY_DIR="$_prfp_prev"
    if run_logged "$(personal_cli)" config set --ports "db:$PERSONAL_PICKED_PORT" --deployment-dir "$1"; then
        info "Port $_prfp_port is in use by another database, so your database '$(basename "$1")' now uses port $PERSONAL_PICKED_PORT."
        return 0
    fi
    return 1
}

# personal_record_engine_own — runtime.engine becomes what the deployment in
# use says itself (_personal_engine_own): the record of the database before it,
# or an older kit's guess, is not its engine. Nothing when it does not say.
# Twin of Save-PersonalEngineOwn.
personal_record_engine_own() {
    _preo="$(_personal_engine_own)"
    case "$_preo" in
        docker|podman) ( manifest_set runtime.engine "$_preo" ) >/dev/null 2>&1 || true ;;
    esac
    return 0
}

# _personal_reuse_declined — EXAKIT_REUSE_DB says a new database (0, n, no,
# new): `exakit repair-runtime` sets it to replace the kit's own database
# rather than start it. Any other value, or none, keeps the kit's own.
_personal_reuse_declined() {
    case "${EXAKIT_REUSE_DB:-}" in
        0|n|N|no|NO|No|new) return 0 ;;
    esac
    return 1
}

# _personal_kit_made <dir> <id> — 0 when the starter-kit-local in <dir>, found
# with no database record of the kit's, is one the kit made itself: its first
# deploy was interrupted before the receipt was written. The kit's records
# say so: runtime.first_boot_pending (written right before the kit's own
# `install local`), or runtime.deployment_id naming <id>. So does the place:
# the kit's private home (mode P), where only the kit's own launcher deploys
# and a database of the user's never is. A receipt of the kit's makes it a
# recorded database (personal_kit_has_record): it never gets here. (The deploy
# step writes that receipt with the deployment's id, which is a record; a
# run that ended between the two leaves runtime.first_boot_pending, above.)
_personal_kit_made() {
    case "$1" in "$EXAKIT_PERSONAL_PRIVATE_HOME"/*) return 0 ;; esac
    personal_first_boot_pending && return 0
    [ -n "${2:-}" ] && [ "$2" = "$(manifest_get runtime.deployment_id 2>/dev/null || true)" ]
}

# _personal_record_gone_elsewhere — 0 when the folder in use is the one the
# kit's record names, gone, with nothing found in its place (the caller asks
# exakit_personal_db_state first), in one of the launcher's roots and under a
# name that is not the kit's: a 0.3.0 kit's `default` (its own, or one of the
# user's it used) that was destroyed. A folder the user chose, outside the
# launcher's roots, never counts.
_personal_record_gone_elsewhere() {
    [ -n "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] && [ ! -e "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && \
        [ ! -L "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 1
    [ "$(basename "$EXAKIT_PERSONAL_DEPLOY_DIR")" != "$EXAKIT_PERSONAL_DEPLOYMENT" ] || return 1
    [ "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" = "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 1
    detect_personal_deploy_roots
    case "$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")" in
        "$DETECT_PERSONAL_DEPLOY_ROOT_NEW"|"$DETECT_PERSONAL_DEPLOY_ROOT_LEGACY") return 0 ;;
    esac
    return 1
}

# personal_stamp_made_in <old id> <new id> <old folder> <name> — the kit's
# database becomes another one: what the records say the kit created (the
# read-only login, the Scheduler's, the Semantic Views role, the SQL
# preprocessor's) was created in the old one, and says so now
# (<record>.made_in, the deployment id), so the uninstall never drops a login
# or role of the same name the kit did not make here. Nothing when it is the
# same database: the id is the one on record, or a 0.3.0 record kept none and
# it is its folder, moved to the launcher's other root. Twin of
# Set-PersonalMadeIn.
personal_stamp_made_in() {
    [ -f "${EXAKIT_MANIFEST:-}" ] || return 0
    if [ -n "${1:-}" ]; then
        [ "$1" = "${2:-}" ] && return 0
    elif [ -n "${3:-}" ] && [ ! -e "$3" ] && [ "${3##*/}" = "${4:-}" ]; then
        return 0
    fi
    # Its engine too is another database's: what this one says itself is
    # recorded (personal_record_engine_own), or what the deploy step finds.
    [ -n "$(manifest_get runtime.container 2>/dev/null || true)" ] || [ -z "$(manifest_get runtime.engine 2>/dev/null || true)" ] || \
        ( manifest_del runtime.engine ) >/dev/null 2>&1 || true
    for _psmi in mcp_server.connection exasol_scheduler semantic_views preprocessor; do
        [ -n "$(manifest_get "components.$_psmi" 2>/dev/null || true)" ] || continue
        [ -z "$(manifest_get "components.$_psmi.made_in" 2>/dev/null || true)" ] || continue
        ( manifest_set "components.$_psmi.made_in" "${1:-unknown}" ) >/dev/null 2>&1 || true
    done
    return 0
}

# personal_choose_database — the start of the deploy step on a first install:
# which database the starter kit uses. PERSONAL_DB_NEW_NEXT_TO_THEIRS is 1
# when the kit deploys a new database next to an Exasol Personal of the
# user's (the deploy then says so, approved line 4).
#   - an existing install (the kit records its database): nothing to decide,
#     the kit's own is used (or resumed) as it is;
#   - a starter-kit-local already there that the kit has no record of (one an
#     earlier uninstall kept, D5): used as the user's, no question;
#   - the kit's own starter-kit-local whose first deploy was interrupted (no
#     receipt yet, _personal_kit_made): resumed as the kit's, no question;
#   - mode P: a new database in the kit's own home, the user's untouched;
#   - else, when the launcher lists databases of the user's the kit can use,
#     the one question (personal_reuse_answer), and for one of theirs the
#     rename (personal_reuse_rename).
# The kit's own database not found (exakit_personal_db_state) is asked the
# same way: the deployment found in its place is one of the choices. With a
# starter-kit-local of the user's where a new one would go (the kit's own
# destroyed, theirs made under the same name), neither a new database nor a
# rename can have that name: theirs is used as the user's, no question, and
# the screen says so.
# Non-zero when the step cannot go on (a rename that failed).
personal_choose_database() {
    PERSONAL_DB_NEW_NEXT_TO_THEIRS=0
    _pcd_missing=""
    # A PRIVATE MOVE THAT IS NOT FINISHED (personal_update_private): the kit's
    # database is between two places, and an empty new one is never put in its
    # place. Taken back here when it can be, else the step ends.
    personal_private_move_recover
    if _personal_private_move_noted && { _personal_private_move_alive || _personal_private_move_pending; }; then
        if _personal_private_move_alive; then
            warn "The database '$(basename "$(manifest_get runtime.private_move_from)")' was not renamed to '$EXAKIT_PERSONAL_DEPLOYMENT', because another Exasol Personal command is using it. Nothing was changed."
            exakit_note_failure "The database '$(basename "$(manifest_get runtime.private_move_from)")' was not renamed to '$EXAKIT_PERSONAL_DEPLOYMENT', because another Exasol Personal command is using it"
        else
            warn "The database did not stop, so it was not updated. Nothing was changed."
            exakit_note_failure "The database did not stop, so it was not updated"
        fi
        info "The next exakit update tries again."
        return 1
    fi
    if personal_kit_has_record; then
        _pcd_missing="$(exakit_personal_db_state 2>/dev/null || true)"
        if [ -z "$_pcd_missing" ]; then
            personal_deploy_dir_refresh
            # ONLY THE KIT'S ID RECORDED, NO RECEIPT: a record (as on Windows),
            # so nothing is asked, and the deployment carrying that id is the
            # kit's own, recorded so (the id is the proof _personal_kit_made
            # takes too). Without it, the deploy step's reuse would have
            # written a receipt of the user's for it.
            if [ -z "$(manifest_get runtime.ownership 2>/dev/null || true)" ] && \
               [ -z "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" ] && \
               [ -n "$(manifest_get runtime.deployment_id 2>/dev/null || true)" ] && \
               [ "$(_personal_deployment_id_in "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true)" = \
                 "$(manifest_get runtime.deployment_id 2>/dev/null || true)" ]; then
                personal_point_record_at "$EXAKIT_PERSONAL_DEPLOY_DIR" || true
                exakit_record_ownership database kit "$EXAKIT_PERSONAL_DEPLOY_DIR" || true
                return 0
            fi
            _personal_record_gone_elsewhere || return 0
            # THE RECORDED FOLDER IS GONE, NOTHING IN ITS PLACE, UNDER A NAME
            # THAT IS NOT THE KIT'S: a 0.3.0 kit's `default` destroyed by hand.
            # Deployed again there, the kit's new database was named `default`.
            # It goes where a first install puts it (the resolver's target with
            # no usable record), as the kit's own, without the gone database's
            # id; then on as a first install.
            _pcd_owner="$(_personal_new_database_owner)"
            personal_point_record_at "$(detect_personal_deploy_dir)" || return 0
            [ "$_pcd_owner" != user ] || ( manifest_set runtime.rebuild_path "$EXAKIT_PERSONAL_DEPLOY_DIR" ) >/dev/null 2>&1 || true
            exakit_record_ownership database "$_pcd_owner" "$EXAKIT_PERSONAL_DEPLOY_DIR" || true
            ( manifest_del runtime.deployment_id ) >/dev/null 2>&1 || true
        fi
    fi
    personal_deploy_dir_refresh
    # WHERE A NEW DATABASE WOULD GO: the kit's folder on a first install. With
    # the kit's own missing, the kit's name in the launcher's roots
    # (detect_personal_deploy_dir), never the folder the record names.
    _pcd_at="$EXAKIT_PERSONAL_DEPLOY_DIR"
    [ -z "$_pcd_missing" ] || _pcd_at="$(detect_personal_deploy_dir)"
    if [ "$(basename "$_pcd_at")" = "$EXAKIT_PERSONAL_DEPLOYMENT" ] && \
       { [ -f "$_pcd_at/.exasolLauncherState.json" ] || [ -f "$_pcd_at/deployment.json" ]; }; then
        _pcd_id="$(_personal_deployment_id_in "$_pcd_at" 2>/dev/null || true)"
        _pcd_old_id="$(manifest_get runtime.deployment_id 2>/dev/null || true)"
        _pcd_old_dir="$(manifest_get runtime.deployment_dir 2>/dev/null || true)"
        if [ -z "$_pcd_missing" ] && _personal_kit_made "$_pcd_at" "$_pcd_id"; then
            # THE KIT'S OWN, INTERRUPTED: its first deploy ended before the
            # receipt (Ctrl-C, a closed terminal). Resumed and repaired as the
            # kit's, never taken for one an earlier install kept: the deploy
            # step then retries or replaces it as its own.
            personal_point_record_at "$_pcd_at" || true
            exakit_record_ownership database kit "$_pcd_at" || true
        else
            if [ -z "$_pcd_missing" ]; then
                info "Found the database '$EXAKIT_PERSONAL_DEPLOYMENT' from an earlier install. The kit uses it and never deletes it."
            else
                info "A database of yours is named '$EXAKIT_PERSONAL_DEPLOYMENT', the name of the kit's own database. The kit uses it and never deletes it."
            fi
            personal_point_record_at "$_pcd_at" || true
            exakit_record_ownership database user "$_pcd_at" || true
        fi
        personal_stamp_made_in "$_pcd_old_id" "$_pcd_id" "$_pcd_old_dir" "$(basename "$_pcd_at")"
        [ -z "$_pcd_id" ] || manifest_set runtime.deployment_id "$_pcd_id" 2>/dev/null || true
        personal_record_engine_own
        return 0
    fi
    # Mode P: the kit's launcher cannot see the user's databases, and never
    # uses one (D2). A new one, next to theirs.
    _pcd_list=""
    [ "${EXAKIT_PERSONAL_MODE:-}" = P ] || _pcd_list="$(personal_reuse_candidates)"
    if [ -z "$_pcd_list" ]; then
        case "${EXAKIT_REUSE_DB:-}" in
            ""|0|n|N|no|NO|No|new|1|y|Y|yes|YES|Yes) ;;
            *) reject "EXAKIT_REUSE_DB=$EXAKIT_REUSE_DB is not a database the kit can use on this computer. Unset it, or set it to 0, for a new database." ;;
        esac
        { [ "${EXAKIT_PERSONAL_MODE:-}" = P ] || [ -n "${PERSONAL_USER_LAUNCHER:-}" ] || \
          [ -n "$(personal_launcher_deployments 2>/dev/null)" ]; } && PERSONAL_DB_NEW_NEXT_TO_THEIRS=1
        [ -z "$_pcd_missing" ] || personal_point_record_at "$(detect_personal_deploy_dir)" || true
        return 0
    fi
    _pcd_n="$(printf '%s\n' "$_pcd_list" | grep -c .)"
    # The launcher's version, asked once here: the rename below needs it too
    # (personal_session_limit_remove), and asking it again after the rename
    # would let launcher 2.5 move the renamed folder before its edit.
    _pcd_ver="$(personal_launcher_version 2>/dev/null || true)"
    _pcd_line="$(printf '%s' "$_pcd_ver" | awk -F. '{print $1"."$2}')"
    [ -n "$_pcd_ver" ] || _pcd_line="$(printf '%s' "${EXAKIT_PERSONAL_VERSION:-2.5}" | awk -F. '{print $1"."$2}')"
    if [ "$_pcd_n" = 1 ]; then
        info "Exasol Personal $_pcd_line is on this computer, with 1 database of yours."
    else
        info "Exasol Personal $_pcd_line is on this computer, with $_pcd_n databases of yours."
    fi
    _pcd_pick="$(personal_reuse_answer "$_pcd_list")" || exit $?
    if [ "$_pcd_pick" = new ]; then
        PERSONAL_DB_NEW_NEXT_TO_THEIRS=1
        # The kit's own new one, never the folder a missing record names.
        [ -z "$_pcd_missing" ] || personal_point_record_at "$(detect_personal_deploy_dir)" || true
        return 0
    fi
    _pcd_row="$(printf '%s\n' "$_pcd_list" | grep "^$_pcd_pick	" | head -1)"
    _pcd_rest="${_pcd_row#*	}"
    personal_reuse_rename "$_pcd_pick" "${_pcd_rest#*	}" "${_pcd_rest%%	*}" "$_pcd_ver"
}

personal_deploy_local() {
    personal_deploy_dir_refresh
    # WHICH DATABASE, FIRST: on a first install the user's own Exasol Personal
    # 2.5 databases are offered in one question (personal_choose_database), and
    # one picked is renamed to starter-kit-local before anything below looks at
    # the kit's folder. A new database is deployed next to theirs, on its own
    # port. Theirs are never adopted by a port or by their place in a list.
    personal_choose_database || return 1
    # WHICH ENGINE, BEFORE ANYTHING ELSE IN THIS STEP. A deployment that already
    # exists keeps the engine it was made on - the launcher's rule, and every
    # deployment from before 2.4 is Podman - so the kit only chooses for a
    # fresh one (see personal_resolve_engine). A named engine the machine
    # cannot provide ends this STEP and not the run: the caller records it and
    # the install carries on to what does not need a database.
    #
    # A "NOT USABLE" FROM THE COMPATIBILITY GATE IS MINUTES OLD by now (the
    # launcher download ran in between), and a Docker still starting then is
    # often up now: that stale answer made a Podman deployment for good.
    # Asked again here; a "usable" answer stays kept.
    [ "${_PERSONAL_PDU_RC:-}" = 1 ] && _personal_docker_uncache
    if ! personal_engine_platform; then
        EXAKIT_PERSONAL_ENGINE=""
    elif personal_deployment_exists; then
        # The record's engine, the deployment's own version or state, or what
        # Docker or Podman lists (personal_engine_existing). "" when none can
        # say: then nothing is started, replaced or recorded. In THIS shell,
        # so its Docker answer stays kept for the checks below.
        personal_engine_existing >/dev/null
        EXAKIT_PERSONAL_ENGINE="$_PERSONAL_EXISTING"
        [ -n "$EXAKIT_PERSONAL_ENGINE" ] || { _personal_engine_unknown_stop; return 1; }
    elif _personal_rebuild_noted && [ -z "${EXAKIT_CONTAINER_ENGINE:-}" ] && \
         [ -n "$(manifest_get runtime.engine 2>/dev/null || true)" ]; then
        # The user's, destroyed for a rebuild that was cut short: on the engine
        # it had, written down before the destroy.
        EXAKIT_PERSONAL_ENGINE="$(manifest_get runtime.engine)"
    else
        personal_resolve_engine || return 1
    fi
    case "$EXAKIT_PERSONAL_ENGINE" in
        docker)
            personal_engine_running docker || return 1
            ;;
        *)
            # The deployment runs through Podman, so a machine without it is
            # given it here - after the launcher, before the database. No-op
            # wherever Podman is already there, and on the platforms whose
            # launcher brings its own. A no, or a machine it cannot install
            # on, ends this STEP the same way.
            # A FRESH Podman deployment on a WSL kernel without nftables fails
            # at its first network, after the download: refused here instead,
            # with the fix named. An existing deployment is not judged here:
            # its launcher update is not gated either, and its start names the
            # fix from netavark's own error (_personal_start_network_blocked),
            # which is the only check that applies to it.
            if ! personal_deployment_exists; then
                personal_wsl_podman_network_ok "$(exakit_install_command)" || return 1
            fi
            personal_install_podman || return 1
            # AND THAT IT ACTUALLY RUNS. A podman that is present but cannot
            # start a container fails inside the launcher, minutes later,
            # naming neither.
            personal_podman_running || return 1
            ;;
    esac
    # THE KIT'S OWN DATABASE IS ALREADY UP (this run, a previous run, or the
    # user started it by hand): starter-kit-local, the kit's by its record, by
    # the one question above, or kept by an earlier uninstall. Used as it is,
    # no question. `exasol info` is the launcher's own health signal, and a
    # database that is not the kit's is never "running" here, whatever answers
    # on a port (personal_deployment_running). EXAKIT_REUSE_DB=0 (exakit
    # repair-runtime) asks for a fresh deployment instead.
    if personal_deployment_running; then
        info "An Exasol database is already running on port $(personal_db_port)."
        if ! _personal_reuse_declined; then
            exakit_reuse_ownership database "$EXAKIT_PERSONAL_DEPLOY_DIR"
            ok "Reusing the existing Exasol deployment"
            # personal_deployment_running just answered a real SELECT.
            personal_record_manifest "healthy"
            return 0
        fi
        # NOT THE END OF THE RUN. The user declined a database, not the kit:
        # nothing has been written, nothing is half made, and every step that
        # does not need a database still has value. Same shape as a declined
        # Podman install.
        info "Stop it first ('exakit stop'), then re-run the installer to deploy a fresh one - port $(personal_db_port) stays in use while it is running: $(exakit_install_command)"
        exakit_note_failure "Declined to reuse the database already running on port $(personal_db_port)"
        return 1
    fi

    # A deployment exists but is not running — cleanly stopped, or a crashed
    # VM. The launcher refuses `install local` over a stopped deployment
    # ("run `start` to restart or `destroy` to delete resources"), so
    # deploying here would dead-end. Adopt it the way a running one is
    # adopted: start it and reuse. A piped/non-interactive install defaults
    # to yes (reuse). Declining reuse is exactly as harmless as it is for a
    # running database — nothing is deleted without its own explicit consent,
    # so EXAKIT_REUSE_DB=0 can never destroy in this state what it safely
    # refuses in the other. Deletion has a dedicated question and a dedicated
    # variable (EXAKIT_REPLACE_DB=1), and its prompt names the consequence
    # before the answer. The one exception is a deployment that will not
    # start at all (a crashed VM): that is replaced — announced, never
    # silently — because there is nothing left to reuse.
    _pdl_never_booted_replaced=0
    _pdl_exists=0
    personal_deployment_exists && _pdl_exists=1
    if [ "$_pdl_exists" = 1 ]; then
        exakit_reuse_ownership database "$EXAKIT_PERSONAL_DEPLOY_DIR"
        # This run's launcher output starts here: the evidence the replace
        # below reads before deleting anything (_personal_start_network_blocked).
        _pdl_start_log_at=""
        if [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -f "$EXAKIT_LOG_FILE" ]; then
            _pdl_start_log_at="$(wc -l < "$EXAKIT_LOG_FILE" 2>/dev/null | tr -d ' ')"
        fi
        # A FIRST BOOT THE LAUNCHER GAVE UP ON is not a stopped deployment. In
        # "deployment_failed" its start and stop do nothing, so the
        # start-and-reuse path below would report success over a record that
        # stays failed - and every later exakit start would wait on nothing.
        # The launcher's own retry is its deploy; when that gives up on a
        # first boot again, the kit's budget and reconcile take over. Only a
        # database that never answers reaches the ladder below.
        if [ "$(personal_launcher_state 2>/dev/null || true)" = "deployment_failed" ] && \
           ! exakit_component_is_managed database && ! _personal_rebuild_of_users && ! _personal_rebuild_noted; then
            # ONLY THE KIT'S OWN DEPLOYMENT IS EVER DEPLOYED AGAIN OR OFFERED
            # FOR REMOVAL (OWN-06). A failed deployment of the user's - found
            # in the launcher's list, adopted or not - is named and left: its
            # deploy is the user's to run, and the never-started replace below
            # would destroy it on a first-boot flag that belongs to no folder.
            warn "The launcher records the deployment at $EXAKIT_PERSONAL_DEPLOY_DIR as failed. It is not the kit's, so the kit does not deploy it again: repair it with its own launcher, then retry."
            exakit_note_failure "The deployment at $EXAKIT_PERSONAL_DEPLOY_DIR is recorded as failed and is not the kit's: repair it with its own launcher, then re-run the installer"
            return 1
        fi
        if [ "$(personal_launcher_state 2>/dev/null || true)" = "deployment_failed" ]; then
            info "The launcher records this deployment as failed - retrying its deploy."
            EXAKIT_ACTIVE_LABEL="Retrying the deployment"
            PERSONAL_CONTAINER_ERROR=""
            # Its own runner still holding the VM makes that deploy fail with
            # "VM is already running"; stop it first when it is certainly ours.
            personal_stop_runner_of_failed_deployment || true
            _pdl_redeployed=0
            if run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"; then
                _pdl_redeployed=1
            elif _personal_vm_already_running "$_pdl_start_log_at" && \
                 { personal_first_boot_pending || ! personal_tls_answers; } && \
                 personal_clear_stale_vm; then
                # THE RETRY WAS BLOCKED BY THE THING IT RETRIES. Reported from a
                # real install: a deploy was run over a VM that was still
                # running, the launcher recorded the deployment as failed, and
                # every later deploy ended in "VM is already running" - the
                # launcher cannot adopt its own running VM, and its start and
                # stop do nothing in this state. So the runner is stopped and
                # the deploy run once more. Never a runner still inside its
                # start budget; and a database that answers is only stopped
                # when it has never held data (a first boot the kit made and
                # never saw answer) - one that may hold data is left running
                # and named below.
                info "A VM left running by an earlier attempt blocked the deploy; it was stopped, deploying again."
                if run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || \
                   personal_recover_slow_first_boot; then
                    _pdl_redeployed=1
                fi
            elif personal_recover_slow_first_boot; then
                _pdl_redeployed=1
            fi
            if [ "$_pdl_redeployed" = 1 ]; then
                ok "Reusing the existing Exasol deployment (deployed again)"
                personal_wait_ready_or_deploy || return 1
                personal_record_manifest "healthy"
                return 0
            fi
            warn "The failed deployment could not be brought up.$(personal_foreign_db_hint)$(personal_stuck_vm_hint "$_pdl_start_log_at")"
            personal_explain_failure
            # A DEPLOYMENT THAT NEVER STARTED HOLDS NO DATA, so the ladder below
            # asks the wrong questions of it: "start it and keep its data" is a
            # no-op in this state, and "DELETE ... and its data" defaulting to
            # no left the user with nothing either way. The kit made it and has
            # never seen it answer (personal_first_boot_pending), so it is
            # offered for replacement, default yes - still a consent prompt,
            # still answered by EXAKIT_REPLACE_DB. A deployment that ever
            # answered, one the kit did not make, and an explicit
            # EXAKIT_REUSE_DB=1 all keep the ladder unchanged.
            case "${EXAKIT_REUSE_DB:-}" in
                1|y|Y|yes|YES|Yes) _pdl_reuse_asked=1 ;;
                *) _pdl_reuse_asked=0 ;;
            esac
            if [ "$_pdl_reuse_asked" = 0 ] && personal_first_boot_pending && exakit_component_is_managed database; then
                if ! confirm_env EXAKIT_REPLACE_DB "This deployment never started, so it holds no data. Remove it and deploy a fresh one?" y; then
                    info "Nothing was deleted. Diagnose it with 'exakit status', or re-run with EXAKIT_REPLACE_DB=1 to replace it: $(exakit_install_command)"
                    exakit_note_failure "A deployment that never started could not be brought up, and replacing it was declined"
                    return 1
                fi
                # A FRESH DEPLOY ON A WSL KERNEL WITHOUT NFTABLES FAILS, so a
                # Podman deployment is checked before its destroy, as the
                # replace below is (personal_wsl_podman_network_ok --replace).
                if [ "${EXAKIT_PERSONAL_ENGINE:-}" != "docker" ] && \
                   ! personal_wsl_podman_network_ok --replace "exakit start"; then
                    return 1
                fi
                info "Removing the deployment that never started, and deploying a fresh one."
                run_logged "$(personal_cli)" destroy --remove --auto-approve --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || \
                    warn "Could not fully remove the old deployment; the launcher will deploy over it."
                _pdl_never_booted_replaced=1
            fi
        fi
    fi
    if [ "$_pdl_exists" = 1 ] && [ "$_pdl_never_booted_replaced" = 0 ]; then
        info "An Exasol deployment was found, not running."
        # THE KIT'S OWN, RESUMED: no question. It is starter-kit-local, the
        # kit's by its record or by the one question above, and starting it
        # keeps its data. EXAKIT_REUSE_DB=0 (exakit repair-runtime) skips the
        # start for the replace below.
        if ! _personal_reuse_declined; then
            personal_note_guest_rebuild
            if personal_launcher_supports start && \
               run_logged "$(personal_cli)" start $(personal_auto_approve_flag start) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"; then
                ok "Reusing the existing Exasol deployment (started)"
                # NOT "started, therefore running". This is the line the
                # screenshot ended on: the launcher accepted a start for a
                # deployment it had only initialized, did nothing, and the kit
                # then waited 151 seconds for it. The repair is the launcher's
                # own deploy, and it takes twenty seconds.
                personal_wait_ready_or_deploy || return 1
                personal_record_manifest "healthy"
                return 0
            fi
            # `start` failing ONCE is not evidence the deployment is gone: the
            # commonest cause is the module's own documented orphan runner
            # daemon still holding port 8563 after a failed deploy or destroy.
            # Reap it and try once more — the reaper used to run only AFTER
            # this branch had already destroyed the data it would have saved.
            if personal_reap_orphan_daemon 2>/dev/null && \
               run_logged "$(personal_cli)" start $(personal_auto_approve_flag start) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"; then
                ok "Reusing the existing Exasol deployment (started after clearing an orphaned runner)"
                personal_wait_ready_or_deploy || return 1
                personal_record_manifest "healthy"
                return 0
            fi
            warn "The existing deployment could not be started, even after clearing orphaned runners."
        fi
        # NO PATH DESTROYS WITHOUT THIS CONSENT — not even a failed start. A
        # deployment that will not start today may hold months of data and be
        # one diagnosis away from starting tomorrow; deleting it is the user's
        # call, made with the consequence in front of them. Interactive runs
        # are asked (default no); automation says EXAKIT_REPLACE_DB=1, and
        # exakit repair-runtime remains the sanctioned destructive repair.
        #
        # AND NO DESTROY THAT THE REBUILD CANNOT FOLLOW. Replacing a Podman
        # deployment deploys afresh, and on a WSL kernel without nftables that
        # fresh deploy fails at its first network - after the data is gone.
        # So the WSL check runs here, before the question and the destroy
        # (exakit repair-runtime lands here too): refused, nothing is deleted.
        # --replace: a release that cannot be read refuses here too, and the
        # gate says the one "Nothing was deleted" line itself.
        #
        # THE START'S OWN EVIDENCE FIRST. When this run's start failed on
        # netavark's nftables error, a rebuild meets the same kernel whatever
        # the release reads (a WSL 2.7 with a custom kernel, an unreadable
        # release cleared with EXAKIT_WSL_CHECKED=1): refused, nothing deleted,
        # the start's own next step named.
        if [ "${EXAKIT_PERSONAL_ENGINE:-}" != "docker" ] && \
           _personal_start_network_blocked "${_pdl_start_log_at:-}"; then
            warn "$(_personal_start_network_text)"
            info "Nothing was deleted: the deployment and its data stay."
            exakit_note_failure "$(_personal_start_network_text)"
            return 1
        fi
        # ONLY WHEN A REPLACE CAN HAPPEN. With no consent given
        # (EXAKIT_REPLACE_DB unset) and no terminal to ask on, the question
        # below answers no by itself, so a refusal for a replace nobody asked
        # for only hid the real advice ("Start it yourself ..."). With a
        # terminal the check stays BEFORE the question, by design: a yes it
        # would then refuse is not a question worth asking.
        _pdl_consent_possible=0
        case "${EXAKIT_REPLACE_DB:-}" in
            1|y|Y|yes|YES|Yes) _pdl_consent_possible=1 ;;
            0|n|N|no|NO|No)    : ;;
            *) [ -n "$(_exakit_prompt_tty)" ] && _pdl_consent_possible=1 ;;
        esac
        # NEVER ASKED ABOUT A DATABASE OF THE USER'S: one they let the kit use
        # (the one question, or an earlier install) is never deleted, so the
        # question is not put to them. Only the kit's own database is offered
        # for replacement. And exakit repair-runtime rebuilds theirs, once they
        # said yes to its warning (Q19, _personal_rebuild_of_users).
        if ! exakit_component_is_managed database && ! _personal_rebuild_of_users; then
            info "Nothing was deleted. This database is yours, so the kit never deletes it. Start it with 'exakit start', or diagnose it with 'exakit status'."
            exakit_note_failure "A stopped deployment of yours could not be started. The kit never deletes it"
            return 1
        fi
        if [ "$_pdl_consent_possible" = 1 ] && [ "${EXAKIT_PERSONAL_ENGINE:-}" != "docker" ] && \
           ! personal_wsl_podman_network_ok --replace "exakit start"; then
            return 1
        fi
        if ! confirm_env EXAKIT_REPLACE_DB "DELETE the stopped deployment and its data, and deploy a fresh one? This cannot be undone." n; then
            info "Nothing was deleted. Start it yourself with 'exakit start', diagnose with 'exakit status', repair with 'exakit repair-runtime' - or re-run with EXAKIT_REPLACE_DB=1 to replace it, deleting its data."
            exakit_note_failure "A stopped deployment could not be started, and deleting it was declined"
            return 1
        fi
        # THEIRS, ON RECORD BEFORE THE DESTROY (Q19): a deploy that fails, or a
        # run that ends here, is finished as the user's by whatever run comes
        # next. A record that cannot be written ends the step first.
        if ! exakit_component_is_managed database; then
            manifest_set runtime.rebuild_path "$EXAKIT_PERSONAL_DEPLOY_DIR"
            [ -z "${EXAKIT_PERSONAL_ENGINE:-}" ] || manifest_set runtime.engine "$EXAKIT_PERSONAL_ENGINE"
        fi
        info "Replacing the existing deployment — its previous data is not recoverable."
        # --auto-approve: destroy has its own [y/N] prompt, which a piped or
        # scripted install cannot answer; the consent came from the explicit
        # replace question (or EXAKIT_REPLACE_DB=1) just above.
        personal_destroy || \
            warn "Could not fully remove the old deployment (the launcher said: $PERSONAL_DESTROY_ERROR); it will deploy over it."
    fi

    # A NEW DATABASE GETS ITS OWN PORT (D3): 8563 when it is free, else the
    # next free one (personal_pick_port), passed to `install local --ports`. A
    # database of the user's on 8563, running or stopped, is no conflict. A
    # runner of the kit's own left by an interrupted run is reaped first, as
    # below, so its port is free again; a runner of another deployment is
    # never touched (the reaper's own rule), and the pick passes it by.
    if ! personal_deployment_exists; then
        PERSONAL_PICKED_PORT=""
        if port_in_use "$(personal_db_port)"; then
            personal_reap_orphan_daemon >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || true
        fi
        if ! personal_pick_port; then
            warn "No port from $EXAKIT_PERSONAL_PORT to $EXAKIT_PERSONAL_PORT_LAST is free for the starter kit's database: each is in use, or saved by another Exasol Personal database."
            info "Free one of them (stop a database you do not need), then re-run the installer: $(exakit_install_command)"
            exakit_note_failure "No port from $EXAKIT_PERSONAL_PORT to $EXAKIT_PERSONAL_PORT_LAST is free for the starter kit's database"
            return 1
        fi
    fi
    # Port busy but the launcher sees no reachable deployment on it. This is
    # usually our own orphaned runner daemon from a failed deploy or destroy —
    # reap it and continue. Only a genuinely foreign process (another database,
    # a stale container), which the reaper leaves untouched, is a hard stop.
    # EXAKIT_DB_PORT does not apply to the personal path, so name the real port.
    # For a new database this is the port just picked, free a moment ago.
    if port_in_use "$(personal_db_port)"; then
        _pdl_port_free=0
        personal_reap_orphan_daemon && _pdl_port_free=1
        # A RUNNER TOO YOUNG TO JUDGE IS WAITED FOR, NOT GIVEN UP ON. The usual
        # one is this installer's own runner from a run interrupted a moment
        # ago: nobody can stop it for the user (its deployment record is gone),
        # and in three minutes it is either a database that answers or an
        # orphan the reaper takes. So the rest of its start budget is waited
        # out here, once, and the port is judged again.
        if [ "$_pdl_port_free" = 0 ] && [ "${PERSONAL_PORT_HOLDER:-}" = "runner_young" ]; then
            personal_wait_out_young_runner "${PERSONAL_PORT_HOLDER_WAIT:-0}"
            if ! port_in_use "$(personal_db_port)" || personal_reap_orphan_daemon; then
                _pdl_port_free=1
            fi
        fi
        if [ "$_pdl_port_free" = 0 ]; then
            case "${PERSONAL_PORT_HOLDER:-}" in
                runner_young|runner_live|runner_other)
                    # NAME WHAT IT IS AND THE ONE COMMAND THAT FREES THE PORT. "Stop
                    # that application" sent the reader looking for a program;
                    # it is an Exasol runner, and with no deployment here to
                    # stop it through, its process id is the handle there is.
                    warn "Port $(personal_db_port) is held by an Exasol Personal runner (pid ${PERSONAL_PORT_HOLDER_PID}) that is not a reachable deployment of this kit.$(personal_foreign_db_hint)"
                    info "If it is a database you use, stop it with its own 'exasol stop' (or 'exakit stop' where it was installed). If it is a leftover, free the port with: kill ${PERSONAL_PORT_HOLDER_PID}"
                    info "Then re-run the installer (EXAKIT_DB_PORT does not choose the port of a personal deployment): $(exakit_install_command)"
                    exakit_note_failure "Port $(personal_db_port) is held by an Exasol Personal runner (pid ${PERSONAL_PORT_HOLDER_PID}) that is not a reachable deployment of this kit: stop it, or kill ${PERSONAL_PORT_HOLDER_PID}, then re-run the installer"
                    ;;
                *)
                    warn "Port $(personal_db_port) is in use by a process that is not a reachable Exasol Personal deployment.$(personal_foreign_db_hint)"
                    info "Stop that application, then re-run the installer (EXAKIT_DB_PORT does not choose the port of a personal deployment): $(exakit_install_command)"
                    exakit_note_failure "Port $(personal_db_port) is held by something that is not an Exasol Personal deployment"
                    ;;
            esac
            return 1
        fi
    fi

    # Two points, not three. Deploying and then checking health are one fact to
    # the reader -- the database is up and answering -- so they close on a single
    # line, and the launcher's EULA notice follows as the step's own second
    # point instead of being wedged between them.
    #
    # THE NOTICE FOLLOWS THE DEPLOYMENT, NOT THE HEALTH CHECK. It used to be
    # safe to leave it until last for a reason that has since stopped being
    # true: a database that never answered ended the run, the rollback below
    # destroyed the deployment, and no deployment survived to have accepted
    # anything. That failure is now recorded rather than fatal, and the
    # deployment stays - so the licence terms are replayed on that path too,
    # below, before this function hands its refusal back.
    #
    # Same bracket and the same terminal gate as personal_install_launcher: the
    # progress bar narrates the deploy and the spinner narrates the health
    # probe, so the info/ok pairs underneath are the second telling.
    _pdl_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1

    # BEFORE the deploy, not only after it. The launcher's own EULA notice is
    # captured out of its output and replayed once the deploy succeeds, which
    # means the terms could only ever be read after the deployment existed. The
    # replay stays where it is -- it is Exasol's wording, verbatim, and there is
    # nothing to capture until the launcher has run -- so this line goes ahead
    # of it, saying which licence covers what while the reader can still stop.
    info "Exasol Personal is free to use and ships under Exasol's own licence terms, not the kit's MIT licence. The launcher shows them below."
    # Next to an Exasol Personal of the user's: theirs is not touched.
    [ "${PERSONAL_DB_NEW_NEXT_TO_THEIRS:-0}" = 1 ] && \
        info "Deploying the starter kit's own database '$EXAKIT_PERSONAL_DEPLOYMENT'. Your Exasol Personal is not changed."
    info "Deploying Exasol Personal locally${EXAKIT_PERSONAL_ENGINE:+ on $EXAKIT_PERSONAL_ENGINE} — about 2 minutes"
    # THE UNDO DESTROYS ONLY WHAT THIS RUN CREATES. Armed only when the kit's
    # deployment folder does not exist yet, so the folder it removes is the one
    # the install below makes. It names that folder, and checks that it is
    # there when it fires: a launcher run without --deployment-dir acts on ITS
    # default, which next to the user's own launcher is the user's own
    # deployment, and launcher 2.5 follows a legacy folder that is missing to
    # the deployment it moved from there (followMigratedDeployment).
    if [ ! -e "$EXAKIT_PERSONAL_DEPLOY_DIR" ]; then
        push_rollback "[ -d \"$EXAKIT_PERSONAL_DEPLOY_DIR\" ] && \"$(personal_cli)\" destroy --remove --auto-approve --deployment-dir \"$EXAKIT_PERSONAL_DEPLOY_DIR\" || true"
    fi

    # The launcher's output is consumed, not shown -- see the progress helpers
    # above. Three files carry what the pipeline learns back out of it: the live
    # phase, the tail to print if it fails, and the EULA notice to replay if it
    # succeeds.
    _deploy_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-deploy.XXXXXX")" || \
        die "Could not create a temporary directory for the database install."
    _deploy_state="$_deploy_tmp/state"
    _deploy_tail="$_deploy_tmp/tail"
    _deploy_notice="$_deploy_tmp/notice"
    _deploy_t0="$(date +%s 2>/dev/null || echo 0)"
    ui_progress_state "$_deploy_state" 0 5 3 "Preparing to deploy"
    : > "$_deploy_tail"
    : > "$_deploy_notice"

    EXAKIT_DEPLOY_LIVE=0
    PERSONAL_CONTAINER_ERROR=""
    # Recorded BEFORE the deploy: a deployment the launcher creates and never
    # boots is the one the never-booted branch above may later offer to
    # replace as empty. The first answer from its database clears it.
    personal_set_first_boot_pending 1
    ui_progress_begin "$_deploy_state" "$_deploy_t0" && EXAKIT_DEPLOY_LIVE=1
    # --auto-approve: 2.3 fails a non-interactive host preparation rather than
    # proceeding without approval, and this pipeline is the definition of one.
    # Omitted on launchers that do not take it — see personal_auto_approve_flag.
    _pdl_fresh=0
    personal_deployment_exists || _pdl_fresh=1
    # shellcheck disable=SC2046
    "$(personal_cli)" install local $(personal_auto_approve_flag install) \
        $(personal_engine_flag "$EXAKIT_PERSONAL_ENGINE") $(personal_ports_flag) \
        --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>&1 | \
        _personal_deploy_collect "$_deploy_state" "$_deploy_tail" "$_deploy_notice"
    _deploy_rc=${PIPESTATUS[0]}
    if [ "$_pdl_fresh" = 1 ] && personal_deployment_exists; then
        exakit_record_ownership database "$(_personal_new_database_owner)" "$EXAKIT_PERSONAL_DEPLOY_DIR"
        # With its id: the one a deployment in this folder must carry to be
        # the kit's (exakit_component_ownership), even if the run ends here.
        _pdl_new_id="$(_personal_deployment_id_in "$EXAKIT_PERSONAL_DEPLOY_DIR")"
        [ -z "$_pdl_new_id" ] || manifest_set runtime.deployment_id "$_pdl_new_id" 2>/dev/null || true
    fi
    ui_progress_end
    EXAKIT_DEPLOY_LIVE=0

    if [ "$_deploy_rc" -ne 0 ]; then
        # Restored before anything explains the failure: the tail below prints
        # through foreign_note, and a step that says nothing while it works must
        # still say everything when it goes wrong.
        EXAKIT_QUIET_DETAIL="$_pdl_prev_quiet"
        # A DEPLOYMENT THAT EXISTS IS GIVEN THE KIT'S OWN BUDGET FIRST. The
        # launcher waits 27 seconds for a first boot and calls the deployment
        # failed when the database has not answered by then - with the
        # container up and the database ready a moment later (four times in
        # one day, on WSL and on Windows, where a first boot in a fresh Podman
        # machine takes 40 to 60 seconds). See personal_recover_slow_first_boot.
        if personal_deployment_exists && personal_recover_slow_first_boot; then
            rm -rf "$_deploy_tmp"
        else
            _personal_deploy_print_tail "$_deploy_tail"
            # DISARMED, NOT FIRED. The destroy pushed above is the right undo
            # for a run that is ending; this run is not ending, and a partial
            # deployment is what a retry needs to look at.
            rollback_clear
            warn "Local deployment failed.$(personal_foreign_db_hint)"
            # WHAT ACTUALLY WENT WRONG: the container's own error, and the fix
            # when the kit recognises it there or in the launcher's tail.
            personal_explain_failure "$_deploy_tail"
            rm -rf "$_deploy_tmp"
            info "Retry it by re-running the installer - completed steps are skipped: $(exakit_install_command)"
            exakit_note_failure "The launcher could not deploy the database locally${PERSONAL_FAILURE_CAUSE}"
            return 1
        fi
    fi

    if ! personal_wait_ready_or_deploy; then
        EXAKIT_QUIET_DETAIL="$_pdl_prev_quiet"
        # A deployment that exists has accepted the terms, whether or not its
        # database is answering yet. See the note above the deploy.
        _personal_deploy_print_notice "$_deploy_notice"
        rm -rf "$_deploy_tmp"
        rollback_clear
        # The WSL kernel was named with its own next step (wsl --update, then
        # exakit start); a re-run of the installer meets the same kernel.
        [ "${_PERSONAL_WAIT_NETWORK:-0}" = 1 ] || \
            info "Retry it by re-running the installer ($(exakit_install_command)), or read the state with 'exakit status'."
        return 1
    fi

    EXAKIT_QUIET_DETAIL="$_pdl_prev_quiet"
    # One line for both, and the elapsed covers both -- it is the step's time,
    # not the deploy's alone. The endpoint is the literal fallback
    # personal_record_manifest uses when deployment.json cannot be read; the
    # real DSN is not parsed out of it until a few lines later, and this is the
    # same address either way on a personal deployment.
    ok "Exasol Personal deployed and answering on 127.0.0.1:$(personal_db_port) ($(( $(date +%s 2>/dev/null || echo 0) - _deploy_t0 ))s)"
    _personal_deploy_print_notice "$_deploy_notice"
    rm -rf "$_deploy_tmp"

    personal_deploy_dir_refresh
    exakit_record_ownership database "$(_personal_new_database_owner)" "$EXAKIT_PERSONAL_DEPLOY_DIR"
    _personal_rebuild_settled
    PERSONAL_RECORD_FRESH=1
    personal_forget_database_steps
    personal_record_manifest "healthy"
}

# personal_forget_database_steps — drop the ticks of the two steps whose work
# lives in the database or is derived from its password: the exapump profile
# and the MCP read-only user. A fresh deployment is a new database with its own
# users and, from Exasol Personal 2.4, its own random sys password. A re-run
# over it (exakit repair-runtime, EXAKIT_REPLACE_DB=1) used to skip both steps
# as "already done": `exakit sql` answered "Authentication failed", the sample
# data could not load, and mcp_readonly was gone until mcp-doctor recreated
# it. Seen on a real machine. Nothing else is touched: the launcher, pyexasol
# and the exakit helper do not depend on which database is there. Twin of
# Clear-PersonalDatabaseSteps.
personal_forget_database_steps() {
    command -v exakit_unmark_step >/dev/null 2>&1 || return 0
    for _pfs_step in exapump mcp; do
        exakit_unmark_step "$_pfs_step" 2>/dev/null || true
    done
    return 0
}

_personal_wait_ready_probe() {
    info "Checking deployment health"
    # A WALL-CLOCK ceiling, not a try count. Counting tries made the budget
    # thirty sleeps of five seconds PLUS thirty launcher probes of up to
    # EXAKIT_PERSONAL_PROBE_TIMEOUT each - up to 450 s of waiting behind a
    # message that promised 150. The deadline below is the number the message
    # quotes, and the try cap is derived from it as the fallback for a machine
    # whose `date` cannot answer (elapsed would stay 0 and the loop would never
    # end); it is never the tighter of the two.
    # Animate it: the step that just stopped showing the launcher's chatter
    # must not then end on a still screen.
    # A guest rebuild is not a slow start, it is a different operation with a
    # different duration — and the ordinary budget turned a successful upgrade
    # into a reported crash. An explicitly set EXAKIT_PERSONAL_READY_TIMEOUT
    # still wins: a number the user chose is never overridden by a guess.
    _pwr_budget="${EXAKIT_PERSONAL_READY_TIMEOUT:-150}"
    _pwr_what="Waiting for the database to answer"
    _pwr_raise=EXAKIT_PERSONAL_READY_TIMEOUT
    if [ -z "${EXAKIT_PERSONAL_READY_TIMEOUT:-}" ] && personal_guest_rebuild_expected; then
        personal_note_guest_rebuild
        _pwr_budget="${EXAKIT_PERSONAL_REBUILD_TIMEOUT:-900}"
        _pwr_what="Rebuilding the VM guest and waiting for the database"
        _pwr_raise=EXAKIT_PERSONAL_REBUILD_TIMEOUT
    fi
    ui_spin_begin "$_pwr_what"
    _pwr_t0="$(date +%s 2>/dev/null || echo 0)"
    _pwr_elapsed=0
    _pwr_maxtries=$(( _pwr_budget / 5 + 1 ))
    _tries=0
    # SOMETHING HAS TO BE SAID WITHOUT A TTY. The only narration here is
    # ui_spin_begin, and that returns immediately when stdout is not a
    # terminal - so an agent's run printed NOTHING for up to 150 seconds
    # normally, and up to 900 after a launcher update triggers the guest
    # rebuild. Fifteen minutes of silence is indistinguishable from a hang, and
    # the documented advice is not to loop on `exakit start`, so the agent has
    # nothing to poll and no reason to keep waiting.
    #
    # To STDERR: a caller composing a --json answer on stdout must not find
    # progress lines spliced into it.
    _pwr_last_note=0
    PERSONAL_CONTAINER_ERROR=""
    while [ "$_pwr_elapsed" -lt "$_pwr_budget" ] && [ "$_tries" -lt "$_pwr_maxtries" ]; do
        # A HANDSHAKE, NOT AN OPEN PORT. Under rootless Podman the port is
        # pasta's from the moment the container starts, and `exasol info`
        # answers from the deployment directory - together they declared
        # "reachable" a database that was still a minute from accepting a
        # connection, and the next step's SELECT 1 paid for it six times.
        if personal_tls_answers; then
            ui_spin_end
            ok "Deployment is reachable"
            personal_set_first_boot_pending 0
            # The database answered under this launcher, so whatever rebuild
            # that first start owed is paid. Recorded so the notice does not
            # announce it again for the same launcher.
            _pwr_lv="$(personal_launcher_version 2>/dev/null || true)"
            [ -n "$_pwr_lv" ] && manifest_set runtime.guest_rebuilt_for "$_pwr_lv" 2>/dev/null
            return 0
        fi
        # A CONTAINER THAT REFUSED TO START WILL NOT ANSWER LATER. Asked every
        # third try (15 s): two podman calls, and the point is to stop the wait
        # early, not to race it.
        if [ $(( (_tries + 1) % 3 )) -eq 0 ]; then
            _personal_container_refused && break
        fi
        sleep 5
        _tries=$((_tries + 1))
        _pwr_elapsed=$(( $(date +%s 2>/dev/null || echo 0) - _pwr_t0 ))
        [ "$_pwr_elapsed" -ge 0 ] || _pwr_elapsed=0
        if [ ! -t 1 ] && [ $(( _pwr_elapsed - _pwr_last_note )) -ge 30 ]; then
            _pwr_last_note="$_pwr_elapsed"
            printf '  ... %s (%ss elapsed, ceiling %ss; raise it with %s)\n' \
                "$_pwr_what" "$_pwr_elapsed" "$_pwr_budget" "$_pwr_raise" >&2
        fi
    done
    ui_spin_end
    # The number the user actually waited, not the number the loop intended.
    _pwr_spent="$_pwr_elapsed"
    [ "$_pwr_spent" -gt 0 ] || _pwr_spent=$(( _tries * 5 ))
    # Not "run the probe that just failed": name the two commands that actually
    # diagnose and recover a deploy that answers nothing.
    return 1
}

# personal_wait_ready - the probe, and the end of the run when it fails. Every
# caller outside the install still reaches this one; the install's callers use
# personal_wait_ready_or_deploy below, which tries the repair first and hands a
# refusal back instead of ending the run.
personal_wait_ready() {
    _personal_wait_ready_probe && return 0
    if [ -n "${PERSONAL_CONTAINER_ERROR:-}" ]; then
        personal_explain_failure
        die "The database could not start${PERSONAL_FAILURE_CAUSE}. Read the state with 'exakit status'; once the cause is fixed: exakit start"
    fi
    die "The deployment did not answer within ${_pwr_spent} seconds (the ceiling is ${_pwr_budget}s; raise it with ${_pwr_raise}). Read the state with 'exakit status', then 'exakit start' to retry - a deployment stuck in 'interrupted' is repaired with 'exakit repair-runtime' (destructive, it asks first)."
}

# personal_wait_ready_or_deploy - A START THAT REPORTED SUCCESS IS NOT A
# DATABASE. The launcher's `start` exits 0 and does nothing at all in more than
# one state: "deployment_failed" is the one the kit already knew about, and
# "initialized but not deployed yet" is the one that cost a whole install -
# start said OK, the kit said "Reusing the existing Exasol deployment
# (started)", and then waited its entire 150-second budget for a database
# nobody had asked to exist. The launcher prints its own advice in that WARN
# and the fix is one command: its deploy.
#
# So this stops reading the state and reads the DATABASE. Whatever the launcher
# called it, a deployment that does not answer after a start it accepted is a
# deployment that was never started, and the launcher's deploy is what brings
# it up - the same command a user runs by hand when they hit this, and it takes
# about twenty seconds. Checking behaviour rather than a state string means the
# next spelling of this state needs no new case arm.
#
# 0 when the database answers, 1 when it never did. Never dies: the caller in
# the install records it and carries on.
#
# THE DEPLOY CAN MEET THE WSL KERNEL TOO. A start the launcher accepted
# without acting (exit 0) skips personal_start's network check, and the deploy
# here then fails on netavark's nftables error - which used to be told "repair
# with: exakit repair-runtime": data destroyed, same kernel after. So the log
# offset is taken before the deploy and its output is read the same way
# (_personal_start_network_blocked); on that evidence the reason noted is the
# network die's own sentence, so `exakit status --json` answers wsl --update,
# and _PERSONAL_WAIT_NETWORK=1 tells a caller that ends the run to end it with
# _personal_start_network_die (personal_wait_network_die_if_blocked).
personal_wait_ready_or_deploy() {
    personal_deploy_dir_refresh
    _PERSONAL_WAIT_NETWORK=0
    # Its deploy goes to the kit's own deployment only (exakit_personal_db_state).
    exakit_kit_database_guard || return 1
    _personal_wait_ready_probe && return 0
    # A CONTAINER THAT REFUSED TO START is not fixed by deploying it again: the
    # deploy would recreate it and the same error would refuse it the same
    # way. Its cause is the answer.
    if [ -n "${PERSONAL_CONTAINER_ERROR:-}" ]; then
        personal_explain_failure
        exakit_note_failure "The database never answered${PERSONAL_FAILURE_CAUSE}"
        return 1
    fi
    # A VM THAT IS RUNNING IS NOT DEPLOYED OVER. The launcher refuses that
    # ("VM is already running") and then records the deployment as failed, after
    # which it refuses everything - a slow first boot turned into an install
    # that could not be re-run. So while the VM's runner holds the port the
    # database is given a second budget, and a VM still silent after that is
    # stopped before the deploy that starts it again.
    _pwrd_vm="$(personal_vm_runner_pid 2>/dev/null || true)"
    if [ -n "$_pwrd_vm" ]; then
        info "The database VM is running (pid $_pwrd_vm) but has not answered yet - a first boot can take several minutes. Waiting once more instead of deploying over it."
        _personal_wait_ready_probe && { ok "The database answered"; return 0; }
        if ! personal_clear_stale_vm; then
            warn "The database VM is still running (pid $_pwrd_vm) and never answered. Stop it with: kill $_pwrd_vm   then: exakit start"
            exakit_note_failure "The database VM runs (pid $_pwrd_vm) but never answered: stop it with kill $_pwrd_vm, then exakit start"
            return 1
        fi
        info "The VM that never answered was stopped; the launcher's deploy starts it again."
    else
        warn "The database did not answer after the launcher accepted the start."
        info "In some states the launcher's start does nothing and its deploy is the fix - running that now."
    fi
    _pwrd_log_at=""
    if [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -f "$EXAKIT_LOG_FILE" ]; then
        _pwrd_log_at="$(wc -l < "$EXAKIT_LOG_FILE" 2>/dev/null | tr -d ' ')"
    fi
    EXAKIT_ACTIVE_LABEL="Deploying the existing database"
    if ! run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"; then
        EXAKIT_ACTIVE_LABEL=""
        if _personal_start_network_blocked "$_pwrd_log_at"; then
            _PERSONAL_WAIT_NETWORK=1
            # One short line here: a caller that ends the run says the whole
            # sentence (personal_wait_network_die_if_blocked), and the install
            # summary prints the note.
            warn "The launcher's deploy failed: this WSL kernel cannot create the deployment network (run wsl --update, then wsl --shutdown, reopen this distro, then exakit start)."
            exakit_note_failure "$(_personal_start_network_text)"
            return 1
        fi
        exakit_note_failure "The database never answered, and the launcher's deploy could not bring it up"
        return 1
    fi
    EXAKIT_ACTIVE_LABEL=""
    _personal_wait_ready_probe && { ok "The database answered after the launcher's deploy"; return 0; }
    PERSONAL_FAILURE_CAUSE=""
    [ -n "${PERSONAL_CONTAINER_ERROR:-}" ] && personal_explain_failure
    exakit_note_failure "The database never answered, even after the launcher deployed it again${PERSONAL_FAILURE_CAUSE}"
    return 1
}

# personal_wait_network_die_if_blocked - for a caller that ends the run when
# personal_wait_ready_or_deploy returned 1: die with the WSL network sentence
# when that is why, never with the repair-runtime advice. Returns 0 otherwise,
# so the caller's own die follows.
personal_wait_network_die_if_blocked() {
    [ "${_PERSONAL_WAIT_NETWORK:-0}" = 1 ] && _personal_start_network_die
    return 0
}

# personal_record_manifest [status] [fresh] — write the connection details this
# kit hands to every client, plus the runtime state and the database's TLS pin.
#
# The STATUS IS AN ARGUMENT because it used to be the constant "healthy". Every
# caller got it, including `exakit update`, which reaches here after swapping
# the launcher binary with no health probe of any kind in between — so updating
# a STOPPED database recorded it as healthy, and anything reading the manifest
# rather than calling personal_status was then simply wrong. Callers that have
# just watched the database answer pass "healthy"; callers that have not pass
# nothing and the state is probed.
# personal_clear_stale_record — drop the old container's keys from runtime.*.
#
# An install that crossed from the nano kit kept runtime.engine, container,
# image and volume from that record, describing a container that is not this
# deployment's. legacy.* is where the kit keeps the old database: migrate and
# the restore read it from there (legacy_record_value). Copied across first
# when legacy.* has none, so an older record loses nothing. Called when the
# runtime is recorded and on every resumed install. Twin of
# Clear-PersonalStaleRecord.
#
# RUNTIME.ENGINE IS TWO KEYS IN ONE NAME. In a nano record it is the OLD
# container's engine and sits beside runtime.container; in a Personal record
# (kit 0.2.4+) it is THIS deployment's engine and stands alone. So it moves to
# legacy.* only when runtime.container says the record is a nano one. Dropping
# it unconditionally made every resumed install (setup-linux.sh calls this on
# its own) forget a Docker deployment's engine, after which it was treated as
# Podman everywhere.
personal_clear_stale_record() {
    _pcs_nano="$(manifest_get runtime.container 2>/dev/null || true)"
    for _pcs_key in container engine volume; do
        [ "$_pcs_key" = engine ] && [ -z "$_pcs_nano" ] && continue
        _pcs_old="$(manifest_get "runtime.$_pcs_key" 2>/dev/null || true)"
        [ -n "$_pcs_old" ] || continue
        if [ -z "$(manifest_get "legacy.$_pcs_key" 2>/dev/null || true)" ]; then
            manifest_set "legacy.$_pcs_key" "$_pcs_old"
        fi
    done
    [ -n "$_pcs_nano" ] && { manifest_del runtime.engine 2>/dev/null || true; }
    for _pcs_key in runtime.container runtime.image runtime.volume; do
        manifest_del "$_pcs_key" 2>/dev/null || true
    done
}

personal_record_manifest() {
    personal_deploy_dir_refresh
    _prm_status="${1:-}"
    # "fresh": the kit has just deployed this database itself (see the TLS pin
    # at the end). Every other caller adopted, started or updated one. Said by
    # PERSONAL_RECORD_FRESH=1 on the line before, consumed here, so the fresh
    # deploy's record line reads like every other one.
    _prm_fresh="${2:-}"
    [ "${PERSONAL_RECORD_FRESH:-0}" = 1 ] && _prm_fresh="fresh"
    PERSONAL_RECORD_FRESH=0
    manifest_set runtime.type "personal"
    # Read before the clear below drops the key: what the deployment says
    # itself, then this run's own choice, then a record that already names its
    # engine, and one that never did is Podman (every deployment from before
    # kit 0.2.4).
    _prm_engine="$(_personal_engine_own)"
    case "$_prm_engine" in
        docker|podman) ;;
        *) _prm_engine="${EXAKIT_PERSONAL_ENGINE:-$(personal_engine_recorded)}" ;;
    esac
    personal_clear_stale_record
    if personal_engine_platform; then
        manifest_set runtime.engine "$_prm_engine"
    fi
    # The version of the deployment ON DISK, whenever its state can say —
    # never the version this kit merely advertises. Reusing or adopting an
    # existing deployment used to record the advertised number over it, after
    # which every version answer, update check and outranks-guard reasoned
    # from a launcher version the deployment never had.
    # runtime.version is the COMPONENT the kit installs and compares against
    # versions.json, and that component is the LAUNCHER: personal_install_launcher
    # downloads it, its checksum is the one verified, and components.personal
    # names its release. So the binary is asked first. The deployment's own
    # version - a different fact, and the one that decides whether a guest
    # rebuild is still ahead - is recorded beside it rather than in its place.
    #
    # Still never the advertised number while anything on disk can answer: that
    # was the original bug here, and recording an aspiration over an adopted
    # deployment is exactly what the order below refuses to do.
    _prm_dep="$(personal_deployed_version 2>/dev/null || true)"
    _prm_ver="$(personal_launcher_version 2>/dev/null || true)"
    manifest_set runtime.version "${_prm_ver:-${_prm_dep:-$EXAKIT_PERSONAL_VERSION}}"
    if [ -n "$_prm_dep" ]; then
        manifest_set runtime.deployment_version "$_prm_dep"
    fi
    manifest_set runtime.launcher "$(personal_cli)"
    # THE HOME THE LAUNCHER RUNS WITH: the kit's private one in mode P (the
    # wrapper above sets it), none recorded for the user's own home. Python
    # (marketplace/runtime.py) derives the launcher's folders from it.
    if [ "${EXAKIT_PERSONAL_MODE:-}" = P ]; then
        manifest_set runtime.launcher_home "$EXAKIT_PERSONAL_PRIVATE_HOME"
    else
        manifest_del runtime.launcher_home 2>/dev/null || true
    fi
    # NOT OVER A DEPLOYMENT THAT IS NOT PROVABLY THE KIT'S. The id below is
    # what a moved folder must carry to be followed as the kit's
    # (personal_deploy_dir_refresh), so it is written only for a database the
    # kit just deployed, for the folder the kit's record names (where it is
    # now), or when there is no record of the kit's own at all. With the kit's
    # own gone and the user's deployment in the launcher's folder, neither the
    # id nor the folder is rewritten: otherwise the next uninstall would take
    # the user's deployment for the kit's and destroy it.
    _prm_kit=""
    command -v exakit_personal_kit_dir >/dev/null 2>&1 && _prm_kit="$(exakit_personal_kit_dir)"
    _prm_mine=0
    if [ "$_prm_fresh" = fresh ]; then _prm_mine=1
    elif [ -n "$_prm_kit" ]; then
        [ "$(exakit_personal_deploy_dir_now "$_prm_kit")" = "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && _prm_mine=1
    elif [ -z "$(manifest_get runtime.deployment_id 2>/dev/null || true)" ]; then _prm_mine=1
    fi
    if [ "$_prm_mine" = 1 ] || [ -z "$_prm_kit" ] || [ -e "$_prm_kit" ]; then
        manifest_set runtime.deployment_dir "$EXAKIT_PERSONAL_DEPLOY_DIR"
        # Its name, the folder's: starter-kit-local (a 0.3.0 kit's `default`
        # until exakit update renames it, personal_rename_deployment).
        manifest_set runtime.deployment_name "$(basename "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    fi
    # AND ITS ID. The uninstall checks that the deployment's container is gone
    # by this id, and it read it only from the folder: a folder already gone
    # (deleted by hand, or moved by a newer launcher) left the container
    # unchecked and "Database removed" unproven. ⇄ twin: Write-PersonalManifest.
    _prm_id="$(_personal_deployment_id 2>/dev/null || true)"
    # NOT ANOTHER DEPLOYMENT IN THE KIT'S FOLDER (MCU-02): one whose id is not
    # the one recorded is not the kit's, though it sits where the kit's was
    # (the kit's destroyed, the user's made there). Its id is not taken, and
    # it is recorded as the user's, so update and uninstall leave it.
    # Only a database the kit just deployed itself takes a new id.
    _prm_rec_id="$(manifest_get runtime.deployment_id 2>/dev/null || true)"
    if [ "$_prm_mine" = 1 ] && [ "$_prm_fresh" != fresh ] && [ -n "$_prm_id" ] && [ -n "$_prm_rec_id" ] && \
       [ "$_prm_id" != "$_prm_rec_id" ]; then
        _prm_mine=0
        exakit_record_ownership database user "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true
    fi
    [ -n "$_prm_id" ] && [ "$_prm_mine" = 1 ] && manifest_set runtime.deployment_id "$_prm_id"

    # The deployment directory has everything a client needs:
    #   deployment.json -> host, dbPort, username, cert-validation flag
    #   secrets.json    -> dbPassword
    _dep="$EXAKIT_PERSONAL_DEPLOY_DIR/deployment.json"
    _sec="$EXAKIT_PERSONAL_DEPLOY_DIR/secrets.json"
    if [ -f "$_dep" ]; then
        require_python3
        _conn="$(run_python -c '
import json, sys
doc = json.load(open(sys.argv[1]))
c = doc.get("connection", {})
print("%s:%s\t%s" % (c.get("host", "127.0.0.1"), c.get("dbPort", 8563), c.get("username", "sys")))
' "$_dep" 2>/dev/null)"
        _dsn="$(printf '%s' "$_conn" | cut -f1)"
        _user="$(printf '%s' "$_conn" | cut -f2)"
        # A corrupt/unreadable deployment.json must not record an empty DSN.
        manifest_set runtime.dsn "${_dsn:-127.0.0.1:${EXAKIT_PERSONAL_PORT}}"
        manifest_set runtime.user "${_user:-sys}"
    else
        manifest_set runtime.dsn "127.0.0.1:${EXAKIT_PERSONAL_PORT}"
        manifest_set runtime.user "sys"
    fi
    _password=""
    if [ -f "$_sec" ]; then
        _password="$(run_python -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dbPassword",""))' "$_sec" 2>/dev/null)"
    fi
    if [ -n "$_password" ]; then
        store_credential personal_sys_password "$_password"
        manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/personal_sys_password"
    else
        warn "Could not read the database password from the Exasol Personal secrets — the exapump profile and AI client configs will ask for it or need manual completion."
    fi
    manifest_set runtime.tls "self-signed"
    # Never assert health without either having just seen it or probing for it.
    [ -n "$_prm_status" ] || _prm_status="$(personal_status 2>/dev/null || true)"
    manifest_set runtime.status "${_prm_status:-unknown}"
    # A database that has been seen healthy may hold data from now on.
    [ "$_prm_status" = "healthy" ] && personal_set_first_boot_pending 0
    # ITS TLS CERTIFICATE, PINNED (SEC-14). Trust on first use, taken while the
    # kit is looking at its own database: a deployment it has just made
    # replaces any earlier pin (a new deployment is a new certificate); one it
    # adopted, started or merely updated the launcher of records one only when
    # none is recorded yet - a recorded pin is never silently replaced. Never
    # fatal: no TLS answer leaves the clients exactly as unpinned as before.
    case "$_prm_status" in
        healthy|running*)
            # Clients that already exist hold the old value (a first install
            # writes them after this step, so there is nothing to rewrite yet).
            if [ "$_prm_fresh" = "fresh" ]; then
                exakit_tls_record --replace || true
                [ "${EXAKIT_TLS_PIN_CHANGED:-0}" = 1 ] && exakit_tls_rewrite_clients --profile-only
            else
                exakit_tls_record || true
                [ "${EXAKIT_TLS_PIN_CHANGED:-0}" = 1 ] && exakit_tls_rewrite_clients
            fi
            ;;
    esac
    return 0
}

# personal_refresh_changed_password <password before> — true when the database
# password on file is no longer <password before>, after the records that
# depend on it have been refreshed: the exapump profile is rewritten and the
# change is said. False otherwise, and EXAKIT_PERSONAL_PASSWORD_CHANGE says
# which otherwise: "same" when both passwords were read and are equal, and
# "unknown" when either side could not be read (nothing on file before, or
# secrets.json unreadable now). The caller may say "the password is kept" only
# on "same" - the default used to be that assertion, which is what this check
# exists to replace.
#
# `exakit update personal` swaps the launcher and leaves the deployment alone,
# and the 2.3 -> 2.4 update was watched to keep secrets.json byte for byte.
# That is a fact about one update, not a promise about every one, so the
# password is checked after the swap rather than assumed. The kit's own MCP
# user (mcp_readonly) has its own password in the database and is not
# affected; what a changed sys password breaks is exakit sql, pyexasol scripts
# reading the credential, and the next MCP provisioning - which the credential
# file and the profile cover. Nothing here prints a password. Twin of
# Update-PersonalChangedPassword.
personal_refresh_changed_password() {
    _prcp_before="${1:-}"
    EXAKIT_PERSONAL_PASSWORD_CHANGE="unknown"
    [ -n "$_prcp_before" ] || return 1
    _prcp_after="$(read_credential personal_sys_password 2>/dev/null || true)"
    [ -n "$_prcp_after" ] || return 1
    if [ "$_prcp_after" = "$_prcp_before" ]; then
        EXAKIT_PERSONAL_PASSWORD_CHANGE="same"
        return 1
    fi
    EXAKIT_PERSONAL_PASSWORD_CHANGE="changed"
    # In a subshell: exapump_create_profile can die() on a manifest it cannot
    # read, and a die here would end the update AFTER the launcher swap, with
    # the record half written. Its exit code decides what is said, so "now
    # hold the new one" is never claimed for a profile that was not written.
    _prcp_written=1
    if command -v exapump_create_profile >/dev/null 2>&1 && ( exapump_create_profile ); then
        _prcp_written=0
    fi
    if [ "$_prcp_written" = 0 ]; then
        info "The database password changed with this update: the kit's stored credential and the exapump profile now hold the new one. The AI bridge user (mcp_readonly) keeps its own password and keeps connecting."
    else
        warn "The database password changed with this update: the kit's stored credential holds the new one, but the exapump profile could not be rewritten - recreate it with: exapump profile init ${EXAKIT_EXAPUMP_PROFILE:-starter-kit}. The AI bridge user (mcp_readonly) keeps its own password and keeps connecting."
    fi
    return 0
}

# --- lifecycle (used by exakit) ---------------------------------------------
# personal_help_names_token <token> — filter reading help text on stdin; true
# when <token> appears in a SUBCOMMAND/FLAG position, i.e. first on its own
# line apart from indentation, rather than anywhere in the prose.
#
# `grep -w` was the old test and it matched the word wherever it fell: a row
# reading "stop   Stop a running local deployment" satisfied `-w local` and
# `-w start` at once, so the capability probes this module is built around
# answered yes for commands the launcher does not have.
#
# No `grep -q` here: it exits at the first match and closes the pipe, the
# launcher takes a SIGPIPE (141) writing the rest of its help, and the
# dispatcher's `set -o pipefail` then fails the whole pipeline — making a
# supported command look unsupported. Plain grep reads the full help.
personal_help_names_token() {
    grep -E "^[[:space:]]*(-[-a-zA-Z0-9]+,[[:space:]]*)?$1([[:space:]]|,|$)" >/dev/null
}

personal_launcher_supports() {
    # Bounded: a launcher wedged on a deployment it cannot open hangs on
    # `--help` like everything else, and this is called from `exakit start`,
    # `exakit stop` and the deploy path.
    exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" --help 2>&1 \
        | personal_help_names_token "$1"
}

# personal_auto_approve_flag <subcommand> — "--auto-approve" when this launcher
# takes it on <subcommand>, nothing when it does not.
#
# WHY THIS IS NOT personal_launcher_supports: that probe reads the TOP-LEVEL
# help, where a subcommand's own flags never appear, so it would answer "no"
# for every launcher including the ones that need this most.
#
# It needs to exist because Exasol Personal 2.3 made a non-interactive run of
# local runtime host preparation FAIL rather than proceed without approval —
# and the kit's install consumes the launcher's output through a pipeline, so
# it is exactly the caller that cannot answer a prompt. The consent is real and
# already given: the user ran the installer, and the deploy path asks its own
# questions (EXAKIT_REUSE_DB, EXAKIT_REPLACE_DB) before it gets here. A launcher
# that does not know the flag is never handed it — an unknown flag is a hard
# failure, and 2.2 deployments are still supported.
#
# Deliberately uncached, like personal_launcher_supports: every call site is a
# command substitution, so a cache set here would be written in a subshell and
# thrown away. One bounded launcher probe per start or deploy is the real cost.
personal_auto_approve_flag() {
    if exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" \
            "$(personal_cli)" "$1" --help 2>&1 \
            | personal_help_names_token "--auto-approve"; then
        printf '%s' "--auto-approve"
    fi
    return 0
}

# personal_guest_rebuild_expected — true when the deployment on disk was created
# by a different launcher than the one now installed.
#
# Exasol Personal 2.3 runs the VM guest that belongs to the launcher's runner,
# so a deployment made by an earlier launcher rebuilds its guest on the next
# start. The data survives; the start does not fit the ordinary budget, and a
# successful upgrade that overran it read to the user as a crash.
personal_guest_rebuild_expected() {
    _pgr_dep="$(personal_deployed_version 2>/dev/null || true)"
    [ -n "$_pgr_dep" ] || return 1
    # The launcher that is actually installed, not the one the kit advertises:
    # before an update those differ, and announcing a rebuild for a launcher
    # this machine does not have yet is a promise about the wrong event.
    _pgr_launcher="$(personal_launcher_version 2>/dev/null || true)"
    [ -n "$_pgr_launcher" ] || _pgr_launcher="${EXAKIT_PERSONAL_VERSION:-}"
    [ -n "$_pgr_launcher" ] || return 1
    [ "$_pgr_dep" != "$_pgr_launcher" ] || return 1
    # ONCE, not forever. A deployment keeps the version that created it, so
    # "deployment older than launcher" stays true after the rebuild has already
    # happened - and the notice would then repeat on every start, promising a
    # wait that is behind the user, not ahead. The completed start records the
    # launcher it completed under; this is how the notice retires itself.
    [ "$(manifest_get runtime.guest_rebuilt_for 2>/dev/null || true)" != "$_pgr_launcher" ]
}

# personal_note_guest_rebuild — say it once, before the start that does it.
# Silence through a five-minute start is the failure mode being fixed here, so
# the notice goes ahead of the command rather than in the timeout message.
personal_note_guest_rebuild() {
    personal_guest_rebuild_expected || return 0
    [ "${_EXAKIT_PERSONAL_REBUILD_SAID:-0}" = 1 ] && return 0
    _EXAKIT_PERSONAL_REBUILD_SAID=1
    info "This deployment was created by an earlier launcher, so the first start rebuilds its VM guest — slower than usual, once. Your data is kept."
}

# personal_deployment_wedged — has the launcher marked this deployment as
# INTERRUPTED? That is a third state, and collapsing it into "stopped" is what
# made a crashed database look like a merely idle one.
#
# Reproduced: SIGKILL the runner, and the launcher records
# currentWorkflowState.interrupted and thereafter refuses to start with "local VM
# state contains invalid database port: 0" — forever, because every start attempt
# rewrites the VM state file without ever putting the database port back. `exakit
# start` cannot fix it, and neither can the launcher's own advice to run stop and
# start. Only a redeploy clears it, which personal_deploy_local already knows how
# to do; it just was never reached (see step_artifact_state).
#
# Read from the launcher's own state file rather than by running `exasol status`:
# this is called from `exakit status`, which agents poll, and a file read is free
# where a launcher subprocess is not.
personal_deployment_wedged() {
    personal_deploy_dir_refresh
    [ -n "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || return 1
    _pdw_state="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json"
    [ -f "$_pdw_state" ] || return 1
    exakit_can_run_python || return 1
    run_python - "$_pdw_state" <<'EXAKIT_WEDGE_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
state = doc.get("currentWorkflowState")
if not isinstance(state, dict) or "interrupted" not in state:
    sys.exit(1)
detail = state.get("interrupted") or {}
if isinstance(detail, dict) and detail.get("error"):
    print(detail["error"])
sys.exit(0)
EXAKIT_WEDGE_PY
}

# personal_repair_command — the one command that actually clears a wedged
# deployment. Named in every place the wedge is reported, because the state is
# unrecoverable by any gentler route and an agent that is told "stopped" will
# loop on `exakit start` instead.
personal_repair_command() {
    printf 'exakit repair-runtime\n'
}

personal_status() {
    # THE LAUNCHER THE KIT RUNS (personal_cli), never PATH: a 0.3.0 kit's
    # launcher is where its receipt says, in a shell whose PATH does not name
    # that folder too, and this said "not installed" over a running database
    # there (which its update then renamed without a stop).
    _ps_cli="$(personal_cli)"
    if [ ! -x "$_ps_cli" ] && ! command -v "$_ps_cli" >/dev/null 2>&1; then
        echo "not installed"
    elif personal_deployment_exists; then
        # `exasol info` answers even when the cluster is stopped — the SQL
        # port tells the truth about whether the database is actually up.
        # A BUSY port is not the same truth: with the database stopped and
        # another program listening on 8563, this said "running", `exakit
        # start` said "already running" and exited 0, and `exakit status` sent
        # the reader back to `exakit start` — a loop with no exit. When the
        # port answers, ask the database itself (a real SELECT through the kit's
        # profile); a port that is busy but does not answer as Exasol is a
        # conflict, its own state with its own remedy.
        if port_in_use "$(personal_db_port)"; then
            # THE LAUNCHER OWNS THE LIFECYCLE, so its word outranks the port.
            # A stopped 2.3 deployment can leave its runner alive and still
            # answering SQL; calling that "running" made `exakit start` reply
            # "already running" and do nothing, so a stopped database could
            # never be restarted. Reported as stopped - which is what its owner
            # says - and the start path clears the leftover runner first.
            _ps_state="$(personal_launcher_state 2>/dev/null || true)"
            if [ "$_ps_state" = "stopped" ]; then
                echo "stopped"
            elif personal_db_answers; then
                echo "running"
            elif personal_starting; then
                # Our own runner, still inside its start budget: coming up.
                echo "starting"
            else
                echo "conflict"
            fi
        elif personal_deployment_wedged >/dev/null 2>&1; then
            # Not "stopped": start will fail, and saying stopped sends the
            # reader (and every agent) to a command that cannot work.
            echo "interrupted"
        else
            echo "stopped"
        fi
    else
        echo "not deployed"
    fi
}

# _personal_start_engine_ok - 0 unless the deployment runs on Docker and Docker
# cannot run it now; then 1, with the reason in _pdu_said. Podman keeps its own
# heal path inside the launcher's start, so only Docker is asked here.
_personal_start_engine_ok() {
    personal_engine_platform || return 0
    [ "$(personal_engine_recorded)" = "docker" ] || return 0
    personal_docker_usable
}

# _personal_start_network_blocked [log offset] - 0 when a failed start (or
# deploy) failed because this WSL kernel cannot build the 2.4 deployment
# network: this is WSL, the deployment runs on Podman, AND the launcher's
# output since <log offset> carries netavark's own nftables failure.
#
# EVIDENCE, NOT A GUESS. A WSL release below 2.7 alone used to be enough, and
# then a port held by another program, an interrupted deployment or a 2.3
# deployment that never needed nftables was all told to update WSL - and the
# arms that name the real cause were never reached. Off WSL (macOS, native
# Linux) the WSL instruction never applies, whatever the log says, and a
# benign "nftables not available, falling back" line is not the failure.
_personal_start_network_blocked() {
    [ "$(detect_os)" = "wsl" ] || return 1
    personal_engine_platform || return 1
    [ "$(personal_engine_recorded)" = "podman" ] || return 1
    [ -n "${1:-}" ] && [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -f "$EXAKIT_LOG_FILE" ] || return 1
    tail -n "+$(( ${1} + 1 ))" "$EXAKIT_LOG_FILE" 2>/dev/null | \
        grep -Eqi 'nft.*(did not return successfully|applying ruleset)'
}

# The die for _personal_start_network_blocked, one wording for every caller
# (the text alone is _personal_start_network_text, for the caller that notes
# it without ending the run). NOT repair-runtime: it destroys the deployment
# first and its fresh deploy meets the same kernel. ⇄ twin:
# Stop-PersonalStartNetworkBlocked in setup/lib/runtime-personal.ps1.
_personal_start_network_text() {
    printf '%s' "This WSL kernel cannot create the deployment network: run wsl --update (in PowerShell on Windows), then wsl --shutdown, reopen this distro, then exakit start. Without updating WSL: set firewall_driver = \"iptables\" under [network] in ~/.config/containers/containers.conf (the iptables package must be installed), then exakit start. The deployment and its data are untouched; do not repair-runtime, a rebuild meets the same kernel."
}
_personal_start_network_die() {
    die "$(_personal_start_network_text)"
}

# _personal_record_started - what a start the launcher took changes in the
# record: runtime.status (stop writes "stopped"). Not
# runtime.deployment_version: a deployment keeps the version that created it
# (launcher 2.5.0 leaves .exasolLauncher.version and its state's
# deploymentVersion at 2.4.0 for a deployment 2.4 made, after its first start
# too), so a start has nothing to move there (live re-test F-02). Never fails
# the start. Twin of Set-PersonalStartedRecord.
_personal_record_started() {
    # Only into a record that is there, and in a subshell: manifest_set ends
    # the run (die) where it cannot write, and a start must not end on that.
    [ -f "${EXAKIT_MANIFEST:-}" ] || return 0
    ( manifest_set runtime.status "running" ) >/dev/null 2>&1 || true
    _personal_start_settled
    return 0
}

personal_start() {
    personal_deploy_dir_refresh
    # NEVER ANOTHER DEPLOYMENT: with the kit's own gone, the folder in use can
    # be the user's (exakit_personal_db_state). Refused before any launcher call.
    exakit_kit_database_guard || return 3
    # A DOCKER DEPLOYMENT NEEDS DOCKER UP. Without it the launcher's start
    # fails, and the failure arm below used to name repair-runtime - which
    # destroys the data and still cannot start Docker. Said before anything
    # runs, with the one thing that helps.
    if ! _personal_start_engine_ok; then
        die "The database runs on Docker, and ${_pdu_said:-Docker is not usable}. Start Docker (Docker Desktop, or the docker service), then: exakit start"
    fi
    _pst_log_at=""
    if [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -f "$EXAKIT_LOG_FILE" ]; then
        _pst_log_at="$(wc -l < "$EXAKIT_LOG_FILE" 2>/dev/null | tr -d ' ')"
    fi
    if personal_launcher_supports start; then
        # In "deployment_failed" the launcher's start (and stop) do nothing and
        # exit 0, so this reported "Database started" over a database that was
        # never asked to start and then waited its whole budget for it. The
        # launcher's own retry for that state is its deploy.
        if [ "$(personal_launcher_state 2>/dev/null || true)" = "deployment_failed" ]; then
            # Only the kit's own is deployed again (OWN-06): one the user
            # adopted is named and left to its own launcher.
            exakit_component_is_managed database || _personal_rebuild_noted || \
                die "The launcher records the deployment at $EXAKIT_PERSONAL_DEPLOY_DIR as failed. It is not the kit's, so the kit does not deploy it again: repair it with its own launcher, then: exakit start"
            info "The launcher records this deployment as failed - retrying its deploy instead of a start it would ignore."
            PERSONAL_CONTAINER_ERROR=""
            # A VM its runner still runs answers that deploy with "VM is
            # already running"; stop our own runner first (only when certain).
            personal_stop_runner_of_failed_deployment || true
            if run_logged "$(personal_cli)" deploy $(personal_auto_approve_flag deploy) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"; then
                ok "Database started"
                _personal_record_started
                return 0
            fi
            _personal_start_network_blocked "$_pst_log_at" && _personal_start_network_die
            personal_explain_failure
            die "The deployment could not be brought up${PERSONAL_FAILURE_CAUSE}.$(personal_foreign_db_hint) Check the log above; if it fails the same way, repair with: $(personal_repair_command)"
        fi
        personal_note_guest_rebuild
        # A STOPPED DEPLOYMENT CAN STILL BE HOLDING ITS OWN PORT. The 2.3
        # launcher leaves its runner alive after `stop`, and the next `start`
        # then cannot bind - so the port is cleared BEFORE the attempt rather
        # than diagnosed after it. Scoped by personal_is_orphan_daemon: only
        # this kit's own runner is ever reaped, and a genuinely foreign
        # listener is left alone and reported by the failure path below.
        if [ "$(personal_launcher_state 2>/dev/null || true)" = "stopped" ] && \
           port_in_use "$(personal_db_port)"; then
            info "Clearing a leftover Exasol runner still holding port $(personal_db_port)"
            personal_reap_orphan_daemon >/dev/null 2>&1 || true
        fi
        # Docker mounts a language container read-only: its DNS links go into
        # the image, before the start that mounts it - see
        # personal_slc_dns_prepare.
        personal_slc_dns_prepare
        if ! run_logged "$(personal_cli)" start $(personal_auto_approve_flag start) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"; then
            # Say what to do, not just that it failed. A start that fails on a
            # wedged deployment fails identically every time it is retried, and
            # "Failed to start the deployment" plus a log path sent readers back
            # to `exakit start` in a loop.
            #
            # THE NETWORK FIRST. A WSL kernel without nftables fails the 2.4
            # network move on every start, and the arms below would send the
            # reader to repair-runtime: data destroyed, same failure after.
            _personal_start_network_blocked "$_pst_log_at" && _personal_start_network_die
            if personal_deployment_wedged >/dev/null 2>&1; then
                die "The database is interrupted and cannot be started — the launcher has to rebuild it. Repair it with: $(personal_repair_command) (this rebuilds the database from empty; its data is not recoverable)."
            fi
            if [ "$(personal_status 2>/dev/null)" = "conflict" ]; then
                die "Port $(personal_db_port) is held by another process$(personal_port_holder_hint), so the database cannot start. Stop that process, then: exakit start"
            fi
            PERSONAL_CONTAINER_ERROR=""
            personal_explain_failure
            die "Failed to start the database${PERSONAL_FAILURE_CAUSE}. Check the log above, then retry with 'exakit start'; if it fails the same way, repair with: $(personal_repair_command)"
        fi
        ok "Database started"
        _personal_record_started
        # Every start rebuilds the language containers from their images, and
        # with them their empty DNS files - see personal_slc_dns_repair.
        _pst_dns=0
        personal_slc_dns_repair || _pst_dns=$?
        if [ "$_pst_dns" -eq 2 ]; then
            # Docker, and an image the launcher pulled during this start: it
            # is linked now, and only a start mounts it. Once - the next one
            # finds it linked before it starts.
            info "Restarting the database once, so Java in it can resolve host names"
            if ! run_logged "$(personal_cli)" stop --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || \
               ! run_logged "$(personal_cli)" start $(personal_auto_approve_flag start) --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"; then
                die "The database did not come back from its restart. Start it with: exakit start"
            fi
            personal_slc_dns_repair || true
        fi
    else
        info "This launcher version has no explicit start command."
        info "Check the database with: $(personal_cli) info --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR"
    fi
}

# Where this module and its helpers live, captured while it is being sourced.
EXAKIT_PERSONAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# personal_slc_dns_script [--engine CLI] [--deployment-id ID] <flavor...> — the
# POSIX sh that repairs DNS inside the database container from the launcher
# VM's shell on macOS (where the engine is always the VM's Podman). Linux, WSL
# and Windows run the same logic through setup/lib/personal-slc-dns.py, against
# the deployment's own engine (Podman or Docker).
#
# A language container (SLC) is its own filesystem, and the official ones ship
# etc/resolv.conf and etc/hosts EMPTY. The database mounts the deployment's real
# files into every UDF sandbox at /conf, but a UDF reads /etc - so Java code in
# the database could reach any IP address and resolve no name at all, and a
# virtual schema adapter could never connect to a remote source by hostname.
# Pointing the two files at /conf gives every UDF the deployment's DNS. Only a
# file that is still the shipped EMPTY one is replaced, so a Personal release
# that fixes this upstream turns the whole step into a no-op.
#
# ONLY THIS DEPLOYMENT'S DATABASE CONTAINER. The launcher names it
# exasol-db-<deployment id> on every engine; from Exasol Personal 2.4 a
# sidecar is exasol-db-<id>-sidecar-<name>, and another deployment's database
# (a second kit on a shared Docker Desktop, a second deployment folder, a
# stale container) is exasol-db-<its id>. With the id known only that exact
# name is taken; without one (or the launcher's "local"), an exasol-db-* that
# is not a sidecar only when it is the only one. Anything else is
# "nocontainer", never a repair written into someone else's database.
# ⇄ twin: pick() in setup/lib/personal-slc-dns.py.
#
# Prints one "EXAKIT_SLC_DNS <flavor> repaired|ok|absent|failed" line per
# flavor.
personal_slc_dns_script() {
    _psds_engine="podman"
    _psds_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --engine|--deployment-id)
                # A trailing option has no value: dropped. `shift 2` with one
                # argument left shifts nothing, and the loop never ended.
                [ $# -ge 2 ] || { shift; break; }
                case "$1" in --engine) _psds_engine="$2" ;; *) _psds_id="$2" ;; esac
                shift 2 ;;
            *) break ;;
        esac
    done
    # Both are written into the script: only an engine CLI and an id the
    # launcher could have made get through. The id is trimmed as the launcher
    # trims it (TrimSpace) before it names the container.
    case "$_psds_engine" in docker|podman) : ;; *) _psds_engine="podman" ;; esac
    _psds_id="${_psds_id#"${_psds_id%%[![:space:]]*}"}"
    _psds_id="${_psds_id%"${_psds_id##*[![:space:]]}"}"
    case "$_psds_id" in local|*[!A-Za-z0-9_.-]*) _psds_id="" ;; esac
    printf "E='%s'\nID='%s'\n" "$_psds_engine" "$_psds_id"
    # One name per line: the VM's engine is Podman, which never joins names.
    cat <<'EOF'
CTR=""; ONE=""; DBS=0
for N in $("$E" ps --format '{{.Names}}' 2>/dev/null); do
  if [ -n "$ID" ]; then
    if [ "$N" = "exasol-db-$ID" ]; then CTR="$N"; fi
  else
    case "$N" in exasol-db-*-sidecar-*) : ;; exasol-db-*) ONE="$N"; DBS=$((DBS + 1)) ;; esac
  fi
done
[ -n "$ID" ] || [ "$DBS" -ne 1 ] || CTR="$ONE"
[ -n "$CTR" ] || { echo "EXAKIT_SLC_DNS - nocontainer"; exit 0; }
EOF
    for _psds_flavor in "$@"; do
        cat <<EOF
F='$_psds_flavor'
D=\$(mktemp -d)
# Extracted and tested, not read off a listing: tar -tv columns differ between
# GNU and BSD tar, and the size column is the one that moves.
"\$E" cp "\$CTR":/exa/slc/\$F/etc - 2>/dev/null | tar -C "\$D" -xf - etc/resolv.conf 2>/dev/null
if [ -L "\$D/etc/resolv.conf" ] || [ -s "\$D/etc/resolv.conf" ]; then echo "EXAKIT_SLC_DNS \$F ok"
elif [ ! -e "\$D/etc/resolv.conf" ]; then echo "EXAKIT_SLC_DNS \$F absent"
else
  ln -s /conf/resolv.conf "\$D/resolv.conf"; ln -s /conf/hosts "\$D/hosts"
  if tar -C "\$D" -cf - resolv.conf hosts | "\$E" cp - "\$CTR":/exa/slc/\$F/etc/; then echo "EXAKIT_SLC_DNS \$F repaired"; else echo "EXAKIT_SLC_DNS \$F failed"; fi
fi
rm -rf "\$D"
EOF
    done
    printf '%s\n' 'exit 0'
}

# personal_slc_installed_flavors — the official language containers the
# launcher reports installed, space-separated (java-17 python-3.12 ...).
personal_slc_installed_flavors() {
    personal_deploy_dir_refresh
    exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" slc list --json --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null \
        | run_python_any -c 'import json, sys
text = sys.stdin.read()
try:
    rows = json.loads(text[text.find("["):]) if "[" in text else []
except ValueError:
    rows = []
print(" ".join(r["flavor"] for r in rows if isinstance(r, dict) and r.get("installed")
               and r.get("type") == "official" and r.get("flavor")))' 2>/dev/null
}

# personal_slc_container_id — the deployment id the launcher names its database
# container by (exasol-db-<id>), trimmed; empty when no state file names one.
# THE LAUNCHER'S OWN STATE FIRST: ContainerName reads .exasolLauncherState.json,
# and deployment.json can be older than it, or say "local" (what the launcher
# writes there when it cannot read its state). Read as JSON, the top-level key
# only - never a "deploymentId" nested deeper, never a different occurrence
# than the PowerShell twin takes. ⇄ twin: Get-PersonalSlcContainerId.
personal_slc_container_id() {
    personal_deploy_dir_refresh
    detect_personal_deployment_id "$EXAKIT_PERSONAL_DEPLOY_DIR"
    return 0
}

# personal_slc_dns_engine — the engine the repair asks: the RECORD first (a
# nano record's engine is the old database's, not this one's), then this
# run's choice when nothing is recorded (an install that has not recorded it
# yet), then Podman - every deployment before kit 0.2.4. Not the other way
# round: EXAKIT_PERSONAL_ENGINE left in a caller's environment must not send
# a Podman deployment's repair to Docker. ⇄ twin: Get-PersonalSlcDnsEngine.
personal_slc_dns_engine() {
    _psde="$(manifest_get runtime.engine 2>/dev/null || true)"
    [ -n "$(manifest_get runtime.container 2>/dev/null || true)" ] && _psde=""
    case "$_psde" in docker|podman) : ;; *) _psde="${EXAKIT_PERSONAL_ENGINE:-}" ;; esac
    case "$_psde" in docker) printf 'docker' ;; *) printf 'podman' ;; esac
}

# personal_slc_dns_prepare [--pull] — before a start on Docker: link every
# official language container IMAGE the launcher state lists (installedSlcs)
# through setup/lib/personal-slc-dns.py --prepare. Docker mounts an image
# read-only, so the links personal_slc_dns_repair writes into the running
# container on Podman have to be in the image the start mounts; the image is
# committed back under the tag the launcher mounts, once, and labelled, so a
# later start asks one `docker image inspect` and nothing more. --pull first
# pulls an image that is not here yet (the Java install, whose start would
# otherwise pull it and mount it unlinked). Podman and macOS (the launcher
# VM's Podman): nothing - their mount is writable and repaired after the
# start. Best effort: logged, and never fails the start.
# ⇄ twin: Initialize-PersonalSlcDns.
personal_slc_dns_prepare() {
    personal_deploy_dir_refresh
    [ "$(detect_os 2>/dev/null)" = "macos" ] && return 0
    [ "$(personal_slc_dns_engine)" = "docker" ] || return 0
    command -v docker >/dev/null 2>&1 || return 0
    _psdp_state="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json"
    [ -f "$_psdp_state" ] || return 0
    # The interpreter as an executable (exakit_python_any_argv): the runner
    # refuses a shell function. Bounded at 300 s, and the helper's --budget
    # (240 s) keeps it inside that bound: it ends, its containers removed,
    # before the runner would kill it. Except a --pull: a download of the
    # image can take minutes, so that run is not under the runner; the pull
    # is capped at 30 minutes and the rest keeps the same budget.
    if ! exakit_python_any_argv; then
        _psdp_out="no Python to run it with"
        _psdp_ran=1
    elif [ "${1:-}" = "--pull" ]; then
        _psdp_out="$("${_EXAKIT_PY_ANY[@]}" "$EXAKIT_PERSONAL_LIB_DIR/personal-slc-dns.py" --engine docker \
            --prepare "$_psdp_state" --pull --budget 240 2>&1)"
        _psdp_ran=$?
    else
        _psdp_out="$(exakit_run_bounded 300 "${_EXAKIT_PY_ANY[@]}" "$EXAKIT_PERSONAL_LIB_DIR/personal-slc-dns.py" \
            --engine docker --prepare "$_psdp_state" --budget 240 2>&1)"
        _psdp_ran=$?
    fi
    for _psdp_line in $(printf '%s\n' "$_psdp_out" | sed -n 's/^EXAKIT_SLC_DNS \([^ ]*\) \([a-z]*\)$/\1:\2/p'); do
        _exakit_log_file "INFO  language container DNS (before the start): $_psdp_line"
        case "$_psdp_line" in
            *:derived) info "Gave the ${_psdp_line%%:*} language container image the deployment's DNS" ;;
        esac
    done
    if ! printf '%s\n' "$_psdp_out" | grep -q '^EXAKIT_SLC_DNS '; then
        # It always answers (`- none` when nothing is installed): silence is a
        # run that did not happen, timed out or died - one line with the
        # reason, as personal_slc_dns_repair leaves. ⇄ twin: the same line in
        # Initialize-PersonalSlcDns.
        _psdp_why="$(printf '%s\n' "$_psdp_out" | grep -m 1 . | cut -c1-200)"
        _exakit_log_file "WARN  language container DNS before the start did not run (exit $_psdp_ran): ${_psdp_why:-no output}"
    fi
    return 0
}

# personal_slc_dns_repair — run personal_slc_dns_script for every official
# language container the launcher reports installed. Best effort and bounded:
# no container, a launcher without `slc` or a VM shell that does not answer is
# logged and returns 1, and never fails the caller - the virtual schema check
# reports a database without DNS on its own. Returns 2 on Docker when an image
# was linked (or found linked) under a database started before it was - also
# beside another flavor that failed: the fix is in the image, and the
# database sees it from its next start - the caller restarts it, or says so.
# ⇄ twin: Repair-PersonalSlcDns.
personal_slc_dns_repair() {
    personal_deploy_dir_refresh
    # Its restart and its writes go to the kit's own deployment only.
    exakit_kit_database_guard || return 1
    _psdr_flavors="$(personal_slc_installed_flavors)"
    [ -n "$_psdr_flavors" ] || return 0
    # The id names the database container (exasol-db-<id>); without one only
    # a lone exasol-db-* that is not a sidecar is taken.
    _psdr_id="$(personal_slc_container_id)"
    _psdr_script=""
    _psdr_ran=0
    if [ "$(detect_os 2>/dev/null)" = "macos" ]; then
        _psdr_script="$(mktemp "${TMPDIR:-/tmp}/exakit-slc-dns.XXXXXX")" || return 1
        # The launcher VM's engine is Podman whatever runs elsewhere.
        # shellcheck disable=SC2086 -- one argument per flavor
        personal_slc_dns_script --engine podman ${_psdr_id:+--deployment-id "$_psdr_id"} $_psdr_flavors > "$_psdr_script"
        # The database runs in the launcher's Linux VM; its shell is the one
        # with the Podman that owns the container. It takes the script on stdin
        # - redirected INSIDE the bounded command: without timeout(1) that
        # command runs as a background job, and a background job's stdin is
        # /dev/null, so a redirect on the outside never reached it.
        _psdr_out="$(exakit_run_bounded 90 sh -c 'exec "$0" shell container --deployment-dir "$2" < "$1"' "$(personal_cli)" "$_psdr_script" "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>&1)"
        _psdr_ran=$?
    else
        # THE DEPLOYMENT'S ENGINE, NOT PODMAN BY DEFAULT. From kit 0.2.4 a new
        # deployment runs on Docker wherever Docker Engine 29+ runs, and
        # Podman's CLI cannot see a Docker container: Java kept its empty DNS
        # files and every connect by host name failed.
        _psdr_engine="$(personal_slc_dns_engine)"
        if command -v "$_psdr_engine" >/dev/null 2>&1; then
            # The host's own engine owns the container (Linux, WSL): the shared
            # helper the Windows twin runs too. The id in the = form: one that
            # starts with "-" is still a value, not an option.
            # THE INTERPRETER AS AN EXECUTABLE, not run_python_any: timeout(1)
            # execs its command, and a shell function was "failed to run
            # command", exit 127 - the repair never ran on Linux or WSL.
            # Docker links the image (containers created, copied into,
            # committed): 300 s, against 90 for a write into a container. The
            # helper's --budget, 60 s inside the bound, ends it - its
            # containers removed - before the runner would kill it.
            _psdr_bound=90
            [ "$_psdr_engine" = docker ] && _psdr_bound=300
            if exakit_python_any_argv; then
                # shellcheck disable=SC2086 -- one argument per flavor
                _psdr_out="$(exakit_run_bounded "$_psdr_bound" "${_EXAKIT_PY_ANY[@]}" "$EXAKIT_PERSONAL_LIB_DIR/personal-slc-dns.py" \
                    --engine "$_psdr_engine" --budget $((_psdr_bound - 60)) \
                    ${_psdr_id:+"--deployment-id=$_psdr_id"} $_psdr_flavors 2>&1)"
                _psdr_ran=$?
            else
                _psdr_out="no Python to run the repair with"
                _psdr_ran=1
            fi
        else
            _psdr_out="EXAKIT_SLC_DNS - no$_psdr_engine"
        fi
    fi
    [ -z "$_psdr_script" ] || rm -f "$_psdr_script"
    _psdr_rc=0
    _psdr_derived=0
    for _psdr_line in $(printf '%s\n' "$_psdr_out" | sed -n 's/^EXAKIT_SLC_DNS \([^ ]*\) \([a-z]*\)$/\1:\2/p'); do
        _exakit_log_file "INFO  language container DNS: $_psdr_line"
        case "$_psdr_line" in
            *:repaired) info "Gave the ${_psdr_line%%:*} language container the deployment's DNS" ;;
            *:derived) _psdr_derived=1
                       info "Gave the ${_psdr_line%%:*} language container image the deployment's DNS; the database sees it from its next start" ;;
            *:failed) _psdr_rc=1
                      _exakit_log_file "WARN  language container DNS could not be given to ${_psdr_line%%:*}" ;;
            *:nocontainer|*:nopodman|*:nodocker) _psdr_rc=1 ;;
        esac
    done
    if ! printf '%s\n' "$_psdr_out" | grep -q '^EXAKIT_SLC_DNS '; then
        # The repair never answered (it did not run, or died first): one line
        # with the reason, because every caller ignores this exit code and
        # the reader otherwise sees only "DNS could not be repaired".
        # ⇄ twin: the same line in Repair-PersonalSlcDns.
        _psdr_why="$(printf '%s\n' "$_psdr_out" | grep -m 1 . | cut -c1-200)"
        _exakit_log_file "WARN  language container DNS repair did not run (exit $_psdr_ran): ${_psdr_why:-no output}"
        _psdr_rc=1
    fi
    # A linked image wins over another flavor's failure: only a start mounts
    # it, and without that restart Java has no DNS (the failure is logged).
    [ "$_psdr_derived" = 1 ] && _psdr_rc=2
    return "$_psdr_rc"
}

personal_stop() {
    personal_deploy_dir_refresh
    exakit_kit_database_guard || return 3
    if personal_launcher_supports stop; then
        run_logged "$(personal_cli)" stop --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || die "Failed to stop the database."
        manifest_set runtime.status "stopped"
        _personal_start_settled
        # exapump.sh caches a reachable database for the run; this run just
        # ended that. Guarded: the runtime modules load without exapump.sh.
        command -v exakit_forget_db_reachable >/dev/null 2>&1 && exakit_forget_db_reachable
        ok "Database stopped"
    else
        info "This launcher version has no explicit stop command."
        info "To remove the database entirely use: exakit uninstall"
    fi
}

# The launcher's words for a deployment whose lock another run holds.
PERSONAL_LOCKED_TEXT="locked by another operation"

# personal_unlock_stale — release the deployment's lock when no launcher holds
# it: a launcher that crashed or was killed leaves its lock behind, and then
# even `destroy` refuses, leaving the database running and its folder on disk.
# A launcher that IS running keeps its lock - unlocking under it could leave
# the deployment half-written. The database daemon runs under another name and
# does not count. Returns 0 when the lock was released.
personal_unlock_stale() {
    personal_deploy_dir_refresh
    # A launcher RUNNING: its command line starts with the launcher's path. Not
    # any process that merely mentions the path somewhere in its arguments (a
    # shell script, an editor, `bash -c '...'`), which held a stale lock forever.
    _pus_cli="$(personal_cli | sed 's/[][\.*^$+?(){}|]/\\&/g')"
    if pgrep -f "^${_pus_cli}( |\$)" >/dev/null 2>&1; then
        _exakit_log_file "WARN  the deployment is locked and a launcher is running: not unlocking"
        return 1
    fi
    run_logged "$(personal_cli)" diag unlock --auto-approve --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR"
}

# personal_destroy — destroy the deployment and remove its folder. Called only
# from behind a consent gate (teardown's --data guard, or the replace question);
# tests/agent-operability.sh checks every caller. A stale lock (see
# personal_unlock_stale) is released and the destroy tried once more. When it
# still fails, PERSONAL_DESTROY_ERROR holds the launcher's own last error line
# for the warning (the log keeps all of it). Returns the outcome.
personal_destroy() {
    personal_deploy_dir_refresh
    PERSONAL_DESTROY_ERROR=""
    _pd_out="$(mktemp "${TMPDIR:-/tmp}/exakit-destroy.XXXXXX")" || return 1
    _pd_try=1
    while :; do
        _exakit_log_file "CMD   $(personal_cli) destroy (attempt $_pd_try, removing the deployment folder)"
        ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-working}"
        "$(personal_cli)" destroy --remove --auto-approve --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" > "$_pd_out" 2>&1
        _pd_rc=$?
        ui_spin_end
        [ -n "${EXAKIT_LOG_FILE:-}" ] && cat "$_pd_out" >> "$EXAKIT_LOG_FILE"
        if [ "$_pd_rc" -eq 0 ]; then
            rm -f "$_pd_out"
            return 0
        fi
        [ "$_pd_try" = 1 ] && grep -q "$PERSONAL_LOCKED_TEXT" "$_pd_out" && personal_unlock_stale || break
        _pd_try=2
    done
    PERSONAL_DESTROY_ERROR="$(grep -i -E 'error|fail|cannot|could not|denied' "$_pd_out" | tail -1 | cut -c1-300)"
    [ -n "$PERSONAL_DESTROY_ERROR" ] || PERSONAL_DESTROY_ERROR="$(grep -v '^[[:space:]]*$' "$_pd_out" | tail -1 | cut -c1-300)"
    [ -n "$PERSONAL_DESTROY_ERROR" ] || PERSONAL_DESTROY_ERROR="nothing more"
    rm -f "$_pd_out"
    return 1
}

# personal_teardown [--data] — destroy the local deployment. An Exasol
# Personal deployment keeps runtime and data together, so removing it always
# deletes the database content; without --data we refuse instead of silently
# destroying data the documented contract says would be kept.
#
# THE END STATE IS CHECKED, NOT ASSUMED. This used to return the status of its
# last line - a manifest write - so a destroy that failed, a destroy that
# exited 0 and left the deployment behind, and a destroy that never ran at all
# all answered 0, and `exakit uninstall` printed "Database removed" over a
# database that was still there. Returns 1 when anything of the deployment
# remains, with what remains in EXAKIT_TEARDOWN_LEFTOVERS (one item per line)
# and the one command that removes it in EXAKIT_TEARDOWN_REMEDY. Twin of
# Remove-Personal.
personal_teardown() {
    personal_deploy_dir_refresh
    EXAKIT_TEARDOWN_LEFTOVERS=""
    EXAKIT_TEARDOWN_REMEDY=""
    if [ "${1:-}" != "--data" ]; then
        warn "An Exasol Personal deployment keeps the database software and your data together — removing it deletes every table you loaded."
        info "Use 'exakit stop' to stop it without deleting, or 'exakit uninstall' to remove everything."
        return 1
    fi
    # Read BEFORE the destroy: both live in the deployment's own state files,
    # which the destroy deletes, and the check afterwards needs them.
    _ptd_id="$(_personal_deployment_id 2>/dev/null || true)"
    # The folder can already be gone while the container is not: the id the
    # kit recorded at install then names it.
    [ -n "$_ptd_id" ] || _ptd_id="$(manifest_get runtime.deployment_id 2>/dev/null || true)"
    _ptd_port="$(personal_db_port 2>/dev/null || true)"
    # The directory alone decides whether destroy is tried. `exasol info`
    # fails on a deployment the launcher records as "deployment_failed", and
    # gating on it skipped the destroy entirely for exactly the deployments
    # people uninstall to get rid of.
    if [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || personal_deployment_exists; then
        info "Destroying the local Exasol Personal deployment"
        # --auto-approve: the launcher's 'destroy' prompts for confirmation by
        # default. run_logged sends its output to the log, so that prompt is
        # invisible and the install just hangs forever waiting for input. The
        # user has already confirmed at the exakit uninstall level.
        personal_destroy || warn "The launcher could not fully remove the deployment (it said: $PERSONAL_DESTROY_ERROR). If its folder $EXAKIT_PERSONAL_DEPLOY_DIR or a database process is still there, restart the computer and delete the folder."
    else
        info "No active deployment found"
    fi
    # The launcher's destroy can leave an orphaned runner daemon bound to the
    # port when it cannot locate the daemon PID. Reap it unconditionally (even
    # when no deployment was found above, the orphan can outlive the deployment
    # dir) so a future deploy and MCP clients get a clean port.
    personal_reap_orphan_daemon || \
        warn "Could not fully free port $(personal_db_port); if a later deploy fails to bind it, stop the leftover process holding that port and retry."
    if ! personal_teardown_leftovers "$_ptd_id" "$_ptd_port"; then
        return 1
    fi
    manifest_set runtime.status "removed"
    return 0
}

# personal_teardown_leftovers <deployment-id> <port> — what of the deployment
# is still on this machine after a destroy: its directory, the kit's own
# runner listening on its port, and (on Linux/WSL) a container carrying its
# id. Fills EXAKIT_TEARDOWN_LEFTOVERS and EXAKIT_TEARDOWN_REMEDY; returns 1
# when anything remains. A foreign listener on the port is not ours and is not
# counted (personal_reap_orphan_daemon already said so).
personal_teardown_leftovers() {
    personal_deploy_dir_refresh
    _ptl_id="${1:-}"
    _ptl_port="${2:-$EXAKIT_PERSONAL_PORT}"
    EXAKIT_TEARDOWN_LEFTOVERS=""
    _ptl_kill=""; _ptl_rm=""; _ptl_dir=""
    _ptl_add() { EXAKIT_TEARDOWN_LEFTOVERS="${EXAKIT_TEARDOWN_LEFTOVERS:+$EXAKIT_TEARDOWN_LEFTOVERS
}$1"; }
    if command -v lsof >/dev/null 2>&1; then
        for _ptl_pid in $(lsof -nP -iTCP:"$_ptl_port" -sTCP:LISTEN -t 2>/dev/null | sort -u); do
            _personal_is_runner_process "$_ptl_pid" || continue
            _ptl_add "the Exasol runner process (pid $_ptl_pid) still listening on port $_ptl_port"
            _ptl_kill="${_ptl_kill:+$_ptl_kill }$_ptl_pid"
        done
    fi
    # An engine that hangs or refuses (the user is not in the docker group)
    # answered nothing here, so "Database removed" showed over a container that
    # was still there. Its failure is now a warning with the command to check
    # by hand - a warning, not a leftover: it alone never fails the run.
    EXAKIT_TEARDOWN_WARNINGS=""
    # ONLY THE ENGINE THE DEPLOYMENT IS RECORDED ON. An engine this deployment
    # never ran on cannot hold its container, and one that would not answer
    # (a Podman machine that is stopped beside a Docker deployment) only
    # added a warning about it. Both are asked only when the record names
    # neither (or still carries the nano kit's container, whose engine is the
    # OLD database's), as before. Twin of $engines in
    # Find-PersonalTeardownLeftovers.
    _ptl_engines="docker podman"
    _ptl_rec="$(manifest_get runtime.engine 2>/dev/null || true)"
    [ -n "$(manifest_get runtime.container 2>/dev/null || true)" ] && _ptl_rec=""
    case "$_ptl_rec" in
        docker|podman) _ptl_engines="$_ptl_rec" ;;
    esac
    if [ -n "$_ptl_id" ] && personal_engine_platform; then
        for _ptl_eng in $_ptl_engines; do
            command -v "$_ptl_eng" >/dev/null 2>&1 || continue
            _ptl_errf="$(mktemp "${TMPDIR:-/tmp}/exakit-ptl.XXXXXX" 2>/dev/null || true)"
            _ptl_list="$(exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-15}" "$_ptl_eng" ps -a --format '{{.Names}}' 2>"${_ptl_errf:-/dev/null}")"
            _ptl_rc=$?
            if [ "$_ptl_rc" != 0 ]; then
                if [ "$_ptl_rc" = 124 ] || [ "$_ptl_rc" = 137 ]; then
                    _ptl_why="$_ptl_eng did not answer within ${EXAKIT_ENGINE_PROBE_TIMEOUT:-15}s"
                else
                    _ptl_why="$(sed -n '/./{p;q;}' "${_ptl_errf:-/dev/null}" 2>/dev/null | cut -c1-160)"
                    if [ -n "$_ptl_why" ]; then _ptl_why="$_ptl_eng said: $_ptl_why"; else _ptl_why="$_ptl_eng refused: exit $_ptl_rc"; fi
                fi
                # Short enough for one terminal row: the full filter (the
                # deployment id) wrapped onto a second line. It goes to the log.
                # Twin of the same warning in runtime-personal.ps1.
                command -v _exakit_log_file >/dev/null 2>&1 && _exakit_log_file "WARN  Container check for deployment $_ptl_id unanswered ($_ptl_why); check by hand: $_ptl_eng ps -a --filter name=$_ptl_id (or with sudo)"
                EXAKIT_TEARDOWN_WARNINGS="${EXAKIT_TEARDOWN_WARNINGS:+$EXAKIT_TEARDOWN_WARNINGS
}Could not confirm the database container is gone ($_ptl_why). Check: $_ptl_eng ps -a (or sudo $_ptl_eng ps -a)"
            fi
            [ -n "$_ptl_errf" ] && rm -f "$_ptl_errf"
            for _ptl_name in $(printf '%s\n' "$_ptl_list" | \
                    awk -v id="$_ptl_id" '
                        { n = $0; sub(/\r$/, "", n); li = length(id); ln = length(n); f = 0 }
                        n == id { f = 1 }
                        ln > li && (substr(n, 1, li + 1) == id "-" || substr(n, 1, li + 1) == id "_") { f = 1 }
                        ln > li && (substr(n, ln - li) == "-" id || substr(n, ln - li) == "_" id) { f = 1 }
                        f { print n }'); do
                _ptl_add "the $_ptl_eng container $_ptl_name"
                _ptl_rm="${_ptl_rm:+$_ptl_rm; }$_ptl_eng rm -f $_ptl_name"
            done
        done
    fi
    if [ -e "$EXAKIT_PERSONAL_DEPLOY_DIR" ]; then
        _ptl_add "the deployment directory $EXAKIT_PERSONAL_DEPLOY_DIR (the database and ALL its data)"
        # A quote in the path is closed, escaped and reopened ('\'') so the
        # remedy pastes as one argument, like the PowerShell twin's ''.
        _ptl_dir="rm -rf '$(printf '%s' "$EXAKIT_PERSONAL_DEPLOY_DIR" | sed "s/'/'\\\\''/g")'"
    fi
    # THE SAME DEPLOYMENT IN ANOTHER FOLDER. A launcher can move a
    # deployment out of the folder the kit recorded (launcher 2.5 moves
    # ~/.exasol/personal/deployments/<name> to ~/.exasol/launcher/deployments/
    # <name>), and the check above then found nothing while the database was
    # still on disk. A folder in the launcher's deployment folders whose state
    # names this deployment's id is that deployment: named, with the command
    # that removes it, and never removed by the kit, since it is outside the
    # kit's recorded folder. ⇄ twin: the same scan in Find-PersonalTeardownLeftovers.
    if [ -n "$_ptl_id" ]; then
        # The launcher's two deployment folders, as detect.sh spells them, and
        # the folders of every deployment the launcher lists.
        detect_personal_deploy_resolve "$EXAKIT_PERSONAL_DEPLOY_DIR"
        command -v personal_launcher_deployments >/dev/null 2>&1 && { personal_launcher_deployments >/dev/null 2>&1 || true; }
        while IFS= read -r _ptl_root; do
            [ -n "$_ptl_root" ] || continue
            [ -n "${HOME:-}" ] || [ "$_ptl_root" = "$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")" ] || continue
            [ -d "$_ptl_root" ] || continue
            for _ptl_d in "$_ptl_root"/*; do
                [ -d "$_ptl_d" ] && [ ! -L "$_ptl_d" ] || continue
                [ "$_ptl_d" = "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && continue
                [ "$(_personal_deployment_id_in "$_ptl_d")" = "$_ptl_id" ] || continue
                case "
$EXAKIT_TEARDOWN_LEFTOVERS
" in *"directory $_ptl_d ("*) continue ;; esac
                _ptl_add "the deployment directory $_ptl_d (the database and ALL its data)"
                _ptl_dir="${_ptl_dir:+$_ptl_dir; }rm -rf '$(printf '%s' "$_ptl_d" | sed "s/'/'\\\\''/g")'"
            done
        done <<EXAKIT_PTL_ROOTS
$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")
$(dirname "$DETECT_PERSONAL_DEPLOY_LEGACY")
$(dirname "$DETECT_PERSONAL_DEPLOY_NEW")
$(command -v _personal_listed_roots >/dev/null 2>&1 && _personal_listed_roots)
EXAKIT_PTL_ROOTS
    fi
    EXAKIT_TEARDOWN_REMEDY=""
    # Joined with "; ", as the PowerShell twin: a runner that exited before the
    # paste must not stop the rm -rf after it.
    [ -n "$_ptl_kill" ] && EXAKIT_TEARDOWN_REMEDY="kill $_ptl_kill 2>/dev/null"
    [ -n "$_ptl_rm" ]   && EXAKIT_TEARDOWN_REMEDY="${EXAKIT_TEARDOWN_REMEDY:+$EXAKIT_TEARDOWN_REMEDY; }$_ptl_rm"
    [ -n "$_ptl_dir" ]  && EXAKIT_TEARDOWN_REMEDY="${EXAKIT_TEARDOWN_REMEDY:+$EXAKIT_TEARDOWN_REMEDY; }$_ptl_dir"
    [ -z "$EXAKIT_TEARDOWN_LEFTOVERS" ]
}

# personal_launcher_cache_dir — the launcher's download cache (the Nano image,
# the runner, the presets; around 500 MB). The launcher is a Go binary and
# keeps it under os.UserCacheDir(): ~/Library/Caches on macOS, $XDG_CACHE_HOME
# (only when absolute, as Go requires) or ~/.cache elsewhere. Launcher 2.5.0
# keeps it in exasol/launcher/resources there, and deletes the .exasol folder
# earlier launchers used at its first command. So the 2.5.0 folder is the
# answer, unless only the earlier one is on disk. In the launcher's home: the
# kit's private one in mode P, whose wrapper sets XDG_CACHE_HOME to that
# home's .cache whatever the user set, so the user's own XDG_CACHE_HOME (a
# cache a launcher of theirs uses) is never the answer there. Twin of
# Get-PersonalLauncherCacheDir.
personal_launcher_cache_dir() {
    [ -n "${HOME:-}" ] || return 1
    detect_personal_deploy_roots
    _plcd_home="${DETECT_PERSONAL_LAUNCHER_HOME:-$HOME}"
    case "$(uname -s 2>/dev/null)" in
        Darwin) _plcd="$_plcd_home/Library/Caches" ;;
        *)  case "${XDG_CACHE_HOME:-}" in
                /*) _plcd="$XDG_CACHE_HOME" ;;
                *)  _plcd="$_plcd_home/.cache" ;;
            esac
            [ "$_plcd_home" = "$HOME" ] || _plcd="$_plcd_home/.cache" ;;
    esac
    if [ ! -e "$_plcd/exasol/launcher/resources" ] && [ -e "$_plcd/.exasol" ]; then
        printf '%s\n' "$_plcd/.exasol"
    else
        printf '%s\n' "$_plcd/exasol/launcher/resources"
    fi
}

# personal_other_deployments — every entry in the launcher's deployments
# directories other than the kit's own deployment, one per line. Anything there
# (another deployment, or a file nobody can vouch for) keeps the shared cache
# and the state directories in place.
#
# Every place a deployment can live is scanned: beside the configured deploy
# dir, and both of the launcher's default roots (the 2.5.0 one and the one
# before it, detect_personal_deploy_resolve), whichever the kit's deployment is
# in. The launcher cache is shared by every deployment, wherever it lives.
personal_other_deployments() {
    personal_deploy_dir_refresh
    command -v personal_launcher_deployments >/dev/null 2>&1 && { personal_launcher_deployments >/dev/null 2>&1 || true; }
    _pod_parent="$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    _pod_seen=""
    while IFS= read -r _pod_dir; do
        [ -n "${HOME:-}" ] || [ "$_pod_dir" = "$_pod_parent" ] || continue
        # One scan per directory when two of them are the same.
        case "
$_pod_seen
" in *"
$_pod_dir
"*) continue ;; esac
        _pod_seen="$_pod_seen
$_pod_dir"
        [ -d "$_pod_dir" ] || continue
        for _pod_e in "$_pod_dir"/* "$_pod_dir"/.[!.]* "$_pod_dir"/..?*; do
            [ -e "$_pod_e" ] || [ -L "$_pod_e" ] || continue
            [ "$_pod_e" = "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && continue
            printf '%s\n' "$_pod_e"
        done
    done <<EXAKIT_POD_DIRS
$_pod_parent
$(dirname "$DETECT_PERSONAL_DEPLOY_NEW")
$(dirname "$DETECT_PERSONAL_DEPLOY_LEGACY")
$(command -v _personal_listed_roots >/dev/null 2>&1 && _personal_listed_roots)
EXAKIT_POD_DIRS
    return 0
}

# personal_prunable_state_dirs — the launcher's state directories that are
# empty once the kit's deployment is gone, bottom-up, one per line:
# deployments, launcher, .exasol for a 2.5.0 deployment, and deployments,
# personal, .exasol for one from before it (or one in a folder the user chose).
# The same answer before the destroy (what a dry run lists) and after it (what
# is removed). Removal is rmdir only.
personal_prunable_state_dirs() {
    personal_deploy_dir_refresh
    _pp_child="$EXAKIT_PERSONAL_DEPLOY_DIR"
    _pp_d="$(dirname "$_pp_child")"
    _pp_names="deployments personal .exasol"
    # Its ROOT, not one exact folder: the deployment is starter-kit-local now,
    # a 0.3.0 kit's may still be `default`, and either is pruned the same way.
    [ "$_pp_d" = "$DETECT_PERSONAL_DEPLOY_ROOT_NEW" ] && _pp_names="deployments launcher .exasol"
    for _pp_name in $_pp_names; do
        [ "$(basename "$_pp_d")" = "$_pp_name" ] || return 0
        [ -d "$_pp_d" ] && [ ! -L "$_pp_d" ] || return 0
        for _pp_e in "$_pp_d"/* "$_pp_d"/.[!.]* "$_pp_d"/..?*; do
            [ -e "$_pp_e" ] || [ -L "$_pp_e" ] || continue
            [ "$_pp_e" = "$_pp_child" ] || return 0
        done
        printf '%s\n' "$_pp_d"
        _pp_child="$_pp_d"
        _pp_d="$(dirname "$_pp_d")"
    done
}

personal_upgrade_plan() {
    personal_deploy_dir_refresh
    _current="$1"
    _latest="$2"
    warn "Exasol Personal major upgrade detected: ${_current:-unknown} -> $_latest."
    warn "Personal keeps runtime and database content together in the local deployment."
    info "No destructive action was taken."
    info "Deployment: $EXAKIT_PERSONAL_DEPLOY_DIR"
    info "Follow the Exasol Personal $_latest migration/redeployment guidance for your data."
}

personal_upgrade_backup() {
    personal_deploy_dir_refresh
    _current="$1"
    _latest="$2"
    require_cmd tar "tar"
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || \
        die "No Exasol Personal deployment directory found at $EXAKIT_PERSONAL_DEPLOY_DIR; nothing was backed up."
    if [ "$(personal_status 2>/dev/null || true)" = "running" ] && [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        die "Stop Exasol Personal before backing up for a major upgrade: exakit stop"
    fi

    _backup_dir="$EXAKIT_HOME/backups"
    mkdir -p "$_backup_dir"
    chmod 700 "$_backup_dir" 2>/dev/null || true
    _stamp="$(date +%Y%m%d-%H%M%S)"
    _safe_current="$(printf '%s' "${_current:-unknown}" | tr '/ :' '---')"
    _safe_latest="$(printf '%s' "${_latest:-unknown}" | tr '/ :' '---')"
    _backup="$_backup_dir/personal-upgrade-${_safe_current}-to-${_safe_latest}-${_stamp}.tar.gz"
    _parent="$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    _base="$(basename "$EXAKIT_PERSONAL_DEPLOY_DIR")"

    info "Creating Exasol Personal deployment backup"
    if ! tar -czf "$_backup" -C "$_parent" "$_base" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        rm -f "$_backup"
        die "Could not create the Personal backup; no update was applied."
    fi
    chmod 600 "$_backup" 2>/dev/null || true
    if exakit_can_run_python; then
        manifest_set backups.personal_upgrade.latest "$_backup"
        manifest_set backups.personal_upgrade.created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        manifest_set backups.personal_upgrade.from "${_current:-unknown}"
        manifest_set backups.personal_upgrade.to "$_latest"
    else
        warn "Backup was created, but the manifest could not be updated because no Python runtime is available."
    fi
    ok "Personal deployment backup created: $_backup"
}

# --- the update from a 0.3.0 kit: one restart -------------------------------
# A 0.3.0 kit's database is the launcher's deployment `default`, run by
# Exasol Personal 2.4, which set its 20-session limit. The update makes it the
# deployment starter-kit-local on 2.5 without the limit, in ONE restart, and
# nothing 2.5 runs before its folder has its new name:
#   1. whether it runs is noted, its id recorded (the follow in 4 needs it), a
#      copy of the launcher kept, and the database stopped with the launcher
#      that runs it now, the old one (personal_update_stop);
#   2. its folder is renamed in the same root to starter-kit-local, the
#      records with it, said with approved line 5 (personal_update_rename);
#   3. the launcher is replaced (not when it is current already), its copy
#      kept until the new one has answered;
#   4. the new launcher's first command moves the folder to its own root, and
#      the kit's record follows it by its id (personal_deploy_dir_refresh);
#   5. the 20-session limit is lifted while it is stopped, and the database is
#      started once, only when it ran before (personal_update_start_again).
# A failure from 1 to the end of 3 puts back what was changed (the launcher,
# the folder's name, the records), starts the database again when it ran, and
# says why (personal_update_undo): the next `exakit update` tries again. The
# owner stays as recorded: a database the user let the 0.3.0 kit use stays
# theirs, renamed and upgraded with that permission, never destroyed.
# personal_update runs it for the kit's own launcher, personal_update_user for
# a database run by the user's own (which is never replaced: the kit's own takes
# over), personal_update_current with no launcher to replace.

# personal_update_rename_source — the folder of the kit's database while it is
# still a 0.3.0 kit's `default`, in one of the two roots of the launcher's
# home: the folder the update renames. Nothing otherwise: a database named
# starter-kit-local already, a folder the user chose
# (EXAKIT_PERSONAL_DEPLOY_DIR), one the kit may not act on
# (exakit_personal_db_state), or no record of one. Asks no launcher while the
# recorded folder is there.
personal_update_rename_source() {
    [ -f "${EXAKIT_MANIFEST:-}" ] || return 0
    personal_deploy_dir_refresh
    [ "$(basename "${EXAKIT_PERSONAL_DEPLOY_DIR:-}")" = default ] && [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 0
    detect_personal_deploy_roots
    case "$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")" in
        "$DETECT_PERSONAL_DEPLOY_ROOT_NEW"|"$DETECT_PERSONAL_DEPLOY_ROOT_LEGACY") ;;
        *) return 0 ;;
    esac
    [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] || return 0
    [ "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" = "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 0
    [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] || return 0
    printf '%s\n' "$EXAKIT_PERSONAL_DEPLOY_DIR"
}

# _personal_update_rename_check <from> — 0 when <from> can be renamed to
# starter-kit-local now: no starter-kit-local in its root, nor in the 2.5 root
# the next launcher moves it to (launcher 2.5 never moves a folder onto one of
# the same name, it warns on every run instead), and no launcher command holds
# it (a .dirmutex.* marker). Otherwise non-zero, the reason in
# PERSONAL_RENAME_ERROR: exists (the folder in PERSONAL_RENAME_BLOCKER) or
# locked.
_personal_update_rename_check() {
    PERSONAL_RENAME_ERROR=""
    PERSONAL_RENAME_BLOCKER=""
    detect_personal_deploy_roots
    for _purc in "$(dirname "$1")/$EXAKIT_PERSONAL_DEPLOYMENT" "$DETECT_PERSONAL_DEPLOY_NEW"; do
        [ -e "$_purc" ] || [ -L "$_purc" ] || continue
        PERSONAL_RENAME_ERROR=exists
        PERSONAL_RENAME_BLOCKER="$_purc"
        return 1
    done
    for _purc in "$1"/.dirmutex.*; do
        [ -e "$_purc" ] || continue
        PERSONAL_RENAME_ERROR=locked
        return 1
    done
    return 0
}

# _personal_update_not_renamed — the database was not renamed
# (PERSONAL_RENAME_ERROR says why): said, and started again when it ran. The
# update stops there, with nothing changed.
_personal_update_not_renamed() {
    case "${PERSONAL_RENAME_ERROR:-}" in
        exists)  _punr_why="$(ui_tilde "${PERSONAL_RENAME_BLOCKER:-$PERSONAL_UPDATE_TO}") already exists" ;;
        locked)  _punr_why="another Exasol Personal command is using it" ;;
        noid)    _punr_why="the kit could not read its id" ;;
        records) _punr_why="the kit could not write its record" ;;
        *)       _punr_why="its folder could not be renamed" ;;
    esac
    warn "The database '$(basename "$PERSONAL_UPDATE_FROM")' was not renamed to '$EXAKIT_PERSONAL_DEPLOYMENT', because $_punr_why. Nothing was changed."
    exakit_note_failure "The database '$(basename "$PERSONAL_UPDATE_FROM")' was not renamed to '$EXAKIT_PERSONAL_DEPLOYMENT', because $_punr_why"
    personal_update_start_again || true
    info "The next exakit update tries again."
}

# personal_update_record_id — runtime.deployment_id, read from the folder the
# kit's database is in now, when the record has none (a 0.3.0 kit kept no id,
# and kept none for a database of the user's): after the rename and the move
# the record follows the database by it. Non-zero when none is recorded and
# none can be read.
personal_update_record_id() {
    [ -z "$(manifest_get runtime.deployment_id 2>/dev/null || true)" ] || return 0
    personal_deploy_dir_refresh
    _puri="$(_personal_deployment_id_in "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true)"
    [ -n "$_puri" ] || return 1
    ( manifest_set runtime.deployment_id "$_puri" ) >/dev/null 2>&1 || return 1
    return 0
}

# _personal_update_runs — 0 while the kit's database runs, or comes up.
_personal_update_runs() {
    case "$(personal_status 2>/dev/null || true)" in running|starting) return 0 ;; esac
    return 1
}

# _personal_update_stopped — 0 only when the launcher itself says the database
# is stopped (or was never deployed): the one answer its folder may be renamed
# or moved on. No answer, an error, a launcher that is not there and every
# other state are not that answer. Asked twice: a launcher 2.5 can move a
# stopped folder of the legacy root by the command that asks it.
_personal_update_stopped() {
    _personal_update_runs && return 1
    for _pus_try in 1 2; do
        case "$(personal_launcher_state 2>/dev/null || true)" in stopped|initialized) return 0 ;; esac
        command -v _personal_forget_followed >/dev/null 2>&1 && _personal_forget_followed
        personal_deploy_dir_refresh
    done
    return 1
}

# personal_update_keep_launcher <launcher> — the copy step 3 puts back: the
# launcher binary that runs the database now (PERSONAL_UPDATE_BIN), copied
# into the kit's cache (PERSONAL_UPDATE_COPY) before anything changes. No file
# there is nothing to keep. Non-zero when the copy cannot be made.
# A COPY ALREADY THERE, OTHER THAN THE LAUNCHER IN PLACE, IS NEVER WRITTEN
# OVER OR REMOVED: it is the only one left of a launcher an earlier update
# replaced and could not put back, at the path its undo named. This update
# keeps its own copy in a folder of its own beside it (update-<id>), so its
# undo puts back only what this update replaced. Twin of
# Save-PersonalUpdateLauncherCopy.
personal_update_keep_launcher() {
    PERSONAL_UPDATE_BIN="$1"
    PERSONAL_UPDATE_COPY=""
    [ -f "$1" ] || return 0
    _pukl="${EXAKIT_CACHE_DIR:-${EXAKIT_HOME:-${HOME:-}/.exasol-starter-kit}/cache}/personal-launcher-before-update"
    mkdir -p "$_pukl" 2>/dev/null || return 1
    if [ -f "$_pukl/exasol" ] && ! cmp -s "$1" "$_pukl/exasol"; then
        command -v _exakit_log_file >/dev/null 2>&1 && \
            _exakit_log_file "INFO  the launcher copy an earlier update left at $_pukl/exasol is kept as it is"
        _pukl="$(mktemp -d "$_pukl/update-XXXXXXXX" 2>/dev/null)" || return 1
    fi
    rm -f "$_pukl/exasol"
    cp -p "$1" "$_pukl/exasol" 2>/dev/null || { rm -f "$_pukl/exasol"; return 1; }
    PERSONAL_UPDATE_COPY="$_pukl/exasol"
    return 0
}

# personal_update_drop_launcher_copy — the copy, once the new launcher has
# answered (or the old one is back). Only this update's: a copy an earlier
# update left stays (personal_update_keep_launcher).
personal_update_drop_launcher_copy() {
    if [ -n "${PERSONAL_UPDATE_COPY:-}" ]; then
        rm -f "$PERSONAL_UPDATE_COPY"
        rmdir "$(dirname "$PERSONAL_UPDATE_COPY")" 2>/dev/null || true
    fi
    PERSONAL_UPDATE_COPY=""
}

# _personal_update_launcher_answers — 0 when the launcher in place has run: it
# answers `version` with a version, asked as the kit runs it (personal_cli,
# the wrapper in mode P). One whose bytes are still the copy's was not
# replaced, and nothing that is not there can be asked: neither has anything
# new to prove.
_personal_update_launcher_answers() {
    if [ -n "${PERSONAL_UPDATE_COPY:-}" ] && [ -f "${PERSONAL_UPDATE_BIN:-}" ] && \
       cmp -s "$PERSONAL_UPDATE_BIN" "$PERSONAL_UPDATE_COPY"; then
        return 0
    fi
    [ -e "${PERSONAL_UPDATE_BIN:-}" ] || return 0
    # CAPTURED FIRST, THEN MATCHED, never `| grep -q`: grep exits at its first
    # match, and a launcher that writes a line after its version (an update
    # notice) then dies of SIGPIPE, which pipefail (exakit and the setup
    # scripts run with it) reports as a launcher that did not answer: the
    # update was put back over a launcher that ran. As personal_tls_answers.
    # ITS FIRST COMMAND IS SLOW, AND A SLOW ONE IS NOT A BROKEN ONE: Exasol
    # Personal 2.5 first moves every deployment of the older root (a rename
    # and a running check each, the old cache deleted, the SQL history moved).
    # So this `version` gets EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT (120 s), not the
    # probes' few, and one that still runs out of time (124) is asked once more
    # (the move is done by then) before the update is put back: a timeout never
    # undoes an update that went through. Logged, never said. Twin of
    # Test-PersonalUpdateLauncherAnswers.
    for _pula_try in 1 2; do
        _pula_rc=0
        _pula="$(exakit_run_bounded "$EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT" "$(personal_cli)" version 2>/dev/null)" || _pula_rc=$?
        if grep -Eq '^[[:space:]]*v?[0-9]+\.[0-9]+' <<EXAKIT_PULA_EOF
$_pula
EXAKIT_PULA_EOF
        then
            return 0
        fi
        [ "$_pula_rc" = 124 ] || return 1
        command -v _exakit_log_file >/dev/null 2>&1 && \
            _exakit_log_file "WARN  the new launcher's first command ran out of time: asked once more"
    done
    return 1
}

# AN UPDATE OWES A START (Q8) from its stop to the start at its end, on record
# (runtime.start_owed): one cut short in between left a stopped database that
# the next `exakit update` called current. The next one starts it
# (personal_update_finish_start). A start, or a stop the user asks for, settles it.
_personal_start_owed() {
    grep -qF '"start_owed"' "${EXAKIT_MANIFEST:-/nonexistent}" 2>/dev/null && \
        [ -n "$(manifest_get runtime.start_owed 2>/dev/null || true)" ]
}
_personal_start_owe() { ( manifest_set runtime.start_owed true ) >/dev/null 2>&1 || true; }
_personal_start_settled() {
    grep -qF '"start_owed"' "${EXAKIT_MANIFEST:-/nonexistent}" 2>/dev/null || return 0
    ( manifest_del runtime.start_owed ) >/dev/null 2>&1 || true
}

# personal_update_finish_start — the start an update that was cut short still
# owes. 0 when there is none, or it runs. 1 when it did not start (said). 12
# when EXAKIT_CONFIRM_RUNTIME_UPDATE=0 holds it back.
personal_update_finish_start() {
    _personal_start_owed || return 0
    [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] || return 0
    personal_deploy_dir_refresh
    if [ ! -d "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || _personal_update_runs; then
        _personal_start_settled
        return 0
    fi
    if [ "$(exakit_runtime_update_preanswer)" = no ]; then
        warn "personal $(manifest_get runtime.version 2>/dev/null || true) -> ${EXAKIT_PERSONAL_VERSION:-$(personal_launcher_version 2>/dev/null || true)} was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        info "Apply it when convenient:  exakit update --yes"
        return 12
    fi
    PERSONAL_UPDATE_RAN=1
    PERSONAL_UPDATE_LIFTED=0
    personal_update_start_again always
}

# personal_update_stop [<line>] — step 1's stop. PERSONAL_UPDATE_RAN is 1 when
# the database ran: it is started again at the end, or after an undo
# (personal_update_start_again). A running one is stopped with the launcher
# that runs it now, after <line> (the caller's stop line, when it has one to
# say). Non-zero when it did not stop: said, nothing changed, and one that went
# down without stopping as asked is started again.
# A FOLDER THAT IS TO BE RENAMED (PERSONAL_UPDATE_FROM) IS NEVER TOUCHED ON A
# GUESS: one the launcher does not say is stopped (_personal_update_stopped) is
# asked to stop, and unless it then says so, the update ends here.
personal_update_stop() {
    PERSONAL_UPDATE_RAN=0
    if _personal_update_runs; then
        PERSONAL_UPDATE_RAN=1
    elif [ -z "${PERSONAL_UPDATE_FROM:-}" ] || _personal_update_stopped; then
        _personal_start_owe
        return 0
    fi
    [ -z "${1:-}" ] || warn "$1"
    if ( personal_stop ); then
        PERSONAL_UPDATE_RAN=1
        if [ -n "${PERSONAL_UPDATE_FROM:-}" ]; then
            _personal_update_stopped && { _personal_start_owe; return 0; }
        elif ! _personal_update_runs; then
            _personal_start_owe
            return 0
        fi
    fi
    warn "The database did not stop, so it was not updated. Nothing was changed."
    exakit_note_failure "The database did not stop, so it was not updated"
    personal_update_start_again || true
    return 1
}

# personal_update_rename — step 2: the folder PERSONAL_UPDATE_FROM renamed to
# starter-kit-local in its root, and the kit's records with it
# (personal_rename_deployment), said with approved line 5. PERSONAL_UPDATE_RENAMED
# is 1 when done. Nothing to rename is 0. Non-zero when it was not renamed:
# said, nothing changed, and the database started again when it ran.
personal_update_rename() {
    PERSONAL_UPDATE_RENAMED=0
    [ -n "${PERSONAL_UPDATE_FROM:-}" ] || return 0
    # Where it is now: a launcher 2.5 that runs it moves a stopped folder out
    # of the legacy root on its next command (the check after the stop), and
    # the record follows it there by its id.
    _personal_forget_followed
    personal_deploy_dir_refresh
    if [ "$EXAKIT_PERSONAL_DEPLOY_DIR" != "$PERSONAL_UPDATE_FROM" ] && \
       [ "$(basename "$EXAKIT_PERSONAL_DEPLOY_DIR")" = default ] && [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ]; then
        PERSONAL_UPDATE_FROM="$EXAKIT_PERSONAL_DEPLOY_DIR"
        PERSONAL_UPDATE_TO="$(dirname "$PERSONAL_UPDATE_FROM")/$EXAKIT_PERSONAL_DEPLOYMENT"
    fi
    info "Renaming the database to '$EXAKIT_PERSONAL_DEPLOYMENT'."
    if _personal_update_rename_check "$PERSONAL_UPDATE_FROM" && \
       personal_rename_deployment "$PERSONAL_UPDATE_FROM" "$PERSONAL_UPDATE_TO"; then
        PERSONAL_UPDATE_RENAMED=1
        return 0
    fi
    _personal_update_not_renamed
    return 1
}

# personal_update_prepare <stop line> — steps 1 and 2, before a launcher is
# replaced: a copy of the launcher kept (PERSONAL_UPDATE_BIN, set by the
# caller), and, for a database of the kit's to act on, its id recorded, the
# database stopped when it runs (<stop line> said first, when not empty), and
# a 0.3.0 `default` renamed to starter-kit-local. A rename that cannot happen
# is found before anything stops. Non-zero when the update cannot go on:
# said, nothing changed, the database running again when it ran.
personal_update_prepare() {
    PERSONAL_UPDATE_RAN=0
    PERSONAL_UPDATE_RENAMED=0
    PERSONAL_UPDATE_FROM=""
    PERSONAL_UPDATE_TO=""
    PERSONAL_UPDATE_OTHERS=""
    if ! personal_update_keep_launcher "$PERSONAL_UPDATE_BIN"; then
        warn "Exasol Personal was not updated, because the kit could not keep a copy of the launcher it replaces. Nothing was changed."
        exakit_note_failure "Exasol Personal was not updated, because the kit could not keep a copy of the launcher it replaces"
        return 1
    fi
    [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] || return 0
    personal_deploy_dir_refresh
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 0
    PERSONAL_UPDATE_FROM="$(personal_update_rename_source)"
    if [ -n "$PERSONAL_UPDATE_FROM" ]; then
        PERSONAL_UPDATE_TO="$(dirname "$PERSONAL_UPDATE_FROM")/$EXAKIT_PERSONAL_DEPLOYMENT"
        if ! _personal_update_rename_check "$PERSONAL_UPDATE_FROM"; then
            _personal_update_not_renamed
            personal_update_drop_launcher_copy
            return 1
        fi
    fi
    if ! personal_update_record_id && [ -n "$PERSONAL_UPDATE_FROM" ]; then
        PERSONAL_RENAME_ERROR=noid
        _personal_update_not_renamed
        personal_update_drop_launcher_copy
        return 1
    fi
    if ! personal_update_stop "${1:-}" || ! personal_update_rename; then
        personal_update_drop_launcher_copy
        return 1
    fi
    # The other deployments in the legacy root now, before any 2.5 command:
    # the new launcher's first one moves each stopped one into its own root,
    # and an undo does not bring them back (personal_update_moved_others).
    PERSONAL_UPDATE_OTHERS=""
    detect_personal_deploy_roots
    for _pup_o in "$DETECT_PERSONAL_DEPLOY_ROOT_LEGACY"/*; do
        [ -d "$_pup_o" ] || continue
        [ "$_pup_o" != "${PERSONAL_UPDATE_TO:-}" ] && [ "$_pup_o" != "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || continue
        [ -f "$_pup_o/.exasolLauncherState.json" ] || [ -f "$_pup_o/deployment.json" ] || continue
        PERSONAL_UPDATE_OTHERS="$PERSONAL_UPDATE_OTHERS${PERSONAL_UPDATE_OTHERS:+
}$(basename "$_pup_o")"
    done
    return 0
}

# personal_update_moved_others — the names of the deployments
# personal_update_prepare found beside the kit's in the legacy root that are
# now in the 2.5 root instead, joined for a sentence ('a', 'a' and 'b'): a new
# launcher that ran once before its undo moved them, and the old launcher,
# put back, does not look there. Nothing when none moved.
personal_update_moved_others() {
    [ -n "${PERSONAL_UPDATE_OTHERS:-}" ] || return 0
    detect_personal_deploy_roots
    _pumo=""
    _pumo_n=0
    while IFS= read -r _pumo_name; do
        [ -n "$_pumo_name" ] || continue
        [ ! -e "$DETECT_PERSONAL_DEPLOY_ROOT_LEGACY/$_pumo_name" ] && [ -d "$DETECT_PERSONAL_DEPLOY_ROOT_NEW/$_pumo_name" ] || continue
        _pumo_n=$((_pumo_n + 1))
        _pumo="$_pumo${_pumo:+|}'$_pumo_name'"
    done <<EXAKIT_PUMO_EOF
$PERSONAL_UPDATE_OTHERS
EXAKIT_PUMO_EOF
    [ "$_pumo_n" -gt 0 ] || return 0
    case "$_pumo_n" in
        1) printf '%s\n' "$_pumo" ;;
        *) _pumo_last="${_pumo##*|}"
           printf '%s and %s\n' "$(printf '%s' "${_pumo%|*}" | sed 's/|/, /g')" "$_pumo_last" ;;
    esac
    printf '%s\n' "$_pumo_n"
}

# personal_update_undo <why> — a launcher swap that did not work, put back: the
# old launcher from its copy (with the kit's receipt, when it is the kit's), the
# folder renamed back to its 0.3.0 name wherever the new launcher left it, and
# the records with it; the database started again when it ran. Said, with
# <why>, and with what could not be put back.
personal_update_undo() {
    _puu_whole=1
    # The new launcher went into the kit folder beside a 0.3.0 one at
    # ~/.local/bin/exasol, which was never touched: the new one goes, and the
    # receipt names the old one again.
    if [ -n "${PERSONAL_UPDATE_OLD_BIN:-}" ] && [ -f "$PERSONAL_UPDATE_OLD_BIN" ]; then
        rm -f "$EXAKIT_PERSONAL_KIT_BIN" "$EXAKIT_PERSONAL_KIT_BIN.new"
        ( exakit_record_ownership personal "${PERSONAL_UPDATE_RECEIPT:-kit}" "$PERSONAL_UPDATE_OLD_BIN" ) >/dev/null 2>&1 && \
            personal_retire_forget
        [ "${PERSONAL_UPDATE_RECEIPT:-kit}" = kit ] || ( manifest_del components.personal.user_launcher ) >/dev/null 2>&1 || true
    fi
    if [ -n "${PERSONAL_UPDATE_COPY:-}" ] && [ -f "$PERSONAL_UPDATE_COPY" ]; then
        if mv -f "$PERSONAL_UPDATE_COPY" "$PERSONAL_UPDATE_BIN" 2>/dev/null || \
           cp -p "$PERSONAL_UPDATE_COPY" "$PERSONAL_UPDATE_BIN" 2>/dev/null; then
            if [ "${PERSONAL_UPDATE_RECEIPT:-}" = kit ]; then
                ( exakit_record_ownership personal kit "$EXAKIT_PERSONAL_BIN" ) >/dev/null 2>&1 || true
            fi
            personal_update_drop_launcher_copy
        else
            _puu_whole=0
            warn "The launcher could not be put back. A copy of it is at $(ui_tilde "$PERSONAL_UPDATE_COPY")."
        fi
    fi
    if [ "${PERSONAL_UPDATE_RENAMED:-0}" = 1 ]; then
        # Moved by the new launcher's first command: into its own root, under
        # the same name, carrying the id the kit recorded.
        _puu_at="$PERSONAL_UPDATE_TO"
        if [ ! -d "$_puu_at" ]; then
            detect_personal_deploy_roots
            _puu_at="$DETECT_PERSONAL_DEPLOY_NEW"
            [ -d "$_puu_at" ] && [ -n "$(manifest_get runtime.deployment_id 2>/dev/null || true)" ] && \
                [ "$(_personal_deployment_id_in "$_puu_at" 2>/dev/null || true)" = "$(manifest_get runtime.deployment_id 2>/dev/null || true)" ] || \
                _puu_at=""
        fi
        # The records in subshells, as in personal_rename_deployment: a
        # manifest that cannot be written never skips the start below.
        # Like every rename, only while the launcher, asked now, says stopped.
        if [ -n "$_puu_at" ] && _personal_says_stopped "$_puu_at" && personal_rename_deployment "$_puu_at" "$PERSONAL_UPDATE_FROM"; then
            ( personal_rename_records "$PERSONAL_UPDATE_TO" "$PERSONAL_UPDATE_FROM" ) >/dev/null 2>&1 || true
            PERSONAL_UPDATE_RENAMED=0
        else
            _puu_whole=0
            [ -z "$_puu_at" ] || [ "$_puu_at" = "$PERSONAL_UPDATE_TO" ] || \
                ( personal_rename_records "$PERSONAL_UPDATE_TO" "$_puu_at" ) >/dev/null 2>&1 || true
            warn "The database could not be renamed back to '$(basename "$PERSONAL_UPDATE_FROM")'. It keeps the name '$EXAKIT_PERSONAL_DEPLOYMENT', and the kit uses it under that name."
        fi
        _personal_forget_followed
    fi
    # THE USER'S OTHER DATABASES are not "as they were" when the new launcher
    # ran once before this undo: its first command moved each stopped one from
    # the legacy root into its own, and the old launcher, put back, does not
    # look there. Said where they are now.
    _puu_moved="$(personal_update_moved_others)"
    _puu_moved_n="$(printf '%s\n' "$_puu_moved" | sed -n 2p)"
    _puu_moved="$(printf '%s\n' "$_puu_moved" | sed -n 1p)"
    if [ "$_puu_whole" = 1 ] && [ -z "$_puu_moved" ]; then
        warn "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because $1. The launcher and the database are as they were."
    elif [ "$_puu_whole" = 1 ]; then
        warn "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because $1. The launcher and the database '$(basename "${PERSONAL_UPDATE_FROM:-$EXAKIT_PERSONAL_DEPLOY_DIR}")' are as they were."
    else
        warn "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because $1."
    fi
    if [ -n "$_puu_moved" ]; then
        detect_personal_deploy_roots
        if [ "$_puu_moved_n" = 1 ]; then
            info "Your other database $_puu_moved is now in $(ui_tilde "$DETECT_PERSONAL_DEPLOY_ROOT_NEW"), where Exasol Personal 2.5 keeps it."
        else
            info "Your other databases $_puu_moved are now in $(ui_tilde "$DETECT_PERSONAL_DEPLOY_ROOT_NEW"), where Exasol Personal 2.5 keeps them."
        fi
    fi
    exakit_note_failure "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because $1"
    personal_update_start_again || true
    info "The next exakit update tries again."
}

# personal_update_start_again [always] — step 5's start, and the one after an
# undo: the database started once, and waited for as `exakit start` does, when
# it does not run now: after an update that went through ("always", Q8)
# whatever it was before, after an undo only when it ran before the update
# (PERSONAL_UPDATE_RAN). When this
# update lifted the 20-session limit (PERSONAL_UPDATE_LIFTED) and the start
# fails, the file is put back and the database started with it, as the lift
# itself does. A start that fails is said, with the command that starts it.
personal_update_start_again() {
    # "always" (Q8): an update that went through starts the database at the
    # end even when it was stopped before. An undo starts only one that ran.
    if [ "${PERSONAL_UPDATE_RAN:-0}" != 1 ]; then
        [ "${1:-}" = always ] || { _personal_start_settled; return 0; }
        personal_deploy_dir_refresh
        [ -d "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || { _personal_start_settled; return 0; }
    fi
    _personal_update_runs && { _personal_start_settled; return 0; }
    _personal_session_limit_start && { _personal_start_settled; return 0; }
    # Said below when it does not come up, with the command that starts it.
    _personal_start_settled
    # A start that Docker refused says nothing about the limit: the lift stands
    # and applies at the next start.
    if [ "${PERSONAL_UPDATE_LIFTED:-0}" = 1 ] && _personal_start_engine_ok; then
        PERSONAL_UPDATE_LIFTED=0
        _personal_session_limit_restore "$(personal_session_limit_conf).before-session-limit"
        ( manifest_del runtime.session_limit && manifest_del runtime.session_limit_lifted_at ) >/dev/null 2>&1 || true
        if _personal_session_limit_start; then
            warn "The 20-session limit was not removed, because the database did not start without it. The file is as it was, and the database is running again."
            return 0
        fi
        warn "The 20-session limit was not removed, because the database did not start without it. The file is as it was, but the database did not start again. Start it with: exakit start"
        return 1
    fi
    warn "The database did not start again. Start it with: exakit start"
    return 1
}

# The steps after a swap or a rename run in a subshell (their die ends them
# only, and the one start still comes). _personal_update_steps_begin, before
# it: what the record says of the limit, and a file the subshell's own
# results come back through (_personal_update_steps_carry, its last command:
# EXAKIT_PERSONAL_PASSWORD_CHANGE, which callers read after the update).
# _personal_update_after_steps, after it: this shell takes over, the
# refresh's memory dropped (the folder is read where the record has it now),
# PERSONAL_UPDATE_LIFTED set when the steps lifted the limit
# (personal_update_start_again puts the file back when the start fails
# without it), and the carried results read back.
_personal_update_steps_begin() {
    PERSONAL_UPDATE_STEPS_LIMIT="$(manifest_get runtime.session_limit 2>/dev/null || true)"
    PERSONAL_UPDATE_STEPS_CARRY="$(mktemp "${TMPDIR:-/tmp}/exakit-update-steps.XXXXXX" 2>/dev/null || true)"
    return 0
}
_personal_update_steps_carry() {
    [ -z "${PERSONAL_UPDATE_STEPS_CARRY:-}" ] || \
        printf '%s\n' "${EXAKIT_PERSONAL_PASSWORD_CHANGE:-}" > "$PERSONAL_UPDATE_STEPS_CARRY" 2>/dev/null || true
    return 0
}
_personal_update_after_steps() {
    _personal_forget_followed
    PERSONAL_UPDATE_LIFTED=0
    [ "${PERSONAL_UPDATE_STEPS_LIMIT:-}" != lifted ] && \
        [ "$(manifest_get runtime.session_limit 2>/dev/null || true)" = lifted ] && PERSONAL_UPDATE_LIFTED=1
    if [ -n "${PERSONAL_UPDATE_STEPS_CARRY:-}" ]; then
        if [ -s "$PERSONAL_UPDATE_STEPS_CARRY" ]; then
            EXAKIT_PERSONAL_PASSWORD_CHANGE="$(cat "$PERSONAL_UPDATE_STEPS_CARRY" 2>/dev/null || true)"
        fi
        rm -f "$PERSONAL_UPDATE_STEPS_CARRY"
    fi
    PERSONAL_UPDATE_STEPS_CARRY=""
    return 0
}

# personal_update_lift — step 5's lift: personal_lift_session_limit, on a
# database the update stopped, so the file alone changes and the start after
# it applies it. PERSONAL_UPDATE_LIFTED is 1 when it was lifted now.
personal_update_lift() {
    PERSONAL_UPDATE_LIFTED=0
    _pul_before="$(manifest_get runtime.session_limit 2>/dev/null || true)"
    personal_lift_session_limit || return 1
    [ "$_pul_before" != lifted ] && [ "$(manifest_get runtime.session_limit 2>/dev/null || true)" = lifted ] && \
        PERSONAL_UPDATE_LIFTED=1
    return 0
}

# personal_update_current — the update with no launcher to replace: one at
# 2.5.0 or later over a database that is still a 0.3.0 kit's `default`
# (launcher 2.5 moved it into its own root, or it ran when the launcher was
# swapped). Steps 1, 2, 4 and 5 in one restart: stopped when it runs (a line
# says it first), renamed to starter-kit-local, its 20-session limit lifted
# while it is stopped, started again once. Nothing to rename, or a launcher
# before 2.5.0 (the rename waits for the launcher's own update): nothing done
# here, the limit is the caller's (personal_lift_session_limit). Returns 0
# when done or nothing to do, 1 when not done: said, nothing changed, the
# database running again when it ran. 12 when EXAKIT_CONFIRM_RUNTIME_UPDATE=0
# keeps the database as it is.
personal_update_current() {
    PERSONAL_UPDATE_RAN=0
    PERSONAL_UPDATE_RENAMED=0
    PERSONAL_UPDATE_LIFTED=0
    PERSONAL_UPDATE_FROM="$(personal_update_rename_source)"
    if [ -n "$PERSONAL_UPDATE_FROM" ]; then
        # Its id first, while its folder is where the record says: the
        # launcher's `version` below can move a stopped one.
        personal_update_record_id || true
        _pucu_ver="$(personal_launcher_version 2>/dev/null || true)"
        if [ -z "$_pucu_ver" ] || personal_deployment_outranks 2.5.0 "$_pucu_ver"; then
            PERSONAL_UPDATE_FROM=""
        fi
    fi
    [ -n "$PERSONAL_UPDATE_FROM" ] || return 0
    # A deliberate no keeps the database as it is, as on every other arm.
    if [ "$(exakit_runtime_update_preanswer)" = no ]; then
        warn "personal $(manifest_get runtime.version 2>/dev/null || true) -> ${EXAKIT_PERSONAL_VERSION:-$_pucu_ver} was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        info "Apply it when convenient:  exakit update --yes"
        return 12
    fi
    PERSONAL_UPDATE_TO="$(dirname "$PERSONAL_UPDATE_FROM")/$EXAKIT_PERSONAL_DEPLOYMENT"
    if ! _personal_update_rename_check "$PERSONAL_UPDATE_FROM"; then
        _personal_update_not_renamed
        return 1
    fi
    if ! personal_update_record_id; then
        PERSONAL_RENAME_ERROR=noid
        _personal_update_not_renamed
        return 1
    fi
    personal_update_stop "The database stops and starts again once, to rename it to '$EXAKIT_PERSONAL_DEPLOYMENT'." || return 1
    personal_update_rename || return 1
    # Followed by its id, wherever the launcher has it now, and the limit
    # lifted while it is stopped. In a subshell, as in personal_update: a
    # record that cannot be written ends only these steps, the one start below
    # still comes, and then the run ends with that step's own error.
    _personal_update_steps_begin
    _pucu_after=0
    (
    _personal_forget_followed
    personal_deploy_dir_refresh
    personal_record_engine_own
    personal_update_lift || true
    _personal_update_steps_carry
    ) || _pucu_after=$?
    _personal_update_after_steps
    personal_update_start_again always || true
    [ "$_pucu_after" = 0 ] || exit "$_pucu_after"
    # The MCP server the 0.3.0 kit set up beside it, recorded as the kit's
    # when that is provable (mcp_sidecar_claim): the uninstall removes it.
    # After the one start: its proof can need a download (uv, PyYAML), which
    # never lengthens the time the database is down.
    command -v mcp_sidecar_claim >/dev/null 2>&1 && mcp_sidecar_claim
    command -v exakit_forget_update_failure >/dev/null 2>&1 && exakit_forget_update_failure
    return 0
}

# _personal_update_user_case <advertised> [preview] — 0 when
# personal_update_user has an update to make: a database the user let the
# 0.3.0 kit use (runtime.ownership user), one the kit may act on and on disk,
# still run by a launcher of theirs (_puus_bin, at _puus_have) because the kit
# has none of its own yet, on the major line of <advertised> (_puus_want), and
# not made by a newer Exasol Personal than that, which it could not run. 10
# otherwise. The database's id is recorded first, while its folder is where
# the record says (a 0.3.0 kit kept none for a database of the user's): the
# follow after the move needs it, and so does a launcher they update
# themselves later. Not in a preview, which writes nothing
# (personal_update_user_preview).
_personal_update_user_case() {
    _puus_want="${1:-}"
    [ -n "$_puus_want" ] || return 10
    [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] || return 10
    [ "$(manifest_get runtime.ownership 2>/dev/null || true)" = user ] || return 10
    [ "${EXAKIT_PERSONAL_MODE:-}" != P ] && [ ! -e "$EXAKIT_PERSONAL_KIT_BIN" ] || return 10
    exakit_component_is_managed personal && return 10
    [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] || return 10
    personal_deploy_dir_refresh
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 10
    _puus_bin="$(personal_cli)"
    [ -n "$_puus_bin" ] && [ -x "$_puus_bin" ] || return 10
    [ "${2:-}" = preview ] || personal_update_record_id || true
    _puus_have="$(personal_launcher_version 2>/dev/null || true)"
    [ -n "$_puus_have" ] || return 10
    personal_deployment_outranks "$(personal_deployed_version 2>/dev/null || true)" "$_puus_want" && return 10
    exakit_runtime_update_is_staged "$_puus_have" "$_puus_want" && return 10
    return 0
}

# personal_update_preview_database <swap|current> — the database part of an
# update, said and not done, for `exakit update personal --plan`: the rename of
# a 0.3.0 `default` to starter-kit-local, the 20-session limit, and the one
# restart. <swap>: a launcher is replaced first (it stops a running database
# whatever else changes, and 2.5 then drives it); <current>: no launcher to
# replace, so the rename waits for a launcher at 2.5.0 or later, as
# personal_update_current does it, and the limit takes every guard of the lift.
# Reads the records, the folders and the launcher's answers only: nothing is
# stopped, renamed, edited or recorded. 1 when none of the three applies.
personal_update_preview_database() {
    _pupd_said=1
    _pupd_from="$(personal_update_rename_source 2>/dev/null || true)"
    if [ -n "$_pupd_from" ] && [ "$1" = current ]; then
        _pupd_ver="$(personal_launcher_version 2>/dev/null || true)"
        if [ -z "$_pupd_ver" ] || personal_deployment_outranks 2.5.0 "$_pupd_ver"; then
            _pupd_from=""
        fi
    fi
    if [ -n "$_pupd_from" ]; then
        info "The database '$(basename "$_pupd_from")' is renamed to '$EXAKIT_PERSONAL_DEPLOYMENT'."
        _pupd_said=0
    fi
    _pupd_limit=1
    if [ "$1" = swap ]; then
        _personal_session_limit_on_file && _pupd_limit=0
    else
        personal_session_limit_pending && _pupd_limit=0
    fi
    if [ "$_pupd_limit" = 0 ]; then
        info "Its 20-session limit is removed."
        _pupd_said=0
    fi
    if { [ "$1" = swap ] || [ "$_pupd_said" = 0 ]; } && _personal_update_runs; then
        info "The database stops and starts again once."
        _pupd_said=0
    fi
    return "$_pupd_said"
}

# personal_update_user_preview <plan|backup> <installed> <advertised> — what
# personal_update_user would do, said and not done (`exakit update personal
# --plan` or `--backup`). --plan: the database part
# (personal_update_preview_database), their launcher is not touched. --backup:
# what it says for a launcher swap, that there is nothing to back up first.
# Nothing is downloaded, stopped, renamed, edited or recorded. 10 when that is
# not this update, as personal_update_user answers.
personal_update_user_preview() {
    _personal_update_user_case "${3:-}" preview || return 10
    if [ "$1" = backup ]; then
        info "This update neither deletes nor migrates the tables in your database, so there is nothing to back up first."
    else
        personal_update_preview_database swap || true
    fi
    info "Apply it with: exakit update personal"
    return 0
}

# _personal_update_private_case — 0 when the kit's own database (owner kit)
# runs on the USER's launcher, 2.4 or older (a 0.3.0 kit that deployed its
# `default` with the 2.4 it found on PATH), in the user's own legacy root, on
# macOS or Linux, with no private home yet. Q15: such a database moves into
# the kit's private home under the kit's own 2.5 (mode P), so the 2.5 never
# sees, or moves, the user's other 2.4 deployments. Prints that launcher's
# version.
_personal_update_private_case() {
    [ "${EXAKIT_PERSONAL_MODE:-}" != P ] && [ ! -e "$EXAKIT_PERSONAL_PRIVATE_BIN" ] && \
        [ ! -e "$EXAKIT_PERSONAL_KIT_BIN" ] || return 1
    [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] || return 1
    exakit_component_is_managed database || return 1
    [ "$(manifest_get components.personal.ownership 2>/dev/null || true)" = user ] || return 1
    personal_deploy_dir_refresh
    [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] || return 1
    [ -d "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || return 1
    detect_personal_deploy_roots
    case "$EXAKIT_PERSONAL_DEPLOY_DIR" in "${DETECT_PERSONAL_USER_ROOT_LEGACY:-/nonexistent}/"*) ;; *) return 1 ;; esac
    _pupc_ver="$(personal_launcher_version 2>/dev/null || true)"
    _pupc_pin="${EXAKIT_PERSONAL_VERSION:-}"
    [ -n "$_pupc_ver" ] && [ -n "$_pupc_pin" ] || return 1
    # Older than the pinned release line (2.4 next to 2.5).
    _pupc_l1="$(printf '%s' "$_pupc_ver" | awk -F. '{printf "%d%04d", $1, $2}')"
    _pupc_l2="$(printf '%s' "$_pupc_pin" | awk -F. '{printf "%d%04d", $1, $2}')"
    [ "$_pupc_l1" -lt "$_pupc_l2" ] 2>/dev/null || return 1
    printf '%s\n' "$_pupc_ver"
}

# _personal_move_folder <from> <to> — <from> becomes <to> in ONE step (the
# system's rename, never mv's copy and delete): on another filesystem it fails
# and nothing has changed. Refused when <to> is there already.
_personal_move_folder() {
    [ -d "$1" ] && [ ! -e "$2" ] && [ ! -L "$2" ] || return 1
    run_python -c 'import os, sys
os.rename(sys.argv[1], sys.argv[2])' "$1" "$2" 2>/dev/null
}

# _personal_path_device <path> — the device of <path>, or of the nearest folder
# above it that is there. Nothing when it cannot be read.
_personal_path_device() {
    _ppd="$1"
    while [ ! -e "$_ppd" ] && [ "$_ppd" != / ] && [ "$_ppd" != . ]; do _ppd="$(dirname "$_ppd")"; done
    stat -c %d "$_ppd" 2>/dev/null || stat -f %d "$_ppd" 2>/dev/null || true
}

# _personal_private_roots — the private home's two roots, the legacy one first,
# as detect.sh spells them.
_personal_private_roots() {
    ( EXAKIT_PERSONAL_LAUNCHER_HOME="$EXAKIT_PERSONAL_PRIVATE_HOME"; detect_personal_deploy_roots
      printf '%s\n%s\n' "$DETECT_PERSONAL_DEPLOY_ROOT_LEGACY" "$DETECT_PERSONAL_DEPLOY_ROOT_NEW" )
}

# _personal_private_find <id> — the folder in the private home whose deployment
# carries <id>. Nothing for no id.
_personal_private_find() {
    [ -n "${1:-}" ] || return 0
    _personal_private_roots | while IFS= read -r _ppf_root; do
        for _ppf in "$_ppf_root"/*; do
            [ -d "$_ppf" ] || continue
            [ "$(_personal_deployment_id_in "$_ppf" 2>/dev/null || true)" = "$1" ] || continue
            printf '%s\n' "$_ppf"
            break
        done
    done | sed -n 1p
}

# _personal_private_drop — the private home of a move that was put back goes,
# and only when nothing in it can be a deployment: both its roots empty, and no
# launcher state file anywhere in it. Non-zero, nothing deleted, otherwise.
_personal_private_drop() {
    [ -d "$EXAKIT_PERSONAL_PRIVATE_DIR" ] || return 0
    for _ppdr_root in $(_personal_private_roots | sed -n '1p;2p' | tr ' ' '\001'); do
        _ppdr_root="$(printf '%s' "$_ppdr_root" | tr '\001' ' ')"
        [ -z "$(ls -A "$_ppdr_root" 2>/dev/null || true)" ] || return 1
    done
    [ -z "$(find "$EXAKIT_PERSONAL_PRIVATE_DIR" \( -name '.exasolLauncherState.json' -o -name deployment.json \) 2>/dev/null | head -1)" ] || return 1
    rm -rf "$EXAKIT_PERSONAL_PRIVATE_DIR"
}

# _personal_manifest_lacks <key>... — 0 only when the record was read and has
# none of these keys. A record that cannot be read proves nothing.
_personal_manifest_lacks() {
    run_python_any - "$EXAKIT_MANIFEST" "$@" <<'EXAKIT_PML_PY' 2>/dev/null
import json, sys
with open(sys.argv[1]) as handle:
    doc = json.load(handle)
for key in sys.argv[2:]:
    node = doc
    for part in key.split("."):
        node = node.get(part) if isinstance(node, dict) else None
    if node is not None:
        sys.exit(1)
EXAKIT_PML_PY
}

# THE PRIVATE MOVE (personal_update_private) IS WRITTEN DOWN BEFORE IT BEGINS
# (runtime.private_move_*, private_move_from last) and struck out in the step
# that records the database at its new place: a closed terminal, a crash or a
# kill in between left a folder no command found, and the records of two
# launchers mixed. _personal_private_move_begin <from> <id> <their launcher>,
# non-zero when it cannot be written. _personal_private_move_end strikes it
# out, and answers 0 only when the record was read back without it:
# manifest_del answers 0 for a record it could not write.
_personal_private_move_begin() {
    ( manifest_set runtime.private_move_id "$2" && manifest_set runtime.private_move_launcher "$3" && \
      manifest_set runtime.private_move_version "$(manifest_get runtime.version 2>/dev/null || true)" && \
      manifest_set runtime.private_move_desired "$(manifest_get desired.runtime.personal 2>/dev/null || true)" && \
      manifest_set runtime.private_move_pid "$$" && \
      manifest_set runtime.private_move_started "$(exakit_process_start_time "$$")" && \
      manifest_set runtime.private_move_from "$1" ) >/dev/null 2>&1
}
_personal_private_move_end() {
    for _ppme in from pid started launcher version desired id; do
        ( manifest_del "runtime.private_move_$_ppme" ) >/dev/null 2>&1 || true
        # The first one is the note: with it still there, nothing is struck out.
        [ "$_ppme" != from ] || _personal_manifest_lacks runtime.private_move_from || return 1
    done
    return 0
}

# personal_private_move_undo <from> <id> <their launcher> — the move taken
# back: the folder where it was (wherever the move left it, found by its id),
# the records as they were, no private home, their launcher again. ONLY A
# DATABASE THE LAUNCHER, ASKED NOW, SAYS IS STOPPED IS MOVED (the kit's own,
# or theirs when that one does not run). One that runs is left where it is and
# recorded there, as the kit's, under the kit's own launcher (mode P). Anything
# else changes nothing, and the note stays. Nothing is deleted that may hold a
# deployment. Non-zero when it was not taken back.
personal_private_move_undo() {
    _ppmu_at=""
    if [ "$(_personal_deployment_id_in "$1" 2>/dev/null || true)" != "$2" ]; then
        # Neither there nor in the private home: nothing is concluded, nothing
        # is changed, and the note stays for the next run.
        _ppmu_at="$(_personal_private_find "$2")"
        [ -n "$_ppmu_at" ] || return 1
    fi
    # Another database of the kit's on record: not this move's to touch. With
    # another deployment in the private home its launcher stays, so the
    # database stays with it, recorded where it is.
    _ppmu_rec="$(manifest_get runtime.deployment_id 2>/dev/null || true)"
    [ -z "$_ppmu_rec" ] || [ "$_ppmu_rec" = "$2" ] || return 1
    if ! _personal_private_only "$_ppmu_at"; then
        [ -n "$_ppmu_at" ] && personal_wrapper_runs && _personal_private_move_keep "$_ppmu_at"
        return 1
    fi
    if [ -n "$_ppmu_at" ]; then
        # The move went through and only its note was left: the record names
        # the folder it is in.
        if [ "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" = "$_ppmu_at" ] && \
           [ "$(manifest_get runtime.ownership_path 2>/dev/null || true)" = "$_ppmu_at" ]; then
            _personal_private_move_keep "$_ppmu_at"
            return 1
        fi
        # The kit's own is asked, and theirs only where that one does not run
        # on this computer. Asked, the kit's 2.5 moves a folder of its legacy
        # root on, so the folder is found again, and the word is the one of the
        # folder it is in.
        exakit_run_bounded "${EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT:-120}" "$EXAKIT_PERSONAL_WRAPPER" version >/dev/null 2>&1 && \
            _ppmu_cli="$EXAKIT_PERSONAL_WRAPPER" || _ppmu_cli="$3"
        _ppmu_at="$(_personal_private_find "$2")"
        [ -n "$_ppmu_at" ] || return 1
        if [ -z "$_ppmu_cli" ] || ! _personal_says_stopped "$_ppmu_at" "$_ppmu_cli"; then
            [ -n "$_ppmu_cli" ] && _personal_says_running "$_ppmu_at" "$_ppmu_cli" && _personal_private_move_keep "$_ppmu_at"
            return 1
        fi
        if ! _personal_move_folder "$_ppmu_at" "$1" && \
           [ "$(_personal_deployment_id_in "$1" 2>/dev/null || true)" != "$2" ]; then
            [ -d "$_ppmu_at" ] || return 1
            command -v _exakit_log_file >/dev/null 2>&1 && \
                _exakit_log_file "WARN  the database could not go back to $1, it is kept at $_ppmu_at"
            _personal_private_move_keep "$_ppmu_at"
            return 1
        fi
    fi
    if ! ( personal_point_record_at "$1" && exakit_record_ownership database kit "$1" && \
           exakit_record_ownership personal user "$3" && \
           _personal_private_move_put_back runtime.version version && \
           _personal_private_move_put_back desired.runtime.personal desired ) >/dev/null 2>&1; then
        return 1
    fi
    ( manifest_del runtime.launcher_home ) >/dev/null 2>&1 || true
    _personal_manifest_lacks runtime.launcher_home || return 1
    rm -f "$EXAKIT_PERSONAL_PRIVATE_BIN" "$EXAKIT_PERSONAL_WRAPPER"
    _personal_private_drop || true
    EXAKIT_PERSONAL_DEPLOY_DIR="$1"
    personal_use_mode ""
    EXAKIT_PERSONAL_MODE=""
    _personal_private_move_end
}

# _personal_private_only <dir> — 0 when the private home holds no deployment
# but the one in <dir> (empty: none at all). Its launcher is deleted only then.
_personal_private_only() {
    _ppo_out="$(_personal_private_roots | while IFS= read -r _ppo_root; do
        for _ppo in "$_ppo_root"/*; do
            [ -e "$_ppo" ] && [ "$_ppo" != "${1:-}" ] && { echo no; break; }
        done
    done)"
    [ -z "$_ppo_out" ]
}

# _personal_private_move_keep <dir> — the database stays where the move left
# it: recorded there as the kit's, under the kit's own launcher (mode P), and
# the note struck out.
_personal_private_move_keep() {
    ( personal_point_record_at "$1" && exakit_record_ownership database kit "$1" && \
      manifest_set runtime.launcher_home "$EXAKIT_PERSONAL_PRIVATE_HOME" && \
      { ! personal_wrapper_runs || exakit_record_ownership personal kit "$EXAKIT_PERSONAL_WRAPPER"; } ) >/dev/null 2>&1 || return 1
    EXAKIT_PERSONAL_DEPLOY_DIR="$1"
    personal_use_mode P
    _personal_private_move_end
}

# _personal_private_move_put_back <key> <note> — a record the note kept, back
# as it was: its value, or nothing when it had none.
_personal_private_move_put_back() {
    _ppmb="$(manifest_get "runtime.private_move_$2" 2>/dev/null || true)"
    if [ -n "$_ppmb" ]; then manifest_set "$1" "$_ppmb"
    else manifest_del "$1"; fi
}

# _personal_private_move_noted — 0 while the record notes a private move that
# was not finished (one grep when there is none).
_personal_private_move_noted() {
    [ -f "${EXAKIT_MANIFEST:-}" ] && grep -qF '"private_move_from"' "$EXAKIT_MANIFEST" 2>/dev/null && \
        command -v manifest_get >/dev/null 2>&1 && \
        [ -n "$(manifest_get runtime.private_move_from 2>/dev/null || true)" ]
}

# _personal_private_move_pending — 0 while that move's database is in neither
# record: still in its old folder or in the private home, under the id noted,
# and the kit's record names neither it there nor another database.
_personal_private_move_pending() {
    _personal_private_move_noted || return 1
    _ppmp_id="$(manifest_get runtime.private_move_id 2>/dev/null || true)"
    [ -n "$_ppmp_id" ] || return 1
    _ppmp_rec="$(manifest_get runtime.deployment_id 2>/dev/null || true)"
    [ -z "$_ppmp_rec" ] || [ "$_ppmp_rec" = "$_ppmp_id" ] || return 1
    _ppmp_at="$(_personal_private_find "$_ppmp_id")"
    if [ -z "$_ppmp_at" ]; then
        _ppmp_at="$(manifest_get runtime.private_move_from 2>/dev/null || true)"
        [ "$(_personal_deployment_id_in "$_ppmp_at" 2>/dev/null || true)" = "$_ppmp_id" ] || return 1
    fi
    [ "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" != "$_ppmp_at" ]
}

# _personal_private_move_alive — 0 while the process that noted the move runs:
# its pid AND its start time (exakit_lock_holder_alive's rule). A pid alone is
# handed out again, after a restart from the low numbers. This process asking
# is past its own move.
_personal_private_move_alive() {
    _ppma_pid="$(manifest_get runtime.private_move_pid 2>/dev/null || true)"
    case "$_ppma_pid" in ''|*[!0-9]*|"$$") return 1 ;; esac
    kill -0 "$_ppma_pid" 2>/dev/null || return 1
    [ "$(exakit_process_start_time "$_ppma_pid")" = "$(manifest_get runtime.private_move_started 2>/dev/null || true)" ]
}

# personal_private_move_recover — a private move a run before this one began
# and did not finish: taken back, once its process is gone
# (personal_private_move_undo). ONLY A COMMAND THAT ACTS ON THE DATABASE ASKS
# (start, stop, update, repair-runtime, uninstall, the installer), never a
# read: `exakit status` moves and deletes nothing.
personal_private_move_recover() {
    _personal_private_move_noted || return 0
    _personal_private_move_alive && return 0
    _ppmr_from="$(manifest_get runtime.private_move_from 2>/dev/null || true)"
    _ppmr_id="$(manifest_get runtime.private_move_id 2>/dev/null || true)"
    [ -n "$_ppmr_from" ] && [ -n "$_ppmr_id" ] || return 0
    personal_private_move_undo "$_ppmr_from" "$_ppmr_id" "$(manifest_get runtime.private_move_launcher 2>/dev/null || true)" || true
    _personal_forget_followed
    return 0
}

# personal_update_private <installed> <advertised> — Q15: the kit's own
# database, run by the user's 2.4, moves into the kit's private home with the
# kit's own 2.5 (mode P), and is named starter-kit-local, with its id, data
# and port. The user's 2.4 and their other deployments are never touched.
# Stopped with their 2.4 when it runs, the kit's 2.5 installed in its own home,
# the folder moved into that home's legacy root (the kit's 2.5 moves it on into
# its own root by its first command), renamed, recorded, its 20-session limit
# lifted, and started (Q8). A failure before the start puts it all back: the
# folder in its old place, the records as they were, the private home gone,
# the database running again when it ran. 0 updated, 10 not this case, 11 put
# back (said).
personal_update_private() {
    personal_private_move_recover
    [ -z "${2:-}" ] || { EXAKIT_PERSONAL_VERSION="$2"; export EXAKIT_PERSONAL_VERSION; }
    # The folder in use, read in this shell (the case check runs in a subshell).
    personal_deploy_dir_refresh
    _pup_their_ver="$(_personal_update_private_case)" || return 10
    # A deliberate no keeps the database as it is, as on every other arm.
    if [ "$(exakit_runtime_update_preanswer)" = no ]; then
        warn "personal $_pup_their_ver -> $EXAKIT_PERSONAL_VERSION was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        info "Apply it when convenient:  exakit update --yes"
        return 12
    fi
    # The new launcher cannot take over a database whose Docker it cannot ask:
    # said before anything is downloaded or stopped.
    if ! _personal_start_engine_ok; then
        warn "The database runs on Docker, and ${_pdu_said:-Docker is not usable}. Start Docker (Docker Desktop, or the docker service), then: exakit start"
        exakit_note_failure "The database runs on Docker, and ${_pdu_said:-Docker is not usable}"
        info "The next exakit update tries again."
        return 11
    fi
    _pup_their="$(personal_cli)"
    _pup_from="$EXAKIT_PERSONAL_DEPLOY_DIR"
    _pup_id="$(_personal_deployment_id_in "$_pup_from" 2>/dev/null || true)"
    _pup_rec_launcher="$(manifest_get components.personal.ownership_path 2>/dev/null || true)"
    # Theirs moved since: where it is now.
    [ -x "$_pup_rec_launcher" ] || _pup_rec_launcher=""
    _pup_legacy="$(_personal_private_roots | sed -n 1p)"
    _pup_root25="$(_personal_private_roots | sed -n 2p)"
    PERSONAL_UPDATE_RAN=0
    # WITHOUT ITS ID IT COULD NOT BE FOUND AGAIN, and between two filesystems
    # it cannot be moved in one step: both end here, before anything stops.
    if [ -z "$_pup_id" ]; then
        PERSONAL_UPDATE_FROM="$_pup_from"
        PERSONAL_RENAME_ERROR=noid
        _personal_update_not_renamed
        return 11
    fi
    _pup_dev="$(_personal_path_device "$_pup_from")"
    if [ -z "$_pup_dev" ] || [ "$_pup_dev" != "$(_personal_path_device "$_pup_legacy")" ]; then
        warn "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because its folder could not be moved. The launcher and the database are as they were."
        exakit_note_failure "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because its folder could not be moved"
        info "The next exakit update tries again."
        return 11
    fi
    info "Exasol Personal $_pup_their_ver is on this computer. The starter kit uses its own Exasol Personal ${EXAKIT_PERSONAL_VERSION} in its own folder, so yours is not changed."
    if _personal_update_runs; then
        PERSONAL_UPDATE_RAN=1
        warn "The database stops and starts again once, to rename it to '$EXAKIT_PERSONAL_DEPLOYMENT'."
        if ! run_logged "$_pup_their" stop --deployment-dir "$_pup_from" || ! _personal_update_stopped; then
            warn "The database did not stop, so it was not updated. Nothing was changed."
            exakit_note_failure "The database did not stop, so it was not updated"
            personal_update_start_again || true
            return 11
        fi
    elif ! _personal_update_stopped; then
        # Neither running nor known to be stopped: never moved on a guess.
        if ! run_logged "$_pup_their" stop --deployment-dir "$_pup_from" || ! _personal_update_stopped; then
            warn "The database did not stop, so it was not updated. Nothing was changed."
            exakit_note_failure "The database did not stop, so it was not updated"
            return 11
        fi
        PERSONAL_UPDATE_RAN=1
    fi
    _personal_start_owe
    _pup_why=""
    _personal_private_move_begin "$_pup_from" "$_pup_id" "${_pup_rec_launcher:-$_pup_their}" || \
        _pup_why="the kit could not write its record"
    [ -n "$_pup_why" ] || (
        personal_use_mode P
        EXAKIT_FORCE_COMPONENT_INSTALL=1
        personal_install_launcher
    ) >/dev/null 2>&1 || _pup_why="the new launcher could not be installed"
    if [ -z "$_pup_why" ]; then
        # ASKED AGAIN, right before the move: the download above took minutes,
        # and the database can have been started in them.
        _personal_says_stopped "$_pup_from" "$_pup_their" && mkdir -p "$_pup_legacy" 2>/dev/null && \
            _personal_move_folder "$_pup_from" "$_pup_legacy/$(basename "$_pup_from")" || \
            _pup_why="its folder could not be moved"
    fi
    _pup_at=""
    if [ -z "$_pup_why" ]; then
        personal_use_mode P
        # The kit's 2.5, first command: it moves the folder into its own root.
        exakit_run_bounded "${EXAKIT_PERSONAL_FIRST_RUN_TIMEOUT:-120}" "$(personal_cli)" version >/dev/null 2>&1 || \
            _pup_why="the new launcher did not run on this computer"
    fi
    if [ -z "$_pup_why" ]; then
        _pup_at="$(_personal_private_find "$_pup_id")"
        case "$_pup_at" in "$_pup_root25"/*) ;; *) _pup_why="the new launcher did not take the database over" ;; esac
    fi
    if [ -z "$_pup_why" ]; then
        info "Renaming the database to '$EXAKIT_PERSONAL_DEPLOYMENT'."
        _pup_to="$_pup_root25/$EXAKIT_PERSONAL_DEPLOYMENT"
        if [ "$_pup_at" != "$_pup_to" ]; then
            _personal_says_stopped "$_pup_at" "$EXAKIT_PERSONAL_WRAPPER" && \
                personal_rename_deployment "$_pup_at" "$_pup_to" && _pup_at="$_pup_to" || \
                _pup_why="its folder could not be renamed"
        fi
    fi
    if [ -z "$_pup_why" ]; then
        if ! ( personal_point_record_at "$_pup_at" && \
               { [ -z "$_pup_id" ] || manifest_set runtime.deployment_id "$_pup_id"; } && \
               exakit_record_ownership database kit "$_pup_at" && \
               manifest_set runtime.version "$EXAKIT_PERSONAL_VERSION" && \
               manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION" ) >/dev/null 2>&1; then
            _pup_why="the kit could not write its record"
        fi
    fi
    if [ -n "$_pup_why" ]; then
        # PUT BACK: the folder where it was (wherever the move left it, by its
        # id), the records, no private home, and the database running again
        # when it ran, by their own launcher.
        _pup_whole=1
        personal_private_move_undo "$_pup_from" "$_pup_id" "${_pup_rec_launcher:-$_pup_their}" || _pup_whole=0
        if [ "$_pup_whole" = 1 ]; then
            warn "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because $_pup_why. The launcher and the database are as they were."
        else
            warn "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because $_pup_why."
        fi
        exakit_note_failure "Exasol Personal was not updated to ${EXAKIT_PERSONAL_VERSION:-the new version}, because $_pup_why"
        if [ "$PERSONAL_UPDATE_RAN" = 1 ] && [ -d "$_pup_from" ]; then
            _personal_says_running "$_pup_from" "$_pup_their" || run_logged "$_pup_their" start --deployment-dir "$_pup_from" || \
                warn "The database did not start again. Start it with: exakit start"
        elif [ "$PERSONAL_UPDATE_RAN" = 1 ]; then
            personal_update_start_again || true
        fi
        _personal_start_settled
        info "The next exakit update tries again."
        return 11
    fi
    personal_use_mode P
    EXAKIT_PERSONAL_DEPLOY_DIR="$_pup_at"
    # THE NOTE, struck out and read back. One that stays (a record that cannot
    # be written any more) takes nothing back: the record above names the
    # database's new place, so the next command that acts only strikes it out
    # (personal_private_move_undo).
    _personal_private_move_end || _personal_private_move_end || \
        _exakit_log_file "WARN  the note of the database's move could not be struck out: the next exakit start or update does it"
    command -v _personal_forget_followed >/dev/null 2>&1 && _personal_forget_followed
    ( personal_record_manifest ) >/dev/null 2>&1 || true
    personal_session_limit_remove "$_pup_at/local/runtime/exa/exasol.conf" "$EXAKIT_PERSONAL_VERSION" >/dev/null 2>&1 || \
        warn "The 20-session limit of this database was not removed. Its file is as it was."
    ok "Your database is now '$EXAKIT_PERSONAL_DEPLOYMENT', run by the starter kit's own Exasol Personal $EXAKIT_PERSONAL_VERSION."
    personal_update_start_again always || true
    command -v exakit_forget_update_failure >/dev/null 2>&1 && exakit_forget_update_failure
    return 0
}

# personal_update_private_preview <plan|backup> [<advertised>] — what personal_update_private
# would do (Q15), said and not done. 1 when it is not this case.
personal_update_private_preview() {
    [ -z "${2:-}" ] || EXAKIT_PERSONAL_VERSION="$2"
    # The folder in use, read in this shell (the case check runs in a subshell).
    personal_deploy_dir_refresh
    _pupp_ver="$(_personal_update_private_case)" || return 1
    info "Exasol Personal $_pupp_ver is on this computer. The starter kit uses its own Exasol Personal ${EXAKIT_PERSONAL_VERSION} in its own folder, so yours is not changed."
    if [ "$1" = backup ]; then
        info "This update neither deletes nor migrates the tables in your database, so there is nothing to back up first."
    else
        personal_update_preview_database swap || true
    fi
    info "Apply it with: exakit update personal"
    return 0
}

# personal_update_user <installed> <advertised> — the update of a database the
# user let the 0.3.0 kit use (runtime.ownership user), still run by a launcher
# of THEIRS: the same one restart as the kit's own (personal_update), on the
# kit's OWN launcher, installed in the kit folder. THEIR LAUNCHER IS NEVER
# REPLACED, MOVED OR DELETED (#41), whatever its version: it is run once more,
# to stop the database it runs, and stays theirs, recorded by name only
# (components.personal.user_launcher). The kit's 2.5 then moves their stopped
# 2.4 deployments, as it does for anyone (accepted). The pinned release is
# downloaded and checked before anything stops. Returns 10 when this is not
# that update (another owner, a launcher of the kit's, a major upgrade, a
# newer database, no database): the caller carries on as before. 0 when done.
# 11 when it did not happen: said, put back, the database running again when
# it ran (`exakit update` tries again next time). 12 when
# EXAKIT_CONFIRM_RUNTIME_UPDATE=0 keeps the database as it is.
personal_update_user() {
    _personal_update_user_case "${2:-}" || return 10
    if [ "$(exakit_runtime_update_preanswer)" = no ]; then
        warn "personal $_puus_have -> $_puus_want was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        info "Apply it when convenient:  exakit update --yes"
        return 12
    fi
    exakit_runtime_update_explain personal "$_puus_have" "$_puus_want"
    EXAKIT_PERSONAL_VERSION="$_puus_want"
    export EXAKIT_PERSONAL_VERSION
    # The pinned release, downloaded and checked before anything stops. In a
    # subshell: its die() on a bad download ends the download only.
    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-personal.XXXXXX")" || return 11
    command -v exakit_track_tmp >/dev/null 2>&1 && exakit_track_tmp "$_tmp"
    if ! ( personal_launcher_download && { [ "$_binary" = "$_tmp/exasol" ] || cp -p "$_binary" "$_tmp/exasol"; } ) || \
       [ ! -f "$_tmp/exasol" ]; then
        rm -rf "$_tmp"
        warn "Exasol Personal was not updated to $_puus_want, because the new launcher could not be installed. The launcher and the database are as they were."
        exakit_note_failure "Exasol Personal was not updated to $_puus_want, because the new launcher could not be installed"
        return 11
    fi
    _puus_pw_before="$(read_credential personal_sys_password 2>/dev/null || true)"
    # Nothing of the kit's is replaced (there is no launcher in the kit folder
    # yet), so nothing is kept to put back: an undo removes the kit's new one
    # and the receipt names theirs again (PERSONAL_UPDATE_OLD_BIN).
    PERSONAL_UPDATE_BIN="$EXAKIT_PERSONAL_KIT_BIN"
    PERSONAL_UPDATE_OLD_BIN="$_puus_bin"
    PERSONAL_UPDATE_OLD_SHA=""
    PERSONAL_UPDATE_RECEIPT=user
    PERSONAL_UPDATE_LIFTED=0
    if ! personal_update_prepare ""; then
        rm -rf "$_tmp"
        PERSONAL_UPDATE_OLD_BIN=""
        return 11
    fi
    # THE KIT'S OWN, in the kit folder only: a fresh file, and the kit's
    # receipt on it.
    # Theirs recorded first, then the file in one step, then the receipt: cut
    # short anywhere, the next update finishes it (personal_kit_launcher_finish).
    if ! ( manifest_set components.personal.user_launcher "$_puus_bin" ) >/dev/null 2>&1 || \
       ! { mkdir -p "$(dirname "$EXAKIT_PERSONAL_KIT_BIN")" && rm -f "$EXAKIT_PERSONAL_KIT_BIN.new" && \
           install -m 755 "$_tmp/exasol" "$EXAKIT_PERSONAL_KIT_BIN.new" && \
           mv -f "$EXAKIT_PERSONAL_KIT_BIN.new" "$EXAKIT_PERSONAL_KIT_BIN"; } 2>/dev/null || \
       ! ( exakit_record_ownership personal kit "$EXAKIT_PERSONAL_KIT_BIN" ) >/dev/null 2>&1; then
        rm -rf "$_tmp"
        personal_update_undo "the new launcher could not be installed"
        PERSONAL_UPDATE_OLD_BIN=""
        return 11
    fi
    rm -rf "$_tmp"
    if ! _personal_update_launcher_answers; then
        personal_update_undo "the new launcher did not run on this computer"
        PERSONAL_UPDATE_OLD_BIN=""
        return 11
    fi
    PERSONAL_UPDATE_OLD_BIN=""
    # The steps after it in a subshell, as in personal_update: the one start
    # below comes even when one of them cannot write its record.
    _personal_update_steps_begin
    _puus_after=0
    (
    # The new launcher's first command moved the folder: the record follows
    # it by its id, and names the launcher the kit now runs.
    _personal_forget_followed
    personal_record_manifest
    ( manifest_set desired.runtime.personal "$_puus_want" ) >/dev/null 2>&1 || true
    personal_refresh_changed_password "$_puus_pw_before" || true
    personal_update_lift || true
    _personal_update_steps_carry
    ) || _puus_after=$?
    _personal_update_after_steps
    personal_update_start_again always || true
    info "The kit's Exasol launcher is now in $(ui_tilde "$(dirname "$EXAKIT_PERSONAL_KIT_BIN")"). Run it with: exakit exasol"
    [ "$_puus_after" = 0 ] || exit "$_puus_after"
    # The MCP server the 0.3.0 kit set up beside it, recorded as the kit's
    # when that is provable (mcp_sidecar_claim): the uninstall removes it.
    # After the one start: its proof can need a download (uv, PyYAML), which
    # never lengthens the time the database is down.
    command -v mcp_sidecar_claim >/dev/null 2>&1 && mcp_sidecar_claim
    command -v exakit_forget_update_failure >/dev/null 2>&1 && exakit_forget_update_failure
    return 0
}

personal_update() {
    if ! exakit_component_is_managed personal; then exakit_preserve_component personal; return 0; fi
    # The update restarts and re-records the deployment: only the kit's own.
    exakit_kit_database_guard || return 3
    _mode="default"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --plan) _mode="plan" ;;
            --backup) _mode="backup" ;;
            --apply) _mode="apply" ;;
            *) die "Unknown option '$1' for 'exakit update'." ;;
        esac
        shift
    done

    _latest="$(exakit_component_available personal)"
    [ -n "$_latest" ] || die "Could not resolve the advertised Exasol Personal version."
    _current="$(manifest_get runtime.version 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "Exasol Personal launcher is already current ($_current)"
        return 0
    fi
    # A DELIBERATE NO HOLDS BACK EVERY WAY IN: `exakit update personal` by name,
    # and the installer's update of a stopped database, as `exakit update` does
    # (exakit_offer_runtime_update). A plan and a backup change nothing, and the
    # staged major upgrade has its own three steps.
    if [ "$_mode" = default ] && [ "$(exakit_runtime_update_preanswer)" = no ] && \
       ! exakit_runtime_update_is_staged "$_current" "$_latest"; then
        warn "personal ${_current:-unknown} -> $_latest was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        info "Apply it when convenient:  exakit update --yes"
        return 12
    fi

    _current_major="$(exakit_major_version "$_current")"
    _latest_major="$(exakit_major_version "$_latest")"
    if [ -n "$_current_major" ] && [ -n "$_latest_major" ] && [ "$_current_major" != "$_latest_major" ]; then
        case "$_mode" in
            plan|default)
                personal_upgrade_plan "$_current" "$_latest"
                [ "$_mode" = "plan" ] && return 0
                return 1
                ;;
            backup)
                personal_upgrade_plan "$_current" "$_latest"
                personal_upgrade_backup "$_current" "$_latest"
                return 0
                ;;
            apply)
                _last_backup="$(manifest_get backups.personal_upgrade.latest 2>/dev/null || true)"
                _backup_from="$(manifest_get backups.personal_upgrade.from 2>/dev/null || true)"
                _backup_to="$(manifest_get backups.personal_upgrade.to 2>/dev/null || true)"
                if [ -z "$_last_backup" ] || [ ! -f "$_last_backup" ]; then
                    die "Create a backup first."
                fi
                if [ "$_backup_from" != "${_current:-unknown}" ] || [ "$_backup_to" != "$_latest" ]; then
                    die "The latest recorded Personal backup does not match this upgrade (${_current:-unknown} -> $_latest)."
                fi
                info "Updating Exasol Personal launcher ${_current:-unknown} -> $_latest"
                EXAKIT_PERSONAL_VERSION="$_latest"
                EXAKIT_FORCE_COMPONENT_INSTALL=1
                export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
                # The working launcher stays until the new one is downloaded and
                # verified: personal_install_launcher replaces it only then
                # (audit LCY-06; deleting it first left none after a failed download).
                personal_install_launcher
                manifest_set runtime.launcher "$(personal_cli)"
                manifest_set runtime.launcher_version "$EXAKIT_PERSONAL_VERSION"
                manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
                # THE UPGRADE HAS TO CONVERGE. Leaving runtime.version on the
                # old number meant the next `exakit update` saw the same major
                # gap, matched the same backup record, and swapped the launcher
                # again - forever, with no command anywhere that finishes the
                # upgrade. The launcher on this machine IS $_latest now, so
                # that is what the record says; the part that is genuinely
                # still outstanding is the data migration, and it gets its own
                # key instead of being encoded as a stale version.
                manifest_set runtime.version "$_latest"
                manifest_set runtime.migration_pending "$_latest"
                warn "Launcher updated. Existing database content was not deleted or migrated."
                info "Recorded runtime.version $_latest with runtime.migration_pending $_latest — clear that key once the Exasol Personal $_latest data migration is done."
                ok "Exasol Personal launcher update applied with backup available at $_last_backup"
                return 0
                ;;
        esac
    fi

    # --plan AND --backup STOP HERE. Their handling used to live only inside
    # the major-upgrade branch above, so on every other gap they fell through
    # to the installer below: `exakit update runtime --plan` - a command whose
    # whole promise is that it only describes - deleted the launcher binary and
    # installed another one, with none of the confirmation the ordinary path
    # asks for. A flag that reads as "tell me" must never write.
    case "$_mode" in
        plan)
            info "Exasol Personal launcher ${_current:-unknown} -> $_latest."
            info "The launcher program is replaced. The database keeps its data."
            info "The first start after it rebuilds the deployment's VM guest - several minutes, once."
            # And the database part of the update from a 0.3.0 kit (the rename,
            # the 20-session limit, the one restart), said and not done.
            personal_update_preview_database swap || true
            info "Apply it with: exakit update personal"
            return 0
            ;;
        backup)
            # The backup flow exists for a data MIGRATION, which a launcher swap
            # is not. Saying "done" here would hand back a backup that was never
            # taken, so it says what this update actually is instead.
            info "Exasol Personal ${_current:-unknown} -> $_latest replaces the launcher binary only - it neither deletes nor migrates database content, so there is nothing to back up first."
            info "Apply it with: exakit update personal"
            return 0
            ;;
    esac

    # NO WSL CHECK BEFORE THE SWAP, ON PURPOSE. A launcher swap changes no
    # data, and the WSL release is only a proxy for the real question (can
    # Podman build the 2.4 network?): a Podman machine on the iptables driver
    # runs 2.4 on WSL 2.5, and the first update from kit 0.2.3 runs 0.2.3's
    # code, which never asked anyway. So the update goes through, and the
    # evidence decides at the start: when the launcher's own output carries
    # netavark's nftables error, _personal_start_network_die names
    # wsl --update, with the deployment and its data untouched.
    info "Updating Exasol Personal launcher ${_current:-unknown} -> $_latest"
    EXAKIT_PERSONAL_VERSION="$_latest"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    _pu_pw_before="$(read_credential personal_sys_password 2>/dev/null || true)"
    # ONE RESTART, AND NOTHING 2.5 RUNS BEFORE THE RENAME (the update from a
    # 0.3.0 kit, see personal_update_rename_source): a copy of the working
    # launcher kept, the database's id recorded, the database stopped with
    # the launcher that runs it now, and a 0.3.0 `default` renamed to
    # starter-kit-local. The stop is said first unless `exakit update` has
    # said it already (exakit_runtime_update_explain). Not done: said, nothing
    # changed, the database running again when it ran.
    personal_legacy_receipts
    PERSONAL_UPDATE_BIN="$EXAKIT_PERSONAL_BIN"
    [ "${EXAKIT_PERSONAL_MODE:-}" = P ] && PERSONAL_UPDATE_BIN="$EXAKIT_PERSONAL_PRIVATE_BIN"
    # A 0.3.0 kit's own launcher at ~/.local/bin/exasol: the new one goes into
    # the kit folder (EXAKIT_PERSONAL_KIT_BIN), the old one stays as it is
    # until the update went through, then is retired when it is still the
    # file the kit recorded (personal_retire_bin_launcher). An undo removes
    # the new one and points the receipt back at the old one.
    PERSONAL_UPDATE_OLD_BIN=""
    PERSONAL_UPDATE_OLD_SHA=""
    if [ "${EXAKIT_PERSONAL_MODE:-}" != P ] && [ ! -x "$EXAKIT_PERSONAL_KIT_BIN" ] && [ -f "$EXAKIT_BIN_DIR/exasol" ] && \
       [ "$(manifest_get components.personal.ownership_path 2>/dev/null || true)" = "$EXAKIT_BIN_DIR/exasol" ]; then
        PERSONAL_UPDATE_OLD_BIN="$EXAKIT_BIN_DIR/exasol"
        PERSONAL_UPDATE_OLD_SHA="$(manifest_get components.personal.ownership_sha256 2>/dev/null || true)"
        [ "${PERSONAL_LEGACY_RECEIPT:-0}" = 0 ] || PERSONAL_UPDATE_OLD_SHA=""
    fi
    [ -z "$PERSONAL_UPDATE_OLD_BIN" ] || personal_retire_note "$PERSONAL_UPDATE_OLD_BIN" "$PERSONAL_UPDATE_OLD_SHA"
    PERSONAL_UPDATE_RECEIPT=kit
    PERSONAL_UPDATE_LIFTED=0
    _pu_stop_line=""
    [ "${EXAKIT_RUNTIME_UPDATE_SAID:-0}" = 1 ] || \
        _pu_stop_line="personal ${_current:-unknown} -> $_latest needs the database stopped."
    EXAKIT_RUNTIME_UPDATE_SAID=0
    personal_update_prepare "$_pu_stop_line" || return 2
    # It is started again here, once (personal_update_start_again), never a
    # second time by the caller (exakit_apply_runtime_update).
    EXAKIT_RUNTIME_UPDATE_RESTARTED="${PERSONAL_UPDATE_RAN:-0}"
    # The working launcher stays until the new one is verified (audit LCY-06),
    # and its copy until the new one has answered: a failure up to there puts
    # the launcher, the folder's name and the records back
    # (personal_update_undo). In a subshell, so a die() on a bad download or a
    # full disk ends the swap only, never the run between the rename and its undo.
    if ! ( PERSONAL_UPDATE_RUNNING=1; personal_install_launcher ); then
        personal_update_undo "the new launcher could not be installed"
        return 2
    fi
    if ! _personal_update_launcher_answers; then
        personal_update_undo "the new launcher did not run on this computer"
        return 2
    fi
    personal_update_drop_launcher_copy
    # Nothing is put back any more: the old one goes before the one start,
    # which can take minutes.
    personal_retire_pending
    # THE ONE START COMES EVEN WHEN A STEP BELOW FAILS (a manifest that cannot
    # be written): the record, the password check and the lift run in a
    # subshell, whose die ends them only, so a database that ran is never left
    # stopped by them. It is started again, and then the run ends as that
    # step's own error (said by its die) ended it before. Twin of the try
    # around the same steps in Update-Personal.
    _personal_update_steps_begin
    _pu_after=0
    (
    # THE NEW LAUNCHER'S FIRST COMMAND MOVED THE FOLDER into its own root: the
    # record follows it by its id (personal_deploy_dir_refresh), asked of the
    # new launcher.
    _personal_forget_followed
    personal_record_manifest
    manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
    ok "Exasol Personal launcher updated; deployment data was not changed"
    # THE PASSWORD IS CHECKED, NOT ASSUMED. personal_record_manifest has just
    # re-read secrets.json, so the credential on file is the deployment's own;
    # when it differs from what was on file before the swap, the records that
    # depend on it follow and the change is said (personal_refresh_changed_password).
    personal_refresh_changed_password "$_pu_pw_before" || true
    # AN UNREADABLE secrets.json IS "unknown", NOT "same". personal_record_manifest
    # leaves the credential file alone when it cannot read the deployment's
    # password, so the comparison above then read the OLD credential twice and
    # called it unchanged - right after the kit warned it could not read the
    # secrets. Checked against the file itself.
    if [ "$EXAKIT_PERSONAL_PASSWORD_CHANGE" = "same" ] && ! _personal_update_secrets_readable; then
        EXAKIT_PERSONAL_PASSWORD_CHANGE="unknown"
    fi
    # WHAT STAYS THE SAME, said once, where the reader is wondering: 2.4 gives
    # new deployments a random password and a choice of engine, and neither
    # reaches a deployment that already exists. The one visible change is the
    # network move, and it happens at the next stop-and-start, not now. The
    # password is named only when both readings agree; when either could not
    # be read, nothing is claimed about it.
    #
    # THE PASSWORD RESULT IS SAID ON EVERY PLATFORM. It used to share the
    # engine sentence, which only an engine platform prints, so macOS computed
    # the verdict and threw it away. The engine and network words stay where
    # there is an engine.
    if _personal_update_crosses_to_24 "$_latest" && personal_deployment_exists; then
        if personal_engine_platform; then
            case "$EXAKIT_PERSONAL_PASSWORD_CHANGE" in
                same) info "The existing deployment keeps its engine ($(personal_engine_recorded)) and its database password: the launcher changed neither." ;;
                *)    info "The existing deployment keeps its engine ($(personal_engine_recorded))." ;;
            esac
            info "Its next 'exakit stop' followed by 'exakit start' moves the containers onto the launcher's own deployment network, once."
        elif [ "$EXAKIT_PERSONAL_PASSWORD_CHANGE" = "same" ]; then
            info "The existing deployment keeps its database password: the launcher did not change it."
        fi
    fi
    # THE 20-SESSION LIMIT a launcher before 2.5.0 set on the kit's database
    # is removed now that 2.5.0 drives it (personal_lift_session_limit), before
    # the steps after this one use the database. A failure is said there and
    # leaves the database as it was: the launcher update itself stands.
    # The database is stopped by now (personal_update_prepare), so the file
    # alone changes, and the one start below applies it.
    personal_update_lift || true
    _personal_update_steps_carry
    ) || _pu_after=$?
    _personal_update_after_steps
    personal_update_start_again always || true
    if [ -n "$PERSONAL_UPDATE_OLD_BIN" ]; then
        info "The kit's Exasol launcher is now in $(ui_tilde "$(dirname "$EXAKIT_PERSONAL_KIT_BIN")"). Run it with: exakit exasol"
    fi
    [ "$_pu_after" = 0 ] || exit "$_pu_after"
    # An earlier update's reason for not happening is history now.
    command -v exakit_forget_update_failure >/dev/null 2>&1 && exakit_forget_update_failure
    return 0
}

# _personal_update_secrets_readable - the deployment's secrets.json gives a
# database password now. What personal_record_manifest read the credential
# from; when it cannot, the credential on file was not refreshed.
_personal_update_secrets_readable() {
    personal_deploy_dir_refresh
    _pusr_sec="$EXAKIT_PERSONAL_DEPLOY_DIR/secrets.json"
    [ -f "$_pusr_sec" ] || return 1
    _pusr_pw="$(run_python -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dbPassword",""))' "$_pusr_sec" 2>/dev/null)" || return 1
    [ -n "$_pusr_pw" ] || return 1
    _pusr_pw=""
    return 0
}

# --- the 20-session limit of a database Exasol Personal 2.4 made ------------
# Launcher 2.5.0 makes local deployments with no session limit. A deployment an
# earlier launcher made keeps maxConnectionsLicenseLimit=20 (in [DB_PARAMS] of
# <deployment>/local/runtime/exa/exasol.conf) until that line is removed and the
# database restarted: `exasol stop`, delete the line, `exasol start` (the
# Exasol Personal 2.5 upgrade notes). personal_lift_session_limit does that for
# the kit's own deployment, once.

# personal_session_limit_conf - the exasol.conf of the deployment in use.
personal_session_limit_conf() {
    personal_deploy_dir_refresh
    printf '%s\n' "$EXAKIT_PERSONAL_DEPLOY_DIR/local/runtime/exa/exasol.conf"
}

# personal_session_limit_set <conf> - 0 when <conf> carries the limit line.
personal_session_limit_set() {
    [ -f "$1" ] && grep -Eq '^[[:space:]]*maxConnectionsLicenseLimit[[:space:]]*=' "$1"
}

# _personal_session_limit_start - the database started again and waited for,
# as `exakit start` does. A subshell: personal_start ends the run on its own
# failures, and here a failed start is this step's to handle.
_personal_session_limit_start() {
    ( personal_start && personal_wait_ready_or_deploy ) || return 1
    [ "$(personal_status 2>/dev/null || true)" = running ]
}

# _personal_session_limit_restore <backup> - the backup put back over the
# exasol.conf of the deployment in use (the folder may have moved during a
# start), so the database is exactly as it was before the lift.
_personal_session_limit_restore() {
    _pslr_conf="$(personal_session_limit_conf)"
    _pslr_bak="$(dirname "$_pslr_conf")/$(basename "$1")"
    [ -f "$_pslr_bak" ] || _pslr_bak="$1"
    [ -f "$_pslr_bak" ] && cp -p "$_pslr_bak" "$_pslr_conf"
    return 0
}

# _personal_session_limit_on_file - every check of
# personal_session_limit_pending but the launcher's version, from files only:
# the kit's database (its own, or one the user let the kit use), not in
# kit_database_missing, not yet recorded as lifted, its exasol.conf carrying
# the limit line. Asks no launcher.
_personal_session_limit_on_file() {
    [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] || return 1
    [ "$(manifest_get runtime.session_limit 2>/dev/null || true)" = lifted ] && return 1
    [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] || return 1
    exakit_component_is_managed database || \
        [ "$(manifest_get runtime.ownership 2>/dev/null || true)" = user ] || return 1
    # Nothing to remove: no launcher is asked anything.
    personal_session_limit_set "$(personal_session_limit_conf)"
}

# personal_session_limit_pending - 0 when personal_lift_session_limit has
# work to do: the kit's database (runtime.type personal, never in
# kit_database_missing), the kit's own or one the user let the kit use
# (runtime.ownership user: permission to use it is permission to lift its
# limit), not yet recorded as lifted, its exasol.conf still carrying the limit
# line, and launcher 2.5.0 or later driving it. Every check before the last
# one reads files only: with no line there, no launcher is asked anything.
# Twin of Test-PersonalSessionLimitPending.
personal_session_limit_pending() {
    _personal_session_limit_on_file || return 1
    _psl_ver="$(personal_launcher_version 2>/dev/null || true)"
    [ -n "$_psl_ver" ] || return 1
    personal_deployment_outranks 2.5.0 "$_psl_ver" && return 1
    return 0
}

# personal_lift_session_limit - remove the 20-session limit from the kit's
# database, when launcher 2.5.0 or later drives it and its exasol.conf
# still has the line. Only the kit's own deployment, or one the user let the
# kit use (personal_session_limit_pending), never in kit_database_missing
# (exakit_personal_db_state). A
# backup of exasol.conf stays next to it, and only the limit line goes, every
# other byte as it was. A running database is stopped with the launcher and
# started again, and waited for, as `exakit start` does. A stopped one stays
# stopped: its next start applies the change. Idempotent: no line, nothing
# to do and no restart. On success runtime.session_limit is "lifted" (with
# runtime.session_limit_lifted_at), so it never runs twice.
# Returns 0 when it lifted the limit or had nothing to do. Returns 1 when it
# failed: said, the file restored, and a database that was running before is
# started again. Twin of Remove-PersonalSessionLimit.
personal_lift_session_limit() {
    personal_session_limit_pending || return 0
    # `version` under launcher 2.5.0 can move a stopped deployment's folder:
    # the file is read where it is now.
    _plsl_conf="$(personal_session_limit_conf)"
    personal_session_limit_set "$_plsl_conf" || return 0
    _plsl_bak="$_plsl_conf.before-session-limit"
    _plsl_running=0
    # A "conflict" runs too as far as its file goes: the port answers, and the
    # launcher does not say stopped (a boot that is not done, a password that
    # was changed). Its file is never edited under it.
    case "$(personal_status 2>/dev/null || true)" in running|starting|conflict) _plsl_running=1 ;; esac
    # A deliberate no holds back every restart, this one too (12).
    if [ "$_plsl_running" = 1 ] && command -v exakit_runtime_update_preanswer >/dev/null 2>&1 && \
       [ "$(exakit_runtime_update_preanswer)" = no ]; then
        warn "personal $(manifest_get runtime.version 2>/dev/null || true) -> ${EXAKIT_PERSONAL_VERSION:-$(personal_launcher_version 2>/dev/null || true)} was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        info "Apply it when convenient:  exakit update --yes"
        return 12
    fi
    if [ "$_plsl_running" = 1 ]; then
        info "Removing the 20-session limit that Exasol Personal 2.4 set on this database. The database restarts once."
        if ! ( personal_stop ); then
            warn "The 20-session limit was not removed, because the database did not stop. Nothing was changed."
            if [ "$(personal_status 2>/dev/null || true)" != running ] && ! _personal_session_limit_start; then
                warn "The database did not start again. Start it with: exakit start"
            fi
            info "To remove the limit later, re-run the installer: $(exakit_install_command)"
            return 1
        fi
        _plsl_conf="$(personal_session_limit_conf)"
        _plsl_bak="$_plsl_conf.before-session-limit"
    else
        info "Removing the 20-session limit that Exasol Personal 2.4 set on this database. The change takes effect when the database next starts."
    fi
    _plsl_edit=0
    if cp -p "$_plsl_conf" "$_plsl_bak" 2>/dev/null; then
        run_python - "$_plsl_conf" <<'PY' >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 && _plsl_edit=1
import os, re, shutil, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    data = handle.read()
kept = re.sub(rb"(?m)^[ \t]*maxConnectionsLicenseLimit[ \t]*=[^\r\n]*(?:\r\n|\n|\r)?", b"", data)
if kept == data:
    sys.exit(3)
temp = path + ".exakit-tmp"
with open(temp, "wb") as handle:
    handle.write(kept)
shutil.copymode(path, temp)
os.replace(temp, path)
PY
    fi
    if [ "$_plsl_edit" != 1 ]; then
        rm -f "$_plsl_conf.exakit-tmp"
        [ -f "$_plsl_bak" ] && cp -p "$_plsl_bak" "$_plsl_conf"
        warn "The 20-session limit was not removed, because $(ui_tilde "$_plsl_conf") could not be changed. The file is as it was."
        if [ "$_plsl_running" = 1 ] && ! _personal_session_limit_start; then
            warn "The database did not start again. Start it with: exakit start"
        fi
        info "To remove the limit later, re-run the installer: $(exakit_install_command)"
        return 1
    fi
    if [ "$_plsl_running" = 1 ] && ! _personal_session_limit_start; then
        _personal_session_limit_restore "$_plsl_bak"
        if _personal_session_limit_start; then
            warn "The 20-session limit was not removed, because the database did not start without it. The file is as it was, and the database is running again."
        else
            warn "The 20-session limit was not removed, because the database did not start without it. The file is as it was, but the database did not start again. Start it with: exakit start"
        fi
        info "To remove the limit later, re-run the installer: $(exakit_install_command)"
        return 1
    fi
    manifest_set runtime.session_limit lifted
    manifest_set runtime.session_limit_lifted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
}
