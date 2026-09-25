# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

# Fail one rollback move only in the isolated runtime.
$lifecycle = Join-Path $release 'src\app\app_lifecycle.ahk'
$source = [IO.File]::ReadAllText($lifecycle)
$anchor = 'try FileMove(pair[2],pair[1],false)'
if (!$source.Contains($anchor)) { throw 'Reset rollback injection point missing' }
[IO.File]::WriteAllText($lifecycle,$source.Replace($anchor,'try ProbeResetRestore(pair)'),[Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global ProbeRollbackFailure := false
try {
    AssertEmpty(FileExist(SettingsDatabasePath), "fresh settings created")
    AssertEmpty(DefaultReactionIntervalMs = 200, "new settings default to 200ms start interval")
    AssertEmpty(InStr(SettingsDatabasePath, "\data\") && !FileExist(A_ScriptDir "\settings.ini"), "settings live only in data directory")
    legacyPath := A_ScriptDir "\settings.ini"
    FileAppend("[General]`nCount=99`n", legacyPath)
    beforeMigration := FileRead(SettingsDatabasePath,"RAW")
    ReloadAppSettings()
    AssertEmpty(SameFileBytes(FileRead(SettingsDatabasePath,"RAW"),beforeMigration) && FileExist(legacyPath), "reload ignores legacy root settings and preserves existing database")
    FileDelete(legacyPath)
    FileAppend("{}", A_ScriptDir "\reaction_selectors.json")
    ReloadAppSettings()
    AssertEmpty(!FileExist(AppDataDirectory "\reaction_selectors.json") && FileExist(A_ScriptDir "\reaction_selectors.json"), "legacy root placement is ignored")
    AssertEmpty(Profiles.Length=0 && SharedDanmakuItems.Length=0, "fresh install has no sample data")
    AssertEmpty(!PaletteInsert.Enabled, "empty palette cannot input")
    BuildManagement()
    AssertEmpty((GetEditingProfileId() = "") && ManagementTarget.Value=1, "empty management starts with shared library")
    OpenDanmakuEditor(true)
    AssertEmpty(!!DanmakuEditorWindow, "shared editor needs no author")
    CloseDanmakuEditor()
    state := CreateSettingsSnapshot()
    state.Profiles.Push({Id:NewRecordId(),Name:"first",Channel:"",Items:[]})
    CommitLibraryChange(state,"add")
    AssertEmpty(Profiles.Length=1 && InputProfileId="","first added author does not steal input selection")
    UndoLibraryChange()
    AssertEmpty(Profiles.Length=0,"undo returns to empty state")
    ReloadAppSettings()
    AssertEmpty(Profiles.Length=0,"empty state persists")
    brokenPath := AppDataDirectory "\broken.ini"
    FileAppend("[General]`nCount=not-an-integer`n", brokenPath)
    invalidMessage := ""
    try ReadLegacySettings(brokenPath)
    catch as failure
        invalidMessage := failure.Message
    AssertEmpty(InStr(invalidMessage, "[General] Count"), "invalid settings identify exact key")
    backup := BackupSettingsForReset(brokenPath)
    AssertEmpty(FileExist(backup) && !FileExist(brokenPath) && InStr(FileRead(backup), "not-an-integer"), "reset preserves corrupt original")
    resetDirectory := A_ScriptDir "\recovery-target"
    DirCreate(resetDirectory)
    resetPath := resetDirectory "\settings.db"
    resetFiles := ["settings.db","settings.db-journal","settings.db-wal","settings.db-shm","settings.ini","reaction_selectors.json"]
    FileAppend("current legacy",AppDataDirectory "\settings.ini")
    FileAppend("current registration",AppDataDirectory "\reaction_selectors.json")
    for name in resetFiles
        FileAppend(name,resetDirectory "\" name)
    for blockRollback in [false,true] {
        ProbeRollbackFailure := blockRollback
        ; Lock the last file so every preceding move must be rolled back.
        locked := DllCall("CreateFileW","Str",resetDirectory "\reaction_selectors.json","UInt",0x80000000,"UInt",0,"Ptr",0,"UInt",3,"UInt",0,"Ptr",0,"Ptr")
        AssertEmpty(locked != -1,"reset failure fixture holds the final file exclusively")
        try {
            resetError := ""
            try BackupSettingsForReset(resetPath)
            catch as failure
                resetError := failure.Message
            AssertEmpty(resetError != "","reset aborts when a source cannot be moved")
        } finally DllCall("CloseHandle","Ptr",locked)
        remainingBackups := []
        Loop Files resetDirectory "\*.backup-*"
            remainingBackups.Push(A_LoopFileFullPath)
        if blockRollback {
            AssertEmpty(remainingBackups.Length=1 && FileRead(remainingBackups[1])="settings.ini","rollback failure preserves the unmoved backup")
            AssertEmpty(InStr(resetError,remainingBackups[1]) && InStr(resetError,resetDirectory "\settings.ini"),"rollback failure identifies saved file and original destination")
            AssertEmpty(!FileExist(resetDirectory "\settings.ini"),"failed restoration is not reported as complete")
            FileMove(remainingBackups[1],resetDirectory "\settings.ini",false)
        } else
            AssertEmpty(remainingBackups.Length=0,"successful rollback leaves no partial backup set")
        for name in resetFiles
            AssertEmpty(FileExist(resetDirectory "\" name) && FileRead(resetDirectory "\" name)=name,"reset preserves every original despite intermediate failures")
    }
    ProbeRollbackFailure := false
    backup := BackupSettingsForReset(resetPath)
    suffix := SubStr(backup,StrLen(resetPath)+1)
    for name in resetFiles {
        saved := name = "settings.ini" || name = "reaction_selectors.json" ? resetDirectory "\" name suffix : backup SubStr(name,StrLen("settings.db")+1)
        AssertEmpty(!FileExist(resetDirectory "\" name) && FileExist(saved) && FileRead(saved)=name,"reset preserves target files and sidecar names")
    }
    AssertEmpty(FileExist(AppDataDirectory "\settings.ini") && FileExist(AppDataDirectory "\reaction_selectors.json"),"reset never moves legacy files from a different directory")
    FileDelete(AppDataDirectory "\settings.ini")
    FileDelete(AppDataDirectory "\reaction_selectors.json")
    FileAppend("[General]`nCount=1.5`n", brokenPath)
    rejectedFraction := false
    try ReadLegacySettings(brokenPath)
    catch
        rejectedFraction := true
    AssertEmpty(rejectedFraction, "fractional count rejected instead of truncating records")
    AssertEmpty(AppSourceStatus()="起動時のソースと一致","startup source matches")
    versionFile := A_ScriptDir "\VERSION", originalVersion := FileRead(versionFile,"RAW")
    try {
        FileAppend("test",versionFile)
        AssertEmpty(AppSourceStatus()="更新あり：再起動で反映","changed source requests restart")
    } finally {
        FileDelete(versionFile)
        FileAppend(originalVersion,versionFile)
    }
    AssertEmpty(AppSourceStatus()="起動時のソースと一致","restored source matches")
    global RestartChecks := 0
    RuntimePorts.Restart := () => CountRestart()
    ActiveEditorDialog := {Label:"unsaved editor"}
    AssertEmpty(!RestartApplication() && !RestartChecks,"unsaved editor blocks restart")
    ActiveEditorDialog := false, IsBrowserOperationBusy := true
    AssertEmpty(!RestartApplication() && !RestartChecks,"browser operation blocks restart")
    IsBrowserOperationBusy := false
    ActiveReactionJob := CreateReactionJob({Mode:"queued"})
    AssertEmpty(!RestartApplication() && !RestartChecks,"queued reaction blocks restart")
    ActiveReactionJob := 0
    AssertEmpty(RestartApplication() && RestartChecks=1,"idle restart uses the production gate")
    RuntimePorts.Restart := 0
    diagnostics := BuildDiagnosticReport(ReadDiagnosticSnapshot())
    AssertEmpty(InStr(diagnostics, AppVersion) && !InStr(diagnostics, A_ScriptDir), "diagnostics include version without private path")
    snapshot := ReadDiagnosticSnapshot()
    snapshotReport := BuildDiagnosticReport(snapshot)
    AssertEmpty(snapshot.Duration = "—（未実行）" && InStr(snapshot.Worker,"必要なとき"), "idle diagnostics explain normal waiting state")
    RecordBrowserOperation({Mode:"verify_input",State:"wrong_input",Duration:42})
    AssertEmpty(BuildDiagnosticReport(snapshot) = snapshotReport, "copy uses the captured snapshot")
    diagnosticPanel := CreateDiagnosticPanel()
    for control in diagnosticPanel.Window {
        control.GetPos(&x, &y, &w, &h)
        AssertEmpty(x >= 20 && x+w <= 620 && y >= 14 && y+h <= 670, "diagnostic controls fit panel")
    }
    foundResult := false
    for control in diagnosticPanel.Window
        if control.Type = "Text" && control.Text = "入力欄を確認できませんでした"
            foundResult := true
    AssertEmpty(foundResult, "diagnostic panel uses readable result labels")
    RecordBrowserOperation({Mode:"verify_input",State:"ok",Duration:12})
    diagnosticPanel.Refresh.Call()
    foundResult := false
    for control in diagnosticPanel.Window
        if control.Type = "Text" && control.Text = "確認できました"
            foundResult := true
    AssertEmpty(foundResult, "diagnostic refresh replaces displayed result")
    for operation in [["chat_focus","focused"],["verify_chat","ok"],["reactions_show","hovered"]] {
        RecordBrowserOperation({Mode:operation[1],State:operation[2],Duration:10})
        pageDiagnostic := ReadDiagnosticSnapshot()
        AssertEmpty(pageDiagnostic.ModeCode=operation[1] && pageDiagnostic.StateCode=operation[2],"page actions have readable diagnostic labels")
    }
    FileAppend("PASS: empty initialization, UI, shared library, profile lifecycle and reload`n", "*")
    ExitApp(0)
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n", "*")
    ExitApp(1)
}
ProbeResetRestore(pair) {
    global ProbeRollbackFailure
    if ProbeRollbackFailure && RegExMatch(pair[1],"\\settings\.ini$")
        throw Error("Injected reset rollback failure")
    FileMove(pair[2],pair[1],false)
}
CountRestart() {
    global RestartChecks
    RestartChecks++
}
AssertEmpty(condition, message) {
    if !condition
        throw Error(message)
}
SameFileBytes(left,right) {
    return left.Size=right.Size && (!left.Size || DllCall("msvcrt\memcmp","Ptr",left,"Ptr",right,"UPtr",left.Size,"CDecl Int")=0)
}
'@
Invoke-AppTest -Runtime $release -Body $tests
