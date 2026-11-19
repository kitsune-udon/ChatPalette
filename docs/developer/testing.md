# 検証ガイド

[文書一覧](../index.md) · [開発・配布](guide.md)

## Zig版を検証する

### 試験環境を選ぶ

| 確かめること | 使う環境 |
|---|---|
| ロジック、保存、名前付きパイプ、ワーカーの故障と復旧 | 既定のヘッドレス `test-run` |
| 実ブラウザーでの挿入、Enter、停止、誤操作や二重送信の防止 | [オフラインのWindows Sandbox](#合成ブラウザー試験をsandboxで実行する)で実際のBraveと合成ページを使う |
| 依存ツールのないWindowsへの配布 | オフラインのWindows Sandboxで固定ZIPを展開する |
| アプリの起動・交替・終了、管理画面の操作とデータ移行 | 試験用Windowsの対話デスクトップで `startup` と `transfer` を実行する |
| 実YouTubeの通常ページ・別窓チャット、oEmbed、5種のリアクション表示 | [オンラインの試験用Windowsデスクトップ](#zig版で実ブラウザーを確認する)でBraveとFirefoxをそれぞれ新規プロファイルで動かす。必要なページやUI Automation要素を取得できれば、通信用に構成した専用VMも使える |
| 利用環境のIME、DPI、常駐アプリとのキー競合 | 該当する設定を備えたWindowsの対話デスクトップ。利用環境での再現が必要な場合は、そのホストを使う |
| 旧版と候補の初回応答時間 | 同じWindows、ブラウザーの版、プロファイル、ページとフォーカス位置で測る。試行ごとにワーカーを新規起動し、先に測る実装を交互に入れ替える |

合成ページの試験でも、WindowsのUI Automationと名前付きパイプを通して製品を操作します。Sandboxでは利用者のウィンドウからキー入力を隔離し、DOMのイベントから送信回数を確かめられます。ブラウザーごとに実測結果を記録します。初回応答の比較では、起動済みブラウザーに対し、ワーカー起動直前から最初の応答を受信し終えるまでを測ります。ゲストで測った時間にはゲストの構成を添え、同じゲスト内で比較します。[Windows Sandboxの構成](https://learn.microsoft.com/ja-jp/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) · [ワーカー試作時の計測条件](../../prototype/zig-worker/README.md#比較結果)

### 修正箇所に絞って検証する

`zig build check` は `-Dtest-case` で指定した登録済みの試験1群と、その前段のソース検査を実行します。ビルドするのは検証CLI、選んだ試験器、その試験器が使う場合の製品EXEです。ワーカーの通信を変えたときの例を示します。

```powershell
zig build check -Dtest-case=worker-lifecycle -Dtest-results=zig-out/check-worker-01
```

`-Dtest-results` には親フォルダーが存在する新規パスを指定します。試験名は `app-unit`、`brave-fixture`、`ime-input`、`shortcut-unit`、`startup`、`tools-unit`、`transfer`、`worker-lifecycle` です。`brave-fixture` は既定で[Sandbox](#合成ブラウザー試験をsandboxで実行する)に送り、`-Dbrave-exe` でゲストに搬入する `brave.exe` を指定します。`ime-input`、`startup`、`transfer` やホスト固有のBraveの問題を調べる場合は、`-Dtest-session=desktop` を付けて現在の対話デスクトップで実行します。ヘッドレスと対話デスクトップの結果は `result.json` と群別ログに残ります。別のビルドと並行する場合は `--prefix` も分けます。

### 全体を検証する

配布候補を固定する前に、Zigの単体試験、ソース検査、製品EXEの起動試験を実行します。合成データを用い、コマンドには毎回新しい出力先を指定します。

```powershell
zig build install tools test
$bin = '.\zig-out\bin'
& "$bin\chatpalette-tools.exe" source-check .
& "$bin\chatpalette-startup-test.exe" "$bin\ChatPalette.exe" .\dist\startup-check
```

登録済みのネイティブ試験を名前やセッションで選ぶ場合は、`zig build install tools test-artifacts` で実行ファイルを用意します。`test-run` の既定はヘッドレスです。次の例ではソース検査の後に、ヘッドレス群を独立した作業場所とJobで実行し、終了情報を保存します。

```powershell
& "$bin\chatpalette-tools.exe" test-list --session headless
& "$bin\chatpalette-tools.exe" test-run . $bin .\dist\native-test-check
```

`worker-lifecycle` は製品EXEと名前付きパイプを使い、起動障害、応答期限、ハンドル解放、再開を検査します。

対話デスクトップで個別に試す場合は `test-run . <bin> <新規出力先> --session desktop --name <試験名>` を使います。`ime-input` はMicrosoft日本語IMEの開閉、挿入した文字列、Enterの回数、試験前の状態への復帰を専用入力欄で記録します。`startup` は同じ製品EXEの起動・交替・終了を検査します。`transfer` は狭いパレットのTab移動と管理のスクロール、JSON書き出し・取込・自動バックアップからの復元を実画面で確認します。`brave-fixture` を対話デスクトップで実行するのは、ホスト固有の差を再現・調査するときです。

Braveのチャット欄と日本語IMEを組み合わせる試験は、対象のWindowsデスクトップで日本語入力を選択して実行します。試験器は専用プロファイルの合成ページでチャット欄の変換イベントを記録します。変換が始まること、製品のショートカットで挿入した文字列、挿入後に英字が直接入ること、Enterが0回であることを確認し、試験開始時の開閉状態へ戻します。

```powershell
& "$bin\chatpalette-browser-fixture.exe" "$bin\ChatPalette.exe" .\dist\brave-ime-check --ime-only
```

オフラインのWindows Sandboxでは、手元でビルドしたEXEを `sandbox <exe> <新規出力先>` で検証できます。配布する候補は `freeze` で固定し、そのZIPをクリーン環境と実ブラウザーで確認します。確認項目と実績は[移行計画](zig-migration.md)と[検証記録](zig-migration-evidence.md)を参照してください。

同じZIPのクリーン展開をSandboxで再現するときは、`sandbox-package <候補ZIP> <検証記録のArchiveSHA256> <chatpalette-clean-install-test.exe> <新規出力先>` を使います。ゲストの初回保存、診断、再起動、再読と終了に加え、動いたプロセスとロードしたDLLの記録を回収します。診断のコピーボタンをSandbox内で実行し、クリップボードと診断欄が一致すること、合成弾幕と展開先がコピーに含まれないことも確認します。

Windows Sandboxは同時に1セッションまでです。Zigランナーは `wsb.exe` で起動する前に試験専用IDを記録し、起動応答と照合します。ゲストの結果を回収した場合も、接続や結果の読み取りが失敗した場合も、一覧からそのIDだけを探して終了します。出力先の `session-cleanup.json` には終了結果とホスト側のエラーを記録します。起動時にセッションが残っている場合は `wsb list` で確認してください。`wsb.exe` がない環境では、試験用Sandboxの終了を手動で行います。

### 合成ブラウザー試験をSandboxで実行する

合成ページへのキー入力、誤入力の防止、リアクション回数の回帰試験には、オフラインのWindows Sandboxを使います。実際のBraveをゲスト内で起動し、試験のキー入力をホストの作業から隔離できます。`brave.exe` と該当バージョンのフォルダーが同じ場所にあるBraveを指定します。出力先は親フォルダーが存在する新規パスを指定します。

```powershell
$brave = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'
zig build check -Dtest-case=brave-fixture "-Dbrave-exe=$brave" -Dtest-results=zig-out/sandbox-browser-check
```

すでにビルドしたEXEを使う場合は `chatpalette-tools.exe sandbox-browser <ChatPalette.exe> <chatpalette-browser-fixture.exe> <brave.exe> <新規出力先>` を使います。

ネットワークとクリップボード共有を無効にしたSandboxを使用します。ゲストは読み取り専用の搬入先から試験に使うプログラムをゲスト内にコピーし、新しいBraveプロファイルと合成DBを作ります。実行には `wsb.exe` が必要です。試験専用IDで起動と終了を照合します。`results/browser-observations.json` に各試験の結果、`results/result.json` に実行結果とBraveの版、`ChatPalette.exe`、試験器、`brave.exe`、`chrome.dll` のSHA-256が入ります。終了結果は `session-cleanup.json` に残ります。`--prepare-only` は搬入物と設定を準備します。

ゲスト側の検証コマンド開始から試験器の起動まで、搬入時間を含めて35秒以上取ります。ログオン後の処理が試験中に前面へ出たためです。実際に待機した時間は `results/result.json` の `desktop_wait_ms` に残ります。試験中に前面が変わった場合は入力を中止し、取得できた場合は割り込んだプロセスの実行ファイル名を結果に残します。

### 旧版へ切り戻す

0.8.0との切り戻しを試すには、固定ZIPと隔離した旧版を実行できるAutoHotkey v2を用意します。実行中は試験用管理画面を操作するため、同じデスクトップでの入力試験を終えてから実行します。

```powershell
$legacyZip = '.\dist\baseline\ChatPalette-0.8.0.zip'
$legacyAhk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
& "$bin\chatpalette-rollback-test.exe" $legacyZip $legacyAhk "$bin\ChatPalette.exe" .\dist\rollback-check
```

結果の `result.json` で、旧ZIP・候補EXEのSHA-256、候補の管理画面で保存した変更、旧版から読み直した値、プロセスの終了を確認します。公開前はM5で凍結した候補のEXEを使って同じ検査を行います。

### Zig版で実ブラウザーを確認する

オンラインの試験用Windowsデスクトップで通常利用のプロファイルと分けます。対象のYouTube動画と入力可能なチャットを表示し、アドレス欄の編集を終えます。最初に対象のウィンドウでアドレス欄とページのUI要素を取得できるか確認します。取得できなければブラウザーの版・ページ種別・取得できた段階を記録し、同じ窓で旧版も照合します。一覧から対象のウィンドウを選び、`watch` または `popout` を指定して検査します。

```powershell
& "$bin\chatpalette-tools.exe" browser list
& "$bin\chatpalette-tools.exe" browser inspect 123456 watch .\dist\brave-watch.json
& "$bin\chatpalette-tools.exe" browser inspect 123456 watch .\dist\brave-watch-actions.json --exercise
```

`--exercise` は対象ウィンドウが前面にあるときに、チャット欄へフォーカスを移し、リアクションの表示起点にカーソルを置きます。送信回数は隔離した合成ページで検証します。レポートにはブラウザーの版、ページ種別、動画・チャット欄の検出結果、フォーカスとホバーの結果を記録します。

`Hover=hovered` が示すのはカーソルの移動です。凍結版の割当キーを使う実ライブ試験では、表示された5種のボタンと「送らずに確認」の結果を別に記録します。通常ページと別窓チャットをBraveとFirefoxで確認します。

### Zig版の性能を計測する

```powershell
& "$bin\chatpalette-tools.exe" benchmark load .\dist\bench-load 3 1000 10000 100000
& "$bin\chatpalette-tools.exe" benchmark storage .\dist\bench-storage 3 1000 10000 100000
& "$bin\chatpalette-tools.exe" benchmark startup .\dist\bench-startup 6 "$bin\ChatPalette.exe"
& "$bin\chatpalette-benchmark-ui.exe" .\dist\bench-ui 3 1000 10000 100000
```

保存はSQLiteの確定まで、起動は既存DBを使った `--smoke` のプロセス終了までを計測します。読み込み、初回表示、一覧の更新、再検索はそれぞれの値を記録します。各出力先の `measurements.json` に試行ごとの時間、中央値、最大値が入ります。0.8.0の保存計画単体と同期確定までの比較は計測範囲が異なります。[比較の検証記録](zig-migration-evidence.md)

## 0.8.0の比較基準

以下のコマンドとテストは、0.8.0タグから用意した隔離環境で比較を再現するために使います。自動テストはSQLite・アプリ・GUI部品を使い、ブラウザー操作、送信、ネットワーク取得には代替処理を使います。[0.8.0タグの検証ガイド](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/docs/developer/testing.md)

### 自動テストを実行する

隔離した0.8.0の作業コピーの直下から[共通ランナー](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/run.ps1)を使います。選択したテストの前に、ソース形式・PowerShell構文・モジュール境界・文書リンクを一度検査します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1 -List
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1 -Sandbox -Name test-sqlite.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& './tests/run.ps1' -Sandbox -Name test-input.ps1,test-page-actions.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1 -Sandbox
```

| 引数 | 選択・動作 |
|---|---|
| `-Group Headless`／`Desktop`／`All` | 各ファイル先頭の`Test-Session`で選ぶ。省略は全群 |
| `-Name` | 完全なファイル名を一つ以上指定。名前順に各群を一度実行 |
| `-List` | 選択名だけを表示。検査・一時コピー作成はしない |
| `-AutoHotkeyPath` | 実行ファイルを指定。省略時は`AHK_EXE`、次に標準インストール先 |
| `-Sandbox` | Sandboxへ隔離して結果を回収。起動失敗時にホストへ切り替えない |
| `-Sandbox -PrepareOnly` | 起動コピーと`.wsb`だけを作る |

未知引数・存在しないテスト・グループ外の名前・無効な実行ファイルを拒否します。別の対象へ切り替えません。HeadlessもWindows版AHK・SQLite・.NET/UIAを使い、一部は非表示のGUI部品を作ります。Desktopは入力可能なWindowsデスクトップが必要です。

各群はWindows PowerShell 5.1の別プロセスで実行します。`PSModulePath`は5.1の標準検索先を使い、呼出元の設定を復元します。成功条件は終了コード0、標準エラーなし、最後の`PASS`です。群は120秒でタイムアウトし、AHK側にも各検査の期限があります。

隔離コピーは`tests/.tmp/run-*`へ作り、利用者の`data/`を読み書きしません。成功群は次の群の前にコピーを削除し、失敗群は出力とコピーを保持します。直接実行せず、単体でもランナーの`-Name`を使ってください。

待機失敗時は、その検査のPIDと子孫を`taskkill /T /F`で終了します。終了確認とハンドル解放を行い、終了にも失敗した場合は両方のエラーを保持します。既に親から分離したプロセスや権限外のプロセスまで終了できる保証はありません。実行ファイル名で一括終了しません。

#### Windows Sandboxで実行する

対応エディションと仮想化が必要です。[Microsoftの導入手順](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-install)を確認し、初回は管理者PowerShellで有効化します。必要なら作業を保存して再起動します。

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart
```

ホストにAHK v2を用意し、既存のSandboxを閉じてから実行します。Sandbox内の画面は操作しません。Codexのコマンド隔離とWindows Sandboxは別の仕組みです。

ゲストへ渡すソースは読取専用、結果フォルダーは書込可能です。ネットワーク、クリップボード、音声・映像入力、プリンターを無効化します。ゲストの作業コピーは受渡直後と検査後にマニフェストで照合します。

表示された結果フォルダーの`result.json`、`stdout.txt`、`stderr.txt`、`artifacts/`を確認します。成功は`ExitCode=0`で、準備・実行・回収例外は`Error`に残ります。ホスト待機のタイムアウトはゲスト終了を意味しません。設定とログを保持し、別のSandboxを強制終了・自動再実行しません。再現にはランナーで新しいコピーを作ります。

Sandboxは成功時も自動で閉じません。終了を確認し、必要な証拠を保存してから自分の一時資料を削除してください。最小化・切断・ロック時の動作は個別に検証します。

### 変更とテストの対応

| 変更 | 主なテスト |
|---|---|
| DB・保存形式 | [sqlite](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-sqlite.ps1)、[storage](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-storage.ps1)、[integrity](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-settings-integrity.ps1)、[supported-formats](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-supported-formats.ps1) |
| JSON入出力・全件置換 | [user-data-transfer](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-user-data-transfer.ps1)、[app-settings](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-app-settings.ps1) |
| ライブラリ・履歴・公開 | [library-service](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-library-service.ps1)、[state-contracts](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-state-contracts.ps1)、[editor-commit](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-editor-commit.ps1) |
| キー・連続操作 | [shortcut-bindings](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-shortcut-bindings.ps1)、[shortcut-queue](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-shortcut-queue.ps1)、[page-hotkeys](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-page-hotkeys.ps1)、[chat-send](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-chat-send.ps1) |
| 入力対象・ページ操作 | [input](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-input.ps1)、[input-context](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-input-context.ps1)、[page-actions](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-page-actions.ps1)、[app-input-plan](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-app-input-plan.ps1) |
| リアクション・登録 | [quick-reaction](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-quick-reaction.ps1)、[reaction-start](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-reaction-start.ps1)、[reaction-results](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-reaction-results.ps1)、[registration-storage](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-registration-storage.ps1) |
| ワーカー・終了 | [worker-lifetime](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-worker-lifetime.ps1)、[app-worker](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-app-worker.ps1)、[worker-cleanup](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-worker-cleanup.ps1) |
| 画面・排他・編集 | [app-layout](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-app-layout.ps1)、[ui-transactions](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-ui-transactions.ps1)、[editor-lifecycle](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-editor-lifecycle.ps1)、[viewports](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-viewports.ps1)、[window-suspension](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-window-suspension.ps1) |
| 起動・配布・ランナー | [startup](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-startup.ps1)、[release](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-release.ps1)、[runner](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/test-runner.ps1) |

この表は入口です。`-List`と近隣テストで追加の影響範囲を確認します。保存契約・共通基盤・複数の境界を変える場合は範囲を広げます。

### 失敗したとき

最初のエラー、終了コード、スタック、保持したコピーを確認します。UTF-8の出力にはタイムアウト前のログも含まれます。前面失敗の`desktop`・`receives_input`・`foreground_owned`は観測値で、単独では原因を確定できません。同じデスクトップへの手操作と、ホストだけの操作を区別します。

原因を絞ってから必要な群を再実行します。成功した再実行だけで、以前の未特定失敗を解消済みにしません。[未特定の観測](complexity-results.md#原因未特定の失敗と追加した観測)を残してください。

### 回帰テストを追加する

ファイル先頭に`# Test-Session: Headless`または`Desktop`を付けます。支援・計測スクリプトに`test-`を付けません。故障の注入には通常の例外、期待結果には共有の`Assert`を使います。テストの`finally`と製品の終了処理を通し、失敗を捕捉して成功へ変えません。

#### テストの準備と観測

[support.ps1](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/support.ps1)の`New-TestRuntime`、`Invoke-AhkTest`、`Invoke-AppTest`、`Wait-TestProcess`を使います。[app-fixture.ps1](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/app-fixture.ps1)は合成設定とワーカーを用意します。[library-model.ahk](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/tests/fixtures/library-model.ahk)は下書きと設定のコピーを用意し、確定は製品の処理を使います。

通常の依存は`RuntimePorts`で差し替えます。描画は実際のコントロールとWindowsメッセージを観測します。共有Assertは失敗位置を記録し、製品のcatchで吸収されても成功にしません。テスト入口は未処理例外を記録して終了します。

#### 失敗・割り込み・資源解放の検証

通常操作で到達できない故障点だけ、`Edit-TestSource`で隔離コピーへ注入します。置換前の完全一致がなければ停止し、原本と製品用フックを変更しません。ロック・タイマー・表示失敗を使い、保存前の保全、保存後の公開、所有権復旧、再試行、実資源の解放を確認します。割り込みを禁止した実装に合わせて、テストから必要な割り込みまで消しません。

### 実画面で補う確認

新規弾幕の追加と再起動、チャンネル連携、タブ往復、選択復元、狭い画面・拡大表示、チャット・コメント・返信、登録と非送信確認、別フォルダーへの復元を確認します。実送信の検査では対象動画・種類・最大回数を事前に決めます。

### 実ブラウザーを確認する

対象の動画と入力可能なチャットを表示し、アドレス欄の編集を終えます。まず一覧からハンドルを選び、未使用の出力名で読み取り検査を実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-browser.ps1 -List
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-browser.ps1 -WindowHandle 123456 -PageKind Watch -OutputPath .\tests\.tmp\browser-watch.json
# 操作も確認する場合は、対象を最前面にして別の出力名を使う
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-browser.ps1 -WindowHandle 123456 -PageKind Watch -Exercise -OutputPath .\tests\.tmp\browser-actions.json
```

通常ページは`Watch`、別窓チャットは`Popout`です。省略時は自動判定します。`-List`は対象・出力・`-Exercise`と併用できません。親フォルダーを作成し、既存レポートを上書きしません。

終了コード0は動画・入力可能なチャット・表示起点の検出成功です。`-Exercise`ではフォーカスとホバーも含みます。文字入力・クリア・クリック・送信は行いません。レポートはタイトル・URL・入力値・例外本文を収録しません。

`ChatState`の`chat_missing`は入力可能な欄なし、`chat_ambiguous`は候補複数、`not-run`は未開始、`unknown`は開始後の結果不明です。`ChatDetected`は`ok`だけでtrueになります。`Error`の段階を確認し、`Focus`・`Hover`がunknownなら未実施とは判断しません。

#### 人間がリアクションUIの表示を確認する

`Hover=hovered`はマウス移動の成功です。`Display=not-verified`は自動では変更しません。人間が5種類のメニューを確認し、起動版・日時・ブラウザー・ページ種類・使用キー・見えた結果を別に記録します。送信の受理はこの検査の対象外です。

### 性能を計測する

| スクリプト | 計測範囲・既定値 |
|---|---|
| `tests/benchmark-storage.ps1` | 保存計画。1千・1万・10万件、反復7回。`-SourceRoot`で比較元を指定 |
| `tests/benchmark-load.ps1` | 画面・キー・ワーカーなしの読込と状態反映。1千・1万件、反復3回。`-SourceRoot`も指定可能 |
| `tests/benchmark-ui.ps1` | パレット・検索・管理一覧の更新。1千・1万件、反復3回 |

各スクリプトはウォームアップ後に中央値・最大値を出し、計測外で結果を照合します。読込とUIは`-Counts`（1〜100000）と`-Repeats`（1〜9）、保存計画は反復1回以上を指定できます。複数件数はPowerShell内で`& ./tests/benchmark-load.ps1 -Counts 1000,10000,100000`のように渡します。

保存計画にはSQL・DB書込・描画を含みません。読込は接続・ステートメント・OSキャッシュを再利用し、初回起動とは異なります。UIの`cold_initialize`は空DBと画面構築の1回の値で、プロセス起動を含みません。管理一覧更新は初回構築・DB保存を含まず、パレット描画は最大500件です。条件の異なる過去値を直接比較しません。

### 確認記録

版・日時・条件・結果・未検証範囲を[検証・計測の記録](complexity-results.md)へ残します。過去の成功を現在のソースや別ブラウザーへ適用しません。
