#Requires AutoHotkey v2.0
#SingleInstance Force
#Include src\app\app_modules.ahk

; Interpret arguments only at the desktop entry, before storage or window creation.
startupMode := A_Args.Length ? A_Args[1] : ""
if A_Args.Length > 1 || (A_Args.Length && startupMode != "--check" && startupMode != "--smoke" && startupMode != "--quiet") {
    FileAppend("起動引数が不正です。引数なし、--check、--smoke、--quiet のいずれかで起動してください。`n", "**", "UTF-8-RAW")
    ExitApp(1)
}
if startupMode = "--check"
    ExitApp()
InitializeApplication(startupMode != "--smoke")
InstallApplicationShortcuts()
; Keep only app actions; standard reload/pause/suspend bypass application ownership.
A_TrayMenu.Delete()
A_TrayMenu.Add("ChatPaletteを開く", ShowPalette)
A_TrayMenu.Add()
AddApplicationMenuItems(A_TrayMenu)
A_TrayMenu.Default := "ChatPaletteを開く"
UpdateTray()
if startupMode = "--smoke"
    ExitApp()
if startupMode != "--quiet"
    ShowPalette()
