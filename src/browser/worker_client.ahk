; Only worker_client mutates the transport lifetime.
class WorkerState {
    static ProcessId := 0
    static PipeHandle := 0
    static SignalHandle := 0
    static Sequence := 0
    static RequestActive := false
    static RegistrationPid := 0
}
IsWorkerRegistrationCurrent() {
    return WorkerState.RegistrationPid = WorkerState.ProcessId && WorkerState.ProcessId != 0
}
MarkWorkerRegistrationCurrent() {
    WorkerState.RegistrationPid := WorkerState.ProcessId
}
InvalidateWorkerRegistration() {
    WorkerState.RegistrationPid := 0
}
; Worker lifecycle and framed request/reply transport. No GUI dependencies.
EnsureWorkerRunning() {
    if WorkerState.ProcessId && ProcessExist(WorkerState.ProcessId) && WorkerState.PipeHandle
        return
    StopBrowserWorker()
    guid := Buffer(16)
    if DllCall("ole32\CoCreateGuid", "Ptr", guid, "Int") != 0
        throw Error("パイプ名を作成できませんでした。")
    guidText := Buffer(78)
    DllCall("ole32\StringFromGUID2", "Ptr", guid, "Ptr", guidText, "Int", 39)
    pipeName := "youtube-helper-" StrGet(guidText, "UTF-16")
    ; Duplex byte pipe, nonblocking server, local clients only, one instance.
    WorkerState.PipeHandle := DllCall("CreateNamedPipeW", "Str", "\\.\pipe\" pipeName,
        "UInt", 0x80003, "UInt", 9, "UInt", 1, "UInt", 65536,
        "UInt", 65536, "UInt", 0, "Ptr", 0, "Ptr")
    if WorkerState.PipeHandle = -1 || !WorkerState.PipeHandle {
        WorkerState.PipeHandle := 0
        throw Error("名前付きパイプを作成できませんでした。")
    }
    DllCall("ConnectNamedPipe", "Ptr", WorkerState.PipeHandle, "Ptr", 0)
    WorkerState.SignalHandle := DllCall("CreateEventW", "Ptr", 0, "Int", false, "Int", false,
        "Str", pipeName "-ready", "Ptr")
    if !WorkerState.SignalHandle
        throw Error("補助プロセスの通知を準備できませんでした。")
    q := Chr(34)
    command := q A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe" q
        . " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "
        . q A_ScriptDir "\src\browser\browser_worker.ps1" q
        . " -PipeName " q pipeName q
        . " -ParentProcessId " DllCall("GetCurrentProcessId")
    Run(command, A_ScriptDir, "Hide", &pid := 0)
    WorkerState.ProcessId := pid
}

StopBrowserWorker(*) {
    WorkerState.RegistrationPid := 0
    if WorkerState.PipeHandle {
        DllCall("CloseHandle", "Ptr", WorkerState.PipeHandle)
        WorkerState.PipeHandle := 0
    }
    if WorkerState.SignalHandle {
        DllCall("CloseHandle", "Ptr", WorkerState.SignalHandle)
        WorkerState.SignalHandle := 0
    }
    if WorkerState.ProcessId {
        try {
            ; Let an idle reader observe EOF first, then terminate a stuck worker.
            if ProcessWaitClose(WorkerState.ProcessId, 0.25) {
                ProcessClose(WorkerState.ProcessId)
                ProcessWaitClose(WorkerState.ProcessId, 2)
            }
        }
        WorkerState.ProcessId := 0
    }
}

WritePipeRequest(text) {
    size := StrPut(text, "UTF-8") - 1
    if size < 1 || size > 32768
        throw Error("依頼サイズが不正です。")
    frame := Buffer(size + 5, 0)
    NumPut("UInt", size, frame)
    StrPut(text, frame.Ptr + 4, size + 1, "UTF-8")
    written := 0
    if !DllCall("WriteFile", "Ptr", WorkerState.PipeHandle, "Ptr", frame, "UInt", size + 4,
        "UInt*", &written, "Ptr", 0) || written != size + 4
        throw Error("パイプへの送信に失敗しました。")
}

ReadPipeResponse() {
    header := Buffer(4, 0)
    available := 0, copied := 0
    if !DllCall("PeekNamedPipe", "Ptr", WorkerState.PipeHandle, "Ptr", header, "UInt", 4,
        "UInt*", &copied, "UInt*", &available, "Ptr", 0)
        throw Error("パイプが切断されました。")
    if copied < 4
        return ""
    size := NumGet(header, 0, "UInt")
    if size < 1 || size > 32768
        throw Error("応答サイズが不正です。")
    if available < size + 4
        return ""
    frame := Buffer(size + 4)
    received := 0
    if !DllCall("ReadFile", "Ptr", WorkerState.PipeHandle, "Ptr", frame, "UInt", frame.Size,
        "UInt*", &received, "Ptr", 0) || received != frame.Size
        throw Error("応答を受信できませんでした。")
    return StrGet(frame.Ptr + 4, size, "UTF-8")
}

SendWorkerRequest(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    return RuntimePorts.WorkerRequest ? RuntimePorts.WorkerRequest.Call(hwnd,mode,expectedVideo,extra) : NativeSendWorkerRequest(hwnd,mode,expectedVideo,extra)
}

NativeSendWorkerRequest(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    unavailable := {State: (mode = "reaction_send" || mode = "chat_focus" || mode = "reactions_show") ? "unknown" : "unavailable", Author: "", Channel: "", Video: ""}
    if WorkerState.RequestActive
        return unavailable
    WorkerState.RequestActive := true
    try {
        EnsureWorkerRunning()
        seq := ++WorkerState.Sequence
        request := "Seq=" seq "`nWindow=" hwnd "`nMode=" mode "`nVideo=" expectedVideo "`n"
            . extra
        start := A_TickCount
        limit := (mode = "verify" || mode = "verify_input" || mode = "verify_chat") ? 2500 : 8000
        sent := false
        while A_TickCount - start < limit {
            if !WorkerState.ProcessId || !ProcessExist(WorkerState.ProcessId)
                break
            if !sent {
                clientPID := 0
                if DllCall("GetNamedPipeClientProcessId", "Ptr", WorkerState.PipeHandle, "UInt*", &clientPID) {
                    if clientPID != WorkerState.ProcessId
                        throw Error("接続元が補助プロセスと一致しません。")
                    WritePipeRequest(request)
                    sent := true
                }
            } else {
                response := ReadPipeResponse()
                if response != "" {
                    fields := Map()
                    for line in StrSplit(response, "`n") {
                        if RegExMatch(line, "^([A-Za-z]+)=(.*)$", &match)
                            fields[match[1]] := match[2]
                    }
                    if fields.Get("Seq", "") != seq || fields.Get("Window", "") != hwnd
                        throw Error("依頼と応答が一致しません。")
                    return {State: fields.Get("State", "unavailable"),
                        Author: fields.Get("Author", ""), Channel: fields.Get("Channel", ""),
                        Video: fields.Get("Video", ""), Detail: fields.Get("Detail", "")}
                }
            }
            WaitWorkerSignal(Min(50, Max(0, limit - (A_TickCount - start))))
        }
        StopBrowserWorker()
        return unavailable
    } catch {
        StopBrowserWorker()
        return unavailable
    } finally {
        WorkerState.RequestActive := false
    }
}

WaitWorkerSignal(timeout) {
    ; Wake on worker notification or input; pump AHK timers/hotkeys without a sleep.
    handles := Buffer(A_PtrSize)
    NumPut("Ptr", WorkerState.SignalHandle, handles)
    result := DllCall("MsgWaitForMultipleObjectsEx", "UInt", 1, "Ptr", handles,
        "UInt", timeout, "UInt", 0x4FF, "UInt", 4, "UInt")
    if result = 0xFFFFFFFF
        throw Error("補助プロセスの通知待ちに失敗しました。")
    Sleep(-1)
}
