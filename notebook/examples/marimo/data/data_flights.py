import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('data/data_flights.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: US Flights

    Downloads the tutorial dataset when you run the loader. Tutorial tables are kept in EXAKIT_EXAMPLES, separately from the persona datasets.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/data/data_flights.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'data/data_flights.ipynb')", language="python", min_height=100)
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

    # US Flights

    In this notebook we will load a dataset with information about US Flights. The data is publicly accessible at the [Bureau of Transportation Statistics](https://www.transtats.bts.gov/Homepage.asp) of the US Department of Transportation. We will load a selection of this data stored in a AWS cloudfront.

    We will be running SQL queries using <a href="https://github.com/ploomber/jupysql" target="_blank" rel="noopener">JupySQL</a>SQL Magic.

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
    ## Create tables
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='%%sql\nCREATE OR REPLACE TABLE US_FLIGHTS (\n        FL_DATE DATE,\n        OP_CARRIER_AIRLINE_ID DECIMAL(10, 0),\n        ORIGIN_AIRPORT_SEQ_ID DECIMAL(10, 0),\n        ORIGIN_STATE_ABR CHAR(2),\n        DEST_AIRPORT_SEQ_ID DECIMAL(10, 0),\n        DEST_STATE_ABR CHAR(2),\n        CRS_DEP_TIME CHAR(4),\n        DEP_DELAY DECIMAL(6, 2),\n        CRS_ARR_TIME CHAR(4),\n        ARR_DELAY DECIMAL(6, 2),\n        CANCELLED BOOLEAN,\n        CANCELLATION_CODE CHAR(1),\n        DIVERTED BOOLEAN,\n        CRS_ELAPSED_TIME DECIMAL(6, 2),\n        ACTUAL_ELAPSED_TIME DECIMAL(6, 2),\n        DISTANCE DECIMAL(6, 2),\n        CARRIER_DELAY DECIMAL(6, 2),\n        WEATHER_DELAY DECIMAL(6, 2),\n        NAS_DELAY DECIMAL(6, 2),\n        SECURITY_DELAY DECIMAL(6, 2),\n        LATE_AIRCRAFT_DELAY DECIMAL(6, 2)\n);', language="python", min_height=100)
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
    editor_005 = mo.ui.code_editor(value='%%sql\nCREATE OR REPLACE TABLE US_AIRLINES (\n        OP_CARRIER_AIRLINE_ID DECIMAL(10, 0) IDENTITY PRIMARY KEY,\n        CARRIER_NAME VARCHAR(1000)\n);', language="python", min_height=100)
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
    ## Bring in the UI functions

    We will need some UI functions that will handle loading the data.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='%run utils/flight_utils.ipynb', language="python", min_height=100)
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
    ## Load the data

    Please select one or more data periods for the flights in the table below. Once the data for the selected periods is loaded the entries will be removed from the table. Please do not load data for the same period more than once.

    Load the airlines' data (their codes and names). A repeated attempt to load the airlines' data will result in the primary key violation error.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='display(get_data_selection_ui(ai_lab_config))', language="python", min_height=100)
    run_007 = mo.ui.run_button(label="Run cell 7")
    mo.vstack([editor_007, run_007])
    return editor_007, run_007

@app.cell
def _(editor_007, lesson, mo, render, run_007):
    mo.stop(not run_007.value)
    render(mo, lesson.run(editor_007.value))
    return

if __name__ == "__main__":
    app.run()
