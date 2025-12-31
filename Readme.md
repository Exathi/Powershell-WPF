# Powershell WPF

### Challenge:
1. To write a GUI in PowerShell 5.1 and Pwsh 7.5+
2. No custom written C# classes through `Add-Type`.
3. Limited to resources that come natively with Windows 10/11.

### Result:
An **Asynchronous** PowerShell UI! Supported by a ViewModel and Command Bindings. Bonus updated theming with Pwsh 7.5+ that came with .NET 9.

Revisited and simplified for Pwsh. Previous version is in the archive for those that followed it and for some obscure findings.

### Check out the sample:
``` Powershell
Add-Type -AssemblyName PresentationFramework, WindowsBase -ErrorAction Stop
. ".\Sample Pwsh.ps1"
```

### Pwsh and Powershell compatibility:
* Both Pwsh and Powershell can use the same class setup. The only difference is the ViewModel setup.

* Pwsh has access to the attribute `[NoRunspaceAffinity()]`. Powershell 5.1 needs to create the class without a runspace.

``` Powershell
# Pwsh
$ViewModel = [MyViewModel]::new()
$ViewModel.psobject.WriteVerboseCommand = [ActionCommand]::new($ViewModel.psobject.WriteVerboseMethod)
$ViewModel.WriteVerboseMethod()
PS> VERBOSE: Prints to host

# Powershell
$ViewModel = New-UnboundClassInstance MyViewModel
$ViewModel.psobject.Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
$ViewModel.psobject.WriteVerboseCommand = [ActionCommand]::new($ViewModel.psobject.WriteVerboseMethod)
$ViewModel.WriteVerboseMethod()
PS> # Stream not redirected to this host. Lost to the void.
```

### Updating the view from other runspaces
Everything that interacts with the view must be updated via the wpf Dispatcher.

`StartAsync` invokes the provided PSMethod and then follows with `UpdateViewFromThread` which calls the dispatcher to use the return value (pscustomobject of view properties) of the PSMethod and update the viewmodel. If the return value is $null, the dispatcher will not be called.
``` Powershell
$ReturnValue = [pscustomobject]@{
    ViewProperty1 = Value1
    ViewProperty2 = Value2
}
```


