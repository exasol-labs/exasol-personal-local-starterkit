import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('cloud/01_import_data.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Importing data from cloud storage

    Reference only: cloud storage and virtual-schema integration belong to separate work. These cells are not enabled by the local kit.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/cloud/01_import_data.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'cloud/01_import_data.ipynb')", language="python", min_height=100)
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

    # Importing data from cloud storage

    In this notebook we'll use [cloud-storage-extension](https://github.com/exasol/cloud-storage-extension/) to import publicly available data from AWS S3 into the Exasol database.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Prerequisites

    Before importing the data we need to configure the database, by setting up cloud-storage-extension jar files and UDF scripts used for the import. This needs to be done once for the database.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
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
    ### Setup of cloud-storage-extension

    Before running the setup, you need to perform the "Main configuration" in [main_config.ipynb](/?file=exasol-examples/main_config.py)
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='%run ./cloud_store_config.ipynb', language="python", min_height=100)
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
    # Importing data from parquet files

    For the beginning, we'll load small volume of data from publicly available [Ookla Network Performance Maps](https://registry.opendata.aws/speedtest-global-performance/), which contains aggregated network performance measurements from speedtest.net website.

    In this example, we'll import only the subset of dataset - only mobile users for Q1 of 2019. In total there are 3M rows stored in parquet file on public S3 bucket: s3://ookla-open-data/parquet/performance/type=mobile/year=2019/quarter=1/2019-01-01_performance_mobile_tiles.parquet
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='import pyexasol\nfrom exakit.nb.example_runtime import open_pyexasol_connection', language="python", min_height=100)
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
    ## Schema and target table

    As a first step, we need to obtain the schema of the data (set of columns stored in parquet files with their types). You might have this information in advance (if this is your dataset), but if not, you need to analyze parquet files to figure out their schema.

    One of the options of doing this is the parquet-tools library wrapped into a [docker container](https://hub.docker.com/r/nathanhowell/parquet-tools). To use it, you need to download one of parquet files locally, then run this docker container against this file. Using the same container, you can also peek into parquet files and looks at its actual data.

    For the file above, I got the following schema information:

    ```
    message schema {
      optional binary quadkey (STRING);
      optional binary tile (STRING);
      optional int64 avg_d_kbps;
      optional int64 avg_u_kbps;
      optional int64 avg_lat_ms;
      optional int64 tests;
      optional int64 devices;
    }
    ```  

    From this schema we see that we have two types of columns in the parquet file - strings and integers.
    Let's create the table in our database for this data. The names of columns are not important, just the order and their types have to match with parquet file schema.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='TABLE_NAME = "OOKLA_MAP"\n\nsql = """\ncreate or replace table {schema_name!i}.{table_name!i} \n(\n    quadkey     VARCHAR2(1024),\n    tile        VARCHAR2(1024),\n    avg_d_kbps  BIGINT,\n    avg_u_kbps  BIGINT,\n    avg_lat_ms  BIGINT,\n    tests       BIGINT,\n    devices     BIGINT\n)\n"""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    conn.execute(sql, query_params={\n        "schema_name": ai_lab_config.db_schema,\n        "table_name": TABLE_NAME\n    })', language="python", min_height=100)
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
    ## S3 credentials

    If S3 bucket is public, we can pass empty access key and secret keys. Otherwise replace with valid credentials.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='sql = """\nCREATE OR REPLACE CONNECTION S3_CONNECTION TO \'\' USER \'\' \nIDENTIFIED BY \'S3_ACCESS_KEY={access_key!r};S3_SECRET_KEY={secret_key!r}\';\n"""\n\nS3_ACCESS_KEY = ""\nS3_SECRET_KEY = ""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    conn.execute(sql, query_params={\n        "schema": ai_lab_config.db_schema,\n        "access_key": S3_ACCESS_KEY,\n        "secret_key": S3_SECRET_KEY,\n    })', language="python", min_height=100)
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
    ## Importing data

    Now it's time to import our data. We call the `IMPORT_PATH` script, providing the location of parquet files, their format, the s3 endpoint (which has to match the bucket's configuration) and the name of our connection object.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='params = {\n    "schema": ai_lab_config.db_schema,\n    "table": TABLE_NAME,  \n}\n\nsql = """\nIMPORT INTO {schema!i}.{table!i}\nFROM SCRIPT {schema!i}.IMPORT_PATH WITH\n    BUCKET_PATH = \'s3a://ookla-open-data/parquet/performance/type=mobile/year=2019/quarter=1/*\'\n    DATA_FORMAT = \'PARQUET\'\n    S3_ENDPOINT = \'s3-us-west-2.amazonaws.com\'\n    CONNECTION_NAME = \'S3_CONNECTION\';\n"""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    conn.execute(sql, query_params=params)', language="python", min_height=100)
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
    Let's check that data was imported by the process above
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config) as conn:\n    data_rows = conn.execute("select count(*) from {schema!i}.{table!i}", query_params=params)\n    count = next(data_rows)[0] \n    print(f"Loaded {count} rows")\n    data = conn.execute("select * from {schema!i}.{table!i} limit 1", query_params=params)\n    for row in data:\n        print(row)', language="python", min_height=100)
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
