Option Explicit

Dim shell, fileSystem, root, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

root = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(root, "app\AndroidScreenShare.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File """ & scriptPath & """"

shell.Run command, 0, False
