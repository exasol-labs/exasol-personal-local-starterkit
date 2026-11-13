# Add-ons (/kit/tools/add-ons)



Add-ons are optional tools around the database: dashboards, notebooks and more. A persona installs the ones it needs. You can add or remove any of them later.

## See what there is [#see-what-there-is]

```bash
exakit marketplace --list
```

Every add-on is listed with its state, its version and what it is. Nothing is installed. Add `--json` for a script.

The name, the link and the About text of an add-on come from its own repository on GitHub, as last looked up. When a lookup fails, the kit's own copy is shown.

## Install [#install]

```bash
exakit marketplace                 # choose in a menu: Space selects, Enter installs
exakit marketplace dash-server     # install exactly this one
```

<Callout>
  Without a terminal, a bare `exakit marketplace` installs nothing. Name the add-ons, or answer up front: `EXAKIT_MARKETPLACE_ADDONS=dash-server exakit marketplace`.
</Callout>

## Start, stop and check [#start-stop-and-check]

Some add-ons are services, such as the dashboard server.

```bash
exakit start dash-server
exakit stop dash-server
exakit status
exakit logs dash-server
```

`exakit start` with no name starts the database and every enabled add-on service.

After an install, `exakit status` shows whether a service add-on is running, and `exakit help <add-on>` prints its full reference.

## Update and remove [#update-and-remove]

```bash
exakit update                  # apply the updates that are waiting
exakit update notebook         # one component
exakit uninstall dash-server   # remove one add-on
```

`exakit uninstall` takes `--dry-run` to preview what would be removed.

## Help for one add-on [#help-for-one-add-on]

```bash
exakit help dash-server
```

The full reference of an installed add-on is on this computer.

## From a notebook [#from-a-notebook]

```python
nb.addons()                      # every add-on and its state
nb.addon_ready("dash-server")    # install it when missing, start it when stopped
nb.kit_update()                  # bring the kit and its add-ons up to date
```

The Home card's **Marketplace** tab does the same with buttons. See [Run the kit from a notebook](/data-scientist/set-up).

<Callout>
  A tool you installed yourself is recognised and never offered again.
</Callout>

## The add-ons [#the-add-ons]

Each entry gives what the add-on is (the one line the catalog holds), how the kit installs it, its repository, and its documentation. Where the kit pins a version or a SHA-256 digest for an add-on, [Add-ons and downloads](/security/add-ons-and-downloads) lists it.

### dash-server [#dash-server]

* **What it is:** Agent-operated Dash hosting for live analytical apps.
* **Install:** `exakit marketplace dash-server`
* **Repository:** [exasol-labs/dash-server](https://github.com/exasol-labs/dash-server)
* **Documentation:** [repository README](https://github.com/exasol-labs/dash-server#readme).

### dbt-exasol [#dbt-exasol]

* **What it is:** Data Build Tool adapter for Exasol.
* **Install:** `exakit marketplace dbt-exasol`
* **Repository:** [exasol/dbt-exasol](https://github.com/exasol/dbt-exasol)
* **Documentation:** [dbt's Exasol setup page](https://docs.getdbt.com/docs/core/connect-data-platform/exasol-setup), and the [repository README](https://github.com/exasol/dbt-exasol#readme).

### exasol-scheduler [#exasol-scheduler]

* **What it is:** Lightweight table-driven SQL job scheduling for Exasol.
* **Install:** `exakit marketplace exasol-scheduler`
* **Repository:** [exasol-labs/exasol-scheduler](https://github.com/exasol-labs/exasol-scheduler)
* **Documentation:** [repository README](https://github.com/exasol-labs/exasol-scheduler#readme).

### exasol-vscode [#exasol-vscode]

* **What it is:** A Visual Studio Code extension for working with Exasol databases. Provides comprehensive database management, intelligent SQL editing, and powerful query execution capabilities.
* **Install:** `exakit marketplace exasol-vscode`. If you installed the extension yourself, the kit leaves it as yours and does not replace it.
* **Repository:** [exasol-labs/exasol-vscode](https://github.com/exasol-labs/exasol-vscode)
* **Documentation:** [repository README](https://github.com/exasol-labs/exasol-vscode#readme).

### json-tables [#json-tables]

* **What it is:** Exasol JSON Tables: ingest, query, and reshape JSON-shaped data in Exasol.
* **Install:** `exakit marketplace json-tables`
* **Repository:** [exasol-labs/exasol-json-tables](https://github.com/exasol-labs/exasol-json-tables)
* **Documentation:** [repository README](https://github.com/exasol-labs/exasol-json-tables#readme), and Exasol's [JSON functions](https://docs.exasol.com/db/latest/sql_references/functions/json.htm).

### semantic-views [#semantic-views]

* **What it is:** A database-native semantic layer for Exasol.
* **Install:** `exakit marketplace semantic-views`. The first approval of a column map installs it into the database if it is missing, as [Semantic Views](/kit/data/semantic-views) describes.
* **Repository:** [exasol-labs/exasol-semantic-views](https://github.com/exasol-labs/exasol-semantic-views)
* **Documentation:** [repository README](https://github.com/exasol-labs/exasol-semantic-views#readme).

### notebook [#notebook]

* **What it is:** Connection configuration management and additional tools for Jupyter notebooks.
* **Install:** `exakit marketplace notebook`. It offers two front ends, JupyterLab and Marimo. See [Notebooks](/kit/tools/notebooks).
* **Repository:** [exasol/notebook-connector](https://github.com/exasol/notebook-connector)
* **Documentation:** [repository README](https://github.com/exasol/notebook-connector#readme). The driver the notebooks use is documented in Exasol's [PyExasol page](https://docs.exasol.com/db/latest/connect_exasol/drivers/python/pyexasol.htm).

### udf-devkit [#udf-devkit]

* **What it is:** Run Python and Rust code inside the database: UDF containers, model files in BucketFS, a local MLflow. The kit writes this line in place of its repository's About text, because the repository is the upstream it is built on.
* **Install:** Not available in this release. The catalog marks the add-on `visible: false`, and `exakit marketplace udf-devkit` refuses it with "is disabled in marketplace/catalog.json".
* **Repository:** [exasol/script-languages-release](https://github.com/exasol/script-languages-release). This is the upstream repository the kit builds its containers from.
* **Documentation:** Exasol's [user-defined functions](https://docs.exasol.com/db/latest/database_concepts/udf_scripts.htm), [Python in UDFs](https://docs.exasol.com/db/latest/database_concepts/udf_scripts/python3.htm), and [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm).
