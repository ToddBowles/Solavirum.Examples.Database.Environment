function Wait
{
    [CmdletBinding()]
    param
    (
        [scriptblock]$ScriptToFillActualValue,
        [scriptblock]$Condition,
        [int]$TimeoutSeconds=30,
        [int]$IncrementSeconds=2
    )

    write-verbose "Wait: Waiting for the output of the script block [$ScriptToFillActualValue] to meet the condition [$Condition]"

    $totalWaitTimeSeconds = 0
    while ($true)
    {
        try
        {
            $actual = & $ScriptToFillActualValue
        }
        catch
        {
            Write-Verbose "Wait: An error occurred while evaluating the script to get the actual value [$ScriptToFillActualValue]. As a result, the actual value will be undefined (NULL) for condition evaluation"
            Write-Verbose "Wait: Error details [$_]"
        }

        try
        {
            $result = & $condition
        }
        catch
        {
            Write-Verbose "Wait: An error occurred while evaluating the condition [$condition] (Variable:actual = [$actual]) to determine if the wait is over"
            Write-Verbose "Wait: Error details [$_]"

            $result = $false
        }

        
        if ($result)
        {
            write-verbose "Wait: The output of the script block [$ScriptToFillActualValue] (Variable:actual = [$actual]) met the condition [$condition]"
            return $actual
        }

        write-verbose "Wait: The current output of the condition [$condition] (Variable:actual = [$actual]) is [$result]. Waiting [$IncrementSeconds] and then possibly trying again (depending on timeout)"

        Sleep -Seconds $IncrementSeconds
        $totalWaitTimeSeconds = $totalWaitTimeSeconds + $IncrementSeconds

        if ($totalWaitTimeSeconds -ge $TimeoutSeconds)
        {
            throw "The output of the script block [$ScriptToFillActualValue] (Variable:actual = [$actual]) did not meet the condition [$Condition] after [$totalWaitTimeSeconds] seconds. Wait time does not include operation execution time (only time spent waiting)"
        }
    }
}