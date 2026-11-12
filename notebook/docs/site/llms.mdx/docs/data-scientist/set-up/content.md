# Set up Exasol (/data-scientist/set-up)



Every data science project needs a place to work: a database that holds the data, a way to query it, and a notebook to write in. The kit gives you all three on your computer: a local Exasol database, the tools that load and query it, and four notebooks that run on it. Setup takes one install command and one check.

<Flow
  caption="Install, database, notebooks"
  steps="[
  { title: &#x22;You run the installer&#x22;, text: &#x22;One command in a terminal&#x22;, tone: &#x22;you&#x22;, code: &#x22;curl https://www.exasol.com/install/starter-kit.sh | sh&#x22; },
  { title: &#x22;The kit deploys the database&#x22;, text: &#x22;A local Exasol database. Usually under 2 minutes.&#x22;, tone: &#x22;kit&#x22;, code: &#x22;exakit status&#x22; },
  { title: &#x22;The tools are in place&#x22;, text: &#x22;exapump, the read-only AI connection, the notebooks, the personas&#x22;, tone: &#x22;db&#x22;, href: &#x22;/kit/tools/notebooks&#x22; },
  { title: &#x22;You open the notebooks&#x22;, text: &#x22;JupyterLab or Marimo, on the kit's own Python&#x22;, tone: &#x22;you&#x22;, code: &#x22;exakit notebook&#x22; },
]"
/>

## Where you do it [#where-you-do-it]

| Task               | Guided view                                            | Notebook code                                                  | Terminal                                      |
| ------------------ | ------------------------------------------------------ | -------------------------------------------------------------- | --------------------------------------------- |
| Check the kit      | The **Home** card in `00_quickstart`, tab **Your kit** | `nb.kit_check()`                                               | `exakit status`                               |
| Start the database | Not in a card                                          | `nb.exakit("start")`                                           | `exakit start`                                |
| Install an add-on  | Home card, tab **Marketplace**, **Install**            | `nb.addon_ready("dash-server")`                                | `exakit marketplace dash-server`              |
| Connect AI clients | Not in a card                                          | `nb.exakit("mcp-setup", env={"EXAKIT_MCP_CLIENTS": "claude"})` | `exakit mcp-setup`                            |
| Open the notebooks | Not in a card                                          | Not in a cell                                                  | `exakit notebook` or `exakit notebook marimo` |

Commands run from a cell do not need a terminal. Each one streams its output into the cell and returns its exit code, so a cell can act on the result.

## In this stage [#in-this-stage]

<Cards>
  <Card title="Install the kit" href="/data-scientist/set-up/install" description="The install command for each system, and what it puts on this computer" />

  <Card title="Open the notebooks" href="/data-scientist/set-up/open-the-notebooks" description="JupyterLab or Marimo, the kernel, and the docs from a cell" />

  <Card title="Check the kit" href="/data-scientist/set-up/check-the-kit" description="The two checks that show the database answers" />

  <Card title="Workflows" href="/data-scientist/set-up/workflows" description="The id that links the notebooks, and the log it writes" />

  <Card title="Set up AI and Langfuse" href="/data-scientist/set-up/ai-and-langfuse" description="Optional: a text model and tracing, with their keys" />

  <Card title="Troubleshooting" href="/data-scientist/set-up/troubleshooting" description="Install, database, notebook and docs problems" />
</Cards>

## What you have at the end [#what-you-have-at-the-end]

A local Exasol database that answers, the kit's notebooks ready to open, and a workflow that logs what you do. Next, load the data you will work on in [Get the data](/data-scientist/get-the-data).

<StageNav n="1" />
