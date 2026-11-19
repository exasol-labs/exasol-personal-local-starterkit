#!/usr/bin/env bash
# skills.sh — proves the AI skills layer: every shipped SKILL.md carries the
# frontmatter agents match on, the registry is derived from the filesystem
# (so adding a skill stays a one-folder change), the install/list/state
# contract, and the promise that uninstall removes only what the kit placed.
# Pure logic against a sandboxed kit home: no network, no installs.
#
#   bash tests/skills.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac
}

lacks() { # lacks <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The kit home is redirected for the whole run: nothing here may touch a real
# installation, and the discovery roots are redirected for the same reason —
# a test must never write into the developer's own ~/.claude/skills.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
EXAKIT_SKILL_ROOTS="$WORK/claude $WORK/agents"
export EXAKIT_HOME EXAKIT_BIN_DIR EXAKIT_MANIFEST EXAKIT_SKILL_ROOTS
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# HOME too: exakit_install_skills also merges the kit's permission rules into
# $HOME/.claude/settings.json, and with the real HOME a run edits the
# developer's own Claude Code settings whenever an entry is missing there.
HOME="$WORK/userhome"
export HOME
mkdir -p "$HOME"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"

# ---------------------------------------------------------------------------
echo
echo "every shipped skill is loadable by an agent:"
# ---------------------------------------------------------------------------
# A skill an agent cannot identify is dead weight: the name is the directory
# contract, and the description is the ONLY thing an agent sees before it
# decides to load the body. Both are asserted for every skill that ships.
SKILL_COUNT=0
# Skills copied from a component's own repository (skills/upstream.json) keep
# that repository's description word for word; the "Triggers -" list is the
# kit's convention for the skills it writes, so it is asked of those only.
UPSTREAM_SKILLS=" $(python3 "$ROOT/tools/sync_upstream_skills.py" --names | tr '\n' ' ') "
for _dir in "$ROOT"/skills/*/; do
    [ -f "$_dir/SKILL.md" ] || continue
    _id="$(basename "$_dir")"
    SKILL_COUNT=$((SKILL_COUNT + 1))
    _name="$(exakit_skill_field "$_dir/SKILL.md" name)"
    _desc="$(exakit_skill_field "$_dir/SKILL.md" description)"
    check "$_id: name matches its directory" "$_id" "${_name:-MISSING}"
    if [ -n "$_desc" ]; then
        check "$_id: has a description" "yes" "yes"
    else
        check "$_id: has a description" "yes" "MISSING"
    fi
    # The "Triggers —" list is how an agent decides when to fire the skill.
    # skills/README.md promises it is kept accurate; an absent one means the
    # skill can only ever be loaded by being named explicitly.
    case "$UPSTREAM_SKILLS" in
        *" $_id "*) check "$_id: copied from upstream, its description kept" "yes" "yes" ;;
        *) has "$_id: description carries Triggers" "Triggers" "$_desc" ;;
    esac
    # A summary is what `exakit skills` renders; it must not be empty and must
    # not still carry the trigger list.
    _sum="$(exakit_skill_summary "$_desc")"
    if [ -n "$_sum" ]; then
        check "$_id: summary is non-empty" "yes" "yes"
    else
        check "$_id: summary is non-empty" "yes" "EMPTY"
    fi
    lacks "$_id: summary drops the triggers" "Triggers" "$_sum"
    # The kit's own reader is tolerant, but agents load this file with real
    # YAML parsers, and a ": " inside an unquoted plain scalar terminates the
    # scalar there — the skill silently drops out of every standards-compliant
    # loader while `exakit skills` keeps reporting it healthy. Assert the one
    # rule that class of parser enforces and awk cannot see.
    _yaml_safe="$(python3 - "$_dir/SKILL.md" <<'PYEOF'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
if not lines or lines[0] != "---":
    print("no frontmatter"); raise SystemExit
front = []
for line in lines[1:]:
    if line == "---":
        break
    front.append(line)
# A REAL parser first, where one exists: "survives a real YAML parser" was a
# hand-rolled ": "-in-plain-scalar heuristic, which catches the one bug that
# shipped and nothing else a real loader would reject. The heuristic stays as
# the floor for machines without PyYAML, so this check never silently skips.
try:
    import yaml
    try:
        doc = yaml.safe_load("\n".join(front))
        problems = [] if isinstance(doc, dict) else ["frontmatter is not a mapping"]
    except yaml.YAMLError as err:
        problems = ["yaml: " + str(err).splitlines()[0]]
except ImportError:
    problems = []
    for line in front:
        key, sep, value = line.partition(": ")
        if not sep or not key or " " in key:
            continue
        value = value.strip()
        if value[:1] in ("'", '"'):
            continue
        if ": " in value or value.endswith(":"):
            problems.append(key)
print("clean" if not problems else "unparseable value for: " + ", ".join(problems))
PYEOF
)"
    check "$_id: frontmatter survives a real YAML parser" "clean" "$_yaml_safe"
done

# ---------------------------------------------------------------------------
echo
echo "the components' own skills are copies, at the version the kit installs:"
# ---------------------------------------------------------------------------
# Byte for byte against skills/upstream.lock.json: a hand edit would make the
# copy say something its repository never said, and a pin behind the version
# the kit installs would teach an older server's tools. Offline - the sync
# tool is what talks to GitHub.
_up_check="$(python3 "$ROOT/tools/sync_upstream_skills.py" --check 2>&1)"
check "every copy matches the lock and every pin the installed version" "" "$_up_check"
_up_master=no
case "$UPSTREAM_SKILLS" in *" exakit "*) _up_master=yes ;; esac
check "the master skill is not a copy" "no" "$_up_master"
for _up in $UPSTREAM_SKILLS; do
    has "$_up: says where it came from" "copied unchanged from" "$(sed -n '1,12p' "$ROOT/skills/$_up/SKILL.md")"
    check "$_up: carries its repository's licence" "yes" "$([ -s "$ROOT/skills/$_up/LICENSE" ] && echo yes || echo no)"
done
# A broken copy is caught: edit one byte in a scratch copy of the tree.
_UPKIT="$WORK/upkit"; mkdir -p "$_UPKIT/tools"
cp -R "$ROOT/skills" "$_UPKIT/skills"; cp "$ROOT/versions.json" "$_UPKIT/"
cp "$ROOT/tools/sync_upstream_skills.py" "$_UPKIT/tools/"
printf 'x' >> "$_UPKIT/skills/exasol-sql-dialect/SKILL.md"
has "a hand-edited copy is refused" "exasol-sql-dialect/SKILL.md: edited by hand" \
    "$(python3 "$_UPKIT/tools/sync_upstream_skills.py" --check 2>&1)"
rm -rf "$_UPKIT"
# A skill's kit_note (upstream.json) is the one kit text allowed above the
# upstream body: it sits in the quoted kit header, and the body under it stays
# byte for byte. Three upstream skills tell an agent to switch the session
# preprocessor, which on this kit takes the preprocessor framework (JSON
# Tables and every other module) out of that session; their notes say so.
for _up in exasol-dash exasol-semantic-analyst exasol-semantic-modeler; do
    _hdr="$(awk 'NR>1 && /^---$/ {f=1; next} f && /^#/ {exit} f' "$ROOT/skills/$_up/SKILL.md")"
    has "$_up: its kit note sits in the quoted header" "> On this kit, " "$_hdr"
done
has "the exasol-dash note: preprocessor_active false is a false report here" \
    'so that report is false on this kit' "$(sed -n '1,12p' "$ROOT/skills/exasol-dash/SKILL.md")"
for _f in exasol-dash/SKILL.md dash-server/SKILL.md; do
    has "$_f: names the upstream Dash Server issue" "exasol-labs/dash-server/issues/6" "$(cat "$ROOT/skills/$_f")"
done
has "the semantic notes: skip the session setup" 'skip repeating it after a reconnect' \
    "$(sed -n '1,12p' "$ROOT/skills/exasol-semantic-analyst/SKILL.md")"
# The kit's MCP server caps every result at the default_row_limit it is given
# (1,000 rows), silently. The docs say so and tell an agent how to get more,
# and none of them still forbids row_limit, the only way past the cap.
check "mcp.sh: the MCP server's default_row_limit is 1000" "1" \
    "$(grep -c '"default_row_limit": 1000,' "$ROOT/setup/lib/mcp.sh")"
check "mcp.ps1: the MCP server's default_row_limit is 1000" "1" \
    "$(grep -c 'default_row_limit = 1000;' "$ROOT/setup/lib/mcp.ps1")"
has "exakit skill: MCP results stop at 1,000 rows" '**MCP results stop at 1,000 rows.**' "$(cat "$ROOT/skills/exakit/SKILL.md")"
has "exakit skill: tells the user the result may be cut" 'showing the first 1,000 rows; there may be more' "$(cat "$ROOT/skills/exakit/SKILL.md")"
lacks "exakit skill: no longer forbids row_limit" 'no MCP `row_limit`' "$(cat "$ROOT/skills/exakit/SKILL.md")"
has "exasol-mcp skill: names the 1,000-row cap" 'Query results stop at **1,000 rows**' "$(cat "$ROOT/skills/exasol-mcp/SKILL.md")"
has "AGENTS.md: names the 1,000-row cap" '**MCP query results stop at 1,000 rows**' "$(cat "$ROOT/AGENTS.md")"
has "the analyst note: step 6's row_limit advice does not apply here" \
    "step 6's advice not to pass \`row_limit\` does not apply here" \
    "$(sed -n '1,12p' "$ROOT/skills/exasol-semantic-analyst/SKILL.md")"
# AIO-07 (round 3): the mcp-server skill teaches set_exasol_preprocessor, a
# tool the kit's server does not have; its kit note says to skip that section.
_hdr="$(awk 'NR>1 && /^---$/ {f=1; next} f && /^#/ {exit} f' "$ROOT/skills/exasol-mcp-server/SKILL.md")"
has "exasol-mcp-server: its kit note sits in the quoted header" "> On this kit, skip the Preprocessors section" "$_hdr"
# Every vendored copy whose body names set_exasol_preprocessor carries a note.
_up_nonote=""
for _up in $(python3 -c 'import json,sys; [print(s["name"]) for src in json.load(open(sys.argv[1]))["sources"] for s in src["skills"]]' "$ROOT/skills/upstream.json"); do
    grep -q 'set_exasol_preprocessor' "$ROOT/skills/$_up/SKILL.md" 2>/dev/null || continue
    _hdr="$(awk 'NR>1 && /^---$/ {f=1; next} f && /^#/ {exit} f' "$ROOT/skills/$_up/SKILL.md")"
    case "$_hdr" in *"> On this kit, "*) ;; *) _up_nonote="$_up_nonote $_up" ;; esac
done
check "every vendored skill naming set_exasol_preprocessor has a kit note" "" "${_up_nonote# }"
# AIO-06 (round 3): the json-tables query needs double-quoted identifiers,
# which Windows PowerShell 5.1 strips from a native argument.
has "json-tables: Windows PowerShell 5.1 is pointed at --file or a pipe" \
    'In Windows PowerShell 5.1, use `exakit sql --file <path>` or pipe the statement in' \
    "$(cat "$ROOT/skills/json-tables/SKILL.md")"
# AIO-08 (round 3): a kit self-update normally hands the rest to the new kit
# in the same --json object; deferred is the exception, not the rule.
_lc="$(tr '\n' ' ' < "$ROOT/skills/exakit-lifecycle/SKILL.md")"
lacks "lifecycle: the rest is not always deferred" 'Under `--json` the rest is reported `deferred` and' "$_lc"
has "lifecycle: deferred only when the new exakit cannot run or the swap is staged" \
    'Only when the new `exakit` is missing or not executable, or on Windows when the kit swap is staged' "$_lc"
# ...and a scratch tree shows the check holds the line on both sides of it.
_UPKIT="$WORK/upkit"; mkdir -p "$_UPKIT/tools"
cp -R "$ROOT/skills" "$_UPKIT/skills"; cp "$ROOT/versions.json" "$_UPKIT/"
cp "$ROOT/tools/sync_upstream_skills.py" "$_UPKIT/tools/"
printf 'x' >> "$_UPKIT/skills/exasol-dash/SKILL.md"
has "a body edit under a kit note is refused" "exasol-dash/SKILL.md: edited by hand" \
    "$(python3 "$_UPKIT/tools/sync_upstream_skills.py" --check 2>&1)"
cp "$ROOT/skills/exasol-dash/SKILL.md" "$_UPKIT/skills/exasol-dash/SKILL.md"
python3 - "$_UPKIT/skills/upstream.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for source in doc["sources"]:
    for skill in source["skills"]:
        if skill["name"] == "exasol-dash":
            skill["kit_note"] = "A different note."
json.dump(doc, open(path, "w", encoding="utf-8"))
PYEOF
has "a kit note changed in upstream.json without a re-sync is refused" \
    "exasol-dash/SKILL.md: its kit header differs from upstream.json" \
    "$(python3 "$_UPKIT/tools/sync_upstream_skills.py" --check 2>&1)"
cp "$ROOT/skills/upstream.json" "$_UPKIT/skills/upstream.json"
# A note reworded in the copy, with the lock rewritten to match, is still caught.
python3 - "$_UPKIT/skills" <<'PYEOF'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
copy = root / "exasol-dash" / "SKILL.md"
text = copy.read_text(encoding="utf-8").replace("> On this kit, Semantic SQL", "> On this kit, maybe Semantic SQL", 1)
copy.write_text(text, encoding="utf-8")
lock = json.loads((root / "upstream.lock.json").read_text(encoding="utf-8"))
lock["skills"]["exasol-dash"]["files"]["SKILL.md"] = hashlib.sha256(text.encode("utf-8")).hexdigest()
(root / "upstream.lock.json").write_text(json.dumps(lock), encoding="utf-8")
PYEOF
has "a kit note edited in the copy by hand is refused" \
    "exasol-dash/SKILL.md: its kit header differs from upstream.json" \
    "$(python3 "$_UPKIT/tools/sync_upstream_skills.py" --check 2>&1)"
rm -rf "$_UPKIT"

# Guards against the whole point of this feature being quietly lost: the kit
# grew skills for each component and add-on, so a build carrying only the
# original starter skill is a packaging regression, not a valid state.
if [ "$SKILL_COUNT" -ge 2 ]; then
    check "the kit ships more than one skill" "yes" "yes"
else
    check "the kit ships more than one skill" "yes" "only $SKILL_COUNT"
fi

# ---------------------------------------------------------------------------
echo
echo "the registry is the filesystem, not a hardcoded list:"
# ---------------------------------------------------------------------------
# This is the property skills/README.md sells: "add a folder under
# skills/<name>/SKILL.md" with no code edit anywhere. A hardcoded skill name in
# the shell layer would silently take that away — exactly how the old
# uninstall fallback came to name a skill that never shipped.
# Skill ids that are ALSO marketplace add-on ids (dash-server, json-tables,
# exasol-vscode) legitimately appear in the shell layer as add-on registry
# entries, so they are exempt: the thing under test is that no skill needs a
# name in the code to work, not that the string never occurs.
_addon_ids="$(exakit_marketplace_addons 2>/dev/null | cut -d'|' -f1)"
_component_packages="$(python3 -c 'import json,sys
c=json.load(open(sys.argv[1]))["components"]
print(" ".join(sorted({v["package"] for v in c.values() if isinstance(v, dict) and v.get("package")})))' "$ROOT/versions.json")"
for _hardcode in $(ls -1 "$ROOT/skills" 2>/dev/null); do
    [ -f "$ROOT/skills/$_hardcode/SKILL.md" ] || continue
    case " $(printf '%s' "$_addon_ids" | tr '\n' ' ') " in
        *" $_hardcode "*) continue ;;
    esac
    # A skill named after the command itself (exakit) or after a component's
    # package (exasol-mcp-server ships its own skill of that name) shares the
    # name with a constant the code must use; the add-on ids above are the same case.
    case " exakit $_component_packages " in
        *" $_hardcode "*) continue ;;
    esac
    # Match the id as a whole token: "exasol-mcp" is a substring of the MCP
    # package name exasol-mcp-server, which is a legitimate constant.
    _pat="$_hardcode([^-A-Za-z0-9]|$)"
    # grep -c prints 0 AND exits 1 when nothing matches, so swallow the status
    # rather than appending a second count.
    _hits="$(grep -cE -- "$_pat" "$ROOT/setup/lib/common.sh" 2>/dev/null || true)"
    check "common.sh does not hardcode $_hardcode" "0" "${_hits:-0}"
    _hits_ps="$(grep -cE -- "$_pat" "$ROOT/setup/exakit.ps1" 2>/dev/null || true)"
    check "exakit.ps1 does not hardcode $_hardcode" "0" "${_hits_ps:-0}"
done

# A skill invented at run time is picked up with no code change at all.
mkdir -p "$WORK/fakekit/mcp" "$WORK/fakekit/skills/zz-invented-skill"
# The fake kit needs the real versions.json: the install records which skill
# set it came from, and that is read from the kit copy.
cp "$ROOT/versions.json" "$WORK/fakekit/versions.json"
cat > "$WORK/fakekit/skills/zz-invented-skill/SKILL.md" <<'EOF'
---
name: zz-invented-skill
description: A skill that exists only in this test. Triggers — "never".
---
Body.
EOF
# A directory with no SKILL.md must be ignored rather than half-registered.
mkdir -p "$WORK/fakekit/skills/zz-empty-dir"
# ...and one whose frontmatter cannot be read must be skipped consistently,
# so `exakit skills` never lists what skills-install refuses to copy.
mkdir -p "$WORK/fakekit/skills/zz-broken-frontmatter"
printf 'no frontmatter here at all\n' > "$WORK/fakekit/skills/zz-broken-frontmatter/SKILL.md"

exakit_repo_root() { printf '%s\n' "$WORK/fakekit"; }

REG="$(exakit_skills_registry)"
has  "an invented skill registers itself" "zz-invented-skill" "$REG"
lacks "a directory without SKILL.md is ignored" "zz-empty-dir" "$REG"
lacks "unreadable frontmatter is skipped" "zz-broken-frontmatter" "$REG"

# ---------------------------------------------------------------------------
echo
echo "install, state and the JSON contract:"
# ---------------------------------------------------------------------------
printf '{"components": {}}\n' > "$EXAKIT_MANIFEST"

check "before install: state is available" "available" "$(exakit_skill_state zz-invented-skill)"

exakit_install_skills >"$WORK/install.log" 2>&1
INSTALL_RC=$?
check "install succeeds" "0" "$INSTALL_RC"
check "after install: state is installed" "installed" "$(exakit_skill_state zz-invented-skill)"
check "the broken skill was not copied" "available" "$(exakit_skill_state zz-broken-frontmatter)"
has "install refused the broken skill out loud" "zz-broken-frontmatter" "$(cat "$WORK/install.log")"

# Present in one discovery root only — a half-finished install or a hand
# deletion. It needs its own word because the remedy differs from "never
# installed", and `exakit skills` must not call it installed.
rm -rf "$WORK/agents/zz-invented-skill"
check "one root missing: state is partial" "partial" "$(exakit_skill_state zz-invented-skill)"

# What the install recorded is the only honest answer to "which skills are
# ours to remove" once the kit copy is gone.
# Read from versions.json, not hardcoded: the assertion is "the install records
# the shipped skill-set version", and a literal turns every legitimate bump of
# that version into a failure that says nothing about the behaviour.
_skills_version="$(python3 -c "
import json; print(json.load(open('$ROOT/versions.json'))['components']['skills']['version'])")"
has "manifest records the skill set version" "$_skills_version" \
    "$(manifest_get components.skills.version 2>/dev/null || true)"
has "manifest records what was installed" "zz-invented-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"

# The listing is a state query, so it must answer machine-readably with
# nothing else on stdout — the same contract status/info/mcp-doctor keep.
JSON="$(exakit_skills_list --json 2>/dev/null)"
# Pretty-printed like status --json (one key per line) when a Python can run,
# so the needles parse the document instead of assuming its spacing.
has "--json names the skill" '"name": "zz-invented-skill"' "$JSON"
has "--json carries the state" '"state": ' "$JSON"
check "--json is laid out one key per line, like status --json" "yes" \
    "$(printf '%s' "$JSON" | grep -q '^  "skills": \[' && echo yes || echo no)"
if printf '%s' "$JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    check "--json is parseable" "yes" "yes"
else
    check "--json is parseable" "yes" "NOT-JSON"
fi
# SKL-06: three sources, three unlabelled numbers - the installer's "8 AI
# skills", 9 folders on disk, 13 rows in --json - read as a contradiction
# while every one was right. The listing now carries each bucket by name, and
# they must add up: installed + needs_addon + missing = total. Here the one
# core skill is half-placed (one root removed above), so it is "missing".
check "--json carries the four counts, and they add up" \
    "{'installed': 0, 'needs_addon': 0, 'needs_persona': 0, 'missing': 1, 'total': 1}" \
    "$(printf '%s' "$JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["counts"])' 2>/dev/null)"
_cnt="$(printf '%s' "$JSON" | python3 -c 'import json,sys
d=json.load(sys.stdin); c=d["counts"]
print(all(isinstance(c[k],int) for k in ("installed","needs_addon","missing","total")),
      c["installed"]+c["needs_addon"]+c["missing"]==c["total"], c["total"]==len(d["skills"]))' 2>/dev/null)"
check "...as integers, summing to the row count" "True True True" "$_cnt"
# AGT-16: by_state uses the row's own token, so a row's state is always a key.
check "by_state counts the rows by their own state tokens" "True" \
    "$(printf '%s' "$JSON" | python3 -c 'import json,sys,collections
d=json.load(sys.stdin); print(d["by_state"] == dict(collections.Counter(r["state"] for r in d["skills"])))' 2>/dev/null)"
has "the panel ends with the same tally, every number labelled" \
    "0 installed, 1 not placed, 1 in this kit" "$(exakit_skills_list 2>/dev/null)"
# With nothing gated, the installer's sentence is the one it always printed.
has "with nothing gated the installer sentence is unchanged" \
    "Installed 1 AI skill for Claude Code" "$(cat "$WORK/install.log")"

# ---------------------------------------------------------------------------
echo
echo "a skill dropped from the set is retired, not orphaned:"
# ---------------------------------------------------------------------------
# THE ORPHAN THIS PINS: skills-install copied the new set but never removed a
# previously placed skill the new set dropped, so it stayed in the discovery
# roots forever, firing its triggers for a workflow the kit no longer ships.
# Only names the MANIFEST recorded are removed — a skill the user placed
# themselves is never the kit's to touch.
mkdir -p "$WORK/fakekit/skills/zz-keeper"
cat > "$WORK/fakekit/skills/zz-keeper/SKILL.md" <<'EOF'
---
name: zz-keeper
description: Stays in the set. Triggers — "never".
---
Body.
EOF
mkdir -p "$WORK/claude/zz-user-own"
printf 'the user put this here themselves\n' > "$WORK/claude/zz-user-own/SKILL.md"
rm -rf "$WORK/fakekit/skills/zz-invented-skill"
exakit_install_skills >"$WORK/retire.log" 2>&1
check "the dropped skill left every root" "available" "$(exakit_skill_state zz-invented-skill)"
check "the kept skill is untouched" "installed" "$(exakit_skill_state zz-keeper)"
check "a skill the user placed themselves is never removed" "yes" \
    "$([ -f "$WORK/claude/zz-user-own/SKILL.md" ] && echo yes || echo no)"
has "the retirement is said out loud" "Retired 1 skill" "$(cat "$WORK/retire.log")"
lacks "the record no longer names the dropped skill" "zz-invented-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"
# Put the fixture back the way the sections below expect it: the invented
# skill in the kit and placed, the keeper and the user's own skill gone.
rm -rf "$WORK/fakekit/skills/zz-keeper" "$WORK/claude/zz-user-own"
mkdir -p "$WORK/fakekit/skills/zz-invented-skill"
cat > "$WORK/fakekit/skills/zz-invented-skill/SKILL.md" <<'EOF'
---
name: zz-invented-skill
description: A skill that exists only in this test. Triggers — "never".
---
Body.
EOF
exakit_install_skills >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "an add-on's skill ships with its add-on, not before it:"
# ---------------------------------------------------------------------------
# A skill for a marketplace add-on is no use until the add-on is there: its
# whole job is to give an agent triggers for a tool, and matching those triggers
# for a tool that is not installed is worse than not shipping the skill. So the
# AI-bridge step places CORE skills only, and an add-on's skill arrives as part
# of installing the add-on.
#
# Ownership is DECLARED in the skill's frontmatter ("addon: <id>"), not guessed
# from the folder name, so nothing here or in the shell names a skill.
mkdir -p "$WORK/fakekit/skills/zz-owned-skill"
cat > "$WORK/fakekit/skills/zz-owned-skill/SKILL.md" <<'EOF'
---
name: zz-owned-skill
addon: zz-fake-addon
description: A skill owned by a test add-on. Triggers — "never".
EOF
printf -- '---\nBody.\n' >> "$WORK/fakekit/skills/zz-owned-skill/SKILL.md"

check "the owner is read from the frontmatter" "zz-fake-addon" \
    "$(exakit_skill_addon "$WORK/fakekit/skills/zz-owned-skill/SKILL.md")"
check "a core skill declares no owner" "" \
    "$(exakit_skill_addon "$WORK/fakekit/skills/zz-invented-skill/SKILL.md")"
check "the add-on's skills are found by id" "zz-owned-skill" \
    "$(exakit_skills_for_addon zz-fake-addon)"

# Whether the add-on is installed is the only input that moves this.
ZZ_ADDON_INSTALLED=0
exakit_marketplace_addon_installed() {
    [ "$1" = "zz-fake-addon" ] || return 1
    [ "${ZZ_ADDON_INSTALLED:-0}" = "1" ]
}

# 1. The skills step must NOT place it while the add-on is absent.
for _zz_root in "$WORK/claude" "$WORK/agents"; do rm -rf "$_zz_root/zz-owned-skill"; done
exakit_install_skills >"$WORK/install2.log" 2>&1
check "the skills step skips an absent add-on's skill" "available" \
    "$(exakit_skill_state zz-owned-skill)"
check "...and still places the core one" "installed" \
    "$(exakit_skill_state zz-invented-skill)"
lacks "the manifest does not claim it either" "zz-owned-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"
# SKL-06: and the sentence says what it counted - placed of the whole set, and
# where the rest are - instead of a bare "Installed 1" beside two rows.
has "the installer says placed-of-total and where the rest come from" \
    "Installed 1 of 2 AI skills (1 arrives with its add-on) for Claude Code" "$(cat "$WORK/install2.log")"

# 2. Installing the add-on places it.
exakit_install_addon_skills zz-fake-addon
check "installing the add-on places its skill" "installed" \
    "$(exakit_skill_state zz-owned-skill)"
has "...and the manifest records it, so uninstall can find it" "zz-owned-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"

# 3. A refresh while the add-on IS installed keeps it, rather than treating the
#    skills step as the only authority and sweeping it away again.
ZZ_ADDON_INSTALLED=1
exakit_install_skills >"$WORK/install3.log" 2>&1
has "...and once the add-on is there, nothing is held back from the count" \
    "Installed 2 AI skills for Claude Code" "$(cat "$WORK/install3.log")"
check "a refresh keeps an installed add-on's skill" "installed" \
    "$(exakit_skill_state zz-owned-skill)"

# 4. Removing the add-on takes it back out. A skill left behind advertises
#    triggers for a tool that is no longer on the machine.
exakit_remove_addon_skills zz-fake-addon
check "removing the add-on removes its skill" "available" \
    "$(exakit_skill_state zz-owned-skill)"
lacks "...and the manifest stops claiming it" "zz-owned-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"
check "the core skill is untouched throughout" "installed" \
    "$(exakit_skill_state zz-invented-skill)"

unset -f exakit_marketplace_addon_installed
ZZ_ADDON_INSTALLED=0

# 5. The SHIPPED add-on skills actually declare an owner, and it is a real
#    add-on id. Without this the machinery above works and nothing uses it.
_zz_addon_ids="$(exakit_marketplace_addons 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
_zz_owned=0
for _zz_skill in $(ls -1 "$ROOT/skills" 2>/dev/null); do
    [ -f "$ROOT/skills/$_zz_skill/SKILL.md" ] || continue
    _zz_owner="$(exakit_skill_field "$ROOT/skills/$_zz_skill/SKILL.md" addon)"
    [ -n "$_zz_owner" ] || continue
    _zz_owned=$((_zz_owned + 1))
    case " $_zz_addon_ids " in
        *" $_zz_owner "*) _zz_ok="a marketplace add-on" ;;
        *) _zz_ok="'$_zz_owner', which is not a marketplace add-on" ;;
    esac
    check "$_zz_skill is owned by" "a marketplace add-on" "$_zz_ok"
done
if [ "$_zz_owned" -gt 0 ]; then _zz_any="yes"; else _zz_any="no"; fi
check "some shipped skill is add-on owned" "yes" "$_zz_any"

# ...and the declaration cannot be quietly dropped from one of them. Without
# this, deleting a single "addon:" line turns that skill back into a core one
# installed up front, and the loop above just tests one skill fewer -- a guard
# that gets weaker exactly when the thing it guards is broken. Keyed off the
# add-on registry, so it needs no skill name of its own: an add-on that ships a
# skill under its own name must own it.
for _zz_id in $_zz_addon_ids; do
    [ -f "$ROOT/skills/$_zz_id/SKILL.md" ] || continue
    check "the $_zz_id skill still declares its owner" "$_zz_id" \
        "$(exakit_skill_field "$ROOT/skills/$_zz_id/SKILL.md" addon)"
done

# 6. The PowerShell twin, asserted as text: there is no pwsh here, and Windows
#    runs the same marketplace.
_ZZ_PS_COMMON="$ROOT/setup/lib/exakit-common.ps1"
_ZZ_PS_CLI="$ROOT/setup/exakit.ps1"
# The WIRING, on both sides. The lifecycle above calls the two functions
# directly, so it stays green even if nothing ever calls them from the install
# and uninstall paths -- which is the whole feature.
_ZZ_SH_COMMON="$(cat "$ROOT/setup/lib/common.sh")"
has "the marketplace install places the add-on's skills" \
    'exakit_install_addon_skills "$1"' "$_ZZ_SH_COMMON"
has "...and uninstalling the add-on removes them" \
    'exakit_remove_addon_skills "$_uc_key"' "$_ZZ_SH_COMMON"
has "the twin reads the owner"        "function Get-ExakitSkillAddon" "$(cat "$_ZZ_PS_COMMON")"
has "...and gates the skills step"    "Test-ExakitSkillWanted -Path" "$(cat "$_ZZ_PS_COMMON")"
# Windows installs an add-on through the shared Python controller, which places its skills itself.
has "...and installs with the add-on" "install_addon_skills(ctx, addon_id)" "$(cat "$ROOT/marketplace/apply.py")"
has "...and removes with it"          "Remove-ExakitAddonSkills \$Key" "$(cat "$_ZZ_PS_CLI")"

# ---------------------------------------------------------------------------
echo
echo "uninstall removes only what the kit placed:"
# ---------------------------------------------------------------------------
# The discovery folders are shared with every other skill the user has. The
# kit sweeping them wholesale would destroy work it never owned.
mkdir -p "$WORK/claude/somebody-elses-skill"
: > "$WORK/claude/somebody-elses-skill/SKILL.md"
mkdir -p "$WORK/claude/zz-invented-skill" "$WORK/agents/zz-invented-skill"
: > "$WORK/claude/zz-invented-skill/SKILL.md"
: > "$WORK/agents/zz-invented-skill/SKILL.md"

# _exakit_remove_installed_skills reads $HOME, so redirect it for this section
# only and re-point the roots at the same place.
_HOME_SAVED="$HOME"
HOME="$WORK/fakehome"; export HOME
mkdir -p "$HOME/.claude/skills/zz-invented-skill" \
         "$HOME/.agents/skills/zz-invented-skill" \
         "$HOME/.continue/skills/zz-invented-skill" \
         "$HOME/.claude/skills/somebody-elses-skill"
# What the kit places carries its mark (the section after this one covers a
# folder without it).
for _mk in "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.continue/skills"; do
    : > "$_mk/zz-invented-skill/.exakit-owned"
done

_exakit_remove_installed_skills 0 >/dev/null 2>&1
if [ -e "$HOME/.claude/skills/zz-invented-skill" ]; then
    check "a kit skill is removed" "gone" "STILL-THERE"
else
    check "a kit skill is removed" "gone" "gone"
fi
if [ -e "$HOME/.continue/skills/zz-invented-skill" ]; then
    check "a kit skill is removed from Continue's folder" "gone" "STILL-THERE"
else
    check "a kit skill is removed from Continue's folder" "gone" "gone"
fi
if [ -e "$HOME/.claude/skills/somebody-elses-skill" ]; then
    check "a foreign skill is kept" "kept" "kept"
else
    check "a foreign skill is kept" "kept" "REMOVED"
fi
HOME="$_HOME_SAVED"; export HOME

# ---------------------------------------------------------------------------
echo
echo "a folder of a kit skill's name the user keeps is theirs (MCP-03):"
# ---------------------------------------------------------------------------
# The kit replaced any folder named like one of its skills and the uninstall
# deleted it, with no line naming it: a user's own ~/.claude/skills/exakit (or
# dbt-exasol, json-tables, ...) was lost. Every folder the kit places now carries
# .exakit-owned; one without it is never replaced, recorded, or removed, except a
# copy an older kit placed (adopted: byte for byte the kit's, or recorded and not
# an add-on skill whose add-on is missing).
_HOME_SAVED="$HOME"; _ROOTS_SAVED="$EXAKIT_SKILL_ROOTS"
HOME="$WORK/ownhome"; EXAKIT_SKILL_ROOTS="$HOME/.claude/skills $HOME/.agents/skills"
export HOME EXAKIT_SKILL_ROOTS
mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills"
printf '{"components": {}}\n' > "$EXAKIT_MANIFEST"
mkdir -p "$WORK/fakekit/skills/zz-user-named"
printf -- '---\nname: zz-user-named\ndescription: The kit skill. Triggers — "never".\n---\nkit body\n' \
    > "$WORK/fakekit/skills/zz-user-named/SKILL.md"
# 1. The user's own folder under a core kit name, before the kit ever ran.
mkdir -p "$HOME/.claude/skills/zz-user-named"
printf 'my own skill\n' > "$HOME/.claude/skills/zz-user-named/SKILL.md"
printf 'my notes\n'     > "$HOME/.claude/skills/zz-user-named/notes.md"
# 2. The user's own folder under an add-on skill's name, the add-on absent, and
#    listed in the record as kit 0.2.5 listed every kit name it found.
mkdir -p "$HOME/.claude/skills/zz-owned-skill"
printf 'my own dbt-style skill\n' > "$HOME/.claude/skills/zz-owned-skill/SKILL.md"
# 3. A copy kit 0.2.5 placed (no mark) of a skill that has changed since.
mkdir -p "$HOME/.claude/skills/zz-invented-skill"
printf 'the 0.2.5 text\n' > "$HOME/.claude/skills/zz-invented-skill/SKILL.md"
manifest_set components.skills.installed '["zz-invented-skill","zz-owned-skill"]'

exakit_install_skills >"$WORK/own.log" 2>&1
check "the user's own folder under a core name is not replaced" "my own skill|my notes" \
    "$(cat "$HOME/.claude/skills/zz-user-named/SKILL.md")|$(cat "$HOME/.claude/skills/zz-user-named/notes.md" 2>/dev/null)"
check "...and gets no mark" "no" "$([ -e "$HOME/.claude/skills/zz-user-named/.exakit-owned" ] && echo yes || echo no)"
has "...and the install names it in one line" "Kept your own skill folder ~/.claude/skills/zz-user-named" "$(cat "$WORK/own.log")"
check "the other root, where nothing was, gets the kit's copy, marked" "kit body|yes" \
    "$(tail -1 "$HOME/.agents/skills/zz-user-named/SKILL.md")|$([ -s "$HOME/.agents/skills/zz-user-named/.exakit-owned" ] && echo yes || echo no)"
check "the mark holds the skill-set version" "$_skills_version" "$(cat "$HOME/.agents/skills/zz-user-named/.exakit-owned")"
check "the user's folder under a held-back add-on skill's name is untouched" "my own dbt-style skill" \
    "$(cat "$HOME/.claude/skills/zz-owned-skill/SKILL.md")"
check "an older kit's copy it recorded is adopted: replaced and marked" "Body.|yes" \
    "$(tail -1 "$HOME/.claude/skills/zz-invented-skill/SKILL.md")|$([ -e "$HOME/.claude/skills/zz-invented-skill/.exakit-owned" ] && echo yes || echo no)"
_own_rec="$(manifest_get components.skills.installed 2>/dev/null || true)"
lacks "the record no longer claims the user's add-on-named folder" "zz-owned-skill" "$_own_rec"
has "...and claims what the kit placed" "zz-invented-skill" "$_own_rec"
# A second run changes nothing in the user's folders and says the same line.
exakit_install_skills >"$WORK/own2.log" 2>&1
check "a second install leaves the user's folder too" "my own skill" "$(cat "$HOME/.claude/skills/zz-user-named/SKILL.md")"

check "a full install marks the record: only marks count from now on" "true" \
    "$(manifest_get components.skills.marked 2>/dev/null || true)"
check "...so an unmarked folder is not adopted any more, even recorded" "no" \
    "$(unset _EXAKIT_SKR_MEMO; _exakit_skill_is_kits "$HOME/.claude/skills" zz-user-named && echo yes || echo no)"

# 4. Before that (a record an older kit wrote): an unmarked folder of a kit
#    name that differs and is not recorded is kept; a byte-for-byte copy is the kit's.
manifest_set components.skills.marked false
mkdir -p "$HOME/.agents/skills/zz-keeper2"
mkdir -p "$WORK/fakekit/skills/zz-keeper2"
printf -- '---\nname: zz-keeper2\ndescription: x. Triggers — "never".\n---\nkit\n' > "$WORK/fakekit/skills/zz-keeper2/SKILL.md"
printf 'mine\n' > "$HOME/.agents/skills/zz-keeper2/SKILL.md"
check "an unrecorded, different, unmarked folder is not the kit's" "no" \
    "$(unset _EXAKIT_SKR_MEMO; _exakit_skill_is_kits "$HOME/.agents/skills" zz-keeper2 && echo yes || echo no)"
cp "$WORK/fakekit/skills/zz-keeper2/SKILL.md" "$HOME/.agents/skills/zz-keeper2/SKILL.md"
check "...but one byte for byte the kit's is" "yes" \
    "$(unset _EXAKIT_SKR_MEMO; _exakit_skill_is_kits "$HOME/.agents/skills" zz-keeper2 && echo yes || echo no)"
rm -rf "$WORK/fakekit/skills/zz-keeper2" "$HOME/.agents/skills/zz-keeper2"
manifest_set components.skills.marked true

# 5. Uninstall removes the kit's folders and keeps every one of the user's.
_exakit_remove_installed_skills 0 >"$WORK/own-un.log" 2>&1
check "uninstall keeps the user's folder under a core name" "my own skill" "$(cat "$HOME/.claude/skills/zz-user-named/SKILL.md" 2>/dev/null)"
check "uninstall keeps the user's folder under an add-on skill's name" "my own dbt-style skill" \
    "$(cat "$HOME/.claude/skills/zz-owned-skill/SKILL.md" 2>/dev/null)"
check "uninstall removes the kit's marked copies" "gone gone" \
    "$([ -e "$HOME/.agents/skills/zz-user-named" ] && echo there || echo gone) $([ -e "$HOME/.claude/skills/zz-invented-skill" ] && echo there || echo gone)"
# 6. Removing an add-on retires only the kit's folder of its skill.
check "unplacing never removes an unmarked user folder" "kept" \
    "$(unset _EXAKIT_SKR_MEMO; _exakit_skill_unplace zz-owned-skill; [ -e "$HOME/.claude/skills/zz-owned-skill/SKILL.md" ] && echo kept || echo REMOVED)"
rm -rf "$WORK/fakekit/skills/zz-user-named"

# 7. The 0.2.5 -> 0.3.0 upgrade: an add-on skill kit 0.2.5 placed, unmarked, of an
#    add-on the kit installed. Kit 0.2.5 on Windows recorded no add-on skill, and
#    the skills step marks the record before an add-on's skill is placed, so the
#    update said "Kept your own skill folder ~/.claude/skills/dash-server" over the
#    kit's own stale copy. A copy byte for byte one an earlier kit shipped
#    (tests/lib/dash-server-skill-0.2.5.md, CRLF too) is the kit's; one the user
#    changed or added to, or of an add-on the kit did not install, is not.
mkdir -p "$WORK/fakekit/skills/dash-server"
printf -- '---\nname: dash-server\naddon: dash-server\ndescription: x. Triggers — "never".\n---\nkit 0.3.0\n' \
    > "$WORK/fakekit/skills/dash-server/SKILL.md"
manifest_set components.skills.marked true
_ec() ( # _ec <owner-state> — is the 0.2.5 copy in ~/.claude/skills the kit's?
    unset _EXAKIT_SKR_MEMO
    exakit_marketplace_addon_installed() { [ "$1" = dash-server ] && [ "$_ec_state" != absent ]; }
    exakit_component_is_managed() { [ "$1" = dash-server ] && [ "$_ec_state" = kit ]; }
    _ec_state="$1"
    _exakit_skill_is_kits "$HOME/.claude/skills" dash-server && echo yes || echo no
)
rm -rf "$HOME/.claude/skills/dash-server"; mkdir -p "$HOME/.claude/skills/dash-server"
cp "$ROOT/tests/lib/dash-server-skill-0.2.5.md" "$HOME/.claude/skills/dash-server/SKILL.md"
check "a 0.2.5 add-on skill of a kit-installed add-on is the kit's" "yes" "$(_ec kit)"
check "...not when the add-on is not the kit's" "no" "$(_ec user)"
check "...nor when the add-on is not installed" "no" "$(_ec absent)"
sed 's/$/\r/' "$ROOT/tests/lib/dash-server-skill-0.2.5.md" > "$HOME/.claude/skills/dash-server/SKILL.md"
check "...a Windows (CRLF) copy too" "yes" "$(_ec kit)"
printf 'my line\n' >> "$HOME/.claude/skills/dash-server/SKILL.md"
check "a copy the user changed stays theirs" "no" "$(_ec kit)"
cp "$ROOT/tests/lib/dash-server-skill-0.2.5.md" "$HOME/.claude/skills/dash-server/SKILL.md"
printf 'mine\n' > "$HOME/.claude/skills/dash-server/notes.md"
check "...and so does one the user added a file to" "no" "$(_ec kit)"
rm -f "$HOME/.claude/skills/dash-server/notes.md"
# 8. Removing that add-on removes the 0.2.5 copy, as its --dry-run said (audit
#    WNX-03). The add-on's own uninstall drops its receipt first, and the copy is
#    the kit's only while the add-on is installed: decided after that, the
#    folder the preview listed was kept. The whole-kit uninstall had the same
#    order (add-ons in step 0b, the skills in step 3).
_wnx_installed="$WORK/wnx-installed"
_wnx() ( # _wnx <dry> - `exakit uninstall dash-server`, its module dropping the receipt
    exakit_marketplace_addon_installed() { [ "$1" = dash-server ] && [ -e "$_wnx_installed" ]; }
    exakit_component_is_managed() { [ "$1" = dash-server ] && [ -e "$_wnx_installed" ]; }
    _exakit_addon_registered() { [ "$1" = dash-server ]; }
    _exakit_addon_fn() { printf 'wnx_addon_uninstall\n'; }
    wnx_addon_uninstall() { [ "$1" = 1 ] || rm -f "$_wnx_installed"; }
    _exakit_autostart_registered() { return 1; }
    _exakit_autostart_unregister() { :; }
    _exakit_uninstall_component dash-server "$1" 2>&1
)
: > "$_wnx_installed"
has "the add-on removal preview names the 0.2.5 copy" "will remove: AI skill" "$(_wnx 1)"
_wnx 0 >/dev/null
check "...and the removal removes it" "gone|gone" \
    "$([ -e "$HOME/.claude/skills/dash-server" ] && echo KEPT || echo gone)|$([ -e "$_wnx_installed" ] && echo KEPT || echo gone)"
mkdir -p "$HOME/.claude/skills/dash-server"
cp "$ROOT/tests/lib/dash-server-skill-0.2.5.md" "$HOME/.claude/skills/dash-server/SKILL.md"
: > "$_wnx_installed"
check "the whole-kit removal: the add-on's 0.2.5 copy goes in step 3" "gone" "$( (
    exakit_marketplace_addon_installed() { [ "$1" = dash-server ] && [ -e "$_wnx_installed" ]; }
    exakit_component_is_managed() { [ "$1" = dash-server ] && [ -e "$_wnx_installed" ]; }
    _exakit_skills_decide_kits dash-server
    rm -f "$_wnx_installed"                      # step 0b: the add-on is gone
    _exakit_remove_installed_skills 0 >/dev/null 2>&1
    [ -e "$HOME/.claude/skills/dash-server" ] && echo KEPT || echo gone
) )"
_wnx_run="$(sed -n '/^exakit_uninstall_run()/,/^}/p' "$ROOT/setup/lib/common.sh")"
check "...decided before step 0b removes the add-ons" "yes" "$(printf '%s\n' "$_wnx_run" | awk '
    /_exakit_skills_decide_kits/ && !d { d = NR }
    /for _un_id in \$\(exakit_marketplace_removable_addons/ && !l { l = NR }
    END { print (d && l && d < l) ? "yes" : "no" }')"
mkdir -p "$HOME/.claude/skills/dash-server"
cp "$ROOT/tests/lib/dash-server-skill-0.2.5.md" "$HOME/.claude/skills/dash-server/SKILL.md"
_ec_place="$( (
    exakit_marketplace_addon_installed() { [ "$1" = dash-server ]; }
    exakit_component_is_managed() { [ "$1" = dash-server ]; }
    unset _EXAKIT_SKR_MEMO; exakit_install_addon_skills dash-server 2>&1 ) )"
lacks "placing the add-on's skill keeps no own folder over it" "Kept your own skill folder" "$_ec_place"
check "...it replaces the 0.2.5 copy and marks it" "kit 0.3.0|yes" \
    "$(tail -1 "$HOME/.claude/skills/dash-server/SKILL.md")|$([ -e "$HOME/.claude/skills/dash-server/.exakit-owned" ] && echo yes || echo no)"
rm -rf "$WORK/fakekit/skills/dash-server" "$HOME/.claude/skills/dash-server" "$HOME/.agents/skills/dash-server"
HOME="$_HOME_SAVED"; EXAKIT_SKILL_ROOTS="$_ROOTS_SAVED"; export HOME EXAKIT_SKILL_ROOTS

# ---------------------------------------------------------------------------
echo
echo "the CLI and the docs agree:"
# ---------------------------------------------------------------------------
CATALOG="$(python3 -c "
import json
doc = json.load(open('$ROOT/setup/help/exakit.json'))
print(chr(10).join(c['command'] for c in doc['commands']))")"
has "catalog lists exakit skills"         "skills" "$CATALOG"
# skills-install is a REPAIR command, not a discovery one: the installer places
# the skills and `exakit update` fetches a newer set, so the help screen, the
# catalogue and the JSON surfaces leave it out. It keeps its page.
has "the help document still carries skills-install" "skills-install" "$CATALOG"
check "...marked hidden" "True" "$(python3 -c "
import json
doc = json.load(open('$ROOT/setup/help/exakit.json'))
print([c for c in doc['commands'] if c['command'] == 'skills-install'][0].get('hidden'))")"
check "...and in no help group" "0" "$(python3 -c "
import json
doc = json.load(open('$ROOT/setup/help/exakit.json'))
print(sum('skills-install' in g['commands'] for g in doc['groups']))")"
check "skills sits in the Reference group" "True" "$(python3 -c "
import json
doc = json.load(open('$ROOT/setup/help/exakit.json'))
print('skills' in [g for g in doc['groups'] if g['title'] == 'Reference'][0]['commands'])")"
lacks "the overview screen does not list skills-install" "skills-install" "$(bash "$ROOT/setup/exakit" help 2>/dev/null)"
lacks "neither does exakit help --all" "skills-install" "$(bash "$ROOT/setup/exakit" help --all 2>/dev/null)"
lacks "nor the catalogue" "skills-install" "$(bash "$ROOT/setup/exakit" catalog 2>/dev/null)"
# MARKED HIDDEN, NOT ABSENT. This asserted that catalog --json contained no
# skills-install at all, which is what the code did and what AGENTS.md
# contradicts: it describes catalog --json as "every supported command (a
# handful of internal upgrade paths are marked hidden)". Deleting the entries
# meant no row carried a hidden key and three dispatchable commands were
# missing outright - skills-install among them, which `exakit skills --json`
# hands a machine as its own "next", so an agent holding both documents had to
# conclude one of them was lying. The screens above still must not advertise
# it; the machine surface must disclose it with the flag.
check "catalog --json discloses skills-install, marked hidden" "True" \
    "$(bash "$ROOT/setup/exakit" catalog --json 2>/dev/null | python3 -c 'import json, sys
d = json.load(sys.stdin)
rows = [c for c in d["commands"] if c["invocation"] == "exakit skills-install"]
print(bool(rows) and rows[0].get("hidden") is True)' 2>/dev/null)"
has "but exakit skills-install --help still renders its page" "The installer already does this" "$(bash "$ROOT/setup/exakit" skills-install --help 2>/dev/null)"
has "the PowerShell renderer filters hidden entries the same way" 'Get-ExakitHelpVisibleCommands' "$(cat "$ROOT/setup/lib/help.ps1")"
# Both renderers show a command's exit_codes block (bash: help.sh).
has "exakit uninstall --help (bash) lists its exit codes" "Exit codes" "$(bash "$ROOT/setup/exakit" help uninstall 2>/dev/null)"
if command -v pwsh >/dev/null 2>&1; then
    _ps_help="$(ROOT="$ROOT" pwsh -NoProfile -Command '. (Join-Path $env:ROOT "setup/lib/help.ps1"); $script:LibDir = Join-Path $env:ROOT "setup/lib"; [void](Show-ExakitHelpCommand -Name "uninstall")' 2>&1)"
    has "Show-ExakitHelpCommand (PowerShell) lists the exit codes too" "Exit codes" "$_ps_help"
    has "  ...code 1 with its meaning" "1  something remains" "$_ps_help"
    # Numeric order, as in bash: the 0 line comes before the 1 line.
    _ps_l0="$(printf '%s\n' "$_ps_help" | grep -n '^ *0  ' | head -1 | cut -d: -f1)"
    _ps_l1="$(printf '%s\n' "$_ps_help" | grep -n '^ *1  ' | head -1 | cut -d: -f1)"
    has "  ...exit codes in numeric order (0 before 1)" "yes" "$([ -n "$_ps_l0" ] && [ -n "$_ps_l1" ] && [ "$_ps_l0" -lt "$_ps_l1" ] && echo yes || echo no)"
    # An empty exit_codes {} prints no bare "Exit codes" header (bash prints
    # nothing for an empty dict either).
    _ps_empty="$(ROOT="$ROOT" pwsh -NoProfile -Command '. (Join-Path $env:ROOT "setup/lib/help.ps1"); function Get-ExakitHelpDocuments { @{ exakit = [pscustomobject]@{ commands = @([pscustomobject]@{ command = "probe"; summary = "probe entry"; exit_codes = [pscustomobject]@{} }) } } }; [void](Show-ExakitHelpCommand -Name "probe")' 2>&1)"
    has "an empty exit_codes entry still renders its page (PowerShell)" "probe entry" "$_ps_empty"
    lacks "an empty exit_codes {} prints no Exit codes header (PowerShell)" "Exit codes" "$_ps_empty"
else
    has "Show-ExakitHelpCommand renders exit_codes" 'Write-Host "    Exit codes"' "$(cat "$ROOT/setup/lib/help.ps1")"
fi
has "exakit skills names the repair only when a skill is missing" 'exakit skills-install' "$(sed -n '/^exakit_skills_list()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "skills --json carries the verdict" '"installed_version"' "$(sed -n '/^_exakit_skills_json_compact()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "info --json carries the skills block" 'doc["skills"] = {' "$(sed -n '/^cmd_info_json()/,/^}/p' "$ROOT/setup/exakit")"
has "the info panel has a Skills row" 'ui_panel_line "Skills:' "$(cat "$ROOT/setup/lib/common.sh")"
has "PowerShell info carries the skills block" '"skills" -NotePropertyValue' "$(cat "$ROOT/setup/exakit.ps1")"
lacks "no document tells a reader to run skills-install after the install" "Run \`exakit skills-install\`" "$(cat "$ROOT/AGENTS.md" "$ROOT/README.md" "$ROOT/QUICKSTART.md")"
has "the bash CLI dispatches skills"      "skills)" "$(cat "$ROOT/setup/exakit")"
has "the PowerShell CLI dispatches skills" '"skills"' "$(cat "$ROOT/setup/exakit.ps1")"

# versions.json carries the skill set, so a stale installed copy is detectable
# after a kit update rather than being invisible.
has "versions.json carries components.skills" '"skills"' "$(cat "$ROOT/versions.json")"
has "the CI component set expects skills" '"skills"' \
    "$(cat "$ROOT/.github/workflows/versions.yml")"

# Twin parity: both shells implement the same registry, or Windows silently
# loses the feature.
PS_COMMON="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
for _fn in Get-ExakitSkillsDir Get-ExakitSkillField Get-ExakitSkillSummary \
           Get-ExakitSkillsRegistry Get-ExakitSkillState Show-ExakitSkills; do
    has "PowerShell twin defines $_fn" "function $_fn" "$PS_COMMON"
done

# Every skill the docs advertise must actually ship.
README="$(cat "$ROOT/skills/README.md")"
for _dir in "$ROOT"/skills/*/; do
    [ -f "$_dir/SKILL.md" ] || continue
    _id="$(basename "$_dir")"
    has "skills/README.md lists $_id" "$_id" "$README"
done

printf '\n== every virtual-schema connector has a skill that names its inputs ==\n'
# THE DRIFT THIS PINS: a connector added to setup/virtual-schemas/catalog.json
# without skills/exasol-vs-<id>/SKILL.md leaves an agent guessing its inputs,
# and an input added to a connector.json without the skill learning it sends
# the agent to a connect that fails with "<input> is required". Both lists are
# READ from the catalog and the connector definitions, never written here, so a
# new connector is checked the moment it lands and no connector id appears in
# this file.
_vs_rows="$(python3 - "$ROOT/setup/virtual-schemas" <<'PYVS'
import json, os, sys
root = sys.argv[1]
for entry in json.load(open(os.path.join(root, "catalog.json")))["connectors"]:
    spec = json.load(open(os.path.join(root, "connectors", entry["id"], "connector.json")))
    print(entry["id"] + " " + " ".join(s["name"] for s in spec["inputs"]))
PYVS
)"
if [ -n "$_vs_rows" ]; then
    check "the connector catalog and its definitions are readable" "yes" "yes"
else
    check "the connector catalog and its definitions are readable" "yes" "NO"
fi
_vs_ids=""
_vs_shared="$(cat "$ROOT/skills/exasol-virtual-schemas/SKILL.md" 2>/dev/null)"
while read -r _vs_id _vs_inputs; do
    [ -n "$_vs_id" ] || continue
    _vs_ids="$_vs_ids $_vs_id"
    _vs_md="$ROOT/skills/exasol-vs-$_vs_id/SKILL.md"
    if [ ! -f "$_vs_md" ]; then
        check "connector $_vs_id has skills/exasol-vs-$_vs_id/SKILL.md" "present" "MISSING"
        continue
    fi
    check "connector $_vs_id has skills/exasol-vs-$_vs_id/SKILL.md" "present" "present"
    _vs_text="$(cat "$_vs_md")"
    # Named as code (`host`), the way the skill's inputs table writes it: a
    # bare word such as "host" or "schema" would match any sentence.
    for _vs_in in $_vs_inputs; do
        has "exasol-vs-$_vs_id names input \`$_vs_in\`" "\`$_vs_in\`" "$_vs_text"
    done
    has "exasol-vs-$_vs_id shows its connect command" "exakit connect $_vs_id " "$_vs_text"
    has "exasol-vs-$_vs_id points at the shared rules" "../exasol-virtual-schemas/SKILL.md" "$_vs_text"
    has "the shared skill indexes exasol-vs-$_vs_id" "exasol-vs-$_vs_id/SKILL.md" "$_vs_shared"
done <<EOF
$_vs_rows
EOF
# ...and the other way round: a connector skill outliving its connector keeps
# firing triggers for a source `exakit connect` no longer offers.
for _vs_dir in "$ROOT"/skills/exasol-vs-*/; do
    [ -f "$_vs_dir/SKILL.md" ] || continue
    _vs_sid="$(basename "$_vs_dir")"; _vs_sid="${_vs_sid#exasol-vs-}"
    case " $_vs_ids " in
        *" $_vs_sid "*) check "skills/exasol-vs-$_vs_sid matches a catalog connector" "yes" "yes" ;;
        *)              check "skills/exasol-vs-$_vs_sid matches a catalog connector" "yes" "NO" ;;
    esac
done

printf '\n== the skill set is a component exakit update can fetch ==\n'
# THE GAP THIS CLOSES: skills reached a machine only inside a kit update. Bump
# components.skills.version alone and `exakit skills` said "stale" while
# pointing at skills-install -- which copied the OLD local files and recorded
# the NEW number. A maintainer who edits skills/<name>/SKILL.md and bumps the
# version, with no kit release, must reach every installed kit through
# `exakit update`, the way an exapump bump does.
SH_UPD="$(cat "$ROOT/setup/lib/common.sh")"
# An earlier section removes the marketplace probe to test the skills registry
# in isolation; the update-target list asks it which add-ons are installed, so
# give it back a "none" answer here.
command -v exakit_marketplace_addon_installed >/dev/null 2>&1 || exakit_marketplace_addon_installed() { return 1; }
check "skills is a routine update target" "1" "$(exakit_update_targets all | grep -c '^skills$')"
check "...and an explicit one" "skills" "$(exakit_update_targets skills)"
check "it lives at components.skills" "components.skills" "$(_exakit_component_block skills)"
has "the twin lists it too" 'if (Get-ExakitSkillsDir) { $targets += "skills" }' "$PS_COMMON"
has "the shell updater exists" "exakit_update_skills()" "$SH_UPD"
has "...and dispatches to it" "skills) exakit_update_skills ;;" "$SH_UPD"
has "the twin updater exists" "function Update-ExakitSkills" "$PS_COMMON"
has "...and the Windows CLI dispatches to it" 'Update-ExakitSkills -Advertised $available -Installed $current' "$(cat "$ROOT/setup/exakit.ps1")"
has "the twin records what it placed" "function Set-ExakitSkillsRecord" "$PS_COMMON"

# A kit copy under EXAKIT_HOME, so the updater takes the real path rather than
# the source-checkout shortcut. The registry section above pinned
# exakit_repo_root to its fake kit; point it back at this one.
KIT="$EXAKIT_HOME/kit"
exakit_repo_root() { printf '%s\n' "$KIT"; }
rm -rf "$KIT"; mkdir -p "$KIT/mcp"
cp -R "$ROOT/skills" "$KIT/skills"
cp "$ROOT/versions.json" "$KIT/versions.json"
manifest_set components.skills.version "1.0.0" >/dev/null 2>&1
check "the installed version is the recorded one" "1.0.0" "$(exakit_component_current skills)"

# The archive `exakit update` would download: the repository's skills plus one
# new skill, and a versions.json naming 9.8.7 -- while the ADVERTISED document
# says 9.9.9, the shape of the raw endpoint running ahead of the branch.
FIX="$WORK/fixture/update-path-main"
mkdir -p "$FIX"
cp -R "$ROOT/skills" "$FIX/skills"
mkdir -p "$FIX/skills/zz-fetched-skill"
printf -- '---\nname: zz-fetched-skill\ndescription: Fetched by the test. Triggers — "zz fetched".\n---\n\n# fetched\n' > "$FIX/skills/zz-fetched-skill/SKILL.md"
python3 - "$ROOT/versions.json" "$FIX/versions.json" "$WORK/advertised.json" <<'PYFIX'
import json, sys, collections
doc = json.load(open(sys.argv[1]), object_pairs_hook=collections.OrderedDict)
doc["components"]["skills"]["version"] = "9.8.7"
json.dump(doc, open(sys.argv[2], "w"), indent=2)
doc["components"]["skills"]["version"] = "9.9.9"
json.dump(doc, open(sys.argv[3], "w"), indent=2)
PYFIX
( cd "$WORK/fixture" && tar -czf "$WORK/main.tar.gz" update-path-main )
_upd_out="$( (
    EXAKIT_VERSIONS_CACHE="$WORK/advertised.json"; _EXAKIT_VERSIONS_DOC=""
    curl() { # the only network call: hand over the fixture archive
        while [ "$#" -gt 0 ]; do [ "$1" = "-o" ] && { cp "$WORK/main.tar.gz" "$2"; return 0; }; shift; done
        return 1
    }
    exakit_update_skills 2>&1
    printf 'recorded=%s current=%s marker=%s\n' \
        "$(manifest_get components.skills.version)" "$(exakit_component_current skills)" \
        "$(cat "$KIT/skills/.version" 2>/dev/null)"
    [ -f "$WORK/claude/zz-fetched-skill/SKILL.md" ] && printf 'placed-claude ' || printf 'MISSING-claude '
    [ -f "$WORK/agents/zz-fetched-skill/SKILL.md" ] && printf 'placed-agents ' || printf 'MISSING-agents '
    [ -f "$KIT/skills/zz-fetched-skill/SKILL.md" ] && printf 'in-kit-copy' || printf 'NOT-in-kit-copy'
    ls -d "$KIT"/skills.backup-* >/dev/null 2>&1 && printf ' BACKUP-LEFT' || printf ' backup-cleaned'
) )"
has "the update fetches and places the new skill" "placed-claude placed-agents in-kit-copy" "$_upd_out"
has "it records the version the ARCHIVE names, not the advertised one" "recorded=9.8.7 current=9.8.7 marker=9.8.7" "$_upd_out"
has "...and says the manifest is ahead" "not the advertised 9.9.9" "$_upd_out"
has "the backup of the previous set is removed on success" "backup-cleaned" "$_upd_out"
has "it tells the reader to reload the client" "Restart or reload your AI client" "$_upd_out"
# A later skills-install must keep recording the fetched set, not the kit
# copy's older versions.json: the marker beside the skills is what it reads.
check "skills-install re-records the fetched set" "9.8.7" "$( (
    EXAKIT_VERSIONS_CACHE="$WORK/advertised.json"; _EXAKIT_VERSIONS_DOC=""
    exakit_install_skills >/dev/null 2>&1; manifest_get components.skills.version
) )"
check "the fallback tier reads the same marker" "9.8.7" "$(_exakit_component_fallback skills)"

# An unreachable repository must never fail `exakit update`: skills are
# best-effort, like the refresh inside the kit self-update.
_fail_out="$( (
    EXAKIT_VERSIONS_CACHE="$WORK/advertised.json"; _EXAKIT_VERSIONS_DOC=""
    curl() { return 7; }
    exakit_update_skills 2>&1; printf 'rc=%s\n' "$?"
    printf 'recorded=%s\n' "$(manifest_get components.skills.version)"
) )"
has "an unreachable repository warns" "Could not download the skill set" "$_fail_out"
has "...and does not fail the run" "rc=0" "$_fail_out"
has "...and leaves the record alone" "recorded=9.8.7" "$_fail_out"
check "a current set is left alone" "already current (9.8.7)" "$( (
    EXAKIT_VERSIONS_CACHE="$KIT/versions.json"; _EXAKIT_VERSIONS_DOC=""
    printf '9.8.7\n' > "$KIT/skills/.version"
    python3 - "$KIT/versions.json" <<'PYCUR'
import json, sys, collections
p = sys.argv[1]; d = json.load(open(p), object_pairs_hook=collections.OrderedDict)
d["components"]["skills"]["version"] = "9.8.7"; json.dump(d, open(p, "w"), indent=2)
PYCUR
    curl() { printf 'NETWORK\n' >&2; return 7; }
    exakit_update_skills 2>&1 | grep -o 'already current (9.8.7)'
) )"

echo "an archive holding an OLDER skill set than the installed one is not applied:"
# Seen live: the branch archive named 1.12.6 while 1.24.57 was installed and
# 1.24.58 advertised. The update said "a few minutes ahead of main", recorded
# 1.12.6, put it in place and retired 25 skills. The installed set stays now,
# with its record, and nothing is retired.
OLD="$WORK/fixture-old/update-path-main"
mkdir -p "$OLD"
cp -R "$ROOT/skills" "$OLD/skills"
python3 - "$ROOT/versions.json" "$OLD/versions.json" <<'PYOLD'
import json, sys, collections
doc = json.load(open(sys.argv[1]), object_pairs_hook=collections.OrderedDict)
doc["components"]["skills"]["version"] = "1.2.3"
json.dump(doc, open(sys.argv[2], "w"), indent=2)
PYOLD
( cd "$WORK/fixture-old" && tar -czf "$WORK/old.tar.gz" update-path-main )
manifest_set components.skills.version "9.8.7" >/dev/null 2>&1
printf '9.8.7\n' > "$KIT/skills/.version"
_old_curl() { # the archive for the branch download, the advertised manifest for the check
    _oc_out=""; _oc_url=""
    while [ "$#" -gt 0 ]; do
        case "$1" in -o) _oc_out="$2"; shift ;; https://*) _oc_url="$1" ;; esac
        shift
    done
    [ -n "$_oc_out" ] || return 1
    case "$_oc_url" in
        *versions.json) cp "$WORK/advertised.json" "$_oc_out" && printf '200' ;;
        *) cp "$WORK/old.tar.gz" "$_oc_out" ;;
    esac
}
_old_out="$( (
    EXAKIT_VERSIONS_CACHE="$WORK/advertised.json"; _EXAKIT_VERSIONS_DOC=""
    curl() { _old_curl "$@"; }
    exakit_update_skills 2>&1; printf 'rc=%s\n' "$?"
    printf 'recorded=%s marker=%s\n' "$(manifest_get components.skills.version)" "$(cat "$KIT/skills/.version" 2>/dev/null)"
    [ -f "$KIT/skills/zz-fetched-skill/SKILL.md" ] && printf 'kit-kept ' || printf 'KIT-RETIRED '
    [ -f "$WORK/claude/zz-fetched-skill/SKILL.md" ] && printf 'placed-kept\n' || printf 'PLACED-RETIRED\n'
    ls -d "$KIT"/skills.backup-* >/dev/null 2>&1 && printf 'BACKUP-LEFT\n' || printf 'no-backup\n'
) )"
has "the installed set is kept, said in one line" \
    "Keeping AI skills 9.8.7. The download was an older set (1.2.3), and the next update fetches the right one." "$_old_out"
has "...the updater tells the loop it kept them (3)" "rc=3" "$_old_out"
has "...the record and the marker stay where they were" "recorded=9.8.7 marker=9.8.7" "$_old_out"
has "...and no skill is retired" "kit-kept placed-kept" "$_old_out"
has "...with nothing set aside" "no-backup" "$_old_out"
lacks "...and the 'a few minutes ahead' path is not taken" "a few minutes ahead" "$_old_out"
lacks "...nor any skill retired" "Retired" "$_old_out"
lacks "...nor a newer set claimed" "AI skills updated to" "$_old_out"
# The same run through exakit update: on the screen the closing line does not
# call the skills updated, and --json keeps the row current, not failed.
_old_run="$( (
    EXAKIT_VERSIONS_CACHE="$WORK/advertised.json"; _EXAKIT_VERSIONS_DOC=""
    curl() { _old_curl "$@"; }
    exakit_update skills 2>&1; printf 'rc=%s\n' "$?"
) 2>&1 )"
has "exakit update says it kept them" "Keeping AI skills 9.8.7." "$_old_run"
lacks "...and does not close with 'updated: skills'" "updated: skills" "$_old_run"
has "...and exits 0" "rc=0" "$_old_run"
_old_json="$( (
    EXAKIT_VERSIONS_CACHE="$WORK/advertised.json"; _EXAKIT_VERSIONS_DOC=""
    curl() { _old_curl "$@"; }
    exakit_update --json skills 2>/dev/null
) )"
check "--json: the skills row is current, not updated or failed" "ok=True current=['skills'] updated=[] failed=[]" \
    "$(printf '%s' "$_old_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok=%s current=%s updated=%s failed=%s" % (d["ok"], d["current"], [e["component"] for e in d["updated"]], [e["component"] for e in d["failed"]]))' 2>&1)"
check "...and the record is still the installed set" "9.8.7" "$(manifest_get components.skills.version)"
has "the twin keeps them in the same words" \
    'Info "Keeping AI skills $Installed. The download was an older set ($stagedVersion), and the next update fetches the right one."' "$PS_COMMON"
has "...and its update loop reports the row current" \
    '$component -eq "skills" -and $script:ExakitSkillsKept' "$(cat "$ROOT/setup/exakit.ps1")"

echo "an update from 0.2.5 places the kit skills in every skill folder this kit reads:"
# Kit 0.2.5 (14df2ecb) read two roots only:
#   EXAKIT_SKILL_ROOTS="${EXAKIT_SKILL_ROOTS:-$HOME/.claude/skills $HOME/.agents/skills}"
# Its own `exakit update` swapped in this kit, copied the NEW skill set with
# THOSE roots (unmarked, as 0.2.5 placed them) and recorded the new version. So
# ~/.continue/skills, which this kit reads when Continue is on the machine,
# held none, every skill read "partial", and the skills row said "current" on
# every later update. The layout below is that one, built by hand so the suite
# runs on a shallow clone; where the history is there, 0.2.5's rule is checked.
U25="$WORK/u025"; mkdir -p "$U25/.continue" "$U25/.claude/skills" "$U25/.agents/skills"
if git -C "$ROOT" cat-file -e 14df2ecb 2>/dev/null; then
    has "0.2.5 read two skill roots (the layout below)" \
        'EXAKIT_SKILL_ROOTS="${EXAKIT_SKILL_ROOTS:-$HOME/.claude/skills $HOME/.agents/skills}"' \
        "$(git -C "$ROOT" show 14df2ecb:setup/lib/common.sh)"
fi
check "this kit reads ~/.continue/skills where Continue is" \
    "$U25/.claude/skills $U25/.agents/skills $U25/.continue/skills" \
    "$( (unset EXAKIT_SKILL_ROOTS; HOME="$U25"; . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1; printf '%s' "$EXAKIT_SKILL_ROOTS") )"
mkdir -p "$WORK/u-nocontinue"
check "...and not where it is not (no folder made for a client you lack)" \
    "$WORK/u-nocontinue/.claude/skills $WORK/u-nocontinue/.agents/skills" \
    "$( (unset EXAKIT_SKILL_ROOTS; HOME="$WORK/u-nocontinue"; . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1; printf '%s' "$EXAKIT_SKILL_ROOTS") )"
_u25_names=""; _u25_n=0
for _d in "$KIT"/skills/*/; do
    [ -f "$_d/SKILL.md" ] || continue
    _exakit_skill_wanted "$_d/SKILL.md" || continue
    _n="$(basename "$_d")"
    cp -R "$_d" "$U25/.claude/skills/$_n"; cp -R "$_d" "$U25/.agents/skills/$_n"
    _u25_names="${_u25_names:+$_u25_names,}\"$_n\""; _u25_n=$((_u25_n + 1))
done
manifest_set components.skills.installed "[$_u25_names]" >/dev/null 2>&1
manifest_set components.skills.version "9.8.7" >/dev/null 2>&1
_u25_out="$( (
    EXAKIT_SKILL_ROOTS="$U25/.claude/skills $U25/.agents/skills $U25/.continue/skills"
    EXAKIT_VERSIONS_CACHE="$KIT/versions.json"; _EXAKIT_VERSIONS_DOC=""
    curl() { printf 'NETWORK\n' >&2; return 7; }
    _states() { for _d in "$KIT"/skills/*/; do _exakit_skill_wanted "$_d/SKILL.md" && exakit_skill_state "$(basename "$_d")"; done | sort | uniq -c | tr -s ' ' | tr '\n' ';'; }
    printf 'before=%s\n' "$(_states)"
    exakit_skills_unplaced && printf 'unplaced-before\n'
    exakit_update skills 2>&1
    printf 'after=%s\n' "$(_states)"
    exakit_skills_unplaced || printf 'placed-after\n'
    printf 'continue=%s\n' "$(ls "$U25/.continue/skills" | wc -l | tr -d ' ')"
    printf 'recorded=%s\n' "$(manifest_get components.skills.version)"
    exakit_update_skills 2>&1 | grep -o 'already current (9.8.7)'
) 2>&1 )"
has "after the 0.2.5 update every skill is partial" "before= $_u25_n partial;" "$_u25_out"
has "...which the update sees, at the same version" "unplaced-before" "$_u25_out"
has "exakit update does not skip them as current" "skills 9.8.7 -> 9.8.7" "$_u25_out"
has "...it places them" "AI skills placed in every skill folder (9.8.7)." "$_u25_out"
has "...every one now installed" "after= $_u25_n installed;" "$_u25_out"
has "...Continue's folder holds them" "continue=$_u25_n" "$_u25_out"
has "...with nothing downloaded" "placed-after" "$_u25_out"
lacks "...no skill set fetched" "Updating AI skills" "$_u25_out"
has "...the record unchanged" "recorded=9.8.7" "$_u25_out"
has "...and the next update is current" "already current (9.8.7)" "$_u25_out"
has "the twin's update run does not skip it either" \
    '-not ($actual -eq "skills" -and (Test-ExakitSkillsUnplaced))' "$(cat "$ROOT/setup/exakit.ps1")"
rm -rf "$KIT"

printf '\n== the skills panel says the same three things on both platforms ==\n'

# The stale branch existed only in the shell. On Windows a kit update that left
# the installed copies behind said NOTHING: the skills read "installed", which
# was true and useless, and the reader had no way to know the kit had moved
# underneath them. It matters more now that the skill set has a version that
# actually changes -- it moved to 1.3.0 in the same round this was found.
SH_COMMON="$(cat "$ROOT/setup/lib/common.sh")"
has "the shell detects a stale skill set" \
    'ui_panel_line "Installed skill set $_skl_have; the kit advertises $_skl_want."' "$SH_COMMON"
has "...and the twin does too" \
    'Write-ExakitPanelLine "Installed skill set $skillsHave; the kit advertises $skillsWant."' "$PS_COMMON"
# The remedy is `exakit update`, which FETCHES the advertised set. It used to be
# skills-install, which copies the local kit copy's files -- the old set -- and
# then recorded the advertised number over them, hiding the drift for good.
has "the shell offers the fetch"    'ui_panel_line "Fetch and install them:  exakit update"' "$SH_COMMON"
has "...and so does the twin"       'Write-ExakitPanelLine "Fetch and install them:  exakit update"' "$PS_COMMON"
lacks "and neither points a stale set at skills-install" 'Refresh them:  exakit skills-install' "$SH_COMMON$PS_COMMON"
# Both read the same two values to decide, or they can disagree about staleness.
has "the shell compares installed against advertised" \
    'exakit_versions_value components.skills.version' "$SH_COMMON"
has "...and the twin compares the same pair" \
    'Get-ExakitVersionsValue -Path "components.skills.version"' "$PS_COMMON"
# Nothing is said when everything is installed AND current: the panel watches
# for staleness itself, so telling the reader to watch for it was one more line.
lacks "the shell offers no command when there is nothing to do" \
    "All installed. Refresh after a kit update" "$SH_COMMON"
lacks "...nor does the twin" \
    "All installed. Refresh after a kit update" "$PS_COMMON"

# ---------------------------------------------------------------------------
echo
echo "triggers route to one skill, and gated skills say whose they are:"
# ---------------------------------------------------------------------------
# SKL-04: a verbatim trigger in two skills leaves the agent a coin flip.
check "'connect my AI to Exasol' belongs to exactly one skill" "1" \
    "$(grep -l 'connect my AI to Exasol' "$ROOT"/skills/*/SKILL.md | wc -l | tr -d ' ')"
# SKL-05: the ecosystem skill routes AROUND the kit, never over it - no
# literal template trigger, and no claim on the loading the installed tools own.
lacks "the ecosystem skill has no template trigger" '<tool>' \
    "$(cat "$ROOT/skills/exasol-ecosystem/SKILL.md")"
lacks "...and does not claim local Parquet loading" 'load Parquet' \
    "$(sed -n '4p' "$ROOT/skills/exasol-ecosystem/SKILL.md")"
has  "...and scopes itself beyond the kit" 'BEYOND this kit' \
    "$(cat "$ROOT/skills/exasol-ecosystem/SKILL.md")"
# SKL-03: an add-on-gated, uninstalled skill is not "available" to
# skills-install; the listing says whose it is and stops prescribing a command
# that skips it. Proven against the fake kit: gate a skill on an add-on that
# is not installed and read the listing both ways.
# A section above repointed exakit_repo_root at its own kit copy; this block
# builds a minimal kit of its own so the gated fixture is actually visible.
GATEKIT="$WORK/gatekit"
mkdir -p "$GATEKIT/skills/zz-gated"
cp "$ROOT/versions.json" "$GATEKIT/versions.json"
cat > "$GATEKIT/skills/zz-gated/SKILL.md" <<'EOF'
---
name: zz-gated
addon: zz-never-addon
description: Arrives with its add-on. Triggers — "never".
---
Body.
EOF
exakit_repo_root() { printf '%s
' "$GATEKIT"; }
_gated_json="$(exakit_skills_list --json 2>/dev/null)"
check "the JSON says needs-addon" "needs-addon zz-never-addon exakit marketplace zz-never-addon" \
    "$(printf '%s' "$_gated_json" | python3 -c 'import json,sys
r=[r for r in json.load(sys.stdin)["skills"] if r["name"]=="zz-gated"][0]
print(r["state"], r["addon"], r["remedy"])' 2>/dev/null)"
_gated_panel="$(exakit_skills_list 2>/dev/null)"
has "the panel names the owning add-on" "with zz-never-addon" "$_gated_panel"
lacks "...and does not prescribe skills-install for it" "exakit skills-install" "$_gated_panel"
# SKL-06: a gated skill is counted under needs_addon, never under missing -
# or the verdict would call a healthy machine "missing" and name a command
# that cannot change it.
check "the counts file it under needs_addon, not missing" \
    "{'installed': 0, 'needs_addon': 1, 'needs_persona': 0, 'missing': 0, 'total': 1}" \
    "$(printf '%s' "$_gated_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["counts"])' 2>/dev/null)"
lacks "...and the verdict never reads missing for it" '"status": "missing"' "$_gated_json"
has "the panel tally says where it comes from" \
    "0 installed, 1 arrives with its add-on, 1 in this kit" "$_gated_panel"
rm -rf "$GATEKIT"

# ---------------------------------------------------------------------------
echo
echo "the PowerShell twin carries the same three properties:"
# ---------------------------------------------------------------------------
# There is no pwsh here, so these are asserted as text. Every one of them is a
# property the shell side is exercised on for real above, and each shipped to
# Windows unchecked before it was written down here.
PS_SKILLS="$(cat "$ROOT/setup/lib/exakit-common.ps1")"

# SKL-13: the discovery roots must be overridable, or nothing can exercise this
# layer on Windows without writing into the developer's own ~\.claude\skills --
# which is why tests/skills.sh has no Windows twin at all.
_PS_ROOTS="$(awk '/^function Get-ExakitSkillRoots/,/^}/' "$ROOT/setup/lib/exakit-common.ps1")"
has "the twin branches on EXAKIT_SKILL_ROOTS" 'if ($env:EXAKIT_SKILL_ROOTS) {' "$_PS_ROOTS"
has "...and returns them instead of the real home" '$env:EXAKIT_SKILL_ROOTS -split' "$_PS_ROOTS"
has "...returning the override, not falling through" 'return $roots' "$_PS_ROOTS"

# SKL-02: the prune, on the Windows side. The shell retires a skill the new set
# dropped (proven for real above); without this block Install-ExakitSkills only
# ever PLACED, so renaming or retiring a skill left every Windows machine with
# the old copy firing its triggers forever.
_PS_INSTALL="$(awk '/^function Install-ExakitSkills/,/^}$/' "$ROOT/setup/lib/exakit-common.ps1")"
has "the twin reads what it placed before" 'Get-ExakitManifestValue "components.skills.installed"' "$_PS_INSTALL"
has "...and unplaces a name the new set no longer carries" 'Remove-ExakitSkillCopy -Name $prevName' "$_PS_INSTALL"
# Kept only while the set still carries it AND it is still wanted here (a closed
# persona or add-on gate retires it too, as on the shell side).
has "...only when the source set dropped it or no longer wants it here" 'if ((Test-Path $prevMd) -and (Test-ExakitSkillWanted -Path $prevMd)) { continue }' "$_PS_INSTALL"
has "...and says so out loud" 'Ok "Retired $retired $retiredUnit the new set no longer carries"' "$_PS_INSTALL"

# SKL-03: an add-on-gated skill is not counted pending on EITHER half. The shell
# is proven above against a real fixture; the twin's pending count must exclude
# the same rows, or Windows keeps prescribing skills-install for skills that
# command deliberately skips.
has "the twin reads the gating add-on"   "function Get-ExakitSkillGatingAddon" "$PS_SKILLS"
_PS_SHOW="$(awk '/^function Show-ExakitSkills/,/^}$/' "$ROOT/setup/lib/exakit-common.ps1")"
has "...and gives the case its own state" 'state = "needs-addon"' "$_PS_SHOW"
has "...naming the add-on that owns it"   'remedy = "exakit marketplace $owner"' "$_PS_SHOW"
has "...and leaves it out of the pending count" '$skjMissing = $pending' "$_PS_SHOW"
# SKL-06: the four labelled counts, on the Windows half too, summing the same
# way - and the installer's placed-of-total sentence beside them.
has "the twin carries the same four counts" 'counts = [ordered]@{' "$_PS_SHOW"
has "...from the same three buckets" \
    'installed = $placed; needs_addon = $gated; needs_persona = $personaGated; missing = $skjMissing; total = $rows.Count' "$_PS_SHOW"
has "...and the panel's labelled tally" 'Get-ExakitSkillsSummaryLine -Installed $placed -WithAddons $gated -NotPlaced $pending -Total $rows.Count' "$_PS_SHOW"
has "the twin's installer says placed-of-total" 'Installed $installed of $($installed + $gated + $kept) AI skills ($arrive)' "$_PS_INSTALL"
# The gated branch must `continue` BEFORE the pending++ line, or the state word
# changes and the count does not -- the exact half-fix this guards against.
has "...by skipping the count entirely" "continue" \
    "$(printf '%s\n' "$_PS_SHOW" | sed -n '/state = "needs-addon"/,/if ($state -ne "installed") { $pending++ }/p')"

# ---------------------------------------------------------------------------
echo
echo "no two skills claim the same trigger:"
# ---------------------------------------------------------------------------
# A trigger list is how an agent routes a request. The same utterance in two
# descriptions is a coin flip, and it is invisible until someone reads all
# eleven files side by side. Keyed off the filesystem, so a new skill is
# checked the moment it lands and no skill name appears here.
_dupe_triggers="$(for _t_file in "$ROOT"/skills/*/SKILL.md; do
    [ -f "$_t_file" ] || continue
    awk '/^description:/ { print; exit }' "$_t_file" \
        | grep -o '"[^"]*"' | sort -u | sed "s|\$| $(basename "$(dirname "$_t_file")")|"
done | awk '{ key = $0; sub(/ [^ ]*$/, "", key); count[key]++ } END { for (k in count) if (count[k] > 1) print k }')"
check "every trigger belongs to exactly one skill" "" "$_dupe_triggers"

echo
printf 'passed: %d, failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
