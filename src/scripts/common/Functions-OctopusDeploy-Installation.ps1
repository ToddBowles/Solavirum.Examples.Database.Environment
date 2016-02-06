function _GetTentacleServiceName 
{
    param ( [string]$instanceName )

    if ($instanceName -eq "Tentacle") 
    {
        return "OctopusDeploy Tentacle"
    } 
    else 
    {
        return "OctopusDeploy Tentacle: $instanceName"
    }
}

function Download-UrlToLocalFileRobustly 
{
    param 
    (
        [string]$url,
        [string]$saveAs,
        [int]$DI_TotalWaitTimeSeconds=180,
        [int]$DI_WaitTimeBetweenAttemptsSeconds=30
    )
 
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $downloader = New-Object System.Net.WebClient

    $result = @{
        "Url"=$url;
    }

    Write-Verbose "Check for machine proxy via environment variable [HTTP_PROXY]"
    $environmentProxySetting = $env:HTTP_PROXY
    if (-not ([string]::IsNullOrEmpty($environmentProxySetting)))
    {
        Write-Verbose "Proxy was detected in environment variable. Configuring client to use proxy [$environmentProxySetting]"
        $WebProxy = New-Object System.Net.WebProxy($environmentProxySetting, $true)
        $downloader.Proxy = $WebProxy
        $result.Add("UsedProxy", $true)
        $result.Add("ProxySetting", $environmentProxySetting)
    }

    . "$rootDirectoryPath\scripts\common\Functions-Waiting.ps1"


    $downloadScript = {
        Write-Verbose "Downloading [$url] to [$saveAs]"
        $downloader.DownloadFile($url, $saveAs)
        return $true
    }

    Wait -ScriptToFillActualValue $downloadScript -Condition { $actual -ne $null -and $actual -eq $true } -IncrementSeconds $DI_WaitTimeBetweenAttemptsSeconds -TimeoutSeconds $DI_TotalWaitTimeSeconds

    $result.Add("Downloaded", (Get-Item -Path $saveAs))

    return New-Object PSObject $result
}

function _InvokeAndAssert {
    param ($block) 
  
    & $block | Write-Verbose
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) 
    {
        throw "Command returned exit code $LASTEXITCODE"
    }
}

function _GetMyPrivateIPAddress
{
    Write-Verbose "Getting private IP address"

    $ip = (Get-NetAdapter | Get-NetIPAddress | ? AddressFamily -eq 'IPv4').IPAddress
    return $ip
}
 
function Install-Tentacle
{
    param 
    (

    )

    Write-Verbose "Beginning Tentacle installation" 
  
    # OTH change. We needed to install a known version of the Octopus Tentacle, because the V3 tentacle wasnt working properly.
    $tentacleDownloadUrl = "https://download.octopusdeploy.com/octopus/Octopus.Tentacle.2.6.5.1010-x64.msi"
    if ([IntPtr]::Size -eq 4) 
    {
        $tentacleDownloadUrl = "https://download.octopusdeploy.com/octopus/Octopus.Tentacle.2.6.5.1010.msi"
    }

    mkdir "$($env:SystemDrive)\Octopus" -ErrorAction SilentlyContinue

    $tentaclePath = "$($env:SystemDrive)\Octopus\Tentacle.msi"
    if ((test-path $tentaclePath) -ne $true) 
    {
        Write-Verbose "Downloading latest Octopus Tentacle MSI from [$tentacleDownloadUrl] to [$tentaclePath]"
        Download-UrlToLocalFileRobustly $tentacleDownloadUrl $tentaclePath
    }
  
    Write-Verbose "Installing MSI..."
    $msiLog = "$($env:SystemDrive)\Octopus\Tentacle.msi.log"
    $msiExitCode = (Start-Process -FilePath "msiexec.exe" -ArgumentList "/i $tentaclePath /quiet /l*v $msiLog" -Wait -Passthru).ExitCode
    Write-Verbose "Tentacle MSI installer returned exit code $msiExitCode"
    if ($msiExitCode -ne 0) 
    {
        throw "Installation of the Tentacle MSI failed; MSIEXEC exited with code: $msiExitCode. View the log at $msiLog"
    }
 
    Write-Verbose "Tentacle installation complete."
}

function Register-Tentacle 
{
    param 
    (
        [string]$instanceName="Tentacle",
        [Parameter(Mandatory=$True)]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$True)]
        [string]$octopusServerUrl,
        [string]$octopusServerThumbprint="947FD05262243C279609D030DB2990E7E9EBCB4B",
        [Parameter(Mandatory=$True)]
        [string[]]$environments,
        [Parameter(Mandatory=$True)]
        [string[]]$roles,
        [int]$port=10933,
        [string]$DefaultApplicationDirectory="C:\Applications"
    )
 
    if ($port -eq 0)
    {
        $port = 10933
    }

    pushd "${env:ProgramFiles}\Octopus Deploy\Tentacle"

       Write-Verbose "Open port $port on Windows Firewall"
    _InvokeAndAssert { & netsh.exe advfirewall firewall add rule protocol=TCP dir=in localport=$port action=allow name="Octopus Tentacle: $instanceName" }
  
    pushd "${env:ProgramFiles}\Octopus Deploy\Tentacle"
 
    $tentacleHomeDirectory = "$($env:SystemDrive)\Octopus"
    $tentacleAppDirectory = $DefaultApplicationDirectory
    $tentacleConfigFile = "$($env:SystemDrive)\Octopus\$instanceName\Tentacle.config"
    _InvokeAndAssert { & .\tentacle.exe create-instance --instance $instanceName --config $tentacleConfigFile --console }
    _InvokeAndAssert { & .\tentacle.exe configure --instance $instanceName --home $tentacleHomeDirectory --console }
    _InvokeAndAssert { & .\tentacle.exe configure --instance $instanceName --app $tentacleAppDirectory --console }
    _InvokeAndAssert { & .\tentacle.exe configure --instance $instanceName --port $port --console }
    _InvokeAndAssert { & .\tentacle.exe new-certificate --instance $instanceName --console }
    _InvokeAndAssert { & .\tentacle.exe configure --instance $instanceName --trust $octopusServerThumbprint --console }

    $ipAddress = _GetMyPrivateIPAddress
    $ipAddress = $ipAddress.Trim()
 
    Write-Verbose "Private IP address: $ipAddress"
    Write-Verbose "Configuring and registering Tentacle"

    # OTH change. Customising the name of the tentacle to line up with the AWS instance name (if possible). Will default to the
    # Computer name otherwise.
    $tentacleName = $env:COMPUTERNAME
    try
    {
        $response = Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/instance-id" -UseBasicParsing
        if ($response.StatusCode -eq 200) { $tentacleName = $response.Content }
    }
    catch { }
    $registerArguments = @("register-with", "--instance", $instanceName, "--server", $octopusServerUrl, "--name", $tentacleName, "--publicHostName", $ipAddress, "--apiKey", $octopusApiKey, "--comms-style", "TentaclePassive", "--force", "--console")

    foreach ($environment in $environments) 
    {
        foreach ($e2 in $environment.Split(',')) 
        {
            $registerArguments += "--environment"
            $registerArguments += $e2.Trim()
        }
    }
    foreach ($role in $roles) 
    {
        foreach ($r2 in $role.Split(',')) 
        {
            $registerArguments += "--role"
            $registerArguments += $r2.Trim()
        }
    }

    Write-Verbose "Registering with arguments: $registerArguments"
    _InvokeAndAssert { & .\tentacle.exe ($registerArguments) }

    _InvokeAndAssert { & .\tentacle.exe service --install --instance $instanceName --start --console }

    popd
    Write-Verbose "Tentacle Registration Complete"
}