function Copy-Source {
    <#
    .SYNOPSIS
        Copies a source into the staging area, honouring exclude patterns, and
        returns how many files were copied.
    .DESCRIPTION
        A missing source returns 0 rather than throwing: a per-platform
        manifest entry that omits this OS yields an empty path, and a folder
        such as agents/ may simply not exist.

        Claude Code keeps writing while a backup runs. A file that disappears
        between being listed and being copied is skipped, and so is one that
        cannot be read, and a folder that cannot be listed; each is added to
        -Skipped, so the caller can say which. None aborts gigabytes of work —
        the manifest records what was actually staged, so the archive stays
        self-consistent either way.

        -Outcome, when given, is filled with what was found at the moment of
        the copy: Found, and IsFile. A measurement taken minutes earlier can
        be out of date — history.jsonl is created by the first prompt — and a
        restore that believes a file was a folder writes it into one.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$TargetDir,
        [string[]]$Exclude = @(),
        [string[]]$ExcludeTop = @(),
        # Called as ($filesCopied, $bytesCopied) every few files, so a caller
        # can move a progress bar through a source that holds thousands.
        [scriptblock]$OnFile,
        # Collects what could not be copied, with the reason.
        [System.Collections.Generic.List[string]]$Skipped,
        [hashtable]$Outcome
    )

    if ($null -ne $Outcome) { $Outcome.Found = $false; $Outcome.IsFile = $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return 0 }

    [void][System.IO.Directory]::CreateDirectory($TargetDir)

    $copyOne = {
        param($From, $To)
        try {
            [System.IO.File]::Copy($From, $To, $true)
            [System.IO.File]::SetLastWriteTimeUtc($To, [System.IO.File]::GetLastWriteTimeUtc($From))
            return $true
        }
        catch {
            if ($null -ne $Skipped) {
                $why = if (-not [System.IO.File]::Exists($From)) { 'gone before it could be copied' }
                       else { $_.Exception.InnerException.Message ?? $_.Exception.Message }
                $Skipped.Add("$From ($why)")
            }
            return $false
        }
    }

    $item = Get-Item -LiteralPath $Path -Force
    if ($null -ne $Outcome) { $Outcome.Found = $true; $Outcome.IsFile = -not $item.PSIsContainer }
    if (-not $item.PSIsContainer) {
        if (& $copyOne $item.FullName (Join-Path $TargetDir $item.Name)) { return 1 }
        return 0
    }

    # Each file's place under the source is cut from its absolute FullName, so
    # the root has to be absolute too. Cut by the length of a relative path,
    # every staged path came out scrambled while the file count still matched.
    $root = $item.FullName.TrimEnd('\', '/')

    $copied = 0
    $bytes = 0L
    Get-ClaudExtSourceFiles -Root $item.FullName -Exclude $Exclude -ExcludeTop $ExcludeTop -Skipped $Skipped |
        ForEach-Object {
            $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $destination = Join-Path $TargetDir $relative
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
            if (-not (& $copyOne $_.FullName $destination)) { return }
            $copied++
            $bytes += $_.Length
            if ($OnFile -and $copied % 25 -eq 0) { & $OnFile $copied $bytes }
        }
    if ($OnFile) { & $OnFile $copied $bytes }

    return $copied
}
