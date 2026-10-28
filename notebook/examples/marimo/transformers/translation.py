import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/translation.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Translation model

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/translation.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/translation.ipynb')", language="python", min_height=100)
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

    # Translation model

    In this notebook we will load and use a language translation model. Learn more about the Translation task <a href="https://huggingface.co/tasks/translation" target="_blank" rel="noopener">here</a>. Please also refer to the Transformer Extension <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a> to find more information about the UDF used in this notebook.

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
    Let's bring up JupySQL and connect to the database via SQLAlchemy. 
    Please refer to the documentation of [sqlalchemy-exasol](https://github.com/exasol/sqlalchemy-exasol) for details on how to connect to the database using the Exasol SQLAlchemy driver.
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
    # AI_TRANSLATE

    There are two UDfs for translation available. The `AI_TRANSLATE` udf uses some default configuration parameters and a preselected model. If you need more control over your prediction, the `AI_TRANSLATE_EXTENDED` udf allows you to set all configuration parameters.

    We will start by showing you the `AI_TRANSLATE` UDF.

    This udf uses the translation pipeline(previously provided by transformers. we now maintain it ourselves) with the [google-t5/t5-base](https://huggingface.co/google-t5/t5-base) model for the prediction.
                                                                                            We will now use the `AI_TRANSLATE` UDF to translate some text from English to German.
                                                                                              The udf takes various input parameters:

     * text_data: The text to translate.
     * source_language: The language of the input.
     * target_language: The language of the desired output.


    Source and target language should be known by the model, check the models documentation if you are unsure.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='# Here is the text in English\nMY_TEXT = \'We all live in a yellow submarine\'\n\n# Make sure our text can be used in an SQL statement.\nMY_TEXT = MY_TEXT.replace("\'", "\'\'")\n\nSOURCE_LANGUAGE = \'English\'\nTARGET_LANGUAGE = \'German\'', language="python", min_height=100)
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
    You need to supply these parameters in the correct order. Further information can be found in the  <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.

    Let's run the translation model.
    We will save the result in the variable `udf_output` to support automatic testing of this notebook.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_TRANSLATE(\n        '{{MY_TEXT}}',\n        '{{SOURCE_LANGUAGE}}',\n        '{{TARGET_LANGUAGE}}'\n    )\n)\nSELECT translation_text, error_message FROM MODEL_OUTPUT", language="python", min_height=100)
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
    The translated text can be found in the output column `TRANSLATION_TEXT`, and any error occurring while executing the udf will be saved in the `ERROR_MESSAGES` column.

    We select only some of the udf's output columns in these examples.  If you need more details, you can find information on all available output columns in the <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.

    The code above shows how the model works on a toy example. However, the main purpose of having a model deployed in the database is to get a quick response for a batch input. The performance gain comes from two factors - localization and parallelization. The first means that the input data never crosses the machine boundaries. The second means that multiple instances of the model are processing the data on all available nodes in parallel.

    Another advantage of making predictions within the database is the enhanced data security. The task of safeguarding privacy can be simplified giving the fact that the source data never leaves the database machine.

    A more practical application would involve translating multiple pieces of text stored in a column of a database table. For example, we might want to do the translation for each row of the input table `MY_TEXT_TABLE`, where the text in the original language is stored in the column `MY_ORIGINAL_TEXT`. The SQL for this task would look similar to this:
    ```
    SELECT AI_TRANSLATE(MY_ORIGINAL_TEXT, ...) FROM MY_TEXT_TABLE;
    ```
    Please note, that the response time observed on the provided example with a single input will not be scaled up linearly in case of multiple inputs. Much of the latency falls on loading the model into the CPU memory from BucketFS. This needs to be done only once regardless of the number of inputs.

    # AI_TRANSLATE_EXTENDED

    If you want to use a different model for prediction, you can use the `AI_TRANSLATE_EXTENDED` udf instead. This will work nearly the same, but you need to have a model installed and then set the udf parameters so the model can be found by the udf.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Get a language model

    To demonstrate the translation task we will use [Facebook WMT19 English-German model](https://huggingface.co/facebook/wmt19-en-de).

    We need to load the model from the Hugging Face Hub into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm). This could potentially be a long process, depending on the speed of the database connection. Unfortunately, we cannot tell exactly when it has finished. The notebook's hourglass may not be a reliable indicator. BucketFS will still be doing some work when the call issued by the notebook returns. Please wait for a few moments after that, before querying the model.

    You might see a warning that some weights are newly initialized and the model should be trained on a down-stream task. Please ignore this warning. For the purpose of this demonstration, it is not important, the model should still be able to produce some meaningful output.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value="from exasol.nb_connector.model_installation import install_model, TransformerModel\nfrom transformers import AutoModelForSeq2SeqLM\n\n# This is the name of the model at the Hugging Face Hub\nMODEL_NAME = 'facebook/wmt19-en-de'\ninstall_model(ai_lab_config, TransformerModel(MODEL_NAME, 'translation', AutoModelForSeq2SeqLM))", language="python", min_height=100)
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
    ## Use the language model

    We will now use the `AI_TRANSLATE_EXTENDED` UDF to translate the same text as before. In addition to the previous parameters, we also need to set `max_new_tokens`, which will control the maximal length of output the model can return per input text.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='MAX_NEW_TOKENS = 200', language="python", min_height=100)
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
    The udf takes various input parameters:

    * device_id: To run the UDF on a GPU, specify the valid cuda device ID.
    * bucketfs_conn: The BucketFS connection name.
    * sub_dir: The directory where the model is stored in the BucketFS.
    * model_name: The name of the model to use for prediction.
    * text_data: The text to translate.
    * source_language: The language of the input. Required for multilingual models only.
    * target_language: The language of the desired output. Required for multilingual models only.
    * max_new_tokens: The maximum amount of generated tokens.

    You need to supply these parameters in the correct order. Further information can be found in the  <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.

    Let's run the translation model.
    We will save the result in the variable `udf_output` to support automatic testing of this notebook.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_TRANSLATE_EXTENDED(\n        NULL,\n        '{{ai_lab_config.bfs_connection_name}}',\n        '{{ai_lab_config.bfs_model_subdir}}',\n        '{{MODEL_NAME}}',\n        '{{MY_TEXT}}',\n        '{{SOURCE_LANGUAGE}}',\n        '{{TARGET_LANGUAGE}}',\n        {{MAX_NEW_TOKENS}}\n    )\n)\nSELECT translation_text, error_message FROM MODEL_OUTPUT", language="python", min_height=100)
    run_008 = mo.ui.run_button(label="Run cell 8")
    mo.vstack([editor_008, run_008])
    return editor_008, run_008

@app.cell
def _(editor_008, lesson, mo, render, run_008):
    mo.stop(not run_008.value)
    render(mo, lesson.run(editor_008.value))
    return

if __name__ == "__main__":
    app.run()
