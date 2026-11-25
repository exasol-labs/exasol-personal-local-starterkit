#!/usr/bin/env bash
# autostart-sandbox-guard.sh - no test suite reaches this machine's own login
# entries. W4-01: tests/component-ownership-ps.ps1 ran the kit's uninstall
# with the real APPDATA and deleted the real Startup entries
# (com.exasol.exakit.database.cmd, dash-server.cmd, exasol-scheduler.cmd) of
# the kit installed on the Windows test box.
#
# A PowerShell suite that names a function that writes or deletes a Startup
# entry must point EXAKIT_STARTUP_DIR into its sandbox or stub
# Get-ExakitStartupDir. A shell suite that runs a function that writes or
# deletes a LaunchAgent or systemd --user unit must set HOME, or
# EXAKIT_LAUNCHAGENT_DIR, and stub both launchctl and systemctl (a shell
# function or a PATH shim): those two act on the real login session by
# label, wherever the file is. Comments, text reads (grep / sed / awk, an
# assertion) and a writer the suite defines as its own stub do not count.
# The second half checks the guard itself.
#
#   bash tests/autostart-sandbox-guard.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

PS_WRITERS='Disable-ExakitAutostart|Enable-ExakitAutostart|Enable-ExakitAutostartDefault|Invoke-CmdAutostart|Invoke-CmdUninstall|Invoke-ExakitUninstallComponent|Invoke-ExakitUninstallOrphanAutostart|Invoke-ExakitUninstallRun|Register-ExakitAutostart|Unregister-ExakitAutostart|Update-ExakitAutostartEntries'
SH_WRITERS='cmd_uninstall|cmd_autostart|exakit_autostart_enable|exakit_autostart_disable|exakit_autostart_default_on|exakit_autostart_refresh|_exakit_autostart_register|_exakit_autostart_unregister|_exakit_uninstall_orphan_autostart'

# unsafe_suites <dir> - every suite in <dir> that names a writer and keeps
# none of the sandboxes, one path per line.
unsafe_suites() {
    for _f in "$1"/*.ps1 "$1"/lib/*.ps1; do
        [ -f "$_f" ] || continue
        grep -Eq "($PS_WRITERS)([^A-Za-z-]|\$)" "$_f" || continue
        grep -Eq '\$env:EXAKIT_STARTUP_DIR *=|function +Get-ExakitStartupDir' "$_f" || printf '%s\n' "$_f"
    done
    for _f in "$1"/*.sh "$1"/lib/*.sh; do
        [ -f "$_f" ] || continue
        case "$_f" in */autostart-sandbox-guard.sh) continue ;; esac
        # The lines that RUN code: not a comment, and not one that only reads
        # the kit's text (grep / sed / awk, or an assertion on a string).
        _code="$(grep -vE '^[[:space:]]*#|(^|[^A-Za-z_])(grep|sed|awk)[[:space:]]|^[[:space:]]*(has|lacks|contains|check|pass|fail) ' "$_f")"
        _reach=""
        for _w in $(printf '%s' "$SH_WRITERS" | tr '|' ' '); do
            printf '%s\n' "$_code" | grep -Eq "(^|[^A-Za-z_])$_w([^A-Za-z_(]|\$)" || continue
            # A writer the suite defines itself is a stub: it reaches nothing.
            grep -Eq "(^|[^A-Za-z_])$_w *\(\) *\{" "$_f" && continue
            _reach=1
        done
        [ -n "$_reach" ] || continue
        # A sandbox HOME keeps the plist and unit FILES out of the real home,
        # but `launchctl load/unload <plist>` and `systemctl --user
        # enable/disable <label>` act on the real login session by label,
        # wherever the file is: both must be stubbed too, by a shell function
        # or a PATH shim (review 0.3.1, item 3).
        grep -Eq '(^|[^A-Za-z_])HOME=|EXAKIT_LAUNCHAGENT_DIR=' "$_f" || { printf '%s\n' "$_f"; continue; }
        for _t in launchctl systemctl; do
            grep -Eq "(^|[^A-Za-z_])$_t *\(\)|/$_t([^A-Za-z_]|\$)|for [A-Za-z_]+ in [^;]*$_t([^A-Za-z_]|\$)" "$_f" || { printf '%s\n' "$_f"; break; }
        done
    done
}

printf '== every suite keeps the login entries in its sandbox ==\n'
_bad="$(unsafe_suites "$ROOT/tests")"
if [ -z "$_bad" ]; then
    pass "no suite can reach the real Startup folder, LaunchAgents or systemd user units"
else
    for _b in $_bad; do fail "${_b#"$ROOT"/} names a login-entry writer with no sandbox (EXAKIT_STARTUP_DIR / Get-ExakitStartupDir stub, or HOME / EXAKIT_LAUNCHAGENT_DIR with launchctl and systemctl stubbed)"; done
fi

printf '\n== the guard catches a suite that does not ==\n'
_t="$(mktemp -d)"; trap 'rm -rf "$_t"' EXIT
mkdir -p "$_t/lib"
printf '. ./setup/lib/exakit-common.ps1\nInvoke-ExakitUninstallRun\n' > "$_t/bad-ps.ps1"
printf '$env:EXAKIT_STARTUP_DIR = "x"\nInvoke-ExakitUninstallRun\n' > "$_t/good-ps.ps1"
printf 'function Get-ExakitStartupDir { "x" }\nRegister-ExakitAutostart -Id d\n' > "$_t/stub-ps.ps1"
printf '. setup/lib/common.sh\ncmd_uninstall --yes\n' > "$_t/bad-sh.sh"
printf 'export HOME="$WORK/home"\nlaunchctl() { :; }\nsystemctl() { :; }\ncmd_uninstall --yes\n' > "$_t/good-sh.sh"
printf 'export HOME="$WORK/home"\n_exakit_autostart_register database\n' > "$_t/home-only-sh.sh"
printf 'export HOME="$WORK/home"\nprintf "#!/bin/sh\\n" > "$W/bin/launchctl"\n_exakit_autostart_register database\n' > "$_t/no-systemctl-sh.sh"
printf 'export HOME="$WORK/home"\nfor t in launchctl systemctl; do printf x > "$W/$t"; done\n_exakit_autostart_register database\n' > "$_t/shim-loop-sh.sh"
printf 'grep -q _exakit_autostart_register setup/lib/common.sh\n# _exakit_autostart_register database\n' > "$_t/reads-only-sh.sh"
printf 'exakit_autostart_default_on() { :; }\nexakit_autostart_default_on\n' > "$_t/stubbed-writer-sh.sh"
_got="$(unsafe_suites "$_t" | sed "s#^$_t/##" | sort | tr '\n' ' ')"
_want="bad-ps.ps1 bad-sh.sh home-only-sh.sh no-systemctl-sh.sh "
[ "$_got" = "$_want" ] && pass "an unsandboxed suite, or one with the real launchctl or systemctl, is named, a sandboxed and stubbed one is not" \
    || fail "the guard named: '$_got' (want: '$_want')"

printf '\nautostart-sandbox-guard.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
