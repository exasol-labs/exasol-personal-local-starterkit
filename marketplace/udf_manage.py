"""Cross-platform exakit udf-setup, udf-use and udf-build command entry point."""

from __future__ import annotations

import json
import os
import sys
from contextlib import nullcontext, redirect_stdout
from pathlib import Path

from addons import udf_devkit as udf
from runtime import AddonFailure, KitContext


def _parse(command: str, words: list[str]) -> dict:
    result = {"language": os.environ.get("EXAKIT_UDF_LANGUAGE", "python"), "yes": False,
              "json": False, "force": False, "list": False, "alias": "", "item": ""}
    positionals = []
    index = 0
    while index < len(words):
        word = words[index]
        if word in ("--json", "-j") and command != "udf-build":
            result["json"] = True
        elif word in ("--yes", "-y"):
            result["yes"] = True
        elif word == "--force" and command == "udf-setup":
            result["force"] = True
        elif word == "--list" and command == "udf-use":
            result["list"] = True
        elif word in ("--language", "--alias"):
            if word == "--alias" and command == "udf-setup":
                raise udf.UdfFailure("udf-setup has no --alias option.", 2, "select-container")
            if word == "--language" and command == "udf-build":
                raise udf.UdfFailure("udf-build has no --language option.", 2, "select-container")
            index += 1
            if index >= len(words) or not words[index] or words[index].startswith("--"):
                raise udf.UdfFailure(f"{word} needs a value.", 2, "select-container")
            result[word.removeprefix("--")] = words[index]
        elif word.startswith("-"):
            raise udf.UdfFailure(f"Unknown option for {command}: {word}.", 2, "select-container")
        else:
            positionals.append(word)
        index += 1
    if result["language"] not in ("python", "rust"):
        raise udf.UdfFailure("The UDF language must be python or rust.", 2, "select-container")
    if command == "udf-setup":
        if positionals:
            raise udf.UdfFailure("udf-setup takes options only.", 2, "select-container")
    elif command == "udf-use":
        if result["list"]:
            if positionals:
                raise udf.UdfFailure("udf-use --list takes no container.", 2, "select-container")
        elif len(positionals) != 1:
            raise udf.UdfFailure("Name default or one container tarball for udf-use.", 2, "select-container")
        else:
            result["item"] = positionals[0]
            if result["item"] != "default":
                source = Path(result["item"]).expanduser()
                if not str(source).endswith((".tar.gz", ".tgz")) or not source.is_file():
                    raise udf.UdfFailure(f"{source} is not a container tarball file.", 2, "select-container")
                from udf_container import _rules

                try:
                    result["alias"] = _rules(Path(__file__).resolve().parent.parent).identifier(
                        result["alias"] or "PYTHON3_CUSTOM", "The container alias")
                except ValueError as error:
                    raise udf.UdfFailure(str(error), 2, "select-container") from error
    elif command == "udf-build":
        if len(positionals) != 1:
            raise udf.UdfFailure("Name one pinned requirements file for udf-build.", 2, "select-container")
        result["item"] = positionals[0]
        if not Path(result["item"]).is_file():
            raise udf.UdfFailure(f"{result['item']} is not a file.", 2, "select-container")
    else:
        raise udf.UdfFailure(f"Unknown UDF command {command}.", 2, "select-container")
    return result


def _done(language: str, alias: str, row: dict | None, smoke: list[dict],
          steps: list[dict] | None = None) -> dict:
    container = {key: row.get(field) if row else None for key, field in
                 (("url", "url"), ("sha256", "sha256"), ("arch", "arch"), ("db_versions", "db_versions"))}
    result = {"ok": True, "language": language, "alias": alias, "container": container, "smoke": smoke}
    if steps is not None:
        result["steps"] = steps
    return result


def _execute(ctx: KitContext, name: str, options: dict) -> dict:
    language = options["language"]
    if not udf.installed_version(ctx):
        raise udf.UdfFailure("The UDF dev kit is not installed.", 5, "select-container",
                             "exakit marketplace udf-devkit")
    if name == "udf-setup":
        if language == "rust":
            row, smoke, steps = udf.setup_rust(ctx, force=options["force"], yes=options["yes"])
            return _done(language, udf.RUST, row, smoke, steps)
        row, smoke = udf.setup_python(ctx, force=options["force"], yes=options["yes"])
        return _done(language, udf.PYTHON, row, smoke)
    if name == "udf-use" and options["list"]:
        result = udf._slc(ctx, "list", "--json") if options["json"] else udf._slc(ctx, "list")
        if result.returncode:
            raise udf.UdfFailure("The launcher could not list UDF containers.", 5, "select-container",
                                 "exakit logs")
        if options["json"]:
            return {"ok": True, "containers": json.loads(result.stdout)}
        return {"_list_text": result.stdout}
    if name == "udf-use" and options["item"] == "default":
        if language == "rust":
            row, smoke, steps = udf.setup_rust(ctx, force=True, yes=options["yes"])
            return _done(language, udf.RUST, row, smoke, steps)
        row, smoke = udf.setup_default(ctx, yes=options["yes"])
        return _done(language, udf.ML, row, smoke)
    if name == "udf-use":
        smoke = udf.install_tarball(ctx, Path(options["item"]).expanduser(), options["alias"], language,
                                    yes=options["yes"])
        return _done(language, options["alias"], None, smoke)
    smoke = udf.build(ctx, Path(options["item"]).expanduser(), options["alias"] or "PYTHON3_CUSTOM",
                      yes=options["yes"])
    return _done("python", options["alias"] or "PYTHON3_CUSTOM", None, smoke)


def command(ctx: KitContext, name: str, words: list[str]) -> int:
    options = _parse(name, words)
    json_mode = options["json"]
    language = options["language"]
    try:
        with redirect_stdout(sys.stderr) if json_mode else nullcontext():
            answer = _execute(ctx, name, options)
    except udf.UdfFailure as failure:
        if json_mode:
            print(json.dumps({"ok": False, "language": language, "step": failure.step,
                              "reason": str(failure), "remedy": failure.remedy}))
        else:
            print(f"{name}: {failure}", file=sys.stderr)
            if failure.remedy:
                print(f"Run: {failure.remedy}", file=sys.stderr)
        return failure.code
    except (AddonFailure, OSError, ValueError) as error:
        if json_mode:
            print(json.dumps({"ok": False, "language": language, "step": "install",
                              "reason": str(error), "remedy": "exakit logs"}))
        else:
            print(f"{name}: {error}", file=sys.stderr)
        return 5
    if json_mode:
        print(json.dumps(answer))
    elif "_list_text" in answer:
        print(answer["_list_text"], end="")
    else:
        print(f"  ✓ {answer['alias']} UDF container ready")
        for line in answer["smoke"]:
            print(f"    {line['package']}: {line['version']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        print("Name udf-setup, udf-use or udf-build.", file=sys.stderr)
        return 2
    name, *words = args
    json_mode = "--json" in words or "-j" in words
    try:
        return command(KitContext.from_environment(Path(__file__).resolve().parent.parent), name, words)
    except udf.UdfFailure as failure:
        if json_mode:
            print(json.dumps({"ok": False, "language": os.environ.get("EXAKIT_UDF_LANGUAGE", "python"),
                              "step": failure.step, "reason": str(failure), "remedy": failure.remedy}))
        else:
            print(f"{name}: {failure}", file=sys.stderr)
        return failure.code


if __name__ == "__main__":
    raise SystemExit(main())
