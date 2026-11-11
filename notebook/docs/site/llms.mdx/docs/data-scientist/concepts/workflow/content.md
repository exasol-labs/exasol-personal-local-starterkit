# Workflow (/data-scientist/concepts/workflow)



A **workflow** gives one id to every query and decision in a piece of work. The quickstart starts it and the other notebooks continue it. You never paste an id.

```python
workflow_id = nb.workflow("data-scientist-quickstart")   # in the quickstart
nb.continue_workflow("explore")                          # in every later notebook
```

`continue_workflow` takes this kernel's workflow, else the last one started on this computer, and starts a new one only when there is none.

## What is logged [#what-is-logged]

While a workflow is active, every helper that does something appends one line to its log: a SQL statement, a column map draft or approval, a model trace, a dashboard revision, a hand-off. Every guided card action is a line too, with the code it ran and whether it worked.

Without a workflow nothing is written. There are no implicit workflows.

## Where the log is [#where-the-log-is]

`~/.exasol-starter-kit/workflows/<id>.jsonl`: one JSON object per line, append-only, readable by you only. The id looks like `wf-20261027-3f9a1c`.

```python
nb.list_workflows()              # every workflow on this computer
nb.workflow_log(workflow_id)     # one workflow's events
```

```bash
exakit workflow show wf-20261027-3f9a1c
```

## No secrets in the log [#no-secrets-in-the-log]

A secret-named value or a connection string with a password is refused before anything is written. SQL that mentions a password or an API key is logged with its text replaced and its digest kept.

<Callout>
  A log that cannot be written warns and the cell goes on. Logging never fails the work it describes.
</Callout>

## Reference [#reference]

[Workflows](/data-scientist/reference/workflow).
