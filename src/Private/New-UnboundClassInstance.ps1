$script:Powershell = $null

function New-UnboundClassInstance ([type]$Type, [object[]]$Arguments = $null, [scriptblock]$Definition, [bool]$ShowErrors = $true) {
    if ($null -eq $script:Powershell) {
        $script:Powershell = [powershell]::Create()
        $script:Powershell.AddScript({
                function New-UnboundClassInstance ([type]$Type, [object[]]$Arguments = $null) {
                    [activator]::CreateInstance($Type, $Arguments)
                }
            }.Ast.GetScriptBlock()
        ).Invoke()
        $script:Powershell.Commands.Clear()
    }

    if ($Definition) {
        $null = $script:Powershell.AddScript($Definition).Invoke()
        $script:Powershell.Commands.Clear()
    }

    try {
        if ($null -eq $Arguments) { $Arguments = @() }
        $result = $script:Powershell.AddCommand('New-UnboundClassInstance').
        AddParameter('Type', $type).
        AddParameter('Arguments', $Arguments).
        Invoke()
        return $result
    } finally {
        $script:Powershell.Commands.Clear()
        if ($ShowErrors) {
            $script:Powershell.Streams.Error.ReadAll() | Write-Error
        }
    }
}
