#!/usr/bin/env bash
# legacy-crossing-resilience.sh — the crossing from a container database onto
# Exasol Personal, under every fault the road can throw at it.
#
#   bash tests/legacy-crossing-resilience.sh
#
# tests/legacy-crossing.sh pins WHAT the crossing decides. This suite pins what
# it does when the things it depends on misbehave: an engine that hangs,
# refuses, or loses the container between two calls; a database that has no
# password on file, never answers, answers late, or has nothing in it; a copy
# that fails for some tables, or all of them, or cannot even make its
# directory; a restore that finds files missing, tables taken, uploads
# refused; a run that dies between the two halves and comes back. In every one
# of those the install must go on, nothing of the user's may be destroyed, the
# question must be asked at most once, and the manifest must tell the truth.
#
# Both stubs are fault-injection programs in tests/lib/, driven by plain files
# in a per-scenario control directory - one engine, one exapump, no per-test
# rewrites. The engine is named `fakeengine`, which exists nowhere but the
# sandbox; exapump is reached through EXAKIT_EXAPUMP_BIN AND PATH, so no fix in
# the kit is the only thing between this suite and a real database.
#
# Every run is traced, and the suite ends by measuring how much of
# setup/lib/legacy-crossing.sh it walked. The floor is a gate, not a note.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/line-coverage.sh"

PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s = %s\n' "$1" "$3"
    else FAIL=$((FAIL+1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; fi
}
has()   { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;;  *) check "$1" absent absent ;;   esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/exakit-legacy-res.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TRACE="$WORK/trace"; : > "$TRACE"
SCREENS="$WORK/screens"; : > "$SCREENS"

# The developer's real exapump config must come out of this untouched. Its
# hash is taken now and compared at the end; every run below points the kit at
# a config directory inside the sandbox.
REAL_EXAPUMP_CONFIG="$HOME/.exapump/config.toml"
_hash() { [ -f "$1" ] && cksum < "$1" || printf 'absent'; }
REAL_CONFIG_BEFORE="$(_hash "$REAL_EXAPUMP_CONFIG")"

# --- the two stubs ------------------------------------------------------------
# Two directories, so a scenario can take exapump off PATH and keep the engine.
STUB="$WORK/stub"; mkdir -p "$STUB/engine" "$STUB/exapump"
cp "$ROOT/tests/lib/legacy-fault-engine.sh"  "$STUB/engine/fakeengine"
cp "$ROOT/tests/lib/legacy-fault-exapump.sh" "$STUB/exapump/exapump"
chmod +x "$STUB/engine/fakeengine" "$STUB/exapump/exapump"

PASSWORD="legacysecret-Zq7"

# seed <dir> — a kit home holding what an OLDER kit recorded. Knobs are
# environment variables so a scenario reads as a sentence:
#   SEED_TYPE=personal        the runtime the record names        (nano)
#   SEED_NO_PASSWORD=1        no password file at all
#   SEED_EMPTY_PASSWORD=1     a password file with nothing in it
#   SEED_NO_DSN=1             no runtime.dsn
#   SEED_NO_CONTAINER=1       no runtime.container
#   SEED_NO_VOLUME=1          no runtime.volume
#   SEED_ENGINE=<name>        the recorded engine                 (fakeengine)
seed() {
    _s="$1"; mkdir -p "$_s/credentials" "$_s/ctrl" "$_s/bin" "$_s/exapump"
    _pw="$_s/credentials/nano_sys_password"
    if [ "${SEED_NO_PASSWORD:-0}" != 1 ]; then
        if [ "${SEED_EMPTY_PASSWORD:-0}" = 1 ]; then : > "$_pw"; else printf '%s\n' "$PASSWORD" > "$_pw"; fi
        chmod 600 "$_pw"
    fi
    _rt='"type": "'"${SEED_TYPE:-nano}"'", "engine": "'"${SEED_ENGINE:-fakeengine}"'", "user": "sys", "status": "healthy", "image": "docker.io/exasol/nano:2026.2.0-nano.2"'
    [ "${SEED_NO_CONTAINER:-0}" = 1 ] || _rt="$_rt"', "container": "exasol-nano"'
    [ "${SEED_NO_VOLUME:-0}" = 1 ]    || _rt="$_rt"', "volume": "exasol-nano-data"'
    [ "${SEED_NO_DSN:-0}" = 1 ]       || _rt="$_rt"', "dsn": "127.0.0.1:8563"'
    _rt="$_rt"', "password_file": "'"$_pw"'"'
    printf '{"manifest_version": 1, "kit_level": 1,\n "kit": {"version": "0.1.0", "source": "exasol-labs/exasol-personal-local-starterkit@0.1.0"},\n "runtime": {%s},\n "steps_completed": ["runtime"]}\n' "$_rt" > "$_s/manifest.json"
    # A healthy old database unless a scenario says otherwise: three tables in
    # two schemas, with column types the DDL builder has to carry across.
    printf 'S1.T1\nS1.T2\nS2.T3\n' > "$_s/ctrl/db.tables"
    printf 'S1.T1|ID<<:>>DECIMAL(18,0)\nS1.T1|NAME<<:>>VARCHAR(25) UTF8\nS1.T2|WHEN_TS<<:>>TIMESTAMP WITH LOCAL TIME ZONE\nS2.T3|my col<<:>>DOUBLE\n' > "$_s/ctrl/db.columns"
}
fault() { printf '%s' "$3" > "$1/ctrl/$2"; }        # fault <home> <file> <value>

# A PATH with no exapump on it, for the one scenario that takes the stub away:
# the developer's real binary must not step in and read a real database.
PATH_WITHOUT_EXAPUMP="$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r _d; do
    [ -n "$_d" ] && [ ! -x "$_d/exapump" ] && printf '%s:' "$_d"; done | sed 's/:$//')"

# run <home> <env> <body> — the module against <home>, with <env> (a string of
# VAR=value words) in force and <body> as the statements. The scenario's
# variables come LAST so they outrank the defaults. Traced through the coverage
# helper; the stamps go to $TRACE, the rest to stdout and to $SCREENS for the
# aggregate invariants at the end. stdin is /dev/null so "is this a terminal?"
# always has the same answer.
# Two knobs a scenario sets in its own environment rather than in <env>, because
# their values are paths and <env> is split on spaces: PROBE_TIMEOUT (the
# engine probe budget, default 2) and NO_EXAPUMP=1 (no exapump reachable by
# any route - not the stub, not the developer's real one).
RAW_TRACE="$WORK/trace.raw"; : > "$RAW_TRACE"
run() {
    _r_home="$1"; _r_env="$2"; _r_body="$3"
    : > "$_r_home/out"
    _r_path="$STUB/engine:$STUB/exapump:$PATH"; _r_exapump="$STUB/exapump/exapump"
    if [ "${NO_EXAPUMP:-0}" = 1 ]; then _r_path="$STUB/engine:$PATH_WITHOUT_EXAPUMP"; _r_exapump="$_r_home/no-such-exapump"; fi
    # shellcheck disable=SC2086
    env -u EXAKIT_LEGACY_DATA \
        EXAKIT_HOME="$_r_home" EXAKIT_BIN_DIR="$_r_home/bin" \
        EXAKIT_EXAPUMP_BIN="$_r_exapump" EXAKIT_EXAPUMP_CONFIG_DIR="$_r_home/exapump" \
        EXAKIT_LEGACY_EXPORT_DIR="$_r_home/migration" EXAKIT_FAULT_DIR="$_r_home/ctrl" \
        EXAKIT_ENGINE_PROBE_TIMEOUT="${PROBE_TIMEOUT:-2}" EXAKIT_NO_FANCY=1 \
        PATH="$_r_path" ROOT="$ROOT" $_r_env \
        bash -c "$(coverage_prelude "$RAW_TRACE")"'
            . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"; . "$ROOT/setup/lib/exapump.sh"
            set -x
            . "$ROOT/setup/lib/legacy-crossing.sh"
            '"$_r_body" </dev/null > "$_r_home/out" 2> "$_r_home/err"
    # stdout is the screen. stderr holds the kit's warn/error lines AND, on a
    # bash without BASH_XTRACEFD, the trace - and xtrace prints a multi-line
    # argument across several lines with the stamp on the FIRST only, so the
    # rest cannot be told from output by the stamp. The kit's stderr lines have
    # a shape of their own ("      ! ...", "      [x] ..."); only those are kept.
    {
        cat "$_r_home/out"
        coverage_collect "$_r_home/err" "$RAW_TRACE" "$TRACE" | grep -E '^ *(!|\[x\]) ' || true
    } | tee -a "$SCREENS"
}
before() { run "$1" "${2:-}" 'legacy_crossing_before; echo "RC=$?"'; }    # the first half, with its exit code
after()  { run "$1" "${2:-}" 'legacy_crossing_after; echo "RC=$?"'; }     # the second half
# flat <output> - one line, single-spaced. The banner is a sentence and the UI
# wraps it to the terminal width, so a phrase asserted whole can fall across the
# fold; this is what the reader sees, with the fold taken out.
flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }

rc_of()  { printf '%s\n' "$1" | sed -n 's/^RC=\([0-9]*\)$/\1/p' | tail -1; }
quiet()  { printf '%s\n' "$1" | grep -v '^RC=' | tr -d '[:space:]'; }     # everything but the exit code
# mget <home> <dotted.key> — the record, printed as manifest_get prints it
# (true/false for booleans, nothing when absent) but without sourcing ten
# thousand lines of common.sh for each of the dozens of reads below.
mget() {
    python3 - "$1/manifest.json" "$2" <<'MGET_PY'
import json, sys
try:
    node = json.load(open(sys.argv[1]))
    for part in sys.argv[2].split("."):
        node = node[part]
except Exception:
    sys.exit(0)
print("true" if node is True else "false" if node is False else node)
MGET_PY
}
calls()  { cat "$1/ctrl/$2.calls" 2>/dev/null; }
verbs()  { calls "$1" engine | awk '{ print $1 }' | tr '\n' ' ' | sed 's/ $//'; }
BEFORE_RCS=""     # every crossing_before exit code, for the invariant at the end
note_rc() { BEFORE_RCS="$BEFORE_RCS $(rc_of "$1")"; }

# =============================================================================
echo "the engine misbehaves:"

# A hanging engine cannot hold the install hostage. Each bounded probe gives up
# at EXAKIT_ENGINE_PROBE_TIMEOUT; the whole crossing has to be over well before
# the container would have answered.
#
# The stub hangs as ONE process (exec sleep), which is the shape of a wedged
# engine CLI and the shape the kit's bounded runner can end. A hang in a CHILD
# of the engine is a different matter: on a machine without timeout(1) the
# runner's group kill has no group to hit in a non-interactive shell, the
# grandchild keeps the capture pipe open, and the crossing waits out the whole
# hang. That is a limit of exakit_run_bounded, noted here rather than hidden.
#
# The budget is 2, not 1. Without timeout(1) the kit's bounded runner polls the
# child once a second and never again after its last sleep, so a limit of 1
# reads EVERY probe as timed out - including the `version` call the engine
# answers at once, which is what tells a hung inspect from a stopped engine.
# At 2 that call gets its second look; each hung inspect still ends in 3s.
H="$WORK/hang"; seed "$H"; fault "$H" engine.state hang; fault "$H" engine.hang_seconds 60
_t0=$(date +%s); _o="$(PROBE_TIMEOUT=2 before "$H")"; _dt=$(( $(date +%s) - _t0 )); note_rc "$_o"
check "a hanging engine does not block the install" "0" "$(rc_of "$_o")"
check "...and it gives up promptly, not after the hang" "yes" "$([ "$_dt" -lt 30 ] && echo yes || echo "no: ${_dt}s")"
check "...saying nothing on screen" "" "$(quiet "$_o")"
check "...and settling the question for good" "true" "$(mget "$H" legacy.crossing_done)"

# A stopped container that will not start: there is data in there, and no way
# to read it TODAY. A container that refuses to start this morning starts this
# afternoon, so this is a condition, not a decision - nothing is recorded as
# chosen and the crossing stays open for the next run. The engine is still
# asked exactly once.
H="$WORK/nostart"; seed "$H"; fault "$H" engine.state stopped; fault "$H" engine.start_rc 1
_o="$(before "$H")"; note_rc "$_o"
check "a container that will not start is not an error" "0" "$(rc_of "$_o")"
check "...nothing reaches the screen" "" "$(quiet "$_o")"
check "...no choice is recorded for the user" "" "$(mget "$H" legacy.choice)"
check "...the crossing stays open" "" "$(mget "$H" legacy.crossing_done)"
has   "...and the reason is kept" "would not start" "$(mget "$H" legacy.offer_blocked)"
check "start was attempted once" "1" "$(calls "$H" engine | grep -c '^start ')"
lacks "and no export was tried" "export" "$(calls "$H" exapump)"

# The engine refuses to STOP on the skip path. The port may stay busy, and the
# crossing says so - but it still records itself done and lets the install
# continue to its own port check.
H="$WORK/nostop"; seed "$H"; fault "$H" engine.stop_rc 1
_o="$(before "$H" EXAKIT_LEGACY_DATA=skip)"; note_rc "$_o"
check "a stop that fails does not fail the crossing" "0" "$(rc_of "$_o")"
has "...it warns the port may still be held" "may find its port busy" "$_o"
# The first half settles nothing: it copies and stops, and the question is
# the second half's. A stop that failed changes neither.
check "...and the question is still the second half's" "" "$(mget "$H" legacy.crossing_done)"
check "...with the container NOT recorded as stopped" "" "$(mget "$H" legacy.container_stopped)"

# The same refusal on the MIGRATE path: the copy is already safe on disk, so
# the warning is the only consequence.
H="$WORK/nostop-migrate"; seed "$H"; fault "$H" engine.stop_rc 1
_o="$(before "$H")"; note_rc "$_o"
check "the copy lands even so" "3" "$(mget "$H" legacy.exported)"
has "...and the stop failure is named" "may find its port busy" "$_o"
check "...with the export still recorded" "3" "$(mget "$H" legacy.exported)"

# The recorded engine is not on this machine any more (Docker uninstalled,
# Podman never installed). Gate 3 names the reason in the log and closes.
H="$WORK/noengine"; SEED_ENGINE=no-such-engine seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "a recorded engine that is gone closes the gate" "0" "$(rc_of "$_o")"
check "...silently" "" "$(quiet "$_o")"
check "...and the state it reports is unknown, not absent" "unknown" "$(run "$H" "" 'legacy_container_state')"
check "the engine is never asked for" "" "$(calls "$H" engine)"

# No container name recorded at all: an older kit that died before writing it.
H="$WORK/noname"; SEED_NO_CONTAINER=1 seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "a record with no container name reads as absent" "absent" "$(run "$H" "" 'legacy_container_state')"
check "...and closes silently" "" "$(quiet "$_o")"
check "...the removal command has nothing to name and says so" "1" \
    "$(run "$H" "" 'legacy_remove_command >/dev/null; echo $?' | tail -1)"

# An engine whose answer cannot be parsed. "unknown" is not "gone" - and it is
# not "readable" either. Nothing is copied from a container whose state the
# engine will not state, nothing is recorded as chosen, and the crossing stays
# open with the reason kept, so a later run with a talking engine (or `exakit
# migrate docker-nano`) can still make the offer. Reading "unknown" as a
# condition and not a decision is what keeps a stopped Docker Desktop from
# withdrawing the offer for good.
H="$WORK/unknown"; seed "$H"; fault "$H" engine.state unknown
_o="$(before "$H" EXAKIT_LEGACY_DATA=skip)"; note_rc "$_o"
check "an unparseable state is not an error" "0" "$(rc_of "$_o")"
check "...nothing reaches the screen" "" "$(quiet "$_o")"
check "...nothing is copied on its strength" "" "$(mget "$H" legacy.exported)"
check "...no choice is recorded for the user" "" "$(mget "$H" legacy.choice)"
check "...the crossing stays open" "" "$(mget "$H" legacy.crossing_done)"
has   "...and the reason is kept" "is not answering" "$(mget "$H" legacy.offer_blocked)"
lacks "...no export was tried" "export" "$(calls "$H" exapump)"
# With nothing copied, the second half has nothing to offer and nothing to restore.
_o2="$(after "$H" EXAKIT_LEGACY_DATA=skip)"
check "...and the second half has nothing to say" "" "$(quiet "$_o2")"

# An engine that refuses `inspect -f` but answers a plain `inspect` (too old
# for the template flag): the container exists, its state cannot be read, and
# that is "unknown" - never "absent", which would forfeit the offer.
H="$WORK/noformat"; seed "$H"; fault "$H" engine.state noformat
check "an engine without the template flag reads as unknown" "unknown" "$(run "$H" "" 'legacy_container_state')"

# The volume name is missing from the record: the removal command still names
# the container, and only the container.
H="$WORK/novolume"; SEED_NO_VOLUME=1 seed "$H"
_rm="$(run "$H" "" 'legacy_remove_command')"
has "without a recorded volume the command still removes the container" "rm -f exasol-nano" "$_rm"
lacks "...and invents no volume" "volume rm" "$_rm"
check "with one, it removes both, container first" "fakeengine rm -f exasol-nano && fakeengine volume rm exasol-nano-data" \
    "$(run "$WORK/unknown" "" 'legacy_remove_command')"

# =============================================================================
echo
echo "the old database misbehaves:"

# No password on file - the honest case for a deployment the old kit adopted
# rather than created. Nothing can be read, so nothing is offered.
H="$WORK/nopw"; SEED_NO_PASSWORD=1 seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "no password file: silent skip" "" "$(quiet "$_o")"
# A password that is not on file today can be put there tomorrow, so the
# question is left open rather than answered on the user's behalf.
check "...the crossing stays open" "" "$(mget "$H" legacy.crossing_done)"
has   "...with the reason kept" "not on file" "$(mget "$H" legacy.offer_blocked)"
lacks "...and the database was never queried" "EXAKIT_LEGACY_OK" "$(calls "$H" exapump)"
check "...and the container is still stopped, because it holds the port" "1" "$(calls "$H" engine | grep -c '^stop ')"

# An EMPTY password file is the same as none: -s, not -f.
H="$WORK/emptypw"; SEED_EMPTY_PASSWORD=1 seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "an empty password file is treated as missing" "" "$(quiet "$_o")"
check "...profile writer refuses it" "1" "$(run "$H" "" 'legacy_write_profile; echo $?' | tail -1)"

# No DSN recorded: the profile cannot be written either.
H="$WORK/nodsn"; SEED_NO_DSN=1 seed "$H"
check "no dsn: the profile writer refuses" "1" "$(run "$H" "" 'legacy_write_profile; echo $?' | tail -1)"
_o="$(before "$H")"; note_rc "$_o"
check "...and the crossing closes silently" "" "$(quiet "$_o")"

# A running container whose database never answers. The wait is capped at ten
# seconds for a container that was ALREADY running - it should have answered
# on the first ask - and then the gate closes.
H="$WORK/silent-running"; seed "$H"; fault "$H" db.answer_after never
_t0=$(date +%s); _o="$(before "$H")"; _dt=$(( $(date +%s) - _t0 )); note_rc "$_o"
check "a database that never answers closes the gate" "" "$(quiet "$_o")"
check "...within the short budget for an already-running container" "yes" "$([ "$_dt" -lt 25 ] && echo yes || echo "no: ${_dt}s")"
check "...the probe was retried, not asked once" "yes" "$([ "$(calls "$H" exapump | grep -c EXAKIT_LEGACY_OK)" -ge 2 ] && echo yes || echo no)"

# A STOPPED container the crossing started itself gets the long budget - and
# EXAKIT_LEGACY_READY_TIMEOUT is that budget, so a scenario can make it short.
H="$WORK/silent-started"; seed "$H"; fault "$H" engine.state stopped; fault "$H" db.answer_after never
_t0=$(date +%s); _o="$(before "$H" EXAKIT_LEGACY_READY_TIMEOUT=5)"; _dt=$(( $(date +%s) - _t0 )); note_rc "$_o"
check "a started container that never answers closes the gate" "" "$(quiet "$_o")"
check "...within the configured budget" "yes" "$([ "$_dt" -lt 15 ] && echo yes || echo "no: ${_dt}s")"
check "...and the container was started for the attempt" "1" "$(calls "$H" engine | grep -c '^start ')"
check "...then stopped again, holding nothing" "1" "$(calls "$H" engine | grep -c '^stop ')"

# SELF-HEALING WAIT: a database that is slow to come up answers on the second
# ask, and the crossing proceeds as if it had answered on the first.
H="$WORK/late"; seed "$H"; fault "$H" db.answer_after 2
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
check "a database that answers late is still copied" "3" "$(mget "$H" legacy.exported)"
check "...all three tables" "3" "$(mget "$H" legacy.exported)"

# A database with nothing in it. Nothing to offer; nothing said.
H="$WORK/empty"; seed "$H"; : > "$H/ctrl/db.tables"
_o="$(before "$H")"; note_rc "$_o"
check "an empty database is not worth a question" "" "$(quiet "$_o")"
check "...but is marked done" "true" "$(mget "$H" legacy.crossing_done)"
check "...and stopped, for the port" "1" "$(calls "$H" engine | grep -c '^stop ')"

# exapump is not there to read the tables out. The gate closes before the
# database is touched at all - but exapump arrives two steps later in this very
# install, so the question is left open for the next run rather than answered
# on the user's behalf.
H="$WORK/noexapump"; seed "$H"
_o="$(NO_EXAPUMP=1 before "$H")"; note_rc "$_o"
check "no exapump: silent skip" "" "$(quiet "$_o")"
check "...the crossing stays open" "" "$(mget "$H" legacy.crossing_done)"
has   "...with the reason kept" "exapump is not installed yet" "$(mget "$H" legacy.offer_blocked)"
check "...no query was attempted" "" "$(calls "$H" exapump)"

# =============================================================================
echo
echo "copying out tolerates partial failure:"

# One of three tables refuses to export. The other two land, the failed one is
# named, its half-written file is removed, and the run goes on as a migration.
H="$WORK/partial"; seed "$H"; fault "$H" export.fail "S1.T2"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
has "a table that will not copy is named" "Could not copy S1.T2" "$_o"
check "...and the run still saves the rest" "$H/migration" "$(mget "$H" legacy.export_dir)"
check "two of three exported" "2" "$(mget "$H" legacy.exported)"
check "...one recorded as failed" "1" "$(mget "$H" legacy.export_failed)"
check "the failed table is not in the index" "0" "$(grep -c 'S1	T2' "$H/migration/index")"
check "...and its partial file is gone" "no" "$([ -e "$H/migration/t2.csv" ] && echo yes || echo no)"
check "the files that landed are the positional ones" "t1.csv t3.csv" "$(cd "$H/migration" && ls t*.csv | tr '\n' ' ' | sed 's/ $//')"
check "the answer is still the user's to give" "" "$(mget "$H" legacy.choice)"

# EVERY table refuses. Nothing is lost - the old database is untouched - and
# the crossing downgrades itself to skip, saying so, with no export_dir left
# behind for the second half to trip on.
H="$WORK/allfail"; seed "$H"; printf 'S1.T1\nS1.T2\nS2.T3\n' > "$H/ctrl/export.fail"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
# NOT A WORD ON SCREEN, AND NOT AN ANSWER EITHER. This is the first thing the
# install does; a copy that could not be made is a condition to record, not a
# decision to announce or to make for the user.
lacks "when nothing copies, nothing is announced" "Found your previous" "$_o"
has "...the reason is kept" "nothing could be copied out" "$(mget "$H" legacy.offer_blocked)"
check "...and no answer is invented" "" "$(mget "$H" legacy.choice)"
check "...no export_dir is recorded" "" "$(mget "$H" legacy.export_dir)"
check "...zero exported, three failed" "0/3" "$(mget "$H" legacy.exported)/$(mget "$H" legacy.export_failed)"
check "...and the crossing is not closed" "" "$(mget "$H" legacy.crossing_done)"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "the second half then has nothing to do" "" "$(quiet "$_o2")"

# The column catalogue has nothing for one table (a view, a table dropped
# between the listing and the copy). The index carries an EMPTY ddl for it and
# the restore falls back to letting upload infer the shape.
H="$WORK/noddl"; seed "$H"; printf 'S1.T1|ID<<:>>DECIMAL(18,0)\n' > "$H/ctrl/db.columns"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
check "a table with no column catalogue still exports" "3" "$(mget "$H" legacy.exported)"
check "...its index line ends in an empty ddl" "1" "$(awk -F'\t' '$3 == "T2" && $4 == ""' "$H/migration/index" | wc -l | tr -d ' ')"
check "...while the catalogued one carries its types" "1" "$(awk -F'\t' '$3 == "T1" && $4 ~ /DECIMAL\(18,0\)/' "$H/migration/index" | wc -l | tr -d ' ')"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "the restore then uploads it without a CREATE TABLE" "0" "$(calls "$H" exapump | grep -c 'CREATE TABLE "S1"."T2"')"
check "...and counts it restored" "3" "$(mget "$H" legacy.restored)"

# The export directory cannot be made (its parent is a FILE). The copy fails
# before any table, which is the "nothing could be copied" road.
H="$WORK/nodir"; seed "$H"; : > "$H/migration"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
check "an unwritable export directory is survived" "0" "$(rc_of "$_o")"
has "...with the reason kept" "nothing could be copied out" "$(mget "$H" legacy.offer_blocked)"
check "...with the install unblocked" "0" "$(rc_of "$_o")"

# The DDL builder on its own: types carried, identifiers quoted, a table with
# no catalogue refused rather than emitted as an empty CREATE.
H="$WORK/ddl"; seed "$H"; run "$H" "" 'legacy_write_profile' >/dev/null
check "the DDL carries the source types, quoted" 'CREATE TABLE "S1"."T1" ("ID" DECIMAL(18,0), "NAME" VARCHAR(25) UTF8)' \
    "$(run "$H" "" 'legacy_table_ddl S1 T1')"
has "a multi-word type survives the marker split" '"WHEN_TS" TIMESTAMP WITH LOCAL TIME ZONE' "$(run "$H" "" 'legacy_table_ddl S1 T2')"
check "a table with no catalogue yields no DDL" "1" "$(run "$H" "" 'legacy_table_ddl S9 NOPE; echo $?' | tail -1)"

# Identifiers Exasol allows and file systems do not: a dot inside the table
# name, a space in the schema. The split is on the FIRST dot; the files are
# positional; the DDL quotes both halves.
H="$WORK/odd"; seed "$H"; printf 'My Schema.T.with.dots\n' > "$H/ctrl/db.tables"
printf 'My Schema.T.with.dots|order<<:>>VARCHAR(10)\n' > "$H/ctrl/db.columns"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
# ONE table, not two: the name has a space in it, and the list of names used
# to be handed on unquoted with the default IFS, so "My Schema.T.with.dots"
# arrived as "My" and "Schema.T.with.dots".
check "a name with a space exports as ONE table" "1" "$(mget "$H" legacy.exported)"
check "...and nothing was reported failed" "" "$(mget "$H" legacy.export_failed)"
check "...to a positional file" "yes" "$([ -f "$H/migration/t1.csv" ] && echo yes || echo no)"
has "...with the schema split at the first dot" 'My Schema	T.with.dots' "$(cat "$H/migration/index")"
has "...and both halves quoted in the DDL" 'CREATE TABLE "My Schema"."T.with.dots" ("order" VARCHAR(10))' "$(cat "$H/migration/index")"

# =============================================================================
echo
echo "restoring tolerates partial failure and heals what it can:"

# A mixed restore: one lands, one was already created by the fresh install,
# one upload fails. Every count is recorded, every line of the summary is said,
# and the copy is KEPT because something did not land.
H="$WORK/mixed"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
fault "$H" import.exists "S1.T2"; fault "$H" upload.fail "S2.T3"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "one restored" "1" "$(mget "$H" legacy.restored)"
check "one left alone" "1" "$(mget "$H" legacy.restore_skipped)"
check "one failed" "1" "$(mget "$H" legacy.restore_failed)"
has "the summary counts the restored" "Restored 1 table(s)" "$_o2"
has "...names the one left alone" "Left alone (this install had already created them): S1.T2" "$_o2"
has "...and says the copies stay for the failure" "did not restore" "$_o2"
lacks "...so the copy is NOT declared expendable" "no longer needed" "$_o2"
# Matched on the quoted target, not on "T2": the sandbox lives under a random
# mktemp suffix, and one run drew a suffix containing T2 - every upload PATH
# then matched and a correct restore read as two illicit uploads.
check "no upload was issued for the table left alone" "0" "$(calls "$H" exapump | grep '^upload' | grep -c '"S1"."T2"')"
check "the failed table's file is kept" "yes" "$([ -f "$H/migration/t3.csv" ] && echo yes || echo no)"
check "the second half returns cleanly" "0" "$(rc_of "$_o2")"

# Everything lands: the copy is declared expendable and the old container is
# named as still holding the original.
H="$WORK/clean"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"; _o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
has "a clean restore says the copy can go" "no longer needed" "$_o2"
has "...and that the original is still in the container" "still holds the original" "$_o2"
has "...with the exact removal command" "rm -f exasol-nano && fakeengine volume rm exasol-nano-data" "$_o2"
check "every table restored" "3" "$(mget "$H" legacy.restored)"
check "...none skipped, none failed" "/" "$(mget "$H" legacy.restore_skipped)/$(mget "$H" legacy.restore_failed)"

# The second half is IDEMPOTENT: a re-run after a completed restore does
# nothing - not one more upload - because the record says it is done.
_uploads_before="$(calls "$H" exapump | grep -c '^upload')"
_o3="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "a second run of the restore is silent" "" "$(quiet "$_o3")"
check "...and issues no further uploads" "$_uploads_before" "$(calls "$H" exapump | grep -c '^upload')"

# A file the index names has gone missing between the halves. That row is
# skipped without a word and without a count: it is neither restored nor
# failed, and the others are unaffected.
H="$WORK/gonefile"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
rm -f "$H/migration/t2.csv"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "a missing file is skipped, the rest restored" "2" "$(mget "$H" legacy.restored)"
check "...and not counted as a failure" "" "$(mget "$H" legacy.restore_failed)"
check "...no upload was attempted for it" "0" "$(calls "$H" exapump | grep '^upload' | grep -c 't2.csv')"

# CREATE SCHEMA refuses (a permission the new user lacks, say). It is not the
# test for anything, so the restore carries on to the table.
H="$WORK/noschema"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
fault "$H" import.schema_rc 1
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "a failed CREATE SCHEMA does not stop the restore" "3" "$(mget "$H" legacy.restored)"

# The index has blank lines and a line with too few fields (a hand edit, a
# truncated write). Blank lines are skipped; a short line has no file and is
# skipped too; the well-formed rows restore.
H="$WORK/badindex"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
{ printf '\n\nnot-a-real-line\n'; cat "$H/migration/index"; printf '\n'; } > "$H/migration/index.new"
mv "$H/migration/index.new" "$H/migration/index"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "blank and malformed index lines are stepped over" "3" "$(mget "$H" legacy.restored)"
check "...with nothing counted as failed" "" "$(mget "$H" legacy.restore_failed)"

# An export_dir is recorded but the index is EMPTY (the copy died after
# creating it). The second half has nothing to restore and says nothing.
H="$WORK/emptyindex"; seed "$H"
run "$H" "" 'manifest_set legacy.export_dir "$EXAKIT_HOME/migration"' >/dev/null
mkdir -p "$H/migration"; : > "$H/migration/index"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "an empty index restores nothing, silently" "" "$(quiet "$_o2")"
check "...and returns cleanly" "0" "$(rc_of "$_o2")"

# The whole export directory is gone (the user deleted it). Same answer.
H="$WORK/gonedir"; seed "$H"
run "$H" "" 'manifest_set legacy.export_dir "$EXAKIT_HOME/migration"' >/dev/null
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "a deleted export directory is survived" "" "$(quiet "$_o2")"

# legacy_import on a directory with no index at all: the honest non-zero.
H="$WORK/noindex"; seed "$H"; mkdir -p "$H/migration"
check "the importer refuses a directory with no index" "1" "$(run "$H" "" 'legacy_import "$EXAKIT_HOME/migration"; echo $?' | tail -1)"
# ...and the second half turns that into a kept copy, not a crash.
run "$H" "" 'manifest_set legacy.export_dir "$EXAKIT_HOME/migration"' >/dev/null
printf 'x\n' > "$H/migration/index"; : > "$H/migration/x"      # an index with a row, no file
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "a restore that lands nothing keeps the copy" "0" "$(mget "$H" legacy.restored)"
check "...and returns cleanly" "0" "$(rc_of "$_o2")"

# =============================================================================
echo
echo "the two halves survive a crash between them:"

# The run died after the export was recorded but before the container was
# stopped or the crossing marked done. On resume the first half asks nothing,
# says nothing, stops the container it left running, and the second half
# restores what the first had saved.
H="$WORK/crash"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
# Roll the record back to "died after export": choice and export_dir stand,
# crossing_done does not, and the container is running again.
fault "$H" engine.state running
python3 - "$H/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d.get("legacy", {}).pop("crossing_done", None)
json.dump(d, open(p, "w"), indent=2)
PY
_stops_before="$(calls "$H" engine | grep -c '^stop ')"
_exports_before="$(calls "$H" exapump | grep -c '^export')"
_o2="$(before "$H")"; note_rc "$_o2"
check "the resumed first half stops the container and says that" "1"     "$(printf '%s
' "$_o2" | grep -c 'Stopping the old database container')"
check "...and still asks nothing itself" "" "$(mget "$H" legacy.choice)"
check "...copies nothing twice" "$_exports_before" "$(calls "$H" exapump | grep -c '^export')"
check "...but does stop the container it left running" "$(( _stops_before + 1 ))" "$(calls "$H" engine | grep -c '^stop ')"
_o3="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
has "and the second half restores the first half's copy" "Restored 3 table(s)" "$_o3"

# The run died AFTER crossing_done but before the deployment recorded itself
# as personal - the record still says nano. The question is not asked again and
# the database is never touched; the CONTAINER, though, still holds the port the
# new deployment needs, and leaving it alone there is what made every later
# install die at the database step with no way forward but a docker stop by
# hand. So: nothing on screen, no database call, and the port freed.
H="$WORK/done-still-nano"; seed "$H"
run "$H" "" 'manifest_set legacy.crossing_done true' >/dev/null
_o="$(before "$H")"; note_rc "$_o"
check "a crossing already done is never reconsidered" "" "$(quiet "$_o")"
check "...and no database call" "" "$(calls "$H" exapump)"
check "...but the port is freed anyway" "1" "$(calls "$H" engine | grep -c '^stop ')"
check "...and no question is asked" "" "$(mget "$H" legacy.offer_blocked)"

# The normal post-crossing state: the deployment recorded itself as personal.
# Gate 1 closes; the machine is simply a Personal install now.
H="$WORK/personal"; SEED_TYPE=personal seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "a Personal install passes straight through" "" "$(quiet "$_o")"
check "...touching neither stub" "/" "$(calls "$H" engine)/$(calls "$H" exapump)"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
check "...and so does the second half" "" "$(quiet "$_o2")"

# =============================================================================
echo
echo "the whole road, end to end:"

# MIGRATE, container running. Every record the two halves leave, and the exact
# sequence of verbs the engine saw.
H="$WORK/e2e-migrate"; seed "$H"
# THE FIRST HALF SAYS NOTHING AND ASKS NOTHING. It is the only moment the old
# container can be read - it holds the port the deployment is about to take -
# so the tables come out here, quietly, and the question waits for the half
# that runs after exapump.
_o="$(before "$H")"; note_rc "$_o"
check "the first half says one thing: why the container stopped" "1"     "$(printf '%s
' "$_o" | grep -c 'Stopping the old database container')"
lacks "...and nothing about a copy or a question" "Found your previous" "$_o"
check "...and records no answer on the user's behalf" "" "$(mget "$H" legacy.choice)"
check "...and does not close the crossing" "" "$(mget "$H" legacy.crossing_done)"
check "crossed_from" "nano" "$(mget "$H" legacy.crossed_from)"
check "export_dir" "$H/migration" "$(mget "$H" legacy.export_dir)"
check "exported" "3" "$(mget "$H" legacy.exported)"
check "container_stopped" "true" "$(mget "$H" legacy.container_stopped)"
check "the counts are kept for the question" "3" "$(mget "$H" legacy.tables_own)"
check "the engine saw inspect, then inspect, then stop - and nothing else" "container container stop" "$(verbs "$H")"
check "every export went through the LEGACY profile" "3" "$(calls "$H" exapump | grep '^export' | grep -c -- '-p starter-kit-legacy')"
# THE SECOND HALF ASKS, THEN RESTORES.
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
has "the banner names the container" "container 'exasol-nano'" "$_o2"
# ONE LINE, NOT SIX: the name, the state it is in by now, and how much of the
# user's own data is in there. What it no longer says - what the kit does not
# manage, what it deploys instead, what the copy costs - is in the docs.
has "...and how much of it is the user's own" "3 table(s) in 2 schema(s) of your own" "$(flat "$_o2")"
lacks "...without the paragraph that used to precede it" "runs in a container" "$_o2"
has "...and the state it is in when asked" "stopped for this install" "$_o2"
has "...and the one caveat CSV carries" "empty string arrives as NULL" "$_o2"
check "choice" "migrate" "$(mget "$H" legacy.choice)"
check "crossing_done" "true" "$(mget "$H" legacy.crossing_done)"
has "the second half restores" "Restored 3 table(s)" "$_o2"
check "every upload went through the KIT's profile" "3" "$(calls "$H" exapump | grep '^upload' | grep -c -- '-p starter-kit ')"
check "...into the new database, never the old" "0" "$(calls "$H" exapump | grep '^upload' | grep -c -- 'starter-kit-legacy')"
check "restored" "3" "$(mget "$H" legacy.restored)"
# A THIRD run - the next install of any kind - sees a machine that has crossed.
_o3="$(before "$H")"; note_rc "$_o3"
check "and a later install asks nothing again" "" "$(quiet "$_o3")"

# MIGRATE, container stopped: it is started for the copy and stopped after.
H="$WORK/e2e-stopped"; seed "$H"; fault "$H" engine.state stopped
_o="$(before "$H")"; note_rc "$_o"
check "a stopped container is copied too" "3" "$(mget "$H" legacy.exported)"
lacks "...saying nothing about it" "Found your previous" "$_o"
check "the engine saw a start before the stop" "yes" \
    "$(calls "$H" engine | awk '$1=="start"{s=NR} $1=="stop"{t=NR} END{ print (s && t && s < t) ? "yes" : "no" }')"

# SKIP: no copy, container stopped, removal command printed, nothing deleted.
H="$WORK/e2e-skip"; seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "the container was stopped" "1" "$(calls "$H" engine | grep -c '^stop ')"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=skip)"
has "skip leaves the old database alone, and says so" "left exactly as it was, stopped, with its data" "$_o2"
has "...with the command that removes it when wanted" "fakeengine rm -f exasol-nano && fakeengine volume rm exasol-nano-data" "$_o2"
check "and the crossing is done" "true" "$(mget "$H" legacy.crossing_done)"
check "nothing was restored" "" "$(mget "$H" legacy.restored)"
# A NO DELETES THE COPY: it was made without asking, so it does not outlive
# the answer. The old container still holds the original.
check "the copy is gone" "no" "$([ -f "$H/migration/index" ] && echo yes || echo no)"
check "...and the record no longer points at one" "" "$(mget "$H" legacy.export_dir)"
_o3="$(after "$H")"
check "a later run has nothing to restore" "" "$(quiet "$_o3")"

# =============================================================================
echo
echo "answers from the environment and from the keyboard:"

H="$WORK/answers"; seed "$H"
_choice() { # _choice <env> [can] [why] -> the choice; the narration is left on stdout and filtered, not redirected away
    run "$H" "$1" "legacy_choose 3 ${2:-yes} '${3:-}'; printf 'CHOICE=%s' \"\$EXAKIT_LEGACY_CHOICE\"" | sed -n 's/.*CHOICE=\([a-z]*\).*/\1/p' | tail -1
}
check "a copy that cannot be made is refused even when asked for" "skip" "$(_choice EXAKIT_LEGACY_DATA=migrate no 'no reason at all')"
has "...and the refusal names why" "no reason at all" "$(run "$H" EXAKIT_LEGACY_DATA=migrate "legacy_choose 3 no 'no reason at all'")"
check "no answer and no possible copy is skip" "skip" "$(_choice "" no 'the container is gone')"
has "...saying why" "the container is gone" "$(run "$H" "" "legacy_choose 3 no 'the container is gone'")"
check "EXAKIT_LEGACY_DATA=1 means migrate" "migrate" "$(_choice EXAKIT_LEGACY_DATA=1)"
check "EXAKIT_LEGACY_DATA=0 means skip"    "skip"    "$(_choice EXAKIT_LEGACY_DATA=0)"
# A value the kit does not know is not an answer. It falls through to the
# terminal question, and off a terminal that is the unattended skip.
check "a value the kit does not know is no answer" "skip" "$(_choice EXAKIT_LEGACY_DATA=maybe)"
has "...and the hint says how to answer" "EXAKIT_LEGACY_DATA=migrate" "$(run "$H" EXAKIT_LEGACY_DATA=maybe 'legacy_choose 3 yes ""')"

# THE KEYBOARD. The terminal check and the menu are stubbed in the run, so the
# mapping from the menu's answer to the choice is exercised for real: row 1 is
# migrate, row 2 is skip, and row 2 is the exclusive one.
# The terminal check and the menu are replaced by functions in a FILE that the
# run sources, not defined inline in the run's own script: a function defined
# in `bash -c` has no BASH_SOURCE, and on bash 3.2 calling one from inside the
# module wipes the module's own source attribution for the rest of the caller -
# the menu lines ran, and the trace stamped them as belonging to nowhere.
cat > "$H/ctrl/keyboard.sh" <<'KEYBOARD'
exakit_stdin_is_tty() { return 0; }
ui_checkbox_menu() {
    printf '%s\n' "$@" > "$EXAKIT_FAULT_DIR/menu.args"
    printf '%s' "$EXAKIT_CHECKBOX_EXCLUSIVE" > "$EXAKIT_FAULT_DIR/menu.exclusive"
    EXAKIT_CHECKBOX_SELECTION="$MENU_PICK"
}
KEYBOARD
_menu() { # _menu <pick> -> "CHOICE=<c> EXCLUSIVE=<n> LABEL=<count-in-labels>"
    run "$H" "MENU_PICK=$1" '
        . "$EXAKIT_FAULT_DIR/keyboard.sh"
        legacy_choose 7 yes ""
        printf "CHOICE=%s EXCLUSIVE=%s LABEL=%s" "$EXAKIT_LEGACY_CHOICE" "$(cat "$EXAKIT_FAULT_DIR/menu.exclusive")" "$(grep -c "7 table" "$EXAKIT_FAULT_DIR/menu.args")"' | grep '^CHOICE='
}
_m1="$(_menu 1)"; _m2="$(_menu 2)"
has "row 1 on the keyboard is migrate" "CHOICE=migrate" "$_m1"
has "row 2 on the keyboard is skip"    "CHOICE=skip"    "$_m2"
has "row 2 is the exclusive one"       "EXCLUSIVE=2"    "$_m1"
has "the labels carry the table count" "LABEL=1"        "$_m1"
# The menu's default is row 1, so an Enter with nothing changed is migrate.
has "an unchanged menu (empty selection) reads as migrate" "CHOICE=migrate" "$(_menu "")"

# =============================================================================
echo
echo "the CLI's view of a legacy install:"

H="$WORK/notice"; seed "$H"
_n="$(run "$H" "" 'exakit_legacy_runtime_notice')"
has "the notice explains the container" "runs in a container, which this kit no longer manages" "$_n"
has "...and names the crossing as the installer" "Re-run the installer to move across" "$_n"
has "...promising that nothing is deleted" "deletes nothing either way" "$_n"
H2="$WORK/notice-personal"; SEED_TYPE=personal seed "$H2"
check "and is silent on a Personal install" "" "$(run "$H2" "" 'exakit_legacy_runtime_notice' | tr -d '[:space:]')"
# The set of legacy runtime names is one variable, overridable, so a future
# record type can be taught to the kit without a code change here.
check "the legacy set is a variable" "yes" \
    "$(run "$H2" "EXAKIT_LEGACY_RUNTIME_TYPES=personal" 'exakit_legacy_runtime_recorded && echo yes || echo no' | tail -1)"

# =============================================================================
echo
echo "the kit's own sample data is left out of the copy:"

# TPCH.REGION with the row count the kit's own CSV has (5) is the bundled sample,
# unchanged, and is not the user's to copy. TPCH.NATION with one row fewer than
# the CSV (24 of 25) has been changed, so it IS the user's. S1.T1 is the user's.
# The catalog is read from the kit's real data/datasets, so the numbers are the
# kit's, not the suite's.
H="$WORK/sample"; seed "$H"
printf 'S1.T1\nTPCH.NATION\nTPCH.REGION\n' > "$H/ctrl/db.tables"
printf 'TPCH.NATION|24\nTPCH.REGION|5\n' > "$H/ctrl/db.rows"
_o="$(before "$H")"; note_rc "$_o"
_o="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
has "the banner counts the user's own tables" "2 table(s) in 2 schema(s) of your own" "$(flat "$_o")"
has "...and says the rest is the kit's"       "The other 1 is the kit's own tpch sample" "$(flat "$_o")"
# The caveat belongs to the copy, not to the question before it.
has "the caveat is said with the copy"        "an empty string arrives as NULL" "$_o"
check "only the user's tables are copied out"        "2" "$(calls "$H" exapump | grep -c '^export')"
# The export names its table as a quoted query, so that is what the log holds.
check "the unchanged sample table is not"            "0" "$(calls "$H" exapump | grep '^export' | grep -c '"TPCH"."REGION"')"
check "a sample table the user changed is"           "1" "$(calls "$H" exapump | grep '^export' | grep -c '"TPCH"."NATION"')"
check "the row counts were asked for once"           "1" "$(calls "$H" exapump | grep -c 'EXAKIT_LR')"
check "...for the sample schema only"                "1" "$(calls "$H" exapump | grep 'EXAKIT_LR' | grep -c "IN ('TPCH')")"
check "...through the legacy profile"                "1" "$(calls "$H" exapump | grep 'EXAKIT_LR' | grep -c -- '-p starter-kit-legacy')"
check "the record names the dataset left out"        "tpch" "$(mget "$H" legacy.sample_left_out)"
# The record the migrate command reads back later, kept before runtime.* is
# overwritten by the deployment step.
check "the crossing remembers the old database"      "exasol-nano/fakeengine/127.0.0.1:8563/sys" \
    "$(mget "$H" legacy.container)/$(mget "$H" legacy.engine)/$(mget "$H" legacy.dsn)/$(mget "$H" legacy.user)"
check "...and its volume and password file"          "exasol-nano-data/$H/credentials/nano_sys_password" \
    "$(mget "$H" legacy.volume)/$(mget "$H" legacy.password_file)"
# The old kit's "runtime" tick was the container. Kept, the deployment step
# was skipped as done and nothing recorded the new runtime (a real machine).
check "the old kit's step ticks are dropped"          "[]" "$(mget "$H" steps_completed | tr -d ' ')"

# Nothing but the sample: nothing of the user's, so nothing is asked - the same
# silence as an empty database, with the reason settled in the record.
H="$WORK/sample-only"; seed "$H"
printf 'TPCH.REGION\nTPCH.NATION\n' > "$H/ctrl/db.tables"
printf 'TPCH.REGION|5\nTPCH.NATION|25\n' > "$H/ctrl/db.rows"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
check "only the kit's sample data: nothing said"     "" "$(quiet "$_o")"
check "...settled as skip"                           "skip" "$(mget "$H" legacy.choice)"
check "...with the dataset named in the record"      "tpch" "$(mget "$H" legacy.sample_left_out)"
check "...nothing copied out"                        "0" "$(calls "$H" exapump | grep -c '^export')"
check "...and the container stopped for the port"    "1" "$(calls "$H" engine | grep -c '^stop ')"

# A row count the database cannot give (no line for the table) is not evidence
# the table is unchanged: it travels as the user's.
H="$WORK/sample-unknown"; seed "$H"
printf 'TPCH.REGION\n' > "$H/ctrl/db.tables"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
check "an unknown row count keeps the table in the copy" "1" "$(calls "$H" exapump | grep '^export' | grep -c '"TPCH"."REGION"')"
lacks "...and nothing is called the kit's"           "bundled sample data" "$_o"

# The skip road now names the later route.
H="$WORK/skip-later"; seed "$H"
_o="$(before "$H")"; note_rc "$_o"
_o="$(after "$H" EXAKIT_LEGACY_DATA=skip)"
has "skip names the command that copies it later" "exakit migrate docker-nano" "$_o"

# =============================================================================
echo
echo "after the install: exakit migrate docker-nano (legacy_migrate_now):"

# The Personal runtime is a stub too (tests/lib/legacy-fault-personal.sh),
# sourced from the control directory - a file, for the same BASH_SOURCE reason
# as the keyboard above. The confirmation is stubbed the same way where a
# scenario declines. Every scenario here is the state AFTER an install: the
# record says the runtime is Personal, and the old container is named through
# the EXAKIT_LEGACY_* variables the CLI would have set.
seed_mig() { # seed_mig <home>
    SEED_TYPE=personal seed "$1"
    cp "$ROOT/tests/lib/legacy-fault-personal.sh" "$1/ctrl/personal.sh"
    printf 'confirm() { return 1; }\n' > "$1/ctrl/decline.sh"
}
MIG_ENV="EXAKIT_LEGACY_CONTAINER=exasol-nano EXAKIT_LEGACY_ENGINE=fakeengine EXAKIT_LEGACY_DSN=127.0.0.1:8563 EXAKIT_LEGACY_VOLUME=exasol-nano-data"
migrate() { # migrate <home> [extra env] [pre-statements] [yes:0|1]
    run "$1" "$MIG_ENV ${2:-}" '. "$EXAKIT_FAULT_DIR/personal.sh"; '"${3:-}"'
        EXAKIT_LEGACY_PASSWORD_FILE="$EXAKIT_HOME/credentials/nano_sys_password"
        legacy_migrate_now '"${4:-1}"'; echo "RC=$?"; echo "STATUS=$EXAKIT_LEGACY_MIGRATE_STATUS"'
}
status_of() { printf '%s\n' "$1" | sed -n 's/^STATUS=\(.*\)$/\1/p' | tail -1; }
personal_calls() { tr '\n' ' ' < "$1/ctrl/personal.calls" 2>/dev/null | sed 's/ $//'; }

# THE WHOLE ROAD, with the port clash: both databases on 8563, both running.
H="$WORK/mig-clash"; seed_mig "$H"
_o="$(migrate "$H")"
check "it finishes"                                       "0" "$(rc_of "$_o")"
check "...as done"                                        "done" "$(status_of "$_o")"
has "the clash is explained before anything happens"      "the port your database uses" "$_o"
has "...and so is what will be done about it"             "stopped while the tables are copied out" "$_o"
check "the database was stopped, started, waited for - in that order" "stop start wait" "$(personal_calls "$H")"
check "the container was stopped after the copy (it holds the port)"  "1" "$(calls "$H" engine | grep -c '^stop ')"
check "the engine saw inspect, inspect, stop"             "container container stop" "$(verbs "$H")"
check "three tables copied out"                           "3" "$(mget "$H" legacy.exported)"
check "three restored"                                    "3" "$(mget "$H" legacy.restored)"
_copied_at="$(printf '%s\n' "$_o" | grep -n 'Copied 3 table' | head -1 | cut -d: -f1)"
_restored_at="$(printf '%s\n' "$_o" | grep -n 'Restored 3 table' | head -1 | cut -d: -f1)"
check "the copy out came before the restore"              "yes" "$([ -n "$_copied_at" ] && [ -n "$_restored_at" ] && [ "$_copied_at" -lt "$_restored_at" ] && echo yes || echo no)"
has "the restore report calls the copy expendable"        "no longer needed" "$_o"
has "...and names where the original still is"            "still holds the original" "$_o"
check "the record says migrate, done"                     "migrate/true" "$(mget "$H" legacy.choice)/$(mget "$H" legacy.crossing_done)"
check "...and when"                                       "yes" "$([ -n "$(mget "$H" legacy.migrated_at)" ] && echo yes || echo no)"
check "every export used the legacy profile"              "3" "$(calls "$H" exapump | grep -c '^export -p starter-kit-legacy ')"
check "every upload used the kit's profile"               "3" "$(calls "$H" exapump | grep -c '^upload -p starter-kit ')"

# NO CLASH: the container publishes another port, so nothing of the
# deployment's is touched and a running container is left running.
H="$WORK/mig-noclash"; seed_mig "$H"
_o="$(migrate "$H" "EXAKIT_LEGACY_DSN=127.0.0.1:8564")"
check "no clash finishes too"                             "0" "$(rc_of "$_o")"
lacks "...and does not mention the port"                  "the port your database uses" "$_o"
check "the deployment is never stopped or started"        "" "$(personal_calls "$H")"
check "the running container is left running"            "0" "$(calls "$H" engine | grep -c '^stop ')"
check "...the profile points at the named port"           "yes" "$(grep -q 'port = 8564' "$H/exapump/config.toml" && echo yes || echo no)"

# A stopped container on another port is started for the copy and stopped
# again afterwards: back the way it was found.
H="$WORK/mig-stopped"; seed_mig "$H"; fault "$H" engine.state stopped
_o="$(migrate "$H" "EXAKIT_LEGACY_DSN=127.0.0.1:8564")"
check "a stopped container is started, copied, stopped"   "container start container stop" "$(verbs "$H")"
has "...and the start is announced"                       "Starting the container" "$_o"
check "...with the deployment left alone"                 "" "$(personal_calls "$H")"

# DECLINED. Nothing has happened yet at the question, so nothing is undone.
H="$WORK/mig-declined"; seed_mig "$H"
_o="$(migrate "$H" "" '. "$EXAKIT_FAULT_DIR/decline.sh"' 0)"
check "declining returns 5"                               "5" "$(rc_of "$_o")"
check "...as declined"                                    "declined" "$(status_of "$_o")"
has "...saying nothing changed"                           "Nothing was changed" "$_o"
check "no stop, no export, nothing"                       "0" "$(calls "$H" engine | grep -c '^stop '; )"
check "the deployment was not touched"                    "" "$(personal_calls "$H")"
check "no exapump call at all"                            "" "$(calls "$H" exapump)"

# THE THINGS THAT CANNOT WORK, each named for what it is.
H="$WORK/mig-absent"; seed_mig "$H"; fault "$H" engine.state absent
_o="$(migrate "$H")"
check "a container that is not there"                     "1" "$(rc_of "$_o")"
has "...is named, with how to find the right one"         "no container named 'exasol-nano' in fakeengine" "$_o"
has "...and the engine's own listing"                     "fakeengine ps -a" "$_o"
H="$WORK/mig-unknown"; seed_mig "$H"; fault "$H" engine.state unknown
_o="$(migrate "$H")"
has "an engine that will not answer is asked about"       "did not answer about the container" "$_o"
H="$WORK/mig-noengine"; seed_mig "$H"
_o="$(migrate "$H" "EXAKIT_LEGACY_ENGINE=no-such-engine")"
check "an engine that is gone"                            "1" "$(rc_of "$_o")"
has "...is named"                                         "engine 'no-such-engine' is not on this machine" "$_o"
has "...with the option that names another"               "--engine docker|podman" "$_o"
# No name anywhere: not on the command line, not in the record either.
H="$WORK/mig-noname"; SEED_NO_CONTAINER=1 seed_mig "$H"
_o="$(migrate "$H" "EXAKIT_LEGACY_CONTAINER=")"
has "no container name at all asks for one"               "--container <name>" "$_o"
H="$WORK/mig-noexapump"; seed_mig "$H"
_o="$(NO_EXAPUMP=1 migrate "$H")"
has "no exapump names the repair"                         "exapump is not installed" "$_o"
check "...and returns 1"                                  "1" "$(rc_of "$_o")"

# NO PASSWORD, on the clash road: the deployment was already stopped for the
# copy, so it is started again and the container stopped, before the failure
# is reported.
H="$WORK/mig-nopassword"; SEED_NO_PASSWORD=1 seed_mig "$H"
_o="$(migrate "$H")"
check "no password fails"                                 "1" "$(rc_of "$_o")"
has "...naming the two ways to give one"                  "--password-file" "$_o"
check "...but the deployment is back up"                  "stop start wait" "$(personal_calls "$H")"
check "...and the container stopped for the port"         "1" "$(calls "$H" engine | grep -c '^stop ')"
lacks "...and nothing was copied"                         "Copied" "$_o"

# A DATABASE THAT NEVER ANSWERS, within the budget.
H="$WORK/mig-silent"; seed_mig "$H"; fault "$H" db.answer_after never; fault "$H" engine.state stopped
_o="$(migrate "$H" "EXAKIT_LEGACY_READY_TIMEOUT=5")"
check "a silent database fails"                           "1" "$(rc_of "$_o")"
has "...within the budget it names"                       "did not answer within 5s" "$_o"
has "...suggesting the port check"                        "fakeengine port exasol-nano" "$_o"
check "...the container it started is stopped again"      "1" "$(calls "$H" engine | grep -c '^stop ')"

# A CONTAINER THAT WILL NOT START, on the clash road: the deployment comes back.
H="$WORK/mig-nostart"; seed_mig "$H"; fault "$H" engine.state stopped; fault "$H" engine.start_rc 1
_o="$(migrate "$H")"
check "a container that will not start fails"            "1" "$(rc_of "$_o")"
has "...pointing at its logs"                             "fakeengine logs exasol-nano" "$_o"
check "...and the deployment is started again"           "stop start" "$(personal_calls "$H")"

# A PORT STILL HELD AFTER THE STOP (seen for real: the launcher's forwarder
# outlived its "stopped"). The kit's own reaper is tried; a port it cannot
# free is named for what it is, the deployment is started again, and the
# container is never blamed.
H="$WORK/mig-portheld"; seed_mig "$H"; fault "$H" personal.port_busy 1
_o="$(migrate "$H")"
check "a port still held after the stop fails"          "1" "$(rc_of "$_o")"
has "...naming the port and its holder"                  "port 8563 is still held (pid 4242: something-else)" "$_o"
lacks "...and not the container"                         "would not start" "$_o"
check "...the reaper was tried, the deployment restarted" "stop reap start" "$(personal_calls "$H")"
check "...and the container was never started"           "0" "$(calls "$H" engine | grep -c '^start ')"
H="$WORK/mig-portreaped"; seed_mig "$H"; fault "$H" personal.port_busy 1; fault "$H" personal.reap_frees 1
_o="$(migrate "$H")"
check "a port the reaper frees lets the copy go on"      "0" "$(rc_of "$_o")"
check "...stop, reap, then the copy, then the restart"   "stop reap start wait" "$(personal_calls "$H")"

# A DEPLOYMENT THAT WILL NOT STOP: nothing else is attempted.
H="$WORK/mig-nostop"; seed_mig "$H"; fault "$H" personal.stop_rc 1
_o="$(migrate "$H")"
check "a deployment that will not stop fails first"      "1" "$(rc_of "$_o")"
has "...with the remedy"                                  "exakit stop, then exakit migrate docker-nano" "$_o"
check "...before the container is asked anything more"   "container" "$(verbs "$H")"

# ONLY THE KIT'S SAMPLE DATA in the container: nothing of the user's to copy.
H="$WORK/mig-sample-only"; seed_mig "$H"
printf 'TPCH.REGION\n' > "$H/ctrl/db.tables"; printf 'TPCH.REGION|5\n' > "$H/ctrl/db.rows"
_o="$(migrate "$H")"
check "nothing of the user's is not a failure"           "0" "$(rc_of "$_o")"
check "...its own status"                                 "nothing" "$(status_of "$_o")"
has "...and says what the container held"                 "all of them the kit's bundled sample data (tpch)" "$_o"
has "...and how to get it"                                "exakit data-load" "$_o"
check "no export"                                         "0" "$(calls "$H" exapump | grep -c '^export')"
check "the deployment is back"                            "stop start wait" "$(personal_calls "$H")"
check "the record notes the sample"                       "tpch" "$(mget "$H" legacy.sample_left_out)"
# ...and an empty database, the same way.
H="$WORK/mig-empty"; seed_mig "$H"; : > "$H/ctrl/db.tables"
_o="$(migrate "$H")"
has "an empty database: nothing to copy"                  "no tables in it" "$_o"
check "...status nothing"                                 "nothing" "$(status_of "$_o")"

# A MIXED CONTAINER: the sample left out, the rest copied.
H="$WORK/mig-mixed"; seed_mig "$H"
printf 'S1.T1\nTPCH.REGION\nTPCH.NATION\n' > "$H/ctrl/db.tables"; printf 'TPCH.REGION|5\nTPCH.NATION|1\n' > "$H/ctrl/db.rows"
_o="$(migrate "$H")"
has "the count names the whole container"                 "The container holds 3 table(s)" "$_o"
has "...and the kit's share"                              "1 of them belong to the kit's bundled sample data (tpch)" "$_o"
check "two copied out"                                    "2" "$(mget "$H" legacy.exported)"
check "the changed sample table among them"               "1" "$(calls "$H" exapump | grep '^export' | grep -c '"TPCH"."NATION"')"

# EVERY EXPORT FAILS: the deployment comes back, nothing is lost.
H="$WORK/mig-exportfail"; seed_mig "$H"; printf 'S1.T1\nS1.T2\nS2.T3\n' > "$H/ctrl/export.fail"
_o="$(migrate "$H")"
check "a copy that copies nothing fails"                  "1" "$(rc_of "$_o")"
has "...saying nothing is lost"                           "nothing is lost" "$_o"
check "...with the deployment back up"                    "stop start wait" "$(personal_calls "$H")"
check "...and no export_dir recorded"                     "" "$(mget "$H" legacy.export_dir)"

# A PARTIAL RESTORE: what landed is counted, what did not keeps its copy.
H="$WORK/mig-partial"; seed_mig "$H"; fault "$H" upload.fail S2.T3; fault "$H" import.exists S1.T2
_o="$(migrate "$H")"
check "a partial restore returns 1"                       "1" "$(rc_of "$_o")"
check "...as partial"                                     "partial" "$(status_of "$_o")"
has "one restored"                                        "Restored 1 table(s)" "$_o"
has "one left alone, for the new database's reason"       "Left alone (the new database already had them): S1.T2" "$_o"
has "one kept"                                            "did not restore" "$_o"
lacks "...and the copy is not called expendable"          "no longer needed" "$_o"

# THE DEPLOYMENT DOES NOT COME BACK: the copy is kept and the remedy named.
H="$WORK/mig-noreturn"; seed_mig "$H"; fault "$H" personal.start_rc 1
_o="$(migrate "$H")"
check "a deployment that does not come back fails"       "1" "$(rc_of "$_o")"
has "...keeping the copy"                                 "not restored yet" "$_o"
has "...with the remedy"                                  "exakit start, then exakit migrate docker-nano" "$_o"
check "three copied out, none restored"                   "3/" "$(mget "$H" legacy.exported)/$(mget "$H" legacy.restored)"
check "...and the export_dir recorded for the next run"  "$H/migration" "$(mget "$H" legacy.export_dir)"

# A WAITING COPY from that run is restored first, without touching the container.
_o="$(migrate "$H")"
check "the waiting copy is restored"                      "0" "$(rc_of "$_o")"
has "...and said to be"                                   "waiting at" "$_o"
has "...with the pointer to a fresh run"                  "Run the command again for a fresh copy" "$_o"
check "three restored now"                                "3" "$(mget "$H" legacy.restored)"
check "no second export"                                  "3" "$(calls "$H" exapump | grep -c '^export')"
check "the deployment was not stopped again"              "stop start" "$(personal_calls "$H")"

# THE NEW DATABASE DOES NOT ANSWER at restore time: nothing is counted, the
# copy is kept, and the record does not say restored. (On a real machine every
# CREATE TABLE failed on authentication and read as "already there".)
H="$WORK/mig-newdb-silent"; seed_mig "$H"; fault "$H" newdb.answers no
_o="$(migrate "$H")"
check "an unreachable new database fails the restore"     "1" "$(rc_of "$_o")"
has "...keeping the copy"                                 "could not be restored. The copy is kept" "$_o"
lacks "...and nothing is called left alone"               "Left alone" "$_o"
check "...no upload was attempted"                        "0" "$(calls "$H" exapump | grep -c '^upload')"
check "...and the record does not say restored"           "" "$(mget "$H" legacy.restored)"
# The install's own second half, same fault: the copy waits for the next run.
H="$WORK/after-newdb-silent"; seed "$H"; fault "$H" newdb.answers no
_o="$(before "$H")"; note_rc "$_o"
_o2="$(after "$H" EXAKIT_LEGACY_DATA=migrate)"
has "the install's restore says the copy is kept"         "could not be restored. The copy is kept" "$_o2"
check "...and leaves the restore unrecorded for a re-run" "" "$(mget "$H" legacy.restored)"
fault "$H" newdb.answers yes
_o3="$(after "$H")"
has "...which then restores it"                           "Restored 3 table(s)" "$_o3"

# A SECOND, FRESH COPY after a complete one clears the spent files first.
H="$WORK/mig-twice"; seed_mig "$H"
_o="$(migrate "$H")"; check "first run done" "done" "$(status_of "$_o")"
printf 'S1.T1\n' > "$H/ctrl/db.tables"
_o="$(migrate "$H")"
check "second run done"                                   "done" "$(status_of "$_o")"
check "...restoring the one table now there"              "1" "$(mget "$H" legacy.restored)"
check "...with the earlier copy's tail gone"              "t1.csv" "$(ls "$H/migration" | grep '\.csv$' | tr '\n' ' ' | sed 's/ $//')"

# =============================================================================
echo
echo "invariants that held across every scenario above:"

_all_engine="$(cat "$WORK"/*/ctrl/engine.calls 2>/dev/null)"
_all_exapump="$(cat "$WORK"/*/ctrl/exapump.calls 2>/dev/null)"
check "the engine was used, so the next lines mean something" "yes" "$([ -n "$_all_engine" ] && echo yes || echo no)"
check "exapump was used" "yes" "$([ -n "$_all_exapump" ] && echo yes || echo no)"
# THE INVARIANT: the crossing copies and stops. It never deletes.
check "no engine call ever removed a container" "0" "$(printf '%s\n' "$_all_engine" | grep -cE '^(rm|container rm|volume|destroy|kill|prune)')"
# `version` is the one read of the engine itself rather than of the container:
# it is how a stopped daemon is told apart from a missing container.
check "only inspect, version, start and stop were ever issued" "" \
    "$(printf '%s\n' "$_all_engine" | awk '$1 != "container" && $1 != "version" && $1 != "start" && $1 != "stop"' | sort -u | tr '\n' ' ')"
check "every inspect was of the recorded container" "0" "$(printf '%s\n' "$_all_engine" | grep '^container' | grep -vc 'exasol-nano$')"
# THE PASSWORD. It is checked where it would leak - on screen, and in the argv
# handed to another process (what `ps` shows) - and not in the xtrace, which
# expands every argument of every in-process function by design.
check "the password never reached the screen" "0" "$(grep -c -- "$PASSWORD" "$SCREENS")"
check "...nor any process the crossing ran" "0" "$(printf '%s\n' "$_all_engine" "$_all_exapump" | grep -c -- "$PASSWORD")"
# stat is two different programs with the same name. `stat -f FMT` reads a
# format on BSD and means --file-system on GNU, where it SUCCEEDS and prints
# block counts - so a `-f ... || -c ...` fallback never reaches the GNU form
# and this check read "no" on every Linux runner. Dispatch on the OS, the way
# common.sh already does for mtime.
_file_mode() {
    case "$(uname -s)" in
        Darwin|*BSD*) stat -f '%Lp' "$1" 2>/dev/null ;;
        *)            stat -c '%a'  "$1" 2>/dev/null ;;
    esac
}
check "...and it did land in a 0600 profile inside the sandbox" "yes" \
    "$(grep -lq -- "$PASSWORD" "$WORK"/e2e-migrate/exapump/config.toml 2>/dev/null && [ "$(_file_mode "$WORK/e2e-migrate/exapump/config.toml")" = 600 ] && echo yes || echo no)"
check "the developer's real exapump config is untouched" "$REAL_CONFIG_BEFORE" "$(_hash "$REAL_EXAPUMP_CONFIG")"
# THE INSTALL IS NEVER FAILED BY THE CROSSING.
check "every first half returned 0" "" "$(printf '%s\n' $BEFORE_RCS | grep -v '^0$' | tr '\n' ' ')"
# THE RECORD STAYS READABLE.
_bad_json=""
for _m in "$WORK"/*/manifest.json; do python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$_m" 2>/dev/null || _bad_json="$_bad_json ${_m#$WORK/}"; done
check "every manifest is still valid JSON" "" "$_bad_json"
# THE TWO PROFILES NEVER CROSS. Reads of the old database go through the
# legacy profile; writes into the new one go through the kit's.
# The one SELECT the kit's profile does carry is the probe of the NEW database
# before a restore (EXAKIT_NEW_OK) - a read of the new one, by design.
check "no read of the old database used the kit's profile" "0" \
    "$(printf '%s\n' "$_all_exapump" | grep -E '^(export|sql -p [^ ]+ SELECT)' | grep -v EXAKIT_NEW_OK | grep -c -- '-p starter-kit ')"
check "no upload used the legacy profile" "0" "$(printf '%s\n' "$_all_exapump" | grep '^upload' | grep -c -- 'starter-kit-legacy')"
check "no parquet was ever asked for" "0" "$(printf '%s\n' "$_all_exapump" | grep -c parquet)"

# =============================================================================
if coverage_report "$ROOT/setup/lib/legacy-crossing.sh" "$TRACE" 85; then
    PASS=$((PASS+1)); printf '  ok   coverage floor held\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL coverage is below the floor\n'
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
