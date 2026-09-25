; One presentation lifecycle for application-owned Gui windows.
; layout(view, state, width, height) may also finalize a viewport's scroll range.
PresentWindow(view, options := "", layout := 0, activate := true) {
    visible := !!DllCall("IsWindowVisible", "Ptr", view.Hwnd)
    ; Never expose an unprepared first frame; never hide an already visible view.
    view.Show((visible ? "NoActivate " : "Hide ") options)
    requestedWidth := RegExMatch(options,"(?:^|\s)w(\d+)",&wm) ? Integer(wm[1]) : 0
    requestedHeight := RegExMatch(options,"(?:^|\s)h(\d+)",&hm) ? Integer(hm[1]) : 0
    if layout {
        Loop 3 {
            view.GetClientPos(,,&width,&height)
            layout.Call(view,0,width,height)
            view.GetClientPos(,,&settledWidth,&settledHeight)
            if width = settledWidth && height = settledHeight
                && (!requestedWidth || settledWidth = requestedWidth) && (!requestedHeight || settledHeight = requestedHeight)
                break
            ; Scrollbar visibility changes client size; settle it before exposing the frame.
            view.Show((visible ? "NoActivate " : "Hide ") options)
        }
    }
    ; No activation occurs until sizing and the optional layout both succeed.
    view.Show(activate ? "" : "NoActivate")
    DllCall("RedrawWindow", "Ptr", view.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
}

; Informational dialogs share ownership and cleanup; builders only add their content.
ShowInfoDialog(title, build) {
    view := Gui("+Owner" PaletteWindow.Hwnd,title)
    try {
        view.SetFont("s10","Yu Gothic UI")
        build.Call(view)
        view.OnEvent("Close",(*) => view.Destroy())
        view.OnEvent("Escape",(*) => view.Destroy())
        PresentWindow(view)
    } catch as failure {
        view.Destroy()
        throw failure
    }
}

ShowFittedWindow(view, width, height, layout := 0, activate := true) {
    monitor := DllCall("MonitorFromWindow", "Ptr", view.Hwnd, "UInt", 2, "Ptr")
    info := Buffer(40, 0), NumPut("UInt", 40, info)
    DllCall("GetMonitorInfoW", "Ptr", monitor, "Ptr", info)
    scale := A_ScreenDPI / 96
    width := Min(width, Floor((NumGet(info,28,"Int")-NumGet(info,20,"Int")-40)/scale))
    height := Min(height, Floor((NumGet(info,32,"Int")-NumGet(info,24,"Int")-70)/scale))
    prepare := (gui,state,w,h) => PrepareFittedWindow(gui,state,w,h,layout,info)
    PresentWindow(view,"w" width " h" height,prepare,activate)
}


PrepareFittedWindow(view, state, width, height, layout, workArea) {
    if layout
        layout.Call(view,state,width,height)
    rect := Buffer(16)
    DllCall("GetWindowRect","Ptr",view.Hwnd,"Ptr",rect)
    left := NumGet(workArea,20,"Int"), top := NumGet(workArea,24,"Int")
    right := NumGet(workArea,28,"Int"), bottom := NumGet(workArea,32,"Int")
    x := Max(left,Min(NumGet(rect,0,"Int"),right-(NumGet(rect,8,"Int")-NumGet(rect,0,"Int"))))
    y := Max(top,Min(NumGet(rect,4,"Int"),bottom-(NumGet(rect,12,"Int")-NumGet(rect,4,"Int"))))
    DllCall("SetWindowPos","Ptr",view.Hwnd,"Ptr",0,"Int",x,"Int",y,"Int",0,"Int",0,"UInt",0x15)
}
