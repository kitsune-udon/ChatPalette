# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$tests = @'
OnExit(StopBrowserWorker)
global ReorderChecks := 0
try {
    BuildManagement()
    for scope in ["shared","profile"] {
        id := scope="shared" ? "" : ExecuteProfileCommand("add","","fixture").ProfileId
        Loop 60
            ExecuteDanmakuCommand("add",id,0,{Name:Format("row{:02}",A_Index),Text:"text" A_Index,Slot:A_Index=40 ? 1 : 0})
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
        AssertReorder(InStr(ManagedList.GetText(39,3),scope="shared" ? "3" : "1"),"shortcut follows item")
        Loop 5
            HandleDanmakuCommand("up")
        AssertReorder(ManagedList.GetNext()=34 && ManagedList.GetText(34,1)="row40","repeated up moves same item")
        Loop 6
            HandleDanmakuCommand("down")
        AssertReorder(ManagedList.GetNext()=40 && ManagedList.GetText(40,1)="row40","repeated down restores original order")
        state := LoadSettings(SettingsDatabasePath)
        items := GetLibraryItems(state,id)
        AssertReorder(items[40].Name="row40" && ItemSlot(items[40])=1,"order and shortcut persisted")
        SelectManagedRow(1)
        AssertReorder(!ManagementItemButtons[5].Enabled && ManagementItemButtons[6].Enabled,"first row only moves down")
        history := LibraryHistory.Length
        HandleDanmakuCommand("up")
        AssertReorder(LibraryHistory.Length=history && ManagedList.GetNext()=1,"boundary creates no change")
        SelectManagedRow(60)
        AssertReorder(ManagementItemButtons[5].Enabled && !ManagementItemButtons[6].Enabled,"last row only moves up")
        HandleDanmakuCommand("up")
        UndoLibraryChange()
        AssertReorder(GetEditingDanmakuItems()[60].Name="row60","undo restores order")
    }
    FileAppend("PASS: " ReorderChecks " management reorder checks; no browser operations`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n","**")
    ExitApp(1)
}
AssertReorder(condition,message) {
    global ReorderChecks
    ReorderChecks++
    if !condition
        throw Error(message)
}
'@
Invoke-AppTest -Runtime $release -Body $tests
