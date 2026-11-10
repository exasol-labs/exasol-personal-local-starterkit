import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('first_steps.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: First Steps

    Uses the kit encrypted connection. Database examples use EXAKIT_EXAMPLES. Later sections may need tutorial downloads or the ML UDF add-on.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/first_steps.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'first_steps.ipynb')", language="python", min_height=100)
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
    # First Steps

    This notebook guides you through the first steps using Jupyter notebooks with Exasol.

    The notebook demonstrates connecting to an Exasol database instance and using some of its features. 

    ## 1. Open Secure Configuration Storage

    First we need to open the Secure Configuration Storage (SCS) containing the connection information such as the database host, user, password, etc.
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
    ## 2. Using JupySQL with Exasol AI Lab

    Next, we will activate the [JupySQL](https://github.com/ploomber/jupysql) magics:
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
    JupySQL allows you to run SQL and plot large datasets in Jupyter via a %sql, %%sql, and %sqlplot magics. Using these magics, you can enter SQL directly into notebook cells.
    In the background JupySQL uses SQLAlchemy, see also the [demo section on SQLAlchemy](./first_steps.ipynb/#4.-Using-SQLAlchemy-with-Exasol-AI-Lab) below.

    ### 2.1 Create Database Tables

    We will use JupySQL to create 2 database tables but other sections will use the tables, too:
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='%%sql\nCREATE OR REPLACE TABLE US_AIRLINES (\n  OP_CARRIER_AIRLINE_ID DECIMAL(10, 0) IDENTITY PRIMARY KEY,\n  CARRIER_NAME VARCHAR(1000)\n)', language="python", min_height=100)
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
    editor_005 = mo.ui.code_editor(value='%%sql\nCREATE OR REPLACE TABLE US_FLIGHTS (\n  FL_DATE TIMESTAMP, \n  OP_CARRIER_AIRLINE_ID DECIMAL(10, 0),\n  ORIGIN_AIRPORT_SEQ_ID DECIMAL(10, 0),\n  ORIGIN_STATE_ABR CHAR(2),\n  DEST_AIRPORT_SEQ_ID DECIMAL(10, 0),\n  DEST_STATE_ABR CHAR(2),\n  CRS_DEP_TIME CHAR(4),\n  DEP_DELAY DOUBLE, \n  CRS_ARR_TIME CHAR(4),\n  ARR_DELAY DOUBLE,\n  CANCELLED BOOLEAN,\n  CANCELLATION_CODE CHAR(1),\n  DIVERTED BOOLEAN,\n  CRS_ELAPSED_TIME DOUBLE,\n  ACTUAL_ELAPSED_TIME DOUBLE, \n  DISTANCE DOUBLE,\n  CARRIER_DELAY DOUBLE,\n  WEATHER_DELAY DOUBLE,\n  NAS_DELAY DOUBLE,\n  SECURITY_DELAY DOUBLE,\n  LATE_AIRCRAFT_DELAY DOUBLE\n)', language="python", min_height=100)
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
    ### 2.2 Importing CSV Files from Remote

    This section demonstrates how to import CSV files from a remote source into the database.

    First we will import a list of **US airlines**. The data is publicly accessible at the [Bureau of Transportation Statistics](https://www.transtats.bts.gov/Homepage.asp) of the US Department of Transportation.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='%%sql\nIMPORT INTO US_AIRLINES FROM\n    CSV AT \'https://dut5tonqye28.cloudfront.net/ai_lab/flight-info/\' \n    FILE \'US_AIRLINES.csv\' \n    COLUMN SEPARATOR = \',\' \n    ROW SEPARATOR = \'CRLF\'\n    COLUMN DELIMITER = \'"\' \n    SKIP = 1', language="python", min_height=100)
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
    Next, we will import data about **flights** in February 2024:
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value="%%sql\nIMPORT INTO US_FLIGHTS \n    FROM CSV AT 'https://dut5tonqye28.cloudfront.net/ai_lab/first_steps/' \n    FILE 'US_FLIGHTS_FEB_2024-fixed-booleans.csv'\n    (1 FORMAT = 'MM/DD/YYYY HH12:MI:SS AM', 2..21)    \n    SKIP = 1", language="python", min_height=100)
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
    Let's find out which is the airline with the highest delay per flight:
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='%%sql\nSELECT\n  CARRIER_NAME "Airline",\n  SUM(CARRIER_DELAY) "Combined Delay",\n  COUNT(CARRIER_DELAY) "Delayed Flights",\n  COUNT(F.OP_CARRIER_AIRLINE_ID) "Total flights",\n  ROUND( SUM(CARRIER_DELAY) / COUNT(F.OP_CARRIER_AIRLINE_ID), 1 ) "Delay per flight"\nFROM US_FLIGHTS F\n  JOIN US_AIRLINES A ON A.OP_CARRIER_AIRLINE_ID = F.OP_CARRIER_AIRLINE_ID\nWHERE NOT (CANCELLED OR DIVERTED)\nGROUP BY CARRIER_NAME\nORDER BY "Delay per flight" DESC', language="python", min_height=100)
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
    ### 2.3 Importing a Parquet File from an AWS S3 Bucket

    This demo uses a file already uploaded to S3 bucket `ai-lab-example-data-s3`.

    First we will define a connection pointing to the S3 bucket:
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value="%%sql\nCREATE OR REPLACE CONNECTION AI_LAB_FIRST_STEPS_S3 \n    TO 'https://ai-lab-example-data-s3.s3.eu-central-1.amazonaws.com'", language="python", min_height=100)
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
    Alternatively the connection can also use the following URL syntax, see also "_Load data from Parquet files_" on [docs.exasol.com](https://docs.exasol.com/db/latest/loading_data/load_data_parquet.htm#Overview):
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value="%%sql\nCREATE OR REPLACE CONNECTION AI_LAB_FIRST_STEPS_S3 \n    TO 's3://ai-lab-example-data-s3'", language="python", min_height=100)
    run_010 = mo.ui.run_button(label="Run cell 10")
    mo.vstack([editor_010, run_010])
    return editor_010, run_010

@app.cell
def _(editor_010, lesson, mo, render, run_010):
    mo.stop(not run_010.value)
    render(mo, lesson.run(editor_010.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Then we will remove the data imported before:
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='%%sql\nTRUNCATE TABLE US_FLIGHTS', language="python", min_height=100)
    run_011 = mo.ui.run_button(label="Run cell 11")
    mo.vstack([editor_011, run_011])
    return editor_011, run_011

@app.cell
def _(editor_011, lesson, mo, render, run_011):
    mo.stop(not run_011.value)
    render(mo, lesson.run(editor_011.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    **Please note**: Parquet import via SQL statement `IMPORT` requires using **<span style="color: #40a">Exasol version 2025.\\* or higher</span>**, see [docs.exasol.com](https://docs.exasol.com/db/latest/loading_data/load_data_parquet.htm).

    Now we can import the Parquet file from S3 into the database:
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value="%%sql\n\nIMPORT INTO US_FLIGHTS FROM PARQUET AT AI_LAB_FIRST_STEPS_S3 \n    FILE 'first_steps/US_FLIGHTS_FEB_2024.parquet'", language="python", min_height=100)
    run_012 = mo.ui.run_button(label="Run cell 12")
    mo.vstack([editor_012, run_012])
    return editor_012, run_012

@app.cell
def _(editor_012, lesson, mo, render, run_012):
    mo.stop(not run_012.value)
    render(mo, lesson.run(editor_012.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    We will query table `US_FLIGHTS` again to display the imported data:
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='%%sql\nSELECT * FROM US_FLIGHTS', language="python", min_height=100)
    run_013 = mo.ui.run_button(label="Run cell 13")
    mo.vstack([editor_013, run_013])
    return editor_013, run_013

@app.cell
def _(editor_013, lesson, mo, render, run_013):
    mo.stop(not run_013.value)
    render(mo, lesson.run(editor_013.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## 3. Using PyExasol with Exasol AI Lab

    [PyExasol](https://exasol.github.io/pyexasol/master/index.html) is the basic Python connector for interacting with Exasol databases.

    ### 3.1 Importing a CSV File from the Local Filesystem

    This section demonstrates how to import a CSV file from the local file system into the database using Pyexasol.

    The function `open_pyexasol_connection()` opens a connection, using the configuration from the SCS.
    """)
    return

@app.cell
def _(mo):
    editor_014 = mo.ui.code_editor(value='from pathlib import Path\nfrom exakit.nb.example_runtime import open_pyexasol_connection\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    path = Path("first_steps/pyexasol.csv")\n    import_params = {\n        "column_delimiter": \'"\',\n        "column_separator": ",",\n        "row_separator": "CRLF",\n        "skip": 1,\n    }\n    conn.import_from_file(path, (ai_lab_config.db_schema, "US_AIRLINES"), import_params)', language="python", min_height=100)
    run_014 = mo.ui.run_button(label="Run cell 14")
    mo.vstack([editor_014, run_014])
    return editor_014, run_014

@app.cell
def _(editor_014, lesson, mo, render, run_014):
    mo.stop(not run_014.value)
    render(mo, lesson.run(editor_014.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    We will also verify the success by using a query with separate parameters and [PyExasol SQL formatting](https://exasol.github.io/pyexasol/master/user_guide/exploring_features/formatting_sql.html):
    """)
    return

@app.cell
def _(mo):
    editor_015 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\n\nquery = "SELECT * FROM {table!q} WHERE CARRIER_NAME LIKE {pattern!s}"\nparams = {\n    "table": (ai_lab_config.db_schema, "US_AIRLINES"),\n    "pattern": "% local CSV file via pyexasol",\n}\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    result = conn.execute(query, params).fetchone()\nprint(result)', language="python", min_height=100)
    run_015 = mo.ui.run_button(label="Run cell 15")
    mo.vstack([editor_015, run_015])
    return editor_015, run_015

@app.cell
def _(editor_015, lesson, mo, render, run_015):
    mo.stop(not run_015.value)
    render(mo, lesson.run(editor_015.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### 3.2 Importing a CSV File from Remote

    This section demonstrates how to import a CSV file from a remote source into the database using PyExasol.

    First, we will truncate table `US_FLIGHTS` to be able to import the flight data again:
    """)
    return

@app.cell
def _(mo):
    editor_016 = mo.ui.code_editor(value='%%sql\nTRUNCATE TABLE US_FLIGHTS', language="python", min_height=100)
    run_016 = mo.ui.run_button(label="Run cell 16")
    mo.vstack([editor_016, run_016])
    return editor_016, run_016

@app.cell
def _(editor_016, lesson, mo, render, run_016):
    mo.stop(not run_016.value)
    render(mo, lesson.run(editor_016.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Now let's run the import&mdash;again using a query with separate parameter and PyExasol SQL formatting:
    """)
    return

@app.cell
def _(mo):
    editor_017 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\n\nquery = """\n    IMPORT INTO {flights_table!q} FROM CSV AT {url!s} FILE {file!s}\n    (1 FORMAT = {date_format!s}, 2..21) \n    SKIP = 1\n"""\n\nparams = {\n    "flights_table": (ai_lab_config.db_schema, "US_FLIGHTS"),\n    "url": "https://dut5tonqye28.cloudfront.net/ai_lab/first_steps/",\n    "file": "US_FLIGHTS_FEB_2024-fixed-booleans.csv",\n    "date_format": "MM/DD/YYYY HH12:MI:SS AM",\n}\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    result = conn.execute(query, params)\n\nprint(f"Imported {result.rowcount()} rows.")', language="python", min_height=100)
    run_017 = mo.ui.run_button(label="Run cell 17")
    mo.vstack([editor_017, run_017])
    return editor_017, run_017

@app.cell
def _(editor_017, lesson, mo, render, run_017):
    mo.stop(not run_017.value)
    render(mo, lesson.run(editor_017.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### 3.3 Importing a Parquet File from an AWS S3 Bucket

    This demo uses 
    * a file already uploaded to S3 bucket `ai-lab-example-data-s3` 
    * and the Exasol connection object `AI_LAB_FIRST_STEPS_S3` created before.

    First we will truncate table `US_FLIGHTS`:
    """)
    return

@app.cell
def _(mo):
    editor_018 = mo.ui.code_editor(value='%%sql\nTRUNCATE TABLE US_FLIGHTS', language="python", min_height=100)
    run_018 = mo.ui.run_button(label="Run cell 18")
    mo.vstack([editor_018, run_018])
    return editor_018, run_018

@app.cell
def _(editor_018, lesson, mo, render, run_018):
    mo.stop(not run_018.value)
    render(mo, lesson.run(editor_018.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    **Please note**: 
    * Parquet import via SQL statement `IMPORT` requires using **<span style="color: #40a">Exasol version 2025.\\* or higher</span>**, see [docs.exasol.com](https://docs.exasol.com/db/latest/loading_data/load_data_parquet.htm).
    * This restriction does not apply when using PyExasol's native function [import_from_parquet()](https://exasol.github.io/pyexasol/master/user_guide/exploring_features/import_and_export/index.html#id8).

    Now we can import the Parquet file from S3 into the database:
    """)
    return

@app.cell
def _(mo):
    editor_019 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\n\nquery = "IMPORT INTO {table!q} FROM PARQUET AT {connection!r} FILE {file!s}"\n\nparams = {\n    "table": (ai_lab_config.db_schema, "US_FLIGHTS"),\n    "connection": "AI_LAB_FIRST_STEPS_S3",\n    "file": "first_steps/US_FLIGHTS_FEB_2024.parquet",\n}\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    result = conn.execute(query, params)\nprint(f"Imported {result.rowcount()} rows.")', language="python", min_height=100)
    run_019 = mo.ui.run_button(label="Run cell 19")
    mo.vstack([editor_019, run_019])
    return editor_019, run_019

@app.cell
def _(editor_019, lesson, mo, render, run_019):
    mo.stop(not run_019.value)
    render(mo, lesson.run(editor_019.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## 4. Using SQLAlchemy with Exasol AI Lab

    [SQLAlchemy](https://www.sqlalchemy.org/) is a Python SQL Toolkit and Object Relational Mapper for application developers.
                                                               
    It provides a full suite of well known enterprise-level persistence patterns, designed for efficient and high-performing database access, adapted into a simple and Pythonic domain language.

    In Exasol AI Lab, the function `open_sqlalchemy_connection()` returns a SQLAlchemy engine, again using the configuration from the SCS.

    This engine will be used by the examples based on SQLAlchemy.
    """)
    return

@app.cell
def _(mo):
    editor_020 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_sqlalchemy_connection\nengine = open_sqlalchemy_connection(ai_lab_config)', language="python", min_height=100)
    run_020 = mo.ui.run_button(label="Run cell 20")
    mo.vstack([editor_020, run_020])
    return editor_020, run_020

@app.cell
def _(editor_020, lesson, mo, render, run_020):
    mo.stop(not run_020.value)
    render(mo, lesson.run(editor_020.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### 4.1 Importing a CSV File from Remote

    This section demonstrates how to import a CSV file from a remote source into the database using SQLAlchemy.

    We will once again truncate table `US_FLIGHTS` and import the flight data, now using SQLAlchemy:
    """)
    return

@app.cell
def _(mo):
    editor_021 = mo.ui.code_editor(value='from sqlalchemy import text\n\nt = (\n    text(\n        f"""\n        IMPORT INTO "{ai_lab_config.db_schema}"."US_FLIGHTS" \n        FROM CSV AT \'https://dut5tonqye28.cloudfront.net/ai_lab/first_steps/\' \n        FILE \'US_FLIGHTS_FEB_2024-fixed-booleans.csv\'\n        (1 FORMAT = \'MM/DD/YYYY HH12:MI:SS AM\', 2..21) \n        SKIP = 1\n        """\n    )\n)\nwith engine.connect() as conn:\n    conn.execute(text("TRUNCATE TABLE US_FLIGHTS"))\n    result = conn.execute(t)\n\nprint(f"Imported {result.rowcount} rows.")', language="python", min_height=100)
    run_021 = mo.ui.run_button(label="Run cell 21")
    mo.vstack([editor_021, run_021])
    return editor_021, run_021

@app.cell
def _(editor_021, lesson, mo, render, run_021):
    mo.stop(not run_021.value)
    render(mo, lesson.run(editor_021.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### 4.2 Importing a Parquet File from an AWS S3 Bucket

    This section demonstrates how to import a Parquet file from an AWS S3 Bucket into the database using SQLAlchemy.

    First we will truncate table `US_FLIGHTS` again:
    """)
    return

@app.cell
def _(mo):
    editor_022 = mo.ui.code_editor(value='%%sql\nTRUNCATE TABLE US_FLIGHTS', language="python", min_height=100)
    run_022 = mo.ui.run_button(label="Run cell 22")
    mo.vstack([editor_022, run_022])
    return editor_022, run_022

@app.cell
def _(editor_022, lesson, mo, render, run_022):
    mo.stop(not run_022.value)
    render(mo, lesson.run(editor_022.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    **Please note**: Parquet import via SQL statement `IMPORT` requires using **<span style="color: #40a">Exasol version 2025.\\* or higher</span>**, see [docs.exasol.com](https://docs.exasol.com/db/latest/loading_data/load_data_parquet.htm).

    Now we can import the Parquet file from S3 into the database:
    """)
    return

@app.cell
def _(mo):
    editor_023 = mo.ui.code_editor(value='from sqlalchemy import text\n\nt = (\n    text(\n        f"""\n        IMPORT INTO "{ai_lab_config.db_schema}"."US_FLIGHTS" \n        FROM PARQUET AT AI_LAB_FIRST_STEPS_S3\n        FILE \'first_steps/US_FLIGHTS_FEB_2024.parquet\'\n        """\n    )\n)\n\nwith engine.connect() as conn:\n    result = conn.execute(t)\nprint(f"Imported {result.rowcount} rows.")', language="python", min_height=100)
    run_023 = mo.ui.run_button(label="Run cell 23")
    mo.vstack([editor_023, run_023])
    return editor_023, run_023

@app.cell
def _(editor_023, lesson, mo, render, run_023):
    mo.stop(not run_023.value)
    render(mo, lesson.run(editor_023.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### 4.3 Querying using SQLAlchemy’s Metadata Concept

    This section demonstrates using some SQLAlchemy features 
    * Instantiating class [sqlalchemy.MetaData](https://docs.sqlalchemy.org/en/20/core/metadata.html#sqlalchemy.schema.MetaData)
    * Querying existing SQL tables with [.reflect()](https://docs.sqlalchemy.org/en/20/core/metadata.html#sqlalchemy.schema.MetaData)
    * Retrieving a specific table 
    * Using its [select](https://docs.sqlalchemy.org/en/20/core/metadata.html#sqlalchemy.schema.Table.select) statement and
    * Executing it in a SQLAlchemy [Session](https://docs.sqlalchemy.org/en/20/orm/session_api.html#sqlalchemy.orm.Session) object
    * Iterating the result set
    """)
    return

@app.cell
def _(mo):
    editor_024 = mo.ui.code_editor(value='from sqlalchemy import MetaData\nfrom sqlalchemy.orm import Session\n\nmeta = MetaData()\ndb_schema = ai_lab_config.db_schema\nmeta.reflect(engine, schema=db_schema)\n\nflights = meta.tables[f"{db_schema}.us_flights"]\nstmt = (\n    flights.select()\n    .where(flights.c.op_carrier_airline_id == 20452)\n    .where(flights.c.origin_state_abr == "TX")\n    .where(flights.c.dest_state_abr == "NJ")\n)\nwith Session(engine) as session:\n    for r in session.execute(stmt):\n        print(f\'Departure: {r[0].date()} {r[6]}\')', language="python", min_height=100)
    run_024 = mo.ui.run_button(label="Run cell 24")
    mo.vstack([editor_024, run_024])
    return editor_024, run_024

@app.cell
def _(editor_024, lesson, mo, render, run_024):
    mo.stop(not run_024.value)
    render(mo, lesson.run(editor_024.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## 5. Using the Exasol Bucket File System

    The [Exasol Bucket File System](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm) (BucketFS) is a powerful feature for exchanging non-relational data with the database nodes in an Exasol cluster.

    Such data can be arbitrary files including 
    * Data to be processed by [User Defined Scripts](https://docs.exasol.com/db/latest/database_concepts/udf_scripts.htm) (UDFs)
    * [Script-Languages Containers](https://github.com/exasol/script-languages-release) (SLCs), see also the dedicated [Tutorial on Script-Languages Containers](/?file=exasol-examples/script_languages_container/using_the_script_languages_container_tool.py)
    * AI Models

    ### 5.1 Uploading a File to the BucketFS

    First we will create a sample file:
    """)
    return

@app.cell
def _(mo):
    editor_025 = mo.ui.code_editor(value='%%writefile first_steps/text_file.txt\nHello World!\\n', language="python", min_height=100)
    run_025 = mo.ui.run_button(label="Run cell 25")
    mo.vstack([editor_025, run_025])
    return editor_025, run_025

@app.cell
def _(editor_025, lesson, mo, render, run_025):
    mo.stop(not run_025.value)
    render(mo, lesson.run(editor_025.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    And now, let's upload the file into the BucketFS.

    The function `open_bucketfs_location()` returns a path into Exasols BucketFS, also using the configuration in the SCS.
    """)
    return

@app.cell
def _(mo):
    editor_026 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_bucketfs_location\nfrom pathlib import Path \n\nfile = Path("first_steps/text_file.txt")\nbfs = open_bucketfs_location(ai_lab_config)\nfile_in_bfs = bfs / file.name\nfile_in_bfs.write(file.read_bytes())', language="python", min_height=100)
    run_026 = mo.ui.run_button(label="Run cell 26")
    mo.vstack([editor_026, run_026])
    return editor_026, run_026

@app.cell
def _(editor_026, lesson, mo, render, run_026):
    mo.stop(not run_026.value)
    render(mo, lesson.run(editor_026.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### 5.2 Listing the Files in the BucketFS

    We can also list all the files currently available in the BucketFS:
    """)
    return

@app.cell
def _(mo):
    editor_027 = mo.ui.code_editor(value="from exakit.nb.example_runtime import open_bucketfs_location\n\nbfs = open_bucketfs_location(ai_lab_config)\nfor p in bfs.iterdir():\n    print(f'- {p.name}')", language="python", min_height=100)
    run_027 = mo.ui.run_button(label="Run cell 27")
    mo.vstack([editor_027, run_027])
    return editor_027, run_027

@app.cell
def _(editor_027, lesson, mo, render, run_027):
    mo.stop(not run_027.value)
    render(mo, lesson.run(editor_027.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### 5.3 Reading the File in the BucketFS Using a User Defined Function

    This sections demonstrates reading the contents of a file in the BucketFS using a [User Defined Function](https://docs.exasol.com/db/latest/database_concepts/udf_scripts.htm) (UDF). 

    UDFs can be used in Exasol SQL statements and can also access objects in the BucketFS.

    First we will define the UDF:
    """)
    return

@app.cell
def _(mo):
    editor_028 = mo.ui.code_editor(value='%%sql\n--/\nCREATE OR REPLACE PYTHON3_ML SCALAR SCRIPT \n    bfs_file_content("path" VARCHAR(256)) \n    EMITS ("FILE" VARCHAR(256), CONTENT VARCHAR(2000000)) AS\nfrom pathlib import Path \ndef run(ctx):  \n    ctx.emit(ctx.path, Path(ctx.path).read_text())\n/', language="python", min_height=100)
    run_028 = mo.ui.run_button(label="Run cell 28")
    mo.vstack([editor_028, run_028])
    return editor_028, run_028

@app.cell
def _(editor_028, lesson, mo, render, run_028):
    mo.stop(not run_028.value)
    render(mo, lesson.run(editor_028.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    And now, let's read the contents of the file in the BucketFS we just created before. 

    The file's BucketFS location is represented by an instance of class [exasol.bucketfs.PathLike](https://exasol.github.io/bucketfs-python/main/api.html#exasol.bucketfs._path.PathLike) and the method `as_udf_path()` returns the file's path as seen by a UDF:
    """)
    return

@app.cell
def _(mo):
    editor_029 = mo.ui.code_editor(value="%%sql\nSELECT bfs_file_content('{{file_in_bfs.as_udf_path()}}');", language="python", min_height=100)
    run_029 = mo.ui.run_button(label="Run cell 29")
    mo.vstack([editor_029, run_029])
    return editor_029, run_029

@app.cell
def _(editor_029, lesson, mo, render, run_029):
    mo.stop(not run_029.value)
    render(mo, lesson.run(editor_029.value))
    return

if __name__ == "__main__":
    app.run()
