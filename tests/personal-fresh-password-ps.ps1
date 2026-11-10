# personal-fresh-password-ps.ps1 - a replaced database is a new database: the
# exapump profile and the MCP read-only user are rebuilt, never skipped as
# "already done". Twin of tests/personal-fresh-password.sh for
# setup/lib/exapump.ps1, exakit-common.ps1 and runtime-personal.ps1.
#
#   pwsh -NoProfile -File tests/personal-fresh-password-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/personal-fresh-password-ps.ps1
#
# A temp EXAKIT_HOME and a temp profile; no database, no launcher.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected [$expected], got [$actual]" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains($needle)) { Check $label "present" "present" } else { Check $label "present" "MISSING ($haystack)" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-fresh-pw-ps-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "no-deployment"
New-Item -ItemType Directory -Force -Path $env:EXAKIT_HOME | Out-Null
Set-Content -Path (Join-Path $env:EXAKIT_HOME "manifest.json") -Encoding Ascii -Value '{"manifest_version": 1}'
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")
function Info([string]$Msg) { $script:lastInfo = $Msg }
function Ok([string]$Msg) { $script:lastOk = $Msg }

$script:ExapumpConfigPath = Join-Path $work "config.toml"
$cred = Join-Path $work "personal_sys_password"
$binary = Join-Path $work "exapump.exe"
Set-Content -Path $binary -Encoding Ascii -Value "not empty"
Set-ExakitManifestValue "components.exapump.path" $binary
Set-ExakitManifestValue "runtime.password_file" $cred
function Cred([string]$value) { [System.IO.File]::WriteAllText($cred, $value + "`n") }
function Profile([string]$password) {
    Set-Content -Path $script:ExapumpConfigPath -Encoding Ascii -Value @('[other]', 'host = "db.example"', 'password = "unrelated"', '')
    Set-ExapumpTomlSection -ConfigPath $script:ExapumpConfigPath -Profile $script:ExapumpProfile -Host_ "127.0.0.1" -Port "8563" -User "sys" -Password $password
}
function Stale { return ("" + (Test-ExapumpProfilePasswordStale)) }
function State { $script:ExakitStepRerunReason = ""; return (Get-ExakitStepArtifactState "exapump") }

Write-Host "Test-ExapumpProfilePasswordStale: the profile against the credential file"
Remove-Item $script:ExapumpConfigPath -ErrorAction SilentlyContinue
Cred "alpha"
Check "no profile -> not stale"                 "False" (Stale)
Profile "alpha"
Check "same password -> not stale"              "False" (Stale)
Cred "beta16characters"
Check "new password on file -> stale"           "True" (Stale)
Cred 'p"w\d'
Profile 'p"w\d'
Check "escaped quote and backslash round-trip"  "False" (Stale)
Check "  profile holds the escaped form"        "True" ((Get-Content $script:ExapumpConfigPath -Raw).Contains('password = "p\"w\\d"'))
Check "case matters"                            "True" ((Cred "P`"w\d"), (Stale))[1]
Cred ""
Check "empty credential file -> not stale"      "False" (Stale)
Cred "alpha"; Profile "alpha"
Set-ExakitManifestValue "runtime.password_file" ""
Check "no password_file recorded -> not stale"  "False" (Stale)
Set-ExakitManifestValue "runtime.password_file" $cred
Set-Content -Path $script:ExapumpConfigPath -Encoding Ascii -Value @('[starter-kit]', 'host = "127.0.0.1"')
Check "profile without a password line"        "False" (Stale)

Write-Host ""
Write-Host "Get-ExakitStepArtifactState exapump: a stale profile re-runs the step, with its reason"
Cred "alpha"; Profile "alpha"
Check "binary + matching profile -> present"    "present" (State)
Cred "beta"
Check "binary + stale profile -> missing"       "missing" (State)
Has   "  and says why"                          "no longer accepts" $script:ExakitStepRerunReason
Profile "beta"
Check "profile rewritten -> present again"      "present" (State)
Set-Content -Path $binary -Encoding Ascii -Value $null
Check "0-byte binary -> missing (as before)"    "missing" (State)
Check "  with no special reason"                "" $script:ExakitStepRerunReason
Set-Content -Path $binary -Encoding Ascii -Value "not empty"

Write-Host ""
Write-Host "Begin-ExakitStep names the reason"
Set-ExakitStepDone "exapump"
Cred "gamma"
$script:lastInfo = ""
Check "stale profile -> the step runs"          "True" (Begin-ExakitStep "exapump" "Step 3/6  exapump")
Has   "  and the line says why"                 "the exapump connection profile holds a password the database no longer accepts" $script:lastInfo
Profile "gamma"
$script:lastOk = ""
Check "matching profile -> skipped"             "False" (Begin-ExakitStep "exapump" "Step 3/6  exapump")
Has   "  as already done"                       "already done, skipping" $script:lastOk

Write-Host ""
Write-Host "Clear-PersonalDatabaseSteps: exapump and mcp, nothing else"
foreach ($s in @("launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper")) { Set-ExakitStepDone $s }
Clear-PersonalDatabaseSteps
$left = @(Get-ExakitManifestValue "steps_completed")
Check "steps left"                              "launcher runtime pyexasol exakit_helper" ($left -join " ")
Check "exapump no longer done"                  "False" ("" + (Test-ExakitStepDone "exapump"))
Check "mcp no longer done"                      "False" ("" + (Test-ExakitStepDone "mcp"))
Clear-PersonalDatabaseSteps
Check "idempotent"                              "launcher runtime pyexasol exakit_helper" (@(Get-ExakitManifestValue "steps_completed") -join " ")

Write-Host ""
Write-Host "Update-PersonalChangedPassword: the records follow a password that changed on update"
$script:profileCalls = 0
function New-ExapumpProfile { $script:profileCalls++ }
function Test-ExapumpProfilePasswordStale { return $false }
function Warn2([string]$Msg) { $script:lastWarn = $Msg }
Set-ExakitCredential "personal_sys_password" "alpha"
$script:lastInfo = ""; $script:lastWarn = ""
Check "nothing on file before -> unknown"       "unknown" ("" + (Update-PersonalChangedPassword ""))
Check "same password -> same"                   "same" ("" + (Update-PersonalChangedPassword "alpha"))
Check "  nothing rewritten, nothing said"       "0||" ("$($script:profileCalls)|$($script:lastInfo)|$($script:lastWarn)")
# Set-ExakitCredential refuses an empty value, so the file is emptied by hand.
[System.IO.File]::WriteAllText((Join-Path $script:CredsDir "personal_sys_password"), "")
Check "nothing on file after -> unknown"        "unknown" ("" + (Update-PersonalChangedPassword "alpha"))
Set-ExakitCredential "personal_sys_password" "beta16characters"
Check "new password -> changed"                 "changed" ("" + (Update-PersonalChangedPassword "alpha"))
Check "  profile rewritten"                     1 $script:profileCalls
Has   "  and said"                              "password changed with this update" $script:lastInfo
Has   "  claiming the profile"                  "now hold the new one" $script:lastInfo
Has   "  naming what keeps working"             "mcp_readonly" $script:lastInfo
Check "  never prints a password"               "False" ("" + $script:lastInfo.Contains("beta16characters"))
Check "  no warning"                            "" $script:lastWarn
$script:lastInfo = ""
function Test-ExapumpProfilePasswordStale { return $true }
Check "profile still stale after rewrite -> changed" "changed" ("" + (Update-PersonalChangedPassword "alpha"))
Check "  not claimed as written"                "" $script:lastInfo
Has   "  warned instead"                        "could not be rewritten" $script:lastWarn
Has   "  naming the manual step"                "exapump profile init" $script:lastWarn
function New-ExapumpProfile { throw "boom" }
$script:lastWarn = ""
Check "rewrite throws -> changed, warned"       "changed" ("" + (Update-PersonalChangedPassword "alpha"))
Has   "  as a warning"                          "could not be rewritten" $script:lastWarn
Check "case matters"                            "changed" ("" + (Update-PersonalChangedPassword "BETA16characters"))

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -ne 0) { exit 1 }
exit 0
