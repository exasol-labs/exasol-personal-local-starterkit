import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('cloud/cloud_store_config.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Cloud Storage Extension Configuration

    Reference only: cloud storage and virtual-schema integration belong to separate work. These cells are not enabled by the local kit.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/cloud/cloud_store_config.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'cloud/cloud_store_config.ipynb')", language="python", min_height=100)
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

    # Cloud Storage Extension Configuration

    This notebook configures [cloud-storage-extension](https://github.com/exasol/cloud-storage-extension/) using 
    functions from [notebook-connector library](https://github.com/exasol/notebook-connector/).

    On the high level it does the following:
    * retrieves latest release of cloud-storage-extension jar
    * uploads it into [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm)
    * registers UDF scripts for the cloud-storage-extension
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Cloud Storage Extension setup
    """)
    return

@app.cell
def _(mo):
    editor_002 = mo.ui.code_editor(value='from exasol.nb_connector import github, bfs_utils, cloud_storage\nfrom exakit.nb.example_runtime import open_bucketfs_connection, open_pyexasol_connection\n\njar_local_path = github.retrieve_jar(github.Project.CLOUD_STORAGE_EXTENSION, use_local_cache=True)\nbfs_bucket = open_bucketfs_connection(ai_lab_config)\nbfs_path = bfs_utils.put_file(bfs_bucket, jar_local_path)\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    cloud_storage.setup_scripts(conn, ai_lab_config.db_schema, bfs_path.as_udf_path())\n    \nprint("Could Storage Extension was initialized")', language="python", min_height=100)
    run_002 = mo.ui.run_button(label="Run cell 2")
    mo.vstack([editor_002, run_002])
    return editor_002, run_002

@app.cell
def _(editor_002, lesson, mo, render, run_002):
    mo.stop(not run_002.value)
    render(mo, lesson.run(editor_002.value))
    return

if __name__ == "__main__":
    app.run()
