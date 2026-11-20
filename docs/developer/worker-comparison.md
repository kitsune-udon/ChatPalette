# 旧版とZig版のワーカー比較

`compare` は同じブラウザーウィンドウに対し、動画の判定（`browser_context`）と入力欄の確認（`verify_input`）を両版に要求します。結果の一致と、ワーカーを起動した直後・起動後それぞれの応答時間を確認できます。

## 比較を実行する

1. v0.8.0の配布ZIPを用意します。CLIはZIPのSHA-256を既知の値と照合し、試験の出力先にある `legacy-0.8.0/` へ展開します。旧ワーカーはWindows PowerShell 5.1で起動します。[0.8.0の配布物](https://github.com/kitsune-udon/ChatPalette/releases/tag/v0.8.0)
2. リポジトリ直下で次を実行します。試験用ブラウザーで比較するページを開き、一覧から該当する `WindowHandle` を控えます。

```powershell
zig build install tools
$bin = '.\zig-out\bin'
& "$bin\chatpalette-tools.exe" browser list
```

3. 両版に期待する結果をJSONに書きます。次は動画ID `ZigTest0001` の合成ページで、チャット欄にフォーカスがある場合の例です。実際の試験条件に合わせて値を指定してください。

```json
{
  "request_video": "ZigTest0001",
  "detected_video": "ZigTest0001",
  "browser_context": "ok",
  "verify_input": "ok",
  "input_detail": "chat"
}
```

4. ウィンドウ番号 `123456` と、基準ZIP・期待値JSONのパスを手元の値に置き換えます。次のコマンドを実行したら、5秒の待ち時間に比較する入力欄へフォーカスを戻します。比較が終わるまで同じページとフォーカスを保ってください。

```powershell
& {
    Start-Sleep -Seconds 5
    & "$bin\chatpalette-tools.exe" compare .\dist\baseline\ChatPalette-0.8.0.zip "$bin\ChatPalette.exe" 123456 3 .\zig-out\compare-01 --expect .\dist\expected-chat.json
}
```

反復数は1〜1000です。上の例では動画判定を先に行う組を3回、入力欄確認を先に行う組を3回実行し、それぞれで旧版とZig版の起動順を交互にします。`--expect` を省くと、判定内容は両版の応答の一致だけを照合します。

## 結果を読む

- `comparison.json` の `passed` が全試行の合否です。各試行では、両版の応答に加え、指定した場合は期待値、通信や終了処理の失敗も確認します。比較する際はページとフォーカス条件、ブラウザーの版、ホストまたはゲストの構成を記録します。
- `rounds` には試行ごとの状態、動画の有無、入力欄の種類、応答時間が入ります。動画IDとUI Automationが返す詳細の元データはプロセス内で照合します。
- `summary` は両版の試行が合格し、要求の結果が `ok` だった組の集計です。初回の値にはワーカー起動を含み、後続の値は同じプロセスで次の要求を送ってから受信するまでを測ります。

両ワーカーの通信には製品と同じクライアントを使い、接続元PID、応答連番、ウィンドウハンドル、32 KiBのフレーム上限を検査します。Zig版は `ChatPalette.exe -PipeName …` で起動します。後続要求の時点でワーカーが終了していれば、その試行は失敗になります。[比較器の実装](../../tools/compare.zig)

## 2026年11月18日の確認

対象ウィンドウがない場合の比較、通信異常・タイムアウトの試験と計測時の条件は、移植時の記録にあります。[ワーカー比較器の検証記録](../history/worker-verification.md#2026年11月18日の確認)
