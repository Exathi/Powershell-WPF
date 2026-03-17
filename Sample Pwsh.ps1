Add-Type -AssemblyName PresentationFramework, WindowsBase -ErrorAction Stop
# Import-Module .\CreateClassInstanceHelper.psm1

[NoRunspaceAffinity()]
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
        $this.psobject.UpdateViewDelegate = $this.psobject.CreateDelegate($this.psobject.UpdateView)
        $this.psobject.AddPropertyChangedToProperties()
    }

    ViewModelBase([bool]$AddDefault) {
        $this.psobject.UpdateViewDelegate = $this.psobject.CreateDelegate($this.psobject.UpdateView)
        if ($AddDefault) { $this.psobject.AddPropertyChangedToProperties() }
    }

    [void]AddPropertyChangedToProperties() {
        $this.psobject.AddPropertyChangedToProperties($null)
    }

    [void]AddPropertyChangedToProperties([string[]]$Exclude) {
        $PropertiesToExclude = 'PropertyChanged', 'UpdateViewDelegate', 'Dispatcher', 'RunspacePool', 'LastAction', 'DispatcherOperationInvokedAction', 'DispatcherOperationWorkerAction' + $Exclude
        $this.psobject.psobject.Members.Where({
                $_.MemberType -eq 'Property' -and
                $_.IsSettable -eq $true -and
                $_.IsGettable -eq $true -and
                $_.Name -notin $PropertiesToExclude
            }
        ).ForEach(
            {
                $Splat = @{
                    Name = $_.Name
                    MemberType = 'ScriptProperty'
                    Value = [scriptblock]::Create('return ,$this.psobject.{0}' -f $_.Name)
                    SecondValue = [scriptblock]::Create('param($value)
                        $this.psobject.{0} = $value
                        $this.psobject.RaisePropertyChanged("{0}")' -f $_.Name
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

    [void]UpdateView($UpdateValue) {
        if ($null -eq $UpdateValue) { return }
        if ($UpdateValue -isnot [pscustomobject]) { return }
        $UpdateValue.psobject.Properties | ForEach-Object {
            $this.$($_.Name) = $_.Value
        }
    }

    [System.Threading.Tasks.Task]StartAsync($MethodToRunAsync, [ViewModelBase]$Target, $CommandParameter) {
        return $this.psobject.StartAsync($MethodToRunAsync, [ViewModelBase]$Target, $CommandParameter, $null)
    }

    [System.Threading.Tasks.Task]StartAsync($MethodToRunAsync, [ViewModelBase]$Target, $CommandParameter, $ActionCommand) {
        $Powershell = [powershell]::Create()
        $Powershell.RunspacePool = $this.psobject.RunspacePool # Will use a default runspace if RunspacePool is $null

        $Delegate = if ($null -eq $CommandParameter -and $null -ne $ActionCommand) {
            {
                param($NoContextMethod, $ViewModelBase, $ActionCommand)
                $UpdateValue = $NoContextMethod.Invoke()
                $ViewModelBase.psobject.DispatcherOperationInvokedAction = $ViewModelBase.psobject.Dispatcher.BeginInvoke(9, $ViewModelBase.psobject.UpdateViewDelegate, $UpdateValue )
                $ActionCommand.psobject.DispatcherOperationWorkerAction = $ActionCommand.psobject.Dispatcher.InvokeAsync($ActionCommand.psobject.RemoveWorker)

                # Start added for Windows Powershell compatibility
                # $ActionCommand.psobject.DispatcherOperationWorkerAction = $ActionCommand.psobject.Dispatcher.InvokeAsync($ActionCommand.psobject.RemoveWorkerDelegate)
                # End added for Windows Powershell compatibility

                # Pipeline output can be received in $LastAction.Result
            }
        } elseif ($null -eq $CommandParameter -and $null -eq $ActionCommand) {
            {
                param($NoContextMethod, $ViewModelBase)
                $UpdateValue = $NoContextMethod.Invoke()
                $ViewModelBase.psobject.DispatcherOperationInvokedAction = $ViewModelBase.psobject.Dispatcher.BeginInvoke(9, $ViewModelBase.psobject.UpdateViewDelegate, $UpdateValue )
            }
        } elseif ($null -ne $CommandParameter -and $null -eq $ActionCommand) {
            {
                param($NoContextMethod, $ViewModelBase)
                $UpdateValue = $NoContextMethod.Invoke($CommandParameter)
                $ViewModelBase.psobject.DispatcherOperationInvokedAction = $ViewModelBase.psobject.Dispatcher.BeginInvoke(9, $ViewModelBase.psobject.UpdateViewDelegate, $UpdateValue )
            }
        } else {
            {
                param($NoContextMethod, $ViewModelBase, $CommandParameter)
                $UpdateValue = $NoContextMethod.Invoke($CommandParameter)
                $ViewModelBase.psobject.DispatcherOperationInvokedAction = $ViewModelBase.psobject.Dispatcher.BeginInvoke(9, $ViewModelBase.psobject.UpdateViewDelegate, $UpdateValue )
                $ActionCommand.psobject.DispatcherOperationWorkerAction = $ActionCommand.psobject.Dispatcher.InvokeAsync($ActionCommand.psobject.RemoveWorker)

                # Start added for Windows Powershell compatibility
                # $ActionCommand.psobject.DispatcherOperationWorkerAction = $ActionCommand.psobject.Dispatcher.InvokeAsync($ActionCommand.psobject.RemoveWorkerDelegate)
                # End added for Windows Powershell compatibility
            }
        }

        $NoContext = $Delegate.Ast.GetScriptBlock()

        $null = $Powershell.AddScript($NoContext)
        $null = $Powershell.AddParameter('NoContextMethod', $MethodToRunAsync)
        $null = $Powershell.AddParameter('ViewModelBase', $Target)
        if ($null -ne $CommandParameter) { $null = $Powershell.AddParameter('CommandParameter', $CommandParameter) }
        if ($null -ne $ActionCommand) { $null = $Powershell.AddParameter('ActionCommand', $ActionCommand) }
        $Handle = $Powershell.BeginInvoke()

        # $EndInvokeDelegate = $this.psobject.CreateDelegate($Powershell.EndInvoke, $Powershell) # Alternatively use this unless you want to type out the specific delegate
        $Task = [System.Threading.Tasks.Task]::Factory.FromAsync($Handle, [func[System.IAsyncResult, [System.Management.Automation.PSDataCollection[psobject]]]]$Powershell.EndInvoke) # Automagically call EndInvoke asynchronously when completed! AND returns a task! # No need to start a runspace dedicated to clean up!
        $this.psobject.LastAction = $Task

        return $Task
    }

    $Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $RunspacePool
    $LastAction
    $DispatcherOperationInvokedAction
    $DispatcherOperationWorkerAction
    $UpdateViewDelegate
}

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

        $Delegate = if ($this.psobject.Action) { $this.psobject.Action } else { $this.psobject.ActionObject }

        if ($this.psobject.IsAsync) {
            if ($this.psobject.Throttle -gt 0) {
                $null = $this.psobject.StartAsync($Delegate, $this.psobject.Target, $null, $this)
            } else {
                $null = $this.psobject.StartAsync($Delegate, $this.psobject.Target, $null)
            }
        } else {
            $Delegate.Invoke()
            if ($this.psobject.Throttle -gt 0) { $this.psobject.RemoveWorker() }
        }
    }
    # End ICommand Implementation

    ActionCommand([System.Management.Automation.PSMethod]$Action) : Base($false) {
        $this.psobject.Init($Action, $false, $null, 0)
    }

    ActionCommand([System.Management.Automation.PSMethod]$Action, [bool]$IsAsync, [ViewModelBase]$Target, [int]$Throttle) : Base($false) {
        $this.psobject.Init($Action, $IsAsync, $Target, $Throttle)
    }

    hidden Init([System.Management.Automation.PSMethod]$Action, [bool]$IsAsync, [ViewModelBase]$Target, [int]$Throttle) {
        $this.psobject.Action = $Action
        $this.psobject.IsAsync = $IsAsync
        if ($IsAsync) { $this.psobject.RunspacePool = $Target.psobject.RunspacePool }
        $this.psobject.Target = $Target
        $this.psobject.Throttle = $Throttle

        # Start added for Windows Powershell compatibility
        # $this.psobject.RaiseCanExecuteChangedDelegate = $this.psobject.CreateDelegate($this.psobject.RaiseCanExecuteChanged)
        # $this.psobject.RemoveWorkerDelegate = $this.psobject.CreateDelegate($this.psobject.RemoveWorker)
        # End added for Windows Powershell compatibility

        @('Workers').ForEach(
            {
                $Splat = @{
                    Name = $_
                    MemberType = 'ScriptProperty'
                    Value = [scriptblock]::Create('return ,$this.psobject.{0}' -f $_)
                    SecondValue = [scriptblock]::Create('param($value)
                        $this.psobject.{0} = $value
                        $this.psobject.RaisePropertyChanged("{0}")
                        if ($this.psobject.Dispatcher.CheckAccess()) {{
                            $this.psobject.RaiseCanExecuteChanged()
                        }} else {{
                            $this.psobject.Dispatcher.InvokeAsync($this.psobject.RaiseCanExecuteChanged)
                            # Start added for Windows Powershell compatibility
                            # $this.psobject.Dispatcher.InvokeAsync($this.psobject.RaiseCanExecuteChangedDelegate)
                            # End added for Windows Powershell compatibility
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
    $Action
    $ActionObject
    $CanExecuteAction
    $Workers = 0
    $Throttle = 0

    # Start added for Windows Powershell compatibility
    # $RaiseCanExecuteChangedDelegate
    # $RemoveWorkerDelegate
    # End added for Windows Powershell compatibility
}





[NoRunspaceAffinity()]
class MyViewModel : ViewModelBase {
    # Buttons
    $LongTaskCommand
    $RunCmdletCommand
    $AnotherTaskCommand
    $ProgressBarCommand
    $ProgressPauseCommand

    # View
    $LongTaskResource = 1
    $RunCmdletResource = 10
    $DataGridJobsLock = [object]::new()
    $DataGridJobs = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    $Status = 'Pause'
    [int]$StatusPercent = 0 # must be type int else it defaults to string
    $StatusPause = $false

    MyViewModel() {}

    [pscustomobject]LongTask() {
        $Random = Get-Random -Min 100 -Max 5000
        Start-Sleep -Milliseconds $Random
        return [pscustomobject]@{LongTaskResource = $Random }
    }

    [void]AnotherTask() {
        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'Start'; Time = Get-Date; Snapshot = $this.psobject.LongTaskResource; Method = 'AnotherTask' }
        $this.psobject.DataGridJobs.Add($DataRow) # enabled by the following in the UI thread!: [System.Windows.Data.BindingOperations]::EnableCollectionSynchronization($MyViewModel.psobject.DataGridJobs, $MyViewModel.psobject.DataGridJobsLock)

        $DummyItems = 1..10
        $DummyItems | ForEach-Object -Parallel {
            $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'Processing'; Time = Get-Date; Snapshot = "$(($using:this).psobject.LongTaskResource)"; Method = 'AnotherTask' }
            # The below is not the same as above! -> "$(($using:this).psobject.LongTaskResource)" vs "$($using:this.psobject.LongTaskResource)"
            # $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'Processing'; Time = Get-Date; Snapshot = "$($using:this.psobject.LongTaskResource)"; Method = 'AnotherTask'}

            $($using:this).psobject.DataGridJobs.Add($DataRow)

            $Random = Get-Random -Min 100 -Max 5000
            Start-Sleep -Milliseconds $Random
        } -ThrottleLimit 3

        $DataRow = [PSCustomObject]@{Id = [runspace]::DefaultRunspace.Id; Type = 'End'; Time = Get-Date; Snapshot = $this.psobject.LongTaskResource; Method = 'AnotherTask' }
        $this.psobject.DataGridJobs.Add($DataRow)
    }

    [void]ProgressBarReport() {
        $Start = 1
        $End = 1000000
        $Start..$End | ForEach-Object {
            $Progress = ($_ / $End * 100)
            if ($Progress % 1 -eq 0) { $this.StatusPercent = $Progress }

            while ($this.psobject.StatusPause) {
                Start-Sleep -Milliseconds 50
            }

            # Start-Sleep -Milliseconds (Get-Random -Minimum 0 -Maximum 1)
        }
    }

    [void]ProgressBarPause() {
        $this.StatusPause = !$this.StatusPause
        $this.Status = if ($this.StatusPause) { 'Resume' } else { 'Pause' }
    }

    [void]RunCmdlet() {
        $this.RunCmdletResource = Invoke-SampleCmdlet
    }
}

function Invoke-SampleCmdlet {
    [CmdletBinding()]
    param (
        [int]$Max = [int]::MaxValue
    )
    Start-Sleep -Seconds 2
    Get-Random -Maximum $Max
}

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    Title="ps7"
    ThemeMode="Dark"
    WindowStartupLocation="CenterScreen"
    Width="640"
    Height="720">
    <Grid>
        <TabControl Margin="5">
            <TabItem>
                <TabItem.Header>
                    <StackPanel Orientation="Horizontal">
                        <TextBlock FontFamily="{StaticResource SymbolThemeFontFamily}" Text="&#xF164;" VerticalAlignment="Center" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                        <TextBlock Text="LongTask" Margin="5" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                    </StackPanel>
                </TabItem.Header>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition />
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*" />
                            <RowDefinition Height="50" />
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" HorizontalAlignment="Center">
                            <TextBlock Text="{Binding LongTaskResource}" FontSize="20" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" />
                            <TextBlock Text="{Binding RunCmdletResource}" FontSize="20" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </StackPanel>
                        <StackPanel Grid.Row="1" Grid.Column="0" Orientation="Horizontal" HorizontalAlignment="Center">
                            <Button Name="LongTask" Content="LongTask" Command="{Binding LongTaskCommand}" Style="{DynamicResource AccentButtonStyle}" Margin="5" Width="100" HorizontalAlignment="Center"/>
                            <Button Name="RunCmdlet" Content="RunCmdlet" Command="{Binding RunCmdletCommand}" Style="{DynamicResource AccentButtonStyle}" Margin="5" Width="100" HorizontalAlignment="Center"/>
                        </StackPanel>
                    </Grid>
            </TabItem>
			<TabItem>
                <TabItem.Header>
                    <StackPanel Orientation="Horizontal">
                        <TextBlock FontFamily="{StaticResource SymbolThemeFontFamily}" Text="&#xF16C;" VerticalAlignment="Center" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                        <TextBlock Text="AnotherTask" Margin="5" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                    </StackPanel>
                </TabItem.Header>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition />
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="50" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>

                    <Button Grid.Row="0" Grid.Column="0" Name="SnapshotButton" Content="Run long task and log to DataGrid" Command="{Binding AnotherTaskCommand}" Style="{DynamicResource AccentButtonStyle}" Margin="5" Width="250" HorizontalAlignment="Center"/>

                    <DataGrid Grid.Row="1" Grid.Column="0" Name="DataGridJobs" ItemsSource="{Binding DataGridJobs}" ColumnWidth="*" IsReadOnly="True" AutoGenerateColumns="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Id"
                                                Width="25"
                                                Binding="{Binding Path=Id}" />
                            <DataGridTextColumn Header="Type"
                                                Width="50"
                                                Binding="{Binding Path=Type}" />
                            <DataGridTextColumn Header="Time"
                                                Width="*"
                                                Binding="{Binding Path=Time}" />
                            <DataGridTextColumn Header="Snapshot"
                                                Width="*"
                                                Binding="{Binding Path=Snapshot}" />
                            <DataGridTextColumn Header="Method"
                                                Width="*"
                                                Binding="{Binding Path=Method}" />
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>
            </TabItem>
            <TabItem>
                <TabItem.Header>
                    <StackPanel Orientation="Horizontal">
                        <TextBlock FontFamily="{StaticResource SymbolThemeFontFamily}" Text="&#xEB52;" VerticalAlignment="Center" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                        <TextBlock Text="ProgressBar" Margin="5" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                    </StackPanel>
                </TabItem.Header>
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="30" />
                        <RowDefinition Height="30" />
                        <RowDefinition Height="50" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="1" Text="{Binding Status}" Margin="5" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                    <ProgressBar Grid.Row="2" Value="{Binding StatusPercent}" Minimum="0" Maximum="100" Height="20"/>
                    <StackPanel Grid.Row="3" Orientation="Horizontal">
                        <Button Name="ProgressButtonStart" Content="Start" Command="{Binding ProgressBarCommand}" Style="{DynamicResource AccentButtonStyle}" Margin="5" Width="80" HorizontalAlignment="Left"/>
                        <Button Name="ProgressButtonPause" Content="{Binding Status}" Command="{Binding ProgressPauseCommand}" Margin="5" Width="80" HorizontalAlignment="Left"/>
                    </StackPanel>
                </Grid>
            </TabItem>
        </TabControl>
    </Grid>
</Window>
'@

# ConcurrentDictionary just to highlight thread shenanigans going on. Not needed but can be made available in the runspacepool.
# Load Xaml and ViewModel
$SharedDict = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
$SharedDict.Window = [System.Windows.Markup.XamlReader]::Load(([System.Xml.XmlNodeReader]::new($xaml)))
$SharedDict.MainViewModel = [MyViewModel]::new()

# Create runspacepool for async buttons
$State = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
# $RunspaceVariable = [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('SharedDict', $SharedDict, $null)
# $State.Variables.Add($RunspaceVariable)
$InvokeSampleCmdletDefinition = Get-Content Function:\Invoke-SampleCmdlet -ErrorAction Stop
$State.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Invoke-SampleCmdlet', $InvokeSampleCmdletDefinition))
$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $([int]$env:NUMBER_OF_PROCESSORS + 1), $State, (Get-Host))
$RunspacePool.Open()
$SharedDict.MainViewModel.psobject.RunspacePool = $RunspacePool

# Create buttons
$SharedDict.MainViewModel.psobject.LongTaskCommand = [ActionCommand]::new($SharedDict.MainViewModel.psobject.LongTask, $true, $SharedDict.MainViewModel, 0)
$SharedDict.MainViewModel.psobject.RunCmdletCommand = [ActionCommand]::new($SharedDict.MainViewModel.psobject.RunCmdlet, $true, $SharedDict.MainViewModel, 0)
$SharedDict.MainViewModel.psobject.AnotherTaskCommand = [ActionCommand]::new($SharedDict.MainViewModel.psobject.AnotherTask, $true, $SharedDict.MainViewModel, 0)
$SharedDict.MainViewModel.psobject.ProgressBarCommand = [ActionCommand]::new($SharedDict.MainViewModel.psobject.ProgressBarReport, $true, $SharedDict.MainViewModel, 1)
$SharedDict.MainViewModel.psobject.ProgressPauseCommand = [ActionCommand]::new($SharedDict.MainViewModel.psobject.ProgressBarPause)

# Set DataContext and enable collection thread safety for updating collection across runspaces.
$SharedDict.Window.DataContext = $SharedDict.MainViewModel
[System.Windows.Data.BindingOperations]::EnableCollectionSynchronization($SharedDict.MainViewModel.psobject.DataGridJobs, $SharedDict.MainViewModel.psobject.DataGridJobsLock)

$SharedDict.Window.ShowDialog()
