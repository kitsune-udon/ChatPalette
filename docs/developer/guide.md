# 開発・配布ガイド

[READMEへ戻る](../../README.md) · [設計と責任境界](architecture.md)

## 実行構成

入口は `main.ahk`。AutoHotkey v2からWindows PowerShellの `powershell.exe` を起動し、`browser_worker.ps1` が `reaction_automation.ps1` を読み込みます。ブラウザー操作はWindows UI Automationを利用します。

PowerShell 7への切り替えは実装していません。ブラウザーの起動やYouTubeへのログインは利用者が行います。

## 配布に含めるもの

- プロジェクト直下のすべての `.ahk`・`.ps1`（同じフォルダー構成を維持）
- `README.md`、`LICENSE`、`docs/` 一式
- ソース配布の場合は `.gitignore`、`.gitattributes`、`.editorconfig`

実行に必要なのはコード一式です。利用先にAutoHotkey v2とWindows PowerShell 5.1が必要です。設定をアプリと同じ場所に保存するため、利用者が書き込める場所へ展開します。

個人の `settings.ini`、`reaction_selectors.json`、`video_metadata_cache.json` と保存途中の `.new` ファイルは配布しません。`.git` フォルダーも実行用配布物には不要です。Gitの除外設定はZIP作成時の除外を保証しないため、配布物そのものを確認してください。

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
2. 空のホーム・投稿者管理・各設定タブが表示され、サンプルが生成されないことを確認する。
3. 最初の投稿者と弾幕を追加し、保存・再起動で内容が維持されることを確認する。
4. 最後の投稿者の削除と取り消し、投稿者0件での共通弾幕編集を確認する。
5. 投稿者別・共通の未保存変更、切り替え制約、保存失敗時の保持を確認する。
6. リアクションはまず登録と「送信せずに検出を確認」で確認する。送信を伴う確認は明示的に行う。
7. 配布物に個人データ・一時ファイルが入っていないことを確認する。

開発時の自動テストは、配布プロジェクトとは別の作業領域にあります。このリポジトリには現時点で同梱していません。テスト件数を、このリポジトリだけで再現できる保証として扱わないでください。テストを移設する場合は、個人設定に依存しない固定データと、ブラウザーへ実送信しない代替処理を含めて整備します。

## 外部情報と限界

動画の投稿者情報はYouTubeのoEmbedから取得します。ブラウザーのURL欄とリアクションボタンはUI Automationで読み取ります。YouTubeやブラウザーのUI変更により検出が失敗する場合があります。

チャンネルキーは取得した投稿者URLのパスを基にしており、すべてを不変のチャンネルIDへ変換する仕組みではありません。ハンドル等が変わった場合は関連付けの見直しが必要になることがあります。

リアクションの完了はUIのボタン呼び出しが戻ったことを意味します。サーバーの受理確認や、結果不明時の再送は実装していません。

## ライセンス表示

コードとドキュメントは [MIT License](../../LICENSE) で提供します。配布時は著作権表示とライセンス全文を保持してください。
