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

function Copy-ReleaseFiles([string]$Project, [string]$Destination) {
    $root = (Resolve-Path -LiteralPath $Project).Path
    foreach ($file in @(Get-ReleaseFiles $root)) {
        $relative = $file.FullName.Substring($root.Length + 1)
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}
