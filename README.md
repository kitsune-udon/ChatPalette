# ChatPalette

ChatPaletteは、YouTubeのライブチャットや動画のコメント・返信欄に、よく使う1行の文（弾幕）を入力するWindowsアプリです。どのチャンネルでも使う弾幕と、配信者ごとに使う弾幕を登録できます。

[ZIPを入手する](https://github.com/kitsune-udon/ChatPalette/releases) · [設定を引き継いで更新する](docs/user/maintenance.md#更新を反映する) · [変更履歴](CHANGELOG.md)

## 最初の弾幕を使う

初回は弾幕が0件です。共通の弾幕を1件作ると、どのチャンネルでも操作を試せます。

1. `ChatPalette-<版番号>.zip` を書き込みできる空のフォルダーに展開し、`ChatPalette.exe` を起動します。
2. YouTubeの入力欄をクリックし、**Ctrl＋Alt＋Q** でパレットを開きます。
3. 「弾幕を追加・編集」で「共通の弾幕」を選び、「追加…」から弾幕名「拍手」、本文「👏👏👏」を保存します。
4. 「パレットへ戻る」を押し、「拍手」を選んで「選んだ弾幕を入力」を押します。入力欄に入った本文を確かめ、投稿するときはYouTube側で送信します。

パレットを閉じた後もCtrl＋Alt＋Qで呼び出せます。アプリを終了するには「管理・ヘルプ」かタスクトレイの「終了」を選びます。

パレットが開かない、入力欄に文字が入らない場合は、[症状から確認する](docs/user/maintenance.md#症状から確認する)を参照してください。

## 必要な環境

| 項目 | 条件 |
|---|---|
| OS | Windows 11 x64。配布ZIPに同梱のEXEを展開先から起動します |
| ブラウザー | Chrome・Edge・Firefox・Brave・Opera・Vivaldiを識別します。操作できる範囲は、ブラウザーの版やYouTubeの画面によって変わります |
| 保存先 | 展開先に書き込み権限が必要です。弾幕や設定は `ChatPalette.exe` と同じフォルダーの `data/settings.db` に保存します |

## 操作と設定

- **配信者ごとに弾幕を切り替える** — チャンネルを連携すると、開いている動画に合わせてパレットの一覧が切り替わります。[弾幕と配信者](docs/user/guide.md)
- **ライブ配信でリアクションを送る** — ブラウザーごとにボタンを登録し、「② 送らずに確認」で認識を試してから実行します。[リアクションの設定・送信・停止](docs/user/reactions.md)
- **よく使う操作をキーに割り当てる** — 弾幕の入力と、現在のチャットへEnterを送る操作には、それぞれ別のキーがあります。[初期キーと割当の変更](docs/user/reference.md#ショートカット)
- **バックアップ・復元する、問題を調べる** — JSONの書き出し、設定の引き継ぎ、起動や入力で困ったときの確認先をまとめています。[保守とトラブル対処](docs/user/maintenance.md)

配布物の版は [VERSION](VERSION) で確認できます。ソースをビルドする場合は、文書一覧から開発・検証手順へ進んでください。[文書一覧（GitHub）](https://github.com/kitsune-udon/ChatPalette/blob/main/docs/index.md)

## ライセンスとYouTubeとの関係

ChatPaletteはMITライセンスで配布しています。[ライセンス全文と著作権表示](LICENSE)

非公式のツールで、Google LLC・YouTubeとの提携・承認・後援関係はありません。YouTubeはGoogle LLCの商標です。
