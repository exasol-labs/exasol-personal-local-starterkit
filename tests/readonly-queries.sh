#!/usr/bin/env bash
# readonly-queries.sh - the documented read-only commands, on a machine with nothing installed and only the system
# Python, download nothing, write nothing to the home, and answer with exit 0 (and valid JSON for --json).
#
#   bash tests/readonly-queries.sh
#
# What it pins (audit AGT-01..04): help, help/catalog/logs --json answer on any Python 3 (stock macOS has 3.9, the
# kit's tooling floor is 3.11); persona plan/list/show and marketplace --help/--list never bootstrap uv or Python and
# never edit a shell profile. curl and wget are stand-ins that record a call and fail, so a bootstrap is a failure here.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1: expected <$2>, got <$3>"; fi; }

PY="${TEST_PYTHON3:-$(command -v python3)}"     # TEST_PYTHON3=/usr/bin/python3: the stock 3.9 on macOS
mkdir -p "$WORK/home" "$WORK/bin"
for tool in curl wget; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/network"\nexit 1\n' "$tool" "$WORK" > "$WORK/bin/$tool"
    chmod +x "$WORK/bin/$tool"
done
ln -s "$PY" "$WORK/bin/python3"
echo "python3: $("$PY" --version 2>&1)"

for command in "help" "help --json" "catalog --json" "logs --json" "persona list" "persona show data-scientist" \
               "persona plan data-scientist --json" "marketplace --help"; do
    # shellcheck disable=SC2086
    env -i HOME="$WORK/home" PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb \
        bash "$ROOT/setup/exakit" $command > "$WORK/out" 2> "$WORK/err"
    check "exakit $command: exit 0" 0 "$?"
    case "$command" in
        *--json*) "$PY" -c 'import json, sys; json.load(open(sys.argv[1]))' "$WORK/out" 2>/dev/null
                  check "exakit $command: stdout is one JSON document" 0 "$?" ;;
    esac
done
check "nothing was downloaded" "" "$(cat "$WORK/network" 2>/dev/null)"
check "the home gained no uv, Python or shell profile" "" \
    "$(ls -A "$WORK/home" | grep -v -x Library | tr '\n' ' ' | sed 's/ $//')"     # Library: macOS's own Python cache

echo
echo "readonly-queries.sh: $pass passed, $fail failed"
[ "$fail" = 0 ]
