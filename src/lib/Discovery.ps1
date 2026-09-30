function Get-ClaudExtSourceFiles {
    <#
    .SYNOPSIS
        Every file a directory source takes, as FileInfo objects.
    .DESCRIPTION
        ExcludeTop entries match only names directly under the root, and are
        applied before descending. That is what lets one source take
        everything in the Claude folder apart from what other sources, or
        nobody, should take — without walking gigabytes of transcripts just to
        throw them away, and without dropping a 'cache' folder that happens to
        sit deep inside an agent's files.

        A folder that is a link (a junction, or a symbolic link) is followed
        at every depth — an agents/team folder linked in from a dotfiles repo
        is part of what the user sees there — except when it leads back into
        a folder already on the way down, which would never end. What cannot
        be listed or followed is added to -Skipped with the reason, like a
        file that cannot be read, rather than silently left out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Exclude = @(),
        [string[]]$ExcludeTop = @(),
        [System.Collections.Generic.List[string]]$Skipped
    )

    $note = { param($Path, $Why) if ($null -ne $Skipped) { $Skipped.Add("$Path ($Why)") } }
    # Exclude entries match a file or folder name at any depth, wildcards
    # included: 'logs', '*.pid', '.env.*'. By name alone is enough — a folder
    # that matches is never entered, so every folder above an entry has
    # already been checked.
    $isExcluded = {
        param($Item)
        foreach ($pattern in $Exclude) { if ($Item.Name -like $pattern) { return $true } }
        return $false
    }

    # Where a folder really is: the link's final target, or $null when it is
    # not a link. A OneDrive placeholder is a reparse point but not a link,
    # and reads as an ordinary folder.
    $realOf = {
        param([System.IO.DirectoryInfo]$Dir)
        if (-not ($Dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
        $target = $Dir.ResolveLinkTarget($true)
        if ($null -eq $target) { return $null }
        return $target
    }

    $rootInfo = [System.IO.DirectoryInfo]::new($Root)
    $rootReal = try { & $realOf $rootInfo } catch { $null }
    $rootReal = if ($rootReal) { $rootReal.FullName } else { $rootInfo.FullName }

    # Depth first, each folder carrying where it really is and the real
    # folders a link was followed from on the way down: a link whose target
    # contains any of them leads back into itself.
    $pending = [System.Collections.Generic.Stack[object]]::new()
    $pending.Push([pscustomobject]@{ Dir = $rootInfo; Real = $rootReal; Chain = @(); Top = $true })

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        try { $entries = $current.Dir.GetFileSystemInfos() }
        catch {
            & $note $current.Dir.FullName "could not be listed: $($_.Exception.InnerException.Message ?? $_.Exception.Message)"
            continue
        }

        foreach ($entry in $entries) {
            if ($current.Top) {
                $skip = $false
                foreach ($pattern in $ExcludeTop) { if ($entry.Name -like $pattern) { $skip = $true; break } }
                if ($skip) { continue }
            }
            if (& $isExcluded $entry) { continue }

            if ($entry -is [System.IO.FileInfo]) { $entry; continue }

            $real = [System.IO.Path]::Combine($current.Real, $entry.Name)
            $chain = $current.Chain
            try { $target = & $realOf $entry }
            catch { & $note $entry.FullName "a link that could not be followed: $($_.Exception.Message)"; continue }
            if ($null -ne $target) {
                if (-not $target.Exists) { & $note $entry.FullName 'a link to a folder that is not there'; continue }
                $chain = @($current.Chain) + $current.Real
                $loops = $false
                foreach ($c in $chain) { if (Test-PathWithinRoot -Path $c -Root $target.FullName) { $loops = $true; break } }
                if ($loops) { & $note $entry.FullName "a link back into $($target.FullName), not followed"; continue }
                $real = $target.FullName
            }
            $pending.Push([pscustomobject]@{ Dir = $entry; Real = $real; Chain = $chain; Top = $false })
        }
    }
}

function Get-SourceStat {
    <#
    .SYNOPSIS
        Measures a backup source: whether it exists, how many files, how many bytes.
    .DESCRIPTION
        A missing source is reported as Found=$false rather than throwing: a
        per-platform manifest entry that omits this OS yields an empty path, and
        a directory such as downloads/ may simply not exist yet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [string[]]$Exclude = @(),
        [string[]]$ExcludeTop = @(),
        [System.Collections.Generic.List[string]]$Skipped
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Found = $false; IsFile = $false; FileCount = 0; ByteCount = [long]0
        }
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{
            Found = $true; IsFile = $true; FileCount = 1; ByteCount = [long]$item.Length
        }
    }

    # Absolute root for the same reason as in Copy-Source: exclusions match
    # path segments cut from absolute FullName values.
    $count = 0
    $bytes = [long]0
    Get-ClaudExtSourceFiles -Root $item.FullName -Exclude $Exclude -ExcludeTop $ExcludeTop -Skipped $Skipped |
        ForEach-Object {
            $count++
            $bytes += $_.Length
        }

    [pscustomobject]@{
        Found = $true; IsFile = $false; FileCount = $count; ByteCount = $bytes
    }
}
