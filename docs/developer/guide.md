# 開発・配布手順

## 作業を始める

Windows 11 x64でGitとWindows x86_64版のZig 0.15.2を用意します。ビルド先は `x86_64-windows-gnu`、既定の最適化は `ReleaseSafe` です。アプリはWindows標準のSQLiteとUI Automationを使います。

リポジトリ直下のPowerShellで次を実行します。

```powershell
zig version
zig build install tools
.\zig-out\bin\chatpalette-tools.exe source-check .
```

バージョンが `0.15.2`、ソース検査の結果が `PASS` であることを確認します。本体は `zig-out/bin/ChatPalette.exe`、検証CLIと試験用EXEは同じ `bin/` にできます。別の出力先へビルドするには `--prefix` を指定します。

### 既存の設定で開発ビルドを起動する

リポジトリ直下の `ChatPalette.exe` を起動すると、その隣にある `data/settings.db` を読み込みます。起動中のChatPaletteを終了してから、リポジトリ直下のPowerShellで実行します。

~~~powershell
zig build install
if ($LASTEXITCODE -ne 0) { throw '本体のビルドに失敗しました' }
Copy-Item -LiteralPath .\zig-out\bin\ChatPalette.exe -Destination .\ChatPalette.exe -Force
.\ChatPalette.exe
~~~

再ビルドで更新されるのは `zig-out/bin/ChatPalette.exe` です。**再ビルドするたびに、起動中のアプリを終了して生成したEXEを直下へコピーし直してください。**

独立した開発用データで試す場合は `.\zig-out\bin\ChatPalette.exe` を直接起動します。この場合は `zig-out/bin/data/settings.db` を使います。同じWindowsセッションで、本体を常駐できるのは1つです。同じフォルダーから通常起動すると既存の画面を呼び出します。`--quiet` はパレットを閉じたまま常駐し、同じフォルダーで稼働中なら画面を変えずに終了します。別のフォルダーに切り替える場合は稼働中の本体を終了してください。

`--smoke` は設定の読み込みと画面の初期化を確認して終了します。本体が稼働中なら、同じフォルダーでは `InstanceAlreadyRunning`、別フォルダーでは `OtherInstanceAlreadyRunning` と終了コード1を返します。セッション単位の排他に対応していない旧版と比較する場合も、先に稼働中の本体を終了してください。

## 変更箇所を選ぶ

| 変更したい箇所 | 最初に読む場所 |
|---|---|
| 起動モード、本体とワーカーの振り分け | [src/main.zig](../../src/main.zig) |
| 画面、常駐、キーボード入力 | [src/desktop/](../../src/desktop) |
| キー割当の共通定義 | [src/domain/shortcuts.zig](../../src/domain/shortcuts.zig) |
| 弾幕、配信者、設定DB、JSON入出力 | [src/storage/](../../src/storage) |
| 動画・入力欄の判定、リアクション | [src/worker/](../../src/worker) |
| 本体とワーカーの通信 | [worker_client.zig](../../src/desktop/worker_client.zig) |
| ビルド、検査、配布 | [build.zig](../../build.zig)、[tools/](../../tools) |
| 統合試験と試験用ブラウザーページ | [tests/integration/](../../tests/integration) |

単体試験は対象のZigモジュール内にあります。画面とワーカーにまたがる変更では、操作先をどこで確かめ、どの時点で保存するかを確認してください。[設計と状態の所有](architecture.md)

## テストを実行する

`zig build test` は本体、キー割当、検証ツールの単体試験を実行します。製品EXEを介した試験は `zig build check` で選べます。たとえばワーカー通信を変えた場合は、製品と試験器をビルドしてワーカーを再起動できるところまで確かめます。

```powershell
zig build check -Dtest-case=worker-lifecycle -Dtest-results=zig-out/check-worker-01
```

結果は新しいフォルダーへ書き出します。再実行するときは末尾の番号を変えてください。試験名、実機とSandboxの使い分け、失敗時に確認するログは検証ガイドにあります。[検証ガイド](testing.md#試験環境を選ぶ)

## 文字コードとGit

Zig、Markdown、JSON、Git設定、`LICENSE`、`VERSION` はUTF-8（BOMなし）・LFで保存します。編集には `.editorconfig` と `.gitattributes` の設定を使います。

`zig-out/` と `.zig-cache/` はビルド出力、`dist/` は候補と検証記録です。これらと利用者の `data/` はGitの対象外です。試験には合成データを使います。

## リリース手順

1. 候補のコミットをクリーンな作業コピーで開き、`VERSION` の版番号と `CHANGELOG.md` の変更内容を確認します。`freeze` でゲストの試験まで実行するには、Windows Sandboxと `wsb.exe` が必要です。`wsb list` で稼働中のセッションが0件であることを確認します。
2. 次のコマンドで候補を固定します。`$zig` にはWindows x86_64版Zig 0.15.2の `zig.exe` 本体を指定します。`freeze` はバージョンと実行ファイルのSHA-256を検査します。

```powershell
$zig = (Get-Command zig.exe).Source
$version = (Get-Content -Raw VERSION).Trim()
$candidate = ".\dist\candidate-$version"
& $zig build tools
if ($LASTEXITCODE -ne 0) { throw '検証ツールのビルドに失敗しました。' }
.\zig-out\bin\chatpalette-tools.exe freeze . $zig $candidate
```

3. `freeze` が終了コード0を返したら、候補フォルダーの `ChatPalette-<版>.zip` と `ChatPalette-<版>.validation.json` を確認します。後者の `ArchiveSHA256` がZIPのハッシュです。`evidence/` には試験結果とログが入ります。
4. 同じZIPを使ってクリーン展開、実ブラウザーでの動作、更新と切り戻しを確かめます。公開直前にZIPのハッシュをもう一度照合し、公開後はタグのコミットとReleaseの添付名・サイズ・SHA-256を照合します。タグの公開後に添付だけ失敗した場合は、同じ版へ不足分を添付します。[環境ごとの検証手順](testing.md#全体を検証する)

`freeze` はビルド入力を作業コピーから採取し、そのコピーだけで本体と試験器を再ビルドします。キー割当とツールの単体試験はホストで、本体の単体試験、起動、ワーカーの故障と復旧、スモーク試験は消音したWindows Sandboxで実行します。ランナーは自分が起動したセッションIDを照合して終了します。既存の出力先は上書きしません。

`freeze` の末尾に `--prepare-only` を付けると、ホスト試験とSandboxの準備まで進み、作業記録の場所を出力します。梱包だけを予行する `release` は `.rehearsal.json` を作成します。

### 配布物の範囲

| 確認するもの | 内容 |
|---|---|
| `SOURCE-SHA256SUMS` | `build.zig`、任意の `build.zig.zon`、`src/`・`tools/`・`tests/integration/` のZigファイル、同梱する文書などのハッシュ |
| `ChatPalette-<版>.zip` | `ChatPalette.exe`、`README.md`、`VERSION`、`CHANGELOG.md`、`LICENSE`、`docs/user/` の利用ガイド、`SHA256SUMS` |
| `SHA256SUMS` | ZIPに収めたEXEと文書などのハッシュ。候補フォルダーにも同じマニフェストがある |

`chatpalette-tools.exe verify <候補ZIP> <候補フォルダーのSHA256SUMS>` は中身を照合し、ZIP全体のSHA-256を返します。配布対象の追加・削除は許可リストに反映してください。公開する添付に個人データやローカルの作業パスが入っていないことも確認します。[配布対象の定義](../../tools/release.zig)

### 公開版0.9.0を照合する

リポジトリルートで実行し、固定タグの配布ZIPと検証JSONを取得します。検証JSONとZIP内の配布マニフェストをSHA-256で照合してから、検証CLIでZIPの中身を確認します。[公開版0.9.0](https://github.com/kitsune-udon/ChatPalette/releases/tag/v0.9.0)

~~~powershell
zig build tools
if ($LASTEXITCODE -ne 0) { throw '検証CLIのビルドに失敗しました' }
$work = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('ChatPalette-verify-' + [guid]::NewGuid()))
$zip = Join-Path $work.FullName 'ChatPalette-0.9.0.zip'
$validation = Join-Path $work.FullName 'ChatPalette-0.9.0.validation.json'
$download = 'https://github.com/kitsune-udon/ChatPalette/releases/download/v0.9.0'
Invoke-WebRequest "$download/ChatPalette-0.9.0.validation.json" -OutFile $validation
if ((Get-FileHash -LiteralPath $validation).Hash -ine 'a819680a481e1eceeeafe35ad284648140b02e1fb1c3ed66bf9c03ad3b5772cf') {
    throw '検証JSONのSHA-256が一致しません'
}
$expected = Get-Content -Raw -LiteralPath $validation | ConvertFrom-Json
Invoke-WebRequest "$download/ChatPalette-0.9.0.zip" -OutFile $zip
if ((Get-FileHash -LiteralPath $zip).Hash -ine $expected.ArchiveSHA256) { throw 'ZIPのSHA-256が一致しません' }
tar -xf $zip -C $work.FullName SHA256SUMS
if ($LASTEXITCODE -ne 0) { throw '配布マニフェストの展開に失敗しました' }
$manifest = Join-Path $work.FullName 'SHA256SUMS'
if ((Get-FileHash -LiteralPath $manifest).Hash -ine $expected.ArchiveManifestSHA256) {
    throw '配布マニフェストのSHA-256が一致しません'
}
.\zig-out\bin\chatpalette-tools.exe verify $zip $manifest
if ($LASTEXITCODE -ne 0) { throw 'ZIPの検証に失敗しました' }
~~~

固定時のソースマニフェストを再生成するには、同じPowerShellで以下を実行します。公開コミットで使っていた対象（native配下のZigファイル、ビルド設定、配布文書）をパス順に並べ、小文字SHA-256とCRLFで記録します。

~~~powershell
$source = Join-Path $work.FullName 'source'
git -c core.autocrlf=false clone --quiet --depth 1 --branch v0.9.0 https://github.com/kitsune-udon/ChatPalette.git $source
if ($LASTEXITCODE -ne 0) { throw '公開タグの取得に失敗しました' }
if ((git -C $source rev-parse HEAD) -ne '528a05ebdfa22990bc14f718c3fa5a39ea830d9d') {
    throw '公開コミットが一致しません'
}
$paths = [Collections.Generic.List[string]]::new()
$paths.AddRange([string[]]@(
    'build.zig', 'CHANGELOG.md', 'LICENSE', 'README.md', 'VERSION',
    'docs/user/guide.md', 'docs/user/maintenance.md', 'docs/user/reactions.md', 'docs/user/reference.md'
))
if (Test-Path -LiteralPath (Join-Path $source 'build.zig.zon') -PathType Leaf) { $paths.Add('build.zig.zon') }
Get-ChildItem -LiteralPath (Join-Path $source 'native') -File -Recurse -Force | Where-Object Extension -ceq '.zig' | ForEach-Object {
    $paths.Add($_.FullName.Substring($source.Length + 1).Replace('\', '/'))
}
$paths.Sort([StringComparer]::Ordinal)
$lines = foreach ($path in $paths) {
    (Get-FileHash -LiteralPath (Join-Path $source $path)).Hash.ToLowerInvariant() + '  ' + $path
}
$sourceManifest = Join-Path $work.FullName 'SOURCE-SHA256SUMS'
[IO.File]::WriteAllText($sourceManifest, ($lines -join ([string][char]13 + [char]10)) + [char]13 + [char]10)
if ((Get-FileHash -LiteralPath $sourceManifest).Hash -ine $expected.SourceManifestSHA256) {
    throw 'ソースマニフェストのSHA-256が一致しません'
}
~~~

公開時の試験経緯は移行記録を参照してください。[移行記録](../history/zig-migration-evidence.md)

## 文書を更新する規則

操作は利用者ガイド、初期値と上限はリファレンス、復旧は保守手順、内部の状態とデータ形式は設計書に記載します。同じ手順が別の場所でも必要なら、説明を持つページへリンクします。[文書一覧](../index.md)

UIラベルと操作順を実装に照らし、相対リンクと見出しを確認します。配布文書を変えたら `chatpalette-tools.exe source-check .` でZIP内の参照先も検査します。開発文書と履歴のリンクはリポジトリ内で確認します。公開済みの変更履歴から旧版の手順を案内するときは、その版の固定タグへリンクします。最後に `git diff --check` と `git status --short` で差分を確認します。
