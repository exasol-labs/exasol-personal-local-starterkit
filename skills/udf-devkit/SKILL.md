---
name: udf-devkit
addon: udf-devkit
description: Make Python and Rust UDFs work on the local Exasol Personal database with the udf-devkit add-on — covering why a local database runs no UDF until a script language container is installed, exakit udf-setup for the official Python container or the pinned Rust one (--language rust, EXAKIT_UDF_LANGUAGE), exakit udf-use default for the prebuilt machine-learning container picked for the database's architecture and verified against its digest, your own tarball, exakit udf-build from a pinned requirements file, the smoke UDF that proves each install, the database restart every install brings, the --json answers and exit codes naming language and step, and exakit udf-file because a local database has no BucketFS upload service. Triggers — "score a model in the database", "upload a model for a UDF", "exakit model put", "run a Python UDF", "run a Rust UDF", "my UDF says the script language is not found", "install a script language container", "add scikit-learn to my UDFs", "build a custom container", "install udf-devkit", "upload a model to BucketFS", "where do UDF files go", "PYTHON3 alias", "RUST alias", "no container for this architecture", "digest mismatch".
---

# udf-devkit — Python and Rust UDFs on the local database

A local Exasol Personal database ships with **no script language container**,
so `CREATE PYTHON3 SCALAR SCRIPT ...` (or `CREATE RUST SCALAR SCRIPT ...`)
fails until one is installed. And it has
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
| scikit-learn, pandas, numpy, scipy | `exakit udf-use default` | `PYTHON3_ML` |
| Rust UDFs | `exakit udf-setup --language rust` (or `udf-use default --language rust`) | `RUST` |
| Their own container tarball | `exakit udf-use <file.tar.gz> --alias NAME` | `NAME` |
| Packages the prebuilt lacks | `exakit udf-build requirements.txt` | `PYTHON3_CUSTOM` |
| What is installed | `exakit udf-use --list` | |

`exakit udf-use default` picks the row of the container matrix in
`versions.json` for the **database's** architecture (aarch64 on an
Apple-silicon Mac, x86_64 on Windows) and its version, downloads it once into
`~/.exasol-starter-kit/cache/containers`, verifies size and sha256 before the
launcher sees it, and the smoke UDF checks each package's version against the
pin. `EXAKIT_UDF_LANGUAGE=python|rust` is the default language for the commands
and the persona install; `EXAKIT_UDF_CONTAINERS_MIRROR` (a folder or base URL)
serves the file offline; `EXAKIT_UDF_ARCH` overrides the architecture. The Rust
container is installed the same way; its smoke UDF and `exakit rust-udf`
arrive with the next kit step, so until then `exasol slc list` showing `RUST`
is the proof.

Both commands take `--json` and answer `{ok, language, alias, container: {url,
sha256, arch, db_versions}, smoke: [{package, version}]}` or `{ok: false,
language, step, reason, remedy}` (step: `select-container`, `download`,
`verify`, `install`, `smoke`); exit codes 2 bad arguments, 3 a package missing,
4 no container for this architecture or database version or a digest mismatch,
5 not ready (add-on, database, launcher, download, not confirmed), 6 the
launcher's install failed, 7 the smoke UDF failed or reported another version.

`exakit udf-build` needs every line pinned (`name==version`), a running Docker
engine, about 25 GB free and the notebook add-on; it refuses and names what is
missing. The first build takes a long time.

Write the UDF with the alias: `CREATE OR REPLACE PYTHON3_ML SCALAR SCRIPT ...`.

## Files a UDF reads

```bash
exakit udf-file model.pkl models/model.pkl
# prints: /buckets/bfsdefault/default/models/model.pkl
```

Open that path inside the UDF. No restart is needed.

### Model files (a model trained anywhere)

```bash
exakit model put churn.pkl            # prints /buckets/bfsdefault/default/models/churn.pkl, digest recorded
exakit model put churn.pkl --replace  # a DIFFERENT file of the same name: exit 5 without --replace
exakit model list --json              # what is there; a file changed since it was put is flagged "changed"
exakit model template                 # where the scoring UDF template and its renderer are
python3 <kit>/udf/templates/render.py --schema S --name SCORE --model-path /buckets/bfsdefault/default/models/churn.pkl \
    --input category:VARCHAR(2000) --input doc_text:VARCHAR(2000000):text --output DOUBLE --method predict_proba
```

The template loads the model once per UDF instance (pickle, joblib or ONNX).
TEXT is a reserved word: a model column named `text` comes in as parameter
`doc_text`. The notebook `ml-engineer/03_score_external_model` walks through it. Never tell a user to
upload to BucketFS over HTTP, with `exasol-bucketfs` or with curl on port 2580
or 2581: a local deployment does not serve it.

## When something is wrong

| Symptom | Do this |
|---|---|
| "needs Exasol launcher 2.3.0 or later" | `exakit update personal` |
| "does not match its pinned digest" (exit 4, step `verify`) | Run `exakit udf-use default` again: the file was removed and is downloaded afresh |
| "No prebuilt ... container fits this database" (exit 4, step `select-container`) | `exakit update` may bring the row; until then `exakit udf-build requirements.txt` |
| "reported X, pinned Y" (exit 7) | Another container answers to the alias: `exakit udf-use --list`, remove the cached file, `exakit udf-use default` again |
| The `RUST` container is installed but there is no smoke UDF | Expected: it arrives with the next kit step |
| "needs a running Docker engine" | Start Docker Desktop, Colima or the Podman machine, then retry |
| The database did not come back after an install | `exakit start` |
| A package is reported MISSING | Pin it in requirements.txt and run `exakit udf-build` |
