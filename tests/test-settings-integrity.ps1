$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime

$fixture = $release
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$tests = @'
OnExit(StopBrowserWorker)
global IntegrityChecks := 0
try {
    path := AppDataDirectory "\integrity.ini"
    for fixture in [
        ["", "[General] Count"],
        ["[General]`nSchema=3`n[Profile1]`nName=kept`nCount=1`nText1=important`n[CommonDanmaku]`nCount=0", "[General] Count"],
        ["[General]`nSchema=3`nCount=1`n[Profile1]`nName=kept`nText1=important", "[Profile1] Count"],
        ["[General]`nCount=0`n[Profile1]`nName=kept`nCount=1`nText1=important", "Profile1"],
        ["[General]`nCount=1`n[Profile1]`nName=kept`nCount=0`nText1=important", "Text1"],
        ["[General]`nCount=0`n[CommonDanmaku]`nText1=important", "[CommonDanmaku] Count"],
        ["[General]`nCount=0`n[CommonDanmaku]`nCount=0`nText1=important", "Text1"],
        ["[General]`nCount=0`n[CommonDanmaku]`nCount=-1", "件数"],
        ["[General]`nCount=0`n[CommonDanmaku]`nCount=0`nLabel1=kept", "Label1"],
        ["[General]`nCount=0`n[CommonDanmaku]`nCount=0`nSlot1=1", "Slot1"]] {
        if FileExist(path)
            FileDelete(path)
        FileAppend(fixture[1],path,"UTF-16")
        original := FileRead(path)
        message := ""
        try ReadLegacySettings(path)
        catch as failure
            message := failure.Message
        AssertEmpty(InStr(message,fixture[2]),"corruption identifies offending field: " fixture[2])
        AssertEmpty(FileRead(path)==original,"rejection preserves original")
    }
    FileDelete(path)
    state := ReadLegacySettings(path)
    AssertEmpty(state.Profiles.Length=0,"missing file initializes empty state")
    SaveSettings(state,path ".db")
    AssertEmpty(LoadSettings(path ".db").Profiles.Length=0,"new complete empty file reloads normally")
    FileAppend("[General]`nCount=1`n[Profile1]`nName=legacy`nCount=1`nText1=preserved",path,"UTF-16")
    state := ReadLegacySettings(path)
    AssertEmpty(state.Profiles[1].Items[1].Text="preserved","legacy without common section preserves content")
    SaveSettings(state,path ".db")
    AssertEmpty(LoadSettings(path ".db").Profiles[1].Items[1].Text="preserved","legacy round trip")
    BuildManagement()
    AssertEmpty(!ManagementStatus.Visible && ManagementStatus.Text="","empty notification is hidden")
    SetManagementNotice("保存できませんでした。詳細")
    ShowManagement(1)
    AssertEmpty(ManagementStatus.Visible && InStr(ManagementStatus.Text,"通知：保存できませんでした"),"failure notification is visible and labelled")
    SetManagementNotice("")
    AssertEmpty(!ManagementStatus.Visible,"cleared notification is hidden")
    FileAppend("PASS: " IntegrityChecks " settings integrity and notification checks`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n","**")
    ExitApp(1)
}
AssertEmpty(condition, message) {
    global IntegrityChecks
    IntegrityChecks++
    if !condition
        throw Error(message)
}
'@
$source = [IO.File]::ReadAllText((Join-Path $release 'main.ahk'))
$source = $source.Replace('OnExit(StopBrowserWorker)', $tests)
[IO.File]::WriteAllText((Join-Path $fixture 'main.ahk'), $source, [Text.UTF8Encoding]::new($true))
$run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + (Join-Path $fixture 'main.ahk') + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -RedirectStandardError (Join-Path $fixture 'stderr.txt')
$null = $run.Handle
if (!$run.WaitForExit(15000)) { Stop-Process -Id $run.Id; throw 'Settings integrity test timed out' }
Get-Content -LiteralPath (Join-Path $fixture 'stdout.txt'),(Join-Path $fixture 'stderr.txt')
if ($run.ExitCode -ne 0) { throw "Settings integrity test failed: $fixture" }
