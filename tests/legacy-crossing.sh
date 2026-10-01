#!/usr/bin/env bash
# legacy-crossing.sh — the crossing from an older kit's container database onto
# this kit's Exasol Personal deployment.
#
# Everything here runs against a SANDBOXED kit home with a stub engine and a
# stub exapump. That is deliberate and not a compromise: the questions this
# suite asks are what the crossing DECIDES and what it HANDS to those two
# programs, and both are answerable exactly. What a real engine does with a
# correct argv is the engine's business.
#
#   bash tests/legacy-crossing.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s = %s\n' "$1" "$3"
    else FAIL=$((FAIL+1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; fi
}
has() {
    case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac
}
lacks() {
    case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/exakit-legacy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A kit home holding the manifest an OLDER kit would have written. Every field
# the crossing reads is here, and nothing else is: the crossing must work from
# the record alone.
seed_home() { # seed_home <dir> [runtime-type]
    _sh_dir="$1"; _sh_type="${2:-nano}"
    mkdir -p "$_sh_dir/credentials"
    printf 'legacysecret\n' > "$_sh_dir/credentials/nano_sys_password"
    chmod 600 "$_sh_dir/credentials/nano_sys_password"
    cat > "$_sh_dir/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": { "version": "0.1.0", "source": "exasol-labs/exasol-personal-local-starterkit@0.1.0" },
  "runtime": {
    "type": "$_sh_type",
    "engine": "fakeengine",
    "image": "docker.io/exasol/nano:2026.2.0-nano.2",
    "container": "exasol-nano",
    "volume": "exasol-nano-data",
    "dsn": "127.0.0.1:8563",
    "user": "sys",
    "password_file": "$_sh_dir/credentials/nano_sys_password",
    "status": "healthy"
  },
  "steps_completed": ["runtime"]
}
EOF
}

# run <home> <stub-state> <statements> — the module, loaded against a sandboxed
# home with a stub engine on PATH, running whatever the caller passes.
#
# HERMETIC WHERE IT COUNTS: EXAKIT_HOME and EXAKIT_BIN_DIR are sandboxed, and
# the stub directory is PREPENDED to the real PATH rather than replacing it.
# Replacing it also takes away the 3.11+ python3 the manifest writer needs (a
# stock macOS /usr/bin/python3 is 3.9), and every manifest_set then becomes a
# uv bootstrap that fails for a reason unrelated to anything being tested. The
# stubs still win: they are first, and "fakeengine" exists nowhere else.
run() {
    _r_home="$1"; _r_state="$2"; _r_body="$3"
    _r_bin="$WORK/bin-$_r_state"
    mkdir -p "$_r_bin"
    # The engine stub answers the two verbs the state probe uses, and records
    # every call so the assertions can read back what it was handed.
    cat > "$_r_bin/fakeengine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/engine.calls"
case "\$1 \$2" in
  "container inspect")
      [ "$_r_state" = absent ] && exit 1
      [ "$_r_state" = down ] && exit 1
      [ "$_r_state" = unknown ] && { printf 'weird\n'; exit 0; }
      [ "$_r_state" = running ] && { printf 'true\n'; exit 0; }
      printf 'false\n'; exit 0 ;;
  "version --format")
      [ "$_r_state" = down ] && exit 1
      printf '1.0\n'; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$_r_bin/fakeengine"
    EXAKIT_HOME="$_r_home" \
    EXAKIT_BIN_DIR="$_r_home/bin" \
    EXAKIT_LEGACY_EXPORT_DIR="$_r_home/migration" \
    PATH="$_r_bin:$PATH" \
    ROOT="$ROOT" WORK="$WORK" \
    bash -c '
        . "$ROOT/setup/lib/common.sh"
        . "$ROOT/setup/lib/detect.sh"
        . "$ROOT/setup/lib/exapump.sh"
        . "$ROOT/setup/lib/legacy-crossing.sh"
        '"$_r_body"' ' 2>&1
}

echo "the record is the whole test for 'is this a legacy install':"
H1="$WORK/h1"; seed_home "$H1" nano
check "a recorded container runtime is one" "yes" \
    "$(run "$H1" running 'legacy_db_recorded && echo yes || echo no')"
H2="$WORK/h2"; seed_home "$H2" personal
check "a Personal install is not"          "no" \
    "$(run "$H2" running 'legacy_db_recorded && echo yes || echo no')"
H3="$WORK/h3"; mkdir -p "$H3"; printf '{"manifest_version":1}\n' > "$H3/manifest.json"
check "and neither is a fresh machine"     "no" \
    "$(run "$H3" running 'legacy_db_recorded && echo yes || echo no')"
# The predicate the CLI uses and the one the crossing uses must be the same
# function, or `exakit status` and the installer can disagree about the machine.
has "the crossing delegates to the CLI's predicate" "exakit_legacy_runtime_recorded" \
    "$(cat "$ROOT/setup/lib/legacy-crossing.sh")"

echo
echo "the container's state, read through the recorded engine:"
check "running"  "running"  "$(run "$H1" running  'legacy_container_state')"
check "stopped"  "stopped"  "$(run "$H1" stopped  'legacy_container_state')"
check "absent"   "absent"   "$(run "$H1" absent   'legacy_container_state')"
# An engine that answers something unparseable is NOT evidence the database is
# gone. "unknown" keeps the migrate offer available instead of quietly
# withdrawing it.
check "unparseable is unknown, never absent" "unknown" "$(run "$H1" unknown 'legacy_container_state')"
# Docker Desktop stopped: the CLI is there, inspect fails and the server version
# is empty. An engine that will not talk, not a missing container.
check "a stopped engine is unknown, never absent" "unknown" "$(run "$H1" down 'legacy_container_state')"
# The engine NAME comes from the record, never from the machine: a host with a
# different engine installed must not be asked about this container. The stub
# engine lives only in the bin-* directories run() prepends, so the outer PATH
# is already an engine-less PATH; cutting it to /usr/bin:/bin took the working
# python3 away too (a stock macOS one refuses to run until the Xcode licence is
# accepted) and the manifest then read as empty - "absent" for the wrong reason.
check "an engine that is gone answers unknown" "unknown" \
    "$(EXAKIT_HOME="$H1" EXAKIT_BIN_DIR="$H1/bin" ROOT="$ROOT" bash -c '
        . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"
        . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"
        legacy_container_state' 2>/dev/null)"

echo
echo "the removal command names BOTH things that hold data:"
# A container removed without its volume leaves the database on disk, and the
# volume is the part the user cannot find again by name afterwards.
_rm="$(run "$H1" running 'legacy_remove_command')"
has "it names the container"  "exasol-nano"      "$_rm"
has "it names the volume"     "exasol-nano-data" "$_rm"
has "it uses the recorded engine" "fakeengine"   "$_rm"

echo
echo "nothing in the crossing ever removes the old database:"
# THE INVARIANT. The crossing copies and stops; it never deletes. A migration
# that has just copied data out is exactly the wrong moment to destroy the only
# other copy, and "skip" means skip.
for _f in legacy-crossing.sh legacy-crossing.ps1; do
    _body="$(sed '/^# /d' "$ROOT/setup/lib/$_f")"
    lacks "$_f issues no rm"        'Arguments @("rm"'  "$_body"
    lacks "$_f issues no rm (sh)"   'legacy_engine_run rm' "$_body"
    lacks "$_f issues no volume rm" 'volume", "rm'      "$_body"
done
# ...and the only place those words appear is the command PRINTED for the user.
has "the removal command is printed, not run" "legacy_remove_command" \
    "$(cat "$ROOT/setup/lib/legacy-crossing.sh")"

echo
echo "the password never reaches a command line:"
# `ps` is readable by every process on the machine. The profile file is 0600.
for _f in legacy-crossing.sh legacy-crossing.ps1; do
    lacks "$_f passes no dsn with credentials" 'exasol://' "$(cat "$ROOT/setup/lib/$_f")"
    lacks "$_f passes no -d flag"              '"-d"'      "$(cat "$ROOT/setup/lib/$_f")"
done
has "the sh side writes a profile instead" "exapump_write_profile" \
    "$(cat "$ROOT/setup/lib/legacy-crossing.sh")"
has "and the ps side does too"             "Set-ExapumpTomlSection" \
    "$(cat "$ROOT/setup/lib/legacy-crossing.ps1")"
# One writer, not two: the kit's own profile and the legacy one go through the
# same TOML surgery, or they drift.
has "exapump.sh exposes the shared writer" "exapump_write_profile()" \
    "$(cat "$ROOT/setup/lib/exapump.sh")"

echo
echo "the question, and what pre-answers it:"
_choose() {
    run "$H1" running "EXAKIT_LEGACY_DATA=$1 legacy_choose 5 ${2:-yes} 'a reason' >/dev/null 2>&1; printf 'CHOICE=%s' \"\$EXAKIT_LEGACY_CHOICE\"" \
        | sed -n 's/.*CHOICE=\([a-z]*\).*/\1/p' | tail -1
}
check "EXAKIT_LEGACY_DATA=migrate" "migrate" "$(_choose migrate)"
check "=yes is the same answer"    "migrate" "$(_choose yes)"
check "=skip"                      "skip"    "$(_choose skip)"
check "=no is the same answer"     "skip"    "$(_choose no)"
# A pre-answer cannot conjure a copy that is impossible. It is honoured where
# it can be and downgraded, loudly, where it cannot.
check "migrate is refused when it cannot be done" "skip" "$(_choose migrate no)"
has "and the reason is given, not just the refusal" "the container is gone" \
    "$(run "$H1" running "EXAKIT_LEGACY_DATA=migrate legacy_choose 5 no 'the container is gone'" 2>&1)"
# UNATTENDED RUNS SKIP. Copying a database is not something to start on
# someone's behalf while they are not there, and skipping destroys nothing.
_unattended="$(run "$H1" running 'legacy_choose 5 yes "" </dev/null >/dev/null 2>&1; printf "CHOICE=%s" "$EXAKIT_LEGACY_CHOICE"' \
    | sed -n 's/.*CHOICE=\([a-z]*\).*/\1/p' | tail -1)"
check "an unattended run skips by default" "skip" "$_unattended"
has "...and says how to ask for the copy" "EXAKIT_LEGACY_DATA=migrate" \
    "$(run "$H1" running 'legacy_choose 5 yes "" </dev/null')"
# The two answers are mutually exclusive: this is a fork in the road, not a set
# of features, so the menu marks the second row exclusive.
has "the menu makes the answers exclusive" "EXAKIT_CHECKBOX_EXCLUSIVE=2" \
    "$(cat "$ROOT/setup/lib/legacy-crossing.sh")"
has "...and the twin does too" "-ExclusiveIndex 2" \
    "$(cat "$ROOT/setup/lib/legacy-crossing.ps1")"

echo
echo "the export, and the index the other half reads back:"
# A stub exapump: export writes a file, and the column query answers with the
# sentinel the DDL builder parses.
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/exapump" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUBLOG"
case "$1" in
  export)
      _out=""
      while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { _out="$2"; break; }; shift; done
      [ -n "$_out" ] && printf 'A,B\n1,2\n' > "$_out"
      exit 0 ;;
  sql)
      case "$*" in
        *EXA_ALL_COLUMNS*)
            printf 'EXAKIT_LC[ID<<:>>DECIMAL(18,0)]\nEXAKIT_LC[my col<<:>>TIMESTAMP WITH LOCAL TIME ZONE]\n'; exit 0 ;;
        *EXA_ALL_TABLES*)
            printf 'EXAKIT_LT[S1.T1]\nEXAKIT_LT[S1.T2]\n'; exit 0 ;;
        *EXAKIT_LEGACY_OK*)
            printf 'EXAKIT_LEGACY_OK\n'; exit 0 ;;
      esac
      exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB/exapump"

H4="$WORK/h4"; seed_home "$H4"
_exp="$(EXAKIT_HOME="$H4" EXAKIT_BIN_DIR="$H4/bin" EXAKIT_EXAPUMP_BIN="$STUB/exapump" \
    STUBLOG="$WORK/stub.log" EXAKIT_LEGACY_EXPORT_DIR="$H4/migration" \
    PATH="$STUB:$PATH" ROOT="$ROOT" bash -c '
    . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"
    . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"
    legacy_export "$EXAKIT_LEGACY_EXPORT_DIR" "S1.T1" "S1/T2" >/dev/null 2>&1
    cat "$EXAKIT_LEGACY_EXPORT_DIR/index"')"
check "one index line per table" "2" "$(printf '%s\n' "$_exp" | grep -c '^t')"
# POSITIONAL FILE NAMES. A schema or table with a slash in it is legal in
# Exasol; a file name derived from it would write outside the export directory.
has "the file name is positional"  "t1.csv" "$_exp"
has "...for every table"           "t2.csv" "$_exp"
lacks "a slash in a table name never reaches a path" "S1/T2.csv" "$_exp"
# The index carries everything the restore needs, including the DDL - which is
# what keeps the types.
has "the index carries the schema"  "S1"                  "$_exp"
has "the index carries the DDL"     "CREATE TABLE"        "$_exp"
has "the DDL keeps the source type" "DECIMAL(18,0)"       "$_exp"
# A type with spaces in it survives too - the marker is there so neither end
# has to be found by splitting on whitespace.
has "...including a multi-word type" "TIMESTAMP WITH LOCAL TIME ZONE" "$_exp"
# Quoted identifiers: a column with a space or a reserved word in its name is
# legal in Exasol and illegal unquoted.
has "identifiers are quoted"        '"my col"'            "$_exp"
# CSV, because `exapump export --format parquet` writes a 0-byte file and then
# fails re-parsing its own output in the versions this kit installs.
has "the export asks for csv"       "--format csv" "$(cat "$WORK/stub.log")"
lacks "and never for parquet"       "parquet"      "$(cat "$WORK/stub.log")"
# THE HERMETICITY GUARD, and it is not decoration: an empty stub log means the
# run found a REAL exapump instead, and every assertion above it was measuring
# the developer's own database. That happened once. It fails loudly now.
check "the export went through the stub, not a real exapump" "yes" \
    "$([ -s "$WORK/stub.log" ] && echo yes || echo "NO - the run escaped its sandbox")"

echo
echo "the restore skips what the fresh install already made:"
# The bundled sample data is loaded before the restore runs, so appending to a
# table that is already there would double every row of it.
H5="$WORK/h5"; seed_home "$H5"
mkdir -p "$H5/migration"
printf 'a.csv\tS1\tKEEP\tCREATE TABLE "S1"."KEEP" (A DECIMAL(9,0))\n' > "$H5/migration/index"
printf 'b.csv\tS1\tALREADY\tCREATE TABLE "S1"."ALREADY" (A DECIMAL(9,0))\n' >> "$H5/migration/index"
printf 'A\n1\n' > "$H5/migration/a.csv"; printf 'A\n1\n' > "$H5/migration/b.csv"
# ITS OWN DIRECTORY, AND THE NAME `exapump`. The first draft of this fixture
# called the stub "exapump2" and relied on EXAKIT_EXAPUMP_BIN alone. That
# variable was assigned unconditionally in exapump.sh, so the override was
# discarded at source time, exapump_cli fell through to the `exapump` on PATH,
# and this test ran the DEVELOPER'S REAL exapump against the DEVELOPER'S REAL
# database - creating a schema in it. The product bug is fixed; the fixture no
# longer depends on that fix being in place.
STUB2="$WORK/stub2"; mkdir -p "$STUB2"
cat > "$STUB2/exapump" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUBLOG"
# The new database answers its probe; CREATE TABLE for the ALREADY table
# fails, the way a real one does when the fresh install has already created
# it. Matched on "CREATE TABLE", not on the name alone: "CREATE SCHEMA IF NOT
# EXISTS" is issued for every row.
case "$*" in
  *EXAKIT_NEW_OK*) printf 'EXAKIT_NEW_OK\n'; exit 0 ;;
  *"CREATE TABLE"*ALREADY*) exit 1 ;;
esac
exit 0
EOF
chmod +x "$STUB2/exapump"
: > "$WORK/stub2.log"
_imp="$(EXAKIT_HOME="$H5" EXAKIT_BIN_DIR="$H5/bin" EXAKIT_EXAPUMP_BIN="$STUB2/exapump" \
    STUBLOG="$WORK/stub2.log" PATH="$STUB2:$PATH" ROOT="$ROOT" bash -c '
    . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"
    . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"
    legacy_import "$EXAKIT_HOME/migration" >/dev/null 2>&1
    printf "restored=%s skipped=%s" "$EXAKIT_LEGACY_RESTORED" "$EXAKIT_LEGACY_SKIPPED"')"
check "the new table is restored, the existing one is not" "restored=1 skipped=1" "$_imp"
# The skip is a SKIP, not an append: no upload may be issued for it.
lacks "no upload is issued for the existing table" 'ALREADY' \
    "$(grep '^upload' "$WORK/stub2.log" || true)"
has "and the new one is uploaded" '"S1"."KEEP"' \
    "$(grep '^upload' "$WORK/stub2.log" || true)"
check "the restore went through the stub, not a real exapump" "yes" \
    "$([ -s "$WORK/stub2.log" ] && echo yes || echo "NO - the run escaped its sandbox")"
check "the counts are recorded for the reader" "1" \
    "$(EXAKIT_HOME="$H5" ROOT="$ROOT" bash -c '. "$ROOT/setup/lib/common.sh"; manifest_get legacy.restored')"

echo
echo "the container is stopped on BOTH answers, because it holds the port:"
# The old container is listening on the port the new deployment wants. Skip
# means "keep the data", not "keep the port".
_body="$(sed -n '/^legacy_crossing_before()/,/^}/p' "$ROOT/setup/lib/legacy-crossing.sh")"
_stops="$(printf '%s\n' "$_body" | grep -c 'legacy_stop_container')"
check "the sh half stops it outside any choice branch" "yes" \
    "$([ "$_stops" -ge 2 ] && echo yes || echo "no ($_stops)")"
has "and says why"  "take the port" "$(cat "$ROOT/setup/lib/legacy-crossing.sh")"
has "the twin too"  "take the port" "$(cat "$ROOT/setup/lib/legacy-crossing.ps1")"
# Stopped, not removed.
has "it is stopped, never removed" 'legacy_engine_run stop' "$(cat "$ROOT/setup/lib/legacy-crossing.sh")"

echo
echo "a machine with nothing to cross passes straight through:"
# Every fresh install runs this code. It must cost nothing and say nothing.
_fresh="$(run "$H3" absent 'legacy_crossing_before; legacy_crossing_after; echo DONE')"
check "no output, and it returns" "DONE" "$(printf '%s' "$_fresh" | tr -d '[:space:]')"

echo
echo "asked ONCE, and only where there is something to ask about:"
# THIS CODE RUNS ON EVERY INSTALL. An installer that announces "your database
# is in a container" to someone whose container is long gone, or on every
# re-run after the crossing already happened, is a nag. Each gate below closes
# SILENTLY - the assertions are about what does NOT reach the screen.

# Gate 2: the crossing already happened on this machine.
H6="$WORK/h6"; seed_home "$H6"
_done="$(run "$H6" running 'manifest_set legacy.crossing_done true
    legacy_crossing_before; echo SILENT')"
check "a machine that already crossed is silent" "SILENT" "$(printf '%s' "$_done" | tr -d '[:space:]')"

# A resumed attempt at the SAME install: the question was already answered, so
# it is neither re-asked nor narrated. The restore half does the talking.
H7="$WORK/h7"; seed_home "$H7"
_resume="$(run "$H7" running 'manifest_set legacy.choice migrate
    manifest_set legacy.export_dir "$EXAKIT_HOME/migration"
    legacy_crossing_before; echo SILENT')"
check "a resumed attempt is silent too" "SILENT" "$(printf '%s' "$_resume" | tr -d '[:space:]')"
lacks "and asks nothing" "Migrate my data" "$_resume"

# Gate 3: a legacy record, but no database left to copy. The container is
# absent, so there is no offer to make - and nothing to say about it.
H8="$WORK/h8"; seed_home "$H8"
_nothing="$(run "$H8" absent 'legacy_crossing_before; echo SILENT')"
check "no container, no banner, no question" "SILENT" "$(printf '%s' "$_nothing" | tr -d '[:space:]')"
lacks "the banner is not printed" "runs in a container" "$_nothing"
lacks "and no question is asked"  "Migrate my data"    "$_nothing"
# The reason is not lost - it goes to the log, where someone asking "why was I
# not offered a migration?" can find it.
has "the reason is logged instead" "no offer made" "$(cat "$ROOT/setup/lib/legacy-crossing.sh")"
has "...on the Windows side too"   "no offer made" "$(cat "$ROOT/setup/lib/legacy-crossing.ps1")"
# ...and it is settled for good, so the probe is never repeated.
check "and the crossing is marked done" "true" \
    "$(run "$H8" absent 'legacy_crossing_before >/dev/null 2>&1; manifest_get legacy.crossing_done' | tail -1)"

# THE QUESTION IS IN THE OTHER HALF. The first half says nothing about the old
# database at all: it reads the tables out while the container still holds the
# port, and the question waits for the half that runs after exapump, where a
# copy already exists to ask about.
_cb="$(sed -n '/^legacy_crossing_before()/,/^}/p' "$ROOT/setup/lib/legacy-crossing.sh")"
_ca="$(sed -n '/^legacy_crossing_after()/,/^}/p' "$ROOT/setup/lib/legacy-crossing.sh")"
lacks "the first half never asks"     "legacy_choose" "$_cb"
lacks "...and never announces"        "Found your previous starter kit" "$_cb"
has   "the second half asks"          "legacy_choose" "$_ca"
has   "...after saying what it found" "Found your previous starter kit" "$_ca"
_banner_at="$(printf '%s\n' "$_ca" | grep -n 'Found your previous starter kit' | head -1 | cut -d: -f1)"
_choose_at="$(printf '%s\n' "$_ca" | grep -n 'legacy_choose' | head -1 | cut -d: -f1)"
check "and says what it found before it asks" "yes" \
    "$([ -n "$_banner_at" ] && [ -n "$_choose_at" ] && [ "$_banner_at" -lt "$_choose_at" ] && echo yes || echo no)"
# The counts the question quotes are read in the first half, where the database
# could still be reached, and carried across in the record.
has "the counts are recorded for it" "manifest_set legacy.tables_own" "$_cb"
has "...and read back to ask with"   "legacy.tables_own" "$_ca"

# Once asked, marked - so the next install of any kind never reconsiders it.
has "a crossing that was offered is marked done" "manifest_set legacy.crossing_done true" \
    "$(cat "$ROOT/setup/lib/legacy-crossing.sh")"
has "...and the twin marks it too" 'Set-ExakitManifestValue "legacy.crossing_done" $true' \
    "$(cat "$ROOT/setup/lib/legacy-crossing.ps1")"

echo
echo "both halves are wired into all three installers:"
for _s in setup/setup-macos.sh setup/setup-linux.sh; do
    has "$_s calls the first half"  "legacy_crossing_before" "$(cat "$ROOT/$_s")"
    has "$_s calls the second half" "legacy_crossing_after"  "$(cat "$ROOT/$_s")"
done
has "setup-windows.ps1 calls the first half"  "Invoke-LegacyCrossingBefore" "$(cat "$ROOT/setup/setup-windows.ps1")"
has "setup-windows.ps1 calls the second half" "Invoke-LegacyCrossingAfter"  "$(cat "$ROOT/setup/setup-windows.ps1")"
# THE ORDER IS THE FEATURE. The first half must precede the requirements gate
# (it needs the old database up); the second must follow the shared steps (it
# needs a new database, an exapump and a profile pointing at the new one).
for _s in setup/setup-macos.sh setup/setup-linux.sh; do
    _before="$(grep -n 'legacy_crossing_before' "$ROOT/$_s" | head -1 | cut -d: -f1)"
    _req="$(grep -n 'personal_check_requirements' "$ROOT/$_s" | head -1 | cut -d: -f1)"
    _after="$(grep -n 'legacy_crossing_after' "$ROOT/$_s" | head -1 | cut -d: -f1)"
    _shared="$(grep -n 'kit_shared_steps' "$ROOT/$_s" | head -1 | cut -d: -f1)"
    check "$_s: ask before the requirements gate" "yes" \
        "$([ "$_before" -lt "$_req" ] && echo yes || echo no)"
    check "$_s: restore after the shared steps"   "yes" \
        "$([ "$_after" -gt "$_shared" ] && echo yes || echo no)"
done

echo
echo "the twins hold the same contract:"
# Every sh function in the module has a PowerShell peer. The map is explicit
# because the two naming conventions do not translate mechanically.
while IFS='|' read -r _sh _ps; do
    [ -n "$_sh" ] || continue
    grep -q "^$_sh()" "$ROOT/setup/lib/legacy-crossing.sh" || { FAIL=$((FAIL+1)); printf '  FAIL sh side is missing %s\n' "$_sh"; continue; }
    grep -q "^function $_ps" "$ROOT/setup/lib/legacy-crossing.ps1" || { FAIL=$((FAIL+1)); printf '  FAIL ps side is missing %s (peer of %s)\n' "$_ps" "$_sh"; continue; }
    PASS=$((PASS+1)); printf '  ok   %s <-> %s\n' "$_sh" "$_ps"
done <<'EOF'
legacy_db_recorded|Test-LegacyDbRecorded
legacy_container|Get-LegacyContainer
legacy_volume|Get-LegacyVolume
legacy_engine|Get-LegacyEngine
legacy_container_state|Get-LegacyContainerState
legacy_start_container|Start-LegacyContainer
legacy_stop_container|Stop-LegacyContainer
legacy_remove_command|Get-LegacyRemoveCommand
legacy_write_profile|Write-LegacyProfile
legacy_db_answers|Test-LegacyDbAnswers
legacy_tables|Get-LegacyTables
legacy_table_ddl|Get-LegacyTableDdl
legacy_choose|Select-LegacyChoice
legacy_export|Export-LegacyTables
legacy_import|Import-LegacyTables
legacy_crossing_before|Invoke-LegacyCrossingBefore
legacy_crossing_after|Invoke-LegacyCrossingAfter
legacy_password_file|Get-LegacyPasswordFile
legacy_engine_name|Get-LegacyEngineName
legacy_remember_record|Save-LegacyRecord
legacy_forget_old_steps|Clear-LegacyOldSteps
legacy_new_db_answers|Test-LegacyNewDbAnswers
legacy_wait_port_free|Wait-LegacyPortFree
legacy_wait_db_answers|Wait-LegacyDbAnswers
legacy_sample_catalog|Get-LegacySampleCatalog
legacy_table_rows|Get-LegacyTableRows
legacy_classify|Split-LegacyTables
legacy_sample_note|Write-LegacySampleNote
legacy_report_restore|Write-LegacyRestoreReport
_legacy_migrate_fail|Set-LegacyMigrateFailure
_legacy_migrate_settle|Restore-LegacyMigrateState
legacy_migrate_now|Invoke-LegacyMigrateNow
EOF

# Every read from the old database goes through ONE reader on each side, and on
# the PowerShell side that reader holds a Continue window: under the global
# Stop preference, a native command writing to stderr becomes a TERMINATING
# error on 5.1 before its exit code can be read, and exapump writes progress to
# stderr while succeeding.
has "the ps side reads through one query helper" "function Invoke-LegacyQuery" \
    "$(cat "$ROOT/setup/lib/legacy-crossing.ps1")"
has "...inside a Continue window" 'ErrorActionPreference = "Continue"' \
    "$(cat "$ROOT/setup/lib/legacy-crossing.ps1")"
check "and no query bypasses it" "1" \
    "$(grep -c 'Get-ExapumpCli) sql' "$ROOT/setup/lib/legacy-crossing.ps1")"

echo
echo "the CLI explains a legacy install instead of calling it broken:"
# "nano - not installed" reads as a broken install. It is not: it is an
# installation this kit does not manage, and the fix is the installer.
has "status says which it is" "from an older kit, not managed here" "$(cat "$ROOT/setup/exakit")"
has "...and the twin agrees"  "from an older kit, not managed here" "$(cat "$ROOT/setup/exakit.ps1")"
has "the notice names the crossing command" "Re-run the installer to move across" \
    "$(cat "$ROOT/setup/lib/common.sh")"
has "...on the Windows side too" "Re-run the installer to move across" \
    "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
_st="$(EXAKIT_HOME="$H1" EXAKIT_BIN_DIR="$H1/bin" \
    bash "$ROOT/setup/exakit" status 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
has "and a real status run says it" "not managed here" "$_st"

echo
echo "the kit's own sample data is told apart from the user's:"
# The catalog is read from the kit's real data/datasets: TPC-H's region.csv has
# 5 rows, nation.csv 25. A table with the same schema, name and row count is
# the sample, unchanged; anything else is the user's.
STUB3="$WORK/stub3"; mkdir -p "$STUB3"
cat > "$STUB3/exapump" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUBLOG"
case "$*" in
  *EXAKIT_LR*) printf 'EXAKIT_LR[TPCH.REGION<<:>>5]\nEXAKIT_LR[TPCH.NATION<<:>>24]\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB3/exapump"
_cls="$(EXAKIT_HOME="$H1" EXAKIT_BIN_DIR="$H1/bin" EXAKIT_EXAPUMP_BIN="$STUB3/exapump" \
    STUBLOG="$WORK/stub3.log" PATH="$STUB3:$PATH" ROOT="$ROOT" bash -c '
    . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"
    . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"
    legacy_classify "S1.T1
TPCH.REGION
TPCH.NATION
My Schema.T"
    printf "OWN=%s|SAMPLE=%s|IDS=%s" "$(printf "%s" "$EXAKIT_LEGACY_OWN_TABLES" | tr "\n" "," | sed "s/,\$//")" \
        "$(printf "%s" "$EXAKIT_LEGACY_SAMPLE_TABLES" | tr "\n" "," | sed "s/,\$//")" "$EXAKIT_LEGACY_SAMPLE_IDS"')"
check "the unchanged sample table is the kit's, the rest the user's" \
    "OWN=S1.T1,TPCH.NATION,My Schema.T|SAMPLE=TPCH.REGION|IDS=tpch" "$_cls"
check "the row counts were asked once, for the sample schema" "1" \
    "$(grep -c "IN ('TPCH')" "$WORK/stub3.log")"
has "the catalog names the kit's tables with their row counts" "TPCH.REGION|tpch|5" \
    "$(ROOT="$ROOT" EXAKIT_HOME="$H1" bash -c '. "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"; . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"; legacy_sample_catalog')"
# A table outside every sample schema never costs a query.
: > "$WORK/stub3.log"
_cls2="$(EXAKIT_HOME="$H1" EXAKIT_BIN_DIR="$H1/bin" EXAKIT_EXAPUMP_BIN="$STUB3/exapump" \
    STUBLOG="$WORK/stub3.log" PATH="$STUB3:$PATH" ROOT="$ROOT" bash -c '
    . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"
    . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"
    legacy_classify "S1.T1"; printf "%s" "$EXAKIT_LEGACY_OWN_TABLES" | tr -d "\n"')"
check "a table in no sample schema is the user's" "S1.T1" "$_cls2"
check "...and the database was not asked about it" "0" "$(grep -c 'EXAKIT_LR' "$WORK/stub3.log" 2>/dev/null || true)"

# A SAMPLE TABLE THE DATASET GENERATES. energy's ENERGY_READINGS is built by
# 02_load_data.sql — 108,000 rows and no CSV — so a catalog read from the CSV
# names alone never saw it. Every upgrade from a kit that had loaded the energy
# dataset was then told it held "1 table(s) in 1 schema(s) of your own": the
# kit's own sample data, offered back to the user, copied out, restored, and
# replaced by the dataset load minutes later. dataset.conf declares it in
# markers=, and the catalog carries it with an empty row count.
_cat="$(ROOT="$ROOT" EXAKIT_HOME="$H1" bash -c '. "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"; . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"; legacy_sample_catalog')"
has "the catalog carries a generated table, row count unknown" "ENERGY.ENERGY_READINGS|energy|" "$_cat"
has "...and the CSV-backed ones keep their counts" "ENERGY.ENERGY_METERS|energy|50" "$_cat"
_gen="$(ROOT="$ROOT" EXAKIT_HOME="$H1" bash -c '. "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"; . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"
    legacy_is_sample_table "ENERGY.ENERGY_READINGS" && printf gen=yes || printf gen=no
    legacy_is_sample_table "MYWORK.SALES" && printf " mine=yes" || printf " mine=no"')"
check "the restore stands aside for the generated table, not the user's" "gen=yes mine=no" "$_gen"
# The whole of the reported case: a kit that loaded the energy dataset and
# nothing else has nothing of the user's in it, so no offer is made at all.
STUB4="$WORK/stub4"; mkdir -p "$STUB4"
cat > "$STUB4/exapump" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUBLOG"
case "$*" in
  *EXAKIT_LR*) printf 'EXAKIT_LR[ENERGY.ENERGY_METERS<<:>>50]\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB4/exapump"
_cls3="$(EXAKIT_HOME="$H1" EXAKIT_BIN_DIR="$H1/bin" EXAKIT_EXAPUMP_BIN="$STUB4/exapump" \
    STUBLOG="$WORK/stub4.log" PATH="$STUB4:$PATH" ROOT="$ROOT" bash -c '
    . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"
    . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/legacy-crossing.sh"
    legacy_classify "ENERGY.ENERGY_METERS
ENERGY.ENERGY_READINGS"
    _own="$(printf "%s" "$EXAKIT_LEGACY_OWN_TABLES" | tr "\n" ",")"
    _smp="$(printf "%s" "$EXAKIT_LEGACY_SAMPLE_TABLES" | tr "\n" ",")"
    printf "OWN=%s|SAMPLE=%s|IDS=%s" "${_own%,}" "${_smp%,}" "$EXAKIT_LEGACY_SAMPLE_IDS"')"
check "a database holding only the energy dataset has nothing of the user's" \
    "OWN=|SAMPLE=ENERGY.ENERGY_METERS,ENERGY.ENERGY_READINGS|IDS=energy" "$_cls3"

echo
echo "the after-the-install road: exakit migrate docker-nano"
has "the CLI loads the crossing module"      'legacy-crossing.sh' "$(cat "$ROOT/setup/exakit")"
has "...and dispatches migrate"               'cmd_migrate' "$(sed -n '/^case "\${1:-help}" in/,/^esac/p' "$ROOT/setup/exakit")"
has "the twin loads it too"                   'legacy-crossing.ps1' "$(cat "$ROOT/setup/exakit.ps1")"
has "...and dispatches migrate"               'Invoke-CmdMigrate' "$(cat "$ROOT/setup/exakit.ps1")"
has "the help document describes it"          '"command": "migrate"' "$(cat "$ROOT/setup/help/exakit.json")"
has "...with the source it takes"             'docker-nano' "$(cat "$ROOT/setup/help/exakit.json")"
# THE RENDERED SURFACE, not a banner comment. These two lines used to sed the
# first 80 (and 60) lines of each CLI and look for "migrate docker-nano" - a
# range that lands squarely in the `#` header block, so what they asserted was
# the presence of a string in a comment no user or agent ever reads. The real
# help is rendered from setup/help/*.json, and dropping the crossing from that
# document made the command invisible to everyone while all 199 checks passed.
# The range was brittle in the ordinary way too: add 20 lines to the banner and
# the check fails for a reason unrelated to the crossing.
_lc_help="$(bash "$ROOT/setup/exakit" help --json 2>/dev/null)"
has "the rendered help offers the crossing"   '"command": "migrate"' "$_lc_help"
has "...naming the source it takes"           'docker-nano' "$_lc_help"
# ...and the capture is a document, not an error page that happens to contain
# the words: an empty or non-JSON answer must not read as a pass.
check "...as a parseable help document" "yes" \
    "$(printf '%s' "$_lc_help" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print("yes" if any(c.get("command") == "migrate" for c in d.get("commands", [])) else "no")
except Exception:
    print("no")' 2>/dev/null)"
# The Windows twin renders from those same documents rather than carrying its
# own help text, which is the property that keeps the two surfaces equal.
has "...on the Windows side too"              'Show-ExakitHelpJson' "$(cat "$ROOT/setup/exakit.ps1")"
# Bad input is refused BEFORE the install check, exit 2, so a typo never reads
# as "not installed".
_mg() { EXAKIT_HOME="$WORK/mg-nohome" EXAKIT_BIN_DIR="$WORK/mg-nohome/bin" bash "$ROOT/setup/exakit" migrate "$@" 2>&1; echo "RC=$?"; }
_rc() { printf '%s\n' "$1" | sed -n 's/^RC=\([0-9]*\)$/\1/p' | tail -1; }
_o="$(_mg)";                              check "no source is refused"                 "2" "$(_rc "$_o")"
has "...naming the one there is"           "exakit migrate docker-nano [--container NAME]" "$_o"
_o="$(_mg something-else)";               check "an unknown source is refused"         "2" "$(_rc "$_o")"
_o="$(_mg docker-nano --password x)";     check "a password on the command line is refused" "2" "$(_rc "$_o")"
has "...and told where it goes instead"    "--password-file" "$_o"
_o="$(_mg docker-nano --engine lxc)";     check "an engine the kit does not drive is refused" "2" "$(_rc "$_o")"
_o="$(_mg docker-nano --dsn nohost)";     check "a dsn without a port is refused"      "2" "$(_rc "$_o")"
_o="$(_mg docker-nano --bogus)";          check "an unknown option is refused"         "2" "$(_rc "$_o")"
_o="$(_mg docker-nano --container)";      check "a value flag without its value is refused" "2" "$(_rc "$_o")"
_o="$(_mg docker-nano --password-file "$WORK/no-such-file")"; check "a missing password file is refused" "2" "$(_rc "$_o")"
_o="$(_mg docker-nano --bogus --json)";   has "a refusal in JSON is an object"        '"rejected": true' "$_o"
check "...exit 2 still"                    "2" "$(_rc "$_o")"
# Then the install gate, with its documented codes.
_o="$(_mg docker-nano)";                  check "not installed exits 4"               "4" "$(_rc "$_o")"
_o="$(_mg docker-nano --json)";           has "...and says so in JSON"                '"installed": false' "$_o"
# A legacy install that has not crossed yet has no deployment to copy INTO:
# the installer is the road, and that is what the answer names.
_o="$(EXAKIT_HOME="$H1" EXAKIT_BIN_DIR="$H1/bin" bash "$ROOT/setup/exakit" migrate docker-nano --json 2>&1; echo "RC=$?")"
check "a not-yet-crossed legacy install exits 3"   "3" "$(_rc "$_o")"
has "...as no database"                    '"status": "no database"' "$_o"
has "...with the installer as the remedy"  'install' "$_o"
# A Personal install, with a stub engine that knows no such container: the
# command reaches the module and fails there with the container named.
H9="$WORK/h9"; mkdir -p "$H9/bin"
cat > "$H9/manifest.json" <<EOF
{"manifest_version": 1, "kit_level": 1, "runtime": {"type": "personal", "dsn": "127.0.0.1:8563"},
 "components": {"exapump": {"profile": "starter-kit"}}, "steps_completed": ["runtime"]}
EOF
STUB4="$WORK/stub4"; mkdir -p "$STUB4"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$STUBLOG"\nexit 1\n' > "$STUB4/docker"
cp "$STUB3/exapump" "$STUB4/exapump"; chmod +x "$STUB4/docker" "$STUB4/exapump"
: > "$WORK/stub4.log"
_o="$(EXAKIT_HOME="$H9" EXAKIT_BIN_DIR="$H9/bin" EXAKIT_EXAPUMP_BIN="$STUB4/exapump" STUBLOG="$WORK/stub4.log" \
    PATH="$STUB4:$PATH" bash "$ROOT/setup/exakit" migrate docker-nano --engine docker --container old-db --password-file "$H1/credentials/nano_sys_password" --json --yes 2>/dev/null; echo "RC=$?")"
check "a container the engine does not know fails, exit 1" "1" "$(_rc "$_o")"
has "...as one JSON object"                '"ok": false' "$_o"
has "...with the status"                   '"status": "failed"' "$_o"
has "...naming the container"              '"container": "old-db"' "$_o"
has "...and the engine"                    '"engine": "docker"' "$_o"
check "the engine named on the command line was the one asked" "yes" "$(grep -q '^container inspect' "$WORK/stub4.log" && echo yes || echo no)"
# The record the crossing kept is the default for everything not named.
_o="$(EXAKIT_HOME="$H9" EXAKIT_BIN_DIR="$H9/bin" ROOT="$ROOT" \
    bash -c '. "$ROOT/setup/lib/common.sh"; manifest_set legacy.container remembered-db; manifest_set legacy.engine docker; manifest_set legacy.dsn 127.0.0.1:9999' 2>/dev/null
    EXAKIT_HOME="$H9" EXAKIT_BIN_DIR="$H9/bin" EXAKIT_EXAPUMP_BIN="$STUB4/exapump" STUBLOG="$WORK/stub4.log" \
    PATH="$STUB4:$PATH" bash "$ROOT/setup/exakit" migrate docker-nano --password-file "$H1/credentials/nano_sys_password" --json --yes 2>/dev/null; echo "RC=$?")"
has "the remembered container is the default" '"container": "remembered-db"' "$_o"
has "...and the remembered port"           '"dsn": "127.0.0.1:9999"' "$_o"
# Never a password on argv, on either side; the prompt reads without echo.
lacks "the sh CLI has no --password option that works" '--password)' "$(sed -n '/^cmd_migrate()/,/^}/p' "$ROOT/setup/exakit" | grep -v 'password-file' | grep -v 'reject')"
has "the sh prompt does not echo"          'read -rs' "$(cat "$ROOT/setup/exakit")"
has "the ps prompt does not echo"          'Read-Host -AsSecureString' "$(cat "$ROOT/setup/exakit.ps1")"

echo
echo "a crossing that could not ask is not a crossing that was answered:"

# A CONDITION IS NOT A DECISION. One run could not see the container engine,
# wrote the crossing off as finished ("no offer made"), and every later run -
# with the engine right there - returned at that gate: the question was never
# asked again, and the container went on holding port 8563, so the install died
# at the database step every single time with no way forward but a docker stop
# by hand. Seen on a real Windows machine, twice in a row.
CROSS_SRC="$(cat "$ROOT/setup/lib/legacy-crossing.sh")"
CROSS_PS="$(cat "$ROOT/setup/lib/legacy-crossing.ps1")"

# The four environmental reasons are retryable; the three intrinsic ones are not.
for _why in \
    'the container engine this database needs is not on this machine any more' \
    'exapump is not installed yet, and it is what reads the tables out' \
    'the old container would not start' \
    'the old database did not answer in time'; do
    _line="$(printf '%s\n' "$CROSS_SRC" | grep -F "$_why" | head -1)"
    has "retryable: $(printf '%s' "$_why" | cut -c1-34)" "_lcb_retry=1" "$_line"
done
has "retryable: the password is not on file" "_lcb_retry=1" \
    "$(printf '%s\n' "$CROSS_SRC" | grep -F 'the password for the old database is not on file' | head -1)"
for _why in \
    'the container is gone, so there is nothing left to copy' \
    'the old database has no tables in it' \
    'unchanged, which this install loads itself'; do
    _line="$(printf '%s\n' "$CROSS_SRC" | grep -F "$_why" | head -1)"
    lacks "settled: $(printf '%s' "$_why" | cut -c1-34)" "_lcb_retry=1" "$_line"
done

# The retryable branch records nothing as chosen and does not close the
# crossing, so the next run asks what this one could not.
_retry_branch="$(printf '%s\n' "$CROSS_SRC" | sed -n '/if \[ "\$_lcb_retry" = 1 \]; then/,/fi/p')"
has   "a blocked offer records why"            'manifest_set legacy.offer_blocked' "$_retry_branch"
lacks "...and never records a choice"          'legacy.choice' "$_retry_branch"
lacks "...and never closes the crossing"       'crossing_done' "$_retry_branch"
# ...and either way the container stops, because it holds the port.
_decline="$(printf '%s\n' "$CROSS_SRC" | sed -n '/legacy crossing: no offer made/,/^    fi$/p')"
has "a declined offer still frees the port"    'legacy_stop_container' "$_decline"
# The done-gate frees it too: that is the run that used to die at step 2.
_done_gate="$(printf '%s\n' "$CROSS_SRC" | sed -n '/crossing_done 2>\/dev\/null || true)" = "true" \]; then/,/^    fi$/p')"
has "a crossing already done still frees the port" 'legacy_stop_container' "$_done_gate"

# And the PowerShell twin says all of it the same way.
# ASSIGNED FIRST, NOT INLINED INTO THE has - and that is not style. In
# argument position bash 3.2 (which is /bin/bash on macOS, and what the macOS
# runner uses) BRACE-EXPANDS the text of a command substitution: the `{` ... `,`
# ... `}` of a sed range reads as a brace list, so `/...{/,/^    }$/p` reaches
# sed as two scripts with the braces gone -
#     sed: 1: "/legacy.crossing_done") /$/p": invalid command code $
#     sed: 1: "/legacy.crossing_done") /^    $/p": invalid command code ^
# - both of which fail, the substitution is empty, and the assertion reports
# MISSING about a line that is right there in the file. Bash 5 (every Linux
# runner) parses it correctly, so this failed on macOS alone. An assignment is
# not brace-expanded, which is why every neighbouring extraction above works.
# tests/bash32-guard.sh keeps it that way.
_ps_done_gate="$(printf '%s\n' "$CROSS_PS" | sed -n '/legacy.crossing_done") -eq "True") {/,/^    }$/p')"
has "ps: the done-gate frees the port too"   'Stop-LegacyContainer -Quiet' "$_ps_done_gate"
has "ps: a blocked offer records why"        'legacy.offer_blocked' "$CROSS_PS"
has "ps: the engine reason is retryable"     '$retry = $true' \
    "$(printf '%s
' "$CROSS_PS" | grep -F 'retry = $true; $why = "the container engine' | head -1)"
lacks "ps: a gone container is settled"      '$retry = $true' \
    "$(printf '%s\n' "$CROSS_PS" | grep -F 'nothing left to copy' | head -1)"

echo
echo "the engine is the one that actually holds the container, not just the one recorded:"

# THE RECORDED NAME IS A HINT, NOT THE ANSWER. The old kit ran the container
# under Docker when it was there and Podman otherwise, and wrote whichever it
# used into runtime.engine. A record written without that key, or a user who
# has since moved from one engine to the other, had the whole crossing declined
# - "the container engine this database needs is not on this machine any more"
# - with the container sitting in the other engine, and the install then walked
# straight into the port it holds. Seen on a real Windows machine: Docker
# Desktop running the container, runtime.engine absent from the record.
ENGWORK="$WORK/engines"
mkdir -p "$ENGWORK/bin"
# Two stub engines. Only the one named in HOLDER admits to having the
# container; every call is recorded, so the probe ORDER can be asserted too.
for _eng in docker podman; do
    cat > "$ENGWORK/bin/$_eng" <<STUBEOF
#!/bin/sh
printf '%s %s\n' "$_eng" "\$*" >> "$ENGWORK/calls"
case "\$1 \$2" in
  "container inspect")
      case "\${HOLDER:-}" in
          "$_eng"|both) printf 'deadbeef\n'; exit 0 ;;
      esac
      exit 1 ;;
esac
exit 0
STUBEOF
    chmod +x "$ENGWORK/bin/$_eng"
done

_eng_seq=0
eng_probe() { # eng_probe <recorded-engine> <holder> <expression>
    _eng_seq=$((_eng_seq + 1))
    _ep_home="$ENGWORK/home-$_eng_seq"
    seed_home "$_ep_home"
    # Rewrite the recorded engine to the case under test; an empty first
    # argument removes the key altogether, which is the older-record case.
    if [ -n "$1" ]; then
        sed 's/"engine": "fakeengine"/"engine": "'"$1"'"/' "$_ep_home/manifest.json" > "$_ep_home/m.tmp"
    else
        grep -v '"engine":' "$_ep_home/manifest.json" > "$_ep_home/m.tmp"
    fi
    mv "$_ep_home/m.tmp" "$_ep_home/manifest.json"
    : > "$ENGWORK/calls"
    # THE STUBS ARE PREPENDED, NOT SUBSTITUTED FOR THE PATH. Cutting it down to
    # /usr/bin:/bin also cut out uv and any python3 but /usr/bin/python3 - and
    # on a Mac that one is an Xcode shim that does not run (no Command Line
    # Tools, or a licence not yet agreed). manifest_get then answered with an
    # xcrun error instead of a value, every lookup in here came back empty, and
    # seven checks failed on a developer machine over something this suite is
    # not about. The stub directory is first, so docker and podman still
    # resolve to the stubs, which is the only substitution intended.
    EXAKIT_HOME="$_ep_home" EXAKIT_BIN_DIR="$_ep_home/bin" HOLDER="$2" \
    PATH="$ENGWORK/bin:$PATH" ROOT="$ROOT" \
    bash -c '
        . "$ROOT/setup/lib/common.sh"
        . "$ROOT/setup/lib/detect.sh"
        . "$ROOT/setup/lib/exapump.sh"
        . "$ROOT/setup/lib/legacy-crossing.sh"
        '"$3"' ' 2>&1
}

check "no engine recorded, docker holds it"  "docker" "$(eng_probe "" docker 'legacy_engine_name')"
check "no engine recorded, podman holds it"  "podman" "$(eng_probe "" podman 'legacy_engine_name')"
check "no engine recorded, neither holds it" ""       "$(eng_probe "" none 'legacy_engine_name')"
check "...and the path is empty too"         ""       "$(eng_probe "" none 'legacy_engine')"
# A recorded engine that IS on PATH is used as it always was - and nothing else
# is probed, because a working record must not cost two more process starts.
check "a recorded engine on PATH is used"    "podman" "$(eng_probe podman docker 'legacy_engine_name')"
eng_probe podman docker 'legacy_engine >/dev/null' >/dev/null
lacks "...without probing the other one"     "container inspect" "$(cat "$ENGWORK/calls" 2>/dev/null)"
# A recorded engine that is GONE falls back to the one that has the container.
check "a recorded engine that is gone falls back" "docker" "$(eng_probe uninstalled-engine docker 'legacy_engine_name')"
check "...and reports its real path"  "$ENGWORK/bin/docker" "$(eng_probe uninstalled-engine docker 'legacy_engine')"
# Docker before Podman, the order the old kit preferred: with both holding it,
# docker answers and podman is never asked.
check "docker is asked before podman"        "docker" "$(eng_probe "" both 'legacy_engine_name')"
# An explicit override always wins, even over a container it cannot see.
check "EXAKIT_LEGACY_ENGINE overrides everything" "podman" \
    "$(EXAKIT_LEGACY_ENGINE=podman eng_probe "" docker 'legacy_engine_name')"
# And the container's state reads through whatever was resolved.
check "the state reads through the resolved engine" "unknown" \
    "$(eng_probe "" docker 'legacy_container_state')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
