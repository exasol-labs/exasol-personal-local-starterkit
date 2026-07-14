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
#   Non-interactive answers (for agent-driven or scripted installs, so the
#   install honours a choice instead of silently taking the default):
#   EXAKIT_REUSE_DB=0|1     reuse a running database (macOS): 0 deploy fresh, 1 reuse
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
    fail() { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

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
            if grep -qi microsoft /proc/version 2>/dev/null; then
                platform="wsl"
            else
                platform="linux"
            fi
            target="Exasol Nano (container: Docker preferred, Podman fallback)"
            setup_script="setup/setup-wsl.sh"
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
    mkdir -p "$kit_dir" || fail "Could not create $kit_dir. Check that $EXAKIT_HOME is writable and the disk is not full."
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
        say "Dry run requested (EXAKIT_DRY_RUN=1) — nothing was installed."
        say "Inspect the scripts under $kit_dir, then run:"
        printf '    bash %s/%s\n\n' "$kit_dir" "$setup_script"
        exit 0
    fi

    # --- 5. hand off ---------------------------------------------------------
    # When piped (curl | sh), stdin is the exhausted pipe. Reattach the
    # terminal when one is available so any interactive step (for example a
    # first-run license confirmation) can still read the keyboard.
    # Name the platform, not just the script: setup-wsl.sh also serves native
    # Linux, and a Linux user reading "setup-wsl" wonders if WSL is required.
    case "$setup_script" in
        */setup-wsl.sh) say "Starting setup: $setup_script (shared Linux / WSL setup)" ;;
        *)              say "Starting setup: $setup_script" ;;
    esac
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
