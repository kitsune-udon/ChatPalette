# Test-Session: Headless
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support.ps1')
$release=New-TestRuntime
. (Join-Path $ProjectRoot 'scripts\release-files.ps1')
Copy-ReleaseFiles $ProjectRoot $release
foreach ($relative in @('data\settings.db','data\reaction_selectors.json','tests\.tmp\private.txt','private.txt')) {
    $path=Join-Path $release $relative
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null
    [IO.File]::WriteAllText($path,'synthetic private marker')
}
& (Join-Path $release 'scripts\check-source.ps1') -ProjectRoot $release
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
$out=Join-Path $release 'dist'
& (Join-Path $release 'scripts\build-release.ps1') -OutputDirectory $out | Out-Null
$version=([IO.File]::ReadAllText((Join-Path $release 'VERSION'))).Trim()
$zipPath=Join-Path $out "ChatPalette-$version.zip"
$before=(Get-FileHash -LiteralPath $zipPath).Hash
$archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names=@($archive.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
    if ($names -match '(^data/|/\.tmp/|^private.txt$|^dist/)') { throw 'Private or temporary files included in release' }
    foreach ($required in @('main.ahk','VERSION','README.md','LICENSE','SHA256SUMS','tests/fixtures/settings.ini','tests/fixtures/ui-message-probe.ahk','tests/app-fixture.ps1','tests/test-app-input-plan.ps1','tests/run.ps1','scripts/build-release.ps1')) {
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
Write-Output 'PASS: release contents, privacy exclusions, includes, checksums and overwrite protection.'
