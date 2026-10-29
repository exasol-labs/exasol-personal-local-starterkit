# Bundled practice notebooks

The complete 50-lesson official collection is also included. Open
`exasol-examples/00_library.ipynb` in JupyterLab or
`exasol-examples/00_library.py` in Marimo for its full categorized index.
See the kit's `notebook/INSTALL-AND-UPDATE.md` for how the connector, environments
and bundled files are installed and updated.


These runnable notebooks are included with the kit for both JupyterLab and
Marimo. Open the files listed below; no source manifest or download is needed.
They adapt examples distributed by
[Exasol Notebook Connector](https://github.com/exasol/notebook-connector) and
used by [Exasol AI Lab](https://github.com/exasol/ai-lab). They use the kit's
secure connection, approved Pharma or Banking roles and installed Python UDF
runtime. They require no external data connection or cloud account.

| Persona | Notebook in JupyterLab | Lesson |
|---|---|---|
| Data Scientist | `useful-notebooks/data-scientist/01_sql_and_dataframes.ipynb` | SQL aggregates to pandas; validate totals |
| Data Scientist | `useful-notebooks/data-scientist/02_decision_tree_baseline.ipynb` | A reproducible local scikit-learn baseline |
| ML Engineer | `useful-notebooks/ml-engineer/01_udf_package_check.ipynb` | Prove which packages are inside the database |
| ML Engineer | `useful-notebooks/ml-engineer/02_decision_tree_udf.ipynb` | Train and evaluate a decision tree in a SET UDF |

In Marimo, open the matching persona folder and `.py` filename. Change
`DATASET` to `banking_complaints` to repeat a lesson on Banking. Run each
persona's quickstart first; ML lessons need `udf-devkit` and its ML packages.

The decision-tree UDF lesson returns evaluation metrics. `01_train` remains
the full tracked training flow with model artifacts, MLflow and Rust coefficients.
Use `03_share` on Dash Server to turn a validated result into a dashboard.

The original upstream notebooks cover additional services such as BucketFS HTTP,
GPU, Transformers and cloud deployments; those need their own environments.
These local copies replace their setup steps and use the bundled reference data.
Source revisions and original digests are kept internally in the kit at
`notebook/upstream-sources.json`. The MIT notices travel with the notebooks in
`UPSTREAM-LICENSE.txt`.

## Verification on macOS (28 October 2026)

All four added lessons ran successfully on both bundled datasets. The core
MLflow training notebook and external-model scoring notebook also ran on both.
The scoring comparison used 500 held-out rows per dataset; the largest local
versus database difference was `2.22e-16` (Pharma) and `1.11e-16` (Banking).

The UDF imported Python 3.12.3, scikit-learn 1.9.0, pandas 2.3.3, NumPy 2.4.6,
SciPy 1.18.0 and joblib 1.6.0. These versions were read inside Exasol, not from
the notebook environment.

Both Bash and PowerShell installer regressions passed, and Marimo validated
the generated lessons. Windows execution remains to be verified on a Windows
machine. Existing notebooks in the user's folder are preserved; the current
kit originals are also available under `~/.exasol-starter-kit/kit/notebook/`.
