---
name: exasol-vs-mongodb
description: Connect one MongoDB collection (Atlas or self-hosted) to local Exasol as tables with exakit connect mongodb. Covers the inputs to collect (a URI without the password, database, collection, a reader account) and where each is in Atlas, a read-only database user, the Atlas project IP access list that must hold this computer's public IP, the unattended connect line, how documents become a root table and child tables, quoting MongoDB's names in the bash and PowerShell forms, and the MongoDB-specific failures. Connector id mongodb, aliases mongo, atlas and mongodb-atlas, tier GA. Triggers — "connect MongoDB", "query a MongoDB collection from Exasol", "MongoDB Atlas", "connect Atlas to Exasol", "exakit connect mongodb", "error while reading collection metadata".
---

# MongoDB → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds,
disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is MongoDB's own.

## 1. When to use it

One MongoDB collection - Atlas or self-hosted - queried as tables from local
Exasol without copying it. **One source per collection.** Its root table
carries the scalar fields; each nested object and array becomes a child table
(sample_mflix.movies: 12 tables). The schema is inferred from a bounded sample.
The adapter is exasol-labs' exasol-mongodb-vs (0.1.3) in the Rust language
container. Tier GA.

## 2. Fields

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `uri` | yes | | Atlas > Database > Clusters > Connect > Drivers: the `mongodb+srv://` string without `user:password@`; self-hosted `mongodb://host:27017/?...` |
| `database` | yes | | Atlas > Database > Browse Collections, or `listDatabases` below |
| `collection` | yes | | the same view: the one collection to expose |
| `user` | yes | | Atlas > Security > Database Access: the reader account |
| `password` | yes | | its password - only through `--password-file` or a closed stdin pipe |

The first question, "Name (alias) for this connection", is the source name
(`movies`): its tables appear in schema `VS_MOVIES`.

- Give one host or the `mongodb+srv://` name, not a host list.
- Keep `authSource=admin` or leave it out: the adapter always signs in against
  `admin`, so another `authSource` is refused.

Read-only discovery:

```bash
atlas projects list
atlas clusters list --projectId <project-id>
atlas clusters connectionStrings describe <cluster> --projectId <project-id>   # the mongodb+srv:// address
mongosh "<uri>" --username <admin> --eval 'db.adminCommand({listDatabases: 1, nameOnly: true})'
mongosh "<uri>" --username <admin> --eval 'db.getSiblingDB("<database>").getCollectionNames()'
```

## 3. Connection-string forms

`--url` (or the hidden paste prompt) reads:

- `mongodb+srv://user@cluster.example.net/database?options`
- `mongodb://user@host:27017/database?options`

It fills `uri`, `database` and `user`. A password, or an
`authMechanismProperties` option, is never used: it is dropped and the
credential asked for separately, hidden.

On Windows, cmd.exe splits an argument at `&` on its way through `exakit.cmd`.
A URI with two or more options therefore breaks as `--url` or `--set uri=`.
Paste it at the hidden prompt of `exakit connect`, or give a URI with one option
(`?authSource=admin`) and the rest with `--set`.

## 4. Prepare the source (recommended role; show, then run on a yes)

The adapter needs only MongoDB's `find` on the collection: role `read` on the
database, for a user of the `admin` database.

- **Atlas** (`db.createUser` is not supported there): the user runs, in their
  own terminal, `atlas dbusers create --username exakit_reader --role read@<database> --projectId <project-id>`,
  or adds the user in Security > Database Access with password authentication.
  The password never goes on the command line; they write it to
  `~/.config/exakit/<name>.pw` (owner-only) themselves.
- **Self-hosted**: the password from the shared recipe, read inside mongosh:

```bash
cat > ~/.config/exakit/<name>-reader.js <<'JS'
const pw = require('fs').readFileSync(require('os').homedir() + '/.config/exakit/<name>.pw', 'utf8').trim();
db.getSiblingDB('admin').createUser({user: 'exakit_reader', pwd: pw, roles: [{role: 'read', db: '<database>'}]});
JS
mongosh "<uri>" --username <admin> --file ~/.config/exakit/<name>-reader.js
```

**Network.** Run a change only after a yes.

- **Atlas** has a project IP access list (Atlas > Security > Network Access). It
  must hold this computer's public IP, which `exakit connect` shows. Add it as a
  permanent entry: a temporary one stops the source when it expires.
  `atlas accessLists create <public-ip> --type ipAddress --comment exakit --projectId <project-id>`
- **Self-hosted**: `net.bindIp` must cover the interface, and the firewall must
  pass port 27017. `localhost` is refused. A server on this computer is
  `192.168.64.1` on macOS; on Linux and WSL, `host.containers.internal` (Podman)
  or `host.docker.internal` (Docker Desktop, 192.168.65.254 inside the database).

## 5. TLS

No CA file and no TLS input. The URI sets TLS: `mongodb+srv://` is TLS unless
`tls=false`; `tlsInsecure` or `tlsAllowInvalidCertificates` encrypt without
checking (shown as `require`). Atlas `mongodb+srv://` names resolve from inside
the database.

## 6. Connect

```bash
exakit connect mongodb --name movies --set "uri=mongodb+srv://<cluster-host>/?authSource=admin" \
  --set database=sample_mflix --set collection=movies --set user=exakit_reader --dry-run
exakit connect mongodb --name movies --set "uri=mongodb+srv://<cluster-host>/?authSource=admin" \
  --set database=sample_mflix --set collection=movies --set user=exakit_reader \
  --password-file ~/.config/exakit/movies.pw --yes --json
```

PowerShell takes the same line on one row, with
`$HOME\.config\exakit\movies.pw` as the file.

- The URI carries no credentials: user and password go into the CONNECTION,
  hidden.
- First use installs the Rust language container (pinned per CPU, one restart):
  at once at a terminal, with `--yes` in a script. Tell the user first.
- The adapter and its scan UDF (`EXAKIT_VS.MONGODB_ADAPTER`, `MONGODB_SCAN`) are
  shared by every MongoDB source; the last one removed drops them.

## 7. Verify and query

The collection is the upper-case root table (`MOVIES`); its fields and child
tables keep MongoDB's spelling, so they are quoted.

```bash
exakit source check movies
exakit source describe movies      # the root table and its child tables
exakit sql 'SELECT "title", "year" FROM VS_MOVIES.MOVIES LIMIT 10'
exakit sql 'SELECT m."title", w."_value" AS "writer" FROM VS_MOVIES.MOVIES m JOIN VS_MOVIES."MOVIES_writers_arr" w ON w."_parent" = m."_id" LIMIT 10'
```

Windows PowerShell 5.1 drops the inner double quotes of an argument, so these
queries are piped in, or saved to a file:

```powershell
'SELECT "title", "year" FROM VS_MOVIES.MOVIES LIMIT 10' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

- A child table joins its root on `"_parent" = root."_id"`; `mongo_id` is the
  document's ObjectId.
- Columns come from a sample of the documents. After the collection's shape
  changes, run `exakit source refresh movies`.

## 9. When it fails

| Message (`kind`) | Fix |
|---|---|
| "error while reading collection metadata" | a wrong password, this computer's IP not in the Atlas access list, or the server unreachable - the adapter does not say which: check the password (reauth tries it first), the access list, the URI |
| "collection ... does not exist" | no such collection - or the account may not read that database (reported the same way): check the name and the `read` role |
| "not authorized on <db> to execute command" (`privilege`) | signed in, but no `read` role on that database (section 4) |
| "the MongoDB URI carries credentials" | take `user:password@` out; `--set user=` and `--password-file` |
| "the MongoDB adapter always signs in against the admin database" | drop `authSource` or set it to `admin`; make the reader a user of admin |
| "the connection string names more than one host" | give one host, or the `mongodb+srv://` name |
| "is not a valid mongodb-uri" | `mongodb://` or `mongodb+srv://`, host, options - nothing else |
| `norust` (exit 23) | the Rust language container is missing: rerun with `--yes` after telling the user |

## 10. Keep it working

- New password: `exakit source reauth movies --password-file <file>`. It is
  tried first; a refused one keeps the old.
- The cluster moved, or another collection: `exakit connect mongodb --name movies
  --set uri=<new URI> --password-file <file> --yes` (`--dry-run` first).
  `VS_MOVIES` keeps its name, and the password is asked for again, as for every
  re-point; the change is tried before anything changes.
- The collection's shape changed: `exakit source refresh movies`.
- Stop: `exakit source disconnect movies` or `exakit source remove movies`
  (`--dry-run` first, then ask) - see the shared skill.
