import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('start.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Welcome to the Exasol AI Lab

    Uses the kit encrypted connection. Database examples use EXAKIT_EXAMPLES. Later sections may need tutorial downloads or the ML UDF add-on.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/start.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'start.ipynb')", language="python", min_height=100)
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

    # Welcome to the Exasol AI Lab

    ## Introduction

    We present a collection of tutorials demonstrating the capabilities of the Exasol infrastructure in the context of Machine Learning and AI. We will show how Exasol can help deploy ML pipelines and productionize ML/AI solutions.

    ### Exasol provisions for ML/AI

    At the core of The AI Lab are three fundamental features of Exasol: 
    - Massively Parallel Processing (MPP) Architecture.
    - User Defined Functions (UDF).
    - BucketFS file system.

    The MPP Architecture of the Exasol database allows running a predictive model on multiple nodes in parallel. This can significantly reduce the response time when a prediction needs to be computed for a large number of data points.

    [User Defined Functions](https://docs.exasol.com/db/latest/database_concepts/udf_scripts.htm) are one of the most powerful features of Exasol. It offers endless opportunities for embedding customer and third-party computational modules and frameworks into the database. For instance, it is possible to compute a complex AI model based on PyTorch inside the database. Examples of that are included in the tutorials. Given the parallel architecture of the database, the model will be simultaneously computed on each node. 

    The UDFs are backed by [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm) - an Exasol proprietary replicated file system. This is where the model is usually stored. The file system is called replicated because the copies of all its files are stored at every node of the database cluster.

    Now it is easy to see how it all comes together. Each node in the database cluster stores its portion of input data, but all nodes have a copy of the same model and the required infrastructure. The UDF invokes the computation of the model on all nodes simultaneously and assembles the results to form a coherent output.

    ## Structure of the tutorials

    The tutorials are organized into topics, each one in a separate directory. The links below lead to the main page of a topic, usually an introduction. From there one can follow through the tutorials on the topic or go to a particular notebook.

    The configuration notebook must be visited at least once. When using the provided demo database - Exasol Docker-DB - the configuration notebook may need to be re-visited at the beginning of every session with AI Lab to start or restart this database. 

    Some tutorials require example data. The data can be loaded into the database using notebooks in the data loading topic. 

    1. [Configuration](/?file=exasol-examples/main_config.py)
    1. [First steps](/?file=exasol-examples/first_steps.py)
    1. [Loading data](/?file=exasol-examples/data/data_content.py)
    1. [Using scikit-learn](/?file=exasol-examples/sklearn/sklearn_introduction.py)
    1. [Transformers extension](/?file=exasol-examples/transformers/te_introduction.py)
    1. [Cloud store](/?file=exasol-examples/cloud/01_import_data.py)
    1. [Script Languages Container](/?file=exasol-examples/script_languages_container/using_the_script_languages_container_tool.py)
    1. [Using GPU in UDFs](/?file=exasol-examples/gpu_in_udf/using_gpu_in_udf.py)
    1. [Using IBIS dataframe library](/?file=exasol-examples/ibis/quickstart.py)
    1. [Exasol Text AI](/?file=exasol-examples/text_ai/txaie_introduction.py)
    """)
    return

if __name__ == "__main__":
    app.run()
