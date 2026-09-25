# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$tests = @'
OnExit(StopBrowserWorker)
global ReturnChecks := 0, ResolveCalls := 0
global TestChannel := {State:"ok",Channel:"/channel/return",Author:"Return",Video:"abcdefghijk"}
BuildManagement()
TargetBrowserHwnd := 123, AutoMode := true
old := ExecuteProfileCommand("add","","Previous","/channel/previous")
SaveInputProfileId(old.ProfileId)
SelectProfileFromBrowser(TargetBrowserHwnd)
added := ExecuteProfileCommand("add","","Linked","/channel/return")
ExecuteDanmakuCommand("add",added.ProfileId,"",{Name:"New",Text:"new danmaku",Slot:1})
RefreshManagementAfterCommand(added.ProfileId)
AssertReturn(GetInputProfile().Id=old.ProfileId,"editing does not change input selection")
countBefore := PaletteCount.Value
ReturnToPalette()
AssertReturn(GetInputProfile().Id=added.ProfileId,"return resolves new channel association")
AssertReturn(PaletteRows.Length=1 && PaletteRows[1].Text="new danmaku","new danmaku visible on return")
AssertReturn(PaletteCount.Value=countBefore,"session reaction options retained")
TestChannel := {State:"ok",Channel:"/channel/previous",Author:"Previous",Video:"bbbbbbbbbbb"}
ReturnToPalette()
AssertReturn(GetInputProfile().Id=old.ProfileId && PaletteRows.Length=0,"video change uses current channel")
TestChannel := {State:"unavailable",Channel:"",Author:"",Video:""}
ReturnToPalette()
AssertReturn(PaletteRows.Length=0 && InStr(PaletteContext.Text,"共通の弾幕のみ"),"failed detection never shows stale profile")
AutoMode := false
before := ResolveCalls
SaveInputProfileId(added.ProfileId)
PaletteSearch.Value := "new"
ReturnToPalette()
AssertReturn(ResolveCalls=before && GetInputProfile().Id=added.ProfileId,"manual selection is preserved without detection")
AssertReturn(PaletteSearch.Value="new" && PaletteRows.Length=1,"search is preserved")
PaletteSearch.Value := ""
for scenario in ["linked-auto","unlinked-auto","failed-auto","unlinked-manual"] {
    channel := "/channel/" scenario
    entry := ExecuteProfileCommand("add","",scenario,scenario="linked-auto" ? channel : "")
    AutoMode := scenario!="unlinked-manual"
    SaveInputProfileId(entry.ProfileId)
    TestChannel := {State:scenario="failed-auto" ? "unavailable" : "ok",Channel:channel,Author:scenario,Video:"abcdefghijk"}
    visible := scenario="linked-auto" || scenario="unlinked-manual"
    for scope in ["",entry.ProfileId] {
        prefix := scenario (scope="" ? "-shared" : "-profile")
        expectedVisible := scope="" || visible
        first := ExecuteDanmakuCommand("add",scope,"",{Name:prefix,Text:prefix "-added",Slot:0})
        itemId := (scope="" ? SharedDanmakuItems : FindProfileById(Profiles,scope).Items)[first.Index].Id
        ReturnToPalette()
        AssertReturn(HasReturnRow(prefix "-added")=expectedVisible,"add refresh: " prefix)
        ExecuteDanmakuCommand("edit",scope,itemId,{Name:prefix " renamed",Text:prefix "-edited",Slot:2})
        ReturnToPalette()
        AssertReturn(!HasReturnRow(prefix "-added") && HasReturnRow(prefix "-edited")=expectedVisible,"edit refresh: " prefix)
        if expectedVisible {
            for rowIndex,row in PaletteRows
                if row.Text=prefix "-edited" {
                    AssertReturn(InStr(PaletteList.GetText(rowIndex,2),"renamed"),"updated display name: " prefix)
                    AssertReturn(InStr(PaletteList.GetText(rowIndex,3),scope="" ? "4" : "2"),"updated shortcut: " prefix)
                }
        }
        ExecuteDanmakuCommand("delete",scope,itemId)
        ReturnToPalette()
        AssertReturn(!HasReturnRow(prefix "-edited"),"delete refresh: " prefix)
        UndoLibraryCommand()
        ReturnToPalette()
        AssertReturn(HasReturnRow(prefix "-edited")=expectedVisible,"undo refresh: " prefix)
    }
}
; Manual input selection is independent of an unrelated editing target.
AutoMode := false
SaveInputProfileId(entry.ProfileId)
ExecuteProfileCommand("rename",entry.ProfileId,"Renamed input profile")
ReturnToPalette()
AssertReturn(InStr(PaletteContext.Text,"Renamed input profile"),"profile rename refresh")
EditingProfileId := old.ProfileId
ReturnToPalette()
AssertReturn(GetInputProfile().Id=entry.ProfileId,"editing another profile does not switch input")
ExecuteProfileCommand("delete",entry.ProfileId)
ReturnToPalette()
AssertReturn(!GetInputProfile() && InStr(PaletteContext.Text,"共通の弾幕のみ"),"deleted input profile is not displayed")
; Palette editing follows the selected row, including filtered lists.
PaletteSearch.Value := "", AutoMode := false
editProfile := ExecuteProfileCommand("add","","Edit target")
ExecuteDanmakuCommand("add",editProfile.ProfileId,"",{Name:"One",Text:"profile-first",Slot:0})
ExecuteDanmakuCommand("add",editProfile.ProfileId,"",{Name:"Two",Text:"profile-second",Slot:0})
SaveInputProfileId(editProfile.ProfileId)
RefreshPalette()
PaletteList.Modify(0,"-Select")
PaletteList.Modify(2,"Select")
OpenPaletteLibrary()
AssertReturn((GetEditingProfileId() != "") && GetEditingProfileId()=editProfile.ProfileId && ManagedList.GetNext()=2,"selected profile row opens correct editor target and item")
AssertReturn(ManagementItemButtons[5].Enabled && !ManagementItemButtons[6].Enabled,"palette last row only moves up")
RefreshPalette()
PaletteList.Modify(0,"-Select")
PaletteList.Modify(3,"Select")
OpenPaletteLibrary()
AssertReturn((GetEditingProfileId() = "") && ManagedList.GetNext()=1,"selected shared row opens shared editor")
AssertReturn(GetInputProfile().Id=editProfile.ProfileId,"opening shared editor preserves input profile")
PaletteSearch.Value := "profile-second"
RefreshPalette()
OpenPaletteLibrary()
AssertReturn(GetEditingProfileId()=editProfile.ProfileId && ManagedList.GetNext()=2,"filtered row maps to original item")
PaletteSearch.Value := "no-match"
RefreshPalette()
OpenPaletteLibrary()
AssertReturn(GetEditingProfileId()=editProfile.ProfileId,"empty search falls back to manual input target")
AutoMode := true
TestChannel := {State:"ok",Channel:"/channel/unlinked-editor",Author:"Unlinked",Video:"abcdefghijk"}
SelectProfileFromBrowser(TargetBrowserHwnd)
RefreshPalette()
OpenPaletteLibrary()
AssertReturn((GetEditingProfileId() = ""),"unlinked automatic target falls back to shared")
ExecuteProfileCommand("bind",editProfile.ProfileId,TestChannel.Channel)
SelectProfileFromBrowser(TargetBrowserHwnd)
RefreshPalette()
OpenPaletteLibrary()
AssertReturn(GetEditingProfileId()=editProfile.ProfileId,"linked automatic target used when no row selected")
PaletteSearch.Value := "profile-first"
RefreshPalette()
for hwnd in [0,999] {
    TargetBrowserHwnd := hwnd
    AssertReturn(GetPaletteLibraryTarget().ProfileId="","stale selected row cannot select editor")
    ReturnToPalette()
    AssertReturn(DetectedChannel.State!="ok" && !HasReturnRow("profile-first"),"missing/closed browser clears detection and profile rows")
    AssertReturn(GetPaletteLibraryTarget().ProfileId="","missing browser uses shared editor")
    AutoMode := false
    ReturnToPalette()
    AssertReturn(HasReturnRow("profile-first") && GetInputProfile().Id=editProfile.ProfileId,"manual profile retained without browser")
    AutoMode := true, TargetBrowserHwnd := 123
    ReturnToPalette()
}
ExecuteProfileCommand("delete",editProfile.ProfileId)
OpenPaletteLibrary()
AssertReturn((GetEditingProfileId() = ""),"deleted selected profile is not reused")
; Reopening from the palette must refresh actions synchronously for either scope.
AutoMode := false, PaletteSearch.Value := ""
buttonProfile := ExecuteProfileCommand("add","","Button states")
SaveInputProfileId(buttonProfile.ProfileId)
for scope in ["",buttonProfile.ProfileId] {
    Loop 3
        ExecuteDanmakuCommand("add",scope,"",{Name:"button" A_Index,Text:"button-" scope "-" A_Index,Slot:0})
    count := (scope="" ? SharedDanmakuItems : Profiles[FindProfileIndexById(Profiles,scope)].Items).Length
    for selected in [count,1,2,count,1] {
        ReturnToPalette()
        PaletteList.Modify(0,"-Select")
        for rowIndex,row in PaletteRows
            if row.ProfileId=scope && row.Index=selected {
                PaletteList.Modify(rowIndex,"Select Focus")
                break
            }
        OpenPaletteLibrary()
        AssertReturn(ManagedList.GetNext()=selected,"palette restores requested row")
        AssertReturn(ManagementItemButtons[5].Enabled=(selected>1),"up follows palette selection")
        AssertReturn(ManagementItemButtons[6].Enabled=(selected<count),"down follows palette selection")
        Sleep(-1)
        AssertReturn(ManagementItemButtons[5].Enabled=(selected>1) && ManagementItemButtons[6].Enabled=(selected<count),"deferred events preserve action states")
    }
}
emptyProfile := ExecuteProfileCommand("add","","Empty buttons")
SaveInputProfileId(emptyProfile.ProfileId)
ReturnToPalette()
PaletteList.Modify(0,"-Select")
OpenPaletteLibrary()
AssertReturn(!ManagedList.GetCount() && !ManagementItemButtons[5].Enabled && !ManagementItemButtons[6].Enabled,"empty library disables both moves")
for button in [2,3,4,7]
    AssertReturn(!ManagementItemButtons[button].Enabled,"empty library disables selected-item commands")
ExecuteDanmakuCommand("add",emptyProfile.ProfileId,"",{Name:"Only",Text:"only-button-item",Slot:0})
PaletteSearch.Value := "only-button-item"
ReturnToPalette()
OpenPaletteLibrary()
AssertReturn(ManagedList.GetNext()=1 && !ManagementItemButtons[5].Enabled && !ManagementItemButtons[6].Enabled,"single item disables both moves")
FileAppend("PASS: " ReturnChecks " palette return checks; no browser operations`n","*")
ExitApp()
HasReturnRow(text) {
    for row in PaletteRows
        if row.Text=text
            return true
    return false
}
AssertReturn(value,label) {
    global ReturnChecks
    ReturnChecks++
    if !value
        throw Error(label)
}
FixtureResolveChannel(hwnd) {
    global ResolveCalls
    ResolveCalls++
    return TestChannel
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup @'
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
RuntimePorts.ResolveChannel := FixtureResolveChannel
'@


$navigationRuntime=New-TestRuntime
$navigationTests=@'
OnExit(StopBrowserWorker)
BuildManagement()
global NavigationChecks := 0, NavigationRequests := 0, NavigationRestarts := 0
browser := Gui(,"isolated page operation target")
browser.AddEdit("w240","page operation fixture")
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=browser.Hwnd
RuntimePorts.ResolveChannel := NavigationResolve
RuntimePorts.Restart := NavigationRestart
AutoMode := true
try {
    for entry in [ShowPalette,ReturnToPalette,LoadDefaultsAndReturn] {
        for phase in ["focus_wait","page_finish","ipc"] {
            PaletteWindow.Hide()
            ManagementWindow.Show("w760 h660 NA")
            browser.Show("w280 h120")
            WinActivate("ahk_id " browser.Hwnd)
            WinWaitActive("ahk_id " browser.Hwnd,,2)
            TargetBrowserHwnd := browser.Hwnd
            PaletteChoice.Choose(2), PaletteCount.Choose(3), PaletteInterval.Choose(2)
            calls := NavigationRequests, restarts := NavigationRestarts
            owner := phase="ipc" ? 0 : {Window:browser.Hwnd,Pending:0,AcceptsPending:phase="focus_wait"}
            ActivePageAction := owner, IsBrowserOperationBusy := phase="ipc"
            entry.Call()
            label := entry.Name "/" phase
            CheckNavigation(NavigationRequests=calls && TargetBrowserHwnd=browser.Hwnd,"busy navigation never re-resolves or changes the target: " label)
            CheckNavigation(!DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd) && WinActive("ahk_id " browser.Hwnd),"busy navigation preserves foreground and both panels: " label)
            CheckNavigation(PaletteChoice.Value=2 && PaletteCount.Value=3 && PaletteInterval.Value=2,"busy defaults-return cannot reset the session: " label)
            CheckNavigation(!RestartApplication() && NavigationRestarts=restarts && ActivePageAction=owner,"restart and navigation preserve the current owner: " label)
            ActivePageAction := 0, IsBrowserOperationBusy := false
            entry.Call()
            CheckNavigation(NavigationRequests=calls+1 && DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd),"navigation resumes normally after ownership ends: " label)
            CheckNavigation(entry=LoadDefaultsAndReturn ? PaletteChoice.Value=DefaultReactionKind && ReactionCounts[PaletteCount.Value]=DefaultReactionCount && ReactionIntervals[PaletteInterval.Value]=DefaultReactionIntervalMs
                : PaletteChoice.Value=2 && PaletteCount.Value=3 && PaletteInterval.Value=2,"only explicit defaults-return changes session choices: " label)
        }
    }
    ; Returning during a reaction may still show its palette, without another browser lookup.
    calls := NavigationRequests
    job := CreateReactionJob({Mode:"reaction_send",Window:browser.Hwnd})
    ActiveReactionJob := job
    ReturnToPalette()
    CheckNavigation(ActiveReactionJob=job && NavigationRequests=calls,"reaction return retains its job and skips browser resolution")
    FinishReactionJob(job)
} finally {
    ActivePageAction := 0, IsBrowserOperationBusy := false
    RuntimePorts.Restart := 0
    browser.Destroy()
}
FileAppend("PASS: " NavigationChecks " navigation ownership checks; isolated window only`n","*")
ExitApp()
CheckNavigation(value,label) {
    global NavigationChecks
    if !value
        throw Error(label)
    NavigationChecks++
}
NavigationResolve(hwnd) {
    global NavigationRequests
    NavigationRequests++
    return {State:"ok",Channel:"/channel/fixture",Author:"fixture",Video:"abcdefghijk"}
}
NavigationRestart() {
    global NavigationRestarts
    NavigationRestarts++
}
'@
Invoke-AppTest -Runtime $navigationRuntime -Body $navigationTests
