#!/usr/bin/env bash
# common.sh — shared helpers for the Exasol Personal Local Starter Kit.
#
# Sourced by setup-*.sh, exakit, and upgrade scripts. Not meant to be executed
# directly. Compatible with bash 3.2 (macOS default).
#
# Provides:
#   - structured logging (console + log file under ~/.exasol-starter-kit/logs)
#   - install manifest read/write (~/.exasol-starter-kit/manifest.json)
#   - step tracking for idempotent re-runs
#   - rollback registration and failure handling
#   - component version resolution (latest by default, overridable via env)
#   - download + SHA-256 verification helpers

# ---------------------------------------------------------------------------
# Shared visual layer (banner, boxes, spinner, colour palette)
# ---------------------------------------------------------------------------
# ui.sh owns how the installer LOOKS. Source it first so info/ok/begin_step/
# connection_panel below can use its glyphs and palette. If it is somehow
# absent, install no-op stubs so nothing here breaks under `set -u`.
_exakit_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _exakit_common_dir=''
[ -n "$_exakit_common_dir" ] && [ -f "$_exakit_common_dir/ui.sh" ] && . "$_exakit_common_dir/ui.sh"
if ! command -v ui_spin_begin >/dev/null 2>&1; then
    UI_FANCY=0; UI_RESET=''; UI_BOLD=''; UI_DIM=''; UI_ACCENT=''
    UI_INFO=''; UI_OK=''; UI_WARN=''; UI_ERR=''; UI_ASK=''
    UI_TICK='[ok]'; UI_CROSS='[x]'; UI_ARROW='>'; UI_BULLET='-'
    ui_spin_begin() { :; }; ui_spin_end() { :; }; ui_restore_cursor() { :; }
    ui_banner()     { printf '\n  %s\n' "${1:-Exasol Personal Local Starter Kit}"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; printf '\n'; }
    ui_panel_begin() { printf '\n  -- %s --\n' "${1:-}"; }
    ui_panel_line()  { printf '   %s\n' "$1"; }
    ui_panel_end()   { printf '\n'; }
fi

# ---------------------------------------------------------------------------
# State locations
# ---------------------------------------------------------------------------
EXAKIT_HOME="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
EXAKIT_LOG_DIR="$EXAKIT_HOME/logs"
EXAKIT_CACHE_DIR="$EXAKIT_HOME/cache"
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
EXAKIT_MCP_DIR="$EXAKIT_HOME/mcp"
EXAKIT_CREDS_DIR="$EXAKIT_HOME/credentials"
# Where an approved query is saved so it can be re-run tomorrow. The skill's
# closing step ("make it rerunnable") names this directory by name, so it has to
# exist: telling an agent to write into a path nothing creates turns the last
# step of the trust loop into an mkdir it has to guess at.
EXAKIT_WORKFLOWS_DIR="$EXAKIT_HOME/workflows"
EXAKIT_BIN_DIR="${EXAKIT_BIN_DIR:-$HOME/.local/bin}"
EXAKIT_MANAGED_PYTHON_VERSION="${EXAKIT_MANAGED_PYTHON_VERSION:-3.12}"
EXAKIT_MCP_READONLY_USER="${EXAKIT_MCP_READONLY_USER:-mcp_readonly}"
EXAKIT_MCP_READONLY_SCHEMAS="${EXAKIT_MCP_READONLY_SCHEMAS:-STARTER_KIT}"

# ---------------------------------------------------------------------------
# Component version policy
# ---------------------------------------------------------------------------
# manifest (default) — take the version set the maintainers tested together,
#                      from versions.json (see below).
# latest             — resolve each Component independently from its upstream
#                      (GitHub releases, PyPI). The escape hatch for
#                      anyone who wants the newest of everything.
# anything else       — install the *_FALLBACK versions below and touch no
#                      network at all.
EXAKIT_VERSION_POLICY="${EXAKIT_VERSION_POLICY:-manifest}"
EXAKIT_PERSONAL_VERSION="${EXAKIT_PERSONAL_VERSION:-}"
EXAKIT_EXAPUMP_VERSION="${EXAKIT_EXAPUMP_VERSION:-}"
EXAKIT_MCP_PACKAGE="${EXAKIT_MCP_PACKAGE:-exasol-mcp-server}"
EXAKIT_MCP_VERSION="${EXAKIT_MCP_VERSION:-}"
EXAKIT_PYEXASOL_VERSION="${EXAKIT_PYEXASOL_VERSION:-}"

# Last-known-good fallbacks are used only when a latest-version lookup is not
# possible (offline install, API rate limit, private mirror). Successful latest
# resolutions are recorded in the manifest so later updates compare against the
# version that was actually installed.
# A RELEASE CANDIDATE, and candidates are deleted. rc2 and rc3 were both
# removed upstream while pinned here, and the second one reached a user as a
# 404 mid-install with the launcher half-downloaded. So this constant and
# components.personal.version in versions.json move together, and they move to
# a release that still exists - check before pinning, not after.
# 2.3.0 FINAL since 2026-09-21, so no candidate is pinned here any more - the
# two deletions above were both candidates, and a published release is not
# removed the same way. Verified before pinning, as the note above demands:
# v2.3.0 on exasol/exasol-personal is published, not a draft, not a
# prerelease, and carries every asset this kit fetches - the macOS and Linux
# arm64/x86_64 tarballs, the Windows x86_64 zip, and
# exasol-personal_2.3.0_checksums.txt.
EXAKIT_PERSONAL_VERSION_FALLBACK="${EXAKIT_PERSONAL_VERSION_FALLBACK:-2.3.0}"
EXAKIT_EXAPUMP_VERSION_FALLBACK="${EXAKIT_EXAPUMP_VERSION_FALLBACK:-0.13.0}"
EXAKIT_MCP_VERSION_FALLBACK="${EXAKIT_MCP_VERSION_FALLBACK:-2.2.0}"
EXAKIT_PYEXASOL_VERSION_FALLBACK="${EXAKIT_PYEXASOL_VERSION_FALLBACK:-2.4.1}"
# Marketplace add-ons (dash-server, ...) carry their own version constants in
# their module files — they are not part of the install flow, so nothing here
# needs to know them.

EXAKIT_PERSONAL_REPO="exasol/exasol-personal"
EXAKIT_EXAPUMP_REPO="exasol-labs/exapump"
# Captured before the default lands: the manifest resolution below must never
# outrank an answer the caller gave in the environment.
_EXAKIT_KIT_REPO_FROM_ENV="${EXAKIT_KIT_REPO:-${EXAKIT_REPO:-}}"
EXAKIT_KIT_REPO="${EXAKIT_KIT_REPO:-${EXAKIT_REPO:-exasol-labs/exasol-personal-local-starterkit}}"
# --retry-all-errors landed in curl 7.71. Without it plain --retry ignores the
# mid-stream transport failures that actually strand a large download, so it is
# worth having where available and must be absent where not: an unknown flag
# makes curl exit 2 and fail the download it was meant to save.
#
# LAZY, AND MEMOISED. A first cut of this probe ran at SOURCE time, which meant
# every single exakit invocation paid for a curl subprocess before it did
# anything - and, worse, that `exakit status --json` reached for curl at all.
# A read-only state query must not touch the network stack even to ask a
# question about it; tests/agent-audit.sh pins exactly that with a stub curl
# that leaves a fingerprint when it is run. Answered once, on the first real
# download, and remembered for the rest of the process.
_exakit_curl_retry_all() {
    if [ -z "${_EXAKIT_CURL_RETRY_ALL_CACHED:-}" ]; then
        if curl --help all 2>/dev/null | grep -q -- "--retry-all-errors"; then
            _EXAKIT_CURL_RETRY_ALL="--retry-all-errors"
        else
            _EXAKIT_CURL_RETRY_ALL=""
        fi
        _EXAKIT_CURL_RETRY_ALL_CACHED=1
    fi
    printf '%s' "$_EXAKIT_CURL_RETRY_ALL"
}
EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT="${EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT:-5}"
EXAKIT_VERSION_LOOKUP_MAX_TIME="${EXAKIT_VERSION_LOOKUP_MAX_TIME:-12}"

# The versions manifest (versions.json at the root of the kit repository on
# main) is the maintainer-edited record of the version set that was tested
# together. It is fetched over plain HTTPS from GitHub's raw endpoint — the same
# trust domain that already serves install.sh — and cached under the kit home.
# Nothing is collected on our side: the request carries a User-Agent header and
# no query string, and no third party is involved.
_EXAKIT_VERSIONS_URL_FROM_ENV="${EXAKIT_VERSIONS_URL:-}"
EXAKIT_VERSIONS_URL="${EXAKIT_VERSIONS_URL:-https://raw.githubusercontent.com/${EXAKIT_KIT_REPO}/main/versions.json}"

# --- an installed kit follows its own source ---------------------------------
#
# EXAKIT_KIT_REPO names the repository this kit copy talks to at runtime: the
# versions manifest above, `exakit update exakit` (which replaces this very
# kit), and the skills refresh all download from it. Its default is the
# repository the product is published from - right for a fresh curl|sh, and
# silently wrong for every kit installed from a fork. The manifest records
# where a kit really came from (kit.source), and the release assets already
# follow it (json_tables_mirror_repo) - but these URLs kept pointing at the
# default. The result was a split brain no fork install could verify: add-on
# assets downloaded from the fork, digest pins fetched from the default, and
# every install ending in a checksum mismatch that looked like corruption.
# Worse, `exakit update exakit` would quietly replace a fork's kit with the
# default repository's code.
#
# So when the environment named no repository, the manifest decides. An
# explicit EXAKIT_KIT_REPO / EXAKIT_REPO / EXAKIT_VERSIONS_URL still outranks
# it - pointing one command somewhere else is a deliberate act. Self-contained
# on purpose: manifest_get is not defined yet and requires python3 fatally,
# while a kit source is three fields of one line - and a machine with no
# python3, or no manifest, simply keeps the default.
# The macOS Command Line Tools stub (see _exakit_python3_is_xcode_stub, which is
# not defined yet) is ruled out inline: running it pops the developer-tools
# dialog, and this runs on every exakit command.
if [ -z "$_EXAKIT_KIT_REPO_FROM_ENV" ] && [ -f "$EXAKIT_MANIFEST" ] && \
   command -v python3 >/dev/null 2>&1 && \
   ! { [ "$(command -v python3)" = /usr/bin/python3 ] && [ -x /usr/bin/xcode-select ] && \
       ! /usr/bin/xcode-select -p >/dev/null 2>&1; }; then
    _ekr_src="$(python3 - "$EXAKIT_MANIFEST" <<'EXAKIT_KIT_SRC_PY' 2>/dev/null
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
src = ((doc.get("kit") or {}).get("source") or "").strip()
repo = src.split("@", 1)[0]
parts = repo.split("/")
ok = (len(parts) == 2 and all(p and all(c.isalnum() or c in "._-" for c in p)
                              for p in parts))
print(repo if ok else "")
EXAKIT_KIT_SRC_PY
)" || _ekr_src=""
    if [ -n "$_ekr_src" ]; then
        EXAKIT_KIT_REPO="$_ekr_src"
        [ -z "$_EXAKIT_VERSIONS_URL_FROM_ENV" ] && \
            EXAKIT_VERSIONS_URL="https://raw.githubusercontent.com/${EXAKIT_KIT_REPO}/main/versions.json"
    fi
fi
# The public install entry point, which is NOT the raw repository URL: someone
# reinstalling months from now should be sent to the address the product
# publishes, not to a branch of whichever repository built their copy.
EXAKIT_INSTALL_URL="${EXAKIT_INSTALL_URL:-https://www.exasol.com/install/starter-kit.sh}"
EXAKIT_VERSIONS_TTL="${EXAKIT_VERSIONS_TTL:-86400}"
# How long a FAILED versions fetch is remembered, so a network that cannot
# reach the manifest is asked once rather than once per command. Deliberately
# far shorter than the TTL: a machine that comes back online should pick the
# manifest up within minutes, not tomorrow.
EXAKIT_VERSIONS_RETRY_COOLDOWN="${EXAKIT_VERSIONS_RETRY_COOLDOWN:-900}"
EXAKIT_VERSIONS_CACHE="${EXAKIT_VERSIONS_CACHE:-$EXAKIT_CACHE_DIR/versions.json}"
# Schema the client understands. A document that announces a higher number is
# treated as unavailable (the resolution chain falls back) rather than guessed
# at — a newer kit knows how to read it.
EXAKIT_VERSIONS_SCHEMA=1
# Which tier of the chain actually answered, recorded as desired.versions_source
# so a support question ("where did this version come from?") has an answer.
EXAKIT_VERSIONS_SOURCE_USED=""

# Marketplace add-on "About" text. The one-line description the marketplace
# shows for an add-on is NOT stored in this repository: it is the About field of
# the add-on's own repository, fetched once and cached, so the tool that owns
# the wording owns it in exactly one place. The cache is what makes that safe to
# do in front of an interactive menu -- see exakit_marketplace_addon_description
# for the full resolution order, including what happens with no network at all.
EXAKIT_ABOUT_URL="${EXAKIT_ABOUT_URL:-https://api.github.com/repos}"
EXAKIT_ABOUT_TTL="${EXAKIT_ABOUT_TTL:-86400}"
EXAKIT_ABOUT_CACHE_DIR="${EXAKIT_ABOUT_CACHE_DIR:-$EXAKIT_CACHE_DIR/about}"
EXAKIT_ABOUT_OFFLINE="${EXAKIT_ABOUT_OFFLINE:-0}"
# Hard ceiling on a cached About line, in bytes. A repository we do not control
# decides this string's length; nothing downstream should have to cope with an
# unbounded one.
EXAKIT_ABOUT_MAX_LEN="${EXAKIT_ABOUT_MAX_LEN:-200}"
# Width of the Description cell, in the table and in the checkbox label alike.
# The table's rule is 74 columns and the two leading cells spend 30 of them.
EXAKIT_ABOUT_WIDTH="${EXAKIT_ABOUT_WIDTH:-44}"

# Remember whether the environment named the port: an explicit value wins
# everywhere, but the default must yield to the port the install RECORDED
# (runtime.dsn) once there is one.
EXAKIT_DB_PORT_EXPLICIT="${EXAKIT_DB_PORT:+1}"
EXAKIT_DB_PORT="${EXAKIT_DB_PORT:-8563}"

# VALIDATED HERE, at the one place the value enters the kit. A port typed wrong
# used to travel all the way to the container engine and come back as the
# engine's own complaint -- "invalid published port", six frames down, naming
# neither the variable nor what was wrong with it. A leading zero is rejected
# too: `[ 08563 -lt 1 ]` is an arithmetic error in bash, not a comparison, so
# the range test below would itself fail on one. Exit 2 is the contract's
# "bad input", the same code an unknown subcommand answers with. die() and the
# UI palette are defined much further down this file, so this speaks plainly.
case "$EXAKIT_DB_PORT" in
    ''|*[!0-9]*|0*)
        printf '\n  [x] EXAKIT_DB_PORT must be a whole number from 1 to 65535, with no leading zero (got: %s)\n\n' "$EXAKIT_DB_PORT" >&2
        exit 2
        ;;
esac
if [ "$EXAKIT_DB_PORT" -gt 65535 ]; then
    printf '\n  [x] EXAKIT_DB_PORT must be a whole number from 1 to 65535 (got: %s)\n\n' "$EXAKIT_DB_PORT" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
exakit_init_logging() {
    mkdir -p "$EXAKIT_LOG_DIR"
    if [ -z "${EXAKIT_LOG_FILE:-}" ]; then
        EXAKIT_LOG_FILE="$EXAKIT_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
        : > "$EXAKIT_LOG_FILE"
        chmod 600 "$EXAKIT_LOG_FILE"
    fi
    export EXAKIT_LOG_FILE
}

_exakit_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_exakit_log_file() {
    [ -n "${EXAKIT_LOG_FILE:-}" ] || return 0
    # Best-effort: the log directory may already be gone (e.g. during
    # `uninstall`, which deletes the kit home). A failed redirection-open is
    # reported to the *group's* stderr before a trailing `2>/dev/null` on the
    # printf would apply, so redirect at the group level and also skip early if
    # the directory is missing. Never let logging fail a command.
    [ -d "$(dirname "$EXAKIT_LOG_FILE")" ] || return 0
    { printf '%s %s\n' "$(_exakit_ts)" "$*" >> "$EXAKIT_LOG_FILE"; } 2>/dev/null || return 0
}

# Glyphs/colours come from the shared palette (ui.sh): bold + Unicode on an
# interactive UTF-8 terminal, plain ASCII with no escapes when piped/CI/log.
# Three visual levels under the banner: step headers (2-space, begin_step),
# actions (4-space dim bullet: info/prompts), and outcomes nested under their
# action (6-space: ✓ ok, ! warn, ✗ error — plus contained tool output). The
# nesting is what makes a step read as "action → what happened".
# EXAKIT_QUIET_DETAIL=1 — a caller is narrating a whole job on ONE line (an
# add-on install, a dataset load), so the steps underneath report to the LOGFILE
# instead of the screen. Gated here rather than at every call site: the chatter
# comes from a dozen places in four modules, and a gate per line is a gate
# somebody forgets. warn/error are deliberately NOT gated — a job that says
# nothing while it works must still say something when it goes wrong.
info() {
    [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ] || \
        printf '    %s%s%s %s\n' "${UI_DIM:-}" "${UI_BULLET:--}" "${UI_RESET:-}" "$*"
    _exakit_log_file "INFO  $*"
}
ok() {
    [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ] || \
        printf '      %s%s%s %s\n' "${UI_OK:-}" "${UI_TICK:-[ok]}" "${UI_RESET:-}" "$*"
    _exakit_log_file "OK    $*"
}
# ok_step / info_step — the lines a one-line step keeps.
#
# A step that narrates itself on one line sets EXAKIT_QUIET_DETAIL, which gates
# every info/ok underneath it to the logfile. That is the right default: the
# spinner is already saying what is happening. But each step still has one or
# two facts worth leaving on screen -- the profile name someone will type again,
# the path to a Python that is now on disk -- and they are printed from inside
# the same functions being quieted. These two say it anyway.
#
# The flag is saved and restored rather than cleared, so a step nested inside
# another quiet caller (an add-on install, a data load) does not tear a hole in
# ITS one-line narration either. ⇄ twins: OkStep/InfoStep in exakit-common.ps1.
ok_step() {
    _oks_prev="${EXAKIT_QUIET_DETAIL:-0}"
    EXAKIT_QUIET_DETAIL=0
    # The step these survive is usually a SPINNER, which owns its line -- so the
    # line has to be given back before printing or the outcome lands inside it.
    ui_spin_pause
    ok "$@"
    ui_spin_resume
    EXAKIT_QUIET_DETAIL="$_oks_prev"
}
info_step() {
    _ifs_prev="${EXAKIT_QUIET_DETAIL:-0}"
    EXAKIT_QUIET_DETAIL=0
    ui_spin_pause
    info "$@"
    ui_spin_resume
    EXAKIT_QUIET_DETAIL="$_ifs_prev"
}
# heading <text> — a green ▸ at the STEP indent (two spaces).
#
# Not an action and not an outcome, so neither the dim bullet nor the tick fits:
# this marks a heading the reader is meant to stop at — the add-on offer after
# the closing rule, the support line at the very end. The bullet made both read
# as one more thing the installer was doing.
#
# Two spaces, the same column as begin_step's own arrow, because that is what it
# IS: a top-level heading with its own children under it. At four it sat in the
# action gutter, level with the "Explore marketplace ?" question it introduces,
# and the two read as siblings when one contains the other. The glyph is the
# step header's, in the tick's green rather than the accent, and degrades to ">"
# in plain mode like every other arrow. Never gated by EXAKIT_QUIET_DETAIL:
# nothing that uses it runs inside a one-line step.
# ⇄ twin: Write-ExakitHeading in exakit-common.ps1.
heading() {
    printf '  %s%s%s %s\n' "${UI_OK:-}" "${UI_ARROW:->}" "${UI_RESET:-}" "$*"
    _exakit_log_file "INFO  $*"
}
# A LIVE ADD-ON TABLE OWNS THE SCREEN: it redraws its own frame, so anything
# printed underneath is written INTO it, and a warning that cannot be read is
# not a warning. Observed for real - a json-tables download failure arrived as
# "...eleases/download/..." spliced through the table rows, with the reason lost.
#
# _exakit_addon_note already defers for this, but every add-on module calls
# warn/error directly, so deferring HERE covers all of them and any future one.
# warn and error are exactly the two printers the quiet flag does NOT gate,
# which is why they are the two that reach the frame.
# twins: Warn2 and Write-ExakitError in exakit-common.ps1.
_exakit_defer_under_addon_table() {
    # THE FALLBACK BAR COUNTS TOO — see _exakit_addon_narration_live. A warning
    # printed beside a one-line bar that is still being redrawn wraps and pushes
    # the bar down, which is how one add-on's single bar came out as three
    # broken rows. Twin of Test-ExakitAddonNarrationLive in Warn2.
    _exakit_addon_narration_live || return 1
    EXAKIT_ADDON_NOTES="${EXAKIT_ADDON_NOTES}warn|$1
"
    return 0
}
warn() {
    if _exakit_defer_under_addon_table "$*"; then _exakit_log_file "WARN  $*"; return 0; fi
    printf '      %s!%s %s\n'  "${UI_WARN:-}" "${UI_RESET:-}" "$*" >&2
    _exakit_log_file "WARN  $*"
}
error() {
    if _exakit_defer_under_addon_table "$*"; then _exakit_log_file "ERROR $*"; return 0; fi
    printf '      %s%s%s %s\n' "${UI_ERR:-}"  "${UI_CROSS:-[x]}" "${UI_RESET:-}" "$*" >&2
    _exakit_log_file "ERROR $*"
}

# Menu rendering: options nest under the "Choose ..." action line with the
# number in the accent colour; the how-to-answer hint is a dim afterthought.
# usage: ui_menu_option <number> <label>; ui_menu_hint <text>
ui_menu_option() { printf '      %s%s.%s %s\n' "${UI_ACCENT:-}" "$1" "${UI_RESET:-}" "$2"; }
ui_menu_hint()   { printf '      %s%s%s\n' "${UI_DIM:-}" "$1" "${UI_RESET:-}"; }

# _ui_term_cols — the terminal's width, or a sane default. COLUMNS is not
# exported to scripts, and `tput cols` is a TRAP inside command substitution:
# its stdout is a pipe there, so it cannot ioctl the terminal and silently
# answers 80 — which made the menu miscount wrapped rows on any terminal that
# was not 80 columns and climb over the lines above it. `stty size` reads the
# terminal through stdin instead, which /dev/tty provides regardless of where
# stdout points.
_ui_term_cols() {
    _utc="${COLUMNS:-}"
    if [ -z "$_utc" ]; then
        set -- $(stty size < /dev/tty 2>/dev/null || true)
        _utc="${2:-}"
    fi
    [ -n "$_utc" ] || _utc="$(tput cols 2>/dev/null || true)"
    case "$_utc" in ''|*[!0-9]*) _utc=80 ;; esac
    [ "$_utc" -ge 20 ] || _utc=80
    printf '%s\n' "$_utc"
}

# _ui_fit_row <text> <chrome-cols> <terminal-cols> — the text, truncated so
# chrome + text CANNOT exceed one terminal line. The redraw arithmetic is only
# exact when every row is exactly one line: truncation makes that true by
# construction, instead of trusting width detection, locales and wrap rules to
# all agree. (bash counts characters here; in a non-UTF-8 locale it counts
# bytes, which only ever truncates EARLIER — still one line, never two.)
_ui_fit_row() {
    _ufr_text="$1"; _ufr_chrome="$2"; _ufr_cols="$3"
    if [ $(( ${#_ufr_text} + _ufr_chrome )) -gt "$_ufr_cols" ]; then
        _ufr_keep=$(( _ufr_cols - _ufr_chrome - 1 ))
        [ "$_ufr_keep" -gt 0 ] || _ufr_keep=1
        # bash substring, not `cut -c`: BSD cut counts bytes and can split a
        # multibyte character in half at the boundary.
        printf '%s…\n' "${_ufr_text:0:$_ufr_keep}"
        return 0
    fi
    printf '%s\n' "$_ufr_text"
}

# _ui_wrapped_lines <visible-columns> <terminal-columns> — how many terminal
# LINES a row of that width occupies. A row wider than the terminal wraps, and
# a redraw that assumed one line per row would leave the overflow on screen
# forever (every keypress stacking another stale copy). Menus therefore count
# what they actually drew instead of counting their rows.
_ui_wrapped_lines() {
    _uwl_w="$1"; _uwl_cols="$2"
    [ "$_uwl_w" -gt 0 ] 2>/dev/null || { printf '1\n'; return 0; }
    printf '%s\n' "$(( (_uwl_w + _uwl_cols - 1) / _uwl_cols ))"
}

# --- checkbox multi-select ---------------------------------------------------
# _ui_checkbox_toggle <selected_csv> <count> <input> — pure selection logic.
# Toggles the 1-based indices named in <input> (numbers separated by spaces or
# commas; "all" selects everything) in or out of <selected_csv>, echoing the
# new csv. Non-numeric or out-of-range tokens are ignored.
_ui_checkbox_toggle() {
    _ct_sel="$1"
    _ct_n="$2"
    _ct_in="$(printf '%s' "$3" | tr ',' ' ')"
    case " $_ct_in " in
        *" all "*|*" ALL "*|*" All "*)
            _ct_sel=""
            _ct_i=1
            while [ "$_ct_i" -le "$_ct_n" ]; do
                _ct_sel="${_ct_sel:+$_ct_sel,}$_ct_i"
                _ct_i=$((_ct_i + 1))
            done
            printf '%s' "$_ct_sel"
            return 0
            ;;
    esac
    for _ct_tok in $_ct_in; do
        case "$_ct_tok" in ''|*[!0-9]*) continue ;; esac
        [ "$_ct_tok" -ge 1 ] && [ "$_ct_tok" -le "$_ct_n" ] || continue
        case ",$_ct_sel," in
            *",$_ct_tok,"*)
                _ct_sel="$(printf ',%s,' "$_ct_sel" | sed "s/,$_ct_tok,/,/")"
                _ct_sel="${_ct_sel#,}"
                _ct_sel="${_ct_sel%,}"
                ;;
            *) _ct_sel="${_ct_sel:+$_ct_sel,}$_ct_tok" ;;
        esac
    done
    printf '%s' "$_ct_sel"
}

# ui_checkbox_menu <title> <defaults_csv> <label> [label ...] — multi-select
# rendered as checkboxes with a movable cursor: ↑/↓ (or j/k) move, Space
# toggles the highlighted option, Enter confirms and moves to the next step
# ("a" selects all). At least one option must stay selected (Enter on an
# empty selection re-asks). In fancy mode the block redraws in place so
# toggling feels live; plain mode reprints below. Non-interactive runs (and
# EOF on the input) keep the defaults and say so. The confirmed selection
# lands in EXAKIT_CHECKBOX_SELECTION as an ascending csv of 1-based indices.
#
# EXAKIT_CHECKBOX_EXCLUSIVE (optional, cleared after each call): 1-based index
# of an option that cannot be combined with the others — think "Skip".
# Selecting it clears every other choice; selecting any other choice clears it.
# "a" (select all) selects all non-exclusive options.
#
# EXAKIT_CHECKBOX_GROUP (optional, cleared after each call):
# "parent:first:last[:mode]" — row <parent> is a group checkbox whose children
# are rows <first>..<last> (header and disabled rows in that range are skipped).
# Toggling the parent ON selects every child; toggling it OFF clears them all.
# Toggling a child re-derives the parent:
#   mode "any" (default) — checked while ANY child is checked. The parent reads
#                          as a group header, e.g. "Sample datasets".
#   mode "all"           — checked only while EVERY child is checked, so the
#                          parent reads as a MASTER toggle: pick it and you get
#                          everything, untick any one row and it releases.
#   mode "master"        — like "all" downward, but the children may only
#                          RELEASE the parent, never claim it: ticking every
#                          child does NOT tick the parent. For a parent that is
#                          a SCOPE rather than an aggregate. "EVERYTHING" in the
#                          uninstall menu is one -- it removes the database,
#                          which no row above it represents, so "every add-on is
#                          ticked" must never come to mean "remove the kit".
# SEVERAL specs may be given, separated by whitespace, and they are applied IN
# ORDER. That is what nests them: the uninstall menu has "Add-ons only" as a
# master over the add-ons listed under it, and "EVERYTHING" as a master over
# that row and the add-ons together. The inner spec must come FIRST, so it has
# settled its own parent before the outer spec re-reads that parent as one of
# its own children.
EXAKIT_CHECKBOX_SELECTION=""
EXAKIT_CHECKBOX_EXCLUSIVE=""
EXAKIT_CHECKBOX_GROUP=""
# Published by ui_checkbox_menu for the group helpers: the rows that can
# actually be checked (headers and disabled rows excluded).
_UI_CHECKBOX_SELECTABLE=""

# _ui_checkbox_apply_group <selected_csv> <toggled_idx> <group_spec> — pure
# post-toggle parent/child rule, echoing the adjusted csv.
# _ui_checkbox_group_children <first> <last> — the SELECTABLE rows in a group's
# range. Header and disabled rows sit inside the range (a group can span a small
# tree) but can never be checked, so a select-all must skip them and an
# all-children rule must not wait for them. _UI_CHECKBOX_SELECTABLE is published
# by ui_checkbox_menu; empty means "every row is selectable" (pure callers, and
# the unit tests, can set it themselves).
_ui_checkbox_group_children() {
    _cgc_out=""
    _cgc_i="$1"
    while [ "$_cgc_i" -le "$2" ]; do
        if [ -z "${_UI_CHECKBOX_SELECTABLE:-}" ]; then
            _cgc_out="$_cgc_out $_cgc_i"
        else
            case " ${_UI_CHECKBOX_SELECTABLE} " in
                *" $_cgc_i "*) _cgc_out="$_cgc_out $_cgc_i" ;;
            esac
        fi
        _cgc_i=$((_cgc_i + 1))
    done
    printf '%s' "${_cgc_out# }"
}

# _ui_checkbox_apply_group <selection> <toggled-row> <specs>
# Applies every spec in <specs>, in order. One spec is the common case and
# iterates exactly once, so nothing that passed a single spec changes.
_ui_checkbox_apply_group() {
    _cga_sel="$1"; _cga_toggled="$2"; _cga_specs="$3"
    [ -n "$_cga_specs" ] || { printf '%s' "$_cga_sel"; return 0; }
    for _cga_spec in $_cga_specs; do
        _cga_sel="$(_ui_checkbox_apply_one_group "$_cga_sel" "$_cga_toggled" "$_cga_spec")"
    done
    printf '%s' "$_cga_sel"
}

_ui_checkbox_apply_one_group() {
    _cg_sel="$1"; _cg_toggled="$2"; _cg_spec="$3"
    [ -n "$_cg_spec" ] || { printf '%s' "$_cg_sel"; return 0; }
    _cg_parent="${_cg_spec%%:*}"
    _cg_rest="${_cg_spec#*:}"
    _cg_first="${_cg_rest%%:*}"
    _cg_rest="${_cg_rest#*:}"
    _cg_last="${_cg_rest%%:*}"
    # Optional 4th field: "all" makes the parent a MASTER toggle — checked only
    # while EVERY child is checked, so unticking any one of them unticks it.
    # Default "any" (the parent is a group header: checked while any child is).
    case "$_cg_spec" in
        *:*:*:*) _cg_mode="${_cg_spec##*:}" ;;
        *)       _cg_mode="any" ;;
    esac
    _cg_children="$(_ui_checkbox_group_children "$_cg_first" "$_cg_last")"
    if [ "$_cg_toggled" = "$_cg_parent" ]; then
        # Parent toggled: rebuild the child range to match the parent's state.
        case ",$_cg_sel," in
            *",$_cg_parent,"*) _cg_parent_on=1 ;;
            *) _cg_parent_on=0 ;;
        esac
        _cg_out=""
        for _cg_tok in $(printf '%s' "$_cg_sel" | tr ',' ' '); do
            if [ "$_cg_tok" -ge "$_cg_first" ] && [ "$_cg_tok" -le "$_cg_last" ]; then
                continue
            fi
            _cg_out="${_cg_out:+$_cg_out,}$_cg_tok"
        done
        if [ "$_cg_parent_on" = 1 ]; then
            for _cg_i in $_cg_children; do
                _cg_out="${_cg_out:+$_cg_out,}$_cg_i"
            done
        fi
        printf '%s' "$_cg_out"
        return 0
    fi
    if [ "$_cg_toggled" -ge "$_cg_first" ] && [ "$_cg_toggled" -le "$_cg_last" ]; then
        # Child toggled: re-derive the parent from the children.
        _cg_on=0
        if [ "$_cg_mode" = "master" ]; then
            # A child that just went ON leaves the parent exactly as it was; only
            # a child going OFF may release it. Without this, giving "Add-ons
            # only" a group of its own meant one click on that row ticked every
            # row EVERYTHING watches -- and armed a full-kit uninstall, database
            # included, that the reader never asked for.
            case ",$_cg_sel," in
                *",$_cg_toggled,"*) printf '%s' "$_cg_sel"; return 0 ;;
            esac
        elif [ "$_cg_mode" = "all" ]; then
            _cg_on=1
            for _cg_i in $_cg_children; do
                case ",$_cg_sel," in
                    *",$_cg_i,"*) ;;
                    *) _cg_on=0; break ;;
                esac
            done
        else
            for _cg_i in $_cg_children; do
                case ",$_cg_sel," in *",$_cg_i,"*) _cg_on=1; break ;; esac
            done
        fi
        _cg_out=""
        for _cg_tok in $(printf '%s' "$_cg_sel" | tr ',' ' '); do
            [ "$_cg_tok" = "$_cg_parent" ] && continue
            _cg_out="${_cg_out:+$_cg_out,}$_cg_tok"
        done
        [ "$_cg_on" = 1 ] && _cg_out="${_cg_out:+$_cg_out,}$_cg_parent"
        printf '%s' "$_cg_out"
        return 0
    fi
    printf '%s' "$_cg_sel"
}

# _ui_checkbox_apply_exclusive <selected_csv> <toggled_idx> <exclusive_idx> —
# pure post-toggle rule, echoing the adjusted csv.
_ui_checkbox_apply_exclusive() {
    _ce_sel="$1"; _ce_toggled="$2"; _ce_excl="$3"
    [ -n "$_ce_excl" ] || { printf '%s' "$_ce_sel"; return 0; }
    if [ "$_ce_toggled" = "$_ce_excl" ]; then
        # The exclusive option was just toggled: if it landed selected, it
        # becomes the only selection.
        case ",$_ce_sel," in
            *",$_ce_excl,"*) printf '%s' "$_ce_excl" ;;
            *) printf '%s' "$_ce_sel" ;;
        esac
        return 0
    fi
    # Any other toggle drops the exclusive option from the selection.
    _ce_sel="$(printf ',%s,' "$_ce_sel" | sed "s/,$_ce_excl,/,/")"
    _ce_sel="${_ce_sel#,}"; _ce_sel="${_ce_sel%,}"
    printf '%s' "$_ce_sel"
}

ui_checkbox_menu() {
    _cb_title="$1"
    _cb_defaults="$2"
    shift 2
    _cb_sel="$_cb_defaults"
    _cb_n=$#
    _cb_labels=("$@")
    info "$_cb_title"

    # A label starting with "#" is a GROUP HEADER: rendered as a plain caption
    # (no checkbox), never selectable, and skipped by the cursor. Headers let a
    # menu show a small tree — e.g. "Sample datasets" with the individual
    # datasets indented beneath it — while selection indices stay flat.
    # A label starting with "!" is a DISABLED row: rendered as a dimmed,
    # unchecked checkbox (the label should say why — e.g. "· not installed"),
    # never selectable, skipped by the cursor, and excluded from "a". Disabled
    # rows let a menu show the full set of options while only the applicable
    # ones can be chosen.
    _cb_is_header() {
        case "${_cb_labels[$(($1 - 1))]}" in "#"*) return 0 ;; *) return 1 ;; esac
    }
    _cb_is_disabled() {
        case "${_cb_labels[$(($1 - 1))]}" in "!"*) return 0 ;; *) return 1 ;; esac
    }
    _cb_step() { # _cb_step <dir:+1|-1> — move the cursor, skipping headers/disabled
        _cb_steps=0
        while [ "$_cb_steps" -lt "$_cb_n" ]; do
            _cb_cur=$((_cb_cur + $1))
            [ "$_cb_cur" -lt 1 ] && _cb_cur=$_cb_n
            [ "$_cb_cur" -gt "$_cb_n" ] && _cb_cur=1
            if ! _cb_is_header "$_cb_cur" && ! _cb_is_disabled "$_cb_cur"; then
                return 0
            fi
            _cb_steps=$((_cb_steps + 1))
        done
    }
    _cb_cur=0
    _cb_step 1                                            # first selectable row

    # Publish the checkable rows for the group helpers: a select-all must skip
    # headers and disabled rows, and an all-children rule must not wait on them.
    _UI_CHECKBOX_SELECTABLE=""
    _cb_i=1
    while [ "$_cb_i" -le "$_cb_n" ]; do
        if ! _cb_is_header "$_cb_i" && ! _cb_is_disabled "$_cb_i"; then
            _UI_CHECKBOX_SELECTABLE="${_UI_CHECKBOX_SELECTABLE:+$_UI_CHECKBOX_SELECTABLE }$_cb_i"
        fi
        _cb_i=$((_cb_i + 1))
    done

    # The keyboard hint has to describe what the keys actually DO. On an
    # either/or menu — exactly two selectable rows, one of them exclusive —
    # Space does not toggle anything a reader would call a toggle: it moves the
    # tick from one answer to the other, which is choosing. "Toggle" invited
    # people to switch both off (Enter then silently refuses, because at least
    # one selection is required) or to read two answers to one question as two
    # independent switches. A real multi-select keeps "toggle", which is exactly
    # what Space does there.
    #
    # Derived from the menu's shape rather than set per call site, so a new
    # either/or menu gets the right hint without anyone remembering to ask.
    _cb_sel_n=0
    for _cb_s in $_UI_CHECKBOX_SELECTABLE; do _cb_sel_n=$((_cb_sel_n + 1)); done
    if [ -n "${EXAKIT_CHECKBOX_EXCLUSIVE:-}" ] && [ "$_cb_sel_n" -eq 2 ]; then
        _cb_space='Space to select'
    else
        _cb_space='Space to toggle'
    fi

    _cb_tty="$(_exakit_prompt_tty)"
    if [ -z "$_cb_tty" ]; then
        EXAKIT_CHECKBOX_SELECTION="$_cb_defaults"
        EXAKIT_CHECKBOX_EXCLUSIVE=""
        EXAKIT_CHECKBOX_GROUP=""
        _UI_CHECKBOX_SELECTABLE=""
        _cb_i=1
        for _cb_label in "$@"; do
            case ",$_cb_defaults," in *",$_cb_i,"*) ok "$_cb_label (selected by default)" ;; esac
            _cb_i=$((_cb_i + 1))
        done
        return 0
    fi
    # Checked mark: the palette tick in fancy mode; plain "x" otherwise (the
    # plain-palette tick is the multi-char "[ok]", which would double-bracket).
    if [ "${UI_FANCY:-0}" = 1 ]; then _cb_mark="${UI_TICK:-x}"; else _cb_mark="x"; fi
    _cb_first=1
    _cb_drawn=0
    while :; do
        if [ "$_cb_first" -ne 1 ] && [ "$UI_FANCY" = 1 ]; then
            # Up by the lines the LAST frame really occupied, not by the row
            # count: a label wider than the terminal wraps onto a second line,
            # and moving up one-per-row would leave every frame's overflow
            # behind (the stale rows stack with each keypress).
            printf '\033[%dA\033[0J' "$_cb_drawn"
        fi
        _cb_first=0
        _cb_cols="$(_ui_term_cols)"
        _cb_drawn=0
        _cb_i=1
        for _cb_label in "$@"; do
            if _cb_is_header "$_cb_i"; then
                _cb_text="$(_ui_fit_row "${_cb_label#\#}" 4 "$_cb_cols")"
                printf '    %s%s%s\n' "${UI_ACCENT:-}" "$_cb_text" "${UI_RESET:-}"
                _cb_drawn=$((_cb_drawn + $(_ui_wrapped_lines $((4 + ${#_cb_text})) "$_cb_cols")))
                _cb_i=$((_cb_i + 1))
                continue
            fi
            if _cb_is_disabled "$_cb_i"; then
                _cb_text="$(_ui_fit_row "${_cb_label#\!}" 10 "$_cb_cols")"
                printf '      %s[ ] %s%s\n' "${UI_DIM:-}" "$_cb_text" "${UI_RESET:-}"
                _cb_drawn=$((_cb_drawn + $(_ui_wrapped_lines $((10 + ${#_cb_text})) "$_cb_cols")))
                _cb_i=$((_cb_i + 1))
                continue
            fi
            if [ "$_cb_i" -eq "$_cb_cur" ]; then
                if [ "${UI_FANCY:-0}" = 1 ]; then _cb_ptr="${UI_ACCENT:-}❯${UI_RESET:-}"; else _cb_ptr=">"; fi
            else
                _cb_ptr=" "
            fi
            # Chrome: four leading spaces, the pointer, a space, and the
            # checkbox. The CHECKED box is "[<mark>] " whose mark is a palette
            # glyph of ANY width ("✓" is one column, the plain "[ok]" is four),
            # so the chrome is computed from the mark, not assumed — a row is
            # truncated against the wider of its two states, or toggling it
            # would change how many lines it occupies.
            _cb_chrome=$((9 + ${#_cb_mark}))
            [ "$_cb_chrome" -lt 10 ] && _cb_chrome=10
            _cb_text="$(_ui_fit_row "$_cb_label" "$_cb_chrome" "$_cb_cols")"
            case ",$_cb_sel," in
                *",$_cb_i,"*)
                    printf '    %s %s[%s]%s %s\n' \
                        "$_cb_ptr" "${UI_OK:-}" "$_cb_mark" "${UI_RESET:-}" "$_cb_text"
                    ;;
                *)
                    printf '    %s [ ] %s\n' "$_cb_ptr" "$_cb_text"
                    ;;
            esac
            _cb_drawn=$((_cb_drawn + $(_ui_wrapped_lines $((_cb_chrome + ${#_cb_text})) "$_cb_cols")))
            _cb_i=$((_cb_i + 1))
        done
        _cb_hint="$(_ui_fit_row "↑/↓ to move · $_cb_space · Enter to confirm" 6 "$_cb_cols")"
        ui_menu_hint "$_cb_hint"
        _cb_drawn=$((_cb_drawn + $(_ui_wrapped_lines $((6 + ${#_cb_hint})) "$_cb_cols")))
        # One raw keypress, no echo. Enter arrives as an empty read; IFS= keeps
        # a Space keypress from being stripped to an empty string.
        if [ "$_cb_tty" = "/dev/tty" ]; then
            IFS= read -rsn1 _cb_key < /dev/tty || { _cb_sel="$_cb_defaults"; break; }
        else
            IFS= read -rsn1 _cb_key || { _cb_sel="$_cb_defaults"; break; }
        fi
        case "$_cb_key" in
            "")                                          # Enter → confirm, next step
                [ -n "$_cb_sel" ] && break
                continue                                 # at least one selection required
                ;;
            " ")                                         # Space → toggle highlighted
                _cb_sel="$(_ui_checkbox_toggle "$_cb_sel" "$_cb_n" "$_cb_cur")"
                _cb_sel="$(_ui_checkbox_apply_group "$_cb_sel" "$_cb_cur" "$EXAKIT_CHECKBOX_GROUP")"
                _cb_sel="$(_ui_checkbox_apply_exclusive "$_cb_sel" "$_cb_cur" "$EXAKIT_CHECKBOX_EXCLUSIVE")"
                ;;
            "$(printf '\033')")                          # arrows: ESC [ A / ESC [ B
                if [ "$_cb_tty" = "/dev/tty" ]; then
                    IFS= read -rsn2 -t 1 _cb_seq < /dev/tty || _cb_seq=""
                else
                    IFS= read -rsn2 -t 1 _cb_seq || _cb_seq=""
                fi
                case "$_cb_seq" in
                    '[A') _cb_step -1 ;;
                    '[B') _cb_step 1 ;;
                esac
                ;;
            k|K) _cb_step -1 ;;
            j|J) _cb_step 1 ;;
            a|A)
                # "all" means all real choices: never headers, never disabled
                # rows, never the exclusive option.
                _cb_sel=""
                _cb_i=1
                while [ "$_cb_i" -le "$_cb_n" ]; do
                    if ! _cb_is_header "$_cb_i" && ! _cb_is_disabled "$_cb_i" && [ "$_cb_i" != "$EXAKIT_CHECKBOX_EXCLUSIVE" ]; then
                        _cb_sel="${_cb_sel:+$_cb_sel,}$_cb_i"
                    fi
                    _cb_i=$((_cb_i + 1))
                done
                ;;
        esac
    done
    EXAKIT_CHECKBOX_SELECTION="$(printf '%s' "$_cb_sel" | tr ',' '\n' | sort -n | paste -sd, -)"
    EXAKIT_CHECKBOX_EXCLUSIVE=""
    EXAKIT_CHECKBOX_GROUP=""
    _UI_CHECKBOX_SELECTABLE=""
    return 0
}

# exakit_copy_clipboard — best-effort: stdin -> the system clipboard, across
# macOS (pbcopy), Wayland (wl-copy), X11 (xclip/xsel), and WSL (clip.exe).
# Returns 1 when no clipboard tool is available.
exakit_copy_clipboard() {
    if command -v pbcopy >/dev/null 2>&1; then pbcopy
    elif command -v wl-copy >/dev/null 2>&1; then wl-copy
    elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard
    elif command -v xsel >/dev/null 2>&1; then xsel --clipboard --input
    elif command -v clip.exe >/dev/null 2>&1; then clip.exe
    else
        return 1
    fi
}

# --- containing third-party output ------------------------------------------
# We can style only our own lines; a tool we invoke (e.g. the Exasol launcher)
# prints whatever it likes. Rather than let that blend into our output, frame it:
# foreign_note prints a dim marker line, and exakit_stream_foreign pipes a
# command's output through a dim, indented gutter so it reads as "not ours" —
# while the full, unmodified text still goes to the log.
foreign_note() { printf '      %s%s %s%s\n' "${UI_DIM:-}" "${UI_HR:--}" "$*" "${UI_RESET:-}"; }
exakit_stream_foreign() {
    while IFS= read -r _sf_line || [ -n "$_sf_line" ]; do
        [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_sf_line" >> "$EXAKIT_LOG_FILE"
        printf '      %s%s %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$_sf_line" "${UI_RESET:-}"
    done
}

# Sensitive temp files (they hold plaintext credentials) are tracked here so
# they are ALWAYS removed — including on die/exit/interrupt, not only on the
# happy path. Callers register the file right after creating it; die() and the
# EXIT handler both sweep, so no failure path can leave credentials on disk.
EXAKIT_SENSITIVE_TMP=""
exakit_track_sensitive_tmp() { EXAKIT_SENSITIVE_TMP="$EXAKIT_SENSITIVE_TMP $1"; }
exakit_sweep_sensitive_tmp() {
    [ -n "${EXAKIT_SENSITIVE_TMP:-}" ] || return 0
    rm -f $EXAKIT_SENSITIVE_TMP 2>/dev/null
    EXAKIT_SENSITIVE_TMP=""
}

# --- failure notes ----------------------------------------------------------
# A step that fails is run inside a subshell (see exakit_soft_step), so it
# cannot hand its reason back in a shell variable — the subshell's exports die
# with it. The reason goes to a file instead, which is the one channel that
# crosses that boundary, and the closing summary reads it back so it can say
# WHY a component is missing instead of only that it is.
exakit_failure_note_file() {
    printf '%s\n' "${EXAKIT_FAILURE_NOTE:-$EXAKIT_HOME/.last-failure}"
}

# exakit_note_failure <reason> — record why the step now running gave up.
# Never fails: a note is a nicety, and losing it must not turn a soft failure
# into a hard one.
# exakit_reason_summary <text> — one informative line out of a multi-line error.
#
# The note file's line 1 is the reason and every reader takes it, so a reason
# that spans lines has to be collapsed. Collapsing it by keeping line 1 records
# "Traceback (most recent call last):" — pure boilerplate — as the whole
# explanation, in the log AND in last_failure, where it then persists across
# every later `exakit status --json`. A header line ends in a colon with the
# message under it, so in that shape the LAST line is the informative one;
# anything else keeps line 1, which is where a shell error puts its message.
# ⇄ twin: Get-ExakitReasonSummary in setup/lib/exakit-common.ps1.
exakit_reason_summary() {
    _rs_text="$*"
    _rs_n="$(printf '%s\n' "$_rs_text" | sed 's/[[:space:]]*$//' | grep -c '[^[:space:]]' || true)"
    [ -n "$_rs_n" ] || _rs_n=0
    if [ "$_rs_n" -le 1 ]; then
        printf '%s' "$_rs_text" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
        return 0
    fi
    _rs_first="$(printf '%s\n' "$_rs_text" | grep '[^[:space:]]' | head -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$_rs_first" in
        *:) _rs_pick="$(printf '%s\n' "$_rs_text" | grep '[^[:space:]]' | tail -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" ;;
        *)  _rs_pick="$_rs_first" ;;
    esac
    printf '%s (see the log for the full text)' "$_rs_pick"
}

exakit_note_failure() {
    # A READ-ONLY state query must never write state. status --json surfaces
    # this note as last_failure - "a step of your install did not finish" -
    # and a probe that dies inside status/version/info/mcp-doctor is not that:
    # recording it left a permanent "install failure" on a machine where
    # nothing was installed wrong, re-written on every poll. The read-only
    # commands raise this flag; everything they call inherits it.
    [ "${EXAKIT_READONLY_QUERY:-0}" = "1" ] && return 0
    _nf_file="$(exakit_failure_note_file)"
    [ -d "$(dirname "$_nf_file")" ] || return 0
    # Line 1 stays the reason, byte for byte: every existing reader takes
    # `head -n 1`. Line 2 is when it happened, because a note with no date
    # cannot be told from a current one -- and an undated note that outlived its
    # cause is exactly how a healthy machine came to look broken.
    # ONE line, and the informative one: see exakit_reason_summary.
    _nf_reason="$(exakit_reason_summary "$*")"
    [ -n "$_nf_reason" ] || _nf_reason="$*"
    { printf '%s\n%s\n' "$_nf_reason" "$(_exakit_ts)" > "$_nf_file"; } 2>/dev/null || true
    return 0
}

# exakit_take_failure_note — print the pending reason and clear it, so the next
# step cannot inherit the previous one's explanation.
exakit_take_failure_note() {
    _tf_file="$(exakit_failure_note_file)"
    [ -f "$_tf_file" ] || return 0
    head -n 1 "$_tf_file" 2>/dev/null
    rm -f "$_tf_file" 2>/dev/null
    return 0
}

exakit_clear_failure_note() {
    rm -f "$(exakit_failure_note_file)" 2>/dev/null
    return 0
}
# exakit_clear_runtime_failure_note — retire the note only if it is about the
# database not starting. `exakit start` dies with a note when the port is held
# by another process; once the database IS running that note is history, but
# `status --json` kept reporting it as `last_failure` beside "running". Clearing
# every note here would be wrong the other way: a note about an install step
# that never finished ("the AI client configuration did not finish") is still
# true after a start, and start must not hide it. ⇄ twin: Clear-ExakitRuntimeFailureNote.
exakit_clear_runtime_failure_note() {
    _crf_file="$(exakit_failure_note_file)"
    [ -f "$_crf_file" ] || return 0
    case "$(head -n 1 "$_crf_file" 2>/dev/null)" in
        *"exakit start"*|*"cannot start"*|*"held by another process"*|*"not running"*)
            rm -f "$_crf_file" 2>/dev/null ;;
    esac
    return 0
}

# reject <message> — refuse BAD INPUT and stop, without recording a failure note.
#
# The distinction matters to `exakit status --json`, which surfaces the note as
# `last_failure` — a field meant for "a step of your install did not finish". A
# rejected SQL statement is not that: it is the user (or the agent) being told to
# type something else, and recording it left a stale "failure" hanging off an
# otherwise healthy machine until something else overwrote it. Exit 2, the same
# code an unknown subcommand uses, because both mean "your input was wrong".
# _exakit_json_string <text> — the text as a JSON string BODY (no quotes), with
# the two characters that can break out of one escaped, and control characters
# folded to spaces. Enough for a refusal message, which is prose the kit wrote.
_exakit_json_string() {
    printf '%s' "$*" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '
}

reject() {
    # A REFUSAL OWES THE SAME CONTRACT AS AN ANSWER. AGENTS.md promises that
    # where a command takes --json "the answer is one object on stdout and
    # nothing else there" - but every refusal path printed prose to stderr and
    # left stdout empty, so an agent that had committed to a parser got zero
    # bytes and an exit code, with the reason on a stream it was not reading.
    # The kit already had the right pattern in exactly one place: the loader's
    # no-library branch scans for --json and answers with an object before
    # exiting 4.
    if [ "${EXAKIT_REFUSAL_JSON:-0}" = "1" ]; then
        printf '{"ok": false, "error": "%s", "remedy": null, "rejected": true}\n' \
            "$(_exakit_json_string "$*")"
        _exakit_log_file "REJECT $*"
        exit 2
    fi
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" "$*" "${UI_RESET:-}" >&2
    _exakit_log_file "REJECT $*"
    exit 2
}

# Fatal error, rendered as a small "card": a prominent ✗ header, then a dim
# gutter line pointing at the log — consistent shape for every failure.
die() {
    exakit_sweep_sensitive_tmp
    # A table is animating and this is the inside of one of its subshells:
    # printing here would land in a frame that is still being repainted, and the
    # animator's next cursor-up would clear the message away with it. Leave the
    # reason in a file and let the shell that owns the table say it once the
    # table has stopped -- the same reason row state lives in a file.
    if [ -n "${EXAKIT_DEFER_ERRORS:-}" ]; then
        exakit_note_failure "$*"
        printf 'fatal|%s\n' "$*" >> "$EXAKIT_DEFER_ERRORS" 2>/dev/null
        _exakit_log_file "FATAL $*"
        exit 1
    fi
    # Nothing is deferring: stop any animation first, or the message below is
    # wiped off the screen by the next frame before anyone can read it.
    command -v ui_animation_stop >/dev/null 2>&1 && ui_animation_stop
    exakit_note_failure "$*"
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" "$*" "${UI_RESET:-}" >&2
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf '    %s%s Log: %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$EXAKIT_LOG_FILE" "${UI_RESET:-}" >&2
    fi
    _exakit_log_file "FATAL $*"
    exit 1
}

# Run a command, sending its output to the log file only. While it runs (and
# only on an interactive terminal), show a spinner labelled with the current
# step — this is the single hook that animates every silent, long-running
# operation. run_logged never reads stdin, so the spinner is always safe;
# interactive prompts use a separate /dev/tty path and are untouched.
# exakit_explain_db_error <text> — the error-translation layer for the three
# database faults every agent and every new user hits first. The engine's own
# messages are precise but remedy-free ("Connection refused", "syntax error,
# unexpected FETCH_", "object X not found"); each match here appends the one
# line that names the fix. Callers pass whatever output they captured; unknown
# errors print nothing extra, so this can never make a message worse.
# exakit_db_error_remedy <engine text> [statement] — the remedy lines for a raw
# database error, one per line on stdout, nothing when none applies. Data, not
# presentation: `exakit sql` prints these FIRST and on the same stream as the
# error, because on stderr after the output an agent capturing stdout never
# saw them, and one capturing both read exapump's generic "Hint:" first.
# The statement is optional and exists for the one fault the engine text does
# not name: `SELECT TOP n` fails as "unexpected UNSIGNED_INTEGER_" (TOP parses
# as an alias, the number after it is the surprise), so the text alone cannot
# tell it from any other syntax error - the statement can.
# ⇄ twin: Get-ExakitDbErrorRemedy.
exakit_db_error_remedy() {
    _dber_stmt="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]' | tr '\n\t' '  ')"
    case "$1" in
        *"onnection refused"*|*"Errno 61"*|*"Errno 111"*|*"could not connect"*|*"Could not connect"*|*"Failed to connect to"*|*"failed to connect to"*|*"actively refused"*|*"os error 10061"*)
            # The last four are how exapump and Windows spell a refused socket
            # ("Failed to connect to 127.0.0.1:8563", "No connection could be
            # made because the target machine actively refused it (os error
            # 10061)"); without them the first remedy every agent needs was null.
            printf '%s\n' "That is the database not answering — it is stopped or unreachable. Start it with: exakit start (then check: exakit status)"
            ;;
        *"tls handshake"*|*"TLS handshake"*|*"TLS error"*)
            # The port answered but not with Exasol's TLS: something else is
            # listening there. `exakit status` reports that as a conflict and
            # names the process; `exakit start` alone cannot help until it is gone.
            printf '%s\n' "Something answered on the database port, but it is not Exasol (the TLS handshake failed). Check with: exakit status — a conflict names the process holding the port; stop it, then: exakit start"
            ;;
    esac
    _dber_limit=0
    case "$1" in
        *"unexpected FETCH_"*|*"unexpected TOP_"*|*"FETCH FIRST"*) _dber_limit=1 ;;
    esac
    case "$1" in
        *"syntax error"*)
            case " $_dber_stmt" in
                *" TOP "*|*"(TOP "*) _dber_limit=1 ;;
            esac
            ;;
    esac
    if [ "$_dber_limit" -eq 1 ]; then
        printf '%s\n' "Exasol pages result sets with LIMIT <n> (optionally OFFSET) — not FETCH FIRST or TOP. Rewrite the query with LIMIT."
    fi
    case "$1" in
        *"not found"*)
            case "$1" in
                *object*|*table*|*column*|*schema*|*view*)
                    printf '%s\n' "A named object does not exist as written. Check the spelling and the schema qualifier — describe it first (MCP: describe_exasol_table_or_view; SQL: DESCRIBE <schema>.<table>)."
                    # A table loaded from a file keeps the file's column names
                    # AS WRITTEN, quoted - "visits", not VISITS - while an
                    # unquoted name in SQL is upper-cased. "Check the spelling"
                    # sent the reader to re-read a name that was already right.
                    case "$_dber_stmt" in
                        *STARTER_KIT*)
                            printf '%s\n' "If the table was loaded from a file, its columns keep the file's exact spelling and case and must be quoted: SELECT \"visits\" ..., not VISITS. DESCRIBE the table to see them."
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
    # A write refused for lack of privilege is the read-only guardrail doing its
    # job, and the tempting next move — re-run it through `exapump -p
    # starter-kit`, which connects as admin — is the one thing that breaks the
    # trust model. Say so where the error appears, not only in the docs.
    case "$1" in
        *"insufficient privileges"*|*"42500"*)
            # Written for BOTH readers of this stream — the person at the
            # terminal and an agent driving the CLI. "Say so and let the user
            # decide" addressed only the agent, so the human it was printed to
            # was handed a message about themselves in the third person with
            # no action in it.
            printf '%s\n' "That write was refused by the DATABASE: the connection that ran it is read-only by design — the guardrail working as intended."
            printf '%s\n' "To run a write deliberately, use the admin path: exakit sql --write '<statement>'. Never route it through 'exapump -p starter-kit' by reflex — that profile is the ADMIN user and is not sandboxed."
            ;;
    esac
    return 0
}

# exakit_db_error_remedy_cmd <engine text> — the RUNNABLE half of the remedy:
# one command verbatim, or nothing. `sql --json` promises the same contract as
# every other machine answer ("when remedy is not null, run it" — AGENTS.md),
# so the sentence exakit_db_error_remedy composes for humans goes to
# remedy_hint there, and THIS is what sits at the remedy key. Faults whose fix
# is a rewrite, a grant, or a look at the schema have no verbatim command —
# they answer null here, with the hint carrying the guidance.
# ⇄ twin: Get-ExakitDbErrorRemedyCommand.
exakit_db_error_remedy_cmd() {
    case "$1" in
        *"onnection refused"*|*"Errno 61"*|*"Errno 111"*|*"could not connect"*|*"Could not connect"*|*"Failed to connect to"*|*"failed to connect to"*|*"actively refused"*|*"os error 10061"*)
            printf 'exakit start\n'
            return 0
            ;;
    esac
    case "$1" in
        *"tls handshake"*|*"TLS handshake"*|*"TLS error"*)
            printf 'exakit status\n'
            return 0
            ;;
    esac
    return 0
}

# exakit_explain_db_error <engine text> — the same remedies as warnings, for the
# lifecycle paths that print their own output first.
exakit_explain_db_error() {
    exakit_db_error_remedy "$1" | while IFS= read -r _ede_line; do
        [ -n "$_ede_line" ] && warn "$_ede_line"
    done
    return 0
}

# exakit_explain_uv_python_error <text> — the managed-Python fault that makes a
# component install fail for a reason no component can fix. uv caches its own
# CPython builds; a truncated or partially-written cache entry answers every
# `uv venv --python <ver>` with an unparseable response, so the component's own
# remedy ("retry this command") loops forever while the actual repair — one uv
# command — is never named. The cause is always in the log; this puts the fix
# next to it.
exakit_explain_last_log_error() {
    # run_logged sends command output to the logfile, not to a variable, so the
    # only place a failed step's real cause exists is the tail of that file.
    [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -r "${EXAKIT_LOG_FILE:-}" ] || return 0
    _elle_tail="$(tail -n 25 "$EXAKIT_LOG_FILE" 2>/dev/null || true)"
    [ -n "$_elle_tail" ] || return 0
    exakit_explain_uv_python_error "$_elle_tail"
    return 0
}

exakit_explain_uv_python_error() {
    case "$1" in
        *"returned an invalid response"*|*"EOF while parsing"*|*"Querying Python at"*)
            warn "That is uv's managed Python installation being corrupt, not a fault in this component — retrying the same command will fail identically."
            warn "Repair it first:  uv python install ${EXAKIT_MANAGED_PYTHON_VERSION:-3.12} --reinstall"
            ;;
    esac
    return 0
}

run_logged() {
    _exakit_log_file "CMD   $*"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-working}"
        "$@" >> "$EXAKIT_LOG_FILE" 2>&1
        _run_logged_rc=$?
        ui_spin_end
        return $_run_logged_rc
    else
        "$@"
    fi
}

# Ask a yes/no question. Reads from /dev/tty so it works when the script
# itself is piped (curl | bash). Non-interactive runs take the default.
# usage: confirm "Question?" [y|n]
confirm() {
    _question="$1"
    _default="${2:-y}"
    # A usable tty is one we can actually open, not one that merely exists.
    _tty="$(_exakit_prompt_tty)"
    if [ -z "$_tty" ]; then
        [ "$_default" = "y" ]
        return
    fi
    if [ "$_default" = "y" ]; then _hint="[Y/n]"; else _hint="[y/N]"; fi
    printf '    %s?%s %s %s%s%s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" "${UI_DIM:-}" "$_hint" "${UI_RESET:-}"
    if [ "$_tty" = "/dev/tty" ]; then read -r _answer < /dev/tty; else read -r _answer; fi
    _answer="${_answer:-$_default}"
    case "$_answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Like confirm(), but an environment variable can pre-answer the question so an
# agent-driven or scripted install (no tty) honours the user's choice instead of
# silently taking the default. usage: confirm_env VAR "Question?" [y|n]
#   VAR = 1|y|yes  -> yes, skip the prompt
#   VAR = 0|n|no   -> no,  skip the prompt
#   VAR unset/other-> fall back to confirm() (tty prompt, else the default)
confirm_env() {
    _ce_var="$1"
    _ce_question="$2"
    _ce_default="${3:-y}"
    _ce_val="${!_ce_var:-}"
    case "$_ce_val" in
        1|y|Y|yes|YES|Yes) return 0 ;;
        0|n|N|no|NO|No)    return 1 ;;
        *) confirm "$_ce_question" "$_ce_default" ;;
    esac
}

_exakit_prompt_tty() {
    if [ -t 0 ]; then
        printf 'stdin\n'
    elif (: < /dev/tty) 2>/dev/null; then
        printf '/dev/tty\n'
    fi
}

prompt_text() {
    _question="$1"
    _default="${2:-}"
    _tty="$(_exakit_prompt_tty)"
    if [ -z "$_tty" ]; then
        printf '%s\n' "$_default"
        return 0
    fi
    if [ -n "$_default" ]; then
        printf '    %s?%s %s %s[%s]%s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" "${UI_DIM:-}" "$_default" "${UI_RESET:-}" >&2
    else
        printf '    %s?%s %s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" >&2
    fi
    if [ "$_tty" = "/dev/tty" ]; then read -r _answer < /dev/tty; else read -r _answer; fi
    printf '%s\n' "${_answer:-$_default}"
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
require_python3() {
    _exakit_has_system_python3 && return 0
    exakit_ensure_uv || die "A Python runtime is required, and the automatic uv bootstrap failed."
}

# Minimum Python for the kit's own tooling. 3.11 is the floor because the MCP
# client-config code parses TOML via the stdlib's tomllib (added in 3.11); an
# older system interpreter (macOS ships 3.9) made MCP client setup fail during
# install. The PowerShell twin (Test-ExakitSystemPythonForMcp) applies the
# same gate.
EXAKIT_MIN_PYTHON="3.11"
_EXAKIT_SYSTEM_PY_OK=""

# _exakit_python3_is_xcode_stub — is the python3 on PATH the macOS placeholder
# rather than an interpreter?
#
# On a Mac without the Xcode Command Line Tools, /usr/bin/python3 is a small
# xcrun shim: it satisfies `command -v`, and running it fails (and pops the
# "install developer tools" dialog). It is decided WITHOUT running it: the shim
# only works when a developer directory exists, and `xcode-select -p` answers
# that without a dialog. Anything that is not /usr/bin/python3 on a Mac is
# never the stub, and costs no process at all.
_exakit_python3_is_xcode_stub() {
    case "$(command -v python3 2>/dev/null)" in
        /usr/bin/python3) : ;;
        *) return 1 ;;
    esac
    [ -x /usr/bin/xcode-select ] || return 1
    ! /usr/bin/xcode-select -p >/dev/null 2>&1
}

# _exakit_python3_present — a python3 on PATH that can actually run (no
# version floor). The gate for run_python_any: `command -v python3` alone
# accepted the macOS stub, so on a Mac without the Command Line Tools every
# manifest read failed after a successful install and `exakit status --json`
# printed nothing.
_exakit_python3_present() {
    [ "${EXAKIT_DISABLE_SYSTEM_PYTHON:-0}" != "1" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    ! _exakit_python3_is_xcode_stub
}

# A system python3 is usable only when it exists AND meets the version floor;
# anything less is treated exactly like an absent interpreter, so the
# uv-managed runtime takes over automatically. The probe spawns an interpreter,
# so its verdict is cached — run_python funnels through here on every call.
_exakit_has_system_python3() {
    [ "${EXAKIT_DISABLE_SYSTEM_PYTHON:-0}" != "1" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    # The stub is known without running it (running it pops a dialog).
    if [ -z "$_EXAKIT_SYSTEM_PY_OK" ] && _exakit_python3_is_xcode_stub; then
        _EXAKIT_SYSTEM_PY_OK="no"
        _exakit_log_file "INFO  /usr/bin/python3 is the Xcode Command Line Tools stub, not a real interpreter — using the uv-managed Python runtime instead"
    fi
    if [ -z "$_EXAKIT_SYSTEM_PY_OK" ]; then
        # Keep the probe's stderr: it is the difference between an interpreter
        # that is too old and one that is not an interpreter at all.
        if _ehsp_err="$(python3 -c "import sys; req = tuple(map(int, '$EXAKIT_MIN_PYTHON'.split('.'))); raise SystemExit(0 if sys.version_info[:2] >= req else 1)" 2>&1)"; then
            _EXAKIT_SYSTEM_PY_OK="yes"
        else
            _EXAKIT_SYSTEM_PY_OK="no"
            # SAY THE REAL REASON. On a Mac without the Xcode Command Line
            # Tools /usr/bin/python3 is a 118 KB xcrun shim: it exists, it
            # satisfies `command -v`, and it fails to run at all. Logging
            # "older than 3.11" about an interpreter that is not there is the
            # only record of the decision, and it sent readers to
            # `brew install python` to fix a version that was never the problem.
            case "$_ehsp_err" in
                *xcrun*|*"invalid active developer path"*|*"command line developer tools"*)
                    _exakit_log_file "INFO  /usr/bin/python3 is the Xcode Command Line Tools stub, not a real interpreter — using the uv-managed Python runtime instead" ;;
                *)
                    _exakit_log_file "INFO  the system python3 is not usable for this kit (needs >= $EXAKIT_MIN_PYTHON) — using the uv-managed Python runtime instead" ;;
            esac
        fi
    fi
    [ "$_EXAKIT_SYSTEM_PY_OK" = "yes" ]
}

exakit_ensure_uv() {
    if [ -n "${EXAKIT_UV_BIN:-}" ] && [ -x "$EXAKIT_UV_BIN" ]; then
        return 0
    fi
    if command -v uv >/dev/null 2>&1; then
        EXAKIT_UV_BIN="$(command -v uv)"
        return 0
    fi
    if [ -x "$EXAKIT_BIN_DIR/uv" ]; then
        EXAKIT_UV_BIN="$EXAKIT_BIN_DIR/uv"
        return 0
    fi
    # A READ-ONLY STATE QUERY INSTALLS NOTHING. `exakit status --json` is
    # documented as a state query, and on a stock macOS (system python3 is
    # 3.9.6, below the tomllib floor) the very first one used to arrive here
    # and download a 36 MB binary into the user's ~/.local/bin, over the
    # network, with no prompt and no mention in AGENTS.md. Report "no
    # interpreter" instead and let the caller degrade honestly; every command
    # that may CHANGE the machine (install, update, mcp-setup) still
    # bootstraps.
    if [ "${EXAKIT_READONLY_QUERY:-0}" = "1" ]; then
        _exakit_log_file "INFO  uv bootstrap skipped: this is a read-only state query"
        return 1
    fi
    # Narration to STDERR, always: this bootstrap runs lazily from inside
    # run_python, including in the MIDDLE of composing a --json answer — on a
    # stock macOS with no Python 3.11+, the very first `exakit status --json`
    # lands here, and these lines used to interleave with the JSON object on
    # stdout, corrupting the one answer the contract promises is parseable.
    info "Installing the managed Python bootstrapper (uv)" >&2
    mkdir -p "$EXAKIT_BIN_DIR"
    # Same protocol guards as the mcp.sh bootstrap, for the same reason: this
    # script is EXECUTED, -L follows redirects, and a 302 to http:// would
    # otherwise be fetched in the clear and piped into sh. wget spells it
    # --https-only.
    if command -v curl >/dev/null 2>&1; then
        env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh -c \
            'curl -LsSf --proto "=https" --proto-redir "=https" https://astral.sh/uv/install.sh | sh' >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 1
    elif command -v wget >/dev/null 2>&1; then
        env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh -c \
            'wget -qO- --https-only https://astral.sh/uv/install.sh | sh' >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 1
    else
        warn "Neither curl nor wget is available to install uv." >&2
        return 1
    fi
    if [ -x "$EXAKIT_BIN_DIR/uv" ]; then
        EXAKIT_UV_BIN="$EXAKIT_BIN_DIR/uv"
        ok "uv installed at $EXAKIT_UV_BIN" >&2
        return 0
    fi
    warn "uv installation finished but the binary was not found in $EXAKIT_BIN_DIR." >&2
    return 1
}

run_python() {
    if _exakit_has_system_python3; then
        python3 "$@"
        return $?
    fi
    exakit_ensure_uv || return 1
    "$EXAKIT_UV_BIN" run --python "$EXAKIT_MANAGED_PYTHON_VERSION" --no-project python "$@"
}

# Optional Python for best-effort flows (latest-version checks, digest lookup).
# Unlike require_python3, this never exits: callers can fall back to shell
# parsing or report "unknown" instead of failing a status/version command.
exakit_can_run_python() {
    _exakit_has_system_python3 && return 0
    exakit_ensure_uv >/dev/null 2>&1
}

# run_python_any — run a script on ANY Python 3 that is already on the machine.
#
# run_python holds the kit to EXAKIT_MIN_PYTHON (3.11) because exactly ONE
# thing needs it: the MCP client-config writer parses TOML with the stdlib's
# tomllib. Reading the manifest and composing a --json answer need `json` and
# nothing else — but they went through the same gate, so on a stock macOS
# (python3 3.9.6) every state query fell through to the uv bootstrap: a
# documented read-only command downloading 36 MB, and — until that narration
# moved to stderr — splicing its progress lines into the very value it was
# computing, which is how `runtime.type` came back as a multi-line blob.
# Anything that needs only the standard library runs here instead.
# Twin of the guard above: a stub that satisfies `command -v` must not be run.
run_python_any() {
    if _exakit_python3_present; then
        python3 "$@"
        return $?
    fi
    run_python "$@"
}

# Is there any Python 3 at all? Never installs one from a read-only query
# (exakit_ensure_uv enforces that); callers degrade instead of failing.
# A STUB SATISFIES `command -v`. On a Mac without the Xcode Command Line Tools -
# or with them present but the licence unaccepted - /usr/bin/python3 is a 118 KB
# shim that exists, is executable, and fails on every invocation. Guarding on
# `command -v python3` therefore answered "yes, Python is available" and then
# produced nothing: `exakit status --json` emitted ZERO BYTES with exit 3, which
# AGENTS.md documents as "not running, or still installing", so an agent polling
# that loop never terminated. _exakit_python3_present (above) answers
# this correctly instead: it rejects the stub WITHOUT imposing
# EXAKIT_MIN_PYTHON, which is the whole point of the "_any" pair - work that
# needs only the standard library must not be pushed onto the uv-managed
# runtime merely because the system interpreter is 3.9.
exakit_can_run_python_any() {
    if _exakit_python3_present; then
        return 0
    fi
    exakit_can_run_python
}

manifest_init() {
    mkdir -p "$EXAKIT_HOME"
    # The home the skills tell an agent to write into, created with the home
    # itself rather than left for the agent to invent. Cheap, idempotent, and it
    # runs on every install AND every re-run, so an older install grows the
    # directory the moment the installer touches it again.
    mkdir -p "$EXAKIT_WORKFLOWS_DIR" 2>/dev/null || true
    _mi_steps=""
    if [ -f "$EXAKIT_MANIFEST" ]; then
        # Self-heal after an interrupted run: a manifest that no longer
        # parses is quarantined and rebuilt. Each install step re-verifies
        # what actually exists on disk, so nothing is reinstalled blindly.
        #
        # "CANNOT CHECK" IS NOT "CORRUPT". The probe below runs through
        # run_python, which on a machine with no system Python >= 3.11 tries to
        # bootstrap uv over the network first — so an offline machine failed
        # this test for want of an INTERPRETER and a perfectly good manifest was
        # renamed .corrupt-<ts> under a message blaming the file. Ask first
        # whether a Python can be had at all, and when it cannot, leave the
        # manifest exactly where it is.
        if ! exakit_can_run_python; then
            _exakit_log_file "INFO  Skipped the manifest parse check: no Python runtime is available, so the existing manifest is kept as-is"
            return 0
        fi
        if run_python -c 'import json,sys; json.load(open(sys.argv[1]))' "$EXAKIT_MANIFEST" 2>/dev/null; then
            return 0
        fi
        # Name what actually failed, and where the evidence went: "the install
        # manifest is corrupted" told a reader neither which file nor that a
        # copy of it still exists to look at.
        _mi_quarantine="$EXAKIT_MANIFEST.corrupt-$(date +%s)"
        warn "The install manifest at $EXAKIT_MANIFEST does not parse as JSON (interrupted run?) — kept as $_mi_quarantine and rebuilt; existing components will be re-detected"
        mv "$EXAKIT_MANIFEST" "$_mi_quarantine"
        # Salvage the step ticks where the damage did not reach them. Nothing
        # else is worth recovering: every other key records something whose
        # presence each install step re-verifies on disk anyway, while a lost
        # step tick costs a re-run of work that had already finished.
        _mi_steps="$(run_python - "$_mi_quarantine" 2>/dev/null <<'PY' || true
import json, re, sys
try:
    with open(sys.argv[1]) as handle:
        text = handle.read()
except OSError:
    sys.exit(0)
# A regex, not a parser: the document is already known not to parse, and the
# array is being lifted out of whatever is left of it.
match = re.search(r'"steps_completed"\s*:\s*(\[[^]]*\])', text)
if not match:
    sys.exit(0)
try:
    steps = json.loads(match.group(1))
except ValueError:
    sys.exit(0)
if isinstance(steps, list) and steps and all(isinstance(s, str) for s in steps):
    print(json.dumps(steps))
PY
        )"
        if [ -n "$_mi_steps" ]; then
            info "Recovered the completed-step list from the quarantined manifest — finished steps are still skipped"
        fi
    fi
    cat > "$EXAKIT_MANIFEST" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "os": "",
  "arch": "",
  "runtime": {},
  "components": {},
  "data": {
    "loaded": false
  },
  "steps_completed": ${_mi_steps:-[]},
  "log_dir": "$EXAKIT_LOG_DIR"
}
EOF
    chmod 600 "$EXAKIT_MANIFEST"
    _exakit_log_file "INFO  Initialized manifest at $EXAKIT_MANIFEST"
}

# _exakit_manifest_write_error <exit-code> <what> — the sentence a failed
# manifest WRITE is reported with.
#
# The three writers below (manifest_set, manifest_del, mark_step) used to let
# the interpreter report a failure itself: an install interrupted before the
# manifest was created printed a Python traceback at the top of the terminal
# ("FileNotFoundError: [Errno 2] ... manifest.json") and then a kit message
# underneath it that explained nothing — two lines about one fault, neither
# actionable. Every sibling READER (manifest_get, manifest_get_many) has always
# caught the same two exceptions; the writers had not.
#
# They now exit with a small code instead, and the traceback goes to the log
# where a maintainer can still read it. Only two of the cases are things a
# reader can act on, so only those two carry a remedy:
#
#   3  no manifest at all          -> re-run the installer to rebuild it
#   4  present but does not parse  -> re-run the installer to rebuild it
#   5  present but not writable    -> fix its permissions
_exakit_manifest_write_error() {
    case "$1" in
        3) printf 'No install manifest at %s, so %s could not be recorded — re-run the installer to rebuild it\n' "$EXAKIT_MANIFEST" "$2" ;;
        4) printf 'The install manifest at %s could not be read, so %s could not be recorded — re-run the installer to rebuild it\n' "$EXAKIT_MANIFEST" "$2" ;;
        5) printf 'The install manifest at %s is not writable, so %s could not be recorded — fix its permissions and retry\n' "$EXAKIT_MANIFEST" "$2" ;;
        *) printf 'Failed to update the install manifest (%s) — the interpreter error is in the log%s\n' "$2" "${EXAKIT_LOG_FILE:+: $EXAKIT_LOG_FILE}" ;;
    esac
}

# _exakit_manifest_log_stderr <text> — keep an interpreter error, off screen.
# Appended a line at a time so the log stays one-record-per-line, and silent
# when there is nothing to say.
_exakit_manifest_log_stderr() {
    [ -n "$1" ] || return 0
    printf '%s\n' "$1" | while IFS= read -r _mls_line; do
        [ -n "$_mls_line" ] && _exakit_log_file "PYERR $_mls_line"
    done
    return 0
}

# manifest_set <dot.path> <value>
# Value is stored as JSON if it parses as JSON, otherwise as a string.
manifest_set() {
    require_python3
    # stdout is discarded and stderr is captured rather than redirected with
    # `2>>`: the log directory can already be gone (uninstall removes the kit
    # home while later steps still write), and a redirection onto a missing
    # path fails the command itself — which would turn a manifest write that
    # worked into one that reports failure.
    _ms_err="$(run_python - "$EXAKIT_MANIFEST" "$1" "$2" 2>&1 >/dev/null <<'PY'
import fcntl, json, os, sys, tempfile

def _exakit_locked(path):
    """Serialise the read-modify-write. Without this, concurrent writers each
    read the same document, apply their own key, and the last one to finish
    wins -- silently discarding every other update. Measured before this lock:
    17 of 20 concurrent writes lost, and every one of 30 rounds lost at least
    one. Two kit processes at once is not hypothetical: `exakit start` brings up
    the database and every service, autostart can fire one at boot while
    another runs, and an agent may issue two commands in parallel."""
    lock_path = path + ".lock"
    handle = open(lock_path, "a+")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle

def _exakit_write(path, doc):
    """Unique temp name, not a fixed one: two writers sharing path + '.tmp'
    can interleave inside it, and the loser's os.replace can then publish a
    half-written document."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
# Small exit codes instead of an interpreter traceback; the shell wrapper turns
# each one into a sentence (see _exakit_manifest_write_error). The existence
# check comes first so a missing manifest is named as such AND no stray .lock
# file is created beside a manifest that is not there.
if not os.path.exists(path):
    sys.exit(3)
try:
    _lock = _exakit_locked(path)
except OSError:
    sys.exit(5)
try:
    with open(path) as f:
        doc = json.load(f)
except FileNotFoundError:
    sys.exit(3)
except (OSError, ValueError):
    sys.exit(4)
node = doc
parts = key.split(".")
for part in parts[:-1]:
    node = node.setdefault(part, {})
try:
    node[parts[-1]] = json.loads(value)
except json.JSONDecodeError:
    node[parts[-1]] = value
try:
    _exakit_write(path, doc)
except OSError:
    sys.exit(5)
PY
    )"
    _ms_rc=$?
    _exakit_manifest_log_stderr "$_ms_err"
    [ "$_ms_rc" -eq 0 ] || die "$(_exakit_manifest_write_error "$_ms_rc" "$1")"
}

# manifest_set_many — apply several boolean flags in ONE locked read-modify-write,
# reading "<dot.path>=true|false" lines on stdin. Writes only when at least one
# key actually changes, so a caller can offer it every observation without
# rewriting the file each time.
#
# Exists for `exakit status`, which now verifies the loaded datasets against the
# database and heals the flags it finds wrong. Doing that one manifest_set at a
# time meant six python processes on a command agents poll constantly; the whole
# heal is one process now. Never fatal: healing bookkeeping must not fail a
# status read.
manifest_set_many() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    exakit_can_run_python || return 0
    # THE LINES ARE READ HERE, NOT BY PYTHON. `run_python -` takes the program
    # itself from stdin - the heredoc below - so the script's own
    # sys.stdin.read() always came back empty: every caller's piped keys were
    # silently dropped and this function had never written anything. The
    # dataset-flag healing in exakit_verified_datasets went through it, and a
    # rebuilt database therefore kept reading as "loaded". Found when a
    # repair-runtime reloaded nothing on a real machine.
    _msm_lines="$(cat)"
    [ -n "$_msm_lines" ] || return 0
    run_python - "$EXAKIT_MANIFEST" "$_msm_lines" <<'PY' 2>/dev/null || true
import fcntl, json, os, sys, tempfile

path = sys.argv[1]
wanted = []
for line in sys.argv[2].splitlines():
    if "=" not in line:
        continue
    key, _, value = line.partition("=")
    key = key.strip()
    if key:
        wanted.append((key, value.strip() == "true"))
if not wanted:
    sys.exit(0)

lock = open(path + ".lock", "a+")
fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
try:
    with open(path) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(0)

changed = False
for key, value in wanted:
    node = doc
    parts = key.split(".")
    for part in parts[:-1]:
        nxt = node.get(part)
        if not isinstance(nxt, dict):
            nxt = {}
            node[part] = nxt
        node = nxt
    if node.get(parts[-1]) != value:
        node[parts[-1]] = value
        changed = True
if not changed:
    sys.exit(0)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                          prefix=os.path.basename(path) + ".")
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(doc, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    return 0
}

# manifest_get <dot.path> — prints the value; exits non-zero if missing.
#
# Reads through run_python_any: parsing this file needs `json`, not 3.11, and
# routing it through the 3.11 gate is what made `exakit status` install uv on
# a stock Mac. With no interpreter at all a read-only query answers "missing"
# rather than dying; everything else still gets the explicit failure.
manifest_get() {
    if ! exakit_can_run_python_any; then
        [ "${EXAKIT_READONLY_QUERY:-0}" = "1" ] && return 1
        die "A Python runtime is required, and the automatic uv bootstrap failed."
    fi
    run_python_any - "$EXAKIT_MANIFEST" "$1" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        doc = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(1)
node = doc
for part in key.split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(1)
print(node if isinstance(node, str) else json.dumps(node))
PY
}

# manifest_get_many <dot.path>... - read SEVERAL keys in ONE python process.
#
# manifest_get starts a fresh interpreter per key. That is fine for one lookup
# and expensive for a panel: six keys out of the same file measured at ~53ms
# each, ~890ms in total, which is the pause a user feels after pressing enter
# on `exakit info`. One interpreter start for the whole set is ~60ms.
#
# Prints one line per key, IN THE ORDER ASKED, so callers can read them
# positionally. A missing key prints an EMPTY LINE rather than failing - a
# caller wanting six values must still get six lines, and every existing
# caller of manifest_get already treats "absent" as "unknown". That is the one
# behavioural difference from manifest_get, which exits non-zero instead.
#
# Values are assumed not to contain newlines. Every manifest value read this
# way is a DSN, a username or a path; if that ever stops being true, this is
# the line-oriented assumption that breaks.
manifest_get_many() {
    if ! exakit_can_run_python_any; then
        [ "${EXAKIT_READONLY_QUERY:-0}" = "1" ] && return 1
        die "A Python runtime is required, and the automatic uv bootstrap failed."
    fi
    run_python_any - "$EXAKIT_MANIFEST" "$@" <<'PY'
import json, sys
path, keys = sys.argv[1], sys.argv[2:]
try:
    with open(path) as f:
        doc = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    doc = {}
MISSING = object()
for key in keys:
    node = doc
    for part in key.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            node = MISSING
            break
    if node is MISSING:
        print("")
    else:
        print(node if isinstance(node, str) else json.dumps(node))
PY
}

# manifest_del <dot.path> — remove a key (and everything under it) from the
# manifest. Silent when the key is already absent; a partial uninstall must
# not fail over bookkeeping.
manifest_del() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    require_python3
    # Same treatment as manifest_set: the interpreter reports to the log, the
    # reader gets one sentence. Still a warn rather than a die — a partial
    # uninstall must not fail over bookkeeping.
    _md_err="$(run_python - "$EXAKIT_MANIFEST" "$1" 2>&1 >/dev/null <<'PY'
import fcntl, json, os, sys, tempfile

# Same lock + atomic-write pair as manifest_set (see there for the measurements):
# an unlocked read-modify-write silently discards concurrent updates, and a
# shared "<path>.tmp" lets two writers interleave inside it.
def _exakit_locked(path):
    handle = open(path + ".lock", "a+")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle

def _exakit_write(path, doc):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

path, key = sys.argv[1], sys.argv[2]
# Exit codes, not a traceback (see _exakit_manifest_write_error): 3 no manifest,
# 4 unreadable, 5 not writable.
if not os.path.exists(path):
    sys.exit(3)
try:
    _lock = _exakit_locked(path)
except OSError:
    sys.exit(5)
try:
    with open(path) as f:
        doc = json.load(f)
except FileNotFoundError:
    sys.exit(3)
except (OSError, ValueError):
    sys.exit(4)
node = doc
parts = key.split(".")
for part in parts[:-1]:
    if not (isinstance(node, dict) and part in node):
        sys.exit(0)
    node = node[part]
if isinstance(node, dict):
    node.pop(parts[-1], None)
try:
    _exakit_write(path, doc)
except OSError:
    sys.exit(5)
PY
    )"
    _md_rc=$?
    _exakit_manifest_log_stderr "$_md_err"
    [ "$_md_rc" -eq 0 ] || warn "$(_exakit_manifest_write_error "$_md_rc" "$1")"
    return 0
}

# exakit_unmark_step <step> — drop a step flag so a re-run of the installer
# reinstalls what a partial uninstall removed.
exakit_unmark_step() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY' || warn "Could not update the manifest (steps_completed)"
import fcntl, json, os, sys, tempfile

# Same lock + atomic-write pair as manifest_set (see there for the measurements):
# an unlocked read-modify-write silently discards concurrent updates, and a
# shared "<path>.tmp" lets two writers interleave inside it.
def _exakit_locked(path):
    handle = open(path + ".lock", "a+")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle

def _exakit_write(path, doc):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

path, step = sys.argv[1], sys.argv[2]
_lock = _exakit_locked(path)
with open(path) as f:
    doc = json.load(f)
steps = doc.get("steps_completed")
if isinstance(steps, list) and step in steps:
    doc["steps_completed"] = [s for s in steps if s != step]
    _exakit_write(path, doc)
PY
}

# ---------------------------------------------------------------------------
# Versions manifest (versions.json)
# ---------------------------------------------------------------------------
# One document answers one question: "which version of each Component is the
# current tested set?". Maintainers edit it via pull request; clients read it.
# Nothing here may ever fail a command — every reader degrades along the chain
#
#   fresh fetch  ->  cached copy (any age)  ->  copy baked into the kit  ->  the
#   *_FALLBACK constants above
#
# so an offline machine, a rate-limited network, or a hand-mangled cache all
# end up with a usable answer instead of an error.
#
# The document's formatting is an interface, not a style choice: canonical
# 2-space pretty-print, one key per line, LF endings, and "version" before any
# nested object inside a block. That is what lets the no-Python fallback below
# read it with awk, and it is enforced by CI on every edit.
#
# ⇄ twin: the Get-ExakitVersions* / Update-ExakitVersionsCache set in
# setup/lib/exakit-common.ps1.
_EXAKIT_VERSIONS_DOC=""
_EXAKIT_VERSIONS_SOURCE=""
_EXAKIT_VERSIONS_SCHEMA_AHEAD=0

# _exakit_json_leaves <file> [dot.path] — scalar reader for the canonical form
# described above: prints "<dot.path><TAB><value>" for every scalar, or just the
# value of one path when asked. Indentation is the nesting depth (two spaces per
# level, one key per line), so no real parser is needed. Used only when there is
# no Python runtime at all — Python stays the primary path everywhere.
_exakit_json_leaves() {
    awk -v want="${2:-}" '
        {
            n = match($0, /[^ ]/)
            if (n == 0) next
            depth = int((n - 1) / 2)
            if (depth < 1) next
            rest = substr($0, n)
            if (!match(rest, /^"[^"]*" *:/)) next
            key = substr(rest, 1, RLENGTH)
            val = substr(rest, RLENGTH + 1)
            sub(/^"/, "", key)
            sub(/" *:$/, "", key)
            keys[depth] = key
            sub(/^ +/, "", val)
            if (val == "" || val == "{" || val == "[") next
            if (substr(val, 1, 1) == "\"") {
                sub(/",$/, "\"", val)
                val = substr(val, 2, length(val) - 2)
            } else {
                sub(/,$/, "", val)
            }
            path = keys[1]
            for (i = 2; i <= depth; i++) path = path "." keys[i]
            if (want != "") {
                if (path == want) { print val; exit }
                next
            }
            print path "\t" val
        }
    ' "$1"
}

# exakit_versions_validate <file> — the gate every document passes before it is
# trusted. Rejects anything that does not parse, announces a schema this kit
# cannot read, or carries a version/digest outside the safe charset (advertised
# versions are interpolated into download URLs and command lines).
exakit_versions_validate() {
    _vv_file="$1"
    [ -f "$_vv_file" ] && [ -s "$_vv_file" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_vv_file" "$EXAKIT_VERSIONS_SCHEMA" <<'PY' 2>/dev/null
import json, re, sys

path, schema = sys.argv[1], int(sys.argv[2])
try:
    with open(path) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
announced = doc.get("schema_version")
if announced != schema:
    # Exit 2 = "readable, but newer than this kit" so the caller can hint at
    # updating instead of reporting a broken document.
    sys.exit(2 if isinstance(announced, int) and announced > schema else 1)

version_re = re.compile(r"^[A-Za-z0-9._+-]+$")
digest_re = re.compile(r"^[0-9a-f]{64}$")


def check_block(block):
    if not isinstance(block, dict):
        sys.exit(1)
    version = block.get("version")
    if not isinstance(version, str) or not version_re.match(version):
        sys.exit(1)
    min_kit = block.get("min_kit_version")
    if min_kit is not None and (not isinstance(min_kit, str) or not version_re.match(min_kit)):
        sys.exit(1)
    digests = block.get("sha256")
    if digests is not None:
        if not isinstance(digests, dict) or not digests:
            sys.exit(1)
        for value in digests.values():
            if not isinstance(value, str) or not digest_re.match(value):
                sys.exit(1)


kit = doc.get("kit")
if not isinstance(kit, dict):
    sys.exit(1)
check_block(kit)
components = doc.get("components")
if not isinstance(components, dict) or not components:
    sys.exit(1)
for block in components.values():
    check_block(block)
# Optional and additive: absent until the first Kit 2 assets ship.
if doc.get("kit2") is not None:
    check_block(doc["kit2"])
PY
        _vv_rc=$?
        [ "$_vv_rc" -eq 2 ] && _EXAKIT_VERSIONS_SCHEMA_AHEAD=1
        [ "$_vv_rc" -eq 0 ] || _exakit_log_file "WARN  versions manifest rejected ($_vv_file, code $_vv_rc)"
        return $_vv_rc
    fi
    _exakit_versions_validate_shell "$_vv_file"
}

# No-Python fallback for the gate above: shape check plus a charset sweep over
# every scalar the kit would actually use.
_exakit_versions_validate_shell() {
    _vs_file="$1"
    case "$(sed -n '1p' "$_vs_file" | tr -d '\r')" in
        '{') ;;
        *) return 1 ;;
    esac
    _vs_schema="$(_exakit_json_leaves "$_vs_file" schema_version)"
    if [ "$_vs_schema" != "$EXAKIT_VERSIONS_SCHEMA" ]; then
        case "$_vs_schema" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$_vs_schema" -gt "$EXAKIT_VERSIONS_SCHEMA" ] || return 1
        _EXAKIT_VERSIONS_SCHEMA_AHEAD=1
        return 2
    fi
    _vs_kit="$(_exakit_json_leaves "$_vs_file" kit.version)"
    [ -n "$_vs_kit" ] || return 1
    _vs_seen_version=0
    while IFS="$(printf '\t')" read -r _vs_path _vs_value; do
        [ -n "$_vs_path" ] || continue
        case "$_vs_path" in
            *.sha256.*)
                case "$_vs_value" in
                    *[!0-9a-f]*|'') return 1 ;;
                esac
                [ "${#_vs_value}" -eq 64 ] || return 1
                ;;
            *version)
                # Covers kit.version, every components.*.version and any
                # min_kit_version; schema_version is the document's own integer.
                case "$_vs_path" in schema_version) continue ;; esac
                case "$_vs_value" in
                    ''|*[!A-Za-z0-9._+-]*) return 1 ;;
                esac
                _vs_seen_version=1
                ;;
        esac
    done <<EOF
$(_exakit_json_leaves "$_vs_file")
EOF
    [ "$_vs_seen_version" -eq 1 ]
}

# exakit_versions_baked_doc — the copy that shipped inside the installed kit.
# It is the last stop before the compiled-in fallbacks, and it is what makes an
# offline machine still agree with the release it installed.
exakit_versions_baked_doc() {
    _vb_root="$(exakit_repo_root 2>/dev/null || true)"
    [ -n "$_vb_root" ] || return 1
    [ -f "$_vb_root/versions.json" ] || return 1
    printf '%s\n' "$_vb_root/versions.json"
}

# exakit_format_local_time <utc-iso> — a manifest timestamp rendered for a human:
# "May 3, 2026 at 5:30 PM", in the machine's own timezone. The manifest keeps UTC
# ISO 8601 (machine-readable state must not move); only the display changes.
# Falls back to the raw value, because an awkward timestamp beats none at all.
# TWIN: Format-ExakitLocalTime in setup/lib/exakit-common.ps1.
exakit_format_local_time() {
    _flt_raw="$1"
    [ -n "$_flt_raw" ] || return 0
    if exakit_can_run_python; then
        _flt_out="$(
            run_python - "$_flt_raw" 2>/dev/null <<'PY'
import sys
from datetime import datetime, timezone

raw = sys.argv[1].strip()
try:
    stamp = datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except ValueError:
    raise SystemExit(1)
local = stamp.astimezone()
# Assembled by hand rather than with %-d/%-I: those are platform extensions and
# are not available everywhere this kit runs.
hour = local.strftime("%I").lstrip("0") or "12"
print("%s %d, %d at %s:%s" % (local.strftime("%B"), local.day, local.year,
                              hour, local.strftime("%M %p")))
PY
        )"
        if [ -n "$_flt_out" ]; then
            printf '%s\n' "$_flt_out"
            return 0
        fi
    fi
    printf '%s\n' "$_flt_raw"
}

# exakit_format_manifest_date <YYYY-MM-DD> — "2026-07-29" -> "July 29, 2026".
#
# The manifest's "updated" is a calendar date, not an instant, so it must NOT be
# converted to local time: a machine west of UTC would render the day before.
# That also rules out date(1), whose parsing flags differ between BSD and GNU.
# Pure shell instead — the shape is fixed (the CI schema check enforces
# YYYY-MM-DD), and a date is not worth a Python spawn. Anything not of that shape
# is passed through untouched rather than guessed at.
exakit_format_manifest_date() {
    _fmd_raw="$1"
    [ -n "$_fmd_raw" ] || return 0
    _fmd_year="${_fmd_raw%%-*}"
    _fmd_rest="${_fmd_raw#*-}"
    _fmd_month="${_fmd_rest%%-*}"
    _fmd_day="${_fmd_rest#*-}"
    case "${_fmd_year}${_fmd_month}${_fmd_day}" in
        ""|*[!0-9]*) printf '%s\n' "$_fmd_raw"; return 0 ;;
    esac
    case "$_fmd_month" in
        01) _fmd_name="January"   ;; 02) _fmd_name="February" ;;
        03) _fmd_name="March"     ;; 04) _fmd_name="April"    ;;
        05) _fmd_name="May"       ;; 06) _fmd_name="June"     ;;
        07) _fmd_name="July"      ;; 08) _fmd_name="August"   ;;
        09) _fmd_name="September" ;; 10) _fmd_name="October"  ;;
        11) _fmd_name="November"  ;; 12) _fmd_name="December" ;;
        *)  printf '%s\n' "$_fmd_raw"; return 0 ;;
    esac
    # Drop a leading zero for the day: "July 9", not "July 09".
    _fmd_day="${_fmd_day#0}"
    [ -n "$_fmd_day" ] || _fmd_day="0"
    printf '%s %s, %s\n' "$_fmd_name" "$_fmd_day" "$_fmd_year"
}

# exakit_kit_version_at <kit-root> [dot.path] — a version a specific kit tree
# states about itself: kit.version by default, kit2.version for the Kit 2 asset
# bundle. The installers use it on the tree they are installing FROM, which is not
# necessarily the copy under the kit home (that one may be an older install).
exakit_kit_version_at() {
    _kva_doc="$1/versions.json"
    _kva_path="${2:-kit.version}"
    [ -f "$_kva_doc" ] || return 1
    _kva_version="$(exakit_versions_value "$_kva_path" "$_kva_doc" 2>/dev/null || true)"
    case "$_kva_version" in
        ''|*[!A-Za-z0-9._+-]*) return 1 ;;
    esac
    printf '%s\n' "$_kva_version"
}

# exakit_kit_bundled_version — kit.version as recorded by the kit copy on disk.
# This is what "installed" means for the kit itself; the manifest's kit.source
# only says where the copy came from.
exakit_kit_bundled_version() {
    _kbv_root="$(exakit_repo_root 2>/dev/null)" || return 1
    exakit_kit_version_at "$_kbv_root"
}

# exakit_kit2_bundled_version — the version of the Kit 2 asset bundle this kit
# ships. Kit 2 assets travel INSIDE the kit tarball, so the bundle's version is a
# property of the kit copy on disk, not of anything installed separately.
exakit_kit2_bundled_version() {
    _k2b_root="$(exakit_repo_root 2>/dev/null)" || return 1
    exakit_kit_version_at "$_k2b_root" kit2.version
}

exakit_versions_user_agent() {
    _ua_kit="$(exakit_kit_bundled_version 2>/dev/null || true)"
    [ -n "$_ua_kit" ] || _ua_kit="unknown"
    if command -v detect_os >/dev/null 2>&1; then
        _ua_os="$(detect_os 2>/dev/null || true)"
        _ua_arch="$(detect_arch 2>/dev/null || true)"
    else
        _ua_os="$(uname -s 2>/dev/null || true)"
        _ua_arch="$(uname -m 2>/dev/null || true)"
    fi
    printf 'exakit-update-check/%s (%s; %s)\n' "$_ua_kit" "${_ua_os:-unknown}" "${_ua_arch:-unknown}"
}

_exakit_file_mtime() {
    case "$(uname -s 2>/dev/null || true)" in
        Darwin|*BSD*) stat -f %m "$1" 2>/dev/null ;;
        *)            stat -c %Y "$1" 2>/dev/null ;;
    esac
}

# exakit_versions_cache_age — seconds since the cached copy was written.
exakit_versions_cache_age() {
    [ -f "$EXAKIT_VERSIONS_CACHE" ] || return 1
    _vca_mtime="$(_exakit_file_mtime "$EXAKIT_VERSIONS_CACHE")"
    case "$_vca_mtime" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$(( $(date +%s) - _vca_mtime ))"
}

exakit_versions_cache_fresh() {
    _vcf_age="$(exakit_versions_cache_age 2>/dev/null)" || return 1
    case "$EXAKIT_VERSIONS_TTL" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_vcf_age" -lt "$EXAKIT_VERSIONS_TTL" ]
}

# _exakit_versions_attempt_recent — did we already fail to fetch, recently?
#
# WITHOUT THIS, AN UNREACHABLE MANIFEST TAXES EVERY COMMAND. A failed fetch
# writes nothing, so the cache never becomes fresh, so the next command tries
# again and pays the full connect timeout again — and so does the one after
# that. Measured on a corporate network where raw.githubusercontent.com is
# filtered: `exakit status` 12.7s and `exakit version` 19.3s, essentially all
# of it one timing-out request repeated on every invocation.
#
# The About cache has had this since it was written ("an .attempt- stamp so a
# failure is not retried on every run"); the versions cache never got the same
# treatment. Same idea: a stamp written BEFORE the request, so the question
# counts as asked whatever the answer turns out to be.
# ⇄ twin: Test-ExakitVersionsAttemptRecent in exakit-common.ps1.
_exakit_versions_attempt_stamp() {
    printf '%s/.%s.attempt\n' "$(dirname "$EXAKIT_VERSIONS_CACHE")" "$(basename "$EXAKIT_VERSIONS_CACHE")"
}

_exakit_versions_attempt_recent() {
    # TTL 0 means "always ask", and a caller who says that must not be answered
    # from a remembered failure. The cooldown is a cheaper form of the same
    # caching the TTL does, so it can never outlive it.
    case "$EXAKIT_VERSIONS_TTL" in
        0) return 1 ;;
    esac
    _var_stamp="$(_exakit_versions_attempt_stamp)"
    [ -f "$_var_stamp" ] || return 1
    case "$EXAKIT_VERSIONS_RETRY_COOLDOWN" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _var_now="$(date +%s 2>/dev/null)" || return 1
    _var_mtime="$(_exakit_file_mtime "$_var_stamp" 2>/dev/null)" || return 1
    [ -n "$_var_mtime" ] || return 1
    [ "$(( _var_now - _var_mtime ))" -lt "$EXAKIT_VERSIONS_RETRY_COOLDOWN" ]
}

# exakit_versions_update_cache [force] — refresh the cached document.
# Skips the network while the cache is younger than the TTL; "force" is for the
# explicit `exakit version`, which should always ask upstream.
# Returns 0 when a validated document was installed, 2 when the fetch was
# skipped as unnecessary, 1 when nothing could be fetched.
#
# A failed or invalid download never touches the cache: the temporary file lives
# in the cache directory (same filesystem) and only a validated document is
# moved into place, so a reader can never observe a half-written file.
exakit_versions_update_cache() {
    _vu_force="${1:-}"
    case "$EXAKIT_VERSIONS_URL" in
        https://*) ;;
        *)
            _exakit_log_file "WARN  refusing to fetch the versions manifest over a non-HTTPS URL"
            return 1
            ;;
    esac
    if [ "$_vu_force" != "force" ] && exakit_versions_cache_fresh; then
        return 2
    fi
    # A recent failure counts as answered: see _exakit_versions_attempt_recent.
    if [ "$_vu_force" != "force" ] && _exakit_versions_attempt_recent; then
        return 2
    fi
    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$EXAKIT_VERSIONS_CACHE")" 2>/dev/null || return 1
    # Written BEFORE the request, so a timeout or a kill still records that the
    # question was asked.
    : > "$(_exakit_versions_attempt_stamp)" 2>/dev/null || true
    _vu_tmp="$EXAKIT_VERSIONS_CACHE.tmp.$$"
    if ! curl -fsSL --proto '=https' --retry 1 \
            --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" \
            --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
            -A "$(exakit_versions_user_agent)" \
            -o "$_vu_tmp" "$EXAKIT_VERSIONS_URL" 2>/dev/null; then
        rm -f "$_vu_tmp"
        _exakit_log_file "INFO  versions manifest fetch failed — keeping the cached copy"
        return 1
    fi
    if ! exakit_versions_validate "$_vu_tmp"; then
        rm -f "$_vu_tmp"
        _exakit_log_file "WARN  fetched versions manifest did not validate — keeping the cached copy"
        return 1
    fi
    mv -f "$_vu_tmp" "$EXAKIT_VERSIONS_CACHE" 2>/dev/null || {
        rm -f "$_vu_tmp"
        return 1
    }
    _EXAKIT_VERSIONS_DOC="$EXAKIT_VERSIONS_CACHE"
    _EXAKIT_VERSIONS_SOURCE="fetched"
    _exakit_log_file "INFO  versions manifest refreshed from $EXAKIT_VERSIONS_URL"
    return 0
}

# _exakit_versions_cache_outranks_baked — is the CACHE actually newer than the
# manifest that shipped inside this kit?
#
# IT USED TO WIN UNCONDITIONALLY, and that reached a user as a failed Windows
# install. Their machine had a cache left by an older kit advertising launcher
# 2.2.0; the fetch could not reach the network, so the cache stood, and the
# installer downloaded 2.2.0 — a launcher with no Windows local deployment in
# it at all. Podman was therefore never installed (that is the launcher's job,
# and only from 2.3.0), and the run died on the launcher's own gate: "local
# deployments are only supported on macOS Apple Silicon (current platform:
# windows/amd64)". The kit had done exactly what it was told by a memo about
# what was current the LAST time some other kit ran.
#
# The cache exists to pick up releases newer than the one this kit shipped
# with, so it keeps precedence in every case but one: it loses when it can be
# PROVEN OLDER than the kit's own copy. Same date still wins (a fetch usually
# returns the document this kit shipped with, and a same-day republish must
# still be picked up), and so does a date that cannot be read on either side.
# Only a cache that demonstrably predates the running kit is refused, because
# only that one can downgrade it. Dates are the manifest's own "updated"
# field, ISO YYYY-MM-DD, so a string compare is a date compare.
# Twin of Test-ExakitVersionsCacheOutranksBaked.
_exakit_versions_cache_outranks_baked() {
    _vcb_cache="$1"; _vcb_baked="$2"
    [ -n "$_vcb_baked" ] && [ -f "$_vcb_baked" ] || return 0
    _vcb_bdate="$(exakit_versions_value updated "$_vcb_baked" 2>/dev/null || true)"
    [ -n "$_vcb_bdate" ] || return 0
    _vcb_cdate="$(exakit_versions_value updated "$_vcb_cache" 2>/dev/null || true)"
    [ -n "$_vcb_cdate" ] || return 0
    # Older than the kit being installed, and only then, the cache is refused.
    [ "$_vcb_cdate" \< "$_vcb_bdate" ] && return 1
    return 0
}

# exakit_versions_resolve_doc — pick the document to read and remember it in
# _EXAKIT_VERSIONS_DOC/_SOURCE. Callers that read several values should call
# this once first: command substitutions inherit the memo, so the validation
# gate runs once per command instead of once per lookup.
exakit_versions_resolve_doc() {
    [ -n "$_EXAKIT_VERSIONS_DOC" ] && return 0
    # The cache is written only after validation, but anything under the kit
    # home can be edited by hand — re-check before trusting it.
    _vr_baked="$(exakit_versions_baked_doc 2>/dev/null || true)"
    if [ -f "$EXAKIT_VERSIONS_CACHE" ] && exakit_versions_validate "$EXAKIT_VERSIONS_CACHE" &&
       _exakit_versions_cache_outranks_baked "$EXAKIT_VERSIONS_CACHE" "$_vr_baked"; then
        _EXAKIT_VERSIONS_DOC="$EXAKIT_VERSIONS_CACHE"
        [ -n "$_EXAKIT_VERSIONS_SOURCE" ] || _EXAKIT_VERSIONS_SOURCE="cache"
        return 0
    fi
    if [ -n "$_vr_baked" ] && exakit_versions_validate "$_vr_baked"; then
        _EXAKIT_VERSIONS_DOC="$_vr_baked"
        _EXAKIT_VERSIONS_SOURCE="baked"
        return 0
    fi
    _EXAKIT_VERSIONS_SOURCE="fallback"
    return 1
}

exakit_versions_active_doc() {
    exakit_versions_resolve_doc || return 1
    printf '%s\n' "$_EXAKIT_VERSIONS_DOC"
}

# exakit_versions_source — where the answers came from: fetched | cache | baked
# | fallback. Shown by `exakit version` and recorded as desired.versions_source.
exakit_versions_source() {
    [ -n "$_EXAKIT_VERSIONS_SOURCE" ] || exakit_versions_resolve_doc >/dev/null 2>&1 || true
    printf '%s\n' "${_EXAKIT_VERSIONS_SOURCE:-fallback}"
}

# exakit_versions_schema_ahead — true when a document was readable JSON but
# announced a newer schema, so callers can suggest updating the kit.
exakit_versions_schema_ahead() {
    [ "$_EXAKIT_VERSIONS_SCHEMA_AHEAD" -eq 1 ]
}

# exakit_versions_value <dot.path> [file] — the advertised value, e.g.
#   exakit_versions_value components.exapump.version
#   exakit_versions_value components.exapump.sha256.macos-aarch64
# Non-zero exit means "not advertised" — never a failure to be propagated.
exakit_versions_value() {
    _vv_path="$1"
    _vv_doc="${2:-}"
    if [ -z "$_vv_doc" ]; then
        exakit_versions_resolve_doc || return 1
        _vv_doc="$_EXAKIT_VERSIONS_DOC"
    fi
    [ -f "$_vv_doc" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_vv_doc" "$_vv_path" <<'PY' 2>/dev/null
import json, sys

try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
node = doc
for part in sys.argv[2].split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(1)
print(node if isinstance(node, str) else json.dumps(node))
PY
        return $?
    fi
    _vv_out="$(_exakit_json_leaves "$_vv_doc" "$_vv_path")"
    [ -n "$_vv_out" ] || return 1
    printf '%s\n' "$_vv_out"
}

# ---------------------------------------------------------------------------
# Version resolution and update planning
# ---------------------------------------------------------------------------
# The installed runtime version, read from the runtime itself with the record as
# the fallback. Deliberately different from exapump and pyexasol in one way: a probe
# that cannot answer NEVER reports absence here. A launcher that is busy or a
# deployment that is stopped is an ordinary, temporary state, and flipping the
# runtime row to "inspect" every time would be noise. Whether the runtime exists
# at all is `exakit status`'s question, and it asks the launcher directly.

# exakit_run_bounded <seconds> <command> [args...] — run a command and give up on
# it after <seconds>, exiting 124 if it had to be cut off.
#
# A launcher wedged on a deployment it cannot open does not return, so an
# unbounded probe turns `exakit status` and `exakit version` into commands that
# print nothing at all for as long as it hangs. Reading a version is never worth
# that wait: the probes fall back to the recorded value, which is exactly what
# they do when the deployment is stopped.
#
# timeout(1) is not on a stock macOS and gtimeout only arrives with coreutils, so
# both are used when present and otherwise the command runs in the background and
# is polled. SIGTERM first, then SIGKILL for a client that ignores it.
exakit_run_bounded() {
    _rb_limit="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_rb_limit" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$_rb_limit" "$@"
        return $?
    fi
    "$@" &
    _rb_pid=$!
    _rb_waited=0
    while [ "$_rb_waited" -lt "$_rb_limit" ]; do
        if ! kill -0 "$_rb_pid" 2>/dev/null; then
            wait "$_rb_pid"
            return $?
        fi
        sleep 1
        _rb_waited=$((_rb_waited + 1))
    done
    # The GROUP first, then the child: a probe captured with $( ) stays blocked
    # until every process holding the pipe's write end exits, so killing only
    # the direct child leaves its own children keeping the capture open. When
    # the child leads no group of its own (non-interactive shells put it in
    # the script's group, where a group kill must never land), the group kill
    # is a no-op and the direct one still applies.
    kill -TERM -- "-$_rb_pid" 2>/dev/null || kill -TERM "$_rb_pid" 2>/dev/null
    sleep 1
    kill -KILL -- "-$_rb_pid" 2>/dev/null || kill -KILL "$_rb_pid" 2>/dev/null
    wait "$_rb_pid" 2>/dev/null
    return 124
}

# exakit_installed_personal_version — the RECORD, deliberately.
#
# Not a live `exasol version` here: a half-done MAJOR upgrade installs the new
# launcher and still owes a data migration, and reading the binary would call
# that "current" while personal_update kept offering it — the two commands
# disagreeing about one install. The record is what both of them read, and it
# carries the outstanding work in runtime.migration_pending beside it.
#
# What the record MEANS is the launcher, because that is what components.personal
# names and what an update installs; personal_record_manifest asks the binary
# once, when it writes. The deployment's own version rides beside it in
# runtime.deployment_version, because a deployment keeps the version that
# created it and the two answer different questions.
exakit_installed_personal_version() {
    manifest_get runtime.version 2>/dev/null
}

exakit_installation_runtime_type() {
    manifest_get runtime.type 2>/dev/null
}

# The recorded runtime types that belong to a kit OLDER than this one: a
# database in a container, which this kit neither deploys nor drives.
EXAKIT_LEGACY_RUNTIME_TYPES="${EXAKIT_LEGACY_RUNTIME_TYPES:-nano}"

# exakit_legacy_runtime_recorded — 0 when this machine's installation was made
# by an older kit whose database is a container.
#
# It lives HERE, not in legacy-crossing.sh, because the CLI has to be able to
# ask it: `exakit status` on such a machine would otherwise print "nano · not
# installed", which reads as a broken install rather than one that predates the
# removal of the container runtime. The crossing module reads the same answer
# from the same place, so the installer and the CLI can never disagree about
# what this machine is.
exakit_legacy_runtime_recorded() {
    _lrr_type="$(exakit_installation_runtime_type 2>/dev/null || true)"
    [ -n "$_lrr_type" ] || return 1
    for _lrr_known in $EXAKIT_LEGACY_RUNTIME_TYPES; do
        [ "$_lrr_type" = "$_lrr_known" ] && return 0
    done
    return 1
}

# exakit_legacy_runtime_notice — the one sentence a legacy install needs, and
# the command that moves it across. Silent on every other machine, so callers
# do not have to guard it.
exakit_legacy_runtime_notice() {
    exakit_legacy_runtime_recorded || return 0
    warn "This installation's database runs in a container, which this kit no longer manages."
    info "Re-run the installer to move across — it asks whether to bring your data with you, and deletes nothing either way:"
    info "  $(exakit_install_command)"
    return 0
}

# exakit_runtime_is_running — one question, no side effects: is the installed
# database runtime up right now? The pure check that `exakit status` branches
# its exit code on and `exakit mcp-doctor` consults BEFORE any operation that
# needs a live database — so a stopped database is diagnosed as exactly that,
# never as whatever downstream step happened to fail first.
exakit_runtime_is_running() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        personal)
            command -v personal_deployment_running >/dev/null 2>&1 || return 1
            personal_deployment_running 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

# exakit_runtime_remedy — the command that actually fixes a database which is not
# running right now. ONE definition, because every place that reports the state
# also has to report the fix, and they must not drift: `exakit start` is right for
# a stopped database and wrong for an interrupted one, where it fails identically
# every time it is tried.
# ⇄ twin: Get-ExakitRuntimeRemedy in setup/exakit.ps1.
exakit_runtime_remedy() {
    if command -v personal_deployment_wedged >/dev/null 2>&1 && \
       personal_deployment_wedged >/dev/null 2>&1; then
        printf 'exakit repair-runtime\n'
    else
        printf 'exakit start\n'
    fi
}

# exakit_loaded_datasets — the bundled datasets that are loaded, one id per
# line. This is what `exakit status` answers "what data is in there?" with, so
# it has to be true and not merely recorded.
#
# THE DATABASE IS ASKED FIRST. The manifest alone reported three loaded datasets
# against a database with zero schemas after a destroy+redeploy — the worst
# possible answer for an agent rebuilding its bearings after a context reset,
# because it sends it straight into "object TPCH.LINEITEM not found" with the
# real cause (no data) recorded nowhere. exakit_verified_datasets checks the
# marker tables and heals the flags; it lives in exapump.sh, which the CLI loads
# conditionally, and it declines when the database is unreachable. Either way
# the manifest read below is the fallback, never the first answer.
exakit_loaded_datasets() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    if command -v exakit_verified_datasets >/dev/null 2>&1; then
        _eld_verified="$(exakit_verified_datasets 2>/dev/null)" && {
            [ -n "$_eld_verified" ] && printf '%s\n' "$_eld_verified"
            return 0
        }
    fi
    exakit_can_run_python || return 0
    run_python - "$EXAKIT_MANIFEST" <<'EXAKIT_LD_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except Exception:
    sys.exit(0)
datasets = ((doc.get("data") or {}).get("datasets")) or {}
for name in sorted(datasets):
    if isinstance(datasets[name], dict) and datasets[name].get("loaded"):
        print(name)
EXAKIT_LD_PY
    return 0
}

exakit_installation_runtime_version() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        personal) exakit_installed_personal_version ;;
        *) return 1 ;;
    esac
}

exakit_record_desired_versions() {
    manifest_set version_policy "$EXAKIT_VERSION_POLICY"
    manifest_set desired.versions_source "${EXAKIT_VERSIONS_SOURCE_USED:-unknown}"
    manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
    manifest_set desired.exapump "$EXAKIT_EXAPUMP_VERSION"
    manifest_set desired.mcp "$EXAKIT_MCP_VERSION"
    manifest_set desired.pyexasol "$EXAKIT_PYEXASOL_VERSION"
}

exakit_update_actual_target() {
    case "$1" in
        runtime|database|db)
            _rtype="$(exakit_installation_runtime_type 2>/dev/null || true)"
            [ -n "$_rtype" ] || return 1
            printf '%s\n' "$_rtype"
            ;;
        *) printf '%s\n' "$1" ;;
    esac
}

exakit_latest_github_release_version() {
    _repo="$1"
    _json="$(curl -fsSL --proto '=https' --proto-redir '=https' --retry 1 --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        "https://api.github.com/repos/${_repo}/releases/latest" 2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c 'import json,sys; print(json.load(sys.stdin).get("tag_name","").lstrip("v"))' 2>/dev/null
        return $?
    fi
    printf '%s' "$_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1
}

exakit_latest_pypi_version() {
    _package="$1"
    _json="$(curl -fsSL --proto '=https' --proto-redir '=https' --retry 1 --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        "https://pypi.org/pypi/${_package}/json" 2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("version",""))' 2>/dev/null
        return $?
    fi
    printf '%s' "$_json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}



# exakit_version_newer <a> <b> — true when <a> sorts after <b>.
# The _vn_ prefix matters: bash 3.2 has no function-local variables here, and
# callers hold their own state in names like _current/_latest while asking this
# question (sometimes with the arguments the other way round, to detect a
# rollback). Anything less specific would silently overwrite the caller's data.
exakit_version_newer() {
    _vn_a="$1"
    _vn_b="$2"
    [ -n "$_vn_a" ] && [ -n "$_vn_b" ] || return 1
    [ "$_vn_a" != "$_vn_b" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_vn_a" "$_vn_b" <<'EXAKIT_VERCMP_PY'
import re, sys

# A PRE-RELEASE SORTS BELOW ITS OWN RELEASE. The old key() split on digit runs
# and compared the pieces, which put "2.3.0-rc1" ABOVE "2.3.0": the list for
# "2.3.0" ends where the rc's carries on, and the longer list wins. So anyone
# who installed a release candidate was told they were already ahead, and
# `exakit update` refused to move them onto the real release - permanently. It
# also sorted "0.13.0.post1" below "0.13.0", and could raise TypeError
# comparing an int piece against a str piece on a shape it did not expect.
def parse(v):
    v = v.strip().lstrip("v")
    # Build metadata carries no ordering information (semver clause 10).
    v = v.split("+", 1)[0]
    # PEP 440's .postN FOLLOWS the release; semver's -rcN precedes it.
    post = 0
    m = re.search(r"\.post(\d+)$", v)
    if m:
        post = int(m.group(1))
        v = v[:m.start()]
    pre = ()
    m = re.match(r"^(.*?)[-_.]?(rc|alpha|beta|a|b)\.?(\d*)$", v)
    if m and m.group(2):
        v = m.group(1).rstrip(".-_")
        pre = ({"alpha": 0, "a": 0, "beta": 1, "b": 1, "rc": 2}[m.group(2)],
               int(m.group(3) or 0))
    nums = tuple(int(p) for p in re.findall(r"\d+", v))
    # (1,) for a plain release beats (0, ...) for any pre-release of it, and
    # every element compared is an int, so this cannot raise.
    return (nums, (1,) if not pre else (0,) + pre, post)

sys.exit(0 if parse(sys.argv[1]) > parse(sys.argv[2]) else 1)
EXAKIT_VERCMP_PY
        return $?
    fi
    # NO PYTHON: STILL AN ORDER, NOT A COIN TOSS. This used to compare the
    # MAJOR only and then return "the strings differ" for anything inside one -
    # so 2.3.0 was newer than 2.4.0 AND 2.4.0 was newer than 2.3.0. Both
    # directions true meant exakit_component_is_ahead read every same-major
    # component as ahead of its advertised version, and `exakit update`
    # answered "yours is newer than the tested one - keeping yours" and skipped
    # every component, forever, on any machine with neither python3 nor uv.
    # runtime-personal.sh already wrote a Python-free comparator for precisely
    # this hazard and says so in its comment; this guard never got the same.
    _vn_num() { # _vn_num <version> <field> - that dotted field, digits only, 0 if absent
        _vnn="$(printf '%s' "${1#v}" | cut -d'.' -f"$2" 2>/dev/null)"
        _vnn="${_vnn%%[!0-9]*}"
        [ -n "$_vnn" ] || _vnn=0
        printf '%s' "$_vnn"
    }
    # The release part only: everything before a pre-release or build suffix.
    _vn_a_rel="${_vn_a%%[-+]*}"
    _vn_b_rel="${_vn_b%%[-+]*}"
    _vn_i=1
    while [ "$_vn_i" -le 4 ]; do
        _vn_x="$(_vn_num "$_vn_a_rel" "$_vn_i")"
        _vn_y="$(_vn_num "$_vn_b_rel" "$_vn_i")"
        [ "$_vn_x" -gt "$_vn_y" ] && return 0
        [ "$_vn_x" -lt "$_vn_y" ] && return 1
        _vn_i=$(( _vn_i + 1 ))
    done
    # Same release numbers. Rank the suffix the way the Python arm does, so a
    # machine without Python still moves rc1 -> rc2 and release -> .post1
    # instead of sitting still. Stopping at "a release beats a pre-release"
    # would have been SAFE - it errs toward offering nothing - but it would
    # also strand exactly the people running pre-releases, who are the ones
    # who most need the next one.
    #
    # Rank: alpha 1 < beta 2 < rc 3 < plain release 4 < .postN 5.
    _vn_rank() { # _vn_rank <version> -> "<rank> <number>"
        case "$1" in
            *.post*) printf '5 %s' "$(printf '%s' "${1##*.post}" | tr -cd '0-9')"; return ;;
        esac
        _vnr_suf="${1#*-}"
        [ "$_vnr_suf" = "$1" ] && { printf '4 0'; return; }
        _vnr_n="$(printf '%s' "$_vnr_suf" | tr -cd '0-9')"
        [ -n "$_vnr_n" ] || _vnr_n=0
        case "$_vnr_suf" in
            alpha*|a[0-9]*) printf '1 %s' "$_vnr_n" ;;
            beta*|b[0-9]*)  printf '2 %s' "$_vnr_n" ;;
            rc*)            printf '3 %s' "$_vnr_n" ;;
            *)              printf '0 %s' "$_vnr_n" ;;
        esac
    }
    _vn_a_rank="$(_vn_rank "$_vn_a")"
    _vn_b_rank="$(_vn_rank "$_vn_b")"
    _vn_ar="${_vn_a_rank%% *}"; _vn_an="${_vn_a_rank##* }"
    _vn_br="${_vn_b_rank%% *}"; _vn_bn="${_vn_b_rank##* }"
    [ "$_vn_ar" -gt "$_vn_br" ] && return 0
    [ "$_vn_ar" -lt "$_vn_br" ] && return 1
    [ "${_vn_an:-0}" -gt "${_vn_bn:-0}" ]
}

exakit_major_version() {
    printf '%s\n' "$1" | sed -E 's/^v//; s/^([0-9]+).*/\1/'
}

# exakit_resolve_install_versions — decide which version of each Component this
# install gets. An explicit env override (EXAKIT_*_VERSION) always wins; the
# policy decides where the rest comes from. Resolution never
# fails: each tier degrades into the next, and the recorded
# desired.versions_source says which one answered.
exakit_resolve_install_versions() {
    case "${EXAKIT_VERSION_POLICY:-manifest}" in
        latest)   _exakit_resolve_versions_latest ;;
        manifest) _exakit_resolve_versions_manifest ;;
        *)        _exakit_resolve_versions_pinned ;;
    esac
    export EXAKIT_PERSONAL_VERSION EXAKIT_EXAPUMP_VERSION EXAKIT_MCP_VERSION EXAKIT_PYEXASOL_VERSION
    [ -f "$EXAKIT_MANIFEST" ] && exakit_record_desired_versions
    return 0
}

# The versions manifest: one TTL-gated fetch, then read. A fresh install picks up
# the currently advertised set; an offline one silently uses the cached copy, the
# copy that shipped with this kit, or the constants above.
_exakit_resolve_versions_manifest() {
    exakit_versions_update_cache >/dev/null 2>&1 || true
    # Resolve once in THIS shell so the command substitutions below inherit the
    # decision instead of re-validating the document for every lookup.
    exakit_versions_resolve_doc >/dev/null 2>&1 || true
    EXAKIT_VERSIONS_SOURCE_USED="${_EXAKIT_VERSIONS_SOURCE:-fallback}"
    _exakit_resolve_one EXAKIT_PERSONAL_VERSION components.personal.version "$EXAKIT_PERSONAL_VERSION_FALLBACK"
    _exakit_resolve_one EXAKIT_EXAPUMP_VERSION components.exapump.version "$EXAKIT_EXAPUMP_VERSION_FALLBACK"
    _exakit_resolve_one EXAKIT_MCP_VERSION components.mcp.version "$EXAKIT_MCP_VERSION_FALLBACK"
    _exakit_resolve_one EXAKIT_PYEXASOL_VERSION components.pyexasol.version "$EXAKIT_PYEXASOL_VERSION_FALLBACK"
    _exakit_log_file "INFO  versions resolved from the manifest ($EXAKIT_VERSIONS_SOURCE_USED)"
}

# _exakit_resolve_one <var-name> <dot.path> <fallback> — fill <var-name> unless
# it already carries an env override. bash 3.2 has no namerefs, so eval does the
# assignment; the value is charset-checked by the validation gate before it ever
# reaches this point.
_exakit_resolve_one() {
    eval "_ro_current=\${$1:-}"
    [ -z "$_ro_current" ] || return 0
    _ro_value="$(exakit_versions_value "$2" 2>/dev/null || true)"
    [ -n "$_ro_value" ] || _ro_value="$3"
    eval "$1=\$_ro_value"
}

# Today's live-lookup behaviour, kept intact as the escape hatch for anyone who
# wants the newest of every Component rather than the tested set.
_exakit_resolve_versions_latest() {
    EXAKIT_VERSIONS_SOURCE_USED="latest"
    if [ -z "$EXAKIT_PERSONAL_VERSION" ]; then
        EXAKIT_PERSONAL_VERSION="$(exakit_latest_github_release_version "$EXAKIT_PERSONAL_REPO" || true)"
        [ -n "$EXAKIT_PERSONAL_VERSION" ] || EXAKIT_PERSONAL_VERSION="$EXAKIT_PERSONAL_VERSION_FALLBACK"
    fi
    if [ -z "$EXAKIT_EXAPUMP_VERSION" ]; then
        EXAKIT_EXAPUMP_VERSION="$(exakit_latest_github_release_version "$EXAKIT_EXAPUMP_REPO" || true)"
        [ -n "$EXAKIT_EXAPUMP_VERSION" ] || EXAKIT_EXAPUMP_VERSION="$EXAKIT_EXAPUMP_VERSION_FALLBACK"
    fi
    if [ -z "$EXAKIT_MCP_VERSION" ]; then
        EXAKIT_MCP_VERSION="$(exakit_latest_pypi_version "$EXAKIT_MCP_PACKAGE" || true)"
        [ -n "$EXAKIT_MCP_VERSION" ] || EXAKIT_MCP_VERSION="$EXAKIT_MCP_VERSION_FALLBACK"
    fi
    if [ -z "$EXAKIT_PYEXASOL_VERSION" ]; then
        EXAKIT_PYEXASOL_VERSION="$(exakit_latest_pypi_version "${EXAKIT_PYEXASOL_PACKAGE:-pyexasol}" || true)"
        [ -n "$EXAKIT_PYEXASOL_VERSION" ] || EXAKIT_PYEXASOL_VERSION="$EXAKIT_PYEXASOL_VERSION_FALLBACK"
    fi
}

# No network at all: the last-known-good constants only.
_exakit_resolve_versions_pinned() {
    EXAKIT_VERSIONS_SOURCE_USED="fallback"
    EXAKIT_PERSONAL_VERSION="${EXAKIT_PERSONAL_VERSION:-$EXAKIT_PERSONAL_VERSION_FALLBACK}"
    EXAKIT_EXAPUMP_VERSION="${EXAKIT_EXAPUMP_VERSION:-$EXAKIT_EXAPUMP_VERSION_FALLBACK}"
    EXAKIT_MCP_VERSION="${EXAKIT_MCP_VERSION:-$EXAKIT_MCP_VERSION_FALLBACK}"
    EXAKIT_PYEXASOL_VERSION="${EXAKIT_PYEXASOL_VERSION:-$EXAKIT_PYEXASOL_VERSION_FALLBACK}"
}

# exakit_component_latest <component> — the newest version upstream publishes.
# The implementation behind EXAKIT_VERSION_POLICY=latest; under the default
# manifest policy nothing calls it, which is what keeps `exakit version` and the
# update notice off the network.
exakit_component_latest() {
    case "$1" in
        exakit)   exakit_latest_github_release_version "$EXAKIT_KIT_REPO" ;;
        exapump)  exakit_latest_github_release_version "$EXAKIT_EXAPUMP_REPO" ;;
        mcp)      exakit_latest_pypi_version "$EXAKIT_MCP_PACKAGE" ;;
        pyexasol) exakit_latest_pypi_version "${EXAKIT_PYEXASOL_PACKAGE:-pyexasol}" ;;
        personal) exakit_latest_github_release_version "$EXAKIT_PERSONAL_REPO" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                personal) exakit_component_latest personal ;;
                *) return 1 ;;
            esac
            ;;
        *)
            # Marketplace add-ons declare their upstream in versions.json:
            # repo -> a GitHub release, package -> PyPI. No per-add-on arm.
            _exakit_addon_registered "$1" || return 1
            # An add-on whose "latest" is neither of those answers for itself.
            # json-tables is the case this exists for: what is installable is
            # what the kit's packaging workflow has already built and
            # published, which is a stricter thing than what upstream tagged.
            _cl_fn="$(_exakit_addon_fn "$1" latest)"
            if command -v "$_cl_fn" >/dev/null 2>&1; then
                "$_cl_fn"
                return $?
            fi
            _cl_repo="$(exakit_versions_value "components.$1.repo" 2>/dev/null || true)"
            if [ -n "$_cl_repo" ]; then
                exakit_latest_github_release_version "$_cl_repo"
                return $?
            fi
            _cl_pkg="$(exakit_versions_value "components.$1.package" 2>/dev/null || true)"
            if [ -n "$_cl_pkg" ]; then
                exakit_latest_pypi_version "$_cl_pkg"
                return $?
            fi
            return 1
            ;;
    esac
}

# _exakit_component_block <component> — where this Component lives in
# versions.json. One mapping serves version, severity, note and min_kit_version.
_exakit_component_block() {
    case "$1" in
        exakit) printf '%s\n' kit ;;
        kit2)   printf '%s\n' kit2 ;;
        exapump|mcp|pyexasol|personal|skills) printf 'components.%s\n' "$1" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                personal) printf '%s\n' components.personal ;;
                *) return 1 ;;
            esac
            ;;
        *)
            # Every marketplace add-on lives at components.<id> by convention.
            _exakit_addon_registered "$1" || return 1
            printf 'components.%s\n' "$1"
            ;;
    esac
}

# _exakit_component_env_override <component> — the version the user asked for by
# hand, if any. Same precedence as the install path: an explicit
# EXAKIT_*_VERSION outranks the manifest and any upstream
# lookup, so `EXAKIT_EXAPUMP_VERSION=0.11.2 exakit update exapump` installs
# exactly that (still through the confirmation gate, and still verified — the
# digest chain falls back to the release API when the version is not the
# advertised one).
_exakit_component_env_override() {
    case "$1" in
        exapump)  printf '%s' "${EXAKIT_EXAPUMP_VERSION:-}" ;;
        mcp)      printf '%s' "${EXAKIT_MCP_VERSION:-}" ;;
        pyexasol) printf '%s' "${EXAKIT_PYEXASOL_VERSION:-}" ;;
        personal) printf '%s' "${EXAKIT_PERSONAL_VERSION:-}" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                personal) printf '%s' "${EXAKIT_PERSONAL_VERSION:-}" ;;
            esac
            ;;
        *)
            # Marketplace add-ons follow the derived-name convention:
            # EXAKIT_<ID>_VERSION with dashes flipped to underscores.
            if _exakit_addon_registered "$1"; then
                eval "printf '%s' \"\${$(_exakit_addon_env_var "$1" VERSION):-}\""
            fi
            ;;
    esac
}

# exakit_component_available <component> — the version this kit would install
# NOW, under the policy in force. That is the promise the Tagged column makes,
# so each policy answers from the same place its install path would:
#   env override  the version the user asked for
#   manifest      versions.json
#   latest        a live upstream lookup
#   anything else the compiled-in *_FALLBACK constant
# Empty output means "cannot tell" (no readable document), which the table reports
# as unknown rather than guessing.
# exakit_version_plain <version> — a version as the tables spell it: no leading
# "v".
#
# Upstreams disagree about the prefix. Most of what the kit reports is a bare
# number (0.1.0, 1.7.0, 2.2.0) because that is what its source says, but
# json-tables takes its version from a git tag and reported "v0.2" — one row in
# two tables wearing a prefix none of its neighbours wore, which reads as a
# different KIND of version rather than the same thing spelled differently.
#
# Normalised where versions are DISPLAYED, never where they are compared or
# stored: the tag is what it is, and nothing downstream should start guessing
# which spelling it is holding. Anything that is not a "v" followed by a digit
# is returned untouched, so a version legitimately starting with a letter
# (a codename, "vNext") keeps it.
exakit_version_plain() {
    case "$1" in
        v[0-9]*) printf '%s\n' "${1#v}" ;;
        *)       printf '%s\n' "$1" ;;
    esac
}

exakit_component_available() {
    _cav_override="$(_exakit_component_env_override "$1")"
    if [ -n "$_cav_override" ]; then
        printf '%s\n' "$_cav_override"
        return 0
    fi
    case "${EXAKIT_VERSION_POLICY:-manifest}" in
        latest)
            exakit_component_latest "$1"
            return $?
            ;;
        manifest) ;;
        *)
            _exakit_component_fallback "$1"
            return $?
            ;;
    esac
    _cav_block="$(_exakit_component_block "$1" 2>/dev/null)" || return 1
    _cav_value="$(exakit_versions_value "${_cav_block}.version" 2>/dev/null || true)"
    if [ -n "$_cav_value" ]; then
        printf '%s\n' "$_cav_value"
        return 0
    fi
    # A marketplace add-on can be newer than the published manifest (the kit
    # copy carrying it ships before the advertised set catches up): its
    # module's own fallback constant answers instead of "unknown" — the same
    # version the marketplace install would actually install.
    if _exakit_addon_registered "$1"; then
        _exakit_component_fallback "$1"
        return $?
    fi
    # The skill set likewise: a document with no skills block advertises
    # nothing newer than what the kit copy carries, so that is the answer --
    # not "unknown", which would park the row on "inspect" for good.
    if [ "$1" = "skills" ]; then
        _exakit_component_fallback skills
        return $?
    fi
    return 1
}

# The last-known-good constant for a Component: what a no-network install picks.
_exakit_component_fallback() {
    case "$1" in
        exapump)  printf '%s\n' "$EXAKIT_EXAPUMP_VERSION_FALLBACK" ;;
        mcp)      printf '%s\n' "$EXAKIT_MCP_VERSION_FALLBACK" ;;
        pyexasol) printf '%s\n' "$EXAKIT_PYEXASOL_VERSION_FALLBACK" ;;
        personal) printf '%s\n' "$EXAKIT_PERSONAL_VERSION_FALLBACK" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                personal) printf '%s\n' "$EXAKIT_PERSONAL_VERSION_FALLBACK" ;;
                *) return 1 ;;
            esac
            ;;
        # The skill set has no constant either: the kit copy on disk says which
        # set it carries (its versions.json, or the marker a skills-only update
        # left beside the skills).
        skills)   exakit_skills_local_version ;;
        # The kit's own version is not one of the constants: it comes from the
        # copy on disk, which is exactly what is installed.
        exakit) exakit_kit_bundled_version ;;
        *)
            # Marketplace add-ons: EXAKIT_<ID>_VERSION_FALLBACK, defined by the
            # add-on's own module (empty when the module is not loaded).
            _exakit_addon_registered "$1" || return 1
            eval "_cf_value=\"\${$(_exakit_addon_env_var "$1" VERSION_FALLBACK):-}\""
            [ -n "$_cf_value" ] || return 1
            printf '%s\n' "$_cf_value"
            ;;
    esac
}

# The severity, note and min_kit_version below describe the ADVERTISED version of
# a Component. When the version on offer comes from somewhere else — a live
# upstream lookup under `latest`, the fallback constants, or the user's own env
# override — pairing it with the maintainers' commentary would be actively
# misleading ("0.12.0 is the tested build" next to an available 9.9.9).
_exakit_manifest_metadata_applies() {
    [ "${EXAKIT_VERSION_POLICY:-manifest}" = "manifest" ] || return 1
    [ -z "$(_exakit_component_env_override "$1")" ]
}

# exakit_component_severity <component> — normal | recommended | critical.
# Absent means normal; the value gates the after-command notice and is the only
# thing that makes a row stand out in the table.
exakit_component_severity() {
    _exakit_manifest_metadata_applies "$1" || { printf '%s\n' normal; return 0; }
    _cs_block="$(_exakit_component_block "$1" 2>/dev/null)" || { printf '%s\n' normal; return 0; }
    _cs_value="$(exakit_versions_value "${_cs_block}.severity" 2>/dev/null || true)"
    case "$_cs_value" in
        recommended|critical) printf '%s\n' "$_cs_value" ;;
        *) printf '%s\n' normal ;;
    esac
}

# exakit_component_note <component> — the maintainer's one-line note, if any.
exakit_component_note() {
    _exakit_manifest_metadata_applies "$1" || return 1
    _cn_block="$(_exakit_component_block "$1" 2>/dev/null)" || return 1
    exakit_versions_value "${_cn_block}.note"
}

# exakit_component_min_kit <component> — the kit version this Component needs.
exakit_component_min_kit() {
    _exakit_manifest_metadata_applies "$1" || return 1
    _cm_block="$(_exakit_component_block "$1" 2>/dev/null)" || return 1
    exakit_versions_value "${_cm_block}.min_kit_version"
}

# exakit_component_supported <component> — false when no build of it exists for THIS
# machine. The kit must never offer an update for something that cannot be installed
# here: exapump publishes binaries for x86_64 and arm64 on macOS and Linux, nothing for
# a CPU outside those, and nothing at all for Windows on ARM (see Get-ExapumpAssetName
# in exapump.ps1, and the installer's own $exapumpSupported gate).
# ⇄ twin: Test-ExakitComponentSupported in setup/exakit.ps1.
exakit_component_supported() {
    case "$1" in
        exapump)
            command -v detect_arch >/dev/null 2>&1 || return 0
            [ "$(detect_arch 2>/dev/null || true)" != "unsupported" ] || return 1
            return 0
            ;;
        *) return 0 ;;
    esac
}

# exakit_component_is_heavy <component> — true for changes that stop the
# database. Intrinsic to the Component, so it lives in code rather than in the
# manifest: the runtime is heavy, everything else is seconds of work.
exakit_component_is_heavy() {
    case "$1" in
        runtime|personal) return 0 ;;
        *) return 1 ;;
    esac
}

# The manifest records what the kit INSTALLED. These two read what is actually on
# disk, because a user can upgrade pyexasol inside its venv or drop in a different
# exapump build from GitHub — and an update check that trusted the record would
# compare against a version nobody is running, then call it current.
#
# Only these two are probed live: they are the cheap ones (a binary that prints its
# version, an interpreter that already exists) and the ones a person can most
# easily change by hand. The MCP server would cost a uvx resolution, and the
# runtime's recorded version IS the launcher the kit installed, so both stay on the
# record.

# _exakit_probe_exapump_version <binary> — "exapump 0.11.2" -> "0.11.2". Empty when
# the binary will not run (a release built against a newer glibc, for instance).
_exakit_probe_exapump_version() {
    _pev_out="$("$1" --version </dev/null 2>/dev/null | head -1)"
    [ -n "$_pev_out" ] || return 0
    printf '%s' "$_pev_out" | grep -oE '[0-9]+\.[0-9]+[0-9A-Za-z._+-]*' | head -1
}

# _exakit_probe_pyexasol_version <venv-python> — asks the driver itself.
_exakit_probe_pyexasol_version() {
    # The subshell with `&& :` is the house pattern for this probe: on a guest that
    # advertises SVE its host cannot execute, the import dies on a signal, and this
    # keeps the shell's job-status noise out of the user's output.
    _ppv_out="$( ( "$1" -c 'import pyexasol; print(pyexasol.__version__)' </dev/null && : ) 2>/dev/null | head -1 )"
    case "$_ppv_out" in
        ''|*[!A-Za-z0-9._+-]*) return 0 ;;
    esac
    printf '%s' "$_ppv_out"
}

# exakit_installed_mcp_version — the MCP server is never "installed": uvx
# materialises it per launch. What exists on the machine is the SPEC pinned into each
# AI client config, and that is what will run the next time a client connects.
#
# The adapters own where those configs live, so the paths come from the kit's own
# status operation rather than from a second copy of that knowledge here. When the
# clients disagree — one set up before an update and never refreshed — the oldest pin
# is the answer here, and the per-client picture belongs to `exakit mcp-doctor`: it
# names each client whose managed entry is no longer the one the kit would write, and
# `exakit mcp-doctor` re-writes those entries from the current definition.
exakit_installed_mcp_version() {
    command -v exakit_run_mcp_operation_cli >/dev/null 2>&1 || return 1
    exakit_can_run_python || return 1
    _imv_result="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-pins.XXXXXX")"
    if ! exakit_run_mcp_operation_cli status \
            "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" \
            "$_imv_result" >/dev/null 2>&1; then
        rm -f "$_imv_result"
        return 1
    fi
    _imv_pins="$(run_python - "$_imv_result" 2>/dev/null <<'PY'
import json, re, sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
pins = set()
for artifact in doc.get("artifacts", []) or []:
    path = artifact.get("path")
    if not path:
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
    except OSError:
        continue
    pins.update(re.findall(r"exasol-mcp-server@([0-9][0-9A-Za-z._+-]*)", body))
if not pins:
    raise SystemExit(1)


def key(v):
    return [int(p) if p.isdigit() else p for p in re.split(r"([0-9]+)", v)]


# The OLDEST pin, not the set: this value is compared against the advertised version,
# and a comma-joined list is not a version. The oldest is also the honest answer —
# it is the weakest link, the client that would launch the most outdated server.
# Which client is stale belongs to `exakit mcp-doctor`, which prints per-client state
# already. (No apostrophes in here: this heredoc sits inside a command substitution,
# and bash 3.2 mis-tracks a lone quote in that position.)
print(sorted(pins, key=key)[0])
PY
    )"
    rm -f "$_imv_result"
    [ -n "$_imv_pins" ] || return 1
    printf '%s\n' "$_imv_pins"
}

# exakit_previous_kit_repo <installing-repo> — the owner/repo of a starter kit
# already installed here that this run is moving on FROM, or empty.
#
# THIS IS AN UPGRADE, NOT A TAKEOVER. Same product, same machine, same place:
# both kits put their command at ~/.local/bin/exakit, their staged copy at
# ~/.exasol-starter-kit/kit, and their state in the same manifest. This repo is
# where the kit is developed and exasol-labs/exasol-personal-local-starterkit is
# where it is published, so a machine holding the published one is simply behind
# — and it is told that in the words of an update, not of a replacement.
#
# The repo is compared, never the ref: the same repo at another tag is the
# ordinary update and needs no line at all. A checkout: source is a local
# working tree and belongs to no repo.
exakit_previous_kit_repo() {
    _pkr_installing="${1:-}"
    [ -n "$_pkr_installing" ] || return 1
    _pkr_src="$(manifest_get kit.source 2>/dev/null || true)"
    [ -n "$_pkr_src" ] || return 1
    case "$_pkr_src" in checkout:*) return 1 ;; esac
    _pkr_repo="${_pkr_src%@*}"
    [ -n "$_pkr_repo" ] || return 1
    [ "$_pkr_repo" != "${_pkr_installing%@*}" ] || return 1
    # A RECORD IS NOT AN INSTALLATION. The manifest can outlive the kit that
    # wrote it: an uninstall that is interrupted, one that cannot reach a file,
    # or a kit whose Windows half cleans up differently, all leave kit.source
    # sitting there with nothing behind it. Announcing a takeover then is worse
    # than saying nothing - it tells a user their old kit is still installed
    # when they have just finished removing it, and they have no way to argue.
    #
    # So the record has to be corroborated: the command it installed, or the
    # kit copy it staged. Either one is proof something is still there; neither
    # means the record is a leftover and is treated as one.
    [ -x "$EXAKIT_BIN_DIR/exakit" ] || [ -d "$EXAKIT_HOME/kit" ] || return 1
    printf '%s\n' "$_pkr_repo"
}

# exakit_announce_kit_upgrade <installing-repo> — say once, before any step,
# which installation this run is updating, and what it keeps.
#
# INFO, NOT A WARNING. Nothing is wrong here and nothing is being taken over:
# it is the same product moving forward, and a red line would tell a reader
# their machine had a problem it does not have.
#
# WHAT CHANGES IS THE TOOLING. The database, its credentials and the deployment
# the launcher owns are kept: both kits deploy the same Exasol Personal, so
# there is nothing to migrate and nothing to delete. Saying so is the point —
# an update that did not promise it would leave the reader guessing.
exakit_announce_kit_upgrade() {
    _aku_repo="$(exakit_previous_kit_repo "${1:-}" 2>/dev/null || true)"
    [ -n "$_aku_repo" ] || return 0
    info "Updating the starter kit already installed here (from $_aku_repo)."
    info "The exakit command, the kit copy and the AI skills are replaced; your database, its credentials and the deployment are kept."
    manifest_set kit.updated_from "$_aku_repo" 2>/dev/null || true
}

exakit_component_current() {
    case "$1" in
        exakit)
            # kit.version is written by the installer and by self-update; the
            # kit.source parse is the fallback for installs made before that.
            _cur_kit="$(manifest_get kit.version 2>/dev/null || true)"
            if [ -n "$_cur_kit" ]; then
                printf '%s\n' "$_cur_kit"
            else
                _src="$(manifest_get kit.source 2>/dev/null || true)"
                case "$_src" in
                    *@main) exakit_kit_bundled_version 2>/dev/null || printf '%s\n' "unknown" ;;
                    *@*)    printf '%s\n' "${_src##*@}" ;;
                    *)      exakit_kit_bundled_version 2>/dev/null || printf '%s\n' "unknown" ;;
                esac
            fi
            ;;
        exapump)
            _cur_bin="$(manifest_get components.exapump.path 2>/dev/null || true)"
            [ -n "$_cur_bin" ] && [ -x "$_cur_bin" ] || _cur_bin="$(command -v exapump 2>/dev/null || true)"
            # Provably absent beats a stale record: with no binary the table says
            # "not installed" and offers the reinstall, which is the useful answer.
            [ -n "$_cur_bin" ] && [ -x "$_cur_bin" ] || return 1
            _cur_live="$(_exakit_probe_exapump_version "$_cur_bin")"
            if [ -n "$_cur_live" ]; then
                printf '%s\n' "$_cur_live"
            else
                manifest_get components.exapump.version 2>/dev/null
            fi
            ;;
        mcp)
            # What the clients are pinned to is what will actually run; the record is
            # the fallback when no client is configured or the module is absent.
            _cur_live="$(exakit_installed_mcp_version 2>/dev/null || true)"
            if [ -n "$_cur_live" ]; then
                printf '%s\n' "$_cur_live"
            else
                manifest_get components.mcp_server.version 2>/dev/null
            fi
            ;;
        pyexasol)
            _cur_python="$(manifest_get components.pyexasol.python 2>/dev/null || true)"
            [ -n "$_cur_python" ] && [ -x "$_cur_python" ] || _cur_python="$EXAKIT_HOME/pyexasol-venv/bin/python"
            [ -x "$_cur_python" ] || return 1
            _cur_live="$(_exakit_probe_pyexasol_version "$_cur_python")"
            if [ -n "$_cur_live" ]; then
                printf '%s\n' "$_cur_live"
            else
                manifest_get components.pyexasol.version 2>/dev/null
            fi
            ;;
        skills)
            # What the manifest recorded when the skills were placed. Nothing
            # recorded means the skills step never ran here (a Windows install
            # from before it recorded, a hand-edited manifest): "not installed",
            # which makes `exakit update` place them -- a repair, not a lie.
            _cur_skills="$(manifest_get components.skills.version 2>/dev/null || true)"
            [ -n "$_cur_skills" ] || return 1
            printf '%s\n' "$_cur_skills"
            ;;
        kit2)     manifest_get kit2.version 2>/dev/null ;;
        personal)
            # Only the runtime this install actually uses.
            [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "personal" ] || return 1
            exakit_installed_personal_version
            ;;
        runtime)
            exakit_installation_runtime_version
            ;;
        *)
            # Marketplace add-ons: the module's own probe is the authority
            # (<id>_installed_version asks the actual install and fails for a
            # provably absent one, so a stale manifest record can never claim
            # "installed"). Without the module, the record is all there is.
            _exakit_addon_registered "$1" || return 1
            _cur_fn="$(_exakit_addon_fn "$1" installed_version)"
            if command -v "$_cur_fn" >/dev/null 2>&1; then
                _cur_live="$("$_cur_fn" 2>/dev/null || true)"
                [ -n "$_cur_live" ] || return 1
                printf '%s\n' "$_cur_live"
                return 0
            fi
            manifest_get "components.$(printf '%s' "$1" | tr '-' '_').version" 2>/dev/null
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Marketplace add-ons
# ---------------------------------------------------------------------------
# Optional tools the kit can install but the setup scripts never do: the user
# picks them from `exakit marketplace` (a multi-select — Space toggles, Enter
# installs), and only the installed ones join the routine update flow, so
# `exakit update all` can refresh an add-on but never sneak one in.
#
# Adding a new add-on is three additive changes — NO case-statement surgery.
# Every registry function (version block, env override, fallback, upstream
# lookup, installed probe, update targets/dispatch) handles registered add-ons
# through a generic arm driven by these conventions:
#   1. Ship its module as setup/lib/<id>.sh (+ the .ps1 twin), defining
#      <id>_install, <id>_validate, <id>_update, <id>_installed_version and
#      <id>_uninstall — with dashes flipped to underscores, since a shell
#      function name cannot carry a dash — plus its own EXAKIT_<ID>_VERSION
#      and EXAKIT_<ID>_VERSION_FALLBACK constants. The uninstall hook takes a
#      dry flag ("1" narrates the plan) and is what folds the add-on into the
#      selectable `exakit uninstall` menu and the full teardown, with no
#      further wiring.
#   2. Add a components.<id> block to versions.json: version, severity, and
#      repo (GitHub-release-installed) or package (PyPI-installed) — that
#      field is what the generic upstream lookup reads.
#   3. Add one line to exakit_marketplace_addons below.
# The add-on's one-line description is NOT one of those changes: it is the
# About field of its own repository, read through
# exakit_marketplace_addon_description.
# (CI guards move with it: the expected-components set in versions.yml and the
# COUPLED fallback-constant table in versions-bump.yml.)
# ⇄ twin: Get-ExakitMarketplaceAddons and friends in setup/exakit.ps1.

# exakit_marketplace_addons — one line per add-on: "id|label".
#
# There is deliberately no description field here. A one-liner typed into this
# registry is a fourth copy of something the add-on's own repository already
# states in its About, and the copies drifted: the wording differed between the
# shell registry, the PowerShell registry and setup/help/<id>.json, and nothing
# noticed. exakit_marketplace_addon_description reads the About instead.
# EVERY LOOP OVER THIS REGISTRY READS IT ON FILE DESCRIPTOR 3, NOT STDIN.
# The row builders call into the add-on modules, and an add-on module runs
# whatever tool it is about. The VS Code CLI reads and drains the stdin it
# inherits, so with the registry on stdin it swallowed the rest of the loop's
# input and every add-on listed after exasol-vscode vanished from the menu -
# json-tables is last, so json-tables is what disappeared, silently, on any
# machine that had VS Code. Reading on fd 3 makes that class of bug
# impossible here no matter what a future add-on shells out to.
exakit_marketplace_addons() {
    printf '%s\n' "dash-server|dash-server (AI dashboard host)"
    printf '%s\n' "dbt-exasol|dbt-exasol (dbt models on Exasol)"
    printf '%s\n' "exasol-scheduler|Exasol Scheduler (SQL jobs on a schedule)"
    printf '%s\n' "exasol-vscode|Exasol for VS Code (editor extension)"
    printf '%s\n' "json-tables|JSON Tables (JSON into Exasol)"
}

# _exakit_addon_fn <id> <suffix> — the module function for an add-on.
_exakit_addon_fn() {
    printf '%s_%s\n' "$(printf '%s' "$1" | tr '-' '_')" "$2"
}

# _exakit_addon_env_var <id> <suffix> — the env/constant name for an add-on:
# dash-server VERSION_FALLBACK -> EXAKIT_DASH_SERVER_VERSION_FALLBACK.
_exakit_addon_env_var() {
    printf 'EXAKIT_%s_%s\n' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')" "$2"
}

# _exakit_addon_registered <id> — is this a marketplace add-on at all? The
# gate every generic registry arm runs first, so an unknown name still reads
# as "unknown component" everywhere.
_exakit_addon_registered() {
    case "$1" in
        ''|*[!a-z0-9-]*) return 1 ;;
    esac
    while IFS='|' read -r _ar_id _ar_label <&3; do
        [ "$_ar_id" = "$1" ] && return 0
    done 3<<EXAKIT_AR_EOF
$(exakit_marketplace_addons)
EXAKIT_AR_EOF
    return 1
}

# ---------------------------------------------------------------------------
# Add-on "About" text — fetched from the add-on's own repository, cached here
# ---------------------------------------------------------------------------
# The description the marketplace shows is the About field of the add-on's
# repository. Nothing about the wording is stored in this repository, so the
# team that owns a tool owns its one-liner, in one place, and it cannot drift
# out of sync with what we print.
#
# The cache is what makes a network-backed string safe in front of an
# interactive menu, and it is the same mechanism help.sh already uses for the
# help documents: a TTL'd file per id, an .attempt- stamp so a failure is not
# retried on every run, an atomic write, and a hard refusal to fetch over
# anything but HTTPS. Only the rows that actually SHOW a description are ever
# fetched (an installed row prints its update command instead), so a machine
# with nothing left to install makes no requests at all.

# _exakit_addon_doc <id> — the best help document for this add-on already on
# disk, and where the add-on's repository name is read from.
#
# help.sh, when loaded, also knows the fetched cache copy and validates it, so
# prefer it. But the setup scripts source only common.sh, detect.sh and the
# runtime module — and the closing offer runs from there — so this has to work
# with help.sh absent, which is why the two shipped locations are resolved here
# as well.
_exakit_addon_doc() {
    if command -v exakit_help_doc_local >/dev/null 2>&1; then
        exakit_help_doc_local "$1" 2>/dev/null && return 0
    fi
    _aad_cache="${EXAKIT_HELP_CACHE_DIR:-$EXAKIT_CACHE_DIR/help}/$1.json"
    [ -f "$_aad_cache" ] && { printf '%s\n' "$_aad_cache"; return 0; }
    _aad_root="$(exakit_repo_root 2>/dev/null || true)"
    for _aad_dir in ${_aad_root:+"$_aad_root/setup/help"} "$EXAKIT_HOME/kit/setup/help"; do
        [ -f "$_aad_dir/$1.json" ] && { printf '%s\n' "$_aad_dir/$1.json"; return 0; }
    done
    return 1
}

# _exakit_addon_doc_field <id> <field> — one top-level string from that document.
_exakit_addon_doc_field() {
    _adf_doc="$(_exakit_addon_doc "$1" 2>/dev/null)" || return 1
    [ -f "$_adf_doc" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_adf_doc" "$2" <<'EXAKIT_ADF_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except Exception:
    sys.exit(1)
value = doc.get(sys.argv[2])
if isinstance(value, str) and value.strip():
    print(value.strip())
EXAKIT_ADF_PY
        return $?
    fi
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_adf_doc" | head -1
}

# _exakit_addon_repo <id> — the add-on's repository, as owner/name.
#
# This value is interpolated into a URL, so it is validated as two plain path
# segments and nothing else. A document that says anything more interesting than
# that has no repository as far as this code is concerned.
_exakit_addon_repo() {
    _aar_repo="$(_exakit_addon_doc_field "$1" repo 2>/dev/null || true)"
    case "$_aar_repo" in
        ''|*[!A-Za-z0-9._/-]*|*/*/*|/*|*/) return 1 ;;
        */*) printf '%s\n' "$_aar_repo" ;;
        *) return 1 ;;
    esac
}

_exakit_about_cache_path() {
    printf '%s\n' "$EXAKIT_ABOUT_CACHE_DIR/$1.txt"
}

# _exakit_about_cache_fresh <file> — younger than the TTL? ⇄ twin of
# _exakit_help_cache_fresh; TTL 0 means "never trust the cache", which is what
# the tests use to force the fetch path.
_exakit_about_cache_fresh() {
    [ -f "$1" ] || return 1
    case "$EXAKIT_ABOUT_TTL" in
        ''|*[!0-9]*) return 1 ;;
        0) return 1 ;;
    esac
    _acf_mtime="$(_exakit_file_mtime "$1")"
    case "$_acf_mtime" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(( $(date +%s) - _acf_mtime ))" -lt "$EXAKIT_ABOUT_TTL" ]
}

# _exakit_about_sanitise — stdin to one printable line, filtered ON THE WAY IN.
#
# This text is free-form prose from a repository we do not control, and it is
# printed straight into the user's terminal. The help documents get their
# guarantees from a JSON schema; a bare string has none, so the filtering is
# explicit and happens once, before anything reaches the cache:
#   1. CSI sequences and OSC 8 hyperlinks are removed whole. One -e per
#      terminator, never a BRE alternation: `\|` is a GNU sed extension that
#      BSD sed (macOS, this kit's first platform) silently fails to match — the
#      trap already documented on _ui_visible_len in ui.sh.
#   2. every remaining control byte goes, the bare ESC of a half-sequence
#      included, so nothing can move the cursor, bleed colour into the rest of
#      the screen, or rewrite the line above with a carriage return.
#   3. newlines and tabs collapse to single spaces: this occupies one table
#      cell, and a second line would break the row alignment.
_exakit_about_sanitise() {
    _abs_esc="$(printf '\033')"
    _abs_bel="$(printf '\007')"
    LC_ALL=C sed \
        -e "s/${_abs_esc}\[[0-9;?]*[A-Za-z]//g" \
        -e "s/${_abs_esc}]8;;[^${_abs_bel}${_abs_esc}]*${_abs_bel}//g" \
        -e "s/${_abs_esc}]8;;[^${_abs_bel}${_abs_esc}]*${_abs_esc}\\\\//g" \
        | LC_ALL=C tr '\n\r\t' '   ' \
        | LC_ALL=C tr -d '\000-\037\177' \
        | LC_ALL=C tr -s ' ' \
        | sed -e 's/^ *//' -e 's/ *$//'
}

# _exakit_about_cap <text> — the length ceiling, trimmed back to a word boundary
# so a multi-byte character is never cut in half (a continuation byte is never
# a space).
_exakit_about_cap() {
    _abc_text="$1"
    case "$EXAKIT_ABOUT_MAX_LEN" in
        ''|*[!0-9]*) printf '%s\n' "$_abc_text"; return 0 ;;
    esac
    [ "${#_abc_text}" -le "$EXAKIT_ABOUT_MAX_LEN" ] && { printf '%s\n' "$_abc_text"; return 0; }
    _abc_text="$(printf '%s' "$_abc_text" | LC_ALL=C cut -b "1-$EXAKIT_ABOUT_MAX_LEN")"
    case "$_abc_text" in *' '*) _abc_text="${_abc_text% *}" ;; esac
    printf '%s\n' "$_abc_text"
}

# _exakit_about_extract <json> — the About field out of a repository response.
_exakit_about_extract() {
    if exakit_can_run_python; then
        printf '%s' "$1" | run_python -c 'import json,sys
try:
    print((json.load(sys.stdin).get("description") or "").strip())
except Exception:
    pass' 2>/dev/null
        return 0
    fi
    printf '%s' "$1" | sed -n 's/.*"description"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# _exakit_about_fetch <id> — refresh one add-on's cached About line.
# 0 = a line was cached, 2 = the fetch was skipped as unnecessary, 1 = nothing
# was cached (and the caller falls back; it never fails a screen).
_exakit_about_fetch() {
    _abf_id="$1"
    [ "$EXAKIT_ABOUT_OFFLINE" = "1" ] && return 1
    case "$EXAKIT_ABOUT_URL" in
        https://*) ;;
        *) _exakit_log_file "WARN  refusing to fetch an add-on About over a non-HTTPS URL"; return 1 ;;
    esac
    _abf_repo="$(_exakit_addon_repo "$_abf_id" 2>/dev/null || true)"
    [ -n "$_abf_repo" ] || return 1
    _abf_cache="$(_exakit_about_cache_path "$_abf_id")"
    _abf_attempt="$EXAKIT_ABOUT_CACHE_DIR/.attempt-$_abf_id"
    _exakit_about_cache_fresh "$_abf_cache" && return 2
    # The stamp is what keeps a rate-limited or offline machine from asking
    # again on every single run: it is written BEFORE the request, so the
    # question counts as asked whatever the answer turns out to be.
    _exakit_about_cache_fresh "$_abf_attempt" && return 2
    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$EXAKIT_ABOUT_CACHE_DIR" 2>/dev/null || return 1
    : > "$_abf_attempt" 2>/dev/null || true
    _abf_json="$(curl -fsSL --proto '=https' --retry 1 \
        --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" \
        --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        -A "$(exakit_versions_user_agent 2>/dev/null || true)" \
        "$EXAKIT_ABOUT_URL/$_abf_repo" 2>/dev/null || true)"
    if [ -z "$_abf_json" ]; then
        _exakit_log_file "INFO  About fetch failed for $_abf_id — keeping whatever is on disk"
        return 1
    fi
    _abf_text="$(_exakit_about_cap "$(_exakit_about_extract "$_abf_json" | _exakit_about_sanitise)")"
    if [ -z "$_abf_text" ]; then
        _exakit_log_file "INFO  $_abf_repo has no About text to show for $_abf_id"
        return 1
    fi
    _abf_tmp="$_abf_cache.tmp.$$"
    printf '%s\n' "$_abf_text" > "$_abf_tmp" 2>/dev/null || { rm -f "$_abf_tmp"; return 1; }
    mv -f "$_abf_tmp" "$_abf_cache" 2>/dev/null || { rm -f "$_abf_tmp"; return 1; }
    _exakit_log_file "INFO  About refreshed for $_abf_id from $_abf_repo"
    return 0
}

# exakit_marketplace_addon_description <id> — the one-liner a screen shows.
# Always answers something; the chain degrades instead of blanking a column:
#   1. a cached About younger than the TTL     — the common case, no network
#   2. a fresh fetch                           — one request, timeouts bounded
#   3. a STALE cached About, any age           — old wording beats no wording
#   4. the help document's own tagline         — on disk, so this is the answer
#                                                offline and when rate-limited
#   5. a pointer at the help screen            — only if even that is missing
exakit_marketplace_addon_description() {
    _mad_cache="$(_exakit_about_cache_path "$1")"
    _exakit_about_cache_fresh "$_mad_cache" || _exakit_about_fetch "$1" >/dev/null 2>&1 || true
    if [ -f "$_mad_cache" ]; then
        _mad_text="$(head -1 "$_mad_cache" 2>/dev/null || true)"
        if [ -n "$_mad_text" ]; then
            printf '%s\n' "$_mad_text"
            return 0
        fi
    fi
    _mad_text="$(_exakit_addon_doc_field "$1" tagline 2>/dev/null || true)"
    if [ -n "$_mad_text" ]; then
        # A tagline is written as a help-screen header and ends in a period; a
        # table cell does not.
        printf '%s\n' "${_mad_text%.}"
        return 0
    fi
    printf 'Details: exakit help %s\n' "$1"
}

# exakit_about_wrap <text> [width] [continuation-indent] — the text in full,
# folded onto as many lines as it needs.
#
# This is the table's renderer: an About is written for a repository page, not
# for a 44-column cell, and truncating it threw away the half that explained
# what the tool was for. Continuation lines carry their own indent (they are
# printed through the same '  %s\n' as the first line), so the Description
# column stays a column.
#
# Word-wrapped, never mid-word: a word longer than the width is emitted on a
# line of its own and allowed to overhang rather than being broken.
exakit_about_wrap() {
    _abw_text="$1"
    _abw_w="${2:-$EXAKIT_ABOUT_WIDTH}"
    _abw_pad="${3:-}"
    case "$_abw_w" in
        ''|*[!0-9]*) printf '%s\n' "$_abw_text"; return 0 ;;
    esac
    [ "$_abw_w" -lt 8 ] && { printf '%s\n' "$_abw_text"; return 0; }
    _abw_line=""
    _abw_first=1
    # Unquoted on purpose: the value was sanitised to single-space-separated
    # words on its way into the cache, so this is the word list.
    for _abw_word in $_abw_text; do
        if [ -z "$_abw_line" ]; then
            _abw_line="$_abw_word"
        elif [ "$(( ${#_abw_line} + 1 + ${#_abw_word} ))" -le "$_abw_w" ]; then
            _abw_line="$_abw_line $_abw_word"
        else
            if [ "$_abw_first" = 1 ]; then
                printf '%s\n' "$_abw_line"
                _abw_first=0
            else
                printf '%s%s\n' "$_abw_pad" "$_abw_line"
            fi
            _abw_line="$_abw_word"
        fi
    done
    [ -n "$_abw_line" ] || return 0
    if [ "$_abw_first" = 1 ]; then
        printf '%s\n' "$_abw_line"
    else
        printf '%s%s\n' "$_abw_pad" "$_abw_line"
    fi
}

# _exakit_marketplace_warm_about — fill the cache for the rows that will show a
# description, before a screen is drawn.
#
# This exists for the closing offer: it runs its gate question ("Browse it
# now?") before the table exists, so the requests land while the user is reading
# two sentences of prose rather than in front of a half-drawn table.
_exakit_marketplace_warm_about() {
    while read -r _mw_id <&3; do
        [ -n "$_mw_id" ] || continue
        _exakit_addon_offerable "$_mw_id" || continue
        _exakit_marketplace_addon_present "$_mw_id" && continue
        exakit_marketplace_addon_available "$_mw_id" || continue
        _exakit_about_fetch "$_mw_id" >/dev/null 2>&1 || true
    done 3<<EXAKIT_MW_EOF
$(exakit_marketplace_addons | cut -d'|' -f1)
EXAKIT_MW_EOF
    return 0
}

# exakit_marketplace_addon_available <id> — is the add-on's module loaded in
# this process? (An old kit copy that predates the add-on simply lacks the
# module file; the menu shows the row as unavailable instead of failing.)
exakit_marketplace_addon_available() {
    command -v "$(_exakit_addon_fn "$1" install)" >/dev/null 2>&1
}

# _exakit_marketplace_load_modules — source any add-on module that is not
# loaded yet. The setup scripts deliberately do not source the modules (the
# marketplace is not part of the install flow), so the closing offer and the
# menu load them here on demand. A module that fails to load only makes its
# own row unavailable.
_exakit_marketplace_load_modules() {
    # The sourcing must happen in THIS shell so the loaded functions stick —
    # ids are collected via command substitution, never through a pipeline
    # (whose stages are subshells).
    _ml_root="$(exakit_repo_root 2>/dev/null || true)"
    _ml_ids="$(exakit_marketplace_addons | cut -d'|' -f1)"
    for _ml_id in $_ml_ids; do
        exakit_marketplace_addon_available "$_ml_id" && continue
        for _ml_dir in ${_ml_root:+"$_ml_root/setup/lib"} "$EXAKIT_HOME/kit/setup/lib"; do
            if [ -f "$_ml_dir/$_ml_id.sh" ]; then
                . "$_ml_dir/$_ml_id.sh" 2>/dev/null || \
                    warn "The $_ml_id module could not be loaded from $_ml_dir (corrupted kit copy?)"
                break
            fi
        done
    done
    return 0
}

# _exakit_addon_applicable <id> — does this add-on make sense on THIS machine
# at all? An add-on that extends something the user does not have (the VS Code
# extension without VS Code) is not "available then failing" — it is simply not
# on offer, and nothing advertises it. A module with no opinion is applicable.
_exakit_addon_applicable() {
    _aa_fn="$(_exakit_addon_fn "$1" applicable)"
    command -v "$_aa_fn" >/dev/null 2>&1 || return 0
    # The probe belongs to the add-on module and can do real work: shell out to
    # a code CLI, inspect the platform, read a path. Run it in a subshell so a
    # probe that dies takes its own answer down and nothing else — `exakit
    # version` listed only INSTALLED add-ons before, so no caller had ever run
    # this for an absent one. "Cannot tell" means do not offer it.
    ( "$_aa_fn" ) 2>/dev/null
}

# _exakit_addon_applicable_reason <id> — the one line that explains why it is
# not on offer, when the module cares to say.
_exakit_addon_applicable_reason() {
    _ar_fn="$(_exakit_addon_fn "$1" applicable_reason)"
    command -v "$_ar_fn" >/dev/null 2>&1 && "$_ar_fn"
    return 0
}

# _exakit_addon_offerable <id> — should this add-on appear at all? Only an
# add-on that is BOTH absent and inapplicable is hidden. Anything actually on
# the machine stays visible: a kit install so it can still be updated or
# removed (even if the host app disappeared afterwards), and a system install
# so the screen can say it is already covered rather than silently omitting a
# tool the user can see for themselves.
_exakit_addon_offerable() {
    _exakit_marketplace_addon_present "$1" && return 0
    _exakit_addon_applicable "$1"
}

# exakit_marketplace_addon_installed <id> — KIT-MANAGED install only: the
# component answers for itself (exakit_component_current probes the actual
# install and fails for a provably absent one, so a stale manifest record
# cannot say "installed"). This is what gates the update flow — the kit only
# ever updates what it manages.
exakit_marketplace_addon_installed() {
    exakit_component_current "$1" >/dev/null 2>&1
}

# _exakit_addon_system_present <id> — is the tool already on this machine
# OUTSIDE the kit? A same-named binary on PATH that is not the kit's own
# launcher counts; a module may sharpen the answer with <id>_system_present.
# The kit never offers, updates or uninstalls such an install — it only stops
# advertising a tool the user already has.
_exakit_addon_system_present() {
    _sp_fn="$(_exakit_addon_fn "$1" system_present)"
    if command -v "$_sp_fn" >/dev/null 2>&1; then
        "$_sp_fn"
        return $?
    fi
    # The command to look for: the id, plus whatever the module named its
    # launcher in EXAKIT_<ID>_BIN. The two differ often enough (json-tables
    # installs `exasol-json-tables`) that keying on the id alone would miss a
    # manual install and offer the user a tool they already have.
    _sp_bin_var="$(_exakit_addon_env_var "$1" BIN)"
    eval "_sp_bin=\${$_sp_bin_var:-}"
    _sp_names="$1"
    if [ -n "$_sp_bin" ]; then
        _sp_base="${_sp_bin##*/}"
        [ "$_sp_base" = "$1" ] || _sp_names="$_sp_names $_sp_base"
    fi
    for _sp_name in $_sp_names; do
        _sp_path="$(command -v "$_sp_name" 2>/dev/null || true)"
        [ -n "$_sp_path" ] || continue
        # The kit's own launcher on PATH is a kit install, not a system one.
        [ "$_sp_path" = "$EXAKIT_BIN_DIR/$_sp_name" ] && continue
        [ "$_sp_path" -ef "$EXAKIT_BIN_DIR/$_sp_name" ] 2>/dev/null && continue
        return 0
    done
    return 1
}

# _exakit_marketplace_addon_present <id> — installed by the kit OR already on
# the system. "Present" is what the offer, the menu and the discovery lines
# key on: a tool the user has, from anywhere, is never advertised.
_exakit_marketplace_addon_present() {
    exakit_marketplace_addon_installed "$1" && return 0
    _exakit_addon_system_present "$1"
}

# exakit_marketplace_installed_addons — ids of the add-ons present on this
# machine. This is what folds them into `exakit update all` / `exakit version`.
exakit_marketplace_installed_addons() {
    while IFS='|' read -r _ma_id _ma_label <&3; do
        [ -n "$_ma_id" ] || continue
        exakit_marketplace_addon_installed "$_ma_id" && printf '%s\n' "$_ma_id"
    done 3<<EXAKIT_MA_EOF
$(exakit_marketplace_addons)
EXAKIT_MA_EOF
    return 0
}

# exakit_marketplace_has_pending — true while at least one add-on is not on
# this machine yet (neither kit-managed nor a system install). Drives the
# discovery one-liners and the closing offer.
exakit_marketplace_has_pending() {
    [ -n "$(while IFS='|' read -r _mp_id _mp_label <&3; do
        [ -n "$_mp_id" ] || continue
        _exakit_addon_offerable "$_mp_id" || continue
        _exakit_marketplace_addon_present "$_mp_id" || printf '%s\n' "$_mp_id"
    done 3<<EXAKIT_MP_EOF
$(exakit_marketplace_addons)
EXAKIT_MP_EOF
)" ]
}

# --- the add-ons table --------------------------------------------------------
# The SELECTION and the install progress are ONE table -- the same component the
# dataset load uses (ui_table_* in ui.sh) -- so the rows a reader ticks are the
# rows whose Status column then fills in, and nothing has to be mapped from one
# screen onto another. What lives here is which rows there are and what their
# Status column says.
#
# Every row's state lives in a FILE because the animator that draws it is a
# background subshell: it can read a file and could never read a variable this
# shell set.

EXAKIT_ADDON_TABLE_STATE=""
EXAKIT_ADDON_TABLE_LIVE=0
EXAKIT_ADDON_TABLE_IDS=""
EXAKIT_ADDON_TABLE_ROW=""
EXAKIT_ADDON_TABLE_ROW_SKIP=0
# Said once the table has stopped redrawing — see _exakit_addon_note.
EXAKIT_ADDON_NOTES=""

# _exakit_addon_table_live — is a table painting this install? True means the
# one-line progress bar must keep its hands off the UI layer's single animation
# slot; the table owns it.
# _exakit_addon_table_live — the live add-on TABLE is on screen and redrawing.
# (It was called _exakit_addon_bar_live, which is what it never tested: with a
# real bar flag beside it now, that name was a trap.)
_exakit_addon_table_live() {
    [ "${EXAKIT_ADDON_TABLE_LIVE:-0}" = 1 ]
}

# _exakit_addon_narration_live — true while EITHER narration owns the screen:
# the live table, or the one-line bar it falls back to.
#
# The bar counted for nothing before, and a note printed beside one that is
# still being redrawn runs off the right edge, wraps, and pushes the bar to a
# new line - so one add-on's single bar comes out as three broken rows. The
# table path had been thought about; the fallback had not. Twin of
# Test-ExakitAddonNarrationLive.
_exakit_addon_narration_live() {
    _exakit_addon_table_live || [ "${EXAKIT_ADDON_BAR_LIVE:-0}" = 1 ]
}

# _exakit_addon_note <info|warn> <text> — something the reader must see, said
# AFTER the table has stopped. A line printed into a frame that is still being
# repainted lands INSIDE the box, so while the table is live nothing speaks
# except the table. With no table it is said where it stands, exactly as before.
_exakit_addon_note() {
    if _exakit_addon_narration_live; then
        EXAKIT_ADDON_NOTES="${EXAKIT_ADDON_NOTES}$1|$2
"
        return 0
    fi
    case "$1" in
        warn) warn "$2" ;;
        *)    info "$2" ;;
    esac
}

# _exakit_addon_notes_say — drain the collected notes, now that the table is off
# the screen and a line can be read where it is printed.
_exakit_addon_notes_say() {
    while IFS='|' read -r _ans_kind _ans_text; do
        [ -n "$_ans_text" ] || continue
        case "$_ans_kind" in
            warn) warn "$_ans_text" ;;
            *)    info "$_ans_text" ;;
        esac
    done <<EXAKIT_ADDON_NOTES_EOF
$EXAKIT_ADDON_NOTES
EXAKIT_ADDON_NOTES_EOF
    EXAKIT_ADDON_NOTES=""
}

# _exakit_addon_table_build <state-file> <id> [id ...] — the rows, in the order
# they are drawn: the group row, one row per installable add-on hanging off a
# tree connector, and the exclusive Skip. Sets EXAKIT_TABLE_DEFAULTS / _GROUP /
# _EXCLUSIVE the way ui_table_menu expects, and EXAKIT_ADDON_TABLE_IDS to the
# add-on id per row (empty for the rows that are not add-ons) so the installer
# can find a row again.
#
# Only INSTALLABLE add-ons get a row. An add-on that is already present, or
# whose module did not ship in this kit copy, is answered by the state table
# above with its own version and status, and a checkbox that cannot be ticked
# would be the same fact twice — the data-load table leaves already-loaded
# datasets out for exactly that reason. This is also what keeps the group's
# child range contiguous.
_exakit_addon_table_build() {
    _atb_f="$1"; shift
    : > "$_atb_f"
    _atb_n=$#
    printf 'group|Select All|1|idle|||||| \n' >> "$_atb_f"
    # Via a newline-separated STRING, one line per row, so a row that is not an
    # add-on is an EMPTY line rather than a gap a space-separated list would
    # close up — the row number is the index, and it has to stay one.
    EXAKIT_ADDON_TABLE_IDS="
"
    # How many unpickable rows follow, counted BEFORE the loop: the corner
    # connector belongs to the last row of the tree, and when a disabled row
    # comes after the installable ones the corner is not the last installable.
    # Drawn the other way the tree closed early and then kept going.
    _atb_dn=0
    while IFS='|' read -r _atb_cid _atb_cwhy _atb_cver; do
        [ -n "$_atb_cid" ] || continue
        _atb_dn=$(( _atb_dn + 1 ))
    done <<EXAKIT_ATB_COUNT
${EXAKIT_ADDON_TABLE_DISABLED:-}
EXAKIT_ATB_COUNT
    _atb_i=0
    for _atb_id in "$@"; do
        _atb_i=$(( _atb_i + 1 ))
        if [ "$_atb_i" -eq "$_atb_n" ] && [ "$_atb_dn" -eq 0 ]; then
            _atb_kind=corner
        else
            _atb_kind=tee
        fi
        # Fields 11 and 12: the Version and Description columns, PASSED IN
        # through EXAKIT_ADDON_TABLE_META rather than looked up here.
        #
        # Resolving them inside this function put a version probe and a GitHub
        # About fetch behind every caller of it -- including the pty scenario
        # that drives this table with three ids that are not add-ons at all, and
        # which is not a place for network I/O. The caller iterating the add-ons
        # already has both values; it hands them over. Missing metadata leaves
        # the cells empty, which is what a table with no such columns wants.
        _atb_ver=""; _atb_desc=""
        while IFS='|' read -r _atb_mid _atb_mver _atb_mdesc; do
            [ "$_atb_mid" = "$_atb_id" ] || continue
            _atb_ver="$_atb_mver"; _atb_desc="$_atb_mdesc"; break
        done <<EXAKIT_ATB_META
${EXAKIT_ADDON_TABLE_META:-}
EXAKIT_ATB_META
        printf '%s|%s|1|idle|||||| |%s|%s\n' "$_atb_kind" "$_atb_id" \
            "$_atb_ver" "$_atb_desc" >> "$_atb_f"
        EXAKIT_ADDON_TABLE_IDS="$EXAKIT_ADDON_TABLE_IDS$_atb_id
"
    done
    # The add-ons that cannot be installed, AFTER the installable ones so the
    # group's child range stays contiguous, and unpickable so a checkbox never
    # offers what cannot be chosen. Each carries why. An empty id line keeps the
    # row-number-to-id mapping intact: the index IS the row.
    _atb_d=0
    while IFS='|' read -r _atb_did _atb_dwhy _atb_dver; do
        [ -n "$_atb_did" ] || continue
        _atb_d=$(( _atb_d + 1 ))
        if [ "$_atb_d" -eq "$_atb_dn" ]; then _atb_dkind=corner; else _atb_dkind=tee; fi
        # The state word goes to BOTH the status cell (field 10) and the
        # Description column (field 12): the selection screen has Description
        # and no Status, the install screen has Status and no Description, and
        # the row should say the same thing on either.
        printf '%s|%s|0|disabled|||||%s|%s|%s|%s\n' \
            "$_atb_dkind" "$_atb_did" "" "$_atb_dwhy" "$_atb_dver" "$_atb_dwhy" >> "$_atb_f"
        EXAKIT_ADDON_TABLE_IDS="$EXAKIT_ADDON_TABLE_IDS
"
    done <<EXAKIT_ATB_DISABLED
${EXAKIT_ADDON_TABLE_DISABLED:-}
EXAKIT_ATB_DISABLED
    printf 'plain|Skip|0|idle|||||| \n' >> "$_atb_f"
    EXAKIT_ADDON_TABLE_IDS="$EXAKIT_ADDON_TABLE_IDS
"
    EXAKIT_ADDON_TABLE_ROW_SKIP=$(( _atb_n + _atb_d + 2 ))
    EXAKIT_TABLE_EXCLUSIVE="$EXAKIT_ADDON_TABLE_ROW_SKIP"
    # "all": the parent is a master toggle, checked only while EVERY child is.
    # Under the default "any" it stayed checked with one child ticked, so the
    # summary row read "everything is selected" when it was not — on the row a
    # user glances at to confirm what is about to be installed.
    EXAKIT_TABLE_GROUP="1:2:$(( _atb_n + 1 )):all"
    # The group AND every add-on pre-selected, so Enter alone installs what is
    # on offer and Skip is the explicit opt-out. Mirrors exakit_data_load_select.
    EXAKIT_TABLE_DEFAULTS=""
    _atb_i=1
    while [ "$_atb_i" -le $(( _atb_n + 1 )) ]; do
        EXAKIT_TABLE_DEFAULTS="${EXAKIT_TABLE_DEFAULTS:+$EXAKIT_TABLE_DEFAULTS,}$_atb_i"
        _atb_i=$(( _atb_i + 1 ))
    done
    # Every row here can be checked, and saying so is not optional:
    # _UI_CHECKBOX_SELECTABLE is published by ui_checkbox_menu and never cleared,
    # so the offer's two-row "Explore ?" question leaves "1 2" behind — and the
    # group helpers would then treat row 2 as the only child, making Select All
    # toggle the first add-on and nothing else. Empty means "every row".
    _UI_CHECKBOX_SELECTABLE=""
    return 0
}

# _exakit_addon_table_row <id> — which row that add-on is on, or 0.
_exakit_addon_table_row() {
    _atr_i=0
    while IFS= read -r _atr_id; do
        _atr_i=$(( _atr_i + 1 ))
        [ "$_atr_id" = "$1" ] && { printf '%s\n' "$_atr_i"; return 0; }
    done <<EXAKIT_ATR_EOF
$EXAKIT_ADDON_TABLE_IDS
EXAKIT_ATR_EOF
    printf '0\n'
}

# _exakit_addon_table_cell <summary> <seconds> — the Status column for a
# finished add-on. The tick in front of it already says "installed", so the cell
# carries the add-on's own one fact instead ("dashboards at
# http://127.0.0.1:8000"), with the elapsed time padded to a fixed width so the
# times line up down the table rather than wandering with the length of the text
# in front of them.
#
# Truncated to the column rather than allowed to widen it: ui_table_widths sizes
# the Status column from the widest FINISHED status and only ever gives ground
# from the name column, so a sixty-character summary pushes the table past an
# 80-column terminal — and a row that wraps is two terminal lines the frame
# counted as one, which is how a table starts stacking on every redraw. The full
# text is in the logfile either way.
_exakit_addon_table_cell() {
    _atc_el="$(printf '%5s' "(${2}s)")"
    _atc_text="${1:-installed}"
    # The room is what is left of the column's FLOOR after the tick glyph and
    # its space, the space before the elapsed time, and the time itself: the
    # cell _ui_table_cell builds is "<tick> <final>", and a final that overruns
    # the column makes ui_table_frame's padding arithmetic go negative — which
    # is a bash substring error printed over the table, not a wider column.
    _atc_tick="${UI_TICK:-[ok]}"
    _atc_room=$(( ${UI_TABLE_STAT_MIN:-44} - ${#_atc_tick} - ${#_atc_el} - 2 ))
    [ "${#_atc_text}" -le "$_atc_room" ] || \
        _atc_text="${_atc_text:0:$(( _atc_room - 1 ))}…"
    # Padded to the room, not merely fitted into it: the summaries are all
    # different lengths, so an unpadded cell puts each row's elapsed time at a
    # different column and the eye has nothing to run down.
    printf "%-${_atc_room}s %s\n" "$_atc_text" "$_atc_el"
}

# _exakit_addon_table_cleanup — the state file and the animator's scratch files
# go together with the table. Called on every path out of the selection, so a
# cancelled marketplace leaves nothing in TMPDIR.
_exakit_addon_table_cleanup() {
    [ -n "$EXAKIT_ADDON_TABLE_STATE" ] || return 0
    rm -f "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_ADDON_TABLE_STATE.new" \
          "$EXAKIT_ADDON_TABLE_STATE.lines" "$EXAKIT_ADDON_TABLE_STATE.stop"
    EXAKIT_ADDON_TABLE_STATE=""
    return 0
}

# _exakit_marketplace_install_one <id> — install + validate one add-on. The
# validate half must not fail the install (same contract as the setup steps):
# a component that installed but could not be validated explains itself and is
# retried by `exakit update <id>`.
_exakit_marketplace_install_one() {
    _mi_install="$(_exakit_addon_fn "$1" install)"
    _mi_validate="$(_exakit_addon_fn "$1" validate)"
    command -v "$_mi_install" >/dev/null 2>&1 || {
        _exakit_addon_note warn "The $1 module is not part of this kit copy — update the kit first: exakit update"
        return 1
    }
    # Every silent stretch of an add-on install — creating the venv, resolving
    # and installing from PyPI, downloading an extension — already animates,
    # because run_logged and fetch start the spinner. What they did NOT have was
    # a truthful label: EXAKIT_ACTIVE_LABEL is set by begin_step, and add-ons are
    # installed after the last numbered step (or from `exakit marketplace`, with
    # no step at all), so a two-minute install animated under the previous step's
    # title, or under the bare word "working". Name what is actually running.
    # Twin of the same block in Invoke-ExakitMarketplaceApply (exakit-common.ps1).
    _mi_prev_label="${EXAKIT_ACTIVE_LABEL:-}"
    _mi_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    # Installing three add-ons printed fifty lines: a venv, a pip resolve, a
    # download, a checksum, a launcher, a package-data repair and a validation
    # probe, each announcing itself twice. None of it is something the person
    # who ticked three boxes can act on, and all of it is in the logfile.
    #
    # EXAKIT_QUIET_DETAIL routes it there; the progress line below is the
    # narration, carried by the spinner run_logged and fetch already start (so
    # the bar, the percentage, the phase and the animation are ONE line). The
    # percentages are milestone positions weighted by where the TIME goes -
    # fetching and installing is nearly all of it - not a step count.
    EXAKIT_QUIET_DETAIL=1
    _mi_state="$(mktemp "${TMPDIR:-/tmp}/exakit-addon.XXXXXX")" || _mi_state=""
    _mi_t0="$(date +%s 2>/dev/null || echo 0)"
    if [ -n "$_mi_state" ]; then
        _exakit_addon_progress "$_mi_state" "$1" 0 65 40 "installing"
        # The TABLE is already painting this add-on's row, and it holds the UI
        # layer's single animation slot. A second painter here would fight it for
        # the cursor, and the ui_progress_end below would kill the TABLE's
        # animator instead of a bar of its own -- mid-frame, which leaves half a
        # table on screen with the finished one printed under it.
        _exakit_addon_table_live || { ui_progress_begin "$_mi_state" "$_mi_t0" || true; EXAKIT_ADDON_BAR_LIVE=1; }
    fi
    "$_mi_install"
    _mi_rc=$?
    if [ "$_mi_rc" -ne 0 ]; then
        _exakit_addon_table_live || { ui_progress_end; EXAKIT_ADDON_BAR_LIVE=0; }
        [ -n "$_mi_state" ] && rm -f "$_mi_state"
        EXAKIT_QUIET_DETAIL="$_mi_prev_quiet"
        EXAKIT_ACTIVE_LABEL="$_mi_prev_label"
        return 1
    fi
    if command -v "$_mi_validate" >/dev/null 2>&1; then
        [ -n "$_mi_state" ] && _exakit_addon_progress "$_mi_state" "$1" 65 90 8 "validating"
        "$_mi_validate" || true
    fi
    # The add-on's own skills, placed now rather than at the AI-bridge step.
    # Generic on purpose: this reads the owner out of each SKILL.md, so a future
    # add-on ships its skill by declaring "addon: <id>" in the frontmatter and
    # nothing here learns its name.
    exakit_install_addon_skills "$1" || true
    # A service add-on joins the boot set the moment it is installed, so the
    # user does not have to remember a second command after saying yes. On
    # macOS loading the agent also starts it, so it is usable right away.
    if [ "$(manifest_get autostart.enabled 2>/dev/null || true)" = "true" ] && \
       command -v "$(_exakit_addon_fn "$1" autostart_command)" >/dev/null 2>&1; then
        _exakit_autostart_register "$1" || true
    fi
    # ...and it is STARTED now. Registering for boot is not the same as running:
    # on Linux and Windows nothing starts until the next login, so `exakit
    # status` reported the add-on the user had just installed as "stopped".
    # Best-effort, and only for an add-on that declares a start hook.
    _mi_start="$(_exakit_addon_fn "$1" start)"
    if command -v "$_mi_start" >/dev/null 2>&1; then
        [ -n "$_mi_state" ] && _exakit_addon_progress "$_mi_state" "$1" 90 100 3 "starting"
        "$_mi_start" >/dev/null 2>&1 || \
            _exakit_addon_note warn "$1 installed but did not start — start it with: exakit start"
    fi
    _exakit_addon_table_live || { ui_progress_end; EXAKIT_ADDON_BAR_LIVE=0; }
    [ -n "$_mi_state" ] && rm -f "$_mi_state"
    EXAKIT_QUIET_DETAIL="$_mi_prev_quiet"
    EXAKIT_ACTIVE_LABEL="$_mi_prev_label"
    return 0
}

# _exakit_addon_progress <state-file> <id> <pct> <ceiling> <seconds> <phase> —
# the add-on install has reached a new stage.
#
# The percentages are milestone positions weighted by where the TIME goes:
# fetching and installing is nearly all of it, validating a little, starting
# almost none. The seconds are what the creep fills the gaps with, and it is
# capped below the next stage, so a slow PyPI resolve makes the bar wait rather
# than walk into "validating".
# ⇄ twin: Set-ExakitAddonProgress in exakit-common.ps1.
_exakit_addon_progress() {
    # An add-on being installed from the TABLE reports into its ROW; the row
    # already names it, so the "<id> · " prefix the one-line bar needs would be
    # the same fact twice, in a cell that has to spell a phase in a fixed width.
    if [ -n "${EXAKIT_ADDON_TABLE_ROW:-}" ] && [ -n "${EXAKIT_ADDON_TABLE_STATE:-}" ]; then
        ui_table_set "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_ADDON_TABLE_ROW" running \
            "$3" "$4" "$5" "$6"
        return 0
    fi
    ui_progress_state "$1" "$3" "$4" "$5" "$2 · $6"
}

# exakit_marketplace_menu — the `exakit marketplace` command body, wearing the
# kit's two established looks so nothing here reads foreign:
#   1. the STATE, as the same aligned table `exakit version` prints
#      (Add-on / Status / Version / Action, one row per add-on, whatever its
#      state — installed, on the system, missing module, or available);
#   2. the SELECTION, as the same live table the data-load menu uses: a group
#      row with the add-ons hanging off UI_TEE/UI_CORNER connectors, Space
#      toggles, Enter installs, Skip as the exclusive default — and the Status
#      column of those very rows is what the install then fills in.
# Only installable add-ons become menu rows — everything else is answered by
# the table, exactly like already-loaded datasets are not re-offered.
#
# Non-interactive runs answer with EXAKIT_MARKETPLACE_ADDONS: a csv of add-on
# ids, "all", or "none" — same contract as EXAKIT_MCP_CLIENTS / EXAKIT_DATASETS.
exakit_marketplace_menu() {
    _mm_ids=()
    _mm_selectable=0
    # One "<id>|<why>" per add-on that cannot be installed. The reference panel
    # used to carry these; deleting it took the answer to "why is this one not
    # on offer?" with it, and on the all-covered path took the ONLY output that
    # path produced. They come back as dim, unpickable rows inside the one
    # table -- the way the MCP client list shows "Cursor · not installed" --
    # and as plain lines when there is no table to put them in.
    _mm_covered=""
    # "<id>|<version>|<description>" for each installable add-on, handed to the
    # row builder so it never has to look either up itself.
    _mm_meta=""
    while IFS='|' read -r _mm_id _mm_label <&3; do
        [ -n "$_mm_id" ] || continue
        # Not applicable here and not installed: it is not an option on this
        # machine, so it is not shown at all — no row, no table line.
        _exakit_addon_offerable "$_mm_id" || continue
        # Every add-on gets a STATE row; only an installable one also gets a
        # selection row. A state that cannot be installed is answered by the
        # "__disabled__" keeps the row in _mm_ids so the env answer can still
        # tell a real add-on it names from an unknown one, and so the row
        # numbering the selection is built from stays intact. It carries no
        # text of its own any more: the reference panel that used to print a
        # version and a reason for each of these is gone (see below), and the
        # selection only ever listed installable add-ons.
        if exakit_marketplace_addon_installed "$_mm_id"; then
            # "Installed" and the version travel SEPARATELY now: the version
            # belongs in the Version column beside every other add-on's, and the
            # word belongs wherever the table puts a state -- Description on the
            # selection screen, Status while installing. Bundling them into the
            # name read as "json-tables · Installed (0.2)" with the Version
            # column empty right next to it.
            _mm_cv="$(exakit_component_current "$_mm_id" 2>/dev/null || true)"
            _mm_covered="$_mm_covered$_mm_id|Installed|$(exakit_version_plain "${_mm_cv:-?}")
"
            _mm_ids+=("__disabled__")
        elif _exakit_addon_system_present "$_mm_id"; then
            # The user already has the tool from somewhere else: covered, and
            # the kit does not manage it.
            _mm_covered="$_mm_covered$_mm_id|managed outside the kit|
"
            _mm_ids+=("__disabled__")
        elif ! exakit_marketplace_addon_available "$_mm_id"; then
            _mm_covered="$_mm_covered$_mm_id|not in this kit copy|
"
            _mm_ids+=("__disabled__")
        else
            # The version and the description travel to the table from here,
            # where the loop is already visiting every add-on. Resolved ONLY on
            # the path that draws them: a scripted EXAKIT_MARKETPLACE_ADDONS
            # answer never builds a table, so it still never pays for the About
            # lookup -- and neither does anything else that builds a table
            # without asking for these columns.
            if [ -z "${EXAKIT_MARKETPLACE_ADDONS:-}" ]; then
                _mm_mdesc="$(exakit_marketplace_addon_description "$_mm_id" 2>/dev/null || true)"
                # One line for the RECORD, not for the screen: a newline here
                # would end the row's line in the state file. The table re-flows
                # it across as many lines as it needs at draw time -- see
                # _ui_wrap -- in full and without an ellipsis.
                # The advertised version. Read from the versions MANIFEST, not
                # over the network: exakit_component_available only reaches out
                # under EXAKIT_VERSION_POLICY=latest, so this costs nothing that
                # the description lookup on the line above has not already paid.
                #
                # This assignment went missing when the lookup was moved out of
                # the row builder: the expansion below kept its :-unknown
                # fallback, so it read a variable nothing set and every add-on
                # advertised "unknown" instead of a version.
                _mm_adv="$(exakit_component_available "$_mm_id" 2>/dev/null || printf 'unknown')"
                _mm_meta="$_mm_meta$_mm_id|$(exakit_version_plain "${_mm_adv:-unknown}")|$(printf '%s' "$_mm_mdesc" | tr '\n' ' ')
"
            fi
            _mm_ids+=("$_mm_id")
            _mm_selectable=$((_mm_selectable + 1))
        fi
    done 3<<EXAKIT_MM_EOF
$(exakit_marketplace_addons)
EXAKIT_MM_EOF

    # The env answer wins over any menu, so agents and CI never need a TTY.
    if [ -n "${EXAKIT_MARKETPLACE_ADDONS:-}" ]; then
        _mm_answer="$(printf '%s' "$EXAKIT_MARKETPLACE_ADDONS" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
        _mm_picked=""
        case "$_mm_answer" in
            none) info "EXAKIT_MARKETPLACE_ADDONS=none — installing nothing."; return 0 ;;
            all)
                _mm_i=0
                while [ "$_mm_i" -lt "${#_mm_ids[@]}" ]; do
                    case "${_mm_ids[$_mm_i]}" in __*__) ;; *) _mm_picked="${_mm_picked:+$_mm_picked,}${_mm_ids[$_mm_i]}" ;; esac
                    _mm_i=$((_mm_i + 1))
                done
                ;;
            *)
                for _mm_tok in $(printf '%s' "$_mm_answer" | tr ',' ' '); do
                    _mm_known=0
                    _mm_i=0
                    while [ "$_mm_i" -lt "${#_mm_ids[@]}" ]; do
                        [ "${_mm_ids[$_mm_i]}" = "$_mm_tok" ] && _mm_known=1
                        _mm_i=$((_mm_i + 1))
                    done
                    if [ "$_mm_known" -eq 1 ]; then
                        _mm_picked="${_mm_picked:+$_mm_picked,}$_mm_tok"
                    elif exakit_marketplace_addon_installed "$_mm_tok" 2>/dev/null; then
                        info "$_mm_tok is already installed — update it with: exakit update"
                    elif _exakit_addon_registered "$_mm_tok" && _exakit_addon_system_present "$_mm_tok"; then
                        info "$_mm_tok is already on this system — the kit leaves it alone"
                    elif _exakit_addon_registered "$_mm_tok" && ! _exakit_addon_applicable "$_mm_tok"; then
                        _mm_why="$(_exakit_addon_applicable_reason "$_mm_tok")"
                        die "$_mm_tok is not available on this machine${_mm_why:+: $_mm_why}"
                    elif _exakit_addon_registered "$_mm_tok"; then
                        # Registered but no module in this kit copy: a real
                        # add-on the user asked for by name — say what fixes it
                        # instead of calling it unknown.
                        die "The $_mm_tok module is not part of this kit copy — update the kit first: exakit update"
                    else
                        die "Unknown marketplace add-on in EXAKIT_MARKETPLACE_ADDONS: '$_mm_tok' (known: $(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//'))"
                    fi
                done
                ;;
        esac
        if [ -z "$_mm_picked" ]; then
            # Say WHY this is a refusal and not a failure. A reader who arrives
            # here straight after an add-on failed to install reads "nothing to
            # install" as a contradiction of what they just saw; the repair
            # command is what turns it back into an answer.
            info "Nothing to install — every requested add-on is already present."
            info "If one of them is present but not working, repair it with: exakit update <id>"
            return 0
        fi
        _exakit_marketplace_apply "$_mm_picked"
        return $?
    fi

    # There is ONE table. The reference panel that used to stand above the
    # selection carried an Add-on / Version / Description row per add-on, and
    # then the selection below it repeated every installable add-on by name --
    # the same list twice, a box apart. The version and the description now sit
    # in the selection itself as columns, so the reader picks from the thing
    # that describes them.
    #
    # What that costs, on the all-covered path only: the rows for add-ons that
    # are NOT installable (already installed, already on this system, missing
    # from this kit copy) had nowhere else to go, and the panel was the only
    # output that path produced. They are represented by the count below
    # instead. ui_table_disable is how they would come back -- as dim,
    # unpickable rows inside the one table, the way the MCP client list shows
    # "Cursor · not installed".
    printf '\n'

    if [ "$_mm_selectable" -eq 0 ]; then
        info "Everything available is already covered."
        # Named, not just counted: "everything is covered" without saying WHICH
        # things, or how, is the whole of what this path prints.
        # Three fields per line (id|why|version), so the version has to be read
        # into its own name: with two names the third field rode along inside
        # the second and every line ended in a stray "|" ("managed outside the
        # kit|"). An installed add-on shows its version, the others show why.
        while IFS='|' read -r _mm_cid _mm_cwhy _mm_cver; do
            [ -n "$_mm_cid" ] || continue
            info "$(printf '%-14s %s' "$_mm_cid" "$_mm_cwhy${_mm_cver:+ $_mm_cver}")"
        done <<EXAKIT_MM_COVERED
$_mm_covered
EXAKIT_MM_COVERED
        return 0
    fi

    # WITHOUT A TERMINAL, THE ANSWER IS SKIP. The pre-ticked rows exist so a
    # human's bare Enter installs what is on offer; keeping them as the answer
    # when nobody could see the question turned `exakit marketplace` from a
    # browse into a full multi-hundred-MB install with a live daemon — run by
    # agents that were told to look, not to install. Installing without a
    # terminal takes an explicit answer: EXAKIT_MARKETPLACE_ADDONS, or ids on
    # the command line. ⇄ twin: the same guard in Show-ExakitMarketplaceMenu.
    if [ -z "$(_exakit_prompt_tty)" ]; then
        info "No terminal to ask on — nothing was installed."
        info "See what is available (read-only): exakit marketplace --list   (--json for scripts)"
        info "Install explicitly: exakit marketplace <id>   or EXAKIT_MARKETPLACE_ADDONS=<ids>|all exakit marketplace"
        return 0
    fi

    # The selection — the same live table the data-load menu draws: a group row
    # with the add-ons hanging off connectors (UI_TEE/UI_CORNER from the ui
    # palette; ASCII in plain mode), the available add-ons pre-selected so Enter
    # alone installs what is on offer, and Skip as the exclusive opt-out. An
    # interactive run that cannot draw still keeps the pre-selected defaults
    # (EXAKIT_MARKETPLACE_ADDONS=none is the scripted opt-out); a run with no
    # terminal at all never reaches this point.
    # Mirrors exakit_data_load_select / Show-ExakitMarketplaceMenu.
    #
    # The rows the reader ticks here are the rows _exakit_marketplace_apply then
    # fills in, so the choice and the progress are one screen. The disabled rows
    # the checkbox version carried are gone: the state table directly above
    # already gives each of them a version and a status, in more room than a
    # dimmed one-line label had.
    EXAKIT_ADDON_TABLE_STATE="$(mktemp "${TMPDIR:-/tmp}/exakit-addons.XXXXXX")" || {
        warn "Could not create a temporary file for the add-ons table."
        return 1
    }
    _mm_pick_ids=()
    _mm_i=0
    while [ "$_mm_i" -lt "${#_mm_ids[@]}" ]; do
        case "${_mm_ids[$_mm_i]}" in
            __*__) ;;
            *) _mm_pick_ids+=("${_mm_ids[$_mm_i]}") ;;
        esac
        _mm_i=$((_mm_i + 1))
    done
    EXAKIT_ADDON_TABLE_DISABLED="$_mm_covered"
    EXAKIT_ADDON_TABLE_META="$_mm_meta"
    _exakit_addon_table_build "$EXAKIT_ADDON_TABLE_STATE" "${_mm_pick_ids[@]}"
    UI_TABLE_TITLE="Marketplace add-ons"
    # The first column's heading, or the add-ons would sit under "Dataset".
    UI_TABLE_COL1="Add-on"
    # The two the reference panel used to carry. Module state, like COL1, so
    # they are cleared the moment this menu is done -- a heading left behind is
    # how the next table ends up wearing this one's columns.
    UI_TABLE_COL2="Version"
    UI_TABLE_COL3="Description"
    ui_table_menu "$EXAKIT_ADDON_TABLE_STATE"
    UI_TABLE_COL2=""
    UI_TABLE_COL3=""
    # ONLY A PRESSED ENTER INSTALLS. The menu pre-selects everything so that
    # Enter alone acts on what is on offer - which is only a safe posture while
    # there is an Enter. Without one (a dumb terminal where the interactive
    # table cannot draw, a stdin that hit EOF mid-menu), ui_table_menu returns
    # those same defaults as the standing selection, and applying them here
    # installed EVERY add-on on a machine where nobody chose anything - real
    # venvs, real downloads. The scripted route stays EXAKIT_MARKETPLACE_ADDONS.
    if [ "${EXAKIT_TABLE_CONFIRMED:-0}" != 1 ]; then
        _exakit_addon_table_cleanup
        info "No interactive terminal to confirm a selection — nothing was installed."
        info "Pick add-ons without the menu: EXAKIT_MARKETPLACE_ADDONS=<ids|all> exakit marketplace"
        return 0
    fi
    case ",$EXAKIT_TABLE_SELECTION," in
        *",$EXAKIT_ADDON_TABLE_ROW_SKIP,"*)
            _exakit_addon_table_cleanup
            info "Marketplace closed — nothing was installed."
            return 0
            ;;
    esac
    _mm_picked=""
    for _mm_idx in $(printf '%s' "$EXAKIT_TABLE_SELECTION" | tr ',' ' '); do
        # "none" is a selection too (a read that hit EOF), and it would reach sed
        # as a line address it cannot parse.
        case "$_mm_idx" in ''|*[!0-9]*) continue ;; esac
        _mm_id="$(printf '%s\n' "$EXAKIT_ADDON_TABLE_IDS" | sed -n "${_mm_idx}p")"
        [ -n "$_mm_id" ] || continue
        _mm_picked="${_mm_picked:+$_mm_picked,}$_mm_id"
    done
    if [ -z "$_mm_picked" ]; then
        _exakit_addon_table_cleanup
        info "Nothing selected — nothing was installed."
        return 0
    fi
    _exakit_marketplace_apply "$_mm_picked"
}

# exakit_marketplace_list <json01> — the READ-ONLY answer to "what add-ons
# exist and where do they stand?", for agents and scripts that must never
# trigger an install by looking. One row per registered add-on, whatever its
# state; nothing here writes the manifest, a failure note, or a log. The
# status vocabulary is fixed: installed / available / managed outside the
# kit / not in this kit copy / not available on this machine.
exakit_marketplace_list() {
    _ml_json="${1:-0}"
    _ml_rows=""
    while IFS='|' read -r _ml_id _ml_label; do
        [ -n "$_ml_id" ] || continue
        _ml_ver=""
        _ml_reason=""
        if ! _exakit_addon_applicable "$_ml_id" 2>/dev/null && \
           ! exakit_marketplace_addon_installed "$_ml_id" 2>/dev/null; then
            _ml_status="not available on this machine"
            _ml_reason="$(_exakit_addon_applicable_reason "$_ml_id" 2>/dev/null || true)"
        elif exakit_marketplace_addon_installed "$_ml_id"; then
            _ml_status="installed"
            _ml_ver="$(exakit_version_plain "$(exakit_component_current "$_ml_id" 2>/dev/null || true)")"
        elif _exakit_addon_system_present "$_ml_id"; then
            _ml_status="managed outside the kit"
        elif ! exakit_marketplace_addon_available "$_ml_id"; then
            _ml_status="not in this kit copy"
        else
            _ml_status="available"
            _ml_ver="$(exakit_version_plain "$(exakit_component_available "$_ml_id" 2>/dev/null || true)")"
        fi
        _ml_rows="$_ml_rows$_ml_id|$_ml_status|$_ml_ver|$_ml_reason
"
    done <<EXAKIT_ML_EOF
$(exakit_marketplace_addons)
EXAKIT_ML_EOF

    if [ "$_ml_json" = "1" ]; then
        _ml_first=1
        printf '{\n  "addons": [\n'
        while IFS='|' read -r _ml_id _ml_status _ml_ver _ml_reason; do
            [ -n "$_ml_id" ] || continue
            [ "$_ml_first" -eq 1 ] || printf ',\n'
            _ml_first=0
            printf '    {"id": "%s", "status": "%s", "installed": %s' \
                "$_ml_id" "$_ml_status" \
                "$([ "$_ml_status" = "installed" ] && echo true || echo false)"
            [ -n "$_ml_ver" ] && printf ', "version": "%s"' "$_ml_ver"
            [ -n "$_ml_reason" ] && printf ', "reason": "%s"' \
                "$(printf '%s' "$_ml_reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            printf '}'
        done <<EXAKIT_ML_JSON
$_ml_rows
EXAKIT_ML_JSON
        printf '\n  ]\n}\n'
        return 0
    fi

    while IFS='|' read -r _ml_id _ml_status _ml_ver _ml_reason; do
        [ -n "$_ml_id" ] || continue
        printf '%-16s %s%s%s\n' "$_ml_id" "$_ml_status" \
            "${_ml_ver:+ }" "$_ml_ver"
        [ -n "$_ml_reason" ] && printf '%-16s %s\n' "" "($_ml_reason)"
    done <<EXAKIT_ML_OUT
$_ml_rows
EXAKIT_ML_OUT
    return 0
}

# exakit_marketplace_offer — the closing moment of an install: everything ran,
# the panel is on screen, and this asks ONE question — add optional tools now,
# or maybe later? Dynamic by design:
#   - an add-on that is already on the machine (kit-managed, or a system
#     install the kit does not manage) is not on offer;
#   - when nothing is left to offer, the question disappears entirely;
#   - a run with soft failures gets the one-line hint instead of a victory lap;
#   - no TTY (scripted/agent installs) also gets the hint — unless
#     EXAKIT_MARKETPLACE_ADDONS pre-answers, which installs without asking.
# Best-effort by contract: callers run it in a subshell so nothing in here can
# end an install that already succeeded. ⇄ twin: Request-ExakitMarketplaceOffer.
# exakit_print_ready_line — the install's ONE closing line.
#
# There were two: an "ok Setup complete" before the connection panel, and this
# one after it. The panel is the payoff and the reader does not need to be told
# twice, so the first is gone and this is what remains.
#
# It lives here rather than inside the marketplace offer, where it used to sit,
# because that offer returns early three separate ways — nothing left to
# install (every re-run, and the kit tells people to re-run), a scripted
# EXAKIT_MARKETPLACE_ADDONS answer (how the agent install runs), and no tty
# (curl | bash). Behind those gates the only run that got a closing line was an
# interactive, fully-successful, first-time one.
#
# Silent after a soft failure, deliberately: "done and working" must be true
# before it is said, and exakit_print_soft_failures has just listed what is not.
# ⇄ twin: Write-ExakitReadyLine in exakit-common.ps1.
exakit_print_ready_line() {
    [ -z "${EXAKIT_SOFT_FAILED:-}" ] || return 0
    printf '\n'
    ok "Your starter kit is ready to use."
    return 0
}

exakit_marketplace_offer() {
    _exakit_marketplace_load_modules
    exakit_marketplace_has_pending || return 0
    # Fill the About cache now, while the gate question below is still being
    # read: this is the one screen where the cache is reliably cold (a machine
    # minutes old), and the table it feeds does not exist yet.
    _exakit_marketplace_warm_about

    # A scripted answer wins over any prompt (same contract as the menu).
    if [ -n "${EXAKIT_MARKETPLACE_ADDONS:-}" ]; then
        exakit_marketplace_menu
        return $?
    fi

    # "Done and working" must be true before it is said: a run that recorded
    # soft failures points at the marketplace without the celebration.
    if [ -n "${EXAKIT_SOFT_FAILED:-}" ] || [ -z "$(_exakit_prompt_tty)" ]; then
        info "Optional add-ons (dashboards & more): exakit marketplace"
        return 0
    fi

    # One gate question first — the same cursor menu every other kit choice
    # uses, no typing: Yes is pre-ticked, No is the exclusive opt-out. Only a
    # Yes opens the marketplace selection itself (where the available add-ons
    # come pre-selected, so Enter installs them and Skip still backs out).
    #
    # "Your starter kit is ready to use." used to be printed here. It is now
    # exakit_print_ready_line, called by the setup scripts before this offer:
    # behind these gates it reached only an interactive, fully-successful run
    # that still had an add-on left to install, which is a minority of runs.
    # The install is over; what follows is a different question. A rule with air
    # around it is the seam, so the offer does not read as one more install step.
    ui_rule
    # A heading, not an action: what follows the rule is a separate offer, and
    # the dim bullet marked it as one more thing being done TO the machine.
    heading "Supercharge Exasol with add-ons from marketplace"
    EXAKIT_CHECKBOX_EXCLUSIVE=2
    ui_checkbox_menu "Explore marketplace ?" "1" \
        "Yes" \
        "No"
    case ",$EXAKIT_CHECKBOX_SELECTION," in
        *",1,"*)
            exakit_marketplace_menu || true
            # "Browse again: exakit marketplace · how to use one: exakit
            # help <add-on>" stood here. The table above has just said what was
            # installed and what each one gives you; the reader has not asked
            # to browse again, and the closing support line already names
            # `exakit help`.
            ;;
        *)
            info "Maybe later — browse any time with: exakit marketplace"
            ;;
    esac
    return 0
}

# _exakit_marketplace_apply <ids_csv> — install each picked add-on in turn. One
# failure does not strand the rest; the exit status says whether all made it.
_exakit_marketplace_apply() {
    _mp_status=0
    # The SAME table the selection was just made in becomes the progress display:
    # the rows do not move, so nobody has to map one screen onto another. It
    # animates only where there is a terminal to animate on, and a scripted
    # answer (EXAKIT_MARKETPLACE_ADDONS) never built a table at all — every
    # add-on then narrates in plain lines exactly as it did before.
    EXAKIT_ADDON_TABLE_LIVE=0
    if [ -n "$EXAKIT_ADDON_TABLE_STATE" ]; then
        ui_table_begin "$EXAKIT_ADDON_TABLE_STATE" && EXAKIT_ADDON_TABLE_LIVE=1
    fi
    # With the table narrating, the per-add-on lines underneath it are the same
    # facts twice — and printing one scrolls the frame the animator is redrawing.
    # EXAKIT_QUIET_DETAIL routes them to the logfile instead, which is what it is
    # for; install_one saves and restores it, so nesting is already handled.
    _mp_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    _exakit_addon_table_live && EXAKIT_QUIET_DETAIL=1
    for _mp_id in $(printf '%s' "$1" | tr ',' ' '); do
        # Which row this add-on owns, if a table is on screen. Empty means there
        # is none and the single-line bar takes over, unchanged.
        EXAKIT_ADDON_TABLE_ROW=""
        if _exakit_addon_table_live; then
            EXAKIT_ADDON_TABLE_ROW="$(_exakit_addon_table_row "$_mp_id")"
            [ "$EXAKIT_ADDON_TABLE_ROW" = "0" ] && EXAKIT_ADDON_TABLE_ROW=""
        fi
        info "Installing add-on: $_mp_id"
        _mp_t0="$(date +%s 2>/dev/null || echo 0)"
        if _exakit_marketplace_install_one "$_mp_id"; then
            # <id>_summary is an OPTIONAL hook: the one fact worth carrying out
            # of an install whose reference panel is now log-only. Resolved
            # generically, so a new add-on gets it by defining the function and
            # nothing here has to learn its name.
            _mp_note=""
            _mp_summary_fn="$(_exakit_addon_fn "$_mp_id" summary)"
            if command -v "$_mp_summary_fn" >/dev/null 2>&1; then
                _mp_note="$("$_mp_summary_fn" 2>/dev/null || true)"
            fi
            _mp_elapsed=$(( $(date +%s 2>/dev/null || echo 0) - _mp_t0 ))
            [ "$_mp_elapsed" -ge 0 ] 2>/dev/null || _mp_elapsed=0
            # ok() is the record either way: it writes the FULL summary to the
            # logfile whether or not the screen is showing it, which is what
            # keeps a summary too long for the column from being lost.
            ok "$_mp_id installed${_mp_note:+ — $_mp_note}"
            [ -n "$EXAKIT_ADDON_TABLE_ROW" ] && \
                ui_table_set "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_ADDON_TABLE_ROW" \
                    done "" "" "" "" \
                    "$(_exakit_addon_table_cell "$_mp_note" "$_mp_elapsed")"
        else
            [ -n "$EXAKIT_ADDON_TABLE_ROW" ] && \
                ui_table_set "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_ADDON_TABLE_ROW" \
                    failed "" "" "" "" "did not finish — see the log"
            # NOTHING HERE. Two reasons, and they compound.
            #
            # The module that failed has already printed its own reason, specific
            # to what went wrong. A generic "retry with: exakit marketplace"
            # underneath gave one failure two competing answers and the generic
            # one was wrong anyway -- marketplace declines to act on an add-on
            # that is already present and answers "Nothing to install".
            #
            # And the row above already says "did not finish - see the log", so
            # even a corrected sentence is the third telling of one fact. Printed
            # under a frame the animator has only just stopped repainting, it is
            # where the table visibly came apart on a real install.
            _exakit_log_file "WARN  $_mp_id did not finish installing"
            _mp_status=1
        fi
        EXAKIT_ADDON_TABLE_ROW=""
    done
    # The table stops redrawing BEFORE anything is said over it, and only then is
    # what was collected on the way said.
    if _exakit_addon_table_live; then
        ui_table_end "$EXAKIT_ADDON_TABLE_STATE"
        EXAKIT_ADDON_TABLE_LIVE=0
    fi
    EXAKIT_QUIET_DETAIL="$_mp_prev_quiet"
    _exakit_addon_notes_say
    _exakit_addon_table_cleanup
    return "$_mp_status"
}

exakit_update_targets() {
    case "${1:-all}" in
        all)
            # skills is a light component like exapump: the skill set has its
            # own version in versions.json, and `exakit update` fetches a newer
            # set from the kit repository without a kit release (see
            # exakit_update_skills). Before it joined this list, bumping that
            # version reached nobody. A kit copy that carries no skills/ at all
            # has no skill set to keep current, so it gets no row either.
            printf '%s\n' exakit runtime exapump mcp pyexasol
            exakit_skills_dir >/dev/null 2>&1 && printf '%s\n' skills
            # Marketplace add-ons join the routine update set only once they
            # are installed: `exakit update all` must never install a tool the
            # user did not pick from `exakit marketplace`.
            exakit_marketplace_installed_addons
            # Kit 2 is a target only once it is installed: at Kit 1 the update
            # check offers it as a discovery line instead, and a routine update
            # must never add a kit level on its own. It comes last because its
            # assets arrive with the kit copy that `exakit` updates above.
            if [ "$(manifest_get kit_level 2>/dev/null || true)" = "2" ]; then
                printf '%s\n' kit2
            fi
            ;;
        runtime|database|db) printf '%s\n' runtime ;;
        personal|exakit|exapump|mcp|pyexasol|skills|kit2) printf '%s\n' "$1" ;;
        *)
            # Any registered marketplace add-on is a valid explicit target.
            _exakit_addon_registered "$1" || return 1
            printf '%s\n' "$1"
            ;;
    esac
}

# exakit_min_kit_satisfied <required> — can this kit run the advertised
# Component? An unknown kit version never blocks: it would strand the user.
exakit_min_kit_satisfied() {
    _mks_kit="$(exakit_component_current exakit 2>/dev/null || true)"
    [ -n "$_mks_kit" ] && [ "$_mks_kit" != "unknown" ] || return 0
    [ "$_mks_kit" != "$1" ] || return 0
    exakit_version_newer "$_mks_kit" "$1"
}

# exakit_component_is_ahead <component> — is the installed version newer than the
# one the manifest publishes?
#
# The kit never moves a component backwards: not on request, not with a
# confirmation, not behind an env override. A user who upgraded pyexasol or
# exapump themselves keeps what they chose, and a maintainer who lowers a version
# in versions.json does not drag anyone back with it — to withdraw a bad release,
# publish a higher version. Returns 0 when installed is ahead, so the caller can
# leave the component alone.
exakit_component_is_ahead() {
    _cia_component="$1"
    _cia_current="$(exakit_component_current "$_cia_component" 2>/dev/null || true)"
    _cia_available="$(exakit_component_available "$_cia_component" 2>/dev/null || true)"
    [ -n "$_cia_current" ] && [ -n "$_cia_available" ] || return 1
    [ "$_cia_current" != "unknown" ] || return 1
    [ "$_cia_current" != "not installed" ] || return 1
    exakit_version_newer "$_cia_current" "$_cia_available"
}

# exakit_print_versions_source_line — where the Tagged column came from, so
# nobody has to guess whether a stale answer is being shown.
exakit_print_versions_source_line() {
    case "${EXAKIT_VERSION_POLICY:-manifest}" in
        manifest) ;;
        latest)
            info "Available versions come from live upstream lookups (EXAKIT_VERSION_POLICY=latest)"
            _exakit_print_override_line
            return 0
            ;;
        *)
            info "Available versions come from this kit's built-in fallbacks (EXAKIT_VERSION_POLICY=${EXAKIT_VERSION_POLICY}, no network)"
            _exakit_print_override_line
            return 0
            ;;
    esac
    case "$(exakit_versions_source)" in
        fetched) _vsl_text="published manifest, fetched just now" ;;
        cache)   _vsl_text="cached manifest copy" ;;
        baked)   _vsl_text="manifest shipped with this kit, no network" ;;
        # Nothing readable anywhere: the rows say "unknown" rather than inventing
        # a number, so say that plainly instead of crediting a source.
        *)       info "The versions manifest could not be read, so the available versions are unknown"
                 _exakit_print_override_line
                 return 0
                 ;;
    esac
    _vsl_updated="$(exakit_versions_value updated 2>/dev/null || true)"
    if [ -n "$_vsl_updated" ]; then
        _vsl_updated="$(exakit_format_manifest_date "$_vsl_updated")"
        _vsl_text="$_vsl_text (updated $_vsl_updated)"
    fi
    # Where the version numbers came from is provenance, not news: it belongs in
    # the logfile and, while the lookup is running, in the spinner's label --
    # not as a sentence left under the card once the card has answered.
    # exakit_version_source_label sets EXAKIT_VERSIONS_SOURCE_LABEL for the
    # caller to spin on; the line itself is logged either way.
    EXAKIT_VERSIONS_SOURCE_LABEL="Versions: $_vsl_text"
    _vsl_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    info "Versions: $_vsl_text"
    EXAKIT_QUIET_DETAIL="$_vsl_prev_quiet"
    if exakit_versions_schema_ahead; then
        info "This kit is older than the published manifest — update it first: exakit update"
    fi
    _exakit_print_override_line
    return 0
}

# An env override outranks every source above, so say so rather than letting the
# line above take credit for a version the user picked.
_exakit_print_override_line() {
    for _pol_component in exapump mcp pyexasol personal; do
        if [ -n "$(_exakit_component_env_override "$_pol_component")" ]; then
            info "Some versions come from EXAKIT_* environment overrides and not from the manifest"
            return 0
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# After-command update notice
# ---------------------------------------------------------------------------
# One dim line on stderr, after an unrelated command, when the maintainers have
# flagged a pending change as recommended or critical. Everything about it is
# deliberately conservative: a normal bump never interrupts anyone, the notice
# appears at most once a day, it never speaks unless stderr is a terminal, and
# EXAKIT_NO_UPDATE_NOTICE=1 silences it for good.
#
# It is NOT a nag about every version: `exakit version` is where the full
# picture lives, and `exakit version` has its own always-on hint.
# ⇄ twin: Show-ExakitUpdateNotice in setup/lib/exakit-common.ps1.
EXAKIT_NOTICE_STATE="${EXAKIT_NOTICE_STATE:-$EXAKIT_CACHE_DIR/notice-state.json}"
# The notice is printed after every command, but working out WHAT to say costs
# real time: nine manifest reads and a live probe per component, about 600ms. The
# answer barely changes, so it is computed occasionally and printed from a cached
# plan. EXAKIT_NOTICE_PLAN_TTL is how long a plan is trusted; it is also thrown away
# the moment the manifest or the versions cache changes, which covers every update
# applied through the kit.
#
# What it cannot see is a component upgraded behind the kit's back -- `uv tool
# upgrade` on the MCP server, say -- because that moves only the binary on disk,
# which is the reading the cache exists to stop repeating. Such a machine is told
# about an update it has already taken, until the TTL runs out. That is the trade:
# one stale line for at most fifteen minutes, against 600ms on every command.
EXAKIT_NOTICE_PLAN="${EXAKIT_NOTICE_PLAN:-$EXAKIT_CACHE_DIR/notice-plan}"
EXAKIT_NOTICE_PLAN_TTL="${EXAKIT_NOTICE_PLAN_TTL:-900}"
# 0 = show the notice after every command. A pending update that nobody is told
# about is the same as no update mechanism at all: the machines that most need one
# belong to people who never run `exakit version`. Set
# EXAKIT_NOTICE_INTERVAL to a number of seconds to throttle it (86400 for the old
# once-a-day behaviour), or EXAKIT_NO_UPDATE_NOTICE=1 to silence it entirely.
EXAKIT_NOTICE_INTERVAL="${EXAKIT_NOTICE_INTERVAL:-0}"

# exakit_notice_due — has enough time passed since the last notice?
exakit_notice_due() {
    [ -f "$EXAKIT_NOTICE_STATE" ] || return 0
    _nd_last="$(sed -n 's/.*"last_shown"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "$EXAKIT_NOTICE_STATE" 2>/dev/null | head -1)"
    case "$_nd_last" in
        ''|*[!0-9]*) return 0 ;;
    esac
    case "$EXAKIT_NOTICE_INTERVAL" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$(( $(date +%s) - _nd_last ))" -ge "$EXAKIT_NOTICE_INTERVAL" ]
}

# exakit_notice_record — stamp the state file. Atomic, and never a reason for a
# command to fail: a read-only cache directory just means the notice repeats.
exakit_notice_record() {
    mkdir -p "$(dirname "$EXAKIT_NOTICE_STATE")" 2>/dev/null || return 0
    _nr_tmp="$EXAKIT_NOTICE_STATE.tmp.$$"
    printf '{\n  "last_shown": %s\n}\n' "$(date +%s)" > "$_nr_tmp" 2>/dev/null || return 0
    mv -f "$_nr_tmp" "$EXAKIT_NOTICE_STATE" 2>/dev/null || rm -f "$_nr_tmp"
    return 0
}

# A notice may never make an unrelated command feel slow. The cache is normally
# warm (version and update both refresh it); when it is not, this is
# one very short attempt that gives up almost immediately.
# _exakit_notice_signature — what the plan was derived from, as content.
#
# Timestamps were the obvious choice and the wrong one: bash compares mtimes with
# whole-second granularity, so an `exakit update` that rewrote the manifest in the
# same second the plan was written left the plan looking fresh. cksum is two forks
# and a few milliseconds, and it cannot be fooled by the clock.
# The files are passed as arguments, not redirected in: `cksum < missing` makes the
# SHELL report the failed redirection on its own stderr, which no 2>/dev/null inside
# the substitution can suppress, and a version notice must never leak a diagnostic
# about its own bookkeeping.
_exakit_notice_signature() {
    _ns_manifest=""
    _ns_cache=""
    if [ -f "$EXAKIT_MANIFEST" ]; then
        _ns_manifest="$(cksum "$EXAKIT_MANIFEST" 2>/dev/null | awk '{print $1"-"$2}')"
    fi
    if [ -f "$EXAKIT_VERSIONS_CACHE" ]; then
        _ns_cache="$(cksum "$EXAKIT_VERSIONS_CACHE" 2>/dev/null | awk '{print $1"-"$2}')"
    fi
    # The kit's own copy of the document counts too. It is the tier that answers
    # when there is no cache, and a self-update replaces it -- without this, a kit
    # whose baked document changed would keep announcing the previous one's news.
    _ns_baked=""
    _ns_baked_doc="$(exakit_versions_baked_doc 2>/dev/null || true)"
    if [ -n "$_ns_baked_doc" ] && [ -f "$_ns_baked_doc" ]; then
        _ns_baked="$(cksum "$_ns_baked_doc" 2>/dev/null | awk '{print $1"-"$2}')"
    fi
    printf '%s:%s:%s' "$_ns_manifest" "$_ns_cache" "$_ns_baked"
}

# _exakit_notice_plan_fresh — is the cached plan still worth believing?
#
# The TTL is the least of it. What matters is that applying an update silences the
# notice on the very next command: the manifest is rewritten by every install and
# every update, and the versions cache by every refresh, so a change to either
# retires the plan. Without that, `exakit update` would be followed by fifteen
# minutes of being told to run `exakit update`.
_exakit_notice_plan_fresh() {
    [ -f "$EXAKIT_NOTICE_PLAN" ] || return 1
    _npf_sig="$(_exakit_notice_plan_field sig)"
    [ "$_npf_sig" = "$(_exakit_notice_signature)" ] || return 1
    _npf_at="$(sed -n 's/^computed_at=\([0-9][0-9]*\)$/\1/p' "$EXAKIT_NOTICE_PLAN" 2>/dev/null | head -1)"
    case "$_npf_at" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$EXAKIT_NOTICE_PLAN_TTL" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(( $(date +%s) - _npf_at ))" -lt "$EXAKIT_NOTICE_PLAN_TTL" ]
}

# _exakit_notice_plan_field <name> — one line out of the cached plan.
_exakit_notice_plan_field() {
    sed -n "s/^$1=//p" "$EXAKIT_NOTICE_PLAN" 2>/dev/null | head -1
}

# _exakit_notice_plan_write — key=value lines, not JSON: this is read on every
# single command, and a sed call beats parsing.
_exakit_notice_plan_write() {
    [ -n "$EXAKIT_NOTICE_PLAN" ] || return 0
    mkdir -p "$(dirname "$EXAKIT_NOTICE_PLAN")" 2>/dev/null || return 0
    _npw_tmp="$(mktemp "${EXAKIT_NOTICE_PLAN}.XXXXXX" 2>/dev/null)" || return 0
    {
        printf 'computed_at=%s\n' "$(date +%s)"
        printf 'sig=%s\n' "$(_exakit_notice_signature)"
        printf 'light=%s\n' "$_notice_light_detail"
        printf 'light_worst=%s\n' "$_notice_light_worst"
        printf 'heavy=%s\n' "$_notice_heavy_detail"
        printf 'heavy_worst=%s\n' "$_notice_heavy_worst"
    } > "$_npw_tmp" 2>/dev/null || { rm -f "$_npw_tmp"; return 0; }
    mv "$_npw_tmp" "$EXAKIT_NOTICE_PLAN" 2>/dev/null || rm -f "$_npw_tmp"
    return 0
}

_exakit_notice_refresh_cache() {
    exakit_versions_cache_fresh && return 0
    (
        EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT=1
        EXAKIT_VERSION_LOOKUP_MAX_TIME=2
        exakit_versions_update_cache force >/dev/null 2>&1
    ) || true
    return 0
}

_exakit_notice_word() {
    case "$1" in
        critical)    printf 'A critical' ;;
        recommended) printf 'A recommended' ;;
        # A routine bump says nothing about urgency, because it has none to claim.
        *)           printf 'An' ;;
    esac
}

# exakit_notice_after_command — the whole notice, gates included. Always returns 0:
# nothing about version news may change what a command reports.
exakit_notice_after_command() {
    [ "${EXAKIT_NO_UPDATE_NOTICE:-0}" = "1" ] && return 0
    [ "${EXAKIT_VERSION_POLICY:-manifest}" = "manifest" ] || return 0
    # stderr must be a terminal: a notice has no business in a log file, a pipe,
    # or a CI transcript.
    [ -t 2 ] || return 0
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    exakit_notice_due || return 0

    if _exakit_notice_plan_fresh; then
        _notice_light_worst="$(_exakit_notice_plan_field light_worst)"
        _notice_heavy_worst="$(_exakit_notice_plan_field heavy_worst)"
        [ -n "$_notice_light_worst" ] || _notice_light_worst="normal"
        [ -n "$_notice_heavy_worst" ] || _notice_heavy_worst="normal"
        # Confirm each cached candidate is STILL behind before repeating it. A plan
        # written while a component was mid-install kept announcing an update the
        # user had already taken, and disagreed with `exakit version` run
        # seconds later. Costs one probe per pending component -- and when nothing
        # is pending, which is the normal case, it costs nothing at all.
        _notice_light="$(_exakit_notice_still_behind "$(_exakit_notice_plan_field light)")"
        _notice_heavy="$(_exakit_notice_still_behind "$(_exakit_notice_plan_field heavy)")"
        _exakit_notice_say
        return 0
    fi

    _exakit_notice_refresh_cache
    exakit_versions_resolve_doc >/dev/null 2>&1 || return 0

    # Severity is tracked per group, not once for the whole notice: a routine
    # exapump bump must not be announced as critical just because the runtime
    # happens to have a critical one pending in the same breath.
    _notice_light=""
    _notice_heavy=""
    _notice_light_detail=""
    _notice_heavy_detail=""
    _notice_light_worst="normal"
    _notice_heavy_worst="normal"
    for _notice_component in $(exakit_update_targets all); do
        _notice_actual="$(exakit_update_actual_target "$_notice_component" 2>/dev/null || printf '%s\n' "$_notice_component")"
        _notice_avail="$(exakit_component_available "$_notice_actual" 2>/dev/null || true)"
        [ -n "$_notice_avail" ] || continue
        _notice_cur="$(exakit_component_current "$_notice_actual" 2>/dev/null || true)"
        [ -n "$_notice_cur" ] && [ "$_notice_cur" != "unknown" ] || continue
        [ "$_notice_cur" != "$_notice_avail" ] || continue
        # Different is not the same as behind. An install that is PAST the
        # advertised version has nothing pending: the kit never moves a component
        # backwards, so `exakit version` renders that row as "none" and
        # `exakit update` says "keeping yours". Announcing an update here made the
        # three commands contradict each other, and pointed the user at a command
        # that could not do anything. Compared in place rather than through
        # exakit_component_is_ahead, which would re-probe what is already in hand.
        if exakit_version_newer "$_notice_cur" "$_notice_avail"; then
            continue
        fi
        # Every pending update is announced, whatever its severity. Severity still
        # decides the WORDING (a critical bump says so), but no longer whether the
        # user hears about it at all: a routine exapump bump that is never
        # mentioned is a bump that never gets applied.
        _notice_severity="$(exakit_component_severity "$_notice_actual")"
        # Keep the worst severity in the group, on the normal < recommended <
        # critical ladder. This used to promote normal straight to recommended,
        # which was invisible while only flagged bumps got this far and would now
        # word every routine bump as a recommendation.
        if exakit_component_is_heavy "$_notice_actual"; then
            _notice_heavy="${_notice_heavy}${_notice_heavy:+, }$_notice_actual"
            _notice_heavy_detail="${_notice_heavy_detail:-}${_notice_heavy_detail:+, }$_notice_actual:$_notice_avail"
            case "$_notice_severity" in
                critical)    _notice_heavy_worst="critical" ;;
                recommended) [ "$_notice_heavy_worst" = "critical" ] || _notice_heavy_worst="recommended" ;;
            esac
        else
            _notice_light="${_notice_light}${_notice_light:+, }$_notice_actual"
            _notice_light_detail="${_notice_light_detail:-}${_notice_light_detail:+, }$_notice_actual:$_notice_avail"
            case "$_notice_severity" in
                critical)    _notice_light_worst="critical" ;;
                recommended) [ "$_notice_light_worst" = "critical" ] || _notice_light_worst="recommended" ;;
            esac
        fi
    done
    _exakit_notice_plan_write
    _exakit_notice_say
    return 0
}

# _exakit_notice_still_behind <name:advertised, name:advertised> — the names that are
# genuinely still behind, as a display list.
#
# The advertised version is stored with each candidate so this needs no document and
# no severity lookup: probe what is installed, compare, drop whatever has caught up.
_exakit_notice_still_behind() {
    _nsb_in="$1"
    [ -n "$_nsb_in" ] || return 0
    _nsb_out=""
    _nsb_rest="$_nsb_in"
    while [ -n "$_nsb_rest" ]; do
        case "$_nsb_rest" in
            *,*) _nsb_entry="${_nsb_rest%%,*}"; _nsb_rest="${_nsb_rest#*,}" ;;
            *)   _nsb_entry="$_nsb_rest"; _nsb_rest="" ;;
        esac
        # trim the space after a comma
        _nsb_entry="${_nsb_entry# }"
        _nsb_name="${_nsb_entry%%:*}"
        _nsb_want="${_nsb_entry#*:}"
        [ -n "$_nsb_name" ] || continue
        if [ -z "$_nsb_want" ] || [ "$_nsb_want" = "$_nsb_name" ]; then
            # A plan written before versions were recorded with the names: keep the
            # entry rather than silently dropping a real pending update.
            _nsb_out="${_nsb_out}${_nsb_out:+, }$_nsb_name"
            continue
        fi
        _nsb_now="$(exakit_component_current "$_nsb_name" 2>/dev/null || true)"
        if [ -z "$_nsb_now" ] || [ "$_nsb_now" = "unknown" ] || [ "$_nsb_now" = "$_nsb_want" ]; then
            continue
        fi
        # "Caught up" is not only "landed on exactly the advertised version" — an
        # install that overshot it has nothing pending either. Testing equality
        # alone kept such a component alive as a candidate, so a cached plan went
        # on announcing an update on every command with nothing able to clear it.
        if exakit_version_newer "$_nsb_now" "$_nsb_want"; then
            continue
        fi
        _nsb_out="${_nsb_out}${_nsb_out:+, }$_nsb_name"
    done
    printf '%s' "$_nsb_out"
}

# _exakit_notice_say — print whatever the plan says, freshly computed or cached.
# Reads the same four variables either path fills in.
_exakit_notice_say() {
    [ -n "$_notice_light" ] || [ -n "$_notice_heavy" ] || return 0

    printf '\n' >&2
    if [ -n "$_notice_light" ]; then
        printf '%s%s update is available for %s — apply in seconds:  exakit update%s\n' \
            "${UI_DIM:-}" "$(_exakit_notice_word "$_notice_light_worst")" "$_notice_light" "${UI_RESET:-}" >&2
    fi
    if [ -n "$_notice_heavy" ]; then
        # Never "run update now" for the runtime: it stops the database, so the
        # user picks the moment after seeing what it involves.
        printf '%s%s update is available for %s — requires stopping the database, details:  exakit version%s\n' \
            "${UI_DIM:-}" "$(_exakit_notice_word "$_notice_heavy_worst")" "$_notice_heavy" "${UI_RESET:-}" >&2
    fi
    # No "silence this with ..." footer: the notice is one line, once a day, and
    # a line telling the reader how to switch it off is longer than the notice
    # itself. EXAKIT_NO_UPDATE_NOTICE=1 still works; the help page and AGENTS.md
    # document it for whoever goes looking.
    exakit_notice_record
    return 0
}

# exakit_print_kit2_discovery_line — one dim line offering the Kit 2 add-on, and
# ONLY when the maintainers have deliberately enabled that path by adding a kit2
# block to versions.json. Its absence is the launch switch: no block, no line,
# anywhere. It is never part of the after-command notice either — discovering an
# add-on is not an update anyone is behind on.
exakit_print_kit2_discovery_line() {
    [ "$(manifest_get kit_level 2>/dev/null || true)" = "1" ] || return 0
    _k2d_version="$(exakit_component_available kit2 2>/dev/null || true)"
    [ -n "$_k2d_version" ] || return 0
    _k2d_min="$(exakit_component_min_kit kit2 2>/dev/null || true)"
    if [ -n "$_k2d_min" ] && ! exakit_min_kit_satisfied "$_k2d_min"; then
        return 0
    fi
    _k2d_note="$(exakit_component_note kit2 2>/dev/null || true)"
    printf '    %sKit 2 (%s) is available — add it with: exakit upgrade-kit2%s\n' \
        "${UI_DIM:-}" "${_k2d_note:-Trusted AI Workflow add-on}" "${UI_RESET:-}"
    return 0
}

# exakit_update_kit2 — re-stage the Kit 2 assets from the kit copy. Kit 2 assets
# travel inside the kit tarball, so "updating Kit 2" is: make sure the kit copy is
# the one carrying them, then re-run the additive upgrade, which is idempotent and
# touches nothing but kit2.* state.
exakit_update_kit2() {
    [ "$(manifest_get kit_level 2>/dev/null || true)" = "2" ] || \
        die "Kit 2 is not installed. Add it with: exakit upgrade-kit2"
    _k2u_root="$(exakit_repo_root)" || die "Could not locate the kit's upgrade scripts."
    _k2u_script="$_k2u_root/upgrade/upgrade-kit2.sh"
    [ -f "$_k2u_script" ] || die "upgrade-kit2.sh is not part of this kit build."
    _k2u_bundled="$(exakit_kit2_bundled_version 2>/dev/null || true)"
    _k2u_advertised="$(exakit_component_available kit2 2>/dev/null || true)"
    if [ -n "$_k2u_advertised" ] && [ -n "$_k2u_bundled" ] && \
       exakit_version_newer "$_k2u_advertised" "$_k2u_bundled"; then
        # The newer bundle is not on this machine yet, and no amount of re-staging
        # will conjure it: the assets arrive with the kit itself.
        warn "Kit 2 $_k2u_advertised is advertised, but this kit copy carries $_k2u_bundled."
        info "Kit 2 assets travel with the kit — update it first:  exakit update"
        return 0
    fi
    info "Re-staging the Kit 2 assets from $(ui_tilde "$_k2u_root")"
    bash "$_k2u_script" || die "The Kit 2 upgrade script reported an error; nothing else was changed."
}

# exakit_print_version_table — the component table `exakit version` renders
# under its Kit panel: what is installed, and whether anything newer is waiting.
#
# This is the merge of what used to be two commands. `exakit version` listed the
# installed versions and `exakit update-check` compared them against the
# advertised set, so answering the only question either was ever asked meant
# running both and reading one screen against the other — and they disagreed
# often enough to need a comment saying which to trust. There is one screen now,
# and one place where a component's state is decided.
#
# Three columns, because the third answers the question the other two raise:
#   Component  what to name in `exakit update <component>`
#   Version    what is on this machine right now
#   Status     current, or the advertised version and what applying it involves
# The tagged version, the maintainer's severity and the action all live in
# Status: each is only ever interesting for a row that is behind, and four
# mostly-empty columns pushed the card past 80 columns to say nothing.
#
# Someone who asks explicitly gets fresh data: the TTL exists for the readers
# that run behind other commands, not for this one.
# ⇄ twin: Invoke-CmdVersion in setup/exakit.ps1.
exakit_print_version_table() {
    # Everything down to the table itself is GATHERING, and on a cold cache or a
    # slow network it is the longest part of `exakit version` — the screen sat
    # silent right after the Kit box, which is where it was reported. Narrated
    # in two phases so the reader can see which one is taking the time.
    # ui_spin_begin draws nothing unless stdout is a terminal, so a piped or
    # captured run is unchanged.
    #
    # --json: the same rows as one object — installed, advertised, status and
    # severity per component, plus the three keys every state query carries.
    # `exakit version --json` used to print the decorated table and exit 0,
    # which is worse than an error for a parser.
    _uvt_json=0
    [ "${1:-}" = "--json" ] && _uvt_json=1
    if [ "${EXAKIT_VERSION_POLICY:-manifest}" = "manifest" ]; then
        ui_spin_begin "Checking for newer versions"
        exakit_versions_update_cache force >/dev/null 2>&1 || true
        exakit_versions_resolve_doc >/dev/null 2>&1 || true
        ui_spin_end
    fi
    ui_spin_begin "Checking installed components"
    # One parallel array per column, not one packed string per row. The packed
    # form needs a delimiter, and the tab it used was the wrong one: `set -- $row`
    # collapses runs of IFS *whitespace*, so a row whose severity cell was empty
    # silently shifted its notes into the wrong fields. The old code escaped that
    # only because its severity cell was padded to a fixed width and could never
    # be empty — which is exactly the invariant this table drops. Separate arrays
    # cannot shift.
    _uc_comp=(); _uc_ver=(); _uc_status=(); _uc_note=(); _uc_maint=()
    _uc_avail=(); _uc_raw=(); _uc_sev=()
    # Column widths measured, not guessed. A fixed %-10s fits the built-in
    # component names and nothing else: dash-server (11), json-tables (11) and
    # exasol-vscode (13) each overflow it, and an overflowing cell pushes every
    # column after it right ON THAT ROW ONLY — so the table lost its alignment
    # exactly when a user had add-ons installed, and only for their rows.
    _uc_cw=9; _uc_vw=7
    # One counter, not three. The table used to sort what was waiting into quick,
    # heavy and staged so it could print a different closing line for each, and
    # the three lines said the same thing three ways. `exakit update` already
    # knows a runtime change needs the database stopped and asks at the moment it
    # matters; this screen only has to say that something is waiting.
    _pending=0
    for _component in $(exakit_version_table_targets); do
        _row_component="$(exakit_update_actual_target "$_component" 2>/dev/null || printf '%s\n' "$_component")"
        _row_installed="$(exakit_version_plain "$(exakit_version_installed_cell "$_row_component")")"
        _row_available="$(exakit_version_plain "$(exakit_component_available "$_row_component" 2>/dev/null || true)")"
        [ -n "$_row_available" ] || _row_available="unknown"
        _row_note=""
        _row_severity="$(exakit_component_severity "$_row_component" 2>/dev/null || true)"
        _status="current"
        if ! exakit_component_supported "$_row_component"; then
            # Nothing to offer and nothing wrong: there is simply no build for
            # this machine, and an update command that cannot succeed must not be
            # printed.
            _row_installed="not available"
            _status="-"
            _row_severity=""
            _row_note="no $_row_component build exists for this platform"
        elif [ "$_row_installed" = "not installed" ] && _exakit_addon_registered "$_row_component"; then
            # An add-on nobody has installed is not behind on anything: it is an
            # offer. The marketplace is the only path that installs one, so that
            # is the whole status — naming a version here would read as a pending
            # update to something that is not on the machine.
            _status="exakit marketplace"
            _row_severity=""
        elif [ "$_row_available" = "unknown" ] || [ "$_row_installed" = "unknown" ]; then
            _status="inspect"
        elif [ "$_row_installed" = "not installed" ] && exakit_component_is_heavy "$_row_component"; then
            # A runtime that is not installed is not a runtime this machine wants:
            # offering to deploy a second database onto an existing one would be
            # actively wrong. (A missing light component, by contrast, is exactly
            # the repair case below.)
            _status="inspect"
        elif [ "$_row_installed" != "not installed" ] && \
             exakit_version_newer "$_row_installed" "$_row_available"; then
            # Installed is ahead of the published set. The kit never moves a
            # component backwards, so there is nothing to offer: lowering a
            # version in versions.json is not a rollback lever, and a user who
            # upgraded a component themselves keeps what they chose. Counts toward
            # neither the "apply them in one go" hint nor the heavy deferral,
            # because no command belongs in this row at all.
            #
            # The row says only "none". Not "yours is newer than tested", which
            # apologised for the install and made the tested set sound abandoned;
            # not the tagged number either, which invites the reader to go looking
            # for a way back to it. There is nothing to do, so the row says so and
            # stops. The severity goes with it — a severity rates the advertised
            # version, and there is nothing to recommend to someone already past it.
            _status="none"
            _row_severity=""
        elif [ "$_row_installed" != "$_row_available" ]; then
            _row_min_kit="$(exakit_component_min_kit "$_row_component" 2>/dev/null || true)"
            if [ -n "$_row_min_kit" ] && ! exakit_min_kit_satisfied "$_row_min_kit"; then
                # Waiting, but not on this reader: `exakit update` cannot apply
                # it until the kit itself moves, so it must not be counted into
                # the closing line that promises it can.
                _status="update exakit first (needs kit >= $_row_min_kit)"
                _pending=$((_pending - 1))
            elif [ "$_row_installed" = "not installed" ]; then
                # Not an upgrade: the component the manifest says belongs here is
                # missing, and `exakit update` puts it back.
                _status="$_row_available available (repair)"
            else
                # No "(heavy)" or "(major)" suffix: what applying a component
                # involves is `exakit update`'s to explain, at the point where it
                # asks. Saying it here warned about a cost on a screen that cannot
                # charge it, twice for the runtime, and left the Status column
                # reading like a set of caveats rather than a set of versions.
                _status="$_row_available available"
            fi
            _pending=$((_pending + 1))
        fi
        [ "${#_row_component}" -gt "$_uc_cw" ] && _uc_cw="${#_row_component}"
        [ "${#_row_installed}" -gt "$_uc_vw" ] && _uc_vw="${#_row_installed}"
        _uc_comp+=("$_row_component")
        _uc_ver+=("$_row_installed")
        _uc_status+=("$(_exakit_status_cell "$_status" "$_row_severity")")
        _uc_note+=("$_row_note")
        _uc_maint+=("$(exakit_component_note "$_row_component" 2>/dev/null || true)")
        _uc_avail+=("$_row_available")
        _uc_raw+=("$_status")
        _uc_sev+=("${_row_severity:-normal}")
    done

    ui_spin_end
    if [ "$_uvt_json" -eq 1 ]; then
        _uvt_tab="$(printf '\t')"
        _uvt_tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-version.XXXXXX")" || die "Could not create a temporary file for --json."
        _uvt_i=0
        while [ "$_uvt_i" -lt "${#_uc_comp[@]}" ]; do
            printf '%s\n' "${_uc_comp[$_uvt_i]}$_uvt_tab${_uc_ver[$_uvt_i]}$_uvt_tab${_uc_avail[$_uvt_i]}$_uvt_tab${_uc_raw[$_uvt_i]}$_uvt_tab${_uc_sev[$_uvt_i]}$_uvt_tab${_uc_maint[$_uvt_i]}$_uvt_tab${_uc_note[$_uvt_i]}" >> "$_uvt_tmp"
            _uvt_i=$((_uvt_i + 1))
        done
        run_python - "$_uvt_tmp" "$_pending" "$(exakit_component_current exakit 2>/dev/null || printf unknown)" \
            "$(manifest_get installed_at 2>/dev/null || true)" "$(exakit_versions_source 2>/dev/null || true)" \
            "$(exakit_marketplace_addons 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')" <<'EXAKIT_VJ_PY'
import json, sys
# WHICH ROWS ARE OPTIONAL. Nothing in a component object said whether it is
# part of the kit or an add-on someone chose, so an agent reading
# `status: "available"` could not tell "you have not installed this optional
# tool" from "a piece of your kit is missing". The registry is the source:
# these are the ids exakit_marketplace_addons lists, never a hand-written set.
addon_ids = set((sys.argv[6] if len(sys.argv) > 6 else "").split())
rows = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        comp, ver, avail, status, sev, maint, note = (line.split("\t") + [""] * 7)[:7]
        # The raw cell doubles as the HUMAN Action column, so it carried
        # whatever a human should do next - "exakit marketplace",
        # "2.2.0 available (repair)" - which is a command or a sentence, not a
        # status. The JSON key gets a fixed vocabulary a parser can switch on,
        # and the action moves to a per-row remedy that is runnable as-is.
        if status == "current":
            row_status, remedy = "current", None
        elif status == "none":
            # Installed is ahead of the published set; nothing to do.
            row_status, remedy = "ahead", None
        elif status == "-":
            row_status, remedy = "unsupported", None
        elif status == "inspect":
            row_status, remedy = "unknown", None
        elif status == "exakit marketplace":
            row_status, remedy = "available", "exakit marketplace %s" % comp
        elif status.startswith("update exakit first"):
            row_status, remedy = "blocked_on_kit", "exakit update exakit"
        elif status.endswith("available (repair)"):
            row_status, remedy = "missing", "exakit update %s" % comp
        elif status.endswith("available"):
            row_status, remedy = "update_available", "exakit update %s" % comp
        else:
            row_status, remedy = status, None
        rows.append({
            "component": comp,
            "addon": comp in addon_ids,
            "installed": None if ver in ("not installed", "not available", "") else ver,
            "installed_label": ver,
            "advertised": None if avail in ("unknown", "") else avail,
            "status": row_status,
            "remedy": remedy,
            "severity": sev or "normal",
            "note": maint or None,
            "platform_note": note or None,
        })
pending = int(sys.argv[2] or 0)
print(json.dumps({
    "installed": True,
    "status": "update_pending" if pending > 0 else "current",
    "remedy": "exakit update" if pending > 0 else None,
    "pending": pending,
    "kit": {"version": sys.argv[3], "installed_at": sys.argv[4] or None},
    "versions_source": sys.argv[5] or None,
    "components": rows,
}, indent=2))
EXAKIT_VJ_PY
        _uvt_rc=$?
        rm -f "$_uvt_tmp"
        rm -f "$EXAKIT_NOTICE_PLAN" 2>/dev/null || true
        return "$_uvt_rc"
    fi
    # A card, like every other framed answer the kit gives. ui_panel_end measures
    # with _ui_visible_len, so the coloured severity suffix does not throw the
    # border off the way a byte count would.
    ui_panel_begin "Components"
    ui_panel_line "$(printf '%-*s %-*s %s' "$_uc_cw" "Component" "$_uc_vw" "Version" "Status")"
    _uc_i=0
    while [ "$_uc_i" -lt "${#_uc_comp[@]}" ]; do
        ui_panel_line "$(printf '%-*s %-*s %s' \
            "$_uc_cw" "${_uc_comp[$_uc_i]}" "$_uc_vw" "${_uc_ver[$_uc_i]}" "${_uc_status[$_uc_i]}")"
        _exakit_version_note_lines "${_uc_note[$_uc_i]}"
        _exakit_version_note_lines "${_uc_maint[$_uc_i]}"
        _uc_i=$((_uc_i + 1))
    done
    ui_panel_end
    printf '\n'
    # This screen just worked out the truth the long way. Retire the cached plan
    # so the next notice cannot repeat something the table above has just
    # contradicted.
    rm -f "$EXAKIT_NOTICE_PLAN" 2>/dev/null || true
    exakit_print_versions_source_line
    exakit_print_kit2_discovery_line
    # One command is promoted, and it is the one that handles everything:
    # `exakit update`. Per-component commands still work and the rows name the
    # components, so anyone who wants one has it — but a screen that listed a
    # command per row taught the long way round to the reader who least needed it.
    # The add-on rows carry their own `exakit marketplace`, so the discovery line
    # that used to repeat it here is gone too.
    if [ "$_pending" -gt 0 ]; then
        info "Bring everything up to date with: exakit update"
    fi
    return 0
}

# _exakit_version_note_lines <text> — one note, wrapped and indented inside the
# card. A maintainer note is free text, and one long enough to blow the card past
# 80 columns would wrap in the terminal instead, taking the border with it.
# Silent on an empty note, so no caller has to test first.
_exakit_version_note_lines() {
    [ -n "$1" ] || return 0
    _vnl_line=""
    for _vnl_word in $1; do
        if [ -z "$_vnl_line" ]; then
            _vnl_line="$_vnl_word"
        elif [ "$(( ${#_vnl_line} + 1 + ${#_vnl_word} ))" -le 68 ]; then
            _vnl_line="$_vnl_line $_vnl_word"
        else
            ui_panel_line "  ${UI_DIM:-}$_vnl_line${UI_RESET:-}"
            _vnl_line="$_vnl_word"
        fi
    done
    [ -n "$_vnl_line" ] && ui_panel_line "  ${UI_DIM:-}$_vnl_line${UI_RESET:-}"
    return 0
}

# exakit_version_table_targets — every row the table shows.
#
# The update set (what `exakit update` would act on) plus the add-ons this
# machine COULD install: a row saying "not installed" is only worth printing when
# `exakit marketplace` can actually fix it, so an add-on that cannot run here (no
# VS Code, JSON Tables on Windows) is left out entirely rather than dangling an
# install that would be refused. Same filter, and so the same list, as the
# marketplace screen itself.
exakit_version_table_targets() {
    exakit_update_targets all
    while read -r _vtt_id <&3; do
        [ -n "$_vtt_id" ] || continue
        _exakit_addon_offerable "$_vtt_id" || continue
        # PRESENT, not kit-installed: a tool the user installed themselves is
        # already on the machine, and the kit refuses to manage that copy — so a
        # row telling them to run `exakit marketplace` for it advertises an
        # install that would be declined. Same check the marketplace screen makes,
        # so the two screens agree about what is still on offer.
        _exakit_marketplace_addon_present "$_vtt_id" && continue
        printf '%s\n' "$_vtt_id"
    done 3<<EXAKIT_VTT_EOF
$(exakit_marketplace_addons | cut -d'|' -f1)
EXAKIT_VTT_EOF
}

# exakit_version_installed_cell <component> — the Version cell: the version that
# is on this machine right now, or "not installed".
#
# Only that. The cell used to carry a "(kit installed X)" suffix when the copy on
# the machine was not the one the kit put there, and it cost more than it said:
# the annotation is twice the width of the version it explains, so it widened
# every row of the table to push the card past 80 columns, and it had to be
# stripped back off before each of the comparisons below — one more thing to
# forget on the next arm added. What is installed is what is installed.
exakit_version_installed_cell() {
    # The reader returns non-zero only when the component is provably ABSENT, and
    # that verdict has to survive: swallowing it made `exakit version` print a
    # recorded version for a deleted binary while status said "not installed".
    if _vic_live="$(exakit_component_current "$1" 2>/dev/null)"; then
        :
    else
        printf 'not installed\n'
        return 0
    fi
    if [ -z "$_vic_live" ]; then
        printf '%s\n' "$(exakit_version_recorded "$1" | sed -e 's/^$/not installed/')"
        return 0
    fi
    printf '%s\n' "$_vic_live"
}

# exakit_version_recorded <component> — the version the manifest says this
# install put on the machine, or empty when it records none.
exakit_version_recorded() {
    case "$1" in
        personal)
            _vr_val="$(manifest_get runtime.version 2>/dev/null || true)"
            ;;
        mcp) _vr_val="$(manifest_get components.mcp_server.version 2>/dev/null || true)" ;;
        # The kit records no version for itself: exakit_component_current reads it
        # from the installed command, and annotating that with the manifest's copy
        # would report drift against the very file that was just updated.
        exakit) _vr_val="" ;;
        *) _vr_val="$(manifest_get "components.$(printf '%s' "$1" | tr '-' '_').version" 2>/dev/null || true)" ;;
    esac
    printf '%s\n' "$_vr_val"
}

# _exakit_status_cell <status> <severity> — the Status cell, with the maintainer's
# severity appended when it is not the normal one.
#
# Only a flagged row shows a severity, so it stays the one thing on the screen
# that draws the eye. Colour goes on last and only on the suffix: ui_panel_end
# measures with _ui_visible_len, so the escapes cost the border nothing.
_exakit_status_cell() {
    case "$2" in
        critical)
            _sc_suffix="(critical)"
            [ "${UI_FANCY:-0}" = 1 ] && _sc_suffix="${UI_WARN:-}${_sc_suffix}${UI_RESET:-}"
            printf '%s %s' "$1" "$_sc_suffix"
            ;;
        recommended)
            _sc_suffix="(recommended)"
            [ "${UI_FANCY:-0}" = 1 ] && _sc_suffix="${UI_OK:-}${_sc_suffix}${UI_RESET:-}"
            printf '%s %s' "$1" "$_sc_suffix"
            ;;
        *) printf '%s' "$1" ;;
    esac
}

exakit_update_self() {
    _latest="$(exakit_component_available exakit)"
    [ -n "$_latest" ] || die "Could not resolve the advertised starter kit version."
    _current="$(exakit_component_current exakit 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "exakit is already current ($_current)"
        return 0
    fi
    _repo="$EXAKIT_KIT_REPO"
    _kit_dir="$EXAKIT_HOME/kit"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-kit.XXXXXX")"
    # THE STAGE LIVES BESIDE THE KIT, not in TMPDIR, so the swap below is a
    # same-filesystem rename. It used to be a mktemp -d under ${TMPDIR:-/tmp},
    # and on any machine where /tmp is tmpfs or EXAKIT_HOME is on another
    # volume - which this kit itself recommends for WSL - `mv` across
    # filesystems is copy-then-unlink. A failure part way through (ENOSPC is
    # the realistic one) left the destination existing as a partial directory,
    # which is what made the rollback below able to nest the backup inside it.
    # A rename cannot fail part way.
    mkdir -p "$EXAKIT_HOME" 2>/dev/null || true
    _stage="$(mktemp -d "$EXAKIT_HOME/.kit-stage.XXXXXX")" ||
        _stage="$(mktemp -d "${TMPDIR:-/tmp}/exakit-kit-stage.XXXXXX")"
    _backup="${_kit_dir}.backup-$(date +%Y%m%d-%H%M%S)"
    # Named before the swap, cleared after it. See _exakit_update_marker.
    _update_marker="$EXAKIT_HOME/.update-in-progress"
    info "Updating starter kit ${_current:-unknown} -> $_latest"
    # main first — that is what install.sh fetches, and kit script changes live on
    # main: a tag exists only where a release was cut. The tag URLs stay behind it
    # so a kit installed from a tagged release still updates, and so a v0.1.0 field
    # kit (which only ever knew tags) keeps working.
    _kit_ref=""
    for _kit_candidate in "main" "v${_latest}" "${_latest}"; do
        case "$_kit_candidate" in
            main) _kit_url="https://github.com/${_repo}/archive/refs/heads/main.tar.gz" ;;
            *)    _kit_url="https://github.com/${_repo}/archive/refs/tags/${_kit_candidate}.tar.gz" ;;
        esac
        if curl -fL --proto '=https' --retry 3 --connect-timeout 15 -sS -o "$_tmp" "$_kit_url"; then
            _kit_ref="$_kit_candidate"
            break
        fi
    done
    if [ -z "$_kit_ref" ]; then
        rm -f "$_tmp"
        rm -rf "$_stage"
        die "Could not download the starter kit from $_repo (tried main and the $_latest tags)."
    fi
    tar -xzf "$_tmp" -C "$_stage" --strip-components 1 || {
        rm -rf "$_stage"
        rm -f "$_tmp"
        die "Could not unpack the starter kit update; existing kit copy was left untouched."
    }
    rm -f "$_tmp"
    # versions.json is on this list deliberately: without it the new kit copy has
    # no offline version tier and cannot say what version it is. None of the
    # paths on this list may ever be renamed, or an old kit refuses the upgrade.
    for _required in setup/exakit setup/lib/common.sh setup/lib/runtime-personal.sh setup/lib/exapump.sh setup/lib/mcp.sh setup/exakit.ps1 setup/lib/exakit-common.ps1 versions.json; do
        [ -f "$_stage/$_required" ] || {
            rm -rf "$_stage"
            die "Downloaded starter kit is incomplete (missing $_required); existing kit copy was left untouched."
        }
    done
    # What actually landed is what gets recorded. GitHub's raw endpoint can serve a
    # newer versions.json than the branch tarball for a few minutes after a merge,
    # and claiming a version that is not on disk would make every later comparison
    # lie (and re-download this kit on every update).
    _staged_version="$(exakit_kit_version_at "$_stage" 2>/dev/null || true)"
    if [ -z "$_staged_version" ]; then
        _staged_version="$_latest"
    elif [ "$_staged_version" != "$_latest" ] && exakit_version_newer "$_latest" "$_staged_version"; then
        warn "The downloaded kit is $_staged_version, not the advertised $_latest — the published manifest is a few minutes ahead of $_kit_ref. Recording $_staged_version."
    fi
    # THE WINDOW WITH NO KIT IN IT. Between the two renames below there is no
    # $EXAKIT_HOME/kit, and every exakit subcommand needs it to find
    # setup/lib/*.sh. The only recovery used to be the `if !` arm, which runs
    # for a non-zero exit and for nothing else - not Ctrl-C, not a closed
    # laptop, not an OOM kill, not a power cut - and no code anywhere looked
    # for a stranded kit.backup-* on a later run. So the one command users are
    # told to run routinely could leave the machine with no tooling at all and
    # nothing on screen saying the backup beside it was a restore point.
    #
    # Two answers, because they cover different failures. The trap covers the
    # signal that actually happens (Ctrl-C). The marker covers the ones no
    # process can handle - SIGKILL, power loss - by leaving the next run
    # something to find; setup/exakit reads it in the branch that fires when
    # the library is missing, which is the only code still able to run.
    _exakit_update_restore() {
        [ -d "$_backup" ] || return 0
        [ -d "$_kit_dir" ] && rm -rf "$_kit_dir"
        mv "$_backup" "$_kit_dir" 2>/dev/null || return 1
        rm -f "$_update_marker" 2>/dev/null || true
        return 0
    }
    if [ -d "$_kit_dir" ]; then
        printf '%s\n' "$_backup" > "$_update_marker" 2>/dev/null || true
        trap '_exakit_update_restore; trap - INT TERM; exit 130' INT TERM
        mv "$_kit_dir" "$_backup" || {
            rm -f "$_update_marker" 2>/dev/null || true
            trap - INT TERM
            rm -rf "$_stage"
            die "Could not back up existing kit copy; update was not applied."
        }
        info "Previous kit copy kept at $_backup"
    fi
    mkdir -p "$(dirname "$_kit_dir")"
    if ! mv "$_stage" "$_kit_dir"; then
        # rm -rf FIRST. Without it, a destination left behind as a partial
        # directory by a failed cross-filesystem mv turned this "restore" into
        # `mv backup kit/` - the good copy buried at kit/kit.backup-<ts>/ - and
        # the message below still claimed it had been restored. The staging
        # change above makes the partial directory unreachable in the first
        # place; this makes the recovery correct regardless.
        _exakit_update_restore
        trap - INT TERM
        rm -rf "$_stage"
        die "Could not install the staged starter kit update; previous kit copy was restored."
    fi
    if [ -f "$_kit_dir/setup/exakit" ]; then
        mkdir -p "$EXAKIT_BIN_DIR"
        install -m 755 "$_kit_dir/setup/exakit" "$EXAKIT_BIN_DIR/exakit" || {
            # The kit directory is NEW and the binary is OLD at this point, so
            # this is not a state to leave behind either.
            _exakit_update_restore
            trap - INT TERM
            die "Could not install the exakit command to $EXAKIT_BIN_DIR (is it writable? is the disk full?)."
        }
    else
        _exakit_update_restore
        trap - INT TERM
        die "Updated kit did not contain setup/exakit after staging; previous kit copy was restored."
    fi
    # Past every failure that would have wanted the backup: the kit directory
    # and the binary now agree.
    rm -f "$_update_marker" 2>/dev/null || true
    trap - INT TERM
    manifest_set kit.source "${_repo}@${_kit_ref}"
    # Record the version too, not just where it came from. exakit_component_current
    # reads kit.version first, so without this the kit would report its old
    # version forever: the table would keep offering the same update, `exakit
    # version` would keep nagging, and `exakit update` would re-download the whole
    # kit on every run.
    manifest_set kit.version "$_staged_version"
    ok "exakit updated to $_staged_version. Database data, credentials, and MCP state were not changed."
    # Refresh the AI skills from the copy that just landed. The update replaces
    # the whole kit directory, so a release that adds or rewords a skill leaves
    # the agents' discovery folders holding the PREVIOUS text with nothing to say
    # so. `exakit skills` can now report that drift, but detecting it and never
    # resolving it just moves the work to the user; the skills ship with the kit,
    # so they travel with a kit update. Best-effort: a stale skill must not fail
    # an otherwise complete update.
    if ls "$_kit_dir"/skills/*/SKILL.md >/dev/null 2>&1; then
        exakit_install_skills >/dev/null 2>&1 \
            && ok "AI skills refreshed from the new kit copy." \
            || warn "The AI skills could not be refreshed — run: exakit skills-install"
    fi
    # The kit that just landed describes itself: read the section out of the NEW
    # copy, which is already in place at this point.
    exakit_print_whats_new "$_staged_version" "What's new in $_staged_version" || true
}

# exakit_install_helper_early <script_dir> — put the `exakit` command in place
# BEFORE step 1, so `exakit status` answers from the first seconds of an
# install. The helper used to arrive in the last step, at 105 s of a 107 s
# install: AGENTS.md tells an agent to run the install in the background and
# poll `exakit status` until it says running, and for 98 % of the run the only
# answer was "command not found". The kit copy the command reads is already in
# place (install.sh extracts into it before the setup script starts); step 6
# still records the tick and refreshes anything that changed.
exakit_install_helper_early() {
    _ihe_src="$1/exakit"
    [ -f "$_ihe_src" ] || return 0
    mkdir -p "$EXAKIT_BIN_DIR" 2>/dev/null || return 0
    if [ ! -x "$EXAKIT_BIN_DIR/exakit" ] || ! cmp -s "$_ihe_src" "$EXAKIT_BIN_DIR/exakit" 2>/dev/null; then
        install -m 755 "$_ihe_src" "$EXAKIT_BIN_DIR/exakit" 2>/dev/null || return 0
    fi
    # Recorded in the log, not on the screen: the command being ready is a
    # fact for the log and for `exakit status` itself, not news for the reader.
    _exakit_log_file "INFO  exakit command ready (~/.local/bin/exakit) — exakit status answers from here on"
    return 0
}

# exakit_skills_local_version — the version of the skill set sitting in the kit
# copy on disk. Two sources, in order: the marker a skills-only update leaves
# beside the skills (skills/.version), because that update replaces the skills
# and NOT the kit copy's versions.json; then that versions.json, which describes
# the skills that shipped inside the same tarball. This is what skills-install
# records, so the record names the files that were copied — never the
# advertised version, which is what used to be written and which the copied
# files did not have to match. ⇄ twin: Get-ExakitSkillsLocalVersion.
exakit_skills_local_version() {
    _slv_root="$(exakit_repo_root 2>/dev/null)" || return 1
    if [ -s "$_slv_root/skills/.version" ]; then
        _slv_v="$(head -1 "$_slv_root/skills/.version" | tr -d '\r\n')"
        case "$_slv_v" in
            ''|*[!A-Za-z0-9._+-]*) ;;
            *) printf '%s\n' "$_slv_v"; return 0 ;;
        esac
    fi
    exakit_kit_version_at "$_slv_root" components.skills.version
}

# exakit_update_skills — bring the AI skills to the advertised set, without a
# kit release.
#
# The skills are files under skills/ in the kit repository, and they used to
# reach a machine only inside a kit update: bump components.skills.version on
# its own and `exakit skills` said "stale" while pointing at skills-install,
# which copied the OLD local files and recorded the NEW number. So the skill
# set is a light component now, like exapump. This fetches the kit repository's
# main branch (the same tarball, URL and trust the kit self-update uses), moves
# its skills/ directory into the kit copy, places the skills, and records the
# version the TARBALL's versions.json names — not the advertised one, because
# the raw endpoint can run minutes ahead of the branch archive, and a record
# that runs ahead of the files hides the drift for good.
#
# Best-effort, like the skills refresh inside the kit self-update: a skill set
# that could not be fetched must not fail an otherwise complete `exakit
# update`. Every failure warns, names the retry, and returns 0.
# ⇄ twin: Update-ExakitSkills.
exakit_update_skills() {
    _us_latest="$(exakit_component_available skills 2>/dev/null || true)"
    if [ -z "$_us_latest" ]; then
        warn "Could not resolve the advertised skill set; the skills were left as they are."
        return 0
    fi
    _us_current="$(exakit_component_current skills 2>/dev/null || true)"
    if [ "$_us_latest" = "$_us_current" ]; then
        ok "skills are already current ($_us_current)"
        return 0
    fi
    _us_kit="$(exakit_repo_root 2>/dev/null || true)"
    if [ -z "$_us_kit" ] || [ "$_us_kit" != "$EXAKIT_HOME/kit" ]; then
        # A source checkout is updated by git, not by this: place what it has.
        info "This kit runs from a source checkout; placing the skills it carries."
        exakit_install_skills >/dev/null 2>&1 || warn "The skills could not be placed — run: exakit skills-install"
        return 0
    fi
    _us_tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-skills.XXXXXX")" || {
        warn "Could not create a temporary file; the skills were left as they are."
        return 0
    }
    _us_stage="$(mktemp -d "${TMPDIR:-/tmp}/exakit-skills-stage.XXXXXX")" || {
        rm -f "$_us_tmp"
        warn "Could not create a temporary directory; the skills were left as they are."
        return 0
    }
    info "Updating AI skills ${_us_current:-not installed} -> $_us_latest"
    if ! curl -fL --proto '=https' --retry 3 --connect-timeout 15 -sS -o "$_us_tmp" \
            "https://github.com/${EXAKIT_KIT_REPO}/archive/refs/heads/main.tar.gz"; then
        rm -f "$_us_tmp"; rm -rf "$_us_stage"
        warn "Could not download the skill set from $EXAKIT_KIT_REPO; the skills were left as they are. Retry: exakit update"
        return 0
    fi
    if ! tar -xzf "$_us_tmp" -C "$_us_stage" --strip-components 1 2>>"${EXAKIT_LOG_FILE:-/dev/null}"; then
        rm -f "$_us_tmp"; rm -rf "$_us_stage"
        warn "Could not unpack the skill set; the skills were left as they are. Retry: exakit update"
        return 0
    fi
    rm -f "$_us_tmp"
    if ! ls "$_us_stage"/skills/*/SKILL.md >/dev/null 2>&1; then
        rm -rf "$_us_stage"
        warn "The downloaded kit carries no skills; the skills were left as they are."
        return 0
    fi
    # The version the files actually ARE, read from the document that travelled
    # with them. Recorded as such, so the table keeps offering the rest if the
    # branch archive has not caught up with the published manifest yet.
    _us_staged="$(exakit_kit_version_at "$_us_stage" components.skills.version 2>/dev/null || true)"
    if [ -z "$_us_staged" ]; then
        _us_staged="$_us_latest"
    elif [ "$_us_staged" != "$_us_latest" ] && exakit_version_newer "$_us_latest" "$_us_staged"; then
        warn "The downloaded skill set is $_us_staged, not the advertised $_us_latest — the published manifest is a few minutes ahead of main. Recording $_us_staged; the next update picks up the rest."
    fi
    printf '%s\n' "$_us_staged" > "$_us_stage/skills/.version"
    _us_backup="$_us_kit/skills.backup-$(date +%Y%m%d-%H%M%S)"
    if [ -d "$_us_kit/skills" ] && ! mv "$_us_kit/skills" "$_us_backup"; then
        rm -rf "$_us_stage"
        warn "Could not set the current skills aside; the skills were left as they are."
        return 0
    fi
    if ! mv "$_us_stage/skills" "$_us_kit/skills"; then
        [ -d "$_us_backup" ] && mv "$_us_backup" "$_us_kit/skills"
        rm -rf "$_us_stage"
        warn "Could not install the downloaded skills; the previous set was put back."
        return 0
    fi
    rm -rf "$_us_stage"
    # Place them. skills-install records components.skills.version from the
    # marker just written, so the record and the files agree.
    if exakit_install_skills >/dev/null 2>&1; then
        rm -rf "$_us_backup"
        ok "AI skills updated to $_us_staged. Restart or reload your AI client to pick them up."
    else
        warn "The new skills are in the kit copy but could not be placed — run: exakit skills-install"
    fi
    return 0
}

exakit_update_component() {
    _component="$1"
    shift || true
    # Defence in depth, and the last word on the subject. exakit_update settles
    # this before it gets here, but the updaters below hold no version opinion of
    # their own -- they install whatever they are handed, older included -- so a
    # caller that forgets to ask is one edit away from a downgrade. That is how
    # the runtime offer came to ask permission to stop a database and replace
    # 2.1.0 with 2.0.0.
    #
    # There is no downgrade in this kit: not on request, not by naming a
    # component explicitly, not with an env override, and not as a
    # maintainer-advised rollback. Lowering a version in versions.json is a way
    # to describe a tested set, never a lever to drag installs backwards -- to
    # withdraw a bad release, publish a higher version.
    _uc_actual="$(exakit_update_actual_target "$_component" 2>/dev/null || printf '%s\n' "$_component")"
    if exakit_component_is_ahead "$_uc_actual"; then
        ok "$_uc_actual is newer than the tested version -- keeping yours"
        return 0
    fi
    case "$_component" in
        exakit) exakit_update_self ;;
        exapump)
            command -v exapump_update >/dev/null 2>&1 || die "exapump module is not available in this version."
            exapump_update
            ;;
        mcp)
            command -v mcp_update >/dev/null 2>&1 || die "MCP module is not available in this version."
            mcp_update
            ;;
        pyexasol)
            command -v pyexasol_update >/dev/null 2>&1 || die "pyexasol module is not available in this version."
            pyexasol_update
            ;;
        kit2) exakit_update_kit2 ;;
        skills) exakit_update_skills ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                personal) personal_update "$@" ;;
                *) die "No runtime is recorded in the manifest." ;;
            esac
            ;;
        personal) personal_update "$@" ;;
        *)
            # Marketplace add-ons dispatch to their module's <id>_update.
            if _exakit_addon_registered "$_component"; then
                _uc_fn="$(_exakit_addon_fn "$_component" update)"
                command -v "$_uc_fn" >/dev/null 2>&1 || die "The $_component module is not available in this version."
                "$_uc_fn"
            else
                die "Unknown update target: $_component"
            fi
            ;;
    esac
}

# --- the heavy (runtime) update, offered inline instead of handed back --------
#
# `exakit update` used to refuse the heavy part outright: it printed "needs the
# database stopped, so it is not part of a routine update" and left the user to
# run `exakit update runtime` themselves, after stopping nothing and updating
# nothing. The work was never the problem — the second command was. On a
# terminal the offer is now made where the user already is, and one "y" runs the
# whole sequence: stop the database, update the runtime, bring it back up, say so.
#
# Both entry points run the SAME implementation: everything below ends at
# exakit_update_component, which is exactly what `exakit update runtime` calls.
# `exakit update runtime` itself is untouched — still standalone, still
# unprompted beyond the runtime updater's own confirmation.

# exakit_runtime_status / exakit_runtime_start — the runtime-agnostic pair the
# inline offer needs to keep its promise ("the database is running again
# afterwards"). Guarded on purpose: common.sh is sourced without the runtime
# modules (the test suites do it, and so does any caller that only needs version
# state), and an absent module means "cannot tell", not "not running".
# ⇄ twins: Get-ExakitRuntimeStatus / Start-ExakitRuntime in setup/exakit.ps1.
exakit_runtime_status() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        personal) command -v personal_status >/dev/null 2>&1 && personal_status 2>/dev/null ;;
    esac
    return 0
}

exakit_runtime_start() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        # AND THEN WAIT FOR IT. The launcher's start exits 0 without acting
        # in more than one state, so `exakit start` used to report success over
        # a database that never came up; personal_wait_ready_or_deploy asks the
        # database instead of the record and runs the launcher's own deploy
        # when nothing answers. The wait lives here rather than inside
        # personal_start, which other callers run as a best-effort nudge.
        personal)
            command -v personal_start >/dev/null 2>&1 || return 0
            personal_start
            command -v personal_wait_ready_or_deploy >/dev/null 2>&1 && personal_wait_ready_or_deploy
            ;;
    esac
    return 0
}

# exakit_stdin_is_tty — is there a terminal this run can actually ask a question
# on? Deliberately stricter than confirm()'s _exakit_prompt_tty, which falls back
# to /dev/tty: a piped or redirected run must not have a database-stopping
# question put on a terminal it is not reading from.
# ⇄ twin: Test-ExakitInteractive in setup/lib/exakit-common.ps1.
exakit_stdin_is_tty() {
    [ -t 0 ]
}

# exakit_runtime_update_is_staged <installed> <advertised> — true for an Exasol
# Personal MAJOR upgrade. That one is a data migration with its own backup-gated
# three-step flow (personal_upgrade_plan: --plan, --backup, --apply). A single
# y/N is not informed consent for it, so it keeps the deferral it has today.
# ⇄ twin: Test-ExakitRuntimeUpdateStaged in setup/exakit.ps1.
exakit_runtime_update_is_staged() {
    [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "personal" ] || return 1
    _rus_cur="$(exakit_major_version "${1:-}" 2>/dev/null || true)"
    _rus_new="$(exakit_major_version "${2:-}" 2>/dev/null || true)"
    case "$_rus_cur$_rus_new" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_rus_cur" != "$_rus_new" ]
}

# exakit_runtime_update_preanswer — "yes", "no", or empty when nobody has
# answered yet. Two ways to answer without a prompt, and they are the ways this
# kit already uses: `exakit update --yes` (the uninstall flag spelling) and
# EXAKIT_CONFIRM_RUNTIME_UPDATE, the variable that already pre-answers
# `exakit update runtime`. One opt-in, both entry points — a fleet that has said
# "yes, you may recreate the database container" has said it once.
# ⇄ twin: Get-ExakitRuntimeUpdatePreanswer in setup/exakit.ps1.
exakit_runtime_update_preanswer() {
    if [ "${_upd_assume_yes:-0}" = "1" ]; then
        printf 'yes\n'
        return 0
    fi
    case "${EXAKIT_CONFIRM_RUNTIME_UPDATE:-}" in
        1|y|Y|yes|YES|Yes) printf 'yes\n' ;;
        0|n|N|no|NO|No)    printf 'no\n' ;;
    esac
    return 0
}

# exakit_runtime_update_explain <actual> <installed> <advertised> — what the user
# is about to agree to, before they agree to it: that the database goes down,
# roughly for how long, that it comes back up, and what happens to the data.
# Stopping a database is disruptive and outward-facing; a bare "[y/N]" is not
# enough to consent to it.
# ⇄ twin: Write-ExakitRuntimeUpdateExplanation in setup/exakit.ps1.
exakit_runtime_update_explain() {
    warn "$1 $2 -> $3 needs the database stopped."
    case "$1" in
        personal)
            info "The launcher is replaced; the database is checked afterwards and started again if it ends up down — usually under a minute."
            info "Your data is kept: this update neither deletes nor migrates the tables in your database."
            # A minor bump is not always a small operation. From Exasol Personal
            # 2.3 a deployment runs the VM guest belonging to its launcher's
            # runner, so the first start after the launcher changes rebuilds that
            # guest. It is not a major upgrade and does not become a staged one,
            # but a single unexplained y/N covering a ten-minute start is not
            # informed consent either — so the wait is named before it happens.
            #
            # The sentinel is how "2.3 or newer" is asked with the comparator
            # this module already has: outranks is true only when the first
            # version is demonstrably higher than the second.
            _rue_guest_rebuild_from=2.2.99999
            if command -v personal_deployment_outranks >/dev/null 2>&1 && \
               personal_deployment_outranks "$3" "$_rue_guest_rebuild_from"; then
                info "The first start after this update rebuilds the deployment's VM guest — several minutes, once, and only that first start."
            fi
            ;;
        *)
            info "The database goes down for the update and is started again afterwards."
            info "Your data is kept."
            ;;
    esac
}

# exakit_apply_runtime_update <component> — stop, update, start, report.
#
# The runtime updaters own the sequence itself and are called here exactly as
# `exakit update runtime` calls it: personal_update replaces the launcher and
# leaves the deployment's data alone. There is no separate copy of that logic
# here, and no separate copy of the backup story either — see the comment on
# exakit_offer_runtime_update.
#
# What this adds is the one thing the prompt promises and the updaters do not
# guarantee across runtimes: a database that was up before this command is up
# after it.
# ⇄ twin: Invoke-ExakitRuntimeUpdateApply in setup/exakit.ps1.
exakit_apply_runtime_update() {
    _aru_was_running=no
    [ "$(exakit_runtime_status)" = "running" ] && _aru_was_running=yes
    # The offer above IS the confirmation the runtime updater asks for. Asking one
    # question twice is not a safety feature, so the answer is passed down.
    EXAKIT_CONFIRM_RUNTIME_UPDATE=1
    export EXAKIT_CONFIRM_RUNTIME_UPDATE
    exakit_update_component "$1"
    _aru_status="$(exakit_runtime_status)"
    if [ "$_aru_was_running" = "yes" ] && [ -n "$_aru_status" ] && [ "$_aru_status" != "running" ] && [ "$_aru_status" != "starting" ]; then
        info "Bringing the database back up"
        exakit_runtime_start
        _aru_status="$(exakit_runtime_status)"
    fi
    case "$_aru_status" in
        running)  ok "Runtime updated and the database is running again." ;;
        starting) ok "Runtime updated; the database is still coming up — check it with: exakit status" ;;
        '')       ok "Runtime updated." ;;
        *)        warn "Runtime updated, but the database reports '$_aru_status' — start it with: exakit start" ;;
    esac
    return 0
}

# exakit_offer_runtime_update <component> <actual> <installed> <advertised> —
# the heavy part of a routine `exakit update`, decided here instead of being
# handed to the user as homework. Returns 0 when it was applied, 1 when it was
# deferred (and then prints the exact command that applies it later).
#
# On backups: the kit has no data-export facility, and this path needs none.
# The runtime update does not touch the database content — it replaces the
# launcher binary and says so. The one runtime change that IS a data
# migration is the Personal major upgrade, and that already has a real backup
# (personal_upgrade_backup tars the whole deployment) inside its own three-step
# flow — which is exactly why this function refuses to start it from a y/N.
# ⇄ twin: Invoke-ExakitRuntimeUpdateOffer in setup/exakit.ps1.
exakit_offer_runtime_update() {
    _oru_component="$1"
    _oru_actual="$2"
    _oru_cur="$3"
    _oru_avail="$4"

    if exakit_runtime_update_is_staged "$_oru_cur" "$_oru_avail"; then
        warn "$_oru_actual $_oru_cur -> $_oru_avail is a major upgrade: it needs a backup and a data migration, so a routine update does not start it."
        return 1
    fi

    case "$(exakit_runtime_update_preanswer)" in
        yes)
            exakit_runtime_update_explain "$_oru_actual" "$_oru_cur" "$_oru_avail"
            ;;
        no)
            warn "$_oru_actual $_oru_cur -> $_oru_avail was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
            info "Apply it when convenient:  exakit update"
            return 1
            ;;
        *)
            # No terminal, no answer: a prompt nobody can answer must never turn
            # into a stopped database, so a pipe, a CI job, a cron entry and a
            # scripted install all get exactly today's safe deferral.
            if ! exakit_stdin_is_tty; then
                warn "$_oru_actual $_oru_cur -> $_oru_avail needs the database stopped, so it is not part of a routine update."
                info "Apply it when convenient:  exakit update"
                info "Unattended runs can opt in:  exakit update --yes  (or EXAKIT_CONFIRM_RUNTIME_UPDATE=1)"
                return 1
            fi
            exakit_runtime_update_explain "$_oru_actual" "$_oru_cur" "$_oru_avail"
            if ! confirm "Stop the database and update the runtime now?" n; then
                info "Nothing was stopped. Apply it when convenient:  exakit update"
                return 1
            fi
            ;;
    esac

    exakit_apply_runtime_update "$_oru_component"
}

exakit_update() {
    # -y/--yes answers the runtime offer below and may appear anywhere in the
    # arguments; everything else keeps its position, so the target and the
    # Personal upgrade options arrive exactly as they did. Rebuilt by rotating
    # the positional parameters — no arrays, so bash 3.2 and dash both cope.
    _upd_assume_yes=0
    _upd_left="$#"
    while [ "$_upd_left" -gt 0 ]; do
        case "$1" in
            -y|--yes) _upd_assume_yes=1 ;;
            *) set -- "$@" "$1" ;;
        esac
        shift
        _upd_left=$((_upd_left - 1))
    done
    if [ "$_upd_assume_yes" = "1" ]; then
        # --yes answers the only question this command asks: may it stop the
        # database. The runtime updaters read the same variable, so an explicit
        # `exakit update runtime --yes` is unprompted for the same reason.
        EXAKIT_CONFIRM_RUNTIME_UPDATE=1
        export EXAKIT_CONFIRM_RUNTIME_UPDATE
    fi
    _target="${1:-all}"
    if [ "$#" -gt 0 ]; then shift; fi
    if [ "$#" -gt 0 ]; then
        case "$_target" in
            personal|runtime|database|db) ;;
            *) die "Update options are only supported for Personal runtime updates." ;;
        esac
    fi
    case "$_target" in
        -*) reject "Unknown option '$_target' for update (supported: --yes; a component name selects what to update)." ;;
    esac
    _targets="$(exakit_update_targets "$_target")" || reject "Unknown update target '$_target' (see: exakit version)"
    exakit_init_logging
    # An explicit update applies what is advertised right NOW, so ask upstream
    # once and resolve in this shell — the loop below reads the same document.
    if [ "${EXAKIT_VERSION_POLICY:-manifest}" = "manifest" ]; then
        exakit_versions_update_cache force >/dev/null 2>&1 || true
        exakit_versions_resolve_doc >/dev/null 2>&1 || true
    fi
    exakit_print_versions_source_line
    _deferred=0
    _acted=0
    for _component in $_targets; do
        # _upd_ prefix: verify_sha256 (reached through the component updaters)
        # assigns _actual, and bash has no function-local variables here.
        _upd_actual="$(exakit_update_actual_target "$_component" 2>/dev/null || printf '%s\n' "$_component")"
        _cur="$(exakit_component_current "$_upd_actual" 2>/dev/null || true)"
        _avail="$(exakit_component_available "$_upd_actual" 2>/dev/null || true)"
        # No build for this machine: a routine update stays quiet about it (there is
        # nothing the user can do), and an explicit target says why rather than
        # failing deep inside the installer.
        if ! exakit_component_supported "$_upd_actual"; then
            [ "$_target" = "all" ] && continue
            die "$_upd_actual has no build for this platform, so there is nothing to update."
        fi
        # Nothing advertised for this component (unreadable manifest, or a
        # component this kit knows nothing about): a routine update says so and
        # moves on. An explicit single target still runs, so its updater can
        # report the real reason.
        if [ "$_target" = "all" ] && [ -z "$_avail" ]; then
            warn "No advertised version for $_upd_actual — skipping it. Details: exakit version"
            continue
        fi
        # Never backwards, and this has to be settled BEFORE the heavy branch.
        # That branch gates on "$_cur" != "$_avail" and then continues, so it used
        # to reach the runtime offer with the installed version AHEAD of the
        # tested one and ask to stop the database for a downgrade -- while
        # `exakit version` rendered the same row as "none" and every light
        # component said "keeping yours". Different is not behind. Asked once
        # here, for every component, so no later branch can reach an update path
        # by skipping the question.
        if exakit_component_is_ahead "$_upd_actual"; then
            ok "$_upd_actual ${_cur:-unknown} is newer than the tested $_avail — keeping yours"
            continue
        fi
        # A blanket update stops the database only for an answer it was given: on a
        # terminal it asks, with a flag or the env var it was already told, and with
        # neither it defers exactly as it always did. See
        # exakit_offer_runtime_update.
        if [ "$_target" = "all" ] && exakit_component_is_heavy "$_upd_actual"; then
            if [ -n "$_cur" ] && [ -n "$_avail" ] && [ "$_cur" != "unknown" ] && [ "$_cur" != "$_avail" ]; then
                if exakit_offer_runtime_update "$_component" "$_upd_actual" "$_cur" "$_avail"; then
                    _acted=$((_acted + 1))
                else
                    _deferred=$((_deferred + 1))
                fi
            fi
            continue
        fi
        # Only the components this run will actually touch are reported: the work
        # plan, not a status table. `exakit version` is where everything is
        # listed, including what is already current.
        #
        # A marketplace add-on named EXPLICITLY is the exception: its update hook
        # is also its repair command (it rewrites the launcher a newer kit
        # improved, re-registers the boot entry, re-reads a changed DSN), so
        # `exakit update dash-server` must reach the module even when the version
        # already matches. `update all` still skips it — a routine update stays a
        # work plan, not a sweep of every component's repair path.
        if [ -n "$_cur" ] && [ -n "$_avail" ] && [ "$_cur" = "$_avail" ]; then
            if [ "$_target" = "all" ] || ! _exakit_addon_registered "$_component"; then
                continue
            fi
        fi
        # The table's "update exakit first" verdict has to hold here too, or the
        # manifest's only hard compatibility lever would be advice nobody applies.
        _upd_min_kit="$(exakit_component_min_kit "$_upd_actual" 2>/dev/null || true)"
        if [ -n "$_upd_min_kit" ] && ! exakit_min_kit_satisfied "$_upd_min_kit"; then
            warn "$_upd_actual $_avail needs kit >= $_upd_min_kit — update the kit first: exakit update"
            [ "$_target" = "all" ] && continue
            die "Refusing to install $_upd_actual $_avail on kit $(exakit_component_current exakit 2>/dev/null || printf unknown)."
        fi
        if [ -n "$_avail" ]; then
            info "$_upd_actual ${_cur:-not installed} -> $_avail"
        fi
        exakit_update_component "$_component" "$@"
        _acted=$((_acted + 1))
    done
    if [ "$_acted" -eq 0 ] && [ "$_deferred" -eq 0 ]; then
        ok "Everything is already current."
    fi
    if [ "$_deferred" -gt 0 ]; then
        info "See everything, including the deferred runtime change: exakit version"
    fi
    return 0
}

# step_done <name> — succeeds if the step is recorded in steps_completed.
step_done() {
    [ -f "$EXAKIT_MANIFEST" ] || return 1
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
sys.exit(0 if sys.argv[2] in doc.get("steps_completed", []) else 1)
PY
}

# _sas_launcher_on_path — true when a usable `exasol` is reachable on PATH.
# Helper for step_artifact_state's launcher case, held to the same bar: command
# -v is a PATH lookup and not an execution (rule 2 below), and the resolved
# launcher must be a non-empty executable file (rule 4). A `command -v` answer
# that is not a path at all (a shell function) fails those tests and counts as
# no launcher, which only ever means the step runs again.
_sas_launcher_on_path() {
    _sas_cli="$(command -v exasol 2>/dev/null || true)"
    [ -n "$_sas_cli" ] || return 1
    [ -x "$_sas_cli" ] && [ -s "$_sas_cli" ]
}

# step_artifact_state <step> — prints "present", "missing", or "unknown".
#
# The tick in steps_completed records that a step RAN once, not that what it
# produced is still on disk. A machine turned up with steps_completed:
# ["launcher"] and no ~/.local/bin/exasol, and every re-run then skipped the
# launcher step and failed the deployment step that needs it — the one step that
# could have repaired the install was the one being skipped. begin_step consults
# this so a completed step can be re-run when its artifact is gone.
#
# Three rules hold this function together:
#
#   1. "unknown" NEVER overrides the manifest. There is no cheap way to prove a
#      database deployment exists, and re-running the runtime step on a guess
#      would stop a working database — far worse than the bug this fixes. A
#      wrong "missing" is destructive; a wrong "unknown" just leaves today's
#      behaviour in place. Anything not cheaply provable is "unknown".
#   2. FILE TESTS ONLY. This runs once per step on every install, so no network,
#      no PyPI, no GitHub and above all nothing that could wake or probe a
#      launcher (a launcher still opening a deployment is why the kit's own probes are
#      bounded).
#   3. "present" means what the NEXT step will actually resolve. The launcher
#      case mirrors personal_cli(), which is what the deployment step calls.
#   4. EXECUTABLE IS NOT ENOUGH — it must also be non-empty. `[ -x ]` is true of
#      a 0-byte file with mode 755, which is exactly what an interrupted or
#      out-of-space install leaves behind, and running one is either an exec
#      failure or (worse) an empty script that "succeeds" without doing
#      anything. Every branch that judges a binary pairs `-x` with `-s`.
step_artifact_state() {
    case "$1" in
        launcher)
            if [ -z "${EXAKIT_PERSONAL_BIN:-}" ]; then
                # runtime-personal.sh is not loaded: this platform has no
                # launcher step, so there is nothing to judge.
                printf 'unknown\n'
            elif [ -x "$EXAKIT_PERSONAL_BIN" ]; then
                # personal_cli() prefers the kit-managed binary the moment it is
                # executable, so THIS file is what the deployment step will run —
                # even when it is a truncated 0-byte stub, and even when a good
                # launcher sits on PATH. Only a non-empty one is "present".
                if [ -s "$EXAKIT_PERSONAL_BIN" ]; then
                    printf 'present\n'
                else
                    printf 'missing\n'
                fi
            elif _sas_launcher_on_path; then
                # personal_install_launcher deliberately keeps an existing
                # launcher on PATH that supports the `local` preset instead of
                # installing its own, and personal_cli() then resolves that one —
                # so a launcher on PATH is "present" even with no kit-managed
                # binary. command -v is a PATH lookup, not an execution.
                #
                # RESIDUAL HOLE, stated plainly: this branch is not merely a
                # guard against a false "missing". An `exasol` on PATH that is
                # too OLD for the `local` preset, with the managed binary gone,
                # is reported "present" here, the launcher step is skipped, and
                # the deployment step fails again — the same forever-loop this
                # function exists to break, through a different door. Telling
                # the two apart means running `exasol install --help` (what
                # personal_install_launcher does), which rule 2 forbids at this
                # cost. The narrower, self-inflicted case is covered: the kit's
                # own managed binary is judged by the branch above, which no
                # PATH lookup can override.
                printf 'present\n'
            else
                printf 'missing\n'
            fi
            ;;
        exakit_helper)
            if [ -x "$EXAKIT_BIN_DIR/exakit" ] && [ -s "$EXAKIT_BIN_DIR/exakit" ]; then
                printf 'present\n'
            else
                printf 'missing\n'
            fi
            ;;
        exapump)
            # The install records the exact path it resolved. No record means an
            # older install (or a soft failure) we cannot judge: "unknown".
            _sas_path="$(manifest_get components.exapump.path 2>/dev/null || true)"
            if [ -z "$_sas_path" ]; then
                printf 'unknown\n'
            elif [ ! -x "$_sas_path" ] || [ ! -s "$_sas_path" ]; then
                printf 'missing\n'
            elif [ -n "${EXAPUMP_CONFIG:-}" ] && [ ! -s "$EXAPUMP_CONFIG" ]; then
                # THE BINARY IS NOT THE WHOLE STEP. The step also writes the
                # connection profile, and only the binary was ever checked — so a
                # profile that had been removed left the step "already done,
                # skipping" on every re-run while `exapump sql -p starter-kit`
                # answered "Profile 'starter-kit' not found in config" forever.
                # Re-running the installer is supposed to be the cure for that.
                EXAKIT_STEP_RERUN_REASON="the exapump connection profile is gone — writing it again"
                printf 'missing\n'
            else
                printf 'present\n'
            fi
            ;;
        runtime)
            # A deployed database is normally "unknown" by rule 1: a false
            # "missing" here redeploys and destroys data, so neither "stopped"
            # nor "unreachable" may ever answer it.
            #
            # ONE state is safe to call missing, and it is the one that used to
            # loop forever: a deployment the LAUNCHER ITSELF has recorded as
            # interrupted. That is not an opinion this function forms — it is a
            # flag the launcher wrote, and after it every start fails identically
            # ("local VM state contains invalid database port: 0"). The step was
            # skipped as done, the run then failed at start, and the closing
            # advice was to re-run the installer, which skipped it again. The
            # deployment step already knows how to try a start, watch it fail,
            # and replace the deployment; this is what lets it be reached.
            if command -v personal_deployment_wedged >/dev/null 2>&1 && \
               personal_deployment_wedged >/dev/null 2>&1; then
                EXAKIT_STEP_RERUN_REASON="the database is interrupted and cannot be started — rebuilding it"
                printf 'missing\n'
            else
                printf 'unknown\n'
            fi
            ;;
        *)
            # mcp, pyexasol and the kit2 asset steps: nothing a file test can
            # settle without risking a destructive false "missing". See rule 1.
            printf 'unknown\n'
            ;;
    esac
}

# mark_step <name> — records a completed step (idempotent). Completing a
# step also discards the undo entries registered during it: rollback only
# ever covers the step that actually failed, never a finished one (a late
# transient failure must not undo an earlier successful deployment).
mark_step() {
    require_python3
    _mks_err="$(run_python - "$EXAKIT_MANIFEST" "$1" 2>&1 >/dev/null <<'PY'
import fcntl, json, os, sys, tempfile

# Same lock + atomic-write pair as manifest_set (see there for the measurements).
# This writer had neither, and it is the one whose loss is felt most: a dropped
# step tick makes a re-run repeat work it had already finished, which is the
# whole promise of "completed steps are skipped". A shared "<path>.tmp" also let
# two writers interleave inside it. The PowerShell twin (Set-ExakitStepDone)
# takes the lock for the same reason.
def _exakit_locked(path):
    handle = open(path + ".lock", "a+")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle

def _exakit_write(path, doc):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle, indent=2)
            handle.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

path, step = sys.argv[1], sys.argv[2]
# Exit codes, not a traceback (see _exakit_manifest_write_error): 3 no manifest,
# 4 unreadable, 5 not writable.
if not os.path.exists(path):
    sys.exit(3)
try:
    _lock = _exakit_locked(path)
except OSError:
    sys.exit(5)
try:
    with open(path) as f:
        doc = json.load(f)
except FileNotFoundError:
    sys.exit(3)
except (OSError, ValueError):
    sys.exit(4)
steps = doc.setdefault("steps_completed", [])
if step not in steps:
    steps.append(step)
try:
    _exakit_write(path, doc)
except OSError:
    sys.exit(5)
PY
    )"
    _mks_rc=$?
    _exakit_manifest_log_stderr "$_mks_err"
    [ "$_mks_rc" -eq 0 ] || die "$(_exakit_manifest_write_error "$_mks_rc" "step $1")"
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && : > "$EXAKIT_ROLLBACK_FILE"
    _exakit_log_file "STEP  completed: $1"
}

# ---------------------------------------------------------------------------
# Rollback handling
#
# Steps register undo commands as they make changes. On failure the handler
# reports what failed and (interactively) offers to undo this run's changes.
# Completed runs discard their rollback stack — the manifest is then the
# source of truth for uninstall.
# ---------------------------------------------------------------------------
EXAKIT_ROLLBACK_FILE=""
EXAKIT_CURRENT_STEP=""

rollback_init() {
    EXAKIT_ROLLBACK_FILE="$(mktemp "${TMPDIR:-/tmp}/exakit-rollback.XXXXXX")"
}

# push_rollback <command...> — register an undo command for the current run.
push_rollback() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] || return 0
    printf '%s\n' "$*" >> "$EXAKIT_ROLLBACK_FILE"
}

run_rollback() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && [ -s "$EXAKIT_ROLLBACK_FILE" ] || return 0
    info "Rolling back this run's changes..."
    # Execute registered undo commands in reverse order.
    awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }' \
        "$EXAKIT_ROLLBACK_FILE" | while IFS= read -r cmd; do
        _exakit_log_file "UNDO  $cmd"
        sh -c "$cmd" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || \
            warn "A rollback step did not complete: $cmd — what it printed: exakit logs setup"
    done
    : > "$EXAKIT_ROLLBACK_FILE"
    ok "Rollback finished"
}

rollback_discard() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && rm -f "$EXAKIT_ROLLBACK_FILE"
    EXAKIT_ROLLBACK_FILE=""
}

# rollback_clear — forget the undo commands registered so far, keeping the stack
# itself live for the steps still to come.
#
# mark_step already does this as a side effect, which is right for a step that
# COMPLETED: its changes are permanent, and a failure three steps later must not
# reach back and undo them. A RESUME branch re-does that same work without a
# mark_step -- the step is already recorded as done, so there is nothing to
# record -- and the undo commands it registers therefore stay armed for the rest
# of the run. The database deploy registers `destroy --remove --auto-approve`,
# so a later die would offer to delete the database and everything loaded into
# it, under a prompt that calls it "the failed step's changes" when it belongs
# to a step that finished minutes ago.
#
# NOT rollback_discard: that drops the file and leaves the remainder of the run
# with no rollback at all.
rollback_clear() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && : > "$EXAKIT_ROLLBACK_FILE"
    return 0
}

# begin_step <name> <description> — announce a step; skips if already done AND
# what it installed is still there. Returns 1 when the step can be skipped
# (caller should honor it).
#
# A step is skipped only when the manifest tick and the disk agree. When the tick
# says done but step_artifact_state() proves the artifact is gone, the step is
# announced and run again — that is what makes "re-running the installer is safe
# and resumes" (AGENTS.md) true even after something removed an artifact from
# under a completed install.
# step_version_drift <step> — "installed X, this kit installs Y" when the
# component a step owns is behind what this run advertises, else empty.
#
# WHY A COMPLETED STEP MAY STILL HAVE WORK. A step tick means "this was
# installed", not "this is current". Re-running the installer over an older
# installation therefore skipped every step whose artifact was present, and the
# run finished having upgraded the kit and nothing else: exapump, the MCP
# server and pyexasol all stayed where the previous kit had left them. The user
# ran one command expecting an update and got a kit that now disagreed with its
# own components.
#
# Only a component that is genuinely BEHIND counts. Equal versions skip as they
# always did, and a component AHEAD of this kit is left alone rather than
# downgraded - a manifest can advertise an older set than a machine already has,
# and an installer is no place to argue about it.
step_version_drift() {
    case "$1" in
        launcher) _svd_id=personal;  _svd_want="${EXAKIT_PERSONAL_VERSION:-}" ;;
        exapump)  _svd_id=exapump;   _svd_want="${EXAKIT_EXAPUMP_VERSION:-}" ;;
        mcp)      _svd_id=mcp;       _svd_want="${EXAKIT_MCP_VERSION:-}" ;;
        pyexasol) _svd_id=pyexasol;  _svd_want="${EXAKIT_PYEXASOL_VERSION:-}" ;;
        *) return 1 ;;
    esac
    [ -n "$_svd_want" ] || return 1
    _svd_have="$(exakit_component_current "$_svd_id" 2>/dev/null || true)"
    [ -n "$_svd_have" ] || return 1
    [ "$_svd_have" != "unknown" ] || return 1
    exakit_version_newer "$_svd_want" "$_svd_have" || return 1
    printf '%s %s is installed and this kit installs %s — updating it\n' \
        "$_svd_id" "$_svd_have" "$_svd_want"
}

begin_step() {
    EXAKIT_CURRENT_STEP="$1"
    EXAKIT_ACTIVE_LABEL="$2"     # spinner label for run_logged inside this step
    # On disk too, best-effort: `exakit status` reads it back as "installing
    # (step X)" while the installer runs, which is the state an agent polling
    # from a second shell had no way to see. Cleared by exakit_finish. In a
    # subshell, because a manifest that cannot be written must not end the
    # step -- the note is a nicety.
    [ -f "$EXAKIT_MANIFEST" ] && ( manifest_set install.current_step "$1" ) >/dev/null 2>&1
    _bs_rerun=0
    # Cleared before every judgement so one step's reason cannot be reported
    # against the next; step_artifact_state sets it when it has a better
    # explanation than the generic "what it installed is missing".
    EXAKIT_STEP_RERUN_REASON=""
    if step_done "$1"; then
        # A tick says "installed", not "current". Ask about the version before
        # the artifact: a component that is merely BEHIND is present on disk,
        # so the artifact check would happily skip it.
        _bs_drift="$(step_version_drift "$1" 2>/dev/null || true)"
        if [ -n "$_bs_drift" ]; then
            EXAKIT_STEP_RERUN_REASON="$_bs_drift"
            _bs_rerun=1
        # "unknown" (and "present") keep the manifest's answer: only a proven
        # "missing" is allowed to override the tick.
        elif [ "$(step_artifact_state "$1")" = "missing" ]; then
            # Run the judgement AGAIN, in this shell, purely to recover
            # EXAKIT_STEP_RERUN_REASON: the call above is a command
            # substitution, so the variable it set died with the subshell and
            # every re-run reported the generic reason. The check is file tests
            # and a manifest read, so a second one costs nothing.
            step_artifact_state "$1" >/dev/null 2>&1
            _bs_rerun=1
        else
            # Step-level line (a whole step's status, not a nested outcome).
            printf '\n  %s%s%s %s%s%s %s— already done, skipping%s\n' \
                "${UI_OK:-}" "${UI_TICK:-[ok]}" "${UI_RESET:-}" \
                "${UI_BOLD:-}" "$2" "${UI_RESET:-}" "${UI_DIM:-}" "${UI_RESET:-}"
            _exakit_log_file "OK    $2 — already done, skipping"
            return 1
        fi
    fi
    # Styled step header: accent arrow + bold title, set off by a blank line.
    printf '\n  %s%s%s %s%s%s\n' \
        "${UI_ACCENT:-}" "${UI_ARROW:->}" "${UI_RESET:-}" \
        "${UI_BOLD:-}" "$2" "${UI_RESET:-}"
    _exakit_log_file "STEP  $2"
    if [ "$_bs_rerun" -eq 1 ]; then
        info "Recorded as done, but ${EXAKIT_STEP_RERUN_REASON:-what it installed is missing — running it again}"
    fi
    return 0
}

exakit_on_failure() {
    _status=$?
    # Runs on EXIT (any status). Stop any live spinner and un-hide the cursor
    # first, so a failure mid-animation never leaves a stuck/invisible cursor.
    ui_spin_end 2>/dev/null || true
    ui_restore_cursor
    # Same reason as the sweep below: a background prefetch is this run's
    # process, and a run that is ending does not get to leave one downloading.
    if command -v mcp_prefetch_stop >/dev/null 2>&1; then mcp_prefetch_stop 2>/dev/null || true; fi
    exakit_sweep_sensitive_tmp     # never leave credential temp files behind
    [ $_status -eq 0 ] && return 0
    # Same "card" shape as die(): prominent ✗ header, dim gutter details.
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" \
        "Setup failed${EXAKIT_CURRENT_STEP:+ during step: $EXAKIT_CURRENT_STEP}" "${UI_RESET:-}" >&2
    _exakit_log_file "ERROR Setup failed${EXAKIT_CURRENT_STEP:+ during step: $EXAKIT_CURRENT_STEP}"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf '    %s%s Log: %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$EXAKIT_LOG_FILE" "${UI_RESET:-}" >&2
    fi
    printf '    %s%s Re-running the installer is safe: completed steps are skipped.%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
    if [ "${EXAKIT_AUTO_ROLLBACK:-0}" = "1" ]; then
        run_rollback
    elif confirm "Undo the failed step's changes?" n; then
        run_rollback
    else
        info "Keeping partial progress. Re-run the installer to resume."
    fi
    rollback_discard
    exakit_release_lock
    exit $_status
}

# exakit_acquire_lock — one setup run at a time. A lock left behind by a
# dead process is detected and removed automatically.
EXAKIT_LOCK_FILE=""
exakit_acquire_lock() {
    _lock="$EXAKIT_HOME/.install.lock"
    mkdir -p "$EXAKIT_HOME"
    if [ -f "$_lock" ]; then
        _pid="$(sed -n 1p "$_lock" 2>/dev/null)"
        if exakit_lock_holder_alive "$_lock"; then
            die "Another setup run is already in progress (pid $_pid). Wait for it to finish; if you are sure it is dead, remove $_lock and re-run."
        fi
        warn "Found a lock from an interrupted run — removing it and continuing"
        rm -f "$_lock"
    fi
    # Line 1 the pid, line 2 the process start time. A pid alone is reused by
    # the OS, and a crashed installer's pid landing on an unrelated process kept
    # `exakit status` saying "installing" until that process exited.
    printf '%s\n%s\n' "$$" "$(exakit_process_start_time "$$")" > "$_lock"
    EXAKIT_LOCK_FILE="$_lock"
}

# exakit_process_start_time <pid> — the start time ps reports, trimmed; empty
# when ps cannot say. `lstart` is the one column macOS and Linux ps share.
exakit_process_start_time() {
    ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//' | head -n 1
}

# exakit_lock_holder_alive <lockfile> — true only when the pid in the lock is
# alive AND (if the lock recorded one) started when the lock says it did. An
# old one-line lock without a start time falls back to the pid check.
exakit_lock_holder_alive() {
    [ -f "${1:-}" ] || return 1
    _lha_pid="$(sed -n 1p "$1" 2>/dev/null)"
    _lha_start="$(sed -n 2p "$1" 2>/dev/null)"
    [ -n "$_lha_pid" ] || return 1
    kill -0 "$_lha_pid" 2>/dev/null || return 1
    [ -n "$_lha_start" ] || return 0
    [ "$(exakit_process_start_time "$_lha_pid")" = "$_lha_start" ]
}

exakit_release_lock() {
    [ -n "$EXAKIT_LOCK_FILE" ] && rm -f "$EXAKIT_LOCK_FILE"
    EXAKIT_LOCK_FILE=""
}

# Call once near the top of each setup script (after init_logging).
exakit_enable_failure_handling() {
    rollback_init
    exakit_acquire_lock
    trap exakit_on_failure EXIT
}

# Call at the very end of a successful run.
exakit_finish() {
    trap - EXIT
    # A prefetch that never got collected (the MCP step was skipped, or the run
    # is ending early) must not outlive the installer. No-op when there is none.
    if command -v mcp_prefetch_stop >/dev/null 2>&1; then mcp_prefetch_stop || true; fi
    rollback_discard
    exakit_release_lock
    EXAKIT_CURRENT_STEP=""
    [ -f "$EXAKIT_MANIFEST" ] && ( manifest_del install.current_step ) >/dev/null 2>&1
    return 0
}

# ---------------------------------------------------------------------------
# Downloads and verification
# ---------------------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1. $2"
}

# fetch <url> <dest-file>
# Runs curl silently (-sS) under the kit's braille spinner so downloads animate
# consistently with every other step, instead of curl's own hash progress bar.
# The spinner no-ops on non-interactive terminals, so logs/CI stay clean.
fetch() {
    _url="$1"
    _dest="$2"
    mkdir -p "$(dirname "$_dest")"
    _exakit_log_file "GET   $_url -> $_dest"
    ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-downloading $(basename "$_dest")}"
    # BOUNDED, AND RESUMABLE. --connect-timeout only caps the handshake: a server
    # that accepts and then stalls held this forever, times four with --retry,
    # and the spinner no-ops without a TTY so there was no progress signal
    # either. Seen for real as curl exit 92 on a 189 MB asset after 423s.
    # --speed-limit/--speed-time abandons a transfer that has genuinely stopped
    # moving rather than one that is merely slow; -C - resumes instead of
    # restarting from byte zero; --retry-all-errors covers the transport errors
    # plain --retry does not (curl 7.71+, hence the capability probe).
    curl -fL --proto '=https' --retry 3 $(_exakit_curl_retry_all) --connect-timeout 15 \
        --speed-limit 1024 --speed-time 60 -C - \
        -sS -o "$_dest" "$_url"
    _fetch_rc=$?
    ui_spin_end
    if [ "$_fetch_rc" -ne 0 ]; then
        rm -f "$_dest"
        error "Download failed: $_url"
        printf '      %s%s Check your internet connection. Behind a corporate proxy, set%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        printf '      %s%s HTTPS_PROXY (curl honors it) and re-run. If the URL looks wrong,%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        printf '      %s%s a version override (EXAKIT_*_VERSION) may point at a missing release.%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        die "Could not download $(basename "$_dest")"
    fi
}

# fetch_quiet <url> <dest-file>
# A fetch whose chatter goes to the logfile and whose failure is soft: it
# returns non-zero where fetch would die.
#
# Callers used to write this themselves as `( fetch ... ) >> "$LOG" 2>&1`, which
# silenced more than it meant to: ui_spin_begin animates only while stdout is a
# terminal, so redirecting the subshell sent the SPINNER to the logfile too and
# every add-on download sat on screen as a still line for as long as it took.
# Starting the spinner out here, before the redirect, is what gives those
# downloads their "something is happening" back. Clearing _UI_SPIN_PID inside
# the subshell matters just as much: fetch ends with its own ui_spin_end, and
# with the parent's pid still visible it would kill this spinner on the way in.
fetch_quiet() {
    ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-downloading $(basename "$2")}"
    ( _UI_SPIN_PID=''; fetch "$1" "$2" ) >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
    _fq_rc=$?
    ui_spin_end
    return "$_fq_rc"
}

# sha256_of <file>
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "Cannot verify downloads: neither shasum nor sha256sum is installed. Install coreutils (Debian/Ubuntu: apt install coreutils; Fedora/RHEL: dnf install coreutils), then re-run the installer."
    fi
}

# verify_sha256 <file> <expected-hash>
verify_sha256() {
    _actual="$(sha256_of "$1")"
    if [ "$_actual" != "$2" ]; then
        error "Checksum mismatch for $(basename "$1")"
        error "  expected: $2"
        error "  actual:   $_actual"
        die "The download does not match the checksum the kit expects, so it will not be used. This is usually an interrupted or proxy-modified download - re-run the installer to fetch it again. If it keeps failing, report it with the two hashes above."
    fi
    ok "Checksum verified: $(basename "$1")"
}

# verify_sha256_from_file <file> <checksums.txt> — looks the file up by name.
verify_sha256_from_file() {
    _name="$(basename "$1")"
    _expected="$(awk -v f="$_name" '$2 == f || $2 == "*"f {print $1; exit}' "$2")"
    [ -n "$_expected" ] || die "No checksum entry for $_name in $(basename "$2")"
    verify_sha256 "$1" "$_expected"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# ensure_path_hint <dir> — make dir usable on PATH without sudo: fix the
# current process immediately, then persist the export in the user's own
# shell profile (their file, their permissions — never /etc, never root).
# Mirrors the Windows side, which has always persisted the user PATH via
# [Environment]::SetEnvironmentVariable(..., "User") in exakit-common.ps1.
# Idempotent: the marker comment keeps re-runs from stacking duplicates.
# EXAKIT_NO_PROFILE_EDIT=1 restores the old print-a-hint-only behavior.
ensure_path_hint() {
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
    esac
    # Fix the running install right away so later steps can call the kit's
    # CLIs by name; the profile edit below covers future sessions.
    PATH="$1:$PATH"
    export PATH

    if [ "${EXAKIT_NO_PROFILE_EDIT:-0}" = "1" ]; then
        warn "$1 is not on your PATH."
        printf '      %s%s Add this to your shell profile:%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        printf '      %s%s%s   export PATH="%s:$PATH"\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" "$1" >&2
        return 0
    fi

    # The user's interactive shell decides which profile matters; fish has
    # no POSIX profile, so it keeps the printed hint instead of a bad edit.
    _eph_shell="$(basename "${SHELL:-}")"
    # An empty $SHELL (cron, `env -i`, some CI images) used to fall through to
    # the catch-all and write ~/.profile, which zsh does not read either.
    # macOS has shipped zsh as the default login shell since Catalina, so that
    # is the honest guess there rather than a file nobody sources.
    if [ -z "$_eph_shell" ] && [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        _eph_shell="zsh"
    fi
    case "$_eph_shell" in
        zsh)  _eph_profile="$HOME/.zshrc" ;;
        bash)
            # macOS Terminal.app and iTerm2 start bash as a LOGIN shell, which
            # reads ~/.bash_profile (or ~/.profile) and NEVER ~/.bashrc. Writing
            # .bashrc there earned a green tick for an edit no new terminal
            # would ever read. Linux terminals start non-login interactive bash,
            # which does read .bashrc, so only macOS diverges.
            if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
                if [ -f "$HOME/.bash_profile" ] || [ ! -f "$HOME/.profile" ]; then
                    _eph_profile="$HOME/.bash_profile"
                else
                    _eph_profile="$HOME/.profile"
                fi
            else
                _eph_profile="$HOME/.bashrc"
            fi
            ;;
        fish)
            warn "$1 is not on your PATH. For fish, run: fish_add_path $1"
            return 0
            ;;
        *)    _eph_profile="$HOME/.profile" ;;
    esac

    _eph_marker="# Added by the Exasol Personal Local Starter Kit (exakit CLIs)"
    if [ -f "$_eph_profile" ] && grep -qF "$_eph_marker" "$_eph_profile"; then
        # Already persisted by an earlier run; this session just hasn't
        # sourced it (covered by the export above).
        return 0
    fi
    if { printf '\n%s\nexport PATH="%s:$PATH"\n' "$_eph_marker" "$1" >> "$_eph_profile"; } 2>/dev/null; then
        ok "Added $1 to your PATH in $_eph_profile - new terminals pick it up. To undo, delete the two lines marked \"Added by the Exasol Personal Local Starter Kit\"; EXAKIT_NO_PROFILE_EDIT=1 skips this edit."
    else
        warn "$1 is not on your PATH and $_eph_profile is not writable. Add this to your shell profile:"
        printf '      %s%s%s   export PATH="%s:$PATH"\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" "$1" >&2
    fi
}

# exakit_unsigned_binary_hint <path> <exit-status> — the macOS diagnosis for a
# freshly downloaded binary that was KILLED instead of run. Prints nothing and
# returns 1 when that is not what happened.
#
# On Apple silicon the kernel refuses to execute an arm64 Mach-O that carries no
# code signature at all: the process dies on SIGKILL (137) with nothing on
# stderr. Every probe downstream then reads that silence as an answer — the
# launcher capability probe concludes "this launcher version has no explicit
# start command" — so the one thing nobody is told is that the binary never ran.
# Quarantine is NOT this: curl does not set com.apple.quarantine, so no `xattr`
# step is needed or offered here.
exakit_unsigned_binary_hint() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 1
    case "${2:-}" in
        137|9) ;;
        *) return 1 ;;
    esac
    error "$1 was installed but the kernel killed it on its first run (SIGKILL, no output)."
    info "On Apple silicon that is a code-signature problem in the downloaded release, not a problem with this machine."
    info "Confirm it with: codesign -dv \"$1\"   (\"code object is not signed at all\" is the signature failure)"
    info "That is a broken release and worth reporting. An ad-hoc signature unblocks you locally: codesign -s - \"$1\""
    return 0
}

exakit_repo_root() {
    if [ -d "$EXAKIT_HOME/kit/mcp" ]; then
        printf '%s\n' "$EXAKIT_HOME/kit"
        return 0
    fi
    _common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _repo_root="$(cd "$_common_dir/../.." && pwd)"
    if [ -d "$_repo_root/mcp" ]; then
        printf '%s\n' "$_repo_root"
        return 0
    fi
    # When this finds nothing the callers print "Could not find the MCP package
    # source ..." and stop, and until now that was the whole record: the screen did
    # not say where it looked and neither did the log, so a report of it from a
    # machine nobody can reach was not something that could be diagnosed. The
    # failure is rare enough to be worth one log line and quiet enough not to earn
    # a second line on screen.
    _exakit_log_file "WARN  no mcp/ under $EXAKIT_HOME/kit or $_repo_root"
    return 1
}

# ---------------------------------------------------------------------------
# Skills registry
# ---------------------------------------------------------------------------
# The registry is the FILESYSTEM, not a hardcoded list: every directory under
# skills/ carrying a SKILL.md is a skill, and its identity comes from that
# file's own frontmatter. Adding a skill therefore stays a one-folder change
# with no code edit anywhere — the property skills/README.md promises. A
# hardcoded list here would quietly take that away, so tests/skills.sh asserts
# no skill name is ever hardcoded in this file.

EXAKIT_SKILL_ROOTS="${EXAKIT_SKILL_ROOTS:-$HOME/.claude/skills $HOME/.agents/skills}"

# exakit_skills_dir — the kit's skills/ source directory.
exakit_skills_dir() {
    _sd_root="$(exakit_repo_root)" || return 1
    [ -d "$_sd_root/skills" ] || return 1
    printf '%s\n' "$_sd_root/skills"
}

# exakit_skill_field <skill-md> <field> — one value out of the YAML
# frontmatter. Deliberately tiny: the frontmatter this reads is the two flat
# keys the SKILL.md standard defines (name, description), so a real YAML parser
# would be a dependency bought for nothing.
exakit_skill_field() {
    awk -v want="$2" '
        NR == 1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        {
            key = want ": "
            if (index($0, key) == 1) { print substr($0, length(key) + 1); exit }
        }
    ' "$1" 2>/dev/null
}

# exakit_skill_addon <skill-md> — the marketplace add-on that OWNS this skill,
# or empty for a core one.
#
# Declared in the skill's own frontmatter ("addon: dash-server"), NOT inferred
# from the folder name. The three add-on skills happen to be named after their
# add-ons today, so a convention would work by luck; it would also silently
# capture any future core skill that happened to share a name with an add-on,
# and it could not survive either side being renamed. A declared owner says the
# thing out loud to anyone opening the file, and it keeps the registry in the
# filesystem where skills/README.md promises it is — the shell still names no
# skill.
exakit_skill_addon() {
    exakit_skill_field "$1" addon
}

# _exakit_skill_gating_addon <skill-name> — the add-on that gates this skill
# and is NOT installed; empty when the skill is not gated, or the gate is open.
_exakit_skill_gating_addon() {
    _sga_dir="$(exakit_skills_dir 2>/dev/null)" || return 0
    [ -f "$_sga_dir/$1/SKILL.md" ] || return 0
    _sga_owner="$(exakit_skill_addon "$_sga_dir/$1/SKILL.md" 2>/dev/null || true)"
    [ -n "$_sga_owner" ] || return 0
    exakit_marketplace_addon_installed "$_sga_owner" 2>/dev/null && return 0
    printf '%s\n' "$_sga_owner"
}

# exakit_skills_for_addon <addon-id> — the skill folder names that add-on owns.
exakit_skills_for_addon() {
    _sfa_dir="$(exakit_skills_dir)" || return 0
    for _sfa_path in "$_sfa_dir"/*/; do
        [ -f "$_sfa_path/SKILL.md" ] || continue
        [ "$(exakit_skill_addon "$_sfa_path/SKILL.md")" = "$1" ] || continue
        printf '%s\n' "$(basename "$_sfa_path")"
    done
    return 0
}

# _exakit_skill_wanted <skill-md> — does this skill belong on the machine now?
# A core skill always does. An add-on's skill does only once its add-on is
# installed: a skill for something the reader does not have is a set of triggers
# an agent can match on for a tool that is not there.
_exakit_skill_wanted() {
    _skw_owner="$(exakit_skill_addon "$1")"
    [ -n "$_skw_owner" ] || return 0
    exakit_marketplace_addon_installed "$_skw_owner" 2>/dev/null
}

# _exakit_skill_place <src-dir> <name> — copy one skill into every discovery
# root, replacing whatever is there.
_exakit_skill_place() {
    for _skp_root in $EXAKIT_SKILL_ROOTS; do
        rm -rf "$_skp_root/$2"
        mkdir -p "$_skp_root/$2"
        cp -R "$1". "$_skp_root/$2/"
    done
}

# _exakit_skill_unplace <name> — take one skill back out of every root.
_exakit_skill_unplace() {
    for _sku_root in $EXAKIT_SKILL_ROOTS; do
        [ -e "$_sku_root/$1" ] || continue
        rm -rf "$_sku_root/$1"
    done
}

# _exakit_skills_record_installed — write components.skills.installed by LOOKING
# at the discovery roots, rather than by counting what a particular call copied.
#
# That list is what a full uninstall removes, so it has to stay true as add-ons
# come and go — and three different paths now change it (the skills step, an
# add-on install, an add-on removal). Derived state cannot drift the way three
# separate bookkeeping updates can.
_exakit_skills_record_installed() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    _sri_dir="$(exakit_skills_dir)" || return 0
    _sri_json=""
    for _sri_path in "$_sri_dir"/*/; do
        [ -f "$_sri_path/SKILL.md" ] || continue
        _sri_name="$(basename "$_sri_path")"
        [ "$(exakit_skill_state "$_sri_name")" = "available" ] && continue
        _sri_json="${_sri_json:+$_sri_json,}\"$_sri_name\""
    done
    # The version of the files that were COPIED, read from the kit copy they
    # came from -- not the advertised version. Recording the advertised one is
    # how skills-install came to write the new number over the old files it had
    # just placed, after which `exakit skills` saw no drift at all.
    manifest_set components.skills.version \
        "$(exakit_skills_local_version 2>/dev/null || exakit_versions_value components.skills.version 2>/dev/null || printf 'unknown')"
    manifest_set components.skills.installed "[$_sri_json]"
}

# exakit_install_addon_skills <addon-id> — place the skills that add-on owns.
# Called from the generic marketplace install path, so a new add-on that ships a
# skill needs no wiring: declaring the owner in its SKILL.md is the whole change.
exakit_install_addon_skills() {
    _ias_dir="$(exakit_skills_dir)" || return 0
    _ias_n=0
    for _ias_name in $(exakit_skills_for_addon "$1"); do
        [ -f "$_ias_dir/$_ias_name/SKILL.md" ] || continue
        _exakit_skill_place "$_ias_dir/$_ias_name/" "$_ias_name"
        _exakit_log_file "OK    Installed skill: $_ias_name (with $1)"
        _ias_n=$((_ias_n + 1))
    done
    [ "$_ias_n" -gt 0 ] || return 0
    _exakit_skills_record_installed
    return 0
}

# exakit_remove_addon_skills <addon-id> — take them back out again. A skill left
# behind after its add-on is gone still advertises triggers for a tool that is
# no longer on the machine, which is worse than never having shipped it.
exakit_remove_addon_skills() {
    _ras_n=0
    for _ras_name in $(exakit_skills_for_addon "$1"); do
        _exakit_skill_unplace "$_ras_name"
        _ras_n=$((_ras_n + 1))
    done
    [ "$_ras_n" -gt 0 ] || return 0
    _exakit_skills_record_installed
    return 0
}

# exakit_skill_summary <description> — the one-line gist for a list row. The
# full description is written for an AGENT to match on (long, trigger-laden);
# a human scanning a table wants the first sentence, so cut the trigger list
# and then the first sentence, and truncate on a word boundary.
exakit_skill_summary() {
    _ss_text="$1"
    case "$_ss_text" in *"Triggers"*) _ss_text="${_ss_text%%Triggers*}" ;; esac
    case "$_ss_text" in *". "*) _ss_text="${_ss_text%%". "*}" ;; esac
    # Trim trailing separators and whitespace left by either cut above.
    _ss_text="$(printf '%s' "$_ss_text" | sed 's/[[:space:]]*[—-]*[[:space:]]*$//')"
    printf '%s' "$_ss_text" | awk '{
        if (length($0) <= 64) { print; exit }
        out = ""
        n = split($0, words, " ")
        for (i = 1; i <= n; i++) {
            if (length(out) + length(words[i]) + 1 > 61) break
            out = (out == "" ? words[i] : out " " words[i])
        }
        # A dangling connector reads as a truncation bug rather than an
        # ellipsis, so drop one if the cut landed on it.
        sub(/[[:space:]]*(—|-|,|:)$/, "", out)
        print out "..."
    }'
}

# exakit_skills_registry — one line per skill: id|summary. Skills whose
# frontmatter does not parse are skipped here, so they are skipped everywhere
# (list AND install read this one function).
exakit_skills_registry() {
    _sr_dir="$(exakit_skills_dir)" || return 1
    for _sr_path in "$_sr_dir"/*/; do
        [ -f "$_sr_path/SKILL.md" ] || continue
        _sr_name="$(exakit_skill_field "$_sr_path/SKILL.md" name)"
        [ -n "$_sr_name" ] || continue
        _sr_desc="$(exakit_skill_field "$_sr_path/SKILL.md" description)"
        printf '%s|%s\n' "$_sr_name" "$(exakit_skill_summary "$_sr_desc")"
    done
}

# exakit_skill_state <id> — installed (in every discovery root), partial (in
# some), or available (in none). "partial" is worth its own word: it is what a
# half-finished install or a hand-deleted copy looks like, and the remedy
# differs from a clean "never installed".
exakit_skill_state() {
    _sks_have=0
    _sks_total=0
    for _sks_root in $EXAKIT_SKILL_ROOTS; do
        _sks_total=$((_sks_total + 1))
        [ -f "$_sks_root/$1/SKILL.md" ] && _sks_have=$((_sks_have + 1))
    done
    if [ "$_sks_have" -eq 0 ]; then
        printf 'available\n'
    elif [ "$_sks_have" -eq "$_sks_total" ]; then
        printf 'installed\n'
    else
        printf 'partial\n'
    fi
}

# exakit_skills_list [--json] — what skills this kit carries and whether each
# one has reached the agents' discovery folders.
exakit_skills_list() {
    if ! exakit_skills_dir >/dev/null 2>&1; then
        warn "No skills/ directory in this kit build — nothing to list."
        return 1
    fi

    if [ "${1:-}" = "--json" ] || [ "${1:-}" = "-j" ]; then
        _skl_first=1
        printf '{"skills":['
        while IFS='|' read -r _skl_id _skl_sum; do
            [ -n "$_skl_id" ] || continue
            [ "$_skl_first" -eq 1 ] || printf ','
            _skl_first=0
            _skl_state="$(exakit_skill_state "$_skl_id")"
            _skl_owner="$(_exakit_skill_gating_addon "$_skl_id")"
            # An add-on's skill is never "available" to skills-install — that
            # command deliberately skips it, so calling it available
            # prescribed a command that cannot change it. It arrives with its
            # add-on, and the state says so, naming whose it is.
            if [ "$_skl_state" = "available" ] && [ -n "$_skl_owner" ]; then
                printf '{"name":"%s","state":"needs-addon","addon":"%s","remedy":"exakit marketplace %s","summary":"%s"}' \
                    "$_skl_id" "$_skl_owner" "$_skl_owner" \
                    "$(printf '%s' "$_skl_sum" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            else
                printf '{"name":"%s","state":"%s","summary":"%s"}' \
                    "$_skl_id" "$_skl_state" \
                    "$(printf '%s' "$_skl_sum" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            fi
        done <<EXAKIT_SKL_EOF
$(exakit_skills_registry)
EXAKIT_SKL_EOF
        # The same verdict the panel prints, as data: which set is placed,
        # which is advertised, and the one command to run if they differ or a
        # placed skill has gone missing. Nothing here touches the network -
        # the advertised number comes from the cached versions document.
        _skj_have="$(manifest_get components.skills.version 2>/dev/null || true)"
        _skj_want="$(exakit_versions_value components.skills.version 2>/dev/null || true)"
        _skj_missing=0
        while IFS='|' read -r _skj_id _skj_sum; do
            [ -n "$_skj_id" ] || continue
            # An add-on-gated skill whose add-on is absent is not MISSING:
            # skills-install cannot place it, so counting it would prescribe a
            # command that changes nothing, forever.
            [ "$(exakit_skill_state "$_skj_id")" = "installed" ] || \
                [ -n "$(_exakit_skill_gating_addon "$_skj_id")" ] || \
                _skj_missing=$((_skj_missing + 1))
        done <<EXAKIT_SKJ_EOF
$(exakit_skills_registry)
EXAKIT_SKJ_EOF
        _skj_status="current"; _skj_next="null"
        if [ -n "$_skj_have" ] && [ -n "$_skj_want" ] && [ "$_skj_have" != "$_skj_want" ]; then
            _skj_status="update_pending"; _skj_next='"exakit update"'
        elif [ "$_skj_missing" -gt 0 ]; then
            _skj_status="missing"; _skj_next='"exakit skills-install"'
        fi
        printf '],"installed_version":%s,"advertised_version":%s,"status":"%s","next":%s}\n' \
            "$([ -n "$_skj_have" ] && printf '"%s"' "$_skj_have" || printf null)" \
            "$([ -n "$_skj_want" ] && printf '"%s"' "$_skj_want" || printf null)" \
            "$_skj_status" "$_skj_next"
        return 0
    fi

    _skl_count=0
    _skl_pending=0
    printf '\n'
    ui_panel_begin "Exasol skills"
    while IFS='|' read -r _skl_id _skl_sum; do
        [ -n "$_skl_id" ] || continue
        _skl_state="$(exakit_skill_state "$_skl_id")"
        # An add-on's skill arrives with its add-on; "available" beside advice
        # to run skills-install prescribed a command that deliberately skips
        # it. Say whose it is instead, and leave it out of the pending count
        # the advice below is computed from.
        _skl_owner="$(_exakit_skill_gating_addon "$_skl_id")"
        if [ "$_skl_state" = "available" ] && [ -n "$_skl_owner" ]; then
            _skl_state="with $_skl_owner"
        elif [ "$_skl_state" != "installed" ]; then
            _skl_pending=$((_skl_pending + 1))
        fi
        ui_panel_line "$(printf '%-26s %-22s %s' "$_skl_id" "$_skl_state" "$_skl_sum")"
        _skl_count=$((_skl_count + 1))
    done <<EXAKIT_SKL_EOF
$(exakit_skills_registry)
EXAKIT_SKL_EOF

    if [ "$_skl_count" -eq 0 ]; then
        ui_panel_line "No SKILL.md files found in this kit copy."
        ui_panel_end
        printf '\n'
        return 1
    fi

    ui_panel_line ""
    # Stale beats pending in the advice: copies that exist but predate a kit
    # update are the case a user cannot see for themselves, and the remedy is
    # the same command either way.
    _skl_have="$(manifest_get components.skills.version 2>/dev/null || true)"
    _skl_want="$(exakit_versions_value components.skills.version 2>/dev/null || true)"
    if [ -n "$_skl_have" ] && [ -n "$_skl_want" ] && [ "$_skl_have" != "$_skl_want" ]; then
        ui_panel_line "Installed skill set $_skl_have; the kit advertises $_skl_want."
        ui_panel_line "Fetch and install them:  exakit update"
    elif [ "$_skl_pending" -gt 0 ]; then
        ui_panel_line "Install or refresh every skill:  exakit skills-install"
    fi
    # Nothing when everything is installed and current. "All installed. Refresh
    # after a kit update: exakit skills-install" stood here, telling the reader
    # to watch for a condition this panel already watches for them -- the branch
    # above detects a stale skill set and names both versions.
    ui_panel_line "Agents load a skill only when its triggers match your request."
    ui_panel_end
    printf '\n'
    return 0
}

# exakit_stray_launchers — superseded launcher copies the kit set aside during an
# upgrade (exasol.backup-<epoch>). Each is a full ~130 MB binary and nothing
# reported them, so they accumulated invisibly and no command reclaimed the disk.
# Prints one absolute path per line; silent when there are none.
exakit_stray_launchers() {
    [ -d "${EXAKIT_BIN_DIR:-}" ] || return 0
    for _sl in "$EXAKIT_BIN_DIR"/exasol.backup-*; do
        [ -f "$_sl" ] || continue
        printf '%s\n' "$_sl"
    done
}

# exakit_install_skills — copy the kit's AI skills into the per-user discovery
# folders so CLI agents auto-load them. Idempotent: each run replaces the
# managed copy of every skill, so edits and deletions propagate cleanly.
#   ~/.claude/skills/<name>/   — Claude Code
#   ~/.agents/skills/<name>/   — Codex, Cursor, other open-standard agents
exakit_install_skills() {
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not locate the kit to find its skills/ directory."
        return 1
    }
    _skills_src="$_repo_root/skills"
    if [ ! -d "$_skills_src" ]; then
        warn "No skills/ directory in this kit build yet — nothing to install."
        return 1
    fi

    _installed=0
    for _skill_dir in "$_skills_src"/*/; do
        [ -f "$_skill_dir/SKILL.md" ] || continue
        # Frontmatter that does not parse is skipped HERE as well as in the
        # listing: a skill an agent cannot identify is not one worth copying,
        # and installing what `exakit skills` refuses to show would be a lie.
        [ -n "$(exakit_skill_field "$_skill_dir/SKILL.md" name)" ] || {
            warn "Skipping $(basename "$_skill_dir"): its SKILL.md has no readable name in the frontmatter."
            continue
        }
        # An add-on's skill waits for its add-on. It is placed by the add-on
        # install instead, so a reader who never opens the marketplace is not
        # given triggers for three tools they do not have -- and a reader who
        # installs one later gets its skill as part and parcel of that install.
        # On a refresh (exakit skills-install after a kit update) this is also
        # what keeps the add-ons you DO have up to date without resurrecting the
        # ones you removed.
        _exakit_skill_wanted "$_skill_dir/SKILL.md" || continue
        _name="$(basename "$_skill_dir")"
        _exakit_skill_place "$_skill_dir" "$_name"
        # The names go to the logfile, not the screen: nine ticked lines say
        # nothing the count does not, and `exakit skills` lists them any time.
        _exakit_log_file "OK    Installed skill: $_name"
        _installed=$((_installed + 1))
    done

    if [ "$_installed" -eq 0 ]; then
        warn "No SKILL.md files found under $_skills_src — nothing to install."
        return 1
    fi
    ok "Installed $_installed AI skill$([ "$_installed" = 1 ] || printf 's') for Claude Code (~/.claude/skills) and open-standard agents (~/.agents/skills)"

    # A skill the NEW set no longer carries leaves the discovery roots with the
    # update: it was placed by the kit — the manifest's installed list is the
    # proof — and left behind it keeps firing its triggers forever for a
    # workflow this kit no longer ships. Only recorded names are touched; the
    # roots also hold skills the user installed themselves, which the kit must
    # never remove.
    _isk_prev="$(manifest_get components.skills.installed 2>/dev/null | tr -d '[]"' | tr ',' ' ')"
    _isk_retired=0
    for _isk_name in $_isk_prev; do
        [ -n "$_isk_name" ] || continue
        [ -f "$_skills_src/$_isk_name/SKILL.md" ] && continue
        _exakit_skill_unplace "$_isk_name"
        _exakit_log_file "OK    Retired skill: $_isk_name (no longer in the kit's skill set)"
        _isk_retired=$((_isk_retired + 1))
    done
    [ "$_isk_retired" -gt 0 ] && \
        ok "Retired $_isk_retired skill$([ "$_isk_retired" = 1 ] || printf 's') the new set no longer carries"

    # Record what was placed and which skill-set version it came from. This is
    # the only honest source for two later questions: which skill directories
    # are OURS to remove at uninstall time (the discovery folders also hold
    # skills the user installed themselves, which the kit must never touch),
    # and whether the installed copies have gone stale behind a kit update.
    _exakit_skills_record_installed

    exakit_report_readonly_allowlist
    info "Restart or reload your AI client to pick them up."
    return 0
}

# exakit_report_readonly_allowlist — apply the allowlist and say what happened.
# Split out of exakit_install_skills so the friction fix does not depend on the
# skills copy succeeding: when a staging fault meant no skill was ever placed,
# this never ran either, and every prompt the doc promises to remove kept being
# asked. The two are independent remedies and now fail independently.
exakit_report_readonly_allowlist() {
    # Claude Code reads ~/.claude/settings.json. Other agents keep the doc:
    # their settings formats differ and hand-editing them would be presumptuous.
    _skills_applied="$(exakit_apply_readonly_allowlist 2>/dev/null || true)"
    case "$_skills_applied" in
        # ADDED 0 is the nothing-changed branch, so it fired on every re-run to
        # report that nothing happened. The branch below, where commands really
        # are allowlisted, still says so.
        ADDED\ 0) _exakit_log_file "INFO  Read-only command allowlist already present in ~/.claude/settings.json." ;;
        ADDED\ *) ok "Read-only exakit commands allowlisted in ~/.claude/settings.json (status, info, version, mcp-doctor, logs, catalog, preflight, guide, mcp-status, skills; uninstall stays gated)." ;;
        SKIP*)    warn "~/.claude/settings.json could not be merged safely ($_skills_applied) — the allowlist in skills/reducing-agent-prompts.md shows what to add by hand." ;;
    esac
    return 0
}

# exakit_apply_readonly_allowlist — make the documented friction-reduction
# real. skills/reducing-agent-prompts.md tells Claude Code users which
# read-only exakit commands are safe to allow without a prompt; copying a doc
# nobody hand-applies eliminates zero prompts, so skills-install merges that
# same allowlist into ~/.claude/settings.json itself.
#
# The merge is strictly ADDITIVE and idempotent: existing settings are kept
# byte for byte, entries already present are not duplicated, nothing is ever
# removed, and a malformed or unreadable settings file is left alone (warn,
# not clobber). The list deliberately covers only read-only commands — exapump
# and SQL execution keep prompting, exactly as the doc explains — plus a deny
# for uninstall so an agent can never remove the kit unprompted.
exakit_apply_readonly_allowlist() {
    exakit_can_run_python || return 0
    _ral_file="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude" 2>/dev/null || return 0
    run_python - "$_ral_file" <<'EXAKIT_RAL_PY'
import json, os, sys

path = sys.argv[1]

# The kit's read-only command surface. Leaving any of these out is what kept the
# friction real: an agent following AGENTS.md is told to discover commands with
# `exakit catalog` and to check its footing with `version` / `mcp-status`,
# and every one of those asked for approval while changing nothing. `exapump sql`
# and every mutating command stay absent on purpose — that gate is the trust
# model.
READONLY = [
    "status", "info", "version", "mcp-doctor", "logs", "catalog", "preflight",
    "guide", "mcp-status", "help",
]

# EVERY SPELLING THE AGENT IS TOLD TO USE. A permission rule matches the command
# text, and AGENTS.md tells agents in as many words that ~/.local/bin is absent
# from a bare non-interactive PATH and to call the binary by absolute path. So
# the bare-`exakit` rules covered exactly the invocation the docs steer agents
# AWAY from, and every "read-only" command kept prompting anyway — the two halves
# of the kit's own advice cancelling out. All three spellings are listed now.
PREFIXES = ["exakit", "~/.local/bin/exakit", "$HOME/.local/bin/exakit"]

ALLOW = []
for prefix in PREFIXES:
    for command in READONLY:
        ALLOW.append("Bash(%s %s:*)" % (prefix, command))
    # Exact forms, deliberately NOT "exakit skills:*": that prefix would also
    # match `exakit skills-install`, which writes this very settings file. An
    # allowlisted command that can add allowlist entries is an escalation path,
    # so the listing is allowed and the install still asks.
    ALLOW.append("Bash(%s skills)" % prefix)
    ALLOW.append("Bash(%s skills --json)" % prefix)
ALLOW.append("mcp__exasol")

# The deny needs every spelling too, for the opposite reason: a rule that only
# names the bare form is trivially sidestepped by the absolute path the docs
# recommend.
DENY = ["Bash(%s uninstall:*)" % prefix for prefix in PREFIXES]

doc = {}
if os.path.exists(path):
    try:
        with open(path) as handle:
            doc = json.load(handle)
    except (ValueError, OSError):
        print("SKIP unreadable")
        sys.exit(0)
    if not isinstance(doc, dict):
        print("SKIP not-an-object")
        sys.exit(0)

permissions = doc.setdefault("permissions", {})
if not isinstance(permissions, dict):
    print("SKIP permissions-not-an-object")
    sys.exit(0)
added = 0
for key, wanted in (("allow", ALLOW), ("deny", DENY)):
    existing = permissions.setdefault(key, [])
    if not isinstance(existing, list):
        continue
    for entry in wanted:
        if entry not in existing:
            existing.append(entry)
            added += 1
if added:
    tmp = path + ".exakit-tmp"
    with open(tmp, "w") as handle:
        json.dump(doc, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)
print("ADDED %d" % added)
EXAKIT_RAL_PY
}

# exakit_remove_readonly_allowlist - the exact mirror of exakit_apply_readonly_allowlist:
# remove precisely the entries the kit added, nothing else. Uninstall left them
# behind - 42 allow rules and 3 deny rules for a command that no longer existed.
# Entries the user added themselves are not the kit's to touch, so only the
# kit's own spellings go. Best-effort; a malformed file is left alone.
exakit_remove_readonly_allowlist() {
    exakit_can_run_python || return 0
    _rral_file="$HOME/.claude/settings.json"
    [ -f "$_rral_file" ] || { printf 'REMOVED 0\n'; return 0; }
    run_python - "$_rral_file" <<'EXAKIT_RRAL_PY'
import json, os, sys
path = sys.argv[1]
READONLY = [
    "status", "info", "version", "mcp-doctor", "logs", "catalog", "preflight",
    "guide", "mcp-status", "help",
]
PREFIXES = ["exakit", "~/.local/bin/exakit", "$HOME/.local/bin/exakit"]
ALLOW = []
for prefix in PREFIXES:
    for command in READONLY:
        ALLOW.append("Bash(%s %s:*)" % (prefix, command))
    ALLOW.append("Bash(%s skills)" % prefix)
    ALLOW.append("Bash(%s skills --json)" % prefix)
ALLOW.append("mcp__exasol")
DENY = ["Bash(%s uninstall:*)" % prefix for prefix in PREFIXES]
try:
    with open(path) as handle:
        doc = json.load(handle)
except (ValueError, OSError):
    print("SKIP unreadable")
    sys.exit(0)
permissions = doc.get("permissions") if isinstance(doc, dict) else None
if not isinstance(permissions, dict):
    print("REMOVED 0")
    sys.exit(0)
removed = 0
for key, ours in (("allow", ALLOW), ("deny", DENY)):
    existing = permissions.get(key)
    if not isinstance(existing, list):
        continue
    kept = [entry for entry in existing if entry not in ours]
    removed += len(existing) - len(kept)
    permissions[key] = kept
if removed:
    tmp = path + ".exakit-tmp"
    with open(tmp, "w") as handle:
        json.dump(doc, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)
print("REMOVED %d" % removed)
EXAKIT_RRAL_PY
}

# exakit_maybe_offer_skills_install — after setup, place the skills where CLI
# agents can find them. Always installs — no prompt — so the skills are
# present without requiring interactive confirmation. Non-fatal and
# idempotent.
exakit_maybe_offer_skills_install() {
    _repo_root="$(exakit_repo_root)" || {
        exakit_note_failure "the kit copy could not be located, so no skills were installed"
        return 1
    }
    # A missing skills/ directory used to return SUCCESS here, which is how a
    # staging bug that shipped zero skills to every install stayed invisible:
    # the closing summary had nothing to report and AGENTS.md's first
    # post-install instruction failed on a machine the installer called done.
    # It is a real failure now, and it books itself in the summary.
    if ! ls "$_repo_root"/skills/*/SKILL.md >/dev/null 2>&1; then
        warn "No skills/ directory in this kit copy ($_repo_root) — no AI skills were installed."
        exakit_note_failure "this kit copy carries no skills/ directory (expected $_repo_root/skills)"
        return 1
    fi
    if ! exakit_install_skills; then
        warn "Skills install did not finish cleanly. Retry any time with: exakit skills-install"
        exakit_note_failure "the AI skills could not be copied into place (see the log)"
        return 1
    fi
}

exakit_exapump_bin() {
    _manifest_path="$(manifest_get components.exapump.path 2>/dev/null || true)"
    if [ -n "$_manifest_path" ] && [ -x "$_manifest_path" ]; then
        printf '%s\n' "$_manifest_path"
        return 0
    fi
    if command -v exapump >/dev/null 2>&1; then
        command -v exapump
        return 0
    fi
    if [ -x "$EXAKIT_BIN_DIR/exapump" ]; then
        printf '%s\n' "$EXAKIT_BIN_DIR/exapump"
        return 0
    fi
    return 1
}

_exakit_sql_literal() {
    printf "%s" "$1" | sed "s/'/''/g"
}

_exakit_manifest_runtime_value() {
    manifest_get "$1" 2>/dev/null || true
}

_exakit_parse_runtime_host() {
    _dsn="$(_exakit_manifest_runtime_value runtime.dsn)"
    printf '%s\n' "${_dsn%%:*}"
}

_exakit_parse_runtime_port() {
    _dsn="$(_exakit_manifest_runtime_value runtime.dsn)"
    printf '%s\n' "${_dsn##*:}"
}

_exakit_first_schema() {
    _schemas="$1"
    _old_ifs="$IFS"
    IFS=', '
    set -- $_schemas
    IFS="$_old_ifs"
    printf '%s\n' "${1:-STARTER_KIT}"
}

_exakit_write_exapump_config() {
    _config_path="$1"
    _host="$2"
    _port="$3"
    _admin_user="$4"
    _admin_password="$5"
    _readonly_user="$6"
    _readonly_password="$7"
    _schema="$8"
    # Both passwords -- one of them the ADMIN/SYS credential -- travel in the
    # environment, never in argv: an argv is visible to any local user via `ps`
    # for the life of the call, while a child's environment is readable only by
    # its owner and root. Same rule as _exakit_run_exapump_sql below, which
    # keeps its credential off the process table by sending it to stdin; stdin
    # here is already carrying the Python program, so the environment is the
    # equivalent door.
    EXAKIT_ADMIN_PASSWORD="$_admin_password"
    EXAKIT_READONLY_PASSWORD="$_readonly_password"
    export EXAKIT_ADMIN_PASSWORD EXAKIT_READONLY_PASSWORD
    run_python - "$_config_path" "$_host" "$_port" "$_admin_user" "$_readonly_user" "$_schema" <<'PY'
import os, sys

config_path, host, port, admin_user, readonly_user, schema = sys.argv[1:]
admin_password = os.environ["EXAKIT_ADMIN_PASSWORD"]
readonly_password = os.environ["EXAKIT_READONLY_PASSWORD"]

def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

doc = [
    "[admin]\n",
    f"host = {toml_string(host)}\n",
    f"port = {port}\n",
    f"user = {toml_string(admin_user)}\n",
    f"password = {toml_string(admin_password)}\n",
    "tls = true\n",
    "validate_certificate = false\n",
    "\n",
    "[mcp_readonly]\n",
    f"host = {toml_string(host)}\n",
    f"port = {port}\n",
    f"user = {toml_string(readonly_user)}\n",
    f"password = {toml_string(readonly_password)}\n",
    f"schema = {toml_string(schema)}\n",
    "tls = true\n",
    "validate_certificate = false\n",
]
with open(config_path, "w", encoding="utf-8") as handle:
    handle.writelines(doc)
PY
    _wec_rc=$?
    # Unset on BOTH paths: an exported credential that outlives this call is
    # inherited by every later child in the run.
    unset EXAKIT_ADMIN_PASSWORD EXAKIT_READONLY_PASSWORD
    [ "$_wec_rc" -eq 0 ] || return 1
    chmod 600 "$_config_path"
}

_exakit_run_exapump_sql() {
    _config_path="$1"
    _profile="$2"
    _sql="$3"
    _bin="$(exakit_exapump_bin)" || die "exapump is required for MCP read-only setup but was not found."
    # Feed the SQL over stdin, not as an argv: some of these statements are
    # CREATE/ALTER USER … IDENTIFIED BY <password>, and an argv is visible to any
    # local user via `ps` for the life of the call. stdin keeps it off the
    # process table; callers still capture stdout exactly as before.
    printf '%s\n' "$_sql" | EXAPUMP_CONFIG="$_config_path" "$_bin" sql -p "$_profile"
}

_exakit_exapump_sql_has_token() {
    _config_path="$1"
    _profile="$2"
    _sql="$3"
    _token="$4"
    _output="$(_exakit_run_exapump_sql "$_config_path" "$_profile" "$_sql" 2>> "${EXAKIT_LOG_FILE:-/dev/null}")" || return 1
    printf '%s\n' "$_output" | grep -Fq "$_token"
}

# _exakit_assert_mcp_readonly_posture <config> <user> <default-schema>
# Verifies the read-only user holds EXACTLY the database-wide read set
# (CREATE SESSION + USE ANY SCHEMA + SELECT ANY TABLE) and nothing more: no
# extra system privilege, no non-SELECT object privilege, and a live write is
# rejected. This is what lets the user read every schema while still being
# provably unable to write. <default-schema> is only the write-probe target.
_exakit_assert_mcp_readonly_posture() {
    _config_path="$1"
    _readonly_user="$2"
    _schemas="$3"
    _identifier_user="$(printf '%s' "$_readonly_user" | tr '[:lower:]' '[:upper:]')"
    _user_lit="$(_exakit_sql_literal "$_identifier_user")"

    # The read-only user's system privileges must be EXACTLY the read set:
    # CREATE SESSION + USE ANY SCHEMA + SELECT ANY TABLE. Assert each is
    # present, then assert nothing outside that set exists — directly, through
    # a role, or as an object grant. Together those three say the user has no
    # write/DDL/admin privilege (no INSERT ANY TABLE, CREATE USER, GRANT ANY,
    # SELECT ANY DICTIONARY, etc.). Before the role query was added, this
    # comment claimed "and nothing more" while a single GRANT of any role went
    # entirely unseen.
    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE = 'CREATE SESSION') THEN 'EXAKIT_CREATE_SESSION_OK' ELSE 'EXAKIT_CREATE_SESSION_MISSING' END AS STATUS" \
        "EXAKIT_CREATE_SESSION_OK" || die "The read-only database login for your AI client is incomplete (no CREATE SESSION, so it cannot connect). Rebuild it with: exakit mcp-setup"

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE = 'USE ANY SCHEMA') THEN 'EXAKIT_USE_ANY_SCHEMA_OK' ELSE 'EXAKIT_USE_ANY_SCHEMA_MISSING' END AS STATUS" \
        "EXAKIT_USE_ANY_SCHEMA_OK" || die "The read-only database login for your AI client cannot see your schemas. Rebuild it with: exakit mcp-setup"

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE = 'SELECT ANY TABLE') THEN 'EXAKIT_SELECT_ANY_TABLE_OK' ELSE 'EXAKIT_SELECT_ANY_TABLE_MISSING' END AS STATUS" \
        "EXAKIT_SELECT_ANY_TABLE_OK" || die "The read-only database login for your AI client cannot read your tables. Rebuild it with: exakit mcp-setup"

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_SYS_PRIV_SCOPE_OK' ELSE 'EXAKIT_SYS_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE NOT IN ('CREATE SESSION', 'USE ANY SCHEMA', 'SELECT ANY TABLE')" \
        "EXAKIT_SYS_PRIV_SCOPE_OK" || die "The database login for your AI client has more than read-only access, so the kit will not hand it over. Rebuild it with: exakit mcp-setup (or check EXAKIT_MCP_READONLY_USER, which is '$_readonly_user' here, for a login you granted extra privileges to)."

    # NOR MAY IT REACH ANYTHING THROUGH A ROLE. A privilege held via a granted
    # role is attributed to the ROLE in EXA_DBA_SYS_PRIVS, not to the user, so
    # every check above is blind to `GRANT <role> TO MCP_READONLY`. The write
    # probe below does catch a role conferring CREATE TABLE in the probe
    # schema, and it is genuinely load-bearing - but it is one CREATE TABLE in
    # one schema, so a role granting SELECT ANY DICTIONARY (the privilege this
    # file and sql/mcp_readonly_user.sql single out as deliberately withheld,
    # because it exposes audit logs, sessions and other users), IMPORT/EXPORT,
    # EXECUTE ANY SCRIPT, or CREATE ANY TABLE in some other schema passed the
    # whole posture check. The kit never grants a role, so this is drift
    # detection - which is exactly what mcp-doctor re-runs this for.
    #
    # PUBLIC is excluded because every user holds it by definition.
    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_ROLE_SCOPE_OK' ELSE 'EXAKIT_ROLE_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_ROLE_PRIVS WHERE GRANTEE = '$_user_lit' AND GRANTED_ROLE NOT IN ('PUBLIC')" \
        "EXAKIT_ROLE_SCOPE_OK" || die "The database login for your AI client holds a database ROLE, which can carry privileges these checks cannot see, so the kit will not hand it over. Rebuild it with: exakit mcp-setup"

    # No object privilege may be anything other than SELECT — i.e. the user
    # holds no INSERT/UPDATE/DELETE/ALTER/etc. object grant anywhere.
    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_OBJ_PRIV_SCOPE_OK' ELSE 'EXAKIT_OBJ_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE <> 'SELECT'" \
        "EXAKIT_OBJ_PRIV_SCOPE_OK" || die "The database login for your AI client can write to at least one table, so the kit will not hand it over. Rebuild it with: exakit mcp-setup"

    # Live proof the user cannot write: creating a table in the default schema
    # (which USE ANY SCHEMA lets it OPEN) MUST be rejected, since neither read
    # privilege grants CREATE/INSERT.
    _probe_schema="$(_exakit_first_schema "$_schemas")"
    _probe_schema_uc="$(printf '%s' "$_probe_schema" | tr '[:lower:]' '[:upper:]')"
    if _exakit_run_exapump_sql \
        "$_config_path" "mcp_readonly" \
        "CREATE TABLE ${_probe_schema_uc}.EXAKIT_MCP_PERMISSION_PROBE (ID DECIMAL)" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        _exakit_run_exapump_sql \
            "$_config_path" "admin" \
            "DROP TABLE ${_probe_schema_uc}.EXAKIT_MCP_PERMISSION_PROBE" \
            >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || true
        die "Security check failed: the MCP read-only user was able to write to schema $_probe_schema_uc, but it must be read-only. Setup stopped to protect your database."
    fi
}

# _exakit_reassert_mcp_readonly_posture — re-run the grant-posture check
# against the database using the credentials already on file, without
# re-provisioning anything. Used by `exakit mcp-doctor` so
# privilege drift after install (e.g. someone widening a grant by hand) is
# actually caught, not just checked once at setup time.
# Runs the (die()-on-failure) assertion in a subshell so a posture failure
# is reported back to the caller instead of aborting the whole CLI.
_exakit_reassert_mcp_readonly_posture() {
    # Ensure exapump is on PATH (both current session and permanently)
    _exapump_bin="$(exakit_exapump_bin 2>/dev/null)" || true
    if [ -n "$_exapump_bin" ]; then
        _exapump_dir="$(dirname "$_exapump_bin")"
        case ":$PATH:" in
            *":$_exapump_dir:"*) ;;
            *)
                PATH="$_exapump_dir:$PATH"
                _exakit_add_bin_to_shell_rc "$_exapump_dir"
                ;;
        esac
    fi
    
    _runtime_user="$(_exakit_manifest_runtime_value runtime.user)"
    _runtime_password_file="$(_exakit_manifest_runtime_value runtime.password_file)"
    _readonly_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _readonly_password_file="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
    _schemas_json="$(manifest_get components.mcp_server.connection.schemas 2>/dev/null || true)"

    if [ -z "$_runtime_user" ] || [ -z "$_runtime_password_file" ] || \
       [ -z "$_readonly_user" ] || [ -z "$_readonly_password_file" ] || [ -z "$_schemas_json" ]; then
        return 0
    fi
    [ -f "$_runtime_password_file" ] || { warn "Runtime password file missing; skipping MCP grant-posture re-check."; return 1; }
    [ -f "$_readonly_password_file" ] || { warn "MCP read-only password file missing; skipping MCP grant-posture re-check."; return 1; }

    _schemas_csv="$(run_python - "$_schemas_json" <<'PY'
import json, sys
print(",".join(json.loads(sys.argv[1])))
PY
)"
    [ -n "$_schemas_csv" ] || return 0

    _admin_password="$(cat "$_runtime_password_file")"
    _readonly_password="$(cat "$_readonly_password_file")"
    _host="$(_exakit_parse_runtime_host)"
    _port="$(_exakit_parse_runtime_port)"
    _default_schema="$(_exakit_first_schema "$_schemas_csv")"

    _temp_config="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"
    exakit_track_sensitive_tmp "$_temp_config"   # holds plaintext DB passwords; swept on any exit
    _exakit_write_exapump_config \
        "$_temp_config" "$_host" "$_port" "$_runtime_user" "$_admin_password" \
        "$_readonly_user" "$_readonly_password" "$_default_schema"

    info "Re-checking MCP read-only grant posture against the database"
    if ( _exakit_assert_mcp_readonly_posture "$_temp_config" "$_readonly_user" "$_schemas_csv" ) \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        rm -f "$_temp_config"
        ok "MCP read-only grant posture is still correct"
        return 0
    fi
    rm -f "$_temp_config"
    warn "MCP read-only grant posture has drifted from the expected read-only set (see log). Run 'exakit mcp-doctor' or review grants manually."
    return 1
}

_exakit_validate_identifier() {
    case "$1" in
        ""|*[!A-Za-z0-9_]*)
            return 1
            ;;
    esac
    return 0
}

_exakit_validate_sql_password_token() {
    case "$1" in
        ""|[!A-Z]*|*[!A-Z0-9]*)
            return 1
            ;;
    esac
    return 0
}

_exakit_generate_sql_password_token() {
    # Generate alphanumeric password (A-Z, 0-9 only, no underscores) for maximum SQL compatibility
    # Format: A followed by 23 random uppercase/digits
    printf 'A%s\n' "$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 23)"
}

# _exakit_add_bin_to_shell_rc <bin-directory> — one PATH-persistence policy,
# not two. This used to carry its own dotfile preference ("Prefer ~/.bashrc"),
# which on macOS wrote a file neither zsh (the default shell) nor login bash
# ever reads — printing a green tick for an edit no new terminal would pick up
# — and it ignored EXAKIT_NO_PROFILE_EDIT. ensure_path_hint already makes the
# Darwin-aware choice (zsh -> .zshrc, macOS bash -> .bash_profile), marks its
# edit, and honours the opt-out; the second implementation existed only to
# drift from the first.
_exakit_add_bin_to_shell_rc() {
    ensure_path_hint "$1"
}

_exakit_redact_mcp_secret_output() {
    _text="$1"
    _secret="$2"
    if [ -n "$_secret" ]; then
        _text="${_text//$_secret/<redacted>}"
    fi
    printf '%s\n' "$_text" | sed -E "s/(IDENTIFIED BY )('[^']*'|[A-Z][A-Z0-9]*(\.\.\.)?)/\1<redacted>/g"
}

# _exakit_read_exapump_profile_password <profile> — print the password stored
# in the given exapump profile (EXAPUMP_CONFIG / ~/.exapump/config.toml), or
# nothing (non-zero) if it can't be read. Symmetric with how the profile is
# written in exapump.sh (an unescaped `password = "..."` line).
_exakit_read_exapump_profile_password() {
    _cfg="${EXAPUMP_CONFIG:-$HOME/.exapump/config.toml}"
    [ -f "$_cfg" ] || return 1
    require_python3
    run_python - "$_cfg" "$1" <<'PY'
import re, sys
path, profile = sys.argv[1], sys.argv[2]
try:
    content = open(path).read()
except OSError:
    sys.exit(1)
m = re.search(r"\[" + re.escape(profile) + r"\](.*?)(?:\n\[|\Z)", content, re.S)
if not m:
    sys.exit(1)
pw = re.search(r'(?m)^\s*password\s*=\s*"(.*)"\s*$', m.group(1))
if not pw:
    sys.exit(1)
sys.stdout.write(pw.group(1))
PY
}

# Four lines became one. Creating the user, creating the schema and validating
# the login are phases of a single outcome -- the read-only access exists and
# works -- and the tick at the end already said all three happened. They become
# spinner phases; the tick goes through ok_step so it survives the quieting.
exakit_configure_mcp_readonly_access() {
    _cmra_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    _cmra_t0="$(date +%s 2>/dev/null || echo 0)"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    require_python3
    # Ensure exapump is on PATH (both current session and permanently)
    _exapump_bin="$(exakit_exapump_bin)" || die "exapump is required for MCP read-only setup but was not found."
    _exapump_dir="$(dirname "$_exapump_bin")"
    case ":$PATH:" in
        *":$_exapump_dir:"*) ;;
        *)
            PATH="$_exapump_dir:$PATH"
            _exakit_add_bin_to_shell_rc "$_exapump_dir"
            ;;
    esac
    
    _runtime_user="$(_exakit_manifest_runtime_value runtime.user)"
    [ -n "$_runtime_user" ] || die "The install record is incomplete (no database user recorded), so the read-only login for your AI client cannot be created. Re-run the installer to rebuild it: $(exakit_install_command)"
    _runtime_password_file="$(_exakit_manifest_runtime_value runtime.password_file)"
    _admin_password=""
    if [ -n "$_runtime_password_file" ] && [ -f "$_runtime_password_file" ]; then
        _admin_password="$(cat "$_runtime_password_file")"
    fi
    # Fallback: recover the admin password from the exapump profile that the
    # data step already wrote and validated. Covers installs where the runtime
    # step could not record runtime.password_file (an adopted deployment with
    # unreadable secrets) — including re-runs, where the exapump step is skipped
    # as "already done" and so cannot record it either. Persist it forward so
    # later runs and mcp-doctor find it directly.
    if [ -z "$_admin_password" ]; then
        _admin_password="$(_exakit_read_exapump_profile_password "$EXAKIT_EXAPUMP_PROFILE" 2>/dev/null || true)"
        if [ -n "$_admin_password" ]; then
            store_credential runtime_sys_password "$_admin_password"
            manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/runtime_sys_password"
        fi
    fi
    [ -n "$_admin_password" ] || die "No runtime database password is available (runtime.password_file is missing and the exapump '$EXAKIT_EXAPUMP_PROFILE' profile has none). Set it with 'exapump profile init $EXAKIT_EXAPUMP_PROFILE', then re-run."
    _host="$(_exakit_parse_runtime_host)"
    _port="$(_exakit_parse_runtime_port)"
    [ -n "$_host" ] || die "The install record is incomplete (no database host recorded), so the read-only login for your AI client cannot be created. Re-run the installer to rebuild it: $(exakit_install_command)"
    [ -n "$_port" ] || die "The install record is incomplete (no database port recorded), so the read-only login for your AI client cannot be created. Re-run the installer to rebuild it: $(exakit_install_command)"

    _readonly_user="$EXAKIT_MCP_READONLY_USER"
    # The MCP user gets database-wide READ (USE ANY SCHEMA + SELECT ANY TABLE),
    # so it can query every schema and table — bundled datasets, your own
    # uploads, and anything you create later — with no per-schema grant. This
    # list is now only the connection's DEFAULT schema (the landing spot for
    # local uploads); it must exist so the exapump profile can OPEN it on
    # connect, and it is the schema the write-rejection probe targets.
    _readonly_schemas="$EXAKIT_MCP_READONLY_SCHEMAS"
    _default_schema="$(_exakit_first_schema "$_readonly_schemas")"
    _readonly_password="$(read_credential mcp_readonly_password)"
    if ! _exakit_validate_sql_password_token "$_readonly_password"; then
        _readonly_password="$(_exakit_generate_sql_password_token)"
        store_credential mcp_readonly_password "$_readonly_password"
    fi

    _identifier_user="$(printf '%s' "$_readonly_user" | tr '[:lower:]' '[:upper:]')"
    _default_schema_uc="$(printf '%s' "$_default_schema" | tr '[:lower:]' '[:upper:]')"
    _exakit_validate_identifier "$_identifier_user" || die "Invalid EXAKIT_MCP_READONLY_USER: $_readonly_user"
    _temp_config="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"
    exakit_track_sensitive_tmp "$_temp_config"   # holds plaintext DB passwords; swept on any exit
    _exakit_write_exapump_config \
        "$_temp_config" "$_host" "$_port" "$_runtime_user" "$_admin_password" \
        "$_readonly_user" "$_readonly_password" "$_default_schema_uc"

    if ! _exakit_exapump_sql_has_token \
        "$_temp_config" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '$(_exakit_sql_literal "$_identifier_user")') THEN 'EXAKIT_MCP_USER_PRESENT' ELSE 'EXAKIT_MCP_USER_MISSING' END AS STATUS" \
        "EXAKIT_MCP_USER_PRESENT"; then
        EXAKIT_ACTIVE_LABEL="Creating the dedicated MCP read-only database user"
        info "Creating the dedicated MCP read-only database user ($_readonly_user)"
        _create_user_output="$(_exakit_run_exapump_sql \
            "$_temp_config" "admin" \
            "CREATE USER ${_identifier_user} IDENTIFIED BY ${_readonly_password}" 2>&1)"
        if [ $? -ne 0 ]; then
            _create_user_redacted="$(_exakit_redact_mcp_secret_output "$_create_user_output" "$_readonly_password")"
            _exakit_log_file "ERROR_DETAIL $_create_user_redacted"
            error "CREATE USER details: $_create_user_redacted"
            die "Could not create the MCP read-only database user."
        fi
        _create_user_redacted="$(_exakit_redact_mcp_secret_output "$_create_user_output" "$_readonly_password")"
        [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_create_user_redacted" >> "$EXAKIT_LOG_FILE"
    fi

    _alter_user_output="$(_exakit_run_exapump_sql \
        "$_temp_config" "admin" \
        "ALTER USER ${_identifier_user} IDENTIFIED BY ${_readonly_password}" 2>&1)"
    if [ $? -ne 0 ]; then
        _alter_user_redacted="$(_exakit_redact_mcp_secret_output "$_alter_user_output" "$_readonly_password")"
        _exakit_log_file "ERROR_DETAIL $_alter_user_redacted"
        error "ALTER USER details: $_alter_user_redacted"
        die "Could not refresh the MCP read-only database password."
    fi
    _alter_user_redacted="$(_exakit_redact_mcp_secret_output "$_alter_user_output" "$_readonly_password")"
    [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_alter_user_redacted" >> "$EXAKIT_LOG_FILE"
    _exakit_run_exapump_sql \
        "$_temp_config" "admin" \
        "GRANT CREATE SESSION TO ${_identifier_user}" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not grant CREATE SESSION to the MCP read-only database user."

    # Make sure the connection's default schema exists — exapump OPENs it on
    # connect, and the write-rejection probe targets it.
    _exakit_validate_identifier "$_default_schema_uc" || die "Invalid MCP default schema name: $_default_schema"
    if ! _exakit_exapump_sql_has_token \
        "$_temp_config" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$(_exakit_sql_literal "$_default_schema_uc")') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS" \
        "EXAKIT_SCHEMA_PRESENT"; then
        EXAKIT_ACTIVE_LABEL="Creating the default schema for MCP-safe querying"
        info "Creating default schema $_default_schema_uc for MCP-safe querying"
        _exakit_run_exapump_sql "$_temp_config" "admin" "CREATE SCHEMA ${_default_schema_uc}" \
            >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not create schema $_default_schema_uc for MCP access."
    fi

    # Database-wide READ: USE ANY SCHEMA (see every schema) + SELECT ANY TABLE
    # (read table/view contents in any schema). Together these let the AI client
    # query every schema and table — present and future, including ones you
    # create by hand — without a per-schema grant. Neither privilege permits any
    # write or DDL, so the read-only guarantee is preserved (and re-checked by
    # _exakit_assert_mcp_readonly_posture below). SELECT ANY DICTIONARY is
    # deliberately NOT granted, so system dictionaries (audit logs, sessions,
    # other users) stay private; the server lists metadata from the self-scoped
    # EXA_ALL_* views, which USE ANY SCHEMA already covers.
    _exakit_run_exapump_sql "$_temp_config" "admin" "GRANT USE ANY SCHEMA TO ${_identifier_user}" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not grant USE ANY SCHEMA to the MCP read-only database user."
    _exakit_run_exapump_sql "$_temp_config" "admin" "GRANT SELECT ANY TABLE TO ${_identifier_user}" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not grant SELECT ANY TABLE to the MCP read-only database user."

    EXAKIT_ACTIVE_LABEL="Validating the dedicated MCP read-only login"
    info "Validating dedicated MCP read-only login"
    _exakit_exapump_sql_has_token \
        "$_temp_config" "mcp_readonly" \
        "SELECT CURRENT_USER AS EXAKIT_CURRENT_USER" \
        "$_identifier_user" || die "The MCP read-only user could not log in with the generated credentials."
    _exakit_exapump_sql_has_token \
        "$_temp_config" "mcp_readonly" \
        "SELECT 'EXAKIT_MCP_READONLY_OK' AS STATUS" \
        "EXAKIT_MCP_READONLY_OK" || die "The MCP read-only user did not pass the validation query."
    _exakit_assert_mcp_readonly_posture "$_temp_config" "$_readonly_user" "$_readonly_schemas"

    manifest_set components.mcp_server.connection.user "$_readonly_user"
    manifest_set components.mcp_server.connection.password_file "$EXAKIT_CREDS_DIR/mcp_readonly_password"
    # Records the connection's default schema (read access is database-wide, not
    # limited to this list); kept as an array for the posture re-check and the
    # exapump default-schema pick.
    manifest_set components.mcp_server.connection.schemas "[\"$(printf '%s' "$_readonly_schemas" | tr ',' '\n' | sed '/^$/d' | paste -sd '","' -)\"]"
    # THE SAME FACT, SPELLED SO IT CANNOT BE MISREAD. `schemas: ["STARTER_KIT"]`
    # reads as "this user can only see STARTER_KIT" — and an agent checking the
    # install record before querying concluded exactly that, while the MCP user
    # was in fact returning TPCH, ENERGY and WEATHER quite happily. The array
    # stays (internal readers parse it); these two say what it means.
    manifest_set components.mcp_server.connection.default_schema "$_default_schema"
    manifest_set components.mcp_server.connection.read_scope \
        "every schema (USE ANY SCHEMA + SELECT ANY TABLE); 'schemas' is the connection default, not a limit"
    manifest_set components.mcp_server.connection.validated "true"
    rm -f "$_temp_config"
    EXAKIT_QUIET_DETAIL="$_cmra_prev_quiet"
    ok_step "Dedicated MCP read-only access is configured and validated ($(( $(date +%s 2>/dev/null || echo 0) - _cmra_t0 ))s)"
    return 0
}

# _exakit_mcp_reported <result_file> — did the operation produce a real report?
#
# True when the file parses as a result document carrying an operation and a
# status. That is the difference between "the runtime ran and is telling you
# something" and "the runtime never got far enough to say anything", which the
# exit code alone cannot express.
# _exakit_mcp_result_repairable <file> - true when a WARNING or ERROR finding
# carries a code the repair operation acts on.
_exakit_mcp_result_repairable() {
    [ -s "${1:-}" ] || return 1
    exakit_can_run_python 2>/dev/null || return 1
    run_python - "$1" <<'PY' >/dev/null 2>&1
import json, sys
REPAIRABLE = {"permission_drift", "manifest_drift_hash_mismatch", "manifest_drift_missing_artifact",
              "managed_artifact_missing", "managed_entry_outdated"}
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception:
    raise SystemExit(1)
for finding in (doc.get("findings") or []) if isinstance(doc, dict) else []:
    if isinstance(finding, dict) and finding.get("code") in REPAIRABLE \
            and str(finding.get("severity", "")).lower() in ("warning", "error", "critical"):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

_exakit_mcp_reported() {
    [ -s "${1:-}" ] || return 1
    exakit_can_run_python 2>/dev/null || return 1
    run_python - "$1" <<'PY' >/dev/null 2>&1
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if isinstance(doc, dict) and doc.get("operation") and doc.get("status") else 1)
PY
}

# _exakit_log_mcp_result_failure <result_file> — copy the CLI's structured
# diagnosis (status + findings) into the log so "see log" is honest. A crash
# already lands in the log via the runners' stderr redirect; this covers the
# other failure shape, where the CLI exits non-zero with the cause only in its
# JSON payload. Deliberately logs findings, not the raw payload — the payload
# can embed rendered client-config material.
_exakit_log_mcp_result_failure() {
    [ -s "$1" ] || return 0
    [ -n "${EXAKIT_LOG_FILE:-}" ] || return 0
    run_python - "$1" <<'PY' >> "$EXAKIT_LOG_FILE" 2>&1 || true
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception as exc:  # noqa: BLE001 - diagnostics only, never fatal
    print(f"MCP result file unreadable: {exc}")
    raise SystemExit(0)

print(f"MCP status: {doc.get('status', 'unknown')} — {doc.get('summary', '')}")
for finding in doc.get("findings", []) or []:
    line = f"MCP finding [{finding.get('severity')}] {finding.get('code')}: {finding.get('message')}"
    action = finding.get("recommended_action")
    if action:
        line += f" -> {action}"
    print(line)
PY
}

exakit_run_mcp_setup_cli() {
    _clients_csv="$1"
    _output_file="$2"
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to configure your AI clients."
        return 1
    }
    # The caller may have prepared the read-only user already: it narrates as it
    # goes, and the client table is animating by the time this runs, so nothing
    # may print. One call only — the flag is cleared here, so a later run in the
    # same process (a refresh after a redeploy) prepares the user again.
    if [ "${EXAKIT_MCP_READONLY_READY:-0}" = 1 ]; then
        EXAKIT_MCP_READONLY_READY=0
    else
        exakit_configure_mcp_readonly_access || return 1
    fi
    _old_ifs="$IFS"
    IFS=','
    set -- $_clients_csv
    IFS="$_old_ifs"
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp setup-runtime-clients \
                --runtime-root "$EXAKIT_HOME" \
                --clients "$@"
    ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        _exakit_log_mcp_result_failure "$_output_file"
        # First, not last: the client table may be animating, and its next frame
        # moves the cursor up and clears — which would wipe this warning off the
        # screen before anyone could read it. die() stops the animation for the
        # same reason.
        command -v ui_animation_stop >/dev/null 2>&1 && ui_animation_stop
        warn "Could not write the MCP entry for this AI client. What failed: exakit logs setup. Retry with: exakit mcp-setup"
        return 1
    fi
    return 0
}

# exakit_run_mcp_addon_cli <clients_csv> <output_file> — register the MCP
# endpoints of installed add-ons with clients that are already connected.
#
# Deliberately NOT exakit_run_mcp_setup_cli: that path prepares the read-only
# database user first, so an add-on install would have started depending on a
# running database to finish. An add-on endpoint is a loopback URL with no
# credential in it, so this touches neither.
exakit_run_mcp_addon_cli() {
    _clients_csv="$1"
    _output_file="$2"
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to register the add-on endpoint."
        return 1
    }
    _old_ifs="$IFS"
    IFS=','
    set -- $_clients_csv
    IFS="$_old_ifs"
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}"             run_python -m mcp register-addon-servers                 --runtime-root "$EXAKIT_HOME"                 --clients "$@"
    ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        _exakit_log_mcp_result_failure "$_output_file"
        return 1
    fi
    return 0
}

# exakit_run_mcp_server_removal_cli <server> <clients_csv> <output_file> — drop
# ONE managed server entry from the client configs, leaving every other entry in
# the same file alone. The plain uninstall operation removes every managed entry
# for a client, which would take the exasol server with it.
exakit_run_mcp_server_removal_cli() {
    _server_name="$1"
    _clients_csv="$2"
    _output_file="$3"
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to remove the add-on endpoint."
        return 1
    }
    _old_ifs="$IFS"
    IFS=','
    set -- $_clients_csv
    IFS="$_old_ifs"
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}"             run_python -m mcp run-runtime-operation uninstall                 --runtime-root "$EXAKIT_HOME"                 --servers "$_server_name"                 --clients "$@"
    ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        _exakit_log_mcp_result_failure "$_output_file"
        return 1
    fi
    return 0
}

exakit_run_mcp_operation_cli() {
    _operation="$1"
    _clients_csv="$2"
    _output_file="$3"
    _snapshot_id="${4:-}"
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to manage your AI clients."
        return 1
    }
    case "$_operation" in
        validate|repair|doctor)
            exakit_configure_mcp_readonly_access || return 1
            ;;
    esac
    _old_ifs="$IFS"
    IFS=','
    set -- $_clients_csv
    IFS="$_old_ifs"
    if [ -n "$_snapshot_id" ]; then
        if ! (
            cd "$_repo_root" &&
            PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
                run_python -m mcp run-runtime-operation \
                    "$_operation" \
                    --runtime-root "$EXAKIT_HOME" \
                    --snapshot-id "$_snapshot_id" \
                    --clients "$@"
        ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
            _exakit_log_mcp_result_failure "$_output_file"
            _exakit_mcp_reported "$_output_file" && return 2
            warn "MCP $_operation did not complete. The reason: exakit logs setup. Retry with: exakit mcp-setup"
            return 1
        fi
        return 0
    fi
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp run-runtime-operation \
                "$_operation" \
                --runtime-root "$EXAKIT_HOME" \
                --clients "$@"
    ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        _exakit_log_mcp_result_failure "$_output_file"
        # A diagnosis that FOUND something is not a diagnosis that failed to run.
        # The runtime exits non-zero for both, so the two were reported the same
        # way: doctor printed a complete report naming the exact fault, and then
        # said "MCP doctor failed" and "Could not run MCP diagnostics" - telling
        # the reader the tool broke, when the tool had just done its job.
        # Return 2 so the caller can keep a non-zero exit for scripts without
        # contradicting the report it just printed.
        _exakit_mcp_reported "$_output_file" && return 2
        warn "MCP $_operation did not complete. The reason: exakit logs setup. Retry with: exakit mcp-setup"
        return 1
    fi
    return 0
}

# exakit_print_mcp_setup_summary <result-json> — what MCP setup did, in the
# fewest lines that still tell the reader everything they have to act on.
#
# This was a twenty-line panel: a Mode row, a Meaning row explaining the Mode
# row, a Status row, and one File: row per client. None of that is actionable,
# and every word of it is one `exakit mcp-status` away. What IS actionable — the
# clients configured, the plaintext-credential warning, and the per-client
# "restart it like this" lines, which differ per client — stays, as plain lines
# rather than boxed rows. Python emits typed records; the shell renders each
# through the same info/ok/warn the rest of the run uses.
#
# <table-shown> = 1 when the client table carried the per-client outcome: the
# headline is then dropped, because the table said it row by row and said which
# client got what. A run that did NOT finish clean still says so here.
exakit_print_mcp_setup_summary() {
    _result_file="$1"
    _table_shown="${2:-0}"
    require_python3
    _summary_lines="$(run_python - "$_result_file" "$_table_shown" <<'PY'
import json, sys

LABELS = {
    "claude_desktop": "Claude",
    "claude_code": "Claude Code (CLI)",
    "vscode_copilot": "GitHub Copilot",
    "gemini_cli": "Gemini CLI",
    "cursor": "Cursor",
    "codex": "Codex",
    "opencode": "OpenCode",
    "continue": "Continue",
}

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)

# One record per line: "<kind>|<text>". The shell knows how to draw each kind;
# nothing here decides what it looks like.
clients = ", ".join(LABELS.get(item, item) for item in doc.get("selected_clients", []))
lines = []
status = doc.get("status", "unknown")
table_shown = len(sys.argv) > 2 and sys.argv[2] == "1"
if str(status).startswith("success"):
    # The table already named every client and what happened to it, so this
    # line would be the same fact twice, the second time less precisely.
    if not table_shown:
        lines.append(f"ok|MCP configured for {clients or 'no clients'}")
else:
    lines.append(f"warn|MCP setup finished as '{status}' for {clients or 'no clients'}")

# A client whose own config file could not be used is skipped on its own; the
# other clients are still configured, so name it rather than leave a silent gap.
for skipped in doc.get("details", {}).get("skipped_clients", []):
    client = LABELS.get(skipped.get("client"), skipped.get("client", "unknown"))
    lines.append(f"warn|Skipped {client}: {skipped.get('reason', 'unknown reason')}")

# The plaintext-credential finding is a standing property of how every MCP
# client stores a credential, not something this run did or the reader can act
# on -- and it is the READ-ONLY user's password, not the admin one. Raising it
# as a warning on every single install taught people to read past warnings.
# It stays in the result JSON and in the logfile, and `exakit help mcp`
# documents it in full.
for finding in doc.get("findings", []):
    if finding.get("code") == "plaintext_credential_reference":
        # "log" is a kind the shell writes to the LOGFILE and not the screen.
        # Suppressing the line is the point; losing the record is not, and
        # dropping it outright left the only trace in the result JSON, which is
        # deleted when this function returns.
        lines.append(f"log|{finding.get('message', 'Unknown issue')}")
        continue
    # Severity decides the glyph. An INFO finding is a fact about a client, not
    # a fault of this run -- "Claude has no config-file shape for a remote MCP
    # server" printed under the warning glyph on every `exakit update` read as
    # a failure and prompted the question "why is it so?". A note it is.
    if finding.get("severity") == "info":
        lines.append(f"info|{finding.get('message', 'Unknown issue')}")
        continue
    lines.append(f"warn|{finding.get('message', 'Unknown issue')}")

# One "restart your client" line per configured client says the same thing
# four times over, in four wordings, for an action the reader takes once. The
# skills step closes the same install with the generic form already. Every
# adapter tags these kind="restart_client" (json_config.py covers Cursor), so
# dropping that kind drops exactly them -- a repair's next_actions carry the
# finding code as their kind and are untouched.
for action in doc.get("next_actions", []):
    message = action.get("message", "")
    if action.get("kind") == "restart_client":
        if message:
            lines.append(f"log|{message}")
        continue
    if message:
        lines.append(f"info|{message}")

print("\n".join(lines))
PY
)" || { warn "Could not draw the MCP summary; the setup itself is unaffected. See: exakit logs setup, or list the clients with: exakit mcp-status"; return 0; }
    while IFS='|' read -r _sum_kind _sum_text; do
        [ -n "$_sum_text" ] || continue
        case "$_sum_kind" in
            ok)   ok   "$_sum_text" ;;
            warn) warn "$_sum_text" ;;
            # Logged, never printed: a line the screen is better off without but
            # the log should still be able to answer for.
            log)  _exakit_log_file "INFO  $_sum_text" ;;
            *)    info "$_sum_text" ;;
        esac
    done <<EOF
$_summary_lines
EOF
    # Already in the closing panel, verbatim in effect:
    #   MCP configs:  in each AI client's config (list: exakit mcp-status)
    # so the pointer survives without being given twice.
    _exakit_log_file "INFO  Config file paths and per-client state: exakit mcp-status"
}

exakit_print_mcp_ready_panel() {
    _mode="${1:-}"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    # THROUGH THE RESOLVER, not a direct manifest read. Reading
    # connection.user here meant this panel could not tell "the read-only user
    # is recorded" from "there is none and the client is about to be handed the
    # admin account" - the two cases whose difference the line below exists to
    # report. mcp_credentials answers both at once; its third field is which.
    if command -v mcp_credentials >/dev/null 2>&1; then
        _mcp_creds="$(mcp_credentials 2>/dev/null || true)"
        _mcp_user="$(printf '%s' "$_mcp_creds" | cut -f1)"
        _mcp_user_kind="$(printf '%s' "$_mcp_creds" | cut -f3)"
    else
        _mcp_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
        _mcp_user_kind="readonly"
    fi
    _mcp_package="$(manifest_get components.mcp_server.package 2>/dev/null || printf '%s' "$EXAKIT_MCP_PACKAGE")"
    _mcp_version="$(manifest_get components.mcp_server.version 2>/dev/null || printf '%s' "$EXAKIT_MCP_VERSION")"
    _mcp_command="$(manifest_get components.mcp_server.command 2>/dev/null || true)"
    _tls="$(manifest_get runtime.tls 2>/dev/null || true)"
    [ -n "$_mcp_command" ] || _mcp_command="uvx"

    # An eight-row panel of reference values became one line. The command, the
    # package version and the managed-state directory are what `exakit
    # mcp-status` is for; what the reader needs here is that the server exists,
    # what it is called, and that it reaches the database read-only. The whole
    # panel still goes to the logfile, so nothing is unrecoverable.
    _exakit_log_file "DATA  MCP command: $_mcp_command $_mcp_package@$_mcp_version"
    _exakit_log_file "DATA  MCP managed state: $EXAKIT_MCP_DIR"
    _exakit_log_file "DATA  MCP TLS: ${_tls:-unknown}"
    # THE USER THAT WAS RESOLVED, not a default that assumes the good case.
    # `${_mcp_user:-mcp_readonly}` printed the reassurance even when the
    # resolution had fallen back to the admin account, which is precisely when
    # the reader needed to know it had.
    if [ "${_mcp_user_kind:-readonly}" = "admin-fallback" ]; then
        warn "MCP server 'exasol' — ${_dsn:-unknown} as ${_mcp_user:-unknown} — this is the ADMIN account, NOT the read-only user."
        info "No read-only MCP credential is recorded, so writes from your AI client would NOT be rejected by the database."
        info "Fix it with: exakit mcp-setup"
    else
        ok "MCP server 'exasol' — ${_dsn:-unknown} as ${_mcp_user:-unknown} (read-only), started by your AI client on demand"
    fi
    # Put the prompt straight onto the clipboard so the first interaction is a
    # paste, not a retype. Best-effort: silent when no clipboard tool exists.
    #
    # ONLY WITH A TERMINAL ATTACHED. The clipboard is the user's, and an
    # unattended install — an agent driving the kit, CI, a provisioning script —
    # has no business overwriting whatever they had on it for a prompt nobody is
    # about to paste. There is no undo for a clipboard.
    _first_prompt='Use the exasol MCP server connected to my local Exasol database. List the available schemas and tables first. Then answer my questions with read-only SQL only, show me the SQL before you run it, and do not create, update, or delete anything.'
    # The prompt is only PRINTED when it could not be handed over: on the
    # clipboard it is four lines nobody has to read, and off a terminal (an
    # agent, CI) the clipboard is not ours to take, so the text is the only way
    # to pass it on. Never both.
    if exakit_stdin_is_tty && printf '%s' "$_first_prompt" | exakit_copy_clipboard 2>/dev/null; then
        ok "A first prompt for your AI client is on your clipboard — paste it after the restart."
    else
        printf '\n'
        ui_panel_begin "First prompt to try in your AI client"
        ui_panel_line '"Use the exasol MCP server connected to my local Exasol database.'
        ui_panel_line 'List the available schemas and tables first. Then answer my'
        ui_panel_line 'questions with read-only SQL only, show me the SQL before you run'
        ui_panel_line 'it, and do not create, update, or delete anything."'
        ui_panel_end
    fi
}

exakit_print_mcp_operation_summary() {
    _result_file="$1"
    require_python3
    # The python prints "panel|<text>" for rows that belong INSIDE a box and
    # plain text for everything else. Drawing the box HERE, not there, is what
    # lets this screen wear the same rounded panel as `exakit info` and the
    # closing summary instead of the hand-drawn dashes it had -- ui_panel_* owns
    # the glyphs, so it degrades to ASCII on a plain terminal with nothing here
    # spelling a box character.
    #
    # Through a FILE, not a command substitution: this heredoc has to stay at
    # statement level. Wrapped in "$( ... )" so the rows could be walked, bash
    # stopped being able to parse the rest of this file. With no temp file the
    # rows go straight to the screen unboxed, which is a worse screen but never
    # a broken one.
    _mos_out="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-summary.XXXXXX" 2>/dev/null)" || _mos_out=""
    run_python - "$_result_file" > "${_mos_out:-/dev/stdout}" <<'PY'
import json, os, sys

LABELS = {
    "claude_desktop": "Claude",
    "claude_code": "Claude Code (CLI)",
    "vscode_copilot": "GitHub Copilot",
    "gemini_cli": "Gemini CLI",
    "cursor": "Cursor",
    "codex": "Codex",
    "opencode": "OpenCode",
    "continue": "Continue",
}

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)

# `mcp-status` is a STATE QUERY, and the operation summary answers a different
# question. It listed `selected_clients`, which with no client named is every
# client the kit SUPPORTS - so all eight printed whether one was configured or
# eight - and reduced the per-client records to "Tracked 4 managed artifact(s)".
# A reader asking "is my Claude set up?" got the kit's capabilities and a count.
#
# The rows are already in the result; this prints them. Snapshot is left out on
# purpose: a backup id is worth showing after a command that CHANGED something,
# and is noise on a read-only screen.
STATE_LABELS = {
    "configured": "configured",
    "not_set_up": "not set up",
    "not_installed": "not installed",
}
clients_detail = doc.get("details", {}).get("clients") or []
if doc.get("operation") == "status" and clients_detail:
    rows = []
    for entry in clients_detail:
        name = LABELS.get(entry.get("client"), entry.get("client", "unknown"))
        state = STATE_LABELS.get(entry.get("state"), entry.get("state", "unknown"))
        if entry.get("state") == "configured":
            note = entry.get("path") or ""
            home = os.path.expanduser("~")
            if note.startswith(home):
                note = "~" + note[len(home):]
        elif entry.get("state") == "not_set_up":
            note = "run: exakit mcp-setup"
        else:
            # The State column already said "not installed"; repeating it here
            # spends the widest column on nothing.
            note = ""
        rows.append((name, state, note))
    width = max(len(r[0]) for r in rows)
    state_w = max(len(r[1]) for r in rows)
    # Keep the row inside 80 columns. A real config path is long enough on its
    # own ("~/Library/Application Support/Claude/claude_desktop_config.json" is
    # 62) to push the table past any terminal, and a wrapped row loses the
    # column alignment that makes the table readable at a glance. The FILE NAME
    # is the part that identifies it, so the middle goes rather than the end.
    budget = 80 - (2 + width + 2 + state_w + 2)
    trimmed = []
    for name, state, note in rows:
        if len(note) > budget and "/" in note:
            parts = note.split("/")
            # Keep as many trailing segments as fit: the directory above the file
            # is often what tells two clients apart (Code/User/mcp.json), so drop
            # only what the budget forces.
            keep = 1
            while keep < len(parts):
                candidate = parts[0] + "/.../" + "/".join(parts[-(keep + 1):])
                if len(candidate) > budget:
                    break
                keep += 1
            note = parts[0] + "/.../" + "/".join(parts[-keep:])
            if len(note) > budget:
                note = ".../" + parts[-1]
        trimmed.append((name, state, note))
    rows = trimmed
    # ROWS, not a drawn table: the shell renders them through ui_panel_*, so this
    # screen wears the same rounded box as every other panel in the kit instead
    # of hand-drawn dashes. "panel|" marks a line that belongs inside the box.
    #
    # Only the clients that ARE configured. Five rows of "not installed" answered
    # what this machine does not have, which is not what a status screen is for;
    # `exakit mcp-setup` is where the full roster belongs, because there the list
    # IS the choice.
    print("panel|" + f"{'Client'.ljust(width)}  {'State'.ljust(state_w)}  Config")
    shown = 0
    for name, state, note in rows:
        if state != "configured":
            continue
        print("panel|" + f"{name.ljust(width)}  {state.ljust(state_w)}  {note}".rstrip())
        shown += 1
    if not shown:
        print("panel|Nothing configured yet. Connect a client with: exakit mcp-setup")
else:
    clients = ", ".join(LABELS.get(item, item) for item in doc.get("selected_clients", []))
    print("")
    print("  MCP operation summary")
    print(f"  Operation: {doc.get('operation', 'unknown')}")
    print(f"  Clients:   {clients or 'all managed clients'}")
    print(f"  Status:    {doc.get('status', 'unknown')}")
    print(f"  Summary:   {doc.get('summary', 'No summary returned')}")
    if doc.get("backup_reference"):
        print(f"  Snapshot:  {doc.get('backup_reference')}")

# Clients left alone because their own config file could not be used. The rest
# of the selection is still configured, so report this per client.
skipped_clients = doc.get("details", {}).get("skipped_clients", [])
if skipped_clients:
    print("")
    print("  Skipped clients:")
    for skipped in skipped_clients:
        name = LABELS.get(skipped.get("client"), skipped.get("client", "unknown"))
        print(f"  - {name}: {skipped.get('reason', 'unknown reason')}")

# Doctor carries per-client discovery plus the managed-artifact list: render
# a state map in the same vocabulary as the setup menu, so "not installed"
# reads as expected state instead of a warning.
discovered = (doc.get("details") or {}).get("discovered_clients") or []
client_states = (doc.get("details") or {}).get("clients") or []
if doc.get("operation") == "doctor" and client_states:
    # The doctor derives each client's state from HEALTH (see _doctor in
    # mcp/service.py). The map below used to be rebuilt here from "an artifact
    # exists", which called a client connected with its entry deleted, and
    # called clients that were not installed connected too.
    groups = {"connected": [], "needs attention": [], "configured, not installed": [], "available": [], "not installed": []}
    STATE_TO_GROUP = {
        "connected": "connected",
        "needs_attention": "needs attention",
        "configured_client_missing": "configured, not installed",
        "not_set_up": "available",
        "not_installed": "not installed",
    }
    for entry in client_states:
        cid = entry.get("client")
        groups[STATE_TO_GROUP.get(entry.get("state"), "not installed")].append(LABELS.get(cid, cid))
    hints = {
        "available": "-> connect with: exakit mcp-setup",
        "needs attention": "-> the findings below say what; exakit mcp-doctor repairs drift",
        "configured, not installed": "-> the client is gone; its entry stays until: exakit mcp-doctor",
    }
    print("")
    print("  Client state:")
    for label, names in groups.items():
        if names:
            hint = hints.get(label, "")
            print(f"    {label:<26} {', '.join(names)}{'   ' + hint if hint else ''}")
    discovered = []
if discovered:
    managed = {artifact.get("client") for artifact in doc.get("artifacts") or []}
    groups = {"connected": [], "available": [], "needs attention": [], "not installed": []}
    for entry in discovered:
        cid = entry.get("client")
        name = LABELS.get(cid, cid)
        if entry.get("detected") and cid in managed:
            groups["connected"].append(name)
        elif entry.get("detected"):
            groups["available"].append(name)
        elif cid in managed:
            groups["needs attention"].append(name)
        else:
            groups["not installed"].append(name)
    hints = {
        "available": "-> connect with: exakit mcp-setup",
        "needs attention": "-> managed entry, client missing (exakit mcp-doctor)",
    }
    print("")
    print("  Client state:")
    for label, names in groups.items():
        if names:
            hint = hints.get(label, "")
            print(f"    {label:<15} {', '.join(names)}{'   ' + hint if hint else ''}")

changes = doc.get("changes", [])
if changes:
    print("")
    print("  Changes:")
    for change in changes:
        print(f"  - {change.get('kind', 'change')} {change.get('path', '')}")

# Absent-client INFO findings are already represented in the state map above;
# repeating them as notes made a healthy machine read like a problem report.
findings = [
    finding
    for finding in doc.get("findings", [])
    if not (discovered and finding.get("severity") == "info" and finding.get("code") == "client_not_detected")
]
if findings:
    print("")
    print("  Notes:")
    for finding in findings:
        print(f"  - {finding.get('message', 'Unknown issue')}")

actions = doc.get("next_actions", [])
if actions:
    print("")
    print("  Next:")
    for action in actions:
        print(f"  - {action.get('message', '')}")
PY
    [ -n "$_mos_out" ] || return 0
    _mos_open=0
    while IFS= read -r _mos_line; do
        case "$_mos_line" in
            panel\|*)
                [ "$_mos_open" = 1 ] || { printf '\n'; ui_panel_begin "MCP clients"; _mos_open=1; }
                ui_panel_line "${_mos_line#panel|}"
                ;;
            *)
                [ "$_mos_open" = 0 ] || { ui_panel_end; _mos_open=0; }
                printf '%s\n' "$_mos_line"
                ;;
        esac
    done < "$_mos_out"
    [ "$_mos_open" = 0 ] || { ui_panel_end; printf '\n'; }
    rm -f "$_mos_out"
}

exakit_mcp_clients_from_args() {
    if [ "$#" -eq 0 ]; then
        printf '%s\n' "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue"
        return 0
    fi
    exakit_parse_mcp_client_selection "$*"
}

exakit_parse_mcp_client_selection() {
    _raw="$(printf '%s' "$1" | tr ',/' '  ' | tr -s ' ')"
    case "$_raw" in
        "" ) return 1 ;;
        all|ALL|All ) printf '%s\n' "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue"; return 0 ;;
    esac
    _result=""
    for _token in $_raw; do
        # "claude" (or 1) covers both Claude surfaces — the desktop app and the
        # Claude Code CLI — one user choice, two configs. The explicit ids
        # (claude_desktop / claude_code) still address a single surface.
        case "$_token" in
            1|claude) _clients="claude_desktop claude_code" ;;
            claude_desktop) _clients="claude_desktop" ;;
            claude_code) _clients="claude_code" ;;
            2|codex) _clients="codex" ;;
            3|cursor) _clients="cursor" ;;
            4|copilot|vscode|vscode_copilot) _clients="vscode_copilot" ;;
            5|gemini|gemini_cli) _clients="gemini_cli" ;;
            6|opencode) _clients="opencode" ;;
            7|continue) _clients="continue" ;;
            *) return 1 ;;
        esac
        for _client in $_clients; do
            case ",$_result," in
                *,"$_client",*) ;;
                *)
                    if [ -n "$_result" ]; then
                        _result="$_result,$_client"
                    else
                        _result="$_client"
                    fi
                    ;;
            esac
        done
    done
    [ -n "$_result" ] || return 1
    printf '%s\n' "$_result"
}

# exakit_mcp_detected_clients — csv of the clients detected on this machine
# (installed, configured or not), in the kit's canonical order. Empty when
# discovery is unavailable, so callers can fall back to the full list.
exakit_mcp_detected_clients() {
    _mdc_status="$(exakit_mcp_discover_status)" || return 1
    _mdc_out=""
    for _mdc_id in claude_desktop claude_code cursor codex vscode_copilot gemini_cli opencode continue; do
        case "$_mdc_status" in
            *"$_mdc_id connected"*|*"$_mdc_id pending"*) _mdc_out="${_mdc_out:+$_mdc_out,}$_mdc_id" ;;
        esac
    done
    [ -n "$_mdc_out" ] || return 1
    printf '%s\n' "$_mdc_out"
}

# exakit_mcp_discover_status — one "id state" line per supported MCP client,
# straight from the adapters' own detection: "pending" (installed on this
# machine, no managed config yet), "connected" (has a managed config), or
# "missing" (not installed). Used to build the setup menu: pending clients are
# selectable and pre-selected, the others are shown greyed out with the
# reason. Fails (rc 1) when discovery is unavailable so the caller can fall
# back to the static everything-selectable menu.
exakit_mcp_discover_status() {
    require_python3 2>/dev/null || return 1
    _repo_root="$(exakit_repo_root)" || return 1
    _discover_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-discover.XXXXXX")"
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp discover-clients --runtime-root "$EXAKIT_HOME"
    ) > "$_discover_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        rm -f "$_discover_file"
        return 1
    fi
    run_python - "$_discover_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception:
    sys.exit(1)
for client in doc.get("clients", []):
    if client.get("configured"):
        state = "connected"
    elif client.get("detected"):
        state = "pending"
    else:
        state = "missing"
    print(f'{client["id"]} {state}')
PY
    _parse_status=$?
    rm -f "$_discover_file"
    return "$_parse_status"
}

# exakit_ensure_runtime_running [deploy] — the kit's self-heal for "the
# database is not answering", shared by every command that is about to speak
# SQL. A runtime that is merely STOPPED (exakit stop, a reboot) is started and
# health-checked; a MISSING one is deployed when the caller passes "deploy"
# (the action commands do), and otherwise refused with the exact command that
# fixes it. A machine with no runtime recorded, or whose runtime module is not
# loaded, is left alone — that is the installer's territory, not a repair.
# ⇄ twin: Confirm-ExakitRuntimeRunning in setup/lib/exakit-common.ps1.
exakit_ensure_runtime_running() {
    _err_deploy="${1:-}"
    case "$(manifest_get runtime.type 2>/dev/null || true)" in
        personal)
            command -v personal_deployment_running >/dev/null 2>&1 || return 0
            personal_deployment_running && return 0
            if personal_deployment_exists; then
                info "Self-heal: the database is deployed but not running — starting it"
                personal_start
                # The same repair the install uses: a start the launcher took
                # without acting on is finished by its own deploy.
                # NOT `|| personal_wait_ready`: that would spend the whole
                # budget a second time before saying anything.
                personal_wait_ready_or_deploy ||                     die "The database is deployed but did not come up. Read the state with 'exakit status', or repair with: $(personal_repair_command)"
                return 0
            fi
            if [ "$_err_deploy" = "deploy" ]; then
                info "Self-heal: no database deployment found — deploying one"
                # Its result counts: personal_deploy_local returns non-zero when
                # it could not deploy (no usable Podman on Linux, a refused
                # install), having already said why. Returning 0 regardless made
                # `exakit start` exit 0 with no database behind it.
                personal_deploy_local || \
                    die "No database could be deployed (the reason is above). Once it is fixed, re-run the installer: $(exakit_install_command)"
                return 0
            fi
            die "No database found. Start one with: exakit start (or re-run the installer)"
            ;;
        *) return 0 ;;
    esac
}

# The AI-client table: the rows a reader ticks in the selection phase are the
# rows the progress phase fills in. The state file is what the two phases share
# (see ui_table_* in ui.sh); empty means this run has no table — a scripted
# EXAKIT_MCP_CLIENTS answer, or no terminal to draw one on.
EXAKIT_MCP_TABLE_STATE=""

# _exakit_mcp_table_release — the table is finished with: drop its state file and
# the two globals the component reads from the caller, so the NEXT table in the
# same run (the dataset load) is not left wearing this one's title and column
# heading.
_exakit_mcp_table_release() {
    UI_TABLE_TITLE=""
    UI_TABLE_COL1=""
    UI_TABLE_COL2=""
    UI_TABLE_COL3=""
    # And the read-only user's "already done" flag, which only ever covers the
    # one CLI call this table was drawn for: a later run in the same process
    # (mcp.sh's refresh after a redeploy) must prepare it again.
    EXAKIT_MCP_READONLY_READY=0
    if [ -n "$EXAKIT_MCP_TABLE_STATE" ]; then
        rm -f "$EXAKIT_MCP_TABLE_STATE" "$EXAKIT_MCP_TABLE_STATE.lines" \
            "$EXAKIT_MCP_TABLE_STATE.stop" "$EXAKIT_MCP_TABLE_STATE.new"
    fi
    EXAKIT_MCP_TABLE_STATE=""
    return 0
}

# _exakit_mcp_result_states <result-json> — one "<client-id> configured" or
# "<client-id> skipped" line per client the run touched, straight from the CLI's
# own record of what it wrote. The table's final cells are built from this rather
# than from the exit status, which cannot tell "one client's config file was
# unusable" from "nothing was configured".
_exakit_mcp_result_states() {
    [ -s "$1" ] || return 1
    exakit_can_run_python || return 1
    run_python - "$1" <<'PY' 2>/dev/null
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
details = doc.get("details") or {}
for client in details.get("configured_clients") or []:
    print(f"{client} configured")
for item in details.get("skipped_clients") or []:
    client = item.get("client")
    if client:
        print(f"{client} skipped")
PY
}

exakit_mcp_setup() {
    # About to create/verify the read-only database user: a stopped database
    # here used to surface as a bare "Connection refused" — heal it first.
    exakit_ensure_runtime_running

    info "MCP setup will edit the selected AI client config files."

    EXAKIT_MCP_TABLE_STATE=""
    _mcp_rows=""                    # the table rows the progress phase fills in

    # EXAKIT_MCP_CLIENTS lets an agent-driven or scripted install pick clients
    # without a prompt (e.g. "claude", "claude,cursor", "all", or "1,2").
    if [ -n "${EXAKIT_MCP_CLIENTS:-}" ]; then
        case "$EXAKIT_MCP_CLIENTS" in
            skip|SKIP|Skip|none|NONE|None)
                info "Skipping AI client setup (EXAKIT_MCP_CLIENTS=$EXAKIT_MCP_CLIENTS) — run 'exakit mcp-setup' any time."
                return 0
                ;;
        esac
        _clients_csv="$(exakit_parse_mcp_client_selection "$EXAKIT_MCP_CLIENTS")" || {
            warn "EXAKIT_MCP_CLIENTS='$EXAKIT_MCP_CLIENTS' is not valid (use claude, codex, cursor, copilot, gemini, opencode, continue, all, skip, or numbers 1-7)."
            return 1
        }
        case "$EXAKIT_MCP_CLIENTS" in
            all|ALL|All)
                # "all" means every client ON THIS MACHINE — the set the menu
                # offers — not every client the kit knows. The full list wrote
                # the read-only password into config files for four tools that
                # were not installed, and doctor then called them connected. A
                # client named explicitly is still configured, installed or not.
                _clients_all="$(exakit_mcp_detected_clients 2>/dev/null || true)"
                if [ -n "$_clients_all" ]; then
                    _clients_skipped=""
                    for _clients_one in $(printf '%s' "$_clients_csv" | tr ',' ' '); do
                        case ",$_clients_all," in
                            *",$_clients_one,"*) ;;
                            *) _clients_skipped="${_clients_skipped:+$_clients_skipped,}$_clients_one" ;;
                        esac
                    done
                    _clients_csv="$_clients_all"
                    [ -n "$_clients_skipped" ] && info "EXAKIT_MCP_CLIENTS=all — not installed here, skipped: $_clients_skipped (name one explicitly to configure it anyway)"
                fi
                ;;
        esac
        info "Configuring MCP clients from EXAKIT_MCP_CLIENTS: $_clients_csv"
    else
        # Show the FULL list of supported clients so the user sees everything
        # the kit can connect: pending clients (installed, not connected yet)
        # are selectable and pre-selected; clients that are already connected
        # or not installed on this machine appear as DISABLED rows with the
        # reason and cannot be checked. One "Claude" row covers both Claude
        # surfaces (desktop app + Claude Code CLI) while their states match;
        # when they differ, each surface gets its own row. Falls back to
        # everything selectable when discovery is unavailable.
        _cd_state=pending; _cc_state=pending; _codex_state=pending
        _cursor_state=pending; _copilot_state=pending; _gemini_state=pending
        _opencode_state=pending; _continue_state=pending
        if _client_status="$(exakit_mcp_discover_status)"; then
            while read -r _st_id _st_state; do
                [ -n "$_st_id" ] || continue
                case "$_st_id" in
                    claude_desktop)  _cd_state="$_st_state" ;;
                    claude_code)     _cc_state="$_st_state" ;;
                    codex)           _codex_state="$_st_state" ;;
                    cursor)          _cursor_state="$_st_state" ;;
                    vscode_copilot)  _copilot_state="$_st_state" ;;
                    gemini_cli)      _gemini_state="$_st_state" ;;
                    opencode)        _opencode_state="$_st_state" ;;
                    continue)        _continue_state="$_st_state" ;;
                esac
            done <<EOF
$_client_status
EOF
        fi
        _menu_labels=()
        _menu_ids=()
        _menu_notes=()
        _pending_count=0
        _connected_count=0
        # _exakit_mcp_menu_row <label> <state> <ids_csv> — one client row:
        # pending rows carry their ids and are selectable; connected and missing
        # rows carry no id and a note saying why, which is what makes them a
        # disabled row in the table.
        _exakit_mcp_menu_row() {
            _menu_labels+=("$1")
            case "$2" in
                pending)
                    _menu_ids+=("$3"); _menu_notes+=("")
                    _pending_count=$((_pending_count + 1))
                    ;;
                connected)
                    _menu_ids+=(""); _menu_notes+=("already connected")
                    _connected_count=$((_connected_count + 1))
                    ;;
                *)         _menu_ids+=(""); _menu_notes+=("not installed") ;;
            esac
        }
        if [ "$_cd_state" = "$_cc_state" ]; then
            _exakit_mcp_menu_row "Claude" "$_cd_state" "claude_desktop,claude_code"
        else
            _exakit_mcp_menu_row "Claude (desktop app)" "$_cd_state" "claude_desktop"
            _exakit_mcp_menu_row "Claude Code (CLI)" "$_cc_state" "claude_code"
        fi
        _exakit_mcp_menu_row "Codex" "$_codex_state" "codex"
        _exakit_mcp_menu_row "Cursor" "$_cursor_state" "cursor"
        _exakit_mcp_menu_row "GitHub Copilot" "$_copilot_state" "vscode_copilot"
        _exakit_mcp_menu_row "Gemini CLI" "$_gemini_state" "gemini_cli"
        _exakit_mcp_menu_row "OpenCode" "$_opencode_state" "opencode"
        _exakit_mcp_menu_row "Continue" "$_continue_state" "continue"
        if [ "$_pending_count" -eq 0 ]; then
            # NOTHING CONNECTED IS NOT EVERYTHING CONNECTED. Every row can be
            # "not installed" - a fresh machine with no AI client on it at all -
            # and the claim below was printed for that case too, telling the
            # reader their clients were wired up over MCP when the kit had not
            # touched a single config. Zero of zero is not success; say which
            # of the two happened.
            if [ "$_connected_count" -eq 0 ]; then
                info "No AI client was found on this machine, so there is nothing to connect yet."
                info "Install one (Claude, Codex, Cursor, Copilot, Gemini CLI, OpenCode, Continue) and run 'exakit mcp-setup'."
                return 0
            fi
            ok "All AI clients found on this machine are already connected over MCP."
            info "Check them with 'exakit mcp-status'; new clients appear here once installed."
            return 0
        fi
        # The read-only database user is prepared BEFORE the table is drawn.
        # Everything it does narrates itself, and from the moment the table is on
        # screen a line printed under it shifts the frame out from under the
        # cursor arithmetic that redraws it: the animator's first frame would
        # then repaint over its own table instead of the menu's, and the top of a
        # stale table is left stranded above it (the failure ui.sh's comments
        # describe). It is the kit's own database user, not any client's, so
        # preparing it before the choice costs a skipped run nothing but an idle
        # user — and it is what the next 'exakit mcp-setup' needs anyway.
        exakit_configure_mcp_readonly_access || return 1
        EXAKIT_MCP_READONLY_READY=1

        # ONE table for the whole step, the same component the dataset load uses
        # (ui_table_* in ui.sh): the rows a reader ticks are the rows that then
        # fill in, so nobody has to map one screen onto another.
        EXAKIT_MCP_TABLE_STATE="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-table.XXXXXX")" || {
            warn "Could not create a temporary file for the AI client table."
            _exakit_mcp_table_release
            return 1
        }
        _mcp_client_n="${#_menu_labels[@]}"
        _mcp_row_first=2
        _mcp_row_last=$(( _mcp_row_first + _mcp_client_n - 1 ))
        _mcp_row_skip=$(( _mcp_row_last + 1 ))
        printf 'group|Select All|0|idle|||||| \n' > "$EXAKIT_MCP_TABLE_STATE"
        _menu_i=0
        while [ "$_menu_i" -lt "$_mcp_client_n" ]; do
            if [ "$_menu_i" -eq $(( _mcp_client_n - 1 )) ]; then
                _mcp_kind=corner
            else
                _mcp_kind=tee
            fi
            printf '%s|%s|0|idle|||||| \n' "$_mcp_kind" "${_menu_labels[$_menu_i]}" \
                >> "$EXAKIT_MCP_TABLE_STATE"
            _menu_i=$(( _menu_i + 1 ))
        done
        printf 'plain|Skip|0|idle|||||| \n' >> "$EXAKIT_MCP_TABLE_STATE"
        # Pre-select every pending client, and the group row with them: under the
        # all-or-none parent it is ticked exactly while every pickable child is.
        # A client with no id is one this machine cannot offer — it becomes a
        # disabled row carrying the reason, so the list is the whole answer
        # rather than a list that quietly omits things.
        _defaults="1"
        _menu_i=0
        while [ "$_menu_i" -lt "$_mcp_client_n" ]; do
            _mcp_row=$(( _mcp_row_first + _menu_i ))
            if [ -n "${_menu_ids[$_menu_i]}" ]; then
                _defaults="$_defaults,$_mcp_row"
            else
                ui_table_disable "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" "${_menu_notes[$_menu_i]}"
            fi
            _menu_i=$(( _menu_i + 1 ))
        done
        EXAKIT_TABLE_GROUP="1:$_mcp_row_first:$_mcp_row_last:all"
        EXAKIT_TABLE_EXCLUSIVE="$_mcp_row_skip"
        EXAKIT_TABLE_DEFAULTS="$_defaults"
        UI_TABLE_TITLE="AI clients to connect"
        UI_TABLE_COL1="Client"
        UI_TABLE_COL2=""
        UI_TABLE_COL3=""
        printf '\n'
        # Loop so a not-confirmed skip returns the user to the menu.
        while :; do
            ui_table_menu "$EXAKIT_MCP_TABLE_STATE"
            case ",$EXAKIT_TABLE_SELECTION," in
                *",$_mcp_row_skip,"*)
                    warn "No AI client will be connected to your database."
                    if confirm "Are you sure you want to continue without an AI client?" y; then
                        info "Okay — you can connect one any time with: exakit mcp-setup"
                        exakit_print_no_ai_panel
                        _exakit_mcp_table_release
                        return 0
                    fi
                    # Back into the SAME table, not a second one under it: the
                    # frame is still on screen with the warning and the question
                    # below it (one line each), so the menu is told how far up
                    # its own top border is.
                    UI_TABLE_MENU_ONSCREEN=$(( UI_TABLE_LINES + 2 ))
                    continue                              # back to the menu
                    ;;
            esac
            break
        done
        _clients_csv=""
        for _client_idx in $(printf '%s' "$EXAKIT_TABLE_SELECTION" | tr ',' ' '); do
            [ "$_client_idx" -ge "$_mcp_row_first" ] && [ "$_client_idx" -le "$_mcp_row_last" ] || continue
            _client_id="${_menu_ids[$(( _client_idx - _mcp_row_first ))]}"
            [ -n "$_client_id" ] || continue              # disabled rows carry no id
            _clients_csv="${_clients_csv:+$_clients_csv,}$_client_id"
            _mcp_rows="${_mcp_rows:+$_mcp_rows,}$_client_idx"
        done
        if [ -z "$_clients_csv" ]; then
            # Enter needs a selection and the group row can never be the only
            # one ticked, so this is the impossible answer rather than a real
            # one. Still: never call the setup CLI with an empty client list.
            info "No AI client selected — connect one any time with: exakit mcp-setup"
            _exakit_mcp_table_release
            return 0
        fi
    fi

    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-setup.XXXXXX")"
    _setup_status=0
    _mcp_table_shown=0
    if [ -n "$EXAKIT_MCP_TABLE_STATE" ] && [ -n "$_mcp_rows" ]; then
        for _mcp_row in $(printf '%s' "$_mcp_rows" | tr ',' ' '); do
            ui_table_set "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" waiting
        done
        if ui_table_begin "$EXAKIT_MCP_TABLE_STATE"; then
            _mcp_table_shown=1
            # The bar sits on the GROUP row, not on a client row: ONE python
            # process configures every selected client, so there is no
            # per-client checkpoint a per-client bar could be honest about. The
            # client rows wait, and each one's final cell is read out of the
            # result file afterwards — nothing on screen calls a client done
            # before the run says it is.
            ui_table_set "$EXAKIT_MCP_TABLE_STATE" 1 running 5 90 20 "writing client configs"
        fi
    fi
    # No live table to say what is happening: say it in a line, as before. With
    # the table there is nothing to add — and a line printed here would land
    # between the menu's frame and the animator's first frame, which is the one
    # place on this screen where nothing may be printed.
    [ "$_mcp_table_shown" = 1 ] || info "Applying MCP setup"
    if exakit_run_mcp_setup_cli "$_clients_csv" "$_result_file"; then
        :
    else
        _setup_status=$?
    fi
    if [ "$_mcp_table_shown" = 1 ]; then
        # What each row ends up saying comes from the result file, client by
        # client: one client can be skipped on its own (an unparseable config
        # file of its own) while every other client is configured, and the exit
        # status cannot tell those two apart.
        _mcp_states="$(_exakit_mcp_result_states "$_result_file" 2>/dev/null || true)"
        _mcp_ok_n=0
        _mcp_sel_n=0
        for _mcp_row in $(printf '%s' "$_mcp_rows" | tr ',' ' '); do
            _mcp_sel_n=$(( _mcp_sel_n + 1 ))
            _mcp_id_n=0
            _mcp_id_ok=0
            for _mcp_id in $(printf '%s' "${_menu_ids[$(( _mcp_row - _mcp_row_first ))]}" | tr ',' ' '); do
                _mcp_id_n=$(( _mcp_id_n + 1 ))
                # grep, not a case pattern: bash 3.2 mis-parses case patterns
                # written inside $( ).
                if printf '%s\n' "$_mcp_states" | grep -qxF "$_mcp_id configured"; then
                    _mcp_id_ok=$(( _mcp_id_ok + 1 ))
                fi
            done
            if [ "$_mcp_id_ok" -eq 0 ]; then
                ui_table_set "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" failed "" "" "" "" \
                    "not configured"
            elif [ "$_mcp_id_ok" -eq "$_mcp_id_n" ]; then
                ui_table_set "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" done "" "" "" "" \
                    "configured"
                _mcp_ok_n=$(( _mcp_ok_n + 1 ))
            else
                # The Claude row is two surfaces behind one label; say which
                # rather than call a half-written row configured.
                ui_table_set "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" done "" "" "" "" \
                    "configured · $_mcp_id_ok of $_mcp_id_n"
                _mcp_ok_n=$(( _mcp_ok_n + 1 ))
            fi
        done
        if [ "$_mcp_sel_n" = 1 ]; then _mcp_unit=client; else _mcp_unit=clients; fi
        if [ "$_mcp_ok_n" -eq "$_mcp_sel_n" ]; then
            ui_table_set "$EXAKIT_MCP_TABLE_STATE" 1 done "" "" "" "" \
                "configured · $_mcp_sel_n $_mcp_unit"
        else
            ui_table_set "$EXAKIT_MCP_TABLE_STATE" 1 failed "" "" "" "" \
                "$_mcp_ok_n of $_mcp_sel_n $_mcp_unit configured"
        fi
        # Normally still animating. A failed CLI stops the animation itself
        # before it warns, so that its warning is not painted into the frame —
        # and then the frame on screen is already the last one.
        if [ -n "${_UI_TABLE_ACTIVE:-}" ]; then
            ui_table_end "$EXAKIT_MCP_TABLE_STATE"
        fi
    fi
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_setup_summary "$_result_file" "$_mcp_table_shown"
    fi
    rm -f "$_result_file"
    _exakit_mcp_table_release
    if [ "$_setup_status" -ne 0 ]; then
        return "$_setup_status"
    fi
    exakit_print_mcp_ready_panel "permanent"
    # The panel above IS the guidance; announcing that it exists, directly
    # under it, told the reader nothing they had not just read.
    return 0
}

exakit_mcp_operation() {
    _operation="$1"
    shift
    _clients_csv="$(exakit_mcp_clients_from_args "$@")" || {
        warn "Please choose valid AI clients: claude, claude_desktop, claude_code, codex, cursor, copilot, gemini, opencode, continue, or all."
        return 1
    }
    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-operation.XXXXXX")"
    _operation_status=0
    # _exakit_stamp_mcp_json <file> — print the MCP result with `installed` and
    # `remedy` added. Fails (prints nothing) when the file is not a JSON object,
    # so the caller can fall back to passing it through untouched.
    _exakit_stamp_mcp_json() {
        exakit_can_run_python || return 1
        run_python - "$1" <<'EXAKIT_MCP_STAMP_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
doc.setdefault("installed", True)
if "remedy" not in doc:
    # From a WARNING or ERROR finding only. Taking the first next_action made a
    # healthy machine answer "Install the client..." off an INFO finding about
    # a client that is not installed, so `remedy != null` could not be branched on.
    # Worst first, and a finding about a FILE before one about a client that
    # is merely absent: with a loosened mode on Codex and a stale Cursor
    # record, the hoisted remedy used to be the Cursor one because it came
    # first in the list.
    RANK = {"critical": 0, "error": 1, "warning": 2}
    candidates = []
    for index, finding in enumerate(doc.get("findings") or []):
        if not isinstance(finding, dict) or not finding.get("recommended_action"):
            continue
        severity = str(finding.get("severity", "")).lower()
        if severity not in RANK:
            continue
        scope = finding.get("scope") if isinstance(finding.get("scope"), dict) else {}
        candidates.append((RANK[severity], 0 if scope.get("path") else 1, index, finding["recommended_action"]))
    remedy = min(candidates)[3] if candidates else None
    doc["remedy"] = remedy
print(json.dumps(doc, indent=2, sort_keys=True))
EXAKIT_MCP_STAMP_PY
    }
    # JSON mode (EXAKIT_MCP_RESULT_JSON=1): the operation's own result file is
    # already the machine-readable truth the summary is rendered from — print
    # it verbatim and keep every human line off stdout.
    if [ "${EXAKIT_MCP_RESULT_JSON:-0}" = "1" ]; then
        if ( exakit_run_mcp_operation_cli "$_operation" "$_clients_csv" "$_result_file" ) >/dev/null 2>&1; then
            :
        else
            _operation_status=$?
        fi
        if [ -s "$_result_file" ]; then
            # Add the discriminators every --json answer from a state query
            # carries — `installed` and `remedy` — so one parser handles the
            # healthy report, the database-down answer and the not-installed
            # answer alike. The subsystem's own fields are never touched, and a
            # result that is not valid JSON is passed through byte for byte
            # rather than swallowed.
            _exakit_stamp_mcp_json "$_result_file" || cat "$_result_file"
        else
            printf '{"installed": true, "status": "error", "remedy": "exakit logs setup", "error": "the MCP %s operation produced no result; what it printed is in: exakit logs setup"}\n' "$_operation"
            [ "$_operation_status" -eq 0 ] && _operation_status=1
        fi
        rm -f "$_result_file"
        case "$_operation" in
            doctor|validate) _exakit_reassert_mcp_readonly_posture >/dev/null 2>&1 || _operation_status=1 ;;
        esac
        return "$_operation_status"
    fi
    # The spinner says it, rather than a line that stays on screen after the
    # thing it announced has finished. The CLI below is silent for a second or
    # two, so without an animation the screen would simply sit there.
    # Quieted BEFORE the info, or the line prints and the spinner then says the
    # same thing underneath it. On a terminal the animation is the narration and
    # the logfile keeps the record; piped or redirected there is no spinner, so
    # the line stays and nothing is lost.
    _mos_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    info "Running MCP $_operation"
    ui_spin_begin "Running MCP $_operation"
    if exakit_run_mcp_operation_cli "$_operation" "$_clients_csv" "$_result_file"; then
        :
    else
        _operation_status=$?
    fi
    ui_spin_end
    EXAKIT_QUIET_DETAIL="$_mos_prev_quiet"
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_operation_summary "$_result_file"
    fi
    # Whether the report holds something repair can put right - a loosened
    # file mode, a drifted or missing entry - even when the run's status was
    # only "success with warnings" and the exit code 0. Doctor reads this to
    # decide to repair: a warning it can fix and does not is a warning the
    # reader has to fix by hand, and the report told them doctor repairs drift.
    EXAKIT_MCP_LAST_REPAIRABLE=0
    if [ -s "$_result_file" ] && _exakit_mcp_result_repairable "$_result_file"; then
        EXAKIT_MCP_LAST_REPAIRABLE=1
    fi
    rm -f "$_result_file"

    case "$_operation" in
        doctor|validate)
            _exakit_reassert_mcp_readonly_posture || _operation_status=1
            ;;
    esac

    # A diagnosis is only useful next to its remedy. Doctor is the command people
    # run when something looks wrong with an AI client, and the answer is almost
    # always the same one — so name it rather than making them go and find it.
    case "$_operation" in
        doctor) info "Connect or re-connect AI clients any time with:  exakit mcp-setup" ;;
    esac

    return "$_operation_status"
}

exakit_maybe_offer_mcp_setup() {
    _already_done="$(manifest_get components.mcp_server.client_setup.completed 2>/dev/null || true)"
    [ "$_already_done" = "true" ] && return 0
    if [ "${EXAKIT_SKIP_MCP:-}" = "1" ]; then
        info "Skipping AI client setup (EXAKIT_SKIP_MCP=1). Run it any time with: exakit mcp-setup"
        return 0
    fi
    # Connecting an AI client is the point of the kit, so this step always
    # runs (EXAKIT_SKIP_MCP=1 above is the scripted escape hatch). The client
    # selection pre-selects every detected-but-unconnected client;
    # non-interactive runs keep that default.
    # No lead-in: the ticks directly above already said the runtime and the
    # server are ready, and this restated them in a sentence.
    if ! exakit_mcp_setup; then
        warn "Your local database is installed, but AI client setup did not finish cleanly."
        warn "Retry any time with: exakit mcp-setup"
        exakit_note_failure "the AI client configuration did not finish (see the log)"
        return 1
    fi
}

# exakit_maybe_offer_data_load <kit_root> — load data during install, via the
# dynamic dataset checkbox (bundled datasets not loaded yet are pre-selected;
# the user can additionally or instead pick a local file, or explicitly skip).
# Scripted installs can still steer with EXAKIT_DATASETS (csv of bundled
# dataset ids) or EXAKIT_LOAD_SAMPLE (=0 skips, =1 bundled sample);
# EXAKIT_DATASETS takes precedence. Non-interactive runs keep the
# pre-selected defaults. Each load runs in a subshell so a die() inside the
# loading flow never aborts the surrounding install.
exakit_maybe_offer_data_load() {
    _kit_root="$1"
    : "$_kit_root"
    command -v exakit_load_sample_data >/dev/null 2>&1 || return 0

    # YOUR OWN DATA FIRST, THEN THE SAMPLE. The copy out of the old container
    # needs three things this point in the run is the first to have: a database
    # that is up, an exapump binary, and a profile pointing at the new database.
    # It used to run at the very end, after the sample load and every other
    # step, which put a user's own tables last in a run that is mostly about
    # them. Tables that a bundled dataset would create are left in the copy
    # rather than restored, so the load that follows cannot overwrite them --
    # see legacy_import.
    command -v legacy_crossing_after >/dev/null 2>&1 && legacy_crossing_after

    # EXAKIT_DATASETS names bundled datasets directly (csv of ids from
    # data/datasets/<id>/, e.g. "tpch,weather") so an agent-driven or scripted
    # install can pick an exact selection. Unknown ids warn and are skipped;
    # if none are valid the install stops — the caller asked for something
    # this kit does not ship.
    # Every path below reports through _data_failed, so the caller can book the
    # step in the closing summary. Nothing here ends the run any more: an empty
    # database is a thing to repair with one command, not a reason to abandon an
    # install whose database is already up.
    _data_failed=0
    if [ -n "${EXAKIT_DATASETS:-}" ]; then
        _known_ids=" $(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ' ') "
        _valid_any=0
        for _env_id in $(printf '%s' "$EXAKIT_DATASETS" | tr ',' ' '); do
            case "$_known_ids" in
                *" $_env_id "*)
                    _valid_any=1
                    info "Loading dataset '$_env_id' (EXAKIT_DATASETS)."
                    if ! ( exakit_load_dataset "$_kit_root" "$_env_id" ); then
                        warn "Data loading did not finish cleanly. Retry any time with: exakit data-load"
                        exakit_note_failure "loading dataset '$_env_id' did not finish (see the log)"
                        _data_failed=1
                    fi
                    ;;
                *)
                    warn "Unknown dataset id '$_env_id' in EXAKIT_DATASETS (available:$(printf '%s' "$_known_ids" | sed 's/ *$//'))."
                    ;;
            esac
        done
        if [ "$_valid_any" -ne 1 ]; then
            error "EXAKIT_DATASETS='$EXAKIT_DATASETS' matched no bundled dataset — nothing was loaded."
            exakit_note_failure "EXAKIT_DATASETS='$EXAKIT_DATASETS' matched no bundled dataset"
            return 1
        fi
        return "$_data_failed"
    fi

    # EXAKIT_LOAD_SAMPLE lets an agent-driven or scripted install decide up front:
    # =1 loads the bundled sample without asking, =0 skips data loading entirely.
    if [ "${EXAKIT_LOAD_SAMPLE:-}" = "0" ]; then
        info "Skipping data loading (EXAKIT_LOAD_SAMPLE=0). Run it any time with: exakit data-load"
        return 0
    fi
    if [ "${EXAKIT_LOAD_SAMPLE:-}" = "1" ]; then
        info "Loading the bundled sample data (EXAKIT_LOAD_SAMPLE=1)."
        if ! ( exakit_load_sample_data "$_kit_root" ); then
            warn "Data loading did not finish cleanly. Retry any time with: exakit data-load"
            exakit_note_failure "the bundled sample data did not finish loading (see the log)"
            return 1
        fi
        return 0
    fi

    # No lead-in sentence: the checkbox below names every dataset on offer and
    # the skip, which is the whole of what this line was explaining.
    # Dynamic dataset checkbox (shared with `exakit data-load`): only bundled
    # datasets that are not loaded yet are offered, plus the local-file option
    # and an explicit skip. Each load runs in a subshell so a die() inside the
    # loading flow never aborts the surrounding install.
    exakit_data_load_select "Skip"
    if [ "$EXAKIT_DATA_LOAD_SELECTION" = "none" ]; then
        info "Skipping data loading. Run it any time with: exakit data-load"
        return 0
    fi
    # The SAME table the selection was just made in becomes the progress display.
    # This is the path an install actually takes, and it was the one left out:
    # exakit_data_load_menu (the standalone `exakit data-load`) started the table
    # and this loop did not, so during an install the table drew, stayed empty,
    # and every dataset fell back to the single-line bar underneath it.
    #
    # The loads below run in subshells, which is exactly why a row's state lives
    # in a FILE: a subshell can write to it, and could never write to a variable
    # the animator would see.
    EXAKIT_TABLE_LIVE=0
    if [ -n "${EXAKIT_TABLE_STATE:-}" ]; then
        ui_table_begin "$EXAKIT_TABLE_STATE" && EXAKIT_TABLE_LIVE=1
    fi
    _data_notes=""
    _data_has_local=0
    # Anything fatal inside the loads below is written here instead of onto the
    # animating table; it is read out after ui_table_end.
    EXAKIT_DEFER_ERRORS=""
    if [ "$EXAKIT_TABLE_LIVE" = 1 ]; then
        EXAKIT_DEFER_ERRORS="$EXAKIT_TABLE_STATE.fatal"
        : > "$EXAKIT_DEFER_ERRORS"
    fi
    for _data_id in $(printf '%s' "$EXAKIT_DATA_LOAD_SELECTION" | tr ',' ' '); do
        case "$_data_id" in
            local)
                # Deferred until the table has stopped - see below. This row is
                # made of QUESTIONS, and ui_table_detach does not take the frame
                # off the screen: the animator kept repainting over the prompt.
                _data_has_local=1
                ;;
            *)
                if ! ( ui_table_detach; exakit_load_dataset "$_kit_root" "$_data_id" ); then
                    _data_notes="${_data_notes}warn|Data loading did not finish cleanly. Retry any time with: exakit data-load
"
                    exakit_note_failure "loading dataset '$_data_id' did not finish (see the log)"
                    _data_failed=1
                fi
                ;;
        esac
    done
    # The table stops redrawing BEFORE anything is said over it. A warn printed
    # into a frame that is still being repainted lands inside the box.
    [ "$EXAKIT_TABLE_LIVE" = 1 ] && ui_table_end "$EXAKIT_TABLE_STATE"
    EXAKIT_TABLE_LIVE=0
    if [ -n "$EXAKIT_DEFER_ERRORS" ] && [ -s "$EXAKIT_DEFER_ERRORS" ]; then
        while IFS='|' read -r _df_kind _df_text; do
            [ -n "$_df_text" ] || continue
            error "$_df_text"
        done < "$EXAKIT_DEFER_ERRORS"
        rm -f "$EXAKIT_DEFER_ERRORS"
    fi
    EXAKIT_DEFER_ERRORS=""
    # The local file / folder load, now that the box has stopped moving.
    #
    # This is the INSTALLER's copy of the data-load loop -- `exakit data-load`
    # has its own in exapump.sh -- and it was left behind when that one was
    # fixed. The symptom is the same and worse here: the animator repaints every
    # 80ms, so the prompt was overwritten mid-question and the typed path landed
    # on top of the words, "/Users/me/data  or a folder of them (type back to
    # return)". On the install screen the frame was reprinted twenty-two times.
    #
    # ui_table_detach was never the answer: it stops a subshell's exit from
    # killing the animator, it does not take the frame off the screen.
    if [ "$_data_has_local" = 1 ]; then
        printf '\n'
        ( exakit_load_local_file )
        _local_status=$?
        if [ "$_local_status" -eq 2 ]; then
            _data_notes="${_data_notes}info|Local file load skipped.
"
        elif [ "$_local_status" -eq 3 ]; then
            # Refused as bad input (the file, not the install): say so, but
            # do not book it as a failed step.
            _data_notes="${_data_notes}warn|The local file was refused (see above). Load another any time with: exakit data-load
"
        elif [ "$_local_status" -ne 0 ]; then
            _data_notes="${_data_notes}warn|Data loading did not finish cleanly. Retry any time with: exakit data-load
"
            exakit_note_failure "loading the local file did not finish (see the log)"
            _data_failed=1
        fi
    fi
    while IFS='|' read -r _dn_kind _dn_text; do
        [ -n "$_dn_text" ] || continue
        case "$_dn_kind" in
            warn) warn "$_dn_text" ;;
            *)    info "$_dn_text" ;;
        esac
    done <<EXAKIT_DATA_NOTES_EOF
$_data_notes
EXAKIT_DATA_NOTES_EOF
    return "$_data_failed"
}

# kit_shared_steps <first-step-no> <total-steps> <script-dir> <kit-root>
# The steps every platform runs after its runtime is up, in order: exapump,
# the sample-data load offer, the MCP server, the exakit helper, and the MCP
# client setup offer. Data is loaded before MCP so the read-only user is
# provisioned against a populated schema. One implementation so the per-OS
# setup scripts cannot drift apart.
# exakit_soft_step <component> <repair-command> <label> <function...> — run one
# component's install without letting it end the run.
#
# <label> is what the reader is shown, in both the mid-run warning and the
# closing summary. Without it both fell back to the raw component id, so the
# screen said "mcp did not finish" and then "mcp is not installed" -- an
# internal key, in a sentence addressed to someone who never sees one anywhere
# else in the install. The other soft-failure callers already pass a label
# ("sample data", "AI client (MCP) setup", "AI skills"); this one had no way to.
#
# The component installers die() on failure, and die() exits. exapump alone has 32
# of them, and it runs three steps before the `exakit` command is installed: a
# broken download left the user with a deployed database, no CLI, and no way to
# repair it except re-running the whole installer. So each component runs in a
# subshell, and a failure is recorded and stepped over instead of ending the run.
#
# Nothing is lost to the subshell: these functions keep their state in the manifest
# and on disk, not in shell variables, and no component reads a global set by
# another one.
exakit_soft_step() {
    _ss_component="$1"
    _ss_repair="$2"
    _ss_label="$3"
    [ -n "$_ss_label" ] || _ss_label="$_ss_component"
    shift 3
    # Start from a clean slate so a reason left by an earlier step cannot be
    # attributed to this one.
    exakit_clear_failure_note
    if ( "$@" ); then
        exakit_clear_failure_note
        return 0
    fi
    exakit_record_soft_failure "$_ss_component" "$_ss_repair" "$(exakit_take_failure_note)" "$_ss_label"
    warn "$_ss_label did not finish — carrying on so the rest of the install completes"
    return 1
}

# exakit_record_soft_failure <component> <repair> [reason] [label] — book a
# step as "did not complete" without any of the running/subshell machinery.
#
# The soft-step wrapper is for component installers that die(); this is for the
# steps that report failure by returning non-zero or by being wrapped in `|| true`
# (the data load, the AI client wiring, the skills copy). Before this they failed
# silently as far as the closing summary was concerned, so a user whose sample data
# never loaded saw a clean "Setup complete" and no way to know.
exakit_record_soft_failure() {
    _rsf_component="$1"
    _rsf_repair="$2"
    _rsf_reason="${3:-}"
    _rsf_label="${4:-}"
    # First failure wins: a later, vaguer report must not overwrite the specific
    # reason the original failure recorded.
    exakit_soft_failed "$_rsf_component" && return 0
    EXAKIT_SOFT_FAILED="${EXAKIT_SOFT_FAILED:-}${EXAKIT_SOFT_FAILED:+ }$_rsf_component"
    # The repair command and the reason travel with the failure, so the summary
    # never has to guess either back.
    eval "EXAKIT_SOFT_REPAIR_${_rsf_component}=\"\$_rsf_repair\""
    eval "EXAKIT_SOFT_REASON_${_rsf_component}=\"\$_rsf_reason\""
    eval "EXAKIT_SOFT_LABEL_${_rsf_component}=\"\$_rsf_label\""
    return 0
}

# exakit_soft_failed <component> — did this component fail earlier in the run?
exakit_soft_failed() {
    case " ${EXAKIT_SOFT_FAILED:-} " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# exakit_print_soft_failures — the closing account of what did not make it.
#
# Said plainly, with what went wrong and the exact command that fixes it: the
# install is usable, some of it is missing, and here is the one line per piece
# that repairs it. Printed last, after the connection panel, so it is the final
# thing on screen rather than something scrolled past mid-install.
exakit_print_soft_failures() {
    [ -n "${EXAKIT_SOFT_FAILED:-}" ] || return 0
    _sf_count=0
    for _sf in $EXAKIT_SOFT_FAILED; do
        _sf_count=$((_sf_count + 1))
    done
    printf '\n'
    if [ "$_sf_count" = "1" ]; then
        warn "The install finished, but one step did not complete:"
    else
        warn "The install finished, but $_sf_count steps did not complete:"
    fi
    printf '\n'
    for _sf in $EXAKIT_SOFT_FAILED; do
        eval "_sf_repair=\"\${EXAKIT_SOFT_REPAIR_${_sf}:-}\""
        eval "_sf_reason=\"\${EXAKIT_SOFT_REASON_${_sf}:-}\""
        eval "_sf_label=\"\${EXAKIT_SOFT_LABEL_${_sf}:-}\""
        [ -n "$_sf_label" ] || _sf_label="$_sf"
        printf '      %s%s%s is not installed: %s\n' \
            "${UI_BOLD:-}" "$_sf_label" "${UI_RESET:-}" \
            "${_sf_reason:-the step did not finish (see the log)}"
        printf '        reinstall it with:  %s%s%s\n' \
            "${UI_ACCENT:-}" "${_sf_repair:-see the log}" "${UI_RESET:-}"
    done
    printf '\n'
    # Not "the database" when the database is what failed: the summary
    # used to list it as missing and then, one line on, as ready.
    case " $EXAKIT_SOFT_FAILED " in
        *" runtime "*) info "Everything that does not need the database is ready, including the exakit command itself." ;;
        *) info "Everything else is ready — the database, and the exakit command itself." ;;
    esac
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        info "Full detail for each failure: $EXAKIT_LOG_FILE"
    fi
    info "See where you stand any time with: exakit status"
    return 0
}

# The component chains, named so exakit_soft_step has something to isolate.
# Three lines for this step, not nine. run_logged animates the label
# begin_step set, so the info bullets under it were the second telling, and the
# checksum tick named a mktemp temp file rather than the asset (exapump
# downloads to a bare mktemp path, so basename saw "exakit-exapump.ANyKf0").
# What survives goes through ok_step: what was installed and where, the profile
# name someone types again, and the one fact the next two steps depend on --
# that the database can persist a schema, not merely answer SELECT 1.
_exakit_install_exapump() {
    _eie_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    exapump_install || { EXAKIT_QUIET_DETAIL="$_eie_prev_quiet"; return 1; }
    exapump_create_profile || { EXAKIT_QUIET_DETAIL="$_eie_prev_quiet"; return 1; }
    exapump_validate_connection
    _eie_rc=$?
    EXAKIT_QUIET_DETAIL="$_eie_prev_quiet"
    return $_eie_rc
}

# One line for this step's server work: the spinner narrates the prime and the
# handshake, so the info/ok pairs beneath were the second telling.
_exakit_install_mcp() {
    _eim_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    if ! mcp_install; then
        EXAKIT_QUIET_DETAIL="$_eim_prev_quiet"
        return 1
    fi
    mcp_validate
    _eim_rc=$?
    EXAKIT_QUIET_DETAIL="$_eim_prev_quiet"
    return $_eim_rc
}

# pyexasol_validate used to run OUTSIDE the soft step, which defeated the whole
# point of the step being soft: the driver could install fine and a die() from
# anywhere inside validation (a manifest write on a full disk, say) still ended
# the run before the exakit helper was installed. Install and validate belong to
# the same isolated unit.
# Two lines for this step, not five: the outcome, and the interpreter to run it
# with. Everything between -- the venv creation, the pip resolve, the SELECT 1
# narration -- is in the logfile, and the spinner covered it live.
_exakit_install_pyexasol() {
    _eip_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    if ! pyexasol_install; then
        EXAKIT_QUIET_DETAIL="$_eip_prev_quiet"
        return 1
    fi
    pyexasol_validate || true
    EXAKIT_QUIET_DETAIL="$_eip_prev_quiet"
}

# --- What's new -------------------------------------------------------------
#
# ONE source: setup/whats-new.json, a version -> array-of-lines map. The card the
# installer draws after an upgrade and the text `exakit whats-new` prints are the
# same lines, so there is nothing to keep in step.
#
# This block used to parse WHATS-NEW.md with awk, deliberately, so that a missing
# interpreter could not turn a successful upgrade into a failure. JSON needs a
# real parser, so that property is gone: on a machine without python3 the cards
# simply do not appear. That is survivable where the old design's concern was
# not — the box is best-effort already, and manifest_get requires python3 for
# every other thing the kit does, so a box that cannot run it has no working kit
# to upgrade in the first place. Every function here stays quiet on failure.
EXAKIT_WHATS_NEW_POINT_WIDTH=68
EXAKIT_WHATS_NEW_POINTS_PER_VERSION=6

# exakit_whats_new_file <kit-root> — the card source, or non-zero when this kit
# copy does not carry one (an older kit, or a partial download).
exakit_whats_new_file() {
    _wnf_root="${1:-}"
    [ -n "$_wnf_root" ] || return 1
    [ -f "$_wnf_root/setup/whats-new.json" ] || return 1
    printf '%s\n' "$_wnf_root/setup/whats-new.json"
}

# _exakit_whats_new_py <file> <mode> [from] [to] — the one parser.
#   mode "versions": every version in (from, to], oldest first
#   mode "points":   the lines of the single version passed as <from>
# Keys starting with "_" are comments in the file and are never versions.
_exakit_whats_new_py() {
    exakit_can_run_python 2>/dev/null || return 1
    run_python - "$1" "$2" "${3:-}" "${4:-}" "$EXAKIT_WHATS_NEW_POINT_WIDTH" \
        "$EXAKIT_WHATS_NEW_POINTS_PER_VERSION" <<'PY' 2>/dev/null
import json, sys
path, mode, a, b, width, maxpoints = sys.argv[1:7]
width, maxpoints = int(width), int(maxpoints)
try:
    with open(path) as f:
        doc = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)

def key(v):
    # Dotted numbers only, so a jump sorts the way a human reads it. Anything
    # else is skipped rather than guessed at.
    return tuple(int(p) for p in v.split("."))

versions = []
for k in doc:
    if k.startswith("_") or not isinstance(doc[k], list):
        continue
    try:
        versions.append((key(k), k))
    except ValueError:
        continue
versions.sort()

if mode == "versions":
    lo = key(a) if a else None
    hi = key(b) if b else None
    for kk, name in versions:
        if lo is not None and kk <= lo:
            continue
        if hi is not None and kk > hi:
            continue
        print(name)
    sys.exit(0)

if mode == "points":
    for line in doc.get(a, [])[:maxpoints]:
        if not isinstance(line, str):
            continue
        line = " ".join(line.split())
        if not line:
            continue
        # Authoring is guarded by tests/whats-new.sh; this is the last resort so
        # an over-long line cannot break the box's borders.
        if len(line) > width:
            line = line[: width - 3].rstrip() + "..."
        print("  - " + line)
    sys.exit(0)
sys.exit(1)
PY
}

# exakit_whats_new_versions <kit-root> <from> <to> — the versions with cards that
# lie in (from, to], oldest first. A `to` older than `from` (a downgrade) selects
# nothing, which is what keeps the box off the screen.
exakit_whats_new_versions() {
    _wnv_file="$(exakit_whats_new_file "$1")" || return 1
    _exakit_whats_new_py "$_wnv_file" versions "${2:-}" "${3:-}"
}

# exakit_whats_new_points <kit-root> <version> — one line per highlight, as
# "  - text". Non-zero when that version has no card.
exakit_whats_new_points() {
    _wnp_file="$(exakit_whats_new_file "$1")" || return 1
    _wnp_out="$(_exakit_whats_new_py "$_wnp_file" points "${2:-}")" || return 1
    [ -n "$_wnp_out" ] || return 1
    printf '%s\n' "$_wnp_out"
}

# exakit_print_whats_new <version> [heading] — what `exakit whats-new` shows.
exakit_print_whats_new() {
    _pwn_version="$1"
    _pwn_heading="${2:-}"
    _pwn_root="$(exakit_repo_root 2>/dev/null || true)"
    [ -n "$_pwn_root" ] || return 1
    _pwn_body="$(exakit_whats_new_points "$_pwn_root" "$_pwn_version")" || return 1
    # The same card the installer draws. `exakit whats-new` is the command the
    # card itself points at ("Full notes: exakit whats-new 0.2.0"), so printing
    # loose lines there made the follow-up look like a lesser version of the
    # thing that sent you.
    printf '\n'
    # Built in two steps, not "${_pwn_heading:-What's new in ...}": inside a
    # ${:-} default bash treats the apostrophe as an opening quote, so the
    # string ran on to the next apostrophe ANYWHERE in the file and swallowed
    # 300 lines of function bodies with it. `bash -n` accepts that happily -
    # it is valid syntax, just not the program anyone wrote.
    _pwn_title="$_pwn_heading"
    [ -n "$_pwn_title" ] || _pwn_title="What's new in $_pwn_version"
    ui_panel_begin "$_pwn_title"
    # Fed by a here-document, not a pipe: ui_panel_line buffers into a variable,
    # and a pipeline would build that buffer in a subshell.
    while IFS= read -r _pwn_line; do
        [ -n "$_pwn_line" ] || continue
        ui_panel_line "$_pwn_line"
    done <<PWN_BODY
$_pwn_body
PWN_BODY
    ui_panel_end
    printf '\n'
    return 0
}


# exakit_note_kit_upgrade <kit-root> — record the kit version installed BEFORE
# this run, for the box at the end to read. Call it while the manifest still holds
# the previous run's number.
#
# The record is in the manifest, not an environment variable, because a run that
# dies partway has already overwritten kit.version: the next re-run would compare
# the new number against itself, decide nothing moved, and lose the notes for a
# hop nobody ever saw. A pending record therefore wins over anything this run
# computes, and only the box clears it.
exakit_note_kit_upgrade() {
    _nku_pending="$(manifest_get kit.whats_new_from 2>/dev/null || true)"
    [ -z "$_nku_pending" ] || return 0
    _nku_now="$(exakit_kit_version_at "${1:-}" 2>/dev/null || true)"
    [ -n "$_nku_now" ] || return 0
    _nku_was="$(manifest_get kit.version 2>/dev/null || true)"

    # kit.version did not exist before 0.2.0, so an install made by an older kit
    # records no version at all. Treating "no version" as "no previous install"
    # silenced the cards for the ONLY upgrade anyone can currently make: every
    # existing user is on a kit that predates the field, so the feature stayed
    # quiet for exactly the people it exists for.
    #
    # A prior install still leaves proof - it was installed at a time, and it
    # completed steps - so an unversioned manifest with either is an upgrade
    # from something older than we can name, not a first install.
    if [ -z "$_nku_was" ]; then
        # Proof of a PRIOR install, and manifest_init is why this has to be
        # careful: a brand-new manifest already carries installed_at and
        # "steps_completed": [], so either of those alone marks a first-ever
        # install as an upgrade and shows cards to someone who has just met the
        # kit. A COMPLETED step is the thing only a previous run can leave.
        _nku_steps="$(manifest_get steps_completed 2>/dev/null || true)"
        case "$_nku_steps" in
            ''|'[]') _nku_prior=0 ;;
            *)       _nku_prior=1 ;;
        esac
        if [ "$_nku_prior" = 1 ]; then
            # The sentinel is not a version: it means "no lower bound", so every
            # card up to the new version is shown, and the box words itself
            # without claiming a number the manifest never held.
            _nku_was="__unversioned__"
        else
            # A genuine first-ever install: nothing to announce.
            return 0
        fi
    fi

    if [ "$_nku_was" != "__unversioned__" ]; then
        [ "$_nku_was" != "$_nku_now" ] || return 0
        # Only forward. A downgrade has no notes to read out anyway, and recording
        # one would leave a pending marker no later run could resolve.
        exakit_version_newer "$_nku_now" "$_nku_was" || return 0
    fi
    ( manifest_set kit.whats_new_from "$_nku_was" ) >/dev/null 2>&1 || true
    return 0
}

# exakit_print_whats_new_box [kit-root] — the box itself, after the connection
# panel. Prints only when the kit version moved during this run.
#
# No record means nothing is printed, which is the whole reason a first install
# and an idempotent re-run stay silent: the installer is documented as safe to
# re-run, and a box on every no-op run teaches people to ignore it.
exakit_print_whats_new_box() {
    _pwb_root="${1:-}"
    [ -n "$_pwb_root" ] || _pwb_root="$(exakit_repo_root 2>/dev/null || true)"
    _pwb_from="$(manifest_get kit.whats_new_from 2>/dev/null || true)"
    [ -n "$_pwb_from" ] || return 0
    _pwb_to="$(exakit_kit_version_at "$_pwb_root" 2>/dev/null || true)"
    [ -n "$_pwb_to" ] || _pwb_to="$(manifest_get kit.version 2>/dev/null || true)"

    # The sentinel from an unversioned predecessor: no lower bound, so every card
    # up to this version is shown.
    _pwb_lower="$_pwb_from"
    [ "$_pwb_lower" = "__unversioned__" ] && _pwb_lower=""
    _pwb_versions=""
    if [ -n "$_pwb_root" ] && [ -n "$_pwb_to" ]; then
        _pwb_versions="$(exakit_whats_new_versions "$_pwb_root" "$_pwb_lower" "$_pwb_to" 2>/dev/null || true)"
    fi
    if [ -n "$_pwb_versions" ]; then
        # ONE width for every card. ui_panel_end sizes a panel to its own longest
        # line, so a three-version jump drew three boxes of three widths and read
        # as a staircase rather than one announcement.
        _pwb_w=0
        _pwb_any=0
        _pwb_last=""
        for _pwb_v in $_pwb_versions; do
            _pwb_pts="$(exakit_whats_new_points "$_pwb_root" "$_pwb_v" 2>/dev/null || true)"
            # A version in range can still have nothing to say (an empty list).
            # It draws no card, so it must not make the run look announced.
            [ -n "$_pwb_pts" ] || continue
            _pwb_any=1
            _pwb_last="$_pwb_v"
            while IFS= read -r _pwb_l; do
                [ -n "$_pwb_l" ] || continue
                [ "${#_pwb_l}" -gt "$_pwb_w" ] && _pwb_w="${#_pwb_l}"
            done <<PWB_WIDTH
$_pwb_pts
PWB_WIDTH
        done
    fi
    if [ "${_pwb_any:-0}" = 1 ]; then
        # One lead-in above the cards. The titles say which versions arrived;
        # only this says where the reader started, and repeating it on every
        # card would be noise. Printed only once a card is certain: an empty
        # box is worse than no box, and so is a lead-in with nothing under it.
        if [ "$_pwb_from" = "__unversioned__" ]; then
            # The old kit recorded no version, so there is no number to name.
            printf '\n  %sYour kit is now %s.%s\n' \
                "${UI_BOLD:-}" "$_pwb_to" "${UI_RESET:-}"
        else
            printf '\n  %sYour kit moved from %s to %s.%s\n' \
                "${UI_BOLD:-}" "$_pwb_from" "$_pwb_to" "${UI_RESET:-}"
        fi

        for _pwb_v in $_pwb_versions; do
            _pwb_pts="$(exakit_whats_new_points "$_pwb_root" "$_pwb_v" 2>/dev/null || true)"
            [ -n "$_pwb_pts" ] || continue
            printf '\n'
            ui_panel_begin "What's new in $_pwb_v"
            # Fed by a here-document, not a pipe: ui_panel_line buffers into a
            # variable, and a pipeline would build that buffer in a subshell.
            while IFS= read -r _pwb_l; do
                [ -n "$_pwb_l" ] || continue
                ui_panel_line "$(printf '%-*s' "$_pwb_w" "$_pwb_l")"
            done <<PWB_BODY
$_pwb_pts
PWB_BODY
            ui_panel_end
        done
    fi
    # Announced, or found nothing worth announcing: either way this move is dealt
    # with, and the record goes so the next re-run does not repeat the cards.
    ( manifest_set kit.whats_new_from "" ) >/dev/null 2>&1 || true
    return 0
}

kit_shared_steps() {
    _step_no="$1"
    _total="$2"
    _script_dir="$3"
    _kit_root="$4"

    # NO DATABASE, NO STEPS THAT NEED ONE. When the database step records
    # itself as unfinished - today that means Podman was not installed - every
    # step after it would fail one at a time against a database that is not
    # there, each with its own error and its own entry in the closing summary.
    # One reason, said once, is the truth: the summary already carries it, and
    # `exakit update` runs the lot once Podman is in place. The exakit command
    # itself is still installed at the end, because it is what the reader needs
    # next.
    _kss_nodb=0
    if exakit_soft_failed runtime; then
        _kss_nodb=1
        info "Skipping exapump, the sample data, the AI bridge and pyexasol - they all need the database, which is not installed"
    fi

    if [ "$_kss_nodb" = 1 ]; then
        :
    elif command -v exapump_install >/dev/null 2>&1; then
        if begin_step exapump "Step ${_step_no}/${_total}  exapump (data loading CLI)"; then
            if exakit_soft_step exapump "exakit update" "exapump" \
                    _exakit_install_exapump; then
                mark_step exapump
            fi
        fi
    else
        info "Step ${_step_no}/${_total}  exapump — not part of this installation, skipping"
    fi
    _step_no=$((_step_no + 1))

    # Load the sample data before any MCP configuration. exapump is now up
    # (its only dependency), and doing this first means the read-only MCP
    # user is provisioned, granted, and posture-checked against a schema
    # that already holds the sample tables — and the AI client has data to
    # query the moment it connects.
    if [ "$_kss_nodb" = 1 ]; then
        :
    elif exakit_soft_failed exapump; then
        info "Skipping the sample data — it is loaded with exapump, which is not installed"
    else
        # `|| true` alone hid a failed load completely: the run carried on (right)
        # and the closing summary said nothing (wrong). Record it so the user
        # leaves knowing the database is empty and which command fills it.
        exakit_clear_failure_note
        # THE BRIDGE'S DOWNLOAD STARTS HERE, not two steps later. Priming the
        # MCP package is a network download and an unpack; the load below is a
        # local database reading local files. Neither needs the other, so the
        # download runs underneath the load and the AI bridge step collects a
        # finished one. See mcp_prefetch_begin.
        if command -v mcp_prefetch_begin >/dev/null 2>&1; then
            mcp_prefetch_begin || true
        fi
        if ! exakit_maybe_offer_data_load "$_kit_root"; then
            exakit_record_soft_failure sample_data "exakit data-load" \
                "$(exakit_take_failure_note)" "sample data"
            warn "Sample data did not finish loading — carrying on so the rest of the install completes"
        fi
        exakit_clear_failure_note
    fi

    if [ "$_kss_nodb" = 1 ]; then
        :
    elif command -v mcp_install >/dev/null 2>&1; then
        if begin_step mcp "Step ${_step_no}/${_total}  AI bridge (MCP server, clients and skills)"; then
            if exakit_soft_step mcp "exakit update" "the MCP server" _exakit_install_mcp; then
                mark_step mcp
            fi
        fi
    else
        info "Step ${_step_no}/${_total}  MCP server — not part of this installation, skipping"
    fi

    # The AI bridge is finished HERE, in the step that says it is being built:
    # the server, the clients that talk to it, the skills those clients load, and
    # the "restart your client" line that makes all three take effect. These two
    # offers used to run at the very end of the run instead — so a reader watched
    # step 4 announce the AI bridge, sat through pyexasol and the exakit helper,
    # and was then asked which AI clients to connect, under no step at all. The
    # step numbering said one thing and the screen did another.
    #
    # Nothing here needs a later step. The client configs point at `uvx
    # <mcp-server>`, never at the exakit command, and exakit_repo_root falls back
    # to the checkout for skills/ when the helper step has not staged its copy
    # yet. What they DO need is the database and exapump, which are two steps
    # back.
    #
    # Both offers are best-effort and neither may end the run — but "best-effort"
    # used to mean "vanishes without trace". Each books itself in the closing
    # summary with the command that retries it.
    exakit_clear_failure_note
    if ! ( exakit_maybe_offer_mcp_setup ); then
        exakit_record_soft_failure mcp_clients "exakit mcp-setup" \
            "$(exakit_take_failure_note)" "AI client (MCP) setup"
    fi
    exakit_clear_failure_note
    if ! ( exakit_maybe_offer_skills_install ); then
        exakit_record_soft_failure skills "exakit skills-install" \
            "$(exakit_take_failure_note)" "AI skills"
    fi
    exakit_clear_failure_note
    _step_no=$((_step_no + 1))

    if [ "$_kss_nodb" = 1 ]; then
        :
    elif command -v pyexasol_install >/dev/null 2>&1; then
        if begin_step pyexasol "Step ${_step_no}/${_total}  pyexasol (Exasol Python driver)"; then
            # pyexasol is the last, optional Component and it must not be able to
            # end the run: the exakit helper step below still has to happen, or
            # the user is left without the command that fixes everything else. A
            # soft failure explains itself, records validated=false, and leaves
            # the step unmarked so a re-run (or `exakit update pyexasol`) retries.
            if exakit_soft_step pyexasol "exakit update" "pyexasol" _exakit_install_pyexasol; then
                mark_step pyexasol
            fi
        fi
    else
        info "Step ${_step_no}/${_total}  pyexasol — not part of this installation, skipping"
    fi
    _step_no=$((_step_no + 1))

    # The step flag alone is not trusted: if the exakit command was removed
    # (cleanup, testing), a re-run must reinstall it rather than skip.
    _helper_needed=0
    if begin_step exakit_helper "Step ${_step_no}/${_total}  exakit helper command"; then
        _helper_needed=1
    elif [ ! -x "$EXAKIT_BIN_DIR/exakit" ]; then
        info "exakit command is missing — reinstalling it"
        _helper_needed=1
    elif ! cmp -s "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit" 2>/dev/null; then
        # The flag records "installed", not "current". Re-running the installer
        # over an older install (the 0.1.0 -> 0.2.0 upgrade path) arrives with
        # the flag already set and a command already on disk, while install.sh
        # has just replaced the kit copy underneath it. The installed command is
        # a COPY of setup/exakit, so without this it stays at the old version
        # and drives the new library: the update notice, the version panel and
        # the kit2 subcommands all live in the command itself and would go
        # missing until the next self-update.
        info "exakit command is out of date — refreshing it"
        _helper_needed=1
    else
        ensure_path_hint "$EXAKIT_BIN_DIR"
    fi
    if [ "$_helper_needed" -eq 1 ]; then
        mkdir -p "$EXAKIT_BIN_DIR" || die "Could not create $EXAKIT_BIN_DIR for the exakit command."
        # Fail loudly here: without a check, a failed install (e.g. non-writable
        # ~/.local/bin, full disk) would fall through to mark_step + "exakit
        # installed", reporting success while no binary exists.
        install -m 755 "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit" \
            || die "Could not install the exakit command to $EXAKIT_BIN_DIR (is it writable? is the disk full?)."
        # Keep a copy of the kit library (and the mcp/ and sql/ packages
        # exakit_repo_root() depends on) next to the state so exakit finds
        # them even when this checkout moves or disappears. Skip when setup is
        # ALREADY running from the kit home (the curl|sh flow, where install.sh
        # placed the kit there): copying a directory onto itself makes cp error
        # out with "are identical", which is not a real failure.
        if [ "$_script_dir" -ef "$EXAKIT_HOME/kit/setup" ] 2>/dev/null; then
            :   # already in place; nothing to copy
        else
            mkdir -p "$EXAKIT_HOME/kit/setup" || die "Could not create $EXAKIT_HOME/kit/setup."
            # CLEAR WHAT WE ARE ABOUT TO REPLACE. cp -R merges, it does not
            # mirror, so a module the new kit DELETED goes on living in the
            # staged copy - and the staged copy is what an installed exakit
            # sources. Installing this kit over the official one left its
            # runtime-nano.sh, nano.ps1 and catalog.tsv sitting in lib/, three
            # files this kit removed on purpose. Same hazard, smaller, on any
            # update that drops a file.
            #
            # Only the subtrees re-copied below, and only in the branch that
            # already established this is not the kit home itself.
            for _kss_stale in "$EXAKIT_HOME/kit/setup/lib" "$EXAKIT_HOME/kit/setup/help" \
                              "$EXAKIT_HOME/kit/mcp" "$EXAKIT_HOME/kit/sql" \
                              "$EXAKIT_HOME/kit/skills"; do
                rm -rf "$_kss_stale"
            done
            cp -R "$_script_dir/lib" "$EXAKIT_HOME/kit/setup/" \
                || die "Could not copy the kit library to $EXAKIT_HOME/kit/setup."
            # Copy the assets exakit needs after the checkout is gone: the mcp/
            # and sql/ packages, the data/ CSVs, load-data.sh, and the versions
            # manifest (the offline tier of version resolution, and the record of
            # which kit version this is).
            [ -f "$_kit_root/versions.json" ] && cp "$_kit_root/versions.json" "$EXAKIT_HOME/kit/"
            # whats-new.json lives under setup/, and only setup/lib is copied
            # above, so it needs naming or `exakit whats-new` finds nothing once
            # the checkout is gone.
            [ -f "$_kit_root/setup/whats-new.json" ] && cp "$_kit_root/setup/whats-new.json" "$EXAKIT_HOME/kit/setup/"
            [ -d "$_kit_root/mcp" ] && cp -R "$_kit_root/mcp" "$EXAKIT_HOME/kit/"
            [ -d "$_kit_root/sql" ] && cp -R "$_kit_root/sql" "$EXAKIT_HOME/kit/"
            [ -d "$_kit_root/data" ] && cp -R "$_kit_root/data" "$EXAKIT_HOME/kit/"
            # skills/ is not optional decoration: `exakit skills`, `exakit
            # skills-install` and the post-install skills step all resolve
            # through exakit_repo_root, which PREFERS this staged copy once
            # kit/mcp exists. Omitting it here does not fall back to the
            # checkout — it shadows it, so every one of those commands reports
            # "no skills/ directory in this kit build" on a working install.
            [ -d "$_kit_root/skills" ] && cp -R "$_kit_root/skills" "$EXAKIT_HOME/kit/"
            # setup/help/ is the WHOLE help corpus -- one JSON per topic, and
            # `exakit help <topic>` resolves through exakit_repo_root, which
            # PREFERS this staged copy once kit/mcp exists. Omitting it did not
            # fall back to the checkout, it shadowed it: on every installed kit
            # `exakit help mcp`, `exapump`, `personal`, `pyexasol`,
            # `exakit` and all three add-ons answered "No help entry for ...".
            #
            # It also took the marketplace descriptions with it, ALL THREE
            # TIERS of them, because every tier reads this same document:
            # _exakit_addon_repo takes the `repo` field, so with nothing staged
            # the GitHub About could not even be requested; the cache it fills
            # therefore stayed empty; and the `tagline` fallback -- the offline
            # answer AGENTS/CLAUDE describe -- was in the same missing file. So
            # every add-on in the table read "Details: exakit help <id>", the
            # last resort of the chain, pointing at the very command this
            # omission had disabled. Same shape as the skills note below.
            [ -d "$_kit_root/setup/help" ] && cp -R "$_kit_root/setup/help" "$EXAKIT_HOME/kit/setup/"
            [ -f "$_script_dir/load-data.sh" ] && cp "$_script_dir/load-data.sh" "$EXAKIT_HOME/kit/setup/"
        fi
        ensure_path_hint "$EXAKIT_BIN_DIR"
        mark_step exakit_helper
        ok_step "exakit installed ($(ui_tilde "$EXAKIT_BIN_DIR/exakit"))"
    fi

    # Autostart is NOT decided here. It used to be: an unconditional
    # exakit_autostart_enable, which unconditionally writes
    # autostart.enabled=true -- so a user who had run `exakit autostart off` got
    # it switched back on, and the LaunchAgent re-registered, by the mere act of
    # re-running the installer. Silently, because this sits inside a quiet
    # bracket.
    #
    # exakit_autostart_default_on is the function that exists to get this right,
    # and its own comment says the recorded answer "must survive every later run
    # of the installer" -- but it runs AFTER this did, saw the true this wrote,
    # and returned. It was dead code on this path. The setup scripts call it near
    # the end of the run, where a fresh install still defaults to on and a
    # recorded choice is left alone. PowerShell already worked this way.

    # The upgrade news (exakit_print_whats_new_box) and the closing summary
    # (exakit_print_soft_failures) are printed by the setup scripts after the
    # connection panel at the very end of the run — not here, in the middle of
    # the step output where the connection details would push them off screen.
}

# connection_summary — the CLOSING panel of an install: the four things somebody
# who just watched a setup finish actually reaches for, and the command that has
# the rest.
#
# connection_panel below is the same information in full — eighteen rows — and it
# stays that way, because it is also what `exakit info` prints, and a reference
# screen is exactly where every path belongs. What an install should end with is
# not a reference screen.
connection_summary() {
    [ -f "$EXAKIT_MANIFEST" ] || { warn "No installation found ($EXAKIT_MANIFEST missing)"; return 1; }
    # NO DATABASE, NO CONNECTION PANEL. A DSN printed after the database step
    # failed reads as "connect here" to an address nothing is listening on; the
    # soft-failure summary that follows says what is missing and how to finish.
    # Twin of the same gate in Show-ExakitConnectionSummary.
    exakit_soft_failed runtime && return 0
    _cs_dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _cs_user="$(manifest_get runtime.user 2>/dev/null)"
    printf '\n'
    ui_panel_begin "Your local Exasol"
    ui_panel_line "$(printf '%-13s %s' "DSN" "${_cs_dsn:-unknown}   (admin ${_cs_user:-sys}, TLS self-signed)")"
    ui_panel_line "$(printf '%-13s %s' "Passwords" "$(ui_tilde "$EXAKIT_CREDS_DIR")/")"
    if exakit_marketplace_addon_installed exasol-vscode 2>/dev/null; then
        ui_panel_line "$(printf '%-13s %s' "SQL client" "VS Code (Exasol extension), $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")")"
    else
        ui_panel_line "$(printf '%-13s %s' "SQL client" "$(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")")"
    fi
    ui_panel_line "$(printf '%-13s %s' "Everything" "exakit info  ·  exakit guide")"
    ui_panel_end
}

# connection_panel — the payoff screen: everything needed to connect.
# Reads the manifest; sections appear as components get installed.
connection_panel() {
    [ -f "$EXAKIT_MANIFEST" ] || { warn "No installation found ($EXAKIT_MANIFEST missing)"; return 1; }

    # Six manifest_get calls, and every one starts a Python process to read a
    # single key out of the same file: measured at 53ms each, ~890ms for this
    # whole panel. That is why `exakit info` sits there for a moment before
    # anything appears, and it is what this narrates.
    #
    # ui_spin_begin draws nothing unless stdout is a terminal, so the
    # installer's use of this panel and any captured run are unchanged. The
    # spinner is stopped before the panel prints, never across it.
    ui_spin_begin "Reading your connection details"
    # ONE python process for all six keys, not six.
    #
    # This used to be six manifest_get calls, each starting its own interpreter
    # to read one key out of the same file: ~53ms each, ~890ms for the panel.
    # The spinner above explains that wait; batching removes it.
    #
    # THE ORDER OF THESE SIX NAMES IS THE CONTRACT with the loop below. Every
    # variable is initialised first, so a missing manifest leaves them empty
    # and the panel prints "unknown" exactly as it did before.
    _type=""; _dsn=""; _user=""; _pwfile=""; _mcp_user=""; _mcp_pwfile=""
    _cp_values="$(manifest_get_many \
        runtime.type \
        runtime.dsn \
        runtime.user \
        runtime.password_file \
        components.mcp_server.connection.user \
        components.mcp_server.connection.password_file 2>/dev/null)"
    _cp_i=0
    while IFS= read -r _cp_line; do
        _cp_i=$((_cp_i + 1))
        case "$_cp_i" in
            1) _type="$_cp_line" ;;
            2) _dsn="$_cp_line" ;;
            3) _user="$_cp_line" ;;
            4) _pwfile="$_cp_line" ;;
            5) _mcp_user="$_cp_line" ;;
            6) _mcp_pwfile="$_cp_line" ;;
        esac
    done <<_EXAKIT_CONN_EOF
$_cp_values
_EXAKIT_CONN_EOF
    ui_spin_end

    printf '\n'
    ui_panel_begin "Setup details"
    ui_panel_line "Runtime:      ${_type:-unknown}"
    ui_panel_line "DSN:          ${_dsn:-unknown}"
    ui_panel_line "Admin user:   ${_user:-sys}"
    # No "stored in": the path IS the answer, and those two words were what
    # pushed this panel to 85 columns -- five past the 80-column default of
    # Terminal.app, where the box then breaks. ui_panel_end sizes to its longest
    # line and never consults the terminal, unlike the table and the progress
    # line, so the two longest rows here decide whether the panel fits at all.
    [ -n "$_pwfile" ]    && ui_panel_line "Admin pass:   $(ui_tilde "$_pwfile")"
    [ -n "$_mcp_user" ]  && ui_panel_line "MCP user:     $_mcp_user"
    [ -n "$_mcp_pwfile" ] && ui_panel_line "MCP pass:     $(ui_tilde "$_mcp_pwfile")"
    ui_panel_line "TLS:          enabled (self-signed certificate)"

    _exapump="$(manifest_get components.exapump.path 2>/dev/null)"
    if [ -n "$_exapump" ]; then
        ui_panel_line "exapump:      $(ui_tilde "$_exapump") (profile: $(manifest_get components.exapump.profile 2>/dev/null))"
        # THE ONE FACT THAT EXPLAINS EVERY CONFUSING exapump ERROR on these
        # distros, and it was recorded in the manifest and shown nowhere. On
        # glibc < 2.38 the release binary cannot run, so the kit generates a
        # container wrapper - which means exapump sees a subset of the
        # filesystem. A path outside what is mounted is simply not there, and
        # until now nothing told the user that a container was involved at all.
        if [ "$(manifest_get components.exapump.glibc_shim 2>/dev/null)" = "true" ]; then
            ui_panel_line "              runs in a container shim; sees files under ~, /tmp and your current directory"
        fi
    fi

    # Stdio MCP configs live inside each AI client's own config file, not in
    # the kit's mcp/ dir (that holds only pre-edit backups) — point users at
    # the command that lists the real locations.
    _mcp="$(manifest_get components.mcp_server.configs 2>/dev/null)"
    if [ -n "$_mcp" ]; then
        ui_panel_line "MCP configs:  in each AI client's config (list: exakit mcp-status)"
        ui_panel_line "MCP backups:  $(ui_tilde "$EXAKIT_MCP_DIR")"
    fi
    # The skill set, from the manifest and the CACHED versions document: info
    # stays offline and cheap, and still says when `exakit update` has a newer
    # set to fetch. The row is the same verdict `exakit skills` prints.
    _cp_skills_have="$(manifest_get components.skills.version 2>/dev/null || true)"
    _cp_skills_want="$(exakit_versions_value components.skills.version 2>/dev/null || true)"
    if [ -n "$_cp_skills_have" ]; then
        if [ -n "$_cp_skills_want" ] && [ "$_cp_skills_want" != "$_cp_skills_have" ]; then
            ui_panel_line "Skills:       $_cp_skills_have ($_cp_skills_want available: exakit update)"
        else
            ui_panel_line "Skills:       $_cp_skills_have (list: exakit skills)"
        fi
    fi

    # The JSON form rides on the Manifest row rather than trailing the panel as
    # a sentence of its own: it is the same fact -- where this screen's contents
    # live -- and a reader who wants the file usually wants the parseable one.
    ui_panel_line "Manifest:     $(ui_tilde "$EXAKIT_MANIFEST")   ·  exakit info --json"
    ui_panel_line "Logs:         $(ui_tilde "$EXAKIT_LOG_DIR")"
    # The two download links are always true: anyone can fetch them. The VS Code
    # extension is a marketplace add-on, so it is named only when it is actually
    # on this machine — otherwise the row would advertise a SQL client the reader
    # may not have, and on a machine without VS Code cannot get.
    #
    # It has to be named SOMEWHERE, though: the "Add-ons:" row below prints only
    # while something is still pending, so on a fully equipped machine an
    # installed extension went unmentioned by the whole panel.
    if exakit_marketplace_addon_installed exasol-vscode 2>/dev/null; then
        ui_panel_line "SQL client:   VS Code (Exasol extension), $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")"
    else
        ui_panel_line "SQL client:   $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")"
    fi
    ui_panel_line "Guide:        exakit guide"
    # One line, only while something is still on offer: the marketplace is the
    # optional layer on top of a finished install, so this is where it is
    # discovered — never during the install itself.
    if exakit_marketplace_has_pending 2>/dev/null; then
        ui_panel_line "Add-ons:      exakit marketplace (dashboards, editor tools and more)"
    fi
    ui_panel_end
    printf '\n'
}

# exakit_print_no_ai_panel — shown when the user skips MCP client setup: the
# database is still fully usable without an AI assistant, and this says how.
exakit_print_no_ai_panel() {
    _nap_dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _nap_host="${_nap_dsn%%:*}"; _nap_port="${_nap_dsn##*:}"
    printf '\n'
    ui_panel_begin "Using your database without an AI client"
    ui_panel_line "Your database works great on its own — three easy ways in:"
    ui_panel_line ""
    ui_panel_line "GUI client:  $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")"
    ui_panel_line "             New Connection > Exasol > Host ${_nap_host:-127.0.0.1} Port ${_nap_port:-8563}"
    ui_panel_line "Python:      pyexasol is preinstalled in its own environment:"
    ui_panel_line "             $(ui_tilde "$EXAKIT_HOME/pyexasol-venv/bin/python")"
    ui_panel_line "Terminal:    exapump interactive -p starter-kit   (SQL shell)"
    ui_panel_line ""
    ui_panel_line "Step-by-step (credentials, TLS setting, first query):"
    ui_panel_line "  exakit guide"
    ui_panel_line "Changed your mind about AI? Any time:"
    ui_panel_line "  exakit mcp-setup"
    ui_panel_end
    printf '\n'
}

# exakit_guide — friendly how-to-connect walkthrough: AI clients over MCP,
# GUI SQL clients (DBeaver, DbVisualizer), and terminal/Python access. Everything below is
# rendered from the live manifest so the values are the user's own.
exakit_guide() {
    [ -f "$EXAKIT_MANIFEST" ] || { warn "No installation found. Run the installer first."; return 1; }
    _g_dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _g_host="${_g_dsn%%:*}"; _g_port="${_g_dsn##*:}"
    _g_host="${_g_host:-127.0.0.1}"; _g_port="${_g_port:-8563}"
    _g_user="$(manifest_get runtime.user 2>/dev/null)"; _g_user="${_g_user:-sys}"
    _g_pwfile="$(manifest_get runtime.password_file 2>/dev/null)"
    _g_mcp_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"

    ui_banner "How to connect" "AI clients, SQL clients, Python — pick your door"

    ui_panel_begin "1 · Ask questions with an AI client (MCP)"
    ui_panel_line "Connect one or more AI clients in a single guided step:"
    ui_panel_line "  exakit mcp-setup"
    ui_panel_line "Supported: Claude, Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue"
    ui_panel_line "Then restart/reload the client and look for the MCP server 'exasol'."
    ui_panel_line ""
    ui_panel_line "First thing to ask it:"
    ui_panel_line "  \"List the schemas and tables in my Exasol database, then answer my"
    ui_panel_line "   questions with read-only SQL — show me the SQL before you run it.\""
    ui_panel_line "14 ready-made questions: data/example-questions.md (in the kit)"
    ui_panel_end

    ui_panel_begin "2 · Browse and query with a SQL client (GUI)"
    ui_panel_line "Both free: $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")"
    ui_panel_line ""
    ui_panel_line "In DBeaver: Database > New Database Connection > search 'Exasol'"
    ui_panel_line "  Host:      $_g_host"
    ui_panel_line "  Port:      $_g_port"
    ui_panel_line "  User:      $_g_user"
    [ -n "$_g_pwfile" ] && \
    ui_panel_line "  Password:  cat $(ui_tilde "$_g_pwfile")"
    [ -n "$_g_mcp_user" ] && \
    ui_panel_line "  (read-only alternative: user $_g_mcp_user)"
    ui_panel_line "  TLS:       local self-signed certificate — in Driver properties set"
    ui_panel_line "             validateservercertificate = 0 (or add ;validateservercertificate=0"
    ui_panel_line "             to the JDBC URL), then Test Connection > Finish."
    ui_panel_line "Each bundled dataset has its own schema (TPCH, ENERGY, WEATHER);"
    ui_panel_line "your own uploads default to STARTER_KIT."
    ui_panel_end

    ui_panel_begin "3 · Terminal and Python"
    ui_panel_line "Interactive SQL shell:   exapump interactive -p starter-kit"
    ui_panel_line "One-off query:           exapump sql -p starter-kit \"SELECT 42\""
    ui_panel_line ""
    ui_panel_line "Python (pyexasol preinstalled in its own environment):"
    ui_panel_line "  $(ui_tilde "$EXAKIT_HOME/pyexasol-venv/bin/python")"
    ui_panel_line "  import pyexasol"
    ui_panel_line "  c = pyexasol.connect(dsn='$_g_host:$_g_port', user='$_g_user',"
    ui_panel_line "                       password=open('<password file above>').read(),"
    ui_panel_line "                       websocket_sslopt={'cert_reqs': 0})"
    ui_panel_line "  c.export_to_pandas('SELECT * FROM TPCH.CUSTOMER LIMIT 5')"
    ui_panel_end

    ui_panel_begin "Everything else"
    ui_panel_line "Connection summary:   exakit info"
    ui_panel_line "Load more data:       exakit data-load"
    ui_panel_line "Optional add-ons:     exakit marketplace (dashboards & more)"
    ui_panel_line "Health check:         exakit status · exakit mcp-doctor"
    ui_panel_end
    printf '\n'
}

# generate_password — local random password (not logged anywhere).
generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# store_credential <name> <value> — 0600 file under credentials dir.
# Written atomically so an interrupted run can never leave a truncated secret.
store_credential() {
    mkdir -p "$EXAKIT_CREDS_DIR" || die "Could not create the credentials directory $EXAKIT_CREDS_DIR."
    # chmod fails when the dir is owned by someone else (root-owned debris
    # from an interrupted install) — the writability diagnosis below reports
    # that case precisely, so don't let the raw chmod noise muddy the output.
    chmod 700 "$EXAKIT_CREDS_DIR" 2>/dev/null || true
    # Fail loudly on a write error: a silently dropped secret makes a later
    # step read an empty credential and either regenerate a mismatching
    # password or die with a confusing message far from the real cause.
    # Diagnose the actual cause instead of guessing — an end user cannot
    # act on "disk full or not writable?".
    if ! printf '%s' "$2" > "$EXAKIT_CREDS_DIR/$1.tmp" 2>/dev/null; then
        rm -f "$EXAKIT_CREDS_DIR/$1.tmp" 2>/dev/null
        if [ -d "$EXAKIT_CREDS_DIR/$1" ]; then
            die "Could not save credential '$1': $EXAKIT_CREDS_DIR/$1 exists as a directory (leftover from an interrupted install). Remove it with: sudo rm -rf $EXAKIT_CREDS_DIR — then re-run."
        elif [ ! -w "$EXAKIT_CREDS_DIR" ]; then
            _sc_owner="$(ls -ld "$EXAKIT_CREDS_DIR" 2>/dev/null | awk '{print $3}')"
            die "Could not save credential '$1': $EXAKIT_CREDS_DIR is not writable by $(id -un) (owned by ${_sc_owner:-unknown} — leftover from an interrupted install). Remove it with: sudo rm -rf $EXAKIT_CREDS_DIR — then re-run."
        fi
        die "Could not save credential '$1' to $EXAKIT_CREDS_DIR (disk full or read-only filesystem?)."
    fi
    chmod 600 "$EXAKIT_CREDS_DIR/$1.tmp"
    mv "$EXAKIT_CREDS_DIR/$1.tmp" "$EXAKIT_CREDS_DIR/$1" || die "Could not save credential '$1'."
    _exakit_warn_unprotected_credentials "$EXAKIT_CREDS_DIR/$1"
}

# _exakit_warn_unprotected_credentials <file> — say so when the chmod above did
# not actually take.
#
# A chmod on a filesystem with no Unix permission bits SUCCEEDS and stores
# nothing. That is the default state of a Windows drive mounted into WSL
# (DrvFs without the `metadata` option): the kit's one protection on a
# plaintext database password is accepted and discarded, every file stays mode
# 0777, and the install prints its usual ticks. read_credential's own
# permission warning only fires when a file is UNreadable, never when it is too
# readable — so nothing in the kit noticed. Warned ONCE per run: the same home
# holds every credential and the sentence does not improve by repetition.
_exakit_warn_unprotected_credentials() {
    [ "${EXAKIT_CREDS_MODE_WARNED:-0}" = "1" ] && return 0
    _wuc_file="$1"
    [ -f "$_wuc_file" ] || return 0
    # The portable test: find is the only mode query that behaves the same on
    # BSD and GNU. A filesystem that reports the mode we asked for is fine.
    [ "$(find "$_wuc_file" -perm 0600 -print 2>/dev/null)" = "$_wuc_file" ] && return 0
    EXAKIT_CREDS_MODE_WARNED=1
    warn "The database passwords in $EXAKIT_CREDS_DIR cannot be protected on this filesystem: 'chmod 600' was accepted and had no effect."
    if detect_wsl_drvfs_path "$EXAKIT_CREDS_DIR" 2>/dev/null; then
        warn "That is a Windows drive mounted into WSL — every Windows user and process on this machine can read them, and OneDrive will sync them if the profile is backed up."
        info "Fix it by moving the kit to the Linux filesystem: re-run the installer with EXAKIT_HOME=\$HOME/exakit (any path you own on the Linux side), and keep that variable exported for later exakit commands."
    else
        info "Move the kit to a filesystem that supports Unix permissions: re-run the installer with EXAKIT_HOME set to a path there."
    fi
    return 0
}

read_credential() {
    _rc_file="$EXAKIT_CREDS_DIR/$1"
    # A file that exists but can't be read would otherwise look "missing" and
    # trigger a regenerated, diverging password — surface it instead.
    if [ -f "$_rc_file" ] && [ ! -r "$_rc_file" ]; then
        warn "Credential file exists but is not readable: $_rc_file (check permissions)."
    fi
    cat "$_rc_file" 2>/dev/null
}

# exakit_install_command - the install one-liner for THIS platform, so the
# farewell line of an uninstall is something the reader can actually paste.
# This side serves macOS, Linux and WSL, which all curl into sh; Windows has
# its own twin (Get-ExakitInstallCommand) that hands back the irm form.
exakit_install_command() {
    printf 'curl -fsSL %s | sh\n' "$EXAKIT_INSTALL_URL"
}

# --- full uninstall --------------------------------------------------------
#
# exakit_uninstall_run <dry_run> — remove every artifact this kit installs, in
# dependency order: the local database and ALL its data, the managed MCP client
# configs, the installed AI skills, the exapump profile, the kit home, and the
# CLI binaries. With <dry_run>="1" it prints the plan and changes nothing, so
# the caller can show exactly what will go before asking for confirmation.
#
# Deliberately NOT removed (reported instead): uv/uvx (a shared third-party
# Python runner the user may rely on elsewhere) and the PATH line added to the
# shell profile (unmarked and shared with other tools — unsafe to edit blindly).
# _exakit_remove_installed_skills <dry> — the kit's AI skills, wherever they
# were installed. Prefer the live list from the kit's skills/ dir; fall back
# to the known names when the checkout is already gone.
_exakit_remove_installed_skills() {
    _rs_dry="${1:-0}"
    _skill_names=""
    _repo_root="$(exakit_repo_root 2>/dev/null || true)"
    if [ -n "$_repo_root" ] && [ -d "$_repo_root/skills" ]; then
        for _sd in "$_repo_root"/skills/*/; do
            [ -f "$_sd/SKILL.md" ] || continue
            _skill_names="$_skill_names $(basename "$_sd")"
        done
    fi
    # The kit copy is gone (uninstall order, or a hand-deleted checkout), so
    # fall back to what the install actually recorded. A hardcoded name list
    # was the old fallback and it aged badly: it named a skill that never
    # shipped and knew nothing of the ones added since. Enumerating the
    # discovery folders instead is not an option — they also hold skills the
    # user installed themselves, and the kit removes only what it placed.
    if [ -z "$_skill_names" ]; then
        _skill_names="$(manifest_get components.skills.installed 2>/dev/null |
            tr -d '[]"' | tr ',' ' ')"
    fi
    # One line per FOLDER, not per skill. Nine skills across two discovery
    # folders printed eighteen near-identical lines in the middle of an
    # uninstall - long enough to push everything else off a screen, and saying
    # nothing the count and the folder do not. The individual paths are still
    # worth having in the log, where a reader goes when they want them.
    for _root in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
        _rs_found=0
        for _name in $_skill_names; do
            [ -e "$_root/$_name" ] || continue
            _rs_found=$((_rs_found + 1))
            _exakit_log_file "INFO  AI skill $_root/$_name"
            [ "$_rs_dry" = "1" ] || rm -rf "$_root/$_name"
        done
        [ "$_rs_found" -gt 0 ] || continue
        if [ "$_rs_found" = 1 ]; then _rs_word="skill"; else _rs_word="skills"; fi
        if [ "$_rs_dry" = "1" ]; then
            info "  will remove: $_rs_found AI $_rs_word from $(ui_tilde "$_root")"
        else
            info "$_rs_found AI $_rs_word from $(ui_tilde "$_root")"
        fi
    done
    # The permission rules skills-install merged into ~/.claude/settings.json go
    # with the skills. Only the kit's own entries; the user's stay.
    if [ "$_rs_dry" = "1" ]; then
        info "  will remove: the exakit permission rules from ~/.claude/settings.json"
    else
        case "$(exakit_remove_readonly_allowlist 2>/dev/null)" in
            REMOVED\ 0|"") ;;
            REMOVED\ *) info "exakit permission rules removed from ~/.claude/settings.json" ;;
        esac
    fi
    return 0
}



# _exakit_uninstall_component <key> <dry> — one selectable piece of the kit,
# removed on its own. Each removal also clears its manifest record and step
# flag, so `exakit status`, `exakit version` and an installer re-run all read the
# machine honestly afterwards. Best-effort throughout: one piece failing must
# not strand the others.
_exakit_uninstall_component() {
    _uc_key="$1"
    _uc_dry="${2:-0}"
    case "$_uc_key" in
        database)
            _uc_type="$(manifest_get runtime.type 2>/dev/null || true)"
            if [ "$_uc_dry" = "1" ]; then
                info "  will remove: the local Exasol $_uc_type deployment and ALL its data"
                return 0
            fi
            info "Removing the local Exasol $_uc_type deployment and all data"
            case "$_uc_type" in
                personal) personal_teardown --data || warn "Database removal reported errors" ;;
                *)        warn "Unknown runtime type '$_uc_type'; skipping database removal" ;;
            esac
            exakit_unmark_step runtime
            ;;
        mcp_configs)
            if [ "$_uc_dry" = "1" ]; then
                info "  will remove: the managed MCP configuration from the AI clients"
                return 0
            fi
            info "Removing the managed MCP configuration from the AI clients"
            if command -v exakit_mcp_operation >/dev/null 2>&1; then
                exakit_mcp_operation uninstall >/dev/null 2>&1 || \
                    warn "Removing the managed AI client config reported issues"
            fi
            ;;
        skills)
            _exakit_remove_installed_skills "$_uc_dry"
            ;;
        exapump)
            if [ "$_uc_dry" = "1" ]; then
                info "  will remove: exapump ($EXAKIT_BIN_DIR/exapump and the profiles at ~/.exapump)"
                return 0
            fi
            info "Removing exapump and its profiles"
            rm -f "$EXAKIT_BIN_DIR/exapump"
            # Through the shared variable, never a bare "$HOME/.exapump": a
            # caller that sandboxes EXAKIT_HOME but not HOME would otherwise
            # delete the real profile directory (a test suite did exactly that).
            rm -rf "${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}" "$EXAKIT_HOME/libexec"
            manifest_del components.exapump
            exakit_unmark_step exapump
            ;;
        pyexasol)
            if [ "$_uc_dry" = "1" ]; then
                info "  will remove: pyexasol (the managed venv at $EXAKIT_HOME/pyexasol-venv)"
                return 0
            fi
            info "Removing the pyexasol venv"
            rm -rf "${EXAKIT_PYEXASOL_VENV:-$EXAKIT_HOME/pyexasol-venv}"
            manifest_del components.pyexasol
            exakit_unmark_step pyexasol
            ;;
        everything)
            exakit_uninstall_run "$_uc_dry"
            ;;
        *)
            # A marketplace add-on: its module owns the removal.
            if _exakit_addon_registered "$_uc_key"; then
                _uc_fn="$(_exakit_addon_fn "$_uc_key" uninstall)"
                if command -v "$_uc_fn" >/dev/null 2>&1; then
                    "$_uc_fn" "$_uc_dry" || warn "Removing the $_uc_key add-on reported issues"
                    # ...and the skills it owns go with it. Here rather than in
                    # the module, so every add-on gets it without writing a line.
                    [ "$_uc_dry" = "1" ] || exakit_remove_addon_skills "$_uc_key" || true
                    # ...and so does its BOOT ENTRY. Left behind, launchd or
                    # systemd kept firing a launcher that no longer exists on
                    # every login, forever — the one artifact of the add-on
                    # nothing would ever clean up again.
                    [ "$_uc_dry" = "1" ] || _exakit_autostart_unregister "$_uc_key" || true
                else
                    warn "The $_uc_key module carries no uninstall — update the kit: exakit update"
                fi
            else
                warn "Unknown uninstall target: $_uc_key"
            fi
            ;;
    esac
    return 0
}

# exakit_uninstall_menu — the interactive `exakit uninstall`: pick exactly
# what goes, see exactly what that means, then type the word. The selection
# is the same tree-checkbox every other kit choice uses; Skip is the
# exclusive, pre-selected default, so Enter alone removes nothing. Only what
# is actually on this machine is offered, and EVERYTHING is the one row that
# means the full teardown (kit home and the exakit command included).
# ⇄ twin: Show-ExakitUninstallMenu in setup/exakit.ps1.
# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
# One command reaches every log the kit can show: the install run, the database
# container's own output, each service add-on's log, and whatever the boot
# entries wrote at login. Add-ons opt in with <id>_log_path, so a new one is
# viewable with no wiring here.

# exakit_log_targets — one line per viewable log: "id|label|kind|source".
# kind=file → source is a path; kind=cmd → source is a command to run (the
# container keeps its log itself, there is no file to tail).
exakit_log_targets() {
    _lt_setup="$(ls -t "$EXAKIT_LOG_DIR"/install-*.log 2>/dev/null | head -1)"
    [ -n "$_lt_setup" ] && printf 'setup|Installer and setup runs|file|%s\n' "$_lt_setup"

    for _lt_id in $(exakit_marketplace_installed_addons 2>/dev/null); do
        _lt_fn="$(_exakit_addon_fn "$_lt_id" log_path)"
        command -v "$_lt_fn" >/dev/null 2>&1 || continue
        _lt_path="$("$_lt_fn" 2>/dev/null || true)"
        [ -n "$_lt_path" ] && printf '%s|%s service|file|%s\n' "$_lt_id" "$_lt_id" "$_lt_path"
    done

    # What the boot entries wrote at login — the only record of a start that
    # happened while nobody was watching.
    for _lt_auto in "$EXAKIT_LOG_DIR"/autostart-*.log; do
        [ -f "$_lt_auto" ] || continue
        _lt_name="$(basename "$_lt_auto" .log)"
        printf '%s|%s at login|file|%s\n' "$_lt_name" "${_lt_name#autostart-}" "$_lt_auto"
    done
    return 0
}

# _exakit_log_size <file> / _exakit_log_mtime <file> — small, portable columns.
# `date -r <file>` is understood by both BSD (macOS) and GNU date.
_exakit_log_size() {
    [ -f "$1" ] || { printf '%s' "-"; return 0; }
    _ls_bytes="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
    case "$_ls_bytes" in
        ''|*[!0-9]*) printf '%s' "-" ;;
        *) if [ "$_ls_bytes" -ge 1048576 ]; then printf '%sM' "$((_ls_bytes / 1048576))"
           elif [ "$_ls_bytes" -ge 1024 ]; then printf '%sK' "$((_ls_bytes / 1024))"
           else printf '%sB' "$_ls_bytes"; fi ;;
    esac
}

_exakit_log_mtime() {
    [ -f "$1" ] || { printf '%s' "-"; return 0; }
    date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "-"
}

# exakit_logs_overview — what can be viewed, in the kit's table shape.
# exakit_logs_overview_json — the same listing, machine-readable, so an agent can
# pick a target and its path without parsing a column-aligned table. Always an
# object, including when there are no logs at all, so a parser never gets empty
# stdout (the same rule the other --json surfaces follow).
exakit_logs_overview_json() {
    exakit_can_run_python || return 1
    _loj_rows=""
    while IFS='|' read -r _loj_id _loj_label _loj_kind _loj_src; do
        [ -n "$_loj_id" ] || continue
        if [ "$_loj_kind" = "cmd" ]; then
            _loj_rows="${_loj_rows}${_loj_id}|${_loj_label}|${_loj_kind}|${_loj_src}|live|kept by the engine
"
        else
            _loj_rows="${_loj_rows}${_loj_id}|${_loj_label}|${_loj_kind}|${_loj_src}|$(_exakit_log_size "$_loj_src")|$(_exakit_log_mtime "$_loj_src")
"
        fi
    done <<EXAKIT_LOJ_EOF
$(exakit_log_targets)
EXAKIT_LOJ_EOF
    # Rows go through argv, not stdin: run_python reads the PROGRAM from stdin
    # (the here-doc), so a piped payload arrives as an empty read and the
    # listing silently comes back with zero targets.
    run_python - "$_loj_rows" <<'EXAKIT_LOJ_PY'
import json, sys
targets = []
for line in sys.argv[1].splitlines():
    if not line.strip():
        continue
    fields = line.split("|")
    if len(fields) < 6:
        continue
    identifier, label, kind, source, size, updated = fields[:6]
    targets.append({
        "target": identifier,
        "what": label,
        "kind": kind,
        # A command-backed target has no file; null is the honest answer, and it
        # is what tells a caller to use `exakit logs <target>` instead of opening
        # a path itself.
        "path": source if kind != "cmd" else None,
        "command": source if kind == "cmd" else None,
        "size": size,
        "updated": updated,
    })
print(json.dumps({"count": len(targets), "targets": targets}, indent=2))
EXAKIT_LOJ_PY
}

exakit_logs_overview() {
    _lo_rows="$(exakit_log_targets)"
    if [ -z "$_lo_rows" ]; then
        info "No logs yet. They appear here after an install or once a service has run."
        return 0
    fi
    printf '\n  Component logs\n'
    printf '  --------------\n'
    printf '%-22s %-26s %-8s %s\n' "Target" "What" "Size" "Updated"
    while IFS='|' read -r _lo_id _lo_label _lo_kind _lo_src; do
        [ -n "$_lo_id" ] || continue
        if [ "$_lo_kind" = "cmd" ]; then
            printf '%-22s %-26s %-8s %s\n' "$_lo_id" "$_lo_label" "live" "kept by the engine"
        else
            printf '%-22s %-26s %-8s %s\n' "$_lo_id" "$_lo_label" \
                "$(_exakit_log_size "$_lo_src")" "$(_exakit_log_mtime "$_lo_src")"
        fi
    done <<EXAKIT_LO_EOF
$_lo_rows
EXAKIT_LO_EOF
    printf '\n'
    info "View one:  exakit logs <target>        (add -f to follow it live)"
    info "Its path:  exakit logs <target> --path"
    return 0
}

# exakit_logs_show <target> [follow] [lines] [path_only]
exakit_logs_show() {
    _lsh_target="$1"
    _lsh_follow="${2:-0}"
    _lsh_lines="${3:-200}"
    _lsh_path_only="${4:-0}"
    _lsh_found=""
    while IFS='|' read -r _lsh_id _lsh_label _lsh_kind _lsh_src; do
        [ "$_lsh_id" = "$_lsh_target" ] || continue
        _lsh_found="$_lsh_kind|$_lsh_src"
        break
    done <<EXAKIT_LSH_EOF
$(exakit_log_targets)
EXAKIT_LSH_EOF
    if [ -z "$_lsh_found" ]; then
        # A registered add-on that is simply NOT INSTALLED is not an unknown
        # name, and saying "No log called 'dash-server'" next to a list that
        # does not contain it leaves the reader to work out why theirs is
        # missing. Name the actual state instead: not installed here, or not
        # installable on this machine at all.
        if command -v _exakit_addon_registered >/dev/null 2>&1 && \
           _exakit_addon_registered "$_lsh_target"; then
            if command -v _exakit_addon_applicable >/dev/null 2>&1 && \
               ! _exakit_addon_applicable "$_lsh_target"; then
                _lsh_why="$(_exakit_addon_applicable_reason "$_lsh_target" 2>/dev/null || true)"
                die "$_lsh_target is not available on this machine${_lsh_why:+: $_lsh_why}"
            fi
            die "$_lsh_target is not installed, so it has written no log yet. Install it with: exakit marketplace"
        fi
        _lsh_known="$(exakit_log_targets | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
        die "No log called '$_lsh_target'.${_lsh_known:+ Available: $_lsh_known}"
    fi
    _lsh_kind="${_lsh_found%%|*}"
    _lsh_src="${_lsh_found#*|}"

    if [ "$_lsh_kind" = "cmd" ]; then
        if [ "$_lsh_path_only" = "1" ]; then
            printf '%s\n' "$_lsh_src"
            return 0
        fi
        # The container engine owns this log; ask it, with the same shape of
        # options the file path uses.
        if [ "$_lsh_follow" = "1" ]; then
            $_lsh_src --tail "$_lsh_lines" -f
        else
            $_lsh_src --tail "$_lsh_lines"
        fi
        return $?
    fi

    if [ "$_lsh_path_only" = "1" ]; then
        printf '%s\n' "$_lsh_src"
        return 0
    fi
    [ -f "$_lsh_src" ] || die "The $_lsh_target log has not been written yet ($_lsh_src)."
    if [ "$_lsh_follow" = "1" ]; then
        info "Following $_lsh_src — Ctrl-C to stop"
        tail -n "$_lsh_lines" -f "$_lsh_src"
    else
        tail -n "$_lsh_lines" "$_lsh_src"
    fi
}

# ---------------------------------------------------------------------------
# Services and autostart
# ---------------------------------------------------------------------------
# Everything the kit runs as a process — the database and any add-on that
# serves (dash-server today) — answers the same three questions: are you
# running, start, stop. Add-ons opt in by defining <id>_status, <id>_start,
# <id>_stop and <id>_autostart_command; the registry does the rest, so
# `exakit start|stop|status` and the boot entries pick a new add-on up with no
# wiring here.
#
# Autostart uses the platform's own supervisor rather than anything invented:
#   macOS  — a LaunchAgent per service in ~/Library/LaunchAgents (RunAtLoad).
#   Linux  — a systemd --user unit when the session has one.
# A registration is a file the user can read, and `exakit autostart off`
# removes every one of them.

EXAKIT_LAUNCHAGENT_DIR="${EXAKIT_LAUNCHAGENT_DIR:-$HOME/Library/LaunchAgents}"
EXAKIT_SYSTEMD_USER_DIR="${EXAKIT_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
EXAKIT_AUTOSTART_PREFIX="com.exasol.exakit"

# exakit_service_ids — every service on this machine, database first. Add-ons
# appear only when installed AND carrying the service hooks.
exakit_service_ids() {
    [ -n "$(manifest_get runtime.type 2>/dev/null || true)" ] && printf '%s\n' database
    for _si_id in $(exakit_marketplace_installed_addons 2>/dev/null); do
        command -v "$(_exakit_addon_fn "$_si_id" status)" >/dev/null 2>&1 && printf '%s\n' "$_si_id"
    done
    return 0
}

# exakit_service_status <id> — running | stopped | not installed | unknown.
exakit_service_status() {
    if [ "$1" = "database" ]; then
        case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
            personal) personal_status ;;
            *)        printf '%s\n' "unknown" ;;
        esac
        return 0
    fi
    _ss_fn="$(_exakit_addon_fn "$1" status)"
    if command -v "$_ss_fn" >/dev/null 2>&1; then
        "$_ss_fn"
    else
        printf '%s\n' "unknown"
    fi
}

# exakit_service_start <id> / exakit_service_stop <id> — the database self-heals
# (a missing deployment is refused with the remedy, a stopped one started);
# add-ons delegate to their own hooks.
exakit_service_start() {
    if [ "$1" = "database" ]; then
        exakit_ensure_runtime_running deploy
        return $?
    fi
    _sst_fn="$(_exakit_addon_fn "$1" start)"
    command -v "$_sst_fn" >/dev/null 2>&1 || return 0
    "$_sst_fn"
}

exakit_service_stop() {
    if [ "$1" = "database" ]; then
        case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
            personal) personal_stop ;;
        esac
        return $?
    fi
    _ssp_fn="$(_exakit_addon_fn "$1" stop)"
    command -v "$_ssp_fn" >/dev/null 2>&1 || return 0
    "$_ssp_fn"
}

# _exakit_service_autostart_command <id> — the command a boot entry runs, or
# nothing when the service needs no entry.
#
# ONE ARGUMENT PER LINE. It used to be one space-joined line, which is not a
# format that can express an argv: the macOS arm split it with an unquoted
# `for arg in $cmd`, so a kit under a path with a space in it wrote a plist
# whose first ProgramArguments entry was "/Volumes/Data" and whose second was
# "Disk/exasol/bin/exasol" - two arguments, neither of them a program - and the
# same expansion globbed any path containing a wildcard character. launchd then
# refused the entry at every login while `exakit autostart` had already
# reported success. A newline is the one delimiter none of these arguments can
# contain.
_exakit_service_autostart_command() {
    if [ "$1" = "database" ]; then
        case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
            personal)
                _sac_cli="$(personal_cli 2>/dev/null || true)"
                [ -n "$_sac_cli" ] && printf '%s\nstart\n' "$_sac_cli"
                ;;
        esac
        return 0
    fi
    _sac_fn="$(_exakit_addon_fn "$1" autostart_command)"
    command -v "$_sac_fn" >/dev/null 2>&1 && "$_sac_fn"
    return 0
}

_exakit_autostart_label() { printf '%s.%s\n' "$EXAKIT_AUTOSTART_PREFIX" "$1"; }

# _exakit_service_autostart_kind <id> — "handoff" when the boot command starts
# something and returns, "longrunning" when systemd should supervise the
# process it spawns. THE SERVICE SAYS WHICH; the unit writer used to guess, by
# testing whether the command line began with "podman start".
#
# The guess was wrong for the one service every Linux install registers. The
# database's boot command is "$(personal_cli) start" — ~/.local/bin/exasol
# start — which never matched, so the database got Type=simple with
# Restart=on-failure. Two bites followed. A clean start exits 0, so after boot
# `systemctl --user status` reported inactive (dead) while the database was up
# and fine. And a start that failed at boot for a transient reason (rootless
# Podman not up yet, storage not mounted) was retried at systemd's 100 ms
# default, tripping DefaultStartLimitBurst within about half a second — after
# which systemd gives up permanently, and the box comes up with no database
# while `exakit autostart` still calls the entry registered.
_exakit_service_autostart_kind() {
    if [ "$1" = "database" ]; then
        printf 'handoff\n'
        return 0
    fi
    _sak_fn="$(_exakit_addon_fn "$1" autostart_kind)"
    if command -v "$_sak_fn" >/dev/null 2>&1; then
        "$_sak_fn"
        return 0
    fi
    # dash-server and exasol-scheduler both run their process in the
    # foreground, which is what systemd supervises. That is the safe default:
    # a long-running service wrongly called a handoff is never restarted.
    printf 'longrunning\n'
}

# _exakit_xml_escape <text> — text safe to place between XML tags. A plist is
# XML, and the paths that go into one are user-controlled: a single & or < in a
# directory name produced a document launchd could not parse, which failed the
# same silent way the word-splitting did. & first, or the escapes get escaped.
_exakit_xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# _exakit_autostart_argv_line <newline-delimited argv> — the same arguments as
# one systemd ExecStart line. systemd does its own splitting, so an argument
# carrying a space has to arrive quoted or it arrives as two.
_exakit_autostart_argv_line() {
    _aal_out=""
    while IFS= read -r _aal_arg; do
        [ -n "$_aal_arg" ] || continue
        case "$_aal_arg" in
            *[[:space:]]*|*'"'*|*\\*)
                _aal_arg="\"$(printf '%s' "$_aal_arg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\"" ;;
        esac
        _aal_out="${_aal_out:+$_aal_out }$_aal_arg"
    done <<EOF_ARGV
$1
EOF_ARGV
    printf '%s' "$_aal_out"
}

# _exakit_autostart_register <id> — write the platform's boot entry. Returns 1
# (with an explanation) when the platform has no supervisor to register with.
_exakit_autostart_register() {
    _ar_id="$1"
    _ar_cmd="$(_exakit_service_autostart_command "$_ar_id")"
    # Nothing to register is not a failure: a service with no boot command
    # simply has no entry to write.
    [ -n "$_ar_cmd" ] || return 0
    _ar_label="$(_exakit_autostart_label "$_ar_id")"
    case "$(detect_os)" in
        macos)
            mkdir -p "$EXAKIT_LAUNCHAGENT_DIR" || { warn "Could not create $EXAKIT_LAUNCHAGENT_DIR"; return 1; }
            _ar_plist="$EXAKIT_LAUNCHAGENT_DIR/$_ar_label.plist"
            # One <string> per argument: launchd does not run a shell.
            {
                printf '<?xml version="1.0" encoding="UTF-8"?>\n'
                printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                printf '<plist version="1.0">\n<dict>\n'
                printf '  <key>Label</key><string>%s</string>\n' "$_ar_label"
                printf '  <key>ProgramArguments</key>\n  <array>\n'
                printf '%s\n' "$_ar_cmd" | while IFS= read -r _ar_arg; do
                    [ -n "$_ar_arg" ] || continue
                    printf '    <string>%s</string>\n' "$(_exakit_xml_escape "$_ar_arg")"
                done
                printf '  </array>\n'
                printf '  <key>RunAtLoad</key><true/>\n'
                printf '  <key>StandardOutPath</key><string>%s/autostart-%s.log</string>\n' "$EXAKIT_LOG_DIR" "$_ar_id"
                printf '  <key>StandardErrorPath</key><string>%s/autostart-%s.log</string>\n' "$EXAKIT_LOG_DIR" "$_ar_id"
                printf '</dict>\n</plist>\n'
            } > "$_ar_plist" || { warn "Could not write $_ar_plist"; return 1; }
            # launchd creates the log with the default umask (0644). Every other
            # kit log is owner-only; create these first so they are too.
            ( umask 077; : >> "$EXAKIT_LOG_DIR/autostart-$_ar_id.log" ) 2>/dev/null
            chmod 600 "$EXAKIT_LOG_DIR/autostart-$_ar_id.log" 2>/dev/null
            # Load it now so the entry is live without a logout, and so a
            # rewritten plist replaces the old registration.
            launchctl unload "$_ar_plist" >/dev/null 2>&1
            # THE EXIT STATUS IS THE WHOLE POINT. Discarded, a plist launchd
            # refuses to load was followed by an "OK ... starts at login" line,
            # so the one failure mode this code has reported as success.
            if ! launchctl load "$_ar_plist" >/dev/null 2>&1; then
                warn "$_ar_id: the login entry was written, but launchd refused to load it."
                info "Nothing will start at login until that is fixed. See what launchd makes of it with: launchctl load $_ar_plist"
                _exakit_log_file "ERROR $_ar_id: launchctl load refused $_ar_plist"
                return 1
            fi
            # The plist path is not something to act on: `exakit autostart`
            # turns this off and `exakit status` reports it. Printed per SERVICE
            # it was also one line each, so a kit with add-ons announced the same
            # fact three times over three paths nobody types. The logfile keeps
            # the path, and enable() says the one sentence that matters.
            _exakit_log_file "OK    $_ar_id: starts at login ($_ar_plist)"
            ;;
        # WSL takes the linux arm: detect_os separates the two because the
        # INSTALLER must, but a systemd --user session is a systemd --user
        # session. Left out, WSL fell to the catch-all and was told automatic
        # start is "not supported on this platform" — while a WSL2 distro with
        # systemd enabled supports it exactly as any other Linux does, and one
        # without it is already answered, accurately, by the guard below.
        linux|wsl)
            if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
                warn "$_ar_id: this session has no systemd --user, so nothing was registered."
                # WSL2 ships with systemd OFF by default, so on a stock
                # Ubuntu-under-WSL this is the branch that runs — and the
                # remedy that makes it work is a two-line edit on the Windows
                # side that appeared nowhere in the kit. A guard that refuses
                # without naming the fix leaves the reader with no move.
                if [ "$(detect_os)" = "wsl" ]; then
                    warn "On WSL, systemd is off by default. Turn it on, then register again:"
                    info "  1. add these two lines to /etc/wsl.conf:  [boot]  and  systemd=true"
                    info "  2. from Windows: wsl --shutdown   (then reopen this distro)"
                    info "  3. exakit autostart"
                    info "Until then, start it by hand after a reboot with: exakit start"
                    return 1
                fi
                info "Start it by hand after a reboot with: exakit start"
                return 1
            fi
            mkdir -p "$EXAKIT_SYSTEMD_USER_DIR" || { warn "Could not create $EXAKIT_SYSTEMD_USER_DIR"; return 1; }
            _ar_unit="$EXAKIT_SYSTEMD_USER_DIR/$_ar_label.service"
            # Joined back into one line, because ExecStart is one line - but
            # joined with quoting, so an argument with a space in it survives
            # systemd's own splitting instead of arriving as two.
            _ar_exec="$(_exakit_autostart_argv_line "$_ar_cmd")"
            # A starter that hands off exits the moment the thing it started is
            # up: under Type=simple that reads as the service dying.
            # oneshot+RemainAfterExit is the honest shape for it.
            #
            # RestartSec=5 on the other arm regardless. systemd's default is
            # 100 ms, which burns DefaultStartLimitBurst in half a second and
            # then stops trying for good - so a service that fails once at boot
            # for a transient reason never comes back at all.
            case "$(_exakit_service_autostart_kind "$_ar_id")" in
                handoff) _ar_svc='Type=oneshot\nRemainAfterExit=yes' ;;
                *)       _ar_svc='Type=simple\nRestart=on-failure\nRestartSec=5' ;;
            esac
            {
                printf '[Unit]\nDescription=Exasol Starter Kit: %s\n\n' "$_ar_id"
                printf "[Service]\n${_ar_svc}\nExecStart=%s\n\n" "$_ar_exec"
                printf '[Install]\nWantedBy=default.target\n'
            } > "$_ar_unit" || { warn "Could not write $_ar_unit"; return 1; }
            systemctl --user daemon-reload >/dev/null 2>&1
            systemctl --user enable "$_ar_label.service" >/dev/null 2>&1 || {
                warn "Could not enable $_ar_label.service"; return 1; }
            # WITHOUT LINGER, a user unit dies at logout and never runs at boot
            # on a headless box - "starts at login" was silently "starts only
            # while you are logged in". Best-effort self-linger; when it is
            # refused (some distros gate it behind polkit), say what the
            # machine's admin has to run rather than pretending.
            if command -v loginctl >/dev/null 2>&1 && \
               [ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" != "yes" ]; then
                if loginctl enable-linger >/dev/null 2>&1; then
                    _exakit_log_file "OK    lingering enabled: $_ar_id survives logout and runs at boot"
                else
                    warn "$_ar_id starts at login, but only while you stay logged in: enabling lingering was refused."
                    info "On a headless or shared box, have an admin run: loginctl enable-linger $USER"
                fi
            fi
            _exakit_log_file "OK    $_ar_id: starts at login ($_ar_unit)"
            ;;
        *)
            warn "$_ar_id: automatic start is not supported on this platform."
            return 1
            ;;
    esac
}

# _exakit_autostart_unregister <id> — remove the boot entry, quietly.
_exakit_autostart_unregister() {
    _au_label="$(_exakit_autostart_label "$1")"
    _au_plist="$EXAKIT_LAUNCHAGENT_DIR/$_au_label.plist"
    if [ -f "$_au_plist" ]; then
        launchctl unload "$_au_plist" >/dev/null 2>&1
        rm -f "$_au_plist"
        ok "$1: no longer starts at login"
    fi
    _au_unit="$EXAKIT_SYSTEMD_USER_DIR/$_au_label.service"
    if [ -f "$_au_unit" ]; then
        systemctl --user disable "$_au_label.service" >/dev/null 2>&1
        rm -f "$_au_unit"
        systemctl --user daemon-reload >/dev/null 2>&1
        ok "$1: no longer starts at login"
    fi
    return 0
}


# _exakit_autostart_registered <id> — is a boot entry in place?
_exakit_autostart_registered() {
    _arg_label="$(_exakit_autostart_label "$1")"
    [ -f "$EXAKIT_LAUNCHAGENT_DIR/$_arg_label.plist" ] && return 0
    if [ -f "$EXAKIT_SYSTEMD_USER_DIR/$_arg_label.service" ]; then
        # A FILE ON DISK IS NOT A REGISTRATION. `systemctl --user enable` can
        # fail after the unit is written - no linger, a read-only wants
        # directory - and this probe answering "yes" on file existence alone is
        # what let `exakit autostart` and `exakit status` both report a boot
        # entry that systemd would never run.
        #
        # Only a POSITIVE refusal downgrades the answer. is-enabled has many
        # non-zero shapes (static, linked, indirect) and cannot be consulted at
        # all where there is no user bus, and treating any of those as "not
        # registered" would be a worse lie in the other direction.
        if command -v systemctl >/dev/null 2>&1; then
            case "$(systemctl --user is-enabled "$_arg_label.service" 2>/dev/null)" in
                disabled|masked) return 1 ;;
            esac
        fi
        return 0
    fi
    return 1
}



# exakit_autostart_enable / _disable — every service at once. Best-effort: a
# platform without a supervisor says so and the rest still applies.
exakit_autostart_enable() {
    _ae_any=0
    for _ae_id in $(exakit_service_ids); do
        _exakit_autostart_register "$_ae_id" && _ae_any=1
    done
    if [ "$_ae_any" = 1 ]; then
        manifest_set autostart.enabled true
        # One line, whatever the service count -- the twin of the sentence
        # disable() has always printed. Without it, answering "yes" to
        # `exakit autostart` produced no output at all once the per-service
        # lines went.
        ok "Automatic start after a restart is on."
    else
        manifest_set autostart.enabled false
    fi
    return 0
}

# exakit_autostart_default_on — turn automatic start ON for a FRESH install.
#
# The kit exists to give someone a database that is simply there; leaving it off
# by default meant a reboot silently took it away and the next command failed
# with a connection error. Only ever applied when the manifest has no opinion
# yet: a user who ran `exakit autostart off` has said no, and that answer is
# recorded as false and must survive every later run of the installer.
# ⇄ twin: Enable-ExakitAutostartDefault in exakit-common.ps1.
# exakit_with_spinner <label> <command...> — run a slow phase behind the kit's
# spinner, so a command never sits there silent.
#
# `exakit status`, `info` and `version` all have to ask something slow before
# they can print anything: a database round trip, a container probe, sometimes
# the network. They used to show nothing at all until the answer arrived, so a
# two-second wait was indistinguishable from a hang — the reader has no way to
# tell "working" from "stuck". The install path has used this spinner for its
# steps since it was written; the read commands never adopted it.
#
# ui_spin_begin re-checks `-t 1` at call time, so nothing is drawn when stdout
# is a pipe or a file — which is also what keeps a frame out of the middle of
# a --json document.
#
# The command's own stdout is left alone: only the spinner writes to the
# terminal, and it clears its line before this returns. The exit status is the
# command's, so callers can still branch on it.
# ⇄ twin: Invoke-ExakitWithSpinner in exakit-common.ps1.
exakit_with_spinner() {
    _ws_label="$1"; shift
    ui_spin_begin "$_ws_label"
    "$@"
    _ws_rc=$?
    ui_spin_end
    return "$_ws_rc"
}

exakit_autostart_default_on() {
    case "$(manifest_get autostart.enabled 2>/dev/null || true)" in
        true|false) return 0 ;;
    esac
    # Quiet: a default the INSTALLER chose is not news, and the line was landing
    # directly under "Your starter kit is ready to use." `exakit autostart` still
    # says it, because there the reader asked a question and deserves an answer.
    # The logfile keeps it either way, and `exakit status` reports the state.
    _ado_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    EXAKIT_QUIET_DETAIL=1
    exakit_autostart_enable
    EXAKIT_QUIET_DETAIL="$_ado_prev_quiet"
    return 0
}

exakit_autostart_disable() {
    for _ad_id in $(exakit_service_ids); do
        _exakit_autostart_unregister "$_ad_id"
    done
    manifest_set autostart.enabled false
    ok "Automatic start after a restart is off."
    return 0
}

# exakit_autostart_print — the state of every boot entry.
exakit_autostart_print() {
    # A card, like every other framed answer the kit gives. The service ids come
    # from the registry, so the name column is measured rather than assumed.
    _ap_w=7
    for _ap_id in $(exakit_service_ids); do
        [ "${#_ap_id}" -gt "$_ap_w" ] && _ap_w="${#_ap_id}"
    done
    printf '\n'
    ui_panel_begin "Automatic start after a restart"
    ui_panel_line "$(printf '%-*s  %s' "$_ap_w" "Service" "Status")"
    for _ap_id in $(exakit_service_ids); do
        if _exakit_autostart_registered "$_ap_id"; then
            ui_panel_line "$(printf '%-*s  %s' "$_ap_w" "$_ap_id" "enabled")"
        else
            ui_panel_line "$(printf '%-*s  %s' "$_ap_w" "$_ap_id" "disabled")"
        fi
    done
    ui_panel_end
    printf '\n'
    # No "turn it on with ..." line: the question that follows this panel IS the
    # way to change it, and it named two commands that no longer exist.
    return 0
}

exakit_uninstall_menu() {
    _um_labels=("Skip — uninstall nothing")
    _um_keys=("__skip__")
    _um_tee="${UI_TEE:-|-}"; _um_corner="${UI_CORNER:-\`-}"

    # The BUILT-IN components are deliberately NOT rows here.
    #
    # They are not independent things a user meaningfully picks between: the
    # database, its MCP configs, the read-only MCP user, exapump's profile and
    # the pyexasol venv are one working installation, and removing one of them
    # leaves a kit that looks installed and does not work — a state nobody
    # asked for and the update flow cannot repair. The two honest choices for
    # the core are keep it or remove it, which is exactly Skip and EVERYTHING.
    #
    # ADD-ONS are the real per-item choice: each is optional by construction,
    # nothing else depends on it, and removing one leaves everything else
    # working. So they are the only individually selectable rows.
    #
    # There is no by-name form. `exakit uninstall` takes flags only, and the
    # menu is the whole interface: the components below are reachable from it
    # and from nothing else. The hint that used to sit under this menu claimed
    # otherwise and named a syntax the parser rejects.

    # Kit-managed add-ons, each removable on its own.
    _um_addons="$(exakit_marketplace_installed_addons 2>/dev/null || true)"
    if [ -n "$_um_addons" ]; then
        # "Clear the add-ons, keep the kit" was already reachable - tick every
        # add-on row and leave EVERYTHING alone - but nothing on the screen said
        # so, and with three add-ons it was three keystrokes and a guess about
        # whether the combination was safe. This states the outcome instead.
        #
        # A plain row, not a group parent: the checkbox widget carries one group
        # spec and EVERYTHING already owns it (it has to stay a master over the
        # add-on rows, or the screen could claim "everything" with one unticked).
        # Only offered when there is more than one add-on, because with a single
        # add-on it is the same keystroke twice.
        # The scope row, and the caption at the same time. A separate
        # "Add-ons (kit-managed)" caption said the word twice and left the sweep
        # floating above the tree it acts on.
        #
        # Both scope rows say what SURVIVES, not what goes: that is the one
        # fact a reader at this screen is actually weighing, and "keeps:
        # nothing" is the plainest statement EVERYTHING can make.
        #
        # "keeps: starter-kit" names the thing, not its parts. The row used to
        # list them -- database, data, exapump, MCP, pyexasol -- which is the
        # longest line on the screen, has to be re-checked against reality every
        # time a component is added, and asks the reader to reassemble "the kit"
        # from five nouns to answer a question they already think of in one.
        _um_labels+=("Add-ons only — keeps: starter-kit")
        _um_keys+=("__all_addons__")
        _um_count="$(printf '%s\n' $_um_addons | grep -c .)"
        _um_i=0
        for _um_id in $_um_addons; do
            _um_i=$((_um_i + 1))
            if [ "$_um_i" -eq "$_um_count" ]; then _um_conn="$_um_corner"; else _um_conn="$_um_tee"; fi
            # Indented a level further than the scope row above them, so the
            # members read as belonging to it rather than sitting beside it.
            _um_labels+=("  $_um_conn $_um_id")
            _um_keys+=("$_um_id")
        done
    fi

    _um_labels+=("EVERYTHING — keeps: nothing")
    _um_keys+=("everything")
    _um_every_idx="${#_um_labels[@]}"

    # No hint here. There used to be one naming a by-name form -- `exakit
    # uninstall <database|mcp_configs|...>` -- that the argument parser has
    # never accepted: every one of those forms answers "Unknown option". It
    # described a capability the CLI does not offer, directly above the menu
    # that does, so a reader who trusted it left the menu to type a command that
    # could only fail. The menu lists what is on offer; it needs no preamble.

    # EVERYTHING is a MASTER toggle over every row above it: picking it ticks
    # them all, and unticking any single row releases it — so the screen can
    # never claim "everything" while something sits unticked. Skip stays the
    # exclusive opt-out. (No children means nothing but Skip and EVERYTHING is
    # on offer, and a group spec would be meaningless.)
    if [ "$_um_every_idx" -gt 2 ]; then
        EXAKIT_CHECKBOX_GROUP="$_um_every_idx:2:$((_um_every_idx - 1)):master"
        # "Add-ons only" is itself a master over the add-ons drawn under it, so
        # the row and its tree agree: ticking it ticks them, and ticking the last
        # of them ticks it. It was only ever a sweep KEY -- the removal expanded
        # it to every add-on, which was right -- but the checkboxes underneath
        # never moved, so the screen showed a scope that was on with none of its
        # members chosen. Listed FIRST because it nests inside EVERYTHING.
        if [ "$_um_every_idx" -gt 3 ]; then
            EXAKIT_CHECKBOX_GROUP="2:3:$((_um_every_idx - 1)):all $EXAKIT_CHECKBOX_GROUP"
        fi
    fi
    EXAKIT_CHECKBOX_EXCLUSIVE=1
    ui_checkbox_menu "Select what to uninstall" "1" "${_um_labels[@]}"
    case ",$EXAKIT_CHECKBOX_SELECTION," in
        *",1,"*)
            info "Nothing was uninstalled."
            return 0
            ;;
    esac

    _um_picked=""
    _um_picked_labels=""
    for _um_idx in $(printf '%s' "$EXAKIT_CHECKBOX_SELECTION" | tr ',' ' '); do
        [ "$_um_idx" -ge 2 ] || continue
        _um_key="${_um_keys[$((_um_idx - 1))]}"
        # BEFORE the __*__ skip below: the sweep key is spelled like the
        # placeholder keys (headers, spacers) that the skip exists to drop, so
        # checking it afterwards silently discarded the pick and the menu
        # answered "Nothing selected" with the row plainly ticked.
        if [ "$_um_key" = "__all_addons__" ]; then
            # Expand to the add-ons themselves, so the confirmation panel and the
            # removal loop see the same concrete list every other pick produces:
            # nobody types UNINSTALL against a row that hides its members.
            for _um_a in $_um_addons; do
                case " $_um_picked " in *" $_um_a "*) continue ;; esac
                _um_picked="${_um_picked:+$_um_picked }$_um_a"
                _um_picked_labels="${_um_picked_labels:+$_um_picked_labels
}$_um_a"
            done
            continue
        fi
        case "$_um_key" in __*__) continue ;; esac
        # EVERYTHING swallows any other pick — the full run covers it all.
        if [ "$_um_key" = "everything" ]; then
            _um_picked="everything"
            _um_picked_labels="EVERYTHING — the full kit (database + data, MCP configs, skills, exapump, pyexasol, add-ons, kit home, exakit)"
            break
        fi
        case " $_um_picked " in *" $_um_key "*) continue ;; esac
        _um_picked="${_um_picked:+$_um_picked }$_um_key"
        _um_picked_labels="${_um_picked_labels:+$_um_picked_labels
}$(printf '%s' "${_um_labels[$((_um_idx - 1))]}" | sed "s/^  *//; s/^$_um_tee //; s/^$_um_corner //")"
    done
    [ -n "$_um_picked" ] || { info "Nothing selected — nothing was uninstalled."; return 0; }

    # The informed consent: exactly what was picked, in plain words, then the
    # irreversibility warning, then the typed gate. --yes never reaches this
    # menu (it is the scripted FULL uninstall), so the word is always typed.
    printf '\n'
    ui_panel_begin "This will PERMANENTLY remove"
    # No pipeline here: ui_panel_line buffers in the CURRENT shell, and a
    # pipeline stage is a subshell that would swallow every line.
    while IFS= read -r _um_line; do
        [ -n "$_um_line" ] && ui_panel_line "$_um_line"
    done <<EXAKIT_UM_PANEL_EOF
$_um_picked_labels
EXAKIT_UM_PANEL_EOF
    # NAME THE DATABASE. "EVERYTHING - the full kit (database + data, ...)" is
    # a category; the container and the volume are the things the engine
    # deletes, and until now they were printed only in the record line AFTER the
    # removal. A reader who has one of them on the screen can recognise it as
    # the database the other side of the machine is using; a reader who has the
    # word "database" cannot.
    case " $_um_picked " in
        *" database "*|*" everything "*)
            ui_panel_line ""
            ui_panel_line "Database: the local Exasol Personal deployment"
            ui_panel_line "The deployment IS the database - removing it cannot be undone."
            ;;
    esac
    ui_panel_end
    printf '\n'
    warn "This is IRREVERSIBLE. Removed data cannot be recovered."
    case " $_um_picked " in
        *" database "*|*" everything "*)
            warn "The database selection deletes ALL local database data."
            ;;
    esac
    _um_tty="$(_exakit_prompt_tty)"
    [ -n "$_um_tty" ] || die "uninstall needs an interactive terminal to confirm; use --yes for the scripted full uninstall."
    printf '\033[1;31m  !\033[0m Type \033[1mUNINSTALL\033[0m to remove the items above (anything else cancels): '
    if [ "$_um_tty" = "/dev/tty" ]; then read -r _um_answer < /dev/tty; else read -r _um_answer; fi
    [ "$_um_answer" = "UNINSTALL" ] || { info "Uninstall cancelled — nothing was removed."; return 0; }

    printf '\n'
    for _um_key in $_um_picked; do
        _exakit_uninstall_component "$_um_key" 0
    done
    printf '\n'
    # A full uninstall has just deleted the exakit binary, so pointing at
    # `exakit info` sends the reader to a command that no longer exists -
    # the last word of the run being one that cannot be followed. Anything
    # short of EVERYTHING leaves the CLI in place, and there info is exactly
    # the right next step.
    case " $_um_picked " in
        *" everything "*)
            # "The kit is gone" is a claim, and it is false when the teardown
            # could not read a runtime from the manifest and left the database
            # on disk. Saying it anyway is what turns a recoverable surprise
            # into an invisible one.
            if [ "${EXAKIT_UNINSTALL_DB_SKIPPED:-0}" = 1 ]; then
                ok "Done. The kit is gone - but the database was left in place (see the note above)."
            else
                ok "Done. The kit is gone."
            fi
            info "Install it again any time: $(exakit_install_command)"
            ;;
        *)
            ok "Done. See where you stand with: exakit info"
            ;;
    esac
    return 0
}

exakit_uninstall_run() {
    _dry="${1:-0}"
    # A real run narrates itself on ONE line. Every path it touches was printed
    # as its own bullet -- three per add-on, then the deployment, the MCP
    # configs, the kit home and one per CLI binary -- around twenty lines of
    # "Removing <absolute path>" for a command whose whole result is "it is
    # gone". The paths go to the LOGFILE, which is the right place for an
    # account of what a destructive command touched.
    #
    # THE OUTCOMES DO NOT GO WITH THEM. Quieting the paths through
    # EXAKIT_QUIET_DETAIL also quieted every info() that named WHAT was gone, so
    # a run that removed a database, a container, a volume, three add-ons, five
    # AI-client configs, two virtual environments and the launcher printed six
    # lines and named none of them. And step 5 below deletes the logfile the
    # detail was routed into, so afterwards there was no record anywhere, on
    # screen or on disk. Each area therefore promotes ONE durable line through
    # _done (ok_step, which survives the quiet bracket), naming what it removed;
    # the closing line says that those lines are the whole record, because by
    # then they are.
    #
    # NOT in a dry run: there, listing every path IS the output. That is the
    # only thing --dry-run produces and the reason anyone asks for it.
    _un_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    if [ "$_dry" != "1" ] && [ -t 1 ]; then
        EXAKIT_QUIET_DETAIL=1
        ui_spin_begin "Removing the kit"
    fi
    _step() { # _step <message>  — narrate the action (or the plan line)
        if [ "$_dry" = "1" ]; then info "  will remove: $1"; else info "$1"; fi
    }
    # _un_safe_target <path> — is this a path this command may delete?
    #
    # EXAKIT_HOME IS TAKEN FROM THE ENVIRONMENT AND WAS NEVER CHECKED. It is
    # spelled `${EXAKIT_HOME:-$HOME/.exasol-starter-kit}` at the top of this
    # file, so whatever the caller exported is what `rm -rf` was handed — and
    # the kit's OWN WSL remedy tells people to set it and keep it exported, so
    # the users most likely to have it set permanently are the ones an
    # `exakit uninstall` would point wherever it happened to say. A relative
    # value made the target depend on the current directory, and `--yes`
    # bypassed the only confirmation. Four cheap questions close that:
    # absolute, not the home directory itself, not a filesystem root, and
    # recognisable as a directory this kit built.
    #
    # THE MANIFEST CANNOT BE A HARD REQUIREMENT, which a first cut of this
    # guard made it. uninstall is the command people reach for precisely when
    # an install is broken - interrupted before the manifest was written, or
    # with a manifest that no longer parses - and a guard that refuses those
    # leaves the user with no supported way to clean up. So the manifest
    # proves the case, and where it is missing the directory still has to look
    # like ours: one of the structural entries the kit creates, or nothing at
    # all (rm -rf on an empty directory destroys nothing, and an empty
    # directory is not /etc). A populated directory with none of our markers -
    # the EXAKIT_HOME=/etc or EXAKIT_HOME=~/src mistake this exists to stop -
    # is refused.
    _un_safe_target() {
        case "$1" in
            /*) : ;;
            *)  return 1 ;;
        esac
        [ "$1" != "/" ] || return 1
        [ "$1" != "$HOME" ] || return 1
        [ "${1%/}" != "${HOME%/}" ] || return 1
        [ -d "$1" ] || return 1
        [ -f "$1/manifest.json" ] && return 0
        for _un_marker in manifest.json logs cache credentials kit mcp backups \
                          libexec workflows migration .last-failure .install.lock; do
            [ -e "$1/$_un_marker" ] && return 0
        done
        # Nothing of ours in it. Empty is still fine; anything else is not.
        for _un_entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
            [ -e "$_un_entry" ] || [ -L "$_un_entry" ] || continue
            return 1
        done
        return 0
    }
    _rm() { # _rm <path> — remove a path unless dry-run
        [ "$_dry" = "1" ] || rm -rf "$1"
    }
    _done() { # _done <message> — the record line for one area of the removal.
        # Real runs only: a dry run removed nothing, so a line in the past tense
        # would be a lie, and the plan lines above already say what it would do.
        [ "$_dry" = "1" ] || ok_step "$1"
    }

    # THE GUARD RUNS BEFORE ANYTHING IS REMOVED. It used to sit in step 5, just
    # above the kit-home rm, so an unsafe EXAKIT_HOME was refused only after the
    # database, the MCP entries, the skills and the exapump profiles were
    # already gone - and the refusal then said "Nothing was removed". Asking
    # first is what makes that sentence true.
    if [ -e "$EXAKIT_HOME" ] && ! _un_safe_target "$EXAKIT_HOME"; then
        error "Refusing to remove $EXAKIT_HOME: it is not an absolute path to a kit home the kit created."
        info "EXAKIT_HOME must be an absolute path holding the kit's manifest.json, and cannot be your home directory."
        info "Nothing was removed. Check EXAKIT_HOME, or unset it to use the default ~/.exasol-starter-kit."
        die "Unsafe EXAKIT_HOME: $EXAKIT_HOME"
    fi

    # 0a) Boot entries first: a LaunchAgent or systemd unit left behind would
    #     try to start something that no longer exists on the next login.
    if command -v exakit_service_ids >/dev/null 2>&1; then
        for _un_svc in $(exakit_service_ids 2>/dev/null); do
            if _exakit_autostart_registered "$_un_svc" 2>/dev/null; then
                if [ "$_dry" = "1" ]; then
                    info "  will remove: the automatic-start entry for $_un_svc"
                else
                    _exakit_autostart_unregister "$_un_svc" >/dev/null 2>&1 || true
                fi
            fi
        done
    fi

    # 0b) Kit-managed marketplace add-ons that live OUTSIDE the kit home (the
    #    VS Code extension). Anything under the kit home or the bin dir is
    #    swept by steps 5-6 regardless; a system-installed copy the kit never
    #    managed is not touched (each hook enforces that itself).
    _un_addons_gone=""
    # Tells an add-on hook that the kit home goes next, so it does not promise
    # to keep something step 5 is about to delete (dash-server's instance).
    EXAKIT_UNINSTALL_FULL=1
    if command -v exakit_marketplace_installed_addons >/dev/null 2>&1; then
        for _un_id in $(exakit_marketplace_installed_addons 2>/dev/null); do
            _un_fn="$(_exakit_addon_fn "$_un_id" uninstall)"
            command -v "$_un_fn" >/dev/null 2>&1 || continue
            if "$_un_fn" "$_dry"; then
                _un_addons_gone="${_un_addons_gone:+$_un_addons_gone, }$_un_id"
            else
                warn "Removing the $_un_id add-on reported issues (continuing uninstall)"
            fi
        done
    fi
    [ -n "$_un_addons_gone" ] && _done "Add-ons removed: $_un_addons_gone"

    # 1) Database + all data. Uses the runtime removal helper (always --data),
    #    which for Personal also reaps any orphaned runner daemon on the DB port.
    _type="$(manifest_get runtime.type 2>/dev/null || true)"
    if [ -n "$_type" ]; then
        # Named BEFORE the removal, not only in the record line after it: on
        # `--yes` there is no gate to read, so this line is the last chance to
        # see what is about to be deleted.
        _step "local Exasol $_type deployment and ALL its data"
        if [ "$_dry" != "1" ]; then
            case "$_type" in
                personal) personal_teardown --data || warn "Database removal reported errors (continuing uninstall)" ;;
                *)        warn "Unknown runtime type '$_type'; skipping database removal" ;;
            esac
        fi
        # BY NAME. "The database was removed" leaves the reader to guess which
        # container and which volume that was, and those are exactly the two
        # names they need if the engine kept one of them: a container the engine
        # refused to remove is found again by name, and nothing else on screen
        # ever says what it was called.
        case "$_type" in
            personal) _done "Database removed: the local Exasol Personal deployment and all its data" ;;
            *)        : ;;
        esac
    else
        # No runtime.type: the manifest is missing or truncated (an interrupted
        # install, a half-written record, a kit home staged by a dry run). The
        # deployment does NOT live under the kit home -- it is in its own
        # directory -- so removing the kit home does not remove it, and every
        # tool that knew how to is about to be deleted by the steps below.
        # Saying nothing here is how a database survives its own uninstall with
        # no record that it exists. Name the path so the removal is possible by
        # hand afterwards.
        EXAKIT_UNINSTALL_DB_SKIPPED=1
        warn "No runtime recorded in the manifest, so the database was NOT removed."
        info "If a local deployment exists it is still on disk, with all its data, at:"
        info "  ${EXAKIT_PERSONAL_DEPLOY_DIR:-$HOME/.exasol/personal/deployments/default}"
        info "Remove it by hand, or re-install and then uninstall again to have the kit do it."
    fi

    # 2) Managed MCP configuration in every AI client the kit configures.
    #    Best-effort: a failure here must not block the rest.
    if command -v exakit_mcp_operation >/dev/null 2>&1; then
        # The client list comes from the one function that owns it rather than
        # being spelled out here: this line named three clients while the
        # operation covered eight, so five configs were edited that nothing on
        # screen ever mentioned.
        _un_mcp_clients="$(exakit_mcp_clients_from_args 2>/dev/null | tr ',' ' ')"
        _step "managed MCP configuration in the AI clients (${_un_mcp_clients:-all managed clients})"
        if [ "$_dry" != "1" ]; then
            exakit_mcp_operation uninstall >/dev/null 2>&1 || \
                warn "Removing the managed AI client config reported issues (continuing uninstall)"
        fi
        _done "MCP entry removed from the AI clients the kit manages: ${_un_mcp_clients:-all managed clients}"
    fi

    # 3) Installed AI skills (shared with the selectable uninstall menu).
    _exakit_remove_installed_skills "$_dry"

    # 4) exapump profile store (the kit created it; the binary goes in step 6).
    if [ -e "${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}" ]; then
        _step "exapump profiles at ${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}"
        _rm "${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}"
    fi

    # 5) Kit home: credentials, logs, manifest, cached kit copy, MCP snapshots,
    #    and the pyexasol / marketplace add-on virtual environments and state
    #    (dash-server's venv and instance data live under the kit home too).
    if [ -e "$EXAKIT_HOME" ]; then
        # The MCP snapshots taken in step 2 are the only copy of each client
        # config as it was BEFORE this uninstall edited it, and they lived in the
        # kit home this step deletes — so a client file the kit had to rewrite
        # (or, for VS Code, used to delete) had no backup the moment it was
        # needed. Keep them beside the home, not inside it.
        if [ "$_dry" != "1" ] && [ -d "$EXAKIT_HOME/backups" ] && [ -n "$(ls -A "$EXAKIT_HOME/backups" 2>/dev/null)" ]; then
            _un_keep="${EXAKIT_HOME}-backups-$(date +%Y%m%d-%H%M%S)"
            if mv "$EXAKIT_HOME/backups" "$_un_keep" 2>/dev/null; then
                info "AI client config snapshots kept at $_un_keep (delete it when you are sure)"
            fi
        fi
        # Checked by the guard at the top of this function, before step 0a.
        _step "kit home $EXAKIT_HOME (credentials, logs, manifest, snapshots, pyexasol venv, add-ons)"
        _rm "$EXAKIT_HOME"
        _done "Kit home removed: $EXAKIT_HOME (credentials, logs, manifest, snapshots, pyexasol venv, add-on state)"
    fi

    # 6) CLI binaries. Removed last so earlier steps can still call the launcher.
    #    Removing the running exakit binary itself is safe (the inode survives
    #    until the process exits). Marketplace add-on launchers are swept by
    #    registry id — a new add-on needs no edit here, and a machine without
    #    one simply has no file to remove.
    _bins="exasol exakit exapump"
    if command -v exakit_marketplace_addons >/dev/null 2>&1; then
        _bins="$_bins $(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ')"
    fi
    _un_bins_gone=""
    for _bin in $_bins; do
        if [ -e "$EXAKIT_BIN_DIR/$_bin" ]; then
            _step "CLI binary $EXAKIT_BIN_DIR/$_bin"
            _rm "$EXAKIT_BIN_DIR/$_bin"
            _un_bins_gone="${_un_bins_gone:+$_un_bins_gone, }$_bin"
        fi
    done
    [ -n "$_un_bins_gone" ] && _done "Commands removed from $EXAKIT_BIN_DIR: $_un_bins_gone"
    ui_spin_end
    EXAKIT_QUIET_DETAIL="$_un_prev_quiet"
    # Said last, and said plainly, because it is the one thing the reader cannot
    # find out afterwards: the logfile that held the per-path detail lived inside
    # the kit home this run has just deleted, so the lines above are the only
    # account of what was removed that still exists anywhere.
    if [ "$_dry" != "1" ]; then
        info_step "The lines above are the whole record of this uninstall — the install log lived in the kit home and went with it."
    fi
    # Explicit, because every step here is best-effort: each failure warns and
    # carries on, so the function has always succeeded, and leaving the status to
    # whatever the last line happened to be made that an accident of ordering.
    return 0
}
