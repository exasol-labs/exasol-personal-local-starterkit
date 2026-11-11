#!/usr/bin/env bash
# virtual-schemas.sh — `exakit connect` and `exakit source <action>`: query an
# external database from the local one through an Exasol virtual schema.
#
# Sourced by exakit after common.sh, detect.sh, runtime-personal.sh and
# pyexasol.sh. ⇄ twin: virtual-schemas.ps1. The work is the shared Python
# engine in setup/virtual-schemas/engine, run with the kit's pyexasol
# interpreter; this file supplies the deployment, asks the questions, keeps
# secrets off the command line, and repairs the two things the engine
# reports but cannot fix from inside the database:
#
#   exit 20  Java in the database has no DNS resolver -> personal_slc_dns_repair, retry once
#            (Docker: the fix is in the image - one restart, then the retry)
#   exit 21  the Java language container is missing   -> `exasol slc install java`, retry once
#
# A person connecting at a terminal is not asked before either: picking the
# source was the permission, so the step is said and made (_exakit_vs_interactive).
# A script (--json, or no terminal) keeps its contract: --yes, else the exit
# code and its remedy.

# exakit_vs_defs — the folder that holds catalog.json, profiles/, connectors/.
exakit_vs_defs() {
    _evd_root="$(exakit_repo_root 2>/dev/null || true)"
    if [ -n "$_evd_root" ] && [ -f "$_evd_root/setup/virtual-schemas/catalog.json" ]; then
        printf '%s\n' "$_evd_root/setup/virtual-schemas"
        return 0
    fi
    _evd_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [ -f "$_evd_here/virtual-schemas/catalog.json" ] || return 1
    printf '%s\n' "$_evd_here/virtual-schemas"
}

# exakit_vs_available — can a source be connected from here? The definitions
# are in this kit copy and the kit's pyexasol, which runs the engine, exists.
exakit_vs_available() {
    exakit_vs_defs >/dev/null 2>&1 || return 1
    command -v pyexasol_venv_python >/dev/null 2>&1 || return 1
    _eva_py="$(pyexasol_venv_python 2>/dev/null || true)"
    [ -n "$_eva_py" ] && [ -x "$_eva_py" ]
}

# exakit_vs_unavailable_reason — why exakit_vs_available said no, in the few
# words the data table's disabled row has room for (the whole label stays
# inside the name column of an 80-column table).
exakit_vs_unavailable_reason() {
    if ! exakit_vs_defs >/dev/null 2>&1; then
        printf 'unavailable\n'
    else
        printf 'no pyexasol\n'
    fi
}

# _exakit_vs_cli — the kit's own command beside this library (setup/exakit).
# It loads THIS library (its lib/ comes first), so it is the same kit version
# as the installer that sourced it, whatever the kit home holds yet.
_exakit_vs_cli() {
    _evc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || return 1
    [ -f "$_evc_dir/exakit" ] || return 1
    printf '%s\n' "$_evc_dir/exakit"
}

# exakit_vs_connect_wizard — the data-load row: `exakit connect` asking for
# everything, the same as typed with no arguments. Run in a subshell by the
# caller, since cmd_connect exits. Inside exakit (`exakit data-load`) that is
# cmd_connect itself. The installer sources this file too, but cmd_connect
# needs what only the command defines (_require_install and the rest), and the
# installed command reads the kit home, which the installer's last step
# refreshes (kit_helper_step). So there the wizard is the command beside this
# library, as a child: the same kit version as the installer.
#
# The child reads the terminal. `exakit connect` draws its menu and panels only
# when stdin is one (_exakit_vs_tui_ok), and the installer's stdin is not
# always: its data step runs inside exakit_persona_flow's read loop, whose
# stdin is that loop's here-document, and a setup script started from a pipe
# (`curl ... | sh` without install.sh's own </dev/tty) has the pipe. Either way
# the child took the line-by-line questions instead of the table `exakit
# connect` and `exakit data-load` show. Only stdin is handed over: stdout is
# the terminal already wherever the row can be picked, and nothing else is
# redirected, so the install log is untouched.
exakit_vs_connect_wizard() {
    if [ "$(type -t _require_install 2>/dev/null)" = function ]; then
        cmd_connect
        return $?
    fi
    _evw_cli="$(_exakit_vs_cli)" || {
        warn "This kit copy has no exakit command beside its library."
        return 2
    }
    if [ ! -t 0 ] && (: < /dev/tty) 2>/dev/null; then
        "${BASH:-bash}" "$_evw_cli" connect < /dev/tty
    else
        "${BASH:-bash}" "$_evw_cli" connect
    fi
}

# _exakit_vs_kit_python — the kit's pyexasol interpreter, which the engine and
# the credential reader run on; nothing (return 1) when it is not installed.
_exakit_vs_kit_python() {
    _ekp_py=""
    command -v pyexasol_venv_python >/dev/null 2>&1 && _ekp_py="$(pyexasol_venv_python 2>/dev/null || true)"
    [ -n "$_ekp_py" ] && [ -x "$_ekp_py" ] || return 1
    printf '%s\n' "$_ekp_py"
}

# _exakit_vs_python <interpreter> <args...> — Python as everything that holds
# a credential runs it. -I (isolated) ignores every PYTHON* variable
# (PYTHONPATH, PYTHONHOME, PYTHONSTARTUP, ...), the user's site-packages and
# the script's own folder. It does NOT stop a macOS framework build taking its
# program path from PYTHONEXECUTABLE (or __PYVENV_LAUNCHER__), and that path
# decides sys.prefix: another venv's site-packages, whose .pth files run code
# at startup (measured with Homebrew's 3.14). So both are unset - in a
# subshell, so this shell keeps them.
_exakit_vs_python() {
    ( unset PYTHONEXECUTABLE __PYVENV_LAUNCHER__
      _evy_bin="$1"; shift
      exec "$_evy_bin" -I "$@" )
}

# exakit_vs_engine <args...> — the engine with this installation's context.
# Its stdin is passed through: that is where a secret travels. Every engine
# run (catalog, resolve, inputs, field, paste, plan, connect, the source
# commands, the terminal form) comes through here, on _exakit_vs_python.
# cli.py puts its own folder on sys.path, which -I leaves off.
exakit_vs_engine() {
    _eve_defs="$(exakit_vs_defs)" || {
        _exakit_vs_unrunnable "This kit copy has no setup/virtual-schemas. Update it: exakit update" \
            "this kit copy has no setup/virtual-schemas" "update the kit: exakit update" "exakit update"
        return 2; }
    _eve_py="$(_exakit_vs_kit_python)" || {
        _exakit_vs_unrunnable "Virtual schemas run with the kit's pyexasol, which is not installed. Repair it: exakit update pyexasol" \
            "virtual schemas run with the kit's pyexasol, which is not installed" \
            "repair it: exakit update pyexasol" "exakit update pyexasol"
        return 2; }
    # This run's engine choice, passed on even when the shell set it itself:
    # where personal_slc_dns_engine falls back to it, so does the engine
    # (plan.py recorded_engine), and --json names the fix the bridge says.
    EXAKIT_PERSONAL_ENGINE="${EXAKIT_PERSONAL_ENGINE:-}" \
    _exakit_vs_python "$_eve_py" "$_eve_defs/engine/cli.py" --defs "$_eve_defs" --kit-home "$EXAKIT_HOME" \
        --deployment-dir "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" \
        --dsn "$(manifest_get runtime.dsn 2>/dev/null || true)" \
        --user "$(manifest_get runtime.user 2>/dev/null || printf sys)" \
        --password-file "$(manifest_get runtime.password_file 2>/dev/null || true)" "$@"
}

# _exakit_vs_json_failure <kind> <error> <remedy> [command] — the engine's
# failure shape (cli.py) for what the bridge refuses or cannot run itself, so
# `--json` is one object of one shape whoever said no: what happened, its
# class, the fix in words, the one exakit command that is the fix or null.
# rejected and public_ip as the other refusals and plan/connect carry them.
_exakit_vs_json_failure() {
    _ejf_cmd="null"
    [ -n "${4:-}" ] && _ejf_cmd="\"$(_exakit_json_string "$4")\""
    exakit_json_out '{"ok": false, "error": "%s", "kind": "%s", "remedy": "%s", "command": %s, "rejected": true, "public_ip": null}\n' \
        "$(_exakit_json_string "$2")" "$1" "$(_exakit_json_string "$3")" "$_ejf_cmd"
}

# _exakit_vs_refuse <exit> <message> <error> <remedy> [command] — the bridge
# says no before the engine runs: the message on a screen as always (reject's
# card for bad input, exit 2), with --json the failure object instead. Exits.
_exakit_vs_refuse() {
    if [ "${EXAKIT_VS_JSON:-0}" = 1 ]; then
        _exakit_log_file "REJECT $2"
        _exakit_vs_json_failure input "$3" "$4" "${5:-}"
        exit "$1"
    fi
    [ "$1" = 2 ] && reject "$2"
    error "$2"
    exit "$1"
}

# _exakit_vs_credential_argument — a credential given as an option on the
# command line (--password=..., --passwd ..., --secret..., --token...): refused
# without repeating any of it, since argv is readable by every local user.
_exakit_vs_credential_argument() {
    _exakit_vs_refuse 2 "A credential is never taken as an argument (other users can read the process list). Use the hidden prompt, --password-file, or --password-stdin." \
        "a credential was given as an argument, where other users can read it in the process list" \
        "pipe it in with --password-stdin or give it with --password-file <file>"
}

# _exakit_vs_no_tmp — mktemp failed. With --json that is the one object (kind
# setup), and 0: the caller then exits 1. Without, 1: the caller says what it
# always said.
_exakit_vs_no_tmp() {
    [ "${EXAKIT_VS_JSON:-0}" = 1 ] || return 1
    _exakit_log_file "ERROR Could not create a temporary file."
    _exakit_vs_json_failure setup "could not create a temporary file" \
        "check that the temporary folder (TMPDIR, else /tmp) exists, is writable and has space, then run the same command again"
}

# _exakit_vs_unrunnable <message> <error> <remedy> <command> — the engine cannot
# run from this kit copy: said on stderr, and with --json as the one object.
_exakit_vs_unrunnable() {
    if [ "${EXAKIT_VS_JSON:-0}" = 1 ]; then
        _exakit_log_file "ERROR $1"
        _exakit_vs_json_failure setup "$2" "$3" "$4"
        return 0
    fi
    error "$1"
}

# exakit_vs_log_path — the engine's day log (virtual-schemas-YYYYMMDD.log in
# the kit's log folder, written by engine/vslog.py: every statement it sent
# and every event, secrets redacted), the newest one; nothing when there is none.
exakit_vs_log_path() {
    ls -t "${EXAKIT_LOG_DIR:-$EXAKIT_HOME/logs}"/virtual-schemas-*.log 2>/dev/null | head -n 1
}

# _exakit_vs_log_mark — what that log is now (path:size), kept in
# EXAKIT_VS_LOG_MARK so the end of the command can tell whether this run wrote
# to it: a lookup or a refusal the engine never logged points at no log.
_exakit_vs_log_mark() {
    _evm_path="$(exakit_vs_log_path)"
    EXAKIT_VS_LOG_MARK=""
    [ -n "$_evm_path" ] && EXAKIT_VS_LOG_MARK="$_evm_path:$(wc -c < "$_evm_path" 2>/dev/null | tr -d ' ')"
    return 0
}

# _exakit_vs_exit <code> — end a connect or source command. A failure (not 5,
# a question not confirmed or a gated source) that the engine logged names the
# log once, so the statements it sent are one command away; with --json on
# stderr, which no parser reads. An empty file names nothing (the Windows
# twin makes today's ready before every engine run). ⇄ twin: Exit-ExakitVs.
_exakit_vs_exit() {
    case "$1" in 0|5) exit "$1" ;; esac
    _eve_path="$(exakit_vs_log_path)"
    if [ -n "$_eve_path" ] && [ -s "$_eve_path" ] && \
       [ "$_eve_path:$(wc -c < "$_eve_path" 2>/dev/null | tr -d ' ')" != "${EXAKIT_VS_LOG_MARK:-}" ]; then
        if [ "${EXAKIT_VS_JSON:-0}" = 1 ]; then
            printf 'Log (every SQL statement, secrets redacted): %s\n' "$_eve_path" >&2
        else
            info "Log (every SQL statement, secrets redacted): $_eve_path"
        fi
    fi
    exit "$1"
}

# _exakit_vs_render — the engine's event lines in the kit's own marks; the
# RESULT line is kept in EXAKIT_VS_RESULT for the caller.
_exakit_vs_render() {
    EXAKIT_VS_RESULT=""
    while IFS= read -r _evr_line || [ -n "$_evr_line" ]; do
        case "$_evr_line" in
            "OK "*)     ok "${_evr_line#OK }" ;;
            "INFO "*)   info "${_evr_line#INFO }" ;;
            "WARN "*)   warn "${_evr_line#WARN }" ;;
            "FAIL "*)   error "${_evr_line#FAIL }" ;;
            "RESULT "*) EXAKIT_VS_RESULT="${_evr_line#RESULT }" ;;
            *) [ -n "$_evr_line" ] && printf '%s\n' "$_evr_line" ;;
        esac
    done < "$1"
}

# _exakit_vs_secret_text — a credential's bytes (stdin) as UTF-8 on stdout, by
# the rules the engine and the Windows bridge read one with (engine/cli.py
# decode_secret, ConvertFrom-ExakitVsSecretBytes): UTF-16 by its byte-order
# mark (Windows PowerShell 5.1 writes `>` so), else UTF-8 with or without one,
# and no NUL anywhere. Checked HERE, before $( ) takes it: a shell variable
# drops NUL bytes without a word, and the engine would get another credential.
# Nothing is written when it fails: 3 the bytes are not such text, 4 the
# kit's pyexasol (the engine's own Python) did not run; the caller ends the
# command with _exakit_vs_secret_failed.
_exakit_vs_secret_text() {
    _est_py="$(_exakit_vs_kit_python)" || return 4
    _exakit_vs_python "$_est_py" -c 'import codecs, sys
raw = sys.stdin.buffer.read()
try:
    text = raw.decode("utf-16") if raw[:2] in (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE) else raw.decode("utf-8-sig")
except UnicodeDecodeError:
    sys.exit(3)
if "\0" in text:
    sys.exit(3)
sys.stdout.buffer.write(text.encode("utf-8"))'
    case "$?" in 0) return 0 ;; 3) return 3 ;; *) return 4 ;; esac
}

# _exakit_vs_secret_failed <code> — end the command for a credential reader
# that failed inside a $( ), where it could not refuse itself: 3 not UTF-8 or
# UTF-16 text, 4 the kit's Python did not run; any other code the reader has
# said already. Exit 2, with --json the one object (rejected, as PowerShell's).
_exakit_vs_secret_failed() {
    case "$1" in
        3) _exakit_vs_refuse 2 "The credential is not UTF-8 or UTF-16 text (another encoding, or a NUL byte): save it as UTF-8 (UTF-16 needs its byte-order mark)." \
               "the credential is not UTF-8 or UTF-16 text" \
               "save the credential as UTF-8 (UTF-16 needs its byte-order mark), then run the same command again" ;;
        4) _exakit_vs_unrunnable "The credential is read with the kit's pyexasol, which did not run. Repair it: exakit update pyexasol" \
               "the credential is read with the kit's pyexasol, which did not run" \
               "repair it: exakit update pyexasol" "exakit update pyexasol" ;;
    esac
    exit 2
}

# _exakit_vs_quiet — the rest of a connect or source command is not traced
# (bash -x): a credential passes through most of it - an assignment, the
# printf that hands it to the engine. Those commands end in exit, so there
# is nothing to turn back on. Every name that holds a credential, a pasted
# connection string or a typed answer is unset first: an exported one (even
# empty) stays exported when assigned, and every child would see the value.
_exakit_vs_quiet() {
    case "$-" in *x*) { set +x; } 2>/dev/null ;; esac
    unset EXAKIT_VS_STDIN_SECRET _cc_secret _cc_storage _cs_storage _evo_storage _cs_secret _evx_secret _evo_secret _evo_v _EVH_LINE _EVT_ANSWER \
        _eap_url _etf_v _erh_value _EVP_SECRET
    # This command's own answers only. A public IP looked up by an earlier
    # command reaches later ones through the processes it started (a restart's
    # `exakit start` brings back the add-on services with it), and could name a
    # network this computer has left. A person's go-ahead is never inherited.
    unset _EXAKIT_VS_PUBLIC_IP _EXAKIT_VS_INTERACTIVE
}

# _exakit_vs_stdin_secret — --password-stdin: ALL of standard input, read even
# when a terminal is reachable (a JSON key file has line breaks), one trailing
# line ending (LF or CRLF) dropped here and any others by the engine
# (cli.py read_secret), into EXAKIT_VS_STDIN_SECRET. Run in the
# command's own shell, never in $( ): a refusal must end the command, and
# with --json its one object must reach stdout. Refuses (exit 2) a terminal on
# stdin - the flag means a pipe or a file - and nothing read. Never echoed,
# logged or passed as an argument. ⇄ twin: Read-ExakitVsStdinSecret.
_exakit_vs_stdin_secret() {
    if [ -t 0 ]; then
        _exakit_vs_refuse 2 "--password-stdin reads the credential from standard input, which is a terminal here: pipe it in (for example < key.json), or leave --password-stdin out to be asked." \
            "--password-stdin was given, but standard input is a terminal" \
            "pipe the credential into the command (for example < key.json), or give it with --password-file <file>"
    fi
    # Unset first: an exported name stays exported when assigned. The dot keeps
    # the line endings $( ) would take; one is dropped below.
    unset EXAKIT_VS_STDIN_SECRET
    EXAKIT_VS_STDIN_SECRET="$(_exakit_vs_secret_text; _esi_rc=$?; printf .; exit "$_esi_rc")"
    _esi_rc=$?
    [ "$_esi_rc" = 0 ] || { unset EXAKIT_VS_STDIN_SECRET; _exakit_vs_secret_failed "$_esi_rc"; }
    EXAKIT_VS_STDIN_SECRET="${EXAKIT_VS_STDIN_SECRET%.}"
    _esi_lf='
'
    _esi_crlf="$(printf '\r')$_esi_lf"
    case "$EXAKIT_VS_STDIN_SECRET" in
        *"$_esi_crlf") EXAKIT_VS_STDIN_SECRET="${EXAKIT_VS_STDIN_SECRET%"$_esi_crlf"}" ;;
        *"$_esi_lf") EXAKIT_VS_STDIN_SECRET="${EXAKIT_VS_STDIN_SECRET%"$_esi_lf"}" ;;
    esac
    [ -n "$EXAKIT_VS_STDIN_SECRET" ] || _exakit_vs_refuse 2 "--password-stdin read nothing: standard input was empty." \
        "--password-stdin was given, but standard input was empty" \
        "pipe the credential into the command and close the pipe once it is written, or give it with --password-file <file>"
    return 0
}

# _exakit_vs_read_secret <label> <password-file> [kind] — a secret, from the
# file the caller named, else a hidden prompt, else stdin. Never from an
# argument. A secret-file credential (a key file) is asked for by its path on
# a terminal - nobody pastes a JSON key into a hidden prompt. Called in $( ):
# a failure is its code, which the caller hands to _exakit_vs_secret_failed.
_exakit_vs_read_secret() {
    if [ -n "$2" ]; then
        [ -r "$2" ] || { error "Cannot read $2"; return 1; }
        _exakit_vs_secret_text < "$2"
        return $?
    fi
    # --json never prompts: the credential is the file's, or a pipe's.
    if [ "${EXAKIT_VS_JSON:-0}" = 1 ]; then
        [ -t 0 ] && return 0
        _exakit_vs_secret_text
        return $?
    fi
    _evs_tty="$(_exakit_prompt_tty)"
    if [ -n "$_evs_tty" ] && [ -r /dev/tty ]; then
        if [ "${3:-}" = "secret-file" ]; then
            _evs_path="$(prompt_text "$1 - path to the file" "")"
            case "$_evs_path" in "~/"*) _evs_path="$HOME/${_evs_path#\~/}" ;; esac
            [ -n "$_evs_path" ] && [ -r "$_evs_path" ] || { error "Cannot read ${_evs_path:-the file}"; return 1; }
            _exakit_vs_secret_text < "$_evs_path"
            return $?
        fi
        exakit_read_hidden "$1" || { error "The terminal cannot hide input; give the credential with --password-file."; return 1; }
        return 0
    fi
    _exakit_vs_secret_text
}

# _exakit_vs_read_storage <label> <storage-secret-file> — the second secret of
# a lakehouse combination with two (a catalog login and storage keys): from
# --storage-secret-file, else asked hidden at a terminal; empty when neither
# can give it (--json, a pipe), which the caller refuses. Never from stdin:
# that carries the first one. Called in $( ). ⇄ twin: Read-ExakitVsStorageSecret.
_exakit_vs_read_storage() {
    if [ -n "$2" ]; then
        { [ -r "$2" ] && [ ! -d "$2" ]; } || { error "Cannot read $2"; return 1; }
        _exakit_vs_secret_text < "$2"
        return $?
    fi
    [ "${EXAKIT_VS_JSON:-0}" = 1 ] && return 0
    [ -n "$(_exakit_prompt_tty)" ] && [ -r /dev/tty ] || return 0
    exakit_read_hidden "$1" || { error "The terminal cannot hide input; give it with --storage-secret-file."; return 1; }
}

# _exakit_vs_b64 — stdin as one line of base64 (macOS and GNU base64 alike).
_exakit_vs_b64() { base64 | tr -d '\n\r'; }

# _exakit_vs_pair <secret> <storage-secret> — the two secrets as the engine's
# --secret-pair-base64 reads them on stdin: base64 "." base64. Builtins and
# pipes only: neither value is ever an argument of a program.
# ⇄ twin: ConvertTo-ExakitVsSecretPair.
_exakit_vs_pair() {
    printf '%s' "$1" | _exakit_vs_b64
    printf '.'
    printf '%s' "$2" | _exakit_vs_b64
}

# _exakit_vs_engine_sets <command> <connector> — the engine's command with the
# --set pairs gathered so far (EXAKIT_VS_SETS) after the connector.
_exakit_vs_engine_sets() {
    _ees_cmd="$1"; _ees_conn="$2"
    set -- "$_ees_cmd" "$_ees_conn"
    while IFS= read -r _ees_w; do [ -n "$_ees_w" ] && set -- "$@" "$_ees_w"; done <<EOF
${EXAKIT_VS_SETS:-}
EOF
    exakit_vs_engine "$@" < /dev/null
}

# _exakit_vs_secret_labels <connector> — "<credential label>|<storage label>"
# for the combination the --set pairs gathered so far choose (engine inputs);
# the second empty when it has one secret, both when it has none.
# ⇄ twin: Get-ExakitVsSecretLabels.
_exakit_vs_secret_labels() {
    _exakit_vs_engine_sets inputs "$1" 2>>"${EXAKIT_LOG_FILE:-/dev/null}" | sed -n 's/^RESULT //p' \
        | run_python_any -c 'import json, sys
try:
    doc = json.load(sys.stdin)
except ValueError:
    doc = {"inputs": []}
cred = next((f["label"] for f in doc["inputs"] if f["kind"] in ("secret", "secret-file") and not f.get("storage")), "")
store = next((f["label"] for f in doc["inputs"] if f.get("storage")), "")
print("%s|%s" % (cred, store))' 2>/dev/null
}

# exakit_vs_preset <connector> <setting> <value> — the picker's interface to the
# form: a setting chosen before the form opens (the lakehouse tree's catalog and
# files), answered and not asked. Lines "<connector> <key>=<value>" in
# _EXAKIT_VS_PRESET; _exakit_vs_tui_form takes those of its connector as if
# given with --set. Set them before _exakit_vs_tui runs (after _exakit_vs_pick).
# ⇄ twin: Add-ExakitVsPreset.
exakit_vs_preset() {
    _EXAKIT_VS_PRESET="${_EXAKIT_VS_PRESET:-}$1 $2=$3
"
}

# _exakit_vs_interrupted <saved-trap> — after a reader gave the terminal back
# on Ctrl-C: the trap that stood before it (as trap -p printed it) runs, so
# the command says what was cancelled; with none, exit 130.
_exakit_vs_interrupted() {
    if [ -n "$1" ]; then
        # "trap -- '<command>' SIGINT": the command is the third word.
        eval "set -- $1"
        eval "$3"
    fi
    exit 130
}

# _exakit_vs_cancel_trap — Ctrl-C (or TERM) anywhere in a connect at a
# terminal: the terminal back (mouse reporting off, the cursor, echo and the
# stty state saved when the command began), a live table stopped, the work
# folder gone, one line said, exit 130. A source the live table already
# connected stays connected, and the line says so. The menus, the live table
# and the hidden readers give the terminal back themselves and then run this.
# ⇄ twin: the finally block of Invoke-ExakitVsTui.
_exakit_vs_cancel_trap() {
    # Grouped: a failed < /dev/tty is said before a plain 2> would apply.
    _EVC_STTY="$( { stty -g < /dev/tty; } 2>/dev/null)"
    trap '_exakit_vs_cancelled' INT TERM
}
_exakit_vs_cancelled() {
    trap - INT TERM
    command -v ui_table_abort >/dev/null 2>&1 && ui_table_abort
    command -v ui_restore_cursor >/dev/null 2>&1 && ui_restore_cursor
    [ -n "${_EVC_STTY:-}" ] && { stty "$_EVC_STTY" < /dev/tty; } 2>/dev/null
    { stty echo < /dev/tty; } 2>/dev/null
    printf '\n'
    if [ -n "${_EVT_OK:-}" ]; then
        info "Cancelled - the sources marked connected above stay connected; nothing else was."
    else
        info "Cancelled - nothing was connected."
    fi
    [ -n "${_EVT_DIR:-}" ] && rm -rf "$_EVT_DIR"
    exit 130
}

# _exakit_vs_hidden_line <prompt> [err] — one line typed or pasted at a hidden
# prompt, from stdin (a terminal; the caller redirects /dev/tty to it when it
# must), into _EVH_LINE. The prompt goes to stdout, or stderr with "err".
# Returns 1 at end of input (Ctrl-D on an empty line, or the terminal gone), 2
# when echo cannot be turned off - then nothing is read: input is never taken
# in clear. Twin of the hidden branch of Read-ExakitVsTuiAnswer.
#   - Echo goes off BEFORE the prompt shows (exakit_read_hidden, same order).
#   - The terminal leaves canonical mode for the read: a canonical line stops at
#     1023 bytes on macOS (MAX_CANON), so a longer paste rang the bell, lost its
#     Enter, and the read never ended. Key by key instead, Backspace and Ctrl-U
#     editing what was typed.
#   - What is still pending after Enter - the rest of a multi-line paste - is
#     discarded, so it answers no later question; what arrives within a tenth
#     of a second counts as pending.
#   - A key that sends an escape sequence (an arrow, Home, End, Delete) does
#     nothing: the whole sequence is read and dropped (_exakit_vs_esc_rest), so
#     a stray "[D" never joins the line; a lone Esc is dropped too.
#   - The terminal's own state comes back, on Ctrl-C too.
_exakit_vs_hidden_line() {
    _EVH_LINE=""
    _evh_saved="$(stty -g 2>/dev/null)"
    stty -echo -icanon min 1 time 0 2>/dev/null || return 2
    # The caller's own traps are put back afterwards, not cleared.
    _evh_prev_int="$(trap -p INT)"; _evh_prev_term="$(trap -p TERM)"
    trap 'stty "${_evh_saved:-echo icanon}" 2>/dev/null; printf "\n"; _exakit_vs_interrupted "$_evh_prev_int"' INT
    trap 'stty "${_evh_saved:-echo icanon}" 2>/dev/null; printf "\n"; _exakit_vs_interrupted "$_evh_prev_term"' TERM
    if [ "${2:-}" = err ]; then printf '%s' "$1" >&2; else printf '%s' "$1"; fi
    _evh_rc=0; _evh_has=0; _evh_next=""
    while :; do
        # One character; the newline Enter sends is read's delimiter: empty. A
        # key that followed a lone Esc is taken as typed.
        if [ "$_evh_has" = 1 ]; then _evh_c="$_evh_next"; _evh_has=0
        else IFS= read -r -n 1 _evh_c || { _evh_rc=1; break; }; fi
        case "$_evh_c" in
            ''|$'\n'|$'\r') break ;;
            $'\004') if [ -z "$_EVH_LINE" ]; then _evh_rc=1; break; fi ;;
            $'\033') _exakit_vs_esc_rest; _evh_next="$_EVE_NEXT"; _evh_has="$_EVE_HAS" ;;
            $'\177'|$'\010') _EVH_LINE="${_EVH_LINE%?}" ;;
            $'\025') _EVH_LINE="" ;;
            [[:cntrl:]]) ;;
            *) _EVH_LINE="$_EVH_LINE$_evh_c" ;;
        esac
    done
    _evh_c=""; _evh_next=""; _EVE_NEXT=""
    # The rest of the paste: read until a tenth of a second passes with nothing
    # (VMIN 0, VTIME 1 - a read then returns empty, and cat stops).
    stty min 0 time 1 2>/dev/null && cat > /dev/null 2>&1
    stty "${_evh_saved:-echo icanon}" 2>/dev/null
    trap - INT TERM
    [ -n "$_evh_prev_int" ] && eval "$_evh_prev_int"
    [ -n "$_evh_prev_term" ] && eval "$_evh_prev_term"
    return "$_evh_rc"
}

# _exakit_vs_esc_byte — the next byte on stdin (the terminal, out of canonical
# mode), into _EVE_B, waiting at most a tenth of a second: empty when none came.
# Not read -n: bash puts VMIN back to 1 for it, and a lone Esc would wait for
# the next key.
_exakit_vs_esc_byte() {
    stty min 0 time 1 2>/dev/null
    _EVE_B="$(dd bs=1 count=1 2>/dev/null; printf x)"; _EVE_B="${_EVE_B%x}"
    stty min 1 time 0 2>/dev/null
}

# _exakit_vs_esc_rest — after an Esc read by a key-by-key reader: the rest of the
# key's escape sequence, read and dropped. CSI is ESC [, parameter and
# intermediate bytes, one final byte (an arrow ESC [ D, Delete ESC [ 3 ~,
# Ctrl-Left ESC [ 1 ; 5 D); SS3 is ESC O and one byte (an arrow in application
# mode). An Esc with nothing after it within a tenth of a second is a lone Esc:
# _EVE_LONE=1, and nothing waits for another key. Any other key right after it
# begins no sequence: it is handed back in _EVE_NEXT (_EVE_HAS=1), to be taken
# as typed.
_exakit_vs_esc_rest() {
    _EVE_LONE=0; _EVE_NEXT=""; _EVE_HAS=0
    _exakit_vs_esc_byte
    case "$_EVE_B" in
        '') _EVE_LONE=1 ;;
        '[')
            while :; do
                _exakit_vs_esc_byte
                case "$_EVE_B" in
                    [0-9]|';'|':'|'<'|'='|'>'|'?'|' '|'!'|'"'|'#'|'$'|'%'|'&'|"'"|'('|')'|'*'|'+'|','|'-'|'.'|'/') ;;
                    # Another Esc: this sequence was cut short, a new one begins.
                    $'\033') _EVE_NEXT="$_EVE_B"; _EVE_HAS=1; break ;;
                    *) break ;;
                esac
            done ;;
        O) _exakit_vs_esc_byte ;;
        *) _EVE_NEXT="$_EVE_B"; _EVE_HAS=1 ;;
    esac
    _EVE_B=""
}

# _exakit_vs_key — one key from stdin (a terminal; the caller redirects
# /dev/tty to it when it must), nothing echoed, into _EVK: enter, esc, eof
# (Ctrl-D, or the terminal gone), or the character typed. An arrow or another
# key that sends an escape sequence is not a key here: it is dropped and the
# next one read. What is still pending after the key - the rest of a paste
# typed at the question - is discarded. Returns 2, reading nothing, when the
# terminal cannot leave canonical mode. The terminal's own state comes back, on
# Ctrl-C too.
_exakit_vs_key() {
    _EVK=""
    _evk_saved="$(stty -g 2>/dev/null)"
    stty -echo -icanon min 1 time 0 2>/dev/null || return 2
    _evk_prev_int="$(trap -p INT)"; _evk_prev_term="$(trap -p TERM)"
    trap 'stty "${_evk_saved:-echo icanon}" 2>/dev/null; printf "\n"; _exakit_vs_interrupted "$_evk_prev_int"' INT
    trap 'stty "${_evk_saved:-echo icanon}" 2>/dev/null; printf "\n"; _exakit_vs_interrupted "$_evk_prev_term"' TERM
    _evk_has=0; _evk_next=""
    while [ -z "$_EVK" ]; do
        if [ "$_evk_has" = 1 ]; then _evk_c="$_evk_next"; _evk_has=0
        else IFS= read -r -n 1 _evk_c || { _EVK=eof; break; }; fi
        case "$_evk_c" in
            ''|$'\n'|$'\r') _EVK=enter ;;
            $'\004') _EVK=eof ;;
            $'\033')
                _exakit_vs_esc_rest
                if [ "$_EVE_LONE" = 1 ]; then _EVK=esc; else _evk_next="$_EVE_NEXT"; _evk_has="$_EVE_HAS"; fi ;;
            [[:cntrl:]]) ;;
            *) _EVK="$_evk_c" ;;
        esac
    done
    _evk_c=""; _evk_next=""; _EVE_NEXT=""
    # What is still pending - the rest of a paste typed here - answers nothing.
    stty min 0 time 1 2>/dev/null && cat > /dev/null 2>&1
    stty "${_evk_saved:-echo icanon}" 2>/dev/null
    trap - INT TERM
    [ -n "$_evk_prev_int" ] && eval "$_evk_prev_int"
    [ -n "$_evk_prev_term" ] && eval "$_evk_prev_term"
    return 0
}

# _exakit_vs_secret_kind <connector> — the kind of its credential input
# (secret or secret-file), empty when it has none.
_exakit_vs_secret_kind() {
    run_python_any -c 'import json,sys; c=json.load(open(sys.argv[1])); print(next((s["kind"] for s in c["inputs"] if s["kind"] in ("secret","secret-file")), ""))' \
        "$(exakit_vs_defs)/connectors/$1/connector.json" 2>/dev/null
}

# _exakit_vs_confirm <question> — yes on a terminal answer y, or --yes. --json
# never asks: without --yes the answer is no.
_exakit_vs_confirm() {
    [ "${EXAKIT_VS_ASSUME_YES:-0}" = 1 ] && return 0
    [ "${EXAKIT_VS_JSON:-0}" = 1 ] && return 1
    [ -n "$(_exakit_prompt_tty)" ] || return 1
    case "$(prompt_text "$1 [y/N]" "N")" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# _exakit_vs_interactive — is a person connecting at a terminal? Set by
# cmd_connect (a terminal reachable, no --json) and the terminal flow
# (_EXAKIT_VS_INTERACTIVE). Picking the source was their permission to prepare
# the database for it, so a language container or a restart is said and made,
# never asked. Anything else keeps _exakit_vs_confirm: --yes, a y at a terminal
# (exakit source), and no for --json or no terminal - the exit code and remedy.
_exakit_vs_interactive() {
    [ "${_EXAKIT_VS_INTERACTIVE:-0}" = 1 ] && [ "${EXAKIT_VS_JSON:-0}" != 1 ]
}

# _exakit_vs_label <connector> — its name in the catalog ("PostgreSQL"), for the
# line that says what a step is for; the id when the catalog cannot be read.
_exakit_vs_label() {
    run_python_any -c 'import json, sys
print(next((e["name"] for e in json.load(open(sys.argv[1]))["connectors"] if e["id"] == sys.argv[2]), sys.argv[2]))' \
        "$(exakit_vs_defs)/catalog.json" "$1" 2>/dev/null || printf '%s\n' "$1"
}

# _exakit_vs_and <word...> — "a", "a and b", "a, b and c": the sources a step
# is for, in the line that says it.
_exakit_vs_and() {
    _evand_out=""
    while [ "$#" -gt 0 ]; do
        if [ -z "$_evand_out" ]; then _evand_out="$1"
        elif [ "$#" -eq 1 ]; then _evand_out="$_evand_out and $1"
        else _evand_out="$_evand_out, $1"; fi
        shift
    done
    printf '%s' "$_evand_out"
}

# _exakit_vs_prepare_said — is the database prepared without a question? A
# person connecting at a terminal (picking the source was the permission) or
# --yes. Then each step is one spinner line that its tick replaces, under the
# "Preparing the database" header its caller printed.
_exakit_vs_prepare_said() {
    _exakit_vs_interactive || [ "${EXAKIT_VS_ASSUME_YES:-0}" = 1 ]
}

# _exakit_vs_prep_step <doing> <done> <command...> — one step of preparing the
# database: the kit's spinner says <doing> while the command runs, its output
# kept for the log, and a tick line saying <done> replaces it. On failure what
# the command said is shown instead.
_exakit_vs_prep_step() {
    _eps_doing="$1"; _eps_done="$2"; shift 2
    _eps_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs-prep.XXXXXX")" || _eps_out=/dev/null
    ui_spin_begin "$_eps_doing"
    ( EXAKIT_QUIET_DETAIL=1; "$@" ) > "$_eps_out" 2>&1
    _eps_rc=$?
    ui_spin_end
    cat "$_eps_out" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>/dev/null
    if [ "$_eps_rc" -eq 0 ]; then
        ok "$_eps_done"
    else
        cat "$_eps_out"
    fi
    [ "$_eps_out" = /dev/null ] || rm -f "$_eps_out"
    return "$_eps_rc"
}

# _exakit_vs_db_restart — the database stopped (add-on services with it) and
# started again through the kit's own stop/start, which gives the language
# containers the deployment's DNS. Its words go to the log: the step's tick
# says "Database restarted".
_exakit_vs_db_restart() {
    EXAKIT_STOP_ADDONS=1 "$EXAKIT_BIN_DIR/exakit" stop >/dev/null 2>&1 || true
    "$EXAKIT_BIN_DIR/exakit" start >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 \
        || { error "The database did not come back. Run: exakit start"; return 1; }
}

# _exakit_vs_java_add — the Java language container installed, not yet seen
# by the database (it restarts next). Docker: the download the start would
# make, made now, and the image linked to the deployment's DNS before the
# start mounts it read-only - so that start is the only one
# (personal_slc_dns_prepare).
_exakit_vs_java_add() {
    run_logged "$(personal_cli)" slc install java --no-restart $(personal_auto_approve_flag slc) \
        || { error "The Java language container did not install. Details: exakit logs"; return 1; }
    personal_slc_dns_prepare --pull
}

# _exakit_vs_java_restart — the restart that makes Java usable. An installed
# kit's start repairs DNS; this kit copy may be newer than it. Exit 2
# (Docker): linked in the image after an older kit's start mounted it - one
# more start mounts it.
_exakit_vs_java_restart() {
    _exakit_vs_db_restart || return 1
    _evj_dns=0
    personal_slc_dns_repair || _evj_dns=$?
    [ "$_evj_dns" -eq 2 ] || return 0
    _exakit_vs_db_restart
}

# _exakit_vs_install_java — the Java language container, with consent: a
# download of about 250 MiB and one database restart, done through the kit's
# own stop/start so add-on services come back and DNS is repaired. A person
# connecting at a terminal gave it by picking the source, and --yes gives it:
# two steps under "Preparing the database", nothing asked. Otherwise asked.
_exakit_vs_install_java() {
    if ! _exakit_vs_prepare_said; then
        info "Virtual schemas run Java inside the database, and its Java language container is not installed."
        info "Installing it downloads about 250 MiB and restarts the database once (add-on services restart with it)."
        if ! _exakit_vs_confirm "Install the Java language container now?"; then
            _exakit_vs_info_cmds "Install it later with: exasol slc install java --no-restart, then exakit stop and exakit start"
            return 1
        fi
    fi
    _exakit_vs_prep_step "Installing the Java language container (about 250 MiB)" \
        "Java language container installed" _exakit_vs_java_add || return 1
    _exakit_vs_prep_step "Restarting the database" "Database restarted" _exakit_vs_java_restart
}

# _exakit_vs_rust_add — the pinned Rust build (_evr_url, _evr_sha, _evr_size,
# _evr_asset, set by _exakit_vs_install_rust)
# downloaded, size- and SHA-256-checked, and registered as the RUST alias;
# the database sees it from its next start.
_exakit_vs_rust_add() {
    _evr_dir="$(mktemp -d "${TMPDIR:-/tmp}/exakit-rust.XXXXXX")" || return 1
    fetch "$_evr_url" "$_evr_dir/$_evr_asset"
    _evr_got="$(wc -c < "$_evr_dir/$_evr_asset" | tr -d ' ')"
    [ "$_evr_got" = "$_evr_size" ] || { rm -rf "$_evr_dir"; error "The Rust language container download is $_evr_got bytes, not the pinned $_evr_size; nothing was installed."; return 1; }
    verify_sha256 "$_evr_dir/$_evr_asset" "$_evr_sha"
    if ! run_logged "$(personal_cli)" slc custom install --source "$_evr_dir/$_evr_asset" --alias RUST --language rust \
            --no-restart $(personal_auto_approve_flag slc); then
        rm -rf "$_evr_dir"
        error "The Rust language container did not install. Details: exakit logs"
        return 1
    fi
    rm -rf "$_evr_dir"
}

# _exakit_vs_install_rust — the Rust language container a native adapter
# (Profile D) runs in, with consent (prepared without a question at a
# terminal or with --yes, as Java's is): the exasol-labs build pinned for
# this CPU in profiles/rust-native, size- and SHA-256-checked, registered as
# the RUST alias, then one database restart through the kit's own
# stop/start. Twin of Install-ExakitVsRust.
_exakit_vs_install_rust() {
    _evr_pin="$(run_python_any - "$(exakit_vs_defs)/profiles/rust-native/profile.json" "$(uname -m)" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["slc"]["custom"]
arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64", "amd64": "x86_64"}.get(sys.argv[2].lower(), "")
p = c["arch"].get(arch)
print("|".join([p["url"], p["sha256"], str(p["size"]), p["asset"], c["version"], c["upstream"]]) if p else "")
PY
)"
    [ -n "$_evr_pin" ] || { error "There is no Rust language container build for this CPU ($(uname -m))."; return 1; }
    IFS='|' read -r _evr_url _evr_sha _evr_size _evr_asset _evr_version _evr_upstream <<EOF
$_evr_pin
EOF
    if ! _exakit_vs_prepare_said; then
        info "This source runs a native adapter inside the database, and its Rust language container is not installed."
        info "Installing it downloads $_evr_upstream $_evr_version (about $((_evr_size / 1048576)) MiB, checksum-pinned) and restarts the database once (add-on services restart with it)."
        if ! _exakit_vs_confirm "Install the Rust language container now?"; then
            info "Nothing was installed. Run the same exakit connect again when you are ready."
            return 1
        fi
    fi
    _exakit_vs_prep_step "Installing the Rust language container ($_evr_upstream $_evr_version, about $((_evr_size / 1048576)) MiB)" \
        "Rust language container installed" _exakit_vs_rust_add || return 1
    _exakit_vs_prep_step "Restarting the database" "Database restarted" _exakit_vs_db_restart
}

# _exakit_vs_dns_restart — Docker: the DNS fix is in the language container
# image, and the database mounts an image only when it starts - one restart.
# Said and made for a person connecting at a terminal; otherwise asked
# (_exakit_vs_confirm: --yes makes it, --json and no terminal do not).
_exakit_vs_dns_restart() {
    if _exakit_vs_interactive; then
        info "Restarting the database once, so Java in it can resolve host names for ${_EXAKIT_VS_FOR:-this source} (add-on services restart with it)."
    else
        info "The database sees it from its next start: one restart (add-on services restart with it)."
        if ! _exakit_vs_confirm "Restart the database now?"; then
            error "Java in the database resolves host names from its next start. Run: exakit stop, then exakit start - and try again."
            return 1
        fi
    fi
    _exakit_vs_prep_step "Restarting the database" "Database restarted" _exakit_vs_db_restart
}

# _exakit_vs_repair <engine-exit> — what the bridge does about exit 20 (DNS
# repaired), 21 (Java installed) or 23 (Rust installed) before its one retry;
# non-zero when it could not, or was not allowed to.
_exakit_vs_repair() {
    case "$1" in
        20) info "Giving the database's language containers the deployment's DNS, then trying again"
            _evrp_dns=0
            personal_slc_dns_repair || _evrp_dns=$?
            case "$_evrp_dns" in
                0) : ;;
                2) _exakit_vs_dns_restart || return 1 ;;
                *) error "DNS could not be repaired. Restart the database (exakit stop, exakit start) and try again."; return 1 ;;
            esac ;;
        21) _exakit_vs_install_java ;;
        23) _exakit_vs_install_rust ;;
        *)  return 1 ;;
    esac
}

# _exakit_vs_run <secret-or-empty> <engine args...> — run the engine once,
# repairing DNS (exit 20) or installing Java (exit 21) or Rust (exit 23) and retrying once.
# With EXAKIT_VS_JSON=1 the engine answers in JSON, events to the log, and
# only the last run's object reaches stdout; what the bridge says while it
# repairs goes to stderr.
_exakit_vs_run() {
    unset _evx_secret
    _evx_secret="$1"; shift
    if [ "${EXAKIT_VS_JSON:-0}" = 1 ]; then
        # Once: a caller that built its arguments with --json already has it.
        _evx_has=0
        for _evx_a in "$@"; do [ "$_evx_a" = --json ] && _evx_has=1; done
        [ "$_evx_has" = 1 ] || set -- --json "$@"
    fi
    _evx_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || { _exakit_vs_no_tmp; return 1; }
    _evx_try=0
    while :; do
        _evx_try=$((_evx_try + 1))
        if [ -n "$_evx_secret" ]; then
            printf '%s' "$_evx_secret" | exakit_vs_engine "$@" > "$_evx_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        else
            exakit_vs_engine "$@" < /dev/null > "$_evx_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        fi
        _evx_rc=$?
        if [ "${EXAKIT_VS_JSON:-0}" = 1 ]; then
            EXAKIT_VS_RESULT="$(cat "$_evx_out")"
        elif [ "$_evx_try" -eq 1 ] && { [ "$_evx_rc" -eq 21 ] || [ "$_evx_rc" -eq 23 ]; } && _exakit_vs_prepare_said; then
            # A language container installed now, without a question, is a
            # step of the run, not its failure: its FAIL line goes to the log.
            grep '^FAIL ' "$_evx_out" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>/dev/null
            grep -v '^FAIL ' "$_evx_out" > "$_evx_out.said"
            _exakit_vs_render "$_evx_out.said"; rm -f "$_evx_out.said"
            exakit_step_heading "Preparing the database"
        else
            _exakit_vs_render "$_evx_out"
        fi
        [ "$_evx_try" -eq 1 ] || break
        case "$_evx_rc" in 20|21|23) ;; *) break ;; esac
        if [ "${EXAKIT_VS_JSON:-0}" = 1 ]; then
            # In a subshell: a die inside a repair (a download that fails its
            # size or checksum) ends only the repair, and the first run's
            # object still reaches stdout.
            ( _exakit_vs_repair "$_evx_rc" ) >&2 || break
        else
            _exakit_vs_repair "$_evx_rc" || break
        fi
    done
    [ "${EXAKIT_VS_JSON:-0}" = 1 ] && cat "$_evx_out"
    rm -f "$_evx_out"
    return "$_evx_rc"
}

# _exakit_vs_prompt <question> <default> <required:1|""> <marks:1|""> [label] —
# one line-by-line answer on stdout. With marks (someone is answering: not
# --yes, --dry-run or --json) a required question ends in a red * (a plain *
# without colour; _exakit_vs_legend says what it means), and an empty answer to
# it is refused ("<label> is required") and asked again; an optional one shows
# only its default. Without marks, it is prompt_text as it always was. ⇄ twin:
# Read-ExakitVsLineAnswer.
_exakit_vs_prompt() {
    [ -n "$4" ] || { prompt_text "$1" "$2"; return 0; }
    _evq_mark=""; [ -n "$3" ] && _evq_mark=" ${UI_ERR:-}*${UI_RESET:-}"
    while :; do
        # Nobody to ask after all (no terminal reachable from here): the
        # default, as prompt_text would answer, never a loop.
        [ -n "$(_exakit_prompt_tty)" ] || { printf '%s\n' "$2"; return 0; }
        _evq_v="$(prompt_text "$1$_evq_mark" "$2")"
        if [ -n "$_evq_v" ] || [ -z "$3" ]; then printf '%s\n' "$_evq_v"; return 0; fi
        error "${5:-$1} is required"
    done
}

# _exakit_vs_legend — the line above the marked questions that says what their
# star means, as the panel's legend does. ⇄ twin: Write-ExakitVsLegend.
_exakit_vs_legend() {
    printf '    %s*%s %srequired%s\n' "${UI_ERR:-}" "${UI_RESET:-}" "${UI_DIM:-}" "${UI_RESET:-}" >&2
}

# _exakit_vs_ask_inputs <connector> [marks] — prompt for each input the caller
# did not set, defaults offered; appends --set KEY=VALUE pairs to
# EXAKIT_VS_SETS. marks: a required question ends in a red *, and is not left
# empty (_exakit_vs_prompt). The questions are the engine's (inputs), asked
# again after each answer: a connector with settings (lakehouse) asks its
# catalog, then files, then that combination's inputs only.
_exakit_vs_ask_inputs() {
    _evi_asked=" "
    while :; do
        _evi_line="$(_exakit_vs_engine_sets inputs "$1" 2>>"${EXAKIT_LOG_FILE:-/dev/null}" | sed -n 's/^RESULT //p' \
            | run_python_any -c 'import json, sys
doc = json.load(sys.stdin)
skip = sys.argv[1].split()
for spec in doc["inputs"]:
    if spec["kind"] in ("secret", "secret-file", "source-name") or spec["name"] in skip:
        continue
    choices = "/".join(spec.get("choices", []))
    label = spec.get("label", spec["name"])
    short = label
    for cut in (" - ", " (", "; "):
        short = short.split(cut)[0]
    # The words of the question when it has them, and the lines said above it.
    print("%s|%s|%s|%s|%s|%s|%s" % (spec["name"], spec.get("prompt") or label, spec.get("default", ""), choices,
                                    "1" if spec.get("required") else "", short, "|".join(spec.get("hint", []))))
    break' "$EXAKIT_VS_GIVEN $_evi_asked" 2>/dev/null)"
        [ -n "$_evi_line" ] || break
        IFS='|' read -r _evi_name _evi_label _evi_default _evi_choices _evi_req _evi_short _evi_hint <<EOF
$_evi_line
EOF
        _evi_asked="$_evi_asked$_evi_name "
        [ -n "$_evi_hint" ] && printf '%s\n' "$_evi_hint" | tr '|' '\n' | while IFS= read -r _evi_hl; do
            printf '  %s%s%s\n' "${UI_DIM:-}" "$_evi_hl" "${UI_RESET:-}" >&2
        done
        [ -n "$_evi_choices" ] && _evi_label="$_evi_label ($_evi_choices)"
        _evi_value="$(_exakit_vs_prompt "$_evi_label" "$_evi_default" "$_evi_req" "${2:-}" "$_evi_short")"
        [ -n "$_evi_value" ] && EXAKIT_VS_SETS="$EXAKIT_VS_SETS
--set
$_evi_name=$_evi_value"
    done
}

# _exakit_vs_paste_forms <connector> — the connection strings its paste block
# reads, one per line, for the examples above the question that asks for one;
# empty when the connector reads none. ⇄ twin: Get-ExakitVsPasteForms.
_exakit_vs_paste_forms() {
    run_python_any -c 'import json, sys
for f in (json.load(open(sys.argv[1])).get("paste") or {}).get("forms") or []:
    print(f)' \
        "$(exakit_vs_defs)/connectors/$1/connector.json" 2>/dev/null
}

# _exakit_vs_paste_hint <forms> — the line-by-line hint above the question: what
# to paste, then each form (one per line, _exakit_vs_paste_forms) on its own
# line, indented under the hint's text and dim; one wider than the terminal is
# wrapped at the same indent. ⇄ twin: Write-ExakitVsPasteHint.
_exakit_vs_paste_hint() {
    info "Paste the source's connection string, for example:"
    _eph_w=$(( $(_ui_term_cols) - 10 ))
    [ "$_eph_w" -ge 10 ] || _eph_w=10
    while IFS= read -r _eph_f; do
        [ -n "$_eph_f" ] || continue
        _ui_wrap "$_eph_f" "$_eph_w"
        _eph_k=0
        while [ "$_eph_k" -lt "$_UI_WRAP_N" ]; do
            printf '        %s%s%s\n' "${UI_DIM:-}" "${_UI_WRAP[$_eph_k]}" "${UI_RESET:-}"
            _eph_k=$(( _eph_k + 1 ))
        done
    done <<EOF
$1
EOF
}

# _exakit_vs_paste_choice_text — the question after a pasted string was read:
# its three answers, with the palette's separator. ⇄ twin:
# Get-ExakitVsPasteChoiceText.
_exakit_vs_paste_choice_text() {
    _epc_dot='·'; [ "${UI_BULLET:-}" = '-' ] && _epc_dot='-'
    printf 'Enter to use it %s e to paste it again %s Esc/n to type the fields instead' "$_epc_dot" "$_epc_dot"
}

# _exakit_vs_paste_masked <engine-output-file> — the string the engine read, its
# credentials masked by the engine (paste.py masked), from its RESULT line.
_exakit_vs_paste_masked() {
    _exakit_vs_result "$1" | run_python_any -c 'import json, sys; print(json.load(sys.stdin).get("masked") or "")' 2>/dev/null
}

# _exakit_vs_paste_typed — the engine's paste lines on stdin, for a string typed
# at a prompt: its credential notes (WARN lines) say the string was on the
# command line, which a typed one was not, so the shell-history line and that
# sentence are dropped. The RESULT line, which repeats the notes, is left
# whole. ⇄ twin:
# Format-ExakitVsPasteTyped.
_exakit_vs_paste_typed() {
    sed -e '/^WARN The password from the command line/d' -e '/^WARN /s/ The string was on the command line.*$//'
}

# _exakit_vs_ask_paste <connector> — the line-by-line twin of the form's first
# question: a connection string, or Enter to type the fields. It is read with
# echo off, as a password is (it often holds one), out of canonical mode, so a
# long one is read whole (_exakit_vs_hidden_line). Then it is shown back, its
# credentials masked by the engine ("Read: ..."), and one key decides: Enter
# uses it, e asks for it again, Esc or n types the fields instead
# (_exakit_vs_paste). What it names is not asked again; a string the engine
# cannot read is said, in its words, and asked again. A terminal that cannot
# hide input is not asked at all. ⇄ twin: Read-ExakitVsLinePaste.
_exakit_vs_ask_paste() {
    _eap_forms="$(_exakit_vs_paste_forms "$1")"
    [ -n "$_eap_forms" ] || return 0
    _exakit_vs_paste_hint "$_eap_forms"
    while :; do
        _exakit_vs_hidden_line "    ${UI_ASK:-}?${UI_RESET:-} Connection string (hidden) - paste + Enter, or Enter alone for the fields: " err < /dev/tty \
            || { printf '\n' >&2; return 0; }
        printf '\n' >&2
        _eap_url="$_EVH_LINE"; _EVH_LINE=""
        [ -n "$_eap_url" ] || return 0
        _exakit_vs_paste "$1" "$_eap_url" typed; _eap_rc=$?
        _eap_url=""
        # 0 used, 6 the fields instead; anything else (refused, or e) asks again.
        case "$_eap_rc" in 0|6) return 0 ;; esac
    done
}

# --- the terminal flow: pick, fill in, review, connect ----------------------------
#
# `exakit connect` on a terminal that can draw (UI_FANCY) and answer (stdin is
# the terminal), without --yes, --dry-run or --json:
#   1. pick    the marketplace's own table (ui_table_menu): one row per connector,
#              the sources already connected named in its Description; skipped
#              when the command named a connector;
#   2. fill    one panel per picked source, every field visible with its default,
#              a required one with a red *; first a connection string, read
#              hidden (cli.py paste, on its stdin) and shown back masked, that
#              answers what it names once Enter takes it (e pastes again, Esc
#              or n types the fields), or Enter to type the fields; each answer checked by the engine
#              where it was typed (cli.py field, the value on its stdin); a
#              credential is a hidden prompt (or a key file's path) and stays in
#              this shell's memory until it goes down the engine's stdin; then a
#              numbered summary, where a number asks that one field again; a
#              plan that refuses one input goes straight back to it, one naming
#              several reopens the summary, where skip leaves the source out;
#   3. review  the engine's plan for each (cli.py plan): what it downloads and who
#              can read the result, then one table of the sources, one question;
#   4. connect that table comes alive: one source at a time, a bar per row, then
#              VS_<NAME> and its table count, or the reason it failed.
# Everything else (a pipe, --yes, a dumb terminal, --dry-run, --json) keeps the
# line-by-line path in cmd_connect, so scripts and agents see no change.
# ⇄ twin: Invoke-ExakitVsTui.

# _exakit_vs_tui_ok — can the terminal flow run here?
_exakit_vs_tui_ok() {
    [ "${UI_FANCY:-0}" = 1 ] || return 1
    [ "${EXAKIT_VS_ASSUME_YES:-0}" != 1 ] || return 1
    [ -t 0 ] && [ -t 1 ] || return 1
    return 0
}

# _exakit_vs_result <engine-output-file> — the JSON of its RESULT line.
_exakit_vs_result() {
    sed -n 's/^RESULT //p' "$1" | tail -1
}

# _exakit_vs_tui_rows <characters> — how many terminal lines a line of that many
# characters takes. A wrapped line counted as one is a stale line the next
# redraw leaves behind. One that fills the last column exactly is one row on a
# terminal, which holds the wrap until the next character; readline forces the
# wrap there, so a readline line ("readline") counts as two.
_exakit_vs_tui_rows() {
    if [ "$1" -le 0 ]; then echo 1
    elif [ "${2:-}" = readline ]; then echo $(( $1 / _EVT_COLS + 1 ))
    else echo $(( ($1 - 1) / _EVT_COLS + 1 )); fi
}

# _exakit_vs_tui_fit <text> <width> — the text, its END kept when it is wider
# (_exakit_vs_tui_tail), or nothing when the width is too small to say anything.
_exakit_vs_tui_fit() {
    if [ "${#1}" -le "$2" ]; then printf '%s' "$1"
    elif [ "$2" -ge 4 ]; then _exakit_vs_tui_tail "$1" "$2"; fi
}

# _exakit_vs_tui_short <text> <width> — the text with its START kept ("…" at the end).
_exakit_vs_tui_short() {
    if [ "${#1}" -le "$2" ]; then printf '%s' "$1"; else printf '%s…' "${1:0:$(( $2 - 1 ))}"; fi
}

# _exakit_vs_tui_tail <text> <width> — the text with its END kept, for a path or
# a host: "…/vs-test/rds-ap-south-1-bundle.pem".
_exakit_vs_tui_tail() {
    if [ "${#1}" -le "$2" ]; then printf '%s' "$1"; else printf '…%s' "${1:$(( ${#1} - $2 + 1 ))}"; fi
}

# _exakit_vs_catalog <out-file> — the connector catalog (engine catalog), and with
# it this computer's public IP: its tip is said first when it is known (cloud
# sources see this address; the address in green), and nothing when the lookup is off
# (EXAKIT_NO_IP_LOOKUP=1) or failed - publicip.py's own rules and timeout. The
# answer is kept for the rest of this command (_EXAKIT_VS_PUBLIC_IP), so each
# source's plan says it again without asking again. The catalog's RESULT is in
# EXAKIT_VS_RESULT. ⇄ twin: Get-ExakitVsCatalog.
_exakit_vs_catalog() {
    exakit_vs_engine catalog --public-ip < /dev/null > "$1" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    _evk_ip="$(sed -n 's/^RESULT //p' "$1" | run_python_any -c 'import json, sys
print(json.load(sys.stdin).get("public_ip") or "none")' 2>/dev/null)"
    # The engine's tip names the IP; on screen the address is green (the log
    # keeps the plain words). Every other line renders as it always has.
    case "$_evk_ip" in
        ""|none) _exakit_vs_render "$1" ;;
        *)
            while IFS= read -r _evk_line || [ -n "$_evk_line" ]; do
                case "$_evk_line" in
                    "INFO "*"$_evk_ip"*)
                        _evk_text="${_evk_line#INFO }"
                        if [ -z "${UI_ACCENT:-}" ]; then
                            info "$_evk_text"
                        else
                            [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ] || \
                                printf '    %s%s%s %s%s%s%s%s\n' "${UI_DIM:-}" "${UI_BULLET:--}" "${UI_RESET:-}" \
                                    "${_evk_text%%"$_evk_ip"*}" "$UI_ACCENT" "$_evk_ip" "${UI_RESET:-}" "${_evk_text#*"$_evk_ip"}"
                            _exakit_log_file "INFO  $_evk_text"
                        fi ;;
                    *) printf '%s\n' "$_evk_line" >> "$1.rest" ;;
                esac
            done < "$1"
            _exakit_vs_render "$1.rest" 2>/dev/null || EXAKIT_VS_RESULT=""
            rm -f "$1.rest" ;;
    esac
    [ -n "$_evk_ip" ] && { _EXAKIT_VS_PUBLIC_IP="$_evk_ip"; export _EXAKIT_VS_PUBLIC_IP; }
    return 0
}

# _exakit_vs_cmd <command> — a command the reader may type, in the kit's
# green (the colour the Tip gives the IP); as it is without colour.
_exakit_vs_cmd() {
    printf '%s%s%s' "${UI_ACCENT:-}" "$1" "${UI_RESET:-}"
}

# _exakit_vs_info_cmds <text> — an info line whose "exakit stop" and "exakit
# start" are green on screen (_exakit_vs_cmd); the log keeps the plain words.
_exakit_vs_info_cmds() {
    _eic_t="$1"
    if [ -n "${UI_ACCENT:-}" ]; then
        _eic_t="${_eic_t//exakit stop/$(_exakit_vs_cmd "exakit stop")}"
        _eic_t="${_eic_t//exakit start/$(_exakit_vs_cmd "exakit start")}"
    fi
    [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ] || \
        printf '    %s%s%s %s\n' "${UI_DIM:-}" "${UI_BULLET:--}" "${UI_RESET:-}" "$_eic_t"
    _exakit_log_file "INFO  $1"
}

# _exakit_vs_clock_hint — how to sync the database clock, its commands green.
_exakit_vs_clock_hint() {
    _exakit_vs_info_cmds "To sync the database clock: exakit stop, then exakit start"
}

# _exakit_vs_clock_warn <text> — the clock's warning, a yellow ! level with
# the Tip line above it rather than warn()'s outcome indent.
_exakit_vs_clock_warn() {
    printf '    %s!%s %s\n' "${UI_WARN:-}" "${UI_RESET:-}" "$1"
    _exakit_log_file "WARN  $1"
}

# _exakit_vs_clock_check — the database clock against this computer's, said
# above the connect menu every time (exakit_db_clock_skew): "in sync", or past
# EXAKIT_CLOCK_SKEW_LIMIT a warning - TLS and signed S3/Azure requests fail on
# a wrong clock - and, asked at a terminal (Y by default), the restart that
# syncs it, through the kit's own stop and start; --yes or no terminal: the
# warning and the commands, nothing asked. Nothing when the clock cannot be
# read. ⇄ twin: Show-ExakitVsClockCheck.
_exakit_vs_clock_check() {
    command -v exakit_db_clock_skew >/dev/null 2>&1 || return 0
    _ecc_s="$(exakit_db_clock_skew 2>/dev/null)" || return 0
    case "$_ecc_s" in ''|-|*[!0-9-]*) return 0 ;; esac
    if ! exakit_clock_skewed "$_ecc_s"; then
        info "Database clock: in sync with this computer."
        return 0
    fi
    _exakit_vs_clock_warn "Database clock: $(exakit_clock_skew_words "$_ecc_s") this computer - TLS and S3/Azure connects will fail."
    if [ "${EXAKIT_VS_ASSUME_YES:-0}" = 1 ] || [ -z "$(_exakit_prompt_tty)" ]; then
        _exakit_vs_clock_hint
        return 0
    fi
    if ! confirm "Restart the database now to sync its clock?" y; then
        _exakit_vs_clock_hint
        return 0
    fi
    _exakit_vs_prep_step "Restarting the database" "Database restarted" _exakit_vs_db_restart || return 0
    _ecc_s="$(exakit_db_clock_skew 2>/dev/null)" || return 0
    if exakit_clock_skewed "$_ecc_s"; then
        _exakit_vs_clock_warn "Database clock: still $(exakit_clock_skew_words "$_ecc_s") this computer - TLS and S3/Azure connects will fail."
        _exakit_vs_clock_hint
    else
        info "Database clock: in sync with this computer."
    fi
}

# _exakit_vs_pick <work-dir> — the connector menu, under the line that names
# this computer's public IP (_exakit_vs_catalog). Sets EXAKIT_VS_PICKED to the
# chosen connector ids, space separated; returns 5 when nothing was chosen.
_exakit_vs_pick() {
    _evp_dir="$1"
    _exakit_vs_catalog "$_evp_dir/catalog"
    # id|label|gate, in the catalog's order: each source by its name and nothing
    # more - the adapter version and tier are `exakit source catalog`'s.
    run_python_any - "$EXAKIT_VS_RESULT" > "$_evp_dir/rows" <<'PY'
import json, sys
catalog = json.loads(sys.argv[1] or "{}").get("connectors", [])
for e in catalog:
    gate = e.get("gate", "") if e.get("status") == "gated" else ""
    print("|".join(x.replace("|", "/") for x in (e["id"], e["name"], gate)))
PY
    [ -s "$_evp_dir/rows" ] || { error "The connector catalog could not be read. Details: exakit logs"; return 2; }
    _evp_state="$_evp_dir/menu"
    : > "$_evp_state"
    _evp_n="$(grep -c . "$_evp_dir/rows")"
    _evp_i=0; _evp_ids=""
    while IFS='|' read -r _evp_id _evp_label _evp_gate; do
        _evp_i=$(( _evp_i + 1 ))
        _evp_tree=tee; [ "$_evp_i" -eq "$_evp_n" ] && _evp_tree=corner
        # kind|label|tick|state|pct|ceiling|secs|t0|phase|final|col2|col3; a
        # gated connector is shown, never pickable, its reason read on from its
        # name: the menu has no Status column to say it in.
        if [ -n "$_evp_gate" ]; then
            printf '%s|%s|0|disabled||||||||\n' "$_evp_tree" "$_evp_label - not available yet" >> "$_evp_state"
        else
            printf '%s|%s|0|idle||||||||\n' "$_evp_tree" "$_evp_label" >> "$_evp_state"
        fi
        _evp_ids="$_evp_ids
$_evp_id"
    done < "$_evp_dir/rows"
    printf 'plain|Skip|0|idle||||||||\n' >> "$_evp_state"
    _evp_skip=$(( _evp_n + 1 ))
    EXAKIT_TABLE_DEFAULTS=""            # nothing ticked: a connect is always a choice
    EXAKIT_TABLE_GROUP=""
    EXAKIT_TABLE_EXCLUSIVE="$_evp_skip"
    UI_TABLE_TITLE="Connect external sources"
    UI_TABLE_COL1="Source"; UI_TABLE_COL2=""; UI_TABLE_COL3=""
    UI_TABLE_MENU_START=1               # no "Select All" row to step past
    _exakit_vs_clock_check
    printf '\n'
    info "Tick one or more sources; the details for each are asked next."
    printf '\n'
    # The Source column alone: nothing runs in this menu's rows, so it has no
    # Status column either (UI_TABLE_STAT_MIN=0).
    _evp_statmin="${UI_TABLE_STAT_MIN-}"
    UI_TABLE_STAT_MIN=0
    ui_table_menu "$_evp_state"
    if [ -n "$_evp_statmin" ]; then UI_TABLE_STAT_MIN="$_evp_statmin"; else unset UI_TABLE_STAT_MIN; fi
    EXAKIT_TABLE_EXCLUSIVE=""
    EXAKIT_VS_PICKED=""
    [ "${EXAKIT_TABLE_CONFIRMED:-0}" = 1 ] || return 5
    for _evp_row in $(printf '%s' "$EXAKIT_TABLE_SELECTION" | tr ',' ' '); do
        case "$_evp_row" in ''|*[!0-9]*) continue ;; esac
        [ "$_evp_row" = "$_evp_skip" ] && { EXAKIT_VS_PICKED=""; return 5; }
        _evp_id="$(printf '%s\n' "$_evp_ids" | sed -n "$(( _evp_row + 1 ))p")"
        [ -n "$_evp_id" ] && EXAKIT_VS_PICKED="${EXAKIT_VS_PICKED:+$EXAKIT_VS_PICKED }$_evp_id"
    done
    [ -n "$EXAKIT_VS_PICKED" ] || return 5
    return 0
}

# _exakit_vs_tui_frame <title> <current-field> [numbered] — the panel, built into
# _EVT_BUF with its height in _EVT_BUF_N. A required field's label ends in a red
# * (a plain * without colour), which the legend under the fields explains; a
# field still to answer is dim, with its default; an answered one is ticked -
# or, in the summary (numbered), numbered for the reader to pick - and says so
# when a pasted connection string gave it. What the engine said about that
# string (_EVT_NOTES) stays under the panel while the form is open.
_exakit_vs_tui_frame() {
    _EVT_BUF=""; _EVT_BUF_N=0
    _evf_t=" $1 "
    _evf_fill=$(( _EVT_IN - ${#_evf_t} - 1 )); [ "$_evf_fill" -ge 0 ] || _evf_fill=0
    _EVT_BUF="  $UI_ACCENT$UI_TL$UI_HR$UI_RESET$UI_BOLD$_evf_t$UI_RESET$UI_ACCENT${_EVT_HR:0:$_evf_fill}$UI_TR$UI_RESET"$'\n'
    _EVT_BUF_N=1
    # What a row's value may take: the panel's inside less the mark and label.
    _evf_room=$(( _EVT_IN - 7 - _EVT_LW ))
    _evf_i=0; _evf_anyreq=""
    while [ "$_evf_i" -lt "$_EVT_NF" ]; do
        _evf_lab="${_EVT_LAB[$_evf_i]}"
        # The label column holds " *" after a required one (_EVT_LW counts it).
        _evf_star=""; _evf_sw=0
        if [ -n "${_EVT_REQ[$_evf_i]}" ]; then _evf_star=" $UI_ERR*$UI_RESET"; _evf_sw=2; _evf_anyreq=1; fi
        _evf_star="$_evf_star${_EVT_SP:0:$(( _EVT_LW - ${#_evf_lab} - _evf_sw ))}"
        _evf_kind="${_EVT_KIND[$_evf_i]}"
        _evf_lead=""
        if [ "$_evf_i" -eq "$2" ]; then
            _evf_mark="$UI_ACCENT$UI_ARROW$UI_RESET"; _evf_shown="$UI_BOLD$_evf_lab$UI_RESET$_evf_star"
            _evf_plain=""; _evf_val=""
        elif [ -n "${_EVT_DONE[$_evf_i]:-}" ]; then
            _evf_mark="$UI_OK$UI_TICK$UI_RESET"; _evf_shown="$_evf_lab$_evf_star"
            # The summary's number takes the tick's place, in as many columns.
            [ -n "${3:-}" ] && printf -v _evf_lead ' %s%2d%s  ' "$UI_ACCENT" $(( _evf_i + 1 )) "$UI_RESET"
            _evf_val="${_EVT_VAL[$_evf_i]}"
            _evf_from=""; [ -n "${_EVT_FROM[$_evf_i]:-}" ] && _evf_from=" (from the string)"
            if [ "$_evf_kind" = secret ]; then
                # Taken out of a pasted connection string: said in one.
                if [ -n "$_evf_from" ]; then _evf_val="(from the string, hidden)"; _evf_from=""
                elif [ -n "$_evf_val" ]; then _evf_val="(given, hidden)"; else _evf_val="(read from a file)"; fi
            fi
            # Emptied with "-": the default is what the plan will use.
            [ -n "$_evf_val" ] || _evf_val="${_EVT_DEF[$_evf_i]:-(none)}"
            # A mapping left empty, or the one the kit drafted: auto.
            if [ -n "${_EVT_DRAFT[$_evf_i]:-}" ]; then
                case "${_EVT_VAL[$_evf_i]}" in
                    ''|"${_EVT_DRAFTED[$_evf_i]:-.}") _evf_val="auto (drafted from the ${_EVT_DRAFT[$_evf_i]})" ;;
                    auto:*) _evf_val="auto (drafted from ${_EVT_VAL[$_evf_i]#auto:})" ;;
                esac
            fi
            # Too narrow for both: the mark goes first, then the value is cut.
            [ $(( ${#_evf_val} + ${#_evf_from} )) -le "$_evf_room" ] || _evf_from=""
            _evf_plain="$(_exakit_vs_tui_fit "$_evf_val" "$_evf_room")"
            _evf_val="$_evf_plain"
            if [ -n "$_evf_from" ]; then _evf_val="$_evf_val$UI_DIM$_evf_from$UI_RESET"; _evf_plain="$_evf_plain$_evf_from"; fi
        else
            _evf_mark=" "; _evf_shown="$UI_DIM$_evf_lab$UI_RESET$_evf_star"
            _evf_val="${_EVT_VAL[$_evf_i]:-${_EVT_DEF[$_evf_i]}}"
            case "$_evf_kind" in secret|secret-file) _evf_val="" ;; esac
            _evf_plain=""; [ -n "$_evf_val" ] && _evf_plain="[$_evf_val]"
            if [ "${#_evf_plain}" -gt "$_evf_room" ]; then
                # Too narrow: the default is cut, then it goes too (the
                # question says it again).
                _evf_plain=""
                [ "$_evf_room" -ge 6 ] && _evf_plain="[$(_exakit_vs_tui_fit "$_evf_val" $(( _evf_room - 2 )))]"
            fi
            _evf_val="$UI_DIM$_evf_plain$UI_RESET"
        fi
        [ -n "$_evf_lead" ] || _evf_lead="  $_evf_mark  "
        _evf_pad=$(( _EVT_IN - 7 - _EVT_LW - ${#_evf_plain} )); [ "$_evf_pad" -ge 0 ] || _evf_pad=0
        _EVT_BUF="$_EVT_BUF  $UI_ACCENT$UI_VB$UI_RESET$_evf_lead$_evf_shown  $_evf_val${_EVT_SP:0:$_evf_pad}$UI_ACCENT$UI_VB$UI_RESET"$'\n'
        _EVT_BUF_N=$(( _EVT_BUF_N + 1 ))
        _evf_i=$(( _evf_i + 1 ))
    done
    # The legend, one dim line under the fields: what the star means.
    if [ -n "$_evf_anyreq" ]; then
        _evf_pad=$(( _EVT_IN - 15 )); [ "$_evf_pad" -ge 0 ] || _evf_pad=0
        _EVT_BUF="$_EVT_BUF  $UI_ACCENT$UI_VB$UI_RESET     $UI_ERR*$UI_RESET$UI_DIM required$UI_RESET${_EVT_SP:0:$_evf_pad}$UI_ACCENT$UI_VB$UI_RESET"$'\n'
        _EVT_BUF_N=$(( _EVT_BUF_N + 1 ))
    fi
    _EVT_BUF="$_EVT_BUF  $UI_ACCENT$UI_BL${_EVT_HR:0:$_EVT_IN}$UI_BR$UI_RESET"$'\n'
    _EVT_BUF_N=$(( _EVT_BUF_N + 1 ))
    [ -n "${_EVT_NOTES:-}" ] || return 0
    while IFS= read -r _evf_note; do
        [ -n "$_evf_note" ] || continue
        _evf_nm="$UI_DIM$UI_BULLET$UI_RESET"
        case "$_evf_note" in "WARN "*) _evf_nm="$UI_WARN!$UI_RESET" ;; esac
        case "$_evf_note" in
            "INFO Read: "*) _exakit_vs_read_wrap "${_evf_note#* }" $(( _EVT_COLS - 8 )) ;;
            *) _ui_wrap "${_evf_note#* }" $(( _EVT_COLS - 8 )) ;;
        esac
        _evf_k=0
        while [ "$_evf_k" -lt "$_UI_WRAP_N" ]; do
            if [ "$_evf_k" -eq 0 ]; then _EVT_BUF="$_EVT_BUF    $_evf_nm ${_UI_WRAP[0]}"$'\n'
            else _EVT_BUF="$_EVT_BUF      ${_UI_WRAP[$_evf_k]}"$'\n'; fi
            _EVT_BUF_N=$(( _EVT_BUF_N + 1 ))
            _evf_k=$(( _evf_k + 1 ))
        done
    done <<EOF
$_EVT_NOTES
EOF
}

# _exakit_vs_tui_draw <title> <current-field> [numbered] — the panel over what
# this form drew last (_EVT_ON_SCREEN lines: the panel and every line under it),
# in one write.
_exakit_vs_tui_draw() {
    _exakit_vs_tui_frame "$1" "$2" "${3:-}"
    if [ "$_EVT_ON_SCREEN" -gt 0 ]; then
        printf '\r\033[%dA\033[0J%s' "$_EVT_ON_SCREEN" "$_EVT_BUF"
    else
        printf '%s' "$_EVT_BUF"
    fi
    _EVT_ON_SCREEN="$_EVT_BUF_N"
}

# _exakit_vs_tui_say <mark> <text> — a line under the panel (a refused answer and
# why), wrapped to the terminal and counted for the next redraw.
# _exakit_vs_read_wrap <"Read: <string>"> <width> - a connection string shown
# back, into _UI_WRAP as _ui_wrap fills it: whole when it fits, else broken only
# after a separator (& ; ? /), each continuation under the string; a stretch
# with no separator in reach is cut at the width. _ui_wrap would cut the string
# mid-word (ConnCatalog=workspa / ce). Twin of Split-ExakitVsReadWrap.
_exakit_vs_read_wrap() {
    _UI_WRAP=(); _UI_WRAP_N=0
    _erw_rest="$1"; _erw_w="$2"; _erw_pad=""
    [ "$_erw_w" -ge 26 ] || _erw_w=26
    while [ -n "$_erw_rest" ]; do
        _erw_room=$(( _erw_w - ${#_erw_pad} ))
        if [ "${#_erw_rest}" -le "$_erw_room" ]; then
            _erw_cut=${#_erw_rest}
        else
            _erw_cut=$_erw_room
            while [ "$_erw_cut" -gt 0 ]; do
                case "${_erw_rest:$(( _erw_cut - 1 )):1}" in '&'|';'|'?'|'/') break ;; esac
                _erw_cut=$(( _erw_cut - 1 ))
            done
            [ "$_erw_cut" -gt 0 ] || _erw_cut=$_erw_room
        fi
        _UI_WRAP[$_UI_WRAP_N]="$_erw_pad${_erw_rest:0:$_erw_cut}"
        _UI_WRAP_N=$(( _UI_WRAP_N + 1 ))
        _erw_rest="${_erw_rest:$_erw_cut}"
        _erw_pad="      "
    done
}

_exakit_vs_tui_say() {
    case "$2" in
        "Read: "*) _exakit_vs_read_wrap "$2" $(( _EVT_COLS - 8 )) ;;
        *) _ui_wrap "$2" $(( _EVT_COLS - 8 )) ;;
    esac
    _evs_k=0
    while [ "$_evs_k" -lt "$_UI_WRAP_N" ]; do
        if [ "$_evs_k" -eq 0 ]; then printf '    %s %s\n' "$1" "${_UI_WRAP[$_evs_k]}"
        else printf '      %s\n' "${_UI_WRAP[$_evs_k]}"; fi
        _evs_k=$(( _evs_k + 1 ))
    done
    _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + _UI_WRAP_N ))
}

# _exakit_vs_tui_ask <prompt-plain> <prompt-colour> <hidden:0|1> — one answer
# into _EVT_ANSWER: a line editor for the visible ones, echo off (and back on
# whatever happens) for the hidden one. Returns 1 at end of input.
_exakit_vs_tui_ask() {
    if [ "$3" = 1 ]; then
        # Echo off before the prompt shows, out of canonical mode, the rest of
        # a multi-line paste discarded, an arrow key's escape sequence dropped
        # (_exakit_vs_hidden_line).
        _EVT_ANSWER=""
        _exakit_vs_hidden_line "  $2: "; _eva_rc=$?
        if [ "$_eva_rc" = 2 ]; then
            _EVT_NOHIDE=1
            _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "this terminal cannot hide input; give the credential with --password-file"
            return 1
        fi
        _EVT_ANSWER="$_EVH_LINE"; _EVH_LINE=""
        printf '\n'
        _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + $(_exakit_vs_tui_rows $(( ${#1} + 4 ))) ))
        return "$_eva_rc"
    fi
    # The prompt goes through readline (-p), its colour marked invisible
    # (\001..\002), so editing and history redraw it in the right place.
    IFS= read -r -e -p "  $2: " _EVT_ANSWER; _eva_rc=$?
    _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + $(_exakit_vs_tui_rows $(( ${#1} + 4 + ${#_EVT_ANSWER} )) readline) ))
    return "$_eva_rc"
}

# _exakit_vs_tui_yes <question> — y/N, counted like any line under the panel.
_exakit_vs_tui_yes() {
    printf '  %s%s [y/N]%s ' "$UI_ASK" "$1" "$UI_RESET"
    IFS= read -r _ety_a || _ety_a=""
    _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + 1 ))
    case "$_ety_a" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# _exakit_vs_tui_args — the engine arguments of the form being filled in, one
# per line: connector, --name, then --set pairs. A credential is never one.
_exakit_vs_tui_args() {
    printf '%s\n' "$_evo_id"
    _eta_f=0
    while [ "$_eta_f" -lt "$_EVT_NF" ]; do
        _eta_v="${_EVT_VAL[$_eta_f]}"
        case "${_EVT_KIND[$_eta_f]}" in
            source-name) printf -- '--name\n%s\n' "$_eta_v" ;;
            secret|secret-file) ;;
            *) [ -n "$_eta_v" ] && printf -- '--set\n%s=%s\n' "${_EVT_NAME[$_eta_f]}" "$_eta_v" ;;
        esac
        _eta_f=$(( _eta_f + 1 ))
    done
}

# _exakit_vs_tui_source_args <i> — the same for a source whose form is done.
_exakit_vs_tui_source_args() {
    printf '%s\n--name\n%s\n' "${_EVT_S_ID[$1]}" "${_EVT_S_NAME[$1]}"
    printf '%s' "${_EVT_S_SETS[$1]}" | while IFS= read -r _esa_kv; do
        [ -n "$_esa_kv" ] && printf -- '--set\n%s\n' "$_esa_kv"
    done
}

# _exakit_vs_tui_engine <args-one-per-line> <command> [--json] [extra...] — the
# engine with those arguments after the command (--json goes before it: it is
# the engine's own option, not the command's).
_exakit_vs_tui_engine() {
    _ete_lines="$1"; _ete_cmd="$2"; shift 2
    _ete_json=""
    [ "${1:-}" = --json ] && { _ete_json="--json"; shift; }
    _ete_extra="$*"
    set -- "$_ete_cmd"
    [ -n "$_ete_json" ] && set -- --json "$_ete_cmd"
    while IFS= read -r _ete_w; do [ -n "$_ete_w" ] && set -- "$@" "$_ete_w"; done <<EOF
$_ete_lines
EOF
    # shellcheck disable=SC2086 — the extra flags are words of our own
    [ -n "$_ete_extra" ] && set -- "$@" $_ete_extra
    exakit_vs_engine "$@"
}

# _exakit_vs_tui_field <i> [why] — field i asked under the panel (with why it is
# asked again, when there is a reason): its label, a red * when it is required,
# its notes and its default. Enter takes the default; an optional one with none is
# left empty, a required one is refused in one line and asked again. The engine
# checks a typed answer (cli.py field, the value on its stdin, never in argv); a
# credential is hidden, and asked again keeps the one given on Enter. Returns 1
# at end of input. Twin of Read-ExakitVsTuiField.
_exakit_vs_tui_field() {
    _etf_i="$1"
    _exakit_vs_tui_draw "$_evo_title" "$_etf_i"
    [ -n "${2:-}" ] && _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$2"
    _exakit_vs_tui_hint "${_EVT_HINT[$_etf_i]:-}"
    _etf_k="${_EVT_KIND[$_etf_i]}"; _etf_lab="${_EVT_LABF[$_etf_i]}"; _etf_req="${_EVT_REQ[$_etf_i]}"
    _etf_old="${_EVT_VAL[$_etf_i]}"
    _etf_def="${_EVT_VAL[$_etf_i]:-${_EVT_DEF[$_etf_i]}}"
    _etf_keep=""
    _etf_note=""
    case "$_etf_k" in
        choice) _etf_note="($(printf '%s' "${_EVT_CH[$_etf_i]}" | sed 's/ / · /g'))" ;;
        secret) _etf_def=""
                # Given already - typed, or read from --password-file: Enter keeps it.
                _etf_file="$_evo_pwfile"; [ "${_EVT_NAME[$_etf_i]}" = storage_secret ] && _etf_file="${_EXAKIT_VS_STORAGE_FILE:-}"
                if [ -n "$_etf_old" ] || { [ -n "${_EVT_DONE[$_etf_i]}" ] && [ -n "$_etf_file" ]; }; then
                    _etf_keep=1; _etf_note="(hidden, Enter keeps the one given)"
                else _etf_note="(hidden)"; fi ;;
        secret-file) _etf_note="(the path to the file)" ;;
    esac
    # An optional answer that differs from its default can be taken back.
    if [ -z "$_etf_req" ] && [ -n "$_etf_old" ] && [ "$_etf_old" != "${_EVT_DEF[$_etf_i]}" ]; then
        case "$_etf_k" in secret|secret-file) ;; *) _etf_note="${_etf_note:+$_etf_note }(- clears it)" ;; esac
    fi
    [ -n "$_etf_def" ] && _etf_note="${_etf_note:+$_etf_note }[$(_exakit_vs_tui_tail "$_etf_def" 32)]"
    # A required one: the label's red * (a plain * without colour), as in the panel.
    _etf_star=""; [ -n "$_etf_req" ] && _etf_star=" *"
    _etf_plain="$_etf_lab$_etf_star${_etf_note:+ $_etf_note}"
    if [ "$_etf_k" = secret ]; then
        _etf_deco="$UI_ASK$_etf_lab$UI_RESET${_etf_star:+ $UI_ERR*$UI_RESET}${_etf_note:+ $UI_DIM$_etf_note$UI_RESET}"
    else
        _etf_deco=$'\001'"$UI_ASK"$'\002'"$_etf_lab"$'\001'"$UI_RESET"$'\002'
        [ -n "$_etf_star" ] && _etf_deco="$_etf_deco "$'\001'"$UI_ERR"$'\002'"*"$'\001'"$UI_RESET"$'\002'
        [ -n "$_etf_note" ] && _etf_deco="$_etf_deco "$'\001'"$UI_DIM"$'\002'"$_etf_note"$'\001'"$UI_RESET"$'\002'
    fi
    while :; do
        if [ "$_etf_k" = secret ]; then
            _exakit_vs_tui_ask "$_etf_plain" "$_etf_deco" 1 || return 1
            if [ -z "$_EVT_ANSWER" ]; then
                [ -n "$_etf_keep" ] && break
                if [ -n "$_etf_req" ]; then
                    _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "${_EVT_LABF[$_etf_i]} is required; it stays in memory and goes only to the database"
                    continue
                fi
            fi
            _EVT_VAL[$_etf_i]="$_EVT_ANSWER"; _EVT_ANSWER=""
            break
        fi
        _exakit_vs_tui_ask "$_etf_plain" "$_etf_deco" 0 || return 1
        if [ "$_EVT_ANSWER" = "-" ] && [ -z "$_etf_req" ]; then _EVT_VAL[$_etf_i]=""; break; fi
        _etf_v="${_EVT_ANSWER:-$_etf_def}"
        case "$_etf_v" in "~/"*) _etf_v="$HOME/${_etf_v#\~/}" ;; esac
        if [ -z "$_etf_v" ]; then
            if [ -n "$_etf_req" ]; then
                _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "${_EVT_LABF[$_etf_i]} is required"
                continue
            fi
            _EVT_VAL[$_etf_i]=""
            break
        fi
        if [ "$_etf_k" = secret-file ]; then
            if [ -f "$_etf_v" ] && [ -r "$_etf_v" ]; then _EVT_VAL[$_etf_i]="$_etf_v"; break; fi
            _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$_etf_v cannot be read here; give the path to the key file"
            continue
        fi
        # The engine's own rule for this input, in the words a scripted
        # connect would get; the value travels on its stdin, never in argv.
        # A connector with settings checks the answer in its combination:
        # the settings answered so far go with it.
        set -- field "$_evo_id" "${_EVT_NAME[$_etf_i]}"
        _etf_s=0
        while [ "$_etf_s" -lt "$_EVT_NF" ]; do
            case "${_EVT_NAME[$_etf_s]}" in catalog|files|login)
                [ -n "${_EVT_VAL[$_etf_s]}" ] && [ "$_etf_s" != "$_etf_i" ] && \
                    set -- "$@" --set "${_EVT_NAME[$_etf_s]}=${_EVT_VAL[$_etf_s]}" ;;
            esac
            _etf_s=$(( _etf_s + 1 ))
        done
        printf '%s' "$_etf_v" | exakit_vs_engine "$@" > "$_EVT_DIR/field" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        if [ $? -eq 0 ]; then
            _etf_v="$(_exakit_vs_result "$_EVT_DIR/field" | run_python_any -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
            if [ "$_etf_k" = source-name ]; then
                case " ${_EVT_TAKEN:-} " in *" $_etf_v "*)
                    _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$_etf_v is already the name of another source in this list"
                    continue ;;
                esac
            fi
            _EVT_VAL[$_etf_i]="$_etf_v"
            break
        fi
        _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$(sed -n 's/^FAIL //p' "$_EVT_DIR/field" | head -1)"
    done
    _EVT_DONE[$_etf_i]=1
    # Changed by hand, it is no longer what the connection string said.
    [ "${_EVT_VAL[$_etf_i]}" = "$_etf_old" ] || _EVT_FROM[$_etf_i]=""
    return 0
}

# _exakit_vs_tui_hint <lines> — what connector.json says above a question
# (its "hint", the lines joined by |), dim, wrapped and counted for the redraw.
_exakit_vs_tui_hint() {
    [ -n "$1" ] || return 0
    _eth_rest="$1|"
    while [ -n "$_eth_rest" ]; do
        _eth_line="${_eth_rest%%|*}"; _eth_rest="${_eth_rest#*|}"
        [ -n "$_eth_line" ] || continue
        _ui_wrap "$_eth_line" $(( _EVT_COLS - 4 ))
        _eth_k=0
        while [ "$_eth_k" -lt "$_UI_WRAP_N" ]; do
            printf '  %s%s%s\n' "$UI_DIM" "${_UI_WRAP[$_eth_k]}" "$UI_RESET"
            _eth_k=$(( _eth_k + 1 ))
        done
        _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + _UI_WRAP_N ))
    done
}

# _exakit_vs_tui_draft — the mapping drafted from the bucket or container when
# its field was left empty (or auto:<folder>/), after the credential was given:
# a spinner while the engine lists and samples it (cli.py draft, the
# credential on its stdin), then its tables under the panel and one key -
# Enter uses them, e opens the folder to edit them first, n asks for a mapping
# path instead. A store that cannot be listed is said, and the path asked for
# (required then). Returns 1 at end of input. Twin of Invoke-ExakitVsTuiDraft.
_exakit_vs_tui_draft() {
    _etd_i=0
    while [ "$_etd_i" -lt "$_EVT_NF" ]; do
        [ -n "${_EVT_DRAFT[$_etd_i]:-}" ] && break
        _etd_i=$(( _etd_i + 1 ))
    done
    [ "$_etd_i" -lt "$_EVT_NF" ] || return 0
    _etd_where="${_EVT_DRAFT[$_etd_i]}"
    while :; do
        case "${_EVT_VAL[$_etd_i]}" in ''|auto:*) ;; *) return 0 ;; esac
        _etd_sec=""; _etd_f=0
        while [ "$_etd_f" -lt "$_EVT_NF" ]; do
            [ "${_EVT_KIND[$_etd_f]}" = secret ] && _etd_sec="${_EVT_VAL[$_etd_f]}"
            _etd_f=$(( _etd_f + 1 ))
        done
        _exakit_vs_tui_draw "$_evo_title" -1
        ui_spin_begin "Drafting the mapping from the $_etd_where..."
        if [ -n "$_etd_sec" ]; then
            printf '%s' "$_etd_sec" | _exakit_vs_tui_engine "$(_exakit_vs_tui_args)" draft --secret-stdin \
                > "$_EVT_DIR/draft" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        elif [ -n "$_evo_pwfile" ]; then
            _exakit_vs_tui_engine "$(_exakit_vs_tui_args)" draft --secret-stdin < "$_evo_pwfile" \
                > "$_EVT_DIR/draft" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        else
            : > "$_EVT_DIR/draft"
        fi
        _etd_rc=$?
        ui_spin_end
        _etd_sec=""
        if [ "$_etd_rc" -ne 0 ] || ! grep -q '^RESULT ' "$_EVT_DIR/draft"; then
            _etd_why="$(sed -n 's/^FAIL //p' "$_EVT_DIR/draft" | head -1)"
            rm -f "$_EVT_DIR/draft"
            [ -n "$_etd_why" ] || _etd_why="the mapping could not be drafted"
            _EVT_REQ[$_etd_i]=1
            _exakit_vs_tui_field "$_etd_i" "$_etd_why" || return 1
            _EVT_REQ[$_etd_i]=""
            continue
        fi
        _etd_folder="$(_exakit_vs_result "$_EVT_DIR/draft" | run_python_any -c 'import json,sys; print(json.load(sys.stdin)["folder"])')"
        while IFS= read -r _etd_line; do
            printf '    %s\n' "$_etd_line"
            _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + 1 ))
        done <<EOF
$(_exakit_vs_result "$_EVT_DIR/draft" | run_python_any -c 'import json,sys; print("\n".join(json.load(sys.stdin)["summary"]))')
EOF
        sed -n 's/^WARN //p' "$_EVT_DIR/draft" | while IFS= read -r _etd_line; do
            printf '    %s!%s %s\n' "$UI_WARN" "$UI_RESET" "$_etd_line"
        done
        _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + $(grep -c '^WARN ' "$_EVT_DIR/draft") ))
        rm -f "$_EVT_DIR/draft"
        _etd_q="Enter to use these $UI_BULLET e to open the folder and edit $UI_BULLET n to give a folder instead"
        while :; do
            _exakit_vs_tui_choose "$_etd_q" "$UI_ASK$_etd_q$UI_RESET"
            case "$_EVK" in
                eof) return 1 ;;
                n|N|esc)
                    _EVT_DRAFTED[$_etd_i]=""; _EVT_REQ[$_etd_i]=1
                    _EVT_VAL[$_etd_i]="$_etd_folder"
                    _exakit_vs_tui_field "$_etd_i" || return 1
                    _EVT_REQ[$_etd_i]=""
                    break ;;
                e|E)
                    if command -v open >/dev/null 2>&1 && [ "$(uname -s)" = Darwin ]; then open "$_etd_folder" >/dev/null 2>&1
                    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$_etd_folder" >/dev/null 2>&1 &
                    fi
                    _exakit_vs_tui_say "$UI_DIM$UI_BULLET$UI_RESET" "The mapping files are in $_etd_folder"
                    _exakit_vs_tui_ask "Enter when the files are saved" "${UI_ASK}Enter when the files are saved$UI_RESET" 0 || return 1
                    printf '%s' "$_etd_folder" | exakit_vs_engine field "$_evo_id" "${_EVT_NAME[$_etd_i]}" \
                        > "$_EVT_DIR/field" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
                    if [ $? -ne 0 ]; then
                        _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$(sed -n 's/^FAIL //p' "$_EVT_DIR/field" | head -1)"
                        continue
                    fi
                    _EVT_VAL[$_etd_i]="$_etd_folder"; _EVT_DRAFTED[$_etd_i]="$_etd_folder"
                    break ;;
                *) _EVT_VAL[$_etd_i]="$_etd_folder"; _EVT_DRAFTED[$_etd_i]="$_etd_folder"; break ;;
            esac
        done
        return 0
    done
}

# _exakit_vs_tui_walk [why] — every field not answered yet, in order; 1 at end
# of input. Twin of Invoke-ExakitVsTuiWalk.
_exakit_vs_tui_walk() {
    _etw_f=0
    while [ "$_etw_f" -lt "$_EVT_NF" ]; do
        if [ -z "${_EVT_DONE[$_etw_f]}" ]; then _exakit_vs_tui_field "$_etw_f" "${1:-}" || return 1; fi
        _etw_f=$(( _etw_f + 1 ))
    done
    return 0
}

# _exakit_vs_tui_review [why] — the summary before the plan: the panel with
# every answer numbered (a credential as hidden, a key file by its path), with
# why it is shown again when a plan refused. A number asks that one field again,
# then the summary comes back; Enter goes on. Once a plan has refused this source
# (_evo_refused), skip leaves it out. Returns 1 at end of input, 2 for skip.
# Twin of Invoke-ExakitVsTuiReview.
_exakit_vs_tui_review() {
    _etv_why="${1:-}"
    _etv_q="Number to change, Enter to continue"
    [ -n "${_evo_refused:-}" ] && _etv_q="$_etv_q, skip to leave this source out"
    _etv_deco=$'\001'"$UI_ASK"$'\002'"Number to change"$'\001'"$UI_RESET$UI_DIM"$'\002'"${_etv_q#Number to change}"$'\001'"$UI_RESET"$'\002'
    while :; do
        _exakit_vs_tui_draw "$_evo_title" -1 numbered
        [ -n "$_etv_why" ] && _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$_etv_why"
        _exakit_vs_tui_ask "$_etv_q" "$_etv_deco" 0 || return 1
        _etv_n="$(printf '%s' "$_EVT_ANSWER" | tr -d ' ')"
        [ "$_etv_n" = skip ] && [ -n "${_evo_refused:-}" ] && return 2
        if [ -z "$_etv_n" ]; then
            # The answers as they stand, ticked again, the question gone.
            _exakit_vs_tui_draw "$_evo_title" -1
            return 0
        fi
        case "$_etv_n" in
            [0-9]|[0-9][0-9])
                _etv_n=$(( 10#$_etv_n ))
                if [ "$_etv_n" -ge 1 ] && [ "$_etv_n" -le "$_EVT_NF" ]; then
                    _exakit_vs_tui_field $(( _etv_n - 1 )) || return 1
                    _etv_why=""
                    continue
                fi ;;
        esac
        _etv_why="give a number from 1 to $_EVT_NF, or press Enter to continue"
    done
}

# _exakit_vs_tui_example <text> — one example under the hint, indented under its
# text and dim; one wider than the terminal is wrapped at the same indent, and
# every line is counted for the next redraw.
_exakit_vs_tui_example() {
    _ui_wrap "$1" $(( _EVT_COLS - 10 ))
    _ete_k=0
    while [ "$_ete_k" -lt "$_UI_WRAP_N" ]; do
        printf '        %s%s%s\n' "$UI_DIM" "${_UI_WRAP[$_ete_k]}" "$UI_RESET"
        _ete_k=$(( _ete_k + 1 ))
    done
    _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + _UI_WRAP_N ))
}

# _exakit_vs_tui_choose <plain> <colour> — the question after a pasted string,
# answered by one key (_exakit_vs_key): Enter, e, n or Esc into _EVK, eof at end
# of input; any other key is no answer. A terminal that cannot read single keys
# uses the string (enter), as before the question existed.
_exakit_vs_tui_choose() {
    printf '  %s ' "$2"
    while :; do
        _exakit_vs_key || { _EVK=enter; break; }
        case "$_EVK" in enter|esc|eof|e|E|n|N) break ;; esac
    done
    printf '\n'
    _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + $(_exakit_vs_tui_rows $(( ${#1} + 3 ))) ))
}

# _exakit_vs_tui_secret_from <value> — the form's credential field answered by a
# pasted connection string: given, marked "from the string" (the panel shows
# "(from the string, hidden)") and not asked. Twin of Set-ExakitVsTuiSecretFrom.
_exakit_vs_tui_secret_from() {
    _ets_f=0
    while [ "$_ets_f" -lt "$_EVT_NF" ]; do
        if [ "${_EVT_KIND[$_ets_f]}" = secret ] && [ "${_EVT_NAME[$_ets_f]}" != storage_secret ]; then
            _EVT_VAL[$_ets_f]="$1"; _EVT_DONE[$_ets_f]=1; _EVT_FROM[$_ets_f]=1
            return 0
        fi
        _ets_f=$(( _ets_f + 1 ))
    done
}

# _exakit_vs_tui_paste — the form's first question, for a connector that reads a
# connection string (its paste block), under a hint and one example per line:
# read hidden, the string goes to the engine's paste on stdin, never in argv,
# and is not kept. It is shown back with its credentials masked by the engine
# ("Read: ..."), and one key decides: Enter uses it, e asks for it again, Esc or
# n types the fields instead. What it names is answered, marked "from the
# string" and not asked - its credential too, "(from the string, hidden)",
# unless --password-file gives one; the engine's notes and the masked string
# stay under the panel. A string it
# cannot read is said, in the engine's words, and asked again; Enter types the
# fields instead. Returns 1 at end of input. Twin of Invoke-ExakitVsTuiPaste.
_exakit_vs_tui_paste() {
    _etp_forms="$(_exakit_vs_paste_forms "$_evo_id")"
    [ -n "$_etp_forms" ] || return 0
    _etp_why=""
    # Read with echo off, as a password is: the string often holds one. What
    # was read is shown back masked, and the fields it filled.
    _etp_q="Connection string (hidden) - paste + Enter, or Enter alone for the fields"
    _etp_deco="${UI_ASK}Connection string$UI_RESET $UI_DIM(hidden) - paste + Enter, or Enter alone for the fields$UI_RESET"
    _etp_c="$(_exakit_vs_paste_choice_text)"
    # Where there is room, the question says a field can still be changed.
    _etp_more=" $( [ "${UI_BULLET:-}" = '-' ] && printf '%s' '-' || printf '%s' '·' ) every field can be changed in the summary"
    [ $(( ${#_etp_c} + ${#_etp_more} + 3 )) -lt "$_EVT_COLS" ] && _etp_c="$_etp_c$_etp_more"
    while :; do
        _exakit_vs_tui_draw "$_evo_title" -1
        _exakit_vs_tui_say "$UI_DIM$UI_BULLET$UI_RESET" "Paste the source's connection string, for example:"
        while IFS= read -r _etp_f; do
            [ -n "$_etp_f" ] && _exakit_vs_tui_example "$_etp_f"
        done <<EOF
$_etp_forms
EOF
        [ -n "$_etp_why" ] && _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$_etp_why"
        _etp_why=""
        _EVT_NOHIDE=""
        if ! _exakit_vs_tui_ask "$_etp_q" "$_etp_deco" 1; then
            # A terminal that cannot hide input is not asked: the fields are.
            [ -n "$_EVT_NOHIDE" ] && return 0
            return 1
        fi
        [ -n "$_EVT_ANSWER" ] || return 0
        # The string's credential, where the connector's stands, lands in
        # this run's own folder (owner-only) - unless --password-file gives one.
        if [ -n "$_evo_pwfile" ]; then
            printf '%s' "$_EVT_ANSWER" | exakit_vs_engine paste "$_evo_id" --credential-given > "$_EVT_DIR/paste" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        else
            : > "$_EVT_DIR/paste.secret"; chmod 600 "$_EVT_DIR/paste.secret"
            printf '%s' "$_EVT_ANSWER" | exakit_vs_engine paste "$_evo_id" --secret-out "$_EVT_DIR/paste.secret" > "$_EVT_DIR/paste" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        fi
        _etp_rc=$?
        _EVT_ANSWER=""
        if [ "$_etp_rc" -ne 0 ]; then
            rm -f "$_EVT_DIR/paste.secret"
            _etp_why="$(sed -n 's/^FAIL //p' "$_EVT_DIR/paste" | head -1)"
            [ -n "$_etp_why" ] || _etp_why="the connection string could not be read"
            continue
        fi
        _etp_masked="$(_exakit_vs_paste_masked "$_EVT_DIR/paste")"
        _exakit_vs_tui_say "$UI_DIM$UI_BULLET$UI_RESET" "Read: $_etp_masked"
        _exakit_vs_tui_choose "$_etp_c" "$UI_ASK$_etp_c$UI_RESET"
        case "$_EVK" in
            e|E) rm -f "$_EVT_DIR/paste" "$_EVT_DIR/paste.secret"; continue ;;
            n|N|esc) rm -f "$_EVT_DIR/paste" "$_EVT_DIR/paste.secret"; return 0 ;;
            eof) rm -f "$_EVT_DIR/paste" "$_EVT_DIR/paste.secret"; return 1 ;;
        esac
        _etp_pairs="$(_exakit_vs_result "$_EVT_DIR/paste" | run_python_any -c 'import json, sys
for k, v in json.load(sys.stdin)["values"].items():
    print("%s=%s" % (k, v))')"
        while IFS= read -r _etp_kv; do
            [ -n "$_etp_kv" ] || continue
            _etp_f=0
            while [ "$_etp_f" -lt "$_EVT_NF" ]; do
                if [ "${_EVT_NAME[$_etp_f]}" = "${_etp_kv%%=*}" ]; then
                    _EVT_VAL[$_etp_f]="${_etp_kv#*=}"; _EVT_DONE[$_etp_f]=1; _EVT_FROM[$_etp_f]=1
                fi
                _etp_f=$(( _etp_f + 1 ))
            done
        done <<EOF
$_etp_pairs
EOF
        [ -s "$_EVT_DIR/paste.secret" ] && _exakit_vs_tui_secret_from "$(cat "$_EVT_DIR/paste.secret")"
        rm -f "$_EVT_DIR/paste.secret"
        _EVT_NOTES="INFO Read: $_etp_masked
$(grep -E '^(WARN|INFO) ' "$_EVT_DIR/paste" | _exakit_vs_paste_typed)"
        rm -f "$_EVT_DIR/paste"
        return 0
    done
}

# _exakit_vs_tui_named <message> — the field a plan's refusal names: its index
# when it names one, -2 when it names several, -1 when none. Input names count
# first, as whole words in any case ("host", "tls=verify", "URI"; the source
# name as "source name", not the bare word); only when none is named, the
# labels, the same way ("Port" is not "report"). Twin of Find-ExakitVsTuiNamed.
_exakit_vs_tui_named() {
    run_python_any - "$_EVT_DIR/fields" "$1" <<'PY' 2>/dev/null || printf '%s\n' -1
import re, sys
fields = [(line.split("|") + ["", "", ""])[:3] for line in open(sys.argv[1]).read().splitlines()[1:]]
text = sys.argv[2]
def named(word):
    return bool(word) and re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(word), text, re.I) is not None
hits = [i for i, (name, _, kind) in enumerate(fields) if named("source name" if kind == "source-name" else name)]
if not hits:
    hits = [i for i, (_, label, _) in enumerate(fields) if named(label)]
print(hits[0] if len(hits) == 1 else (-2 if hits else -1))
PY
}

# _exakit_vs_tui_form <connector> <pos> <total> <given-name> <given-sets> <password-file>
# — one source's panel; on success it joins the _EVT_S_* lists. Returns 5 when
# the reader left it out, 2 when its definition could not be read.
# _exakit_vs_tui_inputs <sets> — the engine's inputs for the form's connector,
# the KEY=VALUE lines given so far after it, into $_EVT_DIR/inputs.
_exakit_vs_tui_inputs() {
    set -- inputs "$_evo_id"
    while IFS= read -r _eti_kv; do [ -n "$_eti_kv" ] && set -- "$@" --set "$_eti_kv"; done <<EOF
$_evo_sets
EOF
    exakit_vs_engine "$@" < /dev/null > "$_EVT_DIR/inputs" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
}

# _exakit_vs_tui_settings — a connector with settings (lakehouse): every setting
# the picker did not preset (exakit_vs_preset) and the command line did not
# give, asked one line each before the panel - catalog, then files (only the
# ones that catalog takes), then login - and added to _evo_sets. Returns 1 at
# end of input or when the engine refuses the settings. ⇄ twin: Read-ExakitVsTuiSettings.
_exakit_vs_tui_settings() {
    while :; do
        _exakit_vs_tui_inputs || return 1
        _ets_open="$(_exakit_vs_result "$_EVT_DIR/inputs" | run_python_any -c 'import json, sys
doc = json.load(sys.stdin)
given = [l.split("=", 1)[0] for l in sys.argv[1].splitlines() if "=" in l]
for f in doc["inputs"]:
    if f.get("setting") and f["name"] not in given:
        print("|".join([f["name"], f["label"], " ".join(f["choices"]), f.get("default") or "",
                        "; ".join("%s: %s" % c for c in zip(f["choices"], f.get("choice_labels") or f["choices"]))]))
        break' "$_evo_sets" 2>/dev/null)"
        [ -n "$_ets_open" ] || return 0
        IFS='|' read -r _ets_name _ets_label _ets_choices _ets_def _ets_words <<EOF
$_ets_open
EOF
        printf '  %s%s%s\n' "${UI_DIM:-}" "$_ets_words" "${UI_RESET:-}" >&2
        _ets_v="$(prompt_text "$_ets_label ($(printf '%s' "$_ets_choices" | sed 's/ /, /g'))" "$_ets_def")" || return 1
        case " $_ets_choices " in
            *" $_ets_v "*) _evo_sets="$_evo_sets
$_ets_name=$_ets_v" ;;
            *) printf '  %s%s%s %s\n' "$UI_ERR" "$UI_CROSS" "$UI_RESET" "$_ets_label must be one of: $_ets_choices" >&2 ;;
        esac
    done
}

_exakit_vs_tui_form() {
    _evo_id="$1"; _evo_pos="$2"; _evo_total="$3"; _evo_pwfile="$6"
    # The picker's presets for this connector first, the command line's --set over them.
    _evo_sets="$(printf '%s' "${_EXAKIT_VS_PRESET:-}" | sed -n "s/^$_evo_id //p")
$5"
    if [ -f "$(exakit_vs_defs)/connectors/$_evo_id/connector.json" ] && \
       grep -q '"settings"' "$(exakit_vs_defs)/connectors/$_evo_id/connector.json"; then
        _exakit_vs_tui_settings || { _exakit_vs_render "$_EVT_DIR/inputs"; return 5; }
    fi
    _exakit_vs_tui_inputs || {
        _exakit_vs_render "$_EVT_DIR/inputs"
        # An engine older than this file (a kit copy updated by halves) has no
        # "inputs": say so, and how the line-by-line path still works.
        error "The connect form could not read $_evo_id's inputs. Update the kit (exakit update), or connect without the form: exakit connect $_evo_id --name <name> --set KEY=VALUE ... --yes"
        return 2; }
    # First line the connector's name, then name|label|kind|required|default|choices.
    # A long prose label is cut to its first clause; the prompt has room for the rest.
    run_python_any - "$(_exakit_vs_result "$_EVT_DIR/inputs")" > "$_EVT_DIR/fields" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
print(doc["name"])
for f in doc["inputs"]:
    label = f["label"]
    # The kit's own "Name (alias) for this connection" is said whole.
    for cut in (" - ", " (", "; ") if f["kind"] != "source-name" else ():
        label = label.split(cut)[0]
    # Then what the question is drafted from when left empty, its own words,
    # and the lines said above it (the rest of the line, one per |).
    print("|".join(str(x).replace("|", "/") for x in
                   (f["name"], label, f["kind"], "1" if f["required"] else "", f["default"], " ".join(f["choices"]),
                    f.get("draft") or "", f.get("prompt") or "") + tuple(f.get("hint") or ())))
PY
    _evo_label=""
    _EVT_NAME=(); _EVT_LAB=(); _EVT_LABF=(); _EVT_KIND=(); _EVT_REQ=(); _EVT_DEF=(); _EVT_CH=(); _EVT_VAL=(); _EVT_DONE=()
    _EVT_FROM=(); _EVT_NOTES=""; _EVT_DRAFT=(); _EVT_HINT=(); _EVT_DRAFTED=()
    _EVT_NF=0; _EVT_LW=0
    while IFS='|' read -r _evo_n _evo_l _evo_k _evo_r _evo_d _evo_c _evo_dr _evo_pr _evo_h; do
        if [ -z "$_evo_label" ]; then _evo_label="$_evo_n"; continue; fi
        _EVT_NAME[$_EVT_NF]="$_evo_n"; _EVT_LAB[$_EVT_NF]="$_evo_l"; _EVT_LABF[$_EVT_NF]="${_evo_pr:-$_evo_l}"; _EVT_KIND[$_EVT_NF]="$_evo_k"
        _EVT_DRAFT[$_EVT_NF]="$_evo_dr"; _EVT_HINT[$_EVT_NF]="$_evo_h"; _EVT_DRAFTED[$_EVT_NF]=""
        _EVT_REQ[$_EVT_NF]="$_evo_r"; _EVT_DEF[$_EVT_NF]="$_evo_d"; _EVT_CH[$_EVT_NF]="$_evo_c"
        _EVT_VAL[$_EVT_NF]=""; _EVT_DONE[$_EVT_NF]=""; _EVT_FROM[$_EVT_NF]=""
        # What the command line already said is an answer, not a question.
        if [ "$_evo_k" = source-name ] && [ -n "$4" ]; then _EVT_VAL[$_EVT_NF]="$4"; _EVT_DONE[$_EVT_NF]=1; fi
        _evo_given="$(printf '%s\n' "$_evo_sets" | sed -n "s/^$_evo_n=//p" | tail -1)"
        [ -n "$_evo_given" ] && { _EVT_VAL[$_EVT_NF]="$_evo_given"; _EVT_DONE[$_EVT_NF]=1; }
        if [ "$_evo_n" = storage_secret ]; then
            # The second secret: --storage-secret-file answers it, never --password-file.
            [ -n "${_EXAKIT_VS_STORAGE_FILE:-}" ] && [ "$_evo_total" -eq 1 ] && _EVT_DONE[$_EVT_NF]=1
        elif [ -n "$_evo_pwfile" ]; then
            case "$_evo_k" in
                secret) _EVT_DONE[$_EVT_NF]=1 ;;
                secret-file) _EVT_VAL[$_EVT_NF]="$_evo_pwfile"; _EVT_DONE[$_EVT_NF]=1 ;;
            esac
        fi
        # The label column holds a required one's " *" too (_exakit_vs_tui_frame).
        _evo_w=${#_evo_l}; [ -n "$_evo_r" ] && _evo_w=$(( _evo_w + 2 ))
        [ "$_evo_w" -gt "$_EVT_LW" ] && _EVT_LW=$_evo_w
        _EVT_NF=$(( _EVT_NF + 1 ))
    done < "$_EVT_DIR/fields"
    # 34: the kit's own "Name (alias) for this connection *" whole - on a
    # narrow terminal less, so a value keeps 18 columns (the question under
    # the panel says the label whole).
    _evo_cap=$(( _EVT_IN - 7 - 18 )); [ "$_evo_cap" -le 34 ] || _evo_cap=34; [ "$_evo_cap" -ge 12 ] || _evo_cap=12
    [ "$_EVT_LW" -le "$_evo_cap" ] || _EVT_LW="$_evo_cap"
    _evo_f=0
    while [ "$_evo_f" -lt "$_EVT_NF" ]; do
        _evo_w="$_EVT_LW"; [ -n "${_EVT_REQ[$_evo_f]}" ] && _evo_w=$(( _EVT_LW - 2 ))
        _EVT_LAB[$_evo_f]="$(_exakit_vs_tui_short "${_EVT_LAB[$_evo_f]}" "$_evo_w")"
        _evo_f=$(( _evo_f + 1 ))
    done
    _evo_title="$_evo_pos of $_evo_total · $_evo_label"
    _EVT_ON_SCREEN=0
    # A credential --url's string held (_exakit_vs_paste) answers this one
    # form's, unless --password-file gives it.
    if [ -n "${_EVP_SECRET:-}" ]; then
        [ -n "$_evo_pwfile" ] || _exakit_vs_tui_secret_from "$_EVP_SECRET"
        unset _EVP_SECRET; _EVP_SECRET=""
    fi
    # 1. A connection string first, when the command line answered nothing but
    # the name: what it names is answered (and marked so), the rest asked next.
    _evo_asked=""; _evo_f=0
    while [ "$_evo_f" -lt "$_EVT_NF" ]; do
        case "${_EVT_KIND[$_evo_f]}" in
            source-name|secret|secret-file) ;;
            *) [ -n "${_EVT_DONE[$_evo_f]}" ] && _evo_asked=1 ;;
        esac
        _evo_f=$(( _evo_f + 1 ))
    done
    if [ -z "$_evo_asked" ]; then _exakit_vs_tui_paste || return 5; fi
    # 2. every field not answered yet
    _exakit_vs_tui_walk || return 5
    _evo_refused=""; _evo_again=""
    while :; do
        # A mapping left empty: drafted now that the credential is in (S3, Azure).
        _exakit_vs_tui_draft || return 5
        # 3. the numbered summary: one answer at a time asked again, then Enter
        _exakit_vs_tui_review "$_evo_again" || return 5
        _evo_again=""
        # The whole source, checked by the plan: what one field cannot see (a CA
        # with tls=require), and what will be downloaded.
        _exakit_vs_tui_engine "$(_exakit_vs_tui_args)" plan < /dev/null \
            > "$_EVT_DIR/plan.$_EVT_COUNT" 2>>"${EXAKIT_LOG_FILE:-/dev/null}" && break
        _evo_why="$(sed -n 's/^FAIL //p' "$_EVT_DIR/plan.$_EVT_COUNT" | head -1)"
        _evo_refused=1
        # A refusal that names one input goes straight back to that one, its
        # reason above the question; one that names several opens the summary
        # with the reason; any other is said, and every answer can be given
        # again. The summary then offers skip, so no refusal is a dead end.
        _evo_at="$(_exakit_vs_tui_named "$_evo_why")"
        case "$_evo_at" in -2) ;; ''|*[!0-9]*) _evo_at=-1 ;; esac
        if [ "$_evo_at" -ge 0 ]; then
            _exakit_vs_tui_field "$_evo_at" "$_evo_why" || return 5
            continue
        fi
        if [ "$_evo_at" -eq -2 ]; then _evo_again="$_evo_why"; continue; fi
        _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$_evo_why"
        _exakit_vs_tui_yes "Change the answers?" || return 5
        _evo_f=0
        while [ "$_evo_f" -lt "$_EVT_NF" ]; do _EVT_DONE[$_evo_f]=""; _evo_f=$(( _evo_f + 1 )); done
        _evo_pwfile=""
        _exakit_vs_tui_walk "$_evo_why" || return 5
    done
    # Kept for the review and the run, one entry per source.
    _evo_name=""; _evo_secret=""; _evo_sfile=""; _evo_sets=""; _evo_where=""; _evo_storage=""; _evo_stfile=""
    _evo_f=0
    while [ "$_evo_f" -lt "$_EVT_NF" ]; do
        _evo_v="${_EVT_VAL[$_evo_f]}"
        case "${_EVT_KIND[$_evo_f]}" in
            source-name) _evo_name="$_evo_v" ;;
            secret) if [ "${_EVT_NAME[$_evo_f]}" = storage_secret ]; then _evo_storage="$_evo_v"
                    else _evo_secret="$_evo_v"; fi ;;
            secret-file) _evo_sfile="$_evo_v" ;;
            *) [ -n "$_evo_v" ] && _evo_sets="$_evo_sets${_EVT_NAME[$_evo_f]}=$_evo_v"$'\n'
               case "${_EVT_NAME[$_evo_f]}" in
                   host|bucket|account|project|uri|region) [ -z "$_evo_where" ] && _evo_where="$_evo_v" ;;
               esac ;;
        esac
        _evo_f=$(( _evo_f + 1 ))
    done
    [ -z "$_evo_secret" ] && [ -z "$_evo_sfile" ] && [ -n "$_evo_pwfile" ] && _evo_sfile="$_evo_pwfile"
    # A second secret given as a file (--storage-secret-file) is read at the run.
    if [ -z "$_evo_storage" ] && [ "$_evo_total" -eq 1 ]; then
        for _evo_n in "${_EVT_NAME[@]}"; do
            [ "$_evo_n" = storage_secret ] && _evo_stfile="${_EXAKIT_VS_STORAGE_FILE:-}"
        done
    fi
    _evo_where="${_evo_where#*://}"; _evo_where="${_evo_where%%/*}"
    # A host name shows its first label (exakit-vs-test-pg): what a reader recognises.
    case "$_evo_where" in *.*[a-zA-Z]*) _evo_where="${_evo_where%%.*}" ;; esac
    _EVT_S_ID[$_EVT_COUNT]="$_evo_id"; _EVT_S_NAME[$_EVT_COUNT]="$_evo_name"
    _EVT_S_LABEL[$_EVT_COUNT]="$_evo_label"; _EVT_S_SETS[$_EVT_COUNT]="$_evo_sets"
    _EVT_S_SECRET[$_EVT_COUNT]="$_evo_secret"; _EVT_S_SFILE[$_EVT_COUNT]="$_evo_sfile"
    _EVT_S_STORAGE[$_EVT_COUNT]="$_evo_storage"; _EVT_S_STFILE[$_EVT_COUNT]="$_evo_stfile"; _evo_storage=""
    _EVT_S_WHERE[$_EVT_COUNT]="$(_exakit_vs_tui_short "$_evo_where" 18)"
    _EVT_TAKEN="${_EVT_TAKEN:-} $_evo_name"
    _EVT_COUNT=$(( _EVT_COUNT + 1 ))
    printf '\n'
    return 0
}

# _exakit_vs_tui_dl <cell> <width> — a Downloads cell cut to the width, its
# size kept: "adapter 4.1.0 · dri… · 3 MB".
_exakit_vs_tui_dl() {
    if [ "${#1}" -le "$2" ]; then printf '%s' "$1"; return 0; fi
    case "$1" in
        *" · "*) _etd_mb=" · ${1##* · }"
                 printf '%s%s' "$(_exakit_vs_tui_short "${1% · *}" $(( $2 - ${#_etd_mb} )))" "$_etd_mb" ;;
        *) _exakit_vs_tui_short "$1" "$2" ;;
    esac
}

# _exakit_vs_tui_table <state-file> <title> <indexes...> — a table of finished
# forms, every row waiting.
_exakit_vs_tui_table() {
    _ett_state="$1"; _ett_title="$2"; shift 2
    : > "$_ett_state"
    # The Source cell names where it is too. The Downloads cell is cut to what
    # the terminal has beside the other columns, one line a row, as Where was
    # cut to 18; too narrow even for that, the table's own rules wrap it, then
    # leave it out.
    _ett_namew=10; _ett_srcw=6; _ett_dlw=9
    for _ett_i in "$@"; do
        _ett_src="${_EVT_S_LABEL[$_ett_i]}"
        [ -n "${_EVT_S_WHERE[$_ett_i]}" ] && _ett_src="$_ett_src · ${_EVT_S_WHERE[$_ett_i]}"
        _EVT_S_SRC[$_ett_i]="$_ett_src"
        [ $(( ${#_EVT_S_NAME[$_ett_i]} + 3 )) -gt "$_ett_namew" ] && _ett_namew=$(( ${#_EVT_S_NAME[$_ett_i]} + 3 ))
        [ "${#_ett_src}" -gt "$_ett_srcw" ] && _ett_srcw="${#_ett_src}"
        _ett_dl="${_EVT_S_DL[$_ett_i]:-}"
        [ "${#_ett_dl}" -gt "$_ett_dlw" ] && _ett_dlw="${#_ett_dl}"
    done
    # The chrome (12), the name, the source, the Status floor (38), the gaps.
    _ett_room=$(( $(_ui_term_cols) - 12 - _ett_namew - 2 - _ett_srcw - 2 - 38 - 2 ))
    [ "$_ett_room" -lt "$_ett_dlw" ] && [ "$_ett_room" -ge 12 ] && _ett_dlw="$_ett_room"
    _ett_k=0
    for _ett_i in "$@"; do
        _ett_k=$(( _ett_k + 1 ))
        _ett_tree=tee; [ "$_ett_k" -eq "$#" ] && _ett_tree=corner
        printf '%s|%s|1|waiting|||||||%s|%s\n' "$_ett_tree" "${_EVT_S_NAME[$_ett_i]}" \
            "${_EVT_S_SRC[$_ett_i]}" "$(_exakit_vs_tui_dl "${_EVT_S_DL[$_ett_i]:-}" "$_ett_dlw")" >> "$_ett_state"
    done
    UI_TABLE_TITLE="$_ett_title"
    UI_TABLE_COL1="Name (alias)"; UI_TABLE_COL2="Source"; UI_TABLE_COL3="Downloads"
    # As wide as its longest cell, not the add-on descriptions' 44; a Status
    # floor that holds this table's longest status (34 and its tick), not 44:
    # the room goes to Downloads.
    UI_TABLE_COL3_FIXED="$_ett_dlw"; UI_TABLE_COL3_MAX="$_ett_dlw"; UI_TABLE_STAT_MIN=38
}

# _exakit_vs_tui_table_done — the connect table's headings and widths back to
# what other tables expect.
_exakit_vs_tui_table_done() {
    UI_TABLE_COL2=""; UI_TABLE_COL3=""
    unset UI_TABLE_COL3_FIXED UI_TABLE_COL3_MAX UI_TABLE_STAT_MIN
}

# _exakit_vs_tui_footer — the lines under the connect table: every download is
# checked and cached (_evt_bytes, its total), and, when the kit's MCP
# read-only user exists, that the AI clients read the new schemas through it.
# _EVT_FOOT_N is how many rows they took.
_exakit_vs_tui_footer() {
    _EVT_FOOT_N=0
    _etf_mb=$(( (_evt_bytes + 500000) / 1000000 ))
    if [ "$_evt_bytes" -gt 0 ]; then
        [ "$_etf_mb" -gt 0 ] || _etf_mb="<1"
        _etf_say="Every file is SHA-256 checked before it reaches the database. Total $_etf_mb MB, kept in the cache for next time."
    else
        _etf_say="Every file is SHA-256 checked before it reaches the database. All of them are in the cache already."
    fi
    info "$_etf_say"
    _EVT_FOOT_N=$(( _EVT_FOOT_N + $(_exakit_vs_tui_rows $(( ${#_etf_say} + 6 ))) ))
    if [ -n "$_evt_exposed" ] && [ -f "$EXAKIT_CREDS_DIR/mcp_readonly_password" ]; then
        _etf_say="Your AI clients read these schemas through the kit's read-only MCP user."
        info "$_etf_say"
        _EVT_FOOT_N=$(( _EVT_FOOT_N + $(_exakit_vs_tui_rows $(( ${#_etf_say} + 6 ))) ))
    fi
}

# _exakit_vs_tui_prepare <lines-on-screen> <language...> — the language
# containers the picked sources need (java, rust; repeats allowed) that the
# database lacks, installed before the table runs, under one step header:
# Java, then its restart, then Rust and its. The review (that many lines) is
# cleared first, so the live table that follows is the only one. Returns 1
# when nothing was needed (nothing is printed), or the database could not be
# asked - a source that then needs one is prepared below the table, as before.
# _EVT_PREPARED names the languages tried.
_exakit_vs_tui_prepare() {
    _etp_over="$1"; shift
    _etp_need=""
    for _etp_l in java rust; do
        case " $* " in *" $_etp_l "*) _etp_need="$_etp_need $_etp_l" ;; esac
    done
    [ -n "$_etp_need" ] || return 1
    # shellcheck disable=SC2086 — language names
    exakit_vs_engine languages $_etp_need < /dev/null > "$_EVT_DIR/languages" 2>>"${EXAKIT_LOG_FILE:-/dev/null}" || return 1
    _etp_missing="$(_exakit_vs_result "$_EVT_DIR/languages" | run_python_any -c 'import json, sys
print(" ".join(json.load(sys.stdin).get("missing") or []))' 2>/dev/null)"
    [ -n "$_etp_missing" ] || return 1
    if [ "${UI_FANCY:-0}" = 1 ] && [ -t 1 ] && [ "$_etp_over" -gt 0 ]; then
        printf '\r\033[%dA\033[0J' "$_etp_over"
    fi
    exakit_step_heading "Preparing the database"
    for _etp_l in java rust; do
        case " $_etp_missing " in *" $_etp_l "*) ;; *) continue ;; esac
        _EVT_PREPARED="$_EVT_PREPARED $_etp_l"
        case "$_etp_l" in
            java) _exakit_vs_install_java ;;
            rust) _exakit_vs_install_rust ;;
        esac
    done
    printf '\n'
    return 0
}

# _exakit_vs_tui_run <state-file> <indexes...> — connect those sources one after
# another while the table on screen follows. One at a time on purpose: parallel
# connects contend for the same database objects. Collects _EVT_OK, _EVT_FAILED,
# _EVT_NEEDS (sources waiting for a language container, or for the restart
# Docker's DNS repair needs) and _EVT_RC.
_exakit_vs_tui_run() {
    _etr_state="$1"; shift
    _etr_row=0
    for _etr_i in "$@"; do
        _etr_row=$(( _etr_row + 1 ))
        _etr_out="$_EVT_DIR/run.$_etr_i"
        _etr_args="$(_exakit_vs_tui_source_args "$_etr_i")"
        _etr_t0="$(date +%s 2>/dev/null || echo 0)"
        _etr_try=0; _etr_restart=""
        while :; do
            _etr_try=$(( _etr_try + 1 ))
            ui_table_set "$_etr_state" "$_etr_row" running 2 18 8 "starting"
            (
                ui_table_detach
                # --json: the events (OK/INFO/WARN/FAIL) on stderr move the bar,
                # and the answer on stdout carries the failure's kind.
                if [ -n "${_EVT_S_STORAGE[$_etr_i]:-}${_EVT_S_STFILE[$_etr_i]:-}" ]; then
                    # Two secrets (a lakehouse catalog login and storage keys), each typed or from its file.
                    _etr_a="${_EVT_S_SECRET[$_etr_i]}"
                    [ -n "$_etr_a" ] || _etr_a="$(_exakit_vs_secret_text < "${_EVT_S_SFILE[$_etr_i]}")"
                    _etr_b="${_EVT_S_STORAGE[$_etr_i]:-}"
                    [ -n "$_etr_b" ] || _etr_b="$(_exakit_vs_secret_text < "${_EVT_S_STFILE[$_etr_i]}")"
                    _exakit_vs_pair "$_etr_a" "$_etr_b" | _exakit_vs_tui_engine "$_etr_args" connect --json --secret-pair-base64
                    _etr_a=""; _etr_b=""
                elif [ -n "${_EVT_S_SECRET[$_etr_i]}" ]; then
                    printf '%s' "${_EVT_S_SECRET[$_etr_i]}" | _exakit_vs_tui_engine "$_etr_args" connect --json --secret-stdin
                elif [ -n "${_EVT_S_SFILE[$_etr_i]}" ]; then
                    _exakit_vs_tui_engine "$_etr_args" connect --json --secret-stdin < "${_EVT_S_SFILE[$_etr_i]}"
                else
                    _exakit_vs_tui_engine "$_etr_args" connect --json < /dev/null
                fi
            ) > "$_etr_out.json" 2> "$_etr_out" &
            _etr_pid=$!
            _etr_seen=0
            while kill -0 "$_etr_pid" 2>/dev/null; do
                # One OK line per finished step: the bar moves on those.
                _etr_oks="$(grep -c '^OK ' "$_etr_out" 2>/dev/null)"; _etr_oks="${_etr_oks:-0}"
                if [ "$_etr_oks" != "$_etr_seen" ]; then
                    _etr_seen="$_etr_oks"
                    _etr_p=$(( 5 + _etr_oks * 15 )); [ "$_etr_p" -le 90 ] || _etr_p=90
                    _etr_c=$(( _etr_p + 15 )); [ "$_etr_c" -le 97 ] || _etr_c=97
                    ui_table_set "$_etr_state" "$_etr_row" running "$_etr_p" "$_etr_c" 8 "step $_etr_oks"
                fi
                sleep 0.3
            done
            wait "$_etr_pid"; _etr_rc=$?
            cat "$_etr_out" "$_etr_out.json" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>/dev/null
            # Java without DNS needs no question: repaired, then tried once more.
            # On Docker the repair is seen from the database's next start: that
            # restart is made below the table, as a language container is.
            if [ "$_etr_rc" -eq 20 ] && [ "$_etr_try" -eq 1 ]; then
                ui_table_set "$_etr_state" "$_etr_row" running 30 60 20 "repairing DNS"
                _etr_dns=0
                personal_slc_dns_repair >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || _etr_dns=$?
                [ "$_etr_dns" -eq 0 ] && continue
                [ "$_etr_dns" -eq 2 ] && _etr_restart=1
            fi
            break
        done
        _etr_secs=$(( $(date +%s 2>/dev/null || echo 0) - _etr_t0 ))
        # The Status cell says it in a few words - a long one would push the row
        # past the screen; the engine's whole sentence is said under the table.
        _etr_say="$(run_python_any - "$_etr_out.json" "$_etr_rc" "${_EVT_S_NAME[$_etr_i]}" "$_etr_secs" <<'PY' 2>/dev/null
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    doc = {}
rc, name, secs = sys.argv[2], sys.argv[3], sys.argv[4]
if rc == "0":
    n = doc.get("tables", "?")
    print("VS_%s · %s table%s · %s s" % (name.upper(), n, "" if n == 1 else "s", secs))
else:
    short = {"auth": "the credentials were refused", "tls": "the certificate did not verify",
             "unreachable": "the source did not answer", "nohost": "the host name does not resolve",
             "dns": "Java in the database has no DNS", "denied": "the account may not read this",
             "region": "the region does not match", "nobucket": "no such bucket or container",
             "clock": "the database clock is wrong", "privilege": "the account lacks a privilege",
             "missing_or_denied": "no such object, or not granted",
             "sandbox": "the database's Java sandbox refused the driver",
             "catalog": "the catalog does not know that warehouse"}
    why = short.get(doc.get("kind", ""))
    if not why and rc == "3":
        why = "the name is already taken"
    if not why:
        why = doc.get("error") or "did not connect"
    print(why if len(why) <= 34 else why[:33] + "…")
PY
)"
        if [ "$_etr_rc" -eq 0 ]; then
            ui_table_set "$_etr_state" "$_etr_row" done "" "" "" "" "$_etr_say"
            _EVT_OK="${_EVT_OK:-} $_etr_i"
        else
            case "$_etr_rc" in
                21) _etr_say="needs Java in the database"; _EVT_NEEDS="${_EVT_NEEDS:-} java:$_etr_i" ;;
                23) _etr_say="needs Rust in the database"; _EVT_NEEDS="${_EVT_NEEDS:-} rust:$_etr_i" ;;
                20) if [ -n "$_etr_restart" ]; then
                        _etr_say="needs a database restart"; _EVT_NEEDS="${_EVT_NEEDS:-} dns:$_etr_i"
                    else
                        _EVT_FAILED="${_EVT_FAILED:-} $_etr_i"; [ "$_EVT_RC" -ne 0 ] || _EVT_RC="$_etr_rc"
                    fi ;;
                *)  _EVT_FAILED="${_EVT_FAILED:-} $_etr_i"
                    [ "$_EVT_RC" -ne 0 ] || _EVT_RC="$_etr_rc" ;;
            esac
            ui_table_set "$_etr_state" "$_etr_row" failed "" "" "" "" "${_etr_say:-did not connect}"
        fi
    done
}

# _exakit_vs_tui_live <state-file> <lines-on-screen> <indexes...> — that table,
# alive, over the lines it replaces.
_exakit_vs_tui_live() {
    _etl_state="$1"; UI_TABLE_LINES="$2"; shift 2
    # Keys pressed while it runs are neither echoed into the frame nor kept: an
    # impatient Enter must not land in the table, nor answer the next question.
    _etl_tty="$(stty -g 2>/dev/null)"
    stty -echo 2>/dev/null
    _etl_live=0
    ui_table_begin "$_etl_state" && _etl_live=1
    _EVT_LIVE="$_etl_live"
    _exakit_vs_tui_run "$_etl_state" "$@"
    if [ "$_etl_live" = 1 ]; then ui_table_end "$_etl_state"; else ui_table_render "$_etl_state" 0; fi
    run_python_any -c 'import sys, termios; termios.tcflush(sys.stdin.fileno(), termios.TCIFLUSH)' 2>/dev/null
    [ -n "$_etl_tty" ] && stty "$_etl_tty" 2>/dev/null
}

# _exakit_vs_tui <source-or-empty> <name-or-empty> <password-file-or-empty> — the
# whole terminal flow; returns cmd_connect's exit code.
_exakit_vs_tui() {
    # A person at a terminal: what the picked sources need is said, not asked.
    _EXAKIT_VS_INTERACTIVE=1
    _EVT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/exakit-connect.XXXXXX")" || { error "Could not create a temporary folder."; return 1; }
    _EVT_COLS="$(_ui_term_cols)"
    _EVT_W=$(( _EVT_COLS - 2 )); [ "$_EVT_W" -le 96 ] || _EVT_W=96
    _EVT_IN=$(( _EVT_W - 4 ))
    _EVT_SP=""; _EVT_HR=""; _evt_k=0
    while [ "$_evt_k" -lt 160 ]; do _EVT_SP="$_EVT_SP "; _EVT_HR="$_EVT_HR$UI_HR"; _evt_k=$(( _evt_k + 1 )); done
    _EVT_S_ID=(); _EVT_S_NAME=(); _EVT_S_LABEL=(); _EVT_S_SETS=(); _EVT_S_SECRET=(); _EVT_S_SFILE=(); _EVT_S_STORAGE=(); _EVT_S_STFILE=(); _EVT_S_WHERE=(); _EVT_S_DL=(); _EVT_S_SRC=()
    _EVT_COUNT=0; _EVT_TAKEN=""; _EVT_OK=""; _EVT_FAILED=""; _EVT_NEEDS=""; _EVT_RC=0
    _evt_name="$2"; _evt_pwfile="$3"; _evt_named="$1"

    # 1. which sources
    if [ -n "$1" ]; then
        exakit_vs_engine resolve "$1" < /dev/null > "$_EVT_DIR/resolve" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        _evt_rc=$?
        if [ "$_evt_rc" -ne 0 ]; then _exakit_vs_render "$_EVT_DIR/resolve"; rm -rf "$_EVT_DIR"; return "$_evt_rc"; fi
        EXAKIT_VS_PICKED="$(_exakit_vs_result "$_EVT_DIR/resolve" | run_python_any -c 'import json,sys; print(json.load(sys.stdin)["connector"])')"
    else
        _exakit_vs_pick "$_EVT_DIR"
        _evt_rc=$?
        if [ "$_evt_rc" -ne 0 ]; then
            [ "$_evt_rc" -eq 5 ] && info "Nothing was chosen; nothing was changed."
            rm -rf "$_EVT_DIR"; return "$_evt_rc"
        fi
    fi
    # shellcheck disable=SC2086 — connector ids, one word each
    set -- $EXAKIT_VS_PICKED
    _evt_total=$#

    # 2. the details, one panel each. --name, --set and --password-file belong to
    # the one source the command named.
    printf '\n'
    _evt_sets=""
    [ "$_evt_total" -eq 1 ] && _evt_sets="$(printf '%s\n' "${EXAKIT_VS_SETS:-}" | grep -v '^--set$' | grep -v '^$')"
    [ "$_evt_total" -eq 1 ] || { _evt_name=""; _evt_pwfile=""; _EVP_SECRET=""; }
    _evt_pos=0
    for _evt_id in "$@"; do
        _evt_pos=$(( _evt_pos + 1 ))
        _exakit_vs_tui_form "$_evt_id" "$_evt_pos" "$_evt_total" "$_evt_name" "$_evt_sets" "$_evt_pwfile"
        case "$?" in
            2) rm -rf "$_EVT_DIR"; return 2 ;;
            5) printf '\n'; info "Left out: $_evt_id" ;;
        esac
    done
    if [ "$_EVT_COUNT" -eq 0 ]; then info "Nothing was changed."; rm -rf "$_EVT_DIR"; return 5; fi
    _evt_all=""; _evt_i=0
    while [ "$_evt_i" -lt "$_EVT_COUNT" ]; do _evt_all="$_evt_all $_evt_i"; _evt_i=$(( _evt_i + 1 )); done

    # 3. review: each source's warnings and the plan's own INFO lines, above
    # one table - what each downloads is its Downloads cell - its footer, and
    # one question. This computer's public IP is the menu's Tip line, said
    # here once only when no menu was shown.
    _evt_bytes=0; _evt_exposed=""; _evt_need=""; _evt_ip=""
    for _evt_i in $_evt_all; do
        _exakit_vs_result "$_EVT_DIR/plan.$_evt_i" | run_python_any -c 'import json, sys
p = json.load(sys.stdin)
new = [d for d in p["downloads"] if not d["cached"]]
size = sum(d["bytes"] for d in new)
mb = "<1 MB" if 0 < size < 5e5 else "%.0f MB" % (size / 1e6)
cell = " · ".join(["%s %s" % (d["role"], d["version"]) for d in new] + [mb]) if new else "none needed"
print("|".join([cell, str(size), " ".join(p.get("languages") or []), "1" if p.get("exposure") else "",
                p.get("public_ip") or ""]))
for w in p["warnings"]:
    print("WARN %s: %s" % (p["name"], w))' > "$_EVT_DIR/review" 2>/dev/null
        IFS='|' read -r _evt_dl _evt_b _evt_l _evt_x _evt_pip < "$_EVT_DIR/review"
        _EVT_S_DL[$_evt_i]="$_evt_dl"
        case "$_evt_b" in ''|*[!0-9]*) _evt_b=0 ;; esac
        _evt_bytes=$(( _evt_bytes + _evt_b ))
        _evt_need="$_evt_need $_evt_l"
        [ -n "$_evt_x" ] && _evt_exposed=1
        [ -n "$_evt_pip" ] && _evt_ip="$_evt_pip"
        sed 1d "$_EVT_DIR/review" > "$_EVT_DIR/review.say"
        # The name is [a-z0-9_] (the form checked it), safe in a sed replacement.
        # The per-source public IP line is the Tip's: left out.
        grep -v "^INFO This computer's public IP is " "$_EVT_DIR/plan.$_evt_i" \
            | sed -n "s/^INFO /INFO ${_EVT_S_NAME[$_evt_i]}: /p" >> "$_EVT_DIR/review.say"
        _exakit_vs_render "$_EVT_DIR/review.say"
    done
    [ -n "$_evt_named" ] && [ -n "$_evt_ip" ] && \
        info "Tip: cloud sources see you as $_evt_ip - allow it if the source has an IP allowlist."
    _evt_state="$_EVT_DIR/sources"
    # shellcheck disable=SC2086 — indexes
    _exakit_vs_tui_table "$_evt_state" "Connect $_EVT_COUNT source$([ "$_EVT_COUNT" = 1 ] || printf s)" $_evt_all
    ui_table_render "$_evt_state" 0
    _evt_lines="$UI_TABLE_LINES"
    _EVT_ON_SCREEN=0
    _exakit_vs_tui_footer
    _evt_lines=$(( _evt_lines + _EVT_FOOT_N ))
    if ! _exakit_vs_tui_yes "$(if [ "$_EVT_COUNT" = 1 ]; then printf 'Connect it now?'; else printf 'Connect all %s now?' "$_EVT_COUNT"; fi)"; then
        _exakit_vs_tui_table_done
        info "Nothing was changed."; rm -rf "$_EVT_DIR"; return 5
    fi

    # 4. the database first: a language container a source needs and the
    # database lacks is installed before the table runs, so no row fails for
    # one. Picking the sources was the permission: nothing is asked.
    _evt_over=$(( _evt_lines + _EVT_ON_SCREEN ))
    _EVT_PREPARED=""
    _exakit_vs_tui_prepare "$_evt_over" $_evt_need && _evt_over=0

    # 5. connect: the review table comes alive in place, over itself, its
    # footer and the question - or under what the database was prepared with
    # shellcheck disable=SC2086 — indexes
    _exakit_vs_tui_live "$_evt_state" "$_evt_over" $_evt_all
    # The live table drew over the footer.
    [ "${_EVT_LIVE:-0}" = 1 ] && _exakit_vs_tui_footer

    # A language container (a download and a restart), or the restart Docker's
    # DNS repair needs: said once, below the table - picking the sources was the
    # permission, so nothing is asked - and those sources then run again in a
    # table of their own. A restart made for a language container is the one
    # the DNS repair needed too.
    _evt_restarted=""
    for _evt_lang in java rust dns; do
        _evt_wait=""
        for _evt_n in ${_EVT_NEEDS:-}; do
            case "$_evt_n" in "$_evt_lang:"*) _evt_wait="$_evt_wait ${_evt_n#*:}" ;; esac
        done
        [ -n "$_evt_wait" ] || continue
        # Tried before the table and not installed: those sources failed.
        case " ${_EVT_PREPARED:-} " in *" $_evt_lang "*)
            _EVT_FAILED="${_EVT_FAILED:-}$_evt_wait"; [ "$_EVT_RC" -ne 0 ] || _EVT_RC=1
            continue ;;
        esac
        # The sources it is for, by the connector's name, each once.
        _evt_for=(); _evt_seen="|"
        for _evt_n in $_evt_wait; do
            case "$_evt_seen" in *"|${_EVT_S_LABEL[$_evt_n]}|"*) continue ;; esac
            _evt_seen="$_evt_seen${_EVT_S_LABEL[$_evt_n]}|"
            _evt_for+=("${_EVT_S_LABEL[$_evt_n]}")
        done
        _EXAKIT_VS_FOR="$(_exakit_vs_and "${_evt_for[@]}")"
        printf '\n'
        case "$_evt_lang" in
            java) _exakit_vs_install_java ;;
            rust) _exakit_vs_install_rust ;;
            dns)  [ -n "$_evt_restarted" ] || _exakit_vs_dns_restart ;;
        esac
        if [ $? -ne 0 ]; then
            _EVT_FAILED="${_EVT_FAILED:-}$_evt_wait"; [ "$_EVT_RC" -ne 0 ] || _EVT_RC=1
            continue
        fi
        [ "$_evt_lang" = dns ] || _evt_restarted=1
        printf '\n'
        # shellcheck disable=SC2086 — indexes
        _exakit_vs_tui_table "$_EVT_DIR/again.$_evt_lang" "Connect again" $_evt_wait
        # shellcheck disable=SC2086 — indexes
        _exakit_vs_tui_live "$_EVT_DIR/again.$_evt_lang" 0 $_evt_wait
    done
    _exakit_vs_tui_table_done

    # What went wrong in the engine's own words, below the finished table.
    printf '\n'
    for _evt_i in ${_EVT_FAILED:-}; do
        warn "${_EVT_S_NAME[$_evt_i]} did not connect:"
        grep -v '^OK \|^RESULT ' "$_EVT_DIR/run.$_evt_i" > "$_EVT_DIR/why" 2>/dev/null
        _exakit_vs_render "$_EVT_DIR/why"
    done
    if [ -n "${_EVT_OK:-}" ]; then
        _evt_n=0; for _evt_i in $_EVT_OK; do _evt_n=$(( _evt_n + 1 )); done
        for _evt_i in $_EVT_OK; do
            printf '%s\t%s\n' "${_EVT_S_NAME[$_evt_i]}" "$_EVT_DIR/run.$_evt_i.json"
        done > "$_EVT_DIR/hints"
        _exakit_vs_query_list "$_EVT_DIR/hints" "$_evt_n"
        info "Manage with: exakit source show <name> (every action: exakit help source)"
    fi
    # Nothing secret outlives the command in this shell.
    for _evt_i in $_evt_all; do _EVT_S_SECRET[$_evt_i]=""; _EVT_S_STORAGE[$_evt_i]=""; done
    rm -rf "$_EVT_DIR"
    [ -z "${_EVT_FAILED:-}" ] || [ "$_EVT_RC" -ne 0 ] || _EVT_RC=1
    return "$_EVT_RC"
}

# _exakit_vs_paste <connector> <string> [typed] [input] - the inputs a pasted
# connection string names (engine paste, the string on its stdin, never an
# argument), its notes shown, as --set pairs put BEFORE the command line's own
# in EXAKIT_VS_SETS - the engine's pairs() keeps the last, so an explicit --set
# wins - and their names added to EXAKIT_VS_GIVEN, so they are not asked for
# again. typed: the string was typed at a prompt, not given with --url
# (_exakit_vs_paste_typed): it is shown back first, its credentials masked by
# the engine ("Read: ..."), and one key at the terminal decides - Enter uses
# it, e returns 7 (paste it again), Esc or n returns 6 (type the fields
# instead), nothing used. input: the string is that input's value (--set
# uri=...). The credential the string holds where the connector's stands is
# taken out of it by the engine and lands in _EVP_SECRET (never exported,
# never an argument), used as if typed at the hidden prompt - unless
# --password-file or --password-stdin gives one (_EVP_GIVEN), which wins.
# Given on the command line, it is in the shell history, and a line says so.
# ⇄ twin: the --url branch of Invoke-CmdConnect and Read-ExakitVsLinePaste.
_exakit_vs_paste() {
    _evp_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs-paste.XXXXXX")" || {
        _exakit_vs_no_tmp && return 1
        error "Could not create a temporary file."; return 1; }
    # Owner-only (mktemp): the engine writes the string's credential here.
    _evp_sec="$(mktemp "${TMPDIR:-/tmp}/exakit-vs-paste.XXXXXX")" || {
        rm -f "$_evp_out"; _exakit_vs_no_tmp && return 1
        error "Could not create a temporary file."; return 1; }
    set -- "$1" "$2" "${3:-}" "${4:-}" --secret-out "$_evp_sec"
    [ -n "${_EVP_GIVEN:-}" ] && set -- "$1" "$2" "$3" "$4" --credential-given
    [ -n "$4" ] && set -- "$@" --as "$4"
    unset _EVP_SECRET; _EVP_SECRET=""
    if [ "${EXAKIT_VS_JSON:-0}" = 1 ]; then
        # Its notes go to the log; a refusal is the answer, as it stands.
        _evp_s="$2"; _evp_c="$1"; shift 4
        printf '%s' "$_evp_s" | exakit_vs_engine --json paste "$_evp_c" "$@" > "$_evp_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        _evp_rc=$?; _evp_s=""
        [ "$_evp_rc" -eq 0 ] || { cat "$_evp_out"; rm -f "$_evp_out" "$_evp_sec"; return "$_evp_rc"; }
        EXAKIT_VS_RESULT="$(cat "$_evp_out")"; rm -f "$_evp_out"
        _EVP_SECRET="$(cat "$_evp_sec")"; rm -f "$_evp_sec"
        # stdout is the one JSON object: the shell-history line goes to stderr.
        [ -n "$_EVP_SECRET" ] && warn "The password from the command line is now in your shell history - next time paste it at the prompt or use --password-file."
    else
        _evp_s="$2"; _evp_c="$1"; _evp_typed="$3"; shift 4
        printf '%s' "$_evp_s" | exakit_vs_engine paste "$_evp_c" "$@" > "$_evp_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        _evp_rc=$?; _evp_s=""
        set -- "$_evp_c" "" "$_evp_typed"
        if [ -n "${3:-}" ]; then
            if [ "$_evp_rc" -eq 0 ]; then
                info "Read: $(_exakit_vs_paste_masked "$_evp_out")"
                printf '    %s?%s %s ' "${UI_ASK:-}" "${UI_RESET:-}" "$(_exakit_vs_paste_choice_text)" >&2
                while :; do
                    # A terminal that cannot read single keys uses the string.
                    _exakit_vs_key < /dev/tty || { _EVK=enter; break; }
                    case "$_EVK" in enter|esc|eof|e|E|n|N) break ;; esac
                done
                printf '\n' >&2
                case "$_EVK" in
                    e|E) rm -f "$_evp_out" "$_evp_sec"; return 7 ;;
                    n|N|esc|eof) rm -f "$_evp_out" "$_evp_sec"; return 6 ;;
                esac
            fi
            _exakit_vs_render <(_exakit_vs_paste_typed < "$_evp_out")
        else
            _exakit_vs_render "$_evp_out"
        fi
        rm -f "$_evp_out"
        [ "$_evp_rc" -eq 0 ] || { rm -f "$_evp_sec"; return "$_evp_rc"; }
        _EVP_SECRET="$(cat "$_evp_sec")"; rm -f "$_evp_sec"
    fi
    _evp_pairs="$(printf '%s' "$EXAKIT_VS_RESULT" | run_python_any -c 'import json, sys
for k, v in json.load(sys.stdin)["values"].items():
    print("%s=%s" % (k, v))')"
    _evp_sets=""
    while IFS= read -r _evp_pair; do
        [ -n "$_evp_pair" ] || continue
        _evp_sets="$_evp_sets
--set
$_evp_pair"
        EXAKIT_VS_GIVEN="$EXAKIT_VS_GIVEN ${_evp_pair%%=*}"
    done <<EOF
$_evp_pairs
EOF
    EXAKIT_VS_SETS="$_evp_sets$EXAKIT_VS_SETS"
}

# cmd_connect [source] [--name N] [--url STRING] [--set KEY=VALUE]...
#             [--password-file F | --password-stdin] [--dry-run] [--yes] [--json]
#
# --password-stdin: the credential is all of standard input, read even with a
# terminal reachable (a pipe without it is read only when no terminal is);
# a terminal or an empty stdin is refused (_exakit_vs_stdin_secret).
#
# --json: stdout carries one JSON object and nothing else - the engine's plan
# (--dry-run), its connect result, or a failure of the engine's one shape
# (cli.py), whoever refused. It never prompts: what is not on the command
# line, in --password-file or on a pipe is a failure, not a question. The
# engine's events go to the log; what this bridge says while it repairs DNS
# or installs a language container goes to stderr. A failure ends naming the
# engine's day log, every statement it sent (_exakit_vs_exit).
# exakit_vs_guide [--exact] [connector] - `exakit connect <connector> --help`
# (and `exakit help <connector>`): the connector's guide, drawn by
# engine/guide.py from docs/virtual-schemas/<connector>.md, coloured here.
# Without a connector, every connector on one line each (the README index).
# --exact answers 10 and prints nothing for a word that is no connector's id
# or alias, so the caller's own help answers it. No credential is read, so
# any python3 runs it when the kit's own is not installed yet.
# Twin of Show-ExakitVsGuide.
exakit_vs_guide() {
    _evg_exact=""; [ "${1:-}" = --exact ] && _evg_exact=1
    _evg_defs="$(exakit_vs_defs 2>/dev/null)" || {
        [ -n "$_evg_exact" ] && return 10
        error "This kit copy has no setup/virtual-schemas. Update it: exakit update"; return 2; }
    _evg_py="$(_exakit_vs_kit_python 2>/dev/null)" || _evg_py="$(command -v python3 2>/dev/null)" || {
        [ -n "$_evg_exact" ] && return 10
        error "python3 is needed to show the connector guide."; return 2; }
    _evg_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || die "Could not create a temporary file."
    _exakit_vs_python "$_evg_py" "$_evg_defs/engine/guide.py" --defs "$_evg_defs" \
        --width "$(_ui_term_cols 2>/dev/null || echo 80)" --shell bash "$@" \
        > "$_evg_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    _evg_rc=$?
    # One "<style>|<text>" per line: T title, H heading, D dimmed, A a command.
    while IFS= read -r _evg_line || [ -n "$_evg_line" ]; do
        _evg_text="${_evg_line#?|}"
        case "$_evg_line" in
            T\|*)      printf '%s%s%s\n' "${UI_BOLD:-}" "$_evg_text" "${UI_RESET:-}" ;;
            H\|*|D\|*) printf '%s%s%s\n' "${UI_DIM:-}" "$_evg_text" "${UI_RESET:-}" ;;
            A\|*)      printf '%s%s%s\n' "${UI_ACCENT:-}" "$_evg_text" "${UI_RESET:-}" ;;
            *)         printf '%s\n' "$_evg_text" ;;
        esac
    done < "$_evg_out"
    rm -f "$_evg_out"
    return "$_evg_rc"
}

cmd_connect() {
    _exakit_vs_quiet
    _cc_source=""; _cc_name=""; _cc_pwfile=""; _cc_dry=0; _cc_json=0; _cc_url=""; _cc_pwstdin=0; _cc_seturi=""
    _cc_sfile=""; _EXAKIT_VS_STORAGE_FILE=""
    EXAKIT_VS_SETS=""; EXAKIT_VS_GIVEN=""; _EVP_SECRET=""; _EVP_GIVEN=""
    # Known before anything is refused, so every refusal answers in its shape.
    for _cc_word in "$@"; do case "$_cc_word" in --json|-j) _cc_json=1 ;; esac; done
    EXAKIT_VS_JSON="$_cc_json"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name) _cc_name="${2:-}"; shift ;;
            --name=*) _cc_name="${1#--name=}" ;;
            --url|--url=*)
                if [ "$1" = --url ]; then _cc_url="${2:-}"; shift; else _cc_url="${1#--url=}"; fi
                [ -n "$_cc_url" ] || _exakit_vs_refuse 2 "--url takes a connection string (exakit help connect)" \
                    "--url was given without a connection string" \
                    "give the source's connection string after --url, e.g. --url 'postgres://reader@db.example.com/sales'" ;;
            --set) case "${2:-}" in *=*) ;; *) _exakit_vs_refuse 2 "--set takes KEY=VALUE (exakit help connect)" \
                       "--set was not followed by KEY=VALUE" "give each input as --set KEY=VALUE (a connector's inputs: exakit help connect)" ;; esac
                   # A connector's credential input by name: refused before
                   # anything runs, the value never repeated (engine: plan.py).
                   case "${2%%=*}" in password|passwd|pwd|secret|token|key_file|storage_secret)
                       _exakit_vs_refuse 2 "--set ${2%%=*}=... is a credential given as an argument (other users can read the process list). Use --password-file or --password-stdin." \
                           "--set ${2%%=*} gives a credential as an argument, where other users can read it in the process list" \
                           "give it with --password-file <file> or pipe it in with --password-stdin" ;; esac
                   # A URI with user[:password]@ is a connection string: read
                   # as --url is, its credential taken out and used.
                   case "$2" in
                       uri=*@*) _cc_seturi="${2#uri=}" ;;
                       *) EXAKIT_VS_SETS="$EXAKIT_VS_SETS
--set
$2"; EXAKIT_VS_GIVEN="$EXAKIT_VS_GIVEN ${2%%=*}" ;;
                   esac; shift ;;
            --password-file) _cc_pwfile="${2:-}"; shift ;;
            --password-stdin) _cc_pwstdin=1 ;;
            # The second secret of a lakehouse combination with two: a file
            # only (stdin carries the first), never a value on the line.
            --storage-secret-file) _cc_sfile="${2:-}"; shift
                [ -n "$_cc_sfile" ] || _exakit_vs_refuse 2 "--storage-secret-file takes the path of a file holding only the storage secret." \
                    "--storage-secret-file was given without a file" "give the path of a file holding only the storage secret after --storage-secret-file" ;;
            --storage-secret*) _exakit_vs_credential_argument ;;
            --dry-run|-n) _cc_dry=1 ;;
            --yes|-y) EXAKIT_VS_ASSUME_YES=1 ;;
            --json|-j) _cc_json=1 ;;
            # After the exact --password-file and --password-stdin: anything else
            # like a credential option is one given as an argument, and only its
            # name is ever repeated, never what follows an =.
            --password*|--passwd*|--secret*|--token*) _exakit_vs_credential_argument ;;
            -*) _exakit_vs_refuse 2 "Unknown option '${1%%=*}' for connect (exakit help connect)." \
                    "unknown option '${1%%=*}' for connect" "leave it out; the options are listed by: exakit help connect" ;;
            # The extra word is not repeated: it may be a credential typed in
            # the wrong place.
            *) [ -z "$_cc_source" ] || _exakit_vs_refuse 2 "connect takes one source; got more than one word for it." \
                   "connect takes one source; got more than one word for it" "connect one source per command"
               _cc_source="$1" ;;
        esac
        shift
    done
    [ "$_cc_pwstdin" = 1 ] && [ -n "$_cc_pwfile" ] && _exakit_vs_refuse 2 "--password-stdin and --password-file both give the credential; use one." \
        "--password-stdin and --password-file were both given" "give the credential one way: --password-stdin or --password-file <file>"
    [ -n "$_cc_seturi" ] && [ -n "$_cc_url" ] && _exakit_vs_refuse 2 "--url and --set uri=... both give the connection string; use one." \
        "--url and --set uri were both given" "give the connection string one way: --url or --set uri=..."
    # A credential from the command line's own options wins over one in a
    # connection string (_exakit_vs_paste).
    if [ "$_cc_pwstdin" = 1 ] || [ -n "$_cc_pwfile" ]; then _EVP_GIVEN=1; fi
    _EXAKIT_VS_STORAGE_FILE="$_cc_sfile"
    _require_install "$_cc_json"
    exakit_init_logging
    _exakit_vs_log_mark
    # A person at a terminal: Ctrl-C gives it back whole, and says so.
    [ "$_cc_json" = 1 ] || _exakit_vs_cancel_trap
    # Read before anything runs or asks: nothing else can take it off stdin,
    # and a terminal or nothing on it is refused before any work is done.
    [ "$_cc_pwstdin" = 1 ] && _exakit_vs_stdin_secret
    # A pasted connection string fills what it names, for every path below:
    # the terminal's panel shows those answers, --yes and --dry-run use them.
    if [ -n "$_cc_url" ] || [ -n "$_cc_seturi" ]; then
        [ -n "$_cc_source" ] || _exakit_vs_refuse 2 "--url needs the source it is for, e.g. exakit connect postgresql --url 'postgres://reader@db.example.com/sales'" \
            "--url needs the source it is for" \
            "name the source before it, e.g. exakit connect postgresql --url 'postgres://reader@db.example.com/sales'"
        if [ -n "$_cc_seturi" ]; then
            _exakit_vs_paste "$_cc_source" "$_cc_seturi" "" uri || _exakit_vs_exit $?
        else
            _exakit_vs_paste "$_cc_source" "$_cc_url" || _exakit_vs_exit $?
        fi
        _cc_url=""; _cc_seturi=""
    fi
    # A name that is a connected source is re-pointed in place, or left as it
    # is: on the line-by-line path, which asks nothing the record holds.
    _cc_live=""
    _exakit_vs_source_live "$_cc_name" && _cc_live=1
    # A person at a terminal gets the menu and the panels; a pipe, --yes,
    # --dry-run and --json keep the line-by-line path below, unchanged.
    if [ "$_cc_dry" = 0 ] && [ "$_cc_json" = 0 ] && [ -z "$_cc_live" ] && _exakit_vs_tui_ok; then
        _exakit_vs_tui "$_cc_source" "$_cc_name" "$_cc_pwfile"
        _exakit_vs_exit $?
    fi
    # --json never asks: a terminal is as good as none.
    _cc_tty=""
    [ "$_cc_json" = 1 ] || _cc_tty="$(_exakit_prompt_tty)"
    # A person at a terminal (asked "Connect now?" below, or gave --yes): what
    # the source needs first - a language container, a restart - is said, not
    # asked (_exakit_vs_interactive). Without one, the contract stands.
    _EXAKIT_VS_INTERACTIVE=0
    [ -n "$_cc_tty" ] && _EXAKIT_VS_INTERACTIVE=1
    # Someone answering at a terminal: a required question ends in a red *
    # (the legend says so), and a connection string can stand for the fields. A pipe on
    # stdin (even with a terminal behind /dev/tty), --yes, --dry-run and --json
    # ask exactly as they always did - as Test-ExakitInteractive has it.
    _cc_ask=""
    if [ -t 0 ] && [ -n "$_cc_tty" ] && [ "$_cc_dry" = 0 ] && [ "$_cc_json" = 0 ] && [ "${EXAKIT_VS_ASSUME_YES:-0}" != 1 ] \
       && [ -z "$_cc_live" ]; then
        _cc_ask=1
    fi
    if [ -z "$_cc_source" ]; then
        [ -n "$_cc_tty" ] || _exakit_vs_refuse 2 "Name the source to connect, e.g. exakit connect postgresql (see: exakit source catalog)." \
            "no source was named" "name the source to connect, e.g. exakit connect postgresql; every connector: exakit source catalog" \
            "exakit source catalog"
        # The wizard's first line, as above the menu: this computer's public IP.
        _cc_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" && { _exakit_vs_catalog "$_cc_out"; rm -f "$_cc_out"; }
        _exakit_vs_clock_check
        _cc_source="$(prompt_text "Which source? (name or alias, e.g. postgresql, mysql, mssql, oracle, snowflake, bigquery, databricks, mongodb, lakehouse, s3, azure)" "")"
    fi
    # With --json the plan below resolves the source (an unknown or gated one
    # is its refusal), so every answer is a plan or connect object.
    _cc_resolved="$_cc_source"
    if [ "$_cc_json" = 0 ]; then
        _cc_resolved="$(exakit_vs_engine resolve "$_cc_source" 2>/dev/null | sed -n 's/^RESULT {"connector": "\(.*\)"}$/\1/p')"
        if [ -z "$_cc_resolved" ]; then
            _cc_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || die "Could not create a temporary file."
            exakit_vs_engine resolve "$_cc_source" > "$_cc_out" 2>&1
            _cc_rc=$?
            _exakit_vs_render "$_cc_out"; rm -f "$_cc_out"
            [ "$_cc_rc" -ne 0 ] || _cc_rc=2
            exit "$_cc_rc"
        fi
    fi
    [ -n "$_cc_tty" ] && _EXAKIT_VS_FOR="$(_exakit_vs_label "$_cc_resolved")"
    [ -n "$_cc_ask" ] && [ -z "$EXAKIT_VS_GIVEN" ] && _exakit_vs_ask_paste "$_cc_resolved"
    [ -n "$_cc_ask" ] && _exakit_vs_legend
    # With --json a missing name is the plan's refusal, after the gate, as
    # resolve orders them here without it.
    if [ -z "$_cc_name" ] && [ "$_cc_json" = 0 ]; then
        [ -n "$_cc_tty" ] || reject "Give the connection a name with --name (lower case, e.g. sales)."
        _cc_name="$(_exakit_vs_prompt "Name (alias) for this connection (lower case, e.g. sales)" "" 1 "$_cc_ask" "Name (alias) for this connection")"
        # A name typed here can be a connected source too: re-pointed, not asked again.
        _exakit_vs_source_live "$_cc_name" && _cc_live=1
    fi
    # A connected source's inputs are its record's: only what was given changes.
    [ -n "$_cc_tty" ] && [ -z "$_cc_live" ] && _exakit_vs_ask_inputs "$_cc_resolved" "$_cc_ask"
    # Build the engine's argument list from the newline-separated pairs; bash
    # 3.2 has no arrays worth trusting with this, so the positional
    # parameters carry it.
    # --name=VALUE under --json: an empty name stays one argument.
    if [ "$_cc_json" = 1 ]; then set -- "$_cc_resolved" "--name=$_cc_name"; else set -- "$_cc_resolved" --name "$_cc_name"; fi
    while IFS= read -r _cc_word; do
        [ -n "$_cc_word" ] && set -- "$@" "$_cc_word"
    done <<EOF
$EXAKIT_VS_SETS
EOF
    # A connected source with nothing else given and a credential to come is a
    # re-point of the credential alone, not "unchanged": the plan is told.
    _cc_given=""
    if [ -n "$_cc_live" ] && { [ "$_cc_pwstdin" = 1 ] || [ -n "$_cc_pwfile" ] || [ -n "$_EVP_SECRET" ]; }; then _cc_given="--secret-given"; fi
    _cc_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || { _exakit_vs_no_tmp && exit 1; die "Could not create a temporary file."; }
    _cc_action=""
    if [ "$_cc_json" = 1 ]; then
        # The plan checks every input before the credential is read; a refusal,
        # or with --dry-run the plan itself, is the answer.
        exakit_vs_engine --json plan "$@" $_cc_given < /dev/null > "$_cc_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        _cc_rc=$?
        if [ "$_cc_rc" -ne 0 ] || [ "$_cc_dry" = 1 ]; then cat "$_cc_out"; rm -f "$_cc_out"; _exakit_vs_exit "$_cc_rc"; fi
        # The connector it resolved to, and what the plan is, by its own top-level keys.
        _cc_resolved="$(sed -n 's/^  "connector": "\([a-z0-9-]*\)",*$/\1/p' "$_cc_out" | head -n 1)"
        _cc_action="$(sed -n 's/^  "action": "\([a-z]*\)",*$/\1/p' "$_cc_out" | head -n 1)"
        if [ "$_cc_action" = repoint ] && [ "${EXAKIT_VS_ASSUME_YES:-0}" != 1 ]; then
            # --json never asks, and asking is how a person agrees: without
            # --yes nothing changes (exit 5), as source disconnect and remove.
            # The --yes form is named only with the credential it needs.
            _cc_cmd="$(run_python_any -c 'import json, sys; print(json.load(open(sys.argv[1])).get("command") or "")' "$_cc_out" 2>/dev/null)"
            rm -f "$_cc_out"
            [ -n "$_cc_cmd" ] || _cc_cmd="exakit connect $_cc_resolved --name $_cc_name"
            _cc_fix="preview it with --dry-run, then confirm it with --yes"
            if [ -n "$_cc_pwfile" ]; then _cc_cmd="$_cc_cmd --password-file $(_exakit_vs_word "$_cc_pwfile") --yes --json"
            elif [ "$_cc_pwstdin" = 1 ]; then _cc_cmd="$_cc_cmd --password-stdin --yes --json"
            else
                _cc_cmd=""
                _cc_fix="preview it with --dry-run, then run it with --yes and the credential (--password-file <file> or --password-stdin): a re-point always takes it again"
            fi
            _exakit_log_file "DECLINED connect $_cc_name: a re-point, --json without --yes"
            _exakit_vs_json_failure declined "re-pointing $_cc_name was not confirmed; nothing was changed" "$_cc_fix" "$_cc_cmd"
            exit 5
        fi
        rm -f "$_cc_out"
        shift; set -- "$_cc_resolved" "$@"
    else
        exakit_vs_engine plan "$@" $_cc_given < /dev/null > "$_cc_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        _cc_rc=$?
        _exakit_vs_render "$_cc_out"; rm -f "$_cc_out"
        [ "$_cc_rc" -eq 0 ] || _exakit_vs_exit "$_cc_rc"
        _cc_action="$(printf '%s' "$EXAKIT_VS_RESULT" | sed -n 's/.*"action": "\([a-z]*\)".*/\1/p' | head -n 1)"
        # Nothing to change: the connect below says so, without the plan.
        [ "$_cc_action" = unchanged ] && [ "$_cc_dry" = 0 ] || _exakit_vs_show_plan "$EXAKIT_VS_RESULT"
        [ "$_cc_dry" = 1 ] && exit 0
    fi
    if [ "$_cc_action" = unchanged ]; then
        # Nothing to change and no credential: connect settles what an
        # interrupted re-point left, then answers with the source's real
        # state (exit 1 when it is not ready). Nothing is asked.
        _exakit_vs_run "" connect "$@"
        _exakit_vs_exit $?
    fi
    if [ "$_cc_action" = repoint ]; then
        # Asked at a terminal (no by default); without one only --yes agrees.
        _exakit_vs_confirm "Re-point $_cc_name now?" \
            || { info "Nothing was changed. Confirm it with --yes."; exit 5; }
    elif [ -n "$_cc_tty" ] && ! _exakit_vs_confirm "Connect now?"; then
        # 5, as every command a person did not confirm: 0 would read as "done".
        info "Nothing was changed."
        exit 5
    fi
    # The labels of the combination's secrets (engine inputs): a lakehouse
    # source can have two, the second on --storage-secret-file or asked hidden.
    _cc_labels="$(_exakit_vs_secret_labels "$_cc_resolved")"
    _cc_label="${_cc_labels%%|*}"; _cc_slabel="${_cc_labels#*|}"
    if [ -z "$_cc_slabel" ] && [ -n "$_cc_sfile" ]; then
        _exakit_vs_refuse 2 "--storage-secret-file is for a lakehouse source with a catalog login and storage keys; this one has one secret." \
            "--storage-secret-file was given, but this source has one secret" \
            "leave --storage-secret-file out and give the credential with --password-file or --password-stdin"
    fi
    # A re-point takes the credential as a connect does: the database never
    # returns a stored one, and moving a CONNECTION clears it.
    unset _cc_secret; _cc_secret=""
    if [ -n "$_cc_label" ]; then
        _cc_what="$(printf '%s' "$_cc_label" | tr 'A-Z' 'a-z')"
        # With --json an unreadable file is the one object; without, the
        # credential reader says "Cannot read" as it always has.
        if [ "$_cc_json" = 1 ] && [ -n "$_cc_pwfile" ] && { [ -d "$_cc_pwfile" ] || [ ! -r "$_cc_pwfile" ]; }; then
            _exakit_vs_refuse 2 "Cannot read $_cc_pwfile" "cannot read $_cc_pwfile" \
                "give a file this user can read with --password-file, or pipe the $_cc_what on a closed standard input"
        fi
        if [ "$_cc_pwstdin" = 1 ]; then
            _cc_secret="$EXAKIT_VS_STDIN_SECRET"
        elif [ -z "$_cc_pwfile" ] && [ -n "$_EVP_SECRET" ]; then
            # Taken out of the pasted connection string: not asked again.
            _cc_secret="$_EVP_SECRET"
        else
            _cc_secret="$(_exakit_vs_read_secret "$_cc_label" "$_cc_pwfile" "$(_exakit_vs_secret_kind "$_cc_resolved")")" \
                || _exakit_vs_secret_failed $?
        fi
        [ -n "$_cc_secret" ] || _exakit_vs_refuse 2 "No $_cc_what was given (pipe it on standard input or use --password-file)." \
            "no $_cc_what was given" "pipe it on standard input or give it with --password-file <file>"
    fi
    unset _cc_storage; _cc_storage=""
    if [ -n "$_cc_slabel" ]; then
        _cc_swhat="$(printf '%s' "$_cc_slabel" | tr 'A-Z' 'a-z')"
        _cc_storage="$(_exakit_vs_read_storage "$_cc_slabel (storage)" "$_cc_sfile")" || _exakit_vs_secret_failed $?
        [ -n "$_cc_storage" ] || _exakit_vs_refuse 2 "This source also needs the storage's $_cc_swhat: give it with --storage-secret-file <file>." \
            "no storage $_cc_swhat was given" \
            "give it with --storage-secret-file <file> (a file holding only the $_cc_swhat), or answer the hidden prompt at a terminal"
    fi
    if [ -n "$_cc_storage" ]; then
        _exakit_vs_run "$(_exakit_vs_pair "$_cc_secret" "$_cc_storage")" connect "$@" --secret-pair-base64
    elif [ -n "$_cc_secret" ]; then
        _exakit_vs_run "$_cc_secret" connect "$@" --secret-stdin
    else
        _exakit_vs_run "" connect "$@"
    fi
    _cc_rc=$?
    unset _cc_secret _cc_storage EXAKIT_VS_STDIN_SECRET _EVP_SECRET
    if [ "$_cc_rc" -eq 0 ] && [ "$_cc_json" = 0 ]; then
        _exakit_vs_query_hints "$EXAKIT_VS_RESULT" "$_cc_name"
        info "Manage it with: exakit source show $_cc_name | check | reauth | refresh | disconnect | remove"
    fi
    _exakit_vs_exit "$_cc_rc"
}

# _exakit_vs_source_live <name> — the name is a source the kit connected and
# has not disconnected: `exakit connect` re-points it in place (or says there
# is nothing to change), on the line-by-line path. ⇄ twin: Test-ExakitVsSourceLive.
_exakit_vs_source_live() {
    case "$1" in ""|[!a-z]*|*[!a-z0-9_]*) return 1 ;; esac
    [ -f "$EXAKIT_HOME/sources/$1/config.json" ] || return 1
    ! grep -q '^  "status": "disconnected"' "$EXAKIT_HOME/sources/$1/state.json" 2>/dev/null
}

# _exakit_vs_source_exists <name> — a source the kit connected, disconnected
# or not: `exakit source <name>` opens it. ⇄ twin: Test-ExakitVsSourceExists.
_exakit_vs_source_exists() {
    case "$1" in ""|[!a-z]*|*[!a-z0-9_]*) return 1 ;; esac
    [ -f "$EXAKIT_HOME/sources/$1/config.json" ]
}

# _exakit_vs_word <text> — the text as one shell word: as it is when it needs
# no quoting, else in single quotes. For a command the --json answer names.
_exakit_vs_word() {
    case "$1" in
        ""|*[!A-Za-z0-9_@%+=:,./-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}

# _exakit_vs_query_list <file> <count> — how to query what was connected: one
# exakit sql line per source (file: name TAB connect-result-json-file per
# line), a first query on one of its real tables, as one shell word. How each
# kind of source names and types what it sends (the connector's tips) is
# exakit source show's. ⇄ twin: Show-ExakitVsQueryList.
_exakit_vs_query_list() {
    if [ "$2" = 1 ]; then info "Query it like any schema:"; else info "Query them like any schema:"; fi
    while IFS="$(printf '\t')" read -r _eql_name _eql_json; do
        [ -n "$_eql_name" ] || continue
        _eql_last="$_eql_name"
        _eql_q="$(run_python_any -c 'import json, sys
print(json.load(open(sys.argv[1]))["example"])' "$_eql_json" 2>/dev/null)"
        [ -n "$_eql_q" ] || _eql_q="SELECT * FROM VS_$(printf '%s' "$_eql_name" | tr 'a-z' 'A-Z').<table> LIMIT 10"
        printf '        exakit sql %s\n' "$(_exakit_vs_quoted "$_eql_q")"
    done < "$1"
    if [ "$2" = 1 ]; then
        info "Type and naming notes for it: exakit source show $_eql_last"
    else
        info "Type and naming notes for each source: exakit source show <name>"
    fi
}

# _exakit_vs_quoted <text> — the text in single quotes, each ' in it as '\''.
_exakit_vs_quoted() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# _exakit_vs_query_hints <connect-result-json> <name> — the one source's
# query line (_exakit_vs_query_list), for the line-by-line connect.
_exakit_vs_query_hints() {
    _eqh_file="${TMPDIR:-/tmp}/exakit-vs-hints.$$"
    printf '%s' "$1" > "$_eqh_file.json"
    printf '%s\t%s\n' "$2" "$_eqh_file.json" > "$_eqh_file"
    _exakit_vs_query_list "$_eqh_file" 1
    rm -f "$_eqh_file" "$_eqh_file.json"
}

# _exakit_vs_show_plan <plan-json> — what will happen, before it does.
_exakit_vs_show_plan() {
    [ -n "$1" ] || return 0
    printf '%s' "$1" | run_python_any -c 'import json, sys
p = json.load(sys.stdin)
repoint = p.get("action") == "repoint"
print("  %s %s (%s, %s, %s)" % ("Re-point" if repoint else "Plan for", p["name"], p["connector"], p["tier"], p["status"]))
for c in p.get("changes") or []:
    print("    %s: %s -> %s" % (c["input"], "(none)" if c["from"] is None else c["from"], "(none)" if c["to"] is None else c["to"]))
if p.get("action") == "unchanged":
    print("  " + p["note"])
if repoint:
    if not p.get("changes"):
        print("    Address: as it is - only the credential is replaced")
    print("    Credential: required - give it again (the database never returns a stored one); it is tried with the new address before anything changes")
for d in p["downloads"]:
    print("    %s %s %s (%.1f MB%s)" % ("reuse" if d["cached"] else "download", d["role"], d["version"], d["bytes"] / 1e6, ", " + d["license"]))
for s in p["steps"]:
    print("    - " + s)
print("    Exposure: " + p["exposure"])
for w in p["warnings"]:
    print("    Warning: " + w)
if p.get("gate"):
    print("    Not available yet: " + p["gate"])' 2>/dev/null
}

# --- exakit source and exakit source <name>: the card and the menus ---------
# The engine decides the words (engine/card.py: `card`, `cards`), the shell
# draws them; `--json` of every sub-command stays the engine's own answer.
# ⇄ twins in exakit.ps1: Show-ExakitVsCard, Invoke-ExakitVsSourceMenu,
# Invoke-ExakitVsSourcePicker.

# _exakit_vs_mid — the separator a status line joins its parts with.
_exakit_vs_mid() { if [ "${UI_FANCY:-0}" = 1 ]; then printf '·'; else printf -- '-'; fi; }

# _exakit_vs_menu_ok — a person at a terminal: both ends a terminal, a fancy
# one (the picker redraws in place), and not --yes. A pipe gets the plain answer.
_exakit_vs_menu_ok() {
    [ -t 0 ] && [ -t 1 ] && [ "${UI_FANCY:-0}" = 1 ] && [ "${EXAKIT_VS_ASSUME_YES:-0}" != 1 ]
}

# _exakit_vs_card <card-json> [menu] — the source card: a box of labelled
# rows (never raw JSON, never a secret), the connector's notes, a first query
# and, without "menu" (the menu is under it then), how to manage it.
_exakit_vs_card() {
    _evc_lines="$(printf '%s' "$1" | run_python_any -c 'import json, sys
r = json.load(sys.stdin)
tick, cross, mid = sys.argv[1:4]
print("TITLE\t%s %s %s" % (r["name"], mid, r["connector_name"]))
width = max(len(label) for label, _ in r["rows"]) + 2
for label, value in r["rows"]:
    if label == "Status":
        value = "%s %s" % (tick if r["ready"] else cross, (" %s " % mid).join(r["status_parts"]))
    print("ROW\t%s%s" % (label.ljust(width), " ".join(str(value).split())))
for n in r.get("notes") or []:
    print("NOTE\t" + " ".join(n.split()))
if r.get("remedy"):
    print("FIX\t" + r["remedy"])
print("TRY\t" + r["example"])
print("NAME\t" + r["name"])' "${UI_TICK}" "${UI_CROSS}" "$(_exakit_vs_mid)" 2>/dev/null)" || return 1
    _evc_cols="$(_ui_term_cols 2>/dev/null || echo 80)"
    _evc_notes=0
    while IFS="$(printf '\t')" read -r _evc_k _evc_v; do
        case "$_evc_k" in
            TITLE) ui_panel_begin "$_evc_v" ;;
            ROW)
                case "${UI_FANCY}:$_evc_v" in
                    "1:Status "*)
                        _evc_v="${_evc_v//${UI_TICK}/${UI_OK}${UI_TICK}${UI_RESET}}"
                        _evc_v="${_evc_v//${UI_CROSS}/${UI_ERR}${UI_CROSS}${UI_RESET}}" ;;
                esac
                ui_panel_line "$_evc_v" ;;
            NOTE)
                if [ "$_evc_notes" = 0 ]; then ui_panel_end; printf '  %sNotes%s\n' "${UI_BOLD}" "${UI_RESET}"; _evc_notes=1; fi
                _ui_wrap "$_evc_v" $(( _evc_cols - 9 ))
                _evc_i=0
                while [ "$_evc_i" -lt "$_UI_WRAP_N" ]; do
                    if [ "$_evc_i" = 0 ]; then printf '    %s%s%s %s\n' "${UI_DIM}" "${UI_BULLET}" "${UI_RESET}" "${_UI_WRAP[$_evc_i]}"
                    else printf '      %s\n' "${_UI_WRAP[$_evc_i]}"; fi
                    _evc_i=$(( _evc_i + 1 ))
                done ;;
            FIX)
                [ "$_evc_notes" = 0 ] && { ui_panel_end; _evc_notes=1; }
                printf '  %sFix:%s    %s\n' "${UI_BOLD}" "${UI_RESET}" "$_evc_v" ;;
            TRY)
                [ "$_evc_notes" = 0 ] && { ui_panel_end; _evc_notes=1; }
                printf '  %sTry:%s    exakit sql %s\n' "${UI_BOLD}" "${UI_RESET}" "$(_exakit_vs_quoted "$_evc_v")" ;;
            NAME)
                [ -n "${2:-}" ] || printf '  %sManage:%s exakit source %s   (menu)\n' "${UI_BOLD}" "${UI_RESET}" "$_evc_v" ;;
        esac
    done <<EOF2
$_evc_lines
EOF2
    return 0
}

# _exakit_vs_card_json <name> — the engine's card for one source, quietly:
# EXAKIT_VS_CARD, return 1 (said) when there is none.
_exakit_vs_card_json() {
    _evcj_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || { _exakit_vs_no_tmp; return 1; }
    exakit_vs_engine card "$1" < /dev/null > "$_evcj_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    _evcj_rc=$?
    _exakit_vs_render "$_evcj_out"; rm -f "$_evcj_out"
    EXAKIT_VS_CARD="$EXAKIT_VS_RESULT"
    [ "$_evcj_rc" -eq 0 ] && [ -n "$EXAKIT_VS_CARD" ]
}

# _exakit_vs_card_field <card-json> <python-expression on r> — one value of it.
_exakit_vs_card_field() {
    printf '%s' "$1" | run_python_any -c 'import json, sys
r = json.load(sys.stdin)
v = eval(sys.argv[1], {"r": r})
print("" if v is None else v)' "$2" 2>/dev/null
}

# _exakit_vs_repoint <name> <connector> <card-json> — "Move to a new host":
# each input that says where the source is, asked again with its value as the
# default, then the re-point connect (exakit connect <c> --name <name> --set
# ...), which shows the change and asks for the credential before anything moves.
_exakit_vs_repoint() {
    set --  "$2" --name "$1"
    _evrp_list="$(_exakit_vs_card_field "$3" '"\n".join("%s\t%s\t%s" % (a["input"], a["label"], a["value"]) for a in r["address"])')"
    while IFS="$(printf '\t')" read -r _evrp_in _evrp_label _evrp_val; do
        [ -n "$_evrp_in" ] || continue
        _evrp_new="$(prompt_text "$_evrp_label (Enter keeps it)" "$_evrp_val" < /dev/tty)"
        [ -n "$_evrp_new" ] && [ "$_evrp_new" != "$_evrp_val" ] && set -- "$@" --set "$_evrp_in=$_evrp_new"
    done <<EOF2
$_evrp_list
EOF2
    ( cmd_connect "$@" )
}

# _exakit_vs_source_menu <name> — exakit source <name> at a terminal: the
# card, then what to do with it; a source that is not ready has its fix
# first. After each action the card again, its state as it is now; q quits.
# Returns 0 when the source is gone (removed).
_exakit_vs_source_menu() {
    _evsm_name="$1"
    _evsm_rows="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || { _exakit_vs_no_tmp; return 1; }
    while :; do
        _exakit_vs_card_json "$_evsm_name" || { rm -f "$_evsm_rows"; return 1; }
        _evsm_card="$EXAKIT_VS_CARD"
        printf '\n'
        _exakit_vs_card "$_evsm_card" menu
        _evsm_conn="$(_exakit_vs_card_field "$_evsm_card" 'r["connector"]')"
        _evsm_fix="$(_exakit_vs_card_field "$_evsm_card" '(r["fix"] or {}).get("action", "")')"
        _evsm_acts=""
        : > "$_evsm_rows"
        if [ -n "$_evsm_fix" ]; then
            printf '✗ %s\n' "$(_exakit_vs_card_field "$_evsm_card" 'r["fix"]["label"]')" >> "$_evsm_rows"
            _evsm_acts="$_evsm_fix"
        fi
        printf '%s\n' "Tables and columns          (describe)" "Test it now                 (check)" \
            "Pick up new tables          (refresh)" "New password or token       (reauth)" \
            "Move to a new host          (re-point)" "Disconnect for now          (disconnect)" \
            "Remove it                   (remove)" >> "$_evsm_rows"
        _evsm_acts="$_evsm_acts describe check refresh reauth repoint disconnect remove"
        printf '\n  %sWhat do you want to do?%s\n' "${UI_BOLD}" "${UI_RESET}"
        UI_PICK_HINT="Enter to choose"
        ui_pick_menu "$_evsm_rows" || { rm -f "$_evsm_rows"; return 1; }
        [ "${UI_PICK}" -gt 0 ] || { rm -f "$_evsm_rows"; return 1; }
        # shellcheck disable=SC2086 — the action words, split on purpose
        set -- $_evsm_acts
        eval "_evsm_act=\${${UI_PICK}}"
        printf '\n'
        case "$_evsm_act" in
            repoint) _exakit_vs_repoint "$_evsm_name" "$_evsm_conn" "$_evsm_card" ;;
            reconnect) ( cmd_connect "$_evsm_conn" --name "$_evsm_name" ) ;;
            *) ( cmd_source "$_evsm_act" "$_evsm_name" ) ;;
        esac
        if [ ! -f "$EXAKIT_HOME/sources/$_evsm_name/config.json" ]; then rm -f "$_evsm_rows"; return 0; fi
    done
}

# _exakit_vs_source_picker — exakit source at a terminal: every source in a
# box (name, connector, status, tables); Enter opens one (its card and menu),
# q quits. Back from a source, the box again, as the sources are now.
_exakit_vs_source_picker() {
    _evsp_rows="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || { _exakit_vs_no_tmp; return 1; }
    _evsp_at=1
    while :; do
        _evsp_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || { _exakit_vs_no_tmp; return 1; }
        exakit_vs_engine cards < /dev/null > "$_evsp_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        _exakit_vs_render "$_evsp_out"; rm -f "$_evsp_out"
        [ -n "$EXAKIT_VS_RESULT" ] || { rm -f "$_evsp_rows"; return 1; }
        # The rows (the head first) to one file, the names in their order to another.
        printf '%s' "$EXAKIT_VS_RESULT" | run_python_any -c 'import json, sys
rows = [[s["name"], s["connector_name"], ("\u2713 " if s["ready"] else "\u2717 ") + s["reason"],
         "-" if s.get("tables") is None else str(s["tables"])] for s in json.load(sys.stdin)["sources"]]
rows = [[c if len(c) <= 34 else c[:33] + "\u2026" for c in r] for r in rows]
head = ["NAME", "CONNECTOR", "STATUS", "TABLES"]
width = [max([len(head[i])] + [len(r[i]) for r in rows]) for i in range(4)]
line = lambda r: "  ".join([r[0].ljust(width[0]), r[1].ljust(width[1]), r[2].ljust(width[2]), r[3].rjust(width[3])])
with open(sys.argv[1], "w", encoding="utf-8") as out, open(sys.argv[1] + ".names", "w") as names:
    print(line(head), file=out)
    for r in rows:
        print(line(r), file=out)
        print(r[0], file=names)' "$_evsp_rows.all" 2>/dev/null
        _evsp_head="$(sed -n 1p "$_evsp_rows.all")"
        sed 1d "$_evsp_rows.all" > "$_evsp_rows"
        if [ ! -s "$_evsp_rows" ]; then
            rm -f "$_evsp_rows" "$_evsp_rows.all" "$_evsp_rows.all.names"
            info "No sources yet. Connect one: exakit connect"
            return 0
        fi
        printf '\n'
        UI_PICK_HINT="Enter to open"; UI_PICK_START="$_evsp_at"
        ui_pick_menu "$_evsp_rows" "Sources" "$_evsp_head" || { rm -f "$_evsp_rows" "$_evsp_rows.all" "$_evsp_rows.all.names"; return 1; }
        [ "${UI_PICK}" -gt 0 ] || { rm -f "$_evsp_rows" "$_evsp_rows.all" "$_evsp_rows.all.names"; return 0; }
        _evsp_at="${UI_PICK}"
        _evsp_name="$(sed -n "${UI_PICK}p" "$_evsp_rows.all.names")"
        _exakit_vs_source_menu "$_evsp_name" && _evsp_at=1
    done
}

# _exakit_vs_catalog_box <catalog-json> — exakit source catalog for a person:
# id, name and the first aliases in a box (--json has every alias, the tier
# and the status), then where each connector's inputs are said.
_exakit_vs_catalog_box() {
    _evcb_lines="$(printf '%s' "$1" | run_python_any -c 'import json, sys
rows = []
for c in json.load(sys.stdin)["connectors"]:
    a = list(c.get("aliases", []))
    rows.append([c["id"], c["name"], ", ".join(a[:3]) + (", +%d" % (len(a) - 3) if len(a) > 3 else "")])
head = ["ID", "NAME", "ALIASES"]
w = [max([len(head[i])] + [len(r[i]) for r in rows]) for i in range(3)]
for r in [head] + rows:
    print(("  ".join([r[0].ljust(w[0]), r[1].ljust(w[1]), r[2]])).rstrip())' 2>/dev/null)"
    ui_panel_begin "Connectors"
    _evcb_first=1
    while IFS= read -r _evcb_l; do
        if [ "$_evcb_first" = 1 ]; then ui_panel_line "${UI_DIM}$_evcb_l${UI_RESET}"; _evcb_first=0
        else ui_panel_line "$_evcb_l"; fi
    done <<EOF2
$_evcb_lines
EOF2
    ui_panel_end
    printf '  What each needs: exakit connect <id> --help\n'
}

# cmd_source <action> [name] [options] — the lifecycle of a connected source.
# `exakit source` alone, at a terminal, is the picker; `exakit source <name>`
# the card and its menu (a pipe: the list, the card). Every sub-command, and
# --json of each, answers as it always has.
cmd_source() {
    # An option where the action goes (`exakit source --json`) means the
    # default action, list, with that option.
    _exakit_vs_quiet
    _cs_bare=0
    case "${1:-}" in
        ""|-*) _cs_action=list; _cs_bare=1 ;;
        list|issues|catalog|show|describe|check|reauth|refresh|disconnect|remove) _cs_action="$1"; shift ;;
        # A word that is no action but names a source: that source (open). Any
        # other word stays an unknown action, refused below as it always was.
        *) if _exakit_vs_source_exists "$1"; then _cs_action=open; else _cs_action="$1"; shift; fi ;;
    esac
    _cs_details=0
    _cs_json=0; _cs_dry=0; _cs_name=""; _cs_all=0; _cs_status=""; _cs_pwfile=""; _cs_table=""; _cs_ddl=0; _cs_into=""
    _cs_pwstdin=0; _cs_sfile=""
    # --json is known before anything is refused: the bridge's own refusals
    # and failures then come in the engine's shape, and nothing is asked.
    for _cs_word in "$@"; do case "$_cs_word" in --json|-j) _cs_json=1 ;; esac; done
    EXAKIT_VS_JSON="$_cs_json"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json|-j) _cs_json=1 ;;
            --dry-run|-n) _cs_dry=1 ;;
            --yes|-y) EXAKIT_VS_ASSUME_YES=1 ;;
            --all|-a) _cs_all=1 ;;
            --status) _cs_status="${2:-}"; shift ;;
            --password-file) _cs_pwfile="${2:-}"; shift ;;
            --password-stdin) _cs_pwstdin=1 ;;
            --storage-secret-file) _cs_sfile="${2:-}"; shift
                [ -n "$_cs_sfile" ] || _exakit_vs_refuse 2 "--storage-secret-file takes the path of a file holding only the storage secret." \
                    "--storage-secret-file was given without a file" "give the path of a file holding only the storage secret after --storage-secret-file"
                [ "$_cs_action" = reauth ] || _exakit_vs_refuse 2 "--storage-secret-file is for exakit source reauth (and exakit connect)." \
                    "--storage-secret-file was given to source $_cs_action, which takes no credential" "leave --storage-secret-file out" ;;
            --password*|--passwd*|--secret*|--token*|--storage-secret*) _exakit_vs_credential_argument ;;
            --ddl) _cs_ddl=1 ;;
            --details) _cs_details=1 ;;
            --schema) _cs_into="${2:-}"; shift ;;
            --schema=*) _cs_into="${1#--schema=}" ;;
            -*) _exakit_vs_refuse 2 "Unknown option '${1%%=*}' for source $_cs_action (exakit help source)." \
                    "unknown option '${1%%=*}' for source $_cs_action" "leave it out; the options are listed by: exakit help source" ;;
            *) if [ -z "$_cs_name" ]; then _cs_name="$1"
               elif [ "$_cs_action" = describe ] && [ -z "$_cs_table" ]; then _cs_table="$1"
               # The extra word is not repeated: it may be a credential.
               else _exakit_vs_refuse 2 "source $_cs_action takes one name." \
                        "source $_cs_action takes one name; got more than one" "name one source per command"; fi ;;
        esac
        shift
    done
    if [ "$_cs_pwstdin" = 1 ]; then
        # Only reauth takes a credential: a pipe given to another action would
        # be dropped unread.
        [ "$_cs_action" = reauth ] || _exakit_vs_refuse 2 "--password-stdin is for exakit source reauth (and exakit connect)." \
            "--password-stdin was given to source $_cs_action, which takes no credential" "leave --password-stdin out"
        [ -z "$_cs_pwfile" ] || _exakit_vs_refuse 2 "--password-stdin and --password-file both give the credential; use one." \
            "--password-stdin and --password-file were both given" "give the credential one way: --password-stdin or --password-file <file>"
    fi
    _require_install "$_cs_json"
    exakit_init_logging
    _exakit_vs_log_mark
    if [ "$_cs_action" = open ]; then
        # exakit source <name>: --json is show's answer, a pipe the card, a
        # person the card and its menu.
        _cs_action=show
        if [ "$_cs_json" = 0 ] && _exakit_vs_menu_ok; then
            _exakit_vs_source_menu "$_cs_name"
            exit 0
        fi
    fi
    if [ "$_cs_bare" = 1 ] && [ "$_cs_json" = 0 ] && [ -z "$_cs_name" ] && _exakit_vs_menu_ok; then
        _exakit_vs_source_picker
        exit 0
    fi
    case "$_cs_action" in
        list|issues|catalog|show|describe|check|reauth|refresh|disconnect|remove) ;;
        *) _exakit_vs_refuse 2 "Unknown source action '$_cs_action' (list, issues, show, describe, check, reauth, refresh, disconnect, remove, catalog)." \
               "unknown source action '$_cs_action'" \
               "use one of list, issues, show, describe, check, reauth, refresh, disconnect, remove, catalog (exakit help source)" ;;
    esac
    case "$_cs_action" in
        show|describe|reauth|refresh|disconnect|remove)
            [ -n "$_cs_name" ] || _exakit_vs_refuse 2 "exakit source $_cs_action needs a source name (see: exakit source list)." \
                "exakit source $_cs_action needs a source name" "name the source; the sources are listed by: exakit source list" \
                "exakit source list" ;;
        check) [ -n "$_cs_name" ] || [ "$_cs_all" = 1 ] || _exakit_vs_refuse 2 "exakit source check needs a name or --all." \
                   "exakit source check needs a name or --all" "name the source, or give --all to check every one" \
                   "exakit source check --all" ;;
    esac
    set --
    [ "$_cs_json" = 1 ] && set -- --json
    case "$_cs_action" in
        list)    set -- "$@" list ;;
        catalog) set -- "$@" catalog ;;
        issues)  set -- "$@" issues; [ -n "$_cs_status" ] && set -- "$@" --status "$_cs_status" ;;
        show|refresh) set -- "$@" "$_cs_action" "$_cs_name" ;;
        describe) set -- "$@" describe "$_cs_name"
                  [ -n "$_cs_table" ] && set -- "$@" "$_cs_table"
                  [ "$_cs_ddl" = 1 ] && set -- "$@" --ddl
                  [ -n "$_cs_into" ] && set -- "$@" --into "$_cs_into" ;;
        check)   if [ "$_cs_all" = 1 ]; then set -- "$@" check --all; else set -- "$@" check "$_cs_name"; fi ;;
        disconnect|remove)
            set -- "$@" "$_cs_action" "$_cs_name"
            if [ "$_cs_dry" = 1 ]; then
                set -- "$@" --dry-run
            elif [ "$_cs_json" = 1 ]; then
                # --json never asks, and asking is how a person agrees: without
                # --yes nothing is dropped (exit 5), as without a terminal and as
                # every other destructive exakit command.
                if [ "${EXAKIT_VS_ASSUME_YES:-0}" != 1 ]; then
                    _exakit_log_file "DECLINED source $_cs_action $_cs_name: --json without --yes"
                    _exakit_vs_json_failure declined "$_cs_action $_cs_name was not confirmed; nothing was changed" \
                        "preview it with --dry-run, then confirm it with --yes" "exakit source $_cs_action $_cs_name --yes --json"
                    exit 5
                fi
            else
                exakit_vs_engine "$_cs_action" "$_cs_name" --dry-run < /dev/null 2>/dev/null \
                    | sed -n 's/^RESULT //p' | run_python_any -c 'import json, sys
p = json.load(sys.stdin)
print("  " + "\n  ".join(["drops: " + ", ".join(p["drop"])] + (["keeps: " + ", ".join(p["keep"])] if p.get("keep") else [])
      + (["deletes %d unused file(s); keeps %d still shared" % (len(p.get("delete_files", [])), len(p.get("keep_files", [])))] if "delete_files" in p else [])
      + ["note: " + p["note"]]))' 2>/dev/null
                case "$_cs_action" in disconnect) _cs_verb="Disconnect" ;; *) _cs_verb="Remove" ;; esac
                _exakit_vs_confirm "$_cs_verb $_cs_name?" \
                    || { info "Nothing was changed. Confirm it with --yes."; exit 5; }
            fi ;;
        reauth)
            # The name before the credential: nobody types a password for a
            # source that does not exist.
            _cs_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || { _exakit_vs_no_tmp && exit 1; die "Could not create a temporary file."; }
            exakit_vs_engine "$@" show "$_cs_name" < /dev/null > "$_cs_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
            _cs_rc=$?
            if [ "$_cs_rc" -ne 0 ]; then
                if [ "$_cs_json" = 1 ]; then cat "$_cs_out"; else _exakit_vs_render "$_cs_out"; fi
                rm -f "$_cs_out"; _exakit_vs_exit "$_cs_rc"
            fi
            if [ "$_cs_json" = 1 ]; then
                _cs_conn="$(sed -n 's/^  "connector": "\([a-z0-9-]*\)",*$/\1/p' "$_cs_out" | head -n 1)"
            else
                _cs_conn="$(sed -n 's/^RESULT .*"connector": "\([a-z0-9-]*\)".*/\1/p' "$_cs_out" | head -n 1)"
            fi
            # A lakehouse source with two secrets: reauth writes its JSON whole, so both.
            _cs_slabel="$(if [ "$_cs_json" = 1 ]; then cat "$_cs_out"; else sed -n 's/^RESULT //p' "$_cs_out"; fi \
                | run_python_any -c 'import json, sys
print(json.load(sys.stdin).get("storage_secret") or "")' 2>/dev/null)"
            rm -f "$_cs_out"
            if [ -z "$_cs_slabel" ] && [ -n "$_cs_sfile" ]; then
                _exakit_vs_refuse 2 "$_cs_name has one secret; --storage-secret-file is for a lakehouse source with a catalog login and storage keys." \
                    "--storage-secret-file was given, but $_cs_name has one secret" "leave --storage-secret-file out"
            fi
            # With --json an unreadable file is the one object; without, the
            # credential reader says "Cannot read" as it always has.
            if [ "$_cs_json" = 1 ] && [ -n "$_cs_pwfile" ] && { [ -d "$_cs_pwfile" ] || [ ! -r "$_cs_pwfile" ]; }; then
                _exakit_vs_refuse 2 "Cannot read $_cs_pwfile" "cannot read $_cs_pwfile" \
                    "give a file this user can read with --password-file, or pipe the credential on a closed standard input"
            fi
            if [ "$_cs_pwstdin" = 1 ]; then
                _exakit_vs_stdin_secret
                unset _cs_secret; _cs_secret="$EXAKIT_VS_STDIN_SECRET"; unset EXAKIT_VS_STDIN_SECRET
            else
                unset _cs_secret
                _cs_secret="$(_exakit_vs_read_secret "New credential for $_cs_name" "$_cs_pwfile" "$(_exakit_vs_secret_kind "$_cs_conn")")" \
                    || _exakit_vs_secret_failed $?
            fi
            [ -n "$_cs_secret" ] || _exakit_vs_refuse 2 "No credential was given." "no credential was given" \
                "pipe it on standard input or give it with --password-file <file>"
            unset _cs_storage; _cs_storage=""
            if [ -n "$_cs_slabel" ]; then
                _cs_storage="$(_exakit_vs_read_storage "New $_cs_slabel (storage) for $_cs_name" "$_cs_sfile")" || _exakit_vs_secret_failed $?
                [ -n "$_cs_storage" ] || _exakit_vs_refuse 2 "$_cs_name has two secrets, and reauth writes both: give the storage secret too with --storage-secret-file <file>." \
                    "reauth of $_cs_name needs the storage secret as well" \
                    "give both: --password-file <file> (or --password-stdin) and --storage-secret-file <file>"
                _cs_secret="$(_exakit_vs_pair "$_cs_secret" "$_cs_storage")"; unset _cs_storage
                set -- "$@" reauth "$_cs_name" --secret-pair-base64
            else
                set -- "$@" reauth "$_cs_name" --secret-stdin
            fi
            if [ "$_cs_json" = 1 ]; then
                # The engine's events and any traceback go to the log, as connect's do.
                printf '%s' "$_cs_secret" | exakit_vs_engine "$@" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
                _exakit_vs_exit $?
            fi
            _exakit_vs_run "$_cs_secret" "$@"; _cs_rc=$?; unset _cs_secret
            [ "$_cs_rc" -eq 0 ] && ok "$_cs_name is ready again with the new credential"
            _exakit_vs_exit "$_cs_rc" ;;
    esac
    if [ "$_cs_json" = 1 ]; then
        exakit_vs_engine "$@" < /dev/null 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        _exakit_vs_exit $?
    fi
    if [ "$_cs_action" = show ]; then
        # The card: labelled rows, never the record's JSON (that is --json's;
        # the object names and pins are --details').
        if [ "$_cs_details" = 1 ]; then _exakit_vs_run "" card "$_cs_name" --details; else _exakit_vs_run "" card "$_cs_name"; fi
        _cs_rc=$?
        [ "$_cs_rc" -eq 0 ] && [ -n "$EXAKIT_VS_RESULT" ] && _exakit_vs_card "$EXAKIT_VS_RESULT"
        _exakit_vs_exit "$_cs_rc"
    fi
    if [ "$_cs_action" = catalog ]; then
        _exakit_vs_run "" "$@"
        _cs_rc=$?
        [ "$_cs_rc" -eq 0 ] && [ -n "$EXAKIT_VS_RESULT" ] && _exakit_vs_catalog_box "$EXAKIT_VS_RESULT"
        _exakit_vs_exit "$_cs_rc"
    fi
    _exakit_vs_run "" "$@"
    _cs_rc=$?
    if [ "$_cs_rc" -eq 0 ] && [ "$_cs_dry" != 1 ]; then
        case "$_cs_action" in
            disconnect) ok "$_cs_name disconnected: VS_$(printf '%s' "$_cs_name" | tr 'a-z' 'A-Z') stays, its queries fail until you connect it again with --name $_cs_name"; exit 0 ;;
            remove) ok "$_cs_name removed"; exit 0 ;;
        esac
    fi
    if [ "$_cs_action" = describe ]; then
        # --ddl prints only the statements, so they can go straight to a file.
        [ -n "$EXAKIT_VS_RESULT" ] && printf '%s' "$EXAKIT_VS_RESULT" | run_python_any -c 'import json, sys
r = json.load(sys.stdin)
if not r["tables"]:
    print("  %s shows no tables. If the source has some now: exakit source refresh %s" % (r["schema"], r["name"]))
for t in r["tables"]:
    if "ddl" in t:
        sys.stdout.write(t["ddl"] + "\n")
        continue
    print("  %s.%s (%d column%s)" % (r["schema"], t["name"], len(t["columns"]), "" if len(t["columns"]) == 1 else "s"))
    width = max([len(c["name"]) for c in t["columns"]] + [6])
    for c in t["columns"]:
        print("    %s  %s%s" % (c["name"].ljust(width), c["type"], "" if c["nullable"] else "  NOT NULL"))
    print("")' 2>/dev/null
        _exakit_vs_exit "$_cs_rc"
    fi
    # The sources (list, issues) are one table inside the terminal (argv[1], its
    # width; the last column left unwritten). Too wide, SCHEMA goes first - it is
    # always VS_<NAME> - then LAST CHECK (exakit source show has it), then HOST
    # is cut, never below 10. An issue's fix goes on its own line under its row.
    # Twin of the rows block in Invoke-CmdSource (exakit.ps1).
    [ -n "$EXAKIT_VS_RESULT" ] && printf '%s' "$EXAKIT_VS_RESULT" | run_python_any -c 'import json, sys
r = json.load(sys.stdin)
rows = r["sources"] if "sources" in r else r.get("issues")
if rows is not None:
    if not rows:
        print("  (none)")
    heads = ["NAME", "SOURCE", "SCHEMA", "HOST", "TLS", "STATUS", "LAST CHECK"]
    cells = []
    for s in rows:
        at = (s.get("last_check") or {}).get("at") or ""
        cells.append([s["name"], s["connector"], s["schema"], s.get("host") or "-", s.get("tls") or "n/a",
                      s["status"], at[:16].replace("T", " ") or "never"])
    width = [max([len(h)] + [len(c[i]) for c in cells]) for i, h in enumerate(heads)]
    shown = [0, 1, 2, 3, 4, 5, 6]
    room = (int(sys.argv[1]) if sys.argv[1:] and sys.argv[1].isdigit() else 80) - 1
    for i in (2, 6):
        if 2 * len(shown) + sum(width[j] for j in shown) > room:
            shown.remove(i)
    over = 2 * len(shown) + sum(width[j] for j in shown) - room
    if over > 0:
        width[3] = max(10, width[3] - over)
    def line(c):
        out = [(c[j] if len(c[j]) <= width[j] else c[j][:width[j] - 3] + "...").ljust(width[j]) for j in shown]
        return ("  " + "  ".join(out)).rstrip()
    if rows:
        print(line(heads))
    for s, c in zip(rows, cells):
        print(line(c))
        if s.get("remedy"):
            print("    fix: " + s["remedy"])
elif "connectors" in r:
    for c in r["connectors"]:
        print("  %-12s %-18s %-5s %-10s aliases: %s" % (c["id"], c["name"], c["tier"], c["status"], ", ".join(c.get("aliases", []))))
elif "drop" in r:
    print("  drops: " + ", ".join(r["drop"]))
    if r.get("keep"):
        print("  keeps: " + ", ".join(r["keep"]))
    if "delete_files" in r:
        print("  deletes %d unused file(s); keeps %d still shared" % (len(r["delete_files"]), len(r.get("keep_files", []))))
    print("  note: " + r["note"])
elif "checks" in r:
    if not r["checks"]:
        print("  (none)")
    for c in r["checks"]:
        print("  %-16s %s %s" % (c["name"], c["status"], c.get("evidence") or c.get("remedy") or ""))
else:
    for k in ("name", "connector", "status", "objects", "inputs", "pins", "needs_refresh", "tables", "last_check", "evidence", "remedy"):
        if r.get(k) not in (None, "", {}):
            print("  %-11s %s" % (k, json.dumps(r[k]) if isinstance(r[k], (dict, list)) else r[k]))
    for i, t in enumerate(r.get("tips") or []):
        print("  %-11s %s" % ("tips" if i == 0 else "", t))' "$(_ui_term_cols 2>/dev/null || echo 80)" 2>/dev/null
    _exakit_vs_exit "$_cs_rc"
}
