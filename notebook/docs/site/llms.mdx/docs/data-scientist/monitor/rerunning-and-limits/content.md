# Rerunning, and what the kit does not do (/data-scientist/monitor/rerunning-and-limits)



## Rerunning the notebooks [#rerunning-the-notebooks]

Run a notebook again to see what has changed. These are the things that move:

* `DATASET = None` picks up the dataset approved last. Approve a different one in the quickstart, then run the first cell of the other notebook again to follow it. To pin a dataset, set `DATASET = "..."` in the notebook.
* The baseline reads the newest 20,000 rows, and the lab reads the newest 50,000, when the table has a date. New rows change which rows the models see.
* The log grows. Every rerun adds lines to the same workflow.
* Dashboards and hand-off bundles are not rebuilt by a rerun. Make a new draft and a new bundle when the result changes.

After you update the kit, restart the kernel. A running kernel keeps the helpers it loaded before the update. In JupyterLab, choose **Kernel**, then **Restart Kernel**.

## What the kit does not do [#what-the-kit-does-not-do]

Be clear about these limits before you rely on the kit for a recurring job.

* **It does not detect drift.** It does not compare this month's data with last month's, and it does not warn you when a score falls.
* **It does not retrain.** A model is trained when you run its cell, and nothing runs it again on a schedule.
* **It does not watch the database.** Nothing checks the table between your runs.
* **It does not alert.** Tracing and the log record what happened. They do not send a message.

Monitoring the data over time is a job you schedule yourself, with your own tools. The kit gives you the record to read and the steps to redo.

Back to [Monitor and iterate](/data-scientist/monitor).
