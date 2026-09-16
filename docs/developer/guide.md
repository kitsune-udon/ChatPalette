# 開発・配布ガイド

[READMEへ戻る](../../README.md) · [設計と責務の分担](architecture.md)

## 実行構成

入口は `main.ahk`。AutoHotkey v2からWindows PowerShellの `powershell.exe` を起動し、`src/browser/browser_worker.ps1` が `src/browser/reaction_automation.ps1` を読み込みます。ブラウザー操作はWindows UI Automationを利用します。

PowerShell 7への切り替えは実装していません。ブラウザーの起動やYouTubeへのログインは利用者が行います。

## 配布に含めるもの

- トップの `main.ahk`・`VERSION` と `src/` 内のソース一式（サブフォルダー構成を維持）
- `README.md`、`LICENSE`、`docs/` 一式
- ソース配布の場合は `.gitignore`、`.gitattributes`、`.editorconfig`

実行に必要なのはコード一式です。利用先にAutoHotkey v2とWindows PowerShell 5.1が必要です。設定をアプリ内の `data/` に保存するため、利用者が書き込める場所へ展開します。

個人の `data/` 全体と、旧配置の `settings.ini`、`reaction_selectors.json`、`video_metadata_cache.json`、保存途中の `.new` ファイルは配布しません。`.git` フォルダーも実行用配布物には不要です。Gitの除外設定はZIP作成時の除外を保証しないため、配布物そのものを確認してください。

## Gitと文字コード

| ファイル | 保存形式 | 設定場所 |
|---|---|---|
| `.ahk`・`.ps1` | UTF-8 BOM付き、作業ツリーの改行はCRLF | `.editorconfig`／`.gitattributes` |
| Markdown・Git設定 | UTF-8 BOMなし、LF | 同上 |

Windows PowerShell 5.1で日本語を含むスクリプトを確実に読めるよう、`.ps1` はBOM付きにします。AutoHotkey v2ではBOMは必須ではありませんが、現在のソースはBOM付きで統一しています。

`.editorconfig` は対応エディターに対する指定です。Git自体がBOMを追加する設定ではありません。`.gitattributes` は主に改行の扱いを定義し、Git内部ではテキストの改行を正規化します。ローカルリポジトリの `core.autocrlf=false` 設定はクローン先へ自動継承されませんが、追跡される `.gitattributes` の指定は共有されます。

## 起動オプション

以下はプロジェクトフォルダーで実行する例です。AutoHotkeyのインストール先が異なる場合は実行ファイルのパスを変更します。

```powershell
# 通常起動
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' .\main.ahk

# パネルを表示せず常駐
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' .\main.ahk --quiet

# 読み込み・構文確認後に終了。アプリの初期化はしない
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut .\main.ahk --check

# 設定読み込み・画面構築後に終了
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut .\main.ahk --smoke
```

`--smoke` は設定ファイルを作成することがあります。同一スクリプトの多重起動は置き換えられるため、常駐中の正式版で検証せず、別フォルダーのコピーで実行してください。

## リリース前の確認

1. 配布予定のコードを新しいフォルダーへコピーし、INI・JSONを置かずに起動する。
2. 空のパレット・管理画面が表示され、サンプルが生成されないことを確認する。
3. 最初の配信者と弾幕を追加し、保存・再起動で内容が維持されることを確認する。
4. 最後の配信者の削除と取り消し、配信者0件での共通弾幕編集を確認する。
5. 入力対象と編集対象の独立、動画変更時の入力拒否、並べ替え後のキー割当、複数段階の取り消し、保存失敗時の保持を確認する。
6. リアクションはまず登録と「② 送らずに確認」で確認する。送信を伴う確認は明示的に行う。
7. 配布物に個人データ・一時ファイルが入っていないことを確認する。

## 自動テスト

プロジェクト直下で以下を実行します。Windows PowerShell 5.1とAutoHotkey v2が必要です。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

AutoHotkeyを標準外の場所に置いている場合は `-AutoHotkeyPath '実行ファイルの絶対パス'` を指定します。各テストは新しい一時実行フォルダーを作り、固定データまたは空状態で検証します。実際の入力・リアクション操作・ネットワーク取得は代替処理で置き換えます。利用者の `data/` を読み書きしません。一括実行後の一時ファイルは成功・失敗のどちらでも削除します。

自動テストはサービスのGUI非依存、ライブラリ保存による他設定の保護、配信者の単一判別と確定済み動画の検証、入力欄の分類規則・拒否条件を検証します。ブラウザーごとの実画面の互換性検証は別途必要です。

`test-review-regressions.ps1` は診断・結果保持・設定破損の回帰、`test-viewports.ps1` は小さい表示領域・フォーカス追従・進捗描画を独立した初期状態で検証します。配置の単体検証は `LayoutPalette`／`LayoutManagement`、実際のリサイズ検証は `ResizePalette`／`ResizeManagement` と `PanelViewport` を通します。

## 配布ZIPを作る

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
```

`dist/ChatPalette-バージョン.zip` を作成します。既存の同名ZIPは上書きしません。コード・文書・固定テストデータ・開発設定を明示的に収集し、個人の `data/`・`.git/`・テスト実行ファイルは収集しません。ZIP内の `SHA256SUMS` で内容のハッシュを確認できます。

更新時は `VERSION`、`CHANGELOG.md`、`README.md` のバージョン表記を更新し、番号が一致することを確認します。GitへのコミットやGitHubへのアップロードは、このスクリプトでは行いません。

判別方式・キャッシュ・通信の詳細は[設計資料](architecture.md)を参照してください。

## ライセンス表示

コードとドキュメントは [MIT License](../../LICENSE) で提供します。配布時は著作権表示とライセンス全文を保持してください。

## 名前の規則

- ファイル名は担当を示す。`src/settings/settings_store.ahk` はファイル入出力、`src/settings/settings_service.ahk` は共通設定の確定、`src/browser/worker_client.ahk` は常駐処理への通信を担当する。
- PowerShellの `src/browser/browser_worker.ps1` は常駐処理の入口、`src/browser/reaction_automation.ps1` はリアクション操作を担当する。
- 弾幕の識別子には `Danmaku`、全配信者で共有するデータには `Shared`、配信者別のデータには `Profile` を用いる。
- `InputProfileIndex` は入力用の配信者選択、`EditProfileIndex` は管理画面の編集対象、`TargetBrowserHwnd` は入力先ウィンドウ、`ActiveReactionJob` は実行中の処理を表す。
- 操作は `Insert`、`Delete`、`Commit`、`Read` などで目的を示す。`UndoLibraryChange` は弾幕・配信者の変更履歴を1件取り消す。
- 保存ファイルは `settings.ini`、`reaction_selectors.json`、`video_metadata_cache.json`。保存先は `data/`。

### 命名・責務分離の回帰確認

自動テストでは、表示文言を変更した状態の配置、既存INIキー名の読み書き、汎用通知とリアクション結果の独立、`browser_context` がリアクション処理・メタデータ取得を経由しないことを確認します。キー検証モジュールもGUI非依存の検査対象です。
