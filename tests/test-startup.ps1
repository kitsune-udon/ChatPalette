. (Join-Path $PSScriptRoot 'support.ps1')
$release = New-TestRuntime
$settings = Join-Path $release 'settings.ini'
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
Write-Output 'PASS: corrupt startup retains original and reports key; corrected startup succeeds.'
