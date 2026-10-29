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
    # Verify the libraries where the model will actually run

    **Dataset:** Pharma or Banking. **How long:** two minutes.

    The notebook can import scikit-learn, but the scoring function runs inside Exasol's Python runtime. Check that runtime before debugging a model that depends on missing or incompatible libraries.

    **By the end:** you will have package versions returned by a real database UDF. **Optional AI:** no LLM endpoint is required; this is a direct runtime check you can reuse before training.

    Adapted from Notebook Connector / AI Lab runtime and scikit-learn lessons. Sources and MIT notices: `EXAMPLE-GUIDE.md`.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = "pharma_trials"  # or "banking_complaints"
    CONTAINER = nb.ml_train.udf_container()
    conn = nb.connect()
    ds = nb.dataset(conn, DATASET).require_approved("UDF package check")
    nb.workflow("udf-package-check")
    if not nb.check_container(conn, alias=CONTAINER):
        raise RuntimeError("Install the ML packages with: exakit udf-use default")
    return CONTAINER, conn, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Read evidence from inside Exasol

    The next cell creates a small SQL-callable Python function. That function imports scikit-learn, pandas, NumPy, SciPy and joblib inside the database, then returns their versions.

    **Read the result:** these versions describe the UDF runtime, not the notebook kernel. Use them when checking a saved model's compatibility. A missing import is a readiness failure to fix before continuing.

    **Technical note:** `CONTAINER` defaults to the installed ML runtime, usually `PYTHON3_ML`. The function is created under `EXAKIT_EXAMPLES` and called by the printed SQL. `EXAKIT_UDF_CONTAINER` can select another installed runtime.
    """)
    return


@app.cell
def _(CONTAINER, conn, nb):
    package_script = f'''CREATE OR REPLACE {CONTAINER} SCALAR SCRIPT EXAKIT_EXAMPLES.ML_PACKAGES(x DOUBLE)
    RETURNS VARCHAR(20000) AS
    import json, platform
    import sklearn, pandas, numpy, scipy, joblib
    def run(ctx):
        return json.dumps({{"python": platform.python_version(), "scikit-learn": sklearn.__version__,
                           "pandas": pandas.__version__, "numpy": numpy.__version__,
                           "scipy": scipy.__version__, "joblib": joblib.__version__}})
    '''
    conn.execute("CREATE SCHEMA IF NOT EXISTS EXAKIT_EXAMPLES")
    print(package_script)
    conn.execute(package_script)
    packages_sql = "SELECT EXAKIT_EXAMPLES.ML_PACKAGES(1) AS PACKAGES"
    print(packages_sql)
    runtime_packages = nb.sql(conn, packages_sql)
    print(runtime_packages.iloc[0]["PACKAGES"])
    return


if __name__ == "__main__":
    app.run()
