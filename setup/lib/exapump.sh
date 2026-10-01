#!/usr/bin/env bash
# exapump.sh — exapump installation and connection module.
#
# Sourced by setup scripts after common.sh, detect.sh, and a runtime module.
# Installs the resolved exapump release binary (checksum-verified against the
# digests published by the release API), writes a dedicated connection
# profile, and validates the connection with SELECT 1.
#
# exapump facts:
#   - release assets: exapump-<ver>-{macos,linux}-{aarch64,x86_64}[, .exe]
#   - profiles: ~/.exapump/config.toml (TOML, one section per profile)
#   - SQL from a file: exapump sql -p <profile> < file.sql
#   - CSV/Parquet load: exapump upload <file> --table <schema.table>

EXAKIT_EXAPUMP_PROFILE="${EXAKIT_EXAPUMP_PROFILE:-starter-kit}"
# OVERRIDABLE, like every sibling variable here. It was assigned
# unconditionally, so an EXAKIT_EXAPUMP_BIN set in the environment was
# discarded the moment this file was sourced - and exapump_cli then fell
# through to the `exapump` on PATH. A test that sandboxes EXAKIT_HOME and
# EXAKIT_BIN_DIR but points EXAKIT_EXAPUMP_BIN at a stub therefore ran the
# DEVELOPER'S REAL exapump against the DEVELOPER'S REAL database, and created
# a schema in it. Same class of escape as the HOME/.exapump note below.
EXAKIT_EXAPUMP_BIN="${EXAKIT_EXAPUMP_BIN:-$EXAKIT_BIN_DIR/exapump}"
# ONE definition of where exapump keeps its profiles, and it is overridable.
# The uninstall path used to spell it `rm -rf "$HOME/.exapump"` inline: a test
# that sandboxes EXAKIT_HOME and EXAKIT_BIN_DIR (as every suite here does) but
# not HOME therefore deleted the DEVELOPER'S OWN profile, and the machine only
# said so later, as `Profile 'starter-kit' not found in config` from a command
# that had worked ten minutes earlier. Every reader and the remover now share
# this variable, so sandboxing it once is enough.
EXAKIT_EXAPUMP_CONFIG_DIR="${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}"
EXAPUMP_CONFIG="$EXAKIT_EXAPUMP_CONFIG_DIR/config.toml"

exapump_asset_name() {
    _ver="$EXAKIT_EXAPUMP_VERSION"
    case "$(detect_os)" in
        macos) _osname="macos" ;;
        *)     _osname="linux" ;;
    esac
    case "$(detect_arch)" in
        arm64)  _archname="aarch64" ;;
        x86_64) _archname="x86_64" ;;
    esac
    echo "exapump-${_ver}-${_osname}-${_archname}"
}

# exapump_expected_sha256 <asset> — the digest the download is verified against:
#
#   1. versions.json, but ONLY when the version being installed is the advertised
#      one. An env override must never borrow another release's digest — that
#      would either fail confusingly or, worse, match the wrong artifact.
#   2. the pinned digests of the fallback releases (below).
#   3. the release API for the version in question.
#
# Empty output means "no digest available"; the caller decides what to do with
# that (it refuses to install unless explicitly overridden).
# ⇄ twin: Get-ExapumpExpectedSha256 in exapump.ps1.
exapump_expected_sha256() {
    _ex_asset="$1"
    _ex_advertised="$(exakit_versions_value components.exapump.version 2>/dev/null || true)"
    if [ -n "$_ex_advertised" ] && [ "$_ex_advertised" = "$EXAKIT_EXAPUMP_VERSION" ]; then
        # The asset name is exapump-<version>-<os>-<arch>, and versions.json keys
        # its digests by that same <os>-<arch> token.
        _ex_platform="${_ex_asset#exapump-${EXAKIT_EXAPUMP_VERSION}-}"
        _ex_digest="$(exakit_versions_value "components.exapump.sha256.${_ex_platform}" 2>/dev/null || true)"
        case "$_ex_digest" in
            *[!0-9a-f]*) _ex_digest="" ;;
        esac
        if [ -n "$_ex_digest" ] && [ "${#_ex_digest}" -eq 64 ]; then
            printf '%s\n' "$_ex_digest"
            return 0
        fi
    fi
    _ex_digest="$(exapump_pinned_sha256 "$_ex_asset")"
    if [ -n "$_ex_digest" ]; then
        printf '%s\n' "$_ex_digest"
        return 0
    fi
    exapump_release_digest_from_api "$_ex_asset"
}

# Digests of the fallback releases (published by the release API), consulted by
# exapump_expected_sha256 after versions.json and before the release API. The
# current fallback MUST be listed here: it is what exapump_install verifies
# against when the release API cannot supply a digest for the requested version.
exapump_pinned_sha256() {
    case "$1" in
        exapump-0.13.0-linux-aarch64)  echo "f23a955caf131f26833471dcac0e40e524b825e75277cdda68dfb157acb806bf" ;;
        exapump-0.13.0-linux-x86_64)   echo "69a5a9bc63aa07ff7b95d00b8786ec1c67c3dff6e7f3fbac5f09b110c8d288db" ;;
        exapump-0.13.0-macos-aarch64)  echo "819a3c0c7e024069c8e1ee76c931cf6ea3701e7335c72d97431b2e06d7234c71" ;;
        exapump-0.13.0-macos-x86_64)   echo "38507010bb903573029991e56af3ad846830b328f90cd2f04d048ca684e29ec9" ;;
        exapump-0.11.2-linux-aarch64)  echo "106c3c5ea168a1381549807b82639137c8b3f94bd64c1b6d02fa380a025d5085" ;;
        exapump-0.11.2-linux-x86_64)   echo "669af4d488e5b1ae2e9c9e030c1be4b1cdb7442dedf3175a361928613f4b3e80" ;;
        exapump-0.11.2-macos-aarch64)  echo "e1438c69f26cdcca69ad1b7211aa9495524c53ff1badebee91d5a631c503616b" ;;
        exapump-0.11.2-macos-x86_64)   echo "1dd68d2dbc2d556e1613975eeffb25813f1ec60e06e93d514d5dd86df8144648" ;;
        *) echo "" ;;
    esac
}

exapump_release_digest_from_api() {
    # --proto/--proto-redir: this response decides WHICH DIGEST the download
    # below is verified against, so a redirect to http would weaken the
    # verification chain at its root - and -L follows redirects.
    _json="$(curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/${EXAKIT_EXAPUMP_REPO}/releases/tags/v${EXAKIT_EXAPUMP_VERSION}" \
        2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c '
import json, sys
name = sys.argv[1]
doc = json.load(sys.stdin)
for asset in doc.get("assets", []):
    if asset["name"] == name and asset.get("digest", "").startswith("sha256:"):
        print(asset["digest"].split(":", 1)[1])
        break
' "$1"
        return $?
    fi
    # Best-effort shell fallback for GitHub's asset object. If this misses, the
    # caller already warns and continues rather than pretending verification ran.
    printf '%s' "$_json" | tr '{' '\n' | awk -v name="$1" '
        index($0, "\"name\":\"" name "\"") || index($0, "\"name\": \"" name "\"") {
            if (match($0, /"digest"[[:space:]]*:[[:space:]]*"sha256:[^"]+"/)) {
                digest = substr($0, RSTART, RLENGTH)
                sub(/^.*sha256:/, "", digest)
                sub(/"$/, "", digest)
                print digest
                exit
            }
        }'
}

exapump_cli() {
    if [ -x "$EXAKIT_EXAPUMP_BIN" ]; then
        echo "$EXAKIT_EXAPUMP_BIN"
    elif command -v exapump >/dev/null 2>&1; then
        command -v exapump
    else
        echo "$EXAKIT_EXAPUMP_BIN"
    fi
}

exapump_install() {
    [ "$(detect_arch)" != "unsupported" ] || \
        die "Unsupported CPU architecture: $(uname -m). exapump binaries exist for x86_64 and arm64 only."

    if [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && { command -v exapump >/dev/null 2>&1 || [ -x "$EXAKIT_EXAPUMP_BIN" ]; }; then
        # Trust the existing binary only if it actually runs — an interrupted
        # earlier download can leave a broken file at the same path.
        if _exi_out="$("$(exapump_cli)" --version 2>/dev/null)"; then
            # THE VERSION IS CHECKED, NOT JUST THAT IT RUNS. A kit-managed
            # binary left by an earlier install answered --version, was called
            # "already installed", and the manifest then recorded the version
            # this kit PINS - 0.13.0 on paper, 0.12.0 on disk, and every
            # exapump fix in between missing. A binary elsewhere on PATH is
            # the user's and is left alone; only the kit's own is replaced.
            _exi_have="$(printf '%s' "$_exi_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
            if [ -n "$_exi_have" ] && [ "$_exi_have" != "$EXAKIT_EXAPUMP_VERSION" ] && \
               [ "$(exapump_cli)" = "$EXAKIT_EXAPUMP_BIN" ]; then
                info "exapump $_exi_have is installed; this kit ships $EXAKIT_EXAPUMP_VERSION - replacing it"
                rm -f "$EXAKIT_EXAPUMP_BIN"
            else
                ok "exapump already installed: $(exapump_cli)"
                exapump_record_manifest
                return 0
            fi
        else
        # A binary that fails on the dynamic linker is not a broken download —
        # it is intact but needs a newer glibc than this system has. Shim it
        # in place instead of re-downloading the same incompatible bytes.
        # (Only for the kit-managed path: a foreign exapump elsewhere on PATH
        # falls through to a fresh, kit-managed install below.)
        if [ -x "$EXAKIT_EXAPUMP_BIN" ]; then
            _existing_err="$("$EXAKIT_EXAPUMP_BIN" --version 2>&1 || true)"
            case "$_existing_err" in
                *GLIBC_*)
                    exapump_install_glibc_shim
                    exapump_record_manifest
                    return 0
                    ;;
            esac
        fi
        warn "Existing exapump binary does not run (interrupted download?) — reinstalling"
        rm -f "$EXAKIT_EXAPUMP_BIN"
        fi
    fi

    _asset="$(exapump_asset_name)"
    _url="https://github.com/${EXAKIT_EXAPUMP_REPO}/releases/download/v${EXAKIT_EXAPUMP_VERSION}/${_asset}"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"
    _exi_t0="$(date +%s 2>/dev/null || echo 0)"

    # Named per phase so the one animated line says what is happening now. The
    # checksum has no phase of its own: it is sub-second on a 20 MB binary, and
    # its own tick is gone -- it announced basename($_tmp), the mktemp path,
    # never the asset. The verification itself is untouched.
    EXAKIT_ACTIVE_LABEL="Downloading exapump v${EXAKIT_EXAPUMP_VERSION}"
    info "Downloading exapump v${EXAKIT_EXAPUMP_VERSION} ($_asset)"
    fetch "$_url" "$_tmp"

    _expected="$(exapump_expected_sha256 "$_asset" 2>/dev/null || true)"
    # No digest for the requested version (an un-pinned latest, and the release
    # API unreachable or rate-limited): install the fallback release instead,
    # verified against its pinned digest, rather than failing the install.
    # Ported from the production hotfix (exasol-labs PR #24).
    if [ -z "$_expected" ] && [ "${EXAKIT_ALLOW_UNVERIFIED_EXAPUMP:-0}" != "1" ] \
        && [ "$EXAKIT_EXAPUMP_VERSION" != "$EXAKIT_EXAPUMP_VERSION_FALLBACK" ]; then
        warn "No checksum available for $_asset — installing the fallback exapump v${EXAKIT_EXAPUMP_VERSION_FALLBACK} instead."
        EXAKIT_EXAPUMP_VERSION="$EXAKIT_EXAPUMP_VERSION_FALLBACK"
        export EXAKIT_EXAPUMP_VERSION
        _asset="$(exapump_asset_name)"
        _url="https://github.com/${EXAKIT_EXAPUMP_REPO}/releases/download/v${EXAKIT_EXAPUMP_VERSION}/${_asset}"
        # fetch resumes with curl -C -, so the first download has to go before
        # the fallback lands in the same temp file, or the two would be spliced.
        rm -f "$_tmp"
        EXAKIT_ACTIVE_LABEL="Downloading exapump v${EXAKIT_EXAPUMP_VERSION}"
        info "Downloading exapump v${EXAKIT_EXAPUMP_VERSION} ($_asset)"
        fetch "$_url" "$_tmp"
        _expected="$(exapump_expected_sha256 "$_asset" 2>/dev/null || true)"
    fi
    if [ -n "$_expected" ]; then
        verify_sha256 "$_tmp" "$_expected"
    elif [ "${EXAKIT_ALLOW_UNVERIFIED_EXAPUMP:-0}" = "1" ]; then
        warn "No digest available for $_asset — proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1)."
    else
        # Match the launcher's bar: never install a downloaded-and-executed
        # binary we could not verify. An unknown version with no reachable
        # release API was already swapped for the fallback above, so this only
        # fires when even the fallback release has no digest — a pinned table
        # that was not updated with the fallback — which should fail loudly
        # rather than run unverified code.
        rm -f "$_tmp"
        die "No checksum available for $_asset; refusing to install an unverified exapump binary. Add its digest to versions.json (components.exapump.sha256) or check network access to the release API. Override at your own risk with EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1."
    fi

    mkdir -p "$EXAKIT_BIN_DIR"
    install -m 755 "$_tmp" "$EXAKIT_EXAPUMP_BIN" \
        || die "Could not install exapump to $EXAKIT_EXAPUMP_BIN (is it writable? is the disk full?)."
    push_rollback "rm -f \"$EXAKIT_EXAPUMP_BIN\""
    rm -f "$_tmp"
    ensure_path_hint "$EXAKIT_BIN_DIR"
    # Smoke-test the freshly installed binary BEFORE reporting success. A
    # checksum only proves the download is intact, not that it can launch:
    # release binaries link against a glibc newer than several supported
    # distros ship (e.g. Ubuntu 22.04's 2.35 vs the required 2.38+), and an
    # un-launchable binary would otherwise surface 30s later as an opaque
    # "SELECT 1 failed" after the connection retries.
    exapump_verify_runs
    ok_step "exapump v${EXAKIT_EXAPUMP_VERSION} installed to $(ui_tilde "$EXAKIT_EXAPUMP_BIN") ($(( $(date +%s 2>/dev/null || echo 0) - _exi_t0 ))s)"
    exapump_record_manifest
}

# exapump_verify_runs — prove the installed binary launches. On the known
# failure (dynamic-linker GLIBC version mismatch) self-repair with the
# container shim; anything else is a hard, explained failure.
# exakit_binary_not_runnable_yet <output> — is this the error of a binary that
# cannot start YET, rather than one that cannot start at all?
#
# A freshly written, unsigned 20 MB executable is held open by Windows Defender
# and by corporate EDR agents while they scan it, and every attempt to run it
# meanwhile fails with "Access is denied". Measured on a managed Windows laptop:
# three and a half minutes, during which all six SELECT 1 attempts failed and
# the install reported a database fault - with the database perfectly healthy
# and the same binary running fine a minute later. On Linux and macOS this
# matches nothing, so nothing waits there.
exakit_binary_not_runnable_yet() {
    case "$1" in
        *"Access is denied"*|*"failed to run"*|*"being used by another process"*|*"Text file busy"*|*"cannot access the file"*|*"contains a virus"*)
            return 0 ;;
    esac
    return 1
}

exapump_verify_runs() {
    # A BINARY THAT CANNOT START YET IS NOT A BROKEN ONE: wait it out (see
    # exakit_binary_not_runnable_yet), but only for the error that says so, so a
    # genuinely broken binary still fails in the same second it always did.
    _evr_budget="${EXAKIT_EXAPUMP_READY_TIMEOUT:-180}"
    _evr_t0="$(date +%s 2>/dev/null || echo 0)"
    _evr_said=0
    while :; do
        _evr_err="$("$EXAKIT_EXAPUMP_BIN" --version 2>&1)"
        _evr_rc=$?
        [ "$_evr_rc" -eq 0 ] && return 0
        exakit_binary_not_runnable_yet "$_evr_err" || break
        [ $(( $(date +%s 2>/dev/null || echo 0) - _evr_t0 )) -lt "$_evr_budget" ] || break
        if [ "$_evr_said" = 0 ]; then
            info "The new exapump cannot start yet (a virus scanner still holds it) - waiting up to ${_evr_budget}s"
            _evr_said=1
        fi
        sleep 5
    done
    _exakit_log_file "ERR   exapump --version failed (rc=$_evr_rc): $_evr_err"
    if exakit_binary_not_runnable_yet "$_evr_err"; then
        die "exapump was installed and verified, but this machine will not let it run: ${_evr_err%%
*}. A virus scanner or endpoint-security agent is holding it. Allow $EXAKIT_EXAPUMP_BIN (or wait for the scan to finish), then: exakit update"
    fi
    # A binary the kernel refuses to execute produces no stderr to match on, so
    # the exit status is the only evidence there is.
    if exakit_unsigned_binary_hint "$EXAKIT_EXAPUMP_BIN" "$_evr_rc"; then
        die "exapump was downloaded and verified but cannot be executed on this machine."
    fi
    case "$_evr_err" in
        *GLIBC_*)
            exapump_install_glibc_shim
            ;;
        *)
            die "exapump was installed but does not run: ${_evr_err:-unknown error}. See ${EXAKIT_LOG_FILE:-the log} and https://github.com/${EXAKIT_EXAPUMP_REPO}/issues"
            ;;
    esac
}

# exapump_install_glibc_shim — the exapump release binary needs a newer glibc
# than this system provides (all published Linux builds currently require
# 2.38+, while e.g. Ubuntu 22.04 LTS and every other Jammy-era distro ship
# 2.35). The Linux install path already requires Podman for the database, so
# run the real binary inside a small newer-glibc container with host
# networking instead of failing the install. The wrapper is transparent
# to every caller: same path, same CLI, profiles and data files under $HOME
# and /tmp remain visible.
EXAKIT_EXAPUMP_SHIM_IMAGE="${EXAKIT_EXAPUMP_SHIM_IMAGE:-ubuntu:24.04}"
exapump_install_glibc_shim() {
    _shim_runtime="$(detect_podman)"
    # Rootless podman remaps ownership inside the container: without keep-id
    # the user's own files (profile at ~/.exapump, mode 600) appear root-owned
    # and unreadable to the -u uid.
    _shim_userns="--userns=keep-id"
    _sys_glibc="$(ldd --version 2>/dev/null | head -1)"
    warn "The exapump release binary needs a newer glibc than this system provides (${_sys_glibc:-unknown glibc})."
    if [ "$_shim_runtime" = "none" ]; then
        die "exapump cannot run on this system's glibc and Podman is not available to shim it. Install Podman and re-run, or use a distro with glibc 2.38+ (e.g. Ubuntu 24.04)."
    fi
    info "Self-repair: running exapump inside a $EXAKIT_EXAPUMP_SHIM_IMAGE container via $_shim_runtime"

    _shim_real_dir="$EXAKIT_HOME/libexec"
    _shim_real="$_shim_real_dir/exapump-real"
    mkdir -p "$_shim_real_dir" || die "Could not create $_shim_real_dir (is the disk full?)."
    mv "$EXAKIT_EXAPUMP_BIN" "$_shim_real" \
        || die "Could not move the exapump binary to $_shim_real."
    chmod 755 "$_shim_real"

    run_logged "$_shim_runtime" pull "$EXAKIT_EXAPUMP_SHIM_IMAGE" \
        || die "Could not pull $EXAKIT_EXAPUMP_SHIM_IMAGE with $_shim_runtime. What it printed: exakit logs setup. Check network access and re-run."

    # $HOME/$PWD/id expand at RUN time (quoted heredoc); the runtime, image,
    # and real-binary path are baked in below with a safe substitution.
    cat > "$EXAKIT_EXAPUMP_BIN" <<'EXAKIT_SHIM_EOF'
#!/bin/sh
# exapump glibc shim — generated by the Exasol Personal Local Starter Kit.
# The exapump release binary requires a newer glibc than this system has, so
# it runs inside a container with host networking. The real binary lives at
# the path baked in below; re-running the installer regenerates this wrapper.
# Files are visible to exapump under $HOME, /tmp, and the directory you run it
# from. THE LAST ONE MATTERS: this wrapper used to mount only the first two and
# silently relocate the working directory to $HOME when you were anywhere else,
# so `exapump upload sales.csv` from /srv/data resolved against $HOME/sales.csv
# - reporting the wrong directory when nothing was there, and loading a
# DIFFERENT FILE and calling it a success when something was. That is the
# population this shim exists for: it is only generated on glibc < 2.38
# (RHEL/Rocky/Alma 8-9, Debian 11-12, Amazon Linux 2023), which is servers,
# where data lives under /srv, /data or an NFS mount far more often than under
# $HOME. Mounting the current directory costs nothing and removes both shapes.
if [ -t 0 ] && [ -t 1 ]; then _exakit_tty="-it"; else _exakit_tty="-i"; fi
_exakit_v=""; _exakit_vp=""
case "$PWD" in
    "$HOME"*|/tmp*)
        # Already inside a mount; mounting it again would nest.
        _exakit_wd="$PWD" ;;
    *)
        if [ -d "$PWD" ]; then
            _exakit_wd="$PWD"; _exakit_v="-v"; _exakit_vp="$PWD:$PWD"
        else
            # No current directory to mount (deleted under us). Say so rather
            # than quietly resolving relative paths somewhere else.
            echo "exapump: the current directory does not exist; relative paths will resolve against $HOME" >&2
            _exakit_wd="$HOME"
        fi ;;
esac
exec @RUNTIME@ run --rm $_exakit_tty --network host @USERNS@ \
    -u "$(id -u):$(id -g)" \
    -e HOME="$HOME" \
    -v "$HOME:$HOME" -v /tmp:/tmp \
    ${_exakit_v:+"$_exakit_v"} ${_exakit_vp:+"$_exakit_vp"} \
    -w "$_exakit_wd" \
    @IMAGE@ \
    "@REAL@" "$@"
EXAKIT_SHIM_EOF
    # sed with | as the delimiter: the substituted values are paths/images
    # that can contain / but never |.
    sed -i.exakit-bak \
        -e "s|@RUNTIME@|$_shim_runtime|" \
        -e "s|@USERNS@|$_shim_userns|" \
        -e "s|@IMAGE@|$EXAKIT_EXAPUMP_SHIM_IMAGE|" \
        -e "s|@REAL@|$_shim_real|" \
        "$EXAKIT_EXAPUMP_BIN" && rm -f "$EXAKIT_EXAPUMP_BIN.exakit-bak"
    chmod 755 "$EXAKIT_EXAPUMP_BIN"

    _shim_check="$("$EXAKIT_EXAPUMP_BIN" --version 2>&1)" \
        || die "The exapump container shim did not run: ${_shim_check:-unknown error}. See ${EXAKIT_LOG_FILE:-the log}."
    manifest_set components.exapump.glibc_shim true
    manifest_set components.exapump.shim_image "$EXAKIT_EXAPUMP_SHIM_IMAGE"
    ok "exapump runs via the $_shim_runtime shim ($_shim_check)"
}

# exapump_create_profile — write the kit's connection profile from the
# manifest. Managed section, safe to re-run; other profiles are untouched.
exapump_create_profile() {
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    [ -n "$_dsn" ] || die "No runtime DSN in the manifest — install the database first."
    _host="${_dsn%%:*}"
    _port="${_dsn##*:}"
    _user="$(manifest_get runtime.user 2>/dev/null)"
    _user="${_user:-sys}"

    _pwfile="$(manifest_get runtime.password_file 2>/dev/null)"
    _password=""
    if [ -n "$_pwfile" ] && [ -f "$_pwfile" ]; then
        _password="$(cat "$_pwfile")"
    fi
    if [ -z "$_password" ] && (: < /dev/tty) 2>/dev/null; then
        printf '    %s?%s Database password for user %s (input hidden): ' "${UI_ASK:-}" "${UI_RESET:-}" "$_user"
        stty -echo < /dev/tty 2>/dev/null
        read -r _password < /dev/tty
        stty echo < /dev/tty 2>/dev/null
        printf '\n'
    fi
    if [ -z "$_password" ]; then
        warn "No database password available — create the profile manually with: exapump profile init $EXAKIT_EXAPUMP_PROFILE"
        return 0
    fi

    # If the runtime password wasn't already on file (e.g. we adopted a running
    # deployment whose secrets we couldn't read, so the password came from the
    # prompt above), remember it so exapump_validate_connection can persist it
    # AFTER confirming it works. The MCP step reads runtime.password_file to
    # provision the read-only user, so it must be recorded — but only once the
    # password is validated, otherwise a mistyped password would be saved and
    # the next run would reuse it instead of re-prompting.
    if [ -z "$_pwfile" ] || [ ! -f "$_pwfile" ]; then
        _EXAKIT_PENDING_RUNTIME_PASSWORD="$_password"
    fi

    exapump_write_profile "$EXAKIT_EXAPUMP_PROFILE" "$_host" "$_port" "$_user" "$_password" \
        || die "Could not write the exapump profile"
    manifest_set components.exapump.profile "$EXAKIT_EXAPUMP_PROFILE"
    ok_step "Connection profile [$EXAKIT_EXAPUMP_PROFILE] written to $(ui_tilde "$EXAPUMP_CONFIG")"
}

# exapump_write_profile <profile> <host> <port> <user> <password> - one TOML
# section in ~/.exapump/config.toml, replaced in place if it is already there.
#
# Split out of exapump_create_profile, which reads the manifest and can only
# ever write the kit's own profile. The legacy crossing needs a SECOND profile,
# pointing at the database an older kit deployed, and a password belongs in a
# 0600 config file rather than in argv where `ps` can read it - so both callers
# go through one writer instead of a second copy of this TOML surgery.
exapump_write_profile() {
    _ewp_profile="$1"; _ewp_host="$2"; _ewp_port="$3"; _ewp_user="$4"; _ewp_password="$5"
    require_python3
    mkdir -p "$(dirname "$EXAPUMP_CONFIG")"
    # The password travels in the ENVIRONMENT, never in argv. An argv is visible
    # to every local user through `ps` for the life of the call; a child's
    # environment is readable only by its owner and root. This is the same rule
    # _exakit_run_exapump_sql states and follows -- it can hand its secret to
    # stdin because its payload is SQL, while here stdin is already carrying the
    # Python program (the `-`), so the environment is the way to keep the
    # password off the process table.
    EXAKIT_PROFILE_PASSWORD="$_ewp_password"
    export EXAKIT_PROFILE_PASSWORD
    run_python - "$EXAPUMP_CONFIG" "$_ewp_profile" "$_ewp_host" "$_ewp_port" "$_ewp_user" <<'PY'
import os, re, sys
path, profile, host, port, user = sys.argv[1:6]
password = os.environ["EXAKIT_PROFILE_PASSWORD"]
try:
    with open(path) as f:
        content = f.read()
except FileNotFoundError:
    content = ""

section = (
    f"[{profile}]\n"
    f'host = "{host}"\n'
    f"port = {port}\n"
    f'user = "{user}"\n'
    f'password = "{password}"\n'
    f"tls = true\n"
    f"validate_certificate = false\n"
)
pattern = re.compile(rf"\[{re.escape(profile)}\][^\[]*", re.S)
if pattern.search(content):
    content = pattern.sub(section + "\n", content).rstrip("\n") + "\n"
else:
    if content and not content.endswith("\n\n"):
        content = content.rstrip("\n") + "\n\n"
    content += section
# Atomic replace: an interrupted run must never truncate a config that may
# hold the user's other profiles.
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(content)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
    _ewp_rc=$?
    # Unset on BOTH paths: an exported secret that outlives the call would be
    # inherited by every later child in this run, which is the leak this change
    # exists to close.
    unset EXAKIT_PROFILE_PASSWORD
    [ "$_ewp_rc" -eq 0 ] || return 1
    chmod 600 "$EXAPUMP_CONFIG"
}

# exapump_ddl_roundtrip — one DDL write-readback round through the profile.
# Returns 0 ONLY if a freshly created schema+table is durably persisted and
# visible from SUBSEQUENT connections (each exapump invocation reconnects).
#
# This is the real readiness signal. Right after first boot the database
# accepts a connection and answers SELECT 1 while still stabilizing, and in that
# window it can ACKNOWLEDGE a DDL batch ("N statements executed, 0 failed")
# without durably persisting it — so the schema-creation step "succeeds" but the
# very next `exapump upload` fails with "schema STARTER_KIT not found". The probe
# reproduces exactly that sequence (create schema in one connection, reference it
# from the next) so we only proceed once the database really is ready.
exapump_ddl_roundtrip() {
    _probe="EXAKIT_READY_PROBE"
    _cli="$(exapump_cli)"
    # Best-effort clean slate — a probe schema left by an interrupted earlier
    # attempt must not make this one look like a success. Result ignored.
    "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "DROP SCHEMA IF EXISTS $_probe CASCADE" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
    "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "CREATE SCHEMA $_probe" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 1
    # A NEW connection must see the just-created schema (this is the exact
    # cross-connection visibility that failed during install) and persist a table.
    if ! "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "CREATE TABLE $_probe.READY_PROBE (n DECIMAL(9,0))" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 \
        || ! "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "INSERT INTO $_probe.READY_PROBE VALUES (42)" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "DROP SCHEMA IF EXISTS $_probe CASCADE" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
        return 1
    fi
    _out="$("$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "SELECT 'EXAKIT_DDL[' || CAST(n AS VARCHAR(10)) || ']' AS R FROM $_probe.READY_PROBE" 2>/dev/null)"
    "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "DROP SCHEMA IF EXISTS $_probe CASCADE" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
    case "$_out" in
        *"EXAKIT_DDL[42]"*) return 0 ;;
        *) return 1 ;;
    esac
}

# exapump_confirm_database_ready — block until the database can durably persist
# a schema, not merely answer SELECT 1. Polls exapump_ddl_roundtrip with a
# bounded budget (EXAKIT_DDL_READY_TIMEOUT, default 180s) so the sample-data and
# MCP steps that follow can trust that CREATE SCHEMA/TABLE will stick.
exapump_confirm_database_ready() {
    _timeout="${EXAKIT_DDL_READY_TIMEOUT:-180}"
    info "Confirming the database can persist schema changes"
    # Announced by the caller, not here: answering SELECT 1 and persisting a
    # schema are one fact to the reader -- the database is ready -- and two
    # ticks for it read as two things to keep track of. This one stays in the
    # logfile; exapump_validate_connection prints the merged line.
    ui_spin_begin "Confirming the database can persist schema changes"
    _waited=0
    while :; do
        if exapump_ddl_roundtrip; then
            ui_spin_end
            if [ "$_waited" -eq 0 ]; then
                ok "Database is ready for schema changes"
            else
                ok "Database is ready for schema changes (after ~${_waited}s)"
            fi
            return 0
        fi
        [ "$_waited" -ge "$_timeout" ] && break
        sleep 5
        _waited=$((_waited + 5))
        if [ $((_waited % 30)) -eq 0 ]; then
            # Only where the spinner is not already counting -- a line printed
            # under a live animator is erased by its next frame.
            if [ -t 1 ]; then
                _exakit_log_file "INFO  Database still stabilizing... (${_waited}s)"
            else
                info "Database still stabilizing... (${_waited}s)"
            fi
        fi
    done
    ui_spin_end
    die "The database accepts connections but could not durably persist a schema within ${_timeout}s (first-boot stabilization window). Wait a moment, then retry: exakit data-load"
}

# exapump_validate_connection — SELECT 1 through the new profile, then confirm
# the database can durably persist DDL before any caller relies on CREATE SCHEMA
# sticking.
exapump_validate_connection() {
    if [ -z "$(manifest_get components.exapump.profile 2>/dev/null)" ]; then
        die "No connection profile exists (no database password was available to write one). Create it manually with 'exapump profile init $EXAKIT_EXAPUMP_PROFILE', then re-run this script."
    fi
    info "Validating the database connection (SELECT 1)"
    _evc_t0="$(date +%s 2>/dev/null || echo 0)"
    EXAKIT_ACTIVE_LABEL="Validating the database connection"
    _connected=0
    _tries=0
    while [ "$_tries" -lt 6 ]; do
        if run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" 'SELECT 1'; then
            _connected=1
            break
        fi
        _tries=$((_tries + 1))
        sleep 5
    done
    [ "$_connected" -eq 1 ] || \
        die "SELECT 1 failed via profile '$EXAKIT_EXAPUMP_PROFILE'. Try: exapump sql -p $EXAKIT_EXAPUMP_PROFILE 'SELECT 1'"
    ok "Connection works"

    # A working connection is NOT proof the database can persist schema changes
    # yet — see exapump_ddl_roundtrip. Gate here so both the data-load and MCP
    # steps that follow run against a database that is genuinely ready.
    exapump_confirm_database_ready

    # One line for both checks. Reaching here means SELECT 1 answered AND a
    # schema round-tripped durably; either failing dies with its own message.
    ok_step "Database ready — connection and schema changes verified ($(( $(date +%s 2>/dev/null || echo 0) - _evc_t0 ))s)"

    manifest_set components.exapump.validated true
    # Now that the password is proven to work, persist it as the runtime
    # password if the runtime step could not (adopted deployment with
    # unreadable secrets) — the MCP step needs runtime.password_file.
    if [ -n "${_EXAKIT_PENDING_RUNTIME_PASSWORD:-}" ]; then
        store_credential runtime_sys_password "$_EXAKIT_PENDING_RUNTIME_PASSWORD"
        manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/runtime_sys_password"
        unset _EXAKIT_PENDING_RUNTIME_PASSWORD
    fi
}

# exapump_run_sql_file <file> [description] — execute a SQL file, logged.
exapump_run_sql_file() {
    [ -s "$1" ] || { warn "SQL file missing or empty: $1"; return 1; }
    # EXAKIT_UPLOAD_QUIET covers this the same way it covers exapump_upload: a
    # caller narrating a whole job on one line does not want "Running x" / "x
    # done" for each of its scripts underneath. The failure path is never quiet.
    [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || info "Running ${2:-$(basename "$1")}"
    if ! run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" < "$1"; then
        [ -n "${EXAKIT_LOG_FILE:-}" ] && exakit_explain_db_error "$(tail -8 "$EXAKIT_LOG_FILE" 2>/dev/null)"
        die "The SQL in $(basename "$1") did not run. The database's own message: exakit logs setup. Check the database is up with: exakit status"
    fi
    [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "${2:-$(basename "$1")} done"
}

# exakit_upload_failure_reason — why the last upload failed, in one short line.
#
# The engine says something genuinely useful and says it in the logfile, where a
# reader has to go and find it. "could not be loaded (see log)" is the kit
# refusing to pass on an answer it already has: for a folder of three, one line
# said nothing and the reason sat four directories away.
#
# Only the shapes worth translating are translated; anything else is passed
# through trimmed, because a slightly long engine message beats no message.
exakit_upload_failure_reason() {
    [ -n "${EXAKIT_LOG_FILE:-}" ] || return 1
    _ufr_line="$(grep -a '^Error: ' "$EXAKIT_LOG_FILE" 2>/dev/null | tail -1)"
    [ -n "$_ufr_line" ] || return 1
    # A JSON value quoted by the engine stays in the log. A table loaded from a
    # JSON file carries nested objects as text, so a cast failure on one put
    # the object itself on screen -- braces and all, then cut at 160 characters
    # mid-key. The rest of the line still says what failed and where.
    _ufr_line="$(printf '%s' "$_ufr_line" | sed -e 's/{.*}/<JSON value>/' -e 's/{.*$/<JSON value>/')"
    _ufr_row="$(printf '%s' "$_ufr_line" | sed -n 's/.*row=\([0-9][0-9]*\).*/\1/p')"
    case "$_ufr_line" in
        *"not enclosed field"*)
            # The commonest CSV fault by far, and the message for it is dense:
            # a delimiter the parser met outside quotes. A line break inside a
            # quoted field arrives here too, because the parser ends the row at
            # the newline and then finds the fragment malformed.
            printf 'row %s has a line break or an unescaped %s inside a quoted field\n' \
                "${_ufr_row:-?}" "${EXAKIT_CSV_DELIM_NAME:-comma}" ;;
        *"<CR>"*)
            # The engine names the byte itself.
            printf 'the file has Windows line endings (CRLF), which exapump does not yet pass to the database correctly - re-save it with LF line endings (dos2unix, or "Save as" UTF-8 without CRLF) and load again\n' ;;
        *"ETL-"*)
            # The DETAIL after the code, up to the session id. The first
            # version stopped at the first "[", which is exactly where every
            # Exasol import message begins its detail ("[Column=11 Row=0]
            # [Transformation of value=...]") - so the screen said "ETL-3051"
            # and nothing else, and the one clause that named the fix was the
            # one dropped.
            _ufr_detail="$(printf '%s' "$_ufr_line" | sed -n 's/.*\(ETL-[0-9]*: .*\)$/\1/p' | sed 's/ (Session: .*//')"
            if [ "${#_ufr_detail}" -gt 160 ]; then
                _ufr_detail="$(printf '%s' "$_ufr_detail" | cut -c1-160 | sed 's/ [^ ]*$//')..."
            fi
            # A cast or parse failure on a file the inspector flagged as CRLF
            # is that flag, nine times in ten: the engine reports the symptom
            # ("invalid character value", "not correct enclosed field"), the
            # kit adds the cause it saw in the header.
            case ",${EXAKIT_CSV_FLAGS:-}," in
                *,crlf,*) _ufr_detail="$_ufr_detail - the file has Windows line endings (CRLF), which exapump does not yet pass to the database correctly; re-save it with LF line endings and load again" ;;
            esac
            printf '%s\n' "$_ufr_detail" ;;
        *)
            # THE FALLBACK TRIMMED WORSE THAN THE BRANCH ABOVE IT, and the fallback is
            # what an unrecognised engine error lands in - the ones a reader most needs
            # whole. 160 at a word boundary with an ellipsis up there; a bare 100-character
            # chop down here, mid-word, no ellipsis, and the "(Session: ...)" noise left in.
            # Observed on a real load:
            #     duplicate column name: name [line 4, column 5] (Session: 187
            #     Failed to infer CSV schema from '/Users/me/Desktop/stress-lo
            # Both stop mid-token, and the second loses the path it was about to name.
            _ufr_rest="$(printf '%s' "$_ufr_line" | sed -e 's/^Error: //' -e 's/ (Session: [0-9]*)//g')"
            case "$_ufr_rest" in
                ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????*)
                    _ufr_rest="$(printf '%s' "$_ufr_rest" | cut -c1-160 | sed 's/ [^ ]*$//')..." ;;
            esac
            printf '%s\n' "$_ufr_rest" ;;
    esac
}

# exapump_upload <file> <schema.table> — load a CSV/Parquet file, logged.
exapump_upload() {
    [ -s "$1" ] || { warn "Data file missing or empty: $1"; return 1; }
    # EXAKIT_UPLOAD_QUIET: `exakit data-load` narrates the whole job with a
    # single "Loading your data" spinner, so per-file chatter is noise there.
    # The installer leaves it unset and keeps its step-by-step narration.
    [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || info "Loading $(basename "$1") into $2"
    # The file goes over AS IT IS (see exakit_csv_inspect). What the header
    # says about the delimiter is passed on as exapump's own --delimiter; what
    # the engine will object to is remembered, so the failure reason can name
    # it.
    _upl_delim=","; EXAKIT_CSV_FLAGS=""
    if [ "$(exakit_data_file_kind "$1")" = csv ]; then
        if ! _upl_look="$(exakit_csv_inspect "$1")"; then
            warn "$(basename "$1") has a header and no rows - nothing to load"
            return 1
        fi
        _upl_delim="${_upl_look%%|*}"; EXAKIT_CSV_FLAGS="${_upl_look#*|}"
        case "$_upl_delim" in
            ";")  EXAKIT_CSV_DELIM_NAME="semicolon" ;;
            ",")  EXAKIT_CSV_DELIM_NAME="comma" ;;
            *)    EXAKIT_CSV_DELIM_NAME="tab" ;;
        esac
        [ -n "$EXAKIT_CSV_FLAGS" ] && _exakit_log_file "INFO  $(basename "$1") has: $EXAKIT_CSV_FLAGS"
    fi
    _upl_mark=0
    [ -n "${EXAKIT_LOG_FILE:-}" ] && _upl_mark="$(wc -l < "$EXAKIT_LOG_FILE" 2>/dev/null | tr -d ' ')"
    if [ "$_upl_delim" = "," ]; then
        run_logged "$(exapump_cli)" upload "$1" --table "$2" -p "$EXAKIT_EXAPUMP_PROFILE"
    else
        run_logged "$(exapump_cli)" upload "$1" --table "$2" -p "$EXAKIT_EXAPUMP_PROFILE" --delimiter "$_upl_delim"
    fi
    _upl_rc=$?
    # A cut transfer is recovered here too, not only in the dataset batch: a
    # user's own file crosses the same import connection. The failed attempt's
    # output is only in the log (run_logged), so that is where it is read from -
    # and only a cut it SAYS is acted on: an empty slice of the log is no
    # evidence of a silent failure, just of nothing written there.
    if [ "$_upl_rc" -ne 0 ] && [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        _upl_out="$(mktemp "${TMPDIR:-/tmp}/exakit-upload-out.XXXXXX")" || _upl_out=""
        if [ -n "$_upl_out" ]; then
            tail -n +"$(( ${_upl_mark:-0} + 1 ))" "$EXAKIT_LOG_FILE" 2>/dev/null | sed '/CMD   /d' > "$_upl_out"
            if exakit_upload_cut_short "$(cat "$_upl_out")" && \
               exakit_upload_recover "$1" "$2" "$_upl_delim" "$_upl_rc" "$_upl_out"; then
                _upl_rc=0
            fi
            rm -f "$_upl_out"
        fi
    fi
    if [ "$_upl_rc" -ne 0 ]; then
        # EXAKIT_UPLOAD_SOFT: the caller is loading MANY files, reports each one
        # itself and carries on. Dying here announced a whole-job failure for one
        # file out of three -- a red "Upload failed" and a log path, directly
        # above the caller's own line saying the same thing more calmly. One
        # unreadable file in a folder is not the job failing.
        if [ "${EXAKIT_UPLOAD_SOFT:-0}" = 1 ]; then
            return 1
        fi
        # The engine's message is in the log; translate the common faults into
        # their remedy before dying, so "Connection refused" arrives WITH
        # "exakit start" instead of leaving the user to map one to the other.
        [ -n "${EXAKIT_LOG_FILE:-}" ] && exakit_explain_db_error "$(tail -8 "$EXAKIT_LOG_FILE" 2>/dev/null)"
        # exakit_explain_db_error only knows connection, LIMIT and privilege
        # faults, so a malformed CSV -- the commonest upload failure there is --
        # matched none of them and arrived as "(see log)". The translator that
        # does know that fault was already written and already used one line
        # above (the soft path) and in the folder loop, which means the FATAL
        # outcome was the one getting the worse message. Same reason, same
        # words, on both paths.
        _upl_why="$(exakit_upload_failure_reason 2>/dev/null || true)"
        if [ -n "$_upl_why" ]; then
            die "Could not load $(basename "$1") into $2 — $_upl_why"
        fi
        # "Upload failed:" ON PURPOSE, not the "Could not load X into Y" form
        # used above. That form is reserved for the branch that HAS the
        # engine's reason and appends it; reusing it here would tell the reader
        # the kit knows why when it does not. The log command is named either
        # way - that part was the NEW-03 defect, and it is fixed without
        # flattening the distinction the two sentences carry.
        die "Upload failed: $1 -> $2. What exapump said is in the log: exakit logs setup. Check the database is up with: exakit status"
    fi
    [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "$(basename "$1") loaded"
    # A CRLF file whose last column is text LOADS - and every value in that
    # column ends in a carriage return, because exapump set no row separator
    # and Exasol took the CR as data. 49,812 of 49,812 rows of one public
    # dataset, checked. A load that silently corrupts one column is worse
    # than one that fails, so a bridge that will not rewrite the file has to
    # say this out loud.
    case ",${EXAKIT_CSV_FLAGS:-}," in
        *,crlf,*) warn "$(basename "$1") has Windows line endings (CRLF), which exapump passes through: every value in the last column of $2 ends in a carriage return. Re-save the file with LF endings and load again, or trim it in SQL with RTRIM(col, CHR(13))." ;;
    esac
}

# exakit_upload_parallel — how many uploads may run at once.
#
# WHY UPLOADS OVERLAP AT ALL: an exapump call is a process launch, and on a
# fresh Windows install each one measured ~4.4s against 185ms once warm. A
# dataset load is dominated by that, not by row throughput — weather (10,970
# rows) took as long as energy (108,050) because both made the same number of
# launches. The launches cannot be merged: exapump upload takes many FILES but
# only one --table, and IMPORT ... FROM LOCAL CSV FILE is refused by the server
# over this protocol ("only supported via JDBC or EXAplus"). Overlapping them
# is what is left.
#
# EXAKIT_UPLOAD_PARALLEL=1 restores exactly the old serial behaviour.
exakit_upload_parallel() {
    _up_n="${EXAKIT_UPLOAD_PARALLEL:-4}"
    case "$_up_n" in
        ''|*[!0-9]*) _up_n=4 ;;
    esac
    [ "$_up_n" -ge 1 ] 2>/dev/null || _up_n=1
    [ "$_up_n" -le 8 ] 2>/dev/null || _up_n=8
    printf '%s' "$_up_n"
}

# exapump_upload_many <schema> <file>... — upload every file CONCURRENTLY, one
# exapump process each, in waves of exakit_upload_parallel.
#
# Waves rather than a rolling window because bash 3.2 has no `wait -n`: it can
# only wait for ALL background jobs, so a wave pays for its slowest member.
# That is still far better than one-at-a-time and it keeps the control flow
# simple enough to be obviously correct.
#
# Sets EXAKIT_UPLOAD_FAILED to the failing "file -> table" pairs (empty when
# all succeeded). Failures are COLLECTED, not fatal on the spot: die() inside a
# background job cannot stop the parent, and abandoning the wave would leave
# the other uploads running unreaped.
# exakit_upload_cut_short <exapump output> — did the import connection die
# mid-transfer? The database reads the file through its own import proxy, and
# when the client side of that connection closes before the last byte the
# engine says ETL-5105 "transfer closed with outstanding read data remaining".
# Seen on Windows with exapump 0.12: one or two of eight files per run, a
# different file each time, the same file loading fine a moment later - so
# the remedy is a second attempt, not a message. A malformed file, a missing
# table or a refused login is not this and is never retried.
exakit_upload_cut_short() {
    case "$1" in
        *ETL-5105*|*"transfer closed with outstanding read data"*|*"Transferred a partial file"*|*"Connection reset by peer"*|*"connection was aborted"*) return 0 ;;
    esac
    return 1
}

# exakit_upload_retries — how many more attempts a cut-short upload gets
# (EXAKIT_UPLOAD_RETRIES, default 2; 0 disables).
exakit_upload_retries() {
    case "${EXAKIT_UPLOAD_RETRIES:-2}" in
        ''|*[!0-9]*) printf '2' ;;
        *) printf '%s' "${EXAKIT_UPLOAD_RETRIES:-2}" ;;
    esac
}

# exakit_upload_retryable <exit code> <exapump output> — is this failed upload
# worth another attempt? A cut transfer (exakit_upload_cut_short) is, and so is
# a non-zero exit that printed NOTHING: seen on Windows in the same runs as the
# cuts, five files in a row - a 415-byte one among them - that the same command
# loaded a moment later. A failure that says what is wrong is never retried.
# Twin of Test-ExakitUploadRetryable.
exakit_upload_retryable() {
    exakit_upload_cut_short "$2" && return 0
    [ "$1" != 0 ] || return 1
    [ -z "$(printf '%s' "$2" | tr -d ' \t\r\n')" ]
}

# exakit_upload_piece_bytes — how big each piece of a re-sent file is
# (EXAKIT_UPLOAD_PIECE_KB, default 128; 0 turns piecing off).
#
# WHY PIECES: the cut is not random. Against Exasol Personal on Windows (the
# database inside the Podman WSL machine) the engine loses the LAST 10-90 KB of
# the file - "failed after 393216 bytes" of a 475 KB file, every time, while a
# 390 KB file never failed. Retrying the same file mostly repeats the same cut
# (customer.csv needed nine attempts), so the file is re-sent in pieces small
# enough to arrive whole: measured 54 of 54 at 128 KB, 3 of 72 failing at 256
# KB. Twin of Get-ExakitUploadPieceBytes.
exakit_upload_piece_bytes() {
    case "${EXAKIT_UPLOAD_PIECE_KB:-128}" in
        ''|*[!0-9]*) printf '%s' $((128 * 1024)) ;;
        *) printf '%s' $(( ${EXAKIT_UPLOAD_PIECE_KB:-128} * 1024 )) ;;
    esac
}

# exakit_upload_pieceable <file> — can this file be re-sent in pieces? A plain
# (uncompressed) delimited text file, bigger than one piece, and no bigger than
# 64 MB - past that the piece count, one exapump launch each, costs more than
# the retry is worth. Twin of Test-ExakitUploadPieceable.
exakit_upload_pieceable() {
    _eupa_piece="$(exakit_upload_piece_bytes)"
    [ "$_eupa_piece" -gt 0 ] || return 1
    case "$1" in
        *.csv|*.CSV|*.tsv|*.TSV|*.txt|*.TXT) ;;
        *) return 1 ;;
    esac
    [ -f "$1" ] || return 1
    _eupa_size="$(wc -c < "$1" | tr -d ' ')"
    [ "$_eupa_size" -gt "$_eupa_piece" ] && [ "$_eupa_size" -le 67108864 ]
}

# exakit_split_csv_pieces <file> <dir> <bytes> — cut a CSV into pieces of about
# <bytes> in <dir>, each carrying the header, named so they sort in order.
#
# Line for line: every row goes over exactly as it was, CR included on a CRLF
# file. Cuts only fall where the double quotes seen so far in the piece are
# even - a newline inside a quoted field is data, not a row boundary. LC_ALL=C
# so length() counts bytes. Twin of Split-ExakitCsvPieces.
exakit_split_csv_pieces() {
    _escp_base="$(basename "$1")"
    LC_ALL=C awk -v dir="$2" -v stem="${_escp_base%.*}" -v ext="${_escp_base##*.}" -v lim="$3" '
        NR == 1 { head = $0; next }
        {
            if (f == "" || (size >= lim && quotes % 2 == 0)) {
                if (f != "") close(f)
                n++
                f = sprintf("%s/%s.piece%04d.%s", dir, stem, n, ext)
                print head > f
                size = length(head) + 1
                quotes = 0
            }
            print > f
            size += length($0) + 1
            line = $0
            quotes += gsub(/"/, "", line)
        }' "$1"
}

# _exakit_upload_run <outfile> <exapump args>... — one exapump call, its output
# kept in <outfile> and appended to the log.
_exakit_upload_run() {
    _eur_out="$1"; shift
    "$(exapump_cli)" "$@" > "$_eur_out" 2>&1
    _eur_rc=$?
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf 'exapump %s\n' "$*" >> "$EXAKIT_LOG_FILE"
        cat "$_eur_out" >> "$EXAKIT_LOG_FILE" 2>/dev/null
    fi
    return $_eur_rc
}

# exakit_upload_pieces <file> <schema.table> <delimiter> <outfile> — re-send a
# file in pieces, ALL OR NOTHING.
#
# The pieces are separate exapump calls, so separate commits: loading them
# straight into the target would leave a half-loaded table behind the one
# piece that never made it - and for a user appending to a table they already
# had, no safe way back. So they go into a staging copy of the target (CREATE
# TABLE ... LIKE), and only once every piece is in does ONE INSERT ... SELECT
# move them across. Any failure drops the staging table; the target is exactly
# as it was. Needs the target to exist - it always does here, because a cut
# import has already created it. <outfile> ends up holding the output of the
# attempt that decided it. Twin of Invoke-ExakitUploadPieces.
exakit_upload_pieces() {
    _eup_file="$1"; _eup_table="$2"; _eup_delim="${3:-,}"; _eup_out="$4"
    _eup_stage="${_eup_table}__EXAKIT_PIECES"
    _eup_max="$(exakit_upload_retries)"
    _eup_dir="$(mktemp -d "${TMPDIR:-/tmp}/exakit-pieces.XXXXXX")" || return 1
    exakit_split_csv_pieces "$_eup_file" "$_eup_dir" "$(exakit_upload_piece_bytes)"
    _eup_n="$(ls "$_eup_dir" | wc -l | tr -d ' ')"
    if [ "$_eup_n" -eq 0 ]; then rm -rf "$_eup_dir"; return 1; fi
    [ -n "${EXAKIT_LOG_FILE:-}" ] && \
        printf 'WARN  %s: re-sending it as %s smaller pieces through %s\n' \
            "$(basename "$_eup_file")" "$_eup_n" "$_eup_stage" >> "$EXAKIT_LOG_FILE"
    if ! _exakit_upload_run "$_eup_out" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
            "DROP TABLE IF EXISTS $_eup_stage; CREATE TABLE $_eup_stage LIKE $_eup_table"; then
        rm -rf "$_eup_dir"; return 1
    fi
    for _eup_p in "$_eup_dir"/*; do
        _eup_try=0
        while :; do
            if [ "$_eup_delim" = "," ]; then
                _exakit_upload_run "$_eup_out" upload "$_eup_p" --table "$_eup_stage" -p "$EXAKIT_EXAPUMP_PROFILE"
            else
                _exakit_upload_run "$_eup_out" upload "$_eup_p" --table "$_eup_stage" -p "$EXAKIT_EXAPUMP_PROFILE" --delimiter "$_eup_delim"
            fi
            _eup_rc=$?
            [ "$_eup_rc" = 0 ] && break
            if [ "$_eup_try" -ge "$_eup_max" ] || ! exakit_upload_retryable "$_eup_rc" "$(cat "$_eup_out" 2>/dev/null)"; then
                "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "DROP TABLE IF EXISTS $_eup_stage" >/dev/null 2>&1
                rm -rf "$_eup_dir"; return 1
            fi
            _eup_try=$((_eup_try + 1))
            sleep "$_eup_try"
        done
    done
    rm -rf "$_eup_dir"
    if ! _exakit_upload_run "$_eup_out" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
            "INSERT INTO $_eup_table SELECT * FROM $_eup_stage; DROP TABLE $_eup_stage"; then
        "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "DROP TABLE IF EXISTS $_eup_stage" >/dev/null 2>&1
        return 1
    fi
    return 0
}

# exakit_upload_recover <file> <schema.table> <delimiter> <exit code> <outfile>
# — what every failed upload goes through before anyone hears about it. A
# failure that is not retryable (exakit_upload_retryable) comes straight back.
# A retryable one is re-sent in pieces when the file allows
# (exakit_upload_pieceable), otherwise tried again whole, with a short pause
# between attempts. <outfile> holds the failed attempt's output on the way in
# and the last attempt's on the way out; the log keeps every attempt. Twin of
# Invoke-ExakitUploadRecovery.
exakit_upload_recover() {
    _eurc_file="$1"; _eurc_table="$2"; _eurc_delim="${3:-,}"; _eurc_rc="$4"; _eurc_out="$5"
    _eurc_name="$(basename "$_eurc_file")"
    # Nothing on screen and nothing in the log is what made the Windows
    # failures above impossible to read afterwards. The exit code is all there
    # is, so it is kept.
    if [ -z "$(tr -d ' \t\r\n' < "$_eurc_out" 2>/dev/null)" ] && [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf 'WARN  %s: exapump exited with code %s and printed nothing\n' "$_eurc_name" "$_eurc_rc" >> "$EXAKIT_LOG_FILE"
    fi
    _eurc_max="$(exakit_upload_retries)"
    [ "$_eurc_max" -ge 1 ] || return 1
    exakit_upload_retryable "$_eurc_rc" "$(cat "$_eurc_out" 2>/dev/null)" || return 1
    if exakit_upload_pieceable "$_eurc_file"; then
        EXAKIT_UPLOAD_RETRIED=$((${EXAKIT_UPLOAD_RETRIED:-0} + 1))
        exakit_upload_pieces "$_eurc_file" "$_eurc_table" "$_eurc_delim" "$_eurc_out"
        return
    fi
    _eurc_try=0
    while [ "$_eurc_try" -lt "$_eurc_max" ]; do
        _eurc_try=$((_eurc_try + 1))
        EXAKIT_UPLOAD_RETRIED=$((${EXAKIT_UPLOAD_RETRIED:-0} + 1))
        if exakit_upload_cut_short "$(cat "$_eurc_out" 2>/dev/null)"; then
            _eurc_why="the import connection was cut mid-transfer"
        else
            _eurc_why="exapump failed without saying why"
        fi
        [ -n "${EXAKIT_LOG_FILE:-}" ] && \
            printf 'WARN  %s: %s - attempt %s of %s\n' \
                "$_eurc_name" "$_eurc_why" "$((_eurc_try + 1))" "$((_eurc_max + 1))" >> "$EXAKIT_LOG_FILE"
        [ "$_eurc_try" -gt 1 ] && sleep $((_eurc_try - 1))
        if [ "$_eurc_delim" = "," ]; then
            "$(exapump_cli)" upload "$_eurc_file" --table "$_eurc_table" -p "$EXAKIT_EXAPUMP_PROFILE" > "$_eurc_out" 2>&1
        else
            "$(exapump_cli)" upload "$_eurc_file" --table "$_eurc_table" -p "$EXAKIT_EXAPUMP_PROFILE" --delimiter "$_eurc_delim" > "$_eurc_out" 2>&1
        fi
        _eurc_rc=$?
        [ -n "${EXAKIT_LOG_FILE:-}" ] && cat "$_eurc_out" >> "$EXAKIT_LOG_FILE" 2>/dev/null
        [ "$_eurc_rc" = 0 ] && return 0
        exakit_upload_retryable "$_eurc_rc" "$(cat "$_eurc_out" 2>/dev/null)" || return 1
    done
    return 1
}

exapump_upload_many() {
    _um_schema="$1"; shift
    EXAKIT_UPLOAD_FAILED=""
    EXAKIT_UPLOAD_RETRIED=0
    [ $# -gt 0 ] || return 0
    _um_cap="$(exakit_upload_parallel)"
    _um_dir="$(mktemp -d "${TMPDIR:-/tmp}/exakit-upload.XXXXXX")" || \
        die "Could not create a temporary directory for the upload batch."
    _um_i=0
    for _um_file in "$@"; do
        _um_i=$((_um_i + 1))
        _um_table="$(basename "$_um_file" .csv | tr '[:lower:]' '[:upper:]')"
        printf '%s\n' "$_um_file" > "$_um_dir/$_um_i.file"
        printf '%s\n' "$_um_schema.$_um_table" > "$_um_dir/$_um_i.table"
        (
            "$(exapump_cli)" upload "$_um_file" --table "$_um_schema.$_um_table" \
                -p "$EXAKIT_EXAPUMP_PROFILE" > "$_um_dir/$_um_i.out" 2>&1
            printf '%s' "$?" > "$_um_dir/$_um_i.rc"
        ) &
        if [ $((_um_i % _um_cap)) -eq 0 ]; then
            wait
            # A wave landed. bash 3.2 has no `wait -n`, so a wave is the finest
            # grain there is — and it is enough to say the batch is draining
            # while the caller's bar creeps across the segment on its own clock.
            [ -n "${EXAKIT_PROGRESS_STATE:-}" ] && \
                ui_progress_phase "$EXAKIT_PROGRESS_STATE" \
                    "$EXAKIT_PROGRESS_LABEL loaded $_um_i of $# data files"
        fi
    done
    wait
    # Logged in FILE ORDER once every process has finished, so the logfile still
    # reads as one block per upload rather than interleaved fragments.
    _um_j=0
    while [ "$_um_j" -lt "$_um_i" ]; do
        _um_j=$((_um_j + 1))
        _um_f="$(cat "$_um_dir/$_um_j.file" 2>/dev/null)"
        _um_t="$(cat "$_um_dir/$_um_j.table" 2>/dev/null)"
        _um_rc="$(cat "$_um_dir/$_um_j.rc" 2>/dev/null)"
        if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
            printf 'exapump upload %s --table %s -p %s\n' "$_um_f" "$_um_t" \
                "$EXAKIT_EXAPUMP_PROFILE" >> "$EXAKIT_LOG_FILE"
            cat "$_um_dir/$_um_j.out" >> "$EXAKIT_LOG_FILE" 2>/dev/null
        fi
        if [ "$_um_rc" = "0" ]; then
            [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "$(basename "$_um_f") loaded"
            continue
        fi
        # A CUT TRANSFER IS RECOVERED, one file at a time, before anyone
        # hears about it - re-sent in pieces or tried again whole. See
        # exakit_upload_recover.
        if exakit_upload_recover "$_um_f" "$_um_t" "," "${_um_rc:-1}" "$_um_dir/$_um_j.out"; then
            _um_rc=0
        fi
        if [ "$_um_rc" = "0" ]; then
            [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "$(basename "$_um_f") loaded"
            continue
        fi
        [ -n "${EXAKIT_LOG_FILE:-}" ] && \
            exakit_explain_db_error "$(tail -8 "$_um_dir/$_um_j.out" 2>/dev/null)"
        EXAKIT_UPLOAD_FAILED="${EXAKIT_UPLOAD_FAILED:+$EXAKIT_UPLOAD_FAILED; }$_um_f -> $_um_t"
    done
    rm -rf "$_um_dir"
    [ -z "$EXAKIT_UPLOAD_FAILED" ]
}

# exapump_count <schema.table> — row count (prints the number, empty on failure).
# Wrap the count in a unique delimited token (EXAKIT_RC[<n>]) and recover it with
# a regex instead of scraping the last line for digits. The old "tail -1 |
# tr -dc 0-9" collapsed exapump's "[1/1] ... 1 rows" status line to "111" for
# every table in non-TTY installs (where exapump prints no separate value line).
# The echoed query literal never forms "EXAKIT_RC[<digits>]", so only the real
# result matches.
exapump_count() {
    _sql="SELECT 'EXAKIT_RC[' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $1"
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "$_sql" 2>/dev/null | \
        grep -oE 'EXAKIT_RC\[[0-9]+\]' | head -1 | tr -dc '0-9'
}

# exapump_count_many <schema> <table>... - count EVERY table in ONE exapump
# invocation instead of one per table.
#
# WHY THIS EXISTS: every exapump call is a separate PROCESS LAUNCH, and on
# Windows a freshly downloaded, unsigned exapump.exe is re-scanned by Defender
# on each one - measured at ~4.4s per launch during an install, against 88ms
# once the scan is cached. A tpch load made 20 launches, 8 of them nothing but
# one COUNT(*) per table. That is why loading weather (10,970 rows) took as
# long as energy (108,050 rows): both made 7 launches. The row counts never
# mattered; the launch count did.
#
# Prints one "<table> <count>" line per table asked for, in query order.
# Returns NON-ZERO and prints nothing unless every table came back: a UNION ALL
# fails as a whole, so a partial result must send the caller back to counting
# one at a time rather than let it report a total that is quietly short.
#
# The token carries the table name (EXAKIT_RC[CUSTOMER=1500]) because one
# result set now holds every count and they have to be told apart. As with
# exapump_count, the echoed query literal cannot match: after "=" it has a
# quote, not a digit.
exapump_count_many() {
    _ecm_schema="$1"; shift
    [ $# -gt 0 ] || return 0
    _ecm_want=$#
    _ecm_sql=""
    for _ecm_t in "$@"; do
        [ -n "$_ecm_sql" ] && _ecm_sql="$_ecm_sql UNION ALL "
        _ecm_sql="${_ecm_sql}SELECT 'EXAKIT_RC[$_ecm_t=' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $_ecm_schema.$_ecm_t"
    done
    _ecm_out="$("$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "$_ecm_sql" 2>/dev/null | \
        grep -oE 'EXAKIT_RC\[[A-Za-z0-9_]+=[0-9]+\]' | \
        sed -e 's/^EXAKIT_RC\[//' -e 's/\]$//' -e 's/=/ /')"
    # Deliberately not "grep -c . || printf 0": on empty input grep PRINTS 0
    # and EXITS 1, so the fallback fires too and the count reads "00". It would
    # still be caught by the comparison below, but only by accident.
    _ecm_got=0
    if [ -n "$_ecm_out" ]; then
        _ecm_got="$(printf '%s
' "$_ecm_out" | grep -c .)"
    fi
    [ "$_ecm_got" = "$_ecm_want" ] || return 1
    printf '%s\n' "$_ecm_out"
}

# exakit_group_digits <n> — 173745 -> 173,745. Worth the sed: the row total is
# the one number in a dataset's result line that a reader compares against what
# they were expecting.
exakit_group_digits() {
    printf '%s' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

# --- weighting a load by what it actually costs ------------------------------
# A dataset is twelve steps and one of them is most of the wall clock: TPC-H's
# lineitem.csv is fifteen megabytes against seven files of a few hundred
# kilobytes each. Counted as steps, the bar leapt to 58% through the small files
# and then sat there for twenty seconds — honest arithmetic, useless to watch.
#
# So the denominator is BYTES, which is the one thing known before any of it
# runs. The steps that move no bytes (a schema script, the load statements, the
# verification, the row counts) are worth a nominal share each, measured against
# the same scale, so they neither vanish nor dominate.
EXAKIT_LOAD_STEP_SHARE="${EXAKIT_LOAD_STEP_SHARE:-5}"     # percent of the byte total, per byteless step
# ...but never less than this. A share of the bytes alone is right only for a
# dataset whose cost IS its files, and energy is the counter-example: 1,882 bytes
# of CSV and an 02_load_data.sql that GENERATES 108,000 readings. Five percent of
# 1,882 is 94, so the step that was the whole job got four percent of the bar,
# the upload segment capped at 86% and sat there for a minute. A script is worth
# about a quarter-megabyte of loading, which for a generator is if anything shy.
EXAKIT_LOAD_STEP_FLOOR="${EXAKIT_LOAD_STEP_FLOOR:-262144}"
EXAKIT_LOAD_BYTES_PER_SEC="${EXAKIT_LOAD_BYTES_PER_SEC:-1048576}"

# exakit_load_nominal <total-bytes> — what one byteless step is worth.
exakit_load_nominal() {
    _lno=$(( ${1:-0} * EXAKIT_LOAD_STEP_SHARE / 100 ))
    [ "$_lno" -ge "$EXAKIT_LOAD_STEP_FLOOR" ] || _lno="$EXAKIT_LOAD_STEP_FLOOR"
    printf '%s\n' "$_lno"
}

# exakit_load_weight_of <file> — a file's weight, which is its size.
exakit_load_weight_of() {
    [ -f "$1" ] || { printf '0\n'; return 0; }
    wc -c < "$1" 2>/dev/null | tr -d ' '
}

# exakit_load_secs_for <weight> — how long that much weight usually takes, for
# the creep to fill in with. Only ever an estimate, and a safe one: the creep is
# capped below the next stage, so guessing short makes the bar wait and guessing
# long makes it move slowly. Neither lies.
exakit_load_secs_for() {
    _lsf=$(( ${1:-0} / EXAKIT_LOAD_BYTES_PER_SEC ))
    [ "$_lsf" -ge 2 ] || _lsf=2
    printf '%s\n' "$_lsf"
}

# exakit_load_step <state-file> <done-weight> <step-weight> <total-weight>
#                  <seconds> <phase>
# The load has reached a new stage: report where it is and where this stage ends.
# Prints nothing — ui_progress_animate is what draws.
exakit_load_step() {
    _lst_pct=0
    _lst_ceil=0
    if [ "${4:-0}" -gt 0 ]; then
        _lst_pct=$(( $2 * 100 / $4 ))
        _lst_ceil=$(( ($2 + $3) * 100 / $4 ))
    fi
    [ "$_lst_ceil" -gt 100 ] && _lst_ceil=100
    [ "$_lst_pct" -gt 100 ] && _lst_pct=100
    # A dataset being loaded from the table reports into its ROW; anything else
    # (a folder, a single named file) still owns the one-line bar.
    if [ -n "${EXAKIT_TABLE_ROW:-}" ] && [ -n "${EXAKIT_TABLE_STATE:-}" ]; then
        ui_table_set "$EXAKIT_TABLE_STATE" "$EXAKIT_TABLE_ROW" running \
            "$_lst_pct" "$_lst_ceil" "$5" "$6"
        return 0
    fi
    ui_progress_state "$1" "$_lst_pct" "$_lst_ceil" "$5" "$6"
}

exapump_record_manifest() {
    manifest_set components.exapump.version "$EXAKIT_EXAPUMP_VERSION"
    manifest_set components.exapump.path "$(exapump_cli)"
}

# exapump_confirm_installed_version — ask the binary what it is, now that this run
# has installed one, and make the record agree with the answer.
# exapump_record_manifest writes the version the run INTENDED to install; only the
# binary can say what is actually there (the recorded path can be gone by the time
# anyone looks, leaving an exapump the user manages themselves on PATH as the answer,
# and the glibc shim runs whatever the container image holds). Returns non-zero when
# they disagree, so the caller does not announce a move that did not happen.
#
# Silence is left alone deliberately: exakit_component_current answers nothing only
# when there is no runnable binary at all, exapump_install already fails loudly for
# that, and a correction invented from silence would be worse than the record.
# ⇄ twin: Confirm-ExapumpInstalledVersion in exapump.ps1.
exapump_confirm_installed_version() {
    command -v exakit_component_current >/dev/null 2>&1 || return 0
    _ecv_live="$(exakit_component_current exapump 2>/dev/null || true)"
    [ -n "$_ecv_live" ] || return 0
    [ "$_ecv_live" != "$EXAKIT_EXAPUMP_VERSION" ] || return 0
    warn "The exapump on disk reports $_ecv_live, not the $EXAKIT_EXAPUMP_VERSION this update installed — recording what is there"
    manifest_set components.exapump.version "$_ecv_live"
    return 1
}

exapump_update() {
    _latest="$(exakit_component_available exapump)"
    [ -n "$_latest" ] || die "Could not resolve the advertised exapump version."
    # The already-current guard reads the same thing `exakit version` prints in
    # its Installed column: the version the binary on disk reports when asked. The
    # manifest record is only what a previous run WROTE DOWN — exapump_record_manifest
    # writes it from EXAKIT_EXAPUMP_VERSION, before the download it describes is
    # proven — so it can name a version that was never installed, and it says nothing
    # at all about a binary someone replaced by hand. Comparing against the record
    # made this function decline the work the dispatcher had just announced from the
    # live probe ("exapump 0.11.0 -> 0.11.2", then "already current (0.11.2)"), and
    # call an install current at a version nobody is running.
    _exapump_recorded="$(manifest_get components.exapump.version 2>/dev/null || true)"
    if command -v exakit_component_current >/dev/null 2>&1; then
        # An empty answer is NOT "cannot tell", so it must not fall back to the
        # record: for exapump the reader answers nothing only when there is no
        # executable binary at the recorded path or on PATH, and it already falls
        # back to the record itself when a binary IS there but will not run (a
        # release built against a newer glibc). Provably absent means install —
        # the record must not vouch for a binary that is gone.
        _current="$(exakit_component_current exapump 2>/dev/null || true)"
    else
        # The reader lives in common.sh, which every entry point sources before this
        # module. This is the sourced-alone case, where the record is all there is.
        _current="$_exapump_recorded"
    fi
    if [ "$_latest" = "$_current" ]; then
        # Genuinely already current, so this stays a clean skip — but a record that
        # disagrees with the binary is still reconciled, because that record is what
        # `exakit version` credits the kit with having installed, and what a
        # subsequent exapump_install would leave untouched on its already-installed
        # path.
        if [ "$_exapump_recorded" != "$_current" ]; then
            info "Reconciling the recorded exapump version (${_exapump_recorded:-unrecorded}) with the binary on disk"
            manifest_set components.exapump.version "$_current"
        fi
        ok "exapump is already current ($_current)"
        return 0
    fi
    # Not the place to ask whether $_latest is a step BACKWARDS from $_current. That
    # is settled once, for every component, at the choke point in
    # exakit_update_component (exakit_component_is_ahead), which reads the same live
    # probe this guard now reads and returns before exapump_update is called at all.
    # A second copy of the rule here would be one more thing to keep in step with it.
    info "Updating exapump ${_current:-not installed} -> $_latest"
    EXAKIT_EXAPUMP_VERSION="$_latest"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_EXAPUMP_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    exapump_install
    exapump_create_profile
    manifest_set desired.exapump "$EXAKIT_EXAPUMP_VERSION"
    # Confirm from the binary, not from the record exapump_install just wrote.
    if exapump_confirm_installed_version; then
        ok "exapump updated without changing database data"
    fi
}

exakit_table_name_from_path() {
    _base="$(basename "$1")"
    _base="${_base%%\?*}"
    _base="${_base%.*}"
    _table="$(printf '%s' "$_base" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')"
    _table="$(printf '%s' "$_table" | sed 's/^_*//; s/_*$//; s/__*/_/g')"
    printf '%s\n' "${_table:-MY_TABLE}"
}

exakit_normalize_path() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

exakit_validate_table_target() {
    case "$1" in
        *.*) ;;
        *) return 1 ;;
    esac
    _schema="${1%%.*}"
    _table="${1#*.}"
    case "$_schema" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
    case "$_table" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
    return 0
}

exakit_target_schema() {
    printf '%s\n' "${1%%.*}" | tr '[:lower:]' '[:upper:]'
}

exakit_upper_table_target() {
    _schema="${1%%.*}"
    _table="${1#*.}"
    printf '%s.%s\n' \
        "$(printf '%s' "$_schema" | tr '[:lower:]' '[:upper:]')" \
        "$(printf '%s' "$_table" | tr '[:lower:]' '[:upper:]')"
}

# exakit_schema_present <schema> — read-only check that a schema exists, from a
# fresh connection. Distinct from exakit_ensure_schema, which also creates it.
exakit_schema_present() {
    _schema="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    [ -n "$_schema" ] || return 1
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$_schema') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS" \
        2>> "${EXAKIT_LOG_FILE:-/dev/null}" | grep -q "EXAKIT_SCHEMA_PRESENT"
}

exakit_ensure_schema() {
    _schema="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    [ -n "$_schema" ] || return 1
    if exakit_schema_present "$_schema"; then
        return 0
    fi
    [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || info "Creating schema $_schema"
    run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "CREATE SCHEMA $_schema" || \
        die "Could not create schema $_schema"
}

exakit_verify_loaded_table() {
    _target="$1"
    _rows="$(exapump_count "$_target")"
    [ -n "$_rows" ] || die "Could not verify row count for $_target."
    if [ "$_rows" = "0" ]; then
        warn "Verified $_target, but it currently has 0 rows."
    else
        [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "Verified $_target ($_rows rows)"
    fi
    manifest_set data.last_load.verified_table "$_target"
    manifest_set data.last_load.verified_rows "$_rows"
}

exakit_prompt_optional_verification() {
    _default="${1:-}"
    _target="$(prompt_text "Verify table after script/import (SCHEMA.TABLE, blank to skip)" "$_default")"
    [ -n "$_target" ] || {
        info "Skipping table verification for this script/import."
        return 0
    }
    exakit_validate_table_target "$_target" || die "Verification table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    exakit_verify_loaded_table "$(exakit_upper_table_target "$_target")"
}

# --- JSON input: routed through the JSON Tables add-on -----------------------
#
# exapump loads CSV and Parquet. JSON is a different shape of problem -- one
# document can be an arbitrarily nested tree, and turning that into relational
# tables is what the JSON Tables add-on exists for. So `exakit data-load` reads
# the file's kind first and, for JSON, offers the add-on (prebuilt, no Rust
# toolchain) and then finishes the load itself: ingest the JSON to Parquet,
# then push the Parquet in through the same verified exapump path CSV uses.
# The user hands over one JSON file and ends up with queryable tables.

# exakit_data_file_kind <path> — csv | parquet | json | unknown, from the name.
# Compressed variants resolve to their payload kind: exapump handles .csv.gz,
# and the ingest engine reads .json.gz / .ndjson.gz.
exakit_data_file_kind() {
    _dfk_name="$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')"
    case "$_dfk_name" in
        *.gz|*.bz2|*.zst|*.xz) _dfk_name="${_dfk_name%.*}" ;;
    esac
    case "$_dfk_name" in
        # .geojson IS json - a FeatureCollection is one document like any
        # other, and every geoportal on earth exports under that name. Without
        # this arm the roadworks and district files of a city open-data portal
        # were "ignored: 1 of other kinds" while the same bytes loaded when
        # renamed to .json.
        *.json|*.geojson|*.ndjson|*.jsonl) printf 'json\n' ;;
        *.parquet|*.pq)          printf 'parquet\n' ;;
        *.csv|*.tsv|*.txt)       printf 'csv\n' ;;
        *)                       printf 'unknown\n' ;;
    esac
}

# _exakit_txt_looks_tabular <path> - does this .txt hold delimited rows?
#
# A GTFS feed is eleven CSV files that are all called .txt, by specification.
# A README.txt is not a table. The difference is visible in the first two
# lines: a header with a comma, semicolon or tab in it, and a second line under
# it. That is what a folder scan asks before it decides a .txt is data.
_exakit_txt_looks_tabular() {
    _tlt_head="$(head -n 1 "$1" 2>/dev/null)"
    [ -n "$(sed -n '2p' "$1" 2>/dev/null)" ] || return 1
    case "$_tlt_head" in
        *,*|*";"*|*"$(printf '\t')"*) return 0 ;;
    esac
    return 1
}

# exakit_csv_inspect <path> - what exapump is about to be handed, looked at,
# not touched. Prints one line, "<delimiter>|<flags>": the delimiter the
# header uses (',' ';' or a tab), and flags naming what the engine will
# object to - "bom" for a byte-order mark, "crlf" for Windows line endings.
# Returns 1 for a file that holds a header and no rows.
#
# THE KIT IS A BRIDGE. It hands files to exapump and says what exapump says
# back; it does not rewrite them. That is a decision, not an omission: a kit
# that silently produced converted copies of a user's data would be loading
# something other than the file they named. So what is read from the header
# is passed on as exapump's OWN option (--delimiter), what exapump cannot take
# is named before or after the attempt, and the file goes over as it is.
#
# What exapump cannot take today, for the record: it builds its IMPORT with a
# column separator, a quote character and a skipped header row and NO row
# separator, so Exasol applies its default (LF) and a Windows-ended file
# arrives with a CR on every last field - "7.4" becomes "7.4<CR>" and fails to
# cast (ETL-3050/3051), a quoted last field fails to parse (ETL-2105). Every
# CSV written on Windows or exported from Excel or a public data portal has
# that shape. The fix is one builder call in exapump (row_separator), not a
# copy in this kit; until it lands, the failure reason below names the cause.
exakit_csv_inspect() {
    _ci_src="$1"
    case "$(printf '%s' "${_ci_src##*/}" | tr '[:upper:]' '[:lower:]')" in
        *.gz|*.bz2|*.zst|*.xz) printf ',|\n'; return 0 ;;
    esac
    _ci_cr="$(printf '\r')"; _ci_bom="$(printf '\357\273\277')"; _ci_tab="$(printf '\t')"
    _ci_head="$(head -n 1 "$_ci_src" 2>/dev/null)"
    _ci_flags=""
    case "$_ci_head" in "$_ci_bom"*) _ci_flags="bom"; _ci_head="${_ci_head#"$_ci_bom"}" ;; esac
    case "$_ci_head" in *"$_ci_cr") _ci_flags="${_ci_flags:+$_ci_flags,}crlf"; _ci_head="${_ci_head%"$_ci_cr"}" ;; esac
    # A header with nothing under it: there is no table in this file.
    [ -n "$(sed -n '2p' "$_ci_src" 2>/dev/null)" ] || return 1
    _ci_delim=","
    case "$_ci_head" in
        *,*) ;;
        *";"*)        _ci_delim=";" ;;
        *"$_ci_tab"*) _ci_delim="$_ci_tab" ;;
    esac
    printf '%s|%s\n' "$_ci_delim" "$_ci_flags"
}

# _exakit_json_tables_ready — is the add-on installed AND usable right now?
_exakit_json_tables_ready() {
    command -v json_tables_installed_version >/dev/null 2>&1 || return 1
    [ -n "$(json_tables_installed_version 2>/dev/null || true)" ] || return 1
    [ -x "${EXAKIT_JSON_TABLES_BIN:-}" ] || return 1
    return 0
}

# _exakit_json_tables_load_module — the module is sourced by the exakit CLI but
# not by the installer, and the JSON path can be reached from either.
_exakit_json_tables_load_module() {
    command -v json_tables_install >/dev/null 2>&1 && return 0
    command -v _exakit_marketplace_load_modules >/dev/null 2>&1 || return 1
    _exakit_marketplace_load_modules >/dev/null 2>&1 || true
    command -v json_tables_install >/dev/null 2>&1
}

# _exakit_json_tables_ensure - make the JSON engine usable, saying nothing.
# A JSON file is just data the user asked to load, so the engine it needs is an
# implementation detail: it installs with its output in the log, under the same
# "Loading your data" spinner as the load itself. No question is asked and no
# install STEP is announced -- but the fact that an add-on arrived is, on one
# line, once it has.
#
# Returns 0 when the engine is ready, 1 when this machine cannot have it - that
# case still speaks up, because a silent failure is worse than a loud one.
#
# ONE ATTEMPT PER RUN, AND THAT IS NOT AN OPTIMISATION. This is called per FILE,
# so a folder of ten JSON files whose engine cannot install downloaded the same
# failing wheel ten times and printed the same three lines ten times - measured
# at 95 seconds to load nothing, of which almost all was re-downloading a wheel
# that had already failed its checksum. Whatever stops the engine installing is
# the same on the second file as on the first. The memo is per-process, so the
# next `exakit data-load` tries again.
_EXAKIT_JSON_TABLES_BLOCKED=""
_exakit_json_tables_ensure() {
    _exakit_json_tables_ready && return 0
    if [ -n "$_EXAKIT_JSON_TABLES_BLOCKED" ]; then
        warn "$_EXAKIT_JSON_TABLES_BLOCKED"
        return 1
    fi

    _exakit_json_tables_load_module || {
        _EXAKIT_JSON_TABLES_BLOCKED="This kit copy does not carry the JSON engine - update the kit first: exakit update"
        warn "This kit copy does not carry the JSON engine - update the kit first: exakit update"
        return 1
    }
    if command -v _exakit_addon_applicable >/dev/null 2>&1 && \
       ! _exakit_addon_applicable json-tables; then
        _jte_why="$(_exakit_addon_applicable_reason json-tables 2>/dev/null || true)"
        _EXAKIT_JSON_TABLES_BLOCKED="JSON files need an engine that is not available on this machine${_jte_why:+: $_jte_why}"
        warn "JSON files need an engine that is not available on this machine${_jte_why:+: $_jte_why}"
        info "CSV and Parquet load without it. Convert the file, or load it from a supported machine."
        return 1
    fi
    command -v _exakit_marketplace_install_one >/dev/null 2>&1 || {
        _EXAKIT_JSON_TABLES_BLOCKED="The marketplace installer is not available in this kit build."
        warn "The marketplace installer is not available in this kit build."
        return 1
    }
    if ! _exakit_marketplace_install_one json-tables >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        _EXAKIT_JSON_TABLES_BLOCKED="The JSON engine could not be installed, so this file was not loaded (details: exakit logs setup)."
        warn "The JSON engine could not be installed, so this file was not loaded."
        info "Everything already in the database is untouched. Details: exakit logs"
        return 1
    fi
    _exakit_json_tables_ready || {
        warn "The JSON engine installed but is not usable yet - retry with: exakit data-load"
        return 1
    }
    # Said once, and only when this run actually installed it -- the early
    # readiness check above returns before reaching here, so a machine that
    # already has the add-on stays quiet.
    #
    # An add-on the reader never chose has just appeared on their machine, and
    # since an add-on's skills now install WITH it, a skill arrived too. Leaving
    # both silent asks them to discover it in `exakit marketplace` later and work
    # out where it came from. The install itself is still unannounced: this says
    # that it happened and what it is for, not what it did.
    #
    # ok_step rather than ok: the load narrates on one line, which gates plain
    # ok to the logfile, and ok_step also hands the spinner's line back before
    # printing so this lands on a row of its own.
    # Nothing on screen. This runs in the middle of a folder load, where the
    # one-line progress bar owns the row and rewrites it continuously -- the
    # line landed inside it:
    #
    #   ⠇ products.json (2/2)  ████████ 99% (7s)   ✓ JSON Tables installed — ...
    #
    # ok_step cannot help here: its ui_spin_pause looks for a SPINNER, and a
    # progress bar is a different animator holding the same line. Announcing an
    # add-on the reader did not choose was worth one line; it is not worth one
    # line printed through the middle of another. The logfile keeps it, and the
    # add-on shows as installed in `exakit marketplace` like any other.
    _exakit_log_file "OK    JSON Tables installed — the add-on that loads JSON into Exasol"
    return 0
}

# exakit_load_local_json <path> <target> - ingest a JSON file and load what
# comes out of it. The target is decided by the CALLER, before anything runs,
# so JSON asks exactly what CSV and Parquet ask: one SCHEMA.TABLE, then it
# loads. Nothing here prompts.
#
# Nested JSON legitimately yields SEVERAL tables. One table lands on <target>
# exactly; several keep <target> as their shared prefix, so the name the user
# typed still describes every table the document produced. The full list is
# left in EXAKIT_LAST_LOAD_TARGET for the caller's closing line.
exakit_load_local_json() {
    _jl_path="$1"
    _jl_target="$2"
    _jl_schema="$(exakit_target_schema "$_jl_target")"
    _jl_base="${_jl_target#*.}"

    _exakit_json_tables_ensure || return 1

    _jl_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-json-load.XXXXXX")" || {
        warn "Could not create a temporary directory for the JSON ingest."
        return 1
    }
    # THE INGEST ENGINE IS LINE-ORIENTED: it reads one complete JSON document
    # per line. A pretty-printed file - which is what almost every API, export
    # and hand-written fixture actually looks like - fails on its first line
    # with "Line 1: EOF while parsing an object", because line 1 is just "{".
    #
    # Re-flowing that onto one line changes whitespace, not data, so the kit
    # does it rather than telling someone to reformat a file it can read
    # perfectly well. A file that is ALREADY line-delimited is passed through
    # untouched; one that is not JSON at all is reported as that, instead of
    # as a parse error pointing at a line number nobody wrote.
    _jl_input="$_jl_path"
    _jl_norm="$_jl_tmp/normalised.json"
    run_python - "$_jl_path" "$_jl_norm" <<'EXAKIT_JSON_NORMALISE_PY'
import json, sys

source, target = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8-sig") as handle:
    raw = handle.read()

try:
    document = json.loads(raw)
except ValueError:
    # Not one whole document. It may already be NDJSON - every non-empty line
    # a document of its own - which is exactly what the engine wants.
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            json.loads(line)
        except ValueError:
            sys.exit(4)          # neither shape: genuinely malformed
    sys.exit(3)                  # already line-delimited, use it as it is

with open(target, "w", encoding="utf-8") as out:
    if isinstance(document, list):
        # A top-level array is a list of records: one per line.
        for item in document:
            out.write(json.dumps(item) + "\n")
    else:
        out.write(json.dumps(document) + "\n")
EXAKIT_JSON_NORMALISE_PY
    case $? in
        0) _jl_input="$_jl_norm" ;;
        3) ;;   # already NDJSON
        4) rm -rf "$_jl_tmp"
           warn "$(ui_tilde "$_jl_path") is not valid JSON."
           info "It must be one JSON document, or NDJSON with one document per line."
           info "Nothing was loaded; the database is unchanged."
           return 1 ;;
        *) ;;   # no python, or an unreadable file: let the engine have its say
    esac

    # Through _json_tables_logged so the engine's own words land in the
    # add-on's log too - the very file the failure message below points at.
    if ! run_logged _json_tables_logged "$EXAKIT_JSON_TABLES_BIN" ingest \
            --input "$_jl_input" --output-dir "$_jl_tmp/out"; then
        rm -rf "$_jl_tmp"
        warn "This JSON file could not be read - see: exakit logs json-tables"
        info "It must be one JSON document, or NDJSON with one document per line."
        info "Nothing was loaded; the database is unchanged."
        return 1
    fi

    _jl_files="$(find "$_jl_tmp/out" -name '*.parquet' 2>/dev/null | sort)"
    if [ -z "$_jl_files" ]; then
        rm -rf "$_jl_tmp"
        warn "No tables came out of $(ui_tilde "$_jl_path")."
        info "Check the file is JSON or NDJSON, then retry: exakit data-load"
        return 1
    fi
    _jl_count="$(printf '%s\n' "$_jl_files" | grep -c .)"

    exakit_ensure_schema "$_jl_schema"
    if [ "$_jl_count" -eq 1 ]; then
        exapump_upload "$_jl_files" "$_jl_target"
        exakit_verify_loaded_table "$_jl_target"
        _jl_loaded="$_jl_target"
    else
        _jl_loaded=""
        while IFS= read -r _jl_file; do
            [ -n "$_jl_file" ] || continue
            _jl_table="$_jl_schema.${_jl_base}_$(exakit_table_name_from_path "$_jl_file")"
            _jl_table="$(exakit_upper_table_target "$_jl_table")"
            exapump_upload "$_jl_file" "$_jl_table"
            exakit_verify_loaded_table "$_jl_table"
            _jl_loaded="${_jl_loaded:+$_jl_loaded, }$_jl_table"
        done <<EXAKIT_JL_EOF
$_jl_files
EXAKIT_JL_EOF
    fi
    rm -rf "$_jl_tmp"

    manifest_set data.last_load.type "local_json"
    manifest_set data.last_load.target "$_jl_loaded"
    manifest_set data.last_load.source "$_jl_path"
    EXAKIT_LAST_LOAD_TARGET="$_jl_loaded"
    return 0
}

# _llf_refuse <message> — the loader runs in a subshell whose exit code its
# callers read: 0 loaded, 2 "back"/skipped. A refusal of BAD INPUT is neither,
# so it is exit 3: the callers turn it into exit 2 for the user (the same code
# every other refusal has) without recording a failed step. `reject` could not
# be used here: its exit 2 read as "skipped" and the command exited 0.
_llf_refuse() {
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" "$*" "${UI_RESET:-}" >&2
    _exakit_log_file "REJECT $*"
    exit 3
}

exakit_load_local_file() {
    while :; do
        _raw_path="$(prompt_text "Local CSV / Parquet / JSON file — or a folder of them (type back to return)" "${EXAKIT_DATA_FILE:-}")"
        case "$_raw_path" in
            b|B|back|Back|BACK)
                info "Returning to data loading options."
                return 2
                ;;
        esac
        if [ -z "$_raw_path" ]; then
            warn "Please enter a local CSV, Parquet or JSON file, a folder of them, or type back to return."
            # No tty means prompt_text returns the same default forever, so a
            # bad or missing EXAKIT_DATA_FILE must fail instead of looping.
            [ -n "$(_exakit_prompt_tty)" ] || return 1
            continue
        fi
        _path="$(exakit_normalize_path "$_raw_path")"
        # A FOLDER is a bulk load: every data file in it, one table each. It is
        # answered by the same prompt (and the same EXAKIT_DATA_FILE) as a
        # single file, because "here is my data" is the same request either way.
        [ -d "$_path" ] && { exakit_load_local_folder "$_path"; return $?; }
        if [ -s "$_path" ]; then
            # Refuse what the loader cannot take BEFORE it runs. exapump loads
            # .csv and .parquet (JSON through the add-on); anything else died
            # inside the loader and was recorded as a failed install step,
            # although it was only the wrong file. Bad input: exit 2, no note.
            # A .tsv or .txt is data exapump refuses BY NAME; the kit says so
            # and does not rename it behind the user's back.
            _llf_kind="$(exakit_data_file_kind "$_path")"
            if [ "$_llf_kind" = csv ] && _exakit_csv_extension_refused "$_path"; then
                warn "${_path##*/} looks tabular, but exapump reads .csv and .parquet only - rename it to .csv and load that."
                [ -n "$(_exakit_prompt_tty)" ] || _llf_refuse "Cannot load '${_path##*/}': exapump reads .csv and .parquet only - rename it to .csv first."
                continue
            fi
            case "$_llf_kind" in
                unknown)
                    [ -n "$(_exakit_prompt_tty)" ] || _llf_refuse "Cannot load '${_path##*/}': only .csv and .parquet (and .json / .geojson with the JSON Tables add-on) are supported — rename or convert the file first."
                    warn "Only .csv and .parquet (and .json / .geojson with the JSON Tables add-on) can be loaded: ${_path##*/}"
                    continue ;;
            esac
            if [ "$_llf_kind" = csv ]; then
                # A header with no comma but a ';' or a tab used to be a
                # warning and a hand-typed exapump command; the delimiter is
                # read from the header now (exakit_csv_prepare), so the only
                # thing left to say is which one was found.
                _llf_head="$(head -n 1 "$_path" 2>/dev/null)"
                case "$_llf_head" in
                    *,*) ;;
                    *";"*)  info "${_path##*/} is semicolon-separated — loading it as such." ;;
                    *"	"*) info "${_path##*/} is tab-separated — loading it as such." ;;
                esac
            fi
            break
        fi
        warn "File not found or empty: $_path"
        [ -n "$(_exakit_prompt_tty)" ] || _llf_refuse "File not found or empty: $_path"
    done
    # Every file kind is asked the same two things, in the same order, before
    # any work starts: the file, then SCHEMA.TABLE. What has to happen after
    # that - an engine to install, a conversion to run - is this command's
    # problem, not the user's, so none of it reaches the screen.
    _default_table="${EXAKIT_SCHEMA:-STARTER_KIT}.$(exakit_table_name_from_path "$_path")"
    # EXAKIT_DATA_TABLE pre-answers the target the same way the path is
    # pre-answered — as the prompt's default, which a no-tty run keeps.
    [ -n "${EXAKIT_DATA_TABLE:-}" ] && _default_table="$EXAKIT_DATA_TABLE"
    while :; do
        _target="$(prompt_text "Target table (SCHEMA.TABLE, back to return)" "$_default_table")"
        case "$_target" in
            b|B|back|Back|BACK)
                info "Returning to data loading options."
                return 2
                ;;
        esac
        exakit_validate_table_target "$_target" && break
        warn "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
        [ -n "$(_exakit_prompt_tty)" ] || return 1
    done
    _target="$(exakit_upper_table_target "$_target")"

    # One label, one spinner, whatever the file turns out to need.
    EXAKIT_UPLOAD_QUIET=1
    EXAKIT_ACTIVE_LABEL="Loading your data"
    export EXAKIT_UPLOAD_QUIET EXAKIT_ACTIVE_LABEL

    if [ "$(exakit_data_file_kind "$_path")" = "json" ]; then
        EXAKIT_LAST_LOAD_TARGET=""
        exakit_load_local_json "$_path" "$_target"
        _lf_status=$?
        EXAKIT_UPLOAD_QUIET=0
        EXAKIT_ACTIVE_LABEL=""
        [ "$_lf_status" -eq 0 ] || return "$_lf_status"
        ok "Loaded $(ui_tilde "$_path") into ${EXAKIT_LAST_LOAD_TARGET:-$_target}"
        return 0
    fi
    exakit_ensure_schema "$(exakit_target_schema "$_target")"
    exapump_upload "$_path" "$_target"
    manifest_set data.last_load.type "local_file"
    manifest_set data.last_load.target "$_target"
    manifest_set data.last_load.source "$_path"
    exakit_verify_loaded_table "$_target"
    EXAKIT_UPLOAD_QUIET=0
    EXAKIT_ACTIVE_LABEL=""
    ok "Loaded $(ui_tilde "$_path") into $_target"
}

# --- bulk folder load --------------------------------------------------------
# One folder in, every data file in it loaded, one table per file. The folder is
# read at its TOP LEVEL only: subfolders are never descended into and dotfiles
# are left alone, so a directory of exports loads without dragging in a nested
# archive/, a .DS_Store, or the images sitting next to the data.

# exakit_bulk_file_kind <path> — exakit_data_file_kind, with .txt decided by
# its content.
#
# Naming one file says "this is my data, whatever it is called", and .txt is a
# reasonable CSV there. Scanning a folder says less: a README.txt or
# LICENSE.txt beside the exports is not a table, and loading one as CSV would
# be a silent surprise. But a GTFS feed - the public-transport standard - is
# eleven CSV files that are ALL called .txt, and refusing them by name left an
# extracted feed loading "0 files". So a .txt is looked at: delimited header,
# a row under it, and it is data; anything else is left alone.
exakit_bulk_file_kind() {
    case "$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')" in
        *.txt.gz|*.txt.bz2|*.txt.zst|*.txt.xz) printf 'unknown\n' ;;
        *.txt) if _exakit_txt_looks_tabular "$1"; then printf 'csv\n'; else printf 'unknown\n'; fi ;;
        *) exakit_data_file_kind "$1" ;;
    esac
}

# _exakit_csv_extension_refused <path> - exapump picks the file format from
# the extension and reads .csv and .parquet only; a .tsv or a tabular .txt is
# data it will not take BY NAME. The kit does not rename files behind the
# user's back, so these are reported with the one action that loads them.
_exakit_csv_extension_refused() {
    case "$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')" in
        *.tsv|*.txt|*.tsv.gz|*.txt.gz) return 0 ;;
    esac
    return 1
}

# exakit_bulk_scan_folder <dir> — the plan for a folder, one line per top-level
# file, in the order the files will load:
#
#   load|<kind>|<table>|<path>          kind: csv | parquet | json
#   skip|<reason>|<detail>|<path>       reason: unsupported | empty
#                                             | duplicate-content | duplicate-table
#
# For a skipped duplicate, <detail> names the file it duplicates. Two kinds of
# duplicate are refused, because both silently lose data:
#
#   * byte-identical files — the same rows would land in two tables under two
#     names, and nothing on screen would say they were the same data;
#   * two names that resolve to the SAME table (sales.csv beside sales.parquet,
#     or 2024-sales.csv beside 2024_sales.csv) — the second load would overwrite
#     the first, and only the second would be reported.
#
# The first file in alphabetical order wins. Content is compared by hash only
# between files of identical BYTE SIZE, so a folder of differently sized exports
# is never read twice just to prove they differ.
# --- load receipts -------------------------------------------------------
#
# What a repeated folder load needs to know, and could not ask anything for:
# "are the rows already in that table MINE?". exapump's upload APPENDS -- a
# folder loaded twice ends with every row in it twice, silently, which is the
# one outcome a data tool must never produce by accident. The database can say
# a table holds 1,204 rows; it cannot say they came from sales.csv. So each
# file that lands writes a line here, and a later run compares.
#
# A flat file, not the manifest: one append per file costs a printf, while a
# manifest_set costs a python start and a lock round-trip, and a forty-file
# folder would pay that forty times for bookkeeping nobody queries.
exakit_load_receipts_path() {
    printf '%s/load-receipts.tsv\n' "$EXAKIT_CACHE_DIR"
}

# exakit_load_receipt_record <SCHEMA.TABLE> <file> <rows> — remember a landing.
exakit_load_receipt_record() {
    _lrr_path="$(exakit_load_receipts_path)"
    mkdir -p "$(dirname "$_lrr_path")" 2>/dev/null || return 0
    _lrr_bytes="$(wc -c < "$2" 2>/dev/null | tr -d ' ')"
    [ -n "$_lrr_bytes" ] || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" \
        "$_lrr_bytes" "$(sha256_of "$2")" "${3:-0}" \
        "$(date +%s 2>/dev/null || echo 0)" "$(basename "$2")" \
        >> "$_lrr_path" 2>/dev/null || true
    return 0
}

# exakit_load_receipt_match <SCHEMA.TABLE> <file> — did THIS file land in THAT
# table before? Prints the remembered row count on a match.
#
# Size first, hash only on a size match: the hash of a 2 GB parquet is seconds
# of reading to answer a question that its byte count settles for free in the
# overwhelming majority of cases. Same trick the in-folder duplicate check uses.
exakit_load_receipt_match() {
    _lrm_path="$(exakit_load_receipts_path)"
    [ -f "$_lrm_path" ] || return 1
    _lrm_target="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    _lrm_bytes="$(wc -c < "$2" 2>/dev/null | tr -d ' ')"
    [ -n "$_lrm_bytes" ] || return 1
    # Newest first: a table loaded, replaced and loaded again has several lines,
    # and the last one written is the one that describes what is in there now.
    _lrm_cand="$(grep -F "$_lrm_target	$_lrm_bytes	" "$_lrm_path" 2>/dev/null | tail -1)"
    [ -n "$_lrm_cand" ] || return 1
    _lrm_have="$(printf '%s' "$_lrm_cand" | cut -f3)"
    [ "$_lrm_have" = "$(sha256_of "$2")" ] || return 1
    printf '%s\n' "$(printf '%s' "$_lrm_cand" | cut -f4)"
    return 0
}

# exakit_load_receipt_file_targets <schema> <file> — every table IN THAT SCHEMA
# this exact file has landed in, one per line.
#
# Keyed on the FILE, not the target, because one JSON file does not become one
# table: json-tables shreds a nested document into SCHEMA.<base>_<name> per
# array it finds, so the table the plan named never exists and a target-keyed
# lookup answers "nothing there" every time -- which is how a second run would
# shred the same document on top of itself.
exakit_load_receipt_file_targets() {
    _lrft_path="$(exakit_load_receipts_path)"
    [ -f "$_lrft_path" ] || return 1
    _lrft_bytes="$(wc -c < "$2" 2>/dev/null | tr -d ' ')"
    [ -n "$_lrft_bytes" ] || return 1
    # Size before hash, as everywhere else: no point reading a 2 GB file to
    # answer a question its byte count settles.
    grep -F "	$_lrft_bytes	" "$_lrft_path" 2>/dev/null | \
        grep "^$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')\." > /dev/null 2>&1 || return 1
    _lrft_sha="$(sha256_of "$2")"
    _lrft_out="$(awk -F'\t' -v pfx="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')." \
        -v sz="$_lrft_bytes" -v sha="$_lrft_sha" \
        'index($1, pfx) == 1 && $2 == sz && $3 == sha { print $1 "|" $4 }' "$_lrft_path" \
        | awk -F'|' '{ seen[$1] = $2 } END { for (t in seen) print t "|" seen[t] }')"
    [ -n "$_lrft_out" ] || return 1
    printf '%s\n' "$_lrft_out"
}

# exakit_file_already_landed <schema> <file> — has this exact file already been
# loaded into this schema, and is every table it made still holding exactly what
# it held? Prints the total rows across them.
exakit_file_already_landed() {
    _fal_rows="$(exakit_load_receipt_file_targets "$1" "$2")" || return 1
    _fal_total=0
    while IFS='|' read -r _fal_t _fal_n; do
        [ -n "$_fal_t" ] || continue
        # Every one of them, not just the first: a document that shredded into
        # four tables and lost one is a load to redo, not a load to skip.
        [ "$(exakit_table_rows_of "$_fal_t")" = "$_fal_n" ] || return 1
        _fal_total=$(( _fal_total + _fal_n ))
    done <<EXAKIT_FAL_EOF
$_fal_rows
EXAKIT_FAL_EOF
    [ "$_fal_total" -gt 0 ] || return 1
    printf '%s\n' "$_fal_total"
}

# exakit_load_receipt_forget <SCHEMA.TABLE> — drop what we remember about a
# table, because its rows have just been thrown away.
exakit_load_receipt_forget() {
    _lrf_path="$(exakit_load_receipts_path)"
    [ -f "$_lrf_path" ] || return 0
    _lrf_target="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    _lrf_tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-receipts.XXXXXX")" || return 0
    grep -v -F "$_lrf_target	" "$_lrf_path" > "$_lrf_tmp" 2>/dev/null || true
    mv "$_lrf_tmp" "$_lrf_path" 2>/dev/null || rm -f "$_lrf_tmp"
    return 0
}

exakit_bulk_scan_folder() {
    _bsf_dir="$1"
    _bsf_paths=()
    _bsf_tables=()
    _bsf_sizes=()
    _bsf_hashes=()
    _bsf_n=0
    # Byte order (LC_ALL=C), not the machine's collation: which of two
    # duplicates wins has to be the same answer on every machine, and en_US
    # folds punctuation while C does not -- so sales.csv beside sales_copy.csv
    # picked a different winner on macOS than in CI.
    _bsf_names="$(for _bsf_f in "$_bsf_dir"/*; do
        # Not a regular file: a subfolder, a broken symlink, or the unexpanded
        # glob of an empty directory.
        [ -f "$_bsf_f" ] || continue
        printf '%s\n' "${_bsf_f##*/}"
    done | LC_ALL=C sort)"
    while IFS= read -r _bsf_name; do
        [ -n "$_bsf_name" ] || continue
        _bsf_f="$_bsf_dir/$_bsf_name"
        _bsf_table="$(exakit_table_name_from_path "$_bsf_f")"
        if [ "$(exakit_bulk_file_kind "$_bsf_f")" = "unknown" ]; then
            printf 'skip|unsupported||%s\n' "$_bsf_f"
            continue
        fi
        if [ ! -s "$_bsf_f" ]; then
            printf 'skip|empty||%s\n' "$_bsf_f"
            continue
        fi
        # A CSV whose only line is its header (GTFS ships shapes.txt that way
        # when a feed has no shapes) has no table in it. Named as such, rather
        # than failing later inside exapump's schema inference.
        if [ "$(exakit_bulk_file_kind "$_bsf_f")" = csv ] && [ -z "$(sed -n '2p' "$_bsf_f" 2>/dev/null)" ]; then
            printf 'skip|header-only||%s\n' "$_bsf_f"
            continue
        fi
        if [ "$(exakit_bulk_file_kind "$_bsf_f")" = csv ] && _exakit_csv_extension_refused "$_bsf_f"; then
            printf 'skip|extension||%s\n' "$_bsf_f"
            continue
        fi
        _bsf_size="$(wc -c < "$_bsf_f" | tr -d ' ')"
        _bsf_hash=""
        _bsf_dupe=""
        _bsf_reason=""
        _bsf_i=0
        while [ "$_bsf_i" -lt "$_bsf_n" ]; do
            if [ "${_bsf_tables[$_bsf_i]}" = "$_bsf_table" ]; then
                _bsf_dupe="${_bsf_paths[$_bsf_i]}"
                _bsf_reason="duplicate-table"
                break
            fi
            if [ "${_bsf_sizes[$_bsf_i]}" = "$_bsf_size" ]; then
                [ -n "$_bsf_hash" ] || _bsf_hash="$(sha256_of "$_bsf_f")"
                if [ -z "${_bsf_hashes[$_bsf_i]}" ]; then
                    _bsf_hashes[$_bsf_i]="$(sha256_of "${_bsf_paths[$_bsf_i]}")"
                fi
                if [ "${_bsf_hashes[$_bsf_i]}" = "$_bsf_hash" ]; then
                    _bsf_dupe="${_bsf_paths[$_bsf_i]}"
                    _bsf_reason="duplicate-content"
                    break
                fi
            fi
            _bsf_i=$((_bsf_i + 1))
        done
        if [ -n "$_bsf_dupe" ]; then
            printf 'skip|%s|%s|%s\n' "$_bsf_reason" "$(basename "$_bsf_dupe")" "$_bsf_f"
            continue
        fi
        _bsf_paths[$_bsf_n]="$_bsf_f"
        _bsf_tables[$_bsf_n]="$_bsf_table"
        _bsf_sizes[$_bsf_n]="$_bsf_size"
        _bsf_hashes[$_bsf_n]="$_bsf_hash"
        _bsf_n=$((_bsf_n + 1))
        printf 'load|%s|%s|%s\n' "$(exakit_bulk_file_kind "$_bsf_f")" "$_bsf_table" "$_bsf_f"
    done <<EXAKIT_BULK_SCAN_EOF
$_bsf_names
EXAKIT_BULK_SCAN_EOF
}

# exakit_bulk_kinds_present <plan> — the loadable kinds in the plan, one per
# line, in the order the format menu shows them.
exakit_bulk_kinds_present() {
    for _bkp_kind in csv parquet json; do
        if printf '%s\n' "$1" | grep -q "^load|$_bkp_kind|"; then
            printf '%s\n' "$_bkp_kind"
        fi
    done
    return 0
}

# exakit_bulk_label <kind> — the format's name as the menu says it.
exakit_bulk_label() {
    case "$1" in
        csv)     printf 'CSV\n' ;;
        parquet) printf 'Parquet\n' ;;
        json)    printf 'JSON\n' ;;
        *)       printf '%s\n' "$1" ;;
    esac
}

# exakit_load_local_folder <dir> — load every data file in one folder.
#
# The schema is asked once, not once per file: a folder is one job, and its
# tables are named after the files (sales.csv -> SALES). Returns 2 when the user
# backs out, 1 when something failed, 0 when everything asked for was loaded.
exakit_load_local_folder() {
    _blf_dir="$1"
    _blf_plan="$(exakit_bulk_scan_folder "$_blf_dir")"

    _blf_loadable="$(printf '%s\n' "$_blf_plan" | grep -c '^load|' || true)"
    if [ "$_blf_loadable" -eq 0 ]; then
        # A GTFS feed is eleven tables all called .txt: a folder with nothing
        # exapump takes by name, and everything the user came to load. Saying
        # "no files" to that is untrue; say what is there and what loads it.
        _blf_ext="$(printf '%s\n' "$_blf_plan" | grep -c '^skip|extension|' || true)"
        if [ "$_blf_ext" -gt 0 ]; then
            warn "$(exakit_plural "$_blf_ext" file) in $(ui_tilde "$_blf_dir") are tabular but named .txt/.tsv - exapump reads .csv and .parquet only. Rename them to .csv and load the folder again."
        else
            warn "No CSV, Parquet or JSON files in $(ui_tilde "$_blf_dir")."
        fi
        info "Only the folder itself is read — subfolders and files of other kinds are left alone."
        return 1
    fi

    # EVERY loadable file, whatever its kind. A folder means "here is my data",
    # and asking which of CSV, Parquet and JSON to take is asking the reader to
    # do the sorting the kit exists to do -- for an answer that is almost always
    # "all of them". Anything unreadable is already listed as skipped with its
    # reason, so nothing disappears silently by not being asked about.
    _blf_chosen="$(printf '%s\n' "$_blf_plan" | grep '^load|' | cut -d'|' -f2-)"
    _blf_n="$(printf '%s\n' "$_blf_chosen" | grep -c '.' || true)"
    [ "$_blf_n" -gt 0 ] || { info "Nothing selected — no files were loaded."; return 2; }

    # One schema for the whole folder, asked once.
    _blf_schema="${EXAKIT_SCHEMA:-STARTER_KIT}"
    while :; do
        _blf_schema="$(prompt_text "Target schema (back to return)" "$_blf_schema")"
        case "$_blf_schema" in
            b|B|back|Back|BACK) info "Returning to data loading options."; return 2 ;;
            ""|*[!A-Za-z0-9_]*)
                warn "Schema must use letters, numbers or underscores."
                [ -n "$(_exakit_prompt_tty)" ] || return 1
                ;;
            *) break ;;
        esac
    done
    _blf_schema="$(printf '%s' "$_blf_schema" | tr '[:lower:]' '[:upper:]')"

    # No confirmation. The reader has already answered twice -- the folder, then
    # the schema -- and the plan printed above is what those two answers produced.
    # A third question asking whether they meant it turns a two-answer job into a
    # three-answer one and adds nothing: `back` at either prompt is the way out,
    # and nothing is written until the loading starts.
    exakit_bulk_print_plan "$_blf_plan" "$_blf_chosen" "$_blf_schema" "$_blf_dir"

    # Quiet BEFORE the schema call, not after: creating the schema is plumbing
    # this job needs, not a step the reader is following, and it was the one line
    # of it that escaped onto the screen.
    EXAKIT_UPLOAD_QUIET=1
    export EXAKIT_UPLOAD_QUIET
    exakit_ensure_schema "$_blf_schema"

    # BEFORE a single byte goes over: what is already in those tables? The
    # schema was just created, so the listing has to be taken after that, and
    # it is one query for the whole folder.
    exakit_clear_table_listing
    _blf_plans="$(exakit_bulk_decide "$_blf_chosen" "$_blf_schema")"
    # EXAKIT_ON_EXISTING answers the clash question without a terminal, which is
    # what a script or an agent driving this needs; an unusable value is a
    # refusal, not a silent fallback to the most destructive reading.
    case "${EXAKIT_ON_EXISTING:-}" in
        "")                  _blf_clash="$(exakit_bulk_ask_clashes "$_blf_plans" "$_blf_schema")" ;;
        skip|replace|append) _blf_clash="$EXAKIT_ON_EXISTING" ;;
        *) warn "EXAKIT_ON_EXISTING must be skip, replace or append (got '$EXAKIT_ON_EXISTING')."; return 1 ;;
    esac
    exakit_bulk_print_resume "$_blf_plans" "$_blf_clash"
    # Weighted by BYTES, like a bundled dataset: a folder is usually one big
    # export and a handful of small ones, and counting files would put the bar
    # at 90% while the only file that matters is still going.
    _blf_total_w=0
    while IFS='|' read -r _blf_k _blf_t _blf_p; do
        [ -n "$_blf_p" ] || continue
        _blf_total_w=$(( _blf_total_w + $(exakit_load_weight_of "$_blf_p") ))
    done <<EXAKIT_BULK_WEIGH_EOF
$_blf_chosen
EXAKIT_BULK_WEIGH_EOF
    _blf_done_w=0
    _blf_t0="$(date +%s 2>/dev/null || echo 0)"
    _blf_state="$(mktemp "${TMPDIR:-/tmp}/exakit-folder.XXXXXX")" || _blf_state=""
    if [ -n "$_blf_state" ]; then
        ui_progress_state "$_blf_state" 0 1 2 "reading $(exakit_plural "$_blf_n" file)"
        ui_progress_begin "$_blf_state" "$_blf_t0" || true
    fi
    _blf_done=0
    _blf_failed=0
    _blf_skipped=0
    _blf_i=0
    # Every file's fate, collected as it happens and printed as a table once the
    # bar is gone. Writing it to a file rather than a variable because the
    # reporting must survive the subshells the uploads run in.
    _blf_out="$(mktemp "${TMPDIR:-/tmp}/exakit-outcome.XXXXXX")" || _blf_out=""
    # What landed where, for the ONE listing taken after the loop. Row counts
    # and receipts both need it, and asking per file made a forty-file folder
    # pay forty round trips for bookkeeping one query answers.
    _blf_landed="$(mktemp "${TMPDIR:-/tmp}/exakit-landed.XXXXXX")" || _blf_landed="/dev/null"
    while IFS='|' read -r _blf_kind _blf_table _blf_path; do
        [ -n "$_blf_path" ] || continue
        _blf_i=$((_blf_i + 1))
        _blf_target="$_blf_schema.$_blf_table"
        _blf_w="$(exakit_load_weight_of "$_blf_path")"
        _blf_verdict="$(printf '%s\n' "$_blf_plans" | grep -F "|$_blf_path|" | head -1)"
        [ -n "$_blf_verdict" ] || _blf_verdict="load|$_blf_path|"
        _blf_act="${_blf_verdict%%|*}"
        _blf_had="${_blf_verdict##*|}"
        # Already there, put there by this very file: the whole point of the
        # exercise. Weight still counts towards the bar, or a resumed run would
        # crawl to 100% in one jump at the end.
        if [ "$_blf_act" = "done" ]; then
            _blf_skipped=$((_blf_skipped + 1))
            _blf_done_w=$(( _blf_done_w + _blf_w ))
            # Name the tables it MADE, not the one the plan guessed. A shredded
            # JSON document never produced a table called FEED, and printing one
            # sends the reader looking for it.
            _blf_show="$_blf_table"
            if [ "$_blf_kind" = json ]; then
                _blf_real="$(exakit_load_receipt_file_targets "$_blf_schema" "$_blf_path" 2>/dev/null \
                    | cut -d'|' -f1 | sed 's/^[^.]*\.//' | sort | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
                [ -n "$_blf_real" ] && _blf_show="$_blf_real"
            fi
            _exakit_log_file "SKIP  $(basename "$_blf_path") -> $_blf_show (already loaded, $_blf_had rows)"
            [ -n "$_blf_out" ] && printf 'skip\t%s\t%s\t%s\talready loaded from this file - left as it is\n' \
                "$(basename "$_blf_path")" "$_blf_show" "$(exakit_rows_label "$_blf_had")" >> "$_blf_out"
            continue
        fi
        if [ "$_blf_act" = "clash" ] && [ "$_blf_clash" = "skip" ]; then
            _blf_skipped=$((_blf_skipped + 1))
            _blf_done_w=$(( _blf_done_w + _blf_w ))
            _exakit_log_file "SKIP  $(basename "$_blf_path") -> $_blf_target (holds $_blf_had rows this kit did not load)"
            [ -n "$_blf_out" ] && printf 'skip\t%s\t%s\t%s\tnot loaded: the table already holds rows this kit did not put there\n' \
                "$(basename "$_blf_path")" "$_blf_table" "$(exakit_rows_label "$_blf_had")" >> "$_blf_out"
            continue
        fi
        # An interrupted write leaves PART of a file in the table, and a clash
        # the reader chose to replace is the same situation by consent: in both
        # the rows there are not wanted, and appending on top of them would mix
        # a half-file with a whole one.
        if [ "$_blf_act" = "resume" ] || { [ "$_blf_act" = "clash" ] && [ "$_blf_clash" = "replace" ]; }; then
            "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
                "DROP TABLE IF EXISTS $_blf_target" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || true
            exakit_load_receipt_forget "$_blf_target"
            _exakit_log_file "RESET $_blf_target dropped before reloading $(basename "$_blf_path")"
        fi
        # The bar names the file it is actually on and how far through the
        # folder it is — a forty-file load must never animate under one label.
        if [ -n "$_blf_state" ]; then
            exakit_load_step "$_blf_state" "$_blf_done_w" "$_blf_w" "$_blf_total_w" \
                "$(exakit_load_secs_for "$_blf_w")" \
                "$(basename "$_blf_path") ($_blf_i/$_blf_n)"
        fi
        # Was the table there BEFORE we touched it? A failure that leaves behind
        # a table we created and never filled is a phantom: it answers "yes" to
        # every "is it loaded?" check the kit has, while holding nothing.
        # This comes from the decision taken before the loop -- and from the DROP
        # just above, when there was one -- rather than from a fresh listing per
        # file, which on a forty-file folder was forty extra round trips.
        _blf_pre="$_blf_had"
        case "$_blf_act" in resume|clash) _blf_pre="absent" ;; esac
        exakit_load_inflight_set "$_blf_target"
        if [ "$_blf_kind" = "json" ]; then
            EXAKIT_LAST_LOAD_TARGET=""
            if exakit_load_local_json "$_blf_path" "$_blf_target"; then
                exakit_load_inflight_clear
                _blf_land="${EXAKIT_LAST_LOAD_TARGET:-$_blf_target}"
                _exakit_log_file "OK    $(basename "$_blf_path") -> $_blf_land"
                _blf_done=$((_blf_done + 1))
                _blf_done_w=$(( _blf_done_w + _blf_w ))
                # _blf_land is a COMMA-SEPARATED LIST when the document
                # shredded into several tables. The row counts are filled in
                # by ONE listing after the loop, not one per file.
                [ -n "$_blf_out" ] && printf 'ok\t%s\t%s\t@ROWS@\t\n' \
                    "$(basename "$_blf_path")" \
                    "$(printf '%s' "$_blf_land" | tr -d ' ')" >> "$_blf_out"
                printf '%s\t%s\n' "$_blf_path" "$(printf '%s' "$_blf_land" | tr -d ' ')" >> "$_blf_landed"
            else
                exakit_load_inflight_clear
                _blf_why="$(exakit_upload_failure_reason 2>/dev/null || true)"
                _blf_gone="$(exakit_drop_phantom_table "$_blf_target" "$_blf_pre")"
                _blf_failed=$((_blf_failed + 1))
                [ -n "$_blf_out" ] && printf 'fail\t%s\t%s\tnot loaded%s\t%s\n' \
                    "$(basename "$_blf_path")" "$_blf_table" "$_blf_gone" "$_blf_why" >> "$_blf_out"
            fi
            continue
        fi
        # EXAKIT_UPLOAD_SOFT keeps one unreadable file from announcing itself as
        # a failed job: this loop reports each file and carries on, so the
        # engine's own "Upload failed" banner would be the same news twice, in a
        # louder voice than the truth deserves.
        # The upload runs in a subshell, so what it learns about the file dies
        # with it; the failure reason needs the inspector's flags, so they are
        # read here, in the loop's own shell, before the attempt.
        EXAKIT_CSV_FLAGS=""
        if [ "$_blf_kind" = csv ]; then
            EXAKIT_CSV_FLAGS="$(exakit_csv_inspect "$_blf_path" 2>/dev/null | cut -d'|' -f2)"
        fi
        if ( EXAKIT_UPLOAD_SOFT=1 exapump_upload "$_blf_path" "$_blf_target" ); then
            exakit_load_inflight_clear
            _exakit_log_file "OK    $(basename "$_blf_path") -> $_blf_target"
            _blf_done=$((_blf_done + 1))
            _blf_done_w=$(( _blf_done_w + _blf_w ))
            [ -n "$_blf_out" ] && printf 'ok\t%s\t%s\t@ROWS@\t\n' \
                "$(basename "$_blf_path")" "$_blf_target" >> "$_blf_out"
            printf '%s\t%s\n' "$_blf_path" "$_blf_target" >> "$_blf_landed"
        else
            exakit_load_inflight_clear
            _blf_why="$(exakit_upload_failure_reason 2>/dev/null || true)"
            _blf_gone="$(exakit_drop_phantom_table "$_blf_target" "$_blf_pre")"
            _blf_failed=$((_blf_failed + 1))
            [ -n "$_blf_out" ] && printf 'fail\t%s\t%s\tnot loaded%s\t%s\n' \
                "$(basename "$_blf_path")" "$_blf_table" "$_blf_gone" "$_blf_why" >> "$_blf_out"
        fi
    done <<EXAKIT_BULK_LOAD_EOF
$_blf_chosen
EXAKIT_BULK_LOAD_EOF
    ui_progress_end
    [ -n "$_blf_state" ] && rm -f "$_blf_state"
    EXAKIT_UPLOAD_QUIET=0
    EXAKIT_ACTIVE_LABEL=""

    exakit_bulk_settle "$_blf_landed" "$_blf_out"
    rm -f "$_blf_landed"

    # The table, before the sentence about it. A reader who reads nothing else
    # has already been told which file went where and which one did not.
    if [ -n "$_blf_out" ]; then
        exakit_bulk_print_outcomes "$_blf_out" "$_blf_schema"
        rm -f "$_blf_out"
    fi

    manifest_set data.last_load.type "local_folder"
    manifest_set data.last_load.source "$_blf_dir"
    manifest_set data.last_load.target "$_blf_schema"
    manifest_set data.last_load.files "$_blf_done"

    # Every outcome that happened, named once, in one sentence. "Loaded 0 of 3"
    # was what a fully-resumed run used to say about a schema holding every row
    # it asked for -- a true count of a number nobody wanted, reading as total
    # failure. Each clause appears only when its count is non-zero.
    _blf_say="$(exakit_plural "$_blf_done" file) loaded"
    [ "$_blf_skipped" -gt 0 ] && _blf_say="$_blf_say, $_blf_skipped already there and left alone"
    [ "$_blf_failed" -gt 0 ] && _blf_say="$_blf_say, $_blf_failed not loaded"
    if [ "$_blf_failed" -gt 0 ]; then
        # NOT "exakit logs". That command lists the log TARGETS and shows none
        # of them, so a reader following it lands on a chooser and still does
        # not know what went wrong. Name the log that holds the answer.
        warn "$_blf_schema: $_blf_say (each file's reason is against it above; full detail: exakit logs setup)."
        return 1
    fi
    if [ "$_blf_done" -eq 0 ] && [ "$_blf_skipped" -gt 0 ]; then
        ok "$_blf_schema already holds every file in that folder — nothing to load."
        return 0
    fi
    ok "$_blf_schema: $_blf_say"
    return 0
}

# exakit_bulk_settle <landed> <outcomes> — one listing, taken once, that turns
# every "@ROWS@" in the report into a real count and writes a receipt for every
# table that took rows.
#
# The counts cannot be read as the loop goes: each one needs a fresh listing,
# and a listing is a process start, a TLS handshake and an authentication. Read
# per file, a forty-file folder spent about a hundred seconds asking the
# database questions it could answer for all forty at once.
exakit_bulk_settle() {
    [ -s "$1" ] || return 0
    exakit_clear_table_listing
    while IFS='	' read -r _bs_path _bs_targets; do
        [ -n "$_bs_targets" ] || continue
        _bs_total=0
        _bs_names=""
        _bs_rest="$_bs_targets"
        while [ -n "$_bs_rest" ]; do
            _bs_one="${_bs_rest%%,*}"
            case "$_bs_rest" in *,*) _bs_rest="${_bs_rest#*,}" ;; *) _bs_rest="" ;; esac
            [ -n "$_bs_one" ] || continue
            _bs_n="$(exakit_table_rows_of "$_bs_one")"
            case "$_bs_n" in
                ''|absent) _bs_n=0 ;;
                *) _bs_total=$(( _bs_total + _bs_n )) ;;
            esac
            # A receipt for every table it made, so a later run can tell rows it
            # put there from rows it did not.
            exakit_load_receipt_record "$_bs_one" "$_bs_path" "$_bs_n"
            _bs_names="${_bs_names:+$_bs_names, }${_bs_one#*.}"
        done
        [ -s "$2" ] || continue
        # The row this file wrote, filled in. awk over sed because a filename
        # may hold characters sed would read as part of the expression.
        _bs_tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-settle.XXXXXX")" || return 0
        awk -F'	' -v OFS='	' -v want="$(basename "$_bs_path")" -v names="$_bs_names" \
            -v rows="$(exakit_rows_label "$_bs_total")" \
            '$1 == "ok" && $2 == want && $4 == "@ROWS@" { $3 = names; $4 = rows } { print }' \
            "$2" > "$_bs_tmp" && mv "$_bs_tmp" "$2" || rm -f "$_bs_tmp"
    done < "$1"
    # Anything the listing could not answer for must not print a marker at the
    # reader. It loaded; we simply cannot say how much.
    _bs_tmp2="$(mktemp "${TMPDIR:-/tmp}/exakit-settle.XXXXXX")" || return 0
    awk -F'	' -v OFS='	' '$4 == "@ROWS@" { $4 = "" } { print }' "$2" > "$_bs_tmp2" \
        && mv "$_bs_tmp2" "$2" || rm -f "$_bs_tmp2"
    return 0
}

# exakit_rows_label <rows> — "339 rows" from a count, or "" when the database
# could not be asked. Never "0 rows" dressed up as a success.
exakit_rows_label() {
    case "${1:-}" in
        ""|absent) printf '\n' ;;
        *)         printf '%s\n' "$(exakit_plural "$1" row)" ;;
    esac
}

# exakit_drop_phantom_table <SCHEMA.TABLE> <rows-before> — clean up after a
# failed upload, and say so.
#
# exapump infers the schema and CREATES the table before it imports a single
# row, so a file the engine then refuses leaves an EMPTY TABLE standing. That
# table is worse than nothing: exakit status counts it, the schema listing
# shows it, and the next reader sees a name that promises data it does not
# have. Drop it -- but only when we are the ones who created it. A table that
# was already there is the reader's, failed import or not.
exakit_drop_phantom_table() {
    _dpt_pre="${2:-}"
    [ "$_dpt_pre" = "absent" ] || return 0
    exakit_clear_table_listing
    [ "$(exakit_table_rows_of "$1")" = "0" ] || return 0
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "DROP TABLE IF EXISTS $1" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 0
    exakit_clear_table_listing
    _exakit_log_file "CLEAN dropped empty $1 left by the failed import"
    printf ', no empty table left behind\n'
    return 0
}

# --- what a re-run must not do twice -------------------------------------

exakit_load_inflight_path() { printf '%s/load-inflight\n' "$EXAKIT_CACHE_DIR"; }

# exakit_load_inflight_set <SCHEMA.TABLE> / _clear — a crumb dropped before an
# upload and swept after it. A folder load that is killed mid-file leaves the
# target holding PART of that file and no receipt, which is indistinguishable
# from a table the reader filled themselves -- unless we said, before starting,
# that we were about to write to it. That is the whole difference between
# "resume this" and "ask before touching the reader's data".
exakit_load_inflight_set() {
    _lis_p="$(exakit_load_inflight_path)"
    mkdir -p "$(dirname "$_lis_p")" 2>/dev/null || return 0
    printf '%s\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" > "$_lis_p" 2>/dev/null || true
    return 0
}
exakit_load_inflight_clear() { rm -f "$(exakit_load_inflight_path)" 2>/dev/null || true; return 0; }
exakit_load_inflight_get() { cat "$(exakit_load_inflight_path)" 2>/dev/null || true; }

# exakit_bulk_decide <chosen> <schema> — one line per planned file:
#
#     load|<path>            nothing there, or an empty table: go
#     done|<path>|<rows>     this very file already landed there: skip it
#     resume|<path>|<rows>   we were interrupted writing this one: redo it
#     clash|<path>|<rows>    rows we cannot account for: ask before writing
#
# This is the answer to "I ran it again after it stopped". exapump's upload
# APPENDS, so without this every re-run doubles the rows of every file that had
# already made it -- no error, no warning, just twice the data.
exakit_bulk_decide() {
    _bd_chosen="$1"; _bd_schema="$2"
    _bd_inflight="$(exakit_load_inflight_get)"
    while IFS='|' read -r _bd_kind _bd_table _bd_path; do
        [ -n "$_bd_path" ] || continue
        _bd_target="$(printf '%s.%s' "$_bd_schema" "$_bd_table" | tr '[:lower:]' '[:upper:]')"
        _bd_rows="$(exakit_table_rows_of "$_bd_target")"
        case "$_bd_rows" in
            # "" is a database that could not be asked -- not an empty one. Load
            # is the honest move: refusing to load because we could not look
            # would make an unreachable listing into a failed job.
            "") printf 'load|%s|unknown\n' "$_bd_path" ;;
            absent|0)
                # The named target holds nothing -- but a JSON document does not
                # land in the table the plan named, so "nothing there" is not
                # the same as "never loaded". Ask what this FILE has landed.
                _bd_land=""
                [ "$_bd_kind" = json ] && _bd_land="$(exakit_file_already_landed "$_bd_schema" "$_bd_path" 2>/dev/null || true)"
                if [ -n "$_bd_land" ]; then
                    printf 'done|%s|%s\n' "$_bd_path" "$_bd_land"
                else
                    # The row count travels with the verdict. Whether the table
                    # was THERE before the upload decides whether an empty one
                    # left behind afterwards is ours to drop, and asking the
                    # database again per file costs a listing per file.
                    printf 'load|%s|%s\n' "$_bd_path" "$_bd_rows"
                fi
                ;;
            *)
                _bd_seen="$(exakit_load_receipt_match "$_bd_target" "$_bd_path" 2>/dev/null || true)"
                # The receipt alone is not enough. It says what WE put there;
                # the table can have been dropped and rebuilt, truncated, or
                # added to since, and a receipt that outlives its rows would
                # skip a file the schema no longer holds. The remembered count
                # has to still be the count -- anything else is a table we can
                # no longer account for, which is a question, not an assumption.
                if [ -n "$_bd_seen" ] && [ "$_bd_seen" = "$_bd_rows" ]; then
                    printf 'done|%s|%s\n' "$_bd_path" "$_bd_rows"
                elif [ "$_bd_inflight" = "$_bd_target" ]; then
                    printf 'resume|%s|%s\n' "$_bd_path" "$_bd_rows"
                else
                    printf 'clash|%s|%s\n' "$_bd_path" "$_bd_rows"
                fi
                ;;
        esac
    done <<EXAKIT_BULK_DECIDE_EOF
$_bd_chosen
EXAKIT_BULK_DECIDE_EOF
}

# exakit_bulk_ask_clashes <decisions> <schema> — what to do about target tables
# that already hold rows this kit did not put there. Asked ONCE for the whole
# set, not once per file: eight files into a schema someone has been using is
# one decision, and asking it eight times is how a reader ends up answering
# "yes" to the one they meant to refuse.
#
# Skip is the default, and the default on a pipe. Appending by accident is
# unrecoverable without knowing which rows were new; skipping costs a re-run.
exakit_bulk_ask_clashes() {
    _bac_n="$(printf '%s\n' "$1" | grep -c '^clash|' || true)"
    [ "$_bac_n" -gt 0 ] || { printf 'skip\n'; return 0; }
    # EVERY line of this goes to stderr, and only the answer to stdout. The
    # caller reads this function through $(...), so a list printed on stdout
    # does not appear on screen -- it becomes part of the answer, which then
    # matches none of the three cases and silently falls through to appending.
    # Exactly what prompt_text does, and for the same reason.
    printf '\n' >&2
    warn "$(exakit_plural "$_bac_n" table) in $2 already holding rows this kit did not load:"
    printf '%s\n' "$1" | grep '^clash|' | while IFS='|' read -r _bac_v _bac_p _bac_r; do
        printf '      %s%s%s %s %s->%s %s already\n' \
            "${UI_DIM:-}" "${UI_BULLET:--}" "${UI_RESET:-}" \
            "$(basename "$_bac_p")" "${UI_DIM:-}" "${UI_RESET:-}" "$(exakit_rows_label "$_bac_r")" >&2
    done
    if [ -z "$(_exakit_prompt_tty)" ]; then
        # info writes to stdout, and stdout here is the answer. >&2 or the
        # sentence becomes part of it.
        info "Skipping those files. Re-run with EXAKIT_ON_EXISTING=replace or =append to decide otherwise." >&2
        printf 'skip\n'; return 0
    fi
    while :; do
        case "$(prompt_text 'Those files: (s)kip, (r)eplace what is there, or (a)ppend to it' 's')" in
            s|S|skip|Skip|SKIP)          printf 'skip\n'; return 0 ;;
            r|R|replace|Replace|REPLACE) printf 'replace\n'; return 0 ;;
            a|A|append|Append|APPEND)    printf 'append\n'; return 0 ;;
            *) warn "Answer s, r or a." ;;
        esac
    done
}

# exakit_bulk_print_resume <decisions> <clash-answer> — said BEFORE the bar
# starts, because "why is it only loading three of my eight files?" is a
# question a reader should never have to ask a progress bar.
exakit_bulk_print_resume() {
    _bpr_done="$(printf '%s\n' "$1" | grep -c '^done|' || true)"
    _bpr_res="$(printf '%s\n' "$1" | grep -c '^resume|' || true)"
    if [ "$_bpr_done" -gt 0 ]; then
        info "$(exakit_plural "$_bpr_done" file) already loaded from this folder — skipping $([ "$_bpr_done" = 1 ] && echo it || echo them)."
    fi
    if [ "$_bpr_res" -gt 0 ]; then
        info "$(exakit_plural "$_bpr_res" file) was left half-loaded by an interrupted run — reloading from scratch."
    fi
    case "$2" in
        replace) info "Replacing what is in the tables that already held rows." ;;
        append)  warn "Appending to the tables that already held rows — those rows stay, and these go on top." ;;
    esac
    return 0
}

# exakit_bulk_print_outcomes <outcomes-file> <schema> — what happened, per file,
# on screen, after the bar has gone.
#
# The count alone ("Loaded 7 of 8") does not say WHICH seven, and the one line
# that named the failure was printed INSIDE a live progress bar forty lines
# earlier. A reader who looks away for the ten seconds that matters is left
# with a number and a pointer to a log. This is the table they actually needed.
exakit_bulk_print_outcomes() {
    [ -s "$1" ] || return 0
    # ONE width for the name column and ONE for the mark, measured from what is
    # actually in this table. The marks are not all the same length without
    # colour ("[ok]", "[x]", "-"), and padding only the names put every target
    # in a different column -- a list whose whole job is to be scanned down.
    _bpo_mok="${UI_TICK:-[ok]}"; _bpo_msk="${UI_BULLET:--}"; _bpo_mfl="${UI_CROSS:-[x]}"
    _bpo_mw=${#_bpo_mok}
    [ ${#_bpo_msk} -gt "$_bpo_mw" ] && _bpo_mw=${#_bpo_msk}
    [ ${#_bpo_mfl} -gt "$_bpo_mw" ] && _bpo_mw=${#_bpo_mfl}
    _bpo_w=0
    while IFS='	' read -r _bpo_s _bpo_f _bpo_t _bpo_r _bpo_why; do
        [ -n "$_bpo_f" ] || continue
        [ ${#_bpo_f} -gt "$_bpo_w" ] && _bpo_w=${#_bpo_f}
    done < "$1"
    [ "$_bpo_w" -gt 44 ] && _bpo_w=44
    printf '\n'
    [ -n "$2" ] && printf '   %sinto %s%s\n' "${UI_DIM:-}" "$2" "${UI_RESET:-}"
    while IFS='	' read -r _bpo_s _bpo_f _bpo_t _bpo_r _bpo_why; do
        [ -n "$_bpo_f" ] || continue
        case "$_bpo_s" in
            ok)   _bpo_plain="$_bpo_mok"; _bpo_mark="${UI_OK:-}$_bpo_mok${UI_RESET:-}" ;;
            skip) _bpo_plain="$_bpo_msk"; _bpo_mark="${UI_DIM:-}$_bpo_msk${UI_RESET:-}" ;;
            *)    _bpo_plain="$_bpo_mfl"; _bpo_mark="${UI_ERR:-}$_bpo_mfl${UI_RESET:-}" ;;
        esac
        printf '   %s%*s %-*s %s->%s %s  %s\n' \
            "$_bpo_mark" "$(( _bpo_mw - ${#_bpo_plain} ))" '' \
            "$_bpo_w" "$_bpo_f" "${UI_DIM:-}" "${UI_RESET:-}" \
            "$_bpo_t" "$_bpo_r"
        # The reason under the row it belongs to, not forty lines up the screen
        # inside a progress bar that has since been overwritten.
        [ -n "$_bpo_why" ] && printf '     %s%s%s\n' "${UI_DIM:-}" "$_bpo_why" "${UI_RESET:-}"
    done < "$1"
    printf '\n'
    return 0
}

# exakit_plural <n> <noun> — "1 file", "2 files". The kit wrote "file(s)" in
# nine places, which is a form nobody says out loud and which reads as unfinished
# on the only count that is ever common: one.
exakit_plural() {
    if [ "$1" = "1" ]; then printf '%s %s\n' "$1" "$2"; else printf '%s %ss\n' "$1" "$2"; fi
}

# exakit_bulk_print_plan <plan> <chosen> <schema> <dir> — what is about to
# happen, and what will not. Duplicates are named one by one, because being
# skipped is a surprise worth explaining; files of other kinds are counted,
# because a folder of exports beside two hundred images should not print two
# hundred lines.
exakit_bulk_print_plan() {
    # No header line. The confirm below names the count, the schema and the
    # folder in one sentence, so a line above the list saying the same three
    # things was the plan introducing itself.
    printf '%s\n' "$2" | while IFS='|' read -r _bpp_kind _bpp_table _bpp_path; do
        [ -n "$_bpp_path" ] || continue
        # Table name only. The schema is the same for every row and is said
        # once, in the question underneath -- repeating it per file made the
        # busiest column the one carrying the least information.
        printf '      %s%s%s %s %s->%s %s\n' \
            "${UI_DIM:-}" "${UI_BULLET:--}" "${UI_RESET:-}" \
            "$(basename "$_bpp_path")" "${UI_DIM:-}" "${UI_RESET:-}" "$_bpp_table"
    done
    printf '%s\n' "$1" | grep '^skip|duplicate' | while IFS='|' read -r _bpp_v _bpp_reason _bpp_of _bpp_path; do
        case "$_bpp_reason" in
            duplicate-content) _bpp_why="identical to $_bpp_of" ;;
            *)                 _bpp_why="same target table as $_bpp_of" ;;
        esac
        printf '      %s! %s skipped (%s)%s\n' \
            "${UI_DIM:-}" "$(basename "$_bpp_path")" "$_bpp_why" "${UI_RESET:-}"
    done
    # The two counts on ONE line when both happen, and each with its own
    # plural. Two near-identical sentences stacked under a three-file plan was
    # more lines about what is NOT being loaded than about what is.
    _bpp_other="$(printf '%s\n' "$1" | grep -c '^skip|unsupported|' || true)"
    _bpp_empty="$(printf '%s\n' "$1" | grep -c '^skip|empty|' || true)"
    _bpp_hdr="$(printf '%s\n' "$1" | grep -c '^skip|header-only|' || true)"
    _bpp_ig=""
    [ "$_bpp_other" -gt 0 ] && _bpp_ig="$_bpp_other of other kinds"
    [ "$_bpp_empty" -gt 0 ] && _bpp_ig="${_bpp_ig:+$_bpp_ig, }$_bpp_empty empty"
    [ "$_bpp_hdr" -gt 0 ] && _bpp_ig="${_bpp_ig:+$_bpp_ig, }$_bpp_hdr with a header and no rows"
    # Not folded into "ignored": these hold data, and one rename loads them.
    _bpp_ext="$(printf '%s\n' "$1" | grep -c '^skip|extension|' || true)"
    [ "$_bpp_ext" -gt 0 ] && printf '      %s! %s tabular but named .txt/.tsv - exapump reads .csv and .parquet only; rename to .csv to load%s\n' \
        "${UI_DIM:-}" "$(exakit_plural "$_bpp_ext" file)" "${UI_RESET:-}"
    [ -n "$_bpp_ig" ] && printf '      %signored: %s%s\n' \
        "${UI_DIM:-}" "$_bpp_ig" "${UI_RESET:-}"
    return 0
}

exakit_load_remote_file() {
    _url="$(prompt_text "Remote CSV / Parquet / JSON URL")"
    [ -n "$_url" ] || die "Remote URL is required."
    _name="$(basename "${_url%%\?*}")"
    [ -n "$_name" ] || _name="remote-data.csv"
    # Same two questions as a local file, asked before the download starts.
    _default_table="${EXAKIT_SCHEMA:-STARTER_KIT}.$(exakit_table_name_from_path "$_name")"
    _target="$(prompt_text "Target table (SCHEMA.TABLE)" "$_default_table")"
    exakit_validate_table_target "$_target" || die "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    _target="$(exakit_upper_table_target "$_target")"

    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/exakit-remote-data.XXXXXX")" || die "Could not create a temporary download directory."
    _tmp_file="$_tmp_dir/$_name"

    # The download is part of "loading your data", not a step of its own: the
    # spinner carries it under the same label as everything after it.
    EXAKIT_UPLOAD_QUIET=1
    EXAKIT_ACTIVE_LABEL="Loading your data"
    export EXAKIT_UPLOAD_QUIET EXAKIT_ACTIVE_LABEL
    fetch "$_url" "$_tmp_file"

    if [ "$(exakit_data_file_kind "$_tmp_file")" = "json" ]; then
        EXAKIT_LAST_LOAD_TARGET=""
        exakit_load_local_json "$_tmp_file" "$_target"
        _rf_status=$?
        rm -rf "$_tmp_dir"
        EXAKIT_UPLOAD_QUIET=0
        EXAKIT_ACTIVE_LABEL=""
        [ "$_rf_status" -eq 0 ] || return "$_rf_status"
        manifest_set data.last_load.type "remote_file"
        manifest_set data.last_load.source "$_url"
        ok "Loaded $_url into ${EXAKIT_LAST_LOAD_TARGET:-$_target}"
        return 0
    fi
    exakit_ensure_schema "$(exakit_target_schema "$_target")"
    exapump_upload "$_tmp_file" "$_target"
    rm -rf "$_tmp_dir"
    manifest_set data.last_load.type "remote_file"
    manifest_set data.last_load.target "$_target"
    manifest_set data.last_load.source "$_url"
    exakit_verify_loaded_table "$_target"
    EXAKIT_UPLOAD_QUIET=0
    EXAKIT_ACTIVE_LABEL=""
    ok "Loaded $_url into $_target"
}

exakit_run_sql_script() {
    _raw_path="$(prompt_text "SQL script path")"
    _path="$(exakit_normalize_path "$_raw_path")"
    [ -s "$_path" ] || die "SQL script not found or empty: $_path"
    exapump_run_sql_file "$_path" "SQL script ($(basename "$_path"))"
    manifest_set data.last_load.type "sql_script"
    manifest_set data.last_load.source "$_path"
    exakit_prompt_optional_verification ""
    ok "SQL script completed"
}

# --- bundled dataset registry ------------------------------------------------
# The kit can ship any number of bundled datasets. TPC-H is the original one
# (flat layout: data/*.csv + sql/0*.sql, loaded by exakit_load_sample_data);
# every additional dataset is a self-contained directory:
#
#   data/datasets/<id>/dataset.conf      id=, label=, markers= (see below)
#   data/datasets/<id>/01_create_schema.sql
#   data/datasets/<id>/data/*.csv        optional bulk files (table = filename)
#   data/datasets/<id>/02_load_data.sql  optional transform/generation step
#   data/datasets/<id>/03_verify_setup.sql  optional checks (a FAIL row blocks)
#
# Each bundled dataset loads into its own schema (schema= in dataset.conf,
# default the id uppercased — e.g. TPCH, ENERGY, WEATHER) so its tables stay
# grouped in the AI client; the MCP read-only user has database-wide read
# (USE ANY SCHEMA + SELECT ANY TABLE — see exakit_configure_mcp_readonly_access)
# so it sees every dataset schema with no per-schema grant. "markers" names the
# dataset's tables used to answer "is this loaded?" against the DATABASE (in
# that schema), not just the manifest.

# exakit_bundled_datasets — one line per dataset: "id|label|flag|markers|schema".
# Every dataset (TPC-H included) lives under data/datasets/<id>/ and is
# discovered from its dataset.conf; nothing is hardcoded here. A conf may set
# flag= to override the default manifest key (TPC-H keeps the historical
# data.loaded so existing installs stay recognized) and schema= to name the
# schema it loads into (default: the id, uppercased).
# Read one key from a dataset.conf. The trailing-CR strip matters: a kit
# copied from a Windows checkout can carry CRLF confs, and a CR-suffixed id
# makes every dataset "Unknown" (gitattributes now pins these to LF, but a
# pre-existing checkout keeps its old line endings).
_exakit_dataset_conf_get() {
    sed -n "s/^$1=//p" "$2" | head -1 | tr -d '\r'
}


exakit_bundled_datasets() {
    _bdr_root="$(exakit_repo_root 2>/dev/null)" || return 0
    for _bdr_conf in "$_bdr_root"/data/datasets/*/dataset.conf; do
        [ -f "$_bdr_conf" ] || continue
        _bdr_id="$(_exakit_dataset_conf_get id "$_bdr_conf")"
        _bdr_label="$(_exakit_dataset_conf_get label "$_bdr_conf")"
        _bdr_markers="$(_exakit_dataset_conf_get markers "$_bdr_conf")"
        _bdr_flag="$(_exakit_dataset_conf_get flag "$_bdr_conf")"
        _bdr_order="$(_exakit_dataset_conf_get order "$_bdr_conf")"
        _bdr_schema="$(_exakit_dataset_conf_get schema "$_bdr_conf")"
        [ -n "$_bdr_id" ] && [ -n "$_bdr_label" ] || continue
        [ -n "$_bdr_flag" ] || _bdr_flag="data.datasets.${_bdr_id}.loaded"
        [ -n "$_bdr_schema" ] || _bdr_schema="$(printf '%s' "$_bdr_id" | tr '[:lower:]' '[:upper:]')"
        case "$_bdr_order" in ''|*[!0-9]*) _bdr_order=50 ;; esac
        printf '%s|%s|%s|%s|%s|%s\n' "$_bdr_order" "$_bdr_id" "$_bdr_label" "$_bdr_flag" "$_bdr_markers" "$_bdr_schema"
    done | sort -t'|' -n -k1,1 | cut -d'|' -f2-
}

# exakit_db_reachable — can we run SQL right now?
#
# ONLY A "YES" IS CACHED. Caching the "no" too is what let one installer run
# report a full database while looking at an empty one: the probe ran before
# the runtime step, the deployment was down (or being replaced), and the 0 that
# answer left behind was still there when the data step asked afterwards. Every
# dataset then fell through to the manifest flag and printed "already loaded"
# against a database with no schemas in it — and the run exited 0.
#
# A "yes" cannot go stale the same way: nothing in a kit run takes the database
# down without going through personal_stop, and that calls
# exakit_forget_db_reachable. A "no" can go stale on any run that starts or
# deploys one, so it is re-probed. The cost is one refused local connection per
# ask, and exakit_dataset_loaded is the only caller.
_EXAKIT_DB_REACHABLE=""
exakit_db_reachable() {
    if [ "$_EXAKIT_DB_REACHABLE" != 1 ]; then
        if [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] && \
           "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "SELECT 1" >/dev/null 2>&1; then
            _EXAKIT_DB_REACHABLE=1
        else
            _EXAKIT_DB_REACHABLE=0
        fi
    fi
    [ "$_EXAKIT_DB_REACHABLE" = 1 ]
}

# exakit_forget_db_reachable — drop the cached "yes" after the kit itself takes
# the database down, so a later check re-probes instead of trusting a state that
# this run has just ended.
exakit_forget_db_reachable() {
    _EXAKIT_DB_REACHABLE=""
    return 0
}

# exakit_table_present <table> [schema] — does the table exist in the given
# schema (default STARTER_KIT / $EXAKIT_SCHEMA)?
exakit_table_present() {
    _tp_schema="$(printf '%s' "${2:-${EXAKIT_SCHEMA:-STARTER_KIT}}" | tr '[:lower:]' '[:upper:]')"
    _tp_table="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    [ -n "$_tp_table" ] || return 1
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = '$_tp_schema' AND TABLE_NAME = '$_tp_table') THEN 'EXAKIT_TABLE_PRESENT' ELSE 'EXAKIT_TABLE_MISSING' END AS STATUS" \
        2>> "${EXAKIT_LOG_FILE:-/dev/null}" | grep -q "EXAKIT_TABLE_PRESENT"
}

# _exakit_sync_dataset_flag <key> <true|false> — write one manifest flag only
# when it disagrees with what was observed. Split out because a dataset has TWO
# keys to keep honest, not one (see exakit_dataset_loaded).
_exakit_sync_dataset_flag() {
    [ -n "$1" ] || return 0
    [ "$(manifest_get "$1" 2>/dev/null)" = "$2" ] || manifest_set "$1" "$2"
    return 0
}

# exakit_dataset_loaded <flag> <markers_csv> [schema] [id] — is the dataset
# actually loaded? The DATABASE is the source of truth: when it is reachable,
# every marker table must exist in the dataset's schema, and BOTH manifest keys
# are synced to what was observed, so a destroy+redeploy that left a stale
# "loaded" flag self-heals. Only when the database is unreachable do we fall
# back to the manifest.
#
# TWO KEYS, on purpose. A dataset.conf may set flag= to override the manifest
# key (TPC-H keeps the historical data.loaded so older installs stay
# recognized), while `exakit status` reads the canonical
# data.datasets.<id>.loaded for every dataset alike. Syncing only the override
# is what let `exakit status --json` keep listing tpch as loaded against a
# database with no schemas in it, long after this function had observed the
# tables were gone and healed the other key. Whichever key the caller names,
# the canonical one is written too.
# exakit_table_listing — every table THAT HOLDS ROWS as SCHEMA.TABLE, one per
# line, from ONE query. Cached for the shell and cleared by
# exakit_clear_table_listing once a dataset has landed, so nothing reads a
# listing taken before its own tables existed.
#
# Rows, not existence. A dataset's DDL creates its tables before a single file
# is uploaded, so an upload that failed left eight empty tables that the marker
# check counted as "loaded": exakit data-load then answered "already loaded -
# nothing to do" over ORDERS and PART with 0 rows in them (Windows, the
# database fetching two of eight files over a NAT that cut them off). A marker
# table with no rows is a dataset that did not land. TABLE_ROW_COUNT is exact
# in EXA_ALL_TABLES (checked against COUNT(*) on a real database), and the
# sentinel row keeps a database whose every table is empty apart from one
# that could not be asked - which is what an empty answer means below.
# ONE query answers both questions. "Does this table exist?" and "how many rows
# has it?" used to be a listing of the non-empty tables plus a probe per table,
# and the difference between the two answers is the whole bug a folder load ran
# into: a table that EXISTS WITH NO ROWS is not absent and is not loaded, and
# reporting it as either one is what let a failed upload pass for a loaded one.
# So the query carries the count and drops the WHERE, and the rows>0 listing the
# dataset checks want is derived from it rather than fetched again.
EXAKIT_TABLE_ROWS=""
EXAKIT_TABLE_ROWS_READ=0

exakit_clear_table_listing() {
    EXAKIT_TABLE_ROWS=""
    EXAKIT_TABLE_ROWS_READ=0
}

# exakit_table_rows_listing — "SCHEMA.TABLE|ROWS" for EVERY table, one per line.
# Empty output means the database could not be ASKED; the sentinel row is what
# separates that from a database that genuinely holds nothing. The sentinel
# carries |1, not |0, ON PURPOSE: exakit_table_listing below filters the
# zero-row tables out, and a |0 sentinel would be filtered with them - handing
# every caller an empty listing, which they all read as "unreachable", on a
# database whose tables merely happen to be empty.
exakit_table_rows_listing() {
    if [ "$EXAKIT_TABLE_ROWS_READ" != "1" ]; then
        EXAKIT_TABLE_ROWS="$("$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
            "SELECT 'EXAKIT.LISTING_ANSWERED|1' AS QUALIFIED FROM DUAL UNION ALL SELECT TABLE_SCHEMA || '.' || TABLE_NAME || '|' || TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES" 2>/dev/null | \
            grep -oE '^[A-Za-z0-9_$]+\.[A-Za-z0-9_$]+\|[0-9]+$' | tr '[:lower:]' '[:upper:]')"
        EXAKIT_TABLE_ROWS_READ=1
    fi
    printf '%s' "$EXAKIT_TABLE_ROWS"
}

# exakit_table_rows_of <SCHEMA.TABLE> — the row count, or "absent" when the
# table is not there, or "" when the database could not be asked. THREE
# answers, because the caller acts differently on each one.
exakit_table_rows_of() {
    _tro_want="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    _tro_all="$(exakit_table_rows_listing)"
    [ -n "$_tro_all" ] || return 0
    _tro_hit="$(printf '%s\n' "$_tro_all" | grep -F "$_tro_want|" | head -1)"
    if [ -z "$_tro_hit" ]; then printf 'absent\n'; return 0; fi
    printf '%s\n' "${_tro_hit#*|}"
}

exakit_table_listing() {
    _tl_all="$(exakit_table_rows_listing)"
    [ -n "$_tl_all" ] || return 0
    printf '%s\n' "$_tl_all" | grep -v '|0$' | cut -d'|' -f1
}

exakit_dataset_loaded() {
    _dl_flag="$1"
    _dl_markers="$(printf '%s' "$2" | tr ',' ' ')"
    _dl_schema="$3"
    _dl_id="${4:-}"
    _dl_canonical=""
    [ -n "$_dl_id" ] && _dl_canonical="data.datasets.${_dl_id}.loaded"
    [ "$_dl_canonical" = "$_dl_flag" ] && _dl_canonical=""
    # ONE LISTING, NOT A REACHABILITY PROBE PLUS A QUERY PER MARKER. This used
    # to call exakit_db_reachable (a SELECT 1) and then one EXA_ALL_TABLES
    # query PER MARKER TABLE - eight exapump launches across the three bundled
    # datasets, each a process start, a TLS handshake and an authentication.
    # exakit_verified_datasets already learned this; this function was never
    # brought along. Empty output means the database could not be ASKED, not
    # that it holds nothing, so that falls through to the manifest below.
    if [ -n "$_dl_markers" ]; then
        _dl_listing="$(exakit_table_listing)"
        if [ -n "$_dl_listing" ]; then
            for _dl_table in $_dl_markers; do
                _dl_want="$(printf '%s.%s' "$_dl_schema" "$_dl_table" | tr '[:lower:]' '[:upper:]')"
                if ! printf '%s\n' "$_dl_listing" | grep -qx "$_dl_want"; then
                    _exakit_sync_dataset_flag "$_dl_flag" false
                    _exakit_sync_dataset_flag "$_dl_canonical" false
                    return 1
                fi
            done
            _exakit_sync_dataset_flag "$_dl_flag" true
            _exakit_sync_dataset_flag "$_dl_canonical" true
            return 0
        fi
    fi
    [ "$(manifest_get "$_dl_flag" 2>/dev/null)" = "true" ]
}

# exakit_pending_datasets — "id|label" lines for bundled datasets that are NOT
# loaded yet. Drives the dynamic data menus: loaded datasets are not offered.
exakit_pending_datasets() {
    exakit_bundled_datasets | while IFS='|' read -r _bd_id _bd_label _bd_flag _bd_markers _bd_schema; do
        [ -n "$_bd_id" ] || continue
        exakit_dataset_loaded "$_bd_flag" "$_bd_markers" "$_bd_schema" "$_bd_id" \
            || printf '%s|%s\n' "$_bd_id" "$_bd_label"
    done
}

# exakit_verified_datasets — the ids of bundled datasets whose marker tables are
# ACTUALLY in the database right now, one per line, and the manifest flags healed
# to match. The verifying counterpart to the manifest read in
# exakit_loaded_datasets. Returns non-zero (and prints nothing) when the database
# cannot be asked, so the caller keeps the manifest's answer instead of reporting
# an empty database.
#
# ONE query for every marker table, not one per table: this runs inside
# `exakit status`, which agents call constantly and which used to cost nothing.
# Eight round trips to answer "what data is in there?" would be a tax on the
# command's whole reason to exist.
exakit_verified_datasets() {
    exakit_db_reachable || return 1
    _vd_present="$("$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "SELECT TABLE_SCHEMA || '.' || TABLE_NAME AS QUALIFIED FROM SYS.EXA_ALL_TABLES" \
        2>/dev/null)" || return 1
    _vd_ids=""
    _vd_heal=""
    # A pipeline would put this loop in a subshell and lose both accumulators,
    # so feed the list in through a here-doc instead. bash 3.2: no process
    # substitution, no lastpipe.
    while IFS='|' read -r _vd_id _vd_label _vd_flag _vd_markers _vd_schema; do
        [ -n "$_vd_id" ] || continue
        # No markers declared means nothing to verify — keep the manifest's word
        # rather than silently demoting the dataset to "not loaded".
        if [ -z "$_vd_markers" ]; then
            [ "$(manifest_get "$_vd_flag" 2>/dev/null)" = "true" ] && \
                _vd_ids="${_vd_ids}${_vd_id}
"
            continue
        fi
        _vd_ok=1
        for _vd_table in $(printf '%s' "$_vd_markers" | tr ',' ' '); do
            printf '%s\n' "$_vd_present" \
                | grep -Fqx "$_vd_schema.$_vd_table" || { _vd_ok=0; break; }
        done
        if [ "$_vd_ok" = 1 ]; then
            _vd_ids="${_vd_ids}${_vd_id}
"
            _vd_heal="${_vd_heal}${_vd_flag}=true
data.datasets.${_vd_id}.loaded=true
"
        else
            _vd_heal="${_vd_heal}${_vd_flag}=false
data.datasets.${_vd_id}.loaded=false
"
        fi
    done <<EOF
$(exakit_bundled_datasets)
EOF
    [ -n "$_vd_heal" ] && printf '%s' "$_vd_heal" | manifest_set_many
    [ -n "$_vd_ids" ] && printf '%s' "$_vd_ids"
    return 0
}

# exakit_load_dataset <kit_root> <id> [--force] — load one bundled dataset.
exakit_load_dataset() {
    case "$2" in
        tpch) exakit_load_sample_data "$1" "${3:-}" ;;
        *) exakit_load_dataset_dir "$1" "$2" "${3:-}" ;;
    esac
}

# exakit_load_dataset_dir <kit_root> <id> [--force] — generic pipeline for a
# directory-based bundled dataset (see the layout above): schema script, bulk
# files, optional transform, optional verify, then record the manifest flag.
# Mirrors exakit_load_sample_data step-for-step so datasets behave alike.
exakit_load_dataset_dir() {
    _ld_kit_root="$1"
    _ld_id="$2"
    _ld_force="${3:-}"
    _ld_dir="$_ld_kit_root/data/datasets/$_ld_id"
    [ -d "$_ld_dir" ] || die "Unknown bundled dataset: $_ld_id (no $_ld_dir)"
    # Each dataset loads into its own schema (schema= in dataset.conf, default
    # the id uppercased) so the tables stay grouped per dataset in the AI
    # client. The dataset's SQL scripts create and OPEN that same schema.
    _ld_schema="$(_exakit_dataset_conf_get schema "$_ld_dir/dataset.conf" 2>/dev/null)"
    [ -n "$_ld_schema" ] || _ld_schema="$(printf '%s' "$_ld_id" | tr '[:lower:]' '[:upper:]')"
    # Honor a flag= override in dataset.conf (TPC-H keeps the historical
    # data.loaded key); default to the per-dataset key.
    _ld_flag="$(_exakit_dataset_conf_get flag "$_ld_dir/dataset.conf" 2>/dev/null)"
    [ -n "$_ld_flag" ] || _ld_flag="data.datasets.${_ld_id}.loaded"

    [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] || \
        die "No exapump connection profile is recorded — the exapump setup step has not completed. Re-run the installer, then retry."

    # Ask the DATABASE, not the manifest. Reading the flag directly here is what
    # let an install that had just replaced the deployment print "already
    # loaded" three times into a database with no schemas in it, and exit 0.
    # exakit_dataset_loaded re-checks the marker tables whenever the database is
    # reachable and heals both flags, so a destroy+redeploy reloads by itself.
    _ld_markers="$(_exakit_dataset_conf_get markers "$_ld_dir/dataset.conf" 2>/dev/null)"
    if [ "$_ld_force" != "--force" ] && \
       exakit_dataset_loaded "$_ld_flag" "$_ld_markers" "$_ld_schema" "$_ld_id"; then
        # "re-run" and "reload" both sound additive. The schema scripts are
        # CREATE OR REPLACE TABLE, so every table in the dataset's schema is
        # dropped and rebuilt - and the kit teaches people to work in exactly
        # those schemas (data/example-questions.md is entirely TPC-H). The word
        # for "your changes are gone" is replace.
        ok "Dataset '$_ld_id' already loaded (pass --force to REPLACE it: its tables are dropped and rebuilt)"
        return 0
    fi

    # The table already names the dataset in its own row, so announcing it again
    # would be the same fact twice — and the line would scroll the table.
    if [ "${EXAKIT_TABLE_LIVE:-0}" = 1 ]; then
        _exakit_log_file "INFO  Loading the '$_ld_id' dataset into schema $_ld_schema"
    else
        info "Loading the '$_ld_id' dataset into schema $_ld_schema"
    fi

    # ONE line for the whole dataset, not one line per file. Loading three
    # bundled datasets used to print about a hundred and thirty lines — every
    # CSV twice, every script twice, eighteen rows of verification CSV and a
    # row-count panel per dataset — and none of it is something the person
    # waiting for a database can act on.
    #
    # The steps are counted up front, so the percentage is a real fraction of
    # the work rather than a guess: the schema script, one per CSV, the load
    # statements, the verification, and the row count at the end.
    # EXAKIT_UPLOAD_QUIET silences the narration underneath; the progress line
    # IS the narration now (see _exakit_dataset_progress). Nothing is lost —
    # every suppressed line still goes to the logfile, including the per-table
    # row counts, and a FAILED verification still prints in full.
    _ld_bytes=0
    _ld_files=0
    for _ld_csv in "$_ld_dir"/data/*.csv; do
        [ -s "$_ld_csv" ] || continue
        _ld_bytes=$(( _ld_bytes + $(exakit_load_weight_of "$_ld_csv") ))
    done
    # A byteless step is worth a nominal share of the same scale, so the schema
    # script and the verification neither vanish next to fifteen megabytes of
    # lineitem nor pretend to be a twelfth of the job.
    _ld_nominal="$(exakit_load_nominal "$_ld_bytes")"
    _ld_total_w=$(( _ld_bytes + _ld_nominal + _ld_nominal ))   # + schema + row counts
    [ -s "$_ld_dir/02_load_data.sql" ]    && _ld_total_w=$(( _ld_total_w + _ld_nominal ))
    [ -s "$_ld_dir/03_verify_setup.sql" ] && _ld_total_w=$(( _ld_total_w + _ld_nominal ))
    _ld_done_w=0
    _ld_t0="$(date +%s 2>/dev/null || echo 0)"
    _ld_state="$(mktemp "${TMPDIR:-/tmp}/exakit-load.XXXXXX")" || \
        die "Could not create a temporary file for the load progress."
    # Which row of the table this dataset owns, if a table is on screen. Empty
    # means there is none, and the single-line bar takes over.
    EXAKIT_TABLE_ROW=""
    if [ "${EXAKIT_TABLE_LIVE:-0}" = 1 ]; then
        EXAKIT_TABLE_ROW="$(exakit_data_table_row "$_ld_id")"
        [ "$EXAKIT_TABLE_ROW" = "0" ] && EXAKIT_TABLE_ROW=""
    fi
    EXAKIT_UPLOAD_QUIET=1
    export EXAKIT_UPLOAD_QUIET
    exakit_load_step "$_ld_state" "$_ld_done_w" "$_ld_nominal" "$_ld_total_w" 2 \
        "$_ld_id · creating schema $_ld_schema"
    [ -n "$EXAKIT_TABLE_ROW" ] || ui_progress_begin "$_ld_state" "$_ld_t0" || true

    # Schema script is OPTIONAL: exapump infers column types and creates the
    # table itself when none exists, so a dataset can ship as bare CSVs. The
    # script exists to pin exact types/precision and primary keys. When one is
    # present, verify the DDL really landed from a fresh connection and re-run
    # the idempotent script once if not (the database can report a DDL batch
    # as applied while still stabilizing after first boot).
    if [ -s "$_ld_dir/01_create_schema.sql" ]; then
        exapump_run_sql_file "$_ld_dir/01_create_schema.sql" "$_ld_id schema (01_create_schema.sql)"
        if ! exakit_schema_present "$_ld_schema"; then
            warn "Schema $_ld_schema is not present after creation — re-running the schema script"
            exapump_run_sql_file "$_ld_dir/01_create_schema.sql" "$_ld_id schema (re-run)"
            exakit_schema_present "$_ld_schema" || \
                die "Schema $_ld_schema was reported created but does not exist. The database may still be stabilizing after first boot; wait a moment and retry: exakit data-load"
        fi
    else
        exakit_ensure_schema "$_ld_schema" || die "Could not create schema $_ld_schema."
    fi
    _ld_done_w=$(( _ld_done_w + _ld_nominal ))

    _ld_tables=""
    # Uploads run CONCURRENTLY (see exapump_upload_many). Still one launch per
    # file - what changes is how many are in flight at once, which is the only
    # lever left: exapump upload cannot target more than one table per call,
    # and the server refuses IMPORT of local files over this protocol.
    _ld_csvs=""
    for _ld_csv in "$_ld_dir"/data/*.csv; do
        [ -s "$_ld_csv" ] || continue
        _ld_table="$(basename "$_ld_csv" .csv | tr '[:lower:]' '[:upper:]')"
        _ld_tables="$_ld_tables $_ld_table"
        _ld_csvs="${_ld_csvs:+$_ld_csvs }$_ld_csv"
        _ld_files=$(( _ld_files + 1 ))
    done
    if [ -n "$_ld_csvs" ]; then
        # ONE segment for the whole upload. The files go up concurrently, so
        # there is no per-file position to report any more -- which is fine,
        # because the bytes were never the interesting part of the position.
        # They still set the PACE: the segment spans every byte of the dataset
        # and is expected to take as long as those bytes usually take, so the
        # creep moves across it instead of parking at 6% until the last wave
        # lands. The ceiling is where the upload ends, so it cannot overrun into
        # the load statements however long the waves take.
        exakit_load_step "$_ld_state" "$_ld_done_w" "$_ld_bytes" "$_ld_total_w" \
            "$(exakit_load_secs_for "$_ld_bytes")" \
            "$_ld_id · loading $_ld_files data file$([ "$_ld_files" = 1 ] || printf 's')"
        EXAKIT_PROGRESS_STATE="$_ld_state"
        EXAKIT_PROGRESS_LABEL="$_ld_id ·"
        export EXAKIT_PROGRESS_STATE EXAKIT_PROGRESS_LABEL
        exapump_upload_many "$_ld_schema" $_ld_csvs
        EXAKIT_PROGRESS_STATE=""
        [ -z "$EXAKIT_UPLOAD_FAILED" ] || \
            die "Could not load $EXAKIT_UPLOAD_FAILED. The reason: exakit logs setup. Retry this step with: exakit update"
        _ld_done_w=$(( _ld_done_w + _ld_bytes ))
    fi

    if [ -s "$_ld_dir/02_load_data.sql" ]; then
        # Thirty, not three. 02_load_data.sql is where a dataset GENERATES rows
        # (energy makes 108,000 of them), so it is the slowest thing here as
        # often as it is the fastest. Guessing long makes the bar creep slowly
        # across its share; guessing short makes it cap and wait.
        exakit_load_step "$_ld_state" "$_ld_done_w" "$_ld_nominal" "$_ld_total_w" 30 \
            "$_ld_id · running load statements"
        exapump_run_sql_file "$_ld_dir/02_load_data.sql" "$_ld_id load statements (02_load_data.sql)"
        _ld_done_w=$(( _ld_done_w + _ld_nominal ))
    fi

    if [ -s "$_ld_dir/03_verify_setup.sql" ]; then
        exakit_load_step "$_ld_state" "$_ld_done_w" "$_ld_nominal" "$_ld_total_w" 10 \
            "$_ld_id · verifying"
        _ld_verify="$(mktemp "${TMPDIR:-/tmp}/exakit-verify.XXXXXX")" || \
            die "Could not create a temporary file for verification output."
        # Not run_logged: the output is the answer, so it is captured rather than
        # logged away. No spinner either — the load's own bar is already running.
        "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" < "$_ld_dir/03_verify_setup.sql" \
            > "$_ld_verify" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"
        _ld_verify_status=$?
        # Every check goes to the logfile whatever the outcome; they reach the
        # SCREEN only when one of them failed. Eighteen rows of "OK, 0 orphaned
        # row(s)" say nothing the result line does not already say — a FAIL row
        # says everything, so that is the case worth printing.
        [ -n "${EXAKIT_LOG_FILE:-}" ] && cat "$_ld_verify" >> "$EXAKIT_LOG_FILE"
        # Grade on the STATUS column value ",FAIL," — not the bare word. The
        # verify SQL is full of the literal string (its header comment and every
        # "CASE … ELSE 'FAIL' END" clause), so matching bare FAIL would fail a
        # dataset even when every row reads OK. A real failing check emits an
        # unquoted STATUS column (check_name,FAIL,detail). Mirrors exapump.ps1.
        if [ "$_ld_verify_status" -ne 0 ] || grep -q ',FAIL,' "$_ld_verify"; then
            ui_progress_end
            rm -f "$_ld_state"
            if [ -n "$EXAKIT_TABLE_ROW" ]; then
                ui_table_set "$EXAKIT_TABLE_STATE" "$EXAKIT_TABLE_ROW" failed \
                    "" "" "" "" "failed · verification (see log)"
                # The table has to stop animating before anything is printed over
                # it, or the checks scroll under a redrawing frame.
                ui_table_end "$EXAKIT_TABLE_STATE"
                EXAKIT_TABLE_LIVE=0
                EXAKIT_TABLE_ROW=""
            fi
            EXAKIT_UPLOAD_QUIET=0
            EXAKIT_ACTIVE_LABEL=""
            error "Verification failed for dataset '$_ld_id':"
            # Printed, not streamed: exakit_stream_foreign would log these lines
            # a second time, and they are already in the logfile above.
            while IFS= read -r _ld_vline; do
                printf '      %s%s %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$_ld_vline" "${UI_RESET:-}" >&2
            done < "$_ld_verify"
            rm -f "$_ld_verify"
            die "Verification failed for dataset '$_ld_id' — see ${EXAKIT_LOG_FILE:-the log}. Data is loaded but not marked ready; fix the underlying issue and re-run with --force."
        fi
        rm -f "$_ld_verify"
    fi

    # Row-count summary over the dataset's tables: every uploaded CSV table
    # plus the conf's marker tables (covers SQL-generated tables too).
    _ld_markers="$(_exakit_dataset_conf_get markers "$_ld_dir/dataset.conf" 2>/dev/null | tr ',' ' ')"
    for _ld_marker in $_ld_markers; do
        case " $_ld_tables " in *" $_ld_marker "*) ;; *) _ld_tables="$_ld_tables $_ld_marker" ;; esac
    done
    # The per-table numbers still go to the logfile, exactly as before; what
    # changed is that they no longer take a ten-line panel on screen per
    # dataset. Their totals land in the result line instead, which is the part
    # a reader actually checks against what they expected.
    _ld_done_w=$(( _ld_done_w + _ld_nominal ))
    exakit_load_step "$_ld_state" "$_ld_done_w" "$_ld_nominal" "$_ld_total_w" 5 \
        "$_ld_id · counting rows"
    _ld_tables_n=0
    _ld_rows_total=0
    _ld_rows_known=1
    if [ -n "$_ld_tables" ]; then
        # ONE invocation for every table. exapump_count_many returns non-zero
        # unless it read them all, and an empty _ld_counts sends the loop back
        # to the per-table call - so a batch that cannot run costs correctness
        # nothing, only the speed it was meant to buy.
        _ld_counts="$(exapump_count_many "$_ld_schema" $_ld_tables 2>/dev/null)" || _ld_counts=""
        for _ld_table in $_ld_tables; do
            if [ -n "$_ld_counts" ]; then
                _ld_rows="$(printf '%s\n' "$_ld_counts" | awk -v t="$_ld_table" '$1 == t { print $2; exit }')"
            else
                _ld_rows="$(exapump_count "$_ld_schema.$_ld_table")"
            fi
            _ld_tables_n=$((_ld_tables_n + 1))
            if [ -n "$_ld_rows" ]; then
                _ld_rows_total=$((_ld_rows_total + _ld_rows))
            else
                _ld_rows_known=0
            fi
            _exakit_log_file "DATA  $(printf '%-30s %s rows' "$_ld_schema.$_ld_table" "${_ld_rows:-?}")"
        done
    fi

    manifest_set "$_ld_flag" true
    # Also record the canonical per-dataset key so data.datasets is a complete
    # map even for datasets that keep a legacy flag (TPC-H uses data.loaded for
    # backward compatibility). data.loaded is left untouched for existing installs.
    _ld_canonical="data.datasets.${_ld_id}.loaded"
    [ "$_ld_flag" = "$_ld_canonical" ] || manifest_set "$_ld_canonical" true
    # RECORDED HERE BECAUSE THEY ARE ALREADY COMPUTED for the result line
    # below. `exakit status` shows a dataset's shape without asking the
    # database at all, which is what keeps that screen instant - counting three
    # datasets live would put two more exapump launches on every status, and
    # process launches are exactly what made the old status slow.
    #
    # They describe the state AS OF THIS LOAD. Anyone who changes these tables
    # behind the kit's back will read stale numbers, which is the price of not
    # querying; `exakit data-load` rewrites them.
    manifest_set "data.datasets.${_ld_id}.schema" "$_ld_schema"
    manifest_set "data.datasets.${_ld_id}.tables" "$_ld_tables_n"
    if [ "$_ld_rows_known" = 1 ]; then
        manifest_set "data.datasets.${_ld_id}.rows" "$_ld_rows_total"
    fi
    manifest_set data.last_load.source "dataset:$_ld_id"
    # This dataset's tables exist now, so any listing taken before it is stale.
    exakit_clear_table_listing
    ui_progress_end
    rm -f "$_ld_state"
    EXAKIT_UPLOAD_QUIET=0
    EXAKIT_ACTIVE_LABEL=""
    _ld_elapsed=$(( $(date +%s 2>/dev/null || echo 0) - _ld_t0 ))
    [ "$_ld_elapsed" -ge 0 ] 2>/dev/null || _ld_elapsed=0
    _ld_result="Dataset '$_ld_id' loaded and verified"
    if [ "$_ld_tables_n" -gt 0 ]; then
        _ld_result="$_ld_result — $_ld_tables_n table$([ "$_ld_tables_n" = 1 ] || printf 's')"
        [ "$_ld_rows_known" = 1 ] && \
            _ld_result="$_ld_result, $(exakit_group_digits "$_ld_rows_total") rows"
    fi
    if [ -n "$EXAKIT_TABLE_ROW" ]; then
        # Built for the COLUMN, not for a sentence: the row already says which
        # dataset it is, so the prefix goes, and the two numbers are padded to a
        # fixed width so they line up down the table instead of wandering with
        # the length of the text in front of them.
        #
        #   completed · 8 tables, 173,745 rows  (23s)
        #   completed · 2 tables, 108,050 rows   (4s)
        #   completed · 2 tables,  10,970 rows   (2s)
        _ld_cell="completed · $_ld_tables_n table$([ "$_ld_tables_n" = 1 ] || printf 's')"
        if [ "$_ld_rows_known" = 1 ]; then
            _ld_cell="$_ld_cell, $(printf '%7s' "$(exakit_group_digits "$_ld_rows_total")") rows"
        fi
        ui_table_set "$EXAKIT_TABLE_STATE" "$EXAKIT_TABLE_ROW" done "" "" "" "" \
            "$_ld_cell $(printf '%5s' "(${_ld_elapsed}s)")"
        _exakit_log_file "OK    $_ld_result (${_ld_elapsed}s)"
        EXAKIT_TABLE_ROW=""
    else
        ok "$_ld_result (${_ld_elapsed}s)"
    fi
}

# exakit_data_load_select <final_label> — dynamic checkbox over the data
# sources, shown as a small tree with exactly three top-level choices:
#
#   Select All                      <- group row (only when any is pending)
#     [x] <each dataset not loaded yet, visible upfront and individually
#          selectable — no extra keypress needed to see what is available>
#   [ ] A local CSV / Parquet / JSON file
#   [ ] <final_label>               <- mutually exclusive opt-out (Cancel/Skip)
#
# Already-loaded datasets are not offered; when every bundled dataset is
# loaded the group disappears and only the local-file and opt-out choices
# remain. Pending datasets are pre-selected; with none pending the opt-out is
# the (safe) default, which is also what a non-interactive run keeps. The
# result lands in EXAKIT_DATA_LOAD_SELECTION as a csv of ids ("tpch",
# "local") or "none".
EXAKIT_DATA_LOAD_SELECTION=""
exakit_data_load_select() {
    _dls_final_label="$1"
    # EXAKIT_DATA_FILE mirrors the EXAKIT_DATASETS contract: naming a file IS
    # choosing "A local CSV / Parquet / JSON file", so the table never draws.
    # The path (and EXAKIT_DATA_TABLE) are consumed by exakit_load_local_file
    # as its two answers.
    if [ -n "${EXAKIT_DATA_FILE:-}" ]; then
        info "Loading a local file (EXAKIT_DATA_FILE)."
        EXAKIT_DATA_LOAD_SELECTION="local"
        return 0
    fi
    # The selection is made in the TABLE that will show the progress, so the
    # rows a reader ticks are the rows they then watch fill in. The final label
    # is a parameter for the same reason it always was: the installer's opt-out
    # reads "Skip", and so does the standalone command's.
    EXAKIT_TABLE_STATE="$(mktemp "${TMPDIR:-/tmp}/exakit-table.XXXXXX")" || {
        warn "Could not create a temporary file for the data table."
        EXAKIT_DATA_LOAD_SELECTION="none"
        return 1
    }
    exakit_data_table_build "$EXAKIT_TABLE_STATE"
    # Nothing said about the bundled datasets already being loaded. The table
    # below shows exactly what is on offer, and when they are all in it offers
    # the local-file row and Skip -- their absence IS the message. A sentence
    # explaining why the list is short, printed above the list, is the screen
    # apologising for itself. The logfile keeps the fact.
    if [ "$(exakit_data_table_row local)" = "$EXAKIT_TABLE_ROW_LOCAL" ] && \
       [ "$EXAKIT_TABLE_ROW_LOCAL" = "1" ]; then
        _exakit_log_file "INFO  Every bundled dataset is already loaded (replace with: exakit data-load --force, which drops and rebuilds their tables)."
    fi
    UI_TABLE_TITLE="Datasets to load"
    printf '\n'
    ui_table_menu "$EXAKIT_TABLE_STATE"

    EXAKIT_DATA_LOAD_SELECTION=""
    case ",$EXAKIT_TABLE_SELECTION," in
        *",$EXAKIT_TABLE_ROW_SKIP,"*)
            EXAKIT_DATA_LOAD_SELECTION="none"
            return 0
            ;;
    esac
    for _dls_row in $(printf '%s' "$EXAKIT_TABLE_SELECTION" | tr ',' ' '); do
        _dls_id="$(printf '%s\n' "$EXAKIT_TABLE_IDS" | sed -n "${_dls_row}p")"
        [ -n "$_dls_id" ] || continue
        EXAKIT_DATA_LOAD_SELECTION="${EXAKIT_DATA_LOAD_SELECTION:+$EXAKIT_DATA_LOAD_SELECTION,}$_dls_id"
    done
    [ -n "$EXAKIT_DATA_LOAD_SELECTION" ] || EXAKIT_DATA_LOAD_SELECTION="none"
    return 0
}

# Standalone `exakit data-load` menu: the dynamic dataset checkbox with a
# plain Cancel as the opt-out.
# --- the datasets table -------------------------------------------------------
# One table for the whole job: the rows you tick are the rows that fill in. See
# ui_table_* in ui.sh for the mechanism; what lives here is which rows there
# are and what their Status column says.

EXAKIT_TABLE_STATE=""
EXAKIT_TABLE_ROW_LOCAL=0
EXAKIT_TABLE_ROW_SKIP=0

# exakit_data_table_build <state-file> — write the rows, in the order they are
# drawn, and set EXAKIT_TABLE_DEFAULTS / _GROUP / _EXCLUSIVE the way the
# checkbox layer expects. Sets EXAKIT_TABLE_IDS to the dataset id per row (empty
# for the rows that are not datasets), so the loader can find its row again.
exakit_data_table_build() {
    _dtb_f="$1"
    : > "$_dtb_f"
    EXAKIT_TABLE_IDS=""
    # Via a FILE, not a space-separated list: every label has spaces in it
    # ("TPC-H retail benchmark"), and `for x in $list` would split each label
    # into a row of its own.
    _dtb_pend="$_dtb_f.pending"
    exakit_pending_datasets > "$_dtb_pend" 2>/dev/null || : > "$_dtb_pend"
    # NOT `grep -c ... || printf 0`: grep exits 1 when the count is zero, so the
    # fallback fired IN ADDITION and the count came out as "0\n0" — which every
    # later [ -gt ] then refused as a non-integer. The guard is the value, not
    # the exit code.
    _dtb_count="$(grep -c '.' "$_dtb_pend" 2>/dev/null)"
    case "$_dtb_count" in ''|*[!0-9]*) _dtb_count=0 ;; esac
    _dtb_n=0
    if [ "$_dtb_count" -gt 0 ]; then
        printf 'group|Select All|1|idle|||||| \n' >> "$_dtb_f"
        EXAKIT_TABLE_IDS="
"
        _dtb_n=1
        _dtb_i=0
        while IFS='|' read -r _dtb_id _dtb_label; do
            [ -n "$_dtb_id" ] || continue
            _dtb_i=$(( _dtb_i + 1 ))
            if [ "$_dtb_i" -eq "$_dtb_count" ]; then _dtb_kind=corner; else _dtb_kind=tee; fi
            # The label loses its trailing "(~175k rows)": the Status column
            # carries the real count when the row finishes, and an estimate
            # beside a measurement is the same fact twice, worse.
            printf '%s|%s|1|idle|||||| \n' "$_dtb_kind" \
                "$(printf '%s' "$_dtb_label" | sed 's/ *([^()]*)$//')" >> "$_dtb_f"
            EXAKIT_TABLE_IDS="$EXAKIT_TABLE_IDS$_dtb_id
"
            _dtb_n=$(( _dtb_n + 1 ))
        done < "$_dtb_pend"
        EXAKIT_TABLE_GROUP="1:2:$(( _dtb_count + 1 )):all"
        EXAKIT_TABLE_DEFAULTS=""
        _dtb_i=1
        while [ "$_dtb_i" -le $(( _dtb_count + 1 )) ]; do
            EXAKIT_TABLE_DEFAULTS="${EXAKIT_TABLE_DEFAULTS:+$EXAKIT_TABLE_DEFAULTS,}$_dtb_i"
            _dtb_i=$(( _dtb_i + 1 ))
        done
    else
        EXAKIT_TABLE_GROUP=""
        EXAKIT_TABLE_DEFAULTS=""
    fi
    rm -f "$_dtb_pend"
    printf 'plain|A local CSV / Parquet / JSON file, or a folder of them|0|idle|||||| \n' >> "$_dtb_f"
    EXAKIT_TABLE_IDS="${EXAKIT_TABLE_IDS}local
"
    _dtb_n=$(( _dtb_n + 1 ))
    EXAKIT_TABLE_ROW_LOCAL="$_dtb_n"
    printf 'plain|Skip|0|idle|||||| \n' >> "$_dtb_f"
    EXAKIT_TABLE_IDS="$EXAKIT_TABLE_IDS
"
    _dtb_n=$(( _dtb_n + 1 ))
    EXAKIT_TABLE_ROW_SKIP="$_dtb_n"
    EXAKIT_TABLE_EXCLUSIVE="$_dtb_n"
    # With every bundled dataset already loaded there is nothing to tick but the
    # local-file row, which is the only thing this screen can still do.
    [ "$_dtb_count" -gt 0 ] || EXAKIT_TABLE_DEFAULTS="$EXAKIT_TABLE_ROW_LOCAL"
    return 0
}

# exakit_data_table_row <dataset-id> — which row that dataset is on, or 0.
exakit_data_table_row() {
    _dtr_i=0
    while IFS= read -r _dtr_id; do
        _dtr_i=$(( _dtr_i + 1 ))
        [ "$_dtr_id" = "$1" ] && { printf '%s\n' "$_dtr_i"; return 0; }
    done <<EXAKIT_DTR_EOF
$EXAKIT_TABLE_IDS
EXAKIT_DTR_EOF
    printf '0\n'
}

exakit_data_load_menu() {
    [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] || \
        die "No exapump connection profile is recorded — re-run the installer, then retry."

    exakit_data_load_select "Skip"
    if [ "$EXAKIT_DATA_LOAD_SELECTION" = "none" ]; then
        info "Data loading cancelled."
        return 0
    fi
    # The same table the selection was made in now becomes the progress display:
    # the rows do not move, so nobody has to map one screen onto another. It
    # animates only where there is a terminal to animate on; everywhere else the
    # loaders narrate in plain lines exactly as they did before.
    EXAKIT_TABLE_LIVE=0
    if [ -n "$EXAKIT_TABLE_STATE" ]; then
        ui_table_begin "$EXAKIT_TABLE_STATE" && EXAKIT_TABLE_LIVE=1
    fi
    _menu_status=0
    # Every load runs in a SUBSHELL, the way the installer has always run them.
    # The loading flow is full of die() calls and die() exits: called straight
    # from here, one of them ended `exakit data-load` mid-table, with no
    # ui_table_end and the animator still running. The orphan's next frame moved
    # the cursor up and cleared, which wiped the error message off the screen and
    # repainted the half-finished table over it -- a truncated table at 99% and
    # no explanation. ui_table_detach is what keeps the subshell's exit from
    # taking this shell's animation with it.
    _menu_notes=""
    _menu_has_local=0
    EXAKIT_DEFER_ERRORS=""
    if [ "$EXAKIT_TABLE_LIVE" = 1 ]; then
        EXAKIT_DEFER_ERRORS="$EXAKIT_TABLE_STATE.fatal"
        : > "$EXAKIT_DEFER_ERRORS"
    fi
    for _menu_id in $(printf '%s' "$EXAKIT_DATA_LOAD_SELECTION" | tr ',' ' '); do
        case "$_menu_id" in
            local)
                # Deferred until the table has closed - see below. Everything
                # this row does is a QUESTION, and a question cannot be asked
                # under a frame that is still repainting itself.
                _menu_has_local=1
                ;;
            *)
                _kit_root="$(exakit_repo_root)" || _kit_root=""
                if [ -z "$_kit_root" ]; then
                    _menu_notes="${_menu_notes}warn|Could not find the kit's sql/ and data/ files to load.
"
                    _menu_status=1
                    continue
                fi
                if ! ( ui_table_detach; exakit_load_dataset "$_kit_root" "$_menu_id" ); then
                    # The row is the only place a reader looks for this, and the
                    # loader died before it could say so itself.
                    _menu_row="$(exakit_data_table_row "$_menu_id")"
                    if [ -n "$_menu_row" ] && [ "$EXAKIT_TABLE_LIVE" = 1 ]; then
                        ui_table_set "$EXAKIT_TABLE_STATE" "$_menu_row" failed \
                            "" "" "" "" "did not finish - see the log"
                    fi
                    _menu_notes="${_menu_notes}warn|Loading '$_menu_id' did not finish. Retry any time with: exakit data-load
"
                    _menu_status=1
                fi
                ;;
        esac
    done
    # The table stops animating BEFORE anything is said, or the words land inside
    # a frame that is still being repainted.
    [ "$EXAKIT_TABLE_LIVE" = 1 ] && ui_table_end "$EXAKIT_TABLE_STATE"
    EXAKIT_TABLE_LIVE=0
    # The reason a load died, said once, below the finished table.
    if [ -n "$EXAKIT_DEFER_ERRORS" ] && [ -s "$EXAKIT_DEFER_ERRORS" ]; then
        while IFS='|' read -r _mf_kind _mf_text; do
            [ -n "$_mf_text" ] || continue
            error "$_mf_text"
        done < "$EXAKIT_DEFER_ERRORS"
        rm -f "$EXAKIT_DEFER_ERRORS"
    fi
    EXAKIT_DEFER_ERRORS=""
    # The local file / folder load, now that the box is closed.
    #
    # It is the one selection made entirely of QUESTIONS -- the path, then the
    # schema -- and they were being asked while the selection table was still on
    # screen as the progress display. A prompt printed into a frame that is
    # still repainting duplicates its borders and strands it: the folder load
    # showed "Datasets to load" twice, then a third time after the question.
    #
    # Nothing is lost by closing first. This row has no per-file progress to
    # show in that table anyway: the folder load draws its own one-line bar, and
    # the datasets above have already finished and been drawn.
    if [ "$_menu_has_local" = 1 ]; then
        printf '\n'
        ( exakit_load_local_file )
        _local_status=$?
        if [ "$_local_status" -eq 2 ]; then
            _menu_notes="${_menu_notes}info|Local file load skipped. Run it any time with: exakit data-load
"
        elif [ "$_local_status" -eq 3 ]; then
            # The file was refused as bad input (message already printed): the
            # command answers like every other refusal, exit 2, nothing recorded.
            _menu_status=2
        elif [ "$_local_status" -ne 0 ]; then
            _menu_status="$_local_status"
        fi
    fi
    while IFS='|' read -r _mn_kind _mn_text; do
        [ -n "$_mn_text" ] || continue
        case "$_mn_kind" in
            warn) warn "$_mn_text" ;;
            *)    info "$_mn_text" ;;
        esac
    done <<EXAKIT_MENU_NOTES_EOF
$_menu_notes
EXAKIT_MENU_NOTES_EOF
    return "$_menu_status"
}

# exakit_load_sample_data <kit_root> [--force] — the TPC-H sample-data entry
# point, kept for its long-standing callers (setup/load-data.sh, the installer
# EXAKIT_LOAD_SAMPLE path, and `exakit data-load --force`). TPC-H now lives in
# data/datasets/tpch/ like every other bundled dataset, so this simply
# delegates to the generic directory pipeline.
exakit_load_sample_data() {
    exakit_load_dataset_dir "$1" tpch "${2:-}"
}
