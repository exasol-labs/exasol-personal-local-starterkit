import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('cloud/s3_vs_setup.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: S3 Virtual Schema configuration

    Reference only: cloud storage and virtual-schema integration belong to separate work. These cells are not enabled by the local kit.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/cloud/s3_vs_setup.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'cloud/s3_vs_setup.ipynb')", language="python", min_height=100)
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

    # S3 Virtual Schema configuration

    [S3 Virtual Schema](https://github.com/exasol/s3-document-files-virtual-schema) is an Exasol extension that allows access
    to structured and semi-structured documents residing in AWS S3 buckets. Once configured and set up, you can query JSON, 
    Parquet and CSV data directly from the database, as if they were imported into the Exasol tables.

    In this notebook we setting up the extension in the database and creating the required scripts.
    """)
    return

@app.cell
def _(mo):
    editor_002 = mo.ui.code_editor(value='from exasol.nb_connector import github, bfs_utils, cloud_storage\nfrom exakit.nb.example_runtime import open_bucketfs_connection, open_pyexasol_connection\n\n# TODO: to be moved into notebook-connector\'s Project enum\nimport enum\n\nclass MyProj(enum.Enum):\n    S3_DOCUMENT_VS = "s3-document-files-virtual-schema" \n\n\njar_local_path = github.retrieve_jar(MyProj.S3_DOCUMENT_VS, use_local_cache=True)\nbfs_bucket = open_bucketfs_connection(ai_lab_config)\nbfs_path = bfs_utils.put_file(bfs_bucket, jar_local_path)', language="python", min_height=100)
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
    editor_003 = mo.ui.code_editor(value='SQLS = [\n        "OPEN SCHEMA {schema!i}",\n        """\n--/\nCREATE OR REPLACE JAVA ADAPTER SCRIPT S3_FILES_ADAPTER AS\n    %scriptclass com.exasol.adapter.RequestDispatcher;\n    %jar {jar_path!r};\n/\n        """,\n        """\n--/\nCREATE OR REPLACE JAVA SET SCRIPT IMPORT_FROM_S3_DOCUMENT_FILES(\n  DATA_LOADER VARCHAR(2000000),\n  SCHEMA_MAPPING_REQUEST VARCHAR(2000000),\n  CONNECTION_NAME VARCHAR(500))\n  EMITS(...) AS\n    %scriptclass com.exasol.adapter.document.UdfEntryPoint;\n    %jar {jar_path!r};\n/\n        """,\n]', language="python", min_height=100)
    run_003 = mo.ui.run_button(label="Run cell 3")
    mo.vstack([editor_003, run_003])
    return editor_003, run_003

@app.cell
def _(editor_003, lesson, mo, render, run_003):
    mo.stop(not run_003.value)
    render(mo, lesson.run(editor_003.value))
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='with open_pyexasol_connection(ai_lab_config) as conn:\n    for sql in SQLS:\n        conn.execute(sql, query_params={\n            "schema": ai_lab_config.db_schema,\n            "jar_path": bfs_path.as_udf_path(),\n        })\n\nprint("S3 Virtual Schema was initialized")', language="python", min_height=100)
    run_004 = mo.ui.run_button(label="Run cell 4")
    mo.vstack([editor_004, run_004])
    return editor_004, run_004

@app.cell
def _(editor_004, lesson, mo, render, run_004):
    mo.stop(not run_004.value)
    render(mo, lesson.run(editor_004.value))
    return

if __name__ == "__main__":
    app.run()
