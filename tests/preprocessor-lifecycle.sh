#!/usr/bin/env bash
# The SQL preprocessor framework's life inside the kit, end to end against a
# simulated database (tests/lib/fake-exapump.py): install, session trial,
# activation, fresh-connection verification, and every way each of those can
# go wrong.
#
# The invariants worth a suite:
#   1. The slot is only ever changed for the kit's own dispatcher, and only
#      after a session using it ran ordinary SQL and a scoped module.
#   2. A failure after the database default changed puts the previous setting
#      back - the database is never left with a preprocessor that broke it.
#   3. release.sql is clean-install only, so it is never replayed over an
#      existing framework; only the kit's OWN interrupted install is dropped,
#      and never one that carries someone's rules.
#   4. Anything the kit does not manage - another script in the slot, a
#      framework someone installed by hand - is left exactly as it was. The
#      user's own script in the slot is a recorded choice (declined), not a
#      failure that every later run repeats.
#   5. A package that does not match the pin is never executed, and an
#      installed framework is verified without the network.
#
# Then the shell bridge: the installer step renders the coordinator's lines,
# fetches the package only when a fresh install asks for it, records the core
# task only after the checks pass, and books a failure in the closing summary.
#
#   bash tests/preprocessor-lifecycle.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; printf '         expected: %s\n         actual:   %s\n' "$2" "$3"; fi
}
has() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1"; printf '         missing: %s\n         in: %.300s\n' "$2" "$3" ;; esac
}
lacks() {
    case "$3" in *"$2"*) fail "$1"; printf '         unexpected: %s\n' "$2" ;; *) pass "$1" ;; esac
}

command -v python3 >/dev/null 2>&1 || { echo "python3 is required for this suite"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PY="$ROOT/setup/preprocessor/manage.py"
FAKE="$ROOT/tests/lib/fake-exapump.py"

# The stand-in exapump: a script, so manage.py runs it exactly as it runs the
# real binary.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/exapump" <<EOF
#!/bin/sh
exec python3 "$FAKE" "\$@"
EOF
chmod +x "$WORK/bin/exapump"

# A small release.sql with the real one's shape: an unguarded CREATE ROLE, the
# two schemas and their owner, the four grants (0.9.1's own, in its order), the
# scripts the kit checks for, the Python module resolver a local deployment
# cannot create, the seed rule, the refresh.
PKG="$WORK/release.sql"
{
    printf 'CREATE ROLE PREPROC_ADMIN;\nCREATE SCHEMA IF NOT EXISTS PREPROC;\nCREATE SCHEMA IF NOT EXISTS PREPROC_RT;\n'
    printf 'ALTER SCHEMA PREPROC CHANGE OWNER PREPROC_ADMIN;\nALTER SCHEMA PREPROC_RT CHANGE OWNER PREPROC_ADMIN;\n'
    printf 'GRANT EXECUTE ON SCHEMA PREPROC_RT TO PUBLIC;\nGRANT SELECT ON SCHEMA PREPROC_RT TO PUBLIC;\n'
    printf 'GRANT SELECT ANY DICTIONARY TO PREPROC_ADMIN;\nGRANT CREATE SCRIPT TO PREPROC_ADMIN;\n'
    for s in PREPROC_RT.MASTER PREPROC_RT.CONTROL_SUGAR_V1 PREPROC.REFRESH_CORE PREPROC.REFRESH \
             PREPROC.STATUS PREPROC.RULE_ENSURE PREPROC.RULE_DROP PREPROC.RULE_LIST \
             PREPROC.MODULE_REGISTER PREPROC.MODULE_RETIRE PREPROC.MODULE_RECLAIM; do
        printf -- '--/\nCREATE OR REPLACE LUA SCRIPT %s() AS\nlocal a = "x;y"\n/\n' "$s"
    done
    printf -- '\n--/\n-- the registry resolver: fetches modules from a URL\nCREATE OR REPLACE PYTHON3 SET SCRIPT PREPROC.MODULE_RESOLVER_V1(src VARCHAR(2000)) EMITS (s VARCHAR(10)) AS\ndef run(ctx):\n    ctx.emit("OK")\n/\n'
    printf -- '--/\nCREATE OR REPLACE LUA SCRIPT PREPROC.MODULE_INSTALL() AS\nlocal r = "PREPROC.MODULE_RESOLVER_V1"\n/\n'
    printf 'INSERT INTO PREPROC.CONFIG (rule_id) SELECT 1;\nEXECUTE SCRIPT PREPROC.REFRESH;\n'
} > "$PKG"
SHA="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$PKG")"
CORE="$(python3 "$PY" derive --package "$PKG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"

printf '\n== the core-only package ==\n'
_derived="$(python3 "$PY" derive --package "$PKG" --out "$WORK/core.sql")"
has "derive leaves out the Python resolver, and only it" '"left_out": ["PREPROC.MODULE_RESOLVER_V1"]' "$_derived"
lacks "...no PYTHON3 statement is left" "CREATE OR REPLACE PYTHON3" "$(cat "$WORK/core.sql")"
has "...the Lua script that names it is kept" "CREATE OR REPLACE LUA SCRIPT PREPROC.MODULE_INSTALL" "$(cat "$WORK/core.sql")"
# The only change is one contiguous deletion: the resolver's "--/" opener, its
# comment, its body and its closing "/". Nothing added, nothing else removed.
_diff="$(diff "$PKG" "$WORK/core.sql")"
check "...and the only change is that block, deleted whole" "1 0 6" \
    "$(printf '%s\n' "$_diff" | grep -c '^[0-9]') $(printf '%s\n' "$_diff" | grep -c '^>') $(printf '%s\n' "$_diff" | grep -c '^<')"
has "...and it is the Python script" "< CREATE OR REPLACE PYTHON3 SET SCRIPT PREPROC.MODULE_RESOLVER_V1" "$_diff"

# scenario <name> [state-json] — a fresh database state and manifest.
scenario() {
    D="$WORK/$1"
    mkdir -p "$D"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$D/state.json"; else printf '{}\n' > "$D/state.json"; fi
    printf '{"components": {}, "steps_completed": []}\n' > "$D/manifest.json"
}
# ensure [extra args...] — run the coordinator against the current scenario.
ensure() {
    FAKE_EXAPUMP_STATE="$D/state.json" python3 "$PY" ensure --exapump "$WORK/bin/exapump" \
        --profile starter-kit --manifest "$D/manifest.json" --admin-user sys \
        --pin-version 0.9.1 --pin-ref v0.9.1 --pin-sha256 "$SHA" --pin-core-sha256 "$CORE" \
        --log "$D/log" "$@" > "$D/out" 2>&1
    RC=$?
    OUT="$(cat "$D/out")"
}
st()  { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if not isinstance(v,str) else v)' "$D/state.json" "$1"; }
rec() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("components",{}).get("preprocessor",{}).get(sys.argv[2])
print(json.dumps(v) if not isinstance(v,str) else v)' "$D/manifest.json" "$1"; }
calls() { python3 -c 'import json,sys; print("\n".join(s for c in json.load(open(sys.argv[1]))["calls"] for s in c))' "$D/state.json"; }
reset_calls() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["calls"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"; }
fault() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.setdefault("faults",[]).append(sys.argv[2]); json.dump(d,open(p,"w"))' "$D/state.json" "$1"; }
set_rec() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.setdefault("components",{})["preprocessor"]=json.loads(sys.argv[2]); json.dump(d,open(p,"w"))' "$D/manifest.json" "$1"; }

printf '\n== a fresh database: the package is asked for, then installed, tried, activated ==\n'
scenario fresh
ensure
check "no package on hand: exit 10, a fresh install needs it" "10" "$RC"
check "...and nothing was created" "[]" "$(st schemas)"
lacks "...and the slot was not touched" "ALTER SYSTEM" "$(calls)"

ensure --package "$WORK/nowhere.sql"
check "a package path that does not exist is the same answer" "10" "$RC"

printf 'tampered\n' >> "$WORK/tampered.sql"; cat "$PKG" >> "$WORK/tampered.sql"
ensure --package "$WORK/tampered.sql"
check "a package that does not match the pin: exit 11" "11" "$RC"
has "...naming both digests" "does not match the pinned SHA-256" "$OUT"
lacks "...and it never reached the database" "CREATE ROLE" "$(calls)"

reset_calls
ensure --package "$PKG"
check "with the pinned package: ready, on a database that has no Python" "0" "$RC"
lacks "...the Python resolver never reached it" "PYTHON3" "$(calls)"
check "...recorded as the core-only package" "core-only $CORE" "$(rec package) $(rec core_sha256)"
check "...naming what it left out" '["PREPROC.MODULE_RESOLVER_V1"]' "$(rec left_out)"
check "the dispatcher holds the slot" "PREPROC_RT.MASTER" "$(st system_slot)"
check "both schemas exist" '["PREPROC", "PREPROC_RT"]' "$(st schemas)"
_install_first="$(python3 -c 'import json,sys; print(next(c[0] for c in json.load(open(sys.argv[1]))["calls"] if any(s.startswith("CREATE ROLE") for s in c)))' "$D/state.json")"
check "the install ran in a session that bypasses any preprocessor" "ALTER SESSION SET sql_preprocessor_script = ''" "$_install_first"
_seq="$(calls | grep -n -E "^ALTER SESSION SET sql_preprocessor_script = PREPROC_RT.MASTER|^ALTER SYSTEM SET sql_preprocessor_script = PREPROC_RT.MASTER" | cut -d: -f2- | awk '{print $1, $2}' | tr '\n' '|')"
check "the session trial comes before the database default" "ALTER SESSION|ALTER SYSTEM|" "$_seq"
check "the probe module is gone afterwards" "false" "$(python3 -c 'import json,sys; print(str("PREPROC_RT.EXAKIT_PROBE_V1" in json.load(open(sys.argv[1]))["scripts"]).lower())' "$D/state.json")"
check "...and so is its rule" '[{"id": 1, "script": "PREPROC_RT.CONTROL_SUGAR_V1"}]' "$(st rules)"
check "recorded: active" "active" "$(rec state)"
check "recorded: validated" "true" "$(rec validated)"
check "recorded: the pinned version" "0.9.1" "$(rec version)"
check "recorded: the verified digest" "$SHA" "$(rec sha256)"
check "recorded: the setting to restore" "" "$(rec previous_setting)"
has "the screen line names the version" "OK SQL preprocessor framework 0.9.1 installed, tested and activated" "$OUT"
has "...and ordinary SQL" "OK Ordinary SQL verified with the framework active" "$OUT"
if grep -q "$SHA" "$D/log" 2>/dev/null || ! grep -q 'PREPROC \[' "$D/log" 2>/dev/null; then
    fail "exapump's progress lines reach the log (and nothing else does)"
else
    pass "exapump's progress lines reach the log (and nothing else does)"
fi

scenario core-pin
ensure --package "$PKG" --pin-core-sha256 "$(printf '0%.0s' $(seq 1 64))"
check "a derived package that does not match its own pin: exit 11" "11" "$RC"
has "...said as such" "core-only package derived from the verified download does not match" "$OUT"
check "...and nothing ran" "[]" "$(st schemas)"

D="$WORK/fresh"
printf '\n== every later pass verifies, and never replays release.sql ==\n'
reset_calls
ensure
check "an active framework verifies without the package" "0" "$RC"
lacks "release.sql was not run again" "CREATE ROLE" "$(calls)"
lacks "the default was not touched" "ALTER SYSTEM" "$(calls)"
has "the screen says so" "OK SQL preprocessor framework 0.9.1 verified and active" "$OUT"

printf '\n== what the kit does not manage is left alone ==\n'
# PRE-02. The user's own script in the slot was a conflict (exit 3) that the
# installer booked as a failure on every pass, and that made every `exakit
# update` rerun the installer and exit 1 with "Retry with: exakit update" - a
# remedy that could never work while the user kept their script. It is the
# user's choice: declined, recorded with its holder, said once.
scenario conflict '{"system_slot": "MYSCHEMA.MY_PREPROCESSOR"}'
ensure --package "$PKG" --opt-in-command "curl -fsSL https://example.invalid/install.sh | sh"
check "another script in the slot: declined, exit 4" "4" "$RC"
check "...the slot still holds it" "MYSCHEMA.MY_PREPROCESSOR" "$(st system_slot)"
lacks "...nothing was installed" "CREATE ROLE" "$(calls)"
lacks "...no ALTER of any kind" "ALTER SYSTEM" "$(calls)"
check "...recorded as declined, with the slot's holder" "true MYSCHEMA.MY_PREPROCESSOR" "$(rec declined) $(rec slot_holder)"
lacks "...and it is not a failure" "FAIL " "$OUT"
has "...said once, as information naming the holder" "INFO The database's SQL preprocessor slot holds MYSCHEMA.MY_PREPROCESSOR" "$OUT"
has "...with how to opt in later" "clear the slot (ALTER SYSTEM SET sql_preprocessor_script = NULL) or move that script into a framework module, then run curl -fsSL https://example.invalid/install.sh | sh again" "$OUT"
has "...and one line for the step" "OK SQL preprocessor slot left to MYSCHEMA.MY_PREPROCESSOR" "$OUT"
_declined_at="$(rec declined_at)"
reset_calls
ensure --package "$PKG"
check "the next pass: still declined, still exit 4" "4" "$RC"
lacks "...without saying the whole story again" "INFO " "$OUT"
has "...only the step's line" "OK SQL preprocessor slot left to MYSCHEMA.MY_PREPROCESSOR" "$OUT"
check "...and the record keeps when it was first declined" "$_declined_at" "$(rec declined_at)"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["system_slot"]=""; d["calls"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
ensure --package "$PKG"
check "the user cleared the slot: the next pass installs and activates" "0 PREPROC_RT.MASTER" "$RC $(st system_slot)"
check "...and the decline is gone from the record" "null null active" "$(rec declined) $(rec slot_holder) $(rec state)"

scenario foreign '{"schemas": ["PREPROC", "PREPROC_RT"], "role": true, "scripts": ["PREPROC_RT.MASTER"]}'
ensure --package "$PKG"
check "a framework someone else installed and left inactive: exit 3" "3" "$RC"
lacks "...not dropped" "DROP SCHEMA" "$(calls)"
lacks "...not activated" "ALTER SYSTEM" "$(calls)"

ALL_SCRIPTS='"PREPROC_RT.MASTER", "PREPROC_RT.CONTROL_SUGAR_V1", "PREPROC.REFRESH_CORE", "PREPROC.REFRESH", "PREPROC.STATUS", "PREPROC.RULE_ENSURE", "PREPROC.RULE_DROP", "PREPROC.RULE_LIST"'
scenario adopted "{\"system_slot\": \"PREPROC_RT.MASTER\", \"schemas\": [\"PREPROC\", \"PREPROC_RT\"], \"role\": true, \"scripts\": [$ALL_SCRIPTS]}"
ensure
check "a framework someone installed AND activated is verified" "0" "$RC"
check "...and recorded as pre-existing" "pre-existing" "$(rec origin)"
lacks "...without reinstalling it" "CREATE ROLE" "$(calls)"

printf '\n== the kit recovers its own interrupted install, and only that ==\n'
scenario interrupted '{"schemas": ["PREPROC"], "role": true, "scripts": []}'
set_rec '{"state": "installing", "version": "0.9.1"}'
ensure
check "without the package: exit 10, nothing dropped yet" "10" "$RC"
lacks "...no DROP issued" "DROP SCHEMA" "$(calls)"
ensure --package "$PKG"
check "with the package: cleaned up and installed" "0" "$RC"
has "...it dropped its own schemas first" "DROP SCHEMA IF EXISTS PREPROC CASCADE" "$(calls)"
has "...and its role" "DROP ROLE IF EXISTS PREPROC_ADMIN CASCADE" "$(calls)"
check "...and the framework is active" "PREPROC_RT.MASTER" "$(st system_slot)"

scenario interrupted-with-rules '{"schemas": ["PREPROC"], "role": true, "scripts": [], "rules": [{"id": 1, "script": "PREPROC_RT.CONTROL_SUGAR_V1"}, {"id": 2, "script": "PREPROC_RT.SOMEONES_MODULE_V1"}]}'
set_rec '{"state": "installing", "version": "0.9.1"}'
ensure --package "$PKG"
check "an interrupted install that carries someone's rules is refused" "1" "$RC"
has "...naming the rule's script" "PREPROC_RT.SOMEONES_MODULE_V1" "$OUT"
has "...and what a person can do about it" "Keep them by activating the framework" "$OUT"
lacks "...and nothing is dropped" "DROP SCHEMA" "$(calls)"

# Audit SCR-06: a CONFIG that cannot be read is never "no rules": nothing is
# dropped. One that does not exist yet (the install stopped before it) is.
scenario interrupted-unreadable-rules '{"schemas": ["PREPROC"], "role": true, "scripts": [], "rules": [{"id": 2, "script": "PREPROC_RT.SOMEONES_MODULE_V1"}]}'
set_rec '{"state": "installing", "version": "0.9.1"}'
fault "fail_on:FROM PREPROC.CONFIG"
ensure --package "$PKG"
check "an interrupted install whose rules cannot be read is refused" "1" "$RC"
has "...saying why" "whether PREPROC.CONFIG holds anyone's rules could not be read" "$OUT"
lacks "...and nothing is dropped" "DROP SCHEMA" "$(calls)"
check "...the rules are still there" "1" "$(st rules | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

scenario interrupted-before-config '{"schemas": ["PREPROC_RT"], "role": true, "scripts": []}'
set_rec '{"state": "installing", "version": "0.9.1"}'
ensure --package "$PKG"
check "an interrupted install that never made PREPROC.CONFIG is cleaned up and installed" "0" "$RC"
has "...it dropped its own schemas first" "DROP SCHEMA IF EXISTS PREPROC_RT CASCADE" "$(calls)"

scenario activated-by-hand "{\"system_slot\": \"PREPROC_RT.MASTER\", \"schemas\": [\"PREPROC\", \"PREPROC_RT\"], \"role\": true, \"scripts\": [$ALL_SCRIPTS]}"
set_rec '{"state": "installing", "version": "0.9.1"}'
ensure
check "an interrupted install someone activated by hand is verified and recorded active" "0 active" "$RC $(rec state)"
lacks "...without reinstalling" "CREATE ROLE" "$(calls)"

scenario stale-resolution "{\"system_slot\": \"PREPROC_RT.MASTER\", \"schemas\": [\"PREPROC\", \"PREPROC_RT\"], \"role\": true, \"scripts\": [$ALL_SCRIPTS], \"stale\": true}"
set_rec '{"state": "active", "version": "0.9.1"}'
ensure
check "a user created since the last refresh: the run refreshes the rule resolution" "0 1" \
    "$RC $(printf '%s\n' "$(calls)" | grep -c 'EXECUTE SCRIPT PREPROC.REFRESH')"
has "...and says so" "Rule resolution refreshed" "$OUT"
reset_calls; ensure
lacks "...once: a current resolution is left alone" "PREPROC.REFRESH" "$(calls)"

scenario install-dies
fault "fail_on:PREPROC.REFRESH_CORE"
ensure --package "$PKG"
check "an install that dies part way: exit 1" "1" "$RC"
check "...the slot is untouched" "" "$(st system_slot)"
check "...and the record says installing, for the next run to recover" "installing" "$(rec state)"
has "...the database's own message reaches the reason" "injected failure on PREPROC.REFRESH_CORE" "$OUT"

printf '\n== activation is tried in one session before the default changes ==\n'
scenario no-dispatch
fault "no_dispatch"
ensure --package "$PKG"
check "a dispatcher that does not run the scoped module: exit 1" "1" "$RC"
check "...the database default was never changed" "" "$(st system_slot)"
lacks "...no ALTER SYSTEM at all" "ALTER SYSTEM" "$(calls)"
check "...recorded installed, not active" "installed" "$(rec state)"
check "...and the probe was cleaned up" "false" "$(python3 -c 'import json,sys; print(str("PREPROC_RT.EXAKIT_PROBE_V1" in json.load(open(sys.argv[1]))["scripts"]).lower())' "$D/state.json")"
# The next pass, with the fault gone, finishes the activation without
# reinstalling.
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; d["calls"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
ensure
check "the next pass activates the installed framework" "0" "$RC"
lacks "...without reinstalling" "CREATE ROLE" "$(calls)"

scenario alter-system-refused
fault "fail_alter_system"
ensure --package "$PKG"
check "a refused ALTER SYSTEM: exit 1" "1" "$RC"
check "...slot unchanged" "" "$(st system_slot)"

printf '\n== a failure after the default changed restores the previous setting ==\n'
scenario breaks-ordinary
fault "fail_on:SELECT COUNT(*) AS N FROM PREPROC_RT.MY_PIPELINE"
ensure --package "$PKG"
check "fresh connections failing after activation: exit 1" "1" "$RC"
check "...the previous (empty) setting is back" "" "$(st system_slot)"
has "...restored with ALTER SYSTEM ... NULL" "ALTER SYSTEM SET sql_preprocessor_script = NULL" "$(calls)"
check "...recorded installed and not validated" "installed false" "$(rec state) $(rec validated)"
has "...and the reason says the restore worked" "previous setting was restored and ordinary SQL works" "$OUT"

scenario active-breaks
ensure --package "$PKG"
reset_calls
fault "fail_on:SELECT COUNT(*) AS N FROM PREPROC_RT.MY_PIPELINE"
ensure
check "an active framework that stops verifying is deactivated" "1" "$RC"
check "...slot restored" "" "$(st system_slot)"

printf '\n== an active framework with objects missing is never overwritten ==\n'
scenario objects-missing
ensure --package "$PKG"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["scripts"]=[s for s in d["scripts"] if s!="PREPROC.STATUS"]; d["calls"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
ensure --package "$PKG"
check "a missing script: exit 1" "1" "$RC"
has "...named" "PREPROC.STATUS" "$OUT"
lacks "...and release.sql is not replayed" "CREATE ROLE" "$(calls)"

printf '\n== only the role is missing: put back as the package makes it, then adopted ==\n'
# An uninstall over a database of the user's hands PREPROC and PREPROC_RT to SYS
# and drops the role; the framework and the slot stay (marketplace/kit_logins.py).
# The next install then refused the framework, "objects are missing (PREPROC_ADMIN)".
# uninstalled <scenario> - the database and the record after that uninstall and a
# new install on the same database: no framework record, a user's own rule.
uninstalled() {
    scenario "$1"
    ensure --package "$PKG"
    python3 - "$D/state.json" "$D/fresh.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
json.dump({k: doc.get(k) for k in ("role", "owners", "grants")}, open(sys.argv[2], "w"), sort_keys=True)
doc["rules"].append({"id": 7, "script": "PREPROC_RT.SOMEONES_MODULE_V1", "enabled": False})
doc.update(role=False, owners={"PREPROC": "SYS", "PREPROC_RT": "SYS"}, calls=[],
           grants=[g for g in doc.get("grants", []) if not g.endswith(" TO PREPROC_ADMIN")])
json.dump(doc, open(sys.argv[1], "w"))
EOF
    printf '{"runtime": {"deployment_id": "exa-mine", "ownership": "user"}, "components": {}, "steps_completed": []}\n' > "$D/manifest.json"
}
# the role, the owners and the grants, against what the fresh install left.
same_as_fresh() { python3 - "$D/state.json" "$D/fresh.json" <<'EOF'
import json, sys
doc, fresh = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
print("same" if all(sorted(doc[k]) == sorted(fresh[k]) if isinstance(doc[k], list) else doc[k] == fresh[k]
                    for k in ("role", "owners", "grants")) else "differs")
EOF
}
# what the uninstall would do with the record as it is now.
plan_roles() { python3 - "$ROOT" "$D" <<'EOF'
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "marketplace"))
from pathlib import Path
import kit_logins
doc = json.load(open(os.path.join(sys.argv[2], "manifest.json")))
plan = kit_logins.build_plan(doc, Path(sys.argv[2]), "starter-kit-local")
print(" ".join(plan.roles), " ".join(plan.owned.get("PREPROC_ADMIN", [])))
EOF
}
uninstalled role-only
_rules="$(st rules)"
_scripts="$(st scripts)"
ensure
check "only the role is missing: put back and adopted, without the package" "0 active true" "$RC $(rec state) $(rec validated)"
check "...the role, the schemas' owner and the grants are a fresh install's" "same" "$(same_as_fresh)"
check "...the statements are the package's own, in its order" \
    "$(grep -E '^(CREATE ROLE|ALTER SCHEMA|GRANT) ' "$PKG" | tr -d ';')" \
    "$(calls | grep -E '^(CREATE ROLE|ALTER SCHEMA|GRANT) ')"
check "...in a session that bypasses any preprocessor" "ALTER SESSION SET sql_preprocessor_script = ''" \
    "$(python3 -c 'import json,sys; print(next(c[0] for c in json.load(open(sys.argv[1]))["calls"] if "CREATE ROLE PREPROC_ADMIN" in c))' "$D/state.json")"
check "...no rule is touched" "$_rules" "$(st rules)"
check "...no script either" "$_scripts" "$(st scripts)"
lacks "...and the rest of release.sql is not replayed" "CREATE SCHEMA" "$(calls)"
lacks "...nor the slot" "ALTER SYSTEM" "$(calls)"
check "...recorded: the framework was there, the role is the kit's, in this database" "pre-existing true exa-mine null" \
    "$(rec origin) $(rec role_created) $(rec made_in) $(rec role_restoring)"
check "a second uninstall drops the role again, its schemas first" "PREPROC_ADMIN PREPROC PREPROC_RT" "$(plan_roles)"
reset_calls
ensure
check "the next pass verifies" "0" "$RC"
lacks "...and puts nothing back" "CHANGE OWNER" "$(calls)"
lacks "...nor creates the role" "CREATE ROLE" "$(calls)"
check "...and the uninstall still drops the role" "PREPROC_ADMIN PREPROC PREPROC_RT" "$(plan_roles)"

uninstalled role-twice
for _round in 1 2; do
    ensure
    check "uninstalled and installed again ($_round): the role is back" "0 same" "$RC $(same_as_fresh)"
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["role"]=False; d["owners"]={"PREPROC": "SYS", "PREPROC_RT": "SYS"}; json.dump(d,open(p,"w"))' "$D/state.json"
    printf '{"runtime": {"deployment_id": "exa-mine", "ownership": "user"}, "components": {}, "steps_completed": []}\n' > "$D/manifest.json"
done

for _fault in "ALTER SCHEMA PREPROC_RT CHANGE OWNER" "GRANT CREATE SCRIPT"; do
    uninstalled "role-dies-$(printf '%s' "$_fault" | tr -d ' ')"
    fault "fail_on:$_fault"
    ensure
    check "a run that dies at $_fault: exit 1" "1" "$RC"
    has "...said" "the framework's role PREPROC_ADMIN could not be put back: injected failure on $_fault" "$OUT"
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; d["calls"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
    ensure
    check "...the next run finishes it" "0 same null" "$RC $(same_as_fresh) $(rec role_restoring)"
    lacks "...without creating the role twice" "CREATE ROLE" "$(calls)"
    check "...and the uninstall drops it" "PREPROC_ADMIN PREPROC PREPROC_RT" "$(plan_roles)"
done

# refused <name> - the old refusal, and nothing changed in the database.
refused() {
    ensure --package "$PKG"
    check "$1: still refused" "1" "$RC"
    has "...with the same message" "framework objects are missing (" "$OUT"
    lacks "...no role created" "CREATE ROLE" "$(calls)"
    lacks "...no owner changed" "CHANGE OWNER" "$(calls)"
    lacks "...no grant" "GRANT " "$(calls)"
    check "...and no record that the kit made one" "null" "$(rec role_created)"
}
uninstalled role-and-script
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["scripts"]=[s for s in d["scripts"] if s!="PREPROC.STATUS"]; json.dump(d,open(p,"w"))' "$D/state.json"
refused "the role and a script missing"
uninstalled role-and-schema
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["schemas"]=["PREPROC_RT"]; json.dump(d,open(p,"w"))' "$D/state.json"
refused "the role and a schema missing"
# A schema that went to somebody else is theirs: the uninstall gives them to SYS only.
uninstalled role-foreign-owner
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["owners"]["PREPROC"]="TEAM_ADMIN"; json.dump(d,open(p,"w"))' "$D/state.json"
refused "the role missing and a schema owned by a role of the user's"
uninstalled role-inactive
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["system_slot"]=""; json.dump(d,open(p,"w"))' "$D/state.json"
ensure --package "$PKG"
check "the role missing and the slot empty: a conflict, as before" "3" "$RC"
lacks "...nothing created" "CREATE ROLE" "$(calls)"

printf '\n== a cleared slot is reactivated; a newer pin is reported, not forced ==\n'
scenario cleared
ensure --package "$PKG"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["system_slot"]=""; json.dump(d,open(p,"w"))' "$D/state.json"
ensure
check "an installed framework whose slot was cleared is activated again" "0 PREPROC_RT.MASTER" "$RC $(st system_slot)"
has "...and the screen says why" "no longer active - activating it again" "$OUT"

scenario upgrade
ensure --package "$PKG"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["components"]["preprocessor"]["version"]="0.9.0"; json.dump(d,open(p,"w"))' "$D/manifest.json"
reset_calls
ensure --package "$PKG"
check "an older installed framework still verifies" "0" "$RC"
has "...with the pending upgrade named" "WARN Framework 0.9.0 is installed and this kit pins 0.9.1" "$OUT"
lacks "...and nothing is reinstalled" "CREATE ROLE" "$(calls)"

scenario down
fault "down"
ensure --package "$PKG"
check "a database that does not answer: exit 1" "1" "$RC"
has "...said plainly" "the database could not be inspected" "$OUT"

printf '\n== inspect is read-only ==\n'
scenario inspect-only '{"system_slot": "X.Y"}'
_insp="$(FAKE_EXAPUMP_STATE="$D/state.json" python3 "$PY" inspect --exapump "$WORK/bin/exapump" --profile p --manifest "$D/manifest.json")"
has "inspect reports the slot" '"slot": "X.Y"' "$_insp"
lacks "...and writes nothing" "ALTER SYSTEM" "$(calls)"
has "...reading behind the session bypass" "ALTER SESSION SET sql_preprocessor_script = ''" "$(calls)"

printf '\n== a framework that breaks every statement is rolled back (PRE-03) ==\n'
# inspect() read through the slot, so a MASTER that failed every statement
# stopped ensure at its first SELECT and left the database refusing SQL.
scenario master-broken
ensure --package "$PKG"
reset_calls
fault "master_broken"
ensure
check "a broken dispatcher: exit 1" "1" "$RC"
check "...the slot is put back to what it was" "" "$(st system_slot)"
has "...and the reason says ordinary SQL works again" "previous setting was restored and ordinary SQL works" "$OUT"
check "...and every session the kit opened read behind the bypass first" "" \
    "$(python3 -c 'import json,sys
calls=json.load(open(sys.argv[1]))["calls"]
reads=[c for c in calls if any("EXA_PARAMETERS" in s or "PREPROC.STATUS" in s for s in c) and len(c) > 1]
print("".join(c[0] for c in reads if c[0] != "ALTER SESSION SET sql_preprocessor_script = '"''"'"))' "$D/state.json")"

printf '\n== add-on modules: register, retire, idempotent, and the framework arriving after the add-on ==\n'
# Two test modules: a pinned one (its artifact in the folder, SHA-256 in
# module.toml) and a generated one (built by its add-on per database, its
# object names carrying {VERSION}).
MODS="$WORK/modules"
mkdir -p "$MODS/demo-addon" "$MODS/gen-addon"
printf -- '--/\nCREATE OR REPLACE LUA SCRIPT PREPROC_RT.DEMO_MOD_V1() AS\nfunction demo_mod(sqltext)\n    return nil\nend\n/\n' \
    > "$MODS/demo-addon/demo_mod_v1.sql"
_dsha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$MODS/demo-addon/demo_mod_v1.sql")"
cat > "$MODS/demo-addon/module.toml" <<TOML
name = "demo_mod"
description = "a test module"
phase = "EXPAND"
script_name = "PREPROC_RT.DEMO_MOD_V1"
function = "demo_mod"
version = 1
min_framework = "0.9.1"
deploy_mode = "library-deployed"
sha256 = "$_dsha"
[suggested_scope]
type = "ROLE"
value = "PUBLIC"
[kit]
addon = "demo-addon"
label = "Demo"
receipt = "components.demo_addon"
artifact = "demo_mod_v1.sql"
TOML
cat > "$WORK/gen.py" <<'PYG'
import shutil, sys
shutil.copyfile(sys.argv[1], sys.argv[2])
print("generated from the test fixture")
PYG
cat > "$MODS/gen-addon/module.toml" <<TOML
name = "gen_mod"
description = "a generated test module"
phase = "TRANSLATE"
script_name = "PREPROC_RT.GEN_MOD_V{VERSION}"
function = "gen_mod"
min_framework = "0.9.1"
deploy_mode = "kit-generated"
[suggested_scope]
type = "ROLE"
value = "PUBLIC"
[source]
repo = "example/gen"
ref = "v1.0.0"
[kit]
addon = "gen-addon"
label = "Gen"
receipt = "components.gen_addon"
generated = true
generator = ["{python}", "$WORK/gen.py", "$WORK/gen-current.sql", "{out}"]
TOML
gen_artifact() {
    printf -- '--/\nCREATE OR REPLACE LUA SCRIPT PREPROC_RT.GEN_MOD_V{VERSION}() AS\nfunction gen_mod(sqltext)\n    return sqltext -- %s\nend\n/\n' "$1" > "$WORK/gen-current.sql"
}
gen_artifact one
# module <register-module|retire-module> <addon> [args...]
module() {
    FAKE_EXAPUMP_STATE="$D/state.json" python3 "$PY" "$1" --exapump "$WORK/bin/exapump" --profile starter-kit \
        --manifest "$D/manifest.json" --modules-dir "$MODS" --log "$D/log" "${@:2}" > "$D/out" 2>&1
    RC=$?
    OUT="$(cat "$D/out")"
}
installed() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.setdefault("components",{})[sys.argv[2]]={"ownership":"kit","version":"1.0.0"}; json.dump(d,open(p,"w"))' "$D/manifest.json" "$1"; }
modrec() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("components",{}).get("preprocessor",{}).get("modules",{}).get(sys.argv[2],{}).get(sys.argv[3])
print(json.dumps(v) if not isinstance(v,str) else v)' "$D/manifest.json" "$1" "$2"; }
rules_for() { python3 -c 'import json,sys; print(" ".join("%s:%s:%s:%s" % (r.get("scope_type"), r.get("scope_value"), r.get("phase"), r["script"]) for r in json.load(open(sys.argv[1]))["rules"] if r["script"].startswith(sys.argv[2])))' "$D/state.json" "$1"; }
prov() { python3 -c 'import json,sys; print(" ".join("%s:%s" % (m["version"], m["status"]) for m in json.load(open(sys.argv[1]))["modules"] if m["name"]==sys.argv[2]))' "$D/state.json" "$1"; }
has_script() { python3 -c 'import json,sys; print(str(sys.argv[2] in json.load(open(sys.argv[1]))["scripts"]).lower())' "$D/state.json" "$1"; }
first_not_bypass() { python3 -c 'import json,sys
print(sum(1 for c in json.load(open(sys.argv[1]))["calls"] if c and c[0] != "ALTER SESSION SET sql_preprocessor_script = '"''"'"))' "$D/state.json"; }
refreshes() { st refreshes; }

scenario mod-no-framework
installed demo_addon
module register-module demo-addon
check "no framework in the database yet: skipped, exit 5" "5" "$RC"
has "...said as information, with when it will happen" "INFO the kit's SQL preprocessor framework is not set up in this database yet; Demo registers with it when the framework is installed" "$OUT"
lacks "...nothing was created" "CREATE" "$(calls)"

scenario mod-declined '{"system_slot": "MYSCHEMA.MY_PREPROCESSOR"}'
ensure --package "$PKG" --modules-dir "$MODS"
installed demo_addon
module register-module demo-addon
check "the user's own preprocessor holds the slot: skipped, exit 5" "5" "$RC"
has "...naming it" "slot holds MYSCHEMA.MY_PREPROCESSOR" "$OUT"
check "...and the slot is untouched" "MYSCHEMA.MY_PREPROCESSOR" "$(st system_slot)"
lacks "...nothing was registered" "MODULE_REGISTER" "$(calls)"

scenario mod-lifecycle
ensure --package "$PKG" --modules-dir "$MODS"
reset_calls
_r0="$(refreshes)"
module register-module demo-addon
check "an add-on the kit has not installed: skipped, exit 5" "5" "$RC"
installed demo_addon
module register-module demo-addon
check "an installed add-on registers: exit 0" "0" "$RC"
has "...said with its script and scope" "OK Demo registered with the SQL preprocessor framework: PREPROC_RT.DEMO_MOD_V1 for role PUBLIC" "$OUT"
check "...its script exists" "true" "$(has_script PREPROC_RT.DEMO_MOD_V1)"
check "...its rule reaches every user (ROLE PUBLIC, its phase)" "ROLE:PUBLIC:EXPAND:PREPROC_RT.DEMO_MOD_V1" "$(rules_for PREPROC_RT.DEMO_MOD)"
check "...its provenance is recorded" "1:deployed" "$(prov demo_mod)"
check "...the rule resolution was refreshed" "$((_r0 + 1))" "$(refreshes)"
check "...every session the kit opened started with the bypass" "0" "$(first_not_bypass)"
check "...and the kit's manifest records it" "1 PREPROC_RT.DEMO_MOD_V1" "$(modrec demo-addon version) $(modrec demo-addon script)"
reset_calls
module register-module demo-addon
check "registering again: exit 0" "0" "$RC"
lacks "...creates nothing" "CREATE" "$(calls)"
lacks "...ensures no rule" "RULE_ENSURE" "$(calls)"
check "...and refreshes nothing" "$((_r0 + 1))" "$(refreshes)"
check "...one rule still" "ROLE:PUBLIC:EXPAND:PREPROC_RT.DEMO_MOD_V1" "$(rules_for PREPROC_RT.DEMO_MOD)"
reset_calls
ensure --modules-dir "$MODS"
check "the framework's verify pass with the module in place: exit 0" "0" "$RC"
lacks "...and it says nothing about it" "Demo" "$OUT"
lacks "...or changes anything" "MODULE_REGISTER" "$(calls)"
reset_calls
module retire-module demo-addon
check "retiring: exit 0" "0" "$RC"
has "...said" "OK Demo retired from the SQL preprocessor framework" "$OUT"
check "...its rule is gone" "" "$(rules_for PREPROC_RT.DEMO_MOD)"
has "...the rules were refreshed after the rule went" "EXECUTE SCRIPT PREPROC.REFRESH" "$(calls)"
check "...its provenance retired, then reclaimed with its script" "false" "$(has_script PREPROC_RT.DEMO_MOD_V1)"
check "...nothing left in provenance" "" "$(prov demo_mod)"
check "...and the kit's record is gone" "null" "$(modrec demo-addon version)"
check "...every session started with the bypass" "0" "$(first_not_bypass)"
reset_calls
module retire-module demo-addon
check "retiring again: exit 0, nothing to do" "0" "$RC"
lacks "...and no rule is touched" "RULE_DROP" "$(calls)"

printf '\n-- the framework arrives after the add-on (0.2.5 -> 0.3.0) --\n'
scenario mod-update-path
installed demo_addon
ensure --package "$PKG" --modules-dir "$MODS"
check "the framework's fresh install: exit 0" "0" "$RC"
has "...and it registers the add-on that was already installed" "OK Demo registered with the SQL preprocessor framework" "$OUT"
check "...its rule is in place" "ROLE:PUBLIC:EXPAND:PREPROC_RT.DEMO_MOD_V1" "$(rules_for PREPROC_RT.DEMO_MOD)"
check "...after the framework was activated" "PREPROC_RT.MASTER" "$(st system_slot)"
reset_calls
ensure --modules-dir "$MODS"
lacks "the next pass is silent about it" "Demo" "$OUT"
check "...one read, no write" "0" "$(calls | grep -c -E 'RULE_ENSURE|MODULE_REGISTER|CREATE')"

scenario mod-register-fails
installed demo_addon
fault "fail_on:EXECUTE SCRIPT PREPROC.MODULE_REGISTER"
ensure --package "$PKG" --modules-dir "$MODS"
check "a registration that fails never fails the framework: exit 0" "0" "$RC"
has "...it is a warning naming the add-on" "WARN Demo could not be registered with the SQL preprocessor framework" "$OUT"
check "...and the framework is active" "PREPROC_RT.MASTER" "$(st system_slot)"
module register-module demo-addon
check "the add-on's own call reports it: exit 1" "1" "$RC"
has "...as a FAIL line with the database's reason" "injected failure on EXECUTE SCRIPT PREPROC.MODULE_REGISTER" "$OUT"

scenario mod-tampered
ensure --package "$PKG" --modules-dir "$MODS"
installed demo_addon
cp -R "$MODS" "$WORK/modules-tampered"
printf -- '-- changed\n' >> "$WORK/modules-tampered/demo-addon/demo_mod_v1.sql"
reset_calls
FAKE_EXAPUMP_STATE="$D/state.json" python3 "$PY" register-module --exapump "$WORK/bin/exapump" --profile p \
    --manifest "$D/manifest.json" --modules-dir "$WORK/modules-tampered" demo-addon > "$D/out" 2>&1
check "a pinned artifact that does not match its SHA-256: exit 1" "1" "$?"
has "...said" "does not match the SHA-256 pinned in module.toml" "$(cat "$D/out")"
check "...and the database was never touched" "" "$(calls)"

printf '\n-- a generated module: a changed artifact is the next version, never a replaced one --\n'
scenario mod-generated
ensure --package "$PKG" --modules-dir "$MODS"
installed gen_addon
module register-module gen-addon
check "a generated module without its artifact: exit 1" "1" "$RC"
has "...said" "pass the artifact with --artifact" "$OUT"
module register-module gen-addon --artifact "$WORK/gen-current.sql" --note "exasol-json-tables v0.4.1 + 2 wrappers"
check "with it: registered as version 1" "0 1:deployed" "$RC $(prov gen_mod)"
check "...the {VERSION} token became 1" "true" "$(has_script PREPROC_RT.GEN_MOD_V1)"
check "...its phase and scope" "ROLE:PUBLIC:TRANSLATE:PREPROC_RT.GEN_MOD_V1" "$(rules_for PREPROC_RT.GEN_MOD)"
check "...its provenance says what it was generated from" "exasol-json-tables v0.4.1 + 2 wrappers" \
    "$(python3 -c 'import json,sys; print(next(m["library_version"] for m in json.load(open(sys.argv[1]))["modules"] if m["name"]=="gen_mod"))' "$D/state.json")"
reset_calls
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "the same artifact again: exit 0, nothing created" "0 0" "$RC $(calls | grep -c CREATE)"
gen_artifact two
reset_calls
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "a changed artifact: exit 0" "0" "$RC"
has "...deployed as version 2, version 1 retired" "PREPROC_RT.GEN_MOD_V2 for role PUBLIC (version 1 retired)" "$OUT"
lacks "...version 1 was never replaced in place" "CREATE OR REPLACE LUA SCRIPT PREPROC_RT.GEN_MOD_V1" "$(calls)"
check "...the rule points at version 2 only" "ROLE:PUBLIC:TRANSLATE:PREPROC_RT.GEN_MOD_V2" "$(rules_for PREPROC_RT.GEN_MOD)"
_order="$(calls | grep -n -E 'RULE_ENSURE|RULE_DROP|PREPROC.REFRESH|MODULE_RETIRE|MODULE_RECLAIM' | sed 's/(.*//' | cut -d: -f2 | awk '{print $3}' | tr '\n' ' ')"
check "...in the framework's order: new rule, old rule dropped, refresh, old version retired, reclaimed" \
    "PREPROC.RULE_ENSURE PREPROC.RULE_DROP PREPROC.REFRESH PREPROC.MODULE_RETIRE PREPROC.MODULE_RECLAIM " "$_order"
check "...and version 1 is reclaimed" "false 2:deployed" "$(has_script PREPROC_RT.GEN_MOD_V1) $(prov gen_mod)"

# A register that fails before MODULE_REGISTER leaves the new version's rule
# and scripts with no provenance row: two rules of one module would go live at
# the next REFRESH, and MODULE_RECLAIM can never drop scripts it has no row for.
scenario mod-half-made
ensure --package "$PKG" --modules-dir "$MODS"
installed gen_addon
gen_artifact one
module register-module gen-addon --artifact "$WORK/gen-current.sql"
gen_artifact two
fault "fail_on:EXECUTE SCRIPT PREPROC.MODULE_REGISTER"
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "a register that fails before MODULE_REGISTER: exit 1" "1" "$RC"
check "...the new version's rule is dropped again, version 1's stays" "ROLE:PUBLIC:TRANSLATE:PREPROC_RT.GEN_MOD_V1" "$(rules_for PREPROC_RT.GEN_MOD)"
check "...and so is its script" "false" "$(has_script PREPROC_RT.GEN_MOD_V2)"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "the retry deploys version 2 after all, version 1 retired and reclaimed" "0 2:deployed false" "$RC $(prov gen_mod) $(has_script PREPROC_RT.GEN_MOD_V1)"
gen_artifact three
fault "fail_on:EXECUTE SCRIPT PREPROC.MODULE_REGISTER"
fault "fail_on:DROP SCRIPT IF EXISTS PREPROC_RT.GEN_MOD_V3"
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "a cleanup that fails as well leaves version 3's script" "1 true" "$RC $(has_script PREPROC_RT.GEN_MOD_V3)"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "...the next register deploys version 4 and drops it" "0 4:deployed false" "$RC $(prov gen_mod) $(has_script PREPROC_RT.GEN_MOD_V3)"
gen_artifact four
fault "fail_on:EXECUTE SCRIPT PREPROC.MODULE_REGISTER"
fault "fail_on:DROP SCRIPT IF EXISTS PREPROC_RT.GEN_MOD_V5"
module register-module gen-addon --artifact "$WORK/gen-current.sql"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
module retire-module gen-addon
check "...and a retire right after one drops it too: no rule, no script, no provenance" "0   " \
    "$RC $(rules_for PREPROC_RT.GEN_MOD) $(prov gen_mod) $(python3 -c 'import json,sys; print(" ".join(s for s in json.load(open(sys.argv[1]))["scripts"] if s.startswith("PREPROC_RT.GEN_MOD")))' "$D/state.json")"
gen_artifact one

scenario mod-generated-update-path
installed gen_addon
gen_artifact one
ensure --package "$PKG" --modules-dir "$MODS"
check "the framework's pass runs a generated module's generator" "0 1:deployed" "$RC $(prov gen_mod)"
has "...and says it registered" "OK Gen registered with the SQL preprocessor framework" "$OUT"

# PPX-01. A batch that failed at its REFRESH left the rule on version 2, the
# sessions' resolution on version 1 and version 1 deployed. The retry used to
# find everything "in place" and say registered, with no refresh and no retire:
# every session kept running version 1 for good.
scenario mod-refresh-failed
ensure --package "$PKG" --modules-dir "$MODS"
installed gen_addon
gen_artifact one
module register-module gen-addon --artifact "$WORK/gen-current.sql"
gen_artifact two
fault "fail_on:EXECUTE SCRIPT PREPROC.REFRESH"
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "a register that fails at its refresh: exit 1" "1" "$RC"
check "...the rule already names version 2, and both versions are deployed" \
    "ROLE:PUBLIC:TRANSLATE:PREPROC_RT.GEN_MOD_V2 1:deployed 2:deployed" "$(rules_for PREPROC_RT.GEN_MOD) $(prov gen_mod)"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
_r1="$(refreshes)"
reset_calls
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "the retry: exit 0" "0" "$RC"
has "...it finishes the switch: version 1 retired" "OK Gen registered with the SQL preprocessor framework: PREPROC_RT.GEN_MOD_V2 for role PUBLIC (version 1 retired)" "$OUT"
check "...the rule resolution was refreshed" "$((_r1 + 1))" "$(refreshes)"
lacks "...nothing was created again" "CREATE" "$(calls)"
check "...version 1 retired and reclaimed" "false 2:deployed" "$(has_script PREPROC_RT.GEN_MOD_V1) $(prov gen_mod)"
reset_calls
module register-module gen-addon --artifact "$WORK/gen-current.sql"
check "...and the next register is the quiet one again: exit 0, no refresh" "0 0" "$RC $(calls | grep -c 'PREPROC.REFRESH')"

# The same for a first registration whose refresh failed: no old version, but
# no session resolves the rule either.
scenario mod-first-refresh-failed
ensure --package "$PKG" --modules-dir "$MODS"
installed demo_addon
fault "fail_on:EXECUTE SCRIPT PREPROC.REFRESH"
module register-module demo-addon
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
_r1="$(refreshes)"
module register-module demo-addon
check "a first registration whose refresh failed is refreshed on the retry" "0 $((_r1 + 1))" "$RC $(refreshes)"

# PPX-03. The framework resolves ROLE PUBLIC to the users that exist at a
# REFRESH; a database user created after it has no row, so no module reaches it.
# The verify pass (every installer run and exakit update) refreshes for it.
scenario mod-new-user
installed demo_addon
ensure --package "$PKG" --modules-dir "$MODS"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["users"]=["SYS","ANALYST"]; json.dump(d,open(p,"w"))' "$D/state.json"
_r1="$(refreshes)"
reset_calls
ensure --modules-dir "$MODS"
check "a database user created since the last refresh: the verify pass refreshes" "0 $((_r1 + 1))" "$RC $(refreshes)"
has "...said" "OK Rule resolution refreshed for users and roles changed since" "$OUT"
check "...and the new user now resolves the module" "true" \
    "$(python3 -c 'import json,sys; print(str(["ANALYST","PREPROC_RT.DEMO_MOD_V1"] in json.load(open(sys.argv[1]))["resolution"]).lower())' "$D/state.json")"
ensure --modules-dir "$MODS"
check "...the next pass has nothing to refresh" "$((_r1 + 1))" "$(refreshes)"
scenario mod-new-user-no-public
ensure --package "$PKG" --modules-dir "$MODS"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["users"]=["SYS","ANALYST"]; json.dump(d,open(p,"w"))' "$D/state.json"
_r1="$(refreshes)"
ensure --modules-dir "$MODS"
check "with no rule for every user, a user without rules is not stale" "$_r1" "$(refreshes)"

printf '\n-- JSON Tables: its module is built from the wrappers in the database (setup/preprocessor/modules/json-tables) --\n'
# The real module folder and generator, with a stand-in for upstream
# exasol_json_tables (tests/lib/stub-json-tables, upstream's own catalog SQL) and
# a wrapper package recorded from a live ingest-and-wrap
# (tests/lib/json-tables-jvs-fixture.json) in the simulated database.
JT_STUB="$ROOT/tests/lib/stub-json-tables"
JT_GEN="$ROOT/setup/preprocessor/modules/json-tables/generate.py"
jvs() {   # jvs <helper schemas...>: the fixture's package, once per name (the first keeps its own name)
    python3 - "$D/state.json" "$ROOT/tests/lib/json-tables-jvs-fixture.json" "$@" <<'PYJ'
import json, sys
path, fixture, names = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3:]
(helper, package), = fixture.items()
doc = json.load(open(path))
doc["jvs"] = {}
for name in names:
    text = json.dumps(package).replace(helper.rsplit("_VIEW_INTERNAL", 1)[0], name)
    doc["jvs"][name + "_VIEW_INTERNAL"] = json.loads(text)
    doc.setdefault("schemas", []).extend(s for s in (name + "_VIEW", name + "_VIEW_INTERNAL") if s not in doc["schemas"])
json.dump(doc, open(path, "w"))
PYJ
}
jt_register() {
    FAKE_EXAPUMP_STATE="$D/state.json" PYTHONPATH="$JT_STUB" python3 "$JT_GEN" --register --home "$D" \
        --exapump "$WORK/bin/exapump" --profile starter-kit > "$D/out" 2>&1
    RC=$?
    OUT="$(cat "$D/out")"
}
jt_scripts() { python3 -c 'import json,sys; print(" ".join(sorted(s for s in json.load(open(sys.argv[1]))["scripts"] if s.startswith("PREPROC_RT.JSON_TABLES"))))' "$D/state.json"; }
jt_created() { calls | grep -c '^CREATE OR REPLACE LUA SCRIPT PREPROC_RT.JSON_TABLES_V'; }

scenario jt-update-path
installed json_tables
jvs SAMPLE_ORDERS
PYTHONPATH="$JT_STUB" ensure --package "$PKG"
check "a wrapper made before the framework came (0.2.5 -> 0.3.0): the framework's pass registers JSON Tables" "0" "$RC"
has "...said with its script and scope" "OK JSON Tables registered with the SQL preprocessor framework: PREPROC_RT.JSON_TABLES_V1 for role PUBLIC" "$OUT"
check "...a TRANSLATE rule for every user" "ROLE:PUBLIC:TRANSLATE:PREPROC_RT.JSON_TABLES_V1" "$(rules_for PREPROC_RT.JSON_TABLES)"
check "...its entry, its rewriter and its refusal, all version 1" \
    "PREPROC_RT.JSON_TABLES_LIB_V1 PREPROC_RT.JSON_TABLES_REFUSE_V1 PREPROC_RT.JSON_TABLES_V1" "$(jt_scripts)"
check "...its provenance names the release and the wrappers it was built from" "exasol-json-tables v0.4.1 + 1 wrapper" \
    "$(python3 -c 'import json,sys; print(next(m["library_version"] for m in json.load(open(sys.argv[1]))["modules"] if m["name"]=="json_tables"))' "$D/state.json")"
has "...the entry knows the wrapper schema" "local SCHEMAS = {'SAMPLE_ORDERS_VIEW'}" "$(calls)"
has "...and the rewriter carries its configuration inline" "['helper_schema_by_allowed_schema'] = {['SAMPLE_ORDERS_VIEW'] = 'SAMPLE_ORDERS_VIEW_INTERNAL'}" "$(calls)"
reset_calls
PYTHONPATH="$JT_STUB" ensure
check "the next pass, nothing changed: exit 0" "0" "$RC"
lacks "...it says nothing about JSON Tables" "JSON Tables" "$OUT"
lacks "...and writes nothing" "MODULE_REGISTER" "$(calls)"

scenario jt-new-wrapper
installed json_tables
jvs SAMPLE_ORDERS
PYTHONPATH="$JT_STUB" ensure --package "$PKG"
jvs SAMPLE_ORDERS SECOND_EVENTS
reset_calls
jt_register
check "a new wrapper (the launcher after a wrap): exit 0" "0" "$RC"
check "...first it says it is registering, before the sessions it opens" "JSON Tables: registering the new wrapper ..." "$(head -n 1 "$D/out")"
check "...every session it opened, the wrapper reads too, started with the bypass" "0" "$(first_not_bypass)"
has "...one line says JSON queries work on every connection" "JSON Tables: JSON queries work on every connection, no session setup (PREPROC_RT.JSON_TABLES_V2, exasol-json-tables v0.4.1 + 2 wrappers)" "$OUT"
_two="local SCHEMAS = {'SAMPLE_ORDERS_VIEW', 'SECOND_EVENTS_VIEW'}"   # a variable: bash 3.2 brace-expands it inside "$(...)"
check "...version 2 serves both wrapper schemas" "1" "$(calls | grep -cF "$_two")"
lacks "...version 1 was never replaced in place" "CREATE OR REPLACE LUA SCRIPT PREPROC_RT.JSON_TABLES_V1" "$(calls)"
check "...the rule points at version 2 only" "ROLE:PUBLIC:TRANSLATE:PREPROC_RT.JSON_TABLES_V2" "$(rules_for PREPROC_RT.JSON_TABLES)"
check "...and version 1 is retired and reclaimed, all three scripts" \
    "PREPROC_RT.JSON_TABLES_LIB_V2 PREPROC_RT.JSON_TABLES_REFUSE_V2 PREPROC_RT.JSON_TABLES_V2 2:deployed" "$(jt_scripts) $(prov json_tables)"
check "...the kit's manifest records version 2" "2 PREPROC_RT.JSON_TABLES_V2" "$(modrec json-tables version) $(modrec json-tables script)"
reset_calls
jt_register
check "the same wrappers again: exit 0, nothing created" "0 0" "$RC $(jt_created)"
jvs
reset_calls
jt_register
check "every wrapper gone: exit 0, a module that passes everything through" "0 PREPROC_RT.JSON_TABLES_V3" "$RC $(modrec json-tables script)"
has "...it names no schema" "local SCHEMAS = {}" "$(calls)"
has "...and carries no rewriter" "function rewrite_statement(sqltext)
    return sqltext
end" "$(calls)"
reset_calls
FAKE_EXAPUMP_STATE="$D/state.json" python3 "$PY" retire-module --exapump "$WORK/bin/exapump" --profile starter-kit \
    --manifest "$D/manifest.json" --log "$D/log" json-tables > "$D/out" 2>&1
check "uninstall retires it: exit 0, no rule, no script left" "0  " "$? $(rules_for PREPROC_RT.JSON_TABLES) $(jt_scripts)"

# PPX-09: a wrapper schema dropped by hand keeps its helper schema, and upstream
# finds wrappers by their helpers. The next rebuild configures only a wrapper
# whose schema is still there, so a later schema of that name is plain SQL.
scenario jt-dropped-wrapper
installed json_tables
jvs SAMPLE_ORDERS SECOND_EVENTS
PYTHONPATH="$JT_STUB" ensure --package "$PKG"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["schemas"].remove("SECOND_EVENTS_VIEW"); json.dump(d,open(p,"w"))' "$D/state.json"
reset_calls
PYTHONPATH="$JT_STUB" ensure
check "a wrapper schema dropped by hand: the framework's verify rebuilds the module without it" "0 PREPROC_RT.JSON_TABLES_V2" "$RC $(modrec json-tables script)"
has "...it names only the wrapper still there" "local SCHEMAS = {'SAMPLE_ORDERS_VIEW'}" "$(calls)"
lacks "...and configures nothing for the dropped one" "SECOND_EVENTS_VIEW" "$(calls | grep -v '__JVS_')"

scenario jt-failures
installed json_tables
jvs SAMPLE_ORDERS
fault "fail_on:__JVS_ROOTS"
PYTHONPATH="$JT_STUB" ensure --package "$PKG"
check "the wrappers cannot be read: the framework still installs, exit 0" "0 PREPROC_RT.MASTER" "$RC $(st system_slot)"
check "...and no JSON Tables module is half made" "" "$(jt_scripts)"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
set_rec '{"state": "absent"}'
jt_register
check "the launcher with the framework not set up: skipped (exit 5), said" "5" "$RC"
has "...in one line" "JSON Tables: the kit's SQL preprocessor framework is not set up in this database yet" "$OUT"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["components"]["json_tables"]={}; json.dump(d,open(p,"w"))' "$D/manifest.json"
FAKE_EXAPUMP_STATE="$D/state.json" python3 "$JT_GEN" --register --home "$D" --exapump "$WORK/bin/exapump" > "$D/out" 2>&1
check "the kit has no JSON Tables here and the interpreter has no upstream: exit 1, said" "1" "$?"
has "...plainly" "JSON Tables is not installed by the kit here" "$(cat "$D/out")"

# PPX-02 for a module of several scripts: every one of the new version's goes.
scenario jt-half-made
installed json_tables
jvs SAMPLE_ORDERS
PYTHONPATH="$JT_STUB" ensure --package "$PKG"
jvs SAMPLE_ORDERS SECOND_EVENTS
fault "fail_on:EXECUTE SCRIPT PREPROC.MODULE_REGISTER"
jt_register
check "a new wrapper whose register fails: exit 1, version 1 untouched, nothing of version 2 left" \
    "1 PREPROC_RT.JSON_TABLES_LIB_V1 PREPROC_RT.JSON_TABLES_REFUSE_V1 PREPROC_RT.JSON_TABLES_V1 ROLE:PUBLIC:TRANSLATE:PREPROC_RT.JSON_TABLES_V1" \
    "$RC $(jt_scripts) $(rules_for PREPROC_RT.JSON_TABLES)"

# A Windows artifact: generate.py writes text mode there, so every line ends in
# CRLF. exapump ends a script body only at "/" followed by a bare LF, so the
# block after the first one ran on to the end of the input: the REFUSE script
# was created with the library, the entry and every EXECUTE SCRIPT inside its
# body, exapump exited 0, and the kit printed "registered" with no
# PREPROC.MODULES row and no JSON_TABLES_V1 (Windows 11 upgrade re-run).
scenario jt-crlf
installed json_tables
jvs SAMPLE_ORDERS
ensure --package "$PKG" --modules-dir "$MODS"
FAKE_EXAPUMP_STATE="$D/state.json" PYTHONPATH="$JT_STUB" python3 "$JT_GEN" --home "$D" \
    --exapump "$WORK/bin/exapump" --profile starter-kit "$WORK/jt-lf.sql" > /dev/null 2>&1
python3 -c 'import sys; t=open(sys.argv[1],newline="").read(); open(sys.argv[2],"w",newline="").write(t.replace("\r\n","\n").replace("\n","\r\n"))' \
    "$WORK/jt-lf.sql" "$WORK/jt-crlf.sql"
reset_calls
FAKE_EXAPUMP_STATE="$D/state.json" python3 "$PY" register-module --exapump "$WORK/bin/exapump" --profile starter-kit \
    --manifest "$D/manifest.json" --log "$D/log" json-tables --artifact "$WORK/jt-crlf.sql" --note "crlf" > "$D/out" 2>&1
RC=$?; OUT="$(cat "$D/out")"
check "a CRLF artifact (Windows) registers: exit 0" "0" "$RC"
check "...all three scripts exist" \
    "PREPROC_RT.JSON_TABLES_LIB_V1 PREPROC_RT.JSON_TABLES_REFUSE_V1 PREPROC_RT.JSON_TABLES_V1" "$(jt_scripts)"
check "...its provenance row is deployed" "1:deployed" "$(prov json_tables)"
check "...its rule reaches every user" "ROLE:PUBLIC:TRANSLATE:PREPROC_RT.JSON_TABLES_V1" "$(rules_for PREPROC_RT.JSON_TABLES)"

# "Registered" is what the database shows afterwards, not what exapump's exit
# code says: a deploy that answered OK but left no PREPROC.MODULES row is a
# failure, said, and the kit's manifest does not record the module. The next
# pass (the launcher, the framework's verify) reads the database, not the
# manifest, so it deploys it again.
scenario jt-unverified
installed json_tables
jvs SAMPLE_ORDERS
ensure --package "$PKG" --modules-dir "$MODS"
set_rec "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["components"]["preprocessor"]; r["modules"]={"json-tables":{"name":"json_tables","version":1,"sha256":"9157fd61","script":"PREPROC_RT.JSON_TABLES_V1","registered_at":"2026-11-18T17:50:29Z"}}; print(json.dumps(r))' "$D/manifest.json")"
fault "noop_on:EXECUTE SCRIPT PREPROC.MODULE_REGISTER"
reset_calls
jt_register
check "a deploy the database did not take: exit 1" "1" "$RC"
has "...said, naming what is missing" "JSON Tables: JSON Tables could not be registered with the SQL preprocessor framework: the database shows no deployed json_tables version 1" "$OUT"
lacks "...and never claims JSON queries work" "JSON queries work on every connection" "$OUT"
check "...the stale manifest record is dropped" "null" "$(modrec json-tables version)"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
reset_calls
PYTHONPATH="$JT_STUB" ensure
# Version 1 again: the half-made version 1 (scripts and rule, no provenance
# row) was dropped when the read-back found it incomplete.
has "the framework's next pass deploys it again" "OK JSON Tables registered with the SQL preprocessor framework: PREPROC_RT.JSON_TABLES_V1 for role PUBLIC" "$OUT"
check "...with its provenance row" "1:deployed" "$(prov json_tables)"
check "...its rule on that version only" "ROLE:PUBLIC:TRANSLATE:PREPROC_RT.JSON_TABLES_V1" "$(rules_for PREPROC_RT.JSON_TABLES)"
check "...and the manifest records it again" "1 PREPROC_RT.JSON_TABLES_V1" "$(modrec json-tables version) $(modrec json-tables script)"

# SCR-05. The wrapper names come from the database (any schema's __JVS_ROOTS),
# so they reach the module's Lua as data only: never into a comment, every
# quote, backslash and line break escaped, and a package whose names hold a
# line break left out, since upstream quotes them into CONFIG unescaped.
scenario jt-hostile-names
installed json_tables
jvs SAMPLE_ORDERS SECOND_EVENTS
python3 - "$D/state.json" <<'PYH'
import json, sys
doc = json.load(open(sys.argv[1]))
for row in doc["jvs"]["SECOND_EVENTS_VIEW_INTERNAL"]["roots"]:
    row["PUBLIC_SCHEMA"] = "W\n]] INJECTED_TOP_LEVEL_LINE_MARKER()\n--"
json.dump(doc, open(sys.argv[1], "w"))
PYH
FAKE_EXAPUMP_STATE="$D/state.json" PYTHONPATH="$JT_STUB" python3 "$JT_GEN" --home "$D" \
    --exapump "$WORK/bin/exapump" --profile starter-kit "$WORK/jt-hostile.sql" > "$D/out" 2> "$D/err"
check "a wrapper whose name holds a line break: the module is still built, exit 0" "0" "$?"
check "...from the other wrapper only" "exasol-json-tables v0.4.1 + 1 wrapper" "$(cat "$D/out")"
has "...and the one left out is said" "was left out of the SQL preprocessor module: its names hold a line break" "$(cat "$D/err")"
check "...no line of the module starts with the planted text" "0" "$(grep -c '^]] INJECTED' "$WORK/jt-hostile.sql")"
lacks "...it is nowhere in the module" "INJECTED_TOP_LEVEL_LINE_MARKER" "$(cat "$WORK/jt-hostile.sql")"
lacks "...and no comment carries a database value" "Packages:" "$(cat "$WORK/jt-hostile.sql")"
_lua="$(cd "$ROOT/setup/preprocessor/modules/json-tables" && python3 -c 'import generate; print(generate._lua_string("A'"'"'B\\C\nD\rE\0F]]G\"H"))')"
check "a name is one Lua string: quote, backslash, line breaks, NUL and quote escaped, ]] inert" \
    "'A\\'B\\\\C\\nD\\rE\\0F]]G\\\"H'" "$_lua"

printf '\n== the installer step: the shell bridge ==\n'
# A sandboxed kit: its own home, manifest and versions document pinning the
# test package, the stand-in exapump, and a fetch that copies the package
# instead of downloading it.
B="$WORK/bridge"
mkdir -p "$B/home" "$B/kit"
python3 - "$ROOT/versions.json" "$B/kit/versions.json" "$SHA" "$CORE" <<'PYV'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["components"]["preprocessor"]["sha256"]["release-sql"] = sys.argv[3]
doc["components"]["preprocessor"]["sha256"]["core-only"] = sys.argv[4]
json.dump(doc, open(sys.argv[2], "w"), indent=2)
PYV
printf '{}\n' > "$B/state.json"
bridge() {
    ( EXAKIT_HOME="$B/home"
      EXAKIT_MANIFEST="$B/home/manifest.json"
      EXAKIT_BIN_DIR="$B/home/bin"
      EXAKIT_LOG_FILE="$B/home/setup.log"
      EXAKIT_EXAPUMP_BIN="$WORK/bin/exapump"
      EXAKIT_EXAPUMP_CONFIG_DIR="$B/home/.exapump"
      FAKE_EXAPUMP_STATE="$B/state.json"
      export FAKE_EXAPUMP_STATE
      . "$ROOT/setup/lib/common.sh"
      . "$ROOT/setup/lib/detect.sh"
      . "$ROOT/setup/lib/runtime-personal.sh"
      . "$ROOT/setup/lib/exapump.sh"
      . "$ROOT/setup/lib/core-setup.sh"
      _EXAKIT_VERSIONS_DOC="$B/kit/versions.json"
      _EXAKIT_VERSIONS_SOURCE="baked"
      [ -f "$EXAKIT_MANIFEST" ] || manifest_init >/dev/null 2>&1
      manifest_set kit.version 0.3.0 >/dev/null 2>&1
      fetch() { printf 'FETCH %s\n' "$1" >> "$B/fetches"; cp "$PKG" "$2"; }
      "$@" )
}
# The kit's copy of setup/core and setup/preprocessor is the checkout itself.
B_OUT="$(bridge exakit_core_database_step "Step 4/7  Configure database features" "$ROOT" 2>&1)"
has "the step announces itself" "Step 4/7  Configure database features" "$B_OUT"
has "the coordinator's OK lines are rendered" "SQL preprocessor framework 0.9.1 installed, tested and activated" "$B_OUT"
check "the package was fetched once, from the pinned release asset" \
    "FETCH https://github.com/exasol-labs/preprocessor-framework/releases/download/v0.9.1/release.sql" "$(cat "$B/fetches")"
check "...into the content-addressed cache" "yes" "$([ -f "$B/home/cache/preprocessor/$SHA/release.sql" ] && echo yes || echo no)"
check "the core task is recorded only now" '["preprocessor"]' "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["core_tasks"]["completed"]))' "$B/home/manifest.json")"
lacks "...and the step itself never joins steps_completed" "db_features" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("steps_completed"))' "$B/home/manifest.json")"

rm -f "$B/fetches"
B_OUT="$(bridge exakit_core_database_step "Step 4/7  Configure database features" "$ROOT" 2>&1)"
has "a second pass verifies" "verified and active" "$B_OUT"
check "...without fetching anything" "no" "$([ -f "$B/fetches" ] && echo yes || echo no)"

# PRE-02: the user's own preprocessor in the slot is declined, not failed. The
# task completes as declined, so nothing is booked in the closing summary and
# `exakit update` has nothing pending to rerun the installer for.
printf '{"system_slot": "OTHER.SCRIPT"}\n' > "$B/state.json"
rm -rf "$B/home"; mkdir -p "$B/home"
B_OUT="$(bridge eval 'exakit_core_database_step "Step 4/7  Configure database features" "'"$ROOT"'"; exakit_print_soft_failures; printf "COMPLETED=%s\n" "$(manifest_get core_tasks.completed 2>/dev/null)"; printf "PENDING=%s\n" "$(exakit_core_pending "'"$ROOT"'" | tr "\n" " ")"' 2>&1)"
has "a declined slot is said once, naming the holder" "OTHER.SCRIPT, a script the kit does not manage" "$B_OUT"
has "...with the installer's own command to opt in later" "then run curl -fsSL" "$B_OUT"
lacks "...it is not in the closing summary" "the SQL preprocessor framework is not installed" "$B_OUT"
lacks "...and no retry is handed out" "Retry with: exakit update" "$B_OUT"
has "...the task is recorded, as declined" 'COMPLETED=["preprocessor"]' "$B_OUT"
has "...so nothing is pending for exakit update" "PENDING=" "$B_OUT"
lacks "...not even the preprocessor" "PENDING=preprocessor" "$B_OUT"
check "...the record names the holder" "true OTHER.SCRIPT" "$(D="$B/home"; rec declined) $(D="$B/home"; rec slot_holder)"
check "...and the slot still holds the other script" "OTHER.SCRIPT" "$(D="$B"; st system_slot)"
# And `exakit update` itself: no installer rerun, no failure, exit 0.
B_OUT="$(bridge eval 'exakit_core_rerun_installer() { echo RERUN-CALLED; return 1; }; personal_deployment_running() { return 0; }; exakit_core_update_check all; printf "RC=%s ACTED=%s\n" "$?" "$EXAKIT_CORE_UPDATE_ACTED"' 2>&1)"
lacks "exakit update does not rerun the installer for a declined slot" "RERUN-CALLED" "$B_OUT"
has "...and its check passes" "RC=0 ACTED=0" "$B_OUT"
lacks "...without a failure line" "New setup did not complete" "$B_OUT"
# `exakit status --json` reports it: the state, the holder and the command that
# opts in once the slot is cleared - information, never a remedy (no runtime is
# recorded in this sandbox, so status asks no database).
_sj="$(EXAKIT_HOME="$B/home" EXAKIT_BIN_DIR="$B/home/bin" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
_sjf() { printf '%s' "$_sj" | python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v.get(k) if isinstance(v,dict) else None
print("null" if v is None else v)' "$1"; }
check "status --json: preprocessor.state is declined" "declined" "$(_sjf preprocessor.state)"
check "...naming the slot's holder" "OTHER.SCRIPT" "$(_sjf preprocessor.slot_holder)"
has "...with the installer's command to opt in" "curl -fsSL" "$(_sjf preprocessor.opt_in)"
has "...and the step before it" "ALTER SYSTEM SET sql_preprocessor_script = NULL" "$(_sjf preprocessor.opt_in_hint)"
check "...and it is no remedy" "null" "$(_sjf remedies.preprocessor)"
# The Windows twin answers the same object (Invoke-CmdStatus).
_ps_status="$(sed -n '/^function Invoke-CmdStatus/,/^}/p' "$ROOT/setup/exakit.ps1")"
has "exakit.ps1 status --json carries the same preprocessor object" 'preprocessor    = $ppStatus' "$_ps_status"
has "...declined from the record, with the installer as opt_in" '$ppStatus.opt_in = $installCmd' "$_ps_status"

printf '\n== the slot changes while the MCP server runs: it is restarted after, once (U5) ==\n'
# `exakit update` from 0.2.x sets up the MCP server before the installer rerun
# activates the framework, and a system setting reaches only new sessions: the
# server's pooled session answered Semantic SQL and JSON paths without the
# framework until the next database restart. The stand-in launcher records each
# call with the slot the simulated database holds at that moment.
mkdir -p "$B/sbin"
cat > "$B/sbin/exasol" <<EOF
#!/bin/sh
slot="\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("system_slot") or "-")' "$B/state.json")"
printf '%s slot=%s\n' "\$*" "\$slot" >> "$B/launcher"
case "\$1 \${2:-}" in "mcp status") cat "$B/sidecar-status" ;; esac
exit 0
EOF
printf '#!/bin/sh\necho changed\n' > "$B/sbin/uv"
chmod +x "$B/sbin/exasol" "$B/sbin/uv"
printf 'pw\n' > "$B/mcp-pw"
U5_SERVING='{"name": "mcp", "running": true, "health": "serving"}'
# u5_fresh - a database and a kit home with no framework yet.
u5_fresh() { printf '{}\n' > "$B/state.json"; rm -rf "${B:?}/home"; mkdir -p "$B/home"; }
# bridge_mcp <backend> - the step, with the MCP module loaded and the server recorded.
bridge_mcp() {
    : > "$B/launcher"
    bridge eval '. "$ROOT/setup/lib/mcp.sh"
        personal_cli() { printf "%s\n" "$B/sbin/exasol"; }
        personal_launcher_deployments() { return 1; }
        exakit_ensure_uv() { EXAKIT_UV_BIN="$B/sbin/uv"; }
        EXAKIT_MCP_SIDECAR_WAIT=0
        manifest_set components.mcp_server.backend "'"$1"'"
        manifest_set components.mcp_server.connection.user mcp_readonly
        manifest_set components.mcp_server.connection.password_file "$B/mcp-pw"
        exakit_core_database_step "Step 4/7  Configure database features" "$ROOT"' 2>&1
}
u5_fresh
printf '%s\n' "$U5_SERVING" > "$B/sidecar-status"
B_OUT="$(bridge_mcp sidecar)"
has "the framework is activated" "installed, tested and activated" "$B_OUT"
check "...then the running server is restarted: switched off and reconciled, the framework already in the slot" \
    "mcp status --json slot=PREPROC_RT.MASTER|sidecar disable mcp slot=PREPROC_RT.MASTER|start slot=PREPROC_RT.MASTER|mcp status --json slot=PREPROC_RT.MASTER" \
    "$(sed 's/ --deployment-dir [^ ]*//' "$B/launcher" | tr '\n' '|' | sed 's/|$//')"
check "...each call naming the kit's deployment folder" "0" "$(grep -vc -- '--deployment-dir ' "$B/launcher")"
has "...said in one line" "The MCP server was restarted to pick up the SQL Preprocessor" "$B_OUT"
# The install screen's "SQL Preprocessor" sub-line ends "MCP server restarted",
# found by matching the start of that line: the line mcp.sh says must match.
_restart_line="$(sed -n 's/^ *info "\(The MCP server was restarted[^"]*\)"$/\1/p' "$ROOT/setup/lib/mcp.sh")"
printf 'INFO %s\n' "$_restart_line" > "$WORK/held-restart"
has "...and the install sub-line still says MCP server restarted" "MCP server restarted" \
    "$( . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/core-setup.sh"
        EXAKIT_ITEM_LOG="$WORK/held-restart"; exakit_core_task_item_detail preprocessor )"
check "...once" "1" "$(grep -c 'sidecar disable' "$B/launcher")"
B_OUT="$(bridge_mcp sidecar)"
has "a pass that only verifies" "verified and active" "$B_OUT"
check "...leaves the server alone" "" "$(cat "$B/launcher")"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["system_slot"]=""; json.dump(d,open(p,"w"))' "$B/state.json"
B_OUT="$(bridge_mcp sidecar)"
has "a cleared slot is activated again" "activating it again" "$B_OUT"
check "...and the server restarted after it" "sidecar disable mcp slot=PREPROC_RT.MASTER" "$(grep 'sidecar disable' "$B/launcher" | sed 's/ --deployment-dir [^ ]*//')"
u5_fresh
printf '%s\n' '{"name": "mcp", "running": false, "health": "stopped"}' > "$B/sidecar-status"
B_OUT="$(bridge_mcp sidecar)"
check "a server that is not running is not restarted" "mcp status --json slot=PREPROC_RT.MASTER" "$(sed 's/ --deployment-dir [^ ]*//' "$B/launcher")"
u5_fresh
printf '%s\n' "$U5_SERVING" > "$B/sidecar-status"
B_OUT="$(bridge_mcp stdio)"
check "a fresh install (no sidecar recorded yet - Step 4 comes after): the launcher is not called" "" "$(cat "$B/launcher")"
has "...and the framework is activated all the same" "installed, tested and activated" "$B_OUT"

printf '\n== exakit update runs the framework verify pass every time (PPX-04) ==\n'
# Once the preprocessor core task is done, `exakit update` reran nothing: a
# module that failed to register at add-on install (or a database user created
# since) stayed without it, while every remedy said "run exakit update".
u5_fresh
bridge exakit_core_database_step "Step 4/7  Configure database features" "$ROOT" > /dev/null 2>&1
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["components"]["semantic_views"]={"ownership":"kit","version":"0.6.1","state":"installed"}; json.dump(d,open(p,"w"))' "$B/home/manifest.json"
check "an installed add-on whose module the database lacks" "" "$(D="$B"; rules_for PREPROC_RT.SEMANTIC_VIEWS)"
B_OUT="$(bridge eval 'personal_deployment_running() { return 0; }; exakit_core_update_check all; printf "ACTED=%s\n" "$EXAKIT_CORE_UPDATE_ACTED"; exakit_core_preprocessor_verify all; printf "RC=%s\n" "$?"' 2>&1)"
has "...no core task is pending, so the installer is not rerun" "ACTED=0" "$B_OUT"
lacks "exakit update's verify pass leaves no line for the framework it only verified" "verified and active" "$B_OUT"
has "...and says the module it registered" "Semantic Views registered with the SQL preprocessor framework: PREPROC_RT.SEMANTIC_VIEWS_V1 for role PUBLIC" "$B_OUT"
has "...exit 0" "RC=0" "$B_OUT"
check "...its rule is in the database" "ROLE:PUBLIC:EXPAND:PREPROC_RT.SEMANTIC_VIEWS_V1" "$(D="$B"; rules_for PREPROC_RT.SEMANTIC_VIEWS)"
B_OUT="$(bridge eval 'personal_deployment_running() { return 0; }; exakit_core_preprocessor_verify all; printf "RC=%s\n" "$?"' 2>&1)"
check "a clean verify (nothing to repair) prints nothing that stays: a normal update looks as before" "RC=0" "$B_OUT"
has "...the verification is in the log" "PREPROC OK SQL preprocessor framework 0.9.1 verified and active" "$(cat "$B/home/setup.log")"
B_OUT="$(bridge exakit_core_database_step "Step 4/7  Configure database features" "$ROOT" 2>&1)"
has "...while the installer's pass still says it" "SQL preprocessor framework 0.9.1 verified and active" "$B_OUT"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["calls"]=[]; json.dump(d,open(p,"w"))' "$B/state.json"
B_OUT="$(bridge eval 'personal_deployment_running() { return 1; }; exakit_core_preprocessor_verify all; printf "RC=%s\n" "$?"' 2>&1)"
has "with the database stopped it is said, not started" "The database is not running, so the SQL preprocessor modules were not checked" "$B_OUT"
check "...and nothing reached the database" "" "$(D="$B"; calls)"
B_OUT="$(bridge eval 'personal_deployment_running() { return 0; }; exakit_core_preprocessor_verify exapump; printf "RC=%s\n" "$?"' 2>&1)"
check "exakit update <one component> keeps its scope" "RC=0" "$B_OUT"
check "...nothing reached the database" "" "$(D="$B"; calls)"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["components"]["preprocessor"]["declined"]=True; json.dump(d,open(p,"w"))' "$B/home/manifest.json"
B_OUT="$(bridge eval 'personal_deployment_running() { return 0; }; exakit_core_preprocessor_verify all; printf "RC=%s\n" "$?"' 2>&1)"
check "a declined slot is left alone" "RC=0" "$B_OUT"
check "...nothing reached the database" "" "$(D="$B"; calls)"
has "exakit update runs it after its core-setup check" "exakit_core_preprocessor_verify \"\$_target\"" "$(sed -n '/^_exakit_update_run()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "...and so does exakit.ps1" 'Invoke-ExakitCorePreprocessorVerify -Target $Target' "$(sed -n '/^function Invoke-ExakitUpdateRun/,/^}/p' "$ROOT/setup/exakit.ps1")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
