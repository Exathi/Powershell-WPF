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
        The version changes for each module/assembly and the order loaded in.
        Each different inline class defined in the terminal creates a new assembly version for it.
        Classes defined in another ps1 and invoked in count as the same assembly.

        xmlns:local="clr-namespace:;assembly=PowerShell Class Assembly, Version=1.0.0.3, Culture=neutral, PublicKeyToken=null"
        (xmlns:local="clr-namespace:;assembly={0}" -f [CustomClass].Assembly.FullName)
        (xmlns:ps="clr-namespace:;assembly={0}" -f (Get-Module -Name ModuleName).ImplementingAssembly.FullName)

        .PARAMETER BaseUri
        The base URI for the Xaml. This allows for relative paths to be used in the Xaml for resources.
        Must end with a forward slash. Example: "C:/Path/To/Resources/"

        .EXAMPLE
        $Window = New-WpfObject -Xaml $Xaml -DataContext $ViewModel

        .EXAMPLE
        $ResourceDictionary = New-WpfObject -Path $Path

        .EXAMPLE
        $Window = New-WpfObject -Path $Path -DataContext $ViewModel -Namespace ('xmlns:local="clr-namespace:;assembly={0}"' -f [ViewModel].Assembly.FullName) -BaseUri "$PSScriptRoot/"
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
        [string]$BaseUri,
        [ViewModelBase]$DataContext
    )

    process {
        $RawXaml = if ($PSBoundParameters.ContainsKey('Path')) {
            $Raw = Get-Content -Path $Path -Raw
            if ($Namespace) {
                $Pattern = '<([^ ]+)'
                $Replacement = '<$1 {0}' -f $($Namespace -join ' ')
                [regex]::new($Pattern).Replace($Raw, $Replacement, [System.StringComparison]::CurrentCultureIgnoreCase)
            } else {
                $Raw
            }
        } else {
            $Xaml
        }

        $WpfObject = if ($BaseUri) {
            $SanitizedUri = $BaseUri -replace '\\', '/'
            if ($SanitizedUri[-1] -ne '/') { $SanitizedUri = "$SanitizedUri/" }
            $ParserContext = [System.Windows.Markup.ParserContext]::new()
            $ParserContext.BaseUri = [System.Uri]::new($SanitizedUri, [System.UriKind]::Absolute)
            [System.Windows.Markup.XamlReader]::Parse($RawXaml, $ParserContext)
        } else {
            [System.Windows.Markup.XamlReader]::Parse($RawXaml)
        }

        if ($DataContext) {
            # because $DataContext can be created unbound, it may not have the same dispatcher as $WpfObject so it is set here.
            $DataContext.psobject.Dispatcher = $WpfObject.Dispatcher
            $WpfObject.DataContext = $DataContext
        }

        $WpfObject
    }
}
