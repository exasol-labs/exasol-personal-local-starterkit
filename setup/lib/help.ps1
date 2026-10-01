# help.ps1 - Windows twin of help.sh: the kit's help system, rendered from the
# documents in setup/help/*.json rather than from hardcoded text.
#
# Same policy as the bash side: the data comes from the copy that shipped with
# this kit (setup/help/), and nothing else. Fetching a remote copy used to take
# precedence, which let a repository BEHIND the installed kit silently
# downgrade its own help. Help now matches the code it was installed with.
#
# PowerShell parses JSON natively, so unlike the bash twin this side needs no
# Python. Keep it 5.1 compatible: no ternary, no null-coalescing.

function Get-ExakitHelpKitDir {
    if ($script:LibDir) {
        $candidate = Join-Path (Split-Path $script:LibDir -Parent) "help"
        if (Test-Path $candidate) { return $candidate }
    }
    return (Join-Path (Join-Path $script:ExakitHome "kit") "setup\help")
}

# The shipped directory IS the registry: a component exists for help purposes
# exactly when this kit carries a document for it.
function Get-ExakitHelpIds {
    $dir = Get-ExakitHelpKitDir
    if (-not (Test-Path $dir)) { return @() }
    $ids = @()
    foreach ($file in (Get-ChildItem -Path $dir -Filter "*.json" -ErrorAction SilentlyContinue)) {
        $ids += $file.BaseName
    }
    return ($ids | Sort-Object)
}

function Test-ExakitHelpId {
    param([string]$Id)
    return ((Get-ExakitHelpIds) -contains $Id)
}

function Get-ExakitHelpDocument {
    param([string]$Id)
    $shipped = Join-Path (Get-ExakitHelpKitDir) "$Id.json"
    if (Test-Path $shipped) {
        try { return (Get-Content -Raw -Path $shipped -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

# Get-ExakitHelpDocuments - every document this kit carries.
function Get-ExakitHelpDocuments {
    param([string]$Primary = "")
    $map = @{}
    foreach ($id in (Get-ExakitHelpIds)) {
        $doc = Get-ExakitHelpDocument -Id $id
        if ($doc) { $map[$id] = $doc }
    }
    return $map
}

# --- rendering --------------------------------------------------------------

# Every binary the kit documents. A command whose first word is one of these is
# already spelled out ("exakit start" on the runtime page); anything else is a
# bare subcommand and gets its document's prefix put in front. Twin of
# KNOWN_TOOLS / invocation() in help.sh.
$script:ExakitHelpKnownTools = @("exakit", "exapump", "exasol", "dash-server",
    "exasol-json-tables", "exasol-mcp-server", "exasol-mcp-server-http")

# Twin of commands_of() in help.sh: an entry marked "hidden": true keeps its
# page (exakit <cmd> --help) but is left off the overview, --all and the
# catalogue SCREEN. It exists for repair, not for discovery.
#
# The JSON surfaces MARK it instead of dropping it - see
# Get-ExakitHelpDocWithHiddenMarked below, and the twin in help.sh.
function Get-ExakitHelpVisibleCommands {
    param($Doc, [switch]$IncludeHidden)
    $out = @()
    foreach ($entry in @($Doc.commands)) {
        if ($null -eq $entry) { continue }
        if (-not $IncludeHidden -and $entry.PSObject.Properties["hidden"] -and $entry.hidden) { continue }
        $out += $entry
    }
    return $out
}

# A copy of a document that KEEPS its hidden commands, each carrying
# "hidden": true, for the JSON dumps. AGENTS.md says of catalog --json that the
# internal upgrade paths "are marked hidden"; the dumps used to delete them, so
# no row carried a hidden key and three dispatchable commands were absent
# entirely - including skills-install, which `exakit skills --json` hands a
# machine as its "next".
function Get-ExakitHelpDocWithHiddenMarked {
    param($Doc)
    $copy = $Doc | Select-Object *
    if ($copy.PSObject.Properties["commands"]) {
        $marked = @()
        foreach ($entry in (Get-ExakitHelpVisibleCommands $Doc -IncludeHidden)) {
            $e = $entry | Select-Object *
            $isHidden = [bool]($e.PSObject.Properties["hidden"] -and $e.hidden)
            if ($e.PSObject.Properties["hidden"]) { $e.hidden = $isHidden }
            else { $e | Add-Member -NotePropertyName hidden -NotePropertyValue $isHidden }
            $marked += $e
        }
        $copy.commands = $marked
    }
    return $copy
}

function Get-ExakitHelpInvocation {
    param([string]$DocId, $Entry, $Doc)
    $command = ""
    if ($Entry.command) { $command = ([string]$Entry.command).Trim() }
    $parts = $command -split '\s+'
    if ($parts.Count -gt 0 -and $script:ExakitHelpKnownTools -contains $parts[0]) {
        return $command
    }
    $prefix = $DocId
    if ($Doc -and $Doc.invocation_prefix) { $prefix = $Doc.invocation_prefix }
    return ("$prefix $command").Trim()
}

function Get-ExakitHelpInvocationWithOptions {
    param([string]$DocId, $Entry, $Doc)
    $label = Get-ExakitHelpInvocation -DocId $DocId -Entry $Entry -Doc $Doc
    if ($Entry.options) { $label = "$label $($Entry.options)" }
    return $label
}

function Write-ExakitHelpWrapped {
    param([string]$Text, [string]$Indent = "    ", [string]$First = $null)
    if (-not $Text) { return }
    $width = 100
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 40) { $width = [Math]::Min(100, $Host.UI.RawUI.WindowSize.Width) } } catch { }
    $limit = $width - $Indent.Length
    if ($limit -lt 20) { $limit = 20 }
    $line = ""
    $prefix = $Indent
    if ($First) { $prefix = $First }
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if (($line.Length + $word.Length + 1) -gt $limit -and $line) {
            Write-Host ($prefix + $line)
            $line = $word
            $prefix = $Indent
        } else {
            if ($line) { $line = "$line $word" } else { $line = $word }
        }
    }
    if ($line) { Write-Host ($prefix + $line) }
}

function Write-ExakitHelpHeader {
    param([string]$Title, [string]$Subtitle)
    Write-Host ""
    Write-Host ("  " + ("-" * 70)) -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host "   $Title  " -ForegroundColor Cyan -NoNewline
        Write-Host $Subtitle -ForegroundColor DarkGray
    } else {
        Write-Host "   $Title" -ForegroundColor Cyan
    }
    Write-Host ("  " + ("-" * 70)) -ForegroundColor Cyan
}

function Write-ExakitHelpSection {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title"
    Write-Host ""
}

function Write-ExakitHelpCommand {
    param([string]$Label, [string]$Summary, [int]$Pad = 26, [string]$Indent = "    ")
    if ($Label.Length -le $Pad -and $Summary) {
        Write-Host ($Indent + $Label.PadRight($Pad)) -ForegroundColor Green -NoNewline
        Write-Host " $Summary"
    } else {
        Write-Host "$Indent$Label" -ForegroundColor Green
        if ($Summary) { Write-ExakitHelpWrapped -Text $Summary -Indent ($Indent + "  ") }
    }
}

function Write-ExakitHelpSteps {
    param($Steps)
    $number = 1
    foreach ($step in $Steps) {
        Write-Host "    $number. $($step.step)"
        if ($step.run) { Write-Host "       $($step.run)" -ForegroundColor Cyan }
        if ($step.note) { Write-ExakitHelpWrapped -Text $step.note -Indent "       " }
        $number++
    }
}

function Show-ExakitHelpOverview {
    $docs = Get-ExakitHelpDocuments
    $doc = $docs["exakit"]
    if (-not $doc) { Write-Host "No help data found. Re-run the installer."; return 1 }
    Write-ExakitHelpHeader $doc.title $doc.tagline
    # Both optional, and the blank line belongs to the prose rather than to the
    # header: Write-ExakitHelpSection opens with its own blank, so emitting one
    # here for a document that has no role leaves two.
    # Mirrors render_overview in setup/lib/help.sh.
    if ($doc.role) {
        Write-Host ""
        Write-ExakitHelpWrapped -Text $doc.role -Indent "   "
    }
    if ($doc.quickstart) {
        Write-ExakitHelpSection "Start here"
        Write-ExakitHelpSteps $doc.quickstart
    }
    $byName = @{}
    foreach ($entry in (Get-ExakitHelpVisibleCommands $doc)) { $byName[$entry.command] = $entry }
    # First group wins, exactly as the --all view already does. A command that
    # reads naturally in two groups (mcp-setup belongs to both "Get started" and
    # "AI clients") was printed twice, so the one screen whose whole job is "find
    # the command you want" answered the same question in two places. The section
    # header is held back until a row actually survives, so a group whose every
    # command was already listed does not leave an empty heading behind.
    # Twin of render_overview in help.sh.
    $seen = @{}
    foreach ($group in $doc.groups) {
        $rows = @()
        foreach ($name in $group.commands) {
            $entry = $byName[$name]
            if (-not $entry -or $seen[$name]) { continue }
            $seen[$name] = $true
            $rows += $entry
        }
        if ($rows.Count -eq 0) { continue }
        Write-ExakitHelpSection $group.title
        foreach ($entry in $rows) {
            $label = Get-ExakitHelpInvocation -DocId "exakit" -Entry $entry -Doc $doc
            Write-ExakitHelpCommand -Label $label -Summary $entry.summary -Pad 24
        }
    }
    # NO per-component command dump here, and no trailing pointer line. This
    # screen is the map, not the atlas: it used to run past a screenful by
    # printing every command of every component, which made the one thing it is
    # for - finding the command you want - harder. The component pages moved to
    # `exakit help --all`, which is where a reader who wants everything goes,
    # and `exakit catalog` is already listed above under Reference.
    Write-Host ""
    return 0
}

function Show-ExakitHelpAll {
    $docs = Get-ExakitHelpDocuments
    $doc = $docs["exakit"]
    if (-not $doc) { return 1 }
    Write-ExakitHelpHeader "exakit - every command" $doc.tagline
    $byName = @{}
    foreach ($entry in (Get-ExakitHelpVisibleCommands $doc)) { $byName[$entry.command] = $entry }
    $seen = @{}
    foreach ($group in $doc.groups) {
        Write-ExakitHelpSection $group.title
        foreach ($name in $group.commands) {
            $entry = $byName[$name]
            if (-not $entry -or $seen[$name]) { continue }
            $seen[$name] = $true
            Write-ExakitHelpCommand -Pad 30 -Summary $entry.summary `
                -Label (Get-ExakitHelpInvocationWithOptions -DocId "exakit" -Entry $entry -Doc $doc)
        }
    }
    # The per-component command lists, which the overview no longer carries.
    # THIS is "every command", so this is where they belong - the overview was
    # showing more than --all did, which is backwards.
    $others = @()
    foreach ($key in ($docs.Keys | Sort-Object)) { if ($key -ne "exakit") { $others += $key } }
    if ($others.Count -gt 0) {
        Write-ExakitHelpSection "Components"
        foreach ($key in $others) {
            $sub = $docs[$key]
            Write-Host "    $key" -NoNewline
            Write-Host "  $($sub.tagline)" -ForegroundColor DarkGray
            foreach ($entry in (Get-ExakitHelpVisibleCommands $sub)) {
                $text = $entry.summary
                if (-not $text) { $text = $entry.description }
                Write-ExakitHelpCommand -Indent "      " -Pad 34 -Summary $text `
                    -Label (Get-ExakitHelpInvocationWithOptions -DocId $key -Entry $entry -Doc $sub)
            }
            Write-Host ""
        }
    }
    Write-Host ""
    Write-Host "  Detail for one command: exakit <command> --help" -ForegroundColor DarkGray
    Write-Host ""
    return 0
}

function Show-ExakitHelpComponent {
    param([string]$Id)
    $docs = Get-ExakitHelpDocuments -Primary $Id
    $doc = $docs[$Id]
    if (-not $doc) {
        Write-Host "  No help document for '$Id'."
        Write-Host ("  Known: " + (($docs.Keys | Sort-Object) -join ", "))
        return 1
    }
    Write-ExakitHelpHeader $doc.title $doc.tagline
    Write-Host ""
    Write-ExakitHelpWrapped -Text $doc.role -Indent "   "

    $facts = [ordered]@{
        "Repository" = $doc.repo; "Package" = $doc.package; "Binary" = $doc.binary
        "Runs via" = $doc.runs_via; "Image" = $doc.image; "Config" = $doc.config
        "Profile" = $doc.profile; "Venv" = $doc.venv; "Python" = $doc.python
        "URL" = $doc.url; "Control plane" = $doc.control_plane; "DSN" = $doc.dsn
        "Admin user" = $doc.admin_user; "DB user" = $doc.db_user
        "Deployment" = $doc.deployment_dir; "Platforms" = $doc.platforms
        "Requires" = $doc.requires; "Installed by" = $doc.installed_by; "Docs" = $doc.docs
    }
    $any = $false
    foreach ($key in $facts.Keys) { if ($facts[$key]) { $any = $true } }
    if ($any) {
        Write-ExakitHelpSection "At a glance"
        foreach ($key in $facts.Keys) {
            if (-not $facts[$key]) { continue }
            Write-Host ("    " + $key.PadRight(16)) -ForegroundColor Green -NoNewline
            Write-Host $facts[$key]
        }
    }
    if ($doc.warning) {
        Write-ExakitHelpSection "Important"
        Write-ExakitHelpWrapped -Text $doc.warning -Indent "    "
    }
    if ($doc.boundary) {
        Write-ExakitHelpSection "The read-only boundary"
        Write-ExakitHelpWrapped -Text $doc.boundary -Indent "    "
    }
    if ($doc.clients) {
        Write-ExakitHelpSection "Supported clients"
        Write-ExakitHelpWrapped -Text ($doc.clients -join ", ") -Indent "    "
    }
    if ($doc.quickstart) {
        Write-ExakitHelpSection "How to start"
        Write-ExakitHelpSteps $doc.quickstart
    }
    if ($doc.commands) {
        Write-ExakitHelpSection "Commands"
        foreach ($entry in (Get-ExakitHelpVisibleCommands $doc)) {
            $text = $entry.summary
            if (-not $text) { $text = $entry.description }
            Write-ExakitHelpCommand -Pad 34 -Summary $text `
                -Label (Get-ExakitHelpInvocationWithOptions -DocId $Id -Entry $entry -Doc $doc)
        }
    }
    # Twin of the snippets block in help.sh. Without it the Examples section -
    # the SQL a reader needs most on the json-tables and pyexasol pages -
    # silently vanished on Windows.
    if ($doc.snippets) {
        Write-ExakitHelpSection "Examples"
        $first = $true
        foreach ($snippet in $doc.snippets) {
            if (-not $first) { Write-Host "" }
            $first = $false
            Write-Host "    $($snippet.title)"
            foreach ($line in ($snippet.code -split "`n")) {
                Write-Host "      $line" -ForegroundColor Cyan
            }
        }
    }
    if ($doc.environment) {
        Write-ExakitHelpSection "Environment"
        foreach ($item in $doc.environment) {
            Write-Host ("    " + $item.name.PadRight(26)) -ForegroundColor Green -NoNewline
            Write-Host ""
            Write-ExakitHelpWrapped -Text $item.effect -Indent "      "
        }
    }
    if ($doc.notes) {
        Write-ExakitHelpSection "Good to know"
        foreach ($note in $doc.notes) { Write-ExakitHelpWrapped -Text ("- " + $note) -Indent "      " -First "    " }
    }
    if ($doc.troubleshooting) {
        Write-ExakitHelpSection "If something goes wrong"
        foreach ($item in $doc.troubleshooting) {
            Write-Host "    $($item.symptom)"
            Write-ExakitHelpWrapped -Text $item.remedy -Indent "      "
        }
    }
    if ($doc.see_also) {
        Write-ExakitHelpSection "See also"
        Write-ExakitHelpWrapped -Text ($doc.see_also -join ", ") -Indent "    "
    }
    Write-Host ""
    return 0
}

function Get-ExakitHelpRows {
    param([switch]$IncludeHidden)
    $docs = Get-ExakitHelpDocuments
    $rows = @()
    $seen = @{}
    foreach ($key in ($docs.Keys | Sort-Object)) {
        $doc = $docs[$key]
        foreach ($entry in (Get-ExakitHelpVisibleCommands $doc -IncludeHidden:$IncludeHidden)) {
            $tool = $key
            $command = $entry.command
            $parts = $command -split '\s+'
            if ($parts.Count -gt 1 -and @("exakit", "exapump", "exasol") -contains $parts[0] -and $key -ne $parts[0]) {
                $tool = $parts[0]
                $command = ($parts[1..($parts.Count - 1)] -join " ")
            }
            $text = $entry.summary
            if (-not $text) { $text = $entry.description }
            # Dedupe on (tool, command) WITHOUT options. Keying on options too
            # let the same command through twice whenever two documents spelled
            # its options differently: exakit.json lists `status [--json | -j]`
            # while dash-server.json mentions a bare `exakit status`, and the
            # catalogue printed both. When that happens the tool's OWN document
            # wins - a component page describing `exakit status` is contextual
            # rephrasing, not the canonical description of the command.
            $dedupe = "$tool|$command"
            $row = [pscustomobject]@{
                tool = $tool; command = $command; options = $entry.options
                description = $text; invocation = ("$tool $command").Trim()
                source = $key
                hidden = [bool]($entry.PSObject.Properties["hidden"] -and $entry.hidden)
            }
            if ($seen.ContainsKey($dedupe)) {
                $keptAt = $seen[$dedupe]
                $kept = $rows[$keptAt]
                if ($tool -eq $key -and $kept.source -ne $kept.tool) { $rows[$keptAt] = $row }
                continue
            }
            $seen[$dedupe] = $rows.Count
            $rows += $row
        }
    }
    return $rows
}

function Show-ExakitHelpCatalog {
    param([string]$Search)
    $rows = Get-ExakitHelpRows
    if ($Search) {
        $needle = $Search.ToLowerInvariant()
        $rows = @($rows | Where-Object {
            ("$($_.tool) $($_.command) $($_.options) $($_.description)").ToLowerInvariant().Contains($needle)
        })
    }
    if ($Search) {
        Write-ExakitHelpHeader "command catalog" "results for `"$Search`""
    } else {
        Write-ExakitHelpHeader "command catalog" "exakit - exapump - exasol - components"
    }
    if ($rows.Count -eq 0) {
        Write-Host ""
        Write-Host "  No commands match `"$Search`".  Try: exakit catalog mcp" -ForegroundColor DarkGray
        Write-Host ""
        return 1
    }
    # GROUP by tool, do not merely break on a change of tool. The rows arrive
    # in help-document order and nearly every component document contributes
    # `exakit ...` commands, so a run-length break printed the "exakit" heading
    # once per component - five times on a full install, interleaved with the
    # component sections. Collect first, then print one section per tool.
    $grouped = @{}
    foreach ($row in $rows) {
        if (-not $grouped.ContainsKey($row.tool)) { $grouped[$row.tool] = @() }
        $grouped[$row.tool] += $row
    }
    $tools = @($grouped.Keys | Sort-Object)
    if ($grouped.ContainsKey("exakit")) {       # the kit's own command first
        $tools = @("exakit") + @($tools | Where-Object { $_ -ne "exakit" })
    }
    foreach ($tool in $tools) {
        Write-ExakitHelpSection $tool
        $entries = @($grouped[$tool])
        # NAME AND PURPOSE ONLY, sorted, with the column sized to this section.
        #
        # The option syntax used to ride along in the label, and a third of the
        # rows were then too long for a fixed 26-column gutter - so they broke
        # onto a second line and the descriptions stopped lining up. A catalog
        # is for scanning down; a ragged one is the one thing it must not be.
        # The full signature is one command away, and SEARCH still matches on
        # the option text - only the display drops it. Sorted because the rows
        # arrive in help-document order.
        # Twin of render_catalog in help.sh.
        $pad = 12
        foreach ($e in $entries) { if ("$($e.command)".Length -gt $pad) { $pad = "$($e.command)".Length } }
        if ($pad -gt 30) { $pad = 30 }
        foreach ($row in ($entries | Sort-Object { "$($_.command)" })) {
            Write-ExakitHelpCommand -Label $row.command -Summary $row.description -Pad $pad
        }
    }
    Write-Host ""
    return 0
}

function Show-ExakitHelpCommand {
    param([string]$Name)
    $docs = Get-ExakitHelpDocuments
    $needle = $Name.ToLowerInvariant()
    foreach ($key in (@("exakit") + ($docs.Keys | Sort-Object))) {
        if (-not $docs.ContainsKey($key)) { continue }
        foreach ($entry in $docs[$key].commands) {
            $command = $entry.command.ToLowerInvariant()
            if ($command -ne $needle -and -not $command.StartsWith("$needle ")) { continue }
            $label = $entry.command
            if ($key -eq "exakit") { $label = "exakit $($entry.command)" }
            Write-Host ""
            if ($entry.options) {
                Write-Host "  $label $($entry.options)"
            } else {
                Write-Host "  $label"
            }
            Write-Host ""
            $text = $entry.description
            if (-not $text) { $text = $entry.summary }
            Write-ExakitHelpWrapped -Text $text -Indent "    "
            if ($entry.warning) {
                Write-Host ""
                Write-ExakitHelpWrapped -Text ("! " + $entry.warning) -Indent "    "
            }
            if ($entry.examples) {
                Write-Host ""
                Write-Host "    Examples" -ForegroundColor DarkGray
                foreach ($example in $entry.examples) { Write-Host "      $example" -ForegroundColor Cyan }
            }
            Write-Host ""
            return 0
        }
    }
    if (Test-ExakitHelpId $Name) { return (Show-ExakitHelpComponent -Id $Name) }
    Write-Host ""
    Write-Host "  No help entry for '$Name'."
    Write-Host "  Try: exakit catalog $Name   or   exakit help --all"
    Write-Host ""
    return 1
}

function Show-ExakitHelpJson {
    param([string]$Which)
    $docs = Get-ExakitHelpDocuments
    $rows = Get-ExakitHelpRows -IncludeHidden
    if (-not $Which -or $Which -eq "all") {
        $visibleDocs = [ordered]@{}
        foreach ($k in ($docs.Keys | Sort-Object)) { $visibleDocs[$k] = Get-ExakitHelpDocWithHiddenMarked $docs[$k] }
        $payload = [ordered]@{ schema_version = 1; search = $null; count = $rows.Count; commands = $rows; documents = $visibleDocs }
    } elseif ($docs.ContainsKey($Which)) {
        $payload = Get-ExakitHelpDocWithHiddenMarked $docs[$Which]
    } else {
        $needle = $Which.ToLowerInvariant()
        $hit = @($rows | Where-Object {
            ("$($_.tool) $($_.command) $($_.options) $($_.description)").ToLowerInvariant().Contains($needle)
        })
        $payload = [ordered]@{ schema_version = 1; search = $Which; count = $hit.Count; commands = $hit }
    }
    $payload | ConvertTo-Json -Depth 12
    # Nothing else on stdout: a `return 0` here put a bare "0" line after the
    # object, and `exakit catalog --json` / `help <x> --json` failed every parser.
    return
}
