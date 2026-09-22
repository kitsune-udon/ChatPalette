# Test-Session: Desktop
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
function Rewrite($relative,$before,$after) {
 $p=Join-Path $release $relative
 $s=[IO.File]::ReadAllText($p)
 if(!$s.Contains($before)){throw "Missing injection: $relative"}
 [IO.File]::WriteAllText($p,$s.Replace($before,$after),[Text.UTF8Encoding]::new($true))
}
Rewrite 'src/ui/reaction_feedback.ahk' '            text := view.AddText("w360 r6", "")' ('            text := view.AddText("w360 r6", "")'+"`r`n            ProbeOverlayConstruction()")
Rewrite 'src/ui/palette/palette_view.ahk' '            for row in rows' '            for row in rows {'
Rewrite 'src/ui/palette/palette_view.ahk' '                PaletteList.Add("",row.Shared ? "共通" : "配信者",row.Label,row.Key,row.ItemId)' ('                PaletteList.Add("",row.Shared ? "共通" : "配信者",row.Label,row.Key,row.ItemId)'+"`r`n                ProbeListUpdate()`r`n            }")
Rewrite 'src/ui/panel_viewport.ahk' '    ApplyOffset(x, y) {' ("    ApplyOffset(x, y) {`r`n        ProbeViewport(this)")
Rewrite 'src/input/input_controller.ahk' 'RequestDanmakuInput(request) {' 'OriginalRequestDanmakuInput(request) {'
Rewrite 'src/ui/management/management_view.ahk' '        for row in model.Rows' '        for row in model.Rows {'
Rewrite 'src/ui/management/management_view.ahk' '        ManagedList.ModifyCol(1,160)' ("            ProbeManagementUpdate()`r`n        }`r`n        ManagedList.ModifyCol(1,160)")
$tests=@'
OnExit(StopBrowserWorker)
global UiChecks := 0, ProbeListArmed := false, ProbeViewportArmed := false, InputCalls := 0
try {
    AutoMode := false
    ReactionExecutionStatus := {Phase:"finished",Message:"fixture",Final:true}
    global ProbeOverlayFailure := true
    failed := false
    try ShowReactionProgress()
    catch
        failed := true
    CheckUi(failed && !ReactionOverlayReady && !ReactionOverlayBuilding && !ReactionOverlay,"failed construction publishes nothing and unlocks retry")
    ShowReactionProgress()
    CheckUi(ReactionOverlayReady && IsObject(ReactionOverlayHint) && IsObject(ReactionOverlayStop),"overlay publishes completed controls")
    ReactionOverlay.Hide()
    ExecuteDanmakuCommand("add","",0,{Name:"first",Text:"same",Slot:0})
    RefreshPaletteItems()
    global ProbeListFailure := true
    failed := false
    try RefreshPaletteItems()
    catch
        failed := true
    CheckUi(failed && !PaletteRefresh.Active && PaletteRows.Length=0 && PaletteList.GetCount()=0,"failed native update clears incomplete view and unlocks retry")
    RefreshPaletteItems()
    CheckUi(PaletteRows.Length=1,"list rebuild recovers after failure")
    oldRows := PaletteRows
    ExecuteDanmakuCommand("add","",0,{Name:"second",Text:"second",Slot:0})
    ProbeListArmed := true
    RefreshPaletteItems()
    CheckUi(!ProbeListArmed && PaletteRows.Length=2 && PaletteList.GetCount()=2,"list publishes complete snapshot")
    CheckUi(!PaletteRefresh.Active && InputCalls=0,"update restores interaction without sending")
    old := SharedDanmakuItems[1]
    SharedDanmakuItems[1] := old.Clone()
    SharedDanmakuItems[1].Id := NewRecordId()
    PaletteList.Modify(1,"Select Focus")
    InsertPaletteItem()
    CheckUi(InputCalls=0 && PaletteRows[1].ItemId=SharedDanmakuItems[1].Id,"same text with changed identity is refreshed rather than sent")
    PaletteRows := []
    InsertPaletteItem()
    CheckUi(InputCalls=0,"stale index is rejected")
    RefreshPaletteItems()
    BuildManagement()
    global ProbeManagementArmed := true
    RefreshManagement()
    CheckUi(!ProbeManagementArmed && !ManagementRefresh.Active && !DanmakuEditorWindow,"management defers nested refresh and blocks editing")
    CheckUi(SharedDanmakuItems.Length=2 && ManagedList.GetCount()=2,"management refresh cannot delete or undo data")
    PresentWindow(PaletteWindow,"w260 h300",ResizePalette)
    ProbeViewportArmed := true
    PaletteViewport.SetOffset(0,0)
    CheckUi(!ProbeViewportArmed && PaletteViewport.PendingResize && IsObject(PaletteViewport.PendingOffset),"nested updates are queued")
    PaletteViewport.FlushUpdates()
    CheckUi(!PaletteViewport.Updating && !PaletteViewport.PendingResize && !PaletteViewport.PendingOffset,"queued updates drain")
    PaletteViewport.Updating := true
    PaletteViewport.SetOffset(10,20)
    PaletteViewport.SetOffset(20,30)
    CheckUi(PaletteViewport.PendingOffset.X=20 && PaletteViewport.PendingOffset.Y=30,"latest pending offset wins")
    PaletteViewport.Updating := false
    PaletteViewport.Dispose()
    PaletteViewport.FlushUpdates()
    CheckUi(!PaletteViewport.PendingOffset && !PaletteViewport.PendingResize,"disposed viewport drops pending work")
    FileAppend("PASS: " UiChecks " UI publication and reentry checks; no browser operations`n","*")
    ExitApp()
} catch as failure {
    FileAppend("FAIL: " failure.Message " at " failure.File ":" failure.Line "`n","*")
    ExitApp(1)
}
CheckUi(value,label) {
    global UiChecks
    if !value
        throw Error(label)
    UiChecks++
}
ProbeOverlayConstruction() {
    global ProbeOverlayFailure
    if IsSet(ProbeOverlayFailure) && ProbeOverlayFailure {
        ProbeOverlayFailure := false
        throw Error("fixture construction failure")
    }
    CheckUi(!ReactionOverlayReady && !ReactionOverlayText,"incomplete overlay not published")
    RenderReactionStatus()
    ShowReactionProgress()
    CheckUi(!ReactionOverlayReady,"nested show cannot publish incomplete overlay")
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
    CheckUi(PaletteRefresh.Active,"list updating state precedes native mutation")
    PaletteList.Modify(1,"Select Focus")
    InsertPaletteItem()
    OpenPaletteLibrary()
    PreviewPaletteItem()
    RefreshPaletteItems()
    CheckUi(PaletteRows.Length=1 && PaletteRefresh.Pending,"old snapshot retained until publish; nested refresh deferred")
}
ProbeManagementUpdate() {
    global ProbeManagementArmed
    if !IsSet(ProbeManagementArmed) || !ProbeManagementArmed
        return
    ProbeManagementArmed := false
    CheckUi(ManagementRefresh.Active,"management owns update guard")
    SelectManagedRow(1)
    HandleDanmakuCommand("delete")
    OpenDanmakuEditor(true)
    UndoLibraryChange()
    RefreshManagement()
    CheckUi(ManagementRefresh.Pending,"nested management refresh coalesces")
}
ProbeViewport(viewport) {
    global ProbeViewportArmed
    if !IsSet(ProbeViewportArmed) || !ProbeViewportArmed
        return
    ProbeViewportArmed := false
    CheckUi(viewport.Updating,"scrolling owns update guard")
    viewport.Resize()
    viewport.SetOffset(10,20)
}
RequestDanmakuInput(*) {
    global InputCalls
    InputCalls++
}
'@
Invoke-AppTest -Runtime $release -Body $tests
