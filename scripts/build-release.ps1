[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path $project 'dist' }
. (Join-Path $PSScriptRoot 'release-files.ps1')
$version = Get-ReleaseVersion $project
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$zipPath = Join-Path $output "ChatPalette-$version.zip"
if (Test-Path -LiteralPath $zipPath) { throw 'Release archive already exists. Use a new version or output directory.' }
$stage = Join-Path $output ('stage-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'files'
$temporaryZip = Join-Path $stage 'release.zip'
try {
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    Copy-ReleaseFiles $project $payload
    $hashes = @(Get-ChildItem -LiteralPath $payload -File -Recurse | Sort-Object FullName | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.FullName.Substring($payload.Length + 1).Replace('\','/')
    })
    [IO.File]::WriteAllLines((Join-Path $payload 'SHA256SUMS'), $hashes, [Text.UTF8Encoding]::new($false))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $temporaryZip)
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
