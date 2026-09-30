# Compress-Archive is deliberately not used anywhere in this project: the
# backup exceeds 3 GB and needs Zip64, which System.IO.Compression provides.
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-BackupArchive {
    <#
    .SYNOPSIS
        Zips a staging directory into a single archive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$ArchivePath,
        # Called as ($fraction) while entries are written. CreateFromDirectory
        # would be one opaque call lasting minutes, so entries are added one at
        # a time instead — the archive it produces is the same.
        [scriptblock]$OnProgress
    )

    $SourceDir = Resolve-ClaudExtFullPath $SourceDir
    $ArchivePath = Resolve-ClaudExtFullPath $ArchivePath

    $archiveDir = Split-Path -Parent $ArchivePath
    if ($archiveDir -and -not (Test-Path -LiteralPath $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }

    $source = (Get-Item -LiteralPath $SourceDir -Force).FullName
    $cut = $source.TrimEnd('\', '/').Length
    $files = @(Get-ChildItem -LiteralPath $source -Recurse -File -Force)
    $totalBytes = [math]::Max(1L, ($files | Measure-Object -Property Length -Sum).Sum)

    # Written under a temporary name and moved over the final one only once
    # complete. Deleting the earlier archive first and writing in place meant a
    # failed run left neither the earlier backup nor a usable new one — and a
    # truncated zip under a name that looks finished.
    $partial = $ArchivePath + '.partial'
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($partial, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $written = 0L
            $index = 0
            foreach ($file in $files) {
                # Forward slashes are what the zip format specifies, and what
                # CreateFromDirectory wrote before this.
                $name = $file.FullName.Substring($cut).TrimStart('\', '/').Replace('\', '/')
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $file.FullName, $name, [System.IO.Compression.CompressionLevel]::Optimal)
                $written += $file.Length
                $index++
                if ($OnProgress -and $index % 25 -eq 0) { & $OnProgress ($written / $totalBytes) }
            }
        }
        finally { $zip.Dispose() }
    }
    catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
    try {
        # An earlier archive of the same day may be read-only. File.Move with
        # overwrite refuses it where Remove-Item -Force does not, and the
        # backup then failed after all the work was done.
        if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
        [System.IO.File]::Move($partial, $ArchivePath)
    }
    catch {
        # The .partial is complete at this point, so it is kept and named.
        throw "Could not put the archive in place at ${ArchivePath}: $($_.Exception.Message) The complete archive was left at $partial."
    }
    if ($OnProgress) { & $OnProgress 1.0 }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try { $entryCount = @($zip.Entries | Where-Object { $_.Name }).Count }
    finally { $zip.Dispose() }

    [pscustomobject]@{
        EntryCount = $entryCount
        Bytes      = (Get-Item -LiteralPath $ArchivePath).Length
    }
}

function Test-BackupArchive {
    <#
    .SYNOPSIS
        Verifies an archive opens and reports its entry count.
    .DESCRIPTION
        Called before anything is written to the target system: nothing is
        restored from an archive that does not open.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchivePath)

    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
        return [pscustomobject]@{ Valid = $false; EntryCount = 0; Error = 'No archive selected.' }
    }
    $ArchivePath = Resolve-ClaudExtFullPath $ArchivePath
    if (Test-Path -LiteralPath $ArchivePath -PathType Container) {
        return [pscustomobject]@{ Valid = $false; EntryCount = 0; Error = 'That is a folder, not an archive.' }
    }
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        return [pscustomobject]@{ Valid = $false; EntryCount = 0; Error = 'Archive not found.' }
    }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try { $count = @($zip.Entries | Where-Object { $_.Name }).Count }
        finally { $zip.Dispose() }
        [pscustomobject]@{ Valid = $true; EntryCount = $count; Error = '' }
    }
    catch {
        # The raw text here is a nested .NET message — 'Exception calling
        # "OpenRead" with "1" argument(s): ...' — which tells a person nothing
        # they can act on. Classify it into something short instead.
        $reason = switch -Regex ($_.Exception.Message) {
            'denied|UnauthorizedAccess'   { 'Access to that file is denied.'; break }
            'being used by another|in use' { 'That file is open in another program.'; break }
            'Central Directory|End of Central|not a valid|corrupt' { 'That file is not a zip archive.'; break }
            default                       { 'Archive is not usable.' }
        }
        [pscustomobject]@{ Valid = $false; EntryCount = 0; Error = $reason }
    }
}

function Expand-BackupArchive {
    <#
    .SYNOPSIS
        Extracts an archive into a target directory, returning the file count.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$TargetDir,
        # Called as ($fraction) while entries are extracted.
        [scriptblock]$OnProgress
    )

    $ArchivePath = Resolve-ClaudExtFullPath $ArchivePath
    $TargetDir = Resolve-ClaudExtFullPath $TargetDir

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    # A drive root keeps its separator: 'E:' alone is the current folder on E.
    $root = Get-ClaudExtTrimmedPath $TargetDir
    $rootWithSeparator = if ($root.EndsWith('\') -or $root.EndsWith('/')) { $root }
                         else { $root + [System.IO.Path]::DirectorySeparatorChar }
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase }
                  else { [System.StringComparison]::Ordinal }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = @($zip.Entries)
        $totalBytes = [math]::Max(1L, ($entries | Measure-Object -Property Length -Sum).Sum)
        $done = 0L
        $index = 0
        foreach ($entry in $entries) {
            $destination = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $entry.FullName))

            # ExtractToDirectory refused entries that climb out of the target
            # with '..'; extracting by hand has to keep that promise itself.
            if (-not $destination.StartsWith($rootWithSeparator, $comparison)) {
                throw "Archive entry '$($entry.FullName)' points outside the target folder."
            }

            if (-not $entry.Name) {
                [void][System.IO.Directory]::CreateDirectory($destination)
                continue
            }

            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $true)
            $done += $entry.Length
            $index++
            if ($OnProgress -and $index % 25 -eq 0) { & $OnProgress ($done / $totalBytes) }
        }
    }
    finally { $zip.Dispose() }
    if ($OnProgress) { & $OnProgress 1.0 }

    return $index
}
