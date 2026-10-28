import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('cloud/02_s3_vs_reuters.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Create Virtual Schema

    Reference only: cloud storage and virtual-schema integration belong to separate work. These cells are not enabled by the local kit.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/cloud/02_s3_vs_reuters.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'cloud/02_s3_vs_reuters.ipynb')", language="python", min_height=100)
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

    In this notebook we create a Virtual Schema which accesses JSON files on a public S3 bucket.
    The data we are loading is a part of the [Reuters 21578](https://paperswithcode.com/dataset/reuters-21578) dataset, which is a collection of documents with news articles.
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
    As a first step, we are setting up the S3 Virtual Schema connector in the database.
    You can find more information in the [s3-document-files-virtual-schema](https://github.com/exasol/s3-document-files-virtual-schema/) GitHub repository.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='%run ./s3_vs_setup.ipynb', language="python", min_height=100)
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
    # Create Virtual Schema

    To configure the virtual schema, we need the following:

    1. Create an S3 Connection object, which specifies in which S3 bucket our data resides. Our dataset is on a public S3 bucket, so no S3 credentials are needed. If your data is not open to the public, you need to store credentials in the Connection object.
    2. Put the EDML file into the Bucket FS. EDML describes the mapping between the JSON structure and the desired Virtual Schema tables and columns. In our case, the mapping is simple, as every JSON file describes an individual news article with the same set of columns. However, EDML supports more complex scenarios, like table references, foreign keys, and missing columns. You can find more details [in the documentation.](https://github.com/exasol/virtual-schema-common-document/blob/main/doc/user_guide/edml_user_guide.md)
    3. Create a Virtual Schema with the S3 Connection object and the EDML file in the Bucket FS. After this step, new virtual tables are added to Exasol, and every query from them performs S3 data read.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='import pyexasol\nimport pathlib\nfrom exakit.nb.example_runtime import open_pyexasol_connection\nfrom exasol.nb_connector import bfs_utils', language="python", min_height=100)
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
    editor_005 = mo.ui.code_editor(value='sql = """\nCREATE CONNECTION S3_CONNECTION_VS\n  TO \'\'\n  USER \'\'\n  IDENTIFIED BY \'{\n      "awsRegion": "eu-central-1", \n      "s3Bucket": "ai-lab-example-data-s3" \n  }\';\n"""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    conn.execute(sql)', language="python", min_height=100)
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
    Our EDML definition extracts 3 fields from JSON files:
    * `title`: as a VARCHAR(255) where longer texts are truncated.
    * `id` (named as `NEWS_ID`): article identifier stored as a VARCHAR(50)
    * `body`: text of the article as VARCHAR(1024) where longer texts are truncated.

    In addition to those 3 fields, we have the field `topics`, which is extracted as a reference table.
    In the JSON data, topics are represented as a list of tags associated with the article, for example:

    ```
        "topics": [
          "grain",
          "wheat",
          "corn",
          "barley",
          "oat",
          "sorghum"
        ],
    ```

    To have convenient access to the topics, we use the `toTableMapping` EDML feature, which creates a second table `NEWS_TOPICS`, keeping a list of topics and `NEWS_ID`:

    ```
          "topics": {
            "toTableMapping": {
              "mapping": {
                "toVarcharMapping": {
                  "destinationName": "NAME"
                }
              }
            }
          },
    ```
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='# put edml to bucket fs\nbfs_bucket = open_bucketfs_connection(ai_lab_config)\nbfs_path = bfs_utils.put_file(bfs_bucket, pathlib.Path("reuters-edml.json"))', language="python", min_height=100)
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
    editor_007 = mo.ui.code_editor(value='bfs_path.as_udf_path()', language="python", min_height=100)
    run_007 = mo.ui.run_button(label="Run cell 7")
    mo.vstack([editor_007, run_007])
    return editor_007, run_007

@app.cell
def _(editor_007, lesson, mo, render, run_007):
    mo.stop(not run_007.value)
    render(mo, lesson.run(editor_007.value))
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='sql = """\nCREATE VIRTUAL SCHEMA {schema_name!i}_VS USING {schema_name!i}.S3_FILES_ADAPTER WITH\n    CONNECTION_NAME = \'S3_CONNECTION_VS\'\n    MAPPING         = {map_file!s};\n"""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    conn.execute(sql, query_params={\n        "schema_name": ai_lab_config.db_schema,\n        "map_file": bfs_path.as_udf_path()\n    })', language="python", min_height=100)
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
    # Query the data

    Once we have our Virtual Schema created, a new table `AI_LAB_VS.NEWS` is available for querying. 
    *Note*: you need to be aware of performance overhead. Virtual Schemas don't do any intermediate caching, and every request to a virtual table performs several S3 data reads, which might be slow.

    If you are going to access the data several times, it might make sense to create the new table and copy the data from the virtual table into a normal table. Here we don't do that for simplicity.
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='sql = """\nselect title, news_id from {schema_name!i}_VS.NEWS\nlimit 10\n"""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    res = conn.execute(sql, query_params={\n        "schema_name": ai_lab_config.db_schema\n    })\n    for r in res:\n        print(r)', language="python", min_height=100)
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
    Besides the `NEWS` table, where each row is a news article, we additionally have a reference table with topics associated with every article.
    In our EDML file, `toTableMapping` was used, which created a second table `NEWS_TOPICS`, containing flattened list of topics associated with `NEWS_ID`.
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='sql = """\nselect *\nfrom {schema_name!i}_VS.NEWS_TOPICS\nlimit 10\n"""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    res = conn.execute(sql, query_params={\n        "schema_name": ai_lab_config.db_schema\n    })\n    for r in res:\n        print(r)', language="python", min_height=100)
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
    So, the query below can be used to find the most frequent topics in our dataset.
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='sql = """\nselect NAME, count(*)\nfrom {schema_name!i}_VS.NEWS_TOPICS\ngroup by 1\norder by 2 desc\nlimit 10\n"""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    res = conn.execute(sql, query_params={\n        "schema_name": ai_lab_config.db_schema\n    })\n    for r in res:\n        print(r)', language="python", min_height=100)
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
    The tables `NEWS` and `NEWS_TOPICS` can also be joined on column `NEWS_ID` to find articles about a specific topic:
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value='sql = """\nselect topics.name, news.title, news.news_id\nfrom \n    {schema_name!i}_VS.NEWS as news,\n    {schema_name!i}_VS.NEWS_TOPICS as topics\nwhere news.NEWS_ID = topics.NEWS_NEWS_ID\nand topics.NAME = \'grain\'\n\nlimit 10\n"""\n\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    res = conn.execute(sql, query_params={\n        "schema_name": ai_lab_config.db_schema\n    })\n    for r in res:\n        print(r)', language="python", min_height=100)
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
    Materialize the news data in a table. This speeds up processing of the data in other notebooks.
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='sql = """\nCREATE TABLE {schema_name!i}.NEWS as select T.NAME as TOPIC, N.TITLE as TITLE, N.NEWS_ID as NEWS_ID, N.BODY as BODY\nFROM\n    {schema_name!i}_VS.NEWS as N,\n    {schema_name!i}_VS.NEWS_TOPICS as T\nWHERE N.NEWS_ID = T.NEWS_NEWS_ID;\n"""\nwith open_pyexasol_connection(ai_lab_config) as conn:\n    res = conn.execute(sql, query_params={\n        "schema_name": ai_lab_config.db_schema\n    })', language="python", min_height=100)
    run_013 = mo.ui.run_button(label="Run cell 13")
    mo.vstack([editor_013, run_013])
    return editor_013, run_013

@app.cell
def _(editor_013, lesson, mo, render, run_013):
    mo.stop(not run_013.value)
    render(mo, lesson.run(editor_013.value))
    return

if __name__ == "__main__":
    app.run()
