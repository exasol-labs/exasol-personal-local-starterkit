"""The kit's notebooks into the user's notebooks folder, one folder per persona, and the folder prepared for Positron.
Standard-library helper for the Python marketplace.

    python notebooks.py copy <jupyter|marimo> <kit_root> <notebooks_dir>   prints persona/file for each one added
    python notebooks.py positron <notebooks_dir> <python> <venv>           .vscode/settings.json names the kit's Python
    python notebooks.py positron-remove <notebooks_dir> <python> <venv>    takes the kit's two settings out again
    python notebooks.py list <kit_root>                                    step|persona|title|jupyter file|marimo file

What goes where is notebook/catalog.json: the Jupyter notebooks into <notebooks_dir>/starter-kit-notebooks/<persona>/
(and the shared cells into its 00_shared/) with a README naming the order to open them in, the Marimo ones into
<notebooks_dir>/marimo/<persona>/. A catalog entry whose file this kit copy does not carry is skipped. A file
already there is the user's and is never overwritten; neither is the README. What the kit copied is recorded in
.kit-copied in that folder, so a notebook the user deleted stays deleted. A notebook that cannot be copied (a file
where its persona folder should be, a folder that is read-only) is named on stderr, the rest are still copied, and the
exit status is 1.

The Positron settings file is read as VS Code writes it (JSON with // and /* */ comments and trailing commas). One
with comments is never rewritten, because rewriting would drop them: when it does not already name the kit's Python,
the exit status is 3 and stderr says which two settings to add by hand. Exit 2 for bad input, 3 when the settings file
is not valid JSON either (it is left alone).
"""

from __future__ import annotations

import json
import hashlib
import shutil
import sys
from pathlib import Path

STATE = ".kit-copied"                      # one persona/file per line: what the kit has copied into this folder
INTERPRETER = "python.defaultInterpreterPath"
INCLUDE = "python.interpreters.include"


class SettingsError(ValueError):
    """The Positron settings file is left alone; the message says why and what to do instead."""


def catalog(kit: Path) -> dict:
    """notebook/catalog.json, its notebooks grouped by persona (in the order they first appear) and in the order a new
    user opens them within each."""
    doc = json.loads((kit / "notebook" / "catalog.json").read_text(encoding="utf-8"))
    personas = list(dict.fromkeys(entry["persona"] for entry in doc["notebooks"]))
    doc["notebooks"] = sorted(doc["notebooks"], key=lambda entry: (personas.index(entry["persona"]), int(entry.get("step", 0))))
    return doc


def _placed(doc: dict) -> list[tuple[str, dict]]:
    """(folder, entry) for everything the copy places: the shared cells' folder first, then each persona's notebooks.
    A source file lives at <source>/<folder>/<file> and is copied to <base>/<folder>/<file>."""
    shared = doc.get("shared")
    return (([(shared["folder"], shared)] if shared else [])
            + [(entry["persona"], entry) for entry in doc["notebooks"]]
            + [(entry["folder"], entry) for entry in doc.get("examples", [])])


def persona_title(kit: Path, persona: str) -> str:
    """The persona's title from personas/<id>.json; the id when there is no such file."""
    try:
        return str(json.loads((kit / "personas" / f"{persona}.json").read_text(encoding="utf-8"))["title"])
    except (OSError, ValueError, KeyError):
        return persona


def _copied_before(base: Path) -> set[str]:
    try:
        return {line.strip() for line in (base / STATE).read_text(encoding="utf-8").splitlines() if line.strip()}
    except OSError:
        return set()


def copy(front: str, kit: Path, notebooks_dir: Path) -> tuple[list[str], list[str]]:
    """The kit's notebooks for a front end into their persona folders: (the ones added as persona/file, the problems).
    One already there is the user's; one the kit copied before and the user deleted is not brought back."""
    doc = catalog(kit)
    source = kit / doc["sources"][front]
    base = notebooks_dir / doc["folders"][front]
    before = _copied_before(base)
    added, problems, seen = [], [], set(before)
    for folder, entry in _placed(doc):
        name = entry.get(front)
        if not name or not (source / folder / name).is_file():
            continue                                     # a catalog entry this kit copy does not carry yet
        key = f"{folder}/{name}"
        target = base / folder / name
        if target.exists() or target.is_symlink():
            seen.add(key)                                # there (the kit's earlier copy, or the user's own): theirs
            continue
        if key in before:
            continue                                     # copied once, then deleted by the user: it stays deleted
        if target.parent.exists() and not target.parent.is_dir():
            problems.append(f"{key}: {target.parent} is a file where its folder should be")
            continue
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / folder / name, target)
        except OSError as err:
            problems.append(f"{key}: {err.strerror or err}")
            continue
        added.append(key)
        seen.add(key)
    # Retire only unchanged copies from the old utility slots. Edited files
    # remain the user's; a new example is copied before its old copy is removed.
    for entry in doc.get("examples", []):
        old = entry.get("previous", {}).get(front, {})
        old_key = old.get("path", "")
        previous = base / old_key
        current = base / entry["folder"] / entry[front]
        try:
            if (old_key in before and previous.is_file() and not previous.is_symlink()
                    and current.is_file() and not current.is_symlink()
                    and previous.resolve().is_relative_to(base.resolve())
                    and not base.is_symlink()
                    and not any(parent.is_symlink() for parent in previous.parents
                                if parent != base and parent.is_relative_to(base))
                    and hashlib.sha256(previous.read_bytes()).hexdigest() == old.get("sha256")):
                previous.unlink()
                seen.discard(old_key)
        except OSError as err:
            problems.append(f"{old_key}: {err.strerror or err}")
    # The full official example library is prebuilt into this kit copy.
    # It is optional only for older kit copies; installation never fetches it.
    library = kit / "notebook" / "examples" / front
    library_added = False
    if library.is_dir():
        for origin in sorted(library.rglob("*")):
            if not origin.is_file():
                continue
            relative = origin.relative_to(library).as_posix()
            key = relative if relative.startswith("public/") else "exasol-examples/" + relative
            target = base / key
            if target.exists() or target.is_symlink():
                seen.add(key)
                continue
            if key in before:
                continue
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(origin, target)
                seen.add(key)
                library_added = True
            except OSError as err:
                problems.append(f"{key}: {err.strerror or err}")
        if library_added:
            added.append("exasol-examples")
    # Runnable notebooks are the bundle. The source manifest stays in the
    # kit, outside the user's notebook browser. Remove only our unchanged old
    # manifest copy; a file the user edited remains theirs.
    legacy = base / "upstream-sources.json"
    origin = kit / "notebook" / legacy.name
    if legacy.name in before and legacy.is_file() and not legacy.is_symlink() and origin.is_file():
        try:
            if legacy.read_bytes() == origin.read_bytes():
                legacy.unlink()
                seen.discard(legacy.name)
        except OSError as err:
            problems.append(f"{legacy.name}: {err.strerror or err}")
    # Keep the lesson guide and required license notices alongside the bundle.
    for name in ("EXAMPLE-GUIDE.md", "UPSTREAM-LICENSE.txt", "INSTALL-AND-UPDATE.md", "MODEL-PROVIDERS.md"):
        origin, target = kit / "notebook" / name, base / name
        if not origin.is_file() or target.exists() or target.is_symlink() or name in before:
            continue
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(origin, target)
            seen.add(name)
            added.append(name)
        except OSError as err:
            problems.append(f"{name}: {err.strerror or err}")
    if front == "jupyter":                           # Marimo would list a README as a notebook of its own
        try:
            write_readme(kit, doc, base)
        except OSError as err:
            problems.append(f"README.md: {err.strerror or err}")
    if seen != before and base.is_dir():
        try:
            (base / STATE).write_text("".join(f"{key}\n" for key in sorted(seen)), encoding="utf-8")
        except OSError as err:
            problems.append(f"{STATE}: {err.strerror or err}")
    return added, problems


def write_readme(kit: Path, doc: dict, folder: Path) -> None:
    """A README naming each persona folder and the order to open its notebooks in; written once, then the user's.
    It names only the notebooks this kit copy carries."""
    readme = folder / "README.md"
    if readme.exists() or not folder.is_dir():
        return
    source = kit / doc["sources"]["jupyter"]
    lines = ["# The starter kit's notebooks", "", "One folder per persona; open its notebooks in this order, `00_quickstart` first.", ""]
    persona = None
    for entry in doc["notebooks"]:
        if not entry.get("jupyter") or not (source / entry["persona"] / entry["jupyter"]).is_file():
            continue
        if entry["persona"] != persona:
            persona = entry["persona"]
            lines += ([""] if lines[-1] else []) + [f"## {persona}/ ({persona_title(kit, persona)})", ""]
        lines.append(f"{int(entry['step']):02d}. `{persona}/{entry['jupyter']}` - {entry['title']}: {entry['summary']}")
        lines.append(f"    Needs: {entry['needs']}")
        if entry.get("upstream"):
            lines.append(f"    Adapted from [Exasol Notebook Connector / AI Lab]({entry['upstream']}); see UPSTREAM-LICENSE.txt.")
    if (kit / "notebook/examples/jupyter/00_library.ipynb").is_file():
        lines += ["", "## Full Exasol example library", "",
                  "Open [exasol-examples/00_library.ipynb](exasol-examples/00_library.ipynb) for all 50 official lessons,",
                  "their prerequisites and the recommended order. The same library is bundled for Marimo."]
    if doc.get("examples"):
        lines += ["", "## Useful notebooks", "", "Optional lessons, separate from the BRD persona sequence:", ""]
        for entry in doc["examples"]:
            lines.append(f"- `{entry['folder']}/{entry['jupyter']}` - {entry['title']}")
    shared = doc.get("shared")
    if shared and (source / shared["folder"] / shared["jupyter"]).is_file():
        lines += ["", f"`{shared['folder']}/{shared['jupyter']}` - {shared['title']}: {shared['summary']}"]
    lines += ["", "Every notebook connects with `import exakit.nb as nb; conn = nb.connect()` - no host, user or password.",
              "These files are yours: the kit never overwrites them, and one you delete is not copied again.",
              "Your own notebooks can go anywhere in the notebooks folder.",
              "", "Also: `exakit notebook marimo` (the same notebooks in Marimo), `exakit notebook positron` (this folder in",
              "Positron, with the kit's Python).", ""]
    readme.write_text("\n".join(lines), encoding="utf-8")


def _strip_jsonc(text: str) -> tuple[str, bool]:
    """JSON from VS Code's JSONC: comments outside strings and trailing commas removed. Returns (json, had comments)."""
    out, i, n, comments = [], 0, len(text), False
    while i < n:
        ch = text[i]
        if ch == '"':                                    # a string, copied as it is, escapes included
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            comments = True
            while i < n and text[i] not in "\r\n":
                i += 1
        elif text.startswith("/*", i):
            comments = True
            end = text.find("*/", i + 2)
            if end < 0:
                raise SettingsError("has a /* comment that is never closed")
            out.append(" ")
            i = end + 2
        elif ch == ",":                                  # a trailing comma: the next thing that is not blank closes
            j = i + 1
            while j < n:
                if text[j].isspace():
                    j += 1
                elif text.startswith("//", j):
                    while j < n and text[j] not in "\r\n":
                        j += 1
                elif text.startswith("/*", j):
                    end = text.find("*/", j + 2)
                    j = n if end < 0 else end + 2
                else:
                    break
            if j >= n or text[j] not in "}]":
                out.append(ch)
            i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out), comments


def _read_settings(path: Path) -> tuple[dict, bool]:
    """The settings file as a dict ({} when it is missing or blank) and whether it holds comments."""
    if not path.is_file():
        return {}, False
    try:
        text = path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as err:
        raise SettingsError(f"cannot be read ({err})") from err
    if not text.strip():
        return {}, False
    plain, comments = _strip_jsonc(text)
    try:
        doc = json.loads(plain) if plain.strip() else {}
    except ValueError as err:
        raise SettingsError(f"is not valid JSON ({err})") from err
    if not isinstance(doc, dict):
        raise SettingsError("is not a JSON object")
    return doc, comments


def _includes(value) -> list[str]:
    """python.interpreters.include as a list of paths, whatever shape the file gave it."""
    if isinstance(value, str):
        return [value] if value else []
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str) and item]
    return []


def positron(notebooks_dir: Path, python: str, venv: str) -> Path:
    """The notebooks folder as a Positron workspace whose interpreter is the kit's notebook Python; the file's other
    settings stay. SettingsError, the file untouched, when it cannot be rewritten safely."""
    path = notebooks_dir / ".vscode" / "settings.json"
    doc, comments = _read_settings(path)
    includes = _includes(doc.get(INCLUDE))
    if doc.get(INTERPRETER) == python and venv in includes and isinstance(doc.get(INCLUDE), list):
        return path                                      # already set: nothing to write
    if comments:
        raise SettingsError(f"has comments, which rewriting it would lose. Add these two settings to it yourself: "
                            f"\"{INTERPRETER}\": {json.dumps(python)} and \"{INCLUDE}\": [{json.dumps(venv)}]")
    doc[INTERPRETER] = python
    doc[INCLUDE] = includes + ([venv] if venv not in includes else [])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    return path


def positron_remove(notebooks_dir: Path, python: str, venv: str) -> str:
    """The kit's two settings out of the folder's settings file again (an uninstall): the interpreter only when it is
    the kit's Python, the kit's venv from the include list. The user's other settings stay; a file left empty goes.
    Returns what was done: removed|unchanged|absent."""
    path = notebooks_dir / ".vscode" / "settings.json"
    if not path.is_file():
        return "absent"
    doc, comments = _read_settings(path)
    changed = dict(doc)
    if changed.get(INTERPRETER) == python:
        del changed[INTERPRETER]
    if INCLUDE in changed:
        includes = _includes(changed[INCLUDE])
        if venv in includes:
            includes = [item for item in includes if item != venv]
            if includes:
                changed[INCLUDE] = includes
            else:
                del changed[INCLUDE]
    if changed == doc:
        return "unchanged"
    if comments:
        raise SettingsError(f"has comments, so the kit leaves it alone. Remove \"{INTERPRETER}\" and \"{INCLUDE}\" "
                            "from it yourself: they name the notebook environment the uninstall removed")
    if changed:
        path.write_text(json.dumps(changed, indent=2) + "\n", encoding="utf-8")
    else:
        path.unlink()
        try:
            path.parent.rmdir()
        except OSError:
            pass
    return "removed"


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[0] == "copy" and argv[1] in ("jupyter", "marimo"):
        try:
            added, problems = copy(argv[1], Path(argv[2]), Path(argv[3]))
        except (OSError, ValueError, KeyError) as err:
            print(f"the kit's notebooks could not be placed: {err}", file=sys.stderr)
            return 1
        for line in added:
            print(line)
        for problem in problems:
            print(f"could not copy {problem}", file=sys.stderr)
        return 1 if problems else 0
    if len(argv) == 4 and argv[0] in ("positron", "positron-remove"):
        settings = Path(argv[1]) / ".vscode" / "settings.json"
        try:
            if argv[0] == "positron":
                print(positron(Path(argv[1]), argv[2], argv[3]))
            else:
                print(positron_remove(Path(argv[1]), argv[2], argv[3]))
        except SettingsError as err:
            if argv[0] == "positron":
                print(f"{settings} {err} - the kit leaves it alone; choose the interpreter {argv[2]} in Positron yourself",
                      file=sys.stderr)
            else:
                print(f"{settings} {err}", file=sys.stderr)
            return 3
        except OSError as err:
            print(f"{settings} could not be written: {err}", file=sys.stderr)
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
