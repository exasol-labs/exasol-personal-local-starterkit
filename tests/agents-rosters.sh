#!/usr/bin/env bash
# agents-rosters.sh — AGENTS.md is the agent runbook, and its hand-maintained
# lists go stale silently.
#
# THE DEFECT THIS EXISTS FOR: a registered add-on with a skill, a help document
# and a marketplace entry was invisible to the runbook — `grep -c dbt AGENTS.md`
# returned 0 — and a documented command (`exakit autostart off`) named a form
# both CLIs reject. Neither is visible to a reader; both are trivially visible
# to a loop. The repo already guards this shape for skills and the marketplace
# (tests/skills.sh, tests/marketplace.sh); this points the same idea at the
# runbook's own rosters.
#
#   bash tests/agents-rosters.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

AGENTS="$(cat "$ROOT/AGENTS.md")"

echo "every registered add-on is named in the runbook:"
for _id in $(sed -n 's/^\([a-z][a-z0-9-]*\)|.*/\1/p' "$ROOT/setup/marketplace.txt" 2>/dev/null); do :; done
# The registry lives in code, so read it from there rather than a second list.
_ids="$( . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
         exakit_marketplace_addons 2>/dev/null | cut -d'|' -f1 )"
[ -n "$_ids" ] || bad "could not read the add-on registry from common.sh"
for _id in $_ids; do
    case "$AGENTS" in
        *"$_id"*) ok "$_id" ;;
        *)        bad "$_id is a registered add-on and AGENTS.md never names it" ;;
    esac
done

echo
echo "every shipped skill is named in the runbook:"
for _dir in "$ROOT"/skills/*/; do
    [ -f "$_dir/SKILL.md" ] || continue
    _name="$(basename "$_dir")"
    case "$AGENTS" in
        *"$_name"*) ok "$_name" ;;
        *)          bad "$_name ships a SKILL.md and AGENTS.md never names it" ;;
    esac
done

echo
echo "no document names a command form the CLIs reject:"
# `<cmd> off` / `<cmd> on` are the shape that bit us: both CLIs reject any
# argument to autostart, and a quickstart told readers to pass one.
_phantoms=0
for _doc in "$ROOT"/*.md "$ROOT"/quickstarts/*.md; do
    [ -f "$_doc" ] || continue
    # CHANGELOG records that these forms were REMOVED. A history of a phantom is
    # not a phantom; excluding it is the difference between a guard and a nag.
    case "$(basename "$_doc")" in CHANGELOG.md) continue ;; esac
    _hits="$(grep -oE 'exakit autostart (on|off)' "$_doc" 2>/dev/null || true)"
    [ -n "$_hits" ] || continue
    printf '%s\n' "$_hits" | while IFS= read -r _h; do
        [ -n "$_h" ] && printf '     %s: %s\n' "$(basename "$_doc")" "$_h"
    done
    _phantoms=$((_phantoms + $(printf '%s\n' "$_hits" | grep -c .)))
done
[ "$_phantoms" -eq 0 ] && ok "no doc passes an argument to 'exakit autostart'" \
                       || bad "$_phantoms doc reference(s) pass an argument both CLIs reject"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
