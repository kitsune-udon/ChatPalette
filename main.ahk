#Requires AutoHotkey v2.0
#SingleInstance Force
#Include src\app\app_modules.ahk

if FileExist(A_ScriptDir "\build.zig") {
    notice := "Zig版は ChatPalette.exe から起動してください。旧版を検証する場合は、隔離した v0.8.0 の作業コピーを使ってください。"
    if A_Args.Length
        FileAppend(notice "`n", "**", "UTF-8-RAW")
    else
        MsgBox(notice, "ChatPalette")
    ExitApp(1)
}

; Interpret arguments only at the desktop entry, before storage or window creation.
startupMode := A_Args.Length ? A_Args[1] : ""
if A_Args.Length > 1 || (A_Args.Length && startupMode != "--smoke" && startupMode != "--quiet") {
    FileAppend("起動引数が不正です。引数なし、--smoke、--quiet のいずれかで起動してください。`n", "**", "UTF-8-RAW")
    ExitApp(1)
}
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
