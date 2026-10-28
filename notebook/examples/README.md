# Bundled Exasol Notebook Connector library

This directory contains the complete 50-notebook collection from the official Notebook Connector resources, pinned at the revision in `manifest.json`.

- `jupyter/`: all lessons as notebooks, with cleared outputs and the kit kernel/connection bootstrap.
- `marimo/`: the same lessons as Marimo apps. Editable code cells run explicitly in an IPython session, preserving variables, SQL magics and utility notebook execution. Original widget UI steps can be used in Jupyter.
- Supporting CSV, SVG, PNG and draw.io files and MIT notices travel with the collection.

`notebook/kit/notebooks.py` copies this directory's front-end trees under each installed collection's `exasol-examples/`, preserving existing user files. It copies the Marimo public image assets into that front end's public folder. Neither installation nor opening a notebook fetches source notebooks from GitHub.

Cloud/virtual-schema examples are reference only. GPU and extension/container provisioning examples require separate setup. The bundle changes no external-source or virtual-schema implementation.

Rebuild with `python3 tools/bundle_connector_notebooks.py /path/to/notebook-connector`, then run the library tests and Marimo checks. See the parent `INSTALL-AND-UPDATE.md` for user commands and update behavior.
