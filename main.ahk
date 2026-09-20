#Requires AutoHotkey v2.0
#SingleInstance Force
#Include src\settings\settings_schema.ahk
#Include src\app\app_lifecycle.ahk
#Include src\app\record_identity.ahk
#Include src\reactions\reaction_controller.ahk
#Include src\ui\palette\palette_view.ahk
#Include src\ui\management\management_view.ahk
#Include src\ui\management\management_dialogs.ahk
#Include src\ui\help_view.ahk
#Include src\ui\reaction_feedback.ahk
#Include src\ui\ui_runtime.ahk
#Include src\ui\window_presenter.ahk
#Include src\ui\diagnostics.ahk
#Include src\shortcuts\shortcut_controller.ahk
#Include src\shortcuts\shortcut_policy.ahk
#Include src\shortcuts\shortcut_bindings.ahk
#Include src\ui\palette\palette_controller.ahk
#Include src\browser\browser_service.ahk
#Include src\browser\reaction_registration_service.ahk
#Include src\ui\panel_viewport.ahk
#Include src\library\danmaku_library.ahk
#Include src\storage\sqlite_connection.ahk
#Include src\settings\settings_validation.ahk
#Include src\settings\legacy_settings_import.ahk
#Include src\settings\library_storage_plan.ahk
#Include src\settings\library_storage_delta.ahk
#Include src\settings\reaction_registration_repository.ahk
#Include src\settings\settings_repository.ahk
#Include src\settings\settings_store.ahk
#Include src\browser\worker_client.ahk
#Include src\input\text_input.ahk
#Include src\input\input_controller.ahk
#Include src\settings\settings_service.ahk
#Include src\library\profile_service.ahk
#Include src\library\library_service.ahk
#Include src\ui\management\management_controller.ahk

; 構文チェック時は常駐しない。
if A_Args.Length && A_Args[1] = "--check"
    ExitApp()

global AppVersion := Trim(FileRead(A_ScriptDir "\VERSION", "UTF-8"))
global LastBrowserOperation := {Mode:"なし", State:"未実行", Duration:0}
global AppDataDirectory := A_ScriptDir "\data"
global SettingsDatabasePath := AppDataDirectory "\settings.db"
global SharedDanmakuItems := []
global Profiles := [], InputProfileIndex := 1, TargetBrowserHwnd := 0, PaletteWindow := 0, DanmakuEditorWindow := 0
global AutoMode := 1, IsBrowserOperationBusy := false
global PaletteUpdating := false, ManagementUpdating := false, ManagementRefreshPending := false
global DetectedChannel := {State: "unavailable", Author: "", Channel: ""}
global ActiveEditorDialog := false
global WorkerRequestActive := false
global WorkerProcessId := 0, WorkerPipeHandle := 0, WorkerSignalHandle := 0, WorkerRequestSequence := 0, ChannelIndex := Map()
OnExit(CloseSettingsStore)
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
A_TrayMenu.Add("弾幕・設定をバックアップ", ExportSettingsBackup)
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
