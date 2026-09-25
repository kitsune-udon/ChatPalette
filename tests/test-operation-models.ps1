# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$source = @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
modelKeys := DefaultShortcutKeys(), modelKeys["profile1"] := "^+F11", modelKeys["shared1"] := "^+F12"
bulk := []
Loop 501
    bulk.Push({Id:"bulk-" A_Index,Name:"row",Text:"text " A_Index,Slot:0})
limited := BuildPaletteItems(0,bulk,"",modelKeys)
Assert(limited.Rows.Length=500 && limited.Truncated && InStr(limited.Hint,"500"),"large palette caps drawing with explanation")
last := BuildPaletteItems(0,bulk,"text 501",modelKeys)
Assert(last.Rows.Length=1 && last.Rows[1].ItemId="bulk-501" && last.Rows[1].Index=501 && !last.Truncated,"search reaches records past display limit without changing identity")
Assert(BuildManagementPresentation([],bulk,"",modelKeys).Rows.Length=501,"management retains all rows")
bulk.Pop()
Assert(!BuildPaletteItems(0,bulk,"",modelKeys).Truncated,"exact limit is not reported as truncated")
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
model := BuildPaletteItems(modelProfiles[1],shared," Body ",modelKeys)
Assert(model.Rows.Length=2 && model.Rows[1].ItemId="p1" && model.Rows[2].ItemId="p2","search keeps distinct IDs for equal text")
Assert(model.Rows[1].Index=1 && model.Rows[2].Index=2 && model.Rows[1].Key="Ctrl+Shift+F11","filtered rows preserve source identity and the supplied key assignment")
modelProfiles[1].Items[1].Text := "changed"
Assert(model.Rows[1].Text="Body","presentation captures the displayed value without aliasing items")
model := BuildPaletteItems(0,shared,"",modelKeys)
Assert(model.Rows.Length=1 && model.Rows[1].ProfileId="" && model.Rows[1].Key="Ctrl+Shift+F12","unmatched auto target exposes shared items with the supplied key assignment")
model := BuildPaletteContext(modelProfiles,0,true,"未検出")
Assert(model.Choice=0 && !model.CanChoose && InStr(model.Context,"共通の弾幕のみ"),"unmatched profile does not appear selected")
model := BuildPaletteContext(modelProfiles,modelProfiles[1],false,"")
Assert(model.Choice=1 && model.CanChoose && InStr(model.Context,"配信者"),"manual selection uses its stable identity")
model := BuildManagementPresentation(modelProfiles,shared,"deleted-profile",modelKeys)
Assert(model.ProfileId="" && model.Choice=1 && model.Rows[1].ItemId="s1","deleted editing target falls back to shared items")
Assert(BuildPaletteItems(0,[],"",modelKeys).Rows.Length=0,"empty library is representable")

global RefreshCount := 0
cycle := RefreshCycle(() => CountRefresh())
Assert(cycle.Begin(),"initial refresh starts")
Assert(!cycle.Begin() && !cycle.Begin() && cycle.Pending,"reentrant refreshes are held")
cycle.End()
deadline := A_TickCount+1000
while RefreshCount<1 && A_TickCount<deadline
    Sleep(10)
Assert(!cycle.Active && !cycle.Pending && RefreshCount=1,"multiple pending refreshes coalesce into one")
try {
    cycle.Begin()
    cycle.Begin()
    throw Error("refresh failure")
} catch {
} finally {
    cycle.End()
}
deadline := A_TickCount+1000
while RefreshCount<2 && A_TickCount<deadline
    Sleep(10)
Assert(!cycle.Active && !cycle.Pending && RefreshCount=2,"failed rendering also releases pending refresh")

; An explicit refresh can fulfill queued work before its timer is dispatched.
for reenterLatest in [false,true] {
    before := RefreshCount
    Critical("On")
    try {
        cycle.Begin(), cycle.Begin(), cycle.End()
        Assert(cycle.Begin(),"a newer explicit refresh starts before the queued callback")
        if reenterLatest
            cycle.Begin()
        cycle.End()
    } finally Critical("Off")
    Sleep(40)
    Assert(RefreshCount=before+(reenterLatest ? 1 : 0),"new refresh replaces the old reservation but preserves its own reentry")
    Assert(!cycle.Active && !cycle.Pending,"completed refresh leaves no owned or pending work")
}

FileAppend("PASS: " Checks " operation model checks; no application startup`n","*")
ExitApp()
CountRefresh() {
    global RefreshCount
    RefreshCount++
}
'@
Invoke-AhkTest -Runtime $release -Source $source
