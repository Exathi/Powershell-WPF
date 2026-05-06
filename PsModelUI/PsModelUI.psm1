Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
# [NoRunspaceAffinity()]
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
        $this.psobject.UpdateWithDispatcherDelegate = $this.psobject.CreateDelegate($this.psobject.UpdateWithDispatcher)
        $this.psobject.AddPropertyChangedToProperties()
    }

    ViewModelBase([bool]$AddDefault) {
        $this.psobject.UpdateWithDispatcherDelegate = $this.psobject.CreateDelegate($this.psobject.UpdateWithDispatcher)
        if ($AddDefault) { $this.psobject.AddPropertyChangedToProperties() }
    }

    [void]AddPropertyChangedToProperties() {
        $this.psobject.AddPropertyChangedToProperties($null)
    }

    [void]AddPropertyChangedToProperties([string[]]$Exclude) {
        $PropertiesToExclude = 'PropertyChanged', 'Dispatcher', 'ViewModelThread', 'LastAction', 'UpdateWithDispatcherDelegate' + $Exclude
        $this.psobject.psobject.Members.Where({
                $_.MemberType -eq 'Property' -and
                $_.IsSettable -eq $true -and
                $_.IsGettable -eq $true -and
                $_.Name -notin $PropertiesToExclude
            }
        ).ForEach(
            {
                $ProperName = if ($_.Name.StartsWith('_')) { $_.Name.Remove(0, 1) } else { $_.Name }
                $Splat = @{
                    Name = $ProperName
                    MemberType = 'ScriptProperty'
                    Value = [scriptblock]::Create('return ,$this.psobject.{0}' -f $_.Name)
                    SecondValue = [scriptblock]::Create(('param($value)
                        $this.psobject.{0} = $value
                        $this.psobject.RaisePropertyChanged("{1}")' -f $_.Name, $ProperName)
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

    [void]UpdateView([pscustomobject]$UpdateValue) {
        if ($null -eq $UpdateValue) { return }
        $this.psobject.InvokeDispatcher($UpdateValue)
    }

    hidden [void]UpdateWithDispatcher($UpdateValue) {
        $UpdateValue.psobject.Properties | ForEach-Object {
            try {
                $this.$($_.Name) = $_.Value
            } catch {
                Write-Warning ('Tried to update class property that does not exist: {0}' -f $_.Name)
            }
        }
    }

    hidden [void]InvokeDispatcher($UpdateValue) {
        $this.psobject.Dispatcher.BeginInvoke(9, $this.psobject.UpdateWithDispatcherDelegate, $UpdateValue)
    }

    [System.Threading.Tasks.Task]StartAsync($MethodToRunAsync, [ViewModelBase]$Target, $CommandParameter, $ActionCommand) {
        $Powershell = [powershell]::Create()
        $Powershell.RunspacePool = $Target.psobject.ViewModelThread['Pool'] # Will use a default runspace if ViewModelThread is $null

        $Delegate = if ($null -eq $CommandParameter -and $ActionCommand.psobject.Throttle -gt 0) {
            {
                param($NoContextMethod, $ActionCommand)
                try {
                    $NoContextMethod.Invoke()
                    $null = $ActionCommand.psobject.Dispatcher.InvokeAsync($ActionCommand.psobject.RemoveWorkerDelegate)
                    # Pipeline output can be received in $LastAction.Result
                } catch { throw $_ }
            }
        } elseif ($null -eq $CommandParameter -and $ActionCommand.psobject.Throttle -eq 0) {
            {
                param($NoContextMethod)
                try {
                    $NoContextMethod.Invoke()
                } catch { throw $_ }
            }
        } elseif ($null -ne $CommandParameter -and $ActionCommand.psobject.Throttle -eq 0) {
            {
                param($NoContextMethod, $CommandParameter)
                try {
                    $NoContextMethod.Invoke($CommandParameter)
                } catch { throw $_ }
            }
        } else {
            {
                param($NoContextMethod, $ActionCommand, $CommandParameter)
                try {
                    $NoContextMethod.Invoke($CommandParameter)
                    $ActionCommand.psobject.Dispatcher.InvokeAsync($ActionCommand.psobject.RemoveWorkerDelegate)
                } catch { throw $_ }
            }
        }

        $NoContext = $Delegate.Ast.GetScriptBlock()

        $null = $Powershell.AddScript($NoContext)
        $null = $Powershell.AddParameter('NoContextMethod', $MethodToRunAsync)
        if ($null -ne $CommandParameter) { $null = $Powershell.AddParameter('CommandParameter', $CommandParameter) }
        if ($ActionCommand.psobject.Throttle -gt 0) { $null = $Powershell.AddParameter('ActionCommand', $ActionCommand) }
        $Handle = $Powershell.BeginInvoke()

        $EndInvokeDelegate = $this.psobject.CreateDelegate($Powershell.EndInvoke, $Powershell) # Not needed with pwsh
        $Task = [System.Threading.Tasks.Task]::Factory.FromAsync($Handle, $EndInvokeDelegate)
        $this.psobject.LastAction = $Task

        return $Task
    }

    $Dispatcher #= [System.Windows.Threading.Dispatcher]::CurrentDispatcher # requires types to be loaded in ScriptsToProcess
    [System.Collections.Concurrent.ConcurrentDictionary[string, System.Management.Automation.Runspaces.RunspacePool]]$ViewModelThread
    [System.Threading.Tasks.Task]$LastAction
    $UpdateWithDispatcherDelegate
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

        if ($this.psobject.IsAsync) {
            if ($this.psobject.ActionObject) {
                $this.psobject.LastAction = $this.psobject.StartAsync($this.psobject.ActionObject, $this.psobject.Target, $CommandParameter, $this)
            } else {
                $this.psobject.LastAction = $this.psobject.StartAsync($this.psobject.Action, $this.psobject.Target, $null, $this)
            }
        } else {
            if ($this.psobject.ActionObject) {
                $this.psobject.ActionObject.Invoke($CommandParameter)
            } else {
                $this.psobject.Action.Invoke()
            }
            if ($this.psobject.Throttle -gt 0) { $this.psobject.RemoveWorker() }
        }
    }
    # End ICommand Implementation

    ActionCommand([System.Management.Automation.PSMethod]$Action, [bool]$IsAsync, [ViewModelBase]$Target, [int]$Throttle) : Base($false) {
        $this.psobject.Init($Action, $IsAsync, $Target, $Throttle)
    }

    hidden Init([System.Management.Automation.PSMethod]$Action, [bool]$IsAsync, [ViewModelBase]$Target, [int]$Throttle) {
        $Delegate = $this.psobject.CreateDelegate($Action, $Target)

        if ($Delegate -is [action]) {
            $this.psobject.Action = $Delegate
        } else {
            $this.psobject.ActionObject = $Delegate
        }

        $this.psobject.IsAsync = $IsAsync
        $this.psobject.Target = $Target
        $this.psobject.Throttle = $Throttle

        $this.psobject.RaiseCanExecuteChangedDelegate = $this.psobject.CreateDelegate($this.psobject.RaiseCanExecuteChanged)
        $this.psobject.RemoveWorkerDelegate = $this.psobject.CreateDelegate($this.psobject.RemoveWorker)

        @('Workers').ForEach(
            {
                $Splat = @{
                    Name = $_
                    MemberType = 'ScriptProperty'
                    Value = [scriptblock]::Create('return ,$this.psobject.{0}' -f $_)
                    SecondValue = [scriptblock]::Create('param($value)
                        $this.psobject.{0} = $value
                        $this.psobject.RaisePropertyChanged("{0}")
                        if ($this.psobject.Dispatcher) {{
                            $this.psobject.RaiseCanExecuteChanged()
                        }} elseif ([System.Windows.Threading.Dispatcher]::CurrentDispatcher.CheckAccess()) {{
                            $this.psobject.RaiseCanExecuteChanged()
                            $this.psobject.Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
                        }} else {{
                            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeAsync($this.psobject.RaiseCanExecuteChangedDelegate)
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
    [delegate]$Action
    [delegate]$ActionObject
    $CanExecuteAction
    $Workers = 0
    $Throttle = 1
    $RaiseCanExecuteChangedDelegate
    $RemoveWorkerDelegate
}

$script:Powershell = $null

function New-UnboundClassInstance ([type]$Type, [object[]]$Arguments = $null, [scriptblock]$Definition, [bool]$ShowErrors = $true) {
    if ($null -eq $script:Powershell) {
        $script:Powershell = [powershell]::Create()
        $script:Powershell.AddScript({
                function New-UnboundClassInstance ([type]$Type, [object[]]$Arguments = $null) {
                    [activator]::CreateInstance($Type, $Arguments)
                }
            }.Ast.GetScriptBlock()
        ).Invoke()
        $script:Powershell.Commands.Clear()
    }

    if ($Definition) {
        $null = $script:Powershell.AddScript($Definition).Invoke()
        $script:Powershell.Commands.Clear()
    }

    try {
        if ($null -eq $Arguments) { $Arguments = @() }
        $result = $script:Powershell.AddCommand('New-UnboundClassInstance').
        AddParameter('Type', $type).
        AddParameter('Arguments', $Arguments).
        Invoke()
        return $result
    } finally {
        $script:Powershell.Commands.Clear()
        if ($ShowErrors) {
            $script:Powershell.Streams.Error.ReadAll() | Write-Error
        }
    }
}

function New-ActionCommand {
    <#
        .SYNOPSIS
        Creates an [ActionCommand] object with the provided method in $Target.

        .PARAMETER MethodName
        Name of the method in $Target.

        .PARAMETER IsAsync
        This signals the equivalent command to be invoked in another runspace if $true or on the console thread.

        .PARAMETER Target
        The class object of the method.

        .PARAMETER Throttle
        The max number of times the equivalent method command can be running at a given time.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$MethodName,
        [bool]$IsAsync = $true,
        [Parameter(Mandatory)]
        [object]$Target,
        [int]$Throttle = 1
    )

    $Method = if ($Target.GetType().Name -eq 'PSCustomObject') {
        $Target.psobject.$MethodName
    } else {
        $Target.$MethodName
    }

    [ActionCommand]::new($Method, $IsAsync, $Target, $Throttle)
}

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

        .PARAMETER ClassType
        Used to create classes of the same assembly version after the -AsString definition has been invoked in the current scope.

        .EXAMPLE
        Create classes of the same assembly instead of redefining every time.

        $MainDef = New-Class -ClassName 'Main' -AsString
        $AnotherDef = New-Class -ClassName 'Another' -AsString

        *** Important to call it together in the same scriptblock as multiple scriptblocks is treated the same as inlining the class in the terminal one at a time.
        . ([scriptblock]::Create("
        $MainDef
        $AnotherDef
        "))

        $Main = New-Class -Type 'Main'
        $Another = New-Class -Type 'Another'

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
        [string[]]$Inherits = 'pscustomobject',
        [Parameter(ParameterSetName = 'AsObject')]
        [string[]]$PropertyDeclaration,
        [Parameter(ParameterSetName = 'AsTypeWithDefinition')]
        [pscustomobject[]]$PropertyInit,
        [pscustomobject[]]$Methods,
        [bool]$Unbound = $true,
        [bool]$AutomaticProperties = $false,
        [switch]$AsString,
        [switch]$ExcludeScriptProperty,
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

        return $DynamicClass
    }

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

        $null = $StringBuilder.Append(('$this.{0} = ' -f $BackingFieldName))
        $null = $StringBuilder.AppendLine($ClassProperty.Init.ToString())
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

    if ($ConstructorBody) {
        $null = $StringBuilder.AppendLine($ConstructorBody.ToString())
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

function New-ClassMethod {
    <#
        .SYNOPSIS
        Creates a pscustomobject to be consumed by New-Class to create a class method.

        .PARAMETER Name
        Name of the method to be defined in the class by New-Class.

        .PARAMETER Body
        Body of the method to be defined in the class by New-Class.
        Uses the paramblock to define parameters that the method will receive.
        **Paramblock is not required if the method doesn't need parameters.

        All $this references will be of the class.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$Body
        # [bool]$IsAsync = $true
    )

    [pscustomobject]@{
        Name = $Name
        Body = $Body.Ast.GetScriptBlock()
        # IsAsync = $IsAsync
    }
}

function New-ClassProperty {
    <#
        .SYNOPSIS
        Creates a pscustomobject to be consumed by New-ViewModel to create a class property with initial value.

        .PARAMETER PropertyName
        Name of the property

        .PARAMETER Type
        Type of the property
        'string'
        ([string])
        'object'
        'int'
        ([System.Collections.Generic.List[object]])

        .PARAMETER Init
        A scriptblock containing the initial value or object to create.
        Similar to list initialization in C++. Same braces!

        { 123 }
        { [System.Collections.Generic.List[object]]::new() }

        .PARAMETER ExcludePrefix
        Excludes adding an underscore "_" to the backing class property.
        Used for properties that need the actual object to bind since Add-Member value/secondvalue only return an object and not a guaranteed type.
        If the ScriptProperty is the same name as the backing field, the binding will use the backing field and may ignore the setter of ScriptProperty.

        **Bind as usual and a converter or bind to the _underlying object. Should only be needed for ILists/IEnumberable.

        .PARAMETER Get
        A scriptblock that overwrites the default Get of the property. The scriptblock must return the value to be retrieved.

        .PARAMETER Set
        A scriptblock that overwrites the default the Set of the property. The scriptblock must have a parameter to receive the value being set.
        If used with New-ViewModel, you will need to include $this.psobject.RaisePropertyChanged("PropertyName/_PropertyName") in the scriptblock to update bindings.

        .EXAMPLE
        New-ViewModelProperty -PropertyName 'a' -Type int -Init {1+1}
        The above will be consumed in New-ViewModel to generate:

        class Sample {
            [int]$_a
            Sample() {
                $this.a = [scriptblock]::Create(
@'
                ,(1+1)
'@
                ).InvokeReturnAsIs()
            }
        }
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [type]$Type,
        [scriptblock]$Init,
        [Parameter(ParameterSetName = 'WithAccessors')]
        [scriptblock]$Get,
        [Parameter(ParameterSetName = 'WithAccessors')]
        [scriptblock]$Set,
        [switch]$ExcludePrefix
    )

    if ($Name -notmatch '^\w+$') { throw 'Name can only contain letters and numbers' }

    [pscustomobject]@{
        Name = $Name
        Type = if ($Type) { $Type } else { [object] }
        Init = if ($Init.Ast.EndBlock.Statements.Count -gt 0) { $Init } else { $null }
        ExcludePrefix = $ExcludePrefix
        Get = if ($Get.Ast.EndBlock.Statements.Count -gt 0) { $Get } else { $null }
        Set = if ($Set.Ast.EndBlock.Statements.Count -gt 0) { $Set } else { $null }
    }
}

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
        Init: a scriptblock that defines the initial value of the property.
            It can reference other properties defined in $PropertyInit or $PropertyDeclaration with `$this.PropertyName`.
            It will be invoked in the constructor of the class so it can also reference other properties defined in the same $PropertyInit array.
        ExcludePrefix: if $true, the backing property will be created without the '_' prefix.
            Only used for consistency in binding name rather than binding to _name vs just name.
        Get: A scriptblock that defines the get accessor of the property. It can reference other properties defined in $PropertyInit or $PropertyDeclaration with `$this.PropertyName`.
        Set: A scriptblock that defines the set accessor of the property. It can reference other properties defined in $PropertyInit or $PropertyDeclaration with `$this.PropertyName`.

        .EXAMPLE
        New-ViewModel -ClassName 'Test' -PropertyInit @(
            [pscustomobject]@{Name = 'Property1'; Type = ([string]); Init = {'Hello World'}}
            [pscustomobject]@{Name = 'Property2'; Type = ([int]); Init = {42}; ExcludePrefix = $true}
        )

        .PARAMETER Methods
        Use New-ViewModelMethod as a helper function to create the objects needed for this parameter.
        Takes an array of PSCustomObjects with the following properties:

        Name: name of the method
        Body: a scriptblock that defines the body of the method. It can reference properties defined in $PropertyInit or $PropertyDeclaration with `$this.PropertyName`.
            The paramblock defines the parameters that the method will receive.
            Can be strongly typed by defining the parameters in the paramblock with their types.
        CommandName: if ExcludeCommand is $true, this will be the name of the command property created for this method. If not provided, the command property will be named '{MethodName}Command'.
        ExcludeCommand: if $true, no command property will be created for this method.
        Throttle: the max number of times the equivalent method command can be running at a given time. Default is 1.
        IsAsync: this signals the equivalent command to be invoked in another runspace if $true or on the console thread. Default is $true.

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

        $Test.DoMethod()
        hello world


        Creates the following class:

        class ViewModel : ViewModelBase {
            $DoMethodCommand
            [object]DoMethod() {
                return "hello world"
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
        foreach ($ClassProperty in $ClassProperties.Parent.Member.Extent.Text) {
            if ([string]::IsNullOrWhiteSpace($ClassProperty)) { continue }
            if ($PropertyDeclaration -contains $ClassProperty) { continue }
            if ($PropertyInit.Name -contains $ClassProperty) { continue }
            if ($ClassProperty -eq 'psobject') { continue }
            if ($ClassProperty -in $ExcludeProperties) { continue }

            $null = $UniqueProperties.Add($ClassProperty)
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

function New-ViewModelMethod {
    <#
        .SYNOPSIS
        Creates a pscustomobject to be consumed by New-ViewModel to create a class method.

        .PARAMETER Name
        Name of the method to be defined in the class by New-ViewModel.

        .PARAMETER Body
        Body of the method to be defined in the class by New-ViewModel.
        Uses the paramblock to define parameters that the method will receive.
        **Paramblock is not required if the method doesn't need parameters.

        All $this references will be of the class.

        .PARAMETER CommandName
        If specified, a command with this name will be created as that invokes the method.

        .PARAMETER ExcludeCommand
        If $true, no command will be created for this method. CommandName will be ignored if ExcludeCommand is $true.

        .PARAMETER Throttle
        The max number of times the equivalent method command can be running at a given time.

        .PARAMETER IsAsync
        This signals the equivalent command to be invoked in another runspace if $true or on the console thread.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$Body,
        [string]$CommandName,
        [switch]$ExcludeCommand,
        [int]$Throttle = 1,
        [bool]$IsAsync = $true
    )

    [pscustomobject]@{
        Name = $Name
        Body = $Body.Ast.GetScriptBlock()
        CommandName = $CommandName
        ExcludeCommand = $ExcludeCommand
        Throttle = $Throttle
        IsAsync = $IsAsync
    }
}

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

# Use an object so we can hot swap the runspacepool on calls to Set-ViewModelPool on all ViewModels if needed.
$script:ViewModelThread = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Management.Automation.Runspaces.RunspacePool]]::new()

function Set-ViewModelPool {
    <#
        .SYNOPSIS
        Creates and opens the global runspacepool to be used by each viewmodel created by New-ViewModel.

        .DESCRIPTION
        Runspacepool is stored in module script scope: $script:ViewModelThread as a concurrent dictionary.
        It is added to each ViewModel created by New-ViewModel.
        Will be disposed and recreated on each call.

        .PARAMETER MaxRunspaces
        Max number of runspaces in the pool to be available for use.

        .PARAMETER Functions
        Name of the function defined inline to be available in the runspacepool.

        .PARAMETER StartupScripts
        Full paths of the scripts to run in the new runspace created by the runspacepool.
    #>
    [CmdletBinding()]
    param (
        [int]$MaxRunspaces = $([int]$env:NUMBER_OF_PROCESSORS + 1),
        [string[]]$Functions,
        [string[]]$StartupScripts
    )

    $State = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $State.ThrowOnRunspaceOpenError = $true

    foreach ($Name in $Functions) {
        $FunctionDefinition = Get-Content "Function:\$Name" -ErrorAction Stop
        $State.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($Name, $FunctionDefinition))
    }

    foreach ($ScriptPath in $StartupScripts) {
        $null = $State.StartupScripts.Add($ScriptPath)
    }

    if ($script:ViewModelThread['Pool']) {
        $script:ViewModelThread['Pool'].Dispose()
    }

    $script:ViewModelThread['Pool'] = [RunspaceFactory]::CreateRunspacePool(1, $MaxRunspaces, $State, (Get-Host))
    $script:ViewModelThread['Pool'].CleanupInterval = [timespan]::FromMinutes(5)
    $script:ViewModelThread['Pool'].Open()
}

