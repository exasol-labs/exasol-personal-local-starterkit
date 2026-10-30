#!/usr/bin/env bash
# describe-command.sh — `exakit describe <table> [--sample N] [--id <slug>]
# [--json] [--write <path>]` and the approve half (`<id|draft.yaml> --approve
# [--role r=COL]... [--owner x] [--no-comments]`, `<id> --show [--version n]`,
# `--versions`, `--comments`) in setup/lib/describe.sh (the service it runs is
# tested in tests/test_describe_service.py).
#
#   bash tests/describe-command.sh
#
# What it pins:
#   - bad arguments are refused with exit 2 before anything runs, as prose
#     or, with --json, as one refusal object; the approve half's options are
#     checked for shape and for the mode they belong to
#   - without the notebook add-on the command says so, names
#     `exakit marketplace notebook`, and exits 1
#   - a missing notebook environment names `exakit notebook setup`
#   - the service runs in the kit's notebook Python with the manifest's
#     connection settings (the password file's path, never the password) and
#     exactly the arguments given, for every mode; its exit code is the
#     command's (2 bad roles, 3 unknown id, 5 a version conflict)
#   - the real service, run with no connection settings, is exit 4
#   - the CLI dispatches the command and the help document describes it
#
# A sandboxed kit home; no database, no network, no real venv: the venv's
# Python is this machine's python3, and the kit copy is a sandbox whose
# describe_service.py is test_data/describe/stub_service.py.

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
unset EXAKIT_NOTEBOOK_VENV EXAKIT_REFUSAL_JSON EXAKIT_PYX_DSN EXAKIT_PYX_USER EXAKIT_PYX_PWFILE STUB_EXIT
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$WORK/root/setup/lib"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/help.sh"; . "$ROOT/setup/lib/describe.sh"
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
manifest_init >/dev/null 2>&1

# The venv's Python, stubbed: this machine's python3. The kit copy, stubbed: a
# sandbox whose service records what it was asked.
PY3="$(command -v python3)"
cp "$ROOT/test_data/describe/stub_service.py" "$WORK/root/setup/lib/describe_service.py"
manifest_set components.notebook.python "$PY3"
exakit_repo_root() { printf '%s\n' "$WORK/root"; }
# The help renderer reads the installed kit's documents, which this sandbox has
# none of; what matters here is that --help asks for the command's page.
exakit_help_render() { printf 'help page: %s %s\n' "$1" "$2"; }

# run <args> — the command in a subshell (reject and die exit); stdout+stderr
# in OUT, the exit code in CODE.
run() {
    OUT="$( (cmd_describe "$@") 2>&1 )"; CODE=$?
}
# asked <key> — one field of the stub's answer in OUT.
asked() {
    printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d[sys.argv[1]]; print(" ".join(v) if isinstance(v, list) else v)' "$1"
}

echo "bad arguments are refused with exit 2 before anything runs:"
run;                               check "no table" "2" "$CODE"; contains "names the shape" "exakit describe SCHEMA.TABLE" "$OUT"
run READINGS;                      check "a bare name" "2" "$CODE"; contains "asks for SCHEMA.TABLE" "SCHEMA.TABLE" "$OUT"
run A.B.C;                         check "three parts" "2" "$CODE"
run 'LAB.1X';                      check "a part that starts with a digit" "2" "$CODE"
run LAB.READINGS LAB.OTHER;        check "two tables" "2" "$CODE"; contains "says one" "Name one table" "$OUT"
run LAB.READINGS --bogus;          check "an unknown option" "2" "$CODE"; contains "names the option" "Unknown option '--bogus'" "$OUT"
run LAB.READINGS --sample;         check "--sample without a value" "2" "$CODE"; contains "says so" "--sample needs a value" "$OUT"
run LAB.READINGS --sample --json;  check "--sample followed by an option" "2" "$CODE"
run LAB.READINGS --sample x;       check "--sample with a word" "2" "$CODE"; contains "says positive integer" "positive integer" "$OUT"
run LAB.READINGS --sample 0;       check "--sample 0" "2" "$CODE"
run LAB.READINGS --sample 5 --sample 6; check "--sample twice" "2" "$CODE"
run LAB.READINGS --id 'Bad Id';    check "--id that is no dataset id" "2" "$CODE"; contains "says the shape" "lower-case letters and digits" "$OUT"
run LAB.READINGS --write;          check "--write without a path" "2" "$CODE"
run LAB.READINGS --approve;        check "--approve on a table name (no id, no file)" "2" "$CODE"; contains "says what it takes" "--approve takes a dataset id" "$OUT"
run LAB.READINGS --versions;       check "--versions on a table name" "2" "$CODE"
run readings --approve --show;     check "two modes" "2" "$CODE"; contains "names both" "--approve and --show are two different things" "$OUT"
run readings --approve --role;     check "--role without a value" "2" "$CODE"
run readings --approve --role owner=X; check "--role with no such role" "2" "$CODE"; contains "names the roles" "one of entity, category, date, label, text" "$OUT"
run readings --approve --role entity=1x; check "--role with a column that is no plain name" "2" "$CODE"
run readings --approve --role 'entity=A B'; check "--role with a space" "2" "$CODE"
run readings --approve --owner;    check "--owner without a value" "2" "$CODE"
run readings --approve --owner a --owner b; check "--owner twice" "2" "$CODE"
run readings --approve --id x;     check "--id does not go with --approve" "2" "$CODE"; contains "says so" "do not go with --approve" "$OUT"
run readings --approve --version 2; check "nor --version" "2" "$CODE"
run --approve;                     check "--approve without a target" "2" "$CODE"; contains "asks for the draft" "Name the draft to approve" "$OUT"
run Bad.Id --approve;              check "--approve with neither an id nor a file" "2" "$CODE"
run LAB.READINGS --role entity=ID; check "--role without --approve" "2" "$CODE"; contains "says where it goes" "go with --approve" "$OUT"
run LAB.READINGS --no-comments;    check "--no-comments without --approve" "2" "$CODE"
run readings --show --version x;   check "--show --version with a word" "2" "$CODE"; contains "says positive integer" "positive integer" "$OUT"
run readings --show --version 0;   check "--show --version 0" "2" "$CODE"
run readings --show --role entity=ID; check "--show with --role" "2" "$CODE"; contains "says what --show takes" "--show takes a dataset id and --version n and --json" "$OUT"
run readings --versions --version 2; check "--versions with --version" "2" "$CODE"; contains "says --version goes with --show" "--version goes with --show" "$OUT"
run readings --comments --sample 5; check "--comments with --sample" "2" "$CODE"
run --versions;                    check "--versions without an id" "2" "$CODE"; contains "asks for the id" "Name the dataset id" "$OUT"
run Readings --versions;           check "--versions with an upper-case id" "2" "$CODE"; contains "says the shape" "lower-case letters and digits" "$OUT"
OUT="$( (cmd_describe LAB.READINGS --json --bogus) 2>/dev/null )"; CODE=$?
check "with --json the refusal is one object" "2" "$CODE"
check "and it says rejected" "yes" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d.get("rejected") and d.get("ok") is False else "no")')"

echo "without the notebook add-on the command says so:"
run LAB.READINGS;                  check "exit 1" "1" "$CODE"; contains "names the install command" "exakit marketplace notebook" "$OUT"

echo "a missing notebook environment names the repair:"
manifest_set components.notebook.version 3.1.0
manifest_set components.notebook.python "$WORK/nowhere/python"
run LAB.READINGS;                  check "exit 1" "1" "$CODE"; contains "names exakit notebook setup" "exakit notebook setup" "$OUT"
manifest_set components.notebook.python "$PY3"

echo "the service runs with the manifest's connection settings and the arguments given:"
manifest_set runtime.dsn 127.0.0.1:8563
manifest_set runtime.user sys
manifest_set runtime.password_file "$EXAKIT_HOME/credentials/personal_sys_password"
run LAB.READINGS;                  check "exit 0" "0" "$CODE"
check "draft, the table" "draft LAB.READINGS" "$(asked args)"
check "the dsn" "127.0.0.1:8563" "$(asked dsn)"; check "the user" "sys" "$(asked user)"
check "the password file's path, not its content" "$EXAKIT_HOME/credentials/personal_sys_password" "$(asked pwfile)"
run lab.readings --sample 500 --id lab-readings --json --write "$WORK/out.yaml"
check "every option passes through, in the service's order" "draft lab.readings --sample 500 --id lab-readings --json --write $WORK/out.yaml" "$(asked args)"
run LAB.READINGS -j;               check "-j is --json" "draft LAB.READINGS --json" "$(asked args)"
run '"my schema"."order data"';    check "a quoted table passes through as typed" 'draft "my schema"."order data"' "$(asked args)"
STUB_EXIT=3 run LAB.NOPE;          check "the service's exit code is the command's (3: no such table)" "3" "$CODE"
STUB_EXIT=4 run LAB.READINGS;      check "and 4: database unreachable" "4" "$CODE"
echo "the approve half passes through the same way:"
run readings --approve;            check "approve, the id" "approve readings" "$(asked args)"
run readings --approve --role entity=ID --role text=A,B --owner lee --no-comments --json --sample 500
check "every approve option, in the service's order" "approve readings --sample 500 --owner lee --no-comments --json --role entity=ID --role text=A,B" "$(asked args)"
printf 'schema_version: 2\n' > "$WORK/draft.yaml"
run "$WORK/draft.yaml" --approve;  check "a draft file by its path" "approve $WORK/draft.yaml" "$(asked args)"
run readings --show;               check "show" "show readings" "$(asked args)"
run readings --show --version 2 --json; check "show with a version and --json" "show readings --version 2 --json" "$(asked args)"
run readings --show --show;        check "the same mode twice is one mode" "show readings" "$(asked args)"
run readings --versions;           check "versions" "versions readings" "$(asked args)"
run readings --comments -j;        check "comments" "comments readings --json" "$(asked args)"
check "the dsn reaches the approve half too" "127.0.0.1:8563" "$(asked dsn)"
STUB_EXIT=2 run readings --approve --role entity=NOPE; check "the service's 2 (a bad role) is the command's" "2" "$CODE"
STUB_EXIT=3 run nowhere --versions; check "3: no such id" "3" "$CODE"
STUB_EXIT=5 run readings --approve; check "5: a version conflict" "5" "$CODE"
run --help;                        check "--help renders the page" "0" "$CODE"; contains "the command's own" "help page: command describe" "$OUT"
run LAB.READINGS --help;           check "so does <table> --help" "0" "$CODE"; contains "the same page" "help page: command describe" "$OUT"

echo "the real service, with no connection settings, is exit 4:"
exakit_repo_root() { printf '%s\n' "$ROOT"; }
manifest_set runtime.dsn ""
manifest_set runtime.password_file ""
run LAB.READINGS;                  check "exit 4" "4" "$CODE"; contains "names exakit status" "exakit status" "$OUT"
exakit_repo_root() { printf '%s\n' "$WORK/root"; }

echo "the CLI dispatches the command and the help document describes it:"
contains "setup/exakit has the arm" 'cmd_describe "$@"' "$(grep 'describe) shift' "$ROOT/setup/exakit")"
contains "and sources the module" 'describe.sh" ] && . "$_lib_dir/describe.sh"' "$(cat "$ROOT/setup/exakit")"
contains "and its header names the command" 'describe <table>' "$(sed -n '1,90p' "$ROOT/setup/exakit")"
check "the help document has the command" "describe" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(c["command"] for c in d["commands"] if c["command"]=="describe"))' "$ROOT/setup/help/exakit.json")"
check "in the add-ons group" "yes" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("yes" if any("describe" in g["commands"] for g in d["groups"] if g["title"]=="Add-ons") else "no")' "$ROOT/setup/help/exakit.json")"
_cd_page="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=[c for c in d["commands"] if c["command"]=="describe"][0]; print(c["options"]); print(c["description"]); print("\n".join(c["examples"]))' "$ROOT/setup/help/exakit.json")"
contains "and its page names the add-on" "exakit marketplace notebook" "$_cd_page"
for _opt in --approve --role --owner --no-comments --show --version --versions --comments; do
    contains "the options list $_opt" "$_opt" "$(printf '%s' "$_cd_page" | sed -n 1p)"
done
contains "the page says what approve writes" "descriptors/<id>/v<n>.yaml" "$_cd_page"
contains "and the comment it writes" "role: <role> (starter kit, descriptor <id> v<n>)" "$_cd_page"
contains "and the view for a virtual table" "STARTER_KIT.<ID>_DESCRIBED" "$_cd_page"
contains "and exit 5" "5 when another approve" "$_cd_page"
contains "with an approve example" "exakit describe orders --approve" "$_cd_page"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
