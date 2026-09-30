function Compare-RestoreCount {
    <#
    .SYNOPSIS
        Compares restored file counts against the counts recorded at backup time.
    .DESCRIPTION
        A partial restore must never be reported as success. Every mismatch
        names its source with expected and actual counts. A count higher than
        expected is reported too — silent duplication is as wrong as silent
        loss.

        The manifest may be an object or a hashtable; both read the same.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ManifestJson,
        [Parameter(Mandatory)][hashtable]$ActualCounts
    )

    $mismatches = foreach ($s in @($ManifestJson.sources)) {
        if ($null -eq $s) { continue }
        $actual = if ($ActualCounts.ContainsKey($s.id)) { [int]$ActualCounts[$s.id] } else { 0 }
        if ($actual -ne [int]$s.files) {
            [pscustomobject]@{ Id = $s.id; Expected = [int]$s.files; Actual = $actual }
        }
    }

    [pscustomobject]@{
        AllMatched = (@($mismatches).Count -eq 0)
        Mismatches = @($mismatches)
    }
}
