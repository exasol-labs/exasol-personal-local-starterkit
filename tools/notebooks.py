"""The kit's notebooks are written as jupytext percent-format .py files (reviewable, diffable) and shipped as .ipynb
built from them: one cell per ``# %%`` marker, markdown cells for ``# %% [markdown]``. No jupytext needed.

    python3 tools/notebooks.py           # rebuild every notebook/notebooks/<name>.ipynb that has a <name>.py
    python3 tools/notebooks.py --check           # exit 1 when an .ipynb differs from its .py; writes nothing
    python3 tools/notebooks.py --marimo          # also write the Marimo versions to notebook/marimo/ (needs uv: marimo, pinned)
    python3 tools/notebooks.py --check --marimo  # also compare notebook/marimo/ with a fresh conversion in a temp folder
                                                 # (skipped, with a note, when uv is not there); writes nothing

The Marimo versions are converted from the .ipynb by marimo itself (``marimo convert``, at the version the notebook
add-on installs), so a reviewer still reads one source; they are committed, and the add-on copies them for its users.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

FOLDER = Path(__file__).resolve().parents[1] / "notebook" / "notebooks"
MARIMO = FOLDER.parent / "marimo"
CATALOG = FOLDER.parent / "catalog.json"
KERNEL = {"display_name": "Exasol (Starter Kit)", "language": "python", "name": "exasol-starter-kit"}


def _cells(source: str) -> list[tuple[str, list[str]]]:
    """(kind, lines) per ``# %%`` block, after the jupytext header."""
    lines = source.splitlines()
    if lines and lines[0] == "# ---":
        lines = lines[lines.index("# ---", 1) + 1:]
    cells: list[tuple[str, list[str]]] = []
    for line in lines:
        if line.startswith("# %%"):
            cells.append(("markdown" if "[markdown]" in line else "code", []))
        elif cells:
            cells[-1][1].append(line)
    return cells


def _source(kind: str, lines: list[str]) -> list[str]:
    """A cell's source as the .ipynb keeps it: markdown without its ``# ``, no blank lines at either end."""
    if kind == "markdown":
        lines = [line[2:] if line.startswith("# ") else line.lstrip("#") for line in lines]
    while lines and not lines[0].strip():
        lines = lines[1:]
    while lines and not lines[-1].strip():
        lines = lines[:-1]
    return [line + "\n" for line in lines[:-1]] + lines[-1:]


def build(py: Path) -> str:
    """The .ipynb text for a percent-format .py."""
    cells = []
    for index, (kind, lines) in enumerate(_cells(py.read_text(encoding="utf-8"))):
        cell = {"cell_type": kind, "id": f"{py.stem}-{index:02d}", "metadata": {}, "source": _source(kind, lines)}
        if kind == "code":
            cell.update(execution_count=None, outputs=[])
        cells.append(cell)
    doc = {"cells": cells, "metadata": {"kernelspec": KERNEL, "language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}
    return json.dumps(doc, indent=1, ensure_ascii=False) + "\n"


def marimo(notebooks: list[Path], into: Path = MARIMO) -> None:
    """Each .ipynb converted to a Marimo notebook in ``into`` by the marimo the add-on pins (its lowest allowed version)."""
    import subprocess
    spec = json.loads(CATALOG.read_text(encoding="utf-8"))["marimo_package"]
    pinned = spec.split(",")[0].replace(">=", "==")
    into.mkdir(exist_ok=True)
    for ipynb in notebooks:
        subprocess.run(["uvx", "--from", pinned, "marimo", "convert", str(ipynb), "-o", str(into / f"{ipynb.stem}.py")],
                       check=True, capture_output=True)


def _marimo_sources() -> list[str]:
    """The notebook names the catalog ships a Marimo version of (``<name>.py``)."""
    doc = json.loads(CATALOG.read_text(encoding="utf-8"))
    return sorted(entry["marimo"] for entry in doc["notebooks"] if entry.get("marimo"))


def check_marimo() -> list[str]:
    """The Marimo files that differ from a fresh conversion of their .py, converted in a temp folder: from the .ipynb
    built in memory, so a stale .ipynb in the tree cannot hide a stale Marimo file. Nothing in the tree is written."""
    import shutil
    import tempfile
    if not shutil.which("uvx"):
        print("note: uv is not installed, so notebook/marimo/ was not compared (install uv to check it)", file=sys.stderr)
        return []
    stale = []
    with tempfile.TemporaryDirectory() as tmp:
        built = []
        for name in _marimo_sources():
            source = FOLDER / name
            if not source.is_file():
                stale.append(f"marimo/{name} (no notebook/notebooks/{name})")
                continue
            ipynb = Path(tmp) / f"{source.stem}.ipynb"
            ipynb.write_text(build(source), encoding="utf-8")
            built.append(ipynb)
        out = Path(tmp) / "marimo"
        marimo(built, out)
        for ipynb in built:
            fresh, shipped = out / f"{ipynb.stem}.py", MARIMO / f"{ipynb.stem}.py"
            if not shipped.is_file() or shipped.read_text(encoding="utf-8") != fresh.read_text(encoding="utf-8"):
                stale.append(f"marimo/{ipynb.stem}.py")
    return stale


def main(argv: list[str]) -> int:
    check = "--check" in argv
    stale = []
    for py in sorted(FOLDER.glob("*.py")):
        target, text = py.with_suffix(".ipynb"), build(py)
        if check:
            if not target.exists() or target.read_text(encoding="utf-8") != text:
                stale.append(target.name)
        else:
            target.write_text(text, encoding="utf-8")
    if "--marimo" in argv:
        if check:
            stale += check_marimo()
        else:
            marimo([FOLDER / f"{Path(name).stem}.ipynb" for name in _marimo_sources()])
    if stale:
        regen = "python3 tools/notebooks.py --marimo" if any(s.startswith("marimo/") for s in stale) else "python3 tools/notebooks.py"
        print(f"out of date with their .py (run: {regen}): {', '.join(stale)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
