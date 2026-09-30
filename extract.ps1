#requires -Version 7.0
<#
.SYNOPSIS
    Archives all local Claude Code state into a single zip.
.DESCRIPTION
    Collects transcripts with each project's memory, skills, settings, prompt
    history, CLAUDE.md, agents, commands and the rest of the Claude folder,
    plus the portable parts of ~/.claude.json and the desktop app config.
    Credentials are never collected, and caches Claude Code rebuilds by
    itself — the plugin folder among them — are left out.

    The sequence itself lives in Invoke-ClaudExtBackup, which the GUI calls too,
    so both entry points stay in step.
.EXAMPLE
    .\extract.ps1 -Destination E:\claude-backup
.EXAMPLE
    .\extract.ps1 -Destination E:\claude-backup -KeepStaging
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [switch]$KeepStaging,
    # Overrides the source registry. Used by tests to exercise the
    # whole pipeline against a handful of files instead of the full corpus.
    [string]$ManifestPath,
    # Where Claude Code keeps its files. Omitted, it is detected:
    # CLAUDE_CONFIG_DIR when set, ~/.claude otherwise.
    [string]$ClaudeDir
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src' 'ClaudExt.psm1') -Force

if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

$manifest = if ($ManifestPath) { Get-ClaudExtManifest -ManifestPath $ManifestPath -ClaudeDir $ClaudeDir }
            else { Get-ClaudExtManifest -ClaudeDir $ClaudeDir }

Write-Host "ClaudExt backup - platform: $($manifest.Platform)" -ForegroundColor Cyan
Write-Host "Claude folder: $($manifest.ClaudeDir)"
Write-Host ''

$onStep = {
    param($Phase, $Message, $Level)
    $colour = if ($Level -eq 'warn') { 'Yellow' } elseif ($Phase -eq 'done') { 'Green' } else { 'Gray' }
    Write-Host "  $Message" -ForegroundColor $colour
}

$result = Invoke-ClaudExtBackup -Destination $Destination -ManifestPath $ManifestPath `
                              -ToolRoot $PSScriptRoot -OnStep $onStep -KeepStaging:$KeepStaging `
                              -ClaudeDir $ClaudeDir

$outsideHome = @($result.ProjectPaths | Where-Object { -not (Test-PathWithinRoot -Path $_ -Root $result.SourceHome) })
if ($outsideHome.Count -gt 0) {
    Write-Host ''
    Write-Host "$($outsideHome.Count) project paths live outside the home directory and will need manual mapping on restore:" -ForegroundColor Yellow
    foreach ($p in $outsideHome) { Write-Host "    $p" -ForegroundColor Yellow }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  Archive : $($result.ArchivePath)"
Write-Host ("  Size    : {0:N1} MB" -f ($result.Bytes / 1MB))
Write-Host "  Entries : $($result.EntryCount)"
if ($result.ProgramCount -gt 0) { Write-Host "  Programs recorded in INVENTORY.md: $($result.ProgramCount)" }
if ($result.Tool) {
    if ($result.Tool.Verified) {
        Write-Host "  ClaudExt beside the archive: $($result.Tool.Files) files, verified"
    }
    else {
        Write-Host "  ClaudExt beside the archive could not be verified: $(@($result.Tool.Problems)[0..4] -join ', ')" -ForegroundColor Yellow
    }
}
if (@($result.Skipped).Count -gt 0) {
    Write-Host "  $(@($result.Skipped).Count) item(s) could not be copied (listed above)." -ForegroundColor Yellow
}
if (@($result.Warnings).Count -gt 0) {
    Write-Host "  $(@($result.Warnings).Count) warning(s), listed above." -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'To restore on the new machine, double-click claudext-tool\ClaudExt.cmd on the backup drive,'
Write-Host 'or from a terminal there (Bypass: files copied from a download are otherwise blocked):'
Write-Host "  pwsh -ExecutionPolicy Bypass -File claudext-tool\import.ps1 -Archive $(Split-Path -Leaf $result.ArchivePath)"
Write-Host ''
Write-Host 'Credentials, .env files and keys were not collected; run /login after restoring.'
Write-Host 'Values you put in an MCP server''s env or in settings.json''s env did travel: the archive is not encrypted.'
