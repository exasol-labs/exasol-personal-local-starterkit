# Troubleshooting (/data-scientist/set-up/troubleshooting)



Each entry gives the message or the symptom, then the command to run. The AI entries are at the end.

## Install and the command line [#install-and-the-command-line]

<Accordions type="multiple">
  <Accordion title="exakit: command not found">
    The command is in `~/.local/bin`, and that folder is not on a bare shell's `PATH`. This does not mean the kit is missing. Run `export PATH="$HOME/.local/bin:$PATH"`, or call `~/.local/bin/exakit` by its full path. On Windows, call `exakit.cmd`.
  </Accordion>

  <Accordion title="exakit status says installing, or the installer stopped">
    `installing` with exit code 3 means the install is still running. Poll `exakit status` until it reports running. If the status names a re-run instead, the installer stopped. Run the installer again. It resumes where it stopped.
  </Accordion>

  <Accordion title="The database does not answer">
    ```python
    nb.kit_check()          # is the database running?
    nb.exakit("start")      # start it, for example after a restart of this computer
    ```

    `exakit status` also tells you what to run. If it says `interrupted`, do not loop on `exakit start`. Run `exakit repair-runtime` only after you have agreed to it: it rebuilds the database, and that destroys the data you loaded. The bundled datasets are loaded again afterwards. The kit asks before it does this.
  </Accordion>

  <Accordion title="An add-on is missing or stopped">
    ```python
    nb.addon_ready("dash-server")
    ```

    It installs the add-on when it is missing and starts it when it is stopped.
  </Accordion>

  <Accordion title="After an update, nothing changed">
    A running kernel keeps the helpers it loaded before the update. Restart the kernel. In JupyterLab, choose **Kernel**, then **Restart Kernel**.
  </Accordion>
</Accordions>

## Notebooks and docs [#notebooks-and-docs]

<Accordions type="multiple">
  <Accordion title="The notebooks say the port is in use">
    Port 8888 (JupyterLab) or 2718 (Marimo) belongs to another program. Without `--port`, the kit uses the next free port and says which one. To pick a port yourself, run `exakit notebook --port 8890`. A port you name is refused when it is taken.
  </Accordion>

  <Accordion title="JupyterLab or Marimo is missing from the kit">
    Run `exakit notebook setup`. It installs the kit's JupyterLab again at its pinned version. Without a terminal it does this without asking. If the notebook environment itself is broken, run `exakit update notebook`.
  </Accordion>

  <Accordion title="The kernel Exasol (Starter Kit) is gone from Jupyter">
    Run `exakit notebook setup`. Every `exakit notebook` command registers the kernel again.
  </Accordion>

  <Accordion title="The browser does not open">
    Run `exakit notebook --no-browser`. It prints the address. The login token is in `~/.exasol-starter-kit/credentials`. Do not paste the token anywhere else.
  </Accordion>

  <Accordion title="A notebook cannot connect">
    Run `exakit notebook check`. It finds the kit's database connection and checks it.
  </Accordion>

  <Accordion title="The documentation does not open">
    `nb.docs()` reads the copy of the site in the kit. If it reports the site is missing, run `nb.exakit("update", "notebook")`. The site is served on this computer at one of the ports 8790 to 8809, the first one free. To choose the port, set `EXAKIT_DOCS_PORT` before you start the notebooks. If the notebook runs on another machine than your browser, the page cannot reach the site. Use `nb.docs(browser=True)` on the machine that runs the kit.
  </Accordion>

  <Accordion title="How do I find a command?">
    `nb.docs("words")` searches these docs. `nb.docs(nb.some_command)` opens that command's page. The [command reference](/data-scientist/development/reference) lists every helper.
  </Accordion>
</Accordions>

## Files and updates [#files-and-updates]

<Accordions type="multiple">
  <Accordion title="Do I need a terminal?">
    No. Everything the notebooks need runs from a cell or a card: `nb.kit_check()`, `nb.exakit(...)`, `nb.addon_ready(...)`. You need a terminal once, to run the installer and open the notebooks.
  </Accordion>

  <Accordion title="Where is my work saved?">
    Under `~/.exasol-starter-kit`: column maps, workflow logs, hand-off bundles and the kit's credentials. The data you load lives in the database on this computer.
  </Accordion>

  <Accordion title="Will an update overwrite my notebooks?">
    No. A notebook you edited is never overwritten. A notebook you deleted is not copied back.
  </Accordion>
</Accordions>

## AI model and tracing [#ai-model-and-tracing]

These entries are about the optional model and Langfuse settings. The setup steps are in [Set up AI and Langfuse](/data-scientist/set-up/ai-and-langfuse).

<Accordions type="multiple">
  <Accordion title="A model step is skipped">
    Either no model is set, or the dataset has no column for that step. Run `nb.model_settings()` to see what is set. Set the model as shown on [Set up AI and Langfuse](/data-scientist/set-up/ai-and-langfuse). The themes step also skips on a dataset with no text column, and says so. The reference datasets, `amazon_sales` and `fraud_transactions`, have no text column.
  </Accordion>

  <Accordion title="The message says the model is not usable">
    The settings are refused before any call is made. The message names the setting. Common causes:

    * The base URL is `http://` to a host outside this computer and your network. Use the provider's `https://` address.
    * The base URL includes a path such as `/chat/completions`, a query, or a username and password. Remove them. Give only the API base, such as `/v1/`.
    * `EXAKIT_PROVIDER_HEADERS` is not a JSON object of plain values, or it sets an authorization header. Put the key in `EXAKIT_PROVIDER_API_KEY` instead.
  </Accordion>

  <Accordion title="Langfuse says tracing is off">
    The message names the missing setting. Tracing needs all three: the public key, the secret key and the base URL. A plain `http://` address to a host outside this computer and your network also turns tracing off. Use the `https://` address.
  </Accordion>

  <Accordion title="I changed a setting and nothing changed">
    The notebook server read its environment when it started. Run `exakit notebook stop`, then `exakit notebook` from the terminal that has the variables. A kernel restart does not read them again, and a new terminal does not reach a server that is already running.
  </Accordion>

  <Accordion title="Do I need an AI model?">
    No. Every step runs without one. A model is used only to draft SQL in Ask and to sort texts into themes in Explore. Both are off until you turn them on. Ask also has a drafter that needs no model: `nb.draft_question`.
  </Accordion>

  <Accordion title="Is my data sent anywhere?">
    Not by default. The database and the notebooks run on this computer. With a model set up, Ask sends the column map and your question, never rows. The themes step sends a sample of texts. It asks first when the data is a live external source. With Langfuse Cloud on, the recorded inputs and outputs of each model call are sent to Langfuse.
  </Accordion>

  <Accordion title="Can an AI-drafted query change my data?">
    No. Nothing runs until you approve the exact text. Approved questions run as the read-only user, and writes are rejected by the database.
  </Accordion>
</Accordions>

Back to [Set up Exasol](/data-scientist/set-up). Next stage: [Get the data](/data-scientist/get-the-data).
