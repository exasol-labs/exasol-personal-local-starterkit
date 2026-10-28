import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('script_languages_container/utils/file_system_ui.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: File System Ui

    Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/script_languages_container/utils/file_system_ui.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'script_languages_container/utils/file_system_ui.ipynb')", language="python", min_height=100)
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
    editor_002 = mo.ui.code_editor(value='from pathlib import Path\nfrom typing import List\nfrom IPython.display import Code, display, FileLink, FileLinks\nimport os\n\nimport os\nimport contextlib\nfrom pathlib import Path\n\ndef show_directory_content(p: Path, max_depth: int = 1):\n    for path in p.iterdir():\n        if path.is_file():\n            display(FileLink(str(os.path.relpath(path))))\n        if path.is_dir() and max_depth > 1:\n            show_directory_content(path, max_depth - 1)\n\ndef show_files(paths: List[Path]):\n        for path in paths:\n            if path.is_file():\n                display(FileLink(str(os.path.relpath(path))))\n\ndef tail_file(path: Path, length: int):\n    with open(path) as f:\n        lines = f.readlines()\n        print("".join(lines[-length:]))\n\ndef show_docker_file(path: Path):\n    display(Code(filename=str(path), language="Docker"))\n\ndef show_pip_file(path: Path):\n    display(Code(filename=str(path), language="toml"))', language="python", min_height=100)
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
