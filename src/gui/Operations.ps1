# The backup and restore sequences, in one place. extract.ps1, import.ps1 and
# the GUI jobs all call these, so the CLI and the browser cannot drift apart.
#
# Progress is optional: pass a synchronized hashtable and the operation reports
# into it, or omit it and the operation runs silently. Callers that want console
# output subscribe by passing a -OnStep scriptblock.

# Roughly how much of the wall-clock each phase takes on a home of a few
# gigabytes. Only the proportions matter. Without weights the bar followed file
# counts alone, reached the end during the copy, and sat there through the
# archive — which on a large home is the longest wait of all.
$script:BackupPlan = [ordered]@{
    measure = 6; paths = 2; copy = 40; inventory = 6; archive = 38; verify = 5; finish = 3
}
$script:RestorePlan = [ordered]@{
    verify = 3; extract = 40; restore = 52; compare = 5
}

function Write-OperationStep {
    param(
        $Progress,
        [scriptblock]$OnStep,
        [System.Collections.Specialized.OrderedDictionary]$Plan,
        [string]$Phase,
        # Omitted for updates that only move the bar, so the log gets one line
        # per piece of work rather than one per file.
        [string]$Message,
        # How far through this phase, from 0 to 1.
        [double]$Fraction = 0,
        # 'warn' for a line that reports a problem the operation carries on past.
        [ValidateSet('info', 'warn')][string]$Level = 'info'
    )

    if ($Progress) {
        $Progress.Phase = $Phase

        if ($Plan) {
            $keys = @($Plan.Keys)
            $index = [array]::IndexOf($keys, $Phase)
            if ($Phase -eq 'done') {
                $Progress.Steps = $keys.Count
                $Progress.Step = $keys.Count
                $Progress.Percent = 100
            }
            elseif ($index -ge 0) {
                $sum = ($Plan.Values | Measure-Object -Sum).Sum
                $before = 0
                for ($i = 0; $i -lt $index; $i++) { $before += $Plan[$keys[$i]] }
                $clamped = [math]::Min(1.0, [math]::Max(0.0, $Fraction))
                $percent = [int][math]::Floor(100 * ($before + $Plan[$Phase] * $clamped) / $sum)

                $Progress.Steps = $keys.Count
                if ($index + 1 -gt $Progress.Step) { $Progress.Step = $index + 1 }
                # Never backwards, and never full before the work is: a bar
                # that retreats or sits at 100% reads as something gone wrong.
                if ($percent -gt $Progress.Percent) { $Progress.Percent = [math]::Min(99, $percent) }
            }
        }

        if ($Message) {
            $Progress.Message = $Message
            # Built in a list, not with '$existing + $Message': assigning an
            # if-expression unrolls a one-line array into a bare string, and
            # '+' then concatenated the second message onto the first.
            $log = [System.Collections.Generic.List[object]]::new()
            if ($Progress.Log) { foreach ($line in $Progress.Log) { $log.Add($line) } }
            # The level lets the page mark a line that reports a problem as a
            # warning, instead of stamping it [OK] like every other line.
            $log.Add([pscustomobject]@{ Text = $Message; Level = $Level })
            # Replaced rather than appended in place, so a poll reading the
            # array from the listener thread never sees it mid-change.
            $Progress.Log = $log.ToArray()
        }
    }
    if ($OnStep -and $Message) { & $OnStep $Phase $Message $Level }
}

function Invoke-ClaudExtBackup {
    <#
    .SYNOPSIS
        Collects the selected sources into a verified archive.
    .DESCRIPTION
        The whole extract sequence: measure, gather project paths, copy the
        sources, build the inventory, write MANIFEST.json, zip, verify the entry
        count, and place a copy of ClaudExt beside the archive so the backup can
        be read on a machine that has been wiped.

        The manifest records what was staged, not what was measured beforehand.
        Claude Code keeps writing while this runs; counts taken before the copy
        would disagree with the archive and a perfect restore would be reported
        as incomplete.

        Every archive gets a name of its own, down to the minute, so a quick
        backup of a few sources never replaces a full one taken earlier the
        same day. The staging copy is removed whether the run succeeds or not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$SourceIds,
        [string]$ManifestPath,
        [string]$ToolRoot,
        $Progress,
        [scriptblock]$OnStep,
        [switch]$KeepStaging,
        # Where Claude Code keeps its files. Omitted, it is detected.
        [AllowEmptyString()][string]$ClaudeDir
    )

    $Destination = Resolve-ClaudExtFullPath $Destination
    $manifest = if ($ManifestPath) { Get-ClaudExtManifest -ManifestPath $ManifestPath -ClaudeDir $ClaudeDir -Backup }
                else { Get-ClaudExtManifest -ClaudeDir $ClaudeDir -Backup }

    # Nothing to read is nothing to back up. Finishing with an empty archive
    # and 'Backup complete' is the worst way to find that out.
    if (-not (Test-Path -LiteralPath $manifest.ClaudeDir -PathType Container)) {
        throw "Claude folder not found: $($manifest.ClaudeDir)"
    }

    $selected = if ($SourceIds -and $SourceIds.Count -gt 0) {
        @($manifest.Sources | Where-Object { $SourceIds -contains $_.Id })
    } else {
        @($manifest.Sources | Where-Object { $_.Type -notin @('skip', 'report') })
    }
    $measurable = @($selected | Where-Object { $_.Type -notin @('skip', 'report') })

    # A destination inside what is being copied would copy the staging folder
    # into itself while it grows.
    foreach ($inside in @($manifest.ClaudeDir) + @($measurable | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path -PathType Container) } | ForEach-Object Path)) {
        if (Test-PathWithinRoot -Path $Destination -Root $inside) {
            throw "The backup cannot go inside a folder it is backing up: $inside"
        }
    }

    # Local time, to the minute: the name is what a person picks an archive
    # by. Two runs in the same minute still get two names.
    $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
    $stamp = (Get-Date).ToString('yyyy-MM-dd-HHmm')
    $name = "claude-backup-$hostName-$stamp"
    for ($n = 2; (Test-Path -LiteralPath (Join-Path $Destination "$name.zip")) -or
                 (Test-Path -LiteralPath (Join-Path $Destination "staging-$($name.Substring(14))")); $n++) {
        $name = "claude-backup-$hostName-$stamp-$n"
    }
    $archivePath = Join-Path $Destination "$name.zip"
    $stage = Join-Path $Destination "staging-$($name.Substring(14))"

    # The callbacks below are invoked from inside Copy-Source and the archive
    # functions; they still see $step, $bytesBefore and $totalBytes because
    # PowerShell resolves variables up the call stack.
    $step = @{ Progress = $Progress; OnStep = $OnStep; Plan = $script:BackupPlan }
    $warnings = [System.Collections.Generic.List[string]]::new()
    $warn = {
        param($Phase, $Message)
        $warnings.Add($Message)
        Write-OperationStep @step -Phase $Phase -Level 'warn' -Message $Message
    }

    Write-OperationStep @step -Phase 'measure' -Message 'Measuring Sources'
    foreach ($note in $manifest.Notes) { & $warn 'measure' $note }
    $measured = 0
    $measurements = @{}
    foreach ($s in $measurable) {
        $stat = Get-SourceStat -Path $s.Path -Exclude $s.Exclude -ExcludeTop $s.ExcludeTop
        $measurements[$s.Id] = $stat
        $measured++
        Write-OperationStep @step -Phase 'measure' -Fraction ($measured / $measurable.Count) `
            -Message ("{0}: {1:N0} Files, {2:N1} MB" -f $s.Label, $stat.FileCount, ($stat.ByteCount / 1MB))
    }

    # An existing folder can still be the wrong one: a typo that lands on D:\
    # or on the home itself. When none of the selected sources that live in
    # the Claude folder are there, there is nothing worth an archive — only a
    # manifest and an inventory under 'Backup Complete'.
    $insideClaude = @($measurable | Where-Object {
        -not $_.CatchAll -and $_.Path -and (Test-PathWithinRoot -Path $_.Path -Root $manifest.ClaudeDir)
    })
    if ($insideClaude.Count -gt 0 -and -not ($insideClaude | Where-Object { Test-Path -LiteralPath $_.Path })) {
        throw "Nothing to back up in $($manifest.ClaudeDir): none of the selected sources are there."
    }

    Write-OperationStep @step -Phase 'paths' -Message 'Collecting Project Paths'
    $projectsRoot = Join-Path $manifest.ClaudeDir 'projects'
    $pathWarnings = @()
    $transcripts = @($manifest.Sources | Where-Object Id -eq 'transcripts') | Select-Object -First 1
    $leftOut = if ($transcripts) { @($transcripts.ExcludeTop) } else { @() }
    $projectPaths = @(Get-ProjectPaths -ProjectsRoot $projectsRoot -ClaudeJsonPath $manifest.ClaudeJson -ExcludeTop $leftOut `
                                       -WarningVariable pathWarnings -WarningAction SilentlyContinue)
    foreach ($w in $pathWarnings) { & $warn 'paths' ([string]$w.Message) }
    $projectDirs = Get-ProjectDirectoryMap -ProjectsRoot $projectsRoot -ProjectPaths $projectPaths

    # Whose home the records were written under. For this machine's own
    # Claude folder, this machine's. For another machine's, the one its
    # records name — the restore maps paths from there.
    $origin = @{}
    if ($manifest.Foreign) {
        $recordedHome = Get-ClaudExtRecordedHome -ProjectPaths $projectPaths -DiskHome $manifest.DiskHome
        $sourceHome = if ($recordedHome) { $recordedHome }
                      elseif ($manifest.DiskHome) { $manifest.DiskHome }
                      else { Split-Path -Parent $manifest.ClaudeDir }
        $separator = if ($sourceHome.Contains('/') -and -not $sourceHome.Contains('\')) { '/' } else { '\' }
        $origin = @{
            SourceHome        = $sourceHome
            SourceUser        = Split-Path -Leaf $sourceHome
            SourceHost        = ''
            # As that machine named it: where its records point.
            SourceClaudeDir   = if ($manifest.DiskHome) { $sourceHome.TrimEnd('\', '/') + $separator + '.claude' } else { $manifest.ClaudeDir }
            ClaudeCodeVersion = if ($manifest.DiskHome) { Get-ClaudeCodeVersion -AppData (Join-Path $manifest.DiskHome 'AppData' 'Roaming') } else { '' }
        }
        # Where each source was read from, as that machine named it: an
        # auto memory folder is restored to its recorded path.
        if ($manifest.DiskHome) { $origin.DiskHome = $manifest.DiskHome }
        $how = if ($recordedHome) { 'as its records name it' } else { 'guessed from where the folder sits; its records name no home' }
        Write-OperationStep @step -Phase 'paths' -Level $(if ($recordedHome) { 'info' } else { 'warn' }) `
            -Message "Not This Machine's Claude Folder: Its Home Was $sourceHome ($how)"
        if (-not $recordedHome) { $warnings.Add("The old home was guessed as $sourceHome; the records name no home.") }
    }

    $totalBytes = [math]::Max(1L, [long](@($measurements.Values) | Measure-Object -Property ByteCount -Sum).Sum)
    $bytesBefore = 0L
    $onFile = {
        param($files, $bytes)
        Write-OperationStep @step -Phase 'copy' -Fraction (($bytesBefore + $bytes) / $totalBytes)
    }
    $skipped = [System.Collections.Generic.List[string]]::new()
    $done = $false

    try {
        # Staging is created only now, once there is something to put in it, so
        # a backup refused above leaves nothing behind in the destination.
        New-Item -ItemType Directory -Path $stage -Force | Out-Null

        # Bytes, not files: a transcript can be megabytes and a skill a few
        # hundred bytes, so counting files would race through the small
        # sources and crawl through the large one.
        $stats = foreach ($s in $measurable) {
            $measuredStat = $measurements[$s.Id]
            Write-OperationStep @step -Phase 'copy' -Fraction ($bytesBefore / $totalBytes) `
                -Message ("Copying {0} ({1:N0} Files)" -f $s.Label, $measuredStat.FileCount)
            $stagedDir = Join-Path $stage 'claude' $s.Id
            $outcome = @{ Found = $false; IsFile = $false }

            if ($s.Type -eq 'merge') {
                # Only what a restore merges. The rest of the file is this
                # machine's identity, and an API key can be among it.
                if ($s.Path -and (Test-Path -LiteralPath $s.Path -PathType Leaf)) {
                    $outcome = @{ Found = $true; IsFile = $true }
                    try {
                        $null = Export-JsonPortableKeys -SourcePath $s.Path -PortableKeys $s.PortableKeys `
                                    -DestinationPath (Join-Path $stagedDir (Split-Path -Leaf $s.Path))
                    }
                    catch { & $warn 'copy' "$($s.Label) not backed up: $($_.Exception.Message)" }
                }
            }
            else {
                $null = Copy-Source -Path $s.Path -TargetDir $stagedDir -Exclude $s.Exclude -ExcludeTop $s.ExcludeTop `
                                    -OnFile $onFile -Skipped $skipped -Outcome $outcome
            }
            $bytesBefore += $measuredStat.ByteCount

            # What went into the archive, counted where it now sits, and what
            # the source was at the moment it was copied.
            $staged = Get-SourceStat -Path $stagedDir
            [pscustomobject]@{
                Id = $s.Id; Type = $s.Type; Path = $s.Path; Found = $outcome.Found
                IsFile = $outcome.IsFile; FileCount = $staged.FileCount; ByteCount = $staged.ByteCount
            }
        }
        if ($skipped.Count -gt 0) {
            $shown = @($skipped | Select-Object -First 5) -join '; '
            $more = if ($skipped.Count -gt 5) { " and $($skipped.Count - 5) more" } else { '' }
            & $warn 'copy' "$($skipped.Count) Item(s) Could Not Be Copied: $shown$more"
        }

        Write-OperationStep @step -Phase 'inventory' -Message 'Building Inventory'
        $inv = New-InventoryReport -OutputPath (Join-Path $stage 'INVENTORY.md') -ClaudeDir $manifest.ClaudeDir `
                                   -PluginsOnly:$manifest.Foreign

        New-BackupManifestFile -StageDir $stage -Manifest $manifest -SourceStats @($stats) `
                               -ProjectPaths $projectPaths -ProjectDirs $projectDirs @origin | Out-Null

        Write-OperationStep @step -Phase 'archive' -Message 'Creating Archive'
        $onArchive = { param($fraction) Write-OperationStep @step -Phase 'archive' -Fraction $fraction }
        $archive = New-BackupArchive -SourceDir $stage -ArchivePath $archivePath -OnProgress $onArchive

        Write-OperationStep @step -Phase 'verify' -Message 'Verifying Archive'
        $check = Test-BackupArchive -ArchivePath $archivePath
        if (-not $check.Valid) { throw "Archive verification failed: $($check.Error)" }

        $stagedFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force).Count
        if ($check.EntryCount -ne $stagedFiles) {
            throw "Archive holds $($check.EntryCount) entries but $stagedFiles files were staged."
        }
        $done = $true
    }
    finally {
        # On failure too: gigabytes of plain copies, ~/.claude.json's project
        # records among them, must not be left on the backup drive.
        if (-not $KeepStaging -and (Test-Path -LiteralPath $stage)) {
            if ($done) { Write-OperationStep @step -Phase 'finish' -Message 'Removing Staging Folder' }
            try { Remove-Item -LiteralPath $stage -Recurse -Force }
            catch { if ($done) { & $warn 'finish' "Staging folder could not be removed: $stage" } }
        }
    }

    # Without the tool beside it the archive is unreadable after a reinstall,
    # so the copy is checked, created or brought in line, and verified. A copy
    # that cannot be verified does not fail the backup — the archive itself was
    # verified above — but the result says so.
    $tool = $null
    if ($ToolRoot -and (Test-Path -LiteralPath $ToolRoot)) {
        Write-OperationStep @step -Phase 'finish' -Fraction 0.5 -Message 'Checking The ClaudExt Tool Beside The Archive'
        try { $tool = Sync-ClaudExtTool -ToolRoot $ToolRoot -Destination $Destination }
        catch {
            # A locked file or a read-only drive. The archive is already
            # verified, so this is reported, not turned into a failed backup.
            $tool = [pscustomobject]@{
                Action = 'none'; Verified = $false; Files = 0; Changed = 0; IsSelf = $false
                Path = [System.IO.Path]::Combine($Destination, 'claudext-tool')
                Problems = @($_.Exception.Message)
            }
        }
        if ($tool.Verified) {
            $verdict = if ($tool.Action -eq 'created') { "ClaudExt Tool Created ($($tool.Files) Files, Verified)" }
                       elseif ($tool.Action -eq 'refreshed') { "ClaudExt Tool Brought Up To Date ($($tool.Changed) Files, Verified)" }
                       else { "ClaudExt Tool Already Up To Date ($($tool.Files) Files)" }
            Write-OperationStep @step -Phase 'finish' -Fraction 0.9 -Message $verdict
        }
        else {
            & $warn 'finish' "ClaudExt Tool Could Not Be Verified: $(@($tool.Problems)[0..4] -join ', ')"
        }
    }

    Write-OperationStep @step -Phase 'done' -Message 'Backup Complete'

    [pscustomobject]@{
        ArchivePath  = $archivePath
        Bytes        = $archive.Bytes
        EntryCount   = $archive.EntryCount
        ProjectPaths = @($projectPaths)
        ProgramCount = $inv.ProgramCount
        PluginCount  = $inv.PluginCount
        ToolFiles    = if ($tool) { $tool.Files } else { 0 }
        Tool         = $tool
        Skipped      = @($skipped)
        Warnings     = @($warnings)
        SourceHome   = if ($origin.SourceHome) { $origin.SourceHome } else { Get-UserHome }
        Sources      = @($stats)
    }
}

function Resolve-RestoreTarget {
    <#
    .SYNOPSIS
        Redirects a restore destination into an alternative root.
    .DESCRIPTION
        Given a root, that folder behaves as a stand-in home: ~/.claude/skills
        becomes <root>/.claude/skills. A path outside the home keeps its drive
        as the first folder — D:\claude-config\projects becomes
        <root>\D\claude-config\projects — so nothing collides and nothing can
        resolve back out of the root.

        This is what makes a full-scale rehearsal possible — and it is also
        useful on its own, for opening an archive to look inside it without
        overwriting the machine you are sitting at.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$TargetRoot
    )

    if ([string]::IsNullOrWhiteSpace($TargetRoot)) { return $Path }

    # Both sides normalised first. Compared as raw strings, a path with '..' in
    # it counted as under the home and was joined, '..' and all, onto the root —
    # writing outside the folder that was promised to hold everything. And a
    # boundary is required, or 'C:\Users\ada.000' counted as under 'C:\Users\ada'.
    $root = Get-ClaudExtTrimmedPath ([System.IO.Path]::GetFullPath($TargetRoot))
    $relative = Get-RestoreRelativePath -Path $Path
    $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relative))

    if (-not (Test-PathWithinRoot -Path $resolved -Root $root)) {
        throw "Refusing to write outside the chosen folder: $resolved"
    }
    return $resolved
}

function Initialize-ClaudExtWorkDir {
    <#
    .SYNOPSIS
        Empties and prepares the folder an archive is extracted into.
    .DESCRIPTION
        The folder is deleted recursively before each restore, so it has to be
        one ClaudExt made. A marker file says so; a folder without it is emptied
        only when it is the default work folder ClaudExt chose itself. Anything
        else that already holds files is refused — a mistyped -WorkDir must
        never wipe a drive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Owned
    )

    $marker = Join-Path $Path '.claudext-workdir'
    if (Test-Path -LiteralPath $Path -PathType Leaf) { throw "The work folder is a file: $Path" }
    if (Test-Path -LiteralPath $Path) {
        $occupied = [bool](Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)
        if ($occupied -and -not $Owned -and -not (Test-Path -LiteralPath $marker)) {
            throw "The work folder $Path already holds files ClaudExt did not put there. Choose an empty folder."
        }
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    [System.IO.File]::WriteAllText($marker, 'ClaudExt extracts archives here and empties this folder before each restore.')
}

function Test-ClaudExtSameFile {
    # Same size and same bytes. Size first: it settles almost every case
    # without reading anything.
    param([string]$A, [string]$B)
    $x = [System.IO.FileInfo]::new($A); $y = [System.IO.FileInfo]::new($B)
    if ($x.Length -ne $y.Length) { return $false }
    return (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
}

function Get-ArchiveExtraSource {
    <#
    .SYNOPSIS
        The sources an archive declares that no manifest here defines, which a
        restore may still put back: only an auto memory folder.
    .DESCRIPTION
        A custom auto memory folder exists only in the settings of the machine
        that made the archive, so its place comes from MANIFEST.json. Any other
        id there is not trusted with a destination: an archive could name any
        folder at all — the Startup folder, a PowerShell profile — and nothing
        would show it. Those come back under Refused.

        Each accepted source's recorded path is a path the person restoring
        has to see and decide on, like a project outside the old home, so the
        mapping step lists it (see Get-RestoreDecisionRows).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$BackupManifest,
        [string]$ManifestPath
    )

    $accepted = [System.Collections.Generic.List[object]]::new()
    $refused = [System.Collections.Generic.List[string]]::new()
    # The ids manifest.psd1 defines. 'auto-memory' is never one of them: it
    # appears only when some machine's settings.json names the folder.
    $defined = if ($ManifestPath) { Get-ClaudExtManifest -ManifestPath $ManifestPath } else { Get-ClaudExtManifest }
    $known = @($defined.Sources.Id | Where-Object { $_ -ne 'auto-memory' })
    foreach ($a in @($BackupManifest['sources'] | Where-Object { $_ })) {
        $id = [string]$a['id']
        if (-not $id -or $known -contains $id) { continue }
        if ([int]$a['files'] -le 0) { continue }
        $recorded = ([string]$a['path']).Trim()
        # A plain full path only: no '.' or '..' segment that could carry a
        # suggestion out of the home it seems to sit in.
        $qualified = [System.IO.Path]::IsPathFullyQualified($recorded) -or
                     ($recorded.StartsWith('/') -and -not $recorded.StartsWith('//'))
        $plain = $recorded -and $qualified -and $recorded -notmatch '(^|[\\/])\.{1,2}([\\/]|$)'
        if ($id -eq 'auto-memory' -and $plain -and -not [bool]$a['isFile']) {
            $accepted.Add([pscustomobject]@{ Id = $id; Label = 'Auto Memory Folder'; Path = $recorded })
        }
        else { $refused.Add($id) }
    }
    [pscustomobject]@{ Accepted = @($accepted); Refused = @($refused) }
}

function Get-RestoreDecisionRows {
    <#
    .SYNOPSIS
        The old-to-new path table a restore asks about.
    .DESCRIPTION
        Every recorded project path, rewritten for you when it sits under the
        old home and left to a person otherwise, plus the home itself. Paths
        that differ only in case, separator or a trailing separator are one
        folder and one row.

        A folder the archive names as a destination of its own — an auto
        memory folder — is always a row someone decides, even when the home
        did not change and even when it sits under the old home: the archive's
        word alone never picks where files are written. Kind says which rows
        those are ('auto-memory'; 'project' and 'home' for the rest), and
        Suggested what the home mapping would make of it.

        The GUI's mapping step, import.ps1 and the check before a restore
        starts all read this one table.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$BackupManifest,
        [string]$ManifestPath
    )

    $sourceHome = [string]$BackupManifest['sourceHome']
    $targetHome = Get-UserHome
    $remapNeeded = [bool]$sourceHome -and ($sourceHome -ne $targetHome)
    $homeKey = Get-ClaudExtPathKey $sourceHome

    # Archives written before the fix carry [null] when they had no projects.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $projects = foreach ($p in @($BackupManifest['projectPaths'] | Where-Object { $_ })) {
        if ($seen.Add((Get-ClaudExtPathKey ([string]$p)))) { [string]$p }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    if ($remapNeeded) {
        foreach ($r in @(New-PathMapping -SourceHome $sourceHome -TargetHome $targetHome -ProjectPaths @($projects))) {
            $rows.Add([pscustomobject]@{
                From = $r.From; To = $r.To; Resolved = $r.Resolved; Suggested = ''
                Kind = $(if ((Get-ClaudExtPathKey $r.From) -eq $homeKey) { 'home' } else { 'project' })
            })
        }
    }

    $extras = Get-ArchiveExtraSource -BackupManifest $BackupManifest -ManifestPath $ManifestPath
    foreach ($e in $extras.Accepted) {
        $key = Get-ClaudExtPathKey $e.Path
        foreach ($same in @($rows | Where-Object { (Get-ClaudExtPathKey $_.From) -eq $key })) { [void]$rows.Remove($same) }
        # Only a suggestion that lands inside the new home: anything else is
        # for a person to type.
        $suggested = if ($remapNeeded) { ConvertTo-MappedPath -Path $e.Path -Mapping @{ $sourceHome = $targetHome } } else { $null }
        if ($suggested) {
            $suggested = Get-ClaudExtTrimmedPath ([System.IO.Path]::GetFullPath($suggested))
            $location = Get-ClaudeLocation
            if (-not (Test-PathWithinRoot -Path $suggested -Root $targetHome) -or
                (Test-ClaudExtMemoryDestination -Path $suggested -ClaudeDir $location.ConfigDir -Also @($location.ClaudeJson))) {
                $suggested = $null
            }
        }
        $rows.Add([pscustomobject]@{
            From = $e.Path; To = ''; Resolved = $false; Suggested = [string]$suggested; Kind = 'auto-memory'
        })
    }

    [pscustomobject]@{
        SourceHome  = $sourceHome
        TargetHome  = $targetHome
        RemapNeeded = $remapNeeded
        Rows        = @($rows)
    }
}

function Test-ClaudExtMemoryDestination {
    <#
    .SYNOPSIS
        Why a folder may not receive an archive's auto memory, or '' when it
        may.
    .DESCRIPTION
        The last check before files the archive chose are written where the
        archive said, after a person confirmed the place. Refused: anything
        not a plain full path — device paths ('\\?\', '\\.\'), a stream after
        a colon, a share on this very machine ('\\localhost\C$') — the home or
        a folder holding it, the Claude folder or anything inside or around
        it, and the folders where a file runs by itself or changes how the
        machine behaves: start-up folders, every folder on PATH, SSH keys,
        PowerShell profiles, Windows and program folders.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ClaudeDir,
        # More places no memory may go: ~/.claude.json, say.
        [string[]]$Also = @()
    )

    $Path = $Path.Trim()
    if (-not [System.IO.Path]::IsPathFullyQualified($Path)) { return "$Path is not a full path" }
    # One spelling per place, so no other spelling can slip past the checks
    # below: no device prefix, no stream, and a share only on another machine.
    if ($Path -match '^[\\/]{2}[?.][\\/]') { return "$Path is a device path" }
    if ($Path.IndexOf(':', 2) -ge 0) { return "$Path names a stream, not a folder" }
    if ($Path -match '^[\\/]{2}(?<server>[^\\/]+)[\\/](?<share>[^\\/]+)') {
        $server = $Matches['server']; $share = $Matches['share']
        $thisMachine = @('localhost', '127.0.0.1', '::1', '[::1]', $env:COMPUTERNAME, [System.Net.Dns]::GetHostName()) | Where-Object { $_ }
        if ($share.EndsWith('$') -or $thisMachine -contains $server -or $server -match '^127\.') {
            return "$Path is a share of this machine's own disks"
        }
    }
    # Checked as spelled and as it really is: 'C:\Documents and Settings' is a
    # link to 'C:\Users', so a path through it can name the home.
    $real = Resolve-ClaudExtRealPath -Path $Path
    foreach ($candidate in @($Path, $real) | Select-Object -Unique) {
        $problem = Test-ClaudExtGuardedPath -Path $candidate -ClaudeDir $ClaudeDir -Also $Also
        if ($problem) { return $problem }
    }
    return ''
}

function Resolve-ClaudExtRealPath {
    <#
    .SYNOPSIS
        A path with every link along it that exists replaced by where it
        leads; the part that does not exist yet is kept as written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root
    $rest = @($full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries))
    for ($i = 0; $i -lt $rest.Count; $i++) {
        $next = [System.IO.Path]::Combine($current, $rest[$i])
        $info = [System.IO.DirectoryInfo]::new($next)
        if (-not $info.Exists) { return [System.IO.Path]::Combine(@($next) + @($rest | Select-Object -Skip ($i + 1))) }
        try {
            $target = $info.ResolveLinkTarget($true)
            $current = if ($target) { $target.FullName } else { $next }
        }
        catch { $current = $next }
    }
    return $current
}

function Test-ClaudExtGuardedPath {
    # The checks of Test-ClaudExtMemoryDestination, for one spelling of a path.
    param([string]$Path, [string]$ClaudeDir, [string[]]$Also = @())

    $homeDir = Get-UserHome
    if (Test-PathWithinRoot -Path $homeDir -Root $Path) { return "$Path is the home or holds it" }
    if ((Test-PathWithinRoot -Path $ClaudeDir -Root $Path) -or (Test-PathWithinRoot -Path $Path -Root $ClaudeDir)) {
        return "$Path is the Claude folder, inside it or around it"
    }
    foreach ($a in $Also) {
        if ($a -and ((Test-PathWithinRoot -Path $a -Root $Path) -or (Test-PathWithinRoot -Path $Path -Root $a))) {
            return "$Path is, or holds, $a"
        }
    }

    $documents = [Environment]::GetFolderPath('MyDocuments')
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $guarded = @(
        [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'),
        [Environment]::GetFolderPath('Windows'), [Environment]::GetFolderPath('System'),
        [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'),
        (Join-Path $homeDir '.ssh'), (Join-Path $homeDir '.config' 'autostart'), (Join-Path $homeDir '.gnupg'),
        $(if ($documents) { Join-Path $documents 'PowerShell' }), $(if ($documents) { Join-Path $documents 'WindowsPowerShell' }),
        $(if ($localAppData) { Join-Path $localAppData 'Microsoft' 'WindowsApps' })
    ) + @(([string]$env:PATH) -split [System.IO.Path]::PathSeparator | Where-Object { $_ -and [System.IO.Path]::IsPathFullyQualified($_) }) |
        Where-Object { $_ }
    foreach ($g in $guarded) {
        if ((Test-PathWithinRoot -Path $Path -Root $g) -or (Test-PathWithinRoot -Path $g -Root $Path)) {
            return "$Path is, or holds, a folder whose files run by themselves or guard the machine ($g)"
        }
    }
    return ''
}

function Invoke-ClaudExtRestore {
    <#
    .SYNOPSIS
        Restores an archive, applying a confirmed path mapping.
    .DESCRIPTION
        Verifies the archive before writing anything, extracts it, restores each
        source (renaming transcript folders and rewriting embedded paths when
        the home or the Claude folder moved), then compares counts against the
        manifest recorded at backup time.

        Nothing already on the machine is lost. A file the restore would
        replace with different content is moved first into
        <Claude folder>\claudext-replaced\<time>, keeping its place, and so is
        every JSON file before keys are merged into it. The result names that
        folder.

        One source that fails does not stop the others: it is reported as a
        warning and in the count comparison, which always runs, and the
        extracted copy is always removed.

        The archive is opened in a work folder. Restoring into a folder
        (-TargetRoot), that is '.claudext-work' inside it, so a rehearsal
        writes nothing anywhere else, the temp folder included; MANIFEST.json
        and INVENTORY.md stay there. Restoring into this machine, it is a
        folder in the temp directory, and nothing of it is left afterwards.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Archive,
        [System.Collections.IDictionary]$Mapping = @{},
        # Where the archive is opened. Omitted: inside -TargetRoot when there
        # is one, the temp directory otherwise. A folder named here must be
        # empty or one ClaudExt made: it is emptied before use.
        [string]$WorkDir,
        [string]$ManifestPath,
        # When set, everything is written under this folder instead of the live
        # home — the work folder too. Nothing outside it is touched.
        [AllowEmptyString()][string]$TargetRoot,
        $Progress,
        [scriptblock]$OnStep,
        # Where Claude Code keeps its files on this machine. Omitted, it is
        # detected. It does not have to exist yet.
        [AllowEmptyString()][string]$ClaudeDir
    )

    $Archive = Resolve-ClaudExtFullPath $Archive
    if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) { $TargetRoot = Resolve-ClaudExtFullPath $TargetRoot }
    # The temp folder is ClaudExt's own and is cleared completely after use.
    # A folder inside the target is emptied before use only once it is empty
    # or carries ClaudExt's marker, like one named by hand.
    $tempWorkDir = $false
    if (-not $WorkDir) {
        if ($TargetRoot) { $WorkDir = Join-Path $TargetRoot '.claudext-work' }
        else { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) 'claudext-restore'; $tempWorkDir = $true }
    }
    $WorkDir = Resolve-ClaudExtFullPath $WorkDir

    $step = @{ Progress = $Progress; OnStep = $OnStep; Plan = $script:RestorePlan }

    # Checked before anything is extracted: a mapping to nowhere would be
    # written into thousands of records. The answers as given are kept apart
    # from the working mapping, which is trimmed of what a parent implies.
    $map = ConvertTo-RestoreMapping -Mapping $Mapping
    $decisions = $map.Clone()

    Write-OperationStep @step -Phase 'verify' -Message 'Verifying Archive'
    $check = Test-BackupArchive -ArchivePath $Archive
    if (-not $check.Valid) { throw "Archive is not usable: $($check.Error)" }

    Initialize-ClaudExtWorkDir -Path $WorkDir -Owned:$tempWorkDir
    $extractedTree = Join-Path $WorkDir 'claude'
    try {
        Write-OperationStep @step -Phase 'extract' -Message ("Extracting {0:N0} Entries" -f $check.EntryCount)
        $onExtract = { param($fraction) Write-OperationStep @step -Phase 'extract' -Fraction $fraction }
        $extracted = Expand-BackupArchive -ArchivePath $Archive -TargetDir $WorkDir -OnProgress $onExtract
        $extractedSafe = [math]::Max(1, $extracted)

        $backupManifestPath = Join-Path $WorkDir 'MANIFEST.json'
        if (-not (Test-Path -LiteralPath $backupManifestPath)) { throw 'MANIFEST.json missing from archive.' }
        $backupManifest = Read-ClaudExtJson -Path $backupManifestPath

        $manifest = if ($ManifestPath) { Get-ClaudExtManifest -ManifestPath $ManifestPath -ClaudeDir $ClaudeDir }
                    else { Get-ClaudExtManifest -ClaudeDir $ClaudeDir }

        # The Claude folder itself may live somewhere new — CLAUDE_CONFIG_DIR,
        # or a folder chosen on either side. Paths into the old one follow it.
        $sourceClaudeDir = Get-ClaudExtTrimmedPath ([string]$backupManifest['sourceClaudeDir'])
        if ($sourceClaudeDir) {
            $followed = ConvertTo-MappedPath -Path $sourceClaudeDir -Mapping $map
            if (-not $followed) { $followed = $sourceClaudeDir }
            $sameFolder = [string]::Equals((Get-ClaudExtTrimmedPath $followed), (Get-ClaudExtTrimmedPath $manifest.ClaudeDir),
                                           [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $sameFolder) { $map[$sourceClaudeDir] = $manifest.ClaudeDir }
        }
        # Entries that say nothing a shorter one does not already say — every
        # project under the old home, typically — only slow the rewrite down.
        $map = Get-ClaudExtMinimalMapping -Mapping $map
        $remapper = if ($map.Count -gt 0) { New-PathRemapper -Mapping $map } else { $null }

        # Which transcript folder was named after which path: recorded at
        # backup time since schema 2, rebuilt from the project list for older
        # archives.
        $knownDirs = @{}
        $recordedDirs = $backupManifest['projectDirs']
        if ($recordedDirs -is [System.Collections.IDictionary]) {
            foreach ($k in $recordedDirs.Keys) { $knownDirs[[string]$k] = [string]$recordedDirs[$k] }
        }
        else {
            foreach ($p in @($backupManifest['projectPaths'] | Where-Object { $_ })) {
                $name = ConvertTo-ProjectDirName $p
                if (-not $knownDirs.ContainsKey($name)) { $knownDirs[$name] = $p }
            }
        }
        $archiveSources = @{}
        foreach ($a in @($backupManifest['sources'] | Where-Object { $_ })) { $archiveSources[[string]$a['id']] = $a }

        $warnings = [System.Collections.Generic.List[string]]::new()
        $notes = [System.Collections.Generic.List[string]]::new()

        # What to restore: this machine's sources, plus an auto memory folder
        # the archive declares. That folder goes where the restored settings
        # will point: its recorded path, translated like every other path.
        # This machine's own setting names it only when the archive brought no
        # settings to replace it with.
        $plan = [System.Collections.Generic.List[object]]::new()
        $notRestored = @{}
        foreach ($s in $manifest.Sources) {
            if ($s.Type -in @('skip', 'report')) {
                if ($archiveSources.ContainsKey($s.Id) -and [int]$archiveSources[$s.Id]['files'] -gt 0) { $notRestored[$s.Id] = $s.Label }
                continue
            }
            $plan.Add($s)
        }
        $extras = Get-ArchiveExtraSource -BackupManifest $backupManifest -ManifestPath $ManifestPath
        # When the archive carries an auto memory folder, it goes where a
        # person answered, or nowhere — never into this machine's own memory
        # folder by default, and not when the archive's entry was refused.
        if ($archiveSources.ContainsKey('auto-memory') -and [int]$archiveSources['auto-memory']['files'] -gt 0) {
            foreach ($live in @($plan | Where-Object Id -eq 'auto-memory')) { [void]$plan.Remove($live) }
        }
        foreach ($e in $extras.Accepted) {
            # Only where a person said: an answer for this very folder, not
            # one carried over from a parent. Without one, the archive's word
            # would be all there is.
            $decided = @($decisions.Keys | Where-Object { (Get-ClaudExtPathKey $_) -eq (Get-ClaudExtPathKey $e.Path) }) | Select-Object -First 1
            if (-not $decided) {
                $warnings.Add("$($e.Label) not restored: nobody chose where it goes ($($e.Path)). Restore again and answer for it.")
                continue
            }
            $destination = $decisions[$decided]
            $problem = Test-ClaudExtMemoryDestination -Path $destination -ClaudeDir $manifest.ClaudeDir -Also @($manifest.ClaudeJson)
            if (-not $problem -and (Test-Path -LiteralPath (Resolve-RestoreTarget -Path $destination -TargetRoot $TargetRoot) -PathType Leaf)) {
                $problem = "$destination is a file, not a folder"
            }
            if ($problem) {
                $warnings.Add("$($e.Label) not restored: $problem. Choose another place for it and restore again.")
                continue
            }
            $plan.Add([pscustomobject]@{
                Id = $e.Id; Label = $e.Label; Type = 'copy'; Remap = $true; Path = $destination; PortableKeys = @()
                # Notes only: an archive has no say over anything that runs.
                OnlyExtensions = @('.md', '.markdown', '.txt')
            })
        }
        foreach ($id in $extras.Refused) {
            $warnings.Add("'$id' is in the archive, but ClaudExt does not restore it: nothing says where it belongs, and the archive's own word is not trusted with a destination.")
        }
        foreach ($id in $notRestored.Keys) {
            $notes.Add("$($notRestored[$id]): in the archive, not restored — Claude Code on this machine makes its own.")
        }

        $replacedRoot = Join-Path (Resolve-RestoreTarget -Path $manifest.ClaudeDir -TargetRoot $TargetRoot) `
                                  ('claudext-replaced\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        # Counted through one shared table: the helpers below run in scopes of
        # their own, where '$n++' on a plain variable would count a copy.
        $counters = @{ Replaced = 0; FilesRewritten = 0L; LinesRewritten = 0L; StaleLines = 0L }
        $staleFiles = [System.Collections.Generic.List[string]]::new()
        $pathComparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
        $written = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
        $madeDirs = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
        $dirNames = @{}
        $dirOutcome = @{ known = 0; prefix = 0; unchanged = 0; 'too-long' = 0 }

        # Moves whatever sits at a path into the replaced folder, keeping its
        # place.
        $setAside = {
            param($Path)
            $aside = Join-Path $replacedRoot (Get-RestoreRelativePath -Path $Path -Root $TargetRoot)
            $n = 1
            $candidate = $aside
            while (Test-Path -LiteralPath $candidate) { $candidate = "$aside.$n"; $n++ }
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $candidate))
            Move-Item -LiteralPath $Path -Destination $candidate -Force
            $counters.Replaced++
        }

        $ensureDir = {
            param($Dir)
            if ($madeDirs.Contains($Dir)) { return }
            if (Test-Path -LiteralPath $Dir -PathType Leaf) { & $setAside $Dir }
            [void][System.IO.Directory]::CreateDirectory($Dir)
            [void]$madeDirs.Add($Dir)
        }

        # Writes one file into place. A file already there with different
        # content, or one this same restore wrote a moment ago under a
        # colliding name, is set aside first; an identical one is left as it is.
        # How a file is written: 'copy' byte for byte, 'text' and 'json'
        # through the remapper (JSON sees paths only in their escaped form),
        # 'utf16' for a script Windows PowerShell saved as UTF-16.
        $place = {
            param($From, $To, $Mode)
            & $ensureDir (Split-Path -Parent $To)
            $exists = Test-Path -LiteralPath $To
            $target = if ($exists) { "$To.claudext-new" } else { $To }

            if ($Mode -in 'text', 'json') {
                $r = $remapper.RemapFile($From, $target, ($Mode -eq 'json'))
                if ($r.LinesChanged -gt 0) { $counters.FilesRewritten++; $counters.LinesRewritten += $r.LinesChanged }
                if ($r.LinesLeftStale -gt 0) { $counters.StaleLines += $r.LinesLeftStale; $staleFiles.Add($To) }
            }
            elseif ($Mode -eq 'utf16') {
                $changed = Invoke-ClaudExtUtf16Remap -InputPath $From -OutputPath $target -Remapper $remapper
                if ($changed -gt 0) { $counters.FilesRewritten++; $counters.LinesRewritten += $changed }
            }
            else {
                [System.IO.File]::Copy($From, $target, $true)
                [System.IO.File]::SetLastWriteTimeUtc($target, [System.IO.File]::GetLastWriteTimeUtc($From))
            }

            if ($exists) {
                if (-not $written.Contains($To) -and (Test-Path -LiteralPath $To -PathType Leaf) -and (Test-ClaudExtSameFile $To $target)) {
                    Remove-Item -LiteralPath $target -Force
                }
                else {
                    & $setAside $To
                    Move-Item -LiteralPath $target -Destination $To -Force
                }
            }
            [void]$written.Add($To)
        }

        $actualCounts = @{}
        $ruleSkipped = @{}
        $restored = 0

        foreach ($s in $plan) {
            $stagedDir = Join-Path $extractedTree $s.Id
            if (-not (Test-Path -LiteralPath $stagedDir)) { continue }
            if (-not $s.Path) {
                $warnings.Add("$($s.Label): nowhere to put it on this system, so it was not restored. It is still in the archive.")
                continue
            }

            $count = 0
            try {
                $destinationRoot = Resolve-RestoreTarget -Path $s.Path -TargetRoot $TargetRoot
                $rewrite = [bool]($remapper -and $s.Remap)

                if ($s.Type -eq 'merge') {
                    $staged = Get-ChildItem -LiteralPath $stagedDir -File | Select-Object -First 1
                    if ($staged) {
                        if (Test-Path -LiteralPath $destinationRoot -PathType Container) { & $setAside $destinationRoot }
                        $aside = ''
                        if (Test-Path -LiteralPath $destinationRoot -PathType Leaf) {
                            # Kept as it was before any key is merged into it.
                            $aside = Join-Path $replacedRoot (Get-RestoreRelativePath -Path $destinationRoot -Root $TargetRoot)
                            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $aside))
                            Copy-Item -LiteralPath $destinationRoot -Destination $aside -Force
                            $counters.Replaced++
                        }
                        $r = Merge-JsonPortableKeys -SourcePath $staged.FullName -TargetPath $destinationRoot `
                                                    -PortableKeys $s.PortableKeys -ReplaceUnreadableTarget `
                                                    -Remapper $(if ($rewrite) { $remapper } else { $null })
                        if ($r.TargetUnreadable) {
                            $warnings.Add("$($s.Label): $destinationRoot could not be read, so the archive's keys went into a fresh file. The unreadable one is kept in $aside.")
                        }
                        $count = 1
                        $restored++
                        Write-OperationStep @step -Phase 'restore' -Fraction ($restored / $extractedSafe) `
                            -Message ("{0}: Merged {1}" -f $s.Label, ($r.KeysMerged -join ', '))
                    }
                    continue
                }

                # A single-file source goes to its own path. Schema 2 archives
                # say which sources are files; for older ones the staged folder
                # is read — one file, nothing else, named like the source.
                $archiveEntry = $archiveSources[$s.Id]
                $isFile = if ($archiveEntry -and $archiveEntry.Contains('isFile')) { [bool]$archiveEntry['isFile'] }
                          else {
                              $children = @(Get-ChildItem -LiteralPath $stagedDir -Force)
                              $children.Count -eq 1 -and -not $children[0].PSIsContainer -and
                                  $children[0].Name -eq (Split-Path -Leaf $s.Path)
                          }

                Write-OperationStep @step -Phase 'restore' -Fraction ($restored / $extractedSafe) -Message "Restoring $($s.Label)"
                $isTranscripts = $map.Count -gt 0 -and $s.Id -eq 'transcripts'
                # What a backup never takes, a restore never writes, whatever
                # an archive holds: the catch-all's left-out names (plugins,
                # sessions, credentials...) and, for an archive's own memory
                # folder, anything but notes.
                $only = if ($s.PSObject.Properties['OnlyExtensions']) { @($s.OnlyExtensions) } else { @() }
                $neverTop = if ($s.CatchAll) { @($s.ExcludeTop) } else { @() }
                $leftOut = 0
                foreach ($file in Get-ChildItem -LiteralPath $stagedDir -Recurse -File -Force) {
                    if ($only.Count -gt 0 -and $only -notcontains $file.Extension.ToLowerInvariant()) { $leftOut++; continue }
                    if ($neverTop.Count -gt 0) {
                        $top = ($file.FullName.Substring($stagedDir.Length).TrimStart('\', '/') -split '[\\/]', 2)[0]
                        if (@($neverTop | Where-Object { $top -like $_ }).Count -gt 0) { $leftOut++; continue }
                    }
                    if ($isFile) {
                        $destination = $destinationRoot
                    }
                    else {
                        $relative = $file.FullName.Substring($stagedDir.Length).TrimStart('\', '/')
                        if ($isTranscripts) {
                            $segments = $relative -split '[\\/]', 2
                            if (-not $dirNames.ContainsKey($segments[0])) {
                                $known = if ($knownDirs.ContainsKey($segments[0])) { $knownDirs[$segments[0]] } else { '' }
                                $resolution = Resolve-ProjectDirName -Name $segments[0] -KnownPath $known -Mapping $map
                                $dirNames[$segments[0]] = $resolution.Name
                                $dirOutcome[$resolution.How]++
                                if ($resolution.How -eq 'too-long') {
                                    $warnings.Add("Project folder kept under its old name (Claude Code shortens long names with a hash that cannot be recomputed): $($segments[0])")
                                }
                            }
                            $segments[0] = $dirNames[$segments[0]]
                            $relative = $segments -join [System.IO.Path]::DirectorySeparatorChar
                        }
                        $destination = Join-Path $destinationRoot $relative
                    }

                    $mode = if (-not $rewrite) { 'copy' } else { Get-ClaudExtRemapMode -Path $file.FullName }
                    & $place $file.FullName $destination $mode
                    $count++
                    $restored++
                    if ($count % 25 -eq 0) {
                        Write-OperationStep @step -Phase 'restore' -Fraction ($restored / $extractedSafe)
                    }
                }
                if ($leftOut -gt 0) {
                    # Left out on purpose, so not counted as missing.
                    $ruleSkipped[$s.Id] = $leftOut
                    $what = if ($only.Count -gt 0) { "files that are not notes ($($only -join ', ') only)" }
                            else { 'files of kinds ClaudExt never collects (plugins, sessions, credentials and the like)' }
                    $warnings.Add("$($s.Label): $leftOut $what were in the archive and were not restored.")
                }
            }
            catch {
                $warnings.Add("$($s.Label) not fully restored: $($_.Exception.Message)")
            }
            finally { $actualCounts[$s.Id] = $count }
        }
        $replacedCount = $counters.Replaced

        if ($map.Count -gt 0) {
            $moved = $dirOutcome['known'] + $dirOutcome['prefix']
            Write-OperationStep @step -Phase 'restore' -Fraction 1 `
                -Message ("Paths Rewritten: {0:N0} Lines In {1:N0} Files; {2} Project Folders Renamed" -f $counters.LinesRewritten, $counters.FilesRewritten, $moved)
        }
        if ($counters.StaleLines -gt 0) {
            $shown = @($staleFiles | Select-Object -First 3) -join ', '
            $more = if ($staleFiles.Count -gt 3) { " and $($staleFiles.Count - 3) more" } else { '' }
            $warnings.Add("$($counters.StaleLines) line(s) still hold an old path: they are not UTF-8, and the new path cannot be spelled in their encoding. Edit by hand: $shown$more")
        }

        # Archives written before third-party memory plugins were dropped
        # carry an extra top-level directory. It is not restored, and said out
        # loud so the omission is not a surprise.
        $legacyBackends = @(Get-ChildItem -LiteralPath $WorkDir -Directory -Force -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -notin @('claude', 'desktop-config') })
        foreach ($legacy in $legacyBackends) {
            $warnings.Add("$($legacy.Name): third-party memory plugin data, not restored. It is still in the archive.")
        }

        foreach ($n in $notes) { Write-OperationStep @step -Phase 'restore' -Fraction 1 -Message $n }
        if ($replacedCount -gt 0) {
            Write-OperationStep @step -Phase 'restore' -Fraction 1 `
                -Message "$replacedCount Existing File(s) Kept In $replacedRoot"
        }
        foreach ($w in $warnings) { Write-OperationStep @step -Phase 'restore' -Fraction 1 -Level 'warn' -Message $w }

        # What the archive holds for each source it restores. Schema 2 records
        # what was staged. Schema 1 recorded a count taken before the copy,
        # which a file created meanwhile made wrong, so the extracted tree is
        # counted instead — it is what the zip holds, entry for entry.
        Write-OperationStep @step -Phase 'compare' -Message 'Comparing Counts'
        $schema = [int]$backupManifest['schemaVersion']
        $expected = foreach ($a in @($backupManifest['sources'] | Where-Object { $_ })) {
            $id = [string]$a['id']
            if ($notRestored.ContainsKey($id)) { continue }
            $files = [int]$a['files']
            if ($schema -lt 2) {
                $dir = Join-Path $extractedTree $id
                $files = if (Test-Path -LiteralPath $dir) { @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force).Count } else { 0 }
            }
            if ($ruleSkipped.ContainsKey($id)) { $files -= $ruleSkipped[$id] }
            @{ id = $id; files = $files }
        }
        $verdict = Compare-RestoreCount -ManifestJson @{ sources = @($expected) } -ActualCounts $actualCounts
    }
    finally {
        # The extracted copy has done its job, or cannot finish it; left behind
        # it would hold gigabytes for nothing. Nothing at all stays in the temp
        # folder — the archive still holds MANIFEST.json and INVENTORY.md.
        # Beside a restore into a folder, those two stay.
        $clear = if ($tempWorkDir) { $WorkDir } else { $extractedTree }
        if (Test-Path -LiteralPath $clear) {
            try { Remove-Item -LiteralPath $clear -Recurse -Force } catch { }
        }
    }

    Write-OperationStep @step -Phase 'done' `
        -Message $(if ($verdict.AllMatched) { 'Restore Complete' } else { 'Restore Incomplete' })

    [pscustomobject]@{
        AllMatched     = $verdict.AllMatched
        Mismatches     = @($verdict.Mismatches)
        Counts         = $actualCounts
        TargetRoot     = $TargetRoot
        ClaudeDir      = $manifest.ClaudeDir
        WorkDir        = $(if ($tempWorkDir) { '' } else { $WorkDir })
        # Empty when the work folder is gone: the list is in the archive.
        InventoryPath  = $(if ($tempWorkDir) { '' } else { Join-Path $WorkDir 'INVENTORY.md' })
        ReplacedDir    = $(if ($replacedCount -gt 0) { $replacedRoot } else { '' })
        ReplacedCount  = $replacedCount
        FilesRewritten = $counters.FilesRewritten
        LinesRewritten = $counters.LinesRewritten
        FoldersRenamed = $dirOutcome['known'] + $dirOutcome['prefix']
        Warnings       = @($warnings)
        Notes          = @($notes)
        SourceHost     = [string]$backupManifest['sourceHost']
        CreatedAt      = [string]$backupManifest['createdAt']
    }
}

function Invoke-GuiBackup {
    <#
    .SYNOPSIS
        Job body wrapper: runs a backup and reports into the progress table.
    #>
    [CmdletBinding()]
    param($Progress, $Arguments)

    Invoke-ClaudExtBackup -Destination $Arguments.Destination `
                        -SourceIds $Arguments.SourceIds `
                        -ToolRoot $Arguments.RepoRoot `
                        -ClaudeDir $Arguments.ClaudeDir `
                        -Progress $Progress
}

function Invoke-GuiRestore {
    <#
    .SYNOPSIS
        Job body wrapper: runs a restore and reports into the progress table.
    #>
    [CmdletBinding()]
    param($Progress, $Arguments)

    $mapping = @{}
    if ($Arguments.Mapping) {
        foreach ($k in $Arguments.Mapping.Keys) { $mapping[$k] = $Arguments.Mapping[$k] }
    }

    Invoke-ClaudExtRestore -Archive $Arguments.Archive -Mapping $mapping `
                           -TargetRoot $Arguments.TargetRoot -ClaudeDir $Arguments.ClaudeDir `
                           -Progress $Progress
}
