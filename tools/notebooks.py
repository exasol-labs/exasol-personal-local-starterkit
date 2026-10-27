"""The kit's notebooks are written as jupytext percent-format .py files (reviewable, diffable) and shipped as .ipynb
built from them: one cell per ``# %%`` marker, markdown cells for ``# %% [markdown]``. No jupytext needed.

    python3 tools/notebooks.py                   # rebuild every notebook/notebooks/<folder>/<name>.ipynb from its .py
    python3 tools/notebooks.py --check           # exit 1 when an .ipynb differs from its .py; writes nothing
    python3 tools/notebooks.py --marimo          # also write the Marimo versions to notebook/marimo/<folder>/ (needs uv)
    python3 tools/notebooks.py --check --marimo  # also compare notebook/marimo/ with a fresh conversion in a temp folder
                                                 # (skipped, with a note, when uv is not there); writes nothing
    python3 tools/notebooks.py --run [<notebook.py>...] [--dataset <id>]... [--timeout S] [--output DIR]
                                                 # execute the notebooks headless on the kit's kernel against the
                                                 # local database (every catalog notebook when none is named), once
                                                 # per --dataset; exit 1 with the failing cell and its traceback

The notebooks are in one folder per persona (``data-scientist/``, ``ml-engineer/``) beside ``00_shared/``, which holds
the cells both quickstarts share. A quickstart takes them with one line, ``# %% [include] ../00_shared/<file>.py
<tag>``: the build puts in its place every cell of that file whose ``tags=[...]`` names the tag, so both quickstarts
carry the very same cells and each built notebook stands on its own in every front end (nothing is imported from
another notebook at run time). A cell's tags travel into the .ipynb as its metadata, as jupytext writes them.

The Marimo versions are converted from the .ipynb by marimo itself (``marimo convert``) at the version versions.json
pins for the notebook add-on (components.notebook.frontends.marimo), the one the add-on installs, so a reviewer still
reads one source; they are committed, and the add-on copies them for its users. A catalog entry whose .py is not in
the tree yet is skipped with a note.

``--run`` (AC-DS3.1, AC-ML3.1) builds each notebook in memory from its .py and executes it with nbclient on the kernel
the notebook add-on registers (``exasol-starter-kit``, or the one EXAKIT_NOTEBOOK_KERNEL names), so the cells run
exactly as a user runs them: same kernel, same environment, same connection from the kit's store. ``--dataset <id>``
rewrites the notebook's one dataset assignment (``DATASET = "..."`` in explore/train/score, ``SAMPLE = "..."`` in the
quickstarts' shared load cell) to that id - the "one assignment switches" promise, exercised rather than assumed;
given several, each notebook runs once per dataset. A cell tagged ``skip-ci`` is left out of the run. The kernel sees
the caller's environment except the LANGFUSE_* variables, which are dropped (a headless run never writes to anyone's
Langfuse); MLFLOW_TRACKING_URI passes through when set, else MLflow uses its local store in the run folder. The role
review runs as EXAKIT_NB_AUTO_APPROVE=1 (a proposal equal to the approved version is used, nothing is written; another
stays a draft) unless the caller exported it; ``force`` approves whatever is proposed. The run
folder is a temporary directory per notebook and dataset (``mlflow/``, ``models/`` land there, never in the tree);
``--output DIR`` keeps the executed .ipynb, outputs included, for a CI artifact. Needs nbclient in the kit's notebook
environment: when the Python running this has none, ``--run`` re-runs itself with the kit's notebook Python
(EXAKIT_NOTEBOOK_PYTHON, else $EXAKIT_HOME/notebook-venv), and says how to add nbclient when that one lacks it too.
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
SKIP_TAG = "skip-ci"                                       # a cell tagged so is left out of a --run
DATASET_NAMES = ("DATASET", "SAMPLE")                      # the one assignment that picks the data, per notebook kind
_DATASET_LINE = re.compile(r'^(?P<name>' + "|".join(DATASET_NAMES) + r')(?P<gap>\s*=\s*)"[^"\n]*"', re.M)
LANGFUSE_PREFIX = "LANGFUSE_"

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



# --- --run: execute the notebooks headless (AC-DS3.1, AC-ML3.1) ---------------------------------------------------

def notebook_python() -> Path | None:
    """The kit's notebook Python: EXAKIT_NOTEBOOK_PYTHON, else the venv under EXAKIT_HOME (~/.exasol-starter-kit)."""
    import os
    if os.environ.get("EXAKIT_NOTEBOOK_PYTHON"):
        return Path(os.environ["EXAKIT_NOTEBOOK_PYTHON"]).expanduser()
    home = Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser()
    venv = home / "notebook-venv"
    for candidate in (venv / "bin" / "python", venv / "Scripts" / "python.exe"):
        if candidate.is_file():
            return candidate
    return None


def run_document(py: Path, dataset: str | None, skip_tag: str = SKIP_TAG) -> dict:
    """The notebook to execute, as nbformat's dict: built from the .py, the dataset assignment rewritten to ``dataset``
    when one is given (DATASET or SAMPLE, whichever the notebook has - both when it has both), cells tagged ``skip_tag``
    left out. A dataset given to a notebook with no such assignment is an error: the override would do nothing."""
    doc = json.loads(build(py))
    doc["cells"] = [cell for cell in doc["cells"] if skip_tag not in cell.get("metadata", {}).get("tags", [])]
    if dataset is not None:
        if not re.fullmatch(r"[A-Za-z0-9_./~ -]+", dataset):
            raise ValueError(f"{dataset!r} is not a dataset id or path the notebooks take")
        hits = 0
        for cell in doc["cells"]:
            if cell["cell_type"] != "code":
                continue
            source = "".join(cell["source"])
            source, n = _DATASET_LINE.subn(lambda m: f'{m.group("name")}{m.group("gap")}"{dataset}"', source)
            if n:
                hits += n
                cell["source"] = source.splitlines(keepends=True)
        if not hits:
            raise ValueError(f"{py.name} assigns none of {', '.join(DATASET_NAMES)}, so --dataset would change nothing")
    return doc


AUTO_APPROVE = "EXAKIT_NB_AUTO_APPROVE"                    # 1: approve a proposal equal to the approved version (writes nothing);
                                                            # force: approve whatever is proposed (a scripted approval)


def _run_environment() -> dict[str, str]:
    """The kernel's environment: this process's, without the LANGFUSE_* variables (nothing headless traces to a
    person's Langfuse). MLFLOW_TRACKING_URI, the model variables and everything else pass through. The role review
    runs headless as EXAKIT_NB_AUTO_APPROVE=1 - a proposal whose roles equal the current approved version's is used
    as approved and nothing is written, any other stays a draft - unless the caller set it (``force`` approves)."""
    import os
    return {**{k: v for k, v in os.environ.items() if not k.startswith(LANGFUSE_PREFIX)},
            AUTO_APPROVE: os.environ.get(AUTO_APPROVE) or "1", "EXAKIT_NB_STRICT": "1"}


def _plain(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)


def _as_dict(nb) -> dict:
    """An nbformat notebook as the plain dict its JSON is (outputs included)."""
    import nbformat
    return json.loads(nbformat.writes(nb))


def execute(doc: dict, kernel: str, cwd: Path, timeout: int) -> tuple[dict, str | None]:
    """Run every cell of ``doc`` in order on ``kernel`` with ``cwd`` as the working folder; (the executed document,
    None) when every cell ran, else (the document as far as it got, what went wrong: the cell's index, its source and
    the traceback)."""
    import nbformat
    from nbclient import NotebookClient
    from nbclient.exceptions import CellExecutionError, CellTimeoutError

    nb = nbformat.reads(json.dumps(doc), as_version=4)       # reads() joins each cell's source lines into one string
    client = NotebookClient(nb, timeout=timeout, kernel_name=kernel, allow_errors=False, record_timing=False,
                            resources={"metadata": {"path": str(cwd)}})
    # The environment goes to the kernel explicitly: jupyter_client builds the kernel's from the kernelspec alone
    # unless one is handed to start_kernel, so a model variable exported before the run would not reach the cells.
    with client.setup_kernel(env=_run_environment()):
        for index, cell in enumerate(nb.cells):
            try:
                client.execute_cell(cell, index)
            except CellTimeoutError:
                return _as_dict(nb), (f"cell {index} did not finish within {timeout}s (--timeout raises it)\n"
                                      f"--- cell {index} ---\n{cell.source}\n")
            except CellExecutionError as failure:
                return _as_dict(nb), (f"cell {index} raised {failure.ename}: {_plain(failure.evalue)}\n"
                                      f"--- cell {index} ---\n{cell.source}\n--- traceback ---\n"
                                      f"{_plain(failure.traceback)}\n")
    return _as_dict(nb), None


def run(notebooks: list[Path], datasets: list[str | None], kernel: str, timeout: int, output: Path | None) -> int:
    """Each notebook once per dataset; one line per run, the failing cell and traceback for a failure; 0 when all ran."""
    import tempfile
    import time
    failed = 0
    for py in notebooks:
        name = py.relative_to(FOLDER).as_posix() if py.is_relative_to(FOLDER) else py.name
        for dataset in datasets:
            label = f"{name} on {dataset}" if dataset else name
            try:
                doc = run_document(py, dataset)
            except ValueError as problem:
                print(f"FAIL {label}: {problem}")
                failed += 1
                continue
            started = time.monotonic()
            with tempfile.TemporaryDirectory(prefix="exakit-nb-run-") as folder:
                print(f"run  {label}: {sum(c['cell_type'] == 'code' for c in doc['cells'])} code cells on kernel "
                      f"{kernel}, in {folder}", flush=True)
                try:
                    executed, problem = execute(doc, kernel, Path(folder), timeout)
                except Exception as broken:                 # not a cell: the kernel (not registered, did not start)
                    import traceback
                    traceback.print_exc()
                    kind = type(broken).__name__
                    hint = ("" if kind != "NoSuchKernel" else
                            " - register it with: exakit notebook check (the notebook add-on), or name another with "
                            "EXAKIT_NOTEBOOK_KERNEL")
                    print(f"FAIL {label}: the run on kernel {kernel!r} did not finish ({kind}: {_plain(str(broken))}){hint}")
                    return 2
            if output is not None:
                stem = f"{py.stem}.{dataset}" if dataset else py.stem
                target = output / (py.parent.name if py.is_relative_to(FOLDER) else "") / f"{stem}.ipynb"
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(json.dumps(executed, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
            seconds = time.monotonic() - started
            if problem:
                failed += 1
                print(f"FAIL {label} after {seconds:.0f}s: {problem}", flush=True)
            else:
                print(f"ok   {label} ({seconds:.0f}s)", flush=True)
    print(f"{len(notebooks) * len(datasets) - failed} ran, {failed} failed")
    return 1 if failed else 0


def run_main(argv: list[str]) -> int:
    """``--run`` from the command line: the options, the notebooks (named, or every catalog notebook that is in the
    tree), the interpreter (this one when it has nbclient, else the kit's notebook Python)."""
    import argparse
    import os
    import subprocess
    parser = argparse.ArgumentParser(prog="tools/notebooks.py --run",
                                     description="Execute the kit's notebooks headless on the local database.")
    parser.add_argument("--run", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("notebooks", nargs="*", metavar="notebook.py",
                        help="notebook sources to run (default: every catalog notebook in notebook/notebooks)")
    parser.add_argument("--dataset", action="append", default=[], metavar="ID",
                        help="run on this dataset (pharma_trials, banking_complaints, a descriptor or file path); "
                             "repeat for several; none keeps each notebook's own assignment")
    parser.add_argument("--timeout", type=int, default=900, metavar="S", help="seconds one cell may take (default 900)")
    parser.add_argument("--kernel", default=os.environ.get("EXAKIT_NOTEBOOK_KERNEL") or KERNEL["name"],
                        help="the Jupyter kernel (default: EXAKIT_NOTEBOOK_KERNEL, else the kit's %(default)s)")
    parser.add_argument("--output", type=Path, default=None, metavar="DIR",
                        help="keep each executed notebook, outputs included, as DIR/<persona>/<name>.<dataset>.ipynb")
    args = parser.parse_args(argv)
    try:
        import nbclient  # noqa: F401
        import nbformat  # noqa: F401
    except ImportError:
        kit_python = notebook_python()
        if kit_python is None or Path(sys.executable).resolve() == kit_python.resolve():
            print("--run needs nbclient in the kit's notebook environment. Add it with:\n"
                  f"  uv pip install --python {kit_python or '<notebook-venv>/bin/python'} nbclient\n"
                  "(the notebook add-on: exakit marketplace notebook; or set EXAKIT_NOTEBOOK_PYTHON)", file=sys.stderr)
            return 2
        return subprocess.call([str(kit_python), str(Path(__file__).resolve()), *argv])
    if args.notebooks:
        notebooks = [Path(name).resolve() for name in args.notebooks]
        missing = [str(n) for n in notebooks if not n.is_file()]
        if missing:
            print(f"not a notebook source: {', '.join(missing)}", file=sys.stderr)
            return 2
    else:
        for name in pending():
            print(f"note: {name} is not in notebook/notebooks yet; its catalog entry is skipped until it is", file=sys.stderr)
        shared = json.loads(CATALOG.read_text(encoding="utf-8"))["shared"]["folder"]
        notebooks = [FOLDER / folder / f"{Path(jupyter).stem}.py" for folder, jupyter, _ in catalog_files()
                     if folder != shared and (FOLDER / folder / f"{Path(jupyter).stem}.py").is_file()]
    return run(notebooks, args.dataset or [None], args.kernel, args.timeout, args.output)


def main(argv: list[str]) -> int:
    if "--run" in argv:
        return run_main(argv)
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
