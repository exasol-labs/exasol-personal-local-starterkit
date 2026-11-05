#!/usr/bin/env bash
# catalog-github-sed.sh - the no-Python reader of the catalog's GitHub block
# (QAT-12). _exakit_addon_github reads marketplace/catalog.json with Python
# where any python3 exists and with sed where none does; the sed path depends
# on the exact line shape tools/addon_github.py writes ("github": {...},
# "backend"), and nothing exercised it. Every field of every add-on is read
# both ways here and must agree, so a catalog reformat that breaks the anchor
# fails CI instead of blanking names and links on a machine without Python.
#
#   bash tests/catalog-github-sed.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s: python [%s], sed [%s]\n' "$1" "$2" "$3"; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" EXAKIT_HOME="$WORK/kh"; mkdir -p "$HOME" "$EXAKIT_HOME"
. "$ROOT/setup/lib/common.sh" 2>/dev/null || { echo "FAIL could not source common.sh"; exit 1; }
_exakit_marketplace_root() { printf '%s\n' "$ROOT"; }

ids="$(python3 -c 'import json,sys; print("\n".join(a["id"] for a in json.load(open(sys.argv[1]))["addons"]))' "$ROOT/marketplace/catalog.json")"
[ -n "$ids" ] || { echo "FAIL no add-ons read from the catalog"; exit 1; }
for id in $ids; do
    for field in repo url name about; do
        with_python="$(_exakit_addon_github "$id" "$field")"
        without="$( _exakit_python3_present() { return 1; }; _exakit_addon_github "$id" "$field")"
        check "$id $field" "$with_python" "$without"
    done
    check "$id has a repository either way" "yes" "$([ -n "$(_exakit_python3_present() { return 1; }; _exakit_addon_repo "$id")" ] && echo yes || echo no)"
done

echo ""
echo "catalog-github-sed.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
