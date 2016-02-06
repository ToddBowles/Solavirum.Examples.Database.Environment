function _StopAndDisableService()
{
    param
    (
        [string]$serviceName
    )
    
    $computerName = "localhost"
    $service = Get-WmiObject Win32_Service -Filter "Name=`"$serviceName`"" -ComputerName $computerName -Ea 0

    if ($service)
    {
        if ($service.StartMode -ne "Disabled")
        {
            $result = $service.ChangeStartMode("Disabled").ReturnValue
            if($result)
            {
                "Failed to disable the '$serviceName' service on $computerName. The return value was $result."
            }
            else {"Success to disable the '$serviceName' service on $computerName."}
            
            if ($service.State -eq "Running")
            {
                $result = $service.StopService().ReturnValue
                if ($result)
                {
                    "Failed to stop the '$serviceName' service on $computerName. The return value was $result."
                }
                else {"Success to stop the '$serviceName' service on $computerName."}
            }
        }
        else {"The '$serviceName' service on $computerName is already disabled."}
    }
    else {"Failed to retrieve the service '$serviceName' from $computerName."}
}

$services = @("wuauserv", "TrustedInstaller")
foreach ($serviceName in $services)
{
    _StopAndDisableService $serviceName
}

