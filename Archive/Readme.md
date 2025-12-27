# Powershell WPF

### Challenge:
1. To write a GUI in PowerShell 5.1 and .Net Framework.
2. No custom written C# classes through `Add-Type`.
3. Limited to resources that come natively with Windows 10/11.

### Result:
An **Asynchronous** PowerShell UI! Supported by a ViewModel and Command Bindings.

`SampleGUI.ps1` Right click and run with powershell, dot source, or load up vscode and run the debugger to check out the sample.

https://github.com/Exathi/Powershell-WPF/assets/87538502/46a83c2b-9f6a-48e1-8dcd-b881f23443de

## Xaml Custom Namespace
You are able to use local powershell classes by adding `xmlns:local="clr-namespace:;assembly=PowerShell Class Assembly"` to the xaml. This allows for functionality close to C#. The following will create a PartialWindow class when parsed by the `XamlReader`.

```xml
<local:PartialWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:local="clr-namespace:;assembly=PowerShell Class Assembly">
    <StackPanel>
        <TextBlock Text="Custom WPF Object from xaml!" />
    </StackPanel>
</local:PartialWindow>
```

```Powershell
class PartialWindow : System.Windows.Window {
    PartialWindow() {
        Write-Verbose 'PartialWindow was created!' -Verbose
    }
}
```

## Powershell and the Task Parallel Library
You aren't able to call `[System.Threading.Tasks.Task]::Run([action]$Scriptblock)` due to there not being a runspace to execute the scriptblock. However, you are able to use `Factory.FromAsync()` and chain ContinueWith.
```Powershell
class DelegateClass {
    DelegateClass() {}

    $MagicDelegate = $this.CreateDelegate($this.AutoMagicallyCallEndInvoke, $this)

    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method, $Target) {
        $ReflectionMethod = $Target.GetType().GetMethod($Method.Name)
        $ParameterTypes = [System.Linq.Enumerable]::Select($ReflectionMethod.GetParameters(), [func[object,object]]{$args[0].parametertype})
        $ConcatMethodTypes = $ParameterTypes + $ReflectionMethod.ReturnType
        $DelegateType = [System.Linq.Expressions.Expression]::GetDelegateType($ConcatMethodTypes)
        $Delegate = [delegate]::CreateDelegate($DelegateType, $Target, $ReflectionMethod.Name)
        return $Delegate
    }

    [object]AutoMagicallyCallEndInvoke([System.Threading.Tasks.Task]$Task, [object]$Powershell) {
        $Powershell.Dispose()
        return "$($Task.Result) ContinueWith"
    }
}

$Class = [DelegateClass]::new()
$Powershell = [powershell]::Create()

# Convert the PSMethod EndInvoke to Delegate
$EndInvokeDelegate = $Class.CreateDelegate($Powershell.EndInvoke, $Powershell)

$Scriptblock = {'Task Result!'}
$null = $Powershell.AddScript($Scriptblock)
$Handle = $Powershell.BeginInvoke()

$TaskFactory = [System.Threading.Tasks.TaskFactory]::new([System.Threading.Tasks.TaskScheduler]::Default)
$Task = $TaskFactory.FromAsync($Handle, $EndInvokeDelegate)
$ContinueWithTask = $Task.ContinueWith($Class.MagicDelegate, $Powershell)
$Task.Result
$ContinueWithTask.Result

```

If you do call `$Task.Result` or `$Task` before the BeginInvoke is finished, it will hold up the console/thread. You can check its status with `$Task.Status` or `$Task.IsCompleted` without freezing.

While you can call `[System.Threading.Tasks.Task]::Run($Class.CreateDelegate(Class.Method))`, it will still run in the current runspace.

## Concurrency
Pwsh 7 has the attribute `[NoRunspaceAffinity()]`. Powershell 5.1 does not. The kind gentleman [here](https://github.com/PowerShell/PowerShell/issues/3651#issuecomment-306968528) has provided a way to do so. You can probably achieve the same result if you define a class in a runspace and immediately calling `(Get-Runspace -Id x).Close()`

## ViewModel with native INotifyPropertyChanged Implementation
Powershell classes can implement `INotifyPropertyChanged`. One of the things powershell classes lack are getters and setters, however, we can mimic it by inheriting a PSCustomObject. Doing so hides members behind `$ViewModel.psobject.Property`. You can then set getters and setters for the property that are visible by `$ViewModel.PropertyScriptMethod`. As a bonus, you can use `"{Binding Property}"` in the xaml even though it is only visible in the console via `$ViewModel.psobject.Property`

```Powershell
class ViewModelBase : PSCustomObject, System.ComponentModel.INotifyPropertyChanged {
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
}

class MyViewModel : ViewModelBase {
    $SharedResource
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
}
```

## Commands
Last but not least, command bindings. You can set handlers in the "codebehind".
```Powershell
$Window.FindName('Button').add_Click({$Class.Method()})
```

However, since we're this far deep in wpf, we can also implement our own DelegateCommand Class. It can take care of interaction and even be responsible for running methods async. This allows for only needing to run tests on the ViewModel's methods. The ViewModel just works.
```Powershell
class DelegateCommand : ViewModelBase, System.Windows.Input.ICommand  {
    [System.EventHandler]$InternalCanExecuteChanged

    add_CanExecuteChanged([EventHandler]$value) {
        $this.psobject.InternalCanExecuteChanged = [Delegate]::Combine($this.psobject.InternalCanExecuteChanged, $value)
    }

    remove_CanExecuteChanged([EventHandler]$value) {
        $this.psobject.InternalCanExecuteChanged = [Delegate]::Remove($this.psobject.InternalCanExecuteChanged, $value)
    }

    [bool]CanExecute([object]$CommandParameter) {
        if ($this.psobject.CanExecuteAction) { return $this.psobject.CanExecuteAction.Invoke() }
        return $true
    }

    [void]Execute([object]$CommandParameter) {
        if ($this.psobject.Action) {
            $this.psobject.Action.Invoke()
        } else {
            $this.psobject.ActionObject.Invoke()
        }
    }

    DelegateCommand([Action]$Action) {
        $this.psobject.Action = $Action
    }

    DelegateCommand([Action[object]]$Action) {
        $this.psobject.ActionObject = $Action
    }

    [void]RaiseCanExecuteChanged() {
        $eCanExecuteChanged = $this.psobject.InternalCanExecuteChanged
        if ($eCanExecuteChanged) {
            if ($this.psobject.CanExecuteAction) {
                $eCanExecuteChanged.Invoke($this, [System.EventArgs]::Empty)
            }
        }
    }

    $Action
    $ActionObject
    $CanExecuteAction
}
```
