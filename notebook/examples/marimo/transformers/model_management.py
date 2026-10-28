import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/model_management.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Model Management

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/model_management.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/model_management.ipynb')", language="python", min_height=100)
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
    # Model Management

    This notebook shows how you can manage the installed models in BucketFS.

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
    ## Install a model

    In this example we need some model to demonstrate the available administration UDFs. For this we install the [Ekman emotions classifier](https://huggingface.co/arpanghoshal/EkmanClassifier) model.

    We need to load the model from the Hugging Face Hub into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm). This could potentially be a long process. Unfortunately, we cannot tell exactly when it has finished. The notebook's hourglass may not be a reliable indicator. BucketFS will still be doing some work when the call issued by the notebook returns. Please wait for a few moments after that, before querying the model.

    You might see a warning that some weights are newly initialized and the model should be trained on a down-stream task. Please ignore this warning. For the purpose of this demonstration, it is not important.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value="from exasol.nb_connector.model_installation import install_model, TransformerModel\nfrom transformers import AutoModelForSequenceClassification\n# This is the name of the model at the Hugging Face Hub\nMODEL_NAME = 'arpanghoshal/EkmanClassifier'\ninstall_model(ai_lab_config, TransformerModel(MODEL_NAME, 'text_classification', AutoModelForSequenceClassification))", language="python", min_height=100)
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
    ## List available models

    Now we have at least one model installed in BucketFS. (If you have already executed other notebooks from the Transformer Extension tuturial, you probably will have more models installed)

    We now can use the `TE_LIST_MODELS_UDF` UDF to check all available models.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value="%%sql --save udf_output\nSELECT TE_LIST_MODELS_UDF(\n    '{{ai_lab_config.bfs_connection_name}}',\n    '{{ai_lab_config.bfs_model_subdir}}'\n)", language="python", min_height=100)
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
    ## Delete a model

    You can delete a model using the `TE_DELETE_MODEL_UDF` UDF.
    In the following example we delete the model, which was installed before.
    Note: We don't use the `%%sql` expression here because it interfers with the test tools. But feel free to use `%%sql` in your own notebooks.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value="model_delete = %sql SELECT TE_DELETE_MODEL_UDF( \\\n    '{{ai_lab_config.bfs_connection_name}}', \\\n    '{{ai_lab_config.bfs_model_subdir}}', \\\n    'arpanghoshal/EkmanClassifier', \\\n    'text-classification' \\\n)\nmodel_delete", language="python", min_height=100)
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
    Running the `TE_LIST_MODELS_UDF` again now will show that the model was removed from BucketFS.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value="%%sql --save udf_output\nSELECT TE_LIST_MODELS_UDF(\n    '{{ai_lab_config.bfs_connection_name}}',\n    '{{ai_lab_config.bfs_model_subdir}}'\n)", language="python", min_height=100)
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
    `TE_DELETE_MODEL_UDF` will not fail if an invalid parameter was given, instead it will indicate an error in the output columns `success` and `error_message`.
    We can observe this behaviour if we now try to delete the same model again.

    Note: We don't use the `%%sql` expression here because it interferes with the test tools. But feel free to use `%%sql` in your own notebooks.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value="model_delete_with_error = %sql SELECT TE_DELETE_MODEL_UDF( \\\n    '{{ai_lab_config.bfs_connection_name}}', \\\n    '{{ai_lab_config.bfs_model_subdir}}', \\\n    'arpanghoshal/EkmanClassifier', \\\n    'text-classification' \\\n)\nmodel_delete_with_error", language="python", min_height=100)
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
