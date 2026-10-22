#!/usr/bin/env bash
# dataset-asset.sh — proves how a reference dataset's CSVs reach exakit
# data-load: the kit copy when its digests match the manifest, else the verified
# cache, else the release asset - downloaded, checked against its SHA-256,
# extracted safely, every CSV checked again, then cached and loaded.
#
#   bash tests/dataset-asset.sh
#
# Offline: the "release" is a mirror folder (EXAKIT_DATASETS_MIRROR), the
# network fetch is stubbed, exapump is a stub, and every path is in a temporary
# kit home. The PowerShell twin is tests/dataset-asset-ps.ps1.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected <%s>, got <%s>\n' "$1" "$2" "$3"
    fi
}

has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING in: $3" ;; esac
}

lacks() { # lacks <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "absent" "PRESENT in: $3" ;; *) check "$1" "absent" "absent" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
HOME="$WORK/fake-home"
export HOME
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$HOME"
unset EXAKIT_DATASETS_MIRROR EXAKIT_DATASETS_REPO

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/exapump.sh"

# Never a managed Python: the system one, and a record of every call.
run_python_any() { printf 'py %s\n' "$2" >> "$WORK/python.calls"; python3 "$@"; }
EXAKIT_LOG_FILE="$WORK/test.log"
: > "$EXAKIT_LOG_FILE"
CACHE="$EXAKIT_CACHE_DIR/datasets"

# --- a small reference dataset in a kit of its own ----------------------------
KIT="$WORK/kit"
DS="$KIT/data/datasets/demo_ref"
mkdir -p "$KIT/setup/lib" "$DS/data"
cp "$ROOT/setup/lib/dataset_asset.py" "$KIT/setup/lib/"
printf 'id=demo_ref\nlabel=Demo reference (synthetic, ~3 rows)\nschema=DEMO_REF\nmarkers=DEMO_ITEMS\norder=60\n' > "$DS/dataset.conf"
printf 'CREATE SCHEMA IF NOT EXISTS DEMO_REF;\nOPEN SCHEMA DEMO_REF;\nCREATE OR REPLACE TABLE DEMO_ITEMS (\n    ITEM_ID DECIMAL(9,0) NOT NULL,\n    NAME VARCHAR(20),\n    CONSTRAINT DEMO_ITEMS_PK PRIMARY KEY (ITEM_ID)\n);\n' > "$DS/01_create_schema.sql"
printf 'ITEM_ID,NAME\n1,a\n2,b\n3,c\n' > "$DS/data/demo_items.csv"
printf 'NOTE_ID,TEXT\n1,x\n' > "$DS/data/demo_notes.csv"
GOOD_ITEMS="$(cat "$DS/data/demo_items.csv")"

# The manifest and the archive, made by the same packager the kit's datasets use.
python3 - "$ROOT" "$DS" "$WORK/dist" <<'PYEOF'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "tools" / "datasets"))
import package
folder = Path(sys.argv[2])
files = {f"data/{p.name}": {"rows": 1, "sha256": h} for p, h in
         ((p, package.file_digests(folder)[f"data/{p.name}"]) for p in package.csv_paths(folder))}
(folder / "manifest.json").write_text(json.dumps({"id": "demo_ref", "source": {"name": "x", "url": "https://x"},
    "terms": {"url": "https://x", "summary": "x", "confirmed": True}, "snapshot": "2026-01-02", "files": files}, indent=2))
package.package(folder, Path(sys.argv[3]))
PYEOF
ARCHIVE="demo_ref-2026-01-02.tar.gz"
MIRROR="$WORK/mirror"
mkdir -p "$MIRROR"
cp "$WORK/dist/$ARCHIVE" "$MIRROR/"
SHA="$(_exakit_dataset_asset_field "$DS/manifest.json" sha256)"
check "the manifest names the archive" "$ARCHIVE" "$(_exakit_dataset_asset_field "$DS/manifest.json" file)"
check "the url template carries {repo}" \
    "https://github.com/{repo}/releases/download/datasets-demo_ref-2026-01-02/$ARCHIVE" \
    "$(_exakit_dataset_asset_field "$DS/manifest.json" url)"

# The network: never touched. A download records its URL and fails, like a
# machine with no route out; an "online" one copies from the mirror instead.
fetch_quiet() { printf '%s\n' "$1" >> "$WORK/fetch.calls"; return 1; }
reset_cache() { rm -rf "$CACHE"; : > "$WORK/fetch.calls"; : > "$WORK/python.calls"; }

printf '\n== the kit copy, when its digests match ==\n'
reset_cache
exakit_dataset_files "$KIT" "$DS" demo_ref
check "the kit copy is used" "0:$DS/data" "$?:$EXAKIT_DATASET_DATA_DIR"
check "nothing was downloaded" "" "$(cat "$WORK/fetch.calls")"
check "nothing was cached" "no" "$([ -d "$CACHE/demo_ref" ] && echo yes || echo no)"
check "no download is announced in the listing" "" "$(exakit_dataset_download_note "$DS")"

printf '\n== a kit copy that does not match is ignored ==\n'
reset_cache
printf 'ITEM_ID,NAME\n1,a\n2,b\n3,TAMPERED\n' > "$DS/data/demo_items.csv"
OUT="$(EXAKIT_DATASETS_MIRROR="$MIRROR" exakit_dataset_files "$KIT" "$DS" demo_ref 2>&1; printf 'rc=%s dir=%s' "$?" "$EXAKIT_DATASET_DATA_DIR")"
has "the archive is used instead" "rc=0 dir=$CACHE/demo_ref/$SHA/data" "$OUT"
has "the download is said, with its size" "Downloading the 'demo_ref' data (0.1 MB" "$OUT"
check "the cached CSV is the manifest's, not the tampered one" "$GOOD_ITEMS" "$(cat "$CACHE/demo_ref/$SHA/data/demo_items.csv")"
check "the cache is marked verified" "$SHA" "$(cat "$CACHE/demo_ref/$SHA/.verified")"
check "no partial download is left" "" "$(ls "$CACHE/demo_ref" | grep '\.part$')"
has "the log says why the kit copy was passed over" "do not match manifest.json" "$(cat "$EXAKIT_LOG_FILE")"

printf '\n== the cache is reused: no mirror, no network ==\n'
rm -rf "$DS/data"                               # the installed kit: no CSVs in its copy
: > "$WORK/fetch.calls"
exakit_dataset_files "$KIT" "$DS" demo_ref
check "the verified extraction is used" "0:$CACHE/demo_ref/$SHA/data" "$?:$EXAKIT_DATASET_DATA_DIR"
check "nothing was downloaded" "" "$(cat "$WORK/fetch.calls")"
check "no download is announced while it is cached" "" "$(exakit_dataset_download_note "$DS")"
printf 'ITEM_ID,NAME\n9,z\n' > "$CACHE/demo_ref/$SHA/data/demo_items.csv"
OUT="$(exakit_dataset_files "$KIT" "$DS" demo_ref 2>&1; printf 'rc=%s' "$?")"
has "a cache changed since is not trusted: it is fetched again" "rc=1" "$OUT"
check "and the bad entry is gone" "no" "$([ -d "$CACHE/demo_ref/$SHA" ] && echo yes || echo no)"

printf '\n== offline, nothing cached: a clear, soft failure ==\n'
reset_cache
check "the listing names the download" "0.1 MB download" "$(exakit_dataset_download_note "$DS")"
exakit_dataset_files "$KIT" "$DS" demo_ref
check "it fails" "1" "$?"
check "the release URL was tried, with the kit's repository" \
    "https://github.com/$EXAKIT_KIT_REPO/releases/download/datasets-demo_ref-2026-01-02/$ARCHIVE" "$(cat "$WORK/fetch.calls")"
has "the reason names the URL" "could not be fetched from https://github.com/" "$EXAKIT_DATASET_FETCH_ERROR"
has "and the way out" "EXAKIT_DATASETS_MIRROR" "$EXAKIT_DATASET_FETCH_ERROR"
: > "$WORK/fetch.calls"
EXAKIT_DATASETS_REPO=someone/fork exakit_dataset_files "$KIT" "$DS" demo_ref
has "EXAKIT_DATASETS_REPO picks the release" "github.com/someone/fork/releases/download/" "$(cat "$WORK/fetch.calls")"
: > "$WORK/fetch.calls"
EXAKIT_DATASETS_REPO='x/y/../z' exakit_dataset_files "$KIT" "$DS" demo_ref
has "a repository that is not owner/name is refused" "must be owner/name" "$EXAKIT_DATASET_FETCH_ERROR"
check "before any download" "" "$(cat "$WORK/fetch.calls")"
EXAKIT_DATASETS_MIRROR="https://mirror.example/assets/" exakit_dataset_files "$KIT" "$DS" demo_ref
check "an https mirror is a base URL" "https://mirror.example/assets/$ARCHIVE" "$(cat "$WORK/fetch.calls")"
EXAKIT_DATASETS_MIRROR="ftp://mirror.example" exakit_dataset_files "$KIT" "$DS" demo_ref
has "any other scheme is refused" "must be a folder, a file:// URL or an https:// URL" "$EXAKIT_DATASET_FETCH_ERROR"

printf '\n== a tampered archive is refused and never cached ==\n'
reset_cache
BAD="$WORK/bad-mirror"
mkdir -p "$BAD"
cp "$MIRROR/$ARCHIVE" "$BAD/$ARCHIVE"
printf 'x' >> "$BAD/$ARCHIVE"
EXAKIT_DATASETS_MIRROR="$BAD" exakit_dataset_files "$KIT" "$DS" demo_ref
check "it fails" "1" "$?"
has "naming the digest" "does not match the manifest's $SHA" "$EXAKIT_DATASET_FETCH_ERROR"
check "nothing is cached" "" "$(ls "$CACHE/demo_ref" 2>/dev/null)"
check "the mirror's copy is left alone" "yes" "$([ -f "$BAD/$ARCHIVE" ] && echo yes || echo no)"

printf '\n== an archive with a path that escapes is refused ==\n'
# A copy of the dataset whose manifest trusts a crafted archive (right digest),
# so what is under test is the extraction, not the digest.
evil() { # evil <member-name> <type: file|link>
    rm -rf "$WORK/evil" && mkdir -p "$WORK/evil/kit/data/datasets" "$WORK/evil/kit/setup/lib" "$WORK/evil/mirror"
    cp -R "$DS" "$WORK/evil/kit/data/datasets/demo_ref"
    python3 - "$WORK/evil/kit/data/datasets/demo_ref/manifest.json" "$WORK/evil/mirror/$ARCHIVE" "$1" "$2" <<'PYEOF'
import hashlib, io, json, sys, tarfile
manifest, archive, name, kind = sys.argv[1:5]
with tarfile.open(archive, "w:gz") as tar:
    for member in ("data/demo_items.csv", "data/demo_notes.csv"):
        data = b"ITEM_ID,NAME\n1,a\n"
        info = tarfile.TarInfo(member); info.size = len(data); tar.addfile(info, io.BytesIO(data))
    info = tarfile.TarInfo(name)
    if kind == "link":
        info.type, info.linkname = tarfile.SYMTYPE, "/etc/passwd"
        tar.addfile(info)
    else:
        data = b"owned\n"; info.size = len(data); tar.addfile(info, io.BytesIO(data))
doc = json.load(open(manifest))
blob = open(archive, "rb").read()
doc["asset"]["sha256"], doc["asset"]["size"] = hashlib.sha256(blob).hexdigest(), len(blob)
json.dump(doc, open(manifest, "w"), indent=2)
PYEOF
    cp "$KIT/setup/lib/dataset_asset.py" "$WORK/evil/kit/setup/lib/"
    EXAKIT_DATASETS_MIRROR="$WORK/evil/mirror" exakit_dataset_files "$WORK/evil/kit" "$WORK/evil/kit/data/datasets/demo_ref" demo_ref
}
reset_cache
evil "../escaped.csv" file
check "a .. member: refused" "1" "$?"
has "saying which member" "'../escaped.csv', which is not a plain data/<name>.csv" "$EXAKIT_DATASET_FETCH_ERROR"
check "nothing was written beside the cache" "no" "$([ -e "$CACHE/escaped.csv" ] || [ -e "$CACHE/demo_ref/escaped.csv" ] && echo yes || echo no)"
evil "/tmp/exakit-absolute-$$.csv" file
check "an absolute member: refused" "1" "$?"
check "and not written" "no" "$([ -e "/tmp/exakit-absolute-$$.csv" ] && echo yes || echo no)"
evil "data/link.csv" link
check "a symlink member: refused" "1" "$?"
check "nothing is cached after any of them" "" "$(ls "$CACHE/demo_ref" 2>/dev/null)"

printf '\n== file:// mirrors work too ==\n'
reset_cache
EXAKIT_DATASETS_MIRROR="file://$MIRROR" exakit_dataset_files "$KIT" "$DS" demo_ref
check "fetched from file://, verified, cached" "0:$CACHE/demo_ref/$SHA/data" "$?:$EXAKIT_DATASET_DATA_DIR"

printf '\n== a dataset without an asset block loads as it always did ==\n'
: > "$WORK/python.calls"
exakit_dataset_files "$ROOT" "$ROOT/data/datasets/tpch" tpch
check "tpch reads its own data/" "0:$ROOT/data/datasets/tpch/data" "$?:$EXAKIT_DATASET_DATA_DIR"
check "without starting Python" "" "$(cat "$WORK/python.calls")"
exakit_dataset_files "$ROOT" "$ROOT/data/datasets/pharma_trials" pharma_trials
check "a checkout's pharma_trials CSVs match: no download" "0:$ROOT/data/datasets/pharma_trials/data" "$?:$EXAKIT_DATASET_DATA_DIR"

printf '\n== the listing names the download, the table keeps it ==\n'
reset_cache
exakit_repo_root() { printf '%s\n' "$KIT"; }
check "the label carries the size" "demo_ref|Demo reference (synthetic, ~3 rows) - 0.1 MB download" \
    "$(exakit_bundled_datasets | cut -d'|' -f1,2)"
exakit_pending_datasets() { exakit_bundled_datasets | cut -d'|' -f1,2; }
exakit_data_table_build "$WORK/table"
has "the table row drops the estimate, keeps the download" "|Demo reference - 0.1 MB download|" "$(cat "$WORK/table")"

printf '\n== the whole load: downloaded, verified, cached, uploaded from the cache ==\n'
cat > "$EXAKIT_BIN_DIR/exapump" <<STUBEOF
#!/bin/sh
case "\$1" in
    upload) printf '%s\n' "\$2" >> "$WORK/uploads"; exit 0 ;;
    sql) shift; shift; shift
         if [ -n "\${1:-}" ]; then case "\$1" in *EXAKIT_RC*) echo "EXAKIT_RC[3]" ;; esac; exit 0; fi
         cat > /dev/null; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$EXAKIT_BIN_DIR/exapump"
exapump_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exapump"; }
EXAKIT_EXAPUMP_PROFILE="starter-kit"
manifest_get() { [ "$1" = "components.exapump.profile" ] && printf 'starter-kit\n'; return 0; }
manifest_set() { return 0; }
exakit_dataset_loaded() { return 1; }
exakit_schema_present() { return 0; }
: > "$WORK/uploads"
OUT="$(EXAKIT_DATASETS_MIRROR="$MIRROR" exakit_load_dataset_dir "$KIT" demo_ref 2>&1)"
check "the load succeeds" "0" "$?"
has "it says it downloads" "Downloading the 'demo_ref' data" "$OUT"
has "and that it loaded" "Dataset 'demo_ref' loaded and verified" "$OUT"
check "both CSVs went up from the cache" \
    "$CACHE/demo_ref/$SHA/data/demo_items.csv $CACHE/demo_ref/$SHA/data/demo_notes.csv" \
    "$(sort "$WORK/uploads" | tr '\n' ' ' | sed 's/ $//')"
: > "$WORK/uploads"
OUT="$(exakit_load_dataset_dir "$KIT" demo_ref 2>&1)"
check "a reload needs no mirror: the cache answers" "0" "$?"
lacks "and downloads nothing" "Downloading" "$OUT"
reset_cache
: > "$WORK/uploads"
OUT="$( (exakit_load_dataset_dir "$KIT" demo_ref) 2>&1)"
check "offline with nothing cached: the load fails" "1" "$?"
has "with the reason, once" "could not be fetched from" "$OUT"
check "and nothing was uploaded" "" "$(cat "$WORK/uploads")"

printf '\n== the PowerShell twin moves with it ==\n'
EXAPUMP_PS1="$(cat "$ROOT/setup/lib/exapump.ps1")"
has "exapump.ps1 resolves the files"       "function Get-ExakitDatasetFiles"        "$EXAPUMP_PS1"
has "...through the same service"          "dataset_asset.py"                        "$EXAPUMP_PS1"
has "...and names the download size"       "function Get-ExakitDatasetDownloadNote" "$EXAPUMP_PS1"
has "the load reads the resolved folder"   'Join-Path $dataDir "*.csv"'             "$EXAPUMP_PS1"

printf '\ndataset-asset: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
