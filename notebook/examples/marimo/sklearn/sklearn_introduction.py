import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('sklearn/sklearn_introduction.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Introduction

    Load the matching Abalone or Telescope data notebook first. Prediction requires udf-devkit and the PYTHON3_ML runtime. Models use the local file bucket.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/sklearn/sklearn_introduction.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'sklearn/sklearn_introduction.ipynb')", language="python", min_height=100)
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

    # Introduction

    This set of notebooks demonstrates the use case of uploading an externally trained prediction model into Exasol database. In this particular scenario, a regression or classification model is trained using the [scikit-learn](https://scikit-learn.org/stable/) library. The trained scikiit_learn model is then uploaded into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm) and used for making predictions.

    The prediction is made for each row in a "test" database. The computation is invoked by a user defined function ([UDF](https://docs.exasol.com/db/latest/database_concepts/udf_scripts.htm)). If the database has multiple nodes the test rows would be evenly distributed across the nodes. The UDF making the predictions runs on all these nodes in parallel, each node computing its portion of the test data. This parallelization results in the reduction of overall computation time by the factor equal to the number of nodes.

    For the prediction UDF the scikit-learn model is an arbitrary object that supports the `predict` method. It can just as well be a pipeline including some pre-processing and/or post-processing steps.

    ## Prerequisites

    Before using this set of notebooks the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py)
    2. [Fix the Version of Python Library Scikit-learn](/?file=exasol-examples/sklearn/sklearn_fix_version.py)
    3. [Load the MAGIC Gamma Telescope data](/?file=exasol-examples/data/data_telescope.py)
    4. [Load the Abalone data](/?file=exasol-examples/data/data_abalone.py)

    ## Content

    This section consists of two tutorials, covering one classification and one regression problem. Please note that the tutorials focus on showing the in-database prediction rather than presenting best ML practices. For the sake of clarity, we perform only very basic ML pre-processing and performance analysis.

    The first notebook to run is the one that creates a [prediction UDF](/?file=exasol-examples/sklearn/sklearn_predict_udf.py).

    This shall be followed by the two tutorials in any order.

    - [Solving classification problem (MAGIC Gamma Telescope)](/?file=exasol-examples/sklearn/sklearn_train_telescope.py).
    - [Solving regression problem (Abalone)](/?file=exasol-examples/sklearn/sklearn_train_abalone.py).
    """)
    return

if __name__ == "__main__":
    app.run()
