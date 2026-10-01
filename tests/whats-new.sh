#!/usr/bin/env bash
# Guard setup/whats-new.json: the cards are authored by hand, so the file is
# checked here rather than discovered broken by a user mid-upgrade.
#
# The card renderer truncates an over-long line to "..." and caps the number of
# lines per version. Both are last-resort safety nets, not a licence to write
# long lines: a reader who upgrades sees half a sentence and no way to get the
# rest except a second command. Before this test existed the shipped 0.2.0 notes
# were changelog prose, and EVERY line in the box was cut mid-word.
#
# Also checks the things a hand-edited JSON file gets wrong: a stray comma, a
# version key that is not a dotted number (it would be silently skipped, so the
# release ships with no card at all), and a value that is not a list of strings.
#
#   bash tests/whats-new.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/setup/whats-new.json"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

# The limits live in one place; read them rather than restating them, or this
# guard and the renderer drift apart and the guard becomes decoration.
WIDTH="$(sed -n 's/^EXAKIT_WHATS_NEW_POINT_WIDTH=\([0-9]*\).*/\1/p' "$ROOT/setup/lib/common.sh" | head -1)"
MAXPTS="$(sed -n 's/^EXAKIT_WHATS_NEW_POINTS_PER_VERSION=\([0-9]*\).*/\1/p' "$ROOT/setup/lib/common.sh" | head -1)"
if [ -n "$WIDTH" ] && [ -n "$MAXPTS" ]; then
    pass "limits read from common.sh (width $WIDTH, max $MAXPTS per version)"
else
    fail "could not read the limits from common.sh - they were renamed or removed"
    printf '\n%d checks, %d failed\n' "$checks" "$fails"
    exit 1
fi

if [ -f "$FILE" ]; then
    pass "setup/whats-new.json exists"
else
    fail "setup/whats-new.json is missing - the installer has no cards to draw"
    printf '\n%d checks, %d failed\n' "$checks" "$fails"
    exit 1
fi

report="$(python3 - "$FILE" "$WIDTH" "$MAXPTS" <<'PY'
import json, re, sys
path, width, maxpts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    with open(path) as f:
        doc = json.load(f)
except json.JSONDecodeError as e:
    print("FAIL|the file is not valid JSON: %s" % e)
    raise SystemExit(0)
if not isinstance(doc, dict):
    print("FAIL|the top level must be an object of version -> list of lines")
    raise SystemExit(0)
print("PASS|the file is valid JSON")

versions = [k for k in doc if not k.startswith("_")]
if not versions:
    print("FAIL|no version keys at all - every key starts with _")
else:
    print("PASS|%d version(s) declared" % len(versions))

for v in sorted(versions):
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", v):
        # Silently skipped by the renderer, so the release would ship with no
        # card and nobody would notice until a user upgraded into nothing.
        print("FAIL|version key %r is not a plain dotted number, so it is skipped" % v)
        continue
    lines = doc[v]
    if not isinstance(lines, list):
        print("FAIL|%s does not hold a list of lines" % v)
        continue
    if len(lines) > maxpts:
        print("FAIL|%s has %d lines, over the %d the card shows" % (v, len(lines), maxpts))
    else:
        print("PASS|%s has %d line(s), within %d" % (v, len(lines), maxpts))
    for line in lines:
        if not isinstance(line, str):
            print("FAIL|%s contains a non-string entry: %r" % (v, line))
            continue
        n = len(line)
        if n > width:
            print("FAIL|%s line is %d chars, over %d, so the card cuts it: %r" % (v, n, width, line[:40] + "..."))
        elif not line.strip():
            print("FAIL|%s contains a blank line" % v)
PY
)" || { printf 'FAIL could not read the file with python3\n'; exit 1; }

while IFS='|' read -r verdict message; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
        PASS) pass "$message" ;;
        *)    fail "$message" ;;
    esac
done <<EOF
$report
EOF

# The renderer must be able to read what this test just approved: a guard that
# only inspects the file, and never asks the code, passes a file the code cannot
# parse (a path change, a renamed function).
. "$ROOT/setup/lib/common.sh" 2>/dev/null || true
if command -v exakit_whats_new_versions >/dev/null 2>&1; then
    live="$(exakit_whats_new_versions "$ROOT" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
    if [ -n "$live" ]; then
        pass "the renderer reads it too: $live"
    else
        fail "the renderer found no versions in a file this test just validated - check exakit_whats_new_file's path"
    fi
else
    fail "exakit_whats_new_versions is gone from common.sh"
fi

# The command is discoverable: it sits in the help screen's Reference group,
# answers --help, and the catalog finds it. It shipped without any of that --
# `exakit whats-new --help` said "No help entry" and `exakit catalog whats`
# matched nothing -- so a reader could only learn of it from the CHANGELOG.
if python3 - "$ROOT/setup/help/exakit.json" <<'PYCHECK' >/dev/null 2>&1
import json, sys
doc = json.load(open(sys.argv[1]))
ref = next(g for g in doc["groups"] if g["title"] == "Reference")
assert "whats-new" in ref["commands"], "not in the Reference group"
assert any(c["command"] == "whats-new" and c["summary"] for c in doc["commands"]), "no command entry"
PYCHECK
then pass "whats-new is in the help document's Reference group"; else fail "whats-new is missing from setup/help/exakit.json (Reference group + command entry)"; fi
_wn_help="$(NO_COLOR=1 EXAKIT_NO_FANCY=1 bash "$ROOT/setup/exakit" whats-new --help 2>/dev/null)"
case "$_wn_help" in
    *"exakit whats-new"*"Examples"*) pass "exakit whats-new --help renders its page" ;;
    *) fail "exakit whats-new --help does not render a page: $_wn_help" ;;
esac

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
