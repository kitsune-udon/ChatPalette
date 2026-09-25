# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$runtime=New-TestRuntime
New-Item -ItemType Directory -Path (Join-Path $runtime 'scripts') | Out-Null
$checker=Join-Path $runtime 'scripts\check-browser.ps1'
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'scripts\check-browser.ps1') -Destination $checker
# Change PowerShell's location without changing the process working directory.
$entry=Join-Path $runtime 'probe.ps1'
[IO.File]::WriteAllText($entry,@'
param([string]$Checker,[string]$ReportPath,[string]$Location)
$ErrorActionPreference='Stop'
Set-Location -LiteralPath $Location
& $Checker -WindowHandle -1 -OutputPath $ReportPath
exit $LASTEXITCODE
'@,[Text.UTF8Encoding]::new($true))
function Invoke-ReportProbe([string]$ReportPath) {
    $stdout=Join-Path $runtime 'stdout.txt'
    $stderr=Join-Path $runtime 'stderr.txt'
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$entry+'"'),'-Checker',('"'+$checker+'"'),'-ReportPath',('"'+$ReportPath+'"'),'-Location',('"'+$runtime+'"'))
    $process=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $arguments -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    return Wait-TestProcess -Process $process -TimeoutMs 15000
}
# An invalid handle records a failed inspection without accessing a browser.
$relative='reports [new]\report.json'
$reportPath=Join-Path $runtime $relative
if ((Invoke-ReportProbe $relative) -ne 1 -or !(Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw "Missing output directory or PowerShell-relative path was not handled; artifacts: $runtime" }
$report=[IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
if ($report.AddressDetected -isnot [bool] -or $report.AddressDetected -or !$report.Error -or $report.VideoDetected -or $report.ChatDetected -or $report.Focus -ne 'not-run' -or $report.Hover -ne 'not-run') { throw 'Failed inspection was not recorded accurately' }
[IO.File]::WriteAllText($reportPath,'existing report')
if ((Invoke-ReportProbe $relative) -eq 0 -or [IO.File]::ReadAllText($reportPath) -cne 'existing report') { throw 'Existing report was overwritten' }
# Simulate another writer publishing after the initial existence check.
$anchor='# Never include titles, URLs, field values or exception text in a shareable report.'
$injection="[IO.File]::WriteAllText(`$OutputPath,'concurrent report')`r`n"
Edit-TestSource $runtime 'scripts/check-browser.ps1' $anchor ($injection+$anchor)
$concurrent=Join-Path $runtime 'concurrent.json'
if ((Invoke-ReportProbe $concurrent) -eq 0 -or [IO.File]::ReadAllText($concurrent) -cne 'concurrent report') { throw 'Concurrent report was overwritten' }
# Keep the real report path and JSON serialization; replace browser observations.
Edit-TestSource $runtime 'scripts/check-browser.ps1' ($injection+$anchor) $anchor
$rootRead='[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)'
Edit-TestSource $runtime 'scripts/check-browser.ps1' $rootRead '([pscustomobject]@{Current=[pscustomobject]@{ProcessId=1}})'
foreach ($state in @('ok','chat_missing','chat_ambiguous')) {
    $fixture=@'
function Get-Process { return [pscustomobject]@{ProcessName='brave';MainModule=[pscustomobject]@{FileVersionInfo=[pscustomobject]@{FileVersion='test'}}} }
function Test-ReactionForeground { return $true }
function Read-BrowserVideoId { return '' }
$script:AddressBarCache=@{}
function Find-ChatInput { return @{State='__STATE__';Element=__ELEMENT__} }
function Find-ReactionLauncher { return $null }
'@
    $element=if ($state -eq 'ok') { "'test-chat'" } else { '$null' }
    [IO.File]::WriteAllText((Join-Path $runtime 'src\browser\browser_worker.ps1'),$fixture.Replace('__STATE__',$state).Replace('__ELEMENT__',$element),[Text.UTF8Encoding]::new($true))
    $path=Join-Path $runtime ("chat-$state.json")
    if ((Invoke-ReportProbe $path) -ne 1) { throw "Other missing detections must still fail the $state report" }
    $report=[IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($report.Error -or $report.ChatDetected -isnot [bool] -or $report.ChatDetected -ne ($state -eq 'ok')) { throw "Chat detection state $state was misreported" }
}
Write-Output 'PASS: report paths, overwrite protection and chat discovery outcomes'
