# Add-on modules for the preprocessor framework

Exasol has one global SQL preprocessor slot, and the framework's
`PREPROC_RT.MASTER` dispatcher holds it on every starter-kit database. An add-on
that needs to transform SQL never takes the slot itself: it registers its
transformation with MASTER as a module.

Each add-on that needs the slot gets a folder here:

```
modules/<add-on>/
  module.toml        # the framework's module manifest, plus a [kit] table
  <name>_v<N>.sql    # the module's artifact (a pinned module only)
```

The upstream add-on repository stays untouched; the adaptation lives in this
kit's packaging. Users never run `ALTER SESSION SET sql_preprocessor_script`.

The kit registers a module itself - verify its artifact, create its scripts,
`PREPROC.RULE_ENSURE` its rule, `PREPROC.MODULE_REGISTER` its provenance,
`PREPROC.REFRESH` - rather than through `PREPROC INSTALL MODULE ... FROM <url>`.
That command needs the framework's Python registry resolver, which the kit
leaves out: local deployments ship no script language container. A module's own
code is Lua (Exasol preprocessors are Lua); a module whose Lua calls a Python UDF
needs the Python container installed with it (`exasol slc install python3`).

## The modules

| Folder | Module | Phase | Scope | Artifact |
|---|---|---|---|---|
| `semantic-views` | `PREPROC_RT.SEMANTIC_VIEWS_V1` | EXPAND | ROLE PUBLIC | pinned: a thin entry that calls Semantic Views' own runtimes |
| `json-tables` | `PREPROC_RT.JSON_TABLES_V<N>` | TRANSLATE | ROLE PUBLIC | generated per database by `generate.py`: JSON Tables' own rewriter and the configuration of every installed wrapper |

dash-server, dbt-exasol, exasol-scheduler and exasol-vscode do not transform
SQL, and neither does json-tables ingest: only its wrap (`wrap install`, `wrap
deploy`, `ingest-and-wrap`) makes JSON syntax to rewrite. The kit's
`exasol-json-tables` launcher rebuilds and registers the module after each
successful one, so a new wrapper is the module's next version; the add-on's
install and update, and the framework's verify pass (its [kit] generator), do
the same. json-tables is also the one module that catches its add-on's error:
the framework would swallow JSON Tables' clear refusal of a mistyped path and run
the statement unchanged, so the entry fails the statement with exactly that
message instead (see the comment in `json_tables.sql.tmpl`).

## module.toml

The framework's fields (`name`, `description`, `phase`, `script_name`,
`function`, `version`, `min_framework`, `deploy_mode`, `sha256`,
`suggested_scope`, `[source]`, `[[objects]]`; see the framework's
docs/module-authoring.md), and:

```toml
[kit]
addon = "<add-on id>"              # the folder name
label = "<name in messages>"
receipt = "components.<key>"       # installed = kit-owned, a version, not mid-install
artifact = "<name>_v<N>.sql"       # a pinned module: sha256 above is its digest
# or, for a module the add-on builds for this database:
generated = true                   # object names carry {VERSION}; no version/sha256
generator = ["{python}", "...", "{out}"]   # optional: writes the artifact to {out}
                                           # ({kit_root} {home} {exapump} {profile} too)
```

The rule's scope is `suggested_scope`. ROLE `PUBLIC` reaches every user: the
framework resolves PUBLIC to each user in the database on every refresh, so the
administrator, the MCP read-only login and Dash Server get the module, and a
database user created later gets it after the next `exakit update`, whose
verify pass refreshes.

## The mechanism

One implementation, `setup/preprocessor/manage.py`, shared by every platform:

```
manage.py register-module --exapump BIN --profile NAME --manifest FILE ADDON
                          [--artifact FILE] [--note TEXT] [--log FILE]
manage.py retire-module   --exapump BIN --profile NAME --manifest FILE ADDON [--log FILE]
```

Exit 0 done (or nothing to do), 1 failed, 5 skipped: the framework is declined
(the user's own preprocessor holds the slot), not set up yet, or not in this
database, or the add-on is not installed. A skip is never a failure of the
add-on. Every statement runs behind `ALTER SESSION SET sql_preprocessor_script =
''`, and one registration runs at a time.

- Registering an unchanged module is one read and changes nothing.
- A pinned module whose version is deployed with other content is refused: a
  changed module ships as a new version.
- A generated module whose artifact changed is deployed as the next `_V<N>`;
  its rule is repointed, the rules refreshed, the old version retired and then
  reclaimed by the framework's guarded `MODULE_RECLAIM`. A live module is never
  replaced in place.
- Retiring drops the module's rules, refreshes and retires its provenance.

Add-ons call it through `marketplace/preprocessor_modules.py`.

## Lifecycle

- add-on install or update: install the add-on, then register its module
- the framework's install or verify (`manage.py ensure`, every installer pass
  and `exakit update`): registers every installed add-on that has a folder here.
  This is how a framework that arrives after the add-on (a 0.2.5 -> 0.3.0
  update), or one that was declined and later set up, picks its add-ons up.
- add-on uninstall: retire the module first, then remove the add-on
