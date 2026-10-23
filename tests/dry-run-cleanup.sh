#!/usr/bin/env bash
# dry-run-cleanup.sh - a dry run of install.sh must not fill the disk.
#
#   bash tests/dry-run-cleanup.sh
#
# Two leaks, found when a test suite left 435 exakit-dry-run.* folders of about
# 500 MB each in $TMPDIR:
#   1. every EXAKIT_DRY_RUN=1 run left its staging folder behind, forever;
#   2. EXAKIT_LOCAL_KIT copied the whole checkout - .git, agent worktrees under
#      .claude, caches - not just the kit.
# Each dry run here runs against a synthetic checkout in a private TMPDIR, so
# nothing outside this test's own folder is touched.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/exakit-dryrun-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
T="$WORK/tmp"; mkdir -p "$T"

# A checkout: the kit's tracked files, committed, plus what a developer's tree
# also holds - an agent worktree, an ignored cache, a new untracked file, and a
# tracked file deleted in the work tree.
SRC="$WORK/src"; mkdir -p "$SRC"
git -C "$ROOT" archive HEAD | tar -xf - -C "$SRC"
git -C "$SRC" init -q
git -C "$SRC" add -A
git -C "$SRC" -c user.name=t -c user.email=t@example.invalid commit -q -m kit
mkdir -p "$SRC/.claude/worktrees/agent-1"; printf 'big\n' > "$SRC/.claude/worktrees/agent-1/blob"
# Even where .gitignore does not name .claude, agent worktrees stay out.
grep -v '\.claude' "$SRC/.gitignore" > "$SRC/.gitignore.new" 2>/dev/null; mv "$SRC/.gitignore.new" "$SRC/.gitignore"
mkdir -p "$SRC/setup/lib/__pycache__"; printf 'x\n' > "$SRC/setup/lib/__pycache__/cached.pyc"
printf 'new\n' > "$SRC/NEW-UNTRACKED.md"
rm -f "$SRC/CHANGELOG.md"

dry_run() {
    TMPDIR="$T" EXAKIT_HOME="$WORK/home" EXAKIT_LOCAL_KIT="$1" EXAKIT_DRY_RUN=1 \
        sh "$ROOT/install.sh" </dev/null >"$WORK/out" 2>&1
}
newest() { ls -dt "$T"/exakit-dry-run.* 2>/dev/null | head -1; }
yesno() { if [ "$1" "$2" ]; then echo yes; else echo no; fi; }

echo "a local checkout: the kit's files only"
dry_run "$SRC"; check "the dry run succeeds" 0 $?
D="$(newest)"
check "a tracked file is copied" yes "$(yesno -f "$D/setup/exakit")"
check "a new file git does not ignore is copied" yes "$(yesno -f "$D/NEW-UNTRACKED.md")"
check "a tracked file deleted in the work tree is skipped" no "$(yesno -e "$D/CHANGELOG.md")"
check ".git is not copied" no "$(yesno -e "$D/.git")"
check "agent worktrees under .claude are not copied" no "$(yesno -e "$D/.claude")"
check "an ignored cache is not copied" no "$(yesno -e "$D/setup/lib/__pycache__")"
check "the message says when the folder goes" yes \
    "$(grep -q 'the next dry run removes it once it is 10 minutes old' "$WORK/out" && echo yes || echo no)"

echo "a folder that is not a git checkout: everything but the checkout-only folders"
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"
git -C "$ROOT" archive HEAD | tar -xf - -C "$PLAIN"
mkdir -p "$PLAIN/.git" "$PLAIN/.claude/worktrees" "$PLAIN/setup/lib/__pycache__"
printf 'x\n' > "$PLAIN/.claude/worktrees/blob"; printf 'x\n' > "$PLAIN/setup/lib/__pycache__/c.pyc"
dry_run "$PLAIN"; check "the dry run succeeds" 0 $?
D="$(newest)"
check "the kit is copied" yes "$(yesno -f "$D/setup/exakit")"
check ".git is not copied" no "$(yesno -e "$D/.git")"
check ".claude is not copied" no "$(yesno -e "$D/.claude")"
check "a nested __pycache__ is not copied" no "$(yesno -e "$D/setup/lib/__pycache__")"

echo "earlier dry runs are removed once they are 10 minutes old"
rm -rf "$T"/exakit-dry-run.*
mkdir -p "$T/exakit-dry-run.OLD1" "$T/exakit-dry-run.OLD2" "$T/exakit-dry-run.RECENT" "$T/unrelated-folder"
touch -t 202001010000 "$T/exakit-dry-run.OLD1" "$T/exakit-dry-run.OLD2" "$T/unrelated-folder"
dry_run "$SRC"; check "the dry run succeeds" 0 $?
check "an hour-old dry-run folder is removed" no "$(yesno -e "$T/exakit-dry-run.OLD1")"
check "...every one of them" no "$(yesno -e "$T/exakit-dry-run.OLD2")"
check "a dry run from the last 10 minutes is kept" yes "$(yesno -d "$T/exakit-dry-run.RECENT")"
check "a folder that is not a dry run is never touched" yes "$(yesno -d "$T/unrelated-folder")"
check "only the new and the recent folder remain" 2 "$(ls -d "$T"/exakit-dry-run.* | wc -l | tr -d ' ')"

printf '\ndry-run-cleanup.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
