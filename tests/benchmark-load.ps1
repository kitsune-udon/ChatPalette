[CmdletBinding()]
param([ValidateRange(1,9)][int]$Repeats=3, [ValidateNotNullOrEmpty()][int[]]$Counts=@(1000,10000), [string]$SourceRoot)
. (Join-Path $PSScriptRoot 'support.ps1')
if (@($Counts | Where-Object { $_ -lt 1 -or $_ -gt 100000 }).Count) { throw 'Counts must be between 1 and 100000' }
if ($SourceRoot) { $ProjectRoot = (Resolve-Path -LiteralPath $SourceRoot).Path }
$runtime=New-TestRuntime
$source="#Requires AutoHotkey v2.0`r`n#Include %A_ScriptDir%\src\app\app_modules.ahk`r`n"
$source += 'Counts := [' + ($Counts -join ',') + "]`r`nRepeats := $Repeats`r`n"
$source += @'
global SettingsDatabasePath := A_ScriptDir "\settings.db"
global ApplicationShortcutsInstalled := false, ShortcutKeys := DefaultShortcutKeys(), LibraryHistory := []
OnExit(CloseSettingsStore)
DllCall("QueryPerformanceFrequency","Int64*",&frequency := 0)
FileAppend("items,operation,median_ms,max_ms`n","*")
for count in Counts {
    draft := CreateDefaultSettings(), draft.AutoMode := 0
    Loop count
        draft.SharedDanmakuItems.Push({Id:"bench-" A_Index,Name:"item " A_Index,Text:"synthetic body " A_Index,Slot:0})
    OpenSettingsRepository(SettingsDatabasePath).SaveAll(draft)
    samples := ""
    Loop Repeats+1 {
        DllCall("QueryPerformanceCounter","Int64*",&started := 0)
        ReloadAppSettings()
        DllCall("QueryPerformanceCounter","Int64*",&finished := 0)
        ; Check the published state after every read, outside the measured interval.
        measured := CreatePreferences(), measured.Profiles := Profiles, measured.SharedDanmakuItems := SharedDanmakuItems
        VerifySettingsRoundTrip(draft,measured)
        measured := 0
        if A_Index>1
            samples .= (finished-started)*1000/frequency "`n"
    }
    sorted := StrSplit(RTrim(Sort(samples,"N"),"`n"),"`n")
    median := (sorted[(Repeats+1)//2]+sorted[(Repeats+2)//2])/2
    FileAppend(count ",load," Round(median,3) "," Round(sorted[-1],3) "`n","*")
}
ExitApp()
'@
Invoke-AhkTest -Runtime $runtime -Source $source -TimeoutMs 180000
# The completed child has closed its isolated database; preserve failed runs for diagnosis.
$resolved = (Resolve-Path -LiteralPath $runtime).Path
$base = if ($env:HELPER_TEST_ROOT) { $env:HELPER_TEST_ROOT } else { Join-Path $PSScriptRoot '.tmp' }
if ((Split-Path $resolved -Parent) -ne (Resolve-Path -LiteralPath $base).Path) { throw 'Unexpected cleanup path' }
Remove-Item -LiteralPath $resolved -Recurse -Force
