# Powershell WPF

### Challenge:
1. To write a GUI in Windows Powershell and Pwsh 7.5+
2. No custom written C# classes through `Add-Type`.
3. Limited to resources that come natively with Windows 10/11.

### Result:
An **Asynchronous** PowerShell UI! Supported by a ViewModel and Command Bindings. Bonus updated theming with Pwsh 7.5+ that came with .NET 9.

Revisited and simplified for Pwsh. Previous version is in the archive for those that followed it and for some obscure findings.



https://github.com/user-attachments/assets/caaab235-4286-406f-b3a9-e026df59c0e0



### Check out the sample:
``` Powershell
Add-Type -AssemblyName PresentationFramework, WindowsBase -ErrorAction Stop
. ".\Sample Pwsh.ps1"
```

### Syntax
Since classes inherit `PSCustomObject`, properties are accessed `$Class.psobject.property`. It functions as a accessible hidden (but not private or protected) property that will show intellisense after `.psobject`.

Since `$Class.property` no longer exists, we can add property definitions with the same name as the internal property with Getters and Setters for use in the Xaml with `Add-Member`!

With `$ViewModelBase.AddPropertyChangedToProperties`™ (naming is hard), it will expose all non default properties so they can be accessed by `$ViewModelBase.Property`. Properties added this way will automatically call `RaisePropertyChanged` to notify the UI to update.

### Pwsh and Powershell compatibility:
* Both Pwsh and Powershell can use the same class setup. The only difference is the ViewModel setup.

* Pwsh has access to the attribute `[NoRunspaceAffinity()]`. Powershell 5.1 needs to create the class without a runspace.

``` Powershell
# Pwsh
$ViewModel = [MyViewModel]::new()
$ViewModel.psobject.WriteVerboseCommand = [ActionCommand]::new($ViewModel.psobject.WriteVerboseMethod, $true, $Target, 0)
$ViewModel.WriteVerboseMethod()
PS> VERBOSE: Prints to host

# Powershell
$ViewModel = New-UnboundClassInstance MyViewModel
$ViewModel.psobject.Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
$ViewModel.psobject.WriteVerboseCommand = [ActionCommand]::new($ViewModel.psobject.WriteVerboseMethod, $true, $Target, 0))
$ViewModel.WriteVerboseMethod()
PS> VERBOSE: Prints to host
```

### Updating the view from other runspaces
Everything that interacts with the view must be updated via the wpf Dispatcher.

`ActionCommand.StartAsync` invokes the provided PSMethod in another runspace. It will not run and block on the GUI thread because it is not bound to the runspace it was created in with attribute `[NoRunspaceAffinity()]` and Windows Powershell equivalent.

``` Powershell
# Updating the view by setting property in class method
[void]$Method() {
	$this.Property = $NewValue
}

# Method with return value will try to update the view with this pscustomobject format
[pscustomobject]$Method() {
	return [pscustomobject]@{
		ViewProperty1 = Value1
		ViewProperty2 = Value2
	}
}

# StartAsync will try to update the view with return value from $Method
$ReturnValue.psobject.Properties | ForEach-Object {
	$ViewModelBase.$($_.Name) = $_.Value # since properties are accessed by $ViewModelBase.Property, RaisePropertyChanged will notify the UI of updates in the datacontext.
}
```

### Why not Start-ThreadJob?
Start-ThreadJob alternative feels slower and you'll want something to clean up the jobs. Also does not come default in Windows Powershell.

``` Powershell
# The entirety of StartAsync() can be replaced with:

Start-ThreadJob -Scriptblock {
	param($MethodToRunAsync, $ViewModelBase)
	$UpdateValue = $MethodToRunAsync.Invoke()
	$ViewModelBase.psobject.UpdateViewFromThread($UpdateValue)
} -ArgumentList $MethodToRunAsync, $ViewModelBase
```
