# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
# Display reads durable registration without starting or synchronizing a worker.
$displayRuntime=New-TestRuntime
Edit-TestSource $displayRuntime 'src/browser/browser_service.ahk' 'WinGetProcessName("ahk_id " hwnd)' 'RegistrationDisplayProcess(hwnd)'
Invoke-AppTest -Runtime $displayRuntime -Body @'
global DisplayProcess := "brave.exe", DisplayRequests := 0
RuntimePorts.BrowserRequest := RejectDisplayRequest
RuntimePorts.WorkerRequest := RejectDisplayRequest
BuildManagement()
RecordBrowserOperation({Mode:"reaction_send",State:"menu_closed",Duration:17})
previousOperation := LastBrowserOperation, previousResult := LastReactionResult
for target in [0,123] {
    TargetBrowserHwnd := target
    for process in ["closed","autohotkey64.exe"] {
        DisplayProcess := process
        RefreshReactionRegistration()
        Assert(InStr(ReactionRegistrationLabel.Text,"未選択"),"missing, closed and non-browser targets are not registered browsers")
    }
}
TargetBrowserHwnd := 123, DisplayProcess := "BRAVE.EXE"
RefreshReactionRegistration()
Assert(InStr(ReactionRegistrationLabel.Text,"未設定"),"known browser with no saved registration is unconfigured")
tokens := "["
Loop 5
    tokens .= (A_Index>1 ? "," : "") '{"name":"button' A_Index '","id":"id' A_Index '","class":"button","type":50000}'
tokens .= "]"
SaveReactionRegistration('{"browser":"chrome","tokens":' tokens '}')
RefreshReactionRegistration()
Assert(InStr(ReactionRegistrationLabel.Text,"未設定"),"another browser registration cannot configure the current browser")
SaveReactionRegistration('{"browser":"brave","tokens":' tokens '}')
for busy in [false,true] {
    IsBrowserOperationBusy := busy
    RefreshReactionRegistration()
    Assert(InStr(ReactionRegistrationLabel.Text,"設定済み（メニューの認識は未確認）")=1,"saved registration can be shown even while a browser request owns the gate")
    Assert(IsBrowserOperationBusy=busy,"display does not take or release another request's gate")
}
IsBrowserOperationBusy := false
job := CreateReactionJob({Mode:"reaction_send",Phase:"running"})
ActiveReactionJob := job
RefreshReactionRegistration()
Assert(ActiveReactionJob=job && job.Phase="running" && InStr(ReactionRegistrationLabel.Text,"設定済み")=1,"display preserves a running reaction owner")
ActiveReactionJob := 0
db := OpenSettingsRepository(SettingsDatabasePath).Db
db.DefineProp("Scalar",{Call:RegistrationDisplayReadFailure})
try {
    RefreshReactionRegistration()
    Assert(InStr(ReactionRegistrationLabel.Text,"未確認") && InStr(ReactionRegistrationLabel.Text,"Synthetic registration read failure"),"read failure replaces a stale configured label with its cause")
} finally db.DeleteProp("Scalar")
RefreshReactionRegistration()
Assert(InStr(ReactionRegistrationLabel.Text,"設定済み")=1,"new display refresh can read the preserved registration after failure")
Assert(DisplayRequests=0 && !WorkerState.ProcessHandle && !WorkerState.PipeHandle && !WorkerState.SignalHandle && !IsWorkerRegistrationCurrent(),"display never starts, contacts or synchronizes a worker")
Assert(LastBrowserOperation=previousOperation && LastReactionResult=previousResult,"display leaves operation diagnostics and reaction result untouched")
Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),"display does not suspend app windows")
Assert(!DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd)
    && !DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd) && !ReactionOverlay && !ActiveEditorDialog,
    "registration display checks keep all application views hidden")
FileAppend("PASS: " Checks " local registration display checks; no browser or worker operations`n","*")
ExitApp()
RegistrationDisplayProcess(hwnd) {
    if DisplayProcess="closed"
        throw TargetError("Fixture browser is closed")
    return DisplayProcess
}
RejectDisplayRequest(*) {
    global DisplayRequests
    DisplayRequests++
    throw Error("Registration display must not request a worker")
}
RegistrationDisplayReadFailure(*) {
    throw Error("Synthetic registration read failure")
}
'@
