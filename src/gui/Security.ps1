function New-ClaudExtToken {
    <#
    .SYNOPSIS
        Generates a random bearer token for the local server.
    .DESCRIPTION
        32 bytes from the cryptographic RNG, rendered as lowercase hex. This is
        the only thing standing between the API and any other tab in the user's
        browser, so it does not come from Get-Random.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $bytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Test-ClaudExtToken {
    <#
    .SYNOPSIS
        Compares a supplied token against the expected one in fixed time.
    .DESCRIPTION
        A short-circuiting comparison returns faster the earlier it finds a
        mismatch, which lets a caller recover the token one character at a time
        by measuring response times. This walks every byte regardless and
        accumulates differences, so the duration carries no information about
        where the mismatch was.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Provided,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Expected
    )

    if ([string]::IsNullOrEmpty($Provided) -or [string]::IsNullOrEmpty($Expected)) {
        return $false
    }

    $a = [System.Text.Encoding]::UTF8.GetBytes($Provided)
    $b = [System.Text.Encoding]::UTF8.GetBytes($Expected)

    # Length itself is not a secret, but comparing different lengths byte by
    # byte would index out of range, so it is checked up front.
    if ($a.Length -ne $b.Length) { return $false }

    $diff = 0
    for ($i = 0; $i -lt $a.Length; $i++) {
        $diff = $diff -bor ($a[$i] -bxor $b[$i])
    }
    return ($diff -eq 0)
}

function Test-ClaudExtOrigin {
    <#
    .SYNOPSIS
        True when a request's Origin header is this server's own, or absent.
    .DESCRIPTION
        Blocks cross-site requests: a page on another origin that POSTs to the
        API carries its own Origin, which will not match. Same-origin fetches
        and plain navigation send no Origin at all, and those are allowed —
        the token is what authorises them.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Origin,
        [Parameter(Mandatory)][string]$SelfOrigin
    )

    if ([string]::IsNullOrWhiteSpace($Origin)) { return $true }
    return ($Origin.TrimEnd('/') -eq $SelfOrigin.TrimEnd('/'))
}
