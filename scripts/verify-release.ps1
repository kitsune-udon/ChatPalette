[CmdletBinding()]
param([string]$OutputDirectory, [string]$AutoHotkeyPath)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory=Join-Path $project 'dist' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output=(Resolve-Path -LiteralPath $OutputDirectory).Path
. (Join-Path $PSScriptRoot 'release-files.ps1')
$stage=Join-Path (Join-Path $project 'tests\.tmp') ('v-'+[guid]::NewGuid().ToString('N').Substring(0,16))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$completed=$false
$temporaryReport=Join-Path $output ('validation-'+[guid]::NewGuid().ToString('N')+'.tmp')
try {
    # Freeze the allowlisted inputs once. Validate and package exactly this copy.
    Copy-ReleaseFiles $project $stage
    $version=Get-ReleaseVersion $stage
    $zip=Join-Path $output "ChatPalette-$version.zip"
    $report=Join-Path $output "ChatPalette-$version.validation.json"
    if ((Test-Path -LiteralPath $zip) -or (Test-Path -LiteralPath $report)) { throw 'Release output exists; choose a new directory.' }
    $inputHashes=@{}
    foreach($file in @(Get-ReleaseFiles $stage)) { $inputHashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash }
    & (Join-Path $stage 'scripts\check-source.ps1') -ProjectRoot $stage
    $runner=Join-Path $stage 'tests\run.ps1'
    & $runner -AutoHotkeyPath $AutoHotkeyPath
    # Tests may alter only their isolated runtimes. Compare staged inputs with initial manifest.
    foreach($file in @(Get-ReleaseFiles $stage)) {
        if (!$inputHashes.ContainsKey($file.FullName) -or $inputHashes[$file.FullName] -cne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw 'Validated source changed during tests' }
        $inputHashes.Remove($file.FullName)
    }
    if ($inputHashes.Count) { throw 'Validated source files were removed during tests' }
    & (Join-Path $stage 'scripts\build-release.ps1') -OutputDirectory $output | Out-Null
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $stream=$archive.GetEntry('SHA256SUMS').Open()
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $sourceHash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose(); $stream.Dispose() }
    } finally { $archive.Dispose() }
    $result=[ordered]@{Version=$version;CheckedAt=[DateTime]::UtcNow.ToString('o');Tests='All';
        TestGroups=@(Get-ChildItem -LiteralPath (Join-Path $stage 'tests') -Filter 'test-*.ps1' -File).Count;
        Archive=[IO.Path]::GetFileName($zip);ArchiveSHA256=(Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant();
        SourceManifestSHA256=$sourceHash;RealBrowser='Separate check-browser.ps1 reports required; not implied by automated tests'}
    [IO.File]::WriteAllText($temporaryReport,($result | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    # Publish the complete report without overwriting a file created during validation.
    [IO.File]::Move($temporaryReport,$report)
    $completed=$true
    Write-Output $zip
    Write-Output $report
} finally {
    if (Test-Path -LiteralPath $temporaryReport) { Remove-Item -LiteralPath $temporaryReport -Force }
    if ($completed) { Remove-Item -LiteralPath $stage -Recurse -Force }
    else { Write-Warning "Validation artifacts retained: $stage" }
}
