# 開発・配布手順

[文書一覧](../index.md) · [設計](architecture.md) · [検証](testing.md)

## 作業を始める

Windows、AutoHotkey v2、Windows PowerShell 5.1、Gitを用意します。ブラウザー調査にはWindows UI Automation、保存にはWindows標準の `winsqlite3.dll` を使います。追加のSQLiteサーバーやパッケージ管理による依存取得はありません。

実行確認はWindows 11・64bit版AutoHotkey v2で行っています。これ以外の環境を対応済みとする場合は、その環境で保存・ブラウザー検出・入力・配布の検証を追加してください。

リポジトリを取得したら、通常利用するアプリとは**別フォルダー**を開発用に使います。同じスクリプトの起動は `#SingleInstance Force` により既存インスタンスを置き換えます。構文確認だけでも、正式版のパスを使って実行しないでください。

`main.ahk`は引数なし、または`--check`・`--smoke`・`--quiet`のいずれか一つを指定して起動します。未知の引数や複数指定は、設定の読み込み・画面構築前に標準エラーへ理由を出して終了コード1で終了します。

以下の例はリポジトリ直下で実行します。AutoHotkeyのインストール場所が違う場合は読み替えます。 配布・検査・テスト・計測コマンドは、未知の引数名を処理開始前に拒否します。引数名の誤記を既定値での実行として扱いません。

```powershell
# 構文を読み込み、アプリ初期化前に終了
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut .\main.ahk --check

# 設定読み込みと画面構築を行って終了。data/を作る場合がある
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut .\main.ahk --smoke

# 通常起動
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' .\main.ahk

# 起動時にパレットを表示しない
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' .\main.ahk --quiet
```

## 変更箇所を選ぶ

| 変更したいこと | 最初に読む場所 |
|---|---|
| 配置・ボタン・表示文言 | [src/ui/](../../src/ui)の該当画面 |
| 弾幕・配信者の編集規則 | [src/library/library_service.ahk](../../src/library/library_service.ahk) |
| 初期値・選択肢 | [src/settings/settings_schema.ahk](../../src/settings/settings_schema.ahk) |
| 設定の保存 | [src/settings/](../../src/settings)、SQLite呼び出しは[src/storage/](../../src/storage) |
| キーの許可・登録 | [src/shortcuts/](../../src/shortcuts) |
| 文字入力の対象確認 | [src/input/](../../src/input)、[src/browser/input_target.ps1](../../src/browser/input_target.ps1) |
| リアクションの実行・停止 | [src/reactions/reaction_controller.ahk](../../src/reactions/reaction_controller.ahk) |
| UIAによるボタン検出 | [src/browser/reaction_automation.ps1](../../src/browser/reaction_automation.ps1) |
| 常駐プロセスとの通信 | [src/browser/worker_client.ahk](../../src/browser/worker_client.ahk)、`browser_worker.ps1` |

変更前に[状態の所有](architecture.md#状態を混ぜない)と、対象に応じた[保存の契約](architecture.md#永続化の契約)・[画面更新の契約](architecture.md#キャッシュと画面更新)を確認してください。画面の選択値をそのまま保存済み状態へ代入する変更や、結果不明の操作を自動再送する変更は、既存の保証を崩します。

## テストを実行する

[検証ガイドの対応表](testing.md#変更とテストの対応)から影響するテストを選び、[共通の実行コマンド](testing.md#自動テストを実行する)を使います。単体・グループ・全体の指定、AutoHotkeyの場所、実行環境、一時ファイルの扱いは同ページにまとめています。

画面やブラウザーの変更は、同ガイドの実画面・実ブラウザー確認も行います。配布時は下のリリース手順が全テストを含むため、その直前に全体を重ねて実行する必要はありません。

## 文字コードとGit

| 対象 | 作業ツリーの形式 |
|---|---|
| `.ahk`・`.ps1` | UTF-8 BOM付き、CRLF |
| Markdown・Git設定・LICENSE・VERSION | UTF-8 BOMなし、LF |

`.gitattributes`がGitの改行変換、`.editorconfig`が対応エディターの保存形式を定めます。GitはBOMを自動付加しません。特にWindows PowerShell 5.1で日本語を含むスクリプトを編集するときは、BOMを保持してください。

個人の `data/`、配布出力 `dist/`、テストの一時ファイルはGit対象外です。画面テストの合成設定は`tests/app-fixture.ps1`で作り、利用者のDBは使用しません。

```powershell
git status --short
git diff --check
# ステージング後
git diff --cached --check
```

文書では配布・リポジトリ内の相対パスを使用し、開発者個人の絶対パスや動画情報を含めないでください。

## リリース手順

1. 利用者に影響する変更をCHANGELOGへ記録し、公開する版を`VERSION`へ設定します。版番号の正本はこのファイルで、アプリ・配布処理・READMEから参照します。変更内容に応じた実ブラウザー確認は[検証ガイド](testing.md)に従います。
2. 次のコマンドを一度実行します。全テストを別途繰り返してからZIPを作る必要はありません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-release.ps1 -OutputDirectory .\dist\validated
```

3. 終了コード0、ZIP、同名の`.validation.json`を確認します。同名出力がある場合は、新しい出力先を指定します。
4. ZIPを別フォルダーへ展開し、新規起動・弾幕の保存・再起動後の読み込みを確認します。保存・更新に変更がある場合は、[バックアップと復元](../user/maintenance.md#バックアップから復元する)も確認します。
5. 差分と検証結果を確認してコミットします。pushや公開は別の操作です。

`verify-release.ps1`は配布対象を一時フォルダーへ固定し、形式確認・全テスト・ZIP生成を同じコピーに対して実行します。テスト中に配布対象が変化した場合は失敗します。失敗時は作業フォルダーを残すため、表示されたパスで原因を調べます。ZIPの存在だけで検証完了と判断せず、終了コードと同名の検証記録も確認してください。

`.validation.json`には版、検査日時、テスト群数、ZIPとソースマニフェストのSHA-256を記録します。実ブラウザーでの成功を示す記録ではありません。ブラウザー確認は別レポートとして保管します。

### 配布物の範囲

収録対象は[release-files.ps1](../../scripts/release-files.ps1)の許可リストが正本です。直下に列挙したファイルはすべて必須です。欠落しているか、同名のフォルダーに置き換わっている場合は、対象名を示してコピー開始前に失敗します。バージョンの読み込みと形式判定も同ファイルの`Get-ReleaseVersion`に集約し、ソース検査・梱包・配布検証で共有します。同ファイルの`Copy-ReleaseFiles`を検証用コピー・ZIP梱包・配布テストの準備で共有します。

ソース、文書、ライセンス、開発設定、テストと合成データを含み、`data/`・`.git/`・一時ファイルは含みません。ZIP内のパスと`SHA256SUMS`のパスは、どちらも`/`区切りの同じ相対名です。読み取り側で区切りを変換せず照合できます。`SHA256SUMS`は内容照合用であり、発行者を証明する署名ではありません。

[build-release.ps1](../../scripts/build-release.ps1)は検証コマンドから呼ぶ梱包処理です。単独実行では検証済み配布物にならないため、通常のリリース入口には使いません。

ZIPと検証レポートは、それぞれ出力先と同じファイルシステム上の一時ファイルを完成させてから、既存ファイルを上書きしない移動で正式名へ確定します。検証中に作られた同名レポートも上書きしません。レポートの公開に失敗した場合は一時レポートを片付けますが、完成済みZIPは残るため、その実行を検証成功として扱わないでください。圧縮中の読み取り失敗では不完全なZIPを正式名へ残さず、一時出力を片付けるため、原因を解消後に同じ出力先で再実行できます。現在の配布はソース形式で、実行にはAutoHotkey v2とWindows PowerShell 5.1が必要です。

## 文書を更新する規則

実装・テストを一次情報とし、利用者向け手順は画面のラベルと照合します。仕様値は[リファレンス](../user/reference.md)、障害時の手順は[保守](../user/maintenance.md)、内部の理由・制約は[設計](architecture.md)を正本にします。

未リリースの変更履歴は、作業ごとの追記ではなく、最終的な変更結果ごとにまとめます。同じ機能の追加修正は既存の項目へ統合し、内部の契約や詳細な手順は正本へリンクします。公開済みバージョンの履歴は保持してください。

変更時はリンク先の存在、見出しへのリンク、バージョン、初期値、保存範囲を確認してください。`docs/`内の新しい`.md`は配布対象になります。リポジトリ直下のファイルや画像など別形式の資料を追加する場合は、[配布対象の許可リスト](../../scripts/release-files.ps1)も更新してください。

文書だけの変更では、実装との照合、相対リンクと見出し、配布対象への収録を確認します。手順の意味が変わった場合は、その操作も確認します。実施していない操作を検証済みと記載しないでください。形式とリンクの確認は次のコマンドを使い、アプリ全テストは文書変更だけを理由に繰り返しません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-source.ps1
```
