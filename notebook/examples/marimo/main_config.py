import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('main_config.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Main Configuration

    Uses the kit encrypted connection. Database examples use EXAKIT_EXAMPLES. Later sections may need tutorial downloads or the ML UDF add-on.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/main_config.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'main_config.ipynb')", language="python", min_height=100)
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

    # Main Configuration

    This notebook may need to be visited first before we start with the examples. The notebook includes several steps outlined below. Under various conditions, some or all of these steps can be skipped.

    * Accessing the configuration store.
    * Choosing the database.
    * Setting up the main configuration parameters, depending on the choice of the database.
    * Creating the database schema.

    The configuration parameters may include the location of the Exasol database, the access credentials for the database, and the parameters of its [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm) file system.

    Once specified, the parameters are stored in a configuration store. All notebooks, including this one, access configuration data in this store. The configuration store is encrypted and protected with a password.

    Before starting working with any notebook in the AI Lab one needs to connect to the configuration store providing the name of the file where the data is stored and the password. If the file with the specified name doesn't exist a new file will be created and protected with the entered password. However, if the file does exist it will be opened only if the provided password matches the password the file was created with.

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
    ## Load UI functions

    Let's import some other UI functions that may be used in this notebook.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='print("The starter kit already manages the local connection and database. No replacement database is created.")', language="python", min_height=100)
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
    ## Choose the database

    First, choose the database—AI Lab offers an Exasol Docker-DB, a single-node Docker container database, ideal for lightweight proof-of-concept experiments. For solving real world tasks, consider an external Exasol database.

    The chosen database is stored in the configuration. If configured, no need to repeat unless switching to another database is desired.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='print("The starter kit already manages the local connection and database. No replacement database is created.")', language="python", min_height=100)
    run_004 = mo.ui.run_button(label="Run cell 4")
    mo.vstack([editor_004, run_004])
    return editor_004, run_004

@app.cell
def _(editor_004, lesson, mo, render, run_004):
    mo.stop(not run_004.value)
    render(mo, lesson.run(editor_004.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Set up main configuration

    Here we are going to enter the main configuration parameters. The set of configuration parameters depend on the choice of the database. All configuration parameters are saved in the configuration store. If this step has already been completed there is no need to repeat it unless we have switched to another database or want to modify some of the parameter values.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='print("The starter kit already manages the local connection and database. No replacement database is created.")', language="python", min_height=100)
    run_005 = mo.ui.run_button(label="Run cell 5")
    mo.vstack([editor_005, run_005])
    return editor_005, run_005

@app.cell
def _(editor_005, lesson, mo, render, run_005):
    mo.stop(not run_005.value)
    render(mo, lesson.run(editor_005.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Start the Exasol Docker-DB

    If we choose to use the Exasol Docker-DB we need to launch it after every restart of the AI Lab. This operation may take a few moments. Please wait till it is completed before proceeding with the next step.

    For an external Exasol database, this operation will have no effect.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='print("The starter kit already manages the local connection and database. No replacement database is created.")', language="python", min_height=100)
    run_006 = mo.ui.run_button(label="Run cell 6")
    mo.vstack([editor_006, run_006])
    return editor_006, run_006

@app.cell
def _(editor_006, lesson, mo, render, run_006):
    mo.stop(not run_006.value)
    render(mo, lesson.run(editor_006.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Create DB schema

    We will now check if the schema specified in the configuration exists. The SQL statement below will attempt to create the schema if it doesn't already exist. This may fail if the provided credentials do not include sufficient permissions. The other reason for failure would be invalid credentials. In either case please check the credentials with your database administrator.

    To execute a query on the Exasol database we will be using the pyexasol module.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='print("The starter kit already manages the local connection and database. No replacement database is created.")', language="python", min_height=100)
    run_007 = mo.ui.run_button(label="Run cell 7")
    mo.vstack([editor_007, run_007])
    return editor_007, run_007

@app.cell
def _(editor_007, lesson, mo, render, run_007):
    mo.stop(not run_007.value)
    render(mo, lesson.run(editor_007.value))
    return

if __name__ == "__main__":
    app.run()
