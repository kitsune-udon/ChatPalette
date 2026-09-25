# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
. (Join-Path $ProjectRoot 'scripts\release-files.ps1')
Copy-ReleaseFiles $ProjectRoot $release
foreach ($relative in @('data\settings.db','data\private-registration.txt','tests\.tmp\private.txt','private.txt')) {
    $path=Join-Path $release $relative
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null
    [IO.File]::WriteAllText($path,'synthetic private marker')
}
& (Join-Path $release 'scripts\check-source.ps1') -ProjectRoot $release
# Direct -File startup must resolve its own project, independently of the caller's directory.
$sourceOut=Join-Path $release 'source-check-stdout.txt'
$sourceError=Join-Path $release 'source-check-stderr.txt'
$sourceProcess=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $release 'scripts\check-source.ps1')+'"') -WorkingDirectory (Join-Path $release 'data') -WindowStyle Hidden -PassThru -RedirectStandardOutput $sourceOut -RedirectStandardError $sourceError
if ((Wait-TestProcess -Process $sourceProcess -TimeoutMs 30000) -ne 0 -or [IO.File]::ReadAllText($sourceOut) -notmatch '^PASS:') {
    throw ('Direct source validation failed: '+[IO.File]::ReadAllText($sourceError))
}
foreach($invalid in @('version','encoding','link')) {
    $target=Join-Path $release $(if($invalid -eq 'version') {'VERSION'} elseif($invalid -eq 'encoding') {'main.ahk'} else {'README.md'})
    $original=[IO.File]::ReadAllBytes($target)
    try {
        if($invalid -eq 'version') { [IO.File]::WriteAllText($target,'99.99.99') }
        elseif($invalid -eq 'encoding') { [IO.File]::WriteAllText($target,"#Requires AutoHotkey v2.0`n",[Text.UTF8Encoding]::new($false)) }
        else { [IO.File]::AppendAllText($target,"`n[missing](not-a-real-file.md)`n",[Text.UTF8Encoding]::new($false)) }
        $rejected=$false
        try { & (Join-Path $release 'scripts\check-source.ps1') -ProjectRoot $release | Out-Null } catch { $rejected=$true }
        if(!$rejected) { throw "Source validator accepted invalid $invalid" }
    } finally { [IO.File]::WriteAllBytes($target,$original) }
}
$versionFile=Join-Path $release 'VERSION'
$originalVersion=[IO.File]::ReadAllBytes($versionFile)
try {
    [IO.File]::WriteAllText($versionFile,'invalid-version')
    # A misspelled option must fail before source inspection or output preparation.
    foreach ($script in @('build-release.ps1','verify-release.ps1','check-source.ps1')) {
        $argumentOutput=Join-Path $release ('argument-' + $script)
        $arguments=if ($script -eq 'check-source.ps1') { @{ProjectRoot=$release;ProjectRoto=$release} }
            else { @{OutputDirectory=$argumentOutput;OutptDirectory=$argumentOutput} }
        $rejected=$false
        try { & (Join-Path $release ('scripts\' + $script)) @arguments | Out-Null }
        catch [Management.Automation.ParameterBindingException] { $rejected=$true }
        if (!$rejected -or (Test-Path -LiteralPath $argumentOutput)) { throw "$script did not reject a misspelled option before executing" }
    }
    foreach ($script in @('build-release.ps1','verify-release.ps1')) {
        $invalidOutput=Join-Path $release ('invalid-' + $script)
        $rejected=$false
        try { & (Join-Path $release ('scripts\' + $script)) -OutputDirectory $invalidOutput | Out-Null }
        catch {
            if ($_.Exception.Message -ne 'Invalid VERSION') { throw }
            $rejected=$true
        }
        if (!$rejected) { throw "$script accepted an invalid release version" }
        if ((Test-Path -LiteralPath $invalidOutput) -and @(Get-ChildItem -LiteralPath $invalidOutput).Count) {
            throw "$script produced artifacts for an invalid release version"
        }
    }
} finally { [IO.File]::WriteAllBytes($versionFile,$originalVersion) }
# Lock an input after hashing so compression fails after opening its output archive.
$builderPath=Join-Path $release 'scripts\build-release.ps1'
$builderBytes=[IO.File]::ReadAllBytes($builderPath)
$builderSource=[IO.File]::ReadAllText($builderPath)
$archiveCalls=@($builderSource -split '\r?\n' | Where-Object { $_ -match '^    \[IO.Compression.ZipFile\]::CreateFromDirectory\(' })
if ($archiveCalls.Count -ne 1) { throw 'Archive creation injection point missing' }
$lockedArchiveCall=@'
    $lockedInput=Get-ChildItem -LiteralPath $stage -Recurse -File -Filter 'README.md' | Select-Object -First 1
    $inputLock=[IO.File]::Open($lockedInput.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
ARCHIVE_CALL
    } finally { $inputLock.Dispose() }
'@
$failedOutput=Join-Path $release 'dist'
$version=Get-ReleaseVersion $release
try {
    [IO.File]::WriteAllText($builderPath,$builderSource.Replace($archiveCalls[0],$lockedArchiveCall.Replace('ARCHIVE_CALL',$archiveCalls[0])),[Text.UTF8Encoding]::new($true))
    $rejected=$false
    try { & $builderPath -OutputDirectory $failedOutput | Out-Null }
    catch {
        if ($_.Exception.InnerException -isnot [IO.IOException]) { throw }
        $rejected=$true
    }
    if (!$rejected) { throw 'Compression accepted an exclusively locked input' }
    if (Test-Path -LiteralPath (Join-Path $failedOutput "ChatPalette-$version.zip")) { throw 'Failed compression published an incomplete release archive' }
    if (@(Get-ChildItem -LiteralPath $failedOutput -Force).Count) { throw 'Failed compression left temporary release artifacts' }
} finally { [IO.File]::WriteAllBytes($builderPath,$builderBytes) }
# Retry into the same directory, then validate the resulting archive below.
$out=$failedOutput
& $builderPath -OutputDirectory $out | Out-Null
$zipPath=Join-Path $out "ChatPalette-$version.zip"
$before=(Get-FileHash -LiteralPath $zipPath).Hash
$archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names=@($archive.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
    if ($names -match '(^data/|/\.tmp/|^private.txt$|^dist/)') { throw 'Private or temporary files included in release' }
    foreach ($required in @('main.ahk','VERSION','README.md','LICENSE','SHA256SUMS','tests/fixtures/ui-message-probe.ahk','tests/fixtures/library-model.ahk','tests/app-fixture.ps1','tests/test-app-input-plan.ps1','tests/run.ps1','scripts/build-release.ps1')) {
        if ($names -cnotcontains $required) { throw "Missing release file: $required" }
    }
    foreach ($file in Get-ChildItem -LiteralPath $release -Filter '*.ahk' -File -Recurse) {
        foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
            if ($line -match '^#Include (.+)$') {
                $include = $Matches[1].Replace('%A_ScriptDir%\','').Replace('\','/')
                if ($names -cnotcontains $include) { throw "Missing include: $line" }
            }
        }
    }
    $manifestEntry=@($archive.Entries | Where-Object { $_.FullName -eq 'SHA256SUMS' })[0]
    $reader=[IO.StreamReader]::new($manifestEntry.Open())
    try { $manifest=$reader.ReadToEnd() } finally { $reader.Dispose() }
    $expected=@{}
    foreach ($line in ($manifest -split '\r?\n')) {
        if (!$line) { continue }
        if ($line -cnotmatch '^([a-f0-9]{64})  (.+)$' -or $expected.ContainsKey($Matches[2])) { throw 'Invalid or duplicate release hash entry' }
        $expected[$Matches[2]]=$Matches[1]
    }
    if ($expected.Count -ne $archive.Entries.Count-1) { throw 'Incomplete release manifest' }
    foreach ($entry in $archive.Entries) {
        $name=$entry.FullName.Replace('\','/')
        if ($name -eq 'SHA256SUMS') { continue }
        $stream=$entry.Open(); $sha=[Security.Cryptography.SHA256]::Create()
        try { $actual=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose(); $stream.Dispose() }
        if ($expected[$name] -cne $actual) { throw "Wrong release checksum: $name" }
    }
} finally { $archive.Dispose() }
$failed=$false
try { & (Join-Path $release 'scripts\build-release.ps1') -OutputDirectory $out | Out-Null } catch { $failed=$true }
if (!$failed -or (Get-FileHash -LiteralPath $zipPath).Hash -ne $before) { throw 'Release overwrite protection failed' }
if (@(Get-ChildItem -LiteralPath $out -Directory -Filter 'stage-*').Count) { throw 'Release staging directory left behind' }
$protectedOutput=Join-Path $release '[validated]'
New-Item -ItemType Directory -Path $protectedOutput | Out-Null
$protectedReport=Join-Path $protectedOutput "ChatPalette-$version.validation.json"
[IO.File]::WriteAllText($protectedReport,'existing validation record')
$runnerPath=Join-Path $release 'tests\run.ps1'
$runnerSource=[IO.File]::ReadAllBytes($runnerPath)
try {
    # An unexpected validation must stop here, not recursively run the entire suite.
    [IO.File]::WriteAllText($runnerPath,"param([string]`$AutoHotkeyPath)`r`nthrow 'Unexpected validation run'`r`n",[Text.UTF8Encoding]::new($true))
    $rejected=$false
    try { & (Join-Path $release 'scripts\verify-release.ps1') -OutputDirectory $protectedOutput | Out-Null }
    catch {
        if ($_.Exception.Message -ne 'Release output exists; choose a new directory.') { throw }
        $rejected=$true
    }
    if (!$rejected -or [IO.File]::ReadAllText($protectedReport) -ne 'existing validation record') {
        throw 'Validation report overwrite protection failed for literal path'
    }
} finally { [IO.File]::WriteAllBytes($runnerPath,$runnerSource) }
# Exercise report publication with a stub runner; never recursively execute the suite.
$verifierPath=Join-Path $release 'scripts\verify-release.ps1'
$verifierBytes=[IO.File]::ReadAllBytes($verifierPath)
$verifierSource=[IO.File]::ReadAllText($verifierPath)
$reportWrites=@($verifierSource -split '\r?\n' | Where-Object { $_ -match '^    \[IO.File\]::WriteAllText\(' })
if ($reportWrites.Count -ne 1) { throw 'Report publication injection point missing' }
try {
    [IO.File]::WriteAllText($runnerPath,"param([string]`$AutoHotkeyPath)`r`n# Isolated publication fixture: no nested tests.`r`n",[Text.UTF8Encoding]::new($true))
    foreach ($scenario in @('concurrent','interrupted','success')) {
        # Keep nested release copies below Windows PowerShell 5.1 path limits.
        $publicationOutput=Join-Path $release ('['+$scenario.Substring(0,1)+']')
        $publicationReport=Join-Path $publicationOutput "ChatPalette-$version.validation.json"
        $replacement=$reportWrites[0]
        if ($scenario -eq 'concurrent') {
            $replacement='    [IO.File]::WriteAllText($report,"competing validation record")'+"`r`n"+$replacement
        } elseif ($scenario -eq 'interrupted') {
            $replacement+="`r`n    throw 'fixture report publication failure'"
        }
        [IO.File]::WriteAllText($verifierPath,$verifierSource.Replace($reportWrites[0],$replacement),[Text.UTF8Encoding]::new($true))
        $failure=$null
        try { & $verifierPath -OutputDirectory $publicationOutput | Out-Null }
        catch { $failure=$_ }
        if ($scenario -eq 'concurrent') {
            if (!$failure) { throw 'Concurrent report did not reject publication' }
            if ($failure.Exception.InnerException -isnot [IO.IOException]) { throw $failure }
            if ([IO.File]::ReadAllText($publicationReport) -cne 'competing validation record') { throw 'Concurrent validation report was overwritten' }
        } elseif ($scenario -eq 'interrupted') {
            if (!$failure -or $failure.Exception.Message -ne 'fixture report publication failure') { throw 'Report publication failure did not escape' }
            if (Test-Path -LiteralPath $publicationReport) { throw 'Interrupted publication left a final validation report' }
        } else {
            if ($failure) { throw $failure }
            $record=[IO.File]::ReadAllText($publicationReport) | ConvertFrom-Json
            $built=Join-Path $publicationOutput $record.Archive
            if ($record.Version -cne $version -or $record.Tests -ne 'All' -or $record.ArchiveSHA256 -cne (Get-FileHash -LiteralPath $built).Hash.ToLowerInvariant()) {
                throw 'Completed report does not describe its archive'
            }
        }
        $expectedFiles=if ($scenario -eq 'interrupted') { 1 } else { 2 }
        if (@(Get-ChildItem -LiteralPath $publicationOutput -Force).Count -ne $expectedFiles) { throw 'Report publication left temporary output files' }
    }
} finally {
    [IO.File]::WriteAllBytes($verifierPath,$verifierBytes)
    [IO.File]::WriteAllBytes($runnerPath,$runnerSource)
}
Write-Output 'PASS: release contents, privacy exclusions, checksums, compression recovery, report publication and concurrent overwrite protection.'
