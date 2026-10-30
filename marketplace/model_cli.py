"""Model file commands for the UDF Devkit, using its existing Python rules."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from runtime import AddonFailure, KitContext
from udf_bucket import Bucket, locate

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "setup" / "udf"))
import model_tool  # noqa: E402


class ModelError(AddonFailure):
    def __init__(self, message: str, code: int = 2, remedy: str | None = None):
        super().__init__(message)
        self.code = code
        self.remedy = remedy


def _ready(ctx: KitContext) -> Bucket:
    if not ctx.manifest.get("components.udf_devkit.version"):
        raise ModelError("The UDF dev kit is not installed.", 4, "exakit marketplace udf-devkit")
    deployment = ctx.manifest.get("runtime.deployment_dir") or os.environ.get("EXAKIT_PERSONAL_DEPLOY_DIR")
    if not deployment:
        raise ModelError("No Exasol Personal deployment is recorded.", 3, "exakit status")
    try:
        return locate(Path(deployment))
    except AddonFailure as error:
        raise ModelError(str(error), 3, "exakit status") from error


def _record(ctx: KitContext) -> dict:
    raw = ctx.manifest.get("components.udf_devkit.models")
    if isinstance(raw, dict):
        return raw
    return model_tool.read_record(raw if isinstance(raw, str) else "")


def _arguments(args: list[str], allowed: set[str], count: int) -> tuple[list[str], set[str]]:
    options = {arg for arg in args if arg.startswith("-")}
    invalid = options - allowed
    if invalid:
        raise ModelError(f"Unknown option {sorted(invalid)[0]} (supported: {' '.join(sorted(allowed))}).")
    positional = [arg for arg in args if not arg.startswith("-")]
    if len(positional) != count:
        raise ModelError("Name exactly one model file or name." if count else "This command takes no positional argument.")
    return positional, options


def _show(doc: dict, json_mode: bool) -> None:
    if json_mode:
        print(json.dumps(doc, indent=2))


def _trust_gate(info: dict, source: str, options: set[str], json_mode: bool) -> None:
    if not info["loads_code"] or info["trusted"] or info["in_bucket"] == "same":
        return
    if "--yes" in options or "-y" in options or os.environ.get("EXAKIT_MODEL_TRUST") == "1":
        return
    remedy = f"exakit model put {source} --yes"
    reason = info.get("reason") or "no trusted provenance"
    if not json_mode and sys.stdin.isatty() and sys.stdout.isatty():
        print(f"{info['name']} is a {info['kind']} file without trusted provenance ({reason}).")
        if input("Loading a pickle runs code from the file. Continue? [y/N] ").strip().lower() in ("y", "yes"):
            return
        raise ModelError("Not confirmed; nothing was copied.", 5, remedy)
    raise ModelError(f"Loading a pickle runs code from the file, and {info['name']} carries no trusted provenance ({reason}). Nothing was copied; confirm with --yes or EXAKIT_MODEL_TRUST=1 when you trust its source.", 6, remedy)


def command(ctx: KitContext, args: list[str]) -> int:
    if not args:
        raise ModelError("Name what to do: exakit model put <file> | list | rm <name> | prune | inspect <file> | template.")
    action, *rest = args
    if action not in {"put", "inspect", "rm", "prune", "list", "template"}:
        raise ModelError(f"Unknown model command '{action}' (supported: put, list, rm, prune, inspect, template).")
    json_mode = "--json" in rest or "-j" in rest
    if action == "template":
        _arguments(rest, {"--json", "-j"}, 0)
        folder = ctx.root / "udf" / "templates"
        renderer = folder / "render.py"
        template = folder / "score_model.sql"
        if not renderer.is_file() or not template.is_file():
            raise ModelError(f"The UDF templates are missing from this kit copy ({folder}). Repair with: exakit update", 1)
        found = subprocess.run([sys.executable, str(renderer), "--placeholders"],
                               capture_output=True, text=True, check=False, timeout=15)
        if found.returncode:
            raise ModelError("The UDF template renderer did not report its placeholders.", 1)
        placeholders = found.stdout.split()
        doc = {"template": str(template), "renderer": str(renderer), "placeholders": placeholders,
               "usage": f"python3 {renderer} --help"}
        if json_mode:
            _show(doc, True)
        else:
            print(f"Scoring UDF template: {template}\nPlaceholders: {' '.join(placeholders)}")
            print(f"Fill it with: python3 {renderer} --help")
        return 0
    # Reject malformed commands before locating BucketFS: locate may create
    # the default bucket directory on a fresh deployment.
    parsed: tuple[list[str], set[str]] | None = None
    days = 30
    apply = False
    if action == "put":
        parsed = _arguments(rest, {"--replace", "--yes", "-y", "--json", "-j"}, 1)
        source = parsed[0][0]
        original = Path(source).expanduser()
        if not original.is_file():
            raise ModelError(f"{source} is not a file.")
        if original.stat().st_size > model_tool.MAX_MODEL_BYTES:
            raise ModelError(f"{source} exceeds the 500 MB model limit; nothing was copied.", 6)
    elif action in ("inspect", "rm"):
        parsed = _arguments(rest, {"--json", "-j"}, 1)
    elif action == "list":
        _arguments(rest, {"--json", "-j"}, 0)
    else:
        iterator = iter(rest)
        for word in iterator:
            if word == "--older-than":
                raw = next(iterator, "")
                if not raw.isdigit() or int(raw) < 1:
                    raise ModelError("--older-than must be a positive number of days")
                days = int(raw)
            elif word == "--yes":
                apply = True
            elif word in ("--json", "-j"):
                pass
            else:
                raise ModelError(f"Unknown option '{word}' for model prune (supported: --older-than DAYS --yes --json).")
    bucket = _ready(ctx)
    directory, root = str(bucket.directory), bucket.udf_root
    if action == "put":
        assert parsed is not None
        positional, options = parsed
        source = positional[0]
        original = Path(source).expanduser()
        # Inspect and install the same private snapshot. A file or provenance
        # sidecar changing after the trust prompt cannot change what is put.
        with tempfile.TemporaryDirectory(prefix="exakit-model-put-") as temporary:
            staged = Path(temporary) / original.name
            shutil.copy2(original, staged)
            sidecar = Path(str(original) + model_tool.SIDECAR)
            if sidecar.is_file():
                shutil.copy2(sidecar, Path(str(staged) + model_tool.SIDECAR))
            info = model_tool.inspect(str(staged), directory, str(ctx.home))
            _trust_gate(info, source, options, json_mode)
            with ctx.manifest.edit() as manifest:
                record = manifest.setdefault("components", {}).setdefault("udf_devkit", {}).get("models")
                record = record if isinstance(record, dict) else model_tool.read_record(record if isinstance(record, str) else "")
                try:
                    outcome, answer, updated = model_tool.put(str(staged), directory, root, "--replace" in options,
                                                               record, str(ctx.home))
                except model_tool.NotConfirmed as error:
                    raise ModelError(str(error), 5, f"exakit model put {source} --replace") from error
                manifest["components"]["udf_devkit"]["models"] = updated
        if json_mode:
            _show(answer, True)
        else:
            verb = {"unchanged": "already in", "replaced": "Replaced in", "copied": "Copied into"}[outcome]
            print(f"{answer['name']} {verb} the bucket directory: {bucket.directory / 'models' / answer['name']}")
            print(f"sha256 {answer['sha256']}, {answer['size']} bytes, recorded")
            print(f"A UDF reads it as: {answer['path']}")
            if answer.get("warning"):
                print(f"Warning: {answer['warning']}")
        return 0
    if action == "inspect":
        assert parsed is not None
        positional, _ = parsed
        info = model_tool.inspect(positional[0], directory, str(ctx.home))
        if json_mode:
            _show(info, True)
        else:
            print(f"{info['name']}: {info['kind']} file, {info['size']} bytes, sha256 {info['sha256']}")
            print(f"Trusted: {'yes' if info['trusted'] else 'no'} ({info['reason']})")
            print(f"In the bucket directory: {info['in_bucket']}")
            if info.get("warning"):
                print(f"Warning: {info['warning']}")
        return 0
    if action == "list":
        answer = model_tool.listing(directory, root, _record(ctx), bucket.created, bucket.mapping)
        if json_mode:
            _show(answer, True)
        else:
            print(f"Bucket directory: {directory}{' (created now)' if bucket.created else ''}")
            print(f"UDFs read it as: {root} (mapping: {bucket.mapping})")
            if not answer["models"]:
                print("No models yet. Put one with: exakit model put <file>")
            for item in answer["models"]:
                print(f"{item['name']}: {item['size']} bytes, sha256 {item['sha256'][:12]}... ({item['status']})")
                print(f"  {item['path']}")
            for name in answer["missing"]:
                print(f"{name}: recorded, but no longer in the bucket directory")
        return 0
    if action == "rm":
        assert parsed is not None
        positional, _ = parsed
        name = positional[0]
        with ctx.manifest.edit() as manifest:
            record = manifest.setdefault("components", {}).setdefault("udf_devkit", {}).get("models")
            record = record if isinstance(record, dict) else model_tool.read_record(record if isinstance(record, str) else "")
            try:
                answer, updated = model_tool.remove(name, directory, root, record)
            except model_tool.NotConfirmed as error:
                raise ModelError(str(error), 5) from error
            manifest["components"]["udf_devkit"]["models"] = updated
        if json_mode:
            _show(answer, True)
        else:
            print(f"Removed {name} from the bucket directory and the kit's record")
        return 0
    # prune
    if apply:
        with ctx.manifest.edit() as manifest:
            record = manifest.setdefault("components", {}).setdefault("udf_devkit", {}).get("models")
            record = record if isinstance(record, dict) else model_tool.read_record(record if isinstance(record, str) else "")
            answer, updated = model_tool.prune(directory, root, str(ctx.home), days, True, record)
            manifest["components"]["udf_devkit"]["models"] = updated
    else:
        answer, _ = model_tool.prune(directory, root, str(ctx.home), days, False, _record(ctx))
    if json_mode:
        _show(answer, True)
    else:
        for name in answer["candidates"]:
            print(("Removed " if apply else "Would remove ") + name)
        print("No old unreferenced models found." if not answer["candidates"] else
              "Pruned." if apply else "Dry run; pass --yes to remove these models.")
        if answer.get("mlflow"):
            print(f"({answer['mlflow']})")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    json_mode = "--json" in args or "-j" in args
    try:
        return command(KitContext.from_environment(Path(__file__).resolve().parent.parent), args)
    except model_tool.Refused as error:
        failure = ModelError(str(error), error.code)
    except ModelError as error:
        failure = error
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        failure = ModelError(str(error), 1)
    if json_mode:
        print(json.dumps({"ok": False, "error": str(failure), "remedy": failure.remedy}))
    else:
        print(f"model: {failure}", file=sys.stderr)
        if failure.remedy:
            print(f"Run: {failure.remedy}", file=sys.stderr)
    return failure.code


if __name__ == "__main__":
    raise SystemExit(main())
