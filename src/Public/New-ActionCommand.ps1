function New-ActionCommand {
    <#
        .SYNOPSIS
        Creates an [ActionCommand] object with the provided method in $Target.

        .PARAMETER MethodName
        Name of the method in $Target.

        .PARAMETER IsAsync
        This signals the equivalent command to be invoked in another runspace if $true or on the console thread.

        .PARAMETER Target
        The class object of the method.

        .PARAMETER Throttle
        The max number of times the equivalent method command can be running at a given time.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$MethodName,
        [bool]$IsAsync = $true,
        [Parameter(Mandatory)]
        [object]$Target,
        [int]$Throttle = 1
    )

    $Method = if ($Target.GetType().Name -eq 'PSCustomObject') {
        $Target.psobject.$MethodName
    } else {
        $Target.$MethodName
    }

    [ActionCommand]::new($Method, $IsAsync, $Target, $Throttle)
}
