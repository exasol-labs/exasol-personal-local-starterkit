# AI clients and skills (/kit/tools/ai-clients-and-skills)



The kit connects AI clients to the database through its AI bridge. A client connected this way reads data as the kit's read-only user.

## Connect [#connect]

```bash
exakit mcp-setup
```

It configures the `exasol` MCP server in every supported AI client. Existing configs are backed up first. To name the clients yourself, set `EXAKIT_MCP_CLIENTS` before the command:

```bash
EXAKIT_MCP_CLIENTS=claude,codex exakit mcp-setup
```

Restart each client afterwards and look for a server named `exasol`.

## Check and repair [#check-and-repair]

```bash
exakit mcp-status      # the state of each client
exakit mcp-doctor      # test the connection and repair it
```

Both take `--json` for a script.

## Skills [#skills]

A **skill** is a set of instructions that teaches an AI client how to use the kit: which command loads data, how to read a column map, where dashboards go.

```bash
exakit skills              # the skills the kit carries
exakit skills-install      # put them back in place (repair)
```

Skills update with the kit, so a new skill reaches every installed kit through `exakit update`.

## What a client can and cannot do [#what-a-client-can-and-cannot-do]

* It reads through the read-only user. It cannot change your data.
* It reads the approved [column maps](/kit/data/column-maps), so it works from the roles you approved.
* The notebooks send a model names, types, notes and a column's most frequent values for most AI steps. One step sends row text: the themes step in Explore (`nb.themes`) sends the text column of sampled rows, up to 600 characters each, to sort them into themes. Every AI step is off until you set a model up. See [What goes to a model](/security/what-goes-to-a-model) and [AI and tracing](/data-scientist/set-up/ai-and-langfuse).

## From a notebook [#from-a-notebook]

```python
nb.ai_clients()                # the clients the kit can connect, and which are connected
nb.exakit("mcp-doctor")        # check the connection
```

## Further reading [#further-reading]

* [Exasol MCP server documentation](https://exasol.github.io/mcp-server/main/index.html), and its [repository](https://github.com/exasol/mcp-server). The kit runs this server beside the database and copies its skills.
* [Privileges](https://docs.exasol.com/db/latest/database_concepts/privileges.htm) and [GRANT](https://docs.exasol.com/db/latest/sql/grant.htm), the rules behind the read-only user.
* [AI clients and the read-only user](/security/ai-clients), the security view of the same connection, with its limits.
