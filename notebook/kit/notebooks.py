"""The kit's notebooks into the user's notebooks folder, one folder per persona, and the folder prepared for Positron.
Standard-library helper for the Python marketplace.

    python notebooks.py copy <jupyter|marimo> <kit_root> <notebooks_dir> [personas]
                                       prints persona/file for each one added; personas: comma-separated ids
    python notebooks.py positron <notebooks_dir> <python> <venv>           .vscode/settings.json names the kit's Python
    python notebooks.py positron-remove <notebooks_dir> <python> <venv>    takes the kit's two settings out again
    python notebooks.py list <kit_root>                                    step|persona|title|jupyter file|marimo file

What goes where is notebook/catalog.json: the picked personas' Jupyter notebooks into
<notebooks_dir>/starter-kit-notebooks/<persona>/ with a README naming the order to open them in, the Marimo ones into
<notebooks_dir>/marimo/<persona>/; a persona added later brings its folder on the next copy (no persona with
notebooks picked: all of them). A catalog entry whose file this kit copy does not carry is skipped. A kit notebook
nobody edited is refreshed when the kit's version changes (its cells are compared, not its outputs: running it is not
editing it); one the user edited, or a file of their own, is never overwritten; the README is rewritten only while it
is what the kit wrote. What the kit copied is recorded in
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

STATE = ".kit-copied"                      # one "persona/file<TAB>cells digest" per line: what the kit copied here
OLD_README_HEADING = "# The starter kit's notebooks"   # what kits before the marker wrote, once
README_STATE = ".kit-readme"               # the sha256 of the README the kit last wrote: rewritten only while unchanged
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
    doc["disabled"] = sorted(p for p in personas if not _visible(kit, p))
    return doc


def _visible(kit: Path, persona: str) -> bool:
    """False for a persona its file switches off ("visible": false: kept, not offered); True otherwise."""
    try:
        return json.loads((kit / "personas" / f"{persona}.json").read_text(encoding="utf-8-sig")).get("visible", True) is not False
    except (OSError, ValueError):
        return True


def wanted(doc: dict, personas: set[str] | None, fresh: bool = True) -> set[str]:
    """The personas whose notebooks are copied: the ones picked that have notebooks. When none of them has any, every
    persona's - but only into a fresh folder (``fresh``), so installing the add-on on its own still brings them all,
    while a kit left with General after `persona remove data-scientist` is not handed the ML Engineer's (DAY-04)."""
    # A disabled persona's notebooks come only to a kit that already has that persona.
    have = {entry["persona"] for entry in doc["notebooks"]} - (set(doc.get("disabled") or ()) - set(personas or ()))
    if not personas:
        return have                                  # no persona recorded: the add-on on its own brings them all
    return (have & personas) or (have if fresh else set())


def _placed(doc: dict, personas: set[str] | None = None, fresh: bool = True) -> list[tuple[str, dict]]:
    """(folder, entry) for everything the copy places: the picked personas' notebooks.
    A source file lives at <source>/<folder>/<file> and is copied to <base>/<folder>/<file>. The shared cells
    (00_shared/) are build input only: each quickstart already carries them."""
    keep = wanted(doc, personas, fresh)
    return [(entry["persona"], entry) for entry in doc["notebooks"] if entry["persona"] in keep]


def persona_title(kit: Path, persona: str) -> str:
    """The persona's title from personas/<id>.json; the id when there is no such file."""
    try:
        return str(json.loads((kit / "personas" / f"{persona}.json").read_text(encoding="utf-8"))["title"])
    except (OSError, ValueError, KeyError):
        return persona


def _copied_before(base: Path) -> dict[str, str]:
    """{persona/file: the digest of the cells the kit copied} ("" from an older kit, which kept names only)."""
    try:
        lines = (base / STATE).read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    return {key.strip(): digest.strip() for key, _, digest in (line.partition("\t") for line in lines) if key.strip()}


def cells_digest(path: Path) -> str:
    """What a notebook says, not what running it left: a .ipynb's cell types and sources (outputs, execution counts
    and metadata do not count), any other file as it is."""
    raw = path.read_bytes()
    if path.suffix == ".ipynb":
        try:
            cells = json.loads(raw).get("cells", [])
            raw = json.dumps([(c.get("cell_type"), "".join(c.get("source", ""))) for c in cells]).encode("utf-8")
        except (ValueError, AttributeError):
            pass
    return hashlib.sha256(raw).hexdigest()


def copy(front: str, kit: Path, notebooks_dir: Path, personas: set[str] | None = None) -> tuple[list[str], list[str]]:
    """The picked personas' notebooks for a front end into their folders: (the ones added as persona/file, the
    problems). A persona added later brings its folder on the next copy. One already there is the user's; one the kit
    copied before and the user deleted is not brought back."""
    doc = catalog(kit)
    source = kit / doc["sources"][front]
    base = notebooks_dir / doc["folders"][front]
    before = _copied_before(base)
    added, problems, seen = [], [], dict(before)
    have = {entry["persona"] for entry in doc["notebooks"]}
    fresh = not any(key.split("/", 1)[0] in have for key in before)     # no persona's notebooks copied here yet
    for folder, entry in _placed(doc, personas, fresh):
        name = entry.get(front)
        if not name or not (source / folder / name).is_file():
            continue                                     # a catalog entry this kit copy does not carry yet
        key = f"{folder}/{name}"
        target = base / folder / name
        if target.exists() or target.is_symlink():
            if key not in before or target.is_symlink():
                seen.setdefault(key, "")                 # a file of the user's own with the kit's name: theirs
                continue
            fresh, there = cells_digest(source / folder / name), cells_digest(target)
            if not before[key]:                          # an older kit's record: adopted only when it is the kit's now
                seen[key] = fresh if there == fresh else ""
                continue
            if there != before[key] or fresh == there:
                continue                                 # edited by the user (theirs), or already the kit's latest
            try:
                shutil.copyfile(source / folder / name, target)
            except OSError as err:
                problems.append(f"{key}: {err.strerror or err}")
                continue
            seen[key] = fresh
            added.append(f"{key} (updated)")
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
        seen[key] = cells_digest(target)
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
                seen.setdefault(key, before.get(key, ""))
                continue
            if key in before:
                continue
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(origin, target)
                seen[key] = ""
                library_added = True
            except OSError as err:
                problems.append(f"{key}: {err.strerror or err}")
        if library_added:
            added.append("exasol-examples")
    if front == "jupyter":                           # Marimo would list a README as a notebook of its own
        try:
            write_readme(kit, doc, base, personas, fresh)
        except OSError as err:
            problems.append(f"README.md: {err.strerror or err}")
    if seen != before and base.is_dir():
        try:
            (base / STATE).write_text("".join(f"{key}\t{seen[key]}\n" if seen[key] else f"{key}\n"
                                              for key in sorted(seen)), encoding="utf-8")
        except OSError as err:
            problems.append(f"{STATE}: {err.strerror or err}")
    return added, problems


def readme_text(kit: Path, doc: dict, personas: set[str] | None = None, fresh: bool = True,
                present: set[str] | None = None) -> str:
    """The folder's README: the picked personas' notebooks, and those of any persona folder still there (``present``),
    in the order to open them, and the few things to know. Only notebooks this kit copy carries."""
    source = kit / doc["sources"]["jupyter"]
    keep = wanted(doc, personas, fresh) | (present or set())
    lines = ["# Your notebooks", "", "Open them in order, `00_quickstart` first.", ""]
    persona = None
    for entry in doc["notebooks"]:
        if entry["persona"] not in keep or not entry.get("jupyter") or not (source / entry["persona"] / entry["jupyter"]).is_file():
            continue
        if entry["persona"] != persona:
            persona = entry["persona"]
            lines += ([""] if lines[-1] else []) + [f"## {persona_title(kit, persona)} - `{persona}/`", ""]
        needs = f" (needs {entry['needs']})" if entry.get("needs") else ""
        lines.append(f"{int(entry['step']):02d}. `{entry['jupyter']}` - {entry['title']}{needs}")
    if (kit / "notebook/examples/jupyter/00_library.ipynb").is_file():
        lines += ["", "## Exasol examples", "", "`exasol-examples/00_library.ipynb` - the 50 official lessons, in order."]
    lines += ["", "## Good to know", "",
              "- Connect: `import exakit.nb as nb; conn = nb.connect()` - no host, user or password.",
              "- A model for the AI steps: set `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL` and",
              "  `EXAKIT_PROVIDER_API_KEY` before `exakit notebook` (Claude: `https://api.anthropic.com/v1/`;",
              "  Ollama: its `/v1/` address, no key).",
              "- Langfuse traces: set `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_BASE_URL` the same way.",
              "- JupyterLab reads these only when it starts. Already running? Set them in a terminal, then run",
              "  `exakit notebook stop && exakit notebook` there (a kernel restart is not enough).",
              "- Marimo: `exakit notebook marimo`.",
              "- These files are yours: one you edit is kept as it is, one you have not edited takes the kit's",
              "  newer version on update, and one you delete is not copied back."]
    return "\n".join(lines) + "\n"


def write_readme(kit: Path, doc: dict, folder: Path, personas: set[str] | None = None, fresh: bool = True) -> None:
    """Write the README; rewrite it when the personas change, but only while it is exactly what the kit wrote -
    once edited it is the user's."""
    readme = folder / "README.md"
    if not folder.is_dir():
        return
    marker = folder / README_STATE
    if not marker.exists() and readme.is_file() and not readme.is_symlink():
        # An older kit wrote it once, with no marker, under this heading; it still names useful-notebooks/ and
        # Positron. It is kept beside as README.old.md and the current one is written (audit DAY-02).
        try:
            first = readme.read_text(encoding="utf-8").splitlines()[:1]
        except (OSError, UnicodeDecodeError):
            first = []
        if first == [OLD_README_HEADING] and not (folder / "README.old.md").exists():
            readme.rename(folder / "README.old.md")
    if readme.exists() or readme.is_symlink():
        try:
            ours = marker.read_text(encoding="utf-8").strip()
            unchanged = not readme.is_symlink() and hashlib.sha256(readme.read_bytes()).hexdigest() == ours
        except OSError:
            unchanged = False
        if not unchanged:
            return
    have = {entry["persona"] for entry in doc["notebooks"]}
    present = {child.name for child in folder.iterdir() if child.is_dir() and child.name in have}
    text = readme_text(kit, doc, personas, fresh, present)
    readme.write_text(text, encoding="utf-8")
    marker.write_text(hashlib.sha256(text.encode("utf-8")).hexdigest() + "\n", encoding="utf-8")


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
    if len(argv) in (4, 5) and argv[0] == "copy" and argv[1] in ("jupyter", "marimo"):
        personas = {part for part in argv[4].split(",") if part} if len(argv) == 5 else None
        try:
            added, problems = copy(argv[1], Path(argv[2]), Path(argv[3]), personas)
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
