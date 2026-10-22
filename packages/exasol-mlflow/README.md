# exasol-mlflow

Train inside Exasol with a Python UDF, and log the run to **your** MLflow from
the client: the parameters, the metrics, the training SQL, the model file and
the lineage tags `exasol.session_id`, `exasol.statement_id` and
`exasol.deployment`. The UDF needs no MLflow credentials and no network.

```python
import exasol_mlflow
conn.execute(exasol_mlflow.create_script("ML"))          # the training UDF
with exasol_mlflow.start_run(conn, params={"C": 1.0}, experiment="my-experiment") as run:
    run.execute(f"""
        SELECT {exasol_mlflow.call("ML")}(LABEL_COL, CATEGORY_COL, TEXT_COL, '{{"C": 1.0, ...}}')
        FROM MY.TABLE""")
run.run_id, run.metrics, run.artifact_uri
```

`run.execute` checks the UDF's answer before it opens the MLflow run, which
stays open until the `with` block ends (log more inside it; an error marks it
failed). One training statement per run. `log_training(conn, sql,
experiment=...)` does the same in one call.

- **Where the run goes:** `MLFLOW_TRACKING_URI` when set; otherwise a local
  store (`mlflow/mlflow.db` and `mlflow/artifacts`), which
  `mlflow ui --backend-store-uri sqlite:///mlflow/mlflow.db` opens.
- **Your own UDF:** any UDF that emits `PART`, `CHUNK` and, on part 0,
  `TRAINING_RESULT` (the contract in `exasol_mlflow/contract.py`) can be
  logged the same way. A result that breaks the contract raises
  `ResultContractError` and logs nothing.
- **The model travels inline**, base64 in chunks of 1.9 million characters,
  so its size is not limited by one value. A path under the host folder a
  local deployment maps for BucketFS is not used: a UDF sees BucketFS
  read-only, and a local deployment has no BucketFS endpoint to upload to.
- **Install:** `pip install "exasol-mlflow[mlflow]"`; the Exasol Personal
  Local Starter Kit's notebook add-on installs it for you.
