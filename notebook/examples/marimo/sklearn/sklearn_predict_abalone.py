import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('sklearn/sklearn_predict_abalone.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Predicting with Regression Model

    Load the matching Abalone or Telescope data notebook first. Prediction requires udf-devkit and the PYTHON3_ML runtime. Models use the local file bucket.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/sklearn/sklearn_predict_abalone.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'sklearn/sklearn_predict_abalone.ipynb')", language="python", min_height=100)
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

    # Predicting with Regression Model

    In this notebook, we will use a <a href="https://scikit-learn.org/stable/" target="_blank" rel="noopener">`scikit-learn`</a> model created earlier to predict the age of an abalone from its physical measurements and sex. You can find more information about the problem domain <a href="https://archive.ics.uci.edu/dataset/1/abalone" target="_blank" rel="noopener">here</a>.

    We will be using a generic prediction UDF script. To execute queries and load data from the Exasol database we will be using the <a href="https://github.com/exasol/pyexasol" target="_blank" rel="noopener">`pyexasol`</a> module.

    ## Prerequisites

    Prior to using this notebook the following steps need to be completed:
    1. [Create generic scikit-learn prediction UDF script](/?file=exasol-examples/sklearn/sklearn_predict_udf.py).
    2. [Train a model on the Abalone dataset](/?file=exasol-examples/sklearn/sklearn_train_abalone.py).

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
    ## Run predictions

    Let's make predictions on the data we have in table `ABALONE_TEST`. This table also includes a column with ground truth labels. We will use it to assess the performance of our predictor. In the code below we will add the ROWID to the output columns (as required by the generic prediction UDF). This will allow us to link the result to the ground truth.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection, get_udf_bucket_path\nfrom stopwatch import Stopwatch\n\ntarget_column = \'RINGS\'\nbfs_model_path = get_udf_bucket_path(ai_lab_config) + \'/abalone_svm_model.pkl\'\nparams = {\'schema\': ai_lab_config.db_schema, \'test_table\': \'ABALONE_TEST\', \'model_path\': bfs_model_path}\n\nstopwatch = Stopwatch()\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    # Get the list of feature columns\n    sql = \'SELECT * FROM {schema!q}.{test_table!q} LIMIT 1\'\n    df_tmp = conn.export_to_pandas(query_or_table=sql, query_params=params)\n    params[\'column_names\'] = [f\'[{c}]\' for c in df_tmp.columns if c != target_column]\n\n    # Get the predictions for all rows in the TEST table calling the prediction UDF.\n    # Provide the model path and the row ID in the first two parameters.\n    sql = f\'SELECT {{schema!q}}.SKLEARN_PREDICT({{model_path!s}}, ROWID, {{column_names!r}}) \' \\\n        f\'emits ([sample_id] DECIMAL(20,0), [{target_column}] DOUBLE) FROM {{schema!q}}.{{test_table!q}}\'\n    df_pred = conn.export_to_pandas(query_or_table=sql, query_params=params)\n\nprint(f"Getting predictions took: {stopwatch}")\ndf_pred.head()', language="python", min_height=100)
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
    ## Evaluate predictions

    We are going to check the performance of our predictor by linking the results to the ground truth labels and computing some regression metrics. This should give us similar results to what we have seen in the [training notebook](/?file=exasol-examples/sklearn/sklearn_train_abalone.py).
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value="import pandas as pd\nfrom sklearn.metrics import explained_variance_score, mean_absolute_error, mean_squared_error\nimport matplotlib.pyplot as plt\n\n# Get the ground truth labels for the test set.\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    sql = f'SELECT ROWID AS [sample_id], [{target_column}] FROM {{schema!q}}.{{test_table!q}}'\n    df_true = conn.export_to_pandas(query_or_table=sql, query_params=params)\n\n# Merge predictions and the ground truth on the sample ID.\ndf_res = pd.merge(left=df_true, right=df_pred, on='sample_id', suffixes=['_true', '_pred'])\n\nprint('Mean absolute error:', mean_absolute_error(df_res[f'{target_column}_true'], df_res[f'{target_column}_pred']))\nprint('Mean squared error:', mean_squared_error(df_res[f'{target_column}_true'], df_res[f'{target_column}_pred']))\nprint('Explained variance:', explained_variance_score(df_res[f'{target_column}_true'], df_res[f'{target_column}_pred']))", language="python", min_height=100)
    run_004 = mo.ui.run_button(label="Run cell 4")
    mo.vstack([editor_004, run_004])
    return editor_004, run_004

@app.cell
def _(editor_004, lesson, mo, render, run_004):
    mo.stop(not run_004.value)
    render(mo, lesson.run(editor_004.value))
    return

if __name__ == "__main__":
    app.run()
