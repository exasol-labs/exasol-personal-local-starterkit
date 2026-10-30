#!/usr/bin/env bash
# uv-bootstrap.sh — proves how the kit obtains uv, the Python tool runner.
#
# uvx is the process every AI client launches to run the MCP server, and it is
# handed the database password on every start. Two findings against 0.2.2:
# any uv already on the machine was used without its version being read (uv
# below 0.13.4 trusts a compromised root CA, GHSA-hq85-5cpj-mr62), and when uv
# was missing astral's install.sh was fetched and piped into sh, unpinned and
# unverified. This suite pins the fix on both sides:
#
#   1. no installer script is fetched or executed anywhere in setup/;
#   2. versions.json pins uv: a version, a floor at or below it, one digest
#      per supported platform, and the fallback table agrees;
#   3. a uv at or above the floor is used where it is; one below it is refused
#      and never run as the kit's uv;
#   4. a read-only query installs nothing, even with no usable uv;
#   5. the install downloads the pinned archive, verifies it against the
#      pinned digest, unpacks uv and uvx into the kit's bin dir - and a digest
#      that does not match refuses, leaving nothing behind;
#   6. the PowerShell twin carries the same functions and the same pin.
#
# No network: curl is a stub that serves a locally built archive. The real
# digests are verified by versions.yml (uv-digest-verify) from the real files.
#
#   bash tests/uv-bootstrap.sh

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
    case "$3" in
        *"$2"*) check "$1" "present" "present" ;;
        *)      check "$1" "present" "MISSING" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) check "$1" "absent" "PRESENT" ;;
        *)      check "$1" "absent" "absent" ;;
    esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The kit home and bin dir are redirected for the whole run: nothing here may
# touch a real installation or the developer's own uv.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/kitbin"
EXAKIT_MANIFEST="$WORK/home/manifest.json"
mkdir -p "$EXAKIT_HOME" "$WORK/path"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"

shipped() { # shipped <dotted.path> — straight out of versions.json
    python3 - "$ROOT/versions.json" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    node = node[part]
print(node)
PY
}
V_UV="$(shipped components.uv.version)"
V_MIN="$(shipped components.uv.min_version)"

# -----------------------------------------------------------------------------
echo "1. no installer script is executed anywhere:"
# The URL may appear in a comment that explains its absence; it may never be
# the operand of curl, wget, sh, Invoke-RestMethod or Invoke-Expression.
_script_hits="$(grep -rn 'astral.sh/uv/install' "$ROOT/setup" "$ROOT/install.sh" "$ROOT/install.ps1" 2>/dev/null \
    | grep -v ':[[:space:]]*#' | grep -v ':[[:space:]]*<#' | grep -v ':[[:space:]]*\*' || true)"
check "astral's install script is named in no command under setup/" "" "$_script_hits"
# The kit's OWN installer is advertised as `curl ... | sh` / `irm ... | iex`
# in remedies and comments, and that is not what this guards: the guard is
# that no file EXECUTES a downloaded script to obtain uv.
_iex_hits="$(grep -rn 'Invoke-Expression[[:space:]]*(Invoke-RestMethod\|iex[[:space:]]*(irm' "$ROOT/setup" 2>/dev/null | grep -v ':[[:space:]]*#' || true)"
check "no PowerShell file executes a downloaded script" "" "$_iex_hits"
_pipe_hits="$(grep -rnE '(curl|wget)[^|]*\|[[:space:]]*(run_logged )?sh\b' "$ROOT/setup" 2>/dev/null | grep -v ':[[:space:]]*#' | grep -E '\buv\b|astral' || true)"
check "no shell file pipes a uv download into sh" "" "$_pipe_hits"

# -----------------------------------------------------------------------------
echo "2. versions.json pins uv:"
check "components.uv.version is a plain release" "yes" \
    "$(printf '%s' "$V_UV" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && echo yes || echo no)"
check "components.uv.min_version is a plain release" "yes" \
    "$(printf '%s' "$V_MIN" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && echo yes || echo no)"
check "the floor is at or below the pinned version" "yes" \
    "$( [ "$V_MIN" = "$V_UV" ] && echo yes || { exakit_version_newer "$V_UV" "$V_MIN" && echo yes || echo no; } )"
check "the floor is at least 0.13.4 (GHSA-hq85-5cpj-mr62)" "yes" \
    "$( [ "$V_MIN" = "0.13.4" ] && echo yes || { exakit_version_newer "$V_MIN" "0.13.4" && echo yes || echo no; } )"
check "components.uv.repo is astral's" "astral-sh/uv" "$(shipped components.uv.repo)"
_platforms="$(python3 -c 'import json; print(" ".join(sorted(json.load(open("'"$ROOT"'/versions.json"))["components"]["uv"]["sha256"])))')"
check "one digest per supported platform" "linux-aarch64 linux-x86_64 macos-aarch64 macos-x86_64 windows-x86_64" "$_platforms"
for _p in $_platforms; do
    _d="$(shipped "components.uv.sha256.$_p")"
    check "digest for $_p is 64 hex" "yes" "$(printf '%s' "$_d" | grep -qE '^[0-9a-f]{64}$' && echo yes || echo no)"
done
# The fallback constants and table are what an offline machine installs from;
# they must name the same release and the same bytes as the manifest.
check "EXAKIT_UV_VERSION_FALLBACK matches the manifest" "$V_UV" "$EXAKIT_UV_VERSION_FALLBACK"
check "EXAKIT_UV_MIN_VERSION_FALLBACK matches the manifest" "$V_MIN" "$EXAKIT_UV_MIN_VERSION_FALLBACK"
for _p in $_platforms; do
    check "pinned table agrees with the manifest for $_p" "$(shipped "components.uv.sha256.$_p")" \
        "$(exakit_uv_pinned_sha256 "uv-${V_UV}-${_p}")"
done
check "the PowerShell fallback matches the manifest" "$V_UV" \
    "$(sed -n 's/^\$script:UvVersionFallback = .* else { "\([^"]*\)" }$/\1/p' "$ROOT/setup/lib/exakit-common.ps1")"
check "the PowerShell floor matches the manifest" "$V_MIN" \
    "$(sed -n 's/^\$script:UvMinVersionFallback = .* else { "\([^"]*\)" }$/\1/p' "$ROOT/setup/lib/exakit-common.ps1")"
check "the PowerShell pinned table carries the windows digest" "$(shipped components.uv.sha256.windows-x86_64)" \
    "$(sed -n 's/.*"uv-'"$V_UV"'-windows-x86_64" { return "\([0-9a-f]*\)" }.*/\1/p' "$ROOT/setup/lib/exakit-common.ps1")"
check "the manifest keys resolve to astral targets" "aarch64-apple-darwin x86_64-apple-darwin aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu x86_64-pc-windows-msvc" \
    "$(exakit_uv_target macos-aarch64) $(exakit_uv_target macos-x86_64) $(exakit_uv_target linux-aarch64) $(exakit_uv_target linux-x86_64) $(exakit_uv_target windows-x86_64)"

# -----------------------------------------------------------------------------
echo "3. the floor:"
stub_uv() { # stub_uv <dir> <version> — a uv that answers --version
    mkdir -p "$1"
    printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "uv %s (stub)"; exit 0; }\nexit 0\n' "$2" > "$1/uv"
    printf '#!/bin/sh\necho "uvx %s (stub)"\n' "$2" > "$1/uvx"
    chmod +x "$1/uv" "$1/uvx"
}
check "min version is read from the manifest" "$V_MIN" "$(exakit_uv_min_version)"
check "pinned version is read from the manifest" "$V_UV" "$(exakit_uv_pinned_version)"
check "EXAKIT_UV_VERSION overrides the pin" "9.9.9" "$(EXAKIT_UV_VERSION=v9.9.9 exakit_uv_pinned_version)"

stub_uv "$WORK/path" "0.12.0"
below="$( PATH="$WORK/path:$PATH"; _EXAKIT_UV_VETTED=""; EXAKIT_UV_BIN=""
    exakit_uv_report )"
check "a uv below the floor is reported, not used" "below|$WORK/path/uv|0.12.0|$V_MIN" "$below"
check "component_current still names it (so the table offers the update)" "0.12.0" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; exakit_component_current uv )"
check "and the advertised version is the pin" "$V_UV" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; exakit_component_available uv )"

stub_uv "$WORK/path" "$V_MIN"
check "a uv exactly at the floor is accepted" "ok|$WORK/path/uv|$V_MIN|$V_MIN" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; exakit_uv_report )"
stub_uv "$WORK/path" "0.99.0"
check "a newer uv is accepted" "ok|$WORK/path/uv|0.99.0|$V_MIN" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; exakit_uv_report )"
# A uv the user installed, at or above the floor, is the version the kit wants:
# the row reads current and `exakit update` leaves it alone.
check "a user's uv above the floor is advertised as itself" "0.99.0" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; exakit_component_available uv )"
check "so the update loop has nothing to do for it" "no" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; exakit_component_is_ahead uv && echo yes || echo no )"
check "ensure_uv settles on it" "$WORK/path/uv" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; _EXAKIT_UV_VETTED=""; exakit_ensure_uv && printf '%s' "$EXAKIT_UV_BIN" )"
check "and uvx is the one beside it" "$WORK/path/uvx" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; _EXAKIT_UV_VETTED=""; exakit_uv_uvx )"
# The kit's own copy wins over PATH: a copy installed to shadow an old uv
# elsewhere must be the one found.
stub_uv "$EXAKIT_BIN_DIR" "$V_UV"
check "the kit's own copy is preferred over PATH" "ok|$EXAKIT_BIN_DIR/uv|$V_UV|$V_MIN" \
    "$( PATH="$WORK/path:$PATH"; EXAKIT_UV_BIN=""; exakit_uv_report )"
rm -rf "$EXAKIT_BIN_DIR"
check "no uv at all is reported as none" "none|||$V_MIN" \
    "$( PATH="/usr/bin:/bin"; EXAKIT_UV_BIN=""; exakit_uv_report )"
check "and component_current says not installed" "1" \
    "$( PATH="/usr/bin:/bin"; EXAKIT_UV_BIN=""; exakit_component_current uv >/dev/null 2>&1; echo $? )"

# -----------------------------------------------------------------------------
echo "4. a read-only query installs nothing:"
stub_uv "$WORK/path" "0.12.0"
mkdir -p "$WORK/nocurl"
printf '#!/bin/sh\necho "curl must not run in a read-only query" >&2\nexit 99\n' > "$WORK/nocurl/curl"
chmod +x "$WORK/nocurl/curl"
ro="$( PATH="$WORK/nocurl:$WORK/path:/usr/bin:/bin"; EXAKIT_UV_BIN=""; _EXAKIT_UV_VETTED=""; _EXAKIT_UV_NONE=""
    EXAKIT_READONLY_QUERY=1 exakit_ensure_uv >/dev/null 2>&1; printf 'rc=%s ' "$?"
    [ -e "$EXAKIT_BIN_DIR/uv" ] && printf 'INSTALLED' || printf 'nothing-installed' )"
check "ensure_uv refuses and downloads nothing" "rc=1 nothing-installed" "$ro"

# -----------------------------------------------------------------------------
echo "5. the install (stubbed download):"
# Build the archive astral publishes: uv-<target>/{uv,uvx}, as a tar.gz. The
# stub uv inside answers the pinned version, which the install insists on.
_target="$(exakit_uv_target "$(exakit_uv_platform)")"
mkdir -p "$WORK/archive/uv-$_target"
stub_uv "$WORK/archive/uv-$_target" "$V_UV"
( cd "$WORK/archive" && tar -czf "$WORK/uv-$_target.tar.gz" "uv-$_target" )
_digest="$(sha256_of "$WORK/uv-$_target.tar.gz")"
# curl serves the local archive for the pinned URL and 404s everything else.
mkdir -p "$WORK/servecurl"
cat > "$WORK/servecurl/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        https://*) url="\$1"; shift ;;
        --help|-V|--version) echo "curl 8.0.0 stub"; exit 0 ;;
        *) shift ;;
    esac
done
case "\$url" in
    https://github.com/astral-sh/uv/releases/download/$V_UV/uv-$_target.tar.gz) cp "$WORK/uv-$_target.tar.gz" "\$out" ;;
    *) echo "stub curl: no such asset \$url" >&2; exit 22 ;;
esac
EOF
chmod +x "$WORK/servecurl/curl"
# The manifest digest is the REAL archive's; the stubbed archive carries the
# test's own, so the chain is pointed at it for this install only. The digest
# that versions.json advertises is proven against the real file by CI.
installed="$( PATH="$WORK/servecurl:$WORK/path:/usr/bin:/bin"; EXAKIT_UV_BIN=""; _EXAKIT_UV_VETTED=""; _EXAKIT_UV_NONE=""
    exakit_uv_expected_sha256() { printf '%s\n' "$_digest"; }
    exakit_ensure_uv >"$WORK/install-out.txt" 2>&1; printf 'rc=%s ' "$?"
    printf 'bin=%s ' "$EXAKIT_UV_BIN"
    [ -x "$EXAKIT_BIN_DIR/uv" ] && printf 'uv ' || printf 'NO-UV '
    [ -x "$EXAKIT_BIN_DIR/uvx" ] && printf 'uvx ' || printf 'NO-UVX '
    printf '%s' "$("$EXAKIT_BIN_DIR/uv" --version 2>/dev/null | awk '{print $2}')" )"
check "an old uv on PATH leads to the kit's own verified copy" \
    "rc=0 bin=$EXAKIT_BIN_DIR/uv uv uvx $V_UV" "$installed"
has "the user's uv is named as below the floor and left alone" "0.12.0 at $WORK/path/uv is below the minimum $V_MIN" "$(cat "$WORK/install-out.txt")"
has "the checksum is verified before anything is unpacked" "Checksum verified: uv-$_target.tar.gz" "$(cat "$WORK/install-out.txt")"
has "the install is announced with its version" "uv $V_UV installed to" "$(cat "$WORK/install-out.txt")"
check "the user's uv was not modified" "0.12.0" "$("$WORK/path/uv" --version | awk '{print $2}')"
lacks "no installer script ran" "install.sh" "$(cat "$WORK/install-out.txt")"
check "the install is recorded nowhere without a manifest" "absent" \
    "$( [ -f "$EXAKIT_MANIFEST" ] && echo PRESENT || echo absent )"

rm -rf "$EXAKIT_BIN_DIR"
tampered="$( PATH="$WORK/servecurl:$WORK/path:/usr/bin:/bin"; EXAKIT_UV_BIN=""; _EXAKIT_UV_VETTED=""; _EXAKIT_UV_NONE=""
    exakit_uv_expected_sha256() { printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000"; }
    exakit_ensure_uv >"$WORK/tamper-out.txt" 2>&1; printf 'rc=%s ' "$?"
    [ -e "$EXAKIT_BIN_DIR/uv" ] && printf 'INSTALLED' || printf 'nothing-installed' )"
check "a digest that does not match refuses the install" "rc=1 nothing-installed" "$tampered"
has "and says so" "Checksum mismatch for uv-$_target.tar.gz" "$(cat "$WORK/tamper-out.txt")"

rm -rf "$EXAKIT_BIN_DIR"
nodigest="$( PATH="$WORK/servecurl:$WORK/path:/usr/bin:/bin"; EXAKIT_UV_BIN=""; _EXAKIT_UV_VETTED=""; _EXAKIT_UV_NONE=""
    exakit_uv_expected_sha256() { return 1; }
    exakit_ensure_uv >"$WORK/nodigest-out.txt" 2>&1; printf 'rc=%s ' "$?"
    [ -e "$EXAKIT_BIN_DIR/uv" ] && printf 'INSTALLED' || printf 'nothing-installed' )"
check "no pinned digest refuses the install (no override exists)" "rc=1 nothing-installed" "$nodigest"
has "and names the pin to fix" "No checksum is pinned for uv" "$(cat "$WORK/nodigest-out.txt")"
lacks "no EXAKIT_ALLOW_UNVERIFIED escape hatch is offered" "ALLOW_UNVERIFIED" "$(cat "$WORK/nodigest-out.txt")"

# A version the manifest does not advertise must not borrow its digest.
check "an overridden version does not borrow the advertised digest" "" \
    "$( EXAKIT_UV_VERSION=0.0.0-not-advertised; curl() { return 22; }; exakit_uv_expected_sha256 0.0.0-not-advertised macos-aarch64 https://invalid.invalid/x 2>/dev/null )"

# -----------------------------------------------------------------------------
echo "6. the registry and the twins:"
_all_targets="$(exakit_update_targets all)"
check "uv is an update target" "yes" "$(printf '%s\n' "$_all_targets" | grep -cx uv | sed 's/^1$/yes/; s/^0$/no/')"
check "and an explicit one" "uv" "$(exakit_update_targets uv)"
check "its manifest block is components.uv" "components.uv" "$(_exakit_component_block uv)"
check "its env override is EXAKIT_UV_VERSION" "7.7.7" "$(EXAKIT_UV_VERSION=7.7.7 _exakit_component_env_override uv)"
check "its fallback is the constant" "$EXAKIT_UV_VERSION_FALLBACK" "$(_exakit_component_fallback uv)"
check "the update dispatcher routes uv" "yes" "$(grep -q 'uv) exakit_uv_update ;;' "$ROOT/setup/lib/common.sh" && echo yes || echo no)"
check "every add-on resolves uv through the one checker" "" \
    "$(grep -n 'command -v uv >/dev/null 2>&1; then' "$ROOT/setup/lib/pyexasol.sh" "$ROOT/setup/lib/dash-server.sh" "$ROOT/setup/lib/json-tables.sh" "$ROOT/setup/lib/dbt-exasol.sh" || true)"
check "the MCP server is primed through the vetted uvx, never a bare one" "" \
    "$(grep -nE '^[[:space:]]*uvx |\(uvx |"\$\(uvx' "$ROOT/setup/lib/mcp.sh" | grep -v '^[0-9]*:[[:space:]]*#' || true)"
for _fn in Get-ExakitUvReport Get-ExakitUvBin Install-ExakitUv Install-ExakitUvPinned Get-ExakitUvExpectedSha256 \
           Get-ExakitUvPinnedSha256 Get-ExakitUvUvx Update-ExakitUv Set-ExakitUvManifest Get-ExakitUvMinVersion; do
    check "powershell twin $_fn exists" "yes" "$(grep -q "^function $_fn" "$ROOT/setup/lib/exakit-common.ps1" && echo yes || echo no)"
done
check "powershell update dispatcher routes uv" "yes" "$(grep -q '"uv" {' "$ROOT/setup/exakit.ps1" && echo yes || echo no)"
check "powershell update targets carry uv" "yes" "$(grep -q '"exakit", "runtime", "exapump", "uv", "mcp", "pyexasol"' "$ROOT/setup/lib/exakit-common.ps1" && echo yes || echo no)"
check "the MCP client command prefers the vetted uvx (bash)" "yes" "$(grep -q 'exakit_uv_uvx' "$ROOT/setup/lib/mcp.sh" && echo yes || echo no)"
check "the MCP client command prefers the vetted uvx (powershell)" "yes" "$(grep -q 'Get-ExakitUvUvx' "$ROOT/setup/lib/mcp.ps1" && echo yes || echo no)"
check "CI validates the uv block" "yes" "$(grep -q 'components.uv' "$ROOT/.github/workflows/versions.yml" && echo yes || echo no)"
check "CI hashes the uv archives" "yes" "$(grep -q 'uv-digest-verify\|verify uv digests' "$ROOT/.github/workflows/versions.yml" && echo yes || echo no)"
check "the bump workflow proposes uv" "yes" "$(grep -q 'EXAKIT_UV_VERSION_FALLBACK' "$ROOT/.github/workflows/versions-bump.yml" && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
