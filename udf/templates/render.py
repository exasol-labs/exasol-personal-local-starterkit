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

The training template (train_model.sql, the exasol-mlflow run contract) is rendered from Python only, from the
handoff's feature view (exakit.nb.read_handoff):

    create = render.render_train(schema="STARTER_KIT", name="TRAIN_PHARMA", features=[f["name"] for f in handoff["input_schema"]],
                                 label=handoff["label"]["column"], positive=handoff["label"]["positive"], seed=0)
    select = render.train_sql(schema="STARTER_KIT", name="TRAIN_PHARMA", training_sql=handoff["training_sql"],
                              run_key="pharma-v1", label=handoff["label"]["column"], features=[...])
    conn.execute(create)
    with exasol_mlflow.start_run(conn, handoff=handoff) as run:
        run.execute(select)

Feature and label names there are COLUMN names (any text; train_sql double-quotes them), not parameter names: the UDF
takes them positionally as f0, f1, ... DOUBLE after run_key, split_ and label.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATE = "score_model.sql"
TRAIN_TEMPLATE = "train_model.sql"
METHODS = ("predict", "predict_proba")
MODEL_DIR = "/buckets/bfsdefault/default/models"            # where a model over 1 MB is written (see train_model.sql)
SPLIT_COLUMN = "SPLIT_"                                     # the handoff training SQL's split column: 'train' | 'test'
RUN_KEY_COLUMN = "RUN_KEY"
_RUN_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_COLUMN = re.compile(r"^[^\x00-\x1f]{1,128}$")
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
    return _fill(template, values)


def _fill(template: str, values: dict[str, str]) -> str:
    """The template with every placeholder replaced by its checked value; the comment header dropped (the statement
    starts at CREATE); a placeholder the renderer does not know, or one left unfilled, is refused by name."""
    text = (HERE / template).read_text(encoding="utf-8")
    unknown = [p for p in placeholders(template) if p not in values]
    if unknown:
        raise Refused(f"{template} has placeholders this renderer does not fill: {', '.join(unknown)}.")
    rendered = _PLACEHOLDER.sub(lambda match: values[match.group(1)], text)
    left = _PLACEHOLDER.findall(rendered)
    if left:
        raise Refused(f"Placeholders left unfilled: {', '.join(sorted(set(left)))}.")
    lines = rendered.splitlines()
    while lines and (lines[0].startswith("--") or not lines[0].strip()):
        lines.pop(0)
    return "\n".join(lines).rstrip() + "\n"


def _column(value, what: str) -> str:
    """A column name as the data has it (any text without control characters, up to 128 characters); it is always
    double-quoted in SQL, so case and reserved words do not matter."""
    text = "" if value is None else str(value)
    if not text.strip():
        raise Refused(f"{what} is not filled.")
    if not _COLUMN.match(text) or '"' in text:
        raise Refused(f"{what} '{text}' is not a column name (no control characters or double quotes, up to 128 characters).")
    return text


def quoted(name: str) -> str:
    """The column name as a double-quoted SQL identifier."""
    return '"' + name + '"'


def _features(features) -> list[str]:
    names = [_column(f, "A feature") for f in (features or [])]
    if not names:
        raise Refused("FEATURES is not filled: name at least one feature column (the handoff's input_schema).")
    if len(set(names)) != len(names):
        raise Refused("A feature is named twice: " + ", ".join(sorted({n for n in names if names.count(n) > 1})) + ".")
    return names


def _number(value, what: str, kind, low=None):
    try:
        number = kind(value)
    except (TypeError, ValueError) as err:
        raise Refused(f"{what} {value!r} is not a {kind.__name__}.") from err
    if isinstance(number, float) and number != number:
        raise Refused(f"{what} must be a number.")
    if low is not None and number < low:
        raise Refused(f"{what} must be at least {low}, not {number}.")
    return number


def render_train(schema=None, name=None, features=None, label=None, positive=None, seed=0, C=1.0, max_iter=1000,
                 language="PYTHON3", model_dir=MODEL_DIR, template: str = TRAIN_TEMPLATE, class_weight=None) -> str:
    """The CREATE statement of a training UDF (train_model.sql) for the feature columns in ``features`` (in order: the
    coefficient vector follows it) and the label column ``label``; ``positive`` is the positive class as text (roc_auc
    refers to it; None takes the last class). The UDF's parameters are positional (run_key, split_, label, f0, f1, ...),
    so train_sql() must list the same features in the same order."""
    if class_weight not in (None, "balanced"):
        raise Refused("CLASS_WEIGHT must be balanced or None.")
    reserved = _reserved()
    names = _features(features)
    columns = ["run_key VARCHAR(64)", "split_ VARCHAR(8)", "label VARCHAR(2000)"] + [f"f{i} DOUBLE" for i in range(len(names))]
    folder = "" if model_dir is None else str(model_dir).strip()
    if not _BUCKETS.match(folder) or "/../" in folder + "/" or "/./" in folder + "/":
        raise Refused(f"MODEL_DIR '{folder}' is not a /buckets folder such as {MODEL_DIR}.")
    values = {
        "LANGUAGE": _name(language, "LANGUAGE", reserved).upper(),
        "SCHEMA": _name(schema, "SCHEMA", reserved).upper(),
        "SCRIPT_NAME": _name(name, "SCRIPT_NAME", reserved).upper(),
        "INPUT_COLUMNS": ", ".join(columns),
        "FEATURES": repr(names),
        "LABEL": repr(_column(label, "LABEL")),
        "POSITIVE": repr(None if positive is None else str(positive)),
        "SEED": repr(_number(seed, "SEED", int, 0)),
        "C": repr(_number(C, "C", float, 0.0)),
        "MAX_ITER": repr(_number(max_iter, "MAX_ITER", int, 1)),
        "CLASS_WEIGHT": repr(class_weight),
        "MODEL_DIR": repr(folder),
    }
    values["ALIAS"] = repr(values["LANGUAGE"])
    return _fill(template, values)


def train_sql(schema=None, name=None, training_sql=None, run_key=None, label=None, features=None,
              split_column=SPLIT_COLUMN) -> str:
    """The SELECT that trains: the UDF render_train() created, over the handoff's training SQL (a SELECT whose rows
    carry the label, the features and the split column), one group per ``run_key`` (a key the run is filed under:
    letters, digits, . _ -; up to 64 characters). Every column reference is double-quoted; the label is passed as text
    and every feature as DOUBLE, which is what the UDF's parameters expect."""
    reserved = _reserved()
    key = "" if run_key is None else str(run_key).strip()
    if not _RUN_KEY.match(key):
        raise Refused(f"RUN_KEY '{key}' is not a run key (letters, digits, . _ -; up to 64 characters).")
    sql = "" if training_sql is None else str(training_sql).strip().rstrip(";").strip()
    if not sql.upper().startswith(("SELECT", "WITH")):
        raise Refused("TRAINING_SQL is not filled: the handoff's training SQL (a SELECT).")
    names = _features(features)
    arguments = [quoted(RUN_KEY_COLUMN), quoted(_column(split_column, "SPLIT_COLUMN")),
                 f"CAST({quoted(_column(label, 'LABEL'))} AS VARCHAR(2000))"] + [f"CAST({quoted(n)} AS DOUBLE)" for n in names]
    udf = f"{_name(schema, 'SCHEMA', reserved).upper()}.{_name(name, 'SCRIPT_NAME', reserved).upper()}"
    inner = "\n".join("        " + line for line in sql.splitlines())
    return (f"SELECT {udf}(\n    " + ",\n    ".join(arguments) + "\n)\n"
            f"FROM (\n    SELECT '{key}' AS {quoted(RUN_KEY_COLUMN)}, T.* FROM (\n{inner}\n    ) T\n)\n"
            f"GROUP BY {quoted(RUN_KEY_COLUMN)}")


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
