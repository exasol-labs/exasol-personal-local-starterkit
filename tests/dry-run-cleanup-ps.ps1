# dry-run-cleanup-ps.ps1 - a dry run of install.ps1 must not fill the disk.
# Twin of tests/dry-run-cleanup.sh. install.ps1 refuses to run off Windows, so
# its two helpers are loaded from the file itself and exercised directly:
#   Copy-ExakitLocalKit     - only the kit's files from a local checkout
#   Remove-ExakitOldDryRuns - earlier dry-run folders go after 10 minutes
#
#   pwsh -NoProfile -File tests/dry-run-cleanup-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:Pass = 0; $script:FailCount = 0
function Check([string]$Name, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host "  ok   $Name" }
    else { $script:FailCount++; Write-Host "  FAIL $Name : expected [$Expected], got [$Actual]" }
}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "install.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "install.ps1 does not parse: $($errors[0].Message)" }
$wanted = @("Copy-ExakitLocalKit", "Remove-ExakitOldDryRuns")
$defs = @($ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($wanted -contains $n.Name) }, $true))
Check "both helpers are defined in install.ps1" 2 $defs.Count
foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-dryrun-ps-test-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    function New-Tree([string]$Root, [string[]]$Files) {
        foreach ($f in $Files) {
            $p = Join-Path $Root $f
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
            Set-Content -LiteralPath $p -Value "x" -Encoding ASCII
        }
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        Write-Host "a local git checkout: the kit's files only"
        $src = Join-Path $work "src"
        New-Tree $src @("setup/exakit", "setup/lib/common.sh", "CHANGELOG.md", ".gitignore")
        Set-Content -LiteralPath (Join-Path $src ".gitignore") -Value "__pycache__/" -Encoding ASCII
        & $git.Source -C $src init -q | Out-Null
        & $git.Source -C $src add -A | Out-Null
        & $git.Source -C $src -c user.name=t -c user.email=t@example.invalid commit -q -m kit | Out-Null
        New-Tree $src @(".claude/worktrees/agent-1/blob", "setup/lib/__pycache__/c.pyc", "NEW-UNTRACKED.md")
        Remove-Item -LiteralPath (Join-Path $src "CHANGELOG.md")
        $dest = Join-Path $work "dest-git"; New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-ExakitLocalKit -Source $src -Destination $dest
        Check "a tracked file is copied" $true (Test-Path (Join-Path $dest "setup/exakit"))
        Check "a new file git does not ignore is copied" $true (Test-Path (Join-Path $dest "NEW-UNTRACKED.md"))
        Check "a tracked file deleted in the work tree is skipped" $false (Test-Path (Join-Path $dest "CHANGELOG.md"))
        Check ".git is not copied" $false (Test-Path (Join-Path $dest ".git"))
        Check "agent worktrees under .claude are not copied, even when .gitignore does not name them" $false (Test-Path (Join-Path $dest ".claude"))
        Check "an ignored cache is not copied" $false (Test-Path (Join-Path $dest "setup/lib/__pycache__"))
    } else {
        Write-Host "  SKIP the git checkout cases - no git on this machine"
    }

    Write-Host "a folder that is not a git checkout: everything but the checkout-only folders"
    $plain = Join-Path $work "plain"
    New-Tree $plain @("setup/exakit", ".git/HEAD", ".claude/worktrees/blob", "setup/lib/__pycache__/c.pyc", "node_modules/m/index.js")
    $dest = Join-Path $work "dest-plain"; New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-ExakitLocalKit -Source $plain -Destination $dest
    Check "the kit is copied" $true (Test-Path (Join-Path $dest "setup/exakit"))
    Check ".git is not copied" $false (Test-Path (Join-Path $dest ".git"))
    Check ".claude is not copied" $false (Test-Path (Join-Path $dest ".claude"))
    Check "a nested __pycache__ is not copied" $false (Test-Path (Join-Path $dest "setup/lib/__pycache__"))
    Check "node_modules is not copied" $false (Test-Path (Join-Path $dest "node_modules"))

    Write-Host "earlier dry runs are removed once they are 10 minutes old"
    $temp = Join-Path $work "temp"
    foreach ($n in @("exakit-dry-run-old1", "exakit-dry-run-old2", "exakit-dry-run-recent", "unrelated-folder")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $temp $n) | Out-Null
    }
    foreach ($n in @("exakit-dry-run-old1", "exakit-dry-run-old2", "unrelated-folder")) {
        (Get-Item -LiteralPath (Join-Path $temp $n)).LastWriteTime = (Get-Date).AddHours(-1)
    }
    Remove-ExakitOldDryRuns -TempPath $temp
    Check "an hour-old dry-run folder is removed" $false (Test-Path (Join-Path $temp "exakit-dry-run-old1"))
    Check "...every one of them" $false (Test-Path (Join-Path $temp "exakit-dry-run-old2"))
    Check "a dry run from the last 10 minutes is kept" $true (Test-Path (Join-Path $temp "exakit-dry-run-recent"))
    Check "a folder that is not a dry run is never touched" $true (Test-Path (Join-Path $temp "unrelated-folder"))

    Write-Host "the installer uses them"
    $text = [System.IO.File]::ReadAllText((Join-Path $repo "install.ps1"))
    Check "a dry run sweeps before it stages" $true ($text -match 'if \(\$env:EXAKIT_DRY_RUN -eq "1"\) \{\s+Remove-ExakitOldDryRuns')
    Check "a local checkout is copied through the helper" $true ($text -match 'Copy-ExakitLocalKit -Source \$LocalKit -Destination \$localDest')
    Check "no whole-folder copy of the checkout is left" $false ($text -match 'Copy-Item -Path \(Join-Path \$LocalKit "\*"\)')
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "dry-run-cleanup-ps: $($script:Pass) passed, $($script:FailCount) failed"
if ($script:FailCount -gt 0) { exit 1 }
