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
SharedDanmakuItems := []
RefreshManagement()
SelectListRow(ManagedList,0)
Assert(FindNative("A",-1,0x28)=-1 && ManagedList.GetCount()=0 && ManagedList.GetNext()=0,"empty lists support search and selection clearing")
FileAppend("PASS: " Checks " virtual management notification, search and buffer checks`n","*")
ExitApp()
FindNative(query,start,flags) {
    info := Buffer(A_PtrSize=8 ? 40 : 24,0)
    NumPut("UInt",flags,info), NumPut("Ptr",StrPtr(query),info,A_PtrSize)
    result := SendMessage(0x1053,start,info.Ptr,ManagedList.Hwnd) & 0xFFFFFFFF ; LVM_FINDITEMW
    return result=0xFFFFFFFF ? -1 : result
}
'@
Invoke-AppTest -Runtime $release -Body $body
