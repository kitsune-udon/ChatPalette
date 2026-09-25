# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
# Re-entry while releasing controls or rendering a final result must preserve the successor.
$resultRuntime=New-TestRuntime
$needle="RefreshOperationControls() {"
Edit-TestSource $resultRuntime 'src/ui/ui_runtime.ahk' $needle ($needle+"`r`n    ProbeResultPublication()")
$resultTests=@'
BuildManagement()
global ResultChecks := 0, ResultArmed := false, ResultPoint := "", ResultCase := ""
global ResultReplacement := 0, ResultPreserved := 0
for point in ["release","render","release-finished","render-finished"] {
    for scenario in ["completed","unknown","cancelled","countdown","quick"] {
        ResultPoint := point, ResultCase := scenario
        job := CreateReactionJob({Mode:scenario="quick" ? "queued" : scenario="countdown" ? "reaction_capture" : "reaction_send",
            Window:123,Video:"abcdefghijk",Total:1,Interval:0,Remaining:0})
        ActiveReactionJob := job
        SetReactionStatus("original pending")
        ResultReplacement := 0, ResultArmed := true
        if scenario="cancelled"
            CancelReaction()
        else if scenario="countdown"
            ReactionCountdown()
        else if scenario="quick"
            QuickReaction()
        else
            RunReactionSendLoop(job)
        label := point "/" scenario, finished := !!InStr(point,"finished")
        expectedMessage := finished ? "successor finished" : "successor pending"
        CheckResult(!ResultArmed && ResultReplacement && (finished ? !ActiveReactionJob : ActiveReactionJob=ResultReplacement),"successor owns execution: " label)
        CheckResult(job.Phase="finished" && ResultReplacement.Phase=(finished ? "finished" : "queued") && ResultReplacement.Completed=0,"finished attempt does not mutate successor: " label)
        CheckResult((ReactionExecutionStatus.Phase="finished")=finished && ReactionExecutionStatus.Message==expectedMessage && LastReactionResult=ResultPreserved,"successor progress and saved result survive: " label)
        CheckResult(PaletteStart.Enabled=finished && ManagementItemButtons[1].Enabled=finished,"controls follow successor lifetime: " label)
        tip := "ahk_class tooltips_class32 ahk_pid " DllCall("GetCurrentProcessId")
        CheckResult(WinExist(tip) && WinGetTitle(tip)=="successor tip","old result does not clear or replace successor notification: " label)
        CheckResult(!SetReactionStatus("late progress",false,"",job) && ReactionExecutionStatus.Message==expectedMessage,"late progress is rejected at publication boundary: " label)
        CheckResult(!SetReactionStatus("late final result",true,"old detail",job,"unknown")
            && ReactionExecutionStatus.Message==expectedMessage && LastReactionResult=ResultPreserved,"late final result is rejected after successor progress or completion: " label)
        FinishReactionJob(ResultReplacement)
        ShowStatusTip()
    }
}
; A final rendering failure cannot reclassify a completed send or retain its timing request.
global ResultRenderFailure := true, ResultPrecision := ""
RuntimePorts.Foreground := (hwnd) => hwnd=123
RuntimePorts.BrowserRequest := (*) => {State:"operated"}
RuntimePorts.Clock := ResultRenderClock
RuntimePorts.TimingPrecision := ResultTiming
job := CreateReactionJob({Window:123,Total:1,Interval:100})
ActiveReactionJob := job
SetReactionStatus("before final rendering")
escaped := false
try RunReactionSendLoop(job)
catch
    escaped := true
RuntimePorts.Clock := 0
CheckResult(escaped && !ResultRenderFailure && ResultPrecision=="BE" && !ActiveReactionJob && job.Phase="finished",
    "final rendering failure releases this job and its timing request")
CheckResult(LastReactionResult.Reason="completed" && LastReactionResult.Completed=1 && LastReactionResult.Detail="",
    "display failure cannot replace the completed operation with an unknown outcome")
FileAppend("PASS: " ResultChecks " result publication ownership checks; no real browser operations`n","*")
ExitApp()
CheckResult(value,label) {
    global ResultChecks
    if !value
        throw Error(label)
    ResultChecks++
}
ProbeResultPublication() {
    global ResultArmed, ResultReplacement, ResultPreserved, ActiveReactionJob
    if !IsSet(ResultArmed) || !ResultArmed || ActiveReactionJob
        return
    if InStr(ResultPoint,"render") && ReactionExecutionStatus.Phase!="finished"
        return
    ResultArmed := false
    ResultPreserved := LastReactionResult
    ResultReplacement := CreateReactionJob({Mode:"queued",Window:123})
    ActiveReactionJob := ResultReplacement
    SetReactionStatus("successor pending")
    if InStr(ResultPoint,"finished") {
        FinishReactionJob(ResultReplacement)
        SetReactionStatus("successor finished",true,"successor detail",ResultReplacement,"cancelled")
        ResultPreserved := LastReactionResult
    }
    ShowStatusTip("successor tip")
}
ResultRenderClock() {
    global ResultRenderFailure
    if ResultRenderFailure && ReactionExecutionStatus.Phase="finished" {
        ResultRenderFailure := false
        throw Error("final rendering failed")
    }
    return NativeAppClockMs()
}
ResultTiming(enabled) {
    global ResultPrecision
    ResultPrecision .= enabled ? "B" : "E"
    return enabled
}
ResultRequest(hwnd,mode,video,extra) {
    return {State:ResultCase="completed" ? "operated" : "unknown",Detail:"fixture failure"}
}
'@
Invoke-AppTest -Runtime $resultRuntime -Body $resultTests -Setup @'
RuntimePorts.Foreground := (hwnd) => ResultCase!="countdown" && ResultCase!="quick"
RuntimePorts.ShortcutRelease := (key) => true
RuntimePorts.BrowserRequest := ResultRequest
'@
