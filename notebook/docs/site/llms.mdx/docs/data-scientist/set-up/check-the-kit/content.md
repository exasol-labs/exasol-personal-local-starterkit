# Check the kit (/data-scientist/set-up/check-the-kit)



A check tells you whether the database answers. Run the terminal check once after the install. The quickstart runs the cell check first.

## Check from a terminal [#check-from-a-terminal]

```sh
export PATH="$HOME/.local/bin:$PATH"     # once per terminal, if exakit is not found
exakit status                            # Status: running, exit code 0
exakit sql 'SELECT CURRENT_TIMESTAMP'    # a timestamp means the database works
```

`exakit status` reports `Status: running` and exits with code 0 when the kit is ready. The `exakit sql` line prints the database's current time. A timestamp means the query went through.

On Windows, the command is `exakit.cmd` in `%USERPROFILE%\.local\bin`. Git Bash does not find it on the path, so call `~/.local/bin/exakit.cmd` there.

## Check from a cell [#check-from-a-cell]

The first cell of `00_quickstart` checks the kit and changes nothing:

```python
import exakit.nb as nb

kit_state = nb.kit_check()      # what is installed and running
nb.components()                 # the kit's parts, their versions and pending updates
nb.addons()                     # the marketplace's add-ons and their state
nb.sample_datasets()            # the kit's datasets, and which are loaded
nb.notebooks("data-scientist")  # this persona's notebooks, in order
```

`nb.kit_check()` returns the state as a value (`kit_state`), so a later cell can read it.

## How we used it [#how-we-used-it]

On a fresh machine, install with the Data Scientist persona, as shown on [Install the kit](/data-scientist/set-up/install). Then open `00_quickstart` and run the check cell. It shows what is installed and running, and changes nothing:

```python
kit_state = nb.kit_check()
```

Then run the workflow cell, the one that starts `data-scientist-quickstart`. It prints the workflow id, and the other notebooks continue that workflow. You do not need to note the id down. See [Workflows](/data-scientist/set-up/workflows).

## Change the kit from a cell [#change-the-kit-from-a-cell]

To change the kit from a cell, use `nb.exakit(...)`. It runs the same command as a terminal and returns the exit code:

```python
nb.exakit("start")                              # start the database
nb.addon_ready("dash-server")                   # install and start an add-on
nb.exakit("logs", "dash-server")                # a service's log
nb.kit_update()                                 # bring the kit and its add-ons up to date
```

A command run from a cell has no terminal. A question it would ask takes its default. Give the answer up front instead, for example `nb.exakit("mcp-setup", env={"EXAKIT_MCP_CLIENTS": "claude"})`.

Back to [Set up Exasol](/data-scientist/set-up). Next: [Workflows](/data-scientist/set-up/workflows).
