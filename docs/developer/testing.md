# 検証ガイド

## Zig版を検証する

以下の例は、リポジトリ直下のPowerShellで実行します。実行結果を保存するコマンドには、試験ごとに新しい出力先を指定します。[開発環境と初回ビルド](guide.md#作業を始める)

### 試験環境を選ぶ

| 変更・目的 | 試験と環境 |
|---|---|
| 本体のロジック・設定DB、キー割当、検証ツール | `app-unit`、`shortcut-unit`、`tools-unit`。3群まとめて実行するには `zig build test` |
| ワーカー通信、タイムアウト、故障後の再開 | `worker-lifecycle`。ヘッドレスで製品EXEと名前付きパイプを使う |
| 起動時の引き継ぎ・終了、管理画面でのデータ移行 | `startup`、`transfer`。試験用の対話デスクトップで実行する |
| 入力欄の識別、Enterやリアクションの操作回数 | `brave-fixture`。オフラインのWindows SandboxでBraveと合成ページを使う |
| 日本語IME、DPI、常駐アプリとのキー競合 | 対象の設定を備えた試験用デスクトップ。IMEの開閉・文字列・Enter回数は `ime-input` |
| 配布ZIPの初回起動、保存、再起動 | `sandbox-package`。開発ツールのないオフラインのWindows Sandboxで候補ZIPを展開する |
| 実YouTubeでの動画・チャットの判定、oEmbed、リアクションの表示 | 試験用プロファイルを用意したオンラインのWindows環境で、Brave・Firefoxの通常ページと別窓チャットを確認する |

`test-run` の「ヘッドレス」は、対話試験を明示的に選ばなくても実行できるグループです。`app-unit` の一部はWin32の画面と前面ウィンドウを使います。前面の切り替わりに関わる失敗は、該当のテスト名と直前のログを保存し、配布試験と同じWindows Sandboxでも確認できます。[配布試験の手順](guide.md#リリース手順)

### 修正箇所に絞って検証する

`zig build check` は検証CLI、選んだ試験器、その試験に必要な製品EXEをビルドし、ソース検査の後に指定の1群を実行します。

```powershell
zig build check -Dtest-case=worker-lifecycle -Dtest-results=zig-out/check-worker-01
```

`-Dtest-results` の親フォルダーは先に用意します。別のビルドと並行する場合は `--prefix` も分けます。対話デスクトップの試験には `-Dtest-session=desktop` を付けます。次の例では、試験中に専用の入力欄で日本語IMEを操作します。

```powershell
zig build check -Dtest-case=ime-input -Dtest-session=desktop -Dtest-results=zig-out/check-ime-01
```

`brave-fixture` は既定でWindows Sandboxを使います。ホスト固有の問題を調べる場合は、対象のデスクトップで `-Dtest-session=desktop` を指定します。[BraveのSandbox試験](#合成ブラウザー試験をsandboxで実行する)

### 全体を検証する

本体、検証ツール、単体試験のEXEをそろえてから、ヘッドレスの登録群をまとめて実行します。

```powershell
zig build install tools test-artifacts
$bin = '.\zig-out\bin'
& "$bin\chatpalette-tools.exe" test-list --session headless
& "$bin\chatpalette-tools.exe" test-run . $bin .\zig-out\check-headless-01
```

`result.json` に選択した試験、実行した試験、終了理由を記録します。先にソース検査を行い、最初の失敗で後続の群を止めます。原因を調べるときは、該当の群の `stderr.txt` と `stdout.txt` を確認してください。対象を絞って再実行するときは `--name <試験名>` を付けます。[登録試験の定義](../../tools/test_runner.zig)

起動・交替、次いで管理画面でのJSON入出力を確かめるには、試験用デスクトップで次を実行します。`transfer` では狭い画面での移動、インポート前の自動バックアップからの復元も調べます。

```powershell
& "$bin\chatpalette-tools.exe" test-run . $bin .\zig-out\check-desktop-01 --session desktop --name startup --name transfer
```

Braveのチャット欄と日本語IMEを組み合わせる場合は、日本語入力に切り替えた試験用デスクトップで次を実行します。専用プロファイルの合成ページで変換開始、弾幕入力、入力後の英字、Enterの回数、IMEの開閉状態の復帰を確認します。

```powershell
& "$bin\chatpalette-browser-fixture.exe" "$bin\ChatPalette.exe" .\zig-out\brave-ime-01 --ime-only
```

**配布候補を確認する場合**は `freeze` でソースとEXEを固定します。手元のEXEだけをSandboxで起動するには `chatpalette-tools.exe sandbox <exe> <新規出力先>` を使います。既定の引数は `--smoke` です。[候補の固定とハッシュの照合](guide.md#リリース手順)

固定ZIPのクリーン展開には `chatpalette-tools.exe sandbox-package <候補ZIP> <検証記録のArchiveSHA256> <chatpalette-clean-install-test.exe> <新規出力先>` を使います。初回保存、診断、再起動、保存値の再読、終了に加え、プロセスと読み込んだDLLを記録します。診断のコピー内容と表示が一致し、合成弾幕と展開先がコピーに含まれないことも調べます。

### 合成ブラウザー試験をSandboxで実行する

Windows Sandboxと `wsb.exe`、ホストにインストールしたBraveを使います。`brave.exe` の隣に、その版のランタイムフォルダーがあることを確認してください。

```powershell
$brave = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'
zig build check -Dtest-case=brave-fixture "-Dbrave-exe=$brave" -Dtest-results=zig-out/check-brave-01
```

ビルド済みのEXEを試す場合は `chatpalette-tools.exe sandbox-browser <ChatPalette.exe> <chatpalette-browser-fixture.exe> <brave.exe> <新規出力先>` を使います。末尾に `--prepare-only` を付けると搬入物と設定を作成します。

ゲストは読み取り専用の搬入先からEXEとBraveをコピーし、新しいプロファイルと合成DBを用意します。ネットワークとクリップボード共有を無効にし、UI Automationと製品の名前付きパイプを通して画面を操作します。送信回数は合成ページが受けたイベントから数えます。ログオン直後の別ウィンドウが試験に割り込むのを避けるため、搬入を含めて少なくとも35秒経ってから試験器を起動します。

| 出力先にあるファイル | 確認できること |
|---|---|
| `results/browser-observations.json` | シナリオごとの観測と合否。前面が変わって中止した場合は、取得できた範囲で割り込んだプロセスも記録 |
| `results/result.json` | 終了結果、Braveの版、本体・試験器・Brave・`chrome.dll` のSHA-256、搬入後の追加待機時間 `desktop_wait_ms` |
| `results/audio.json` | ゲストでミュートした音声出力。ランナーはミュート状態を確認してから試験を開始 |
| `session-cleanup.json` | ランナーが起動したセッションのID、終了結果、ホスト側のエラー |

Sandboxの試験は一度に1セッションだけ実行します。使用中なら `wsb list` で確認します。`wsb.exe` を使うランナーは成功・失敗のどちらでも自分が起動したIDを照合して終了します。通常の `sandbox` コマンドを `wsb.exe` のない環境で実行した場合は、試験用セッションを手動で閉じます。[Windows Sandboxの構成](https://learn.microsoft.com/ja-jp/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)

### 旧版へ切り戻す

0.8.0の固定ZIPと、隔離した旧版を起動するためのAutoHotkey v2を用意します。ほかの入力試験を止め、試験用デスクトップで旧版から候補へ、候補から旧版へとデータを引き継ぎます。

```powershell
$bin = '.\zig-out\bin'
$legacyZip = Join-Path $env:TEMP 'ChatPalette-0.8.0.zip'
Invoke-WebRequest 'https://github.com/kitsune-udon/ChatPalette/releases/download/v0.8.0/ChatPalette-0.8.0.zip' -OutFile $legacyZip
if ((Get-FileHash -LiteralPath $legacyZip).Hash -ine '7e071f90a371964fe8cdf244d4730eaae9473430caad2392024dded5afd56b19') {
    throw '0.8.0 ZIPのSHA-256が一致しません'
}
$legacyAhk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
& "$bin\chatpalette-rollback-test.exe" $legacyZip $legacyAhk "$bin\ChatPalette.exe" .\zig-out\rollback-01
```

`result.json` で旧ZIP・候補EXEのSHA-256、候補の管理画面で保存した変更、旧版で読み直した値、プロセスの終了を確認します。配布候補の試験では、上の例の `ChatPalette.exe` に候補ZIPから展開したEXEを指定します。

### Zig版で実ブラウザーを確認する

オンラインの試験用デスクトップで、テスト用のプロファイルにYouTube動画と入力可能なチャットを表示します。アドレス欄の編集を終えたら `browser list` でウィンドウを一覧し、例の `123456` を対象の `WindowHandle` に置き換えます。通常ページには `watch`、別窓チャットには `popout` を使います。最後のコマンドを実行したら、5秒の待ち時間に対象のブラウザーへ戻ってください。

```powershell
$bin = '.\zig-out\bin'
& "$bin\chatpalette-tools.exe" browser list
& "$bin\chatpalette-tools.exe" browser inspect 123456 watch .\zig-out\brave-watch.json
& {
    Start-Sleep -Seconds 5
    & "$bin\chatpalette-tools.exe" browser inspect 123456 watch .\zig-out\brave-watch-actions.json --exercise
}
```

レポートにはブラウザーの版、ページの種類、動画とチャット欄の検出結果が入ります。`--exercise` を使うと、対象が最前面のときにチャット欄へフォーカスを移し、リアクションの表示起点へカーソルを移動します。`Hover=hovered` は移動の結果です。実ライブでは5種類のボタンが実際に表示されたかと「送らずに確認」の結果を、BraveとFirefoxの通常ページ・別窓でそれぞれ記録します。UI要素を取得できない場合はブラウザーの版と取得できた段階を記録し、必要に応じて同じウィンドウで旧版とも照合します。

### Zig版の性能を計測する

```powershell
$bin = '.\zig-out\bin'
& "$bin\chatpalette-tools.exe" benchmark load .\zig-out\bench-load 3 1000 10000 100000
& "$bin\chatpalette-tools.exe" benchmark storage .\zig-out\bench-storage 3 1000 10000 100000
& "$bin\chatpalette-tools.exe" benchmark startup .\zig-out\bench-startup 6 "$bin\ChatPalette.exe"
& "$bin\chatpalette-benchmark-ui.exe" .\zig-out\bench-ui 3 1000 10000 100000
```

各出力先の `measurements.json` に試行ごとの時間、中央値、最大値が入ります。`storage` はSQLiteの確定まで、`startup` は既存DBを使って `--smoke` が終了するまでを測ります。画面では初回表示、一覧更新、再検索を別々に記録します。過去の結果と比較するときは同じデータと計測範囲を使います。初回と後続のワーカー応答の測り方は比較手順にあります。[旧版との比較手順](worker-comparison.md) · [移行時の計測条件](../history/zig-migration-evidence.md#候補を比較する計測条件)

## 0.8.0の比較基準

旧版との比較にはv0.8.0の配布ZIPを別フォルダーに展開します。当時の57群を再実行する場合は、同じタグの作業コピーでその版の手順を使ってください。[0.8.0の配布物](https://github.com/kitsune-udon/ChatPalette/releases/tag/v0.8.0) · [0.8.0の検証ガイド](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/docs/developer/testing.md) · [57群とZig版の試験の対応](../history/zig-migration-evidence.md#080の57群との照合)
