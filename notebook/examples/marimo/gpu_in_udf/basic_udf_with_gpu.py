import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('gpu_in_udf/basic_udf_with_gpu.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Basic Udf With Gpu

    Requires a GPU-capable Exasol host and GPU SLC. The local Mac kit does not provision these.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/gpu_in_udf/basic_udf_with_gpu.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'gpu_in_udf/basic_udf_with_gpu.ipynb')", language="python", min_height=100)
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

    ## Basic UDF using GPU Acceleration

    In this tutorial we will build two very simple UDFs which demonstrate that GPU detection works.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Open Secure Configuration Storage
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
    ### Instantiate ScriptLanguagesContainer

    The following cell creates an instance of class `ScriptLanguageContainer` from the notebook-connector,
    which enables us to use the Script Language Container (SLC).
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exasol.nb_connector.slc import ScriptLanguageContainer\nslc = ScriptLanguageContainer(secrets=ai_lab_config, name="gpu_slc")', language="python", min_height=100)
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
    ### Connect to the Database and activate the Container
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='from exasol.nb_connector.language_container_activation import open_pyexasol_connection_with_lang_definitions\n\nconn = open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True)', language="python", min_height=100)
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
    ### Create GPU enabled UDFs

    Exasol UDFs provide the script option `%perInstanceRequiredAcceleratorDevices` which allows us to define the behavior of the database when executing UDF's. This option can have the following values:
    * `None`: NO accelerator selected/required (implicit default for CPU processing)
    * `GpuNvidia`: NVIDIA GPU accelerator required by the UDF. The invocation of the UDF will fail if the GPU is unavailable or the Script Language Container is not suited for GPU's.
    * `None|GpuNvidia`: NVIDIA GPU accelerator preferred but fallback to NO accelerator (CPU processing)

    The following sample UDF requires GPU support by adding the line:
    ```
     %perInstanceRequiredAcceleratorDevices GpuNvidia;
    ```
    and emits the value of the environment variable `NVIDIA_VISIBLE_DEVICES`.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='import textwrap\nconn.execute(textwrap.dedent(f"""\nCREATE OR REPLACE {slc.language_alias} SCALAR SCRIPT\nnvidia_env_variable_check()\nEMITS (var_name VARCHAR(1000), var_value VARCHAR(1000)) AS\n %perInstanceRequiredAcceleratorDevices GpuNvidia;\n\nimport os\n\ndef run(ctx):\n    ctx.emit("NVIDIA_VISIBLE_DEVICES", os.getenv(\'NVIDIA_VISIBLE_DEVICES\', "<invalid>"))\n/\n"""))\n\nres = conn.export_to_pandas("SELECT nvidia_env_variable_check();")\nres', language="python", min_height=100)
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
    The next UDF leverages the `pytorch` package which was installed in our custom Script Language Container and returns the string "GPU Found" if the GPU was detected in the UDF by `pytorch`.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='import textwrap\nconn.execute(textwrap.dedent(f"""\nCREATE OR REPLACE {slc.language_alias} SCALAR SCRIPT\ngpu_available()\nRETURNS VARCHAR(10000) AS\n %perInstanceRequiredAcceleratorDevices GpuNvidia;\n\nimport torch\n\ndef run(ctx):\n    if torch.cuda.is_available():\n        return "GPU Found"\n    else:\n        return "GPU Not Found"\n/\n"""))\n\nres = conn.export_to_pandas("SELECT gpu_available();")\nres', language="python", min_height=100)
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
    Now, try out the other values for `%perInstanceRequiredAcceleratorDevices` and see what happens.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Finish
    Now you can continue with [Advanced UDF with GPU support](/?file=exasol-examples/gpu_in_udf/advanced_udf_with_gpu.py)
    """)
    return

if __name__ == "__main__":
    app.run()
