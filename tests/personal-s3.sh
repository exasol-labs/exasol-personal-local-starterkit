#!/usr/bin/env bash
# Hermetic S3-first launcher tests. No network, launcher execution or deployment.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXAKIT_BIN_DIR="$WORK/bin"
EXAKIT_PERSONAL_VERSION=2.3.0
EXAKIT_PERSONAL_REPO=exasol/exasol-personal
EXAKIT_FORCE_COMPONENT_INSTALL=1
EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/deployment"
. "$ROOT/setup/lib/runtime-personal.sh"

PASS=0
FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); printf 'FAIL %s: expected <%s>, got <%s>\n' "$1" "$2" "$3" >&2
    fi
}
manifest_version=2.3.0
pin="$(printf good-s3 | shasum -a 256 | awk '{print $1}')"
exakit_versions_value() {
    case "$1" in
        components.personal.version) printf '%s\n' "$manifest_version" ;;
        components.personal.s3.base_url) printf '%s\n' 'https://example.test/personal' ;;
        components.personal.s3.sha256.macos-arm64) printf '%s\n' "$pin" ;;
        components.personal.s3.sha256.linux-arm64) printf '%s\n' "$pin" ;;
    esac
}
detect_os() { printf 'macos\n'; }
detect_arch() { printf 'arm64\n'; }
info() { :; }
ok() { :; }
warn() { :; }
_exakit_log_file() { :; }
ui_tilde() { printf '%s\n' "$1"; }
push_rollback() { :; }
ensure_path_hint() { :; }
exakit_reuse_ownership() { :; } # these download fixtures represent a kit-owned launcher
exakit_component_is_managed() { return 0; }
exakit_record_ownership() { :; }
personal_refuse_launcher_downgrade() { :; }
exakit_run_bounded() { return 0; }
exakit_unsigned_binary_hint() { return 1; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
verify_sha256_from_file() {
    expected="$(awk '{print $1}' "$2")"
    [ "$(sha256_of "$1")" = "$expected" ] || return 1
}
run_logged() { mkdir -p "$_tmp/release"; printf 'github-bin' > "$_tmp/release/exasol"; }
mode=success
s3_calls=0
github_calls=0
fetch_soft() {
    s3_calls=$((s3_calls + 1))
    case "$mode" in
        success) printf good-s3 > "$2" ;;
        mismatch) printf bad-s3 > "$2" ;;
        fail) return 1 ;;
    esac
}
fetch() {
    github_calls=$((github_calls + 1))
    case "$2" in
        */checksums.txt)
            archive="$(find "$_tmp" -name '*.tar.gz' -type f | head -1)"
            printf '%s  %s\n' "$(sha256_of "$archive")" "$(basename "$archive")" > "$2"
            ;;
        *) printf 'archive' > "$2" ;;
    esac
}

source_record="$(personal_s3_source)"
check 'S3 path uses version and native OS/arch' \
    'https://example.test/personal/macos/arm64/2.3.0/exasol' "${source_record%%$'\n'*}"
check 'S3 pin is the raw binary pin' "$pin" "${source_record##*$'\n'}"
detect_os() { printf 'wsl\n'; }
check 'WSL uses Linux S3 path' 'https://example.test/personal/linux/arm64/2.3.0/exasol' \
    "$(personal_s3_source | head -1)"
detect_os() { printf 'macos\n'; }

personal_install_launcher
check 'S3 success avoids GitHub' 0 "$github_calls"
check 'S3 raw binary installed' good-s3 "$(cat "$EXAKIT_PERSONAL_BIN")"

mode=mismatch
personal_install_launcher
check 'checksum mismatch downloads GitHub archive and checksums' 2 "$github_calls"
check 'unverified S3 binary never installed' github-bin "$(cat "$EXAKIT_PERSONAL_BIN")"

mode=fail
personal_install_launcher
check 'S3 transfer failure falls back' 4 "$github_calls"
check 'GitHub binary installed after S3 failure' github-bin "$(cat "$EXAKIT_PERSONAL_BIN")"

EXAKIT_PERSONAL_VERSION=2.4.0
before="$s3_calls"
personal_install_launcher
check 'different target version skips stale S3 pin' "$before" "$s3_calls"
check 'different target version still uses GitHub' 6 "$github_calls"

# The opt-out: a network that blocks the bucket, or a user who wants the
# release path, sets EXAKIT_PERSONAL_S3=0 and S3 is never asked, for any
# version. The GitHub path is as verified, so nothing is lost.
EXAKIT_PERSONAL_VERSION=2.3.0
check 'EXAKIT_PERSONAL_S3=0 builds no S3 source' 1 "$(EXAKIT_PERSONAL_S3=0 personal_s3_source >/dev/null 2>&1; echo $?)"
mode=success
before="$s3_calls"
EXAKIT_PERSONAL_S3=0 personal_install_launcher
check 'EXAKIT_PERSONAL_S3=0 never touches S3' "$before" "$s3_calls"
check '...and installs the verified GitHub binary' github-bin "$(cat "$EXAKIT_PERSONAL_BIN")"
check '...after the archive and its checksums' 8 "$github_calls"

# The real fetch_soft, not the stub above: a miss must come back as a return
# code with no failure note, or every S3 miss that fell back to GitHub would
# leave exakit status reporting "Could not download exasol" as a failed step.
# A closed local port stands in for an unreachable bucket; nothing leaves the
# machine. Run in a subshell so common.sh cannot replace the stubs above.
note_verdict="$(
    HOME="$WORK/note-home" EXAKIT_HOME="$WORK/note-home/kit" EXAKIT_LOG_FILE="$WORK/note-home/log" \
    NO_COLOR=1 EXAKIT_NO_FANCY=1 bash -c '
        mkdir -p "$EXAKIT_HOME"
        . "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
        fetch_soft "https://127.0.0.1:9/personal/exasol" "$EXAKIT_HOME/../exasol" >/dev/null 2>&1
        rc=$?
        if [ -f "$EXAKIT_HOME/.last-failure" ]; then note=written; else note=none; fi
        printf "rc=%s note=%s" "$rc" "$note"'
)"
check 'a missed soft fetch is a return code with no failure note' 'rc=1 note=none' "$note_verdict"

# The soft download's budget is the short one: one retry of a transient error
# and none of a hard one, a 10 s handshake cap and a 20 s stall cap, where
# the hard fetch keeps its four tries and --retry-all-errors. A fake curl on
# PATH records the flags it was given; it also answers the capability probe
# (`curl --help all`) as a curl that knows --retry-all-errors, so the hard
# path has something to drop.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/curl" <<'FAKE'
#!/bin/sh
case "$1" in --help) echo "--retry-all-errors"; exit 0 ;; esac
# The count first, then one [argument] per line: a quoted "--retry 1" would
# show as one line, and an empty argument (a quoted empty variable, which curl
# would take for a URL) as [].
{ printf 'argc=%s\n' "$#"; for a in "$@"; do printf '[%s]\n' "$a"; done; } > "${FAKE_CURL_ARGS:?}"
exit 7
FAKE
chmod +x "$WORK/fakebin/curl"
_curl_flags() { # _curl_flags <soft|hard> -> the flags the fetch handed to curl, one per line
    PATH="$WORK/fakebin:$PATH" FAKE_CURL_ARGS="$WORK/curl.$1.args" \
    HOME="$WORK/note-home" EXAKIT_HOME="$WORK/note-home/kit" EXAKIT_LOG_FILE="$WORK/note-home/log" \
    NO_COLOR=1 EXAKIT_NO_FANCY=1 bash -c '
        mkdir -p "$EXAKIT_HOME"
        . "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
        if [ "'"$1"'" = soft ]; then fetch_soft "https://example.invalid/x" "$EXAKIT_HOME/../x"
        else fetch_quiet "https://example.invalid/x" "$EXAKIT_HOME/../x"; fi' >/dev/null 2>&1
    cat "$WORK/curl.$1.args"
}
soft_args="$(_curl_flags soft)"
hard_args="$(_curl_flags hard)"
soft_flags="$(printf '%s\n' "$soft_args" | tr -d '[]' | tr '\n' ' ')"
hard_flags="$(printf '%s\n' "$hard_args" | tr -d '[]' | tr '\n' ' ')"
case "$soft_flags" in *"--retry 1 "*"--connect-timeout 10 "*"--speed-time 20 "*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL the soft fetch takes the short budget: got <%s>\n' "$soft_flags" >&2 ;; esac
case "$soft_flags" in *"--retry-all-errors"*) FAIL=$((FAIL + 1)); printf 'FAIL ...and does not retry hard errors: got <%s>\n' "$soft_flags" >&2 ;; *) PASS=$((PASS + 1)) ;; esac
case "$hard_flags" in *"--retry 3 "*"--retry-all-errors "*"--connect-timeout 15 "*"--speed-time 60 "*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL the hard fetch keeps its full budget: got <%s>\n' "$hard_flags" >&2 ;; esac
# The words reach curl as separate arguments and never as an empty one: a
# quoted "$_fetch_retry" would hand curl the one argument "--retry 1" (which it
# refuses) and a quoted empty "$_fetch_retry_all" an empty argument (which it
# takes for a URL), and the folded flags above would still read right.
check 'the soft fetch hands curl 17 arguments' 'argc=17' "$(printf '%s\n' "$soft_args" | sed -n 1p)"
check '...--retry and 1 as two of them' 'yes' "$(printf '%s\n' "$soft_args" | grep -qx '\[--retry\]' && printf '%s\n' "$soft_args" | grep -qx '\[1\]' && echo yes || echo no)"
check '...and none of them empty' '0' "$(printf '%s\n' "$soft_args" | grep -cx '\[\]')"
check 'the hard fetch hands curl 18 arguments' 'argc=18' "$(printf '%s\n' "$hard_args" | sed -n 1p)"
check '...and none of them empty' '0' "$(printf '%s\n' "$hard_args" | grep -cx '\[\]')"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
