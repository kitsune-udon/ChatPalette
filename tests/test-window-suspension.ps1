# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
Edit-TestSource $release 'src/ui/ui_runtime.ahk' 'RefreshOperationControls() {' ('RefreshOperationControls() {' + "`r`n    global ProbeWaitFailure`r`n    if IsSet(ProbeWaitFailure) && ProbeWaitFailure && IsBrowserOperationBusy {`r`n        ProbeWaitFailure := false`r`n        throw Error(""fixture wait preparation failure"")`r`n    }")
$tests=@'
BuildManagement()
global WindowFaults := Map(), WindowReplacement := 0
global WindowInterleaveArmed := false, WindowInterleaveRuns := 0, WindowInterleaveEditor := 0
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
global ProbeWaitFailure := false
for managerEnabled in [true,false] {
    ManagementWindow.Opt(managerEnabled ? "-Disabled" : "+Disabled")
    ProbeWaitFailure := true
    failed := false
    try NativeRequestBrowserOperation(123,"browser_context")
    catch as failure
        failed := failure.Message == "fixture wait preparation failure"
    Assert(failed && !IsBrowserOperationBusy,"failed wait preparation releases operation ownership")
    Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !!DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)=managerEnabled,"failed wait preparation restores prior parent enabled state")
}
ManagementWindow.Opt("-Disabled")
PaletteWindow.DefineProp("Opt",{Call:WindowOpt})
ManagementWindow.DefineProp("Opt",{Call:WindowOpt})
for flow in ["wait","editor"] {
    for failedWindow in ["palette","manager","both"] {
        WindowFaults := Map()
        if failedWindow!="manager"
            WindowFaults[PaletteWindow] := "palette restore failure"
        if failedWindow!="palette"
            WindowFaults[ManagementWindow] := "manager restore failure"
        errorMessage := "", priorInterrupt := A_IsCritical
        try ExerciseWindowSuspension(flow)
        catch as failure
            errorMessage := failure.Message
        label := flow "/" failedWindow
        Assert(A_IsCritical=priorInterrupt,"failed parent restoration keeps caller interrupt setting: " label)
        for window, detail in WindowFaults
            Assert(InStr(errorMessage,detail),"restore failure remains visible: " label "/" detail)
        Assert(!IsBrowserOperationBusy && !ActiveEditorDialog,"failed restore releases the operation: " label)
        Assert(!!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd)=(failedWindow="manager"),"palette restoration is attempted independently: " label)
        Assert(!!DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)=(failedWindow="palette"),"management restoration is attempted independently: " label)
        Assert(PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"operation controls refresh despite parent restore failure: " label)
        WindowFaults.Clear()
        PaletteWindow.Opt("-Disabled"), ManagementWindow.Opt("-Disabled")
    }
    for paletteEnabled in [true,false] {
        for managerEnabled in [true,false] {
            PaletteWindow.Opt(paletteEnabled ? "-Disabled" : "+Disabled")
            ManagementWindow.Opt(managerEnabled ? "-Disabled" : "+Disabled")
            ExerciseWindowSuspension(flow)
            Assert(!!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd)=paletteEnabled
                && !!DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd)=managerEnabled,"original enabled states survive: " flow "/" paletteEnabled "/" managerEnabled)
        }
    }
    PaletteWindow.Opt("-Disabled"), ManagementWindow.Opt("-Disabled")
    originalManager := ManagementWindow
    WindowReplacement := Gui(), WindowReplacement.Opt("+Disabled")
    try {
        ExerciseWindowSuspension(flow)
        Assert(DllCall("IsWindowEnabled","Ptr",originalManager.Hwnd),"restore belongs to the originally suspended window: " flow)
        Assert(!DllCall("IsWindowEnabled","Ptr",WindowReplacement.Hwnd),"replacement window keeps its own disabled state: " flow)
    } finally {
        ManagementWindow := originalManager
        WindowReplacement.Destroy(), WindowReplacement := 0
        originalManager.Opt("-Disabled")
    }
}
editor := Gui()
try {
    BeginEditorDialog(editor,"nested wait fixture")
    NativeRequestBrowserOperation(123,"browser_context")
    Assert(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"browser wait preserves the editor's parent locks")
} finally {
    EndEditorDialog(editor)
    editor.Destroy()
}
Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"outer editor restores both parents after the nested wait")
; A queued editor must see both restored parents, never the first half of cleanup.
for flow in ["wait","editor"] {
    for callerCritical in [0,23] {
        WindowInterleaveArmed := true, WindowInterleaveRuns := 0
        label := flow "/" callerCritical
        try {
            Critical(callerCritical)
            ExerciseWindowSuspension(flow)
            Assert(A_IsCritical=callerCritical,"parent cleanup restores caller interrupt setting: " label)
            Critical("Off")
            deadline := A_TickCount+1000
            while !WindowInterleaveRuns && A_TickCount<deadline
                Sleep(10)
            Assert(!WindowInterleaveArmed && WindowInterleaveRuns=1 && WindowInterleaveEditor && ActiveEditorDialog,
                "queued editor enters exactly once after parent cleanup: " label)
            Assert(!DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && !DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),
                "parent cleanup cannot enable a new editor's parents: " label)
        } finally {
            Critical("Off")
            WindowInterleaveArmed := false
            SetTimer(OpenWindowInterleaveEditor,0)
            if WindowInterleaveEditor {
                try EndEditorDialog(WindowInterleaveEditor)
                finally WindowInterleaveEditor.Destroy(), WindowInterleaveEditor := 0
            }
        }
        Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),
            "new editor captures and restores both parents after parent cleanup: " label)
    }
}
PaletteWindow.DeleteProp("Opt"), ManagementWindow.DeleteProp("Opt")
FileAppend("PASS: " Checks " parent-window suspension checks; no real browser operations`n","*")
ExitApp()
WindowOpt(window,options) {
    global WindowInterleaveArmed
    if options="-Disabled" && WindowFaults.Has(window)
        throw Error(WindowFaults[window])
    result := Gui.Prototype.Opt.Call(window,options)
    if options="-Disabled" && WindowInterleaveArmed {
        WindowInterleaveArmed := false
        SetTimer(OpenWindowInterleaveEditor,-1)
        Sleep(40)
    }
    return result
}
OpenWindowInterleaveEditor(*) {
    global WindowInterleaveRuns, WindowInterleaveEditor
    WindowInterleaveRuns++
    if !OperationAllowed("edit")
        return
    WindowInterleaveEditor := Gui()
    BeginEditorDialog(WindowInterleaveEditor,"queued editor fixture")
}
ExerciseWindowSuspension(flow) {
    if flow="wait"
        NativeRequestBrowserOperation(123,"browser_context")
    else {
        editor := Gui()
        try {
            BeginEditorDialog(editor,"window suspension fixture")
            ReplaceSuspendedWindow()
        } finally {
            try EndEditorDialog(editor)
            finally editor.Destroy()
        }
    }
}
ReplaceSuspendedWindow() {
    global ManagementWindow
    if WindowReplacement
        ManagementWindow := WindowReplacement
}
WindowRequest(hwnd,mode,video,extra) {
    ReplaceSuspendedWindow()
    return {State:"ok",Video:"abcdefghijk"}
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup @'
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=123
RuntimePorts.WorkerRequest := WindowRequest
'@
