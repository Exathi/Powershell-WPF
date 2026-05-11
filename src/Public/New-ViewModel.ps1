function New-ViewModel {
    <#
        .SYNOPSIS
        Dynamically creates a class object that inherits ViewModeBase.

        .DESCRIPTION
        Creates a class object that inherits ViewModeBase. View models created this way will use the same shared runspacepool from Set-ViewModelPool.
        Properties preceeed by `$this` used in Methods that aren't defined in PropertyDeclaration will automatically be defined as a property of the class.
        Method overloads are not supported for commands.

        .EXAMPLE
        $A = New-ViewModel -ClassName 'ClassType' -PropertyDeclaration 'One'
        $B = New-ViewModel -ClassName 'ClassType' -PropertyInit ([pscustomobject]@{
            Name = 'NewProperty'
            Type = ([string])
            Init = 'Hello World'
        })
        $C = New-ViewModel -ClassName 'ClassType' -Methods ([pscustomobject]@{
            Name = 'ClassMethod'
	        Body = {return 'Hello World'}
            Throttle = 1
            IsAsync = $false
        })

        .PARAMETER ClassName
        The name of the class
        'MyClass'

        Creates:
        class MyClass : ViewModeBase {
            MyClass() {}
        }

        .PARAMETER PropertyDeclaration
        Takes an array of strings.
        @('property1', 'PropertY2')

        Creates:

        class ViewModel : ViewModelBase {
            $_property1
            $_PropertY2
        }

        .PARAMETER PropertyInit
        Use New-ClassProperty as a helper function to create the objects needed for this parameter.
        Takes an array of PSCustomObjects with the following properties:

        Name: Name of the property
        Type: Type of the property (e.g. [string], [int], etc.)
        Init: A scriptblock that defines the initial value of the property.
            It can reference other properties defined in $PropertyInit or $PropertyDeclaration with `$this.PropertyName`.
            It will be invoked in the constructor of the class so it can also reference other properties defined in the same $PropertyInit array.
        ExcludePrefix: if $true, the backing property will be created without the '_' prefix.
            Only used for consistency in binding name rather than binding to _name vs just name.
        Get: Optional with Set - A scriptblock that defines the get accessor of the property. It can reference other properties defined in $PropertyInit or $PropertyDeclaration with `$this.PropertyName`.
        Set: Optional with Get - A scriptblock that defines the set accessor of the property. It can reference other properties defined in $PropertyInit or $PropertyDeclaration with `$this.PropertyName`.

        .EXAMPLE
        New-ViewModel -ClassName 'Test' -PropertyInit @(
            [pscustomobject]@{Name = 'Property1'; Type = ([string]); Init = {'Hello World'}}
            [pscustomobject]@{Name = 'Property2'; Type = ([int]); Init = {42}; ExcludePrefix = $true}
        )

        .PARAMETER Methods
        Use New-ViewModelMethod as a helper function to create the objects needed for this parameter.
        Takes an array of PSCustomObjects with the following properties:

        Name: Name of the method
        Body: A scriptblock that defines the body of the method. It can reference properties defined in $PropertyInit or $PropertyDeclaration with `$this.PropertyName`.
            The paramblock defines the parameters that the method will receive.
            Can be strongly typed by defining the parameters in the paramblock with their types.
        CommandName: If ExcludeCommand is $true, this will be the name of the command property created for this method. If not provided, the command property will be named '{MethodName}Command'.
        ExcludeCommand: If $true, no command property will be created for this method.
        Throttle: The max number of times the equivalent method command can be running at a given time. Default is 1.
        IsAsync: This signals the equivalent command to be invoked in another runspace if $true or on the console thread. Default is $true.

        Will also create class properties for methods that call $this.propertyname that isn't in $PropertyDeclaration or $PropertyInit if $AutomaticProperties is $true.

        .EXAMPLE
        $Test = New-ViewModel -ClassName 'Test' -Methods @(
            [pscustomobject]@{
                Name = 'DoMethod'
                Body = {return 'hello world'}
                Throttle = 1
                IsAsync = $false
            }
        )

        $Test.psobject.DoMethod()
        hello world


        Creates the following class:

        class Test : ViewModelBase {
            Test() {
                $this.DoMethodCommand = [ActionCommand]::new($this.psobject.DoMethod, $False, $this, 1)
            }
            $DoMethodCommand
            [object]DoMethod() {
                return 'hello world'
            }
        }

        .PARAMETER Unbound
        Creates the class with no runspace affinity if $true. Otherwise class methods cannot be called when the UI is running if invoking async buttons.

        .PARAMETER AutomaticProperties
        Automatically creates class properties for any $this.property reference in the method bodies that isn't already defined in $PropertyDeclaration or $PropertyInit. This is useful for quickly prototyping but it is recommended to define properties explicitly for maintainability.

        .PARAMETER AsString
        Returns the full class definition as a string instead of the object.

        .PARAMETER Type
        Used to create classes of the same assembly version after the -AsString definition has been invoked in the current scope.

        .EXAMPLE
        using module .\PsModelUI
        $MainViewModelDef = New-ViewModel -ClassName 'MainViewModel' -PropertyInit @(New-ClassProperty -Name Prop -Init {'Example'}) -AsString
        . ([scriptblock]::Create("$MainViewModelDef"))

        New-ViewModel -Type MainViewModel -Unbound $false
        [MainViewModel]::new()

        .EXAMPLE
        Create classes of the same assembly instead of redefining every time.

        $MainViewModelDef = New-ViewModel -ClassName 'MainViewModel' -AsString
        $AnotherViewModelDef = New-ViewModel -ClassName 'AnotherViewModel' -AsString

        *** Important to call it together in the same scriptblock as multiple scriptblocks is treated the same as inlining the class in the terminal one at a time.
        . ([scriptblock]::Create("
        $MainViewModelDef
        $AnotherViewModelDef
        "))

        $Main = New-ViewModel -Type 'MainViewModel'
        $Another = New-ViewModel -Type 'AnotherViewModel'

        $Main.psobject.GetType().Assembly.FullName
        $Another.psobject.GetType().Assembly.FullName

        .PARAMETER ConstructorBody
        The body of the constructor. If unbound is $true this will not have access to imported functions.
    #>
    [CmdletBinding(DefaultParameterSetName = 'AsObject')]
    param (
        [Parameter(Mandatory, ParameterSetName = 'AsObject')]
        [Parameter(Mandatory, ParameterSetName = 'AsTypeWithDefinition')]
        [string]$ClassName,
        [Parameter(ParameterSetName = 'AsObject')]
        [string[]]$PropertyDeclaration,
        [Parameter(ParameterSetName = 'AsTypeWithDefinition')]
        [pscustomobject[]]$PropertyInit,
        [pscustomobject[]]$Methods,
        [bool]$Unbound = $true,
        [bool]$AutomaticProperties = $false,
        [switch]$AsString,
        [Parameter(ParameterSetName = 'AsSameAssembly')]
        [type]$Type,
        [scriptblock]$ConstructorBody
    )

    if ($Type) {
        if ($Unbound) {
            $DynamicClass = New-UnboundClassInstance $Type
        } else {
            $DynamicClass = [activator]::CreateInstance($Type)
        }

        if (!$script:ViewModelThread['Pool'] -or $script:ViewModelThread['Pool'].IsDisposed) { Set-ViewModelPool }
        $DynamicClass.psobject.ViewModelThread = $script:ViewModelThread

        return $DynamicClass
    }

    $StringBuilder = [System.Text.StringBuilder]::new()

    # start class line
    $null = $StringBuilder.Append("class $ClassName")
    $null = $StringBuilder.Append(' : ViewModelBase')
    $null = $StringBuilder.AppendLine(' {')

    # class properties
    foreach ($Name in $PropertyDeclaration) {
        if ($Name -notmatch '^\w+$') { throw 'property name can only contain letters and numbers' }
        $null = $StringBuilder.AppendLine(('$_{0}' -f $Name))
    }

    foreach ($ClassProperty in $PropertyInit) {
        if ($ClassProperty.Name -notmatch '^\w+$') { throw 'property name can only contain letters and numbers' }
        if ($ClassProperty.ExcludePrefix) {
            $null = $StringBuilder.AppendLine(('[{0}]${1}' -f $ClassProperty.Type, $ClassProperty.Name))
        } else {
            $null = $StringBuilder.AppendLine(('[{0}]$_{1}' -f $ClassProperty.Type, $ClassProperty.Name))
        }
    }

    # base constructor
    $null = $StringBuilder.AppendLine(('{0}(){{' -f $ClassName))

    foreach ($ClassProperty in $PropertyInit) {
        if ($null -eq $ClassProperty.Init -or $ClassProperty.Init.Ast.EndBlock.Statements.Count -eq 0) { continue }

        if ($ClassProperty.ExcludePrefix) {
            $BackingFieldName = "psobject.$($ClassProperty.Name)"
        } else {
            $BackingFieldName = "psobject._$($ClassProperty.Name)"
        }

        $null = $StringBuilder.Append(('$this.{0} = ' -f $BackingFieldName))
        $null = $StringBuilder.AppendLine($ClassProperty.Init.ToString())
    }

    foreach ($ClassProperty in $PropertyInit) {
        $BackingFieldName = if ($ClassProperty.ExcludePrefix) {
            $ClassProperty.Name
        } else {
            "_$($ClassProperty.Name)"
        }
        if ($ClassProperty.Get -and $ClassProperty.Set) {
            $null = $StringBuilder.AppendLine(('$this | Add-Member -MemberType ScriptProperty -Name {0} -Value {{{1}}} -SecondValue {{{2}}} -Force' -f $ClassProperty.Name, $ClassProperty.Get.Ast.GetScriptBlock(), $ClassProperty.Set.Ast.GetScriptBlock()))
        }
    }

    # # add a command property for each method
    $ExcludeProperties = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($PSMethod in $Methods) {
        if ($PSMethod.ExcludeCommand) { continue }
        $CommandName = if ([string]::IsNullOrWhiteSpace($PSMethod.CommandName)) { "$($PSMethod.Name)Command" } else { $PSMethod.CommandName }
        $null = $ExcludeProperties.Add($CommandName)
        $null = $ExcludeProperties.Add("_$CommandName")

        # The powershell instance does not know of New-ActionCommand but knows of the type [ActionCommand]
        # $null = $StringBuilder.AppendLine(('$this.{0} = New-ActionCommand -MethodName {1} -Target $this -Throttle {2} -IsAsync ${3}' -f $CommandName, $PSMethod.Name, $PSMethod.Throttle, $PSMethod.IsAsync))
        $null = $StringBuilder.AppendLine(('$this.{0} = [ActionCommand]::new($this.psobject.{1}, ${2}, $this, {3})' -f $CommandName, $PSMethod.Name, $PSMethod.IsAsync, $PSMethod.Throttle))
    }

    if ($ConstructorBody) {
        $null = $StringBuilder.AppendLine($ConstructorBody.ToString())
    }

    # end constructor
    $null = $StringBuilder.AppendLine('}')


    # methods
    foreach ($PSMethod in $Methods) {
        # Create a command property for the method and append 'Command' to the end.
        if (-not $PSMethod.ExcludeCommand) {
            if ([string]::IsNullOrWhiteSpace($PSMethod.CommandName)) {
                $null = $StringBuilder.AppendLine(('${0}Command' -f $PSMethod.Name))
            } else {
                $null = $StringBuilder.AppendLine(('${0}' -f $PSMethod.CommandName))
            }
        }

        if (($PSMethod.Body.Ast.EndBlock.Statements.Where({ $null -ne $_.Pipeline })).Count -eq 0) {
            $null = $StringBuilder.Append(('[void]{0}(' -f $PSMethod.Name))
        } else {
            $null = $StringBuilder.Append(('[object]{0}(' -f $PSMethod.Name))
        }
        $ParameterText = if ($PSMethod.Body.Ast.ParamBlock.Parameters.Extent.Text) {
            $PSMethod.Body.Ast.ParamBlock.Parameters.Extent.Text -join ', '
        } else {
            ''
        }
        $null = $StringBuilder.AppendLine(('{0}) {{' -f $ParameterText))

        foreach ($Statement in $PSMethod.Body.Ast.EndBlock.Statements.Extent.Text) {
            $null = $StringBuilder.AppendLine($Statement)
        }
        $null = $StringBuilder.AppendLine('}')
    }

    # end class definition
    $null = $StringBuilder.AppendLine('}')

    # find all $this references from preliminary definition and create class properties for them.
    $UniqueProperties = [System.Collections.Generic.HashSet[string]]::new()
    if ($AutomaticProperties) {
        $PreliminaryDefinition = ([scriptblock]::Create($StringBuilder.ToString()))
        $ClassProperties = $PreliminaryDefinition.Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | Where-Object { $_.VariablePath.UserPath -eq 'this' }

        # remove the newline and closing brace to add $this variables as properties from methods.
        $null = $StringBuilder.Remove($StringBuilder.Length - 3, 3)

        # get all unique $this properties and add them as $property if not added in $PropertyDeclaration
        foreach ($ClassProperty in $ClassProperties) {
            $PropertyName = $ClassProperty.Parent.Member.Extent.Text
            if ([string]::IsNullOrWhiteSpace($PropertyName)) { continue }
            if ($PropertyDeclaration -contains $PropertyName) { continue }
            if ($PropertyInit.Name -contains $PropertyName) { continue }
            if ($PropertyName -eq 'psobject') { continue }
            if ($PropertyName -in $ExcludeProperties) { continue }
            if ($null -ne $PropertyName -and -not $ClassProperty.Parent.Extent.Text.StartsWith('$')) { continue }

            $null = $UniqueProperties.Add($PropertyName)
        }

        foreach ($ClassProperty in $UniqueProperties.GetEnumerator()) {
            $null = $StringBuilder.AppendLine('$_{0}' -f $ClassProperty)
        }

        # end class definition
        $null = $StringBuilder.AppendLine('}')
    }

    if ($AsString) {
        return $StringBuilder.ToString()
    }

    $Definition = ([scriptblock]::Create($StringBuilder.ToString()))
    . $Definition

    $DynamicClass = if ($Unbound) {
        New-UnboundClassInstance $ClassName
    } else {
        [activator]::CreateInstance($ClassName)
    }

    # add a command property for each method
    # foreach ($PSMethod in $Methods) {
    #     if ($PSMethod.ExcludeCommand) { continue }
    #     $CommandName = if ([string]::IsNullOrWhiteSpace($PSMethod.CommandName)) { "$($PSMethod.Name)Command" } else { $PSMethod.CommandName }
    #     $DynamicClass."$CommandName" = New-ActionCommand -MethodName $PSMethod.Name -Target $DynamicClass -Throttle $PSMethod.Throttle -IsAsync $PSMethod.IsAsync
    # }

    if (!$script:ViewModelThread['Pool'] -or $script:ViewModelThread['Pool'].IsDisposed) { Set-ViewModelPool }
    $DynamicClass.psobject.ViewModelThread = $script:ViewModelThread

    $DynamicClass
}
