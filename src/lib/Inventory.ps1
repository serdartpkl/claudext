function Invoke-SafeCollector {
    <#
    .SYNOPSIS
        Runs one inventory collector, isolating its failures.
    .DESCRIPTION
        A missing or broken package manager must never abort the whole report.
        When -Command is given and that executable is absent, the collector is
        reported as skipped rather than failed.

        Each collector runs in a runspace of its own with a time limit. A
        package manager waiting on a prompt nobody will answer, or a CLI that
        stalls while its application updates, would otherwise hold the whole
        backup at "Building Inventory" for ever. One that overruns is reported
        as failed and left behind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Command,
        [int]$TimeoutSeconds = 120
    )

    if ($Command -and -not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Name = $Name; Succeeded = $false; Skipped = $true; Output = @(); Error = ''
        }
    }

    $failed = {
        param($why)
        [pscustomobject]@{ Name = $Name; Succeeded = $false; Skipped = $false; Output = @(); Error = $why }
    }

    $ps = [powershell]::Create()
    $finished = $false
    try {
        [void]$ps.AddScript($Body.ToString())
        $handle = $ps.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            [void]$ps.BeginStop($null, $null)
            return & $failed "timed out after $TimeoutSeconds seconds"
        }
        $finished = $true
        $output = $ps.EndInvoke($handle)
        [pscustomobject]@{
            Name = $Name; Succeeded = $true; Skipped = $false
            Output = @($output); Error = ''
        }
    }
    catch {
        $finished = $true
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        & $failed $inner.Message
    }
    finally {
        # A collector that overran is still stopping; disposing it here would
        # wait for exactly the thing the time limit was there to avoid.
        if ($finished) { $ps.Dispose() }
    }
}

function Get-ClaudePluginList {
    <#
    .SYNOPSIS
        The plugins settings.json enables, each with where its marketplace
        comes from.
    .DESCRIPTION
        The plugin folder itself is not backed up: it is a cache Claude Code
        rebuilds. This is the record needed to rebuild it by hand if it does
        not — a marketplace added with /plugin marketplace add lives only in
        that cache's registry.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ClaudeDir)

    if (-not $ClaudeDir) { return @() }
    $settingsPath = Join-Path $ClaudeDir 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return @() }
    try { $settings = Read-ClaudExtJson -Path $settingsPath } catch { return @() }
    $enabled = if ($settings -is [System.Collections.IDictionary]) { $settings['enabledPlugins'] }
    if ($enabled -isnot [System.Collections.IDictionary]) { return @() }

    $marketplaces = @{}
    $registry = Join-Path $ClaudeDir 'plugins' 'known_marketplaces.json'
    if (Test-Path -LiteralPath $registry -PathType Leaf) {
        try {
            $known = Read-ClaudExtJson -Path $registry
            foreach ($name in $known.Keys) {
                $src = $known[$name]['source']
                if ($src -is [System.Collections.IDictionary]) {
                    $where = @($src['repo'], $src['url'], $src['path'] | Where-Object { $_ })[0]
                    $marketplaces[$name] = "$($src['source']): $where"
                }
            }
        }
        catch { }
    }

    foreach ($id in $enabled.Keys) {
        if (-not $enabled[$id]) { continue }
        $plugin, $market = ([string]$id).Split('@', 2)
        [pscustomobject]@{
            Plugin      = $plugin
            Marketplace = [string]$market
            Source      = if ($market -and $marketplaces.ContainsKey($market)) { $marketplaces[$market] } else { '' }
        }
    }
}

function Get-InstalledProgram {
    <#
    .SYNOPSIS
        Lists installed programs using whatever mechanism this platform offers.
    .DESCRIPTION
        Windows reads the three registry uninstall hives — verified against a
        real machine, 633 entries. macOS lists application bundles. Linux has no
        single source, so this returns nothing there and the per-manager
        collectors (dpkg, rpm, flatpak) carry the information instead.
    #>
    [CmdletBinding()]
    param()

    switch (Get-ClaudExtPlatform) {
        'Windows' {
            $hives = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            $all = foreach ($hive in $hives) {
                Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName }
            }
            return $all |
                Select-Object DisplayName, DisplayVersion, Publisher |
                Sort-Object DisplayName -Unique
        }
        'macOS' {
            return Get-ChildItem -Path '/Applications' -Filter '*.app' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject]@{
                        DisplayName    = $_.BaseName
                        DisplayVersion = ''
                        Publisher      = ''
                    }
                } | Sort-Object DisplayName -Unique
        }
        default { return @() }
    }
}

function Get-PlatformCollector {
    <#
    .SYNOPSIS
        Returns the package-manager collectors that apply to this platform.
    .DESCRIPTION
        Each entry is a name, the executable that must exist, and the command to
        run. Cross-platform managers appear in every set; OS-specific ones only
        in theirs. Nothing here installs or modifies anything.
    #>
    [CmdletBinding()]
    param()

    $shared = @(
        @{ Name = 'npm global'; Command = 'npm';   Body = { npm ls -g --depth=0 2>$null } }
        @{ Name = 'pip';        Command = 'pip';   Body = { pip list 2>$null } }
        @{ Name = 'uv';         Command = 'uv';    Body = { uv tool list 2>$null } }
        @{ Name = 'bun';        Command = 'bun';   Body = { bun pm ls -g 2>$null } }
        @{ Name = 'pnpm';       Command = 'pnpm';  Body = { pnpm list -g --depth=0 2>$null } }
        @{ Name = 'cargo';      Command = 'cargo'; Body = { cargo install --list 2>$null } }
        @{ Name = 'vscode';     Command = 'code';  Body = { code --list-extensions 2>$null } }
    )

    $specific = switch (Get-ClaudExtPlatform) {
        'Windows' { @(
            @{ Name = 'winget';     Command = 'winget'; Body = { winget list --disable-interactivity 2>$null } }
            @{ Name = 'chocolatey'; Command = 'choco';  Body = { choco list --limit-output 2>$null } }
        ) }
        'macOS' { @(
            @{ Name = 'homebrew';       Command = 'brew'; Body = { brew list --versions 2>$null } }
            @{ Name = 'homebrew casks'; Command = 'brew'; Body = { brew list --cask 2>$null } }
            @{ Name = 'mas';            Command = 'mas';  Body = { mas list 2>$null } }
        ) }
        'Linux' { @(
            @{ Name = 'apt';     Command = 'dpkg';    Body = { dpkg -l 2>$null } }
            @{ Name = 'rpm';     Command = 'rpm';     Body = { rpm -qa 2>$null } }
            @{ Name = 'flatpak'; Command = 'flatpak'; Body = { flatpak list 2>$null } }
            @{ Name = 'snap';    Command = 'snap';    Body = { snap list 2>$null } }
        ) }
        default { @() }
    }

    return @($specific) + @($shared)
}

function New-InventoryReport {
    <#
    .SYNOPSIS
        Writes INVENTORY.md: installed programs plus package manager state.
    .DESCRIPTION
        Read-only by design. Produces no installation script and reads no
        credential files — it is a reminder of what was on the machine, not a
        rebuild tool.

        -PluginsOnly is for a Claude folder that is not this machine's (an old
        disk mounted here): what this machine has installed says nothing about
        the machine that folder came from, so only its plugins are listed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        # Where Claude Code keeps its files, for the list of enabled plugins.
        [AllowEmptyString()][string]$ClaudeDir,
        [switch]$PluginsOnly
    )

    $platform = Get-ClaudExtPlatform
    $plugins = @(Get-ClaudePluginList -ClaudeDir $ClaudeDir)
    $programs = @()
    $collectors = @()
    if (-not $PluginsOnly) {
        $programs = Get-InstalledProgram
        $collectors = foreach ($c in (Get-PlatformCollector)) {
            Invoke-SafeCollector -Name $c.Name -Command $c.Command -Body $c.Body
        }
        $collectors = @($collectors) + @(
            Invoke-SafeCollector -Name 'runtimes' -Body {
                foreach ($c in @('node', 'python', 'python3', 'git', 'docker', 'pwsh')) {
                    $cmd = Get-Command $c -ErrorAction SilentlyContinue
                    if ($cmd) { "$c : $(& $c --version 2>$null | Select-Object -First 1)" }
                }
            }
        )
    }

    $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Machine inventory')
    $lines.Add('')
    $lines.Add("Generated: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
    $lines.Add("Host: $hostName")
    $lines.Add("Platform: $platform")
    $lines.Add('')
    $lines.Add('This report is read-only. It installs nothing and collects no credentials.')
    # A pipe inside a name would end its table cell early.
    $cell = { param($v) ([string]$v).Replace('|', '\|') }
    if ($PluginsOnly) {
        $lines.Add('')
        $lines.Add("The Claude folder backed up ($ClaudeDir) is not this machine's, so this machine's")
        $lines.Add('installed programs are not listed: they say nothing about the machine it came from.')
    }
    else {
        $lines.Add('')
        $lines.Add('## Installed programs')
        $lines.Add('')
        $lines.Add("Total: $(@($programs).Count)")
        $lines.Add('')
        $lines.Add('| Name | Version | Publisher |')
        $lines.Add('|---|---|---|')
        foreach ($p in $programs) {
            $lines.Add("| $(& $cell $p.DisplayName) | $(& $cell $p.DisplayVersion) | $(& $cell $p.Publisher) |")
        }
    }

    if ($plugins.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Claude Code plugins')
        $lines.Add('')
        $lines.Add('Enabled in settings.json. Claude Code normally installs these again by itself. If one is')
        $lines.Add('missing, add its marketplace and install it: `/plugin marketplace add <source>`, then')
        $lines.Add('`/plugin install <plugin>@<marketplace>`.')
        $lines.Add('')
        $lines.Add('| Plugin | Marketplace | Source |')
        $lines.Add('|---|---|---|')
        foreach ($p in $plugins) {
            $lines.Add("| $(& $cell $p.Plugin) | $(& $cell $p.Marketplace) | $(& $cell $p.Source) |")
        }
    }

    foreach ($c in $collectors) {
        if ($c.Skipped -or -not $c.Succeeded) { continue }
        $lines.Add('')
        $lines.Add("## $($c.Name)")
        $lines.Add('')
        $lines.Add('```')
        foreach ($line in $c.Output) { $lines.Add([string]$line) }
        $lines.Add('```')
    }

    if (@($collectors).Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Collector status')
        $lines.Add('')
        $lines.Add('| Collector | Status |')
        $lines.Add('|---|---|')
        foreach ($c in $collectors) {
            $status = if ($c.Skipped) { 'skipped (not installed)' }
                      elseif ($c.Succeeded) { 'ok' }
                      else { "failed: $($c.Error)" }
            $lines.Add("| $($c.Name) | $status |")
        }
    }

    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllLines($OutputPath, $lines, [System.Text.UTF8Encoding]::new($false))

    [pscustomobject]@{
        ProgramCount     = @($programs).Count
        PluginCount      = $plugins.Count
        CollectorsRun    = @($collectors | Where-Object Succeeded | Select-Object -ExpandProperty Name)
        CollectorsFailed = @($collectors | Where-Object { -not $_.Succeeded -and -not $_.Skipped } |
                             Select-Object -ExpandProperty Name)
    }
}
