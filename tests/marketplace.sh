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
export HOME
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
. "$ROOT/setup/lib/dash-server.sh"
. "$ROOT/setup/lib/dbt-exasol.sh"
. "$ROOT/setup/lib/exasol-vscode.sh"
. "$ROOT/setup/lib/json-tables.sh"
. "$ROOT/setup/lib/exasol-scheduler.sh"

# ...and its own port. The default 5100 is where a developer's REAL dash-server
# listens, and the ownership probe would rightly call that a foreign process
# holding the suite's port. A sandbox-unique high port keeps every machine
# reading the same. Explicit, so the manifest never overrides it.
EXAKIT_DASH_SERVER_PORT="$((5900 + $$ % 90))"
_EXAKIT_DS_PORT_EXPLICIT=1

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
check "addons list carries every registered add-on" "dash-server dbt-exasol exasol-scheduler exasol-vscode json-tables" \
    "$(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "addon module is loaded" "yes" "$(exakit_marketplace_addon_available dash-server && echo yes || echo no)"
check "component block" "components.dash-server" "$(_exakit_component_block dash-server)"
check "fallback version is the constant" "$EXAKIT_DASH_SERVER_VERSION_FALLBACK" "$(_exakit_component_fallback dash-server)"
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
# module's constant instead of reading as unknown — that empty answer used to
# make `exakit update dash-server` die on a machine whose fetched doc had no
# dash-server block yet.
check "a manifest without the add-on falls back to the module constant" \
    "$EXAKIT_DASH_SERVER_VERSION_FALLBACK" \
    "$( ( exakit_versions_value() { return 1; }; exakit_component_available dash-server ) )"
check "env override wins" "9.9.9" "$(EXAKIT_DASH_SERVER_VERSION=9.9.9 _exakit_component_env_override dash-server)"
check "release url is the tag tarball" \
    "https://github.com/exasol-labs/dash-server/archive/refs/tags/v0.1.0.tar.gz" \
    "$(dash_server_release_url 0.1.0)"

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
check "all installs every pending addon" "rc=0 called=dash-server dbt-exasol exasol-scheduler exasol-vscode json-tables" "$(run_menu all)"
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

echo "launcher generation:"
printf 's3cr3t-value\n' > "$WORK/pwfile"
chmod 600 "$WORK/pwfile"
manifest_set runtime.dsn "127.0.0.1:8563"
manifest_set runtime.user "sys"
manifest_set runtime.password_file "$WORK/pwfile"
( dash_server_write_launcher >/dev/null 2>&1 )
_launcher="$EXAKIT_BIN_DIR/dash-server"
check "launcher exists and is executable" "yes" "$([ -x "$_launcher" ] && echo yes || echo no)"
_launcher_body="$(cat "$_launcher" 2>/dev/null)"
has  "launcher bakes the DSN" "127.0.0.1:8563" "$_launcher_body"
has  "launcher reads the credential file at run time" "$WORK/pwfile" "$_launcher_body"
lacks "the password itself never lands in the launcher" "s3cr3t-value" "$_launcher_body"
has  "user overrides win (setdefault DSN guard)" 'DASH_SERVER_EXASOL_DSN:-' "$_launcher_body"
has  "instance path is kit-managed" "$EXAKIT_HOME/dash-server/instance" "$_launcher_body"
has  "profile bootstrap goes through the env secret" "DASH_SERVER_EXASOL_SECRET_ENV_VAR" "$_launcher_body"
# Running the launcher while a copy is already serving must explain, not hand
# the user dash-server's single-coordinator traceback.
has  "the launcher refuses a duplicate politely" "already running" "$_launcher_body"
has  "and points at the state and log commands" "exakit logs dash-server" "$_launcher_body"
# ADD-07: the launcher printed a pre-flight verdict for the RECORDED port and
# then execed dash-server with no port at all, so it bound the upstream default
# - on a machine that moved off 5100, the busy one. The bind host was left to
# upstream too, on the one path the kit does not control, while the module
# asserts loopback everywhere else. Both are setdefaults, so an exported value
# still wins.
#
# The bind now names the RESOLVED port rather than a baked number. That check
# used to read 'DASH_SERVER_PORT:=5177' - it asserted the generation port was
# written into the file, which is exactly the copy that later drifted from the
# kit's record (probe on one port, bind on another). The invariant it was
# really after - the pre-flight and the bind agree - is what the variable
# guarantees; which port that resolves to is proven behaviourally further down.
( EXAKIT_DASH_SERVER_PORT=5177 dash_server_write_launcher >/dev/null 2>&1 )
_launcher_5177="$(cat "$_launcher" 2>/dev/null)"
has  "the launcher passes the RESOLVED port to the server" 'DASH_SERVER_PORT:=$_ds_port' "$_launcher_5177"
has  "...and pins the bind host to loopback"               'DASH_SERVER_HOST:=127.0.0.1' "$_launcher_5177"
has  "...exported, or the child never sees them"           'export DASH_SERVER_HOST DASH_SERVER_PORT' "$_launcher_5177"
# The twin: Windows had the identical hole, and the identical drift.
_ds_ps="$(cat "$ROOT/setup/lib/dash-server.ps1")"
has  "the PowerShell launcher does the same" 'if not defined DASH_SERVER_PORT set' "$_ds_ps"
has  "...binding the RESOLVED port, not a baked one" 'DASH_SERVER_PORT=%EXAKIT_DS_PORT%' "$_ds_ps"
has  "...resolved from the kit's record at run time" 'EXAKIT_DS_MANIFEST' "$_ds_ps"
has  "...with the plain default as the last resort" 'if not defined EXAKIT_DS_PORT set' "$_ds_ps"
# Scoped to the GENERATED launcher's probe, not the file: the module itself
# resolves the port and probes it, and those uses are correct.
has  "...probing that same resolved port" 'http://127.0.0.1:%EXAKIT_DS_PORT%/mcp' "$_ds_ps"
has  "...host too"                           'if not defined DASH_SERVER_HOST set' \
    "$(cat "$ROOT/setup/lib/dash-server.ps1")"
( dash_server_write_launcher >/dev/null 2>&1 )   # back to the recorded port

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

echo "pip self-repair (dash-server app builds shell out to python -m pip):"
# The stub python fails `-m pip` until a marker file appears; the stubbed uv
# call plants it. Built OUTSIDE command substitution: bash 3.2 misparses a
# case close-paren inside $( ... ).
_pv="$WORK/pipless-venv"
mkdir -p "$_pv/bin"
rm -f "$_pv/bin/python"
cat > "$_pv/bin/python" <<'PYEOF'
#!/bin/sh
case "$*" in
    *"-m pip"*) [ -f "${0%/*}/pip-marker" ] || exit 1 ;;
    *) echo "0.1.0" ;;
esac
PYEOF
chmod +x "$_pv/bin/python"
_pip_repair="$( (
    EXAKIT_DASH_SERVER_VENV="$_pv"
    run_logged() { # the uv call: record it, then "install" pip
        printf '%s\n' "$*" >> "$WORK/uv-calls"
        : > "$_pv/bin/pip-marker"
    }
    : > "$WORK/uv-calls"
    _dash_server_ensure_pip fake-uv >/dev/null 2>&1 || { echo "repair-failed"; exit 0; }
    grep -q "fake-uv pip install --python $_pv/bin/python pip" "$WORK/uv-calls" && echo "repaired"
) )"
check "a pip-less venv is repaired through uv" "repaired" "$_pip_repair"
_pip_noop="$( (
    EXAKIT_DASH_SERVER_VENV="$_pv"   # now carries the pip-marker from the repair above
    run_logged() { printf '%s\n' "$*" >> "$WORK/uv-calls-2"; }
    : > "$WORK/uv-calls-2"
    _dash_server_ensure_pip fake-uv >/dev/null 2>&1
    [ -s "$WORK/uv-calls-2" ] && echo "reinstalled" || echo "left alone"
) )"
check "a venv that already has pip is left alone" "left alone" "$_pip_noop"

echo "soft-fail accounting:"
( _dash_server_not_installed "the disk caught fire" >/dev/null 2>&1 )
check "a soft miss records validated=false" "false" "$(manifest_get components.dash_server.validated)"

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
check "already-current says so and regenerates the launcher" "yes" "$( (
    dash_server_installed_version() { echo "0.0.1-test"; }
    exakit_component_available() { echo "0.0.1-test"; }
    rm -f "$EXAKIT_BIN_DIR/dash-server"
    dash_server_update >/dev/null 2>&1 && [ -x "$EXAKIT_BIN_DIR/dash-server" ] && echo yes || echo no
) )"

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

echo "install refuses a venv that cannot answer for its version:"
# The check is about the version probe, not uv — CI runners have no uv on
# PATH, so the bootstrap is stubbed to a fake binary either way (a machine
# with a real uv never reaches the stub).
printf '#!/bin/sh\nexit 0\n' > "$WORK/stub-uv"
chmod +x "$WORK/stub-uv"
_noversion_out="$( (
    EXAKIT_DASH_SERVER_VENV="$WORK/hollow-venv"
    exakit_ensure_uv() { EXAKIT_UV_BIN="$WORK/stub-uv"; return 0; }
    run_logged() { return 0; }               # venv creation and pip install "succeed"
    dash_server_installed_version() { return 1; }   # ...but the package never materializes
    dash_server_install 2>&1
    printf 'rc=%s' "$?"
) )"
has "a hollow install is refused, not reported" "cannot report a dash-server version" "$_noversion_out"
has "and it returns failure" "rc=1" "$_noversion_out"

echo "validation shortcut when the port already answers:"
mkdir -p "$WORK/live-venv/bin"
rm -f "$WORK/live-venv/bin/python"
printf '#!/bin/sh\nexit 0\n' > "$WORK/live-venv/bin/python"
chmod +x "$WORK/live-venv/bin/python"
_live_out="$( (
    EXAKIT_DASH_SERVER_VENV="$WORK/live-venv"
    _dash_server_port_foreign_desc() { return 1; }   # nobody else holds the port
    _dash_server_http_answers() { return 0; }    # something already serves /mcp
    dash_server_validate 2>&1
) )"
has "an already-running server validates without a second bind" "control plane answers" "$_live_out"
check "and records validated=true" "true" "$(manifest_get components.dash_server.validated)"

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

echo "exasol-vscode (the VS Code extension add-on):"
# The stub `code` CLI created at the top answers the listing and records
# every invocation; CODE_LISTING and CODE_CALLS steer it per case.

check "live version parses publisher.id@version" "1.7.0" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="other.ext@2.0.0
exasol.exasol-vscode@1.7.0"
    export CODE_LISTING
    _exasol_vscode_live_version
) )"
check "extension in VS Code without a kit record = system install" "sys=yes kit=no" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="exasol.exasol-vscode@1.7.0"; export CODE_LISTING
    printf 'sys=%s ' "$(exasol_vscode_system_present && echo yes || echo no)"
    printf 'kit=%s' "$(exasol_vscode_installed_version >/dev/null 2>&1 && echo yes || echo no)"
) )"
check "kit record + live extension = kit-managed" "sys=no kit=1.7.0" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="exasol.exasol-vscode@1.7.0"; export CODE_LISTING
    manifest_set components.exasol_vscode.version "1.7.0"
    printf 'sys=%s ' "$(exasol_vscode_system_present && echo yes || echo no)"
    printf 'kit=%s' "$(exasol_vscode_installed_version)"
) )"
( . /dev/null; manifest_set components.exasol_vscode.version "" ) 2>/dev/null
python3 - "$EXAKIT_HOME/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc.get("components", {}).pop("exasol_vscode", None)
json.dump(doc, open(path, "w"))
PY
check "no record and no extension = simply pending" "no" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING=""; export CODE_LISTING
    _exakit_marketplace_addon_present exasol-vscode && echo yes || echo no
) )"
check "the sandbox extensions dir is passed through" "yes" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_CALLS="$WORK/code-calls"; export CODE_CALLS
    : > "$CODE_CALLS"
    _exasol_vscode_code --list-extensions >/dev/null 2>&1
    grep -q -- "--extensions-dir $EXAKIT_EXASOL_VSCODE_EXTDIR" "$CODE_CALLS" && echo yes || echo no
) )"

# On WSL the `code` on PATH is the WINDOWS build, reached over /mnt/c interop,
# and it parses every path in its argv as a Windows path: an untranslated
# /tmp/x.vsix arrives as C:\tmp\x.vsix and the install dies with ENOENT. Which
# CLI we are talking to therefore decides whether a path needs translating.
check "a native code CLI is left alone" "native" "$( (
    exasol_vscode_code_cli() { printf '/usr/bin/code\n'; }
    _exasol_vscode_code_is_windows && printf 'windows\n' || printf 'native\n'
) )"
check "a /mnt interop CLI reads as Windows" "windows" "$( (
    exasol_vscode_code_cli() { printf '/mnt/c/Program Files/Microsoft VS Code/bin/code\n'; }
    _exasol_vscode_code_is_windows && printf 'windows\n' || printf 'native\n'
) )"
check "so does a .cmd launcher" "windows" "$( (
    exasol_vscode_code_cli() { printf '/somewhere/code.cmd\n'; }
    _exasol_vscode_code_is_windows && printf 'windows\n' || printf 'native\n'
) )"
check "a native CLI gets the path verbatim" "/tmp/x.vsix" "$( (
    exasol_vscode_code_cli() { printf '/usr/bin/code\n'; }
    _exasol_vscode_host_path /tmp/x.vsix
) )"
if command -v wslpath >/dev/null 2>&1; then
    # A real WSL host: the path must come back as something Windows can open.
    # Computed first, then matched: a `case` inside the $( ) would not parse
    # under bash 3.2 (see the note on the drain checks above).
    _wsl_translated="$( (
        exasol_vscode_code_cli() { printf '/mnt/c/code.cmd\n'; }
        _exasol_vscode_host_path /tmp/x.vsix
    ) )"
    lacks "on WSL a Windows CLI gets a translated path" "/tmp/x.vsix" "$_wsl_translated"
else
    # Anywhere else there is nothing to translate WITH, and a best guess would
    # be worse than none: the argument is returned untouched, so the call fails
    # exactly as it did before rather than in some new way.
    check "without wslpath the path is returned unchanged" "/tmp/x.vsix" "$( (
        exasol_vscode_code_cli() { printf '/mnt/c/code.cmd\n'; }
        _exasol_vscode_host_path /tmp/x.vsix
    ) )"
fi

# A Windows CLI cannot open a file that lives on the WSL side - Node refuses the
# UNC host (ERR_UNC_HOST_NOT_ALLOWED: "UNC host 'wsl.localhost' access is not
# allowed"), seen live on a WSL install - so the install stages the .vsix on a
# Windows drive (the user's %TEMP%, over /mnt) and removes both copies after.
EV_SRC="$(cat "$ROOT/setup/lib/exasol-vscode.sh")"
has "a Windows code CLI gets a copy staged on a Windows drive, not a wsl.localhost path" \
    '_evi_stage="$(_exasol_vscode_windows_stage_dir 2>/dev/null || true)"' "$EV_SRC"
has "both the WSL download and the staged copy are removed after the install" \
    '_exasol_vscode_cleanup_vsix "$_evi_local" "$_evi_vsix"' "$EV_SRC"
check "the stage dir falls back to the system temp folders when cmd.exe is absent" "" "$( (
    command() { if [ "$1" = "-v" ] && [ "$2" = "cmd.exe" ]; then return 1; fi; builtin command "$@"; }
    _exasol_vscode_windows_stage_dir 2>/dev/null | grep -v '^/mnt/c/'
) )"

echo "a stdin-draining host CLI must not eat the add-on registry:"
# The VS Code CLI reads and DRAINS whatever stdin it inherits. Every loop over
# the add-on registry calls into the add-on modules, and the exasol-vscode row
# asks VS Code what is installed — so with the registry on stdin, that one call
# swallowed the rest of the loop's input and every add-on listed AFTER
# exasol-vscode silently vanished. json-tables is last in the registry, so
# json-tables is what disappeared, on every machine that had VS Code.
#
# Measured on WSL before the fix: a `while read` loop over three lines read ONE.
# CI never caught it because a runner has no VS Code at all, so the CLI is never
# found and never run — which is exactly why this stub exists. It reproduces the
# drain on a machine that has no VS Code, and it fails against the old code.
mkdir -p "$WORK/drain-bin"
cat > "$WORK/drain-bin/code" <<'DRAINSTUBEOF'
#!/bin/sh
# Behave like the real thing in the one way that matters here.
cat >/dev/null 2>&1 || true
exit 0
DRAINSTUBEOF
chmod +x "$WORK/drain-bin/code"
# The registry's LAST entry is the canary: it is the one a drain loses first.
_drain_last="$(exakit_marketplace_addons | tail -1 | cut -d'|' -f1)"
check "the canary is still the last registry entry" "json-tables" "$_drain_last"
# NOTE: the result is computed first and matched with `has`, rather than with a
# `case` inside the $( ). bash 3.2 - what macOS ships, and what this repo must
# keep working on - mis-parses a case pattern's closing ')' inside a command
# substitution ("syntax error near unexpected token `newline'"), which made
# both of these read as failures on macOS only.
_drain_targets="$( (
    PATH="$WORK/drain-bin:$PATH"
    exakit_version_table_targets 2>/dev/null
) )"
has "version-table targets survive the drain" "$_drain_last" "$_drain_targets"
_drain_installed="$( (
    PATH="$WORK/drain-bin:$PATH"
    # exasol-vscode stays REAL and gets a manifest record, so its row actually
    # runs the draining CLI - that is the whole point. Only the canary is
    # stubbed, because its real probe verifies the venv and engine on disk and
    # would answer "not installed" here for reasons that have nothing to do
    # with the drain.
    manifest_set components.exasol_vscode.version "1.7.0" >/dev/null 2>&1
    manifest_set components.json_tables.version "v0.2" >/dev/null 2>&1
    json_tables_installed_version() { printf 'v0.2\n'; }
    exakit_marketplace_installed_addons 2>/dev/null
) )"
has "installed-addon enumeration survives the drain" "$_drain_last" "$_drain_installed"
check "has-pending survives the drain" "yes" "$( (
    PATH="$WORK/drain-bin:$PATH"
    exakit_marketplace_has_pending && printf 'yes\n' || printf 'no\n'
) )"

echo "an add-on that needs a host app is only offered when the app is there:"
# No VS Code on this machine → the extension is not an option at all: no menu
# row, and no row in the `exakit version` table either. The kit never advertises
# something it cannot install here.
_no_code="$( (
    cover_every_addon
    exasol_vscode_code_cli() { return 1; }          # no VS Code anywhere
    exasol_vscode_system_present() { return 1; }    # ...and not present either
    printf 'applicable=%s ' "$(_exakit_addon_applicable exasol-vscode && echo yes || echo no)"
    printf 'offerable=%s ' "$(_exakit_addon_offerable exasol-vscode && echo yes || echo no)"
    printf 'in-menu=%s ' "$(exakit_marketplace_menu 2>&1 | grep -c exasol-vscode)"
    printf 'in-version-table=%s' "$(exakit_version_table_targets 2>&1 | grep -c exasol-vscode)"
) )"
check "without the host app it is hidden everywhere" \
    "applicable=no offerable=no in-menu=0 in-version-table=0" "$_no_code"
# With VS Code present it is a normal, selectable add-on again.
_with_code="$( (
    exasol_vscode_code_cli() { printf '/stub/code\n'; }
    # The menu installs nothing without a terminal, so probing its DRAWN
    # content needs one faked; the guard itself has its own assertions below.
    _exakit_prompt_tty() { printf 'stub\n'; }
    printf 'applicable=%s ' "$(_exakit_addon_applicable exasol-vscode && echo yes || echo no)"
    printf 'in-menu=%s' "$(exakit_marketplace_menu 2>&1 | grep -c exasol-vscode)"
) )"
has "with the host app present it is offered again" "applicable=yes" "$_with_code"
check "and appears in the menu" "yes" "$(
    printf '%s' "$_with_code" | grep -q 'in-menu=0' && echo no || echo yes
)"
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
# Naming it explicitly on a machine without the app explains why, instead of
# claiming the add-on is unknown or failing deep in the installer.
_named="$( (
    exasol_vscode_code_cli() { return 1; }
    EXAKIT_MARKETPLACE_ADDONS="exasol-vscode"
    exakit_marketplace_menu 2>&1
) )"
has "naming it anyway explains the host app is missing" "VS Code was not found" "$_named"
lacks "and never calls it unknown" "Unknown marketplace add-on" "$_named"
# A kit-installed copy stays visible even if the app disappears afterwards, so
# it can still be updated or removed rather than becoming unreachable state.
check "an installed copy stays visible without the app" "yes" "$( (
    exasol_vscode_code_cli() { return 1; }
    exakit_marketplace_addon_installed() { return 0; }
    _exakit_addon_offerable exasol-vscode && echo yes || echo no
) )"

echo "exasol-vscode checksum chain (mirrors the exapump precedence):"
check "the advertised version verifies against versions.json" \
    "$(exakit_versions_value components.exasol-vscode.sha256.vsix "$ROOT/versions.json")" \
    "$(exasol_vscode_expected_sha256 "$(exakit_versions_value components.exasol-vscode.version "$ROOT/versions.json")")"
check "an unadvertised version falls to the pinned table, then the API" "pinned-empty from-api" "$( (
    exasol_vscode_pinned_sha256() { printf ''; }
    exasol_vscode_release_digest_from_api() { printf 'from-api\n'; }
    printf 'pinned-empty %s' "$(exasol_vscode_expected_sha256 0.0.0-not-advertised)"
) )"
check "a checksum mismatch refuses the install" "refused rc=1" "$( (
    PATH="$WORK/code-bin:$PATH"
    fetch() { printf 'not-the-real-vsix' > "$2"; }
    exasol_vscode_expected_sha256() { printf '%064d\n' 1; }
    exasol_vscode_install >/dev/null 2>&1 && printf 'installed' || printf 'refused rc=1'
) )"
check "no checksum anywhere refuses the install" "yes" "$( (
    PATH="$WORK/code-bin:$PATH"
    fetch() { printf 'payload' > "$2"; }
    exasol_vscode_expected_sha256() { return 1; }
    exasol_vscode_install 2>&1 | grep -q "refusing an unverified extension" && echo yes || echo no
) )"
check "no VS Code anywhere is a soft miss naming the fix" "yes" "$( (
    exasol_vscode_code_cli() { return 1; }
    exasol_vscode_install 2>&1 | grep -q "install VS Code" && echo yes || echo no
) )"

echo "the browser UI is validated separately from the control plane:"
# The packaging gap that shipped a 500 to a user looked healthy on /mcp. A
# broken page must be reported, never pass silently — and it must not fail the
# install, because agents can still drive the add-on over MCP.
_ui_bad="$( (
    _dash_server_ui_answers() { return 1; }
    _dash_server_check_ui 2>&1
) )"
has "a broken dashboards page is called out" "does not render" "$_ui_bad"
check "and recorded, not swallowed" "false" "$(manifest_get components.dash_server.ui_validated)"
_ui_good="$( (
    _dash_server_ui_answers() { return 0; }
    _dash_server_check_ui 2>&1
) )"
has "a working page is confirmed" "Dashboards page answers" "$_ui_good"
check "and recorded" "true" "$(manifest_get components.dash_server.ui_validated)"

# The fresh-install path starts its own probe server, and the browser page must
# be probed WHILE that server is alive. Probing after the kill asked a DEAD
# port whether it renders, so every fresh install warned "the dashboards page
# does not render" about a page that worked the moment the user opened it.
# The fake server below drops its marker when killed, so a probe that happens
# after the kill genuinely sees nothing — which is what makes this discriminate.
_ui_order="$( (
    dash_server_venv_python() { printf '%s\n' "$EXAKIT_HOME/dash-server-venv/bin/python"; }
    mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
    rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
    printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
    chmod 755 "$EXAKIT_HOME/dash-server-venv/bin/python"
    _dash_server_resolve_port() { :; }
    _dash_server_port_foreign_desc() { return 1; }
    _dash_server_http_answers() { [ -f "$WORK/probe-up" ]; }
    _dash_server_ui_answers() { [ -f "$WORK/probe-up" ]; }
    EXAKIT_DASH_SERVER_BIN="$WORK/fake-dash-server"
    cat > "$WORK/fake-dash-server" <<FAKEEOF
#!/bin/sh
trap 'rm -f "$WORK/probe-up"; exit 0' TERM INT
touch "$WORK/probe-up"
while :; do sleep 1; done
FAKEEOF
    chmod 755 "$WORK/fake-dash-server"
    _dash_server_print_usage() { :; }
    rm -f "$WORK/probe-up"
    dash_server_validate >/dev/null 2>&1
    printf 'ui=%s' "$(manifest_get components.dash_server.ui_validated)"
) )"
check "the UI is probed while the probe server is alive" "ui=true" "$_ui_order"

# The stale-process repair: a server started BEFORE the package-data restore
# serves 500 on templates that are on disk, and re-validating the same process
# can never heal it. When the broken page is on OUR OWN instance, validation
# restarts it once; a foreign holder is never touched.
_ui_heal="$( (
    dash_server_venv_python() { printf '%s\n' "$EXAKIT_HOME/dash-server-venv/bin/python"; }
    mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
    rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
    printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
    chmod 755 "$EXAKIT_HOME/dash-server-venv/bin/python"
    _dash_server_resolve_port() { :; }
    _dash_server_port_foreign_desc() { return 1; }
    _dash_server_http_answers() { return 0; }
    _dash_server_ui_answers() { return 1; }
    _dash_server_port_is_ours() { return 0; }
    dash_server_stop() { printf 'STOPPED ' >> "$WORK/heal-trace"; }
    dash_server_start() { printf 'STARTED ' >> "$WORK/heal-trace"; _dash_server_ui_answers() { return 0; }; }
    _dash_server_print_usage() { :; }
    : > "$WORK/heal-trace"
    dash_server_validate >/dev/null 2>&1
    printf '%sui=%s' "$(cat "$WORK/heal-trace")" "$(manifest_get components.dash_server.ui_validated)"
) )"
check "a stale instance of ours is restarted, then judged" "STOPPED STARTED ui=true" "$_ui_heal"
_ui_foreign="$( (
    dash_server_venv_python() { printf '%s\n' "$EXAKIT_HOME/dash-server-venv/bin/python"; }
    _dash_server_resolve_port() { :; }
    _dash_server_port_foreign_desc() { return 1; }
    _dash_server_http_answers() { return 0; }
    _dash_server_ui_answers() { return 1; }
    _dash_server_port_is_ours() { return 1; }
    dash_server_stop() { printf 'STOPPED ' >> "$WORK/heal-trace2"; }
    dash_server_start() { printf 'STARTED ' >> "$WORK/heal-trace2"; }
    _dash_server_print_usage() { :; }
    : > "$WORK/heal-trace2"
    dash_server_validate >/dev/null 2>&1
    [ -s "$WORK/heal-trace2" ] && printf 'restarted' || printf 'untouched'
) )"
check "a foreign holder is never restarted" "untouched" "$_ui_foreign"
# The restore only fills GAPS: a file the install already placed is never
# overwritten, so a fixed upstream release makes it a silent no-op.
check "restoring package data leaves existing files alone" "original" "$( (
    _drp_dir="$WORK/site/dash_server"
    mkdir -p "$_drp_dir/templates"
    printf 'original' > "$_drp_dir/templates/keep.html"
    dash_server_venv_python() { printf '%s\n' "$WORK/stub-py"; }
    printf '#!/bin/sh\nprintf "%s\\n" "'"$_drp_dir"'"\n' > "$WORK/stub-py"; chmod +x "$WORK/stub-py"
    fetch() { return 1; }          # no network in the suite: the restore bails out
    _dash_server_restore_package_data >/dev/null 2>&1
    cat "$_drp_dir/templates/keep.html"
) )"

echo "add-on uninstall hooks (what folds them into exakit uninstall):"
# dash-server: dry narrates, real removes venv + state + launcher + record.
mkdir -p "$EXAKIT_HOME/dash-server-venv" "$EXAKIT_HOME/dash-server" "$EXAKIT_BIN_DIR"
: > "$EXAKIT_BIN_DIR/dash-server"
manifest_set components.dash_server.version "0.1.0"
_ds_dry="$(dash_server_uninstall 1 2>&1)"
has "dash-server dry-run narrates, removes nothing" "will remove" "$_ds_dry"
check "and the venv survives a dry-run" "yes" "$([ -d "$EXAKIT_HOME/dash-server-venv" ] && echo yes || echo no)"
dash_server_uninstall 0 >/dev/null 2>&1
check "real run removes venv, state and launcher" "GONE GONE GONE" "$(
    for p in "$EXAKIT_HOME/dash-server-venv" "$EXAKIT_HOME/dash-server" "$EXAKIT_BIN_DIR/dash-server"; do
        [ -e "$p" ] && printf 'KEPT ' || printf 'GONE '
    done | sed 's/ $//'
)"
check "and clears the manifest record" "absent" "$(manifest_get components.dash_server.version >/dev/null 2>&1 && echo present || echo absent)"

# exasol-vscode: a kit-managed copy is removed through VS Code's own CLI; a
# copy the kit never installed is refused, and the CLI is never invoked.
_vs_kit="$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="exasol.exasol-vscode@1.7.0"; export CODE_LISTING
    CODE_CALLS="$WORK/un-calls"; export CODE_CALLS
    : > "$CODE_CALLS"
    manifest_set components.exasol_vscode.version "1.7.0"
    exasol_vscode_uninstall 0 >/dev/null 2>&1
    grep -q -- "--uninstall-extension exasol.exasol-vscode" "$CODE_CALLS" && printf 'cli-called '
    manifest_get components.exasol_vscode.version >/dev/null 2>&1 && printf 'record-kept' || printf 'record-cleared'
) )"
check "kit-managed extension: removed via code CLI, record cleared" "cli-called record-cleared" "$_vs_kit"
_vs_sys="$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="exasol.exasol-vscode@1.7.0"; export CODE_LISTING
    CODE_CALLS="$WORK/un-calls-2"; export CODE_CALLS
    : > "$CODE_CALLS"
    exasol_vscode_uninstall 0 2>&1 | grep -q "not kit-managed" && printf 'refused '
    grep -q -- "--uninstall-extension" "$CODE_CALLS" && printf 'cli-called' || printf 'cli-untouched'
) )"
check "a Marketplace-installed copy is refused, CLI untouched" "refused cli-untouched" "$_vs_sys"

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
    dash_server_uninstall() { printf 'hook-ran'; }
    _exakit_uninstall_component dash-server 0
) )"
check "an add-on without a hook explains instead of failing" "yes" "$( (
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

echo "services and autostart (is it running, and does it come back after a reboot):"
# A stand-in server on a quiet port: the status probe is an HTTP check, so
# anything that answers proves the plumbing without installing dash-server.
mkdir -p "$EXAKIT_HOME/logs" "$EXAKIT_HOME/dash-server-venv/bin"
# The stand-in server must look like ours to the ownership probe, which matches
# on the venv path. The real console script is run as
# `<venv>/bin/python <venv>/bin/dash-server`, so the venv shows up in argv - a
# bare `python3 -m http.server` never would. A script INSIDE the venv bin
# reproduces that shape (a symlinked interpreter does not: macOS resolves
# argv[0] to the framework binary).
cat > "$EXAKIT_HOME/dash-server-venv/bin/serve.py" <<'SERVEEOF'
import http.server, socketserver, sys
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), http.server.SimpleHTTPRequestHandler) as httpd:
    httpd.serve_forever()
SERVEEOF
check "not installed reads as such, never 'stopped'" "not installed" "$(
    ( EXAKIT_DASH_SERVER_BIN="$WORK/nope"; dash_server_status )
)"
cat > "$EXAKIT_BIN_DIR/dash-server" <<SRVEOF
#!/bin/sh
exec python3 "$EXAKIT_HOME/dash-server-venv/bin/serve.py" $EXAKIT_DASH_SERVER_PORT
SRVEOF
chmod +x "$EXAKIT_BIN_DIR/dash-server"
check "installed but down reads stopped" "stopped" "$(dash_server_status)"
dash_server_start >/dev/null 2>&1
check "start brings it up" "running" "$(dash_server_status)"
check "and records a pidfile" "yes" "$([ -f "$EXAKIT_DASH_SERVER_PIDFILE" ] && echo yes || echo no)"
has "starting twice is idempotent" "already running" "$(dash_server_start 2>&1)"
dash_server_stop >/dev/null 2>&1
check "stop takes it down and cleans the pidfile" "stopped cleaned" \
    "$(printf '%s %s' "$(dash_server_status)" "$([ -f "$EXAKIT_DASH_SERVER_PIDFILE" ] && echo kept || echo cleaned)")"
has "stopping twice is idempotent" "already stopped" "$(dash_server_stop 2>&1)"

echo "a port held by someone else is never mistaken for dash-server:"
# The old probe asked "does something answer HTTP here", so ANY web server on
# the port made the kit report a healthy add-on it never started. Ownership is
# matched on the venv path, the way the real console script is recognised.
#
# The foreign listener must PROVABLY be up before anything is asserted about
# it: a fixed sleep was not enough on GitHub's macOS runners (a cold python
# can take longer than 2s to serve), and every check below reads as a product
# failure when the fixture silently is not there. So: try a few candidate
# ports (the first choice can be genuinely taken on a shared runner), poll
# until the listener ANSWERS, and if none can be started, skip the section
# with the reason instead of failing on a fixture.
_foreign_port=""
_foreign_pid=""
for _fp_try in "$((6100 + $$ % 80))" "$((6300 + $$ % 80))" "$((6500 + $$ % 80))"; do
    python3 -m http.server "$_fp_try" --bind 127.0.0.1 >/dev/null 2>&1 &
    _fp_pid=$!
    _fp_up=0
    _fp_n=0
    while [ "$_fp_n" -lt 40 ]; do
        if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$_fp_try/" 2>/dev/null; then
            _fp_up=1
            break
        fi
        # The process dying (port taken, python unhappy) ends the wait early.
        kill -0 "$_fp_pid" 2>/dev/null || break
        sleep 0.5
        _fp_n=$((_fp_n + 1))
    done
    if [ "$_fp_up" -eq 1 ]; then
        _foreign_port="$_fp_try"
        _foreign_pid="$_fp_pid"
        break
    fi
    kill "$_fp_pid" 2>/dev/null
    wait "$_fp_pid" 2>/dev/null || true
done
if [ -z "$_foreign_port" ]; then
    echo "  SKIP  no local test listener could be started on this machine — port-ownership checks not run"
else
_port_verdict="$( (
    EXAKIT_DASH_SERVER_PORT="$_foreign_port"
    printf 'status=%s ' "$(dash_server_status | cut -d'(' -f1 | sed 's/ *$//')"
    printf 'ours=%s ' "$(_dash_server_port_is_ours && echo yes || echo no)"
    printf 'foreign=%s' "$(_dash_server_port_foreign_desc >/dev/null 2>&1 && echo yes || echo no)"
) )"
check "a foreign listener reads as stopped, not running" "status=stopped ours=no foreign=yes" "$_port_verdict"
has "status names the process holding it" "held by another process" \
    "$( ( EXAKIT_DASH_SERVER_PORT="$_foreign_port"; dash_server_status ) )"
_start_refusal="$( ( EXAKIT_DASH_SERVER_PORT="$_foreign_port"; dash_server_start 2>&1 ) )"
has "start refuses instead of claiming success" "cannot bind" "$_start_refusal"
has "and says how to move to a free port" "EXAKIT_DASH_SERVER_PORT" "$_start_refusal"
_val_refusal="$( ( EXAKIT_DASH_SERVER_PORT="$_foreign_port"; dash_server_validate 2>&1 ) )"
has "validation refuses to claim health on someone else's port" "was not validated" "$_val_refusal"
# An install with no explicit port steps over the busy one instead of failing.
_settled="$( (
    EXAKIT_DASH_SERVER_PORT="$_foreign_port"
    _EXAKIT_DS_PORT_EXPLICIT=0
    _dash_server_settle_port >/dev/null 2>&1
    printf '%s' "$EXAKIT_DASH_SERVER_PORT"
) )"
check "an unnamed port steps past the collision" "$((_foreign_port + 1))" "$_settled"
# A port the user NAMED is refused rather than silently moved.
_explicit="$( (
    EXAKIT_DASH_SERVER_PORT="$_foreign_port"
    _EXAKIT_DS_PORT_EXPLICIT=1
    _dash_server_settle_port 2>&1 | head -1
) )"
has "a named port is refused, never moved behind your back" "is held by another process" "$_explicit"
kill "$_foreign_pid" 2>/dev/null
wait "$_foreign_pid" 2>/dev/null || true
fi

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
check "the registry lists the database and the service add-on" "database dash-server" \
    "$(exakit_service_ids | tr '\n' ' ' | sed 's/ $//')"
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

# The asset name is the contract between the packaging workflow and the
# installer: a mismatch means every download 404s. Pin both halves.
_jt_asset() { ( detect_os() { printf '%s\n' "$1"; }; detect_arch() { printf '%s\n' "$2"; }
    json_tables_engine_asset 2>/dev/null || printf 'NONE\n' ); }
check "macOS arm64 asks for the macos-aarch64 engine" "exasol-json-tables-ingest-macos-aarch64" \
    "$( ( detect_os() { printf 'macos\n'; }; detect_arch() { printf 'arm64\n'; }; json_tables_engine_asset ) )"
check "Linux x86_64 asks for the linux-x86_64 engine" "exasol-json-tables-ingest-linux-x86_64" \
    "$( ( detect_os() { printf 'linux\n'; }; detect_arch() { printf 'x86_64\n'; }; json_tables_engine_asset ) )"
check "Linux arm64 asks for the linux-aarch64 engine" "exasol-json-tables-ingest-linux-aarch64" \
    "$( ( detect_os() { printf 'linux\n'; }; detect_arch() { printf 'arm64\n'; }; json_tables_engine_asset ) )"
# WSL IS Linux and runs the linux engine. detect_os reports it as a platform of
# its own because the INSTALLER needs that distinction (WSL is refused, /mnt
# paths) — but an artifact lookup does not, and one that fails to fold it back
# into linux hides the add-on from every WSL machine, with a "no prebuilt engine
# for this platform" reason that is not true.
check "WSL x86_64 asks for the linux-x86_64 engine" "exasol-json-tables-ingest-linux-x86_64" \
    "$( ( detect_os() { printf 'wsl\n'; }; detect_arch() { printf 'x86_64\n'; }; json_tables_engine_asset ) )"
check "WSL arm64 asks for the linux-aarch64 engine" "exasol-json-tables-ingest-linux-aarch64" \
    "$( ( detect_os() { printf 'wsl\n'; }; detect_arch() { printf 'arm64\n'; }; json_tables_engine_asset ) )"
check "and WSL is therefore OFFERED, not hidden" "offered" \
    "$( ( detect_os() { printf 'wsl\n'; }; detect_arch() { printf 'x86_64\n'; }
        json_tables_applicable && printf 'offered\n' || printf 'hidden\n' ) )"
# An Intel Mac has no published engine and building one needs the toolchain the
# add-on exists to avoid: it must be HIDDEN, not offered and then failed.
check "an Intel Mac is not applicable" "hidden" \
    "$( ( detect_os() { printf 'macos\n'; }; detect_arch() { printf 'x86_64\n'; }
        json_tables_applicable && printf 'offered\n' || printf 'hidden\n' ) )"
has "and says why, in terms the user can act on" "no prebuilt ingest engine" \
    "$( ( detect_os() { printf 'macos\n'; }; detect_arch() { printf 'x86_64\n'; }
        json_tables_applicable_reason ) )"

# The mirror must be looked up where THIS kit came from: a user who installed
# from a fork gets that fork's mirror release, not the canonical repo's (which
# may not have one). Explicit override still wins; a checkout falls back.
check "the mirror follows the recorded install source" "some-fork/update-path" "$( (
    manifest_set kit.source "some-fork/update-path@main" >/dev/null 2>&1
    json_tables_mirror_repo
) )"
check "an explicit mirror override wins over the source" "elsewhere/mirror" "$( (
    manifest_set kit.source "some-fork/update-path@main" >/dev/null 2>&1
    EXAKIT_JSON_TABLES_MIRROR_REPO="elsewhere/mirror"
    json_tables_mirror_repo
) )"
check "a checkout install falls back to the kit repo" "$EXAKIT_KIT_REPO" "$( (
    manifest_set kit.source "checkout:/tmp/somewhere" >/dev/null 2>&1
    json_tables_mirror_repo
) )"

# The shim is the whole no-Rust story. Upstream's ONLY engine call is
#   cargo run --manifest-path <...>/json_tables_ingest/Cargo.toml -- <engine argv>
# so the shim must hand <engine argv> to the prebuilt binary verbatim: an extra
# or dropped argument here is a broken ingest for every user.
_jt_shim="$( (
    EXAKIT_JSON_TABLES_HOME="$WORK/jt"
    mkdir -p "$WORK/jt/libexec"
    printf '#!/bin/sh\nprintf "ARGV"; for a in "$@"; do printf " <%%s>" "$a"; done; printf "\\n"\n' \
        > "$WORK/jt/libexec/json_to_parquet"
    chmod 755 "$WORK/jt/libexec/json_to_parquet"
    json_tables_write_shim >/dev/null 2>&1
    "$WORK/jt/shim/cargo" run --manifest-path /x/crates/json_tables_ingest/Cargo.toml \
        -- --input /tmp/a.json --output-dir /tmp/out --schema-sql
) )"
check "the shim replays the engine argv exactly" \
    "ARGV <--input> </tmp/a.json> <--output-dir> </tmp/out> <--schema-sql>" "$_jt_shim"
# A user with their own cargo must keep it: the shim is only ever on PATH
# inside our launcher, and even there it must not swallow unrelated commands.
_jt_passthru="$( (
    EXAKIT_JSON_TABLES_HOME="$WORK/jt2"
    mkdir -p "$WORK/jt2/libexec" "$WORK/real-cargo"
    printf '#!/bin/sh\necho REAL-CARGO "$@"\n' > "$WORK/real-cargo/cargo"
    chmod 755 "$WORK/real-cargo/cargo"
    : > "$WORK/jt2/libexec/json_to_parquet"; chmod 755 "$WORK/jt2/libexec/json_to_parquet"
    json_tables_write_shim >/dev/null 2>&1
    PATH="$WORK/jt2/shim:$WORK/real-cargo" "$WORK/jt2/shim/cargo" build --release
) )"
check "anything else reaches the real cargo untouched" "REAL-CARGO build --release" "$_jt_passthru"

_jt_launcher="$( (
    EXAKIT_JSON_TABLES_HOME="$WORK/jt3"
    EXAKIT_JSON_TABLES_VENV="$WORK/jt3-venv"
    EXAKIT_JSON_TABLES_BIN="$WORK/bin/exasol-json-tables"
    json_tables_write_launcher >/dev/null 2>&1
    grep -c "$WORK/jt3/shim" "$WORK/bin/exasol-json-tables"
    grep -c "$WORK/jt3-venv/bin/exasol-json-tables" "$WORK/bin/exasol-json-tables"
) )"
check "the launcher fronts PATH with the shim and runs the venv CLI" "1
1" "$_jt_launcher"

# Half an install is not an install: a venv whose engine never arrived would
# pass an import check and then fail at the first ingest.
_jt_half="$( (
    EXAKIT_JSON_TABLES_VENV="$WORK/jt-half-venv"
    EXAKIT_JSON_TABLES_HOME="$WORK/jt-half"
    mkdir -p "$WORK/jt-half-venv/bin"
    rm -f "$WORK/jt-half-venv/bin/python"
    printf '#!/bin/sh\nexit 0\n' > "$WORK/jt-half-venv/bin/python"; chmod 755 "$WORK/jt-half-venv/bin/python"
    manifest_set components.json_tables.version 50d05da0f6da >/dev/null 2>&1
    json_tables_installed_version >/dev/null 2>&1 && printf 'installed\n' || printf 'not installed\n'
) )"
check "a venv without the engine does not count as installed" "not installed" "$_jt_half"

# The mirror release is published by our own workflow. Until it exists the
# add-on must fail SOFT and name the fix, never end the caller's run.
_jt_missing="$( (
    EXAKIT_JSON_TABLES_MIRROR_TAG="does-not-exist-$$"
    # The module chooses its sentence from the HTTP status the release lookup
    # recorded, so the stub has to leave that record behind the way a real 404
    # would -- a bare "return 1" is "GitHub could not be reached", which names
    # the network, not the workflow.
    _json_tables_mirror_wheel_name() {
        _jtm_c="$(_json_tables_mirror_cache_file 2>/dev/null || printf '%s' "$EXAKIT_JSON_TABLES_MIRROR_CACHE")"
        mkdir -p "$(dirname "$_jtm_c")"; printf '404' > "$_jtm_c.http"; return 1; }
    exakit_ensure_uv() { return 0; }
    EXAKIT_UV_BIN="$WORK/bin/uv"; printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/uv"; chmod 755 "$WORK/bin/uv"
    detect_os() { printf 'linux\n'; }; detect_arch() { printf 'x86_64\n'; }
    json_tables_install 2>&1 | tr '\n' ' '
    printf 'rc=%s' "$?"
) )"
has "a missing mirror release names the workflow to run" "pkg / json-tables" "$_jt_missing"
has "and stays a soft failure" "Everything else in the kit is unaffected" "$_jt_missing"

_jt_uninst="$( (
    EXAKIT_JSON_TABLES_VENV="$WORK/jt-u-venv"
    EXAKIT_JSON_TABLES_HOME="$WORK/jt-u"
    EXAKIT_JSON_TABLES_BIN="$WORK/bin/exasol-json-tables-u"
    mkdir -p "$EXAKIT_JSON_TABLES_VENV" "$EXAKIT_JSON_TABLES_HOME"
    : > "$EXAKIT_JSON_TABLES_BIN"
    manifest_set components.json_tables.version 50d05da0f6da >/dev/null 2>&1
    json_tables_uninstall 1 >/dev/null 2>&1
    [ -d "$EXAKIT_JSON_TABLES_VENV" ] && printf 'dry-kept '
    json_tables_uninstall 0 >/dev/null 2>&1
    for _p in "$EXAKIT_JSON_TABLES_VENV" "$EXAKIT_JSON_TABLES_HOME" "$EXAKIT_JSON_TABLES_BIN"; do
        [ -e "$_p" ] && printf 'LEFT ' || printf 'gone '
    done
    manifest_get components.json_tables.version >/dev/null 2>&1 && printf 'record' || printf 'cleared'
) )"
check "uninstall keeps a dry run, then removes every part" "dry-kept gone gone gone cleared" "$_jt_uninst"

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
check "with nothing advertised the module's fallback answers, not a guess" "$EXAKIT_JSON_TABLES_VERSION_FALLBACK" "$( (
    exakit_versions_value() { return 1; }
    exakit_component_latest json-tables 2>/dev/null
) )"
echo "the scheduler's give-up state is visible, not a bare stopped:"
# THE BUG CLASS: the launcher stops after five rapid engine failures - correct -
# but the only trace was a log line nobody whose jobs just stopped was reading.
# The marker it now writes is what turns `exakit status` from "stopped" (reads
# like a choice someone made) into the reason plus the two commands that act on
# it. A deliberate restart clears the marker: a fresh start is a fresh chance.
_SG_HOME="$WORK/sched-giveup"
_sg_out="$( (
    EXAKIT_EXASOL_SCHEDULER_HOME="$_SG_HOME"
    EXAKIT_EXASOL_SCHEDULER_BIN="$_SG_HOME/launcher"
    mkdir -p "$_SG_HOME"
    : > "$_SG_HOME/launcher"; chmod 755 "$_SG_HOME/launcher"
    _exasol_scheduler_pids() { printf ''; }
    printf 'gave up after 5 rapid failures (last exit 7) at earlier\n' > "$_SG_HOME/gave-up"
    exasol_scheduler_status
) )"
has "a gave-up scheduler says so" "gave up after 5 rapid failures" "$_sg_out"
has "and names the diagnosis" "exakit logs exasol-scheduler" "$_sg_out"
check "a start clears the give-up state" "cleared" "$( (
    EXAKIT_EXASOL_SCHEDULER_HOME="$_SG_HOME"
    EXAKIT_EXASOL_SCHEDULER_BIN="$_SG_HOME/launcher"
    printf 'gave up\n' > "$_SG_HOME/gave-up"
    _exasol_scheduler_pids() { printf ''; }
    info() { :; }; ok() { :; }; warn() { :; }
    nohup() { :; }
    exasol_scheduler_start >/dev/null 2>&1 || true
    [ -f "$_SG_HOME/gave-up" ] && echo present || echo cleared
) )"
check "an ordinary stop stays a plain stopped" "stopped" "$( (
    EXAKIT_EXASOL_SCHEDULER_HOME="$_SG_HOME"
    EXAKIT_EXASOL_SCHEDULER_BIN="$_SG_HOME/launcher"
    rm -f "$_SG_HOME/gave-up"
    _exasol_scheduler_pids() { printf ''; }
    exasol_scheduler_status
) )"

echo "data-load's default row when every bundled dataset is in:"
# THE BUG: with nothing left to load from the bundle, the pre-selected row was
# the final "Skip" one -- so Enter did nothing, on the one
# screen whose only remaining purpose is to load a file of your own. The local
# row is what should be waiting under the cursor.
. "$ROOT/setup/lib/exapump.sh"
_dl_probe="$WORK/dl-default-label"
(
    exakit_pending_datasets() { :; }          # everything already loaded
    info() { :; }
    # The screen is a live TABLE now: the defaults are row numbers into its
    # state file, so the probe reads the label of whichever row is pre-ticked.
    ui_table_menu() {
        _dlp_row="${EXAKIT_TABLE_DEFAULTS%%,*}"
        sed -n "${_dlp_row}p" "$1" | cut -d'|' -f2 > "$_dl_probe"
        EXAKIT_TABLE_SELECTION="$EXAKIT_TABLE_DEFAULTS"
    }
    exakit_data_load_select "Skip" >/dev/null 2>&1
)
# The expected value is the label VERBATIM, and it moves when the label moves:
# the folder-loading work widened this row to ", or a folder of them" and left
# the assertion behind, which is what turned main red. Kept as an equality
# check rather than loosened to a prefix - this is the row the menu pre-selects
# and the wording is worth pinning.
check "the local-file row is pre-selected" "A local CSV / Parquet / JSON file, or a folder of them" "$(cat "$_dl_probe" 2>/dev/null)"
lacks "and Skip is not what Enter would take" "Skip" "$(cat "$_dl_probe" 2>/dev/null)"
# The Windows twin draws the same live table now, so its pre-selection is a ROW
# NUMBER in that table rather than an index into a label array. Same bug to
# guard against: with nothing left in the bundle, the row waiting under the
# cursor must be the local-file one and never the opt-out.
_dl_ps1="$(sed -n '/^function New-ExakitDataTable/,/^}/p' "$ROOT/setup/lib/exapump.ps1")"
has "the PowerShell twin pre-ticks the local-file row" \
    '[void]$defaults.Add($script:ExakitTableRowLocal)' "$_dl_ps1"
lacks "...and never the opt-out row" \
    '[void]$defaults.Add($script:ExakitTableRowSkip)' "$_dl_ps1"

echo "data-load routes JSON through the add-on:"
. "$ROOT/setup/lib/exapump.sh"
check "file kinds are classified from the name" "csv parquet json json json csv unknown" "$(
    for _f in a.csv b.parquet c.json d.ndjson e.jsonl.gz f.CSV.gz g.xlsx; do
        printf '%s ' "$(exakit_data_file_kind "$_f")"
    done | sed 's/ $//')"

# Not applicable on this platform: the add-on is not even offered, and the
# reason names the platform rather than leaving the user guessing.
_jl_unsupported="$( (
    json_tables_installed_version() { return 1; }
    json_tables_applicable() { return 1; }
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
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
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
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
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
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
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
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
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
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
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
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
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

echo "== a half-installed add-on can be retried, and Windows can extract =="

DS_PS1="$(cat "$ROOT/setup/lib/dash-server.ps1")"
DS_SH="$(cat "$ROOT/setup/lib/dash-server.sh")"

# A full Windows install ended with "dash-server installer reported: tar
# (child): Cannot connect to C: resolve failed". Two stacked causes:
#
# 1. `tar` off PATH is Git's GNU tar on a developer machine, ahead of Windows'
#    own bsdtar, and GNU tar reads "C:\..." as host:path rsh syntax.
# 2. $ErrorActionPreference is Stop module-wide, so that stderr became a
#    TERMINATING error - which 2>$null does not prevent - and a best-effort
#    data-file top-up took the whole add-on install down with it.
lacks "tar is not taken off PATH"   '& tar -xzf'                        "$DS_PS1"
has   "...it is asked for by name"  'Join-Path $env:SystemRoot "System32\tar.exe"' "$DS_PS1"
has   "...and cannot terminate"     '$ErrorActionPreference = "Continue"'  "$DS_PS1"
has   "...with the code inspected"  '$tarCode = $LASTEXITCODE'             "$DS_PS1"

# That failure left the venv behind but no launcher, and the version check read
# ONLY the venv - so every caller believed the add-on was fully installed:
# the marketplace answered "already present - nothing to install", `exakit
# update dash-server` answered "everything is already current", and starting it
# answered "not installed". No documented command could recover it.
#
# Presence now means USABLE, on both sides. json-tables already took this line.
has "presence needs the record"     'if (-not (Get-ExakitManifestValue "components.dash_server.version")) { return $null }' "$DS_PS1"
has "...and the twin agrees"        '_dsv_recorded="$(manifest_get components.dash_server.version' "$DS_SH"
# ...and the venv is still asked, because neither half alone is evidence.
has "the venv answers the version"  'return (Get-DashServerPackageVersion)'  "$DS_PS1"
has "...and on the shell side"      '    dash_server_package_version'        "$DS_SH"
# The installer asks the venv-only question, because it runs before the
# record exists - asking the strict one there made a good install report
# "the venv cannot report a dash-server version after the install".
has "the installer asks the venv"   'if (-not (Get-DashServerPackageVersion)) {' "$DS_PS1"
has "...and on the shell side"      '_ds_now="$(dash_server_package_version'   "$DS_SH"

echo
echo "a refused lookup is not a missing release:"
# On a real install json-tables failed with "the prebuilt mirror release was not
# found ... run the pkg workflow once to publish it". That release had existed
# since August and held the exact asset that machine needed. GitHub had answered
# 403: its API allows 60 calls an hour unauthenticated, and a full install spends
# them. `curl -f` turns any 4xx into an empty body, so a refusal and an absence
# were indistinguishable, and the remedy named was work that changes nothing.
JT_SH="$(cat "$ROOT/setup/lib/json-tables.sh")"
JT_PS="$(cat "$ROOT/setup/lib/json-tables.ps1")"
CO_SH="$(cat "$ROOT/setup/lib/common.sh")"
has "the shell records the HTTP status"  'EXAKIT_JSON_TABLES_MIRROR_HTTP=' "$JT_SH"
has "...and no longer uses curl -f"      'set -- -sSL --retry 3'          "$JT_SH"
# ONE request serves all three callers. Each reaches the release through $( ),
# so the cache and the status both have to be FILES: a variable would be set in
# a subshell and thrown away, which is the original bug wearing a cache.
check "the release is fetched from one place only" "1" \
    "$(grep -c 'api.github.com' "$ROOT/setup/lib/json-tables.sh")"
has "the document is cached in a file"   'EXAKIT_JSON_TABLES_MIRROR_CACHE=' "$JT_SH"
has "...and so is the status"            '> "$_jmr_c.http"'                 "$JT_SH"
has "...which the caller reads back"     'cat "$(_json_tables_mirror_cache_file).http"' "$JT_SH"
lacks "a refusal is never cached"        'printf %s "$_jmr_http" > "$_jmr_c" ' "$JT_SH"
has "...and answers 403 differently"     '403|429)'                       "$JT_SH"
has "...while keeping the 404 remedy"    'pkg / json-tables'              "$JT_SH"
has "the twin records it too"            'JsonTablesMirrorHttp'           "$JT_PS"
has "...and branches on 403"             '-eq "403"'                      "$JT_PS"
has "a token is honoured on the shell"   'Bearer $GITHUB_TOKEN'           "$JT_SH"
has "...and on Windows"                  'Bearer $($env:GITHUB_TOKEN)'    "$JT_PS"
# The failure is said ONCE: the row says it, the module's own reason said why,
# and the note under the table is gone. Asserted on what replaced it, not on the
# wording that was removed -- that wording had already been changed once by
# another hand, so a needle aimed at it tests nothing.
has "the add-on failure is only logged"  '_exakit_log_file "WARN  $_mp_id did not finish installing"' "$CO_SH"
lacks "no note is printed under the frame" '_exakit_addon_note warn \\' "$CO_SH"

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
check "...and lowered on both ends of the loop" "2" \
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

echo
echo "the Windows registry dispatches the same per-add-on hooks as the shell:"
# THE PARITY GAP THIS PINS: the PS registry had no field for the per-add-on
# hooks the shell registry dispatches to. Get-JsonTablesSystemPresent and
# Get-ExasolSchedulerSystemPresent were dead code, exasol-vscode had no
# Windows detector at all (the kit adopted and later DELETED a user's own
# Marketplace extension), "never offered twice" held on three platforms and
# failed on Windows, and "latest" was always empty there so the update check
# could not see either binary add-on.
COMMON_PS_TP="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "the registry declares json-tables' detector"   'SystemPresentFn = "Get-JsonTablesSystemPresent"' "$COMMON_PS_TP"
has "...and the scheduler's"                        'SystemPresentFn = "Get-ExasolSchedulerSystemPresent"' "$COMMON_PS_TP"
has "...and the VS Code extension's"                'SystemPresentFn = "Test-ExasolVscodeSystemPresent"' "$COMMON_PS_TP"
has "the detector exists for VS Code"               'function Test-ExasolVscodeSystemPresent' "$(cat "$ROOT/setup/lib/exasol-vscode.ps1")"
has "the present probe dispatches the hook first"   '$addon.SystemPresentFn' "$COMMON_PS_TP"
has "the registry declares json-tables' latest"     'LatestFn     = "Get-JsonTablesLatest"' "$COMMON_PS_TP"
has "...and the scheduler's"                        'LatestFn     = "Get-ExasolSchedulerLatest"' "$COMMON_PS_TP"
has "the latest lookup dispatches the hook first"   '$addon.LatestFn' "$COMMON_PS_TP"
# ADD-01/CPY-02: "recorded, so every command agrees" was false on Windows -
# the module never read the port back. The audit's own zero-occurrence check,
# inverted into the guard.
check "dash-server.ps1 reads the recorded port back" "1" \
    "$(grep -c 'Get-ExakitManifestValue "components.dash_server.port"' "$ROOT/setup/lib/dash-server.ps1")"
has "...resolved before every entry point" 'function Resolve-DashServerPort' "$(cat "$ROOT/setup/lib/dash-server.ps1")"

# ADD-09: json_tables_update returns early when the installed build already IS
# the advertised one; Update-JsonTables had no such comparison and no
# already-installed guard behind it, so `exakit update` on Windows re-downloaded
# the wheel, the ingest engine and the compiled cargo shim on every run while
# macOS and Linux did nothing. The two halves also have to AGREE in the sentence
# an agent parses.
JT_PS_TP="$(cat "$ROOT/setup/lib/json-tables.ps1")"
JT_SH_TP="$(cat "$ROOT/setup/lib/json-tables.sh")"
has "Update-JsonTables compares the installed build" \
    '$current -and $current -eq $available' "$JT_PS_TP"
has "...and stops instead of re-downloading" \
    'Ok "JSON Tables is already current ($current)"' "$JT_PS_TP"
has "...rewriting the launcher first, like the shell half" \
    '[void](Write-JsonTablesLauncher)' "$JT_PS_TP"
has "the shell half says the same words" \
    'JSON Tables is already current' "$JT_SH_TP"

# ADD-11: the code CLI drains inherited stdin, which ate the marketplace's own
# row loop and silently dropped every add-on listed after exasol-vscode. The
# shell half closes stdin (</dev/null); the Windows half must redirect it too -
# code.cmd is a batch wrapper around the same Node process. CI never catches
# this: a runner has no VS Code, so the CLI is never run.
has "the code CLI cannot reach the console on Windows" \
    '$null | & $cli @Arguments' "$(cat "$ROOT/setup/lib/exasol-vscode.ps1")"

echo "the dash-server launcher never carries an authoritative port:"
# BAKED-IN PORTS DRIFT, and this one did. The generated launcher used to hold
# the port it was written with - in its pre-flight probe AND in the bind
# variable it exports - while the kit records its own choice separately. A
# launcher written when the port was 5102 kept probing and binding 5102 while
# the kit passed --port 5100 and waited on it: the launcher answered "already
# running: 5102", the kit answered "did not answer on 5100", and
# `exakit status` called a live add-on stopped.
#
# The launcher now resolves the port exactly as the kit does - argv, then the
# kit's record, then the plain default - and holds no copy of its own. These
# checks generate one with 5102 as its GENERATION port and then prove every
# resolution step ignores that number.
_dsp="$WORK/dsport"; mkdir -p "$_dsp/bin" "$_dsp/venv" "$_dsp/home"
( EXAKIT_BIN_DIR="$_dsp/bin"
  EXAKIT_DASH_SERVER_BIN="$_dsp/bin/dash-server"
  EXAKIT_DASH_SERVER_VENV="$_dsp/venv"
  EXAKIT_DASH_SERVER_HOME="$_dsp"
  EXAKIT_DASH_SERVER_PORT=5102
  _EXAKIT_DS_PORT_EXPLICIT=1
  _EXAKIT_DS_PORT_RESOLVED=1
  dash_server_write_launcher >/dev/null 2>&1 ) || true
check "the launcher was generated" "yes" \
    "$([ -x "$_dsp/bin/dash-server" ] && echo yes || echo no)"
# No literal port survives in the probe or the bind - those are the two lines
# that drifted, and a number in either brings the bug back.
check "no literal port in its probes or its bind" "0" \
    "$(grep -cE 'iTCP:[0-9]|127\.0\.0\.1:[0-9]+/mcp|DASH_SERVER_PORT:=[0-9]' "$_dsp/bin/dash-server" 2>/dev/null | head -1)"
# Which port it RESOLVES, observed rather than read: stubbed lsof/ps report a
# foreign holder for whatever port is probed, so the launcher names that port in
# its refusal. Hermetic - no port is bound and nothing is started.
mkdir -p "$_dsp/probe"
printf '#!/bin/sh\nprintf "4242\\n"\n' > "$_dsp/probe/lsof"
printf '#!/bin/sh\nprintf "/usr/bin/some-unrelated-app\\n"\n' > "$_dsp/probe/ps"
chmod +x "$_dsp/probe/lsof" "$_dsp/probe/ps"
_dsp_port_of() { # _dsp_port_of <manifest-port|-> [args...] -> the port it named
    if [ "$1" = "-" ]; then rm -f "$_dsp/home/manifest.json"
    else printf '{\n  "components": {\n    "dash_server": {\n      "port": %s\n    }\n  }\n}\n' "$1" > "$_dsp/home/manifest.json"
    fi
    shift
    PATH="$_dsp/probe:$PATH" EXAKIT_HOME="$_dsp/home" sh "$_dsp/bin/dash-server" "$@" 2>&1 |
        sed -n 's/^Port \([0-9]*\) is held.*/\1/p' | head -1
}
check "a bare run obeys the kit's record, not the generation port" "5100" "$(_dsp_port_of 5100)"
check "...even when the record moved somewhere else entirely" "5311" "$(_dsp_port_of 5311)"
check "--port on the command line outranks the record" "5199" "$(_dsp_port_of 5100 --host 127.0.0.1 --port 5199)"
check "--port=N is understood too" "5177" "$(_dsp_port_of 5100 --port=5177)"
check "with no record at all it falls back to the plain default" "5100" "$(_dsp_port_of -)"
# The other half of the record's honesty: a successful start writes back the
# port that actually bound, so status and the launcher's fallback cannot be
# reading an intention that never happened.
has "a successful start records the port it bound" \
    'manifest_set components.dash_server.port "$EXAKIT_DASH_SERVER_PORT" 2>/dev/null' \
    "$(cat "$ROOT/setup/lib/dash-server.sh")"

# THE WINDOWS LAUNCHER HAD NONE OF THIS, and that is why it drifted: every
# check above exercises the sh launcher by running it, and cmd cannot be run
# here, so the .cmd twin went untested and quietly stopped reading argv at all.
# The kit starts it as `dash-server.cmd --host 127.0.0.1 --port <n>` and then
# waits on <n>; with argv unread, the wrapper's own pre-flight probed whatever
# its manifest scan turned up and could answer "already running" about a port
# nobody had asked about, while the kit reported "did not answer on 5100".
# Read from the generator's source, which is the closest this host can get to
# running cmd.
_dsw="$(cat "$ROOT/setup/lib/dash-server.ps1")"
echo "the Windows dash-server launcher resolves the port the same way:"
has "it walks argv for --port before anything else" \
    'if /i `"%~1`"==`"--port`" goto exakit_ds_argv_want' "$_dsw"
has "...and understands --port=N too" \
    'if `"%EXAKIT_DS_ARG:~0,7%`"==`"--port=`" goto exakit_ds_argv_eq' "$_dsw"
check "the argv walk runs before the manifest is consulted" "yes" \
    "$(printf '%s' "$_dsw" | awk '/exakit_ds_argv_done/{a=NR} /EXAKIT_DS_MANIFEST=%USERPROFILE%/{if(a&&NR>a){print "yes";exit}}' | head -1)"
has "the manifest scan takes the FIRST port key, not the last" \
    'do if not defined EXAKIT_DS_PORT set `"EXAKIT_DS_PORT=%%P`"' "$_dsw"
has "a non-numeric value is discarded rather than bound" \
    'for /f `"delims=0123456789`" %%R in' "$_dsw"
# `shift` does not touch %*, so walking argv must not cost the server its
# arguments - the kit's --host and --port still have to reach it.
has "the whole command line still reaches the server after the walk" \
    '`"$exe`" %*' "$_dsw"
# Same rule as the sh launcher: the probe and the bind carry no port of their
# own, only the one resolved above.
check "no literal port in its probe or its bind" "0" \
    "$(printf '%s' "$_dsw" | grep -cE '127\.0\.0\.1:[0-9]+/mcp|DASH_SERVER_PORT=[0-9]+`')"

echo "a dash-server that does not come up says why:"
# "see the log" IS NOT A DIAGNOSIS - and on the Windows half the named log had
# nothing in it, because the validation probe was started with no redirection
# at all. Both halves now redirect to their own file and put the reason on
# screen. The extractor is exercised for real: a traceback must yield its
# exception, not its first frame.
_dsr="$WORK/dsreason"; mkdir -p "$_dsr"
printf 'Serving on http://127.0.0.1:5100\nTraceback (most recent call last):\n  File "x.py", line 1\nOSError: [Errno 98] Address already in use\n' > "$_dsr/trace.log"
printf 'dash-server is already running: http://127.0.0.1:8563 (MCP: /mcp)\n' > "$_dsr/wrongport.log"
: > "$_dsr/empty.log"
check "a traceback yields its exception, not its first frame" \
    "OSError: [Errno 98] Address already in use" "$(_dash_server_failure_reason "$_dsr/trace.log")"
check "a launcher that mis-resolved the port is quoted verbatim" \
    "dash-server is already running: http://127.0.0.1:8563 (MCP: /mcp)" \
    "$(_dash_server_failure_reason "$_dsr/wrongport.log")"
check "an empty log yields nothing, so the caller falls back" "" \
    "$(_dash_server_failure_reason "$_dsr/empty.log")"
check "a log that is not there yields nothing either" "" \
    "$(_dash_server_failure_reason "$_dsr/absent.log")"
has "the validation probe redirects somewhere it can read back" \
    'dash-server-validate.log' "$(cat "$ROOT/setup/lib/dash-server.sh")"
has "...and so does the Windows twin, which redirected nowhere at all" \
    'dash-server-validate.log' "$_dsw"
has "the Windows twin has the same extractor" \
    'function Get-DashServerFailureReason' "$_dsw"

echo "dbt-exasol is graded on its connection, not on the machine's git:"
# `dbt debug` folds a `git --help` check into the same pass/fail as the
# connection test, and without git it raises BEFORE the connection is tried.
# Windows ships no git, so every fresh Windows install reported "dbt could not
# connect to the database" about a database dbt never opened, while the same
# kit passed on every developer machine. `--connection` is dbt's own flag for
# this. Verified against dbt 1.12.5: no git -> `debug` exits 2, `debug
# --connection` exits 0 with "Connection test: [OK connection ok]".
has "the shell half asks dbt for the connection alone" \
    'exakit_run_bounded 60 "$_ddo_dbt" debug --connection' "$(cat "$ROOT/setup/lib/dbt-exasol.sh")"
has "the Windows twin asks the same question" \
    'Invoke-ExakitLogged $exe "debug" "--connection"' "$(cat "$ROOT/setup/lib/dbt-exasol.ps1")"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
