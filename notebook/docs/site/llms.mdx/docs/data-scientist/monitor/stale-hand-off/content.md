# A training hand-off that went stale (/data-scientist/monitor/stale-hand-off)



## A training hand-off that went stale [#a-training-hand-off-that-went-stale]

The training hand-off is written with `nb.write_handoff` on the ML Engineer's side, and read by the training step. A hand-off is a snapshot. When the column map or the rows change after it was written, the hand-off is stale. The kit can tell you that, and refuses to train on it.

<Flow
  caption="A training hand-off that went stale"
  steps="[
  { title: &#x22;You write a training hand-off&#x22;, text: &#x22;The feature view, the target and the split, in one file&#x22;, code: &#x22;nb.write_handoff(conn, ds)&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The data or the column map changes&#x22;, text: &#x22;A new version, or new rows&#x22;, tone: &#x22;db&#x22; },
  { title: &#x22;The kit compares them&#x22;, text: &#x22;The descriptor version and digest first, then the data digest&#x22;, code: &#x22;nb.handoff_is_stale(conn, handoff, ds)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;It names what changed&#x22;, text: &#x22;The line says what changed, and the fix&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You write it again&#x22;, text: &#x22;A new file, and the old one stays&#x22;, code: &#x22;nb.write_handoff(conn, ds)&#x22;, tone: &#x22;you&#x22; },
]"
/>

## What the check looks at [#what-the-check-looks-at]

`nb.handoff_is_stale(conn, handoff, ds)` returns `None` when the hand-off still describes the dataset and its data. Otherwise it returns one line that says what changed and what to do. It checks, in this order:

* **The hand-off is for another descriptor.** The line names both ids.
* **The descriptor's version changed**, or its digest did. The line gives both versions, such as v2 to v3.
* **The data no longer matches.** With a connection, the check compares the data digest. A mismatch means the rows or the dates differ.

## The fix [#the-fix]

The fix in every case is the same: write it again with `nb.write_handoff(conn, ds)`. The old file stays where it is. The file name carries the descriptor version, so the new one is saved beside the old one.

The training step on the ML Engineer's side refuses a stale hand-off and prints the same line. Check the line first, so you know whether the change was to the column map or to the data.

## The hand-off bundle has no such check [#the-hand-off-bundle-has-no-such-check]

The hand-off bundle, from [The hand-off bundle](/data-scientist/communicate/hand-off-bundle), is a snapshot too. It has no staleness check. Write a new one when the work changes.

Back to [Monitor and iterate](/data-scientist/monitor). Next: [Tracing model calls](/data-scientist/monitor/tracing).
