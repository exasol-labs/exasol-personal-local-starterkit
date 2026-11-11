"""Excel (.xlsx) to CSV, with Python's standard library only.

The kit's loader takes CSV, Parquet and JSON. The guided view accepts an Excel file
by turning one sheet into a CSV beside it, then loading that CSV the kit's way.
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
