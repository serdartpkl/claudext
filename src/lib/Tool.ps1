# The copy of ClaudExt that travels beside every archive. A backup is only as
# good as the tool that can read it back, and on the day it is needed that
# tool's original sits on the drive that was wiped. So the copy is checked,
# created when missing, brought in line when it differs, and verified file by
# file afterwards.

$script:ClaudExtToolItems = @('src', 'extract.ps1', 'import.ps1', 'gui.ps1', 'ClaudExt.cmd', 'README.md', 'LICENSE')

function Get-ClaudExtToolFiles {
    <#
    .SYNOPSIS
        Maps every file the tool is made of, by relative path, to its SHA256.
    .DESCRIPTION
        Only the items a tool copy consists of are read, so anything else in
        the folder — notes, a scratch file, the tests — is neither expected
        nor counted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $map }
    $base = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\', '/')

    foreach ($item in $script:ClaudExtToolItems) {
        $path = Join-Path $base $item
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $files = if (Test-Path -LiteralPath $path -PathType Container) {
            Get-ChildItem -LiteralPath $path -Recurse -File -Force
        } else {
            Get-Item -LiteralPath $path -Force
        }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
            $map[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
    return $map
}

function Test-ClaudExtSamePath {
    param([string]$A, [string]$B)
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase }
                  else { [System.StringComparison]::Ordinal }
    $left = [System.IO.Path]::GetFullPath($A).TrimEnd('\', '/')
    $right = [System.IO.Path]::GetFullPath($B).TrimEnd('\', '/')
    return [string]::Equals($left, $right, $comparison)
}

function Test-ClaudExtTool {
    <#
    .SYNOPSIS
        Compares the tool copy at a backup destination with the running tool.
    .DESCRIPTION
        Status is 'missing' when there is no copy, 'outdated' when any file is
        absent, left over or different, 'current' when every file matches, and
        'linked' when the copy contains a junction or symbolic link.

        A link is refused rather than followed: reading, overwriting and
        deleting through it would happen in whatever folder it points at.
        ClaudExt never creates one, so a copy that has one is not its to manage.

        Read-only. Choosing a destination must not write to it; the backup is
        what creates or refreshes the copy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolRoot,
        [Parameter(Mandatory)][string]$Destination
    )

    $ToolRoot = Resolve-ClaudExtFullPath $ToolRoot
    $Destination = Resolve-ClaudExtFullPath $Destination
    $toolDir = [System.IO.Path]::Combine($Destination, 'claudext-tool')
    $expected = Get-ClaudExtToolFiles -Root $ToolRoot

    $report = {
        param($Status, $Missing, $Changed, $Extra, $IsSelf, $Links)
        [pscustomobject]@{
            Status   = $Status
            Path     = $toolDir
            Expected = $expected.Count
            Missing  = @($Missing)
            Changed  = @($Changed)
            Extra    = @($Extra)
            Links    = @($Links)
            IsSelf   = $IsSelf
        }
    }

    # Running from that very copy: it is the tool, so it matches by definition.
    if (Test-ClaudExtSamePath $ToolRoot $toolDir) {
        return & $report 'current' @() @() @() $true @()
    }
    if (-not (Test-Path -LiteralPath $toolDir -PathType Container)) {
        return & $report 'missing' @($expected.Keys | Sort-Object) @() @() $false @()
    }

    # Get-ChildItem -Recurse lists a link without descending into it, which is
    # what makes this check safe to run before anything else.
    $links = @(@(Get-Item -LiteralPath $toolDir -Force) +
               @(Get-ChildItem -LiteralPath $toolDir -Recurse -Force -ErrorAction SilentlyContinue) |
               # Real links only. Every reparse point carries the same
               # attribute, and OneDrive placeholders and deduplicated files
               # would otherwise mark a copy under a synced folder as linked
               # for good, so it was never refreshed again.
               Where-Object { $_.LinkType -in @('SymbolicLink', 'Junction', 'HardLink') } |
               ForEach-Object { $_.FullName })
    if ($links.Count -gt 0) {
        return & $report 'linked' @() @() @() $false $links
    }

    $actual = Get-ClaudExtToolFiles -Root $toolDir
    $missing = @($expected.Keys | Where-Object { -not $actual.ContainsKey($_) } | Sort-Object)
    $changed = @($expected.Keys | Where-Object { $actual.ContainsKey($_) -and $actual[$_] -ne $expected[$_] } | Sort-Object)
    $extra = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) } | Sort-Object)

    $status = if ($missing.Count + $changed.Count + $extra.Count -eq 0) { 'current' } else { 'outdated' }
    return & $report $status $missing $changed $extra $false @()
}

function Sync-ClaudExtTool {
    <#
    .SYNOPSIS
        Brings the tool copy beside an archive in line with the running tool,
        then verifies it.
    .DESCRIPTION
        Only the files that differ are written, and they are copied over in
        place rather than the folder being deleted first: an interrupted copy
        then leaves an older tool behind instead of none. Files that no longer
        belong to the tool are removed afterwards.

        When ClaudExt is itself running from that folder — a restored machine
        backing up to the same drive — nothing is done. Deleting the folder
        first, as the backup used to, deleted the running tool. A copy holding
        a link is left alone too, and reported as unverified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolRoot,
        [Parameter(Mandatory)][string]$Destination
    )

    $ToolRoot = Resolve-ClaudExtFullPath $ToolRoot
    $Destination = Resolve-ClaudExtFullPath $Destination

    $before = Test-ClaudExtTool -ToolRoot $ToolRoot -Destination $Destination
    $action = switch ($before.Status) { 'missing' { 'created' } 'outdated' { 'refreshed' } default { 'none' } }

    if ($action -ne 'none') {
        $source = (Get-Item -LiteralPath $ToolRoot -Force).FullName
        New-Item -ItemType Directory -Path $before.Path -Force | Out-Null

        foreach ($relative in @($before.Missing) + @($before.Changed)) {
            $to = Join-Path $before.Path $relative
            $toDir = Split-Path -Parent $to
            if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
            Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $to -Force
        }
        foreach ($relative in $before.Extra) {
            Remove-Item -LiteralPath (Join-Path $before.Path $relative) -Force
        }
    }

    # A ClaudExt that came as a browser download carries the downloaded-file
    # mark on every file, and a copy keeps it. Under the default execution
    # policy Windows then refuses to run the copy's scripts — on the day it is
    # needed. The copy is for running, so the mark goes.
    if ($IsWindows -and (Test-Path -LiteralPath $before.Path)) {
        Get-ChildItem -LiteralPath $before.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
    }

    $after = Test-ClaudExtTool -ToolRoot $ToolRoot -Destination $Destination
    [pscustomobject]@{
        Action   = $action
        Verified = ($after.Status -eq 'current')
        Files    = $after.Expected
        Changed  = @($before.Missing).Count + @($before.Changed).Count + @($before.Extra).Count
        Path     = $after.Path
        IsSelf   = $after.IsSelf
        Problems = @(@($after.Missing) + @($after.Changed) + @($after.Extra) +
                     @($after.Links | ForEach-Object { "$_ (a link, left untouched)" }))
    }
}
