[CmdletBinding()]
param([string]$OutputDirectory, [string]$AutoHotkeyPath, [switch]$Sandbox)
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
    $inputManifest=Get-ReleaseManifest $stage
    $runner=Join-Path $stage 'tests\run.ps1'
    & $runner -AutoHotkeyPath $AutoHotkeyPath -Sandbox:$Sandbox
    # Tests may alter only their isolated runtimes. Compare staged inputs with initial manifest.
    if ($inputManifest -cne (Get-ReleaseManifest $stage)) { throw 'Validated source changed during tests' }
    & (Join-Path $stage 'scripts\build-release.ps1') -OutputDirectory $output | Out-Null
    # Bind every archived byte to the tested inputs, including the manifest itself.
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $sourceHash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($inputManifest))).Replace('-','').ToLowerInvariant()
        $expected=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($line in ($inputManifest -split '\r\n' | Where-Object { $_ })) {
            $hash,$name=$line -split '  ',2
            $expected.Add($name,$hash)
        }
        $expected.Add('SHA256SUMS',$sourceHash)
        $archive=[IO.Compression.ZipFile]::OpenRead($zip)
        try {
            if ($archive.Entries.Count -ne $expected.Count) { throw 'Release archive file count differs from validated inputs' }
            foreach ($entry in $archive.Entries) {
                $name=$entry.FullName
                if (!$expected.ContainsKey($name)) { throw "Release archive contains an unexpected or duplicate file: $name" }
                $stream=$entry.Open()
                try { $actual=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
                finally { $stream.Dispose() }
                if ($actual -cne $expected[$name]) { throw "Release archive differs from validated inputs: $name" }
                $null=$expected.Remove($name)
            }
        } finally { $archive.Dispose() }
    } finally { $sha.Dispose() }
    $result=[ordered]@{Version=$version;CheckedAt=[DateTime]::UtcNow.ToString('o');Tests='All';
        TestEnvironment=$(if ($Sandbox) { 'WindowsSandbox' } else { 'Host' });
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
    # A running Sandbox owns the mapped inputs; retain its logs and snapshot together.
    if ($completed -and !$Sandbox) {
        $resolved=(Resolve-Path -LiteralPath $stage).Path
        if ((Split-Path $resolved -Parent) -ne (Resolve-Path -LiteralPath (Join-Path $project 'tests\.tmp')).Path) { throw 'Unexpected validation cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } elseif ($completed) { Write-Output "Sandbox validation artifacts retained: $stage" }
    else { Write-Warning "Validation artifacts retained: $stage" }
}
