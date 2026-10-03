# 開発・配布手順

[文書一覧](../index.md) · [設計](architecture.md) · [検証](testing.md)

## 作業を始める

Windows、AutoHotkey v2、Windows PowerShell 5.1、Gitを用意します。追加のSQLiteやパッケージ取得は不要です。検証環境はWindows 11・64bit版AutoHotkey v2です。他環境の対応を主張するには、その環境で検証してください。

通常利用するアプリとは別フォルダーで開発します。通常起動・`--smoke`・`--quiet`は`#SingleInstance Force`により同じパスのアプリを置き換えます。構文確認には、実行も置き換えも行わないAutoHotkey標準の`/Validate`を使います。`--check`は廃止しました。

リポジトリ直下で実行します。AutoHotkeyのパスは環境に合わせて変更してください。

```powershell
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut /Validate .\main.ahk
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut .\main.ahk --smoke
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' .\main.ahk
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' .\main.ahk --quiet
```

`--smoke`は設定と画面を初期化して終了します。`--quiet`はパレットを表示せず常駐します。未知・複数の引数はデータ初期化前に拒否します。検査・配布・計測コマンドも未知の引数名を拒否します。

## 変更箇所を選ぶ

| 対象 | 最初に読む場所 |
|---|---|
| 画面・文言 | [src/ui/](../../src/ui) |
| 弾幕・配信者の編集 | [library_service.ahk](../../src/library/library_service.ahk) |
| 初期値・選択肢 | [settings_schema.ahk](../../src/settings/settings_schema.ahk) |
| 保存・入出力 | [src/settings/](../../src/settings)、[src/storage/](../../src/storage) |
| キー | [src/shortcuts/](../../src/shortcuts) |
| 入力対象の確認 | [src/input/](../../src/input)、[input_target.ps1](../../src/browser/input_target.ps1) |
| リアクション | [reaction_controller.ahk](../../src/reactions/reaction_controller.ahk)、[reaction_automation.ps1](../../src/browser/reaction_automation.ps1) |
| ワーカー通信 | [worker_client.ahk](../../src/browser/worker_client.ahk) |

変更前に[状態の所有](architecture.md#状態を混ぜない)、[保存](architecture.md#永続化の契約)、[画面更新](architecture.md#キャッシュと画面更新)の契約を確認します。

## テストを実行する

[変更とテストの対応表](testing.md#変更とテストの対応)から対象を選び、[共通ランナー](testing.md#自動テストを実行する)を使います。画面・ブラウザーの変更は、実画面の確認も追加します。配布検証は全テストを含むため、直前に同じ全検査を重ねる必要はありません。

## 文字コードとGit

`.ahk`・`.ps1`はUTF-8 BOM付き・CRLF、Markdown・Git設定・LICENSE・VERSIONはUTF-8 BOMなし・LFです。`.editorconfig`と`.gitattributes`を維持します。GitはBOMを付加しません。

`data/`、`dist/`、`tests/.tmp/`はGit対象外です。利用者のDBをテストへコピーしません。変更後に`git status --short`と`git diff --check`で差分を確認します。

## リリース手順

1. `VERSION`と未公開の変更履歴を更新し、対象差分を確認します。版番号はSemVer 2.0.0を使います。
2. Sandboxの準備後、次を実行します。
3. 終了コード0、全テストの`PASS`、ZIPと同名の`.validation.json`を確認します。
4. 実ブラウザーの確認を別レポートに残します。公開するZIPのハッシュを検証記録と照合します。
5. 公開時はタグのコミット、Releaseの版・添付名・サイズ・SHA-256を照合します。タグpush後の添付失敗は不足分を続行し、公開タグを作り直しません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-release.ps1 -Sandbox -OutputDirectory .\dist
```

検証入口は配布対象を固定し、同じコピーでソース検査・全テスト・ZIP生成を行います。ゲストへのコピー直後と検証後、梱包前にマニフェストを照合します。ZIPの全エントリーと`SHA256SUMS`自体も検証前のマニフェストに照合し、欠落・追加・内容変更・重複名・大小文字違いを拒否します。

検証記録は版、UTC日時、テスト群数、`TestEnvironment`、ZIPとソースマニフェストのSHA-256を含みます。ZIPだけが存在しても成功ではありません。出力は一時ファイルから確定し、既存ZIP・レポートを上書きしません。失敗時の資料とSandboxの成功時資料は保持するため、Sandboxを終了してから整理します。

### 配布物の範囲

[release-files.ps1](../../scripts/release-files.ps1)の許可リストが正本です。コード・文書・ライセンス・開発設定・テスト・合成データを含み、`data/`・`.git/`・一時資料を含みません。必須ファイルの欠落はコピー前に拒否します。

[build-release.ps1](../../scripts/build-release.ps1)単独のZIPは検証済み配布物ではありません。`SHA256SUMS`は内容照合用で、発行者の署名ではありません。配布はソース形式で、AutoHotkey v2とWindows PowerShell 5.1が必要です。

## 文書を更新する規則

[Plain Language Guidelines](https://digital.gov/guides/plain-language/principles)に従い、読者の目的を先に書きます。一文で一つの内容を伝え、操作する人と動詞を明示します。長い段落を手順・表へ分け、重複と不要な実装履歴を除きます。

利用手順は利用者ページ、値は[リファレンス](../user/reference.md)、復旧は[保守](../user/maintenance.md)、内部契約は[設計](architecture.md)へ集約します。実装・テストとUIラベルを照合し、公開済みの変更履歴は保持します。未公開の履歴は最終的な結果ごとにまとめます。

文書だけの変更は内容・相対リンク・見出し・配布対象を確認します。操作の意味が変わる場合は、その操作も検証します。未実施の検証を成功と書きません。`docs/`内の`.md`は配布対象です。別形式や直下の新規資料は許可リストを確認します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-source.ps1
```
