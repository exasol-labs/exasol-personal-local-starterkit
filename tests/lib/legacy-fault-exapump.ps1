# legacy-fault-exapump.ps1 - the PowerShell twin of legacy-fault-exapump.sh.
#
# Same contract, same control files, same log (exapump.calls): an exapump
# whose database fails on request. Driven by tests/legacy-crossing-ps.ps1
# through a thin wrapper, so the PowerShell module meets one stub on every
# host. See the .sh twin for what each control file means.
$dir = $env:EXAKIT_FAULT_DIR
if (-not $dir) { [Console]::Error.WriteLine("EXAKIT_FAULT_DIR must point at the scenario's control directory"); exit 2 }
function Read-Knob([string]$Name, [string]$Default) {
    $p = Join-Path $dir $Name
    if (Test-Path $p) { return (Get-Content $p -Raw) }
    return $Default
}
function Test-Listed([string]$Name, [string]$Value) {
    $p = Join-Path $dir $Name
    if (-not (Test-Path $p)) { return $false }
    foreach ($line in (Get-Content $p)) { if ($line -eq $Value) { return $true } }
    return $false
}
# WHAT THIS STUB IS HANDED, ON WINDOWS. The kit escapes a double quote as \"
# before it calls a native program, because the PowerShell 5.1 command-line
# rules drop an unescaped one (see ConvertTo-ExakitNativeArgs). A real exapump
# is a native program and its parser turns \" back into ". This stub is
# reached through a .cmd wrapper and a second powershell, which need not undo
# the escape, so it undoes the escape itself - and then everything below, the
# log included, reads the same on every host. A MISSING quote still arrives
# missing, which is the fault worth catching: the sh twin needs none of this,
# because a shell hands its argv over untouched.
$argv = @()
foreach ($a in $args) { $argv += ("$a" -replace '\\"', '"') }

Add-Content -Path (Join-Path $dir "exapump.calls") -Value ($argv -join " ")

$rest = @($argv)
$sub = "" + $rest[0]; $rest = $rest[1..($rest.Count - 1)]
# Every subcommand takes -p <profile> first; keep it in the log, drop it here.
if ($rest.Count -ge 2 -and $rest[0] -eq "-p") { $rest = @($rest[2..($rest.Count - 1)]) }

switch ($sub) {
    "sql" {
        $sql = ($rest -join " ")
        if ($sql -match "EXAKIT_NEW_OK") {
            if ((Read-Knob "newdb.answers" "yes").Trim() -ne "no") { Write-Output "EXAKIT_NEW_OK" }
            exit 0
        }
        if ($sql -match "EXAKIT_LEGACY_OK") {
            $n = [int](Read-Knob "probe.count" "0") + 1
            Set-Content -Path (Join-Path $dir "probe.count") -Value "$n" -NoNewline
            $after = (Read-Knob "db.answer_after" "1").Trim()
            if ($after -ne "never" -and $n -ge [int]$after) { Write-Output "EXAKIT_LEGACY_OK" }
            exit 0
        }
        # The row-count query names EXA_ALL_TABLES too, so it is told apart by
        # its own sentinel, and BEFORE the table listing.
        if ($sql -match "EXAKIT_LR") {
            $p = Join-Path $dir "db.rows"
            if (Test-Path $p) {
                foreach ($line in (Get-Content $p)) {
                    if ($line -match '^([^|]+)\|(.*)$') { Write-Output ("EXAKIT_LR[" + $Matches[1] + "<<:>>" + $Matches[2] + "]") }
                }
            }
            exit 0
        }
        if ($sql -match "EXA_ALL_TABLES") {
            $p = Join-Path $dir "db.tables"
            if (Test-Path $p) { foreach ($t in (Get-Content $p)) { if ($t) { Write-Output "EXAKIT_LT[$t]" } } }
            exit 0
        }
        if ($sql -match "EXA_ALL_COLUMNS") {
            $s = ""; $t = ""
            if ($sql -match "COLUMN_SCHEMA = '([^']*)'") { $s = $Matches[1] }
            if ($sql -match "COLUMN_TABLE = '([^']*)'")  { $t = $Matches[1] }
            $p = Join-Path $dir "db.columns"
            if (Test-Path $p) {
                foreach ($line in (Get-Content $p)) {
                    if ($line.StartsWith("$s.$t|")) { Write-Output ("EXAKIT_LC[" + $line.Substring("$s.$t|".Length) + "]") }
                }
            }
            exit 0
        }
        if ($sql -match "CREATE SCHEMA") { exit ([int](Read-Knob "import.schema_rc" "0").Trim()) }
        if ($sql -match 'CREATE TABLE "([^"]*)"\."([^"]*)"') {
            if (Test-Listed "import.exists" ($Matches[1] + "." + $Matches[2])) { exit 1 }
            exit 0
        }
        exit 0
    }
    "export" {
        $table = ""; $out = ""
        for ($i = 0; $i -lt $rest.Count; $i++) {
            if ($rest[$i] -eq "--table") { $table = $rest[$i + 1] }
            # The crossing names the table as a quoted query; the fault lists say S.T.
            if ($rest[$i] -eq "--query" -and "$($rest[$i + 1])" -match 'FROM "([^"]*)"\."([^"]*)"') { $table = $Matches[1] + "." + $Matches[2] }
            if ($rest[$i] -eq "-o")      { $out = $rest[$i + 1] }
        }
        # The file is created BEFORE the query is known to work - the real
        # exapump does this, and it is why a failed export leaves a 0-byte file.
        if ($out) { Set-Content -Path $out -Value "" -NoNewline }
        if (Test-Listed "export.fail" $table) { exit 1 }
        if ($out) { Set-Content -Path $out -Value (Read-Knob "export.rows" "A,B`n1,2") -NoNewline }
        exit 0
    }
    "upload" {
        $table = ""
        for ($i = 0; $i -lt $rest.Count; $i++) { if ($rest[$i] -eq "--table") { $table = $rest[$i + 1] } }
        # The crossing hands the target as "S"."T"; the fault lists say S.T.
        if (Test-Listed "upload.fail" ($table -replace '"', '')) { exit 1 }
        exit 0
    }
}
exit 0
