; Shared initialization for the desktop entry and isolated test runners.
InitializeApplication() {
    global StartupSource := "", AppStartedAt := FormatTime(, "yyyy/MM/dd HH:mm:ss")
    try StartupSource := CaptureAppSource()
    global AppVersion := Trim(FileRead(A_ScriptDir "\VERSION", "UTF-8"))
    global ApplicationShortcutsInstalled := false, ShortcutKeys := DefaultShortcutKeys()
    RecordBrowserOperation({Mode:"なし", State:"未実行", Duration:0})
    global AppDataDirectory := A_ScriptDir "\data"
    global SettingsDatabasePath := AppDataDirectory "\settings.db"
    global SharedDanmakuItems := []
    global Profiles := [], InputProfileId := "", TargetBrowserHwnd := 0, PaletteWindow := 0, DanmakuEditorWindow := 0
    global AutoMode := 1, IsBrowserOperationBusy := false
    global PaletteRefresh := RefreshCycle(RunScheduledPaletteSearch), ManagementRefresh := RefreshCycle(RefreshManagement)
    global DetectedChannel := {State: "unavailable", Author: "", Channel: ""}
    global ActiveEditorDialog := false
    global ChannelIndex := Map()
    OnExit(CloseSettingsStore)
    if !InitializeAppSettings()
        ExitApp(1)
    InitReactions()
    global EditingProfileId := "", ManagementWindow := 0
    global LibraryHistory := [], DetectionMessage := "YouTubeから開くとチャンネルを確認します。"
    global PaletteRows := []
    InitializeReactionFeedback()
    BuildPalette()
    OnExit(StopBrowserWorker)
}
