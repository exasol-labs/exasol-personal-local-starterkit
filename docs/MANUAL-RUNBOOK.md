# Mac test runbook: current starter-kit candidate

Test in this order: clean install → baseline checks → add Share/JSON tools → Data Scientist → ML Engineer → own files → Marimo and bundled lessons → final checks.

Use Terminal for shell commands and the Exasol (Starter Kit) kernel for notebook cells. This guide tests the current checkout, including commit `bc73a21`; the ordinary public installer alone does not contain these unmerged changes. Virtual schemas and external data-source connections are excluded. Leave the connected-source setting at its shipped `None` value.

## 1. Optional clean reset

**Full uninstall deletes kit-owned database data and, with the setting below, your kit notebooks. Save anything you need first.** Compatible user-owned components and databases are preserved; this is a clean kit installation, not a guarantee that every pre-existing Exasol deployment disappears.

```sh
export PATH="$HOME/.local/bin:$PATH"
exakit version
EXAKIT_UNINSTALL_NOTEBOOKS=remove exakit uninstall --dry-run
```

Read the removal plan. If it is correct, run this and select **EVERYTHING** in the menu, then confirm:

```sh
EXAKIT_UNINSTALL_NOTEBOOKS=remove exakit uninstall
```

Skip this section if `exakit` is not installed. Keep your source checkout and the internal evidence document. Do not manually delete reused deployments or edit ownership records to make the reset look clean.

## 2. Install the current checkout using curl

First change into your checkout. On the Mac used for this test, run:

```sh
cd /Users/sheetaldharshan.a/Desktop/starterkit-0.2.0
git branch --show-current
git log -1 --oneline
```

Expected branch: `feat/persona-v05-completion`; the tested code is `bc73a21` or a later revision containing it.
On another machine, substitute its checkout path. A `fatal: not a git repository` message means you are in the wrong directory; correct that before installing. `$PWD` is your current Terminal directory, so running the following command from `~` points at your home rather than the checkout.

```sh
curl -fsSL https://www.exasol.com/install/starter-kit.sh | \
  EXAKIT_LOCAL_KIT="$PWD" \
  EXAKIT_PERSONA=data-scientist,ml-engineer \
  EXAKIT_NOTEBOOK_FRONTENDS=jupyterlab,marimo sh
```

The log must say it is using the **local checkout**. `EXAKIT_LOCAL_KIT` belongs after the pipe, as shown. Wait for completion; do not interrupt the UDF step because its percentage pauses. The line above its progress bar should name download, checksum verification, container installation, restart or package checking. A previous first UDF install took about 11 minutes; elapsed time alone is not a failure.

Expected baseline:

| Item | Data Scientist | ML Engineer | Both together |
|---|---|---|---|
| Datasets | Pharma + Banking | Pharma + Banking | Each loaded once |
| Add-ons | Notebook | Notebook + UDF devkit | Notebook + UDF devkit |
| MLflow | — | Managed local service | Managed local service |
| Extra tools | Dash Server / JSON Tables added explicitly below | Same | Same |

To test either persona alone on a fresh kit, change only `EXAKIT_PERSONA` to `data-scientist` or `ml-engineer`. To test adding the other persona later, use `exakit persona add ml-engineer` or `exakit persona add data-scientist`, then check its plan.

## 3. Confirm the installation and default data

```sh
export PATH="$HOME/.local/bin:$PATH"
exakit status --json
exakit persona plan data-scientist,ml-engineer
exakit notebook check
exakit mcp-doctor --json
exakit sql --json 'SELECT CURRENT_TIMESTAMP'
exakit sql 'SELECT COUNT(*) AS N FROM PHARMA.PHARMA_TRIALS'
exakit sql 'SELECT COUNT(*) AS N FROM BANKING.BANKING_COMPLAINTS'
```

Pass: database running; persona plan has nothing pending; notebook connection works; the timestamp returns; counts are **5,169 Pharma trials** and **6,754 Banking complaints**. MCP doctor should report a successful handshake for configured clients. Restart an AI client before expecting its newly registered tools to appear.

If a reference dataset is missing, load it and repeat the count:

```sh
exakit data-load pharma_trials
exakit data-load banking_complaints
```

For the ordinary kit sample datasets as well, optionally run these separately:

```sh
exakit data-load tpch
exakit data-load energy
exakit data-load weather
exakit sql "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT LIKE 'SYS%' ORDER BY 1, 2"
```

## 4. Add Share and CLI JSON support; prepare Rust

```sh
exakit marketplace dash-server json-tables
exakit mcp-setup
exakit start dash-server
exakit mlflow status --json
exakit marketplace --list --json
exakit status --json
```

Pass: both added tools are installed; Dash Server reports its URL (normally `http://127.0.0.1:5100`); MLflow is running. If MLflow is stopped, run `exakit mlflow start`. Use `exakit mlflow url` for its actual address.

Rust container installation can restart the database. Run it when a restart is acceptable and confirm the prompt:

```sh
exakit udf-setup --language rust
exakit udf-use --list
```

Pass: Rust smoke reports the pinned rustc/SDK, and the installed aliases include `RUST` plus the Python training runtimes. A later check should succeed without reinstalling an already valid container. The ML Engineer persona should already have prepared `PYTHON3_ML`; use `exakit udf-use default --language python` only if that runtime is missing or its package check failed—it can restart the database too.

A first Rust **build** additionally needs a running Docker or Podman Linux engine. The database running inside Exasol Personal does not by itself prove that a build engine is available.

## 5. Data Scientist: Pharma, then Banking

```sh
exakit notebook
```

Choose JupyterLab. In `starter-kit-notebooks/data-scientist/`, use the **Exasol (Starter Kit)** kernel and run cells in order:

| Notebook | Action | Pass |
|---|---|---|
| `00_quickstart.ipynb` | Keep `SAMPLE = "pharma_trials"`; leave own-file and connected-source defaults alone. Review the proposed roles and click **Approve descriptor** before continuing. | Connection, approved roles and first query succeed; workflow ID is printed. |
| `01_explore.ipynb` | Keep `DATASET = "pharma_trials"` and `USE_AI_THEMES = False`; run the SQL, client model and final handoff cell. | SQL/results appear and a handoff file is written. Optional AI themes stay off, including when an endpoint is configured. |
| `02_ask_your_data.ipynb` | Keep `DRAFT_WITH_MODEL = False`. Leave `APPROVE_SQL = False` first; after reading the SQL, set it to `True` and rerun the approval cell. | No proposal execution before approval; category counts return after approval. |
| `03_share.ipynb` | Use `APP_NAME = "pharma-category-check"`. Run Preview, open its URL and check the figures. Only then set `FIGURES_CHECKED = True` and rerun the last cell. | Healthy preview, then a live Dash Server URL; no promotion while the flag is false. |

Copy the quickstart's workflow ID into `WORKFLOW_ID` in subsequent notebooks to keep one log across kernels.

Read the question and result notes as you go. The role picker must explain that
its suggestions use measured table values and column names, show the technical
evidence and flag close alternatives. Check that a role fits your question:
`TERMINATED` and `HAS_RESULTS` are both binary, but predict different outcomes.
Your approval selects the meaning; a suggestion score is not a probability.

Existing working notebooks are preserved during updates. For the revised
walkthrough, open the current original under the kit's
`kit/notebook/notebooks/` or `kit/notebook/marimo/` directory and save a new copy
with a different name; see `notebook/README.md` in this checkout for the paths.

Repeat all four with `SAMPLE` / `DATASET = "banking_complaints"`. Use `APP_NAME = "banking-category-check"` for its dashboard. The rest of the notebook SQL should stay unchanged.

## 6. ML Engineer: train, score and inspect MLflow

Run Data Scientist `01_explore` first for each dataset so the handoff exists. Open `starter-kit-notebooks/ml-engineer/`:

| Notebook | Action | Pass / current expectation |
|---|---|---|
| `00_quickstart.ipynb` | Keep Pharma; run connection, container, MLflow and bucket checks, then review/approve roles. | Checks and first query succeed. Record any failed bucket check; do not silently mark it passed. |
| `01_train.ipynb` | Set `DATASET = "pharma_trials"`; keep seed/options unchanged. Run training and artifact export twice. | Two runs have identical metrics/coefficients; model, training SQL and coefficients appear in MLflow. Pharma's last observed macro-F1 was `0.445955`, above baseline `0.441129`. |
| `02_rust_score.ipynb` | Keep the same dataset; use `UDF_NAME = "score_pharma"`. Run build/deploy and parity cells. | Rust/Python labels agree and maximum probability difference is **below `1e-9`** on the tested rows. The Rust MLflow run includes container/library/Cargo digests. |
| `03_score_external_model.ipynb` | Keep `MODEL_FILE = None` to train its built-in local example. This tests a local model file, not an external data connection. | File is copied to the shared bucket and local/database predictions match. A skipped comparison or version mismatch is not a pass. |

Repeat on Banking with `DATASET = "banking_complaints"` and Rust `UDF_NAME = "score_banking"`. Use a new UDF name when changing coefficient revisions; existing projects are preserved.

**Known open result:** Banking training reruns are deterministic, but its last observed macro-F1 **`0.469807` equals its majority baseline**. Record training/logging separately from model acceptance; this is an existing acceptance failure. Do not change the test split or lower the pass threshold to hide it.

For bucketless Rust deployment, the notebook defaults to `ALLOW_DATABASE_RESTART = False`. If it reports that a container update is needed, set it to `True` only when you agree to the restart, then rerun deployment. A verified unchanged packaged library should deploy again without another restart. This fallback applies to Rust; external pickle scoring still requires a working shared bucket.

```sh
exakit mlflow url
exakit model list --json
```

Open MLflow and inspect the Python/Rust runs, metrics, parameters, artifacts and descriptor/workflow tags. Notebook-side packages and packages inside Exasol are different environments; the database-side check is in the extra lesson below.

## 7. Test all five own-file formats

In a new notebook cell, create local test files:

```python
from pathlib import Path
import pandas as pd

folder = Path.home() / "exakit-test-data"
folder.mkdir(exist_ok=True)
frame = pd.DataFrame({
    "COMPANY": [f"company-{i % 5}" for i in range(120)],
    "CATEGORY": ["A" if i % 2 else "B" for i in range(120)],
    "EVENT_DATE": pd.date_range("2025-01-01", periods=120).strftime("%Y-%m-%d"),
    "LABEL": [i % 2 for i in range(120)],
    "DESCRIPTION": ["accepted claim" if i % 2 else "rejected claim" for i in range(120)],
    "select": list(range(120)),
    "EMPTY_TEXT": [""] * 120,
})
frame.to_csv(folder / "records-csv.csv", index=False)
frame.to_parquet(folder / "records-parquet.parquet", index=False)
frame.to_json(folder / "records-array.json", orient="records")
frame.to_json(folder / "records-jsonl.jsonl", orient="records", lines=True)
frame.to_json(folder / "records-lines.json", orient="records", lines=True)
print(folder)
```

For each row below, rerun the Data Scientist quickstart's load/review/query cells with `SAMPLE = None` and these values. Use a separate table per format:

| `OWN_FILE` | `OWN_TABLE` |
|---|---|
| `"~/exakit-test-data/records-csv.csv"` | `"FILE_TEST.CSV_RECORDS"` |
| `"~/exakit-test-data/records-parquet.parquet"` | `"FILE_TEST.PARQUET_RECORDS"` |
| `"~/exakit-test-data/records-array.json"` | `"FILE_TEST.JSON_RECORDS"` |
| `"~/exakit-test-data/records-jsonl.jsonl"` | `"FILE_TEST.JSONL_RECORDS"` |
| `"~/exakit-test-data/records-lines.json"` | `"FILE_TEST.JSON_LINES_RECORDS"` |

Review entity=`COMPANY`, category=`CATEGORY`, date=`EVENT_DATE`, label=`LABEL` (positive `1`), text=`DESCRIPTION`; the all-empty column must not break loading. Approve before continuing. Each table should contain **120 rows**, the reserved `select` header should be normalized safely, and no `Descriptor.has` error should appear.

Choose one file and set Explore's single `DATASET` assignment to that file path. Rerun exploration and handoff; its descriptor was saved beside the file. You can then use the same path in the training notebook.

Separately test the **JSON Tables CLI add-on** using a new target:

```sh
EXAKIT_DATA_FILE="$HOME/exakit-test-data/records-array.json" \
  EXAKIT_DATA_TABLE=FILE_TEST.CLI_JSON exakit data-load
exakit sql "SELECT TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA = 'FILE_TEST' ORDER BY TABLE_NAME"
```

Pass: the CLI reports the created tables and a successful load. Inspect the printed table names; JSON ingestion can create related tables. This is separate from the notebook's own-file loader.

## 8. Marimo, useful lessons and the official library

```sh
exakit notebook marimo
```

Open the matching persona `.py` files in Marimo's `data-scientist/` or `ml-engineer/` folders. Run the quickstart and Explore/Train with the same settings above. Use the notebook's visible Run/approval controls. Each front end has its own copies; editing Jupyter does not edit Marimo.

In either front end, run these additional lessons under `useful-notebooks/<persona>/`:

| Persona | File stem | Pass |
|---|---|---|
| Data Scientist | `01_sql_and_dataframes` | SQL aggregates and independent totals agree. |
| Data Scientist | `02_decision_tree_baseline` | Client-side scikit-learn training/evaluation completes. |
| ML Engineer | `01_udf_package_check` | scikit-learn, pandas, NumPy, SciPy and joblib import **inside Exasol**. |
| ML Engineer | `02_decision_tree_udf` | Database-side decision-tree training returns row counts and metrics. |

Repeat with Banking. Jupyter filenames end in `.ipynb`; Marimo filenames end in `.py`.

Open `exasol-examples/00_library.ipynb` (or `.py`) for the bundled 50-example index. For the local smoke flow, use its configuration lesson and Abalone load/train/UDF-prediction/client-prediction lessons. Read prerequisites first; external-source, cloud, GPU and other service-dependent tutorials are outside this run. Record them as **not exercised**, not passed.

## 9. Check help, ownership and notebook preservation

```sh
exakit --help udf-devkit
exakit rust-udf deploy --help
exakit model put --help --json
exakit --help notebook
exakit marketplace --list --json
exakit version --json
```

Pass: options/defaults/examples match each action, including Rust deploy's `--yes`; installed components show ownership. Reused user-owned components must remain user-owned and be preserved in the uninstall preview. See [ownership behavior](COMPONENT-OWNERSHIP.md) and [all add-on commands](ADDON-COMMANDS.md).

Test a harmless invalid help action:

```sh
exakit help made-up-action --json
echo $?
```

Expected: `ok: false`, no matching commands, catalog remedy, exit **2**; nothing is installed.

To test refresh preservation, add a Markdown marker to a copied optional lesson, save it, then run `exakit notebook setup` and reopen it. Your edit must remain. Existing old utility copies that you edited are also preserved; unchanged kit copies can be moved out of the reserved slots. After a clean install, utility lessons belong under `useful-notebooks/`.

## 10. Rust fallback-specific checks

Use a fresh UDF name for a new coefficients file. The public command forms are:

```sh
exakit rust-udf new score_manual --coefficients "$HOME/.exasol-starter-kit/handoffs/pharma_trials-v1.coefficients.json"
exakit rust-udf build score_manual --json
exakit rust-udf deploy score_manual --schema EXAKIT_SCORING --json
```

Use the actual coefficient path printed by training if the descriptor version is not `v1`.

| Situation | Expected result |
|---|---|
| Shared bucket is readable in a UDF | `deployment: "bucket"`; no database restart. |
| Bucket unavailable and no matching packaged library; no `--yes` | Exit **5**, `step: "confirm"`, explicit restart remedy. A bucket probe may stage a library/helper UDF; no container update/restart occurs. |
| Same unavailable bucket, restart accepted | Run `exakit rust-udf deploy score_manual --schema EXAKIT_SCORING --yes --json`; expect `deployment: "container"`, derived `container_sha256`, restart requested and a successful load. |
| Repeat unchanged packaged deployment | Run the ordinary deploy again; expect reuse with `database_restart_requested: false`. |

Do not rename/delete live bucket folders to force this test. A Mac with a working bucket exercises the normal route; record the live fallback as **not exercised** unless the bucket is actually unavailable. Python/Rust parity still needs the notebook check after deployment.

The isolated fallback fixtures can be run from the source checkout without altering the real deployment:

```sh
python3 tests/test_rust_container.py
python3 tests/test_rust_udf.py
python3 tests/test_udf_tool.py
```

Expected current counts: **7, 13 and 17 tests pass**. These cover packaging, consent, unavailable UDF-visible buckets, retained libraries, reuse and invalidation; they do not establish a live restart/parity pass.

## 11. Optional model endpoint and Langfuse trace

This needs your own model endpoint and Langfuse project. Configure `EXAKIT_NB_MODEL`, `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` securely in the Terminal environment. Do not paste keys into notebook cells or logs.

Restart the notebook servers from that same Terminal so the kernel inherits the settings:

```sh
exakit notebook stop
exakit notebook
```

In Explore set `USE_AI_THEMES = True` and rerun its settings cell. This opts into sending up to five descriptions to your configured endpoint. Inspect the text-step SQL before running that cell; bundled local tables do not ask for another confirmation. Pass: one trace groups its model calls and shows inputs/outputs, token usage, latency, dataset/descriptor/workflow/session tags and sample SQL. Inspect the trace for accidental connection secrets. With model configuration present but Langfuse variables absent, model calls should still work with a tracing-off note. With no model configured, the optional model step skips. Return `USE_AI_THEMES` to `False` and rerun: the SQL sample should still appear and no theme calls should be made.

No local Langfuse server installation is required by this flow. Real Cloud/self-hosted compatibility and your own-project trace remain manual checks; local mock tests do not replace them.

## 12. Final record and stop

```sh
exakit mlflow url
exakit workflow list
exakit status --json
```

Inspect a workflow with the real ID printed earlier:

```sh
exakit workflow show YOUR_WORKFLOW_ID --json
```

Record **pass / fail / not exercised** for: installation, reference counts, both DS notebook flows, both ML training/logging flows, model baseline improvement, Python/Rust parity, external local-model scoring, five file formats, CLI JSON, Marimo, useful lessons, notebook preservation, ownership/help, Langfuse and live fallback. Keep the Banking baseline failure visible. GitHub CI is separately blocked by the account billing/spending limit until that is resolved.

```sh
exakit notebook stop
exakit stop
```

For another session, run `exakit start`, then open notebooks on demand. For failures, use the named remedy and inspect:

```sh
exakit status --json
exakit logs setup --lines 100
exakit logs udf-devkit-mlflow --lines 100
```

Do not loop on `start` if status reports `interrupted`; runtime repair deletes database data and requires a separate deliberate decision.

## Windows commands for later verification

Live Windows verification is deferred. From the Windows checkout directory, after any uninstall preview/confirmation:

```powershell
$env:EXAKIT_LOCAL_KIT = (Get-Location).Path
$env:EXAKIT_PERSONA = 'data-scientist,ml-engineer'
$env:EXAKIT_NOTEBOOK_FRONTENDS = 'jupyterlab,marimo'
irm https://www.exasol.com/install/starter-kit.ps1 | iex
exakit status --json
exakit persona plan data-scientist,ml-engineer
exakit notebook check
```

The remaining kit commands and notebook settings above are shared. Use PowerShell 5.1 when checking the minimum supported Windows shell; macOS PowerShell fixture success is not live Windows acceptance.
