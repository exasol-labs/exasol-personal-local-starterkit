"""Files the kit's loader cannot take as they are, made loadable: Excel (.xlsx) to CSV, and a CSV saved in another
encoding to a UTF-8 copy. Python's standard library only.

load_own_file calls loadable() first, so a cell and the guided view load an Excel file or a cp1252 CSV the same
way: one sheet becomes a CSV beside the file, a non-UTF-8 CSV gets a UTF-8 copy, and the original stays untouched.
Streaming XML, so large sheets don't need much memory. Excel stores dates as
day numbers (44834.32 = 2022-09-30 07:45); columns named like a date or time
whose values are all day numbers are written as real dates.
"""

from __future__ import annotations

import csv
import re
import zipfile
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta
from pathlib import Path

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
EXCEL_EPOCH = datetime(1899, 12, 30)
DATE_NAME = re.compile(r"(date|time|created|updated|_at$|^at$|day)", re.I)


def _col_index(ref: str) -> int:
    letters = re.match(r"[A-Z]+", ref).group(0)
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def sheets(path: str | Path) -> list[str]:
    with zipfile.ZipFile(path) as z:
        wb = z.read("xl/workbook.xml").decode("utf-8", "ignore")
    return re.findall(r'<sheet [^>]*name="([^"]+)"', wb)


def _sheet_file(z: zipfile.ZipFile, sheet: str | None) -> tuple[str, str]:
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
    targets = {r.get("Id"): r.get("Target") for r in rels}
    entries = [(s.get("name"), targets.get(s.get(REL + "id"))) for s in wb.iter(NS + "sheet")]
    if not entries:
        raise ValueError("This Excel file has no sheets.")
    name, target = next(((n, t) for n, t in entries if n == sheet), entries[0])
    target = target.lstrip("/")
    return name, target if target.startswith("xl/") else f"xl/{target}"


def to_csv(path: str | Path, sheet: str | None = None, out: str | Path | None = None) -> dict:
    """Write one sheet as CSV (UTF-8, LF line ends). Returns {csv, sheet, rows, columns, dates, other_sheets}."""
    path = Path(path).expanduser()
    with zipfile.ZipFile(path) as z:
        name, member = _sheet_file(z, sheet)
        shared: list[str] = []
        if "xl/sharedStrings.xml" in z.namelist():
            for _ev, el in ET.iterparse(z.open("xl/sharedStrings.xml")):
                if el.tag == NS + "si":
                    shared.append("".join(t.text or "" for t in el.iter(NS + "t")))
                    el.clear()

        def value(c) -> str:
            t = c.get("t")
            if t == "inlineStr":
                return "".join(x.text or "" for x in c.iter(NS + "t"))
            v = c.find(NS + "v")
            if v is None or v.text is None:
                return ""
            if t == "s":
                return shared[int(v.text)]
            if t == "b":
                return "true" if v.text == "1" else "false"
            return v.text

        rows: list[list[str]] = []
        width = 0
        for _ev, el in ET.iterparse(z.open(member)):
            if el.tag == NS + "row":
                cells: dict[int, str] = {}
                for i, c in enumerate(el.findall(NS + "c")):
                    ref = c.get("r")
                    cells[_col_index(ref) if ref else i] = value(c)
                if cells:
                    width = max(width, max(cells) + 1)
                rows.append([cells.get(i, "") for i in range(max(cells) + 1 if cells else 0)])
                el.clear()
        others = [s for s in sheets(path) if s != name]

    if not rows:
        raise ValueError(f"The sheet {name} is empty.")
    header = [h.strip() or f"COLUMN_{i + 1}" for i, h in enumerate(rows[0] + [""] * (width - len(rows[0])))]
    body = [r + [""] * (width - len(r)) for r in rows[1:]]
    body = [r for r in body if any(x.strip() for x in r)]

    # Excel day numbers -> dates, for columns named like a date whose filled values are all day numbers.
    dates = []
    for j, h in enumerate(header):
        if not DATE_NAME.search(h):
            continue
        filled = [r[j] for r in body if r[j].strip()]
        try:
            nums = [float(x) for x in filled]
        except ValueError:
            continue
        if filled and all(20000 <= n <= 80000 for n in nums):
            for r in body:
                if r[j].strip():
                    d = EXCEL_EPOCH + timedelta(days=float(r[j]))
                    r[j] = d.strftime("%Y-%m-%d %H:%M:%S") if d.time() != datetime.min.time() else d.strftime("%Y-%m-%d")
            dates.append(h)

    target = Path(out) if out else path.with_suffix(".csv")
    with target.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(header)
        w.writerows(body)
    return {"csv": str(target), "sheet": name, "rows": len(body), "columns": len(header), "dates": dates, "other_sheets": others}


EXCEL = (".xlsx", ".xlsm")
TEXT = (".csv", ".txt", ".tsv")


def free_name(target: Path, tag: str) -> Path:
    """target itself if it does not exist yet, else target with a tag: never overwrite someone's file."""
    if not target.exists():
        return target
    for i in range(1, 100):
        alt = target.with_name(f"{target.stem}{tag}{'' if i == 1 else f'-{i}'}{target.suffix}")
        if not alt.exists():
            return alt
    raise ValueError(f"Too many converted copies next to {target.name}. Remove some and try again.")


def utf8_copy(path: str | Path) -> tuple[Path | None, str]:
    """The kit reads strict UTF-8. A text file saved in another encoding gets a UTF-8 copy beside it (LF line ends);
    (None, "") when it is UTF-8 already."""
    path = Path(path).expanduser()
    raw = path.read_bytes()
    try:
        raw.decode("utf-8")
        return None, ""
    except UnicodeDecodeError:
        pass
    text = raw.decode("cp1252", errors="strict") if _decodes(raw, "cp1252") else raw.decode("latin-1")
    out = free_name(path.with_name(path.stem + ".utf8" + path.suffix), "")
    out.write_text(text.replace("\r\n", "\n"), encoding="utf-8")
    return out, f"{path.name} was not saved as UTF-8 (the kit needs that), so a UTF-8 copy, {out.name}, was loaded instead."


def _decodes(raw: bytes, encoding: str) -> bool:
    try:
        raw.decode(encoding)
        return True
    except UnicodeDecodeError:
        return False


def loadable(path: str | Path, sheet: str | None = None) -> tuple[Path, list[str]]:
    """The file to load for ``path``, and a note per change made: an Excel sheet becomes a CSV beside it, a non-UTF-8
    CSV a UTF-8 copy. Any other file comes back as it is, with no note."""
    path = Path(path).expanduser()
    notes: list[str] = []
    if path.suffix.lower() in EXCEL:
        made = to_csv(path, sheet, out=free_name(path.with_suffix(".csv"), ".from-excel"))
        notes.append(f"The Excel sheet \u201c{made['sheet']}\u201d became {Path(made['csv']).name} "
                     f"({made['rows']:,} rows, {made['columns']} columns), and that was loaded.")
        if made["dates"]:
            notes.append(f"Excel day numbers in {', '.join(made['dates'])} became real dates.")
        if made["other_sheets"]:
            notes.append(f"Other sheets were not loaded: {', '.join(made['other_sheets'])}.")
        path = Path(made["csv"])
    if path.suffix.lower() in TEXT:
        fixed, why = utf8_copy(path)
        if fixed:
            path = fixed
            notes.append(why)
    return path, notes
