# exasol-mlflow

Train inside Exasol with a Python UDF, and log the run to **your** MLflow from
the client: the parameters, the metrics, the training SQL, the model file and
the lineage tags `exasol.session_id`, `exasol.statement_id` and
`exasol.deployment`. The UDF needs no MLflow credentials and no network.

```python
import exasol_mlflow
conn.execute(exasol_mlflow.create_script("ML"))          # the training UDF
run = exasol_mlflow.log_training(conn, f"""
    SELECT {exasol_mlflow.call("ML")}(LABEL_COL, CATEGORY_COL, TEXT_COL, '{{"C": 1.0, ...}}')
    FROM MY.TABLE""", experiment="my-experiment")
run.run_id, run.metrics, run.artifact_uri
```

- **Where the run goes:** `MLFLOW_TRACKING_URI` when set; otherwise a local
  store (`mlflow/mlflow.db` and `mlflow/artifacts`), which
  `mlflow ui --backend-store-uri sqlite:///mlflow/mlflow.db` opens.
- **Your own UDF:** any UDF that emits `PART`, `CHUNK` and, on part 0,
  `TRAINING_RESULT` (the contract in `exasol_mlflow/contract.py`) can be
  logged the same way. A result that breaks the contract raises
  `ResultContractError` and logs nothing.
- **Install:** `pip install "exasol-mlflow[mlflow]"`; the Exasol Personal
  Local Starter Kit's notebook add-on installs it for you.
