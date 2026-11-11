# Define your own persona (/kit/personas/define-your-own)



A persona is one file, `personas/<id>.json`, in the kit's repository. No installer code names a persona, so adding a file is the whole change.

## Try it first [#try-it-first]

`tools/try_persona.sh` runs a persona in a sandbox that changes nothing. `personas/examples/analyst.json` is a ready-made one to start from.

```bash
bash tools/try_persona.sh personas/examples/analyst.json
```

```bash
bash tools/try_persona.sh personas/examples/analyst.json --ask
```

The first shows the checks, the question, the answers and the data table. The second then asks the install question live.

## The keys [#the-keys]

| Key                | Value                                                                                                                              |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `schema_version`   | `1`                                                                                                                                |
| `id`               | The file name without `.json`                                                                                                      |
| `title`, `summary` | What `exakit persona list` and the install question show                                                                           |
| `picker`           | `true` to offer it in the install question                                                                                         |
| `visible`          | `true` to offer new selections. `false` hides it and refuses a new add, while keeping the definition and an existing installation. |
| `default`          | `true` to tick it to begin with                                                                                                    |
| `order`            | Where the question lists it, lowest first                                                                                          |
| `datasets`         | A list of dataset ids, or `"all"` or `"none"`                                                                                      |
| `mcp_clients`      | `"all"`, `"skip"`, or a list of client ids                                                                                         |
| `addons`           | A list of add-on ids, or `"all"` or `"none"`                                                                                       |
| `addon_reasons`    | Optional. One line per add-on, at most 90 characters, saying what it does for this persona                                         |
| `notebook_tools`   | Optional. Which notebook tools to tick, for example `["jupyterlab", "marimo"]`                                                     |
| `services`         | Optional. Kit services the persona starts at login, for example `["mlflow"]`                                                       |
| `udf_language`     | Optional. `python` or `rust`                                                                                                       |
| `first_prompt`     | Optional. What to do first, shown by `exakit persona show`                                                                         |

## Rules [#rules]

* **No secrets and no machine paths.** A persona names things, it never holds them.
* **It appears where `order` puts it** when `visible` and `picker` are true.
* **Its notebooks** go in `notebook/notebooks/<id>/`, listed in `notebook/catalog.json`.
* **Its documentation** goes in `notebook/docs/content/docs/<id>/`. See [These docs](/data-scientist/develop/docs-site).

## Checks [#checks]

```bash
bash tests/personas.sh
```

It validates every persona file against the datasets and add-ons this kit ships. `tests/personas-ps.ps1` checks that the Windows side reads the files the same way.
