import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('script_languages_container/test_slc.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Test the new Script-Languages-Container

    Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/script_languages_container/test_slc.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'script_languages_container/test_slc.ipynb')", language="python", min_height=100)
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

    # Test the new Script-Languages-Container

    This notebooks shows how to:
    - activate the new script-languages-container in the Exasol database
    - create UDFs for the new script-languages-container
    - run those UDFs
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
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
    ### Instantiate Script Languages Container

    The following cell creates an instance of class `ScriptLanguageContainer` from the notebook-connector,
    which enables using the`exaslct` in the AI Lab in a convenient way.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exasol.nb_connector.slc import ScriptLanguageContainer\nslc = ScriptLanguageContainer(secrets=ai_lab_config, name="sample_slc")', language="python", min_height=100)
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
    ## Use the new Script-Languages-Container

    ### Connect to the database and activate the container
    Once you have a connection to the database you can run either the ALTER SESSION statement or ALTER SYSTEM statement. The latter statement will activate the container permanently and globally.
    The `notebook` connector package provides a utility method, for creating an `pyexasol` connection and applying the `ALTER SESSION` command for all registered languages:
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
    ### Check if your customization did work

    You first create a helper UDF which allows you to run arbitrary shell commands inside of a UDF instance. With that you can easily inspect the container.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='import textwrap\n\nconn.execute(textwrap.dedent(f"""\nCREATE OR REPLACE {slc.language_alias} SCALAR SCRIPT execute_shell_command_py3(command VARCHAR(2000000), split_output boolean)\nEMITS (lines VARCHAR(2000000)) AS\nimport subprocess\n\ndef run(ctx):\n    try:\n        p = subprocess.Popen(ctx.command,\n                             stdout    = subprocess.PIPE,\n                             stderr    = subprocess.STDOUT,\n                             close_fds = True,\n                             shell     = True)\n        out, err = p.communicate()\n        if isinstance(out,bytes):\n            out=out.decode(\'utf8\')\n        if ctx.split_output:\n            for line in out.strip().split(\'\\\\n\'):\n                ctx.emit(line)\n        else:\n            ctx.emit(out)\n    finally:\n        if p is not None:\n            try: p.kill()\n            except: pass\n/\n"""))', language="python", min_height=100)
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
    Check with "pip list" if the "xgboost" package is installed
    We use our helper UDF to run `python3 -m pip list` directly in the container and get the list of currently available python3 packages.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='rs=conn.execute("""select execute_shell_command_py3(\'python3 -m pip list\', true)""")\nfor r in rs: \n    print(r[0])', language="python", min_height=100)
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
    Running `pip list` inside the container displays the available packages. In case of unexpected results, please have a look at the information stored by `exaslct` during build-time inside the container.

    #### Embedded Build Information of the Container
    Here we see an overview about the build information which `exaslct` embedded into the container. `exaslct` stores all packages lists (as defined in the flavor and what actually got installed), the final Dockerfiles and the image info. The image info describes how the underlying Docker images of the container got built. The build information is stored in the `/build_info` directory in the container.

    This command will show an overview of the build information:
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='rs=conn.execute("""select execute_shell_command_py3(\'find /build_info\', true)""")\nfor r in rs: \n    print(r[0])', language="python", min_height=100)
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
    Now you can examine the python3 pip packages file, which was created directly after building the container image by `exaslct`.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='rs=conn.execute("""select execute_shell_command_py3(\'cat /build_info/actual_installed_packages/release/python3_pip_packages\', true)""")\nfor r in rs: \n    print(r[0])', language="python", min_height=100)
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
    All your packages from the flavor-customization build step should be included. If you want to double check this, you can run:
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='rs=conn.execute("""select execute_shell_command_py3(\'cat /build_info/packages/flavor_customization/python3_pip_packages\', true)""")\nfor r in rs:\n    if r[0] is None:\n        print()\n    else:\n        print(r[0])', language="python", min_height=100)
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
    ### Testing the new package

    After you made sure that the required packages are installed, you need to try importing and using them. Importing is usually a good first test if a package got successfully installed, because often you might already get errors at this step. However, sometimes you only will recognize errors when using the package. We recommend to have a test suite for each new package to check if it works properly before you start your UDF development. It is usually easier to debug problems if you have very narrow tests.
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='conn.execute(textwrap.dedent(f"""\nCREATE OR REPLACE {slc.language_alias} SET SCRIPT test_xgboost(i integer)\nEMITS (o VARCHAR(2000000)) AS\n\ndef run(ctx):\n    import xgboost\n    import sklearn \n    \n    ctx.emit("success")\n/\n"""))\n\nrs = conn.execute("select test_xgboost(1)")\nrs.fetchall()', language="python", min_height=100)
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
    Finally, import and use the new packages. The following UDF uses the `xgboost` and `sklearn` modules to solve a small machine learning problem.
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='conn.execute(textwrap.dedent(f"""\nCREATE OR REPLACE {slc.language_alias} SET SCRIPT test_xgboost(i integer)\nEMITS (o1 DOUbLE, o2 DOUbLE, o3 DOUbLE) AS\n\ndef run(ctx):\n    import pandas as pd\n    import xgboost as xgb\n    from sklearn import datasets\n    from sklearn.model_selection import train_test_split\n    \n    iris = datasets.load_iris()\n    X = iris.data\n    y = iris.target\n    \n    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)\n    \n    dtrain = xgb.DMatrix(X_train, label=y_train)\n    dtest = xgb.DMatrix(X_test, label=y_test)\n    param = {{\n        \'max_depth\': 3,  # the maximum depth of each tree\n        \'eta\': 0.3,  # the training step for each iteration\n        \'silent\': 1,  # logging mode - quiet\n        \'objective\': \'multi:softprob\',  # error evaluation for multiclass training\n        \'num_class\': 3  # the number of classes that exist in this datset\n        }}\n    num_round = 20  # the number of training iterations\n    bst = xgb.train(param, dtrain, num_round)\n    preds = bst.predict(dtest)\n    \n    ctx.emit(pd.DataFrame(preds))\n/\n"""))\n\nconn.export_to_pandas("select test_xgboost(1)")', language="python", min_height=100)
    run_011 = mo.ui.run_button(label="Run cell 11")
    mo.vstack([editor_011, run_011])
    return editor_011, run_011

@app.cell
def _(editor_011, lesson, mo, render, run_011):
    mo.stop(not run_011.value)
    render(mo, lesson.run(editor_011.value))
    return

if __name__ == "__main__":
    app.run()
