function ConvertTo-ProjectDirName {
    <#
    .SYNOPSIS
        Encodes a working directory path the way Claude Code names its
        transcript directories.
    .DESCRIPTION
        Every character outside [A-Za-z0-9-] becomes a dash. This is lossy and
        MUST NOT be reversed by parsing: 'C:\a\b' and 'C:/a/b' and 'C:\a b'
        can all collapse to the same name. Real paths are recovered from the
        'cwd' field inside transcripts and from MANIFEST.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    return [regex]::Replace($Path, '[^A-Za-z0-9-]', '-')
}

# Claude Code shortens a project folder name longer than this and appends a
# hash of the full path. The hash cannot be recomputed here, so such a folder
# keeps the name it has.
$script:ClaudExtMaxProjectDirName = 200

function Get-ClaudExtPathComparison {
    <#
    .SYNOPSIS
        The string comparison paths on this platform use.
    #>
    [CmdletBinding()]
    param()

    if ($IsWindows) { return [System.StringComparison]::OrdinalIgnoreCase }
    return [System.StringComparison]::Ordinal
}

function Test-ClaudExtWindowsStylePath {
    <#
    .SYNOPSIS
        True for a path written the Windows way: a drive letter or a UNC share.
    .DESCRIPTION
        Decided from the text, not from the platform running now: an archive
        taken on Windows carries Windows paths wherever it is restored, and
        those compare without regard to case.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Path)

    return [bool]($Path -match '^[A-Za-z]:([\\/]|$)' -or $Path.StartsWith('\\'))
}

function Get-ClaudExtTrimmedPath {
    <#
    .SYNOPSIS
        Drops a trailing separator, unless the path is a root.
    .DESCRIPTION
        'D:\x\' becomes 'D:\x', but 'D:\' stays 'D:\': 'D:' alone means the
        current directory on D, a different place, and would encode to the
        folder name 'D-' where Claude Code uses 'D--'. '/' stays '/'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path -match '^[A-Za-z]:[\\/]*$') { return $Path.Substring(0, 2) + $(if ($Path.Contains('/') -and -not $Path.Contains('\')) { '/' } else { '\' }) }
    if ($Path -match '^[\\/]+$') { return $Path.Substring(0, 1) }
    return $Path.TrimEnd('\', '/')
}

function Get-ClaudExtSharedPrefixLength {
    <#
    .SYNOPSIS
        How much of a new path can keep the spelling of the old one.
    .DESCRIPTION
        The length of the prefix two paths share, ignoring case and separator
        style when asked to, cut back to the last separator inside it so no
        folder name is half one spelling and half the other. Equal paths share
        everything. Used so 'c:\users\old\x' becomes 'c:\users\new\x' rather
        than 'C:\Users\new\x': in ~/.claude.json and history.jsonl the path is a
        lookup key, and a lowercase-drive key must stay a lowercase-drive key.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$From,
        [Parameter(Mandatory)][AllowEmptyString()][string]$To,
        [switch]$IgnoreCase
    )

    $a = $From.Replace('\', '/'); $b = $To.Replace('\', '/')
    $comparison = if ($IgnoreCase) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($a.Equals($b, $comparison)) { return $From.Length }
    $n = [math]::Min($a.Length, $b.Length)
    $i = 0
    while ($i -lt $n -and [string]::Compare($a, $i, $b, $i, 1, $comparison) -eq 0) { $i++ }
    # Nothing shared is nothing shared, even when the old path starts with a
    # separator: '/home/old' and 'C:\Users\new' share no prefix at all.
    if ($i -eq 0) { return 0 }
    return $a.LastIndexOf('/', $i - 1) + 1
}

function Get-ClaudExtPathKey {
    <#
    .SYNOPSIS
        One key per folder: a Windows path compared whatever its separators,
        case or trailing separator, any other path exactly.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Path)

    $Path = ([string]$Path).Trim()
    if (-not $Path) { return '' }
    if (Test-ClaudExtWindowsStylePath $Path) {
        # Windows opens 'x.' and 'x ' as 'x', in every segment.
        $segments = (Get-ClaudExtTrimmedPath $Path.Replace('/', '\')) -split '\\'
        $clean = for ($i = 0; $i -lt $segments.Count; $i++) {
            if ($i -eq 0 -or $segments[$i] -in '.', '..') { $segments[$i] } else { $segments[$i].TrimEnd('.', ' ') }
        }
        return (Get-ClaudExtTrimmedPath ($clean -join '\')).ToLowerInvariant()
    }
    return Get-ClaudExtTrimmedPath $Path
}

function Test-PathWithinRoot {
    <#
    .SYNOPSIS
        True when a path resolves to a root directory or somewhere inside it.
    .DESCRIPTION
        Both sides are normalised first, and a separator must follow the root:
        'C:\rootother' is not inside 'C:\root' merely because it shares the
        prefix as a string, and 'C:\root\..\other' is not inside it at all.
        Case is ignored on Windows only.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    try {
        $fullPath = Get-ClaudExtTrimmedPath ([System.IO.Path]::GetFullPath($Path))
        $fullRoot = Get-ClaudExtTrimmedPath ([System.IO.Path]::GetFullPath($Root))
    }
    catch { return $false }

    $comparison = Get-ClaudExtPathComparison
    if ($fullPath.Equals($fullRoot, $comparison)) { return $true }
    # A drive root already ends in its separator: everything on C: is under 'C:\'.
    $boundary = if ($fullRoot.EndsWith('\') -or $fullRoot.EndsWith('/')) { $fullRoot }
                else { $fullRoot + [System.IO.Path]::DirectorySeparatorChar }
    return $fullPath.StartsWith($boundary, $comparison)
}

function ConvertTo-MappedPath {
    <#
    .SYNOPSIS
        Translates one real path through a restore mapping, or returns $null
        when no entry applies.
    .DESCRIPTION
        The longest matching entry wins, and only on a separator boundary:
        with 'C:\Users\ada' mapped, 'C:\Users\adam\x' is left alone. Windows
        paths match without regard to case or separator style, so 'c:/users/ADA'
        is under 'C:\Users\ada'. The remainder keeps its names and takes the
        separator of the new root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Mapping
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Mapping.Count -eq 0) { return $null }

    $candidate = (Get-ClaudExtTrimmedPath $Path).Replace('\', '/')
    $froms = @($Mapping.Keys | Sort-Object -Property Length -Descending)
    foreach ($from in $froms) {
        $f = (Get-ClaudExtTrimmedPath ([string]$from)).Replace('\', '/')
        if (-not $f) { continue }
        $windows = Test-ClaudExtWindowsStylePath $from
        $comparison = if ($windows) { [System.StringComparison]::OrdinalIgnoreCase }
                      else { [System.StringComparison]::Ordinal }
        $boundary = if ($f.EndsWith('/')) { $f } else { $f + '/' }
        if (-not ($candidate.Equals($f, $comparison) -or $candidate.StartsWith($boundary, $comparison))) { continue }

        $to = Get-ClaudExtTrimmedPath ([string]$Mapping[$from])
        $toSlash = $to.Replace('\', '/')
        $separator = if ($to.Contains('\') -or (Test-ClaudExtWindowsStylePath $to)) { '\' } else { '/' }

        # The part old and new share keeps the candidate's own spelling.
        $shared = Get-ClaudExtSharedPrefixLength -From $f -To $toSlash -IgnoreCase:$windows
        $head = $candidate.Substring(0, $shared) + $toSlash.Substring($shared)
        $rest = $candidate.Substring($f.Length)
        if ($head.EndsWith('/') -and $rest.StartsWith('/')) { $rest = $rest.Substring(1) }
        elseif (-not $head.EndsWith('/') -and $rest -and -not $rest.StartsWith('/')) { $rest = '/' + $rest }
        $result = $head + $rest
        if ($separator -eq '\') { $result = $result.Replace('/', '\') }
        return $result
    }
    return $null
}

function ConvertTo-RestoreMapping {
    <#
    .SYNOPSIS
        Checks and normalises a path mapping before anything is written with it.
    .DESCRIPTION
        Every target must be an absolute path on this machine. A relative one
        would be encoded into a transcript folder name that no working
        directory can ever produce, and would be written into every record.
        Targets take this platform's separator and lose a trailing one: 'D:\x\'
        would otherwise become the folder name 'D--x-' and double the
        backslash in every rewritten path.

        Old paths are kept as the archive recorded them, apart from a trailing
        separator; they belong to the machine the backup came from, which may
        use the other separator.

        Throws with every offending entry named. Returns a new table.
    #>
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Mapping = @{})

    $result = @{}
    $bad = [System.Collections.Generic.List[string]]::new()
    # Two old paths that name one folder are one decision. Given two different
    # answers, neither may silently win — an archive could list the same
    # folder twice, once where a person decided and once where nobody looked.
    $answers = @{}
    foreach ($from in @($Mapping.Keys)) {
        # A drive root keeps its separator: 'D:' alone means the current
        # directory on D, not its root.
        $f = Get-ClaudExtTrimmedPath ([string]$from).Trim()
        if ($f -match '^[A-Za-z]:$') { $f += '\' }
        if (-not $f) { continue }
        $key = Get-ClaudExtPathKey $f
        $answer = Get-ClaudExtPathKey ([string]$Mapping[$from])
        if ($answers.ContainsKey($key)) {
            if ($answers[$key] -ne $answer) { $bad.Add("$f (two different answers for one folder)") }
            continue
        }
        $answers[$key] = $answer

        $to = ([string]$Mapping[$from]).Trim()
        if (-not $to) { $bad.Add("$f (no new path)"); continue }
        # A path kept where it was maps to itself. It belongs to the machine
        # the backup came from and is taken as it is, whatever this platform
        # would call a full path.
        if ((Get-ClaudExtTrimmedPath $to) -ceq $f) { $result[$f] = $f; continue }
        $to = ConvertTo-CanonicalPath $to
        if (-not [System.IO.Path]::IsPathFullyQualified($to)) { $bad.Add("$f -> $to (not a full path)"); continue }
        # Doubled separators, '..' and '.' segments, trailing dots and spaces:
        # Windows opens such a path as the plain one, and Claude Code names its
        # folder after the plain one, so that is what gets written.
        $result[$f] = Get-ClaudExtTrimmedPath ([System.IO.Path]::GetFullPath($to))
    }
    if ($bad.Count -gt 0) {
        throw "These paths need a full new location: $($bad -join '; ')"
    }
    return $result
}

function Get-ClaudExtMinimalMapping {
    <#
    .SYNOPSIS
        The same mapping without the entries a shorter one already implies.
    .DESCRIPTION
        Every project under the old home arrives as its own entry, and each
        says exactly what the home entry says about it. Each one still costs
        the rewrite three more patterns to try at every position of gigabytes
        of text. An entry goes when an entry for one of its parent folders
        translates it to the same place, character for character. A path kept
        where it was (mapped to itself) goes too when nothing above it moves,
        since it then changes nothing.

        Only entries for a parent are weighed, never one for the same folder
        spelled another way — two spellings would each imply the other and
        both would go.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Mapping)

    # Each entry by its folder key. The nearest parent that has an entry is
    # found by walking up the path, which keeps this linear in the number of
    # entries — hundreds of recorded working directories are not unusual.
    $byKey = @{}
    foreach ($from in $Mapping.Keys) {
        $key = Get-ClaudExtPathKey ([string]$from)
        if (-not $byKey.ContainsKey($key)) { $byKey[$key] = $from }
    }

    $result = @{}
    foreach ($from in @($Mapping.Keys)) {
        $to = [string]$Mapping[$from]
        $path = Get-ClaudExtTrimmedPath ([string]$from)
        $parent = $null
        $up = $path
        while ($true) {
            # The parent by the string, whichever separator this path uses.
            $cut = $up.TrimEnd('\', '/').LastIndexOfAny([char[]]@('\', '/'))
            if ($cut -lt 0) { break }
            $next = Get-ClaudExtTrimmedPath $up.Substring(0, $cut + 1)
            if ($next -eq $up) { break }
            $up = $next
            $candidate = $byKey[(Get-ClaudExtPathKey $up)]
            if ($null -ne $candidate) { $parent = $candidate; break }
        }
        $implied = if ($null -ne $parent) { ConvertTo-MappedPath -Path ([string]$from) -Mapping @{ $parent = $Mapping[$parent] } } else { $null }
        if ($implied -and $implied -ceq $to) { continue }
        if (-not $implied -and (Get-ClaudExtTrimmedPath $to) -ceq $path) { continue }
        $result[$from] = $Mapping[$from]
    }
    return $result
}

function Resolve-ProjectDirName {
    <#
    .SYNOPSIS
        Works out what a transcript folder should be called after a restore.
    .DESCRIPTION
        Claude Code files a project's sessions and memory under a folder named
        after the project's path, with every character outside [A-Za-z0-9-]
        turned into a dash. Git worktrees and subfolders share the folder of
        their repository, so the path inside a transcript is often not the one
        the folder was named after — on the machine this was written for, 12 of
        44 folders disagreed with their own first session.

        So the folder is renamed from the path it was really named after when
        the backup knew it (KnownPath, matched when the backup was taken).
        Otherwise the encoded name itself is translated: the encoding works
        character by character, so an old prefix can be swapped for a new one
        on a dash boundary. That second route is a best effort — '-' stands for
        a separator, a space or a dot alike — and is used only where nothing
        better is known.

        A name Claude Code shortened with a hash, or a new name that would
        need shortening, stays as it is: the hash cannot be recomputed.

        Returns Name and How: 'known', 'prefix', 'unchanged' or 'too-long'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$KnownPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Mapping
    )

    $result = { param($n, $how) [pscustomobject]@{ Name = $n; How = $how } }
    if ($Mapping.Count -eq 0) { return & $result $Name 'unchanged' }
    if ($Name.Length -gt $script:ClaudExtMaxProjectDirName) { return & $result $Name 'too-long' }

    $newName = $null
    if ($KnownPath) {
        $mapped = ConvertTo-MappedPath -Path $KnownPath -Mapping $Mapping
        if ($mapped) { $newName = ConvertTo-ProjectDirName $mapped }
        else { return & $result $Name 'unchanged' }
        $how = 'known'
    }
    else {
        # A root keeps its separator, and so its trailing dash: 'D:\' is
        # 'D--', and 'D:\Work' is 'D--Work' with no further dash between.
        # Whether a side is a root is read off the path: a folder named
        # 'Ortağı' also encodes to a trailing dash, and is no root.
        $isRoot = { param($p) $t = Get-ClaudExtTrimmedPath ([string]$p); $t.EndsWith('\') -or $t.EndsWith('/') }
        $encoded = @($Mapping.Keys | ForEach-Object {
            [pscustomobject]@{
                From     = ConvertTo-ProjectDirName (Get-ClaudExtTrimmedPath ([string]$_))
                To       = ConvertTo-ProjectDirName (Get-ClaudExtTrimmedPath ([string]$Mapping[$_]))
                FromRoot = & $isRoot $_
                ToRoot   = & $isRoot $Mapping[$_]
            }
        } | Sort-Object { $_.From.Length } -Descending)
        foreach ($e in $encoded) {
            $comparison = if ($e.From -match '^[A-Za-z]-') { [System.StringComparison]::OrdinalIgnoreCase }
                          else { [System.StringComparison]::Ordinal }
            if ($Name.Equals($e.From, $comparison)) { $newName = $e.To; break }
            # The dash after the old path stands for its separator; a root
            # carries that separator already.
            $boundary = if ($e.FromRoot) { $e.From } else { $e.From + '-' }
            if ($Name.StartsWith($boundary, $comparison)) {
                $rest = $Name.Substring($e.From.Length)
                if ($e.FromRoot -and -not $e.ToRoot) { $rest = '-' + $rest }
                elseif (-not $e.FromRoot -and $e.ToRoot) { $rest = $rest.Substring(1) }
                $newName = $e.To + $rest
                break
            }
        }
        if (-not $newName) { return & $result $Name 'unchanged' }
        $how = 'prefix'
    }

    if ($newName.Length -gt $script:ClaudExtMaxProjectDirName) { return & $result $Name 'too-long' }
    if ($newName -ceq $Name) { return & $result $Name 'unchanged' }
    return & $result $newName $how
}

function Get-RestoreRelativePath {
    <#
    .SYNOPSIS
        A path's place relative to the root it was written under, for mirroring
        it somewhere else.
    .DESCRIPTION
        Relative to the restore root when there is one, otherwise to the home.
        Anything else keeps its drive as the first folder, so two roots never
        collide.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Root
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    foreach ($base in @($Root, (Get-UserHome))) {
        if (-not $base) { continue }
        if (Test-PathWithinRoot -Path $full -Root $base) {
            $b = [System.IO.Path]::GetFullPath($base).TrimEnd('\', '/')
            return $full.Substring($b.Length).TrimStart('\', '/')
        }
    }
    $pathRoot = [System.IO.Path]::GetPathRoot($full)
    # A share keeps server and share as two folders, so '\\srv\share1' and
    # '\\srvs\hare1' stay apart. A drive becomes its letter.
    $first = if ($pathRoot.StartsWith('\\') -or $pathRoot.StartsWith('//')) {
                 Join-Path 'UNC' ($pathRoot.Trim('\', '/').Replace('/', '\'))
             }
             else { $pathRoot -replace '[^A-Za-z0-9]', '' }
    if (-not $first) { $first = 'root' }
    return Join-Path $first $full.Substring($pathRoot.Length).TrimStart('\', '/')
}

function Get-UserHome {
    <#
    .SYNOPSIS
        Returns the current user's home directory.
    .DESCRIPTION
        $HOME is PowerShell's automatic variable and resolves correctly on all
        three platforms: USERPROFILE on Windows, the POSIX home elsewhere.
        Using it instead of $env:USERPROFILE keeps this function portable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $HOME
}

function Get-ClaudExtPlatform {
    <#
    .SYNOPSIS
        Returns 'Windows', 'Linux' or 'macOS'.
    .DESCRIPTION
        Drives per-platform path selection in the manifest and the choice of
        inventory collectors. $IsWindows/$IsLinux/$IsMacOS are automatic
        variables in PowerShell 6+.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($IsWindows) { return 'Windows' }
    if ($IsMacOS)   { return 'macOS'   }
    if ($IsLinux)   { return 'Linux'   }
    throw 'Unsupported platform.'
}

function ConvertTo-CanonicalPath {
    <#
    .SYNOPSIS
        Rewrites a path to this platform's separator and drops a trailing one.
    .DESCRIPTION
        Claude stores the same directory in more than one form: transcripts use
        backslashes on Windows while claude.json sometimes uses forward slashes.
        On the source machine 16 of 52 project paths came back slash-separated.
        Left alone, one project is counted twice and its home prefix stops
        matching, which would send a restore asking the user to map paths that
        need no mapping.

        Only the separator is touched. Case is preserved, since these strings
        are also compared against real directory names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    if ((Get-ClaudExtPlatform) -eq 'Windows') {
        return Get-ClaudExtTrimmedPath $Path.Replace('/', '\')
    }
    return Get-ClaudExtTrimmedPath $Path.Replace('\', '/')
}

function Expand-ClaudExtPath {
    <#
    .SYNOPSIS
        Expands a leading '~/' in a manifest path against the current home.
    .DESCRIPTION
        Accepts both separators so manifest entries can be written with forward
        slashes on every platform. Join-Path emits the native separator.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        # Where ~/.claude really is, and its .claude.json. Given, the Claude
        # paths are re-rooted there; everything else stays under the home.
        [string]$ClaudeDir,
        [string]$ClaudeJson
    )

    $normal = $Path.Replace('\', '/')
    if ($ClaudeJson -and $normal -eq '~/.claude.json') { return $ClaudeJson }
    if ($ClaudeDir) {
        if ($normal -eq '~/.claude') { return $ClaudeDir }
        if ($normal.StartsWith('~/.claude/')) { return Join-Path $ClaudeDir $normal.Substring(10) }
    }

    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return Join-Path (Get-UserHome) $Path.Substring(2)
    }
    return $Path
}

function Resolve-ClaudExtFullPath {
    <#
    .SYNOPSIS
        Makes a path absolute against PowerShell's current location, expanding
        a leading '~'.
    .DESCRIPTION
        .NET calls resolve a relative path against the process working
        directory, which PowerShell does not move when the location changes;
        cmdlets resolve it against the location. Mixing the two sent an archive
        to one folder and its staging copy to another. Paths that reach both
        kinds of call go through here first. A path that does not exist yet is
        fine, and so is one on a drive that is not there.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $p = $Path.Trim()
    if ($p -eq '~') { $p = Get-UserHome }
    elseif ($p.StartsWith('~/') -or $p.StartsWith('~\')) { $p = Join-Path (Get-UserHome) $p.Substring(2) }

    try { $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
    catch { }
    return [System.IO.Path]::GetFullPath($p)
}

function Get-ClaudeLocation {
    <#
    .SYNOPSIS
        Finds where Claude Code keeps its files on this machine.
    .DESCRIPTION
        Claude Code reads its configuration directory from CLAUDE_CONFIG_DIR
        when that is set and uses ~/.claude otherwise. The rule is the same on
        Windows, macOS and Linux — only the home directory differs, and
        Get-UserHome already accounts for that. A folder the caller names wins
        over both.

        In the default layout .claude.json sits in the home, beside the
        directory. A relocated directory keeps its own copy inside. For a named
        folder the inside copy is preferred and the one beside it is the
        fallback, which is what an old disk mounted on a new machine looks like.

        A folder that does not exist is reported, not thrown: a restore onto a
        fresh machine writes into a directory that is not there yet.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ConfigDir)

    $userHome = Get-UserHome
    $default = Join-Path $userHome '.claude'
    $fromEnv = [string]$env:CLAUDE_CONFIG_DIR
    $comparison = Get-ClaudExtPathComparison

    # Absolute before anything else. A relative or '~' folder used to be kept
    # as typed, and every file copied from it was then cut at the wrong length:
    # the staged paths came out scrambled while the file count still matched.
    $absolute = {
        param($p)
        $full = Resolve-ClaudExtFullPath $p
        if ([System.IO.Path]::GetPathRoot($full) -eq $full) { return $full }
        return $full.TrimEnd('\', '/')
    }
    $same = { param($a, $b) [string]::Equals($a, $b, $comparison) }

    if (-not [string]::IsNullOrWhiteSpace($ConfigDir)) {
        $dir = & $absolute $ConfigDir
        # Naming the folder detection would have found is not a choice, and
        # must not change which .claude.json is read.
        $source = if (& $same $dir $default) { 'default' }
                  elseif ($fromEnv -and (& $same $dir (& $absolute $fromEnv))) { 'env' }
                  else { 'chosen' }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        $dir = & $absolute $fromEnv
        $source = 'env'
    }
    else {
        $dir = $default
        $source = 'default'
    }

    $found = [bool](Test-Path -LiteralPath $dir -PathType Container)

    # A relocated folder keeps its own .claude.json inside, and that is the one
    # Claude Code reads. The file beside the folder is borrowed only for a
    # folder picked by hand that exists and has no copy inside — an old disk
    # mounted on another machine — never for CLAUDE_CONFIG_DIR and never for a
    # folder that is still to be created, where it would be some other
    # profile's file.
    $claudeJson = Join-Path $userHome '.claude.json'
    if ($source -ne 'default') {
        $claudeJson = Join-Path $dir '.claude.json'
        $parent = Split-Path -Parent $dir
        if ($source -eq 'chosen' -and $found -and $parent -and -not (Test-Path -LiteralPath $claudeJson)) {
            $beside = Join-Path $parent '.claude.json'
            if (Test-Path -LiteralPath $beside) { $claudeJson = $beside }
        }
    }

    [pscustomobject]@{
        Platform    = Get-ClaudExtPlatform
        ConfigDir   = $dir
        ClaudeJson  = $claudeJson
        Source      = $source
        Found       = $found
        # A file where the folder should be is neither found nor creatable.
        IsFile      = [bool](Test-Path -LiteralPath $dir -PathType Leaf)
        HasProjects = [bool](Test-Path -LiteralPath (Join-Path $dir 'projects') -PathType Container)
    }
}
