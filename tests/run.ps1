param([string]$AutoHotkeyPath, [ValidateSet("All","Headless","Desktop")][string]$Group="All", [switch]$List)
$ErrorActionPreference = 'Stop'
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test-*.ps1' -File | Sort-Object Name)
$tests = @($tests | Where-Object {
    $header = Get-Content -LiteralPath $_.FullName -TotalCount 1
    if ($header -notmatch '^# Test-Session: (Headless|Desktop)$') { throw "Missing test session classification: $($_.Name)" }
    $Group -eq 'All' -or $Matches[1] -eq $Group
})
if (!$tests.Count) { throw 'No test scripts found' }
if ($List) { $tests.Name; return }
$base = Join-Path $PSScriptRoot '.tmp'
$runRoot = Join-Path $base ('run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$completed = $false
$oldRoot = $env:HELPER_TEST_ROOT
$oldAhk = $env:AHK_EXE
try {
    $env:HELPER_TEST_ROOT = $runRoot
    if ($AutoHotkeyPath) { $env:AHK_EXE = $AutoHotkeyPath }
    foreach ($test in $tests) {
        $name = $test.Name
        Write-Output "RUN: $name"
        $out = Join-Path $runRoot ($name + '.stdout.txt')
        $err = Join-Path $runRoot ($name + '.stderr.txt')
        $process = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $PSScriptRoot $name) + '"') -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $process.Handle
        if (!$process.WaitForExit(120000)) { $process.Kill(); throw "Timed out: $name" }
        Get-Content -LiteralPath $out,$err
        if ($process.ExitCode -ne 0) { throw "Failed: $name" }
    }
    $completed = $true
    Write-Output "PASS: $Group / $($tests.Count) test groups; no real messages or reactions sent."
} finally {
    $env:HELPER_TEST_ROOT = $oldRoot
    $env:AHK_EXE = $oldAhk
    $resolved = (Resolve-Path -LiteralPath $runRoot).Path
    if ((Split-Path $resolved -Parent) -ne (Resolve-Path -LiteralPath $base).Path) { throw 'Unexpected cleanup path' }
    if ($completed) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    else { Write-Warning "Failed test artifacts retained: $resolved" }
}
