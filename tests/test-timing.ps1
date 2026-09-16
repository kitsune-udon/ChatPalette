$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$path = Join-Path $release 'src\reactions\reaction_controller.ahk'
$source = [IO.File]::ReadAllText($path).Replace('WinActive("ahk_id " job.Window)','true').Replace('SetReactionTimingPrecision(enabled) {','RealSetReactionTimingPrecision(enabled) {')
[IO.File]::WriteAllText($path,$source,[Text.UTF8Encoding]::new($true))
$path = Join-Path $release 'src\browser\browser_service.ahk'
$source = [IO.File]::ReadAllText($path).Replace('RequestBrowserOperation(hwnd,','UnusedBrowserOperation(hwnd,')
[IO.File]::WriteAllText($path,$source,[Text.UTF8Encoding]::new($true))
$tests = @'
OnExit(StopBrowserWorker)
global TimingChecks := 0, TimingMode := "", PrecisionEvents := ""
try {
    AssertTiming(ReactionIntervalLabels()[5]="150 ms" && ReactionIntervalLabels()[7]="250 ms", "new choices and labels")
    for mode in ["normal","error","cancel","unavailable","nowait"] {
        TimingMode := mode, PrecisionEvents := ""
        job := {Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:mode="nowait" ? 0 : 100}
        ActiveReactionJob := job
        ReactionSendNext()
        expected := mode="nowait" ? "" : (mode="unavailable" ? "B" : "BE")
        AssertTiming(PrecisionEvents=expected,"balanced precision: " mode)
        AssertTiming(!ActiveReactionJob,"job finished: " mode)
    }
    TimingMode := "random"
    SaveReactionDefaults(CreateReactionOptions(RandomReactionKind,10,200,ReactionShortcut))
    restored := ReadSettingsFile(SettingsFilePath)
    AssertTiming(restored.DefaultReactionKind=RandomReactionKind && restored.DefaultReactionIntervalMs=200,"random persistence")
    global RandomChoices := []
    ActiveReactionJob := {Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:RandomReactionKind,Completed:0,Total:10,Cancelled:false,Interval:0}
    randomJob := ActiveReactionJob
    ReactionSendNext()
    AssertTiming(randomJob.Completed=10 && randomJob.Choice=RandomReactionKind && RandomChoices.Length=10,"random resolves per operation")
    for choice in RandomChoices
        AssertTiming(choice>=1 && choice<=5,"worker receives concrete kind")
    Loop 5
        AssertTiming(ResolveReactionKind(A_Index)=A_Index,"fixed kind unchanged")
    TimingMode := "normal"
    for interval in [150,250] {
        PrecisionEvents := ""
        ActiveReactionJob := {Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:interval}
        job := ActiveReactionJob
        ReactionSendNext()
        AssertTiming(job.Completed=2 && PrecisionEvents="BE","new interval runs: " interval)
    }
    FileAppend("PASS: " TimingChecks " timing lifecycle checks`n", "*")
    TimingMode := "exit", PrecisionEvents := ""
    ActiveReactionJob := {Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:100}
    ReactionSendNext()
    throw Error("Exit did not terminate")
} catch as e {
    FileAppend(e.Message "`n", "**")
    ExitApp(1)
}
AssertTiming(value,label) {
    global TimingChecks
    TimingChecks++
    if !value
        throw Error(label)
}
SetReactionTimingPrecision(enabled) {
    global PrecisionEvents
    PrecisionEvents .= enabled ? "B" : "E"
    if TimingMode="exit" && !enabled
        FileAppend(PrecisionEvents,A_ScriptDir "\exit-release.txt")
    return enabled && TimingMode!="unavailable"
}
RequestBrowserOperation(hwnd,mode:="resolve",video:="",extra:="") {
    if TimingMode="random" {
        if !RegExMatch(extra,"^Reaction=([1-5])\n$",&match)
            throw Error("Invalid random worker payload")
        RandomChoices.Push(Integer(match[1]))
    }
    if TimingMode="error"
        throw Error("injected failure")
    if TimingMode="exit"
        ExitApp()
    if TimingMode="cancel"
        SetTimer(CancelReaction,-20)
    return {State:"operated"}
}
'@
$path = Join-Path $release 'main.ahk'
$source = [IO.File]::ReadAllText($path).Replace('OnExit(StopBrowserWorker)',$tests)
[IO.File]::WriteAllText($path,$source,[Text.UTF8Encoding]::new($true))
$run = Start-Process (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut',('"'+$path+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $release 'out.txt') -RedirectStandardError (Join-Path $release 'err.txt')
$null = $run.Handle
if (!$run.WaitForExit(15000)) { $run.Kill(); throw 'Timing test timeout' }
Get-Content (Join-Path $release 'out.txt'),(Join-Path $release 'err.txt')
if ($run.ExitCode -ne 0) { throw 'Timing checks failed' }
if ([IO.File]::ReadAllText((Join-Path $release 'exit-release.txt')) -ne 'BE') { throw 'Exit precision cleanup failed' }
Write-Output 'PASS: precision released on application exit'
