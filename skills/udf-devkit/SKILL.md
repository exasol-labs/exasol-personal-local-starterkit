---
name: udf-devkit
addon: udf-devkit
description: Make Python and Rust UDFs work on the local Exasol Personal database with the udf-devkit add-on — covering why a local database runs no UDF until a script language container is installed, exakit udf-setup for the official Python container or the pinned Rust one (--language rust, EXAKIT_UDF_LANGUAGE), exakit udf-use default for the prebuilt machine-learning container picked for the database's architecture and verified against its digest, your own tarball, exakit udf-build from a pinned requirements file, the smoke UDF that proves each install (Python's reports package versions, Rust's is the CI-built libexakit_smoke.so reporting container, rustc and exasol-udf-sdk, refused by the database with F-UDF-CL-RUST-9001 when its ABI fingerprint differs), the database restart every install brings, the --json answers and exit codes naming language and step, and exakit udf-file because a local database has no BucketFS upload service. Triggers — "score a model in the database", "upload a model for a UDF", "exakit model put", "run a Python UDF", "run a Rust UDF", "my UDF says the script language is not found", "install a script language container", "add scikit-learn to my UDFs", "build a custom container", "install udf-devkit", "upload a model to BucketFS", "where do UDF files go", "PYTHON3 alias", "RUST alias", "no container for this architecture", "digest mismatch", "F-UDF-CL-RUST-9001", "Rust smoke UDF", "EXAKIT_SMOKE".
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
serves the file offline; `EXAKIT_UDF_ARCH` overrides the architecture.

### Rust

The Rust container (`exasol-labs/language-container-rs` v0.33.0: rustc 1.98.1,
exasol-udf-sdk 0.33.0) is installed the same way under alias `RUST`, and
proven by the kit's **prebuilt Rust smoke UDF**: `libexakit_smoke.so`, built by
CI (`.github/workflows/rust-smoke.yml` from `udf/rust-smoke`, inside
`rust:1.98.1-trixie` with `cargo-exasol-udf` 0.33.0, one per architecture) and
pinned as the Rust row's `smoke_asset` in `versions.json`. `exakit udf-setup
--language rust` verifies the bundled Linux library *before* the install (a
wrong digest is exit 7, step `verify`, and the database is not restarted), copies it into
the bucket directory as `udf/libexakit_smoke.so`, registers
`STARTER_KIT.EXAKIT_SMOKE(x BIGINT) RETURNS VARCHAR(2000) AS %udf_object
/buckets/bfsdefault/default/udf/libexakit_smoke.so`, runs it once and holds
the reported rustc and sdk against the row (`--json` `smoke`: `container`,
`rustc`, `sdk`, `rustc_full`). An installed `RUST` is proven without a
reinstall (`--force` reinstalls; `udf-use default --language rust` updates it).
A library the database refuses (`F-UDF-CL-RUST-9001`: its ABI fingerprint
`SDK_VERSION:RUSTC_VERSION` is not the container's) or a rustc other than the
pinned one is exit 7, step `smoke`, both versions in the reason. The kit ships
both architecture-specific smoke libraries and their SHA-256 and size pins;
a release URL can be added later as a verified fallback. Build
inside the pinned Linux image, including when driving Docker from a Mac: a
macOS host cannot emit a Linux `.so`. A Rust UDF of the user's own is `exakit
rust-udf` (the next kit step); the smoke UDF's `udf/` folder in the bucket is
where it goes too.

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
| Rust: "rustc reported X, pinned 1.98.1" or `F-UDF-CL-RUST-9001` (exit 7, step `smoke`) | The cached library was built for another toolchain: remove `~/.exasol-starter-kit/cache/containers/libexakit_smoke-<arch>.so`, run `exakit udf-setup --language rust` again; if it repeats, `exakit update` |
| Rust: "smoke UDF library ... is not pinned in this kit's versions.json yet" (exit 7, step `smoke`) | Expected before the first CI build: the `RUST` container is installed and usable; `exakit update` once a release pins the library |
| Rust: "smoke UDF library ... does not match its pinned digest" (exit 4, step `verify`) | Run `exakit udf-setup --language rust` again: the file was removed, the container untouched |
| "needs a running Docker engine" | Start Docker Desktop, Colima or the Podman machine, then retry |
| The database did not come back after an install | `exakit start` |
| A package is reported MISSING | Pin it in requirements.txt and run `exakit udf-build` |
