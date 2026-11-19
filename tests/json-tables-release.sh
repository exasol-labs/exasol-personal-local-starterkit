#!/usr/bin/env bash
# json-tables-release.sh — proves the json-tables release model: one immutable
# release per build, and versions.json as the ONLY authority on what gets
# installed.
#
# The failure this guards (2026-09-03): the prebuilt engine was served from a
# single rolling release with unversioned filenames. Upstream shipped v0.3, the
# packaging workflow overwrote the v0.2 binaries in place, and every install of
# the add-on failed on `Checksum mismatch` because versions.json still pinned
# the v0.2 digests -- while the install read the VERSION off the release body,
# so the log said "Installing JSON Tables v0.3" over a v0.2 wheel pin.
#
# Two halves, both load-bearing:
#   1. the module reads release tag, wheel and digests from versions.json for
#      the advertised build, applies those pins to NO other build, and needs no
#      network call to say which version is installable;
#   2. the packaging workflow publishes to a tag that carries the version,
#      refuses to overwrite an existing release, and writes the whole pin into
#      versions.json in its advertise pull request.
#
# Pure logic against a sandboxed kit home: no network (curl is stubbed to fail
# loudly), no installs.
#
#   bash tests/json-tables-release.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac
}

lacks() { # lacks <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac
}

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 is needed for the JSON Tables release checks"
    exit 0
fi

WF="$ROOT/.github/workflows/pkg-json-tables.yml"
CI="$ROOT/.github/workflows/versions.yml"

pin="$(python3 - "$ROOT/versions.json" <<'PYJSON'
import json, sys
block = json.load(open(sys.argv[1], encoding="utf-8"))["components"]["json-tables"]
print(block["version"], block["release"], block["wheel"],
      " ".join(sorted(block["sha256"])), sep="|")
PYJSON
)"
IFS='|' read -r PIN_VERSION PIN_RELEASE PIN_WHEEL PIN_KEYS <<< "$pin"
case "$PIN_RELEASE" in
    "json-tables-$PIN_VERSION"|"json-tables-$PIN_VERSION-"[0-9]*) check "release tag carries the advertised version" yes yes ;;
    *) check "release tag carries the advertised version" yes no ;;
esac
check "the wheel is pinned" yes "$([ -n "$PIN_WHEEL" ] && echo yes || echo no)"
check "all published assets have digests"     "cargo-windows-x86_64 linux-aarch64 linux-x86_64 macos-aarch64 wheel windows-x86_64" "$PIN_KEYS"

if python3 -m unittest discover -s "$ROOT/tests" -p test_marketplace_json_tables.py >/dev/null 2>&1; then
    check "Python release and shim contracts pass" yes yes
else
    check "Python release and shim contracts pass" yes no
fi

echo "the packaging workflow publishes immutably:"
_wf="$(cat "$WF")"
lacks "never to a fixed tag" "tag_name: mirror-json-tables" "$_wf"
has "the tag comes from the check job and carries the version" 'tag_name: ${{ needs.check.outputs.tag }}' "$_wf"
has "the tag is json-tables-<version>" 'tag="json-tables-$sha"' "$_wf"
has "already-published is the change gate" 'release_exists "$tag"' "$_wf"
has "a forced rebuild gets a suffixed tag, not an overwrite" 'tag="$tag-$n"' "$_wf"
has "publish refuses an existing release" "refuse to overwrite a published release" "$_wf"
has "every artefact must be uploaded or the publish fails" "fail_on_unmatched_files: true" "$_wf"
has "advertise pins the release tag" 'block["release"] = tag' "$_wf"
has "advertise pins the wheel name" 'block["wheel"] = wheel' "$_wf"
has "advertise pins every digest from the published files" 'hashlib.sha256(path.read_bytes())' "$_wf"
has "advertise runs only after publish" "needs: [check, publish]" "$_wf"

echo "CI refuses a pin that does not match the named release:"
_ci="$(cat "$CI")"
lacks "CI no longer looks at the rolling tag" "releases/tags/mirror-json-tables" "$_ci"
has "the named release must exist" 'json-tables: release %s does not exist' "$_ci"
has "every pinned digest is compared with the published one" 'json-tables: sha256.%s pins %s but %s on %s is %s' "$_ci"
has "the release must belong to the advertised version" 'does not belong to version' "$_ci"
has "this suite is wired into CI" "bash tests/json-tables-release.sh" "$_ci"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
