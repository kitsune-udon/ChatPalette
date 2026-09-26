# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
# Each fault gets an independent process and the existing 30-second deadline.
$body = @'
    entry := "__ENTRY__", scenario := "__SCENARIO__"
    global StopFaultArmed := false, StopChecks := 0, StopOwned := false, StopNestedState := "", StopClock := 0
    BuildManagement()
    Assert(SendWorkerRequest(123,"browser_context").State="ok","prepare live worker for " entry "/" scenario)
    handle := WorkerState.ProcessHandle
    StopChecks := 0, StopOwned := false, StopNestedState := "", StopClock := 0
    if scenario="restart" {
        DllCall("TerminateProcess","Ptr",handle,"UInt",1)
        Assert(DllCall("WaitForSingleObject","Ptr",handle,"UInt",2000,"UInt")=0,entry ": previous worker is stopped before restart")
    }
    RecordBrowserOperation({Mode:"chat_focus",State:"focused",Window:456,Duration:17})
    previousOperation := LastBrowserOperation
    StopFaultArmed := true
    if scenario="timeout"
        RuntimePorts.Clock := StopDeadlineClock
    extra := scenario="timeout" ? "FixtureDelay=3500`n" : (scenario="crash" ? "FixtureExit=1`n" : (scenario="oversize" ? Format("{:33000}","x") : ""))
    failed := false, detail := ""
    try {
        if entry="startup"
            EnsureWorkerRunning()
        else if entry="registration" {
            reply := NativeRequestBrowserOperation(123,"reaction_check")
            failed := reply.State="sync_failed" && InStr(reply.Detail,"補助プロセスの終了を確認できませんでした") > 0
        } else if entry="capture-sync" {
            reply := SynchronizeCapturedReactionRegistration(123,{State:"saved"})
            failed := reply.State="sync_failed" && InStr(reply.Detail,"補助プロセスの終了を確認できませんでした") > 0
        } else {
            reply := entry="transport" ? NativeSendWorkerRequest(123,"verify_input","abcdefghijk",extra)
                : NativeRequestBrowserOperation(123,"verify_input","abcdefghijk",extra)
            failed := reply.State="unavailable" && reply.HasOwnProp("Detail")
                && InStr(reply.Detail,"補助プロセスの終了を確認できませんでした") > 0
        }
        if entry!="startup" && reply.HasOwnProp("Detail")
            detail := reply.Detail
    } catch as failure {
        detail := failure.Message
        failed := InStr(failure.Message,"補助プロセスの終了を確認できませんでした") > 0
    } finally {
        StopFaultArmed := false
        RuntimePorts.Clock := 0
    }
    label := entry "/" scenario
    Assert(failed && StopChecks=1,label ": unconfirmed cleanup is surfaced without an implicit retry")
    if scenario!="restart" {
        cause := scenario="timeout" ? "補助プロセスの応答が時間内に届きませんでした"
            : (scenario="oversize" ? "依頼サイズが不正です" : "補助プロセスが応答する前に終了しました|パイプが切断されました")
        Assert(RegExMatch(detail,cause)>0,label ": original communication failure survives cleanup failure: " detail)
    }
    if entry="browser" || entry="registration" {
        expectedMode := entry="browser" ? "verify_input" : "reaction_check"
        expectedState := entry="registration" ? "sync_failed" : (scenario="restart" ? "unavailable" : "unknown")
        diagnostic := ReadDiagnosticSnapshot()
        Assert(diagnostic.ModeCode=expectedMode && diagnostic.StateCode=expectedState && LastBrowserOperation.Window=123
            && IsInteger(LastBrowserOperation.Duration) && LastBrowserOperation.Duration>=0,
            label ": diagnostic report replaces the previous success after a failed operation")
    } else
        Assert(LastBrowserOperation=previousOperation,label ": direct transport and synchronization leave operation diagnostics to their caller")
    Assert(entry!="startup" ? (StopOwned && StopNestedState="unavailable") : !StopOwned,label ": cleanup preserves its caller request gate and rejects nested requests")
    Assert(WorkerState.ProcessHandle=handle && DllCall("GetHandleInformation","Ptr",handle,"UInt*",&flags:=0),label ": unconfirmed process handle remains owned")
    Assert(!WorkerState.PipeHandle && !WorkerState.SignalHandle,label ": pipe and signal are already released")
    Assert(!WorkerState.RequestActive && !IsBrowserOperationBusy,label ": cleanup failure releases both request gates")
    Assert(DllCall("IsWindowEnabled","Ptr",PaletteWindow.Hwnd) && DllCall("IsWindowEnabled","Ptr",ManagementWindow.Hwnd),label ": cleanup failure restores parent windows")
    StopBrowserWorker()
    Assert(!WorkerState.ProcessHandle && !WorkerState.ProcessId,label ": explicit cleanup retry releases retained ownership")
    Assert(SendWorkerRequest(123,"browser_context").State="ok",label ": the next request succeeds with a fresh worker")
    StopBrowserWorker()
'@
$helpers = @'
ObserveWorkerStop(state) {
    global StopChecks, StopOwned, StopNestedState
    if StopFaultArmed {
        StopChecks++
        StopOwned := WorkerState.RequestActive
        if StopOwned
            StopNestedState := NativeSendWorkerRequest(123,"browser_context").State
        ; The real process is stopped, but its first wait result cannot confirm that.
        if StopChecks=1
            return 0xFFFFFFFF
    }
    return state
}
StopDeadlineClock() {
    global StopClock
    now := StopClock
    StopClock += 1000
    return now
}
'@
foreach ($entry in @('transport','browser','startup','registration','capture-sync')) {
    $scenarios = if ($entry -in @('transport','browser')) { @('timeout','crash','oversize','restart') } else { @('restart') }
    foreach ($scenario in $scenarios) {
        Write-Output "CASE: worker cleanup $entry/$scenario"
        $runtime = New-TestRuntime
        $stopObservation = '            if state != 0'
        Edit-TestSource $runtime 'src/browser/worker_client.ahk' $stopObservation ('            state := ObserveWorkerStop(state)' + "`r`n" + $stopObservation)
        Invoke-AppFixture -Runtime $runtime -Body ($body.Replace('__ENTRY__',$entry).Replace('__SCENARIO__',$scenario)) -Helpers $helpers
    }
}
