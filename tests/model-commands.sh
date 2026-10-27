#!/usr/bin/env bash
# model-commands.sh — `exakit model put | list | template` (ML-4) in
# setup/lib/udf-devkit.sh and its dispatcher arm in setup/exakit.
#
#   bash tests/model-commands.sh
#
# What it pins (AC-ML4.3 and the offline half of AC-ML4.1):
#   - put copies the file into the deployment's bucket directory under models/,
#     records its sha256, size and time, and prints the /buckets path
#   - --json is one object: name, path, sha256, size, replaced
#   - the same file again is a no-op; a DIFFERENT file of the same name is
#     refused with exit 5 and nothing copied, unless --replace is given
#   - list --json has the shape the quickstart notebook reads, is empty before
#     anything is put, and flags a file changed since it was put
#   - exit codes: 2 bad input, 3 no deployment, 4 add-on not installed
#   - no credential is read, printed or recorded
#   - model --help and model put --help render the add-on's pages
# Whether a UDF really reads the file at the printed path needs a database:
# tests/model-live-check.sh (EXAKIT_LIVE_TESTS=1).
#
# A sandboxed home, kit home and deployment folder; no database, no launcher.

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
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: must not contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
    esac
}
jq_py() { # jq_py <python expression on d> — read JSON on stdin
    python3 -c 'import json, sys
d = json.load(sys.stdin)
print(eval(sys.argv[1]))' "$1"
}

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
export EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/deployment"
export EXAKIT_HELP_PLAIN=1 EXAKIT_NO_UPDATE_CHECK=1
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$EXAKIT_PERSONAL_DEPLOY_DIR/local/runtime/exa"
BUCKET="$EXAKIT_PERSONAL_DEPLOY_DIR/local/runtime/exa/bucketfs/bfsdefault/default"
SECRET="not-a-real-password-7731"
mkdir -p "$EXAKIT_HOME/credentials"
printf '%s\n' "$SECRET" > "$EXAKIT_HOME/credentials/db-password"

# The kit's record: installed, with a runtime whose password file the model
# commands must never read.
(
    # shellcheck disable=SC1091
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
    run_python_any() { python3 "$@"; }
    manifest_init >/dev/null 2>&1
    manifest_set runtime.dsn "127.0.0.1:8563"
    manifest_set runtime.password_file "$EXAKIT_HOME/credentials/db-password"
    manifest_set components.udf_devkit.version 0.1.0
)

CLI="$ROOT/setup/exakit"
cli() { /bin/bash "$CLI" "$@"; }
record() { python3 -c 'import json, sys
print(json.dumps(json.load(open(sys.argv[1])).get("components", {}).get("udf_devkit", {}).get("models")))' "$EXAKIT_HOME/manifest.json"; }

printf 'weights-v1' > "$WORK/churn.pkl"
mkdir -p "$WORK/v2"; printf 'weights-v2-longer' > "$WORK/v2/churn.pkl"

echo "list works before anything is put:"
out="$(cli model list --json 2>&1)"; rc=$?
check "exit 0" "0" "$rc"
check "the keys the quickstart notebook reads" "['bucket_dir', 'missing', 'models', 'udf_root']" "$(printf '%s' "$out" | jq_py 'sorted(d)')"
check "an empty models list" "[]" "$(printf '%s' "$out" | jq_py 'd["models"]')"
check "the UDF root" "/buckets/bfsdefault/default" "$(printf '%s' "$out" | jq_py 'd["udf_root"]')"
check "the bucket directory on this machine" "$BUCKET" "$(printf '%s' "$out" | jq_py 'd["bucket_dir"]')"

echo "put copies, records and prints the /buckets path:"
out="$(cli model put "$WORK/churn.pkl" 2>&1)"; rc=$?
check "exit 0" "0" "$rc"
check "the file is in the bucket under models/" "weights-v1" "$(cat "$BUCKET/models/churn.pkl" 2>/dev/null)"
contains "the UDF path is printed" "/buckets/bfsdefault/default/models/churn.pkl" "$out"
SHA1="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$WORK/churn.pkl")"
check "the digest is recorded" "$SHA1" "$(record | jq_py 'd["churn.pkl"]["sha256"]')"
check "with the size, path, provenance and time" "['path', 'provenance', 'put_at', 'sha256', 'size']" "$(record | jq_py 'sorted(d["churn.pkl"])')"
check "no copy in progress left behind" "" "$(ls "$BUCKET/models" | grep '\.part$' || true)"

echo "the same file again changes nothing:"
put_at="$(record | jq_py 'd["churn.pkl"]["put_at"]')"
out="$(cli model put "$WORK/churn.pkl" --json 2>&1)"; rc=$?
check "exit 0" "0" "$rc"
check "--json includes origin status" "['name', 'path', 'replaced', 'sha256', 'size', 'trusted_origin', 'warning']" "$(printf '%s' "$out" | jq_py 'sorted(d)')"
check "not replaced" "False" "$(printf '%s' "$out" | jq_py 'd["replaced"]')"
check "the record keeps its time" "$put_at" "$(record | jq_py 'd["churn.pkl"]["put_at"]')"

echo "a different file of the same name is refused without --replace:"
out="$(cli model put "$WORK/v2/churn.pkl" 2>&1)"; rc=$?
check "exit 5 (not confirmed)" "5" "$rc"
contains "the refusal names --replace" "--replace" "$out"
check "nothing was copied" "weights-v1" "$(cat "$BUCKET/models/churn.pkl")"
check "the record is unchanged" "$SHA1" "$(record | jq_py 'd["churn.pkl"]["sha256"]')"
out="$(cli model put "$WORK/v2/churn.pkl" --json 2>/dev/null)"; rc=$?
check "with --json: exit 5 too" "5" "$rc"
check "and one refusal object on stdout" "False" "$(printf '%s' "$out" | jq_py 'd["ok"]')"
contains "whose remedy is the --replace command" "--replace" "$(printf '%s' "$out" | jq_py 'd["remedy"]')"

echo "--replace overwrites it and says so:"
out="$(cli model put "$WORK/v2/churn.pkl" --replace --json 2>&1)"; rc=$?
check "exit 0" "0" "$rc"
check "replaced" "True" "$(printf '%s' "$out" | jq_py 'd["replaced"]')"
check "the new content is there" "weights-v2-longer" "$(cat "$BUCKET/models/churn.pkl")"
check "the record follows" "$(printf '%s' "$out" | jq_py 'd["sha256"]')" "$(record | jq_py 'd["churn.pkl"]["sha256"]')"
check "and the size" "17" "$(printf '%s' "$out" | jq_py 'd["size"]')"

echo "list flags a file changed since it was put:"
printf 'tampered' > "$BUCKET/models/churn.pkl"
printf 'csv' > "$WORK/lookup.csv"
mkdir -p "$BUCKET/models"; cp "$WORK/lookup.csv" "$BUCKET/models/lookup.csv"
out="$(cli model list --json 2>&1)"; rc=$?
check "exit 0" "0" "$rc"
check "each model has name, path, sha256, size" "True" "$(printf '%s' "$out" | jq_py 'all({"name", "path", "sha256", "size"} <= set(m) for m in d["models"])')"
check "the tampered file is flagged" "changed" "$(printf '%s' "$out" | jq_py '[m["status"] for m in d["models"] if m["name"] == "churn.pkl"][0]')"
check "a file copied another way is unrecorded" "unrecorded" "$(printf '%s' "$out" | jq_py '[m["status"] for m in d["models"] if m["name"] == "lookup.csv"][0]')"
check "its path is the /buckets path" "/buckets/bfsdefault/default/models/lookup.csv" "$(printf '%s' "$out" | jq_py '[m["path"] for m in d["models"] if m["name"] == "lookup.csv"][0]')"
out="$(cli model list 2>&1)"
contains "the screen says CHANGED" "CHANGED since it was put" "$out"
rm -f "$BUCKET/models/churn.pkl"
check "a recorded file that is gone is named missing" "['churn.pkl']" "$(cli model list --json 2>/dev/null | jq_py 'd["missing"]')"

echo "bad input exits 2 and copies nothing:"
cli model put >/dev/null 2>&1; check "no file" "2" "$?"
cli model put "$WORK/nope.pkl" >/dev/null 2>&1; check "not a file" "2" "$?"
cli model put "$WORK/churn.pkl" --force >/dev/null 2>&1; check "an unknown option" "2" "$?"
printf 'x' > "$WORK/my model.pkl"
out="$(cli model put "$WORK/my model.pkl" 2>&1)"; rc=$?
check "a name the bucket path cannot hold" "2" "$rc"
contains "with the reason" "cannot be a model name" "$out"
cli model frob >/dev/null 2>&1; check "an unknown model command" "2" "$?"
cli model >/dev/null 2>&1; check "no model command" "2" "$?"
cli model list --frob >/dev/null 2>&1; check "list refuses an unknown option" "2" "$?"

echo "no deployment is exit 3, no add-on exit 4:"
out="$(EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/none" cli model list --json 2>/dev/null)"; rc=$?
check "no deployment: exit 3" "3" "$rc"
contains "naming the folder it looked for" "no BucketFS folder" "$(printf '%s' "$out" | jq_py 'd["error"]')"
(
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
    run_python_any() { python3 "$@"; }
    manifest_del components.udf_devkit.version
)
out="$(cli model put "$WORK/churn.pkl" 2>&1)"; rc=$?
check "not installed: exit 4" "4" "$rc"
contains "naming the marketplace" "exakit marketplace udf-devkit" "$out"
check "nothing written by a refused put" "lookup.csv" "$(ls "$BUCKET/models")"
(
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
    run_python_any() { python3 "$@"; }
    manifest_set components.udf_devkit.version 0.1.0
)

echo "no credential is read, printed or recorded:"
all="$(cli model put "$WORK/churn.pkl" --replace 2>&1; cli model put "$WORK/churn.pkl" --json 2>&1; cli model list 2>&1; cli model list --json 2>&1; cli model put "$WORK/v2/churn.pkl" 2>&1)"
lacks "the password is never printed" "$SECRET" "$all"
lacks "nor the password file's path" "db-password" "$all"
lacks "nor the record" "$SECRET" "$(record)"
lacks "the record holds no password file" "password" "$(record)"
lacks "no failure note from a refusal" "exakit model" "$(cat "$EXAKIT_HOME/.last-failure" 2>/dev/null)"

echo "the template and the help pages:"
out="$(cli model template --json 2>&1)"; rc=$?
check "template --json: exit 0" "0" "$rc"
check "names the renderer, which exists" "True" "$(printf '%s' "$out" | python3 -c 'import json, os, sys; print(os.path.isfile(json.load(sys.stdin)["renderer"]))')"
check "and every placeholder" "LANGUAGE SCHEMA SCRIPT_NAME INPUT_COLUMNS OUTPUT_TYPE MODEL_PATH INPUTS METHOD" "$(printf '%s' "$out" | jq_py '" ".join(d["placeholders"])')"
contains "template (screen) shows how to render" "render.py" "$(cli model template 2>&1)"
out="$(cli model --help 2>&1)"; rc=$?
check "model --help: exit 0" "0" "$rc"
contains "shows put" "exakit model put" "$out"
contains "and list" "exakit model list" "$out"
contains "and template" "exakit model template" "$out"
out="$(cli model put --help 2>&1)"
contains "model put --help shows put" "--replace" "$out"
lacks "and only put" "exakit model list" "$out"
contains "the catalog lists the commands" "model put" "$(cli catalog model 2>&1)"

echo "rm removes a recorded model:"
printf 'disposable' > "$WORK/disposable.pkl"
cli model put "$WORK/disposable.pkl" --json >/dev/null
out="$(cli model rm disposable.pkl --json)"; rc=$?
check "rm exit 0" "0" "$rc"
check "rm JSON names the file" "disposable.pkl" "$(printf '%s' "$out" | jq_py 'd["name"]')"
check "rm deletes the file" "no" "$([ -e "$BUCKET/models/disposable.pkl" ] && printf yes || printf no)"
check "rm deletes its record" "False" "$(record | jq_py '"disposable.pkl" in d')"

echo "prune previews before removing an old model:"
printf 'old' > "$WORK/old.pkl"
cli model put "$WORK/old.pkl" --json >/dev/null
python3 - "$EXAKIT_HOME/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
d["components"]["udf_devkit"]["models"]["old.pkl"]["put_at"]="2020-01-01T00:00:00Z"
with open(p,"w") as f: json.dump(d,f)
PY
out="$(cli model prune --json)"; rc=$?
check "prune dry run exit 0" "0" "$rc"
check "prune previews old model" "['old.pkl']" "$(printf '%s' "$out" | jq_py 'd["candidates"]')"
check "prune dry run keeps file" "yes" "$([ -f "$BUCKET/models/old.pkl" ] && printf yes || printf no)"
out="$(cli model prune --yes --json)"; rc=$?
check "prune apply exit 0" "0" "$rc"
check "prune removes old model" "no" "$([ -f "$BUCKET/models/old.pkl" ] && printf yes || printf no)"

echo "udf-file and model share the bucket helper:"
check "one resolver, used by both" "2" "$(grep -c 'udf_bucket_locate ||' "$ROOT/setup/lib/udf-devkit.sh")"
check "and no other code spells out the bucket's path" "2" "$(grep -c '\$EXAKIT_UDF_BUCKETFS_SERVICE' "$ROOT/setup/lib/udf-devkit.sh")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
