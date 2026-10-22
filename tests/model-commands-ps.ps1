#!/usr/bin/env pwsh
# model-commands-ps.ps1 - the Windows twin of tests/model-commands.sh:
# `exakit model put | list | template` in setup/lib/udf-devkit.ps1. Runs under
# Windows PowerShell 5.1 and pwsh; a sandboxed kit home and deployment folder,
# the exits stubbed so each refusal is read as its code; no database.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-model-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/help.ps1")
. (Join-Path $repo "setup/lib/udf-devkit.ps1")
$script:LogFile = $null
$script:PersonalDeployDir = Join-Path $work "deployment"
New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path (Join-Path $script:PersonalDeployDir "local") "runtime") "exa") | Out-Null
$bucket = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $script:PersonalDeployDir "local") "runtime") "exa") "bucketfs") "bfsdefault") "default"
$models = Join-Path $bucket "models"
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Contains($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
}
function Lacks($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> found in <$haystack>" }
    else { $script:PASS++; Write-Host "  ok   $label" }
}
# Every way out, stubbed to throw its exit code so the test reads it.
function Fail([string]$Msg) { throw "EXIT 1: $Msg" }
function Deny-ExakitInput { param([string]$Message, $Remedy = $null) throw "EXIT 2: $Message" }
function Exit-UdfModel { param([int]$Code, [string]$Message, $Remedy = $null) throw "EXIT $($Code): $Message | $Remedy" }
function Invoke-Refused([scriptblock]$Action) {
    try { & $Action | Out-Null; return "EXIT 0" } catch { return "$_" }
}
function Get-Record {
    $doc = Get-Content -Raw $script:ManifestPath | ConvertFrom-Json
    return $doc.components.udf_devkit.models
}
function Get-Sha([string]$Path) { return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant() }

try {
    Initialize-ExakitManifest | Out-Null
    $secret = "not-a-real-password-7731"
    $pwFile = Join-Path $work "db-password"
    Set-Content -Path $pwFile -Value $secret -NoNewline
    Set-ExakitManifestValue "runtime.password_file" $pwFile
    Set-ExakitManifestValue "components.udf_devkit.version" "0.1.0"
    $v1 = Join-Path $work "churn.pkl"
    Set-Content -Path $v1 -Value "weights-v1" -NoNewline
    New-Item -ItemType Directory -Force -Path (Join-Path $work "v2") | Out-Null
    $v2 = Join-Path (Join-Path $work "v2") "churn.pkl"
    Set-Content -Path $v2 -Value "weights-v2-longer" -NoNewline

    Write-Host "list works before anything is put:"
    $doc = (Invoke-CmdModelList -CmdArgs @("--json")) | ConvertFrom-Json
    Check "the keys the quickstart notebook reads" "bucket_dir missing models udf_root" (($doc.PSObject.Properties.Name | Sort-Object) -join " ")
    Check "an empty models list" "0" @($doc.models).Count
    Check "the UDF root" "/buckets/bfsdefault/default" $doc.udf_root
    Check "the bucket directory on this machine" (Get-Item $script:PersonalDeployDir).FullName ($doc.bucket_dir -replace "[\\/]local[\\/]runtime[\\/]exa[\\/]bucketfs[\\/]bfsdefault[\\/]default$", "")

    Write-Host "put copies, records and prints the /buckets path:"
    $answer = (Invoke-CmdModelPut -CmdArgs @($v1, "--json")) | ConvertFrom-Json
    Check "the file is in the bucket under models/" "weights-v1" (Get-Content -Raw (Join-Path $models "churn.pkl"))
    Check "the UDF path" "/buckets/bfsdefault/default/models/churn.pkl" $answer.path
    Check "--json is exactly name, path, sha256, size, replaced" "name path replaced sha256 size" (($answer.PSObject.Properties.Name | Sort-Object) -join " ")
    $sha1 = Get-Sha $v1
    Check "the digest" $sha1 $answer.sha256
    Check "the digest is recorded" $sha1 (Get-Record).'churn.pkl'.sha256
    Check "with the size, the path and the time" "path put_at sha256 size" (((Get-Record).'churn.pkl'.PSObject.Properties.Name | Sort-Object) -join " ")

    Write-Host "the same file again changes nothing:"
    $putAt = (Get-Record).'churn.pkl'.put_at
    $again = (Invoke-CmdModelPut -CmdArgs @($v1, "--json")) | ConvertFrom-Json
    Check "not replaced" "False" $again.replaced
    Check "the record keeps its time" $putAt (Get-Record).'churn.pkl'.put_at

    Write-Host "a different file of the same name is refused without --replace:"
    $said = Invoke-Refused { Invoke-CmdModelPut -CmdArgs @($v2) }
    Contains "exit 5 (not confirmed)" "EXIT 5:" $said
    Contains "the remedy is --replace" "--replace" $said
    Check "nothing was copied" "weights-v1" (Get-Content -Raw (Join-Path $models "churn.pkl"))
    Check "the record is unchanged" $sha1 (Get-Record).'churn.pkl'.sha256

    Write-Host "--replace overwrites it and says so:"
    $replaced = (Invoke-CmdModelPut -CmdArgs @($v2, "--replace", "--json")) | ConvertFrom-Json
    Check "replaced" "True" $replaced.replaced
    Check "the new content is there" "weights-v2-longer" (Get-Content -Raw (Join-Path $models "churn.pkl"))
    Check "the record follows" (Get-Sha $v2) (Get-Record).'churn.pkl'.sha256
    Check "and the size" "17" $replaced.size

    Write-Host "list flags a file changed since it was put:"
    Set-Content -Path (Join-Path $models "churn.pkl") -Value "tampered" -NoNewline
    Set-Content -Path (Join-Path $models "lookup.csv") -Value "csv" -NoNewline
    $doc = (Invoke-CmdModelList -CmdArgs @("--json")) | ConvertFrom-Json
    $byName = @{}
    foreach ($m in @($doc.models)) { $byName[$m.name] = $m }
    Check "the tampered file is flagged" "changed" $byName["churn.pkl"].status
    Check "a file copied another way is unrecorded" "unrecorded" $byName["lookup.csv"].status
    Check "its path is the /buckets path" "/buckets/bfsdefault/default/models/lookup.csv" $byName["lookup.csv"].path
    Remove-Item -Force (Join-Path $models "churn.pkl")
    $doc = (Invoke-CmdModelList -CmdArgs @("--json")) | ConvertFrom-Json
    Check "a recorded file that is gone is named missing" "churn.pkl" (@($doc.missing) -join " ")

    Write-Host "bad input exits 2 and copies nothing:"
    Contains "no file" "EXIT 2:" (Invoke-Refused { Invoke-CmdModelPut -CmdArgs @() })
    Contains "not a file" "EXIT 2:" (Invoke-Refused { Invoke-CmdModelPut -CmdArgs @((Join-Path $work "nope.pkl")) })
    Contains "an unknown option" "EXIT 2:" (Invoke-Refused { Invoke-CmdModelPut -CmdArgs @($v1, "--force") })
    $spaced = Join-Path $work "my model.pkl"
    Set-Content -Path $spaced -Value "x" -NoNewline
    $said = Invoke-Refused { Invoke-CmdModelPut -CmdArgs @($spaced) }
    Contains "a name the bucket path cannot hold" "EXIT 2:" $said
    Contains "with the reason" "cannot be a model name" $said
    Contains "an unknown model command" "EXIT 2:" (Invoke-Refused { Invoke-CmdModel -CmdArgs @("frob") })
    Contains "no model command" "EXIT 2:" (Invoke-Refused { Invoke-CmdModel -CmdArgs @() })
    Contains "list refuses an unknown option" "EXIT 2:" (Invoke-Refused { Invoke-CmdModelList -CmdArgs @("--frob") })

    Write-Host "no deployment is exit 3, no add-on exit 4:"
    $realDeploy = $script:PersonalDeployDir
    $script:PersonalDeployDir = Join-Path $work "none"
    $said = Invoke-Refused { Invoke-CmdModelList -CmdArgs @("--json") }
    Contains "no deployment: exit 3" "EXIT 3:" $said
    Contains "naming the folder it looked for" "no BucketFS folder" $said
    $script:PersonalDeployDir = $realDeploy
    Remove-ExakitManifestValue "components.udf_devkit.version"
    $said = Invoke-Refused { Invoke-CmdModelPut -CmdArgs @($v1) }
    Contains "not installed: exit 4" "EXIT 4:" $said
    Contains "naming the marketplace" "exakit marketplace udf-devkit" $said
    Check "nothing written by a refused put" "lookup.csv" (@(Get-ChildItem -Name $models) -join " ")
    Set-ExakitManifestValue "components.udf_devkit.version" "0.1.0"

    Write-Host "no credential is read, printed or recorded:"
    $all = (@(Invoke-CmdModelPut -CmdArgs @($v1, "--replace", "--json")) + @(Invoke-CmdModelList -CmdArgs @("--json")) + @(Invoke-CmdModelPut -CmdArgs @($v1, "--json"))) -join "`n"
    Lacks "the password is never printed" $secret $all
    Lacks "nor the password file's path" "db-password" $all
    $recordText = (Get-Record) | ConvertTo-Json -Depth 6 -Compress
    Lacks "nor the record" $secret $recordText
    Lacks "the record holds no password file" "password" $recordText

    Write-Host "the template:"
    $tpl = (Invoke-CmdModelTemplate -CmdArgs @("--json")) | ConvertFrom-Json
    Check "names the renderer, which exists" "True" (Test-Path $tpl.renderer -PathType Leaf)
    Check "and every placeholder" "LANGUAGE SCHEMA SCRIPT_NAME INPUT_COLUMNS OUTPUT_TYPE MODEL_PATH INPUTS METHOD" (@($tpl.placeholders) -join " ")

    Write-Host "through the real CLI, the exit codes are the kit's:"
    $shell = (Get-Process -Id $PID).Path
    $cli = Join-Path (Join-Path $repo "setup") "exakit.ps1"
    $env:EXAKIT_PERSONAL_DEPLOY_DIR = $script:PersonalDeployDir
    $env:EXAKIT_HELP_PLAIN = "1"
    # @(exit code, output) of one CLI run, stderr folded in under a Continue
    # window (5.1 would otherwise turn a stderr line into a terminating error).
    function Invoke-Cli {
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $text = (& $shell -NoProfile -File $cli @args 2>&1 | ForEach-Object { "$_" }) -join "`n"
            return ,@($LASTEXITCODE, $text)
        } finally { $ErrorActionPreference = $prevEap }
    }
    try {
        $run = Invoke-Cli model put $v1 --json
        Check "put --json: exit 0" "0" $run[0]
        Check "and one object on stdout" "churn.pkl" (($run[1] | ConvertFrom-Json).name)
        $run = Invoke-Cli model put $v2 --json
        Check "a different file: exit 5" "5" $run[0]
        Check "with one refusal object" "False" (($run[1] | ConvertFrom-Json).ok)
        $run = Invoke-Cli model list --json
        Check "list --json: exit 0" "0" $run[0]
        Check "with the UDF root" "/buckets/bfsdefault/default" (($run[1] | ConvertFrom-Json).udf_root)
        Check "an unknown model command: exit 2" "2" (Invoke-Cli model frob)[0]
        Contains "model --help shows the pages" "exakit model template" (Invoke-Cli model --help)[1]
        $env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "none"
        Check "no deployment: exit 3" "3" (Invoke-Cli model list --json)[0]
    } finally {
        Remove-Item Env:\EXAKIT_PERSONAL_DEPLOY_DIR -ErrorAction SilentlyContinue
    }

    Write-Host "udf-file and model share the bucket helper:"
    $source = Get-Content -Raw (Join-Path $repo "setup/lib/udf-devkit.ps1")
    Check "one resolver, used by udf-file and the model commands" "2" ([regex]::Matches($source, "= Get-UdfBucketLocation").Count)
    Check "and no other code joins the bucket's path" "1" ([regex]::Matches($source, "Join-Path \(Join-Path \`$root \`$script:UdfBucketfsService\)").Count)
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "model-commands-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
