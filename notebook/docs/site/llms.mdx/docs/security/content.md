# Security (/security)



This section is for a security reviewer, a platform engineer or a DBA. Every statement names the file and the function that does it, and quotes the behaviour from the code. Where the code does not do something, the page says so. Most pages end with a list of their limits.

The kit runs on your computer. It installs a local Exasol database, connects AI clients to it, and gives notebooks a way to ask questions. Its outbound calls are listed on the [Network and TLS](/security/network-and-tls) page.

## The trust boundaries [#the-trust-boundaries]

Two charts show where data and credentials move. The first is inside this computer.

<Flow
  caption="Inside this computer"
  steps="[
  { title: &#x22;You&#x22;, text: &#x22;Run exakit, answer its prompts, approve each SQL statement before a notebook runs it&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The kit&#x22;, text: &#x22;The exakit scripts and the notebook helpers. They read the credentials folder when they run&#x22;, code: &#x22;exakit status&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Local database&#x22;, text: &#x22;The admin (SYS) user is used for setup and admin tasks&#x22;, tone: &#x22;db&#x22;, href: &#x22;/security/credentials&#x22; },
  { title: &#x22;Read-only MCP user&#x22;, text: &#x22;mcp_readonly. It can read, not write. The database rejects writes&#x22;, tone: &#x22;db&#x22;, href: &#x22;/security/ai-clients&#x22; },
  { title: &#x22;AI client&#x22;, text: &#x22;Reads through the Exasol MCP server on 127.0.0.1&#x22;, tone: &#x22;ai&#x22;, href: &#x22;/security/ai-clients&#x22; },
]"
/>

The second is what leaves this computer, and when.

<Flow
  caption="What leaves this computer, and when"
  steps="[
  { title: &#x22;You start it&#x22;, text: &#x22;exakit marketplace, exakit update, or a model or source you chose&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;Add-on downloads&#x22;, text: &#x22;From GitHub or S3 over HTTPS. The version and SHA-256 are pinned&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/security/add-ons-and-downloads&#x22; },
  { title: &#x22;AI model provider&#x22;, text: &#x22;Only when you set one. Column names, types, roles and a few values. No rows&#x22;, tone: &#x22;ai&#x22;, href: &#x22;/security/what-goes-to-a-model&#x22; },
  { title: &#x22;External source&#x22;, text: &#x22;Read live by the database through a virtual schema. TLS is verified by default&#x22;, tone: &#x22;db&#x22;, href: &#x22;/security/network-and-tls&#x22; },
]"
/>

## Pages [#pages]

<Cards>
  <Card title="Credentials and passwords" href="/security/credentials">
    Where the passwords live, their file permissions, how they reach each tool, and what is kept out of logs.
  </Card>

  <Card title="AI clients and the read-only user" href="/security/ai-clients">
    The database user that AI clients use, what it may and may not do, and how a notebook question is approved before it runs.
  </Card>

  <Card title="What is sent to an AI model" href="/security/what-goes-to-a-model">
    Which helper sends what to a model, how sensitive columns are found, where keys may travel, and when tracing is on.
  </Card>

  <Card title="Network and TLS" href="/security/network-and-tls">
    The database certificate pin, the addresses the kit listens on, the outbound calls it makes, and how external sources are verified.
  </Card>

  <Card title="Add-ons and downloads" href="/security/add-ons-and-downloads">
    Pinned versions and SHA-256 digests, the check before anything is unpacked, add-ons the kit did not install, and removal.
  </Card>

  <Card title="What the kit writes" href="/security/what-the-kit-writes">
    The schemas the kit creates, which of your tables it will change and when, and the files it keeps on this computer.
  </Card>

  <Card title="Report a security issue" href="/security/report-an-issue">
    Where to send a vulnerability, and what the repository does and does not publish about it.
  </Card>
</Cards>

## Known limits, from the code [#known-limits-from-the-code]

These are the places where the code does less than a reader might assume. Each is explained on its page.

| Limit                                        | What the code does                                                                                                                                                           | Where                                                     |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| `exakit sql` runs as the admin user          | It uses the exapump admin profile and is not sandboxed. The read-only boundary is the MCP user, not this command                                                             | [AI clients](/security/ai-clients)                        |
| The read-only user reads every table         | It holds `SELECT ANY TABLE`, so an AI client can query personal-data columns. The sensitive-column rule limits what the kit sends to a model, not what the MCP user can read | [AI clients](/security/ai-clients)                        |
| The MCP server has no token                  | It runs with `--no-auth` on 127.0.0.1. Any program on this computer that reaches the port can send read queries                                                              | [AI clients](/security/ai-clients)                        |
| The MCP server connection is not pinned here | The sidecar definition sets `EXA_DSN` to the plain host and port and `EXA_SSL_CERT_VALIDATION` to `false`. The certificate pin is added to the other clients only            | [Network and TLS](/security/network-and-tls)              |
| One helper sends row text                    | `nb.themes()` sends the text of the rows you select to your model, up to 600 characters each. The sensitive-column rule does not apply to it                                 | [What is sent to a model](/security/what-goes-to-a-model) |
| Three add-ons can skip their checksum        | Setting `EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE`, `EXAKIT_ALLOW_UNVERIFIED_EXASOL_SCHEDULER` or `EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES` to `1` installs without a digest        | [Add-ons and downloads](/security/add-ons-and-downloads)  |
| A pasted connection string can lower TLS     | A SQL Server string with `encrypt=false` sets `tls=disable` for that source. You see the reading before you confirm it                                                       | [Network and TLS](/security/network-and-tls)              |
| Your passwords are plain text in a 0600 file | The admin password sits in the exapump profile, and the notebook store master password sits beside its store. Both are protected by file permissions only                    | [Credentials](/security/credentials)                      |
