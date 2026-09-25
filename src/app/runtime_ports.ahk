; External effects are replaceable before initialization in an isolated runner.
; A zero callback uses the production adapter. No arbitrary hooks inside domain code.
class RuntimePorts {
    static ConfirmDiscard := 0
    static Restart := 0
    static BrowserRequest := 0
    static WorkerRequest := 0
    static WorkerScript := ""
    static BrowserIdentity := 0
    static ResolveChannel := 0
    static VerifyInput := 0
    static Foreground := 0
    static Text := 0
    static ClearChat := 0
    static Clock := 0
    static TimingPrecision := 0
    static ShortcutKey := 0
    static ShortcutRelease := 0
}
IsTargetForeground(hwnd) {
    return RuntimePorts.Foreground ? RuntimePorts.Foreground.Call(hwnd) : !!WinActive("ahk_id " hwnd)
}

; Monotonic milliseconds for deadlines, elapsed time, rendering and reaction pacing.
AppClockMs() {
    return RuntimePorts.Clock ? RuntimePorts.Clock.Call() : NativeAppClockMs()
}

NativeAppClockMs() {
    static frequency := 0
    if !frequency
        DllCall("QueryPerformanceFrequency", "Int64*", &frequency)
    DllCall("QueryPerformanceCounter", "Int64*", &counter := 0)
    return counter * (1000 / frequency)
}
