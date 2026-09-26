# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$tests = @'
Assert(FileExist(SettingsDatabasePath), "fresh settings created")
Assert(DefaultReactionIntervalMs = 200, "new settings default to 200ms start interval")
Assert(InStr(SettingsDatabasePath, "\data\"), "settings live in data directory")
beforeReload := FileRead(SettingsDatabasePath,"RAW")
ReloadAppSettings()
Assert(SameFileBytes(FileRead(SettingsDatabasePath,"RAW"),beforeReload), "reload preserves existing database")
Assert(Profiles.Length=0 && SharedDanmakuItems.Length=0, "fresh install has no sample data")
Assert(!PaletteInsert.Enabled, "empty palette cannot input")
BuildManagement()
Assert((GetEditingProfileId() = "") && ManagementTarget.Value=1, "empty management starts with shared library")
OpenDanmakuEditor(true)
Assert(!!ActiveEditorDialog, "shared editor needs no author")
CloseDanmakuEditor(ActiveEditorDialog.Window)
state := CreateTestLibrarySnapshot()
state.Profiles.Push({Id:NewRecordId(),Name:"first",Channel:"",Items:[]})
CommitTestLibraryChange(state,"add")
Assert(Profiles.Length=1 && InputProfileId="","first added author does not steal input selection")
UndoLibraryChange()
Assert(Profiles.Length=0,"undo returns to empty state")
ReloadAppSettings()
Assert(Profiles.Length=0,"empty state persists")
Assert(AppSourceStatus()="起動時のソースと一致","startup source matches")
versionFile := A_ScriptDir "\VERSION", originalVersion := FileRead(versionFile,"RAW")
try {
    FileAppend("test",versionFile)
    Assert(AppSourceStatus()="更新あり：再起動で反映","changed source requests restart")
} finally {
    FileDelete(versionFile)
    FileAppend(originalVersion,versionFile)
}
Assert(AppSourceStatus()="起動時のソースと一致","restored source matches")
global RestartChecks := 0
RuntimePorts.Restart := () => CountRestart()
ActiveEditorDialog := {Label:"unsaved editor"}
Assert(!RestartApplication() && !RestartChecks,"unsaved editor blocks restart")
ActiveEditorDialog := false, IsBrowserOperationBusy := true
Assert(!RestartApplication() && !RestartChecks,"browser operation blocks restart")
IsBrowserOperationBusy := false
ActiveReactionJob := CreateReactionJob({Mode:"queued"})
Assert(!RestartApplication() && !RestartChecks,"queued reaction blocks restart")
ActiveReactionJob := 0
Assert(RestartApplication() && RestartChecks=1,"idle restart uses the production gate")
RuntimePorts.Restart := 0
diagnostics := BuildDiagnosticReport(ReadDiagnosticSnapshot())
Assert(InStr(diagnostics, AppVersion) && !InStr(diagnostics, A_ScriptDir), "diagnostics include version without private path")
snapshot := ReadDiagnosticSnapshot()
snapshotReport := BuildDiagnosticReport(snapshot)
Assert(snapshot.Duration = "—（未実行）" && InStr(snapshot.Worker,"必要なとき"), "idle diagnostics explain normal waiting state")
RecordBrowserOperation({Mode:"verify_input",State:"wrong_input",Duration:42})
Assert(BuildDiagnosticReport(snapshot) = snapshotReport, "copy uses the captured snapshot")
diagnosticPanel := CreateDiagnosticPanel()
for control in diagnosticPanel.Window {
    control.GetPos(&x, &y, &w, &h)
    Assert(x >= 20 && x+w <= 620 && y >= 14 && y+h <= 670, "diagnostic controls fit panel")
}
foundResult := false
for control in diagnosticPanel.Window
    if control.Type = "Text" && control.Text = "入力欄を確認できませんでした"
        foundResult := true
Assert(foundResult, "diagnostic panel uses readable result labels")
RecordBrowserOperation({Mode:"verify_input",State:"ok",Duration:12})
diagnosticPanel.Refresh.Call()
foundResult := false
for control in diagnosticPanel.Window
    if control.Type = "Text" && control.Text = "確認できました"
        foundResult := true
Assert(foundResult, "diagnostic refresh replaces displayed result")
for operation in [["chat_focus","focused"],["verify_chat","ok"],["reactions_show","hovered"]] {
    RecordBrowserOperation({Mode:operation[1],State:operation[2],Duration:10})
    pageDiagnostic := ReadDiagnosticSnapshot()
    Assert(pageDiagnostic.ModeCode=operation[1] && pageDiagnostic.StateCode=operation[2],"page actions have readable diagnostic labels")
}
FileAppend("PASS: empty initialization, UI, shared library, profile lifecycle and reload`n", "*")
ExitApp(0)
CountRestart() {
    global RestartChecks
    RestartChecks++
}
SameFileBytes(left,right) {
    return left.Size=right.Size && (!left.Size || DllCall("msvcrt\memcmp","Ptr",left,"Ptr",right,"UPtr",left.Size,"CDecl Int")=0)
}
'@
Invoke-AppTest -Runtime $release -Body $tests
