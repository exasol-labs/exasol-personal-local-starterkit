# exasol-mlflow

Train inside Exasol and log from the client to MLflow. The database UDF needs no network access or MLflow credentials.

The Starter Kit's training template is `udf/templates/train_model.sql`. Render it from an approved descriptor's
handoff, then run its training query:

```python
from udf.templates import render
import exasol_mlflow

create = render.render_train(
    schema="STARTER_KIT", name="TRAIN_MODEL",
    features=[item["name"] for item in handoff["input_schema"]],
    label=handoff["label"]["column"], positive=handoff["label"]["positive"],
)
query = render.train_sql(
    schema="STARTER_KIT", name="TRAIN_MODEL",
    training_sql=handoff["training_sql"], run_key="dataset-v1",
    label=handoff["label"]["column"],
    features=[item["name"] for item in handoff["input_schema"]],
)
conn.execute(handoff["feature_view"]["sql"])
conn.execute(create)
with exasol_mlflow.start_run(conn, handoff=handoff, experiment="my-experiment") as run:
    run.execute(query)
print(run.run_id, run.metrics, run.artifact_uri)
```

The kit's text-classifier example is also available through `create_script(schema)` and `call(schema)`.

Each UDF result has a run key, JSON parameters and metrics, a model or an error, language, container digest,
package versions and optional coefficients. `contract.py` validates every field and names the broken field. A
valid grouped result logs one MLflow run per key. Models up to 1 MiB travel inline; larger models use a
`/buckets/...` path, whose bytes and SHA-256 the client checks before logging.

`MLFLOW_TRACKING_URI` selects a remote server. The client accepts `MLFLOW_TRACKING_USERNAME` and
`MLFLOW_TRACKING_PASSWORD` for Basic authentication, or `MLFLOW_TRACKING_TOKEN` for Bearer authentication.
Unset, it uses the kit's local server when `exakit mlflow start` has recorded one, then the local SQLite store.
The health check runs before training SQL. A database disconnect marks the run failed. If logging fails after a
valid result, the record stays under `$EXAKIT_HOME/mlflow/spool/`; `python -m exasol_mlflow replay` sends it
again. `python -m exasol_mlflow status --json` lists pending records.

Install the client with `pip install "exasol-mlflow[mlflow]"`. A local server needs
`pip install "exasol-mlflow[server]"`; the kit's notebook and ML Engineer persona manage these packages.
