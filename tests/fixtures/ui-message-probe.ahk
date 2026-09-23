; Observe native control effects without changing application sources.
class UiMessageProbe {
    static Renders := 0
    static Writes := 0
    static Watched := []
    static Callback := CallbackCreate(ObjBindMethod(UiMessageProbe,"Observe"),,6)
    static Start() {
        for control in PaletteWindow {
            if !DllCall("comctl32\SetWindowSubclass","Ptr",control.Hwnd,"Ptr",this.Callback,"UPtr",1,"UPtr",0)
                throw Error("Cannot observe control messages")
            this.Watched.Push(control.Hwnd)
        }
        OnExit(ObjBindMethod(this,"Stop"))
    }
    static Stop(*) {
        for hwnd in this.Watched
            if DllCall("IsWindow","Ptr",hwnd)
                DllCall("comctl32\RemoveWindowSubclass","Ptr",hwnd,"Ptr",this.Callback,"UPtr",1)
        this.Watched := []
    }
    static Observe(hwnd,msg,wParam,lParam,id,data) {
        if msg = 0x1009 && hwnd = PaletteList.Hwnd
            this.Renders++
        if msg = 0x000A || msg = 0x000C
            this.Writes++
        return DllCall("comctl32\DefSubclassProc","Ptr",hwnd,"UInt",msg,"UPtr",wParam,"Ptr",lParam,"Ptr")
    }
}
