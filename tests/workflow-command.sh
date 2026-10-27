#!/usr/bin/env bash
# workflow-command.sh — `exakit workflow list|show <id> [--json]` in
# setup/lib/workflow.sh (the module it runs is tested in tests/test_workflow.py).
#
#   bash tests/workflow-command.sh
#
# What it pins:
#   - bad arguments are refused with exit 2 before anything is read, as prose
#     or, with --json, as one refusal object
#   - without the notebook add-on the command says so, names
#     `exakit marketplace notebook`, and exits 1
#   - a missing notebook environment names `exakit notebook setup`
#   - list and show read the logs under $EXAKIT_HOME/workflows through the
#     kit's notebook Python, as a table or as JSON; a workflow that is not there
#     is exit 1
#   - the CLI dispatches the command and the help document describes it
#
# A sandboxed kit home; no database, no network, no real venv: the venv's
# Python is a stub that runs this machine's python3 on the kit's package.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
unset EXAKIT_NOTEBOOK_VENV EXAKIT_WORKFLOW_ID EXAKIT_REFUSAL_JSON
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/help.sh"; . "$ROOT/setup/lib/notebook.sh"; . "$ROOT/setup/lib/workflow.sh"
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
manifest_init >/dev/null 2>&1

# The venv's Python, stubbed: this machine's python3 with the kit's package on
# its path, which is what the installed module amounts to.
STUB="$WORK/python"
cat > "$STUB" <<STUBEOF
#!/bin/sh
PYTHONPATH="$ROOT/notebook/package" exec python3 "\$@"
STUBEOF
chmod +x "$STUB"
notebook_venv_python() { printf '%s\n' "$STUB"; }
# The help renderer reads the installed kit's documents, which this sandbox has
# none of; what matters here is that --help asks for the command's page.
exakit_help_render() { printf 'help page: %s %s\n' "$1" "$2"; }

# run <args> — the command in a subshell (reject and die exit); stdout+stderr
# in OUT, the exit code in CODE.
run() {
    OUT="$( (cmd_workflow "$@") 2>&1 )"; CODE=$?
}

echo "bad arguments are refused with exit 2 before anything is read:"
run;                     check "no word" "2" "$CODE"; contains "names the forms" "exakit workflow list | exakit workflow show <id>" "$OUT"
run frobnicate;          check "an unknown word" "2" "$CODE"; contains "names the words" "supported: list, show" "$OUT"
run list --bogus;        check "an unknown option" "2" "$CODE"; contains "names the option" "Unknown option '--bogus'" "$OUT"
run list extra;          check "list with an argument" "2" "$CODE"
run show;                check "show without an id" "2" "$CODE"; contains "says where the ids are" "exakit workflow list" "$OUT"
run show nope;           check "show with a word that is no id" "2" "$CODE"; contains "says the shape" "wf-YYYYMMDD-xxxxxx" "$OUT"
run show ../x;           check "a path is no id" "2" "$CODE"
run show wf-20261027-3f9a1c wf-20261027-3f9a1d; check "two ids" "2" "$CODE"
check "nothing was written for a refusal" "" "$(find "$EXAKIT_HOME/workflows" -name 'wf-*.jsonl' 2>/dev/null)"
OUT="$( (EXAKIT_REFUSAL_JSON=1 cmd_workflow frobnicate) 2>/dev/null )"; CODE=$?
check "with --json the refusal is one object" "2" "$CODE"
check "and it says rejected" "yes" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d.get("rejected") and d.get("ok") is False else "no")')"

echo "without the notebook add-on the command says so:"
run list;                check "exit 1" "1" "$CODE"; contains "names the install command" "exakit marketplace notebook" "$OUT"
run show wf-20261027-3f9a1c; check "show too" "1" "$CODE"

echo "a missing notebook environment names the repair:"
manifest_set components.notebook.version 3.1.0
notebook_venv_python() { printf '%s\n' "$WORK/nowhere/python"; }
run list;                check "exit 1" "1" "$CODE"; contains "names exakit notebook setup" "exakit notebook setup" "$OUT"
notebook_venv_python() { printf '%s\n' "$STUB"; }

echo "list and show read the logs through the kit's notebook Python:"
run list;                check "no workflows yet is still exit 0" "0" "$CODE"; contains "and says so" "No workflows yet" "$OUT"
WF="$("$STUB" -c 'import exakit_nb.workflow as w; wid = w.workflow("demo"); w.log_event(w.SQL, sql="SELECT 1", rows=1)' | sed 's/^Workflow \([^:]*\):.*/\1/')"
contains "the helper started a workflow" "wf-" "$WF"
check "its log is under the kit home" "yes" "$([ -f "$EXAKIT_HOME/workflows/$WF.jsonl" ] && echo yes || echo no)"
run list;                check "list" "0" "$CODE"; contains "has the id" "$WF" "$OUT"; contains "and the name" "demo" "$OUT"
run list --json;         check "list --json" "0" "$CODE"
check "is a list with the workflow" "$WF|demo|2" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]; print("|".join(str(r[k]) for k in ("id","name","events")))')"
run list -j;             check "-j is --json" "0" "$CODE"; contains "and answers JSON" '"id": "'"$WF"'"' "$OUT"
run show "$WF";          check "show" "0" "$CODE"; contains "has the start line" "start" "$OUT"; contains "and the statement" "sql=SELECT 1" "$OUT"
run show "$WF" --json;   check "show --json" "0" "$CODE"
check "is the lines in order" "start,sql" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(e["kind"] for e in json.load(sys.stdin)))')"
run show wf-20200101-abcdef; check "a workflow that is not there is exit 1" "1" "$CODE"; contains "naming it" "wf-20200101-abcdef" "$OUT"
run --help;              check "--help renders the page" "0" "$CODE"; contains "the command's own" "help page: command workflow" "$OUT"
run show --help;         check "so does show --help" "0" "$CODE"; contains "the same page" "help page: command workflow" "$OUT"

echo "the CLI dispatches the command and the help document describes it:"
contains "setup/exakit has the arm" 'cmd_workflow "$@"' "$(grep 'workflow) shift' "$ROOT/setup/exakit")"
contains "and sources the module" 'workflow.sh" ] && . "$_lib_dir/workflow.sh"' "$(cat "$ROOT/setup/exakit")"
check "the help document has the command" "workflow" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(c["command"] for c in d["commands"] if c["command"]=="workflow"))' "$ROOT/setup/help/exakit.json")"
check "in the add-ons group" "yes" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("yes" if any("workflow" in g["commands"] for g in d["groups"] if g["title"]=="Add-ons") else "no")' "$ROOT/setup/help/exakit.json")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
