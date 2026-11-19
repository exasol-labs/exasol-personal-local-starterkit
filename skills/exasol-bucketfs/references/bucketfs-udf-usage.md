# Staging Files in BucketFS for UDFs

Every pattern here is two steps: upload with the bucket-relative path, then
reference the mounted absolute path `/buckets/<service>/<bucket>/<path>` from
SQL or UDF code.

## Upload a JAR for a Java UDF

```bash
exapump bucketfs cp my_library.jar jars/my_library.jar
```

Reference in UDF SQL:
```sql
CREATE OR REPLACE JAVA SCALAR SCRIPT my_schema.my_func(input VARCHAR(2000))
RETURNS VARCHAR(2000) AS
  %scriptclass com.example.MyClass;
  %jar /buckets/bfsdefault/default/jars/my_library.jar;
/
```

## Upload an ML Model for a Python UDF

```bash
exapump bucketfs cp model.pkl models/model.pkl
```

Load in Python UDF:
```python
import pickle
with open('/buckets/bfsdefault/default/models/model.pkl', 'rb') as f:
    model = pickle.load(f)
```

Load the model once at module level rather than inside the row loop — the file
is read from the local node's replica, but unpickling per row is still the
dominant cost.

## Upload a Custom Script Language Container (SLC)

```bash
exapump bucketfs cp my_slc.tar.gz slc/my_slc.tar.gz
```

Then activate via SQL:
```sql
ALTER SESSION SET SCRIPT_LANGUAGES='PYTHON3=localzmq+protobuf:///bfsdefault/default/slc/my_slc?lang=python#buckets/bfsdefault/default/slc/my_slc/exaudf/exaudfclient_py3';
```

Note the two path spellings inside one statement: the container URL uses
`/bfsdefault/default/...` while the client path after `#` uses
`buckets/bfsdefault/default/...`. Both must point at the same upload.

Neither spelling carries the `.tar.gz` suffix: BucketFS extracts the archive and
UDFs see the extracted directory `slc/my_slc`. Wait for extraction to finish
before running a UDF against the new container.

For building the container in the first place, and for system-wide activation,
use **exasol-udfs**.

## Browse and Clean Up

```bash
exapump bucketfs ls -r                        # See all files
exapump bucketfs rm old_model.pkl             # Remove an outdated file
```

Confirm the exact bucket and path before removing anything — BucketFS is not
covered by database backups, so a deletion here is not recoverable from a
database restore. To replace a file, upload the new version under a new name
instead of deleting first: an upload shortly after a delete of the same path
can fail.
