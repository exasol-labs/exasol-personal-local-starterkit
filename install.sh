#!/bin/sh
# install.sh — Exasol Personal Local Starter Kit, one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | sh
#
# What it does, in order:
#   1. detects your OS and hardware
#   2. downloads the starter kit to ~/.exasol-starter-kit/kit (so you can
#      read every script before or after it runs)
#   3. shows the installation plan
#   4. hands off to the matching setup script, which installs and connects
#      a local Exasol database, exapump, and the Exasol MCP server
#
# Options (environment variables, because flags don't travel through a pipe):
#   EXAKIT_DRY_RUN=1        show the plan and downloaded scripts, install nothing
#   EXAKIT_PREFLIGHT=1      check this machine's requirements, install nothing
#   EXAKIT_REPO=...         override the source repo (owner/name)
#   EXAKIT_REF=...          override the git ref to install from
#   EXAKIT_LOCAL_KIT=path   use a local checkout instead of downloading
#                           (development / private-repo testing)
#   EXAKIT_NO_PROFILE_EDIT=1  never edit shell profiles; print the PATH
#                           line to add instead (default: the installer
#                           adds ~/.local/bin to the user's own profile)
#
#   Versions (the kit installs the tested set the maintainers publish in
#   versions.json; see MAINTAINERS.md and README "Staying up to date"):
#   EXAKIT_VERSION_POLICY=manifest|latest|pinned
#                           manifest (default) = the published tested set,
#                           latest = each component's own upstream,
#                           anything else = the kit's built-in fallbacks,
#                           no network
#   EXAKIT_VERSIONS_URL=... where that document is fetched from (https only)
#   EXAKIT_VERSIONS_TTL=n   seconds before the cached copy is refreshed
#   EXAKIT_NO_UPDATE_NOTICE=1  never print the once-a-day update notice that
#                           other exakit commands can show afterwards
#
#   Non-interactive answers (for agent-driven or scripted installs, so the
#   install honours a choice instead of silently taking the default):
#   EXAKIT_REUSE_DB=0|1     adopt an existing database: 1 reuse (default), 0 decline.
#                           On macOS declining never deletes; replacing a stopped
#                           deployment (and losing its data) needs EXAKIT_REPLACE_DB=1.
#   EXAKIT_MCP_CLIENTS=...  which MCP clients to configure, BY NAME (names are
#                           stable across releases; menu numbers are not):
#                           claude (= both the desktop app and the Claude Code
#                           CLI), claude_desktop, claude_code, codex, cursor,
#                           copilot, gemini, opencode, continue, all, or skip
#                           (e.g. "claude,cursor")
#   EXAKIT_SKIP_MCP=1       skip MCP client setup (run `exakit mcp-setup` later)
#   EXAKIT_DATASETS=...     which bundled datasets to load, by id (csv of
#                           data/datasets/<id>/ ids, e.g. "tpch,weather");
#                           takes precedence over EXAKIT_LOAD_SAMPLE
#   EXAKIT_LOAD_SAMPLE=0|1  0 skip data loading, 1 load the bundled sample (tpch)
#   EXAKIT_MARKETPLACE_ADDONS=...  answer the closing marketplace offer: add-on
#                           ids (csv, e.g. "dash-server"), all, or none; unset,
#                           a non-interactive install skips the offer
#   GITHUB_TOKEN=...        auth for downloading from a private repo
#
# Windows (PowerShell): use install.ps1 instead.
#
# The whole script is wrapped in main() so a truncated download cannot
# execute a half-fetched script.

set -u

main() {
    EXAKIT_HOME="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
    EXAKIT_REPO="${EXAKIT_REPO:-exasol-labs/exasol-personal-local-starterkit}"
    EXAKIT_REF="${EXAKIT_REF:-main}"
    kit_dir="$EXAKIT_HOME/kit"

    # Top-level installer actions: a blue bullet at the outer indent, matching
    # the step/gutter hierarchy the setup scripts use once ui.sh is loaded.
    # UTF-8 bullet only on UTF-8 locales; ASCII everywhere else.
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]*) _say_glyph='•' ;;
        *)              _say_glyph='*' ;;
    esac
    say() { printf '  \033[1;34m%s\033[0m %s\n' "$_say_glyph" "$*"; }
    # Record the reason before exiting. This runs before the kit's own logging
    # exists, so a failure here used to leave NOTHING behind: no log, no note.
    # An agent whose `curl | sh` died at platform detection had no artifact to
    # read in the next session and no way to tell "never ran" from "ran and
    # refused". Best-effort: a note is a nicety and must not mask the real error.
    fail() {
        printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2
        _fail_home="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
        if mkdir -p "$_fail_home" 2>/dev/null; then
            # TWO lines, matching exakit_note_failure: line 1 the reason, line 2
            # when it happened. `exakit status --json` reads the date off line 2,
            # and this writer left it empty — so the one failure an agent is most
            # likely to meet (the installer dying before the kit exists) produced
            # exactly the undated note that makes a healthy machine look broken
            # months later. date is POSIX; a missing one must not break the note.
            # Same format as _exakit_ts in common.sh, so both writers of this
            # file produce a line 2 the same reader can parse.
            printf '%s\n%s\n' "$*" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)" \
                > "$_fail_home/.last-failure" 2>/dev/null || true
        fi
        exit 1
    }

    # Banner + plan: reuse the kit's shared visual layer (setup/lib/ui.sh) so
    # the EXASOL wordmark and palette match the rest of the install exactly.
    # install.sh is POSIX sh and can't source that bash lib, so bridge through
    # `bash ui.sh __render_install_plan`; fall back to plain sh if bash or the
    # lib isn't there. Called after the kit is fetched (once ui.sh exists).
    render_banner_plan() {
        _ui="$kit_dir/setup/lib/ui.sh"
        if command -v bash >/dev/null 2>&1 && [ -f "$_ui" ]; then
            EXAKIT_UI_PLATFORM="$platform ($arch)" \
            EXAKIT_UI_TARGET="$target" \
            EXAKIT_UI_KIT="$kit_dir" \
            EXAKIT_UI_HOME="$EXAKIT_HOME" \
            bash "$_ui" __render_install_plan && return 0
        fi
        printf '\n  Exasol Personal Local Starter Kit\n\n'
    }

    # --- 1. preflight --------------------------------------------------------
    [ "$(id -u)" -ne 0 ] || fail "Please run as a regular user, not root."
    command -v curl >/dev/null 2>&1 || fail "curl is required."
    command -v tar  >/dev/null 2>&1 || fail "tar is required."
    # THIS SCRIPT is POSIX sh, but everything it hands off to is bash: the setup
    # scripts, every module under setup/lib, and the exakit command itself. Left
    # unchecked, a bash-less distro (Alpine/BusyBox, a minimal image) downloaded
    # and unpacked the whole kit and then died at `exec bash` with the shell's
    # own "exec: bash: not found" and exit 127 — past fail(), so not even a
    # .last-failure note was written for the next session to read. Checked here,
    # beside curl and tar, so the refusal comes before anything is downloaded.
    command -v bash >/dev/null 2>&1 || fail "bash is required (the setup scripts and the exakit command are bash). Install it with your package manager — e.g. 'sudo apk add bash', 'sudo apt-get install -y bash' or 'sudo dnf install -y bash' — then re-run this installer."

    # --- 2. detect -----------------------------------------------------------
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Darwin)
            platform="macos"
            target="Exasol Personal (local deployment)"
            setup_script="setup/setup-macos.sh"
            ;;
        Linux)
            # THE SAME UNION AS detect_os, and duplicated for the same reason
            # it always was: this runs before the kit is on disk, so detect.sh
            # cannot be sourced yet. Keeping the two in step is what
            # tests/agent-operability.sh now asserts - a fix to one of them
            # used to leave the other wrong, silently, on the platform where
            # the answer changes the most.
            if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -e /run/WSL ] ||
               [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] ||
               grep -qi microsoft /proc/version 2>/dev/null; then
                platform="wsl"
            else
                platform="linux"
            fi
            # WSL takes the Linux road, because to the launcher it IS Linux: a
            # WSL2 distro runs a real kernel on AMD64, the launcher ships a
            # Linux build, and its Linux local runtime wants one thing, a podman
            # on PATH. setup-linux.sh then checks that and says so before
            # anything is downloaded.
            target="Exasol Personal (local deployment via Podman)"
            setup_script="setup/setup-linux.sh"
            ;;
        *)
            fail "Unsupported platform: $os. On Windows, run install.ps1 in PowerShell."
            ;;
    esac
    case "$arch" in
        arm64|aarch64|x86_64|amd64) : ;;
        *) fail "Unsupported CPU architecture: $arch" ;;
    esac

    # --- 3. fetch the kit ----------------------------------------------------
    # A DRY RUN WRITES NOTHING UNDER EXAKIT_HOME. It used to unpack into
    # $EXAKIT_HOME/kit, which first empties the copy an installed exakit loads
    # its code from, and then said "nothing was installed". It unpacks into a
    # scratch directory instead, so a dry run over a working install changes
    # nothing about it.
    if [ "${EXAKIT_DRY_RUN:-0}" = "1" ]; then
        kit_dir="$(mktemp -d "${TMPDIR:-/tmp}/exakit-dry-run.XXXXXX")" \
            || fail "Could not create a temporary directory for the dry run. Check that ${TMPDIR:-/tmp} is writable and the disk is not full."
    fi
    # The failure text names the OWNERSHIP case explicitly. "Check that it is
    # writable" is not an action, and the documented escape hatch for a
    # /mnt/c or cloud-synced HOME (EXAKIT_HOME=/opt/exakit) lands here on every
    # distro, because /opt is root-owned — while the installer separately, and
    # correctly, refuses to be run with sudo. The two messages read as a
    # contradiction unless this one says which sudo command is the right one.
    mkdir -p "$kit_dir" || fail "Could not create $kit_dir: $EXAKIT_HOME is not writable by $(id -un). If EXAKIT_HOME points at a system path such as /opt, create it and take ownership once — sudo mkdir -p '$EXAKIT_HOME' && sudo chown \"\$(id -un)\" '$EXAKIT_HOME' — then re-run this installer as your normal user (never with sudo). Otherwise pick a path you own, or check the disk is not full."
    if [ -n "${EXAKIT_LOCAL_KIT:-}" ]; then
        [ -f "$EXAKIT_LOCAL_KIT/install.sh" ] || fail "EXAKIT_LOCAL_KIT does not look like a kit checkout: $EXAKIT_LOCAL_KIT"
        EXAKIT_KIT_SOURCE="local:$EXAKIT_LOCAL_KIT"
        export EXAKIT_KIT_SOURCE
        say "Using local kit checkout: $EXAKIT_LOCAL_KIT"
        find "$kit_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        cp -R "$EXAKIT_LOCAL_KIT"/. "$kit_dir/"
        rm -rf "$kit_dir/.git"
    else
        EXAKIT_KIT_SOURCE="$EXAKIT_REPO@$EXAKIT_REF"
        export EXAKIT_KIT_SOURCE
        # Stamped so setup can say how long the bootstrap took before its first
        # step: on some fresh installs `exakit status` was unavailable for over a
        # minute after this line and nothing recorded where the time went.
        EXAKIT_INSTALL_T0="$(date +%s)"; export EXAKIT_INSTALL_T0
        say "Downloading the starter kit ($EXAKIT_REPO@$EXAKIT_REF)"
        tmp_tar="$(mktemp "${TMPDIR:-/tmp}/exakit-src.XXXXXX")" \
            || fail "Could not create a temporary file. Check that ${TMPDIR:-/tmp} is writable and the disk is not full."
        # Fetch with the auth header ONLY when a token is set. Passing it via
        # ${auth_header:+-H "..."} word-splits the header value into separate
        # argv tokens (a real bug), so branch explicitly instead. --max-time
        # caps a stalled transfer so a hung connection can't hang forever.
        _fetch_kit() {
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                curl -fL --proto '=https' --retry 3 --connect-timeout 15 --max-time 300 -sS \
                    -H "Authorization: Bearer $GITHUB_TOKEN" -o "$tmp_tar" "$1"
            else
                curl -fL --proto '=https' --retry 3 --connect-timeout 15 --max-time 300 -sS \
                    -o "$tmp_tar" "$1"
            fi
        }
        _fetch_kit "https://github.com/$EXAKIT_REPO/archive/refs/heads/$EXAKIT_REF.tar.gz" \
            || _fetch_kit "https://github.com/$EXAKIT_REPO/archive/refs/tags/$EXAKIT_REF.tar.gz" \
            || fail "Could not download the kit from github.com/$EXAKIT_REPO ($EXAKIT_REF). Check your internet connection or proxy (set HTTPS_PROXY if needed); if the repository is private, set GITHUB_TOKEN or use EXAKIT_LOCAL_KIT."

        # Replace previous kit copy so re-runs always use the fetched ref.
        find "$kit_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        tar -xzf "$tmp_tar" -C "$kit_dir" --strip-components 1 \
            || fail "Could not extract the kit archive."
        rm -f "$tmp_tar"
    fi

    if [ "${EXAKIT_PREFLIGHT:-0}" = "1" ]; then
        exec bash -c ". '$kit_dir/setup/lib/detect.sh'; preflight_report"
    fi

    # --- 4. show the plan ----------------------------------------------------
    render_banner_plan

    if [ "${EXAKIT_DRY_RUN:-0}" = "1" ]; then
        say "Dry run requested (EXAKIT_DRY_RUN=1) — nothing was installed, and nothing under $EXAKIT_HOME was changed."
        say "The kit is unpacked for inspection in a temporary folder: $kit_dir"
        say "To install, run the same command again without EXAKIT_DRY_RUN=1."
        exit 0
    fi

    # --- 5. hand off ---------------------------------------------------------
    # When piped (curl | sh), stdin is the exhausted pipe. Reattach the
    # terminal when one is available so any interactive step (for example a
    # first-run license confirmation) can still read the keyboard.
    # THE INSTALLER AND THE KIT CAN COME FROM DIFFERENT PLACES. This file is
    # fetched by URL and piped to sh; the KIT it unpacks comes from $repo,
    # which defaults to the upstream repository whatever URL this file was read
    # from. So `curl .../<a fork>/install.sh | sh` installs a fork's installer
    # over the UPSTREAM kit, and when the two layouts differ the handoff below
    # died on "No such file or directory" - a path, and no hint that two
    # repositories were in play. Twin of the same guard in install.ps1.
    if [ ! -f "$kit_dir/$setup_script" ]; then
        printf '\n'
        say "The kit came from $EXAKIT_REPO@$EXAKIT_REF and has no $setup_script in it."
        say "The installer is read from a URL, but the kit is taken from EXAKIT_REPO,"
        say "which is '$EXAKIT_REPO' unless you say otherwise. If you fetched this"
        say "installer from a fork or a branch, name it for the kit as well:"
        say "  EXAKIT_REPO=owner/name EXAKIT_REF=branch curl -fsSL <url> | sh"
        say "The download is at $kit_dir."
        printf '\n'
        fail "This installer and the kit it downloaded do not match. Nothing was installed."
    fi
    _bootstrap_s=""
    [ -n "${EXAKIT_INSTALL_T0:-}" ] && _bootstrap_s=" ($(( $(date +%s) - EXAKIT_INSTALL_T0 ))s after start)"
    say "Starting setup: $setup_script$_bootstrap_s"
    printf '\n'
    # We already showed the banner above; tell the setup script to skip its
    # own so the wordmark appears exactly once through the installer. A direct
    # `bash setup/setup-*.sh` run (no installer) still shows it.
    export EXAKIT_BANNER_SHOWN=1
    if [ ! -t 0 ] && (: < /dev/tty) 2>/dev/null; then
        exec bash "$kit_dir/$setup_script" < /dev/tty
    else
        exec bash "$kit_dir/$setup_script"
    fi
}

main "$@"
