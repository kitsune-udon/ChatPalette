# 検証ガイド

[文書一覧](../index.md) · [開発・配布](guide.md)

変更範囲に合わせて検査を選びます。自動テストは実際のSQLite・アプリ・GUI部品を使いますが、ブラウザー操作・送信・ネットワーク取得は代替処理です。実ブラウザーとYouTube側の受理を確認した結果ではありません。

## 自動テストを実行する

リポジトリ直下から[共通ランナー](../../tests/run.ps1)を使います。選択したテストの前に、ソース形式・PowerShell構文・モジュール境界・文書リンクを一度検査します。

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

### Windows Sandboxで実行する

対応エディションと仮想化が必要です。[Microsoftの導入手順](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-install)を確認し、初回は管理者PowerShellで有効化します。必要なら作業を保存して再起動します。

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart
```

ホストにAHK v2を用意し、既存のSandboxを閉じてから実行します。Sandbox内の画面は操作しません。Codexのコマンド隔離とWindows Sandboxは別の仕組みです。

ゲストへ渡すソースは読取専用、結果フォルダーは書込可能です。ネットワーク、クリップボード、音声・映像入力、プリンターを無効化します。ゲストの作業コピーは受渡直後と検査後にマニフェストで照合します。

表示された結果フォルダーの`result.json`、`stdout.txt`、`stderr.txt`、`artifacts/`を確認します。成功は`ExitCode=0`で、準備・実行・回収例外は`Error`に残ります。ホスト待機のタイムアウトはゲスト終了を意味しません。設定とログを保持し、別のSandboxを強制終了・自動再実行しません。再現にはランナーで新しいコピーを作ります。

Sandboxは成功時も自動で閉じません。終了を確認し、必要な証拠を保存してから自分の一時資料を削除してください。最小化・切断・ロック時の動作は個別に検証します。

## 変更とテストの対応

| 変更 | 主なテスト |
|---|---|
| DB・保存形式 | [sqlite](../../tests/test-sqlite.ps1)、[storage](../../tests/test-storage.ps1)、[integrity](../../tests/test-settings-integrity.ps1)、[supported-formats](../../tests/test-supported-formats.ps1) |
| JSON入出力・全件置換 | [user-data-transfer](../../tests/test-user-data-transfer.ps1)、[app-settings](../../tests/test-app-settings.ps1) |
| ライブラリ・履歴・公開 | [library-service](../../tests/test-library-service.ps1)、[state-contracts](../../tests/test-state-contracts.ps1)、[editor-commit](../../tests/test-editor-commit.ps1) |
| キー・連続操作 | [shortcut-bindings](../../tests/test-shortcut-bindings.ps1)、[shortcut-queue](../../tests/test-shortcut-queue.ps1)、[page-hotkeys](../../tests/test-page-hotkeys.ps1)、[chat-send](../../tests/test-chat-send.ps1) |
| 入力対象・ページ操作 | [input](../../tests/test-input.ps1)、[input-context](../../tests/test-input-context.ps1)、[page-actions](../../tests/test-page-actions.ps1)、[app-input-plan](../../tests/test-app-input-plan.ps1) |
| リアクション・登録 | [quick-reaction](../../tests/test-quick-reaction.ps1)、[reaction-start](../../tests/test-reaction-start.ps1)、[reaction-results](../../tests/test-reaction-results.ps1)、[registration-storage](../../tests/test-registration-storage.ps1) |
| ワーカー・終了 | [worker-lifetime](../../tests/test-worker-lifetime.ps1)、[app-worker](../../tests/test-app-worker.ps1)、[worker-cleanup](../../tests/test-worker-cleanup.ps1) |
| 画面・排他・編集 | [app-layout](../../tests/test-app-layout.ps1)、[ui-transactions](../../tests/test-ui-transactions.ps1)、[editor-lifecycle](../../tests/test-editor-lifecycle.ps1)、[viewports](../../tests/test-viewports.ps1)、[window-suspension](../../tests/test-window-suspension.ps1) |
| 起動・配布・ランナー | [startup](../../tests/test-startup.ps1)、[release](../../tests/test-release.ps1)、[runner](../../tests/test-runner.ps1) |

この表は入口です。`-List`と近隣テストで追加の影響範囲を確認します。保存契約・共通基盤・複数の境界を変える場合は範囲を広げます。

## 失敗したとき

最初のエラー、終了コード、スタック、保持したコピーを確認します。UTF-8の出力にはタイムアウト前のログも含まれます。前面失敗の`desktop`・`receives_input`・`foreground_owned`は観測値で、単独では原因を確定できません。同じデスクトップへの手操作と、ホストだけの操作を区別します。

原因を絞ってから必要な群を再実行します。成功した再実行だけで、以前の未特定失敗を解消済みにしません。[未特定の観測](complexity-results.md#原因未特定の失敗と追加した観測)を残してください。

## 回帰テストを追加する

ファイル先頭に`# Test-Session: Headless`または`Desktop`を付けます。支援・計測スクリプトに`test-`を付けません。故障の注入には通常の例外、期待結果には共有の`Assert`を使います。テストの`finally`と製品の終了処理を通し、失敗を捕捉して成功へ変えません。

### テストの準備と観測

[support.ps1](../../tests/support.ps1)の`New-TestRuntime`、`Invoke-AhkTest`、`Invoke-AppTest`、`Wait-TestProcess`を使います。[app-fixture.ps1](../../tests/app-fixture.ps1)は合成設定とワーカーを用意します。[library-model.ahk](../../tests/fixtures/library-model.ahk)は下書きと設定のコピーを用意し、確定は製品の処理を使います。

通常の依存は`RuntimePorts`で差し替えます。描画は実際のコントロールとWindowsメッセージを観測します。共有Assertは失敗位置を記録し、製品のcatchで吸収されても成功にしません。テスト入口は未処理例外を記録して終了します。

### 失敗・割り込み・資源解放の検証

通常操作で到達できない故障点だけ、`Edit-TestSource`で隔離コピーへ注入します。置換前の完全一致がなければ停止し、原本と製品用フックを変更しません。ロック・タイマー・表示失敗を使い、保存前の保全、保存後の公開、所有権復旧、再試行、実資源の解放を確認します。割り込みを禁止した実装に合わせて、テストから必要な割り込みまで消しません。

## 実画面で補う確認

新規弾幕の追加と再起動、チャンネル連携、タブ往復、選択復元、狭い画面・拡大表示、チャット・コメント・返信、登録と非送信確認、別フォルダーへの復元を確認します。実送信の検査では対象動画・種類・最大回数を事前に決めます。

## 実ブラウザーを確認する

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

### 人間がリアクションUIの表示を確認する

`Hover=hovered`はマウス移動の成功です。`Display=not-verified`は自動では変更しません。人間が5種類のメニューを確認し、起動版・日時・ブラウザー・ページ種類・使用キー・見えた結果を別に記録します。送信の受理はこの検査の対象外です。

## 性能を計測する

| スクリプト | 計測範囲・既定値 |
|---|---|
| `tests/benchmark-storage.ps1` | 保存計画。1千・1万・10万件、反復7回。`-SourceRoot`で比較元を指定 |
| `tests/benchmark-load.ps1` | 画面・キー・ワーカーなしの読込と状態反映。1千・1万件、反復3回。`-SourceRoot`も指定可能 |
| `tests/benchmark-ui.ps1` | パレット・検索・管理一覧の更新。1千・1万件、反復3回 |

各スクリプトはウォームアップ後に中央値・最大値を出し、計測外で結果を照合します。読込とUIは`-Counts`（1〜100000）と`-Repeats`（1〜9）、保存計画は反復1回以上を指定できます。複数件数はPowerShell内で`& ./tests/benchmark-load.ps1 -Counts 1000,10000,100000`のように渡します。

保存計画にはSQL・DB書込・描画を含みません。読込は接続・ステートメント・OSキャッシュを再利用し、初回起動とは異なります。UIの`cold_initialize`は空DBと画面構築の1回の値で、プロセス起動を含みません。管理一覧更新は初回構築・DB保存を含まず、パレット描画は最大500件です。条件の異なる過去値を直接比較しません。

## 確認記録

版・日時・条件・結果・未検証範囲を[検証・計測の記録](complexity-results.md)へ残します。過去の成功を現在のソースや別ブラウザーへ適用しません。
