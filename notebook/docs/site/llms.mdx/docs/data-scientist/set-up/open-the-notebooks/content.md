# Open the notebooks (/data-scientist/set-up/open-the-notebooks)



The notebooks run in your browser, on the kit's own Python. Both JupyterLab and Marimo open with the kernel **Exasol (Starter Kit)**. That kernel knows where the kit's database connection is, so no notebook asks for a host, a user or a password.

## Start them [#start-them]

```sh
exakit notebook             # JupyterLab, in your browser
exakit notebook marimo      # Marimo, in your browser
exakit notebook stop        # stop both servers
```

Run `exakit notebook` again after an install or an update to check the notebook environment and the database connection. It fixes what it can and says what it cannot fix.

## Run the notebooks in order [#run-the-notebooks-in-order]

Your copies are in `~/.exasol-starter-kit/notebooks/starter-kit-notebooks/data-scientist/`. Run them in this order:

1. `00_quickstart`
2. `01_explore`
3. `02_ask_your_data`
4. `03_share`

A notebook you edited is never overwritten by an update. A notebook you deleted is not copied back.

## The guided card and the Code view [#the-guided-card-and-the-code-view]

Each notebook opens with a guided card. A card has buttons and forms for the page's steps. The first card has a **Docs** button beside the logo. It opens this documentation on the page for that notebook.

Every card has a **Guided / Code** switch. **Guided** is the default. **Code** shows the calls behind each button. [Two ways through each notebook](/data-scientist#two-ways-through-each-notebook) explains both.

## Read these docs from a notebook [#read-these-docs-from-a-notebook]

```python
import exakit.nb as nb

nb.docs()                  # this site, under the cell
nb.docs("descriptor")      # search it
nb.docs(nb.describe)       # one command's page
nb.docs(browser=True)      # in a browser tab instead
```

The site ships with the kit and is served from this computer. Reading and searching work without internet.

If `nb.docs()` reports that the site is missing, run `nb.exakit("update", "notebook")`. More on this in [Troubleshooting](/data-scientist/set-up/troubleshooting).

Back to [Set up Exasol](/data-scientist/set-up). Next: [Check the kit](/data-scientist/set-up/check-the-kit).
