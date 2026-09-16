$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$tests = @'
OnExit(StopBrowserWorker)
try {
    AssertEmpty(FileExist(SettingsFilePath), "fresh settings created")
    AssertEmpty(InStr(SettingsFilePath, "\data\") && !FileExist(A_ScriptDir "\settings.ini"), "settings live only in data directory")
    legacyPath := A_ScriptDir "\settings.ini"
    FileAppend("[General]`nCount=99`n", legacyPath)
    beforeMigration := FileRead(SettingsFilePath)
    InitializeDataDirectory(AppDataDirectory)
    AssertEmpty(FileRead(SettingsFilePath) = beforeMigration && FileExist(legacyPath), "migration never overwrites existing data")
    FileDelete(legacyPath)
    FileAppend("{}", A_ScriptDir "\reaction_selectors.json")
    InitializeDataDirectory(AppDataDirectory)
    AssertEmpty(FileExist(AppDataDirectory "\reaction_selectors.json") && !FileExist(A_ScriptDir "\reaction_selectors.json"), "legacy selectors moved to data")
    AssertEmpty(Profiles.Length = 0 && SelectedProfileIndex = 0 && SharedDanmakuItems.Length = 0, "no sample data")
    NavigatePanel(3)
    AssertEmpty(!ProfileReactionDraft && !HomeInput.Enabled && !HomeCommonInput.Enabled && !ReactionScope.Enabled, "empty UI safe: " (!!ProfileReactionDraft) " / " HomeInput.Enabled " / " HomeCommonInput.Enabled " / " ReactionScope.Enabled)
    AssertEmpty(InStr(HomeAuthor.Text, "未登録") && InStr(ReactionSettingsInfo.Text, "ハート"), "empty state and shared reaction displayed")
    emptyManager := BuildProfileManager()
    for control in emptyManager {
        if control.Type = "Button" && (control.Text = "名前変更" || control.Text = "この投稿者を削除…" || control.Text = "弾幕を追加する…" || control.Text = "関連付ける")
            AssertEmpty(!control.Enabled, "profile-only manager action disabled")
    }
    emptyManager.Destroy()
    AutoMode := false
    AssertEmpty(ResolveReactionChoice(0, "") = ReactionDefault, "manual mode uses shared reaction without profile")
    InsertProfileDanmaku(1, 0)
    SetLibraryScope(true)
    OpenDanmakuEditor(true)
    AssertEmpty(!!DanmakuEditorWindow, "shared editor opens without profile")
    CloseDanmakuEditor()
    SaveLibraryTargets([SharedDanmakuItems], [[{Name:"共通テスト",Text:"test"}]])
    AssertEmpty(SharedDanmakuItems.Length = 1, "shared items can be saved without profile")
    undo := ExecuteProfileCommand("add", 0, "最初の投稿者")
    RefreshProfiles()
    AssertEmpty(Profiles.Length = 1 && Profiles[1].Items.Length = 0 && !!ProfileReactionDraft && ReactionScope.Enabled, "first profile added without sample danmaku")
    ExecuteProfileCommand("undo", 1, "", undo)
    RefreshProfiles()
    AssertEmpty(Profiles.Length = 0 && !ProfileReactionDraft, "undo first addition restores empty state")
    ExecuteProfileCommand("add", 0, "削除テスト")
    undo := ExecuteProfileCommand("delete", 1)
    RefreshProfiles()
    AssertEmpty(Profiles.Length = 0 && SelectedProfileIndex = 0, "last deletion leaves zero profiles")
    ExecuteProfileCommand("undo", 0, "", undo)
    AssertEmpty(Profiles.Length = 1, "undo from empty restores deleted profile")
    ExecuteProfileCommand("delete", 1)
    SaveLibraryTargets([SharedDanmakuItems], [[]])
    ReloadAppSettings()
    RefreshProfiles()
    AssertEmpty(Profiles.Length = 0 && SharedDanmakuItems.Length = 0, "saved empty settings remain empty after reload")
    brokenPath := AppDataDirectory "\broken.ini"
    FileAppend("[General]`nCount=not-an-integer`n", brokenPath)
    invalidMessage := ""
    try ReadSettingsFile(brokenPath)
    catch as failure
        invalidMessage := failure.Message
    AssertEmpty(InStr(invalidMessage, "[General] Count"), "invalid settings identify exact key")
    backup := BackupSettingsForReset(brokenPath)
    AssertEmpty(FileExist(backup) && !FileExist(brokenPath) && InStr(FileRead(backup), "not-an-integer"), "reset preserves corrupt original")
    diagnostics := BuildDiagnosticReport()
    AssertEmpty(InStr(diagnostics, AppVersion) && !InStr(diagnostics, A_ScriptDir), "diagnostics include version without private path")
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
'@
$source = [IO.File]::ReadAllText((Join-Path $release 'main.ahk'))
$source = $source.Replace('OnExit(StopBrowserWorker)', $tests)
[IO.File]::WriteAllText((Join-Path $fixture 'main.ahk'), $source, [Text.UTF8Encoding]::new($true))
$run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + (Join-Path $fixture 'main.ahk') + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt')
$null = $run.Handle
if (!$run.WaitForExit(15000)) { Stop-Process -Id $run.Id; throw 'Empty settings test timed out' }
Get-Content -LiteralPath (Join-Path $fixture 'stdout.txt'),(Join-Path $fixture 'stderr.txt')
if ($run.ExitCode -ne 0) { throw "Empty settings test failed: $fixture" }
