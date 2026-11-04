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
    # Score a model file in SQL

    **Dataset:** the one you approved last (else `esophageal_posts`); set `DATASET` for Banking or a compatible table. **Run time:** about three minutes after setup.

    Copies a scikit-learn model file to the shared model directory, wraps it in a scoring UDF and checks database scores match local ones.

    **Needs:** approved roles, the Python ML runtime and a working shared bucket.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = None   # None: the dataset approved last in a quickstart (else esophageal_posts); or "banking_complaints", or the path of a descriptor for a table you loaded
    return DATASET, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Settings

    Keep `MODEL_FILE = None` to train a small stand-in model. Your own file needs `predict_proba` and `category`/`text` inputs.
    """)
    return


@app.cell
def _(nb):
    MODEL_FILE = None                   # or "~/Downloads/model.pkl"
    SCORING_SCHEMA = "EXAKIT_SCORING"   # where the scoring UDF is created; nothing else is written there
    UDF_NAME = "SCORE_TEXT_MODEL"
    CONTAINER = nb.ml_train.udf_container()  # prefer the installed PYTHON3_ML runtime
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
    ## Load the roles

    Prints the role-to-column map the SQL below uses.
    """)
    return


@app.cell
def _(DATASET, nb):
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
    conn = nb.connect()
    DATASET_1 = nb.chosen_dataset(DATASET)
    ds = nb.dataset(conn, DATASET_1)
    for role, column in ds.roles():
        print(f'  {role:<9} {column}')
    return (
        Path,
        conn,
        ds,
        hashlib,
        importlib,
        json,
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
    ## Training rows

    A fixed hash holds out about one row in five; the stand-in trains on the rest.
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
    ## Load the model and check versions

    Trains the stand-in or opens `MODEL_FILE`, then checks its scikit-learn version against the database runtime. Only open pickles you trust: loading one can run code.
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
    ## Copy the model for the UDF

    `exakit model put` copies the file and prints the UDF-visible path and SHA-256. For your own `MODEL_FILE`, run `exakit model inspect`, then `exakit model put ... --yes`.
    """)
    return


@app.cell
def _(
    MODEL_COMPATIBLE,
    MODEL_FILE,
    Path,
    json,
    model_path,
    os,
    shutil,
    subprocess,
):
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
        put_options = ["--replace"]
        if MODEL_FILE is None:  # Trust only the stand-in trained and pickled in this notebook.
            put_options.append("--yes")
        put = exakit("model", "put", str(model_path), *put_options)
        print(f"sha256 {put['sha256']}, {put['size']} bytes{' (replaced the earlier file)' if put['replaced'] else ''}")
        print(f"the UDF reads it at: {put['path']}")
    else:
        put = None
        print("Scoring skipped until the model and container versions match.")
    return exakit, put


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Create the scoring UDF

    Renders the UDF from the kit's checked template. It returns the positive-class probability.
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
    ## Compare predictions

    Scores the held-out rows in Exasol and locally. They must match; a skipped comparison is not a pass.
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
    ## Score in a query

    Mean predicted score vs actual label share per category.
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
    ## Use your own model

    Set `MODEL_FILE`, adapt the inputs and rerun the checks. Remove the example with `DROP SCRIPT EXAKIT_SCORING.SCORE_TEXT_MODEL`.
    """)
    return


if __name__ == "__main__":
    app.run()
