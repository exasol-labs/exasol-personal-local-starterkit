# Run SQL (/kit/data/run-sql)



```bash
exakit sql 'SELECT COUNT(*) FROM AMAZON.ORDER_LINES'
```

It runs one statement and prints the result.

## Reads only unless you say otherwise [#reads-only-unless-you-say-otherwise]

A statement that would change data is refused unless you add `--write`.

```bash
exakit sql --write 'CREATE SCHEMA SCRATCH'
```

<Callout type="warn">
  `exakit sql` connects as the kit's admin user, and that user is not sandboxed. The read-only boundary is the MCP user that AI clients use, not this command.
</Callout>

## A saved statement [#a-saved-statement]

```bash
exakit sql --file ./report.sql
```

Comment lines and a trailing semicolon are dropped first. A statement can also come on standard input.

## Errors come with their fix [#errors-come-with-their-fix]

The three faults everyone hits first are turned into what to do:

| Fault                  | What you are told  |
| ---------------------- | ------------------ |
| Connection refused     | Run `exakit start` |
| `FETCH FIRST` or `TOP` | Use `LIMIT`        |
| Object not found       | Describe it first  |

The fix is printed first, with the error.

## For a script [#for-a-script]

```bash
exakit sql --json 'SELECT 1'
```

One JSON object comes back and nothing else: the rows and their count on success, or the error with a command to run, when there is one.

<Callout>
  On Windows PowerShell 5.1, a double quote inside an argument is dropped before `exakit` runs. Pass a statement with quoted names through `--file`.
</Callout>

## Further reading [#further-reading]

* [SELECT](https://docs.exasol.com/db/latest/sql/select.htm), the statement the examples on this page use.
* [Privileges](https://docs.exasol.com/db/latest/database_concepts/privileges.htm), the rules behind the admin and read-only users.
* [exapump](https://github.com/exasol-labs/exapump), the command-line client the kit uses for SQL and loading.
* [AI clients and the read-only user](/security/ai-clients), which explains why `exakit sql` is not the read-only path.
