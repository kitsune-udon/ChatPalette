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
$source=[IO.File]::ReadAllText($checker)
$anchor='# Never include titles, URLs, field values or exception text in a shareable report.'
if (!$source.Contains($anchor)) { throw 'Report publication injection point missing' }
$injection="[IO.File]::WriteAllText(`$OutputPath,'concurrent report')`r`n"
[IO.File]::WriteAllText($checker,$source.Replace($anchor,$injection+$anchor),[Text.UTF8Encoding]::new($true))
$concurrent=Join-Path $runtime 'concurrent.json'
if ((Invoke-ReportProbe $concurrent) -eq 0 -or [IO.File]::ReadAllText($concurrent) -cne 'concurrent report') { throw 'Concurrent report was overwritten' }
Write-Output 'PASS: report directory creation, PowerShell-relative paths, failed inspection record and overwrite protection'
