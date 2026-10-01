# The Windows half of tests/skills.sh, executed rather than grepped.
#
# tests/skills.sh asserts the PowerShell skill layer with awk and grep against
# exakit-common.ps1, because there is no pwsh on the machine this kit is
# developed on. That catches a deleted line and nothing else: a logic error
# that still reads correctly passes. Every fix in this layer - the
# EXAKIT_SKILL_ROOTS override, the prune of retired skills, the add-on gate -
# therefore shipped source-verified only.
#
# This file runs the real functions on a real filesystem, under the engine
# exakit.cmd actually invokes. It is driven from .github/workflows/windows-ps51.yml.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\skills.ps1
$ErrorActionPreference = "Stop"
$pass = 0
$fail = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") {
        Write-Host "  ok   $label = $actual"
        $script:pass++
    } else {
        # ${label}, not $label: PowerShell reads "$label:" as a drive-qualified
        # variable and refuses to parse the file at all.
        Write-Host "  FAIL ${label}: expected '$expected', got '$actual'"
        $script:fail++
    }
}

$repo = Split-Path -Parent $PSScriptRoot

# Definitions only, via the AST: exakit-common.ps1 has top-level statements
# (it creates the kit's directories when sourced) and none of them may run
# here. Same technique as tests/uninstall-ps.ps1.
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "exakit-common.ps1 has parse errors" }
# TOP-LEVEL FUNCTIONS ONLY. exakit-common.ps1 declares `class
# ExakitFailException`, and on Windows PowerShell 5.1 that class's constructor
# comes back from this walk looking like a function definition. Running its
# extent as an expression is then a call to a command named
# ExakitFailException, which does not exist, and the whole suite died before
# its first check. pwsh 7 does not reproduce it, so the filter has to be here
# rather than trusted to the engine.
$fns = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Extent.Text -match '^\s*(function|filter)\s' }, $true)
# Each definition on its own, and a failure to define one is not fatal here:
# what matters is that the handful this suite exercises exist, which is
# asserted immediately below. A blanket stop would again turn one unexpected
# node into a dead suite.
foreach ($f in $fns) {
    try { Invoke-Expression $f.Extent.Text } catch { }
}
foreach ($needed in @("Get-ExakitSkillRoots", "Get-ExakitSkillField", "Copy-ExakitSkill", "Remove-ExakitSkillCopy")) {
    if (-not (Get-Command $needed -ErrorAction SilentlyContinue)) { throw "$needed not found in exakit-common.ps1" }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-skills-" + [guid]::NewGuid())
$rootA = Join-Path $sandbox "claude-skills"
$rootB = Join-Path $sandbox "agents skills"   # a space, on purpose: that is why the separator is ';'
$src   = Join-Path $sandbox "src"
New-Item -ItemType Directory -Force -Path $rootA, $rootB, $src | Out-Null

Write-Host "Get-ExakitSkillRoots:"

# 1. The override, which is the whole reason this layer is testable at all.
$env:EXAKIT_SKILL_ROOTS = "$rootA;$rootB"
$roots = @(Get-ExakitSkillRoots)
Check "the override is honoured"        "2"     "$($roots.Count)"
Check "...first root"                   $rootA  "$($roots[0])"
Check "...second root, spaces intact"   $rootB  "$($roots[1])"

# 2. Whitespace and empty segments. A trailing ';' is what a hand-edited
# environment variable looks like, and an empty root would place skills at the
# filesystem root.
$env:EXAKIT_SKILL_ROOTS = " $rootA ; ; $rootB ;"
$roots = @(Get-ExakitSkillRoots)
Check "blank segments dropped, ends trimmed" "$rootA|$rootB" ($roots -join "|")

# 3. Unset: the two discovery folders under the profile home, never $HOME.
# On a redirected home those differ, and exapump/Claude Code read the profile.
Remove-Item Env:\EXAKIT_SKILL_ROOTS -ErrorAction SilentlyContinue
function Get-ExakitProfileHome { return "C:\fake-profile" }
$roots = @(Get-ExakitSkillRoots)
Check "default root count"  "2" "$($roots.Count)"
Check "default is .claude"  "C:\fake-profile\.claude\skills" "$($roots[0])"
Check "default is .agents"  "C:\fake-profile\.agents\skills" "$($roots[1])"

Write-Host "Get-ExakitSkillField:"

# READ THE FILES THAT ACTUALLY SHIP, not a fixture. This function exists to
# parse the repo's own SKILL.md frontmatter, and the thing that breaks it on
# 5.1 is decoding: a BOM-less UTF-8 file read with the system ANSI codepage
# turns every em dash into two characters, and every description in this kit
# carries one. A synthetic file proves nothing the real ones do not.
$real = Join-Path $repo "skills\exakit-lifecycle\SKILL.md"
Check "the shipped skill file is there" "True" "$(Test-Path $real)"
Check "its name is read" "exakit-lifecycle" (Get-ExakitSkillField -Path $real -Field "name")
$desc = Get-ExakitSkillField -Path $real -Field "description"
$emdash = [string][char]0x2014
Check "the description is not empty" "True" "$($desc.Length -gt 40)"
Check "the em dash survived 5.1's decoding" "True" "$($desc.Contains($emdash))"
Check "nothing after the first colon was lost" "True" "$($desc.TrimEnd().EndsWith('.'))"
# On failure, say WHAT came back rather than only that it was wrong. The code
# points are the whole diagnosis for an encoding fault, and a mangled string
# often prints as nothing at all in a CI log. Printed only when something is
# already wrong, so a green run stays quiet.
if (-not $desc.Contains($emdash)) {
    $codes = (($desc.ToCharArray() | Select-Object -First 80 | ForEach-Object { [int]$_ }) -join ",")
    Write-Host "       description length=$($desc.Length) first-80-codepoints=$codes"
}

# A second real file, so the check is not one file's luck.
$real2 = Join-Path $repo "skills\exasol-runtime\SKILL.md"
if (Test-Path $real2) {
    Check "a second shipped skill parses too" "exasol-runtime" (Get-ExakitSkillField -Path $real2 -Field "name")
}

# The two not-found paths, which need no fixture content at all.
Check "a missing field is empty, not an error" "" (Get-ExakitSkillField -Path $real -Field "nosuch")
Check "a missing file is empty, not an error"  "" (Get-ExakitSkillField -Path (Join-Path $src "gone\SKILL.md") -Field "name")

# A minimal skill to place and retire below. ASCII only: what is being tested
# from here on is file movement, not decoding.
$one = Join-Path $src "demo-skill"
New-Item -ItemType Directory -Force -Path $one | Out-Null
Set-Content -Path (Join-Path $one "SKILL.md") -Value "---`nname: demo-skill`n---" -Encoding Ascii

Write-Host "Copy-ExakitSkill / Remove-ExakitSkillCopy:"

$env:EXAKIT_SKILL_ROOTS = "$rootA;$rootB"
Copy-ExakitSkill -Source $one -Name "demo-skill"
Check "placed in root A" "True" "$(Test-Path (Join-Path $rootA 'demo-skill\SKILL.md'))"
Check "placed in root B" "True" "$(Test-Path (Join-Path $rootB 'demo-skill\SKILL.md'))"

# A skill the user placed themselves. The kit removes only what it recorded,
# so this one has to survive every operation below.
$mine = Join-Path $rootA "my-own-skill"
New-Item -ItemType Directory -Force -Path $mine | Out-Null
Set-Content -Path (Join-Path $mine "SKILL.md") -Value "---`nname: my-own-skill`n---" -Encoding Ascii

# Re-placing must replace, not merge: a file the new version dropped cannot
# survive the copy.
Set-Content -Path (Join-Path $rootA "demo-skill\stale.md") -Value "old" -Encoding Ascii
Copy-ExakitSkill -Source $one -Name "demo-skill"
Check "a re-place drops a file the new version does not carry" "False" `
    "$(Test-Path (Join-Path $rootA 'demo-skill\stale.md'))"

Remove-ExakitSkillCopy -Name "demo-skill"
Check "retired from root A" "False" "$(Test-Path (Join-Path $rootA 'demo-skill'))"
Check "retired from root B" "False" "$(Test-Path (Join-Path $rootB 'demo-skill'))"
Check "the user's own skill is untouched" "True" "$(Test-Path (Join-Path $mine 'SKILL.md'))"

# Removing something that was never there is not an error: uninstall runs it
# for every recorded name, and a machine that lost one by hand must not stop.
Remove-ExakitSkillCopy -Name "never-existed"
Check "removing an absent skill is a no-op" "True" "True"

Remove-Item Env:\EXAKIT_SKILL_ROOTS -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "skills (ps): $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
