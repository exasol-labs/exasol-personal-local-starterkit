# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Prepare a trustworthy place to train
#
# **Dataset:** `pharma_trials` by default; Banking or your own described file can follow. **How long:** about five minutes once the required runtimes are installed.
#
# The Data Scientist has identified a question and a column map. Your job is to turn that work into a repeatable training and scoring flow. Start by checking the environment before interpreting any model metric.
#
# **By the end:** you will know whether the database can run Python, where training runs are recorded, whether shared model files are visible and which outcome the first query describes. The following chapters train in Exasol, verify a Rust scorer and try a trusted model file.
#
# **Optional AI:** this path uses SQL and scikit-learn as supplied; an LLM endpoint is optional. An assistant can help you inspect code or propose a later experiment, while the checks and measured results remain yours to validate.
#
# **Run first:** install the ML Engineer persona or UDF devkit. `exakit udf-use default` supplies the ML runtime; a container installation can restart the database.

# %% [markdown]
# ## Keep the investigation connected to the training run
#
# Use one workflow ID to follow the approved data, checks and model runs. If you continue the Data Scientist's investigation, start the kernel with its `EXAKIT_WORKFLOW_ID`; otherwise this cell creates a fresh workflow.
#
# **Technical note:** each logged step carries the same identifier, and MLflow runs can carry it as a tag. Keep the printed `exakit workflow show ...` command so you can inspect the trail later.

# %%
import os
import exakit.nb as nb

wid = nb.workflow("ml-engineer-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {wid}")

# %% [markdown]
# ## Choose the Python that runs inside the database
#
# The notebook's Python prepares the work. A separate Python runtime inside Exasol executes the training UDF, which is a function you call from SQL. It needs its own copies of scikit-learn and the other training packages.
#
# **Read the result:** keep the default `CONTAINER` for the first run. The printed alias identifies the runtime the next check and training notebook will use.
#
# **Technical note:** `exakit udf-use default` installs `PYTHON3_ML` with the ML packages; `exakit udf-setup` installs the official `PYTHON3` alternative. `PYTHON3_ML` is preferred when installed. `EXAKIT_UDF_CONTAINER` can select another installed alias. If none is ready, the helper stops and names the installation command.

# %%
CONTAINER = nb.ml_train.udf_container()   # or "PYTHON3_ML", "PYTHON3", or the alias of a container you installed
print(f"container alias: {CONTAINER}")

# %% [include] ../00_shared/data_paths.py connect

# %% [markdown]
# ## Prove the database can import its training packages
#
# A package working in Jupyter does not establish that it works inside Exasol. The next cell runs a small UDF in the selected runtime and checks what it imports.
#
# **Read the result:** continue when the check reports success. If it prints a failure, use the command it names for that exact alias and repeat the check before training.
#
# **Technical note:** this is a smoke test of the database-side Python and required package versions. The useful lesson `01_udf_package_check` shows a fuller package report.

# %%
container_ok = nb.check_container(conn, alias=CONTAINER)

# %% [markdown]
# ## Decide where the experiment record goes
#
# A useful experiment includes its inputs, settings, metrics and model files. MLflow is the experiment record you can inspect and compare after training; it is independent of any optional LLM endpoint.
#
# **Read the result:** the check reports the destination this notebook will actually use. For the local browser UI, run `exakit mlflow start` and open the address from `exakit mlflow url`.
#
# **Technical note:** `MLFLOW_TRACKING_URI` selects another configured server. Otherwise the helper uses the kit server or its local store under `~/.exasol-starter-kit/mlflow/`. The client records the UDF's result; database training does not need MLflow credentials.

# %%
mlflow_ok = nb.check_mlflow()

# %% [markdown]
# ## Check the path a scoring function will read
#
# A trained model can be a file on your computer, but a database function must see that file from inside its runtime. The next check tests the kit's shared model directory and its visibility in a UDF.
#
# **Read the result:** success makes the shared-file scoring route available. Record a failed check and its reason. Rust has a separate container-packaging fallback that asks before a needed restart; Python model-file scoring still needs a working shared directory.
#
# **Technical note:** `exakit model list --json` reports the host directory and the `/buckets/...` path a UDF uses. This check does not make a missing shared directory pass by assumption.

# %%
bucket_ok = nb.check_bucket(conn)

# %% [include] ../00_shared/data_paths.py load

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ## Confirm the outcome before teaching a model
#
# Count the records and positive outcomes in each category. Pharma's label is trial termination; Banking's is monetary relief. Check that this matches the question handed to you.
#
# **Read the result:** a positive label means the chosen outcome occurred. It does not mean that the outcome is desirable. The query shows which groups and class balance the later training recipe will encounter.
#
# **Technical note:** the query uses the approved role map. Missing category or label roles produce the explained fallback rather than an invented column.

# %%
skipped = {m["role"]: m["reason"] for m in ds.missing}
for role, instead in (("category", "rows are counted per entity instead"),
                      ("label", "the label count is left out, and 01_train has nothing to predict until a label role is approved")):
    if role in skipped:
        print(f"No {role} role ({skipped[role]}): {instead}; the steps that need it later say so.")
BY = ds.col("category") if ds.has("category") else ds.col("entity")
LABEL_1 = f",\n       SUM({ds.col('label')}) AS LABEL_1" if ds.has("label") else ""
first_rows = nb.sql(conn, f"""
SELECT {BY} AS CATEGORY,
       COUNT(*) AS N{LABEL_1}
FROM {ds.fact_table}
GROUP BY {BY}
ORDER BY N DESC
LIMIT 10""")
nb.show_sql()
first_rows

# %% [markdown]
# ## Move from readiness to a repeatable experiment
#
# Run `data-scientist/01_explore.ipynb` through its handoff cell for the chosen dataset, then open `01_train.ipynb`. A **handoff** is the saved recipe tying the approved column map, data fingerprint, features and split together.
#
# Change one `DATASET` assignment in the training notebook to follow Banking or your own described file. Keep the default runtime until the first experiment is working.
