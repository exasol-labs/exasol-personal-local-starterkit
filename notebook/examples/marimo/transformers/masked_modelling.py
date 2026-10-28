import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/masked_modelling.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Fill-Mask model

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/masked_modelling.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/masked_modelling.ipynb')", language="python", min_height=100)
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

    # Fill-Mask model

    In this notebook, we will load and use a masked language model. This kind of model predicts which words would replace masked words in a sentence. Learn more about the Fill-Mask task <a href="https://huggingface.co/tasks/fill-mask" target="_blank" rel="noopener">here</a>. Please also refer to the Transformer Extension <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a> to find more information about the UDF used in this notebook.

    We will be running SQL queries using <a href="https://github.com/ploomber/jupysql" target="_blank" rel="noopener">JupySQL</a>SQL Magic.

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
    Let's bring up JupySQL and connect to the database via SQLAlchemy. Please refer to the documentation of <a href="https://github.com/exasol/sqlalchemy-exasol" target="_blank" rel="noopener">sqlalchemy-exasol</a> for details on how to connect to the database using the Exasol SQLAlchemy driver.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exakit.nb.example_runtime import init_sql as jupysql_init\njupysql_init(ai_lab_config)', language="python", min_height=100)
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
    ## Get a language model

    To demonstrate the filling of a masked word task we will use a [RadBERT model](https://huggingface.co/StanfordAIMI/RadBERT) which was pre-trained on radiology reports.

    We need to load the model from the Hugging Face Hub into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm). This could potentially be a long process, depending on the speed of the database connection. Unfortunately, we cannot tell exactly when it has finished. The notebook's hourglass may not be a reliable indicator. [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm) will still be doing some work when the call issued by the notebook returns. Please wait for a few moments after that, before querying the model.

    You might see a warning that some weights are newly initialized and the model should be trained on a down-stream task. Please ignore this warning. For the purpose of this demonstration, it is not important, the model should still be able to produce some meaningful output.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value="from exasol.nb_connector.model_installation import install_model, TransformerModel\nfrom transformers import AutoModelForMaskedLM\n\n# This is the name of the model at the Hugging Face Hub\nMODEL_NAME = 'StanfordAIMI/RadBERT'\ninstall_model(ai_lab_config, TransformerModel(MODEL_NAME, 'fill_mask', AutoModelForMaskedLM))", language="python", min_height=100)
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
    ## Use the language model

    Let's see if the model can fill in a masked word in the following text. We will be using the `AI_FILL_MASK_EXTENDED` UDF for this. We will use an patient-instruction as the input text.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='# This is a sentence with a masked word that will be given to the model.\n# It instruction usually given to a patient when a radiographer is doing a chest X-ray\nMY_TEXT = \'Take a deep [MASK] and hold it\'\n\n# Make sure our text can be used in an SQL statement.\nMY_TEXT = MY_TEXT.replace("\'", "\'\'")', language="python", min_height=100)
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
    * text_data: The text data containing masking tokens.
    * top_k: The number of predictions to return.

    We will collect the 5 best answers.
    We will save the result in the variable `udf_output` to support automatic testing of this notebook.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_FILL_MASK_EXTENDED(\n        NULL,\n        '{{ai_lab_config.bfs_connection_name}}',\n        '{{ai_lab_config.bfs_model_subdir}}',\n        '{{MODEL_NAME}}',\n        '{{MY_TEXT}}',\n        5\n    )\n)\nSELECT filled_text, score, rank, error_message FROM MODEL_OUTPUT ORDER BY SCORE DESC", language="python", min_height=100)
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
    We select only some of the udf's output columns in these examples.  If you need more details, you can find information on all available output columns in the <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.

    The output of the model is sorted into the following columns by the udf:

    * filled_text: the filled text which replaces the masked part od the input text
    * score: the confidence, with which the filled_text was predicted
    * rank: the rank of the prediction. In this context, all predictions/labels for one input are ranked by their score. rank=1 means best result/highest score.
    * error_message: error occurring while executing the udf will be saved here


    The code above shows how the model works on a toy example. However, the main purpose of having a model deployed in the database is to get a quick response for a batch input. The performance gain comes from two factors - localization and parallelization. The first means that the input data never crosses the machine boundaries. The second means that multiple instances of the model are processing the data on all available nodes in parallel.

    Another advantage of making predictions within the database is enhanced data security. The task of safeguarding privacy can be simplified given the fact that the source data never leaves the database machine.

    In a more practical application, the input text would be stored in a column of a database table. For example, if we wanted to get the best answer for each row of the input table `MY_TEXT_TABLE`, where text with a masked word is in the column `MY_TEXT_COLUMN`, the SQL would look similar to this:
    ```
    SELECT AI_FILL_MASK_EXTENDED(..., MY_TEXT_COLUMN, 1) FROM MY_TEXT_TABLE;
    ```
    Please note, that the response time observed on the provided example with a single input will not be scaled up linearly in case of multiple inputs. Much of the latency falls on loading the model into the CPU memory from BucketFS. This needs to be done only once regardless of the number of inputs.
    """)
    return

if __name__ == "__main__":
    app.run()
