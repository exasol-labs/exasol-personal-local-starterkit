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
# The versions manifest is the other one. exakit_update asks upstream for
# versions.json before it applies anything, so the "update repair path" cases
# fetched it from raw.githubusercontent.com and the rest of the run then read
# whatever main carried that day. A non-https URL is refused without a request
# (as in tests/versions-manifest.sh), and resolution falls back to the
# checkout's own versions.json.
EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
export EXAKIT_VERSIONS_URL
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
check "addons list carries every registered add-on" "dash-server dbt-exasol exasol-scheduler exasol-vscode json-tables semantic-views" \
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
check "not installed -> excluded from all" "exakit runtime exapump uv mcp pyexasol skills" \
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
check "installed -> joins update all" "exakit runtime exapump uv mcp pyexasol skills dash-server" \
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
check "excluded from update all again" "exakit runtime exapump uv mcp pyexasol skills" \
    "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"

echo "EXAKIT_MARKETPLACE_ADDONS (the non-interactive contract):"
# The install functions are stubbed: this proves the routing, not pip.
run_menu() ( # run_menu <env-answer> — echoes "installed:<ids>" + menu output
    . "$ROOT/tests/lib/mock-addon-events.sh"
    : > "$WORK/called"
    for _rm_id in $(exakit_marketplace_addons | cut -d'|' -f1); do
        _rm_fn="$(printf '%s' "$_rm_id" | tr '-' '_')"
        eval "${_rm_fn}_install() { printf '%s ' '$_rm_id' >> \"\$WORK/called\"; }"
        eval "${_rm_fn}_summary() { :; }"
    done
    EXAKIT_MARKETPLACE_ADDONS="$1"
    exakit_marketplace_menu >/dev/null 2>&1
    printf 'rc=%s called=%s' "$?" "$(sed 's/ $//' "$WORK/called")"
)
check "none installs nothing" "rc=0 called=" "$(run_menu none)"
check "naming one addon installs only it" "rc=0 called=dash-server" "$(run_menu dash-server)"
# semantic-views installs into the kit's database, and this test's kit records none: not applicable here, so
# "all" skips it.
check "all installs every pending addon" "rc=0 called=dash-server dbt-exasol exasol-scheduler exasol-vscode json-tables" "$(run_menu all)"
_unknown_out="$( (run_menu not-a-tool) 2>&1 || true)"
check "an unknown id refuses" "yes" "$( (EXAKIT_MARKETPLACE_ADDONS=not-a-tool exakit_marketplace_menu >/dev/null 2>&1); [ $? -ne 0 ] && echo yes || echo no )"
# An installer that fails must not report success.
check "a failing installer surfaces" "rc=1" "$( (
    . "$ROOT/tests/lib/mock-addon-events.sh"
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
# The uninstall is the one exception: there dash-server is the name of a folder
# under the kit home whose dashboards it keeps, not a component id.
check "common.sh carries no dash-server case arm" "0" "$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { f = $1 }
    /dash-server\)/ && f != "exakit_uninstall_run()" { n++ } END { print n + 0 }' "$ROOT/setup/lib/common.sh")"

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

# Which repository to ask is resolved OFFLINE, from the catalog's GitHub block
# the kit ships -- so a cold, network-less machine still knows the answer exists.
check "repo comes from the catalog's GitHub block" "exasol-labs/dash-server" "$(_exakit_addon_repo dash-server)"
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
check "sanitiser strips C1 controls and bidi overrides too (SEC-10)" "Safe [31mred evil text ok" \
    "$(printf 'Safe\302\233[31mred \342\200\256evil\342\201\247 text ok' | _exakit_about_sanitise)"
_sec18_home="$(mktemp -d)"
_sec18_out="$( (EXAKIT_ABOUT_CACHE_DIR="$_sec18_home"; mkdir -p "$_sec18_home"
    printf 'planted\033[2J\033]8;;http://evil.example\033\\link\033]8;;\033\\ text\nname\nhttps://github.com/a/b\nfalse\n%s\n' \
        "$(_exakit_addon_repo dash-server)" > "$(_exakit_about_cache_path dash-server)"
    exakit_marketplace_addon_description dash-server; _exakit_marketplace_addon_about_offline dash-server) 2>&1)"
check "a cached About is cleaned again when it is read (SEC-18)" "plantedlink text|plantedlink text" \
    "$(printf '%s' "$_sec18_out" | tr '\n' '|' | sed 's/|$//')"
rm -rf "$_sec18_home"
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

# Offline is this suite's default. With nothing cached the answer is the
# catalog's copy of the repository's GitHub About, as tools/addon_github.py
# wrote it.
check "offline falls back to the catalog's GitHub About" \
    "$(python3 -c 'import json,sys; print(next(r["github"]["about"] for r in json.load(open(sys.argv[1]))["addons"] if r["id"] == "exasol-vscode"))' "$ROOT/marketplace/catalog.json")" \
    "$(exakit_marketplace_addon_description exasol-vscode)"
check "and so do the name and the link" "exasol-json-tables|exasol-json-tables (json-tables)|https://github.com/exasol-labs/exasol-json-tables" \
    "$(exakit_marketplace_addon_name json-tables)|$(exakit_marketplace_addon_label json-tables)|$(exakit_marketplace_addon_url json-tables)"
check "a name that matches its id is not repeated" "dbt-exasol" "$(exakit_marketplace_addon_label dbt-exasol)"
check "and nothing was cached by that" "no" \
    "$([ -f "$(_exakit_about_cache_path exasol-vscode)" ] && echo yes || echo no)"
# Nothing cached AND no document: still a usable cell, never a blank one.
check "with no About and no document it points at help" "Details: exakit help ghost" \
    "$(exakit_marketplace_addon_description ghost)"

mkdir -p "$EXAKIT_ABOUT_CACHE_DIR"
printf 'Cached About line\n\n\n\n%s\n' "$(_exakit_addon_repo dash-server)" > "$(_exakit_about_cache_path dash-server)"
check "a fresh cache answers with no lookup" "Cached About line" \
    "$(exakit_marketplace_addon_description dash-server)"

# A stale cache plus an unreachable endpoint: old wording beats an empty column.
# The endpoint is a dead local port, so no test here leaves the machine.
touch -t 200001010000 "$(_exakit_about_cache_path dash-server)"
check "a stale cache survives a failed lookup" "Cached About line" "$( (
    EXAKIT_ABOUT_OFFLINE=0; EXAKIT_ABOUT_URL="https://127.0.0.1:9/repos"
    exakit_marketplace_addon_description dash-server ) )"

# A screen never looks anything up: only the install's offer and exakit update
# do (_exakit_marketplace_warm_about). A stale cache is shown as it is, and no
# attempt is even stamped.
check "a screen makes no lookup, however old the cache" "Cached About line|no attempt" "$( (
    EXAKIT_ABOUT_OFFLINE=0; EXAKIT_ABOUT_URL="https://127.0.0.1:9/repos"
    printf '%s|' "$(exakit_marketplace_addon_description dash-server)"
    [ -f "$EXAKIT_ABOUT_CACHE_DIR/.attempt-dash-server" ] && echo attempted || echo "no attempt" ) )"

# What the last lookup saw wins over the catalog: a renamed repository shows its
# new name and link; an archived one says so. A cache line that is not the plain
# shape is ignored rather than shown.
printf 'Renamed About\nnew-scheduler\nhttps://github.com/exasol-labs/new-scheduler\ntrue\n%s\n' \
    "$(_exakit_addon_repo exasol-scheduler)" > "$(_exakit_about_cache_path exasol-scheduler)"
check "a renamed repository shows its new name and link" "new-scheduler (exasol-scheduler)|https://github.com/exasol-labs/new-scheduler" \
    "$(exakit_marketplace_addon_label exasol-scheduler)|$(exakit_marketplace_addon_url exasol-scheduler)"
check "an archived repository says so" "Renamed About (archived on GitHub)" \
    "$(exakit_marketplace_addon_description exasol-scheduler)"
printf 'About\nbad name;rm\nhttps://evil.example/x\nfalse\n%s\n' "$(_exakit_addon_repo exasol-scheduler)" > "$(_exakit_about_cache_path exasol-scheduler)"
check "a tampered cache falls back to the catalog's name and link" "exasol-scheduler|https://github.com/exasol-labs/exasol-scheduler" \
    "$(exakit_marketplace_addon_label exasol-scheduler)|$(exakit_marketplace_addon_url exasol-scheduler)"
# DAY-05: the cache is keyed by id; lines asked of another repository - a kit
# update repointed the add-on - or written before line 5 are not this add-on's.
printf 'Old repo About\nold-name\nhttps://github.com/someone/old-name\nfalse\nsomeone/old-name\n' > "$(_exakit_about_cache_path exasol-scheduler)"
check "a cache from the add-on's previous repository is not shown (DAY-05)" "exasol-scheduler|https://github.com/exasol-labs/exasol-scheduler" \
    "$(exakit_marketplace_addon_label exasol-scheduler)|$(exakit_marketplace_addon_url exasol-scheduler)"
lacks "...nor its About" "Old repo About" "$(exakit_marketplace_addon_description exasol-scheduler)"
printf 'Four-line About\nexasol-scheduler\nhttps://github.com/exasol-labs/exasol-scheduler\nfalse\n' > "$(_exakit_about_cache_path exasol-scheduler)"
lacks "...nor a cache from before line 5 named its repository" "Four-line About" "$(exakit_marketplace_addon_description exasol-scheduler)"
rm -f "$(_exakit_about_cache_path exasol-scheduler)"

# GitHub out of reach: the round stops at the first request that gets no answer,
# instead of every add-on waiting out its own timeout; screens carry on with the
# catalog's copy.
check "an unreachable GitHub stops the lookup round after one request" "1" "$( (
    EXAKIT_ABOUT_OFFLINE=0; EXAKIT_ABOUT_URL="https://127.0.0.1:9/repos"; EXAKIT_ABOUT_TTL=0
    rm -f "$EXAKIT_ABOUT_CACHE_DIR"/.attempt-* 2>/dev/null
    _exakit_marketplace_warm_about all >/dev/null 2>&1
    ls -a "$EXAKIT_ABOUT_CACHE_DIR" | grep -c '^\.attempt-' ) )"

# The attempt stamp is written BEFORE the request, so one attempt per id per TTL
# is made whatever the answer -- this is what keeps a rate-limited or offline
# machine from paying a timeout on every single run.
check "a failed lookup is not retried within the TTL" "first=3 second=2" "$( (
    EXAKIT_ABOUT_OFFLINE=0; EXAKIT_ABOUT_URL="https://127.0.0.1:9/repos"
    _exakit_about_fetch exasol-vscode >/dev/null 2>&1; printf 'first=%s ' "$?"
    _exakit_about_fetch exasol-vscode >/dev/null 2>&1; printf 'second=%s' "$?" ) )"
check "a non-HTTPS endpoint is refused outright" "1" "$( (
    EXAKIT_ABOUT_OFFLINE=0; EXAKIT_ABOUT_URL="http://api.github.com/repos"
    _exakit_about_fetch json-tables >/dev/null 2>&1; printf '%s' "$?" ) )"

# A scripted answer installs without drawing a table, so it must resolve NO
# description at all: that is what keeps agent and CI runs off the network.
check "a scripted run resolves no description" "rc=0 looked=0" "$( (
    . "$ROOT/tests/lib/mock-addon-events.sh"
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
# Under --json the same run reports the add-on as current, not updated: the
# version did not move. tests/update-targets-ps.ps1 holds Windows to this row.
: > "$WORK/hook-marker"
_rp_json="$( ( exakit_component_current() { printf '0.1.0\n'; }
  exakit_component_available() { printf '0.1.0\n'; }
  exakit_component_is_managed() { return 0; }
  dash_server_update() { printf 'hook-ran' > "$WORK/hook-marker"; }
  exakit_core_update_check() { :; }
  exakit_update dash-server --json ) 2>/dev/null )"
check "explicit --json update reaches the hook too" "hook-ran" "$(cat "$WORK/hook-marker")"
has "...and lists the add-on as current" '"current":["dash-server"]' "$(printf '%s' "$_rp_json" | tr -d ' \n')"
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
    "present=yes pending=no kit-managed=no update-targets=exakit runtime exapump uv mcp pyexasol skills" "$_sys_out"
check "kit launcher on PATH is NOT a system install" "no" "$( (
    cp "$WORK/system-bin/dash-server" "$EXAKIT_BIN_DIR/dash-server"
    PATH="$EXAKIT_BIN_DIR:$PATH"
    _exakit_addon_system_present dash-server && echo yes || echo no
) )"
rm -f "$EXAKIT_BIN_DIR/dash-server"

echo "the closing offer (post-install):"
# Non-interactive (no TTY): never a question - the closing add-ons are installed, not offered.
_offer_notty="$( (_EXAKIT_HOOK_MEMO=""; exakit_marketplace_menu() { printf 'MENU %s\n' "${EXAKIT_MARKETPLACE_ONLY:-}"; }; exakit_marketplace_offer) 2>&1 )"
lacks "no TTY -> no yes/no question" "Explore marketplace" "$_offer_notty"
lacks "no TTY -> no 'marketplace now'" "marketplace now" "$_offer_notty"
# A scripted answer installs without asking.
check "EXAKIT_MARKETPLACE_ADDONS pre-answers the offer" "rc=0 called=dash-server" "$( (
    _EXAKIT_HOOK_MEMO=""      # the offer's add-on answers stay in this subshell, not the run's memo
    . "$ROOT/tests/lib/mock-addon-events.sh"
    dash_server_install() { printf dash-server > "$WORK/called"; }
    dash_server_validate() { return 0; }
    : > "$WORK/called"
    EXAKIT_MARKETPLACE_ADDONS="dash-server"
    exakit_marketplace_offer >/dev/null 2>&1
    printf 'rc=%s called=%s' "$?" "$(cat "$WORK/called")"
) )"
# Everything already present: the offer disappears entirely — no hint, no ask.
check "nothing pending -> the offer is silent" "" "$( (
    _EXAKIT_HOOK_MEMO=""
    PATH="$WORK/system-bin:$PATH"
    cover_every_addon
    exakit_marketplace_offer 2>&1
) )"
# Soft failures: the hint, never the "done and working" celebration.
_offer_soft="$( (
    _EXAKIT_HOOK_MEMO=""
    EXAKIT_SOFT_FAILED="pyexasol"
    exakit_marketplace_menu() { printf 'MENU %s\n' "${EXAKIT_MARKETPLACE_ONLY:-}"; }
    exakit_marketplace_offer 2>&1
) )"
lacks "soft failures -> no victory lap" "done and working" "$_offer_soft"
# Only a database that never installed holds the closing add-ons back.
check "a failed database -> no add-ons at all" "" "$( (
    _EXAKIT_HOOK_MEMO=""
    exakit_soft_failed() { [ "$1" = runtime ]; }
    exakit_marketplace_menu() { printf 'MENU\n'; }
    exakit_marketplace_offer 2>&1
) )"

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
# Columns as wide as the longest name: a fixed 14 let "exasol-scheduler"
# (16) push its state out of line with every other row's.
_covered_cols="$(printf '%s\n' "$_covered_out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Installed|managed outside|not in this kit|disabled in' |
    awk '{ m = match($0, /(Installed|managed outside the kit|not in this kit copy|disabled in this release)/); print m }' | sort -u | wc -l | tr -d ' ')"
check "every covered row's state starts in the same column" "1" "$_covered_cols"
_covered_vers="$(printf '%s\n' "$_covered_out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Installed +[0-9?]' |
    awk '{ m = match($0, /Installed +[0-9?]/); print m + RLENGTH }' | sort -u | wc -l | tr -d ' ')"
check "...and every version too" "1" "$_covered_vers"
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
has "and exits 4 (not installed), as every state query does" "rc=4" "$_nomanifest_out"

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
# The last registry row this machine offers is the canary (a hidden or inapplicable one is never a
# version-table target).
# In a subshell: the add-ons' answers are remembered for the run (the hook memo), and the checks
# below change what those answers would be.
_drain_last="$( (
    _drain_found=""
    for _drain_id in $(exakit_marketplace_addons | cut -d'|' -f1); do
        _exakit_addon_offerable "$_drain_id" && _drain_found="$_drain_id"
    done
    printf '%s' "$_drain_found"
) )"
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
# The preview names what the removal does for every add-on as well: the boot
# entry and the skills it placed (the module's own lines named neither, so
# `exakit uninstall exasol-scheduler --dry-run` listed three paths while the
# removal also took its login entry). A real removal prints no plan lines.
mkdir -p "$WORK/arp-claude/dash-server" "$WORK/arp-agents"
_arp_preview() ( # _arp_preview <dry>
    exakit_record_ownership dash-server kit
    dash_server_uninstall() { :; }
    _exakit_autostart_registered() { [ "$1" = dash-server ]; }
    _exakit_autostart_unregister() { :; }
    exakit_remove_addon_skills() { :; }
    exakit_skills_for_addon() { [ "$1" = dash-server ] && printf 'dash-server\n'; }
    _exakit_skill_is_kits() { return 0; }
    EXAKIT_SKILL_ROOTS="$WORK/arp-claude $WORK/arp-agents"
    _exakit_uninstall_component dash-server "$1" 2>&1
)
has "the add-on preview names its boot entry" "will remove: the automatic-start entry for dash-server" "$(_arp_preview 1)"
has "...and the skill it placed" "will remove: AI skill $WORK/arp-claude/dash-server" "$(_arp_preview 1)"
lacks "...and no root it is not in" "arp-agents" "$(_arp_preview 1)"
lacks "a real removal prints no plan lines" "will remove:" "$(_arp_preview 0)"
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
# The newest run that wrote something, not the empty log the newest command
# (this `exakit logs` itself) just opened (L-02); all empty: the newest.
mkdir -p "$WORK/setuplogs"
printf 'installer line\n' > "$WORK/setuplogs/install-20260810-090000.log"
: > "$WORK/setuplogs/install-20260810-100000.log"
touch -t 202608101000 "$WORK/setuplogs/install-20260810-090000.log"
touch -t 202608101100 "$WORK/setuplogs/install-20260810-100000.log"
check "the setup target is the newest log that is not empty" "$WORK/setuplogs/install-20260810-090000.log" \
    "$(EXAKIT_LOG_DIR="$WORK/setuplogs" exakit_log_targets | grep '^setup|' | cut -d'|' -f4)"
rm -f "$WORK/setuplogs/install-20260810-090000.log"
check "...and when every one is empty, the newest" "$WORK/setuplogs/install-20260810-100000.log" \
    "$(EXAKIT_LOG_DIR="$WORK/setuplogs" exakit_log_targets | grep '^setup|' | cut -d'|' -f4)"
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
# W3-07: an engine's log lines carry colour codes. Off a terminal (a pipe, as
# here) or with NO_COLOR they are dropped from what is printed; the file keeps
# them.
_esc="$(printf '\033')"
printf '%s[32mINFO%s[0m scheduler tick\n' "$_esc" "$_esc" >> "$EXAKIT_HOME/logs/dash-server.log"
_log_piped="$(exakit_logs_show dash-server 0 200 0)"
has "a piped log keeps its text" "INFO scheduler tick" "$_log_piped"
lacks "...without the colour codes" "$_esc" "$_log_piped"
has "...and the file keeps them" "$_esc[32mINFO" "$(cat "$EXAKIT_HOME/logs/dash-server.log")"
check "a colour terminal gets the line as written" "1" \
    "$(UI_FANCY=1 exakit_logs_show dash-server 0 200 0 | grep -c "$_esc")"
# WSL-01: mawk (Debian, Ubuntu, WSL) reads a pipe in 4 KB blocks, so a
# followed log (tail -f | exakit_strip_sgr) showed nothing for minutes. A
# mawk is asked for its interactive mode; any other awk runs as it is. The
# stub stands in for each, and logs how it was called.
_real_awk="$(command -v awk)"
mkdir -p "$WORK/awk-mawk" "$WORK/awk-other"
for _flavour in mawk other; do
    cat > "$WORK/awk-$_flavour/awk" <<AWKSTUB
#!/bin/sh
if [ "\$1" = -W ] && [ "\$2" = version ]; then
    if [ "$_flavour" = mawk ]; then echo "mawk 1.3.4 20240123"; else echo "awk version 20200816"; fi; exit 0
fi
if [ "\$1" = -W ] && [ "\$2" = interactive ]; then echo INTERACTIVE >> "$WORK/awk-$_flavour/calls"; shift 2
else echo PLAIN >> "$WORK/awk-$_flavour/calls"; fi
exec "$_real_awk" "\$@"
AWKSTUB
    chmod +x "$WORK/awk-$_flavour/awk"
done
_wsl01="$(printf '%s[32mINFO%s[0m tick\n' "$_esc" "$_esc" | PATH="$WORK/awk-mawk:$PATH" exakit_strip_sgr)"
check "WSL-01: a mawk strips in its interactive mode (line by line from a pipe)" "INFO tick|INTERACTIVE" \
    "$_wsl01|$(cat "$WORK/awk-mawk/calls" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
_wsl01="$(printf '%s[32mINFO%s[0m tick\n' "$_esc" "$_esc" | PATH="$WORK/awk-other:$PATH" exakit_strip_sgr)"
check "...any other awk as it is" "INFO tick|PLAIN" \
    "$_wsl01|$(cat "$WORK/awk-other/calls" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
has "the overview lists the targets in a table" "Target" "$(exakit_logs_overview)"
has "and names the add-on" "dash-server" "$(exakit_logs_overview)"
# M-12: a target name longer than 22 (autostart-exasol-scheduler) kept the
# column at 22 and pushed its row's What, Size and Updated out of line.
_m12="$( exakit_log_targets() { printf 'autostart-exasol-scheduler|Scheduler at login|file|/nonexistent\nsetup|Setup|file|/nonexistent\n'; }; exakit_logs_overview )"
check "M-12: the What column starts at one place on every row, the longest name included" "1" \
    "$(printf '%s\n' "$_m12" | awk '/^Target /{print index($0, "What")} /^autostart-exasol-scheduler /{print index($0, "Scheduler")} /^setup /{print index($0, "Setup")}' | sort -u | wc -l | tr -d ' ')"
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
    _exakit_uninstall_mcp_processes() { :; }   # never the real process table
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

# Earlier sections leave json-tables recorded as a kit install in this run's
# manifest (the menu tests install it, stubbed): its version and its command.
# The next two sections are about a machine where the kit never installed it -
# a recorded command wins over EXAKIT_JSON_TABLES_BIN by design (owned_path).
forget_json_tables() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    python3 - "$EXAKIT_MANIFEST" <<'FORGETJTEOF'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
doc.get("components", {}).pop("json_tables", None)
doc.get("components", {}).pop("json-tables", None)
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
FORGETJTEOF
}

echo "a 0.2.5 json-tables install after the kit update:"
# Kit 0.2.5's receipt (no ownership field) and its launcher, byte for byte
# (setup/lib/json-tables.sh json_tables_write_launcher at 14df2ecb). The real
# Python add-on answers: the add-on used to read as "not installed" because the
# launcher differs from the one this kit writes, so `exakit version`/`status`
# offered it, `uninstall json-tables` found nothing, and a plain `exakit update`
# never reached it. It is installed, at its version, and needs an update.
_u1_venv="$EXAKIT_HOME/json-tables-venv"
_u1_home="$EXAKIT_HOME/json-tables"
mkdir -p "$_u1_venv/bin" "$_u1_home/libexec" "$_u1_home/shim" "$EXAKIT_BIN_DIR"
rm -f "$_u1_venv/bin/python"          # never write through a uv venv's symlinked python
printf '#!/bin/sh\nexit 0\n' > "$_u1_venv/bin/python"   # `import exasol_json_tables` succeeds
chmod 755 "$_u1_venv/bin/python"
printf '#!/bin/sh\nexit 0\n' > "$_u1_home/libexec/json_to_parquet"
chmod 755 "$_u1_home/libexec/json_to_parquet"
cat > "$EXAKIT_BIN_DIR/exasol-json-tables" <<'U1LAUNCHEREOF'
#!/bin/sh
# exasol-json-tables launcher — generated by the Exasol Personal Local Starter
# Kit. Runs the CLI from its kit-managed venv with the prebuilt ingest engine
# in front of PATH, so no Rust toolchain is needed. Regenerated by:
#   exakit update json-tables
PATH="@SHIMDIR@:$PATH"
export PATH
exec "@VENVBIN@" "$@"
U1LAUNCHEREOF
sed -i.bak -e "s|@SHIMDIR@|$_u1_home/shim|" -e "s|@VENVBIN@|$_u1_venv/bin/exasol-json-tables|" \
    "$EXAKIT_BIN_DIR/exasol-json-tables" && rm -f "$EXAKIT_BIN_DIR/exasol-json-tables.bak"
chmod 755 "$EXAKIT_BIN_DIR/exasol-json-tables"
python3 - "$EXAKIT_MANIFEST" "$_u1_venv" "$_u1_home" "$EXAKIT_BIN_DIR/exasol-json-tables" <<'U1RECEIPTEOF'
import json, sys
path, venv, home, command = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
doc.setdefault("components", {})["json_tables"] = {
    "version": "v0.4.1", "venv": venv, "python": venv + "/bin/python",
    "engine": home + "/libexec/json_to_parquet", "command": command, "validated": True}
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
U1RECEIPTEOF
_exakit_hook_memo_forget
check "it reads as installed, at its version" "v0.4.1" "$(exakit_component_current json-tables 2>/dev/null)"
check "it is among the installed add-ons" "yes" \
    "$(exakit_marketplace_installed_addons | grep -qx json-tables && echo yes || echo no)"
check "it joins a plain exakit update" "yes" \
    "$(exakit_update_targets all | grep -qx json-tables && echo yes || echo no)"
check "and it says it needs an update" "yes" "$(_exakit_addon_needs_update json-tables && echo yes || echo no)"
# A plain `exakit update` reaches its update hook although the version matches
# (the hook rewrites the launcher, validates and registers the module - that
# half is proved against the real module in test_marketplace_json_tables.py),
# and the --json answer lists it as updated, not nowhere.
: > "$WORK/hook-marker"
_u1_json="$( ( json_tables_update() { printf 'hook-ran' > "$WORK/hook-marker"; }
  # The real target list, narrowed to the add-on: the other components and the
  # steps after the loop are not what this proves, and none may touch the machine.
  eval "$(declare -f exakit_update_targets | sed '1s/exakit_update_targets/_u1_real_targets/')"
  exakit_update_targets() { _u1_real_targets "$@" | grep -x json-tables; }
  exakit_core_update_check() { :; }; exakit_autostart_refresh() { :; }; mcp_sidecar_refresh() { :; }
  exakit_update --json ) 2>/dev/null )"
check "a plain exakit update runs its update" "hook-ran" "$(cat "$WORK/hook-marker")"
has "and --json lists it as updated" '"updated":[{"component":"json-tables"' "$(printf '%s' "$_u1_json" | tr -d ' \n')"
check "the version table says a refresh is waiting, not the version it already has" "refresh available" "$( (
    _exakit_version_row json-tables | tr '\036' '\n' | head -1 | cut -d"$(printf '\037')" -f7 ) )"
check "...and counts it as pending, so the screen still ends on exakit update" "1" "$( (
    _exakit_version_row json-tables | tr '\036' '\n' | head -1 | cut -d"$(printf '\037')" -f9 ) )"
_u1_vjson="$( ( EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"; exakit_print_version_table --json ) 2>/dev/null | python3 -c '
import json, sys
row = [r for r in json.load(sys.stdin)["components"] if r["component"] == "json-tables"][0]
print(row["status"], row["remedy"])' 2>&1 )"
check "...and --json still says update_available, with its remedy" "update_available exakit update json-tables" "$_u1_vjson"
# The launcher this kit writes clears it: current again, and skipped by update.
_exakit_hook_memo_forget
python3 - "$ROOT" <<'U1REWRITEEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/marketplace")
from addons import json_tables
from runtime import KitContext
json_tables._write_launchers(KitContext.from_environment(__import__("pathlib").Path(sys.argv[1])))
U1REWRITEEOF
_exakit_hook_memo_forget
check "once rewritten it needs no update" "no" "$(_exakit_addon_needs_update json-tables && echo yes || echo no)"
forget_json_tables
rm -rf "$_u1_venv" "$_u1_home" "$EXAKIT_BIN_DIR/exasol-json-tables"
_exakit_hook_memo_forget

echo "manual installs are never re-offered:"
forget_json_tables
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
    # The row and its continuation line: the Description cell folds a long state.
    exakit_marketplace_menu 2>/dev/null | sed 's/^[^A-Za-z]*//' | grep -A1 '^exasol-json-tables (json-tables)' \
        | tr -s ' |\n' '   ' | grep -o 'managed outside the kit' | head -1
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
        ui_table_menu() { EXAKIT_TABLE_SELECTION="$EXAKIT_TABLE_DEFAULTS"; EXAKIT_TABLE_CONFIRMED=1; }
        exakit_data_load_select "Skip" >/dev/null 2>&1 </dev/null; printf '%s' "$EXAKIT_DATA_LOAD_SELECTION") )"
# Nobody at the table (no terminal): the file row's path question has no one to
# answer it, so the answer is none and the hint names EXAKIT_DATA_FILE.
check "...and with nobody at the table, none" "none" \
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
forget_json_tables
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
# A bare `exakit marketplace` (no preselection) ticks NOTHING: Skip is the
# default, so a bare Enter installs nothing (a Windows run pre-ticked every
# add-on not yet in, and Enter installed them all). "all" still ticks them all.
check "nothing is pre-ticked without a preselection: Skip answers Enter" "5" "$EXAKIT_TABLE_DEFAULTS"
check "...and the cursor's first row is an add-on, not Skip" "demo-alpha" \
    "$(sed -n 2p "$ADDON_STATE_FILE" | cut -d'|' -f2)"
check "with EXAKIT_MARKETPLACE_PRESELECT=all the group and every add-on are pre-ticked" "1,2,3,4" \
    "$( EXAKIT_MARKETPLACE_PRESELECT=all _exakit_addon_table_build "$WORK/addon-table-all" demo-alpha demo-beta demo-gamma >/dev/null
        printf '%s' "$EXAKIT_TABLE_DEFAULTS" )"
check "a persona's preselection ticks only its own" "3" \
    "$( EXAKIT_MARKETPLACE_PRESELECT=demo-beta _exakit_addon_table_build "$WORK/addon-table-p" demo-alpha demo-beta demo-gamma >/dev/null
        printf '%s' "$EXAKIT_TABLE_DEFAULTS" )"
check "the Textual table ticks Skip when nothing is preselected" "present" \
    "$(grep -q 'app.skip = True' "$ROOT/marketplace/ui.py" && grep -q 'elif defaults == {"all"}:' "$ROOT/marketplace/ui.py" && echo present || echo MISSING)"
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
    . "$ROOT/tests/lib/mock-addon-events.sh"
    dash_server_install() { return 0; }
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
    if [ -n "${EXAKIT_TEST_TTY_EVIDENCE:-}" ]; then
        cp "$WORK/addon-tty.out" "$EXAKIT_TEST_TTY_EVIDENCE"
    fi
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

printf '\n== under a REAL terminal, the install table follows the early install ==\n'
# The table is drawn while the early run still goes; its two rows end "Auto
# installed" when it is over, and the row it never started installs after it.
# The follow's keep-alive lines must never reach the screen.
if command -v python3 >/dev/null 2>&1; then
    if python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/addon-early-scenario.sh" "$ROOT" \
            "Marketplace add-ons" '' 1 > "$WORK/early-tty.out" 2>&1; then
        check "one table, followed to the end" "yes" "yes"
    else
        check "one table, followed to the end" "yes" \
            "no: $(grep 'tables on screen\|job announcements\|worst instant' "$WORK/early-tty.out" | tr '\n' ' ' || echo 'replay failed')"
    fi
    EARLY_SCREEN="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/early-tty.out")"
    check "every row ends Auto installed" "3" "$(printf '%s\n' "$EARLY_SCREEN" | grep -c 'Auto installed')"
    lacks "no half-drawn bar left behind" "░" "$EARLY_SCREEN"
    lacks "no per-add-on progress line under the table" "Installing add-on" "$EARLY_SCREEN"
    # The scenario carries the Version column the real menu has, which is what
    # makes the Status column come and go (RAD-01): a shell error is never drawn.
    check "no shell error reaches the screen" "" "$(grep -E 'line [0-9]+:|substring expression' "$WORK/early-tty.out" | head -1)"
else
    check "one table, followed to the end" "skipped" "skipped"
fi

echo "the add-ons table reads its rows once per frame:"
# RAD-01: the animator built a frame from TWO reads of the state file while
# ui_table_set replaced it. The first read found every row idle and withheld
# the Status column, the second measured the row that had just started, and
# the heading's pad came out negative: "substring expression < 0", the
# animator dead on its first frames, the table frozen. A FIFO makes that
# timing certain: its first read is the idle rows, every later one the row
# that started.
_race_out="$( (
    UI_FANCY=1; UI_TICK='✓'; UI_VB='│'; UI_HR='─'
    _rt="$WORK/race"
    printf '%s\n' 'dash-server|dash-server|0|idle|||||||0.2.1|' 'json-tables|exasol-json-tables|0|idle|||||||0.4.1|' > "$_rt.idle"
    cp "$_rt.idle" "$_rt.running"; ui_table_set "$_rt.running" 1 running 0 65 40 installing
    UI_TABLE_TITLE="Marketplace add-ons"; UI_TABLE_COL1="Add-on"; UI_TABLE_COL2="Version"; UI_TABLE_COL3=""; UI_TABLE_COL2_YIELDS=1
    rm -f "$_rt.fifo"; mkfifo "$_rt.fifo"
    ( cat "$_rt.idle" > "$_rt.fifo"; while :; do cat "$_rt.running" > "$_rt.fifo" 2>/dev/null || break; done ) >/dev/null 2>&1 &
    _rw=$!
    ( ui_table_frame "$_rt.fifo" 0; printf 'frame-built lines=%s\n' "$UI_TABLE_LINES" ) 2>&1
    pkill -P "$_rw" 2>/dev/null; kill "$_rw" 2>/dev/null; wait "$_rw" 2>/dev/null
    rm -f "$_rt.fifo" "$_rt.idle" "$_rt.running"
) )"
check "a row starting between the reads: the frame is still built" "frame-built lines=5" "$(printf '%s\n' "$_race_out" | grep '^frame-built')"
lacks "...and no shell error" "substring expression" "$_race_out"

printf '\n== under a REAL terminal, the install table says what each row is (RAD-10) ==\n'
# At 80 columns the install's table has no Description column: a newcomer was
# asked to pick from bare names. The row under the cursor is described under
# the hint (the replay WAITS for each description, so a table without them
# fails). A row in before this run said "Auto installed", and the boxes on the
# rows nobody can pick differed with the path.
if command -v python3 >/dev/null 2>&1; then
    if TTY_REPLAY_WAIT=60 TTY_REPLAY_RAW="$WORK/install-table.raw" python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/addon-install-table-scenario.sh" "$ROOT" \
            "Marketplace add-ons" '\x02Data Build Tool\x03j\x02Lightweight\x03\r' 1 > "$WORK/install-table.out" 2>&1; then
        check "the cursor row's description follows the cursor" "yes" "yes"
    else
        check "the cursor row's description follows the cursor" "yes" \
            "no: $(grep 'WAIT\|tables on screen' "$WORK/install-table.out" | head -2 | tr '\n' ' ')"
    fi
    IT_SCREEN="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/install-table.out")"
    check "the one the early run got in says Auto installed, checked and locked" "yes" \
        "$(printf '%s\n' "$IT_SCREEN" | grep 'dash-server' | grep -q '│ \[✓\] dash-server .*Auto installed' && echo yes || echo no)"
    check "the one in before this run says Installed, with no box" "yes" \
        "$(printf '%s\n' "$IT_SCREEN" | grep 'json-tables' | grep -v 'Auto installed' | grep -q '│     exasol-json-tables .*✓ Installed' && echo yes || echo no)"
else
    check "the cursor row's description follows the cursor" "skipped" "skipped"
fi

printf '\n== under a REAL terminal, the install table asks while its own two install ==\n'
# The two the install puts in on its own (EXAKIT_MARKETPLACE_AUTO_FIRST) were
# drawn "[ ]" with their bars, and the table took no key until they were in
# (about 45 s); after Enter they showed "[ ]" again. Now they are drawn checked
# and locked from the start, the table asks at once (a row is ticked while the
# two still install), and after Enter they stay checked.
if command -v python3 >/dev/null 2>&1; then
    if TTY_REPLAY_WAIT=90 TTY_REPLAY_RAW="$WORK/behind.raw" python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/addon-behind-scenario.sh" "$ROOT" \
            "Marketplace add-ons" '\x02Data Build Tool\x03 \r' 1 > "$WORK/behind.out" 2>&1; then
        check "the install's table with its two installing behind it: one table" "yes" "yes"
    else
        check "the install's table with its two installing behind it: one table" "yes" \
            "no: $(grep 'WAIT\|tables on screen' "$WORK/behind.out" | head -2 | tr '\n' ' ')"
    fi
    BH_SCREEN="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/behind.out")"
    BH_ORDER="$(python3 -c 'import re,sys; t=re.sub(r"\x1b\[[0-9;?<]*[A-Za-z]","",open(sys.argv[1],"rb").read().decode("utf-8","replace")); a=t.find("Space to toggle"); b=t.find("Auto installed"); print("asks first" if 0 <= a < b else "waits (hint at %d, Auto installed at %d)" % (a, b))' "$WORK/behind.raw" 2>&1)"
    check "the table asks before the two are in" "asks first" "$BH_ORDER"
    check "after Enter the two stay checked, with their result" "2" \
        "$(printf '%s\n' "$BH_SCREEN" | grep -cE '│ \[✓\] (dash-server|exasol-json-tables) .*Auto installed')"
    check "the row ticked while they installed is installed after them" "1" \
        "$(printf '%s\n' "$BH_SCREEN" | grep -cE '│ \[✓\] dbt-exasol .*✓ ')"
    has "the Continue row is still the last" "[ ] Continue" "$BH_SCREEN"
else
    check "the install's table with its two installing behind it: one table" "skipped" "skipped"
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
has "the add-on failure is deferred until the table ends" 'warn|$_mpa_id did not finish: ${_mpa_detail%.}. Retry: exakit marketplace $_mpa_id' "$CO_SH"
lacks "no note is printed under the frame" '_exakit_addon_note warn \\' "$CO_SH"

printf '\n== a marketplace --json row always carries version ==\n'
# AGENTS.md and the help promise version on every row; a row for an add-on
# with no known version used to drop the key, so a parser had to probe for it.
has   "the shell row carries version null when unknown"   '"version": null' "$(cat "$ROOT/setup/lib/common.sh")"
has   "the Windows row carries version null when unknown" '$entry.version = $null' "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has   "AGENTS.md says which keys are null when unknown"   '`version`, `repo`, `docs`, `url` and `about` are `null` when unknown' "$(cat "$ROOT/AGENTS.md")"

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
    '$script:ExakitAddonBarLive = [bool](Start-ExakitProgress' "$COMMON_PS_D"
check "...and lowered on success, failure, and cleanup" "3" \
    "$(printf '%s\n' "$COMMON_PS_D" | grep -cF 'Stop-ExakitProgress; $script:ExakitAddonBarLive = $false')"
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
check "the pinned set is exactly json-tables (the kit's own version)" "json-tables" \
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
echo "the install's closing add-ons: Dash Server and JSON Tables, installed when missing, no question:"
offer() { # offer <installed ids> — what exakit_marketplace_offer hands the menu
    (
        _exakit_marketplace_load_modules() { :; }
        _exakit_marketplace_warm_about() { :; }
        _exakit_marketplace_catalog_about() { :; }
        _exakit_addon_offerable() { return 0; }
        _exakit_addon_system_present() { return 1; }
        exakit_marketplace_addon_installed() { case " $INSTALLED_IDS " in *" $1 "*) return 0 ;; esac; return 1; }
        heading() { printf 'HEADING %s\n' "$1"; }
        ui_checkbox_menu() { printf 'ASKED\n'; }
        exakit_marketplace_menu() { printf 'MENU ONLY=[%s] TICKED=[%s] AUTO=[%s]%s\n' "${EXAKIT_MARKETPLACE_ONLY:-}" "${EXAKIT_MARKETPLACE_PRESELECT:-}" "${UI_TABLE_AUTO:-}" "${EXAKIT_MARKETPLACE_AUTO_FIRST:+ FIRST=[$EXAKIT_MARKETPLACE_AUTO_FIRST]}"; }
        UI_FANCY=1
        _exakit_prompt_tty() { [ -n "${OFFER_TTY:-}" ] && printf '/dev/tty'; }
        exakit_marketplace_has_pending() { [ -n "${OFFER_PENDING:-}" ]; }
        unset EXAKIT_MARKETPLACE_ADDONS EXAKIT_SOFT_FAILED EXAKIT_MARKETPLACE_PRESELECT
        INSTALLED_IDS="$1" exakit_marketplace_offer
    )
}
check "both missing: both installed, ticked, no question" \
    "||HEADING Supercharging Exasol with Add-ons|MENU ONLY=[dash-server,json-tables] TICKED=[dash-server,json-tables] AUTO=[1]" "$(offer "" | tr '\n' '|' | sed 's/|$//')"
check "one there: only the other"  "MENU ONLY=[json-tables] TICKED=[json-tables] AUTO=[1]" "$(offer dash-server | grep MENU)"
check "both there: nothing at all" "" "$(offer "dash-server json-tables")"
check "on a terminal, ONE table: every add-on, the two installing first, the rest waiting with nothing ticked" \
    "||HEADING Supercharging Exasol with Add-ons|MENU ONLY=[] TICKED=[none] AUTO=[] FIRST=[dash-server,json-tables]" \
    "$(OFFER_TTY=1 OFFER_PENDING=1 offer "" | tr '\n' '|' | sed 's/|$//')"
check "...also when the two are there already" "||HEADING Supercharging Exasol with Add-ons|MENU ONLY=[] TICKED=[none] AUTO=[]" \
    "$(OFFER_TTY=1 OFFER_PENDING=1 offer "dash-server json-tables" | tr '\n' '|' | sed 's/|$//')"
_ps_offer="$(sed -n '/^function Request-ExakitMarketplaceOffer/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
_ps_auto="$(sed -n '/^function Install-ExakitAutoAddons/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
has "the Windows twin narrows to the missing ones" '$env:EXAKIT_MARKETPLACE_ONLY = ($ids -join' "$_ps_auto"
has "...and draws them ticked, unasked"           '$env:UI_TABLE_AUTO = "1"'                  "$_ps_auto"
has "...then the rest, nothing ticked"            '$env:EXAKIT_MARKETPLACE_PRESELECT = "none"' "$_ps_offer"
lacks "...with no question"                       'Read-ExakitCheckboxMenu'                     "$_ps_offer"

echo "nobody to ask: the install's two in the same flat table, no Select All, Continue last:"
# The product's table has no Select All and ends on Continue; the no-terminal
# rendering (UI_TABLE_AUTO, an agent shell) drew the marketplace's tree with
# "[x] Select All" and "[ ] Skip" instead.
_auto_table="$( (
    _exakit_marketplace_apply() { echo "APPLY $1"; }
    _exakit_marketplace_apply_python() { echo "APPLY $1"; }
    exakit_marketplace_addon_installed() { return 1; }
    _exakit_addon_system_present() { return 1; }
    _exakit_marketplace_addon_present() { return 1; }
    _exakit_addon_offerable() { return 0; }
    EXAKIT_MARKETPLACE_ONLY=dash-server,json-tables EXAKIT_MARKETPLACE_PRESELECT=dash-server,json-tables \
        UI_TABLE_AUTO=1 exakit_marketplace_menu </dev/null 2>&1
) )"
lacks "no Select All row" "Select All" "$_auto_table"
lacks "...no Skip row" "Skip" "$_auto_table"
has "...Continue last" "Continue" "$_auto_table"
has "...and both install" "APPLY dash-server,json-tables" "$_auto_table"

echo "the early background install starts only the add-ons that run on this machine:"
# LNX-07: on a glibc older than the JSON engine's (Ubuntu 22.04, Debian 12,
# RHEL 9) json-tables is not applicable. The background install the installer
# starts during the database step must leave it out, not install it into a
# loader error the user sees as a failed add-on.
early() { # early <ids not applicable here> — what exakit_addons_early_begin starts
    ( _EARLY_NOT_HERE="$1"
      rm -f "$WORK/early.out"
      _exakit_prompt_tty() { printf '/dev/tty'; }
      exakit_soft_failed() { return 1; }
      _exakit_marketplace_load_modules() { :; }
      exakit_marketplace_addon_installed() { return 1; }
      _exakit_addon_system_present() { return 1; }
      _exakit_marketplace_addon_present() { return 1; }
      _exakit_addon_visible() { return 0; }
      _exakit_addon_applicable() { case " $_EARLY_NOT_HERE " in *" $1 "*) return 1 ;; esac; return 0; }
      exakit_marketplace_menu() { printf 'EARLY %s\n' "$EXAKIT_MARKETPLACE_ADDONS" >> "$WORK/early.out"; }
      UI_FANCY=1
      EXAKIT_MARKETPLACE_ADDONS=""
      exakit_addons_early_begin
      [ -z "${EARLY_MARK:-}" ] || printf 'MARK %s\n' "$(cat "$(_exakit_addons_early_dir)/ids" 2>/dev/null)" >> "$WORK/early.out"
      exakit_addons_early_wait
      cat "$WORK/early.out" 2>/dev/null | sort )
}
check "both run here: both start early"          "EARLY dash-server,json-tables" "$(early "")"
check "json-tables does not run here: left out"  "EARLY dash-server"             "$(early json-tables)"
check "neither runs here: nothing starts"        ""                              "$(early "dash-server json-tables")"
check "...and it records what it started (the table follows only those)" "EARLY dash-server|MARK dash-server" \
    "$(EARLY_MARK=1 early json-tables | tr '\n' '|' | sed 's/|$//')"
# RAD-11: the switch that turns the early run off was read in the code and
# named nowhere a user or an agent would look.
check "EXAKIT_ADDONS_EARLY=0: nothing starts early" "" "$(EXAKIT_ADDONS_EARLY=0 early "")"
# MCX-03: a file loaded meanwhile takes its failure reason from the install
# log's lines since the load began, so the early run writes its own log: its uv
# errors and WARN notes could otherwise be named as the load's reason.
_el="$WORK/early-logs"; rm -rf "$_el"; mkdir -p "$_el"; : > "$_el/install-1.log"
( EXAKIT_LOG_FILE="$_el/install-1.log"
  _exakit_prompt_tty() { printf '/dev/tty'; }
  exakit_soft_failed() { return 1; }
  _exakit_marketplace_load_modules() { :; }
  exakit_marketplace_addon_installed() { return 1; }
  _exakit_addon_system_present() { return 1; }
  _exakit_marketplace_addon_present() { return 1; }
  _exakit_addon_visible() { return 0; }
  _exakit_addon_applicable() { return 0; }
  exakit_marketplace_menu() { echo "Error: uv could not download"; _exakit_log_file "WARN  dash-server: installed but not started"; }
  UI_FANCY=1
  EXAKIT_MARKETPLACE_ADDONS=""
  exakit_addons_early_begin
  _exakit_addons_early_log > "$_el/named"
  exakit_addons_early_wait )
check "the early install's lines stay out of the install log" "0" \
    "$(grep -c 'uv could not download\|installed but not started' "$_el/install-1.log")"
check "...they are in its own log" "2" \
    "$(cat "$_el"/addons-early-*.log 2>/dev/null | grep -c 'uv could not download\|installed but not started')"
check "...which is the log it names" "$(ls "$_el"/addons-early-*.log 2>/dev/null)" "$(cat "$_el/named")"
has "...and AGENTS.md documents that switch" '| `EXAKIT_ADDONS_EARLY=0` |' "$(cat "$ROOT/AGENTS.md")"

echo "the add-ons table does not wait for the early install, its rows follow it:"
# Before, the offer sat under its heading with a bare spinner until the early
# run was over - up to a minute, read as a hang. Now the table is drawn at
# once: the rows of the ids that run started say "installing" while it goes,
# and "done" once it is over - only for one that really got in. Everything else
# (a persona's add-on it never started, one it failed) goes to apply.py after it.
fake_early() { # fake_early <ids> <rc> <seconds> — the marks exakit_addons_early_begin leaves, and a run that ends
    _fe_dir="$(_exakit_addons_early_dir)"
    rm -rf "$_fe_dir"; mkdir -p "$_fe_dir"
    printf '%s\n' "$1" > "$_fe_dir/ids"
    ( sleep "$3"; printf '%s\n' "$2" > "$_fe_dir/rc" ) &
    printf '%s\n' "$!" > "$_fe_dir/pid"
}
follow() { # follow <early ids> <early rc> <installed after it> <ids the table follows> — the events, ';'-joined
    ( fake_early "$1" "$2" 1
      _FOLLOW_IN="$3"
      exakit_marketplace_addon_installed() { case " $_FOLLOW_IN " in *" $1 "*) return 0 ;; esac; return 1; }
      _exakit_marketplace_run_python() { printf 'APPLY.PY %s\n' "$3"; }
      _exakit_addons_early_follow "$4" | grep -v '^$' | sed 's/|[0-9]*$//' | tr '\n' ';' | sed 's/;$//'
      wait )
}
check "both in: installing, then done, and no apply.py" \
    "@@EXAKIT|dash-server|installing|;@@EXAKIT|json-tables|installing|;@@EXAKIT|dash-server|done|installed;@@EXAKIT|json-tables|done|installed" \
    "$(follow dash-server,json-tables 0 "dash-server json-tables" dash-server,json-tables)"
check "the run failed: apply.py gets both (it installs what is missing, says the rest is there)" \
    "@@EXAKIT|dash-server|installing|;@@EXAKIT|json-tables|installing|;APPLY.PY dash-server,json-tables" \
    "$(follow dash-server,json-tables 1 "dash-server" dash-server,json-tables)"
check "the run ended well but one is not in: only that one goes to apply.py, never 'done'" \
    "@@EXAKIT|dash-server|installing|;@@EXAKIT|json-tables|installing|;@@EXAKIT|dash-server|done|installed;APPLY.PY json-tables" \
    "$(follow dash-server,json-tables 0 "dash-server" dash-server,json-tables)"
check "a persona's add-on that run never started: apply.py installs it, the follow never says it is done" \
    "@@EXAKIT|dash-server|installing|;@@EXAKIT|json-tables|installing|;@@EXAKIT|dash-server|done|installed;@@EXAKIT|json-tables|done|installed;APPLY.PY exasol-scheduler" \
    "$(follow dash-server,json-tables 0 "dash-server json-tables" dash-server,json-tables,exasol-scheduler)"
# LNX-07: on a glibc older than the JSON engine's, the early run started Dash
# Server alone. JSON Tables gets no "installing" row that would never end.
_follow_lnx="$(follow dash-server 0 "dash-server" dash-server)"
check "json-tables not applicable: only Dash Server is followed" \
    "@@EXAKIT|dash-server|installing|;@@EXAKIT|dash-server|done|installed" "$_follow_lnx"
lacks "...and json-tables never shows installing" "json-tables" "$_follow_lnx"
check "the rows say installing while that run still goes (the table does not wait)" "installing-while-running" "$( (
    fake_early dash-server,json-tables 0 4
    exakit_marketplace_addon_installed() { return 0; }
    _exakit_marketplace_run_python() { :; }
    _exakit_addons_early_follow dash-server,json-tables > "$WORK/follow.out" &
    _fi=0
    while [ "$_fi" -lt 20 ] && ! grep -q '^@@EXAKIT|json-tables|installing' "$WORK/follow.out"; do sleep 0.1; _fi=$(( _fi + 1 )); done
    if grep -q '^@@EXAKIT|json-tables|installing' "$WORK/follow.out" && ! grep -q '|done|' "$WORK/follow.out" && \
       exakit_addons_early_running; then echo installing-while-running; else echo "no: $(tr '\n' ';' < "$WORK/follow.out")"; fi
    wait
) )"
check "...and its marks are gone once it is over" "gone" \
    "$([ -d "$(_exakit_addons_early_dir)" ] && echo left || echo gone)"
# Ctrl-C while the table is up: the table's reader is gone. The follow ends at
# its next write, and a run that then fails does NOT start apply.py for a table
# nobody is watching.
check "the reader gone (Ctrl-C): the follow ends, and starts no apply.py" "ended:no-apply.py" "$( (
    rm -f "$WORK/follow.fifo" "$WORK/follow.applied"
    mkfifo "$WORK/follow.fifo"
    fake_early dash-server 1 2
    exakit_marketplace_addon_installed() { return 1; }
    _exakit_marketplace_run_python() { : > "$WORK/follow.applied"; }
    _exakit_addons_early_follow dash-server > "$WORK/follow.fifo" &
    _fp=$!
    head -n 1 < "$WORK/follow.fifo" >/dev/null
    sleep 1
    if kill -0 "$_fp" 2>/dev/null; then _fs=still-running; else _fs=ended; fi
    wait
    if [ -f "$WORK/follow.applied" ]; then _fa=apply.py-started; else _fa=no-apply.py; fi
    printf '%s:%s' "$_fs" "$_fa"
) )"

# The adapter that paints the table: the follow is its event source while the
# early run goes (EXAKIT_ADDONS_EARLY_FOLLOW, set by the offer), only for the
# install's own table (EXAKIT_ADDON_TABLE_KEEP), and its rows end on "Auto installed".
table_follow() { # table_follow <follow 0|1> <keep 0|1> — each row change: <row> <state> <early run going?> [cell]
    ( rm -f "$WORK/rows"
      fake_early dash-server,json-tables 0 2
      EXAKIT_ADDON_TABLE_STATE="$WORK/follow-table"; : > "$EXAKIT_ADDON_TABLE_STATE"
      EXAKIT_ADDON_TABLE_IDS="dash-server
json-tables"
      _exakit_marketplace_questions() { :; }
      _exakit_marketplace_versions_doc() { :; }
      ui_table_begin() { return 0; }
      ui_table_end() { :; }
      ui_table_detach() { :; }
      exakit_marketplace_addon_installed() { return 0; }
      _exakit_marketplace_run_python() { printf '@@EXAKIT|%s|done|from apply.py|0\n' "$(printf '%s' "$3" | tr ',' '\n' | head -1)"; }
      ui_table_set() {
          printf '%s %s %s%s\n' "$2" "$3" "$(exakit_addons_early_running && echo during || echo after)" \
              "$([ "$3" = done ] && printf ' [%s]' "$(printf '%s' "$8" | sed 's/  *(.*$//; s/ *$//')")" >> "$WORK/rows"
      }
      EXAKIT_ADDONS_EARLY_FOLLOW="$1" EXAKIT_ADDON_TABLE_KEEP="$2" _exakit_marketplace_apply_python dash-server,json-tables >/dev/null 2>&1
      wait
      tr '\n' ';' < "$WORK/rows" | sed 's/;$//' )
}
check "the install's table: rows installing while the early run goes, then Auto installed" \
    "1 running during;2 running during;1 done after [Auto installed];2 done after [Auto installed]" "$(table_follow 1 1)"
check "...no early run to follow: apply.py, as always" "1 done during [Auto installed]" "$(table_follow 0 1)"
check "...never outside the install's own table" "1 done during [from apply.py]" "$(table_follow 1 0)"

echo "the offer: the table follows a running early run, nothing else does:"
offer_early() { # offer_early <tty 0|1> <not applicable ids> — what the menu is handed, and whether the run still went
    ( fake_early "$(printf '%s' "dash-server json-tables" | tr ' ' '\n' | grep -vx "${2:-none}" | tr '\n' ',' | sed 's/,$//')" 0 4
      # OE_OVERDUE=1: that run started longer ago than the waits' ceiling.
      [ "${OE_OVERDUE:-0}" != 1 ] || printf '%s\n' "$(( $(date +%s) - 700 ))" > "$(_exakit_addons_early_dir)/since"
      _OE_NOT="$2"
      _exakit_marketplace_load_modules() { :; }
      _exakit_marketplace_warm_about() { :; }
      _exakit_marketplace_catalog_about() { :; }
      _exakit_addon_offerable() { case " $_OE_NOT " in *" $1 "*) return 1 ;; esac; return 0; }
      _exakit_addon_system_present() { return 1; }
      exakit_marketplace_addon_installed() { return 1; }
      heading() { :; }
      ui_spin_begin() { :; }
      ui_spin_end_all() { :; }
      exakit_marketplace_menu() {
          printf 'MENU FIRST=[%s] ONLY=[%s] FOLLOW=[%s] EARLY=[%s]\n' "${EXAKIT_MARKETPLACE_AUTO_FIRST:-}" \
              "${EXAKIT_MARKETPLACE_ONLY:-}" "${EXAKIT_ADDONS_EARLY_FOLLOW:-}" \
              "$(exakit_addons_early_running && echo running || echo over)"
      }
      UI_FANCY=1
      _OE_TTY="$1"
      _exakit_prompt_tty() { [ "$_OE_TTY" = 1 ] && printf '/dev/tty'; }
      exakit_marketplace_has_pending() { return 0; }
      unset EXAKIT_MARKETPLACE_ADDONS EXAKIT_SOFT_FAILED EXAKIT_MARKETPLACE_PRESELECT
      exakit_marketplace_offer | grep MENU
      printf 'AFTER %s\n' "$([ -d "$(_exakit_addons_early_dir)" ] && echo marks-left || echo marks-gone)" )
}
check "a terminal: the table at once, following that run" \
    "MENU FIRST=[dash-server,json-tables] ONLY=[] FOLLOW=[1] EARLY=[running]|AFTER marks-gone" \
    "$(offer_early 1 "" | tr '\n' '|' | sed 's/|$//')"
check "json-tables not applicable: the table follows Dash Server alone" \
    "MENU FIRST=[dash-server] ONLY=[] FOLLOW=[1] EARLY=[running]|AFTER marks-gone" \
    "$(offer_early 1 json-tables | tr '\n' '|' | sed 's/|$//')"
check "no terminal: it waits for that run first, no second install beside it" \
    "MENU FIRST=[] ONLY=[dash-server,json-tables] FOLLOW=[0] EARLY=[over]|AFTER marks-gone" \
    "$(offer_early 0 "" | tr '\n' '|' | sed 's/|$//')"
check "no terminal, that run still going past the ceiling: no second install of its add-ons, its marks kept" \
    "AFTER marks-left" "$(OE_OVERDUE=1 offer_early 0 "" | tr '\n' '|' | sed 's/|$//')"

echo "the early install: a pid alone never says it is still going, and no wait is for ever:"
# RAD-02: marks a closed terminal left behind, their pid since reused by
# another process of the user, kept the add-ons step "installing" for ever
# (no terminal: silent for ever). The pid is checked with its start time, as
# the install lock does, and every wait has a ceiling.
early_marks() { # early_marks <ids> <pid> <start time> — marks as exakit_addons_early_begin writes them
    _em_dir="$(_exakit_addons_early_dir)"
    rm -rf "$_em_dir"; mkdir -p "$_em_dir"
    printf '%s\n' "$1" > "$_em_dir/ids"
    printf '%s\n%s\n' "$2" "$3" > "$_em_dir/pid"
}
check "marks whose pid is now another process: not running, the wait ends at once, the marks go" "over:0:gone" "$( (
    sleep 20 & _other=$!
    early_marks dash-server "$_other" "Mon Jan  1 00:00:00 2001"
    exakit_addons_early_running && _r=running || _r=over
    rm -f "$WORK/wait.rc"
    ( exakit_addons_early_wait; echo "$?" > "$WORK/wait.rc" ) &
    _wp=$!; _wi=0
    while [ "$_wi" -lt 30 ] && kill -0 "$_wp" 2>/dev/null; do sleep 0.1; _wi=$(( _wi + 1 )); done
    kill "$_wp" 2>/dev/null; kill "$_other" 2>/dev/null; wait 2>/dev/null
    printf '%s:%s:%s' "$_r" "$(cat "$WORK/wait.rc" 2>/dev/null || echo still-waiting)" \
        "$([ -d "$(_exakit_addons_early_dir)" ] && echo left || echo gone)"
) 2>/dev/null )"
check "...the same pid with its own start time: still running" "running" "$( (
    sleep 5 & _own=$!
    early_marks dash-server "$_own" "$(exakit_process_start_time "$_own")"
    exakit_addons_early_running && echo running || echo over
    kill "$_own" 2>/dev/null; wait 2>/dev/null; rm -rf "$(_exakit_addons_early_dir)"
) 2>/dev/null )"
check "past the ceiling the follow ends: its rows say so, no second install of them, the rest to apply.py" \
    "@@EXAKIT|dash-server|installing||;@@EXAKIT|dash-server|failed|still installing in the background after 10 minutes; it finishes on its own (log: $WORK/early.log);APPLY.PY exasol-scheduler|rc=1|marks=left" \
    "$( (
    sleep 20 & _own=$!
    early_marks dash-server "$_own" "$(exakit_process_start_time "$_own")"
    printf '%s\n' "$(( $(date +%s) - 700 ))" > "$(_exakit_addons_early_dir)/since"
    EXAKIT_LOG_FILE="$WORK/early.log"
    _exakit_marketplace_run_python() { printf 'APPLY.PY %s\n' "$3"; }
    _exakit_addons_early_follow dash-server,exasol-scheduler > "$WORK/follow-late.out"; _rc=$?
    printf '%s|rc=%s|marks=%s' "$(grep -v '^$' "$WORK/follow-late.out" | tr '\n' ';' | sed 's/;$//')" "$_rc" \
        "$([ -d "$(_exakit_addons_early_dir)" ] && echo left || echo gone)"
    kill "$_own" 2>/dev/null; wait 2>/dev/null; rm -rf "$(_exakit_addons_early_dir)"
) 2>/dev/null )"
check "...the wait too: it returns, saying the run is still going, and keeps its marks" "1:left" "$( (
    sleep 20 & _own=$!
    early_marks dash-server "$_own" "$(exakit_process_start_time "$_own")"
    printf '%s\n' "$(( $(date +%s) - 700 ))" > "$(_exakit_addons_early_dir)/since"
    rm -f "$WORK/wait.rc"
    ( exakit_addons_early_wait; echo "$?" > "$WORK/wait.rc" ) &
    _wp=$!; _wi=0
    while [ "$_wi" -lt 30 ] && kill -0 "$_wp" 2>/dev/null; do sleep 0.1; _wi=$(( _wi + 1 )); done
    kill "$_wp" 2>/dev/null
    printf '%s:%s' "$(cat "$WORK/wait.rc" 2>/dev/null || echo still-waiting)" "$([ -d "$(_exakit_addons_early_dir)" ] && echo left || echo gone)"
    kill "$_own" 2>/dev/null; wait 2>/dev/null; rm -rf "$(_exakit_addons_early_dir)"
) 2>/dev/null )"

echo "Ctrl-C leaves the early install going: said, and a re-run never starts a second one:"
# RAD-03: the early run ignores SIGINT (a background job of a non-interactive
# shell), so an interrupted install left it installing with nothing on screen
# saying so, and a re-run deleted its marks and started the same add-ons again.
_report_live="$( (
    sleep 5 & _own=$!
    early_marks dash-server,json-tables "$_own" "$(exakit_process_start_time "$_own")"
    EXAKIT_LOG_FILE="$WORK/early.log"
    exakit_addons_early_report 2>&1
    kill "$_own" 2>/dev/null; wait 2>/dev/null; rm -rf "$(_exakit_addons_early_dir)"
) )"
has "one line says the early install is still going, with what and its log" \
    "Still installing in the background: dash-server, json-tables. It finishes on its own; its log: $WORK/early.log" "$_report_live"
check "...and nothing at all when no early run is going" "" "$( ( rm -rf "$(_exakit_addons_early_dir)"; exakit_addons_early_report 2>&1 ) )"
has "an interrupted install (the EXIT trap) says it" "exakit_addons_early_report" \
    "$(sed -n '/^exakit_on_failure()/,/^}/p' "$ROOT/setup/lib/common.sh")"
check "...and so does each installer after its add-ons step (macOS)" "2" "$(grep -c 'exakit_addons_early_report$' "$ROOT/setup/setup-macos.sh")"
check "...and Linux" "2" "$(grep -c 'exakit_addons_early_report$' "$ROOT/setup/setup-linux.sh")"
check "a live early run an interrupted installer left is adopted by the next, never started twice" "MARK json-tables" "$( (
    sleep 2 & _own=$!
    early_marks json-tables "$_own" "$(exakit_process_start_time "$_own")"
    EARLY_MARK=1 early "" | tr '\n' '|' | sed 's/|$//'
    kill "$_own" 2>/dev/null; wait 2>/dev/null
) 2>/dev/null )"
check "stale marks go at installer start, even with the early install off" "gone" "$( (
    early_marks dash-server 999999 ""
    EXAKIT_ADDONS_EARLY=0 exakit_addons_early_begin
    [ -d "$(_exakit_addons_early_dir)" ] && echo left || echo gone
) 2>/dev/null )"
check "a run writes its exit status only into its own marks, never a later run's" "no-rc" "$( (
    _exakit_prompt_tty() { printf '/dev/tty'; }
    exakit_soft_failed() { return 1; }
    _exakit_marketplace_load_modules() { :; }
    exakit_marketplace_addon_installed() { return 1; }
    _exakit_addon_system_present() { return 1; }
    _exakit_addon_offerable() { return 0; }
    exakit_marketplace_menu() { sleep 1; }
    UI_FANCY=1; EXAKIT_MARKETPLACE_ADDONS=""; EXAKIT_ADDONS_EARLY=1
    rm -rf "$(_exakit_addons_early_dir)"
    exakit_addons_early_begin
    _ed="$(_exakit_addons_early_dir)"
    printf 'a later run\n' > "$_ed/run"
    _p="$(sed -n 1p "$_ed/pid")"; _pi=0
    while [ "$_pi" -lt 50 ] && kill -0 "$_p" 2>/dev/null; do sleep 0.1; _pi=$(( _pi + 1 )); done
    [ -f "$_ed/rc" ] && echo rc-written || echo no-rc
    rm -rf "$_ed"
) 2>/dev/null )"
echo "the early install's warnings reach the screen (RAD-04):"
# Its installs run with everything sent to the log, and what the table said
# about them came from the exit status alone: an add-on installed but not
# started read "Auto installed" and nothing else, the remedy only in the log.
check "the follow passes the warning on for one it got in (not its failures)" \
    "@@EXAKIT|dash-server|installing|;@@EXAKIT|dash-server|done|installed;@@EXAKIT|dash-server|warning|installed but did not start: fixture; retry with exakit start" \
    "$( ( fake_early dash-server 0 1
          printf 'ok|dash-server installed\nwarn|dash-server: installed but did not start: fixture; retry with exakit start\nwarn|json-tables did not finish: fixture\n' \
              > "$(_exakit_addons_early_dir)/notes"
          exakit_marketplace_addon_installed() { return 0; }
          _exakit_marketplace_run_python() { printf 'APPLY.PY %s\n' "$3"; }
          _exakit_addons_early_follow dash-server | grep -v '^$' | sed 's/|[0-9]*$//' | tr '\n' ';' | sed 's/;$//'
          wait ) 2>/dev/null )"
check "the early run's own install keeps its notes for that table" \
    "warn|dash-server: installed but did not start: fixture" "$( (
    rm -f "$WORK/early-notes"
    EXAKIT_ADDONS_EARLY_NOTES="$WORK/early-notes"
    _exakit_marketplace_questions() { :; }
    _exakit_marketplace_versions_doc() { :; }
    _exakit_marketplace_run_python() { printf '@@EXAKIT|dash-server|warning|installed but did not start: fixture|\n@@EXAKIT|dash-server|done|ok|0\n'; }
    EXAKIT_ADDON_TABLE_STATE=""
    _exakit_marketplace_apply_python dash-server >/dev/null 2>&1
    grep '^warn|' "$WORK/early-notes"
) )"
_over_warn="$( (
    early_marks dash-server 999999 ""
    printf '0\n' > "$(_exakit_addons_early_dir)/rc"
    printf 'warn|dash-server: installed but did not start: fixture; retry with exakit start\n' > "$(_exakit_addons_early_dir)/notes"
    _exakit_marketplace_load_modules() { :; }
    _exakit_marketplace_warm_about() { :; }
    _exakit_marketplace_catalog_about() { :; }
    _exakit_addon_offerable() { return 0; }
    _exakit_addon_system_present() { return 1; }
    exakit_marketplace_addon_installed() { return 0; }
    heading() { :; }; ui_spin_begin() { :; }; ui_spin_end_all() { :; }
    exakit_marketplace_menu() { echo MENU; }
    exakit_marketplace_has_pending() { return 0; }
    _exakit_prompt_tty() { printf '/dev/tty'; }
    UI_FANCY=1
    unset EXAKIT_MARKETPLACE_ADDONS EXAKIT_SOFT_FAILED EXAKIT_MARKETPLACE_PRESELECT
    exakit_marketplace_offer 2>&1 | tr '\n' '|'
) )"
has "...and one the early run got in before the table: said under it" \
    "MENU|      ! dash-server: installed but did not start: fixture; retry with exakit start|" "$_over_warn"

echo "a failed add-on says how to retry it (RAD-05):"
_fail_out="$( (
    EXAKIT_LOG_FILE="$WORK/fail.log"
    EXAKIT_ADDON_TABLE_STATE="$WORK/fail-table"; : > "$EXAKIT_ADDON_TABLE_STATE"
    EXAKIT_ADDON_TABLE_IDS="json-tables"
    _exakit_marketplace_questions() { :; }
    _exakit_marketplace_versions_doc() { :; }
    ui_table_begin() { return 0; }
    ui_table_end() { :; }
    ui_table_detach() { :; }
    ui_table_set() { [ "$3" = failed ] && printf 'ROW %s\n' "$8"; return 0; }
    _exakit_marketplace_run_python() { printf '@@EXAKIT|json-tables|failed|fixture install failure.|\n'; return 1; }
    _exakit_marketplace_apply_python json-tables 2>&1
) )"
has "the row points below the table" "ROW did not finish — see below" "$_fail_out"
has "...where the reason, the retry and the log are" \
    "json-tables did not finish: fixture install failure. Retry: exakit marketplace json-tables. Log: $WORK/fail.log" "$_fail_out"

echo "the rows following the early install move with its phases (RAD-06):"
# They said "installing" for the whole run, the bar standing at 64% from the
# 40th second on, while the run had long moved on to validating and starting.
check "its phases are replayed for the ids it started, nothing else of it" \
    "@@EXAKIT|dash-server|installing|;@@EXAKIT|dash-server|validating|;@@EXAKIT|dash-server|starting|;@@EXAKIT|dash-server|done|installed" \
    "$( ( fake_early dash-server 0 2
          printf '%s\n' '@@EXAKIT|dash-server|installing|' '@@EXAKIT|dash-server|validating|' '@@EXAKIT|json-tables|validating|' \
              '@@EXAKIT|dash-server|starting|' '@@EXAKIT|dash-server|done|ok' > "$(_exakit_addons_early_dir)/events"
          exakit_marketplace_addon_installed() { return 0; }
          _exakit_marketplace_run_python() { printf 'APPLY.PY %s\n' "$3"; }
          _exakit_addons_early_follow dash-server | grep -v '^$' | sed 's/|[0-9]*$//' | awk '!seen[$0]++' | tr '\n' ';' | sed 's/;$//'
          wait ) 2>/dev/null )"
check "the early run's own install records its phases for that table" \
    "@@EXAKIT|dash-server|validating|;@@EXAKIT|dash-server|done|ok" "$( (
    rm -f "$WORK/early-events"
    EXAKIT_ADDONS_EARLY_EVENTS="$WORK/early-events"
    _exakit_marketplace_questions() { :; }
    _exakit_marketplace_versions_doc() { :; }
    _exakit_marketplace_run_python() { printf '@@EXAKIT|dash-server|validating||\n@@EXAKIT|dash-server|done|ok|0\n'; }
    EXAKIT_ADDON_TABLE_STATE=""
    _exakit_marketplace_apply_python dash-server >/dev/null 2>&1
    tr '\n' ';' < "$WORK/early-events" | sed 's/;$//'
) )"

echo "the add-ons step reads its rows under a labelled spinner, and asks the Python version once (RAD-07):"
_offer_sh="$(sed -n '/^exakit_marketplace_offer()/,/^}/p' "$ROOT/setup/lib/common.sh")"
_offer_ps="$(sed -n '/^function Request-ExakitMarketplaceOffer/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
has "the spinner under the heading says what it waits for" 'ui_spin_begin "Reading the add-ons"' "$_offer_sh"
has "...on Windows too" 'Start-ExakitSpinner "Reading the add-ons"' "$_offer_ps"
lacks "...never a bare one" 'ui_spin_begin ""' "$_offer_sh"
check "the version floor is probed once for the whole step, not in every subshell" "1" "$( (
    mkdir -p "$WORK/pybin"; _real_py="$(command -v python3)"
    printf '#!/bin/sh\ncase "$*" in *"req = tuple"*) echo PROBE >> "%s/py-probes" ;; esac\nexec "%s" "$@"\n' "$WORK" "$_real_py" > "$WORK/pybin/python3"
    chmod +x "$WORK/pybin/python3"; rm -f "$WORK/py-probes"
    PATH="$WORK/pybin:$PATH"; _EXAKIT_SYSTEM_PY_OK=""; EXAKIT_DISABLE_SYSTEM_PYTHON=0
    _exakit_marketplace_load_modules() { :; }
    _exakit_marketplace_warm_about() { :; }
    _exakit_marketplace_catalog_about() { :; }
    _exakit_addon_offerable() { return 0; }
    _exakit_addon_system_present() { return 1; }
    exakit_marketplace_addon_installed() { return 1; }
    heading() { :; }; ui_spin_begin() { :; }; ui_spin_end_all() { :; }
    exakit_marketplace_menu() { ( _exakit_has_system_python3 ); ( _exakit_has_system_python3 ); _x="$(_exakit_has_system_python3; echo)"; }
    exakit_marketplace_has_pending() { return 0; }
    _exakit_prompt_tty() { printf '/dev/tty'; }
    UI_FANCY=1
    unset EXAKIT_MARKETPLACE_ADDONS EXAKIT_SOFT_FAILED EXAKIT_MARKETPLACE_PRESELECT
    rm -rf "$(_exakit_addons_early_dir)"
    ( exakit_marketplace_offer ) >/dev/null 2>&1
    grep -c PROBE "$WORK/py-probes" 2>/dev/null || echo 0
) )"

_ps_offer_body="$(sed -n '/^function Request-ExakitMarketplaceOffer/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
lacks "the Windows offer waits on nothing before its table (no early run there)" 'Start-Sleep' "$_ps_offer_body"
has "...it installs the two in the table at once" '$env:EXAKIT_MARKETPLACE_AUTO_FIRST = ($ids -join' "$_ps_offer_body"

echo "the add-on events are read even when a signal interrupts the FIFO open:"
# A plain `done <fifo` blocks in open() until Python opens the other end; on
# macOS a signal arriving meanwhile failed it with "Interrupted system call",
# losing every event (test_marketplace_worker_cannot_abort_its_parent_animation
# saw it in CI). The read side is opened on its own descriptor, again while the
# worker lives.
_apply_body="$(sed -n '/^_exakit_marketplace_apply_python()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "the FIFO is opened on its own descriptor" 'exec 8<"$_mpa_dir/events"' "$_apply_body"
has "...retried while the open fails" 'while ! { exec 8<"$_mpa_dir/events"; } 2>/dev/null; do' "$_apply_body"
has "...the loop reads that descriptor" '_mpa_seconds <&8; do' "$_apply_body"
lacks "...never a redirect that one signal can fail" 'done <"$_mpa_dir/events"' "$_apply_body"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
