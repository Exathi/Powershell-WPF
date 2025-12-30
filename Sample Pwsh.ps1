Add-Type -AssemblyName PresentationFramework, WindowsBase -ErrorAction Stop
# Import-Module .\CreateClassInstanceHelper.psm1

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
        if (!(Test-Path $BaseUri)) { [System.IO.DirectoryNotFoundException]::new("$($BaseUri) is invalid") }
        if (!$BaseUri.EndsWith('\')) { $BaseUri = "$BaseUri\" }
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

        $ParameterTypes = [System.Linq.Enumerable]::Select($ReflectionMethod.GetParameters(), [func[object, object]] { $args[0].parametertype })
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
    }

    [Delegate]CreateDelegate([System.Management.Automation.PSMethod]$Method) {
        $reflectionMethod = $this.psobject.GetType().GetMethod($Method.Name)
        $parameterTypes = [System.Linq.Enumerable]::Select($reflectionMethod.GetParameters(), [func[object,object]]{$args[0].parametertype})
        $concatMethodTypes = $parameterTypes + $reflectionMethod.ReturnType
        $delegateType = [System.Linq.Expressions.Expression]::GetDelegateType($concatMethodTypes)
        $delegate = [delegate]::CreateDelegate($delegateType, $this, $reflectionMethod.Name)
        return $delegate
    }

    [void]UpdateViewFromThread($UpdateValue){
		$this.psobject.Dispatcher.BeginInvoke(9, $this.psobject.UpdateViewDelegate, $UpdateValue)
	}

    [void]UpdateView($UpdateValue){
		$UpdateValue.psobject.Properties | ForEach-Object {
			$this.$($_.Name) = $_.Value
		}
	}

    [void]StartAsync($MethodToRunAsync) {
        $Powershell = [powershell]::Create()
		$Powershell.RunspacePool = $this.psobject.RunspacePool

		$reflectionMethod = $Powershell.GetType().GetMethod('EndInvoke')
        $parameterTypes = [System.Linq.Enumerable]::Select($reflectionMethod.GetParameters(), [func[object,object]]{$args[0].parametertype})
        $concatMethodTypes = $parameterTypes + $reflectionMethod.ReturnType
        $delegateType = [System.Linq.Expressions.Expression]::GetDelegateType($concatMethodTypes)
        $EndInvokeDelegate = [delegate]::CreateDelegate($delegateType, $Powershell, $reflectionMethod.Name)

        $Delegate = {
			param($NoContextMethod, $Marshall)
			$UpdateValue = $NoContextMethod.Invoke()
			$Marshall.psobject.UpdateViewFromThread($UpdateValue)
		}
        $NoContext = [scriptblock]::create($Delegate.ToString())

        $null = $Powershell.AddScript($NoContext)
        $null = $Powershell.AddParameter('NoContextMethod', $MethodToRunAsync)
        $null = $Powershell.AddParameter('Marshall', $this)
        $Handle = $Powershell.BeginInvoke()

		$TaskFactory = [System.Threading.Tasks.TaskFactory]::new([System.Threading.Tasks.TaskScheduler]::Default)
        $Task = $TaskFactory.FromAsync($Handle, $EndInvokeDelegate) # Automagically call EndInvoke asynchronously when completed! AND returns a task! # No need to start a runspace dedicated to clean up!
		$DisposeTaskDelegate = $this.psobject.CreateDelegate($this.psobject.DisposeTask)
		$null = $Task.ContinueWith($DisposeTaskDelegate, $Powershell)
    }

	DisposeTask([System.Threading.Tasks.Task]$Task, [object]$Powershell) {
        $Powershell.Dispose()
    }

    $UpdateViewDelegate
    $Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $RunspacePool
}

class ActionCommand : ViewModelBase, System.Windows.Input.ICommand  {
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
        try {
            if ($this.psobject.Action) {
                $this.psobject.Action.Invoke()
            } elseif ($this.psobject.ActionObject) {
                $this.psobject.ActionObject.Invoke($CommandParameter)
            }
        } catch {
            Write-Error "Error handling ActionCommand.Execute: $_" # Have never seen this activate
        }
    }
    # End ICommand Implementation

    ActionCommand([Action]$Action) {
        $this.psobject.Action = $Action
    }

    ActionCommand([Action[object]]$Action) {
        $this.psobject.ActionObject = $Action
    }

    [void]RaiseCanExecuteChanged() {
        $eCanExecuteChanged = $this.psobject.InternalCanExecuteChanged
        if ($eCanExecuteChanged) {
			$eCanExecuteChanged.Invoke($this, [System.EventArgs]::Empty)
        }
    }

    $Action
    $ActionObject
    $CanExecuteAction
    $Workers = 0
    $Throttle = 0
}





[NoRunspaceAffinity()]
class MyViewModel : ViewModelBase {
	$SharedResource = 10
	$SampleCommand

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

	[void]SampleMethod(){
        $this.psobject.StartAsync($this.psobject.LongTask)
	}

	[object]LongTask(){
        $Random = Get-Random -Min 100 -Max 5000
		Start-Sleep -Milliseconds $Random
		return [pscustomobject]@{SharedResource = $Random}
	}
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
                        <TextBlock Text="Sample" Margin="5" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
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

                        <TextBlock Grid.Row="0" Grid.Column="0" Text="{Binding SharedResource, UpdateSourceTrigger=PropertyChanged}" FontSize="20" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" />
                        <Button Grid.Row="1" Grid.Column="0" Name="Increment" Content="+" Command="{Binding SampleCommand}" Style="{DynamicResource AccentButtonStyle}" Margin="5" Width="50" HorizontalAlignment="Center"/>
                    </Grid>
            </TabItem>
			<TabItem>
                <TabItem.Header>
                    <StackPanel Orientation="Horizontal">
                        <TextBlock FontFamily="{StaticResource SymbolThemeFontFamily}" Text="&#xF16C;" VerticalAlignment="Center" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                        <TextBlock Text="Tab2" Margin="5" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
                    </StackPanel>
                </TabItem.Header>
                <StackPanel Margin="5">
                    <TextBlock Text="Tab2" FontSize="20" FontWeight="Bold" />
                </StackPanel>
            </TabItem>
        </TabControl>
    </Grid>
</Window>
'@

# ConcurrentDictionary just to highlight thread shenanigans going on. Not needed.
$SharedDict = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$SharedDict.Window = [System.Windows.Markup.XamlReader]::Load(([System.Xml.XmlNodeReader]::new($xaml)))
$SharedDict.VM = [MyViewModel]::new()

$State = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
# $RunspaceVariable = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'SharedDict', $SharedDict, $null
# $State.Variables.Add($RunspaceVariable)
$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $([int]$env:NUMBER_OF_PROCESSORS + 1), $State, (Get-Host))
$RunspacePool.Open()
$SharedDict.VM.psobject.RunspacePool = $RunspacePool

$SharedDict.VM.psobject.SampleCommand = [ActionCommand]::new($SharedDict.VM.psobject.SampleMethod)

$SharedDict.Window.DataContext = $SharedDict.VM

$SharedDict.Window.ShowDialog()
