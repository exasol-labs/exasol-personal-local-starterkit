"""Read-only catalog adapter for the two platform entry scripts.

The output is deliberately line based: neither shell needs to parse JSON or
maintain an add-on list. All fields are validated before any row is printed.
"""

from __future__ import annotations

import argparse
import importlib
import sys
from pathlib import Path

from model import CatalogError, load_addons, parse_addon_answer
from runtime import AddonFailure
from service import OPERATIONS


def notebook_choices(root: Path, kind: str, selected: str = "") -> list[str]:
    from addons import notebook
    from notebook_cli import _positron_command
    from runtime import KitContext, venv_executable

    ctx = KitContext.from_environment(root)
    choices = next((addon.choices for addon in load_addons(root) if addon.id == "notebook"), None)
    if choices is None:
        raise CatalogError("notebook is missing from marketplace/catalog.json")
    ids = [key for key, _ in choices]
    if kind == "notebook-normalize":
        picked = [part.strip().lower() for part in selected.split(",") if part.strip()]
        unknown = set(picked) - set(ids)
        if unknown:
            raise CatalogError(f"Unknown notebook choice: {', '.join(sorted(unknown))}")
        return [",".join(key for key in ids if key in picked) or "none"]
    if kind == "notebook-questions":
        return ["JupyterLab - notebooks in the browser with the kit's kernel; yours is used if you have one",
                "Marimo - reactive notebooks, installed into the kit's notebook environment",
                "Positron - your Positron, pointed at the kit's Python; never installed by the kit"]
    defaults = set(notebook._frontends(ctx))
    if kind == "notebook-default":
        return [",".join(key for key in ids if key in defaults) or "none"]
    venv = notebook.paths(ctx)[0]
    external = notebook._external_jupyter(ctx)
    if external:
        home = str(Path.home())
        display = str(external).replace(home, "~", 1) if str(external).startswith(home) else str(external)
        jupyter = f"yours ({display}) is used as it is"
    elif venv_executable(venv, "jupyter-lab").is_file():
        jupyter = "already in the kit's notebook environment"
    else:
        jupyter = "not on this machine: installed into the kit's notebook environment"
    marimo = ("already installed" if venv_executable(venv, "marimo").is_file()
              else "installed into the kit's notebook environment")
    positron = ("yours: pointed at the kit's Python" if _positron_command()
                else "not on this machine: the notebooks folder is prepared for it (positron.posit.co)")
    details = {"jupyterlab": (notebook._pin(ctx, "jupyterlab"), jupyter),
               "marimo": (notebook._pin(ctx, "marimo"), marimo),
               "positron": ("", positron)}
    return ["|".join((key, "Positron" if key == "positron" else label,
                      details[key][0], details[key][1].replace("|", "/"),
                      "1" if key in defaults else "0")) for key, label in choices]


def rows(root: Path, kind: str) -> list[str]:
    addons = load_addons(root)
    result = []
    for addon in addons:
        if kind == "registry":
            result.append("|".join((addon.id, addon.label, addon.backend,
                                    "1" if addon.visible else "0", addon.default_version)))
        elif kind == "shell-hooks":
            if not (root / "marketplace" / "addons" / (addon.id.replace("-", "_") + ".py")).is_file():
                continue
            try:
                module = importlib.import_module("addons." + addon.id.replace("-", "_"))
            except (ImportError, SyntaxError):
                continue
            for operation in sorted(OPERATIONS):
                method = operation.replace("-", "_")
                if callable(getattr(module, method, None)):
                    result.append(f"{addon.id}|{method}|{operation}")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("kind", choices=("registry", "shell-hooks", "answer",
                                         "notebook-rows", "notebook-default", "notebook-normalize",
                                         "notebook-questions"))
    parser.add_argument("value", nargs="?")
    args = parser.parse_args(argv)
    try:
        if args.kind.startswith("notebook-"):
            for row in notebook_choices(args.root, args.kind, args.value or ""):
                print(row)
        elif args.kind == "answer":
            if args.value is None:
                parser.error("answer needs EXAKIT_MARKETPLACE_ADDONS")
            print(parse_addon_answer(load_addons(args.root), args.value))
        else:
            for row in rows(args.root, args.kind):
                print(row)
    except (OSError, ValueError, CatalogError, AddonFailure, ImportError) as error:
        prefix = "" if args.kind == "answer" else "marketplace catalog: "
        print(f"{prefix}{error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
