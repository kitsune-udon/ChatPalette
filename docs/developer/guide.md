# 開発・配布手順

[文書一覧](../index.md) · [設計](architecture.md) · [検証](testing.md)

## 作業を始める

Windows、AutoHotkey v2、Windows PowerShell 5.1、Gitを用意します。ブラウザー調査にはWindows UI Automation、保存にはWindows標準の `winsqlite3.dll` を使います。追加のSQLiteサーバーやパッケージ管理による依存取得はありません。

実行確認はWindows 11・64bit版AutoHotkey v2で行っています。これ以外の環境を対応済みとする場合は、その環境で保存・ブラウザー検出・入力・配布の検証を追加してください。

リポジトリを取得したら、通常利用するアプリとは**別フォルダー**を開発用に使います。同じスクリプトの起動は `#SingleInstance Force` により既存インスタンスを置き換えます。構文確認だけでも、正式版のパスを使って実行しないでください。

以下の例はリポジトリ直下で実行します。AutoHotkeyのインストール場所が違う場合は読み替えます。

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
| 保存と移行 | [src/settings/](../../src/settings)、SQLite呼び出しは[src/storage/](../../src/storage) |
| キーの許可・登録 | [src/shortcuts/](../../src/shortcuts) |
| 文字入力の対象確認 | [src/input/](../../src/input)、[src/browser/input_target.ps1](../../src/browser/input_target.ps1) |
| リアクションの実行・停止 | [src/reactions/reaction_controller.ahk](../../src/reactions/reaction_controller.ahk) |
| UIAによるボタン検出 | [src/browser/reaction_automation.ps1](../../src/browser/reaction_automation.ps1) |
| 常駐プロセスとの通信 | [src/browser/worker_client.ahk](../../src/browser/worker_client.ahk)、`browser_worker.ps1` |

変更前に[状態の所有と確定順序](architecture.md)を確認してください。画面の選択値をそのまま保存済み状態へ代入する変更や、結果不明の操作を自動再送する変更は、既存の保証を崩します。

## テストを実行する

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

AutoHotkeyが標準外の場所にある場合は、末尾へ `-AutoHotkeyPath '実行ファイルの絶対パス'` を追加します。成功時は終了コード0と全体のPASSを確認します。

テストは一時フォルダーへソースをコピーして実行します。実ブラウザーへの入力・リアクション送信・ネットワーク取得は代替処理を使いますが、画面生成やフォーカスを扱うテストはあります。操作できるWindowsセッションで実行し、途中で別のウィンドウへフォーカスを奪う操作を避けてください。

対象別のテスト、失敗時の調べ方、手動確認は[検証ガイド](testing.md)を参照してください。

## 文字コードとGit

| 対象 | 作業ツリーの形式 |
|---|---|
| `.ahk`・`.ps1` | UTF-8 BOM付き、CRLF |
| Markdown・Git設定・LICENSE・VERSION | UTF-8 BOMなし、LF |
| 移行テスト用INI | `.gitattributes`でテキスト変換を無効化した固定データ |

`.gitattributes`がGitの改行変換、`.editorconfig`が対応エディターの保存形式を定めます。GitはBOMを自動付加しません。特にWindows PowerShell 5.1で日本語を含むスクリプトを編集するときは、BOMを保持してください。

個人の `data/`、配布出力 `dist/`、テストの一時ファイルはGit対象外です。`tests/fixtures/settings.ini`は合成データなので、旧ユーザー設定と区別して保持します。

```powershell
git status --short
git diff --check
# ステージング後
git diff --cached --check
```

文書では配布・リポジトリ内の相対パスを使用し、開発者個人の絶対パスや動画情報を含めないでください。

## 検証済みの配布物を一度に作る

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-release.ps1 -OutputDirectory .\dist\validated
```

配布許可リストのソースを一時フォルダーへ固定し、バージョン一致・文字コード・改行・PowerShell構文・文書リンク・全テストを確認した後、その同じソースからZIPを作ります。テスト中に配布対象が変化した場合は拒否します。成功時にはZIPと、ZIPのSHA-256・ソースマニフェストのSHA-256・検査日時・テスト群数を含む`.validation.json`を出力します。公開やpushは行いません。既存の同名出力は上書きしません。失敗した作業フォルダーは調査用に残します。

画面を扱うテストを含むため、操作可能なWindowsセッションで実行します。実ブラウザーの確認はこのコマンドに含めず、検証ガイドのレポートで別途管理します。形式だけ確認する場合は`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-source.ps1`を使います。

## 配布ZIPを作る

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
```

`dist/ChatPalette-バージョン.zip`を作成します。同名ZIPは上書きしません。出力を分ける場合は `-OutputDirectory '出力先'` を指定します。

収録するファイルは許可リストで選びます。アプリの入口・`VERSION`・ソース一式・文書・ライセンス・開発設定・テストと合成データ・配布スクリプトが対象です。`data/`や`.git/`、テスト実行時の一時ファイルは収録しません。ZIP内の`SHA256SUMS`は収録ファイルのSHA-256です。これは破損・内容照合用で、発行者を証明する署名ではありません。

実行に必要なのは `main.ahk`、`VERSION`、`src/`のソース一式と外部の実行環境です。配布時にはREADME・文書・LICENSEも含めます。現在のスクリプトはソース配布物を作り、単体実行ファイルへのコンパイルはしません。

## リリース手順

1. 利用者に影響する変更をCHANGELOGへ記録し、`VERSION`とREADMEのバージョンを一致させます。
2. [変更に対応するテスト](testing.md)と必要な実画面確認を実施します。リリース前には全テスト群を実行します。
3. ZIPを作成し、個人データがないことを確認します。
4. 新しいフォルダーへ展開し、DBなしで起動できること、最初の弾幕を保存・再起動して読み直せることを確認します。
5. 更新を含む場合は、利用者向けの更新・復旧手順も照合します。
6. 差分を確認してコミットします。公開先へのpushやリリース公開は別の操作です。

## 文書を更新する規則

実装・テストを一次情報とし、利用者向け手順は画面のラベルと照合します。仕様値は[リファレンス](../user/reference.md)、障害時の手順は[保守](../user/maintenance.md)、内部の理由・制約は[設計](architecture.md)を正本にします。

変更時はリンク先の存在、見出しへのリンク、バージョン、初期値、保存範囲を確認してください。新しい`.md`は配布スクリプトで収録されます。画像など別形式の資料を追加する場合は、配布スクリプトの収録対象も更新する必要があります。
