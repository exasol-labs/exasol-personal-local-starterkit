import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('script_languages_container/advanced.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Advanced topics

    Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/script_languages_container/advanced.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'script_languages_container/advanced.ipynb')", language="python", min_height=100)
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

    # Advanced topics
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    This notebooks explains some details and background regarding the tool `exaslct`. This is especially useful when:
    - you encounter a problem when running one of the other notebooks in this tutorial.
    - you need to clean up disk space.
    - you want to do more modifications to the script-languages-container than just adding a Python package.
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
    ### Preparation 
    Before you start, run the export command (again), just to be sure to have all the artifacts (local files and docker images), which are necessary for this tutorial.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='slc.export()', language="python", min_height=100)
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
    ## What to do if something doesn't work?

    During the build, export or upload it can happen that external package repositories are not available or something is wrong on your machine running the build. For these cases, `exaslct` provides extensive log files that can help analyzing such problems.

    #### Exaslsct Log
    The main log file for `exaslct` is stored as file `main.log` in the build output of the job. With the following command you can find the main logs for all previous executions.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value="main_logs = list(slc.workspace.output_path.glob('**/main.log'))\nshow_files(main_logs)", language="python", min_height=100)
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
    The following command shows the log file of the last execution.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='tail_file(main_logs[0], 20)', language="python", min_height=100)
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
    #### Build Output Directory

    More detailed information about the build or other operations can be found in directory `.build_output/jobs/*/outputs`. Here each run of `exaslct` creates its own subdirectory under `.build_output/jobs`. Directory `outputs`  contains the outputs and log files (if any) produced by each of the executed tasks of `exaslct`. Especially, the Docker tasks such as build, pull and push store the logs returned by the Docker API. This can be helpful for analyzing problems during the build.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value="all_logs = list(slc.workspace.output_path.glob('**/*.log'))\nshow_files(all_logs)", language="python", min_height=100)
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
    <a id='flavor_definition'></a>
    ## Flavor Definition
    The following diagram shows a high level overview of the build steps for a script languages container.

    Building an SLC usually starts with selecting one of the default build templates provided by Exsol.
    These templates are called _flavors_. In this tutorial we customize the template Python flavor by adding new pip packages.


    ![image.png](slc_main_build_steps.svg)





    The easiest way to customize a flavor is to add dependencies in the build step `flavor_customization`. Other build steps should only be changed with caution and is only required in special cases, e.g. when dependencies are defined in other build steps because the script client depends on these dependencies.
    Check the directory structure of the selected flavor:
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='show_directory_content(slc.flavor_path, 3)', language="python", min_height=100)
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
    For example, if you need additional apt packages, you can add those to the flavor_customization step in the `template-Exasol-all-python-3.12/packages.yml` file.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Build Cache

    `exaslct` internally uses a build cache in order to accelerate the build by re-using docker images, which were built during a previous execution.
    Customizing a flavor always creates a separate entry in the cache with a unique hashcode and old containers don't get lost. If you revert your changes the system automatically uses the existing cached container. Below you can see the content of the cache directory for the containers.
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='show_directory_content(slc.workspace.output_path / "cache" / "exports")', language="python", min_height=100)
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
    `exaslct` also creates a docker image for each particular build step (see [Flavor Definition](#flavor_definition)), you can find the images with the following code:
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='slc.docker_image_tags', language="python", min_height=100)
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
    Image `exasol/script-language-container:template-Exasol-all-python-3.12-release_...` is the final release image for the script-language-container, the other (intermediate) images are used for the caching mechanism.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Cleanup

    This sections shows how you can use the instance of `ScriptLanguageContainer` class to clean up the artifacts created by `exaslct`:
    - The docker images for the script-languages-container as well as the cache images
    - The exported containers (tar gz files)
    - The cached container files
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Clean up the docker images

    The following command cleans up the docker images.
    **Be aware that this command deletes all script-languages-container related docker images on the running host, even those created by other notebooks or users.**
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value='slc.clean_docker_images()', language="python", min_height=100)
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
    ### Clean up the local exported containers

    The following command cleans up the exported container files:
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='slc.workspace.cleanup_export_path()', language="python", min_height=100)
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
    ### Clean up the output path

    Clean up the log files and caches:
    """)
    return

@app.cell
def _(mo):
    editor_014 = mo.ui.code_editor(value='slc.workspace.cleanup_output_path()', language="python", min_height=100)
    run_014 = mo.ui.run_button(label="Run cell 14")
    mo.vstack([editor_014, run_014])
    return editor_014, run_014

@app.cell
def _(editor_014, lesson, mo, render, run_014):
    mo.stop(not run_014.value)
    render(mo, lesson.run(editor_014.value))
    return

if __name__ == "__main__":
    app.run()
