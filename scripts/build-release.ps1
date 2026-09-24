param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path $project 'dist' }
$version = (Get-Content -LiteralPath (Join-Path $project 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { throw 'Invalid VERSION' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$zipPath = Join-Path $output "ChatPalette-$version.zip"
if (Test-Path -LiteralPath $zipPath) { throw 'Release archive already exists. Use a new version or output directory.' }
$stage = Join-Path $output ('stage-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    . (Join-Path $PSScriptRoot 'release-files.ps1')
    Copy-ReleaseFiles $project $stage
    $hashes = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.FullName.Substring($stage.Length + 1).Replace('\','/')
    })
    [IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS'), $hashes, [Text.UTF8Encoding]::new($false))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
    Write-Output $zipPath
} finally {
    if (Test-Path -LiteralPath $stage) {
        $resolved = (Resolve-Path -LiteralPath $stage).Path
        if ((Split-Path $resolved -Parent) -ne $output -or (Split-Path $resolved -Leaf) -notlike 'stage-*') { throw 'Unexpected staging path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
