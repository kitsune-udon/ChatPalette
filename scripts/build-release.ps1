[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path $project 'dist' }
. (Join-Path $PSScriptRoot 'release-files.ps1')
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$stage = Join-Path $output ('stage-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'files'
$temporaryZip = Join-Path $stage 'release.zip'
try {
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    Copy-ReleaseFiles $project $payload
    $version = Get-ReleaseVersion $payload
    $zipPath = Join-Path $output "ChatPalette-$version.zip"
    if (Test-Path -LiteralPath $zipPath) { throw 'Release archive already exists. Use a new version or output directory.' }
    # ZIP names and checksums share one relative-path representation.
    $entries = @(Get-ChildItem -LiteralPath $payload -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{Path=$_.FullName; Name=$_.FullName.Substring($payload.Length + 1).Replace('\','/')}
    })
    $hashes = @($entries | ForEach-Object {
        (Get-FileHash -LiteralPath $_.Path -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name
    })
    $manifest = Join-Path $payload 'SHA256SUMS'
    [IO.File]::WriteAllLines($manifest, $hashes, [Text.UTF8Encoding]::new($false))
    $entries += [pscustomobject]@{Path=$manifest; Name='SHA256SUMS'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem, System.IO.Compression
    $archive = [IO.Compression.ZipFile]::Open($temporaryZip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $entries) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $entry.Path, $entry.Name)
        }
    } finally { $archive.Dispose() }
    # Publish only a complete archive. Move refuses to overwrite a concurrent output.
    [IO.File]::Move($temporaryZip, $zipPath)
    Write-Output $zipPath
} finally {
    if (Test-Path -LiteralPath $stage) {
        $resolved = (Resolve-Path -LiteralPath $stage).Path
        if ((Split-Path $resolved -Parent) -ne $output -or (Split-Path $resolved -Leaf) -notlike 'stage-*') { throw 'Unexpected staging path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
