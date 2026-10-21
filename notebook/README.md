# The notebook add-on's content

| Path | What it is |
|---|---|
| `catalog.json` | Which notebooks the kit ships, for which persona, in which order |
| `notebooks/<name>.py` | A notebook's source (jupytext percent format); `<name>.ipynb` is built from it |
| `marimo/<name>.py` | The same notebook for Marimo, converted from the `.ipynb` |
| `package/exakit_nb/` | The helpers every notebook imports: `conn = exakit_nb.connect()` |
| `kit/` | The scripts both installers run (the store, the kernel, placing the notebooks, Marimo) |

On a machine, `exakit marketplace notebook` copies each notebook into
`~/.exasol-starter-kit/notebooks/starter-kit-notebooks/<persona>/` (and the
Marimo ones into `notebooks/marimo/<persona>/`), with a README naming the
end-to-end path. A file already there is the user's and is never overwritten.

## Adding a notebook

No code. Three steps:

1. Write `notebooks/<name>.py` and build it: `python3 tools/notebooks.py`
   (`--marimo` also writes `marimo/<name>.py`; it needs uv).
2. Add one entry to `catalog.json`:

   | Key | Value |
   |---|---|
   | `id` | the notebook's id |
   | `persona` | the persona folder it goes in: an id from `personas/` |
   | `step` | its place in the end-to-end path (lowest first) |
   | `title`, `summary`, `needs` | what the README says about it |
   | `jupyter` | its `.ipynb` file name |
   | `marimo` | its Marimo file name (optional) |

3. `bash tests/notebook-addon.sh` checks that every entry's files exist and
   that no notebook holds an address or a credential; `tests/personas.sh`
   checks the persona exists.

A new persona is one file in `personas/` (see `personas/README.md`); a new
dataset is one folder in `data/datasets/` (see `data/README.md`).
