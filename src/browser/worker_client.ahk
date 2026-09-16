; Worker lifecycle and framed request/reply transport. No GUI dependencies.
EnsureWorkerRunning() {
    global WorkerProcessId, WorkerPipeHandle, WorkerSignalHandle
    if WorkerProcessId && ProcessExist(WorkerProcessId) && WorkerPipeHandle
        return
    StopBrowserWorker()
    guid := Buffer(16)
    if DllCall("ole32\CoCreateGuid", "Ptr", guid, "Int") != 0
        throw Error("パイプ名を作成できませんでした。")
    guidText := Buffer(78)
    DllCall("ole32\StringFromGUID2", "Ptr", guid, "Ptr", guidText, "Int", 39)
    pipeName := "youtube-helper-" StrGet(guidText, "UTF-16")
    ; Duplex byte pipe, nonblocking server, local clients only, one instance.
    WorkerPipeHandle := DllCall("CreateNamedPipeW", "Str", "\\.\pipe\" pipeName,
        "UInt", 0x80003, "UInt", 9, "UInt", 1, "UInt", 65536,
        "UInt", 65536, "UInt", 0, "Ptr", 0, "Ptr")
    if WorkerPipeHandle = -1 || !WorkerPipeHandle {
        WorkerPipeHandle := 0
        throw Error("名前付きパイプを作成できませんでした。")
    }
    DllCall("ConnectNamedPipe", "Ptr", WorkerPipeHandle, "Ptr", 0)
    WorkerSignalHandle := DllCall("CreateEventW", "Ptr", 0, "Int", false, "Int", false,
        "Str", pipeName "-ready", "Ptr")
    if !WorkerSignalHandle
        throw Error("補助プロセスの通知を準備できませんでした。")
    q := Chr(34)
    command := q A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe" q
        . " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "
        . q A_ScriptDir "\src\browser\browser_worker.ps1" q
        . " -PipeName " q pipeName q
        . " -ParentProcessId " DllCall("GetCurrentProcessId")
        . " -CachePath " q AppDataDirectory "\video_metadata_cache.json" q
        . " -DataDirectory " q AppDataDirectory q
    Run(command, A_ScriptDir, "Hide", &WorkerProcessId)
}

StopBrowserWorker(*) {
    global WorkerProcessId, WorkerPipeHandle, WorkerSignalHandle
    if WorkerPipeHandle {
        DllCall("CloseHandle", "Ptr", WorkerPipeHandle)
        WorkerPipeHandle := 0
    }
    if IsSet(WorkerSignalHandle) && WorkerSignalHandle {
        DllCall("CloseHandle", "Ptr", WorkerSignalHandle)
        WorkerSignalHandle := 0
    }
    if WorkerProcessId {
        try {
            ; Let an idle reader observe EOF first, then terminate a stuck worker.
            if ProcessWaitClose(WorkerProcessId, 0.25) {
                ProcessClose(WorkerProcessId)
                ProcessWaitClose(WorkerProcessId, 2)
            }
        }
        WorkerProcessId := 0
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
    if !DllCall("WriteFile", "Ptr", WorkerPipeHandle, "Ptr", frame, "UInt", size + 4,
        "UInt*", &written, "Ptr", 0) || written != size + 4
        throw Error("パイプへの送信に失敗しました。")
}

ReadPipeResponse() {
    header := Buffer(4, 0)
    available := 0, copied := 0
    if !DllCall("PeekNamedPipe", "Ptr", WorkerPipeHandle, "Ptr", header, "UInt", 4,
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
    if !DllCall("ReadFile", "Ptr", WorkerPipeHandle, "Ptr", frame, "UInt", frame.Size,
        "UInt*", &received, "Ptr", 0) || received != frame.Size
        throw Error("応答を受信できませんでした。")
    return StrGet(frame.Ptr + 4, size, "UTF-8")
}

SendWorkerRequest(hwnd, mode := "resolve", expectedVideo := "", extra := "") {
    global WorkerRequestActive, WorkerRequestSequence
    unavailable := {State: mode = "reaction_send" ? "unknown" : "unavailable", Author: "", Channel: "", Video: ""}
    if WorkerRequestActive
        return unavailable
    WorkerRequestActive := true
    try {
        EnsureWorkerRunning()
        seq := ++WorkerRequestSequence
        request := "Seq=" seq "`nWindow=" hwnd "`nMode=" mode "`nVideo=" expectedVideo "`n"
            . extra
        start := A_TickCount
        limit := (mode = "verify" || mode = "verify_input") ? 2500 : 8000
        sent := false
        while A_TickCount - start < limit {
            if !WorkerProcessId || !ProcessExist(WorkerProcessId)
                break
            if !sent {
                clientPID := 0
                if DllCall("GetNamedPipeClientProcessId", "Ptr", WorkerPipeHandle, "UInt*", &clientPID) {
                    if clientPID != WorkerProcessId
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
        WorkerRequestActive := false
    }
}

WaitWorkerSignal(timeout) {
    ; Wake on worker notification or input; pump AHK timers/hotkeys without a sleep.
    handles := Buffer(A_PtrSize)
    NumPut("Ptr", WorkerSignalHandle, handles)
    result := DllCall("MsgWaitForMultipleObjectsEx", "UInt", 1, "Ptr", handles,
        "UInt", timeout, "UInt", 0x4FF, "UInt", 4, "UInt")
    if result = 0xFFFFFFFF
        throw Error("補助プロセスの通知待ちに失敗しました。")
    Sleep(-1)
}
