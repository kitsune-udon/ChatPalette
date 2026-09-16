$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

foreach ($module in @('settings_schema.ahk','settings_store.ahk','worker_client.ahk','danmaku_library.ahk','reaction_drafts.ahk','profile_service.ahk','settings_service.ahk')) {
    $moduleText = [IO.File]::ReadAllText((Join-Path $release $module))
    $moduleText = [regex]::Replace($moduleText, '(?m)^\s*;.*$', '')
    if ($moduleText -match '\b(MainWindow|DanmakuListView|LibraryProfilePicker|ToolTip|MsgBox|Gui|ReactionChoice|ReactionScope)\b') {
        throw "Boundary regression: $module depends on GUI"
    }
}
$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$reactionSource = [IO.File]::ReadAllText("$fixture\reaction_controller.ahk").Replace('SetReactionHotkey(key, enabled := true) {', 'RegisterFixtureHotkey(key, enabled := true) {')
[IO.File]::WriteAllText("$fixture\reaction_controller.ahk", $reactionSource, [Text.UTF8Encoding]::new($true))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\settings.ini') -Destination "$fixture\settings.ini" -Force
$worker = [IO.File]::ReadAllText("$release\browser_worker.ps1")
$mock = @'
function Read-BrowserVideoId([long]$WindowHandle) { return 'abcdefghijk' }
function Get-BrowserProcessName([long]$WindowHandle) { return 'fixture' }
function Test-ReactionForeground([long]$WindowHandle) { return $true }
$script:BrowserReactionSelectors['fixture'] = @{}
$script:fakeTarget = [pscustomobject]@{ Current=[pscustomobject]@{IsOffscreen=$false; IsEnabled=$true} }
$script:fakeInvoke = [pscustomobject]@{}
$script:fakeInvoke | Add-Member ScriptMethod Invoke { }
function Get-ReactionInvoker($Target) { return $script:fakeInvoke }
function Find-RegisteredReactions([long]$WindowHandle, $Saved) { return @{ Elements=@($script:fakeTarget,$script:fakeTarget,$script:fakeTarget,$script:fakeTarget,$script:fakeTarget) } }
'@
$worker = $worker.Replace('if ($Library) { return }', $mock + "`n" + 'if ($Library) { return }')
[IO.File]::WriteAllText("$fixture\browser_worker.ps1", $worker, [Text.UTF8Encoding]::new($true))
$source = [IO.File]::ReadAllText("$release\main.ahk").Replace("`r`n", "`n")
if ($source -notmatch '(?s)#HotIf IsBrowser\(WinExist\("A"\)\)\s+\^!1::HandleProfileDanmakuShortcut\(1\)\s+\^!2::HandleProfileDanmakuShortcut\(2\)\s+\^!3::HandleSharedDanmakuShortcut\(1\)\s+\^!4::HandleSharedDanmakuShortcut\(2\)\s+#HotIf\s+\^!q::ShowPanel\(\)') {
    throw 'Shortcut scope regression: text keys must be browser-only and panel key global'
}
$start = $source.IndexOf('IsBrowser(hwnd) {')
$end = $source.IndexOf('HandleProfileDanmakuShortcut(n) {', $start)
$source = $source.Substring(0,$start) + "IsBrowser(hwnd) {`nreturn hwnd = 123`n}`n`n" + $source.Substring($end)
$tests = @'
OnExit(StopBrowserWorker)
global Checks := 0
try {
    manager := BuildProfileManager()
    managerButtons := 0
    for control in manager
        if control.Type = "Button"
            managerButtons++
    Assert(managerButtons = 9, "profile manager has management and recovery actions")
    Assert(DllCall("GetWindow", "Ptr", manager.Hwnd, "UInt", 4, "Ptr") = MainWindow.Hwnd, "profile manager owned by main panel")
    originalChannel := Profiles[SelectedProfileIndex].Channel
    if originalChannel != "" {
        manager.Show("NoActivate")
        for control in manager {
            if control.Type = "Button" && control.Text = "関連付けを解除"
                DllCall("SendMessage", "Ptr", control.Hwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0)
        }
        Sleep(100)
        Assert(Profiles[SelectedProfileIndex].Channel = "", "manager unlink applies without closing")
        for control in manager {
            if control.Type = "Button" && control.Text = "直前の変更を戻す"
                DllCall("SendMessage", "Ptr", control.Hwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0)
        }
        Sleep(100)
        Assert(Profiles[SelectedProfileIndex].Channel = originalChannel, "manager undo restores association")
    }
    manager.Destroy()
    global HelpOwnerMatches := false
    SetTimer(CheckHelpOwner, 100)
    Help()
    Assert(HelpOwnerMatches, "help dialog owned by main panel")
    Assert(Profiles.Length > 0 && Profiles[1].Reaction = 0, "existing settings migration")
    oldText := Profiles[1].Items[1].Text
    oldChannel := Profiles[1].Channel
    Assert(HomeDanmaku.Value > 0 && HomeInput.Enabled, "home offers existing danmaku")
    Assert(HomeDanmaku.Text = Profiles[SelectedProfileIndex].Items[HomeDanmaku.Value].Name, "home selection reflects active profile")
    FeatureTabs.GetPos(&layoutX, &layoutY, &layoutW, &layoutH)
    for control in MainWindow {
        control.GetPos(&cx, &cy, &cw, &ch)
        if cy >= UiY && cy < layoutY + layoutH
            Assert(cx >= layoutX && cx + cw <= layoutX + layoutW && cy + ch <= layoutY + layoutH, "content control fits redesigned panel")
    }
    SetDetectionStatus("判別状態の同期確認")
    Assert(DetectionLabel.Text = ProfileDetectionLabel.Text, "detection status synchronized across profile tabs")
    originalProfile := SelectedProfileIndex
    ProfilePicker.Choose(1)
    ChangeProfile(ProfilePicker)
    Assert(SelectedProfileIndex = 1 && LibraryProfilePicker.Value = 1, "profile settings selection syncs danmaku tab")
    LibraryProfilePicker.Choose(originalProfile)
    ChangeProfile(LibraryProfilePicker)
    Assert(ProfilePicker.Value = originalProfile, "danmaku selection syncs profile settings")
    FeatureTabs.Choose(2)
    RefreshReactionUI()
    Assert(ReactionChoice.Value = ReactionDefault && !ReactionScope.Value, "default choice")
    ReactionScope.Value := 1
    ReactionChoice.Choose(5)
    CaptureProfileReactionEdits()
    SaveProfileReactionEdits()
    Assert(Profiles[SelectedProfileIndex].Reaction = 5, "per-profile setting")
    Assert(Profiles[1].Items[1].Text = oldText && Profiles[1].Channel = oldChannel, "existing data preserved")
    Profiles := []
    ReloadAppSettings()
    RefreshProfiles()
    Assert(Profiles[SelectedProfileIndex].Reaction = 5 && ReactionChoice.Value = 5, "preference reload")
    ReactionScope.Value := 0
    CaptureProfileReactionEdits()
    SaveProfileReactionEdits()
    ReactionDefaultChoice.Choose(3)
    priorExecutionText := ReactionInfo.Text
    CaptureSharedReactionEdits()
    SaveSharedReactionEdits()
    Assert(ReactionInfo.Text = priorExecutionText, "saving common settings preserves execution result")
    Assert(ReactionDefault = 3 && Profiles[SelectedProfileIndex].Reaction = 0, "common preference")
    ReactionScope.Value := 1
    ReactionChoice.Choose(5)
    CaptureProfileReactionEdits()
    ReactionDefaultChoice.Choose(2)
    CaptureSharedReactionEdits()
    CaptureSharedReactionEdits()
    SaveSharedReactionEdits()
    Assert(ReactionDefault = 2 && Profiles[SelectedProfileIndex].Reaction = 0 && HasUnsavedProfileReaction, "common save leaves profile draft uncommitted")
    CaptureProfileReactionEdits()
    SaveProfileReactionEdits()
    Assert(Profiles[SelectedProfileIndex].Reaction = 5 && ReactionDefault = 2 && !HasUnsavedReactionSettings, "profile save does not change common default")
    ReactionCountChoice.Choose(2)
    CaptureSharedReactionEdits()
    ReactionChoice.Choose(4)
    CaptureProfileReactionEdits()
    DiscardProfileReactionEdits()
    Assert(ReactionChoice.Value = 5 && HasUnsavedSharedReaction && ReactionCountChoice.Value = 2, "profile discard preserves common draft")
    DiscardSharedReactionEdits()
    ReactionScope.Value := 0
    CaptureProfileReactionEdits()
    SaveProfileReactionEdits()
    validShortcut := ReactionShortcut
    for reserved in ["^!1", "!^2", "^!q"] {
        ReactionKeyControl.Value := reserved
        CaptureSharedReactionEdits()
    SaveSharedReactionEdits()
        Assert(ReactionShortcut = validShortcut, "reserved shortcut cannot override panel or danmaku")
    }
    ReactionKeyControl.Value := "r"
    CaptureSharedReactionEdits()
    SaveSharedReactionEdits()
    Assert(ReactionShortcut = validShortcut, "unmodified hotkey rejected")
    ReactionKeyControl.Value := "^!r"
    IsBrowserOperationBusy := true
    Assert(ShortcutBlocked(), "busy shortcut reports blocked")
    IsBrowserOperationBusy := false
    ActiveReactionJob := {Cancelled: false}
    Assert(ShortcutBlocked(), "pending shortcut reports blocked")
    ActiveReactionJob := 0
    Assert(!ShortcutBlocked(), "shortcut recovers after completion")
    for i, count in ReactionCounts {
        ReactionCountChoice.Choose(i)
        CaptureSharedReactionEdits()
    SaveSharedReactionEdits()
        Assert(Integer(IniRead(SettingsFilePath, "General", "ReactionCount")) = count, "count saved " count)
        job := {Total: count, Completed: count - 1, Cancelled: false, Interval: 100}
        ActiveReactionJob := job
        ApplyReactionResult(job, {State: "operated"})
        Assert(job.Completed = count && !ActiveReactionJob, "exact completion " count)
    }
    for i, interval in ReactionIntervals {
        ReactionIntervalChoice.Choose(i)
        CaptureSharedReactionEdits()
    SaveSharedReactionEdits()
        Assert(Integer(IniRead(SettingsFilePath, "General", "ReactionInterval")) = interval, "interval saved " interval)
    }
    job := {Total: 10, Completed: 0, Cancelled: false, Interval: 1000}
    ActiveReactionJob := job
    ApplyReactionResult(job, {State: "operated"})
    SetTimer(ReactionSendNext, 0)
    Assert(job.Completed = 1 && ActiveReactionJob = job, "continue after first operation")
    IsBrowserOperationBusy := true
    CancelReaction()
    IsBrowserOperationBusy := false
    ApplyReactionResult(job, {State: "operated"})
    Assert(job.Completed = 2 && !ActiveReactionJob, "cancel during pending response")
    for state in ["unknown", "changed", "menu_closed", "cooldown"] {
        job := {Total: 10000, Completed: 3, Cancelled: false, Interval: 100}
        ActiveReactionJob := job
        ApplyReactionResult(job, {State: state})
        Assert(job.Completed = 3 && !ActiveReactionJob, "stop without retry " state)
    }
    FeatureTabs.GetPos(&tabX, &tabY, &tabWidth, &tabHeight)
    ReactionInfo.GetPos(&infoX, &infoY, &infoWidth, &infoHeight)
    Assert(infoX >= tabX && infoX + infoWidth <= tabX + tabWidth, "reaction text within tab width")
    Assert(infoY + infoHeight < tabY + tabHeight, "reaction status within tab height")
    DanmakuListView.GetPos(&rowX, &rowY, &rowWidth, &rowHeight)
    Assert(rowX >= tabX && rowX + rowWidth <= tabX + tabWidth, "danmaku list within tab")
    FeatureTabs.Choose(2)
    foundEditButtons := 0
    for control in MainWindow {
        if control.Type = "Button" && (control.Text = "追加" || control.Text = "編集") {
            control.GetPos(&buttonX, &buttonY, &buttonWidth, &buttonHeight)
            Assert(buttonY > rowY + rowHeight && buttonY + buttonHeight < tabY + tabHeight, "edit button within tab " control.Text)
            Assert(buttonX >= tabX && buttonX + buttonWidth <= tabX + tabWidth, "edit button horizontal bounds")
            foundEditButtons++
        }
    }
    Assert(foundEditButtons = 2, "add and edit buttons present")
    FeatureTabs.Choose(4)
    CaptureSharedReactionEdits()
    Assert(ReactionSaveButton.Enabled && ReactionResetButton.Enabled, "changed settings enable save and discard")
    beforeRequest := WorkerRequestSequence
    ScheduleReaction("reaction_send", 3)
    Assert(!ActiveReactionJob && WorkerRequestSequence = beforeRequest, "unsaved button request blocked before worker")
    QueueQuickReaction()
    Assert(!ActiveReactionJob && WorkerRequestSequence = beforeRequest, "unsaved shortcut blocked before worker")
    DiscardSharedReactionEdits()
    Assert(!ReactionSaveButton.Enabled && !ReactionResetButton.Enabled, "unchanged settings disable redundant actions")
    Assert(!HasUnsavedReactionSettings && ReactionCount = ReactionCounts[ReactionCountChoice.Value], "discard restores effective settings")
    previousAuto := AutoMode
    AutoMode := 0
    Profiles[SelectedProfileIndex].Reaction := 5
    Assert(ResolveReactionChoice(123, "abcdefghijk") = 5, "shared saved profile choice")
    Assert(InStr(ReactionApplied, Profiles[SelectedProfileIndex].Name) && InStr(ReactionApplied, ReactionNames[5]), "actual applied profile and reaction shown")
    Profiles[SelectedProfileIndex].Reaction := 0
    Assert(ResolveReactionChoice(123, "abcdefghijk") = ReactionDefault, "shared common choice")
    AutoMode := previousAuto
    job := {Mode: "reaction_send", Completed: 12, Total: 100, Cancelled: false}
    ActiveReactionJob := job
    ShowPanel()
    Assert(ActiveReactionJob = job && !job.Cancelled, "opening progress does not stop batch")
    CancelReaction()
    Assert(InStr(ReactionLastResult, "12 / 100"), "cancel progress retained")
    waiting := {Mode: "reaction_capture", Cancelled: false}
    Assert(ShouldWaitForRegistration(waiting, {State: "unsupported"}), "registration waits for visible menu")
    Assert(!ShouldWaitForRegistration(waiting, {State: "registered"}), "registration stops after success")
    Assert(!ShouldWaitForRegistration(waiting, {State: "changed"}), "registration stops on video change")
    waiting.Cancelled := true
    Assert(!ShouldWaitForRegistration(waiting, {State: "unsupported"}), "registration cancellation stops retry")
    ReactionOverlay.Hide()
    SetReactionStatus("完了テスト", true)
    ShowReactionProgress()
    HideFinishedReactionProgress()
    Assert(!DllCall("IsWindowVisible", "Ptr", ReactionOverlay.Hwnd), "finished overlay hides")
    Assert(ReactionLastResult = "完了テスト", "hiding preserves final result")
    ActiveReactionJob := {Mode: "reaction_send", Cancelled: false}
    SetReactionStatus("実行中テスト")
    ShowReactionProgress()
    HideFinishedReactionProgress()
    Assert(DllCall("IsWindowVisible", "Ptr", ReactionOverlay.Hwnd), "stale hide cannot hide active progress")
    Assert(!ReactionStatusFinal && !InStr(ReactionProgressHint(), "4秒"), "active progress has no completion hint")
    CancelReaction()
    HideFinishedReactionProgress()
    FeatureTabs.Choose(2)
    DanmakuListView.Modify(0, "-Select")
    ShowPreview()
    Assert(!EditButton.Enabled && !DeleteButton.Enabled && !UpButton.Enabled, "selection actions disabled without selection")
    DanmakuListView.Modify(1, "Select")
    ShowPreview()
    Assert(EditButton.Enabled && !UpButton.Enabled, "first item edit enabled but move up disabled")
    Assert(SharedDanmakuItems.Length = 1 && SharedDanmakuItems[1].Text = "👏👏👏👏👏👏", "fixed fixture contains shared applause")
    Assert(IsReservedReactionKey("^!3") && IsReservedReactionKey("!^4"), "shared shortcuts reserved")
    SetLibraryScope(true)
    Assert(!LibraryProfilePicker.Enabled && !LibraryManage.Enabled && !DetectionLabel.Visible, "shared scope hides channel context")
    Assert(DanmakuListView.GetText(1, 1) = "Ctrl＋Alt＋3", "shared shortcut shown")
    NavigatePanel(1)
    Assert(HomeCommonInput.Enabled && HomeCommon.Text = "拍手", "home exposes shared applause")
    NavigatePanel(2)
    OpenDanmakuEditor(true)
    editFields := []
    for control in DanmakuEditorWindow {
        if control.Type = "Edit"
            editFields.Push(control)
        if control.Type = "Button" && control.Text = "保存"
            saveControl := control
    }
    editFields[1].Value := "共通の追加テスト"
    editFields[2].Value := "👏👏"
    DllCall("SendMessage", "Ptr", saveControl.Hwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0)
    Sleep(100)
    Assert(!DanmakuEditorWindow && SharedDanmakuItems.Length = 2 && SharedDanmakuItems[2].Text = "👏👏", "editor adds common text")
    OpenDanmakuEditor(false)
    for control in DanmakuEditorWindow {
        if control.Type = "Edit"
            control.Value := "編集済み"
        if control.Type = "Button" && control.Text = "保存"
            saveControl := control
    }
    DllCall("SendMessage", "Ptr", saveControl.Hwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0)
    Sleep(100)
    Assert(SharedDanmakuItems[2].Text = "編集済み", "editor updates common text")
    DeleteSelectedDanmaku()
    originalProfileCount := Profiles[SelectedProfileIndex].Items.Length
    DuplicateSelectedDanmaku()
    Assert(SharedDanmakuItems.Length = 2 && Profiles[SelectedProfileIndex].Items.Length = originalProfileCount, "shared duplication isolated")
    MoveSelectedDanmaku(-1)
    Assert(SharedDanmakuItems[1].Name = "拍手（コピー）", "shared reorder")
    DeleteSelectedDanmaku()
    Assert(SharedDanmakuItems.Length = 1, "shared delete")
    UndoLibraryChange()
    Assert(SharedDanmakuItems.Length = 2 && IsSharedLibrarySelected, "shared undo restores scope and data")
    TransferSelectedDanmaku()
    Assert(SharedDanmakuItems.Length = 1 && Profiles[SelectedProfileIndex].Items.Length = originalProfileCount + 1, "move shared to author")
    UndoLibraryChange()
    Assert(SharedDanmakuItems.Length = 2 && Profiles[SelectedProfileIndex].Items.Length = originalProfileCount, "undo transfer restores both libraries")
    SetLibraryScope(false)
    TransferSelectedDanmaku()
    Assert(SharedDanmakuItems.Length = 3 && Profiles[SelectedProfileIndex].Items.Length = originalProfileCount - 1, "move author to shared")
    UndoLibraryChange()
    Assert(SharedDanmakuItems.Length = 2 && Profiles[SelectedProfileIndex].Items.Length = originalProfileCount, "undo author transfer")
    SetLibraryScope(true)
    DeleteSelectedDanmaku()
    DeleteSelectedDanmaku()
    Assert(SharedDanmakuItems.Length = 0 && !TransferButton.Enabled, "empty shared library disables actions")
    NavigatePanel(1)
    Assert(!HomeCommonInput.Enabled, "empty shared home input disabled")
    NavigatePanel(2)
    Profiles := []
    ReloadAppSettings()
    Assert(SharedDanmakuItems.Length = 0, "deleted defaults never return after reload")
    SharedDanmakuItems.Push({Name: "保存確認", Text: "👏✨"})
    SaveAppSettingsSnapshot()
    Profiles := []
    ReloadAppSettings()
    Assert(SharedDanmakuItems.Length = 1 && SharedDanmakuItems[1].Text = "👏✨", "shared unicode persists")
    SetLibraryScope(false)

    Profiles := [{Name:"A",Channel:"/channel/A",Reaction:0,Items:[{Name:"A1",Text:"a"}]}, {Name:"B",Channel:"/channel/B",Reaction:0,Items:[{Name:"B1",Text:"b"}]}]
    SelectedProfileIndex := 1
    HasUnsavedProfileReaction := HasUnsavedSharedReaction := HasUnsavedReactionSettings := false
    SaveAppSettingsSnapshot()
    RefreshProfiles()
    SetLibraryScope(false)
    DeleteSelectedDanmaku()
    LibraryProfilePicker.Choose(2)
    ChangeProfile(LibraryProfilePicker)
    ReactionScope.Value := 1
    ReactionChoice.Choose(5)
    CaptureProfileReactionEdits()
    UndoLibraryChange()
    Assert(SelectedProfileIndex = 2 && HasUnsavedProfileReaction && ReactionChoice.Value = 5, "undo preserves author and its reaction draft")
    Assert(Profiles[1].Items.Length = 1, "undo restores original author text")
    CaptureProfileReactionEdits()
    SaveProfileReactionEdits()
    Assert(Profiles[1].Reaction = 0 && Profiles[2].Reaction = 5, "draft saved to intended author after undo")
    SelectCurrentProfile(1)
    RebuildChannelIndex()
    DetectedChannel := {State:"ok", Author:"B", Channel:"/channel/B"}
    reviewManager := BuildProfileManager()
    for control in reviewManager {
        if control.Type = "ListBox" {
            control.Choose(2)
            DllCall("SendMessage", "Ptr", reviewManager.Hwnd, "UInt", 0x111, "UPtr", (1 << 16) | DllCall("GetDlgCtrlID", "Ptr", control.Hwnd), "Ptr", control.Hwnd)
        }
    }
    Sleep(100)
    Assert(SelectedProfileIndex = 2 && Integer(IniRead(SettingsFilePath,"General","Current")) = 2, "manager selection persisted")
    reviewManager.Destroy()
    SelectCurrentProfile(1)
    reviewManager := BuildProfileManager()
    for control in reviewManager {
        if control.Type = "Button" && control.Text = "関連付け先を表示"
            DllCall("SendMessage", "Ptr", control.Hwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0)
    }
    Sleep(100)
    Assert(SelectedProfileIndex = 2 && Integer(IniRead(SettingsFilePath,"General","Current")) = 2, "jump to associated author persisted")
    reviewManager.Destroy()
    Profiles := []
    ReloadAppSettings()
    Assert(SelectedProfileIndex = 2, "manager selection survives reload")
    RefreshProfiles()
    SetLibraryScope(true)
    IsBrowserOperationBusy := true
    InsertHomeProfileDanmaku()
    IsBrowserOperationBusy := false
    Assert(IsSharedLibrarySelected && LibraryScope.Value = 2, "home input never changes library editor scope")
    SetLibraryScope(false)
    selectedItems := Profiles[SelectedProfileIndex].Items
    RecordLibraryUndo([selectedItems], false)
    savedUndo := LibraryUndoSnapshot
    savedIndex := ChannelIndex
    SaveAppSettingsSnapshot()
    Assert(LibraryUndoSnapshot = savedUndo && ChannelIndex = savedIndex, "persistence has no undo or index side effects")
    selectedItems.RemoveAt(1)
    SaveAppSettingsSnapshot()
    ReactionScope.Value := 1
    ReactionChoice.Choose(3)
    CaptureProfileReactionEdits()
    CaptureProfileReactionEdits()
    SaveProfileReactionEdits()
    Assert(LibraryUndoSnapshot = savedUndo, "unrelated reaction save preserves text undo")
    UndoLibraryChange()
    Assert(selectedItems.Length = 1 && Profiles[SelectedProfileIndex].Reaction = 3, "undo restores only affected text")
    ReactionChoice.Choose(4)
    CaptureProfileReactionEdits()
    draftOwner := ProfileReactionDraft.Profile
    SelectedProfileIndex := 1
    CaptureProfileReactionEdits()
    SaveProfileReactionEdits()
    Assert(Profiles[1].Reaction = 0 && draftOwner.Reaction = 3 && HasUnsavedProfileReaction, "stale draft cannot save to a different author")
    SelectedProfileIndex := 2
    DiscardProfileReactionEdits()
    first := [{Name:"one",Text:"1"}]
    second := [{Name:"two",Text:"2"}]
    change := CreateLibraryUndoSnapshot([first], true)
    SetDanmakuItem(first, 1, {Name:"changed",Text:"x"})
    SetDanmakuItem(second, 1, {Name:"retained",Text:"y"})
    RestoreLibraryUndoSnapshot(change)
    Assert(first[1].Text = "1" && second[1].Text = "y", "library undo only changes explicit targets")
    MainWindow.Opt("+Disabled")
    directReply := SendWorkerRequest(123, "reaction_context")
    Assert(directReply.State = "ok" && !DllCall("IsWindowEnabled", "Ptr", MainWindow.Hwnd), "transport leaves disabled UI unchanged")
    wrappedReply := RequestBrowserOperation(123, "reaction_context")
    Assert(wrappedReply.State = "ok" && !DllCall("IsWindowEnabled", "Ptr", MainWindow.Hwnd) && !IsBrowserOperationBusy, "request feedback restores prior disabled state")
    MainWindow.Opt("-Disabled")
    recordCount := Profiles.Length
    ReloadAppSettings()
    ReloadAppSettings()
    Assert(Profiles.Length = recordCount, "repeated reload replaces rather than appends profiles")
    RefreshProfiles()
    initialDraft := ProfileReactionDraft
    RefreshReactionUI()
    Assert(ProfileReactionDraft = initialDraft, "render does not replace draft")
    diskPath := SettingsFilePath
    diskBefore := FileRead(SettingsFilePath)
    oldReaction := Profiles[SelectedProfileIndex].Reaction
    ReactionScope.Value := 1
    ReactionChoice.Choose(oldReaction = 4 ? 5 : 4)
    CaptureProfileReactionEdits()
    intendedReaction := ProfileReactionDraft.Reaction
    oldShortcut := ReactionShortcut
    oldCount := ReactionCount
    ReactionKeyControl.Value := oldShortcut = "^!t" ? "^!y" : "^!t"
    ReactionCountChoice.Choose(2)
    CaptureSharedReactionEdits()
    global KeyCalls := []
    SettingsFilePath := A_ScriptDir "\missing-parent\settings.ini"
    SaveProfileReactionEdits()
    Assert(Profiles[SelectedProfileIndex].Reaction = oldReaction && HasUnsavedProfileReaction && ProfileReactionDraft.Reaction = intendedReaction, "failed profile save retains live value and editable draft")
    SaveSharedReactionEdits()
    Assert(ReactionShortcut = oldShortcut && ReactionCount = oldCount && HasUnsavedSharedReaction, "failed common save retains active settings")
    Assert(KeyCalls.Length = 4 && KeyCalls[1].Enabled && !KeyCalls[2].Enabled && KeyCalls[3].Key = oldShortcut && KeyCalls[3].Enabled && !KeyCalls[4].Enabled, "failed persistence restores prior hotkey registration")
    beforeProfile := Profiles[SelectedProfileIndex]
    HasUnsavedProfileReaction := false
    failed := false
    try ExecuteProfileCommand("rename", SelectedProfileIndex, "must not persist")
    catch
        failed := true
    Assert(failed && Profiles[SelectedProfileIndex] = beforeProfile, "failed profile command preserves active records")
    HasUnsavedProfileReaction := true
    targetItems := Profiles[SelectedProfileIndex].Items
    beforeText := targetItems[1].Text
    changedItems := CopyItems(targetItems)
    changedItems[1].Text := "must not persist"
    failed := false
    try SaveLibraryTargets([targetItems], [changedItems])
    catch
        failed := true
    Assert(failed && targetItems[1].Text = beforeText, "failed library save does not change live text")
    Assert(FileRead(diskPath) = diskBefore, "failed transactions preserve settings file")
    SettingsFilePath := diskPath
    badConfig := A_ScriptDir "\invalid-settings.ini"
    FileAppend("[General]`nCount=invalid`n", badConfig, "UTF-16")
    SettingsFilePath := badConfig
    beforeProfiles := Profiles
    failed := false
    try ReloadAppSettings()
    catch
        failed := true
    Assert(failed && Profiles = beforeProfiles && HasUnsavedProfileReaction, "invalid reload does not replace live state or draft")
    SettingsFilePath := diskPath
    ; Saving uses the draft, not a second read of control values.
    ReactionChoice.Choose(intendedReaction = 5 ? 4 : 5)
    SaveProfileReactionEdits()
    Assert(Profiles[SelectedProfileIndex].Reaction = intendedReaction && !HasUnsavedProfileReaction, "retry saves captured draft rather than controls")
    DiscardSharedReactionEdits()
    oldSize := Profiles.Length
    ReactionCountChoice.Choose(2)
    CaptureSharedReactionEdits()
    ReactionCountChoice.Choose(3)
    SaveSharedReactionEdits()
    Assert(ReactionCount = 10 && Integer(IniRead(SettingsFilePath,"General","ReactionCount")) = 10, "common save uses draft rather than controls")
    prior := ExecuteProfileCommand("add", SelectedProfileIndex, "service-only author")
    Assert(Profiles.Length = oldSize + 1 && Profiles[SelectedProfileIndex].Name = "service-only author", "profile add works without manager GUI")
    ExecuteProfileCommand("rename", SelectedProfileIndex, "renamed")
    ExecuteProfileCommand("bind", SelectedProfileIndex, "/channel/service")
    Assert(ChannelIndex.Get("/channel/service", 0) = SelectedProfileIndex && Profiles[SelectedProfileIndex].Name = "renamed", "profile service maintains channel index")
    ExecuteProfileCommand("undo", SelectedProfileIndex, "", prior)
    Assert(Profiles.Length = oldSize && !ChannelIndex.Has("/channel/service"), "profile service undo restores records and index")
    RefreshProfiles()
    context := RequestBrowserOperation(123, "reaction_context")
    Assert(context.State = "ok" && context.Video = "abcdefghijk", "pipe reaction context")
    result := RequestBrowserOperation(123, "reaction_check", context.Video)
    Assert(result.State = "ready", "non-sending check through pipe")
    result := RequestBrowserOperation(123, "reaction_send", "ABCDEFGHIJK", "Reaction=1`n")
    Assert(result.State = "changed", "changed video rejected through pipe")
    result := RequestBrowserOperation(123, "reaction_send", context.Video, "Reaction=5`n")
    Assert(result.State = "operated", "mock operation through pipe")
    result := RequestBrowserOperation(123, "reaction_send", context.Video, "Reaction=5`n")
    Assert(result.State = "cooldown" || result.State = "operated", "subsequent pipe request handled across cooldown boundary")
    firstPID := WorkerProcessId
    StopBrowserWorker()
    Assert(!ProcessExist(firstPID), "worker shuts down")
    BeginReactionEditing()
    HasUnsavedSharedReaction := true
    HasUnsavedReactionSettings := true
    SharedReactionDraft.Count := 1000
    sharedDraftBefore := SharedReactionDraft
    Assert(CanChangeProfile(), "shared-only edits allow profile transition")
    SaveSelectedProfile(SelectedProfileIndex)
    Assert(SharedReactionDraft = sharedDraftBefore && SharedReactionDraft.Count = 1000 && HasUnsavedSharedReaction, "profile selection preserves shared draft")
    HasUnsavedProfileReaction := true
    blocked := false
    try SaveSelectedProfile(SelectedProfileIndex)
    catch
        blocked := true
    Assert(blocked && !CanChangeProfile(), "service rejects selection with unsaved profile edits")
    BeginReactionEditing()
    ActiveReactionJob := {Mode: "queued", Cancelled: false, Window: 0}
    SetReactionStatus("文言を変更した開始待ち", false, "queued")
    ReactionInfo.Text := "表示だけを書き換えた文言"
    QuickReaction()
    Assert(!ActiveReactionJob && ReactionExecutionStatus.Final && ReactionExecutionStatus.Phase = "finished", "early exit finalizes regardless of displayed wording")
    Assert(InStr(ReactionExecutionStatus.Message, "開始できません"), "early exit records controller outcome")
    ActiveReactionJob := {Mode: "queued", Cancelled: false, Window: 0}
    SetReactionStatus("開始待ち", false, "queued")
    CancelReaction()
    cancelledMessage := ReactionExecutionStatus.Message
    QuickReaction()
    Assert(ReactionExecutionStatus.Message = cancelledMessage, "queued cancellation result is retained")
    schemaPath := A_ScriptDir "\schema-check.ini"
    schemaState := CreateSettingsSnapshot()
    schemaState.SharedDanmakuItems := [
        {Name:Chr(34) "quoted label" Chr(34), Text:"  👏👏  "},
        {Name:"quoted text", Text:Chr(34) "👏" Chr(34)},
        {Name:"single quotes", Text:"'👏'"}]
    WriteSettingsFile(schemaState, schemaPath)
    roundTrip := ReadSettingsFile(schemaPath)
    for i, expected in schemaState.SharedDanmakuItems {
        Assert(roundTrip.SharedDanmakuItems[i].Name == expected.Name, "INI preserves label quotes")
        Assert(roundTrip.SharedDanmakuItems[i].Text == expected.Text, "INI preserves literal text and spaces")
    }
    savedRoundTrip := FileRead(schemaPath)
    schemaState.SharedDanmakuItems[1].Text := "first`nsecond"
    rejected := false
    try WriteSettingsFile(schemaState, schemaPath)
    catch
        rejected := true
    Assert(rejected && FileRead(schemaPath) == savedRoundTrip && !FileExist(schemaPath ".new"), "multiline text cannot corrupt persisted INI")
    schemaState.SharedDanmakuItems[1].Text := "👏"
    ReactionCounts.Push(7)
    ReactionIntervals.Push(75)
    try {
        schemaState.ReactionCount := 7
        schemaState.ReactionInterval := 75
        WriteSettingsFile(schemaState, schemaPath)
        schemaRead := ReadSettingsFile(schemaPath)
        Assert(schemaRead.ReactionCount = 7 && schemaRead.ReactionInterval = 75, "store accepts options from shared schema")
        Assert(SettingOptionLabels(ReactionCounts, "回")[-1] = "7回" && SettingOptionLabels(ReactionIntervals, " ms")[-1] = "75 ms", "UI labels follow shared schema")
    } finally {
        ReactionCounts.Pop()
        ReactionIntervals.Pop()
        FileDelete(schemaPath)
    }
    FileAppend("PASS: " Checks " application and named-pipe checks`n", "*")
    ExitApp(0)
} catch as testError {
    FileAppend("FAIL: " testError.Message " at line " testError.Line "`n", "*")
    ExitApp(1)
}
Assert(condition, label) {
    global Checks
    if !condition
        throw Error(label)
    Checks++
}
SetReactionHotkey(key, enabled := true) {
    RegisterFixtureHotkey(key, enabled)
    if IsSet(KeyCalls)
        KeyCalls.Push({Key:key, Enabled:enabled})
}
CheckHelpOwner() {
    global HelpOwnerMatches
    hwnd := WinExist("使い方 ahk_class #32770 ahk_pid " DllCall("GetCurrentProcessId"))
    if !hwnd
        return
    HelpOwnerMatches := DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") = MainWindow.Hwnd
    SetTimer(CheckHelpOwner, 0)
    WinClose("ahk_id " hwnd)
}
'@
$source = $source.Replace('OnExit(StopBrowserWorker)', $tests)
[IO.File]::WriteAllText("$fixture\test.ahk", $source, [Text.UTF8Encoding]::new($true))
$run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut',('"' + "$fixture\test.ahk" + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput "$fixture\out.txt" -RedirectStandardError "$fixture\error.txt"
$null = $run.Handle
if (-not $run.WaitForExit(30000)) { $run.Kill(); throw 'Test timeout' }
Get-Content "$fixture\out.txt","$fixture\error.txt"
if ($run.ExitCode -ne 0) { throw 'Application test failed' }
