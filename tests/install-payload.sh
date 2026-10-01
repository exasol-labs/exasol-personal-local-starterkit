#!/usr/bin/env bash
# Guard the size of what `curl | sh` actually downloads.
#
# install.sh fetches the repo as a GitHub source archive (built with
# `git archive`, so .gitattributes export-ignore applies) and only then can it
# print the banner - setup/lib/ui.sh does not exist until the download lands.
# Every byte in that archive is therefore dead time in front of a user who has
# so far seen one line of output.
#
# A 24 MB demo video once sat in static/ and nothing in the kit ever read it:
# 78% of the download, spent before the wordmark appeared. It is still in the
# repo (it is documentation) and is kept out of the archive with export-ignore.
#
# The obvious wrong way to pass this test is to export-ignore something the
# install genuinely needs, so section 3 asserts the payload is still complete.
# Run:
#
#   bash tests/install-payload.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

# The archive the installer downloads, as GitHub builds it.
listing="$(git archive HEAD | tar -t)" || {
    printf 'FAIL could not build the source archive with git archive\n'
    exit 1
}
bytes="$(git archive --format=tar.gz HEAD | wc -c | tr -d ' ')"
mb=$((bytes / 1048576))

# 1. Budget. The install payload is scripts plus the bundled datasets (~7 MB).
#    This is a ceiling to catch a heavy asset riding along unnoticed, not a
#    target - if a dataset legitimately grows, raise it deliberately.
budget_mb=12
if [ "$mb" -le "$budget_mb" ]; then
    pass "source archive is ${mb} MB (budget ${budget_mb} MB)"
else
    fail "source archive is ${mb} MB, over the ${budget_mb} MB budget - every byte here is pre-banner wait in curl | sh; export-ignore what the install does not read"
fi

# 2. Media never belongs in the install payload. Nothing in the kit plays it.
media="$(printf '%s\n' "$listing" | grep -Ei '\.(mp4|mov|avi|webm|mkv|gif|psd|zip)$' || true)"
if [ -z "$media" ]; then
    pass "no media files in the source archive"
else
    fail "media in the source archive (export-ignore these in .gitattributes): $(printf '%s' "$media" | tr '\n' ' ')"
fi

# 3. Completeness. export-ignore is a loaded gun pointed at the installer: an
#    over-broad pattern silently ships a kit that cannot install. Assert the
#    things install.sh and the setup scripts actually open are still present.
for needed in \
    install.sh \
    install.ps1 \
    versions.json \
    setup/setup-macos.sh \
    setup/setup-linux.sh \
    setup/lib/ui.sh \
    setup/lib/detect.sh \
    setup/lib/help.sh \
    setup/help/exakit.json \
    setup/help/exapump.json \
    setup/exakit \
    data/datasets/tpch/data/lineitem.csv
do
    if printf '%s\n' "$listing" | grep -qxF "$needed"; then
        pass "archive contains $needed"
    else
        fail "archive is MISSING $needed - the install cannot work; check the export-ignore patterns in .gitattributes"
    fi
done

# --- the installer and the kit can come from different places ----------------
# install.sh / install.ps1 are read from a URL, but the KIT they unpack comes
# from EXAKIT_REPO, which defaults to the upstream repository whatever URL the
# installer was read from. Fetching a fork's installer therefore installs the
# UPSTREAM kit, and when the two layouts differ the handoff used to die on the
# shell's own "does not exist" - a path, with no hint that two repositories
# were in play. Two people hit exactly that in one morning.
for _guard in install.sh install.ps1; do
    _body="$(cat "$ROOT/$_guard")"
    case "$_body" in
        *"do not match"*) pass "$_guard names the mismatch instead of a bare path" ;;
        *) fail "$_guard still lets the handoff fail on a missing setup script" ;;
    esac
    case "$_body" in
        *EXAKIT_REPO*EXAKIT_REF*) pass "$_guard names the two variables that fix it" ;;
        *) fail "$_guard does not say how to point the kit at the same place" ;;
    esac
done

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
