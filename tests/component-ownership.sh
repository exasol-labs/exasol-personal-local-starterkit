#!/usr/bin/env bash
# No real install or teardown: every resource and executable is a temporary fixture.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" EXAKIT_HOME="$WORK/home/kit" EXAKIT_BIN_DIR="$WORK/home/bin"
export EXAKIT_VERSION_POLICY=pinned EXAKIT_NO_UPDATE_NOTICE=1 EXAKIT_NO_FANCY=1
unset EXAKIT_EXAPUMP_BIN EXAKIT_EXAPUMP_CONFIG_DIR EXAKIT_PERSONAL_BIN EXAKIT_PYEXASOL_VENV
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$HOME/.exapump"
export PATH="$EXAKIT_BIN_DIR:$PATH"
. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/exapump.sh"
. "$ROOT/setup/lib/runtime-personal.sh"
. "$ROOT/setup/lib/pyexasol.sh"
PASS=0
check() { if [ "$2" != "$3" ]; then printf 'FAIL %s: expected <%s>, got <%s>\n' "$1" "$2" "$3" >&2; exit 1; fi; PASS=$((PASS+1)); }
info(){ :; }; ok(){ :; }; warn(){ :; }; info_step(){ :; }; ok_step(){ :; }
fetch(){ echo 'Unexpected download' >&2; return 91; }
run_logged(){ echo 'Unexpected installation' >&2; return 92; }
detect_arch(){ printf arm64; }
printf '{}\n' > "$EXAKIT_MANIFEST"
printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_BIN_DIR/exasol"
chmod +x "$EXAKIT_BIN_DIR/exasol"
manifest_set installed_at fixture
check 'untracked shared launcher is unknown' unknown "$(exakit_component_ownership personal)"
exakit_reuse_ownership personal "$EXAKIT_BIN_DIR/exasol"
check 'reuse records user ownership' user "$(exakit_component_ownership personal)"
exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
exakit_reuse_ownership personal "$EXAKIT_BIN_DIR/exasol"
check 'repeat reuse retains kit receipt' kit "$(exakit_component_ownership personal)"
exakit_reuse_ownership personal "$HOME/another-exasol"
check 'different executable is user owned' user "$(exakit_component_ownership personal)"
check 'launcher receipt does not own database' unknown "$(exakit_component_ownership database)"

cat > "$EXAKIT_BIN_DIR/exapump" <<'BIN'
#!/bin/sh
printf 'exapump 0.14.0\n'
BIN
cat > "$EXAKIT_BIN_DIR/exasol" <<'BIN'
#!/bin/sh
printf 'Commands:\n  local  Install locally\n'
BIN
chmod +x "$EXAKIT_BIN_DIR/exapump" "$EXAKIT_BIN_DIR/exasol"
printf 'user profiles\n' > "$HOME/.exapump/config.toml"
exapump_before="$(shasum -a 256 "$EXAKIT_BIN_DIR/exapump")"
export EXAKIT_FORCE_COMPONENT_INSTALL=1
exapump_install
personal_install_launcher
check 'exapump reused despite force flag' user "$(exakit_component_ownership exapump)"
check 'launcher reused despite force flag' user "$(exakit_component_ownership personal)"
check 'actual reused version recorded' 0.14.0 "$(manifest_get components.exapump.version)"
check 'reused binary unchanged' "$exapump_before" "$(shasum -a 256 "$EXAKIT_BIN_DIR/exapump")"
exakit_record_ownership exapump kit "$EXAKIT_BIN_DIR/exapump"
printf '\n# user replacement\n' >> "$EXAKIT_BIN_DIR/exapump"
check 'same-path user replacement is protected' user "$(exakit_component_ownership exapump)"
exakit_reuse_ownership exapump "$EXAKIT_BIN_DIR/exapump"
exapump_before="$(shasum -a 256 "$EXAKIT_BIN_DIR/exapump")"
check 'kit profile is private' "$EXAKIT_HOME/exapump/config.toml" "$EXAPUMP_CONFIG"
exapump_update
personal_update
check 'update leaves binary unchanged' "$exapump_before" "$(shasum -a 256 "$EXAKIT_BIN_DIR/exapump")"

# A broken user executable must not be removed and downloaded again.
printf '#!/bin/sh\nexit 1\n' > "$EXAKIT_BIN_DIR/exapump"
if exapump_install; then echo 'FAIL broken external executable was accepted' >&2; exit 1; fi
check 'broken reused binary preserved' yes "$([ -f "$EXAKIT_BIN_DIR/exapump" ] && echo yes)"
printf '#!/bin/sh\nprintf "exapump 0.14.0\\n"\n' > "$EXAKIT_BIN_DIR/exapump"

# A previously adopted Python may never become an install target on a rerun.
printf '#!/bin/sh\nprintf "2.4.1\\n"\n' > "$HOME/user-python"
chmod +x "$HOME/user-python"
pyexasol_existing_python(){ printf '%s' "$HOME/user-python"; }
pyexasol_install
check 'external driver adopted without a package install' user "$(exakit_component_ownership pyexasol)"
check 'external driver version recorded' 2.4.1 "$(manifest_get components.pyexasol.version)"
exakit_record_ownership pyexasol user "$HOME/user-python"
pyexasol_installed_version(){ printf 2.5.0; }
pyexasol_install
check 'driver remains user owned' user "$(exakit_component_ownership pyexasol)"
pyexasol_installed_version(){ :; }
if pyexasol_install; then echo 'FAIL broken reused driver was accepted' >&2; exit 1; fi

# A reused driver older than Exasol Personal needs (InvalidVersion on every import and export) is
# left alone: the kit installs its own beside it and never into the user's Python.
exakit_record_ownership pyexasol user "$HOME/user-python"
manifest_set components.pyexasol.python "$HOME/user-python"
pyexasol_installed_version(){ printf 2.3.1; }
printf '#!/bin/sh\nprintf "2.3.1\\n"\n' > "$HOME/user-python"
eval "$(declare -f run_logged | sed '1s/^run_logged/_ownership_run_logged/')"
run_logged(){ printf '%s\n' "$*" >> "$HOME/pyexasol-installs"; }
# A uv the kit vetted, as on a machine past the bootstrap: the CI runner has none on PATH, and finding one
# would mean a download, which this fixture refuses.
printf '#!/bin/sh\nexit 0\n' > "$HOME/vetted-uv"; chmod +x "$HOME/vetted-uv"
eval "$(declare -f exakit_ensure_uv | sed '1s/^exakit_ensure_uv/_ownership_ensure_uv/')"
exakit_ensure_uv(){ EXAKIT_UV_BIN="$HOME/vetted-uv"; return 0; }
pyexasol_install >/dev/null 2>&1 || true
check 'an older reused driver hands over to the kit' kit "$(exakit_component_ownership pyexasol)"
check '...which installs into its own environment' yes "$(grep -q 'pyexasol-venv' "$HOME/pyexasol-installs" && echo yes)"
check '...and never into the user'"'"'s Python' no "$(grep -q 'user-python' "$HOME/pyexasol-installs" && echo yes || echo no)"
eval "$(declare -f _ownership_run_logged | sed '1s/^_ownership_run_logged/run_logged/')"
eval "$(declare -f _ownership_ensure_uv | sed '1s/^_ownership_ensure_uv/exakit_ensure_uv/')"

exakit_version_table_targets(){ printf 'exapump\n'; }
exakit_component_available(){ printf 99.0.0; }
exakit_component_note(){ :; }
exakit_component_severity(){ :; }
exakit_component_supported(){ return 0; }
exakit_component_current(){ printf 0.14.0; }
exakit_versions_source(){ printf fixture; }
exakit_marketplace_addons(){ :; }
exakit_print_version_table --json > "$WORK/version.json"
python3 - "$WORK/version.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
r = v['components'][0]
assert (r['ownership'], r['installed_by_kit'], r['status'], r['remedy']) == ('user', False, 'external', None), r
assert v['pending'] == 0, v
PY
PASS=$((PASS+1))

exakit_marketplace_installed_addons(){ :; }
exakit_marketplace_addons(){ printf 'future-addon|Future add-on\n'; }
exakit_service_ids(){ :; }
exakit_mcp_operation(){ :; }
_exakit_remove_installed_skills(){ :; }
exakit_remove_readonly_allowlist(){ :; }
personal_teardown(){ touch "$WORK/teardown"; rm -rf "$HOME/database"; }
manifest_set runtime.type personal
manifest_set runtime.deployment_dir "$HOME/database"
EXAKIT_PERSONAL_DEPLOY_DIR="$HOME/database"
exakit_record_ownership database user "$HOME/database"
exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
printf '\n# replaced by the user\n' >> "$EXAKIT_BIN_DIR/exasol"
mkdir -p "$HOME/database" "$EXAKIT_HOME/user-env" "$EXAKIT_HOME/exapump"
touch "$HOME/database/data" "$EXAKIT_HOME/user-env/keep" "$EXAKIT_HOME/exapump/config.toml" "$EXAKIT_BIN_DIR/exakit"
exakit_record_ownership pyexasol user "$EXAKIT_HOME/user-env"
exakit_record_ownership future-addon user "$EXAKIT_HOME/broken-user-addon"
mkdir -p "$EXAKIT_HOME/broken-user-addon"
touch "$EXAKIT_HOME/broken-user-addon/user-data"
_exakit_uninstall_component database 0
check 'selective uninstall keeps reused database' no "$([ -e "$WORK/teardown" ] && echo yes || echo no)"
exakit_uninstall_run 1
check 'dry run keeps kit config' yes "$([ -f "$EXAKIT_HOME/exapump/config.toml" ] && echo yes)"
exakit_uninstall_run 0
check 'full uninstall never tears down user database' no "$([ -e "$WORK/teardown" ] && echo yes || echo no)"
check 'database data retained' yes "$([ -e "$HOME/database/data" ] && echo yes)"
check 'external resource inside kit home retained' yes "$([ -e "$EXAKIT_HOME/user-env/keep" ] && echo yes)"
check 'broken user add-on retained without an installed probe' yes "$([ -e "$EXAKIT_HOME/broken-user-addon/user-data" ] && echo yes)"
check 'user exapump retained' yes "$([ -e "$EXAKIT_BIN_DIR/exapump" ] && echo yes)"
check 'user launcher retained' yes "$([ -e "$EXAKIT_BIN_DIR/exasol" ] && echo yes)"
check 'user profile retained' 'user profiles' "$(cat "$HOME/.exapump/config.toml")"
check 'kit profile removed' no "$([ -e "$EXAKIT_HOME/exapump/config.toml" ] && echo yes || echo no)"
check 'kit entrypoint removed' no "$([ -e "$EXAKIT_BIN_DIR/exakit" ] && echo yes || echo no)"

# With explicit kit receipts, the same paths are removable.
printf '{}\n' > "$EXAKIT_MANIFEST"
manifest_set installed_at fixture
manifest_set runtime.type personal
exakit_record_ownership database kit "$HOME/database"
exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
EXAKIT_EXAPUMP_BIN="$HOME/kit-owned-custom-exapump"
cp "$EXAKIT_BIN_DIR/exapump" "$EXAKIT_EXAPUMP_BIN"
exakit_record_ownership exapump kit "$EXAKIT_EXAPUMP_BIN"
exakit_uninstall_run 0
check 'owned database teardown called' yes "$([ -e "$WORK/teardown" ] && echo yes)"
check 'owned launcher removed' no "$([ -e "$EXAKIT_BIN_DIR/exasol" ] && echo yes || echo no)"
check 'owned custom exapump removed' no "$([ -e "$EXAKIT_EXAPUMP_BIN" ] && echo yes || echo no)"
check 'same-named user binary at default path retained' yes "$([ -e "$EXAKIT_BIN_DIR/exapump" ] && echo yes || echo no)"
# AN INSTALL FROM BEFORE RECEIPTS (every kit up to 0.2.4, audit LCY-01): no
# `*.ownership` key anywhere, only what the old kit recorded about its own
# install. Answering "unknown" here made `exakit update` skip the launcher,
# the database and exapump of every existing install and report "current".
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
printf '{}\n' > "$EXAKIT_MANIFEST"
manifest_set installed_at fixture
printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_BIN_DIR/exasol"; chmod +x "$EXAKIT_BIN_DIR/exasol"
printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_BIN_DIR/exapump"; chmod +x "$EXAKIT_BIN_DIR/exapump"
unset EXAKIT_EXAPUMP_BIN
mkdir -p "$HOME/legacy-deployment"
EXAKIT_PERSONAL_DEPLOY_DIR="$HOME/legacy-deployment"
manifest_set runtime.type personal
manifest_set runtime.launcher "$EXAKIT_BIN_DIR/exasol"
manifest_set runtime.deployment_dir "$HOME/legacy-deployment"
manifest_set components.exapump.path "$EXAKIT_BIN_DIR/exapump"
manifest_set components.mcp_server.version 1.9.0
check 'pre-receipt: the kit launcher is the kit'"'"'s' kit "$(exakit_component_ownership personal)"
check 'pre-receipt: the database its launcher deployed is the kit'"'"'s' kit "$(exakit_component_ownership database)"
check 'pre-receipt: the kit exapump is the kit'"'"'s' kit "$(exakit_component_ownership exapump)"
check 'pre-receipt: the MCP server it recorded is the kit'"'"'s' kit "$(exakit_component_ownership mcp)"
check 'pre-receipt: so update manages the launcher' yes "$(exakit_component_is_managed personal && echo yes)"
exakit_reuse_ownership personal "$EXAKIT_BIN_DIR/exasol"
exakit_reuse_ownership database "$HOME/legacy-deployment"
check 'pre-receipt: an installer re-run writes the kit receipt, never "user"' kit "$(manifest_get components.personal.ownership)"
check '...for the database too' kit "$(manifest_get runtime.ownership)"
# Never by PATH: a launcher the old kit recorded somewhere else is the user's.
printf '{}\n' > "$EXAKIT_MANIFEST"
manifest_set runtime.type personal
manifest_set runtime.launcher "$HOME/their-own/exasol"
manifest_set runtime.deployment_dir "$HOME/legacy-deployment"
check 'pre-receipt: a launcher outside the kit bin stays unknown' unknown "$(exakit_component_ownership personal)"
check '...and so does the database it deployed' unknown "$(exakit_component_ownership database)"
check 'pre-receipt: an explicit user receipt is never overridden' user "$(manifest_set components.exapump.ownership user; manifest_set components.exapump.path "$EXAKIT_BIN_DIR/exapump"; exakit_component_ownership exapump)"

# THE KIT'S OWN uv (audit UPG-06): kits 0.2.3 to 0.2.5 installed the pinned,
# verified uv into the kit's bin folder and recorded only path, version and
# managed=true - no receipt - so it read "unknown" and `exakit update` never
# moved it again. That record plus the exact bytes of the pinned release's uv
# is the kit's; a uv the user put at the same path (other bytes), a symlink, a
# uv elsewhere or a record that does not say managed stays out of the kit's hands.
# The release table is asked for this fixture's bytes; its real entries are
# spot-checked against the archives at the end.
eval "$(declare -f exakit_uv_binary_sha256 | sed '1s/^exakit_uv_binary_sha256/_real_uv_binary_sha256/')"
printf '#!/bin/sh\nprintf "uv 0.13.7 (fixture release)\\n"\n' > "$HOME/uv-0.13.7-release"
exakit_uv_binary_sha256(){
    if [ "$1" = "uv-0.13.7-$(exakit_uv_platform)" ]; then sha256_of "$HOME/uv-0.13.7-release"; else _real_uv_binary_sha256 "$1"; fi
}
uv_025_record() { # the components.uv record kits 0.2.3 to 0.2.5 wrote
    printf '{"kit":{"version":"0.2.5"},"installed_at":"fixture","components":{"uv":{"path":"%s","version":"%s","managed":%s}}}\n' \
        "${1:-$EXAKIT_BIN_DIR/uv}" "${2:-0.13.7}" "${3:-true}" > "$EXAKIT_MANIFEST"
}
rm -f "$EXAKIT_BIN_DIR/uv"; cp "$HOME/uv-0.13.7-release" "$EXAKIT_BIN_DIR/uv"; chmod +x "$EXAKIT_BIN_DIR/uv"
uv_025_record
check 'uv a 0.2.5 kit installed (pinned bytes, managed) is the kit'"'"'s' kit "$(exakit_component_ownership uv)"
check '...so update manages it' yes "$(exakit_component_is_managed uv && echo yes || echo no)"
uv_025_record "$EXAKIT_BIN_DIR/uv" 0.13.6
check 'a recorded version whose release bytes differ is not the kit'"'"'s' unknown "$(exakit_component_ownership uv)"
uv_025_record "$EXAKIT_BIN_DIR/uv" 0.13.7 false
check 'a record that does not say managed is not the kit'"'"'s' unknown "$(exakit_component_ownership uv)"
uv_025_record "$HOME/homebrew/bin/uv"
check 'a uv recorded outside the kit bin folder stays the user'"'"'s' unknown "$(exakit_component_ownership uv)"
uv_025_record
printf '\n# the user'"'"'s own uv build\n' >> "$EXAKIT_BIN_DIR/uv"
check 'a uv with other bytes at the kit path stays the user'"'"'s' unknown "$(exakit_component_ownership uv)"
rm -f "$EXAKIT_BIN_DIR/uv"; ln -s "$HOME/uv-0.13.7-release" "$EXAKIT_BIN_DIR/uv"
check 'a symlink at the kit path (pipx and the like) stays the user'"'"'s' unknown "$(exakit_component_ownership uv)"
# A uv the kit installs now carries a receipt: `exakit update uv` (and the
# install's bootstrap) record it, and a later user replacement voids it.
rm -f "$EXAKIT_BIN_DIR/uv"
uv_025_record "$EXAKIT_BIN_DIR/uv" 0.13.6 false
eval "$(declare -f exakit_uv_install_pinned | sed '1s/^exakit_uv_install_pinned/_ownership_uv_install_pinned/')"
eval "$(declare -f exakit_uv_report | sed '1s/^exakit_uv_report/_ownership_uv_report/')"
exakit_uv_install_pinned(){ printf '#!/bin/sh\nprintf "uv 0.13.8 (fixture install)\\n"\n' > "$EXAKIT_BIN_DIR/uv"; chmod +x "$EXAKIT_BIN_DIR/uv"; }
exakit_uv_report(){ printf 'none|||0.13.4\n'; }
exakit_uv_update >/dev/null 2>&1
check 'a uv the kit installs gets the kit receipt' kit "$(manifest_get components.uv.ownership)"
check '...naming its own path' "$EXAKIT_BIN_DIR/uv" "$(manifest_get components.uv.ownership_path)"
check '...so it is the kit'"'"'s' kit "$(exakit_component_ownership uv)"
printf '\n# uv self update by the user\n' >> "$EXAKIT_BIN_DIR/uv"
check 'the user replacing the kit'"'"'s uv makes it theirs' user "$(exakit_component_ownership uv)"
# A uv the kit only found (no install in this process) gets no receipt.
printf '{"installed_at":"fixture"}\n' > "$EXAKIT_MANIFEST"
_EXAKIT_UV_KIT_INSTALLED=0
EXAKIT_UV_BIN="$EXAKIT_BIN_DIR/uv" exakit_uv_record_manifest
check 'a uv the kit found at its path gets no kit receipt' none "$(manifest_get components.uv.ownership 2>/dev/null || echo none)"
eval "$(declare -f _ownership_uv_install_pinned | sed '1s/^_ownership_uv_install_pinned/exakit_uv_install_pinned/')"
eval "$(declare -f _ownership_uv_report | sed '1s/^_ownership_uv_report/exakit_uv_report/')"
eval "$(declare -f _real_uv_binary_sha256 | sed '1s/^_real_uv_binary_sha256/exakit_uv_binary_sha256/')"
unset EXAKIT_UV_BIN _EXAKIT_UV_VETTED _EXAKIT_UV_KIT_INSTALLED
# The real table: the uv binary of each pinned release, by platform. Spot
# checks against the archives' bytes (0.13.7 is what 0.2.4/0.2.5 installed).
check 'release table: uv 0.13.7 macOS arm64' 0f333833a6d011710d3edc0e45b55d3d934aef15bb83a25b29848c241ac513b4 "$(exakit_uv_binary_sha256 uv-0.13.7-macos-aarch64)"
check 'release table: uv 0.13.7 Linux x86_64' 4b5e59bc557ff2cd70934beb59d0eaa92820702853d49f0066b50aa11a8f0c52 "$(exakit_uv_binary_sha256 uv-0.13.7-linux-x86_64)"
check 'release table: an unpinned release has no entry' '' "$(exakit_uv_binary_sha256 uv-0.13.5-linux-x86_64)"
rm -f "$EXAKIT_BIN_DIR/uv"

# AN ADD-ON KIT 0.2.5 INSTALLED (audit UPG-01): 0.2.5 recorded Dash Server and
# JSON Tables with no ownership key. The shell reads the venv under the kit home
# as the kit's; the Python add-on modules must give the same answer, or the kit
# lists the add-on as its own and then refuses to update or remove it.
python_owner() {
    python3 - "$ROOT/marketplace" "$EXAKIT_MANIFEST" "$1" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from runtime import Manifest
print(Manifest(Path(sys.argv[2])).get(f"components.{sys.argv[3]}.ownership") or "none")
PY
}
printf '{"kit":{"version":"0.2.5"},"components":{"dash_server":{"version":"0.2.1","venv":"%s","python":"%s","command":"%s","port":5100,"instance":"%s"},"json_tables":{"version":"0.4.1","venv":"%s","python":"%s","engine":"%s","command":"%s"}}}\n' \
    "$EXAKIT_HOME/dash-server-venv" "$EXAKIT_HOME/dash-server-venv/bin/python" "$EXAKIT_BIN_DIR/dash-server" \
    "$EXAKIT_HOME/dash-server/instance" "$EXAKIT_HOME/json-tables-venv" "$EXAKIT_HOME/json-tables-venv/bin/python" \
    "$EXAKIT_HOME/json-tables/libexec/json_to_parquet" "$EXAKIT_BIN_DIR/exasol-json-tables" > "$EXAKIT_MANIFEST"
check '0.2.5 add-on receipt: the shell reads Dash Server as the kit'"'"'s' kit "$(exakit_component_ownership dash-server)"
check '...and so do the add-on modules' kit "$(python_owner dash_server)"
check '0.2.5 add-on receipt: JSON Tables in the shell' kit "$(exakit_component_ownership json-tables)"
check '...and in the add-on modules' kit "$(python_owner json_tables)"
manifest_set components.json_tables.venv "$HOME/their-own/venv"
manifest_set components.json_tables.python "$HOME/their-own/venv/bin/python"
manifest_set components.json_tables.engine "$HOME/their-own/json_to_parquet"
check 'a receipt naming a venv outside the kit home stays unknown in the shell' unknown "$(exakit_component_ownership json-tables)"
check '...and unowned in the add-on modules' none "$(python_owner json_tables)"

# THE OTHER TWO ADD-ONS KIT 0.2.5 INSTALLED (audit STA-01): the Scheduler
# recorded version, engine, db_user, schema (only its engine under the kit
# home); the VS Code extension recorded version, extension_id, code_cli
# (nothing under the kit home: that shape with no ownership key is the kit's).
# Every fixture is asked of all three readers - bash, PowerShell (when pwsh is
# on PATH; EXAKIT_REQUIRE_PS=1 makes it mandatory) and Python - and they must
# give the same answer.
cat > "$WORK/owners.ps1" <<'PS1'
param([string]$Root, [string]$Manifest, [string]$KitHome, [string[]]$Ids)
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'setup/lib/exakit-common.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "exakit-common.ps1 parse errors: $parseErrors" }
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Extent.Text -match '^\s*(function|filter)\s' }, $true)) {
    Invoke-Expression $fn.Extent.Text
}
$script:ExakitHome = $KitHome
$script:BinDir = Join-Path $KitHome 'no-bin'
$script:doc = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json
function Get-ExakitManifestValue([string]$Path) {
    $node = $script:doc
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node -or -not $node.PSObject.Properties[$part]) { return $null }
        $node = $node.$part
    }
    return $node
}
foreach ($id in $Ids) { Write-Output (Get-ExakitComponentOwnership $id) }
PS1
_ps_runner=""
if command -v pwsh >/dev/null 2>&1; then _ps_runner=pwsh
elif [ "${EXAKIT_REQUIRE_PS:-0}" = 1 ]; then echo 'FAIL pwsh is required (EXAKIT_REQUIRE_PS=1) and not on PATH' >&2; exit 1
else echo '  skip PowerShell ownership answers: pwsh is not on PATH'; fi
ps_owner() {
    [ -n "$_ps_runner" ] || return 0
    "$_ps_runner" -NoProfile -NonInteractive -File "$WORK/owners.ps1" -Root "$ROOT" -Manifest "$EXAKIT_MANIFEST" \
        -KitHome "$EXAKIT_HOME" -Ids "$1" | tr -d '\r'
}
# agree <label> <add-on id> <expected: kit|user|unknown>
agree() {
    _ag_key="$(printf '%s' "$2" | tr '-' '_')"
    check "$1 (bash)" "$3" "$(exakit_component_ownership "$2")"
    _ag_py="$(python_owner "$_ag_key")"; [ "$_ag_py" = none ] && _ag_py=unknown
    check "$1 (Python)" "$3" "$_ag_py"
    [ -z "$_ps_runner" ] || check "$1 (PowerShell)" "$3" "$(ps_owner "$2")"
}
write_025_receipts() { # the exact receipts 0.2.5 wrote, plus an optional extra JSON per add-on
    printf '{"kit":{"version":"0.2.5"},"installed_at":"fixture","components":{"exasol_scheduler":{"version":"0.4.1","engine":"%s","db_user":"scheduler_svc","schema":"SCHED","bootstrap_revoked":true,"validated":true%s},"exasol_vscode":{"version":"1.9.1","extension_id":"exasol.exasol-vscode","code_cli":"/usr/local/bin/code","validated":true%s}}}\n' \
        "${3:-$EXAKIT_HOME/exasol-scheduler/libexec/exasol_scheduler}" "${1:-}" "${2:-}" > "$EXAKIT_MANIFEST"
}
write_025_receipts
agree '0.2.5 Scheduler receipt (engine under the kit home) is the kit'"'"'s' exasol-scheduler kit
agree '0.2.5 VS Code extension receipt (its exact shape) is the kit'"'"'s' exasol-vscode kit
write_025_receipts ',"ownership":"user"' ',"ownership":"user"'
agree 'a Scheduler receipt saying ownership user stays the user'"'"'s' exasol-scheduler user
agree 'a VS Code receipt saying ownership user stays the user'"'"'s' exasol-vscode user
write_025_receipts ',"ownership":"unknown"' ',"ownership":"unknown"'
agree 'a Scheduler receipt saying ownership unknown is never adopted' exasol-scheduler unknown
agree 'a VS Code receipt saying ownership unknown is never adopted' exasol-vscode unknown
write_025_receipts '' '' "$EXAKIT_HOME-other/exasol-scheduler/libexec/exasol_scheduler"
agree 'an engine in a sibling folder whose name starts with the kit home is not the kit'"'"'s' exasol-scheduler unknown
printf '{"components":{"exasol_vscode":{"version":"1.9.1","extension_id":"exasol.exasol-vscode"}}}\n' > "$EXAKIT_MANIFEST"
agree 'a VS Code receipt without code_cli is not the 0.2.5 shape' exasol-vscode unknown

# A KEPT ADD-ON NEVER ANSWERS "removed" (audit STA-01): `exakit uninstall
# <id> --yes` on an add-on the kit did not install said "removed" with exit 0
# while everything stayed. Kept is "something remains": exit 1, and it says
# that nothing was removed. A preview of the same is exit 0.
mkdir -p "$EXAKIT_HOME/exasol-scheduler/libexec"
printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_HOME/exasol-scheduler/libexec/exasol_scheduler"
printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_BIN_DIR/exasol-scheduler"
chmod +x "$EXAKIT_HOME/exasol-scheduler/libexec/exasol_scheduler" "$EXAKIT_BIN_DIR/exasol-scheduler"
write_025_receipts ',"ownership":"user"'
_kept_cli() {
    _kc_rc=0
    _kc_out="$(EXAKIT_NO_UPDATE_NOTICE=1 TERM=dumb /bin/bash "$ROOT/setup/exakit" uninstall exasol-scheduler "$@" 2>&1)" || _kc_rc=$?
    printf '%s|%s' "$_kc_rc" "$(printf '%s' "$_kc_out" | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')"
}
_kept="$(_kept_cli --yes)"
check 'kept add-on: uninstall --yes exits 1' 1 "${_kept%%|*}"
case "${_kept#*|}" in *"Nothing was removed"*) _k=says ;; *) _k="${_kept#*|}" ;; esac
check '...and says nothing was removed' says "$_k"
case "${_kept#*|}" in *"exasol-scheduler removed"*) _k=claims ;; *) _k=never ;; esac
check '...and never claims removed' never "$_k"
check '...and the launcher is still there' yes "$([ -e "$EXAKIT_BIN_DIR/exasol-scheduler" ] && echo yes || echo no)"
check '...and so is the receipt' user "$(manifest_get components.exasol_scheduler.ownership)"
_kept="$(_kept_cli --dry-run)"
check 'kept add-on: the preview exits 0' 0 "${_kept%%|*}"
case "${_kept#*|}" in *"Nothing would be removed"*) _k=says ;; *) _k="${_kept#*|}" ;; esac
check '...and says nothing would be removed' says "$_k"

printf '%s ownership checks passed\n' "$PASS"
