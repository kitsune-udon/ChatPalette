; Shared initialization for the desktop entry and isolated test runners.
InitializeApplication(showRecoveryDialogs := true) {
    global StartupSource := "", AppStartedAt := FormatTime(, "yyyy/MM/dd HH:mm:ss")
    try StartupSource := CaptureAppSource()
    global AppVersion := Trim(FileRead(A_ScriptDir "\VERSION", "UTF-8"))
    global ApplicationShortcutsInstalled := false
    RecordBrowserOperation({Mode:"なし", State:"未実行", Duration:0})
    global AppDataDirectory := A_ScriptDir "\data"
    global SettingsDatabasePath := AppDataDirectory "\settings.db"
    global TargetBrowserHwnd := 0, PaletteWindow := 0
    global IsBrowserOperationBusy := false, ActivePageAction := 0
    global PaletteRefresh := RefreshCycle(RunScheduledPaletteSearch), ManagementRefresh := RefreshCycle(RefreshManagement)
    global DetectedChannel := {State: "unavailable", Author: "", Channel: ""}
    global ActiveEditorDialog := false
    OnExit(CloseSettingsStore)
    if !InitializeAppSettings(showRecoveryDialogs)
        ExitApp(1)
    InitReactions()
    global EditingProfileId := "", ManagementWindow := 0
    global LibraryHistory := [], DetectionMessage := "YouTubeから開くとチャンネルを確認します。"
    global PaletteRows := []
    global ReactionOverlay := 0
    BuildPalette()
    OnExit(StopBrowserWorker)
}
