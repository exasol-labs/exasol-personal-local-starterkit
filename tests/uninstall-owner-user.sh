#!/usr/bin/env bash
# uninstall-owner-user.sh - what `exakit uninstall` does to a database the user
# let the kit use (owner user), and to the kit's own launcher (D4).
#
#   bash tests/uninstall-owner-user.sh
#
# What is pinned:
#   owner user  never destroyed, and it keeps its name starter-kit-local (D5):
#               the folder and its data are where they were. SEC-01 runs inside
#               it through marketplace/kit_logins.py, before the add-ons go:
#               the kit's read-only login and the Scheduler's are dropped (their
#               sessions killed first), a role the kit created goes unless one
#               of the user's own users holds it, every schema such a login or
#               role owns goes to SYS first (PREPROC and PREPROC_RT, the
#               Scheduler's SCHED), and nothing is dropped with CASCADE, nor any
#               connection or schema. Each connection is listed with the
#               statement that drops it. The add-ons' own removal then runs with
#               EXAKIT_UNINSTALL_KEEP_DATABASE=1 and touches nothing inside it.
#             - a dry run lists those steps, in their order, and changes nothing
#             - a stopped database is never started: the statements are printed
#               for later, in the same order, and the uninstall still finishes
#             - the kit's own database gone and another deployment found there:
#               no statement at all (its logins are not the kit's to drop)
#   D4          the kit's own launcher stays while another deployment uses it,
#               and the line says which; a stray folder (no launcher state) does
#               not count; with none it goes as before; a launcher that is not
#               the kit's is kept as before. Next to a launcher of the user's it
#               goes only when theirs is readable and on the 2.5 line or newer
#   mode P      the kit's private launcher home ($EXAKIT_HOME/personal) goes with
#               the kit home, unless its own root holds another deployment
#   prune       the 2.5.0 launcher root is recognised by its folder, not by the
#               deployment's name in it (starter-kit-local)
#   component   `_exakit_uninstall_component database` never destroys a database
#               the user let the kit use
#
# Everything runs against a sandboxed HOME, a stub launcher and a stand-in
# database (tests/lib/fake-kit-logins-db.py); no real launcher, database,
# engine, kit home or AI client is touched.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got:\n%s\n' "$1" "$2" "$3" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: must not contain "%s", got:\n%s\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
    esac
}
gone() { [ -e "$1" ] && echo kept || echo gone; }

SBHOME="$TMP/home"
case "$SBHOME" in "$HOME"|"$HOME/") echo "refusing: sandbox HOME is the real HOME"; exit 1 ;; esac
PY="$(command -v python3)"
[ -n "$PY" ] || { echo "python3 is needed (marketplace/kit_logins.py)"; exit 1; }
ROOT25="$SBHOME/.exasol/launcher/deployments"
DEPLOY="$ROOT25/starter-kit-local"
KITHOME="$SBHOME/.exasol-starter-kit"
DBLOG="$TMP/db.log"
DBSTATE="$TMP/db-state.json"

# The harness: the real libraries, the real exakit_uninstall_run, the real
# kit_logins.py. Stubbed: the screen (with the quiet bracket the real info()
# honours), the teardown, and every step that would reach outside the sandbox.
cat > "$TMP/run.sh" <<HARNESS
set -u
export HOME="$SBHOME" EXAKIT_HOME="$KITHOME" EXAKIT_BIN_DIR="$SBHOME/.local/bin"
export EXAKIT_VERSION_POLICY=pinned EXAKIT_NO_UPDATE_NOTICE=1 EXAKIT_NO_FANCY=1
export EXAKIT_KIT_LOGINS_FAKE_DB="$ROOT/tests/lib/fake-kit-logins-db.py"
export EXAKIT_FAKE_DB_STATE="$DBSTATE" EXAKIT_FAKE_DB_LOG="$DBLOG"
unset EXAKIT_PERSONAL_BIN EXAKIT_EXAPUMP_BIN EXAKIT_LOG_FILE
EXAKIT_PERSONAL_DEPLOY_DIR="\${SC_DEPLOY_DIR:-$DEPLOY}"
. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/runtime-personal.sh"
# Mode P: the kit runs its launcher through the wrapper in its private home.
[ -z "\${SC_PERSONAL_BIN:-}" ] || EXAKIT_PERSONAL_BIN="\$SC_PERSONAL_BIN"
info(){ [ "\${EXAKIT_QUIET_DETAIL:-0}" = 1 ] && return 0; printf 'INFO %s\n' "\$*"; }
info_step(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }; ok_step(){ printf 'OK %s\n' "\$*"; }
warn(){ printf 'WARN %s\n' "\$*"; }; error(){ printf 'ERROR %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
ui_spin_begin(){ :; }; ui_spin_end(){ :; }; ui_spin_relabel(){ :; }; ui_tilde(){ printf '%s' "\$1"; }
_exakit_log_file(){ :; }
exakit_service_ids(){ :; }; _exakit_uninstall_orphan_autostart(){ :; }
exakit_marketplace_addons(){ :; }; exakit_marketplace_installed_addons(){ :; }; exakit_marketplace_removable_addons(){ :; }
# SC_ADDON=1: one kit-managed add-on to remove, which writes when it ran (into
# the database log, so its place among the statements shows) and whether the
# run told it to keep the database.
if [ "\${SC_ADDON:-0}" = 1 ]; then
    exakit_marketplace_installed_addons(){ printf 'semantic-views\n'; }
    exakit_marketplace_removable_addons(){ printf 'semantic-views\n'; }
    _exakit_skills_decide_kits(){ :; }
    semantic_views_uninstall(){ printf 'ADDON semantic-views dry=%s keep=%s\n' "\$1" "\${EXAKIT_UNINSTALL_KEEP_DATABASE:-}" >> "$DBLOG"; }
fi
exakit_mcp_operation(){ :; }; _exakit_remove_installed_skills(){ :; }
_exakit_uninstall_mcp_processes(){ :; }; _exakit_uninstall_kit_images(){ :; }; _exakit_uninstall_kit_image_ids(){ :; }
_exakit_uninstall_closing_hints(){ :; }
personal_launcher_cache_dir(){ printf '%s\n' "$SBHOME/.cache/exasol/launcher/resources"; }
personal_teardown(){ printf 'TEARDOWN %s\n' "\$EXAKIT_PERSONAL_DEPLOY_DIR"; rm -rf "\$EXAKIT_PERSONAL_DEPLOY_DIR"; return 0; }
# The scenario: who owns the database and the launcher.
printf '{}\n' > "\$EXAKIT_MANIFEST"
manifest_set runtime.type personal
manifest_set runtime.user sys
manifest_set runtime.dsn 127.0.0.1:8563
manifest_set runtime.password_file "$KITHOME/credentials/runtime_sys_password"
manifest_set runtime.deployment_dir "\${SC_RECORDED_DIR:-$DEPLOY}"
manifest_set components.mcp_server.connection.user "\${SC_MCP_USER:-mcp_readonly}"
[ -z "\${SC_MCP_CREATED:-}" ] || manifest_set components.mcp_server.connection.created "\$SC_MCP_CREATED"
manifest_set components.semantic_views.role_created true
manifest_set components.semantic_views.ownership kit
manifest_set components.exasol_scheduler.ownership kit
manifest_set components.exasol_scheduler.db_user scheduler_svc
manifest_set components.exasol_scheduler.schema SCHED
manifest_set components.preprocessor.origin kit
manifest_set components.preprocessor.state active
manifest_set components.pyexasol.python "$PY"
[ -z "\${SC_SIDECAR:-}" ] || manifest_set components.mcp_server.backend sidecar
[ -z "\${SC_USER_LAUNCHER:-}" ] || manifest_set components.personal.user_launcher "\$SC_USER_LAUNCHER"
exakit_record_ownership database "\${SC_OWNER:-user}" "\${SC_RECORDED_DIR:-$DEPLOY}"
if [ "\${SC_LAUNCHER:-kit}" = kit ]; then
    exakit_record_ownership personal kit "\${SC_LAUNCHER_PATH:-\$EXAKIT_BIN_DIR/exasol}"
else
    exakit_record_ownership personal user "\$EXAKIT_BIN_DIR/exasol"
fi
if [ -n "\${SC_COMPONENT:-}" ]; then
    _exakit_uninstall_component "\$SC_COMPONENT" "\${SC_DRY:-0}"
else
    exakit_uninstall_run "\${SC_DRY:-0}"
fi
printf 'RC=%s\n' "\$?"
HARNESS

# seed [demo|stray] - a fresh sandbox: the kit home, the kit's launcher (a stub
# that answers no deployment list, as a 2.4 launcher), the database folder
# with its data, the kit's source records, and the stand-in database.
seed() {
    rm -rf "$SBHOME" "$DBLOG"
    mkdir -p "$KITHOME/credentials" "$KITHOME/sources/sales" "$SBHOME/.local/bin" "$DEPLOY/data"
    printf 'not-a-real-password\n' > "$KITHOME/credentials/runtime_sys_password"
    printf '{"objects": {"connection": "EXAKIT_SRC_SALES", "schema": "VS_SALES"}}\n' > "$KITHOME/sources/sales/config.json"
    printf '{"deploymentId": "abcd1234"}\n' > "$DEPLOY/.exasolLauncherState.json"
    printf 'the user data\n' > "$DEPLOY/data/table.dat"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n[ "$1" = deployments ] && exit 1\nexit 0\n' "$TMP/launcher-calls" > "$SBHOME/.local/bin/exasol"
    chmod +x "$SBHOME/.local/bin/exasol"
    case "${1:-}" in
        demo)  mkdir -p "$ROOT25/demo"; printf '{"deploymentId": "feed0001"}\n' > "$ROOT25/demo/.exasolLauncherState.json" ;;
        stray) mkdir -p "$ROOT25/notes" ;;
    esac
    cat > "$DBSTATE" <<JSON
{"down": ${DB_DOWN:-false}, "users": ["MCP_READONLY", "SCHEDULER_SVC", "THEIR_ANALYST"${DB_USERS_EXTRA:-}],
 "sessions": {"MCP_READONLY": [41, 42]${DB_SESSIONS_EXTRA:-}},
 "roles": {"SEMANTIC_USER": ["MCP_READONLY", "THEIR_ANALYST"], "PREPROC_ADMIN": ["SYS"]},
 "owners": {"PREPROC": "PREPROC_ADMIN", "PREPROC_RT": "PREPROC_ADMIN", "SCHED": "SCHEDULER_SVC",
            "THEIRS": "THEIR_ANALYST"${DB_OWNERS_EXTRA:-}},
 "connections": ["EXAKIT_SRC_SALES", "THEIR_OWN"], "schemas": ["VS_SALES"], "slot": "PREPROC_RT.MASTER"}
JSON
}
statements() { [ -f "$DBLOG" ] && cat "$DBLOG"; }
# before <first> <second> <text> - yes when the line <first> comes before the
# line <second> in <text>.
before() {
    _b1="$(printf '%s\n' "$3" | grep -nxF -- "$1" | head -1 | cut -d: -f1)"
    _b2="$(printf '%s\n' "$3" | grep -nxF -- "$2" | head -1 | cut -d: -f1)"
    [ -n "$_b1" ] && [ -n "$_b2" ] && [ "$_b1" -lt "$_b2" ] && echo yes || echo no
}

echo "owner user, a real run: the database stays as it is, the kit's logins inside it go"
seed
out="$(bash "$TMP/run.sh" 2>&1)"
contains "the run answers 0" "RC=0" "$out"
lacks    "the database is never torn down" "TEARDOWN" "$out"
check    "it keeps its folder, name and data (D5)" "the user data" "$(cat "$DEPLOY/data/table.dat" 2>/dev/null)"
check    "no other folder took its place" "starter-kit-local" "$(ls "$ROOT25")"
sql="$(statements)"
check    "the read-only login's sessions end before its drop" yes "$(before "KILL SESSION 41" 'DROP USER "MCP_READONLY"' "$sql")"
contains "...its CREATE SESSION revoked" 'REVOKE CREATE SESSION FROM "MCP_READONLY"' "$sql"
check    "the Scheduler's schema goes to SYS before its login is dropped" yes \
    "$(before 'ALTER SCHEMA "SCHED" CHANGE OWNER SYS' 'DROP USER "SCHEDULER_SVC"' "$sql")"
check    "PREPROC goes to SYS before the role is dropped" yes "$(before 'ALTER SCHEMA "PREPROC" CHANGE OWNER SYS' 'DROP ROLE "PREPROC_ADMIN"' "$sql")"
check    "PREPROC_RT goes to SYS before the role is dropped" yes "$(before 'ALTER SCHEMA "PREPROC_RT" CHANGE OWNER SYS' 'DROP ROLE "PREPROC_ADMIN"' "$sql")"
check    "the framework's schemas and the Scheduler's are SYS's now, theirs untouched" \
    '{"PREPROC": "SYS", "PREPROC_RT": "SYS", "SCHED": "SYS", "THEIRS": "THEIR_ANALYST"}' \
    "$("$PY" -c 'import json,sys; print(json.dumps(dict(sorted(json.load(open(sys.argv[1]))["owners"].items()))))' "$DBSTATE")"
lacks    "a role one of their own users holds stays" 'DROP ROLE "SEMANTIC_USER"' "$sql"
lacks    "their own user is never dropped" 'THEIR_ANALYST"' "$(printf '%s\n' "$sql" | grep '^DROP' || true)"
lacks    "their own schema keeps its owner" 'ALTER SCHEMA "THEIRS"' "$sql"
lacks    "nothing with CASCADE" "CASCADE" "$sql"
lacks    "no connection dropped" "DROP CONNECTION" "$sql"
lacks    "no schema dropped" "DROP SCHEMA" "$sql"
contains "the record line names the logins" "OK Removed the kit's logins MCP_READONLY and SCHEDULER_SVC from your database 'starter-kit-local'" "$out"
contains "the Scheduler's schema stays, said" "INFO The schema SCHED stays in your database, now owned by SYS." "$out"
contains "the dropped role is said" "OK Removed the role PREPROC_ADMIN from your database 'starter-kit-local'" "$out"
contains "its schemas stay, said" "INFO The schemas PREPROC and PREPROC_RT stay in your database, now owned by SYS." "$out"
contains "the kept role is said, with who holds it" "INFO The role SEMANTIC_USER stays in your database: THEIR_ANALYST holds it." "$out"
contains "the connection is listed with its DROP statement" "INFO The connection EXAKIT_SRC_SALES stays in your database. To remove it: DROP CONNECTION EXAKIT_SRC_SALES;" "$out"
lacks    "their own connection is not the kit's to list" "THEIR_OWN" "$out"
contains "the virtual schema stays" "INFO The virtual schema VS_SALES stays in your database." "$out"
contains "the preprocessor stays" "INFO The SQL preprocessor PREPROC_RT.MASTER stays in your database." "$out"
contains "D4: the kit's launcher stays, and the line says why" "INFO Keeping the Exasol Personal launcher: your deployment 'starter-kit-local' still uses it." "$out"
check    "...and it is still there" kept "$(gone "$SBHOME/.local/bin/exasol")"
lacks    "no password on the screen" "not-a-real-password" "$out"
check    "the kit home is gone" gone "$(gone "$KITHOME/manifest.json")"

echo
echo "owner user, a dry run: the steps, and nothing changed"
seed
out="$(SC_DRY=1 bash "$TMP/run.sh" 2>&1)"
contains "the database is kept, by name" "INFO Keeping your database 'starter-kit-local' and all its data. It keeps the name 'starter-kit-local'." "$out"
contains "the login drop is a step" "INFO   will remove: the kit's login MCP_READONLY in your database 'starter-kit-local' (DROP USER)" "$out"
contains "the Scheduler's login, its schema handed over first" "INFO   will remove: the kit's login SCHEDULER_SVC in your database 'starter-kit-local'. Its schema SCHED stays and goes to SYS first (ALTER SCHEMA SCHED CHANGE OWNER SYS, then DROP USER)" "$out"
contains "the role drop is a step, with its condition" "INFO   will remove: the role SEMANTIC_USER in your database 'starter-kit-local', unless one of your own users holds it (DROP ROLE)" "$out"
contains "the framework's role, its schemas handed over first" "INFO   will remove: the role PREPROC_ADMIN in your database 'starter-kit-local', unless one of your own users holds it. Its schemas PREPROC and PREPROC_RT stay and go to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP ROLE)" "$out"
contains "the connection is listed" "INFO   The connection EXAKIT_SRC_SALES stays in your database. To remove it: DROP CONNECTION EXAKIT_SRC_SALES;" "$out"
contains "Semantic Views stays" "INFO   The Semantic Views schemas and their models stay in your database." "$out"
contains "the launcher line is said in the plan too" "Keeping the Exasol Personal launcher: your deployment 'starter-kit-local' still uses it." "$out"
lacks    "the plan never lists the launcher for removal" "will remove: CLI binary $SBHOME/.local/bin/exasol" "$out"
contains "it asked the database which schemas the logins and roles own" "WHERE SCHEMA_OWNER = 'SCHEDULER_SVC'" "$(statements)"
check    "...and nothing but reads reached it" "" "$(statements | grep -v '^SELECT ' || true)"
check    "the kit home is still there" kept "$(gone "$KITHOME/manifest.json")"
# A schema of the user's that the Scheduler's login owns: a real run hands it
# to SYS too, so the dry run names it.
DB_OWNERS_EXTRA=', "SALES_MART": "SCHEDULER_SVC"' seed
out="$(SC_DRY=1 bash "$TMP/run.sh" 2>&1)"
contains "every schema the real run hands over is named" "INFO   will remove: the kit's login SCHEDULER_SVC in your database 'starter-kit-local'. Its schemas SALES_MART and SCHED stay and go to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP USER)" "$out"
check    "...nothing but reads" "" "$(statements | grep -v '^SELECT ' || true)"
DB_OWNERS_EXTRA=', "SALES_MART": "SCHEDULER_SVC"' seed
out="$(bash "$TMP/run.sh" 2>&1)"
contains "...the same set the real run hands over" "INFO The schemas SALES_MART and SCHED stay in your database, now owned by SYS." "$out"
# The database does not answer: the records' schema, and any other it owns.
DB_DOWN=true seed
out="$(SC_DRY=1 bash "$TMP/run.sh" 2>&1)"
contains "a database that does not answer: the recorded schema and any other it owns" "INFO   will remove: the kit's login SCHEDULER_SVC in your database 'starter-kit-local'. Its schema SCHED and any other schema it owns stay and go to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP USER)" "$out"
contains "...and for a login with none recorded" "INFO   will remove: the kit's login MCP_READONLY in your database 'starter-kit-local'. Any schema it owns stays and goes to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP USER)" "$out"
check    "...nothing ran" "" "$(statements)"

echo
echo "owner user, the database is stopped: never started, the statements printed for later"
DB_DOWN=true seed
out="$(bash "$TMP/run.sh" 2>&1)"
contains "the run still answers 0" "RC=0" "$out"
contains "it says the database is not running" "WARN Your database 'starter-kit-local' is not running, so the kit's logins in it were not removed." "$out"
contains "...and what to run once it does, in the order a real run takes" "INFO Remove them once it runs, as sys:
INFO   -- any schema MCP_READONLY owns: ALTER SCHEMA <name> CHANGE OWNER SYS;
INFO   DROP USER IF EXISTS MCP_READONLY;
INFO   ALTER SCHEMA SCHED CHANGE OWNER SYS;  -- if SCHEDULER_SVC owns it
INFO   -- any other schema SCHEDULER_SVC owns: ALTER SCHEMA <name> CHANGE OWNER SYS;
INFO   DROP USER IF EXISTS SCHEDULER_SVC;
INFO   -- only if none of your own users needs the role SEMANTIC_USER:
INFO   -- any schema SEMANTIC_USER owns: ALTER SCHEMA <name> CHANGE OWNER SYS;
INFO   DROP ROLE IF EXISTS SEMANTIC_USER;
INFO   -- only if none of your own users needs the role PREPROC_ADMIN:
INFO   ALTER SCHEMA PREPROC CHANGE OWNER SYS;
INFO   ALTER SCHEMA PREPROC_RT CHANGE OWNER SYS;
INFO   -- any other schema PREPROC_ADMIN owns: ALTER SCHEMA <name> CHANGE OWNER SYS;
INFO   DROP ROLE IF EXISTS PREPROC_ADMIN;" "$out"
lacks    "...never CASCADE" "CASCADE" "$out"
check    "nothing was run" "" "$(statements)"
lacks    "nothing started it" "start" "$(cat "$TMP/launcher-calls" 2>/dev/null)"
check    "the database is still there" "the user data" "$(cat "$DEPLOY/data/table.dat" 2>/dev/null)"

echo
echo "owner user: SEC-01 first, then the add-ons, which leave the database alone"
seed
out="$(SC_ADDON=1 bash "$TMP/run.sh" 2>&1)"
sql="$(statements)"
check    "the add-on goes after the kit's logins and roles" yes "$(before 'DROP ROLE "PREPROC_ADMIN"' "ADDON semantic-views dry=0 keep=1" "$sql")"
contains "...told to keep the database" "ADDON semantic-views dry=0 keep=1" "$sql"
contains "...and it is removed" "OK Add-ons removed: semantic-views" "$out"
seed
out="$(SC_ADDON=1 SC_DRY=1 bash "$TMP/run.sh" 2>&1)"
check    "a dry run tells it the same (its plan only reads the database)" "ADDON semantic-views dry=1 keep=1" "$(statements | grep -v '^SELECT ' || true)"
contains "...after the database's plan lines" "INFO Keeping your database 'starter-kit-local' and all its data. It keeps the name 'starter-kit-local'." "$out"
seed
out="$(SC_ADDON=1 SC_OWNER=kit bash "$TMP/run.sh" 2>&1)"
contains "the kit's own database: the add-on's removal is as before" "ADDON semantic-views dry=0 keep=" "$(statements)"
lacks    "...with no keep switch" "keep=1" "$(statements)"

echo
echo "owner user: a login the kit did not create is never dropped"
# EXAKIT_MCP_READONLY_USER named a login of theirs: the kit took it over.
DB_USERS_EXTRA=', "BI_READER"' DB_SESSIONS_EXTRA=', "BI_READER": [51]' DB_OWNERS_EXTRA=', "BI_MART": "BI_READER"' seed
out="$(SC_MCP_USER=bi_reader bash "$TMP/run.sh" 2>&1)"
sql="$(statements)"
check    "nothing revoked, ended, handed over or dropped for it" "" "$(printf '%s
' "$sql" | grep 'BI_READER' | grep -v '^SELECT ' || true)"
lacks    "...its session not killed" "KILL SESSION 51" "$sql"
contains "the kit's own Scheduler login still goes" 'DROP USER "SCHEDULER_SVC"' "$sql"
contains "the screen says it stays, with the statement that drops it" "INFO The login BI_READER stays in your database: the kit did not create it. To remove it: DROP USER BI_READER;" "$out"
check    "its schema keeps its owner" "BI_READER" \
    "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["owners"]["BI_MART"])' "$DBSTATE")"
DB_USERS_EXTRA=', "BI_READER"' seed
out="$(SC_MCP_USER=bi_reader SC_DRY=1 bash "$TMP/run.sh" 2>&1)"
lacks    "the dry run never lists it for removal" "will remove: the kit's login BI_READER" "$out"
contains "...and says it stays" "INFO   The login BI_READER stays in your database: the kit did not create it. To remove it: DROP USER BI_READER;" "$out"
# The kit's own name, but the record says the kit took it over.
seed
out="$(SC_MCP_CREATED=false bash "$TMP/run.sh" 2>&1)"
check    "MCP_READONLY taken over (created false): never dropped, nothing revoked" "" \
    "$(statements | grep 'MCP_READONLY' | grep -v '^SELECT ' || true)"
seed
out="$(SC_MCP_CREATED=true bash "$TMP/run.sh" 2>&1)"
contains "MCP_READONLY the kit created: dropped" 'DROP USER "MCP_READONLY"' "$(statements)"

echo
echo "the record of who made the read-only login, written at setup"
# exakit_configure_mcp_readonly_access with its database calls stubbed: the
# login there or not (MCP_PRESENT), every other check passing.
cat > "$TMP/mcp-setup.sh" <<MCPSETUP
set -u
export HOME="$SBHOME" EXAKIT_HOME="$TMP/mcp-kit" EXAKIT_NO_FANCY=1
. "$ROOT/setup/lib/common.sh"
info(){ :; }; info_step(){ :; }; ok(){ :; }; ok_step(){ :; }; warn(){ :; }
require_python3() { :; }
exakit_exapump_bin() { printf '/usr/bin/true\n'; }
_exakit_add_bin_to_shell_rc() { :; }
_exakit_manifest_runtime_value() { case "\$1" in runtime.user) printf 'sys\n' ;; runtime.password_file) printf '%s\n' "$TMP/mcp-admin-pw" ;; esac; }
read_credential() { printf 'A1234567890ABCDEFGHIJKLM\n'; }
store_credential() { :; }
_exakit_parse_runtime_host() { printf 'localhost\n'; }
_exakit_parse_runtime_port() { printf '8563\n'; }
_exakit_write_exapump_config() { :; }
_exakit_exapump_sql_has_token() {
    case "\$3" in *EXAKIT_MCP_USER_PRESENT*) [ "\${MCP_PRESENT:-0}" = 1 ] ;; *) return 0 ;; esac
}
_exakit_run_exapump_sql() { printf '%s\n' "\${3%% IDENTIFIED BY *}" >> "$TMP/mcp-sql.log"; return 0; }
_exakit_assert_mcp_readonly_posture() { :; }
exakit_configure_mcp_readonly_access >/dev/null 2>&1
printf 'RC=%s CREATED=%s\n' "\$?" "\$(manifest_get components.mcp_server.connection.created 2>/dev/null || printf none)"
MCPSETUP
mcp_setup() { # mcp_setup <present 0|1> [<recorded user> [<recorded created>]]
    rm -rf "$TMP/mcp-kit"; mkdir -p "$TMP/mcp-kit"; : > "$TMP/mcp-sql.log"; printf 'pw\n' > "$TMP/mcp-admin-pw"
    printf '{"components": {"mcp_server": {"connection": {%s}}}}\n' \
        "${2:+\"user\": \"$2\"}${3:+, \"created\": $3}" > "$TMP/mcp-kit/manifest.json"
    MCP_PRESENT="$1" bash "$TMP/mcp-setup.sh"
}
check "a login made now (CREATE USER): created true" "RC=0 CREATED=true" "$(mcp_setup 0)"
contains "...it ran CREATE USER" "CREATE USER MCP_READONLY" "$(cat "$TMP/mcp-sql.log")"
check "a login that was there, no record of it: taken over, created false" "RC=0 CREATED=false" "$(mcp_setup 1)"
check "...a record of another login proves nothing: false" "RC=0 CREATED=false" "$(mcp_setup 1 bi_reader true)"
check "the kit's own login again, its record says created: stays true" "RC=0 CREATED=true" "$(mcp_setup 1 mcp_readonly true)"
check "a 0.3.0 record of the same login (no flag): none made up" "RC=0 CREATED=none" "$(mcp_setup 1 mcp_readonly)"

echo
echo "the kit's own database gone, a deployment of the user's found in its place: no statement"
seed
OTHER="$ROOT25/theirs"; mkdir -p "$OTHER"; printf '{"deploymentId": "0ther0ne"}\n' > "$OTHER/.exasolLauncherState.json"
out="$(SC_RECORDED_DIR="$ROOT25/gone-kit-db" SC_DEPLOY_DIR="$OTHER" bash "$TMP/run.sh" 2>&1)"
check    "no statement reached that database" "" "$(statements)"
lacks    "no SEC-01 line" "Removed the kit's login" "$out"
check    "that deployment stays" kept "$(gone "$OTHER/.exasolLauncherState.json")"

echo
echo "D4, owner kit: the launcher stays while another deployment uses it"
seed demo
out="$(SC_OWNER=kit bash "$TMP/run.sh" 2>&1)"
contains "the kit's database is torn down" "TEARDOWN $DEPLOY" "$out"
contains "the line names the deployment that still uses the launcher" "INFO Keeping the Exasol Personal launcher: your deployment 'demo' still uses it." "$out"
check    "the launcher is kept" kept "$(gone "$SBHOME/.local/bin/exasol")"
check    "their deployment stays" kept "$(gone "$ROOT25/demo/.exasolLauncherState.json")"
check    "no statement: the kit's own database is destroyed, not cleaned" "" "$(statements)"
seed demo
out="$(SC_OWNER=kit SC_DRY=1 bash "$TMP/run.sh" 2>&1)"
contains "dry run: the same line" "INFO Keeping the Exasol Personal launcher: your deployment 'demo' still uses it." "$out"
lacks    "dry run: the launcher is not on the removal list" "will remove: CLI binary $SBHOME/.local/bin/exasol" "$out"
seed stray
out="$(SC_OWNER=kit bash "$TMP/run.sh" 2>&1)"
lacks    "a stray folder with no launcher state does not keep it" "Keeping the Exasol Personal launcher" "$out"
check    "...and the launcher goes as before" gone "$(gone "$SBHOME/.local/bin/exasol")"
seed
out="$(SC_OWNER=kit bash "$TMP/run.sh" 2>&1)"
lacks    "no other deployment: no line" "Keeping the Exasol Personal launcher" "$out"
check    "...and the launcher goes" gone "$(gone "$SBHOME/.local/bin/exasol")"
check    "prune: the empty 2.5.0 root goes (recognised by its folder)" gone "$(gone "$SBHOME/.exasol")"
seed demo
out="$(SC_OWNER=kit SC_LAUNCHER=user SC_DRY=1 bash "$TMP/run.sh" 2>&1)"
contains "a launcher that is not the kit's is kept as before" "INFO Keeping exasol (not installed by this kit)." "$out"
lacks    "...with no D4 line" "Keeping the Exasol Personal launcher" "$out"
out="$(SC_OWNER=kit SC_LAUNCHER=user bash "$TMP/run.sh" 2>&1)"
lacks    "...in a real run either" "Keeping the Exasol Personal launcher" "$out"
check    "...and it is there" kept "$(gone "$SBHOME/.local/bin/exasol")"

echo
echo "mode P: the kit's private launcher home"
# The kit's launcher is the wrapper in its private home; the bin folder's
# exasol is the user's own (their 2.4 or 2.6).
P="$KITHOME/personal"
seed_private() {
    mkdir -p "$P/home/.exasol/launcher/deployments/starter-kit-local" "$P/libexec" "$P/bin"
    printf 'x\n' > "$P/libexec/exasol"
    printf '#!/bin/sh\nexit 0\n' > "$P/bin/exasol"; chmod +x "$P/bin/exasol"
}
seed; seed_private
out="$(SC_OWNER=kit SC_LAUNCHER_PATH="$P/bin/exasol" SC_PERSONAL_BIN="$P/bin/exasol" bash "$TMP/run.sh" 2>&1)"
lacks    "nothing but the kit's own there: no line" "Keeping the Exasol Personal launcher" "$out"
check    "it goes with the kit home" gone "$(gone "$P")"
check    "the user's own exasol in the bin folder stays" kept "$(gone "$SBHOME/.local/bin/exasol")"
contains "Q29: the kit's own launcher is named in the commands removed" "exasol (the kit's own)" "$out"
seed; seed_private
mkdir -p "$P/home/.exasol/launcher/deployments/demo"
printf '{"deploymentId": "feed0002"}\n' > "$P/home/.exasol/launcher/deployments/demo/.exasolLauncherState.json"
out="$(SC_OWNER=kit SC_LAUNCHER_PATH="$P/bin/exasol" SC_PERSONAL_BIN="$P/bin/exasol" bash "$TMP/run.sh" 2>&1)"
contains "another deployment in its own root: kept, and said" "INFO Keeping the Exasol Personal launcher: your deployment 'demo' still uses it." "$out"
check    "the private launcher stays" kept "$(gone "$P/bin/exasol")"
check    "...with that deployment" kept "$(gone "$P/home/.exasol/launcher/deployments/demo/.exasolLauncherState.json")"
check    "the rest of the kit home goes" gone "$(gone "$KITHOME/manifest.json")"
lacks    "Q29: a launcher that stays is not named as removed" "exasol (the kit's own)" "$out"
check    "the user's own exasol in the bin folder stays" kept "$(gone "$SBHOME/.local/bin/exasol")"

echo
echo "the component removal never destroys a database the user let the kit use"
seed
out="$(SC_COMPONENT=database bash "$TMP/run.sh" 2>&1)"
lacks    "no teardown" "TEARDOWN" "$out"
check    "the database stays" "the user data" "$(cat "$DEPLOY/data/table.dat" 2>/dev/null)"

printf 'mode K, the kit launcher in the kit folder, D4, the kit MCP server in the kept database:\n'
seed; mkdir -p "$KITHOME/personal/bin"; mv "$SBHOME/.local/bin/exasol" "$KITHOME/personal/bin/exasol"; rm -f "$TMP/launcher-calls"
out="$(SC_SIDECAR=1 SC_LAUNCHER_PATH="$KITHOME/personal/bin/exasol" PATH="/usr/bin:/bin:$(dirname "$PY")" bash "$TMP/run.sh" 2>&1)"
check    "the MCP server is removed by the kit's launcher before it moves" "1" "$(grep -c '^sidecar disable' "$TMP/launcher-calls" 2>/dev/null)"
lacks    "...with no issue reported" "Removing the MCP sidecar reported issues" "$out"
check    "...and then the launcher moves to ~/.local/bin" "yes" "$([ -x "$SBHOME/.local/bin/exasol" ] && echo yes)"
printf 'the same, with a file at ~/.local/bin/exasol already:\n'
seed; mkdir -p "$KITHOME/personal/bin"; cp "$SBHOME/.local/bin/exasol" "$KITHOME/personal/bin/exasol"; chmod -x "$SBHOME/.local/bin/exasol"
out="$(SC_LAUNCHER_PATH="$KITHOME/personal/bin/exasol" PATH="/usr/bin:/bin:$(dirname "$PY")" bash "$TMP/run.sh" 2>&1)"
check    "the launcher stays in the kit folder, that file as it was" "kept|no" "$(gone "$KITHOME/personal/bin/exasol")|$([ -x "$SBHOME/.local/bin/exasol" ] && echo yes || echo no)"
printf 'the same, with a launcher of the user off PATH on record:\n'
seed; mkdir -p "$KITHOME/personal/bin" "$SBHOME/theirs"; printf '#!/bin/sh\n[ "$1" = version ] && echo 2.5.0\nexit 0\n' > "$SBHOME/theirs/exasol"; chmod +x "$SBHOME/theirs/exasol"; mv "$SBHOME/.local/bin/exasol" "$KITHOME/personal/bin/exasol"
out="$(SC_USER_LAUNCHER="$SBHOME/theirs/exasol" SC_LAUNCHER_PATH="$KITHOME/personal/bin/exasol" PATH="/usr/bin:/bin:$(dirname "$PY")" bash "$TMP/run.sh" 2>&1)"
lacks    "the kit's launcher is not kept for their deployment" "Keeping the Exasol Personal launcher" "$out"
check    "...it goes, theirs stays" "gone|kept" "$(gone "$KITHOME/personal/bin/exasol")|$(gone "$SBHOME/theirs/exasol")"

# D4 NEXT TO A LAUNCHER OF THE USER'S (DOC-01): the kit's launcher goes only
# when theirs can open the deployments that stay, so only when its version is
# readable and on the 2.5 line or newer. A 2.4 does not list them. Theirs is
# asked `version` only, time-bounded, and its file is the same afterwards.
seed_theirs() { # seed_theirs <owner> <version|unread|hang|link|none>
    if [ "$1" = kit ]; then seed demo; else seed; fi
    mkdir -p "$KITHOME/personal/bin" "$SBHOME/theirs"
    mv "$SBHOME/.local/bin/exasol" "$KITHOME/personal/bin/exasol"
    rm -f "$TMP/theirs-calls"
    case "$2" in
        none)   return 0 ;;
        link)   ln -s "$KITHOME/personal/bin/exasol" "$SBHOME/theirs/exasol"; return 0 ;;
        unread) _st_say='echo "Error: no such command"' ;;
        hang)   _st_say='exec sleep 240' ;;
        *)      _st_say="echo $2" ;;
    esac
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n[ "$1" = version ] && { %s; }\nexit 0\n' "$TMP/theirs-calls" "$_st_say" > "$SBHOME/theirs/exasol"
    chmod +x "$SBHOME/theirs/exasol"
}
run_theirs() { # run_theirs <owner> <on|off>: on PATH, or off PATH and on record
    _rt_path="/usr/bin:/bin:$(dirname "$PY")"; _rt_rec=""
    if [ "$2" = on ]; then _rt_path="$SBHOME/theirs:$_rt_path"; else _rt_rec="$SBHOME/theirs/exasol"; fi
    SC_OWNER="$1" SC_USER_LAUNCHER="$_rt_rec" SC_LAUNCHER_PATH="$KITHOME/personal/bin/exasol" PATH="$_rt_path" bash "$TMP/run.sh" 2>&1
}
for _owner in user kit; do
    _name=starter-kit-local; [ "$_owner" = kit ] && _name=demo
    for _where in on off; do
        printf "D4, owner %s, a launcher of the user's %s PATH:\n" "$_owner" "$_where"
        for _ver in 2.4.0 unread none 2.5.0 2.6.0; do
            seed_theirs "$_owner" "$_ver"
            _sha="$(cksum 2>/dev/null < "$SBHOME/theirs/exasol" || true)"
            out="$(run_theirs "$_owner" "$_where")"
            case "$_ver" in
                2.5.0|2.6.0)
                    lacks "$_ver: no line" "Keeping the Exasol Personal launcher" "$out"
                    check "$_ver: the kit's launcher goes" "gone|gone" "$(gone "$KITHOME/personal")|$(gone "$SBHOME/.local/bin/exasol")" ;;
                *)
                    contains "$_ver: the line names the deployment" "INFO Keeping the Exasol Personal launcher: your deployment '$_name' still uses it." "$out"
                    check "$_ver: the kit's launcher is at ~/.local/bin, and runs" "kept|yes" "$(gone "$SBHOME/.local/bin/exasol")|$([ -x "$SBHOME/.local/bin/exasol" ] && echo yes)"
                    lacks "$_ver: it is not named as removed" "exasol (the kit's own)" "$out" ;;
            esac
            check "$_ver: the deployment stays" kept "$(gone "$ROOT25/$_name/.exasolLauncherState.json")"
            case "$_ver" in
                none) ;;
                *)  check "$_ver: theirs is as it was" "$_sha" "$(cksum 2>/dev/null < "$SBHOME/theirs/exasol" || true)"
                    check "$_ver: ...and asked its version only" "version" "$(sort -u "$TMP/theirs-calls" 2>/dev/null)" ;;
            esac
        done
    done
done
printf "a link on PATH to the kit's own launcher is not the user's\n"
seed_theirs user link
out="$(run_theirs user on)"
contains "the line" "INFO Keeping the Exasol Personal launcher: your deployment 'starter-kit-local' still uses it." "$out"
printf "which versions of theirs count, next to the pinned 2.5\n"
seed_theirs user none
cat > "$TMP/counts.sh" <<HARNESS
export HOME="$SBHOME" EXAKIT_HOME="$KITHOME" EXAKIT_BIN_DIR="$SBHOME/.local/bin" EXAKIT_NO_FANCY=1
unset EXAKIT_PERSONAL_VERSION EXAKIT_PERSONAL_VERSION_FALLBACK EXAKIT_LOG_FILE
. "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
. "$ROOT/setup/lib/runtime-personal.sh" >/dev/null 2>&1
manifest_get(){ :; }
for _v in "2.4.99" "v2.4.9" "1.9" "2" "2.x" "v" "" "Error: 2.5.0" "2.5.0" "v2.5.3" "2.5.0-rc1" "2.6.0" "2.10.1" "3.0.0"; do
    printf '#!/bin/sh\necho "%s"\n' "\$_v" > "$SBHOME/theirs/exasol"; chmod +x "$SBHOME/theirs/exasol"
    PATH="$SBHOME/theirs:\$PATH" _exakit_uninstall_user_launcher "$KITHOME/personal/bin/exasol" && printf '[%s] ' "\$_v"
done
HARNESS
check "only a readable 2.5 or newer" "[2.5.0] [v2.5.3] [2.5.0-rc1] [2.6.0] [2.10.1] [3.0.0] " "$(bash "$TMP/counts.sh")"
printf "a launcher of the user's that hangs on version: bounded, the kit's stays\n"
seed_theirs user hang
_t0="$(date +%s)"
out="$(EXAKIT_PERSONAL_PROBE_TIMEOUT=2 run_theirs user on)"
contains "the line" "INFO Keeping the Exasol Personal launcher: your deployment 'starter-kit-local' still uses it." "$out"
check    "...within its bound" yes "$([ $(( $(date +%s) - _t0 )) -lt 200 ] && echo yes || echo no)"
printf 'a 2.4 on PATH, a 2.5 of theirs on record: theirs opens them\n'
seed_theirs user 2.4.0
mkdir -p "$SBHOME/theirs25"; printf '#!/bin/sh\n[ "$1" = version ] && echo 2.5.1\nexit 0\n' > "$SBHOME/theirs25/exasol"; chmod +x "$SBHOME/theirs25/exasol"
out="$(SC_USER_LAUNCHER="$SBHOME/theirs25/exasol" SC_LAUNCHER_PATH="$KITHOME/personal/bin/exasol" PATH="$SBHOME/theirs:/usr/bin:/bin:$(dirname "$PY")" bash "$TMP/run.sh" 2>&1)"
lacks    "no line" "Keeping the Exasol Personal launcher" "$out"
printf "the user's 2.4 at ~/.local/bin/exasol: never overwritten, the kit's stays in the kit folder\n"
for _owner in user kit; do
    seed_theirs "$_owner" 2.4.0; cp "$SBHOME/theirs/exasol" "$SBHOME/.local/bin/exasol"
    _sha="$(cksum < "$SBHOME/.local/bin/exasol")"
    out="$(SC_OWNER="$_owner" SC_USER_LAUNCHER="$SBHOME/.local/bin/exasol" SC_LAUNCHER_PATH="$KITHOME/personal/bin/exasol" PATH="$SBHOME/.local/bin:/usr/bin:/bin:$(dirname "$PY")" bash "$TMP/run.sh" 2>&1)"
    contains "owner $_owner: the line" "INFO Keeping the Exasol Personal launcher: your deployment" "$out"
    check    "owner $_owner: theirs as it was, the kit's in the kit folder, the rest of the kit home gone" "$_sha|kept|personal" \
        "$(cksum < "$SBHOME/.local/bin/exasol")|$(gone "$KITHOME/personal/bin/exasol")|$(ls -A "$KITHOME")"
done
printf 'the same 2.4, a dry run: the same line, nothing changed\n'
seed_theirs user 2.4.0
out="$(SC_DRY=1 run_theirs user on)"
contains "the line" "INFO Keeping the Exasol Personal launcher: your deployment 'starter-kit-local' still uses it." "$out"
check    "nothing changed" "kept|kept" "$(gone "$KITHOME/personal/bin/exasol")|$(gone "$KITHOME/manifest.json")"
printf "mode P: a 2.5 of the user's on PATH never sees the private home, which stays whole\n"
seed; seed_private
mkdir -p "$P/home/.exasol/launcher/deployments/demo" "$SBHOME/theirs"
printf '{"deploymentId": "feed0002"}\n' > "$P/home/.exasol/launcher/deployments/demo/.exasolLauncherState.json"
printf '#!/bin/sh\n[ "$1" = version ] && echo 2.5.0\nexit 0\n' > "$SBHOME/theirs/exasol"; chmod +x "$SBHOME/theirs/exasol"
out="$(SC_OWNER=kit SC_LAUNCHER_PATH="$P/bin/exasol" SC_PERSONAL_BIN="$P/bin/exasol" PATH="$SBHOME/theirs:/usr/bin:/bin:$(dirname "$PY")" bash "$TMP/run.sh" 2>&1)"
contains "the line" "INFO Keeping the Exasol Personal launcher: your deployment 'demo' still uses it." "$out"
check    "wrapper, program and deployment stay" "kept|kept|kept" "$(gone "$P/bin/exasol")|$(gone "$P/libexec/exasol")|$(gone "$P/home/.exasol/launcher/deployments/demo/.exasolLauncherState.json")"

printf 'a database in the kit home that this run did not remove, in any root:\n'
for _root in personal/home/.exasol/personal/deployments personal/home/.exasol/launcher/deployments mine; do
    for _name in default starter-kit-local; do
        seed; rm -rf "$ROOT25"
        _there="$KITHOME/$_root/$_name"
        mkdir -p "$_there/data" "$KITHOME/personal/libexec" "$KITHOME/personal/bin"
        printf '{"deploymentId": "abcd9999"}\n' > "$_there/.exasolLauncherState.json"
        printf 'every table of the kit\n' > "$_there/data/table.dat"
        printf '#!/bin/sh\n[ "$1" = deployments ] && { echo "[]"; exit 0; }\nexit 0\n' > "$KITHOME/personal/libexec/exasol"; chmod +x "$KITHOME/personal/libexec/exasol"
        cp "$KITHOME/personal/libexec/exasol" "$KITHOME/personal/bin/exasol"
        out="$(SC_OWNER=kit SC_LAUNCHER_PATH="$KITHOME/personal/bin/exasol" SC_DEPLOY_DIR="$SBHOME/.exasol/personal/deployments/default" \
            SC_RECORDED_DIR="$SBHOME/.exasol/personal/deployments/default" bash "$TMP/run.sh" 2>&1)"
        check "$_root/$_name: its tables are still there after the uninstall" "every table of the kit" "$(cat "$_there/data/table.dat" 2>/dev/null || echo GONE)"
        check "$_root/$_name: ...the rest of the kit home is gone" "gone" "$(gone "$KITHOME/credentials")"
    done
done

printf '\nuninstall-owner-user.sh: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
