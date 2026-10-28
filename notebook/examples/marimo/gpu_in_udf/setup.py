import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('gpu_in_udf/setup.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Setup Script Language Container with GPU Support

    Requires a GPU-capable Exasol host and GPU SLC. The local Mac kit does not provision these.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/gpu_in_udf/setup.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'gpu_in_udf/setup.ipynb')", language="python", min_height=100)
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

    # Setup Script Language Container with GPU Support

    We will create a custom Script Language Container with GPU support and install two machine learning libraries to it:
    * `pytorch`
    * `exasol-transformers-extension`
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
    ### Check that we don't have a SaaS backend configured
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exasol.nb_connector.ai_lab_config import StorageBackend, AILabConfig\nfrom exasol.nb_connector.ui.common import popup_message\nif ai_lab_config.get(AILabConfig.storage_backend, ) == StorageBackend.saas.name:\n    popup_message.display_popup(f"This tutorial will not work correctly with a SaaS as backend. You can export the Script-Languages-Container to a local file, but the upload to the database will fail.")', language="python", min_height=100)
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
    ## Preparation
    Similar to the [Script Languages Container tutorial](/?file=exasol-examples/script_languages_container/using_the_script_languages_container_tool.py), we instantiate the class `ScriptLanguagesContainer`. Exasol provides a special flavor for CUDA enabled Script Language Container: `template-Exasol-8-python-3.10-cuda-conda`. This flavor already brings basic packages (e.g. CUDA) and configurations which are necessary to use GPU's in UDF's.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='from exasol.nb_connector.slc import ScriptLanguageContainer\nflavor = "template-Exasol-8-python-3.10-cuda-conda"\nslc = ScriptLanguageContainer.create_or_open(secrets=ai_lab_config, name="gpu_slc", flavor=flavor)\nprint(f"{slc.name} is ready.")', language="python", min_height=100)
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
    ### Add ML Libraries
    In this example we use the [pytorch](https://anaconda.org/conda-forge/pytorch) Conda package to create a basic UDF and check if the GPU is available. We specify explictily to use the CUDA 12.9 version of `pytorch`, the same CUDA version which is already installed in `template-Exasol-8-python-3.10-cuda-conda`. Also, we add Exasol's `exasol-transformers-extension` package which will be used in the more advanced example.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='from exasol.exaslpm.model.package_file_config import CondaPackage, PipPackage\nslc.restore_internal_package_file()\nslc.restore_public_package_file()\npytorch_pkg = CondaPackage(name="pytorch", version="=2.7.1=cuda129_mkl_py310_hecdad2d_304")\nslc.append_custom_conda_packages([pytorch_pkg])\nte_pkg = PipPackage(name="exasol-transformers-extension", version="==3.0.0")\nslc.append_custom_pip_packages([te_pkg])', language="python", min_height=100)
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
    ### Export the Container to a File
    We can now build and export the new Script Language Container to a tar.gz file. As the file gets quite large, we do not want to copy the file to an export path. The internal file is enough for this tutorial. The class `ScriptLanguageContainer` offers the method `export_no_copy` for this use case. **Note:** this step might take very long (>1h).
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='slc.export_no_copy()\nprint("Ready")', language="python", min_height=100)
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
    ### Deploy the Container to the Database
    Now we are ready to deploy the new Script Language Container to the database. **Note:** this step might also take very long...
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='slc.deploy()\nprint("Ready")', language="python", min_height=100)
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
    If the deploy function failed, we can try to generate the activation key again by calling `generate_activation_key()`
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='slc.generate_activation_key(True)', language="python", min_height=100)
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
    ### Finish
    Now you can continue with [Basic UDF with GPU support](/?file=exasol-examples/gpu_in_udf/basic_udf_with_gpu.py)
    """)
    return

if __name__ == "__main__":
    app.run()
