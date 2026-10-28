import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('text_ai/txaie_init.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Text AI Extension Initialization

    Requires a configured Text AI Extension and its database objects. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/text_ai/txaie_init.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'text_ai/txaie_init.ipynb')", language="python", min_height=100)
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

    # Text AI Extension Initialization

    Here we will bring the Text AI functionality up and running. We will do this via a single call to function in the support library.

    ## Prerequisites

    **Note**: To be able to store and run the models used in this demo, your database should meet the following requirements:

    * The database has at least 10 GB free disk space for the BucketFS. In case you are using the Exasol Docker-DB, your Docker host needs at least 10 GB free disk space.
    * The database is configured with at least 8 GB RAM. In case you are using the Exasol Docker-DB, please configure the Exasol Docker-DB accordingly in the AI Lab Main Configuration and restart the Docker-DB if needed. 
        * **Caution**: Restarting the Docker-DB will wipe out the content of the database.

    Prior to using this notebook one needs to complete the following steps:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).

    ## Setup

    ### Open Secure Configuration Storage
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
    ## Initialize the Extension

    <b>This operation normally takes a considerable amount of time to complete</b>

    This notebook installs the Text AI SLC and Scripts and the default Hugging Face Transformers models.
    The installation of the SLC prints output which suggests to activate the language container. This is not needed in AI Lab, because the language container activation will be executed at the session level once the connection to the database is established. In tutorials using JupySQL the container activation is included in the routine that enables the JupySQL.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exasol.nb_connector.text_ai_extension_wrapper import initialize_text_ai_extension\n\ninitialize_text_ai_extension(ai_lab_config)', language="python", min_height=100)
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
    You can now continue with the [Text AI Preprocessing Notebook](/?file=exasol-examples/text_ai/txaie_preprocessing.py).
    """)
    return

if __name__ == "__main__":
    app.run()
