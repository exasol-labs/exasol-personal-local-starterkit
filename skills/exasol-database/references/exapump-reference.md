# exapump Database CLI Reference

> Database-skill reference for exapump profile, SQL, and interactive commands.
> Use **exasol-import** and **exasol-export** for local file movement workflows.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exapump/main/install.sh | sh
```

## Global Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Print help |
| `-V, --version` | Print version |

## Connection Profiles

exapump uses saved connection profiles. The default profile is used automatically; pass `--profile <name>` **after the subcommand** to select a different one. Example: `exapump sql --profile staging "SELECT 1"`

```bash
# Add a new profile (interactive — prompts for host, port, user, password, TLS)
exapump profile add default

# List saved profiles
exapump profile list
```

## sql

Execute SQL statements against Exasol. Returns results in CSV or JSON format for SELECT queries.

```
exapump sql [OPTIONS] [SQL]
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `[SQL]` | No | SQL statement to execute. Reads from stdin if omitted or if `-` is given. |

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `-f, --format <FORMAT>` | `csv` | Output format for SELECT results. Values: `csv`, `json` |
| `--profile <NAME>` | (none) | Use a saved connection profile instead of the default |

### Example

```bash
exapump sql "SELECT * FROM my_table LIMIT 10"
```

## interactive

Start an interactive SQL REPL session connected to Exasol.

```
exapump interactive [OPTIONS]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--profile <NAME>` | (none) | Use a saved connection profile instead of the default |

### Example

```bash
exapump interactive --profile production
```
