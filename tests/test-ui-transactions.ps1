# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
Edit-TestSource $release 'src/ui/reaction_feedback.ahk' '            text := view.AddText("w360 r6", "")' ('            text := view.AddText("w360 r6", "")'+"`r`n            ProbeOverlayConstruction(view)")
Edit-TestSource $release 'src/ui/palette/palette_view.ahk' '            for row in rows' '            for row in rows {'
Edit-TestSource $release 'src/ui/palette/palette_view.ahk' '                PaletteList.Add("",row.ProfileId = "" ? "共通" : "配信者",row.Name "　" row.Text,row.Key,row.ItemId)' ('                PaletteList.Add("",row.ProfileId = "" ? "共通" : "配信者",row.Name "　" row.Text,row.Key,row.ItemId)'+"`r`n                ProbeListUpdate()`r`n            }")
Edit-TestSource $release 'src/ui/panel_viewport.ahk' '    ApplyOffset(x, y) {' ("    ApplyOffset(x, y) {`r`n        ProbeViewport(this)")
Edit-TestSource $release 'src/input/input_controller.ahk' 'RequestDanmakuInput(request) {' 'OriginalRequestDanmakuInput(request) {'
Edit-TestSource $release 'src/ui/management/management_view.ahk' '                ManagedList.Add("",row.Name,row.Text,row.Key,row.ItemId)' ('                ManagedList.Add("",row.Name,row.Text,row.Key,row.ItemId)' + "`r`n            ProbeManagementUpdate()")
Edit-TestSource $release 'src/ui/panel_viewport.ahk' '            OnMessage(0x115,this.ScrollHandler)' ('            OnMessage(0x115,this.ScrollHandler)' + "`r`n            ProbeViewportRegistration(this)")
Edit-TestSource $release 'src/ui/help_view.ahk' '        topics.Choose(ManagementTabs.Value = 1 ? 2 : 3)' ('        topics.Choose(ManagementTabs.Value = 1 ? 2 : 3)' + "`r`n    ProbeInfoDialogBuild(view)")
Edit-TestSource $release 'src/ui/reaction_feedback.ahk' '    details.AddButton("x12 y324 w180","結果と詳細をコピー").OnEvent("Click", (*) => A_Clipboard := content)' ('    details.AddButton("x12 y324 w180","結果と詳細をコピー").OnEvent("Click", (*) => A_Clipboard := content)' + "`r`n    ProbeInfoDialogBuild(details)")
Edit-TestSource $release 'src/ui/window_presenter.ahk' 'PresentWindow(view, options := "", layout := 0, activate := true) {' ('PresentWindow(view, options := "", layout := 0, activate := true) {' + "`r`n    if IsSet(ProbeInfoFailure) && ProbeInfoFailure = ""show"" && view.Hwnd = ProbeInfoHwnd`r`n        throw Error(""fixture info show failure"")")
$tests=@'
global ProbeListArmed := false, ProbeViewportArmed := false, InputCalls := 0
global ProbeViewportRegistrationFailure := true, ProbeRegisteredViewport := 0, DeletedRegisteredViewports := 0
registrationView := Gui(,"viewport registration fixture")
failed := false
try RegisteredViewportProbe(registrationView,160,120)
catch as failure {
    failed := failure.Message == "fixture viewport registration failure"
    if !failed
        throw failure
}
Assert(failed && ProbeRegisteredViewport.Disposed,"partial viewport registration is disposed before publication")
ProbeRegisteredViewport := 0
Assert(DeletedRegisteredViewports=1,"failed viewport releases registered GUI and message callbacks")
Assert(DllCall("IsWindow","Ptr",registrationView.Hwnd),"failed viewport registration leaves the host window owned by its caller")
ProbeViewportRegistrationFailure := false
registered := RegisteredViewportProbe(registrationView,160,120)
registered.Dispose(), registered := 0
Assert(DeletedRegisteredViewports=2,"viewport registration can be retried on the same window and released")
registrationView.Destroy()
global ProbeInfoFailure := "", ProbeInfoHwnd := 0
for open in [Help,ShowReactionDetails] {
    for point in ["build","show"] {
        ProbeInfoFailure := point, ProbeInfoHwnd := 0, failed := false
        try open.Call()
        catch as failure
            failed := failure.Message == "fixture info " point " failure"
        Assert(failed,"informational dialog preserves the failure: " open.Name "/" point)
        Assert(ProbeInfoHwnd && !DllCall("IsWindow","Ptr",ProbeInfoHwnd),"failed informational dialog is destroyed: " open.Name "/" point)
        ProbeInfoFailure := ""
        open.Call()
        shown := WinExist("A")
        Assert(IsAppWindow(shown) && shown != PaletteWindow.Hwnd,"informational dialog can be retried: " open.Name "/" point)
        WinClose("ahk_id " shown)
        Assert(WinWaitClose("ahk_id " shown,,2),"informational dialog close releases its window: " open.Name "/" point)
    }
}
AutoMode := false
ReactionExecutionStatus := {Phase:"finished",Message:"fixture"}
global ProbeOverlayFailure := true, ProbeOverlayHwnd := 0
failed := false
try ShowReactionProgress()
catch
    failed := true
Assert(failed && !ReactionOverlay,"failed construction publishes nothing")
Assert(!DllCall("IsWindow","Ptr",ProbeOverlayHwnd),"failed construction destroys its unpublished window")
ShowReactionProgress()
Assert(ReactionOverlay && IsObject(ReactionOverlay.Text) && IsObject(ReactionOverlay.Hint) && IsObject(ReactionOverlay.Stop),"retry publishes completed controls")
ReactionOverlay.Window.Hide()
ExecuteDanmakuCommand("add","","",{Name:"first",Text:"same",Slot:0})
RefreshPaletteItems()
global ProbeListFailure := true
failed := false
try RefreshPaletteItems()
catch
    failed := true
Assert(failed && !PaletteRefresh.Active && PaletteRows.Length=0 && PaletteList.GetCount()=0,"failed native update clears incomplete view and unlocks retry")
RefreshPaletteItems()
Assert(PaletteRows.Length=1,"list rebuild recovers after failure")
oldRows := PaletteRows
ExecuteDanmakuCommand("add","","",{Name:"second",Text:"second",Slot:0})
ProbeListArmed := true
RefreshPaletteItems()
Assert(!ProbeListArmed && PaletteRows.Length=2 && PaletteList.GetCount()=2,"list publishes complete snapshot")
Assert(!PaletteRefresh.Active && InputCalls=0,"update restores interaction without sending")
old := SharedDanmakuItems[1]
SharedDanmakuItems[1] := old.Clone()
SharedDanmakuItems[1].Id := NewRecordId()
PaletteList.Modify(1,"Select Focus")
InsertPaletteItem()
Assert(InputCalls=0 && PaletteRows[1].ItemId=SharedDanmakuItems[1].Id,"same text with changed identity is refreshed rather than sent")
PaletteRows := []
InsertPaletteItem()
Assert(InputCalls=0,"stale index is rejected")
SharedDanmakuItems[1] := old
RefreshPaletteItems()
BuildManagement()
global ProbeManagementArmed := true
RefreshManagement()
Assert(!ProbeManagementArmed && !ManagementRefresh.Active && !ActiveEditorDialog,"management defers nested refresh and blocks editing")
Assert(SharedDanmakuItems.Length=2 && ManagedList.GetCount()=2,"management refresh cannot delete or undo data")
ManagedList.Add("","obsolete","obsolete","","obsolete-id")
global ProbeManagementFailure := true
failed := false
try RefreshManagement()
catch as failure
    failed := failure.Message == "fixture management update failure"
Assert(failed && !ManagementRefresh.Active,"failed row replacement releases the management guard")
Assert(SharedDanmakuItems.Length=2 && ManagedList.GetCount()=3,"failed refresh preserves data even before excess rows are removed")
RefreshManagement()
Assert(ManagedList.GetCount()=2 && ManagedList.GetText(2,4)==SharedDanmakuItems[2].Id && !ManagementRefresh.Active,"retry repairs the incomplete list without duplicating rows")
PresentWindow(PaletteWindow,"w260 h300",ResizePalette)
ProbeViewportArmed := true
PaletteViewport.SetOffset(0,0)
Assert(!ProbeViewportArmed && PaletteViewport.PendingResize && IsObject(PaletteViewport.PendingOffset),"nested updates are queued")
PaletteViewport.FlushUpdates()
Assert(!PaletteViewport.Updating && !PaletteViewport.PendingResize && !PaletteViewport.PendingOffset,"queued updates drain")
previousCritical := A_IsCritical
Critical("On")
try {
    ProbeViewportArmed := true
    PaletteViewport.SetOffset(0,0)
    PaletteViewport.SetOffset(30,40)
    PaletteViewport.FlushUpdates()
    Assert(PaletteViewport.X=30 && PaletteViewport.Y=40,"new scrolling supersedes an older queued position")
    PaletteViewport.Updating := true
    PaletteViewport.Resize()
    PaletteViewport.SetOffset(30,40)
    PaletteViewport.Updating := false
    ProbeViewportArmed := true
    PaletteViewport.FlushUpdates()
    Assert(PaletteViewport.X=10 && PaletteViewport.Y=20,"scrolling requested during layout supersedes the earlier queued position")
    PaletteViewport.FlushUpdates()
    Assert(!PaletteViewport.PendingResize && !PaletteViewport.PendingOffset,"reentrant layout requests finish without replaying old positions")
} finally Critical(previousCritical)
PaletteViewport.Updating := true
PaletteViewport.SetOffset(10,20)
PaletteViewport.SetOffset(20,30)
Assert(PaletteViewport.PendingOffset.X=20 && PaletteViewport.PendingOffset.Y=30,"latest pending offset wins")
PaletteViewport.Updating := false
PaletteViewport.Dispose()
PaletteViewport.FlushUpdates()
Assert(!PaletteViewport.PendingOffset && !PaletteViewport.PendingResize,"disposed viewport drops pending work")
FileAppend("PASS: " Checks " UI publication and reentry checks; no browser operations`n","*")
ExitApp()
class RegisteredViewportProbe extends PanelViewport {
    __Delete() {
        global DeletedRegisteredViewports
        DeletedRegisteredViewports++
    }
}
ProbeInfoDialogBuild(view) {
    global ProbeInfoHwnd
    if !IsSet(ProbeInfoFailure) || ProbeInfoFailure = ""
        return
    ProbeInfoHwnd := view.Hwnd
    if ProbeInfoFailure = "build"
        throw Error("fixture info build failure")
}
ProbeViewportRegistration(viewport) {
    global ProbeRegisteredViewport
    if IsSet(ProbeViewportRegistrationFailure) && ProbeViewportRegistrationFailure {
        ProbeRegisteredViewport := viewport
        throw Error("fixture viewport registration failure")
    }
}
ProbeOverlayConstruction(view) {
    global ProbeOverlayFailure, ProbeOverlayHwnd
    ProbeOverlayHwnd := view.Hwnd
    if IsSet(ProbeOverlayFailure) && ProbeOverlayFailure {
        ProbeOverlayFailure := false
        throw Error("fixture construction failure")
    }
    Assert(!ReactionOverlay,"incomplete overlay not published")
    RenderReactionStatus()
    ShowReactionProgress()
    Assert(!ReactionOverlay,"nested show cannot publish incomplete overlay")
}
ProbeListUpdate() {
    global ProbeListFailure
    if IsSet(ProbeListFailure) && ProbeListFailure {
        ProbeListFailure := false
        throw Error("fixture list update failure")
    }
    global ProbeListArmed
    if !IsSet(ProbeListArmed) || !ProbeListArmed
        return
    ProbeListArmed := false
    Assert(PaletteRefresh.Active,"list updating state precedes native mutation")
    PaletteList.Modify(1,"Select Focus")
    InsertPaletteItem()
    OpenPaletteLibrary()
    PreviewPaletteItem()
    RefreshPaletteItems()
    Assert(PaletteRows.Length=1 && PaletteRefresh.Pending,"old snapshot retained until publish; nested refresh deferred")
}
ProbeManagementUpdate() {
    global ProbeManagementFailure
    if IsSet(ProbeManagementFailure) && ProbeManagementFailure {
        ProbeManagementFailure := false
        throw Error("fixture management update failure")
    }
    global ProbeManagementArmed
    if !IsSet(ProbeManagementArmed) || !ProbeManagementArmed
        return
    ProbeManagementArmed := false
    Assert(ManagementRefresh.Active,"management owns update guard")
    SelectManagedRow(1)
    HandleDanmakuCommand("delete")
    OpenDanmakuEditor(true)
    UndoLibraryChange()
    RefreshManagement()
    Assert(ManagementRefresh.Pending,"nested management refresh coalesces")
}
ProbeViewport(viewport) {
    global ProbeViewportArmed
    if !IsSet(ProbeViewportArmed) || !ProbeViewportArmed
        return
    ProbeViewportArmed := false
    Assert(viewport.Updating,"scrolling owns update guard")
    viewport.Resize()
    viewport.SetOffset(10,20)
}
RequestDanmakuInput(*) {
    global InputCalls
    InputCalls++
}
'@
Invoke-AppTest -Runtime $release -Body $tests
