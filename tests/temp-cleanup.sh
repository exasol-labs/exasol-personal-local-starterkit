#!/usr/bin/env bash
# temp-cleanup.sh — nothing the kit makes in TMPDIR outlives the run that made it.
#
#   bash tests/temp-cleanup.sh
#
# A dry run used to copy the whole checkout (.git, .claude/worktrees, caches:
# ~500 MB on a dev machine) into $TMPDIR/exakit-dry-run.* and never remove it;
# 435 of them filled 135 GB on one Mac. The data table's state file was never
# removed either, and the add-ons table and the launcher download only on the
# happy path. Every check here runs against a TMPDIR of its own, so a leak is
# an entry in a directory that must be empty.
#
# twin: tests/temp-cleanup-ps.ps1

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRATCH="$WORK/tmp"
mkdir -p "$SCRATCH"
left() { ls -A "$SCRATCH" | tr '\n' ' ' | sed 's/ $//'; }

# dry <extra env...> — the installer's dry run over this checkout, with its own
# TMPDIR and kit home. Output to a file: the plan is not under test.
dry() {
    env TMPDIR="$SCRATCH" HOME="$WORK/home" EXAKIT_HOME="$WORK/home/kit" \
        EXAKIT_BIN_DIR="$WORK/home/bin" EXAKIT_NO_PROFILE_EDIT=1 \
        EXAKIT_LOCAL_KIT="$ROOT" EXAKIT_DRY_RUN=1 "$@" sh "$ROOT/install.sh" \
        > "$WORK/out" 2>&1
}

printf '\n== install.sh: a dry run leaves nothing in TMPDIR ==\n'
dry; check "first dry run exits 0" "0" "$?"
check "first dry run: TMPDIR is empty" "" "$(left)"
dry; check "second dry run exits 0" "0" "$?"
check "second dry run: TMPDIR is empty" "" "$(left)"
check "and says the folder was removed" "1" "$(grep -c 'has been removed' "$WORK/out")"
check "nothing written under EXAKIT_HOME" "no" "$([ -e "$WORK/home/kit" ] && echo yes || echo no)"

printf '\n== install.sh: EXAKIT_DRY_RUN_KEEP=1 keeps it, and only the kit ==\n'
dry EXAKIT_DRY_RUN_KEEP=1; check "keep run exits 0" "0" "$?"
kept="$(ls -d "$SCRATCH"/exakit-dry-run.* 2>/dev/null | head -n 1)"
check "the folder is kept" "yes" "$([ -n "$kept" ] && [ -f "$kept/install.sh" ] && echo yes || echo no)"
check "and named in the output" "1" "$(grep -c 'kept for inspection' "$WORK/out")"
check "no .git in the copy" "no" "$([ -e "$kept/.git" ] && echo yes || echo no)"
check "no .claude in the copy" "no" "$([ -e "$kept/.claude" ] && echo yes || echo no)"
rm -rf "$SCRATCH"/*

printf '\n== install.sh: a local copy is what git ships, not the checkout ==\n'
SRC="$WORK/src"
mkdir -p "$SRC/.claude/worktrees/big" "$SRC/setup" "$SRC/.ruff_cache"
printf 'echo kit\n' > "$SRC/install.sh"
printf 'x\n' > "$SRC/setup/tracked.sh"
printf 'x\n' > "$SRC/.claude/worktrees/big/blob"
printf '*\n' > "$SRC/.ruff_cache/.gitignore"
printf 'x\n' > "$SRC/.ruff_cache/cache"
printf '.claude/\n' > "$SRC/.gitignore"
if command -v git >/dev/null 2>&1; then
    git -C "$SRC" init -q && git -C "$SRC" add install.sh setup .gitignore && \
        git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init
    printf 'x\n' > "$SRC/setup/new-untracked.sh"
    rm -f "$SRC/setup/tracked.sh"      # tracked, deleted: must not fail the copy
    printf 'x\n' > "$SRC/setup/tracked2.sh"
    dry EXAKIT_LOCAL_KIT="$SRC" EXAKIT_DRY_RUN_KEEP=1
    check "git checkout copy exits 0" "0" "$?"
    kept="$(ls -d "$SCRATCH"/exakit-dry-run.* 2>/dev/null | head -n 1)"
    check "an untracked new file is copied" "yes" "$([ -f "$kept/setup/new-untracked.sh" ] && echo yes || echo no)"
    check "ignored .claude is not" "no" "$([ -e "$kept/.claude" ] && echo yes || echo no)"
    check "self-ignored cache is not" "no" "$([ -e "$kept/.ruff_cache/cache" ] && echo yes || echo no)"
    check "no .git" "no" "$([ -e "$kept/.git" ] && echo yes || echo no)"
    rm -rf "$SCRATCH"/* "$SRC/.git"
fi
dry EXAKIT_LOCAL_KIT="$SRC" EXAKIT_DRY_RUN_KEEP=1
check "plain folder copy exits 0" "0" "$?"
kept="$(ls -d "$SCRATCH"/exakit-dry-run.* 2>/dev/null | head -n 1)"
check "plain folder: kit files copied" "yes" "$([ -f "$kept/install.sh" ] && echo yes || echo no)"
check "plain folder: .claude skipped" "no" "$([ -e "$kept/.claude" ] && echo yes || echo no)"
check "plain folder: .ruff_cache skipped" "no" "$([ -e "$kept/.ruff_cache" ] && echo yes || echo no)"
rm -rf "$SCRATCH"/*

printf '\n== install.sh: failures and signals clean up too ==\n'
dry EXAKIT_LOCAL_KIT="$WORK/not-a-kit"
check "fail() after mktemp exits 1" "1" "$?"
check "fail(): TMPDIR is empty" "" "$(left)"
dry EXAKIT_PREFLIGHT=1
check "preflight (no exec) under a dry run: TMPDIR is empty" "" "$(left)"
for sig in TERM INT HUP; do
    # INT reset to default: a background job of a non-interactive shell starts
    # with it ignored, and a shell may not trap what it inherited ignored.
    env TMPDIR="$SCRATCH" HOME="$WORK/home" EXAKIT_HOME="$WORK/home/kit" \
        EXAKIT_LOCAL_KIT="$ROOT" EXAKIT_DRY_RUN=1 \
        perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' sh "$ROOT/install.sh" > /dev/null 2>&1 &
    pid=$!
    n=0
    while [ "$n" -lt 200 ] && [ -z "$(left)" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.05; n=$((n + 1))
    done
    kill -"$sig" "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    check "SIG$sig mid-run: TMPDIR is empty" "" "$(left)"
done

printf '\n== exakit_track_tmp / exakit_sweep_tmp ==\n'
(
    set +u
    export TMPDIR="$SCRATCH" EXAKIT_HOME="$WORK/lib-home" HOME="$WORK/home"
    mkdir -p "$EXAKIT_HOME"
    # shellcheck source=/dev/null
    . "$ROOT/setup/lib/ui.sh"
    # shellcheck source=/dev/null
    . "$ROOT/setup/lib/common.sh"
    # shellcheck source=/dev/null
    . "$ROOT/setup/lib/exapump.sh"

    parent="$(mktemp "$SCRATCH/exakit-table.XXXXXX")"
    : > "$parent.lines"; : > "$parent.fatal"
    exakit_track_tmp "$parent"
    # A load dies in its subshell while the parent's table still animates from
    # its state file: the subshell's own scratch goes, the parent's stays.
    ( child="$(mktemp -d "$SCRATCH/exakit-personal.XXXXXX")"
      exakit_track_tmp "$child"
      die "simulated failure" ) > /dev/null 2>&1
    check "die() in a subshell removes the subshell's folder" "$(basename "$parent") $(basename "$parent").fatal $(basename "$parent").lines" "$(left)"
    exakit_sweep_tmp
    check "the parent's sweep removes its file and sidecars" "" "$(left)"
    check "the registry is empty after a sweep" "" "$EXAKIT_SCRATCH_TMP"

    EXAKIT_TABLE_STATE="$(mktemp "$SCRATCH/exakit-table.XXXXXX")"
    : > "$EXAKIT_TABLE_STATE.stop"
    exakit_data_table_release
    check "exakit_data_table_release removes the state and sidecars" "" "$(left)"
    check "and forgets the path" "" "$EXAKIT_TABLE_STATE"
)

printf '\n== the exakit CLI sweeps on exit ==\n'
# A command that tracks a file and then dies, through the real CLI entry: the
# EXIT trap the CLI sets is what has to remove it.
cat > "$WORK/probe.sh" <<'EOF'
_f="$(mktemp "${TMPDIR:-/tmp}/exakit-addons.XXXXXX")"
exakit_track_tmp "$_f"
exit 7
EOF
grep -q "trap .*exakit_sweep_tmp.* EXIT" "$ROOT/setup/exakit"
check "setup/exakit sets an EXIT trap that sweeps" "0" "$?"
TMPDIR="$SCRATCH" HOME="$WORK/home" EXAKIT_HOME="$WORK/cli-home" bash -c '
    set +u
    _lib_dir="$1/setup/lib"
    . "$_lib_dir/common.sh"
    eval "$(grep "^trap .*exakit_sweep_tmp.* EXIT" "$1/setup/exakit")"
    . "$2"' _ "$ROOT" "$WORK/probe.sh" > /dev/null 2>&1
check "the exit status survives the trap" "7" "$?"
check "the CLI trap leaves TMPDIR empty" "" "$(left)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
