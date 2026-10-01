---
name: exasol-pyexasol
description: Query the local Exasol database from Python using pyexasol, the official Exasol Python driver the starter kit preinstalls into its own virtual environment — connecting with the right TLS setting for the kit's self-signed certificate, running queries, reading credentials safely, and adding extra packages such as pandas. Triggers — "query Exasol from Python", "use pyexasol", "connect Python to my database", "write a Python script against Exasol", "pandas dataframe from Exasol", "import pyexasol fails", "which Python has pyexasol".
---

# pyexasol — Python access to the local database

The kit preinstalls the official Exasol Python driver into a **dedicated
virtual environment**, so scripting against the local database works
immediately without touching the system interpreter or any of the user's own
projects.

## Use this interpreter

```
~/.exasol-starter-kit/pyexasol-venv/bin/python
```

That is the only interpreter with `pyexasol` in it. A plain `python3` on the
machine will raise `ModuleNotFoundError: No module named 'pyexasol'` — that
error means the wrong interpreter, not a broken install.

Confirm it and read the exact path from the machine rather than assuming:

```bash
exakit info --json      # components.pyexasol.python is the interpreter path
```

## Connecting

Three details matter, and the third is the one people miss:

- **DSN** — `127.0.0.1:8563` (confirm with `exakit info`)
- **User** — `sys`, the admin user; its password lives in a file under
  `~/.exasol-starter-kit/credentials/`
- **TLS** — the local database uses a **self-signed certificate**, so
  certificate verification must be relaxed or every connection fails

```python
import pyexasol

with open("/Users/<you>/.exasol-starter-kit/credentials/<password-file>") as fh:
    password = fh.read().strip()

C = pyexasol.connect(
    dsn="127.0.0.1:8563",
    user="sys",
    password=password,
    websocket_sslopt={"cert_reqs": 0},   # local self-signed certificate
)
```

Get the real password filename from `exakit info` (the "Admin pass" line) or
`exakit info --json` (`runtime.password_file`) — do not guess it, and **never
print the password or paste it into a script literal**. Read it from the file
at run time, exactly as above.

## Querying

```python
stmt = C.execute("SELECT * FROM TPCH.CUSTOMER LIMIT 5")
for row in stmt:
    print(row)

print(C.execute("SELECT COUNT(*) FROM TPCH.ORDERS").fetchval())

C.close()
```

Remember the dialect: Exasol pages with **`LIMIT n`**, never `FETCH FIRST` or
`TOP`.

The bundled datasets live in their own schemas — `TPCH`, `ENERGY`, `WEATHER` —
and anything the user uploads defaults to `STARTER_KIT`.

## pandas is not preinstalled

The kit installs the **bare** `pyexasol` package. Convenience methods that
return dataframes — `export_to_pandas`, `import_from_pandas` — need pandas,
which is not in the venv. Calling them as shipped raises `ImportError`.

Add it to the kit's venv when the user actually wants dataframes:

```bash
PY=~/.exasol-starter-kit/pyexasol-venv/bin/python
# Kits installed before pip was seeded into this venv have no pip yet; ensurepip adds it.
"$PY" -m pip --version >/dev/null 2>&1 || "$PY" -m ensurepip --upgrade
"$PY" -m pip install pandas
```

On Windows the interpreter is `%USERPROFILE%\.exasol-starter-kit\pyexasol-venv\Scripts\python.exe`; run the same `-m ensurepip --upgrade` and `-m pip install pandas` with it.

Then:

```python
df = C.export_to_pandas("SELECT * FROM TPCH.CUSTOMER LIMIT 5")
```

Prefer the plain `execute()` API when a dataframe is not required — it works
out of the box.

## This connection is the admin connection

`sys` is the **admin** user. Like `exapump -p starter-kit`, and unlike the MCP
tools, it is **not sandboxed** — it can create, update, delete and drop. The
read-only guarantee in this kit belongs to the MCP path only.

So: write `SELECT` unless the user explicitly asked for a change, show the SQL
before running it, and never use a Python script to route around a write the
MCP path refused.

## When something is wrong

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleNotFoundError: No module named 'pyexasol'` | wrong interpreter | use `~/.exasol-starter-kit/pyexasol-venv/bin/python` |
| Connection refused / timeout on `8563` | database not running | `exakit start`, confirm `exakit status` |
| TLS / certificate verification error | self-signed certificate | pass `websocket_sslopt={"cert_reqs": 0}` |
| `ImportError` from `export_to_pandas` | pandas not installed | install it into the kit venv with the three lines above (`ensurepip` first if `No module named pip`) |
| pyexasol reported missing by `exakit status` | the soft install step failed | `exakit update` |

`exakit update` doubles as the repair command — it installs the
advertised version into the venv.

## Guardrails

- **Never print, log or hardcode** the contents of the credential files under
  `~/.exasol-starter-kit/credentials/`. Open and read them at run time.
- **Admin connection** — treat every statement as consequential; `SELECT` by
  default.
- **Do not install into the system Python** to "fix" an import error. The venv
  is deliberate; use its interpreter.
- **Do not invent** pyexasol API calls. If unsure, check the driver's own docs
  rather than guessing a method name.
