[CmdletBinding()]
param
(
    [string]$password
)

$ErrorActionPreference = "Stop"

Write-Verbose "Resetting local admin password"
([adsi]("WinNT://$env:COMPUTERNAME/administrator, user")).psbase.invoke('SetPassword', $password)