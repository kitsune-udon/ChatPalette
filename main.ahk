#Requires AutoHotkey v2.0
#SingleInstance Force
#Include src\app\app_modules.ahk

; Interpret arguments only at the desktop entry, before storage or window creation.
startupMode := A_Args.Length ? A_Args[1] : ""
if A_Args.Length > 1 || (A_Args.Length && startupMode != "--check" && startupMode != "--smoke" && startupMode != "--quiet") {
    FileAppend("起動引数が不正です。引数なし、--check、--smoke、--quiet のいずれかで起動してください。`n", "**")
    ExitApp(1)
}
if startupMode = "--check"
    ExitApp()
InitializeApplication(startupMode != "--smoke")
InstallApplicationShortcuts()
; Keep only app actions; standard reload/pause/suspend bypass application ownership.
A_TrayMenu.Delete()
A_TrayMenu.Add("ChatPaletteを開く", ShowPalette)
A_TrayMenu.Add("使い方", Help)
A_TrayMenu.Add("診断情報", ShowDiagnostics)
A_TrayMenu.Add("ショートカットを管理", (*) => ShowShortcutManager())
A_TrayMenu.Add("弾幕・設定をバックアップ", ExportSettingsBackup)
A_TrayMenu.Add()
A_TrayMenu.Add("アプリを再起動", RestartApplication)
A_TrayMenu.Add("終了", (*) => ExitApp())
A_TrayMenu.Default := "ChatPaletteを開く"
UpdateTray()
if startupMode = "--smoke"
    ExitApp()
if startupMode != "--quiet"
    ShowPalette()
