# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$runtime=New-TestRuntime
New-Item -ItemType Directory -Path (Join-Path $runtime 'scripts') | Out-Null
$checker=Join-Path $runtime 'scripts\check-browser.ps1'
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'scripts\check-browser.ps1') -Destination $checker
# Invalid combinations must fail at binding, before observing a desktop or creating a report.
$checkerBytes=[IO.File]::ReadAllBytes($checker)
try {
    Edit-TestSource $runtime 'scripts/check-browser.ps1' "Add-Type -AssemblyName UIAutomationClient" "throw 'Unexpected browser inspection'"
    foreach ($arguments in @(@{List=$true;Exercise=$true},
        @{List=$true;WindowHandle=-1;OutputPath=(Join-Path $runtime 'invalid.json')},
        @{WindowHandle=-1;OutputPath=(Join-Path $runtime 'invalid.json');Exercize=$true})) {
        $rejected=$false
        try { & $checker @arguments | Out-Null }
        catch [Management.Automation.ParameterBindingException] { $rejected=$true }
        if (!$rejected -or (Test-Path -LiteralPath (Join-Path $runtime 'invalid.json'))) { throw 'Invalid browser check arguments were not rejected before execution' }
    }
} finally { [IO.File]::WriteAllBytes($checker,$checkerBytes) }
# Change PowerShell's location without changing the process working directory.
$entry=Join-Path $runtime 'probe.ps1'
[IO.File]::WriteAllText($entry,@'
param([string]$Checker,[string]$ReportPath,[string]$Location,[switch]$Exercise)
$ErrorActionPreference='Stop'
Set-Location -LiteralPath $Location
& $Checker -WindowHandle -1 -OutputPath $ReportPath -Exercise:$Exercise
exit $LASTEXITCODE
'@,[Text.UTF8Encoding]::new($true))
function Invoke-ReportProbe([string]$ReportPath, [switch]$Exercise) {
    $stdout=Join-Path $runtime 'stdout.txt'
    $stderr=Join-Path $runtime 'stderr.txt'
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$entry+'"'),'-Checker',('"'+$checker+'"'),'-ReportPath',('"'+$ReportPath+'"'),'-Location',('"'+$runtime+'"'))
    if ($Exercise) { $arguments += '-Exercise' }
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
function Test-BrowserForeground { return $true }
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
$pageFixture=@'
function Get-Process { return [pscustomobject]@{ProcessName='brave';MainModule=[pscustomobject]@{FileVersionInfo=[pscustomobject]@{FileVersion='test'}}} }
function Test-BrowserForeground { return $true }
function Read-BrowserVideoId { return 'abcdefghijk' }
$address=[pscustomobject]@{Pattern=[pscustomobject]@{Current=[pscustomobject]@{Value='https://www.youtube.com/__PAGE__?v=abcdefghijk'}}}
$address | Add-Member ScriptMethod GetCurrentPattern { param($kind) return $this.Pattern }
$script:AddressBarCache=@{}
$script:AddressBarCache[[long]-1]=$address
function Find-ChatInput { return @{State='ok';Element='test-chat'} }
function Find-ReactionLauncher { return 'test-launcher' }
'@
foreach ($page in @('Watch','Popout')) {
    $urlPath=if ($page -eq 'Watch') { 'watch' } else { 'live_chat' }
    [IO.File]::WriteAllText((Join-Path $runtime 'src\browser\browser_worker.ps1'),$pageFixture.Replace('__PAGE__',$urlPath),[Text.UTF8Encoding]::new($true))
    $path=Join-Path $runtime ("page-$page.json")
    if ((Invoke-ReportProbe $path) -ne 0) { throw "Cached address could not identify page kind: $page" }
    $json=[IO.File]::ReadAllText($path)
    $report=$json | ConvertFrom-Json
    if ($report.Error -or !$report.AddressDetected -or !$report.VideoDetected -or $report.PageKind -ne $page -or
        $report.Focus -ne 'not-run' -or $report.Hover -ne 'not-run' -or $json -match 'abcdefghijk|youtube\.com') {
        throw "Cached address inspection changed privacy or read-only reporting: $page"
    }
}
# A shared report identifies the failed stage without exposing exception contents.
foreach ($fault in @('chat','focus','hover')) {
    $faultFixture=$pageFixture.Replace('__PAGE__','watch')
    if ($fault -eq 'chat') {
        $faultFixture=$faultFixture.Replace("return @{State='ok';Element='test-chat'}", "throw 'fixture-private chat text and URL'")
    }
    $actions=@'
function Invoke-PageAction($Request) {
    if ($Request.Mode -eq '__MODE__') { throw 'fixture-private window title and path' }
    return @{State='focused'}
}
'@
    $mode=if ($fault -eq 'focus') { 'chat_focus' } else { 'reactions_show' }
    $faultFixture+="`r`n"+$actions.Replace('__MODE__',$mode)
    [IO.File]::WriteAllText((Join-Path $runtime 'src\browser\browser_worker.ps1'),$faultFixture,[Text.UTF8Encoding]::new($true))
    $path=Join-Path $runtime ("failure-$fault.json")
    if ((Invoke-ReportProbe $path -Exercise:($fault -ne 'chat')) -ne 1) { throw "$fault exception must fail inspection" }
    $json=[IO.File]::ReadAllText($path)
    $report=$json | ConvertFrom-Json
    if ($report.Error -notlike "Inspection failed at ${fault}.*") { throw "Missing failure stage ${fault}: $($report.Error)" }
    $expectedFocus=if ($fault -eq 'hover') { 'focused' } elseif ($fault -eq 'focus') { 'unknown' } else { 'not-run' }
    $expectedHover=if ($fault -eq 'hover') { 'unknown' } else { 'not-run' }
    if ($report.Focus -ne $expectedFocus -or $report.Hover -ne $expectedHover -or !$report.VideoDetected -or
        $report.Display -ne 'not-verified' -or $json -match 'fixture-private|abcdefghijk|youtube\.com') {
        throw "$fault inspection lost partial results or included private data"
    }
}
Write-Output 'PASS: argument rejection, report paths, overwrite protection, chat outcomes, cached page kinds and private failure-stage reporting'
