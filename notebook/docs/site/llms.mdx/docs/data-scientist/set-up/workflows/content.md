# Workflows (/data-scientist/set-up/workflows)



## Workflows [#workflows]

A **workflow** is one id that every query and decision in a piece of work carries. The quickstart starts it, and every later notebook continues it, so you never paste an id.

<Flow
  caption="A notebook session starts a workflow, and every step is logged"
  steps="[
  { title: &#x22;The first cell checks the kit&#x22;, text: &#x22;It changes nothing&#x22;, tone: &#x22;you&#x22;, code: &#x22;nb.kit_check()&#x22; },
  { title: &#x22;The workflow cell starts a workflow&#x22;, text: &#x22;Every query and decision is under this id&#x22;, tone: &#x22;kit&#x22;, code: &#x22;workflow_id = nb.workflow(\&#x22;data-scientist-quickstart\&#x22;)&#x22; },
  { title: &#x22;Each step writes a log line&#x22;, text: &#x22;SQL, approvals, model calls, dashboards, the hand-off&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You read the log&#x22;, text: &#x22;A file on this computer, readable by you only&#x22;, tone: &#x22;you&#x22;, code: &#x22;nb.workflow_log(workflow_id)&#x22; },
]"
/>

## Start and continue [#start-and-continue]

```python
workflow_id = nb.workflow("data-scientist-quickstart")   # in the quickstart
nb.continue_workflow("explore")                          # in every later notebook
```

`nb.continue_workflow` takes the workflow of this kernel, or else the last one started on this computer. It starts a new one only when there is none. Nothing is logged without an active workflow, and the kit never starts one on its own.

## The workflow log [#the-workflow-log]

While a workflow is active, each helper that does something adds one line to its log. That includes a SQL statement, a column-map draft or approval, a model call and its trace, a dashboard revision and a hand-off. Every guided card action is a line too, with the code it ran and whether it worked.

The log is one file per workflow: `~/.exasol-starter-kit/workflows/<id>.jsonl`. Each line is a JSON object. The file is append-only and readable by you only. Ids look like `wf-20261027-3f9a1c`.

```python
nb.list_workflows()              # every workflow on this computer
nb.workflow_log(workflow_id)     # one workflow's events
nb.current_workflow()            # the id this kernel is using
```

```sh
exakit workflow show wf-20261027-3f9a1c
```

## What is never written [#what-is-never-written]

* A value named like a secret is refused before anything is written.
* A connection string with a password is refused too.
* SQL that looks credential-bearing, such as a statement with a `PASSWORD` or `API_KEY` column, is logged with its text replaced. Its digest is kept, and a warning is shown.
* A log that cannot be written warns, and the cell goes on. Logging never stops the work it describes.

The kit never writes a key into a cell, the code view or the log.

Back to [Set up Exasol](/data-scientist/set-up). Next: [Set up AI and Langfuse](/data-scientist/set-up/ai-and-langfuse).
