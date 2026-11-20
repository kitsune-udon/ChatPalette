# ChatPaletteの文書一覧

初めて使う方は、配布ZIPを展開し、共通の弾幕を1件登録してYouTubeの入力欄で試せます。[READMEの「最初の弾幕を使う」](../README.md#最初の弾幕を使う)

## 利用する

| 目的 | 文書 |
|---|---|
| 弾幕を登録する、チャンネルに合わせて配信者を切り替える | [弾幕と配信者](user/guide.md) |
| リアクションを準備、実行、停止する | [リアクション](user/reactions.md) |
| キー・初期値・保存範囲を調べる | [リファレンス](user/reference.md) |
| 以前の版から更新する、データを保管・復元する | [更新手順](user/maintenance.md#更新を反映する) · [バックアップ](user/maintenance.md#バックアップする) |
| アプリが起動しない、キーや入力欄が反応しない | [症状から確認する](user/maintenance.md#症状から確認する) |

## 開発する

| 目的 | 文書 |
|---|---|
| ソースからビルドする、変更箇所を探す、配布ZIPを作る | [開発・配布手順](developer/guide.md) |
| 本体とワーカーの役割、入力・設定保存の流れを読む | [設計と状態の所有](developer/architecture.md) |
| 変更に合う試験を選び、WindowsやSandboxで実行する | [検証ガイド](developer/testing.md) |
| 0.8.0と現行版に同じ要求を送り、ワーカーの応答や所要時間を比べる | [ワーカーの比較手順](developer/worker-comparison.md) |

## 過去の版と移行記録を調べる

利用者向けの変更点は[変更履歴](../CHANGELOG.md)にあります。次の資料には、AutoHotkey・PowerShell版からZig版に切り替えた当時の計画、試験条件、結果を保存しています。

| 調べたいこと | 資料 |
|---|---|
| 0.8.0以前の動作と性能 | [旧版の検証・計測記録](history/complexity-results.md) |
| 移行の範囲と合格条件 | [移行計画](history/zig-migration.md) · [計画の独立レビュー](history/zig-migration-review.md) |
| ワーカーの移植と初回応答時間 | [移植検証](history/worker-verification.md) · [試作時の計測値（JSON）](history/worker-prototype.json) |
| 旧版の57試験群に対応するZig版の検証結果 | [新旧の照合記録](history/zig-migration-evidence.md#080の57群との照合) |
| 0.9.0の公開時に照合したZIPとSHA-256 | [公開後の検証記録](history/zig-migration-evidence.md#m7の完了判定) |
