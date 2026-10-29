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
    # Bring a trusted model file into SQL

    **Dataset:** `pharma_trials` by default; change `DATASET` for Banking or a compatible described table.

    Sometimes a model is trained on a laptop and arrives as a file. You want to call it from SQL without changing its predictions. This lesson provides a local stand-in model, copies it into the shared model directory and compares database scores with local scores.

    **By the end:** you will know which model file was used, whether its Python packages are compatible and whether both environments score the held-out sample consistently.

    **What it needs:** approved roles, the Python ML runtime and a working shared bucket. **Run time:** about three minutes after setup.

    **Optional AI:** no LLM endpoint is required. Here 'external model' means a local model file; it does not configure an external data source.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = "pharma_trials"   # or "banking_complaints", or the path of a descriptor for a table you loaded
    return DATASET, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Use the supplied model first, then adapt the input contract

    Keep `MODEL_FILE = None` for the walkthrough. The notebook trains a small category-and-text classifier locally, standing in for a model someone hands you. Later, supply a trusted scikit-learn model file with compatible inputs and `predict_proba`.

    **Technical note:** this template sends fields named `category` and `text`. The numeric-feature pipeline from `01_train` has a different input contract and needs an adapted feature query/template before it can be used here. A matching filename alone does not establish compatibility.
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
    ## Agree what data the file will receive

    Open the approved role map and check that category, text and label mean the same things the model was trained to use. Pharma supplies phase and trial descriptions; Banking supplies product and complaint descriptions.

    **Technical note:** the connection comes from the kit store. `DATASET` selects the descriptor; its mapped column names supply the SQL expressions below.
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
    ## Keep some records away from the supplied training example

    The built-in stand-in learns from one set of records and is checked on another. This avoids judging it only on records it has just seen.

    **Technical note:** a fixed hash of category/text selects the held-out bucket, while the complement supplies the stand-in's training rows. The same expressions select either dataset. Null labels are excluded; text fields are combined and missing text becomes empty.
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
    ## Check the file and the runtime before using it

    The next cell trains and saves the stand-in, or opens the trusted file you supplied. Inspect the package-compatibility result before scoring. A skipped check or an incompatible version leaves the scoring lesson incomplete.

    **Technical note:** the helper compares the model's scikit-learn version with the selected database runtime. When a local provenance sidecar matches the file's SHA-256, its scikit-learn version supplies that check; the digest does not prove who created the file. Python and other package compatibility still need the loading and scoring tests below. A pickle can execute code when opened, so use files whose origin you trust. The notebook's own stand-in is created by the visible code you just ran.
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
    ## Make the same file visible to the scoring function

    A file on your laptop must be placed where a database UDF can read it. The next cell copies it into the deployment's shared model directory and prints the UDF-visible path and digest.

    **Technical note:** `exakit model put` makes an atomic copy and records SHA-256. This lesson intentionally allows replacement of its just-trained example on reruns. A supplied `MODEL_FILE` needs a separate origin/trust confirmation using `exakit model inspect` and `exakit model put ... --yes`. `exakit model list` shows recorded files. Rust's bucketless fallback does not provide a Python model-file route.
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
    ## Turn the file into a function a query can call

    The generated scoring function accepts a category and description, loads the model and returns its positive-class probability. Read the printed definition before creating it.

    **Technical note:** the checked renderer fills `udf/templates/score_model.sql` and rejects invalid or missing placeholders. Each UDF instance loads the model once. The SQL argument `doc_text` is passed to the pipeline's `text` field; adapting a model requires preserving its feature names, types and order.
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
    ## Compare predictions before scoring more rows

    The same held-out records are scored inside Exasol and on your computer. Read the row count, largest difference and comparison message. A skipped comparison is not a portability pass.

    **Technical note:** the notebook compares probabilities using NumPy's numerical comparison and reports the maximum difference as well. Investigate mismatches in package versions, input preparation and model provenance. Matching implementations establish portability on the tested records; the printed accuracy is a separate measure of the model's quality.
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
    ## Use the verified scorer in an ordinary query

    Once the comparison is satisfactory, inspect the average predicted probability and actual outcome share per category. Pharma groups by phase; Banking groups by product.

    **Read the result:** a predicted probability is a model estimate, while the actual label share is observed data. Disagreement can reveal calibration or coverage problems worth investigating.

    **Technical note:** the query calls the scoring UDF for each selected row and aggregates the results. Keep the feature preparation consistent with the earlier comparison.
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
    ## Reuse the pattern for a model you own

    Start from the supplied example, then change `MODEL_FILE` and adapt the feature query and renderer inputs to your model's contract. Repeat the compatibility and held-out comparison before relying on its scores.

    Use `exakit model list` to inspect model provenance. When you are finished with this example, the SQL function can be removed deliberately with `DROP SCRIPT EXAKIT_SCORING.SCORE_TEXT_MODEL`. Use the kit's model commands for managed files. A chart or published result belongs in the checked Dash Server Share flow.
    """)
    return


if __name__ == "__main__":
    app.run()
