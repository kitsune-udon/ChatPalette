param([string]$SourceRoot, [int]$Repeats = 7)
. (Join-Path $PSScriptRoot 'support.ps1')
if ($SourceRoot) { $ProjectRoot = (Resolve-Path -LiteralPath $SourceRoot).Path }
$runtime = New-TestRuntime
$modules = @('app/record_identity','settings/settings_schema','shortcuts/shortcut_policy','settings/settings_validation','library/danmaku_library','settings/library_storage_plan')
$source = "#Requires AutoHotkey v2.0`r`n#Warn All, StdOut`r`nglobal SharedDanmakuItems := []`r`n"
foreach ($module in $modules) { $source += "#Include %A_ScriptDir%\src\$module.ahk`r`n" }
if (Test-Path (Join-Path $runtime 'src/settings/library_storage_delta.ahk')) {
    $source += "#Include %A_ScriptDir%\src\settings\library_storage_delta.ahk`r`n"
}
$source += "Repeats := $Repeats`r`n"
$source += @'
try {
    DllCall("QueryPerformanceFrequency","Int64*",&frequency := 0)
    FileAppend("items,operation,median_ms,max_ms`n","*")
    for count in [1000,10000,100000] {
        items := []
        Loop count
            items.Push({Id:"item-" A_Index,Name:"name" A_Index,Text:"synthetic text " A_Index,Slot:0})
        state := {Profiles:[],SharedDanmakuItems:items}
        base := BuildLibraryStoragePlan(state,Map())
        for operation in ["edit","swap","undo"] {
            changed := items.Clone(), middle := count//2
            if operation = "edit" {
                changed[middle] := items[middle].Clone()
                changed[middle].Text := "edited"
            } else {
                changed[middle] := items[middle+1], changed[middle+1] := items[middle]
            }
            draft := {Profiles:[],SharedDanmakuItems:changed}, benchmarkPrevious := base.Scopes
            if operation = "undo" {
                benchmarkPrevious := BuildLibraryStoragePlan(draft,benchmarkPrevious).Scopes
                draft := state
            }
            samples := ""
            Loop Repeats+1 {
                DllCall("QueryPerformanceCounter","Int64*",&started := 0)
                plan := BuildLibraryStoragePlan(draft,benchmarkPrevious)
                DllCall("QueryPerformanceCounter","Int64*",&finished := 0)
                if A_Index > 1
                    samples .= (finished-started)*1000/frequency "`n"
            }
            benchmarkSorted := StrSplit(RTrim(Sort(samples,"N"),"`n"),"`n")
            FileAppend(count "," operation "," Round(benchmarkSorted[(Repeats+1)//2],3) "," Round(benchmarkSorted[-1],3) "`n","*")
        }
    }
    ExitApp()
} catch as failure {
    FileAppend(failure.Message " at " failure.File ":" failure.Line "`n","**")
    ExitApp(1)
}
'@
Invoke-AhkTest -Runtime $runtime -Source $source -TimeoutMs 120000
