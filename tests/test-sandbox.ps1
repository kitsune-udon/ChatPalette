# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $ProjectRoot 'scripts\release-files.ps1')
$runtime = New-TestRuntime
Copy-ReleaseFiles -Project $ProjectRoot -Destination $runtime
# Host packaging must exclude user data and previous test evidence.
New-Item -ItemType Directory -Path (Join-Path $runtime 'data'),(Join-Path $runtime 'dist') | Out-Null
Set-Content -LiteralPath (Join-Path $runtime 'data\private.txt') -Value 'private'
Set-Content -LiteralPath (Join-Path $runtime 'dist\private.txt') -Value 'private'
$runner = Join-Path $runtime 'tests\run.ps1'
$listed = @(& $runner -Sandbox -List -Name test-input.ps1)
Assert ($listed.Count -eq 1 -and $listed[0] -eq 'test-input.ps1') 'Sandbox listing does not require virtualization'
Assert (!(Test-Path -LiteralPath (Join-Path $runtime 'tests\.tmp'))) 'Listing created no package'
$invalid = $false
try { & $runner -PrepareOnly -Name test-input.ps1 | Out-Null } catch { $invalid = $true }
Assert $invalid 'PrepareOnly without Sandbox cannot accidentally execute on the host'
$invalid = $false
try { & $runner -Sandbox -PrepareOnly -Name 'missing.ps1' | Out-Null } catch { $invalid = $true }
Assert $invalid 'Invalid Sandbox selection rejected before packaging'
Assert (!(Test-Path -LiteralPath (Join-Path $runtime 'tests\.tmp'))) 'Invalid selection created no package'
$output = @(& $runner -Sandbox -PrepareOnly -Name test-page-actions.ps1,test-input.ps1,test-input.ps1)
$runs = @(Get-ChildItem -LiteralPath (Join-Path $runtime 'tests\.tmp') -Directory)
Assert ($runs.Count -eq 1) 'Prepared one Sandbox without launching it'
$package = $runs[0].FullName
$config = [xml](Get-Content -LiteralPath (Join-Path $package 'tests.wsb') -Raw)
$maps = @($config.Configuration.MappedFolders.MappedFolder)
Assert ($maps.Count -eq 2 -and $maps[0].ReadOnly -eq 'true' -and $maps[1].ReadOnly -eq 'false') 'Only inputs and results are mapped, with separate access'
Assert ($maps[0].HostFolder -eq (Join-Path $package 'input') -and $maps[1].HostFolder -eq (Join-Path $package 'results')) 'Only this run is exposed to the guest'
Assert ($config.Configuration.Networking -eq 'Disable' -and $config.Configuration.ClipboardRedirection -eq 'Disable') 'Network and host clipboard are not shared'
$selection = Get-Content -LiteralPath (Join-Path $package 'input\selection.json') -Raw | ConvertFrom-Json
Assert (($selection.Name -join ',') -eq 'test-input.ps1,test-page-actions.ps1') 'Existing selection order and deduplication are retained'
$snapshot = Join-Path $package 'input\project'
foreach ($excluded in @('data','dist','.git','tests\.tmp')) {
    Assert (!(Test-Path -LiteralPath (Join-Path $snapshot $excluded))) "Snapshot excludes $excluded"
}
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $snapshot 'tests\run.ps1'))) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($runner))) 'Snapshot contains the current runner'
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $package 'input\AutoHotkey.exe'))) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-AutoHotkeyPath)))) 'Snapshot contains the selected AutoHotkey'
# Exercise the guest's real process/log/result handoff with a headless fake runner.
# This does not claim to test virtualization, desktop activation or input delivery.
$inputRoot = Join-Path $runtime 'guest-input'
Copy-ReleaseFiles -Project $ProjectRoot -Destination (Join-Path $inputRoot 'project')
Copy-Item -LiteralPath (Get-AutoHotkeyPath) -Destination (Join-Path $inputRoot 'AutoHotkey.exe')
@{ Name = @('first name.ps1',"quote' name.ps1") } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $inputRoot 'selection.json') -Encoding UTF8
$probe = @'
param([string[]]$Name, [string]$AutoHotkeyPath)
if (($Name -join ',') -ne "first name.ps1,quote' name.ps1") { throw 'Selection was changed' }
if (!(Test-Path -LiteralPath $AutoHotkeyPath)) { throw 'Runtime was not copied' }
New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot '.tmp\failed-case') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $PSScriptRoot '.tmp\failed-case\evidence.txt') -Value 'evidence'
Write-Output 'guest-output 日本語 🧪'
'@
foreach ($scenario in @('success','failure','exit-code','source-edit','source-add','source-remove')) {
    $body = $probe
    if ($scenario -eq 'failure') { $body += "`r`nthrow 'guest-failure 日本語 🧪'" }
    if ($scenario -eq 'exit-code') { $body += "`r`nexit 7" }
    if ($scenario -eq 'source-edit') { $body += "`r`nAdd-Content -LiteralPath (Join-Path `$PSScriptRoot '..\README.md') -Value 'changed'" }
    if ($scenario -eq 'source-add') { $body += "`r`nSet-Content -LiteralPath (Join-Path `$PSScriptRoot 'new-check.ps1') -Value '# added'" }
    if ($scenario -eq 'source-remove') { $body += "`r`nRemove-Item -LiteralPath (Join-Path `$PSScriptRoot 'test-input.ps1')" }
    [IO.File]::WriteAllText((Join-Path $inputRoot 'project\tests\run.ps1'),$body,[Text.UTF8Encoding]::new($true))
    $outputRoot = Join-Path $runtime ($scenario + '-results')
    New-Item -ItemType Directory -Path $outputRoot | Out-Null
    & (Join-Path $PSScriptRoot 'sandbox-guest.ps1') -InputRoot $inputRoot -OutputRoot $outputRoot -WorkRoot (Join-Path $runtime ($scenario + '-work'))
    $result = Get-Content -LiteralPath (Join-Path $outputRoot 'result.json') -Raw | ConvertFrom-Json
    Assert (($result.ExitCode -eq 0) -eq ($scenario -eq 'success')) "$scenario reports the actual outcome"
    Assert ((Get-Content -LiteralPath (Join-Path $outputRoot 'stdout.txt') -Raw -Encoding UTF8) -match 'guest-output 日本語 🧪') "$scenario preserves stdout"
    Assert ((Get-Content -LiteralPath (Join-Path $outputRoot 'artifacts\failed-case\evidence.txt') -Raw).Trim() -eq 'evidence') "$scenario collects evidence before completion"
    Assert (!(Test-Path -LiteralPath (Join-Path $outputRoot 'result.pending.json'))) "$scenario publishes completion atomically"
    if ($scenario -eq 'failure') {
        Assert ((Get-Content -LiteralPath (Join-Path $outputRoot 'stderr.txt') -Raw -Encoding UTF8) -match 'guest-failure 日本語 🧪') 'Failure preserves stderr'
    }
    if ($scenario -like 'source-*') {
        Assert ($result.Error -eq 'Validated source changed during Sandbox tests') "$scenario rejects success after mutation of the tested source"
    }
}
Write-Output "PASS: $script:checks Sandbox packaging and guest handoff checks (no VM launched)"
