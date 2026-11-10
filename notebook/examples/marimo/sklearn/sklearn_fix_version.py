import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('sklearn/sklearn_fix_version.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Fix the Version of Python Library Scikit-learn

    Load the matching Abalone or Telescope data notebook first. Prediction requires udf-devkit and the PYTHON3_ML runtime. Models use the local file bucket.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/sklearn/sklearn_fix_version.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'sklearn/sklearn_fix_version.ipynb')", language="python", min_height=100)
    run_001 = mo.ui.run_button(label="Run cell 1")
    mo.vstack([editor_001, run_001])
    return editor_001, run_001

@app.cell
def _(editor_001, lesson, mo, render, run_001):
    mo.stop(not run_001.value)
    render(mo, lesson.run(editor_001.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    <div style="text-align: right;">
      <img src="https://raw.githubusercontent.com/exasol/ai-lab/refs/heads/main/assets/Exasol_Logo_2025_Dark.svg" style="width:200px; margin: 10px;" />
    </div>

    # Fix the Version of Python Library Scikit-learn

    This notebook ensures the AI Lab is using the same version of the python library `scikit-learn` as the one used by the built-in [Script Language Container (SLC)](https://docs.exasol.com/db/latest/database_concepts/udf_scripts/adding_new_packages_script_languages.htm#ScriptLanguageContainer) inside the Exasol database.

    ## Rationale

    Using identical versions is required when transferring the Scikit-learn model from the AI Lab to the database SLC.

    The AI Lab serializes the Scikit-learn model with [pickle](https://docs.python.org/3/library/pickle.html) and uploads it into the BucketFS of the database. The UDF using the built-in SLC can only _deserialize_ the model if it is using the same version of Scikit-learn as was used for serializing it. The specific version of the library available in the built-in SLC depends on the release version of the database and cannot be controlled by the AI Lab.

    Running the following script will update the version of the library used in the AI Lab, if required.

    ## Open Secure Configuration Storage
    """)
    return

@app.cell
def _(mo):
    editor_002 = mo.ui.code_editor(value='print("Using the Starter Kit encrypted connection; tutorial schema: EXAKIT_EXAMPLES.")', language="python", min_height=100)
    run_002 = mo.ui.run_button(label="Run cell 2")
    mo.vstack([editor_002, run_002])
    return editor_002, run_002

@app.cell
def _(editor_002, lesson, mo, render, run_002):
    mo.stop(not run_002.value)
    render(mo, lesson.run(editor_002.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Detect the Version of Scikit-learn Used in the SLC

    The following cell creates a User Defined Function (UDF) called `detect_scikit_learn_version()` and then executes the UDF using the built-in SLC via an SQL statement.

    The UDF inquires and returns the version of Scikit-learn available in the built-in SLC which is then stored in variable `slc_scikit_learn_version`.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='import textwrap\nfrom exakit.nb.example_runtime import open_pyexasol_connection\n\nsql = textwrap.dedent("""\nCREATE OR REPLACE PYTHON3_ML SCALAR SCRIPT {schema!q}.detect_scikit_learn_version() RETURNS VARCHAR(100) AS\nimport sklearn\ndef run(ctx):\n    return sklearn.__version__ \n/\n""")\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    query_params={\'schema\': ai_lab_config.db_schema}\n    conn.execute(sql, query_params)\n    result = conn.execute("select {schema!q}.detect_scikit_learn_version()", query_params).fetchone()\n    slc_scikit_learn_version = result[0]', language="python", min_height=100)
    run_003 = mo.ui.run_button(label="Run cell 3")
    mo.vstack([editor_003, run_003])
    return editor_003, run_003

@app.cell
def _(editor_003, lesson, mo, render, run_003):
    mo.stop(not run_003.value)
    render(mo, lesson.run(editor_003.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Compare the Scikit-learn Version and Update the AI Lab if Required

    The next cell compares the Scikit-learn version returned by the UDF with the Scikit-learn version in the AI Lab environment. If they differ, then the cell installs the UDF's Scikit-learn version in the AI Lab environment.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='import sklearn\nfrom importlib import reload\n\nmy_version = sklearn.__version__\n\nif slc_scikit_learn_version == my_version:\n    print(f"AI Lab scikit-learn version {my_version} is identical to that of the SLC.\\nNothing to do.")\nelse:\n    print(f"AI Lab scikit-learn version {my_version} differs from SLC.\\nInstalling version {slc_scikit_learn_version} ...")\n    %pip install "scikit_learn=={slc_scikit_learn_version}"\n    sklearn = reload(sklearn)\n    print(f"Updated AI Lab scikit-learn to version {sklearn.__version__}.")', language="python", min_height=100)
    run_004 = mo.ui.run_button(label="Run cell 4")
    mo.vstack([editor_004, run_004])
    return editor_004, run_004

@app.cell
def _(editor_004, lesson, mo, render, run_004):
    mo.stop(not run_004.value)
    render(mo, lesson.run(editor_004.value))
    return

if __name__ == "__main__":
    app.run()
