# Installing and updating the notebook collection

The Notebook add-on has three parts:

1. **Notebook Connector**: Exasol's Python package, `exasol-notebook-connector`, installed from PyPI at the version tested in `versions.json`.
2. **Notebook tools and helpers**: JupyterLab, Marimo, the Exasol kernel, the kit's `exakit.nb` helpers and companion packages, installed together into the kit's `notebook-venv` environment.
3. **Bundled notebook files**: the persona notebooks and the full 50-lesson Exasol example collection, shipped with the starter-kit source. Opening or installing the collection does not fetch notebook files from GitHub.

Install on an existing kit:

```sh
exakit marketplace notebook
exakit notebook check
exakit notebook
exakit notebook marimo
```

The Data Scientist and ML Engineer personas both include the Notebook add-on, so a persona install performs the same setup. You do not need a separate pip installation.

The bundled library is installed here, beneath the kit home:

- `notebooks/starter-kit-notebooks/exasol-examples/00_library.ipynb`
- `notebooks/marimo/exasol-examples/00_library.py`

The starter page lists every lesson and its prerequisites. Tutorial tables use `EXAKIT_EXAMPLES`. The original widgets are available in Jupyter; Marimo provides editable cells and individual Run buttons with a shared Python/IPython session, including SQL magics. GPU and extension examples require additional setup. Cloud and virtual-schema lessons are reference material, and their integrations are not configured by this bundle.

Update:

```sh
exakit version
exakit update
exakit notebook check
```

`exakit update` first brings in the starter-kit release and then its tested component versions. A kit release can contain new notebook files even when the connector version stays the same.

To refresh only the Notebook add-on using the kit source already installed:

```sh
exakit update notebook
```

This refreshes the connector, notebook tools and helpers and copies any missing bundled files. It cannot obtain a new notebook collection that has not yet shipped in your installed kit source. Existing notebook files are preserved, including edits. A file deliberately deleted from an existing collection is not restored automatically. These rules also apply to the full example library.

Maintainers update the library from a reviewed, pinned Notebook Connector checkout with:

```sh
python3 tools/bundle_connector_notebooks.py /path/to/notebook-connector
```

The tool bundles all 50 notebooks, supporting files, source revision and MIT notices; adapts the local connection; and builds Marimo apps that retain IPython magics. The generated files are tested and released with the kit. Source bookkeeping remains inside the kit, outside the notebook folders shown to users.

These additions are currently local work. Use the local-checkout install command in `MANUAL-RUNBOOK.md` until this version is published.
