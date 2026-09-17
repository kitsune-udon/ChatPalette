$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$tests = @'
OnExit(StopBrowserWorker)
try {
    AssertEmpty(FileExist(SettingsDatabasePath), "fresh settings created")
    AssertEmpty(DefaultReactionIntervalMs = 200, "new settings default to 200ms start interval")
    AssertEmpty(InStr(SettingsDatabasePath, "\data\") && !FileExist(A_ScriptDir "\settings.ini"), "settings live only in data directory")
    legacyPath := A_ScriptDir "\settings.ini"
    FileAppend("[General]`nCount=99`n", legacyPath)
    beforeMigration := FileRead(SettingsDatabasePath,"RAW")
    InitializeDataDirectory(AppDataDirectory)
    AssertEmpty(SameFileBytes(FileRead(SettingsDatabasePath,"RAW"),beforeMigration) && FileExist(legacyPath), "migration never overwrites existing data")
    FileDelete(legacyPath)
    FileAppend("{}", A_ScriptDir "\reaction_selectors.json")
    InitializeDataDirectory(AppDataDirectory)
    AssertEmpty(!FileExist(AppDataDirectory "\reaction_selectors.json") && FileExist(A_ScriptDir "\reaction_selectors.json"), "legacy root placement is ignored")
    AssertEmpty(Profiles.Length=0 && SharedDanmakuItems.Length=0, "fresh install has no sample data")
    AssertEmpty(!PaletteInsert.Enabled, "empty palette cannot input")
    BuildManagement()
    AssertEmpty(EditScopeShared && ManagementTarget.Value=1, "empty management starts with shared library")
    OpenDanmakuEditor(true)
    AssertEmpty(!!DanmakuEditorWindow, "shared editor needs no author")
    CloseDanmakuEditor()
    state := CreateSettingsSnapshot()
    state.Profiles.Push({Id:NewRecordId(),Name:"first",Channel:"",Items:[]})
    CommitLibraryChange(state,"add")
    AssertEmpty(Profiles.Length=1 && InputProfileIndex=0,"first added author does not steal input selection")
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
    FileAppend("[General]`nCount=1.5`n", brokenPath)
    rejectedFraction := false
    try ReadLegacySettings(brokenPath)
    catch
        rejectedFraction := true
    AssertEmpty(rejectedFraction, "fractional count rejected instead of truncating records")
    diagnostics := BuildDiagnosticReport()
    AssertEmpty(InStr(diagnostics, AppVersion) && !InStr(diagnostics, A_ScriptDir), "diagnostics include version without private path")
    snapshot := ReadDiagnosticSnapshot()
    snapshotReport := BuildDiagnosticReport(snapshot)
    AssertEmpty(snapshot.Duration = "—（未実行）" && InStr(snapshot.Worker,"必要なとき"), "idle diagnostics explain normal waiting state")
    LastBrowserOperation := {Mode:"verify_input",State:"wrong_input",Duration:42}
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
    LastBrowserOperation := {Mode:"verify_input",State:"ok",Duration:12}
    diagnosticPanel.Refresh.Call()
    foundResult := false
    for control in diagnosticPanel.Window
        if control.Type = "Text" && control.Text = "確認できました"
            foundResult := true
    AssertEmpty(foundResult, "diagnostic refresh replaces displayed result")
    FileAppend("PASS: empty initialization, UI, shared library, profile lifecycle and reload`n", "*")
    ExitApp(0)
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n", "*")
    ExitApp(1)
}
AssertEmpty(condition, message) {
    if !condition
        throw Error(message)
}
SameFileBytes(left,right) {
    return left.Size=right.Size && (!left.Size || DllCall("msvcrt\memcmp","Ptr",left,"Ptr",right,"UPtr",left.Size,"CDecl Int")=0)
}
'@
$source = [IO.File]::ReadAllText((Join-Path $release 'main.ahk'))
$source = $source.Replace('OnExit(StopBrowserWorker)', $tests)
[IO.File]::WriteAllText((Join-Path $fixture 'main.ahk'), $source, [Text.UTF8Encoding]::new($true))
$run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + (Join-Path $fixture 'main.ahk') + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt')
$null = $run.Handle
if (!$run.WaitForExit(15000)) { Stop-Process -Id $run.Id; throw 'Empty settings test timed out' }
Get-Content -LiteralPath (Join-Path $fixture 'stdout.txt'),(Join-Path $fixture 'stderr.txt')
if ($run.ExitCode -ne 0) { throw "Empty settings test failed: $fixture" }
