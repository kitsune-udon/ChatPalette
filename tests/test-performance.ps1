# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

Copy-Item (Join-Path $PSScriptRoot 'fixtures\ui-message-probe.ahk') (Join-Path $release 'ui-message-probe.ahk')
$tests = @'
#Include %A_ScriptDir%\ui-message-probe.ahk
UiMessageProbe.Start()
a := ExecuteProfileCommand("add","","A","/channel/a").ProfileId
b := ExecuteProfileCommand("add","","B","/channel/b").ProfileId
ExecuteProfileCommand("add","","untouched","/channel/untouched")
for id in ["",a,b] {
    ExecuteDanmakuCommand("add",id,"",{Name:"first",Text:"first",Slot:1})
    ExecuteDanmakuCommand("add",id,"",{Name:"second",Text:"second",Slot:2})
}
for id in ["",a,b] {
    for action in ["edit","up","down","duplicate","delete","move"] {
        old := {Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems}
        signature := Fingerprint(old)
        history := LibraryHistory.Length
        itemId := GetLibraryItems(old,id)[action="up" ? 2 : 1].Id
        result := ExecuteDanmakuCommand(action,id,itemId,{Name:"changed",Text:"changed",Slot:2},id=b ? a : b)
        Assert(Fingerprint(old)==signature,"published history immutable: " id action)
        for oldProfile in old.Profiles {
            if oldProfile.Id == id || (action="move" && oldProfile.Id == (id=b ? a : b))
                continue
            Assert(FindProfileById(Profiles,oldProfile.Id)=oldProfile,"unchanged profile reused after item command: " id action)
        }
        UndoLibraryCommand()
        Assert(Fingerprint({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems})==signature,"undo restores data and slots: " id action)
        oldPath := SettingsDatabasePath, SettingsDatabasePath := A_ScriptDir "\missing\settings.db"
        failed := false
        try ExecuteDanmakuCommand(action,id,itemId,{Name:"changed",Text:"changed",Slot:2},id=b ? a : b)
        catch
            failed := true
        SettingsDatabasePath := oldPath
        Assert(failed && LibraryHistory.Length=history && Fingerprint(old)==signature
            && Fingerprint({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems})==signature,"failed command leaves history and live data unchanged: " id action)
    }
}
for action in ["rename","bind","unbind","delete"] {
    old := {Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems}, signature := Fingerprint(old)
    ExecuteProfileCommand(action,a,action="bind" ? "/channel/new" : "changed")
    Assert(Fingerprint(old)==signature,"profile metadata immutable: " action)
    for oldProfile in old.Profiles
        if !(oldProfile.Id == a)
            Assert(FindProfileById(Profiles,oldProfile.Id)=oldProfile,"other profiles reused after metadata command: " action)
    UndoLibraryCommand()
    Assert(Fingerprint({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems})==signature,"profile undo: " action)
}
external := CreateTestLibrarySnapshot()
CommitTestLibraryChange(external,"external draft")
external.SharedDanmakuItems[1].Text := "caller mutation"
external.Profiles[1].Name := "caller mutation"
Assert(SharedDanmakuItems[1].Text!="caller mutation" && Profiles[1].Name!="caller mutation","external draft remains detached")
item := SharedDanmakuItems[1], LibraryHistory := []
Loop 30
    ExecuteDanmakuCommand("down","",SharedDanmakuItems[1].Id)
for entry in LibraryHistory
    Assert(entry.SharedDanmakuItems[1]=item || entry.SharedDanmakuItems[2]=item,"unchanged item reused across history")
held := LibraryHistory[-1], signature := Fingerprint(held)
UndoLibraryCommand()
ExecuteDanmakuCommand("edit","",SharedDanmakuItems[1].Id,{Name:"branch",Text:"branch",Slot:2})
Assert(Fingerprint(held)==signature,"edit after undo does not mutate prior branch")
oldPath := SettingsDatabasePath, SettingsDatabasePath := A_ScriptDir "\missing\settings.db"
SaveReactionDefaults(CreateReactionOptions(DefaultReactionKind,DefaultReactionCount,DefaultReactionIntervalMs))
SaveAutoDetection(AutoMode)
Assert(true,"unchanged preferences skip file access")
failed := false
try SaveReactionDefaults(CreateReactionOptions(DefaultReactionKind=1 ? 2 : 1,DefaultReactionCount,DefaultReactionIntervalMs))
catch
    failed := true
Assert(failed,"changed preferences still save transactionally")
SettingsDatabasePath := oldPath
BuildManagement()
AutoMode := false, SharedDanmakuItems := []
Loop 60
    SharedDanmakuItems.Push({Id:NewRecordId(),Name:"row" A_Index,Text:"text" A_Index,Slot:0})
EditingProfileId := ""
ShowManagement(1)
SelectManagedRow(40)
Assert(ManagedList.GetNext()=40,"management selection is prepared before refresh: selected=" ManagedList.GetNext())
top := SendMessage(0x1027,0,0,ManagedList.Hwnd)
RefreshManagement()
Assert(ManagedList.GetNext()=40 && SendMessage(0x1027,0,0,ManagedList.Hwnd)=top,"management full refresh preserves selection and viewport: selected=" ManagedList.GetNext() " top=" top " actual=" SendMessage(0x1027,0,0,ManagedList.Hwnd))
RefreshPalette()
PaletteWindow.Hide()
prior := UiMessageProbe.Renders
RefreshVisiblePalette()
Assert(UiMessageProbe.Renders=prior,"hidden palette is not rebuilt")
ExecuteDanmakuCommand("edit","",SharedDanmakuItems[1].Id,{Name:"fresh",Text:"fresh",Slot:0})
ReturnToPalette()
Assert(PaletteRows[1].Text="fresh","return renders current data")
PaletteList.Modify(40,"Select Focus Vis")
Assert(PaletteList.GetNext()=40,"palette selection is prepared before refresh: selected=" PaletteList.GetNext())
top := SendMessage(0x1027,0,0,PaletteList.Hwnd)
RefreshPalette()
Assert(PaletteList.GetNext()=40 && SendMessage(0x1027,0,0,PaletteList.Hwnd)=top && PaletteProfile.Enabled,"manual palette refresh preserves selection, viewport and profile choice")
PaletteSearch.Value := "text60"
RefreshPaletteItems()
Assert(PaletteRows.Length=1 && PaletteRows[1].Text="text60" && PaletteList.GetNext()=1,"search selection remains valid")
AutoMode := true, TargetBrowserHwnd := 123
prior := UiMessageProbe.Renders
RefreshPaletteForTarget()
Assert(UiMessageProbe.Renders=prior+1 && !PaletteProfile.Enabled,"detection renders exactly once and disables manual profile choice")
RefreshOperationControls()
writes := UiMessageProbe.Writes
Loop 20
    RefreshOperationControls()
Assert(UiMessageProbe.Writes=writes,"unchanged palette controls and preview perform zero native property writes")
IsBrowserOperationBusy := true
RefreshOperationControls()
Assert(UiMessageProbe.Writes>writes && !PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"changed state still updates native controls")
IsBrowserOperationBusy := false
RefreshOperationControls()
Assert(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"controls recover after busy state")
FileAppend("PASS: " Checks " performance regression checks`n","*")
ExitApp()
Fingerprint(library) {
    text := ""
    for p in library.Profiles {
        text .= p.Id "|" p.Name "|" p.Channel "|"
        for item in p.Items
            text .= item.Name "|" item.Text "|" item.Slot ";"
    }
    text .= "SHARED:"
    for item in library.SharedDanmakuItems
        text .= item.Name "|" item.Text "|" item.Slot ";"
    return text
}
FixtureIsBrowser(hwnd) {
    return hwnd=123
}
FixtureResolveChannel(hwnd) {
    return {State:"ok",Channel:"/channel/a",Author:"A",Video:"fixture0000"}
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup 'RuntimePorts.BrowserIdentity := FixtureIsBrowser, RuntimePorts.ResolveChannel := FixtureResolveChannel'

# Each initial tab gets a fresh application; count complete management renders.
foreach ($page in @(1,2,3)) {
    $initialRuntime=New-TestRuntime
    Edit-TestSource $initialRuntime 'src/ui/management/management_view.ahk' 'RenderManagement() {' ("RenderManagement() {`r`n    CountManagementRender()")
    $initialTests=@'
global ManagementRenders := 0
AutoMode := false
Loop 3
    ExecuteDanmakuCommand("add","","",{Name:"item" A_Index,Text:"body" A_Index,Slot:0})
firstPage := INITIAL_PAGE
ShowManagement(firstPage)
Assert(ManagementRenders=1,"first display renders management once; actual=" ManagementRenders)
Assert(ManagementTabs.Value=firstPage && DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd),"first display opens the requested tab")
Assert(ManagedList.GetCount()=3 && ManagedList.GetText(3,4)==SharedDanmakuItems[3].Id,"first display contains the complete current library")
ManagementTabs.Choose(1)
Assert(DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd) && ManagementItemButtons[2].Enabled
    && !ManagementItemButtons[5].Enabled && ManagementItemButtons[6].Enabled,"first display prepares visible selection and edit/move actions")
SelectManagedRow(3)
selected := ManagedList.GetText(3,4)
ManagementWindow.Hide()
ExecuteDanmakuCommand("edit","",SharedDanmakuItems[2].Id,{Name:"updated",Text:"updated body",Slot:0})
ExecuteDanmakuCommand("add","","",{Name:"new item",Text:"new body",Slot:0})
ShowManagement(Mod(firstPage,3)+1)
Assert(ManagementRenders=2,"reopening performs one fresh render")
ManagementTabs.Choose(1)
Assert(ManagedList.GetCount()=4 && ManagedList.GetText(2,1)="updated" && ManagedList.GetText(4,2)="new body","reopening reflects changes made while hidden")
Assert(ManagedList.GetNext()=3 && ManagedList.GetText(3,4)==selected && ManagementItemButtons[5].Enabled && ManagementItemButtons[6].Enabled,"reopening preserves selected identity and refreshes move actions")
Sleep(30)
Assert(ManagementRenders=2,"initial and reopened displays leave no redundant deferred render")
SharedDanmakuItems := [SharedDanmakuItems[4],SharedDanmakuItems[3]]
RefreshManagement()
Assert(ManagedList.GetCount()=2 && ManagedList.GetText(1,4)==SharedDanmakuItems[1].Id,"shrinking removes trailing rows and replaces the first row")
Assert(ManagedList.GetNext()=2 && ManagedList.GetText(2,4)==selected,"selection follows identity after shrinking and reordering")
SharedDanmakuItems := [{Id:"case-id",Name:"replacement",Text:"replacement body",Slot:1},{Id:"CASE-ID",Name:"other",Text:"other body",Slot:0}]
ShortcutKeys["shared1"] := "^+F8"
RefreshManagement()
Assert(ManagedList.GetCount()=2 && ManagedList.GetText(1,1)="replacement" && ManagedList.GetText(1,2)="replacement body"
    && ManagedList.GetText(1,3)="Ctrl+Shift+F8" && ManagedList.GetText(1,4)=="case-id","same-size replacement updates every column")
Assert(ManagedList.GetNext()=1,"removed selection falls back to the first current row")
SelectManagedRow(2)
SharedDanmakuItems := [SharedDanmakuItems[2],SharedDanmakuItems[1]]
RefreshManagement()
Assert(ManagedList.GetNext()=1 && ManagedList.GetText(1,4)=="CASE-ID","reused rows restore identity with case-sensitive matching")
Assert(ManagedList.GetText(1,3)="" && ManagedList.GetText(2,3)="Ctrl+Shift+F8","rewriting rows clears obsolete shortcut labels")
retained := SharedDanmakuItems.Clone()
Loop 6
    SharedDanmakuItems.Push({Id:"extra-" A_Index,Name:"extra",Text:"extra body",Slot:0})
RefreshManagement()
SelectManagedRow(2)
ManagementTabs.Choose(2)
SharedDanmakuItems := retained
RefreshManagement()
Assert(ManagedList.GetCount()=2 && !DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd),"large reduction removes excess rows while keeping the inactive tab hidden")
ManagementTabs.Choose(1)
Assert(ManagedList.GetNext()=2 && ManagedList.GetText(2,4)=="case-id" && ManagedList.GetText(2,3)="Ctrl+Shift+F8"
    && DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd),"large reduction preserves identity, columns and visibility on return")
SharedDanmakuItems := []
RefreshManagement()
Assert(ManagedList.GetCount()=0 && ManagedList.GetNext()=0 && !ManagementItemButtons[2].Enabled,"empty library clears all rows, selection and edit action")
SharedDanmakuItems := [{Id:"after-empty",Name:"restored",Text:"restored body",Slot:0}]
RefreshManagement()
Assert(ManagedList.GetCount()=1 && ManagedList.GetText(1,4)=="after-empty" && ManagedList.GetNext()=1
    && ManagementItemButtons[2].Enabled,"empty list can grow again with valid selection and actions")
FileAppend("PASS: " Checks " management display checks for initial tab " firstPage "`n","*")
ExitApp()
CountManagementRender() {
    global ManagementRenders
    ManagementRenders++
}
'@
    Invoke-AppTest -Runtime $initialRuntime -Body $initialTests.Replace('INITIAL_PAGE',[string]$page)
}
