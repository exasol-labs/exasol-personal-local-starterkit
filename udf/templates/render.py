"""Fill a UDF template in this folder (score_model.sql) and print, or return, the CREATE statement.

Every value is checked before it lands in SQL: names are plain SQL names (not reserved words), types are SQL type
names, the model path is a /buckets path. A placeholder left unfilled - or one the template has that this renderer does
not know - is refused with its name, so a half-rendered UDF never reaches the database. Standard library only.

From Python (a notebook):

    import render
    sql = render.render(schema="SCORING", name="SCORE_CHURN", model_path="/buckets/bfsdefault/default/models/churn.pkl",
                        inputs=[("category", "VARCHAR(2000)"), ("doc_text", "VARCHAR(2000000)", "text")],
                        output="DOUBLE", method="predict_proba")
    conn.execute(sql)

From a terminal (the statement ends with a line holding only '/', which SQL clients such as DBeaver want after a script;
--no-slash leaves it off):

    python3 render.py --schema SCORING --name SCORE_CHURN --model-path /buckets/bfsdefault/default/models/churn.pkl \\
        --input category:VARCHAR(2000) --input doc_text:VARCHAR(2000000):text --output DOUBLE --method predict_proba

An input is (parameter, SQL type) or (parameter, SQL type, model feature): the parameter is the UDF's argument, the
feature the column name the model was trained on (the parameter's own name when left out). TEXT, DATA and VALUE are
reserved words in Exasol, so a model trained on a "text" column takes a parameter such as doc_text with feature "text".
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATE = "score_model.sql"
METHODS = ("predict", "predict_proba")
_PLACEHOLDER = re.compile(r"\{\{([A-Z_]+)\}\}")
_IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
_TYPE = re.compile(r"^(BOOLEAN|BOOL|CHAR|CHARACTER|VARCHAR|CHARACTER VARYING|NVARCHAR|VARCHAR2|DECIMAL|DEC|NUMERIC|"
                   r"NUMBER|INT|INTEGER|BIGINT|SMALLINT|TINYINT|DOUBLE|DOUBLE PRECISION|FLOAT|REAL|DATE|TIMESTAMP|"
                   r"TIMESTAMP WITH LOCAL TIME ZONE)(\(\s*\d{1,7}\s*(,\s*\d{1,3}\s*)?\))?( (UTF8|ASCII))?$", re.IGNORECASE)
_BUCKETS = re.compile(r"^/buckets/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$")
_FEATURE = re.compile(r"^[^\x00-\x1f'\"\\]{1,128}$")


class Refused(ValueError):
    """A value the renderer will not put into SQL; the message names the placeholder and what is wrong."""


def _reserved() -> set[str]:
    """Exasol's reserved words, from the kit's list (tools/exasol_reserved_words.txt) when this runs inside the kit."""
    words = HERE.parents[1] / "tools" / "exasol_reserved_words.txt"
    try:
        lines = words.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {"TEXT", "DATA", "VALUE", "SELECT", "FROM", "TABLE", "ORDER", "GROUP"}
    return {line.strip().upper() for line in lines if line.strip() and not line.startswith("#")}


def _name(value, placeholder: str, reserved: set[str]) -> str:
    text = "" if value is None else str(value).strip()
    if not text:
        raise Refused(f"{placeholder} is not filled.")
    if not _IDENT.match(text):
        raise Refused(f"{placeholder} '{text}' is not a plain SQL name (a letter, then letters, digits or _).")
    if text.upper() in reserved:
        raise Refused(f"{placeholder} '{text}' is a reserved word in Exasol; pick another name (doc_text for text).")
    return text


def _type(value, placeholder: str) -> str:
    text = "" if value is None else " ".join(str(value).split())
    if not text:
        raise Refused(f"{placeholder} is not filled.")
    if not _TYPE.match(text):
        raise Refused(f"{placeholder} '{text}' is not an SQL type such as DOUBLE, DECIMAL(18,0) or VARCHAR(2000).")
    return text.upper()


def placeholders(template: str = TEMPLATE) -> list[str]:
    """The placeholders a template holds, in the order they first appear."""
    found: list[str] = []
    for name in _PLACEHOLDER.findall((HERE / template).read_text(encoding="utf-8")):
        if name not in found:
            found.append(name)
    return found


def render(schema=None, name=None, model_path=None, inputs=None, output=None, method="predict",
           language="PYTHON3", template: str = TEMPLATE) -> str:
    """The template's CREATE statement with every placeholder filled, as a driver sends it (no trailing '/')."""
    reserved = _reserved()
    if not inputs:
        raise Refused("INPUT_COLUMNS is not filled: name at least one input, (parameter, SQL type[, model feature]).")
    params, pairs = [], []
    for entry in inputs:
        entry = tuple(entry) if isinstance(entry, (list, tuple)) else (entry,)
        if len(entry) not in (2, 3):
            raise Refused(f"An input is (parameter, SQL type) or (parameter, SQL type, model feature), not {entry!r}.")
        param = _name(entry[0], "An input's parameter", reserved).lower()
        sql_type = _type(entry[1], f"The type of input {param}")
        feature = str(entry[2]) if len(entry) == 3 and entry[2] not in (None, "") else param
        if not _FEATURE.match(feature):
            raise Refused(f"The model feature '{feature}' of input {param} has quotes or control characters.")
        if param in [p for p, _ in pairs]:
            raise Refused(f"The input {param} is named twice.")
        params.append(f"{param} {sql_type}")
        pairs.append((param, feature))
    path = "" if model_path is None else str(model_path).strip()
    if not path:
        raise Refused("MODEL_PATH is not filled: the /buckets path exakit model put printed.")
    if not _BUCKETS.match(path) or "/../" in path + "/" or "/./" in path + "/":
        raise Refused(f"MODEL_PATH '{path}' is not a /buckets path such as /buckets/bfsdefault/default/models/model.pkl "
                      "(exakit model put prints it).")
    if method not in METHODS:
        raise Refused(f"METHOD '{method}' is not one of: {', '.join(METHODS)}.")
    values = {
        "LANGUAGE": _name(language, "LANGUAGE", reserved).upper(),
        "SCHEMA": _name(schema, "SCHEMA", reserved).upper(),
        "SCRIPT_NAME": _name(name, "SCRIPT_NAME", reserved).upper(),
        "INPUT_COLUMNS": ", ".join(params),
        "OUTPUT_TYPE": _type(output, "OUTPUT_TYPE"),
        "MODEL_PATH": repr(path),
        "INPUTS": repr(pairs),
        "METHOD": repr(method),
    }
    text = (HERE / template).read_text(encoding="utf-8")
    unknown = [p for p in placeholders(template) if p not in values]
    if unknown:
        raise Refused(f"{template} has placeholders this renderer does not fill: {', '.join(unknown)}.")
    rendered = _PLACEHOLDER.sub(lambda match: values[match.group(1)], text)
    left = _PLACEHOLDER.findall(rendered)
    if left:
        raise Refused(f"Placeholders left unfilled: {', '.join(sorted(set(left)))}.")
    # The comment header is for the reader of the template; the statement starts at CREATE.
    lines = rendered.splitlines()
    while lines and (lines[0].startswith("--") or not lines[0].strip()):
        lines.pop(0)
    return "\n".join(lines).rstrip() + "\n"


def _input(text: str) -> tuple[str, ...]:
    parts = text.split(":")
    if len(parts) not in (2, 3):
        raise argparse.ArgumentTypeError(f"'{text}' is not PARAMETER:TYPE or PARAMETER:TYPE:FEATURE")
    return tuple(parts)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="render.py", description=__doc__.split("\n\n")[0],
                                     epilog="Placeholders in score_model.sql: " + ", ".join(placeholders()))
    parser.add_argument("--schema", help="the schema the UDF is created in")
    parser.add_argument("--name", help="the UDF's name")
    parser.add_argument("--model-path", help="the /buckets path exakit model put printed")
    parser.add_argument("--input", action="append", type=_input, default=[], metavar="PARAMETER:TYPE[:FEATURE]",
                        help="one per UDF parameter, in order; FEATURE is the model's column name when it differs")
    parser.add_argument("--output", help="the SQL type the UDF returns (DOUBLE for a probability)")
    parser.add_argument("--method", default="predict", choices=METHODS, help="default: predict")
    parser.add_argument("--language", default="PYTHON3", help="the container alias (default: PYTHON3)")
    parser.add_argument("--no-slash", action="store_true", help="leave off the closing '/' line")
    parser.add_argument("--placeholders", action="store_true", help="list the template's placeholders and stop")
    args = parser.parse_args(argv)
    if args.placeholders:
        print("\n".join(placeholders()))
        return 0
    try:
        sql = render(schema=args.schema, name=args.name, model_path=args.model_path, inputs=args.input,
                     output=args.output, method=args.method, language=args.language)
    except Refused as err:
        print(f"render.py: {err}", file=sys.stderr)
        return 2
    sys.stdout.write(sql if args.no_slash else sql + "/\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
