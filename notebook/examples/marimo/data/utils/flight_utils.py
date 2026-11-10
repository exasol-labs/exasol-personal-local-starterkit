import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('data/utils/flight_utils.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Flight Utils

    Downloads the tutorial dataset when you run the loader. Tutorial tables are kept in EXAKIT_EXAMPLES, separately from the persona datasets.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/data/utils/flight_utils.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'data/utils/flight_utils.ipynb')", language="python", min_height=100)
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

@app.cell
def _(mo):
    editor_002 = mo.ui.code_editor(value='from exasol.nb_connector.utils import upward_file_search\n\n# This NB may be running from various locations in the NB hierarchy.\n# Need to search for other supporting NBs from the current directory upwards.\n\nfrom exasol.nb_connector.ui.common import ui_styles\nfrom exasol.nb_connector.ui.common import popup_message', language="python", min_height=100)
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
    editor_003 = mo.ui.code_editor(value='from typing import List\nfrom datetime import datetime\nfrom dateutil.relativedelta import relativedelta\nimport io\nfrom itertools import islice\n\nimport ipywidgets as widgets\nimport requests\nfrom exasol.nb_connector.secret_store import Secrets\nfrom exakit.nb.example_runtime import open_pyexasol_connection\n\n\ndef _transform_flights(pipe, src) -> None:\n\n    for row in islice(src, 1, None):\n        fields = row.split(\',\')\n        fields[0] = datetime.strptime(fields[0], \'%m/%d/%Y %I:%M:%S %p\').strftime(\'%Y-%m-%d\')\n        for i in [10, 12]:\n            fields[i] = \'False\' if float(fields[i]) == 0. else \'True\'\n        pipe.write(bytes(\',\'.join(fields), encoding=\'utf-8\'))\n\n\ndef _transform_airlines(pipe, src) -> None:\n\n    for row in islice(src, 1, None):\n        fields = row.split(\',\', maxsplit=1)\n        al_name = fields[1].strip(\'"\\n\').split(\':\')[0]\n        fields[1] = f\'"{al_name}"\'\n        pipe.write(bytes(\',\'.join(fields) + \'\\n\', encoding=\'utf-8\'))\n\n\ndef _import_from_cloudfront(conf: Secrets, file_name: str, transform, table_name: str) -> None:\n\n    # Read requested csv file from the cloudfront\n    response = requests.get(f\'https://dut5tonqye28.cloudfront.net/ai_lab/flight-info/{file_name}\')\n    response.raise_for_status()\n    content_stream = io.BytesIO(response.content)\n    f_src = io.TextIOWrapper(content_stream, encoding=\'utf-8\')\n\n    # Pre-process and import the data\n    with open_pyexasol_connection(conf, schema=conf.db_schema, compression=True) as pyexasol_conn:\n        pyexasol_conn.import_from_callback(transform, f_src, table=table_name)\n\n\ndef load_flights_data(conf: Secrets, months: List[str]) -> None:\n\n    for mon in months:\n        file_name = f\'US_FLIGHTS_{mon.replace(" ", "_").upper()}.csv\'\n        _import_from_cloudfront(conf, file_name, _transform_flights, \'US_FLIGHTS\')\n\n\ndef load_airlines_data(conf: Secrets) -> None:\n\n    _import_from_cloudfront(conf, \'US_AIRLINES.csv\', _transform_airlines, \'US_AIRLINES\')\n\n\ndef get_data_selection_ui(conf: Secrets) -> widgets.Widget:\n    """\n    Builds a UI with a multi-select list of data periods and buttons for\n    loading the selected data.\n    """\n\n    ui_look = ui_styles.config_styles()\n\n    start_date = datetime(year=2023, month=4, day=1)\n    months = [(start_date + relativedelta(months=i)).strftime(\'%b %Y\')\n              for i in range(12)]\n\n    data_selector = widgets.SelectMultiple(options=months, layout=ui_look.input_layout, style=ui_look.input_style)\n    flights_btn = widgets.Button(description=\'Load Flights\', style=ui_look.button_style, layout=ui_look.button_layout)\n    airlines_btn = widgets.Button(description=\'Load Airlines\', style=ui_look.button_style, layout=ui_look.button_layout)\n    header_lbl = widgets.Label(value=\'Data Periods\', style=ui_look.header_style, layout=ui_look.header_layout)\n\n    def load_flights(btn):\n        if data_selector.value:\n            try:\n                load_flights_data(conf, data_selector.value)\n                popup_message.display_popup(\'Flights data has been loaded successfully\')\n                data_selector.options = [opt for opt in data_selector.options \n                                         if opt not in data_selector.value]\n                btn.icon = \'check\'\n                btn.disabled = not data_selector.options\n            except Exception as ex:\n                popup_message.display_popup(f\'Failed to load the flights data: {ex}\')\n        else:\n            btn.icon = \'check\'\n\n    def load_airlines(btn):\n        try:\n            load_airlines_data(conf)\n            popup_message.display_popup(\'Airlines data has been loaded successfully\')\n            btn.disabled = True\n        except Exception as ex:\n            popup_message.display_popup(f\'Failed to load the airlines data: {ex}\')\n\n    def on_value_change(change):\n        flights_btn.icon = \'pen\'\n\n    flights_btn.on_click(load_flights)\n    airlines_btn.on_click(load_airlines)\n    data_selector.observe(on_value_change, names=[\'value\'])\n\n    group_items = [header_lbl, widgets.Box([data_selector], layout=ui_look.row_layout)]\n    items = [widgets.Box(group_items, layout=ui_look.group_layout), \n             widgets.Box([flights_btn, airlines_btn], layout=ui_look.row_layout)]\n    ui = widgets.Box(items, layout=ui_look.outer_layout)\n    return ui', language="python", min_height=100)
    run_003 = mo.ui.run_button(label="Run cell 3")
    mo.vstack([editor_003, run_003])
    return editor_003, run_003

@app.cell
def _(editor_003, lesson, mo, render, run_003):
    mo.stop(not run_003.value)
    render(mo, lesson.run(editor_003.value))
    return

if __name__ == "__main__":
    app.run()
