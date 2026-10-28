import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('script_languages_container/customize.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Customize a flavor

    Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/script_languages_container/customize.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'script_languages_container/customize.ipynb')", language="python", min_height=100)
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

    # Customize a flavor

    Sometimes you need very specific dependencies or versions of dependencies in the Exasol UDFs. In such case you can customize a Script-Language Container.
    You find additional information in the [Exasol official documentation](https://docs.exasol.com/db/latest/database_concepts/udf_scripts/adding_new_packages_script_languages.htm#).
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
    ### Instantiate ScriptLanguagesContainer

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
    ### Import some utility functions
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='%run ./utils/file_system_ui.ipynb', language="python", min_height=100)
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
    ### Flavor Customization Build Step

    `exasclt` consists of multiple build steps. By a build step here we mean a file structure which serves as an input for a certain stage of the building process of the script-languages-container. See [Advanced Topics](/?file=exasol-examples/script_languages_container/advanced.py) for more details.

    Build step **flavor_customization** is defined by a Dockerfile and several package lists. We recommend to add new packages to the package lists and only modify the Dockerfile if you need very specific changes, like adding additional resources.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='show_directory_content(slc.flavor_path / "flavor_customization")', language="python", min_height=100)
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
    The Dockerfile consists of two parts. The first part installs the packages from the package lists and should only be changed with care. The second part is free for your changes. Read the description in the Dockerfile carefully to find out what you can and shouldn't do.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    #### Package Lists

    Before we use the package list file, we run the restore method from class `ScriptLanguageContainer`, which reverts any possible modifications of the file.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='slc.restore_public_package_file()\nslc.restore_internal_package_file()', language="python", min_height=100)
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
    The packages are listed in an yaml file named packages.yml. There are multiple logical sections in it like build-step, phase and so on. We recommend to install a specific package using one of the append_package variants. Also, it is better to specify the version to avoid surprises about which version actually got installed later.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='show_files([slc.public_package_file])', language="python", min_height=100)
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
    We are now going to append Python package "xgboost" to packages.yml by creating a PipPackage instance and passing it to append_custom_pip_packages.

    Notes:
     - running the following command multiple times will iteratively append the packages
     - you can also click on the link and modify the file directly
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='from exasol.exaslpm.model.package_file_config import PipPackage\nxgboost_pkg = PipPackage(name="xgboost", version="==2.0.3")\nscikit_learn_pkg = PipPackage(name="scikit-learn", version="==1.5.0")\nslc.append_custom_pip_packages([xgboost_pkg, scikit_learn_pkg])\nshow_files([slc.public_package_file])', language="python", min_height=100)
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
    #### Rebuilding the customized Flavor

    After changing the flavor you need to rebuild it. You can do it by running `export` again. Exaslct automatically recognizes that the flavor has changed and builds a new version of the container. Don't get confused by the warnings: `exaslct` first tries to find the cached docker images (see [Advanced Topics](/?file=exasol-examples/script_languages_container/advanced.py)), but as the content has changed, the cached image is not available, and the docker service returns a 404 error message.
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='slc.export()', language="python", min_height=100)
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
    Lets check the resulting tar gz file:
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='show_directory_content(slc.workspace.export_path)', language="python", min_height=100)
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
    #### Deploy the Container to the Database
    To use the new container you need to upload it to the BucketFS. If the build machine has access to the BucketFS you do it with the `exaslct` upload command, as shown below. Otherwise you need to install the script-languages-container manually: 
    1. Transfer the container tar gz file of the previous step to a machine that has access to the BucketFS. 
    2. From that machine upload it via curl, as described in our [documentation](https://docs.exasol.com/db/latest/database_concepts/udf_scripts/adding_new_packages_script_languages.htm).

    With the following command you upload the new script language container.
    You could run the same on the command line with the `exaslct` tool:
    ```
    cd <slc_dir>
    ./exaslct deploy --flavor-path flavors/<flavor_path> --bucketfs-host <bucketfs_host> --bucketfs-port <bucketfs_port> --bucketfs-user <bucketfs_username> --bucketfs-password <bucketfs_password> --bucketfs-name <bucketfs_name> --bucket <bucket_name>
    ```
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='slc.deploy()', language="python", min_height=100)
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
    This command also stores the activation statement in the ai-lab-config. You can verify it with:
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value='slc.activation_key', language="python", min_height=100)
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
    The syntax of the activation statement is: `alias=url`. The activation key will be used in the `ALTER_SESSION` or `ALTER_SYSTEM` commands to "register" the script-language-container for usage in the UDFs.

    You can generate the SQL commands for the activation with the following command line:
    ```
    cd <slc_dir>
    ./exaslct generate-language-activation --flavor-path flavors/<flavor_path> --bucketfs-name <bucketfs_name> --bucket-name <bucket_name> --container-name <container_name> --path-in-bucket <path_in_bucket>
    ```
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    The class `ScriptLanguageContainer` also provides a method to generate the activation statement without having the container deployed onto the database. The bool parameter indicates if the generated activation statement should be automatically stored to the ai-lab-config or not.
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='slc.generate_activation_key(True)', language="python", min_height=100)
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
    You can now continue [testing the uploaded container](/?file=exasol-examples/script_languages_container/test_slc.py).
    """)
    return

if __name__ == "__main__":
    app.run()
