# [NoRunspaceAffinity()]
class ViewModelBase : PSCustomObject, System.ComponentModel.INotifyPropertyChanged {
    # INotifyPropertyChanged Implementation
    [ComponentModel.PropertyChangedEventHandler]$PropertyChanged

    add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        $this.psobject.PropertyChanged = [Delegate]::Combine($this.psobject.PropertyChanged, $handler)
    }

    remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        $this.psobject.PropertyChanged = [Delegate]::Remove($this.psobject.PropertyChanged, $handler)
    }

    RaisePropertyChanged([string]$propname) {
        if ($this.psobject.PropertyChanged) {
            $evargs = [System.ComponentModel.PropertyChangedEventArgs]::new($propname)
            $this.psobject.PropertyChanged.Invoke($this, $evargs)
        }
    }
    # End INotifyPropertyChanged Implementation

    ViewModelBase() {
        $this.psobject.UpdateWithDispatcherDelegate = $this.psobject.CreateDelegate($this.psobject.UpdateWithDispatcher)
        $this.psobject.AddPropertyChangedToProperties()
    }

    ViewModelBase([bool]$AddDefault) {
        $this.psobject.UpdateWithDispatcherDelegate = $this.psobject.CreateDelegate($this.psobject.UpdateWithDispatcher)
        if ($AddDefault) { $this.psobject.AddPropertyChangedToProperties() }
    }

    [void]AddPropertyChangedToProperties() {
        $this.psobject.AddPropertyChangedToProperties($null)
    }

    [void]AddPropertyChangedToProperties([string[]]$Exclude) {
        $PropertiesToExclude = 'PropertyChanged', 'Dispatcher', 'ViewModelThread', 'LastAction', 'UpdateWithDispatcherDelegate' + $Exclude
        $this.psobject.psobject.Members.Where({
                $_.MemberType -eq 'Property' -and
                $_.IsSettable -eq $true -and
                $_.IsGettable -eq $true -and
                $_.Name -notin $PropertiesToExclude
            }
        ).ForEach(
            {
                $ProperName = if ($_.Name.StartsWith('_')) { $_.Name.Remove(0, 1) } else { $_.Name }
                $Splat = @{
                    Name = $ProperName
                    MemberType = 'ScriptProperty'
                    Value = [scriptblock]::Create('return ,$this.psobject.{0}' -f $_.Name)
                    SecondValue = [scriptblock]::Create(('param($value)
                        $this.psobject.{0} = $value
                        $this.psobject.RaisePropertyChanged("{1}")' -f $_.Name, $ProperName)
                    )
                }
                $this | Add-Member @Splat
            }
        )
    }

    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method) {
        return $this.psobject.CreateDelegate($Method, $this)
    }

    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method, $Target) {
        $reflectionMethod = if ($Target.GetType().Name -eq 'PSCustomObject') {
            $Target.psobject.GetType().GetMethod($Method.Name)
        } else {
            $Target.GetType().GetMethod($Method.Name)
        }
        $parameterTypes = [System.Linq.Enumerable]::Select($reflectionMethod.GetParameters(), [func[object, object]] { $args[0].parametertype })
        $concatMethodTypes = $parameterTypes + $reflectionMethod.ReturnType
        $delegateType = [System.Linq.Expressions.Expression]::GetDelegateType($concatMethodTypes)
        $delegate = [delegate]::CreateDelegate($delegateType, $Target, $reflectionMethod.Name)
        return $delegate
    }

    [void]UpdateView([pscustomobject]$UpdateValue) {
        if ($null -eq $UpdateValue) { return }
        $this.psobject.InvokeDispatcher($UpdateValue)
    }

    hidden [void]UpdateWithDispatcher($UpdateValue) {
        $UpdateValue.psobject.Properties | ForEach-Object {
            try {
                $this.$($_.Name) = $_.Value
            } catch {
                Write-Warning ('Tried to update class property that does not exist: {0}' -f $_.Name)
            }
        }
    }

    hidden [void]InvokeDispatcher($UpdateValue) {
        $this.psobject.Dispatcher.BeginInvoke(9, $this.psobject.UpdateWithDispatcherDelegate, $UpdateValue)
    }

    [System.Threading.Tasks.Task]StartAsync($MethodToRunAsync, [ViewModelBase]$Target, $CommandParameter, $ActionCommand) {
        $Powershell = [powershell]::Create()
        $Powershell.RunspacePool = $Target.psobject.ViewModelThread['Pool'] # Will use a default runspace if ViewModelThread is $null

        $Delegate = if ($null -eq $CommandParameter -and $ActionCommand.psobject.Throttle -gt 0) {
            {
                param($NoContextMethod, $ActionCommand)
                try {
                    $NoContextMethod.Invoke()
                    $null = $ActionCommand.psobject.Dispatcher.InvokeAsync($ActionCommand.psobject.RemoveWorkerDelegate)
                    # Pipeline output can be received in $LastAction.Result
                } catch { throw $_ }
            }
        } elseif ($null -eq $CommandParameter -and $ActionCommand.psobject.Throttle -eq 0) {
            {
                param($NoContextMethod)
                try {
                    $NoContextMethod.Invoke()
                } catch { throw $_ }
            }
        } elseif ($null -ne $CommandParameter -and $ActionCommand.psobject.Throttle -eq 0) {
            {
                param($NoContextMethod, $CommandParameter)
                try {
                    $NoContextMethod.Invoke($CommandParameter)
                } catch { throw $_ }
            }
        } else {
            {
                param($NoContextMethod, $ActionCommand, $CommandParameter)
                try {
                    $NoContextMethod.Invoke($CommandParameter)
                    $ActionCommand.psobject.Dispatcher.InvokeAsync($ActionCommand.psobject.RemoveWorkerDelegate)
                } catch { throw $_ }
            }
        }

        $NoContext = $Delegate.Ast.GetScriptBlock()

        $null = $Powershell.AddScript($NoContext)
        $null = $Powershell.AddParameter('NoContextMethod', $MethodToRunAsync)
        if ($null -ne $CommandParameter) { $null = $Powershell.AddParameter('CommandParameter', $CommandParameter) }
        if ($ActionCommand.psobject.Throttle -gt 0) { $null = $Powershell.AddParameter('ActionCommand', $ActionCommand) }
        $Handle = $Powershell.BeginInvoke()

        $EndInvokeDelegate = $this.psobject.CreateDelegate($Powershell.EndInvoke, $Powershell) # Not needed with pwsh
        $Task = [System.Threading.Tasks.Task]::Factory.FromAsync($Handle, $EndInvokeDelegate)
        $this.psobject.LastAction = $Task

        return $Task
    }

    $Dispatcher #= [System.Windows.Threading.Dispatcher]::CurrentDispatcher # requires types to be loaded in ScriptsToProcess
    [System.Collections.Concurrent.ConcurrentDictionary[string, System.Management.Automation.Runspaces.RunspacePool]]$ViewModelThread
    [System.Threading.Tasks.Task]$LastAction
    $UpdateWithDispatcherDelegate
}
