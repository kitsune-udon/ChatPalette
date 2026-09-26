[CmdletBinding()]
param([string]$AutoHotkeyPath, [ValidateSet("All","Headless","Desktop")][string]$Group="All",
    [ValidateNotNullOrEmpty()][string[]]$Name, [switch]$List, [switch]$Sandbox, [switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
if ($PrepareOnly -and !$Sandbox) { throw '-PrepareOnly requires -Sandbox.' }
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test-*.ps1' -File | Sort-Object Name)
$tests = @($tests | Where-Object {
    $header = Get-Content -LiteralPath $_.FullName -TotalCount 1
    if ($header -notmatch '^# Test-Session: (Headless|Desktop)$') { throw "Missing test session classification: $($_.Name)" }
    ($Group -eq 'All' -or $Matches[1] -eq $Group) -and (!$Name -or $_.Name -in $Name)
})
if (!$tests.Count) { throw 'No matching test scripts found. Use -List to inspect available names.' }
foreach ($requested in $Name) {
    if ($requested -notin $tests.Name) { throw "No matching test script in ${Group}: $requested. Use -List to inspect available names." }
}
if ($List) { $tests.Name; return }
if ($Sandbox) {
    & (Join-Path $PSScriptRoot 'sandbox.ps1') -Name $tests.Name -AutoHotkeyPath $AutoHotkeyPath -PrepareOnly:$PrepareOnly
    return
}
. (Join-Path $PSScriptRoot 'support.ps1')
$checks = @((Get-Item -LiteralPath (Join-Path $ProjectRoot 'scripts\check-source.ps1'))) + $tests
$base = Join-Path $PSScriptRoot '.tmp'
$oldRoot = $env:HELPER_TEST_ROOT
$oldAhk = $env:AHK_EXE
try {
    if ($AutoHotkeyPath) { $env:AHK_EXE = $AutoHotkeyPath }
    foreach ($test in $checks) {
        $testName = $test.Name
        Write-Output "RUN: $testName"
        # Each check owns its artifacts; keep paths short for nested release checks.
        $runRoot = Join-Path $base ('run-' + [guid]::NewGuid().ToString('N').Substring(0,16))
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $completed = $false
        try {
            $env:HELPER_TEST_ROOT = $runRoot
            $out = Join-Path $runRoot ($testName + '.stdout.txt')
            $err = Join-Path $runRoot ($testName + '.stderr.txt')
            $modulePath = $env:PSModulePath
            try {
                # Let Windows PowerShell build its own paths instead of inheriting PowerShell 7 modules.
                $env:PSModulePath = $null
                $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $PSScriptRoot 'execute-check.ps1') + '"'),'-Path',('"' + $test.FullName + '"') -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
            } finally { $env:PSModulePath = $modulePath }
            try { $exitCode = Wait-TestProcess -Process $process -TimeoutMs 120000 }
            finally { Get-Content -LiteralPath $out,$err -Encoding UTF8 }
            if ($exitCode -ne 0 -or (Get-Item -LiteralPath $err).Length -gt 0) { throw "Failed: $testName" }
            $completed = $true
        } finally {
            $resolved = (Resolve-Path -LiteralPath $runRoot).Path
            if ((Split-Path $resolved -Parent) -ne (Resolve-Path -LiteralPath $base).Path) { throw 'Unexpected cleanup path' }
            if ($completed) { Remove-Item -LiteralPath $resolved -Recurse -Force }
            else { Write-Warning "Failed test artifacts retained: $resolved" }
        }
    }
    $selection = if ($Name) { $tests.Name -join ', ' } else { $Group }
    Write-Output "PASS: $selection / $($tests.Count) test groups; no real messages or reactions sent."
} finally {
    $env:HELPER_TEST_ROOT = $oldRoot
    $env:AHK_EXE = $oldAhk
}
