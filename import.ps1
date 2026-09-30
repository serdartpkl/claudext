#requires -Version 7.0
<#
.SYNOPSIS
    Restores Claude Code state from a backup archive, remapping paths as needed.
.DESCRIPTION
    Verifies the archive before writing anything. When the home directory has
    changed, builds an old-to-new path mapping, shows it, and requires explicit
    confirmation. Paths outside the old home cannot be inferred and are asked
    for one by one.

    Nothing already on the machine is lost: a file the restore would replace
    is kept in <Claude folder>\claudext-replaced\<time> first.

    The restore sequence itself lives in Invoke-ClaudExtRestore, which the GUI
    calls too. Only the interactive confirmation is specific to this entry point.
.EXAMPLE
    .\import.ps1 -Archive E:\claude-backup\claude-backup-DESKTOP-2026-08-11-1430.zip
.EXAMPLE
    .\import.ps1 -Archive E:\backup.zip -DryRun
.EXAMPLE
    .\import.ps1 -Archive E:\backup.zip -TargetRoot E:\restore-test
    Restores into E:\restore-test as a stand-in home and touches nothing else.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Archive,
    # Where the archive is extracted. Omitted: '.claudext-work' inside
    # -TargetRoot when that is given, otherwise a folder in the temp directory
    # that is removed completely afterwards. A folder given here must be empty
    # or one ClaudExt made: it is emptied.
    [string]$WorkDir,
    [string]$ManifestPath,
    # Where Claude Code keeps its files on this machine. Omitted, it is
    # detected: CLAUDE_CONFIG_DIR when set, ~/.claude otherwise.
    [string]$ClaudeDir,
    # Restore into this existing folder as a stand-in home instead of the
    # live one. Nothing outside it is written.
    [string]$TargetRoot,
    [switch]$DryRun,
    # Accepts the automatically resolved mapping without prompting and keeps
    # any path that could not be inferred as it was. For unattended runs.
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src' 'ClaudExt.psm1') -Force

if ($TargetRoot) {
    $TargetRoot = Resolve-ClaudExtFullPath $TargetRoot
    if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        throw "That folder does not exist: $TargetRoot"
    }
}
# The Claude folder may be missing — a fresh machine has none — but it
# cannot be a file. Checked before anything is extracted.
if ($ClaudeDir) {
    $ClaudeDir = Resolve-ClaudExtFullPath $ClaudeDir
    if (Test-Path -LiteralPath $ClaudeDir -PathType Leaf) { throw "That is a file, not a folder: $ClaudeDir" }
}

Write-Host 'Inspecting archive...' -ForegroundColor Cyan
$inspect = Invoke-ApiArchive -Parameters @{ Path = $Archive }
if (-not $inspect.Ok) { throw $inspect.Error }

$backupManifest = $inspect.Data.Manifest
Write-Host "  $($inspect.Data.EntryCount) entries, archive opens cleanly"

$sourceHome = $backupManifest.sourceHome
$targetHome = Get-UserHome

Write-Host ''
$takenOn = if ($backupManifest.sourceHost) { " on $($backupManifest.sourceHost)" } else { '' }
Write-Host "Backup taken : $($backupManifest.createdAt)$takenOn ($($backupManifest.platform))"
Write-Host "Source home  : $sourceHome"
Write-Host "Target home  : $targetHome"
Write-Host "Claude folder: $((Get-ClaudeLocation -ConfigDir $ClaudeDir).ConfigDir)"
if ($TargetRoot) { Write-Host "Writing into : $TargetRoot (a stand-in home; nothing else is touched)" -ForegroundColor Cyan }

if ($backupManifest.platform -ne (Get-ClaudExtPlatform)) {
    Write-Host ''
    Write-Host "WARNING: the backup was taken on $($backupManifest.platform), restoring onto $(Get-ClaudExtPlatform)." -ForegroundColor Yellow
    Write-Host 'Cross-platform restore is untested. Review the mapping carefully.' -ForegroundColor Yellow
}

$mapping = @{}
$mappingTable = Invoke-ApiMapping -Parameters @{ Path = $Archive }
if (-not $mappingTable.Ok) { throw $mappingTable.Error }
$table = @($mappingTable.Data.Rows)

if ($mappingTable.Data.RemapNeeded) {
    Write-Host ''
    Write-Host 'Home directory changed. Path mapping required.' -ForegroundColor Yellow
}
elseif ($table.Count -eq 0) {
    Write-Host 'Home directories match - no remapping needed.' -ForegroundColor Green
}

if ($table.Count -gt 0) {
    $resolved = @($table | Where-Object Resolved)
    if ($resolved.Count -gt 0) {
        Write-Host ''
        Write-Host '  Resolved automatically:'
        foreach ($e in $resolved) {
            Write-Host "    $($e.From)"
            Write-Host "      -> $($e.To)"
            $mapping[$e.From] = $e.To
        }
    }

    # A folder the archive names itself is asked about even when the home did
    # not change: the archive alone never picks where files are written.
    $unresolved = @($table | Where-Object { -not $_.Resolved })
    if ($unresolved.Count -gt 0) {
        Write-Host ''
        Write-Host '  Could not be inferred - decide where each one lives now:' -ForegroundColor Yellow
        foreach ($e in $unresolved) {
            Write-Host ''
            if ($e.Kind -eq 'auto-memory') { Write-Host '    Auto memory folder, where the archive says it was:' -ForegroundColor Cyan }
            Write-Host "    $($e.From)"
            # A path kept where it was maps to itself, so a mapping of its
            # parent cannot carry it along.
            if ($Yes) {
                if ($e.Suggested) {
                    Write-Host "      -> $($e.Suggested) (the home mapping; -Yes was given)" -ForegroundColor Yellow
                    $mapping[$e.From] = $e.Suggested
                }
                elseif ($e.Kind -eq 'auto-memory') {
                    # The archive alone never picks where files are written.
                    Write-Host '      not restored: only the archive says where it goes. Run without -Yes to choose.' -ForegroundColor Yellow
                }
                else {
                    Write-Host '      kept as it was (-Yes was given, so nothing is guessed)' -ForegroundColor Yellow
                    $mapping[$e.From] = $e.From
                }
                continue
            }
            $prompt = if ($e.Suggested) { "      New full path (Enter takes $($e.Suggested), '-' keeps the old path)" }
                      else { '      New full path (blank keeps the old path as it is)' }
            while ($true) {
                $answer = ([string](Read-Host $prompt)).Trim()
                if (-not $answer -and $e.Suggested) { $answer = $e.Suggested }
                if (-not $answer -or $answer -eq '-') { $mapping[$e.From] = $e.From; break }
                # The same check and the same normalising the GUI's answers
                # get: a drive root keeps its separator, '..' and doubled
                # separators are resolved.
                try {
                    $checked = ConvertTo-RestoreMapping -Mapping @{ ($e.From) = $answer }
                    $mapping[$e.From] = @($checked.Values)[0]
                    break
                }
                catch { Write-Host '      That is not a full path, e.g. D:\Work\project. Try again.' -ForegroundColor Yellow }
            }
        }
    }

    Write-Host ''
    $moving = @($mapping.Keys | Where-Object { $mapping[$_] -cne $_ }).Count
    Write-Host "$moving mappings will be applied."
    if (-not $Yes) {
        $confirm = Read-Host 'Proceed? (yes/no)'
        if ($confirm -ne 'yes') {
            Write-Host 'Aborted, nothing was written.' -ForegroundColor Yellow
            exit 1
        }
    }
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run: stopping before any file is written.' -ForegroundColor Yellow
    exit 0
}

if (-not $TargetRoot -and (Test-ClaudeRunning)) {
    Write-Host ''
    Write-Host 'Claude is running. Close every Claude Code session and the Claude app before restoring:' -ForegroundColor Yellow
    Write-Host 'a running Claude writes ~/.claude.json back when it exits, over the restored project records.' -ForegroundColor Yellow
    if (-not $Yes) {
        $confirm = Read-Host 'Restore anyway? (yes/no)'
        if ($confirm -ne 'yes') {
            Write-Host 'Aborted, nothing was written.' -ForegroundColor Yellow
            exit 1
        }
    }
}

Write-Host ''
Write-Host 'Restoring...' -ForegroundColor Cyan

$onStep = {
    param($Phase, $Message, $Level)
    $colour = if ($Level -eq 'warn') { 'Yellow' } else { 'Gray' }
    Write-Host "  $Message" -ForegroundColor $colour
}

$restoreArgs = @{
    Archive = $Archive; Mapping = $mapping; ManifestPath = $ManifestPath
    ClaudeDir = $ClaudeDir; TargetRoot = $TargetRoot; OnStep = $onStep
}
if ($WorkDir) { $restoreArgs.WorkDir = $WorkDir }
$result = Invoke-ClaudExtRestore @restoreArgs

Write-Host ''
if ($result.AllMatched) {
    Write-Host 'All source counts match the manifest.' -ForegroundColor Green
}
else {
    Write-Host 'RESTORE INCOMPLETE:' -ForegroundColor Red
    foreach ($m in $result.Mismatches) {
        Write-Host "  $($m.Id): expected $($m.Expected), restored $($m.Actual)" -ForegroundColor Red
    }
}

if ($result.ReplacedCount -gt 0) {
    Write-Host ''
    Write-Host "$($result.ReplacedCount) file(s) that were already here are kept in:" -ForegroundColor Yellow
    Write-Host "  $($result.ReplacedDir)"
}

if ($result.InventoryPath -and (Test-Path -LiteralPath $result.InventoryPath)) {
    # Reported, never copied elsewhere. Writing into the user's Desktop or any
    # other directory they did not name is not this tool's business.
    Write-Host ''
    Write-Host "Installed-software list: $($result.InventoryPath)"
}
else {
    Write-Host ''
    Write-Host 'Installed-software list: INVENTORY.md inside the archive.'
}

Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Start Claude Code - it reinstalls plugins from settings.json.'
Write-Host '  2. Run /login to restore authentication (credentials are not backed up by design).'
Write-Host '  3. Open one of your projects and check that its memory came back:'
Write-Host '     ~/.claude/projects/<encoded path>/memory/'

if (-not $result.AllMatched) { exit 1 }
