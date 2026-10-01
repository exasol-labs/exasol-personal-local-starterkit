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
# .claude/ is excluded because a git worktree under .claude/worktrees/ is a
# FULL second checkout: its setup/lib/ui.ps1 is a copy of the one file allowed
# to hold glyphs, but the exemption above matches an exact path, so the copy
# reported as an offender. CI never sees this -- a fresh checkout has no
# worktrees -- so it only ever failed on a developer's machine, which is the
# worst place to spend a false failure.
done <<EOF
$(find "$ROOT" -name '*.ps1' -not -path "$ROOT/.git/*" -not -path "$ROOT/.claude/*" | sort)
EOF

# 3. "$var:" inside a double-quoted string is a PARSE ERROR, not a runtime one.
#
# PowerShell reads $name: as a drive-qualified variable ($env:, $script:,
# $global: are the ones people know), so "FAIL $label: expected ..." refuses to
# parse and the WHOLE FILE dies before a single line of it runs. There is no
# pwsh on the machine this kit is developed on, so the first time anyone found
# out was a red Windows job - which is a full CI round to learn something a
# regular expression can say in a second. ${label} is the fix.
#
# Only the known scope prefixes are allowed; anything else is the mistake.
while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    # Whole-line comments are skipped: they discuss the hazard (this file's own
    # note, and Test-ExakitLocalPath's "answers $true: ...") without being it.
    # The known scope prefixes are removed before the test, since $env: and
    # $script: are the legitimate form of exactly this syntax.
    hits="$(awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            gsub(/\$(env|script|global|local|private|using|workflow):/, "", line)
            if (line ~ /"[^"]*\$[A-Za-z_][A-Za-z0-9_]*:/) print NR
        }' "$file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$hits" ]; then
        fail "$rel has \$name: in a string (lines $hits) - PowerShell reads it as a drive; write \${name}:"
    else
        pass "$rel has no drive-ambiguous variable reference"
    fi
done <<EOF
$(find "$ROOT" -name '*.ps1' -not -path "$ROOT/.git/*" -not -path "$ROOT/.claude/*" | sort)
EOF

# 4. A NATIVE COMMAND'S stderr IS A TERMINATING ERROR under
# $ErrorActionPreference = "Stop", which both entry points set globally.
#
# `& $python -c "import x" 2>$null` looks like it swallows the noise and lets
# $LASTEXITCODE answer. It does not: Windows PowerShell promotes the native
# command's stderr to a RemoteException BEFORE the exit code can be read. That
# is how `exakit version` and `exakit marketplace` came to die with a bare
# "Traceback (most recent call last):" on any Windows machine carrying a stock
# python without exasol-json-tables - which is the common case, not a corner
# one. Invoke-ExakitLogged has carried the defence and a comment describing the
# quirk for a long time; two probes simply never used it.
#
# The rule: a `&` invocation redirecting stderr must sit inside a window where
# $ErrorActionPreference has been set to "Continue". Checked over the twelve
# preceding lines, which covers the save/set/call/restore shape used
# everywhere in this repo, and a bare try/catch counts too since the
# exception is then handled.
#
# The match is deliberately NOT anchored to the start of the line. It was, and
# that let the commonest shape of all through untouched: `$v = & $python -c ...
# 2>$null`, which is a probe whose whole purpose is to answer a question about
# a possibly-broken thing. Six sites were hiding behind the anchor, among them
# Get-PyexasolInstalledVersion and Get-DashServerPackageVersion (both read by
# `exakit version`), where a probe writing to stderr is the ORDINARY case.
# Whole-line comments are
# skipped so prose describing the trap does not trip it.
while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    bad=""
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        from=$(( n - 12 )); [ "$from" -lt 1 ] && from=1
        window="$(sed -n "${from},${n}p" "$file")"
        case "$window" in
            *'ErrorActionPreference = "Continue"'*) continue ;;
            *"try {"*) continue ;;
        esac
        bad="${bad:+$bad,}$n"
    done <<INNER
$(grep -nE '(^|[^`])&[[:space:]]+[^ ]+.*2>(\$null|&1)' "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1)
INNER
    if [ -n "$bad" ]; then
        fail "$rel invokes a native command with redirected stderr outside a Continue window (lines $bad) - 5.1 turns that into a terminating error before \$LASTEXITCODE is read"
    else
        pass "$rel guards every native call that redirects stderr"
    fi
done <<EOF
$(find "$ROOT" -name '*.ps1' -not -path "$ROOT/.git/*" -not -path "$ROOT/.claude/*" | sort)
EOF

# 5. Out-String, in product code, without -Width.
#
# Windows PowerShell 5.1's Out-String runs the FORMATTING subsystem and hard
# wraps at $Host.UI.RawUI.BufferSize.Width - 80 in a console, 120 headless.
# PowerShell 7 does not wrap at all, so the pwsh CI leg cannot see this, and
# the folding only ever happens on the engine real users get (exakit.cmd runs
# powershell.exe). One of these captures is fed to ConvertFrom-Json: a folded
# config_path line made Get-McpClientStates throw, return $null, and silently
# drop the kit back to the undifferentiated client menu. The test suites have
# always passed -Width 4096; the product code passed it nowhere.
for file in $(find "$ROOT/setup" -name '*.ps1' | sort); do
    rel="${file#$ROOT/}"
    bare="$(grep -n 'Out-String' "$file" \
            | grep -v -- '-Width' \
            | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1 | tr '\n' ' ')"
    if [ -n "$(printf '%s' "$bare" | tr -d ' ')" ]; then
        fail "$rel captures through Out-String with no -Width (lines ${bare% }) - 5.1 folds it to the terminal width"
    else
        pass "$rel widens every Out-String capture"
    fi
done

# 6. A redirected pipe that nobody reads.
#
# RedirectStandardError = $true with no read of StandardError is a deadlock,
# not an ignore: the Windows anonymous pipe buffers 4 KB, and a probe that
# writes past that blocks on the write and never exits. WaitForExit then burns
# its whole timeout, the probe is killed, and the $null that comes back reads
# to every caller as "this feature is not supported".
for file in $(find "$ROOT/setup" -name '*.ps1' | sort); do
    rel="${file#$ROOT/}"
    grep -q 'RedirectStandardError[[:space:]]*=[[:space:]]*\$true' "$file" || continue
    if grep -q 'StandardError\.ReadToEnd' "$file"; then
        pass "$rel drains the stderr pipe it redirects"
    else
        fail "$rel redirects stderr and never reads it - a chatty probe deadlocks against WaitForExit"
    fi
done

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
