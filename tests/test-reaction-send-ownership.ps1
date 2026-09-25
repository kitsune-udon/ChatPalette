# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$ownershipRuntime=New-TestRuntime
$ownershipTests=@'
BuildManagement()
global OwnershipCase := 0, OwnershipReplacement := 0
global OwnershipForegroundCalls := 0, OwnershipRequests := 0, OwnershipPrecision := ""
for scenario in [{Point:1,Throws:false,Requests:0,Precision:""},
    {Point:1,Throws:true,Requests:0,Precision:""},
    {Point:2,Throws:false,Requests:0,Precision:"BE"},
    {Point:2,Throws:true,Requests:0,Precision:"BE"},
    {Point:0,Throws:true,Requests:1,Precision:"BE"},
    {Point:0,Throws:false,Requests:1,Precision:"BE"}] {
    OwnershipCase := scenario, OwnershipForegroundCalls := 0, OwnershipRequests := 0, OwnershipPrecision := ""
    job := CreateReactionJob({Window:123,Video:"abcdefghijk",Total:2,Interval:100})
    ActiveReactionJob := job
    SetReactionStatus("original running")
    previousResult := LastReactionResult
    RunReactionSendLoop(job)
    label := scenario.Point "/" scenario.Throws
    Assert(ActiveReactionJob=OwnershipReplacement && OwnershipReplacement.Phase="queued" && !OwnershipReplacement.Cancelled,"old failure cannot stop replacement: " label)
    Assert(job.Phase="finished" && OwnershipPrecision==scenario.Precision && OwnershipRequests=scenario.Requests,"old loop finishes and releases only its resources: " label)
    Assert(ReactionExecutionStatus.Phase!="finished" && ReactionExecutionStatus.Message=="replacement pending" && LastReactionResult=previousResult,"old result cannot overwrite replacement progress or previous result: " label)
    Assert(!PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"replacement keeps operation controls locked: " label)
    FinishReactionJob(OwnershipReplacement)
}
FileAppend("PASS: " Checks " send-loop ownership checks; no real browser operations`n","*")
ExitApp()
ReplaceOwnershipJob() {
    global ActiveReactionJob, OwnershipReplacement
    OwnershipReplacement := CreateReactionJob({Mode:"queued",Window:123})
    ActiveReactionJob := OwnershipReplacement
    SetReactionStatus("replacement pending")
    if OwnershipCase.Throws
        throw Error("failure from superseded operation")
}
OwnershipForeground(hwnd) {
    global OwnershipForegroundCalls
    OwnershipForegroundCalls++
    if OwnershipCase.Point=OwnershipForegroundCalls {
        ReplaceOwnershipJob()
        return false
    }
    return true
}
OwnershipRequest(hwnd,mode,video,extra) {
    global OwnershipRequests
    OwnershipRequests++
    if OwnershipCase.Point=0
        ReplaceOwnershipJob()
    return {State:"operated"}
}
OwnershipTiming(enabled) {
    global OwnershipPrecision
    OwnershipPrecision .= enabled ? "B" : "E"
    return enabled
}
'@
Invoke-AppTest -Runtime $ownershipRuntime -Body $ownershipTests -Setup @'
RuntimePorts.Foreground := OwnershipForeground
RuntimePorts.BrowserRequest := OwnershipRequest
RuntimePorts.TimingPrecision := OwnershipTiming
'@
