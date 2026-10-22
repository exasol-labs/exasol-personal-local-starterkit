"""The kit's notebooks are written as jupytext percent-format .py files (reviewable, diffable) and shipped as .ipynb
built from them: one cell per ``# %%`` marker, markdown cells for ``# %% [markdown]``. No jupytext needed.

    python3 tools/notebooks.py                   # rebuild every notebook/notebooks/<folder>/<name>.ipynb from its .py
    python3 tools/notebooks.py --check           # exit 1 when an .ipynb differs from its .py; writes nothing
    python3 tools/notebooks.py --marimo          # also write the Marimo versions to notebook/marimo/<folder>/ (needs uv)
    python3 tools/notebooks.py --check --marimo  # also compare notebook/marimo/ with a fresh conversion in a temp folder
                                                 # (skipped, with a note, when uv is not there); writes nothing

The notebooks are in one folder per persona (``data-scientist/``, ``ml-engineer/``) beside ``00_shared/``, which holds
the cells both quickstarts share. A quickstart takes them with one line, ``# %% [include] ../00_shared/<file>.py
<tag>``: the build puts in its place every cell of that file whose ``tags=[...]`` names the tag, so both quickstarts
carry the very same cells and each built notebook stands on its own in every front end (nothing is imported from
another notebook at run time). A cell's tags travel into the .ipynb as its metadata, as jupytext writes them.

The Marimo versions are converted from the .ipynb by marimo itself (``marimo convert``) at the version versions.json
pins for the notebook add-on (components.notebook.frontends.marimo), the one the add-on installs, so a reviewer still
reads one source; they are committed, and the add-on copies them for its users. A catalog entry whose .py is not in
the tree yet is skipped with a note.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / "notebook" / "notebooks"
MARIMO = FOLDER.parent / "marimo"
CATALOG = FOLDER.parent / "catalog.json"
VERSIONS = ROOT / "versions.json"
KERNEL = {"display_name": "Exasol (Starter Kit)", "language": "python", "name": "exasol-starter-kit"}
_TAGS = re.compile(r"\btags=(\[[^\]]*\])")

Cell = tuple[str, list[str], list[str]]          # kind, source lines, tags


def marimo_pin() -> str:
    """``marimo==<version>``: the Marimo versions.json pins for the notebook add-on."""
    doc = json.loads(VERSIONS.read_text(encoding="utf-8"))
    version = doc["components"]["notebook"]["frontends"]["marimo"]
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", version):
        raise ValueError(f"versions.json components.notebook.frontends.marimo is not a version: {version!r}")
    return f"marimo=={version}"


def _header_tags(line: str) -> list[str]:
    found = _TAGS.search(line)
    return [str(tag) for tag in json.loads(found.group(1))] if found else []


def _cells(source: str, where: Path | None = None) -> list[Cell]:
    """(kind, lines, tags) per ``# %%`` block, after the jupytext header; ``# %% [include] <file> <tag>`` is replaced
    by the cells of ``<file>`` (relative to ``where``) that carry the tag."""
    lines = source.splitlines()
    if lines and lines[0] == "# ---":
        lines = lines[lines.index("# ---", 1) + 1:]
    cells: list[Cell] = []
    for line in lines:
        if line.startswith("# %% [include]"):
            if where is None:
                raise ValueError("an include needs the folder of the notebook it is in")
            parts = line.split()[3:]
            if len(parts) != 2:
                raise ValueError(f"'{line}' is not '# %% [include] <file> <tag>'")
            shared = (where / parts[0]).resolve()
            taken = [cell for cell in _cells(shared.read_text(encoding="utf-8"), shared.parent) if parts[1] in cell[2]]
            if not taken:
                raise ValueError(f"{parts[0]} has no cell tagged {parts[1]}")
            cells += [(kind, list(body), tags) for kind, body, tags in taken]
            cells.append(("skip", [], []))                         # the lines after an include belong to no cell
        elif line.startswith("# %%"):
            cells.append(("markdown" if "[markdown]" in line else "code", [], _header_tags(line)))
        elif cells:
            cells[-1][1].append(line)
    return [cell for cell in cells if cell[0] != "skip"]


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
    for index, (kind, lines, tags) in enumerate(_cells(py.read_text(encoding="utf-8"), py.parent)):
        cell = {"cell_type": kind, "id": f"{py.stem}-{index:02d}", "metadata": {"tags": tags} if tags else {},
                "source": _source(kind, lines)}
        if kind == "code":
            cell.update(execution_count=None, outputs=[])
        cells.append(cell)
    doc = {"cells": cells, "metadata": {"kernelspec": KERNEL, "language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}
    return json.dumps(doc, indent=1, ensure_ascii=False) + "\n"


def sources() -> list[Path]:
    """Every notebook source: the .py files in notebook/notebooks/<folder>/."""
    return sorted(FOLDER.glob("*/*.py"))


def catalog_files() -> list[tuple[str, str, str]]:
    """(folder, Jupyter file, Marimo file or "") for the shared cells and every catalog notebook."""
    doc = json.loads(CATALOG.read_text(encoding="utf-8"))
    entries = [(doc["shared"]["folder"], doc["shared"])] + [(entry["persona"], entry) for entry in doc["notebooks"]]
    return [(folder, entry["jupyter"], entry.get("marimo", "")) for folder, entry in entries]


def pending() -> list[str]:
    """The catalog notebooks whose .py source is not in the tree yet (named in a note, skipped)."""
    return [f"{folder}/{Path(jupyter).stem}.py" for folder, jupyter, _ in catalog_files()
            if not (FOLDER / folder / f"{Path(jupyter).stem}.py").is_file()]


def marimo(notebooks: list[tuple[Path, Path]]) -> None:
    """Each (.ipynb, Marimo target) converted by the marimo versions.json pins."""
    import subprocess
    pinned = marimo_pin()
    for ipynb, target in notebooks:
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["uvx", "--from", pinned, "marimo", "convert", str(ipynb), "-o", str(target)],
                       check=True, capture_output=True)


def _marimo_sources() -> list[tuple[Path, str]]:
    """(the .py source, its Marimo file relative to notebook/marimo/) for each catalog notebook with a Marimo version."""
    return [(FOLDER / folder / f"{Path(name).stem}.py", f"{folder}/{name}") for folder, _, name in catalog_files() if name]


def check_marimo() -> list[str]:
    """The Marimo files that differ from a fresh conversion of their .py, converted in a temp folder: from the .ipynb
    built in memory, so a stale .ipynb in the tree cannot hide a stale Marimo file. Nothing in the tree is written."""
    import shutil
    import tempfile
    if not shutil.which("uvx"):
        print("note: uv is not installed, so notebook/marimo/ was not compared (install uv to check it)", file=sys.stderr)
        return []
    stale = []
    present = [(source, relative) for source, relative in _marimo_sources() if source.is_file()]   # pending: see main()
    with tempfile.TemporaryDirectory() as tmp:
        jobs = []
        for source, relative in present:
            ipynb = Path(tmp) / "ipynb" / relative.replace(".py", ".ipynb")
            ipynb.parent.mkdir(parents=True, exist_ok=True)
            ipynb.write_text(build(source), encoding="utf-8")
            jobs.append((ipynb, Path(tmp) / "marimo" / relative))
        marimo(jobs)
        for (_, fresh), (_, relative) in zip(jobs, present):
            shipped = MARIMO / relative
            if not shipped.is_file() or shipped.read_text(encoding="utf-8") != fresh.read_text(encoding="utf-8"):
                stale.append(f"marimo/{relative}")
    # Marimo runs a notebook only when each name is defined in one cell: a Jupyter notebook that assigns a name in
    # two cells converts without a word and then fails in Marimo. marimo check says so now.
    import subprocess
    shipped = [str(MARIMO / relative) for _, relative in present if (MARIMO / relative).is_file()]
    if shipped:
        done = subprocess.run(["uvx", "--from", marimo_pin(), "marimo", "check", *shipped], capture_output=True, text=True)
        if done.returncode != 0:
            print(done.stdout + done.stderr, file=sys.stderr)
            stale.append("marimo/ (marimo check failed: a name defined in two cells, see above)")
    return stale


def main(argv: list[str]) -> int:
    check = "--check" in argv
    stale = []
    for name in pending():
        print(f"note: {name} is not in notebook/notebooks yet; its catalog entry is skipped until it is", file=sys.stderr)
    for py in sources():
        target, text = py.with_suffix(".ipynb"), build(py)
        if check:
            if not target.exists() or target.read_text(encoding="utf-8") != text:
                stale.append(target.relative_to(FOLDER).as_posix())
        else:
            target.write_text(text, encoding="utf-8")
    for ipynb in FOLDER.glob("**/*.ipynb"):
        if not ipynb.with_suffix(".py").is_file():
            stale.append(f"{ipynb.relative_to(FOLDER).as_posix()} (no .py source)")
    if "--marimo" in argv:
        if check:
            stale += check_marimo()
        else:
            marimo([(source.with_suffix(".ipynb"), MARIMO / relative) for source, relative in _marimo_sources()
                    if source.is_file()])
    if stale:
        regen = "python3 tools/notebooks.py --marimo" if any(s.startswith("marimo/") for s in stale) else "python3 tools/notebooks.py"
        print(f"out of date with their .py (run: {regen}): {', '.join(stale)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
