# Tracing model calls (/data-scientist/monitor/tracing)



## Tracing model calls [#tracing-model-calls]

With Langfuse set up, each model call is one trace in your own Langfuse project, with its input, output, token use and time. Langfuse is the tracing service the kit connects to. Set it up on [AI and Langfuse](/data-scientist/set-up/ai-and-langfuse).

Check whether tracing is on:

```python
nb.tracing()        # True when the three Langfuse settings are set
```

Pass a block to group several calls into one trace:

```python
with nb.trace(connection, dataset=dataset):
    ideas = nb.feature_ideas(lab, ai=True)
```

Each trace is tagged with the database session, the workflow id and, with a dataset, its id and descriptor version. When the block ends, the kit prints the trace id and where to find it, and adds a `trace` line to the [workflow log](/data-scientist/monitor/the-workflow-log). The secret key is never printed or logged.

Tracing lets you compare runs by their cost, time and answers. It does not alert you to anything.

Back to [Monitor and iterate](/data-scientist/monitor). Next: [Rerunning, and what the kit does not do](/data-scientist/monitor/rerunning-and-limits).
