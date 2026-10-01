#!/usr/bin/env pwsh
# data-load-shapes-ps.ps1 - behavioural tests for the Windows twin of the local
# data loader on the files people actually have: Windows line endings, a
# byte-order mark, ';'-separated German exports, a GTFS feed of .txt files, a
# header with no rows, a .geojson. Twin of the "real-world CSV shapes" section
# of tests/bulk-folder-load.sh.
#
# THE KIT IS A BRIDGE. It hands files to exapump and says what exapump says
# back; it does not rewrite them. That is measured at the binary's argv and at
# the bytes it receives: the ORIGINAL path, the ORIGINAL bytes (CR and BOM
# included), exapump's own --delimiter when the header calls for it, no upload
# at all for a file with nothing in it or a name exapump refuses by extension,
# and a failure reason that names the cause the inspector saw.
#
#   pwsh -NoProfile -File tests/data-load-shapes-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/data-load-shapes-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains("" + $needle)) { $script:PASS++; Write-Host "  ok   $label = present" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected '$needle' in:`n$haystack" }
}
function Lacks($label, $needle, $haystack) {
    if (-not ("" + $haystack).Contains("" + $needle)) { $script:PASS++; Write-Host "  ok   $label = absent" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): did not expect '$needle' in:`n$haystack" }
}

# --- sandbox ----------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-shapes-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path (Join-Path $work "home") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $work "got") | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_LOG_FILE = Join-Path $work "test.log"
$got = Join-Path $work "got"
$env:SHAPES_GOT = $got

# A stub exapump that records argv and keeps a copy of the file it was handed,
# so the suite can prove it received the user's bytes and not a copy.
# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1.
$onWindows = ($env:OS -like "*Windows*")
if ($onWindows) {
    $stub = Join-Path $work "exapump.cmd"
    Set-Content -Path $stub -Encoding Ascii -Value @(
        "@echo off",
        "echo %*>> `"%SHAPES_GOT%\argv`"",
        "if `"%~1`"==`"upload`" copy /y `"%~2`" `"%SHAPES_GOT%\received`" >nul",
        "exit /b 0"
    )
} else {
    $stub = Join-Path $work "exapump"
    Set-Content -Path $stub -Value @(
        "#!/bin/sh",
        "printf '%s\n' `"`$*`" >> `"`$SHAPES_GOT/argv`"",
        "[ `"`$1`" = upload ] && cp `"`$2`" `"`$SHAPES_GOT/received`"",
        "exit 0"
    )
    & chmod +x $stub
}
$env:EXAKIT_EXAPUMP_BIN = $stub

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")
$script:ExakitUploadQuiet = $true

# --- fixtures: the shapes, byte for byte ------------------------------------
$shapes = Join-Path $work "shapes"; New-Item -ItemType Directory -Force -Path $shapes | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Put([string]$Name, [byte[]]$Bytes) { [System.IO.File]::WriteAllBytes((Join-Path $shapes $Name), $Bytes) }
Put "windows.csv" ([byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes("datum,gesamt`r`n2026.01.01,7`r`n"))   # BOM + CRLF
Put "german.csv"  ($utf8.GetBytes("Row;LAT;NAME`n1;48,17;Zentrale`n"))                               # ';' with decimal commas
Put "tabs.tsv"    ($utf8.GetBytes("a`tb`n1`t2`n"))                                                    # .tsv - exapump refuses the name
Put "stops.txt"   ($utf8.GetBytes("stop_id,stop_name`n1,Ostbahnhof`n"))                               # GTFS - same
Put "shapes.csv"  ($utf8.GetBytes("shape_id,shape_pt_lat`n"))                                         # a header with nothing under it
Put "plain.csv"   ($utf8.GetBytes("a,b`n1,2`n"))
Put "README.txt"  ($utf8.GetBytes("just some notes`nabout the exports`n"))
Put "areas.geojson" ($utf8.GetBytes('{"type":"FeatureCollection","features":[]}' + "`n"))

Write-Host ""
Write-Host "== the inspector looks, and does not touch =="
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "plain.csv")
Check "a plain file: comma, no flags" ",|" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "windows.csv")
Check "a BOM+CRLF file is seen for what it is" ",|bom,crlf" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
Check "...and is not header-only" $false $look.HeaderOnly
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "german.csv")
Check "a ';' header selects the semicolon" ";" $look.Delimiter
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "tabs.tsv")
Check "a tab header selects the tab" "`t" $look.Delimiter
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "shapes.csv")
Check "a header with no rows is named as such" $true $look.HeaderOnly
$before = [System.IO.File]::ReadAllBytes((Join-Path $shapes "windows.csv"))
Check "...and the file is byte-for-byte what it was" 3 ($before.Length - $utf8.GetBytes("datum,gesamt`r`n2026.01.01,7`r`n").Length)

Write-Host ""
Write-Host "== through the real uploader, into the stub binary =="
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$said = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "windows.csv") -Target "T.WINDOWS" } 6>&1
$rc = @($said | Where-Object { $_ -is [bool] })[0]
Check "the upload is reported as it went" $true $rc
Has "a CRLF file that loads is told what its last column now holds" "every value in the last column of T.WINDOWS ends in a carriage return" ($said -join "`n")
$argv = Get-Content (Join-Path $got "argv") -Raw
Has "exapump is handed the ORIGINAL path" ("upload " + (Join-Path $shapes "windows.csv")) $argv
Lacks "...with no delimiter flag for a comma file" "--delimiter" $argv
$received = [System.IO.File]::ReadAllBytes((Join-Path $got "received"))
Check "...and the original bytes, CR and BOM included - no copy" ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String($received))
$saidPlain = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "plain.csv") -Target "T.PLAIN" } 6>&1
Lacks "...and a clean file is not" "carriage return" ($saidPlain -join "`n")
$rc = Invoke-ExapumpUpload -Path (Join-Path $shapes "german.csv") -Target "T.GERMAN" 6>$null
$argv = Get-Content (Join-Path $got "argv") -Raw
Has "a ';' file is uploaded with exapump's own --delimiter ;" "--delimiter ;" $argv
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$said = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "shapes.csv") -Target "T.SHAPES" -Soft } 6>&1
$rc = @($said | Where-Object { $_ -is [bool] })[0]
Has "a header-only file is named, not sent to the engine" "has a header and no rows" ($said -join "`n")
Check "...as a failure" $false $rc
Lacks "...that never reached exapump" "shapes.csv" (Get-Content (Join-Path $got "argv") -Raw)
Check "no temporary copy of anything exists" 0 @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter "exakit-csv*" -ErrorAction SilentlyContinue).Count

Write-Host ""
Write-Host "== the folder scan sees the same things, and says them =="
$plan = @(Get-ExakitBulkFolderPlan -Path $shapes)
$planText = $plan -join "`n"
Has "a tabular .txt is recognised as data" ("skip|extension||" + (Join-Path $shapes "stops.txt")) $planText
Has "...and so is a .tsv" ("skip|extension||" + (Join-Path $shapes "tabs.tsv")) $planText
Has "a README.txt is not" ("skip|unsupported||" + (Join-Path $shapes "README.txt")) $planText
Has "a header-only file is skipped by name" ("skip|header-only||" + (Join-Path $shapes "shapes.csv")) $planText
Lacks "nothing exapump refuses by name is queued for it" "load|csv|STOPS|" $planText
# A folder's JSON files load through JSON Tables where the engine exists
# (Windows x86_64) and are listed as skipped where it does not. Either way what
# matters is that .geojson is planned as JSON, not among "other kinds".
if (Test-ExakitJsonTablesApplicable) {
    Has ".geojson is JSON in a folder scan (queued for JSON Tables)" ("load|json|AREAS|" + (Join-Path $shapes "areas.geojson")) $planText
} else {
    Has ".geojson is JSON in a folder scan (no engine here)" ("skip|json-unsupported||" + (Join-Path $shapes "areas.geojson")) $planText
}
Lacks "...and not a file of another kind" ("skip|unsupported||" + (Join-Path $shapes "areas.geojson")) $planText
Check ".geojson is JSON" "json" (Get-ExakitDataFileKind (Join-Path $shapes "areas.geojson"))
$chosen = @($plan | Where-Object { $_.StartsWith("load|") } | ForEach-Object { $_.Substring(5) })
$shown = (& { Show-ExakitBulkPlan -Plan $plan -Chosen $chosen -Schema "S" -Path $shapes } 6>&1) -join "`n"
Has "the plan tells the user the one thing that loads them" "rename to .csv to load" $shown
Has "...and counts the header-only file in words" "with a header and no rows" $shown

Write-Host ""
Write-Host "== the engine's reason survives to the screen, whole, with the cause the kit saw =="
$cr = @("Error: SQL execution failed: Protocol error: ETL-3051: [Column=11 Row=0] [Transformation of value='7.4<CR>' failed - invalid character value for cast; Value: '7.4'] (Session: 1876)")
Has "a <CR> in the engine's message is translated" "Windows line endings (CRLF)" (Get-ExakitUploadFailureReason -Output $cr)
$etl = @("Error: SQL execution failed: Protocol error: ETL-3050: [Column=6 Row=0] [Transformation of value='x' failed - invalid character value for cast; Value: 'x'] (Session: 1876)")
$script:ExakitCsvFlags = ""
$reason = Get-ExakitUploadFailureReason -Output $etl
Has "an ETL detail in brackets is kept, not cut at the bracket" "ETL-3050: [Column=6 Row=0] [Transformation of value='x' failed" $reason
Lacks "...and the session id is dropped" "Session" $reason
Lacks "...and a clean file gets no invented cause" "Windows line endings" $reason
$script:ExakitCsvFlags = "bom,crlf"
Has "...but a file the inspector flagged as CRLF gets the cause appended" "Windows line endings (CRLF)" (Get-ExakitUploadFailureReason -Output $etl)
$script:ExakitCsvFlags = ""
$json = @("Error: SQL execution failed: Protocol error: ETL-3050: [Column=2 Row=0] [Transformation of value='{`"sku`":`"A-1`",`"tags`":[`"x`"]}' failed - invalid character value for cast] (Session: 9)")
$jr = Get-ExakitUploadFailureReason -Output $json
Lacks "a JSON value the engine quotes stays in the log" '"sku"' $jr
Has "...named, with what failed kept around it" "value='<JSON value>' failed - invalid character value for cast" $jr
$open = @('Error: Failed to parse row: {"sku":"A-1","name":"a very long product name that runs on')
$jr = Get-ExakitUploadFailureReason -Output $open
Has "...and an unclosed one, cut by the engine, is dropped to the end" "Failed to parse row: <JSON value>" $jr
Lacks "...leaving nothing of it" "sku" $jr
$long = @("Error: SQL execution failed: Protocol error: ETL-2105: Error while parsing row=0 (starting from 0) [CSV Parser found at byte 5385 (starting with 0 at the beginning of the row) of 5385 a single field delimiter or a row terminator directly after a quoted field] (Session: 1)")
$cut = Get-ExakitUploadFailureReason -Output $long
Has "a long detail is cut at a word, with an ellipsis" "field..." $cut
Lacks "...never mid-word" "delimi" $cut

Write-Host ""
Write-Host "== a folder holding only what exapump refuses by name: a GTFS feed, as shipped =="
$gtfs = Join-Path $work "gtfs"; New-Item -ItemType Directory -Force -Path $gtfs | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $gtfs "stops.txt"), $utf8.GetBytes("stop_id,stop_name`n1,Ostbahnhof`n"))
[System.IO.File]::WriteAllBytes((Join-Path $gtfs "routes.txt"), $utf8.GetBytes("route_id,route_short_name`n1,U1`n"))
$gt = & { Import-ExakitLocalFolder -Path $gtfs } 6>&1
$gtText = ($gt | ForEach-Object { "$_" }) -join "`n"
Has "a folder of .txt tables is not 'no files'" "2 files in" $gtText
Has "...it names the rename that loads them" "Rename them to .csv" $gtText
Lacks "...and does not call it empty" "No CSV, Parquet or JSON files" $gtText
Has "...and fails, as before" "failed" $gtText

Write-Host ""
Write-Host "== a quoted identifier survives the PowerShell 5.1 command-line rules =="
# PowerShell 5.1 builds ONE command line for a native program and does not
# escape a double quote inside an argument, so the receiver reads it as a
# delimiter and drops it: `--table "s1"."t2"` arrived as `--table s1.t2`, and
# Exasol upper-cases what is not quoted. Windows CI found it in the legacy
# crossing, where every restored table was rebuilt under a different name than
# the one it had been exported from.
#
# Legacy is those exact rules, and PowerShell 7 can be asked for them - so this
# runs the real failure on every host, not only on the Windows runner. On 5.1
# the assignment is an ordinary variable the engine ignores, and the rules are
# already in force.
$savedPassing = Get-Variable -Name "PSNativeCommandArgumentPassing" -ValueOnly -ErrorAction SilentlyContinue
$PSNativeCommandArgumentPassing = "Legacy"
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
[void](& { Invoke-ExapumpUpload -Path (Join-Path $shapes "plain.csv") -Target '"s1"."t2"' } 6>&1)
# WHAT THE STUB CAN SEE. On Windows the stub is a .cmd and records with
# `echo %*`, which prints cmd's RAW command line - before the un-escaping that
# CommandLineToArgvW performs for a real program (exapump is a Rust binary and
# gets that for free). So the escape the kit correctly applied, \", is still
# spelled out in the recording. Undo it here and the assertion reads what
# exapump would receive, on either host. A quote that was DROPPED, which is the
# bug this pins, cannot come back through this normalisation.
$argvSeen = (Get-Content (Join-Path $got "argv") -Raw) -replace '\\"', '"'
Has "the quoted target reaches exapump with its quotes" '--table "s1"."t2"' $argvSeen
Check "the helper escapes a quote under those rules" 'CREATE TABLE \"s1\".\"t2\"' `
    @(ConvertTo-ExakitNativeArgs @('CREATE TABLE "s1"."t2"'))[0]
Check "...and leaves an argument with no quote alone" "upload" @(ConvertTo-ExakitNativeArgs @("upload"))[0]
if ($PSVersionTable.PSVersion.Major -ge 7) {
    # PowerShell 7 hands over an argument vector, so the escape must NOT be
    # applied there - it would arrive as a literal backslash.
    $PSNativeCommandArgumentPassing = "Standard"
    Check "...and changes nothing where the vector is passed straight through" 'CREATE TABLE "s1"."t2"' `
        @(ConvertTo-ExakitNativeArgs @('CREATE TABLE "s1"."t2"'))[0]
}
if ($savedPassing) { $PSNativeCommandArgumentPassing = $savedPassing }

Write-Host ""
Write-Host "== an import connection cut mid-transfer is tried again, quietly =="
# The database reads each file through its own import proxy; when the client
# side closes before the last byte it says ETL-5105 "transfer closed with
# outstanding read data remaining". On Windows with exapump 0.12 that hit one
# or two of eight files per run, a different file each time, and the same file
# loaded fine a moment later. This stub fails a file's first N attempts with
# that message (N from a knob file), then succeeds. Twin of the sh suite's
# section in dataset-load-progress.sh.
$retry = Join-Path $work "retry"
$knobs = Join-Path $retry "knobs"
New-Item -ItemType Directory -Force -Path (Join-Path $retry "data"), $knobs | Out-Null
foreach ($n in @("alpha", "beta", "gamma")) { Set-Content -Path (Join-Path $retry "data\$n.csv") -Value "id`n1`n2" }
$env:EXAKIT_RETRY_KNOBS = $knobs
$cutMsg = "Error: SQL execution failed: Protocol error: ETL-5105: Following error occured while reading data from external connection [http://172.25.78.139:41705/001.csv failed after 393216 bytes. [transfer closed with outstanding read data remaining],[18],[Transferred a partial file]]"
if ($onWindows) {
    $retryStub = Join-Path $work "exapump-retry.cmd"
    Set-Content -Path $retryStub -Encoding Ascii -Value @(
        "@echo off",
        "if `"%~1`"==`"sql`" goto :sql",
        "if not `"%~1`"==`"upload`" exit /b 0",
        "for %%F in (`"%~2`") do set NAME=%%~nF",
        ">`"%EXAKIT_RETRY_KNOBS%\%NAME%.table`" echo %~4",
        "set CF=%EXAKIT_RETRY_KNOBS%\%NAME%.count",
        "set N=0",
        "if exist `"%CF%`" set /p N=<`"%CF%`"",
        "set /a N+=1",
        ">`"%CF%`" echo %N%",
        "set FAIL=0",
        "if exist `"%EXAKIT_RETRY_KNOBS%\%NAME%.fail`" set /p FAIL=<`"%EXAKIT_RETRY_KNOBS%\%NAME%.fail`"",
        "if %N% LEQ %FAIL% goto :fail",
        "echo Imported 2 rows",
        "exit /b 0",
        ":fail",
        "if `"%EXAKIT_RETRY_KIND%`"==`"silent`" exit /b 1",
        "if `"%EXAKIT_RETRY_KIND%`"==`"parse`" echo Error: SQL execution failed: Protocol error: ETL-2109: Error while parsing row=2",
        "if not `"%EXAKIT_RETRY_KIND%`"==`"parse`" echo $cutMsg",
        "exit /b 1",
        ":sql",
        ">>`"%EXAKIT_RETRY_KNOBS%\sql.log`" echo %~4",
        "exit /b 0"
    )
} else {
    $retryStub = Join-Path $work "exapump-retry"
    Set-Content -Path $retryStub -Value @(
        "#!/bin/sh",
        "if [ `"`$1`" = sql ]; then printf '%s\n' `"`$4`" >> `"`$EXAKIT_RETRY_KNOBS/sql.log`"; exit 0; fi",
        "[ `"`$1`" = upload ] || exit 0",
        "name=`"`$(basename `"`$2`" .csv)`"",
        "printf '%s' `"`$4`" > `"`$EXAKIT_RETRY_KNOBS/`$name.table`"",
        "cf=`"`$EXAKIT_RETRY_KNOBS/`$name.count`"; n=0; [ -f `"`$cf`" ] && n=`"`$(cat `"`$cf`")`"",
        "n=`$((n + 1)); printf '%s' `"`$n`" > `"`$cf`"",
        "fail=0; [ -f `"`$EXAKIT_RETRY_KNOBS/`$name.fail`" ] && fail=`"`$(cat `"`$EXAKIT_RETRY_KNOBS/`$name.fail`")`"",
        "if [ `"`$n`" -le `"`$fail`" ]; then",
        "  [ `"`${EXAKIT_RETRY_KIND:-cut}`" = silent ] && exit 1",
        "  if [ `"`${EXAKIT_RETRY_KIND:-cut}`" = parse ]; then echo 'Error: SQL execution failed: Protocol error: ETL-2109: Error while parsing row=2'; else echo '$cutMsg'; fi",
        "  exit 1",
        "fi",
        "echo 'Imported 2 rows'",
        "exit 0"
    )
    & chmod +x $retryStub
}
$env:EXAKIT_EXAPUMP_BIN = $retryStub
$script:ExapumpProfile = "starter-kit"
$script:LogFile = Join-Path $retry "install.log"
function Reset-Retry { Remove-Item -Recurse -Force $knobs -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $knobs | Out-Null; Set-Content -Path $script:LogFile -Value "" }
function Get-RetryAttempts($n) { $f = Join-Path $knobs "$n.count"; if (Test-Path $f) { return ((Get-Content $f -Raw).Trim()) }; return "0" }
function New-RetryFile($n) { return @{ Path = (Join-Path $retry "data\$n.csv"); Target = "TPCH.$($n.ToUpper())"; Name = "$n.csv" } }

Check "a cut transfer is recognised"     $true  (Test-ExakitUploadCutShort -Output "ETL-5105: ... [transfer closed with outstanding read data remaining]")
Check "so is a reset connection"         $true  (Test-ExakitUploadCutShort -Output "read: Connection reset by peer")
Check "a malformed row is not"           $false (Test-ExakitUploadCutShort -Output "ETL-2109: Error while parsing row=2")
Check "a refused login is not"           $false (Test-ExakitUploadCutShort -Output "authentication failed")
Check "the default is two more attempts" 2 (Get-ExakitUploadRetries)
$env:EXAKIT_UPLOAD_RETRIES = "0"
Check "EXAKIT_UPLOAD_RETRIES=0 disables" 0 (Get-ExakitUploadRetries)
Remove-Item Env:EXAKIT_UPLOAD_RETRIES -ErrorAction SilentlyContinue

Reset-Retry; Set-Content -Path (Join-Path $knobs "beta.fail") -Value "1"
$screen = (& { Invoke-ExapumpUploadMany -Files @((New-RetryFile "alpha"), (New-RetryFile "beta"), (New-RetryFile "gamma")) -Id "t" } 6>&1) -join "`n"
Check "one file cut once -> no failure recorded"  0   $script:ExakitUploadFailures.Count
Check "...that file was tried twice"              "2" (Get-RetryAttempts "beta")
Check "...the others once"                        "1" (Get-RetryAttempts "alpha")
Check "...and the retry was counted"              1   $script:ExakitUploadRetried
Has   "...the log says why it was retried" "beta.csv: the import connection was cut mid-transfer - attempt 2 of 3" (Get-Content $script:LogFile -Raw)
Lacks "...and the screen heard nothing about it"  "exapump output" $screen

Reset-Retry; Set-Content -Path (Join-Path $knobs "beta.fail") -Value "9"
$screen = (& { Invoke-ExapumpUploadMany -Files @((New-RetryFile "alpha"), (New-RetryFile "beta")) -Id "t" } 6>&1) -join "`n"
Check "cut every time -> three attempts, then failure" "3" (Get-RetryAttempts "beta")
Check "...recorded as a failure"                       1   $script:ExakitUploadFailures.Count
Has   "...naming the file"                             "beta.csv -> TPCH.BETA" ($script:ExakitUploadFailures -join "; ")

Reset-Retry; Set-Content -Path (Join-Path $knobs "beta.fail") -Value "9"
$env:EXAKIT_RETRY_KIND = "parse"
[void](& { Invoke-ExapumpUploadMany -Files @((New-RetryFile "beta")) -Id "t" } 6>&1)
Check "a malformed file is never retried" "1" (Get-RetryAttempts "beta")
Check "...and fails at once"              1   $script:ExakitUploadFailures.Count
Remove-Item Env:EXAKIT_RETRY_KIND -ErrorAction SilentlyContinue

Reset-Retry; Set-Content -Path (Join-Path $knobs "beta.fail") -Value "1"
$env:EXAKIT_UPLOAD_RETRIES = "0"
[void](& { Invoke-ExapumpUploadMany -Files @((New-RetryFile "beta")) -Id "t" } 6>&1)
Check "EXAKIT_UPLOAD_RETRIES=0 -> one attempt only" "1" (Get-RetryAttempts "beta")
Check "...and the cut is a failure"                 1   $script:ExakitUploadFailures.Count
Remove-Item Env:EXAKIT_UPLOAD_RETRIES -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "== a file the import keeps cutting is re-sent in pieces, all or nothing =="
# Against Exasol Personal on Windows the engine loses the LAST 10-90 KB of a
# file, and the same file mostly loses it again: retrying whole does not help,
# pieces small enough to arrive whole do. EXAKIT_UPLOAD_PIECE_KB=1 makes a
# 5 KB fixture several pieces. The fixture has a BOM, CRLF endings and a
# quoted field spanning a line, because pieces must be slices of the original
# bytes. Twin of the same section in dataset-load-progress.sh.
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("id,note`r`n")
foreach ($i in 1..120) {
    if ($i -eq 40) { [void]$sb.Append("$i,`"a quoted note`r`nthat spans, a line`"`r`n") }
    else { [void]$sb.Append("$i,plain note number $i for padding`r`n") }
}
$bigPath = Join-Path $retry "data\big.csv"
$bom = [byte[]](0xEF, 0xBB, 0xBF)
[System.IO.File]::WriteAllBytes($bigPath, $bom + [System.Text.Encoding]::ASCII.GetBytes($sb.ToString()))
$pieceDir = Join-Path $work "pieces"
New-Item -ItemType Directory -Force -Path $pieceDir | Out-Null
$pieces = @(Split-ExakitCsvPieces -Path $bigPath -Dir $pieceDir -PieceBytes 1024)
$orig = [System.IO.File]::ReadAllBytes($bigPath)
$headLen = [Array]::IndexOf($orig, [byte]10) + 1
$joined = New-Object System.Collections.Generic.List[byte]
$badHead = 0; $odd = 0
foreach ($p in $pieces) {
    $b = [System.IO.File]::ReadAllBytes($p)
    for ($k = 0; $k -lt $headLen; $k++) { if ($b[$k] -ne $orig[$k]) { $badHead++; break } }
    $joined.AddRange([byte[]]($b[$headLen..($b.Length - 1)]))
    if ((@($b | Where-Object { $_ -eq 34 }).Count % 2) -ne 0) { $odd++ }
}
$body = [byte[]]($orig[$headLen..($orig.Length - 1)])
Check "a 5 KB file cut at 1 KB -> several pieces"   $true  ($pieces.Count -ge 4)
Check "...every piece starts with the header (BOM included)" 0 $badHead
Check "...the rows put back together are the file, byte for byte" $true ([System.Linq.Enumerable]::SequenceEqual([byte[]]$joined.ToArray(), $body))
Check "...and no cut falls inside a quoted field"   0      $odd
function New-BigFile { return @{ Path = $bigPath; Target = "TPCH.BIG"; Name = "big.csv" } }
function Get-SqlLog { $f = Join-Path $knobs "sql.log"; if (Test-Path $f) { return (Get-Content $f -Raw) }; return "" }

$env:EXAKIT_UPLOAD_PIECE_KB = "1"
Reset-Retry; Set-Content -Path (Join-Path $knobs "big.fail") -Value "9"
[void](& { Invoke-ExapumpUploadMany -Files @((New-BigFile)) -Id "t" } 6>&1)
Check "cut every time -> re-sent in pieces, batch succeeds" 0 $script:ExakitUploadFailures.Count
Check "...the whole file was tried once"            "1" (Get-RetryAttempts "big")
Check "...each piece went to the staging table"     "TPCH.BIG__EXAKIT_PIECES" ((Get-Content (Join-Path $knobs "big.piece0002.table") -Raw).Trim())
Has   "...which is a copy of the target"            "CREATE TABLE TPCH.BIG__EXAKIT_PIECES LIKE TPCH.BIG" (Get-SqlLog)
Has   "...moved across in one statement"            "INSERT INTO TPCH.BIG SELECT * FROM TPCH.BIG__EXAKIT_PIECES" (Get-SqlLog)
Has   "...and the log says why"                     "big.csv: re-sending it as" (Get-Content $script:LogFile -Raw)

Reset-Retry; Set-Content -Path (Join-Path $knobs "big.fail") -Value "9"; Set-Content -Path (Join-Path $knobs "big.piece0002.fail") -Value "9"
[void](& { Invoke-ExapumpUploadMany -Files @((New-BigFile)) -Id "t" } 6>&1)
Check "a piece that never lands -> the file fails"  1   $script:ExakitUploadFailures.Count
Check "...after its own three attempts"             "3" (Get-RetryAttempts "big.piece0002")
Check "...the pieces after it are not sent"         "0" (Get-RetryAttempts "big.piece0003")
Lacks "...the target never sees the pieces"         "INSERT INTO TPCH.BIG" (Get-SqlLog)
Check "...and the staging table is dropped"         "DROP TABLE IF EXISTS TPCH.BIG__EXAKIT_PIECES" (@((Get-SqlLog).Trim() -split "`r?`n")[-1])

Reset-Retry; Set-Content -Path (Join-Path $knobs "big.fail") -Value "9"
$env:EXAKIT_UPLOAD_PIECE_KB = "0"
[void](& { Invoke-ExapumpUploadMany -Files @((New-BigFile)) -Id "t" } 6>&1)
Check "EXAKIT_UPLOAD_PIECE_KB=0 -> whole-file retries only" "3" (Get-RetryAttempts "big")
Check "...and no staging table"                     "" (Get-SqlLog)

# The single-file path - a user's own CSV - crosses the same connection.
$env:EXAKIT_UPLOAD_PIECE_KB = "1"
Reset-Retry; Set-Content -Path (Join-Path $knobs "big.fail") -Value "9"
$ok = [bool](@(& { Invoke-ExapumpUpload $bigPath "TPCH.BIG" -Soft } 6>&1)[-1])
Check "a user's file that keeps being cut loads in pieces too" $true $ok
Has   "...through the staging table"                "INSERT INTO TPCH.BIG SELECT * FROM TPCH.BIG__EXAKIT_PIECES" (Get-SqlLog)
Remove-Item Env:EXAKIT_UPLOAD_PIECE_KB -ErrorAction SilentlyContinue

Reset-Retry; Set-Content -Path (Join-Path $knobs "beta.fail") -Value "1"
$env:EXAKIT_RETRY_KIND = "silent"
[void](& { Invoke-ExapumpUploadMany -Files @((New-RetryFile "beta")) -Id "t" } 6>&1)
Check "a failure that printed nothing is retried"   0   $script:ExakitUploadFailures.Count
Check "...once"                                     "2" (Get-RetryAttempts "beta")
Has   "...and the log keeps the exit code"          "beta.csv: exapump exited with code 1 and printed nothing" (Get-Content $script:LogFile -Raw)
Remove-Item Env:EXAKIT_RETRY_KIND -ErrorAction SilentlyContinue
$env:EXAKIT_EXAPUMP_BIN = $stub

Write-Host ""
Write-Host "== a binary that cannot start YET is waited for, not called broken =="
# A freshly written, unsigned 20 MB exe is held open by Windows Defender and by
# corporate EDR agents while they scan it: "Access is denied" for three and a
# half minutes on a managed laptop, during which all six SELECT 1 attempts
# failed and the install blamed a database that was healthy the whole time.
# Twin of the same section in dataset-load-progress.sh.
Check "Access is denied is a not-yet"        $true  (Test-ExakitBinaryNotRunnableYet -Output "Program 'exapump.exe' failed to run: Access is denied")
Check "so is a file held by another process" $true  (Test-ExakitBinaryNotRunnableYet -Output "The process cannot access the file because it is being used by another process")
Check "so is Defender's virus wording"       $true  (Test-ExakitBinaryNotRunnableYet -Output "Operation did not complete successfully because the file contains a virus")
Check "a glibc fault is NOT a not-yet"       $false (Test-ExakitBinaryNotRunnableYet -Output "libc.so.6: version GLIBC_2.38 not found")
Check "an ordinary error is not either"      $false (Test-ExakitBinaryNotRunnableYet -Output "unknown flag: --nope")

# The wait is bounded and only the not-yet error is waited for, so a genuinely
# broken binary still fails in the same second it always did.
$vrCount = Join-Path $work "vr.count"
$env:EXAKIT_VR_COUNT = $vrCount
if ($onWindows) {
    $vrBin = Join-Path $work "vr-exapump.cmd"
    Set-Content -Path $vrBin -Encoding Ascii -Value @(
        "@echo off",
        "set N=0",
        "if exist `"%EXAKIT_VR_COUNT%`" set /p N=<`"%EXAKIT_VR_COUNT%`"",
        "set /a N+=1",
        ">`"%EXAKIT_VR_COUNT%`" echo %N%",
        "if %N% GEQ %EXAKIT_VR_OK_AT% (echo exapump 0.13.0",
        "exit /b 0)",
        "echo %EXAKIT_VR_ERR%",
        "exit /b 1"
    )
} else {
    $vrBin = Join-Path $work "vr-exapump"
    Set-Content -Path $vrBin -Value @(
        "#!/bin/sh",
        "n=0; [ -f `"`$EXAKIT_VR_COUNT`" ] && n=`"`$(cat `"`$EXAKIT_VR_COUNT`")`"",
        "n=`$((n + 1)); printf '%s' `"`$n`" > `"`$EXAKIT_VR_COUNT`"",
        "[ `"`$n`" -ge `"`$EXAKIT_VR_OK_AT`" ] && { echo 'exapump 0.13.0'; exit 0; }",
        "echo `"`$EXAKIT_VR_ERR`"",
        "exit 1"
    )
    & chmod +x $vrBin
}
$savedBinPath = $script:ExapumpBinPath
$script:ExapumpBinPath = $vrBin
$env:EXAKIT_VR_ERR = "Program 'exapump.exe' failed to run: Access is denied"
function Get-VrAttempts { if (Test-Path $vrCount) { return ((Get-Content $vrCount -Raw).Trim()) }; return "0" }

Remove-Item -Force $vrCount -ErrorAction SilentlyContinue
$env:EXAKIT_VR_OK_AT = "1"; $env:EXAKIT_EXAPUMP_READY_TIMEOUT = "30"
$failed = $false
try { Test-ExapumpRuns } catch { $failed = $true }
Check "a binary that runs at once is not waited for" $false $failed

Remove-Item -Force $vrCount -ErrorAction SilentlyContinue
$env:EXAKIT_VR_OK_AT = "2"
$failed = $false
$screen = (& { try { Test-ExapumpRuns } catch { $script:vrFailed = $true } } 6>&1) -join "`n"
Check "a locked binary is waited for, then runs" "2" (Get-VrAttempts)
Has   "...and the wait was announced"            "cannot start yet" $screen

Remove-Item -Force $vrCount -ErrorAction SilentlyContinue
$env:EXAKIT_VR_OK_AT = "99"; $env:EXAKIT_EXAPUMP_READY_TIMEOUT = "5"
$reason = ""
try { Test-ExapumpRuns } catch { $reason = "$_" }
Has   "locked past the budget -> failure names the scanner" "virus scanner or endpoint-security agent" $reason
Lacks "...and never mentions SELECT"                        "SELECT" $reason

Remove-Item -Force $vrCount -ErrorAction SilentlyContinue
$env:EXAKIT_VR_ERR = "unknown flag: --nope"; $env:EXAKIT_EXAPUMP_READY_TIMEOUT = "60"
$reason = ""
try { Test-ExapumpRuns } catch { $reason = "$_" }
Check "a broken binary fails at once, unwaited" "1" (Get-VrAttempts)
Has   "...saying it does not run"               "installed but does not run" $reason
$script:ExapumpBinPath = $savedBinPath
foreach ($v in @("EXAKIT_VR_COUNT", "EXAKIT_VR_OK_AT", "EXAKIT_VR_ERR", "EXAKIT_EXAPUMP_READY_TIMEOUT")) {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "== a dataset whose marker tables are empty is not loaded =="
# The dataset's DDL creates its tables before a single file is uploaded, so an
# upload that failed left empty tables that the marker check called "loaded".
# The listing carries every table's row count and only a table with rows is
# kept; a stub answering with every table but ORDERS reads as "not loaded" for
# markers that include ORDERS. Twin of the checks in tests/dataset-load-progress.sh.
$exapumpPs1 = Get-Content (Join-Path $repo "setup/lib/exapump.ps1") -Raw
Has "the listing carries the row count"  "TABLE_NAME || '|' || TABLE_ROW_COUNT" $exapumpPs1
Has "...and says when it was answered"   "SELECT 'EXAKIT.LISTING_ANSWERED|1' AS QUALIFIED FROM DUAL UNION ALL" $exapumpPs1
function Get-ExakitQualifiedTables { return @{ "TPCH.REGION" = $true; "TPCH.NATION" = $true } }
function Sync-ExakitDatasetFlag { }
$script:ExakitTableListing = $null
Check "markers with rows -> loaded"         $true  (Test-ExakitDatasetLoaded -Dataset @{ Id = "tpch"; Flag = "data.datasets.tpch.loaded"; Schema = "TPCH"; Markers = @("REGION", "NATION") })
Check "a marker without rows -> not loaded" $false (Test-ExakitDatasetLoaded -Dataset @{ Id = "tpch"; Flag = "data.datasets.tpch.loaded"; Schema = "TPCH"; Markers = @("REGION", "ORDERS") })

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "data-load-shapes-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
