# 検証ガイド

[文書一覧](../index.md) · [実行コマンド](guide.md#テストを実行する)

## 自動テストで分かること

現行の一括実行は33テスト群です。アプリ・SQLite・GUIの一部は実際に動かし、ブラウザー入力・リアクション送信・ネットワークは代替処理に置き換えます。成功は、ブラウザー全種類との互換性や実際のYouTube受理数の証明にはなりません。

`tests/run.ps1`が直下の`test-*.ps1`を名前順に自動検出し、各テストを別のWindows PowerShellプロセスで実行して終了コードを確認します。実行中のファイル名と、成功時のテスト群数も表示します。支援スクリプトと計測用スクリプトには`test-`を付けません。一時実行先は`tests/.tmp/run-*`です。全体成功時に削除し、失敗時は調査用に残します。単体実行の一時フォルダーは自動削除しません。利用者の`data/`は読み書きしません。

## 変更とテストの対応

| 対象 | 主なテスト | 検証する契約 |
|---|---|---|
| 代表的な画面連携 | [test-app.ps1](../../tests/test-app.ps1) | 初回表示、パレットから管理画面、戻る操作、モジュール境界 |
| 配置・表示 | [test-app-layout.ps1](../../tests/test-app-layout.ps1) | 狭い画面、非表示での配置、通知、チャンネル連携 |
| 編集ダイアログ | [test-app-editors.ps1](../../tests/test-app-editors.ps1) | 保存・変更あり/なしの破棄確認・取消時の下書き保持・再表示・フォーカス復元 |
| ライブラリ操作 | [test-app-library.ps1](../../tests/test-app-library.ps1) | 選択、編集、割当、Undo、保存失敗、サービス単体の操作 |
| 入力計画 | [test-app-input-plan.ps1](../../tests/test-app-input-plan.ps1) | 解決は一度、動画変更、IDによる追跡、本文変更・同文の別項目の拒否 |
| 設定往復 | [test-app-settings.ps1](../../tests/test-app-settings.ps1) | 共通設定専用API、キーのロールバック、旧INI、Unicode・長文・競合 |
| 通信・実行 | [test-app-worker.ps1](../../tests/test-app-worker.ps1) | 名前付きパイプ、再起動、タイムアウト、中止、実行間隔、合成UIA |
| 操作ルール・表示モデル | [test-operation-models.ps1](../../tests/test-operation-models.ps1) | 状態の組み合わせ、停止、編集内の保存、純粋な表示計算、再入更新の集約、ボタン状態 |
| SQLite基盤・保存 | [test-sqlite.ps1](../../tests/test-sqlite.ps1) | 差分更新、競合、容量、バックアップ、異常終了 |
| 登録保存・同期 | [test-registration-storage.ps1](../../tests/test-registration-storage.ps1) | 移行、保存失敗、同期失敗、保存前後の中止、ワーカー保持 |
| 状態と識別子 | [test-state-contracts.ps1](../../tests/test-state-contracts.ps1) | 独立したID選択、重複本文の選択復元、混合編集・不正ID・順序の不変性、古いジョブの終了と中止 |
| 設定整合性 | [test-settings-integrity.ps1](../../tests/test-settings-integrity.ps1) | 欠損・不正な設定を拒否し原本を保持 |
| 起動・復旧 | [test-startup.ps1](../../tests/test-startup.ps1) | 空・破損・未対応DB、移行中断と再試行 |
| 空のライブラリ | [test-empty-settings.ps1](../../tests/test-empty-settings.ps1) | 新規状態・最後の削除・共通弾幕・再読み込み |
| 画面復帰 | [test-palette-return.ps1](../../tests/test-palette-return.ps1) | 編集反映、入力対象と編集対象の独立 |
| 順序操作 | [test-management-order.ps1](../../tests/test-management-order.ps1) | 選択・スクロール・上下移動 |
| 一覧表示 | [test-list-visibility.ps1](../../tests/test-list-visibility.ps1) | タブ往復・再表示・明示的非表示 |
| 小さい画面 | [test-viewports.ps1](../../tests/test-viewports.ps1) | 配置、スクロール、フォーカス追従 |
| UI更新の割り込み | [test-ui-transactions.ps1](../../tests/test-ui-transactions.ps1) | 完成後の公開、更新中操作の拒否、対象ID、配置の直列化・終了後の保留解除 |
| 画面・診断の回帰 | [test-review-regressions.ps1](../../tests/test-review-regressions.ps1) | 結果保持、通知、診断など過去の不具合 |
| 不要処理の抑制 | [test-performance.ps1](../../tests/test-performance.ps1) | 履歴共有、差分編集、同値保存、非表示更新抑制、パレットの同値書き込み抑制 |
| 検索・選択肢 | [test-search-scheduling.ps1](../../tests/test-search-scheduling.ps1) | 検索集約、旧結果操作防止、選択肢の再利用 |
| 時間制御 | [test-timing.ps1](../../tests/test-timing.ps1) | タイマー精度の取得・解除、間隔、平均開始時刻 |
| リアクション検出 | [test-reactions.ps1](../../tests/test-reactions.ps1) | 5種類の識別、曖昧な対象の拒否、操作直前の画面変更 |
| UIA参照 | [test-cache.ps1](../../tests/test-cache.ps1) | 再検証、登録の置換、要素の失効 |
| ページ操作 | [test-page-actions.ps1](../../tests/test-page-actions.ps1) | チャット限定、表示用UIの識別、対象・動画・前面の変更、クリック／送信しないこと |
| フォーカス後の保留入力 | [test-focused-input.ps1](../../tests/test-focused-input.ps1) | 1件の保留、キー解放待ち、連打、期限、動画・入力欄・本文変更、失敗時の解放 |
| ページ操作キー | [test-page-shortcuts.ps1](../../tests/test-page-shortcuts.ps1) | フォーカス後の再検証、失敗時にクリアしない、キー競合、編集中の拒否 |
| キー管理画面・移行 | [test-shortcut-manager.ps1](../../tests/test-shortcut-manager.ps1) | 全キー保存、交換、重複拒否、登録/保存失敗時の復元、弾幕割当、形式2からの移行 |
| 実キーの経路 | [test-page-hotkeys.ps1](../../tests/test-page-hotkeys.ps1) | アプリのキー登録経路からF／C／Eを発火し、隔離GUIでフォーカス・実際のクリア・表示要求を確認 |
| 文字入力 | [test-input.ps1](../../tests/test-input.ps1) | チャット・コメントの分類、拒否条件、同一要素確認 |
| メモリキャッシュ | [test-storage.ps1](../../tests/test-storage.ps1) | 再利用、期限、件数、再試行抑制、登録更新 |
| 配布 | [test-release.ps1](../../tests/test-release.ps1) | 必須ファイル、個人データ除外、ハッシュ、上書き防止 |

## 失敗したとき

1. 最初のFAILと、出力された一時フォルダーの場所を確認します。
2. そのフォルダーのソース・標準出力・標準エラーを確認します。正式版へ失敗時のデータをコピーしないでください。
3. 構文エラー、実装の不具合、テストの前提、フォーカス競合など環境要因を区別します。
4. 原因を説明できてから修正・再実行します。再実行で通っただけで環境要因と断定しません。
5. 調査後、該当する一時フォルダーだけを削除します。

画面フォーカスを扱う試験は、非対話セッションや別アプリの操作に影響されます。単体で再現を絞る場合は、例えば次を実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-registration-storage.ps1
```

## テストの起動と差し替え

`support.ps1`の`Invoke-AppTest`が、モジュール読み込み・任意の外部アダプター設定・`InitializeApplication`・検査本体から独立したAHK入口を作ります。`Invoke-AhkTest`がプロセス起動、時間制限、終了コード、標準出力を管理します。`--smoke`を付けるため、起動失敗で復旧ダイアログを待ち続けません。実際の`main.ahk`は起動テストで別途検証します。

画面連携のテストは目的別の独立したシナリオです。共通の`app-fixture.ps1`は各呼び出しで新しい隔離フォルダー、旧INIの合成データ、偽ワーカー、明示的なテスト状態を作り、新しいAHKプロセスで初期化します。前のテストが追加・変更したデータには依存しません。配置などの補助関数は必要なシナリオだけが定義します。

通常のブラウザー要求、通信要求、入力、前面確認、時刻、タイマー精度、ホットキー、キー解放待ちは`RuntimePorts`へコールバックを設定して置き換えます。本体の関数名や本文を書き換えないでください。既定処理を観測する検査は対応する`Native…`アダプターを呼べます。

IPCテストは`Write-TestWorker`で専用の入口を作り、`Start-BrowserWorker`へ合成応答のハンドラーを渡します。`RuntimePorts.WorkerScript`はその入口だけを差し替えます。通信・資源解放は本番と共通で、本番ファイルの関数名や本文は置換しません。

描画回数とコントロール書き込みは、`fixtures/ui-message-probe.ahk`が隔離GUIのWindowsメッセージを観測します。アプリの関数呼び出し回数ではなく、実際の一覧再構築・有効状態変更・文言更新を検証します。終了時に観測を解除します。

ソース注入を残すのは、`test-ui-transactions.ps1`の描画途中の失敗・再入と、`test-startup.ps1`の移行途中のプロセス停止です。通常操作では起こせない瞬間へ故障を入れる目的に限定し、汎用フックを本番の各行へ増やしません。

## 回帰テストの設計

期待する利用者の結果と不変条件を先に決め、関数の内部をそのまま写した検査にしないでください。

登録中止なら、通知文言だけでなくDB・ワーカーの以前の登録が変わらないことを確認します。保存後の中止は別ケースにし、保存済み結果と同期が維持されることを確認します。対象変更なら、操作前から条件を不正にするだけでなく、検出途中に状態を切り替えて操作回数0を確認します。

成功時・境界値・保存失敗・通信失敗・ジョブ中止・ジョブ置換を、変更の影響に応じて選びます。新しい回帰テストは`test-*.ps1`として追加すると一括実行の対象になります。この対応表も更新してください。

## 実画面で補う確認

| 確認 | 成功の判断 |
|---|---|
| 空の新規状態から共通弾幕を追加 | パレットへ戻ると表示され、再起動後も残る |
| チャンネル連携→配信者別弾幕追加→戻る | 入力対象と表示内容が一致する |
| タブ往復・初回表示・再表示 | 一覧が消えず、選択行と上下ボタンが一致する |
| 小さい画面・拡大表示・モニター間移動 | 操作部へ到達でき、文言が重ならない。編集・ヘルプも確認 |
| チャット・コメント・返信欄 | 意図した欄だけに入力する。検索・アドレス欄は拒否 |
| ボタン登録→送らずに確認 | 5種類を識別し、送信操作を起こさない |
| バックアップ→別フォルダーで復元 | 弾幕・連携・標準設定・登録を読み直せる |

実送信を伴う試験は、対象動画・種類・最大回数を事前に決めて実施します。自動テストが送信しないことを理由に、手動試験も送信しないと考えないでください。

## 性能の測り方

機能回帰と実測を分けます。性能回帰テストは不要な更新・複製・再探索の抑制を確認しますが、毎回同じ実時間を要求する試験ではありません。

実測では版、OS、ブラウザー、件数、検索語、キャッシュの有無、実行回数を記録し、変更前後を同じ条件で比較します。初回起動・初回探索と再利用時を分け、平均だけでなく遅い試行も記録してください。リアクションは指定間隔・処理時間・平均開始間隔・YouTube側の受理を区別します。

大量データのテストは合成データと隔離DBを使います。保存上限の試験を、快適性や長時間稼働の検証結果として扱わないでください。実停電、OS全体のディスク枯渇、全ブラウザーの互換性は既存テストで検証していません。

## 文書変更の確認

文書だけの変更では、アプリ全テストの再実行より、実装との照合・相対リンクと見出し・配布ZIPへの収録確認を優先します。手順の意味が変わる場合はその操作も確認し、実際に行っていない手順を検証済みと記載しないでください。

## 保存計画の計測

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\benchmark-storage.ps1
# 以前のソースを別フォルダーに展開して同じ計測を実行
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\benchmark-storage.ps1 -SourceRoot '以前のソースの場所'
```

合成データ1千・1万・10万件の編集・隣接交換・Undoについて、保存計画の計算時間を出力します。各条件はウォームアップ1回を除く7回の中央値と最大値です。DBへの書き込み、画面再描画、ブラウザー操作の時間は含みません。通常の回帰テストには時間の合否基準を加えません。今回の比較は[改善時の計測記録](complexity-results.md)を参照してください。

## ページ操作の確認記録（2026-09-23）

追加したページ操作は、隔離テストでチャット限定の検証、動画・前面・対象の変更、失敗時のクリア抑止、クリックや送信を行わないこと、キー競合を確認しています。当時の実キー経路の検査も成功し、クリアは隔離GUIだけで実行しました。BraveのYouTubeページでは、ネイティブ処理によるフォーカス成功と表示用ボタンへのマウス移動成功を確認しました。リアクションUIの見た目は自動検証していません。旧版の起動プロセスを再起動した後、利用者から3機能が想定どおり動作しているとの確認を得ました。

途中の全体実行で既存の`test-app-editors.ps1`の保存クリック検査が一度失敗しました。単体実行とその後の全体実行では再現しておらず、原因は未特定です。再発時にアプリ自身の編集画面の状態と保存案内を出力する診断を追加しました。

## 実行区分と実ブラウザーの検証

`tests/run.ps1 -Group Headless` は画面操作不要の5群、`-Group Desktop` は操作可能なWindowsセッションが必要な27群を実行します。省略時は全32群です。`-List`で実行対象だけを確認できます。各テスト先頭の`Test-Session`が区分の正本で、未分類のテストはエラーになります。HeadlessもWindowsの.NET/UIAライブラリを使うため、Linux対応を意味しません。GUIテストのフォーカス競合を避け、Desktopは専用セッションで実行してください。

実ブラウザーの検証は自動テスト群とは別に行います。

```powershell
# タイトル・URLを出さず、ブラウザー名と対象ハンドルを一覧表示
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-browser.ps1 -List
# 一覧のWindowHandleを指定。通常ページ/別ウィンドウは自動判定
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-browser.ps1 -WindowHandle 123456 -PageKind Watch -OutputPath .\tests\.tmp\browser-watch.json
# 別ウィンドウでは -PageKind Popout を指定
```

対象はライブチャットを表示したYouTubeページです。既存レポートは上書きしません。`-Exercise`を付けると、対象が最前面の場合だけフォーカス移動と表示用ボタンへのホバーを行います。入力・クリア・クリック・リアクション送信は行いません。終了コード0は検出と指定した操作の成功で、メニューの見た目やYouTubeの受理を保証しません。表示の確認は目視で別途記録してください。

ブラウザー名・版・ページ種類・各検出/操作の結果をJSONへ残します。URL・タイトル・チャット内容・例外本文は記録しません。Chrome、Edge、Brave、Firefoxなどは、通常ページと別ウィンドウそれぞれの結果が揃ってから、その組み合わせを検証済みと扱います。未実施や対象なしを成功と扱わないでください。

## 画面の性能計測

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\benchmark-ui.ps1
```

隔離DBの合成データ1千・1万件で、設定読み込み・実際のパレット一覧描画・検索を計測します。各操作はウォームアップ1回後、既定3回の中央値と最大値を出します。`cold_initialize`は空DBの初期化と画面構築を1回測った値で、プロセス起動時間を含みません。`-Counts`と`-Repeats`で件数と反復数を指定できます。測定結果に基づきパレットの表示は先頭500件までとし、検索は全データを対象にします。管理画面は全件表示を維持します。
