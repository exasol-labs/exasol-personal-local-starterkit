#!/usr/bin/env bash
# exapump-shim-wrapper.sh - the wrapper the kit writes on Linux with glibc < 2.38, which runs the real exapump in a
# container, rendered with a stand-in runtime that prints the argv it was given.
#
#   bash tests/exapump-shim-wrapper.sh
#
# What it pins (audit LNX-01, LNX-15):
#   - EXAPUMP_CONFIG reaches the container: the kit's profile lives in its own store, not ~/.exapump
#   - its folder is mounted when it is outside $HOME, and only then; a path with a space stays one argument
#   - without EXAPUMP_CONFIG nothing extra is passed
#   - the image is fully qualified (Podman refuses a short name without a TTY)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"     # physical: macOS /var is /private/var, and the wrapper compares $PWD
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1"; fi; }

# The wrapper's body, exactly as exapump_install_glibc_shim writes it, with its placeholders filled.
sed -n "/<<'EXAKIT_SHIM_EOF'/,/^EXAKIT_SHIM_EOF\$/p" "$ROOT/setup/lib/exapump.sh" | sed '1d;$d' > "$WORK/template"
[ -s "$WORK/template" ]; check "the wrapper template is found in exapump.sh" $?
cat > "$WORK/runtime" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
STUB
chmod +x "$WORK/runtime"
sed -e "s|@RUNTIME@|$WORK/runtime|" -e "s|@USERNS@||" -e "s|@IMAGE@|IMAGE|" -e "s|@REAL@|/opt/real/exapump|" \
    "$WORK/template" > "$WORK/exapump"
chmod +x "$WORK/exapump"

home="$WORK/home"; mkdir -p "$home/.exasol-starter-kit/exapump" "$WORK/elsewhere kit/exapump"
has_pair() { awk -v a="$1" -v b="$2" 'prev == a && $0 == b { found = 1 } { prev = $0 } END { exit !found }'; }
for shell in sh dash; do                # Debian and Ubuntu run #!/bin/sh as dash
    command -v "$shell" >/dev/null 2>&1 || { echo "  skip $shell (not installed)"; continue; }
    run() { (cd "$home" && env -i PATH=/usr/bin:/bin HOME="$home" "$@" "$shell" "$WORK/exapump" sql -p starter-kit); }

    out="$(run EXAPUMP_CONFIG="$home/.exasol-starter-kit/exapump/config.toml")"
    printf '%s\n' "$out" | has_pair -e "EXAPUMP_CONFIG=$home/.exasol-starter-kit/exapump/config.toml"
    check "EXAPUMP_CONFIG under \$HOME is passed into the container ($shell)" $?
    [ "$(printf '%s\n' "$out" | grep -c -- '^-v$')" = 2 ]
    check "...and needs no mount of its own (\$HOME and /tmp only) ($shell)" $?

    cfg="$WORK/elsewhere kit/exapump/config.toml"
    out="$(run EXAPUMP_CONFIG="$cfg")"
    printf '%s\n' "$out" | has_pair -e "EXAPUMP_CONFIG=$cfg"
    check "EXAPUMP_CONFIG outside \$HOME is passed, the space kept in one argument ($shell)" $?
    printf '%s\n' "$out" | has_pair -v "$WORK/elsewhere kit/exapump:$WORK/elsewhere kit/exapump"
    check "...and its folder is mounted ($shell)" $?

    out="$(run)"
    printf '%s\n' "$out" | grep -q EXAPUMP_CONFIG; [ $? != 0 ]
    check "without EXAPUMP_CONFIG nothing extra is passed ($shell)" $?
    printf '%s\n' "$out" | has_pair IMAGE /opt/real/exapump && [ "$(printf '%s\n' "$out" | tail -1)" = starter-kit ]
    check "the real binary still runs with the caller's arguments ($shell)" $?

done

grep -q 'EXAKIT_EXAPUMP_SHIM_IMAGE:-docker.io/library/ubuntu:24.04' "$ROOT/setup/lib/exapump.sh"
check "the shim image is fully qualified" $?

echo
echo "exapump-shim-wrapper.sh: $pass passed, $fail failed"
[ "$fail" = 0 ]
