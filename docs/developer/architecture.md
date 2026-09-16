# 設計と責務の分担

[READMEへ戻る](../../README.md) · [開発・配布ガイド](guide.md)

プロジェクト: `youtube_chat_helper`。起動ファイル: `main.ahk`。パネル呼び出し: Ctrl＋Alt＋Q。

## 処理の全体像

```mermaid
flowchart TD
    UI[パネル・ショートカット] --> Controller[入力・リアクションの制御]
    UI --> Service[設定・投稿者の変更確定]
    Service --> Store[INI読み書き]
    Controller --> Client[常駐プロセスの管理・通信]
    Client <-->|名前付きパイプ| Worker[PowerShell補助プロセス]
    Worker --> Browser[ブラウザーのUI Automation]
    Worker --> Metadata[YouTube oEmbed・動画情報キャッシュ]
```

弾幕の文字列入力はAutoHotkeyの `SendText` が担当する。PowerShell側は動画確認や投稿者の解決を担当し、Enterによるチャット送信はしない。リアクションはPowerShell側でUI Automationの操作を呼び出す。

## モジュールの役割

- `main.ahk`: 起動、操作の順序、投稿者選択、保存・取り消しの方針。`RequestBrowserOperation` は通信中の操作制限と表示を調整する。
- `app_ui.ahk`: 画面構築、表示更新、GUIイベントの受け取り。UIイベントは対象を確定してモデル／操作処理に渡す。
- `settings_store.ahk`: 設定全体の読み取り・候補データのINI書き込み。実行中のデータは更新しない。
- `settings_schema.ahk`: 設定の選択肢と既定値。読み込み・保存前検証・画面の選択肢が同じ定義を参照する。
- `settings_service.ahk`: 設定の読み込み・移行・変更確定。候補の保存に成功してから実行中の値へ反映する。キー変更はコールバックを抑止した区間で準備し、保存失敗時に旧登録へ戻す。
- `profile_service.ahk`: 投稿者の追加・名前変更・関連付け・削除・取り消し・選択の保存。UIを作らずに呼び出せる。
- `worker_client.ahk`: 常駐プロセスの管理、名前付きパイプ、要求と応答、タイムアウト。GUIを参照しない。
- `danmaku_library.ahk`: 明示した弾幕リストの操作と復元。画面の選択状態、保存、入力操作を参照しない。
- `chat_input.ahk`: 投稿者別／共通の文字列の解決と入力。`DeliverText` は確定した文字列・対象ウィンドウ・動画IDを受け取る。
- `reaction_drafts.ahk`: 編集開始・破棄に伴う下書きの作成。GUI部品を参照しない。表示更新では下書きを作り直さない。
- `reaction_controller.ahk`: リアクションの設定操作、キー登録、実行・停止・回数管理。
- PowerShell側: 動画・投稿者の取得とリアクションボタンの検出／操作。UI Automationでブラウザーの状態を確認する。

## 状態と保存の流れ

永続データは `settings.ini` に保存し、編集中のリアクション設定は別の下書きに保持する。画面変更時に下書きを更新し、保存時には下書きを検証して候補の設定全体を書き出す。書き込みに成功してから実行中の設定へ反映する。投稿者管理と弾幕操作は、操作の確定時に保存する。

`settings_schema.ahk` の選択肢・既定値を、読み込み時の検証、保存前の検証、画面の選択肢生成で共有する。

投稿者0件は正常な状態であり、選択位置は0となる。`GetSelectedProfile()` は未選択なら0を返す。投稿者別の下書きは作らず、共通弾幕・共通リアクションは独立して利用する。

## 通信と障害処理

補助プロセスは必要時に起動する。要求・応答は長さ付きUTF-8フレームでローカルの名前付きパイプを通す。要求の連番・対象ウィンドウを照合し、接続相手のプロセスIDも確認する。通常の要求は最大8秒、動画の再確認は最大2.5秒で待機を打ち切る。

通信失敗時は接続と補助プロセスを整理する。次の要求で再起動できるが、失敗した要求を自動再実行しない。特にリアクションは、操作後に通信が切れた場合に実行済みか判断できないため、結果不明を再送しない。

通信のためにディスクへ要求・応答ファイルを書き出すことはない。INIは設定変更時、ボタン登録JSONは登録時、動画キャッシュは新たな情報を取得したときに保存する。

## 自動判別と関連付け

ブラウザーのURL欄から現在の動画IDを取得し、動画IDに対応する投稿者情報をキャッシュまたはoEmbedから解決する。取得後に動画IDを再確認し、途中で動画が変わっていれば結果を適用しない。

関連付けは投稿者URLから正規化したチャンネルのパスをキーにする。表示名の類似度や部分一致では判定しない。保存済みの投稿者を索引化し、同一キーが複数あれば曖昧な関連付けとして扱う。ハンドル等の変更に追従する不変IDへの変換は行っていない。

## 変更時の規則

1. 通常の変更は `CommitProfileReactionDraft`、`CommitSharedReactionDraft`、`SaveLibraryTargets`、`ExecuteProfileCommand` などで確定する。実行中の値を書き換えてから保存しない。`SaveAppSettingsSnapshot()` は既存の状態をそのまま書き出す補助API。
2. 投稿者操作は `ExecuteProfileCommand` が保存後の履歴破棄・索引更新も担当する。画面から投稿者データを直接変更しない。
3. 取り消しは `CreateLibraryUndoSnapshot` に渡したリストのみ復元する。投稿者選択・リアクション設定を巻き戻さない。
4. 入力対象の文字列を決めるために、編集画面の選択を変更しない。
5. 投稿者別の下書きは編集開始時の投稿者オブジェクトを保持する。保存対象が一致しなければ保存を拒否する。
6. 通信によって元から無効だった画面を有効にしない。低水準の `SendWorkerRequest` は表示に触れず、`RequestBrowserOperation` が表示層を調整する。
7. 下書きは変更イベントで更新する。保存時にGUIから読み直さず、保持している下書きを保存する。
8. `ReadSettingsFile(path)` は設定全体を新しい値として返す。`ReloadAppSettings()` は取得・検証に成功した結果だけを一括で適用する。呼び出し前の配列クリアは不要。
9. 設定確定の区間はタイマー・キー処理による割り込みを抑止する。成功・失敗のどちらでも以前の割り込み設定を復元する。
10. 投稿者の切り替え可否は `CanChangeProfile` で判断し、保存サービスでも検証する。共通設定の未保存変更は切り替えを妨げず、切り替え後も保持する。
11. リアクションの実行状態はコントローラーの `ReactionExecutionStatus` が保持する。開始待ちの終了判断には `Phase` を用い、画面の文章を読み戻して判断しない。`RenderReactionStatus` は表示と表示タイマーだけを担当する。
12. 初期設定は投稿者・投稿者別弾幕・共通弾幕がすべて0件。最後の投稿者を削除しても代替データを作らない。選択がない場合は `GetSelectedProfile()` が0を返し、投稿者別編集を無効にする。共通設定・共通弾幕は独立して利用できる。

AutoHotkeyの共有状態は残している。ファイル分割だけで隔離されたモジュールになるわけではないため、GUI依存の禁止と上記の契約をテストで確認する。

## 名前の規則

- ファイル名は担当を示す。`settings_store.ahk` はファイル入出力、`settings_service.ahk` は設定の確定、`worker_client.ahk` は常駐処理への通信を担当する。
- PowerShellの `browser_worker.ps1` は常駐処理の入口、`reaction_automation.ps1` はリアクション操作を担当する。
- 弾幕の識別子には `Danmaku`、全投稿者で共有するデータには `Shared`、投稿者別のデータには `Profile` を用いる。
- `SelectedProfileIndex` は配列の選択位置、`TargetBrowserHwnd` は入力先ウィンドウ、`ActiveReactionJob` は実行中の処理を表す。
- 操作は `Insert`、`Delete`、`Commit`、`Read` などで目的を示す。`UndoLibraryChange` は削除だけでなく移動も取り消す。
- 保存ファイルは `settings.ini`、`reaction_selectors.json`、`video_metadata_cache.json`。既存データのキー名・形式は変更していない。
