# Framework upgrade paths

`release.sql` from the preprocessor framework is fresh-install only: it creates
the `PREPROC_ADMIN` role without a guard and seeds the bootstrap rules, so it
cannot be replayed over a framework that is already installed.

An installed framework therefore stays at its version until a tested upgrade
path exists for the exact pair of versions. To add one:

1. Write the migration SQL for `<from>` to `<to>` in this folder, for example
   `0.9.1-to-0.10.0.sql`. It must preserve `PREPROC.CONFIG`, `PREPROC.MODULES`
   and `PREPROC.SETTINGS`, and every rule a user or an add-on registered.
2. Test it against a database that holds the `<from>` framework with rules and
   modules registered, then verify with `EXECUTE SCRIPT PREPROC.STATUS`.
3. List it under `upgrades` in `../manifest.json` as
   `{"from": "<from>", "to": "<to>", "migration": "migrations/<file>.sql"}`.
4. Add a new core task name in `setup/core/tasks.json` (for example
   `preprocessor_v2`), so `exakit update` reruns the installer once on every
   machine that has not applied it yet.

Until then, `manage.py` reports the pending upgrade and keeps verifying the
installed framework.
