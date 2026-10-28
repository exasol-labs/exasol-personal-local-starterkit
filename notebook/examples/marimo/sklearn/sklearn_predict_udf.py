import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('sklearn/sklearn_predict_udf.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Generic Prediction UDF

    Load the matching Abalone or Telescope data notebook first. Prediction requires udf-devkit and the PYTHON3_ML runtime. Models use the local file bucket.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/sklearn/sklearn_predict_udf.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'sklearn/sklearn_predict_udf.ipynb')", language="python", min_height=100)
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

    # Generic Prediction UDF

    In this notebook, we are going to create a universal UDF SET script that will use a trained scikit-learn model for making a prediction. In order to use this script one has to create and train a scikit-learn model or a pipeline and upload its pickle file into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm). The list of features supplied to the UDF should match those used in model training and/or pre-processing. The script emits the prediction labels. The output of the script can be multi-dimensional. It works similarly in regression and classification scenarios.

    To communicate with the Exasol database we will be using the <a href="https://github.com/exasol/pyexasol" target="_blank" rel="noopener">`pyexasol`</a> module.

    ## Prerequisites

    Prior to using this notebook the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).

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
    ## Create UDF
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='import textwrap\nfrom exakit.nb.example_runtime import open_pyexasol_connection\nfrom stopwatch import Stopwatch\n\nstopwatch = Stopwatch()\n\n# Create script to test the model\nsql = textwrap.dedent("""\\\nCREATE OR REPLACE PYTHON3_ML SET SCRIPT\n{schema!q}.SKLEARN_PREDICT(...)\nEMITS(...) AS\n\n# Generic scikit-learn predictor that runs a prediction for a data batch.\n# Loads a scikit-learn model or a pipeline from the specified file. Calls its `predict` method\n# passing to it all provided data columns. Emits sample IDs and the output of the model.\n#\n# Note that the model should not include features\' names!\n# \n# Input columns:\n#    [0]:  Full BucketFS path to the model file;\n#    [1]:  Sample ID, can be the ROWID of the test batch.\n#    [2+]: Feature columns.\n#\n# Output columns:\n#    [0]:  Sample ID copied from the input.\n#    [1+]: Model output.\n\nimport pickle\nimport pandas as pd\n\ndef run(ctx):\n    # Load model from EXABucket\n    with open(ctx[0], \'rb\') as f:\n        model = pickle.load(f)\n\n    # Stream the data through the model to reduce the required main memory of the UDF.\n    # This allows running the UDF on larger datasets.\n    while True:\n        # Read the input skipping the first column which holds the model path.\n        X_pred = ctx.get_dataframe(num_rows=1000, start_col=1)\n        if X_pred is None:\n            break\n\n        # Call the model to get the predictions. Omit the first column in the input\n        # which holds the sample IDs.\n        df_features = X_pred.drop(X_pred.columns[0], axis=1)\n        y_pred = model.predict(df_features.values)\n\n        # Combine predictions with the sample IDs.\n        df_rowid = X_pred[X_pred.columns[0]].reset_index(drop=True)\n        df_pred = pd.concat((df_rowid, pd.DataFrame(y_pred)), axis=1)\n\n        # Output data\n        ctx.emit(df_pred)\n/\n""")\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.execute(query=sql, query_params={\'schema\': ai_lab_config.db_schema})\n\nprint(f"Creating prediction script took: {stopwatch}")', language="python", min_height=100)
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
