# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$tests = @'
global ContractChecks := 0
try {
    AutoMode := false
    a := ExecuteProfileCommand("add","","A").ProfileId
    b := ExecuteProfileCommand("add","","B").ProfileId
    c := ExecuteProfileCommand("add","","C").ProfileId
    SaveInputProfileId(c)
    BuildManagement()
    EditingProfileId := b
    ExecuteProfileCommand("delete",a)
    CheckContract(GetInputProfile().Id=c && GetEditingProfileId()=b,"deleting preceding profile preserves both independent identities")
    CheckContract(LoadSettings(SettingsDatabasePath).InputProfileId=c,"active identity persists without a list index")
    UndoLibraryCommand()
    CheckContract(GetInputProfile().Id=c && GetEditingProfileId()=b,"undo restores order without retargeting either selection")
    ExecuteProfileCommand("delete",c)
    CheckContract(!GetInputProfile() && InputProfileId="","deleting selected profile clears input target")
    UndoLibraryCommand()
    CheckContract(!GetInputProfile(),"undo does not reselect deleted input target")
    EditingProfileId := ""
    Loop 3
        ExecuteDanmakuCommand("add","",0,{Name:"same",Text:"same",Slot:0})
    RefreshPalette(), RefreshManagement()
    selectedId := SharedDanmakuItems[2].Id
    PaletteList.Modify(2,"Select Focus"), ManagedList.Modify(2,"Select Focus")
    ExecuteDanmakuCommand("delete","",1)
    RefreshPalette(), RefreshManagement()
    CheckContract(PaletteList.GetText(PaletteList.GetNext(),4)=selectedId,"palette restores duplicate text by ID after preceding deletion")
    CheckContract(ManagedList.GetText(ManagedList.GetNext(),4)=selectedId,"management restores duplicate text by ID after preceding deletion")
    ExecuteDanmakuCommand("edit","",1,{Name:"renamed",Text:"changed",Slot:0})
    RefreshPalette(), RefreshManagement()
    CheckContract(PaletteList.GetText(PaletteList.GetNext(),4)=selectedId && ManagedList.GetText(ManagedList.GetNext(),4)=selectedId,"text edits preserve selected identity")
    ; Mixed edits exercise one changed-range planner, including unchanged interior items.
    Loop 12
        ExecuteDanmakuCommand("add","",0,{Name:"item" A_Index,Text:"body" A_Index,Slot:0})
    store := OpenSettingsRepository(SettingsDatabasePath)
    for operation in ["insert","delete","mixed","reverse","duplicate-id","duplicate-slot"] {
        original := CreateSettingsSnapshot(), draft := CreateLibrarySnapshot()
        oldRows := store.Scopes["@shared"].Rows, oldRanks := Map()
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
        try CommitLibraryChange(draft,operation)
        catch
            failed := true
        for id, row in oldRows
            CheckContract(row.Position=oldRanks[id],"planner never mutates previous ranks: " operation)
        if operation="duplicate-id" || operation="duplicate-slot" {
            CheckContract(failed,"invalid identity/slot rejected: " operation)
            VerifySettingsMigration(original,LoadSettings(SettingsDatabasePath))
        } else {
            CheckContract(!failed,"valid mixed change saves: " operation)
            VerifySettingsMigration(CreateSettingsSnapshot(),LoadSettings(SettingsDatabasePath))
            UndoLibraryCommand()
            VerifySettingsMigration(original,LoadSettings(SettingsDatabasePath))
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
            CheckContract(delta.Rows[item.Id].Position>rank,"inserted ranks stay strictly ordered at " at)
            rank := delta.Rows[item.Id].Position
        }
        CheckContract(oldScope.Rows["left"].Position=1024 && oldScope.Rows["right"].Position=2048,"rank expansion preserves baseline")
        CheckContract(delta.Rows.Count=22 && delta.Deleted.Length=0,"all inserted rows retained")
    }
    oldJob := CreateReactionJob({Mode:"queued"})
    currentJob := CreateReactionJob({Mode:"queued"})
    ActiveReactionJob := currentJob
    FinishReactionJob(oldJob)
    CheckContract(ActiveReactionJob=currentJob && currentJob.Phase="queued","stale cleanup preserves replacement job")
    CheckContract(!SetReactionJobPhase(oldJob,"running"),"stale callback cannot restart completed job")
    IsBrowserOperationBusy := true
    CancelReaction()
    CheckContract(currentJob.Phase="stopping" && ActiveReactionJob=currentJob,"cancel during request waits for result")
    IsBrowserOperationBusy := false
    CancelReaction()
    CheckContract(currentJob.Phase="finished" && currentJob.Cancelled && !ActiveReactionJob,"cancel cleanup finishes once")
    CheckContract(!SetReactionJobPhase(currentJob,"running"),"finished cancellation cannot resume")
    RuntimePorts.ShortcutRelease := (keys) => true
    RuntimePorts.Foreground := (hwnd) => true
    RuntimePorts.BrowserRequest := CancelQueuedContext
    queued := CreateReactionJob({Mode:"queued",Window:123})
    ActiveReactionJob := queued
    SetReactionStatus("queued",false,"queued")
    QuickReaction()
    CheckContract(!ActiveReactionJob && queued.Phase="finished" && LastReactionResult.Reason="cancelled" && ReactionExecutionStatus.Final,"cancel during queued context request publishes terminal cancellation")
    FileAppend("PASS: " ContractChecks " identity, publication, storage-range and job-state checks`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n","**")
    ExitApp(1)
}
CancelQueuedContext(*) {
    global IsBrowserOperationBusy := true
    try CancelReaction()
    finally IsBrowserOperationBusy := false
    return {State:"ok",Video:"abcdefghijk"}
}
CheckContract(value,message) {
    global ContractChecks
    if !value
        throw Error(message)
    ContractChecks++
}
'@
Invoke-AppTest -Runtime $release -Body $tests
