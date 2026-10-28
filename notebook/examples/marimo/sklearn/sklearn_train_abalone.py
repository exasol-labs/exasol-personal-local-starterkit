import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('sklearn/sklearn_train_abalone.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Training Regression Model

    Load the matching Abalone or Telescope data notebook first. Prediction requires udf-devkit and the PYTHON3_ML runtime. Models use the local file bucket.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/sklearn/sklearn_train_abalone.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'sklearn/sklearn_train_abalone.ipynb')", language="python", min_height=100)
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

    # Training Regression Model

    In this notebook, we will train a simple regression model for predicting the age of an abalone from its physical measurements and sex.You can find more information about the problem domain <a href="https://archive.ics.uci.edu/dataset/1/abalone" target="_blank" rel="noopener">here</a>.

    We will train the model in this notebook using <a href="https://scikit-learn.org/stable/" target="_blank" rel="noopener">`scikit-learn`</a>, on the training data we are going to export from the database.

    To execute queries and load data from the Exasol database we will be using the <a href="https://github.com/exasol/pyexasol" target="_blank" rel="noopener">`pyexasol`</a> module.

    ## Prerequisites

    Prior to using this notebook the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).
    2. [Load the Abalone data](/?file=exasol-examples/data/data_abalone.py).

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
    ## Load data

    First, we will export data into a pandas DataFrame and split it into training and validation sets.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\nfrom sklearn.model_selection import train_test_split\nfrom stopwatch import Stopwatch\n\nstopwatch = Stopwatch()\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    df = conn.export_to_pandas(query_or_table=(ai_lab_config.db_schema, \'ABALONE_TRAIN\'))\n\nX, y = df.drop(columns=\'RINGS\'), df[\'RINGS\']\nX_train, X_valid, y_train, y_valid = train_test_split(X, y, test_size=0.2)\n\nprint(f"Loading the data took: {stopwatch}")', language="python", min_height=100)
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
    ## Analyze data

    Let's look at the features. We will first check what physical measurements have predictive power. For that, we will compute mutual information between the measurements' input columns and the target.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value="from sklearn.feature_selection import mutual_info_regression\n\nX_meas = X_train.drop(columns='SEX')\nmi = mutual_info_regression(X_meas, y_train)\ndict(zip(X_meas.columns, mi))", language="python", min_height=100)
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
    Now let's see if SEX is a good predictor. We will do the ANOVA test and print the p-value.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value="from sklearn.feature_selection import f_classif\n\nf_classif(y_train.to_frame(), X_train['SEX'])[1][0]", language="python", min_height=100)
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
    ## Train model

    Let's make a pipeline. We will use all features in the input. We will do One Hot Encoding of the SEX column and normalize all others, including the target. Let's use the Support Vector Machine as the regression model. We will drop the column names in the inputs, as they will not be available in the prediction UDF.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='from sklearn.preprocessing import OneHotEncoder, StandardScaler\nfrom sklearn.compose import ColumnTransformer, TransformedTargetRegressor\nfrom sklearn.pipeline import Pipeline\nfrom sklearn.svm import SVR\n\n# Create the pipeline.\npreprocessor = ColumnTransformer(\n    transformers=[\n        ("num", StandardScaler(), [1, 2, 3, 4, 5, 6, 7]),\n        ("cat", OneHotEncoder(), [0]),\n    ]\n)\nregressor = SVR(kernel=\'rbf\')\nmodel = Pipeline(\n    steps=[("preprocessor", preprocessor), (\'regressor\', regressor)]\n)\nmodel = TransformedTargetRegressor(regressor=model, transformer=StandardScaler())\n\nstopwatch = Stopwatch()\n\n# Train the model.\nmodel.fit(X_train.values, y_train.values)\n\nprint(f"Training of the model took: {stopwatch}")', language="python", min_height=100)
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
    ## Evaluate model

    Let's see what prediction performance we've got, printing some regression metrics.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value="from sklearn.metrics import explained_variance_score, mean_absolute_error, mean_squared_error\n\ny_pred = model.predict(X_valid.values)\n\nprint('Mean absolute error:', mean_absolute_error(y_valid, y_pred))\nprint('Mean squared error:', mean_squared_error(y_valid, y_pred))\nprint('Explained variance:', explained_variance_score(y_valid, y_pred))", language="python", min_height=100)
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
    ### Make sure scikit-learn versions match

    We need to make sure the scikit-learn version 
    of the training and the SLC are compatible. 

    If this next call results in an error indicating a version missmatch, you can resolve it using [the version fix notebook](/?file=exasol-examples/sklearn/sklearn_fix_version.py).
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='from exakit.nb.example_runtime import sklearn_version_check\n\nsklearn_version_check(ai_lab_config)', language="python", min_height=100)
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
    ## Upload model into BucketFS

    Now, let's upload the model into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm) so that it can be used for making predictions in SQL queries. To communicate with BucketFS we will be using the <a href="https://exasol.github.io/bucketfs-python/" target="_blank" rel="noopener">`bucketfs-python`</a> module.
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='import pickle\nfrom exakit.nb.example_runtime import open_bucketfs_connection\n\nMODEL_FILE = \'abalone_svm_model.pkl\'\n\nstopwatch = Stopwatch()\n\n# Connect to the BucketFS service\nbucket = open_bucketfs_connection(ai_lab_config)\n\n# Serialize the model into a byte-array and upload it to the BucketFS, \n# where it will be saved in the file with the specified name.\nbucket.upload(MODEL_FILE, pickle.dumps(model))\n\nprint(f"Uploading the model took: {stopwatch}")', language="python", min_height=100)
    run_009 = mo.ui.run_button(label="Run cell 9")
    mo.vstack([editor_009, run_009])
    return editor_009, run_009

@app.cell
def _(editor_009, lesson, mo, render, run_009):
    mo.stop(not run_009.value)
    render(mo, lesson.run(editor_009.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Now we are ready to use this model in our SQL queries. This will be demonstrated in the [following notebook](/?file=exasol-examples/sklearn/sklearn_predict_abalone.py)
    """)
    return

if __name__ == "__main__":
    app.run()
