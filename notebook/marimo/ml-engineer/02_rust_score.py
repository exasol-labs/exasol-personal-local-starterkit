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
    # Score the same test rows with Rust

    - **Dataset:** Pharma, Banking, or your own approved descriptor and handoff.
    - **How long:** about fifteen minutes on the first Rust build, less on later builds.

    `01_train` exports raw-feature coefficients to MLflow. This notebook retrieves
    the newest run for this descriptor, builds a Linux Rust UDF for the database's
    architecture, and compares its probabilities and labels with the Python
    formula on the same held-out rows. A stale handoff is refused before building.
    """)
    return


@app.cell
def _():
    DATASET = "pharma_trials"  # or banking_complaints, or your own approved descriptor
    COEFFICIENTS_FILE = None  # or a local coefficients.json exported from 01_train's MLflow run
    UDF_NAME = "score_pharma"  # choose a new plain lowercase name for a new coefficient revision
    UDF_SCHEMA = "EXAKIT_SCORING"
    TEST_ROWS = 500
    return COEFFICIENTS_FILE, DATASET, TEST_ROWS, UDF_NAME, UDF_SCHEMA


@app.cell
def _(DATASET):
    import json
    import os
    import shutil
    import subprocess
    from pathlib import Path

    import numpy as np
    from scipy.special import expit
    import exakit.nb as nb

    conn = nb.connect()
    ds = nb.dataset(conn, DATASET).require_approved("rust scoring")
    handoff = nb.read_handoff(ds.id)
    stale = nb.handoff_is_stale(conn, handoff, ds)
    if stale:
        raise ValueError(stale)
    return Path, conn, ds, expit, handoff, json, nb, np, os, shutil, subprocess


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Find the exact coefficient artifact

    The newest finished run must carry this descriptor id and version. For a
    remote MLflow server, the client downloads the artifact into the kit home.
    """)
    return


@app.cell
def _(COEFFICIENTS_FILE, Path, ds, handoff, json, os):
    if COEFFICIENTS_FILE is None:
        from mlflow.tracking import MlflowClient
        from exasol_mlflow import tracking
        client = MlflowClient(tracking_uri=tracking.resolve().uri)
        experiment = client.get_experiment_by_name('exasol-starter-kit')
        if experiment is None:
            raise FileNotFoundError('No MLflow experiment from 01_train. Run it first, or set COEFFICIENTS_FILE.')
        runs = client.search_runs([experiment.experiment_id], filter_string=f"tags.exasol.descriptor_id = '{ds.id}'", order_by=['attributes.start_time DESC'], max_results=20)
        matching = [item for item in runs if item.info.status == 'FINISHED' and item.data.tags.get('exasol.descriptor_version') == str(ds.version)]
        if not matching:
            raise FileNotFoundError('No finished MLflow run for this descriptor version. Run 01_train again.')
        download_dir = Path(os.environ.get('EXAKIT_HOME') or Path.home() / '.exasol-starter-kit') / 'rust-udfs' / 'artifacts'
        download_dir.mkdir(parents=True, exist_ok=True)
        COEFFICIENTS_FILE_1 = client.download_artifacts(matching[0].info.run_id, 'coefficients.json', str(download_dir))
    coefficients = json.loads(Path(COEFFICIENTS_FILE_1).expanduser().read_text(encoding='utf-8'))
    features = coefficients['features']
    if features != [item['name'] for item in handoff['input_schema'] if item['name'] in features]:
        raise ValueError('Coefficient feature order differs from this handoff; rerun 01_train.')
    print('features in coefficient order:', ', '.join(features))
    return COEFFICIENTS_FILE_1, coefficients, features


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Build and deploy

    The command pins exasol-udf-sdk 0.33.0 and rustc 1.98.1. On macOS it builds
    inside the matching Linux Docker or Podman image, validates the `.so`, copies
    it into the deployment bucket directory and registers the RUST script.
    """)
    return


@app.cell
def _(
    COEFFICIENTS_FILE_1,
    Path,
    UDF_NAME,
    UDF_SCHEMA,
    json,
    os,
    shutil,
    subprocess,
):
    def exakit(*arguments):
        found = shutil.which('exakit') or shutil.which('exakit.cmd')
        if found is None:
            home = Path(os.environ.get('EXAKIT_BIN_DIR') or Path.home() / '.local/bin')
            found = next((str(home / name) for name in ('exakit', 'exakit.cmd') if (home / name).is_file()), None)
        if found is None:
            raise RuntimeError("The kit command is absent from this kernel's PATH and ~/.local/bin.")
        completed = subprocess.run([found, *arguments, '--json'], capture_output=True, text=True, check=False)
        try:
            answer = json.loads(completed.stdout)
        except ValueError as error:
            raise RuntimeError('The kit command returned invalid JSON: ' + (completed.stderr or completed.stdout)[:300]) from error
        if completed.returncode:
            raise RuntimeError(answer.get('error', 'Rust UDF command failed') + ('; run: ' + answer['remedy'] if answer.get('remedy') else ''))
        return answer
    project = exakit('rust-udf', 'new', UDF_NAME, '--coefficients', str(Path(COEFFICIENTS_FILE_1).expanduser()))
    built = exakit('rust-udf', 'build', UDF_NAME)
    deployed = exakit('rust-udf', 'deploy', UDF_NAME, '--schema', UDF_SCHEMA)
    print('Rust UDF:', deployed['udf'], 'sha256', deployed['sha256'])
    return (deployed,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Compare on the same later 20 percent

    The handoff's split expression selects the test rows. Its SQL is printed
    before interpreting the result. Differences above 1e-9 or any differing
    class label fail the check.
    """)
    return


@app.cell
def _(
    TEST_ROWS,
    coefficients,
    conn,
    deployed,
    expit,
    features,
    handoff,
    nb,
    np,
):
    arguments = ", ".join(f'CAST(T."{feature}" AS DOUBLE)' for feature in features)
    test_sql = (f'SELECT T.*, {deployed["udf"]}({arguments}) AS RUST_P '
                f'FROM ({handoff["training_sql"]}) T WHERE T."SPLIT_" = \'test\' LIMIT {TEST_ROWS}')
    print(test_sql)
    test = nb.sql(conn, test_sql)
    matrix = test[features].astype(float).to_numpy()
    weights = np.asarray(coefficients["coef"][0], dtype=float)
    expected = expit(matrix @ weights + float(coefficients["intercept"][0]))
    actual = test["RUST_P"].astype(float).to_numpy()
    if len(test) == 0:
        raise ValueError("The handoff has no later test rows; review its split.")
    gap = float(np.max(np.abs(expected - actual)))
    labels_match = np.array_equal(expected >= 0.5, actual >= 0.5)
    print(f"{len(test)} test rows; largest probability difference {gap:.3e}; labels agree: {labels_match}")
    if gap >= 1e-9 or not labels_match:
        raise AssertionError("Rust and Python predictions differ; inspect coefficient order, container and input values.")
    print("Rust and Python scoring agree on the held-out rows.")
    return


if __name__ == "__main__":
    app.run()
