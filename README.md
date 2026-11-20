# ChatPalette

ChatPaletteは、YouTubeのライブチャットや動画のコメント・返信欄に、よく使う1行の文（弾幕）を入力するWindowsアプリです。どのチャンネルでも使う弾幕と、配信者ごとに使う弾幕を登録できます。

## 最初の弾幕を使う

0.8.0の弾幕や設定を引き継ぐ方は、先に[更新手順](docs/user/maintenance.md#更新を反映する)を確認してください。初めて使う場合は空のライブラリから始まります。

1. GitHubの配布ページから `ChatPalette-<版番号>.zip` をダウンロードし、書き込みできる空のフォルダーに展開します。[配布ページ](https://github.com/kitsune-udon/ChatPalette/releases)
2. 展開先の **`ChatPalette.exe`** を起動します。YouTubeで使いたいチャット欄かコメント欄をクリックし、初期キーの **Ctrl＋Alt＋Q** でパレットを開きます。
3. 「弾幕を追加・編集」を開き、「共通の弾幕」を選んで「追加…」を押します。たとえば弾幕名に「拍手」、本文に「👏👏👏」と入力して「保存」を押します。
4. 「パレットへ戻る」を押し、一覧から「拍手」を選んで「選んだ弾幕を入力」を押します。
5. YouTubeの入力欄に「👏👏👏」が入ります。内容を確認し、送信したいときにYouTubeで送信します。

パレットを閉じた後もCtrl＋Alt＋Qで呼び出せます。アプリを終了するには「管理・ヘルプ」かタスクトレイの「終了」を選びます。

## 必要な環境

| 項目 | 条件 |
|---|---|
| OS | Windows 11 x64。配布ZIPに同梱のZig版をそのまま起動できます |
| ブラウザー | Chrome・Edge・Firefox・Brave・Opera・Vivaldiを識別します。操作できる範囲は、ブラウザーの版やYouTubeの画面によって変わります |
| 保存先 | 展開先に書き込み権限が必要です。弾幕や設定は `ChatPalette.exe` と同じフォルダーの `data/settings.db` に保存します |

## 操作と設定

- **配信者ごとに弾幕を切り替える** — チャンネルを連携すると、開いている動画に合わせてパレットの一覧が切り替わります。[弾幕と配信者](docs/user/guide.md)
- **ライブ配信でリアクションを送る** — ブラウザーごとにボタンを登録し、「② 送らずに確認」で認識を試してから実行します。[リアクションの設定・送信・停止](docs/user/reactions.md)
- **よく使う操作をキーに割り当てる** — 弾幕の入力と、現在のチャットへEnterを送る操作には、それぞれ別のキーがあります。[初期キーと割当の変更](docs/user/reference.md#ショートカット)
- **バックアップ・復元する、問題を調べる** — JSONの書き出し、設定の引き継ぎ、起動や入力で困ったときの確認先をまとめています。[保守とトラブル対処](docs/user/maintenance.md)

この配布物の版は [VERSION](VERSION)、版ごとの変更点は[変更履歴](CHANGELOG.md)で確認できます。ソースからビルドする場合は、リポジトリの `docs/index.md` から開発・検証手順を参照してください。[文書一覧（GitHub）](https://github.com/kitsune-udon/ChatPalette/blob/main/docs/index.md) [既存の data/settings.db で開発ビルドを起動する手順](https://github.com/kitsune-udon/ChatPalette/blob/main/docs/developer/guide.md#既存の設定で開発ビルドを起動する)

## ライセンスとYouTubeとの関係

ChatPaletteはMITライセンスで配布しています。[ライセンス全文と著作権表示](LICENSE)

非公式のツールで、Google LLC・YouTubeとの提携・承認・後援関係はありません。YouTubeはGoogle LLCの商標です。
