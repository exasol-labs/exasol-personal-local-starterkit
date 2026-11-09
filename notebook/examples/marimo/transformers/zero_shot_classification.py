import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/zero_shot_classification.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Zero-shot classification model

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/zero_shot_classification.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/zero_shot_classification.ipynb')", language="python", min_height=100)
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

    # Zero-shot classification model

    In this notebook we will load and use zero shot classification language models. Learn about the Zero Shot Classification task <a href="https://huggingface.co/tasks/zero-shot-classification" target="_blank" rel="noopener">here</a>. Please also refer to the Transformer Extension <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a> to find more information about the UDF used in this notebook.

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
    # AI_CLASSIFY

    There are two UDfs for zero shot classification. The `AI_CLASSIFY` udf uses some default configuration parameters and a preselected model. If you need more control over your prediction, the `AI_CLASSIFY_EXTENDED` udf allows you to set all configuration parameters.

    We will start by showing you the `AI_CLASSIFY` udf.
                                                                                             This udf uses the zero-shot-classification pipeline with the [MoritzLaurer/ModernBERT-large-zeroshot-v2.0](https://huggingface.co/MoritzLaurer/ModernBERT-large-zeroshot-v2.0) model for the prediction. 

    Below is a text that we will try to classify using labels that were not necessarily used during the model training. Out of five suggested labels the first two are much more relevant than the others. We expect the model to give them significantly higher scores.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='# Text to be classified.\nMY_TEXT = """\nA new model offers an explanation for how the Galilean satellites formed around the solar system’s largest world. \nKonstantin Batygin did not set out to solve one of the solar system’s most puzzling mysteries when he went for a\nrun up a hill in Nice, France. Dr. Batygin, a Caltech researcher, best known for his contributions to the search\nfor the solar system’s missing “Planet Nine,” spotted a beer bottle. At a steep, 20 degree grade, he wondered why\nit wasn’t rolling down the hill. He realized there was a breeze at his back holding the bottle in place. Then he\nhad a thought that would only pop into the mind of a theoretical astrophysicist: “Oh! This is how Europa formed.”\nEuropa is one of Jupiter’s four large Galilean moons. And in a paper published Monday in the Astrophysical Journal,\nDr. Batygin and a co-author, Alessandro Morbidelli, a planetary scientist at the Côte d’Azur Observatory in France,\npresent a theory explaining how some moons form around gas giants like Jupiter and Saturn, suggesting that\nmillimeter-sized grains of hail produced during the solar system’s formation became trapped around these massive\nworlds, taking shape one at a time into the potentially habitable moons we know today.\n"""\n\n# Make sure our texts can be used in an SQL statement.\nMY_TEXT = MY_TEXT.replace("\'", "\'\'")\n\n# Classes, not seen during model training.\nMY_LABELS = \'space & cosmos, scientific discovery, microbiology, robots, archeology\'', language="python", min_height=100)
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
    Let's run the zero shot text classification model. We will save the result in the variable `udf_output` to support automatic testing of this notebook.

    The `AI_CLASSIFY` UDF takes various input parameters:

    * text_data: The text to be classified.
    * candidate_labels: Labels, should be comma-separated.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH\n  MODEL_OUTPUT AS (\n    SELECT\n      AI_CLASSIFY ('{{MY_TEXT}}', '{{MY_LABELS}}')\n  )\nSELECT\n  label,\n  score,\n  error_message\nFROM\n  MODEL_OUTPUT\nORDER BY\n  SCORE DESC", language="python", min_height=100)
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
    The code above shows how the model works on a toy example. However, the main purpose of having a model deployed in the database is to get a quick response for a batch input. The performance gain comes from two factors - localization and parallelization. The first means that the input data never crosses the machine boundaries. The second means that multiple instances of the model are processing the data on all available nodes in parallel.

    Another advantage of making predictions within the database is the enhanced data security. The task of safeguarding privacy can be simplified giving the fact that the source data never leaves the database machine.

    In a more practical application the text to be classified would be stored in a column of a database table. For example, if we wanted to get a label with the highest score for each row of the input table `MY_TEXT_TABLE`, where the text in question is in the column `MY_TEXT_COLUMN`, the SQL would look similar to this:
    ```
    WITH MODEL_OUTPUT AS
    (
        SELECT AI_CLASSIFY(MY_TEXT_COLUMN, <MY_LABELS>) FROM MY_TEXT_TABLE
    )
    SELECT test_data, label FROM MODEL_OUTPUT WHERE rank=1;
    ```
    Please note, that the response time observed on the provided example with a single input will not be scaled up linearly in case of multiple inputs. Much of the latency falls on loading the model into the CPU memory from BucketFS. This needs to be done only once regardless of the number of inputs.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # AI_CLASSIFY_EXTENDED

    If you want to use a different model for prediction, you can use the `AI_CLASSIFY_EXTENDED` udf instead. This will work nearly the same, but you need to have a model installed and then set the udf parameters so the model can be found by the udf.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Get a language model

    To demonstrate the zero shot classification task we will use the [Cross-Encoder for Natural Language Inference](https://huggingface.co/cross-encoder/nli-deberta-base) model.

    We need to load the model from the Hugging Face Hub into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm). This could potentially be a long process, depending on the speed of the database connection. Unfortunately, we cannot tell exactly when it has finished. The notebook's hourglass may not be a reliable indicator. BucketFS will still be doing some work when the call issued by the notebook returns. Please wait for a few moments after that, before querying the model.

    You might see a warning that some weights are newly initialized and the model should be trained on a down-stream task. Please ignore this warning. For the purpose of this demonstration, it is not important, the model should still be able to produce some meaningful output.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value="from exasol.nb_connector.model_installation import install_model, TransformerModel\nfrom transformers import AutoModelForSequenceClassification\n\n# This is the name of the model at the Hugging Face Hub\nMODEL_NAME = 'cross-encoder/nli-deberta-base'\ninstall_model(ai_lab_config, TransformerModel(MODEL_NAME, 'zero_shot_classification', AutoModelForSequenceClassification))", language="python", min_height=100)
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

    We will use the same input text with this new model.

    Let's run the zero shot text classification model. We will save the result in the variable `udf_output` to support automatic testing of this notebook.

    The `AI_CLASSIFY_EXTENDED` UDF takes various input parameters:

    * device_id: To run the UDF on a GPU, specify the valid cuda device ID.
    * bucketfs_conn: The BucketFS connection name.
    * sub_dir: The directory where the model is stored in the BucketFS.
    * model_name: The name of the model to use for prediction.
    * text_data: The text to be classified.
    * candidate_labels: Labels, should be comma-separated.
    * return_ranks: Either "ALL" or "HIGHEST".

    You need to supply these parameters in the correct order. Further information can be found in the  <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH\n  MODEL_OUTPUT AS (\n    SELECT\n      AI_CLASSIFY_EXTENDED (\n        NULL,\n        '{{ai_lab_config.bfs_connection_name}}',\n        '{{ai_lab_config.bfs_model_subdir}}',\n        '{{MODEL_NAME}}',\n        '{{MY_TEXT}}',\n        '{{MY_LABELS}}',\n        'HIGHEST'\n      )\n  )\nSELECT\n  label,\n  score,\n  error_message\nFROM\n  MODEL_OUTPUT\nORDER BY\n  SCORE DESC", language="python", min_height=100)
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
    In this instance, we let the model return only the highest ranking result by setting `return_ranks = "HIGHEST"`. If we want to get all available results instead, we can run it with `return_ranks = "ALL"` instead:
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH\n  MODEL_OUTPUT AS (\n    SELECT\n      AI_CLASSIFY_EXTENDED (\n        NULL,\n        '{{ai_lab_config.bfs_connection_name}}',\n        '{{ai_lab_config.bfs_model_subdir}}',\n        '{{MODEL_NAME}}',\n        '{{MY_TEXT}}',\n        '{{MY_LABELS}}',\n        'ALL'\n      )\n  )\nSELECT\n  label,\n  score,\n  error_message\nFROM\n  MODEL_OUTPUT\nORDER BY\n  SCORE DESC", language="python", min_height=100)
    run_008 = mo.ui.run_button(label="Run cell 8")
    mo.vstack([editor_008, run_008])
    return editor_008, run_008

@app.cell
def _(editor_008, lesson, mo, render, run_008):
    mo.stop(not run_008.value)
    render(mo, lesson.run(editor_008.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    We select only some of the udf's output columns in these examples.  If you need more details, you can find information on all available output columns in the <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.

    The output of the model is sorted into the following columns by the udf:

    * label: the label the model assigned for the input
    * score: the confidence, with which the label was assigned
    * rank: the rank of the label. In this context, all predictions/labels for one input are ranked by their score. rank=1 means best result/highest score.
    * error_message: error occurring while executing the udf will be saved here
    """)
    return

if __name__ == "__main__":
    app.run()
