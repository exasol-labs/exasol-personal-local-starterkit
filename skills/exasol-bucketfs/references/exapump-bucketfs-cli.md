# The `exapump bucketfs` CLI

The `exapump` command is the CLI tool for managing BucketFS. All BucketFS operations use the `exapump bucketfs` subcommand.

## Connection Configuration

exapump connects through saved profiles; pass `--profile <name>` **after the
subcommand** to select one, as in `exapump bucketfs ls --profile production`.
A profile's BucketFS section — host, port, bucket, and the read and write
passwords — is prompted for by `exapump profile init` and
`exapump profile edit <name>`, so never dictate the underlying field names or
edit them by hand. `exapump bucketfs --help` lists the per-command `--bfs-*`
overrides; prefer the profile over passing a password on the command line,
where it lands in the process list and the shell history.

The BucketFS settings fall back to their database counterparts when unset: the
BucketFS host to the profile's `host`, TLS and certificate validation to the
database values, and the read password to the write password. A BucketFS
command that reaches an unexpected host, or authenticates when you expected it
to fail, is usually a fallback rather than an explicit setting.

exapump selects a bucket, not a service: it has no `--bfs-service` flag and no
`bfs_service` profile field, and its defaults address the `bfsdefault` service
on port `2581`. Treat every `exapump bucketfs` command as operating on
`bfsdefault`. If the user asks for a different BucketFS service, say that
exapump does not select one instead of guessing at flags. The service name
still matters for the UDF mount path `/buckets/<service>/<bucket>/<path>`.

## Configuration Protocol

**Before any BucketFS operation**, verify the connection is configured:

1. Run `exapump bucketfs ls` (add `--profile <name>` after the subcommand for a
   named profile). If it succeeds, the profile is usable — proceed.
2. On failure, run `exapump profile list`, then inspect the intended profile
   with `exapump profile show <name>` — it masks credentials — and check
   whether its BucketFS settings are present.
3. **Never read, `cat`, or print `~/.exapump/config.toml`**; it stores
   credentials in clear text. If a credential value appears in any command
   output, do not repeat it in the conversation.
4. If settings are missing, have the user fill them in locally with
   `exapump profile edit <name>`, or create the profile with
   `exapump profile init <name>`; both prompt for the BucketFS section and ask
   for passwords on a hidden line. Do not ask them to paste passwords into
   chat, guess values, or echo secret values.

## `ls` — List Contents

```bash
exapump bucketfs ls [PATH] [OPTIONS]
exapump bucketfs ls -r [PATH]            # Recursive listing
exapump bucketfs ls --recursive [PATH]
```

**Examples:**
```bash
exapump bucketfs ls                      # List bucket root
exapump bucketfs ls models/             # List a directory
exapump bucketfs ls -r models/          # Recursively list all files under models/
```

## `cp` — Copy / Upload / Download

Direction is automatically determined by the source type (local file vs. BucketFS path).

Upload a local file to BucketFS:
```bash
exapump bucketfs cp <local-file> <bucket-path>
exapump bucketfs cp <local-file> <bucket-dir>/    # Preserve filename
```

Download a file from BucketFS to local:
```bash
exapump bucketfs cp <bucket-path> <local-path>
```

**Examples:**
```bash
exapump bucketfs cp my_model.pkl models/my_model.pkl     # Upload with explicit name
exapump bucketfs cp my_model.pkl models/                 # Upload, preserve filename
exapump bucketfs cp library.jar jars/library.jar         # Upload JAR for UDF
exapump bucketfs cp models/my_model.pkl .                # Download to current dir
exapump bucketfs cp models/my_model.pkl ./local-copy.pkl # Download with rename
```

## `rm` — Remove a File

```bash
exapump bucketfs rm <path-in-bucket>
```

**Examples:**
```bash
exapump bucketfs rm models/old_model.pkl     # Delete a single file
```

Uploading to a path that was just deleted can fail (HTTP 423 Locked / access
denied) — reported for uploads within about 30 seconds of the delete. Upload
the replacement under a new name, or wait before reusing the same path.

## Safety

Before running `rm`, show the exact bucket, path, and profile, then obtain
explicit confirmation. Before a `cp` that would overwrite an existing
BucketFS or local file, inspect the target and obtain confirmation. Never print
profile passwords or pass them as command-line arguments when a profile can
hold them securely.
