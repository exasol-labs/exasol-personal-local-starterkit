#!/usr/bin/env bash
# launcher-words.sh - the launcher's own text, relayed in the kit's failure
# box, never tells a kit user to run the launcher's `destroy`.
#
#   bash tests/launcher-words.sh
#
# THE BUG (scenario X, X2): a failed deploy showed the launcher's last lines
# verbatim, among them "Deployment stopped. Run `start` to restart or
# `destroy` to delete resources." For a kit user `destroy` deletes their
# database, and the kit has its own commands. The screen copy now maps
# `start` to `exakit start` and leaves out any sentence that says to destroy;
# the file the lines come from (the copy of the log) keeps the launcher's
# words.
#
# The real _personal_deploy_print_tail and personal_launcher_words_for_kit;
# no launcher runs.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s contains "%s"\n' "$1" "$2" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: must not contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s lacks "%s"\n' "$1" "$2" ;;
    esac
}

# What the launcher printed in X2 (the user's folder shortened), plus the
# other shapes a destroy hint can take.
cat > "$TMP/tail" <<'TAIL'
Using default deployment directory: /home/u/.exasol/launcher/deployments/default
Error: deployment failed: deployment in /home/u/.exasol/launcher/deployments/default is in state "stopped". Deployment stopped. Run `start` to restart or `destroy` to delete resources.
Use `destroy` to remove the old deployment first. Then retry.
run 'exasol destroy' to clean up
Run `start` again later.
TAIL
cp "$TMP/tail" "$TMP/tail.orig"

out="$(
    HOME="$TMP/home" EXAKIT_HOME="$TMP/kit"; export HOME EXAKIT_HOME
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/runtime-personal.sh" >/dev/null 2>&1
    foreign_note() { printf -- '- %s\n' "$*"; }
    _personal_deploy_print_tail "$TMP/tail"
)"
echo "the deploy failure box:"
contains "the launcher's error is still shown" 'is in state "stopped". Deployment stopped.' "$out"
contains "its start is the kit's" 'Run `exakit start` to restart.' "$out"
lacks    "no destroy instruction" '`destroy`' "$out"
lacks    "  in any quoting" "'exasol destroy'" "$out"
lacks    "  nor the rest of that sentence" "delete resources" "$out"
contains "the sentence after a dropped one stays" "Then retry." "$out"
contains "a bare start hint is mapped too" 'Run `exakit start` again later.' "$out"
contains "lines without a hint are unchanged" "Using default deployment directory: /home/u/.exasol/launcher/deployments/default" "$out"
check_same="$(cmp -s "$TMP/tail" "$TMP/tail.orig" && echo same || echo changed)"
contains "the launcher's own words stay in the log copy" "same" "$check_same"
contains "  with its destroy hint" '`destroy` to delete resources' "$(cat "$TMP/tail")"

echo "the Windows twin maps the same way:"
contains "Show-PersonalLauncherTail goes through ConvertTo-PersonalKitWords" 'ConvertTo-PersonalKitWords ("$line".TrimEnd())' "$(cat "$ROOT/setup/lib/runtime-personal.ps1")"

printf '\nlauncher-words.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
