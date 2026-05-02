class ActionCommand : ViewModelBase, System.Windows.Input.ICommand {
    # ICommand Implementation
    [System.EventHandler]$InternalCanExecuteChanged
    add_CanExecuteChanged([EventHandler] $value) {
        $this.psobject.InternalCanExecuteChanged = [Delegate]::Combine($this.psobject.InternalCanExecuteChanged, $value)
    }

    remove_CanExecuteChanged([EventHandler] $value) {
        $this.psobject.InternalCanExecuteChanged = [Delegate]::Remove($this.psobject.InternalCanExecuteChanged, $value)
    }

    [bool]CanExecute([object]$CommandParameter) {
        if ($this.psobject.Throttle -gt 0) { return ($this.psobject.Workers -lt $this.psobject.Throttle) }
        if ($this.psobject.CanExecuteAction) { return $this.psobject.CanExecuteAction.Invoke() }
        return $true
    }

    [void]Execute([object]$CommandParameter) {
        if ($this.psobject.Throttle -gt 0) { $this.Workers++ }

        if ($this.psobject.IsAsync) {
            if ($this.psobject.ActionObject) {
                $this.psobject.LastAction = $this.psobject.StartAsync($this.psobject.ActionObject, $this.psobject.Target, $CommandParameter, $this)
            } else {
                $this.psobject.LastAction = $this.psobject.StartAsync($this.psobject.Action, $this.psobject.Target, $null, $this)
            }
        } else {
            if ($this.psobject.ActionObject) {
                $this.psobject.ActionObject.Invoke($CommandParameter)
            } else {
                $this.psobject.Action.Invoke()
            }
            if ($this.psobject.Throttle -gt 0) { $this.psobject.RemoveWorker() }
        }
    }
    # End ICommand Implementation

    ActionCommand([System.Management.Automation.PSMethod]$Action, [bool]$IsAsync, [ViewModelBase]$Target, [int]$Throttle) : Base($false) {
        $this.psobject.Init($Action, $IsAsync, $Target, $Throttle)
    }

    hidden Init([System.Management.Automation.PSMethod]$Action, [bool]$IsAsync, [ViewModelBase]$Target, [int]$Throttle) {
        $Delegate = $this.psobject.CreateDelegate($Action, $Target)

        if ($Delegate -is [action]) {
            $this.psobject.Action = $Delegate
        } else {
            $this.psobject.ActionObject = $Delegate
        }

        $this.psobject.IsAsync = $IsAsync
        $this.psobject.Target = $Target
        $this.psobject.Throttle = $Throttle

        $this.psobject.RaiseCanExecuteChangedDelegate = $this.psobject.CreateDelegate($this.psobject.RaiseCanExecuteChanged)
        $this.psobject.RemoveWorkerDelegate = $this.psobject.CreateDelegate($this.psobject.RemoveWorker)

        @('Workers').ForEach(
            {
                $Splat = @{
                    Name = $_
                    MemberType = 'ScriptProperty'
                    Value = [scriptblock]::Create('return ,$this.psobject.{0}' -f $_)
                    SecondValue = [scriptblock]::Create('param($value)
                        $this.psobject.{0} = $value
                        $this.psobject.RaisePropertyChanged("{0}")
                        if ($this.psobject.Dispatcher) {{
                            $this.psobject.RaiseCanExecuteChanged()
                        }} elseif ([System.Windows.Threading.Dispatcher]::CurrentDispatcher.CheckAccess()) {{
                            $this.psobject.RaiseCanExecuteChanged()
                            $this.psobject.Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
                        }} else {{
                            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeAsync($this.psobject.RaiseCanExecuteChangedDelegate)
                        }}' -f $_
                    )
                }
                $this | Add-Member @Splat
            }
        )
    }

    [void]RaiseCanExecuteChanged() {
        $eCanExecuteChanged = $this.psobject.InternalCanExecuteChanged
        if ($eCanExecuteChanged) {
            $eCanExecuteChanged.Invoke($this, [System.EventArgs]::Empty)
        }
    }

    [void]RemoveWorker() {
        $this.Workers--
    }

    [ViewModelBase]$Target
    [bool]$IsAsync = $false
    [delegate]$Action
    [delegate]$ActionObject
    $CanExecuteAction
    $Workers = 0
    $Throttle = 1
    $RaiseCanExecuteChangedDelegate
    $RemoveWorkerDelegate
}
