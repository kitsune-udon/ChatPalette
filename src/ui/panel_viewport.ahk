; Keep full-size controls reachable without shrinking text on small work areas.
class PanelViewport {
    __New(view, width, height, layout := 0) {
        this.View := view, this.Hwnd := view.Hwnd, this.Width := width, this.Height := height
        this.MinimumWidth := width, this.MinimumHeight := height, this.Layout := layout
        this.X := 0, this.Y := 0, this.Children := [], this.Updating := false
        this.LastFocus := 0, this.Disposed := false
        this.FocusHandler := ObjBindMethod(this,"FollowFocus")
        this.PendingResize := false, this.PendingOffset := 0
        this.UpdateHandler := ObjBindMethod(this,"FlushUpdates")
        view.Opt("+Resize +MinSize160x160")
        this.CaptureChildren()
        if !layout
            view.OnEvent("Size", ObjBindMethod(this, "Resize"))
        this.ScrollHandler := ObjBindMethod(this, "Scroll")
        this.WheelHandler := ObjBindMethod(this, "Wheel")

        OnMessage(0x114, this.ScrollHandler)
        OnMessage(0x115, this.ScrollHandler)
        OnMessage(0x20A, this.WheelHandler)
        ; Focus is sampled by an AHK timer only while the panel is visible.
        this.ExitHandler := ObjBindMethod(this,"Dispose")
        OnExit(this.ExitHandler)
    }

    CaptureChildren() {
        children := []
        child := DllCall("GetWindow", "Ptr", this.Hwnd, "UInt", 5, "Ptr")
        while child {
            rect := Buffer(16)
            if !DllCall("GetWindowRect", "Ptr", child, "Ptr", rect)
                throw Error("画面部品の座標を取得できませんでした。")
            DllCall("MapWindowPoints", "Ptr", 0, "Ptr", this.Hwnd, "Ptr", rect, "UInt", 2)
            ; Fixed-size native record: HWND followed by two signed coordinates.
            record := Buffer(A_PtrSize+8)
            NumPut("Ptr",child,"Int",NumGet(rect,0,"Int"),"Int",NumGet(rect,4,"Int"),record)
            children.Push(record)
            child := DllCall("GetWindow", "Ptr", child, "UInt", 2, "Ptr")
        }
        ; Publish only a complete coordinate snapshot.
        this.Children := children
    }

    MoveChildren(x, y) {
        snapshot := this.Children
        for record in snapshot {
            hwnd := NumGet(record,0,"Ptr")
            targetX := NumGet(record,A_PtrSize,"Int")-x
            targetY := NumGet(record,A_PtrSize+4,"Int")-y
            DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", targetX, "Int", targetY,
                "Int", 0, "Int", 0, "UInt", 0x15)
        }
    }

    Show() {
        ShowFittedWindow(this.View,this.MinimumWidth,this.MinimumHeight,ObjBindMethod(this,"Resize"))
    }

    Resize(*) {
        if this.Disposed
            return
        if this.Updating {
            this.PendingResize := true
            SetTimer(this.UpdateHandler,-1)
            return
        }
        this.LastFocus := 0
        SetTimer(this.FocusHandler,50)
        this.Updating := true
        try {
            ; A scrollbar appearing can change the other axis's client size.
            Loop 2 {
                rect := Buffer(16)
                DllCall("GetClientRect", "Ptr", this.Hwnd, "Ptr", rect)
                this.PageX := NumGet(rect,8,"Int"), this.PageY := NumGet(rect,12,"Int")
                if this.Layout {
                    ; Restore unscrolled coordinates before any relative Move calls.
                    this.MoveChildren(0,0)
                    this.Width := Max(this.MinimumWidth,Floor(this.PageX*96/A_ScreenDPI))
                    this.Height := Max(this.MinimumHeight,Floor(this.PageY*96/A_ScreenDPI))
                    this.Layout.Call(this.View,0,this.Width,this.Height)
                    this.CaptureChildren()
                }
                this.MaxX := Max(0, Round(this.Width * A_ScreenDPI / 96) - this.PageX)
                this.MaxY := Max(0, Round(this.Height * A_ScreenDPI / 96) - this.PageY)
                this.ApplyOffset(this.X, this.Y)
            }
        } finally {
            this.Updating := false
        }
    }

    SetOffset(x, y) {
        if this.Disposed || !this.HasOwnProp("PageY")
            return
        if this.Updating {
            this.PendingOffset := {X:x,Y:y}
            SetTimer(this.UpdateHandler,-1)
            return
        }
        this.Updating := true
        try this.ApplyOffset(x,y)
        finally this.Updating := false
    }

    FlushUpdates() {
        if this.Disposed
            return
        if this.Updating {
            SetTimer(this.UpdateHandler,-10)
            return
        }
        resize := this.PendingResize, offset := this.PendingOffset
        this.PendingResize := false, this.PendingOffset := 0
        if resize
            this.Resize()
        if offset
            this.SetOffset(offset.X,offset.Y)
    }

    ; Only the owner of Updating may apply native moves.
    ApplyOffset(x, y) {
        this.X := Min(Max(0, x), this.MaxX), this.Y := Min(Max(0, y), this.MaxY)
        for axis in [0, 1] {
            info := Buffer(28, 0)
            NumPut("UInt", 28, "UInt", 7, "Int", 0, "Int", Round((axis ? this.Height : this.Width) * A_ScreenDPI / 96) - 1,
                "UInt", axis ? this.PageY : this.PageX, "Int", axis ? this.Y : this.X, info)
            DllCall("SetScrollInfo", "Ptr", this.Hwnd, "Int", axis, "Ptr", info, "Int", true)
        }
        this.MoveChildren(this.X,this.Y)
        DllCall("RedrawWindow", "Ptr", this.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x85)
    }

    Scroll(wParam, lParam, msg, hwnd) {
        if this.Disposed || this.Updating || !this.HasOwnProp("PageY") || hwnd != this.Hwnd || lParam
            return
        vertical := msg = 0x115
        pos := vertical ? this.Y : this.X, page := vertical ? this.PageY : this.PageX
        action := wParam & 0xFFFF
        switch action {
            case 0: pos -= 32
            case 1: pos += 32
            case 2: pos -= page
            case 3: pos += page
            case 4, 5:
                info := Buffer(28,0), NumPut("UInt",28,"UInt",0x10,info)
                DllCall("GetScrollInfo","Ptr",hwnd,"Int",vertical,"Ptr",info)
                pos := NumGet(info,24,"Int")
            case 6: pos := 0
            case 7: pos := vertical ? this.MaxY : this.MaxX
            default: return 0
        }
        this.SetOffset(vertical ? this.X : pos, vertical ? pos : this.Y)
        return 0
    }

    Wheel(wParam, lParam, msg, hwnd) {
        if this.Disposed || this.Updating || !this.HasOwnProp("PageY")
            return
        if DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") != this.Hwnd
            return
        control := GuiCtrlFromHwnd(hwnd)
        if control && (control.Type = "Edit" || control.Type = "ListView" || control.Type = "ListBox" || control.Type = "DropDownList" || control.Type = "DDL" || control.Type = "ComboBox")
            return
        delta := (wParam >> 16) & 0xFFFF
        if delta >= 0x8000
            delta -= 0x10000
        this.SetOffset(this.X, this.Y - Round(delta / 120 * 96))
        return 0
    }

    Dispose(*) {
        if this.Disposed
            return
        this.Disposed := true
        OnExit(this.ExitHandler,0)
        SetTimer(this.UpdateHandler,0)
        this.PendingResize := false, this.PendingOffset := 0
        OnMessage(0x114,this.ScrollHandler,0)
        OnMessage(0x115,this.ScrollHandler,0)
        OnMessage(0x20A,this.WheelHandler,0)
        SetTimer(this.FocusHandler,0)
        this.LastFocus := 0
    }

    FollowFocus() {
        if this.Disposed
            return
        if !DllCall("IsWindowVisible","Ptr",this.Hwnd) {
            SetTimer(this.FocusHandler,0)
            this.LastFocus := 0
            return
        }
        if this.Updating
            return
        control := DllCall("GetFocus","Ptr")
        if !control || DllCall("GetAncestor","Ptr",control,"UInt",2,"Ptr") != this.Hwnd {
            this.LastFocus := 0
            return
        }
        if control = this.LastFocus
            return
        this.LastFocus := control
        this.Updating := true
        try this.RevealFocusedControl(control)
        finally this.Updating := false
    }

    RevealFocusedControl(control) {
        if !DllCall("IsWindow", "Ptr", this.Hwnd) || !this.HasOwnProp("PageY")
            return
        if control = this.Hwnd || DllCall("GetAncestor", "Ptr", control, "UInt", 2, "Ptr") != this.Hwnd
            return
        rect := Buffer(16)
        DllCall("GetWindowRect", "Ptr", control, "Ptr", rect)
        DllCall("MapWindowPoints", "Ptr", 0, "Ptr", this.Hwnd, "Ptr", rect, "UInt", 2)
        focusedControl := GuiCtrlFromHwnd(control)
        if focusedControl && SubStr(focusedControl.Type, 1, 3) = "Tab"
            NumPut("Int", NumGet(rect,4,"Int") + Round(32 * A_ScreenDPI / 96), rect, 12)
        x := this.X, y := this.Y
        ; Wide controls cannot fit both edges: consistently reveal the right edge.
        if NumGet(rect,8,"Int")-NumGet(rect,0,"Int") > this.PageX
            x += NumGet(rect,8,"Int") - this.PageX
        else if NumGet(rect,0,"Int") < 0
            x += NumGet(rect,0,"Int")
        else if NumGet(rect,8,"Int") > this.PageX
            x += NumGet(rect,8,"Int") - this.PageX
        if NumGet(rect,12,"Int")-NumGet(rect,4,"Int") > this.PageY
            y += NumGet(rect,4,"Int")
        else if NumGet(rect,4,"Int") < 0
            y += NumGet(rect,4,"Int")
        else if NumGet(rect,12,"Int") > this.PageY
            y += NumGet(rect,12,"Int") - this.PageY
        if x != this.X || y != this.Y
            this.ApplyOffset(x, y)
    }
}
