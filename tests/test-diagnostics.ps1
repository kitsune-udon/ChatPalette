# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
Edit-TestSource $release 'src/ui/diagnostics.ahk' '    view.BackColor := "F5F7FA"' ('    view.BackColor := "F5F7FA"' + "`r`n    ProbeDiagnosticConstruction(view)")
Edit-TestSource $release 'src/ui/diagnostics.ahk' 'ReadDiagnosticSnapshot() {' ('ReadDiagnosticSnapshot() {' + "`r`n    if IsSet(ProbeDiagnosticFailure) && ProbeDiagnosticFailure = ""snapshot""`r`n        throw Error(""fixture diagnostic snapshot failure"")")
Edit-TestSource $release 'src/ui/diagnostics.ahk' '        copyButton.OnEvent("Click", CopySnapshot)' ('        copyButton.OnEvent("Click", CopySnapshot)' + "`r`n        global ProbeDiagnosticCopy := CopySnapshot, ProbeDiagnosticCopyButton := copyButton")
Edit-TestSource $release 'src/ui/diagnostics.ahk' '            operation.Text := next.Operation' ('            operation.Text := next.Operation' + "`r`n        ProbeDiagnosticPaint()")
Edit-TestSource $release 'src/ui/diagnostics.ahk' 'A_Clipboard := BuildDiagnosticReport(snapshot)' 'ProbeDiagnosticReport(BuildDiagnosticReport(snapshot))'
Edit-TestSource $release 'src/ui/panel_viewport.ahk' '            OnMessage(0x115,this.ScrollHandler)' ('            OnMessage(0x115,this.ScrollHandler)' + "`r`n            ProbeDiagnosticViewportRegistration(this)")
$tests=@'
global DiagnosticChecks := 0
global ProbeDiagnosticFailure := "", ProbeDiagnosticHwnd := 0, ProbeDiagnosticViewport := 0
for point in ["construction","snapshot","viewport"] {
    ProbeDiagnosticFailure := point, ProbeDiagnosticHwnd := 0, ProbeDiagnosticViewport := 0
    failed := false
    try CreateDiagnosticPanel()
    catch as failure
        failed := failure.Message == "fixture diagnostic " point " failure"
    CheckDiagnostic(failed,"diagnostic creation preserves the failure: " point)
    CheckDiagnostic(ProbeDiagnosticHwnd && !DllCall("IsWindow","Ptr",ProbeDiagnosticHwnd),"failed diagnostic creation destroys its unpublished window: " point)
    if point = "viewport"
        CheckDiagnostic(ProbeDiagnosticViewport.Disposed,"failed diagnostic creation releases viewport callbacks")
    ProbeDiagnosticFailure := "", ProbeDiagnosticViewport := 0
    diagnostic := CreateDiagnosticPanel()
    try {
        diagnostic.Refresh.Call()
        CheckDiagnostic(DllCall("IsWindow","Ptr",diagnostic.Window.Hwnd) && !diagnostic.Viewport.Disposed,"diagnostic creation and refresh retry after failure: " point)
    } finally {
        diagnostic.Viewport.Dispose()
        diagnostic.Window.Destroy()
    }
}
global ProbeDiagnosticPaintFailure := false, ProbeDiagnosticReports := [], ProbeDiagnosticPaintCopied := false, ProbeDiagnosticPaintEnabled := false
RecordBrowserOperation({Mode:"chat_focus",State:"focused",Duration:10})
diagnostic := CreateDiagnosticPanel()
try {
    ProbeDiagnosticCopy.Call()
    CheckDiagnostic(ProbeDiagnosticReports.Length=1 && InStr(ProbeDiagnosticReports[1],"(focused)"),"diagnostic copy starts with the completed display")
    RecordBrowserOperation({Mode:"chat_clear",State:"cleared",Duration:20})
    ProbeDiagnosticPaintFailure := true, failed := false, beforeCritical := A_IsCritical
    try diagnostic.Refresh.Call()
    catch as failure
        failed := failure.Message == "fixture diagnostic paint failure"
    CheckDiagnostic(failed && A_IsCritical=beforeCritical,"failed diagnostic paint preserves the cause and restores interrupt state")
    CheckDiagnostic(!ProbeDiagnosticPaintEnabled && !ProbeDiagnosticPaintCopied,"incomplete diagnostic paint cannot be copied")
    ProbeDiagnosticCopy.Call()
    CheckDiagnostic(!ProbeDiagnosticCopyButton.Enabled && ProbeDiagnosticReports.Length=1,"failed diagnostic paint keeps copying unavailable")
    ProbeDiagnosticPaintFailure := false
    diagnostic.Refresh.Call()
    ProbeDiagnosticCopy.Call()
    CheckDiagnostic(ProbeDiagnosticCopyButton.Enabled && ProbeDiagnosticReports.Length=2 && InStr(ProbeDiagnosticReports[2],"(cleared)"),"successful retry publishes and enables the new diagnostic report")
    ProbeDiagnosticFailure := "snapshot", failed := false
    try diagnostic.Refresh.Call()
    catch as failure
        failed := failure.Message == "fixture diagnostic snapshot failure"
    ProbeDiagnosticCopy.Call()
    CheckDiagnostic(failed && ProbeDiagnosticCopyButton.Enabled && ProbeDiagnosticReports.Length=3
        && ProbeDiagnosticReports[3]==ProbeDiagnosticReports[2],"failed diagnostic acquisition preserves the last complete display and report")
} finally {
    diagnostic.Viewport.Dispose()
    diagnostic.Window.Destroy()
    ProbeDiagnosticCopy := 0, ProbeDiagnosticCopyButton := 0
}
FileAppend("PASS: " DiagnosticChecks " diagnostic construction, publication and recovery checks; no browser or clipboard operations`n","*")
ExitApp()
CheckDiagnostic(value,label) {
    global DiagnosticChecks
    if !value
        throw Error(label)
    DiagnosticChecks++
}
ProbeDiagnosticReport(report) {
    ProbeDiagnosticReports.Push(report)
}
ProbeDiagnosticPaint() {
    global ProbeDiagnosticPaintCopied, ProbeDiagnosticPaintEnabled
    if !IsSet(ProbeDiagnosticPaintFailure) || !ProbeDiagnosticPaintFailure
        return
    ProbeDiagnosticPaintEnabled := ProbeDiagnosticCopyButton.Enabled
    count := ProbeDiagnosticReports.Length
    ProbeDiagnosticCopy.Call()
    ProbeDiagnosticPaintCopied := ProbeDiagnosticReports.Length != count
    throw Error("fixture diagnostic paint failure")
}
ProbeDiagnosticConstruction(view) {
    global ProbeDiagnosticHwnd
    ProbeDiagnosticHwnd := view.Hwnd
    if IsSet(ProbeDiagnosticFailure) && ProbeDiagnosticFailure = "construction"
        throw Error("fixture diagnostic construction failure")
}
ProbeDiagnosticViewportRegistration(viewport) {
    global ProbeDiagnosticViewport
    if IsSet(ProbeDiagnosticFailure) && ProbeDiagnosticFailure = "viewport" {
        ProbeDiagnosticViewport := viewport
        throw Error("fixture diagnostic viewport failure")
    }
}
'@
Invoke-AppTest -Runtime $release -Body $tests
