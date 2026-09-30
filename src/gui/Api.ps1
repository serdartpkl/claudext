# API handlers. These know nothing about HTTP: each takes a hashtable of
# parameters and returns an object. Server.ps1 is the only file that touches
# HttpListener, which is what keeps every behaviour here testable without a
# socket.
#
# Every handler returns @{ Ok = $true; Data = ... } or
# @{ Ok = $false; Error = '...'; StatusCode = <int> }.

function New-ApiOk {
    param($Data)
    [pscustomobject]@{ Ok = $true; Data = $Data; Error = ''; StatusCode = 200 }
}

function New-ApiError {
    param([string]$Message, [int]$StatusCode = 400)
    [pscustomobject]@{ Ok = $false; Data = $null; Error = $Message; StatusCode = $StatusCode }
}

function Test-ClaudeRunning {
    <#
    .SYNOPSIS
        True when Claude Code or the Claude app is running on this machine.
    .DESCRIPTION
        A running Claude writes ~/.claude.json back from memory when it exits,
        over whatever a restore merged into it meanwhile. The native Claude
        Code and the desktop app both run as 'claude'; an npm install runs as
        node, with the package in its command line.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (Get-Process -Name 'claude' -ErrorAction SilentlyContinue) { return $true }
    try {
        $node = if ($IsWindows) {
            Get-CimInstance -ClassName Win32_Process -Filter "Name = 'node.exe'" -OperationTimeoutSec 5 -ErrorAction Stop
        } else { Get-Process -Name 'node' -ErrorAction SilentlyContinue }
        foreach ($p in @($node)) {
            if ([string]$p.CommandLine -match 'claude-code|@anthropic-ai') { return $true }
        }
    }
    catch { }
    return $false
}

function Invoke-ApiInfo {
    <#
    .SYNOPSIS
        Describes this machine: platform, host name, and where Claude lives.
    .DESCRIPTION
        Without a ClaudeDir it reports what detection found. With one it checks
        that folder instead, so the page can say whether a typed or browsed
        path holds anything before a backup is measured against it.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    try {
        $location = Get-ClaudeLocation -ConfigDir ([string]$Parameters['ClaudeDir'])
        $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
        return New-ApiOk -Data ([pscustomobject]@{
            Platform      = $location.Platform
            Host          = $hostName
            Home          = Get-UserHome
            # The date an archive written now carries in its name.
            Today         = (Get-Date).ToString('yyyy-MM-dd')
            Claude        = $location
            ClaudeRunning = Test-ClaudeRunning
        })
    }
    catch { return New-ApiError -Message $_.Exception.Message -StatusCode 500 }
}

function Invoke-ApiTool {
    <#
    .SYNOPSIS
        Reports whether a backup destination already holds a current ClaudExt.
    .DESCRIPTION
        Read-only: choosing a destination writes nothing to it. The backup is
        what creates or refreshes the copy.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    $destination = Resolve-ClaudExtFullPath ([string]$Parameters['Destination'])
    if ([string]::IsNullOrWhiteSpace($destination)) { return New-ApiError -Message 'No destination given.' }

    try {
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            return New-ApiOk -Data ([pscustomobject]@{
                Status = 'no-destination'; Path = [System.IO.Path]::Combine($destination, 'claudext-tool')
                Files = 0; Differences = 0; IsSelf = $false
            })
        }
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $t = Test-ClaudExtTool -ToolRoot $repoRoot -Destination $destination
        # The machine is being wiped because of this backup; a destination on
        # the same drive as the home goes with it.
        $homeRoot = [System.IO.Path]::GetPathRoot((Get-UserHome))
        $sameDrive = [string]::Equals([System.IO.Path]::GetPathRoot($destination), $homeRoot,
                                      [System.StringComparison]::OrdinalIgnoreCase)
        return New-ApiOk -Data ([pscustomobject]@{
            Status         = $t.Status
            Path           = $t.Path
            Files          = $t.Expected
            Differences    = @($t.Missing).Count + @($t.Changed).Count + @($t.Extra).Count
            IsSelf         = $t.IsSelf
            SameDriveAsHome = $sameDrive -and $IsWindows
        })
    }
    catch { return New-ApiError -Message $_.Exception.Message -StatusCode 500 }
}

function Invoke-ApiSources {
    <#
    .SYNOPSIS
        Lists every collectable source with its live file count and size.
    .DESCRIPTION
        skip and report entries are omitted: credentials and the plugin
        directory are never offered as choices, because offering them would
        imply they could be backed up.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    try {
        # The sources a backup of that folder would read.
        $manifest = Get-ClaudExtManifest -ClaudeDir ([string]$Parameters['ClaudeDir']) -Backup
        $rows = foreach ($s in $manifest.Sources) {
            if ($s.Type -in @('skip', 'report')) { continue }
            $stat = Get-SourceStat -Path $s.Path -Exclude $s.Exclude -ExcludeTop $s.ExcludeTop
            [pscustomobject]@{
                Id        = $s.Id
                Label     = $s.Label
                Type      = $s.Type
                Path      = $s.Path
                Found     = $stat.Found
                FileCount = $stat.FileCount
                ByteCount = $stat.ByteCount
            }
        }

        return New-ApiOk -Data @($rows)
    }
    catch { return New-ApiError -Message $_.Exception.Message -StatusCode 500 }
}

function Invoke-ApiBrowse {
    <#
    .SYNOPSIS
        Lists drives, or the subdirectories of a path, optionally with archives.
    .DESCRIPTION
        A browser cannot hand a script a filesystem path — file inputs give
        contents, not locations — so directory navigation happens server side.
        Read-only: names, sizes and timestamps, never file contents.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    $path = $Parameters['Path']
    $includeFiles = [bool]$Parameters['IncludeFiles']

    try {
        if ([string]::IsNullOrWhiteSpace($path)) {
            $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject]@{
                        Name     = $_.Name + ':'
                        Path     = $_.Root
                        IsFolder = $true
                        Size     = 0
                        Modified = ''
                    }
                }
            return New-ApiOk -Data ([pscustomobject]@{
                Path = ''; Parent = ''; IsDriveList = $true; Entries = @($drives)
            })
        }

        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            return New-ApiError -Message "Not a directory: $path"
        }

        # -Force reveals dotfiles, which is wanted, but it also surfaces the
        # recycle bin and the volume metadata directory. Neither can be opened
        # and neither holds a backup.
        $hidden = @('$RECYCLE.BIN', 'System Volume Information', '$Recycle.Bin',
                    'Config.Msi', 'Recovery')
        $entries = Get-ChildItem -LiteralPath $path -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $hidden -notcontains $_.Name } |
            ForEach-Object {
                [pscustomobject]@{
                    Name     = $_.Name
                    Path     = $_.FullName
                    IsFolder = $true
                    Size     = 0
                    Modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                }
            }

        if ($includeFiles) {
            $entries = @($entries) + @(
                Get-ChildItem -LiteralPath $path -File -Filter '*.zip' -Force -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        [pscustomobject]@{
                            Name     = $_.Name
                            Path     = $_.FullName
                            IsFolder = $false
                            Size     = $_.Length
                            Modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                        }
                    }
            )
        }

        $parent = Split-Path -Parent $path
        return New-ApiOk -Data ([pscustomobject]@{
            Path = $path; Parent = $parent; IsDriveList = $false; Entries = @($entries)
        })
    }
    catch { return New-ApiError -Message $_.Exception.Message -StatusCode 500 }
}

function Invoke-ApiArchive {
    <#
    .SYNOPSIS
        Opens an archive and returns its MANIFEST.json plus entry count.
    .DESCRIPTION
        Runs before any mapping work: an archive that will not open is reported
        here, not halfway through a restore.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    # Resolved here and not only inside Test-BackupArchive: ZipFile.OpenRead
    # below would otherwise look for a relative name in the process directory.
    $path = Resolve-ClaudExtFullPath ([string]$Parameters['Path'])
    if ([string]::IsNullOrWhiteSpace($path)) { return New-ApiError -Message 'No archive given.' }

    $check = Test-BackupArchive -ArchivePath $path
    if (-not $check.Valid) { return New-ApiError -Message $check.Error }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try {
            $entry = $zip.GetEntry('MANIFEST.json')
            if (-not $entry) { return New-ApiError -Message 'MANIFEST.json missing from archive.' }
            $reader = [System.IO.StreamReader]::new($entry.Open())
            try { $json = ConvertFrom-ClaudExtJson -Text $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $zip.Dispose() }

        return New-ApiOk -Data ([pscustomobject]@{
            Path = $path; EntryCount = $check.EntryCount; Manifest = $json
        })
    }
    catch { return New-ApiError -Message $_.Exception.Message -StatusCode 500 }
}

function Invoke-ApiMapping {
    <#
    .SYNOPSIS
        Builds the old-to-new path table for an archive against this machine.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    $archive = Invoke-ApiArchive -Parameters $Parameters
    if (-not $archive.Ok) { return $archive }

    # The same table the restore checks its answers against.
    try { return New-ApiOk -Data (Get-RestoreDecisionRows -BackupManifest $archive.Data.Manifest) }
    catch { return New-ApiError -Message $_.Exception.Message -StatusCode 500 }
}

function Test-RestoreMappingComplete {
    <#
    .SYNOPSIS
        True when every project path is either mapped or explicitly skipped.
    .DESCRIPTION
        A restore must not start on a mapping nobody reviewed. Absence is not
        consent: "I did not notice this project" and "I chose to leave it out"
        have to be distinguishable, so skipping is stated rather than inferred.
        An answer counts for the folder, however its path is spelled.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ProjectPaths = @(),
        [hashtable]$Mapping = @{},
        [string[]]$Skipped = @()
    )

    $answered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($k in @($Mapping.Keys) + @($Skipped)) { if ($k) { [void]$answered.Add((Get-ClaudExtPathKey ([string]$k))) } }
    $unaccounted = foreach ($p in $ProjectPaths) {
        if ($answered.Contains((Get-ClaudExtPathKey $p))) { continue }
        $p
    }

    [pscustomobject]@{
        Complete    = (@($unaccounted).Count -eq 0)
        Unaccounted = @($unaccounted)
    }
}

function Invoke-ApiBackup {
    <#
    .SYNOPSIS
        Validates a backup request and starts it as a job.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    # Trimmed and made absolute before it is checked. Test-Path forgives a
    # trailing space and New-Item does not, so an untrimmed path passed the
    # check and then created a second folder. And the job's runspace starts in
    # the process directory, not this location, so a relative path checked
    # here would be written somewhere else there.
    $destination = Resolve-ClaudExtFullPath ([string]$Parameters['Destination'])
    $sourceIds = @($Parameters['SourceIds'])

    if ([string]::IsNullOrWhiteSpace($destination)) {
        return New-ApiError -Message 'No destination given.'
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        return New-ApiError -Message "Destination does not exist: $destination"
    }
    # A backup reads from this folder, so unlike a restore it must be there.
    $claudeDir = Resolve-ClaudExtFullPath ([string]$Parameters['ClaudeDir'])
    if ($claudeDir -and -not (Test-Path -LiteralPath $claudeDir -PathType Container)) {
        return New-ApiError -Message "Claude was not found there: $claudeDir"
    }
    if ($sourceIds.Count -eq 0) {
        return New-ApiError -Message 'Select at least one source.'
    }

    # The folder the job will read: its settings can add a source.
    $manifest = Get-ClaudExtManifest -ClaudeDir $claudeDir -Backup
    $known = @($manifest.Sources | Where-Object { $_.Type -notin @('skip', 'report') } |
               Select-Object -ExpandProperty Id)
    $unknown = @($sourceIds | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) {
        return New-ApiError -Message "Unknown source: $($unknown -join ', ')"
    }

    if (Test-ClaudExtJobRunning) {
        return New-ApiError -Message 'Another job is already running.' -StatusCode 409
    }

    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $id = Start-ClaudExtJob -Kind 'backup' -Arguments @{
        Destination = $destination
        SourceIds   = $sourceIds
        RepoRoot    = $repoRoot
        ClaudeDir   = $claudeDir
    } -Body {
        param($Progress, $Arguments)
        Invoke-GuiBackup -Progress $Progress -Arguments $Arguments
    }

    if (-not $id) { return New-ApiError -Message 'Could not start the job.' -StatusCode 409 }
    return New-ApiOk -Data ([pscustomobject]@{ JobId = $id })
}

function Invoke-ApiRestore {
    <#
    .SYNOPSIS
        Validates a restore request and starts it as a job.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    $archive = Resolve-ClaudExtFullPath ([string]$Parameters['Archive'])
    if ([string]::IsNullOrWhiteSpace($archive)) { return New-ApiError -Message 'No archive given.' }

    $inspect = Invoke-ApiArchive -Parameters @{ Path = $archive }
    if (-not $inspect.Ok) { return $inspect }

    $mapping = @{}
    if ($Parameters['Mapping'] -is [System.Collections.IDictionary]) {
        foreach ($k in $Parameters['Mapping'].Keys) { $mapping[[string]$k] = [string]$Parameters['Mapping'][$k] }
    }
    $skipped = @($Parameters['Skipped'] | Where-Object { $_ })
    # A path kept where it was maps to itself, so a mapping of its parent
    # cannot carry it along.
    foreach ($p in $skipped) { if (-not $mapping.ContainsKey($p)) { $mapping[$p] = $p } }
    # Every new path must be a full path on this machine, before any job starts.
    try { $null = ConvertTo-RestoreMapping -Mapping $mapping }
    catch { return New-ApiError -Message $_.Exception.Message }
    $decisions = Get-RestoreDecisionRows -BackupManifest $inspect.Data.Manifest

    # An empty target means the live home. Anything else must already exist:
    # creating it here would turn a typo into a stray directory tree.
    $targetRoot = Resolve-ClaudExtFullPath ([string]$Parameters['Target'])
    if ($targetRoot -and -not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        return New-ApiError -Message "That folder does not exist: $targetRoot"
    }

    # The Claude folder may be missing — a fresh machine has none — but it
    # cannot be a file.
    $claudeDir = Resolve-ClaudExtFullPath ([string]$Parameters['ClaudeDir'])
    if ($claudeDir -and (Test-Path -LiteralPath $claudeDir -PathType Leaf)) {
        return New-ApiError -Message "That is a file, not a folder: $claudeDir"
    }

    # Every row the mapping step asked about has an answer: a new place, or
    # the old one kept. That includes a folder the archive names itself,
    # whether or not the home changed.
    $open = @($decisions.Rows | Where-Object { -not $_.Resolved } | ForEach-Object From)
    $verdict = Test-RestoreMappingComplete -ProjectPaths $open -Mapping $mapping -Skipped $skipped
    if (-not $verdict.Complete) {
        return New-ApiError -Message ("These paths were neither mapped nor skipped: " +
                                      ($verdict.Unaccounted -join ', '))
    }

    if (Test-ClaudExtJobRunning) {
        return New-ApiError -Message 'Another job is already running.' -StatusCode 409
    }

    # Into this machine while Claude runs, only when asked twice: on exit it
    # writes ~/.claude.json back over the merged project records. 423, not
    # 409: the page joins a running job on a 409.
    if (-not $targetRoot -and -not [bool]$Parameters['Force'] -and (Test-ClaudeRunning)) {
        return New-ApiError -StatusCode 423 -Message ('Claude is running. Close Claude Code and the Claude app first: ' +
                                                      'on exit, Claude writes its settings back over the restored ones.')
    }

    $id = Start-ClaudExtJob -Kind 'restore' -Arguments @{
        Archive    = $archive
        Mapping    = $mapping
        TargetRoot = $targetRoot
        ClaudeDir  = $claudeDir
    } -Body {
        param($Progress, $Arguments)
        Invoke-GuiRestore -Progress $Progress -Arguments $Arguments
    }

    if (-not $id) { return New-ApiError -Message 'Could not start the job.' -StatusCode 409 }
    return New-ApiOk -Data ([pscustomobject]@{ JobId = $id })
}

function Invoke-ApiJob {
    <#
    .SYNOPSIS
        Returns a job's progress snapshot.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    $id = $Parameters['Id']
    if ([string]::IsNullOrWhiteSpace($id)) { return New-ApiError -Message 'No job id given.' }

    # 'latest' answers after the job has finished too, so a page loaded later —
    # a reload, or a tab the browser put to sleep — can still draw its result.
    if ($id -eq 'latest') {
        $latest = Get-ClaudExtLatestJobId
        if (-not $latest) { return New-ApiOk -Data $null }
        $id = $latest
    }

    $job = Get-ClaudExtJob -Id $id
    if (-not $job) { return New-ApiError -Message 'No such job.' -StatusCode 404 }
    # A stop was asked for while this ran: once its outcome has been handed
    # to the page, the server may go.
    if ($script:ClaudExtStopWhenIdle -and $job.Status -ne 'running') { $script:ClaudExtResultDelivered = $true }
    return New-ApiOk -Data $job
}

function Invoke-ApiShutdown {
    <#
    .SYNOPSIS
        Stops the server now, or once the running job has finished.
    .DESCRIPTION
        A job is never cut short. Asked while one runs, the server stops by
        itself a few seconds after it ends — long enough for the page to fetch
        the result — and Deferred says so.
    #>
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})

    if (Test-ClaudExtJobRunning) {
        $script:ClaudExtStopWhenIdle = $true
        $script:ClaudExtResultDelivered = $false
        return New-ApiOk -Data ([pscustomobject]@{ Stopping = $false; Deferred = $true })
    }
    return New-ApiOk -Data ([pscustomobject]@{ Stopping = $true; Deferred = $false })
}
