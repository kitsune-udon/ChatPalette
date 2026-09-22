# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$workerPath = Join-Path $release 'src\browser\browser_worker.ps1'
$worker = [IO.File]::ReadAllText($workerPath).Replace('function Invoke-WorkerRequest($Request) {', @'
function Invoke-WorkerRequest($Request) {
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
        return @{Seq=$Request.Seq;Window=$Request.Window;State='unavailable'}
    }
'@)
[IO.File]::WriteAllText($workerPath,$worker,[Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global SqliteChecks := 0
try {
    db := OpenSettingsRepository(SettingsDatabasePath).Db
    tokens := "["
    Loop 5
        tokens .= (A_Index>1 ? "," : "") '{"name":"👏' A_Index '","id":"id' A_Index '","class":"button","type":50000}'
    tokens .= "]"
    payload := '{"browser":"fixture","tokens":' tokens '}'
    SaveReactionRegistration(payload)
    SqlCheck(db.Scalar("PRAGMA user_version")="3","schema version")
    snapshot := LoadReactionRegistrationSnapshot()
    SqlCheck(db.Scalar("SELECT COUNT(*) FROM reaction_registrations")="1","saved registration")
    reply := SendWorkerRequest(0,"reaction_configure","","Payload=" snapshot "`n")
    SqlCheck(reply.State="configured","worker accepts snapshot over pipe")
    StopBrowserWorker()
    SqlCheck(PrepareReactionRegistrations(0),"worker restart restores registrations")
    db.Exec("PRAGMA query_only=ON")
    reply := CommitCapturedReactionRegistration(0,{State:"captured",Detail:StrReplace(payload,"👏1","must-not-save")})
    SqlCheck(reply.State="save_failed" && LoadReactionRegistrationSnapshot()==snapshot,"failed commit preserves registration")
    SqlCheck(SendWorkerRequest(0,"fixture_registration").Detail="👏1","failed save retains worker registration")
    db.Exec("PRAGMA query_only=OFF")
    beforeCancel := LoadReactionRegistrationSnapshot()
    global ActiveReactionJob := CreateReactionJob({Mode:"reaction_capture",Window:0,Cancelled:false})
    global CaptureFixturePayload := StrReplace(payload,"👏1","cancelled-first")
    captured := RequestBrowserOperation(0,"reaction_capture")
    SqlCheck(captured.State="captured" && ActiveReactionJob.Cancelled && LoadReactionRegistrationSnapshot()==beforeCancel,"capture response does not persist cancelled request")
    cancelled := FinalizeReactionCapture(ActiveReactionJob,captured)
    SqlCheck(cancelled.State="cancelled" && LoadReactionRegistrationSnapshot()==beforeCancel,"cancel before commit retains DB")
    SqlCheck(SendWorkerRequest(0,"fixture_registration").Detail="👏1","cancel before commit retains worker")
    stale := CreateReactionJob({Mode:"reaction_capture",Window:0,Cancelled:false})
    cancelled := FinalizeReactionCapture(stale,{State:"captured",Detail:payload})
    SqlCheck(cancelled.State="cancelled" && LoadReactionRegistrationSnapshot()==beforeCancel,"replaced job cannot commit")
    global ActiveReactionJob := 0
    workerBefore := WorkerState.ProcessId
    SendWorkerRequest(0,"fixture_seed")
    payload := StrReplace(payload,"👏1","updated-first")
    reply := CommitCapturedReactionRegistration(0,{State:"captured",Detail:payload})
    SqlCheck(reply.State="registered" && WorkerState.ProcessId=workerBefore,"capture sync keeps worker alive")
    SqlCheck(SendWorkerRequest(0,"fixture_count").Detail="1","capture sync retains video cache")
    SqlCheck(SendWorkerRequest(0,"fixture_registration").Detail="updated-first","changed registration reaches existing worker")
    global CancelOnRegistrationSync := true, CommittedAtCancellation := false
    reply := CommitCapturedReactionRegistration(0,{State:"captured",Detail:payload})
    SqlCheck(CommittedAtCancellation && reply.State="registered","cancel during sync preserves committed result")
    SqlCheck(SendWorkerRequest(0,"fixture_registration").Detail="updated-first","cancel after save still synchronizes worker")
    snapshot := LoadReactionRegistrationSnapshot()
    flag := A_ScriptDir "\src\browser\reject-sync"
    FileAppend("reject",flag)
    payload := StrReplace(payload,"updated-first","updated-after-failure")
    reply := CommitCapturedReactionRegistration(0,{State:"captured",Detail:payload})
    snapshot := LoadReactionRegistrationSnapshot()
    SqlCheck(reply.State="sync_failed" && !WorkerState.ProcessId && !WorkerState.RegistrationPid && InStr(snapshot,"updated-after-failure"),"failed sync stops stale worker and retains committed DB")
    SqlCheck(!PrepareReactionRegistrations(0) && !WorkerState.ProcessId,"repeated sync failure cannot mark worker ready")
    blocked := RequestBrowserOperation(0,"reaction_send","abcdefghijk","Reaction=1`n")
    SqlCheck(blocked.State="sync_failed" && !WorkerState.ProcessId && LastBrowserOperation.State="sync_failed","public operation blocks sending on failed sync")
    FileDelete(flag)
    SqlCheck(PrepareReactionRegistrations(0),"next operation recovers committed snapshot")
    SqlCheck(SendWorkerRequest(0,"fixture_registration").Detail="updated-after-failure","retry restores new data instead of stale registration")
    SqlCheck(SendWorkerRequest(0,"fixture_count").Detail="0","restarted worker has no disk video cache")
    for bad in ["{", "{}", db.Scalar("SELECT json_set(?,'$.tokens[1]',json_extract(?,'$.tokens[0]'))",payload,payload), db.Scalar("SELECT json_remove(?,'$.tokens[4]')",payload), StrReplace(payload,'"type":50000','"type":1'),StrReplace(payload,'"browser":"fixture"','"browser":"invalid space"')] {
        failed := false
        try SaveReactionRegistration(bad)
        catch
            failed := true
        SqlCheck(failed && LoadReactionRegistrationSnapshot()==snapshot,"invalid payload preserves data")
    }
    external := SqliteConnection(SettingsDatabasePath)
    external.ConfigureStorage()
    external.Run("UPDATE reaction_registrations SET payload=json_set(payload,'$.extra','external')")
    external.Close()
    failed := false
    try SaveReactionRegistration(payload)
    catch
        failed := true
    SqlCheck(failed,"external update is not overwritten")
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
    SqlCheck(failed && LoadReactionRegistrationSnapshot()==before,"aggregate overflow rolls back candidate")
    db.Run("DELETE FROM reaction_registrations WHERE browser!='fixture'")
    second := db.Scalar("SELECT json_set(?,'$.browser','second')",payload)
    SaveReactionRegistration(second)
    backup := A_ScriptDir "\backup.db"
    BackupSettingsDatabase(backup)
    copy := SettingsRepository(backup)
    SqlCheck(copy.Db.Scalar("SELECT COUNT(*) FROM reaction_registrations")="2","backup includes every browser")
    for row in db.Rows("SELECT browser,payload FROM reaction_registrations")
        SqlCheck(copy.Db.Scalar("SELECT payload FROM reaction_registrations WHERE browser=?",row[1])==row[2],"backup preserves browser payload")
    copy.Close()
    db.Run("DELETE FROM reaction_registrations WHERE browser='second'")
    CloseSettingsStore()
    legacy := AppDataDirectory "\reaction_selectors.json"
    FileAppend(snapshot,legacy,"UTF-8")
    original := FileRead(legacy,"UTF-8")
    prior := SqliteConnection(SettingsDatabasePath)
    prior.Exec("DROP TABLE reaction_registrations; DROP TABLE shortcut_bindings; PRAGMA user_version=1"), prior.Close()
    migrated := OpenSettingsRepository(SettingsDatabasePath)
    SqlCheck(LoadReactionRegistrationSnapshot()==snapshot && FileRead(legacy,"UTF-8")==original,"v1 migration preserves source")
    CloseSettingsStore()
    FileDelete(legacy)
    FileAppend('{"version":1,"profiles":[' payload ',{}]}',legacy,"UTF-8")
    OpenSettingsRepository(SettingsDatabasePath)
    SqlCheck(LoadReactionRegistrationSnapshot()==snapshot,"v2 ignores obsolete JSON")
    CloseSettingsStore()
    prior := SqliteConnection(SettingsDatabasePath)
    prior.Exec("DROP TABLE reaction_registrations; DROP TABLE shortcut_bindings; PRAGMA user_version=1"), prior.Close()
    failed := false
    try OpenSettingsRepository(SettingsDatabasePath)
    catch
        failed := true
    prior := SqliteConnection(SettingsDatabasePath)
    SqlCheck(failed && prior.Scalar("PRAGMA user_version")="1" && prior.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='reaction_registrations'")="0","bad legacy import rolls back upgrade")
    prior.Close()
    ; Repair the source and retry after a partially attempted import.
    FileDelete(legacy)
    FileAppend(snapshot,legacy,"UTF-8")
    OpenSettingsRepository(SettingsDatabasePath)
    SqlCheck(LoadReactionRegistrationSnapshot()==snapshot,"retry after partial import succeeds")
    CloseSettingsStore()
    FileDelete(legacy)
    OpenSettingsRepository(SettingsDatabasePath)
    SqlCheck(LoadReactionRegistrationSnapshot()==snapshot,"DB reload needs no legacy JSON")
    FileAppend("PASS: " SqliteChecks " registration DB, migration, backup and IPC checks`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n","**")
    ExitApp(1)
}
FixtureWorkerRequest(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    global CancelOnRegistrationSync, CommittedAtCancellation
    if mode = "reaction_capture" {
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
            SqlCheck(ActiveReactionJob.RegistrationCommitted && ActiveReactionJob.RegistrationSynced=(result.State="registered"),"save and sync are distinct job states")
        return result
    }
    finally global ActiveReactionJob := 0
}
SqlCheck(value,message) {
    global SqliteChecks
    SqliteChecks++
    if !value
        throw Error(message)
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup @'
RuntimePorts.BrowserIdentity := (hwnd) => hwnd=0
RuntimePorts.WorkerRequest := FixtureWorkerRequest
'@
