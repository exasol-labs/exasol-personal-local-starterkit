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
    echo "SKIP: python3 is needed to read the pins out of versions.json"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Sandbox first: common.sh derives its paths at source time.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
HOME="$WORK/fake-home"
export HOME
mkdir -p "$EXAKIT_HOME/cache" "$EXAKIT_BIN_DIR" "$HOME"

# The versions document under test is the repository's own, so every
# expectation below moves with the pin instead of hardcoding a build.
cp "$ROOT/versions.json" "$WORK/versions.json"
EXAKIT_VERSIONS_CACHE="$WORK/versions.json"
export EXAKIT_VERSIONS_CACHE
EXAKIT_NO_FANCY=1; export EXAKIT_NO_FANCY

. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/json-tables.sh"

pin() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["components"]["json-tables"]
for p in sys.argv[2].split("."): d=d[p]
print(d)' "$WORK/versions.json" "$1"; }
PIN_VERSION="$(pin version)"
PIN_RELEASE="$(pin release)"
PIN_WHEEL="$(pin wheel)"
PIN_MAC="$(pin sha256.macos-aarch64)"

# No network, ever, in this suite. A call that reaches curl is itself a failure.
curl() { printf 'NETWORK-CALL\n' >&2; return 7; }

WF="$ROOT/.github/workflows/pkg-json-tables.yml"
CI="$ROOT/.github/workflows/versions.yml"

echo "the pin itself:"
case "$PIN_RELEASE" in
    "json-tables-$PIN_VERSION"|"json-tables-$PIN_VERSION-"[0-9]*) check "release tag carries the advertised version" "yes" "yes" ;;
    *) check "release tag carries the advertised version ($PIN_RELEASE vs $PIN_VERSION)" "yes" "no" ;;
esac
lacks "the release is not the old rolling tag" "mirror-json-tables" "$PIN_RELEASE"
check "the wheel is pinned by name" "yes" "$( [ -n "$PIN_WHEEL" ] && echo yes || echo no )"
check "six digests, keyed by platform" "cargo-windows-x86_64 linux-aarch64 linux-x86_64 macos-aarch64 wheel windows-x86_64" \
    "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["components"]["json-tables"]["sha256"])))' "$WORK/versions.json")"

echo "the advertised build reads everything from versions.json, with no network:"
_out="$( ( json_tables_release_tag ) 2>&1 )"
check "release tag" "$PIN_RELEASE" "$_out"
_out="$( ( _json_tables_mirror_asset_url exasol-json-tables-ingest-macos-aarch64 ) 2>&1 )"
check "asset URL points at the pinned release" \
    "https://github.com/$(json_tables_mirror_repo)/releases/download/$PIN_RELEASE/exasol-json-tables-ingest-macos-aarch64" "$_out"
_out="$( ( _json_tables_mirror_digest exasol-json-tables-ingest-macos-aarch64 ) 2>&1 )"
check "engine digest is the pinned one" "$PIN_MAC" "$_out"
_out="$( ( _json_tables_mirror_wheel_name ) 2>&1 )"
check "wheel name is the pinned one" "$PIN_WHEEL" "$_out"
_out="$( ( json_tables_latest ) 2>&1 )"
check "latest is the advertised version" "$PIN_VERSION" "$_out"
_out="$( ( _json_tables_target_version ) 2>&1 )"
check "the install targets the advertised version" "$PIN_VERSION" "$_out"
# The whole section above must have made no network call: the digest and the
# wheel name are what used to cost three API requests per install.
_out="$( ( json_tables_release_tag; _json_tables_mirror_digest exasol-json-tables-ingest-macos-aarch64; _json_tables_mirror_wheel_name; json_tables_latest ) 2>&1 )"
lacks "none of it touched the network" "NETWORK-CALL" "$_out"

echo "a build chosen by hand never borrows the advertised build's pins:"
# This is the exact shape of the 2026-09-03 failure, inverted: a digest that
# describes one build must never be checked against the bytes of another.
_out="$( ( EXAKIT_JSON_TABLES_VERSION=v9.9; json_tables_release_tag ) 2>&1 )"
check "its release tag is derived from ITS version" "json-tables-v9.9" "$_out"
_out="$( ( EXAKIT_JSON_TABLES_VERSION=v9.9; _json_tables_mirror_release() { return 1; }; _json_tables_mirror_digest exasol-json-tables-ingest-macos-aarch64 ) 2>&1 )"
lacks "the advertised digest is not applied to it" "$PIN_MAC" "$_out"
check "so with its release unreachable there is no digest at all" "" "$_out"
_out="$( ( EXAKIT_JSON_TABLES_VERSION=v9.9; _json_tables_mirror_release() { return 1; }; _json_tables_mirror_wheel_name ) 2>&1 )"
lacks "nor the advertised wheel name" "$PIN_WHEEL" "$_out"
_out="$( ( EXAKIT_JSON_TABLES_VERSION=v9.9; _json_tables_mirror_release() { return 1; }
           fetch_quiet() { : > "$2"; }
           _json_tables_fetch_verified exasol-json-tables-ingest-macos-aarch64 "$WORK/engine" && echo ACCEPTED || echo refused
           [ -e "$WORK/engine" ] && echo LEFT-BEHIND || echo cleaned ) 2>&1 )"
has "and an unverifiable artefact is refused" "refused" "$_out"
has "with the download removed" "cleaned" "$_out"
lacks "never accepted" "ACCEPTED" "$_out"
_out="$( ( EXAKIT_JSON_TABLES_VERSION=v9.9; _json_tables_target_version ) 2>&1 )"
check "an explicit version is the one installed" "v9.9" "$_out"

echo "the release tag is versions.json's to name:"
_out="$( ( EXAKIT_JSON_TABLES_MIRROR_TAG=hand-picked-tag; json_tables_release_tag ) 2>&1 )"
check "an explicit tag overrides everything" "hand-picked-tag" "$_out"
# A forced rebuild of the same upstream version publishes json-tables-<v>-2; the
# advertise PR records that exact tag, and the module must follow it rather
# than deriving json-tables-<v> and downloading the superseded build.
sed "s|\"release\": \"$PIN_RELEASE\"|\"release\": \"json-tables-$PIN_VERSION-2\"|" "$WORK/versions.json" > "$WORK/rebuilt.json"
_out="$( ( EXAKIT_VERSIONS_CACHE="$WORK/rebuilt.json"; _EXAKIT_VERSIONS_DOC=""; json_tables_release_tag ) 2>&1 )"
check "a rebuild suffix in the pin is honoured" "json-tables-$PIN_VERSION-2" "$_out"
# An older document (or a hand edit) without the field still resolves: the tag
# is derived from the version, which is what the workflow names it anyway.
python3 - "$WORK/versions.json" "$WORK/norelease.json" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1]), object_pairs_hook=collections.OrderedDict)
del d["components"]["json-tables"]["release"]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
_out="$( ( EXAKIT_VERSIONS_CACHE="$WORK/norelease.json"; _EXAKIT_VERSIONS_DOC=""; json_tables_release_tag ) 2>&1 )"
check "without the field the tag is derived from the version" "json-tables-$PIN_VERSION" "$_out"
_out="$( ( EXAKIT_VERSIONS_CACHE="$WORK/rebuilt.json"; _EXAKIT_VERSIONS_DOC=""; _json_tables_mirror_cache_file ) 2>&1 )"
has "the release document cache is keyed by tag" "json-tables-$PIN_VERSION-2" "$_out"

echo "the module no longer reads a version off a release body:"
lacks "no release-body version parser" "_json_tables_mirror_version" "$(cat "$ROOT/setup/lib/json-tables.sh")"
lacks "and none on the PowerShell side" "Get-JsonTablesMirrorVersion" "$(cat "$ROOT/setup/lib/json-tables.ps1")"
lacks "no fixed rolling tag in the shell module" '"mirror-json-tables"' "$(cat "$ROOT/setup/lib/json-tables.sh")"
lacks "no fixed rolling tag in the PowerShell module" '"mirror-json-tables"' "$(cat "$ROOT/setup/lib/json-tables.ps1")"
for _twin in Get-JsonTablesTargetVersion Test-JsonTablesPinApplies Get-JsonTablesReleaseTag; do
    has "PowerShell twin $_twin exists" "function $_twin" "$(cat "$ROOT/setup/lib/json-tables.ps1")"
done

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
