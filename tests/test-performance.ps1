# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'fixtures\ui-message-probe.ahk') (Join-Path $release 'ui-message-probe.ahk')
$tests = @'
OnExit(StopBrowserWorker)
#Include %A_ScriptDir%\ui-message-probe.ahk
UiMessageProbe.Start()
global PerfChecks := 0
try {
    a := ExecuteProfileCommand("add","","A","/channel/a").ProfileId
    b := ExecuteProfileCommand("add","","B","/channel/b").ProfileId
    ExecuteProfileCommand("add","","untouched","/channel/untouched")
    for id in ["",a,b] {
        ExecuteDanmakuCommand("add",id,0,{Name:"first",Text:"first",Slot:1})
        ExecuteDanmakuCommand("add",id,0,{Name:"second",Text:"second",Slot:2})
    }
    for id in ["",a,b] {
        for action in ["edit","up","down","duplicate","delete","move"] {
            old := {Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems}
            signature := Fingerprint(old)
            history := LibraryHistory.Length
            index := action="up" ? 2 : 1
            result := ExecuteDanmakuCommand(action,id,index,{Name:"changed",Text:"changed",Slot:2},id=b ? a : b)
            CheckPerf(Fingerprint(old)==signature,"published history immutable: " id action)
            for oldProfile in old.Profiles {
                if oldProfile.Id == id || (action="move" && oldProfile.Id == (id=b ? a : b))
                    continue
                CheckPerf(FindProfileById(Profiles,oldProfile.Id)=oldProfile,"unchanged profile reused after item command: " id action)
            }
            UndoLibraryCommand()
            CheckPerf(Fingerprint({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems})==signature,"undo restores data and slots: " id action)
            oldPath := SettingsDatabasePath, SettingsDatabasePath := A_ScriptDir "\missing\settings.ini"
            failed := false
            try ExecuteDanmakuCommand(action,id,index,{Name:"changed",Text:"changed",Slot:2},id=b ? a : b)
            catch
                failed := true
            SettingsDatabasePath := oldPath
            CheckPerf(failed && LibraryHistory.Length=history && Fingerprint(old)==signature
                && Fingerprint({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems})==signature,"failed command leaves history and live data unchanged: " id action)
        }
    }
    for action in ["rename","bind","unbind","delete"] {
        old := {Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems}, signature := Fingerprint(old)
        ExecuteProfileCommand(action,a,action="bind" ? "/channel/new" : "changed")
        CheckPerf(Fingerprint(old)==signature,"profile metadata immutable: " action)
        for oldProfile in old.Profiles
            if !(oldProfile.Id == a)
                CheckPerf(FindProfileById(Profiles,oldProfile.Id)=oldProfile,"other profiles reused after metadata command: " action)
        UndoLibraryCommand()
        CheckPerf(Fingerprint({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems})==signature,"profile undo: " action)
    }
    external := CreateLibrarySnapshot()
    CommitLibraryChange(external,"external draft")
    external.SharedDanmakuItems[1].Text := "caller mutation"
    external.Profiles[1].Name := "caller mutation"
    CheckPerf(SharedDanmakuItems[1].Text!="caller mutation" && Profiles[1].Name!="caller mutation","external draft remains detached")
    item := SharedDanmakuItems[1], LibraryHistory := []
    Loop 30
        ExecuteDanmakuCommand("down","",1)
    for entry in LibraryHistory
        CheckPerf(entry.SharedDanmakuItems[1]=item || entry.SharedDanmakuItems[2]=item,"unchanged item reused across history")
    held := LibraryHistory[-1], signature := Fingerprint(held)
    UndoLibraryCommand()
    ExecuteDanmakuCommand("edit","",1,{Name:"branch",Text:"branch",Slot:2})
    CheckPerf(Fingerprint(held)==signature,"edit after undo does not mutate prior branch")
    oldPath := SettingsDatabasePath, SettingsDatabasePath := A_ScriptDir "\missing\settings.ini"
    SaveReactionDefaults(CreateReactionOptions(DefaultReactionKind,DefaultReactionCount,DefaultReactionIntervalMs,ShortcutKeys["reaction"]))
    SaveAutoDetection(AutoMode)
    CheckPerf(true,"unchanged preferences skip file access")
    failed := false
    try SaveReactionDefaults(CreateReactionOptions(DefaultReactionKind=1 ? 2 : 1,DefaultReactionCount,DefaultReactionIntervalMs,ShortcutKeys["reaction"]))
    catch
        failed := true
    CheckPerf(failed,"changed preferences still save transactionally")
    SettingsDatabasePath := oldPath
    BuildManagement()
    AutoMode := false, SharedDanmakuItems := []
    Loop 60
        SharedDanmakuItems.Push({Id:NewRecordId(),Name:"row" A_Index,Text:"text" A_Index,Slot:0})
    EditingProfileId := ""
    ShowManagement(1)
    SelectManagedRow(40)
    top := SendMessage(0x1027,0,0,ManagedList.Hwnd)
    RefreshManagement()
    CheckPerf(ManagedList.GetNext()=40 && SendMessage(0x1027,0,0,ManagedList.Hwnd)=top,"management full refresh preserves selection and viewport: selected=" ManagedList.GetNext() " top=" top " actual=" SendMessage(0x1027,0,0,ManagedList.Hwnd))
    RefreshPalette()
    PaletteWindow.Hide()
    prior := UiMessageProbe.Renders
    RefreshVisiblePalette()
    CheckPerf(UiMessageProbe.Renders=prior,"hidden palette is not rebuilt")
    ExecuteDanmakuCommand("edit","",1,{Name:"fresh",Text:"fresh",Slot:0})
    ReturnToPalette()
    CheckPerf(PaletteRows[1].Text="fresh","return renders current data")
    PaletteList.Modify(40,"Select Focus Vis")
    top := SendMessage(0x1027,0,0,PaletteList.Hwnd)
    RefreshPalette()
    CheckPerf(PaletteList.GetNext()=40 && SendMessage(0x1027,0,0,PaletteList.Hwnd)=top,"palette full refresh preserves selection and viewport")
    PaletteSearch.Value := "text60"
    RefreshPaletteItems()
    CheckPerf(PaletteRows.Length=1 && PaletteRows[1].Text="text60" && PaletteList.GetNext()=1,"search selection remains valid")
    AutoMode := true, TargetBrowserHwnd := 123
    prior := UiMessageProbe.Renders
    RefreshPaletteForTarget()
    CheckPerf(UiMessageProbe.Renders=prior+1,"detection renders exactly once")
    RefreshOperationControls()
    writes := UiMessageProbe.Writes
    Loop 20
        RefreshOperationControls()
    CheckPerf(UiMessageProbe.Writes=writes,"unchanged palette controls and preview perform zero native property writes")
    IsBrowserOperationBusy := true
    RefreshOperationControls()
    CheckPerf(UiMessageProbe.Writes>writes && !PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"changed state still updates native controls")
    IsBrowserOperationBusy := false
    RefreshOperationControls()
    CheckPerf(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"controls recover after busy state")
    FileAppend("PASS: " PerfChecks " performance regression checks`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.Line "`n","**")
    ExitApp(1)
}
Fingerprint(library) {
    text := ""
    for p in library.Profiles {
        text .= p.Id "|" p.Name "|" p.Channel "|"
        for item in p.Items
            text .= item.Name "|" item.Text "|" ItemSlot(item) ";"
    }
    text .= "SHARED:"
    for item in library.SharedDanmakuItems
        text .= item.Name "|" item.Text "|" ItemSlot(item) ";"
    return text
}
CheckPerf(condition,message) {
    global PerfChecks
    PerfChecks++
    if !condition
        throw Error(message)
}
FixtureIsBrowser(hwnd) {
    return hwnd=123
}
FixtureResolveChannel(hwnd) {
    return {State:"ok",Channel:"/channel/a",Author:"A",Video:"fixture0000"}
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup 'RuntimePorts.BrowserIdentity := FixtureIsBrowser, RuntimePorts.ResolveChannel := FixtureResolveChannel'
