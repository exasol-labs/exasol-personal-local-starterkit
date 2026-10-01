#!/usr/bin/env bash
# versions-manifest.sh — proves the versions.json contract.
#
# versions.json is the maintainer-edited record of the tested version set, so
# every machine reads it and no machine may be broken by it. This test covers
# the four promises the readers make:
#
#   1. the shipped document is accepted, and a corrupt, newer-schema, or
#      unsafely-typed one is refused (a version lands in a download URL);
#   2. the Python reader and the no-Python awk fallback return the SAME values
#      (that agreement is what the formatting invariants exist for);
#   3. a failed or invalid fetch never loses a good cached copy, and the TTL
#      keeps normal commands off the network;
#   4. resolution degrades fetch -> cache -> baked kit copy -> fallback and
#      never fails a command.
#
# It also covers what install-time resolution does with those answers, and the
# rule that pyexasol — the last, optional Component — can never end a run.
#
# No installs, no network: the fetch is a stubbed curl, and resolution runs
# against a deliberately non-HTTPS endpoint (refused before any connection).
#
#   bash tests/versions-manifest.sh

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixtures"
mkdir -p "$FIX"

# The kit home is redirected for the whole run: nothing here may touch a real
# installation. common.sh derives its paths at source time, so this comes first.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"

REAL="$ROOT/versions.json"

# shipped <dotted.path> - a value straight out of the shipped document, read with
# plain json.load rather than either of the kit's readers.
#
# Nothing here may hardcode what versions.json currently says. A version bump is
# meant to be a one-file pull request, and every literal copied out of that file
# turns it into a two-file one -- which is exactly what happened: the first
# automated bump PR failed 15 checks that were only asserting the old numbers
# back at themselves. What these tests actually owe you is that the two readers
# agree with each other and with the document, whatever it holds today.
shipped() {
    python3 - "$REAL" "$1" <<'SHIPPED_PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    node = node[part]
print(node)
SHIPPED_PY
}

# --- fixtures ----------------------------------------------------------------
# Variants are derived from the shipped document so they keep its canonical
# shape; only the property under test differs.
#
# A derived fixture is worth something only while it actually DIFFERS from what it
# came from, and a rewrite that stops matching does not say so: it copies the
# document straight through and every check downstream keeps passing with its
# premise deleted. So two rules hold for everything below.
#
# 1. Synthetic versions are out of reach of any release -- major 99, year 2099, or
#    a 0.0.x floor -- never the next plausible number. The synthetic exapump in the
#    cache and notice fixtures used to be 0.12.0, one routine release above what the
#    document advertised, and versions-bump.yml runs daily and does not edit tests.
# 2. Every rewrite proves it changed something. That is the half that survives the
#    next person picking a plausible-looking literal: the fixture fails loudly
#    instead of quietly becoming a copy of the document it was derived from.

# derive <sed-expression> <source> <destination> — a sed-derived fixture that must
# not come out byte-identical to its source.
derive() {
    sed "$1" "$2" > "$3"
    if cmp -s "$2" "$3"; then
        _dv_state="NO-OP: $1 matched nothing in $2"
    else
        _dv_state="differs"
    fi
    check "fixture $(basename "$3")" "differs" "$_dv_state"
}

# fixture_doc <label> <destination> <dotted.path=value>... — a fixture document
# built from the SHIPPED versions.json with the named paths replaced.
#
# Paths are addressed by key, never by matching the text that happens to be there,
# so a rewrite cannot silently half-apply. A *.version replacement must also CHANGE
# the value: every version fixture in this file exists in order to differ from the
# shipped set, so one the document has caught up with is a broken fixture, not a
# passing test. Other properties (severity, note) may legitimately already agree.
fixture_doc() {
    _fx_label="$1"
    _fx_dest="$2"
    shift 2
    check "fixture $_fx_label" "rewritten" \
        "$(python3 - "$REAL" "$_fx_dest" "$@" 2>&1 <<'FIXTURE_PY'
import collections, json, sys
with open(sys.argv[1]) as handle:
    doc = json.load(handle, object_pairs_hook=collections.OrderedDict)
for spec in sys.argv[3:]:
    path, _, value = spec.partition("=")
    keys = path.split(".")
    node = doc
    for key in keys[:-1]:
        node = node.setdefault(key, collections.OrderedDict())
    if keys[-1] == "version" and node.get(keys[-1]) == value:
        sys.exit("NO-OP: the shipped document already says %s = %s -- this fixture "
                 "needs a version no release can reach" % (path, value))
    node[keys[-1]] = value
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
print("rewritten")
FIXTURE_PY
)"
}

echo "fixtures (a derived variant must really differ from what it came from):"
derive 's/"schema_version": 1/"schema_version": 2/' "$REAL" "$FIX/schema2.json"
python3 - "$REAL" "$FIX/bad-charset.json" <<'CHARSET_PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["components"]["exapump"]["version"] += " rm -rf /"
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
CHARSET_PY
derive 's/"macos-aarch64": "[0-9a-f]*"/"macos-aarch64": "nothexnothexnothex"/' \
    "$REAL" "$FIX/bad-digest.json"
printf 'this is not json\n' > "$FIX/corrupt.json"
printf '[{"schema_version": 1}]\n' > "$FIX/array.json"
cat > "$FIX/no-kit.json" <<'EOF'
{
  "schema_version": 1,
  "components": {
    "mcp": {
      "version": "1.10.1"
    }
  }
}
EOF
# The kit2 block is optional and additive: a document carrying it must still
# validate on a client that predates Kit 2 support.
cat > "$FIX/kit2.json" <<'EOF'
{
  "schema_version": 1,
  "updated": "2026-07-29",
  "kit": {
    "version": "0.2.0"
  },
  "components": {
    "mcp": {
      "version": "1.10.1",
      "package": "exasol-mcp-server",
      "severity": "normal"
    }
  },
  "kit2": {
    "version": "0.1.0",
    "min_kit_version": "0.2.0",
    "severity": "recommended",
    "note": "Trusted AI Workflow add-on"
  }
}
EOF
derive 's/"version": "0.1.0"/"version": "0.1.0 evil"/' "$FIX/kit2.json" "$FIX/kit2-bad.json"

# no_python <command...> — run one reader with every Python route closed, so
# the awk fallback is the only thing that can answer.
no_python() (
    EXAKIT_DISABLE_SYSTEM_PYTHON=1
    exakit_ensure_uv() { return 1; }
    "$@"
)

# validate_rc <file> — validation exit code (0 ok, 2 newer schema, 1 refused).
validate_rc() {
    exakit_versions_validate "$1" >/dev/null 2>&1
    printf '%s\n' "$?"
}

# both_rc <label> <expected> <file> — the gate must agree with and without Python.
both_rc() {
    check "$1 (python)" "$2" "$(validate_rc "$3")"
    check "$1 (no python)" "$2" "$(no_python validate_rc "$3")"
}

# both_value <label> <expected> <dot.path> [file] — same for the reader.
both_value() {
    _bv_file="${4:-}"
    check "$1 (python)" "$2" "$(exakit_versions_value "$3" "$_bv_file" 2>/dev/null || printf 'absent')"
    check "$1 (no python)" "$2" "$(no_python exakit_versions_value "$3" "$_bv_file" 2>/dev/null || printf 'absent')"
}

echo "validation gate:"
both_rc "shipped versions.json" 0 "$REAL"
both_rc "newer schema" 2 "$FIX/schema2.json"
both_rc "version outside the safe charset" 1 "$FIX/bad-charset.json"
both_rc "digest that is not 64 hex chars" 1 "$FIX/bad-digest.json"
both_rc "no kit block" 1 "$FIX/no-kit.json"
both_rc "not json at all" 1 "$FIX/corrupt.json"
both_rc "an array instead of one object" 1 "$FIX/array.json"
both_rc "missing file" 1 "$WORK/does-not-exist.json"
both_rc "optional kit2 block" 0 "$FIX/kit2.json"
both_rc "kit2 version outside the charset" 1 "$FIX/kit2-bad.json"
schema_ahead="$( exakit_versions_validate "$FIX/schema2.json" >/dev/null 2>&1
                 if exakit_versions_schema_ahead; then printf yes; else printf no; fi )"
check "newer schema is reported as ahead" "yes" "$schema_ahead"

echo "reader (Python and the awk fallback must agree):"
for _path in kit.version components.personal.version components.personal.severity \
             components.exapump.version components.mcp.version \
             components.mcp.package components.pyexasol.version \
             components.dash-server.version components.dash-server.repo \
             components.dbt-exasol.version components.dbt-exasol.package \
             components.exasol-vscode.version components.exasol-vscode.sha256.vsix \
             components.exapump.sha256.macos-aarch64 \
             components.exapump.sha256.windows-x86_64; do
    both_value "$_path" "$(shipped "$_path")" "$_path" "$REAL"
done
both_value "unknown component" "absent" components.nope.version "$REAL"
both_value "kit2 absent from the shipped document" "absent" kit2.version "$REAL"
both_value "kit2.version" "0.1.0" kit2.version "$FIX/kit2.json"
both_value "kit2.min_kit_version" "0.2.0" kit2.min_kit_version "$FIX/kit2.json"
both_value "kit2.note" "Trusted AI Workflow add-on" kit2.note "$FIX/kit2.json"
both_value "severity" "recommended" kit2.severity "$FIX/kit2.json"

echo "kit copy (what 'installed' means for the kit itself):"
mkdir -p "$EXAKIT_HOME/kit/mcp"
cp "$REAL" "$EXAKIT_HOME/kit/versions.json"
check "baked document is the kit copy" "$EXAKIT_HOME/kit/versions.json" "$(exakit_versions_baked_doc)"
V_KIT="$(shipped kit.version)"
check "kit bundled version" "$V_KIT" "$(exakit_kit_bundled_version)"
check "kit bundled version (no python)" "$V_KIT" "$(no_python exakit_kit_bundled_version)"
check "user agent" "exakit-update-check/$V_KIT" "$(exakit_versions_user_agent | cut -d' ' -f1)"
printf 'garbage\n' > "$EXAKIT_HOME/kit/versions.json"
check "unreadable kit copy is not a version" "absent" \
    "$(exakit_kit_bundled_version 2>/dev/null || printf absent)"
cp "$REAL" "$EXAKIT_HOME/kit/versions.json"

echo "resolution chain (a command must never fail over a version lookup):"
EXAKIT_VERSIONS_CACHE="$EXAKIT_HOME/cache/versions.json"
check "no cache -> baked kit copy" "baked" "$( exakit_versions_source )"
V_BAKED_EXAPUMP="$(shipped components.exapump.version)"
check "baked value is readable" "$V_BAKED_EXAPUMP" "$( exakit_versions_value components.exapump.version )"
mkdir -p "$EXAKIT_HOME/cache"
# A sentinel, not a plausible version: it has to be impossible for the cached
# answer to coincide with the baked one, or this proves nothing.
V_CACHED_EXAPUMP="0.0.0-from-the-cache"
fixture_doc "cached exapump sentinel" "$EXAKIT_VERSIONS_CACHE" \
    "components.exapump.version=$V_CACHED_EXAPUMP"
check "cache wins over the kit copy" "cache" "$( exakit_versions_source )"
check "cached value is used" "$V_CACHED_EXAPUMP" "$( exakit_versions_value components.exapump.version )"
printf 'corrupted by hand\n' > "$EXAKIT_VERSIONS_CACHE"
check "unreadable cache falls back to the kit copy" "baked" "$( exakit_versions_source )"
check "kit copy answers again" "$V_BAKED_EXAPUMP" "$( exakit_versions_value components.exapump.version )"
# A CACHE OLDER THAN THE KIT MUST NOT DOWNGRADE IT. Reported from a Windows
# machine: a cache left by an earlier kit advertised launcher 2.2.0, the fetch
# could not reach the network, and the cache stood - so the installer fetched
# 2.2.0, a launcher with no Windows local deployment in it. Podman is the
# launcher's job and only from 2.3.0, so nothing installed it, and the run died
# on the launcher's own gate ("local deployments are only supported on macOS
# Apple Silicon"). The cache is a memo about what was current last time; it
# cannot outrank the document that travelled with the code now running.
fixture_doc "a cache from an older kit" "$EXAKIT_VERSIONS_CACHE" \
    "updated=2026-08-01" "components.personal.version=0.0.0-older-kit"
check "a cache older than the kit copy is refused" "baked" "$( exakit_versions_source )"
check "...and the kit's own launcher version is used" \
    "$(shipped components.personal.version)" "$( exakit_versions_value components.personal.version )"
# The narrow rule, both other ways round: only a PROVABLY older cache loses.
fixture_doc "a cache from a newer kit" "$EXAKIT_VERSIONS_CACHE" \
    "updated=2099-01-01" "components.personal.version=0.0.0-newer-kit"
check "a newer cache still wins" "cache" "$( exakit_versions_source )"
check "...and its value is used" "0.0.0-newer-kit" "$( exakit_versions_value components.personal.version )"
fixture_doc "a cache with no date at all" "$EXAKIT_VERSIONS_CACHE" \
    "updated=" "components.personal.version=0.0.0-undated"
check "an undated cache is not assumed old" "cache" "$( exakit_versions_source )"
rm -f "$EXAKIT_VERSIONS_CACHE"
no_doc="$( exakit_repo_root() { return 1; }
           printf '%s ' "$(exakit_versions_source)"
           if exakit_versions_value kit.version >/dev/null 2>&1; then printf found; else printf absent; fi )"
check "nothing on disk -> fallback constants" "fallback absent" "$no_doc"

echo "cache refresh (stubbed curl, no network):"
# The stub answers with whatever $SERVE points at, or fails when $CURL_FAIL=1 —
# enough to exercise every branch of the fetch without a server.
stub_curl() {
    curl() {
        _co=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) _co="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        [ "${CURL_FAIL:-0}" = 1 ] && return 22
        cp "$SERVE" "$_co"
    }
}
fetch_state="$( stub_curl
    SERVE="$REAL"
    EXAKIT_VERSIONS_CACHE="$WORK/fetch/versions.json"
    exakit_versions_update_cache >/dev/null 2>&1
    printf '%s %s ' "$?" "$_EXAKIT_VERSIONS_SOURCE"
    [ -f "$EXAKIT_VERSIONS_CACHE" ] && printf 'cached '
    # Only the validated document may exist — no half-written temporary file.
    printf '%s' "$(ls "$WORK/fetch" | tr '\n' ',')" )"
check "first fetch writes the cache atomically" "0 fetched cached versions.json," "$fetch_state"

ttl_state="$( stub_curl
    SERVE="$REAL"
    EXAKIT_VERSIONS_CACHE="$WORK/fetch/versions.json"
    exakit_versions_update_cache >/dev/null 2>&1; printf '%s ' "$?"
    exakit_versions_update_cache force >/dev/null 2>&1; printf '%s ' "$?"
    EXAKIT_VERSIONS_TTL=0
    exakit_versions_update_cache >/dev/null 2>&1; printf '%s' "$?" )"
check "fresh cache is not refetched (2), force and ttl=0 are" "2 0 0" "$ttl_state"

preserved="$( stub_curl
    EXAKIT_VERSIONS_CACHE="$WORK/fetch/versions.json"
    cp "$EXAKIT_VERSIONS_CACHE" "$WORK/good.json"
    SERVE="$REAL"
    CURL_FAIL=1
    exakit_versions_update_cache force >/dev/null 2>&1; printf '%s ' "$?"
    CURL_FAIL=0
    SERVE="$FIX/bad-digest.json"
    exakit_versions_update_cache force >/dev/null 2>&1; printf '%s ' "$?"
    if cmp -s "$WORK/good.json" "$EXAKIT_VERSIONS_CACHE"; then printf 'preserved '; else printf 'CLOBBERED '; fi
    printf '%s' "$(ls "$WORK/fetch" | tr '\n' ',')" )"
check "a failed or invalid fetch keeps the good cache" "1 1 preserved versions.json," "$preserved"

http_refused="$( stub_curl
    SERVE="$REAL"
    EXAKIT_VERSIONS_CACHE="$WORK/plain/versions.json"
    EXAKIT_VERSIONS_URL="http://example.invalid/versions.json"
    exakit_versions_update_cache force >/dev/null 2>&1; printf '%s ' "$?"
    [ -d "$WORK/plain" ] && printf 'wrote' || printf 'nothing' )"
check "a non-HTTPS endpoint is refused outright" "1 nothing" "$http_refused"

echo "install-time resolution:"
# Expectations are read from the manifest itself, so bumping a Component does not
# mean editing this test.
V_PERSONAL="$(exakit_versions_value components.personal.version "$REAL")"
V_EXAPUMP="$(exakit_versions_value components.exapump.version "$REAL")"
V_MCP="$(exakit_versions_value components.mcp.version "$REAL")"
V_PYEXASOL="$(exakit_versions_value components.pyexasol.version "$REAL")"

# resolve_set <shell-statements> — resolve in a subshell (so nothing leaks into
# the next case) and print "<source> <personal> <exapump> <mcp> <pyexasol>".
# The endpoint is non-HTTPS on purpose: it is refused outright, which keeps the
# whole test offline while still exercising the fetch-then-fall-back path.
resolve_set() (
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    EXAKIT_MANIFEST="$WORK/absent-manifest.json"
    EXAKIT_PERSONAL_VERSION=""; EXAKIT_EXAPUMP_VERSION=""
    EXAKIT_MCP_VERSION=""; EXAKIT_PYEXASOL_VERSION=""
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    eval "${1:-}"
    exakit_resolve_install_versions >/dev/null 2>&1
    printf '%s %s %s %s %s\n' "$EXAKIT_VERSIONS_SOURCE_USED" "$EXAKIT_PERSONAL_VERSION" \
        "$EXAKIT_EXAPUMP_VERSION" "$EXAKIT_MCP_VERSION" "$EXAKIT_PYEXASOL_VERSION"
)

check "manifest policy (default) reads the kit copy" \
    "baked $V_PERSONAL $V_EXAPUMP $V_MCP $V_PYEXASOL" "$(resolve_set)"
check "an env override beats the manifest" \
    "baked $V_PERSONAL 9.9.9 $V_MCP $V_PYEXASOL" \
    "$(resolve_set 'EXAKIT_EXAPUMP_VERSION=9.9.9')"
check "no document at all -> the fallback constants" \
    "fallback $EXAKIT_PERSONAL_VERSION_FALLBACK $EXAKIT_EXAPUMP_VERSION_FALLBACK $EXAKIT_MCP_VERSION_FALLBACK $EXAKIT_PYEXASOL_VERSION_FALLBACK" \
    "$(resolve_set 'exakit_repo_root() { return 1; }')"
mkdir -p "$EXAKIT_HOME/cache"
# The cached answer has to be one the baked copy cannot also be giving, so this is
# an unreachable major rather than the next plausible exapump release: the previous
# 0.12.0 was a rewrite that would have become a no-op the week the document reached
# it, leaving this check comparing the baked set to itself and still passing.
V_CACHE_ONLY_EXAPUMP="99.0.0"
fixture_doc "cache-only exapump" "$EXAKIT_VERSIONS_CACHE" \
    "components.exapump.version=$V_CACHE_ONLY_EXAPUMP"
check "a cached document beats the kit copy" \
    "cache $V_PERSONAL $V_CACHE_ONLY_EXAPUMP $V_MCP $V_PYEXASOL" "$(resolve_set)"
check "pinned policy ignores the document entirely" \
    "fallback $EXAKIT_PERSONAL_VERSION_FALLBACK $EXAKIT_EXAPUMP_VERSION_FALLBACK $EXAKIT_MCP_VERSION_FALLBACK $EXAKIT_PYEXASOL_VERSION_FALLBACK" \
    "$(resolve_set 'EXAKIT_VERSION_POLICY=pinned')"
check "latest policy still asks upstream" \
    "latest 7.7.7 7.7.7 6.6.6 6.6.6" \
    "$(resolve_set 'EXAKIT_VERSION_POLICY=latest
                    exakit_latest_github_release_version() { echo 7.7.7; }
                    exakit_latest_pypi_version() { echo 6.6.6; }')"
rm -f "$EXAKIT_VERSIONS_CACHE"

recorded="$( EXAKIT_HOME="$WORK/record-home"
             EXAKIT_MANIFEST="$WORK/record-home/manifest.json"
             EXAKIT_VERSIONS_CACHE="$WORK/record-home/cache/versions.json"
             EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
             EXAKIT_PERSONAL_VERSION=""; EXAKIT_EXAPUMP_VERSION=""
             EXAKIT_MCP_VERSION=""; EXAKIT_PYEXASOL_VERSION=""
             _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
             mkdir -p "$EXAKIT_HOME/kit/mcp"
             cp "$REAL" "$EXAKIT_HOME/kit/versions.json"
             manifest_init >/dev/null 2>&1
             exakit_resolve_install_versions >/dev/null 2>&1
             printf '%s %s %s' "$(manifest_get version_policy)" \
                 "$(manifest_get desired.versions_source)" "$(manifest_get desired.exapump)" )"
check "the install records where the versions came from" "manifest baked $V_EXAPUMP" "$recorded"

echo "exapump digest chain:"
digest_chain="$( . "$ROOT/setup/lib/detect.sh"
    . "$ROOT/setup/lib/exapump.sh"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_VERSIONS_CACHE="$WORK/no-cache.json"
    EXAKIT_EXAPUMP_VERSION="$V_EXAPUMP"
    _asset="$(exapump_asset_name)"
    _advertised="$(exakit_versions_value "components.exapump.sha256.${_asset#exapump-$V_EXAPUMP-}" "$REAL")"
    [ "$(exapump_expected_sha256 "$_asset")" = "$_advertised" ] && printf 'manifest ' || printf 'WRONG '
    # A version the manifest does not advertise must not borrow its digest: the
    # chain has to fall through to the pinned table and then the release API.
    exapump_pinned_sha256() { printf '' ; }
    exapump_release_digest_from_api() { printf 'from-api\n'; }
    EXAKIT_EXAPUMP_VERSION="0.0.0-not-advertised"
    printf '%s' "$(exapump_expected_sha256 "exapump-0.0.0-not-advertised-linux-x86_64")" )"
check "the advertised version verifies against the manifest digest" "manifest from-api" "$digest_chain"

echo "resilient install (pyexasol cannot end a run):"
mkdir -p "$WORK/failing-uv"
printf '#!/bin/sh\nexit 1\n' > "$WORK/failing-uv/uv"
chmod +x "$WORK/failing-uv/uv"
soft_fail="$( EXAKIT_HOME="$WORK/pyx-home"
    EXAKIT_MANIFEST="$WORK/pyx-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/pyx-home/bin"
    EXAKIT_PYEXASOL_VENV="$WORK/pyx-home/pyexasol-venv"
    EXAKIT_PYEXASOL_VERSION="$V_PYEXASOL"
    mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    PATH="$WORK/failing-uv:$PATH"
    if pyexasol_install >/dev/null 2>&1; then printf 'installed '; else printf 'soft-failed '; fi
    printf '%s ' "$(manifest_get components.pyexasol.validated 2>/dev/null || printf unset)"
    printf '%s' "$(manifest_get components.pyexasol.version 2>/dev/null || printf no-version)" )"
check "a uv that cannot run records the miss instead of dying" \
    "soft-failed false no-version" "$soft_fail"

# The real promise: the exakit helper step comes AFTER pyexasol, so a pyexasol
# failure must not stop the run from installing the command that fixes it.
mkdir -p "$WORK/fake-kit"
cp "$REAL" "$WORK/fake-kit/versions.json"
completed="$( EXAKIT_HOME="$WORK/kss-home"
    EXAKIT_MANIFEST="$WORK/kss-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/kss-home/bin"
    EXAKIT_PYEXASOL_VENV="$WORK/kss-home/pyexasol-venv"
    EXAKIT_PYEXASOL_VERSION="$V_PYEXASOL"
    mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    # Out of scope for this test: data load, MCP client setup, skills, PATH hints.
    exakit_maybe_offer_data_load() { :; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    PATH="$WORK/failing-uv:$PATH"
    kit_shared_steps 3 6 "$ROOT/setup" "$WORK/fake-kit" >/dev/null 2>&1
    [ -x "$EXAKIT_BIN_DIR/exakit" ] && printf 'exakit-installed ' || printf 'NO-EXAKIT '
    [ -f "$EXAKIT_HOME/kit/versions.json" ] && printf 'manifest-copied ' || printf 'NO-MANIFEST '
    printf '%s' "$(manifest_get steps_completed | tr -d ' "[]')" )"
check "the run completes and the kit copy carries the manifest" \
    "exakit-installed manifest-copied exakit_helper" "$completed"

# Re-running the installer over an older install (the 0.1.0 -> 0.2.0 path) is the
# one case where the step flag lies: install.sh has already replaced the kit copy,
# but exakit_helper is marked and a command is on disk, so the step skips. The
# installed command is a COPY of setup/exakit, so it has to be compared with the
# kit's own script or the user drives the new library with the old command.
rerun="$( EXAKIT_HOME="$WORK/rerun-home"
    EXAKIT_MANIFEST="$WORK/rerun-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/rerun-home/bin"
    EXAKIT_PYEXASOL_VENV="$WORK/rerun-home/pyexasol-venv"
    EXAKIT_PYEXASOL_VERSION="$V_PYEXASOL"
    mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    exakit_maybe_offer_data_load() { :; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    PATH="$WORK/failing-uv:$PATH"
    # Stand in for the older install: step already marked, previous command on disk.
    printf '#!/bin/sh\nprintf 0.1.0\n' > "$EXAKIT_BIN_DIR/exakit"
    chmod +x "$EXAKIT_BIN_DIR/exakit"
    mark_step exakit_helper >/dev/null 2>&1
    _out="$(kit_shared_steps 3 6 "$ROOT/setup" "$WORK/fake-kit" 2>&1)"
    # grep rather than case: inside a command substitution bash 3.2 reads the
    # close-paren of a case pattern as the end of the substitution itself, and
    # quote characters in a comment here confuse it the same way. Keep both out.
    if printf '%s\n' "$_out" | grep -q 'out of date'; then
        printf 'said-out-of-date '
    else
        printf 'SILENT '
    fi
    if cmp -s "$ROOT/setup/exakit" "$EXAKIT_BIN_DIR/exakit"; then printf 'refreshed'; else printf 'STALE'; fi )"
check "a re-run refreshes the command an older install left behind" \
    "said-out-of-date refreshed" "$rerun"

# ...and it must leave a command that already matches alone, or every re-run
# announces an upgrade that did not happen.
noop="$( EXAKIT_HOME="$WORK/noop-home"
    EXAKIT_MANIFEST="$WORK/noop-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/noop-home/bin"
    EXAKIT_PYEXASOL_VENV="$WORK/noop-home/pyexasol-venv"
    EXAKIT_PYEXASOL_VERSION="$V_PYEXASOL"
    mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    exakit_maybe_offer_data_load() { :; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    PATH="$WORK/failing-uv:$PATH"
    install -m 755 "$ROOT/setup/exakit" "$EXAKIT_BIN_DIR/exakit"
    mark_step exakit_helper >/dev/null 2>&1
    _out="$(kit_shared_steps 3 6 "$ROOT/setup" "$WORK/fake-kit" 2>&1)"
    if printf '%s\n' "$_out" | grep -q 'out of date'; then
        printf 'REFRESHED-ANYWAY'
    else
        printf 'left-alone'
    fi )"
check "a re-run leaves an up-to-date command alone" "left-alone" "$noop"

echo "the version table:"
# One fixture install, one advertised set, every interesting row at once:
#   exakit    0.2.0            = 0.2.0             -> current (and NOT "inspect")
#   personal  2.2.0           -> 2.3.0             -> heavy
#   exapump   0.13.0          -> 0.12.0            -> ahead, nothing offered
#   mcp       1.10.1          -> 1.11.0 critical   -> severity + note
#   pyexasol  not installed   -> 2.2.2             -> repair action
UC="$WORK/uc-home"
mkdir -p "$UC/kit/mcp" "$UC/cache" "$UC/bin"
# Installed versions are read from disk now, so the fixture supplies the disk: a
# stub that reports 0.13.0 is what puts the install AHEAD of the advertised 0.12.0,
# on any machine, whether or not a real exapump is installed.
printf '#!/bin/sh\necho "exapump 0.13.0"\n' > "$UC/bin/exapump"
chmod +x "$UC/bin/exapump"
cat > "$UC/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "installed_at": "2026-07-29T10:00:00Z",
  "kit": {
    "version": "0.2.0",
    "source": "example/starter-kit@main"
  },
  "runtime": {
    "type": "personal",
    "version": "2.2.0"
  },
  "components": {
    "exapump": {
      "version": "0.13.0",
      "path": "$UC/bin/exapump"
    },
    "mcp_server": {
      "package": "exasol-mcp-server",
      "version": "1.10.1"
    },
    "pyexasol": {
      "validated": false
    }
  },
  "steps_completed": []
}
EOF
cat > "$UC/kit/versions.json" <<'EOF'
{
  "schema_version": 1,
  "updated": "2026-07-29",
  "kit": {
    "version": "0.2.0"
  },
  "components": {
    "exapump": {
      "version": "0.12.0",
      "severity": "recommended",
      "note": "0.13.0 mis-detects CSV headers; 0.12.0 is the tested build."
    },
    "mcp": {
      "version": "1.11.0",
      "package": "exasol-mcp-server",
      "severity": "critical"
    },
    "pyexasol": {
      "version": "2.2.2"
    },
    "personal": {
      "version": "2.3.0",
      "severity": "normal"
    }
  }
}
EOF

# row <table> <first column> — one row of a rendered table, colour escapes
# removed and runs of spaces squeezed to one, so a whole row can be compared
# exactly. The Severity cell is coloured when the suite is run on a terminal
# (UI_FANCY), and an exact comparison must hold either way.
# row <table> <first-cell> — one row, squeezed, with the card border removed.
# The table is drawn as a panel, so every row arrives as
# "  | exakit  0.2.0  ... |"; matching "^exakit " found nothing at all.
row() {
    printf '%s\n' "$1" \
        | sed "s/$(printf '\033')\[[0-9;]*m//g" \
        | sed 's/^ *[|│] //; s/ *[|│] *$//' \
        | grep -m1 "^$2 " | tr -s ' ' | sed 's/ *$//'
}

# has <label> <needle> <haystack>
has() {
    case "$3" in
        *"$2"*) check "$1" "present" "present" ;;
        *)      check "$1" "present" "MISSING" ;;
    esac
}
lacks() {
    case "$3" in
        *"$2"*) check "$1" "absent" "PRESENT" ;;
        *)      check "$1" "absent" "absent" ;;
    esac
}

uc_table="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_version_table 2>&1 )"

# The header line itself, squeezed. `exakit version` and `exakit update-check`
# were merged into one command, so there is one table and it has three columns:
# what to name in a command, what is on the machine, and what is waiting.
check "the table is Component / Version / Status" \
    "Component Version Status" "$(row "$uc_table" Component)"
lacks "the old Installed header is gone" "Installed " "$uc_table"
lacks "the old Tagged column is gone" "Tagged" "$uc_table"
lacks "the old Latest header is gone" "Latest" "$uc_table"
lacks "the old Severity column is gone" "Severity" "$uc_table"
lacks "the old Action column is gone" "Action" "$uc_table"
has "the kit row compares its own version" "exakit 0.2.0" "$(row "$uc_table" exakit)"
# The Version column must keep showing what is installed. Asking
# exakit_version_newer about a possible rollback passes the versions in reverse,
# and bash has no function-local variables here: a callee that reused the name
# _current would silently overwrite the row's installed version.
has "installed stays installed (exapump)" "exapump 0.13.0" "$(row "$uc_table" exapump)"
has "installed stays installed (personal)" "personal 2.2.0" "$(row "$uc_table" personal)"
has "installed stays installed (mcp)" "mcp 1.10.1" "$(row "$uc_table" mcp)"
lacks "no row is stuck on inspect" "inspect" "$uc_table"
# The advertised version IS the status: with no Tagged column, a row that is
# behind has to name the number it is behind, or the screen says only that
# something is wrong without saying what would fix it.
check "a waiting update names the advertised version" \
    "personal 2.2.0 2.3.0 available" "$(row "$uc_table" personal)"
# The whole ahead row, squeezed: the status is exactly "none". Not "yours is
# newer than tested", which apologised for the install and made the tested set
# sound abandoned; not the tagged number either, which invites the reader to go
# looking for a way back to it. And no severity — a severity rates the advertised
# version, and there is nothing to recommend to someone already past it.
check "an install ahead of the tagged set says only none" \
    "exapump 0.13.0 none" "$(row "$uc_table" exapump)"
lacks "no version cell is annotated (older)" "(older)" "$uc_table"
lacks "and nothing apologises for the install" "newer than tested" "$uc_table"
lacks "no downgrade is offered" "exakit update exapump" "$uc_table"
lacks "and no confirmation is promised" "advisory rollback" "$uc_table"
# The kit never moves a component backwards, by any route: the ahead row offers
# no command at all, and it must not be counted into the closing line either.
lacks "the ahead row is not counted as waiting work" "ahead of tagged" "$uc_table"
check "a flagged row carries its severity in the status" \
    "mcp 1.10.1 1.11.0 available (critical)" "$(row "$uc_table" mcp)"
# The fixture's only "recommended" component is the one that is AHEAD, and an
# ahead row drops its severity on purpose, so the table itself cannot show one.
# The renderer is guarded directly rather than by a fixture row that no longer
# carries it -- and the pair together pin both halves of the rule.
check "a recommended severity renders when a row is behind" \
    "0.13.0 available (recommended)" "$(_exakit_status_cell "0.13.0 available" recommended)"
check "and a normal severity adds nothing" \
    "0.13.0 available" "$(_exakit_status_cell "0.13.0 available" normal)"
has "the maintainer note is printed" "0.13.0 mis-detects CSV headers" "$uc_table"
# The note hangs under its row. It used to be packed into a tab-separated string
# with every other cell and split back apart with `set --`, which collapses runs
# of IFS whitespace: the row whose severity was empty silently shifted its notes
# into the wrong fields, so this note vanished exactly when a component was ahead.
has "a missing component offers the repair" "2.2.2 available (repair)" "$(row "$uc_table" pyexasol)"
has "normal severities stay quiet" "exakit 0.2.0 current" "$(row "$uc_table" exakit)"
has "the source of the answers is stated" "Versions:" "$uc_table"
# One command is promoted, and it is the one that applies everything.
has "the screen promotes update-all" "Bring everything up to date with: exakit update" "$uc_table"
lacks "and advertises no per-row command" "exakit update mcp" "$uc_table"
lacks "no heavy caveat is printed here" "(heavy)" "$uc_table"
lacks "no staged-upgrade caveat is printed here" "(major)" "$uc_table"

min_kit_table="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    # A component that needs a newer kit must send the user to the kit first.
    exakit_component_min_kit() { [ "$1" = "mcp" ] && printf '9.9.9\n'; return 0; }
    exakit_print_version_table 2>&1 )"
has "min_kit_version routes to the kit first" "update exakit first (needs kit >= 9.9.9)" "$min_kit_table"

echo "one command renders the table, and it is exakit version:"
version_out="$( EXAKIT_HOME="$UC" EXAKIT_MANIFEST="$UC/manifest.json" \
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
    bash "$ROOT/setup/exakit" version 2>&1 )"
# The Kit panel keeps its own shape: kit version, level, source and install date
# have no component/version/status form. Match the label and value, not the
# spacing between them, or this pins a padding that legitimately moves when a
# longer value (a repo name, a git-sha version) widens the screen.
has "version reports the installed kit version" "Version " "$version_out"
has "version reports the installed kit version value" "0.2.0" "$version_out"
has "version keeps the Kit panel" "Kit" "$version_out"
# The merge, guarded from both sides: version renders the table itself...
has "version renders the comparison table" "Component Version Status" \
    "$(row "$version_out" Component)"
has "version names what is waiting" "1.11.0 available" "$version_out"
has "version promotes update-all" "Bring everything up to date with: exakit update" "$version_out"
# ...and the second command it was merged from is gone, not hidden.
lacks "version prints no separate updates panel" "Updates available" "$version_out"
lacks "and points at no update-check" "update-check" "$version_out"
uc_gone="$( EXAKIT_HOME="$UC" EXAKIT_MANIFEST="$UC/manifest.json" \
    bash "$ROOT/setup/exakit" update-check 2>&1 || true )"
has "update-check is not a command any more" "unknown command 'update-check'" "$uc_gone"
uc_rc=0
( EXAKIT_HOME="$UC" EXAKIT_MANIFEST="$UC/manifest.json" \
    bash "$ROOT/setup/exakit" update-check >/dev/null 2>&1 ) || uc_rc=$?
check "and it exits like any unknown command" "2" "$uc_rc"

update_out="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    # </dev/null on purpose: this is the unattended case, and stdin decides
    # whether the runtime update is offered inline (see the offer tests below).
    exakit_update all </dev/null 2>&1 )"
lacks "update prints no comparison table either" "Component update check" "$update_out"
has "update states its work plan" "mcp 1.10.1 -> 1.11.0" "$update_out"
has "update applies the light components" "APPLIED mcp" "$update_out"
lacks "an unattended update never applies the runtime by itself" "APPLIED runtime" "$update_out"
has "update explains the deferred runtime" "needs the database stopped" "$update_out"

echo "the runtime update is offered inline, not handed back as homework:"
# The old flow refused the heavy part outright — "not part of a routine update",
# followed by `exakit update runtime` for the user to run themselves after
# stopping nothing. These cases cover the whole decision: a terminal is asked and
# a "y" does the work here; a "no" keeps exactly the old deferral; no terminal
# never asks and never stops a database; and the two explicit opt-ins apply it
# unattended.
#
# exakit_stdin_is_tty and _exakit_prompt_tty are stubbed rather than allocating a
# pty: they are the two functions that decide "is there anyone to ask", and with
# both pointing at stdin the answer piped in below is read exactly as a typed one
# would be.
offer_run() ( # offer_run <answer> [statements]
    EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    unset EXAKIT_CONFIRM_RUNTIME_UPDATE
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    exakit_stdin_is_tty() { return 0; }
    _exakit_prompt_tty() { printf 'stdin\n'; }
    eval "${2:-}"
    printf '%s\n' "$1" | ( exakit_update all 2>&1 )
)

offer_yes="$(offer_run y)"
has "a terminal is asked before anything is stopped" "Stop the database and update the runtime now?" "$offer_yes"
has "the question names the outage" "needs the database stopped" "$offer_yes"
has "the question promises the restart" "started again if it ends up down" "$offer_yes"
has "the question says the data survives" "Your data is kept" "$offer_yes"
has "yes applies the runtime in this run" "APPLIED runtime" "$offer_yes"
has "and reports the result" "Runtime updated" "$offer_yes"

# A runtime AHEAD of the tested set must never reach the question. The heavy
# branch gated on "different" and then continued, so the never-backwards guard
# further down was unreachable for it: an installed 2.1.0 against a tested 2.0.0
# was offered as a runtime update -- a DOWNGRADE, behind a prompt promising the
# data would survive it -- while `exakit version` rendered that same row as
# "none" and every light component said "keeping yours". Answer "y" here on
# purpose: if the question is ever asked again, this run applies the downgrade
# and the APPLIED assertion catches it rather than passing on a silent skip.
offer_ahead="$(offer_run y '
    exakit_component_current() { printf "9.9.9\n"; }
    exakit_component_available() { printf "1.0.0\n"; }
')"
lacks "a runtime ahead of the tested set is never offered" \
    "Stop the database and update the runtime now?" "$offer_ahead"
lacks "and nothing is applied, downgrade or otherwise" "APPLIED" "$offer_ahead"
lacks "and no database is described as going down" "goes down while the container is recreated" "$offer_ahead"
has "it says it is keeping what is installed" "is newer than the tested 1.0.0" "$offer_ahead"

# The choke point refuses on its own, called DIRECTLY with no exakit_update above
# it to have vetted the request. The updaters it dispatches to hold no version
# opinion at all -- they install whatever they are handed -- so without this a
# caller that forgets to ask is one edit away from reintroducing the downgrade.
chokepoint="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    exakit_component_current() { printf '9.9.9\n'; }
    exakit_component_available() { printf '1.0.0\n'; }
    exapump_update() { printf 'APPLIED exapump\n'; }
    mcp_update() { printf 'APPLIED mcp\n'; }
    exakit_update_component exapump 2>&1
    exakit_update_component mcp 2>&1 )"
lacks "the choke point applies nothing when the install is ahead" "APPLIED" "$chokepoint"
has "and says so once per component asked for" "keeping yours" "$chokepoint"
# An env override must not resurrect it either: the flow it used to pre-answer is
# gone, so the variable is inert and has to stay inert.
choke_override="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_ALLOW_DOWNGRADE=1
    exakit_init_logging() { :; }
    exakit_component_current() { printf '9.9.9\n'; }
    exakit_component_available() { printf '1.0.0\n'; }
    exapump_update() { printf 'APPLIED exapump\n'; }
    exakit_update_component exapump 2>&1 )"
lacks "and no override can buy a downgrade" "APPLIED" "$choke_override"
lacks "and demands no second command" "exakit update runtime" "$offer_yes"
has "while the light components still run" "APPLIED mcp" "$offer_yes"

offer_no="$(offer_run n)"
lacks "no stops nothing" "APPLIED runtime" "$offer_no"
has "no says so plainly" "Nothing was stopped." "$offer_no"
has "no keeps the exact command for later" "Apply it when convenient:  exakit update" "$offer_no"
has "and points at the full picture" "including the deferred runtime change" "$offer_no"
has "the light components are applied either way" "APPLIED mcp" "$offer_no"

# Enter (empty answer) is not consent: the default is no.
offer_default="$(offer_run '')"
lacks "an empty answer stops nothing" "APPLIED runtime" "$offer_default"
has "the prompt shows no as the default" "[y/N]" "$offer_default"

# The safety case. A prompt nobody can answer must never become a stopped
# database, so the unattended run above (update_out, with real stdin redirected
# from /dev/null) must not even print the question.
lacks "an unattended run is never asked" "Stop the database and update the runtime now?" "$update_out"
has "an unattended run defers as it always did" "not part of a routine update" "$update_out"
has "and names the opt-in for scripts" "exakit update --yes" "$update_out"

offer_flag="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    unset EXAKIT_CONFIRM_RUNTIME_UPDATE
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    exakit_update all --yes </dev/null 2>&1 )"
has "--yes applies the runtime without a terminal" "APPLIED runtime" "$offer_flag"
lacks "and asks nothing" "Stop the database and update the runtime now?" "$offer_flag"
has "but still says what it did to the database" "needs the database stopped" "$offer_flag"
has "and the rest of the run is unaffected" "APPLIED mcp" "$offer_flag"

offer_env="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_CONFIRM_RUNTIME_UPDATE=1
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    exakit_update all </dev/null 2>&1 )"
has "EXAKIT_CONFIRM_RUNTIME_UPDATE=1 is the same opt-in" "APPLIED runtime" "$offer_env"

# =0 is a deliberate no, and it outranks the terminal: a fleet that has said "not
# the database" must not be asked again on every machine that has a console.
offer_env_no="$(offer_run y 'EXAKIT_CONFIRM_RUNTIME_UPDATE=0')"
lacks "EXAKIT_CONFIRM_RUNTIME_UPDATE=0 stops nothing" "APPLIED runtime" "$offer_env_no"
lacks "and is not asked anyway" "Stop the database and update the runtime now?" "$offer_env_no"
has "and says why it was left alone" "was left alone" "$offer_env_no"

# A Personal MAJOR upgrade is a data migration with its own backup-gated flow. One
# y/N is not informed consent for it, so it keeps the deferral.
offer_major="$(offer_run y '
    exakit_installation_runtime_type() { printf personal; }
    exakit_component_current() { [ "$1" = personal ] && printf "1.5.0\n"; return 0; }
    exakit_component_available() { [ "$1" = personal ] && printf "2.0.0\n"; return 0; }')"
has "a Personal major upgrade is named as such" "is a major upgrade" "$offer_major"
has "and refuses to start it from a routine update" "a routine update does not start it" "$offer_major"
lacks "and is never started from a y/N" "APPLIED runtime" "$offer_major"
lacks "and does not ask the inline question at all" "Stop the database and update the runtime now?" "$offer_major"

# The promise the question makes: a database that was up before is up afterwards.
# The updaters do that themselves; this covers the case where one comes back down.
rm -f "$WORK/rt-down"
offer_restart="$(offer_run y '
    exakit_runtime_status() { if [ -f "$WORK/rt-down" ]; then printf "stopped\n"; else printf "running\n"; fi; }
    exakit_runtime_start() { printf "STARTED\n"; rm -f "$WORK/rt-down"; }
    exakit_update_component() { printf "APPLIED %s\n" "$1"; [ "$1" = runtime ] && : > "$WORK/rt-down"; return 0; }')"
has "a database left down is brought back up" "STARTED" "$offer_restart"
has "and the run says it is running again" "the database is running again" "$offer_restart"

echo "the user's own choice still wins:"
# The install path honours EXAKIT_*_VERSION; the update path must too, or the
# documented "downgrade of my own choosing" movement quietly does something else.
override_avail="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_EXAPUMP_VERSION="0.11.2"
    printf '%s %s' "$(exakit_component_available exapump)" "$(exakit_component_available mcp)" )"
check "an env override outranks the manifest" "0.11.2 1.11.0" "$override_avail"
override_confirm="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_EXAPUMP_VERSION="0.11.2"
    if exakit_component_is_ahead exapump; then printf 'ahead'; else printf 'NOT-AHEAD'; fi )"
check "but an override naming an older version is still not a downgrade lever" \
    "ahead" "$override_confirm"

echo "a routine update never dies on one component:"
unknown_skip="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    # Nothing is advertised at all (an unreadable manifest looks like this).
    exakit_component_available() { return 1; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    exakit_update all 2>&1 )"
has "an unadvertised component is skipped, not fatal" "No advertised version for mcp" "$unknown_skip"
lacks "and nothing is applied blindly" "APPLIED" "$unknown_skip"

current_only="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    # Everything installed matches what is advertised.
    exakit_component_available() { exakit_component_current "$1"; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    exakit_update all 2>&1 )"
has "an up-to-date install says so once" "Everything is already current." "$current_only"
lacks "without listing every component" "is current (" "$current_only"

echo "installed versions come from disk, not just from the record:"
# The record says what the kit installed. A user can upgrade pyexasol inside its
# venv or drop in another exapump build, and an update check that trusted the
# record would compare against a version nobody is running.
LIVE="$WORK/live-home"
mkdir -p "$LIVE/bin" "$LIVE/venv/bin" "$LIVE/kit/mcp" "$LIVE/cache"
cp "$REAL" "$LIVE/kit/versions.json"
printf '#!/bin/sh\necho "exapump 0.13.0"\n' > "$LIVE/bin/exapump"
# rm -f first: a uv-created venv's bin/python is a SYMLINK to the shared
# managed interpreter, and `>` follows symlinks -- writing through it
# replaced the developer's real 18 MB CPython with this 17-byte stub and
# broke uv for every later component install.
rm -f "$LIVE/venv/bin/python"
printf '#!/bin/sh\necho 2.9.9\n' > "$LIVE/venv/bin/python"
chmod +x "$LIVE/bin/exapump" "$LIVE/venv/bin/python"
cat > "$LIVE/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": { "version": "0.2.0" },
  "runtime": { "type": "personal", "version": "2.0.0-rc4" },
  "components": {
    "exapump": { "version": "0.11.2", "path": "$LIVE/bin/exapump" },
    "mcp_server": { "version": "1.10.1" },
    "pyexasol": { "version": "2.2.2", "python": "$LIVE/venv/bin/python" }
  },
  "steps_completed": []
}
EOF

live_read() (
    EXAKIT_HOME="$LIVE"
    EXAKIT_MANIFEST="$LIVE/manifest.json"
    eval "${2:-}"
    exakit_component_current "$1" 2>/dev/null || printf 'not installed'
)

check "exapump: the binary on disk wins over the record" "0.13.0" "$(live_read exapump)"
check "pyexasol: the venv wins over the record" "2.9.9" "$(live_read pyexasol)"
# A probe that runs but says nothing usable: keep the record rather than claim
# the component vanished.
check "a silent probe falls back to the record" "0.11.2" \
    "$(live_read exapump 'printf "#!/bin/sh\nexit 3\n" > "$LIVE/bin/exapump"; chmod +x "$LIVE/bin/exapump"')"
# Provably absent is different from unknown: the table should offer the reinstall.
check "a missing binary reports not installed" "not installed" \
    "$(live_read exapump 'rm -f "$LIVE/bin/exapump"; PATH="/nonexistent"')"
check "a missing venv reports not installed" "not installed" \
    "$(live_read pyexasol 'rm -f "$LIVE/venv/bin/python"')"
# The MCP server is materialised per launch by uvx, so its record stands.
check "the MCP server keeps its recorded version" "1.10.1" "$(live_read mcp)"

# A component that is gone must read as gone in EVERY command. Swallowing the reader's
# "provably absent" verdict made `exakit version` print a recorded version while
# the version table and status both said "not installed".
# PATH must not contain a real exapump either, or the binary fallback finds the
# tester's own install; python3 has to stay reachable for the manifest reads.
absent_version="$( rm -f "$LIVE/bin/exapump" "$LIVE/venv/bin/python"
    EXAKIT_HOME="$LIVE" PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin" \
        bash "$ROOT/setup/exakit" version 2>&1 )"
has "version agrees that a deleted exapump is gone" "exapump not installed" "$(row "$absent_version" exapump)"
has "version agrees that a deleted venv is gone" "pyexasol not installed" "$(row "$absent_version" pyexasol)"
# Put them back for anything that follows.
printf '#!/bin/sh\necho "exapump 0.13.0"\n' > "$LIVE/bin/exapump"
rm -f "$LIVE/venv/bin/python"
printf '#!/bin/sh\necho 2.9.9\n' > "$LIVE/venv/bin/python"
chmod +x "$LIVE/bin/exapump" "$LIVE/venv/bin/python"

# Clients that disagree must yield ONE comparable version, not a joined list: the list
# compared as newer than the advertised version, so an unattended update read it as a
# rollback and skipped MCP entirely.
mcp_not_rollback="$( EXAKIT_HOME="$LIVE"
    EXAKIT_MANIFEST="$LIVE/manifest.json"
    exakit_component_available() { printf '1.10.1\n'; }
    exakit_component_current() { printf '1.9.0\n'; }
    if exakit_component_is_ahead mcp; then printf 'AHEAD'; else printf 'not-ahead'; fi )"
check "and an older pin is not mistaken for being ahead" "not-ahead" "$mcp_not_rollback"

# The launcher is a different axis from the runtime: personal_update --apply installs a
# new launcher but leaves runtime.version behind until the data migration is done.
# Reporting the launcher there hid the outstanding migration.
check "personal reports the recorded runtime, not the launcher" "2.0.0-rc4" \
    "$( EXAKIT_HOME="$LIVE"; EXAKIT_MANIFEST="$LIVE/manifest.json"; EXAKIT_BIN_DIR="$LIVE/rt"
        mkdir -p "$LIVE/rt"; printf '#!/bin/sh\necho 9.9.9\n' > "$LIVE/rt/exasol"
        chmod +x "$LIVE/rt/exasol"
        exakit_installation_runtime_type() { printf personal; }
        exakit_component_current personal 2>/dev/null )"

# The runtime is probed too, but with one deliberate difference: a probe that cannot
# answer keeps the record instead of reporting absence. A stopped deployment is an
# ordinary state; the runtime row must not flicker to "inspect" because the
# launcher is not answering.
mkdir -p "$LIVE/rt"
printf '#!/bin/sh\necho 3.1.4\n' > "$LIVE/rt/exasol"
chmod +x "$LIVE/rt/exasol"
# Asking for `personal` on an installation whose manifest records no runtime type
# must return nothing even with a launcher sitting right there: a runtime this kit
# does not manage is not installed. PATH is left alone on purpose — stripping it
# hides python3, and the kit then reaches for uv, which is noise rather than a
# result.
runtime_read() (
    EXAKIT_HOME="$LIVE"
    EXAKIT_MANIFEST="$LIVE/manifest.json"
    EXAKIT_BIN_DIR="$LIVE/rt"
    eval "${2:-}"
    exakit_component_current "$1" 2>/dev/null || printf 'not installed'
)
# The launcher is NOT the runtime version: personal_update --apply installs a new
# launcher and deliberately leaves runtime.version behind until the data migration is
# finished, so the record is the only honest answer here.
check "personal reports the record, launcher present or not" "2.0.0-rc4" \
    "$(runtime_read personal 'exakit_installation_runtime_type() { printf personal; }')"
check "personal is not installed when nothing recorded it" "not installed" \
    "$(runtime_read personal 'exakit_installation_runtime_type() { printf ""; }')"

# The MCP server is never installed as such: uvx materialises it per launch, so what
# exists is the spec pinned into each AI client config. The status operation is stubbed
# to hand back a config path, and the pin is read out of the file itself.
mkdir -p "$LIVE/mcp"
printf '{"mcpServers":{"exasol":{"command":"uvx","args":["exasol-mcp-server@1.9.0"]}}}\n' \
    > "$LIVE/mcp/client-a.json"
printf '{"mcpServers":{"exasol":{"command":"uvx","args":["exasol-mcp-server@1.10.1"]}}}\n' \
    > "$LIVE/mcp/client-b.json"
mcp_read() (
    EXAKIT_HOME="$LIVE"
    EXAKIT_MANIFEST="$LIVE/manifest.json"
    exakit_run_mcp_operation_cli() {
        printf '{"artifacts":[%s]}\n' "$MCP_ARTIFACTS" > "$3"
    }
    eval "${1:-}"
    exakit_component_current mcp 2>/dev/null || printf 'not installed'
)
check "mcp: the pin in the client config is what will run" "1.9.0" \
    "$(MCP_ARTIFACTS='{"path":"'"$LIVE"'/mcp/client-a.json"}' mcp_read)"
# Clients that disagree yield the OLDEST pin: this value is compared against the
# advertised version, and the oldest is the weakest link — the client that would launch
# the most outdated server. Which client is stale belongs to mcp-doctor.
check "mcp: disagreeing clients yield the oldest pin" "1.9.0" \
    "$(MCP_ARTIFACTS='{"path":"'"$LIVE"'/mcp/client-a.json"},{"path":"'"$LIVE"'/mcp/client-b.json"}' mcp_read)"
check "mcp: no configured client keeps the record" "1.10.1" \
    "$(MCP_ARTIFACTS='' mcp_read)"
check "mcp: no mcp module at all keeps the record" "1.10.1" \
    "$(mcp_read 'unset -f exakit_run_mcp_operation_cli')"

echo "the MCP update compares against the client pin, not the record:"
# The record only says what a previous run WROTE DOWN, and it is written before the
# client configs are refreshed — so it can name a version no client is launching.
# `exakit version` already reports the live pin; the updater has to agree with it, or it
# announces "mcp 1.10.1 -> 2.0.0" from the pin and then declines the work it just
# announced because the record already says 2.0.0.
DIV="$WORK/divergent-home"
mkdir -p "$DIV/mcp" "$DIV/kit/mcp" "$DIV/cache"
cp "$REAL" "$DIV/kit/versions.json"
printf '{"mcpServers":{"exasol":{"command":"uvx","args":["exasol-mcp-server@1.10.1"]}}}\n' \
    > "$DIV/mcp/client.json"
cat > "$DIV/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "runtime": {
    "type": "personal",
    "version": "2.2.0"
  },
  "components": {
    "mcp_server": {
      "package": "exasol-mcp-server",
      "version": "2.0.0"
    }
  },
  "steps_completed": []
}
EOF
# mcp_update itself runs for real. Only the seams are stubbed: the advertised
# version, the client-config listing, the config rewrite, and the three steps that
# would touch the machine (uvx prime, snapshot, stdio handshake). The stubbed
# rewrite moves the pin in the fixture config exactly as the real configure
# operation does, so the assertions below read the file, not a promise.
mcp_update_run() (
    EXAKIT_HOME="$DIV"
    EXAKIT_MANIFEST="$DIV/manifest.json"
    # shellcheck source=/dev/null
    . "$ROOT/setup/lib/mcp.sh"
    exakit_component_available() { printf '%s\n' "$ADVERTISED"; }
    exakit_run_mcp_operation_cli() {
        printf '{"artifacts":[{"path":"%s","client":"claude_code"}]}\n' \
            "$DIV/mcp/client.json" > "$3"
    }
    exakit_run_mcp_setup_cli() {
        printf 'REFRESHED %s\n' "$1"
        printf '{"mcpServers":{"exasol":{"command":"uvx","args":["exasol-mcp-server@%s"]}}}\n' \
            "$EXAKIT_MCP_VERSION" > "$DIV/mcp/client.json"
        printf '{"status":"success","selected_clients":["claude_code"],"artifacts":[]}\n' > "$2"
    }
    exakit_print_mcp_setup_summary() { :; }
    mcp_update_snapshot() { :; }
    mcp_install() {
        printf 'PRIMED %s\n' "$EXAKIT_MCP_VERSION"
        manifest_set components.mcp_server.version "$EXAKIT_MCP_VERSION"
    }
    mcp_validate() { :; }
    eval "${1:-}"
    mcp_update 2>&1
)
div_pin() { grep -o 'exasol-mcp-server@[0-9.]*' "$DIV/mcp/client.json" | cut -d@ -f2; }
div_record() ( EXAKIT_MANIFEST="$DIV/manifest.json"; manifest_get components.mcp_server.version )

divergent="$(ADVERTISED=2.0.0 mcp_update_run)"
lacks "a record that already names the target is not proof" "already current" "$divergent"
has "the update runs anyway" "PRIMED 2.0.0" "$divergent"
has "and the client configs are the thing it rewrites" "REFRESHED claude_code" "$divergent"
check "the pin the next client launch would use has moved" "2.0.0" "$(div_pin)"

# Idempotent for the real case: the configs now agree with the advertised version,
# so a second run must do nothing at all rather than re-prime and re-render.
current="$(ADVERTISED=2.0.0 mcp_update_run)"
has "a genuinely current install skips cleanly" "already current (2.0.0)" "$current"
lacks "and nothing is reinstalled" "PRIMED" "$current"
lacks "and no client config is touched" "REFRESHED" "$current"

# The other direction of the same divergence: the configs are current and the record
# lags. Nothing to install, but the record is what the renderer reads to pin the NEXT
# client the user connects, so it is reconciled instead of left lying.
reconciled="$(ADVERTISED=2.0.0 mcp_update_run 'manifest_set components.mcp_server.version 1.9.0')"
has "a lagging record is reconciled, not left lying" "Reconciling the recorded MCP version" "$reconciled"
has "and the skip is still clean" "already current (2.0.0)" "$reconciled"
check "the record now matches the configs" "2.0.0" "$(div_record)"

echo "the exapump update compares against the binary on disk, not the record:"
# components.exapump.version is only what a previous run WROTE DOWN, and
# exapump_record_manifest writes it from the version that run asked for — so it can
# name a release that never landed, and it says nothing about a binary someone
# replaced by hand. `exakit version` and the dispatcher both report what the binary says;
# the updater has to agree with them, or it announces "exapump 8.1.0 -> 8.2.0" from
# the probe and then declines that exact work because the record already says 8.2.0.
XP="$WORK/exapump-divergent"
mkdir -p "$XP/bin" "$XP/kit" "$XP/cache"
cp "$REAL" "$XP/kit/versions.json"
# Versions no part of the shipped document uses, so a bump cannot make these pass or
# fail for the wrong reason.
xp_binary() { printf '#!/bin/sh\necho "exapump %s"\n' "$1" > "$XP/bin/exapump"; chmod +x "$XP/bin/exapump"; }
xp_binary 8.1.0
cat > "$XP/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "runtime": {
    "type": "personal",
    "version": "2.2.0"
  },
  "components": {
    "exapump": {
      "version": "8.2.0",
      "path": "$XP/bin/exapump"
    }
  },
  "steps_completed": []
}
EOF
# exapump_update itself runs for real. Only the seams are stubbed: the advertised
# version, the download, and the profile write. The stubbed install replaces the
# fixture binary exactly as a real one would, so the assertions below read what the
# binary reports, not a promise.
xp_update_run() (
    EXAKIT_HOME="$XP"
    EXAKIT_MANIFEST="$XP/manifest.json"
    EXAKIT_BIN_DIR="$XP/bin"
    # shellcheck source=/dev/null
    . "$ROOT/setup/lib/exapump.sh"
    exakit_component_available() { printf '%s\n' "$ADVERTISED"; }
    exapump_install() {
        printf 'INSTALLED %s\n' "$EXAKIT_EXAPUMP_VERSION"
        printf '#!/bin/sh\necho "exapump %s"\n' "$EXAKIT_EXAPUMP_VERSION" > "$EXAKIT_EXAPUMP_BIN"
        chmod +x "$EXAKIT_EXAPUMP_BIN"
        exapump_record_manifest
    }
    exapump_create_profile() { printf 'PROFILE\n'; }
    eval "${1:-}"
    "${XP_ENTRY:-exapump_update}" exapump 2>&1
)
xp_live() { "$XP/bin/exapump" --version 2>/dev/null | sed 's/^exapump //'; }
xp_record() ( EXAKIT_MANIFEST="$XP/manifest.json"; manifest_get components.exapump.version )

xp_divergent="$(ADVERTISED=8.2.0 xp_update_run)"
lacks "a record that already names the target is not proof" "already current" "$xp_divergent"
has "the work is announced against the binary" "Updating exapump 8.1.0 -> 8.2.0" "$xp_divergent"
has "and the install actually runs" "INSTALLED 8.2.0" "$xp_divergent"
check "the binary a user would run has moved" "8.2.0" "$(xp_live)"

# Idempotent for the real case: the binary now reports the advertised version, so a
# second run must do nothing at all rather than re-download and rewrite the profile.
xp_current="$(ADVERTISED=8.2.0 xp_update_run)"
has "a genuinely current install skips cleanly" "already current (8.2.0)" "$xp_current"
lacks "and nothing is reinstalled" "INSTALLED" "$xp_current"
lacks "and no profile is rewritten" "PROFILE" "$xp_current"

# The other direction of the same divergence: the binary is current and the record
# lags. Nothing to install, but `exakit version` credits the kit with that record, so
# it is reconciled instead of left lying.
xp_reconciled="$(ADVERTISED=8.2.0 xp_update_run 'manifest_set components.exapump.version 7.0.0')"
has "a lagging record is reconciled, not left lying" "Reconciling the recorded exapump version" "$xp_reconciled"
has "and the skip is still clean" "already current (8.2.0)" "$xp_reconciled"
check "the record now matches the binary" "8.2.0" "$(xp_record)"

# A record naming the target with no binary behind it is the other half of the same
# bug: the record must not vouch for something that is gone. PATH is stripped to the
# python3 the manifest reads need, or the probe's PATH fallback finds the tester's own
# exapump and this reads as installed.
xp_absent="$(ADVERTISED=8.2.0 xp_update_run \
    'rm -f "$XP/bin/exapump"; PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin"')"
lacks "a record with no binary behind it is not current" "already current" "$xp_absent"
has "the missing binary is reinstalled" "INSTALLED 8.2.0" "$xp_absent"

# An install AHEAD of the tested set must still not be dragged back — and this now
# matters more, because the guard inside exapump_update no longer accidentally
# refuses it via a matching record. The refusal belongs to the one hard guard in
# exakit_update_component, which reads the same probe, so this drives the real
# updater through that choke point rather than calling it directly.
xp_binary 9.9.9
xp_ahead="$( XP_ENTRY=exakit_update_component ADVERTISED=8.2.0 xp_update_run )"
has "an install ahead of the tested set is kept" "is newer than the tested" "$xp_ahead"
lacks "and nothing is installed over it" "INSTALLED" "$xp_ahead"
check "and the binary is untouched" "9.9.9" "$(xp_live)"

echo "exakit version reports what is on the machine, and only that:"
# Its own fixture on purpose: the cases above delete stubs to test absence, and this
# one needs them present. One runtime key only (a real manifest has version OR image).
DR="$WORK/drift-home"
mkdir -p "$DR/bin" "$DR/venv/bin" "$DR/kit/mcp"
cp "$REAL" "$DR/kit/versions.json"
printf '#!/bin/sh\necho "exapump 0.13.0"\n' > "$DR/bin/exapump"
rm -f "$DR/venv/bin/python"
printf '#!/bin/sh\necho 2.9.9\n' > "$DR/venv/bin/python"
chmod +x "$DR/bin/exapump" "$DR/venv/bin/python"
drift_manifest() {
    cat > "$DR/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": { "version": "0.2.0" },
  "runtime": { "type": "personal", "version": "2.2.0" },
  "components": {
    "exapump": { "version": "$1", "path": "$DR/bin/exapump" },
    "mcp_server": { "package": "exasol-mcp-server", "version": "1.10.1" },
    "pyexasol": { "version": "$2", "python": "$DR/venv/bin/python" }
  },
  "steps_completed": []
}
EOF
}
# EXAKIT_HOME has to be exported into the child: `exakit version` is a separate
# process, and a plain assignment in this shell would leave it reading the real
# installation instead of the fixture.
version_out() {
    EXAKIT_HOME="$DR" bash "$ROOT/setup/exakit" version 2>&1
}
# A component upgraded outside the kit reads as what it now IS. The cell used to
# carry a "(kit installed 0.11.2)" suffix as well, and it cost more than it said:
# the annotation is twice the width of the version it explains, so it widened every
# row of the table and pushed the card past 80 columns, and it had to be stripped
# back off before each comparison the table makes.
drift_manifest 0.11.2 2.2.2
drift_out="$(version_out)"
has "a hand-upgraded exapump reads as what it is" "exapump 0.13.0" "$(row "$drift_out" exapump)"
has "a hand-upgraded pyexasol reads as what it is" "pyexasol 2.9.9" "$(row "$drift_out" pyexasol)"
lacks "and the record is not printed beside it" "kit installed" "$drift_out"
# The same with nothing changed outside the kit: one number either way, so the
# reader cannot tell the two cases apart from the column, and does not need to.
drift_manifest 0.13.0 2.9.9
agree_out="$(version_out)"
lacks "and says nothing extra when they agree" "kit installed" "$agree_out"

echo "a component with no build for this machine is never offered:"
# exapump publishes nothing for Windows on ARM, and nothing for a CPU outside
# x86_64/arm64. Offering `exakit update exapump` there fails deep inside the installer,
# so the row says why instead.
unsupported_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    detect_arch() { printf unsupported; }
    exakit_print_version_table 2>&1 )"
has "the row says not available" "exapump not available" "$(row "$unsupported_row" exapump)"
has "and explains why once" "no exapump build exists for this platform" "$unsupported_row"
lacks "and offers no command" "exakit update exapump" "$unsupported_row"
unsupported_apply="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    detect_arch() { printf unsupported; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    ( exakit_update exapump </dev/null 2>&1 ) )"
has "an explicit update explains rather than failing deep" "no build for this platform" "$unsupported_apply"
lacks "and installs nothing" "APPLIED" "$unsupported_apply"

echo "the table's verdict binds the apply path too:"
# uc_run <statements> — `exakit update all` against the fixture, with the real
# component updaters replaced by a marker so the decisions are what is observed.
uc_run() (
    EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    eval "${1:-}"
    ( exakit_update all </dev/null 2>&1 ); printf 'rc=%s' "$?"
)

min_kit_apply="$(uc_run 'exakit_component_min_kit() { [ "$1" = mcp ] && printf "9.9.9\n"; return 0; }')"
has "a kit-blocked component says so" "needs kit >= 9.9.9" "$min_kit_apply"
lacks "and is not installed anyway" "APPLIED mcp" "$min_kit_apply"
has "while the rest of the run continues" "APPLIED pyexasol" "$min_kit_apply"

ahead_skip="$(uc_run)"
lacks "an install ahead of the manifest is never downgraded" "APPLIED exapump" "$ahead_skip"
has "and the skip is stated" "is newer than the tested 0.12.0" "$ahead_skip"
has "but its neighbours still are" "APPLIED mcp" "$ahead_skip"
has "and the run itself succeeds" "rc=0" "$ahead_skip"

# The table lists the runtime this machine actually runs, and only that one.
# `exakit update-check <runtime>` used to render a row on request; the merged
# `exakit version` takes no target, and inventing a row for a runtime nobody
# installed would offer to deploy a database onto a machine that never had one
# — which is exactly the install the kit refuses to do.
personal_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_version_table 2>&1 )"
has "the installed runtime is the one listed" "personal 2.2.0" "$(row "$personal_row" personal)"
lacks "no second runtime row is invented" "runtime " "$personal_row"

echo "the advertised version matches the policy in force:"
pinned_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSION_POLICY=pinned
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_version_table 2>&1 )"
# Asserted on pyexasol, not exapump: the fixture's exapump is installed AHEAD of
# every advertised set, and an ahead row says only "none" — so the number it is
# ahead of is not on the screen to match, whatever policy produced it. pyexasol is
# not installed at all, so its row names the version the policy resolved.
has "pinned policy offers the built-in fallback" "$EXAKIT_PYEXASOL_VERSION_FALLBACK available" "$pinned_row"
has "and says where that came from" "built-in fallbacks" "$pinned_row"
lacks "not the manifest" "versions manifest that shipped" "$pinned_row"

override_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_EXAPUMP_VERSION=9.9.9
    exakit_print_version_table 2>&1 )"
has "an override reaches the advertised version" "9.9.9" "$override_row"
has "and is credited as an override" "EXAKIT_* environment overrides" "$override_row"
lacks "the maintainers' note is withheld from it" "mis-detects CSV headers" "$override_row"

unreadable_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$WORK/no-such-cache.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_repo_root() { return 1; }
    exakit_print_version_table 2>&1 )"
has "no readable document is stated plainly" "could not be read" "$unreadable_row"
has "and the row admits it does not know" "inspect" "$unreadable_row"

echo "never backwards (no prompt, no override, no exception):"
ahead="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    if exakit_component_is_ahead exapump; then printf 'ahead '; else printf 'NOT-AHEAD '; fi
    # The env override that used to pre-answer the confirmation must not resurrect
    # the behaviour now that the confirmation itself is gone.
    EXAKIT_ALLOW_DOWNGRADE=1
    if exakit_component_is_ahead exapump; then printf 'still-ahead'; else printf 'OVERRIDDEN'; fi )"
check "an install ahead of the manifest stays ahead, override or not" \
    "ahead still-ahead" "$ahead"
# The behaviour that used to prompt: asking for that component by name must now
# succeed and do nothing, rather than fail or ask.
one_ahead="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    ( exakit_update exapump </dev/null 2>&1 ); printf 'rc=%s' "$?" )"
has "asking for it by name explains the skip" "is newer than the tested 0.12.0" "$one_ahead"
lacks "and applies nothing" "APPLIED exapump" "$one_ahead"
lacks "without asking anything" "Downgrade" "$one_ahead"
has "and exits clean" "rc=0" "$one_ahead"

echo "a failed component cannot strand the install:"
# The failure this prevents: exapump has 32 die() calls and runs three steps before
# the exakit command is installed, so a broken download used to leave a deployed
# database, no CLI, and nothing to repair it with but the whole installer again.
mkdir -p "$WORK/soft-kit"
cp "$REAL" "$WORK/soft-kit/versions.json"
soft="$( EXAKIT_HOME="$WORK/soft-home"
    EXAKIT_MANIFEST="$WORK/soft-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/soft-home/bin"
    mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    # exapump dies the way a bad download does; MCP works; pyexasol misses softly.
    exapump_install() { die "Could not install exapump"; }
    exapump_create_profile() { :; }
    exapump_validate_connection() { :; }
    mcp_install() { :; }
    mcp_validate() { :; }
    pyexasol_install() { return 1; }
    pyexasol_validate() { :; }
    exakit_maybe_offer_data_load() { printf 'OFFERED-DATA-LOAD\n'; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    # exakit_print_soft_failures is called by the setup scripts AFTER the
    # connection panel (so the account of what is missing is the last thing on
    # screen), not from inside kit_shared_steps. Same shell, same order here.
    _out="$(kit_shared_steps 3 6 "$ROOT/setup" "$WORK/soft-kit" 2>&1; exakit_print_soft_failures 2>&1)"
    [ -x "$EXAKIT_BIN_DIR/exakit" ] && printf 'cli ' || printf 'NO-CLI '
    printf '%s ' "$(manifest_get steps_completed | tr -d '\" []' )"
    printf '%s\n' "$_out" | grep -q 'OFFERED-DATA-LOAD' && printf 'data-offered' || printf 'data-skipped'
    printf ' '
    printf '%s\n' "$_out" | grep -q 'exakit update' && printf 'repair-exapump' || printf 'NO-REPAIR-EXAPUMP'
    printf ' '
    printf '%s\n' "$_out" | grep -q 'exakit update' && printf 'repair-pyexasol' || printf 'NO-REPAIR-PYEXASOL' )"
check "a dying component leaves a working CLI, a repair line, and no half-marked step" \
    "cli mcp,exakit_helper data-skipped repair-exapump repair-pyexasol" "$soft"

# Nothing failing must not produce a summary out of thin air.
quiet="$( EXAKIT_HOME="$WORK/soft-ok-home"
    EXAKIT_MANIFEST="$WORK/soft-ok-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/soft-ok-home/bin"
    mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    exapump_install() { :; }
    exapump_create_profile() { :; }
    exapump_validate_connection() { :; }
    mcp_install() { :; }
    mcp_validate() { :; }
    pyexasol_install() { :; }
    pyexasol_validate() { :; }
    exakit_maybe_offer_data_load() { :; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    _out="$(kit_shared_steps 3 6 "$ROOT/setup" "$WORK/soft-kit" 2>&1; exakit_print_soft_failures 2>&1)"
    printf '%s\n' "$_out" | grep -q 'did not complete' && printf 'SPURIOUS' || printf 'silent'
    printf ' %s' "$(manifest_get steps_completed | tr -d '\" []' )" )"
check "a clean run says nothing and marks everything" \
    "silent exapump,mcp,pyexasol,exakit_helper" "$quiet"
echo "release notes travel with the kit:"
mkdir -p "$WORK/wn-kit/setup"
cat > "$WORK/wn-kit/setup/whats-new.json" <<'WN_ONE'
{
  "_comment": "keys starting with _ are notes to maintainers, never versions",
  "0.3.0": ["the newer thing"],
  "0.2.0": ["the older thing"]
}
WN_ONE
check "a version's lines are read as its own" "  - the older thing" \
    "$(exakit_whats_new_points "$WORK/wn-kit" 0.2.0 | head -1)"
check "the later version is separate" "  - the newer thing" \
    "$(exakit_whats_new_points "$WORK/wn-kit" 0.3.0 | head -1)"
# Silence, not noise, for the cases a real upgrade meets.
check "an unknown version is silent" "rc=1" \
    "$(exakit_whats_new_points "$WORK/wn-kit" 9.9.9 >/dev/null 2>&1; printf 'rc=%s' "$?")"
check "a kit copy without the file is silent" "rc=1" \
    "$(exakit_whats_new_points "$WORK" 0.2.0 >/dev/null 2>&1; printf 'rc=%s' "$?")"
# A key with an empty list must not print an empty card.
printf '{"0.4.0": [], "0.3.0": ["real"]}\n' > "$WORK/wn-kit/setup/whats-new.json"
check "an empty list counts as no card" "rc=1" \
    "$(exakit_whats_new_points "$WORK/wn-kit" 0.4.0 >/dev/null 2>&1; printf 'rc=%s' "$?")"
# A hand-edited file with a syntax error must not end a successful upgrade.
printf '{"0.3.0": ["oops",]}\n' > "$WORK/wn-kit/setup/whats-new.json"
check "a malformed file is silent, not fatal" "rc=1" \
    "$(exakit_whats_new_points "$WORK/wn-kit" 0.3.0 >/dev/null 2>&1; printf 'rc=%s' "$?")"
# The comment key is not a version.
printf '{"_comment": ["not a version"], "0.3.0": ["real"]}\n' > "$WORK/wn-kit/setup/whats-new.json"
check "a _comment key is never offered as a version" "0.3.0" \
    "$(exakit_whats_new_versions "$WORK/wn-kit" | tr '\n' ' ' | sed 's/ $//')"

echo "the post-install \"What's new\" box:"
# The box is the one place an upgrading user learns what they just got, and the
# installer is documented as safe to re-run - so a run that moved the kit version
# has to say so, and every other run has to stay completely silent.
#
# Sentinels, not real note text: the fixture below is the only file that contains
# them, so a test cannot pass by accidentally reading this checkout's cards.
cat > "$WORK/wn-notes.json" <<'WN_NOTES'
{
  "_comment": "0.4.5 has no lines at all: a version can ship with nothing to say.",
  "0.4.5": [],
  "0.4.0": ["future-sentinel-040"],
  "0.25.0": ["lexical-trap-sentinel-025"],
  "0.3.0": [
    "three-oh point one",
    "three-oh point two, which runs on and on and on and on and on and on and on past any width a drawn card could hold",
    "three-oh point three",
    "three-oh point four",
    "three-oh point five",
    "three-oh point six",
    "seventh-point-past-the-cap"
  ],
  "0.2.0": ["two-oh-sentinel", "two-oh second point"],
  "0.1.5": ["one-five-sentinel"],
  "0.1.0": ["ancient-sentinel-must-not-appear"]
}
WN_NOTES

# wn_kit <version> — a kit tree that states <version> about itself and carries the
# fixture notes.
wn_kit() {
    mkdir -p "$WORK/wn-kit-$1"
    python3 - "$REAL" "$WORK/wn-kit-$1/versions.json" "$1" <<'WN_KIT_PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["kit"]["version"] = sys.argv[3]
json.dump(doc, open(sys.argv[2], "w"), indent=2)
WN_KIT_PY
    mkdir -p "$WORK/wn-kit-$1/setup"
    cp "$WORK/wn-notes.json" "$WORK/wn-kit-$1/setup/whats-new.json"
}
for wn_v in 0.1.0 0.1.5 0.2.0 0.3.0 0.4.0 0.4.5; do wn_kit "$wn_v"; done

# wn_run <home-tag> <kit-version> [die] — one installer run against one home: the
# record taken while the manifest still holds the previous number, the kit.version
# write, and the box at the end. `die` stops before the box, which is what a run
# that fails partway leaves behind.
wn_run() {
    ( EXAKIT_HOME="$WORK/wn-home-$1"
      EXAKIT_MANIFEST="$WORK/wn-home-$1/manifest.json"
      EXAKIT_BIN_DIR="$WORK/wn-home-$1/bin"
      mkdir -p "$EXAKIT_HOME"
      manifest_init >/dev/null 2>&1
      _wr_root="$WORK/wn-kit-$2"
      exakit_note_kit_upgrade "$_wr_root"
      _wr_v="$(exakit_kit_version_at "$_wr_root" 2>/dev/null || true)"
      [ -n "$_wr_v" ] && manifest_set kit.version "$_wr_v"
      [ "${3:-}" = "die" ] && exit 0
      exakit_print_whats_new_box "$_wr_root" 2>&1 )
}
wn_pending() { manifest_get kit.whats_new_from 2>/dev/null || true; }
wn_shape() {
    if [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; then printf 'silent'; else printf 'printed'; fi
}
# The version headings the box printed, in the order it printed them.
wn_order() {
    printf '%s\n' "$1" | sed -n 's/.*new in \([0-9][0-9.]*\).*/\1/p' \
        | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 } END { printf "\n" }'
}

check "a first-ever install shows no box" "silent" "$(wn_shape "$(wn_run first 0.3.0)")"
# Same home again, now moving 0.3.0 -> 0.4.0.
wn_upgrade="$(wn_run first 0.4.0)"
check "an upgrade shows one" "printed" "$(wn_shape "$wn_upgrade")"
has "with the version it moved to" "new in 0.4.0" "$wn_upgrade"
has "and that version's points" "future-sentinel-040" "$wn_upgrade"
has "and the line that names the move" "moved from 0.3.0 to 0.4.0" "$wn_upgrade"
lacks "not the points of a version it already had" "lexical-trap-sentinel-025" "$wn_upgrade"
check "an idempotent re-run at the same version shows none" "silent" \
    "$(wn_shape "$(wn_run first 0.4.0)")"

# One box for the whole jump, oldest hop first. A per-hop box, or a box for the
# newest hop only, both fail here.
wn_run cum 0.1.0 >/dev/null
wn_cum="$(wn_run cum 0.3.0)"
# One card per version crossed, not one box for the jump: three hops, three
# cards, so a reader can take them one at a time.
check "a 0.1.0 -> 0.3.0 upgrade draws one card per version" "3" \
    "$(printf '%s\n' "$wn_cum" | grep -c "new in")"
check "covering every version in between, oldest first" "0.1.5 0.2.0 0.3.0" \
    "$(wn_order "$wn_cum")"
has "with the points of the middle hop" "two-oh-sentinel" "$wn_cum"
has "and the points of the newest hop" "three-oh point one" "$wn_cum"
lacks "and nothing from the version already installed" "ancient-sentinel-must-not-appear" "$wn_cum"
lacks "and nothing from a version not installed yet" "future-sentinel-040" "$wn_cum"
# 0.25.0 sorts BEFORE 0.3.0 as a string and AFTER it as a version: a lexical
# comparison would smuggle notes for a release the user does not have into the box.
lacks "and nothing from a version that only sorts low as text" "lexical-trap-sentinel-025" "$wn_cum"
# Authoring length is guarded by tests/whats-new.sh; this proves the runtime
# fallback still cuts a line that somehow got through, rather than blowing out
# the card's borders.
has "an over-long line is still cut to the card width" "on and..." "$wn_cum"
lacks "and only the first few points of a version are shown" "seventh-point-past-the-cap" "$wn_cum"
check "the widest line still fits a terminal" "fits" \
    "$(printf '%s\n' "$wn_cum" | awk 'length($0) > 90 { print "TOO-WIDE: " length($0); exit } END { print "fits" }')"

# A version documented with prose but no points has nothing to put in a box, and an
# empty box is worse than no box.
wn_run none 0.4.0 >/dev/null
check "a version with no points shows no empty box" "silent" \
    "$(wn_shape "$(wn_run none 0.4.5)")"

# The record is in the manifest for exactly this case: the first run overwrote
# kit.version and then died, so nothing but the record knows a hop is unannounced.
wn_run die 0.1.5 >/dev/null
wn_run die 0.3.0 die >/dev/null 2>&1
wn_after_death="$(wn_run die 0.3.0)"
has "a run that died partway still gets its box next time" "two-oh-sentinel" "$wn_after_death"
has "measured from before the run that died" "moved from 0.1.5 to 0.3.0" "$wn_after_death"
check "and the record is spent once the box is drawn" "" \
    "$( EXAKIT_MANIFEST="$WORK/wn-home-die/manifest.json"; wn_pending )"

# Backwards is not an upgrade: nothing recorded, nothing printed, and no marker
# left behind for a later run to resolve.
wn_run down 0.3.0 >/dev/null
check "a downgrade shows no box" "silent" "$(wn_shape "$(wn_run down 0.1.5)")"
check "and records nothing" "" \
    "$( EXAKIT_MANIFEST="$WORK/wn-home-down/manifest.json"; wn_pending )"

# Cosmetic means cosmetic: a kit copy with no notes file at all must print nothing
# and still finish clean.
mkdir -p "$WORK/wn-kit-nofile"
cp "$WORK/wn-kit-0.3.0/versions.json" "$WORK/wn-kit-nofile/versions.json"
wn_nofile="$( EXAKIT_HOME="$WORK/wn-home-nofile"
    EXAKIT_MANIFEST="$WORK/wn-home-nofile/manifest.json"
    mkdir -p "$EXAKIT_HOME"
    manifest_init >/dev/null 2>&1
    manifest_set kit.version 0.1.0
    manifest_set kit.whats_new_from 0.1.0
    exakit_print_whats_new_box "$WORK/wn-kit-nofile" 2>&1
    printf 'rc=%s' "$?" )"
check "a kit copy without the notes file prints nothing and succeeds" "rc=0" "$wn_nofile"

echo "a hanging container engine cannot stall a version lookup:"
# The failure this prevents: an engine probe that does not return while the
# engine is still starting left `exakit version` printing nothing for as long
# as that took.
mkdir -p "$WORK/hang-bin"
printf '#!/bin/sh\nsleep 300\n' > "$WORK/hang-bin/podman"
chmod +x "$WORK/hang-bin/podman"
hang_start="$(date +%s)"
hang="$( PATH="$WORK/hang-bin:$PATH"
    EXAKIT_ENGINE_PROBE_TIMEOUT=2
    # detect.sh is where the engine detection lives, and this file does not source
    # it by default: without this the call is a silent "command not found", which
    # looks exactly like a pass.
    . "$ROOT/setup/lib/detect.sh"
    if [ "$(detect_podman)" = "none" ]; then printf 'gave-up'; else printf 'HUNG-OR-FOUND'; fi )"
hang_elapsed=$(( $(date +%s) - hang_start ))
check "a podman that never answers is treated as no engine" "gave-up" "$hang"
if [ "$hang_elapsed" -le 20 ]; then
    check "and it gives up promptly" "prompt" "prompt"
else
    check "and it gives up promptly" "prompt" "took ${hang_elapsed}s"
fi
# The bounded runner's own contract, independent of the engine.
bounded="$( if exakit_run_bounded 2 sleep 30 >/dev/null 2>&1; then printf 'NO-CUTOFF'; else printf "rc=$?"; fi
            printf ' '
            if exakit_run_bounded 5 printf 'ok' >/dev/null 2>&1; then printf 'fast-ok'; else printf 'FAST-FAILED'; fi )"
check "the runner cuts off a hang and passes a quick command through" "rc=124 fast-ok" "$bounded"

echo "the manifest date reads as a date:"
# A calendar date must never be shifted into local time: TZ is set to a zone west
# of UTC to prove the day does not move backwards.
dates="$( TZ="Pacific/Honolulu"
    printf '%s|' "$(exakit_format_manifest_date 2026-07-29)"
    printf '%s|' "$(exakit_format_manifest_date 2026-01-09)"
    printf '%s|' "$(exakit_format_manifest_date 2026-12-31)"
    printf '%s|' "$(exakit_format_manifest_date not-a-date)"
    printf '%s|' "$(exakit_format_manifest_date 2026-13-01)"
    printf '%s' "$(exakit_format_manifest_date '')" )"
check "formatted, zero-stripped, and passed through when unparseable" \
    "July 29, 2026|January 9, 2026|December 31, 2026|not-a-date|2026-13-01|" "$dates"
source_line="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_versions_source_line 2>&1 )"
has "and the source line spells it out" "updated July 29, 2026" "$source_line"
lacks "with no ISO date left" "2026-07-29" "$source_line"

echo "after-command notice (severity-gated, once a day, stderr only):"
NT="$WORK/notice-home"
mkdir -p "$NT/kit/mcp" "$NT/cache" "$NT/bin"
cp "$REAL" "$NT/kit/versions.json"
# What this install is ON, and what the fixture document advertises. Both ends are
# deliberately out of reach of any release rather than a step either side of
# whatever versions.json says today.
#
# The install is ancient because these checks need it behind the SHIPPED document,
# and a version set lowered by the maintainers (a withdrawn release, a test set)
# would otherwise catch up with the fixture and quietly delete the premise.
# The advertised values are unreachable for the mirror-image reason: 0.12.0 was the
# next plausible exapump release, so a weekly bump could walk into it and turn
# "the advertised set differs from the shipped set" into a fiction that no
# assertion here would notice.
# The KIT'S OWN version, read from the shipped document rather than pinned.
#
# It was pinned at "0.2.0" in the manifest below, and the moment the kit reached
# 0.2.1 the kit itself became a pending light bump -- so the notice correctly
# said "A recommended update is available for exakit, exapump, mcp" while every
# assertion here anchors on "...available for exapump". Five of them failed at
# once, none of them naming the reason, and they stayed failing.
#
# The same rot the comment above guards against for exapump; the kit's own
# version was simply left out of that reasoning. Read dynamically it cannot
# drift again: the kit is neither behind nor ahead of the document, so it is not
# pending, and the premise -- that exapump, mcp and the runtime are the only
# things behind -- is restored and stays true through any future bump.
NOTICE_KIT_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kit"]["version"])' "$REAL" 2>/dev/null || printf '0.0.0')"
NOTICE_INSTALLED_EXAPUMP="0.0.1"
NOTICE_INSTALLED_MCP="0.0.1"
NOTICE_ADVERTISED_EXAPUMP="99.1.0"
NOTICE_ADVERTISED_MCP="99.2.0"
NOTICE_ADVERTISED_PERSONAL="99.3.0"
printf '#!/bin/sh\necho "exapump %s"\n' "$NOTICE_INSTALLED_EXAPUMP" > "$NT/bin/exapump"
chmod +x "$NT/bin/exapump"
cat > "$NT/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": {
    "version": "$NOTICE_KIT_VERSION"
  },
  "runtime": {
    "type": "personal",
    "version": "2.2.0"
  },
  "components": {
    "exapump": {
      "version": "$NOTICE_INSTALLED_EXAPUMP",
      "path": "$NT/bin/exapump"
    },
    "mcp_server": {
      "version": "$NOTICE_INSTALLED_MCP"
    }
  },
  "steps_completed": []
}
EOF
# Advertise one recommended light bump and one critical heavy bump. The mcp bump is
# a genuine normal-severity one: the recorded install is far behind it, so it is
# pending. Without the version change there is nothing to announce, and an assertion
# about it would pass or fail for the wrong reason -- which is why fixture_doc
# refuses a version the shipped document has already reached.
fixture_doc "notice: an advertised set the install is behind" "$WORK/notice-versions.json" \
    "components.exapump.version=$NOTICE_ADVERTISED_EXAPUMP" \
    "components.exapump.severity=recommended" \
    "components.personal.version=$NOTICE_ADVERTISED_PERSONAL" \
    "components.personal.severity=critical" \
    "components.mcp.version=$NOTICE_ADVERTISED_MCP" \
    "components.mcp.severity=normal"

# The notice refuses to speak unless stderr is a terminal, so the harness has to
# provide one. script(1) does that, with two different command lines in the wild:
# BSD/macOS takes the command as arguments, util-linux takes it after -c.
NOTICE_PTY="none"
if command -v script >/dev/null 2>&1; then
    # stdin must be /dev/null: macOS script(1) refuses to start when its stdin is
    # a socket, which is what a CI or agent shell hands it.
    if script -q /dev/null /bin/echo probe </dev/null >/dev/null 2>&1; then
        NOTICE_PTY="bsd"
    elif script -q -c "/bin/echo probe" /dev/null </dev/null >/dev/null 2>&1; then
        NOTICE_PTY="util-linux"
    fi
fi

# notice <versions-doc> [statements] — run the notice on a pty and return what it
# wrote, stripped of the line breaks the pty inserts at its 80-column edge (a wrap
# must not be able to hide a phrase from an assertion) and of script(1)'s own EOT.
notice() {
    _n_doc="$1"
    _n_extra="${2:-}"
    cp "$_n_doc" "$NT/kit/versions.json"
    cat > "$WORK/notice-run.sh" <<EOF
EXAKIT_NO_FANCY=1
EXAKIT_HOME='$NT'
EXAKIT_MANIFEST='$NT/manifest.json'
EXAKIT_VERSIONS_CACHE='$NT/cache/versions.json'
EXAKIT_VERSIONS_URL='http://offline.invalid/versions.json'
EXAKIT_NOTICE_STATE='$NT/cache/notice-state.json'
. '$ROOT/setup/lib/common.sh'
_EXAKIT_VERSIONS_DOC=''; _EXAKIT_VERSIONS_SOURCE=''
$_n_extra
exakit_notice_after_command
EOF
    case "$NOTICE_PTY" in
        bsd)        script -q /dev/null /bin/bash "$WORK/notice-run.sh" </dev/null 2>&1 ;;
        util-linux) script -q -c "/bin/bash $WORK/notice-run.sh" /dev/null </dev/null 2>&1 ;;
        *)          printf '' ;;
    esac | tr -d '\r\n\004\010' | sed 's/\^D//g'
}

if [ "$NOTICE_PTY" = "none" ]; then
    # Without a pty the notice cannot be observed at all (that is its own gate).
    for _skipped in "a recommended light bump is announced as recommended" "with the cheap command" \
                    "a critical heavy bump is announced as critical" "as a database stop, not a one-liner" \
                    "and never told to just run update" "the kill switch is advertised" \
                    "a normal-severity bump is announced too" \
                    "and it speaks again on the very next command" \
                    "an explicit interval still shows it once" \
                    "and then holds off for the interval" \
                    "a routine bump is announced" "without claiming it is recommended" \
                    "or critical" "the kill switch silences it" \
                    "an install ahead of the tagged set is not announced" \
                    "nor the other component that overshot" \
                    "and no light line is printed at all" \
                    "while a component genuinely behind is still announced" \
                    "and a cached plan does not resurrect it" \
                    "while the cached plan keeps the real one" \
                    "latest policy has no severities to gate on"; do
        check "$_skipped" "skipped" "skipped"
    done
else
# The premise, asserted rather than assumed: if the kit itself is pending, it
# joins the light group and every "...available for exapump" assertion below
# reads a list that starts with "exakit," instead. That is exactly how these
# five went quiet.
check "the kit itself is not pending" "not-pending" \
    "$(printf '%s' "$NOTICE_KIT_VERSION" | grep -q . && printf 'not-pending' || printf 'UNKNOWN')"
rm -f "$NT/cache/notice-state.json"
flagged="$(notice "$WORK/notice-versions.json")"
lacks "the kit is not in the notice" "available for exakit" "$flagged"
{
  echo "=== flagged ==="; printf '%s\n' "$flagged"
  echo "=== fixture exapump ==="
  python3 -c "import json;print(json.load(open('$WORK/notice-versions.json'))['components']['exapump'])" 2>&1
  echo "=== kit copy exapump ==="
  python3 -c "import json;print(json.load(open('$NT/kit/versions.json'))['components']['exapump'])" 2>&1
  echo "=== manifest ==="; cat "$NT/manifest.json" 2>&1
  echo "=== cache dir ==="; ls -la "$NT/cache/" 2>&1
  echo "=== stub ==="; cat "$NT/bin/exapump" 2>&1
  echo "=== NOTICE_PTY ==="; echo "$NOTICE_PTY"
} >> /tmp/vm-debug.out 2>&1
has "a recommended light bump is announced as recommended" \
    "A recommended update is available for exapump" "$flagged"
has "with the cheap command" "apply in seconds:  exakit update" "$flagged"
has "a critical heavy bump is announced as critical" \
    "A critical update is available for personal" "$flagged"
has "as a database stop, not a one-liner" "requires stopping the database" "$flagged"
lacks "and never told to just run update" "personal — apply in seconds" "$flagged"
# The kill switch is documented (help page, AGENTS.md), not printed: a footer
# explaining how to turn the notice off was longer than the notice.
lacks "the kill switch is not printed under the notice" "EXAKIT_NO_UPDATE_NOTICE" "$flagged"
# Every severity is announced now, so the routine one appears too - and appears
# WITHOUT borrowing urgency it was never given.
has "a normal-severity bump is announced too" "mcp" "$flagged"

repeat="$(notice "$WORK/notice-versions.json")"
has "and it speaks again on the very next command" \
    "A recommended update is available for exapump" "$repeat"

# The throttle is still there for anyone who wants it, just not the default. It
# needs a clean slate: the runs above have already recorded a "last shown".
rm -f "$NT/cache/notice-state.json"
throttled_first="$(notice "$WORK/notice-versions.json" 'EXAKIT_NOTICE_INTERVAL=86400')"
has "an explicit interval still shows it once" \
    "A recommended update is available for exapump" "$throttled_first"
throttled_again="$(notice "$WORK/notice-versions.json" 'EXAKIT_NOTICE_INTERVAL=86400')"
check "and then holds off for the interval" "" \
    "$(printf '%s' "$throttled_again" | tr -d '[:space:]')"
rm -f "$NT/cache/notice-state.json"

# The shipped document against an install that is behind it: a routine bump, which
# must now be mentioned, and must not call itself recommended or critical.
only_normal="$(notice "$REAL")"
has "a routine bump is announced" "update is available for exapump" "$only_normal"
lacks "without claiming it is recommended" "A recommended" "$only_normal"
lacks "or critical" "A critical" "$only_normal"

# An install that has overshot the advertised set has nothing pending, and the
# notice must not claim otherwise: `exakit version` renders those rows as
# "none" and `exakit update` says "keeping yours", so announcing them made the
# three commands disagree and pointed the user at a command that could do
# nothing. exapump and mcp are advertised BELOW the recorded 0.0.1 install;
# the runtime stays genuinely behind, to prove the skip is targeted and not a mute
# button. exapump is also flagged 'recommended', so if it were still counted the
# light line would appear and borrow that word.
fixture_doc "notice: an advertised set the install has overshot" "$WORK/notice-ahead.json" \
    "components.exapump.version=0.0.0" \
    "components.exapump.severity=recommended" \
    "components.mcp.version=0.0.0" \
    "components.mcp.severity=normal" \
    "components.personal.version=$NOTICE_ADVERTISED_PERSONAL" \
    "components.personal.severity=critical"
rm -f "$NT/cache/notice-state.json" "$NT/cache/notice-plan"
ahead_notice="$(notice "$WORK/notice-ahead.json")"
lacks "an install ahead of the tagged set is not announced" "exapump" "$ahead_notice"
lacks "nor the other component that overshot" "mcp" "$ahead_notice"
lacks "and no light line is printed at all" "apply in seconds" "$ahead_notice"
has "while a component genuinely behind is still announced" \
    "A critical update is available for personal" "$ahead_notice"
# The cached plan re-verification carried the same equality-only flaw, which is
# why the phantom line reappeared on every command instead of clearing itself.
ahead_cached="$(notice "$WORK/notice-ahead.json")"
lacks "and a cached plan does not resurrect it" "exapump" "$ahead_cached"
has "while the cached plan keeps the real one" \
    "A critical update is available for personal" "$ahead_cached"

# The plan cache: printed every run, computed rarely. Counted by a probe stub that
# appends a line each time it is asked, which is the only way to tell "said the same
# thing again" from "worked it out again".
# Counted at the exapump stub itself rather than by overriding a reader: the test
# then cannot pass because it guessed the wrong internal function name.
rm -f "$NT/cache/notice-plan" "$NT/cache/notice-state.json" "$WORK/probe-count"
printf '#!/bin/sh\nprintf x >> "%s"\necho "exapump %s"\n' "$WORK/probe-count" \
    "$NOTICE_INSTALLED_EXAPUMP" > "$NT/bin/exapump"
chmod +x "$NT/bin/exapump"
probe_count() { [ -f "$WORK/probe-count" ] && wc -c < "$WORK/probe-count" | tr -d ' ' || printf 0; }
cached_first="$(notice "$WORK/notice-versions.json")"
has "the first run still says its piece" "update is available" "$cached_first"
probes_after_first="$(probe_count)"
check "and it did probe" "yes" "$([ "$probes_after_first" -gt 0 ] && printf yes || printf no)"
plan_stamp() { sed -n 's/^computed_at=//p' "$NT/cache/notice-plan" 2>/dev/null | head -1; }
stamp_after_first="$(plan_stamp)"
cached_second="$(notice "$WORK/notice-versions.json")"
has "the second run says the same thing" "update is available" "$cached_second"
# Served from the plan, not worked out again. The probe count is no longer the signal:
# the cached path deliberately re-probes its pending candidates so it can never repeat
# an update that has already been taken.
check "and did not recompute the verdict" "$stamp_after_first" "$(plan_stamp)"

# A cached plan must not repeat an update the user has already taken. This is the
# real-world failure it fixes: a plan computed while MCP was mid-install kept saying
# "an update is available for mcp" while `exakit version`, run seconds later in
# the same session, reported everything current.
plan_detail="$(sed -n 's/^light=//p' "$NT/cache/notice-plan" | head -1)"
has "the plan records the advertised version with each candidate" "exapump:" "$plan_detail"
# The stub catches up. Nothing else changes -- not the manifest, not the document --
# which is precisely the blind spot a signature alone cannot see.
printf '#!/bin/sh\nprintf x >> "%s"\necho "exapump %s"\n' "$WORK/probe-count" \
    "$NOTICE_ADVERTISED_EXAPUMP" > "$NT/bin/exapump"
chmod +x "$NT/bin/exapump"
caught_up="$(notice "$WORK/notice-versions.json")"
lacks "a candidate that caught up is dropped" "for exapump" "$caught_up"
has "and the ones still behind are kept" "mcp" "$caught_up"
# Back to behind, so what follows sees the same fixture as before.
printf '#!/bin/sh\nprintf x >> "%s"\necho "exapump %s"\n' "$WORK/probe-count" \
    "$NOTICE_INSTALLED_EXAPUMP" > "$NT/bin/exapump"
chmod +x "$NT/bin/exapump"

# the version table computes the truth the long way, so it retires the plan: nothing it
# just contradicted may be repeated by the next command.
notice "$WORK/notice-versions.json" >/dev/null
retired="$( EXAKIT_HOME="$NT"
    EXAKIT_MANIFEST="$NT/manifest.json"
    EXAKIT_NOTICE_PLAN="$NT/cache/notice-plan"
    EXAKIT_VERSIONS_CACHE="$NT/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    [ -f "$EXAKIT_NOTICE_PLAN" ] && printf 'had-plan '
    exakit_print_version_table >/dev/null 2>&1
    [ -f "$EXAKIT_NOTICE_PLAN" ] && printf 'STILL-THERE' || printf 'retired' )"
check "the version table retires the cached plan" "had-plan retired" "$retired"

# A TTL of zero is how you ask for the old behaviour of always recomputing.
notice "$WORK/notice-versions.json" 'EXAKIT_NOTICE_PLAN_TTL=0' >/dev/null
check "a zero TTL recomputes every time" "yes" \
    "$([ "$(probe_count)" -gt "$probes_after_first" ] && printf yes || printf no)"

# Applying an update must silence it on the NEXT command, not fifteen minutes later.
# The manifest is what every update rewrites, so a change to it retires the plan --
# and it has to work when both happen inside the same second, which is why the plan
# is keyed on content and not on a timestamp.
rm -f "$NT/cache/notice-plan"
notice "$WORK/notice-versions.json" >/dev/null
plan_sig_before="$(sed -n 's/^sig=//p' "$NT/cache/notice-plan" | head -1)"
printf ' ' >> "$NT/manifest.json"
plan_still_fresh="$( EXAKIT_HOME="$NT"
    EXAKIT_MANIFEST="$NT/manifest.json"
    EXAKIT_NOTICE_PLAN="$NT/cache/notice-plan"
    EXAKIT_VERSIONS_CACHE="$NT/cache/versions.json"
    if _exakit_notice_plan_fresh; then printf 'STILL-FRESH'; else printf 'retired'; fi )"
check "a rewritten manifest retires the plan within the same second" "retired" "$plan_still_fresh"
check "the plan records what it was derived from" "yes" \
    "$([ -n "$plan_sig_before" ] && printf yes || printf no)"

# The bookkeeping must not leak: cksum on a missing cache file used to make the
# SHELL print a failed-redirection error, straight past the notice's own stderr.
no_cache_leak="$( EXAKIT_HOME="$NT"
    EXAKIT_MANIFEST="$NT/manifest.json"
    EXAKIT_VERSIONS_CACHE="$WORK/definitely-not-here.json"
    _exakit_notice_signature 2>&1 >/dev/null )"
check "a missing versions cache prints nothing" "" "$no_cache_leak"

kill_switch="$(notice "$WORK/notice-versions.json" 'EXAKIT_NO_UPDATE_NOTICE=1')"
check "the kill switch silences it" "" "$(printf '%s' "$kill_switch" | tr -d '[:space:]')"

latest_policy="$(notice "$WORK/notice-versions.json" 'EXAKIT_VERSION_POLICY=latest')"
check "latest policy has no severities to gate on" "" "$(printf '%s' "$latest_policy" | tr -d '[:space:]')"
fi

# The gate that keeps it out of logs and pipes: no tty on stderr, no notice.
piped="$( EXAKIT_HOME="$NT"
    EXAKIT_MANIFEST="$NT/manifest.json"
    EXAKIT_VERSIONS_CACHE="$NT/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    EXAKIT_NOTICE_STATE="$NT/cache/notice-state.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    cp "$WORK/notice-versions.json" "$NT/kit/versions.json"
    exakit_notice_after_command 2>&1 )"
check "no terminal on stderr, no notice" "" "$(printf '%s' "$piped" | tr -d '[:space:]')"

# The commands that must never carry it, and the ones that must.
if grep -q '_with_notice cmd_status' "$ROOT/setup/exakit" && \
   grep -q '_with_notice cmd_mcp_doctor' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_update' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_version' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_uninstall' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice usage' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_catalog' "$ROOT/setup/exakit"; then
    check "hooked into the right commands only" "yes" "yes"
else
    check "hooked into the right commands only" "yes" "no"
fi
# A notice may not change what a command reported to a script.
rc_preserved="$( _with_notice() { "$@"; _wn_rc=$?; exakit_notice_after_command || true; return $_wn_rc; }
    exakit_notice_after_command() { printf 'notice\n' >&2; return 0; }
    _with_notice false; printf 'rc=%s' "$?" )"
check "the command's exit status survives the notice" "rc=1" "$rc_preserved"

echo "Kit 2 awareness (the block's absence is the launch switch):"
# The shipped versions.json has no kit2 block, and nothing may advertise Kit 2
# until a reviewed pull request adds one. This is the gate, asserted directly.
check "the shipped manifest advertises no Kit 2" "absent" \
    "$(exakit_versions_value kit2.version "$REAL" 2>/dev/null || printf absent)"
K2="$WORK/kit2-home"
mkdir -p "$K2/kit/mcp" "$K2/cache"
cat > "$K2/manifest.json" <<'EOF'
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": {
    "version": "0.2.0"
  },
  "runtime": {
    "type": "personal",
    "version": "2.2.0"
  },
  "components": {},
  "steps_completed": []
}
EOF
cp "$REAL" "$K2/kit/versions.json"

# kit2_table <versions-doc> [statements] — the table as a Kit 1 (or stubbed Kit 2)
# machine would render it against the given advertised document.
kit2_table() (
    EXAKIT_HOME="$K2"
    EXAKIT_MANIFEST="$K2/manifest.json"
    EXAKIT_VERSIONS_CACHE="$K2/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    cp "$1" "$K2/kit/versions.json"
    eval "${2:-}"
    exakit_print_version_table 2>&1
)

no_kit2="$(kit2_table "$REAL")"
lacks "no kit2 block -> not a word about Kit 2" "Kit 2" "$no_kit2"
lacks "and no kit2 row" "kit2 " "$no_kit2"

# Enabling the path is exactly one edit: add the block.
python3 - "$REAL" "$WORK/with-kit2.json" <<'PY'
import json, sys, collections
with open(sys.argv[1]) as handle:
    doc = json.load(handle, object_pairs_hook=collections.OrderedDict)
doc["kit2"] = collections.OrderedDict(
    [("version", "0.1.0"), ("min_kit_version", "0.2.0"), ("severity", "normal"),
     ("note", "Trusted AI Workflow add-on")])
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
PY
with_kit2="$(kit2_table "$WORK/with-kit2.json")"
has "the block turns the discovery line on" "Kit 2 (Trusted AI Workflow add-on) is available" "$with_kit2"
has "and names the command" "exakit upgrade-kit2" "$with_kit2"
lacks "a Kit 1 machine gets no kit2 row" "kit2       " "$with_kit2"

# A kit too old for the add-on must not be told to add it.
python3 - "$WORK/with-kit2.json" "$WORK/with-kit2-future.json" <<'PY'
import json, sys, collections
with open(sys.argv[1]) as handle:
    doc = json.load(handle, object_pairs_hook=collections.OrderedDict)
doc["kit2"]["min_kit_version"] = "9.9.9"
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
PY
future_kit2="$(kit2_table "$WORK/with-kit2-future.json")"
lacks "an unsatisfied min_kit_version keeps it hidden" "Kit 2 (" "$future_kit2"

# Once Kit 2 is installed the discovery line gives way to a real row.
level2="$(kit2_table "$WORK/with-kit2.json" \
    'manifest_get() { case "$1" in kit_level) printf "2\n" ;;
                                   kit2.version) printf "0.1.0\n" ;;
                                   runtime.type) printf "personal\n" ;;
                                   kit.version) printf "0.2.0\n" ;;
                                   *) return 1 ;; esac; }')"
has "Kit 2 installed -> its own row" "kit2 0.1.0" "$(row "$level2" kit2)"
lacks "and no discovery line any more" "is available — add it with" "$level2"
level2_behind="$(kit2_table "$WORK/with-kit2.json" \
    'manifest_get() { case "$1" in kit_level) printf "2\n" ;;
                                   kit2.version) printf "0.0.9\n" ;;
                                   runtime.type) printf "personal\n" ;;
                                   kit.version) printf "0.2.0\n" ;;
                                   *) return 1 ;; esac; }')"
has "an older bundle offers the update" "kit2 0.0.9 0.1.0 available" "$(row "$level2_behind" kit2)"
has "and promotes the command that applies it" "Bring everything up to date with: exakit update" "$level2_behind"

# `exakit update kit2` is only meaningful once Kit 2 is installed, and it never
# invents assets the kit copy does not carry.
kit2_update_at_level1="$( EXAKIT_HOME="$K2"
    EXAKIT_MANIFEST="$K2/manifest.json"
    ( exakit_update_kit2 2>&1 ) )"
has "updating Kit 2 at Kit 1 explains itself" "Kit 2 is not installed" "$kit2_update_at_level1"
kit2_update_behind="$( EXAKIT_HOME="$K2"
    EXAKIT_MANIFEST="$K2/manifest.json"
    EXAKIT_VERSIONS_CACHE="$K2/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    cp "$WORK/with-kit2.json" "$K2/kit/versions.json"
    mkdir -p "$K2/kit/upgrade"
    printf '#!/usr/bin/env bash\necho STAGED\n' > "$K2/kit/upgrade/upgrade-kit2.sh"
    manifest_get() { [ "$1" = kit_level ] && printf '2\n' && return 0; return 1; }
    # This kit copy carries an older bundle than the manifest advertises.
    exakit_kit2_bundled_version() { printf '0.0.9\n'; }
    exakit_update_kit2 2>&1 )"
has "a kit copy behind the advertised bundle says so" "update it first" "$kit2_update_behind"
lacks "and stages nothing" "STAGED" "$kit2_update_behind"
kit2_update_current="$( EXAKIT_HOME="$K2"
    EXAKIT_MANIFEST="$K2/manifest.json"
    EXAKIT_VERSIONS_CACHE="$K2/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    manifest_get() { [ "$1" = kit_level ] && printf '2\n' && return 0; return 1; }
    exakit_kit2_bundled_version() { printf '0.1.0\n'; }
    exakit_update_kit2 2>&1 )"
has "a current kit copy re-stages the assets" "STAGED" "$kit2_update_current"
cp "$REAL" "$K2/kit/versions.json"

echo "kit self-update (stubbed download, no network):"
# A real tarball of a fake kit: the download is stubbed, but everything after it —
# unpacking, the required-file gate, the staged-version gate, the backup/swap and
# the recorded identity — is the production code path.
# make_kit_tarball <dest.tgz> <kit-version> [omit-path]
make_kit_tarball() {
    _mk_dest="$1"
    _mk_version="$2"
    _mk_omit="${3:-}"
    # Keyed by the archive being built, not by the version: two archives of the
    # same version (one deliberately incomplete) must not share a source tree.
    _mk_src="$WORK/kit-src-$(basename "$_mk_dest" | tr -c 'A-Za-z0-9' '_')"
    rm -rf "$_mk_src"
    MK_LAST_SRC="$_mk_src/repo-main"
    mkdir -p "$_mk_src/repo-main/setup/lib"
    for _mk_file in setup/exakit setup/lib/common.sh \
                    setup/lib/runtime-personal.sh setup/lib/exapump.sh setup/lib/mcp.sh \
                    setup/exakit.ps1 setup/lib/exakit-common.ps1; do
        [ "$_mk_file" = "$_mk_omit" ] && continue
        printf '# fake %s from kit %s\n' "$_mk_file" "$_mk_version" > "$_mk_src/repo-main/$_mk_file"
    done
    if [ "$_mk_omit" != "versions.json" ]; then
        # kit.version is set by key, not by matching the version the shipped
        # document happens to carry today: an archive is allowed to advertise the
        # shipped kit version (the checks here are against the INSTALLED 0.2.0 this
        # sandbox records), but a literal made the rewrite silently optional the
        # moment the kit released the number this test asks for.
        python3 - "$REAL" "$_mk_src/repo-main/versions.json" "$_mk_version" <<'MK_VERSIONS_PY'
import collections, json, sys
with open(sys.argv[1]) as handle:
    doc = json.load(handle, object_pairs_hook=collections.OrderedDict)
doc["kit"]["version"] = sys.argv[3]
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
MK_VERSIONS_PY
    fi
    # Release notes for the version this archive carries: the update prints them
    # from the copy it just staged, so they have to travel with it.
    mkdir -p "$_mk_src/repo-main/setup"
    printf '{"%s": ["a line only kit %s could print"]}\n' \
        "$_mk_version" "$_mk_version" > "$_mk_src/repo-main/setup/whats-new.json"
    ( cd "$_mk_src" && tar -czf "$_mk_dest" repo-main )
}

# self_update <served-tarball> <advertised> — run the real updater against a
# sandbox kit home and report what it did.
self_update() (
    EXAKIT_HOME="$WORK/su-home"
    EXAKIT_MANIFEST="$WORK/su-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/su-home/bin"
    rm -rf "$EXAKIT_HOME"
    mkdir -p "$EXAKIT_HOME/kit/mcp" "$EXAKIT_BIN_DIR"
    printf 'the kit copy that is about to be replaced\n' > "$EXAKIT_HOME/kit/marker.txt"
    cp "$REAL" "$EXAKIT_HOME/kit/versions.json"
    manifest_init >/dev/null 2>&1
    manifest_set kit.version 0.2.0 >/dev/null 2>&1
    SU_ADVERTISED="$2"
    SU_SERVE="$1"
    exakit_component_available() { printf '%s\n' "$SU_ADVERTISED"; }
    curl() {
        _co=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) _co="$2"; shift 2 ;;
                https://*) _su_url="$1"; shift ;;
                *) shift ;;
            esac
        done
        # Only the main branch archive exists in this world; the tag fallbacks 404.
        case "$_su_url" in
            *refs/heads/main.tar.gz) cp "$SU_SERVE" "$_co" ;;
            *) return 22 ;;
        esac
    }
    ( exakit_update_self >"$WORK/su-out.txt" 2>&1 ); printf 'rc=%s ' "$?"
    printf 'version=%s source=%s ' "$(manifest_get kit.version 2>/dev/null || printf none)" \
        "$(manifest_get kit.source 2>/dev/null || printf none)"
    [ -f "$EXAKIT_HOME/kit/versions.json" ] && printf 'kit-present ' || printf 'NO-KIT '
    grep -q 'fake setup/exakit ' "$EXAKIT_HOME/kit/setup/exakit" 2>/dev/null && printf 'replaced ' || printf 'not-replaced '
    [ -x "$EXAKIT_BIN_DIR/exakit" ] && printf 'cli-installed ' || printf 'NO-CLI '
    ls -d "$EXAKIT_HOME"/kit.backup-* >/dev/null 2>&1 && printf 'backup-kept' || printf 'NO-BACKUP'
)

make_kit_tarball "$WORK/kit-0.3.0.tgz" 0.3.0
PS_KIT_SRC="$MK_LAST_SRC"       # reused by the PowerShell self-update check below
# The recorded source is the kit repository the library defaults to, not a literal:
# which repository that is can be retargeted (a fork, for testing), and none of
# these checks are about its name.
check "a newer kit replaces the copy and records itself" \
    "rc=0 version=0.3.0 source=$EXAKIT_KIT_REPO@main kit-present replaced cli-installed backup-kept" \
    "$(self_update "$WORK/kit-0.3.0.tgz" 0.3.0)"

# The raw endpoint can be minutes ahead of the branch archive: record what landed.
make_kit_tarball "$WORK/kit-0.2.5.tgz" 0.2.5
lag_state="$(self_update "$WORK/kit-0.2.5.tgz" 0.3.0)"
check "a lagging archive records the version that landed" \
    "rc=0 version=0.2.5 source=$EXAKIT_KIT_REPO@main kit-present replaced cli-installed backup-kept" \
    "$lag_state"
has "and says the manifest was ahead" "not the advertised 0.3.0" "$(cat "$WORK/su-out.txt")"

# An archive without versions.json is refused: the new copy would have no offline
# version tier and could not say what it is.
make_kit_tarball "$WORK/kit-no-manifest.tgz" 0.3.0 versions.json
check "an archive without versions.json is refused" \
    "rc=1 version=0.2.0 source=none kit-present not-replaced NO-CLI NO-BACKUP" \
    "$(self_update "$WORK/kit-no-manifest.tgz" 0.3.0)"
has "and says the kit copy was left alone" "existing kit copy was left untouched" "$(cat "$WORK/su-out.txt")"

# One of v0.1.0's eight required paths missing must fail the same way.
make_kit_tarball "$WORK/kit-no-common.tgz" 0.3.0 setup/lib/common.sh
check "an archive missing a v0.1.0 required file is refused" \
    "rc=1 version=0.2.0 source=none kit-present not-replaced NO-CLI NO-BACKUP" \
    "$(self_update "$WORK/kit-no-common.tgz" 0.3.0)"

echo "Windows parity (versions manifest):"
if command -v pwsh >/dev/null 2>&1; then
    PS_HOME="$WORK/ps-home"
    mkdir -p "$PS_HOME/kit/mcp" "$PS_HOME/cache"
    cp "$REAL" "$PS_HOME/kit/versions.json"
    # A cached copy that differs from the kit copy proves which one is read. The
    # sentinel cannot coincide with whatever the document advertises today.
    PS_CACHED_EXAPUMP="0.0.0-from-the-cache"
    fixture_doc "powershell: cached exapump sentinel" "$PS_HOME/cache/versions.json" \
        "components.exapump.version=$PS_CACHED_EXAPUMP"
    touch "$PS_HOME/cache/versions.json"
    ps_state="$(EXAKIT_HOME="$PS_HOME" EXAKIT_BIN_DIR="$PS_HOME/bin" \
        EXAKIT_VERSIONS_CACHE="$PS_HOME/cache/versions.json" \
        EXAKIT_VERSIONS_URL="https://127.0.0.1:1/versions.json" \
        VM_ROOT="$ROOT" VM_FIX="$FIX" pwsh -NoProfile -Command '
        . (Join-Path $env:VM_ROOT "setup/lib/exakit-common.ps1")
        $real = Join-Path $env:VM_ROOT "versions.json"
        $out = @()
        $out += (Test-ExakitVersionsDoc -Path $real)
        $out += (Test-ExakitVersionsDoc -Path (Join-Path $env:VM_FIX "schema2.json"))
        $out += (Test-ExakitVersionsDoc -Path (Join-Path $env:VM_FIX "bad-digest.json"))
        $out += (Test-ExakitVersionsDoc -Path (Join-Path $env:VM_FIX "corrupt.json"))
        $out += (Test-ExakitVersionsDoc -Path (Join-Path $env:VM_FIX "kit2.json"))
        $out += (Get-ExakitVersionsValue -Path "components.exapump.version" -DocPath $real)
        $out += (Get-ExakitVersionsValue -Path "components.exapump.sha256.windows-x86_64" -DocPath $real).Substring(0, 8)
        $out += (Get-ExakitKitBundledVersion)
        # The TTL keeps a normal command off the network; -Force cannot reach
        # 127.0.0.1:1, and that failure must leave the cached copy in place.
        $out += (Update-ExakitVersionsCache)
        $out += (Update-ExakitVersionsCache -Force)
        $out += (Get-ExakitVersionsValue -Path "components.exapump.version")
        $out += (Get-ExakitVersionsSource)
        Write-Output ($out -join " ")
    ' | tail -1 | tr -d '\r')"
    check "powershell(versions_manifest)" \
        "0 2 1 1 0 $(shipped components.exapump.version) $(shipped components.exapump.sha256.windows-x86_64 | cut -c1-8) $(shipped kit.version) 2 1 $PS_CACHED_EXAPUMP cache" \
        "$ps_state"
    ps_http="$(EXAKIT_HOME="$PS_HOME" EXAKIT_BIN_DIR="$PS_HOME/bin" \
        EXAKIT_VERSIONS_CACHE="$PS_HOME/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://example.invalid/versions.json" \
        VM_ROOT="$ROOT" pwsh -NoProfile -Command '
        . (Join-Path $env:VM_ROOT "setup/lib/exakit-common.ps1")
        Write-Output (Update-ExakitVersionsCache -Force)
    ' | tail -1 | tr -d '\r')"
    check "powershell(non_https_refused)" "1" "$ps_http"

    # The table is mirrored code, so compare the real thing: run the PowerShell
    # CLI against the SAME fixture install and manifest the bash rows came from.
    # Both sides must reach the same verdict for every row.
    ps_table="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" version 2>&1 | tr -d '\r')"
    check "powershell: Component / Version / Status" \
        "Component Version Status" "$(row "$ps_table" Component)"
    has "powershell: kit row is comparable" "exakit 0.2.0 current" "$(row "$ps_table" exakit)"
    has "powershell: installed stays installed" "exapump 0.13.0" "$(row "$ps_table" exapump)"
    has "powershell: a waiting update names the version" \
        "personal 2.2.0 2.3.0 available" "$(row "$ps_table" personal)"
    check "powershell: older advertised version" \
        "exapump 0.13.0 none" "$(row "$ps_table" exapump)"
    has "powershell: critical severity" "critical" "$ps_table"
    has "powershell: maintainer note" "0.13.0 mis-detects CSV headers" "$ps_table"
    has "powershell: repair status for a missing component" \
        "pyexasol not installed 2.2.2 available (repair)" "$(row "$ps_table" pyexasol)"
    has "powershell: promotes update-all" "Bring everything up to date with: exakit update" "$ps_table"
    # The decisions the bash rows above make must be the same ones here.
    ps_personal="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" version 2>&1 | tr -d '\r')"
    has "powershell: the installed runtime is the one listed" "personal 2.2.0" "$(row "$ps_personal" personal)"
    lacks "powershell: no second runtime row is invented" "runtime " "$ps_personal"
    # The inline runtime offer is mirrored code, and the half that decides whether a
    # database may be stopped is the half that must not drift. The decision
    # functions are called directly (running `update all` here would download a real
    # kit), and the wording of the offer is compared against the bash lines above.
    ps_offer="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        VM_ROOT="$ROOT" pwsh -NoProfile -Command '
        . (Join-Path $env:VM_ROOT "setup/lib/exakit-common.ps1")
        # The offer helpers live in the CLI; load it with a harmless command.
        . (Join-Path $env:VM_ROOT "setup/exakit.ps1") -Command "help" *> $null
        $out = @()
        $out += (Get-ExakitRuntimeUpdatePreanswer -AssumeYes $true)
        $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "1"
        $out += (Get-ExakitRuntimeUpdatePreanswer)
        $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "no"
        $out += (Get-ExakitRuntimeUpdatePreanswer)
        $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = ""
        $answer = (Get-ExakitRuntimeUpdatePreanswer)
        if ($answer) { $out += $answer } else { $out += "unanswered" }
        $out += (Get-ExakitMajorVersion "2026.2.0")
        # A major change IS the staged (backup-gated) route - same verdict the
        # bash side reaches.
        $out += (Test-ExakitRuntimeUpdateStaged -Installed "1.5.0" -Advertised "2.0.0")
        Write-Output ($out -join " ")
    ' | tail -1 | tr -d '\r')"
    check "powershell(runtime_offer_decisions)" "yes yes no unanswered 2026 True" "$ps_offer"
    ps_explain="$(VM_ROOT="$ROOT" pwsh -NoProfile -Command '
        . (Join-Path $env:VM_ROOT "setup/lib/exakit-common.ps1")
        . (Join-Path $env:VM_ROOT "setup/exakit.ps1") -Command "help" *> $null
        Write-ExakitRuntimeUpdateExplanation -Actual "personal" -Installed "2.2.0" -Advertised "2.3.0"
    ' 2>&1 | tr -d '\r')"
    has "powershell: the offer names the outage" "needs the database stopped" "$ps_explain"
    has "powershell: the offer promises the restart" "started again if it ends up down" "$ps_explain"
    has "powershell: the offer says the data survives" "Your data is kept" "$ps_explain"
    ps_pinned="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" EXAKIT_VERSION_POLICY=pinned \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" version 2>&1 | tr -d '\r')"
    has "powershell: pinned policy uses the fallback" "built-in fallbacks" "$ps_pinned"
    ps_override="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        EXAKIT_EXAPUMP_VERSION=9.9.9 \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" version 2>&1 | tr -d '\r')"
    has "powershell: an override is credited" "EXAKIT_* environment overrides" "$ps_override"
    lacks "powershell: and withholds the maintainer note" "mis-detects CSV headers" "$ps_override"
    # The Windows self-update, for real: the download cmdlet is shadowed by a
    # function in the same session, so everything after it - the required-file
    # gate, the staged-version gate, the backup/swap, the shim and the recorded
    # identity - is the production path. (The deferred swap is Windows-only: it
    # exists because Windows will not rename a directory whose files are open, so
    # it cannot be provoked here.)
    PS_SU="$WORK/ps-su"
    rm -rf "$PS_SU"
    mkdir -p "$PS_SU/home/kit/mcp" "$PS_SU/home/bin"
    printf 'the kit copy that is about to be replaced\n' > "$PS_SU/home/kit/marker.txt"
    cp "$REAL" "$PS_SU/home/kit/versions.json"
    python3 - "$PS_KIT_SRC" "$PS_SU/kit-0.3.0.zip" <<'PY'
import pathlib, sys, zipfile
src, dest = pathlib.Path(sys.argv[1]), sys.argv[2]
with zipfile.ZipFile(dest, "w") as archive:
    for path in sorted(src.rglob("*")):
        if path.is_file():
            archive.write(path, pathlib.Path("repo-main") / path.relative_to(src))
PY
    ps_self="$(EXAKIT_HOME="$PS_SU/home" EXAKIT_BIN_DIR="$PS_SU/home/bin" \
        VM_ROOT="$ROOT" SU_ZIP="$PS_SU/kit-0.3.0.zip" pwsh -NoProfile -Command '
        . "$env:VM_ROOT/setup/lib/exakit-common.ps1"
        # Only the main-branch archive exists in this world; the tags 404.
        function Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec, $UserAgent)
            if ($Uri -notlike "*refs/heads/main.zip") { throw "404" }
            Copy-Item -Force $env:SU_ZIP $OutFile
        }
        Initialize-ExakitManifest
        Set-ExakitManifestValue "kit.version" "0.2.0"
        Update-ExakitSelf -Advertised "0.3.0" -Installed "0.2.0" | Out-Null
        $kit = Join-Path $env:EXAKIT_HOME "kit"
        $out = @()
        $out += (Get-ExakitManifestValue "kit.version")
        $out += (Get-ExakitManifestValue "kit.source")
        if (Test-Path (Join-Path $kit "versions.json")) { $out += "kit-present" } else { $out += "NO-KIT" }
        if ((Get-Content -Raw (Join-Path $kit "setup/exakit")) -like "*fake setup/exakit*") { $out += "replaced" } else { $out += "not-replaced" }
        if (Test-Path (Join-Path $env:EXAKIT_BIN_DIR "exakit.cmd")) { $out += "shim-written" } else { $out += "NO-SHIM" }
        if (Get-ChildItem -Path $env:EXAKIT_HOME -Filter "kit.backup-*" -ErrorAction SilentlyContinue) { $out += "backup-kept" } else { $out += "NO-BACKUP" }
        Write-Output ($out -join " ")
    ' 2>&1 | tail -1 | tr -d '\r')"
    # Nothing above sets EXAKIT_KIT_REPO for pwsh, so the slug in this line is the
    # PowerShell default measured against the bash one: the two must not drift.
    check "powershell(self_update)" \
        "0.3.0 $EXAKIT_KIT_REPO@main kit-present replaced shim-written backup-kept" \
        "$ps_self"
    # The notice is mirrored code and its wording carries the cost of the update, so
    # compare the real thing against the same fixture the bash lines came from.
    if [ "$NOTICE_PTY" != "none" ]; then
        rm -f "$NT/cache/notice-state.json"
        cp "$WORK/notice-versions.json" "$NT/kit/versions.json"
        cat > "$WORK/ps-notice.ps1" <<'PSEOF'
$env:EXAKIT_HOME = $env:NT
$env:EXAKIT_BIN_DIR = "$env:NT/bin"
$env:EXAKIT_VERSIONS_CACHE = "$env:NT/cache/versions.json"
$env:EXAKIT_VERSIONS_URL = "http://offline.invalid/versions.json"
$env:EXAKIT_NOTICE_STATE = "$env:NT/cache/notice-state.json"
. "$env:VM_ROOT/setup/lib/exakit-common.ps1"
# The component readers live in the CLI; load it with a harmless command.
. "$env:VM_ROOT/setup/exakit.ps1" -Command "help" *> $null
Show-ExakitUpdateNotice
PSEOF
        case "$NOTICE_PTY" in
            bsd) ps_notice="$(NT="$NT" VM_ROOT="$ROOT" script -q /dev/null                     pwsh -NoProfile -File "$WORK/ps-notice.ps1" </dev/null 2>&1)" ;;
            *)   ps_notice="$(NT="$NT" VM_ROOT="$ROOT" script -q                     -c "pwsh -NoProfile -File $WORK/ps-notice.ps1" /dev/null </dev/null 2>&1)" ;;
        esac
        ps_notice="$(printf '%s' "$ps_notice" | tr -d '\r\n\004\010' | sed 's/\^D//g')"
        has "powershell: recommended light bump" "A recommended update is available for exapump" "$ps_notice"
        has "powershell: critical heavy bump" "A critical update is available for personal" "$ps_notice"
        has "powershell: the heavy line names the cost" "requires stopping the database" "$ps_notice"
        cp "$REAL" "$NT/kit/versions.json"
    else
        check "powershell: recommended light bump" "skipped" "skipped"
        check "powershell: critical heavy bump" "skipped" "skipped"
        check "powershell: the heavy line names the cost" "skipped" "skipped"
    fi
    ps_version="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" version 2>&1 | tr -d '\r')"
    has "powershell: version reports the kit version" "Version " "$ps_version"
    has "powershell: version reports the kit version value" "0.2.0" "$ps_version"
    has "powershell: version renders the table" "Component Version Status" "$(row "$ps_version" Component)"
    has "powershell: version promotes update-all" "Bring everything up to date with: exakit update" "$ps_version"
    lacks "powershell: version prints no separate updates panel" "Updates available" "$ps_version"
    lacks "powershell: and points at no update-check" "update-check" "$ps_version"
else
    check "powershell(versions_manifest)" "skipped" "skipped"
    check "powershell(non_https_refused)" "skipped" "skipped"
    check "powershell(runtime_offer_decisions)" "skipped" "skipped"
    for _skipped in "Component / Version / Status" "kit row is comparable" "installed stays installed" \
                    "a waiting update names the version" "older advertised version" "critical severity" \
                    "maintainer note" "repair status for a missing component" \
                    "promotes update-all" \
                    "the installed runtime is the one listed" "the absent runtime gets no row" \
                    "and is never offered for installation" \
                    "pinned policy uses the fallback" "an override is credited" \
                    "and withholds the maintainer note" \
                    "the offer names the outage" "the offer promises the restart" \
                    "the offer says the data survives" \
                    "version reports the kit version" "version renders the table" \
                    "version promotes update-all" "version prints no separate updates panel" \
                    "and points at no update-check" "(self_update)" \
                    "recommended light bump" "critical heavy bump" \
                    "the heavy line names the cost"; do
        check "powershell: $_skipped" "skipped" "skipped"
    done
fi

# ---------------------------------------------------------------------------
echo "an installed kit follows its own source:"
# THE BUG: EXAKIT_KIT_REPO defaulted to the published repository and never read
# the manifest, while json_tables_mirror_repo already followed kit.source. A
# kit installed from a fork downloaded release assets from the fork and digest
# pins from the default - a split brain where every add-on install died on a
# checksum mismatch that looked like corruption - and `exakit update exakit`
# would have replaced the fork's kit with the default repository's code.
_SRC_HOME="$WORK/kit-source-home"
mkdir -p "$_SRC_HOME"
printf '{"kit":{"source":"owner-a/fork-b@main"}}\n' > "$_SRC_HOME/manifest.json"
check "the manifest's kit.source decides the repo" "owner-a/fork-b" "$(
    EXAKIT_HOME="$_SRC_HOME" bash -c '. "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1; printf %s "$EXAKIT_KIT_REPO"')"
check "and the versions URL follows it" \
    "https://raw.githubusercontent.com/owner-a/fork-b/main/versions.json" "$(
    EXAKIT_HOME="$_SRC_HOME" bash -c '. "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1; printf %s "$EXAKIT_VERSIONS_URL"')"
check "an explicit EXAKIT_KIT_REPO still outranks the manifest" "someone/else" "$(
    EXAKIT_HOME="$_SRC_HOME" EXAKIT_KIT_REPO="someone/else" bash -c '. "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1; printf %s "$EXAKIT_KIT_REPO"')"
check "an explicit versions URL is never recomputed" "https://example.invalid/v.json" "$(
    EXAKIT_HOME="$_SRC_HOME" EXAKIT_VERSIONS_URL="https://example.invalid/v.json" bash -c '. "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1; printf %s "$EXAKIT_VERSIONS_URL"')"
check "no manifest keeps the published default" "exasol-labs/exasol-personal-local-starterkit" "$(
    EXAKIT_HOME="$WORK/kit-source-none" bash -c '. "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1; printf %s "$EXAKIT_KIT_REPO"')"
# kit.source is interpolated into download URLs, so a value that is not
# owner/name is refused whole, never repaired into something plausible.
printf '{"kit":{"source":"evil.example/x;id@main"}}\n' > "$_SRC_HOME/manifest.json"
check "a hostile kit.source is refused, not repaired" "exasol-labs/exasol-personal-local-starterkit" "$(
    EXAKIT_HOME="$_SRC_HOME" bash -c '. "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1; printf %s "$EXAKIT_KIT_REPO"')"
if command -v pwsh >/dev/null 2>&1; then
    printf '{"kit":{"source":"owner-a/fork-b@main"}}\n' > "$_SRC_HOME/manifest.json"
    check "powershell: the manifest's kit.source decides the repo" "owner-a/fork-b" "$(
        EXAKIT_HOME="$_SRC_HOME" pwsh -NoProfile -Command '. "'"$ROOT"'/setup/lib/exakit-common.ps1" 2>$null; $script:KitRepo' 2>/dev/null | tail -1)"
    printf '{"kit":{"source":"evil.example/x;id@main"}}\n' > "$_SRC_HOME/manifest.json"
    check "powershell: a hostile kit.source is refused" "exasol-labs/exasol-personal-local-starterkit" "$(
        EXAKIT_HOME="$_SRC_HOME" pwsh -NoProfile -Command '. "'"$ROOT"'/setup/lib/exakit-common.ps1" 2>$null; $script:KitRepo' 2>/dev/null | tail -1)"
fi

echo
echo "the manifest and the fallback constants say the same version:"
# THE LAST TIER OF RESOLUTION MUST NOT DISAGREE WITH THE FIRST. A *_FALLBACK
# constant is what a machine with no network, no cache and no kit copy
# installs; versions.json is what everyone else installs. When they drift, an
# offline install is silently a DIFFERENT install - and a hand-edit of one
# without the other is exactly how that happens (it did: the runtime defaults
# moved to Exasol Personal while components.personal.version still named a
# launcher with no Linux or Windows deployment).
#
# The contract already exists as the COUPLED table in
# .github/workflows/versions-bump.yml, which the bump automation writes
# through. Nothing VALIDATED it, so this reads that same table - the single
# declared source of truth - and checks every constant it names. A table this
# cannot parse is a failure, not a skip.
# The reader is a FILE, not a heredoc inside $(...): bash 3.2 mis-parses a
# heredoc in a command substitution when the body carries the shell's own
# metacharacters, and this one is full of regexes. Written out, then run.
_vc_py="$(mktemp "${TMPDIR:-/tmp}/exakit-coupled.XXXXXX")"
cat > "$_vc_py" <<'EXAKIT_COUPLED_PY'
SIGIL = chr(36)   # the PowerShell variable sigil, spelled so no shell reading
                  # this file mistakes it for one of its own
import ast, json, os, re, sys

root = sys.argv[1]
workflow = os.path.join(root, ".github", "workflows", "versions-bump.yml")
try:
    text = open(workflow, encoding="utf-8").read()
except OSError as err:
    print("unreadable %s: %s" % (workflow, err)); raise SystemExit(0)

start = text.find("COUPLED = {")
if start < 0:
    print("no COUPLED table in versions-bump.yml"); raise SystemExit(0)
brace = text.index("{", start)
depth, end = 0, None
for i in range(brace, len(text)):
    if text[i] == "{":
        depth += 1
    elif text[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    print("COUPLED table is unterminated"); raise SystemExit(0)
# The block is indented inside the YAML run: strip the common indent so it
# parses as the literal it is.
literal = "\n".join(line.strip() for line in text[brace:end].splitlines())
try:
    coupled = ast.literal_eval(literal)
except Exception as err:
    print("COUPLED table does not parse: %s" % err); raise SystemExit(0)

doc = json.load(open(os.path.join(root, "versions.json"), encoding="utf-8"))
components = doc.get("components") or {}
# The declared default, in each language's shape. The PowerShell constants
# come in two: a plain assignment, and the env-override form
#   $script:X = if ($env:Y) { $env:Y } else { "value" }
# so the pwsh reader takes the LAST quoted string on the assignment line -
# the literal default in both shapes.
patterns = {
    # NAME="${NAME:-value}"
    "bash": lambda name: re.compile(r'%s="\$\{%s:-([^}]*)\}"' % (re.escape(name), re.escape(name))),
    # NAME = "value"
    "python": lambda name: re.compile(r'^%s\s*=\s*"([^"]*)"' % re.escape(name), re.M),
}

def read_pwsh(body, name):
    marker = "script:" + name
    for raw in body.splitlines():
        line = raw.strip()
        if not line.startswith(SIGIL + marker):
            continue
        rest = line[len(SIGIL + marker):].lstrip()
        if not rest.startswith("="):
            continue
        quoted = re.findall(r'"([^"]*)"', rest)
        return quoted[-1] if quoted else None
    return None
problems = []
checked = 0
for component, entries in sorted(coupled.items()):
    block = components.get(component)
    if block is None:
        problems.append("%s: named in COUPLED but absent from versions.json" % component)
        continue
    want = block.get("version")
    for path, kind, name in entries:
        full = os.path.join(root, path)
        try:
            body = open(full, encoding="utf-8").read()
        except OSError:
            problems.append("%s: %s is unreadable" % (component, path))
            continue
        if kind == "pwsh":
            found = read_pwsh(body, name)
        else:
            match = patterns[kind](name).search(body)
            found = match.group(1) if match else None
        if found is None:
            problems.append("%s: %s not found in %s" % (component, name, path))
            continue
        checked += 1
        if found != want:
            problems.append("%s: versions.json says %s, %s says %s (%s)"
                            % (component, want, name, found, path))
print("checked=%d" % checked)
for problem in problems:
    print("  " + problem)
EXAKIT_COUPLED_PY
_vc_out="$(python3 "$_vc_py" "$ROOT")"
rm -f "$_vc_py"
_vc_bad="$(printf '%s' "$_vc_out" | grep -v '^checked=' | grep -c '[^[:space:]]' || true)"
check "every coupled fallback constant matches versions.json" "0" "$_vc_bad"
[ "$_vc_bad" = "0" ] || printf '%s\n' "$_vc_out"
# The table has to actually cover something, or a parse that silently returned
# an empty dict would pass this suite while checking nothing.
_vc_n="$(printf '%s' "$_vc_out" | sed -n 's/^checked=//p')"
check "the coupled table covers the constants it declares" "yes" \
    "$([ "${_vc_n:-0}" -ge 8 ] && echo yes || echo "only ${_vc_n:-0}")"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
