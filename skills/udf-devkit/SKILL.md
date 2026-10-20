---
name: udf-devkit
addon: udf-devkit
description: Make Python UDFs work on the local Exasol Personal database with the udf-devkit add-on — covering why a local database runs no UDF until a script language container is installed, exakit udf-setup for the official container, exakit udf-use for the prebuilt machine-learning one or your own tarball, exakit udf-build from a pinned requirements file, the smoke UDF that proves each install, the database restart every install brings, and exakit udf-file because a local database has no BucketFS upload service. Triggers — "run a Python UDF", "my UDF says the script language is not found", "install a script language container", "add scikit-learn to my UDFs", "build a custom container", "install udf-devkit", "upload a model to BucketFS", "where do UDF files go", "PYTHON3 alias".
---

# udf-devkit — Python UDFs on the local database

A local Exasol Personal database ships with **no script language container**,
so `CREATE PYTHON3 SCALAR SCRIPT ...` fails until one is installed. And it has
**no BucketFS upload service**: its BucketFS is a folder in the deployment,
which the database reads under `/buckets`. The `udf-devkit` marketplace add-on
handles both through the Exasol launcher (2.3.0 or later). The ml-engineer
persona installs it.

## Every container install restarts the database

Say so before running one. The command asks; `--yes` answers, and so does a run
with no terminal. Running add-on services are stopped first and started again
after the database answers. Each install ends with a smoke UDF in the
`EXAKIT_UDF` schema that reports every package's version, so a missing package
shows now, not in the user's first UDF.

## Which command

| The user wants | Run | Alias |
|---|---|---|
| Python UDFs, standard library | `exakit udf-setup` | `PYTHON3` |
| numpy, pandas, scikit-learn | `exakit udf-use default` | `PYTHON3_ML` |
| Their own container tarball | `exakit udf-use <file.tar.gz> --alias NAME` | `NAME` |
| Packages the prebuilt lacks | `exakit udf-build requirements.txt` | `PYTHON3_CUSTOM` |
| What is installed | `exakit udf-use --list` | |

`exakit udf-build` needs every line pinned (`name==version`), a running Docker
engine, about 25 GB free and the notebook add-on; it refuses and names what is
missing. The first build takes a long time.

Write the UDF with the alias: `CREATE OR REPLACE PYTHON3_ML SCALAR SCRIPT ...`.

## Files a UDF reads

```bash
exakit udf-file model.pkl models/model.pkl
# prints: /buckets/bfsdefault/default/models/model.pkl
```

Open that path inside the UDF. No restart is needed. Never tell a user to
upload to BucketFS over HTTP, with `exasol-bucketfs` or with curl on port 2580
or 2581: a local deployment does not serve it.

## When something is wrong

| Symptom | Do this |
|---|---|
| "needs Exasol launcher 2.3.0 or later" | `exakit update personal` |
| "No prebuilt container is published for this machine yet" | `exakit udf-build requirements.txt` |
| "needs a running Docker engine" | Start Docker Desktop or Colima, then retry |
| The database did not come back after an install | `exakit start` |
| A package is reported MISSING | Pin it in requirements.txt and run `exakit udf-build` |
