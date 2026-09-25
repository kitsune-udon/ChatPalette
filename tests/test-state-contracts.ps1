# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
# Pause at the commit boundary only in the isolated runtime, allowing a real AHK timer to compete.
$commitAnchor = 'ApplyPreferences(state, persist := true) {'
Edit-TestSource $release 'src/settings/settings_service.ahk' $commitAnchor ($commitAnchor + "`r`n    ProbePreferenceCommit()")
$tests = @'
AutoMode := false
originalLibrary := CreateTestLibrarySnapshot()
caseLibrary := CreateTestLibrarySnapshot()
caseLibrary.Profiles.Push({Id:"case-profile",Name:"lower",Channel:"",Items:[{Id:"case-item",Name:"lower item",Text:"lower",Slot:1},{Id:"CASE-ITEM",Name:"upper item",Text:"upper",Slot:2}]})
caseLibrary.Profiles.Push({Id:"CASE-PROFILE",Name:"upper",Channel:"",Items:[]})
CommitTestLibraryChange(caseLibrary,"case-sensitive identities")
Assert(FindProfileById(Profiles,"CASE-PROFILE").Name="upper","profile lookup preserves exact stored identity")
SaveInputProfileId("case-profile")
SaveInputProfileId("CASE-PROFILE")
Assert(InputProfileId=="CASE-PROFILE" && LoadSettings(SettingsDatabasePath).InputProfileId=="CASE-PROFILE","case-only selection change persists exact identity")
for unknownId in ["missing-profile","Case-profile","@shared"] {
    beforeSelectionHistory := LibraryHistory.Length
    rejected := false
    try SaveInputProfileId(unknownId)
    catch
        rejected := true
    Assert(rejected && InputProfileId=="CASE-PROFILE"
        && LoadSettings(SettingsDatabasePath).InputProfileId=="CASE-PROFILE"
        && LibraryHistory.Length=beforeSelectionHistory,"invalid input selection reports failure and preserves saved selection: " unknownId)
}
ExecuteProfileCommand("rename","CASE-PROFILE","renamed upper")
Assert(FindProfileById(Profiles,"case-profile").Name="lower" && FindProfileById(Profiles,"CASE-PROFILE").Name="renamed upper","edit cannot target a case-insensitive match")
historyBeforeAssignment := LibraryHistory.Length
rejected := false
try SaveShortcutItemAssignments("case-profile","Case-item","")
catch
    rejected := true
assigned := GetLibraryItems(LoadSettings(SettingsDatabasePath),"case-profile")
Assert(rejected && assigned[1].Slot=1 && assigned[2].Slot=2 && LibraryHistory.Length=historyBeforeAssignment,"unknown case variant cannot clear saved assignments or add history")
SaveShortcutItemAssignments("case-profile","CASE-ITEM","case-item")
assigned := GetLibraryItems(LoadSettings(SettingsDatabasePath),"case-profile")
Assert(assigned[1].Slot=2 && assigned[2].Slot=1,"exact case-distinct item identities swap assignments")
ExecuteProfileCommand("delete","CASE-PROFILE")
Assert(FindProfileById(Profiles,"case-profile") && !FindProfileById(Profiles,"CASE-PROFILE"),"deletion removes only exact profile")
CommitTestLibraryChange(originalLibrary,"restore identity fixture")
a := ExecuteProfileCommand("add","","A").ProfileId
b := ExecuteProfileCommand("add","","B").ProfileId
c := ExecuteProfileCommand("add","","C").ProfileId
SaveInputProfileId(c)
BuildManagement()
EditingProfileId := b
RefreshPalette(), RefreshManagement()
oldBChoice := FindProfileIndexById(Profiles,b)
ExecuteProfileCommand("delete",a)
Assert(GetInputProfile().Id=c && GetEditingProfileId()=b,"deleting preceding profile preserves both independent identities")
Assert(LoadSettings(SettingsDatabasePath).InputProfileId=c,"active identity persists without a list index")
; The displayed choices still predate the deletion, as after a failed refresh.
ManagementTarget.Choose(oldBChoice+1)
ChangeManagementTarget()
Assert(EditingProfileId==b,"management resolves the displayed profile identity after preceding deletion")
PaletteProfile.Choose(oldBChoice)
SelectPaletteProfile()
Assert(InputProfileId==b && LoadSettings(SettingsDatabasePath).InputProfileId==b,"palette saves the displayed profile identity after preceding deletion")
SaveInputProfileId(c)
UndoLibraryCommand()
Assert(GetInputProfile().Id=c && GetEditingProfileId()=b,"undo restores order without retargeting either selection")
RefreshPalette(), RefreshManagement()
oldCChoice := FindProfileIndexById(Profiles,c)
ExecuteProfileCommand("delete",c)
Assert(!GetInputProfile() && InputProfileId="","deleting selected profile clears input target")
ManagementTarget.Choose(oldCChoice+1)
ChangeManagementTarget()
Assert(EditingProfileId==b && InStr(ManagementStatus.Text,"選び直してください"),"deleted management choice is rejected without choosing another profile")
PaletteProfile.Choose(oldCChoice)
SelectPaletteProfile()
Assert(InputProfileId="" && LoadSettings(SettingsDatabasePath).InputProfileId="" && InStr(PaletteHint.Text,"選び直してください"),"deleted palette choice is rejected without changing saved selection")
ManagementTarget.Choose(0)
ChangeManagementTarget()
Assert(EditingProfileId==b,"absent selection is not interpreted as shared items")
ManagementTarget.Choose(1)
ChangeManagementTarget()
Assert(EditingProfileId="","explicit shared choice selects shared items")
EditingProfileId := b
UndoLibraryCommand()
Assert(!GetInputProfile(),"undo does not reselect deleted input target")
EditingProfileId := ""
Loop 3
    ExecuteDanmakuCommand("add","","",{Name:"same",Text:"same",Slot:0})
RefreshPalette(), RefreshManagement()
selectedId := SharedDanmakuItems[2].Id
PaletteList.Modify(2,"Select Focus"), ManagedList.Modify(2,"Select Focus")
ExecuteDanmakuCommand("delete","",SharedDanmakuItems[1].Id)
RefreshPalette(), RefreshManagement()
Assert(PaletteList.GetText(PaletteList.GetNext(),4)=selectedId,"palette restores duplicate text by ID after preceding deletion")
Assert(ManagedList.GetText(ManagedList.GetNext(),4)=selectedId,"management restores duplicate text by ID after preceding deletion")
ExecuteDanmakuCommand("edit","",SharedDanmakuItems[1].Id,{Name:"renamed",Text:"changed",Slot:0})
RefreshPalette(), RefreshManagement()
Assert(PaletteList.GetText(PaletteList.GetNext(),4)=selectedId && ManagedList.GetText(ManagedList.GetNext(),4)=selectedId,"text edits preserve selected identity")
; Mixed edits exercise one changed-range planner, including unchanged interior items.
Loop 12
    ExecuteDanmakuCommand("add","","",{Name:"item" A_Index,Text:"body" A_Index,Slot:0})
store := OpenSettingsRepository(SettingsDatabasePath)
for operation in ["insert","delete","mixed","reverse","duplicate-id","duplicate-slot"] {
    original := CreateTestSettingsSnapshot(), draft := CreateTestLibrarySnapshot()
    oldRows := store.Saved.Scopes["@shared"].Rows, oldRanks := Map()
    for id, row in oldRows
        oldRanks[id] := row.Position
    if operation="insert" {
        Loop 3
            draft.SharedDanmakuItems.InsertAt(4,{Id:NewRecordId(),Name:"insert",Text:"insert",Slot:0})
    } else if operation="delete" {
        draft.SharedDanmakuItems.RemoveAt(3,4)
    } else if operation="mixed" {
        draft.SharedDanmakuItems[2].Text := "left"
        draft.SharedDanmakuItems[-2].Text := "right"
        draft.SharedDanmakuItems.RemoveAt(5)
        draft.SharedDanmakuItems.InsertAt(8,{Id:NewRecordId(),Name:"mixed",Text:"mixed",Slot:0})
    } else if operation="reverse" {
        reversed := []
        for item in draft.SharedDanmakuItems
            reversed.InsertAt(1,item)
        draft.SharedDanmakuItems := reversed
    } else if operation="duplicate-id" {
        draft.SharedDanmakuItems.InsertAt(3,draft.SharedDanmakuItems[1].Clone())
    } else {
        draft.SharedDanmakuItems[1].Slot := 1
        draft.SharedDanmakuItems[-1].Slot := 1
    }
    failed := false
    try CommitTestLibraryChange(draft,operation)
    catch
        failed := true
    for id, row in oldRows
        Assert(row.Position=oldRanks[id],"planner never mutates previous ranks: " operation)
    if operation="duplicate-id" || operation="duplicate-slot" {
        Assert(failed,"invalid identity/slot rejected: " operation)
        VerifySettingsRoundTrip(original,LoadSettings(SettingsDatabasePath))
    } else {
        Assert(!failed,"valid mixed change saves: " operation)
        VerifySettingsRoundTrip(CreateTestSettingsSnapshot(),LoadSettings(SettingsDatabasePath))
        UndoLibraryCommand()
        VerifySettingsRoundTrip(original,LoadSettings(SettingsDatabasePath))
    }
}
; Dense insertions exhaust rank gaps and must rebalance without changing old rows.
seed := [{Id:"left",Name:"left",Text:"left",Slot:0},{Id:"right",Name:"right",Text:"right",Slot:0}]
baseline := BuildScopeStorageDelta(seed,0)
oldScope := {Items:seed,Rows:baseline.Rows,TextBytes:baseline.TextBytes}
for at in [1,2,3] {
    expanded := seed.Clone()
    Loop 20
        expanded.InsertAt(at,{Id:"added-" A_Index,Name:"new",Text:"new",Slot:0})
    delta := BuildScopeStorageDelta(expanded,oldScope)
    rank := 0
    for item in expanded {
        Assert(delta.Rows[item.Id].Position>rank,"inserted ranks stay strictly ordered at " at)
        rank := delta.Rows[item.Id].Position
    }
    Assert(oldScope.Rows["left"].Position=1024 && oldScope.Rows["right"].Position=2048,"rank expansion preserves baseline")
    Assert(delta.Rows.Count=22 && delta.Deleted.Length=0,"all inserted rows retained")
}
oldJob := CreateReactionJob({Mode:"queued"})
currentJob := CreateReactionJob({Mode:"queued"})
ActiveReactionJob := currentJob
RefreshOperationControls()
FinishReactionJob(oldJob)
Assert(ActiveReactionJob=currentJob && currentJob.Phase="queued","stale cleanup preserves replacement job")
Assert(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"stale cleanup keeps replacement job controls disabled")
Assert(!SetReactionJobPhase(oldJob,"running"),"stale callback cannot restart completed job")
IsBrowserOperationBusy := true
CancelReaction()
Assert(currentJob.Phase="stopping" && ActiveReactionJob=currentJob,"cancel during request waits for result")
IsBrowserOperationBusy := false
CancelReaction()
Assert(currentJob.Phase="finished" && currentJob.Cancelled && !ActiveReactionJob,"cancel cleanup finishes once")
Assert(!SetReactionJobPhase(currentJob,"running"),"finished cancellation cannot resume")
RuntimePorts.ShortcutRelease := (keys) => true
RuntimePorts.Foreground := (hwnd) => true
RuntimePorts.BrowserRequest := CancelQueuedContext
queued := CreateReactionJob({Mode:"queued",Window:123})
ActiveReactionJob := queued
SetReactionStatus("queued",false)
QuickReaction()
Assert(!ActiveReactionJob && queued.Phase="finished" && LastReactionResult.Reason="cancelled" && ReactionExecutionStatus.Phase="finished","cancel during queued context request publishes terminal cancellation")
; A queued selection change must run wholly before or after a preference edit.
global ProbePreferenceArmed := false, ProbePreferenceRuns := 0, ProbePreferenceTarget := b
for saveChange in [() => SaveAutoDetection(!AutoMode),
    () => SaveReactionDefaults(CreateReactionOptions(DefaultReactionKind=1 ? 2 : 1,DefaultReactionCount,DefaultReactionIntervalMs)),
    () => SaveShortcutMap(MapWithChangedFocusKey())] {
    SaveInputProfileId(a)
    ProbePreferenceRuns := 0, ProbePreferenceArmed := true
    saveChange.Call()
    deadline := A_TickCount+1000
    while !ProbePreferenceRuns && A_TickCount<deadline
        Sleep(10)
    Assert(!ProbePreferenceArmed && ProbePreferenceRuns=1,"queued selection actually reaches preference commit boundary")
    persisted := LoadSettings(SettingsDatabasePath)
    Assert(InputProfileId==b && persisted.InputProfileId==b,"preference edit cannot overwrite a concurrent profile selection")
    Assert(persisted.AutoMode=AutoMode && persisted.ShortcutKeys["reaction"]==ShortcutKeys["reaction"]
        && persisted.ShortcutKeys["chat_focus"]==ShortcutKeys["chat_focus"],"concurrent selection retains committed preference values")
}
FileAppend("PASS: " Checks " identity, publication, storage-range and job-state checks`n","*")
ExitApp()
ProbePreferenceCommit() {
    global ProbePreferenceArmed
    if !IsSet(ProbePreferenceArmed) || !ProbePreferenceArmed
        return
    ProbePreferenceArmed := false
    SetTimer(SelectProfileDuringPreferences,-1)
    Sleep(30)
}
SelectProfileDuringPreferences() {
    global ProbePreferenceRuns
    SaveInputProfileId(ProbePreferenceTarget)
    ProbePreferenceRuns++
}
MapWithChangedFocusKey() {
    keys := CurrentShortcutMap(), keys["chat_focus"] := "^+f"
    return keys
}
CancelQueuedContext(*) {
    global IsBrowserOperationBusy := true
    try CancelReaction()
    finally IsBrowserOperationBusy := false
    return {State:"ok",Video:"abcdefghijk"}
}
'@
Invoke-AppTest -Runtime $release -Body $tests
