using module '..\PsModelUI'



function Invoke-SampleFunction {
    [CmdletBinding()]
    param (
        [int]$Max = [int]::MaxValue
    )
    Start-Sleep -Seconds 2
    Get-Random -Maximum $Max
}

Set-ViewModelPool -Functions @(
    'Invoke-SampleFunction'
)



$ServiceModel = New-Class -ClassName 'ServiceModel' -PropertyInit @(
    New-ClassProperty -Name LongTaskItem -Type ([int])
) -Methods @(
    New-ClassMethod -Name 'NewItem' -Body {
        $Random = Get-Random -Min 100 -Max 5000
        Start-Sleep -Milliseconds $Random
        $this.LongTaskItem = $Random
        return $this.LongTaskItem
    }
    New-ClassMethod -Name 'SampleFunction' -Body {
        return Invoke-SampleFunction
    }
    New-ClassMethod -Name 'DotSourced' -Body {
        try {
            $DotSourcedItem = . "$PWD\Demos\DemoDotSource.ps1"
        } catch {
            Write-Warning "Method DotSourced failed. Current location is: '$PWD' and the dotsourced script isn't here. Source the fullpath or set '[Environment]::CurrentDirectory = Get-Location' before launching the GUI."
        }
        return $DotSourcedItem
    }
    New-ClassMethod -Name 'ProgressBar' -Body {
        param([int]$CurrentItem)
        Start-Sleep -Milliseconds ($CurrentItem * (Get-Random -Min 0 -Max 3))
    }
) -AutomaticProperties $true -ExcludeScriptProperty -Inherits $null


$LongTaskSplat = @{
    ClassName = 'LongTaskViewModel'
    PropertyInit = @(
        New-ClassProperty -Name Header -Type ([string]) -Init { 'LongTask' }
        New-ClassProperty -Name BodyText -Type ([string]) -Init { '$LongTaskCommand will be invoked in a runspace to update $UpdatableContent after 100ms - 5000ms per click. if there are no available runspaces in the runspacepool, the command is queued until the next runspace is available.' }
        New-ClassProperty -Name UpdatableContent -Type ([string]) -Init { '' }
        New-ClassProperty -Name ButtonText -Type ([string]) -Init { 'LongTaskCommand' }
        New-ClassProperty -Name FooterNote -Type ([string]) -Init { "Click to your heart's content." }
    )
    Methods = @(
        New-ViewModelMethod -Name 'LongTask' -CommandName 'Command' -Body {
            $this.UpdatableContent = $this.ServiceModel.NewItem()
        } -Throttle 0
    )
    Unbound = $true
    AutomaticProperties = $true
}


$AnotherTask = New-ViewModelMethod -Name 'AnotherTask' -CommandName 'Command' -Body {
    $DataRow = [pscustomobject]@{
        Id = [runspace]::DefaultRunspace.Id
        ThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId
        Type = 'Start'
        Time = Get-Date
        Snapshot = $this.ServiceModel.LongTaskItem
        Method = 'AnotherTask'
    }

    $this.GridContent.Add($DataRow)

    $DummyItems = 1..10
    $DummyItems | ForEach-Object {
        $DataRow = [pscustomobject]@{
            Id = [runspace]::DefaultRunspace.Id
            ThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId
            Type = 'Processing'
            Time = Get-Date
            Snapshot = $this.ServiceModel.LongTaskItem
            Method = 'AnotherTask'
        }

        $this.GridContent.Add($DataRow)

        $Random = Get-Random -Min 1 -Max 3000
        Start-Sleep -Milliseconds $Random
    }

    $DataRow = [pscustomobject]@{
        Id = [runspace]::DefaultRunspace.Id
        ThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId
        Type = 'End'
        Time = Get-Date
        Snapshot = $this.ServiceModel.LongTaskItem
        Method = 'AnotherTask'
    }
    $this.GridContent.Add($DataRow)
} -Throttle 2

$AnotherTaskSplat = @{
    ClassName = 'AnotherTaskViewModel'
    PropertyInit = @(
        New-ClassProperty -Name Header -Type ([string]) -Init { 'AnotherTask' }
        New-ClassProperty -Name BodyText -Type ([string]) -Init { 'Some bindings require the actual property instead of the ScriptProperty because the getter returns an object instead of the typed object.' }
        New-ClassProperty -Name GridContentLock -Type ([object]) -Init { [object]::new() }
        New-ClassProperty -Name GridContent -Type ([System.Collections.ObjectModel.ObservableCollection[Object]]) -Init { [System.Collections.ObjectModel.ObservableCollection[Object]]::new() } -ExcludePrefix
        New-ClassProperty -Name ButtonText -Type ([string]) -Init { 'AnotherTaskCommand' }
        New-ClassProperty -Name FooterNote -Type ([string]) -Init { 'Add to datagrid with a maximum of two running at the same time.' }
    )
    Methods = @(
        $AnotherTask
    )
    Unbound = $true
    AutomaticProperties = $true
}


$SampleFunctionSplat = @{
    ClassName = 'SampleFunctionViewModel'
    PropertyInit = @(
        New-ClassProperty -Name Header -Type ([string]) -Init { 'SampleFunction' }
        New-ClassProperty -Name BodyText -Type ([string]) -Init { 'The below textblock will update when the button is clicked. The button calls $SampleFunctionCommand in a runspace to update $UpdatableContent after 2000ms and cannot be clicked while running.' }
        New-ClassProperty -Name ButtonText -Type ([string]) -Init { 'SampleFunctionCommand' }
        New-ClassProperty -Name FooterNote -Type ([string]) -Init { 'Button will be disabled until command is finished.' }
    )
    Methods = @(
        New-ViewModelMethod -Name 'SampleFunction' -CommandName 'Command' -Body {
            $this.UpdatableContent = $this.ServiceModel.SampleFunction()
        }
    )
    Unbound = $true
    AutomaticProperties = $true
}


$DotSourcedSplat = @{
    ClassName = 'DotSourcedViewModel'
    PropertyInit = @(
        New-ClassProperty -Name Header -Type ([string]) -Init { 'DotSourced' }
        New-ClassProperty -Name BodyText -Type ([string]) -Init { 'This will invoke $DotSourcedCommand in a runspace to update $UpdatableContent.' }
        New-ClassProperty -Name ButtonText -Type ([string]) -Init { 'DotSourcedCommand' }
        New-ClassProperty -Name FooterNote -Type ([string]) -Init { 'Already have scripts? Just invoke them.' }
    )
    Methods = @(
        New-ViewModelMethod -Name 'DotSourced' -CommandName 'Command' -Body {
            $this.UpdatableContent = $this.ServiceModel.DotSourced()
        }
    )
    Unbound = $true
    AutomaticProperties = $true
}


$ProgressBarSplat = @{
    ClassName = 'ProgressBarViewModel'
    PropertyInit = @(
        New-ClassProperty -Name Header -Type ([string]) -Init { 'ProgressBar' }
        New-ClassProperty -Name BodyText -Type ([string]) -Init { 'This will call $ServiceModel.Progressbar and display a progress bar of the completion percent.' }
        New-ClassProperty -Name UpdatableContent -Type ([string]) -Init { '' }
        New-ClassProperty -Name ButtonText -Type ([string]) -Init { 'ProgressBarCommand' }
        New-ClassProperty -Name FooterNote -Type ([string]) -Init { 'For when you do or do not know how long it will take.' }
        New-ClassProperty -Name Status -Type ([string]) -Init { 'Pause' }
        New-ClassProperty -Name ProgressVisible -Type ([string]) -Init { 'Collapsed' }
        New-ClassProperty -Name StatusPercent -Type ([int]) -Init { 0 } -ExcludePrefix
        New-ClassProperty -Name IsPaused -Type ([bool]) -Init { $false }
    )
    Methods = @(
        New-ViewModelMethod -Name 'ProgressBar' -CommandName 'Command' -Body {
            $this.ProgressVisible = 'Visible'

            $Start = 1
            $End = 100
            $Start..$End | ForEach-Object {
                while ($this.IsPaused) {
                    Start-Sleep -Milliseconds 100
                }

                $this.ServiceModel.ProgressBar($_)

                $Progress = ($_ / $End * 100)
                $this.UpdatableContent = $Progress
                if ($Progress % 1 -eq 0) { $this.StatusPercent = $Progress }
            }

            $this.UpdatableContent = 'Done'
            $this.ProgressVisible = 'Collapsed'
        }

        New-ViewModelMethod -Name 'ProgressPause' -Body {
            if ($this.ProgressVisible -eq 'Collapsed') { return }
            $this.IsPaused = !$this.IsPaused
            $this.Status = if ($this.IsPaused) { 'Resume' } else { 'Pause' }
        } -IsAsync $false
    )
    Unbound = $true
    AutomaticProperties = $true
}

# Script will complain about [System.Windows.Media.Color] so we use New-ViewModel to wrap it.
# Otherwise move it to another script and call it after assemblies are loaded.
$ColorSplat = @{
    ClassName = 'ColorViewModel'
    PropertyInit = @(
        New-ClassProperty -Name Header -Type ([string]) -Init { 'Background Color Binding' }
        New-ClassProperty -Name Limitations -Type ([string]) -Init { 'Interactive color picker. Any control binding text requires binding to a ScriptProperty without the same backing name to invoke PropertyChanged.' }

        New-ClassProperty -Name ColorA -Type ([byte]) -Init { 200 } -Get { return, $this.psobject._ColorA } -Set {
            param($value)
            $this.psobject._ColorA = $value
            $this.ColorArgb = [System.Windows.Media.Color]::FromArgb($this.ColorA, $this.ColorR, $this.ColorG, $this.ColorB)
            $this.psobject.RaisePropertyChanged('ColorA')
        }

        New-ClassProperty -Name ColorR -Type ([byte]) -Init { 255 } -Get { return, $this.psobject._ColorR } -Set {
            param($value)
            $this.psobject._ColorR = $value
            $this.ColorArgb = [System.Windows.Media.Color]::FromArgb($this.ColorA, $this.ColorR, $this.ColorG, $this.ColorB)
            $this.psobject.RaisePropertyChanged('ColorR')
        }

        New-ClassProperty -Name ColorG -Type ([byte]) -Init { 255 } -Get { return, $this.psobject._ColorG } -Set {
            param($value)
            $this.psobject._ColorG = $value
            $this.ColorArgb = [System.Windows.Media.Color]::FromArgb($this.ColorA, $this.ColorR, $this.ColorG, $this.ColorB)
            $this.psobject.RaisePropertyChanged('ColorG')
        }

        New-ClassProperty -Name ColorB -Type ([byte]) -Init { 255 } -Get { return, $this.psobject._ColorB } -Set {
            param($value)
            $this.psobject._ColorB = $value
            $this.ColorArgb = [System.Windows.Media.Color]::FromArgb($this.ColorA, $this.ColorR, $this.ColorG, $this.ColorB)
            $this.psobject.RaisePropertyChanged('ColorB')
        }

        # Background wants to bind to a [SolidColorBrush] but it can also coerce a string into a color so we'll take advantage of that here instead of using a converter.
        # Alternatively bind the background to the ElementName of the textbox: {ElementName=GivenTextBoxName, Path=Text}
        New-ClassProperty -Name ColorArgb -Type ([string]) -Init { [System.Windows.Media.Color]::FromArgb($this.ColorA, $this.ColorR, $this.ColorG, $this.ColorB).ToString() } -ExcludePrefix -Get { 'return, $this.psobject.ColorArgb' } -Set {
            param($value)
            $this.psobject.ColorArgb = $value
            $this.ColorArgbText = $value
            $this.psobject.RaisePropertyChanged('ColorArgb')
        }

        New-ClassProperty -Name ColorArgbText -Type ([string]) -Init { $this.ColorArgb } -Get { return, $this.psobject.ColorArgb } -Set {
            param($value)
            $Color = [System.Windows.Media.Color]$value
            $this.psobject._ColorA = $Color.A
            $this.psobject._ColorR = $Color.R
            $this.psobject._ColorG = $Color.G
            $this.psobject._ColorB = $Color.B
            $this.psobject.ColorArgb = $value
            $this.psobject.RaisePropertyChanged('ColorA')
            $this.psobject.RaisePropertyChanged('ColorR')
            $this.psobject.RaisePropertyChanged('ColorG')
            $this.psobject.RaisePropertyChanged('ColorB')
            $this.psobject.RaisePropertyChanged('ColorArgb')
            $this.psobject.RaisePropertyChanged('ColorArgbText')
        }

        New-ClassProperty -Name HeaderAlpha -Type ([string]) -Init { 'A' }
        New-ClassProperty -Name HeaderRed -Type ([string]) -Init { 'R' }
        New-ClassProperty -Name HeaderGreen -Type ([string]) -Init { 'G' }
        New-ClassProperty -Name HeaderBlue -Type ([string]) -Init { 'B' }
        New-ClassProperty -Name SetArgbButtonLabel -Type ([string]) -Init { 'Update Card Background Color By Sliders' }
        New-ClassProperty -Name ButtonText -Type ([string]) -Init { 'Update' }
        New-ClassProperty -Name RefreshArgbButtonLabel -Type ([string]) -Init { 'Update Card Background Color By Hex' }
        New-ClassProperty -Name ColorArgbHexLabel -Type ([string]) -Init { 'Hex Code' }
    )
    Unbound = $true
}

$DemoSplat = @{
    ClassName = 'DemoViewModel'
    PropertyInit = @(
        New-ClassProperty -Name 'Header' -Type ([string]) -Init { 'A Viewmodel for every content control' }
        New-ClassProperty -Name 'LongTaskViewModel'
        New-ClassProperty -Name 'AnotherTaskViewModel'
        New-ClassProperty -Name 'SampleFunctionViewModel'
        New-ClassProperty -Name 'DotSourcedViewModel'
        New-ClassProperty -Name 'ProgressBarViewModel'
    )
    Unbound = $true
}

$MainViewModelDef = New-ViewModel -ClassName 'MainViewModel' -PropertyInit @(
    New-ClassProperty -Name ViewModels -Type ([System.Collections.Generic.Dictionary[string, object]]) -Init { [System.Collections.Generic.Dictionary[string, object]]::new() }
    New-ClassProperty -Name CurrentViewModel
    New-ClassProperty -Name Header -Type ([string])
    New-ClassProperty -Name ContentVisible -Type ([string]) -Init { 'Visible' } -ExcludePrefix
    New-ClassProperty -Name EditorVisible -Type ([string]) -Init { 'Collapsed' } -ExcludePrefix
    New-ClassProperty -Name XamlString -Type ([string])
    New-ClassProperty -Name Window
) -Methods @(
    New-ViewModelMethod -Name 'SwitchView' -Body {
        param($CommandParameter)
        if ($this.CurrentViewModel -eq $this.ViewModels[$CommandParameter]) { return }

        $this.Header = $CommandParameter
        $this.CurrentViewModel = $this.ViewModels[$CommandParameter]

        if ($CommandParameter -eq 'Xaml Visual') {
            $this.ContentVisible = 'Collapsed'

            if ($this.EditorVisible -eq 'Visible') {
                $this.EditorVisible = 'Collapsed'
            }
            $this.EditorVisible = 'Visible'
        } else {
            $this.ContentVisible = 'Visible'
            $this.EditorVisible = 'Collapsed'
        }
    } -IsAsync $false
) -ConstructorBody {
    $this.ViewModels['Home'] = $this
    $this.ViewModels['Demo'] = New-ViewModel -Type 'DemoViewModel'
    $this.ViewModels['Demo'].LongTaskViewModel = New-ViewModel -Type 'LongTaskViewModel'
    $this.ViewModels['Demo'].AnotherTaskViewModel = New-ViewModel -Type 'AnotherTaskViewModel'
    $this.ViewModels['Demo'].SampleFunctionViewModel = New-ViewModel -Type 'SampleFunctionViewModel'
    $this.ViewModels['Demo'].DotSourcedViewModel = New-ViewModel -Type 'DotSourcedViewModel'
    $this.ViewModels['Demo'].ProgressBarViewModel = New-ViewModel -Type 'ProgressBarViewModel'
    $this.ViewModels['Color'] = New-ViewModel -Type 'ColorViewModel'

    $this.CurrentViewModel = $this.ViewModels['Home']
    $this.Header = 'Home'

    $this.psobject._XamlString = '<ContentControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <TextBlock Text="placeholder" />
</ContentControl>'

    $this | Add-Member -MemberType ScriptProperty -Name XamlString -Value { return , $this.psobject._XamlString }.Ast.GetScriptBlock() -SecondValue {
        param($value)
        $this.psobject._XamlString = $value
        try {
            $this.psobject._Window.FindName('HotReload').Content = New-WpfObject -Xaml $MainViewModel.XamlString
        } catch {
            Write-Verbose $_ -Verbose
        }
        $this.psobject.RaisePropertyChanged('XamlString')
    }.Ast.GetScriptBlock() -Force
} -Unbound $false -AsString

$LongTaskViewModelDef = New-ViewModel @LongTaskSplat -AsString
$AnotherTaskViewModelDef = New-ViewModel @AnotherTaskSplat -AsString
$SampleFunctionViewModelDef = New-ViewModel @SampleFunctionSplat -AsString
$DotSourceViewModelDef = New-ViewModel @DotSourcedSplat -AsString
$ProgressBarViewModelDef = New-ViewModel @ProgressBarSplat -AsString
$ColorViewModelDef = New-ViewModel @ColorSplat -AsString
$DemoViewModelDef = New-ViewModel @DemoSplat -AsString

# This creates these classes as one bundled assembly version.
# Requires using module PsModelUI since the ViewModelBase class is not imported with Import-Module
. ([scriptblock]::Create("
$LongTaskViewModelDef
$AnotherTaskViewModelDef
$SampleFunctionViewModelDef
$DotSourceViewModelDef
$ProgressBarViewModelDef
$ColorViewModelDef
$DemoViewModelDef
$MainViewModelDef
"))


$MainViewModel = New-ViewModel -Type MainViewModel -Unbound $false
$MainViewModel.ViewModels['Demo'].LongTaskViewModel.ServiceModel = $ServiceModel
$MainViewModel.ViewModels['Demo'].AnotherTaskViewModel.ServiceModel = $ServiceModel
$MainViewModel.ViewModels['Demo'].SampleFunctionViewModel.ServiceModel = $ServiceModel
$MainViewModel.ViewModels['Demo'].DotSourcedViewModel.ServiceModel = $ServiceModel
$MainViewModel.ViewModels['Demo'].ProgressBarViewModel.ServiceModel = $ServiceModel
[System.Windows.Data.BindingOperations]::EnableCollectionSynchronization($MainViewModel.ViewModels['Demo'].AnotherTaskViewModel.GridContent, $MainViewModel.ViewModels['Demo'].AnotherTaskViewModel.GridContentLock)

$WindowPath = "$PSScriptRoot\DataTemplates\DemoDataTemplates.xaml"
$HotReloadPath = "$PSScriptRoot\DataTemplates\DemoDataTemplatesXamlVisual.xaml"
$Window = New-WpfObject -Path $WindowPath -DataContext $MainViewModel -Namespace ('xmlns:local="clr-namespace:;assembly={0}" xmlns:ViewModels="clr-namespace:;assembly={1}" ' -f [MainViewModel].Assembly.FullName, [DemoViewModel].Assembly.FullName) -BaseUri "$PSScriptRoot/DataTemplates/"
$MainViewModel.Window = $Window
$MainViewModel.XamlString = Get-Content -Path $HotReloadPath -Raw

$Window.ShowDialog()
