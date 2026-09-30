function Resolve-ManifestPath {
    <#
    .SYNOPSIS
        Resolves a manifest path entry for one platform.
    .DESCRIPTION
        A path entry is either a plain string (identical on every platform, as
        ~/.claude is) or a hashtable keyed by platform name (as the desktop
        app's config directory is). A map that omits the current platform
        resolves to an empty string, which Get-SourceStat reports as not found —
        a source that does not exist on this OS is not an error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Value,
        [Parameter(Mandatory)][string]$Platform
    )

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Platform)) { return [string]$Value[$Platform] }
        return ''
    }
    throw "Manifest path must be a string or a platform map, got $($Value.GetType().Name)."
}

function Get-AutoMemorySource {
    <#
    .SYNOPSIS
        A source for the auto memory folder when settings.json moves it out of
        the Claude folder, or $null.
    .DESCRIPTION
        Claude Code keeps each project's auto memory under projects/, which the
        transcripts source already takes — unless autoMemoryDirectory points
        somewhere else. Then that folder is the memory, and it is backed up in
        its own right.

        A folder that holds the Claude folder or the whole home is refused:
        backing it up would archive everything again, credentials and SSH keys
        included. The source then carries a Problem, and no Path.

        -DiskHome is the home the Claude folder sits in when it is not this
        machine's — an old disk mounted here. A '~' in the setting, or the old
        home spelled as that machine saw it, is then read from that disk.
        -Foreign says the folder is not this machine's at all: a setting that
        cannot be placed on that disk names a folder of the other machine, and
        reading it here would archive this machine's files in its stead, so
        it is left out with a Problem.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [AllowEmptyString()][string]$DiskHome,
        [switch]$Foreign
    )

    $settingsPath = Join-Path $ClaudeDir 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return $null }
    try { $settings = Read-ClaudExtJson -Path $settingsPath } catch { return $null }
    if ($settings -isnot [System.Collections.IDictionary]) { return $null }

    $configured = ([string]$settings['autoMemoryDirectory']).Trim()
    if ([string]::IsNullOrWhiteSpace($configured)) { return $null }

    $path = $null
    if ($DiskHome) {
        if ($configured -eq '~') { $path = $DiskHome }
        elseif ($configured -match '^~[\\/]') { $path = Join-Path $DiskHome $configured.Substring(2) }
        else {
            # 'C:\Users\ada\notes' as the old machine wrote it is
            # '<disk>\Users\ada\notes' here.
            $leaf = [regex]::Escape((Split-Path -Leaf $DiskHome))
            if ($configured -match "^(?:[A-Za-z]:)?[\\/](?:Users|home)[\\/]$leaf(?<rest>[\\/].*)?$") {
                $path = $DiskHome + $Matches['rest']
            }
        }
    }
    if (-not $path -and $Foreign) {
        return [pscustomobject]@{
            Id = 'auto-memory'; Label = 'Auto Memory Folder'; Type = 'copy'; Remap = $true
            Path = ''; Exclude = @(); ExcludeTop = @(); PortableKeys = @(); CatchAll = $false
            Problem = "Auto Memory Folder not backed up: autoMemoryDirectory ($configured) is a folder of the machine this Claude folder came from, and there is no telling where it is here."
        }
    }
    if (-not $path) { $path = Resolve-ClaudExtFullPath $configured }
    $path = Get-ClaudExtTrimmedPath $path
    if (Test-PathWithinRoot -Path $path -Root $ClaudeDir) { return $null }

    $source = [pscustomobject]@{
        Id = 'auto-memory'; Label = 'Auto Memory Folder'; Type = 'copy'; Remap = $true
        Path = $path; Exclude = @(); ExcludeTop = @(); PortableKeys = @(); CatchAll = $false; Problem = ''
    }
    $homeDir = if ($DiskHome) { $DiskHome } else { Get-UserHome }
    if ((Test-PathWithinRoot -Path $ClaudeDir -Root $path) -or (Test-PathWithinRoot -Path $homeDir -Root $path)) {
        $source.Problem = "Auto Memory Folder not backed up: autoMemoryDirectory ($path) holds the Claude folder or the whole home. Point it at a folder of its own."
        $source.Path = ''
    }
    return $source
}

function Get-ClaudExtManifest {
    <#
    .SYNOPSIS
        Loads manifest.psd1 and returns it with all paths resolved for this
        platform and expanded.
    .DESCRIPTION
        Validates that every source declares a known handling type and that
        merge sources declare which keys are portable. Fails loudly: a silently
        mistyped source would be silently skipped during backup.

        The catch-all source leaves out every name another source takes, so no
        file is ever archived twice. A custom auto memory folder set in
        settings.json becomes a source of its own. Every folder source leaves
        out the files SecretExclude names.

        -Backup resolves the paths a backup reads. When the Claude folder is
        not this machine's own — a '.claude' in another home, an old disk
        mounted here — what lives in the home beside it (the desktop app's
        config) is read from that home, not from this machine's. When there is
        no telling where that home is, such a source is left out, and Notes
        says so.
    #>
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        # Where Claude Code keeps its files. Omitted, it is detected.
        [AllowEmptyString()][string]$ClaudeDir,
        [switch]$Backup
    )

    if (-not $ManifestPath) {
        $ManifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'manifest.psd1'
    }

    $raw = Import-PowerShellDataFile -LiteralPath $ManifestPath
    $validTypes = @('copy', 'remap', 'merge', 'skip', 'report')
    $platform = Get-ClaudExtPlatform
    $location = Get-ClaudeLocation -ConfigDir $ClaudeDir
    $secrets = @($raw.SecretExclude | Where-Object { $_ })
    $notes = [System.Collections.Generic.List[string]]::new()

    # Whose home the Claude folder belongs to, when it is not this machine's.
    # A '.claude' folder names its home: the folder it sits in. Any other
    # folder is this machine's when it is inside this home.
    $foreign = $false
    $diskHome = ''
    if ($Backup -and $location.Source -eq 'chosen') {
        $thisHome = Get-UserHome
        $parent = Split-Path -Parent $location.ConfigDir
        if ($parent -and (Split-Path -Leaf $location.ConfigDir) -eq '.claude') {
            $diskHome = $parent
            $foreign = -not ((Test-PathWithinRoot -Path $parent -Root $thisHome) -and
                             (Test-PathWithinRoot -Path $thisHome -Root $parent))
        }
        else {
            $foreign = -not (Test-PathWithinRoot -Path $location.ConfigDir -Root $thisHome)
            # Outside this home, but perhaps still this machine's: the folder
            # CLAUDE_CONFIG_DIR names, reached from somewhere the variable is
            # not set. Its project records then name this home.
            if ($foreign -and (Test-Path -LiteralPath $location.ClaudeJson -PathType Leaf)) {
                $keys = @()
                try {
                    $records = (Read-ClaudExtJson -Path $location.ClaudeJson)['projects']
                    if ($records -is [System.Collections.IDictionary]) { $keys = @($records.Keys | ForEach-Object { ConvertTo-CanonicalPath ([string]$_) }) }
                }
                catch { }
                $named = Get-ClaudExtRecordedHome -ProjectPaths $keys
                if ($named -and (Get-ClaudExtPathKey $named) -eq (Get-ClaudExtPathKey $thisHome)) { $foreign = $false }
            }
        }
        if (-not $foreign) { $diskHome = '' }
    }

    $sources = foreach ($s in $raw.Sources) {
        if ($validTypes -notcontains $s.Type) {
            throw "Source '$($s.Id)' declares unknown type '$($s.Type)'."
        }
        if ($s.Type -eq 'merge' -and -not $s.PortableKeys) {
            throw "Merge source '$($s.Id)' must declare PortableKeys."
        }
        $resolved = Resolve-ManifestPath -Value $s.Path -Platform $platform
        $label = if ($s.Label) { $s.Label } else { $s.Id }
        $path = if ($resolved) {
                    Expand-ClaudExtPath $resolved -ClaudeDir $location.ConfigDir -ClaudeJson $location.ClaudeJson
                } else { '' }

        # A home-relative path outside the Claude folder, read for a folder
        # that is not this machine's.
        $normal = $resolved.Replace('\', '/')
        $homeRelative = $normal.StartsWith('~/') -and $normal -ne '~/.claude' -and
                        -not $normal.StartsWith('~/.claude/') -and $normal -ne '~/.claude.json'
        if ($foreign -and $homeRelative -and $s.Type -notin @('skip', 'report')) {
            if ($diskHome) { $path = Join-Path $diskHome $resolved.Substring(2) }
            else {
                $path = ''
                $notes.Add("${label} not collected: $($location.ConfigDir) is not this machine's Claude folder, and there is no telling which home it belongs to.")
            }
        }

        $type = if ($s.Type -eq 'remap') { 'copy' } else { $s.Type }
        $exclude = @($s.Exclude | Where-Object { $_ })
        if ($type -eq 'copy') { $exclude = @($exclude + $secrets | Select-Object -Unique) }
        [pscustomobject]@{
            Id           = $s.Id
            Label        = $label
            Type         = $type
            Remap        = [bool]($s.Remap -or $s.Type -eq 'remap')
            Path         = $path
            Exclude      = $exclude
            ExcludeTop   = @($s.ExcludeTop | Where-Object { $_ })
            PortableKeys = @($s.PortableKeys | Where-Object { $_ })
            CatchAll     = [bool]$s.CatchAll
        }
    }

    $autoMemory = Get-AutoMemorySource -ClaudeDir $location.ConfigDir -DiskHome $diskHome -Foreign:$foreign
    if ($autoMemory) {
        if ($autoMemory.Problem) { $notes.Add($autoMemory.Problem) }
        else {
            $autoMemory.Exclude = $secrets
            $sources = @($sources) + ($autoMemory | Select-Object -Property * -ExcludeProperty Problem)
        }
    }

    # A catch-all leaves out, by name, everything directly inside it that
    # another source already takes.
    foreach ($catchAll in @($sources | Where-Object CatchAll)) {
        $taken = foreach ($other in $sources) {
            if ($other.Id -eq $catchAll.Id -or -not $other.Path) { continue }
            $parent = Split-Path -Parent $other.Path
            if ($parent -and (Test-PathWithinRoot -Path $parent -Root $catchAll.Path) -and
                (Test-PathWithinRoot -Path $catchAll.Path -Root $parent)) {
                Split-Path -Leaf $other.Path
            }
        }
        $catchAll.ExcludeTop = @(@($catchAll.ExcludeTop) + @($taken) | Select-Object -Unique)
    }

    $ids = @($sources.Id)
    if ($ids.Count -ne ($ids | Sort-Object -Unique).Count) {
        throw 'Duplicate source id in manifest.psd1.'
    }

    [pscustomobject]@{
        SchemaVersion = $raw.schemaVersion
        Platform      = $platform
        ClaudeDir     = $location.ConfigDir
        ClaudeJson    = $location.ClaudeJson
        # Set by -Backup for a Claude folder that is not this machine's.
        Foreign       = $foreign
        DiskHome      = $diskHome
        Notes         = @($notes)
        Sources       = @($sources)
    }
}
