#!/bin/sh
# Rust UDF command twin of rust-udf.ps1; Python owns the build/deploy rules.

cmd_rust_udf() {
    [ $# -ge 2 ] || reject "Use: exakit rust-udf new|build|deploy <name> [--json]"
    case "$1" in new|build|deploy) _rust_action="$1" ;; *) reject "Unknown rust-udf action '$1' (new, build, deploy)." ;; esac
    [ -n "$(udf_devkit_installed_version || true)" ] || _model_refuse 4 "exakit marketplace udf-devkit" "The UDF dev kit is not installed."
    _rust_bucket=""; _rust_root=""; _rust_launcher=""
    if [ "$_rust_action" = deploy ]; then
        # Python selects the container fallback when this check fails. It
        # refuses the restart unless deploy was given --yes.
        if udf_bucket_locate; then
            _rust_bucket="$UDF_BUCKET_DIR"
            _rust_root="$UDF_BUCKET_UDF_ROOT"
        fi
        _rust_launcher="$(personal_cli 2>/dev/null || true)"
    fi
    _rust_python="$(pyexasol_venv_python 2>/dev/null || true)"
    [ -x "$_rust_python" ] || _rust_python="$(command -v python3 || true)"
    [ -n "$_rust_python" ] || _model_refuse 4 "exakit update pyexasol" "Python is needed for rust-udf."
    EXAKIT_RUST_BUCKET_DIR="$_rust_bucket" EXAKIT_RUST_UDF_ROOT="$_rust_root" \
    EXAKIT_RUST_LAUNCHER="$_rust_launcher" EXAKIT_RUST_DEPLOYMENT="${EXAKIT_PERSONAL_DEPLOY_DIR:-}" \
    EXAKIT_PYX_DSN="$(manifest_get runtime.dsn 2>/dev/null || true)" \
    EXAKIT_PYX_USER="$(manifest_get runtime.user 2>/dev/null || echo sys)" \
    EXAKIT_PYX_PWFILE="$(manifest_get runtime.password_file 2>/dev/null || true)" \
        "$_rust_python" "$(exakit_repo_root)/setup/udf/rust_udf_tool.py" "$@"
}
