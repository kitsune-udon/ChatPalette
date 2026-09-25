# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
# Independent lifecycle scenario: the final result must describe the queued attempt.
$release = New-TestRuntime
$quickTests = @'
global QuickScenario := "", QuickRequests := 0, QuickReplacement := 0
DefaultReactionCount := 1, DefaultReactionIntervalMs := 0
for entry in [["changed","changed","lookup detail"], ["unavailable","unavailable","lookup detail"],
    ["request_error","unknown","context exception"], ["release_error","unknown","key exception"],
    ["release_timeout","unavailable",""], ["before_switch","wrong_window",""],
    ["after_switch","wrong_window",""], ["cancel","cancelled",""]] {
    QuickScenario := entry[1], QuickRequests := 0
    queued := CreateReactionJob({Mode:"queued",Window:123})
    ActiveReactionJob := queued
    SetReactionStatus("waiting for quick fixture")
    QuickReaction()
    Assert(!ActiveReactionJob && queued.Phase="finished" && OperationAllowed("reaction"),"ownership released: " QuickScenario)
    Assert(LastReactionResult.Reason==entry[2] && LastReactionResult.Detail==entry[3],"final cause retained: " QuickScenario)
    Assert(LastReactionResult.Mode="queued" && LastReactionResult.Completed=0 && ReactionExecutionStatus.Phase="finished"
        && ReactionExecutionStatus.Message==LastReactionResult.Message && PaletteStatusControl.Text==LastReactionResult.Message,"visible result belongs to this unstarted attempt: " QuickScenario)
    Assert(QuickRequests=(InStr(QuickScenario,"release_") || QuickScenario="before_switch" ? 0 : 1),"no send or retry after start failure: " QuickScenario)
}
QuickScenario := "replacement", QuickRequests := 0
previousResult := LastReactionResult
queued := CreateReactionJob({Mode:"queued",Window:123})
ActiveReactionJob := queued
QuickReaction()
Assert(ActiveReactionJob=QuickReplacement && QuickReplacement.Phase="queued" && LastReactionResult=previousResult
    && ReactionExecutionStatus.Phase!="finished" && ReactionExecutionStatus.Message="replacement pending","old start cannot finalize or overwrite replacement")
CancelReaction()
QuickScenario := "success", QuickRequests := 0
ActiveReactionJob := CreateReactionJob({Mode:"queued",Window:123})
QuickReaction()
Assert(!ActiveReactionJob && QuickRequests=2 && LastReactionResult.Reason="completed"
    && LastReactionResult.Mode="reaction_send" && LastReactionResult.Completed=1,"successful handoff keeps the send result")
FileAppend("PASS: " Checks " quick reaction result checks; no real browser operations`n","*")
ExitApp()
QuickRelease(keys) {
    if QuickScenario="release_error"
        throw Error("key exception")
    return QuickScenario!="release_timeout"
}
QuickForeground(hwnd) {
    return QuickScenario!="before_switch" && !(QuickScenario="after_switch" && QuickRequests)
}
QuickRequest(hwnd,mode,video,extra) {
    global QuickRequests, QuickReplacement, ActiveReactionJob, IsBrowserOperationBusy
    QuickRequests++
    if mode="reaction_send" {
        if QuickScenario!="success"
            throw Error("unexpected reaction send")
        return {State:"operated"}
    }
    if mode!="browser_context"
        throw Error("unexpected operation")
    if QuickScenario="request_error"
        throw Error("context exception")
    if QuickScenario="cancel" {
        IsBrowserOperationBusy := true
        try CancelReaction()
        finally IsBrowserOperationBusy := false
    }
    if QuickScenario="replacement" {
        QuickReplacement := CreateReactionJob({Mode:"queued",Window:123})
        ActiveReactionJob := QuickReplacement
        SetReactionStatus("replacement pending")
    }
    return {State:QuickScenario="changed" || QuickScenario="unavailable" ? QuickScenario : "ok", Video:"abcdefghijk", Detail:"lookup detail"}
}
'@
Invoke-AppTest -Runtime $release -Body $quickTests -Setup @'
RuntimePorts.ShortcutRelease := QuickRelease
RuntimePorts.Foreground := QuickForeground
RuntimePorts.BrowserRequest := QuickRequest
'@
