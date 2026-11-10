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
    # Rust scorer

    **Dataset:** `amazon_sales`, `fraud_transactions` or your own approved descriptor and handoff. **How long:** about fifteen minutes for a first build.

    Builds a Rust UDF from the trained coefficients and checks that it scores the same as Python.

    **Run first:** `01_train`, the `RUST` container (`exakit udf-setup --language rust`), and Docker or Podman.
    """)
    return


@app.cell
def _():
    DATASET = None  # None: the dataset approved last in a quickstart (else amazon_sales); or "fraud_transactions", or your own approved descriptor
    COEFFICIENTS_FILE = None  # or a local coefficients.json exported from 01_train's MLflow run
    UDF_NAME = None  # choose a new plain lowercase name for a new coefficient revision
    UDF_SCHEMA = "EXAKIT_SCORING"
    TEST_ROWS = 500
    ALLOW_DATABASE_RESTART = False  # set True to consent if the shared bucket is unavailable
    return (
        ALLOW_DATABASE_RESTART,
        COEFFICIENTS_FILE,
        DATASET,
        TEST_ROWS,
        UDF_NAME,
        UDF_SCHEMA,
    )


@app.cell
def _(DATASET, UDF_NAME):
    import json
    import os
    import shutil
    import subprocess
    from pathlib import Path

    import numpy as np
    from scipy.special import expit
    import exakit.nb as nb

    nb.continue_workflow("rust-scoring")   # the quickstart's workflow, or the last one: nothing to paste

    connection = nb.connect()
    dataset_id = nb.chosen_dataset(DATASET)
    dataset = nb.dataset(connection, dataset_id).require_approved("rust scoring")
    SCORER_NAME = UDF_NAME or "score_" + dataset.id.replace("-", "_")[:40] + "_v" + str(dataset.version)
    handoff = nb.read_handoff(dataset.id)
    stale = nb.handoff_is_stale(connection, handoff, dataset)
    if stale:
        raise ValueError(stale)
    return (
        Path,
        SCORER_NAME,
        connection,
        dataset,
        expit,
        handoff,
        json,
        nb,
        np,
        os,
        shutil,
        subprocess,
    )


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Load the coefficients

    Uses the newest finished `01_train` run for this descriptor version, or `COEFFICIENTS_FILE`. The feature order must match the handoff. Use a new `UDF_NAME` for a new revision.
    """)
    return


@app.cell
def _(COEFFICIENTS_FILE, Path, dataset, handoff, json, os):
    source_run_id = None
    coefficients_path = COEFFICIENTS_FILE
    if coefficients_path is None:
        from mlflow.tracking import MlflowClient
        from exasol_mlflow import tracking
        _client = MlflowClient(tracking_uri=tracking.resolve().uri)
        _experiment = _client.get_experiment_by_name('exasol-starter-kit')
        if _experiment is None:
            raise FileNotFoundError('No MLflow experiment from 01_train. Run it first, or set COEFFICIENTS_FILE.')
        runs = _client.search_runs([_experiment.experiment_id], filter_string=f"tags.exasol.descriptor_id = '{dataset.id}' AND tags.exasol.language = 'python'", order_by=['attributes.start_time DESC'], max_results=20)
        matching = [item for item in runs if item.info.status == 'FINISHED' and item.data.tags.get('exasol.descriptor_version') == str(dataset.version)]
        if not matching:
            raise FileNotFoundError('No finished MLflow run for this descriptor version. Run 01_train again.')
        source_run_id = matching[0].info.run_id
        download_dir = Path(os.environ.get('EXAKIT_HOME') or Path.home() / '.exasol-starter-kit') / 'rust-udfs' / 'artifacts'
        download_dir.mkdir(parents=True, exist_ok=True)
        coefficients_path = _client.download_artifacts(matching[0].info.run_id, 'coefficients.json', str(download_dir))
    coefficients = json.loads(Path(coefficients_path).expanduser().read_text(encoding='utf-8'))
    features = coefficients['features']
    if features != [item['name'] for item in handoff['input_schema'] if item['name'] in features]:
        raise ValueError('Coefficient feature order differs from this handoff; rerun 01_train.')
    print('features in coefficient order:', ', '.join(features))
    return (
        MlflowClient,
        coefficients,
        coefficients_path,
        features,
        source_run_id,
        tracking,
    )


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Build and deploy

    Builds a Linux `.so` and deploys a SQL function. Without a shared bucket, the library goes into the RUST container, which restarts the database. Set `ALLOW_DATABASE_RESTART = True` to allow this.
    """)
    return


@app.cell
def _(
    ALLOW_DATABASE_RESTART,
    Path,
    SCORER_NAME,
    UDF_SCHEMA,
    coefficients_path,
    json,
    os,
    shutil,
    subprocess,
):
    def exakit(*arguments):
        found = shutil.which("exakit") or shutil.which("exakit.cmd")
        if found is None:
            home = Path(os.environ.get("EXAKIT_BIN_DIR") or Path.home() / ".local/bin")
            found = next((str(home / name) for name in ("exakit", "exakit.cmd") if (home / name).is_file()), None)
        if found is None:
            raise RuntimeError("The kit command is absent from this kernel's PATH and ~/.local/bin.")
        completed = subprocess.run([found, *arguments, "--json"], capture_output=True, text=True, check=False)
        try:
            answer = json.loads(completed.stdout)
        except ValueError as error:
            raise RuntimeError("The kit command returned invalid JSON: " + (completed.stderr or completed.stdout)[:300]) from error
        if completed.returncode:
            raise RuntimeError(answer.get("error", "Rust UDF command failed") +
                               ("; run: " + answer["remedy"] if answer.get("remedy") else ""))
        return answer

    project = exakit("rust-udf", "new", SCORER_NAME, "--coefficients", str(Path(coefficients_path).expanduser()))
    built = exakit("rust-udf", "build", SCORER_NAME)
    deploy_options = ["--yes"] if ALLOW_DATABASE_RESTART else []
    deployed = exakit("rust-udf", "deploy", SCORER_NAME, "--schema", UDF_SCHEMA, *deploy_options)
    print("Rust UDF:", deployed["udf"], "sha256", deployed["sha256"])
    return built, deployed, project


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Check parity

    The Rust scorer is a faster copy of the model. It must give the same answer on every row. Both score up to `TEST_ROWS` held-out rows. Every label must match, and the largest probability gap must be below `1e-9`. A difference stops the notebook.
    """)
    return


@app.cell
def _(
    TEST_ROWS,
    coefficients,
    connection,
    deployed,
    expit,
    features,
    handoff,
    nb,
    np,
):
    arguments = ', '.join((f'COALESCE(CAST(T."{feature}" AS DOUBLE), 0.0)' for feature in features))
    test_sql = f"""SELECT T.*, {deployed['udf']}({arguments}) AS RUST_P FROM ({handoff['training_sql']}) T WHERE T."SPLIT_" = 'test' LIMIT {TEST_ROWS}"""
    print(test_sql)
    test = nb.sql(connection, test_sql)
    _matrix = test[features].astype(float).fillna(0.0).to_numpy()
    weights = np.asarray(coefficients['coef'][0], dtype=float)
    expected = expit(_matrix @ weights + float(coefficients['intercept'][0]))
    actual = test['RUST_P'].astype(float).to_numpy()
    if len(test) == 0:
        raise ValueError('The handoff has no later test rows; review its split.')
    if not np.all(np.isfinite(expected)) or not np.all(np.isfinite(actual)):
        raise AssertionError('Parity requires finite probabilities from both scorers; inspect missing inputs and model coefficients.')
    gap = float(np.max(np.abs(expected - actual)))
    labels_match = np.array_equal(expected >= 0.5, actual >= 0.5)
    print(f'{len(test)} test rows; largest probability difference {gap:.3e}; labels agree: {labels_match}')
    if gap >= 1e-09 or not labels_match:
        raise AssertionError('Rust and Python predictions differ; inspect coefficient order, container and input values.')
    print('Rust and Python scoring agree on the held-out rows.')
    return gap, labels_match, test


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Record the run in MLflow

    Records a Rust run linked to the Python run, with the build hashes and the parity result.
    """)
    return


@app.cell
def _(
    MlflowClient,
    Path,
    built,
    dataset,
    deployed,
    gap,
    json,
    labels_match,
    nb,
    os,
    project,
    source_run_id,
    test,
    tracking,
):
    import hashlib
    kit_home = Path(os.environ.get('EXAKIT_HOME') or Path.home() / '.exasol-starter-kit')
    _matrix = json.loads((kit_home / 'kit' / 'versions.json').read_text(encoding='utf-8'))
    container = next((row for row in _matrix['components']['udf-devkit']['containers'] if row['language'] == 'rust' and row['arch'] == built['arch']), None)
    if container is None:
        raise RuntimeError(f"No pinned Rust container for {built['arch']}.")
    project_dir = Path(project['project'])
    lock_file = project_dir / 'Cargo.lock'
    if not lock_file.is_file():
        raise RuntimeError('The Rust build did not leave Cargo.lock; the run cannot be reproduced.')
    lock_digest = hashlib.sha256(lock_file.read_bytes()).hexdigest()
    _client = MlflowClient(tracking_uri=tracking.resolve().uri)
    _experiment = _client.get_experiment_by_name('exasol-starter-kit')
    experiment_id = _experiment.experiment_id if _experiment else _client.create_experiment('exasol-starter-kit')
    container_digest = deployed.get('container_sha256', container['sha256'])
    tags = {'exasol.language': 'rust', 'exasol.container_alias': container['alias'], 'exasol.container_digest': container_digest, 'exasol.base_container_digest': container['sha256'], 'exasol.rustc': built['rustc'], 'exasol.sdk': built['sdk'], 'exasol.cargo_lock_sha256': lock_digest, 'exasol.udf_sha256': built['sha256'], 'exasol.descriptor_id': dataset.id, 'exasol.descriptor_version': str(dataset.version), 'exasol.workflow_id': nb.current_workflow() or ''}
    if source_run_id:
        tags['exasol.source_run_id'] = source_run_id
    rust_run = _client.create_run(experiment_id, tags=tags)
    try:
        _client.log_metric(rust_run.info.run_id, 'rust_parity_max_abs_diff', gap)
        _client.log_metric(rust_run.info.run_id, 'rust_parity_rows', len(test))
        _client.log_metric(rust_run.info.run_id, 'rust_labels_agree', int(labels_match))
        for artifact_file in (lock_file, project_dir / 'exakit-rust.json', project_dir / 'build.json'):
            _client.log_artifact(rust_run.info.run_id, str(artifact_file), artifact_path='rust')
    except Exception:
        _client.set_terminated(rust_run.info.run_id, status='FAILED')
        raise
    _client.set_terminated(rust_run.info.run_id, status='FINISHED')
    nb.log_event('mlflow.run', run_id=rust_run.info.run_id, language='rust', descriptor_id=dataset.id, descriptor_version=dataset.version, container_digest=container_digest, cargo_lock_sha256=lock_digest, udf_sha256=built['sha256'])
    print('Rust scoring MLflow run:', rust_run.info.run_id)
    return


if __name__ == "__main__":
    app.run()
