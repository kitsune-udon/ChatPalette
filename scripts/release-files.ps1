function Get-ReleaseVersion([string]$Project) {
    $version = ([IO.File]::ReadAllText((Join-Path $Project 'VERSION'))).Trim()
    # SemVer 2.0.0: core numbers, optional prerelease, optional build metadata.
    $semver = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' +
        '(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?' +
        '(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'
    if ($version -cnotmatch $semver) { throw 'Invalid VERSION' }
    return $version
}

function Get-ReleaseFiles([string]$project) {
    # Allowlist only. Never traverse data/, .git/, or test execution directories.
    $files = @(foreach ($name in @('main.ahk','README.md','LICENSE','VERSION','CHANGELOG.md','.gitignore','.gitattributes','.editorconfig')) {
        $path = Join-Path $project $name
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing required release file: $name" }
        Get-Item -LiteralPath $path -Force -ErrorAction Stop
    })
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'src') -Recurse -File | Where-Object { $_.Extension -in '.ahk','.ps1' })
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'docs') -Filter '*.md' -Recurse -File)
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'tests') -Filter '*.ps1' -File)
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'tests\fixtures') -Filter '*.ahk' -File)
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'scripts') -Filter '*.ps1' -File)
    return $files
}

# Stable relative paths let the host, guest and archive describe the same inputs.
function Get-ReleaseManifest([string]$Project) {
    $root = (Resolve-Path -LiteralPath $Project).Path
    $paths = [string[]]@(Get-ReleaseFiles $root | ForEach-Object { $_.FullName })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $lines = @(foreach ($path in $paths) {
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $path.Substring($root.Length + 1).Replace('\','/')
    })
    return ($lines -join "`r`n") + "`r`n"
}

function Get-ReleaseArchiveHashes([string]$Path, [string]$ExpectedManifest) {
    Add-Type -AssemblyName System.IO.Compression
    # Bind every archived byte to the tested inputs, including the manifest itself.
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $sourceHash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ExpectedManifest))).Replace('-','').ToLowerInvariant()
        $expected=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($line in ($ExpectedManifest -split '\r\n' | Where-Object { $_ })) {
            $hash,$name=$line -split '  ',2
            $expected.Add($name,$hash)
        }
        $expected.Add('SHA256SUMS',$sourceHash)
        # Keep the same read-only file open through validation and hashing.
        $file=[IO.File]::OpenRead($Path)
        try {
            $archive=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Read,$true)
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
            $file.Position=0
            $archiveHash=[BitConverter]::ToString($sha.ComputeHash($file)).Replace('-','').ToLowerInvariant()
        } finally { $file.Dispose() }
    } finally { $sha.Dispose() }
    return @{ ArchiveSHA256=$archiveHash; SourceManifestSHA256=$sourceHash }
}

function Copy-ReleaseFiles([string]$Project, [string]$Destination) {
    $root = (Resolve-Path -LiteralPath $Project).Path
    foreach ($file in @(Get-ReleaseFiles $root)) {
        $relative = $file.FullName.Substring($root.Length + 1)
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}
