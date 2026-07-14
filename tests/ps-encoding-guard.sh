#!/usr/bin/env bash
# Guard against the Windows PowerShell 5.1 encoding trap.
#
# PowerShell 5.1 reads BOM-less .ps1 files using the legacy ANSI codepage, so
# raw non-ASCII bytes are misread (UTF-8 "├─" becomes garbage that can even
# terminate strings early and break parsing of the whole script). The repo
# rule: glyphs live only in setup/lib/ui.ps1 (which carries a UTF-8 BOM);
# every other .ps1 must be pure ASCII and reference the palette variables.
#
# This has bitten twice already (an em dash in mcp.ps1, tree connectors in
# exapump.ps1 that made the Windows install fail to parse). Run:
#
#   bash tests/ps-encoding-guard.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

# 1. ui.ps1 must keep its UTF-8 BOM (PS 5.1 needs it to decode the glyphs).
bom="$(head -c 3 "$ROOT/setup/lib/ui.ps1" | od -An -tx1 | tr -d ' \n')"
if [ "$bom" = "efbbbf" ]; then
    pass "setup/lib/ui.ps1 has a UTF-8 BOM"
else
    fail "setup/lib/ui.ps1 lost its UTF-8 BOM (found: $bom)"
fi

# 2. Every other .ps1 must be pure ASCII (no bytes above 0x7F anywhere).
while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    case "$rel" in setup/lib/ui.ps1) continue ;; esac
    if LC_ALL=C grep -q $'[\x80-\xff]' "$file"; then
        offenders="$(LC_ALL=C grep -n $'[\x80-\xff]' "$file" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
        fail "$rel contains non-ASCII bytes (lines $offenders) - use the ui palette variables instead"
    else
        pass "$rel is pure ASCII"
    fi
done <<EOF
$(find "$ROOT" -name '*.ps1' -not -path "$ROOT/.git/*" | sort)
EOF

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
