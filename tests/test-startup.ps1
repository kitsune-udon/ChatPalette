# Test-Session: Desktop
. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
[IO.File]::WriteAllText((Join-Path $release 'VERSION'),"99.98.97-test`r`n",[Text.UTF8Encoding]::new($false))
$dbPath = Join-Path $release 'data\settings.db'
function Run-Startup([string[]]$Options=@('--smoke')) {
    $arguments = @('/ErrorStdOut', ('"' + (Join-Path $release 'main.ahk') + '"')) + $Options
    $run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $release 'error.txt')
    return Wait-TestProcess -Process $run -TimeoutMs 10000
}
if ((Run-Startup -Options '--check') -ne 0 -or (Test-Path -LiteralPath (Join-Path $release 'data'))) { throw 'Syntax check initialized application data' }
foreach ($options in @(@('--smkoe'),@('--check','unexpected'),@('--smoke','unexpected'),@('--quiet','unexpected'))) {
    if ((Run-Startup -Options $options) -ne 1 -or (Test-Path -LiteralPath (Join-Path $release 'data'))) { throw 'Invalid startup arguments initialized the application' }
    if ([IO.File]::ReadAllText((Join-Path $release 'error.txt'),[Text.Encoding]::Default) -notmatch '起動引数が不正') { throw 'Missing startup argument error' }
}
$dataPath=Join-Path $release 'data'
[IO.File]::WriteAllText($dataPath,'preserved file')
if ((Run-Startup) -ne 1 -or [IO.File]::ReadAllText($dataPath) -ne 'preserved file') { throw 'Failed data-directory preparation did not preserve the existing file' }
if ([IO.File]::ReadAllText((Join-Path $release 'error.txt'),[Text.Encoding]::Default) -notmatch 'データフォルダーの準備失敗') { throw 'Missing data-directory failure message' }
Remove-Item -LiteralPath $dataPath
New-Item -ItemType Directory -Path $dataPath | Out-Null
foreach ($bytes in @([byte[]]@(),[Text.Encoding]::UTF8.GetBytes('invalid database'))) {
    [IO.File]::WriteAllBytes($dbPath,$bytes)
    $before = (Get-FileHash -LiteralPath $dbPath).Hash
    if ((Run-Startup) -ne 1) { throw 'Empty or corrupt database must fail without automatic reset' }
    if ((Get-FileHash -LiteralPath $dbPath).Hash -ne $before) { throw 'Rejected database was altered' }
    if ([IO.File]::ReadAllText((Join-Path $release 'error.txt'),[Text.Encoding]::Default) -notmatch '設定の読み込み失敗') { throw 'Missing startup failure message' }
}
# The shared initializer also fails without dialogs when the test caller requests it explicitly.
$failed=$false
try { Invoke-AppTest -Runtime $release -Body 'throw Error("Initialization unexpectedly succeeded")' | Out-Null }
catch { $failed=$_.Exception.Message -match '^Test failed \(1\):' }
if (!$failed -or [IO.File]::ReadAllText((Join-Path $release 'stderr.txt'),[Text.Encoding]::Default) -notmatch '設定の読み込み失敗') { throw 'Explicit unattended initialization did not report failure without CLI arguments' }
if ((Get-FileHash -LiteralPath $dbPath).Hash -ne $before) { throw 'Unattended initialization altered the rejected database' }
Remove-Item -LiteralPath $dbPath
# Interrupt fresh creation after validation/close but before publication.
$storePath = Join-Path $release 'src\settings\settings_store.ahk'
$storeSource = [IO.File]::ReadAllText($storePath)
$anchor = 'FileMove(temporary,path,false)'
Edit-TestSource $release 'src/settings/settings_store.ahk' $anchor ('DllCall("ExitProcess","UInt",72)' + "`r`n        " + $anchor)
if ((Run-Startup) -ne 72) { throw 'Creation crash point was not reached' }
if (Test-Path -LiteralPath $dbPath) { throw 'Unfinished database was published' }
[IO.File]::WriteAllText($storePath,$storeSource,[Text.UTF8Encoding]::new($true))
if ((Run-Startup) -ne 0) { throw 'Restart after interrupted creation failed' }
$before = (Get-FileHash -LiteralPath $dbPath).Hash
if ((Run-Startup) -ne 0) { throw 'Existing database startup failed' }
if ((Get-FileHash -LiteralPath $dbPath).Hash -ne $before) { throw 'Startup unexpectedly rewrote settings' }
Invoke-AppTest -Runtime $release -Body 'Assert(AppVersion == "99.98.97-test","displayed version excludes the file line ending")
ExitApp()'
Write-Output 'PASS: startup argument validation, explicit unattended initialization, invalid database preservation, interrupted creation, retry and unchanged startup'
