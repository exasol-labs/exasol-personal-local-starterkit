#!/usr/bin/env bash
# marketplace-e2e.sh — end-to-end proof of the marketplace add-on flow, against
# a SANDBOXED kit home (the real ~/.exasol-starter-kit is never touched):
#
#   1. `exakit marketplace` (non-interactive, EXAKIT_MARKETPLACE_ADDONS)
#      installs dash-server from its real GitHub release into a kit-managed
#      venv, writes the launcher, and validates the HTTP control plane.
#   2. The installed add-on joins the update flow: `exakit version` lists it,
#      `exakit update dash-server` answers "already current", `exakit version`
#      reports it, and a second marketplace run offers nothing to install.
#   3. `exakit_uninstall_run` sweeps the venv, state and launcher.
#
# Needs the network (GitHub + PyPI) AND uv, and skips cleanly when any of the
# three is missing, so it is safe in a dry CI environment. It performs a real
# install when they are all present -- that is the point of it. No database is required:
# dash-server starts and answers /mcp without a bootstrapped profile.
#
#   bash tests/marketplace-e2e.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

say()  { printf '\n[marketplace-e2e] %s\n' "$1"; }
skip() { echo "SKIP: $1"; exit 0; }
fail() { echo "[marketplace-e2e] FAIL: $1" >&2; exit 1; }

# uv is REQUIRED, not one of two alternatives. Written as
# `uv || curl || skip`, a machine with curl and no uv skipped nothing and
# walked into the real `uv pip install` below -- which is how an auditor's
# sandbox began a live install while the header promised this suite "SKIPs
# cleanly". curl cannot substitute for uv: it is the venv this test builds.
command -v uv >/dev/null 2>&1 || skip "uv is not available (this suite builds a real venv with it)"
command -v curl >/dev/null 2>&1 || skip "curl is not available"
# Probe the host the install actually downloads from; a HEAD of the release
# page avoids the API rate limit that a busy CI runner can hit.
curl -fsSIL --max-time 10 https://github.com >/dev/null 2>&1 || skip "no network (github.com unreachable)"

SANDBOX="$(mktemp -d)"
trap 'pkill -f "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

export EXAKIT_HOME="$SANDBOX/home"
export EXAKIT_BIN_DIR="$SANDBOX/bin"
# The machine running this may have a REAL dash-server on PATH — the developer's
# own install, or a previous run of this very test. The kit would then read it
# as a system install and decline to offer the add-on, and the sandbox would
# never get one. Rebuild PATH without any directory that carries it.
_clean_path=""
_old_ifs="$IFS"; IFS=:
for _dir in $PATH; do
    [ -x "$_dir/dash-server" ] || _clean_path="${_clean_path:+$_clean_path:}$_dir"
done
IFS="$_old_ifs"
PATH="$_clean_path"
export PATH
# A quiet high port so a dash-server the user already runs on 5100 cannot
# collide with the validation probe.
export EXAKIT_DASH_SERVER_PORT="$((5300 + $$ % 400))"
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"

# A minimal manifest so the CLI accepts commands; runtime credentials let the
# launcher bake its profile bootstrap (the value is fake — dash-server only
# reads it when a dashboard actually connects).
(
    . "$ROOT/setup/lib/common.sh"
    manifest_init >/dev/null
    mkdir -p "$EXAKIT_HOME/credentials"
    printf 'not-a-real-password\n' > "$EXAKIT_HOME/credentials/runtime_sys_password"
    chmod 600 "$EXAKIT_HOME/credentials/runtime_sys_password"
    manifest_set runtime.type "personal"
    manifest_set runtime.dsn "127.0.0.1:8563"
    manifest_set runtime.user "sys"
    manifest_set runtime.password_file "$EXAKIT_HOME/credentials/runtime_sys_password"
) || fail "could not seed the sandbox manifest"

say "1/9 exakit marketplace installs dash-server from its GitHub release"
if ! EXAKIT_MARKETPLACE_ADDONS=dash-server bash "$ROOT/setup/exakit" marketplace; then
    fail "exakit marketplace did not complete"
fi

say "2/9 the venv answers for the advertised version"
_advertised="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    exakit_versions_value components.dash-server.version "$ROOT/versions.json"
)"
_installed="$("$EXAKIT_HOME/dash-server-venv/bin/python" -c \
    'from importlib.metadata import version; print(version("dash-server"))' 2>/dev/null)"
[ -n "$_installed" ] || fail "no dash-server package in the venv"
[ "$_installed" = "$_advertised" ] || fail "installed $_installed but versions.json advertises $_advertised"
[ -x "$EXAKIT_BIN_DIR/dash-server" ] || fail "the dash-server launcher was not written"
grep -q "DASH_SERVER_EXASOL_DSN" "$EXAKIT_BIN_DIR/dash-server" || fail "the launcher carries no profile bootstrap"
grep -q "not-a-real-password" "$EXAKIT_BIN_DIR/dash-server" && fail "the launcher leaked the password"
echo "  ok  dash-server $_installed installed, launcher in place"

say "3/9 validation recorded the live HTTP probe"
_validated="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    manifest_get components.dash_server.validated
)"
[ "$_validated" = "true" ] || fail "components.dash_server.validated is '$_validated', expected true (did the control-plane probe fail?)"
echo "  ok  control plane answered on port $EXAKIT_DASH_SERVER_PORT during validation"

say "4/9 the installed add-on joins the update flow"
_targets="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/dash-server.sh" >/dev/null 2>&1
    exakit_update_targets all | tr '\n' ' '
)"
case "$_targets" in
    *dash-server*) echo "  ok  update all now covers: $_targets" ;;
    *) fail "exakit update targets (all) does not include dash-server: $_targets" ;;
esac
_version_out="$(bash "$ROOT/setup/exakit" version 2>/dev/null)"
case "$_version_out" in
    *dash-server*) echo "  ok  exakit version reports the add-on" ;;
    *) fail "exakit version does not report dash-server" ;;
esac

say "5/9 update says already current; a second marketplace run offers nothing"
_update_out="$(bash "$ROOT/setup/exakit" update dash-server 2>&1)" || fail "exakit update failed: $_update_out"
case "$_update_out" in
    *"already current"*) echo "  ok  exakit update: already current" ;;
    *) fail "unexpected update output: $_update_out" ;;
esac
_second="$(EXAKIT_MARKETPLACE_ADDONS=dash-server bash "$ROOT/setup/exakit" marketplace 2>&1)" || fail "second marketplace run failed"
case "$_second" in
    *"already installed"*|*"already present"*) echo "  ok  second run installs nothing" ;;
    *) fail "second marketplace run did not recognize the install: $_second" ;;
esac

say "6/9 exasol-vscode installs from its release, checksum-verified, into an isolated extensions dir"
# The extension add-on needs VS Code itself; without one this half SKIPs
# rather than failing (the dash-server half above has already proven the
# marketplace machinery). The sandbox extensions dir guarantees the user's
# real VS Code profile is never touched — even on a machine where the
# extension is genuinely installed.
_code_cli="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
    exasol_vscode_code_cli 2>/dev/null
)"
if [ -z "$_code_cli" ]; then
    echo "  --  no VS Code on this machine; the exasol-vscode half is skipped"
else
    export EXAKIT_EXASOL_VSCODE_EXTDIR="$SANDBOX/vscode-ext"
    mkdir -p "$EXAKIT_EXASOL_VSCODE_EXTDIR"
    if ! EXAKIT_MARKETPLACE_ADDONS=exasol-vscode bash "$ROOT/setup/exakit" marketplace; then
        fail "exakit marketplace did not complete for exasol-vscode"
    fi
    _ext_live="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
        _exasol_vscode_live_version
    )"
    _ext_advertised="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        exakit_versions_value components.exasol-vscode.version "$ROOT/versions.json"
    )"
    [ -n "$_ext_live" ] || fail "VS Code does not list the extension in the sandbox extensions dir"
    [ "$_ext_live" = "$_ext_advertised" ] || fail "installed $_ext_live but versions.json advertises $_ext_advertised"
    ls "$EXAKIT_EXASOL_VSCODE_EXTDIR" | grep -qi exasol || fail "nothing landed in the isolated extensions dir"
    echo "  ok  exasol.exasol-vscode@$_ext_live installed into the sandbox extensions dir"

    say "7/9 the extension joins the update flow and a second run offers nothing"
    _ext_update="$(bash "$ROOT/setup/exakit" update exasol-vscode 2>&1)" || fail "exakit update failed: $_ext_update"
    case "$_ext_update" in
        *"already current"*) echo "  ok  exakit update: already current" ;;
        *) fail "unexpected update output: $_ext_update" ;;
    esac
    _ext_targets="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/dash-server.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
        exakit_update_targets all | tr '\n' ' '
    )"
    case "$_ext_targets" in
        *exasol-vscode*) echo "  ok  update all now covers: $_ext_targets" ;;
        *) fail "update targets (all) does not include exasol-vscode: $_ext_targets" ;;
    esac
    _ext_second="$(EXAKIT_MARKETPLACE_ADDONS=exasol-vscode bash "$ROOT/setup/exakit" marketplace 2>&1)" || fail "second exasol-vscode marketplace run failed"
    case "$_ext_second" in
        *"already installed"*|*"already present"*) echo "  ok  second run installs nothing" ;;
        *) fail "second run did not recognize the install: $_ext_second" ;;
    esac
fi

say "8/9 json-tables installs from the kit's own mirror release and a real JSON file becomes tables"
# The whole point of this add-on is the no-Rust story: the engine and the wheel
# are prebuilt by .github/workflows/pkg-json-tables.yml and served from the
# immutable json-tables-<version> release versions.json names. Until that
# workflow has published the advertised build the release does not exist --
# then this stage SKIPS (with the reason) instead of failing, so the rest of
# the e2e stays meaningful.
_jt_repo="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/json-tables.sh" >/dev/null 2>&1
    json_tables_mirror_repo
)"
_jt_tag="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/json-tables.sh" >/dev/null 2>&1
    json_tables_release_tag
)"
if ! curl -fsSIL --max-time 15 \
        "https://github.com/$_jt_repo/releases/tag/$_jt_tag" >/dev/null 2>&1; then
    echo "  SKIP  the $_jt_tag release does not exist in $_jt_repo yet"
    echo "        run the 'pkg / json-tables' workflow once, then this stage goes live"
elif ! (
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/json-tables.sh" >/dev/null 2>&1
    json_tables_applicable
); then
    echo "  SKIP  no prebuilt engine is published for this platform"
else
    _jt_out="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/dash-server.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/json-tables.sh" >/dev/null 2>&1
        EXAKIT_MARKETPLACE_ADDONS="json-tables" exakit_marketplace_menu 2>&1
    )" || fail "the json-tables marketplace install failed: $_jt_out"
    [ -x "$EXAKIT_BIN_DIR/exasol-json-tables" ] || fail "no launcher was written"
    [ -x "$EXAKIT_HOME/json-tables/libexec/json_to_parquet" ] || fail "no prebuilt engine was installed"
    [ -x "$EXAKIT_HOME/json-tables/shim/cargo" ] || fail "no cargo shim was written"
    # Regression guard: the wheel does not declare this file as package data
    # (upstream packaging gap), so without _json_tables_restore_package_data
    # it is silently absent and ingest-and-wrap fails later with FILE-NOT-FOUND.
    _jt_venv_site="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/json-tables.sh" >/dev/null 2>&1
        "$(json_tables_venv_python)" -c 'import exasol_json_tables, os; print(os.path.dirname(exasol_json_tables.__file__))' 2>/dev/null
    )"
    [ -f "$_jt_venv_site/preprocessor_assets/jvs_preprocessor_lib.lua" ] \
        || fail "the preprocessor lua asset is missing -- ingest-and-wrap will fail with FILE-NOT-FOUND"
    echo "  ok  the preprocessor lua asset the wheel omits was restored"
    # The marketplace narrates an add-on install on ONE line, which routes every
    # info/ok underneath it to the LOGFILE (EXAKIT_QUIET_DETAIL). The checksum
    # tick is one of those, so proving the download WAS verified means reading
    # the log, not the screen. Grepping stdout for it made this assertion fail
    # on main for as long as the one-line narration has existed -- the download
    # was verified the whole time, the proof had simply moved.
    _jt_log="$(cat "$EXAKIT_HOME"/logs/*.log 2>/dev/null || true)"
    case "$_jt_out$_jt_log" in
        *"Checksum verified"*) echo "  ok  artifacts were checksum-verified against the release digests" ;;
        *) fail "the install did not verify its downloads: $_jt_out" ;;
    esac
    # ...and it must NOT be on screen: that is the one-line narration working.
    case "$_jt_out" in
        *"Checksum verified"*) fail "the checksum tick reached the screen; the one-line narration is not quieting it" ;;
    esac
    # The real proof: a JSON document goes through the launcher (venv CLI ->
    # cargo shim -> prebuilt engine) and comes out as Parquet. No Rust anywhere.
    _jt_work="$SANDBOX/jt-e2e"
    mkdir -p "$_jt_work"
    printf '[{"id":1,"name":"alpha","tags":["x","y"]},{"id":2,"name":"beta","tags":["z"]}]\n' \
        > "$_jt_work/sample.json"
    PATH="$EXAKIT_BIN_DIR:$PATH" "$EXAKIT_BIN_DIR/exasol-json-tables" ingest \
        --input "$_jt_work/sample.json" --output-dir "$_jt_work/out" \
        >"$_jt_work/ingest.log" 2>&1 \
        || fail "the ingest round trip failed: $(cat "$_jt_work/ingest.log")"
    [ -n "$(find "$_jt_work/out" -name '*.parquet' 2>/dev/null | head -1)" ] \
        || fail "the ingest produced no Parquet"
    echo "  ok  JSON in, Parquet out, through the prebuilt engine (no Rust toolchain on this runner)"
    # And the version recorded is the mirror's own version= line, so
    # the version table can never see an offer it cannot install.
    _jt_recorded="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        manifest_get components.json_tables.version 2>/dev/null
    )"
    [ -n "$_jt_recorded" ] || fail "no version was recorded in the manifest"
    echo "  ok  recorded version: $_jt_recorded (the mirror build)"
fi

say "9/9 uninstall sweeps the add-on"
(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    # The add-on modules must be loaded: the full run dispatches each
    # kit-managed add-on's own uninstall hook (that is what removes the
    # kit-installed VS Code extension).
    . "$ROOT/setup/lib/dash-server.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/json-tables.sh" >/dev/null 2>&1
    # The database/MCP steps are stubbed: this sandbox never had either.
    personal_teardown() { :; }
    exakit_mcp_operation() { :; }
    exakit_uninstall_run 0 >/dev/null 2>&1
    :
)
[ ! -e "$EXAKIT_HOME/dash-server-venv" ] || fail "uninstall left the dash-server venv behind"
[ ! -e "$EXAKIT_BIN_DIR/dash-server" ] || fail "uninstall left the dash-server launcher behind"
[ ! -e "$EXAKIT_HOME/json-tables-venv" ] || fail "uninstall left the json-tables venv behind"
[ ! -e "$EXAKIT_HOME/json-tables" ] || fail "uninstall left the json-tables engine/shim behind"
[ ! -e "$EXAKIT_BIN_DIR/exasol-json-tables" ] || fail "uninstall left the json-tables launcher behind"
echo "  ok  venv, state and launcher removed"
# The KIT-INSTALLED extension goes with the kit: the full uninstall runs the
# add-on's own hook (VS Code's --uninstall-extension) before the sweep. VS
# Code's LISTING is the truth here — uninstall updates extensions.json
# immediately but defers deleting the folder until its next cleanup pass, so
# an ls of the extensions dir would report a ghost. A copy the user installed
# from the VS Code Marketplace would be refused by the same hook — that path
# is pinned by the unit tests.
if [ -n "${EXAKIT_EXASOL_VSCODE_EXTDIR:-}" ] && [ -d "$EXAKIT_EXASOL_VSCODE_EXTDIR" ]; then
    _ext_after="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
        _exasol_vscode_live_version 2>/dev/null || true
    )"
    [ -z "$_ext_after" ] || fail "uninstall left the kit-installed VS Code extension behind (VS Code still lists $_ext_after)"
    echo "  ok  the kit-installed VS Code extension was removed through its own hook (VS Code no longer lists it)"
fi

say "PASS — marketplace install, update flow and uninstall all work end to end"
