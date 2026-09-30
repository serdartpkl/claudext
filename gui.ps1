#requires -Version 7.0
<#
.SYNOPSIS
    Opens the ClaudExt browser interface.
.DESCRIPTION
    Starts a loopback HTTP server and opens the default browser at it. Nothing
    is installed and nothing is downloaded: HttpListener ships with .NET, so
    this works on a freshly reinstalled machine that has only PowerShell.

    The server binds to 127.0.0.1 only and requires a random token that is
    generated at startup and passed in the URL. Any other tab in the browser
    can reach a localhost port, so without the token it would be reachable by
    a page the user merely happened to visit.

    Both wizards call the same functions the CLI uses, so extract.ps1 and
    import.ps1 remain available and behave identically.
.EXAMPLE
    .\gui.ps1
.EXAMPLE
    .\gui.ps1 -Port 8899 -NoBrowser
#>
[CmdletBinding()]
param(
    # Fixed port. Omit to let the OS pick a free one.
    [int]$Port = 0,
    # Print the URL without launching a browser.
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src' 'ClaudExt.psm1') -Force

function Get-FreePort {
    # Bind to port 0, ask the OS what it handed out, release it. A race is
    # possible in principle but the window is microseconds and the listener
    # would simply fail to start, which is visible rather than silent.
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $chosen = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $chosen
}

if ($Port -eq 0) { $Port = Get-FreePort }

$token = New-ClaudExtToken
$pagePath = Join-Path $PSScriptRoot 'src' 'gui' 'index.html'
if (-not (Test-Path -LiteralPath $pagePath)) { throw "Page not found: $pagePath" }

$url = "http://127.0.0.1:$Port/?t=$token"

Write-Host ''
Write-Host 'ClaudExt' -ForegroundColor Cyan
Write-Host "  $url"
Write-Host ''
Write-Host '  The token in that URL is what authorises the interface.' -ForegroundColor Gray
Write-Host '  Requests without it are refused, including from other browser tabs.' -ForegroundColor Gray
Write-Host ''
Write-Host '  Ctrl+C stops the server, and a job still running stops with it.' -ForegroundColor Gray
Write-Host '  Wait for Backed Up! or Restored! before pressing it.' -ForegroundColor Gray
Write-Host ''

if (-not $NoBrowser) {
    try { Start-Process $url }
    catch { Write-Host "  Could not open a browser. Paste the URL above." -ForegroundColor Yellow }
}

try {
    Start-ClaudExtServer -Port $Port -Token $token -PagePath $pagePath
}
finally {
    Clear-ClaudExtJobs
}
