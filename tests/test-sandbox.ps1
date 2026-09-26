# Test-Session: Headless
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $ProjectRoot 'scripts\release-files.ps1')
$runtime = New-TestRuntime
Copy-ReleaseFiles -Project $ProjectRoot -Destination $runtime
# Poll a log while the writer holds it open, including a split UTF-8 character.
$log=[pscustomobject]@{Path=(Join-Path $runtime 'progress.txt'); Position=0}
Assert (@(Write-TestLogUpdate $log).Count -eq 0) 'Absent progress log does not block Sandbox startup'
$writer=[IO.File]::Open($log.Path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try {
    Assert (@(Write-TestLogUpdate $log).Count -eq 0) 'Empty progress log is not published'
    $bytes=[Text.Encoding]::UTF8.GetBytes("first 日本語 🧪`r`n")
    $writer.Write($bytes,0,$bytes.Length-4); $writer.Flush()
    Assert (@(Write-TestLogUpdate $log).Count -eq 0 -and $log.Position -eq 0) 'Partial UTF-8 line is not consumed'
    $writer.Write($bytes,$bytes.Length-4,4); $writer.Flush()
    $lines=@(Write-TestLogUpdate $log)
    Assert ($lines.Count -eq 1 -and $lines[0] -ceq 'first 日本語 🧪') 'Completed Unicode line is preserved'
    Assert (@(Write-TestLogUpdate $log).Count -eq 0) 'Unchanged log is not printed twice'
    $bytes=[Text.Encoding]::UTF8.GetBytes("`r`nsecond`ntail 日本語 🧪")
    $writer.Write($bytes,0,$bytes.Length); $writer.Flush()
    $lines=@(Write-TestLogUpdate $log)
    Assert ($lines.Count -eq 2 -and $lines[0] -ceq '' -and $lines[1] -ceq 'second') 'Empty lines and mixed line endings are preserved'
} finally { $writer.Dispose() }
$lines=@(Write-TestLogUpdate $log -Complete)
Assert ($lines.Count -eq 1 -and $lines[0] -ceq 'tail 日本語 🧪') 'Closed log publishes its final line without a newline'
Assert (@(Write-TestLogUpdate $log -Complete).Count -eq 0) 'Final drain does not repeat output'
[IO.File]::WriteAllText($log.Path,'')
$rejected=$false
try { Write-TestLogUpdate $log | Out-Null } catch { $rejected=$_.Exception.Message -like 'Test log was truncated:*' }
Assert $rejected 'Unexpected log replacement is reported instead of silently losing progress'
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
# The host must forward output before completion, then drain failure logs only once.
$producer=@'
param([string]$OutputRoot)
$utf8=[Text.UTF8Encoding]::new($false)
$stdout=Join-Path $OutputRoot 'stdout.txt'
[IO.File]::WriteAllText($stdout,"live 日本語 🧪`r`n",$utf8)
$ack=Join-Path $OutputRoot 'observed.txt'
$deadline=[DateTime]::UtcNow.AddSeconds(10)
while (!(Test-Path -LiteralPath $ack) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
[IO.File]::AppendAllText($stdout,'final line without newline',$utf8)
[IO.File]::WriteAllText((Join-Path $OutputRoot 'stderr.txt'),'failure 日本語 🧪',$utf8)
[IO.File]::WriteAllText((Join-Path $OutputRoot 'result.pending.json'),'{"ExitCode":1,"Error":"fixture progress failure"}',$utf8)
Move-Item -LiteralPath (Join-Path $OutputRoot 'result.pending.json') -Destination (Join-Path $OutputRoot 'result.json')
'@
[IO.File]::WriteAllText((Join-Path $runtime 'progress-writer.ps1'),$producer,[Text.UTF8Encoding]::new($true))
Edit-TestSource $runtime 'tests/sandbox.ps1' '$sandboxExe = Join-Path $env:SystemRoot ''System32\WindowsSandbox.exe''' '$sandboxExe = Join-Path $env:SystemRoot ''System32\WindowsPowerShell\v1.0\powershell.exe'''
Edit-TestSource $runtime 'tests/sandbox.ps1' '-ArgumentList (''"'' + $config + ''"'') -WindowStyle Normal' '-ArgumentList ''-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',(''"'' + (Join-Path $ProjectRoot ''progress-writer.ps1'') + ''"''),''-OutputRoot'',(''"'' + $outputRoot + ''"'') -WindowStyle Hidden'
$before=@(Get-ChildItem -LiteralPath (Join-Path $runtime 'tests\.tmp') -Directory | Select-Object -ExpandProperty FullName)
$observed=[Collections.Generic.List[string]]::new()
$liveBeforeCompletion=$false
$failure=''
try {
    & (Join-Path $runtime 'tests\sandbox.ps1') -Name test-input.ps1 | ForEach-Object {
        $observed.Add([string]$_)
        if ($_ -ceq 'live 日本語 🧪') {
            $active=@(Get-ChildItem -LiteralPath (Join-Path $runtime 'tests\.tmp') -Directory | Where-Object FullName -NotIn $before)
            Assert ($active.Count -eq 1) 'Progress belongs to this host invocation'
            $results=Join-Path $active[0].FullName 'results'
            $liveBeforeCompletion=!(Test-Path -LiteralPath (Join-Path $results 'result.json'))
            [IO.File]::WriteAllText((Join-Path $results 'observed.txt'),'observed')
        }
    }
} catch { $failure=$_.Exception.Message }
Assert $liveBeforeCompletion 'Host publishes progress before the result exists'
foreach ($line in @('live 日本語 🧪','final line without newline','failure 日本語 🧪')) {
    Assert (@($observed | Where-Object { $_ -ceq $line }).Count -eq 1) "Host publishes each line once: $line"
}
Assert ($failure -like 'Sandbox tests failed: fixture progress failure*') 'Live progress does not turn a failing run into success'
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
