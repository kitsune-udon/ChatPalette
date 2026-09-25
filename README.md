# ChatPalette

**YouTubeのチャット・コメントへ、よく使う弾幕を呼び出して入力するWindowsアプリ。**

全チャンネルで使う共通弾幕と、配信者ごとの弾幕を管理できます。動画のチャンネルに合わせた自動選択と、ライブ配信のリアクション操作にも対応します。

弾幕は入力欄へ入れるところまでです。内容を確認し、YouTube側で送信してください。リアクションはYouTubeのボタンを操作するため、実行すると送信を伴います。

## 最初の弾幕を使う

1. AutoHotkey **v2** を用意し、配布物を自分が書き込めるフォルダーへ展開します。
2. フォルダー構成を変えずに `main.ahk` を起動します。
3. YouTubeの動画を開き、チャット欄またはコメント欄をクリックします。
4. **Ctrl＋Alt＋Q** でパレットを開き、「弾幕を追加・編集」を押します。
5. 編集対象に「共通の弾幕」を選び、「追加…」で名前と本文を入力して保存します。例：名前「拍手」、本文「👏👏👏👏👏👏」。
6. 「パレットへ戻る」で追加した弾幕を選び、「選んだ弾幕を入力」を押します。

YouTubeの入力欄に本文が入れば完了です。入力できない場合は、入力欄をクリックしてからパレットを開き直してください。初回は配信者・弾幕ともに0件で、上の例も自動登録されません。

記載したキーは初期割当です。「管理・ヘルプ」→「ショートカットを管理」で全操作のキーを変更できます。[割当と保存の手順](docs/user/reference.md#ショートカット)を参照してください。

## 必要な環境

| 項目 | 条件 |
|---|---|
| OS | 必要なWindows標準SQLite API・JSON関数が利用できるWindows環境。開発・検証環境はWindows 11 |
| 実行環境 | AutoHotkey v2、Windows PowerShell 5.1。SQLiteの追加インストールは不要 |
| ブラウザー | 判定対象はChrome・Edge・Firefox・Brave・Opera・Vivaldi。UI Automationで対象を識別できることが必要 |
| 保存先 | アプリのフォルダー内に設定を書き込めること |

全ブラウザーの全バージョン、Windows 10各版、32bit・ARMでの動作は確認していません。PowerShell 7への切り替え機能はありません。

## 次にしたいこと

- [配信者ごとの弾幕を使う・追加した弾幕を整理する](docs/user/guide.md)
- [リアクションを準備して実行する](docs/user/reactions.md)
- [キー・初期値・保存範囲を調べる](docs/user/reference.md)
- [入力できない・バックアップ・復元・更新](docs/user/maintenance.md)
- [ソースを変更する・テストする・配布する](docs/developer/guide.md)
- [ドキュメント全体の入口](docs/index.md)

## 設定と終了

設定は自動作成される `data/settings.db` に保存されます。配布物やGitに自分の `data/` を含めないでください。動画情報のキャッシュはメモリだけに保持します。

パネルの×で画面を閉じても常駐します。アプリを終了するには、パレットの「管理・ヘルプ」→「終了」を選びます。

版番号は[VERSION](VERSION)、更新内容は[変更履歴](CHANGELOG.md)を参照してください。

## ライセンスとYouTubeとの関係

コードとドキュメントは[MIT License](LICENSE)で提供します。Copyright (c) 2026 kitsune-udon(kitsune.udon.delicious@gmail.com)

ChatPaletteは非公式のツールです。Google LLCおよびYouTubeとの提携・承認・後援関係はありません。YouTubeはGoogle LLCの商標です。
