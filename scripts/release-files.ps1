function Get-ReleaseFiles([string]$project) {
    # Allowlist only. Never traverse data/, .git/, or test execution directories.
    $files = @(Get-ChildItem -LiteralPath $project -File | Where-Object { $_.Name -in 'main.ahk', 'README.md','LICENSE','VERSION','CHANGELOG.md','.gitignore','.gitattributes','.editorconfig' })
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'src') -Recurse -File | Where-Object { $_.Extension -in '.ahk','.ps1' })
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'docs') -Filter '*.md' -Recurse -File)
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'tests') -Filter '*.ps1' -File)
    $files += Get-Item -LiteralPath (Join-Path $project 'tests\fixtures\settings.ini')
    $files += Get-Item -LiteralPath (Join-Path $project 'tests\fixtures\ui-message-probe.ahk')
    $files += @(Get-ChildItem -LiteralPath (Join-Path $project 'scripts') -Filter '*.ps1' -File)
    return $files
}
