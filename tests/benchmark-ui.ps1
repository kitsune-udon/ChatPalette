param([ValidateRange(1,9)][int]$Repeats=3, [int[]]$Counts=@(1000,10000))
. (Join-Path $PSScriptRoot 'support.ps1')
if (@($Counts | Where-Object { $_ -lt 1 -or $_ -gt 100000 }).Count) { throw 'Counts must be between 1 and 100000' }
$runtime=New-TestRuntime
$source="#Requires AutoHotkey v2.0`r`n#Include %A_ScriptDir%\src\app\app_modules.ahk`r`n"
$source += 'Counts := [' + ($Counts -join ',') + "]`r`nRepeats := $Repeats`r`n"
$source += @'
try {
    DllCall("QueryPerformanceFrequency","Int64*",&frequency := 0)
    started := Tick()
    InitializeApplication()
    initializedMs := Round(Tick()-started,3)
    FileAppend("items,operation,median_ms,max_ms`n0,cold_initialize," initializedMs "," initializedMs "`n","*")
    AutoMode := false
    PaletteViewport.Show()
    for count in Counts {
        draft := CreateSettingsSnapshot(), draft.SharedDanmakuItems := [], draft.Profiles := [], draft.InputProfileId := ""
        Loop count
            draft.SharedDanmakuItems.Push({Id:"bench-" A_Index,Name:"item " A_Index,Text:"synthetic body " A_Index,Slot:0})
        SaveSettings(draft,SettingsDatabasePath)
        ReloadAppSettings()
        for operation in ["load","list","search"] {
            samples := ""
            Loop Repeats+1 {
                PaletteSearch.Value := operation="search" ? "body 9" : ""
                started := Tick()
                if operation="load"
                    ReloadAppSettings()
                else
                    RefreshPaletteItems()
                elapsed := Tick()-started
                if A_Index>1
                    samples .= elapsed "`n"
            }
            sorted := StrSplit(RTrim(Sort(samples,"N"),"`n"),"`n")
            FileAppend(count "," operation "," Round(sorted[Ceil(Repeats/2)],3) "," Round(sorted[-1],3) "`n","*")
        }
    }
    ExitApp()
} catch as failure {
    FileAppend(failure.Message " at " failure.Line "`n","**")
    ExitApp(1)
}
Tick() {
    DllCall("QueryPerformanceCounter","Int64*",&now := 0)
    return now*1000/frequency
}
'@
Invoke-AhkTest -Runtime $runtime -Source $source -TimeoutMs 180000
