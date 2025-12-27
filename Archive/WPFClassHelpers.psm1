Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
function New-WPFObject {
    <#
        .SYNOPSIS
            Creates a WPF object with given Xaml from a string or file
            Uses the dedicated wpf xaml reader rather than the xmlreader.
        .PARAMETER BaseUri
            Path to the root folder of xaml files. Must end with backslash '\' if pointing to a folder.
            Or a path to a file.Xaml.
            Untested idea - point to zip file?
            Allows relative sources in the xaml. <ResourceDictionary Source="Common.Xaml" /> where Common.Xaml is allowed vs hard coding the fullpath C:\folder\Common.Xaml.
        .EXAMPLE
            -BaseUri "$PSScriptRoot\"
            -BaseUri "C:\Test\Folder\"
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param (
        [Parameter(Mandatory, ValueFromPipeline, Position = 0, ParameterSetName = 'HereString')]
        [Parameter(Mandatory, ValueFromPipeline, Position = 0, ParameterSetName = 'HereStringDynamic')]
        [string[]]$Xaml,

        [Alias('FullName')]
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0, ParameterSetName = 'Path')]
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0, ParameterSetName = 'PathDynamic')]
        [ValidateScript({ Test-Path $_ })]
        [string[]]$Path,

        [Parameter(Mandatory, ParameterSetName = 'HereStringDynamic')]
        [Parameter(Mandatory, ParameterSetName = 'PathDynamic')]
        [string]$BaseUri
    )

    begin {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        if (!(Test-Path $BaseUri)) {[System.IO.DirectoryNotFoundException]::new("$($BaseUri) is invalid")}
        if (!$BaseUri.EndsWith('\')) { $BaseUri = "$BaseUri\"}
    }

    process {
        Write-Debug $PSCmdlet.ParameterSetName
        $RawXaml = if ($PSBoundParameters.ContainsKey('Path')) { Get-Content -Path $Path } else { $Xaml }

        if ($PSCmdlet.ParameterSetName -in @('PathDynamic', 'HereStringDynamic')) {
            $ParserContext = [System.Windows.Markup.ParserContext]::new()
            $ParserContext.BaseUri = [System.Uri]::new($BaseUri, [System.UriKind]::Absolute)

            [System.Windows.Markup.XamlReader]::Parse($RawXaml, $ParserContext)
        } else {
            [System.Windows.Markup.XamlReader]::Parse($RawXaml)
        }
    }
}

function ConvertTo-Delegate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [System.Management.Automation.PSMethod[]]$PSMethod,

        [Parameter(Mandatory)]
        [object]$Target,

        [switch]
        $IsPSObject
    )

    process {
        if ($IsPSObject) {
            $ReflectionMethod = $Target.psobject.GetType().GetMethod($PSMethod.Name)
        } else {
            $ReflectionMethod = $Target.GetType().GetMethod($PSMethod.Name)
        }

        $ParameterTypes = [System.Linq.Enumerable]::Select($ReflectionMethod.GetParameters(), [func[object,object]]{ $args[0].parametertype })
        $ConcatMethodTypes = $ParameterTypes + $ReflectionMethod.ReturnType

        $IsAction = $ReflectionMethod.ReturnType -eq [void]
        if ($IsAction) {
            $DelegateType = [System.Linq.Expressions.Expression]::GetActionType($ParameterTypes)
        } else {
            $DelegateType = [System.Linq.Expressions.Expression]::GetFuncType($ConcatMethodTypes)
        }

        [delegate]::CreateDelegate($DelegateType, $Target, $ReflectionMethod.Name)
    }
}

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
            $this.psobject.PropertyChanged.Invoke($this, $evargs) # invokes every member
            # Write-Verbose "RaisePropertyChanged $propname" -Verbose
	    }
	}
    # End INotifyPropertyChanged Implementation
}

class ActionCommand : ViewModelBase, System.Windows.Input.ICommand  {
    # ICommand Implementation
    [System.EventHandler]$InternalCanExecuteChanged

    add_CanExecuteChanged([EventHandler] $value) {
        $this.psobject.InternalCanExecuteChanged = [Delegate]::Combine($this.psobject.InternalCanExecuteChanged, $value)
        # [System.Windows.Input.CommandManager]::add_RequerySuggested($value) # Use this instead to monitor and refresh all buttons. Must call CommandManager.InvalidateRequerySuggested() if updating from another thread/runspace
    }

    remove_CanExecuteChanged([EventHandler] $value) {
        $this.psobject.InternalCanExecuteChanged = [Delegate]::Remove($this.psobject.InternalCanExecuteChanged, $value)
        # [System.Windows.Input.CommandManager]::remove_RequerySuggested($value)
    }

    [bool]CanExecute([object]$CommandParameter) {
        if ($this.psobject.Throttle -gt 0) { return ($this.psobject.Workers -lt $this.psobject.Throttle) }
        if ($this.psobject.CanExecuteAction) { return $this.psobject.CanExecuteAction.Invoke() }
        return $true
    }

    [void]Execute([object]$CommandParameter) {
        try {
            if ($this.psobject.Action) {
                if ($this.psobject.ThreadManager) {
                    $null = $this.psobject.ThreadManager.Async($this.psobject.Action, $this.psobject.InvokeCanExecuteChangedDelegate)
                    $this.Workers++
                } else {
                    $this.psobject.Action.Invoke()
                }
            } else {
                if ($this.psobject.ThreadManager) {
                    throw 'NotImplemented'
                    # $null = $this.psobject.ThreadManager.Async($this.psobject.ActionObject, $this.psobject.InvokeCanExecuteChangedDelegate)
                    $this.Workers++
                } else {
                    $this.psobject.ActionObject.Invoke($CommandParameter)
                }
            }
        } catch {
            Write-Error "Error handling ActionCommand.Execute: $_" # Have never seen this activate
        }
    }
    # End ICommand Implementation

    ActionCommand() {
        $this.psobject.Init()
    }

    ActionCommand([Action]$Action) {
        $this.psobject.Action = $Action
    }

    ActionCommand([Action[object]]$Action) {
        $this.psobject.ActionObject = $Action
    }

    ActionCommand([Action]$Action, $ThreadManager) {
        $this.psobject.Init()
        $this.psobject.Action = $Action
        $this.psobject.ThreadManager = $ThreadManager
    }

    ActionCommand([Action[object]]$Action, $ThreadManager) {
        $this.psobject.Init()
        $this.psobject.ActionObject = $Action
        $this.psobject.ThreadManager = $ThreadManager
    }

    Init() {
        $this.psobject.InvokeCanExecuteChangedDelegate = $this.psobject.CreateDelegate($this.psobject.InvokeCanExecuteChanged)
        $this | Add-Member -Name Workers -MemberType ScriptProperty -Value {
			return $this.psobject.Workers
		} -SecondValue {
			param($value)
			$this.psobject.Workers = $value
			$this.psobject.RaisePropertyChanged('Workers')
            $this.psobject.RaiseCanExecuteChanged()
		}

        $this | Add-Member -Name Throttle -MemberType ScriptProperty -Value {
			return $this.psobject.Throttle
		} -SecondValue {
			param($value)
			$this.psobject.Throttle = $value
			$this.psobject.RaisePropertyChanged('Throttle')
            $this.psobject.RaiseCanExecuteChanged()
		}
    }

    [void]RaiseCanExecuteChanged() {
        $eCanExecuteChanged = $this.psobject.InternalCanExecuteChanged
        if ($eCanExecuteChanged) {
            if ($this.psobject.CanExecuteAction -or ($this.psobject.Throttle -gt 0)) {
                $eCanExecuteChanged.Invoke($this, [System.EventArgs]::Empty)
            }
        }
    }

    [void]InvokeCanExecuteChanged() {
        $ActionCommand = $this
        $this.psobject.Dispatcher.Invoke(9,[Action[object]]{
            param($ActionCommand)
            $ActionCommand.Workers--
        }, $ActionCommand)
    }

    $Action
    $ActionObject
    $CanExecuteAction
    $ThreadManager
    $Workers = 0
    $Throttle = 0
    $InvokeCanExecuteChangedDelegate
    $Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher

    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method) {
        $ReflectionMethod = $this.psobject.GetType().GetMethod($Method.Name)
        $ParameterTypes = [System.Linq.Enumerable]::Select($ReflectionMethod.GetParameters(), [func[object,object]]{$args[0].parametertype})
        $ConcatMethodTypes = $ParameterTypes + $ReflectionMethod.ReturnType
        $DelegateType = [System.Linq.Expressions.Expression]::GetDelegateType($ConcatMethodTypes)
        $Delegate = [delegate]::CreateDelegate($DelegateType, $this, $ReflectionMethod.Name)
        return $Delegate
    }
}


class ThreadManager : System.IDisposable {
    # IDisposable Implementation
    Dispose() {
        $this.RunspacePool.Dispose()
    }
    # End IDisposable Implementation

    # This class is used to offload work from the main ui thread.
    # Allows unbound class methods to run asynchronously.
    # Intended to be used with an unbound class with New-UnboundClassInstance for Powershell 5.1 or if using pwsh7+, the NoRunspaceAffinity attribute.

    $SharedPoolVars = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $DisposeTaskDelegate = $this.CreateDelegate($this.DisposeTask)

    $RunspacePool
    ThreadManager($FunctionNames) {
        $this.Init($FunctionNames)
    }

    ThreadManager() {
        $this.Init($null)
    }

    hidden Init($FunctionNames) {
        $State = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $RunspaceVariable = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'SharedPoolVars', $this.SharedPoolVars, $null
        $State.Variables.Add($RunspaceVariable)

        foreach ($FunctionName in $FunctionNames) {
            $FunctionDefinition = Get-Content Function:\$FunctionName -ErrorAction 'Stop'
            $SessionStateFunction = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $FunctionName, $FunctionDefinition
            $State.Commands.Add($SessionStateFunction)
        }

        $this.RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $([int]$env:NUMBER_OF_PROCESSORS + 1), $State, (Get-Host))
        $this.RunspacePool.ApartmentState = 'STA' # Don't think MTA does anything
        $this.RunspacePool.ThreadOptions = 'ReuseThread' # Probably doesn't matter since the only runspaces we create are used to house dispatcher threads
        $this.RunspacePool.CleanupInterval = [timespan]::FromMinutes(2) # Also probably doesn't matter since the only runspaces we create are used to house dispatcher threads and won't be free to cleanup. OR none since Async cleans them up on ContinueWith.
        $this.RunspacePool.Open() # Todo either move to an initalize method or make the runspacepool a variable outside the class.
    }

    [object]Async([scriptblock]$scriptblock) {
        $Powershell = [powershell]::Create()
        $EndInvokeDelegate = $this.CreateDelegate($Powershell.EndInvoke, $Powershell)
        $Powershell.RunspacePool = $this.RunspacePool

        $null = $Powershell.AddScript($scriptblock)
        $Handle = $Powershell.BeginInvoke()

        $TaskFactory = [System.Threading.Tasks.TaskFactory]::new([System.Threading.Tasks.TaskScheduler]::Default)
        $Task = $TaskFactory.FromAsync($Handle, $EndInvokeDelegate)
        $null = $Task.ContinueWith($this.DisposeTaskDelegate, $Powershell)

        return $Task
    }

    [object]Async([Delegate]$MethodToRunAsync) {
        return $this.Async($MethodToRunAsync, $null)
    }

    [object]Async([Delegate]$MethodToRunAsync, [Delegate]$Callback) {
        $Powershell = [powershell]::Create()
        $EndInvokeDelegate = $this.CreateDelegate($Powershell.EndInvoke, $Powershell)
        $Powershell.RunspacePool = $this.RunspacePool

        if ($Callback) {
            $Action = {
                param($MethodToRunAsync, $Callback)
                $MethodToRunAsync.Invoke()
                $Callback.Invoke()
            }
        } else {
            $Action = {
                param($MethodToRunAsync)
                $MethodToRunAsync.Invoke()
            }
        }
        $NoContext = [scriptblock]::create($Action.ToString())

        $null = $Powershell.AddScript($NoContext)
        $null = $Powershell.AddParameter('MethodToRunAsync', $MethodToRunAsync)
        if ($Callback) { $null = $Powershell.AddParameter('Callback', $Callback) }
        $Handle = $Powershell.BeginInvoke()

        $TaskFactory = [System.Threading.Tasks.TaskFactory]::new([System.Threading.Tasks.TaskScheduler]::Default)
        $Task = $TaskFactory.FromAsync($Handle, $EndInvokeDelegate) # Automagically call EndInvoke asynchronously when completed! AND returns a task! # No need to start a runspace dedicated to clean up!
        $null = $Task.ContinueWith($this.DisposeTaskDelegate, $Powershell)

        return $Task
    }

    [void]DisposeTask([System.Threading.Tasks.Task]$Task, [object]$Powershell) {
        $Powershell.Dispose()
    }

    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method) {
        return $this.CreateDelegate($Method, $this)
    }

    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method, $Target) {
        $ReflectionMethod = $Target.GetType().GetMethod($Method.Name)
        $ParameterTypes = [System.Linq.Enumerable]::Select($ReflectionMethod.GetParameters(), [func[object,object]]{$args[0].parametertype})
        $ConcatMethodTypes = $ParameterTypes + $ReflectionMethod.ReturnType
        $DelegateType = [System.Linq.Expressions.Expression]::GetDelegateType($ConcatMethodTypes)
        $Delegate = [delegate]::CreateDelegate($DelegateType, $Target, $ReflectionMethod.Name)
        return $Delegate
    }
}
