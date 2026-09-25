[CmdletBinding()]
param([string]$AutoHotkeyPath, [ValidateSet("All","Headless","Desktop")][string]$Group="All",
    [ValidateNotNullOrEmpty()][string]$Name, [switch]$List)
$ErrorActionPreference = 'Stop'
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test-*.ps1' -File | Sort-Object Name)
$tests = @($tests | Where-Object {
    $header = Get-Content -LiteralPath $_.FullName -TotalCount 1
    if ($header -notmatch '^# Test-Session: (Headless|Desktop)$') { throw "Missing test session classification: $($_.Name)" }
    ($Group -eq 'All' -or $Matches[1] -eq $Group) -and (!$Name -or $_.Name -eq $Name)
})
if (!$tests.Count) { throw 'No matching test scripts found. Use -List to inspect available names.' }
if ($List) { $tests.Name; return }
. (Join-Path $PSScriptRoot 'support.ps1')
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
        $testName = $test.Name
        Write-Output "RUN: $testName"
        $out = Join-Path $runRoot ($testName + '.stdout.txt')
        $err = Join-Path $runRoot ($testName + '.stderr.txt')
        $process = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $PSScriptRoot $testName) + '"') -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
        $exitCode = Wait-TestProcess -Process $process -TimeoutMs 120000
        Get-Content -LiteralPath $out,$err
        if ($exitCode -ne 0) { throw "Failed: $testName" }
    }
    $completed = $true
    $selection = if ($Name) { $Name } else { $Group }
    Write-Output "PASS: $selection / $($tests.Count) test groups; no real messages or reactions sent."
} finally {
    $env:HELPER_TEST_ROOT = $oldRoot
    $env:AHK_EXE = $oldAhk
    $resolved = (Resolve-Path -LiteralPath $runRoot).Path
    if ((Split-Path $resolved -Parent) -ne (Resolve-Path -LiteralPath $base).Path) { throw 'Unexpected cleanup path' }
    if ($completed) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    else { Write-Warning "Failed test artifacts retained: $resolved" }
}
