# 検証ガイド

## Zig版を検証する

以下の例は、リポジトリ直下のPowerShellで実行します。実行結果を保存するコマンドには、試験ごとに新しい出力先を指定します。[開発環境と初回ビルド](guide.md#作業を始める)

### 試験環境を選ぶ

| 変更・目的 | 試験と環境 |
|---|---|
| 本体のロジック・設定DB、キー割当、検証ツール | `app-unit`、`shortcut-unit`、`tools-unit`。3群まとめて実行するには `zig build test` |
| ワーカー通信、タイムアウト、故障後の再開 | [`worker-lifecycle` の実行例](#修正箇所に絞って検証する)。ヘッドレスで製品EXEと名前付きパイプを使う |
| 二重起動時の画面表示、別フォルダーからの起動拒否、再起動 | [`startup` の実行例](#起動とデータ移行を確認する)。試験用の対話デスクトップを使う |
| 管理画面でのJSON入出力、取込後の復元 | [`transfer` の実行例](#起動とデータ移行を確認する)。試験用の対話デスクトップを使う |
| 公開版からの更新、保存と再起動、バックアップからの切り戻し | [`upgrade-rollback`](#zig版の更新と切り戻しを確認する)。公開版と候補のZIPを使い、試験用の対話デスクトップで実行する |
| 入力欄の識別、Enterやリアクションの操作回数 | [`browser-fixture` の実行例](#合成ブラウザー試験をsandboxで実行する)。オフラインのWindows Sandboxで対応するChromium系ブラウザーと合成ページを使う |
| 日本語IME、DPI、常駐アプリとのキー競合 | 対象の設定を備えた試験用デスクトップ。IMEの開閉・文字列・Enter回数は `ime-input` |
| 配布ZIPの初回起動、保存、再起動 | `sandbox-package`。開発ツールのないオフラインのWindows Sandboxで候補ZIPを展開する |
| 実YouTubeでの動画・チャットの判定、oEmbed、リアクションの表示 | 試験用プロファイルを用意したオンラインのWindows環境で、対象ブラウザーの通常ページと別窓チャットを確認する |

`test-run` の「ヘッドレス」は、対話試験を明示的に選ばなくても実行できるグループです。`app-unit` の一部はWin32の画面と前面ウィンドウを使います。前面の切り替わりに関わる失敗は、該当のテスト名と直前のログを保存し、配布試験と同じWindows Sandboxでも確認できます。[配布試験の手順](guide.md#リリース手順)

## PRのWindows CI

`main` 向けのPRと `main` への反映時に、GitHub ActionsでWindows CIが実行されます。PRの **Checks** タブで、ビルド・ソース検査・単体試験の結果とログを確認できます。Windows上で同じ検査を実行するコマンドは次のとおりです。

```powershell
zig build install tools --summary all
.\zig-out\bin\chatpalette-tools.exe source-check .
zig build test-shortcuts --summary all
zig build test-tools --summary all
zig build test-app-headless --summary all
```

本体のうち、Win32のウィンドウを作成したり入力フックを試したりする単体試験は、対話可能なWindowsデスクトップから `zig build test-app-desktop --summary all` で実行します。`test-app-headless` の集計では、これらの試験がスキップとして表示されます。すべての単体試験を一度に実行するには、対話デスクトップから `zig build test --summary all` を使います。

対話デスクトップを使う試験を追加する場合は、試験名を `desktop: ` で始め、冒頭で `requireDesktop()` を呼び出します。

配信者情報の取得試験は、本体の非対話単体試験に含まれます。ローカルHTTPサーバーが応答本文を少しずつ送り、全体の期限でWinHTTP要求を取り消せることと、次の取得が成功することを確認します。

### 修正箇所に絞って検証する

`zig build check` は検証CLI、選んだ試験器、その試験に必要な製品EXEをビルドし、ソース検査の後に指定の1群を実行します。

```powershell
zig build check -Dtest-case=worker-lifecycle -Dtest-results=zig-out/check-worker-01
```

終了コードが0で、指定先の `result.json` の `passed` が `true` なら合格です。失敗した場合は同じファイルで止まった試験を確認し、その試験の `stderr.txt` と `stdout.txt` を開きます。`result.json` が生成されていなければ、PowerShellに表示されたビルドや引数のエラーを確認します。

`-Dtest-results` の親フォルダーは先に用意します。別のビルドと並行する場合は `--prefix` も分けます。対話デスクトップの試験には `-Dtest-session=desktop` を付けます。次の例では、試験中に専用の入力欄で日本語IMEを操作します。

```powershell
zig build check -Dtest-case=ime-input -Dtest-session=desktop -Dtest-results=zig-out/check-ime-01
```

`browser-fixture` は既定でWindows Sandboxを使います。ホスト固有の問題を調べる場合は、対象のデスクトップで `-Dtest-session=desktop` を指定します。どちらの環境でも `-Dbrowser-exe` でブラウザーを選べます。デスクトップで省略した場合は標準のインストール先をChrome、Edge、Braveの順に探します。旧名の `brave-fixture` と `-Dbrave-exe` も指定でき、試験名は結果に `browser-fixture` と記録されます。[合成ブラウザーのSandbox試験](#合成ブラウザー試験をsandboxで実行する)

### 全体を検証する

本体、検証ツール、単体試験のEXEをそろえてから、ヘッドレスの登録群をまとめて実行します。

```powershell
zig build install tools test-artifacts
$bin = '.\zig-out\bin'
& "$bin\chatpalette-tools.exe" test-list --session headless
& "$bin\chatpalette-tools.exe" test-run . $bin .\zig-out\check-headless-01
```

`result.json` に選択した試験、実行した試験、終了理由を記録します。先にソース検査を行い、最初の失敗で後続の群を止めます。原因を調べるときは、該当の群の `stderr.txt` と `stdout.txt` を確認してください。対象を絞って再実行するときは `--name <試験名>` を付けます。`zig build check` と検証CLIは同じ試験一覧を参照します。[登録試験の定義](../../tools/test_registry.zig)

### 起動とデータ移行を確認する

稼働中のChatPaletteを終了し、試験用デスクトップで次を実行します。`transfer` では狭い画面での移動と、インポート前の自動バックアップからの復元も調べます。結果は指定先の `result.json` で確認します。

```powershell
& "$bin\chatpalette-tools.exe" test-run . $bin .\zig-out\check-desktop-01 --session desktop --name startup --name transfer
```

合成ページのチャット欄と日本語IMEを組み合わせる場合は、日本語入力に切り替えた試験用デスクトップで次を実行します。専用プロファイルの合成ページで変換開始、弾幕入力、入力後の英字、Enterの回数、IMEの開閉状態の復帰を確認します。

```powershell
$browser = Read-Host '試験するブラウザーEXEの絶対パス'
& "$bin\chatpalette-browser-fixture.exe" "$bin\ChatPalette.exe" .\zig-out\browser-ime-01 $browser --ime-only
```

**配布候補を確認する場合**は `freeze` でソースとEXEを固定します。手元のEXEだけをSandboxで起動するには `chatpalette-tools.exe sandbox <exe> <新規出力先>` を使います。既定の引数は `--smoke` です。[候補の固定とハッシュの照合](guide.md#リリース手順)

固定ZIPのクリーン展開には `chatpalette-tools.exe sandbox-package <候補ZIP> <検証記録のArchiveSHA256> <chatpalette-clean-install-test.exe> <新規出力先>` を使います。初回保存、診断、再起動、保存値の再読、終了に加え、プロセスと読み込んだDLLを記録します。診断のコピー内容と表示が一致し、合成弾幕と展開先がコピーに含まれないことも調べます。

### 合成ブラウザー試験をSandboxで実行する

Windows Sandboxと `wsb.exe`、ホストにインストールしたChrome・Edge・Braveのいずれかを使います。合成試験はChromiumのCDPを使います。製品が識別するブラウザーの一覧は[必要な環境](../../README.md#必要な環境)を参照してください。Sandboxへ搬入するには、指定したEXEの隣に、その版のランタイムフォルダーが必要です。

```powershell
$browser = Read-Host '試験するブラウザーEXEの絶対パス'
zig build check -Dtest-case=browser-fixture "-Dbrowser-exe=$browser" -Dtest-results=zig-out/check-browser-01
```

ビルド済みのEXEを試す場合は `chatpalette-tools.exe sandbox-browser <ChatPalette.exe> <chatpalette-browser-fixture.exe> <ブラウザーEXE> <新規出力先>` を使います。末尾に `--prepare-only` を付けると搬入物と設定を作成します。

ゲストは読み取り専用の搬入先から本体・試験器・選択したブラウザーをコピーし、新しいプロファイルと合成DBを用意します。ネットワークとクリップボード共有を無効にし、UI Automationと製品の名前付きパイプを通して画面を操作します。送信回数は合成ページが受けたイベントから数えます。ログオン直後の別ウィンドウが試験に割り込むのを避けるため、搬入を含めて少なくとも35秒経ってから試験器を起動します。

| 出力先にあるファイル | 確認できること |
|---|---|
| `results/browser-observations.json` | シナリオごとの観測と合否。前面が変わって中止した場合は、取得できた範囲で割り込んだプロセスも記録 |
| `results/result.json` | 終了結果、ブラウザーの種類と版、本体・試験器・ブラウザーEXE・ランタイムDLLのSHA-256、搬入後の追加待機時間 `desktop_wait_ms` |
| `results/audio.json` | ゲストでミュートした音声出力。ランナーはミュート状態を確認してから試験を開始 |
| `session-cleanup.json` | ランナーが起動したセッションのID、終了結果、ホスト側のエラー |

Sandboxの試験は一度に1セッションだけ実行します。使用中なら `wsb list` で確認します。`wsb.exe` を使うランナーは成功・失敗のどちらでも自分が起動したIDを照合して終了します。通常の `sandbox` コマンドを `wsb.exe` のない環境で実行した場合は、試験用セッションを手動で閉じます。[Windows Sandboxの構成](https://learn.microsoft.com/ja-jp/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)

### Zig版の更新と切り戻しを確認する

稼働中のChatPaletteを終了し、試験用の対話デスクトップで実行します。公開版と候補のZIPを用意し、それぞれのZIPの隣に、同じ名前で末尾を `.validation.json` に置き換えた検証JSONを置きます。試験は検証JSONのSHA-256でZIPを照合し、出力フォルダー内だけに展開します。

```powershell
zig build tools
$baseline = '.\dist\baseline\ChatPalette-0.9.1.zip'
$version = (Get-Content -Raw VERSION).Trim()
$candidate = ".\dist\candidate-$version\ChatPalette-$version.zip"
.\zig-out\bin\chatpalette-tools.exe upgrade-rollback $baseline $candidate .\zig-out\upgrade-rollback-01 --session desktop
```

公開版の画面で共通弾幕・配信者・配信者別の弾幕とショートカットを登録します。公開版を終了して実行ファイルと `data/` をバックアップし、`data/` のコピーで候補を起動します。候補で変更を保存して再起動後に読み込み、最後にバックアップから復元した公開版で更新前の値を確認します。候補の保存データとバックアップもSHA-256で照合します。

出力フォルダーの `result.json` が全体の合否、`scenario/result.json` が版・ハッシュ・各起動の結果と失敗箇所です。正常終了時は展開先と合成DBを削除します。失敗時は `scenario/work/` に残った展開物とログを確認できます。

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
& "$bin\chatpalette-tools.exe" browser inspect 123456 watch .\zig-out\browser-watch.json
& {
    Start-Sleep -Seconds 5
    & "$bin\chatpalette-tools.exe" browser inspect 123456 watch .\zig-out\browser-watch-actions.json --exercise
}
```

レポートにはブラウザーの版、ページの種類、動画とチャット欄の検出結果が入ります。`--exercise` を使うと、対象が最前面のときにチャット欄へフォーカスを移し、リアクションの表示起点へカーソルを移動します。`Hover=hovered` は移動の結果です。実ライブでは5種類のボタンが実際に表示されたかと「送らずに確認」の結果を、対象ブラウザーの通常ページ・別窓でそれぞれ記録します。UI要素を取得できない場合はブラウザーの版と取得できた段階を記録し、必要に応じて同じウィンドウで旧版とも照合します。

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
