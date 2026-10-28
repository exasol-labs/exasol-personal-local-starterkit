import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('script_languages_container/export_as_is.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Export the flavor as is

    Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/script_languages_container/export_as_is.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'script_languages_container/export_as_is.ipynb')", language="python", min_height=100)
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

    # Export the flavor as is

    Exasol [User Defined Functions](https://docs.exasol.com/db/latest/database_concepts/udf_scripts.htm) (UDFs) enable embedding user code into SQL statements. Each Python UDF runs in a so-called [Script-Languages-Container](https://docs.exasol.com/db/latest/database_concepts/udf_scripts/adding_new_packages_script_languages.htm) (SLC). Exasol provides default SLCs with some preinstalled PYthon packages but also allows users to create their own SLCs, e.g. by adding additional dependencies.

    This tutorial shows how to build a Script-Languages-Container (SLC) from a base flavor (without any modification) and write the result to a tar gz file. The base flavor `template-Exasol-all-python-3.12` is part of the Script-Languages Release repository.

    `exaslct` uses the flavor description to build a Docker image which is called the `release` image. `exaslct` can export the content of this Docker image then to a tar gz file.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
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
    ### Instantiate ScriptLanguagesContainer

    The following cell creates an instance of class `ScriptLanguageContainer` from the notebook-connector,
    which enables using the`exaslct` in the AI Lab in a convenient way.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exasol.nb_connector.slc import ScriptLanguageContainer\nslc = ScriptLanguageContainer(secrets=ai_lab_config, name="sample_slc")', language="python", min_height=100)
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
    ### Import Some utility functions
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='%run ./utils/file_system_ui.ipynb', language="python", min_height=100)
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
    ## Export
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Currently used flavor is:
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='slc.flavor', language="python", min_height=100)
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
    ### Export the flavor

    Now execute the `export` step. The command builds the docker image and exports the Docker image to the export directory.

    You could run the same on the command line with the `exaslct` tool:
    ```
    cd <slc_dir>
    ./exaslct export --flavor-path flavors/<flavor_path>
    ```
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='slc.export()', language="python", min_height=100)
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
    #### Check the result
    The following command will show the resulting files of the export command:
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='show_directory_content(slc.workspace.export_path)', language="python", min_height=100)
    run_007 = mo.ui.run_button(label="Run cell 7")
    mo.vstack([editor_007, run_007])
    return editor_007, run_007

@app.cell
def _(editor_007, lesson, mo, render, run_007):
    mo.stop(not run_007.value)
    render(mo, lesson.run(editor_007.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Hint: If you want to download the tar gz file, you can do this in the Jupyter Project View on the left side.

    The resulting tar gz can then be uploaded to BucketFS. You will learn how to do this in the next lesson:
    [Customize the flavor, export and upload the script-language-container](/?file=exasol-examples/script_languages_container/customize.py)
    """)
    return

if __name__ == "__main__":
    app.run()
