import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('data/data_customer_support.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Customer Support Ticket Dataset

    Downloads the tutorial dataset when you run the loader. Tutorial tables are kept in EXAKIT_EXAMPLES, separately from the persona datasets.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/data/data_customer_support.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'data/data_customer_support.ipynb')", language="python", min_height=100)
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

    # Customer Support Ticket Dataset

    Here we will load a dataset containing customer support tickets. We are using a modified version of the following [dataset](https://www.kaggle.com/datasets/suraj520/customer-support-ticket-dataset). 

    We modified the original dataset by removing data that was not needed for this demonstration. Furthermore, we replaced the purchased product placeholders in the ticket description with the actual product name, to show you in later notebooks, how you can extract this information from text with the help of Exasol.


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
    ## Create Customer Support Ticket Table

    First we have to create the table to import the customer support dataset into.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.execute(f"""\n    CREATE OR REPLACE TABLE {ai_lab_config.db_schema}.CUSTOMER_SUPPORT_TICKETS (\n        TICKET_ID DECIMAL(10,0), \n        CUSTOMER_NAME VARCHAR(100), \n        DATE_OF_PURCHASE DATE, \n        TICKET_SUBJECT VARCHAR(255), \n        TICKET_DESCRIPTION VARCHAR(2000), \n        TICKET_STATUS VARCHAR(50), \n        TICKET_CHANNEL VARCHAR(100)\n    );\n    """)', language="python", min_height=100)
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
    ## Import Data

    We will import the data via Exasols CSV Import statement.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    conn.execute(f"""\n    IMPORT INTO {ai_lab_config.db_schema}.CUSTOMER_SUPPORT_TICKETS\n    FROM CSV \n    AT \'https://dut5tonqye28.cloudfront.net/ai_lab/text_ai/\'\n    FILE \'customer_support_tickets.csv\'\n    SKIP = 1\n    """)', language="python", min_height=100)
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
    ## Inspect the Data

    Now we can inspect the data.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='from pandas import option_context\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    df = conn.export_to_pandas(f"""\n    SELECT * FROM {ai_lab_config.db_schema}.CUSTOMER_SUPPORT_TICKETS\n    LIMIT 10\n    """)\n    with option_context(\'display.max_rows\', 10, \'display.max_colwidth\', 1000):\n        display(df)', language="python", min_height=100)
    run_005 = mo.ui.run_button(label="Run cell 5")
    mo.vstack([editor_005, run_005])
    return editor_005, run_005

@app.cell
def _(editor_005, lesson, mo, render, run_005):
    mo.stop(not run_005.value)
    render(mo, lesson.run(editor_005.value))
    return

if __name__ == "__main__":
    app.run()
