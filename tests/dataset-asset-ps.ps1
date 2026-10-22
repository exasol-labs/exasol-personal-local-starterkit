#!/usr/bin/env pwsh
# dataset-asset-ps.ps1 - the Windows twin of tests/dataset-asset.sh: a reference
# dataset's CSVs come from the kit copy when its digests match the manifest,
# else the verified cache, else the release asset - downloaded, checked against
# its SHA-256, extracted safely, every CSV checked again, then cached and loaded.
# Offline: the "release" is a mirror folder, the network fetch and exapump are
# stubbed, the kit home is a temporary folder. Runs under Windows PowerShell 5.1
# and pwsh.
#
#   pwsh -NoProfile -File tests/dataset-asset-ps.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-asset-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
foreach ($v in "EXAKIT_DATASETS_MIRROR", "EXAKIT_DATASETS_REPO") { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")
$script:LogFile = Join-Path $work "test.log"
Set-Content -Path $script:LogFile -Value ""
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains("" + $needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected '$needle' in <$haystack>" }
}
function Fail([string]$Msg) { throw "$Msg" }
function Info([string]$Msg) { $script:Said += @($Msg) }
# The network: never touched. Every download records its URL and fails.
$script:Fetched = @()
function Get-ExakitFile {
    param([string]$Url, [string]$Dest, [switch]$Soft)
    $script:Fetched += @($Url)
    return $false
}
function Start-Sleep { param([int]$Seconds) }
function Try-Files([string]$Kit, [string]$Dir) {
    $script:Said = @()
    try { return "ok|" + (Get-ExakitDatasetFiles -KitRoot $Kit -Dir $Dir -Id "demo_ref") }
    catch { return "failed|$($_.Exception.Message)" }
}

$py = Get-ExakitDatasetPython
if (-not $py) { Write-Host "dataset-asset-ps: skipped (no Python 3.8+ on PATH)"; exit 0 }
$cache = Join-Path $script:CacheDir "datasets"
function Reset-Cache {
    Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue
    $script:Fetched = @()
}

try {
    # --- a small reference dataset in a kit of its own ------------------------
    $kit = Join-Path $work "kit"
    $ds = Join-Path (Join-Path (Join-Path $kit "data") "datasets") "demo_ref"
    $lib = Join-Path (Join-Path $kit "setup") "lib"
    New-Item -ItemType Directory -Force -Path (Join-Path $ds "data"), $lib | Out-Null
    Copy-Item (Join-Path (Join-Path (Join-Path $repo "setup") "lib") "dataset_asset.py") $lib
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $ds "dataset.conf"), "id=demo_ref`nlabel=Demo reference (synthetic, ~3 rows)`nschema=DEMO_REF`nmarkers=DEMO_ITEMS`norder=60`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $ds "01_create_schema.sql"), "CREATE SCHEMA IF NOT EXISTS DEMO_REF;`n", $utf8)
    $good = "ITEM_ID,NAME`n1,a`n2,b`n3,c`n"
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $ds "data") "demo_items.csv"), $good, $utf8)
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $ds "data") "demo_notes.csv"), "NOTE_ID,TEXT`n1,x`n", $utf8)
    $dist = Join-Path $work "dist"
    $maker = Join-Path $work "make.py"
    [System.IO.File]::WriteAllText($maker, @'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "tools" / "datasets"))
import package
folder = Path(sys.argv[2])
files = {name: {"rows": 1, "sha256": digest} for name, digest in package.file_digests(folder).items()}
(folder / "manifest.json").write_text(json.dumps({"id": "demo_ref", "source": {"name": "x", "url": "https://x"},
    "terms": {"url": "https://x", "summary": "x", "confirmed": True}, "snapshot": "2026-01-02", "files": files}, indent=2))
package.package(folder, Path(sys.argv[3]))
'@, $utf8)
    & $py $maker $repo $ds $dist
    $archive = "demo_ref-2026-01-02.tar.gz"
    $mirror = Join-Path $work "mirror"
    New-Item -ItemType Directory -Force -Path $mirror | Out-Null
    Copy-Item (Join-Path $dist $archive) $mirror
    $sha = (Get-ExakitDatasetAsset -Dir $ds).sha256
    $entry = Join-Path (Join-Path $cache "demo_ref") $sha
    Check "the manifest names the archive" $archive (Get-ExakitDatasetAsset -Dir $ds).file

    Write-Host "the kit copy, when its digests match:"
    Reset-Cache
    Check "the kit copy is used" "ok|$(Join-Path $ds 'data')" (Try-Files $kit $ds)
    Check "nothing was downloaded" "" ($script:Fetched -join ",")
    Check "no download is announced in the listing" "" (Get-ExakitDatasetDownloadNote -Dir $ds)

    Write-Host "a kit copy that does not match is ignored:"
    Reset-Cache
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $ds "data") "demo_items.csv"), "ITEM_ID,NAME`n1,TAMPERED`n", $utf8)
    $env:EXAKIT_DATASETS_MIRROR = $mirror
    Check "the archive is used instead" "ok|$(Join-Path $entry 'data')" (Try-Files $kit $ds)
    Has "the download is said, with its size" "Downloading the 'demo_ref' data (0.1 MB" ($script:Said -join " ")
    Check "the cached CSV is the manifest's" $good ([System.IO.File]::ReadAllText((Join-Path (Join-Path $entry "data") "demo_items.csv")))
    Check "the cache is marked verified" $sha ([System.IO.File]::ReadAllText((Join-Path $entry ".verified")).Trim())
    Check "no partial download is left" "0" (@(Get-ChildItem (Join-Path $cache "demo_ref") -Filter "*.part").Count)
    Remove-Item Env:EXAKIT_DATASETS_MIRROR

    Write-Host "the cache is reused: no mirror, no network:"
    Remove-Item -Recurse -Force (Join-Path $ds "data")
    $script:Fetched = @()
    Check "the verified extraction is used" "ok|$(Join-Path $entry 'data')" (Try-Files $kit $ds)
    Check "nothing was downloaded" "" ($script:Fetched -join ",")
    Check "no download is announced while it is cached" "" (Get-ExakitDatasetDownloadNote -Dir $ds)

    Write-Host "offline, nothing cached: a clear, soft failure:"
    Reset-Cache
    Check "the listing names the download" "0.1 MB download" (Get-ExakitDatasetDownloadNote -Dir $ds)
    $r = Try-Files $kit $ds
    Has "it fails" "failed|" $r
    Has "naming the URL" "could not be fetched from https://github.com/$($script:KitRepo)/releases/download/datasets-demo_ref-2026-01-02/$archive" $r
    Has "and the way out" "EXAKIT_DATASETS_MIRROR" $r
    Check "the download was retried, three tries" "3" $script:Fetched.Count
    $script:Fetched = @()
    $env:EXAKIT_DATASETS_REPO = "someone/fork"
    [void](Try-Files $kit $ds)
    Has "EXAKIT_DATASETS_REPO picks the release" "github.com/someone/fork/releases/download/" ($script:Fetched -join ",")
    $env:EXAKIT_DATASETS_REPO = "x/y/../z"
    $script:Fetched = @()
    Has "a repository that is not owner/name is refused" "must be owner/name" (Try-Files $kit $ds)
    Check "before any download" "" ($script:Fetched -join ",")
    Remove-Item Env:EXAKIT_DATASETS_REPO
    $env:EXAKIT_DATASETS_MIRROR = "https://mirror.example/assets/"
    [void](Try-Files $kit $ds)
    Check "an https mirror is a base URL" "https://mirror.example/assets/$archive" $script:Fetched[0]
    $env:EXAKIT_DATASETS_MIRROR = "ftp://mirror.example"
    Has "any other scheme is refused" "must be a folder, a file:// URL or an https:// URL" (Try-Files $kit $ds)

    Write-Host "a tampered archive is refused and never cached:"
    Reset-Cache
    $bad = Join-Path $work "bad-mirror"
    New-Item -ItemType Directory -Force -Path $bad | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $mirror $archive))
    [System.IO.File]::WriteAllBytes((Join-Path $bad $archive), $bytes + [byte[]](120))
    $env:EXAKIT_DATASETS_MIRROR = $bad
    $r = Try-Files $kit $ds
    Has "it fails, naming the digest" "does not match the manifest's $sha" $r
    Check "nothing is cached" "0" (@(Get-ChildItem (Join-Path $cache "demo_ref") -ErrorAction SilentlyContinue).Count)
    Check "the mirror's copy is left alone" "True" (Test-Path (Join-Path $bad $archive))

    Write-Host "an archive with a path that escapes is refused:"
    $evilKit = Join-Path $work "evil"
    $evilDs = Join-Path (Join-Path (Join-Path $evilKit "data") "datasets") "demo_ref"
    New-Item -ItemType Directory -Force -Path $evilDs, (Join-Path (Join-Path $evilKit "setup") "lib"), (Join-Path $evilKit "mirror") | Out-Null
    Copy-Item (Join-Path $lib "dataset_asset.py") (Join-Path (Join-Path $evilKit "setup") "lib")
    Copy-Item (Join-Path $ds "*") $evilDs -Recurse
    $crafter = Join-Path $work "evil.py"
    [System.IO.File]::WriteAllText($crafter, @'
import hashlib, io, json, sys, tarfile
manifest, archive, name = sys.argv[1:4]
with tarfile.open(archive, "w:gz") as tar:
    for member in ("data/demo_items.csv", name):
        data = b"ITEM_ID,NAME\n1,a\n"
        info = tarfile.TarInfo(member); info.size = len(data); tar.addfile(info, io.BytesIO(data))
doc = json.load(open(manifest))
blob = open(archive, "rb").read()
doc["asset"]["sha256"], doc["asset"]["size"] = hashlib.sha256(blob).hexdigest(), len(blob)
json.dump(doc, open(manifest, "w"), indent=2)
'@, $utf8)
    & $py $crafter (Join-Path $evilDs "manifest.json") (Join-Path (Join-Path $evilKit "mirror") $archive) "../escaped.csv"
    Reset-Cache
    $env:EXAKIT_DATASETS_MIRROR = Join-Path $evilKit "mirror"
    Has "a .. member is refused, by name" "'../escaped.csv', which is not a plain data/<name>.csv" (Try-Files $evilKit $evilDs)
    Check "nothing was written beside the cache" "False" (Test-Path (Join-Path $cache "escaped.csv"))
    Check "nothing is cached" "0" (@(Get-ChildItem (Join-Path $cache "demo_ref") -ErrorAction SilentlyContinue).Count)

    Write-Host "file:// mirrors work too:"
    Reset-Cache
    $env:EXAKIT_DATASETS_MIRROR = "file://" + ($mirror -replace '\\', '/')
    Check "fetched from file://, verified, cached" "ok|$(Join-Path $entry 'data')" (Try-Files $kit $ds)
    Remove-Item Env:EXAKIT_DATASETS_MIRROR

    Write-Host "a dataset without an asset block loads as it always did:"
    $tpch = Join-Path (Join-Path (Join-Path $repo "data") "datasets") "tpch"
    Check "tpch reads its own data folder" (Join-Path $tpch "data") (Get-ExakitDatasetFiles -KitRoot $repo -Dir $tpch -Id "tpch")

    Write-Host "the listing names the download, the table keeps it:"
    Reset-Cache
    function Get-ExakitRepoRoot { return $kit }
    $listed = @(Get-ExakitBundledDatasets)
    Check "the label carries the size" "Demo reference (synthetic, ~3 rows) - 0.1 MB download" $listed[0].Label
    Check "the table drops the estimate, keeps the download" "Demo reference - 0.1 MB download" `
        ([regex]::Replace($listed[0].Label, ' *\([^()]*\)( - [0-9.]+ MB download)?$', '$1'))

    Write-Host "the whole load: downloaded, verified, cached, uploaded from the cache:"
    function Get-ExakitManifestValue([string]$Key) { if ($Key -eq "components.exapump.profile") { return "starter-kit" }; return $null }
    function Set-ExakitManifestValue { }
    function Test-ExakitDatasetLoaded { return $false }
    function Invoke-ExapumpSqlFile { return $true }
    function Test-ExapumpSchemaPresent { return $true }
    function Get-ExapumpRowCountMany { param($Schema, $Tables) $h = @{}; foreach ($t in $Tables) { $h[$t] = "3" }; return $h }
    function Clear-ExakitTableListing { }
    function Ok([string]$Msg) { $script:Said += @($Msg) }
    $script:Uploaded = @()
    function Invoke-ExapumpUploadMany {
        param($Files, $Id)
        foreach ($f in $Files) { $script:Uploaded += @($f.Path) }
        $script:ExakitUploadFailures = @()
        return $true
    }
    $env:EXAKIT_DATASETS_MIRROR = $mirror
    $script:Said = @()
    Invoke-ExakitDatasetDirLoad -KitRoot $kit -Id "demo_ref"
    Has "it said it downloads" "Downloading the 'demo_ref' data" ($script:Said -join " ")
    Has "and that it loaded" "Dataset 'demo_ref' loaded and verified" ($script:Said -join " ")
    Check "both CSVs went up from the cache" "$(Join-Path (Join-Path $entry 'data') 'demo_items.csv'),$(Join-Path (Join-Path $entry 'data') 'demo_notes.csv')" `
        ((@($script:Uploaded) | Sort-Object) -join ",")
    Remove-Item Env:EXAKIT_DATASETS_MIRROR
    Reset-Cache
    $script:Uploaded = @()
    $failed = ""
    try { Invoke-ExakitDatasetDirLoad -KitRoot $kit -Id "demo_ref" } catch { $failed = $_.Exception.Message }
    Has "offline with nothing cached: the load fails, with the reason" "could not be fetched from" $failed
    Check "and nothing was uploaded" "0" @($script:Uploaded).Count
} finally {
    Remove-Item Env:EXAKIT_DATASETS_MIRROR -ErrorAction SilentlyContinue
    Remove-Item Env:EXAKIT_DATASETS_REPO -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "dataset-asset-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
