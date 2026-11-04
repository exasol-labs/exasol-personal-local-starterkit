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
#   exit 21  the Java language container is missing   -> `exasol slc install java` (asked), retry once

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

# exakit_vs_connect_wizard — the data-load row: `exakit connect` asking for
# everything. Run in a subshell by the caller, since cmd_connect exits.
exakit_vs_connect_wizard() {
    cmd_connect
}

# exakit_vs_engine <args...> — the engine with this installation's context.
# Its stdin is passed through: that is where a secret travels.
exakit_vs_engine() {
    _eve_defs="$(exakit_vs_defs)" || { error "This kit copy has no setup/virtual-schemas. Update it: exakit update"; return 2; }
    _eve_py=""
    command -v pyexasol_venv_python >/dev/null 2>&1 && _eve_py="$(pyexasol_venv_python 2>/dev/null || true)"
    if [ -z "$_eve_py" ] || [ ! -x "$_eve_py" ]; then
        error "Virtual schemas run with the kit's pyexasol, which is not installed. Repair it: exakit update pyexasol"
        return 2
    fi
    "$_eve_py" "$_eve_defs/engine/cli.py" --defs "$_eve_defs" --kit-home "$EXAKIT_HOME" \
        --deployment-dir "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" \
        --dsn "$(manifest_get runtime.dsn 2>/dev/null || true)" \
        --user "$(manifest_get runtime.user 2>/dev/null || printf sys)" \
        --password-file "$(manifest_get runtime.password_file 2>/dev/null || true)" "$@"
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

# _exakit_vs_read_secret <label> <password-file> [kind] — a secret, from the
# file the caller named, else a hidden prompt, else stdin. Never from an
# argument. A secret-file credential (a key file) is asked for by its path on
# a terminal - nobody pastes a JSON key into a hidden prompt.
_exakit_vs_read_secret() {
    if [ -n "$2" ]; then
        [ -r "$2" ] || { error "Cannot read $2"; return 1; }
        cat "$2"
        return 0
    fi
    _evs_tty="$(_exakit_prompt_tty)"
    if [ -n "$_evs_tty" ] && [ -r /dev/tty ]; then
        if [ "${3:-}" = "secret-file" ]; then
            _evs_path="$(prompt_text "$1 - path to the file" "")"
            case "$_evs_path" in "~/"*) _evs_path="$HOME/${_evs_path#\~/}" ;; esac
            [ -n "$_evs_path" ] && [ -r "$_evs_path" ] || { error "Cannot read ${_evs_path:-the file}"; return 1; }
            cat "$_evs_path"
            return 0
        fi
        exakit_read_hidden "$1" || { error "The terminal cannot hide input; give the credential with --password-file."; return 1; }
        return 0
    fi
    cat
}

# _exakit_vs_secret_kind <connector> — the kind of its credential input
# (secret or secret-file), empty when it has none.
_exakit_vs_secret_kind() {
    run_python_any -c 'import json,sys; c=json.load(open(sys.argv[1])); print(next((s["kind"] for s in c["inputs"] if s["kind"] in ("secret","secret-file")), ""))' \
        "$(exakit_vs_defs)/connectors/$1/connector.json" 2>/dev/null
}

# _exakit_vs_confirm <question> — yes on a terminal answer y, or --yes.
_exakit_vs_confirm() {
    [ "${EXAKIT_VS_ASSUME_YES:-0}" = 1 ] && return 0
    [ -n "$(_exakit_prompt_tty)" ] || return 1
    case "$(prompt_text "$1 [y/N]" "N")" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# _exakit_vs_install_java — the Java language container, with consent: a
# download of about 250 MiB and one database restart, done through the kit's
# own stop/start so add-on services come back and DNS is repaired.
_exakit_vs_install_java() {
    info "Virtual schemas run Java inside the database, and its Java language container is not installed."
    info "Installing it downloads about 250 MiB and restarts the database once (add-on services restart with it)."
    if ! _exakit_vs_confirm "Install the Java language container now?"; then
        info "Install it later with: exasol slc install java --no-restart, then exakit stop and exakit start"
        return 1
    fi
    run_logged "$(personal_cli)" slc install java --no-restart $(personal_auto_approve_flag slc) \
        || { error "The Java language container did not install. Details: exakit logs"; return 1; }
    EXAKIT_STOP_ADDONS=1 "$EXAKIT_BIN_DIR/exakit" stop >/dev/null 2>&1 || true
    "$EXAKIT_BIN_DIR/exakit" start || { error "The database did not come back after installing Java. Run: exakit start"; return 1; }
    # An installed kit's start repairs DNS; this kit copy may be newer than it.
    personal_slc_dns_repair || true
    ok "Java language container installed"
}

# _exakit_vs_install_rust — the Rust language container a native adapter
# (Profile D) runs in, with consent: the exasol-labs build pinned for this CPU
# in profiles/rust-native, size- and SHA-256-checked, registered as the RUST
# alias, then one database restart through the kit's own stop/start. Twin of
# Install-ExakitVsRust.
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
    info "This source runs a native adapter inside the database, and its Rust language container is not installed."
    info "Installing it downloads $_evr_upstream $_evr_version (about $((_evr_size / 1048576)) MiB, checksum-pinned) and restarts the database once (add-on services restart with it)."
    if ! _exakit_vs_confirm "Install the Rust language container now?"; then
        info "Nothing was installed. Run the same exakit connect again when you are ready."
        return 1
    fi
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
    EXAKIT_STOP_ADDONS=1 "$EXAKIT_BIN_DIR/exakit" stop >/dev/null 2>&1 || true
    "$EXAKIT_BIN_DIR/exakit" start || { error "The database did not come back after installing Rust. Run: exakit start"; return 1; }
    ok "Rust language container installed"
}

# _exakit_vs_run <secret-or-empty> <engine args...> — run the engine once,
# repairing DNS (exit 20) or installing Java (exit 21) or Rust (exit 23) and retrying once.
_exakit_vs_run() {
    _evx_secret="$1"; shift
    _evx_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || return 1
    _evx_try=0
    while :; do
        _evx_try=$((_evx_try + 1))
        if [ -n "$_evx_secret" ]; then
            printf '%s' "$_evx_secret" | exakit_vs_engine "$@" > "$_evx_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        else
            exakit_vs_engine "$@" < /dev/null > "$_evx_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        fi
        _evx_rc=$?
        _exakit_vs_render "$_evx_out"
        [ "$_evx_try" -eq 1 ] || break
        case "$_evx_rc" in
            20) info "Giving the database's language containers the deployment's DNS, then trying again"
                personal_slc_dns_repair || { error "DNS could not be repaired. Restart the database (exakit stop, exakit start) and try again."; break; } ;;
            21) _exakit_vs_install_java || break ;;
            23) _exakit_vs_install_rust || break ;;
            *)  break ;;
        esac
    done
    rm -f "$_evx_out"
    return "$_evx_rc"
}

# _exakit_vs_ask_inputs <connector> — prompt for each input the caller did not
# set, defaults offered; appends --set KEY=VALUE pairs to EXAKIT_VS_SETS.
_exakit_vs_ask_inputs() {
    _evi_lines="$(run_python_any - "$(exakit_vs_defs)/connectors/$1/connector.json" <<'PY'
import json, sys
for spec in json.load(open(sys.argv[1]))["inputs"]:
    if spec["kind"] in ("secret", "secret-file"):
        continue
    choices = "/".join(spec.get("choices", []))
    print("%s|%s|%s|%s" % (spec["name"], spec.get("label", spec["name"]), spec.get("default", ""), choices))
PY
)"
    while IFS='|' read -r _evi_name _evi_label _evi_default _evi_choices; do
        [ -n "$_evi_name" ] || continue
        case " $EXAKIT_VS_GIVEN " in *" $_evi_name "*) continue ;; esac
        [ -n "$_evi_choices" ] && _evi_label="$_evi_label ($_evi_choices)"
        _evi_value="$(prompt_text "$_evi_label" "$_evi_default")"
        [ -n "$_evi_value" ] && EXAKIT_VS_SETS="$EXAKIT_VS_SETS
--set
$_evi_name=$_evi_value"
    done <<EOF
$_evi_lines
EOF
}

# --- the terminal flow: pick, fill in, review, connect ----------------------------
#
# `exakit connect` on a terminal that can draw (UI_FANCY) and answer (stdin is
# the terminal), without --yes, --dry-run or --json:
#   1. pick    the marketplace's own table (ui_table_menu): one row per connector,
#              the sources already connected named in its Description; skipped
#              when the command named a connector;
#   2. fill    one panel per picked source, every field visible with its default,
#              each answer checked by the engine where it was typed (cli.py field,
#              the value on its stdin); a credential is a hidden prompt (or a key
#              file's path) and stays in this shell's memory until it goes down
#              the engine's stdin;
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
# redraw leaves behind.
_exakit_vs_tui_rows() {
    if [ "$1" -le 0 ]; then echo 1; else echo $(( ($1 - 1) / _EVT_COLS + 1 )); fi
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

# _exakit_vs_pick <work-dir> — the connector menu. Sets EXAKIT_VS_PICKED to the
# chosen connector ids, space separated; returns 5 when nothing was chosen.
_exakit_vs_pick() {
    _evp_dir="$1"
    exakit_vs_engine catalog < /dev/null > "$_evp_dir/catalog" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    exakit_vs_engine list < /dev/null > "$_evp_dir/list" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    # id|label|kind|description|gate. The label drops a parenthesis ("Lakehouse
    # (Iceberg on AWS Glue)" is "Lakehouse"): the summary says what it is, and
    # the sources already connected through it follow it.
    run_python_any - "$(_exakit_vs_result "$_evp_dir/catalog")" "$(_exakit_vs_result "$_evp_dir/list")" \
        > "$_evp_dir/rows" <<'PY'
import json, sys
catalog = json.loads(sys.argv[1] or "{}").get("connectors", [])
have = {}
for s in json.loads(sys.argv[2] or "{}").get("sources", []):
    have.setdefault(s.get("connector", ""), []).append(s.get("name", ""))
kinds = {"java-jdbc": "JDBC", "java-document-files": "files", "lua-jdbc": "REST + JDBC", "rust-native": "native"}
for e in catalog:
    if e.get("tier") != "GA":
        continue
    text = e.get("summary", "")
    if have.get(e["id"]):
        text += " · connected: " + ", ".join(sorted(have[e["id"]]))
    gate = e.get("gate", "") if e.get("status") == "gated" else ""
    print("|".join(x.replace("|", "/") for x in
                   (e["id"], e["name"].split(" (")[0], kinds.get(e["profile"], e["profile"]), text, gate)))
PY
    [ -s "$_evp_dir/rows" ] || { error "The connector catalog could not be read. Details: exakit logs"; return 2; }
    _evp_state="$_evp_dir/menu"
    : > "$_evp_state"
    _evp_n="$(grep -c . "$_evp_dir/rows")"
    _evp_i=0; _evp_ids=""
    while IFS='|' read -r _evp_id _evp_label _evp_kind _evp_text _evp_gate; do
        _evp_i=$(( _evp_i + 1 ))
        _evp_tree=tee; [ "$_evp_i" -eq "$_evp_n" ] && _evp_tree=corner
        # kind|label|tick|state|pct|ceiling|secs|t0|phase|final|col2|col3; a
        # gated connector is shown, never pickable, with its gate as the reason
        # (the marketplace's own disabled-row shape).
        if [ -n "$_evp_gate" ]; then
            printf '%s|%s|0|disabled||||||%s|%s|%s\n' "$_evp_tree" "$_evp_label" \
                "not available yet" "$_evp_kind" "not available yet: $_evp_gate" >> "$_evp_state"
        else
            printf '%s|%s|0|idle|||||||%s|%s\n' "$_evp_tree" "$_evp_label" "$_evp_kind" "$_evp_text" >> "$_evp_state"
        fi
        _evp_ids="$_evp_ids
$_evp_id"
    done < "$_evp_dir/rows"
    printf 'plain|Skip|0|idle||||||| | \n' >> "$_evp_state"
    _evp_skip=$(( _evp_n + 1 ))
    EXAKIT_TABLE_DEFAULTS=""            # nothing ticked: a connect is always a choice
    EXAKIT_TABLE_GROUP=""
    EXAKIT_TABLE_EXCLUSIVE="$_evp_skip"
    UI_TABLE_TITLE="Connect external sources"
    UI_TABLE_COL1="Source"; UI_TABLE_COL2="Kind"; UI_TABLE_COL3="Description"
    UI_TABLE_MENU_START=1               # no "Select All" row to step past
    info "Tick one or more sources; the details for each are asked next."
    ui_table_menu "$_evp_state"
    UI_TABLE_COL2=""; UI_TABLE_COL3=""
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

# _exakit_vs_tui_frame <title> <current-field> — the panel, built into _EVT_BUF
# with its height in _EVT_BUF_N.
_exakit_vs_tui_frame() {
    _EVT_BUF=""; _EVT_BUF_N=0
    _evf_t=" $1 "
    _evf_fill=$(( _EVT_IN - ${#_evf_t} - 1 )); [ "$_evf_fill" -ge 0 ] || _evf_fill=0
    _EVT_BUF="  $UI_ACCENT$UI_TL$UI_HR$UI_RESET$UI_BOLD$_evf_t$UI_RESET$UI_ACCENT${_EVT_HR:0:$_evf_fill}$UI_TR$UI_RESET"$'\n'
    _EVT_BUF_N=1
    _evf_i=0
    while [ "$_evf_i" -lt "$_EVT_NF" ]; do
        _evf_lab="${_EVT_LAB[$_evf_i]}"
        _evf_lab="$_evf_lab${_EVT_SP:0:$(( _EVT_LW - ${#_evf_lab} ))}"
        _evf_kind="${_EVT_KIND[$_evf_i]}"
        if [ "$_evf_i" -eq "$2" ]; then
            _evf_mark="$UI_ACCENT$UI_ARROW$UI_RESET"; _evf_shown="$UI_BOLD$_evf_lab$UI_RESET"
            _evf_plain=""; _evf_val=""
        elif [ -n "${_EVT_DONE[$_evf_i]:-}" ]; then
            _evf_mark="$UI_OK$UI_TICK$UI_RESET"; _evf_shown="$_evf_lab"
            _evf_val="${_EVT_VAL[$_evf_i]}"
            if [ "$_evf_kind" = secret ]; then
                if [ -n "$_evf_val" ]; then _evf_val="(given, hidden)"; else _evf_val="(read from a file)"; fi
            fi
            [ -n "$_evf_val" ] || _evf_val="(none)"
            _evf_plain="$(_exakit_vs_tui_tail "$_evf_val" "$_EVT_VW")"
            _evf_val="$_evf_plain"
        else
            _evf_mark=" "; _evf_shown="$UI_DIM$_evf_lab$UI_RESET"
            _evf_val="${_EVT_VAL[$_evf_i]:-${_EVT_DEF[$_evf_i]}}"
            case "$_evf_kind" in secret|secret-file) _evf_val="" ;; esac
            [ -n "$_evf_val" ] && _evf_val="[$(_exakit_vs_tui_tail "$_evf_val" $(( _EVT_VW - 2 )))]"
            _evf_plain="$_evf_val"; _evf_val="$UI_DIM$_evf_val$UI_RESET"
        fi
        _evf_pad=$(( _EVT_IN - 7 - _EVT_LW - ${#_evf_plain} )); [ "$_evf_pad" -ge 0 ] || _evf_pad=0
        _EVT_BUF="$_EVT_BUF  $UI_ACCENT$UI_VB$UI_RESET  $_evf_mark  $_evf_shown  $_evf_val${_EVT_SP:0:$_evf_pad}$UI_ACCENT$UI_VB$UI_RESET"$'\n'
        _EVT_BUF_N=$(( _EVT_BUF_N + 1 ))
        _evf_i=$(( _evf_i + 1 ))
    done
    _EVT_BUF="$_EVT_BUF  $UI_ACCENT$UI_BL${_EVT_HR:0:$_EVT_IN}$UI_BR$UI_RESET"$'\n'
    _EVT_BUF_N=$(( _EVT_BUF_N + 1 ))
}

# _exakit_vs_tui_draw <title> <current-field> — the panel over what this form
# drew last (_EVT_ON_SCREEN lines: the panel and every line under it), in one write.
_exakit_vs_tui_draw() {
    _exakit_vs_tui_frame "$1" "$2"
    if [ "$_EVT_ON_SCREEN" -gt 0 ]; then
        printf '\r\033[%dA\033[0J%s' "$_EVT_ON_SCREEN" "$_EVT_BUF"
    else
        printf '%s' "$_EVT_BUF"
    fi
    _EVT_ON_SCREEN="$_EVT_BUF_N"
}

# _exakit_vs_tui_say <mark> <text> — a line under the panel (a refused answer and
# why), wrapped to the terminal and counted for the next redraw.
_exakit_vs_tui_say() {
    _ui_wrap "$2" $(( _EVT_COLS - 8 ))
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
        # Echo off BEFORE the prompt shows: a key typed the moment it appears
        # would otherwise be echoed in clear (exakit_read_hidden, same order).
        _eva_saved="$(stty -g 2>/dev/null)"
        trap 'stty "${_eva_saved:-echo}" 2>/dev/null; printf "\n"; exit 130' INT TERM
        if ! stty -echo 2>/dev/null; then
            _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "this terminal cannot hide input; give the credential with --password-file"
            _EVT_ANSWER=""; trap - INT TERM; return 1
        fi
        printf '  %s: ' "$2"
        IFS= read -r _EVT_ANSWER; _eva_rc=$?
        stty "${_eva_saved:-echo}" 2>/dev/null
        trap - INT TERM
        printf '\n'
        _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + $(_exakit_vs_tui_rows $(( ${#1} + 4 ))) ))
        return "$_eva_rc"
    fi
    # The prompt goes through readline (-p), its colour marked invisible
    # (\001..\002), so editing and history redraw it in the right place.
    IFS= read -r -e -p "  $2: " _EVT_ANSWER; _eva_rc=$?
    _EVT_ON_SCREEN=$(( _EVT_ON_SCREEN + $(_exakit_vs_tui_rows $(( ${#1} + 4 + ${#_EVT_ANSWER} ))) ))
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

# _exakit_vs_tui_form <connector> <pos> <total> <given-name> <given-sets> <password-file>
# — one source's panel; on success it joins the _EVT_S_* lists. Returns 5 when
# the reader left it out, 2 when its definition could not be read.
_exakit_vs_tui_form() {
    _evo_id="$1"; _evo_pos="$2"; _evo_total="$3"; _evo_pwfile="$6"
    exakit_vs_engine inputs "$_evo_id" < /dev/null > "$_EVT_DIR/inputs" 2>>"${EXAKIT_LOG_FILE:-/dev/null}" || {
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
    for cut in (" - ", " (", "; "):
        label = label.split(cut)[0]
    print("|".join(str(x).replace("|", "/") for x in
                   (f["name"], label, f["kind"], "1" if f["required"] else "", f["default"], " ".join(f["choices"]))))
PY
    _evo_label=""
    _EVT_NAME=(); _EVT_LAB=(); _EVT_KIND=(); _EVT_REQ=(); _EVT_DEF=(); _EVT_CH=(); _EVT_VAL=(); _EVT_DONE=()
    _EVT_NF=0; _EVT_LW=0
    while IFS='|' read -r _evo_n _evo_l _evo_k _evo_r _evo_d _evo_c; do
        if [ -z "$_evo_label" ]; then _evo_label="$_evo_n"; continue; fi
        _EVT_NAME[$_EVT_NF]="$_evo_n"; _EVT_LAB[$_EVT_NF]="$_evo_l"; _EVT_KIND[$_EVT_NF]="$_evo_k"
        _EVT_REQ[$_EVT_NF]="$_evo_r"; _EVT_DEF[$_EVT_NF]="$_evo_d"; _EVT_CH[$_EVT_NF]="$_evo_c"
        _EVT_VAL[$_EVT_NF]=""; _EVT_DONE[$_EVT_NF]=""
        # What the command line already said is an answer, not a question.
        if [ "$_evo_k" = source-name ] && [ -n "$4" ]; then _EVT_VAL[$_EVT_NF]="$4"; _EVT_DONE[$_EVT_NF]=1; fi
        _evo_given="$(printf '%s\n' "$5" | sed -n "s/^$_evo_n=//p" | tail -1)"
        [ -n "$_evo_given" ] && { _EVT_VAL[$_EVT_NF]="$_evo_given"; _EVT_DONE[$_EVT_NF]=1; }
        if [ -n "$_evo_pwfile" ]; then
            case "$_evo_k" in
                secret) _EVT_DONE[$_EVT_NF]=1 ;;
                secret-file) _EVT_VAL[$_EVT_NF]="$_evo_pwfile"; _EVT_DONE[$_EVT_NF]=1 ;;
            esac
        fi
        [ "${#_evo_l}" -gt "$_EVT_LW" ] && _EVT_LW=${#_evo_l}
        _EVT_NF=$(( _EVT_NF + 1 ))
    done < "$_EVT_DIR/fields"
    [ "$_EVT_LW" -le 30 ] || _EVT_LW=30
    _evo_f=0
    while [ "$_evo_f" -lt "$_EVT_NF" ]; do
        _EVT_LAB[$_evo_f]="$(_exakit_vs_tui_short "${_EVT_LAB[$_evo_f]}" "$_EVT_LW")"
        _evo_f=$(( _evo_f + 1 ))
    done
    _EVT_VW=$(( _EVT_IN - 7 - _EVT_LW - 2 ))
    _evo_title="$_evo_pos of $_evo_total · $_evo_label"
    while :; do
        _EVT_ON_SCREEN=0
        _evo_f=0
        while [ "$_evo_f" -lt "$_EVT_NF" ]; do
            if [ -n "${_EVT_DONE[$_evo_f]}" ]; then _evo_f=$(( _evo_f + 1 )); continue; fi
            _exakit_vs_tui_draw "$_evo_title" "$_evo_f"
            _evo_k="${_EVT_KIND[$_evo_f]}"; _evo_def="${_EVT_VAL[$_evo_f]:-${_EVT_DEF[$_evo_f]}}"
            _evo_note=""
            case "$_evo_k" in
                choice) _evo_note="($(printf '%s' "${_EVT_CH[$_evo_f]}" | sed 's/ / · /g'))" ;;
                secret) _evo_note="(hidden)"; _evo_def="" ;;
                secret-file) _evo_note="(the path to the file)" ;;
            esac
            [ -n "$_evo_def" ] && _evo_note="${_evo_note:+$_evo_note }[$(_exakit_vs_tui_tail "$_evo_def" 32)]"
            _evo_plain="${_EVT_LAB[$_evo_f]}${_evo_note:+ $_evo_note}"
            if [ "$_evo_k" = secret ]; then
                _evo_deco="$UI_ASK${_EVT_LAB[$_evo_f]}$UI_RESET $UI_DIM$_evo_note$UI_RESET"
            else
                _evo_deco=$'\001'"$UI_ASK"$'\002'"${_EVT_LAB[$_evo_f]}"$'\001'"$UI_RESET"$'\002'
                [ -n "$_evo_note" ] && _evo_deco="$_evo_deco "$'\001'"$UI_DIM"$'\002'"$_evo_note"$'\001'"$UI_RESET"$'\002'
            fi
            while :; do
                if [ "$_evo_k" = secret ]; then
                    _exakit_vs_tui_ask "$_evo_plain" "$_evo_deco" 1 || return 5
                    if [ -z "$_EVT_ANSWER" ]; then
                        _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "this one is needed; it stays in memory and goes only to the database"
                        continue
                    fi
                    _EVT_VAL[$_evo_f]="$_EVT_ANSWER"; _EVT_ANSWER=""
                    break
                fi
                _exakit_vs_tui_ask "$_evo_plain" "$_evo_deco" 0 || return 5
                _evo_v="${_EVT_ANSWER:-$_evo_def}"
                case "$_evo_v" in "~/"*) _evo_v="$HOME/${_evo_v#\~/}" ;; esac
                if [ "$_evo_k" = secret-file ]; then
                    if [ -n "$_evo_v" ] && [ -f "$_evo_v" ] && [ -r "$_evo_v" ]; then _EVT_VAL[$_evo_f]="$_evo_v"; break; fi
                    _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "${_evo_v:-no file} cannot be read here; give the path to the key file"
                    continue
                fi
                # The engine's own rule for this input, in the words a scripted
                # connect would get; the value travels on its stdin, never in argv.
                printf '%s' "$_evo_v" | exakit_vs_engine field "$_evo_id" "${_EVT_NAME[$_evo_f]}" \
                    > "$_EVT_DIR/field" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
                if [ $? -eq 0 ]; then
                    _evo_v="$(_exakit_vs_result "$_EVT_DIR/field" | run_python_any -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
                    if [ "$_evo_k" = source-name ]; then
                        case " ${_EVT_TAKEN:-} " in *" $_evo_v "*)
                            _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$_evo_v is already the name of another source in this list"
                            continue ;;
                        esac
                    fi
                    _EVT_VAL[$_evo_f]="$_evo_v"
                    break
                fi
                _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$(sed -n 's/^FAIL //p' "$_EVT_DIR/field" | head -1)"
            done
            _EVT_DONE[$_evo_f]=1
            _evo_f=$(( _evo_f + 1 ))
        done
        _exakit_vs_tui_draw "$_evo_title" -1
        # The whole source, checked by the plan: what one field cannot see (a CA
        # with tls=require), and what will be downloaded.
        _exakit_vs_tui_engine "$(_exakit_vs_tui_args)" plan < /dev/null \
            > "$_EVT_DIR/plan.$_EVT_COUNT" 2>>"${EXAKIT_LOG_FILE:-/dev/null}" && break
        _exakit_vs_tui_say "$UI_ERR$UI_CROSS$UI_RESET" "$(sed -n 's/^FAIL //p' "$_EVT_DIR/plan.$_EVT_COUNT" | head -1)"
        _exakit_vs_tui_yes "Change the answers?" || return 5
        printf '\n'
        _evo_f=0
        while [ "$_evo_f" -lt "$_EVT_NF" ]; do _EVT_DONE[$_evo_f]=""; _evo_f=$(( _evo_f + 1 )); done
        _evo_pwfile=""
    done
    # Kept for the review and the run, one entry per source.
    _evo_name=""; _evo_secret=""; _evo_sfile=""; _evo_sets=""; _evo_where=""
    _evo_f=0
    while [ "$_evo_f" -lt "$_EVT_NF" ]; do
        _evo_v="${_EVT_VAL[$_evo_f]}"
        case "${_EVT_KIND[$_evo_f]}" in
            source-name) _evo_name="$_evo_v" ;;
            secret) _evo_secret="$_evo_v" ;;
            secret-file) _evo_sfile="$_evo_v" ;;
            *) [ -n "$_evo_v" ] && _evo_sets="$_evo_sets${_EVT_NAME[$_evo_f]}=$_evo_v"$'\n'
               case "${_EVT_NAME[$_evo_f]}" in
                   host|bucket|account|project|uri|region) [ -z "$_evo_where" ] && _evo_where="$_evo_v" ;;
               esac ;;
        esac
        _evo_f=$(( _evo_f + 1 ))
    done
    [ -z "$_evo_secret" ] && [ -z "$_evo_sfile" ] && [ -n "$_evo_pwfile" ] && _evo_sfile="$_evo_pwfile"
    _evo_where="${_evo_where#*://}"; _evo_where="${_evo_where%%/*}"
    # A host name shows its first label (exakit-vs-test-pg): what a reader recognises.
    case "$_evo_where" in *.*[a-zA-Z]*) _evo_where="${_evo_where%%.*}" ;; esac
    _EVT_S_ID[$_EVT_COUNT]="$_evo_id"; _EVT_S_NAME[$_EVT_COUNT]="$_evo_name"
    _EVT_S_LABEL[$_EVT_COUNT]="$_evo_label"; _EVT_S_SETS[$_EVT_COUNT]="$_evo_sets"
    _EVT_S_SECRET[$_EVT_COUNT]="$_evo_secret"; _EVT_S_SFILE[$_EVT_COUNT]="$_evo_sfile"
    _EVT_S_WHERE[$_EVT_COUNT]="$(_exakit_vs_tui_short "$_evo_where" 18)"
    _EVT_TAKEN="${_EVT_TAKEN:-} $_evo_name"
    _EVT_COUNT=$(( _EVT_COUNT + 1 ))
    printf '\n'
    return 0
}

# _exakit_vs_tui_table <state-file> <title> <indexes...> — a table of finished
# forms, every row waiting.
_exakit_vs_tui_table() {
    _ett_state="$1"; _ett_title="$2"; shift 2
    : > "$_ett_state"
    _ett_k=0
    for _ett_i in "$@"; do
        _ett_k=$(( _ett_k + 1 ))
        _ett_tree=tee; [ "$_ett_k" -eq "$#" ] && _ett_tree=corner
        printf '%s|%s|1|waiting|||||||%s|%s\n' "$_ett_tree" "${_EVT_S_NAME[$_ett_i]}" \
            "${_EVT_S_LABEL[$_ett_i]}" "${_EVT_S_WHERE[$_ett_i]}" >> "$_ett_state"
    done
    UI_TABLE_TITLE="$_ett_title"
    UI_TABLE_COL1="Name"; UI_TABLE_COL2="Source"; UI_TABLE_COL3="Where"
}

# _exakit_vs_tui_run <state-file> <indexes...> — connect those sources one after
# another while the table on screen follows. One at a time on purpose: parallel
# connects contend for the same database objects. Collects _EVT_OK, _EVT_FAILED,
# _EVT_NEEDS (sources waiting for a language container) and _EVT_RC.
_exakit_vs_tui_run() {
    _etr_state="$1"; shift
    _etr_row=0
    for _etr_i in "$@"; do
        _etr_row=$(( _etr_row + 1 ))
        _etr_out="$_EVT_DIR/run.$_etr_i"
        _etr_args="$(_exakit_vs_tui_source_args "$_etr_i")"
        _etr_t0="$(date +%s 2>/dev/null || echo 0)"
        _etr_try=0
        while :; do
            _etr_try=$(( _etr_try + 1 ))
            ui_table_set "$_etr_state" "$_etr_row" running 2 18 8 "starting"
            (
                ui_table_detach
                # --json: the events (OK/INFO/WARN/FAIL) on stderr move the bar,
                # and the answer on stdout carries the failure's kind.
                if [ -n "${_EVT_S_SECRET[$_etr_i]}" ]; then
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
            if [ "$_etr_rc" -eq 20 ] && [ "$_etr_try" -eq 1 ]; then
                ui_table_set "$_etr_state" "$_etr_row" running 30 60 20 "repairing DNS"
                personal_slc_dns_repair >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 && continue
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
             "clock": "the database clock is wrong"}
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
    _exakit_vs_tui_run "$_etl_state" "$@"
    if [ "$_etl_live" = 1 ]; then ui_table_end "$_etl_state"; else ui_table_render "$_etl_state" 0; fi
    run_python_any -c 'import sys, termios; termios.tcflush(sys.stdin.fileno(), termios.TCIFLUSH)' 2>/dev/null
    [ -n "$_etl_tty" ] && stty "$_etl_tty" 2>/dev/null
}

# _exakit_vs_tui <source-or-empty> <name-or-empty> <password-file-or-empty> — the
# whole terminal flow; returns cmd_connect's exit code.
_exakit_vs_tui() {
    _EVT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/exakit-connect.XXXXXX")" || { error "Could not create a temporary folder."; return 1; }
    _EVT_COLS="$(_ui_term_cols)"
    _EVT_W=$(( _EVT_COLS - 2 )); [ "$_EVT_W" -le 96 ] || _EVT_W=96
    _EVT_IN=$(( _EVT_W - 4 ))
    _EVT_SP=""; _EVT_HR=""; _evt_k=0
    while [ "$_evt_k" -lt 160 ]; do _EVT_SP="$_EVT_SP "; _EVT_HR="$_EVT_HR$UI_HR"; _evt_k=$(( _evt_k + 1 )); done
    _EVT_S_ID=(); _EVT_S_NAME=(); _EVT_S_LABEL=(); _EVT_S_SETS=(); _EVT_S_SECRET=(); _EVT_S_SFILE=(); _EVT_S_WHERE=()
    _EVT_COUNT=0; _EVT_TAKEN=""; _EVT_OK=""; _EVT_FAILED=""; _EVT_NEEDS=""; _EVT_RC=0
    _evt_name="$2"; _evt_pwfile="$3"

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
    [ "$_evt_total" -eq 1 ] || { _evt_name=""; _evt_pwfile=""; }
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

    # 3. review: what each plan downloads and who can read the result, above one
    # table of the sources and one question
    for _evt_i in $_evt_all; do
        _exakit_vs_result "$_EVT_DIR/plan.$_evt_i" | run_python_any -c 'import json, sys
p = json.load(sys.stdin)
new = [d for d in p["downloads"] if not d["cached"]]
if new:
    print("INFO %s downloads %s (%.0f MB)" % (p["name"], ", ".join("%s %s" % (d["role"], d["version"]) for d in new),
                                           sum(d["bytes"] for d in new) / 1e6))
for w in p["warnings"]:
    print("WARN %s: %s" % (p["name"], w))
if p.get("exposure"):
    print("INFO %s: %s" % (p["name"], p["exposure"][0].upper() + p["exposure"][1:]))' > "$_EVT_DIR/review" 2>/dev/null
        _exakit_vs_render "$_EVT_DIR/review"
    done
    _evt_state="$_EVT_DIR/sources"
    # shellcheck disable=SC2086 — indexes
    _exakit_vs_tui_table "$_evt_state" "Connect $_EVT_COUNT source$([ "$_EVT_COUNT" = 1 ] || printf s)" $_evt_all
    ui_table_render "$_evt_state" 0
    _evt_lines="$UI_TABLE_LINES"
    _EVT_ON_SCREEN=0
    if ! _exakit_vs_tui_yes "$(if [ "$_EVT_COUNT" = 1 ]; then printf 'Connect it now?'; else printf 'Connect all %s now?' "$_EVT_COUNT"; fi)"; then
        UI_TABLE_COL2=""; UI_TABLE_COL3=""
        info "Nothing was changed."; rm -rf "$_EVT_DIR"; return 5
    fi

    # 4. connect: the review table comes alive in place, over itself and the question
    # shellcheck disable=SC2086 — indexes
    _exakit_vs_tui_live "$_evt_state" $(( _evt_lines + _EVT_ON_SCREEN )) $_evt_all

    # A language container is a download and a restart: asked once, below the
    # table, and those sources then run again in a table of their own.
    for _evt_lang in java rust; do
        _evt_wait=""
        for _evt_n in ${_EVT_NEEDS:-}; do
            case "$_evt_n" in "$_evt_lang:"*) _evt_wait="$_evt_wait ${_evt_n#*:}" ;; esac
        done
        [ -n "$_evt_wait" ] || continue
        printf '\n'
        if [ "$_evt_lang" = java ]; then _exakit_vs_install_java; else _exakit_vs_install_rust; fi
        if [ $? -ne 0 ]; then
            _EVT_FAILED="${_EVT_FAILED:-}$_evt_wait"; [ "$_EVT_RC" -ne 0 ] || _EVT_RC=1
            continue
        fi
        printf '\n'
        # shellcheck disable=SC2086 — indexes
        _exakit_vs_tui_table "$_EVT_DIR/again.$_evt_lang" "Connect again" $_evt_wait
        # shellcheck disable=SC2086 — indexes
        _exakit_vs_tui_live "$_EVT_DIR/again.$_evt_lang" 0 $_evt_wait
    done
    UI_TABLE_COL2=""; UI_TABLE_COL3=""

    # What went wrong in the engine's own words, below the finished table.
    printf '\n'
    for _evt_i in ${_EVT_FAILED:-}; do
        warn "${_EVT_S_NAME[$_evt_i]} did not connect:"
        grep -v '^OK \|^RESULT ' "$_EVT_DIR/run.$_evt_i" > "$_EVT_DIR/why" 2>/dev/null
        _exakit_vs_render "$_EVT_DIR/why"
    done
    for _evt_i in ${_EVT_OK:-}; do
        _exakit_vs_query_hints "$(cat "$_EVT_DIR/run.$_evt_i.json" 2>/dev/null)" "${_EVT_S_NAME[$_evt_i]}"
    done
    [ -n "${_EVT_OK:-}" ] && info "Manage with: exakit source show <name> (every action: exakit help source)"
    # Nothing secret outlives the command in this shell.
    for _evt_i in $_evt_all; do _EVT_S_SECRET[$_evt_i]=""; done
    rm -rf "$_EVT_DIR"
    [ -z "${_EVT_FAILED:-}" ] || [ "$_EVT_RC" -ne 0 ] || _EVT_RC=1
    return "$_EVT_RC"
}

# cmd_connect [source] [--name N] [--set KEY=VALUE]... [--password-file F]
#             [--dry-run] [--yes] [--json]
cmd_connect() {
    _cc_source=""; _cc_name=""; _cc_pwfile=""; _cc_dry=0; _cc_json=0
    EXAKIT_VS_SETS=""; EXAKIT_VS_GIVEN=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name) _cc_name="${2:-}"; shift ;;
            --name=*) _cc_name="${1#--name=}" ;;
            --set) case "${2:-}" in *=*) ;; *) reject "--set takes KEY=VALUE (exakit help connect)" ;; esac
                   EXAKIT_VS_SETS="$EXAKIT_VS_SETS
--set
$2"; EXAKIT_VS_GIVEN="$EXAKIT_VS_GIVEN ${2%%=*}"; shift ;;
            --password-file) _cc_pwfile="${2:-}"; shift ;;
            --dry-run|-n) _cc_dry=1 ;;
            --yes|-y) EXAKIT_VS_ASSUME_YES=1 ;;
            --json|-j) _cc_json=1 ;;
            --password=*|--password|--secret*|--token*)
                reject "A credential is never taken as an argument (other users can read the process list). Use the hidden prompt, --password-file, or standard input." ;;
            -*) reject "Unknown option '$1' for connect (exakit help connect)." ;;
            *) [ -z "$_cc_source" ] || reject "connect takes one source; got '$_cc_source' and '$1'."; _cc_source="$1" ;;
        esac
        shift
    done
    _require_install "$_cc_json"
    exakit_init_logging
    # A person at a terminal gets the menu and the panels; a pipe, --yes,
    # --dry-run and --json keep the line-by-line path below, unchanged.
    if [ "$_cc_dry" = 0 ] && [ "$_cc_json" = 0 ] && _exakit_vs_tui_ok; then
        _exakit_vs_tui "$_cc_source" "$_cc_name" "$_cc_pwfile"
        exit $?
    fi
    _cc_tty="$(_exakit_prompt_tty)"
    if [ -z "$_cc_source" ]; then
        [ -n "$_cc_tty" ] || reject "Name the source to connect, e.g. exakit connect postgresql (see: exakit source catalog)."
        _cc_source="$(prompt_text "Which source? (name or alias, e.g. postgresql, mysql, mssql, oracle, snowflake, bigquery, databricks, mongodb, lakehouse, s3, azure)" "")"
    fi
    _cc_resolved="$(exakit_vs_engine resolve "$_cc_source" 2>/dev/null | sed -n 's/^RESULT {"connector": "\(.*\)"}$/\1/p')"
    if [ -z "$_cc_resolved" ]; then
        exakit_vs_engine resolve "$_cc_source" > "${TMPDIR:-/tmp}/exakit-vs-resolve.$$" 2>&1
        _cc_rc=$?
        _exakit_vs_render "${TMPDIR:-/tmp}/exakit-vs-resolve.$$"; rm -f "${TMPDIR:-/tmp}/exakit-vs-resolve.$$"
        [ "$_cc_rc" -ne 0 ] || _cc_rc=2
        exit "$_cc_rc"
    fi
    if [ -z "$_cc_name" ]; then
        [ -n "$_cc_tty" ] || reject "Give the connection a name with --name (lower case, e.g. sales)."
        _cc_name="$(prompt_text "Name for this connection (lower case, e.g. sales)" "")"
    fi
    [ -n "$_cc_tty" ] && _exakit_vs_ask_inputs "$_cc_resolved"
    # Build the engine's argument list from the newline-separated pairs; bash
    # 3.2 has no arrays worth trusting with this, so the positional
    # parameters carry it.
    set -- "$_cc_resolved" --name "$_cc_name"
    while IFS= read -r _cc_word; do
        [ -n "$_cc_word" ] && set -- "$@" "$_cc_word"
    done <<EOF
$EXAKIT_VS_SETS
EOF
    _cc_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || die "Could not create a temporary file."
    exakit_vs_engine plan "$@" < /dev/null > "$_cc_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    _cc_rc=$?
    _exakit_vs_render "$_cc_out"; rm -f "$_cc_out"
    [ "$_cc_rc" -eq 0 ] || exit "$_cc_rc"
    _exakit_vs_show_plan "$EXAKIT_VS_RESULT"
    if [ "$_cc_dry" = 1 ]; then
        [ "$_cc_json" = 1 ] && printf '%s\n' "$EXAKIT_VS_RESULT"
        exit 0
    fi
    if [ -n "$_cc_tty" ] && ! _exakit_vs_confirm "Connect now?"; then
        # 5, as every command a person did not confirm: 0 would read as "done".
        info "Nothing was changed."
        exit 5
    fi
    _cc_label="$(run_python_any -c 'import json,sys; c=json.load(open(sys.argv[1])); print(next((s.get("label","password") for s in c["inputs"] if s["kind"] in ("secret","secret-file")), ""))' \
        "$(exakit_vs_defs)/connectors/$_cc_resolved/connector.json" 2>/dev/null)"
    _cc_secret=""
    if [ -n "$_cc_label" ]; then
        _cc_secret="$(_exakit_vs_read_secret "$_cc_label" "$_cc_pwfile" "$(_exakit_vs_secret_kind "$_cc_resolved")")" || exit 2
        [ -n "$_cc_secret" ] || reject "No $(printf '%s' "$_cc_label" | tr 'A-Z' 'a-z') was given (pipe it on standard input or use --password-file)."
    fi
    if [ -n "$_cc_secret" ]; then
        _exakit_vs_run "$_cc_secret" connect "$@" --secret-stdin
    else
        _exakit_vs_run "" connect "$@"
    fi
    _cc_rc=$?
    unset _cc_secret
    if [ "$_cc_rc" -eq 0 ]; then
        _exakit_vs_query_hints "$EXAKIT_VS_RESULT" "$_cc_name"
        info "Manage it with: exakit source show $_cc_name | check | reauth | refresh | disconnect | remove"
    fi
    exit "$_cc_rc"
}

# _exakit_vs_query_hints <connect-result-json> <name> — a first query on one of
# the source's real tables, quoted as it must be, then how this kind of source
# names and types what it sends (the connector's tips).
_exakit_vs_query_hints() {
    _eqh_lines="$(printf '%s' "$1" | run_python_any -c 'import json, sys
r = json.load(sys.stdin)
print("OK Query it like any schema: " + r["example"])
for t in r.get("tips") or []:
    print("INFO " + t)' 2>/dev/null)"
    if [ -z "$_eqh_lines" ]; then
        ok "Query it like any schema: SELECT * FROM VS_$(printf '%s' "$2" | tr 'a-z' 'A-Z').<table> LIMIT 10"
        return 0
    fi
    printf '%s\n' "$_eqh_lines" > "${TMPDIR:-/tmp}/exakit-vs-hints.$$"
    _exakit_vs_render "${TMPDIR:-/tmp}/exakit-vs-hints.$$"
    rm -f "${TMPDIR:-/tmp}/exakit-vs-hints.$$"
}

# _exakit_vs_show_plan <plan-json> — what will happen, before it does.
_exakit_vs_show_plan() {
    [ -n "$1" ] || return 0
    printf '%s' "$1" | run_python_any -c 'import json, sys
p = json.load(sys.stdin)
print("  Plan for %s (%s, %s, %s)" % (p["name"], p["connector"], p["tier"], p["status"]))
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

# cmd_source <action> [name] [options] — the lifecycle of a connected source.
cmd_source() {
    _cs_action="${1:-list}"; [ "$#" -gt 0 ] && shift
    _cs_json=0; _cs_dry=0; _cs_name=""; _cs_all=0; _cs_status=""; _cs_pwfile=""; _cs_table=""; _cs_ddl=0; _cs_into=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json|-j) _cs_json=1 ;;
            --dry-run|-n) _cs_dry=1 ;;
            --yes|-y) EXAKIT_VS_ASSUME_YES=1 ;;
            --all|-a) _cs_all=1 ;;
            --status) _cs_status="${2:-}"; shift ;;
            --password-file) _cs_pwfile="${2:-}"; shift ;;
            --ddl) _cs_ddl=1 ;;
            --schema) _cs_into="${2:-}"; shift ;;
            --schema=*) _cs_into="${1#--schema=}" ;;
            -*) reject "Unknown option '$1' for source $_cs_action (exakit help source)." ;;
            *) if [ -z "$_cs_name" ]; then _cs_name="$1"
               elif [ "$_cs_action" = describe ] && [ -z "$_cs_table" ]; then _cs_table="$1"
               else reject "source $_cs_action takes one name."; fi ;;
        esac
        shift
    done
    _require_install "$_cs_json"
    exakit_init_logging
    case "$_cs_action" in
        list|issues|catalog|show|describe|check|reauth|refresh|disconnect|remove) ;;
        *) reject "Unknown source action '$_cs_action' (list, issues, show, describe, check, reauth, refresh, disconnect, remove, catalog)." ;;
    esac
    case "$_cs_action" in
        show|describe|reauth|refresh|disconnect|remove)
            [ -n "$_cs_name" ] || reject "exakit source $_cs_action needs a source name (see: exakit source list)." ;;
        check) [ -n "$_cs_name" ] || [ "$_cs_all" = 1 ] || reject "exakit source check needs a name or --all." ;;
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
            elif [ "$_cs_json" != 1 ]; then
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
            _cs_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || die "Could not create a temporary file."
            exakit_vs_engine "$@" show "$_cs_name" < /dev/null > "$_cs_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
            _cs_rc=$?
            if [ "$_cs_rc" -ne 0 ]; then
                if [ "$_cs_json" = 1 ]; then cat "$_cs_out"; else _exakit_vs_render "$_cs_out"; fi
                rm -f "$_cs_out"; exit "$_cs_rc"
            fi
            _cs_conn="$(sed -n 's/^RESULT .*"connector": "\([a-z0-9-]*\)".*/\1/p' "$_cs_out" | head -n 1)"
            rm -f "$_cs_out"
            _cs_secret="$(_exakit_vs_read_secret "New credential for $_cs_name" "$_cs_pwfile" "$(_exakit_vs_secret_kind "$_cs_conn")")" || exit 2
            [ -n "$_cs_secret" ] || reject "No credential was given."
            set -- "$@" reauth "$_cs_name" --secret-stdin
            if [ "$_cs_json" = 1 ]; then printf '%s' "$_cs_secret" | exakit_vs_engine "$@"; exit $?; fi
            _exakit_vs_run "$_cs_secret" "$@"; _cs_rc=$?; unset _cs_secret
            [ "$_cs_rc" -eq 0 ] && ok "$_cs_name is ready again with the new credential"
            exit "$_cs_rc" ;;
    esac
    if [ "$_cs_json" = 1 ]; then
        exakit_vs_engine "$@" < /dev/null 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        exit $?
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
        exit "$_cs_rc"
    fi
    [ -n "$EXAKIT_VS_RESULT" ] && printf '%s' "$EXAKIT_VS_RESULT" | run_python_any -c 'import json, sys
r = json.load(sys.stdin)
rows = r["sources"] if "sources" in r else r.get("issues")
if rows is not None:
    if not rows:
        print("  (none)")
    for s in rows:
        last = (s.get("last_check") or {})
        print("  %-16s %-11s %-14s %-14s %s" % (s["name"], s["connector"], s["schema"], s["status"],
              (last.get("at") or "never checked") + ((" - " + s["remedy"]) if s.get("remedy") else "")))
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
        print("  %-11s %s" % ("tips" if i == 0 else "", t))' 2>/dev/null
    exit "$_cs_rc"
}
