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
    # Train in Exasol

    **Dataset:** the one you approved last (else `amazon_sales`); set `DATASET` for `walmart_sales` or your own approved file. **How long:** about five minutes after setup.

    Trains a model inside Exasol from the approved column map and records it in MLflow. No LLM needed.

    **Run first:**
    - an approved column map with a label (the quickstart's review step, or `exakit describe <id> --approve`)
    - a Python ML runtime: `exakit udf-use default` (`PYTHON3_ML`) or `exakit udf-setup` (`PYTHON3`); `EXAKIT_UDF_CONTAINER` picks another alias
    - `exakit mlflow start` for the MLflow UI
    """)
    return


@app.cell
def _():
    import exakit.nb as nb
    import exasol_mlflow
    import os

    DATASET = None  # None: the dataset approved last in a quickstart (else amazon_sales); or "walmart_sales", or "~/my-data/transactions.csv" with approved roles beside it
    CONTAINER = nb.ml_train.udf_container()   # or "PYTHON3_ML", "PYTHON3", or the alias of a container you installed
    DATASET = nb.chosen_dataset(DATASET)
    if os.environ.get("EXAKIT_WORKFLOW_ID"):
        nb.workflow(resume=os.environ["EXAKIT_WORKFLOW_ID"])
    elif not nb.current_workflow():
        nb.workflow("train-" + DATASET)
    return CONTAINER, DATASET, exasol_mlflow, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Load the handoff

    > **What is the handoff?** One small file that pins down what the model is trained on: the approved map, the features, the outcome (label) and how rows are split into training and test.
    > Written down once, the same training can be repeated later and gives the same model.
    > If the table or the map changes, the handoff no longer matches and is refused instead of being used silently.

    The handoff fixes what is trained on: the approved map version, a data fingerprint, the features, the label and the split. With none yet, it is written here from the approved map; a stale one is refused. Check the printed ID and split. No date role? Set `SPLIT = "random"`.
    """)
    return


@app.cell
def _(DATASET, nb):
    SPLIT = None  # None: the time split by the date role; "random": a hash split, only when there is no handoff file yet

    conn = nb.connect()
    ds = nb.dataset(conn, DATASET).require_approved("training")
    handoff = nb.ml_train.training_handoff(conn, ds, split=SPLIT)
    print(f"handoff: {ds.id} v{ds.version}; {handoff['rows']} rows; {handoff['split']['kind']} split"
          + (" (asked for)" if handoff['split'].get('explicit') else ""))
    print(f"data digest: {handoff['data_digest']}")
    return conn, ds, handoff


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Build features and the training UDF

    > **What is the feature view?** A SQL view that turns each row into numbers a model can use: year, month and weekday from the date, one 0/1 column per common category value, how common the entity is.
    > It is plain SQL, so you can read every feature, and the Rust scorer later reads the very same view.
    > It is built from the approved map only, so a column that gives the answer away (like `STATUS` in `amazon_sales`) never becomes a feature.

    Creates a SQL feature view and a training UDF. Check the label is not among the printed features.
    """)
    return


@app.cell
def _(CONTAINER, conn, ds, handoff, nb):
    UDF_SCHEMA = "EXASOL_MLFLOW"
    UDF_NAME = "TRAIN_FROM_HANDOFF"
    SEED = 0
    CLASS_WEIGHT = "balanced"  # "balanced": the rarer outcome counts more (amazon_sales: 14.2% cancelled); None: every row counts the same
    REGULARIZATION_C = 1.0

    plan = nb.prepare_training(conn, ds, handoff, schema=UDF_SCHEMA, name=UDF_NAME, container=CONTAINER,
                               seed=SEED, C=REGULARIZATION_C, class_weight=CLASS_WEIGHT)
    conn.execute(f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}")
    nb.log_sql(conn, f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}", None)
    conn.execute(plan.create_script)
    nb.log_sql(conn, plan.create_script, None)
    print(f"UDF {UDF_SCHEMA}.{UDF_NAME} on {CONTAINER}; features ({len(plan.features)}): {', '.join(plan.features)}")
    print(plan.training_sql)
    return (plan,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Train and compare with the baseline

    > **What is the baseline?** The score of a "model" that always predicts the most common outcome (in `amazon_sales`: never cancelled).
    > A trained model has to beat it; if it does not, it has learned nothing useful yet.
    > The score is macro-F1, which weighs both outcomes equally, so always answering "not cancelled" cannot look good.

    Compare macro-F1 with `baseline_macro_f1` (always predicting the most common class). `CLASS_WEIGHT = "balanced"` helps when the label is rare (`amazon_sales`: 14.2% cancelled); with an even label (`walmart_sales`: 49.7% above the store's median) it changes little, and `None` is fine.

    The run is recorded in MLflow: its settings, scores and model file, tagged with the map version and handoff it came from.

    If MLflow fails after training, replay with `exakit mlflow replay`.
    """)
    return


@app.cell
def _(conn, ds, exasol_mlflow, handoff, nb, plan):
    EXPERIMENT = "exasol-starter-kit"
    with exasol_mlflow.start_run(conn, params=plan.params, experiment=EXPERIMENT,
                                 run_name=f"{ds.id}-v{ds.version}-logistic", tags=ds.tags(),
                                 handoff=handoff) as run:
        run.execute(plan.training_sql)
        nb.log_sql(conn, plan.training_sql, 1)

    f1 = run.metrics["macro_f1"]
    baseline = run.metrics["baseline_macro_f1"]
    print(f"run {run.run_id} in {run.tracking_uri}")
    print(f"accuracy: {run.metrics['accuracy']:.4f}")
    print(f"macro-F1: {f1:.4f}; majority baseline: {baseline:.4f}")
    print("beats baseline" if f1 > baseline else "does not beat baseline; inspect features or the split")
    return (run,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Model files

    `model/model.pkl` is the fitted pipeline. `coefficients.json` holds the weights, also saved beside the handoff for the Rust scorer.
    """)
    return


@app.cell
def _(handoff, nb, run):
    from urllib.parse import unquote, urlparse

    print(f"model: {run.artifact_uri}/model/model.pkl")
    print(f"coefficients: {run.artifact_uri}/coefficients.json")
    if urlparse(run.artifact_uri).scheme == "file":
        print(f"on this computer: {unquote(urlparse(run.artifact_uri).path)}")
    coefficients_path = nb.ml_train.export_coefficients(run, handoff)
    print(f"coefficients beside the handoff: {coefficients_path}")
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    - `02_rust_score.ipynb`: check a Rust scorer against this model.
    - `03_score_external_model.ipynb`: score a model file in SQL.
    - To experiment, change one setting (e.g. `REGULARIZATION_C`) and compare runs in MLflow.
    """)
    return


if __name__ == "__main__":
    app.run()
