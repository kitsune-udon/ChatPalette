# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
$tests=@'
global ViewChecks := 0
global DeletedViewports := 0
for useLayout in [false,true] {
    lifetimeView := Gui(,"viewport lifetime fixture")
    lifetimeView.AddText("w100","fixture")
    viewport := LifetimeViewport(lifetimeView,160,120,useLayout ? (*) => 0 : 0)
    viewport.Dispose()
    viewport.Dispose()
    viewport := 0
    AssertView(DeletedViewports=(useLayout ? 2 : 1),"disposed viewport releases its callbacks while the host window remains alive")
    AssertView(DllCall("IsWindow","Ptr",lifetimeView.Hwnd),"viewport disposal preserves its externally owned window")
    lifetimeView.Destroy()
}
global FailedViewport := 0
failureView := Gui(,"failed viewport fixture")
failed := false
try FaultedViewport(failureView,160,120)
catch as failure {
    failed := failure.Message == "fixture viewport capture failure"
    if !failed
        throw failure
}
AssertView(failed && FailedViewport.Disposed,"failed viewport construction disposes callbacks before publication")
FailedViewport := 0
AssertView(DeletedViewports=3,"failed construction releases its last reference")
AssertView(DllCall("IsWindow","Ptr",failureView.Hwnd),"failed viewport construction preserves its externally owned window")
failureView.Destroy()
AutoMode := false
ShowPalette()
PresentWindow(PaletteWindow,"w260 h300",ResizePalette)
AssertView(PaletteViewport.MaxX>0 && PaletteViewport.MaxY>0,"small palette scrolls both axes")
PaletteReset.Focus()
Sleep(80)
AssertVisible(PaletteReset,PaletteWindow)
PresentWindow(PaletteWindow,"w560 h740",ResizePalette)
AssertView(PaletteViewport.X=0 && PaletteViewport.Y=0 && PaletteViewport.MaxX=0 && PaletteViewport.MaxY=0,"larger palette clears obsolete scroll offsets")
ExecuteDanmakuCommand("add","","",{Name:"test",Text:"test",Slot:0})
ShowManagement(1)
PresentWindow(ManagementWindow,"w260 h300",ResizeManagement)
AssertView(ManagementViewport.MaxX>0 && ManagementViewport.MaxY>0,"small manager scrolls both axes")
for pair in [[1,ManagementUndo],[2,ReactionLoadButton],[3,ManagementSupportButtons["diagnostics"]]] {
    ManagementTabs.Choose(pair[1])
    pair[2].Focus()
    Sleep(80)
    AssertVisible(pair[2],ManagementWindow)
}
PresentWindow(ManagementWindow,"w760 h660",ResizeManagement)
AssertView(ManagementViewport.MaxX=0 && ManagementViewport.MaxY=0,"large manager needs no scrollbars")
ManagementTitle.GetPos(&x,&y)
AssertView(x=28 && y=48,"scrolling and reflow do not accumulate coordinate drift")
ManagementWindow.Hide()
SetReactionStatus("progress one",false)
SetReactionStatus("progress two",false)
AssertView(ReactionExecutionStatus.Message="progress two","progress accounting remains immediate")
Sleep(150)
AssertView(PaletteStatusControl.Text="progress two","throttled rendering eventually displays latest state")
SetReactionStatus("progress three",false)
SetReactionStatus("finished immediately",true)
AssertView(PaletteStatusControl.Text="finished immediately","final status bypasses throttling")
Sleep(150)
AssertView(PaletteStatusControl.Text="finished immediately","pending refresh cannot restore stale progress")
probe := Gui(,"Work area test")
probe.AddText("w160","test")
PresentWindow(probe,"w200 h100")
WinMove(-5000,-5000,,,"ahk_id " probe.Hwnd)
ShowFittedWindow(probe,200,100)
rect := Buffer(16), info := Buffer(40,0)
NumPut("UInt",40,info)
monitor := DllCall("MonitorFromWindow","Ptr",probe.Hwnd,"UInt",2,"Ptr")
DllCall("GetMonitorInfoW","Ptr",monitor,"Ptr",info)
DllCall("GetWindowRect","Ptr",probe.Hwnd,"Ptr",rect)
AssertView(NumGet(rect,0,"Int")>=NumGet(info,20,"Int") && NumGet(rect,4,"Int")>=NumGet(info,24,"Int") && NumGet(rect,8,"Int")<=NumGet(info,28,"Int") && NumGet(rect,12,"Int")<=NumGet(info,32,"Int"),"all edges fit recovered work area")
probe.Destroy()
PresentWindow(PaletteWindow,"w260 h300",ResizePalette)
; Establish an observed control before changing focus; a timer during setup must
; not turn the target into an already-observed control before the layout test.
previousCritical := A_IsCritical
Critical("On")
try {
    SetTimer(PaletteViewport.FocusHandler,0)
    PaletteSearch.Focus()
    PaletteViewport.FollowFocus()
    PaletteReset.Focus()
    PaletteViewport.SetOffset(0,0)
    PaletteViewport.Updating := true
    PaletteViewport.FollowFocus()
    AssertView(PaletteViewport.Y=0,"focus sampling does not move controls during layout")
    PaletteViewport.FollowFocus()
    AssertView(PaletteViewport.Y=0,"focus waits for layout completion")
    PaletteViewport.Updating := false
    SetTimer(PaletteViewport.FocusHandler,50)
} finally Critical(previousCritical)
Sleep(80)
AssertVisible(PaletteReset,PaletteWindow)
; A newly focused control supersedes positions queued before its focus was observed.
for scenario in ["reveal","already-visible"] {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        SetTimer(PaletteViewport.FocusHandler,0)
        PaletteSearch.Focus()
        PaletteViewport.FollowFocus()
        target := scenario="reveal" ? PaletteReset : PaletteInterval
        if scenario="already-visible" {
            PaletteReset.Focus()
            PaletteViewport.FollowFocus()
            AssertVisible(target,PaletteWindow)
        }
        PaletteViewport.Updating := true
        PaletteViewport.SetOffset(0,0)
        PaletteViewport.Updating := false
        beforeX := PaletteViewport.X, beforeY := PaletteViewport.Y
        target.Focus()
        PaletteViewport.FollowFocus()
        if scenario="already-visible"
            AssertView(PaletteViewport.X=beforeX && PaletteViewport.Y=beforeY,"visible new focus needs no movement but still supersedes old scrolling")
        AssertVisible(target,PaletteWindow)
        PaletteViewport.FlushUpdates()
        AssertVisible(target,PaletteWindow)
    } finally {
        SetTimer(PaletteViewport.FocusHandler,50)
        Critical(previousCritical)
    }
}
Loop 20 {
    PresentWindow(PaletteWindow,"w260 h300",ResizePalette)
    PaletteSearch.Focus()
    PaletteReset.Focus()
    PaletteViewport.Resize()
    Sleep(15)
    for record in PaletteViewport.Children
        AssertView(Type(record)="Buffer" && record.Size=A_PtrSize+8 && DllCall("IsWindow","Ptr",NumGet(record,0,"Ptr")),"coordinate snapshot complete under focus and resize")
}
PaletteViewport.SetOffset(0,0)
PaletteSearch.Focus()
SetTimer(PaletteViewport.FocusHandler,0)
PaletteViewport.FollowFocus()
PaletteViewport.FollowFocus()
AssertView(PaletteViewport.Y=0,"sampling uses the current focused control")
SetTimer(PaletteViewport.FocusHandler,50)
PaletteViewport.Dispose()
AssertView(PaletteViewport.LastFocus=0 && PaletteViewport.Disposed,"dispose clears focus tracking")
Sleep(30)
FileAppend("PASS: " ViewChecks " viewport and progress checks; no browser operations`n","*")
ExitApp(0)
class LifetimeViewport extends PanelViewport {
    __Delete() {
        global DeletedViewports
        DeletedViewports++
    }
}
class FaultedViewport extends LifetimeViewport {
    CaptureChildren() {
        global FailedViewport := this
        throw Error("fixture viewport capture failure")
    }
}
AssertView(value,label) {
    global ViewChecks
    if !value
        throw Error(label)
    ViewChecks++
}
AssertVisible(control,view) {
    rect := Buffer(16), client := Buffer(16)
    DllCall("GetWindowRect","Ptr",control.Hwnd,"Ptr",rect)
    DllCall("MapWindowPoints","Ptr",0,"Ptr",view.Hwnd,"Ptr",rect,"UInt",2)
    DllCall("GetClientRect","Ptr",view.Hwnd,"Ptr",client)
    deadline := A_TickCount+1000
    while A_TickCount < deadline {
        DllCall("GetWindowRect","Ptr",control.Hwnd,"Ptr",rect)
        DllCall("MapWindowPoints","Ptr",0,"Ptr",view.Hwnd,"Ptr",rect,"UInt",2)
        if (NumGet(rect,0,"Int")>=0 || NumGet(rect,8,"Int")-NumGet(rect,0,"Int")>NumGet(client,8,"Int")) && NumGet(rect,4,"Int")>=0
            && NumGet(rect,8,"Int")<=NumGet(client,8,"Int") && NumGet(rect,12,"Int")<=NumGet(client,12,"Int")
            break
        Sleep(20)
    }
    AssertView((NumGet(rect,0,"Int")>=0 || NumGet(rect,8,"Int")-NumGet(rect,0,"Int")>NumGet(client,8,"Int")) && NumGet(rect,4,"Int")>=0
        && NumGet(rect,8,"Int")<=NumGet(client,8,"Int") && NumGet(rect,12,"Int")<=NumGet(client,12,"Int"),"focused control is reachable in small view: " control.Text)
}
'@
Invoke-AppTest -Runtime $release -Body $tests
