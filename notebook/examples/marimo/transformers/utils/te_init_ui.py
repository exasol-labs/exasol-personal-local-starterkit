import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/utils/te_init_ui.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Hugging Face credentials UI

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/utils/te_init_ui.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/utils/te_init_ui.ipynb')", language="python", min_height=100)
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

    # Hugging Face credentials UI

    <b>This notebook is not supposed to be used on its own.<b>
    """)
    return

@app.cell
def _(mo):
    editor_002 = mo.ui.code_editor(value='from exasol.nb_connector.ui.config import generic', language="python", min_height=100)
    run_002 = mo.ui.run_button(label="Run cell 2")
    mo.vstack([editor_002, run_002])
    return editor_002, run_002

@app.cell
def _(editor_002, lesson, mo, render, run_002):
    mo.stop(not run_002.value)
    render(mo, lesson.run(editor_002.value))
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value="import ipywidgets as widgets\n\nfrom exasol.nb_connector.secret_store import Secrets\nfrom exasol.nb_connector.ai_lab_config import AILabConfig as CKey\n\n\ndef get_te_config_ui(conf: Secrets) -> widgets.Widget:\n\n    inputs = [\n        ('Access token', widgets.Password(value=ai_lab_config.get(CKey.huggingface_token)), CKey.huggingface_token)\n    ]\n\n    return generic.get_config(conf, [inputs], ['Hugging Face Access Parameters'])", language="python", min_height=100)
    run_003 = mo.ui.run_button(label="Run cell 3")
    mo.vstack([editor_003, run_003])
    return editor_003, run_003

@app.cell
def _(editor_003, lesson, mo, render, run_003):
    mo.stop(not run_003.value)
    render(mo, lesson.run(editor_003.value))
    return

if __name__ == "__main__":
    app.run()
