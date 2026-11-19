[CmdletBinding()]
param([Parameter(Mandatory)][string[]]$Name, [string]$AutoHotkeyPath, [switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $ProjectRoot 'scripts\release-files.ps1')
Assert-LegacyReleaseProject $ProjectRoot 'chatpalette-tools sandbox'
$sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (!$PrepareOnly -and !(Test-Path -LiteralPath $sandboxExe -PathType Leaf)) {
    throw 'Windows Sandbox is not installed. Enable Containers-DisposableClientVM and restart Windows if requested. Use -Sandbox -PrepareOnly to prepare without launching.'
}
$ahk = if ($AutoHotkeyPath) { $AutoHotkeyPath } else { Get-AutoHotkeyPath }
$ahk = (Resolve-Path -LiteralPath $ahk -ErrorAction Stop).Path
if (!(Test-Path -LiteralPath $ahk -PathType Leaf)) { throw 'AutoHotkey must be an executable file.' }
$runRoot = Join-Path $PSScriptRoot ('.tmp\sandbox-' + [guid]::NewGuid().ToString('N').Substring(0,16))
$inputRoot = Join-Path $runRoot 'input'
$outputRoot = Join-Path $runRoot 'results'
New-Item -ItemType Directory -Path $inputRoot,$outputRoot | Out-Null
Copy-ReleaseFiles -Project $ProjectRoot -Destination (Join-Path $inputRoot 'project')
Copy-Item -LiteralPath $ahk -Destination (Join-Path $inputRoot 'AutoHotkey.exe')
@{ Name = @($Name) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $inputRoot 'selection.json') -Encoding UTF8
$config = Join-Path $runRoot 'tests.wsb'
$inputXml = [Security.SecurityElement]::Escape($inputRoot)
$outputXml = [Security.SecurityElement]::Escape($outputRoot)
$xml = @"
<Configuration>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <MappedFolders>
    <MappedFolder><HostFolder>$inputXml</HostFolder><SandboxFolder>C:\ChatPaletteInput</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$outputXml</HostFolder><SandboxFolder>C:\ChatPaletteResults</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ChatPaletteInput\project\tests\sandbox-guest.ps1 -InputRoot C:\ChatPaletteInput -OutputRoot C:\ChatPaletteResults -WorkRoot C:\ChatPaletteTests</Command></LogonCommand>
</Configuration>
"@
[IO.File]::WriteAllText($config,$xml,[Text.UTF8Encoding]::new($false))
Write-Output "Sandbox configuration: $config"
Write-Output "Sandbox results: $outputRoot"
if ($PrepareOnly) { return }
$created = $false
$mutex = [Threading.Mutex]::new($true, 'Local\ChatPaletteSandboxRunner', [ref]$created)
try {
    if (!$created) { throw 'Another ChatPalette Sandbox runner is active.' }
    $sandboxCli = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wsb.exe'
    if (Test-Path -LiteralPath $sandboxCli -PathType Leaf) {
        $listPath = Join-Path $runRoot 'session-list.json'
        $listErrorPath = Join-Path $runRoot 'session-list-stderr.txt'
        $listProcess = Start-Process -FilePath $sandboxCli -ArgumentList 'list','--raw' -WindowStyle Hidden -PassThru -RedirectStandardOutput $listPath -RedirectStandardError $listErrorPath
        try {
            # Keep the process handle open so Windows PowerShell 5.1 can read ExitCode after a fast exit.
            $null = $listProcess.Handle
            if (!$listProcess.WaitForExit(10000)) {
                if (!$listProcess.HasExited) { $listProcess.Kill() }
                throw "Windows Sandbox session query timed out. See $listErrorPath."
            }
            if ($listProcess.ExitCode -ne 0 -or (Get-Item -LiteralPath $listErrorPath).Length -ne 0) {
                throw "Windows Sandbox session query failed. See $listErrorPath."
            }
        } finally {
            $listProcess.Dispose()
        }
        $list = Get-Content -LiteralPath $listPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($list.WindowsSandboxEnvironments -isnot [array]) { throw "Invalid Windows Sandbox session query result. See $listPath." }
        if ($list.WindowsSandboxEnvironments.Count -ne 0) {
            throw 'Windows Sandbox is already open. Use wsb list to check the active session before starting the tests.'
        }
    }
    # The server can stay alive without a VM, for example after `wsb list`.
    $sessions = @(Get-Process -Name WindowsSandbox,WindowsSandboxRemoteSession,WindowsSandboxClient,vmmemWindowsSandbox -ErrorAction SilentlyContinue)
    if ($sessions.Count) {
        throw "Windows Sandbox is already open (PID $($sessions.Id -join ', ')). Close that session before starting the tests."
    }
    # The Sandbox window is visible for observing tests. Do not activate host test windows.
    $process = Start-Process -FilePath $sandboxExe -ArgumentList ('"' + $config + '"') -WindowStyle Normal -PassThru
    $process.Dispose()
    $resultPath = Join-Path $outputRoot 'result.json'
    $logs = @('stdout.txt','stderr.txt') | ForEach-Object { [pscustomobject]@{Path=(Join-Path $outputRoot $_); Position=0} }
    $timeoutMs = 1000 * (180 + 120 * ($Name.Count + 1))
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path -LiteralPath $resultPath)) {
        foreach ($log in $logs) { Write-TestLogUpdate $log }
        if ($elapsed.ElapsedMilliseconds -ge $timeoutMs) {
            throw "Sandbox did not report completion. It may still be running; inspect its window and $outputRoot. No success is assumed and no other Sandbox is stopped."
        }
        Start-Sleep -Milliseconds 500
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    foreach ($log in $logs) { Write-TestLogUpdate $log -Complete }
    if ($result.ExitCode -ne 0) { throw "Sandbox tests failed: $($result.Error). Results: $outputRoot" }
    Write-Output "PASS: Windows Sandbox / $($Name.Count) test groups. Results: $outputRoot"
} finally {
    if ($created) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
