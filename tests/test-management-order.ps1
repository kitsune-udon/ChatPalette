# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$viewPath=Join-Path $release 'src\ui\management\management_view.ahk'
$viewSource=[IO.File]::ReadAllText($viewPath)
$anchor='    rows := [BuildPresentationRow(items[previous],previous,id,ShortcutKeys), BuildPresentationRow(items[current],current,id,ShortcutKeys)]'
if (!$viewSource.Contains($anchor)) { throw 'Missing partial update boundary' }
[IO.File]::WriteAllText($viewPath,$viewSource.Replace($anchor,$anchor+"`r`n    ProbePartialUpdate()"),[Text.UTF8Encoding]::new($true))

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$tests = @'
OnExit(StopBrowserWorker)
global ReorderChecks := 0, PartialArmed := false, PartialFailure := false, PartialProbes := 0, PartialGuarded := false
BuildManagement()
for scope in ["shared","profile"] {
    id := scope="shared" ? "" : ExecuteProfileCommand("add","","fixture").ProfileId
    Loop 60
        ExecuteDanmakuCommand("add",id,"",{Name:Format("row{:02}",A_Index),Text:"text" A_Index,Slot:A_Index=40 ? 1 : 0})
    keys := CurrentShortcutMap()
    keys[scope "1"] := scope="shared" ? "^+F8" : "^+F9"
    SaveShortcutMap(keys)
    expectedKey := scope="shared" ? "Ctrl+Shift+F8" : "Ctrl+Shift+F9"
    EditingProfileId := id
    ShowManagement(1)
    SelectManagedRow(40)
    SendMessage(0x1013,34,0,ManagedList.Hwnd) ; Ensure the upper neighbour is visible too.
    AssertReorder(WinGetStyle("ahk_id " ManagedList.Hwnd) & 0x8000,"column sorting disabled")
    ManagementItemButtons[5].Focus()
    topBefore := SendMessage(0x1027,0,0,ManagedList.Hwnd)
    HandleDanmakuCommand("up")
    AssertReorder(ManagedList.GetNext()=39 && ManagedList.GetText(39,1)="row40","selection follows moved item")
    AssertReorder(ManagedList.GetText(40,1)="row39","adjacent row exchanged")
    AssertReorder(SendMessage(0x1027,0,0,ManagedList.Hwnd)=topBefore,"viewport retained for visible move")
    AssertReorder(DllCall("GetFocus","Ptr")=ManagementItemButtons[5].Hwnd,"move button keeps focus")
    AssertReorder(ManagedList.GetText(39,3)==expectedKey,"configured shortcut follows the moved item")
    partial := []
    for index in [39,40]
        partial.Push([ManagedList.GetText(index,1),ManagedList.GetText(index,2),ManagedList.GetText(index,3),ManagedList.GetText(index,4)])
    RefreshManagement()
    for i, row in partial
        for column, value in row
            AssertReorder(ManagedList.GetText(38+i,column)==value,"partial reorder and full refresh agree: " scope "/" i "/" column)
    Loop 5
        HandleDanmakuCommand("up")
    AssertReorder(ManagedList.GetNext()=34 && ManagedList.GetText(34,1)="row40","repeated up moves same item")
    Loop 6
        HandleDanmakuCommand("down")
    AssertReorder(ManagedList.GetNext()=40 && ManagedList.GetText(40,1)="row40","repeated down restores original order")
    state := LoadSettings(SettingsDatabasePath)
    items := GetLibraryItems(state,id)
    AssertReorder(items[40].Name="row40" && items[40].Slot=1,"order and shortcut persisted")
    SelectManagedRow(1)
    AssertReorder(!ManagementItemButtons[5].Enabled && ManagementItemButtons[6].Enabled,"first row only moves down")
    history := LibraryHistory.Length
    HandleDanmakuCommand("up")
    AssertReorder(LibraryHistory.Length=history && ManagedList.GetNext()=1,"boundary creates no change")
    SelectManagedRow(60)
    AssertReorder(ManagementItemButtons[5].Enabled && !ManagementItemButtons[6].Enabled,"last row only moves up")
    HandleDanmakuCommand("up")
    UndoLibraryChange()
    AssertReorder(GetLibraryItems({Profiles:Profiles,SharedDanmakuItems:SharedDanmakuItems},id)[60].Name="row60","undo restores order")
}
; A partial update has the same owner, recovery and tab visibility as a full refresh.
for fails in [false,true] {
    ShowManagement(1)
    SelectManagedRow(40)
    moved := GetSelectedManagedTarget().Item.Id
    PartialFailure := fails, PartialProbes := 0, PartialArmed := true
    previousCritical := A_IsCritical
    Critical("On")
    try {
        HandleDanmakuCommand("up")
        AssertReorder(PartialProbes=1 && PartialGuarded && !ManagementRefresh.Active,"partial update releases ownership after reentry or failure")
        AssertReorder(!DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd),"partial update preserves the inactive tab before queued repair")
        if fails
            AssertReorder(InStr(ManagementStatus.Text,"保存済み") && InStr(ManagementStatus.Text,"partial render failure"),"partial rendering failure preserves the committed outcome")
        AssertReorder(GetLibraryItems(LoadSettings(SettingsDatabasePath),id)[39].Id==moved,"partial rendering never rolls back or repeats the saved reorder")
    } finally Critical(previousCritical)
    Sleep(150)
    AssertReorder(!ManagementRefresh.Active && !DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd),"queued refresh preserves the inactive tab")
    ManagementTabs.Choose(1)
    AssertReorder(DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd) && ManagedList.GetText(39,4)==moved,"queued refresh repairs rows before the tab reopens")
    UndoLibraryChange()
}
FileAppend("PASS: " ReorderChecks " management reorder checks; no browser operations`n","*")
ExitApp()
ProbePartialUpdate() {
    global PartialArmed, PartialProbes, PartialGuarded
    if !PartialArmed
        return
    PartialArmed := false, PartialProbes++, PartialGuarded := ManagementRefresh.Active
    AssertReorder(ManagementRefresh.Active && !OperationAllowed("edit") && !OperationAllowed("input") && !OperationAllowed("reaction"),"partial update holds the common operation guard")
    RefreshManagement()
    AssertReorder(ManagementRefresh.Pending,"nested partial-update refresh is coalesced")
    ManagementTabs.Choose(2)
    if PartialFailure
        throw Error("partial render failure")
}
AssertReorder(condition,message) {
    global ReorderChecks
    ReorderChecks++
    if !condition
        throw Error(message)
}
'@
Invoke-AppTest -Runtime $release -Body $tests
