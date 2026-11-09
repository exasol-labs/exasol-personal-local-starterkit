import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('pyexasol/roundtrip_import_and_export.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Working with Exasol Using the PyExasol Connector

    Requires the flight tutorial tables. Reads and writes tutorial tables and local export files.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/pyexasol/roundtrip_import_and_export.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'pyexasol/roundtrip_import_and_export.ipynb')", language="python", min_height=100)
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
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Working with Exasol Using the PyExasol Connector
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    This notebook shows basic operations on example data using PyExasol. For more details, see also the [PyExasol documentation](https://exasol.github.io/pyexasol/master/index.html).

    Organized as a quickstart tutorial, the notebook highlights the flexibility and ease by which PyExasol allows importing data into and exporting data from an Exasol database. The notebook also shows how to transform data both in Python and within the database. The tutorial uses Polars, PyArrow, and example data on US flight delays.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    * [Polars](https://pola.rs/) is a lightning-fast DataFrame library for Python. A DataFrame is a two-dimensional data structure representing data as a table with rows and columns. The [import_from_polars](https://exasol.github.io/pyexasol/1.3.0/api.html#pyexasol.ExaConnection.import_from_polars) and [export_to_polars](https://exasol.github.io/pyexasol/1.3.0/api.html#pyexasol.ExaConnection.export_to_polars) were introduced in PyExasol version `1.0.0` allowing users to quickly import & export their data into & from an Exasol Database.
    * [PyArrow](https://pola.rs/) is a cross-language development platform for in-memory data. The [import_from_parquet](https://exasol.github.io/pyexasol/1.3.0/api.html#pyexasol.ExaConnection.import_from_parquet) and [export_to_parquet](https://exasol.github.io/pyexasol/1.3.0/api.html#pyexasol.ExaConnection.export_to_parquet) were introduced in PyExasol version `1.2.0` to allow users to quickly import & export their data into & from an Exasol Database to a parquet file. A parquet file is a highly compressed, high-speed storage for massive, spreadsheet-like data.
    * The example data on US flight delays is used to explore the delay caused by the carrier.This data is publicly accessible at the [Bureau of Transportation Statistics](https://www.transtats.bts.gov/Homepage.asp) of the US Department of Transportation.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    We will use both the import and export functionalities of Polars & PyArrow in a a roundtrip manner with the data on US flight delays to illustrate how PyExasol creates a versatile & flexible bridge between Python code and the Exasol Database. Beyond specific use cases, like a project using Polars, this can leverage dynamic ecosystems with multiple input and output formats typical for real companies.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Prerequisites

    Prior to using this notebook the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).

    Please note:
    * AI Lab currently is shipped with PyExasol version `1.3.0`. 
    * Functions for PyArrow's parquet and Polars's DataFrame should work for all supported database versions, as data is converted into streamed CSVs before executing SQL statements `IMPORT` or `EXPORT`.

    ## 1. Setup

    ### 1.1 Open Secure Configuration Storage (SCS)
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
    ### 1.2 Download Files to Local Filesystem
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='import requests\n\ndef download_file(url, filename):\n    try:\n        response = requests.get(url, stream=True)\n        response.raise_for_status()\n        \n        with open(filename, \'wb\') as f:\n            for chunk in response.iter_content(chunk_size=8192):\n                f.write(chunk)\n                \n        print("File downloaded successfully!")\n        \n    except requests.exceptions.RequestException as e:\n        print(f"Error downloading file: {str(e)}")', language="python", min_height=100)
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
    #### 1.2.1 Download Parquet File from S3 Bucket & Inspect with Pyarrow
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    In this section we download a prepared file from an AWS S3 Bucket to our local filesystem. The file contains data on US flight delays. After that, we load and inspect the data with PyArrow.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='flights_parquet_file = "US_FLIGHTS_FEB_2024.parquet"\n\ndownload_file(\n    url="https://ai-lab-example-data-s3.s3.eu-central-1.amazonaws.com/first_steps/US_FLIGHTS_FEB_2024.parquet",\n    filename=flights_parquet_file\n)', language="python", min_height=100)
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
    Let's take a look at the contents of this file.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='from pyarrow import dataset\n\nparquet_table = dataset.dataset(flights_parquet_file).to_table()\n\nparquet_table.schema', language="python", min_height=100)
    run_005 = mo.ui.run_button(label="Run cell 5")
    mo.vstack([editor_005, run_005])
    return editor_005, run_005

@app.cell
def _(editor_005, lesson, mo, render, run_005):
    mo.stop(not run_005.value)
    render(mo, lesson.run(editor_005.value))
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='parquet_table.to_pandas().head()', language="python", min_height=100)
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
    #### 1.2.2 Download CVS File from Remote Filesystem & Inspect with Polars
    This section demonstrates how to download a CSV file from a remote source.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='airlines_csv_file = "US_AIRLINES.csv"\n\ndownload_file(\n    url="https://dut5tonqye28.cloudfront.net/ai_lab/flight-info/US_AIRLINES.csv",\n    filename=airlines_csv_file\n)', language="python", min_height=100)
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
    Let's take a look at the contents of this file.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='import polars as pl\n\npolars_dataframe = pl.read_csv(airlines_csv_file)\npolars_dataframe.schema', language="python", min_height=100)
    run_008 = mo.ui.run_button(label="Run cell 8")
    mo.vstack([editor_008, run_008])
    return editor_008, run_008

@app.cell
def _(editor_008, lesson, mo, render, run_008):
    mo.stop(not run_008.value)
    render(mo, lesson.run(editor_008.value))
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='polars_dataframe.head()', language="python", min_height=100)
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
    ### 1.3 Create Tables

    For importing the data into Exasol, we will start by creating empty tables.
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='from typing import NamedTuple\n\nclass TableInfo(NamedTuple):\n    table: str\n    schema: str = ai_lab_config.db_schema\n\n    @property\n    def as_tuple(self):\n        """This format is needed for PyExasol connections as keyword arguments"""\n        return (self.schema, self.table)\n\n    @property\n    def as_string(self):\n        """This format is important for completed queries sent to PyExasol"""\n        return f"{self.schema}.{self.table}"', language="python", min_height=100)
    run_010 = mo.ui.run_button(label="Run cell 10")
    mo.vstack([editor_010, run_010])
    return editor_010, run_010

@app.cell
def _(editor_010, lesson, mo, render, run_010):
    mo.stop(not run_010.value)
    render(mo, lesson.run(editor_010.value))
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='us_airlines = TableInfo(table="US_AIRLINES")\nus_flights = TableInfo(table="US_FLIGHTS")\n\n\nus_airlines_ddl = f"""\nCREATE OR REPLACE TABLE {us_airlines.as_string} (\n  OP_CARRIER_AIRLINE_ID DECIMAL(10, 0) IDENTITY PRIMARY KEY,\n  CARRIER_NAME VARCHAR(1000)\n)\n"""\n\nus_flights_ddl = f"""\nCREATE OR REPLACE TABLE {us_flights.as_string} (\n  FLIGHT_ID DECIMAL(18,0) IDENTITY PRIMARY KEY,\n  FL_DATE TIMESTAMP, \n  OP_CARRIER_AIRLINE_ID DECIMAL(10, 0),\n  ORIGIN_AIRPORT_SEQ_ID DECIMAL(10, 0),\n  ORIGIN_STATE_ABR CHAR(2),\n  DEST_AIRPORT_SEQ_ID DECIMAL(10, 0),\n  DEST_STATE_ABR CHAR(2),\n  CRS_DEP_TIME CHAR(4),\n  DEP_DELAY DOUBLE, \n  CRS_ARR_TIME CHAR(4),\n  ARR_DELAY DOUBLE,\n  CANCELLED BOOLEAN,\n  CANCELLATION_CODE CHAR(1),\n  DIVERTED BOOLEAN,\n  CRS_ELAPSED_TIME DOUBLE,\n  ACTUAL_ELAPSED_TIME DOUBLE, \n  DISTANCE DOUBLE,\n  CARRIER_DELAY DOUBLE,\n  WEATHER_DELAY DOUBLE,\n  NAS_DELAY DOUBLE,\n  SECURITY_DELAY DOUBLE,\n  LATE_AIRCRAFT_DELAY DOUBLE\n)\n"""', language="python", min_height=100)
    run_011 = mo.ui.run_button(label="Run cell 11")
    mo.vstack([editor_011, run_011])
    return editor_011, run_011

@app.cell
def _(editor_011, lesson, mo, render, run_011):
    mo.stop(not run_011.value)
    render(mo, lesson.run(editor_011.value))
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    for ddl in (us_airlines_ddl, us_flights_ddl):\n        conn.execute(ddl)', language="python", min_height=100)
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
    ### 1.4 Import Airline Information from CSV with PyExasol

    We use PyExasol's `import_from_file` to import the CSV into the `US_AIRLINES` table.
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='from pathlib import Path\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    path = Path(airlines_csv_file)\n    import_params = {\n        "column_delimiter": \'"\',\n        "column_separator": ",",\n        "row_separator": "CRLF",\n        "skip": 1,\n    }\n    conn.import_from_file(path, us_airlines.as_tuple, import_params)', language="python", min_height=100)
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
    ## 2. Roundtrip with Parquet

    ### 2.1 Importing Parquet Data from the Local Filesystem

    This section demonstrates how to import a parquet file from a local source into the database using PyExasol.
    """)
    return

@app.cell
def _(mo):
    editor_014 = mo.ui.code_editor(value='from pathlib import Path\n\ncolumns = parquet_table.column_names\n\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.import_from_parquet(source=Path(flights_parquet_file), table=us_flights.as_tuple, import_params={"columns":columns})', language="python", min_height=100)
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
    ### 2.2 Aggregating & Transforming the Data in the Database

    Let's find out which airline has the highest delay per flight:
    """)
    return

@app.cell
def _(mo):
    editor_015 = mo.ui.code_editor(value='highest_delay_per_flight_query = f"""\nSELECT\n  CARRIER_NAME "Airline",\n  SUM(CARRIER_DELAY) "Combined Delay",\n  COUNT(CARRIER_DELAY) "Delayed Flights",\n  COUNT(F.OP_CARRIER_AIRLINE_ID) "Total flights",\n  ROUND( SUM(CARRIER_DELAY) / COUNT(F.OP_CARRIER_AIRLINE_ID), 1 ) "Delay per flight"\nFROM {us_flights.as_string} F\n  JOIN {us_airlines.as_string} A \n  ON A.OP_CARRIER_AIRLINE_ID = F.OP_CARRIER_AIRLINE_ID\nWHERE NOT (CANCELLED OR DIVERTED)\nGROUP BY CARRIER_NAME\nORDER BY "Delay per flight" DESC\n"""', language="python", min_height=100)
    run_015 = mo.ui.run_button(label="Run cell 15")
    mo.vstack([editor_015, run_015])
    return editor_015, run_015

@app.cell
def _(editor_015, lesson, mo, render, run_015):
    mo.stop(not run_015.value)
    render(mo, lesson.run(editor_015.value))
    return

@app.cell
def _(mo):
    editor_016 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    result = conn.execute(highest_delay_per_flight_query).fetchall()\n\nresult', language="python", min_height=100)
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
    ### 2.3 Exporting the Transformed Data to Parquet

    This section demonstrates how to export transformed data to a parquet file in the local filesystem.
    """)
    return

@app.cell
def _(mo):
    editor_017 = mo.ui.code_editor(value='local_directory = "highest_delay"', language="python", min_height=100)
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
    #### 2.3.1 Save One File Without Additional `callback_params` 

    This code will save all of the data for the query into 1 parquet file, 
    Please note: When executing this cell more than once without deleting the directory, **you will get an exception**.
    This is because `callback_params={"existing_data_behavior":...}` was not changed (and the default behavior is to not overwrite files)

    ```python
    ValueError: 'highest_delay' contains existing files and `callback_params['existing_data_behavior']` is not one of these values: ('overwrite_or_ignore', 'delete_matching').
    ```
    """)
    return

@app.cell
def _(mo):
    editor_018 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.export_to_parquet(\n        dst=local_directory, \n        query_or_table=highest_delay_per_flight_query\n    )', language="python", min_height=100)
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
    #### 2.3.2 Repeatedly Saving a File With Overwriting

    `callback_params["existing_data_behavior"] = "overwrite_or_ignore"` will save all of the data for the query into 1 parquet file and overwrite any existing matching parquet file.
    **This allows executing the cell executed multiple times, unlike section 2.3.1.**


    `existing_data_behavior` can be set to:
    > * `error` (default value) raises an error if **any** data exists in the destination.

    > * `overwrite_or_ignore` ignores any existing data and overwrites files with the same name as an output file. Other existing files are ignored. This behavior, in combination with a unique basename_template for each write, allows for an append workflow.
    `delete_matching` is useful when writing a partitioned dataset. The first time each partition directory is encountered the entire directory will be deleted. This allows overwriting old partitions completely.
    """)
    return

@app.cell
def _(mo):
    editor_019 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.export_to_parquet(\n        dst=local_directory, \n        query_or_table=highest_delay_per_flight_query,\n        callback_params={"existing_data_behavior": "overwrite_or_ignore"}\n    )', language="python", min_height=100)
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
    #### 2.3.3 Save into Multiple Files
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    This code will save the data for the query into different parquet files and overwrite any existing & matching parquet filename.<br>
    The saving into multiple files comes from: `callback["max_rows_per_file"]=5` and `callback["max_rows_per_group"]=5`.<br>
    This overwriting behavior is due to: `callback_params["existing_data_behavior"] = "overwrite_or_ignore"`. 

    **Note:** If ``max_rows_per_file`` is altered, ensure that ``max_rows_per_group`` is set to a value less than or equal to the value of ``max_rows_per_file``. Both values must be set for this command to work as desired. Please refer to PyArrow's documentation for more information.
    """)
    return

@app.cell
def _(mo):
    editor_020 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.export_to_parquet(\n        dst=local_directory,\n        query_or_table=highest_delay_per_flight_query,\n        callback_params={\n            "existing_data_behavior": "overwrite_or_ignore",\n            "max_rows_per_file": 5,\n            "max_rows_per_group": 5,\n        }\n    )', language="python", min_height=100)
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
    ## 3. Roundtrip with Polars

    ### 3.1 Exporting the Data to a Polars DataFrame

    This section demonstrates how to export data from an Exasol Database to a Polars DataFrame.
    """)
    return

@app.cell
def _(mo):
    editor_021 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    highest_delay_per_flight_dataframe = conn.export_to_polars(\n        query_or_table=highest_delay_per_flight_query,\n    )\n\nhighest_delay_per_flight_dataframe.head()', language="python", min_height=100)
    run_021 = mo.ui.run_button(label="Run cell 21")
    mo.vstack([editor_021, run_021])
    return editor_021, run_021

@app.cell
def _(editor_021, lesson, mo, render, run_021):
    mo.stop(not run_021.value)
    render(mo, lesson.run(editor_021.value))
    return

@app.cell
def _(mo):
    editor_022 = mo.ui.code_editor(value='model_query = f"""\nSELECT\n  FLIGHT_ID,\n  TO_CHAR(FL_DATE, \'D\') AS day_of_week,\n  CASE \n        WHEN TO_CHAR(FL_DATE, \'D\') IN (\'6\', \'7\') THEN TRUE \n        ELSE FALSE \n    END AS is_weekend,\n  OP_CARRIER_AIRLINE_ID,\n  CAST(TO_CHAR(TO_TIMESTAMP(CRS_DEP_TIME, \'HH24MI\'), \'HH24\') AS INTEGER) AS CRS_DEP_HOUR,\n  ORIGIN_STATE_ABR,\n  DEST_STATE_ABR,\n  DISTANCE,\n  CASE\n      WHEN ARR_DELAY > 0 THEN 1\n      ELSE 0\n  END AS was_delayed\nFROM {us_flights.as_string}\n  WHERE CANCELLED IS FALSE\n  AND DIVERTED IS FALSE\n"""', language="python", min_height=100)
    run_022 = mo.ui.run_button(label="Run cell 22")
    mo.vstack([editor_022, run_022])
    return editor_022, run_022

@app.cell
def _(editor_022, lesson, mo, render, run_022):
    mo.stop(not run_022.value)
    render(mo, lesson.run(editor_022.value))
    return

@app.cell
def _(mo):
    editor_023 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    model_dataframe = conn.export_to_polars(query_or_table=model_query)\n\nmodel_dataframe.head()', language="python", min_height=100)
    run_023 = mo.ui.run_button(label="Run cell 23")
    mo.vstack([editor_023, run_023])
    return editor_023, run_023

@app.cell
def _(editor_023, lesson, mo, render, run_023):
    mo.stop(not run_023.value)
    render(mo, lesson.run(editor_023.value))
    return

@app.cell
def _(mo):
    editor_024 = mo.ui.code_editor(value='model_dataframe.select(pl.col("WAS_DELAYED").value_counts(sort=True))', language="python", min_height=100)
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
    ### 3.2 Training a Model
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    This is a toy example of a machine learning model. It is not intended to be optimized or well-performing. The example also omits many steps which you would expect in the preparation of a machine learning model.

    First, we one-hot encode categorical values and scale large numerical values.
    """)
    return

@app.cell
def _(mo):
    editor_025 = mo.ui.code_editor(value='from sklearn.preprocessing import OneHotEncoder, StandardScaler\nfrom sklearn.compose import ColumnTransformer\nfrom sklearn import set_config\n\n# Globally configure sklearn to return Polars DataFrames\nset_config(transform_output="polars")\n\n# Apply different transformations to different columns\ncat_cols = [\'OP_CARRIER_AIRLINE_ID\', \'ORIGIN_STATE_ABR\', \'DEST_STATE_ABR\']\nnum_cols = [\'DISTANCE\']\n\npreprocessor = ColumnTransformer(\n    transformers=[\n        (\'cat\', OneHotEncoder(sparse_output=False), cat_cols),\n        (\'num\', StandardScaler(), num_cols)  # Added scaling for DISTANCE\n    ],\n    remainder=\'passthrough\',\n    # This removes the prefixes like \'remainder__\' and \'cat__\'\n    verbose_feature_names_out=False \n)\n\n# Transform directly using the Polars DataFrame\nmodel_polars = preprocessor.fit_transform(model_dataframe)\n\nmodel_polars.head()', language="python", min_height=100)
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
    Next, we split the data into training and validation sets.
    """)
    return

@app.cell
def _(mo):
    editor_026 = mo.ui.code_editor(value="from sklearn.model_selection import train_test_split\n\nX = model_polars.drop('WAS_DELAYED', 'FLIGHT_ID')\ny = model_polars.select('WAS_DELAYED')\n\nX_train, X_valid, y_train, y_valid = train_test_split(X, y, test_size=0.2)", language="python", min_height=100)
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
    Finally, we train our model and then evaluate how it performed.
    """)
    return

@app.cell
def _(mo):
    editor_027 = mo.ui.code_editor(value='from sklearn.linear_model import LogisticRegression\nfrom sklearn.metrics import accuracy_score, classification_report\n\nclf_model = LogisticRegression(solver=\'liblinear\', random_state=42)\nclf_model.fit(X_train, y_train.to_series())\n\npred_valid_clf = clf_model.predict(X_valid)\n\nprint(f"Accuracy: {accuracy_score(y_valid, pred_valid_clf):.2%}")\nprint(classification_report(y_valid, pred_valid_clf))', language="python", min_height=100)
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
    ### 3.3 Importing the Model Results into an Exasol Database Table
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    We run the machine learning model on all of our flight data and insert it into an Exasol Database table.
    """)
    return

@app.cell
def _(mo):
    editor_028 = mo.ui.code_editor(value='all_preds = clf_model.predict(model_polars.drop(\'WAS_DELAYED\', \'FLIGHT_ID\'))\n\nfinal_df = model_polars.with_columns(\n    pl.Series("WAS_DELAYED_PRED", all_preds)\n).select([\n    "FLIGHT_ID",\n    "WAS_DELAYED",\n    "WAS_DELAYED_PRED"\n])\n\nfinal_df.head()', language="python", min_height=100)
    run_028 = mo.ui.run_button(label="Run cell 28")
    mo.vstack([editor_028, run_028])
    return editor_028, run_028

@app.cell
def _(editor_028, lesson, mo, render, run_028):
    mo.stop(not run_028.value)
    render(mo, lesson.run(editor_028.value))
    return

@app.cell
def _(mo):
    editor_029 = mo.ui.code_editor(value='us_flights_model = TableInfo(table="US_FLIGHTS_MODEL")\n\nus_flights_model_ddl = f"""\nCREATE OR REPLACE TABLE {us_flights_model.as_string}(\n    FLIGHT_ID DECIMAL(18,0) NOT NULL,\n    WAS_DELAYED BOOLEAN,\n    WAS_DELAYED_PRED BOOLEAN,\n    CONSTRAINT fk_flight_id\n        FOREIGN KEY (FLIGHT_ID) \n        REFERENCES {us_flights.as_string} (FLIGHT_ID)\n)\n"""', language="python", min_height=100)
    run_029 = mo.ui.run_button(label="Run cell 29")
    mo.vstack([editor_029, run_029])
    return editor_029, run_029

@app.cell
def _(editor_029, lesson, mo, render, run_029):
    mo.stop(not run_029.value)
    render(mo, lesson.run(editor_029.value))
    return

@app.cell
def _(mo):
    editor_030 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.execute(us_flights_model_ddl)', language="python", min_height=100)
    run_030 = mo.ui.run_button(label="Run cell 30")
    mo.vstack([editor_030, run_030])
    return editor_030, run_030

@app.cell
def _(editor_030, lesson, mo, render, run_030):
    mo.stop(not run_030.value)
    render(mo, lesson.run(editor_030.value))
    return

@app.cell
def _(mo):
    editor_031 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.import_from_polars(\n        src=final_df,\n        table=us_flights_model.as_tuple\n    )', language="python", min_height=100)
    run_031 = mo.ui.run_button(label="Run cell 31")
    mo.vstack([editor_031, run_031])
    return editor_031, run_031

@app.cell
def _(editor_031, lesson, mo, render, run_031):
    mo.stop(not run_031.value)
    render(mo, lesson.run(editor_031.value))
    return

@app.cell
def _(mo):
    editor_032 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    df = conn.export_to_pandas(us_flights_model.as_tuple)\ndf.head()', language="python", min_height=100)
    run_032 = mo.ui.run_button(label="Run cell 32")
    mo.vstack([editor_032, run_032])
    return editor_032, run_032

@app.cell
def _(editor_032, lesson, mo, render, run_032):
    mo.stop(not run_032.value)
    render(mo, lesson.run(editor_032.value))
    return

if __name__ == "__main__":
    app.run()
