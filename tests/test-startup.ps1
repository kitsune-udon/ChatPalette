# Test-Session: Desktop
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
New-Item -ItemType Directory -Path (Join-Path $release 'data') -Force | Out-Null
$dbPath = Join-Path $release 'data\settings.db'
function Run-Smoke {
    $run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + (Join-Path $release 'main.ahk') + '"'), '--smoke' -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $release 'error.txt')
    return Wait-TestProcess -Process $run -TimeoutMs 10000
}
foreach ($bytes in @([byte[]]@(),[Text.Encoding]::UTF8.GetBytes('invalid database'))) {
    [IO.File]::WriteAllBytes($dbPath,$bytes)
    $before = (Get-FileHash -LiteralPath $dbPath).Hash
    if ((Run-Smoke) -ne 1) { throw 'Empty or corrupt database must fail without automatic reset' }
    if ((Get-FileHash -LiteralPath $dbPath).Hash -ne $before) { throw 'Rejected database was altered' }
    if ([IO.File]::ReadAllText((Join-Path $release 'error.txt'),[Text.Encoding]::Default) -notmatch '設定の読み込み失敗') { throw 'Missing startup failure message' }
}
Remove-Item -LiteralPath $dbPath
# Interrupt fresh creation after validation/close but before publication.
$storePath = Join-Path $release 'src\settings\settings_store.ahk'
$storeSource = [IO.File]::ReadAllText($storePath)
$anchor = 'FileMove(temporary,path,false)'
if (!$storeSource.Contains($anchor)) { throw 'Database publication injection point missing' }
$crashSource = $storeSource.Replace($anchor, 'DllCall("ExitProcess","UInt",72)' + "`r`n        " + $anchor)
[IO.File]::WriteAllText($storePath,$crashSource,[Text.UTF8Encoding]::new($true))
if ((Run-Smoke) -ne 72) { throw 'Creation crash point was not reached' }
if (Test-Path -LiteralPath $dbPath) { throw 'Unfinished database was published' }
[IO.File]::WriteAllText($storePath,$storeSource,[Text.UTF8Encoding]::new($true))
if ((Run-Smoke) -ne 0) { throw 'Restart after interrupted creation failed' }
$before = (Get-FileHash -LiteralPath $dbPath).Hash
if ((Run-Smoke) -ne 0) { throw 'Existing database startup failed' }
if ((Get-FileHash -LiteralPath $dbPath).Hash -ne $before) { throw 'Startup unexpectedly rewrote settings' }
Write-Output 'PASS: invalid database preservation, interrupted creation, retry and unchanged startup'
