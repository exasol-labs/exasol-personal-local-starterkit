---
name: exasol-vs-mongodb
description: Connect one MongoDB collection (Atlas or self-hosted) to local Exasol as tables with exakit connect mongodb. Covers the inputs to collect (a URI without credentials, database, collection, a reader account), finding them with the Atlas CLI and mongosh, a read-only database user, the Atlas IP access list that must hold this computer's public IP, the unattended connect line, how documents become a root table and child tables, quoting MongoDB's names, and the MongoDB-specific failures. Connector id mongodb, aliases mongo, atlas and mongodb-atlas, tier GA. Triggers — "connect MongoDB", "query a MongoDB collection from Exasol", "MongoDB Atlas", "connect Atlas to Exasol", "exakit connect mongodb", "error while reading collection metadata".
---

# MongoDB → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds,
disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is MongoDB's own.

## 1. When to use it

One MongoDB collection - Atlas or self-hosted - to query as tables from local
Exasol without copying it. **One source per collection.** Its root table
carries the scalar fields; each nested object and array becomes a child table
(sample_mflix.movies: 12 tables). The schema is inferred from a bounded sample.
The adapter is exasol-labs' (0.1.3) in the Rust language container. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `uri` | yes | | mongodb-uri | `mongodb+srv://host/?...` or `mongodb://host:27017/?...` - no `user:password@` |
| `database` | yes | | mongo-name | the database |
| `collection` | yes | | mongo-name | the one collection to expose |
| `user` | yes | | text | the reader account |
| `password` | yes | | secret | its password - only through `--password-file` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`. Give one host
or the `mongodb+srv://` name, not a host list, and keep `authSource=admin`:
the adapter signs in against `admin`.

## 3. Find each value (read-only)

```bash
atlas projects list
atlas clusters list --projectId <project-id>
atlas clusters connectionStrings describe <cluster> --projectId <project-id>   # the mongodb+srv:// address
mongosh "<uri>" --username <admin> --eval 'db.adminCommand({listDatabases: 1, nameOnly: true})'
mongosh "<uri>" --username <admin> --eval 'db.getSiblingDB("<database>").getCollectionNames()'
```

In Atlas: Clusters > Connect > Drivers shows the `mongodb+srv://` string; drop
its `<db_password>` part. A URI fills uri, database and user:
`--url 'mongodb+srv://exakit_reader@<cluster-host>/<database>?authSource=admin'`
(a password or credential parameter in it is never used).

## 4. Prepare a reader at the source (recommended role; show, then run on a yes)

The adapter needs only MongoDB's `find` on the collection: role `read` on the
database.

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

## 5. Network

`exakit connect` shows this computer's public IP; allow that address at the
source. Fallback: the `python3` one-liner in the shared skill. Run a change only
after a yes.

- **Atlas** answers only addresses in the project's IP access list. Avoid a
  temporary entry: when it expires, the source stops working.
  `atlas accessLists create <public-ip> --type ipAddress --comment exakit --projectId <project-id>`
- **Self-hosted**: `net.bindIp` must cover the interface and the firewall pass
  port 27017. On this computer use `192.168.64.1` (macOS) in the URI; on Linux
  and WSL the address the database sees this computer at (Podman:
  `host.containers.internal`; Docker: `host.docker.internal` where the deployment
  provides it, else the bridge gateway).

## 6. Connect

```bash
exakit connect mongodb --name movies --set "uri=mongodb+srv://<cluster-host>/?authSource=admin" \
  --set database=sample_mflix --set collection=movies --set user=exakit_reader --dry-run
exakit connect mongodb --name movies --set "uri=mongodb+srv://<cluster-host>/?authSource=admin" \
  --set database=sample_mflix --set collection=movies --set user=exakit_reader \
  --password-file ~/.config/exakit/movies.pw --yes --json
```

- The URI carries no credentials: user and password go into the CONNECTION,
  hidden. Atlas `mongodb+srv://` addresses resolve from inside the database.
- First use installs the Rust language container - at once at a terminal, with
  `--yes` in a script (tell the user first - one restart). The adapter and its scan UDF
  (`EXAKIT_VS.MONGODB_ADAPTER`, `MONGODB_SCAN`) are shared by every MongoDB
  source; the last one removed drops them.
- The tables appear as `VS_MOVIES`.

## 7. Verify

```bash
exakit source check movies
exakit source describe movies      # the root table and its child tables
exakit sql 'SELECT "title", "year" FROM VS_MOVIES.MOVIES LIMIT 10'
```

The collection is the upper-case root table (`MOVIES`); its fields and child
tables keep MongoDB's spelling, so quote them: `VS_MOVIES."MOVIES_writers_arr"."_value"`.
A child table joins its root on `"_parent" = root."_id"`; `mongo_id` is the
document's ObjectId.

## 8. When it fails

| Message | Fix |
|---|---|
| "error while reading collection metadata" | a wrong password, this computer's IP not in the Atlas access list, or the server unreachable - the adapter does not say which: check the password (reauth tries it first), the access list, the URI |
| "collection ... does not exist" | no such collection - or the account may not read that database (reported the same way): the name and the `read` role |
| "Error code 13 (Unauthorized): not authorized on <db> to execute command" (`privilege`) | signed in, but no `read` role on that database (section 4) |
| "the MongoDB URI carries credentials" | take `user:password@` out; `--set user=` and `--password-file` |
| "is not a valid mongodb-uri" | `mongodb://` or `mongodb+srv://`, host, options - nothing else |
| `norust` (exit 23) | the Rust language container is missing: rerun with `--yes` after telling the user |

## 9. Keep it working

- New password: `exakit source reauth movies --password-file <file>` - tried on
  a throwaway schema first; a refused one keeps the old.
- The collection's shape changed: `exakit source refresh movies` (columns come
  from a sample).
- Stop: `exakit source disconnect movies` or `exakit source remove movies`
  (`--dry-run` first, then ask) - see the shared skill.
