# MongoDB · Federation guide

> **Federation** lets your local Exasol query MongoDB data in place, without copying it.
> `exakit connect mongodb` makes it a virtual schema, `VS_<NAME>`, that you query with SQL.

One MongoDB collection (Atlas or self-hosted), read as a root table plus one
child table for each nested object and array. The columns come from a sample
of the documents.

## At a glance

| You need | Where to find it |
|---|---|
| The URI, without the password | Atlas: Connect → Drivers ([step 1](#1-uri)) |
| Database and collection | Atlas: Browse Collections, or `mongosh` ([step 2](#2-database-and-collection)) |
| A read-only user (role `read`) | Atlas: Database Users, or `createUser` ([step 3](#3-a-read-only-user)) |
| Your IP in the access list | Atlas: IP Access List ([step 4](#4-open-the-network)) |

## The simplest way: ask your AI agent

**Easiest: let your AI agent do it.** The kit installs the skill
`exasol-vs-mongodb` for your AI client; it knows this connector.

Copy this prompt, fill in the `<...>` parts, and give it to your agent:

```text
Connect the MongoDB collection <collection> of the database <database> on
<cluster or host> to my local Exasol with exakit. Use the exasol-vs-mongodb
skill. Create a read-only user for it and open the network for my IP. Write the
password to a file, never into the chat.
```

**You still need, on your computer:** the Atlas UI in a browser or the
`atlas` CLI (`atlas auth login`) for Atlas; `mongosh` as an admin for a
self-hosted server.

**Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

### Required

| Field | Example |
|---|---|
| Name (alias) for this connection | `movies` (gives the schema `VS_MOVIES`) |
| MongoDB URI (without password) | `mongodb+srv://cluster0.abcde.mongodb.net/?authSource=admin` |
| Database | `sample_mflix` |
| Collection | `movies` |
| Username | `exakit_reader` |
| Password | (hidden) |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| (none) | Every field is required. | |

- The URI is kept without `user:password@`. A URI pasted with them gives the
  user and the password, which the database keeps in the CONNECTION.
- Keep `authSource=admin` (or leave it out): the adapter always signs in
  against `admin`.

## Where to find each value

Prepare the source in this order. Every step is a one-time setup.

### 1. URI

- **Atlas:** Clusters → `<cluster>` → Connect → Drivers → copy the
  `mongodb+srv://` string and drop its `<db_username>:<db_password>@` part.
  ```bash
  atlas clusters connectionStrings describe <cluster> --projectId <project-id>
  ```
- **Self-hosted:** `mongodb://<host>:27017/?authSource=admin`. Give one host, not
  a host list. A server on this computer: `192.168.64.1` on macOS, never `localhost`.

### 2. Database and collection

Atlas: Clusters → `<cluster>` → Browse Collections. Or:

```bash
mongosh "<uri>" --username <admin> --eval 'db.getSiblingDB("sample_mflix").getCollectionNames()'
```

### 3. A read-only user

The adapter needs only `find` on the collection: role `read` on the database,
for a user of the `admin` database.

- **Atlas:** Security → Database & Network Access → Database Users → Add New
  Database User → Password → Built-in Role / Specific Privileges: `read` on
  `sample_mflix` → Add User.
  ```bash
  atlas dbusers create --username exakit_reader --role read@sample_mflix --projectId <project-id>
  ```
- **Self-hosted**, in `mongosh` as an admin:
  ```javascript
  db.getSiblingDB('admin').createUser({user: 'exakit_reader', pwd: passwordPrompt(),
    roles: [{role: 'read', db: 'sample_mflix'}]});
  ```

### 4. Open the network

Get your public IP: `curl https://checkip.amazonaws.com` (`exakit connect` prints it too).

- **Atlas:** Security → Database & Network Access → IP Access List → Add IP
  Address → your IP. Make it permanent: a temporary entry stops the source
  when it expires.
  ```bash
  atlas accessLists create <your-ip> --type ipAddress --comment exakit --projectId <project-id>
  ```
- **Self-hosted:** `net.bindIp` must cover the interface and the firewall must
  pass port 27017.

## Connect

```bash
exakit connect mongodb
```

1. The kit prints your public IP.
2. It asks for a connection string (hidden). Press Enter on an empty line to
   type the fields instead.
3. It shows a plan, then connects.
4. The first connect enables Federation: it installs the Rust language
   container (one restart).

Your tables appear as `VS_MOVIES`.

Without prompts (put the password alone in an owner-only file):

```bash
exakit connect mongodb --name movies --set "uri=mongodb+srv://cluster0.abcde.mongodb.net/?authSource=admin" \
  --set database=sample_mflix --set collection=movies --set user=exakit_reader \
  --password-file ~/.config/exakit/movies.pw --yes
```

Add `--dry-run` to see the plan first.

**Windows:** paste the URI at the prompt; do not use `--url` with a URI that
contains `&`. Quoted names do not survive PowerShell 5.1 arguments: pipe the
statement in (`'SELECT "title" FROM VS_MOVIES.MOVIES' | exakit sql`) or use
`exakit sql --file query.sql`.

## Query

The root table is upper case (`MOVIES`); fields and child tables keep
MongoDB's spelling, so quote them.

```bash
exakit sql 'SELECT "title" FROM VS_MOVIES.MOVIES LIMIT 10'
```

```powershell
'SELECT "title" FROM VS_MOVIES.MOVIES LIMIT 10' | exakit sql
```

- A child table joins its root on `"_parent" = root."_id"`; `mongo_id` is the
  document's ObjectId. Example: `"MOVIES_writers_arr"."_value"`.
- Columns come from a sample of the documents. After the collection's shape
  changes, run `exakit source refresh movies`.

## Troubleshooting

| Error you see | Why | Fix |
|---|---|---|
| "error while reading collection metadata" | A wrong password, your IP not in the Atlas access list, or the server unreachable. The adapter does not say which. | Check all three; `exakit source reauth movies` for the password. |
| "collection ... does not exist" | A wrong name, or the user has no `read` role on that database. | Check the name; grant the role (step 3). |
| "not authorized on <db> to execute command" | The user lacks role `read`. | Grant role `read` on the database (step 3). |
| "the MongoDB URI carries credentials" | The URI field itself still holds `user:password@`. | Give the URI with `--url` or at the prompt (the kit takes `user:password@` out), or remove it. |
| New fields do not show | The columns come from a sample. | Run `exakit source refresh movies`. |

## Connection string you can paste

Reference. The string is optional: at the prompt, press Enter alone and
`exakit connect` asks for the fields one by one.

```text
mongodb+srv://exakit_reader@cluster0.abcde.mongodb.net/sample_mflix?authSource=admin
mongodb://exakit_reader@mongo.example.com:27017/sales?authSource=admin&tls=true
```

| String | Fills |
|---|---|
| `mongodb+srv://user@cluster.example.net/database?options` | URI (without the user), database and user |
| `mongodb://user@host:27017/database?options` | URI (without the user), database and user |

Type the collection. A `user:password@` in the string gives the password too:
the kit takes it out of the URI (never stored or shown) and does not ask again.

Leave the password out of the string. The kit asks for it at a hidden prompt,
or reads it from `--password-file`.

### Where to find the connection string

You do not build it: copy the address your provider shows.

- **Atlas:** Clusters → `<cluster>` → Connect → Drivers → copy the
  `mongodb+srv://` string. Turn off the SRV toggle for a `mongodb://` string.
- In the copied string, change `<db_username>:<db_password>@` to `<user>@`
  (the user without the password), or delete it and type the user.
- Add the database after the host (`...mongodb.net/<database>?...`) to fill it,
  or type it.
- **Self-hosted:** your team's `mongodb://<host>:27017/<database>?authSource=admin`.
  Give one host, not a host list.

### Where to find each part of the string

| Part of the string | Where to find it |
|---|---|
| host (cluster) | Atlas: Connect → Drivers, or `atlas clusters connectionStrings describe` ([step 1](#1-uri)). |
| user | The read-only user you make ([step 3](#3-a-read-only-user)). |
| database | `show dbs` in `mongosh` ([step 2](#2-database-and-collection)). |
| `authSource` | Keep `admin`, or leave it out. |

### `--set` keys

`uri`, `database`, `collection`, `user`. Give the password with
`--password-file` (or `--password-stdin`), never on the command line.
