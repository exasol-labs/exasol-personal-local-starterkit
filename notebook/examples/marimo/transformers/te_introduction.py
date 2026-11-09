import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/te_introduction.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Introduction

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/te_introduction.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/te_introduction.ipynb')", language="python", min_height=100)
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

    This set of notebooks demonstrates the functionality of the Exasol Transformer Extension. The extension allows the use of a pre-trained NLP model that can be found at the Hugging Face Hub. It consists of a number of UDF and Lua scripts. The scripts can be uploaded into the database using a Python library.

    For more information, please refer to the Transformer Extension <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.

    ## Prerequisites

    Before using this notebook the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).

    ## Setup

    Please start with the [Extension Initialization](/?file=exasol-examples/transformers/te_init.py) page.

    ## NLP Tasks

    The Extension provides the following NLP tasks:

    * [Sequence Classification](/?file=exasol-examples/transformers/sequence_classification.py)
    * [Question Answering](/?file=exasol-examples/transformers/question_answering.py)
    * [Masked Language Modelling](/?file=exasol-examples/transformers/masked_modelling.py)
    * [Text Generation](/?file=exasol-examples/transformers/text_generation.py)
    * [Token Classification](/?file=exasol-examples/transformers/token_classification.py)
    * [Text Translation](/?file=exasol-examples/transformers/translation.py)
    * [Zero-Shot Text Classification](/?file=exasol-examples/transformers/zero_shot_classification.py)

    ## Model Management

    You also can manage the installed models with the extension:

    * [Model Management](/?file=exasol-examples/transformers/model_management.py)
    """)
    return

if __name__ == "__main__":
    app.run()
