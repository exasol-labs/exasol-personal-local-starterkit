"""The kit's notebooks into the user's notebooks folder, one folder per persona, and the folder prepared for Positron.
Standard library only; one file for setup/lib/notebook.sh and notebook.ps1, so the two cannot drift.

    python notebooks.py copy <jupyter|marimo> <kit_root> <notebooks_dir>   prints persona/file for each one added
    python notebooks.py positron <notebooks_dir> <python> <venv>           .vscode/settings.json names the kit's Python
    python notebooks.py list <kit_root>                                    step|persona|title|jupyter file|marimo file

What goes where is notebook/catalog.json: the Jupyter notebooks into <notebooks_dir>/starter-kit-notebooks/<persona>/
with a README naming the end-to-end path through them, the Marimo ones into <notebooks_dir>/marimo/<persona>/. A file
already there is the user's and is never overwritten; neither is the README. Exit 2 for bad input, 3 when the Positron
settings file is not valid JSON (it is left alone).
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path


def catalog(kit: Path) -> dict:
    """notebook/catalog.json, its notebooks in the order of the end-to-end path."""
    doc = json.loads((kit / "notebook" / "catalog.json").read_text(encoding="utf-8"))
    doc["notebooks"] = sorted(doc["notebooks"], key=lambda entry: int(entry.get("step", 0)))
    return doc


def persona_title(kit: Path, persona: str) -> str:
    """The persona's title from personas/<id>.json; the id when there is no such file."""
    try:
        return str(json.loads((kit / "personas" / f"{persona}.json").read_text(encoding="utf-8"))["title"])
    except (OSError, ValueError, KeyError):
        return persona


def copy(front: str, kit: Path, notebooks_dir: Path) -> list[str]:
    """The kit's notebooks for a front end into their persona folders; the ones added, as persona/file."""
    doc = catalog(kit)
    source = kit / doc["sources"][front]
    base = notebooks_dir / doc["folders"][front]
    added = []
    for entry in doc["notebooks"]:
        name = entry.get(front)
        if not name or not (source / name).is_file():
            continue
        target = base / entry["persona"] / name
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)
        added.append(f"{entry['persona']}/{name}")
    if front == "jupyter":                           # Marimo would list a README as a notebook of its own
        write_readme(kit, doc, base)
    return added


def write_readme(kit: Path, doc: dict, folder: Path) -> None:
    """A README naming each persona folder and the end-to-end path through them; written once, then the user's."""
    readme = folder / "README.md"
    if readme.exists() or not folder.is_dir():
        return
    lines = ["# The starter kit's notebooks", "", "One folder per persona. Together they are one path, end to end:", ""]
    for entry in doc["notebooks"]:
        if entry.get("jupyter"):
            who = persona_title(kit, entry["persona"])
            lines.append(f"{entry['step']}. `{entry['persona']}/{entry['jupyter']}` ({who}) - {entry['title']}: {entry['summary']}")
            lines.append(f"   Needs: {entry['needs']}")
    lines += ["", "Every notebook connects with `import exakit_nb; conn = exakit_nb.connect()` - no host, user or password.",
              "These files are yours: the kit never overwrites them. Your own notebooks can go anywhere in the notebooks folder.",
              "", "Also: `exakit notebook --marimo` (the same notebooks in Marimo), `exakit notebook --positron` (this folder in",
              "Positron, with the kit's Python).", ""]
    readme.write_text("\n".join(lines), encoding="utf-8")


def positron(notebooks_dir: Path, python: str, venv: str) -> Path:
    """The notebooks folder as a Positron workspace whose interpreter is the kit's notebook Python; the file's other
    settings stay. ValueError when the file is not valid JSON."""
    path = notebooks_dir / ".vscode" / "settings.json"
    doc: dict = {}
    if path.is_file():
        doc = json.loads(path.read_text(encoding="utf-8") or "{}")
        if not isinstance(doc, dict):
            raise ValueError(f"{path} is not a JSON object")
    doc["python.defaultInterpreterPath"] = python
    doc["python.interpreters.include"] = sorted({*doc.get("python.interpreters.include", []), venv})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    return path


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[0] == "copy" and argv[1] in ("jupyter", "marimo"):
        for line in copy(argv[1], Path(argv[2]), Path(argv[3]) if len(argv) > 3 else Path(".")):
            print(line)
        return 0
    if len(argv) == 4 and argv[0] == "positron":
        try:
            print(positron(Path(argv[1]), argv[2], argv[3]))
        except ValueError as err:
            print(f"{err} - the kit leaves it alone; choose the interpreter {argv[2]} in Positron yourself", file=sys.stderr)
            return 3
        return 0
    if len(argv) == 2 and argv[0] == "list":
        kit = Path(argv[1])
        for entry in catalog(kit)["notebooks"]:
            print(f"{entry['step']}|{entry['persona']}|{entry['title']}|{entry.get('jupyter', '')}|{entry.get('marimo', '')}")
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
