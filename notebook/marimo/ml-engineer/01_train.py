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
    # Train inside the database, track the run in MLflow

    - **Dataset:** the Pharma sample (`pharma_trials`, ClinicalTrials.gov studies) as it ships; the Banking sample
      (`banking_complaints`) or your own file by changing the one assignment below.
    - **What must be loaded:** that dataset (`00_quickstart.ipynb` loads it), and a Python container with scikit-learn
      in the database (`exakit udf-setup`; the quickstart's container check says whether it is there).
    - **How long:** about five minutes; the training statement itself takes one to three.

    SQL builds the training rows from the dataset's **descriptor** roles, a Python UDF trains a scikit-learn classifier
    **inside Exasol**, and this notebook logs the run to **your** MLflow with `exasol_mlflow.start_run`: the parameters,
    the metrics, the training SQL, the model file, and the database session and statement that trained it. The UDF needs
    no MLflow credentials and no network.
    """)
    return


@app.cell
def _():
    DATASET = "pharma_trials"   # or "banking_complaints", or your own file ("~/my-data/transactions.csv", roles beside it)
    return (DATASET,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Where the run goes

    With `MLFLOW_TRACKING_URI` set before `exakit notebook`, the run goes to that MLflow server. Without it, it goes to
    a local MLflow store in the `mlflow` folder next to this notebook; open it with
    `mlflow ui --backend-store-uri sqlite:///mlflow/mlflow.db` (the full `mlflow` package has the UI).
    """)
    return


@app.cell
def _():
    EXPERIMENT = "exasol-starter-kit"
    UDF_SCHEMA = "EXASOL_MLFLOW"        # where the training UDF is created; nothing else is written there
    return EXPERIMENT, UDF_SCHEMA


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Connect, read the descriptor, create the training UDF

    As in `data-scientist/01_explore`: a kit dataset by its id, or your own CSV, Parquet or JSON file by its path, with
    its roles in `<name>.descriptor.yaml` beside it - the same descriptor, the same cells.
    """)
    return


@app.cell
def _(DATASET, UDF_SCHEMA):
    import json

    import exakit.nb as nb
    import exasol_mlflow

    conn = nb.connect()
    ds = nb.dataset(conn, DATASET)
    nb.show_roles(ds)

    conn.execute(f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}")
    conn.execute(exasol_mlflow.create_script(UDF_SCHEMA))
    print(f"UDF {exasol_mlflow.call(UDF_SCHEMA)} is ready; it runs on the database's Python script language container")
    return conn, ds, exasol_mlflow, json


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The features, in SQL

    One row per observation, every column from a role: the label, the category and the text, plus the training
    parameters as one JSON value. The UDF sees every row and trains one model (a SET script called without GROUP BY).
    """)
    return


@app.cell
def _(UDF_SCHEMA, ds, exasol_mlflow, json):
    PARAMS = dict(exasol_mlflow.DEFAULT_PARAMS)      # max_features, ngram_max, C, test_size, seed - change any of them
    PARAMS["C"] = 1.0

    training_sql = f"""SELECT {exasol_mlflow.call(UDF_SCHEMA)}(
             {ds.col("label")},
             CAST({ds.col("category")} AS VARCHAR(2000)),
             {ds.text_sql()},
             '{json.dumps(PARAMS)}')
    FROM {ds.fact_table}
    WHERE {ds.col("label")} IS NOT NULL"""
    print(training_sql)
    return PARAMS, training_sql


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Train and log

    `start_run` opens one MLflow run around the training statement: `run.execute` runs it, checks the UDF's answer (one
    result, every model chunk present, the model's SHA-256 matching) and logs the parameters, the metrics, the training
    SQL, the model file and the lineage tags `exasol.session_id`, `exasol.statement_id` and `exasol.deployment`, with the
    dataset and its descriptor's digest. A broken answer stops here with the reason, and MLflow gets nothing.
    """)
    return


@app.cell
def _(EXPERIMENT, PARAMS, conn, ds, exasol_mlflow, training_sql):
    with exasol_mlflow.start_run(conn, params=PARAMS, experiment=EXPERIMENT, run_name=f"{ds.id}-text-classifier",
                                 tags=ds.tags()) as run:
        run.execute(training_sql)
    print(f"run {run.run_id} in {run.tracking_uri}")
    for metric, value in sorted(run.metrics.items()):
        print(f"  {metric:<14} {value:.4f}")
    for tag, value in sorted(run.tags.items()):
        print(f"  {tag:<26} {value}")
    return (run,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Where the model landed

    The model file is an artefact of the run (`model/model.pkl`, a scikit-learn pipeline), beside `training.sql`. On a
    local store that is a file on this computer.
    """)
    return


@app.cell
def _(run):
    from urllib.parse import unquote, urlparse

    model_uri = f"{run.artifact_uri}/model/model.pkl"
    print(f"model artefact: {model_uri}")
    if urlparse(model_uri).scheme == "file":
        print(f"on this computer: {unquote(urlparse(model_uri).path)}")
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    - Change `PARAMS` and run the last cells again: each run is one more row in the MLflow experiment, so runs compare
      side by side.
    - The model was trained with the database container's Python and scikit-learn - the run's tags say which - so load it
      where those match.
    - Packages beyond the container's own: `exakit udf-build <requirements.txt>` (the `udf-devkit` add-on).
    """)
    return


if __name__ == "__main__":
    app.run()
