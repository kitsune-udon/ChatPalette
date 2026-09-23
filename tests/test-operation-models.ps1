# Test-Session: Desktop
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app-fixture.ps1')
Invoke-AppFixture -Body @'
    bulk := []
    Loop 501
        bulk.Push({Id:"bulk-" A_Index,Name:"row",Text:"text " A_Index,Slot:0})
    limited := BuildPaletteItems([],bulk,"",false,"")
    Assert(limited.Rows.Length=500 && limited.Truncated && InStr(limited.Hint,"500"),"large palette caps drawing with explanation")
    last := BuildPaletteItems([],bulk,"",false,"text 501")
    Assert(last.Rows.Length=1 && last.Rows[1].ItemId="bulk-501" && last.Rows[1].Index=501 && !last.Truncated,"search reaches records past display limit without changing identity")
    Assert(BuildManagementPresentation([],bulk,"").Rows.Length=501,"management retains all rows")
    bulk.Pop()
    Assert(!BuildPaletteItems([],bulk,"",false,"").Truncated,"exact limit is not reported as truncated")
    ; Every busy-state combination: stopping always works; the owning editor may save preferences.
    for refreshing in [false,true]
        for browserBusy in [false,true]
            for reactionActive in [false,true]
                for editorLabel in ["","キーの編集"] {
                    state := {Refreshing:refreshing,BrowserBusy:browserBusy,ReactionActive:reactionActive,EditorLabel:editorLabel}
                    Assert(EvaluateOperation("stop",state).Allowed,"stop remains available")
                    for action in ["input","edit","reaction"]
                        Assert(EvaluateOperation(action,state).Allowed=(!refreshing && !browserBusy && !reactionActive && editorLabel=""),"conflicting action blocked: " action)
                    Assert(EvaluateOperation("preferences",state).Allowed=(!refreshing && !browserBusy && !reactionActive),"editor can save preferences only outside busy work")
                }
    refusal := EvaluateOperation("input",{Refreshing:false,BrowserBusy:false,ReactionActive:false,EditorLabel:"キーの編集"})
    Assert(refusal.Reason="editor" && InStr(refusal.Message,"キーの編集"),"refusal identifies the active editor")

    modelProfiles := [{Id:"p",Name:"配信者",Channel:"/channel/p",Items:[{Id:"p1",Name:"same",Text:"Body",Slot:1},{Id:"p2",Name:"same",Text:"Body",Slot:0}]}]
    shared := [{Id:"s1",Name:"共通",Text:"shared",Slot:1}]
    model := BuildPaletteItems(modelProfiles,shared,"p",true," Body ")
    Assert(model.Rows.Length=2 && model.Rows[1].ItemId="p1" && model.Rows[2].ItemId="p2","search keeps distinct IDs for equal text")
    Assert(model.Rows[1].Index=1 && model.Rows[2].Index=2 && model.Rows[1].Key="Ctrl+Alt+1","filtered rows preserve source identity and slot")
    modelProfiles[1].Items[1].Text := "changed"
    Assert(model.Rows[1].Text="Body","presentation captures the displayed value without aliasing items")
    model := BuildPaletteItems(modelProfiles,shared,"p",false,"")
    Assert(model.Rows.Length=1 && model.Rows[1].Shared && model.Rows[1].ProfileId="" && model.Rows[1].Key="Ctrl+Alt+3","unmatched auto target exposes shared items only")
    model := BuildPaletteContext(modelProfiles,"p",true,false,"未検出")
    Assert(model.Choice=0 && !model.CanChoose && InStr(model.Context,"共通の弾幕のみ"),"unmatched profile does not appear selected")
    model := BuildPaletteContext(modelProfiles,"p",false,true,"")
    Assert(model.Choice=1 && model.CanChoose && InStr(model.Context,"配信者"),"manual selection uses its stable identity")
    model := BuildManagementPresentation(modelProfiles,shared,"deleted-profile")
    Assert(model.ProfileId="" && model.Choice=1 && !model.HasProfile && model.Rows[1].ItemId="s1","deleted editing target falls back to shared items")
    Assert(BuildPaletteItems([],[],"",false,"").Rows.Length=0,"empty library is representable")

    global RefreshCount := 0
    cycle := RefreshCycle(() => CountRefresh())
    Assert(cycle.Begin(),"initial refresh starts")
    Assert(!cycle.Begin() && !cycle.Begin() && cycle.Pending,"reentrant refreshes are held")
    cycle.End()
    Sleep(40)
    Assert(!cycle.Active && !cycle.Pending && RefreshCount=1,"multiple pending refreshes coalesce into one")
    try {
        cycle.Begin()
        cycle.Begin()
        throw Error("refresh failure")
    } catch {
    } finally {
        cycle.End()
    }
    Sleep(40)
    Assert(!cycle.Active && !cycle.Pending && RefreshCount=2,"failed rendering also releases pending refresh")

    ShowManagement(1)
    RefreshPaletteItems()
    RefreshOperationControls()
    Assert(PaletteInsert.Enabled && PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"idle controls allow actions")
    ActiveReactionJob := CreateReactionJob({Mode:"queued"})
    RefreshOperationControls()
    Assert(!PaletteInsert.Enabled && !PaletteStart.Enabled && !ManagementItemButtons[1].Enabled,"reaction state disables the same actions as handlers")
    CancelReaction()
    Assert(PaletteInsert.Enabled && PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"stopping restores action controls")
    IsBrowserOperationBusy := true
    RefreshOperationControls()
    Assert(!PaletteInsert.Enabled && !PaletteDefaults.Enabled && !ManagementItemButtons[1].Enabled,"worker state disables conflicting controls")
    IsBrowserOperationBusy := false
    RefreshOperationControls()
    ShowShortcutManager()
    Assert(!OperationAllowed("input") && OperationAllowed("preferences"),"editor state permits its own settings save")
    SaveReactionDefaults(CreateReactionOptions(2,10,25,ShortcutKeys["reaction"]))
    Assert(DefaultReactionCount=10,"preferences save succeeds inside editor")
    WinClose("ahk_id " ActiveEditorDialog.Window.Hwnd)
    Sleep(30)
    Assert(!ActiveEditorDialog && PaletteStart.Enabled && ManagementItemButtons[1].Enabled,"closing editor restores actions")
'@ -Helpers @'
CountRefresh() {
    global RefreshCount
    RefreshCount++
}
'@
