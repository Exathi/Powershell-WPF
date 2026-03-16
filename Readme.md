# Powershell WPF

### Challenge
1. To write a GUI in Windows Powershell and Pwsh 7.5+
2. No custom written C# classes through `Add-Type`.
3. Limited to resources that come natively with Windows 11.

### Result
An **Asynchronous** PowerShell UI! Supported by a ViewModel and Command Bindings. Bonus updated theming with Pwsh 7.5+ that came with .NET 9.

Revisited and simplified for Pwsh. Previous version is in the archive for those that followed it and for some obscure findings.



https://github.com/user-attachments/assets/caaab235-4286-406f-b3a9-e026df59c0e0



### Check out the single file sample
``` Powershell
Add-Type -AssemblyName PresentationFramework, WindowsBase -ErrorAction Stop
. ".\Sample Pwsh.ps1"
```

### How it works
Since classes inherit `PSCustomObject`, properties are accessed `$Class.psobject.Property`. It functions as a accessible hidden (but not private or protected) property that will show intellisense after `.psobject`.

While the xaml can bind to `$Class.psobject.Property`, there won't be a way to call OnPropertyChanged in property setter. The Xaml also can't find and bind to `Add-Member -MemberType ScriptProperty`. However, since we inherited `PSCustomObject`, `$Class.Property` no longer exists therefore we can add property definitions with the same name as the internal property with Getters and Setters for use in the Xaml with `Add-Member`!

Now when the property is set with `$Class.Property = $Value`, it can properly call OnPropertyChanged on the backing property! You can use `$Class.Property` for notifying or access the backing field directly `$Class.psobject.Property` similar to csharp `$Class.Property` and internal `$Class._Property`.

With `$ViewModelBase.AddPropertyChangedToProperties`™ (naming is hard), it will expose all non default properties so they can be accessed by `$ViewModelBase.Property`. Properties added this way will automatically call `$ViewModelBase.RaisePropertyChanged` to notify the UI to update.

Methods will have to be called with `$Class.psobject.ClassMethod()`. I have not explored adding via `Add-Member -MemberType ScriptMethod`.

### Minimal Setup Example
``` Powershell
# Pwsh
# Make sure to load ViewModelBase and ActionCommand first
$Location = Join-Path -Path (Get-Location).Path -ChildPath Modules -AdditionalChildPath PowershellWpf
$LoadClasses = [ScriptBlock]::Create("using module '$Location' ")
. $LoadClasses
$xaml = [xml]::new()
$xaml.LoadXml(@'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    Title="ps7.5" ThemeMode="Dark" WindowStartupLocation="CenterScreen" Width="640" Height="480">
	<StackPanel HorizontalAlignment="Center">
		 <TextBlock Text="{Binding CustomerNameValue}" />
		 <Button Content="Async" Command="{Binding AsyncCustomerNameCommand}" />
		 <Button Content="Freeze" Command="{Binding CustomerNameCommand}" />
	</StackPanel>
</Window>
'@)
class ViewModel : ViewModelBase {
	$AsyncCustomerNameCommand
	$CustomerNameCommand
	$CustomerNameValue = 'Hello World'
	ViewModel () {}
	[void]CustomerName() {
		Start-Sleep -Seconds 2
		$this.CustomerNameValue = Get-Random
	}
}
$ViewModel = [ViewModel]::new()
$ViewModel.psobject.AsyncCustomerNameCommand = [ActionCommand]::new($ViewModel.psobject.CustomerName, $true, $ViewModel, 1)
$ViewModel.psobject.CustomerNameCommand = [ActionCommand]::new($ViewModel.psobject.CustomerName, $false, $ViewModel, 1)
$Window = [System.Windows.Markup.XamlReader]::Load(([System.Xml.XmlNodeReader]::new($xaml)))
$Window.DataContext = $ViewModel
$Window.ShowDialog()

```

### Pwsh and Powershell compatibility
* The main difference is the ViewModel setup.

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
$ViewModel.psobject.WriteVerboseCommand = [ActionCommand]::new($ViewModel.psobject.WriteVerboseMethod, $true, $Target, 0)
$ViewModel.WriteVerboseMethod()
PS> VERBOSE: Prints to host
```

``` Powershell
# Pwsh can implicitly convert methods to delegates so this is possible
$Dispatcher.InvokeAsync($Class.Method)

# But not with a parameter
$Dispatcher.InvokeAsync($Class.Method($Parameter))

# So we have to rely on BeginInvoke for method and its delegate with a parameter
$Dispatcher.BeginInvoke(9, $Class.MethodDelegate, $Parameter)
```


``` Powershell
# Windows Powershell has an extra two delegates used in actioncommand and viewmodelbase.startasync
# Other than these and [NoRunspaceAffinity()], the classes are the same.
$RaiseCanExecuteChangedDelegate
$RemoveWorkerDelegate
```

### Updating the view from other runspaces
Everything that interacts with the view must be updated via the wpf Dispatcher.

`ActionCommand.Execute` invokes the provided PSMethod in another runspace. It will not run and block on the GUI thread because it is not bound to the runspace it was created in with attribute `[NoRunspaceAffinity()]` and Windows Powershell equivalent.

``` Powershell
# Update the view by setting property in class method
# Provided that the property was setup with AddPropertyChangedToProperties().
# Method works as is. Create an ActionCommand.IsAsync = $true to run in a runspace or false to run on the GUI thread.
[void]$Method() {
	$NewValue = Invoke-RestMethod
	$this.Property = $NewValue.Result
}

# Methods with this formatted [pscustomobject] will try to update the view with this pscustomobject format if ran async from a button command.
# This will only update when the dispatcher/ui is running.
[pscustomobject]$Method() {
	return [pscustomobject]@{
		ViewProperty1 = Value1
		ViewProperty2 = Value2
	}
}

# StartAsync will try to update the view with return value from $Method
$ReturnValue = $Class.Method()
$ReturnValue.psobject.Properties | ForEach-Object {
	$ViewModelBase.$($_.Name) = $_.Value # since properties are accessed by $ViewModelBase.Property, RaisePropertyChanged will notify the UI of updates in the datacontext.
}
```

### Why not Start-ThreadJob
Start-ThreadJob alternative feels slower and you'll want something to clean up the jobs. Also does not come default in Windows Powershell.

``` Powershell
# The entirety of StartAsync() can be replaced with this but won't be able to run custom cmdlets within the class method unless you pass an initialization script to define the cmdlet.
# And something else to clean up the job since Receive-Job with -AutoRemoveJob requires -Wait.

Start-ThreadJob -Scriptblock {
	param($MethodToRunAsync, $ViewModelBase)
	$UpdateValue = $MethodToRunAsync.Invoke()
	$ViewModelBase.psobject.UpdateView($UpdateValue)
} -ArgumentList $MethodToRunAsync, $ViewModelBase
```
