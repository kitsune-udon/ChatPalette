# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
# Page actions retain the same exclusion from request through result publication.
Invoke-AppTest -Runtime (New-TestRuntime) -Body @'
    global OwnerScenario := "", OwnerProbes := [], OwnerRequests := 0, OwnerClears := 0
    global OwnerThrowClock := false, OwnerProbePublication := false, OwnerReplacement := 0, OwnerReplacementResult := 0
    RuntimePorts.Foreground := (hwnd) => hwnd=123
    RuntimePorts.BrowserRequest := OwnerRequest
    RuntimePorts.ClearChat := OwnerClear
    RuntimePorts.Clock := OwnerClock
    for action in ["chat_clear","chat_focus","reactions_show"] {
        for scenario in ["success","request_failed","notification_failed"] {
            OwnerScenario := scenario, OwnerProbes := [], OwnerRequests := 0, OwnerClears := 0, OwnerThrowClock := false, OwnerProbePublication := false
            escaped := false, result := false
            try result := RunPageAction(action,123)
            catch
                escaped := true
            Assert(OwnerProbes.Length>=1,"page lifecycle reaches the request boundary: " action "/" scenario)
            for probe in OwnerProbes {
                Assert(!probe.Input && !probe.Edit && !probe.Reaction && !probe.Preferences,"all conflicting operations remain blocked at " probe.Boundary ": " action "/" scenario)
                Assert(!probe.Nested && probe.RequestsBefore=probe.RequestsAfter,"another page action never reenters at " probe.Boundary ": " action "/" scenario)
            }
            Assert(OperationAllowed("input") && OperationAllowed("edit") && OperationAllowed("reaction") && OperationAllowed("preferences"),"success or failure releases page ownership: " action "/" scenario)
            Assert(escaped=(scenario="notification_failed") && result=(scenario="success"),"page completion preserves success and failure meaning: " action "/" scenario)
            Assert(OwnerClears=(action="chat_clear" && (scenario="success" || scenario="notification_failed") ? 1 : 0),"only a verified clear reaches the deletion port once: " action "/" scenario)
        }
    }
    for action in ["chat_clear","chat_focus","reactions_show"] {
        for scenario in ["replacement","replacement_failed"] {
            OwnerScenario := scenario, OwnerProbes := [], OwnerRequests := 0, OwnerClears := 0, OwnerProbePublication := false
            Assert(!RunPageAction(action,123),"superseded page action cannot report success: " action "/" scenario)
            Assert(ActivePageAction=OwnerReplacement && !OperationAllowed("input"),"old cleanup preserves replacement ownership: " action "/" scenario)
            Assert(LastBrowserOperation=OwnerReplacementResult && PaletteHint.Text=="replacement pending","old result cannot overwrite replacement diagnostics or hint: " action "/" scenario)
            Assert(OwnerRequests=1 && !OwnerClears,"superseded action cannot verify, clear or send again: " action "/" scenario)
            ActivePageAction := 0
            RefreshOperationControls()
        }
    }

FileAppend("PASS: " Checks " page ownership checks; no real input or browser operations`n","*")
ExitApp()
OwnerProbe(boundary) {
    global OwnerProbes
    probe := {Boundary:boundary,Input:OperationAllowed("input"),Edit:OperationAllowed("edit"),
        Reaction:OperationAllowed("reaction"),Preferences:OperationAllowed("preferences"),RequestsBefore:OwnerRequests}
    ; Avoid recursion while recording the pre-fix policy failure.
    probe.Nested := probe.Input ? true : RunPageAction("reactions_show",123)
    probe.RequestsAfter := OwnerRequests
    OwnerProbes.Push(probe)
}
OwnerRequest(hwnd,mode,video,extra) {
    global OwnerRequests, OwnerThrowClock, OwnerProbePublication, ActivePageAction, OwnerReplacement, OwnerReplacementResult
    OwnerRequests++
    OwnerProbe(mode)
    if OwnerScenario="replacement" || OwnerScenario="replacement_failed" {
        OwnerReplacement := {Window:456}
        ActivePageAction := OwnerReplacement
        RecordBrowserOperation({Mode:"fixture",State:"pending",Duration:0})
        OwnerReplacementResult := LastBrowserOperation
        PaletteHint.Text := "replacement pending"
        if OwnerScenario="replacement_failed"
            throw Error("superseded page request failure")
    } else
        OwnerProbePublication := true
    if OwnerScenario="request_failed"
        throw Error("page request fixture failure")
    if OwnerScenario="notification_failed"
        OwnerThrowClock := true
    return {State:mode="chat_focus" ? "focused" : (mode="verify_chat" ? "ok" : "hovered"),Video:"abcdefghijk",Detail:"owner-proof"}
}
OwnerClear() {
    global OwnerClears
    OwnerProbe("clear keys")
    OwnerClears++
}
OwnerClock() {
    global OwnerThrowClock, OwnerProbePublication
    if OwnerProbePublication {
        OwnerProbePublication := false
        OwnerProbe("result publication")
    }
    if OwnerThrowClock {
        OwnerThrowClock := false
        throw Error("page notification fixture failure")
    }
    return 100
}
'@

# A timer models an application callback changing the input destination after verification.
Invoke-AppTest -Runtime (New-TestRuntime) -Body @'
Thread("Interrupt",0)
global ClearDestination := 123, ClearedDestination := 0, ClearVerified := false, ClearFailure := false
RuntimePorts.Foreground := ClearForeground
RuntimePorts.BrowserRequest := ClearRequest
RuntimePorts.ClearChat := ClearInput
for callerCritical in [0,23] {
    for scenario in ["success","send_failure","foreground_changed"] {
        ClearDestination := 123, ClearedDestination := 0, ClearVerified := false
        ClearFailure := scenario="send_failure"
        Critical(callerCritical)
        try {
            result := RunPageAction("chat_clear",123)
            Assert(A_IsCritical=callerCritical,"clear restores caller interruption policy: " scenario)
            Assert(result=(scenario="success") && ClearedDestination=(scenario="foreground_changed" ? 0 : 123),
                "clear never deletes at the destination selected by an intervening timer: " scenario)
            Assert(!ActivePageAction,"clear releases ownership after success, refusal or send failure: " scenario)
            expectedState := scenario="success" ? "cleared" : (scenario="send_failure" ? "unknown" : "cancelled")
            Assert(LastBrowserOperation.State=expectedState,"clear retains its completion state: " scenario)
        } finally Critical("Off")
        deadline := A_TickCount+1000
        while ClearDestination!=456 && A_TickCount<deadline
            Sleep(10)
        Assert(ClearDestination=456,"application timer resumes after clear: " scenario)
    }
}
FileAppend("PASS: " Checks " clear interruption checks; no real keys sent`n","*")
ExitApp()
ClearRequest(hwnd,mode,video,extra) {
    global ClearVerified, ClearDestination
    if mode="verify_chat" {
        ClearVerified := true
        if scenario="foreground_changed"
            ClearDestination := 456
    }
    return {State:mode="chat_focus" ? "focused" : "ok",Video:"abcdefghijk",Detail:"clear-proof"}
}
ClearForeground(hwnd) {
    if ClearVerified
        SetTimer(ChangeClearDestination,-1)
    return hwnd=ClearDestination
}
ChangeClearDestination() {
    global ClearDestination := 456
}
ClearInput() {
    global ClearedDestination
    Sleep(30)
    ClearedDestination := ClearDestination
    if ClearFailure
        throw Error("fixture clear failure")
}
'@
