# Credentials and passwords (/security/credentials)



The kit holds three kinds of secret: the database admin password (the SYS user), the password of the read-only user that AI clients use, and any model or Langfuse key you give the notebooks. Each secret is a file in one folder, `~/.exasol-starter-kit/credentials/`. A password is never written to `exakit.env`, and the manifest records the path of each credential file, not the password.

## Where they live [#where-they-live]

| File under `credentials/`                                                                 | What it holds                                                                                            | Written by                                                                                                                 |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `runtime_sys_password`                                                                    | The database admin (SYS) password. Its path is recorded as `runtime.password_file` in the kit's manifest | `store_credential` in `setup/lib/common.sh`, called from `setup/lib/exapump.sh` and `exakit_configure_mcp_readonly_access` |
| `mcp_readonly_password`                                                                   | The password of the read-only MCP user                                                                   | `store_credential` in `exakit_configure_mcp_readonly_access`, `setup/lib/common.sh`                                        |
| `notebook_store_master_password`                                                          | The master password of the notebook connection store                                                     | `_credential()` in `marketplace/addons/notebook.py`                                                                        |
| `notebook_model_api_key`, `notebook_langfuse_secret_key` and the other `notebook_*` files | A model or Langfuse key, only if you asked for `remember=True`                                           | `_write_private()` in `notebook/package/exakit_nb/setup_env.py`                                                            |

Two more files hold a password in a different form:

* `~/.exapump/config.toml` (the exapump profile) holds the admin password as a TOML value. `exapump_write_profile()` in `setup/lib/exapump.sh` writes it, then runs `chmod 600`.
* The launcher's `sidecars.yaml` holds a reference to `mcp_readonly_password`, not the password. The file is written with mode 0600. `_mcp_sidecar_definition()` in `setup/lib/mcp.sh` says: "The password is a file reference the editor resolves; it is never in this text."

### File permissions [#file-permissions]

* The credentials folder is set to `700` by `store_credential()`. Each file is written as `<name>.tmp`, set to `600`, then renamed into place. An interrupted run cannot leave a truncated secret.
* `_exakit_warn_unprotected_credentials()` checks that `600` took effect. On a filesystem that ignores Unix modes, such as a Windows drive mounted into WSL, the kit prints a warning once per run.
* On Windows, `Protect-ExakitFile()` in `setup/lib/exakit-common.ps1` removes inherited permissions and grants full control to the current user only.
* Generated passwords are 24 characters of `A-Z`, `a-z` and `0-9`. `generate_password()` in `setup/lib/common.sh` reads `/dev/urandom`. `New-ExakitPassword()` in `setup/lib/exakit-common.ps1` uses `RandomNumberGenerator`.

## How a password reaches a tool [#how-a-password-reaches-a-tool]

| Tool                                                                        | How the password travels                                                                                                                                                 | Where to check it                                                                          |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| exapump, for the profile                                                    | The password goes in the environment variable `EXAKIT_PROFILE_PASSWORD`, read by a Python writer. It is never in argv                                                    | `exapump_write_profile()`, `setup/lib/exapump.sh`                                          |
| exapump, for SQL that contains a password (`CREATE USER ... IDENTIFIED BY`) | The SQL goes to exapump on standard input                                                                                                                                | `_exakit_run_exapump_sql()`, `setup/lib/common.sh`                                         |
| The read-only user's temporary config                                       | The admin and read-only passwords go in `EXAKIT_ADMIN_PASSWORD` and `EXAKIT_READONLY_PASSWORD`. The temporary file comes from `mktemp` and is removed on exit or failure | `_exakit_write_exapump_config()` and `exakit_track_sensitive_tmp()`, `setup/lib/common.sh` |
| The Exasol MCP server                                                       | The definition names the file, `EXA_PASSWORD` with a `valueFile`. The launcher reads the file                                                                            | `_mcp_sidecar_definition()`, `setup/lib/mcp.sh`                                            |
| The notebook connection store                                               | The master password is read from its file and passed as `SCS_MASTER_PASSWORD` to the store tool                                                                          | `marketplace/addons/notebook.py`, around the `SCS_MASTER_PASSWORD` line                    |
| A source's password (virtual schemas)                                       | You type or paste it. It goes to the engine on standard input. A key from a file goes to `paste.secret` at mode 600, which is deleted after use                          | `_exakit_vs_tui_paste()`, `setup/lib/virtual-schemas.sh`                                   |

A child process's environment is readable by its owner and by root, not by other users. The kit's comments rely on that. Each variable is unset again after the call that needs it.

### Where a source password ends up [#where-a-source-password-ends-up]

For a virtual schema the engine runs `CREATE CONNECTION ... TO <url> USER <user> IDENTIFIED BY <secret>` (`create_connection()` in `setup/virtual-schemas/engine/lifecycle.py`). The password is therefore stored in the database, in the CONNECTION object. The kit does not check how the database stores that object. See the [CREATE CONNECTION reference](https://docs.exasol.com/db/latest/sql/create_connection.htm) for the syntax.

## What stays out of logs [#what-stays-out-of-logs]

* The installer log is created at mode 600 (`setup/lib/common.sh`, the `EXAKIT_LOG_FILE` block).
* `_exakit_redact_mcp_secret_output()` in `setup/lib/common.sh` replaces the password, and the value after `IDENTIFIED BY`, before any `CREATE USER` or `ALTER USER` output is logged or shown.
* `run_logged()` in `marketplace/runtime.py` replaces the value of every child environment variable whose name ends in `PASSWORD`, `TOKEN`, `_KEY` or `SECRET` with `[redacted]`. The marketplace log is set to mode 600.
* `setup/lib/envfile.sh` refuses a settings-file name that contains `PASSWORD`, `API_KEY`, `TOKEN` or `SECRET`. A secret cannot come from `exakit.env`.
* `ModelConfig` in `notebook/package/exakit_nb/model_config.py` declares the key with `field(repr=False)`. `redact_secrets()` removes the key and custom header values in plain, URL-encoded and base64 forms, and whatever follows `Authorization`, `Bearer`, `Basic` or an `api-key` label.
* `notebook/package/exakit_nb/workflow.py` refuses a log payload whose key is named like a secret, or whose DSN contains a password. A statement that mentions `IDENTIFIED BY`, `PASSWORD` or `API_KEY` is logged as `<redacted: credential-like SQL>`.
* `setup_env.use_model()` in `notebook/package/exakit_nb/setup_env.py` asks for a key with a hidden prompt. The key stays in the kernel's environment unless you pass `remember=True`. `forget_model()` deletes the saved copy.

## Limits [#limits]

* `exakit sql` connects with the admin profile. Anyone who can read your home folder as your user can read the admin password in `~/.exapump/config.toml`. So can root.
* The notebook connection store is encrypted, but its master password is a file in the same credentials folder. The store protects the connection details from a casual reader. It does not protect them from anyone who can read that folder.
* The kit has no scheduled password rotation. When `mcp-setup` runs, it reapplies the stored read-only password with `ALTER USER`. It generates a new one only when the stored value is missing or fails validation.
* The protection of the admin password is file permissions. No code in the kit calls the operating system's keychain.
