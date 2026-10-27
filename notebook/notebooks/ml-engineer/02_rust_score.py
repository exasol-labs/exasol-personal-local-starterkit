# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Score the same test rows with Rust
#
# - **Dataset:** Pharma, Banking, or your own approved descriptor and handoff.
# - **How long:** about fifteen minutes on the first Rust build, less on later builds.
#
# `01_train` exports raw-feature coefficients to MLflow. This notebook retrieves
# the newest run for this descriptor, builds a Linux Rust UDF for the database's
# architecture, and compares its probabilities and labels with the Python
# formula on the same held-out rows. A stale handoff is refused before building.

# %%
DATASET = "pharma_trials"  # or banking_complaints, or your own approved descriptor
COEFFICIENTS_FILE = None  # or a local coefficients.json exported from 01_train's MLflow run
UDF_NAME = "score_pharma"  # choose a new plain lowercase name for a new coefficient revision
UDF_SCHEMA = "EXAKIT_SCORING"
TEST_ROWS = 500
WORKFLOW_ID = None  # paste the ML quickstart's wf-... id to continue its log

# %%
import json
import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
from scipy.special import expit
import exakit.nb as nb

if WORKFLOW_ID:
    nb.workflow(resume=WORKFLOW_ID)
elif not nb.current_workflow():
    nb.workflow("rust-scoring")

conn = nb.connect()
ds = nb.dataset(conn, DATASET).require_approved("rust scoring")
handoff = nb.read_handoff(ds.id)
stale = nb.handoff_is_stale(conn, handoff, ds)
if stale:
    raise ValueError(stale)

# %% [markdown]
# ## Find the exact coefficient artifact
#
# The newest finished run must carry this descriptor id and version. For a
# remote MLflow server, the client downloads the artifact into the kit home.

# %%
source_run_id = None
if COEFFICIENTS_FILE is None:
    from mlflow.tracking import MlflowClient
    from exasol_mlflow import tracking

    client = MlflowClient(tracking_uri=tracking.resolve().uri)
    experiment = client.get_experiment_by_name("exasol-starter-kit")
    if experiment is None:
        raise FileNotFoundError("No MLflow experiment from 01_train. Run it first, or set COEFFICIENTS_FILE.")
    runs = client.search_runs([experiment.experiment_id],
                              filter_string=(f"tags.exasol.descriptor_id = '{ds.id}' "
                                             "AND tags.exasol.language = 'python'"),
                              order_by=["attributes.start_time DESC"], max_results=20)
    matching = [item for item in runs if item.info.status == "FINISHED" and
                item.data.tags.get("exasol.descriptor_version") == str(ds.version)]
    if not matching:
        raise FileNotFoundError("No finished MLflow run for this descriptor version. Run 01_train again.")
    source_run_id = matching[0].info.run_id
    download_dir = Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit") / "rust-udfs" / "artifacts"
    download_dir.mkdir(parents=True, exist_ok=True)
    COEFFICIENTS_FILE = client.download_artifacts(matching[0].info.run_id, "coefficients.json", str(download_dir))
coefficients = json.loads(Path(COEFFICIENTS_FILE).expanduser().read_text(encoding="utf-8"))
features = coefficients["features"]
if features != [item["name"] for item in handoff["input_schema"] if item["name"] in features]:
    raise ValueError("Coefficient feature order differs from this handoff; rerun 01_train.")
print("features in coefficient order:", ", ".join(features))

# %% [markdown]
# ## Build and deploy
#
# The command pins exasol-udf-sdk 0.33.0 and rustc 1.98.1. On macOS it builds
# inside the matching Linux Docker or Podman image, validates the `.so`, copies
# it into the deployment bucket directory and registers the RUST script.

# %%
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

project = exakit("rust-udf", "new", UDF_NAME, "--coefficients", str(Path(COEFFICIENTS_FILE).expanduser()))
built = exakit("rust-udf", "build", UDF_NAME)
deployed = exakit("rust-udf", "deploy", UDF_NAME, "--schema", UDF_SCHEMA)
print("Rust UDF:", deployed["udf"], "sha256", deployed["sha256"])

# %% [markdown]
# ## Compare on the same later 20 percent
#
# The handoff's split expression selects the test rows. Its SQL is printed
# before interpreting the result. Differences above 1e-9 or any differing
# class label fail the check.

# %%
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

# %% [markdown]
# ## Record the validated Rust run
#
# The MLflow run holds the source training run (when available), descriptor,
# container and compiler pins, Cargo.lock digest, library digest, row count and
# parity result. The project manifest and build record are attached as artifacts.

# %%
import hashlib
from mlflow.tracking import MlflowClient
from exasol_mlflow import tracking

kit_home = Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit")
matrix = json.loads((kit_home / "kit" / "versions.json").read_text(encoding="utf-8"))
container = next((row for row in matrix["components"]["udf-devkit"]["containers"]
                  if row["language"] == "rust" and row["arch"] == built["arch"]), None)
if container is None:
    raise RuntimeError(f"No pinned Rust container for {built['arch']}.")
project_dir = Path(project["project"])
lock_file = project_dir / "Cargo.lock"
if not lock_file.is_file():
    raise RuntimeError("The Rust build did not leave Cargo.lock; the run cannot be reproduced.")
lock_digest = hashlib.sha256(lock_file.read_bytes()).hexdigest()
client = MlflowClient(tracking_uri=tracking.resolve().uri)
experiment = client.get_experiment_by_name("exasol-starter-kit")
experiment_id = experiment.experiment_id if experiment else client.create_experiment("exasol-starter-kit")
tags = {"exasol.language": "rust", "exasol.container_alias": container["alias"],
        "exasol.container_digest": container["sha256"], "exasol.rustc": built["rustc"],
        "exasol.sdk": built["sdk"], "exasol.cargo_lock_sha256": lock_digest,
        "exasol.udf_sha256": built["sha256"], "exasol.descriptor_id": ds.id,
        "exasol.descriptor_version": str(ds.version), "exasol.workflow_id": nb.current_workflow() or ""}
if source_run_id:
    tags["exasol.source_run_id"] = source_run_id
rust_run = client.create_run(experiment_id, tags=tags)
try:
    client.log_metric(rust_run.info.run_id, "rust_parity_max_abs_diff", gap)
    client.log_metric(rust_run.info.run_id, "rust_parity_rows", len(test))
    client.log_metric(rust_run.info.run_id, "rust_labels_agree", int(labels_match))
    for artifact_file in (lock_file, project_dir / "exakit-rust.json", project_dir / "build.json"):
        client.log_artifact(rust_run.info.run_id, str(artifact_file), artifact_path="rust")
except Exception:
    client.set_terminated(rust_run.info.run_id, status="FAILED")
    raise
client.set_terminated(rust_run.info.run_id, status="FINISHED")
nb.log_event("mlflow.run", run_id=rust_run.info.run_id, language="rust", descriptor_id=ds.id,
             descriptor_version=ds.version, container_digest=container["sha256"],
             cargo_lock_sha256=lock_digest, udf_sha256=built["sha256"])
print("Rust scoring MLflow run:", rust_run.info.run_id)
