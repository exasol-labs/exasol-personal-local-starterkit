import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/text_generation.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Generative text model

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/text_generation.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/text_generation.ipynb')", language="python", min_height=100)
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

    # Generative text model

    In this notebook, we will load and use a generative language model that can produce a continuation for a given text. Learn more about the Text Generation task <a href="https://huggingface.co/tasks/text-generation" target="_blank" rel="noopener">here</a>. Please also refer to the Transformer Extension <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a> to find more information about the UDF used in this notebook.

    To execute queries and load data from the Exasol database we will be using the <a href="https://github.com/exasol/pyexasol" target="_blank" rel="noopener">`pyexasol`</a> module.

    ## Prerequisites

    Prior to using this notebook the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).
    2. [Initialize the Transformer Extension](/?file=exasol-examples/transformers/te_init.py).

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
    ## Get a language model

    To demonstrate the text generation task we will use [Open Pretrained Transformers (OPT)](https://huggingface.co/facebook/opt-125m), a decoder-only pre-trained transformer from Facebook.

    We need to load the model from the Hugging Face Hub into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm). This could potentially be a long process, depending on the speed of the database connection. Unfortunately, we cannot tell exactly when it has finished. The notebook's hourglass may not be a reliable indicator. BucketFS will still be doing some work when the call issued by the notebook returns. Please wait for a few moments after that, before querying the model.

    You might see a warning that some weights are newly initialized and the model should be trained on a down-stream task. Please ignore this warning. For the purpose of this demonstration, it is not important, the model should still be able to produce some meaningful output.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value="from exasol.nb_connector.model_installation import install_model, TransformerModel\nfrom transformers import AutoModelForCausalLM\n\n# This is the name of the model at the Hugging Face Hub\nMODEL_NAME = 'facebook/opt-125m'\ninstall_model(ai_lab_config, TransformerModel(MODEL_NAME, 'text_generation', AutoModelForCausalLM))", language="python", min_height=100)
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
    ## Use the language model

    Let's put our starting text in a variable. We will feed this text to the `AI_COMPLETE_EXTENDED` UDF, which will use the previously downloaded model to generate a continuation of the input text.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='MY_TEXT = \'The bar-headed goose can fly at much\'\n\n# Make sure our texts can be used in an SQL statement.\nMY_TEXT = MY_TEXT.replace("\'", "\'\'")', language="python", min_height=100)
    run_004 = mo.ui.run_button(label="Run cell 4")
    mo.vstack([editor_004, run_004])
    return editor_004, run_004

@app.cell
def _(editor_004, lesson, mo, render, run_004):
    mo.stop(not run_004.value)
    render(mo, lesson.run(editor_004.value))
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\nfrom exasol.nb_connector.language_container_activation import get_activation_sql\n\n# We will be creating a new database session every time we call the model.\n# We will have to activate the language container for each of these sessions.\n# Here we will get the activation SQL command.\nactivation_sql = get_activation_sql(ai_lab_config)', language="python", min_height=100)
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
    The udf takes various input parameters:

    * device_id: To run the UDF on a GPU, specify the valid cuda device ID.
    * bucketfs_conn: The BucketFS connection name.
    * sub_dir: The directory where the model is stored in the BucketFS.
    * model_name: The name of the model to use for prediction.
    * text_data: The text continue.
    * max_new_tokens: The maximum amount of generated tokens.
    * return_full_text: If set to FALSE, only added text is returned, otherwise the full text is returned.

    You need to supply these parameters in the correct order. Further information can be found in the  <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.

    We will use the `max_new_tokens` paramter to put a limit on the length of text the model can generate in one call.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='MAX_NEW_TOKENS = 30', language="python", min_height=100)
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
    At the start, the `MY_TEXT` variable gives an initial context to the generated text. We will update this variable with the generated text after each call to the udf, making it add to the text each time.
    The generated text can be found in the `generated_text` column of the udf-output.

    You can run the next cell multiple times to see how the text evolves with multiple calls.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='sql = f"""\nSELECT {ai_lab_config.db_schema}.AI_COMPLETE_EXTENDED(\n    NULL,\n    \'{ai_lab_config.bfs_connection_name}\',\n    \'{ai_lab_config.bfs_model_subdir}\',\n    \'{MODEL_NAME}\',\n    \'{MY_TEXT}\',\n    {MAX_NEW_TOKENS},\n    True\n)\n"""\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.execute(query=activation_sql)\n    result = conn.export_to_pandas(query_or_table=sql).squeeze()\n    MY_TEXT = result[\'GENERATED_TEXT\']\n    # Errors can be observed at result[\'ERROR_MESSAGE\']\n\nprint(MY_TEXT)\nMY_TEXT = MY_TEXT.replace("\'", "\'\'")', language="python", min_height=100)
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
    If you need more details to your output, you can find information on all output columns in the <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.
    """)
    return

if __name__ == "__main__":
    app.run()
