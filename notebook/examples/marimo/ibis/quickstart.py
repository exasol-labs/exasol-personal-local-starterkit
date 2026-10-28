import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('ibis/quickstart.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Working with Exasol using IBIS dataframe library.

    Requires the US_FLIGHTS and US_AIRLINES tutorial tables. Run first_steps or the flight data loader first.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/ibis/quickstart.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'ibis/quickstart.ipynb')", language="python", min_height=100)
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

    # Working with Exasol using IBIS dataframe library.

    In this notebook, we will show some basic operations on Exasol data using Ibis. You can find more detailed information on using Ibis on the official [Ibis project](https://ibis-project.org/) website.

    The notebook is organized as a quickstart tutorial in which we will be looking at US flight delays. In particular, we will explore the delay caused by the carrier. We will rank the carriers using the delay as the performance metric. The data is publicly accessible at the [Bureau of Transportation Statistics](https://www.transtats.bts.gov/Homepage.asp) of the US Department of Transportation.

    ## Prerequisites

    Prior to using this notebook the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).
    2. [Load the US Flights data](/?file=exasol-examples/data/data_flights.py).

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
    ## connect

    Let's connect to the Exasol database. For convenience, we will use a wrapper around the [ibis.exasol.connect](https://ibis-project.org/backends/exasol) command.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_ibis_connection\n\nconn = open_ibis_connection(ai_lab_config, compression=True)', language="python", min_height=100)
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
    # table

    We will start by creating a `table` object for the table with the flight delay data.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value="flights = conn.table('US_FLIGHTS')", language="python", min_height=100)
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
    Let's have a look at the content of this table.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='flights.head().to_pandas()', language="python", min_height=100)
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
    # filter

    Should we compute the statistics on all records in the table?
    What about canceled or diverted flights? How should we account for them? Let's see what information we've got for such unfortunate flights.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='flights.filter(flights.CANCELLED).head().to_pandas()', language="python", min_height=100)
    run_006 = mo.ui.run_button(label="Run cell 6")
    mo.vstack([editor_006, run_006])
    return editor_006, run_006

@app.cell
def _(editor_006, lesson, mo, render, run_006):
    mo.stop(not run_006.value)
    render(mo, lesson.run(editor_006.value))
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='flights.filter(flights.DIVERTED).head().to_pandas()', language="python", min_height=100)
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
    There is no delay information for those flights. So, let's just exclude them.

    # group_by and aggregate

    Let's compute some statistics on the delay for each carrier.
    We can chain together the `filter`, `group_by`, and `aggregate` operators.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value="delay_by_carrier = flights.filter((flights.CANCELLED | flights.DIVERTED).negate()).group_by('OP_CARRIER_AIRLINE_ID').aggregate(\n    flights.CARRIER_DELAY.sum().name('combined_delay'),\n    flights.CARRIER_DELAY.count().name('total_delayed'),\n    flights.OP_CARRIER_AIRLINE_ID.count().name('total_flights')\n)\ndelay_by_carrier.head().to_pandas()", language="python", min_height=100)
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
    # mutate

    Let's add two new columns to the statistics computed in the previous step - the percentage of flights that have been delayed and the average delay per flight.
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='delay_by_carrier = delay_by_carrier.mutate(\n    percent_delayed=100 * delay_by_carrier.total_delayed / delay_by_carrier.total_flights,\n    delay_per_flight=delay_by_carrier.combined_delay / delay_by_carrier.total_flights\n)\ndelay_by_carrier.head().to_pandas()', language="python", min_height=100)
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
    # join

    Now, let's link the table with the carrier names, that are stored in another table called US_AIRLINES.
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value="airlines = conn.table('US_AIRLINES')\ndelay_by_carrier = delay_by_carrier.join(airlines, 'OP_CARRIER_AIRLINE_ID', how='inner')\ndelay_by_carrier.head().to_pandas()", language="python", min_height=100)
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
    # order

    Let's order the airlines from worst to best
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='delay_by_carrier = delay_by_carrier.order_by(delay_by_carrier.delay_per_flight.desc())\ndelay_by_carrier.head().to_pandas()', language="python", min_height=100)
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
    # select

    Finally, we will select the columns to display and print out the 10 worst airlines.
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value="delay_by_carrier = delay_by_carrier.select('CARRIER_NAME', 'percent_delayed', 'delay_per_flight')\ndelay_by_carrier.head(10).to_pandas()", language="python", min_height=100)
    run_012 = mo.ui.run_button(label="Run cell 12")
    mo.vstack([editor_012, run_012])
    return editor_012, run_012

@app.cell
def _(editor_012, lesson, mo, render, run_012):
    mo.stop(not run_012.value)
    render(mo, lesson.run(editor_012.value))
    return

if __name__ == "__main__":
    app.run()
