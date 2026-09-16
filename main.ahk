#Requires AutoHotkey v2.0
#SingleInstance Force
#Include settings_schema.ahk
#Include app_lifecycle.ahk
#Include reaction_controller.ahk
#Include app_ui.ahk
#Include danmaku_library.ahk
#Include settings_store.ahk
#Include worker_client.ahk
#Include chat_input.ahk
#Include reaction_drafts.ahk
#Include settings_service.ahk
#Include profile_service.ahk

; 構文チェック時は常駐しない。
if A_Args.Length && A_Args[1] = "--check"
    ExitApp()

global AppVersion := Trim(FileRead(A_ScriptDir "\VERSION", "UTF-8"))
global LastBrowserOperation := {Mode:"なし", State:"未実行", Duration:0}
global AppDataDirectory := A_ScriptDir "\data"
global SettingsFilePath := AppDataDirectory "\settings.ini"
global SharedDanmakuItems := [], IsSharedLibrarySelected := false
global Profiles := [], SelectedProfileIndex := 1, TargetBrowserHwnd := 0, MainWindow := 0, DanmakuEditorWindow := 0
global LibraryProfilePicker := 0, DanmakuListView := 0, DanmakuPreview := 0, PanelStatusText := 0
global AutoMode := 1, AutoCheck := 0, DetectionLabel := 0, IsBrowserOperationBusy := false
global DetectedChannel := {State: "unavailable", Author: "", Channel: ""}, LibraryUndoSnapshot := 0
global UndoButton := 0
global ProfileManagerActive := false
global WorkerRequestActive := false
global WorkerProcessId := 0, WorkerPipeHandle := 0, WorkerSignalHandle := 0, WorkerRequestSequence := 0, ChannelIndex := Map()
if !InitializeAppSettings()
    ExitApp(1)
InitReactions()
BeginReactionEditing()
BuildPanel()
OnExit(StopBrowserWorker)
A_TrayMenu.Add("ChatPaletteを開く", ShowPanel)
A_TrayMenu.Add("使い方", Help)
A_TrayMenu.Add("診断情報", ShowDiagnostics)
A_TrayMenu.Default := "ChatPaletteを開く"
UpdateTray()
if A_Args.Length && A_Args[1] = "--smoke"
    ExitApp()
if !(A_Args.Length && A_Args[1] = "--quiet")
    ShowPanel()

#HotIf IsBrowser(WinExist("A"))
^!1::HandleProfileDanmakuShortcut(1)
^!2::HandleProfileDanmakuShortcut(2)
^!3::HandleSharedDanmakuShortcut(1)
^!4::HandleSharedDanmakuShortcut(2)
#HotIf
^!q::ShowPanel()


ChangeProfile(control, *) {
    SelectCurrentProfile(control.Value)
}

SelectCurrentProfile(index) {
    if index < 1 || index > Profiles.Length
        return false
    global SelectedProfileIndex
    if !CanChangeProfile() {
        LibraryProfilePicker.Choose(SelectedProfileIndex)
        ProfilePicker.Choose(SelectedProfileIndex)
        NavigatePanel(3)
        ProfileSettingsInfo.Text := "投稿者設定を保存するか、変更を戻してから投稿者を切り替えてください。"
        return false
    }
    try SaveSelectedProfile(index)
    catch as failure {
        LibraryProfilePicker.Choose(SelectedProfileIndex)
        ProfilePicker.Choose(SelectedProfileIndex)
        PanelStatusText.Text := "保存できませんでした。" failure.Message
        return false
    }
    LibraryProfilePicker.Choose(SelectedProfileIndex)
    ProfilePicker.Choose(SelectedProfileIndex)
    RefreshRows()
    RefreshReactionUI()
    PanelStatusText.Text := "選択中：" Profiles[SelectedProfileIndex].Name
    return true
}

ShowPanel(*) {
    global TargetBrowserHwnd
    if ProfileManagerActive {
        ProfileManager.Show()
        return
    }
    if ActiveReactionJob {
        ShowReactionProgress()
        return
    }
    if IsBrowserOperationBusy
        return
    if DanmakuEditorWindow && WinExist("ahk_id " DanmakuEditorWindow.Hwnd) {
        DanmakuEditorWindow.Show()
        return
    }
    active := WinExist("A")
    if active != MainWindow.Hwnd
        TargetBrowserHwnd := IsBrowser(active) ? active : 0
    PanelStatusText.Text := TargetBrowserHwnd ? "入力先：" WinGetTitle("ahk_id " TargetBrowserHwnd) : "YouTubeのチャット欄またはコメント欄をクリックし、Ctrl＋Alt＋Qで開き直してください。"
    MainWindow.Show()
    if FeatureTabs.Value = 2
        DanmakuListView.Focus()
    if ReactionOverlay
        ReactionOverlay.Hide()
    if AutoMode && TargetBrowserHwnd && CanChangeProfile()
        SelectProfileFromBrowser(TargetBrowserHwnd)
}

ShowProfileManager(*) {
    global ProfileManager, ProfileManagerActive
    if IsBrowserOperationBusy || ActiveReactionJob || DanmakuEditorWindow {
        ToolTip("処理中または編集中です。完了後にもう一度押してください。")
        SetTimer(() => ToolTip(), -3000)
        return
    }
    if !CanChangeProfile() {
        NavigatePanel(3)
        ProfileSettingsInfo.Text := "この投稿者の設定を保存するか、変更を戻してください。"
        return
    }
    if IsSet(ProfileManager) && IsObject(ProfileManager)
        ProfileManager.Destroy()
    ProfileManager := BuildProfileManager()
    ProfileManagerActive := true
    MainWindow.Opt("+Disabled")
    ProfileManager.Show()
}

HidePanel(*) {
    MainWindow.Hide()
}

IsBrowser(hwnd) {
    if !hwnd || !WinExist("ahk_id " hwnd)
        return false
    name := StrLower(WinGetProcessName("ahk_id " hwnd))
    return name = "chrome.exe" || name = "msedge.exe" || name = "firefox.exe" || name = "brave.exe" || name = "opera.exe" || name = "vivaldi.exe"
}

HandleProfileDanmakuShortcut(n) {
    if IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob || ProfileManagerActive
        return
    hwnd := WinExist("A")
    if !IsBrowser(hwnd) {
        ToolTip("YouTubeのチャット入力欄をクリックしてください。")
        SetTimer(() => ToolTip(), -2200)
        return
    }
    if !WaitShortcutRelease([String(n), "Control", "Alt"])
        return
    InsertProfileDanmaku(n, hwnd)
}

InsertSelectedDanmaku(*) {
    n := DanmakuListView.GetNext()
    if !n
        return
    if IsSharedLibrarySelected
        InsertSharedDanmaku(n, TargetBrowserHwnd, true)
    else
        InsertProfileDanmaku(n, TargetBrowserHwnd, true)
}
DuplicateSelectedDanmaku(*) {
    n := DanmakuListView.GetNext()
    if !n
        return
    items := GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile())
    updated := CopyItems(items)
    DuplicateDanmakuItem(updated, n)
    if !CommitLibraryView([items], [updated])
        return
    ClearLibraryUndo()
    RefreshRows(n + 1)
}

MoveSelectedDanmaku(direction) {
    n := DanmakuListView.GetNext()
    other := n + direction
    items := GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile())
    updated := CopyItems(items)
    if !ReorderDanmakuItem(updated, n, other)
        return
    if !CommitLibraryView([items], [updated])
        return
    ClearLibraryUndo()
    RefreshRows(other)
}

RecordLibraryUndo(targets, scope) {
    global LibraryUndoSnapshot
    LibraryUndoSnapshot := CreateLibraryUndoSnapshot(targets, scope)
}

ClearLibraryUndo() {
    global LibraryUndoSnapshot := 0
}

DeleteSelectedDanmaku(*) {
    if IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob
        return
    n := DanmakuListView.GetNext()
    if !n
        return
    items := GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile())
    snapshot := CreateLibraryUndoSnapshot([items], IsSharedLibrarySelected)
    label := items[n].Name
    updated := CopyItems(items)
    updated.RemoveAt(n)
    if !CommitLibraryView([items], [updated])
        return
    global LibraryUndoSnapshot := snapshot
    RefreshRows(n)
    PanelStatusText.Text := "「" label "」を削除しました。元に戻せます。"
}

UndoLibraryChange(*) {
    global LibraryUndoSnapshot, IsSharedLibrarySelected
    if !LibraryUndoSnapshot || IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob
        return
    ; Undo only text-library mutations. Keep selection and reaction drafts intact.
    try SaveLibraryUndo(LibraryUndoSnapshot)
    catch as failure {
        PanelStatusText.Text := "取り消しを保存できませんでした。" failure.Message
        return
    }
    IsSharedLibrarySelected := LibraryUndoSnapshot.Scope
    LibraryScope.Choose(IsSharedLibrarySelected ? 2 : 1)
    UpdateLibraryScope()
    ClearLibraryUndo()
    RefreshProfiles()
    PanelStatusText.Text := "弾幕の削除・移動を元に戻しました。"
}

ToggleAuto(*) {
    global AutoMode
    state := CreateSettingsSnapshot()
    state.AutoMode := AutoCheck.Value
    try WriteSettingsFile(state, SettingsFilePath)
    catch as failure {
        AutoCheck.Value := AutoMode
        PanelStatusText.Text := "保存できませんでした。" failure.Message
        return
    }
    AutoMode := state.AutoMode
    RefreshHome()
    SetDetectionStatus(AutoMode ? "自動判別ON：動画から投稿者を選びます。" : "手動選択：選択した投稿者を使います。")
    if AutoMode && TargetBrowserHwnd
        SelectProfileFromBrowser(TargetBrowserHwnd)
}

; Application policy, separate from worker transport and view rendering.
RequestBrowserOperation(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    global IsBrowserOperationBusy, LastBrowserOperation
    if IsBrowserOperationBusy || !IsBrowser(hwnd)
        return {State: mode = "reaction_send" ? "unknown" : "unavailable", Author: "", Channel: "", Video: ""}
    IsBrowserOperationBusy := true
    try {
        waitView := BeginWorkerWait(mode)
        started := A_TickCount
        reply := SendWorkerRequest(hwnd, mode, expectedVideo, extra)
        LastBrowserOperation := {Mode:mode, State:reply.State, Duration:A_TickCount-started}
        return reply
    } finally {
        IsBrowserOperationBusy := false
        if IsSet(waitView)
            EndWorkerWait(waitView)
    }
}

ResolveBrowserChannel(hwnd) {
    return RequestBrowserOperation(hwnd)
}

VerifyInputTarget(hwnd, expectedVideo) {
    if !WinActive("ahk_id " hwnd)
        return false
    result := RequestBrowserOperation(hwnd, "verify_input", expectedVideo)
    if result.State = "ok" && (expectedVideo = "" || result.Video == expectedVideo) && WinActive("ahk_id " hwnd)
        return true
    return false
}

RebuildChannelIndex() {
    global ChannelIndex
    ChannelIndex := Map()
    ChannelIndex.CaseSense := "On"
    for i, p in Profiles {
        if p.Channel != ""
            ChannelIndex[p.Channel] := ChannelIndex.Has(p.Channel) ? -1 : i
    }
}

SelectProfileFromBrowser(hwnd) {
    global SelectedProfileIndex, DetectedChannel
    DetectedChannel := ResolveBrowserChannel(hwnd)
    if DetectedChannel.State != "ok" {
        SetDetectionStatus("判別できませんでした。通常のYouTube動画ページで再試行するか、自動判別をOFFにしてください。")
        return false
    }
    found := ChannelIndex.Get(DetectedChannel.Channel, 0)
    if found = -1 {
        SetDetectionStatus("同じチャンネルに複数の投稿者が関連付けられています。関連付けを解除してください。")
        return false
    }
    if !found {
        SetDetectionStatus("検出：" DetectedChannel.Author "`n未関連付けです。「投稿者・チャンネル管理」→「関連付ける」。")
        return false
    }
    if SelectedProfileIndex != found {
        if !CanChangeProfile() {
            SetDetectionStatus("リアクション設定が未保存のため投稿者を切り替えられません。保存するか変更を戻してください。")
            return false
        }
        try SaveSelectedProfile(found)
        catch as failure {
            SetDetectionStatus("投稿者の選択を保存できませんでした。" failure.Message)
            return false
        }
        RefreshProfiles()
    }
    SetDetectionStatus("自動判別：" DetectedChannel.Author " → " Profiles[SelectedProfileIndex].Name)
    return true
}


TransferSelectedDanmaku(*) {
    if !GetSelectedProfile()
        return
    if IsBrowserOperationBusy || DanmakuEditorWindow || ActiveReactionJob || !DanmakuListView.GetNext()
        return
    items := GetDanmakuItems(IsSharedLibrarySelected, GetSelectedProfile())
    n := DanmakuListView.GetNext(), item := items[n]
    destination := IsSharedLibrarySelected ? Profiles[SelectedProfileIndex].Items : SharedDanmakuItems
    snapshot := CreateLibraryUndoSnapshot([items, destination], IsSharedLibrarySelected)
    updated := CopyItems(items), moved := CopyItems(destination)
    moved.Push({Name: item.Name, Text: item.Text})
    updated.RemoveAt(n)
    if !CommitLibraryView([items, destination], [updated, moved])
        return
    global LibraryUndoSnapshot := snapshot
    RefreshRows(n)
    PanelStatusText.Text := "「" item.Name "」を" (IsSharedLibrarySelected ? Profiles[SelectedProfileIndex].Name : "共通") "へ移しました。元に戻せます。"
}

CommitLibraryView(targets, replacements) {
    try SaveLibraryTargets(targets, replacements)
    catch as failure {
        PanelStatusText.Text := "弾幕を保存できませんでした。" failure.Message
        return false
    }
    return true
}
