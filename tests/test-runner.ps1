# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$runtime=New-TestRuntime
$fixture=Join-Path $runtime 'tests'
New-Item -ItemType Directory -Path $fixture | Out-Null
$runner=Join-Path $fixture 'run.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run.ps1') -Destination $runner
$headless=Join-Path $fixture 'test-alpha.ps1'
$desktop=Join-Path $fixture 'test-beta.ps1'
[IO.File]::WriteAllText($headless,"# Test-Session: Headless`r`nWrite-Output 'fixture-alpha'`r`n",[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText($desktop,"# Test-Session: Desktop`r`nWrite-Output 'fixture-beta'`r`n",[Text.UTF8Encoding]::new($true))
$base=Join-Path $fixture '.tmp'
$oldRoot=$env:HELPER_TEST_ROOT
$oldAhk=$env:AHK_EXE
$listed=@(& $runner -Name 'test-alpha.ps1' -List)
if ($listed.Count -ne 1 -or $listed[0] -ne 'test-alpha.ps1' -or (Test-Path -LiteralPath $base)) { throw 'Named listing did not select exactly one test without preparing a runtime' }
foreach ($arguments in @(@{Name='missing.ps1'},@{Name='test-beta.ps1';Group='Headless'},@{Name=''},@{Nmae='test-alpha.ps1'})) {
    $rejected=$false
    try { & $runner @arguments | Out-Null } catch { $rejected=$true }
    if (!$rejected -or (Test-Path -LiteralPath $base)) { throw 'Invalid selection started a test or created a runtime' }
}
$output=@(& $runner -Name 'test-alpha.ps1')
if ($output -notcontains 'fixture-alpha' -or $output -contains 'fixture-beta' -or ($output -join "`n") -notmatch 'PASS: test-alpha\.ps1 / 1 test groups') { throw 'Named run did not execute exactly the selected test' }
if (@(Get-ChildItem -LiteralPath $base -Directory).Count -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk) { throw 'Successful named run did not clean up or restore its environment' }
$output=@(& $runner -Group Desktop)
if ($output -notcontains 'fixture-beta' -or $output -contains 'fixture-alpha' -or ($output -join "`n") -notmatch 'PASS: Desktop / 1 test groups') { throw 'Group selection changed' }
$output=@(& $runner)
if ($output -notcontains 'fixture-alpha' -or $output -notcontains 'fixture-beta' -or ($output -join "`n") -notmatch 'PASS: All / 2 test groups') { throw 'Default run did not execute every test' }
[IO.File]::WriteAllText($headless,"# Test-Session: Headless`r`nthrow 'fixture failure'`r`n",[Text.UTF8Encoding]::new($true))
$failed=$false
try { & $runner -Name 'test-alpha.ps1' -AutoHotkeyPath 'fixture-runtime.exe' -WarningAction SilentlyContinue | Out-Null } catch { $failed=$true }
$retained=@(Get-ChildItem -LiteralPath $base -Directory)
if (!$failed -or $retained.Count -ne 1 -or $env:HELPER_TEST_ROOT -cne $oldRoot -or $env:AHK_EXE -cne $oldAhk) { throw 'Failed named run did not retain evidence or restore its environment' }
$stderr=Join-Path $retained[0].FullName 'test-alpha.ps1.stderr.txt'
if (!(Test-Path -LiteralPath $stderr) -or [IO.File]::ReadAllText($stderr) -notmatch 'fixture failure') { throw 'Failed test stderr was not retained' }
Write-Output 'PASS: exact-name and group selection, side-effect-free listing, cleanup, failure evidence and environment restoration'
