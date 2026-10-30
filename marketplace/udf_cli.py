"""Python entry points for UDF Devkit commands as their legacy twins are retired."""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

from runtime import AddonFailure, KitContext
from udf_bucket import locate


def udf_file(ctx: KitContext, args: list[str]) -> int:
    if not 1 <= len(args) <= 2:
        raise AddonFailure("Name the file and, optionally, where in the bucket: exakit udf-file model.pkl models/model.pkl")
    if not ctx.manifest.get("components.udf_devkit.version"):
        raise AddonFailure("The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit")
    source = Path(args[0])
    if not source.is_file():
        raise AddonFailure(f"{source} is not a file")
    sys.path.insert(0, str(ctx.root / "setup" / "udf"))
    try:
        from udf_tool import Refused, bucket_relative

        try:
            relative = bucket_relative(args[1] if len(args) == 2 else source.name)
        except Refused as error:
            raise AddonFailure(str(error)) from error
    finally:
        sys.path.pop(0)
    deployment = ctx.manifest.get("runtime.deployment_dir") or os.environ.get("EXAKIT_PERSONAL_DEPLOY_DIR")
    if not deployment:
        raise AddonFailure("No Exasol Personal deployment is recorded; check exakit status")
    bucket = locate(Path(deployment))
    target = bucket.directory.joinpath(*relative.parts)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.parent.resolve().is_relative_to(bucket.directory.resolve()):
        raise AddonFailure(f"The target {target} leaves the BucketFS directory")
    fd, staged = tempfile.mkstemp(prefix=target.name + ".", suffix=".part", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as output, source.open("rb") as input_file:
            shutil.copyfileobj(input_file, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(staged, target)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)
    if bucket.created:
        print(f"Created the bucket folder {bucket.directory} (UDFs read it at {bucket.udf_root})")
    print(f"Copied into BucketFS: {target}")
    print(f"A UDF reads it as: {bucket.udf_root}/{relative}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    try:
        return udf_file(KitContext.from_environment(Path(__file__).resolve().parent.parent), args)
    except (AddonFailure, OSError) as error:
        print(f"udf-file: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
