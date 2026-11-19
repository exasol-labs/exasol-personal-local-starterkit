# BucketFS Concepts

**BucketFS** is a synchronous distributed file system available on all nodes of
an Exasol cluster. Files stored in BucketFS are automatically replicated to
every cluster node. Replication is not instantaneous: while an upload is still
being synchronised, different nodes can serve different content for the same
path, so treat a fresh upload as usable only once synchronisation has finished.

## The Service / Bucket / Path Model

- **Service**: A named BucketFS instance. The default service is `bfsdefault`.
- **Bucket**: A storage container within a service. The default bucket in `bfsdefault` is `default`.
- **Path inside BucketFS**: Files are referenced by the path within the bucket (e.g., `models/my_model.pkl`).
- **Local path inside UDFs**: Files are accessible at `/buckets/<service>/<bucket>/<path>` (e.g., `/buckets/bfsdefault/default/models/my_model.pkl`).

The two path forms matter constantly: `exapump bucketfs` commands take the
bucket-relative path (`models/my_model.pkl`), while UDF code opens the absolute
mounted path (`/buckets/bfsdefault/default/models/my_model.pkl`). The same file
is named differently on each side.

## Archives Are Extracted Automatically

An upload whose name carries a recognised archive extension (`.tar.gz`,
`.tar.bz2`, or `.zip`) is extracted inside the cluster. Clients that list
or download the bucket see the archive file; UDFs see the extracted tree under
the mount path with the extension dropped, so an upload to `slc/my_slc.tar.gz`
is read from `/buckets/bfsdefault/default/slc/my_slc/...`. Reference the
extracted directory, never the archive name, from UDF and language-container
paths.

Two consequences: the archive and its extracted contents both consume bucket
space, and extraction takes time on top of replication — the extracted tree is
safe to use only after it finishes. To keep an archive packed, upload it under
an extension BucketFS does not recognise (e.g. `.zipx`).

## Characteristics and Limits

- Writes are atomic — a file is either fully written or not at all.
- No locking between concurrent writers and no transactions; the latest write wins.
- Uploading to a path that was just deleted can fail (HTTP 423 Locked / access
  denied). Wait roughly 30 seconds before re-uploading the same path, or upload
  under a new name.
- BucketFS is not included in database backups — manage backups separately.
- Not suited for very large datasets due to replication overhead.

Because there are no locks, a file that a running UDF is reading can be
replaced underneath it. Version model and library files by name
(`model-2026-03-01.pkl`) rather than overwriting a fixed path when UDFs may be
running; that also avoids the delete-then-re-upload failure above.
