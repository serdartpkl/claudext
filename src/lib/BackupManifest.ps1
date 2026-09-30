function Get-FirstTranscriptCwd {
    <#
    .SYNOPSIS
        The first working directory recorded in a transcript, or $null.
    .DESCRIPTION
        Only a bounded prefix is read: cwd appears on almost every record, so
        there is no need to stream gigabytes to find it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Lines = 200
    )

    try { $reader = [System.IO.StreamReader]::new($Path) }
    catch { return $null }
    try {
        for ($i = 0; $i -lt $Lines; $i++) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -notmatch '"cwd"\s*:\s*"') { continue }
            try {
                $cwd = ($line | ConvertFrom-Json -AsHashtable)['cwd']
                if ($cwd) { return [string]$cwd }
            }
            catch { continue }
        }
    }
    finally { $reader.Dispose() }
    return $null
}

function New-ClaudExtPathSet {
    # Windows paths name the same folder whatever their case, so one project
    # must not be listed twice for 'C:\x' and 'c:\x'. The comma keeps
    # PowerShell from unrolling the empty set into nothing on the way out.
    $comparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    return , [System.Collections.Generic.HashSet[string]]::new($comparer)
}

function Get-ProjectPaths {
    <#
    .SYNOPSIS
        Collects every real project working directory known to this machine.
    .DESCRIPTION
        Two sources, deduplicated: the first 'cwd' of every session transcript,
        and the keys of the 'projects' object in ~/.claude.json. Directory
        names under ~/.claude/projects are NOT parsed — that encoding is lossy.

        Every session counts, not only the first in each folder: sessions run
        in a worktree or a subfolder are filed under the repository's folder,
        so one folder can hold several working directories, and any of them
        may sit outside the home and need a decision on restore.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [string]$ClaudeJsonPath,
        [int]$LinesPerTranscript = 200,
        # Project folders the backup leaves out, by name: their sessions are
        # not in the archive, so their paths are nothing to decide about.
        [string[]]$ExcludeTop = @()
    )

    $found = New-ClaudExtPathSet

    if (Test-Path -LiteralPath $ProjectsRoot) {
        foreach ($dir in Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force) {
            if (@($ExcludeTop | Where-Object { $dir.Name -like $_ }).Count -gt 0) { continue }
            foreach ($transcript in Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -Force) {
                $cwd = Get-FirstTranscriptCwd -Path $transcript.FullName -Lines $LinesPerTranscript
                if ($cwd) { [void]$found.Add((ConvertTo-CanonicalPath $cwd)) }
            }
        }
    }

    if ($ClaudeJsonPath -and (Test-Path -LiteralPath $ClaudeJsonPath)) {
        try {
            $json = Read-ClaudExtJson -Path $ClaudeJsonPath
            $projects = if ($json -is [System.Collections.IDictionary]) { $json['projects'] }
            if ($projects -is [System.Collections.IDictionary]) {
                foreach ($key in $projects.Keys) {
                    if ($key) { [void]$found.Add((ConvertTo-CanonicalPath ([string]$key))) }
                }
            }
        }
        catch {
            Write-Warning "Could not parse $ClaudeJsonPath : $($_.Exception.Message)"
        }
    }

    return @($found | Sort-Object)
}

function Get-ProjectDirectoryMap {
    <#
    .SYNOPSIS
        Pairs each transcript folder with the real path it was named after,
        where one of the known paths encodes to exactly that name.
    .DESCRIPTION
        A folder's own transcripts are not a reliable witness: sessions in a
        worktree or subfolder are filed under the repository's folder. The
        folder name is, though — so every known path is encoded and matched
        against the names. Folders nothing matches are left out, and a restore
        falls back to translating their encoded name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [string[]]$ProjectPaths = @()
    )

    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $ProjectsRoot)) { return $map }

    $byName = @{}
    foreach ($p in $ProjectPaths) {
        if (-not $p) { continue }
        $name = ConvertTo-ProjectDirName $p
        # Case-sensitive keys: a folder 'c--x' and a path 'C:\x' are told apart
        # first, and matched without case only when nothing exact exists.
        if (-not $byName.ContainsKey("s:$name")) { $byName["s:$name"] = $p }
        $lower = "i:$($name.ToLowerInvariant())"
        if (-not $byName.ContainsKey($lower)) { $byName[$lower] = $p }
    }

    foreach ($dir in Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force) {
        $path = $byName["s:$($dir.Name)"]
        if (-not $path -and $IsWindows) { $path = $byName["i:$($dir.Name.ToLowerInvariant())"] }
        if ($path) { $map[$dir.Name] = $path }
    }
    return $map
}

function Get-ClaudExtRecordedHome {
    <#
    .SYNOPSIS
        The home a Claude folder's records were written under, as the machine
        that wrote them spelled it.
    .DESCRIPTION
        For a Claude folder that is not this machine's — an old disk mounted
        here — the running user's home says nothing: the transcripts, the
        prompt history and ~/.claude.json name 'C:\Users\ada\...', where the
        disk now shows 'F:\Users\ada'. The recorded project paths do know.

        The home whose name matches the folder the '.claude' sat in wins;
        failing that, the home most project paths are under. $null when the
        paths name no home at all.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]]$ProjectPaths = @(),
        [AllowEmptyString()][string]$DiskHome
    )

    $homePattern = '^(?<home>(?:[A-Za-z]:[\\/](?:Users|Documents and Settings)|/home|/Users)[\\/](?<name>[^\\/]+))(?:[\\/]|$)'
    # Folders every Windows machine has that belong to nobody in particular.
    $shared = @('Public', 'Default', 'Default User', 'All Users', 'Shared')
    $counts = @{}
    $spelling = @{}
    foreach ($p in $ProjectPaths) {
        if (-not $p -or $p -notmatch $homePattern) { continue }
        if ($shared -contains $Matches['name']) { continue }
        $h = $Matches['home']
        $key = if (Test-ClaudExtWindowsStylePath $h) { $h.Replace('/', '\').ToLowerInvariant() } else { $h }
        $counts[$key] = 1 + [int]$counts[$key]
        if (-not $spelling.ContainsKey($key)) { $spelling[$key] = $h }
    }
    if ($counts.Count -eq 0) { return $null }

    $ranked = @($counts.GetEnumerator() | Sort-Object -Property Value -Descending)
    if ($DiskHome) {
        $leaf = Split-Path -Leaf $DiskHome
        $named = @($ranked | Where-Object { ($_.Key -split '[\\/]')[-1] -eq $leaf })
        if ($named.Count -gt 0) { $ranked = $named }
    }
    return $spelling[$ranked[0].Key]
}

function Get-ClaudeCodeVersion {
    <#
    .SYNOPSIS
        The newest Claude Code version the desktop app has unpacked under an
        AppData\Roaming folder, or ''.
    .DESCRIPTION
        Sorted as versions, not as text: '2.1.10' is newer than '2.1.9'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$AppData)

    if (-not $AppData) { return '' }
    $dirs = @(Get-ChildItem -LiteralPath (Join-Path $AppData 'Claude' 'claude-code') -Directory -ErrorAction SilentlyContinue)
    $versions = foreach ($d in $dirs) {
        $v = $null
        if ([version]::TryParse($d.Name, [ref]$v)) { [pscustomobject]@{ Name = $d.Name; Version = $v } }
    }
    $newest = @($versions | Sort-Object -Property Version) | Select-Object -Last 1
    if ($newest) { return $newest.Name }
    return ''
}

function New-BackupManifestFile {
    <#
    .SYNOPSIS
        Writes MANIFEST.json into the staging directory.
    .DESCRIPTION
        This file drives the restore: it carries the source machine's home
        directory and real project paths (which the lossy directory encoding
        cannot supply), which transcript folder belongs to which path, and the
        counts used to verify a restore was complete.

        Schema 2 adds, per source, whether it is a single file and where it
        was read from, plus the folder-to-path table. Restore reads schema 1
        archives too.

        The machine details default to this machine's. A backup of a Claude
        folder that is not this machine's passes the ones its records were
        written under instead: a restore maps paths from sourceHome, and this
        machine's home there would leave every old path as it was.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][pscustomobject]$Manifest,
        [Parameter(Mandatory)][pscustomobject[]]$SourceStats,
        [string[]]$ProjectPaths = @(),
        [System.Collections.IDictionary]$ProjectDirs = @{},
        [string]$SourceHome,
        [AllowEmptyString()][string]$SourceUser,
        [AllowEmptyString()][string]$SourceHost,
        [string]$SourceClaudeDir,
        [AllowEmptyString()][string]$ClaudeCodeVersion,
        # Where the source home sits on this machine, when it is not this
        # machine's: each source's path is recorded as SourceHome saw it.
        [AllowEmptyString()][string]$DiskHome
    )

    $recordedPath = {
        param([string]$Path)
        if (-not $DiskHome -or -not $Path -or -not (Test-PathWithinRoot -Path $Path -Root $DiskHome)) { return $Path }
        $rest = $Path.Substring((Get-ClaudExtTrimmedPath $DiskHome).Length).TrimStart('\', '/')
        $separator = if ($SourceHome.Contains('/') -and -not $SourceHome.Contains('\')) { '/' } else { '\' }
        if (-not $rest) { return $SourceHome }
        return $SourceHome.TrimEnd('\', '/') + $separator + $rest.Replace('\', $separator).Replace('/', $separator)
    }

    if (-not $PSBoundParameters.ContainsKey('SourceHome')) { $SourceHome = Get-UserHome }
    if (-not $PSBoundParameters.ContainsKey('SourceUser')) {
        $SourceUser = if ($env:USERNAME) { $env:USERNAME } else { $env:USER }
    }
    if (-not $PSBoundParameters.ContainsKey('SourceHost')) {
        $SourceHost = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
    }
    if (-not $PSBoundParameters.ContainsKey('SourceClaudeDir')) { $SourceClaudeDir = $Manifest.ClaudeDir }
    if (-not $PSBoundParameters.ContainsKey('ClaudeCodeVersion')) {
        $ClaudeCodeVersion = if ((Get-ClaudExtPlatform) -eq 'Windows') { Get-ClaudeCodeVersion -AppData $env:APPDATA } else { '' }
    }

    $payload = [ordered]@{
        schemaVersion     = 2
        createdAt         = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        platform          = Get-ClaudExtPlatform
        sourceHost        = $SourceHost
        sourceHome        = $SourceHome
        sourceClaudeDir   = $SourceClaudeDir
        sourceUser        = $SourceUser
        claudeCodeVersion = $ClaudeCodeVersion
        # Filtered: with no projects the parameter arrives as $null, and
        # @($null) is a one-element array that restore showed as a phantom row.
        projectPaths      = @($ProjectPaths | Where-Object { $_ })
        projectDirs       = $ProjectDirs
        sources           = @($SourceStats | ForEach-Object {
            [ordered]@{
                id     = $_.Id
                type   = $_.Type
                found  = $_.Found
                isFile = [bool]$_.IsFile
                path   = [string](& $recordedPath ([string]$_.Path))
                files  = $_.FileCount
                bytes  = $_.ByteCount
            }
        })
    }

    $path = Join-Path $StageDir 'MANIFEST.json'
    $json = $payload | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    return $path
}
