#!/usr/bin/env bash
# env-file.sh — the settings file, ~/.exasol-starter-kit/exakit.env (template:
# setup/exakit.env; loader: setup/lib/envfile.sh, with a copy in install.sh):
#   - NAME=value lines are read as written - nothing in them is ever run -
#     and a value already in the environment wins;
#   - only EXAKIT_* names (and EXASOL_TELEMETRY_DISABLE); secrets, EXAKIT_HOME
#     and EXAKIT_ENV_FILE are refused and named;
#   - the template, as shipped, sets nothing; uncommented, it refuses nothing;
#   - the first install copies it, once, never over the user's copy;
#   - install.sh's copy of the loader is the same function;
#   - the template is COMPLETE: every setting a document tells people to set
#     and the code reads is in it, and it lists nothing the code does not read.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '%s\r\n' '# a comment' '' '  EXAKIT_DB_PORT=9563     # an inline comment' 'export EXAKIT_PERSONA=general' \
    'EXAKIT_DATASETS_MIRROR="/tmp/a dir/#x"' "EXAKIT_REF='feat/x'" "EXAKIT_LOCAL_KIT=\$(touch $WORK/ran)" \
    'PATH=/nowhere' 'EXAKIT_PROVIDER_API_KEY=sk-1' 'EXAKIT_HOME=/elsewhere' 'exakit_lower=1' \
    'EXAKIT_VERSION_POLICY=pinned' 'EXAKIT_VERSIONS_URL=https://h/p#frag' 'not a setting' > "$WORK/case.env"

for shell in sh bash; do
    printf '\n== the loader, in %s ==\n' "$shell"
    OUT="$(EXAKIT_ENV_FILE="$WORK/case.env" EXAKIT_VERSION_POLICY=latest "$shell" -c '
        . "$1"; exakit_load_env_file
        printf "%s|" "$EXAKIT_DB_PORT" "$EXAKIT_PERSONA" "$EXAKIT_DATASETS_MIRROR" "$EXAKIT_REF" "$EXAKIT_LOCAL_KIT" \
            "$PATH" "${EXAKIT_PROVIDER_API_KEY-unset}" "$EXAKIT_VERSION_POLICY" "$EXAKIT_VERSIONS_URL" "$EXAKIT_ENV_FILE_REFUSED"
        sh -c "printf %s \"\$EXAKIT_PERSONA\""' _ "$ROOT/setup/lib/envfile.sh")"
    IFS='|' read -r port persona mirror ref local path key policy url refused child <<EOF
$OUT
EOF
    check "a line with spaces and an inline comment (CRLF too)" "9563" "$port"
    check "export NAME=value" "general" "$persona"
    check "a double-quoted value keeps its spaces and #" "/tmp/a dir/#x" "$mirror"
    check "a single-quoted value" "feat/x" "$ref"
    check "nothing is run: \$(...) stays text" "\$(touch $WORK/ran)" "$local"
    check "...and ran nothing" "no" "$([ -e "$WORK/ran" ] && echo yes || echo no)"
    check "PATH is not the file's to set" "no" "$([ "$path" = /nowhere ] && echo yes || echo no)"
    check "a secret is refused" "unset" "$key"
    check "the environment wins over the file" "latest" "$policy"
    check "a # inside an unquoted URL is kept" "https://h/p#frag" "$url"
    check "the refused names are named" "EXAKIT_PROVIDER_API_KEY EXAKIT_HOME" "$refused"
    check "what it sets is exported to child processes" "general" "$child"
done

printf '\n== the template ==\n'
check "as shipped (all commented) it sets nothing" "" "$(EXAKIT_ENV_FILE="$ROOT/setup/exakit.env" bash -c '
    before="$(env | grep -E "^(EXAKIT_|EXASOL_TELEMETRY)" | sort)"
    . "$1"; exakit_load_env_file
    after="$(env | grep -E "^(EXAKIT_|EXASOL_TELEMETRY)" | sort)"
    [ "$before" = "$after" ] || printf changed' _ "$ROOT/setup/lib/envfile.sh")"
sed -E 's/^# (EXAKIT_[A-Z0-9_]+=|EXASOL_TELEMETRY_DISABLE=)/\1/' "$ROOT/setup/exakit.env" > "$WORK/all.env"
check "uncommented, every line is accepted (it lists no secret)" "" \
    "$(env -i HOME="$WORK" PATH="$PATH" EXAKIT_ENV_FILE="$WORK/all.env" bash -c '. "$1"; exakit_load_env_file; printf %s "$EXAKIT_ENV_FILE_REFUSED"' _ "$ROOT/setup/lib/envfile.sh")"
check "...and the values are the defaults, comments cut off" "8563|manifest|STARTER_KIT" \
    "$(env -i HOME="$WORK" PATH="$PATH" EXAKIT_ENV_FILE="$WORK/all.env" bash -c '. "$1"; exakit_load_env_file; printf "%s|%s|%s" "$EXAKIT_DB_PORT" "$EXAKIT_VERSION_POLICY" "$EXAKIT_MCP_READONLY_SCHEMAS"' _ "$ROOT/setup/lib/envfile.sh")"

printf '\n== the first install copies it, once ==\n'
mkdir -p "$WORK/kit/setup" && cp "$ROOT/setup/exakit.env" "$WORK/kit/setup/"
EXAKIT_HOME="$WORK/home" bash -c '. "$1"; exakit_env_file_install "$2"' _ "$ROOT/setup/lib/envfile.sh" "$WORK/kit"
check "the template is in the kit home" "same" "$(cmp -s "$ROOT/setup/exakit.env" "$WORK/home/exakit.env" && echo same)"
check "readable by its owner only" "600" "$(stat -f %Lp "$WORK/home/exakit.env" 2>/dev/null || stat -c %a "$WORK/home/exakit.env")"
printf 'EXAKIT_DB_PORT=1\n' > "$WORK/home/exakit.env"
EXAKIT_HOME="$WORK/home" bash -c '. "$1"; exakit_env_file_install "$2"' _ "$ROOT/setup/lib/envfile.sh" "$WORK/kit"
check "the user's copy is never overwritten" "EXAKIT_DB_PORT=1" "$(cat "$WORK/home/exakit.env")"

printf '\n== the copies and the entry points ==\n'
fn() { awk '/^exakit_load_env_file\(\) \{/,/^}/' "$1"; }
check "install.sh carries the same loader" "same" "$(cmp -s <(fn "$ROOT/setup/lib/envfile.sh") <(fn "$ROOT/install.sh") && echo same)"
check "install.sh reads the file first thing in main" "yes" "$(awk '/^main\(\) \{/{getline; print; exit}' "$ROOT/install.sh" | grep -q exakit_load_env_file && echo yes)"
check "common.sh reads it before ui.sh" "yes" "$(awk '/exakit_load_env_file/{a=NR} /ui\.sh"$/{if(!b)b=NR} END{print (a && b && a<b) ? "yes" : "no"}' "$ROOT/setup/lib/common.sh")"
SETTINGS="$(EXAKIT_ENV_FILE="$WORK/case.env" bash -c '. "$1/setup/lib/common.sh"; printf %s "$EXAKIT_DB_PORT"' _ "$ROOT")"
check "a kit command sees the file's value" "9563" "$SETTINGS"

printf '\n== the template is complete ==\n'
OUT="$(python3 - "$ROOT" <<'PY'
import glob, json, re, sys
root = sys.argv[1]
def names(paths):
    text = []
    for path in paths:
        try:
            text.append(open(path, encoding="utf-8", errors="replace").read())
        except OSError:
            pass
    return set(re.findall(r"\bEXAKIT_[A-Z0-9_]+\b", "\n".join(text)))
g = lambda *patterns: [p for pattern in patterns for p in glob.glob(f"{root}/{pattern}", recursive=True)]
documented = names(g("README.md", "AGENTS.md", "MARKETPLACE.md", "personas/README.md", "data/README.md", "marketplace/README.md",
                     "docs/*.md", "setup/help/*.json"))
code = [p for p in g("install.sh", "install.ps1", "setup/**/*.sh", "setup/**/*.ps1", "setup/**/*.py", "setup/exakit",
                     "marketplace/**/*.py", "notebook/package/**/*.py", "mcp/**/*.py") if not p.endswith("exakit.env")]
read = names(code)
# Names the code builds: EXAKIT_<ADD-ON>_VERSION (marketplace/runtime.py) and EXAKIT_NOTEBOOK_<TOOL>_VERSION.
catalog = json.load(open(f"{root}/marketplace/catalog.json"))
read |= {"EXAKIT_" + a["id"].upper().replace("-", "_") + "_VERSION" for a in catalog["addons"]}
read |= {f"EXAKIT_NOTEBOOK_{tool}_VERSION" for tool in ("JUPYTERLAB", "MARIMO")}
template = set(re.findall(r"^# (EXAKIT_[A-Z0-9_]+)=", open(f"{root}/setup/exakit.env").read(), re.M))
not_settings = {"EXAKIT_SEMANTIC", "EXAKIT_SCORING", "EXAKIT_UDF", "EXAKIT_SMOKE",     # schema names, not settings
                "EXAKIT_HOME", "EXAKIT_ENV_FILE"}                                     # where the file is
secret = re.compile("PASSWORD|API_KEY|TOKEN|SECRET")
missing = sorted(n for n in documented & read if n not in not_settings and not secret.search(n) and n not in template)
unread = sorted(n for n in template if n not in read)
print("missing=" + " ".join(missing))
print("unread=" + " ".join(unread))
PY
)"
check "every documented setting is in setup/exakit.env" "missing=" "$(printf '%s\n' "$OUT" | grep '^missing=')"
check "setup/exakit.env lists nothing the code does not read" "unread=" "$(printf '%s\n' "$OUT" | grep '^unread=')"

printf '\nenv-file.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
