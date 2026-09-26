# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$source = @'
#Requires AutoHotkey v2.0
#Include %A_ScriptDir%\src\app\app_modules.ahk
modelKeys := DefaultShortcutKeys(), modelKeys["profile1"] := "^+F11", modelKeys["shared1"] := "^+F12"
; Canonical spelling must stay valid for every supported function key.
Loop 12 {
    functionBinding := "^!F" A_Index, normalizedBinding := CanonicalShortcutKey(functionBinding)
    Assert(ValidShortcutKey(functionBinding) && ValidShortcutKey(normalizedBinding),"function key validation agrees with canonical spelling: " A_Index)
    normalizedKeys := DefaultShortcutKeys(), normalizedKeys["chat_focus"] := normalizedBinding
    ValidateShortcutMap(normalizedKeys)
    originalKeys := normalizedKeys.Clone(), originalKeys["chat_focus"] := "!^F" A_Index
    Assert(ChangedShortcutBindings(originalKeys,normalizedKeys).Count=0,"function key spelling does not reinstall a binding: " A_Index)
}
for invalidBinding in ["^!f0","^!f13","^!f01","^^!f1","!f1","^f1"]
    Assert(!ValidShortcutKey(invalidBinding),"function key bounds and modifier requirements remain enforced: " invalidBinding)
bulk := []
Loop 501
    bulk.Push({Id:"bulk-" A_Index,Name:"row",Text:"text " A_Index,Slot:0})
limited := BuildPaletteItems(0,bulk,"",modelKeys)
Assert(limited.Rows.Length=500 && limited.Hint="先頭500件を表示しています。検索で絞り込んでください。","large palette caps drawing with explanation")
last := BuildPaletteItems(0,bulk,"text 501",modelKeys)
Assert(last.Rows.Length=1 && last.Rows[1].ItemId="bulk-501" && last.Rows[1].Index=501 && last.Hint="弾幕は入力のみ。内容を確認してYouTubeで送信します。","search reaches records past display limit without changing identity")
Assert(BuildManagementPresentation([],bulk,"",modelKeys).Content.Items.Length=501,"management retains all rows")
bulk.Pop()
Assert(BuildPaletteItems(0,bulk,"",modelKeys).Hint="弾幕は入力のみ。内容を確認してYouTubeで送信します。","exact limit is not reported as truncated")
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
Assert(model.Choice=0 && InStr(model.Context,"共通の弾幕のみ"),"unmatched profile does not appear selected")
model := BuildPaletteContext(modelProfiles,modelProfiles[1],false,"")
Assert(model.Choice=1 && InStr(model.Context,"配信者"),"manual selection uses its stable identity")
; Choices borrow immutable profiles until the control captures labels and IDs.
choiceProfiles := [{Id:"case",Name:"同名",Channel:"",Items:[]},{Id:"CASE",Name:"同名",Channel:"",Items:[]}]
oldContext := BuildPaletteContext(choiceProfiles,choiceProfiles[2],false,"")
oldManagement := BuildManagementPresentation(choiceProfiles,[],"CASE",modelKeys)
Assert(oldContext.Choice=2 && oldManagement.Choice=3,"equal labels retain case-sensitive profile identity")
Assert(choiceProfiles.Length=2 && choiceProfiles[1].Id=="case" && oldManagement.Choices[1].Id="",
    "management prepends shared choice without changing published profiles")
choiceProfiles := choiceProfiles.Clone(), choiceProfiles[2] := choiceProfiles[2].Clone()
choiceProfiles[2].Name := "変更後", choiceProfiles.RemoveAt(1)
nextContext := BuildPaletteContext(choiceProfiles,choiceProfiles[1],false,"")
nextManagement := BuildManagementPresentation(choiceProfiles,[],"CASE",modelKeys)
Assert(oldContext.Choices.Length=2 && oldContext.Choices[2].Id=="CASE" && oldContext.Choices[2].Name="同名",
    "prior palette choices survive committed rename and removal")
Assert(oldManagement.Choices.Length=3 && oldManagement.Choices[3].Id=="CASE" && oldManagement.Choices[3].Name="同名",
    "prior management choices survive committed rename and removal")
Assert(nextContext.Choice=1 && nextManagement.Choice=2 && nextContext.Choices[1].Name="変更後"
    && nextManagement.Choices[2].Name="変更後","refresh observes the new label and shifted position for the same ID")
Assert(BuildPaletteContext([],0,false,"").Choices.Length=0 && BuildManagementPresentation([],[],"",modelKeys).Choices.Length=1,
    "empty library has no palette profile and only the shared management choice")
model := BuildManagementPresentation(modelProfiles,shared,"deleted-profile",modelKeys)
Assert(model.ProfileId="" && model.Choice=1 && ManagedCellText(model.Content,1,4)="s1","deleted editing target falls back to shared items")
Assert(ManagedCellText(model.Content,1,1)="共通" && ManagedCellText(model.Content,1,2)="shared" && ManagedCellText(model.Content,1,3)="Ctrl+Shift+F12","management resolves displayed values and captured shared keys")
; Published library sequences are immutable; edits replace the sequence and changed item.
shared := shared.Clone(), shared[1] := shared[1].Clone(), shared[1].Text := "replacement"
modelKeys["shared1"] := "^!F10"
Assert(ManagedCellText(model.Content,1,2)="shared" && ManagedCellText(model.Content,1,3)="Ctrl+Shift+F12","old management display survives committed replacement and key changes")
replacement := BuildManagementPresentation(modelProfiles,shared,"",modelKeys)
Assert(ManagedCellText(replacement.Content,1,2)="replacement" && ManagedCellText(replacement.Content,1,3)="Ctrl+Alt+F10","refresh captures new items and keys together")
profileModel := BuildManagementPresentation(modelProfiles,shared,"p",modelKeys)
Assert(ManagedCellText(profileModel.Content,1,3)="Ctrl+Shift+F11" && ManagedCellText(profileModel.Content,2,3)="","profile slots use profile keys and unassigned slots stay blank")
Assert(ManagedCellText(model.Content,0,1)="" && ManagedCellText(model.Content,2,1)="" && ManagedCellText(model.Content,1,5)="","management rejects invalid cell coordinates")
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
