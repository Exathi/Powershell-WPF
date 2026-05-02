function New-WpfObject {
    <#
        .SYNOPSIS
        Creates a WPF object with given Xaml from a string or file
        Uses the dedicated wpf xaml reader rather than the xmlreader.

        .PARAMETER Xaml
        The xaml string for to be parsed.

        .PARAMETER Path
        The full name to the xaml file to be parsed.

        .PARAMETER DataContext
        The ViewModel class object that the WpfObject will use.

        .PARAMETER Namespace
        The namespace for the in memory powershell assembly.
        This changes for each module/assembly and the order they load in.

        xmlns:local="clr-namespace:;assembly=PowerShell Class Assembly, Version=1.0.0.3, Culture=neutral, PublicKeyToken=null"
        (xmlns:local="clr-namespace:;assembly={0}" -f [CustomClass].Assembly.FullName)
        (xmlns:ps="clr-namespace:;assembly={0}" -f (Get-Module -Name ModuleName).ImplementingAssembly.FullName)

        .EXAMPLE
        $Window = New-WpfObject -Xaml $Xaml -DataContext $ViewModel
        $ResourceDictionary = New-WpfObject -Path $Path
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param (
        [Parameter(Mandatory, ValueFromPipeline, Position = 0, ParameterSetName = 'HereString')]
        [string[]]$Xaml,
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0, ParameterSetName = 'Path')]
        [ValidateScript({ Test-Path $_ })]
        [string[]]$Path,
        [Parameter(Mandatory = $false, ParameterSetName = 'Path')]
        [string[]]$Namespace,
        [ViewModelBase]$DataContext
    )

    process {
        $RawXaml = if ($PSBoundParameters.ContainsKey('Path')) {
            $Raw = Get-Content -Path $Path -Raw
            if ($Namespace) {
                $Raw.Replace('<Window ', "<Window $($Namespace -join ' ') ", [System.StringComparison]::OrdinalIgnoreCase)
            } else {
                $Raw
            }
        } else {
            $Xaml
        }

        $WpfObject = [System.Windows.Markup.XamlReader]::Parse($RawXaml)

        if ($DataContext) {
            # because $DataContext can be created unbound, it may not have the same dispatcher as $WpfObject so it is set here.
            $DataContext.psobject.Dispatcher = $WpfObject.Dispatcher
            $WpfObject.DataContext = $DataContext
        }

        $WpfObject
    }
}
