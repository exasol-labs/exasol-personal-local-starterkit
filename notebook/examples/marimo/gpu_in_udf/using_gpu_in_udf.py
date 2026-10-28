import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('gpu_in_udf/using_gpu_in_udf.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Using GPU's in UDF's

    Requires a GPU-capable Exasol host and GPU SLC. The local Mac kit does not provision these.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/gpu_in_udf/using_gpu_in_udf.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'gpu_in_udf/using_gpu_in_udf.ipynb')", language="python", min_height=100)
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

    # Using GPU's in UDF's

    This tutorial shows step-by-step how to build a CUDA enabled Script Language Container with the appropriate ML libraries and how to create UDF's with GPU acceleration.
    For a detailed explanation about how to build a custom Script Language Container, please read the tutorial [Script Languages Container](/?file=exasol-examples/script_languages_container/using_the_script_languages_container_tool.py)

    **Notes:**
    - **This tutorial currently does not support Exasol SaaS instances.**
    - **This tutorial was written to work with Exasol DB 2025.02.x. Different versions of Exasol potentially will not work correctly.**
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Prerequisites

    Prior to using this notebook step [Configure the AI Lab](/?file=exasol-examples/main_config.py) needs to be completed.

    Make sure to enable the `nvidia` accelerator option in case you choose the "Exasol Docker DB" as database.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Content

    This tutorial contains the following notebooks:
    1. The [setup](/?file=exasol-examples/gpu_in_udf/setup.py) prepares a GPU enabled Script Languages Container. You need to run it once before you can execute the below examples.
    1. [Basic UDF with GPU Support](/?file=exasol-examples/gpu_in_udf/basic_udf_with_gpu.py)
    2. [Advanced UDF with GPU Support](/?file=exasol-examples/gpu_in_udf/advanced_udf_with_gpu.py)
    """)
    return

if __name__ == "__main__":
    app.run()
