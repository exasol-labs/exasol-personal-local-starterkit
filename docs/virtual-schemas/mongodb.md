# MongoDB

One MongoDB collection (Atlas or self-hosted), read as a root table plus one
child table for each nested object and array. The columns come from a sample
of the documents.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-mongodb` knows this connector.
>
> **You still need, on your computer:** the Atlas UI in a browser or the
> `atlas` CLI (`atlas auth login`) for Atlas; `mongosh` as an admin for a
> self-hosted server.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `movies` |
| MongoDB URI (without password) | yes | `mongodb+srv://cluster0.abcde.mongodb.net/?authSource=admin` |
| Database | yes | `sample_mflix` |
| Collection | yes | `movies` |
| Reader account | yes | `exakit_reader` |
| Password | yes | (hidden) |

The URI carries no `user:password@`. Keep `authSource=admin` (or leave it
out): the adapter always signs in against `admin`.

## Where to find each value

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

The kit prints your public IP, asks for a connection string (hidden; press
Enter on an empty line to type the fields instead), then each field above. It
shows a plan and asks once. The first connect installs the Rust language
container (one restart). Your tables appear as `VS_MOVIES`.

Without prompts (put the password alone in an owner-only file):

```bash
exakit connect mongodb --name movies --set "uri=mongodb+srv://cluster0.abcde.mongodb.net/?authSource=admin" \
  --set database=sample_mflix --set collection=movies --set user=exakit_reader \
  --password-file ~/.config/exakit/movies.pw --yes
exakit sql 'SELECT "title" FROM VS_MOVIES.MOVIES LIMIT 10'
```

The root table is upper case (`MOVIES`); fields and child tables keep
MongoDB's spelling, so quote them. Add `--dry-run` to see the plan first.

**Windows:** paste the URI at the prompt; do not use `--url` with a URI that
contains `&`. Quoted names do not survive PowerShell 5.1 arguments: pipe the
statement in (`'SELECT "title" FROM VS_MOVIES.MOVIES' | exakit sql`) or use
`exakit sql --file query.sql`.

## Connection string you can paste

```text
mongodb+srv://exakit_reader@cluster0.abcde.mongodb.net/sample_mflix?authSource=admin
mongodb://exakit_reader@mongo.example.com:27017/sales?authSource=admin&tls=true
```

Each fills the URI (without the user), database and user; type the
collection. A password in the string is never used.

## Common problems

| Symptom | Fix |
|---|---|
| "error while reading collection metadata" | A wrong password, your IP not in the Atlas access list, or the server unreachable (the adapter does not say which): check all three; `exakit source reauth movies` for the password. |
| "collection ... does not exist" | A wrong name, or the user has no `read` role on that database (step 3). |
| "not authorized on <db> to execute command" | Grant role `read` on the database (step 3). |
| "the MongoDB URI carries credentials" | Remove `user:password@` from the URI. |
| New fields do not show | Run `exakit source refresh movies`: the columns come from a sample. |
