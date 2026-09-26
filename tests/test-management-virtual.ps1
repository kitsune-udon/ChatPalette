# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
$body=@'
AutoMode := false
SharedDanmakuItems := [{Id:"alpha",Name:"Alpha 日本語",Text:"first",Slot:0},
    {Id:"beta",Name:"Beta",Text:"second",Slot:0},{Id:"gamma",Name:"Gamma",Text:"third",Slot:0}]
ShowManagement(1)
RequireTestWindowActive(ManagementWindow.Hwnd)
Assert(WinGetStyle("ahk_id " ManagedList.Hwnd) & 0x1000,"management uses owner data")
Assert(FindNative("BETA",-1,2)=1,"native exact search is case insensitive")
Assert(FindNative("Al",-1,8)=0,"native prefix search finds the first name")
Assert(FindNative("Al",1,8)=-1,"search without wrapping stops at the end")
Assert(FindNative("Al",1,0x28)=0,"wrapped search returns to the beginning")
Assert(FindNative("et",-1,4)=-1,"SUBSTRING follows the documented prefix semantics")
Assert(FindNative("missing",-1,2)=-1,"unmatched names are rejected")
SelectManagedRow(1)
ManagedList.Focus()
SendMessage(0x102,Ord("b"),1,ManagedList.Hwnd) ; WM_CHAR, delivered only to the isolated list.
Assert(ManagedList.GetNext()=2 && ManagedList.GetText(2,4)=="beta","typing a prefix selects the corresponding identity")
for capacity in [1,2,8] {
    text := Buffer((capacity+2)*2,0xA5), item := Buffer(3*A_PtrSize+(A_PtrSize=8 ? 88 : 60),0)
    offset := 3*A_PtrSize, pointerOffset := offset+(A_PtrSize=8 ? 24 : 20)
    NumPut("UInt",1,"Int",0,"Int",0,item,offset)
    NumPut("Ptr",text.Ptr+2,item,pointerOffset), NumPut("Int",capacity,item,pointerOffset+A_PtrSize)
    ProvideManagedText(ManagedList,item.Ptr)
    Assert(NumGet(text,0,"UShort")=0xA5A5 && NumGet(text,(capacity+1)*2,"UShort")=0xA5A5,"text callback respects both buffer boundaries: " capacity)
    Assert(StrGet(text.Ptr+2,"UTF-16")==SubStr("Alpha 日本語",1,capacity-1),"text callback terminates bounded Unicode text: " capacity)
}
previousContent := ManagedList.Content
SharedDanmakuItems := SharedDanmakuItems.Clone(), SharedDanmakuItems[1] := SharedDanmakuItems[1].Clone()
SharedDanmakuItems[1].Name := "Changed", SharedDanmakuItems[1].Text := "replacement"
Assert(ManagedList.GetText(1,1)=="Alpha 日本語" && ManagedList.GetText(1,2)=="first","native display retains the old committed sequence until refresh")
RefreshManagement()
Assert(ManagedList.GetText(1,1)=="Changed" && ManagedList.GetText(1,2)=="replacement" && ManagedList.GetText(1,4)=="alpha","refresh publishes new values with the same identity")
Assert(ManagedCellText(previousContent,1,2)=="first","publishing a new native display leaves the previous snapshot intact")
; Selection restoration uses the published identities without reading every virtual cell back.
items := []
Loop 1000
    items.Push({Id:"item-" A_Index,Name:"row" A_Index,Text:"body",Slot:0})
global KeyReads := 0
observer := CallbackCreate(ObserveManagedText,,6)
if !DllCall("comctl32\SetWindowSubclass","Ptr",ManagedList.Hwnd,"Ptr",observer,"UPtr",1,"UPtr",0) {
    CallbackFree(observer)
    throw Error("Cannot observe native identity reads")
}
try {
    for scenario in ["unchanged","moved","removed"] {
        SharedDanmakuItems := items
        RefreshManagement()
        SelectManagedRow(1000)
        replacement := items.Clone()
        if scenario != "unchanged" {
            selected := replacement.Pop()
            if scenario = "moved"
                replacement.InsertAt(1,selected)
        }
        SharedDanmakuItems := replacement
        KeyReads := 0
        RefreshManagement()
        Assert(KeyReads<=2,"selection restoration avoids per-row native identity reads: " scenario " reads=" KeyReads)
        expected := scenario="unchanged" ? 1000 : 1
        Assert(ManagedList.GetNext()=expected,"selection restores the current index or falls back after removal: " scenario)
        KeyReads := 0
        Assert(ManagedList.GetText(expected,4)==(scenario="removed" ? "item-1" : "item-1000"),"native selected identity matches the published sequence: " scenario)
        Assert(KeyReads=1,"the observer detects one explicit native identity read: " scenario)
    }
} finally {
    Assert(DllCall("comctl32\RemoveWindowSubclass","Ptr",ManagedList.Hwnd,"Ptr",observer,"UPtr",1),"native identity observer is detached before release")
    CallbackFree(observer)
}
SharedDanmakuItems := []
RefreshManagement()
SelectListRow(ManagedList,0)
Assert(FindNative("A",-1,0x28)=-1 && ManagedList.GetCount()=0 && ManagedList.GetNext()=0,"empty lists support search and selection clearing")
FileAppend("PASS: " Checks " virtual management notification, search and buffer checks`n","*")
ExitApp()
ObserveManagedText(hwnd,message,wParam,lParam,id,data) {
    global KeyReads
    ; Count explicit text reads (GETITEMW/GETITEMTEXTW), not display notifications from painting.
    if (message=0x1073 || (message=0x104B && (NumGet(lParam,0,"UInt") & 1))) && NumGet(lParam,8,"Int")=3
        KeyReads++
    return DllCall("comctl32\DefSubclassProc","Ptr",hwnd,"UInt",message,"UPtr",wParam,"Ptr",lParam,"Ptr")
}
FindNative(query,start,flags) {
    info := Buffer(A_PtrSize=8 ? 40 : 24,0)
    NumPut("UInt",flags,info), NumPut("Ptr",StrPtr(query),info,A_PtrSize)
    result := SendMessage(0x1053,start,info.Ptr,ManagedList.Hwnd) & 0xFFFFFFFF ; LVM_FINDITEMW
    return result=0xFFFFFFFF ? -1 : result
}
'@
Invoke-AppTest -Runtime $release -Body $body
