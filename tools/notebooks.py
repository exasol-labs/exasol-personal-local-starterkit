"""The kit's notebooks are written as jupytext percent-format .py files (reviewable, diffable) and shipped as .ipynb
built from them: one cell per ``# %%`` marker, markdown cells for ``# %% [markdown]``. No jupytext needed.

    python3 tools/notebooks.py           # rebuild every notebook/notebooks/<name>.ipynb that has a <name>.py
    python3 tools/notebooks.py --check   # exit 1 when an .ipynb differs from its .py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

FOLDER = Path(__file__).resolve().parents[1] / "notebook" / "notebooks"
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


def main(argv: list[str]) -> int:
    stale = []
    for py in sorted(FOLDER.glob("*.py")):
        target, text = py.with_suffix(".ipynb"), build(py)
        if "--check" in argv:
            if not target.exists() or target.read_text(encoding="utf-8") != text:
                stale.append(target.name)
        else:
            target.write_text(text, encoding="utf-8")
    if stale:
        print(f"out of date with their .py (run: python3 tools/notebooks.py): {', '.join(stale)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
