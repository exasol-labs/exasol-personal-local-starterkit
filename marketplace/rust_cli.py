"""Prepare the Rust UDF tool's environment from one kit receipt on every OS."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

from runtime import AddonFailure, KitContext
from udf_bucket import locate

ROOT = Path(__file__).resolve().parent.parent


def _refusal(words: list[str], reason: str, code: int, remedy: str) -> int:
    if "--json" in words:
        print(json.dumps({"ok": False, "error": reason, "reason": reason,
                          "step": words[0] if words and words[0] in ("new", "build", "deploy") else None,
                          "language": "rust", "remedy": remedy}))
    else:
        print(f"Rust UDF: {reason}\nRun: {remedy}", file=sys.stderr)
    return code


def command(ctx: KitContext, words: list[str]) -> int:
    if len(words) < 2 or words[0] not in ("new", "build", "deploy"):
        return _refusal(words, "Use: exakit rust-udf new|build|deploy <name> [--json]", 2,
                        "exakit help rust-udf")
    if not ctx.manifest.get("components.udf_devkit.version"):
        return _refusal(words, "The UDF dev kit is not installed.", 4,
                        "exakit marketplace udf-devkit")
    env = dict(os.environ)
    env["EXAKIT_HOME"] = str(ctx.home)
    env["EXAKIT_PYX_DSN"] = str(ctx.manifest.get("runtime.dsn") or "")
    env["EXAKIT_PYX_USER"] = str(ctx.manifest.get("runtime.user") or "sys")
    env["EXAKIT_PYX_PWFILE"] = str(ctx.manifest.get("runtime.password_file") or "")
    env["EXAKIT_RUST_BUCKET_DIR"] = ""
    env["EXAKIT_RUST_UDF_ROOT"] = ""
    env["EXAKIT_RUST_LAUNCHER"] = ""
    env["EXAKIT_RUST_DEPLOYMENT"] = ""
    if words[0] == "deploy":
        deployment = (ctx.manifest.get("runtime.deployment_dir") or
                      os.environ.get("EXAKIT_PERSONAL_DEPLOY_DIR") or "")
        if deployment:
            env["EXAKIT_RUST_DEPLOYMENT"] = str(deployment)
            try:
                bucket = locate(Path(deployment), create=False)
                if bucket.directory.is_dir():
                    env["EXAKIT_RUST_BUCKET_DIR"] = str(bucket.directory)
                    env["EXAKIT_RUST_UDF_ROOT"] = bucket.udf_root
            except AddonFailure:
                # The Rust tool owns the documented container fallback and
                # its --yes gate when there is no mounted bucket directory.
                pass
        launcher = (ctx.manifest.get("components.personal.ownership_path") or
                    ctx.manifest.get("components.launcher.ownership_path") or "")
        env["EXAKIT_RUST_LAUNCHER"] = str(launcher)
    recorded = ctx.manifest.get("components.pyexasol.python")
    python = Path(recorded) if recorded and Path(recorded).is_file() else Path(sys.executable)
    try:
        return subprocess.run([str(python), str(ROOT / "setup" / "udf" / "rust_udf_tool.py"), *words],
                              env=env, check=False).returncode
    except OSError:
        return _refusal(words, "Python is needed for rust-udf.", 4, "exakit update pyexasol")


def main() -> int:
    return command(KitContext.from_environment(ROOT), sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
