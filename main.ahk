#Requires AutoHotkey v2.0
#SingleInstance Force
#Include settings_schema.ahk
#Include app_lifecycle.ahk
#Include reaction_controller.ahk
#Include palette_view.ahk
#Include management_view.ahk
#Include management_dialogs.ahk
#Include help_view.ahk
#Include reaction_feedback.ahk
#Include ui_runtime.ahk
#Include window_presenter.ahk
#Include diagnostics.ahk
#Include shortcut_controller.ahk
#Include shortcut_policy.ahk
#Include shortcut_bindings.ahk
#Include palette_controller.ahk
#Include browser_service.ahk
#Include panel_viewport.ahk
#Include danmaku_library.ahk
#Include settings_store.ahk
#Include worker_client.ahk
#Include text_input.ahk
#Include input_controller.ahk
#Include settings_service.ahk
#Include profile_service.ahk
#Include library_service.ahk
#Include management_controller.ahk

; 構文チェック時は常駐しない。
if A_Args.Length && A_Args[1] = "--check"
    ExitApp()

global AppVersion := Trim(FileRead(A_ScriptDir "\VERSION", "UTF-8"))
global LastBrowserOperation := {Mode:"なし", State:"未実行", Duration:0}
global AppDataDirectory := A_ScriptDir "\data"
global SettingsFilePath := AppDataDirectory "\settings.ini"
global SharedDanmakuItems := []
global Profiles := [], InputProfileIndex := 1, TargetBrowserHwnd := 0, PaletteWindow := 0, DanmakuEditorWindow := 0
global AutoMode := 1, IsBrowserOperationBusy := false
global DetectedChannel := {State: "unavailable", Author: "", Channel: ""}
global ActiveEditorDialog := false
global WorkerRequestActive := false
global WorkerProcessId := 0, WorkerPipeHandle := 0, WorkerSignalHandle := 0, WorkerRequestSequence := 0, ChannelIndex := Map()
if !InitializeAppSettings()
    ExitApp(1)
InitReactions()
global EditProfileIndex := 0, EditScopeShared := true, ManagementWindow := 0
global LibraryHistory := [], DetectionMessage := "YouTubeから開くとチャンネルを確認します。"
global PaletteRows := []
InitializeReactionFeedback()
BuildPalette()
OnExit(StopBrowserWorker)
A_TrayMenu.Add("ChatPaletteを開く", ShowPalette)
A_TrayMenu.Add("使い方", Help)
A_TrayMenu.Add("診断情報", ShowDiagnostics)
A_TrayMenu.Default := "ChatPaletteを開く"
UpdateTray()
if A_Args.Length && A_Args[1] = "--smoke"
    ExitApp()
if !(A_Args.Length && A_Args[1] = "--quiet")
    ShowPalette()

#HotIf IsBrowser(WinExist("A"))
^!1::HandleProfileDanmakuShortcut(1)
^!2::HandleProfileDanmakuShortcut(2)
^!3::HandleSharedDanmakuShortcut(1)
^!4::HandleSharedDanmakuShortcut(2)
#HotIf
^!q::ShowPalette()
