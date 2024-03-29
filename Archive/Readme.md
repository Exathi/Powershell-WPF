# Powershell 5.1 and WPF
An attempt at learning WPF with PowerShell, along with VSCode, Git and, Github.

Challenge:
1. To write a GUI in pure PowerShell and .Net Framework.
2. No custom C# classes through ```Add-Type```.
3. Limited to resources that come natively with Windows 10.

# Result
An **asynchronous** PowerShell UI! Supported by view models, multiple views and relay commands.

`OpenGUI.ps1` Right click and run with powershell, dot source, or load up vscode and run the debugger.

Enter a number, in seconds, that the background command will run for in the textbox. Then click the background command button. You are still able to move, resize the window, click other buttons, and navigate to another tab. No frozen UI!

You mentioned view model, that means I can spin up the class without the UI? Why of course! See `FirstViewModel.Tests.ps1`.

![test](./Images/PesterResult.PNG?raw=true)

# Notes

Anything that interacts with the UI must be invoked with the UI dispatcher. Prefer Dispatcher.BeginInvoke over Dispatcher.Invoke for multiple views and callbacks running at the same time.

Don't use cmdlets in PSMethods converted to Delegates. It will crash the ui if there is a task in the background thread.

Dependency Properties are awesome with built in callbacks. A bit verbose, but this is powershell so everything is verbose. Also a cheat to include property get and property set in powershell classes. The down side is the syntax to use them.

INotifyPropertyChanged feels awkward since binding variables cannot raise property changed or set other properties due to the lack of setters. It is probably easier to learn c# and add the c# class through add-type.

Xaml allows mapping a custom namespace with a dynamic assembly. You are be able to use custom powershell classes in the xaml.

It's okay to take the easier route. The code behind doesn't need to be devoid of any code whatsoever. The UI was created using something that wasn't meant to create a UI.

# Helpful References

RelayCommand

https://github.com/nohwnd/WpfToolkit

Incomplete example

https://gist.github.com/mouadcherkaoui/7b0f32d9dbefa71102acdbb07299c9bb

Snake

https://gist.github.com/nikonthethird/2ab6bfad9a81d5fe127fd0d1c2844b7c

Minesweeper

https://gist.github.com/nikonthethird/4e410ac3c04ea6633043a5cb7be1d717
