# Add-ons (/kit/tools/add-ons)



Add-ons are optional tools around the database: dashboards, notebooks and more. A persona installs the ones it needs. You can add or remove any of them later.

## See what there is [#see-what-there-is]

```bash
exakit marketplace --list
```

Every add-on is listed with its state, its version and what it is. Nothing is installed. Add `--json` for a script.

The name, the link and the description of an add-on come from its own repository, so the list always shows the current ones.

## Install [#install]

```bash
exakit marketplace                 # choose in a menu: Space selects, Enter installs
exakit marketplace dash-server     # install exactly this one
```

<Callout>
  Without a terminal, a bare `exakit marketplace` installs nothing. Name the add-ons, or answer up front: `EXAKIT_MARKETPLACE_ADDONS=dash-server exakit marketplace`.
</Callout>

## Start, stop and check [#start-stop-and-check]

Some add-ons are services, such as the dashboard server.

```bash
exakit start dash-server
exakit stop dash-server
exakit status
exakit logs dash-server
```

`exakit start` with no name starts the database and every add-on service.

## Update and remove [#update-and-remove]

```bash
exakit update                  # apply the updates that are waiting
exakit update notebook         # one component
exakit uninstall dash-server   # remove one add-on
```

`exakit uninstall` takes `--dry-run` to preview what would be removed.

## Help for one add-on [#help-for-one-add-on]

```bash
exakit help dash-server
```

The full reference of an installed add-on is on this computer.

## From a notebook [#from-a-notebook]

```python
nb.addons()                      # every add-on and its state
nb.addon_ready("dash-server")    # install it when missing, start it when stopped
nb.kit_update()                  # bring the kit and its add-ons up to date
```

The Home card's **Marketplace** tab does the same with buttons. See [Run the kit from a notebook](/data-scientist/guides/run-the-kit).

<Callout>
  A tool you installed yourself is recognised and never offered again.
</Callout>
