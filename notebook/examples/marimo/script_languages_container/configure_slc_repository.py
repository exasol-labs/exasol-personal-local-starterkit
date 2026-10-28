import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('script_languages_container/configure_slc_repository.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Configure Tutorial Script Languages Container

    Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/script_languages_container/configure_slc_repository.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'script_languages_container/configure_slc_repository.ipynb')", language="python", min_height=100)
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

    # Configure Tutorial Script Languages Container

    ## Prerequisites

    Prior to using this notebook the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).

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
    ## Specific Configuration for this Tutorial

    For this tutorial we need the build definition of a Script-Languages container.

    The tutorial will clone the Script-Languages-Release repository and use a specifc version.
    First we import a convenience class from the notebook connector, called `ScriptLanguagesContainer`.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exasol.nb_connector.slc import ScriptLanguageContainer', language="python", min_height=100)
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
    The package provides two constants pointing to the Github release used in the current version.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='from exasol.nb_connector.slc.constants import SLC_GITHUB_REPO, SLC_RELEASE_TAG\nprint(f"Github URL: {SLC_GITHUB_REPO}")\nprint(f"Release Tag: {SLC_RELEASE_TAG}")', language="python", min_height=100)
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
    The class `ScriptLanguageContainer` also provides a function to fetch and show all available template flavors:
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='ScriptLanguageContainer.list_available_flavors()', language="python", min_height=100)
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
    ### Define the flavor for our Script Languages Container

    Now let's define the flavor we want to use in this tutorial. In this tutorial we will use the [template-Exasol-all-python-3.12](https://github.com/exasol/script-languages/blob/master/flavors/template-Exasol-all-python-3.12/FLAVOR_DESCRIPTION.md) flavor.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='flavor = "template-Exasol-all-python-3.12"', language="python", min_height=100)
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
    ### Create an instance of class ScriptLanguagesContainer

    The following cell creates an instance of class `ScriptLanguageContainer` from the notebook-connector,
    which enables using the`exaslct` in the AI Lab in a convenient way.
    Creating this instance will:
    * Check that no other entries exist in Secret Store
    * Add all necessary entries to the Secret Store
    * Clone the [script-languages-release](https://github.com/exasol/script-languages-release) repository
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='slc = ScriptLanguageContainer.create_or_open(secrets=ai_lab_config, name="sample_slc", flavor=flavor)\nprint(f"{slc.name} is ready.")', language="python", min_height=100)
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
    ## Finish
    Now you can continue with [Using the script-languages-container tool](/?file=exasol-examples/script_languages_container/using_the_script_languages_container_tool.py)
    """)
    return

if __name__ == "__main__":
    app.run()
