import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('data/data_abalone.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Abalone

    Downloads the tutorial dataset when you run the loader. Tutorial tables are kept in EXAKIT_EXAMPLES, separately from the persona datasets.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/data/data_abalone.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'data/data_abalone.ipynb')", language="python", min_height=100)
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

    # Abalone

    Here we will load data of physical measurements of abalones (sea snails). <a href="https://archive.ics.uci.edu/dataset/1/abalone" target="_blank" rel="noopener">Follow this link</a> to get details about this dataset.

    To execute queries and upload data to Exasol database we will be using the <a href="https://github.com/exasol/pyexasol" target="_blank" rel="noopener">`pyexasol`</a> module.

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
    ## Download data

    First, we will load the data into Pandas DataFrame. Each data column represents one of the features and is named accordingly, see section Variable Table in the dataset description. We will name the Pandas columns as per the variable description.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from urllib.request import urlopen\nimport tempfile\nfrom zipfile import ZipFile\nfrom contextlib import ExitStack\nimport pandas as pd\nfrom stopwatch import Stopwatch\n\nstopwatch = Stopwatch()\n\nDATA_URL = "https://archive.ics.uci.edu/static/public/1/abalone.zip"\nDATA_FILE = "abalone.data"\n\nresp = urlopen(DATA_URL)\nwith ExitStack() as stack:\n    f = stack.enter_context(tempfile.TemporaryFile())\n    f.write(resp.read())\n    print(f"Downloading the data took: {stopwatch}")\n\n    f.seek(0)\n    z = stack.enter_context(ZipFile(f))\n    f = stack.enter_context(z.open(DATA_FILE, "r"))\n    df = pd.read_csv(f)\n\ncolumn_def = [\n    (\'Sex\', \'CHAR(1)\'),\t                 # M, F, and I (infant)\n    (\'Length\', \'DECIMAL(4,3)\'),          # longest shell measurement (mm)\n    (\'Diameter\', \'DECIMAL(4,3)\'),\t     # perpendicular to length (mm)\n    (\'Height\', \'DECIMAL(4,3)\'),          # with meat in shell (mm)\n    (\'Whole_weight\', \'DECIMAL(5,4)\'),    # whole abalone (grams)\n    (\'Shucked_weight\', \'DECIMAL(5,4)\'),  # weight of meat (grams)\n    (\'Viscera_weight\', \'DECIMAL(5,4)\'),  # gut weight (after bleeding) (grams)\n    (\'Shell_weight\', \'DECIMAL(4,3)\'),    # after being dried (grams)\n    (\'Rings\', \'INT\')                     # +1.5 gives the age in years\n]\ndf.columns = [name for name, _ in column_def]\n\nprint(df.head())', language="python", min_height=100)
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
    ## Upload data into DB

    Let's split data randomly into train and test sets. We will then create two tables - ABALONE_TRAIN and ABALONE_TEST - and load the datasets into these tables.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='from sklearn.model_selection import train_test_split\nfrom exakit.nb.example_runtime import open_pyexasol_connection\n\n# Split the data into train and test sets\ndf_train, df_test = train_test_split(df, test_size=0.2)\n\ntrain_table = \'ABALONE_TRAIN\'\ntest_table = \'ABALONE_TEST\'\ncolumn_desc = [\' \'.join(c) for c in column_def]\n\nstopwatch = Stopwatch()\n\n# Create an Exasol connection\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    # Create tables\n    sql = f\'CREATE OR REPLACE TABLE "{ai_lab_config.db_schema}"."{train_table}"({", ".join(column_desc)})\'\n    conn.execute(query=sql)\n    sql = f\'CREATE OR REPLACE TABLE "{ai_lab_config.db_schema}"."{test_table}" LIKE "{ai_lab_config.db_schema}"."{train_table}"\'\n    conn.execute(query=sql)\n\n    # Import data into Exasol\n    conn.import_from_pandas(df_train, (ai_lab_config.db_schema, train_table))\n    print(f"Imported {conn.last_statement().rowcount()} rows into {train_table}.")\n    conn.import_from_pandas(df_test, (ai_lab_config.db_schema, test_table))\n    print(f"Imported {conn.last_statement().rowcount()} rows into {test_table}.")\n\nprint(f"Importing the data took: {stopwatch}")', language="python", min_height=100)
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
