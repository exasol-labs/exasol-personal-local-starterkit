# What the kit writes (/security/what-the-kit-writes)



The kit writes to two places: your database and your computer. This page lists what it creates, what it changes, and what it will not touch.

## Schemas in the database [#schemas-in-the-database]

| Schema or object                                        | What it holds                                                                                                                                                        | Created by                                                                                                                                                               |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `STARTER_KIT`                                           | The default schema of the read-only user, where local uploads land. Created if it is missing                                                                         | `exakit_configure_mcp_readonly_access()`, `setup/lib/common.sh`                                                                                                          |
| The sample dataset schemas, such as `AMAZON` and `TPCH` | The bundled sample data. Created by each dataset's own `01_create_schema.sql` in `data/datasets/<name>/`                                                             | `exakit data-load <name>`                                                                                                                                                |
| `EXAKIT_PREPARED`                                       | Joined views and typed, cleaned views you choose to create                                                                                                           | `SCHEMA = "EXAKIT_PREPARED"` in `notebook/package/exakit_nb/prepare.py`, and `CREATE SCHEMA IF NOT EXISTS EXAKIT_PREPARED` in `notebook/package/exakit_nb/schema_map.py` |
| `SEMANTIC_CATALOG`, `SEMANTIC_ADMIN`, `SEMANTIC_AGENT`  | Exasol Semantic Views' own schemas. `SEMANTIC_CATALOG` holds the models' metadata, which any read-only client can read, for example `SEMANTIC_CATALOG.RELATIONSHIPS` | `setup/lib/descriptor/schema.py` and `setup/lib/descriptor/publish.py`                                                                                                   |
| `SEM_<MODEL>`                                           | A published semantic model's views                                                                                                                                   | `setup/lib/descriptor/publish.py`                                                                                                                                        |
| `VS_<NAME>`, and a CONNECTION named `EXAKIT_SRC_<NAME>` | An external source's virtual schema, and its connection                                                                                                              | `setup/virtual-schemas/engine/plan.py`, where `"connection": "EXAKIT_SRC_%s"` and `"schema": "VS_%s"` are set                                                            |

## Your tables [#your-tables]

The kit changes a table you own only when you tell it to. Three paths can do so.

**Loading a file (`exakit data-load`, `nb.load_own_file()`).** The kit does not overwrite a table it did not load. `load_own_file()` in `notebook/package/exakit_nb/own_file.py` stops with "already exists and was not loaded by load_own_file" unless you pass `replace=True`. For `exakit data-load`, `EXAKIT_ON_EXISTING` decides:

* `skip`, the default. A table with rows the kit did not load is left alone. The command exits with code 5 and changes nothing (`setup/lib/exapump.sh`).
* `replace`. The table is dropped and rebuilt from the file. The code comment says "DROP, not TRUNCATE". The load receipt is removed with it.
* `append`. The file's rows are added on top of the existing rows.

**Writing SQL from the terminal (`exakit sql --write`).** This runs as the admin, so it can change any table. See [AI clients](/security/ai-clients).

**Approving a column map.** Approval writes a descriptor under `~/.exasol-starter-kit/descriptors/`. It changes the database only through Semantic Views, in the schemas listed above.

### Comments the kit adds [#comments-the-kit-adds]

When the kit loads a file, it marks the table with `COMMENT ON TABLE`. The mark holds the file's SHA-256, and it is written only on a table the kit has just created or replaced. That mark is how the kit recognises a table it loaded, so a later load can skip it. Outside that load, the kit issues no `ALTER TABLE` and no other `COMMENT ON`. A search of `setup/` and `notebook/package/exakit_nb/` confirms this. The `replace` and `append` paths above are the exception, because you chose them.

`setup/lib/descriptor/schema.py` states the same rule for schema maps: "the user's own schema and tables are never commented or altered."

## Files on this computer [#files-on-this-computer]

Everything is under the kit home, `~/.exasol-starter-kit` (or `EXAKIT_HOME`). Three rules apply to the files there:

* **Secrets** are in `credentials/`. See [Credentials](/security/credentials).
* **Logs and records** are written at mode 600 on Unix. The workflow log is opened with `os.open(..., 0o600)` in `notebook/package/exakit_nb/workflow.py`. The virtual schema log is "created owner-only (mode 600)" according to `setup/virtual-schemas/engine/vslog.py`.
* **Hand-off bundles** get mode 700 for folders and 600 for files, set by `handoff_bundle.py`. Those modes are not applied on Windows, which the code checks with `os.name != "nt"`.

### The approved column maps [#the-approved-column-maps]

Each approved column map is kept as a version, in `~/.exasol-starter-kit/descriptors/<SCHEMA>.<TABLE>/`. The module docstring of `setup/lib/descriptor/store.py` gives the layout:

* `v<n>.yaml` is written exclusively. "A version file is created exclusively, so v(n) is never touched." An approval never rewrites an earlier version.
* `current.yaml` is replaced through a temporary file and `os.replace`.
* `draft.yaml` and `profile.json` hold the work in progress. The profile has no value of a sensitive column.

A whole schema's map (its tables and the links between them) is kept the same way, in `descriptors/<SCHEMA>/`, with `v<n>.json` files. `setup/lib/descriptor/schema.py` says those are never rewritten.

### The shell profile [#the-shell-profile]

The installer adds the kit's `bin` folder to your shell profile, through `ensure_path_hint()` in `setup/lib/common.sh`. If `EXAKIT_NO_PROFILE_EDIT=1` is set, it prints the line for you to add instead. The full uninstall leaves that line in place, as the comment above `exakit_uninstall_run()` in `setup/lib/common.sh` says. Remove the line yourself if you want it gone.

## What the kit leaves alone [#what-the-kit-leaves-alone]

* A table holding rows the kit did not load, unless you choose `replace` or `append`.
* A notebook you edited. The [Notebooks](/kit/tools/notebooks) page says an edited notebook is never overwritten.
* Approved column maps, workflow logs and bundles. The [Where things live](/data-scientist/development/where-things-live) page says an update leaves them alone.
* An add-on installation the kit did not make. See [Add-ons and downloads](/security/add-ons-and-downloads).

## Limits [#limits]

* `exakit data-load` with `replace` drops a table you own. On a terminal you are asked which policy applies. Without a terminal the policy is `skip`, unless `EXAKIT_ON_EXISTING` says otherwise.
* `exakit sql --write` can change any table, as the admin.
* On Windows, the Unix modes above are not applied. The NTFS permissions described in [Credentials](/security/credentials) are the protection there.
* The virtual schema log removes its files older than `KEEP_DAYS` when a new day's file is opened (`setup/virtual-schemas/engine/vslog.py`). This page found no pruning rule for the other logs.
