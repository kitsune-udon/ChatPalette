. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
New-Item -ItemType Directory -Path (Join-Path $release 'data') -Force | Out-Null
$settings = Join-Path $release 'data\settings.ini'
$bad = "[General]`r`nCount=invalid`r`n"
[IO.File]::WriteAllText($settings, $bad, [Text.UnicodeEncoding]::new($false,$true))
$originalHash = (Get-FileHash -LiteralPath $settings).Hash
function Run-Smoke {
    $run = Start-Process -FilePath (Get-AutoHotkeyPath) -ArgumentList '/ErrorStdOut', ('"' + (Join-Path $release 'main.ahk') + '"'), '--smoke' -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $release 'error.txt')
    $null = $run.Handle
    if (!$run.WaitForExit(10000)) { Stop-Process -Id $run.Id; throw 'Startup smoke timeout' }
    return $run.ExitCode
}
if ((Run-Smoke) -ne 1) { throw 'Corrupt settings must fail without automatic reset' }
$migrated = Join-Path $release 'data\settings.ini'
if ((Get-FileHash -LiteralPath $migrated).Hash -ne $originalHash) { throw 'Corrupt original was altered' }
$message = [IO.File]::ReadAllText((Join-Path $release 'error.txt'))
if ($message -notmatch '\[General\] Count') { throw 'Startup error does not identify the setting' }
[IO.File]::WriteAllText($migrated, "[General]`r`nCount=0`r`n[CommonDanmaku]`r`nCount=0`r`n", [Text.UnicodeEncoding]::new($false,$true))
if ((Run-Smoke) -ne 0) { throw 'Corrected settings failed startup' }
Remove-Item -LiteralPath (Join-Path $release 'data\settings.db')
foreach ($broken in @('', "[General]`r`nSchema=3`r`n[Profile1]`r`nName=retained`r`nCount=1`r`nText1=important`r`n[CommonDanmaku]`r`nCount=0`r`n")) {
    [IO.File]::WriteAllText($migrated,$broken,[Text.UnicodeEncoding]::new($false,$true))
    $before = (Get-FileHash -LiteralPath $migrated).Hash
    if ((Run-Smoke) -ne 1) { throw 'Incomplete existing settings must fail startup' }
    if ((Get-FileHash -LiteralPath $migrated).Hash -ne $before) { throw 'Incomplete settings changed during startup' }
}
Write-Output 'PASS: corrupt/empty/incomplete startup retains original; corrected startup succeeds.'

# Stop the actual migration after validation/close but before publishing the DB.
[IO.File]::WriteAllText($migrated,"[General]`r`nSchema=3`r`nCount=0`r`n[CommonDanmaku]`r`nCount=1`r`nLabel1=kept`r`nText1=important`r`nSlot1=0`r`n",[Text.UnicodeEncoding]::new($false,$true))
$originalHash = (Get-FileHash -LiteralPath $migrated).Hash
$storePath = Join-Path $release 'src\settings\settings_store.ahk'
$storeSource = [IO.File]::ReadAllText($storePath)
$crashSource = $storeSource.Replace('FileMove(temporary,path,false)', 'DllCall("ExitProcess","UInt",72)' + "`r`n        FileMove(temporary,path,false)")
[IO.File]::WriteAllText($storePath,$crashSource,[Text.UTF8Encoding]::new($true))
if ((Run-Smoke) -ne 72) { throw 'Migration crash point was not reached' }
if (Test-Path -LiteralPath (Join-Path $release 'data\settings.db')) { throw 'Unfinished migration was published' }
if ((Get-FileHash -LiteralPath $migrated).Hash -ne $originalHash) { throw 'Migration crash changed original INI' }
[IO.File]::WriteAllText($storePath,$storeSource,[Text.UTF8Encoding]::new($true))
if ((Run-Smoke) -ne 0) { throw 'Restart after interrupted migration failed' }
if ((Get-FileHash -LiteralPath $migrated).Hash -ne $originalHash) { throw 'Migration retry changed original INI' }
Write-Output 'PASS: interrupted migration preserves INI and restarts safely.'

# A migrated installation must start from the DB alone.
Remove-Item -LiteralPath $migrated
$dbPath=Join-Path $release 'data\settings.db'
$before=(Get-FileHash -LiteralPath $dbPath).Hash
if ((Run-Smoke) -ne 0 -or (Test-Path -LiteralPath $migrated)) { throw 'DB-only startup recreated legacy settings or failed' }
if ((Get-FileHash -LiteralPath $dbPath).Hash -ne $before) { throw 'DB-only startup unexpectedly rewrote settings' }
Write-Output 'PASS: standalone database startup without legacy files.'
