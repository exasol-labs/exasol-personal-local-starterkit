#!/usr/bin/env bash
# marketplace.sh — proves the marketplace add-on layer: the registry, the
# installed/pending detection that gates `exakit update all`, the
# EXAKIT_MARKETPLACE_ADDONS non-interactive contract, and the dash-server
# module's version resolution, launcher generation and soft-fail accounting.
# Pure logic against a sandboxed kit home: no network, no installs.
#
# EXPECT THREE TO FOUR MINUTES. A run that looks stuck is almost certainly not:
# the suite is hermetic and offline, and the time goes on hundreds of
# manifest_get / manifest_set calls, each of which starts a Python process.
# (Measured with EXAKIT_ABOUT_OFFLINE=1 as well, so the About fetch is not the
# cause.) Nothing here reaches the network or installs anything, so a long run
# is slow, never hung — leave it to finish rather than interrupting it, which
# is how a half-run gets mistaken for a failure.
#
#   bash tests/marketplace.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The add-on table's width and tick checks measure DRAWN columns, which only
# comes out right where the glyphs count as one character each. See the helper.
. "$ROOT/tests/lib/utf8-locale.sh"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac
}

lacks() { # lacks <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The kit home is redirected for the whole run: nothing here may touch a real
# installation. common.sh derives its paths at source time, so this comes first.
#
# HOME IS REDIRECTED TOO, and that is not belt-and-braces. Redirecting only
# EXAKIT_HOME and EXAKIT_BIN_DIR left every path spelled "$HOME/..." pointing at
# the developer's real home, and this suite exercises component removal — so a
# run of these tests deleted the developer's actual ~/.exapump profiles, and the
# machine only said so later, from an unrelated command. Anything derived from
# HOME at source time has to be redirected before common.sh is read.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
HOME="$WORK/fake-home"
export EXAKIT_HOME EXAKIT_BIN_DIR HOME
EXAKIT_EXAPUMP_CONFIG_DIR="$HOME/.exapump"
export EXAKIT_EXAPUMP_CONFIG_DIR
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$HOME"
# The suite must behave the same on a machine that really has these add-ons
# installed — the feature working must not fail its own tests. The generic
# system-present probe walks PATH, so rebuild PATH without any directory that
# carries a real add-on launcher (the system-install section below adds its own
# stub dir when it wants one).
#
# EVERY LAUNCHER, NOT JUST dash-server. This filter named one add-on while the
# probe it defends against walks PATH for all of them, so installing any other
# one broke the suite on the developer's own machine. Found by installing
# json-tables here: `command -v exasol-json-tables` found the real binary in
# ~/.local/bin, the menu correctly said "json-tables is already on this system —
# the kit leaves it alone", and three checks that expect it to be installable
# failed. The product was right and the suite was not hermetic. Launcher names
# differ from ids on purpose (json-tables installs `exasol-json-tables`), so
# they are listed rather than derived.
_clean_path=""
_old_ifs="$IFS"; IFS=:
for _dir in $PATH; do
    _keep=1
    for _launcher in dash-server exasol-json-tables dbt-exasol exasol-scheduler; do
        [ -x "$_dir/$_launcher" ] && { _keep=0; break; }
    done
    [ "$_keep" = 1 ] && _clean_path="${_clean_path:+$_clean_path:}$_dir"
done
IFS="$_old_ifs"
PATH="$_clean_path"
# Same isolation for the VS Code extension: its live probe asks the REAL VS
# Code unless an extensions dir is forced, so a developer machine that
# genuinely has the extension would silently cover the add-on. An empty
# sandbox dir makes every machine — with or without VS Code — read the same.
EXAKIT_EXASOL_VSCODE_EXTDIR="$WORK/vscode-ext"
mkdir -p "$EXAKIT_EXASOL_VSCODE_EXTDIR"
export EXAKIT_EXASOL_VSCODE_EXTDIR
# ...and a stub `code` ON PATH, so whether the extension add-on is APPLICABLE
# is fixed too. Without this the suite would read differently on a machine
# with VS Code than on a CI runner without it: the add-on is deliberately
# hidden where its host app is missing, which is exactly what the dedicated
# section below tests by hiding this stub again.
mkdir -p "$WORK/code-bin"
cat > "$WORK/code-bin/code" <<'CODESTUBEOF'
#!/bin/sh
echo "$*" >> "${CODE_CALLS:-/dev/null}"
case "$*" in
    *--list-extensions*) [ -n "${CODE_LISTING:-}" ] && printf '%s\n' "$CODE_LISTING" ;;
esac
exit 0
CODESTUBEOF
chmod +x "$WORK/code-bin/code"
PATH="$WORK/code-bin:$PATH"
# No suite may reach the network, and the add-on About lookup is the first thing
# in this layer that would: the closing offer warms its cache before it asks
# anything. Offline is the default here and is flipped off only inside the About
# section below, which points the URL at a dead port so nothing leaves the host.
EXAKIT_ABOUT_OFFLINE=1
export EXAKIT_ABOUT_OFFLINE
. "$ROOT/setup/lib/common.sh"
_exakit_marketplace_python_hooks

# ...and its own port. The default 5100 is where a developer's REAL dash-server
# listens, and the ownership probe would rightly call that a foreign process
# holding the suite's port. A sandbox-unique high port keeps every machine
# reading the same. Explicit, so the manifest never overrides it.
EXAKIT_DASH_SERVER_PORT="$((5900 + $$ % 90))"
export EXAKIT_DASH_SERVER_PORT

manifest_init >/dev/null 2>&1

# cover_every_addon — stub <id>_system_present for EVERY registered add-on, so
# "the user already has all of these" is expressed once instead of add-on by
# add-on. Call it inside the subshell whose result depends on nothing pending.
cover_every_addon() {
    for _cea_id in $(exakit_marketplace_addons | cut -d'|' -f1); do
        eval "$(printf '%s' "$_cea_id" | tr '-' '_')_system_present() { return 0; }"
    done
}

echo "registry:"
check "addons list carries every registered add-on" "dash-server dbt-exasol exasol-scheduler exasol-vscode json-tables notebook udf-devkit" \
    "$(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "addon module is loaded" "yes" "$(exakit_marketplace_addon_available dash-server && echo yes || echo no)"
check "component block" "components.dash-server" "$(_exakit_component_block dash-server)"
_dash_fallback="$(python3 -c 'import json; d=json.load(open("'"$ROOT"'/marketplace/catalog.json")); print(next(x["default_version"] for x in d["addons"] if x["id"] == "dash-server"))')"
check "fallback version comes from the catalog" "$_dash_fallback" "$(_exakit_component_fallback dash-server)"
# Both readers (python and the awk fallback) must agree with a plain json.load
# on the new component's path — the same parity promise versions-manifest.sh
# makes for every other component.
_shipped_ds="$(python3 -c 'import json; print(json.load(open("'"$ROOT"'/versions.json"))["components"]["dash-server"]["version"])')"
check "advertised version comes from versions.json" "$_shipped_ds" \
    "$(exakit_versions_value components.dash-server.version "$ROOT/versions.json")"
check "advertised version (awk fallback reader)" "$_shipped_ds" \
    "$( ( EXAKIT_DISABLE_SYSTEM_PYTHON=1; exakit_ensure_uv() { return 1; }; exakit_versions_value components.dash-server.version "$ROOT/versions.json" ) )"
# The published manifest can PREDATE an add-on (a kit copy ships it before the
# advertised set catches up): the available version must fall back to the
# catalog fallback instead of reading as unknown — that empty answer used to
# make `exakit update dash-server` die on a machine whose fetched doc had no
# dash-server block yet.
check "a manifest without the add-on uses the catalog fallback" \
    "$_dash_fallback" \
    "$( ( exakit_versions_value() { return 1; }; exakit_component_available dash-server ) )"
check "env override wins" "9.9.9" "$(EXAKIT_DASH_SERVER_VERSION=9.9.9 _exakit_component_env_override dash-server)"
check "release url is the tag tarball" \
    "https://github.com/exasol-labs/dash-server/archive/refs/tags/v0.1.0.tar.gz" \
    "$(PYTHONPATH="$ROOT/marketplace" python3 -c 'from addons import dash_server; print(dash_server._release_url("0.1.0"))')"

echo "update targets never sneak an add-on in:"
check "not installed -> excluded from all" "exakit runtime exapump mcp pyexasol skills" \
    "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"
check "explicit target still routable" "dash-server" "$(exakit_update_targets dash-server)"
check "pending detection sees the gap" "yes" "$(exakit_marketplace_has_pending && echo yes || echo no)"

# A fake installed venv: exakit_component_current probes this python stub, so
# from here on the add-on counts as installed.
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
# rm -f first: a uv-created venv's bin/python is a SYMLINK to the shared
# managed interpreter, and `>` follows symlinks -- writing through it
# replaced the developer's real 18 MB CPython with this 17-byte stub and
# broke uv for every later component install.
rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
cat > "$EXAKIT_HOME/dash-server-venv/bin/python" <<'EOF'
#!/bin/sh
echo "0.1.0"
EOF
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
manifest_set components.dash_server.python "$EXAKIT_HOME/dash-server-venv/bin/python"
manifest_set components.dash_server.version "0.1.0"

echo "installed add-on state:"
check "live probe answers" "0.1.0" "$(exakit_component_current dash-server)"
check "installed -> joins update all" "exakit runtime exapump mcp pyexasol skills dash-server" \
    "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"
check "installed-addons list" "dash-server" "$(exakit_marketplace_installed_addons)"
# With a second add-on registered, one install no longer empties the offer —
# and once every add-on is covered, it does.
check "another add-on keeps the offer pending" "yes" "$(exakit_marketplace_has_pending && echo yes || echo no)"
check "nothing pending once ALL are covered" "no" "$( (
    cover_every_addon
    exakit_marketplace_has_pending && echo yes || echo no
) )"

# Deleting the stub must flip everything back: a stale manifest record alone
# may never count as installed.
rm -rf "$EXAKIT_HOME/dash-server-venv"
echo "a stale record is not an install:"
check "probe fails without the venv" "absent" "$(exakit_component_current dash-server >/dev/null 2>&1 && echo present || echo absent)"
check "excluded from update all again" "exakit runtime exapump mcp pyexasol skills" \
    "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"

echo "EXAKIT_MARKETPLACE_ADDONS (the non-interactive contract):"
# The install functions are stubbed: this proves the routing, not pip.
run_menu() ( # run_menu <env-answer> — echoes "installed:<ids>" + menu output
    _CALLED=""
    # Stubbed FROM THE REGISTRY, not add-on by add-on. The hand-listed version
    # of this block silently let any add-on it had not been told about run its
    # REAL installer: dbt-exasol pip-installed itself from PyPI, into the
    # sandbox home, on every run of this suite - slowly, over the network, and
    # leaving a genuine install behind that later checks then counted as an
    # update target. A loop cannot forget the next add-on.
    for _rm_id in $(exakit_marketplace_addons | cut -d'|' -f1); do
        _rm_fn="$(printf '%s' "$_rm_id" | tr '-' '_')"
        eval "${_rm_fn}_install() { _CALLED=\"\${_CALLED} $_rm_id\"; return 0; }"
        eval "${_rm_fn}_validate() { return 0; }"
    done
    EXAKIT_MARKETPLACE_ADDONS="$1"
    exakit_marketplace_menu >/dev/null 2>&1
    printf 'rc=%s called=%s' "$?" "${_CALLED# }"
)
check "none installs nothing" "rc=0 called=" "$(run_menu none)"
check "naming one addon installs only it" "rc=0 called=dash-server" "$(run_menu dash-server)"
check "all installs every pending addon" "rc=0 called=dash-server dbt-exasol exasol-scheduler exasol-vscode json-tables notebook udf-devkit" "$(run_menu all)"
_unknown_out="$( (run_menu not-a-tool) 2>&1 || true)"
check "an unknown id refuses" "yes" "$( (EXAKIT_MARKETPLACE_ADDONS=not-a-tool exakit_marketplace_menu >/dev/null 2>&1); [ $? -ne 0 ] && echo yes || echo no )"
# An installer that fails must not report success.
check "a failing installer surfaces" "rc=1" "$( (
    dash_server_install() { return 1; }
    dash_server_validate() { return 0; }
    EXAKIT_MARKETPLACE_ADDONS="dash-server"
    exakit_marketplace_menu >/dev/null 2>&1
    printf 'rc=%s' "$?"
) )"

echo "Dash Server launcher and port contracts use the Python add-on tests:"
check "the Python Dash Server contract suite exists" yes "$([ -f "$ROOT/tests/test_marketplace_dash_server.py" ] && echo yes || echo no)"

echo "generic registry (no per-add-on case arms):"
# The whole point of the generic arms: an id the registry does not carry must
# read as "unknown component" everywhere, without any case-statement edit.
check "unregistered id: no block" "no" "$(_exakit_component_block not-a-tool >/dev/null 2>&1 && echo yes || echo no)"
check "unregistered id: no update target" "no" "$(exakit_update_targets not-a-tool >/dev/null 2>&1 && echo yes || echo no)"
check "unregistered id: no fallback" "no" "$(_exakit_component_fallback not-a-tool >/dev/null 2>&1 && echo yes || echo no)"
check "addon env-var name derivation" "EXAKIT_DASH_SERVER_VERSION_FALLBACK" "$(_exakit_addon_env_var dash-server VERSION_FALLBACK)"
# The shared library must stay free of per-add-on case arms: a "dash-server)"
# pattern in common.sh would mean the generic registry regressed to surgery.
check "common.sh carries no dash-server case arm" "0" "$(grep -c 'dash-server)' "$ROOT/setup/lib/common.sh")"

echo "add-on About text (from the add-on's own repository, cached here):"
# The wording lives in exactly ONE place -- the add-on's repository -- because it
# used to live in three (both registries and the help document) and they drifted.
# A description typed back into either registry is the regression to catch.
check "the registry line carries id|label only" "2" \
    "$(exakit_marketplace_addons | head -1 | awk -F'|' '{print NF}')"
lacks "common.sh types no add-on description" "Live dashboards on your Exasol data" \
    "$(cat "$ROOT/setup/lib/common.sh")"
lacks "exakit-common.ps1 types no add-on description" "Live dashboards on your Exasol data" \
    "$(cat "$ROOT/setup/lib/exakit-common.ps1")"

# Which repository to ask is resolved OFFLINE, from the help document the kit
# already ships -- so a cold, network-less machine still knows the answer exists.
check "repo comes from the shipped help doc" "exasol-labs/dash-server" "$(_exakit_addon_repo dash-server)"
check "json-tables points at its own upstream" "exasol-labs/exasol-json-tables" "$(_exakit_addon_repo json-tables)"
check "an add-on with no document has no repo" "no" \
    "$(_exakit_addon_repo not-a-tool >/dev/null 2>&1 && echo yes || echo no)"

# A help document is data and this value is interpolated into a URL, so anything
# that is not owner/name is REFUSED rather than sanitised into something
# plausible-looking.
mkdir -p "$WORK/help-fixtures"
for _bad in "https://evil.example/x" "a/b/c" "../../etc/passwd" "owner/name;id"; do
    check "hostile repo refused: $_bad" "no" "$( (
        EXAKIT_HELP_CACHE_DIR="$WORK/help-fixtures"
        printf '{"schema_version":1,"id":"probe","tagline":"t.","repo":"%s"}\n' "$_bad" \
            > "$WORK/help-fixtures/probe.json"
        _exakit_addon_repo probe >/dev/null 2>&1 && echo yes || echo no ) )"
done

# The About is free-form prose from a repository we do not control, printed
# straight into a terminal. It is filtered on the way IN: escape sequences gone
# whole, control bytes gone, one line, always.
check "sanitiser strips CSI and control bytes" "LiveALERT dash boards second line" \
    "$(printf 'Live\033[1;31mALERT\033[0m dash\tboards\nsecond\rline\a' | _exakit_about_sanitise)"
check "sanitiser removes OSC 8 hyperlinks whole" "see this now" \
    "$(printf 'see \033]8;;http://evil.example\033\\this\033]8;;\033\\ now' | _exakit_about_sanitise)"
check "the length ceiling trims on a word boundary" "one two" \
    "$(EXAKIT_ABOUT_MAX_LEN=9 _exakit_about_cap 'one two three')"

# The About is shown IN FULL: the table folds it, nothing truncates it. A word
# longer than the width overhangs on a line of its own rather than being broken.
check "a line that fits stays on one line" "short" "$(exakit_about_wrap 'short' 44)"
check "a long line folds on word boundaries" "one two|three|four five" \
    "$(exakit_about_wrap 'one two three four five' 9 | tr '\n' '|' | sed 's/|$//')"
check "continuation lines carry their indent" "one two|..three" \
    "$(exakit_about_wrap 'one two three' 8 '..' | tr '\n' '|' | sed 's/|$//')"
check "an over-long word is not broken" "supercalifragilistic|next" \
    "$(exakit_about_wrap 'supercalifragilistic next' 10 | tr '\n' '|' | sed 's/|$//')"
# Nothing may truncate an About any more -- the helper that did is gone.
check "the truncating helper is gone" "no" \
    "$(command -v exakit_about_fit >/dev/null 2>&1 && echo yes || echo no)"

# Offline is this suite's default. With nothing cached the answer is the help
# document's own tagline, minus the trailing period a header carries and a table
# cell does not.
check "offline falls back to the tagline" "SQL editing and schema browsing inside VS Code" \
    "$(exakit_marketplace_addon_description exasol-vscode)"
check "and nothing was cached by that" "no" \
    "$([ -f "$(_exakit_about_cache_path exasol-vscode)" ] && echo yes || echo no)"
# Nothing cached AND no document: still a usable cell, never a blank one.
check "with no About and no document it points at help" "Details: exakit help ghost" \
    "$(exakit_marketplace_addon_description ghost)"

mkdir -p "$EXAKIT_ABOUT_CACHE_DIR"
printf 'Cached About line\n' > "$(_exakit_about_cache_path dash-server)"
check "a fresh cache answers with no lookup" "Cached About line" \
    "$(exakit_marketplace_addon_description dash-server)"

# A stale cache plus an unreachable endpoint: old wording beats an empty column.
# The endpoint is a dead local port, so no test here leaves the machine.
touch -t 200001010000 "$(_exakit_about_cache_path dash-server)"
check "a stale cache survives a failed lookup" "Cached About line" "$( (
    EXAKIT_ABOUT_OFFLINE=0; EXAKIT_ABOUT_URL="https://127.0.0.1:9/repos"
    exakit_marketplace_addon_description dash-server ) )"

# The attempt stamp is written BEFORE the request, so one attempt per id per TTL
# is made whatever the answer -- this is what keeps a rate-limited or offline
# machine from paying a timeout on every single run.
check "a failed lookup is not retried within the TTL" "first=1 second=2" "$( (
    EXAKIT_ABOUT_OFFLINE=0; EXAKIT_ABOUT_URL="https://127.0.0.1:9/repos"
    _exakit_about_fetch exasol-vscode >/dev/null 2>&1; printf 'first=%s ' "$?"
    _exakit_about_fetch exasol-vscode >/dev/null 2>&1; printf 'second=%s' "$?" ) )"
check "a non-HTTPS endpoint is refused outright" "1" "$( (
    EXAKIT_ABOUT_OFFLINE=0; EXAKIT_ABOUT_URL="http://api.github.com/repos"
    _exakit_about_fetch json-tables >/dev/null 2>&1; printf '%s' "$?" ) )"

# A scripted answer installs without drawing a table, so it must resolve NO
# description at all: that is what keeps agent and CI runs off the network.
check "a scripted run resolves no description" "rc=0 looked=0" "$( (
    : > "$WORK/looked"
    exakit_marketplace_addon_description() { printf 'x\n' >> "$WORK/looked"; printf 'x\n'; }
    dash_server_install() { return 0; }
    dash_server_validate() { return 0; }
    EXAKIT_MARKETPLACE_ADDONS="dash-server"
    exakit_marketplace_menu >/dev/null 2>&1
    printf 'rc=%s looked=%s' "$?" "$(wc -l < "$WORK/looked" | tr -d ' ')" ) )"

echo "update repair path:"
# Naming an add-on explicitly must reach its module even when the version
# matches: the hook doubles as the repair command (it rewrites a launcher a
# newer kit improved). `update all` must still skip it — routine updates are a
# work plan, not a sweep of every repair path.
# The hook records into a file: exakit_update's own stdout is noisy, so the
# marker cannot be read off it.
: > "$WORK/hook-marker"
( exakit_component_current() { printf '0.1.0\n'; }
  exakit_component_available() { printf '0.1.0\n'; }
  dash_server_update() { printf 'hook-ran' > "$WORK/hook-marker"; }
  exakit_update dash-server ) >/dev/null 2>&1
check "explicit update reaches the hook when versions match" "hook-ran" "$(cat "$WORK/hook-marker")"
: > "$WORK/hook-marker"
( exakit_component_current() { printf '0.1.0\n'; }
  exakit_component_available() { printf '0.1.0\n'; }
  dash_server_update() { printf 'hook-ran' > "$WORK/hook-marker"; }
  exakit_update all ) >/dev/null 2>&1
check "update all still skips an already-current add-on" "" "$(cat "$WORK/hook-marker")"

echo "a system install outside the kit is respected:"
# A same-named binary on PATH that is not the kit launcher: the tool is
# "present", so nothing advertises it — but the kit does NOT manage it, so it
# never joins the update flow either.
mkdir -p "$WORK/system-bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/system-bin/dash-server"
chmod +x "$WORK/system-bin/dash-server"
_sys_out="$( (
    PATH="$WORK/system-bin:$PATH"
    cover_every_addon                              # cover the other add-ons too
    printf 'present=%s ' "$(_exakit_marketplace_addon_present dash-server && echo yes || echo no)"
    printf 'pending=%s ' "$(exakit_marketplace_has_pending && echo yes || echo no)"
    printf 'kit-managed=%s ' "$(exakit_marketplace_addon_installed dash-server && echo yes || echo no)"
    printf 'update-targets=%s' "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"
) )"
check "system install covers the offer but stays unmanaged" \
    "present=yes pending=no kit-managed=no update-targets=exakit runtime exapump mcp pyexasol skills" "$_sys_out"
check "kit launcher on PATH is NOT a system install" "no" "$( (
    cp "$WORK/system-bin/dash-server" "$EXAKIT_BIN_DIR/dash-server"
    PATH="$EXAKIT_BIN_DIR:$PATH"
    _exakit_addon_system_present dash-server && echo yes || echo no
) )"
rm -f "$EXAKIT_BIN_DIR/dash-server"

echo "the closing offer (post-install):"
# Non-interactive (no TTY): the offer degrades to the one-line hint.
_offer_notty="$( (exakit_marketplace_offer) 2>&1 )"
has "no TTY -> one-line hint, no prompt" "exakit marketplace" "$_offer_notty"
lacks "no TTY -> no yes/no question" "marketplace now" "$_offer_notty"
# A scripted answer installs without asking.
check "EXAKIT_MARKETPLACE_ADDONS pre-answers the offer" "rc=0 called=dash-server" "$( (
    dash_server_install() { _CALLED="dash-server"; return 0; }
    dash_server_validate() { return 0; }
    _CALLED=""
    EXAKIT_MARKETPLACE_ADDONS="dash-server"
    exakit_marketplace_offer >/dev/null 2>&1
    printf 'rc=%s called=%s' "$?" "$_CALLED"
) )"
# Everything already present: the offer disappears entirely — no hint, no ask.
check "nothing pending -> the offer is silent" "" "$( (
    PATH="$WORK/system-bin:$PATH"
    cover_every_addon
    exakit_marketplace_offer 2>&1
) )"
# Soft failures: the hint, never the "done and working" celebration.
_offer_soft="$( (
    EXAKIT_SOFT_FAILED="pyexasol"
    exakit_marketplace_offer 2>&1
) )"
lacks "soft failures -> no victory lap" "done and working" "$_offer_soft"
has "soft failures -> still hints at the marketplace" "exakit marketplace" "$_offer_soft"

echo "module missing from this kit copy (old kit updated over the wire):"
# The env answer names a real add-on whose module file did not ship: the
# refusal must name the fix (update the kit), not call the add-on unknown.
_missing_out="$( (
    unset -f dash_server_install
    EXAKIT_MARKETPLACE_ADDONS="dash-server"
    exakit_marketplace_menu 2>&1
) )"
has "env answer with module missing names the fix" "exakit update" "$_missing_out"
lacks "and does not call the add-on unknown" "Unknown marketplace add-on" "$_missing_out"
# The generic installer path gives the same answer.
has "install-one with module missing names the fix" "exakit update" "$( (
    unset -f dash_server_install
    _exakit_marketplace_install_one dash-server 2>&1
    :
) )"
# The update dispatch refuses cleanly too.
_upd_missing="$( (
    unset -f dash_server_update
    exakit_update_component dash-server 2>&1
) )"
check "update dispatch with module missing refuses" "no" "$(
    ( unset -f dash_server_update; exakit_update_component dash-server ) >/dev/null 2>&1 \
        && echo yes || echo no
)"
has "update dispatch refusal names the module" "dash-server module is not available" "$_upd_missing"

echo "everything covered — the menu becomes a status screen:"
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
printf '#!/bin/sh\necho 0.1.0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
_covered_out="$( (
    cover_every_addon
    exakit_marketplace_menu 2>&1
) )"
has "no selectable rows -> covered list, no menu" "Everything available is already" "$_covered_out"
has "the covered list shows the install" "Installed" "$_covered_out"
lacks "and does not advertise the update command at them" "Update: exakit update" "$_covered_out"
has "a system install reads as covered, not managed" "managed outside the kit" "$_covered_out"
# id|why|version is three fields; reading it into two names left the empty
# version riding inside the second and every covered line ended in "|".
lacks "and the covered line carries no stray field separator" "kit|" "$_covered_out"
rm -rf "$EXAKIT_HOME/dash-server-venv"

echo "the module system-present hook overrides the PATH check:"
check "hook says present -> present (no binary needed)" "yes" "$( (
    dash_server_system_present() { return 0; }
    _exakit_addon_system_present dash-server && echo yes || echo no
) )"
check "hook says absent -> absent (even with a binary on PATH)" "no" "$( (
    dash_server_system_present() { return 1; }
    PATH="$WORK/system-bin:$PATH"
    _exakit_addon_system_present dash-server && echo yes || echo no
) )"

echo "the CLI gate:"
_nomanifest_out="$( (
    _nm_home="$WORK/no-install"
    mkdir -p "$_nm_home/home" "$_nm_home/bin"
    EXAKIT_HOME="$_nm_home/home" EXAKIT_BIN_DIR="$_nm_home/bin" bash "$ROOT/setup/exakit" marketplace 2>&1
    printf 'rc=%s' "$?"
) )"
has "marketplace without an install refuses" "No installation found" "$_nomanifest_out"
has "and exits non-zero" "rc=1" "$_nomanifest_out"

echo "a stdin-draining host CLI must not eat the add-on registry:"
# The editor stub drains stdin. A later registry row must still be visible.
mkdir -p "$WORK/drain-bin"
cat > "$WORK/drain-bin/code" <<'DRAINSTUBEOF'
#!/bin/sh
# Behave like the real thing in the one way that matters here.
cat >/dev/null 2>&1 || true
exit 0
DRAINSTUBEOF
chmod +x "$WORK/drain-bin/code"
# The last registry row is the canary.
_drain_last="$(exakit_marketplace_addons | tail -1 | cut -d'|' -f1)"
_drain_last_fn="$(printf '%s' "$_drain_last" | tr '-' '_')"
check "the canary is registered after exasol-vscode" "yes" \
    "$(exakit_marketplace_addons | cut -d'|' -f1 | sed -n '/^exasol-vscode$/,$p' | grep -qx "$_drain_last" && [ "$_drain_last" != exasol-vscode ] && echo yes || echo no)"
# Keep the comparison outside command substitution for Bash 3.2.
_drain_targets="$( (
    PATH="$WORK/drain-bin:$PATH"
    exakit_version_table_targets 2>/dev/null
) )"
has "version-table targets survive the drain" "$_drain_last" "$_drain_targets"
_drain_installed="$( (
    PATH="$WORK/drain-bin:$PATH"
    # Only the canary is stubbed; the VS Code row must call the draining CLI.
    manifest_set components.exasol_vscode.version "1.7.0" >/dev/null 2>&1
    manifest_set "components.$_drain_last_fn.version" "1.0" >/dev/null 2>&1
    eval "${_drain_last_fn}_installed_version() { printf '1.0\\n'; }"
    exakit_marketplace_installed_addons 2>/dev/null
) )"
has "installed-addon enumeration survives the drain" "$_drain_last" "$_drain_installed"
check "has-pending survives the drain" "yes" "$( (
    PATH="$WORK/drain-bin:$PATH"
    exakit_marketplace_has_pending && printf 'yes\n' || printf 'no\n'
) )"

# ONLY A PRESSED ENTER INSTALLS. The menu pre-selects every add-on so Enter
# alone acts on the offer - and without a real Enter (a dumb terminal, an EOF
# mid-menu, or this suite's faked TTY probe) ui_table_menu returns those same
# defaults as the standing selection. Applying them installed EVERY add-on for
# real: venvs, wheel downloads, a dbt debug - which is also what ate the CI
# job's six-hour budget from inside this very block. The gate is
# EXAKIT_TABLE_CONFIRMED, and this pins both halves: the refusal is said, and
# the apply path is never entered.
check "an unconfirmed menu installs nothing" "refused apply=0" "$( (
    _exakit_prompt_tty() { printf 'stub
'; }
    _exakit_marketplace_apply() { echo "APPLY-CALLED"; }
    _mm_out="$(exakit_marketplace_menu 2>&1)"
    printf '%s' "$_mm_out" | grep -q "nothing was installed" && printf 'refused ' || printf 'confirmed?! '
    printf 'apply=%s' "$(printf '%s' "$_mm_out" | grep -c APPLY-CALLED)"
) )"
# ...and names the scripted route instead of a dead end.
check "the refusal names EXAKIT_MARKETPLACE_ADDONS" "yes" "$( (
    _exakit_prompt_tty() { printf 'stub
'; }
    exakit_marketplace_menu 2>&1 | grep -q EXAKIT_MARKETPLACE_ADDONS && echo yes || echo no
) )"
echo "EVERYTHING behaves as a master toggle (uninstall menu):"
# Layout under test — the shape exakit_uninstall_menu builds:
#   1 Skip · 2 #Components · 3,4 components · 5 #Add-ons · 6 add-on · 7 EVERYTHING
# Rows 2 and 5 are headers: a select-all must skip them, and the all-children
# rule must not wait on them. The primitive is pure, so these are exact.
_UI_CHECKBOX_SELECTABLE="1 3 4 6 7"
_GROUP="7:2:6:all"
sorted() { printf '%s' "$1" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//'; }
# Ticking EVERYTHING ticks every selectable child (never the headers).
check "picking EVERYTHING ticks every row" "3,4,6,7" \
    "$(sorted "$(_ui_checkbox_apply_group "7" 7 "$_GROUP")")"
# Unticking any single child releases EVERYTHING, and leaves the rest ticked.
check "unticking one row releases EVERYTHING" "3,6" \
    "$(sorted "$(_ui_checkbox_apply_group "3,6,7" 4 "$_GROUP")")"
# Ticking the last missing child re-derives EVERYTHING on its own.
check "ticking the last row re-derives EVERYTHING" "3,4,6,7" \
    "$(sorted "$(_ui_checkbox_apply_group "3,4,6" 6 "$_GROUP")")"
# Unticking EVERYTHING clears the whole selection.
check "unticking EVERYTHING clears every row" "" \
    "$(sorted "$(_ui_checkbox_apply_group "3,4,6" 7 "$_GROUP")")"
# A header can never be checked, so it never blocks the all-children rule.
check "headers never count as children" "3,4,6,7" \
    "$(sorted "$(_ui_checkbox_apply_group "3,4,6,7" 4 "$_GROUP")")"
# The default "any" mode is untouched — the data-load menu depends on it.
check "any-mode parent stays checked while one child is" "1,2" \
    "$( _UI_CHECKBOX_SELECTABLE="1 2 3"; sorted "$(_ui_checkbox_apply_group "2" 2 "1:2:3")" )"
_UI_CHECKBOX_SELECTABLE=""

echo "the selectable uninstall (registry-driven, zero wiring per add-on):"
check "the executor dispatches an add-on to its own hook" "hook-ran" "$( (
    exakit_record_ownership dash-server kit
    dash_server_uninstall() { printf 'hook-ran'; }
    _exakit_uninstall_component dash-server 0
) )"
check "an add-on without a hook explains instead of failing" "yes" "$( (
    exakit_record_ownership exasol-vscode kit
    unset -f exasol_vscode_uninstall
    _exakit_uninstall_component exasol-vscode 0 2>&1 | grep -q "update the kit" && echo yes || echo no
) )"
check "an unknown target warns, never dies" "rc=0" "$( (
    _exakit_uninstall_component not-a-thing 0 >/dev/null 2>&1
    printf 'rc=%s' "$?"
) )"
# Partial bookkeeping: removing a piece unmarks its step so a re-run reinstalls.
manifest_set steps_completed '["exapump","pyexasol"]'
exakit_unmark_step exapump
check "a partial removal unmarks the step flag" '["pyexasol"]' "$(manifest_get steps_completed)"
manifest_set components.exapump.version "0.11.3"
manifest_del components.exapump
check "manifest_del clears the whole component block" "absent" "$(manifest_get components.exapump >/dev/null 2>&1 && echo present || echo absent)"

echo "component logs (one command reaches every one of them):"
mkdir -p "$EXAKIT_HOME/logs"
printf 'installer line one\ninstaller line two\n' > "$EXAKIT_HOME/logs/install-20260810-090000.log"
check "the setup log is a target" "setup" "$(exakit_log_targets | cut -d'|' -f1 | grep -x setup)"
# An add-on is viewable as soon as its module names a log — the same
# registry-driven contract the other hooks use.
printf 'dash line\n' > "$EXAKIT_HOME/logs/dash-server.log"
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
printf '#!/bin/sh\necho 0.1.0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
manifest_set components.dash_server.python "$EXAKIT_HOME/dash-server-venv/bin/python"
# The version RECORD too: a real install writes it, and presence now asks
# for it, because a venv whose metadata answers a version is not evidence
# that the install ever finished.
manifest_set components.dash_server.version "0.1.0"
check "an installed add-on with a log hook is a target" "dash-server" \
    "$(exakit_log_targets | cut -d'|' -f1 | grep -x dash-server)"
check "--path prints the file, nothing else" "$EXAKIT_HOME/logs/dash-server.log" \
    "$(exakit_logs_show dash-server 0 200 1)"
has "viewing one tails its content" "dash line" "$(exakit_logs_show dash-server 0 200 0)"
has "the overview lists the targets in a table" "Target" "$(exakit_logs_overview)"
has "and names the add-on" "dash-server" "$(exakit_logs_overview)"
# An unknown name explains itself and lists what exists, rather than dying bare.
_log_unknown="$( (exakit_logs_show not-a-log 0 200 0) 2>&1 || true)"
has "an unknown target lists what is available" "Available:" "$_log_unknown"
check "and it fails rather than printing nothing" "no" "$(
    ( exakit_logs_show not-a-log 0 200 0 ) >/dev/null 2>&1 && echo yes || echo no
)"
# A log the module names but nothing has written yet is a clear message, not a
# confusing empty screen.
has "a not-yet-written log says so" "has not been written yet" "$( (
    dash_server_log_path() { printf '%s\n' "$WORK/never-written.log"; }
    exakit_logs_show dash-server 0 200 0
) 2>&1 || true)"
rm -f "$EXAKIT_HOME/logs/dash-server.log"

# The service registry: database first, then any installed add-on that serves.
manifest_set runtime.type personal
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
printf '#!/bin/sh\necho 0.1.0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
manifest_set components.dash_server.python "$EXAKIT_HOME/dash-server-venv/bin/python"
# The version RECORD too: a real install writes it, and presence now asks
# for it, because a venv whose metadata answers a version is not evidence
# that the install ever finished.
manifest_set components.dash_server.version "0.1.0"
check "the registry lists the database first" "database" \
    "$(exakit_service_ids | head -1)"
check "the registry includes the service add-on" "dash-server" \
    "$(exakit_service_ids | grep -x dash-server)"
# An add-on with no service hooks must not appear as a service.
check "a non-service add-on stays out of the registry" "no" "$(
    exakit_service_ids | grep -q exasol-vscode && echo yes || echo no
)"

# Autostart writes a real boot entry, into a sandbox dir, and takes it away.
EXAKIT_LAUNCHAGENT_DIR="$WORK/agents"
EXAKIT_SYSTEMD_USER_DIR="$WORK/systemd"
mkdir -p "$EXAKIT_LAUNCHAGENT_DIR" "$EXAKIT_SYSTEMD_USER_DIR"
_as_out="$( (
    launchctl() { :; }                     # never touch the real session
    systemctl() { return 1; }
    personal_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exasol"; }
    detect_os() { printf 'macos\n'; }
    exakit_autostart_enable >/dev/null 2>&1
    printf 'flag=%s ' "$(manifest_get autostart.enabled)"
    printf 'db=%s ' "$(_exakit_autostart_registered database && echo yes || echo no)"
    printf 'ds=%s' "$(_exakit_autostart_registered dash-server && echo yes || echo no)"
) )"
check "autostart on registers every service" "flag=true db=yes ds=yes" "$_as_out"
has "the entry runs the real launcher" "$EXAKIT_BIN_DIR/dash-server" \
    "$(cat "$EXAKIT_LAUNCHAGENT_DIR/com.exasol.exakit.dash-server.plist" 2>/dev/null)"
has "and starts at load, so a reboot brings it back" "RunAtLoad" \
    "$(cat "$EXAKIT_LAUNCHAGENT_DIR/com.exasol.exakit.dash-server.plist" 2>/dev/null)"
_as_off="$( (
    launchctl() { :; }
    systemctl() { return 1; }
    detect_os() { printf 'macos\n'; }
    exakit_autostart_disable >/dev/null 2>&1
    printf 'flag=%s entries=%s' "$(manifest_get autostart.enabled)" "$(ls "$EXAKIT_LAUNCHAGENT_DIR" | wc -l | tr -d ' ')"
) )"
check "autostart off removes every entry" "flag=false entries=0" "$_as_off"
# The full uninstall must not leave a boot entry pointing at deleted files.
# Its own kit home: the run removes $EXAKIT_HOME wholesale, and the checks
# after this one still need the suite's sandbox.
_as_sweep="$( (
    EXAKIT_HOME="$WORK/sweep-home"
    EXAKIT_BIN_DIR="$WORK/sweep-bin"
    EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
    EXAKIT_LAUNCHAGENT_DIR="$WORK/sweep-agents"
    mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$EXAKIT_LAUNCHAGENT_DIR"
    launchctl() { :; }
    systemctl() { return 1; }
    detect_os() { printf 'macos\n'; }
    personal_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exasol"; }
    manifest_init >/dev/null 2>&1
    manifest_set runtime.type personal
    exakit_autostart_enable >/dev/null 2>&1
    # "some" not a count: how many services this sandbox happens to expose is
    # not the point — that entries existed and none survived is.
    [ "$(ls "$EXAKIT_LAUNCHAGENT_DIR" | wc -l | tr -d ' ')" -gt 0 ] && printf 'before=some ' || printf 'before=none '
    personal_teardown() { :; }; exakit_mcp_operation() { :; }
    exakit_uninstall_run 0 >/dev/null 2>&1
    printf 'after=%s' "$(ls "$EXAKIT_LAUNCHAGENT_DIR" 2>/dev/null | wc -l | tr -d ' ')"
) )"
check "uninstall sweeps the boot entries too" "before=some after=0" "$_as_sweep"

echo "json-tables (prebuilt engine, no Rust toolchain):"
check "the add-on is registered" "json-tables" \
    "$(exakit_marketplace_addons | cut -d'|' -f1 | grep -x json-tables)"
# The one-liner is what a first-time user reads in the table and the menu, so
# it says what the add-on DOES, in one short clause. It is no longer typed into
# the registry — it comes from the add-on repository's About, and offline (as
# here) from the help document's tagline. The prebuilt-engine fact (no Rust
# toolchain needed) is real but is installation trivia, not a reason to pick it;
# it lives in skills/json-tables/SKILL.md where someone hitting a build question
# will look.
has "its one-liner says what the add-on does" "JSON" \
    "$(exakit_marketplace_addon_description json-tables)"
lacks "and does not mention the Rust toolchain" "Rust" \
    "$(exakit_marketplace_addon_description json-tables)"

# Release pins, platform selection, shim forwarding, and retry behavior are
# exercised against the Python add-on in test_marketplace_json_tables.py.
check "the JSON Tables add-on is implemented in Python" "yes"     "$([ -f "$ROOT/marketplace/addons/json_tables.py" ] && echo yes || echo no)"

echo "manual installs are never re-offered:"
# A tool the user installed themselves is "present": the marketplace must not
# advertise it, and the kit must never manage or remove it. The launcher name
# often differs from the add-on id, so this is keyed on EXAKIT_<ID>_BIN too --
# without that, a manual `pip install exasol-json-tables` would still be
# offered as if it were missing.
mkdir -p "$WORK/manual-bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/manual-bin/exasol-json-tables"
chmod 755 "$WORK/manual-bin/exasol-json-tables"
check "a manually installed add-on reads as present" "present" "$( (
    PATH="$WORK/manual-bin:$PATH"
    _exakit_marketplace_addon_present json-tables && printf 'present\n' || printf 'missing\n'
) )"
check "the menu says so instead of offering an install" "managed outside the kit" "$( (
    PATH="$WORK/manual-bin:$PATH"
    # A faked terminal, or the no-TTY guard answers before the row is drawn.
    _exakit_prompt_tty() { printf 'stub\n'; }
    # The row sits inside a panel now, so strip whatever border precedes it -
    # ASCII here, since a redirected run is always in plain mode - before
    # anchoring on the id.
    exakit_marketplace_menu 2>/dev/null | sed 's/^[^A-Za-z]*//' | grep '^json-tables' | grep -o 'managed outside the kit' | head -1
) )"
check "and it cannot be selected" "not-selectable" "$( (
    PATH="$WORK/manual-bin:$PATH"
    EXAKIT_MARKETPLACE_ADDONS="json-tables"
    exakit_marketplace_menu 2>/dev/null | grep -q '^json-tables$' && printf 'selectable\n' || printf 'not-selectable\n'
) )"
check "with it gone, it is offerable again" "offered" "$( (
    _exakit_addon_offerable json-tables && printf 'offered\n' || printf 'not-offered\n'
) )"
# ...but the kit still must not claim to MANAGE it: a manual copy is not a kit
# install, so update/uninstall leave it alone.
check "a manual copy is never counted as kit-managed" "not-managed" "$( (
    PATH="$WORK/manual-bin:$PATH"
    exakit_marketplace_addon_installed json-tables && printf 'managed\n' || printf 'not-managed\n'
) )"
rm -f "$WORK/manual-bin/exasol-json-tables"

echo "nothing is advertised before it is built:"
# versions.json is the authority on what can be installed: the packaging
# workflow publishes the immutable json-tables-<version> release BEFORE the
# pull request that advertises it can merge (CI checks every pinned digest
# against that release). So "latest" for this add-on is the advertised
# version, answered with no network call -- an upstream tag the kit has not
# packaged is never offered, and a release body is never consulted (reading
# the version off the release while the pins described another build is how
# "Installing JSON Tables v0.3" came to verify a v0.2 digest).
check "the advertised version comes from versions.json, without the network" \
    "$(exakit_versions_value components.json-tables.version)" "$( (
    curl() { printf 'NETWORK\n' >&2; return 7; }
    exakit_component_latest json-tables 2>&1
) )"
echo "data-load's default row when every bundled dataset is in:"
# THE BUG: with nothing left to load from the bundle, the pre-selected row was
# the final "Skip" one -- so Enter did nothing, on the one
# screen whose only remaining purpose is to load a file of your own. The local
# row is what should be waiting under the cursor.
. "$ROOT/setup/lib/exapump.sh"
_dl_probe="$WORK/dl-default-label"
# The data question is one table: with every sample in, the "Sample datasets"
# parent is shown disabled and "Your file or folder" waits under the cursor.
check "with every sample loaded, your own file is the answer Enter gives" "local" \
    "$( (exakit_pending_datasets() { :; }; info() { :; }
        exakit_data_load_select "Skip" >/dev/null 2>&1 </dev/null; printf '%s' "$EXAKIT_DATA_LOAD_SELECTION") )"
(
    exakit_pending_datasets() { :; }          # everything already loaded
    # The defaults are row numbers into the table's state file, so the probe
    # reads the label of whichever row is pre-ticked.
    exakit_data_table_build "$WORK/dl-table" "Skip"
    _dlp_row="${EXAKIT_TABLE_DEFAULTS%%,*}"
    sed -n "${_dlp_row}p" "$WORK/dl-table" | cut -d'|' -f2 > "$_dl_probe"
    EXAKIT_TABLE_STATE="$WORK/dl-table"
    exakit_data_table_release
)
# The expected value is the label VERBATIM, and it moves when the label moves:
# the folder-loading work widened this row to ", or a folder of them" and left
# the assertion behind, which is what turned main red; the one-table data
# question renamed it again. Kept as an equality check rather than loosened to a
# prefix - this is the row the menu pre-selects and the wording is worth pinning.
check "the local-file row is pre-selected" "Upload a file or folder: CSV/Parquet/JSON" "$(cat "$_dl_probe" 2>/dev/null)"
lacks "and Skip is not what Enter would take" "Skip" "$(cat "$_dl_probe" 2>/dev/null)"
# The Windows twin draws the same live table now, so its pre-selection is a ROW
# NUMBER in that table rather than an index into a label array. Same bug to
# guard against: with nothing left in the bundle, the row waiting under the
# cursor must be the local-file one and never the opt-out.
_dl_ps1="$(sed -n '/^function New-ExakitDataTable/,/^}/p' "$ROOT/setup/lib/exapump.ps1")"
has "the PowerShell twin pre-ticks the local-file row" \
    '[void]$defaults.Add($script:ExakitTableRowLocal)' "$_dl_ps1"
# The opt-out is ticked only when NOTHING else is (a persona that wants none of
# what is on offer, or no local-file row to fall back on) - never in place of
# the local-file row. Behaviourally in tests/data-question-ps.ps1.
has "...and the opt-out row only when nothing else is ticked" \
    'if ($defaults.Count -eq 0) { [void]$defaults.Add($script:ExakitTableRowSkip) }' "$_dl_ps1"

echo "data-load routes JSON through the add-on:"
. "$ROOT/setup/lib/exapump.sh"
check "file kinds are classified from the name" "csv parquet json json json csv unknown" "$(
    for _f in a.csv b.parquet c.json d.ndjson e.jsonl.gz f.CSV.gz g.xlsx; do
        printf '%s ' "$(exakit_data_file_kind "$_f")"
    done | sed 's/ $//')"

# Not applicable on this platform: the add-on is not even offered, and the
# reason names the platform rather than leaving the user guessing.
_jl_unsupported="$( (
    exakit_component_current() { return 1; }
    _exakit_addon_applicable() { return 1; }
    exapump_upload() { printf 'UPLOAD-CALLED\n'; }
    exakit_load_local_json "$WORK/sample.json" "STARTER_KIT.SAMPLE" 2>&1
) )"
has "an unsupported platform says so" "not available on this machine" "$_jl_unsupported"
has "and points at what does work" "CSV and Parquet load without it" "$_jl_unsupported"
lacks "and offers no install" "Install it now" "$_jl_unsupported"

# Installed: the file is ingested and the resulting tables are pushed in by
# data-load itself -- the user hands over one JSON file and gets tables.
mkdir -p "$WORK/jt-bin"
cat > "$WORK/jt-bin/exasol-json-tables" <<'JTSTUBEOF'
#!/bin/sh
# stub CLI: writes the Parquet files a real ingest would produce
_out=""
while [ $# -gt 0 ]; do
    case "$1" in --output-dir) _out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$_out"
: > "$_out/orders.parquet"
[ -n "${JT_STUB_TABLES:-}" ] && : > "$_out/order_items.parquet"
exit 0
JTSTUBEOF
chmod 755 "$WORK/jt-bin/exasol-json-tables"
printf '[{"id":1}]\n' > "$WORK/sample.json"

# THE BUG: the ingest engine reads one complete JSON document per LINE, so a
# pretty-printed file - which is what almost every API, export and fixture
# looks like - died on "Line 1: EOF while parsing an object" with nothing to
# tell the reader that whitespace was the whole problem. Re-flowing it changes
# no data, so data-load does it. These assert on the file the engine is handed.
printf '{\n  "meta": {\n    "page": 1\n  },\n  "rows": [\n    {"id": 1}\n  ]\n}\n' > "$WORK/pretty.json"
printf '{"id":1}\n{"id":2}\n' > "$WORK/already.ndjson"
printf 'this is not json {{{\n' > "$WORK/broken.json"

mkdir -p "$WORK/jt-probe"
cat > "$WORK/jt-probe/exasol-json-tables" <<'JTPROBEEOF'
#!/bin/sh
# stub CLI: records the input it was handed, then writes one Parquet file
_in=""; _out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --input) _in="$2"; shift 2 ;;
        --output-dir) _out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
# One document per line is the contract; record how many lines the engine saw
# and whether the first one parses on its own.
printf '%s' "$(wc -l < "$_in" | tr -d ' ')" > "${JT_PROBE_LINES:-/dev/null}"
mkdir -p "$_out"
: > "$_out/rows.parquet"
exit 0
JTPROBEEOF
chmod 755 "$WORK/jt-probe/exasol-json-tables"

_jl_pretty="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-probe/exasol-json-tables"
    JT_PROBE_LINES="$WORK/probe-lines"; export JT_PROBE_LINES
    exakit_component_current() { printf '50d05da0f6da\n'; }
    run_logged() { "$@" >/dev/null 2>&1; }
    info() { :; }; ok() { :; }
    exakit_ensure_schema() { :; }
    exapump_upload() { printf 'UPLOAD:%s ' "$2"; }
    exakit_verify_loaded_table() { :; }
    exakit_load_local_json "$WORK/pretty.json" "STARTER_KIT.PRETTY" 2>&1
) )"
has "a pretty-printed file still loads" "UPLOAD:STARTER_KIT.PRETTY" "$_jl_pretty"
check "and the engine is handed one document per line" "1" "$(cat "$WORK/probe-lines" 2>/dev/null)"

_jl_nd="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-probe/exasol-json-tables"
    JT_PROBE_LINES="$WORK/probe-lines-nd"; export JT_PROBE_LINES
    exakit_component_current() { printf '50d05da0f6da\n'; }
    run_logged() { "$@" >/dev/null 2>&1; }
    info() { :; }; ok() { :; }
    exakit_ensure_schema() { :; }
    exapump_upload() { printf 'UPLOAD:%s ' "$2"; }
    exakit_verify_loaded_table() { :; }
    exakit_load_local_json "$WORK/already.ndjson" "STARTER_KIT.ND" 2>&1
) )"
check "NDJSON is passed through untouched" "2" "$(cat "$WORK/probe-lines-nd" 2>/dev/null)"

_jl_broken="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-probe/exasol-json-tables"
    exakit_component_current() { printf '50d05da0f6da\n'; }
    run_logged() { "$@" >/dev/null 2>&1; }
    exapump_upload() { printf 'UPLOAD-CALLED\n'; }
    exakit_verify_loaded_table() { :; }
    exakit_load_local_json "$WORK/broken.json" "STARTER_KIT.BROKEN" 2>&1
) )"
has "a file that is not JSON says so" "is not valid JSON" "$_jl_broken"
has "and names the shape it wants" "one document per line" "$_jl_broken"
lacks "and uploads nothing" "UPLOAD-CALLED" "$_jl_broken"

# Not installed: the engine installs itself, silently. The user asked for a
# JSON file to be loaded -- the engine that reads one is an implementation
# detail, so nothing is asked and no install or download step is announced.
rm -f "$WORK/install-called"
_jl_silent="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-bin/exasol-json-tables"
    : > "$WORK/ready-calls"
    # not ready on the first look, ready once the install has run
    _exakit_json_tables_ready() {
        printf 'x' >> "$WORK/ready-calls"
        [ "$(wc -c < "$WORK/ready-calls" | tr -d ' ')" -gt 1 ]
    }
    _exakit_json_tables_load_module() { return 0; }
    _exakit_addon_applicable() { return 0; }
    _exakit_marketplace_install_one() { printf '%s' "$1" > "$WORK/install-called"; return 0; }
    prompt_text() { printf 'PROMPTED '; }
    ui_checkbox_menu() { printf 'MENU '; }
    ui_panel_begin() { printf 'PANEL '; }
    run_logged() { "$@" >/dev/null 2>&1; }
    exakit_ensure_schema() { :; }
    exapump_upload() { printf 'UPLOAD:%s ' "$2"; }
    exakit_verify_loaded_table() { :; }
    exakit_load_local_json "$WORK/sample.json" "STARTER_KIT.SAMPLE" 2>&1
) )"
check "a missing engine installs itself" "json-tables" "$(cat "$WORK/install-called" 2>/dev/null)"
lacks "without asking the user anything" "PROMPTED" "$_jl_silent"
lacks "and without a checkbox" "MENU" "$_jl_silent"
lacks "and without an explanation panel" "PANEL" "$_jl_silent"
lacks "and without narrating the install" "Installing" "$_jl_silent"
has "and the data still lands" "UPLOAD:STARTER_KIT.SAMPLE" "$_jl_silent"

_jl_one="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-bin/exasol-json-tables"
    exakit_component_current() { printf '50d05da0f6da\n'; }
    run_logged() { "$@" >/dev/null 2>&1; }
    info() { :; }; ok() { :; }
    exakit_ensure_schema() { printf 'SCHEMA:%s ' "$1"; }
    exapump_upload() { printf 'UPLOAD:%s->%s ' "${1##*/}" "$2"; }
    exakit_verify_loaded_table() { printf 'VERIFY:%s' "$1"; }
    exakit_load_local_json "$WORK/sample.json" "STARTER_KIT.SAMPLE" 2>/dev/null
) )"
check "one table: ingested, then loaded and verified" \
    "SCHEMA:STARTER_KIT UPLOAD:orders.parquet->STARTER_KIT.SAMPLE VERIFY:STARTER_KIT.SAMPLE" "$_jl_one"

# Nested JSON legitimately produces several tables: all of them must land, not
# just the first one.
_jl_many="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-bin/exasol-json-tables"
    JT_STUB_TABLES=1; export JT_STUB_TABLES
    exakit_component_current() { printf '50d05da0f6da\n'; }
    run_logged() { "$@" >/dev/null 2>&1; }
    info() { :; }; ok() { :; }
    exakit_ensure_schema() { printf 'SCHEMA:%s ' "$1"; }
    exapump_upload() { printf 'UPLOAD:%s ' "$2"; }
    exakit_verify_loaded_table() { :; }
    exakit_load_local_json "$WORK/sample.json" "JSONDATA.SAMPLE" 2>/dev/null
) )"
check "every table from a nested document lands, under the name you gave" \
    "SCHEMA:JSONDATA UPLOAD:JSONDATA.SAMPLE_ORDER_ITEMS UPLOAD:JSONDATA.SAMPLE_ORDERS" \
    "$(printf '%s' "$_jl_many" | sed 's/ *$//')"

# A failed ingest must leave the database alone and name the log.
_jl_failed="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-bin/exasol-json-tables"
    exakit_component_current() { printf '50d05da0f6da\n'; }
    run_logged() { return 1; }
    exapump_upload() { printf 'UPLOAD-CALLED\n'; }
    exakit_load_local_json "$WORK/sample.json" "STARTER_KIT.SAMPLE" 2>&1
    printf 'rc=%s' "$?"
) )"
has "a failed ingest names the log" "exakit logs json-tables" "$_jl_failed"
has "and says the database is unchanged" "database is unchanged" "$_jl_failed"
lacks "and uploads nothing" "UPLOAD-CALLED" "$_jl_failed"

# The CSV path must be completely untouched by all of this.
check "a CSV still never mentions the add-on" "csv" "$(exakit_data_file_kind "$WORK/x.csv")"

echo "discovery one-liners:"
# The dim "Optional add-ons are available (...)" footer is gone. It sat under the
# table repeating a command the table's own rows already carry, so an add-on is
# discovered where it is listed: `exakit version` gives every offerable add-on a
# row, and an uninstalled one reads `exakit marketplace` in its Status cell.
check "the version table lists exactly the add-ons still pending" "$( (
    exakit_marketplace_addons | cut -d'|' -f1 | while read -r _dl_id; do
        [ -n "$_dl_id" ] || continue
        _exakit_addon_offerable "$_dl_id" || continue
        _exakit_marketplace_addon_present "$_dl_id" || printf '%s\n' "$_dl_id"
    done | sort | paste -sd, -
) )" "$( (
    exakit_version_table_targets | while read -r _vt_id; do
        [ -n "$_vt_id" ] || continue
        _exakit_addon_registered "$_vt_id" || continue
        exakit_marketplace_addon_installed "$_vt_id" && continue
        printf '%s\n' "$_vt_id"
    done | sort | paste -sd, -
) )"
has "connection panel advertises the marketplace" "exakit marketplace" "$(connection_panel 2>/dev/null)"

echo "the selection and the install progress are ONE table:"
# The add-on selection is made in the live table (ui_table_* in ui.sh), the same
# component the dataset load uses, and the Status column of those very rows is
# what the install then fills in. Before this the two were separate screens: a
# checkbox menu that scrolled away, then one progress line per add-on printed
# underneath it, so the reader had to map one onto the other.
COMMON_SH_ADDONS="$(cat "$ROOT/setup/lib/common.sh")"
has "the selection IS the table"        'ui_table_menu "$EXAKIT_ADDON_TABLE_STATE"' "$COMMON_SH_ADDONS"
has "...titled for add-ons"            'UI_TABLE_TITLE="Marketplace add-ons"'      "$COMMON_SH_ADDONS"
has "...with a Version column"          'UI_TABLE_COL2="Version"'                    "$COMMON_SH_ADDONS"
has "...and a Description column"       'UI_TABLE_COL3="Description"'                "$COMMON_SH_ADDONS"
lacks "and not a checkbox any more"    'ui_checkbox_menu "Select add-ons to install"' "$COMMON_SH_ADDONS"
has "the install starts the same table" 'ui_table_begin "$EXAKIT_ADDON_TABLE_STATE"' "$COMMON_SH_ADDONS"
has "...and stops it"                   'ui_table_end "$EXAKIT_ADDON_TABLE_STATE"'   "$COMMON_SH_ADDONS"
# The state PANEL above the selection is gone: it listed every add-on with a
# version and a description, and then the selection under it repeated every
# installable one by name -- the same list twice, a box apart. Its two columns
# moved into the selection, and the add-ons it alone could show (installed,
# already on the system, missing from this kit copy) come back as dim,
# unpickable rows in that same table.
lacks "the state panel is gone"         'ui_panel_begin "Marketplace add-ons"'       "$COMMON_SH_ADDONS"
has "...its columns moved into the table" 'UI_TABLE_COL3="Description"'              "$COMMON_SH_ADDONS"
has "...and its other rows became disabled ones" '0|disabled|||||%s|%s|%s|%s' "$COMMON_SH_ADDONS"
# The row builder must do NO lookups of its own. Resolving the version and the
# About inside it put a version probe and a network fetch behind every caller --
# including the pty scenario that drives this table with three ids that are not
# add-ons at all. The caller iterating the add-ons already has both values and
# hands them over in EXAKIT_ADDON_TABLE_META.
BUILDER_SRC="$(sed -n '/^_exakit_addon_table_build()/,/^}/p' "$ROOT/setup/lib/common.sh")"
lacks "the row builder fetches no About"     "exakit_marketplace_addon_description" "$BUILDER_SRC"
lacks "...and probes no version"             "exakit_component_available"           "$BUILDER_SRC"
has   "it is handed them instead"            'EXAKIT_ADDON_TABLE_META'              "$BUILDER_SRC"
# ...and the caller resolves them only when a table will actually draw them.
has "the caller skips the lookup for a scripted answer" \
    'if [ -z "${EXAKIT_MARKETPLACE_ADDONS:-}" ]; then' "$COMMON_SH_ADDONS"

# The rows: a group, one per installable add-on on a tree connector, then Skip.
ADDON_STATE_FILE="$WORK/addon-table"
_exakit_addon_table_build "$ADDON_STATE_FILE" demo-alpha demo-beta demo-gamma
check "row kinds are group, tree, tree, corner, plain" "group tee tee corner plain" \
    "$(cut -d'|' -f1 "$ADDON_STATE_FILE" | paste -sd' ' - | sed 's/ *$//')"
check "row labels name the add-ons between the group and Skip" \
    "Select All demo-alpha demo-beta demo-gamma Skip" \
    "$(cut -d'|' -f2 "$ADDON_STATE_FILE" | paste -sd' ' - | sed 's/ *$//')"
check "the group and every add-on are pre-ticked" "1,2,3,4" "$EXAKIT_TABLE_DEFAULTS"
check "the group is a MASTER toggle over its children" "1:2:4:all" "$EXAKIT_TABLE_GROUP"
check "Skip is the exclusive opt-out, and it is the last row" "5 5" \
    "$EXAKIT_TABLE_EXCLUSIVE $EXAKIT_ADDON_TABLE_ROW_SKIP"
check "an add-on finds its own row again" "2 3 4" \
    "$(_exakit_addon_table_row demo-alpha) $(_exakit_addon_table_row demo-beta) $(_exakit_addon_table_row demo-gamma)"
check "and a row that is not an add-on is nobody's" "0" "$(_exakit_addon_table_row Skip)"
# THE BUG this guards: _UI_CHECKBOX_SELECTABLE is published by ui_checkbox_menu
# and never cleared, and ui_table_menu does not publish it. The closing offer
# asks its two-row "Explore ?" question first, so "1 2" was still standing when
# the table's group helpers ran -- and Select All then toggled row 2 and nothing
# else, on the row a user glances at to confirm what is about to be installed.
check "the build clears the checkbox layer's stale selectable rows" "" \
    "$( _UI_CHECKBOX_SELECTABLE="1 2"
        _exakit_addon_table_build "$WORK/addon-table2" demo-alpha demo-beta >/dev/null
        printf '%s' "$_UI_CHECKBOX_SELECTABLE" )"

# The Status column of a finished row: the add-on's own one-line summary, sized
# to the column. A final wider than the column makes ui_table_frame's padding
# arithmetic go negative -- a bash substring error printed over the table, not a
# wider column -- so the cell gives way, and the full text stays in the logfile.
# Measured against the FANCY tick, because that is the only tick this cell is
# ever drawn with: a finished cell exists only while the table is live, and the
# table animates only on a fancy terminal. A redirected test run is plain, where
# UI_TICK is the four-character "[ok]" and the room is three characters tighter.
ADDON_CELL_SHORT="$( UI_TICK="✓"; _exakit_addon_table_cell 'dashboards at http://127.0.0.1:8000' 4 )"
ADDON_CELL_LONG="$( UI_TICK="✓"; _exakit_addon_table_cell 'load JSON with: exasol-json-tables ingest --input <file.json>' 12 )"
has "a summary that fits is carried whole" "dashboards at http://127.0.0.1:8000" "$ADDON_CELL_SHORT"
has "...with its elapsed time" "(4s)" "$ADDON_CELL_SHORT"
has "one too long for the column is cut, not left to overflow" "…" "$ADDON_CELL_LONG"
check "every finished cell is the same width, so the times line up" "same" \
    "$([ "${#ADDON_CELL_SHORT}" = "${#ADDON_CELL_LONG}" ] && echo same || \
       echo "${#ADDON_CELL_SHORT} vs ${#ADDON_CELL_LONG}")"
check "and it never widens the column past its floor" "fits" \
    "$([ "$(( ${#ADDON_CELL_LONG} + 2 ))" -le "${UI_TABLE_STAT_MIN:-44}" ] && echo fits || \
       echo "${#ADDON_CELL_LONG} > $(( ${UI_TABLE_STAT_MIN:-44} - 2 ))")"
check "a summary-less add-on still says what happened" "installed" \
    "$(_exakit_addon_table_cell '' 2 | sed 's/ *(.*//')"
check "and it fits the plain palette's wider tick too" "fits" \
    "$( UI_TICK="[ok]"
        _cell="$(_exakit_addon_table_cell 'load JSON with: exasol-json-tables ingest --input <file.json>' 12)"
        [ "$(( ${#_cell} + 5 ))" -le "${UI_TABLE_STAT_MIN:-44}" ] && echo fits || echo "${#_cell}" )"

# The non-interactive contract is untouched: a scripted answer builds no table
# at all, so every add-on narrates in the plain lines it always did.
_addon_scripted="$( (
    EXAKIT_ADDON_TABLE_STATE=""
    # Nothing about THIS machine may decide the answer: the sections above leave
    # records behind, and an add-on that reads as already installed makes the env
    # path return before it ever installs anything.
    exakit_marketplace_addon_installed() { return 1; }
    _exakit_addon_system_present() { return 1; }
    _exakit_addon_applicable() { return 0; }
    _exakit_marketplace_install_one() { return 0; }
    dash_server_summary() { printf 'dashboards at http://127.0.0.1:8000\n'; }
    EXAKIT_MARKETPLACE_ADDONS="dash-server" exakit_marketplace_menu 2>&1
    printf 'table=[%s]' "$EXAKIT_ADDON_TABLE_STATE"
) )"
has "a scripted answer still announces each install" "Installing add-on: dash-server" "$_addon_scripted"
has "...and still says what it got" "dash-server installed — dashboards at" "$_addon_scripted"
check "and builds no table to do it" "table=[]" \
    "$(printf '%s' "$_addon_scripted" | grep -o 'table=\[[^]]*\]')"

printf '\n== under a REAL terminal, one add-ons table is left, not four ==\n'

# Everything above reads a state file or a captured string, and neither can see
# the bug this component has shipped twice: the table STACKED. tty-replay.py runs
# the scenario under a pty and replays the escape codes the way a terminal would
# -- cursor-up, clear-to-end, carriage return -- then asserts what is left on
# screen. The static state panel is printed above the live table on purpose: a
# frame that miscounts its own height eats the panel instead of its own last
# frame, which is why the replay is told to expect TWO boxes and exactly one of
# them titled for the selection.
if command -v python3 >/dev/null 2>&1; then
    if python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/addon-table-scenario.sh" "$ROOT" \
            "Add-ons to install" '' 2 > "$WORK/addon-tty.out" 2>&1; then
        check "exactly one add-ons table survives" "yes" "yes"
    else
        check "exactly one add-ons table survives" "yes" \
            "no: $(grep 'tables on screen' "$WORK/addon-tty.out" || echo 'replay failed')"
    fi
    ADDON_SCREEN="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/addon-tty.out")"
    has "and the shell announced no dying job" "job announcements: 0" \
        "$(cat "$WORK/addon-tty.out")"
    has "the state table is still above it" "Marketplace add-ons" "$ADDON_SCREEN"
    has "the finished row carries the add-on's own summary" \
        "dashboards at http://127.0.0.1:8000" "$ADDON_SCREEN"
    has "a failed row says so in the same column" "did not finish" "$ADDON_SCREEN"
    # The bar's own empty-track glyph: no row is still mid-install.
    lacks "no half-drawn bar left behind" "░" "$ADDON_SCREEN"
    # The per-add-on lines are what the table replaced; they went to the logfile.
    lacks "no per-add-on progress line under the table" "Installing add-on" "$ADDON_SCREEN"
    # A warn printed into a frame that is still being repainted lands INSIDE the
    # box, so the failure waits for the table to stop and is said below it.
    lacks "the failure is said below the table, not inside the frame" "│" \
        "$(printf '%s\n' "$ADDON_SCREEN" | grep 'did not finish installing' | head -1)"
else
    check "exactly one add-ons table survives" "skipped" "skipped"
fi

echo "a refused lookup is not a missing release:"
# On a real install json-tables failed with "the prebuilt mirror release was not
# found ... run the pkg workflow once to publish it". That release had existed
# since August and held the exact asset that machine needed. GitHub had answered
# 403: its API allows 60 calls an hour unauthenticated, and a full install spends
# them. `curl -f` turns any 4xx into an empty body, so a refusal and an absence
# were indistinguishable, and the remedy named was work that changes nothing.
JT_PY="$(cat "$ROOT/marketplace/addons/json_tables.py")"
has "the release lookup accepts a GitHub token" 'GITHUB_TOKEN' "$JT_PY"
has "a refused lookup names the retry" 'retry later or set GITHUB_TOKEN' "$JT_PY"
has "a missing release names its workflow" 'pkg / json-tables' "$JT_PY"
CO_SH="$(cat "$ROOT/setup/lib/common.sh")"
# The failure is said ONCE: the row says it, the module's own reason said why,
# and the note under the table is gone. Asserted on what replaced it, not on the
# wording that was removed -- that wording had already been changed once by
# another hand, so a needle aimed at it tests nothing.
has "the add-on failure is only logged"  '_exakit_log_file "WARN  $_mp_id did not finish installing"' "$CO_SH"
lacks "no note is printed under the frame" '_exakit_addon_note warn \\' "$CO_SH"

printf '\n== a marketplace --json row always carries version ==\n'
# AGENTS.md and the help promise version on every row; a row for an add-on
# with no known version used to drop the key, so a parser had to probe for it.
has   "the shell row carries version null when unknown"   '"version": null' "$(cat "$ROOT/setup/lib/common.sh")"
has   "the Windows row carries version null when unknown" '$entry.version = $null' "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has   "AGENTS.md says which keys are null when unknown"   '`version`, `repo` and `docs` are `null` when unknown' "$(cat "$ROOT/AGENTS.md")"

printf '\n== a failing add-on is readable, not spliced through the table ==\n'

# A json-tables download failure arrived on a real machine as
#   | [v] exasol-vscode  ok Exasol view in VS Code's sidebar (3s) |eleases/download/...
#   | [ ] Skip                                                    |ownloaded or verified (see log)
# - the reason written straight through the frame of the live add-on table and
# effectively unreadable. warn and error are the two printers the quiet flag
# deliberately does NOT gate, which is exactly why they are the two that reach
# it, and every add-on module calls them directly rather than the deferring
# helper. So they defer themselves.
COMMON_D="$(cat "$ROOT/setup/lib/common.sh")"
COMMON_PS_D="$(cat "$ROOT/setup/lib/exakit-common.ps1")"

has   "the shell defers under a table"  "_exakit_defer_under_addon_table" "$COMMON_D"
check "...from both printers"           "2" \
    "$(printf '%s\n' "$COMMON_D" | grep -c 'if _exakit_defer_under_addon_table')"
has   "Warn2 defers too"                'if (Test-ExakitAddonNarrationLive) {' "$COMMON_PS_D"

# THE FALLBACK BAR WAS NOT A TABLE, AND THAT WAS THE WHOLE BUG. Where the table
# cannot be drawn the narration falls back to a one-line progress bar, which
# owns its line the way the table owns its frame - but only the table counted,
# so on that path a warning printed the instant it happened, beside a bar still
# being redrawn. It ran off the right edge, wrapped, and pushed the bar down:
# one add-on's single bar arrived on screen as three broken rows with
# half-sentences bleeding between them. Both halves now defer for either.
has   "the shell knows the bar owns the screen too" \
    "_exakit_addon_narration_live" "$COMMON_D"
has   "...and raises the flag around the fallback bar" \
    "EXAKIT_ADDON_BAR_LIVE=1" "$COMMON_D"
check "...and lowers it again wherever that bar ends" "2" \
    "$(printf '%s\n' "$COMMON_D" | grep -c 'EXAKIT_ADDON_BAR_LIVE=0')"
has   "the deferral gate asks the shared question" \
    "_exakit_addon_narration_live || return 1" "$COMMON_D"
has   "the twin has the same predicate" \
    'return ($script:ExakitAddonTableLive -or $script:ExakitAddonBarLive)' "$COMMON_PS_D"
has   "...raised around its fallback bar" \
    '$script:ExakitAddonBarLive = $true' "$COMMON_PS_D"
check "...and lowered on both ends of the loop and in the Python adapter" "3" \
    "$(printf '%s\n' "$COMMON_PS_D" | grep -cE '^ +\$script:ExakitAddonBarLive = \$false$')"
# Warn2, Write-ExakitError and Write-ExakitAddonNote: every printer that can
# land on the bar's line, not just the one that always knew about the table.
check "all three printers ask the shared question" "3" \
    "$(printf '%s\n' "$COMMON_PS_D" | grep -c 'if (Test-ExakitAddonNarrationLive) {')"
has   "the shell's table predicate says table, not bar" \
    "_exakit_addon_table_live() {" "$COMMON_D"
check "...and so does the error printer" "2" \
    "$(printf '%s\n' "$COMMON_PS_D" | grep -c 'Kind = "warn"; Text = $Msg')"
# The log still gets every line: deferring must never mean losing.
check "the shell still logs both"       "2" \
    "$(printf '%s\n' "$COMMON_D" | grep -cE 'if _exakit_defer_under_addon_table .*_exakit_log_file')"

echo
echo "without a terminal, browsing never installs:"
# THE REGRESSION THIS PINS: with no TTY and no env answer, the pre-ticked menu
# rows used to stand as the answer, so `exakit marketplace` - the command every
# doc calls "browse" - performed a full install with a live daemon, triggered
# by agents that were told to look, not to install. Skip is the no-TTY answer.
_mm_notty="$( (
    _exakit_prompt_tty() { :; }                  # no terminal anywhere
    _exakit_marketplace_apply() { printf 'INSTALLED %s\n' "$1"; }
    # Offline: the interactive path resolves descriptions before the guard.
    exakit_marketplace_addon_description() { printf 'stub\n'; }
    exakit_marketplace_menu 2>&1
) )"
has  "no TTY answers Skip out loud" "nothing was installed" "$_mm_notty"
lacks "and nothing is installed"    "INSTALLED"             "$_mm_notty"
has  "the read-only surface is named"  "marketplace --list" "$_mm_notty"
# The env answer still installs without a TTY - that is the explicit consent.
_mm_env="$( (
    _exakit_prompt_tty() { :; }
    _exakit_marketplace_apply() { printf 'INSTALLED %s\n' "$1"; }
    EXAKIT_MARKETPLACE_ADDONS=json-tables exakit_marketplace_menu 2>&1
) )"
has "an explicit env answer still installs" "INSTALLED json-tables" "$_mm_env"

echo
echo "the read-only list surface:"
_mm_list="$(cover_every_addon; exakit_marketplace_list 0 2>&1)"
has "every add-on has a row" "json-tables" "$_mm_list"
has "...dash-server too"     "dash-server" "$_mm_list"
_mm_listjson="$(cover_every_addon; exakit_marketplace_list 1 2>/dev/null)"
check "the JSON form is valid JSON" "yes" \
    "$(printf '%s' "$_mm_listjson" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
has "and carries a status per add-on" '"status": ' "$_mm_listjson"
has "and an installed boolean"        '"installed": ' "$_mm_listjson"
# THE LISTING POINTS AT THE REFERENCE. A row was id/status/installed/version:
# a list of names and numbers, with the help document that explains each
# add-on (repository, docs link, what it installs) reachable only by knowing
# `exakit help <id>` exists - and nothing said so. Every row now carries the
# repository and the documentation URL from its help document, and both
# surfaces name the help command.
has "every JSON row names its repository"     '"repo": "exasol-labs/dash-server"' "$_mm_listjson"
has "...and its documentation link"          '"docs": "https://github.com/exasol-labs/dash-server#readme"' "$_mm_listjson"
check "no row is left without the two keys" "0" \
    "$(printf '%s' "$_mm_listjson" | python3 -c 'import json,sys
rows = json.load(sys.stdin)["addons"]
print(sum(1 for r in rows if "repo" not in r or "docs" not in r))' 2>/dev/null)"
check "and the links are null or https" "0" \
    "$(printf '%s' "$_mm_listjson" | python3 -c 'import json,sys
rows = json.load(sys.stdin)["addons"]
print(sum(1 for r in rows if r["docs"] is not None and not str(r["docs"]).startswith("https://")))' 2>/dev/null)"
has "the plain list names the help command"  "exakit help <id>" "$_mm_list"
has "...and so does the interactive menu"    'info "Details on any add-on: exakit help <id>"' "$(cat "$ROOT/setup/lib/common.sh")"
# The data the row reads: every help document carries a docs link, so no
# add-on answers null on a machine with the kit copy on it.
_mm_docs_missing="$(python3 -c 'import json,glob,os
missing = []
for path in sorted(glob.glob("'"$ROOT"'/setup/help/*.json")):
    doc = json.load(open(path, encoding="utf-8"))
    docs = doc.get("docs")
    if not (isinstance(docs, str) and docs.startswith("https://")):
        missing.append(os.path.basename(path))
print(" ".join(missing))' 2>/dev/null)"
check "every help document carries an https docs link" "" "$_mm_docs_missing"
has "the Windows row carries the repository"   '$entry.repo = $repo' "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "...and the documentation link"            '$entry.docs = $docs' "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "...and the Windows list names the help command" 'Details on any add-on: exakit help <id>' "$(cat "$ROOT/setup/lib/exakit-common.ps1")"

echo
echo "the latest policy names the add-ons it never looks up (upstream #27):"
# EXAKIT_VERSION_POLICY=latest printed "Available versions come from live
# upstream lookups" and then "exasol-scheduler is already current (v0.2)"
# while upstream had shipped v0.3.1. The scheduler's and json-tables' "latest"
# IS the versions.json pin by design - only a build the pkg workflow has
# published and fingerprinted is installable - but nothing on screen said so,
# and the reporter's suggested fix (a repo field) would never have been read:
# exakit_component_latest asks the <id>_latest hook first.
check "json-tables' latest is pinned"          "pinned"   "$(exakit_component_latest_source json-tables)"
# The scheduler was the second pinned add-on until it moved to upstream's own
# release (below); its "latest" is a live lookup now, like exapump's.
check "the scheduler's latest is looked up"    "upstream" "$(exakit_component_latest_source exasol-scheduler)"
check "dash-server's latest is looked up"      "upstream" "$(exakit_component_latest_source dash-server)"
check "a kit component's latest is looked up"  "upstream" "$(exakit_component_latest_source exapump)"
check "the pinned set is exactly json-tables and udf-devkit (the kit's own versions)" "json-tables udf-devkit" \
    "$(exakit_pinned_addons | tr '\n' ' ' | sed 's/ $//')"
_pin_line="$(EXAKIT_VERSION_POLICY=latest exakit_print_versions_source_line 2>&1)"
has   "the latest-policy source line still says where lookups go" "live upstream lookups" "$_pin_line"
has   "...and names json-tables as pinned on its own line"        "Pinned by this kit, not looked up upstream: json-tables" "$_pin_line"
lacks "...but not dash-server, which really is looked up"         "dash-server"          "$_pin_line"
lacks "...nor the scheduler, which is looked up too"              "exasol-scheduler"     "$_pin_line"
# The "already current" line is the other half: under the latest policy a
# pinned add-on says the version is the kit's pin; under the manifest policy
# (the default) the wording is untouched.
has   "a pinned add-on's already-current line is qualified under latest" "the build this kit pins" \
    "$(EXAKIT_VERSION_POLICY=latest exakit_pinned_latest_note json-tables)"
check "...and says nothing under the manifest policy"   "" "$(EXAKIT_VERSION_POLICY=manifest exakit_pinned_latest_note json-tables)"
check "...or for an add-on that is looked up upstream"  "" "$(EXAKIT_VERSION_POLICY=latest exakit_pinned_latest_note dash-server)"
check "...the scheduler included"                       "" "$(EXAKIT_VERSION_POLICY=latest exakit_pinned_latest_note exasol-scheduler)"
has "...and MARKETPLACE.md says the same"            'exakit_component_latest_source' "$(cat "$ROOT/MARKETPLACE.md")"
_pin_ps_common="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "the Windows registry answers the same source question" 'function Get-ExakitComponentLatestSource' "$_pin_ps_common"
has "...with the same note"                                 'function Get-ExakitPinnedLatestNote'      "$_pin_ps_common"
has "the Windows source line names the pinned add-ons"      'Write-ExakitPinnedLine'                    "$(cat "$ROOT/setup/exakit.ps1")"

echo
echo "exasol-scheduler release metadata:"
check "versions.json names the upstream repo" "exasol-labs/exasol-scheduler" \
    "$(python3 -c 'import json; print(json.load(open("'"$ROOT"'/versions.json"))["components"]["exasol-scheduler"].get("repo", ""))')"
check "the old packaging workflow is gone" "absent" "$([ -f "$ROOT/.github/workflows/pkg-exasol-scheduler.yml" ] && echo PRESENT || echo absent)"
has "the bump workflow proposes scheduler digests" 'bumped["exasol-scheduler"]' "$(cat "$ROOT/.github/workflows/versions-bump.yml")"
has "CI checks upstream archives" 'exasol_scheduler-v${version}-${platform}.tar.gz' "$(cat "$ROOT/.github/workflows/versions.yml")"

echo "the Windows registry dispatches the same per-add-on hooks as the shell:"
# THE PARITY GAP THIS PINS: the PS registry had no field for the per-add-on
# hooks the shell registry dispatches to. The add-on detectors were dead code,
# and exasol-vscode had no
# Windows detector at all (the kit adopted and later DELETED a user's own
# Marketplace extension), "never offered twice" held on three platforms and
# failed on Windows, and "latest" was always empty there so the update check
# could not see either binary add-on.
COMMON_PS_TP="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
_python_hooks="$(python3 "$ROOT/marketplace/metadata.py" "$ROOT" shell-hooks)"
has "the registry declares json-tables' detector"   'json-tables|system_present|system-present' "$_python_hooks"
has "...and the scheduler's"                        'exasol-scheduler|system_present|system-present' "$_python_hooks"
has "...and the VS Code extension's"                'exasol-vscode|system_present|system-present' "$_python_hooks"
has "the Python detector exists for VS Code"         'def system_present(' "$(cat "$ROOT/marketplace/addons/exasol_vscode.py")"
has "the present probe dispatches the hook first"   '$addon.SystemPresentFn' "$COMMON_PS_TP"
has "the registry declares json-tables' latest"     'json-tables|latest|latest' "$_python_hooks"
lacks "...but not the scheduler's, which is looked up upstream" 'LatestFn     = "Get-ExasolSchedulerLatest"' "$COMMON_PS_TP"
has "the latest lookup dispatches the hook first"   '$addon.LatestFn' "$COMMON_PS_TP"
# ADD-11: the code CLI drains inherited stdin, which ate the marketplace's own
# row loop and silently dropped every add-on listed after exasol-vscode. The
# shell half closes stdin (</dev/null); the Windows half must redirect it too -
# code.cmd is a batch wrapper around the same Node process. CI never catches
# this: a runner has no VS Code, so the CLI is never run.
has "the code CLI cannot drain stdin" \
    'stdin=subprocess.DEVNULL' "$(cat "$ROOT/marketplace/addons/exasol_vscode.py")"

echo "a scripted add-on that does not run here is skipped, the rest install:"
# A persona's add-on list is written for every platform. One id it names that
# does not apply here used to end the env answer (die) before anything was
# installed. Unknown ids still refuse - that is bad input, checked above.
_mm_partial="$( (
    _exakit_marketplace_apply() { printf 'INSTALLED %s\n' "$1"; }
    exakit_marketplace_addon_installed() { return 1; }
    _exakit_addon_system_present() { return 1; }
    _exakit_marketplace_addon_present() { return 1; }
    _exakit_addon_applicable() { [ "$1" != dash-server ]; }
    _exakit_addon_applicable_reason() { printf 'not on this platform (test)'; }
    EXAKIT_MARKETPLACE_ADDONS=dash-server,json-tables exakit_marketplace_menu 2>&1
    printf 'rc=%s\n' "$?"
) )"
has  "the rest are installed"              "INSTALLED json-tables" "$_mm_partial"
lacks "the inapplicable one is not"        "INSTALLED dash-server" "$_mm_partial"
has  "it is named, with the reason"        "Skipping dash-server" "$_mm_partial"
has  "...the reason itself"                "not on this platform (test)" "$_mm_partial"
has  "and the answer succeeds"             "rc=0" "$_mm_partial"
_mm_none_here="$( (
    _exakit_marketplace_apply() { printf 'INSTALLED %s\n' "$1"; }
    exakit_marketplace_addon_installed() { return 1; }
    _exakit_addon_system_present() { return 1; }
    _exakit_marketplace_addon_present() { return 1; }
    _exakit_addon_applicable() { return 1; }
    _exakit_addon_applicable_reason() { :; }
    EXAKIT_MARKETPLACE_ADDONS=dash-server exakit_marketplace_menu 2>&1
    printf 'rc=%s\n' "$?"
) )"
lacks "nothing applicable: nothing installs"    "INSTALLED" "$_mm_none_here"
has  "...it says so, not 'already present'"     "Nothing to install on this machine" "$_mm_none_here"
has  "...and it is not an error"                "rc=0" "$_mm_none_here"
check "an unknown id among them still refuses" "yes" "$( (
    _exakit_marketplace_apply() { :; }
    EXAKIT_MARKETPLACE_ADDONS=json-tables,not-a-tool exakit_marketplace_menu >/dev/null 2>&1
    ); [ $? -ne 0 ] && echo yes || echo no )"

echo
echo "a persona whose add-ons are all gets the whole marketplace:"
offer() { # offer <preselect> — the filter exakit_marketplace_offer hands the menu
    (
        _exakit_marketplace_load_modules() { :; }
        exakit_marketplace_has_pending() { return 0; }
        _exakit_marketplace_warm_about() { :; }
        _exakit_prompt_tty() { printf '/dev/tty'; }
        ui_rule() { :; }
        heading() { printf 'HEADING %s\n' "$1"; }
        exakit_marketplace_menu() { printf 'MENU ONLY=[%s]\n' "${EXAKIT_MARKETPLACE_ONLY:-}"; }
        unset EXAKIT_MARKETPLACE_ADDONS EXAKIT_SOFT_FAILED
        EXAKIT_MARKETPLACE_PRESELECT="$1" exakit_marketplace_offer
    )
}
check "all: every add-on, no filter"      "HEADING Add-ons for your personas|MENU ONLY=[]" "$(offer all | tr '\n' '|' | sed 's/|$//')"
check "a list: only those"                "MENU ONLY=[notebook,udf-devkit]" "$(offer notebook,udf-devkit | grep MENU)"
_ps_offer="$(sed -n '/^function Request-ExakitMarketplaceOffer/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
has "the Windows twin treats all the same way" 'if ($only -eq "all")' "$_ps_offer"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
