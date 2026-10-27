import marimo

__generated_with = "0.25.2"
app = marimo.App()


@app.cell
def _():
    import marimo as mo

    return (mo,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    # Score a model trained elsewhere

    A model trained **anywhere** - a laptop, a colleague's notebook, `01_train.ipynb` - arrives as a file. This notebook
    puts it into the database's bucket directory with `exakit model put`, creates a scoring UDF for it from the kit's
    template, scores a table **inside Exasol**, and checks that the database's predictions match the same model run here,
    row for row, on a held-out sample.

    **Dataset:** `pharma_trials` (or `banking_complaints`: change one line below). Every query is built from the dataset's
    **descriptor** roles - the category, the text and the label - so the notebook runs unchanged on either.

    **What it needs:** the dataset loaded (`exakit data-load pharma_trials`), the `udf-devkit` add-on with Python UDFs set
    up (`exakit marketplace udf-devkit`, then `exakit udf-setup`), and scikit-learn in this notebook's environment.
    **Run time:** about three minutes; the first scoring query is the slowest, because each UDF instance loads the model
    once.
    """)
    return


@app.cell
def _():
    DATASET = "pharma_trials"   # or "banking_complaints", or the path of a descriptor for a table you loaded
    return (DATASET,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Where the model comes from

    Leave `MODEL_FILE = None` and the next cells train a small text classifier here, standing in for a model trained
    elsewhere. Or point it at a scikit-learn pickle you already have: one that takes a table with the columns `category`
    and `text` and has `predict_proba` - the `model/model.pkl` artefact of an `01_train.ipynb` run is one. The database
    unpickles the file with **its** container's Python and scikit-learn, so train with the same versions; the check at
    the end shows it when they disagree.
    """)
    return


@app.cell
def _():
    MODEL_FILE = None                   # or "~/Downloads/model.pkl"
    SCORING_SCHEMA = "EXAKIT_SCORING"   # where the scoring UDF is created; nothing else is written there
    UDF_NAME = "SCORE_TEXT_MODEL"
    CONTAINER = "PYTHON3"               # the container alias the UDF runs on: PYTHON3, or one you installed
    TRAIN_ROWS = 4000                   # rows the stand-in model learns from
    HOLDOUT_ROWS = 500                  # held-out rows the two predictions are compared on
    return (
        CONTAINER,
        HOLDOUT_ROWS,
        MODEL_FILE,
        SCORING_SCHEMA,
        TRAIN_ROWS,
        UDF_NAME,
    )


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Connect and read the descriptor
    """)
    return


@app.cell
def _(DATASET):
    import importlib.util
    import hashlib
    import json
    import os
    import pickle
    import shutil
    import subprocess
    import warnings
    from pathlib import Path

    import numpy as np
    import pandas as pd

    import exakit.nb as nb

    conn = nb.connect()
    ds = nb.dataset(conn, DATASET)
    for role, column in ds.roles():
        print(f"  {role:<9} {column}")
    return (
        Path,
        conn,
        ds,
        hashlib,
        importlib,
        json,
        nb,
        np,
        os,
        pd,
        pickle,
        shutil,
        subprocess,
        warnings,
    )


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The rows, from the roles

    One row per observation: the category and the text the model reads, and the label. A row is **held out** when a hash
    of its text falls in one bucket of five, so the stand-in model never sees the rows it is checked on, and the split is
    the same on every run.
    """)
    return


@app.cell
def _(TRAIN_ROWS, conn, ds, nb):
    CATEGORY = f"COALESCE(CAST({ds.col('category')} AS VARCHAR(2000)), '')"
    TEXT = ds.text_sql()
    LABEL = ds.col("label")
    HELD_OUT = f"MOD(ASCII(SUBSTR(HASH_MD5({TEXT} || '|' || {CATEGORY}), 1, 1)), 5) = 0"


    def rows_sql(where: str, limit: int, extra: str = "") -> str:
        return (f"SELECT {CATEGORY} AS CATEGORY, {TEXT} AS DOC_TEXT, {LABEL} AS LABEL{extra}\n"
                f"FROM {ds.fact_table}\nWHERE {LABEL} IS NOT NULL AND {where}\nLIMIT {limit}")


    train_sql = rows_sql(f"NOT ({HELD_OUT})", TRAIN_ROWS)
    print(train_sql)
    train = nb.sql(conn, train_sql)
    print(f"\n{len(train)} training rows, label 1 share {train['LABEL'].mean():.2f}")
    return CATEGORY, HELD_OUT, LABEL, TEXT, rows_sql, train


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The model file

    With `MODEL_FILE = None` this trains the stand-in on this computer and pickles it into `models/` next to the
    notebook: the same shape of model `01_train.ipynb` trains inside the database (TF-IDF on the text, the category one-hot
    encoded, a logistic regression), taking a table with the columns `category` and `text`.
    """)
    return


@app.cell
def _(
    CONTAINER,
    MODEL_FILE,
    Path,
    conn,
    ds,
    hashlib,
    json,
    nb,
    pd,
    pickle,
    train,
    warnings,
):
    import sklearn

    if MODEL_FILE is None:
        from sklearn.compose import ColumnTransformer
        from sklearn.feature_extraction.text import TfidfVectorizer
        from sklearn.linear_model import LogisticRegression
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import OneHotEncoder

        stand_in = Pipeline([
            ("features", ColumnTransformer([
                ("text", TfidfVectorizer(max_features=5000, ngram_range=(1, 2), min_df=2), "text"),
                ("category", OneHotEncoder(handle_unknown="ignore"), ["category"])])),
            ("classifier", LogisticRegression(max_iter=1000, class_weight="balanced"))])
        stand_in.fit(pd.DataFrame({"category": train["CATEGORY"], "text": train["DOC_TEXT"]}), train["LABEL"].astype(int))
        model_path = Path("models") / f"{ds.id}_text_classifier.pkl"
        model_path.parent.mkdir(exist_ok=True)
        model_path.write_bytes(pickle.dumps(stand_in))
    else:
        model_path = Path(MODEL_FILE).expanduser()
    try:
        with warnings.catch_warnings(record=True) as pickle_warnings:
            warnings.simplefilter("always")
            model = pickle.loads(model_path.read_bytes())
    except Exception as error:
        model = None
        pickle_warnings = []
        print(f"Cannot score {model_path}: this computer cannot load the pickle ({type(error).__name__}: {error}). "
              "Use a matching Python and scikit-learn version, then put the model again.")
    if model is not None:
        print(f"{model_path} ({model_path.stat().st_size} bytes), scikit-learn {sklearn.__version__} on this computer")
    provenance_file = Path(str(model_path) + ".provenance.json")
    model_version = sklearn.__version__
    for message in pickle_warnings:
        original = getattr(message.message, "original_sklearn_version", None)
        if original:
            model_version = str(original)
    if provenance_file.is_file():
        try:
            provenance = json.loads(provenance_file.read_text(encoding="utf-8"))
            if provenance.get("sha256") == hashlib.sha256(model_path.read_bytes()).hexdigest():
                model_version = provenance.get("scikit-learn") or model_version
        except ValueError:
            pass
    MODEL_COMPATIBLE = model is not None and nb.check_model_compatibility(
        conn, model_version, alias=CONTAINER, model_path=f"/buckets/bfsdefault/default/models/{model_path.name}")
    return MODEL_COMPATIBLE, model, model_path


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Put it into the bucket directory

    A local database has no upload service for its files: its BucketFS is a folder of the deployment, which UDFs read
    under `/buckets`. `exakit model put` copies the file there, records its SHA-256, and prints the path the UDF opens. A
    second run with the same file changes nothing; a **different** file of the same name is refused unless `--replace` is
    given (exit code 5), so a model is never swapped silently. This cell passes `--replace` on purpose: running the
    notebook again should put the model it has just trained. `exakit model list` shows what is there.
    """)
    return


@app.cell
def _(MODEL_COMPATIBLE, Path, json, model_path, os, shutil, subprocess):
    def exakit(*args: str) -> dict:
        """Run one `exakit ... --json` command and return its answer; a refusal stops the notebook with its reason."""
        found = shutil.which("exakit") or shutil.which("exakit.cmd")
        if found is None:
            bin_dir = Path(os.environ.get("EXAKIT_BIN_DIR") or Path.home() / ".local" / "bin")
            found = next((str(bin_dir / name) for name in ("exakit", "exakit.cmd") if (bin_dir / name).is_file()), None)
        if found is None:
            raise RuntimeError("The exakit CLI is not on this kernel's PATH or in ~/.local/bin.")
        done = subprocess.run([found, *args, "--json"], capture_output=True, text=True)
        try:
            answer = json.loads(done.stdout)
        except ValueError:
            answer = {"ok": False, "error": (done.stderr or done.stdout).strip()}
        if done.returncode != 0:
            raise RuntimeError(f"exakit {' '.join(args)} exited {done.returncode}: {answer.get('error')}"
                               + (f" - run: {answer['remedy']}" if answer.get("remedy") else ""))
        return answer


    if MODEL_COMPATIBLE:
        put = exakit("model", "put", str(model_path), "--replace")
        print(f"sha256 {put['sha256']}, {put['size']} bytes{' (replaced the earlier file)' if put['replaced'] else ''}")
        print(f"the UDF reads it at: {put['path']}")
    else:
        put = None
        print("Scoring skipped until the model and container versions match.")
    return exakit, put


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Create the scoring UDF from the template

    The template is `udf/templates/score_model.sql` in the kit; its renderer fills the placeholders and refuses a value
    that does not belong in SQL, or one left unfilled. The UDF loads the model **once per UDF instance** and scores one row
    per call. `TEXT` is a reserved word in Exasol, so the parameter is `doc_text`, handed to the model as its `text`
    column.
    """)
    return


@app.cell
def _(
    CONTAINER,
    MODEL_COMPATIBLE,
    SCORING_SCHEMA,
    UDF_NAME,
    conn,
    exakit,
    importlib,
    put,
):
    if MODEL_COMPATIBLE:
        template = exakit("model", "template")
        spec = importlib.util.spec_from_file_location("exakit_udf_render", template["renderer"])
        render = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(render)
        create_sql = render.render(schema=SCORING_SCHEMA, name=UDF_NAME, model_path=put["path"], language=CONTAINER,
                                   inputs=[("category", "VARCHAR(2000)"), ("doc_text", "VARCHAR(2000000)", "text")],
                                   output="DOUBLE", method="predict_proba")
        print("\n".join(create_sql.splitlines()[:8]) + "\n...")
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {SCORING_SCHEMA}")
        conn.execute(create_sql)
        UDF = f"{SCORING_SCHEMA}.{UDF_NAME}"
        print(f"UDF {UDF} is ready")
    return (UDF,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Score the held-out rows in the database, and here

    The database scores rows the stand-in never saw. The same model scores the very rows the database returned, on this
    computer; the two must agree (AC-ML4.2). A difference beyond rounding means the container's scikit-learn is not the
    one the model was pickled with.
    """)
    return


@app.cell
def _(
    CATEGORY,
    HELD_OUT,
    HOLDOUT_ROWS,
    MODEL_COMPATIBLE,
    TEXT,
    UDF,
    conn,
    model,
    nb,
    np,
    pd,
    rows_sql,
):
    if MODEL_COMPATIBLE:
        holdout_sql = rows_sql(HELD_OUT, HOLDOUT_ROWS, extra=f",\n       {UDF}({CATEGORY}, {TEXT}) AS DB_SCORE")
        print(holdout_sql)
        holdout = nb.sql(conn, holdout_sql)
        here = model.predict_proba(pd.DataFrame({"category": holdout["CATEGORY"], "text": holdout["DOC_TEXT"]}))[:, 1]
        there = holdout["DB_SCORE"].astype(float).to_numpy()
        gap = float(np.max(np.abs(here - there))) if len(here) else 0.0
        print(f"\n{len(holdout)} held-out rows; largest difference between the database and this computer: {gap:.2e}")
        print("the predictions match" if np.allclose(here, there, atol=1e-9) else
              "the predictions DIFFER: train the model with the container's Python and scikit-learn versions")
        print(f"accuracy on the held-out rows: {float(((there >= 0.5).astype(int) == holdout['LABEL'].astype(int)).mean()):.3f}")
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Score the table

    The UDF is SQL now: any query can call it. Here, the mean predicted probability per category over the whole table,
    beside the share of label 1 actually there.
    """)
    return


@app.cell
def _(CATEGORY, LABEL, MODEL_COMPATIBLE, TEXT, UDF, conn, ds, nb):
    if MODEL_COMPATIBLE:
        table_sql = f"""SELECT CATEGORY, COUNT(*) AS ROWS_SCORED, AVG(SCORE) AS MEAN_SCORE, AVG({LABEL}) AS LABEL_1_SHARE
    FROM (SELECT {CATEGORY} AS CATEGORY, {LABEL}, {UDF}({CATEGORY}, {TEXT}) AS SCORE FROM {ds.fact_table})
    GROUP BY CATEGORY
    ORDER BY ROWS_SCORED DESC
    LIMIT 15"""
        print(table_sql)
        nb.sql(conn, table_sql)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    - Your own model: set `MODEL_FILE`, run the notebook again. A model with other inputs takes other `inputs=` in the
      render cell, `(parameter, SQL type, model column)` each; `python3 render.py --help` (path: `exakit model template`)
      shows the options, including ONNX files and `method="predict"` for a class rather than a probability.
    - `exakit model list` shows every model in the bucket directory and flags one changed since it was put.
    - Drop the UDF when done: `DROP SCRIPT EXAKIT_SCORING.SCORE_TEXT_MODEL`.
    """)
    return


if __name__ == "__main__":
    app.run()
