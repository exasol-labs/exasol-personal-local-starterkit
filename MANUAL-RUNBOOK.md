# Mac: clean install and test both personas

Run these steps in Terminal. They test the bundled Pharma and Banking data, Python training, Rust scoring, Ask and Share. Virtual schemas and external data connections are outside this runbook.

## 1. Remove the previous installation

**This removes kit-owned components, including a database the kit created and its data, dashboards and notebooks. Save anything you need first.** Reused user-installed components and databases are kept. Preview the removal, then run it and choose **EVERYTHING** in the menu:

```sh
export PATH="$HOME/.local/bin:$PATH"
EXAKIT_UNINSTALL_NOTEBOOKS=remove exakit uninstall --dry-run
EXAKIT_UNINSTALL_NOTEBOOKS=remove exakit uninstall
```

If `exakit` is not installed, start at step 2. Keep the source checkout on your Desktop.

For a completely fresh database, use a machine with no existing Exasol deployment, or remove your own deployment separately using its original management tool. The kit deliberately keeps reused deployments. `exakit version` shows the component owner; see [component ownership](COMPONENT-OWNERSHIP.md).

## 2. Install with curl

Use this command to install **the current local work** with both personas:

```sh
curl -fsSL https://www.exasol.com/install/starter-kit.sh | \
  EXAKIT_LOCAL_KIT="/Users/sheetaldharshan.a/Desktop/starterkit-0.2.0" \
  EXAKIT_PERSONA=data-scientist,ml-engineer sh
```

The local override is needed because these changes have not been published. The ordinary public command, `curl -fsSL https://www.exasol.com/install/starter-kit.sh | sh`, installs the published kit instead.

Both personas automatically select **Pharma + Banking**, **Notebook + JSON Tables + Dash Server + UDF devkit**, and local MLflow. Wait for the installer to finish, then:

```sh
export PATH="$HOME/.local/bin:$PATH"
exakit status
exakit persona plan data-scientist,ml-engineer
exakit notebook check
exakit mcp-doctor --json
```

Expected: database **running**, persona plan **Nothing pending**, notebooks connect, MCP doctor succeeds.

Data Scientist selects Notebook, JSON Tables and Dash Server. ML Engineer selects Notebook, JSON Tables and UDF devkit, with local MLflow. JSON Tables supports CLI JSON ingestion; dbt, Scheduler and the VS Code extension are optional for transformation projects, scheduled jobs and editor integration.

## 3. Check the bundled datasets

```sh
exakit data-load pharma_trials
exakit data-load banking_complaints
exakit sql 'SELECT COUNT(*) AS N FROM PHARMA.PHARMA_TRIALS'
exakit sql 'SELECT COUNT(*) AS N FROM BANKING.BANKING_COMPLAINTS'
```

The datasets should already be loaded. Expected snapshot counts: **5,169 Pharma trials** and **6,754 Banking complaints**.

## 4. Prepare Rust and Share

```sh
exakit udf-setup --language rust
exakit mlflow status
exakit marketplace --list
exakit mcp-setup
exakit start dash-server
exakit status
```

Dash Server and JSON Tables should already be installed by the personas; check them in the marketplace list. Agree to the Rust container installation when asked; it can restart the database. Python remains available for training. If MLflow is stopped, run `exakit mlflow start`.

## 5. Test the Data Scientist flow

```sh
exakit notebook
```

In JupyterLab select the **Exasol (Starter Kit)** kernel. Open these files in order under `starter-kit-notebooks/data-scientist/`:

| Notebook | What to do | Expected result |
|---|---|---|
| `00_quickstart.ipynb` | Keep `SAMPLE = "pharma_trials"`. Run cells in order; review the roles and click **Approve descriptor**. Leave the own-file and connected-source settings at their defaults. | Connected, approved roles, first query returns rows, workflow ID printed. |
| `01_explore.ipynb` | Keep `DATASET = "pharma_trials"`. Run all cells. | SQL and results displayed; exploration/model steps finish; ML handoff written. With no model endpoint, the optional text/trace step says it is skipped or off. |
| `02_ask_your_data.ipynb` | Leave `DRAFT_WITH_MODEL = False`. Read the proposed SQL. First leave `APPROVE_SQL = False`, then set it to `True` and rerun that cell. | No query before approval; after approval, category counts returned through read-only MCP. |
| `03_share.ipynb` | Set `APP_NAME = "pharma-category-check"`. Run through Preview; open its URL and compare the figures with the printed SQL. Then set `FIGURES_CHECKED = True` and run the final cell. | Healthy preview, matching figures, live Dash Server URL. |

Paste the quickstart's workflow ID into `WORKFLOW_ID` in the other notebooks to keep one log. To test Banking, repeat with `SAMPLE`/`DATASET = "banking_complaints"` and Share's `APP_NAME = "banking-category-check"`.

## 6. Test the ML Engineer flow

Open these files in order under `starter-kit-notebooks/ml-engineer/`:

| Notebook | What to do | Expected result |
|---|---|---|
| `00_quickstart.ipynb` | Keep the Pharma default. Run the checks and review/approve roles. | Container, MLflow and bucket checks pass. |
| `01_train.ipynb` | Keep `DATASET = "pharma_trials"` and the default seed. Run it, then repeat the training cell without changing inputs. | Two MLflow runs with identical metrics; macro-F1 beats the majority baseline; model and coefficients recorded. |
| `02_rust_score.ipynb` | Run after training. Keep the default dataset and `UDF_NAME = "score_pharma"`. | Rust builds/deploys; labels match Python and maximum probability difference is below `1e-9`; Rust run recorded in MLflow. |
| `03_score_external_model.ipynb` | Keep `MODEL_FILE = None` to use its built-in local model example. Run all cells. | Model copied to bucket; database and local predictions match. A version-mismatch skip is not a pass. |

For Banking repeat with `DATASET = "banking_complaints"` and Rust's `UDF_NAME = "score_banking"`. Keep the default container selection for training.

## 7. Final checks

```sh
exakit mlflow url
exakit model list
exakit workflow list
exakit workflow show YOUR_WORKFLOW_ID --json
exakit status --json
```

Open the MLflow URL and check the training/Rust runs, metrics and artifacts. Open the Share notebook's live dashboard URL. The workflow log should connect the approved descriptor, SQL, handoff, MLflow run and dashboard revision. Record a pass/fail beside each notebook.

When finished, stop the notebook service:

```sh
exakit notebook stop
```

To stop the whole kit as well, run `exakit stop`.

## Optional: test your own file

In the Data Scientist quickstart set `OWN_FILE` to your CSV, Parquet or JSON file and `OWN_TABLE` to a new table such as `MY_DATA.TEST_FILE`. Run its load cell, correct/approve the roles, then set Explore's `DATASET` to that file path and rerun. Use the notebook's own-file loader for this flow; it normalizes column names for Describe.

Live model drafting/Langfuse tracing need your own endpoint and keys. Windows live verification and the Rust fallback for a deployment without a bucket remain separate checks.

## 10. Extra lessons from Notebook Connector / AI Lab

In either JupyterLab or Marimo, open the persona folder and run these in order:

| Persona | File stem | Expected result |
|---|---|---|
| Data Scientist | `04_sql_and_dataframes` | SQL category totals agree with an independent count |
| Data Scientist | `05_decision_tree_baseline` | Local scikit-learn decision tree reports held-out accuracy and macro-F1 |
| ML Engineer | `04_udf_package_check` | Versions of scikit-learn, pandas, NumPy, SciPy and joblib imported **inside Exasol** |
| ML Engineer | `05_decision_tree_udf` | Decision tree trained inside a SET UDF reports train/test counts and metrics |

Jupyter files end in `.ipynb`; Marimo files end in `.py`. Repeat with
`DATASET = "banking_complaints"`. The source links and MIT notices are copied
beside the notebooks in `EXAMPLE-GUIDE.md` and `UPSTREAM-LICENSE.txt`. Source
metadata stays inside the kit; the notebook folders contain the runnable examples. A copied notebook you edited is preserved.

The UDF add-on now installs the pinned `PYTHON3_ML` runtime as well as the
selected language setup. It verifies scikit-learn, pandas, NumPy and SciPy
inside the database; notebook package installation alone cannot do that.
For an older installation, run `exakit udf-use default` to add that runtime
(allow the database restart). Training and external-model scoring select
`PYTHON3_ML` automatically when it is installed.

During an interactive add-on install, the small line immediately above the active progress bar, inside the table
names the current operation: download, checksum verification, container install,
database restart or package check. Full package installer output goes to the
setup log; use `exakit logs setup` if a step fails.
