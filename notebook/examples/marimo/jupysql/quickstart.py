import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('jupysql/quickstart.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Working with Exasol using JupySQL

    Requires the US_FLIGHTS and US_AIRLINES tutorial tables. SQL magics are supported in Jupyter and the Marimo cell runner.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/jupysql/quickstart.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'jupysql/quickstart.ipynb')", language="python", min_height=100)
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

    # Working with Exasol using JupySQL

    In this notebook, we will demonstrate how to use JupySQL to query and analyze Exasol data directly in Jupyter notebooks. JupySQL provides a seamless way to write SQL in notebook cells while maintaining the full power of Python for visualization and analysis.

    ### What is JupySQL?

    JupySQL is a modern SQL client for Jupyter notebooks that enables you to:
    - Write SQL directly in notebook cells using magic commands (`%sql` and `%%sql`)
    - Avoid verbose Python connection code and cursor management
    - Get beautifully formatted query results automatically
    - Seamlessly convert results to pandas DataFrames for analysis
    - Bridge SQL analytics with Python's visualization and ML libraries

    ### Why use JupySQL with Exasol?

    For data analysts and engineers working with Exasol, JupySQL offers several advantages:

    * **Better developer experience** - Prototype queries interactively, see results immediately, and iterate quickly without context switching between SQL and Python.
    * **Visualization ready** - Query Exasol data and immediately visualize it with matplotlib, plotly, or other Python libraries.
    * **Reproducible analysis** - Your SQL queries, results, and visualizations live together in one shareable notebook, perfect for documentation and collaboration.
    * **Production-ready connections** - Built on SQLAlchemy, you get reliable connection pooling and parameterized queries.

    The notebook is organized as a quickstart tutorial in which we will be looking at US flight delays. In particular, we will explore the delay caused by the carrier. We will rank the carriers using the delay as the performance metric. The data is publicly accessible at the [Bureau of Transportation Statistics](https://www.transtats.bts.gov/Homepage.asp) of the US Department of Transportation.

    ### Prerequisites

    Prior to using this notebook, the following steps need to be completed:
    1. [Configure the AI-Lab](/?file=exasol-examples/main_config.py).
    2. [Load the US Flights data](/?file=exasol-examples/data/data_flights.py).

    ### How to Use This Notebook:
    - If you're running in the Exasol AI-Lab environment, then you can use the AI-Lab configuration cells (labeled as "Option A" in the **Configuration** section).
    - If you're running in a standard Jupyter environment (VS Code, JupyterLab, etc.), then please provide your own Exasol connection details (labeled as "Option B" in the **Configuration** section).
    - Make sure to run cells sequentially, especially the connection setup cells before running any queries.

    **Note:** The AI-Lab specific cells (using `%run utils/access_store_ui.ipynb` and `%run ../utils/jupysql_init.ipynb`) can be ignored if you're not running in the AI-Lab environment.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Configuration

    Choose the configuration approach that matches your environment:

    - **Option A**: For Exasol AI-Lab users (skip to next section)
    - **Option B**: For portable use in any Jupyter environment (VS Code, JupyterLab, Google Colab, etc.)

    ---
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Option A: Configuration for Exasol AI-Lab

    **Use this section ONLY if you're running in the Exasol AI-Lab environment.**

    The AI-Lab provides pre-configured connection settings that handle all setup automatically.
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

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='# Load JupySQL and connect using AI-Lab configuration (AI-Lab only)\nfrom exakit.nb.example_runtime import init_sql as jupysql_init\njupysql_init(ai_lab_config)', language="python", min_height=100)
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
    ---

    **AI-Lab users:** Skip to the "Explore the Data" section below. The connection is now ready!

    ---
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Option B: Portable Configuration (Any Jupyter Environment)

    <span style="color:red">**Use this section if you're NOT using Exasol AI-Lab.** This works in VS Code, JupyterLab, Google Colab, or any standard Jupyter environment.

    **Prerequisites:** Make sure you have installed the required packages:
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='import sql\nprint("JupySQL and the Exasol dialect are supplied by the notebook environment.")', language="python", min_height=100)
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
    The **sqlalchemy-exasol** package is the dedicated SQLAlchemy dialect for connecting Python to an Exasol database. It translates standard SQL commands into the specific syntax and protocols used by **Exasol**. For more information, check out its [User Guide](https://exasol.github.io/sqlalchemy-exasol/master/user_guide/index.html#user-guide).
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    #### Step 1: Load the JupySQL Extension

    First, load the SQL magic extension (one-time setup per notebook session):
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='# Load the SQL magic extension\n%load_ext sql', language="python", min_height=100)
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
    #### Step 2: Connect to Your Exasol Database
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    **Option A: Use Environmental Variables for Connection Values**

    For your OS, figure out how to set environment variables. For the code below, you will need to set:
    - EXASOL_USER
    - EXASOL_PASSWORD
    - EXASOL_HOST
    - EXASOL_PORT (if not 8563)
    - EXASOL_SCHEMA (if not PUBLIC)
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='from exakit.nb.example_runtime import init_sql\nengine = init_sql(ai_lab_config)', language="python", min_height=100)
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
    #### Alternatives

    JupySQL can automatically connect using the `DATABASE_URL` environment variable:

    ```python
    from os import environ
    environ["DATABASE_URL"] = f"exa+websocket://{EXASOL_USER}:{EXASOL_PASSWORD}@{EXASOL_HOST}:{EXASOL_PORT}/{EXASOL_SCHEMA}"
    ```

    Then simply run:
    ```python
    %sql
    ```

    **For more connection options and security best practices**, see the [JupySQL Connection Documentation](https://jupysql.readthedocs.io/en/latest/connecting.html).

    ---

    **Connection established!** You're now ready to query Exasol using `%%sql` magic commands.

    ---
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Analyze your Data

    Let's start by looking at the flight delay data. Notice how we can write SQL directly in the cell with the `%%sql` magic command - no Python string wrapping needed!
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='%%sql\nSELECT *\nFROM US_FLIGHTS\nLIMIT 5', language="python", min_height=100)
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
    ### Filter Data

    Should we compute statistics on all records? What about canceled or diverted flights? Let's examine these edge cases.

    First, let's look at canceled flights:
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='%%sql\nSELECT *\nFROM US_FLIGHTS\nWHERE CANCELLED = TRUE\nLIMIT 5', language="python", min_height=100)
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
    And diverted flights:
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='%%sql\nSELECT *\nFROM US_FLIGHTS\nWHERE DIVERTED = TRUE\nLIMIT 5', language="python", min_height=100)
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
    There's no delay information for canceled or diverted flights, so we'll exclude them from our analysis.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Aggregate Statistics by Carrier

    Let's compute delay statistics for each carrier, excluding canceled and diverted flights:
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='%%sql\nSELECT \n    OP_CARRIER_AIRLINE_ID,\n    SUM(CARRIER_DELAY) AS combined_delay,\n    COUNT(CARRIER_DELAY) AS total_delayed,\n    COUNT(*) AS total_flights\nFROM US_FLIGHTS\nWHERE CANCELLED = FALSE \n    AND DIVERTED = FALSE\nGROUP BY OP_CARRIER_AIRLINE_ID\nLIMIT 5', language="python", min_height=100)
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
    ### Calculate Performance Metrics

    Now let's add calculated columns for the percentage of flights delayed and average delay per flight:
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='%%sql\nSELECT \n    OP_CARRIER_AIRLINE_ID,\n    SUM(CARRIER_DELAY) AS combined_delay,\n    COUNT(CARRIER_DELAY) AS total_delayed,\n    COUNT(*) AS total_flights,\n    ROUND(100.0 * COUNT(CARRIER_DELAY) / COUNT(*), 2) AS percent_delayed,\n    ROUND(SUM(CARRIER_DELAY) / COUNT(*), 2) AS delay_per_flight\nFROM US_FLIGHTS\nWHERE CANCELLED = FALSE \n    AND DIVERTED = FALSE\nGROUP BY OP_CARRIER_AIRLINE_ID\nLIMIT 5', language="python", min_height=100)
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
    ### Join with Airline Names

    Let's make our results more readable by joining with the airline names table:
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value='%%sql\nSELECT \n    a.CARRIER_NAME,\n    f.OP_CARRIER_AIRLINE_ID,\n    SUM(f.CARRIER_DELAY) AS combined_delay,\n    COUNT(f.CARRIER_DELAY) AS total_delayed,\n    COUNT(*) AS total_flights,\n    ROUND(100.0 * COUNT(f.CARRIER_DELAY) / COUNT(*), 2) AS percent_delayed,\n    ROUND(SUM(f.CARRIER_DELAY) / COUNT(*), 2) AS delay_per_flight\nFROM US_FLIGHTS f\nINNER JOIN US_AIRLINES a \n    ON f.OP_CARRIER_AIRLINE_ID = a.OP_CARRIER_AIRLINE_ID\nWHERE f.CANCELLED = FALSE \n    AND f.DIVERTED = FALSE\nGROUP BY a.CARRIER_NAME, f.OP_CARRIER_AIRLINE_ID\nLIMIT 5', language="python", min_height=100)
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
    ### Rank Airlines by Performance

    Finally, let's order the results to see the worst-performing airlines first (highest average delay per flight):
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='%%sql\nSELECT \n    a.CARRIER_NAME,\n    ROUND(100.0 * COUNT(f.CARRIER_DELAY) / COUNT(*), 2) AS percent_delayed,\n    ROUND(SUM(f.CARRIER_DELAY) / COUNT(*), 2) AS delay_per_flight\nFROM US_FLIGHTS f\nINNER JOIN US_AIRLINES a \n    ON f.OP_CARRIER_AIRLINE_ID = a.OP_CARRIER_AIRLINE_ID\nWHERE f.CANCELLED = FALSE \n    AND f.DIVERTED = FALSE\nGROUP BY a.CARRIER_NAME, f.OP_CARRIER_AIRLINE_ID\nORDER BY delay_per_flight DESC\nLIMIT 10', language="python", min_height=100)
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
    ### Analyzing Delay Patterns by State

    Let's explore which origin states have the most delays:
    """)
    return

@app.cell
def _(mo):
    editor_014 = mo.ui.code_editor(value='%%sql\nSELECT \n    ORIGIN_STATE_ABR AS state_abr,\n    COUNT(*) AS total_flights,\n    ROUND(AVG(DEP_DELAY), 2) AS avg_departure_delay,\n    ROUND(AVG(ARR_DELAY), 2) AS avg_arrival_delay\nFROM US_FLIGHTS\nWHERE CANCELLED = FALSE \n    AND DIVERTED = FALSE\n    AND DEP_DELAY IS NOT NULL\nGROUP BY ORIGIN_STATE_ABR\nHAVING COUNT(*) >= 10000\nORDER BY avg_departure_delay DESC\nLIMIT 10', language="python", min_height=100)
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
    ## Combining Python and JupySQL

    One of JupySQL's strengths is seamless integration with Python. Let's store query results and create a visualization.

    We can save results to a variable and convert to pandas:
    """)
    return

@app.cell
def _(mo):
    editor_015 = mo.ui.code_editor(value='%%sql result <<\nSELECT\n    a.carrier_name,\n    ROUND(100.0 * COUNT(f.carrier_delay) / COUNT(*), 2) AS percent_delayed,\n    ROUND(SUM(f.carrier_delay) / COUNT(*), 2) AS delay_per_flight\nFROM us_flights f\nINNER JOIN us_airlines a\n    ON f.op_carrier_airline_id = a.op_carrier_airline_id\nWHERE f.cancelled = false\n  AND f.diverted = false\nGROUP BY a.carrier_name, f.op_carrier_airline_id\nORDER BY delay_per_flight DESC\nLIMIT 10', language="python", min_height=100)
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
    editor_016 = mo.ui.code_editor(value='# Convert to pandas DataFrame\ndf = result.DataFrame()\ndf', language="python", min_height=100)
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
    ### Creating visualizations

    Now, we can use matplotlib or any other Python visualization library:
    """)
    return

@app.cell
def _(mo):
    editor_017 = mo.ui.code_editor(value="import matplotlib.pyplot as plt\n\nplt.figure(figsize=(12, 6))\nplt.barh(df['carrier_name'], df['delay_per_flight'])\nplt.xlabel('Average Delay per Flight (minutes)')\nplt.ylabel('Carrier')\nplt.title('Top 10 Airlines by Average Delay per Flight')\nplt.gca().invert_yaxis()  # Highest delay at top\nplt.tight_layout()\nplt.show()", language="python", min_height=100)
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
    ### Using Parameterized Queries

    JupySQL supports parameterized queries, making it easy to build dynamic analyses. First, enable named parameters:
    """)
    return

@app.cell
def _(mo):
    editor_018 = mo.ui.code_editor(value='# Enable named parameters feature in JupySQL\n%config SqlMagic.named_parameters="enabled"', language="python", min_height=100)
    run_018 = mo.ui.run_button(label="Run cell 18")
    mo.vstack([editor_018, run_018])
    return editor_018, run_018

@app.cell
def _(editor_018, lesson, mo, render, run_018):
    mo.stop(not run_018.value)
    render(mo, lesson.run(editor_018.value))
    return

@app.cell
def _(mo):
    editor_019 = mo.ui.code_editor(value='# Set a Python variable\nmin_flights = 50000', language="python", min_height=100)
    run_019 = mo.ui.run_button(label="Run cell 19")
    mo.vstack([editor_019, run_019])
    return editor_019, run_019

@app.cell
def _(editor_019, lesson, mo, render, run_019):
    mo.stop(not run_019.value)
    render(mo, lesson.run(editor_019.value))
    return

@app.cell
def _(mo):
    editor_020 = mo.ui.code_editor(value='%%sql\nSELECT\n    a.CARRIER_NAME,\n    COUNT(*) AS flight_count,\n    ROUND(SUM(f.CARRIER_DELAY) / COUNT(*), 2) AS delay_per_flight\nFROM US_FLIGHTS f\nINNER JOIN US_AIRLINES a\n    ON f.OP_CARRIER_AIRLINE_ID = a.OP_CARRIER_AIRLINE_ID\nWHERE f.CANCELLED = FALSE\n  AND f.DIVERTED = FALSE\nGROUP BY a.CARRIER_NAME, f.OP_CARRIER_AIRLINE_ID\nHAVING COUNT(*) >= :min_flights\nORDER BY delay_per_flight DESC', language="python", min_height=100)
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
    ## Understanding JupySQL and SQLAlchemy

    Behind the scenes, JupySQL uses **SQLAlchemy**, Python's most popular SQL toolkit and Object Relational Mapper (ORM). SQLAlchemy provides the robust database connectivity layer that powers JupySQL's magic commands.

    You can also use SQLAlchemy directly when you need more programmatic control over your database operations:
    """)
    return

@app.cell
def _(mo):
    editor_021 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_sqlalchemy_connection\nfrom sqlalchemy import text\n\n# Get a SQLAlchemy engine using AI-Lab config\nengine = open_sqlalchemy_connection(ai_lab_config)\n\n# Execute a query using SQLAlchemy directly\nquery = text("""\n    SELECT CARRIER_NAME, \n           COUNT(*) as total_flights\n    FROM US_FLIGHTS f\n    JOIN US_AIRLINES a ON a.OP_CARRIER_AIRLINE_ID = f.OP_CARRIER_AIRLINE_ID\n    WHERE NOT (CANCELLED OR DIVERTED)\n    GROUP BY CARRIER_NAME\n    ORDER BY total_flights DESC\n    LIMIT 5\n""")\n\nwith engine.connect() as conn:\n    result = conn.execute(query)\n    for row in result:\n        print(f"{row[0]}: {row[1]:,} flights")', language="python", min_height=100)
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
    **When to use SQLAlchemy directly:**
    - Building complex application logic with transactions
    - Using SQLAlchemy's ORM features for object-relational mapping
    - Needing fine-grained control over connection pooling
    - Programmatically constructing complex queries

    **When to use JupySQL:**
    - Interactive data exploration and analysis
    - Quick prototyping of SQL queries
    - Creating data narratives in notebooks
    - Teaching and demonstrating SQL concepts

    Both approaches work seamlessly with Exasol, and you can even use them together in the same notebook!
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Summary

    In this notebook, we've demonstrated how JupySQL provides a natural way to work with Exasol data in Jupyter notebooks:

    1. **Simple setup** - One line to load the extension, one line to connect
    2. **Clean SQL syntax** - Write SQL directly without Python string wrapping
    3. **Immediate results** - Beautifully formatted output automatically
    4. **Python integration** - Easy conversion to pandas for visualization and further analysis
    5. **Parameterized queries** - Dynamic queries using Python variables

    JupySQL bridges the gap between SQL analytics and Python's rich ecosystem, making it ideal for:
    - Data exploration and ad-hoc analysis
    - Creating reproducible analytical reports
    - Prototyping SQL queries before moving them to production
    - Teaching and demonstrating SQL concepts
    - Building data-driven narratives that combine queries, results, and visualizations

    For more information on JupySQL, visit the [official documentation](https://jupysql.readthedocs.io/en/latest/).
    """)
    return

if __name__ == "__main__":
    app.run()
