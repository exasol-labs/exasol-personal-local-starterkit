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
    # Turn the approved investigation into a repeatable model

    **Dataset:** `pharma_trials` by default; change `DATASET` for Banking or your own approved file. **How long:** about five minutes after runtime setup.

    The Data Scientist has agreed what the columns mean and saved a handoff. You will train a small model inside Exasol, test it on later records and keep an experiment record another person can inspect.

    **By the end:** MLflow will hold the training SQL, settings, metrics, model and coefficients. You can rerun the same recipe to check repeatability, then verify its scorer in the Rust chapter.

    **Run first:** an approved descriptor, the Explore handoff and a Python ML runtime (`exakit udf-use default`). Start local MLflow with `exakit mlflow start` for its browser UI.

    **Runtime choice:** `exakit udf-use default` installs `PYTHON3_ML` with the ML packages; `exakit udf-setup` installs the official `PYTHON3` alternative. The default prefers `PYTHON3_ML` when installed. `EXAKIT_UDF_CONTAINER` selects another installed alias; its package check must pass before training.

    **Optional AI:** the supplied SQL/scikit-learn training path needs no LLM endpoint. Use it as a baseline before asking an assistant to suggest a new feature or parameter; every new experiment still needs the same evaluation.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb
    import exasol_mlflow
    import os

    DATASET = "pharma_trials"  # or "banking_complaints", or "~/my-data/transactions.csv" with approved roles beside it
    CONTAINER = nb.ml_train.udf_container()   # or "PYTHON3_ML", "PYTHON3", or the alias of a container you installed
    if os.environ.get("EXAKIT_WORKFLOW_ID"):
        nb.workflow(resume=os.environ["EXAKIT_WORKFLOW_ID"])
    elif not nb.current_workflow():
        nb.workflow("train-" + DATASET)
    return CONTAINER, DATASET, exasol_mlflow, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Start from the same recipe the Data Scientist approved

    The handoff records the chosen target, feature recipe, column-map version and data fingerprint. Check the printed ID and split before training. A change in the data or map means the old recipe should be reviewed again.

    **Technical note:** a stale handoff is refused. With no handoff file, the helper can build a recipe from the approved descriptor and says it has done so. The earliest 80% of records by the date role train the model; the later 20% evaluate it. With no date, explicitly ask for `SPLIT = "random"` when making a new handoff, or approve an appropriate date role. An existing handoff keeps its recorded split.
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
    ## Turn the role map into numbers the model can learn from

    Words such as phase, sponsor and complaint product must become model inputs called **features**. The next cell creates a SQL feature view and a training function inside the selected Exasol runtime.

    **Read the result:** inspect the printed feature names and SQL. Check that the target itself has not become an input and that each input would be available when you intend to make a prediction.

    **Technical note:** the approved recipe supplies category flags, date parts, text lengths and entity frequency. Constant features are dropped. Logistic regression uses the fixed `SEED` and `REGULARIZATION_C`; the UDF returns its model, metrics and raw-feature coefficients to the client.
    """)
    return


@app.cell
def _(CONTAINER, conn, ds, handoff, nb):
    UDF_SCHEMA = "EXASOL_MLFLOW"
    UDF_NAME = "TRAIN_FROM_HANDOFF"
    SEED = 0
    REGULARIZATION_C = 1.0

    plan = nb.prepare_training(conn, ds, handoff, schema=UDF_SCHEMA, name=UDF_NAME, container=CONTAINER,
                               seed=SEED, C=REGULARIZATION_C)
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
    ## Make the model beat a simple alternative

    Train once, then compare its result with a model that always predicts the most common training class. That **majority baseline** is important when one outcome is rare: high accuracy alone can be misleading.

    **Read the result:** compare macro-F1 with `baseline_macro_f1`, using the same later test records. A model that fails to improve is an experiment result to investigate, not evidence of useful prediction. The current Banking reference run is deterministic but matches its majority baseline; that acceptance check remains open. The last checked Pharma run beat its baseline by a small margin.

    **Technical note:** `start_run` checks tracking readiness before executing the training SQL. MLflow records the query, descriptor/version, data digest, settings and returned artifacts. If tracking fails after training, a spool record can be replayed with `exakit mlflow replay`; a database restart fails the active run.
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
    ## Keep the files that make the result reproducible

    A metric without its recipe and model is hard to reuse. Inspect the artifact paths printed below and open the run in MLflow. Rerun training with the same seed, data and handoff; compare both metrics and coefficients.

    **Technical note:** `model/model.pkl` is the fitted Python pipeline. `coefficients.json` contains weights for the raw SQL feature columns, with scaling folded into them. The same coefficients are written beside the handoff as `<id>-v<n>.coefficients.json`, ready for the Rust scorer. Package/container versions help explain portability problems.
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
    ## Choose the next experiment deliberately

    Open `02_rust_score.ipynb` to test whether a compiled scorer reproduces this trained model. Use `03_score_external_model.ipynb` for the separate trusted-file scoring lesson.

    To investigate model quality, change one setting such as `REGULARIZATION_C`, rerun and compare the MLflow records. Optional AI can suggest experiments or explain code. Keep the test split and acceptance criteria fixed while assessing those suggestions; a new story about a metric is not a measured improvement.
    """)
    return


if __name__ == "__main__":
    app.run()
