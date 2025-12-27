using Assembly PresentationFramework
using Assembly PresentationCore
using Assembly WindowsBase
using module .\WPFClassHelpers.psm1
Import-Module .\CreateClassInstanceHelper.psm1
. .\ViewModel.ps1

$ThreadManager = [ThreadManager]::new('Get-Million')
$MyViewModel = New-UnboundClassInstance MyViewModel
$MyViewModel.psobject.CreateButtons($ThreadManager)

[System.Windows.Data.BindingOperations]::EnableCollectionSynchronization($MyViewModel.psobject.Jobs, $MyViewModel.psobject.JobsLock)
# $wpf = New-WPFObject -Path "$PSScriptRoot\Views\MainWindow.xaml" -BaseUri "$PSScriptRoot\"
$wpf = New-WPFObject -Path "$PSScriptRoot\Views\PartialWindow.xaml" -BaseUri "$PSScriptRoot\"
$wpf.DataContext = $MyViewModel

# $wpf.add_Closing({
#     param([System.ComponentModel.CancelEventHandler]$Handler)
#     $ThreadManager.Dispose()
# })

$wpf.ShowDialog()

$MyViewModel.psobject.Jobs | Format-Table
