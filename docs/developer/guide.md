# 開発・配布手順

[文書一覧](../index.md) · [移行計画](zig-migration.md) · [検証記録](zig-migration-evidence.md)

## 作業を始める

Windows 11 x64、Zig 0.15.2 x86_64-windows、Gitを用意します。実行ファイルは `x86_64-windows-gnu` 向けにビルドし、Windows標準の `winsqlite3.dll` とUI Automationを使います。

通常利用するアプリとは別フォルダーで開発します。次のコマンドはリポジトリ直下で実行します。`--prefix` でビルドごとに出力先を変更できます。

```powershell
zig build install tools
.\zig-out\bin\ChatPalette.exe --smoke
.\zig-out\bin\ChatPalette.exe
.\zig-out\bin\ChatPalette.exe --quiet
```

`--smoke` は設定と画面を読み込んで終了し、`--quiet` はパレットを閉じた状態で常駐します。いずれも同じ展開先で稼働中の本体を終了してから引き継ぎます。未知・複数の引数はDBの作成前に拒否します。

## 変更箇所を選ぶ

| 対象 | 最初に読む場所 |
|---|---|
| 常駐・画面・キー | [native/desktop/](../../native/desktop) |
| 弾幕・配信者・設定・ファイル入出力 | [native/storage/](../../native/storage) |
| 動画判定・入力欄の確認・リアクション | [native/worker/](../../native/worker) |
| ワーカー通信 | [worker_client.zig](../../native/desktop/worker_client.zig) |
| ビルド・検査・配布 | [build.zig](../../build.zig)、[native/tools/](../../native/tools) |

変更前に[移行計画](zig-migration.md)で担当する契約と旧版の検査を確認します。

## テストを実行する

```powershell
zig build test tools
.\zig-out\bin\chatpalette-tools.exe source-check .
.\zig-out\bin\chatpalette-startup-test.exe .\zig-out\bin\ChatPalette.exe .\dist\startup-check
```

起動試験には毎回新しい出力先を指定します。実ブラウザーでの確認、隔離環境での送信イベントの計数、旧版との双方向の更新・復旧は、配布する候補のハッシュとともに記録します。0.8.0との比較では固定ZIPまたはタグの旧環境を使います。[0.8.0の検査手順](https://github.com/kitsune-udon/ChatPalette/blob/v0.8.0/docs/developer/testing.md)

## 文字コードとGit

Zig・Markdown・Git設定・LICENSE・VERSIONはUTF-8 BOMなし・LFです。`.editorconfig` と `.gitattributes` を維持します。比較用の旧版を扱う際は、その版の文字コードを維持してください。

`data/`、`dist/`、`tests/.tmp/`はGit対象外です。利用者のDBをテストへコピーしません。変更後に`git status --short`と`git diff --check`で差分を確認します。

## リリース手順

1. `VERSION` にSemVerの版番号を指定し、変更履歴を更新します。候補のコミットをクリーンな環境で開き、必要な検査が揃っていることとWindows Sandboxの稼働セッションが0件であることを確認します。
2. 次のコマンドで固定ソースをビルドし、Zigの単体試験、起動、ワーカーの故障と再開、Windows Sandboxのスモーク検査を実行します。版と出力先は候補ごとに指定します。
3. 終了コード、`ChatPalette-0.9.0.zip`、対応する `.validation.json` とSHA-256を確認します。出力先の `evidence/` に検査名・ログ・結果の照合用ハッシュを保存します。
4. 同じZIPでクリーン展開、実ブラウザーでの確認、更新と切り戻しを実施します。すべての判定を移行計画に照らして確認し、合格したZIPのハッシュを公開直前に照合します。
5. 公開後は、タグのコミット、Releaseの版・添付名・サイズ・SHA-256を照合します。タグpush後に添付だけ失敗した場合は、同じ版の不足分を添付します。

```powershell
$zig = (Get-Command zig.exe).Source
& $zig build tools
.\zig-out\bin\chatpalette-tools.exe freeze . $zig .\dist\candidate-0.9.0
```

`freeze --prepare-only` はビルド・ホストの検査とSandboxの設定作成まで実行します。候補ZIPと検証記録は、実際のSandbox検査が成功した実行で出力されます。`release` コマンドによる梱包の予行には `.rehearsal.json` が付きます。

実行したEXEと梱包するEXEをSHA-256で照合し、作業中のソースとZIP全エントリーをマニフェストに照合します。既存の出力は上書きしません。Sandboxの試験資料はホストに保存されます。結果を回収したら試験用セッションを閉じてから次を起動してください。試験ランナーは稼働中のセッションがあれば起動を見合わせます。`wsb` が使える環境ではウィンドウのないセッションも一覧から検出します。

### 配布物の範囲

許可リストは [release.zig](../../native/tools/release.zig) にあります。ZIPには `ChatPalette.exe`、版番号、変更履歴、MITライセンス、利用者向け文書、`SHA256SUMS` を入れます。照合用のハッシュと検証証拠は、公開する候補と一緒に管理してください。配布する添付ファイルに個人データやローカルの作業パスが入っていないことを確認します。

## 文書を更新する規則

[Plain Language Guidelines](https://digital.gov/guides/plain-language/principles)に従い、読者の目的を先に書きます。一文で一つの内容を伝え、操作する人と動詞を明示します。長い段落を手順・表へ分け、重複と不要な実装履歴を除きます。

利用手順は利用者ページ、値は[リファレンス](../user/reference.md)、復旧は[保守](../user/maintenance.md)、内部契約は[設計](architecture.md)へ集約します。実装・テストとUIラベルを照合し、公開済みの変更履歴は保持します。未公開の履歴は最終的な結果ごとにまとめます。

文書だけの変更は内容・相対リンク・見出し・配布対象を確認します。操作の意味が変わる場合は、その操作も検証します。配布文書の相対リンクはZIPの中でたどれることを確かめます。公開済みの変更履歴から参照する旧手順は該当版のタグにリンクします。

```powershell
.\zig-out\bin\chatpalette-tools.exe source-check .
```
