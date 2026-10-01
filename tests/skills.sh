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
    has "$_id: description carries Triggers" "Triggers" "$_desc"
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
for _hardcode in $(ls -1 "$ROOT/skills" 2>/dev/null); do
    [ -f "$ROOT/skills/$_hardcode/SKILL.md" ] || continue
    case " $(printf '%s' "$_addon_ids" | tr '\n' ' ') " in
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
has "--json names the skill" '"name":"zz-invented-skill"' "$JSON"
has "--json carries the state" '"state":' "$JSON"
if printf '%s' "$JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    check "--json is parseable" "yes" "yes"
else
    check "--json is parseable" "yes" "NOT-JSON"
fi

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
has "...and installs with the add-on" "Install-ExakitAddonSkills \$id" "$(cat "$_ZZ_PS_COMMON")"
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
         "$HOME/.claude/skills/somebody-elses-skill"

_exakit_remove_installed_skills 0 >/dev/null 2>&1
if [ -e "$HOME/.claude/skills/zz-invented-skill" ]; then
    check "a kit skill is removed" "gone" "STILL-THERE"
else
    check "a kit skill is removed" "gone" "gone"
fi
if [ -e "$HOME/.claude/skills/somebody-elses-skill" ]; then
    check "a foreign skill is kept" "kept" "kept"
else
    check "a foreign skill is kept" "kept" "REMOVED"
fi
HOME="$_HOME_SAVED"; export HOME

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
has "exakit skills names the repair only when a skill is missing" 'exakit skills-install' "$(sed -n '/^exakit_skills_list()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "skills --json carries the verdict" '"installed_version"' "$(sed -n '/^exakit_skills_list()/,/^}/p' "$ROOT/setup/lib/common.sh")"
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
has "the JSON says needs-addon" '"name":"zz-gated","state":"needs-addon","addon":"zz-never-addon"' "$_gated_json"
has "...with the runnable remedy" '"remedy":"exakit marketplace zz-never-addon"' "$_gated_json"
_gated_panel="$(exakit_skills_list 2>/dev/null)"
has "the panel names the owning add-on" "with zz-never-addon" "$_gated_panel"
lacks "...and does not prescribe skills-install for it" "exakit skills-install" "$_gated_panel"
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
has "...only when the source set really dropped it" 'if (Test-Path (Join-Path (Join-Path $skillsSrc $prevName) "SKILL.md")) { continue }' "$_PS_INSTALL"
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
