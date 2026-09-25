# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$mock = @'
$script:FixtureReactionSends = 0
function Invoke-FixtureRequest($Request) {
    if ($Request.Mode -eq 'fixture_send_count') {
        return @{Seq=$Request.Seq;Window=$Request.Window;State='ok';Detail=[string]$script:FixtureReactionSends}
    }
    if ($Request.Mode -eq 'reaction_send') {
        $script:FixtureReactionSends++
        return @{Seq=$Request.Seq;Window=$Request.Window;State='operated'}
    }
    if ($Request.Mode -eq 'fixture_seed') {
        $script:Videos['abcdefghijk'] = @{Author='fixture';Channel='/channel/test';Time=[DateTime]::UtcNow}
        return @{Seq=$Request.Seq;Window=$Request.Window;State='ok'}
    }
    if ($Request.Mode -eq 'fixture_registration') {
        return @{Seq=$Request.Seq;Window=$Request.Window;State='ok';Detail=$script:BrowserReactionSelectors['fixture'].tokens[0].name}
    }
    if ($Request.Mode -eq 'fixture_count') {
        return @{Seq=$Request.Seq;Window=$Request.Window;State='ok';Detail=[string]$script:Videos.Count}
    }
    if ($Request.Mode -eq 'reaction_configure' -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'reject-sync'))) {
        $fault = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'reject-sync'))
        if ($fault -eq 'worker-exception') { throw 'Fixture worker registration failure' }
        $reply = @{Seq=$Request.Seq;Window=$Request.Window;State='unavailable'}
        if ($fault -eq 'refused') { $reply.Detail = 'Fixture registration refusal' }
        return $reply
    }
    return Invoke-WorkerRequest $Request
}
'@
Write-TestWorker -Runtime $release -Definitions $mock
$tests = @'
global RegistrationSyncFault := "", CancelOnCapture := true
db := OpenSettingsRepository(SettingsDatabasePath).Db
tokens := "["
Loop 5
    tokens .= (A_Index>1 ? "," : "") '{"name":"👏' A_Index '","id":"id' A_Index '","class":"button","type":50000}'
tokens .= "]"
payload := '{"browser":"fixture","tokens":' tokens '}'
SaveReactionRegistration(payload)
Assert(db.Scalar("PRAGMA user_version")="3","schema version")
snapshot := LoadReactionRegistrationSnapshot()
Assert(db.Scalar("SELECT COUNT(*) FROM reaction_registrations")="1","saved registration")
reply := SendWorkerRequest(0,"reaction_configure","","Payload=" snapshot "`n")
Assert(reply.State="configured","worker accepts snapshot over pipe")
StopBrowserWorker()
EnsureReactionRegistrations(0)
Assert(IsWorkerRegistrationCurrent(),"worker restart restores registrations")
db.Exec("PRAGMA query_only=ON")
reply := CommitCapturedReactionRegistration(0,{State:"captured",Detail:StrReplace(payload,"👏1","must-not-save")})
Assert(reply.State="save_failed" && LoadReactionRegistrationSnapshot()==snapshot,"failed commit preserves registration")
Assert(SendWorkerRequest(0,"fixture_registration").Detail="👏1","failed save retains worker registration")
db.Exec("PRAGMA query_only=OFF")
beforeCancel := LoadReactionRegistrationSnapshot()
global ActiveReactionJob := CreateReactionJob({Mode:"reaction_capture",Window:0,Cancelled:false})
global CaptureFixturePayload := StrReplace(payload,"👏1","cancelled-first")
captured := RequestBrowserOperation(0,"reaction_capture")
Assert(captured.State="captured" && ActiveReactionJob.Cancelled && LoadReactionRegistrationSnapshot()==beforeCancel,"capture response does not persist cancelled request")
cancelled := FinalizeReactionCapture(ActiveReactionJob,captured)
Assert(cancelled.State="cancelled" && LoadReactionRegistrationSnapshot()==beforeCancel,"cancel before commit retains DB")
Assert(SendWorkerRequest(0,"fixture_registration").Detail="👏1","cancel before commit retains worker")
stale := CreateReactionJob({Mode:"reaction_capture",Window:0,Cancelled:false})
RecordBrowserOperation({Mode:"chat_clear",State:"cleared",Window:321,Duration:25})
recordBefore := LastBrowserOperation
cancelled := FinalizeReactionCapture(stale,{State:"captured",Detail:payload})
Assert(cancelled.State="cancelled" && LoadReactionRegistrationSnapshot()==beforeCancel,"replaced job cannot commit")
Assert(LastBrowserOperation=recordBefore && recordBefore.Mode="chat_clear" && recordBefore.State="cleared"
    && recordBefore.Window=321 && recordBefore.Duration=25,"stale registration cannot mutate another operation's diagnostic record")
global ActiveReactionJob := 0
workerBefore := WorkerState.ProcessId
SendWorkerRequest(0,"fixture_seed")
payload := StrReplace(payload,"👏1","updated-first")
reply := CommitCapturedReactionRegistration(0,{State:"captured",Detail:payload})
Assert(reply.State="registered" && WorkerState.ProcessId=workerBefore,"capture sync keeps worker alive")
Assert(SendWorkerRequest(0,"fixture_count").Detail="1","capture sync retains video cache")
Assert(SendWorkerRequest(0,"fixture_registration").Detail="updated-first","changed registration reaches existing worker")
global CancelOnRegistrationSync := true, CommittedAtCancellation := false
reply := CommitCapturedReactionRegistration(0,{State:"captured",Detail:payload})
Assert(CommittedAtCancellation && reply.State="registered","cancel during sync preserves committed result")
Assert(SendWorkerRequest(0,"fixture_registration").Detail="updated-first","cancel after save still synchronizes worker")
; The countdown records capture, save and synchronization as one completed operation.
CaptureFixturePayload := payload
for expected in ["registered","save_failed","sync_failed","cancelled"] {
    CancelOnCapture := expected="cancelled"
    RegistrationSyncFault := expected="sync_failed" ? "exception" : ""
    if expected="save_failed"
        db.Exec("PRAGMA query_only=ON")
    job := CreateReactionJob({Mode:"reaction_capture",Window:0})
    ActiveReactionJob := job
    try {
        ReactionCountdown()
        Assert(!ActiveReactionJob && LastReactionResult.Reason=expected,"capture finishes with its final outcome: " expected)
        Assert(LastBrowserOperation.Mode="reaction_capture" && LastBrowserOperation.State=expected
            && LastBrowserOperation.Window=0 && LastBrowserOperation.Duration>=0,"diagnostics record the complete capture outcome: " expected)
        Assert(job.RegistrationCommitted=(expected="registered" || expected="sync_failed"),"capture outcome agrees with durable commit: " expected)
    } finally {
        RegistrationSyncFault := ""
        db.Exec("PRAGMA query_only=OFF")
        if ActiveReactionJob
            FinishReactionJob(ActiveReactionJob)
    }
}
CancelOnCapture := true
flag := A_ScriptDir "\src\browser\reject-sync"
for fault,expectedDetail in Map("refused","Fixture registration refusal",
    "exception","Synthetic registration synchronization failure",
    "worker-exception","Fixture worker registration failure",
    "no-detail","登録情報の同期に失敗しました。") {
    previousName := SendWorkerRequest(0,"fixture_registration").Detail
    preservedWorker := WorkerState.ProcessHandle
    beforeSends := Integer(SendWorkerRequest(0,"fixture_send_count").Detail)
    RegistrationSyncFault := fault
    if fault!="exception"
        FileAppend(fault,flag)
    nextName := "updated-after-" fault
    payload := StrReplace(payload,previousName,nextName)
    reply := CommitCapturedReactionRegistration(0,{State:"captured",Detail:payload})
    snapshot := LoadReactionRegistrationSnapshot()
    Assert(reply.State="sync_failed" && InStr(snapshot,nextName),fault ": sync failure retains committed registration")
    Assert(reply.Detail==expectedDetail,fault ": capture synchronization preserves the failure reason")
    Assert(IsWorkerRunning() && WorkerState.ProcessHandle=preservedWorker && !IsWorkerRegistrationCurrent(),fault ": healthy worker survives without permission to perform reactions")
    for mode in ["reaction_send","reaction_check","reaction_capture"] {
        blocked := RequestBrowserOperation(0,mode,"","Reaction=1`n")
        Assert(blocked.State="sync_failed" && !IsWorkerRegistrationCurrent(),fault ": unsynchronized registration blocks " mode)
        Assert(blocked.HasOwnProp("Detail") && blocked.Detail==expectedDetail,fault ": blocked " mode " preserves the failure reason")
    }
    job := CreateReactionJob({Mode:"reaction_check",Window:0})
    ActiveReactionJob := job
    ReactionCountdown()
    Assert(!ActiveReactionJob && LastReactionResult.Reason="sync_failed" && LastReactionResult.Detail==expectedDetail,
        fault ": reaction result retains the synchronization reason for inspection")
    Assert(Integer(SendWorkerRequest(0,"fixture_send_count").Detail)=beforeSends,fault ": blocked requests never reach the reaction handler")
    Assert(SendWorkerRequest(0,"fixture_registration").Detail==previousName,fault ": failed synchronization does not publish partial registration")
    Assert(IsWorkerRunning() && WorkerState.ProcessHandle=preservedWorker && SendWorkerRequest(0,"fixture_count").Detail="1",fault ": repeated refusal preserves the worker and video cache")
    RegistrationSyncFault := ""
    if fault!="exception"
        FileDelete(flag)
    recovered := RequestBrowserOperation(0,"reaction_send","","Reaction=1`n")
    Assert(recovered.State="operated" && IsWorkerRegistrationCurrent(),fault ": next operation synchronizes before proceeding")
    Assert(SendWorkerRequest(0,"fixture_registration").Detail==nextName,fault ": recovery uses committed registration")
    Assert(Integer(SendWorkerRequest(0,"fixture_send_count").Detail)=beforeSends+1,fault ": recovery performs only the new request without replay")
    Assert(WorkerState.ProcessHandle=preservedWorker && SendWorkerRequest(0,"fixture_count").Detail="1",fault ": recovery reuses the healthy worker and cache")
}
for bad in [
    "{", "{}",
    db.Scalar("SELECT json_set(?,'$.tokens[1]',json_extract(?,'$.tokens[0]'))",payload,payload),
    db.Scalar("SELECT json_remove(?,'$.tokens[4]')",payload),
    StrReplace(payload,'"type":50000','"type":1'),
    StrReplace(payload,'"browser":"fixture"','"browser":"invalid space"'),
    StrReplace(payload,'"browser":"fixture"','"browser":"fixture","browser":"other"'),
    StrReplace(payload,'"type":50000','"type":50000,"type":1'),
    StrReplace(payload,'"type":50000','"type":50000,"TYPE":1'),
    StrReplace(payload,'"type":50000','"type":50000,"ty\u0070e":1')] {
    failed := false
    try SaveReactionRegistration(bad)
    catch
        failed := true
    Assert(failed && LoadReactionRegistrationSnapshot()==snapshot,"invalid payload preserves data")
}
external := SqliteConnection(SettingsDatabasePath)
external.ConfigureStorage()
external.Run("UPDATE reaction_registrations SET payload=json_set(payload,'$.extra','external')")
external.Close()
failed := false
try SaveReactionRegistration(payload)
catch
    failed := true
Assert(failed,"external update is not overwritten")
ReloadAppSettings()
SaveReactionRegistration(payload)
; A failed aggregate-size check rolls back the candidate row as well.
padding := ""
Loop 6000
    padding .= "x"
large := db.Scalar("SELECT json_set(?,'$.padding',?)",payload,padding)
Loop 3
    SaveReactionRegistration(db.Scalar("SELECT json_set(?,'$.browser',?)",large,"size" A_Index))
before := LoadReactionRegistrationSnapshot(), failed := false
try SaveReactionRegistration(db.Scalar("SELECT json_set(?,'$.browser','sizefour')",large))
catch
    failed := true
Assert(failed && LoadReactionRegistrationSnapshot()==before,"aggregate overflow rolls back candidate")
db.Run("DELETE FROM reaction_registrations WHERE browser!='fixture'")
second := db.Scalar("SELECT json_set(?,'$.browser','second')",payload)
SaveReactionRegistration(second)
backup := A_ScriptDir "\backup.db"
BackupSettingsDatabase(backup)
copy := SettingsRepository(backup)
Assert(copy.Db.Scalar("SELECT COUNT(*) FROM reaction_registrations")="2","backup includes every browser")
for row in db.Rows("SELECT browser,payload FROM reaction_registrations")
    Assert(copy.Db.Scalar("SELECT payload FROM reaction_registrations WHERE browser=?",row[1])==row[2],"backup preserves browser payload")
copy.Close()
db.Run("DELETE FROM reaction_registrations WHERE browser='second'")
CloseSettingsStore()
Assert(LoadReactionRegistrationSnapshot()==snapshot,"DB reload preserves registration")
FileAppend("PASS: " Checks " registration DB, backup and IPC checks`n","*")
ExitApp()
FixtureWorkerRequest(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    global CancelOnRegistrationSync, CommittedAtCancellation
    if mode = "reaction_configure" && RegistrationSyncFault="exception"
        throw Error("Synthetic registration synchronization failure")
    if mode = "reaction_capture" {
        if CancelOnCapture
            CancelReaction()
        return {State:"captured",Detail:CaptureFixturePayload}
    }
    if mode = "reaction_configure" && IsSet(CancelOnRegistrationSync) && CancelOnRegistrationSync {
        CancelOnRegistrationSync := false
        CommittedAtCancellation := ActiveReactionJob.RegistrationCommitted && !A_IsCritical
        CancelReaction()
    }
    return NativeSendWorkerRequest(hwnd,mode,expectedVideo,extra)
}
CommitCapturedReactionRegistration(hwnd,reply) {
    global ActiveReactionJob := CreateReactionJob({Mode:"reaction_capture",Window:hwnd,Cancelled:false})
    try {
        result := FinalizeReactionCapture(ActiveReactionJob,reply)
        if result.State = "registered" || result.State = "sync_failed"
            Assert(ActiveReactionJob.RegistrationCommitted && IsWorkerRegistrationCurrent()=(result.State="registered"),"committed capture reports actual worker readiness")
        return result
    }
    finally global ActiveReactionJob := 0
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup @'
RuntimePorts.WorkerScript := A_ScriptDir "\src\browser\fixture_worker.ps1"
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=0
RuntimePorts.Foreground := (hwnd) => hwnd=0
RuntimePorts.WorkerRequest := FixtureWorkerRequest
'@

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
