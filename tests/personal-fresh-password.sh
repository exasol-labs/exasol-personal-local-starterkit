#!/usr/bin/env bash
# personal-fresh-password.sh - a replaced database is a new database. From
# Exasol Personal 2.4 it has its own random sys password and, always, its own
# users, so the exapump profile and the MCP read-only user are rebuilt, never
# skipped as "already done":
#   - exapump_profile_password_stale: the profile against the credential file
#   - step_artifact_state exapump: "missing", with its reason, over a stale profile
#   - personal_forget_database_steps drops exapump and mcp, nothing else, and
#     runs on the fresh deploy path right before the manifest is recorded
#   - personal_refresh_changed_password: after `exakit update personal` the
#     password is checked, not assumed; a changed one refreshes the profile
#   - the PowerShell twins
#
# The real functions, extracted, over a flat manifest and a temp profile.
# No database, no launcher.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s contains "%s"\n' "$1" "$2" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}

# --- harness ------------------------------------------------------------------
eval "$(sed -n '/^exapump_profile_password_stale()/,/^}/p' "$ROOT/setup/lib/exapump.sh")"
eval "$(sed -n '/^step_artifact_state()/,/^}/p' "$ROOT/setup/lib/common.sh")"
eval "$(sed -n '/^personal_forget_database_steps()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
MF="$TMP/manifest"
manifest_get() { grep "^$1=" "$MF" 2>/dev/null | tail -1 | cut -d= -f2-; grep -q "^$1=" "$MF" 2>/dev/null; }
manifest_set() { { grep -v "^$1=" "$MF" 2>/dev/null || true; } > "$MF.n"; mv "$MF.n" "$MF"; printf '%s=%s\n' "$1" "$2" >> "$MF"; }
manifest_del() { { grep -v "^$1=" "$MF" 2>/dev/null || true; } > "$MF.n"; mv "$MF.n" "$MF"; }
require_python3() { :; }
run_python() { python3 "$@"; }
exakit_unmark_step() { printf '%s\n' "$1" >> "$TMP/unmarked"; }
EXAPUMP_CONFIG="$TMP/config.toml"
EXAKIT_EXAPUMP_PROFILE="starter-kit"
CRED="$TMP/personal_sys_password"
printf '#!/bin/sh\nexit 0\n' > "$TMP/exapump"; chmod +x "$TMP/exapump"
: > "$MF"
manifest_set components.exapump.path "$TMP/exapump"
manifest_set runtime.password_file "$CRED"

profile() { # profile <password literal, as written between the quotes>
    printf '[other]\nhost = "db.example"\npassword = "unrelated"\n\n[starter-kit]\nhost = "127.0.0.1"\nport = 8563\nuser = "sys"\npassword = "%s"\ntls = true\nvalidate_certificate = false\n' "$1" > "$EXAPUMP_CONFIG"
}
stale() { exapump_profile_password_stale >/dev/null 2>&1; printf '%s' "$?"; }
state() { EXAKIT_STEP_RERUN_REASON=""; step_artifact_state exapump; }
reason() { EXAKIT_STEP_RERUN_REASON=""; step_artifact_state exapump >/dev/null; printf '%s' "$EXAKIT_STEP_RERUN_REASON"; }

echo "exapump_profile_password_stale: the profile against the credential file"
rm -f "$EXAPUMP_CONFIG"; printf 'alpha\n' > "$CRED"
check "no profile -> not stale"                   1 "$(stale)"
profile "alpha"
check "same password -> not stale"                1 "$(stale)"
printf 'beta16characters\n' > "$CRED"
check "new password on file -> stale"             0 "$(stale)"
printf 'p"w\\d\n' > "$CRED"
profile 'p\"w\\d'
check "PowerShell-escaped quote and backslash"    1 "$(stale)"
profile 'p"w\d'
check "shell writer, unescaped"                   1 "$(stale)"
: > "$CRED"
check "empty credential file -> not stale"        1 "$(stale)"
printf 'alpha\n' > "$CRED"; profile "alpha"
manifest_del runtime.password_file
check "no password_file recorded -> not stale"    1 "$(stale)"
manifest_set runtime.password_file "$CRED"
printf '[starter-kit]\nhost = "127.0.0.1"\n' > "$EXAPUMP_CONFIG"
check "profile without a password line"          1 "$(stale)"
out="$(profile "alpha"; printf 'beta\n' > "$CRED"; exapump_profile_password_stale 2>&1)"
check "prints nothing, ever"                      "" "$out"

echo
echo "step_artifact_state exapump: a stale profile re-runs the step, with its reason"
printf 'alpha\n' > "$CRED"; profile "alpha"
check "binary + matching profile -> present"      present "$(state)"
printf 'beta\n' > "$CRED"
check "binary + stale profile -> missing"         missing "$(state)"
contains "  and says why"                         "no longer accepts" "$(reason)"
rm -f "$EXAPUMP_CONFIG"
check "profile gone -> missing (as before)"       missing "$(state)"
contains "  with the older reason"                "profile is gone" "$(reason)"
profile "beta"
check "profile rewritten -> present again"        present "$(state)"
rm -f "$TMP/exapump"
check "binary gone -> missing (as before)"        missing "$(state)"

echo
echo "personal_forget_database_steps: exapump and mcp, nothing else"
rm -f "$TMP/unmarked"
personal_forget_database_steps; rc=$?
check "returns 0"                                 0 "$rc"
check "drops exactly exapump then mcp"            "exapump mcp" "$(tr '\n' ' ' < "$TMP/unmarked" | sed 's/ $//')"
rm -f "$TMP/unmarked"
( unset -f exakit_unmark_step; personal_forget_database_steps ); rc=$?
check "without the helper -> no-op, rc 0"         0 "$rc"
check "  and nothing dropped"                     0 "$( [ -f "$TMP/unmarked" ] && wc -l < "$TMP/unmarked" | tr -d ' ' || echo 0)"

echo
echo "personal_refresh_changed_password: the records follow a password that changed on update"
eval "$(sed -n '/^personal_refresh_changed_password()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
read_credential() { printf '%s' "$STUB_CRED"; }
exapump_create_profile() { printf 'PROFILE\n' >> "$TMP/calls"; }
info() { printf 'INFO %s\n' "$*" >> "$TMP/calls"; }
warn() { printf 'WARN %s\n' "$*" >> "$TMP/calls"; }
refresh() { # refresh <before> <after> -> "rc state"
    : > "$TMP/calls"; STUB_CRED="$2" personal_refresh_changed_password "$1"; _r=$?
    printf '%s %s' "$_r" "$EXAKIT_PERSONAL_PASSWORD_CHANGE"
}
said() { cat "$TMP/calls" 2>/dev/null; }
check "nothing on file before -> unknown"      "1 unknown" "$(refresh "" "alpha")"
check "  and nothing rewritten or said"        "" "$(said)"
check "same password -> same"                  "1 same" "$(refresh "alpha" "alpha")"
check "  and nothing rewritten or said"        "" "$(said)"
check "nothing on file after -> unknown"       "1 unknown" "$(refresh "alpha" "")"
check "new password -> changed"                "0 changed" "$(refresh "alpha" "beta16characters")"
contains "  profile rewritten"                 "PROFILE" "$(said)"
contains "  and said"                          "INFO The database password changed with this update" "$(said)"
contains "  claiming the profile"              "now hold the new one" "$(said)"
contains "  naming what keeps working"         "mcp_readonly" "$(said)"
check "  never prints a password"              0 "$(said | grep -c 'beta16characters')"
exapump_create_profile() { printf 'PROFILE\n' >> "$TMP/calls"; return 1; }
check "rewrite fails -> still changed"         "0 changed" "$(refresh "alpha" "beta16characters")"
contains "  but said as a warning"             "WARN The database password changed" "$(said)"
contains "  naming the manual step"            "exapump profile init" "$(said)"
check "  and never claims the profile"         0 "$(said | grep -c 'now hold the new one')"
exapump_create_profile() { printf 'PROFILE\n' >> "$TMP/calls"; exit 7; }
check "rewrite dies -> the update survives"    "0 changed" "$(refresh "alpha" "beta16characters")"
contains "  as a warning"                      "WARN The database password changed" "$(said)"
check "without exapump.sh loaded -> changed, warned" "0 changed" "$( unset -f exapump_create_profile; refresh "alpha" "beta16characters" )"
contains "  and still said"                    "WARN The database password changed" "$(said)"

echo
echo "wiring: personal_update reads before the swap and checks after the record"
RP="$ROOT/setup/lib/runtime-personal.sh"
_pu="$(sed -n '/^personal_update()/,/^}/p' "$RP")"
_pu_before="$(printf '%s\n' "$_pu" | grep -nF '_pu_pw_before="$(read_credential personal_sys_password' | cut -d: -f1 | head -1)"
_pu_swap="$(printf '%s\n' "$_pu" | grep -n '^    personal_install_launcher$' | cut -d: -f1 | head -1)"
_pu_record="$(printf '%s\n' "$_pu" | grep -n '^    personal_record_manifest$' | cut -d: -f1 | head -1)"
_pu_check="$(printf '%s\n' "$_pu" | grep -nF 'personal_refresh_changed_password "$_pu_pw_before"' | cut -d: -f1 | head -1)"
check "read before the swap"                   yes "$([ -n "$_pu_before" ] && [ -n "$_pu_swap" ] && [ "$_pu_before" -lt "$_pu_swap" ] && echo yes || echo no)"
check "checked after the record"               yes "$([ -n "$_pu_record" ] && [ -n "$_pu_check" ] && [ "$_pu_record" -lt "$_pu_check" ] && echo yes || echo no)"
check "the 'keeps its password' line needs 'same'" 1 "$(printf '%s\n' "$_pu" | grep -cF 'same) info "The existing deployment keeps its engine')"
check "  and 'unknown' claims nothing about it"   1 "$(printf '%s\n' "$_pu" | grep -cF '*)    info "The existing deployment keeps its engine ($(personal_engine_recorded))."')"
RPS="$ROOT/setup/lib/runtime-personal.ps1"
check "ps1: Update-PersonalChangedPassword defined" 1 "$(grep -c '^function Update-PersonalChangedPassword' "$RPS")"
check "  called from Update-Personal"          1 "$(grep -cF 'Update-PersonalChangedPassword $pwBefore' "$RPS")"
check "  before the swap is read"              1 "$(grep -cF '$pwBefore = ("" + (Get-ExakitCredential "personal_sys_password"))' "$RPS")"
# ORDER, inside Update-Personal, like the shell side: existence anywhere in the
# file stayed green with $pwBefore moved below the swap, where every update
# would read the NEW password twice and call it unchanged.
_up="$(sed -n '/^function Update-Personal {/,/^}/p' "$RPS")"
_up_before="$(printf '%s\n' "$_up" | grep -nF '$pwBefore = ("" + (Get-ExakitCredential "personal_sys_password"))' | cut -d: -f1 | head -1)"
_up_swap="$(printf '%s\n' "$_up" | grep -n '^        Install-PersonalLauncher$' | cut -d: -f1 | head -1)"
_up_record="$(printf '%s\n' "$_up" | grep -n '^    Set-PersonalManifest$' | cut -d: -f1 | head -1)"
_up_check="$(printf '%s\n' "$_up" | grep -nF 'Update-PersonalChangedPassword $pwBefore' | cut -d: -f1 | head -1)"
check "ps1: read before the swap, inside Update-Personal" yes "$([ -n "$_up_before" ] && [ -n "$_up_swap" ] && [ "$_up_before" -lt "$_up_swap" ] && echo yes || echo no)"
check "ps1: checked after Set-PersonalManifest"   yes "$([ -n "$_up_record" ] && [ -n "$_up_check" ] && [ "$_up_record" -lt "$_up_check" ] && echo yes || echo no)"
check "ps1: an unreadable secrets.json is unknown" 1 "$(printf '%s\n' "$_up" | grep -cF 'if ($pwState -eq "same" -and -not (Test-PersonalSecretsReadable)) { $pwState = "unknown" }')"

echo
echo "wiring: the fresh deploy path, right before the manifest is recorded"
check "called once in runtime-personal.sh"        1 "$(grep -c '^    personal_forget_database_steps$' "$RP")"
check "  on the line before the fresh record"     1 "$(grep -B1 '^    personal_record_manifest "healthy"$' "$RP" | grep -c 'personal_forget_database_steps')"
check "  never on a reuse path (indented deeper)" 0 "$(grep -c '^        *personal_forget_database_steps' "$RP")"
check "step_artifact_state asks the probe"        1 "$(grep -c 'exapump_profile_password_stale; then' "$ROOT/setup/lib/common.sh")"
RPS="$ROOT/setup/lib/runtime-personal.ps1"
check "ps1: Clear-PersonalDatabaseSteps defined"  1 "$(grep -c '^function Clear-PersonalDatabaseSteps' "$RPS")"
check "  called once"                             1 "$(grep -c '^    Clear-PersonalDatabaseSteps$' "$RPS")"
check "  before the fresh record"                 1 "$(grep -B1 '^    Set-PersonalManifest "healthy"$' "$RPS" | grep -c 'Clear-PersonalDatabaseSteps')"
check "  drops exapump and mcp"                   1 "$(grep -c '@("exapump", "mcp")' "$RPS")"
check "ps1: artifact state asks the twin probe"   1 "$(grep -c 'Test-ExapumpProfilePasswordStale)) {' "$ROOT/setup/lib/exakit-common.ps1")"
check "ps1: the probe exists"                     1 "$(grep -c '^function Test-ExapumpProfilePasswordStale' "$ROOT/setup/lib/exapump.ps1")"

# The Windows twin, wherever a PowerShell is at hand to run it.
if command -v pwsh >/dev/null 2>&1; then
    echo
    if pwsh -NoProfile -NonInteractive -File "$ROOT/tests/personal-fresh-password-ps.ps1"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL personal-fresh-password-ps.ps1"
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
