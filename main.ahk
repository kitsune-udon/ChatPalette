#Requires AutoHotkey v2.0
#SingleInstance Force
#Include src\app\app_modules.ahk

; Syntax checks do not initialize storage or windows.
if A_Args.Length && A_Args[1] = "--check"
    ExitApp()
InitializeApplication()
InstallApplicationShortcuts()
A_TrayMenu.Add("ChatPaletteを開く", ShowPalette)
A_TrayMenu.Add("使い方", Help)
A_TrayMenu.Add("診断情報", ShowDiagnostics)
A_TrayMenu.Add("ショートカットを管理", (*) => ShowShortcutManager())
A_TrayMenu.Add("弾幕・設定をバックアップ", ExportSettingsBackup)
A_TrayMenu.Default := "ChatPaletteを開く"
UpdateTray()
if A_Args.Length && A_Args[1] = "--smoke"
    ExitApp()
if !(A_Args.Length && A_Args[1] = "--quiet")
    ShowPalette()
