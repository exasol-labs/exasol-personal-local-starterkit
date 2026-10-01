---
name: dbt-exasol
addon: dbt-exasol
description: Build, test and document SQL models against the local Exasol database with dbt, using the dbt-exasol adapter the marketplace installs — covering the generated profile and why ~/.dbt is never touched, the dbt-exasol command name, where models land, and how the kit supplies the password without writing it anywhere. Triggers — "use dbt with Exasol", "set up dbt", "dbt profile for Exasol", "dbt run against my local database", "install dbt-exasol", "build models on Exasol", "dbt debug fails to connect", "where is my profiles.yml".
---

# dbt-exasol — dbt against the local database

`dbt-exasol` is a **marketplace add-on**: the dbt adapter for Exasol. Installing
it is also what puts **dbt itself** on the machine, because `dbt-core` comes
with the adapter.

Install it with `exakit marketplace` (Space selects, Enter installs). Never tell
a user to `pip install dbt-exasol` — that copy would have no profile, no
credentials and no launcher.

## The command is `dbt-exasol`, not `dbt`

```
dbt-exasol debug        dbt-exasol run        dbt-exasol test
```

Everything after the name is dbt's own command line. The kit deliberately does
**not** install a `dbt` command: a user with dbt-snowflake or dbt-postgres
already relies on that name, and taking it over would break their other
warehouse. If `dbt` on PATH already carries the Exasol adapter, the marketplace
does not offer this add-on at all and leaves that copy alone.

## The profile

The install generates `~/.exasol-starter-kit/dbt/profiles.yml` with a profile
named `exasol_starter_kit`, and the launcher points dbt at that directory with
`DBT_PROFILES_DIR`.

**`~/.dbt/profiles.yml` is never read or written.** That file belongs to the
user and often holds their other warehouses; the kit does not merge into it. A
user who keeps one file should copy the block out of the kit's copy.

To use the generated profile from a project, set it in `dbt_project.yml`:

```yaml
profile: exasol_starter_kit
```

Models build into the **`DBT`** schema, which dbt creates on the first run.

## The password is not in the profile

The profile names an environment variable:

```yaml
password: "{{ env_var('DBT_ENV_SECRET_EXASOL_PASSWORD') }}"
```

The launcher fills it from the kit's credential file at run time. The
`DBT_ENV_SECRET_` prefix is dbt's own convention for values it scrubs from logs
and artifacts. **Never print the password, and never write it into a
profiles.yml.** If a user needs to run dbt outside the launcher, tell them to
export that variable from the credential file — not to paste the value.

The profile uses the runtime **admin** user, not the read-only user the MCP
server and dash-server share: building models means creating tables, and a
read-only grant would fail every `dbt run`.

## dbt needs a project

`dbt-exasol run` outside a folder containing `dbt_project.yml` reports that
there is no project. That is dbt's own behaviour, not a broken install. A
minimal project is a `dbt_project.yml` with `name`, `version`, `config-version:
2` and `profile: exasol_starter_kit`, plus a `models/` folder of `.sql` files.

## What the install already proved

The marketplace install validates as far as it can and says only that it
succeeded. Internally it does two different things:

- **Database reachable** — it scaffolds a throwaway project and runs
  `dbt debug`, so the connection is genuinely proved.
- **Database not reachable** — it proves the adapter imports and stops there.
  A stopped database is not a broken install, so the user is not warned about
  it.

Which one happened is recorded as `components.dbt_exasol.validated_by`
(`connection` or `import`). If it says `import`, the connection has never been
tested on this machine; `exakit update dbt-exasol` re-runs the check once the
database is up.

## Troubleshooting

| Symptom | What to run |
|---|---|
| `dbt-exasol: command not found` | `exakit update dbt-exasol` |
| `Could not find profile named 'exasol_starter_kit'` | `exakit update dbt-exasol` |
| `Env var required but not provided: DBT_ENV_SECRET_EXASOL_PASSWORD` | `exakit update dbt-exasol` |
| `Runtime Error: Could not connect` | `exakit start` |
| dbt-exasol is not in the marketplace | `exakit update` |

`exakit update dbt-exasol` is the repair command for all of these: it rewrites
the profile and the launcher from the current DSN and credentials, then
re-validates.

## Removing it

`exakit uninstall` and pick `dbt-exasol`. It removes the venv, the launcher and
the generated `profiles.yml`. Anything else under
`~/.exasol-starter-kit/dbt` — a project a user kept there — is left alone.
