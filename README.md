# ChatPalette

YouTubeのチャット・コメントへ、保存した1行の弾幕を呼び出して入力するWindowsアプリです。共通・配信者別の弾幕、チャンネルに合わせた自動選択、ライブ配信のリアクションを扱います。

弾幕は入力だけを行います。内容を確認してYouTube側で送信してください。送信キーとリアクションの実行は送信を伴います。

## 最初の弾幕を使う

1. 配布ZIPを、書き込める空のフォルダーへ展開します。
2. 展開先の `ChatPalette.exe` を起動します。
3. YouTube動画のチャット・コメント欄をクリックします。
4. **Ctrl＋Alt＋Q**でパレットを開き、「弾幕を追加・編集」を押します。
5. 「共通の弾幕」→「追加…」で名前と本文を保存します。例：名前「拍手」、本文「👏👏👏👏👏👏」。
6. 「パレットへ戻る」で弾幕を選び、「選んだ弾幕を入力」を押します。

初回の弾幕・配信者は0件です。入力できない場合は、YouTubeの入力欄をクリックしてパレットを開き直します。キーは初期割当で、「ショートカットを管理」で変更できます。

## 必要な環境

| 項目 | 条件 |
|---|---|
| OS | Windows 11 x64 |
| 実行環境 | Windows標準のSQLiteとUI Automationを使用 |
| ブラウザー | Chrome・Edge・Firefox・Brave・Opera・Vivaldiを判定。UI Automationで対象を識別できること |
| 保存先 | アプリのフォルダーへ書き込めること |

配布ZIPに起動に必要なアプリを同梱しています。ブラウザーで取得できる情報は、版やYouTubeの表示によって変わります。

## 操作と設定

- [弾幕・配信者を追加、連携、整理する](docs/user/guide.md)
- [リアクションを準備、実行、停止する](docs/user/reactions.md)
- [キー・初期値・保存範囲を調べる](docs/user/reference.md)
- [更新・バックアップ・復元・トラブル対処](docs/user/maintenance.md)

設定は`data/settings.db`へ保存します。対応形式はDB5・JSON2だけです。旧形式の更新・復旧は[保守手順](docs/user/maintenance.md#更新を反映する)を確認してください。個人の`data/`を配布物やGitへ含めません。

「管理・ヘルプ」のJSON入出力でバックアップ・復元できます。インポートは全件置換で、置換前の値を自動バックアップします。画面の×は常駐を続けます。終了には「管理・ヘルプ」またはトレイの「終了」を使います。

版は[VERSION](VERSION)、変更は[変更履歴](CHANGELOG.md)を参照してください。

## ライセンスとYouTubeとの関係

[MIT License](LICENSE)。Copyright (c) 2026 kitsune-udon(kitsune.udon.delicious@gmail.com)

非公式のツールで、Google LLC・YouTubeとの提携・承認・後援関係はありません。YouTubeはGoogle LLCの商標です。
