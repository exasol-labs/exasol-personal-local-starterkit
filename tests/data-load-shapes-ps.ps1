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

# No console, always (W4-04). These checks pin what the kit does WITHOUT a
# console, the way CI runs them. Started from a real console, the kit's
# console checks (Test-ExakitInteractive, [Console]::IsInputRedirected) saw
# one: Import-ExakitLocalFile asked its questions and the run hung, and the
# tls-pin driver children inherited the console. So a run that has a console
# runs itself once more with stdin from an empty file, and exits with that
# run's code. EXAKIT_TEST_NO_CONSOLE stops a second hop.
if (-not [Console]::IsInputRedirected -and -not $env:EXAKIT_TEST_NO_CONSOLE) {
    $env:EXAKIT_TEST_NO_CONSOLE = "1"
    $noInput = [System.IO.Path]::GetTempFileName()
    $code = 1
    try {
        $self = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -Wait -PassThru `
            -RedirectStandardInput $noInput `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
        if ($null -ne $self.ExitCode) { $code = $self.ExitCode }
    } finally {
        Remove-Item -Force $noInput -ErrorAction SilentlyContinue
    }
    exit $code
}

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
# The CRLF copy is written by setup/lib/csv_guard.py, which the kit runs on the
# system Python ("python"). Off Windows that is usually "python3": a "python"
# beside the stub that runs it, so no uv-managed runtime is fetched here.
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $py3 = Get-Command python3 -ErrorAction SilentlyContinue
    if ($py3) {
        $pyDir = Join-Path $work "pybin"; New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
        Set-Content -Path (Join-Path $pyDir "python") -Value @("#!/bin/sh", "exec `"$($py3.Source)`" `"`$@`"")
        & chmod +x (Join-Path $pyDir "python")
        $env:PATH = $pyDir + [System.IO.Path]::PathSeparator + $env:PATH
    }
}

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
# A COMMA IN THE HEADER of a ';' file made it load as comma-separated. Twin of
# the same checks in bulk-folder-load.sh.
Put "semi-quoted.csv" ($utf8.GetBytes('"Name, first";Amount' + "`n" + '"Smith, J";12' + "`n" + '"Doe, A";7' + "`n"))
Put "semi-prose.csv"  ($utf8.GetBytes("Betrag (EUR, netto);Datum;Notiz`n1,50;2026-01-01;x`n12;2026-01-02;y`n"))
Put "semi-tie.csv"    ($utf8.GetBytes("Betrag (EUR, netto);Datum`n1,50;2026-01-01`n2,00;2026-01-02`n"))
Put "comma-quoted-semi.csv" ($utf8.GetBytes('id,note' + "`n" + '1,"a;b"' + "`n" + '2,"c;d"' + "`n"))
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "semi-quoted.csv")
Check "a ';' file with a quoted comma in its header selects the semicolon" ";|" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "semi-prose.csv")
Check "...and with an unquoted one, read from the rows" ";|" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "semi-tie.csv")
Check "a file both ',' and ';' split evenly is ';', named as a guess" ";|ambiguous-delimiter" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "comma-quoted-semi.csv")
Check "a ',' file with a ';' inside quotes stays comma" ",|" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
$before = [System.IO.File]::ReadAllBytes((Join-Path $shapes "windows.csv"))
Check "...and the file is byte-for-byte what it was" 3 ($before.Length - $utf8.GetBytes("datum,gesamt`r`n2026.01.01,7`r`n").Length)

Write-Host ""
Write-Host "== through the real uploader, into the stub binary =="
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$said = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "windows.csv") -Target "T.WINDOWS" } 6>&1
$rc = @($said | Where-Object { $_ -is [bool] })[0]
Check "the upload is reported as it went" $true $rc
# WINDOWS LINE ENDINGS: exapump 0.14.0 has no row-separator option, so a CRLF
# file failed on a numeric last column ("value='10.5<CR>'", seen live on
# Windows 11) and loaded a CR into a text one. The kit sends an LF copy; the
# user's file stays as it was. Twin of the same checks in bulk-folder-load.sh.
Lacks "...and no carriage-return warning is needed any more" "carriage return" ($said -join "`n")
$argv = Get-Content (Join-Path $got "argv") -Raw
Lacks "a CRLF file is not handed over as it is" ("upload " + (Join-Path $shapes "windows.csv")) $argv
Has "...but as a copy of the same name" ("windows.csv") $argv
Lacks "...with no delimiter flag for a comma file" "--delimiter" $argv
$received = [System.IO.File]::ReadAllBytes((Join-Path $got "received"))
$lfBytes = [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes("datum,gesamt`n2026.01.01,7`n")
Check "...whose records end in LF, the BOM kept" ([Convert]::ToBase64String($lfBytes)) ([Convert]::ToBase64String($received))
Check "...and the user's file is byte-for-byte what it was" ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $shapes "windows.csv"))))
Check "...and the copy is gone afterwards" 0 @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter "exakit-lf-*" -ErrorAction SilentlyContinue).Count
# W3-01: MIXED LINE ENDINGS. PowerShell's `"a`nb`nc" | Set-Content` ends its
# rows in LF and its last line in CRLF: only the first terminator was read, so
# the file went over as it was and failed on "value='9.25<CR>'" (seen live on
# Windows 11). Any CRLF anywhere flags it, and the LF copy goes over. Twin of
# the same checks in bulk-folder-load.sh.
Put "mixed-last.csv" ($utf8.GetBytes("id,amount`n1,7`n2,9.25`r`n"))
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "mixed-last.csv")
Check "a file whose last line alone ends in CRLF is flagged" ",|crlf,mixed-eol" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$saidMixed = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "mixed-last.csv") -Target "T.MIXED" } 6>&1
Lacks "...and is not handed over as it is" ("upload " + (Join-Path $shapes "mixed-last.csv")) (Get-Content (Join-Path $got "argv") -Raw)
Check "...but as an LF copy" ([Convert]::ToBase64String($utf8.GetBytes("id,amount`n1,7`n2,9.25`n"))) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $got "received"))))
Lacks "...with no carriage-return warning" "carriage return" ($saidMixed -join "`n")
# A last record ended by a CR alone, no LF after it: flagged as on macOS and
# Linux (review 0.3.1, item 2, the twins agree), and the copy ends it in LF.
Put "eof-cr.csv" ($utf8.GetBytes("a,b`n1,2`r"))
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "eof-cr.csv")
Check "a file that ends in a lone CR is flagged" ",|crlf,mixed-eol" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
$rc = Invoke-ExapumpUpload -Path (Join-Path $shapes "eof-cr.csv") -Target "T.EOFCR" 6>$null
Check "...and goes over as an LF copy" ([Convert]::ToBase64String($utf8.GetBytes("a,b`n1,2`n"))) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $got "received"))))
Put "mixed-first.csv" ($utf8.GetBytes("id,amount`r`n1,7`n2,9.25`n"))
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "mixed-first.csv")
Check "a CRLF header over LF rows is flagged CRLF" ",|crlf" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
$rc = Invoke-ExapumpUpload -Path (Join-Path $shapes "mixed-first.csv") -Target "T.MIXED" 6>$null
Check "...and goes over as an LF copy" ([Convert]::ToBase64String($utf8.GetBytes("id,amount`n1,7`n2,9.25`n"))) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $got "received"))))
# A CRLF past the first read buffer is still found.
Put "mixed-far.csv" ($utf8.GetBytes("id,amount`n" + ("1,7`n" * 300000) + "2,9.25`r`n"))
Check "a CRLF far past the first megabyte is still found" "crlf,mixed-eol" (Get-ExakitCsvInspection -Path (Join-Path $shapes "mixed-far.csv")).Flags
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "plain.csv")
Check "an LF file is still not flagged" "" $look.Flags
Put "quoted.csv" ($utf8.GetBytes("id,note,amount`r`n1,`"two`r`nlines`",10.5`r`n2,`"say `"`"hi`"`"`",7`r`n"))
$rc = Invoke-ExapumpUpload -Path (Join-Path $shapes "quoted.csv") -Target "T.QUOTED" 6>$null
Check "a CRLF inside quotes is kept, the record ends are made LF" `
    ([Convert]::ToBase64String($utf8.GetBytes("id,note,amount`n1,`"two`r`nlines`",10.5`n2,`"say `"`"hi`"`"`",7`n"))) `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $got "received"))))
# A quote opens a field only at the start of one: an inch mark (27") in an
# unquoted field is data, and every record after it still ends in LF.
Put "inch.csv" ($utf8.GetBytes("sku,product,qty`r`n1,27`" monitor,4`r`n2,USB cable,10`r`n3,mouse,7`r`n"))
$saidInch = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "inch.csv") -Target "T.INCH" } 6>&1
Check "an inch mark does not keep the later records' CR" `
    ([Convert]::ToBase64String($utf8.GetBytes("sku,product,qty`n1,27`" monitor,4`n2,USB cable,10`n3,mouse,7`n"))) `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $got "received"))))
Lacks "...and needs no carriage-return warning" "carriage return" ($saidInch -join "`n")
# The field start is the file's own delimiter: in a tab file a quote after a
# tab opens a field, so the CRLF inside it is data.
Put "quoted-tab.tsv" ($utf8.GetBytes("id`tnote`r`n1`t`"two`r`nlines`"`r`n2`tx`r`n"))
$rc = Invoke-ExapumpUpload -Path (Join-Path $shapes "quoted-tab.tsv") -Target "T.QTAB" 6>$null
Check "a tab file's quoted CRLF is kept, its record ends made LF" `
    ([Convert]::ToBase64String($utf8.GetBytes("id`tnote`n1`t`"two`r`nlines`"`n2`tx`n"))) `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $got "received"))))
# A quote that never closes leaves CRLFs unconverted: the original goes over
# and the carriage-return warning is still said.
Put "open.csv" ($utf8.GetBytes("id,note`r`n1,`"never closed`r`n2,x`r`n"))
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$saidOpen = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "open.csv") -Target "T.OPEN" } 6>&1
Has "a quote that never closes: the original goes over" ("upload " + (Join-Path $shapes "open.csv")) (Get-Content (Join-Path $got "argv") -Raw)
Has "...and the carriage-return warning stays" "carriage return" ($saidOpen -join "`n")
$saidPlain = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "plain.csv") -Target "T.PLAIN" } 6>&1
Lacks "...and a clean file is not" "carriage return" ($saidPlain -join "`n")
$rc = Invoke-ExapumpUpload -Path (Join-Path $shapes "german.csv") -Target "T.GERMAN" 6>$null
$argv = Get-Content (Join-Path $got "argv") -Raw
Has "a ';' file is uploaded with exapump's own --delimiter ;" "--delimiter ;" $argv
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$rc = Invoke-ExapumpUpload -Path (Join-Path $shapes "semi-quoted.csv") -Target "T.SEMI" 6>$null
Has "a ';' file with a comma in its header goes over with --delimiter ;" "--delimiter ;" (Get-Content (Join-Path $got "argv") -Raw)
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
Write-Host "== a stray double quote is named as one, not as a line break =="
# Seen live on Windows, with both line endings: an inch mark in an unquoted
# field (1,27" monitor,4). "Field delimiter" is Exasol's name for the QUOTE
# character, so this ETL-2107 is exactly that, and the kit said "a line break
# or an unescaped comma inside a quoted field". Twin of the same section in
# tests/bulk-folder-load.sh.
Put "c_inch.csv"      ($utf8.GetBytes("id,item,qty`n1,27`" monitor,4`n2,desk,1`n"))
Put "c_inch_crlf.csv" ($utf8.GetBytes("id,item,qty`r`n1,27`" monitor,4`r`n2,desk,1`r`n"))
Put "c_break.csv"     ($utf8.GetBytes("id,item,qty`n1,`"two`nlines`",4`n2,`"a `"`"quoted`"`" word`",1`n"))
Put "c_semi.csv"      ($utf8.GetBytes("id;item`n1;`"ok`"`n2;5 foot 11`" tall`n"))
$inchSays = @("Error: SQL execution failed: Protocol error: ETL-2107: Error while parsing row=0 (starting from 0) [CSV Parser found at byte 4 (starting with 1 at the beginning of the row) of 4 single field delimiter in a not enclosed field in file '001.csv'. Please check for unescaped field delimiters in data fields (they have to be escaped)] (Session: 1)")
$inchWords = 'row 0 has a double quote (") inside a field that is not in quotes: put that field in quotes and double the quote (e.g. "27"" monitor")'
Check "an inch mark in an unquoted field is called a double quote" $inchWords (Get-ExakitUploadFailureReason -Output $inchSays -Path (Join-Path $shapes "c_inch.csv"))
Check "...with Windows line endings too" $inchWords (Get-ExakitUploadFailureReason -Output $inchSays -Path (Join-Path $shapes "c_inch_crlf.csv"))
Check "...and in a ';' file" $inchWords (Get-ExakitUploadFailureReason -Output $inchSays -Path (Join-Path $shapes "c_semi.csv"))
Check "a file whose quotes are in order keeps the line-break reading" "row 0 has a line break or an unescaped comma inside a quoted field" (Get-ExakitUploadFailureReason -Output $inchSays -Path (Join-Path $shapes "c_break.csv"))
Check "...and so does a call that names no file" "row 0 has a line break or an unescaped comma inside a quoted field" (Get-ExakitUploadFailureReason -Output $inchSays)
Remove-Item -Force (Join-Path $shapes "c_inch.csv"), (Join-Path $shapes "c_inch_crlf.csv"), (Join-Path $shapes "c_break.csv"), (Join-Path $shapes "c_semi.csv")

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

# A database that completes the handshake and then never answers: status asks
# with a limit and gets $null (the manifest stands in), not a wait as long as
# the hang. Twin of the block in tests/status-soft-components.sh.
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $hang = Join-Path $work "hang-exapump.cmd"
    Set-Content -LiteralPath $hang -Value "@ping -n 31 127.0.0.1 >nul" -Encoding ASCII
} else {
    $hang = Join-Path $work "hang-exapump"
    Set-Content -LiteralPath $hang -Value "#!/bin/sh`nexec sleep 30" -Encoding ASCII
    & chmod +x $hang
}
$previousBin = $env:EXAKIT_EXAPUMP_BIN
$env:EXAKIT_EXAPUMP_BIN = $hang
$started = Get-Date
$rows = Get-ExakitQualifiedTableRows -TimeoutSeconds 2
$took = ((Get-Date) - $started).TotalSeconds
$env:EXAKIT_EXAPUMP_BIN = $previousBin
Check "a hung database: the bounded listing answers null" $true ($null -eq $rows)
Check "...within its limit, not the hang's 30s" $true ($took -lt 15)
Has "...and says when it was answered"   "SELECT 'EXAKIT.LISTING_ANSWERED|1' AS QUALIFIED FROM DUAL UNION ALL" $exapumpPs1
function Get-ExakitQualifiedTables { return @{ "TPCH.REGION" = $true; "TPCH.NATION" = $true } }
function Sync-ExakitDatasetFlag { }
$script:ExakitTableListing = $null
Check "markers with rows -> loaded"         $true  (Test-ExakitDatasetLoaded -Dataset @{ Id = "tpch"; Flag = "data.datasets.tpch.loaded"; Schema = "TPCH"; Markers = @("REGION", "NATION") })
Check "a marker without rows -> not loaded" $false (Test-ExakitDatasetLoaded -Dataset @{ Id = "tpch"; Flag = "data.datasets.tpch.loaded"; Schema = "TPCH"; Markers = @("REGION", "ORDERS") })
# The 0.2.5 -> 0.3.0 upgrade: TPC-H is kit 0.2.5's sample and hidden=yes in this release. Loaded, it is still the
# kit's data, so status lists it (it said "none loaded" over 173,745 rows). Twin of tests/agent-operability.sh.
function Get-ExakitQualifiedTables { return @{ "TPCH.CUSTOMER" = $true; "TPCH.ORDERS" = $true; "TPCH.LINEITEM" = $true } }
Check "TPC-H is hidden in this release"            $true (@(Get-ExakitBundledDatasets -IncludeHidden | Where-Object { $_.Id -eq "tpch" -and $_.Hidden }).Count -eq 1)
Check "...and loaded by an earlier kit, it is listed" "tpch" ((@(Get-ExakitVerifiedDatasets) | Where-Object { $_ -eq "tpch" }) -join ",")

Write-Host ""
Write-Host "== a file name the database would misread still becomes a table =="
# exapump writes the target into its CREATE TABLE unquoted: STARTER_KIT.2025_01
# is a syntax error and STARTER_KIT.ORDER "not allowed since it is a keyword"
# (both seen on a live database). Twin of the section in tests/bulk-folder-load.sh.
Check "a leading digit gets T_"       "T_2025_01" (Get-ExakitTableName "2025-01.csv")
Check "a reserved word gets T_"       "T_ORDER"   (Get-ExakitTableName "ORDER.csv")
Check "...whatever its case"          "T_USER"    (Get-ExakitTableName "user.csv")
Check "...and for Parquet too"        "T_DATE"    (Get-ExakitTableName "date.parquet")
Check "an ordinary name is untouched" "SALES"     (Get-ExakitTableName "sales.csv")
Check "a name is cut at 128 characters" 128 (Get-ExakitTableName (("a" * 200) + ".csv")).Length
Check "a typed reserved table name is refused" $false (Test-ExakitTableTarget "STARTER_KIT.ORDER")
Check "...and a schema starting with a digit"  $false (Test-ExakitTableTarget "2025.SALES")
Check "...while T_ORDER is fine"               $true  (Test-ExakitTableTarget "STARTER_KIT.T_ORDER")
Has "the refusal says why" "ORDER is an SQL reserved word" (Get-ExakitTableTargetProblem "STARTER_KIT.ORDER")
Check "a name part is not prefixed" "ORDER" (Get-ExakitNamePart "order.parquet")
$names = Join-Path $work "names"; New-Item -ItemType Directory -Force -Path $names | Out-Null
[System.IO.File]::WriteAllText((Join-Path $names "2025-01.csv"), "a,b`n1,2`n")
[System.IO.File]::WriteAllText((Join-Path $names "ORDER.csv"), "a,b`n3,4`n")
$nplan = @(Get-ExakitBulkFolderPlan -Path $names)
Has "the folder plan names 2025-01.csv T_2025_01" "load|csv|T_2025_01|" ($nplan -join "`n")
Has "...and ORDER.csv T_ORDER" "load|csv|T_ORDER|" ($nplan -join "`n")
$nchosen = @($nplan | Where-Object { $_.StartsWith("load|") } | ForEach-Object { $_.Substring(5) })
$nshown = (& { Show-ExakitBulkPlan -Plan $nplan -Chosen $nchosen -Schema "S" -Path $names } 6>&1) -join "`n"
Has "...and the plan says why" "T_ goes in front of a name that starts with a digit" $nshown
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$env:EXAKIT_DATA_FILE = Join-Path $names "2025-01.csv"
# No database and no manifest here: the bookkeeping after the upload is stubbed.
function Set-ExakitManifestValue { }
function Confirm-ExakitLoadedTable { $script:ExakitLastVerifiedRows = 1 }
$nsaid = (& { Import-ExakitLocalFile } 6>&1) -join "`n"
Remove-Item Env:EXAKIT_DATA_FILE
Has "a single 2025-01.csv is uploaded into T_2025_01" "--table STARTER_KIT.T_2025_01" (Get-Content (Join-Path $got "argv") -Raw)
Has "...and says the name it got" "2025-01.csv loads as T_2025_01" $nsaid
# Which delimiter is used is said, and when more than one fits, that is said too.
$env:EXAKIT_DATA_FILE = Join-Path $shapes "semi-tie.csv"
$env:EXAKIT_DATA_TABLE = "STARTER_KIT.GUESS"
$gsaid = (& { Import-ExakitLocalFile } 6>&1) -join "`n"
$env:EXAKIT_DATA_FILE = Join-Path $shapes "semi-quoted.csv"
$env:EXAKIT_DATA_TABLE = "STARTER_KIT.SEMI"
$ssaid = (& { Import-ExakitLocalFile } 6>&1) -join "`n"
Remove-Item Env:EXAKIT_DATA_FILE, Env:EXAKIT_DATA_TABLE
Has "a ';' file with a comma in its header is said to be semicolon-separated" "semi-quoted.csv is semicolon-separated" $ssaid
Has "...and a file two delimiters fit says which one it loads with" "semi-tie.csv fits more than one separator - loading it as semicolon-separated." $gsaid
Lacks "...while a plain one-delimiter file says nothing about it" "separat" $nsaid

Write-Host ""
Write-Host "== a single file that fails leaves no empty table behind =="
# exapump creates the table before the import fails, so a refused file left an
# empty table (seen live on Windows 11: STARTER_KIT.GA_CSV_TEST, 0 rows). Twin
# of the same checks in bulk-folder-load.sh.
$script:calls = @()
function Invoke-Exapump {
    param([string[]]$ExapumpArgs)
    $script:calls += ($ExapumpArgs -join " ")
    if ($ExapumpArgs[0] -eq "upload") {
        return @{ Success = $false; ExitCode = 1; Output = "Error: SQL execution failed: Protocol error: ETL-3050: [Column=1 Row=0] [Transformation of value='x' failed - invalid character value for cast] (Session: 1)" }
    }
    return @{ Success = $true; ExitCode = 0; Output = "" }
}
function Get-ExakitTableRowCount { param($Target) return 0 }
function Write-ExapumpOutput { }
function Show-ExakitDbErrorRemedy { }
$script:ExakitUploadTableBefore = "absent"
$failSaid = ""
try { Invoke-ExapumpUpload -Path (Join-Path $shapes "plain.csv") -Target "T.GONE" | Out-Null } catch { $failSaid = "$($_.Exception.Message)" }
$script:ExakitUploadTableBefore = ""
Has "a refused file's empty new table is dropped" "DROP TABLE IF EXISTS T.GONE" ($script:calls -join "`n")
Has "...and the message says so" "no empty table left behind" $failSaid
# The whole sentence for the live stray-quote file, through the real uploader.
$inchDir = Join-Path $work "inch"; New-Item -ItemType Directory -Force -Path $inchDir | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $inchDir "c_inch.csv"), $utf8.GetBytes("id,item,qty`r`n1,27`" monitor,4`r`n2,desk,1`r`n"))
$script:inchOut = $inchSays[0]
function Invoke-Exapump {
    param([string[]]$ExapumpArgs)
    $script:calls += ($ExapumpArgs -join " ")
    if ($ExapumpArgs[0] -eq "upload") { return @{ Success = $false; ExitCode = 1; Output = $script:inchOut } }
    return @{ Success = $true; ExitCode = 0; Output = "" }
}
$script:ExakitUploadTableBefore = "absent"
$inchSaid = ""
try { Invoke-ExapumpUpload -Path (Join-Path $inchDir "c_inch.csv") -Target "STARTER_KIT.C_INCH" | Out-Null } catch { $inchSaid = "$($_.Exception.Message)" }
$script:ExakitUploadTableBefore = ""
Has "the single-file load says it in one sentence" "Could not load c_inch.csv into STARTER_KIT.C_INCH - $inchWords, no empty table left behind" $inchSaid
Lacks "...and no longer sends the reader looking for a line break" "line break" $inchSaid
$script:calls = @()
try { Invoke-ExapumpUpload -Path (Join-Path $shapes "plain.csv") -Target "T.GONE" | Out-Null } catch { }
Lacks "...but a table that was there before is left alone" "DROP TABLE" ($script:calls -join "`n")
$importLocal = (Get-Content (Join-Path $repo "setup/lib/exapump.ps1") -Raw)
Has "the single-file load says when its table was not there" '$script:ExakitUploadTableBefore = "absent"' $importLocal

Write-Host ""
Write-Host "== one JSON file by name: named after the file, loaded once, failures said =="
# Seen on a live Windows 11 install: ga_json_test.json became
# GA_JSON_TEST_NORMALISED (+ _NORMALISED_TAGS), a second run appended on top,
# and an engine that could not run answered exit 0 with "This JSON file could
# not be read". Twin of the same section in bulk-folder-load.sh. The engine
# writes Parquet names the way the real one does; the database is a hashtable.
$js = Join-Path $work "json1"; New-Item -ItemType Directory -Force -Path $js | Out-Null
$script:CacheDir = Join-Path $js "cache"
$jsonFile = Join-Path $js "ga_json_test.json"
[System.IO.File]::WriteAllText($jsonFile, "{`n  `"id`": 1,`n  `"tags`": [`"a`", `"b`"]`n}`n")
$script:db = @{}
$script:jsLog = @()
$script:failEngine = $false
$script:realConfirmJson = ${function:Confirm-ExakitJsonTablesReady}
function Test-ExakitJsonTablesApplicable { return $true }
function Confirm-ExakitJsonTablesReady { return $true }
function Get-ExakitJsonTablesBin { return "engine" }
function Invoke-ExakitJsonTablesLogged {
    param([string]$Exe, [string[]]$Arguments = @())
    if ($script:failEngine) {
        $script:ExakitJsonTablesOutput = "error: cannot execute the ingest engine: No such file or directory"
        return 127
    }
    $in = $Arguments[[array]::IndexOf($Arguments, "--input") + 1]
    $out = $Arguments[[array]::IndexOf($Arguments, "--output-dir") + 1]
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($in)
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $out "$stem.parquet"), "")
    [System.IO.File]::WriteAllText((Join-Path $out "$stem.tags[].parquet"), "")
    $script:ExakitJsonTablesOutput = ""
    return 0
}
function Invoke-ExapumpUpload {
    param([string]$Path, [string]$Target, [switch]$Soft)
    $script:jsLog += "upload $(Split-Path $Path -Leaf) -> $Target"
    $n = 0; if ($script:db.ContainsKey($Target)) { $n = $script:db[$Target] }
    $script:db[$Target] = $n + 1
    return $true
}
function Confirm-ExakitLoadedTable { param($Target) $script:ExakitLastVerifiedRows = $script:db[$Target] }
function Get-ExakitTableRowCount { param($Target) if ($script:db.ContainsKey($Target)) { return $script:db[$Target] } return "absent" }
function Invoke-Exapump {
    param([string[]]$ExapumpArgs)
    $line = $ExapumpArgs -join " "
    $script:jsLog += $line
    if ($line -match 'DROP TABLE IF EXISTS (\S+)') { $script:db.Remove($Matches[1]) }
    return @{ Success = $true; ExitCode = 0; Output = "" }
}
function Confirm-ExakitSchemaExists { return $true }
$env:EXAKIT_DATA_FILE = $jsonFile
$env:EXAKIT_DATA_TABLE = "T.GA_JSON_TEST"
function Invoke-JsonLoad {
    $script:jsLog = @()
    $r = $null; $err = ""
    $said = (& { try { $script:jsResult = Import-ExakitLocalFile } catch { $script:jsErr = "$($_.Exception.Message)" } } 6>&1 2>&1) -join "`n"
    return $said
}
$script:jsErr = ""
$script:jsResult = "unset"
$said = Invoke-JsonLoad
# F-b (Windows 11 upgrade): a load that worked answered "declined" - nothing
# after the Target table prompt, exit 5 - because $true -eq "declined" is
# $true in PowerShell.
Check "a JSON load that worked is not reported as declined (exit 5)" "" ("" + $script:jsResult)
Has "...it says Loaded with the tables it made" "Loaded $jsonFile into T.GA_JSON_TEST, T.GA_JSON_TEST_TAGS" $said
Has "a JSON file's documents land in the table named after the file" "upload normalised.parquet -> T.GA_JSON_TEST" ($script:jsLog -join "`n")
Has "...its array in <table>_TAGS" "upload normalised.tags[].parquet -> T.GA_JSON_TEST_TAGS" ($script:jsLog -join "`n")
Lacks "...not after the kit's temporary copy" "T.GA_JSON_TEST_NORMALISED" (($script:jsLog -join "`n") + $said)
Has "a receipt is written per table" "T.GA_JSON_TEST_TAGS`t" (Get-Content (Join-Path $script:CacheDir "load-receipts.tsv") -Raw)
$said = Invoke-JsonLoad
Has "the same file again is recognised and left as it is, naming its tables and the file" "T.GA_JSON_TEST, T.GA_JSON_TEST_TAGS already hold the 2 rows ga_json_test.json loaded" $said
Lacks "...and no copy note for the file itself" "has the same content as" $said
Check "...nothing is sent twice" 0 @($script:jsLog | Where-Object { $_ -like "upload *" }).Count
Check "...and the rows did not double" 1 $script:db["T.GA_JSON_TEST"]
# F-c (Windows 11 upgrade): a byte-identical copy matches the original's
# receipts. The message named the copy as the file that made the tables.
$jsonCopy = Join-Path $js "ga_json_copy.json"
Copy-Item -LiteralPath $jsonFile -Destination $jsonCopy
$env:EXAKIT_DATA_FILE = $jsonCopy; $env:EXAKIT_DATA_TABLE = "T.GA_JSON_COPY"
$said = Invoke-JsonLoad
$env:EXAKIT_DATA_FILE = $jsonFile; $env:EXAKIT_DATA_TABLE = "T.GA_JSON_TEST"
Has "a byte-identical copy is recognised, naming the tables and the file that made them" "T.GA_JSON_TEST, T.GA_JSON_TEST_TAGS already hold the 2 rows ga_json_test.json loaded" $said
Has "...and that the copy has the same content" "ga_json_copy.json has the same content as ga_json_test.json" $said
Check "...nothing is sent" 0 @($script:jsLog | Where-Object { $_ -like "upload *" }).Count
Remove-Item -Force -LiteralPath $jsonCopy
$env:EXAKIT_ON_EXISTING = "replace"
$said = Invoke-JsonLoad
Has "replace drops what it loaded before" "DROP TABLE IF EXISTS T.GA_JSON_TEST_TAGS" ($script:jsLog -join "`n")
Check "...and the table holds one load, not two" 1 $script:db["T.GA_JSON_TEST"]
Remove-Item Env:EXAKIT_ON_EXISTING
Remove-Item -Force (Join-Path $script:CacheDir "load-receipts.tsv")
$script:db = @{ "T.GA_JSON_TEST" = 40 }
$script:jsResult = $null
$said = Invoke-JsonLoad
Check "rows this kit did not load are not loaded over, by default" "declined" $script:jsResult
Has "...and the refusal names the table" "Not loaded: T.GA_JSON_TEST already holds 40 rows" $said
Check "...nothing was sent" 0 @($script:jsLog | Where-Object { $_ -like "upload *" }).Count
$env:EXAKIT_ON_EXISTING = "append"
$script:jsResult = "unset"
$said = Invoke-JsonLoad
Check "append loads on top of the 40" 41 $script:db["T.GA_JSON_TEST"]
Check "...and is a load, not declined" "" ("" + $script:jsResult)
Has "...that says Loaded" "Loaded $jsonFile into" $said
Remove-Item Env:EXAKIT_ON_EXISTING
$script:db = @{}
Remove-Item -Force (Join-Path $script:CacheDir "load-receipts.tsv") -ErrorAction SilentlyContinue
$script:failEngine = $true
$script:jsErr = ""
$said = Invoke-JsonLoad
$script:failEngine = $false
Has "an engine that cannot run fails the load (not exit 0)" "Could not load ga_json_test.json" $script:jsErr
Has "...and says it is the engine" "The JSON Tables engine could not load" $said
Has "...with the engine's own words" "cannot execute the ingest engine" ($said + $script:jsErr)
Has "...and the repair" "exakit update json-tables" $said
Lacks "...without blaming a valid file" "It must be one JSON document" $said
# MCX-01: one JSON file with the engine missing installs it (about a minute).
# On a console that animates, a spinner of its own says so for the whole install
# and leaves no line behind - twin of _exakit_json_tables_ensure; on a plain
# console the marketplace's own lines still say it, so it is never silent.
# Through the real engine check and the real marketplace apply, with a uv stub
# that streams what apply.py streams.
$jtWork = Join-Path $work "jtmissing"; New-Item -ItemType Directory -Force -Path $jtWork | Out-Null
$jtReady = Join-Path $jtWork "ready"
if ($onWindows) {
    $jtUv = Join-Path $jtWork "uv.cmd"
    Set-Content -Path $jtUv -Encoding Ascii -Value @(
        "@echo off",
        "if defined JT_FAIL goto fail",
        "echo @@EXAKIT^|json-tables^|installing^|^|0",
        "type nul > `"$jtReady`"",
        "echo @@EXAKIT^|json-tables^|done^|0.4.0^|1",
        "exit /b 0",
        ":fail",
        "echo @@EXAKIT^|json-tables^|installing^|^|0",
        "echo @@EXAKIT^|json-tables^|failed^|the download was refused^|0",
        "exit /b 1"
    )
} else {
    $jtUv = Join-Path $jtWork "uv"
    Set-Content -Path $jtUv -Value @(
        "#!/bin/sh",
        "echo '@@EXAKIT|json-tables|installing||0'",
        "if [ -n `"`$JT_FAIL`" ]; then echo '@@EXAKIT|json-tables|failed|the download was refused|0'; exit 1; fi",
        ": > `"$jtReady`"",
        "echo '@@EXAKIT|json-tables|done|0.4.0|1'",
        "exit 0"
    )
    & chmod +x $jtUv
}
$jtPrevUv = ${function:Get-ExakitUvBin}
$jtPrevNow = ${function:Invoke-ExakitMarketplacePythonNow}
$jtPrevNeeds = ${function:Test-ExakitAddonNeedsUpdate}
$jtPrevBin = ${function:Get-ExakitJsonTablesBin}
$jtPrevSpin = ${function:Start-ExakitSpinner}
$jtPrevFancy = $script:UiFancy
$script:jtSpins = @()
function Get-ExakitUvBin { return $jtUv }
# The real readiness check, with the real per-run memo of the add-on's answers
# (Invoke-ExakitMarketplacePython): only the Python call under it is stubbed, so
# "installed" changes the moment the install has run - as on a real machine. A
# load that installed the engine first was refused on Windows because the memo
# still answered "not installed" from before the install.
function Invoke-ExakitMarketplacePythonNow {
    param([string]$Id, [string]$Operation, [bool]$DryRun = $false)
    if ($Operation -eq 'installed-version') { if (Test-Path -LiteralPath $jtReady) { return '0.4.0' } else { return '' } }
    if ($Operation -eq 'applicable') { return $true }
    return ''
}
function Test-ExakitAddonNeedsUpdate { param([string]$Id) return $false }
function Get-ExakitJsonTablesBin { return $jtUv }
function Start-ExakitSpinner([string]$Label) { $script:jtSpins += $Label; & $jtPrevSpin $Label }
${function:Confirm-ExakitJsonTablesReady} = $script:realConfirmJson
function Reset-JtCase {
    Remove-Item -Force -LiteralPath $jtReady -ErrorAction SilentlyContinue
    $script:JsonTablesBlocked = ""
    $script:db = @{}
    Remove-Item -Force (Join-Path $script:CacheDir "load-receipts.tsv") -ErrorAction SilentlyContinue
    $script:jsResult = "unset"; $script:jsErr = ""; $script:jtSpins = @()
    $script:ExakitHookMemo.Clear()   # a new command starts with nothing remembered
}

Reset-JtCase
$script:UiFancy = $true
$said = Invoke-JsonLoad
$script:UiFancy = $jtPrevFancy
Check "a JSON file with no engine: a spinner says it is installing it" "Installing the JSON engine" ($script:jtSpins -join "|")
Lacks "...and leaves no line of its own behind" "Installing add-on" $said
Lacks "...nor an installed line" "json-tables installed" $said
Has "...and then loads the file, in the same run that installed the engine" "Loaded $jsonFile into" $said
Lacks "...not refused as if the install had failed" "could not be installed" $said
Check "...the spinner is gone" $true ($null -eq $script:UiSpinFlag)
Check "...and the marketplace's detail is not left quiet" $false ([bool]$script:ExakitQuietDetail)

Reset-JtCase
$env:JT_FAIL = "1"
$script:UiFancy = $true
$said = Invoke-JsonLoad
$script:UiFancy = $jtPrevFancy
Remove-Item Env:JT_FAIL
Has "an engine that cannot install still says why, after the spinner" "json-tables did not finish: the download was refused" $said
Has "...and that the file was not loaded" "The JSON engine could not be installed" $said
Has "...and the load fails" "Could not load ga_json_test.json" $script:jsErr

Reset-JtCase
$said = Invoke-JsonLoad
Check "a plain console gets no spinner" "" ($script:jtSpins -join "|")
Has "...but is still told it is installing" "Installing add-on: json-tables" $said
Has "...and then loads the file" "Loaded $jsonFile into" $said

$script:JsonTablesBlocked = ""
${function:Get-ExakitUvBin} = $jtPrevUv
${function:Invoke-ExakitMarketplacePythonNow} = $jtPrevNow
${function:Test-ExakitAddonNeedsUpdate} = $jtPrevNeeds
${function:Get-ExakitJsonTablesBin} = $jtPrevBin
$script:ExakitHookMemo.Clear()
${function:Start-ExakitSpinner} = $jtPrevSpin
function Confirm-ExakitJsonTablesReady { return $true }
Remove-Item Env:EXAKIT_DATA_FILE, Env:EXAKIT_DATA_TABLE -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "== a file edited since this kit loaded it is named as such, and append is never the quiet answer =="
# NEW-12: the receipts match on content, so an edited file is not "already
# loaded" - and it was called "rows this kit did not load", which made append
# look safe: every unchanged row then landed twice. Twin of the section in
# bulk-folder-load.sh. The stubs of the JSON section stand in for the database.
$ed = Join-Path $work "edited"; New-Item -ItemType Directory -Force -Path $ed | Out-Null
$script:CacheDir = Join-Path $ed "cache"
$edFile = Join-Path $ed "orders.csv"
[System.IO.File]::WriteAllText($edFile, "id`n1`n2`n")
Write-ExakitLoadReceipt -Target "T.ORDERS" -File $edFile -Rows 2
Has "the receipt keeps the file's full path" ("`t" + [System.IO.Path]::GetFullPath($edFile)) (Get-Content (Get-ExakitLoadReceiptsPath) -Raw)
[System.IO.File]::WriteAllText($edFile, "id`n1`n2`n3`n")
$script:db = @{ "T.ORDERS" = 2 }
Has "an edited file is recognised as this kit's own, changed" "orders.csv|" (Get-ExakitLoadReceiptChanged "T.ORDERS" $edFile 2)
$env:EXAKIT_DATA_FILE = $edFile; $env:EXAKIT_DATA_TABLE = "T.ORDERS"
$script:jsResult = "unset"
$said = Invoke-JsonLoad
Check "an edited file is not loaded over without an answer" "declined" $script:jsResult
Has "...and says the rows are this kit's, from that file" "Not loaded: T.ORDERS holds the 2 rows this kit loaded from orders.csv on 20" $said
Has "...and that the file changed" "and the file has changed since." $said
Has "...with replace as the remedy and append named for what it does" "Load the new version with `$env:EXAKIT_ON_EXISTING = 'replace' (drop and rebuild it); 'append' would add every row again on top of the old ones." $said
Lacks "...never `"did not load`"" "did not load" $said
Check "...and nothing was sent" 0 @($script:jsLog | Where-Object { $_ -like "upload *" }).Count
# At a console: replace is offered first and is the default.
$g2Interactive = ${function:Test-ExakitInteractive}
$g2Prompt = ${function:Read-ExakitPrompt}
function Test-ExakitInteractive { return $true }
function Read-ExakitPrompt { param($Question, $Default) $script:g2Asked += "$Question|$Default"; return $Default }
$script:g2Asked = @()
$script:jsResult = "unset"
$said = Invoke-JsonLoad
Check "at a console, Enter replaces the edited file's table" "" ("" + $script:jsResult)
Has "...the question offers replace first, default r" "That table: (r)eplace it with the new version, (a)ppend (adds every row again: unchanged rows end up twice), or (s)kip|r" ($script:g2Asked -join "`n")
Has "...after saying what the table holds" "T.ORDERS holds the 2 rows this kit loaded from orders.csv on 20" $said
Has "...and the table is rebuilt" "DROP TABLE IF EXISTS T.ORDERS" ($script:jsLog -join "`n")
# The folder: when every clash is an edited file, replace is first and the default.
$edChosen = @("csv|ORDERS|$edFile")
Remove-Item -Force (Get-ExakitLoadReceiptsPath)
Write-ExakitLoadReceipt -Target "T.ORDERS" -File $edFile -Rows 2
[System.IO.File]::WriteAllText($edFile, "id`n1`n2`n3`n4`n")
$script:db = @{ "T.ORDERS" = 2 }
$edD = @(Get-ExakitBulkDecisions -Chosen $edChosen -Schema "T")
Check "a folder decision carries the edited file" "clash" $edD[0].Action
Has "...with the file it was loaded from" "orders.csv|" $edD[0].Changed
$script:g2Asked = @()
$edAns = $null
$edSaid = (& { $script:edAns = Read-ExakitBulkClashAnswer -Decisions $edD -Schema "T" } 6>&1) -join "`n"
Check "at a console, Enter replaces every edited file's table" "replace" $script:edAns
Has "...naming the rows as this kit's" "1 table in T already holding rows this kit loaded from an earlier version of the same file:" $edSaid
Has "...asked with replace first" "Those files: (r)eplace each table with the new version, (a)ppend (adds every row again: unchanged rows end up twice), or (s)kip|r" ($script:g2Asked -join "`n")
# One file, a table holding rows another file loaded: the warning speaks of
# this file, not of the kit - the kit may well have loaded those rows.
$facSaid = (& { $null = Read-ExakitFileClashAnswer -Target "STARTER_KIT.R_CSV" -Rows 4 } 6>&1) -join "`n"
Has "a single file's clash names this file" "STARTER_KIT.R_CSV already holds 4 rows that this file did not load." $facSaid
Lacks "...not the kit" "this kit did not load" $facSaid
${function:Test-ExakitInteractive} = $g2Interactive
${function:Read-ExakitPrompt} = $g2Prompt
$edSaid = (& { $script:edAns = Read-ExakitBulkClashAnswer -Decisions $edD -Schema "T" } 6>&1) -join "`n"
Check "without a console the folder skips" "skip" $script:edAns
Has "...and points at replace" "Load the new versions with `$env:EXAKIT_ON_EXISTING = 'replace'; 'append' would add every row again" $edSaid
# Another file's rows in that table are still "no load record for this file".
Remove-Item -Force (Get-ExakitLoadReceiptsPath)
$otherFile = Join-Path $ed "other.csv"; [System.IO.File]::WriteAllText($otherFile, "z`n1`n")
Write-ExakitLoadReceipt -Target "T.ORDERS" -File $otherFile -Rows 2
$script:db = @{ "T.ORDERS" = 2 }
$script:jsResult = "unset"
$said = Invoke-JsonLoad
Check "another file's rows: declined" "declined" $script:jsResult
Has "...as rows with no load record for this file" "Not loaded: T.ORDERS already holds 2 rows with no load record for this file" $said
# A receipt from before paths were kept is matched by the file's name.
[System.IO.File]::WriteAllText((Get-ExakitLoadReceiptsPath), "T.ORDERS`t3`tdeadbeef`t2`t1763500000`torders.csv`n")
Has "an older receipt (no path) is matched by name" "orders.csv|1763500000" (Get-ExakitLoadReceiptChanged "T.ORDERS" $edFile 2)
Check "...but not once the table holds other rows" "" (Get-ExakitLoadReceiptChanged "T.ORDERS" $edFile 3)
$script:db = @{}
Remove-Item Env:EXAKIT_DATA_FILE, Env:EXAKIT_DATA_TABLE -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "== an interrupted append is never resumed by dropping the table =="
# DAT-01: "resume" dropped a table an interrupted run had been APPENDING to -
# rows the kit never loaded with it - under the default "skip", exit 0. The
# crumb now says what the table held before. Twin of the bash section.
$ir = Join-Path $work "inter"; New-Item -ItemType Directory -Force -Path $ir | Out-Null
$script:CacheDir = Join-Path $ir "cache"
$irFile = Join-Path $ir "sales.csv"; [System.IO.File]::WriteAllText($irFile, "a,b`n1,2`n")
$irChosen = @("csv|SALES|$irFile")
$script:db = @{ "T.SALES" = 5050 }
Set-ExakitLoadInflight "T.SALES" 5000
$irWarn = (& { $script:irD = @(Get-ExakitBulkDecisions -Chosen $irChosen -Schema "T") } 6>&1) -join "`n"
Check "an interrupted APPEND is a clash, not a resume" "clash" $script:irD[0].Action
Has "...and says why it is left as it is" "already held 5000 rows: part of the file may be in it now" $irWarn
Set-ExakitLoadInflight "T.SALES" "absent"
Check "a table that was absent before is still resumed" "resume" (@(Get-ExakitBulkDecisions -Chosen $irChosen -Schema "T"))[0].Action
Set-ExakitLoadInflight "T.SALES" 0
Check "...and so is one that was empty" "resume" (@(Get-ExakitBulkDecisions -Chosen $irChosen -Schema "T"))[0].Action
Set-Content -LiteralPath (Get-ExakitLoadInflightPath) -Value "T.SALES"
Check "an old crumb with no 'before' is a clash" "clash" (@(Get-ExakitBulkDecisions -Chosen $irChosen -Schema "T") 6>$null)[0].Action
Clear-ExakitLoadInflight
Check "...and with no crumb it is a clash" "clash" (@(Get-ExakitBulkDecisions -Chosen $irChosen -Schema "T"))[0].Action
# The loop records the rows that were there when it appends.
$script:db = @{ "T.SALES" = 5000 }
$script:crumbSeen = ""
function Invoke-ExapumpUpload { param([string]$Path, [string]$Target, [switch]$Soft) $script:crumbSeen = Get-ExakitLoadInflight; return $true }
$env:EXAKIT_ON_EXISTING = "append"; $env:EXAKIT_SCHEMA = "T"
[void](& { Import-ExakitLocalFolder -Path $ir } 6>&1)
Remove-Item Env:EXAKIT_ON_EXISTING, Env:EXAKIT_SCHEMA
Check "an append records the 5,000 rows that were there" "T.SALES|5000" $script:crumbSeen

Write-Host ""
Write-Host "== German number formats never load as wrong numbers =="
# DAT-04, seen on a live database: exapump read Menge 1.234 / 12.500 as DOUBLE
# 1.234 / 12.5 and "Beleg Nr." 0000001237 and PLZ 01067 as 1237 and 1067, under
# a verified row count. Those columns are created as text now, from exapump's
# own dry-run schema. Twin of the section in bulk-folder-load.sh.
# The real uploader again: the sections above replaced it with stubs.
. (Join-Path $repo "setup/lib/exapump.ps1")
$script:ExakitUploadQuiet = $true
$gd = Join-Path $work "german"; New-Item -ItemType Directory -Force -Path $gd | Out-Null
$sap = Join-Path $gd "sap.csv"
[System.IO.File]::WriteAllText($sap, "Beleg Nr.;Menge;Betrag;Ort`n0000001237;1.234;1.234,56;Bonn`n4500001234;12.500;99,00;Ulm`n")
$script:colsAnswer = "EXAKIT.COLUMNS_ANSWERED|0|"
$script:gcalls = @()
function Invoke-Exapump {
    param([string[]]$ExapumpArgs)
    $line = $ExapumpArgs -join " "
    $script:gcalls += $line
    if ($line -like "sql *EXA_ALL_COLUMNS*") { return @{ Success = $true; ExitCode = 0; Output = $script:colsAnswer } }
    if ($line -like "upload *--dry-run*") {
        return @{ Success = $true; ExitCode = 0; Output = (@('Columns:', '  "Beleg Nr.": DECIMAL(36,0)', '  "Menge": DOUBLE', '  "Betrag": VARCHAR(2000000)', '  "Ort": VARCHAR(2000000)', '',
            'CREATE TABLE T.SAP (', '    "Beleg Nr." DECIMAL(36,0),', '    "Menge" DOUBLE,', '    "Betrag" VARCHAR(2000000),', '    "Ort" VARCHAR(2000000)', ');') -join "`n") }
    }
    return @{ Success = $true; ExitCode = 0; Output = "" }
}
Check "csv_guard names the columns that would load as wrong numbers" 2 @((Invoke-ExakitPythonFile -Path $script:ExakitCsvGuardScript -Arguments @("numbers", $sap, ";")).Lines).Count
$script:ExakitNumberGuard = $true
$gsaid = (& { Invoke-ExapumpUpload -Path $sap -Target "T.SAP" } 6>&1) -join "`n"
$script:ExakitNumberGuard = $false
$create = @($script:gcalls | Where-Object { $_ -like "sql *CREATE TABLE T.SAP*" })
Check "a new table is created first, from exapump's own schema" 1 $create.Count
Has "...with the leading-zero column as text" '"Beleg Nr." VARCHAR(2000000)' ($create -join "")
Has "...and the thousands-dot column as text" '"Menge" VARCHAR(2000000)' ($create -join "")
Has "...and the upload follows it" "upload" ($script:gcalls[-1])
Has "the reader is told which columns were kept as text" 'Kept as text in T.SAP' $gsaid
Has "...and why" 'leading zeros (0000001237) would be dropped' $gsaid
$script:gcalls = @()
$script:colsAnswer = "EXAKIT.COLUMNS_ANSWERED|0|`nEXAKIT_COL|1|DECIMAL(36,0)`nEXAKIT_COL|2|DOUBLE`nEXAKIT_COL|3|VARCHAR(2000000) UTF8"
$script:ExakitNumberGuard = $true
$gerr = ""
try { Invoke-ExapumpUpload -Path $sap -Target "T.SAP" 6>$null | Out-Null } catch { $gerr = "$($_.Exception.Message)" }
$script:ExakitNumberGuard = $false
Has "a table that exists with such a column as a number is refused" 'column "Menge" is DOUBLE' $gerr
Has "...with the remedy, in PowerShell's own form" "`$env:EXAKIT_ON_EXISTING = 'replace'" $gerr
Check "...and nothing is uploaded" 0 @($script:gcalls | Where-Object { $_ -like "upload *" -and $_ -notlike "*--dry-run*" }).Count
$script:gcalls = @()
$script:ExakitNumberGuard = $false
Invoke-ExapumpUpload -Path $sap -Target "T.SAP" 6>$null | Out-Null
Check "a bundled dataset's upload (no guard) is untouched" 0 @($script:gcalls | Where-Object { $_ -like "*EXA_ALL_COLUMNS*" }).Count

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "data-load-shapes-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
