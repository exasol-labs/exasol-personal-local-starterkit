# Workflows (/kit/tools/workflows)



A notebook starts a **workflow** and gets an id such as `wf-20261027-3f9a1c`. While it is active, every step the helpers run adds one line to its log. For the idea, see [Workflow](/data-scientist/concepts/workflow).

## List [#list]

```bash
exakit workflow list
```

One row per workflow: its id, first and last time, number of lines and name.

## Show one [#show-one]

```bash
exakit workflow show wf-20261027-3f9a1c
```

Its lines in order. Each one is a step:

| Line                                 | What happened                                  |
| ------------------------------------ | ---------------------------------------------- |
| `start`                              | The workflow began, with its name              |
| `step`                               | A later notebook continued it                  |
| `sql`                                | A statement ran                                |
| `describe.draft`, `describe.approve` | A column map was drafted or approved           |
| `ask.approve`, `ask.answer`          | A question's SQL was approved, and it answered |
| `model`                              | A model was trained and scored                 |
| `trace`                              | A model call was traced                        |
| `dashboard.revision`                 | A dashboard was previewed or published         |
| `handoff`                            | A hand-off was written                         |

Add `--json` to either command for a script.

## Where the logs are [#where-the-logs-are]

`~/.exasol-starter-kit/workflows/<id>.jsonl`, one JSON object per line, readable by you only.

## No secrets [#no-secrets]

The helpers refuse a password, a token, a secret or an API key, and a connection string with a password in it. The log is safe to share.

<Callout>
  The workflow log is written by the notebook helpers, so this command needs the notebook add-on: `exakit marketplace notebook`.
</Callout>
