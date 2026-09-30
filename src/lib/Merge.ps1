function Read-ClaudExtJson {
    <#
    .SYNOPSIS
        Parses a JSON file into ordered hashtables, exactly as written.
    .DESCRIPTION
        Hashtables rather than objects: ~/.claude.json can hold two project
        keys that differ only in case ('C:/x' and 'c:/x'), and an object cannot
        — ConvertFrom-Json refuses the whole file. Dates stay strings where
        this PowerShell allows it (7.5 and later), so a timestamp is written
        back in the form it was read in.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    return ConvertFrom-ClaudExtJson -Text ([System.IO.File]::ReadAllText($Path))
}

function ConvertFrom-ClaudExtJson {
    <#
    .SYNOPSIS
        Parses JSON text the way Read-ClaudExtJson does.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return [ordered]@{} }
    if ($null -eq $script:ClaudExtJsonHasDateKind) {
        $script:ClaudExtJsonHasDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')
    }
    if ($script:ClaudExtJsonHasDateKind) {
        return ($Text | ConvertFrom-Json -AsHashtable -DateKind String)
    }
    return ($Text | ConvertFrom-Json -AsHashtable)
}

function Merge-JsonPortableKeys {
    <#
    .SYNOPSIS
        Copies selected keys from a backed-up JSON file into the live one.
    .DESCRIPTION
        ~/.claude.json mixes portable state (project records, usage history)
        with machine identity (machineID, userID, oauthAccount). Overwriting the
        whole file would replace the new machine's identity with the old one's,
        so only the declared portable keys are copied and everything else on the
        target survives.

        A portable key that holds an object is merged one level down rather
        than replaced: projects the new machine already knows keep their
        entries, and the archive's entries are added over them. A key holding
        anything else is replaced.

        With -Remapper, every path in the backed-up values and keys is
        rewritten first — project records are filed under the project's path,
        and a record under the old home is one Claude Code will never look up.

        A target that cannot be read as a JSON object — truncated by a crash,
        say — is refused, unless -ReplaceUnreadableTarget says a copy of it is
        already kept elsewhere. It is then merged into as an empty object, and
        TargetUnreadable in the result says so.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string[]]$PortableKeys,
        $Remapper,
        [switch]$ReplaceUnreadableTarget
    )

    try { $source = Read-ClaudExtJson -Path $SourcePath }
    catch { throw "The archived $(Split-Path -Leaf $SourcePath) cannot be read: $($_.Exception.Message)" }
    if ($source -isnot [System.Collections.IDictionary]) {
        throw "The archived $(Split-Path -Leaf $SourcePath) does not hold a JSON object."
    }
    if ($Remapper) { $source = ConvertTo-RemappedJsonValue -Value $source -Remapper $Remapper }

    $unreadable = ''
    $target = [ordered]@{}
    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        # Read again a few times: a Claude still running rewrites this file,
        # and one read can catch it half-written.
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $unreadable = ''
            try {
                $target = Read-ClaudExtJson -Path $TargetPath
                if ($target -isnot [System.Collections.IDictionary]) { $unreadable = 'it does not hold a JSON object' }
            }
            catch { $unreadable = $_.Exception.Message }
            if (-not $unreadable) { break }
            if ($attempt -lt 3) { Start-Sleep -Milliseconds (200 * $attempt) }
        }
    }
    if ($unreadable) {
        if (-not $ReplaceUnreadableTarget) { throw "$TargetPath cannot be merged into: $unreadable" }
        $target = [ordered]@{}
    }

    $merged = @()
    foreach ($key in $PortableKeys) {
        if (-not $source.Contains($key)) { continue }
        $value = $source[$key]
        $current = if ($target.Contains($key)) { $target[$key] } else { $null }
        if ($current -is [System.Collections.IDictionary] -and $value -is [System.Collections.IDictionary]) {
            foreach ($k in @($value.Keys)) { $current[$k] = $value[$k] }
        }
        else {
            $target[$key] = $value
        }
        $merged += $key
    }

    $preserved = @($target.Keys | Where-Object { $merged -notcontains $_ })

    $targetDir = Split-Path -Parent $TargetPath
    if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $json = $target | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($TargetPath, $json, [System.Text.UTF8Encoding]::new($false))

    [pscustomobject]@{ KeysMerged = $merged; KeysPreserved = $preserved; TargetUnreadable = [bool]$unreadable }
}

function Export-JsonPortableKeys {
    <#
    .SYNOPSIS
        Writes only the portable keys of a JSON file to another file, and
        returns the keys written.
    .DESCRIPTION
        What a backup keeps of ~/.claude.json and the desktop app's config.
        The rest — the account, the user id, an API key from an API-key login —
        is this machine's identity, never restored, and has no business in an
        unencrypted archive.

        Claude Code rewrites ~/.claude.json while it runs, so a read can catch
        it half-written. The file is read again a few times before giving up;
        a copy that cannot be parsed is useless to a restore, so failing here,
        where it can be reported, beats archiving it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string[]]$PortableKeys,
        [int]$Attempts = 5
    )

    $source = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $source = Read-ClaudExtJson -Path $SourcePath
            if ($source -isnot [System.Collections.IDictionary]) { throw 'it does not hold a JSON object' }
            break
        }
        catch {
            $source = $null
            if ($attempt -eq $Attempts) { throw "$SourcePath cannot be read: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }

    $kept = [ordered]@{}
    foreach ($key in $PortableKeys) { if ($source.Contains($key)) { $kept[$key] = $source[$key] } }

    $dir = Split-Path -Parent $DestinationPath
    if ($dir) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($DestinationPath, ($kept | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::SetLastWriteTimeUtc($DestinationPath, [System.IO.File]::GetLastWriteTimeUtc($SourcePath))
    return @($kept.Keys)
}
