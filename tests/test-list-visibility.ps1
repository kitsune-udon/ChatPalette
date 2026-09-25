# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$tests = @'
AutoMode := false
ExecuteDanmakuCommand("add","","",{Name:"Visible",Text:"visible test",Slot:0})
ShowManagement(1)
AssertVisibleList("initial management display")
ShowManagement(2)
if DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd)
    throw Error("inactive tab leaked its list")
ManagementTabs.Choose(1)
AssertVisibleList("return after inactive tab refresh")
ShowManagement(3)
if DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd)
    throw Error("support tab leaked its list")
ShowManagement(1)
AssertVisibleList("return from support")
ReturnToPalette()
OpenPaletteLibrary()
AssertVisibleList("reopen from palette")
; An explicitly hidden control must still remain hidden after tab changes.
ManagedList.Visible := false
RefreshManagement()
ManagementTabs.Choose(2)
ManagementTabs.Choose(1)
if DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd)
    throw Error("explicitly hidden list became visible")
ManagedList.Visible := true
AssertVisibleList("explicit visibility restored")
RefreshPalette()
ShowPalette()
if !DllCall("IsWindowVisible","Ptr",PaletteList.Hwnd)
    throw Error("palette list became hidden")
FileAppend("PASS: management list remains visible across tabs and reopening`n","*")
ExitApp()
AssertVisibleList(label) {
    if ManagedList.GetCount()!=1
        throw Error(label ": list data missing")
    if !DllCall("IsWindowVisible","Ptr",ManagedList.Hwnd)
        throw Error(label ": populated list is hidden")
}
'@
Invoke-AppTest -Runtime $release -Body $tests
