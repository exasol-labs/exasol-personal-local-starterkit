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
# Inside the sandbox, not "C:\fake-profile": on macOS/Linux pwsh there is no C:
# drive, Join-Path refuses it, and the suite stopped here after four checks.
# The expected paths spell the platform's own separator, so on Windows this is
# still "<profile>\.claude\skills", byte for byte.
$script:fakeProfile = Join-Path $sandbox "fake-profile"
function Get-ExakitProfileHome { return $script:fakeProfile }
$sep = [System.IO.Path]::DirectorySeparatorChar
$roots = @(Get-ExakitSkillRoots)
Check "default root count"  "2" "$($roots.Count)"
Check "default is .claude"  "$fakeProfile$sep.claude${sep}skills" "$($roots[0])"
Check "default is .agents"  "$fakeProfile$sep.agents${sep}skills" "$($roots[1])"

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

# The kit's state, stubbed: the skill set is $src, its version 9.9.9, and the
# manifest holds what each case below sets in $script:fakeManifest.
$script:fakeManifest = @{ "components.skills.marked" = $true; "components.skills.installed" = @() }
function Get-ExakitManifestValue { param([string]$Path) return $script:fakeManifest[$Path] }
function Get-ExakitSkillsDir { return $script:src }
function Get-ExakitSkillsLocalVersion { return "9.9.9" }
function Get-ExakitSkillGatingAddon { param([string]$Id) if ($Id -eq "gated-skill") { return "some-addon" } return "" }
$script:warned = @()
function Warn2([string]$Msg) { $script:warned += $Msg }
$script:src = $src

$env:EXAKIT_SKILL_ROOTS = "$rootA;$rootB"
$script:ExakitSkillsRecordedMemo = $null
[void](Copy-ExakitSkill -Source $one -Name "demo-skill")
Check "placed in root A" "True" "$(Test-Path (Join-Path $rootA 'demo-skill\SKILL.md'))"
Check "placed in root B" "True" "$(Test-Path (Join-Path $rootB 'demo-skill\SKILL.md'))"
Check "...and marked with the skill-set version" "9.9.9" ("" + (Get-Content (Join-Path $rootA 'demo-skill\.exakit-owned') -TotalCount 1))

# A skill the user placed themselves. The kit removes only what it recorded,
# so this one has to survive every operation below.
$mine = Join-Path $rootA "my-own-skill"
New-Item -ItemType Directory -Force -Path $mine | Out-Null
Set-Content -Path (Join-Path $mine "SKILL.md") -Value "---`nname: my-own-skill`n---" -Encoding Ascii

# Re-placing must replace, not merge: a file the new version dropped cannot
# survive the copy.
Set-Content -Path (Join-Path $rootA "demo-skill\stale.md") -Value "old" -Encoding Ascii
[void](Copy-ExakitSkill -Source $one -Name "demo-skill")
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

Write-Host "a folder of a kit skill's name the user keeps is theirs (MCP-03):"
# The kit replaced any folder named like one of its skills and the uninstall
# deleted it. Only a folder carrying the mark is the kit's now.
$two = Join-Path $src "kit-named"
New-Item -ItemType Directory -Force -Path $two | Out-Null
Set-Content -Path (Join-Path $two "SKILL.md") -Value "---`nname: kit-named`n---`nkit" -Encoding Ascii
$userOwn = Join-Path $rootA "kit-named"
New-Item -ItemType Directory -Force -Path $userOwn | Out-Null
Set-Content -Path (Join-Path $userOwn "SKILL.md") -Value "my own" -Encoding Ascii
Set-Content -Path (Join-Path $userOwn "notes.md") -Value "my notes" -Encoding Ascii
$script:ExakitSkillsRecordedMemo = $null
$placedTwo = Copy-ExakitSkill -Source $two -Name "kit-named"
Check "the user's folder is not replaced" "my own|my notes" ("" + (Get-Content (Join-Path $userOwn "SKILL.md")) + "|" + (Get-Content (Join-Path $userOwn "notes.md")))
Check "...gets no mark" "False" "$(Test-Path (Join-Path $userOwn '.exakit-owned'))"
Check "...and is named in one line" "True" "$(@($script:warned | Where-Object { $_ -like "Kept your own skill folder*kit-named*" }).Count -eq 1)"
Check "the other root gets the kit's copy, and the skill counts as placed" "True True" "$(Test-Path (Join-Path $rootB 'kit-named\.exakit-owned')) $placedTwo"
Remove-ExakitSkillCopy -Name "kit-named"
Check "removal keeps the user's folder" "True" "$(Test-Path (Join-Path $userOwn 'notes.md'))"
Check "...and takes the kit's copy" "False" "$(Test-Path (Join-Path $rootB 'kit-named'))"

# Before the first full install of this kit (a record kit 0.2.5 wrote, no marks).
$script:fakeManifest = @{ "components.skills.marked" = $null; "components.skills.installed" = @("kit-named", "gated-skill") }
$script:ExakitSkillsRecordedMemo = $null
Check "an older kit's recorded copy is adopted" "True" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'kit-named')"
$gatedSrc = Join-Path $src "gated-skill"; New-Item -ItemType Directory -Force -Path $gatedSrc | Out-Null
Set-Content -Path (Join-Path $gatedSrc "SKILL.md") -Value "kit" -Encoding Ascii
$gatedUser = Join-Path $rootA "gated-skill"; New-Item -ItemType Directory -Force -Path $gatedUser | Out-Null
Set-Content -Path (Join-Path $gatedUser "SKILL.md") -Value "mine" -Encoding Ascii
Check "...but not a recorded folder of a held-back add-on skill" "False" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'gated-skill')"
$script:fakeManifest["components.skills.installed"] = @()
$script:ExakitSkillsRecordedMemo = $null
Check "an unrecorded, different folder is not the kit's" "False" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'kit-named')"
Copy-Item -Force (Join-Path $gatedSrc "SKILL.md") (Join-Path $gatedUser "SKILL.md")
Check "...one byte for byte the kit's is" "True" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'gated-skill')"

Write-Host "an add-on skill kit 0.2.5 placed is the kit's once its add-on is:"
# The 0.2.5 -> 0.3.0 upgrade on Windows: kit 0.2.5 placed its dash-server skill
# without the mark and recorded no add-on skill, so the update said "Kept your own
# skill folder ...\.claude\skills\dash-server" over the kit's own stale copy. A
# copy byte for byte one an earlier kit shipped (tests/lib/dash-server-skill-0.2.5.md,
# LF or CRLF) of an add-on the kit installed is the kit's; one the user changed or
# added to, or of an add-on that is not the kit's, is not. Twin of section 7 in
# tests/skills.sh.
$script:fakeManifest = @{ "components.skills.marked" = $true; "components.skills.installed" = @() }
function Get-ExakitMarketplaceRoot { return $repo }
$script:owner = "kit"
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return ($Id -eq "dash-server" -and $script:owner -ne "absent") }
function Test-ExakitComponentManaged { param([string]$Component) return ($Component -eq "dash-server" -and $script:owner -eq "kit") }
$dashSrc = Join-Path $src "dash-server"; New-Item -ItemType Directory -Force -Path $dashSrc | Out-Null
Set-Content -Path (Join-Path $dashSrc "SKILL.md") -Value "---`nname: dash-server`naddon: dash-server`n---`nkit 0.3.0" -Encoding Ascii
$old025 = [System.IO.File]::ReadAllBytes((Join-Path $repo "tests/lib/dash-server-skill-0.2.5.md"))
$dashOld = Join-Path $rootA "dash-server"; New-Item -ItemType Directory -Force -Path $dashOld | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $dashOld "SKILL.md"), $old025)
$script:ExakitSkillsRecordedMemo = $null
Check "a 0.2.5 add-on skill of a kit-installed add-on is the kit's" "True" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'dash-server')"
$script:owner = "user"
Check "...not when the add-on is not the kit's" "False" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'dash-server')"
$script:owner = "absent"
Check "...nor when the add-on is not installed" "False" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'dash-server')"
$script:owner = "kit"
$crlf = [System.Text.Encoding]::UTF8.GetBytes(([System.Text.Encoding]::UTF8.GetString($old025) -replace "`n", "`r`n"))
[System.IO.File]::WriteAllBytes((Join-Path $dashOld "SKILL.md"), $crlf)
Check "...a CRLF copy too" "True" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'dash-server')"
[System.IO.File]::WriteAllBytes((Join-Path $dashOld "SKILL.md"), $old025 + [byte[]](109, 105, 110, 101, 10))
Check "a copy the user changed stays theirs" "False" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'dash-server')"
[System.IO.File]::WriteAllBytes((Join-Path $dashOld "SKILL.md"), $old025)
Set-Content -Path (Join-Path $dashOld "notes.md") -Value "mine" -Encoding Ascii
Check "...and so does one the user added a file to" "False" "$(Test-ExakitSkillIsKits -Root $rootA -Name 'dash-server')"
Remove-Item -Force (Join-Path $dashOld "notes.md")

Write-Host "removing that add-on removes the 0.2.5 copy, as its --dry-run said (WNX-03):"
# The add-on's own uninstall drops its receipt first, and the copy is the kit's
# only while the add-on is installed: decided after that, the folder the
# preview listed was kept. The whole-kit uninstall had the same order (add-ons
# in step 0b, the skills in step 3). Twin of section 8 in tests/skills.sh.
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
foreach ($name in @("Invoke-ExakitUninstallComponent", "Write-ExakitAddonRemovalPreview")) {
    $fn = $cliAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
$script:said = @()
function Info([string]$Msg) { $script:said += $Msg }
function Get-ExakitTilde([string]$Path) { return $Path }
function Write-ExakitLog { }
function Test-ExakitAutostartRegistered { param([string]$Id) return $false }
function Unregister-ExakitAutostart { param([string]$Id) }
function Get-ExakitMarketplaceAddon { param([string]$Id) if ($Id -eq "dash-server") { return [pscustomobject]@{ Id = "dash-server"; UninstallFn = "Invoke-WnxAddonUninstall" } } }
function Invoke-WnxAddonUninstall { param([switch]$DryRun) if (-not $DryRun) { $script:owner = "absent" } }
$script:BinDir = Join-Path $sandbox "bin"
$script:owner = "kit"
Write-ExakitAddonRemovalPreview -Id "dash-server"
Check "the add-on removal preview names the 0.2.5 copy" "1" "$(@($script:said | Where-Object { $_ -like '*will remove: AI skill*dash-server*' }).Count)"
Invoke-ExakitUninstallComponent -Key "dash-server"
Check "...and the removal removes it" "False|absent" "$(Test-Path $dashOld)|$($script:owner)"
New-Item -ItemType Directory -Force -Path $dashOld | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $dashOld "SKILL.md"), $old025)
$script:owner = "kit"
Save-ExakitAddonSkillKits -Ids @("dash-server")
$script:owner = "absent"                       # step 0b: the add-on is gone
Remove-ExakitSkillCopy -Name "dash-server"
Check "the whole-kit removal: the add-on's 0.2.5 copy is still the kit's in step 3" "False" "$(Test-Path $dashOld)"
$script:ExakitSkillKitsDecided = @()
$runText = $cliAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Invoke-ExakitUninstallRun" }, $true).Extent.Text
$decideAt = $runText.IndexOf("Save-ExakitAddonSkillKits")
$loopAt = $runText.IndexOf("foreach (`$addonId in (Get-ExakitMarketplaceRemovableAddons))")
Check "...decided before step 0b removes the add-ons" "True" "$($decideAt -ge 0 -and $loopAt -ge 0 -and $decideAt -lt $loopAt)"
New-Item -ItemType Directory -Force -Path $dashOld | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $dashOld "SKILL.md"), $old025)
$script:owner = "kit"
$script:warned = @()
[void](Copy-ExakitSkill -Source $dashSrc -Name "dash-server")
Check "placing the add-on's skill keeps no own folder over it" "0" "$(@($script:warned | Where-Object { $_ -like 'Kept your own skill folder*' }).Count)"
Check "...it replaces the 0.2.5 copy and marks it" "kit 0.3.0|True" ("" + (Get-Content (Join-Path $dashOld "SKILL.md") | Select-Object -Last 1) + "|" + (Test-Path (Join-Path $dashOld ".exakit-owned")))

Write-Host "an update from 0.2.5 places the kit skills in every skill folder this kit reads:"
# Kit 0.2.5 (14df2ecb) read .claude\skills and .agents\skills only. Its own
# update swapped in this kit, copied the NEW set with THOSE roots (unmarked) and
# recorded the new version, so .continue\skills - read where Continue is - held
# none, every skill read "partial", and the skills row said "current" on every
# later update. Twin of the same section in tests/skills.sh.
$home25 = Join-Path $sandbox "u025"
New-Item -ItemType Directory -Force -Path (Join-Path $home25 ".continue") | Out-Null
Remove-Item Env:\EXAKIT_SKILL_ROOTS -ErrorAction SilentlyContinue
$script:fakeProfile = $home25
$roots25 = @(Get-ExakitSkillRoots)
Check "this kit reads .continue\skills where Continue is" "3" "$($roots25.Count)"
$script:fakeProfile = Join-Path $sandbox "fake-profile"
Check "...and not where it is not (no folder made for a client you lack)" "2" "$(@(Get-ExakitSkillRoots).Count)"
$c25 = Join-Path $home25 ".claude\skills"; $a25 = Join-Path $home25 ".agents\skills"; $n25 = Join-Path $home25 ".continue\skills"
$src25 = Join-Path $sandbox "src25"
foreach ($n in @("core25", "addon25")) { New-Item -ItemType Directory -Force -Path (Join-Path $src25 $n) | Out-Null }
Set-Content -Path (Join-Path $src25 "core25\SKILL.md") -Value "---`nname: core25`n---`nkit" -Encoding Ascii
Set-Content -Path (Join-Path $src25 "addon25\SKILL.md") -Value "---`nname: addon25`naddon: not-installed`n---`nkit" -Encoding Ascii
foreach ($r in @($c25, $a25)) { foreach ($n in @("core25", "addon25")) { Copy-Item -Recurse -Force (Join-Path $src25 $n) (Join-Path $r $n) } }
$script:src = $src25
$script:fakeManifest = @{ "components.skills.marked" = $null; "components.skills.installed" = @("core25", "addon25") }
$script:ExakitSkillsRecordedMemo = $null
$env:EXAKIT_SKILL_ROOTS = "$c25;$a25;$n25"
Check "after the 0.2.5 update a skill is missing from Continue's folder" "True" "$(Test-ExakitSkillsUnplaced)"
$script:okSaid = @(); $script:fetched = 0
function Ok([string]$Msg) { $script:okSaid += $Msg }
function Invoke-WebRequest { $script:fetched++ }
function Install-ExakitSkills {
    foreach ($n in @("core25")) { [void](Copy-ExakitSkill -Source (Join-Path $script:src $n) -Name $n) }
    return $true
}
Update-ExakitSkills -Advertised "9.9.9" -Installed "9.9.9"
Check "exakit update places them at the same version" "AI skills placed in every skill folder (9.9.9)." (@($script:okSaid) -join "|")
Check "...Continue's folder holds the skill" "True" "$(Test-Path (Join-Path $n25 'core25\SKILL.md'))"
Check "...with nothing downloaded" "0" "$script:fetched"
Check "...and a skill waiting for its add-on is not asked for" "False" "$(Test-ExakitSkillsUnplaced)"
$script:okSaid = @()
Update-ExakitSkills -Advertised "9.9.9" -Installed "9.9.9"
Check "the next update is current" "skills are already current (9.9.9)" (@($script:okSaid) -join "|")

Write-Host ""
Write-Host "Update-ExakitSkills never applies an older downloaded set:"
# Seen live: the branch archive named 1.12.6 while 1.24.57 was installed. The
# update said "a few minutes ahead of main", recorded 1.12.6 and retired 25
# skills. Twin of the same section in tests/skills.sh.
$script:ExakitHome = Join-Path $sandbox "kithome"
$kitDirD = Join-Path $script:ExakitHome "kit"
New-Item -ItemType Directory -Force -Path (Join-Path $kitDirD "skills\core25") | Out-Null
Set-Content -Path (Join-Path $kitDirD "skills\core25\SKILL.md") -Value "---`nname: core25`n---`nkit" -Encoding Ascii
Set-Content -Path (Join-Path $kitDirD "skills\.version") -Value "9.8.7" -Encoding Ascii
function Get-ExakitRepoRoot { return $kitDirD }
$script:KitRepo = "example/kit"
$zipSrc = Join-Path $sandbox "zipsrc"
New-Item -ItemType Directory -Force -Path (Join-Path $zipSrc "kit-main\skills\older-only") | Out-Null
Set-Content -Path (Join-Path $zipSrc "kit-main\skills\older-only\SKILL.md") -Value "---`nname: older-only`n---`nold" -Encoding Ascii
Set-Content -Path (Join-Path $zipSrc "kit-main\versions.json") -Value '{"components": {"skills": {"version": "1.2.3"}}}' -Encoding Ascii
$oldZip = Join-Path $sandbox "old.zip"
Compress-Archive -Path (Join-Path $zipSrc "kit-main") -DestinationPath $oldZip -Force
function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec) $script:fetched++; Copy-Item -Force $oldZip $OutFile }
$script:placed = 0
function Install-ExakitSkills { $script:placed++; return $true }
$script:infoSaid = @(); $script:okSaid = @(); $script:warned = @(); $script:fetched = 0
function Info([string]$Msg) { $script:infoSaid += $Msg }
Update-ExakitSkills -Advertised "9.9.9" -Installed "9.8.7"
Check "the archive was fetched" "1" "$script:fetched"
Check "the installed set is kept, said in one line" "True" "$(@($script:infoSaid) -contains 'Keeping AI skills 9.8.7. The download was an older set (1.2.3), and the next update fetches the right one.')"
Check "...the update loop is told it was kept" "True" "$script:ExakitSkillsKept"
Check "...the marker stays where it was" "9.8.7" ("" + (Get-Content (Join-Path $kitDirD "skills\.version") -TotalCount 1))
Check "...the installed skill is still in the kit copy" "True" "$(Test-Path (Join-Path $kitDirD 'skills\core25\SKILL.md'))"
Check "...the older set's skill was not moved in" "False" "$(Test-Path (Join-Path $kitDirD 'skills\older-only'))"
Check "...nothing is placed or retired" "0" "$script:placed"
Check "...no 'a few minutes ahead' warning" "" (@($script:warned) -join "|")
Check "...no 'updated to' line" "" (@($script:okSaid) -join "|")
Check "...and no stage or backup is left behind" "0" "$(@(Get-ChildItem -Force -Path $script:ExakitHome -Filter '.skills-stage-*').Count + @(Get-ChildItem -Path $kitDirD -Filter 'skills.backup-*').Count)"
# The guard is only for an OLDER set: one newer than the installed is applied.
$script:infoSaid = @(); $script:okSaid = @(); $script:placed = 0
Update-ExakitSkills -Advertised "1.2.3" -Installed "1.0.0"
Check "a newer downloaded set is still applied" "False" "$script:ExakitSkillsKept"
Check "...and placed" "1" "$script:placed"
Check "...recorded as the archive's version" "1.2.3" ("" + (Get-Content (Join-Path $kitDirD "skills\.version") -TotalCount 1))

Remove-Item Env:\EXAKIT_SKILL_ROOTS -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "skills (ps): $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
