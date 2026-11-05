#!/usr/bin/env bash
# mcp-sve.sh - the faked-SVE self-repair in mcp_validate blames the CPU only
# when it is the CPU (LNX-11).
#
#   bash tests/mcp-sve.sh
#
# On an Arm guest whose hypervisor advertises SVE the host CPU cannot run, the
# server dies in OpenSSL until OPENSSL_armcap=0 is set, and the kit then records
# that override and tells the reader to turn SVE off. On REAL SVE hardware a
# first handshake that fails for another reason (a slow first download, a
# database still starting) followed by a retry that works used to read the same
# way. The plain server is now asked once more after the override worked; only
# when it still fails is the CPU blamed. The handshake is stubbed: no server,
# no network.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s = %s\n' "$1" "$3"; else FAIL=$((FAIL+1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" EXAKIT_HOME="$WORK/kh"; mkdir -p "$HOME" "$EXAKIT_HOME"
. "$ROOT/setup/lib/common.sh" 2>/dev/null || { echo "FAIL could not source common.sh"; exit 1; }
. "$ROOT/setup/lib/mcp.sh"

# Everything around the handshake, stubbed.
mcp_resolve_creds() { _mcp_user=mcp_readonly; _mcp_password=x; }
mcp_ssl_cert_validation() { printf 'no\n'; }
require_python3() { :; }
ui_spin_begin() { :; }; ui_spin_end() { :; }
mcp_print_handshake_detail() { :; }
sleep() { :; }
detect_cpu_advertises_sve() { return 0; }
detect_sve_remedy_hint() { printf 'HINT turn SVE off at boot\n'; }
# The server: a plain run answers from the PLAIN_ANSWERS list (one per call), a
# run with OPENSSL_armcap=0 always answers.
mcp_stdio_handshake_once() {
    [ "${OPENSSL_armcap:-}" = 0 ] && return 0
    _n="$(cat "$WORK/plain-calls" 2>/dev/null || echo 0)"; _n=$((_n + 1)); echo "$_n" > "$WORK/plain-calls"
    [ "$(printf '%s\n' $PLAIN_ANSWERS | sed -n "${_n}p")" = ok ]
}

run() { # run <plain answers...> -> what mcp_validate said and recorded
    rm -f "$WORK/plain-calls" "$EXAKIT_HOME/manifest.json"
    manifest_init >/dev/null 2>&1
    PLAIN_ANSWERS="$*"
    mcp_validate > "$WORK/out.txt" 2>&1
    printf 'workaround=%s hint=%s\n' "$(manifest_get components.mcp_server.openssl_armcap_workaround 2>/dev/null || printf none)" \
        "$(grep -c 'HINT' "$WORK/out.txt")"
}

echo "faked SVE: the plain server never answers, the override does"
check "the override is recorded and the hint given" "workaround=true hint=1" "$(run fail fail fail)"

echo "real SVE, a first failure for another reason: the plain server answers on the third try"
check "nothing is recorded and SVE is not blamed" "workaround=none hint=0" "$(run fail fail ok)"
grep -q "the first failure was not the CPU" "$WORK/out.txt" && check "...and it says so" yes yes || check "...and it says so" yes no

echo ""
echo "mcp-sve.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
