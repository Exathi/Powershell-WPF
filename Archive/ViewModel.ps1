using module .\WPFClassHelpers.psm1
using Assembly PresentationFramework
using Assembly PresentationCore
using Assembly WindowsBase

class MyViewModel : ViewModelBase {
    # Must be created with New-UnboundClassInstance in order for delegates to run concurrently for Powershell 5.1. pwsh 7+ has an equivalent NoRunspaceAffinity attribute for classes.
    # Properties do not have a reference to $this.psobject so you can't set the default values in the properties that require others from within the class.

    # UI Thread Objects
    # $Dispatcher# = [System.Windows.Threading.Dispatcher]::CurrentDispatcher # If created by New-UnboundClassInstance, it's thread is stopped because the runspace is gone.
    $SharedResource = 0
    hidden $SharedResourceLock = [object]::new()
    $Jobs = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    hidden $JobsLock = [object]::new()

    # Dummy Class
    $CalculationService = [CalculationService]::new() # Also created as an unbound class to allow multiple calls to its method.

    # Delegates
    $AddTenSlowlyDelegate
    $ExternalMethodDelegate
    $CmdletInMethodDelegate

    # Commands
    $AddTenSlowlyCommand
    $ExternalMethodCommand
    $CmdletInMethodCommand

    MyViewModel() {
        $this | Add-Member -Name SharedResource -MemberType ScriptProperty -Value {
			return $this.psobject.SharedResource
		} -SecondValue {
			param($value)
			$this.psobject.SharedResource = $value
			$this.psobject.RaisePropertyChanged('SharedResource')
            Write-Verbose "SharedResource is set to $value" -Verbose
		}
    }

    CreateButtons([ThreadManager]$ThreadManager) {
        # Buttons need to have a dispatcher inorder to call RaiseCanExecuteChanged from another runspace.
        # Buttons can't be created in the constructor with New-UnboundClassInstance because the thread associated with it is shutdown and the dispatcher won't work.
        # MyViewModel is not dependent on the buttons, that's the views problem. It's methods can be called without buttons!
        # $this.psobject.Dispatcher = $Dispatcher

        $this.psobject.AddTenSlowlyDelegate = $this.psobject.CreateDelegate($this.psobject.AddTenSlowly)
        $this.psobject.AddTenSlowlyCommand = [ActionCommand]::new($this.psobject.AddTenSlowlyDelegate, $ThreadManager)
        $this.psobject.AddTenSlowlyCommand.psobject.Throttle = 3

        $this.psobject.ExternalMethodDelegate = $this.psobject.CreateDelegate($this.psobject.ExternalMethod)
        $this.psobject.ExternalMethodCommand = [ActionCommand]::new($this.psobject.ExternalMethodDelegate, $ThreadManager)
        $this.psobject.ExternalMethodCommand.psobject.Throttle = 6

        $this.psobject.CmdletInMethodDelegate = $this.psobject.CreateDelegate($this.psobject.Cmdlet)
        $this.psobject.CmdletInMethodCommand = [ActionCommand]::new($this.psobject.CmdletInMethodDelegate, $ThreadManager)
        $this.psobject.CmdletInMethodCommand.psobject.Throttle = 6
    }

    # Not needed in pwsh 7+
    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method) {
        $reflectionMethod = $this.psobject.GetType().GetMethod($Method.Name)
        $parameterTypes = [System.Linq.Enumerable]::Select($reflectionMethod.GetParameters(), [func[object,object]]{$args[0].parametertype})
        $concatMethodTypes = $parameterTypes + $reflectionMethod.ReturnType
        $delegateType = [System.Linq.Expressions.Expression]::GetDelegateType($concatMethodTypes)
        $delegate = [delegate]::CreateDelegate($delegateType, $this, $reflectionMethod.Name)
        return $delegate
    }

    [object]AddTenSlowly() {
        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'Start'; Time = Get-Date; Snapshot = $this.psobject.SharedResource; Method = 'SampleMethod'}
        $this.psobject.Jobs.Add($DataRow) # enabled by the following in the UI thread!: [System.Windows.Data.BindingOperations]::EnableCollectionSynchronization($MyViewModel.psobject.Jobs, $MyViewModel.psobject.JobsLock)

        $Data = 0
        1..10 | ForEach-Object {
            $Data++
            Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 400)
        }

        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'End'; Time = Get-Date; Snapshot = $this.psobject.SharedResource; Method = 'SampleMethod'}
        $this.psobject.Jobs.Add($DataRow)

        return $Data
    }

    AddTenSlowly() {
        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'Start'; Time = Get-Date; Snapshot = $this.psobject.SharedResource; Method = 'AddTenSlowly'}
        $this.psobject.Jobs.Add($DataRow) # enabled by the following in the UI thread!: [System.Windows.Data.BindingOperations]::EnableCollectionSynchronization($MyViewModel.psobject.Jobs, $MyViewModel.psobject.JobsLock)

        [System.Threading.Monitor]::Enter($this.psobject.SharedResourceLock)
        try {
            Write-Verbose "Lock acquired $(Get-Date)" -Verbose
            # Simulate multiple threads at this point. Requires a lock to ensure all 10 are added.
            1..10 | ForEach-Object {
                $this.SharedResource++
                Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 400)
            }
        } catch {
            Write-Verbose "oops: $($Error)" -Verbose
        } finally {
            [System.Threading.Monitor]::Exit($this.psobject.SharedResourceLock)
            Write-Verbose "Lock released $(Get-Date)" -Verbose
        }

        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'End'; Time = Get-Date; Snapshot = $this.psobject.SharedResource; Method = 'AddTenSlowly'}
        $this.psobject.Jobs.Add($DataRow)
    }

    ExternalMethod() {
        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'Start'; Time = Get-Date; Snapshot = $this.psobject.SharedResource; Method = 'ExternalMethod'}
        $this.psobject.Jobs.Add($DataRow)

        $NewNumber = $this.psobject.CalculationService.GetThousandDelegate.Invoke($this.SharedResource)

        [System.Threading.Monitor]::Enter($this.psobject.SharedResourceLock)
        try {
            Write-Verbose "Lock acquired $(Get-Date)" -Verbose
            $this.SharedResource += $NewNumber
        } catch {
            Write-Verbose "oops: $($Error)" -Verbose
        } finally {
            [System.Threading.Monitor]::Exit($this.psobject.SharedResourceLock)
            Write-Verbose "Lock released $(Get-Date)" -Verbose
        }

        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'End'; Time = Get-Date; Snapshot = $this.psobject.SharedResource; Method = 'ExternalMethod'}
        $this.psobject.Jobs.Add($DataRow)
    }

    Cmdlet() {
        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'Start'; Time = Get-Date; Snapshot = $this.psobject.SharedResource; Method = 'Cmdlet'}
        $this.psobject.Jobs.Add($DataRow)

        $NewNumber = Get-Million -Seed $this.SharedResource

        [System.Threading.Monitor]::Enter($this.psobject.SharedResourceLock)
        try {
            Write-Verbose "Lock acquired $(Get-Date)" -Verbose
            $this.SharedResource += $NewNumber
        } catch {
            Write-Verbose "oops: $($Error)" -Verbose
        } finally {
            [System.Threading.Monitor]::Exit($this.psobject.SharedResourceLock)
            Write-Verbose "Lock released $(Get-Date)" -Verbose
        }

        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'End'; Time = Get-Date; Snapshot = $this.psobject.SharedResource; Method = 'Cmdlet'}
        $this.psobject.Jobs.Add($DataRow)
    }
}

class CalculationService {
    $GetThousandDelegate = $this.CreateDelegate($this.GetThousand)
    CalculationService() {}

    [int]GetThousand($Seed) {
        # IF CLASS IS NOT UNBOUND, NO PIPELINE USEAGE IS AVAILABLE IF INVOKED WITH ASYNC BUTTON
        # QUEUES IN UI THREAD AND IS INVOKED ASYNC
        # MUST CALL THE DELEGATE IF NOT UNBOUND

        # 1..10 | ForEach-Object {
        #     Start-Sleep -Milliseconds (Get-Random -SetSeed $Seed -Minimum 50 -Maximum 400)
        # }
        foreach ($i in 1..10) {
            Start-Sleep -Milliseconds (Get-Random -SetSeed $Seed -Minimum 50 -Maximum 400)
        }

        # return (Get-Random -SetSeed $Seed) * (Get-Random -InputObject (-1, 1))
        return 1000
    }

    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method) {
        $reflectionMethod = $this.GetType().GetMethod($Method.Name)
        $parameterTypes = [System.Linq.Enumerable]::Select($reflectionMethod.GetParameters(), [func[object,object]]{$args[0].parametertype})
        $concatMethodTypes = $parameterTypes + $reflectionMethod.ReturnType
        $delegateType = [System.Linq.Expressions.Expression]::GetDelegateType($concatMethodTypes)
        $delegate = [delegate]::CreateDelegate($delegateType, $this, $reflectionMethod.Name)
        return $delegate
    }
}

function Get-Million {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [int]$Seed
    )

    process {
        foreach ($i in 1..10) {
            Start-Sleep -Milliseconds (Get-Random -SetSeed $Seed -Minimum 50 -Maximum 400)
        }
        return 1000000
    }
}

class RightMarginConverter : System.Windows.Data.IValueConverter {
    RightMarginConverter() {}
    [object]Convert([object]$value, [Type]$targetType, [object]$parameter, [CultureInfo]$culture) {
        if ($value -is [double] -and $value -gt 0) {
            Write-Verbose $value -Verbose
            return [System.Windows.Thickness]::new(0,0,$value,0)
        }
        Write-Verbose 'return default 0,0,0,0' -Verbose
        return [System.Windows.Thickness]::new(0,0,0,0)
    }

    [object]ConvertBack([object]$value, [Type]$targetType, [object]$parameter, [CultureInfo] $culture) {
        throw 'NotImplemented'
    }
}

class PartialWindow : System.Windows.Window {
    PartialWindow() {
        $this.CommandBindings.Add([System.Windows.Input.CommandBinding]::new([System.Windows.SystemCommands]::ShowSystemMenuCommand, {
            param($CommandParameter)
            $Point = $CommandParameter.PointToScreen([System.Windows.Input.Mouse]::GetPosition($CommandParameter))
            [System.Windows.SystemCommands]::ShowSystemMenu($CommandParameter,$Point)})
        )
        $this.CommandBindings.Add([System.Windows.Input.CommandBinding]::new([System.Windows.SystemCommands]::MinimizeWindowCommand, {
            param($CommandParameter)
            [System.Windows.SystemCommands]::MinimizeWindow($CommandParameter)})
        )
        $this.CommandBindings.Add([System.Windows.Input.CommandBinding]::new([System.Windows.SystemCommands]::MaximizeWindowCommand, {
            param($CommandParameter)
            [System.Windows.SystemCommands]::MaximizeWindow($CommandParameter)})
        )
        $this.CommandBindings.Add([System.Windows.Input.CommandBinding]::new([System.Windows.SystemCommands]::RestoreWindowCommand, {
            param($CommandParameter)
            [System.Windows.SystemCommands]::RestoreWindow($CommandParameter)})
        )
        $this.CommandBindings.Add([System.Windows.Input.CommandBinding]::new([System.Windows.SystemCommands]::CloseWindowCommand, {
            param($CommandParameter)
            [System.Windows.SystemCommands]::CloseWindow($CommandParameter)})
        )
        # $this.Template = New-WPFObject -Path "$PSScriptRoot\Views\PartialWindowTemplate.xaml" -BaseUri "$PSScriptRoot" -LocalNamespaceName 'local'
    }
}
