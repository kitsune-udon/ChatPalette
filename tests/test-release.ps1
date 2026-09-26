# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestDirectory
. (Join-Path $ProjectRoot 'scripts\release-files.ps1')
Copy-ReleaseFiles $ProjectRoot $release
# A version change needs no README rewrite; validation and both outputs use VERSION.
[IO.File]::WriteAllText((Join-Path $release 'VERSION'),"99.99.99-test+build.001`n",[Text.UTF8Encoding]::new($false))
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
foreach($invalid in @('version','encoding','link','syntax')) {
    $target=Join-Path $release $(if($invalid -eq 'version') {'VERSION'} elseif($invalid -eq 'encoding') {'main.ahk'} elseif($invalid -eq 'syntax') {'src\browser\page_actions.ps1'} else {'README.md'})
    $original=[IO.File]::ReadAllBytes($target)
    try {
        if($invalid -eq 'version') { [IO.File]::WriteAllText($target,'invalid-version') }
        elseif($invalid -eq 'encoding') { [IO.File]::WriteAllText($target,"#Requires AutoHotkey v2.0`n",[Text.UTF8Encoding]::new($false)) }
        elseif($invalid -eq 'syntax') { [IO.File]::WriteAllText($target,"# syntax fixture`r`n`r`n    )`r`n",[Text.UTF8Encoding]::new($true)) }
        else { [IO.File]::AppendAllText($target,"`n[missing](not-a-real-file.md)`n",[Text.UTF8Encoding]::new($false)) }
        $rejected=$false
        try { & (Join-Path $release 'scripts\check-source.ps1') -ProjectRoot $release | Out-Null }
        catch {
            if ($invalid -eq 'syntax' -and !$_.Exception.Message.StartsWith("PowerShell parse failure: ${target}:3:5: ")) { throw }
            $rejected=$true
        }
        if(!$rejected) { throw "Source validator accepted invalid $invalid" }
    } finally { [IO.File]::WriteAllBytes($target,$original) }
}
$versionFile=Join-Path $release 'VERSION'
foreach ($violation in @(
    @{Path='src\settings\settings_store.ahk';Code='MsgBox("unexpected storage UI")';Message='Boundary regression:'},
    @{Path='src\ui\help_view.ahk';Code='view.Show()';Message='Presentation boundary regression:'}
)) {
    $target=Join-Path $release $violation.Path
    $original=[IO.File]::ReadAllBytes($target)
    try {
        [IO.File]::AppendAllText($target,("`r`n"+$violation.Code+"`r`n"),[Text.UTF8Encoding]::new($false))
        $rejected=$false
        try { & (Join-Path $release 'scripts\check-source.ps1') -ProjectRoot $release | Out-Null }
        catch {
            if (!$_.Exception.Message.StartsWith($violation.Message)) { throw }
            $rejected=$true
        }
        if (!$rejected) { throw "Source validator accepted boundary violation: $($violation.Path)" }
    } finally { [IO.File]::WriteAllBytes($target,$original) }
}
$originalVersion=[IO.File]::ReadAllBytes($versionFile)
try {
    foreach ($invalidVersion in @('01.2.3','1.02.3','1.2.03','1.2.3-01','1.2.3-alpha.01',
        '1.2.3-alpha..1','1.2.3-.alpha','1.2.3-alpha.','1.2.3-','1.2.3+',
        '1.2.3+build..1','1.2.3+build_1','１.2.3','1.2.3-α','v1.2.3','1.2.3.4')) {
        [IO.File]::WriteAllText($versionFile,$invalidVersion)
        $rejected=$false
        try { Get-ReleaseVersion $release | Out-Null }
        catch {
            if ($_.Exception.Message -ne 'Invalid VERSION') { throw }
            $rejected=$true
        }
        if (!$rejected) { throw "Version validator accepted invalid SemVer: $invalidVersion" }
    }
    foreach ($validVersion in @('0.0.0','1.2.3','1.2.3-alpha.0','1.2.3-01a','1.2.3-x-y-z.--',
        '1.2.3+001','1.2.3-alpha.1+build.001','99999999999999999999.0.0')) {
        [IO.File]::WriteAllText($versionFile,($validVersion+"`n"))
        if ((Get-ReleaseVersion $release) -cne $validVersion) { throw "Version validator changed SemVer: $validVersion" }
    }
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
# Required root files must fail before a partial copy or archive can escape.
foreach ($required in @('main.ahk','LICENSE','.editorconfig')) {
    foreach ($replacement in @('missing','directory')) {
        $target=Join-Path $release $required
        $held=$target+'.held'
        $incompleteOutput=Join-Path $release 'incomplete-output'
        Move-Item -LiteralPath $target -Destination $held
        try {
            if ($replacement -eq 'directory') { New-Item -ItemType Directory -Path $target | Out-Null }
            foreach ($operation in @('copy','build')) {
                $rejected=$false
                try {
                    if ($operation -eq 'copy') { Copy-ReleaseFiles $release $incompleteOutput }
                    else { & (Join-Path $release 'scripts\build-release.ps1') -OutputDirectory $incompleteOutput | Out-Null }
                } catch {
                    if ($_.Exception.Message -ne "Missing required release file: $required") { throw }
                    $rejected=$true
                }
                if (!$rejected) { throw "$operation accepted $replacement required file: $required" }
                if ((Test-Path -LiteralPath $incompleteOutput) -and @(Get-ChildItem -LiteralPath $incompleteOutput -Force).Count) {
                    throw "$operation left artifacts for $replacement required file: $required"
                }
            }
        } finally {
            if ($replacement -eq 'directory' -and (Test-Path -LiteralPath $target -PathType Container)) { Remove-Item -LiteralPath $target }
            Move-Item -LiteralPath $held -Destination $target
        }
    }
}
# Lock an input after hashing so compression fails after opening its output archive.
$builderPath=Join-Path $release 'scripts\build-release.ps1'
$builderBytes=[IO.File]::ReadAllBytes($builderPath)
$builderSource=[IO.File]::ReadAllText($builderPath)
$archiveCalls=@($builderSource -split '\r?\n' | Where-Object { $_ -match '^            \[void\]\[IO.Compression.ZipFileExtensions\]::CreateEntryFromFile\(' })
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
    $names=@($archive.Entries | ForEach-Object { $_.FullName })
    if ($names -match '\\') { throw 'ZIP entry names must use forward slashes' }
    if ($names -match '(^data/|/\.tmp/|^private.txt$|^dist/)') { throw 'Private or temporary files included in release' }
    foreach ($required in @('main.ahk','VERSION','README.md','LICENSE','SHA256SUMS','tests/fixtures/ui-message-probe.ahk','tests/fixtures/library-model.ahk','tests/app-fixture.ps1','tests/test-app-input-plan.ps1','tests/run.ps1','tests/execute-check.ps1','scripts/build-release.ps1')) {
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
        $name=$entry.FullName
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
    [IO.File]::WriteAllText($runnerPath,"param([string]`$AutoHotkeyPath, [switch]`$Sandbox)`r`nthrow 'Unexpected validation run'`r`n",[Text.UTF8Encoding]::new($true))
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
    foreach ($scenario in @('concurrent','interrupted','success')) {
        $useSandbox=$scenario -eq 'success'
        [IO.File]::WriteAllText($runnerPath,('param([string]$AutoHotkeyPath, [switch]$Sandbox)' + "`r`n" +
            'if ($Sandbox -ne $' + $useSandbox.ToString().ToLowerInvariant() + ') { throw ''Wrong validation environment'' }'),[Text.UTF8Encoding]::new($true))
        # Keep nested release copies below Windows PowerShell 5.1 path limits.
        $publicationOutput=Join-Path $release ('['+$scenario.Substring(0,1)+']')
        $publicationReport=Join-Path $publicationOutput "ChatPalette-$version.validation.json"
        $stagesBefore=@(Get-ChildItem -LiteralPath (Join-Path $release 'tests\.tmp') -Directory -Filter 'v-*' | Select-Object -ExpandProperty FullName)
        $replacement=$reportWrites[0]
        if ($scenario -eq 'concurrent') {
            $replacement='    [IO.File]::WriteAllText($report,"competing validation record")'+"`r`n"+$replacement
        } elseif ($scenario -eq 'interrupted') {
            $replacement+="`r`n    throw 'fixture report publication failure'"
        }
        [IO.File]::WriteAllText($verifierPath,$verifierSource.Replace($reportWrites[0],$replacement),[Text.UTF8Encoding]::new($true))
        $failure=$null
        try { & $verifierPath -OutputDirectory $publicationOutput -Sandbox:$useSandbox | Out-Null }
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
            if ($record.Version -cne $version -or $record.Tests -ne 'All' -or $record.TestEnvironment -ne 'WindowsSandbox' -or $record.ArchiveSHA256 -cne (Get-FileHash -LiteralPath $built).Hash.ToLowerInvariant()) {
                throw 'Completed report does not describe its archive'
            }
            $retained=@(Get-ChildItem -LiteralPath (Join-Path $release 'tests\.tmp') -Directory -Filter 'v-*' | Where-Object FullName -NotIn $stagesBefore)
            if ($retained.Count -ne 1 -or !(Test-Path -LiteralPath (Join-Path $retained[0].FullName 'tests\run.ps1'))) {
                throw 'Sandbox validation removed its still-mounted inputs'
            }
        }
        $expectedFiles=if ($scenario -eq 'interrupted') { 1 } else { 2 }
        if (@(Get-ChildItem -LiteralPath $publicationOutput -Force).Count -ne $expectedFiles) { throw 'Report publication left temporary output files' }
    }
} finally {
    [IO.File]::WriteAllBytes($verifierPath,$verifierBytes)
    [IO.File]::WriteAllBytes($runnerPath,$runnerSource)
}
# Validate the artifact actually produced, not just a successful test run or a self-reported manifest.
function Set-ArchiveFault([string]$Path, [string]$Fault) {
    function Write-ProbeEntry($archive, $name, $text) {
        $entry=$archive.GetEntry($name)
        if ($entry) { $entry.Delete() }
        $writer=[IO.StreamWriter]::new($archive.CreateEntry($name).Open(),[Text.UTF8Encoding]::new($false))
        try { $writer.Write($text) } finally { $writer.Dispose() }
    }
    $archive=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Update)
    try {
        switch ($Fault) {
            'content' { Write-ProbeEntry $archive 'README.md' 'changed archive body' }
            'missing' { $archive.GetEntry('README.md').Delete() }
            'extra' { Write-ProbeEntry $archive 'unexpected.txt' 'extra' }
            'manifest' { Write-ProbeEntry $archive 'SHA256SUMS' 'incorrect manifest' }
            'consistent' {
                $reader=[IO.StreamReader]::new($archive.GetEntry('SHA256SUMS').Open())
                try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
                $sha=[Security.Cryptography.SHA256]::Create()
                try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('changed archive body'))).Replace('-','').ToLowerInvariant() }
                finally { $sha.Dispose() }
                Write-ProbeEntry $archive 'README.md' 'changed archive body'
                Write-ProbeEntry $archive 'SHA256SUMS' ($text -replace '(?m)^[a-f0-9]{64}  README\.md',($hash+'  README.md'))
            }
            default {
                $reader=[IO.StreamReader]::new($archive.GetEntry('README.md').Open())
                try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
                if ($Fault -eq 'case') {
                    $archive.GetEntry('README.md').Delete()
                    Write-ProbeEntry $archive 'readme.md' $text
                } else {
                    # Keep the entry count unchanged so a count-only check cannot pass.
                    $archive.GetEntry('LICENSE').Delete()
                    $writer=[IO.StreamWriter]::new($archive.CreateEntry('README.md').Open(),[Text.UTF8Encoding]::new($false))
                    try { $writer.Write($text) } finally { $writer.Dispose() }
                }
            }
        }
    } finally { $archive.Dispose() }
}
$expectedManifest=Get-ReleaseManifest $release
$hashes=Get-ReleaseArchiveHashes -Path $zipPath -ExpectedManifest $expectedManifest
if ($hashes.ArchiveSHA256 -cne $before.ToLowerInvariant()) { throw 'Archive validation returned the wrong archive hash' }
# An attempted mutation between content validation and the final hash cannot change its input.
$lockedChecker=Join-Path $release 'archive-check.ps1'
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'scripts\release-files.ps1') -Destination $lockedChecker
Edit-TestSource $release 'archive-check.ps1' '} finally { $archive.Dispose() }' ('} finally { $archive.Dispose() }' + "`r`n" + '            Try-ArchiveMutation $Path')
& {
    . $lockedChecker
    function Try-ArchiveMutation([string]$Path) {
        try {
            if ($script:ArchiveMutation -eq 'write') { [IO.File]::WriteAllText($Path,'changed after validation') }
            else {
                [IO.File]::Move($Path,($Path+'.original'))
                [IO.File]::WriteAllText($Path,'replaced after validation')
            }
        } catch [IO.IOException] { $script:ArchiveMutationBlocked=$true }
    }
    foreach ($script:ArchiveMutation in @('write','replace')) {
        $script:ArchiveMutationBlocked=$false
        $ownedZip=Join-Path $out ($script:ArchiveMutation+'.zip')
        Copy-Item -LiteralPath $zipPath -Destination $ownedZip
        $hashes=Get-ReleaseArchiveHashes -Path $ownedZip -ExpectedManifest $expectedManifest
        if (!$script:ArchiveMutationBlocked -or $hashes.ArchiveSHA256 -cne $before.ToLowerInvariant()) {
            throw "Archive validation released its input before hashing: $script:ArchiveMutation / $($hashes.ArchiveSHA256)"
        }
        $exclusive=[IO.File]::Open($ownedZip,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $exclusive.Dispose()
    }
}
foreach ($fault in @('content','missing','extra','manifest','consistent','case','duplicate')) {
    $corruptZip=Join-Path $out ('bad-'+$fault+'.zip')
    Copy-Item -LiteralPath $zipPath -Destination $corruptZip
    Set-ArchiveFault -Path $corruptZip -Fault $fault
    $failure=''
    try { Get-ReleaseArchiveHashes -Path $corruptZip -ExpectedManifest $expectedManifest | Out-Null }
    catch { $failure=$_.Exception.Message }
    if ($failure -notlike 'Release archive*') { throw "Corrupt archive was accepted: $fault / $failure" }
    $exclusive=[IO.File]::Open($corruptZip,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $exclusive.Dispose()
}
# Keep one end-to-end check that an invalid artifact prevents a validation record.
try {
    [IO.File]::WriteAllText($runnerPath,"param([string]`$AutoHotkeyPath, [switch]`$Sandbox)`r`n# Artifact fixture: no nested tests.`r`n",[Text.UTF8Encoding]::new($true))
    $damage=@'
    $archive=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Update)
    try { $archive.GetEntry('README.md').Delete() } finally { $archive.Dispose() }
'@
    Edit-TestSource $release 'scripts/build-release.ps1' '    Write-Output $zipPath' ($damage+"`r`n    Write-Output `$zipPath")
    $corruptOutput=Join-Path $release 'bad-artifact'
    $failure=''
    try { & $verifierPath -OutputDirectory $corruptOutput -WarningAction SilentlyContinue | Out-Null }
    catch { $failure=$_.Exception.Message }
    if ($failure -notlike 'Release archive*' -or (Test-Path -LiteralPath (Join-Path $corruptOutput "ChatPalette-$version.validation.json"))) {
        throw "Corrupt archive received a validation record: $failure"
    }
    if (!(Test-Path -LiteralPath (Join-Path $corruptOutput "ChatPalette-$version.zip"))) { throw 'Failed archive was not retained for diagnosis' }
} finally {
    [IO.File]::WriteAllBytes($builderPath,$builderBytes)
    [IO.File]::WriteAllBytes($runnerPath,$runnerSource)
}
# A failed Sandbox runner or changed validated source must produce no release output.
try {
    foreach ($scenario in @('failure','edit','add','remove')) {
        $body='param([string]$AutoHotkeyPath, [switch]$Sandbox)' + "`r`n" +
            'if (!$Sandbox) { throw ''Sandbox selection was lost'' }' + "`r`n"
        $body += switch ($scenario) {
            'failure' { 'throw ''fixture Sandbox failure''' }
            'edit' { 'Add-Content -LiteralPath (Join-Path $PSScriptRoot ''..\README.md'') -Value ''changed''' }
            'add' { 'Set-Content -LiteralPath (Join-Path $PSScriptRoot ''new-check.ps1'') -Value ''# added''' }
            'remove' { 'Remove-Item -LiteralPath (Join-Path $PSScriptRoot ''test-input.ps1'')' }
        }
        [IO.File]::WriteAllText($runnerPath,$body,[Text.UTF8Encoding]::new($true))
        $failedOutput=Join-Path $release ('fail-'+$scenario)
        $failure=''
        try { & $verifierPath -Sandbox -OutputDirectory $failedOutput | Out-Null }
        catch { $failure=$_.Exception.Message }
        $expected=if ($scenario -eq 'failure') { 'fixture Sandbox failure' } else { 'Validated source changed during tests' }
        if ($failure -ne $expected -or @(Get-ChildItem -LiteralPath $failedOutput -Force).Count) {
            throw "Invalid validation escaped the release gate: $scenario / $failure"
        }
    }
} finally { [IO.File]::WriteAllBytes($runnerPath,$runnerSource) }
# VERSION belongs to the captured inputs, including an edit just before copying.
try {
    [IO.File]::WriteAllText($runnerPath,"param([string]`$AutoHotkeyPath, [switch]`$Sandbox)`r`n# Isolated snapshot fixture: no nested tests.`r`n",[Text.UTF8Encoding]::new($true))
    foreach ($script in @('build-release.ps1','verify-release.ps1')) {
        $entry=Join-Path $release ('scripts\'+$script)
        $entryBytes=[IO.File]::ReadAllBytes($entry)
        $snapshotOutput=Join-Path $release ('snap-'+$script.Substring(0,1))
        $copyStep=if ($script -eq 'build-release.ps1') { '    Copy-ReleaseFiles $project $payload' }
            else { '    Copy-ReleaseFiles $project $stage' }
        $editVersion=@'
    [IO.File]::WriteAllText((Join-Path $project 'VERSION'),"99.99.100-snapshot`n",[Text.UTF8Encoding]::new($false))
'@
        try {
            Edit-TestSource $release ('scripts\'+$script) $copyStep ($editVersion+"`r`n"+$copyStep)
            & $entry -OutputDirectory $snapshotOutput | Out-Null
            $snapshotZip=Join-Path $snapshotOutput 'ChatPalette-99.99.100-snapshot.zip'
            if (!(Test-Path -LiteralPath $snapshotZip)) { throw 'Archive name does not follow the captured VERSION' }
            $archive=[IO.Compression.ZipFile]::OpenRead($snapshotZip)
            try {
                $reader=[IO.StreamReader]::new($archive.GetEntry('VERSION').Open())
                try { $capturedVersion=$reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
                if ($capturedVersion -cne '99.99.100-snapshot') { throw 'Archive contents do not match its version' }
            } finally { $archive.Dispose() }
            if ($script -eq 'verify-release.ps1') {
                $record=[IO.File]::ReadAllText((Join-Path $snapshotOutput 'ChatPalette-99.99.100-snapshot.validation.json')) | ConvertFrom-Json
                if ($record.Version -cne $capturedVersion -or $record.Archive -cne [IO.Path]::GetFileName($snapshotZip)) {
                    throw 'Validation report does not follow the captured VERSION'
                }
                if ($record.TestEnvironment -ne 'Host') { throw 'Host validation recorded the wrong environment' }
            }
        } finally {
            [IO.File]::WriteAllBytes($entry,$entryBytes)
            [IO.File]::WriteAllBytes($versionFile,$originalVersion)
        }
    }
} finally { [IO.File]::WriteAllBytes($runnerPath,$runnerSource) }
Write-Output 'PASS: release snapshots, contents, privacy exclusions, checksums, compression recovery, report publication and concurrent overwrite protection.'
