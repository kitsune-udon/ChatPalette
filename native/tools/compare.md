# 旧版とZig版のワーカー比較

リポジトリ直下で `zig build tools` を実行すると、`chatpalette-tools.exe` を生成する。比較には、検証済みの0.8.0 ZIPと、比較する `ChatPalette.exe` を渡す。

```text
chatpalette-tools compare <0.8.0.zip> <ChatPalette.exe> <HWNDの10進表記> <各先頭順の反復数> <新規出力先> [--expect <期待値JSON>]
```

0.8.0のZIPは、記録済みのSHA-256と照合してから新規出力先の `legacy-0.8.0` に展開する。Zig版のEXEは `-PipeName` でワーカーとして直接起動する。製品と同じクライアントで、接続元PID、応答連番、ウィンドウハンドル、32 KiBのフレーム上限を確認する。`browser_context` と `verify_input` の先頭順を入れ替え、各順序で旧版とZig版の起動順も交互にする。各ワーカーを新規起動するのは一試行の先頭だけ。後続要求ではワーカーが終了済みなら失敗を返す。

期待値を使うと、両実装の結果をシナリオの正解にも照合する。たとえば既知のテスト動画のチャット入力欄は次の通り。

```json
{
  "request_video": "ZigTest0001",
  "detected_video": "ZigTest0001",
  "browser_context": "ok",
  "verify_input": "ok",
  "input_detail": "chat"
}
```

両版の一致、独立した期待値、エラー、所要時間を `comparison.json` に記録する。初回計測にはクライアントの開始からワーカー起動と応答受領までを、後続計測には同じワーカーへ要求してから応答を受け取るまでを含む。集計は試行が合格した `ok` の組を対象とする。動画IDとプロバイダーの生の詳細はプロセス内で比較し、保存する応答情報は状態、動画の有無、詳細の分類、時間に限る。

## 2026年11月18日の確認

- 対象なしの `HWND=0` を使い、独立した期待値を両要求とも `unavailable` として比較した。ホストでは先頭順ごとに2組、計4試行が成功し、先頭・後続の8組の比較結果が一致した。証拠は `dist/migration/tools/compare-host-520c907bfbb74f319bb26e919df8bcb0/headless/comparison.json`。制限された実行環境で旧PowerShellワーカーが早期終了・タイムアウトした初回結果は `dist/migration/tools/compare-b04ea293206b46f0af7dae5366b50c49/headless/comparison.json` に保持した。
- 0.8.0と異なる入力を渡し、出力先やワーカーを作る前に拒否することを確認した。
- `test_child.zig` の試験ワーカーを使い、先頭順ごとに誤PID、誤連番、誤HWND、32,769バイト、後続要求中の終了を独立に試した。すべて期待した通信エラーとなり、後続要求中の終了では総起動回数が2回だった。試験用のURLと動画IDが公開レポートに含まれないことも確認した。証拠は `dist/migration/tools/compare-faults-6b2c6aaafc6f4ccdb5f1f61e0cd757ec`。
- 無応答の試験ワーカーを使い、8秒の動画判定と2.5秒の入力欄確認が別々にタイムアウトし、後続要求と異常な後始末がなかったことを確認した。全体は12,244 ms。証拠は `dist/migration/tools/compare-deadline-e66c29398e49488d90ab249eacbcb8be/measured/comparison.json`。
- 実ブラウザーでの比較はWindowsの入力可能なデスクトップで、対象ウィンドウと入力欄を明示して行う。
