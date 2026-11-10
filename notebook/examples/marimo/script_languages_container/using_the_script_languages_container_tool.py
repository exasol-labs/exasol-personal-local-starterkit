import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('script_languages_container/using_the_script_languages_container_tool.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Using the Script-Languages Container Tool

    Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/script_languages_container/using_the_script_languages_container_tool.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'script_languages_container/using_the_script_languages_container_tool.ipynb')", language="python", min_height=100)
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

    # Using the Script-Languages Container Tool
    A [Script-Language Container](https://github.com/exasol/script-languages-release)(SLC) for the Exasol database consists of a Linux container with a complete Linux distribution and all required libraries, such as a script client. The script client is responsible for the communication with the  database and for executing the script code. It allows to also include user specific libraries which can then be used from within the UDFs.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Before we start we need to configure the script-languages directory and flavor. See [Configure ScriptLanguageContainer](/?file=exasol-examples/script_languages_container/configure_slc_repository.py)
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    This tutorial uses the `template-Exasol-all-python-3.12` flavor as the base. In short words, a flavor is a recipe for building a script-languages-container. 
    Under the hood, the `exaslct` tool is used, see [Script-Language Container Tool](https://github.com/exasol/script-languages-container-tool) for details. The `exaslct` tool can be used to build, test and upload script-languages-container for an Exasol database.
    You will learn how to:
    - [Export a script-languages-container from the flavor](/?file=exasol-examples/script_languages_container/export_as_is.py)
    - [Customize the flavor, export and upload the script-language-container](/?file=exasol-examples/script_languages_container/customize.py)
    - [Test the uploaded script-languages-container](/?file=exasol-examples/script_languages_container/test_slc.py)

    Additionaly, there is the [Advanced Topics](/?file=exasol-examples/script_languages_container/advanced.py) tutorial which provides more detailed information.
    """)
    return

if __name__ == "__main__":
    app.run()
