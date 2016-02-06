function Coalesce
{
    [CmdletBinding()]
    param
    (
        $a,
        $b
    )

    if ($a -eq $null) { return $b }
    return $a
}