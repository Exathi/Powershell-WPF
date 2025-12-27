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
* Both Pwsh and Powershell can use the same class setup. The only difference is the ViewModel setup and ActionCommand setup.

* Pwsh has access to the attribute `[NoRunspaceAffinity()]`. Powershell 5.1 needs to create the class without a runspace.

* Pwsh can automatically convert `[PSMethod]` to `[Action]`. Powershell 5.1 does not have this automatic conversion.

``` Powershell
# Pwsh
$ViewModel = [MyViewModel]::new()
$ViewModel.psobject.WriteVerboseCommand = [ActionCommand]::new($ViewModel.psobject.WriteVerboseMethod)
$ViewModel.WriteVerboseMethod()
PS> VERBOSE: Prints to host

# Powershell 5.1
$ViewModel = New-UnboundClassInstance MyViewModel
$Action = ConvertTo-Delegate -PSMethod $ViewModel.psobject.WriteVerboseMethod -Target $ViewModel -IsPSObject
$ViewModel.psobject.WriteVerboseCommand = [ActionCommand]::new($Action)
$ViewModel.WriteVerboseMethod()
PS> # Stream not redirected to this host. Lost to the void.
```

