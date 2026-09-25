# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$tests = @'
OnExit(StopBrowserWorker)
global TimingChecks := 0, TimingMode := "", PrecisionEvents := ""
try {
    AssertTiming(ReactionIntervalLabels()[5]="150 ms" && ReactionIntervalLabels()[7]="250 ms", "new choices and labels")
    for mode in ["normal","error","cancel","unavailable","nowait","sync_failed","unknown"] {
        TimingMode := mode, PrecisionEvents := ""
        job := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:mode="nowait" ? 0 : 100})
        ActiveReactionJob := job
        ReactionSendNext()
        expected := mode="nowait" ? "" : (mode="unavailable" ? "B" : "BE")
        AssertTiming(PrecisionEvents=expected,"balanced precision: " mode)
        AssertTiming(!ActiveReactionJob,"job finished: " mode)
        expectedCount := (mode="error" || mode="sync_failed" || mode="unknown") ? 0 : (mode="cancel" ? 1 : 2)
        AssertTiming(job.Completed=expectedCount,"exact completed count on exit: " mode)
        if mode="sync_failed" || mode="unknown"
            AssertTiming(LastReactionResult.Reason=mode,"failure reason preserved: " mode)
    }
    TimingMode := "random"
    SaveReactionDefaults(CreateReactionOptions(RandomReactionKind,10,200,ShortcutKeys["reaction"]))
    restored := LoadSettings(SettingsDatabasePath)
    AssertTiming(restored.DefaultReactionKind=RandomReactionKind && restored.DefaultReactionIntervalMs=200,"random persistence")
    global RandomChoices := []
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:RandomReactionKind,Completed:0,Total:10,Cancelled:false,Interval:0})
    randomJob := ActiveReactionJob
    ReactionSendNext()
    AssertTiming(randomJob.Completed=10 && randomJob.Choice=RandomReactionKind && RandomChoices.Length=10,"random resolves per operation")
    for choice in RandomChoices
        AssertTiming(choice>=1 && choice<=5,"worker receives concrete kind")
    Loop 5
        AssertTiming(ResolveReactionKind(A_Index)=A_Index,"fixed kind unchanged")
    measured := CreateReactionJob({StartedAt:1000,Completed:0,Total:3,Cancelled:false})
    ActiveReactionJob := measured
    ApplyReactionResult(measured,{State:"operated"})
    AssertTiming(!InStr(ReactionExecutionStatus.Message,"平均開始間隔"),"single operation does not display an average interval")
    measured.StartedAt := 1200
    ApplyReactionResult(measured,{State:"operated"})
    measured.StartedAt := 1400
    ApplyReactionResult(measured,{State:"operated"})
    AssertTiming(InStr(LastReactionResult.Message,"平均開始間隔 200 ms"),"start timestamps determine mean independently of response time")
    TimingMode := "normal"
    for interval in [150,250] {
        PrecisionEvents := ""
        ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:interval})
        job := ActiveReactionJob
        ReactionSendNext()
        AssertTiming(job.Completed=2 && PrecisionEvents="BE","new interval runs: " interval)
    }
    FileAppend("PASS: " TimingChecks " timing lifecycle checks`n", "*")
    TimingMode := "exit", PrecisionEvents := ""
    ActiveReactionJob := CreateReactionJob({Mode:"reaction_send",Window:123,Video:"abcdefghijk",Choice:1,Completed:0,Total:2,Cancelled:false,Interval:100})
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
FixtureTimingPrecision(enabled) {
    global PrecisionEvents
    PrecisionEvents .= enabled ? "B" : "E"
    if TimingMode="exit" && !enabled
        FileAppend(PrecisionEvents,A_ScriptDir "\exit-release.txt")
    return enabled && TimingMode!="unavailable"
}
FixtureBrowserOperation(hwnd,mode:="resolve",video:="",extra:="") {
    if TimingMode="random" {
        if !RegExMatch(extra,"^Reaction=([1-5])\n$",&match)
            throw Error("Invalid random worker payload")
        RandomChoices.Push(Integer(match[1]))
    }
    if TimingMode="sync_failed" || TimingMode="unknown"
        return {State:TimingMode}
    if TimingMode="error"
        throw Error("injected failure")
    if TimingMode="exit"
        ExitApp()
    if TimingMode="cancel"
        SetTimer(CancelReaction,-20)
    return {State:"operated"}
}
'@
Invoke-AppTest -Runtime $release -Body $tests -Setup @'
RuntimePorts.Foreground := (hwnd) => hwnd=123
RuntimePorts.TimingPrecision := FixtureTimingPrecision
RuntimePorts.BrowserRequest := FixtureBrowserOperation
'@
if ([IO.File]::ReadAllText((Join-Path $release 'exit-release.txt')) -ne 'BE') { throw 'Exit precision cleanup failed' }
Write-Output 'PASS: precision released on application exit'
