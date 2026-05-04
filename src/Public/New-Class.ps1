function New-Class {
    <#
        .SYNOPSIS
        Dynamically creates a class object that inherits ViewModeBase.
        Properties preceeed by `$this` used in Methods that aren't defined in PropertyDeclaration will automatically be defined as a property of the class.
        Method overloads are not supported.

        Allows for classes of the same type name with different properties and methods but allows for hot reloading of classes.

        .EXAMPLE
        $A = New-Class -ClassName 'ClassType' -PropertyDeclaration 'One'
        $B = New-Class -ClassName 'ClassType' -PropertyInit ([pscustomobject]@{
            Name = 'NewProperty'
            Type = ([string])
            Init = 'Hello World'
        })
        $C = New-Class -ClassName 'ClassType' -Methods ([pscustomobject]@{
            Name = 'ClassMethod'
	        Body = {return 'Hello World'}
        })

        .PARAMETER ClassName
        The name of the class
        'MyClass'

        Creates:
        class MyClass : pscustomobject {
            MyClass() {}
        }

        .PARAMETER Inherits
        The name of the class to inherit and interface names.
        Follows powershell interitance so only ONE class can be inherited and any dotnet interfaces can be added.

        .EXAMPLE
        $Foo = New-Class -ClassName 'Foo' -Inherits 'pscustomobject', 'System.IDisposable' -PropertyDeclaration 'Bar' -Methods @(New-ClassMethod -Name Dispose -Body {})

        class Foo {
            Dispose(){}
        }

        $FooDefinition = New-Class -ClassName 'Foo' -Inherits 'pscustomobject', 'System.IDisposable' -PropertyDeclaration 'Bar' -Methods @(New-ClassMethod -Name Dispose -Body {}) -AsString
        . ([scriptblock]::Create($FooDefinition))

        $Baz = New-Class -ClassName 'Baz' -Inherits 'Foo'

        class Baz : Foo {
            $_Bar
            Dispose(){}
        }

        .EXAMPLE
        $FooDefinition = New-Class -ClassName 'Foo' -Inherits 'pscustomobject', 'System.IDisposable' -PropertyInit (New-ClassProperty -Name 'test' -Type 'string' -Init {'yes'})  -Methods @(New-ClassMethod -Name Dispose -Body {}) -AsString
        . ([scriptblock]::Create($FooDefinition))
        $Baz = New-Class -ClassName 'Baz' -Inherits 'Foo'

        .PARAMETER PropertyDeclaration
        Takes an array of strings.
        @('property1', 'PropertY2')

        Creates:

        class ViewModel : ViewModelBase {
            $property1
            $PropertY2
        }

        .PARAMETER PropertyInit
        A pscustomobject comprised of the below:

        Name = The name of the property
        Type = The type of the property
        Init = A scriptblock that initializes the property in the constructor. If the scriptblock has no statements or is null, it will not be invoked.
        Get = Optional with Set - A scriptblock that defines the get accessor of a scriptproperty
        Set = Optional with Get - A scriptblock that defines the set accessor of a scriptproperty
        ExcludePrefix = If $true, the property will be created without a backing field with the same name as the property instead of _propertyname

        [pscustomobject]@{
            Name = 'PropertyName'
            Type = ([string])
            Init = 'Hello World'
            Get = { return $this.PropertyName }
            Set = { param($value) $this.PropertyName = $value }
        }

        .EXAMPLE
        New-ClassProperty -Name 'PropertyName' -Type ([string]) -Init { 'Hello World' } -Get { return $this._PropertyName } -Set { param($value) $this._PropertyName = $value }

        .EXAMPLE
        New-ClassProperty -Name 'PropertyName' -Type ([string]) -Init { 'Hello World' } -Get { return $this.PropertyName } -Set { param($value) $this.PropertyName = $value } -ExcludePrefix

        .PARAMETER Methods
        Will also create class properties for methods that call $this.propertyname that isn't in $PropertyDeclaration
        Requires a hashtable of name and it's Body as a scriptblock
        @(
            DoMethod = {return 'hello world'}
            OtherMethod = {$this.Property = 'foo'} # if '$Property' is not defined in PropertyDeclaration, it will be added automatically if AutomaticProperties = $true
        )

        Creates:

        class ViewModel : ViewModelBase {
            $_Property
            [object]DoMethod() {
                return "hello world"
            }
            [void]OtherMethod() {
                $this.Property = 'foo'
            }
        }

        .PARAMETER Unbound
        Creates the class with no runspace affinity if $true. Otherwise class methods cannot be called when the UI is running.
        Call with Unbound = $false to see errors, if any.

        .PARAMETER AutomaticProperties
        Automatically creates class properties for any $this.property reference in the method bodies that isn't already defined in $PropertyDeclaration or $PropertyInit. This is useful for quickly prototyping but it is recommended to define properties explicitly for maintainability.

        .PARAMETER AsString
        Returns the full class definition as a string instead of the object.

        .PARAMETER ExcludeScriptProperty
        Use when not inherting a pscustomobject.
        Declares all properties as normal without add-member and without the default underscore prefix.
        Ignores the ExcludePrefix of PropertyInit.

    #>
    [CmdletBinding(DefaultParameterSetName = 'AsObject')]
    param (
        [Parameter(Mandatory)]
        [string]$ClassName,
        [string[]]$Inherits = 'pscustomobject',
        [Parameter(ParameterSetName = 'AsObject')]
        [string[]]$PropertyDeclaration,
        [Parameter(ParameterSetName = 'AsTypeWithDefinition')]
        [pscustomobject[]]$PropertyInit,
        [pscustomobject[]]$Methods,
        [bool]$Unbound = $true,
        [bool]$AutomaticProperties = $false,
        [switch]$AsString,
        [switch]$ExcludeScriptProperty
    )

    $StringBuilder = [System.Text.StringBuilder]::new()

    # start class line
    $null = $StringBuilder.Append("class $ClassName")
    if (-not [string]::IsNullOrWhiteSpace($Inherits)) {
        $null = $StringBuilder.Append(' : ')
        $null = $StringBuilder.Append(($Inherits -join ','))
    }
    $null = $StringBuilder.AppendLine(' {')

    # methods
    foreach ($PSMethod in $Methods) {
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

    # class properties
    foreach ($Name in $PropertyDeclaration) {
        if ($Name -notmatch '^\w+$') { throw 'property name can only contain letters and numbers' }
        if ($ExcludeScriptProperty) {
            $null = $StringBuilder.AppendLine(('${0}' -f $Name))
        } else {
            $null = $StringBuilder.AppendLine(('$_{0}' -f $Name))
        }
    }

    foreach ($ClassProperty in $PropertyInit) {
        if ($ClassProperty.Name -notmatch '^\w+$') { throw 'property name can only contain letters and numbers' }
        if ($ExcludeScriptProperty) {
            $null = $StringBuilder.AppendLine(('[{0}]${1}' -f $ClassProperty.Type, $ClassProperty.Name))
        } else {
            if ($ClassProperty.ExcludePrefix) {
                $null = $StringBuilder.AppendLine(('[{0}]${1}' -f $ClassProperty.Type, $ClassProperty.Name))
            } else {
                $null = $StringBuilder.AppendLine(('[{0}]$_{1}' -f $ClassProperty.Type, $ClassProperty.Name))
            }
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

        if ($ExcludeScriptProperty) {
            $BackingFieldName = $ClassProperty.Name
        }

        $RawText = @"
`$this.$BackingFieldName = [scriptblock]::Create(
@'
,($($ClassProperty.Init.ToString()))
'@
).InvokeReturnAsIs()
"@
        $null = $StringBuilder.AppendLine($RawText)
    }

    $ConstructorScriptProperties = $PropertyDeclaration -join '","'
    if ((-not [string]::IsNullOrWhiteSpace($ConstructorScriptProperties) -and -not $ExcludeScriptProperty) ) {
        $null = $StringBuilder.Append('foreach ($ClassProperty in @("')
        $null = $StringBuilder.Append($ConstructorScriptProperties)
        $null = $StringBuilder.AppendLine('")) {')
        $null = $StringBuilder.AppendLine(@'
    $ProperName = $ClassProperty
    $Splat = @{
        Name = $ProperName
        MemberType = 'ScriptProperty'
        Value = [scriptblock]::Create('return ,$this.psobject.{0}' -f $ClassProperty)
        SecondValue = [scriptblock]::Create(('param($value)
            $this.psobject.{0} = $value' -f $ClassProperty, $ProperName)
        )
    }
    $this | Add-Member @Splat
}
'@)
    }

    foreach ($ClassProperty in $PropertyInit) {
        $BackingFieldName = if ($ClassProperty.ExcludePrefix) {
            $ClassProperty.Name
        } else {
            "_$($ClassProperty.Name)"
        }
        if ($ClassProperty.Get -and $ClassProperty.Set) {
            $null = $StringBuilder.AppendLine(('$this | Add-Member -MemberType ScriptProperty -Name {0} -Value {{{1}}} -SecondValue {{{2}}}' -f $ClassProperty.Name, $ClassProperty.Get.Ast.GetScriptBlock(), $ClassProperty.Set.Ast.GetScriptBlock()))
        } else {
            if (-not $ExcludeScriptProperty) {
                $null = $StringBuilder.AppendLine(('$this | Add-Member -MemberType ScriptProperty -Name {0} -Value {{{1}}} -SecondValue {{{2}}}' -f $ClassProperty.Name, ('return ,$this.psobject.{0}' -f $BackingFieldName), ('param($value)
            $this.psobject.{0} = $value' -f $BackingFieldName)))
            }
        }
    }

    # end constructor
    $null = $StringBuilder.AppendLine('}')

    # end class definition
    $null = $StringBuilder.AppendLine('}')

    # find all $this references from preliminary definition and create class properties for them.
    $UniqueProperties = [System.Collections.Generic.HashSet[string]]::new()
    if ($AutomaticProperties) {
        $PreliminaryDefinition = ([scriptblock]::Create($StringBuilder.ToString()))
        $ClassProperties = $PreliminaryDefinition.Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | Where-Object { $_.VariablePath.UserPath -eq 'this' }

        # remove the newline and closing brace to add $this variables as properties from methods.
        $null = $StringBuilder.Remove($StringBuilder.Length - 6, 6)

        # get all unique $this properties and add them as $property if not added in $PropertyDeclaration
        foreach ($ClassProperty in $ClassProperties.Parent.Member.Extent.Text) {
            if ([string]::IsNullOrWhiteSpace($ClassProperty)) { continue }
            if ($PropertyDeclaration -contains $ClassProperty) { continue }
            if ($PropertyInit.Name -contains $ClassProperty) { continue }
            if ($PropertyInit.Name -contains $ClassProperty) { continue }
            if ($ClassProperty -eq 'psobject') { continue }
            $null = $UniqueProperties.Add($ClassProperty)
        }

        $null = $StringBuilder.AppendLine()

        if (-not $ExcludeScriptProperty) {
            foreach ($ClassProperty in $UniqueProperties.GetEnumerator()) {
                $null = $StringBuilder.AppendLine(('$this | Add-Member -MemberType ScriptProperty -Name {0} -Value {{{1}}} -SecondValue {{{2}}}' -f $ClassProperty, ('return ,$this.psobject.{0}' -f "_$ClassProperty"), ('param($value)
            $this.psobject.{0} = $value' -f "_$ClassProperty")))
            }
        }

        # end constructor
        $null = $StringBuilder.AppendLine('}')

        foreach ($ClassProperty in $UniqueProperties.GetEnumerator()) {
            if ($ExcludeScriptProperty) {
                $null = $StringBuilder.AppendLine('${0}' -f $ClassProperty)
            } else {
                $null = $StringBuilder.AppendLine('$_{0}' -f $ClassProperty)
            }
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

    $DynamicClass
}
