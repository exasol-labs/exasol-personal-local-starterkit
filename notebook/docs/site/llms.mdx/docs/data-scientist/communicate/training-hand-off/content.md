# The training hand-off (/data-scientist/communicate/training-hand-off)



## The training hand-off [#the-training-hand-off]

The training hand-off is the ML Engineer's file. It is one JSON file with the feature view, the target, the split and the training SQL. The Data Scientist notebooks do not write it. The ML Engineer's notebook writes one if none exists.

```python
path = nb.write_handoff(conn, ds)     # writes the file and returns its path
```

`nb.write_handoff(conn, ds)` writes the file to `~/.exasol-starter-kit/handoffs/<id>-v<n>.json`, where `<n>` is the descriptor's version. `nb.read_handoff` reads it back. The file names a table, columns, SQL and digests. It never names a host, a user or a password.

## The split [#the-split]

Two rules decide how the rows are split for training:

* **A date in the column map gives a time split.** This is the default. The oldest rows train the model and the newest rows test it.
* **No date means no time split.** The kit refuses a time split that the data cannot support, and names the fix. A dataset with no date, such as `fraud_transactions`, needs a split named on purpose: `nb.write_handoff(conn, ds, split="random")`.

The kit does not choose a random split for you. `split="random"` is a reproducible hash of each row's role columns, so the same rows always give the same split.

## When the hand-off goes stale [#when-the-hand-off-goes-stale]

A hand-off that no longer matches the column map or the data is refused. The check and the fix are on [A training hand-off that went stale](/data-scientist/monitor/stale-hand-off).

Back to [Communicate and deploy](/data-scientist/communicate). Next: [Deploying a model](/data-scientist/communicate/deploying-a-model).
