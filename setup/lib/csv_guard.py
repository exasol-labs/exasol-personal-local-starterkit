"""What the kit checks in a user's CSV before exapump loads it.

One implementation for both twins (exapump.sh and exapump.ps1 run it).

    csv_guard.py lf <source.csv> <target.csv> [<delimiter>]

Writes <target.csv>: the same bytes with every CRLF that ENDS A RECORD made LF
(<delimiter> defaults to a comma; "tab" or "\\t" for a tab).
exapump 0.14.0 has no row-separator option and builds its IMPORT for LF, so a
file saved on Windows (Excel, Notepad) arrived with a carriage return on the
last value of every row: a numeric last column failed the whole load
("Transformation of value='10.5<CR>' failed"), a text one loaded with CR
inside every value. A CRLF inside a quoted field is data and stays as it is.
Exit 0 when written, 2 when the source cannot be read, 3 when a quoted field
never closes (record ends after it were left as CRLF, so the caller loads the
original and keeps its CRLF warning).

    csv_guard.py numbers <file.csv> <delimiter>

Prints "<position>\t<column>\t<reason>" for every column whose values the
loader would turn into WRONG NUMBERS. exapump infers the column types and has
no option for a decimal comma, a thousands separator or a column type, so a
German export loaded "1.234" (one thousand two hundred and thirty-four) as
1.234 and "12.500" as 12.5, and "0000001237" or the postcode "01067" as 1237
and 1067 - each under a verified row count and a green check. Two shapes:
  - leading zeros: a value like 007 or 01067 is a code, not a number;
  - a dot as thousands separator: 1.234 or 12.500 in a file that is not
    comma-separated (';' and tab files come from locales that write the
    decimal comma), where the dot cannot be a decimal point the loader reads.
A column with either is kept as text; the caller decides from exapump's own
inferred types whether that changes anything.

    csv_guard.py ddl <dry-run-output> <numbers-output> <ddl-out>

Reads exapump's `upload --dry-run` output and the "numbers" lines, and writes
to <ddl-out> the CREATE TABLE exapump would run, with each listed column that
it inferred as a number made VARCHAR(2000000). Prints "<column>\t<reason>" for
each column it changed; writes nothing when none needed changing.
"""

import csv
import re
import sys

ROWS_READ = 1_000_000   # values looked at per column, from the top
LEADING_ZERO = re.compile(r"^[+-]?0[0-9]+$")
THOUSANDS_DOT = re.compile(r"^[+-]?[0-9]{1,3}(\.[0-9]{3})+$")


def to_lf(source, target, delimiter=b",", quote=b'"'):
    """Copy source to target, CRLF -> LF at the end of each record only.

    A record ends at a newline that is outside a quoted field. The quote state
    follows the CSV grammar exapump's parser uses: a quote OPENS a field only
    at the start of a field (the start of a record, or right after the
    delimiter); inside a quoted field a doubled quote is an escaped quote and a
    single one closes it. A quote anywhere else is data - an inch mark in
    `1,27" monitor,4` must not make every later record look quoted.

    Returns True when every record end was converted, False when the file ends
    inside a quoted field that never closed: the CRLFs after its opening quote
    were kept, so the caller must not treat the copy as converted.
    """
    inside = False
    first = True
    with open(source, "rb") as src, open(target, "wb") as out:
        for line in src:
            start = 0
            if first:
                first = False
                if line.startswith(b"\xef\xbb\xbf"):
                    start = 3
            pos = line.find(quote, start)
            while pos != -1:
                if inside:
                    if line[pos + 1:pos + 2] == quote:
                        pos = line.find(quote, pos + 2)
                        continue
                    inside = False
                elif pos == start or line[pos - 1:pos] == delimiter:
                    inside = True
                pos = line.find(quote, pos + 1)
            if not inside and line.endswith(b"\r\n"):
                line = line[:-2] + b"\n"
            elif not inside and line.endswith(b"\r"):
                # The file's last record ended by a CR alone (no LF after it):
                # the CR is a line ending, not data, so it is made LF too.
                line = line[:-1] + b"\n"
            out.write(line)
    return not inside


def suspect_columns(path, delimiter):
    """[(position, name, reason)] for the columns that would load as wrong numbers."""
    csv.field_size_limit(min(sys.maxsize, 2**31 - 1))
    found = {}
    with open(path, encoding="utf-8-sig", errors="replace", newline="") as handle:
        reader = csv.reader(handle, delimiter=delimiter, quotechar='"')
        header = next(reader, None)
        if not header:
            return []
        for count, row in enumerate(reader):
            if count >= ROWS_READ:
                break
            for i, raw in enumerate(row[:len(header)]):
                if i in found:
                    continue
                value = raw.strip()
                if not value:
                    continue
                if LEADING_ZERO.match(value):
                    found[i] = f"leading zeros ({value}) would be dropped"
                elif delimiter != "," and THOUSANDS_DOT.match(value):
                    found[i] = f"{value} uses a dot as thousands separator and would load as a decimal"
    return [(i + 1, header[i].strip(), found[i]) for i in sorted(found)]


def text_ddl(dry_run_text, suspects):
    """(ddl, [(column, reason)]) - the dry-run CREATE TABLE with the suspect
    numeric columns made text, or (None, []) when nothing needed changing."""
    lines = dry_run_text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith("CREATE TABLE ")), None)
    if start is None:
        raise ValueError("no CREATE TABLE in the dry-run output")
    out, changed, position = [lines[start]], [], 0
    column = re.compile(r'^(\s*)("(?:[^"]|"")*")\s+(.+?)(,?)\s*$')
    for line in lines[start + 1:]:
        if line.strip().startswith(")"):
            out.append(")")
            break
        match = column.match(line)
        if not match:
            raise ValueError(f"unexpected dry-run line: {line!r}")
        position += 1
        indent, name, kind, comma = match.groups()
        if position in suspects and not kind.upper().startswith(("VARCHAR", "CHAR")):
            kind = "VARCHAR(2000000)"
            changed.append((name[1:-1].replace('""', '"'), suspects[position]))
        out.append(f"{indent}{name} {kind}{comma}")
    if not changed:
        return None, []
    return "\n".join(out), changed


def main(argv):
    if len(argv) == 4 and argv[1] == "numbers":
        delimiter = "\t" if argv[3] in ("\\t", "tab") else argv[3]
        try:
            for position, name, reason in suspect_columns(argv[2], delimiter):
                print(f"{position}\t{name}\t{reason}")
        except (OSError, csv.Error) as exc:
            print(f"cannot read the file: {exc}", file=sys.stderr)
            return 2
        return 0
    if len(argv) == 5 and argv[1] == "ddl":
        try:
            with open(argv[2], encoding="utf-8", errors="replace") as handle:
                dry_run = handle.read()
            suspects = {}
            with open(argv[3], encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    parts = line.rstrip("\n").split("\t", 2)
                    if len(parts) == 3 and parts[0].isdigit():
                        suspects[int(parts[0])] = parts[2]
            ddl, changed = text_ddl(dry_run, suspects)
        except (OSError, ValueError) as exc:
            print(f"cannot read the inferred schema: {exc}", file=sys.stderr)
            return 2
        if ddl:
            with open(argv[4], "w", encoding="utf-8") as handle:
                handle.write(ddl + "\n")
            for name, reason in changed:
                print(f"{name}\t{reason}")
        return 0
    if len(argv) in (4, 5) and argv[1] == "lf":
        delimiter = argv[4] if len(argv) == 5 else ","
        delimiter = "\t" if delimiter in ("\\t", "tab") else delimiter
        try:
            converted = to_lf(argv[2], argv[3], delimiter.encode())
        except OSError as exc:
            print(f"cannot rewrite line endings: {exc}", file=sys.stderr)
            return 2
        if not converted:
            print("a quoted field opens and never closes: line endings after it were left as they are",
                  file=sys.stderr)
            return 3
        return 0
    print("usage: csv_guard.py lf <source> <target> [<delimiter>] | numbers <file> <delimiter> | ddl <dry-run> <numbers> <ddl-out>",
          file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
