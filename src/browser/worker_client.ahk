; Only worker_client mutates the transport lifetime.
class WorkerState {
    static ProcessHandle := 0
    static ProcessId {
        get => this.ProcessHandle ? DllCall("GetProcessId", "Ptr", this.ProcessHandle, "UInt") : 0
    }
    static PipeHandle := 0
    static SignalHandle := 0
    static Sequence := 0
    static RequestActive := false
    static RegistrationsSynchronized := false
}
IsWorkerRegistrationCurrent() {
    return WorkerState.RegistrationsSynchronized && IsWorkerRunning()
}
MarkWorkerRegistrationCurrent() {
    WorkerState.RegistrationsSynchronized := true
}
InvalidateWorkerRegistration() {
    WorkerState.RegistrationsSynchronized := false
}
; Worker lifecycle and framed request/reply transport. No GUI dependencies.
IsWorkerRunning() {
    return WorkerState.ProcessHandle && DllCall("WaitForSingleObject", "Ptr", WorkerState.ProcessHandle, "UInt", 0, "UInt")=0x102
}
EnsureWorkerRunning() {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if IsWorkerRunning() && WorkerState.PipeHandle
            return
        StopBrowserWorker()
        try {
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
            script := RuntimePorts.WorkerScript != "" ? RuntimePorts.WorkerScript : A_ScriptDir "\src\browser\browser_worker.ps1"
            q := Chr(34)
            executable := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
            command := q executable q
                . " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "
                . q script q
                . " -PipeName " q pipeName q
            ; CreateProcess returns the exact process object; never reopen a reusable PID.
            ; STARTUPINFO / PROCESS_INFORMATION sizes include native pointer alignment.
            startup := Buffer(A_PtrSize=8 ? 104 : 68,0), process := Buffer(2*A_PtrSize+8,0)
            NumPut("UInt",startup.Size,startup)
            commandLine := Buffer(StrPut(command,"UTF-16")), StrPut(command,commandLine,"UTF-16")
            ; CREATE_NO_WINDOW, explicit executable, and no inherited handles.
            if !DllCall("CreateProcessW", "Str", executable, "Ptr", commandLine, "Ptr", 0, "Ptr", 0,
                "Int", false, "UInt", 0x08000000, "Ptr", 0, "Str", A_ScriptDir, "Ptr", startup, "Ptr", process)
                throw OSError(, "補助プロセスを起動できませんでした。")
            WorkerState.ProcessHandle := NumGet(process,0,"Ptr")
            DllCall("CloseHandle", "Ptr", NumGet(process,A_PtrSize,"Ptr"))
        } catch as failure {
            StopBrowserWorker()
            throw failure
        }
    } finally Critical(previousCritical)
}

StopBrowserWorker(*) {
    previousCritical := A_IsCritical
    Critical("On")
    try {
        InvalidateWorkerRegistration()
        if WorkerState.PipeHandle {
            DllCall("CloseHandle", "Ptr", WorkerState.PipeHandle)
            WorkerState.PipeHandle := 0
        }
        if WorkerState.SignalHandle {
            DllCall("CloseHandle", "Ptr", WorkerState.SignalHandle)
            WorkerState.SignalHandle := 0
        }
        if WorkerState.ProcessHandle {
            ; Closing the pipe lets an idle reader exit; terminate only this process.
            handle := WorkerState.ProcessHandle
            state := DllCall("WaitForSingleObject", "Ptr", handle, "UInt", 250, "UInt")
            if state=0x102 {
                DllCall("TerminateProcess", "Ptr", handle, "UInt", 1)
                state := DllCall("WaitForSingleObject", "Ptr", handle, "UInt", 2000, "UInt")
            }
            ; Retain ownership if termination is unconfirmed, so cleanup can retry.
            if state != 0
                throw Error("補助プロセスの終了を確認できませんでした。")
            DllCall("CloseHandle", "Ptr", handle)
            WorkerState.ProcessHandle := 0
        }
    } finally Critical(previousCritical)
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
        ; Startup owns its rollback. Preserve its failure without a second cleanup.
        try EnsureWorkerRunning()
        catch as failure {
            unavailable.Detail := failure.Message
            return unavailable
        }
        try {
            seq := ++WorkerState.Sequence
            request := "Seq=" seq "`nWindow=" hwnd "`nMode=" mode "`nVideo=" expectedVideo "`n"
                . extra
            start := AppClockMs()
            limit := (mode = "verify_input" || mode = "verify_chat") ? 2500 : 8000
            sent := false
            while AppClockMs() - start < limit {
                if !IsWorkerRunning()
                    throw Error("補助プロセスが応答する前に終了しました。")
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
                WaitWorkerSignal(Min(50, Max(0, Ceil(limit - (AppClockMs() - start)))))
            }
            throw Error("補助プロセスの応答が時間内に届きませんでした。")
        } catch as failure {
            ; Preserve the observed cause; all communication failures share cleanup.
            unavailable.Detail := failure.Message
        }
        ; Do not catch a cleanup failure here or retry it implicitly.
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
