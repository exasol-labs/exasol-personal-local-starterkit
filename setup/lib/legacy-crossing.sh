#!/usr/bin/env bash
# legacy-crossing.sh — moving an installation made by an OLDER kit onto this one.
#
# Older kits (this one before the container runtime was removed, and the
# upstream exasol-labs/exasol-personal-local-starterkit) could deploy the
# database as a CONTAINER. This kit deploys Exasol Personal and nothing else,
# so an installation whose manifest records a container database has a database
# that nothing in this tree can drive.
#
# This module is the ONE place that touches such an installation, and the way it
# touches it matters: it reads the manifest the old kit wrote and shells out to
# the recorded engine for exactly three verbs — inspect, start, stop. It does
# not reintroduce a runtime, it cannot deploy a container, and nothing outside
# the crossing calls into it. When the crossing is done the module has no work
# left to do on that machine, for ever.
#
# THE ORDER IS FORCED BY THE PORT. The old container is listening on the port
# the new deployment wants, so the container must be stopped before the deploy —
# on BOTH answers, including the one that keeps it. And the data can only be
# read while it is still up. That is why the crossing is in two halves with the
# install between them:
#
#   legacy_crossing_before   read the tables out, stop the container   (before step 1)
#   ... the install runs: launcher, deployment, exapump ...
#   legacy_crossing_after    ask, restore into the new database        (before the sample data)
#
# THE COPY IS MADE BEFORE THE QUESTION, which is the one thing here that looks
# backwards and is not. The container can only be read while it holds the port,
# and it holds the port only until the deployment takes it - so the first half
# is the only moment the data can be reached at all. Asking there meant asking
# before the kit had installed a single thing, about a database the user may
# have forgotten they had. So the tables are read out silently into a directory
# under the kit's own home, and the question waits for the place it belongs:
# after exapump, before the sample data, where a database is up, an exapump
# binary exists and the profile points at the NEW database. A "no" there
# deletes the copy; nothing in the old container is changed either way, and no
# data leaves this machine.
#
# WHAT IS NEVER DONE: the old container and its data volume are not deleted, on
# either answer. A migration that has just copied data out is exactly the wrong
# moment to destroy the only other copy, and "skip" means skip. The container is
# left stopped, named on screen, with the one command that removes it.
#
# AFTER THE INSTALL there is one more road, `exakit migrate docker-nano`
# (legacy_migrate_now, at the end of this file): the same copy, in one sitting,
# for someone who answered "skip" and changed their mind, or whose container the
# installer never saw. And on BOTH roads the kit's own bundled sample data is
# left out of the copy: the install loads it itself, and `exakit data-load` puts
# it back any time (see "the kit's own sample data" below).
#
# Twin: setup/lib/legacy-crossing.ps1. Keep the two in step.

# Where the export lands. Under the kit home rather than /tmp: it holds the
# user's data and it has to survive a reboot between the two halves of a
# resumed install.
EXAKIT_LEGACY_EXPORT_DIR="${EXAKIT_LEGACY_EXPORT_DIR:-$EXAKIT_HOME/migration}"

# The exapump profile pointing at the OLD database. A second profile, not a
# rewrite of the kit's own: the kit's profile has to keep pointing at the new
# database throughout, and a password belongs in a 0600 config file rather than
# in argv where `ps` can read it.
EXAKIT_LEGACY_PROFILE="${EXAKIT_LEGACY_PROFILE:-starter-kit-legacy}"

# Exasol's own schemas. Everything else on the machine is the user's, including
# the kit's STARTER_KIT — a user who loaded their own tables into it means them
# when they say "my data".
EXAKIT_LEGACY_SYSTEM_SCHEMAS="'SYS','EXA_STATISTICS'"

# migrate | skip — set by legacy_choose, read by both halves.
EXAKIT_LEGACY_CHOICE=""

# --- what the old install recorded, or what the command line names -----------
#
# Every accessor answers from an EXAKIT_LEGACY_* variable first and from the
# manifest second. The install-time crossing sets none of them and reads the
# record an older kit wrote under runtime.*. `exakit migrate docker-nano` runs
# AFTER an install, when runtime.* describes the new deployment and says nothing
# about the old container - so the CLI fills these from its options, or from the
# copy of the old record the crossing keeps under legacy.* (legacy_remember_record).

# Whether this machine has an installation whose database is a container. The
# predicate itself lives in common.sh so the CLI can ask the same question from
# the same place - see exakit_legacy_runtime_recorded there.
legacy_db_recorded() { exakit_legacy_runtime_recorded; }

# legacy_record_value <key> — the old container's container/volume/engine:
# the copy under legacy.* first, runtime.* only when none was kept.
#
# runtime.* describes the OLD database only until the new one is recorded:
# personal_record_manifest then drops these keys, so they stop describing a
# deployment that has no container of that name. legacy_remember_record copies
# them under legacy.* before that, and the restore after the deployment reads
# them from there. Twin of Get-LegacyRecordValue.
legacy_record_value() {
    _lrv="$(manifest_get "legacy.$1" 2>/dev/null || true)"
    if [ -n "$_lrv" ]; then printf '%s' "$_lrv"; return 0; fi
    manifest_get "runtime.$1" 2>/dev/null || true
}

legacy_container() {
    [ -n "${EXAKIT_LEGACY_CONTAINER:-}" ] && { printf '%s' "$EXAKIT_LEGACY_CONTAINER"; return 0; }
    legacy_record_value container
}
legacy_volume() {
    [ -n "${EXAKIT_LEGACY_VOLUME:-}" ] && { printf '%s' "$EXAKIT_LEGACY_VOLUME"; return 0; }
    legacy_record_value volume
}
legacy_dsn() {
    [ -n "${EXAKIT_LEGACY_DSN:-}" ] && { printf '%s' "$EXAKIT_LEGACY_DSN"; return 0; }
    manifest_get runtime.dsn 2>/dev/null || true
}

legacy_user() {
    _lu="${EXAKIT_LEGACY_USER:-}"
    [ -n "$_lu" ] || _lu="$(manifest_get runtime.user 2>/dev/null || true)"
    printf '%s' "${_lu:-sys}"
}

legacy_password_file() {
    [ -n "${EXAKIT_LEGACY_PASSWORD_FILE:-}" ] && { printf '%s' "$EXAKIT_LEGACY_PASSWORD_FILE"; return 0; }
    manifest_get runtime.password_file 2>/dev/null || true
}

# legacy_engine_name — the engine's NAME (docker, podman), from the option or
# the record, never re-detected: this is about the engine that holds this
# particular container, and a machine can have another one installed.
legacy_engine_name() {
    [ -n "${EXAKIT_LEGACY_ENGINE:-}" ] && { printf '%s' "$EXAKIT_LEGACY_ENGINE"; return 0; }
    # The engine actually resolved, so the record and every message name the
    # one the container is really in. Only when nothing resolves does the
    # recorded name stand on its own, so a message can still say what is
    # missing.
    _len_path="$(legacy_engine)"
    if [ -n "$_len_path" ]; then
        _len_base="${_len_path##*/}"
        printf '%s' "${_len_base%.exe}"
        return 0
    fi
    legacy_record_value engine
}

# legacy_engine — the engine that can actually reach this database, as a
# runnable path, or empty.
#
# THE RECORDED NAME IS A HINT, NOT THE ANSWER. The old kit ran the container
# under Docker when it was there and Podman otherwise, and it wrote whichever
# it used into runtime.engine. A machine where that key is missing (an older
# record), or where the user has since moved from one engine to the other, then
# had its container declared unreachable - "the container engine this database
# needs is not on this machine any more" - with the container sitting right
# there in the other engine, and the install went on to hit the port it holds.
# So: the recorded engine first, and if that cannot be run, whichever engine on
# this machine actually holds the recorded container. Docker before Podman,
# the order the old kit preferred. Probed once per run; each probe is a process
# start.
_EXAKIT_LEGACY_ENGINE_PATH=""

# legacy_engine_cache_reset — forget the resolved engine. Twin of
# Reset-LegacyEngineCache; see the note there. Each scenario of the shell suite
# runs in its own subshell, so nothing here needs it yet, and a caller that
# resolves twice across two different records does.
legacy_engine_cache_reset() {
    _EXAKIT_LEGACY_ENGINE_PATH=""
}
_EXAKIT_LEGACY_ENGINE_PROBED=0
legacy_engine() {
    if [ -n "${EXAKIT_LEGACY_ENGINE:-}" ]; then
        command -v "$EXAKIT_LEGACY_ENGINE" 2>/dev/null || true
        return 0
    fi
    if [ "$_EXAKIT_LEGACY_ENGINE_PROBED" = 1 ]; then
        printf '%s' "$_EXAKIT_LEGACY_ENGINE_PATH"
        return 0
    fi
    _le_path=""
    _le_recorded="$(legacy_record_value engine)"
    [ -n "$_le_recorded" ] && _le_path="$(command -v "$_le_recorded" 2>/dev/null || true)"
    if [ -z "$_le_path" ]; then
        _le_container="$(legacy_container)"
        if [ -n "$_le_container" ]; then
            for _le_try in docker podman; do
                _le_bin="$(command -v "$_le_try" 2>/dev/null || true)"
                [ -n "$_le_bin" ] || continue
                if exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-20}" \
                       "$_le_bin" container inspect "$_le_container" >/dev/null 2>&1; then
                    _le_path="$_le_bin"
                    break
                fi
            done
        fi
    fi
    _EXAKIT_LEGACY_ENGINE_PATH="$_le_path"
    _EXAKIT_LEGACY_ENGINE_PROBED=1
    printf '%s' "$_le_path"
}

# legacy_forget_engine — drop the cached answer, for the tests that change what
# is on PATH between scenarios.
legacy_forget_engine() {
    _EXAKIT_LEGACY_ENGINE_PATH=""
    _EXAKIT_LEGACY_ENGINE_PROBED=0
    return 0
}

# legacy_remember_record — the old record, copied under legacy.* before the
# install overwrites runtime.* with the new deployment. `exakit migrate
# docker-nano` reads it back, so a "skip" answered today needs no options when
# it is reversed next month, and `exakit status` reads it to say the old
# database is still there. Strings, so one manifest_set each (manifest_set_many
# writes booleans only).
legacy_remember_record() {
    _lrr_v="$(legacy_container)";    [ -n "$_lrr_v" ] && manifest_set legacy.container "$_lrr_v"
    _lrr_v="$(legacy_engine_name)";  [ -n "$_lrr_v" ] && manifest_set legacy.engine "$_lrr_v"
    _lrr_v="$(legacy_volume)";       [ -n "$_lrr_v" ] && manifest_set legacy.volume "$_lrr_v"
    _lrr_v="$(legacy_dsn)";          [ -n "$_lrr_v" ] && manifest_set legacy.dsn "$_lrr_v"
    _lrr_v="$(legacy_password_file)"; [ -n "$_lrr_v" ] && manifest_set legacy.password_file "$_lrr_v"
    manifest_set legacy.user "$(legacy_user)"
    return 0
}

# legacy_engine_run <args...> — one bounded engine call, output on stdout.
#
# Bounded for the reason every engine probe in this kit is bounded: an engine
# that is still starting does not answer, and the crossing must not hang an
# install behind it.
legacy_engine_run() {
    _ler_bin="$(legacy_engine)"
    [ -n "$_ler_bin" ] || return 1
    exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-20}" "$_ler_bin" "$@" 2>/dev/null
}

# legacy_engine_answers — is the engine's daemon/machine up, not just its CLI?
# The server version is empty when Docker Desktop or the Podman machine is
# stopped. Twin of Test-LegacyEngineAnswers.
legacy_engine_answers() {
    _lea="$(legacy_engine_run version --format '{{.Server.Version}}')" || return 1
    [ -n "$_lea" ]
}

# legacy_container_state — running | stopped | absent | unknown.
# "unknown" is its own answer: an engine that will not talk is not evidence
# that the user's database is gone.
legacy_container_state() {
    _lcs_name="$(legacy_container)"
    [ -n "$_lcs_name" ] || { echo "absent"; return 0; }
    [ -n "$(legacy_engine)" ] || { echo "unknown"; return 0; }
    _lcs_out="$(legacy_engine_run container inspect -f '{{.State.Running}}' "$_lcs_name")" || {
        # A refusal is ambiguous on its own; ask whether it exists at all.
        # Silence is not absence: with the daemon or machine stopped every
        # inspect fails, and that read as "the container is gone". Only an
        # engine that answers can say it is absent.
        if legacy_engine_run container inspect "$_lcs_name" >/dev/null 2>&1; then
            echo "unknown"
        elif ! legacy_engine_answers; then
            echo "unknown"
        else
            echo "absent"
        fi
        return 0
    }
    case "$_lcs_out" in
        *true*)  echo "running" ;;
        *false*) echo "stopped" ;;
        *)       echo "unknown" ;;
    esac
}

legacy_start_container() {
    _lsc_name="$(legacy_container)"
    [ -n "$_lsc_name" ] || return 1
    legacy_engine_run start "$_lsc_name" >/dev/null 2>&1 || return 1
    # Started is not ready. The readiness probe is a real query, below.
    return 0
}

# legacy_stop_container — the one mutation the crossing makes to the old
# install, and it is reversible: the container is stopped, never removed, and
# its data volume is not touched.
legacy_stop_container() {
    _ltc_name="$(legacy_container)"
    [ -n "$_ltc_name" ] || return 0
    [ "$(legacy_container_state)" = "running" ] || return 0
    info "Stopping the old database container ($_ltc_name) so the new deployment can take the port"
    legacy_engine_run stop "$_ltc_name" >/dev/null 2>&1 || {
        warn "Could not stop the container $_ltc_name — the new deployment may find its port busy"
        return 1
    }
    manifest_set legacy.container_stopped true
    return 0
}

# legacy_forget_old_steps — the step ticks an older kit recorded, dropped, so
# this kit's steps all run. The launcher step is not among them: no older kit
# had one, so a tick there is this install's own.
legacy_forget_old_steps() {
    command -v exakit_unmark_step >/dev/null 2>&1 || return 0
    for _lfs_step in runtime exapump mcp pyexasol exakit_helper; do
        exakit_unmark_step "$_lfs_step" 2>/dev/null || true
    done
    return 0
}

# legacy_remove_command — the exact command that removes the old container and
# its data, printed for the user and never run by the kit.
legacy_remove_command() {
    _lrc_engine="$(legacy_engine_name)"
    _lrc_engine="${_lrc_engine:-podman}"
    _lrc_c="$(legacy_container)"; _lrc_v="$(legacy_volume)"
    [ -n "$_lrc_c" ] || return 1
    if [ -n "$_lrc_v" ]; then
        printf '%s rm -f %s && %s volume rm %s' "$_lrc_engine" "$_lrc_c" "$_lrc_engine" "$_lrc_v"
    else
        printf '%s rm -f %s' "$_lrc_engine" "$_lrc_c"
    fi
}

# --- talking to the old database --------------------------------------------

# legacy_write_profile — the exapump profile for the OLD database, from what the
# old install recorded. Returns non-zero when the password is not on file, which
# is the honest case for a deployment the old kit adopted rather than created.
legacy_write_profile() {
    _lwp_dsn="$(legacy_dsn)"
    [ -n "$_lwp_dsn" ] || return 1
    _lwp_host="${_lwp_dsn%%:*}"
    _lwp_port="${_lwp_dsn##*:}"
    # The password is read into a variable and handed to the writer, which puts
    # it in a 0600 file. It is never echoed, logged, or passed on a command line.
    # EXAKIT_LEGACY_PASSWORD is the one typed at `exakit migrate docker-nano`'s
    # prompt - a shell variable, so it is not in argv and not in the environment
    # of anything the kit runs.
    _lwp_password="${EXAKIT_LEGACY_PASSWORD:-}"
    if [ -z "$_lwp_password" ]; then
        _lwp_pwfile="$(legacy_password_file)"
        [ -n "$_lwp_pwfile" ] && [ -s "$_lwp_pwfile" ] || return 1
        _lwp_password="$(cat "$_lwp_pwfile")"
    fi
    exapump_write_profile "$EXAKIT_LEGACY_PROFILE" "$_lwp_host" "$_lwp_port" \
        "$(legacy_user)" "$_lwp_password" || return 1
    return 0
}

# legacy_wait_db_answers <seconds> — poll the old database until it answers or
# the budget is spent, in five-second steps with the first ask immediate.
legacy_wait_db_answers() {
    _lwd_budget="$1"
    _lwd_waited=0
    until legacy_db_answers; do
        _lwd_waited=$(( _lwd_waited + 5 ))
        [ "$_lwd_waited" -ge "$_lwd_budget" ] && break
        sleep 5
    done
    legacy_db_answers
}

# legacy_db_answers — a real query against the old database through its own
# profile. The readiness signal for everything below.
legacy_db_answers() {
    "$(exapump_cli)" sql -p "$EXAKIT_LEGACY_PROFILE" \
        "SELECT 'EXAKIT_LEGACY_OK' AS P" 2>/dev/null | grep -q 'EXAKIT_LEGACY_OK'
}

# legacy_tables — SCHEMA.TABLE, one per line, for every non-system table.
#
# The sentinel wrapper is the pattern exapump_count uses and it is here for the
# same reason: the echoed query literal must not be mistaken for a result row,
# and after "EXAKIT_LT[" the literal has a quote where a result has a name.
legacy_tables() {
    "$(exapump_cli)" sql -p "$EXAKIT_LEGACY_PROFILE" \
        "SELECT 'EXAKIT_LT[' || TABLE_SCHEMA || '.' || TABLE_NAME || ']' AS T FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT IN ($EXAKIT_LEGACY_SYSTEM_SCHEMAS) ORDER BY TABLE_SCHEMA, TABLE_NAME" \
        2>/dev/null | sed -n 's/.*EXAKIT_LT\[\([^]]*\)\].*/\1/p'
}

# legacy_table_ddl <schema> <table> — CREATE TABLE for the target, built from
# the SOURCE column types.
#
# THIS IS WHY THE ROUND TRIP KEEPS ITS TYPES. `exapump upload` into a table that
# does not exist INFERS the schema from the CSV, and inference turns a
# DECIMAL(12,4) into whatever the sample looks like. Creating the table with the
# original types first means the upload only has to parse into them.
legacy_table_ddl() {
    _ltd_schema="$1"; _ltd_table="$2"
    _ltd_cols="$("$(exapump_cli)" sql -p "$EXAKIT_LEGACY_PROFILE" \
        "SELECT 'EXAKIT_LC[' || COLUMN_NAME || '<<:>>' || COLUMN_TYPE || ']' AS C FROM EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = '$_ltd_schema' AND COLUMN_TABLE = '$_ltd_table' ORDER BY COLUMN_ORDINAL_POSITION" \
        2>/dev/null | sed -n 's/.*EXAKIT_LC\[\([^]]*\)\].*/\1/p')"
    [ -n "$_ltd_cols" ] || return 1
    _ltd_list=""
    while IFS= read -r _ltd_c; do
        [ -n "$_ltd_c" ] || continue
        # SPLIT ON THE MARKER, NOT ON WHITESPACE. A column name may contain a
        # space ("my col") and so may a type ("TIMESTAMP WITH LOCAL TIME
        # ZONE"), so neither end can be found from the first or the last space.
        _ltd_name="${_ltd_c%%<<:>>*}"
        _ltd_type="${_ltd_c#*<<:>>}"
        # Quoted identifiers: a column named ORDER or one with a lower-case
        # letter or a space is legal in Exasol and illegal unquoted.
        [ -n "$_ltd_list" ] && _ltd_list="$_ltd_list, "
        _ltd_list="$_ltd_list\"$_ltd_name\" $_ltd_type"
    done <<EOF
$_ltd_cols
EOF
    [ -n "$_ltd_list" ] || return 1
    printf 'CREATE TABLE "%s"."%s" (%s)' "$_ltd_schema" "$_ltd_table" "$_ltd_list"
}

# --- the kit's own sample data ----------------------------------------------
#
# The bundled datasets (data/datasets/<id>/) are the kit's, not the user's. The
# install that runs around the crossing loads them itself, and `exakit
# data-load` puts them back any time. Copying them out of the old database and
# into the new one would spend minutes on tables the new database already has -
# and the restore would then have to refuse each one as already there. So a
# table that IS a bundled sample table, unchanged, is left out of the copy and
# named as such. "Unchanged" means the same schema, the same table and the same
# number of rows as the CSV the kit ships; a sample table the user has changed
# is theirs and travels with the rest.

# legacy_count_lines <text> — how many non-blank lines.
legacy_count_lines() {
    _lcn="$(printf '%s\n' "$1" | grep -c '[^[:space:]]' || true)"
    printf '%s' "${_lcn:-0}"
}

# legacy_sample_catalog — SCHEMA.TABLE|dataset|rows, one line per table the
# bundled datasets create, read from the kit's own files. Nothing is hardcoded:
# the schema comes from dataset.conf, the table from the CSV's name (the same
# rule the loader applies), the row count from the file itself.
#
# NOT EVERY SAMPLE TABLE HAS A CSV. A dataset may create a table and fill it
# from SQL — energy's ENERGY_READINGS is generated by 02_load_data.sql, 108,000
# rows and no file — and a catalog built from the CSV names alone does not know
# that table exists at all. It then reads as the user's own: the crossing
# offers to copy the kit's own sample data back to itself, and the restore,
# which asks this same catalog whether to stand aside, does not. So the markers
# dataset.conf already declares are read in as well, and a marker with no CSV
# behind it is listed with an EMPTY row count — the name is known, the size is
# not. What that means for "unchanged" is legacy_classify's business.
legacy_sample_catalog() {
    command -v exakit_bundled_datasets >/dev/null 2>&1 || return 0
    _lsc_root="$(exakit_repo_root 2>/dev/null)" || return 0
    exakit_bundled_datasets | while IFS='|' read -r _lsc_id _lsc_label _lsc_flag _lsc_markers _lsc_schema; do
        [ -n "$_lsc_id" ] || continue
        _lsc_seen=""
        for _lsc_csv in "$_lsc_root/data/datasets/$_lsc_id/data"/*.csv; do
            [ -f "$_lsc_csv" ] || continue
            _lsc_table="$(basename "$_lsc_csv" .csv | tr '[:lower:]' '[:upper:]')"
            # The header is not a row, and a last line without a newline still is.
            _lsc_rows="$(awk 'END { print (NR > 0 ? NR - 1 : 0) }' "$_lsc_csv" 2>/dev/null)"
            _lsc_seen="$_lsc_seen,$_lsc_table"
            printf '%s.%s|%s|%s\n' "$_lsc_schema" "$_lsc_table" "$_lsc_id" "${_lsc_rows:-0}"
        done
        # The declared tables no CSV already accounted for, row count unknown.
        for _lsc_marker in $(printf '%s' "$_lsc_markers" | tr ',' ' '); do
            _lsc_table="$(printf '%s' "$_lsc_marker" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
            [ -n "$_lsc_table" ] || continue
            case "$_lsc_seen," in
                *",$_lsc_table,"*) continue ;;
            esac
            _lsc_seen="$_lsc_seen,$_lsc_table"
            printf '%s.%s|%s|\n' "$_lsc_schema" "$_lsc_table" "$_lsc_id"
        done
    done
}

# legacy_table_rows <'S1','S2'> — SCHEMA.TABLE|rows for every table of the old
# database in those schemas, from the row count Exasol keeps in EXA_ALL_TABLES.
# One query for all of them; a table whose count is not known yields no line.
legacy_table_rows() {
    "$(exapump_cli)" sql -p "$EXAKIT_LEGACY_PROFILE" \
        "SELECT 'EXAKIT_LR[' || TABLE_SCHEMA || '.' || TABLE_NAME || '<<:>>' || CAST(TABLE_ROW_COUNT AS VARCHAR(40)) || ']' AS R FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA IN ($1)" \
        2>/dev/null | sed -n 's/.*EXAKIT_LR\[\([^]]*\)\].*/\1/p' | sed 's/<<:>>/|/'
}

# _legacy_field_of <lines> <key> <field-no> — the field of the line whose first
# field is exactly <key>. Exact, not a substring: S1.T is not S1.T2.
_legacy_field_of() {
    printf '%s\n' "$1" | awk -F'|' -v k="$2" -v f="$3" '$1 == k { print $f; exit }'
}

# legacy_classify <tables, one per line> — the old database's tables split into
# the user's own and the kit's unchanged sample tables. Sets:
#   EXAKIT_LEGACY_OWN_TABLES     one per line — what the crossing copies
#   EXAKIT_LEGACY_SAMPLE_TABLES  one per line — left out
#   EXAKIT_LEGACY_SAMPLE_IDS     the datasets those belong to, comma-separated
# Asks the old database for row counts only when a table sits in a sample
# schema at all, and then once for all of them.
legacy_classify() {
    _lcl_all="$1"
    EXAKIT_LEGACY_OWN_TABLES=""
    EXAKIT_LEGACY_SAMPLE_TABLES=""
    EXAKIT_LEGACY_SAMPLE_IDS=""
    _lcl_catalog="$(legacy_sample_catalog)"
    _lcl_schemas=""
    if [ -n "$_lcl_catalog" ]; then
        while IFS= read -r _lcl_t; do
            [ -n "$_lcl_t" ] || continue
            [ -n "$(_legacy_field_of "$_lcl_catalog" "$_lcl_t" 2)" ] || continue
            _lcl_s="'${_lcl_t%%.*}'"
            case ",$_lcl_schemas," in
                *",$_lcl_s,"*) ;;
                *) _lcl_schemas="${_lcl_schemas:+$_lcl_schemas,}$_lcl_s" ;;
            esac
        done <<EOF
$_lcl_all
EOF
    fi
    _lcl_rows=""
    [ -n "$_lcl_schemas" ] && _lcl_rows="$(legacy_table_rows "$_lcl_schemas")"
    while IFS= read -r _lcl_t; do
        [ -n "$_lcl_t" ] || continue
        _lcl_id=""; _lcl_want=""; _lcl_have=""
        if [ -n "$_lcl_catalog" ]; then
            _lcl_id="$(_legacy_field_of "$_lcl_catalog" "$_lcl_t" 2)"
            _lcl_want="$(_legacy_field_of "$_lcl_catalog" "$_lcl_t" 3)"
            [ -n "$_lcl_id" ] && _lcl_have="$(_legacy_field_of "$_lcl_rows" "$_lcl_t" 2)"
        fi
        # UNCHANGED, as far as it can be told. A table with a CSV behind it is
        # the kit's only while the old database still holds exactly the rows
        # the file ships; touch it and it becomes the user's and travels. A
        # table the dataset GENERATES has no file to count against, so
        # "changed" cannot be measured — and guessing the other way is the
        # expensive mistake: it offers the user their own sample data back,
        # copies 108,000 rows nobody asked for, and restores them minutes
        # before the dataset load replaces the table anyway.
        _lcl_same=0
        if [ -n "$_lcl_id" ]; then
            if [ -z "$_lcl_want" ]; then
                _lcl_same=1
            elif [ -n "$_lcl_have" ] && [ "$_lcl_have" = "$_lcl_want" ]; then
                _lcl_same=1
            fi
        fi
        if [ "$_lcl_same" = 1 ]; then
            EXAKIT_LEGACY_SAMPLE_TABLES="${EXAKIT_LEGACY_SAMPLE_TABLES}${_lcl_t}
"
            case ",$EXAKIT_LEGACY_SAMPLE_IDS," in
                *",$_lcl_id,"*) ;;
                *) EXAKIT_LEGACY_SAMPLE_IDS="${EXAKIT_LEGACY_SAMPLE_IDS:+$EXAKIT_LEGACY_SAMPLE_IDS,}$_lcl_id" ;;
            esac
        else
            EXAKIT_LEGACY_OWN_TABLES="${EXAKIT_LEGACY_OWN_TABLES}${_lcl_t}
"
        fi
    done <<EOF
$_lcl_all
EOF
    return 0
}

# legacy_sample_note <own> <sample> — the sentence that says what is left out.
legacy_sample_note() {
    info "$2 of them belong to the kit's bundled sample data ($EXAKIT_LEGACY_SAMPLE_IDS), unchanged — the kit loads that itself, so they are not copied. Your own: $1 table(s)."
}

# --- the two halves ---------------------------------------------------------

# legacy_choose — the question, asked once.
#
# Two answers, and they are exclusive: this is a fork in the road, not a set of
# features. EXAKIT_LEGACY_DATA pre-answers it for an unattended run, and an
# unattended run with no answer SKIPS — copying a database is not something to
# start on someone's behalf while they are not there, and skipping destroys
# nothing.
legacy_choose() {
    _lc_tables="$1"
    _lc_can_migrate="$2"
    _lc_why="$3"

    case "${EXAKIT_LEGACY_DATA:-}" in
        migrate|yes|1)
            EXAKIT_LEGACY_CHOICE="migrate"
            [ "$_lc_can_migrate" = yes ] || {
                warn "EXAKIT_LEGACY_DATA asked for a migration, but $_lc_why"
                EXAKIT_LEGACY_CHOICE="skip"
            }
            return 0 ;;
        skip|no|0)
            EXAKIT_LEGACY_CHOICE="skip"; return 0 ;;
    esac

    if [ "$_lc_can_migrate" != yes ]; then
        warn "Your data cannot be copied automatically: $_lc_why"
        EXAKIT_LEGACY_CHOICE="skip"
        return 0
    fi

    if ! exakit_stdin_is_tty; then
        info "Nothing is asked in an unattended run, so the old database is left alone."
        info "To copy it into the new one, re-run with EXAKIT_LEGACY_DATA=migrate — or afterwards: exakit migrate docker-nano"
        EXAKIT_LEGACY_CHOICE="skip"
        return 0
    fi

    # Row 2 is the exclusive one: picking "skip" clears "migrate" and the other
    # way round.
    EXAKIT_CHECKBOX_EXCLUSIVE=2
    ui_checkbox_menu "Your existing database" "1" \
        "Migrate my data — copy $_lc_tables table(s) into the new database" \
        "Skip and continue — set up the new database empty, and leave the old one alone"
    case "${EXAKIT_CHECKBOX_SELECTION:-1}" in
        *2*) EXAKIT_LEGACY_CHOICE="skip" ;;
        *)   EXAKIT_LEGACY_CHOICE="migrate" ;;
    esac
    return 0
}

# legacy_export — every non-system table to CSV under <dir>, plus a plain index
# the second half reads back.
#
# CSV, not Parquet: `exapump export --format parquet` is broken in the versions
# this kit installs (it writes the rows as CSV and then fails re-parsing its own
# output), so asking for Parquet produces a 0-byte file and a confusing error.
# CSV round-trips faithfully INTO A TABLE THAT ALREADY EXISTS with the right
# types, which is what legacy_table_ddl is for.
#
# THE ONE THING CSV CANNOT CARRY: an empty string and a NULL are the same three
# bytes in a CSV field, so a VARCHAR that held '' arrives as NULL. That is named
# on screen before the copy starts, not discovered afterwards.
legacy_export() {
    _lex_dir="$1"; shift
    mkdir -p "$_lex_dir" || return 1
    chmod 700 "$_lex_dir" 2>/dev/null || true
    : > "$_lex_dir/index"
    _lex_ok=0
    _lex_bad=0
    _lex_bad_names=""
    _lex_total=$#
    _lex_n=0
    # A BAR, NOT A SPINNER PER TABLE. Copying a database out is the one long
    # stretch of the crossing, and a spinner says only "still going"; the bar
    # says how much of it is left, in the same shape the deploy and the dataset
    # loads use. Live only on a real terminal: ui_progress_begin answers 0
    # elsewhere and the labels below then narrate nothing, exactly as before.
    # It owns the animation slot, so run_logged's own spinner nests into it.
    _lex_state=""
    _lex_live=0
    if [ "$_lex_total" -gt 0 ]; then
        _lex_state="$(mktemp "${TMPDIR:-/tmp}/exakit-legacy-out.XXXXXX" 2>/dev/null || true)"
    fi
    if [ -n "$_lex_state" ]; then
        ui_progress_state "$_lex_state" 0 0 1 "Copying $_lex_total table(s) out of the old database"
        ui_progress_begin "$_lex_state" "$(date +%s 2>/dev/null || echo 0)" && _lex_live=1
    fi
    for _lex_t in "$@"; do
        _lex_n=$(( _lex_n + 1 ))
        if [ "$_lex_live" = 1 ]; then
            ui_progress_state "$_lex_state" \
                $(( (_lex_n - 1) * 100 / _lex_total )) $(( _lex_n * 100 / _lex_total )) 4 \
                "Copying out $_lex_t ($_lex_n of $_lex_total)"
        fi
        _lex_schema="${_lex_t%%.*}"
        _lex_table="${_lex_t#*.}"
        # The file name is positional, not derived from the table name: a
        # schema or table with a dot, a slash or a space in it is legal in
        # Exasol and would otherwise escape the directory.
        _lex_file="$_lex_dir/t${_lex_n}.csv"
        EXAKIT_ACTIVE_LABEL="Copying out $_lex_t ($_lex_n/$_lex_total)"
        # THE TABLE IS NAMED AS A QUERY, WITH BOTH IDENTIFIERS QUOTED. `--table
        # S.T` hands exapump a bare name, and a schema or table that needs
        # quotes ("My Schema"."Sales 2025", legal in Exasol) never resolved: on
        # a real machine the export sat for its full 300 s timeout and the
        # table was reported as left behind. The restore has always quoted its
        # target the same way; the two halves now agree.
        if run_logged "$(exapump_cli)" export -p "$EXAKIT_LEGACY_PROFILE" \
                --query "SELECT * FROM \"$_lex_schema\".\"$_lex_table\"" --format csv -o "$_lex_file"; then
            _lex_ddl="$(legacy_table_ddl "$_lex_schema" "$_lex_table" 2>/dev/null || true)"
            # The index is read back by the other half, so it carries
            # everything that half needs: where the rows are, where they go,
            # and how to build the table that receives them.
            printf '%s\t%s\t%s\t%s\n' "t${_lex_n}.csv" "$_lex_schema" "$_lex_table" "$_lex_ddl" \
                >> "$_lex_dir/index"
            _lex_ok=$(( _lex_ok + 1 ))
        else
            # The partial file goes. exapump creates the output before it
            # knows the query works, so a failed export leaves a 0-byte file -
            # harmless (nothing indexes it) but alarming to find in a
            # directory whose whole job is holding someone's data.
            rm -f "$_lex_file"
            warn "Could not copy $_lex_t out of the old database — it is left there, untouched"
            _lex_bad=$(( _lex_bad + 1 ))
            # The NAME, not just a tally. This warning is one line inside a
            # progress bar during a long install, and it was the only place the
            # table was ever mentioned; the closing screen then reported the
            # crossing as done and offered to delete the container holding the
            # only remaining copy.
            _lex_bad_names="${_lex_bad_names} ${_lex_t}"
        fi
    done
    if [ "$_lex_live" = 1 ]; then
        ui_progress_end
        ok "Copied $_lex_ok of $_lex_total table(s) out"
    fi
    [ -n "$_lex_state" ] && rm -f "$_lex_state"
    EXAKIT_ACTIVE_LABEL=""
    manifest_set legacy.exported "$_lex_ok"
    if [ "$_lex_bad" -gt 0 ]; then
        manifest_set legacy.export_failed "$_lex_bad"
        # Recorded so the closing report can name them. legacy.export_failed
        # has been written since this function was introduced and read by
        # NOTHING - written here, asserted in two test files, and never
        # consulted by any product code.
        manifest_set legacy.export_failed_names "${_lex_bad_names# }"
    fi
    [ "$_lex_ok" -gt 0 ]
}

# legacy_new_db_answers — a real query against the NEW database through the
# kit's own profile: the gate in front of every restore.
# legacy_is_sample_table <SCHEMA.TABLE> — would a bundled dataset create this
# table? Then it is not restored.
#
# The unchanged sample tables never leave the old database at all (see
# legacy_classify). A CHANGED one does come across, and it used to be restored
# after the sample load, where the "this table already exists" gate kept the
# copy on disk instead of overwriting the kit's own. Restoring before that load
# moves the collision: the dataset's CREATE OR REPLACE would land on top of the
# user's rows minutes later. So the answer is the same either way - the copy is
# kept, the table is not restored, and the message says where it is - and now it
# does not depend on which of the two ran first.
legacy_is_sample_table() {
    _list_is_st="$(legacy_sample_catalog 2>/dev/null || true)"
    [ -n "$_list_is_st" ] || return 1
    printf '%s\n' "$_list_is_st" | cut -d'|' -f1 | grep -qx "$1"
}

legacy_new_db_answers() {
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "SELECT 'EXAKIT_NEW_OK' AS P" 2>/dev/null | grep -q 'EXAKIT_NEW_OK'
}

# legacy_import <dir> — the saved tables into the database that is now running.
#
# A table the fresh install has already created is SKIPPED, not appended to.
# The bundled sample data is loaded before this runs, so appending would double
# every row of every sample table a user also had.
legacy_import() {
    _lim_dir="$1"
    [ -s "$_lim_dir/index" ] || return 1
    # THE NEW DATABASE HAS TO ANSWER FIRST. A CREATE TABLE that fails is read
    # below as "already there" - and on a real machine every one of them failed
    # on authentication instead, so a database the kit could not reach reported
    # "Restored 0 table(s), Left alone: <every table>" and recorded the restore
    # as done. A copy that cannot land is kept and said so, never counted.
    legacy_new_db_answers || return 1
    _lim_ok=0; _lim_skipped=0; _lim_bad=0
    _lim_skipped_names=""
    # The same bar on the way back in. The total is the index's line count, so
    # a copy that failed halfway still reports against what there is to restore.
    _lim_total="$(grep -c . "$_lim_dir/index" 2>/dev/null || echo 0)"
    _lim_n=0
    _lim_state=""
    _lim_live=0
    if [ "${_lim_total:-0}" -gt 0 ]; then
        _lim_state="$(mktemp "${TMPDIR:-/tmp}/exakit-legacy-in.XXXXXX" 2>/dev/null || true)"
    fi
    if [ -n "$_lim_state" ]; then
        ui_progress_state "$_lim_state" 0 0 1 "Restoring $_lim_total table(s) into the new database"
        ui_progress_begin "$_lim_state" "$(date +%s 2>/dev/null || echo 0)" && _lim_live=1
    fi
    while IFS="$(printf '\t')" read -r _lim_file _lim_schema _lim_table _lim_ddl; do
        [ -n "$_lim_file" ] || continue
        # A line with fewer than three fields names no table. Without this a
        # truncated or hand-edited line whose first word happened to match a
        # file was uploaded into "".""; the PowerShell twin already refused it.
        [ -n "$_lim_schema" ] && [ -n "$_lim_table" ] || continue
        [ -f "$_lim_dir/$_lim_file" ] || continue
        _lim_target="\"$_lim_schema\".\"$_lim_table\""
        _lim_n=$(( _lim_n + 1 ))
        if [ "$_lim_live" = 1 ]; then
            ui_progress_state "$_lim_state" \
                $(( (_lim_n - 1) * 100 / _lim_total )) $(( _lim_n * 100 / _lim_total )) 4 \
                "Restoring $_lim_schema.$_lim_table ($_lim_n of $_lim_total)"
        fi
        # A TABLE A BUNDLED DATASET WILL CREATE IS LEFT IN THE COPY. The
        # restore runs before the sample load now, so "it already exists" no
        # longer catches this: the dataset's CREATE OR REPLACE would land on
        # top of these rows minutes later. The outcome is the one the old
        # ordering gave - the copy is kept and named - and it no longer depends
        # on which of the two ran first. (Unchanged sample tables never leave
        # the old database at all; see legacy_classify.)
        if legacy_is_sample_table "$_lim_schema.$_lim_table"; then
            _lim_skipped=$(( _lim_skipped + 1 ))
            _lim_skipped_names="$_lim_skipped_names $_lim_schema.$_lim_table"
            continue
        fi
        EXAKIT_ACTIVE_LABEL="Restoring $_lim_schema.$_lim_table"
        # CREATE SCHEMA is unconditional and harmless; CREATE TABLE is the test
        # for "does this already exist", so its failure is not an error here.
        run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
            "CREATE SCHEMA IF NOT EXISTS \"$_lim_schema\"" || true
        if [ -n "$_lim_ddl" ]; then
            if ! run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "$_lim_ddl"; then
                # Already there — the fresh install created it. Leave it alone.
                _lim_skipped=$(( _lim_skipped + 1 ))
                _lim_skipped_names="$_lim_skipped_names $_lim_schema.$_lim_table"
                continue
            fi
        fi
        if run_logged "$(exapump_cli)" upload -p "$EXAKIT_EXAPUMP_PROFILE" \
                --table "$_lim_target" "$_lim_dir/$_lim_file"; then
            _lim_ok=$(( _lim_ok + 1 ))
        else
            warn "Could not restore $_lim_schema.$_lim_table — the copy is kept at $(ui_tilde "$_lim_dir/$_lim_file")"
            _lim_bad=$(( _lim_bad + 1 ))
        fi
    done < "$_lim_dir/index"
    if [ "$_lim_live" = 1 ]; then
        ui_progress_end
    fi
    [ -n "$_lim_state" ] && rm -f "$_lim_state"
    EXAKIT_ACTIVE_LABEL=""
    manifest_set legacy.restored "$_lim_ok"
    [ "$_lim_skipped" -gt 0 ] && manifest_set legacy.restore_skipped "$_lim_skipped"
    [ "$_lim_bad" -gt 0 ] && manifest_set legacy.restore_failed "$_lim_bad"
    EXAKIT_LEGACY_RESTORED="$_lim_ok"
    EXAKIT_LEGACY_SKIPPED="$_lim_skipped"
    EXAKIT_LEGACY_SKIPPED_NAMES="$_lim_skipped_names"
    EXAKIT_LEGACY_RESTORE_FAILED="$_lim_bad"
    return 0
}

# legacy_crossing_before — the first half: say what was found, ask, copy out,
# stop the container. Never fails the install: every arm that cannot continue
# falls back to leaving the old database exactly where it is.
legacy_crossing_before() {
    # ASKED ONCE, AND ONLY WHERE THERE IS SOMETHING TO ASK ABOUT.
    #
    # Three gates, cheapest first, and all three are silent when they close.
    # An installer that announces "your database is in a container" to someone
    # whose container is long gone, or on every re-run after the crossing has
    # already happened, is a nag - and this code runs on EVERY install.
    #
    #   1. the record says this is not a legacy install       -> nothing
    #   2. the crossing already happened on this machine      -> nothing
    #   3. there is no readable database with tables in it    -> nothing
    #
    # Only past all three does anything reach the screen.
    legacy_db_recorded || return 0

    # THE OLD KIT'S STEP TICKS ARE NOT THIS KIT'S. Its manifest says "runtime"
    # is done - that was the container. Left in place, the deployment step was
    # skipped as already done, nothing ever recorded the new runtime, and every
    # later step talked to the new database with the old one's password (seen
    # on a real WSL machine: "SELECT 1 failed via profile 'starter-kit'"). The
    # ticks go for as long as the record still names the container - BEFORE
    # the crossing-done gate, because an install that crossed and then died
    # before its deployment step arrives here with the gate closed and the
    # ticks still standing.
    legacy_forget_old_steps

    # DONE MEANS ASKED AND ANSWERED, NOT "LEAVE THE PORT ALONE". The container
    # publishes the port the new deployment needs, so a crossing that is over
    # must still take it out of the way - without this the install died on
    # "port 8563 is in use" on every later run, with no way forward but a
    # docker stop by hand.
    if [ "$(manifest_get legacy.crossing_done 2>/dev/null || true)" = "true" ]; then
        legacy_stop_container >/dev/null 2>&1 || true
        return 0
    fi

    # An earlier attempt at THIS install already answered. Finish the leftover
    # work and say nothing: the question was asked, and asking again (or
    # narrating a resume) is the same nag from the other direction. The restore
    # half does the talking, because it has something to report.
    if [ -n "$(manifest_get legacy.choice 2>/dev/null || true)" ]; then
        EXAKIT_LEGACY_CHOICE="$(manifest_get legacy.choice)"
        _exakit_log_file "INFO  legacy crossing: resuming with choice=$EXAKIT_LEGACY_CHOICE" 2>/dev/null || true
        legacy_stop_container >/dev/null 2>&1 || true
        return 0
    fi

    _lcb_type="$(manifest_get runtime.type 2>/dev/null || true)"
    _lcb_container="$(legacy_container)"
    _lcb_state="$(legacy_container_state)"
    # The record, kept: the deployment step is about to overwrite runtime.*, and
    # `exakit migrate docker-nano` has to find the old database afterwards.
    legacy_remember_record

    # THE PROBE COMES BEFORE THE BANNER. Whether there is a database worth
    # talking about is answerable without saying a word, and if the answer is
    # no this function has nothing to tell anyone.
    # _lcb_retry SEPARATES A CONDITION FROM A DECISION. "There is nothing to
    # copy" is settled forever; "this machine cannot read it right now" is not,
    # and marking the second one done cost a user their data permanently: one
    # run could not see the engine, wrote the crossing off as finished, and no
    # later run - with the engine right there - ever offered again.
    _lcb_can=yes; _lcb_why=""; _lcb_retry=0
    if [ -z "$(legacy_engine)" ]; then
        _lcb_can=no; _lcb_retry=1; _lcb_why="the container engine this database needs is not on this machine any more"
    elif [ "$_lcb_state" = "absent" ]; then
        _lcb_can=no; _lcb_why="the container is gone, so there is nothing left to copy"
    elif [ "$_lcb_state" = "unknown" ]; then
        _lcb_can=no; _lcb_retry=1; _lcb_why="$(legacy_engine_name) is not answering (is Docker Desktop or the Podman machine running?)"
    elif ! command -v "$(exapump_cli)" >/dev/null 2>&1 && [ ! -x "$(exapump_cli)" ]; then
        _lcb_can=no; _lcb_retry=1; _lcb_why="exapump is not installed yet, and it is what reads the tables out"
    fi

    # A stopped container still holds the data, so it is started - but quietly,
    # and only once the gates above have said there is a point.
    _lcb_started=0
    if [ "$_lcb_can" = yes ] && [ "$_lcb_state" = "stopped" ]; then
        if legacy_start_container; then
            _lcb_started=1
        else
            _lcb_can=no; _lcb_retry=1; _lcb_why="the old container would not start"
        fi
    fi

    _lcb_tables=""
    if [ "$_lcb_can" = yes ]; then
        if legacy_write_profile; then
            # Up to two minutes, and only for a container this run just
            # started: one that was already running answers on the first ask.
            _lcb_budget="${EXAKIT_LEGACY_READY_TIMEOUT:-120}"
            [ "$_lcb_started" -eq 0 ] && _lcb_budget=10
            if legacy_wait_db_answers "$_lcb_budget"; then
                _lcb_tables="$(legacy_tables)"
            else
                _lcb_can=no; _lcb_retry=1; _lcb_why="the old database did not answer in time"
            fi
        else
            _lcb_can=no; _lcb_retry=1; _lcb_why="the password for the old database is not on file, so it cannot be read"
        fi
    fi

    # The kit's own sample data is not "my data": it is left out of the count
    # the user is asked about, and out of the copy.
    _lcb_total="$(legacy_count_lines "$_lcb_tables")"
    _lcb_sample=0
    if [ "$_lcb_can" = yes ]; then
        legacy_classify "$_lcb_tables"
        _lcb_sample="$(legacy_count_lines "$EXAKIT_LEGACY_SAMPLE_TABLES")"
    fi
    _lcb_count="$(legacy_count_lines "${EXAKIT_LEGACY_OWN_TABLES:-}")"
    if [ "$_lcb_can" = yes ] && [ "$_lcb_count" -eq 0 ]; then
        if [ "$_lcb_sample" -gt 0 ]; then
            _lcb_can=no; _lcb_why="the old database holds only the kit's bundled sample data ($EXAKIT_LEGACY_SAMPLE_IDS), unchanged, which this install loads itself"
        else
            _lcb_can=no; _lcb_why="the old database has no tables in it"
        fi
    fi

    # GATE 3. Nothing to offer, so nothing is said. The reason goes to the log,
    # where someone asking "why was I not offered a migration?" can find it,
    # and the crossing is marked done so this is never reconsidered.
    if [ "$_lcb_can" != yes ]; then
        _exakit_log_file "INFO  legacy crossing: no offer made — $_lcb_why" 2>/dev/null || true
        # Either way the container may be holding the port the new deployment
        # needs, whether or not its data could be read.
        legacy_stop_container >/dev/null 2>&1 || true
        if [ "$_lcb_retry" = 1 ]; then
            # A CONDITION, NOT A DECISION: nothing is recorded as chosen and
            # the crossing is not closed, so the next run - on a machine where
            # the obstacle is gone - asks the question this one could not.
            manifest_set legacy.offer_blocked "$_lcb_why"
            return 0
        fi
        manifest_set legacy.choice "skip"
        manifest_set legacy.crossed_from "$_lcb_type"
        [ "$_lcb_sample" -gt 0 ] && manifest_set legacy.sample_left_out "$EXAKIT_LEGACY_SAMPLE_IDS"
        manifest_set legacy.crossing_done true
        return 0
    fi

    # Past all three gates: there is a real database with real tables in it,
    # and this is the one and only time the user is asked about it.
    echo
    # ONE LINE, THEN THE QUESTION. This was six lines of explanation before a
    # yes/no - what the kit no longer manages, what it deploys instead, what
    # the copy costs, which tables are the kit's own, and a caveat about empty
    # strings - all of it ahead of a decision that needs the name, the size and
    # nothing else. What survives: the container, its state, and how much of
    # the user's own data is in it. The caveat moves to the copy itself, where
    # it is about to matter; the rest is in the docs.
    _lcb_schemas="$(printf '%s\n' "${EXAKIT_LEGACY_OWN_TABLES:-}" | sed -n 's/\..*$//p' | sort -u | grep -c . 2>/dev/null || echo 0)"
    _lcb_where=""
    [ -n "$_lcb_container" ] && _lcb_where=" in the container '$_lcb_container' ($_lcb_state)"
    _lcb_mine="$_lcb_count table(s)"
    [ "${_lcb_schemas:-0}" -gt 0 ] && _lcb_mine="$_lcb_mine in $_lcb_schemas schema(s)"
    _lcb_rest=""
    [ "$_lcb_sample" -gt 0 ] && _lcb_rest=" The other $_lcb_sample is the kit's own $EXAKIT_LEGACY_SAMPLE_IDS sample, which this install loads itself."
    # THE COPY IS MADE HERE, THE QUESTION IS ASKED LATER. This is the only
    # moment the old container can be read at all: it publishes the port, and
    # the deployment that is about to be installed needs that same port, so
    # from the next step onwards the container is stopped. Asking here meant
    # asking before the kit had installed a single thing - the first words of
    # the run, about a database the user may have forgotten they had.
    #
    # So the tables are read out now, into a 700 directory under the kit's own
    # home, and nothing is said about it; the question goes where it belongs,
    # after exapump and before the sample data (legacy_crossing_after), and a
    # "no" there deletes the copy. Nothing in the old container is changed
    # either way, and no data leaves this machine.
    manifest_set legacy.crossed_from "$_lcb_type"
    manifest_set legacy.tables_total "$_lcb_total"
    manifest_set legacy.tables_own "$_lcb_count"
    manifest_set legacy.tables_sample "$_lcb_sample"
    manifest_set legacy.container_state "$_lcb_state"
    [ "$_lcb_sample" -gt 0 ] && manifest_set legacy.sample_left_out "$EXAKIT_LEGACY_SAMPLE_IDS"

    # A COPY THAT IS ALREADY THERE IS NOT MADE AGAIN. A run that died between
    # the two halves comes back through here, and re-reading a database that
    # has not changed only overwrites a good copy with a second one - and, on a
    # resume, the container may no longer be able to answer at all. The waiting
    # copy is what the second half asks about.
    if [ -s "$EXAKIT_LEGACY_EXPORT_DIR/index" ] &&        [ -z "$(manifest_get legacy.restored 2>/dev/null || true)" ]; then
        _exakit_log_file "INFO  legacy crossing: a copy is already waiting at $EXAKIT_LEGACY_EXPORT_DIR" 2>/dev/null || true
        manifest_set legacy.export_dir "$EXAKIT_LEGACY_EXPORT_DIR"
        legacy_stop_container || true
        return 0
    fi

    # ONE ARGUMENT PER LINE, NOT PER WORD. The list is newline-separated
    # because a schema or table name may contain a space ("My Schema" is legal
    # in Exasol), and the first version of this handed the list to
    # legacy_export unquoted with the default IFS - so "My Schema.T" arrived as
    # two tables, "My" and "Schema.T", neither of which exists. Splitting on
    # newline alone keeps each name whole; -f keeps a name with a * or ? in it
    # from being expanded against the current directory.
    _lcb_ifs="$IFS"; IFS='
'
    set -f
    # shellcheck disable=SC2086
    legacy_export "$EXAKIT_LEGACY_EXPORT_DIR" $EXAKIT_LEGACY_OWN_TABLES
    _lcb_exported=$?
    set +f
    IFS="$_lcb_ifs"
    if [ "$_lcb_exported" -eq 0 ]; then
        manifest_set legacy.export_dir "$EXAKIT_LEGACY_EXPORT_DIR"
    else
        # Nothing could be read. There is nothing to offer later, and saying so
        # here would be the first line of the install, so it goes to the log;
        # the old container is left exactly as it was.
        # A CONDITION, NOT AN ANSWER. Recording "skip" here would put words in
        # the user's mouth and close the crossing for good; the reason is kept
        # and the question stays open, exactly as it does for an engine that
        # could not be found. `exakit migrate docker-nano` is the road once the
        # deployment holds the port.
        _exakit_log_file "WARN  legacy crossing: nothing could be copied out of $_lcb_container" 2>/dev/null || true
        manifest_set legacy.offer_blocked "nothing could be copied out of the old database"
    fi

    legacy_stop_container || true
    echo
    return 0
}

# legacy_crossing_after — the second half: the saved tables into the database
# this install just deployed. Reports what landed and what did not.
# legacy_crossing_after — THE QUESTION AND THE RESTORE, in the one place that
# can hold both: after exapump, before the sample data. The copy already exists
# (legacy_crossing_before read it out while the container still had the port),
# so this asks about something real and a "no" deletes it.
legacy_crossing_after() {
    _lca_dir="$(manifest_get legacy.export_dir 2>/dev/null || true)"
    [ -n "$_lca_dir" ] || return 0
    [ -s "$_lca_dir/index" ] || return 0
    [ "$(manifest_get legacy.restored 2>/dev/null || true)" = "" ] || return 0

    # NO NEW DATABASE, NO QUESTION. When the deployment step failed there is
    # nothing to restore into: asking "Migrate my data?" and then reporting
    # "could not be restored" read as data loss, while the copy was safe on
    # disk all along. Nothing is asked or recorded, so the next run starts the
    # crossing fresh and asks once the database is up. The old container was
    # stopped to free the port - it is started again, so the user is not left
    # with no database at all; the next run stops it again before deploying.
    # Twin of the same gate in Invoke-LegacyCrossingAfter.
    if exakit_soft_failed runtime; then
        echo
        _lca_container="$(legacy_container)"
        if [ -n "$_lca_container" ] && legacy_start_container >/dev/null 2>&1; then
            info "Your previous database ($_lca_container) is running again, with all its data, while the new one is not installed."
        fi
        info "Your data is safe: the copy is kept at $(ui_tilde "$_lca_dir"), and nothing in the old database was changed."
        info "Re-run the installer to finish - it offers to copy your data in once the new database is up: $(exakit_install_command)"
        return 0
    fi

    _lca_choice="$(manifest_get legacy.choice 2>/dev/null || true)"
    if [ -z "$_lca_choice" ]; then
        _lca_own="$(manifest_get legacy.tables_own 2>/dev/null || true)"
        _lca_sample="$(manifest_get legacy.tables_sample 2>/dev/null || true)"
        _lca_container="$(legacy_container)"
        # NOT the state it had when it was read: by the time this asks, the
        # container has been stopped so the deployment could take the port, and
        # printing "(running)" here said the opposite of what was true.
        # The schemas of the copy itself: column 2 of the index, which is what
        # was actually read out, not what the old database happened to hold.
        _lca_schemas="$(cut -f2 "$_lca_dir/index" 2>/dev/null | sort -u | grep -c . || echo 0)"
        _lca_where=""
        [ -n "$_lca_container" ] && _lca_where=" in the container '$_lca_container' (stopped for this install)"
        _lca_mine="${_lca_own:-0} table(s)"
        [ "${_lca_schemas:-0}" -gt 0 ] && _lca_mine="$_lca_mine in $_lca_schemas schema(s)"
        _lca_rest=""
        if [ "${_lca_sample:-0}" -gt 0 ]; then
            _lca_ids="$(manifest_get legacy.sample_left_out 2>/dev/null || true)"
            _lca_rest=" The other ${_lca_sample} is the kit's own ${_lca_ids} sample, which this install loads itself."
        fi
        echo
        info "Found your previous starter kit's database$_lca_where: $_lca_mine of your own.$_lca_rest"
        legacy_choose "${_lca_own:-0}" yes ""
        manifest_set legacy.choice "$EXAKIT_LEGACY_CHOICE"
        if [ "$EXAKIT_LEGACY_CHOICE" != "migrate" ]; then
            # A NO DELETES THE COPY. It was made without asking, so it does not
            # outlive the answer - and the old container still holds the
            # original, untouched.
            rm -rf "$_lca_dir" 2>/dev/null || true
            manifest_set legacy.export_dir ""
            manifest_set legacy.crossing_done true
            info "The old database is left exactly as it was, stopped, with its data."
            info "To copy it into the new database later: exakit migrate docker-nano"
            _lca_rm="$(legacy_remove_command 2>/dev/null || true)"
            [ -n "$_lca_rm" ] && info "When you no longer want it: $_lca_rm"
            echo
            return 0
        fi
        info "Nothing in the old database is changed. One thing to know: a text column that held an empty string arrives as NULL."
    else
        echo
        info "Restoring your data into the new database"
    fi

    legacy_import "$_lca_dir" || {
        warn "Your data could not be restored. The copy is kept at $(ui_tilde "$_lca_dir")."
        return 0
    }
    legacy_report_restore "$_lca_dir" "this install had already created them" || true
    manifest_set legacy.crossing_done true
    echo
    return 0
}

# legacy_report_restore <dir> <why-left-alone> — what landed and what did not,
# after legacy_import. Non-zero when something did not restore, so the copy is
# named as still needed.
legacy_report_restore() {
    _lrs_dir="$1"; _lrs_why="$2"
    ok "Restored ${EXAKIT_LEGACY_RESTORED:-0} table(s) from your previous database"
    if [ "${EXAKIT_LEGACY_SKIPPED:-0}" -gt 0 ]; then
        info "Left alone ($_lrs_why):${EXAKIT_LEGACY_SKIPPED_NAMES}"
    fi
    if [ "${EXAKIT_LEGACY_RESTORE_FAILED:-0}" -gt 0 ]; then
        warn "${EXAKIT_LEGACY_RESTORE_FAILED} table(s) did not restore — the copies are still at $(ui_tilde "$_lrs_dir")"
        return 1
    fi
    # TABLES THAT NEVER LEFT THE OLD DATABASE COUNT TOO. This function used to
    # tally only RESTORED / SKIPPED / RESTORE_FAILED, so a table that failed at
    # the EXPORT step was mentioned once, in a warn inside a progress bar,
    # during a long install - and then never again. The screen said "Restored 9
    # table(s)", called the copy no longer needed, and handed over the command
    # to delete the container that held the only surviving copy of the tenth.
    # The kit recorded the failure in legacy.export_failed and read it nowhere.
    _lrs_exfail="$(manifest_get legacy.export_failed 2>/dev/null || true)"
    if [ -n "$_lrs_exfail" ] && [ "$_lrs_exfail" -gt 0 ] 2>/dev/null; then
        _lrs_exnames="$(manifest_get legacy.export_failed_names 2>/dev/null || true)"
        warn "${_lrs_exfail} table(s) could NOT be copied out of the old database${_lrs_exnames:+: $_lrs_exnames}"
        warn "Those tables exist ONLY in the old container. Do not remove it until you have them."
        info "Try the copy again with: exakit migrate docker-nano"
        return 1
    fi
    # The copy is only removed once every table is accounted for - which now
    # means exported AND restored - and the old container still has the
    # original either way.
    info "The copy at $(ui_tilde "$_lrs_dir") is no longer needed; remove it whenever you like."
    _lrs_rm="$(legacy_remove_command 2>/dev/null || true)"
    [ -n "$_lrs_rm" ] && info "The old container still holds the original. To remove it: $_lrs_rm"
    return 0
}

# --- after the install: exakit migrate docker-nano --------------------------
#
# The crossing asks once, during an install. Someone who answered "skip" then
# and wants the data after all, or whose container the installer never saw (made
# by hand, or by the upstream kit on a machine this kit was installed fresh on),
# still has a database in a container - and this is the same copy, in one
# sitting: the old database is read, its tables restored into the deployment
# that is already running, the kit's own sample data left where it is.
#
# THE PORT IS THE COMPLICATION. Both databases want 8563. When the container
# publishes the deployment's port, the deployment is stopped for the copy out
# and started again before the copy in; when it does not (a container started
# on another port), nothing is stopped. The container itself ends as it began -
# except that one holding the deployment's port stays stopped, because the
# deployment has to have it back.
#
# Configured through the EXAKIT_LEGACY_* variables the accessors read, which the
# CLI fills from its options and from the record the crossing kept. Returns 0
# when done (or when there was nothing of the user's to copy), 1 when it failed,
# 5 when it was declined; EXAKIT_LEGACY_MIGRATE_STATUS and _REASON carry the
# outcome for the CLI's --json. Nothing here calls die(): the CLI decides how a
# failure is shown.
EXAKIT_LEGACY_MIGRATE_STATUS=""
EXAKIT_LEGACY_MIGRATE_REASON=""
EXAKIT_LEGACY_MIGRATE_REMEDY=""

_legacy_migrate_fail() {
    EXAKIT_LEGACY_MIGRATE_STATUS="failed"
    EXAKIT_LEGACY_MIGRATE_REASON="$1"
    EXAKIT_LEGACY_MIGRATE_REMEDY="${2:-}"
    error "$1"
    [ -n "${2:-}" ] && info "Then: $2"
    _exakit_log_file "ERROR legacy migrate: $1" 2>/dev/null || true
    return 1
}

# legacy_wait_port_free <port> <seconds> — 0 once nothing listens on the port.
legacy_wait_port_free() {
    _lwp_n=0
    while port_in_use "$1" 2>/dev/null; do
        _lwp_n=$(( _lwp_n + 1 ))
        [ "$_lwp_n" -ge "$2" ] && return 1
        sleep 1
    done
    return 0
}

# _legacy_migrate_settle — everything back the way it was found, except a
# container on the deployment's port, which stays stopped so the deployment can
# have the port back. Reads the _lmn_* state legacy_migrate_now sets. Non-zero
# when the deployment did not come back.
_legacy_migrate_settle() {
    if [ "${_lmn_started:-0}" = 1 ] || [ "${_lmn_clash:-0}" = 1 ]; then
        legacy_stop_container >/dev/null 2>&1 || true
    fi
    if [ "${_lmn_db_stopped:-0}" = 1 ] || ! personal_deployment_running >/dev/null 2>&1; then
        EXAKIT_ACTIVE_LABEL="Starting your database again"
        personal_start && personal_wait_ready
    fi
}

# legacy_migrate_now <yes:0|1>
legacy_migrate_now() {
    _lmn_yes="${1:-0}"
    EXAKIT_LEGACY_MIGRATE_STATUS=""; EXAKIT_LEGACY_MIGRATE_REASON=""; EXAKIT_LEGACY_MIGRATE_REMEDY=""
    EXAKIT_LEGACY_RESTORED=0; EXAKIT_LEGACY_SKIPPED=0; EXAKIT_LEGACY_RESTORE_FAILED=0
    EXAKIT_LEGACY_EXPORTED=0; EXAKIT_LEGACY_SAMPLE_IDS=""
    _lmn_container="$(legacy_container)"
    _lmn_engine_name="$(legacy_engine_name)"
    [ -n "$_lmn_container" ] || { _legacy_migrate_fail "No container is named. Say which one holds the old database: exakit migrate docker-nano --container <name>"; return 1; }
    [ -n "$(legacy_engine)" ] || { _legacy_migrate_fail "The container engine '${_lmn_engine_name:-?}' is not on this machine, so the container '$_lmn_container' cannot be reached." "exakit migrate docker-nano --engine docker|podman"; return 1; }
    _lmn_state="$(legacy_container_state)"
    case "$_lmn_state" in
        absent)  _legacy_migrate_fail "There is no container named '$_lmn_container' in $_lmn_engine_name. List them with '$_lmn_engine_name ps -a' and name the right one with --container." ; return 1 ;;
        unknown) _legacy_migrate_fail "$_lmn_engine_name did not answer about the container '$_lmn_container' - it looks stopped. Start it (Docker Desktop, or: podman machine start), then run: exakit migrate docker-nano" ; return 1 ;;
    esac
    _lmn_exapump="$(exapump_cli)"
    if ! command -v "$_lmn_exapump" >/dev/null 2>&1 && [ ! -x "$_lmn_exapump" ]; then
        _legacy_migrate_fail "exapump is not installed, and it is what reads the tables out." "exakit update"
        return 1
    fi

    # A copy from an earlier run that never landed is finished first: it is
    # the user's data, waiting, and a fresh copy over it would destroy it.
    _lmn_dir="$EXAKIT_LEGACY_EXPORT_DIR"
    if [ -s "$_lmn_dir/index" ] && [ -z "$(manifest_get legacy.restored 2>/dev/null || true)" ]; then
        info "A copy from an earlier run is waiting at $(ui_tilde "$_lmn_dir") — restoring it first"
        if ! legacy_import "$_lmn_dir"; then
            _legacy_migrate_fail "The waiting copy could not be restored; it is kept at $(ui_tilde "$_lmn_dir")."
            return 1
        fi
        # The report's verdict decides whether this WAS a crossing. `|| true`
        # here used to discard it, so a run that left tables behind still set
        # crossing_done and answered "done" - and crossing_done is what stops
        # the installer ever offering the crossing again.
        if legacy_report_restore "$_lmn_dir" "the new database already had them"; then
            manifest_set legacy.choice "migrate"
            manifest_set legacy.crossing_done true
            info "Run the command again for a fresh copy of what is in the container now."
            EXAKIT_LEGACY_MIGRATE_STATUS="done"
            return 0
        fi
        manifest_set legacy.choice "migrate"
        EXAKIT_LEGACY_MIGRATE_STATUS="partial"
        EXAKIT_LEGACY_MIGRATE_REMEDY="exakit migrate docker-nano"
        return 1
    fi

    # THE PORT. The container's published port against the deployment's.
    _lmn_dsn="$(legacy_dsn)"
    _lmn_port="${_lmn_dsn##*:}"
    _lmn_db_port="$(personal_db_port 2>/dev/null || printf '%s' "${EXAKIT_PERSONAL_PORT:-8563}")"
    _lmn_clash=0
    [ "$_lmn_port" = "$_lmn_db_port" ] && _lmn_clash=1
    _lmn_db_running=0
    personal_deployment_running >/dev/null 2>&1 && _lmn_db_running=1

    echo
    info "Copying the tables of the container '$_lmn_container' ($_lmn_engine_name, $_lmn_state) into your database."
    info "The kit's bundled sample data is left out — the kit loads that itself. Nothing in the container is changed or removed."
    info "One caveat worth knowing: a text column that held an empty string arrives as NULL."
    if [ "$_lmn_clash" = 1 ] && [ "$_lmn_db_running" = 1 ]; then
        warn "The container publishes port $_lmn_port, the port your database uses, so the two cannot run at once."
        info "Your database is stopped while the tables are copied out, and started again before they are copied in."
    fi
    if [ "$_lmn_yes" != 1 ]; then
        if ! confirm "Go ahead?" y; then
            info "Nothing was changed."
            EXAKIT_LEGACY_MIGRATE_STATUS="declined"
            return 5
        fi
    fi

    _lmn_db_stopped=0
    if [ "$_lmn_clash" = 1 ] && [ "$_lmn_db_running" = 1 ]; then
        EXAKIT_ACTIVE_LABEL="Stopping your database for the copy"
        if ! personal_stop; then
            _legacy_migrate_fail "Your database could not be stopped, so the container cannot take the port." "exakit stop, then exakit migrate docker-nano"
            return 1
        fi
        _lmn_db_stopped=1
        # THE PORT MAY STILL BE HELD after the stop: the launcher can leave its
        # runner or its port forwarder alive (seen on a real WSL machine, where
        # `exakit stop` answered "stopped" and the container then could not
        # bind). A moment's grace, then the kit's own orphan reaper - it only
        # ever touches the kit's own runner - and a port that stays held is
        # named for what it is, not blamed on the container.
        if ! legacy_wait_port_free "$_lmn_db_port" 15; then
            command -v personal_reap_orphan_daemon >/dev/null 2>&1 && personal_reap_orphan_daemon >/dev/null 2>&1
            if ! legacy_wait_port_free "$_lmn_db_port" 5; then
                personal_start >/dev/null 2>&1 || true
                _lmn_holder=""
                command -v personal_port_holder_hint >/dev/null 2>&1 && _lmn_holder="$(personal_port_holder_hint 2>/dev/null || true)"
                _legacy_migrate_fail "Your database was told to stop, but port $_lmn_db_port is still held$_lmn_holder, so the old container cannot take it." "exakit stop, then check the port (ss -ltnp | grep $_lmn_db_port) before: exakit migrate docker-nano"
                return 1
            fi
        fi
    fi
    _lmn_started=0
    if [ "$_lmn_state" != "running" ]; then
        info "Starting the container '$_lmn_container'"
        if ! legacy_start_container; then
            [ "$_lmn_db_stopped" = 1 ] && { personal_start || true; }
            _legacy_migrate_fail "The container '$_lmn_container' would not start (see '$_lmn_engine_name logs $_lmn_container')."
            return 1
        fi
        _lmn_started=1
    fi
    _lmn_ok=0
    if ! legacy_write_profile; then
        _lmn_why="The password of the old database is not on file. Pass it with --password-file <path> (a file holding only the password), or answer the prompt on a terminal."
    else
        _lmn_budget="${EXAKIT_LEGACY_READY_TIMEOUT:-120}"
        [ "$_lmn_started" -eq 0 ] && _lmn_budget=10
        EXAKIT_ACTIVE_LABEL="Waiting for the old database to answer"
        if legacy_wait_db_answers "$_lmn_budget"; then
            _lmn_ok=1
        else
            _lmn_why="The old database did not answer within ${_lmn_budget}s. Is the password right, and is $_lmn_dsn where the container listens ('$_lmn_engine_name port $_lmn_container')?"
        fi
    fi
    if [ "$_lmn_ok" != 1 ]; then
        _legacy_migrate_settle || true
        _legacy_migrate_fail "$_lmn_why"
        return 1
    fi

    _lmn_tables="$(legacy_tables)"
    _lmn_total="$(legacy_count_lines "$_lmn_tables")"
    legacy_classify "$_lmn_tables"
    _lmn_sample="$(legacy_count_lines "$EXAKIT_LEGACY_SAMPLE_TABLES")"
    _lmn_own="$(legacy_count_lines "$EXAKIT_LEGACY_OWN_TABLES")"
    [ "$_lmn_sample" -gt 0 ] && manifest_set legacy.sample_left_out "$EXAKIT_LEGACY_SAMPLE_IDS"
    if [ "$_lmn_own" -eq 0 ]; then
        if [ "$_lmn_sample" -gt 0 ]; then
            info "The container holds $_lmn_total table(s), all of them the kit's bundled sample data ($EXAKIT_LEGACY_SAMPLE_IDS), unchanged — nothing of yours to copy."
            info "The kit loads that data itself: exakit data-load"
        else
            info "The old database has no tables in it — nothing to copy."
        fi
        _legacy_migrate_settle || true
        manifest_set legacy.choice "migrate"
        manifest_set legacy.crossing_done true
        EXAKIT_LEGACY_MIGRATE_STATUS="nothing"
        return 0
    fi

    info "The container holds $_lmn_total table(s)."
    [ "$_lmn_sample" -gt 0 ] && legacy_sample_note "$_lmn_own" "$_lmn_sample"
    # A copy that was restored before is spent; its files go before the new one
    # lands, or a smaller export would leave the old one's tail beside it.
    [ -s "$_lmn_dir/index" ] && rm -rf "$_lmn_dir"
    manifest_del legacy.restored 2>/dev/null || true
    manifest_del legacy.restore_skipped 2>/dev/null || true
    manifest_del legacy.restore_failed 2>/dev/null || true
    info "Copying $_lmn_own table(s) out of the old database"
    _lmn_ifs="$IFS"; IFS='
'
    set -f
    # shellcheck disable=SC2086
    legacy_export "$_lmn_dir" $EXAKIT_LEGACY_OWN_TABLES
    _lmn_exported=$?
    set +f
    IFS="$_lmn_ifs"
    EXAKIT_LEGACY_EXPORTED="$(manifest_get legacy.exported 2>/dev/null || printf '0')"
    if [ "$_lmn_exported" -ne 0 ]; then
        _legacy_migrate_settle || true
        _legacy_migrate_fail "Nothing could be copied out. The old database is untouched; nothing is lost."
        return 1
    fi
    manifest_set legacy.export_dir "$_lmn_dir"
    ok "Copied ${EXAKIT_LEGACY_EXPORTED} table(s) out; they are saved at $(ui_tilde "$_lmn_dir")"

    if ! _legacy_migrate_settle; then
        _legacy_migrate_fail "Your database did not come back, so the copy is not restored yet. It is kept at $(ui_tilde "$_lmn_dir")." "exakit start, then exakit migrate docker-nano"
        return 1
    fi
    info "Restoring your data into the new database"
    if ! legacy_import "$_lmn_dir"; then
        _legacy_migrate_fail "Your data could not be restored. The copy is kept at $(ui_tilde "$_lmn_dir")." "exakit migrate docker-nano"
        return 1
    fi
    manifest_set legacy.choice "migrate"
    manifest_set legacy.crossing_done true
    manifest_set legacy.migrated_at "$(_exakit_ts 2>/dev/null || true)"
    if legacy_report_restore "$_lmn_dir" "the new database already had them"; then
        EXAKIT_LEGACY_MIGRATE_STATUS="done"
        return 0
    fi
    EXAKIT_LEGACY_MIGRATE_STATUS="partial"
    # WHICHEVER HALF FAILED. This said "N table(s) did not restore"
    # unconditionally, so a crossing that was partial because a table never
    # came OUT of the old database reported "0 table(s) did not restore" - a
    # sentence that is both wrong and reassuring.
    _lmn_exfail="$(manifest_get legacy.export_failed 2>/dev/null || true)"
    if [ -n "$_lmn_exfail" ] && [ "$_lmn_exfail" -gt 0 ] 2>/dev/null; then
        EXAKIT_LEGACY_MIGRATE_REASON="${_lmn_exfail} table(s) could not be copied out of the old database and are still only there"
    else
        EXAKIT_LEGACY_MIGRATE_REASON="${EXAKIT_LEGACY_RESTORE_FAILED} table(s) did not restore"
    fi
    EXAKIT_LEGACY_MIGRATE_REMEDY="exakit migrate docker-nano"
    return 1
}
