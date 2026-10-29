# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Give the same trained model a Rust scorer
#
# **Dataset:** Pharma, Banking or your own approved descriptor and handoff. **How long:** about fifteen minutes for a first build, less for later builds.
#
# You already trained a linear model in Python. Now test whether a compiled Rust function can score the same later records with the same probabilities and labels. This checks a second implementation of the model; it does not train a new model or establish that the original model is useful.
#
# **By the end:** you will have a validated Linux library, a callable SQL scoring function, a parity result and a Rust record in MLflow.
#
# **Run first:** `01_train`, the `RUST` container (`exakit udf-setup --language rust`) and a running Docker or Podman Linux build engine. **Optional AI:** no LLM endpoint is required. Use an assistant to review the formula if helpful, then rely on the numerical comparison.

# %%
DATASET = "pharma_trials"  # or banking_complaints, or your own approved descriptor
COEFFICIENTS_FILE = None  # or a local coefficients.json exported from 01_train's MLflow run
UDF_NAME = "score_pharma"  # choose a new plain lowercase name for a new coefficient revision
UDF_SCHEMA = "EXAKIT_SCORING"
TEST_ROWS = 500
ALLOW_DATABASE_RESTART = False  # set True to consent if the shared bucket is unavailable
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
# ## Bring the exact coefficients, not a similar experiment
#
# Choose the model tied to this approved descriptor version. The default finds the newest finished Python run for that version and downloads its coefficients. You can instead set `COEFFICIENTS_FILE` to the file exported by training.
#
# **Read the result:** check the ordered feature list. Each coefficient must multiply the same input column in Python and Rust. A stale handoff or different feature order stops this step.
#
# **Technical note:** the artifact carries raw-feature coefficients, intercept and class order. The source MLflow run is retained for lineage. Choose a new `UDF_NAME` for a different coefficient revision so an existing project is preserved.

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
# ## Build for the database, then choose the deployment route
#
# The scorer runs inside the database's Linux runtime, including when you work on a Mac. The next cell creates the project, builds and validates its `.so` library, then deploys a SQL function.
#
# **Read the result:** a usable shared bucket gives the normal file route. Without one, the kit can package the library into the RUST runtime. Keep `ALLOW_DATABASE_RESTART = False` until you are ready to permit that update; set it to `True` deliberately and rerun deployment when prompted. A verified unchanged packaged library can be reused without another restart.
#
# **Technical note:** the build pins exasol-udf-sdk 0.33.0 and rustc 1.98.1 and targets the database architecture. Deployment verifies library digests and actual UDF visibility, or uses the consented container fallback. The returned deployment details identify the route and resulting container digest.

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
deploy_options = ["--yes"] if ALLOW_DATABASE_RESTART else []
deployed = exakit("rust-udf", "deploy", UDF_NAME, "--schema", UDF_SCHEMA, *deploy_options)
print("Rust UDF:", deployed["udf"], "sha256", deployed["sha256"])

# %% [markdown]
# ## Test the claim that both scorers are equivalent
#
# Look at the largest probability difference and whether the predicted labels agree. If either check fails, investigate feature ordering, missing inputs, coefficients and runtime compatibility before using the scorer.
#
# **Technical note:** the query uses the handoff's later test partition and compares up to `TEST_ROWS` records, 500 by default. The Python formula is a sigmoid over the exported raw-feature weights. Every tested label must match and the largest probability difference must be below `1e-9`. This is evidence for the tested rows; adjust the row limit when your verification needs broader coverage.

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
# ## Leave a trail from the scorer back to its training run
#
# After a passing comparison, inspect the Rust run in MLflow. It should lead back to the source Python run and the descriptor version. This lets a colleague identify which library and recipe produced the scores.
#
# **Technical note:** the run records the actual scoring-container digest, its base-container digest, rustc/SDK pins, Cargo.lock and library hashes, comparison row count and maximum difference. Build records are attached as artifacts. A successful parity check preserves the original model's behaviour; model-quality acceptance remains a separate check.

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
container_digest = deployed.get("container_sha256", container["sha256"])
tags = {"exasol.language": "rust", "exasol.container_alias": container["alias"],
        "exasol.container_digest": container_digest, "exasol.base_container_digest": container["sha256"],
        "exasol.rustc": built["rustc"],
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
             descriptor_version=ds.version, container_digest=container_digest,
             cargo_lock_sha256=lock_digest, udf_sha256=built["sha256"])
print("Rust scoring MLflow run:", rust_run.info.run_id)
