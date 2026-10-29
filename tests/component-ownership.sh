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
pyexasol_installed_version(){ printf 1.0.0; }
pyexasol_install
check 'driver remains user owned' user "$(exakit_component_ownership pyexasol)"
pyexasol_installed_version(){ :; }
if pyexasol_install; then echo 'FAIL broken reused driver was accepted' >&2; exit 1; fi

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
exakit_marketplace_addons(){ printf 'notebook|Notebook\n'; }
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
exakit_record_ownership notebook user "$EXAKIT_HOME/broken-user-addon"
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
printf '%s ownership checks passed\n' "$PASS"
