# Long operations copy gigabytes. Running one inside a request handler would
# block the listener and freeze the page, so each runs in its own runspace and
# reports progress into a hashtable shared with the caller.

$script:ClaudExtJobs = @{}

function Start-ClaudExtJob {
    <#
    .SYNOPSIS
        Runs a scriptblock in a background runspace and returns its job id.
    .DESCRIPTION
        The body receives two arguments: $Progress, a synchronized hashtable it
        writes status into, and $Arguments, the callers parameters. The ClaudExt
        module is imported into the runspace so job bodies can call the core
        functions.

        Only one job runs at a time. A second request returns $null rather than
        starting: two restores writing the same tree would interleave their
        files and the count check at the end would not catch it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [hashtable]$Arguments = @{},
        # 'backup' or 'restore'. A page that reloads mid-run reads this to
        # decide which side of the interface to reattach to.
        [string]$Kind = ''
    )

    if (Test-ClaudExtJobRunning) { return $null }

    $progress = [hashtable]::Synchronized(@{
        Kind    = $Kind
        Status  = 'running'
        Phase   = ''
        # Step of Steps is which phase is running; Percent is weighted across
        # all of them, so a long phase moves the bar further than a quick one.
        Step    = 0
        Steps   = 0
        Percent = 0
        Message = ''
        # Every message, in order. Polling every half second would otherwise
        # drop any phase that starts and finishes between two polls.
        Log     = @()
        Error   = ''
        Result  = $null
    })

    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ClaudExt.psm1'

    # The body is wrapped so a failure lands in the shared table instead of
    # disappearing into a runspace nobody is watching.
    $wrapper = {
        param($Progress, $Arguments, $ModulePath, $UserBody)
        try {
            Import-Module $ModulePath -Force -ErrorAction SilentlyContinue
            $block = [scriptblock]::Create($UserBody)
            $Progress.Result = & $block $Progress $Arguments
            $Progress.Status = 'completed'
        }
        catch {
            $Progress.Error = $_.Exception.Message
            $Progress.Status = 'failed'
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($wrapper).
        AddArgument($progress).
        AddArgument($Arguments).
        AddArgument($modulePath).
        AddArgument($Body.ToString())

    $id = [guid]::NewGuid().ToString('n').Substring(0, 12)
    $handle = $ps.BeginInvoke()

    $script:ClaudExtJobs[$id] = @{
        Id         = $id
        Started    = [DateTime]::UtcNow
        Progress   = $progress
        PowerShell = $ps
        Handle     = $handle
        Runspace   = $runspace
    }

    return $id
}

function Get-ClaudExtJob {
    <#
    .SYNOPSIS
        Returns a snapshot of a job's progress, or $null if the id is unknown.
    .DESCRIPTION
        Once the runspace has finished, its resources are released. The progress
        table survives, so a page that reloads mid-restore can still read the
        outcome.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)

    if (-not $script:ClaudExtJobs.ContainsKey($Id)) { return $null }

    $job = $script:ClaudExtJobs[$Id]
    $p = $job.Progress

    if ($job.Handle -and $job.Handle.IsCompleted -and $job.PowerShell) {
        try { [void]$job.PowerShell.EndInvoke($job.Handle) } catch { }
        $job.PowerShell.Dispose()
        $job.Runspace.Dispose()
        $job.PowerShell = $null
        $job.Runspace = $null
        $job.Handle = $null

        # A runspace that died without reaching either branch of the wrapper
        # must not be reported as still running for ever.
        if ($p.Status -eq 'running') {
            $p.Status = 'failed'
            if (-not $p.Error) { $p.Error = 'The job ended without reporting a result.' }
        }
    }

    [pscustomobject]@{
        Id      = $Id
        Kind    = $p.Kind
        Status  = $p.Status
        Phase   = $p.Phase
        Step    = $p.Step
        Steps   = $p.Steps
        Percent = $p.Percent
        Message = $p.Message
        Log     = @($p.Log)
        Error   = $p.Error
        Result  = $p.Result
    }
}

function Test-ClaudExtJobRunning {
    <#
    .SYNOPSIS
        True when any job is still executing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return [bool](Get-ClaudExtRunningJobId)
}

function Get-ClaudExtRunningJobId {
    <#
    .SYNOPSIS
        The id of the job still executing, or $null when the queue is idle.
    #>
    [CmdletBinding()]
    param()

    foreach ($id in @($script:ClaudExtJobs.Keys)) {
        $snapshot = Get-ClaudExtJob -Id $id
        if ($snapshot -and $snapshot.Status -eq 'running') { return $id }
    }
    return $null
}

function Get-ClaudExtLatestJobId {
    <#
    .SYNOPSIS
        The job still running, or else the one started most recently.
    .DESCRIPTION
        A page loaded after a job finished still has a result to show: the
        progress table outlives the runspace for as long as the server runs.
    #>
    [CmdletBinding()]
    param()

    $running = Get-ClaudExtRunningJobId
    if ($running) { return $running }
    $latest = @($script:ClaudExtJobs.Values) | Sort-Object { $_.Started } -Descending | Select-Object -First 1
    if ($latest) { return $latest.Id }
    return $null
}

function Clear-ClaudExtJobs {
    <#
    .SYNOPSIS
        Disposes every tracked job. Used between tests and at shutdown.
    #>
    [CmdletBinding()]
    param()

    foreach ($id in @($script:ClaudExtJobs.Keys)) {
        $job = $script:ClaudExtJobs[$id]
        if ($job.PowerShell) {
            try { $job.PowerShell.Stop() } catch { }
            try { $job.PowerShell.Dispose() } catch { }
        }
        if ($job.Runspace) { try { $job.Runspace.Dispose() } catch { } }
    }
    $script:ClaudExtJobs = @{}
}
