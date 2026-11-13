# Versions and semantic models (/data-scientist/monitor/versions-and-semantic-models)



This page covers two things that change together: the saved versions of a column map, and the semantic model that is built from the approved version.

## Versions, and restoring one [#versions-and-restoring-one]

Every approval is a new version. Nothing is overwritten.

* `nb.column_map_versions(id)` lists each version with its approval time, its roles, its slots and its evidence.
* `nb.current_version(id)` gives the approved one.
* In the quickstart's card, **History** lists the versions. **Restore** applies an older version's choices and saves them as a new version. The card says which version it restored and which new one it saved.
* In code, restoring means approving that version's roles again. The version the kit saves is the newest.

```python
versions = nb.column_map_versions("amazon_sales")   # every saved version, oldest first, with its roles
```

```bash
exakit describe <id> --versions
exakit describe <id> --show --version <n>
```

## Semantic models [#semantic-models]

Approving a column map rebuilds every semantic model its table is in, so AI clients read the same meaning. The model is in Exasol Semantic Views. The [semantic views page](/kit/data/semantic-views) describes the feature.

A link between tables is not part of a column map. So after you add or remove one, refresh the model yourself:

```python
nb.refresh_semantic(connection, "sales_360")    # rebuild a model the kit published
```

```bash
exakit describe --model sales_360 --refresh
```

`nb.semantic_models(connection)` lists every model in the database. If publishing fails, the approval still stands and the message says why. Run `exakit describe <id> --comments` to publish it again.

Back to [Monitor and iterate](/data-scientist/monitor). Next: [A training hand-off that went stale](/data-scientist/monitor/stale-hand-off).
