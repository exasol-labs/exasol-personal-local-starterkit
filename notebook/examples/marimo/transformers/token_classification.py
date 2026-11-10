import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/token_classification.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Token classifier model

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/token_classification.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/token_classification.ipynb')", language="python", min_height=100)
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

    # Token classifier model

    In this notebook, we will load and use token classifier language models that will find important tokens or words in an input text, and assign labels to these found tokens. Learn more about the Token Classification task <a href="https://huggingface.co/tasks/token-classification" target="_blank" rel="noopener">here</a>. Please also refer to the Transformer Extension <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a> to find more information about the UDFs used in this notebook.

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
    # AI_EXTRACT_ENTITIES

    There are two UDfs for token classification. The `AI_EXTRACT_ENTITIES` udf uses some default configuration parameters and a preselected model. If you need more control over your prediction, the `AI_EXTRACT_EXTENDED` udf allows you to set all configuration parameters.

    We will start by showing you the `AI_EXTRACT_ENTITIES` udf.
                                                                                              This udf uses the token-classification pipeline with the [guishe/nuner-v2_fewnerd_fine_super](https://huggingface.co/guishe/nuner-v2_fewnerd_fine_super/tree/main) model for the prediction.

    As input text we have selected a medical report on a patient examination.

    We will be searching for occurrences of recognized entities in this report using the `AI_EXTRACT_ENTITIES` UDF. Such recognized entities can include patient data (e.g. age, gender), symptoms, clinical events, laboratory test results, etc.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='# We will display all model output\n%config SqlMagic.displaylimit = 0', language="python", min_height=100)
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
    editor_005 = mo.ui.code_editor(value='MY_TEXT = """\nA 63-year-old woman with no known cardiac history presented with a sudden onset of dyspnea requiring\nintubation and ventilatory support out of hospital. She denied preceding symptoms of chest discomfort,\npalpitations, syncope or infection. The patient was afebrile and normotensive, with a sinus tachycardia\nof 140 beats/min.\n"""\n\n# Make sure our texts can be used in an SQL statement.\nMY_TEXT = MY_TEXT.replace("\'", "\'\'")', language="python", min_height=100)
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
    Let's run the token classification model. We will save the result in the variable `udf_output` to support automatic testing of this notebook.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_EXTRACT_ENTITIES(\n        '{{MY_TEXT}}'\n    )\n)\nSELECT start_pos, end_pos, word, entity, error_message FROM MODEL_OUTPUT ORDER BY start_pos, end_pos", language="python", min_height=100)
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

    * start_pos: The index of the starting character of the token.
    * end_pos: The index of the ending character of the token.
    * word: The token found in the text.
    * entity: The token-type the found token was sorted into.
    * score: The confidence, with which the token was assigned.
    * error_message: Errors occurring while executing the udf will be saved here.

    The code above shows how the model works on a toy example. However, the main purpose of having a model deployed in the database is to get a quick response for a batch input. The performance gain comes from two factors - localization and parallelization. The first means that the input data never crosses the machine boundaries. The second means that multiple instances of the model are processing the data on all available nodes in parallel.

    Another advantage of making predictions within the database is enhanced data security. The task of safeguarding privacy can be simplified given the fact that the source data never leaves the database machine.

    In a more practical application, we might want to tokenize text stored in a column of a database table. One possible use case would be collecting statistics of token occurrence in say customer reviews, where each review is stored in a separate row. For example, if the text to be tokenized is stored in the column `MY_TEXT_COLUMN` of the table `MY_TEXT_TABLE` and we want to get the counts of the top 10 tokens, the SQL would look similar to this:
    ```
    SELECT entity, COUNT(*) as occurrence
    FROM (
        SELECT AI_EXTRACT_ENTITIES(MY_TEXT_COLUMN)
        FROM MY_TEXT_TABLE
    ) tokenized 
    GROUP BY entity
    ORDER BY 2 DESC
    LIMIT 10;
    ```
    Please note, that the response time observed on the provided example with a single input will not be scaled up linearly in case of multiple inputs. Much of the latency falls on loading the model into the CPU memory from BucketFS. This needs to be done only once regardless of the number of inputs.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # AI_EXTRACT_EXTENDED

    Medical data analysis is a task quite different to the analysis of other kinds of text. Let's see if a model trained specifically on medical data might give us better results. For this, we are going to use the `AI_EXTRACT_EXTENDED`, which works the same as the previous udf, but lets you select which model and aggregation strategy to use.

    For this, we will need to have a model installed and then set the udf parameters so the model can be found by the udf.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Get a language model

    We will use an [English Named Entity Recognition model](https://huggingface.co/sschet/biomedical-ner-all), trained on Maccrobat to recognize the bio-medical entities (107 entities) from a given text corpus (case reports, etc.).

    We need to load the model from the Hugging Face Hub into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm). This could potentially be a long process, depending on the speed of the database connection. Unfortunately, we cannot tell exactly when it has finished. The notebook's hourglass may not be a reliable indicator. BucketFS will still be doing some work when the call issued by the notebook returns. Please wait for a few moments after that, before querying the model.

    You might see a warning that some weights are newly initialized and the model should be trained on a down-stream task. Please ignore this warning. For the purpose of this demonstration, it is not important, the model should still be able to produce some meaningful output.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value="from exasol.nb_connector.model_installation import install_model, TransformerModel\nfrom transformers import AutoModelForTokenClassification\n\n# This is the name of the model at the Hugging Face Hub\nMODEL_NAME = 'sschet/biomedical-ner-all'\ninstall_model(ai_lab_config, TransformerModel(MODEL_NAME, 'token_classification', AutoModelForTokenClassification))", language="python", min_height=100)
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
    ## Use the language model

    We are going to use the same input text with this new model.

    The udf takes various input parameters:

    * device_id: To run the UDF on a GPU, specify the valid cuda device ID.
    * bucketfs_conn: The BucketFS connection name.
    * sub_dir: The directory where the model is stored in the BucketFS.
    * model_name: The name of the model to use for prediction.
    * text_data: The text to analyze.
    * aggregation_strategy: The strategy about whether to fuse tokens based on the model prediction.

    You need to supply these parameters in the correct order. Further information can be found in the  <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.

    Let's run the token classification model. We will save the result in the variable `udf_output` to support automatic testing of this notebook.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_EXTRACT_EXTENDED(\n        NULL,\n        '{{ai_lab_config.bfs_connection_name}}',\n        '{{ai_lab_config.bfs_model_subdir}}',\n        '{{MODEL_NAME}}',\n        '{{MY_TEXT}}',\n        NULL\n    )\n)\nSELECT start_pos, end_pos, word, entity, error_message FROM MODEL_OUTPUT ORDER BY start_pos, end_pos", language="python", min_height=100)
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
