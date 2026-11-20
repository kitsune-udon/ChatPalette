# ブラウザーワーカーの移植検証

Windows 11 x64、Zig 0.15.2のReleaseSafeで、移植したワーカーを0.8.0の `browser_worker.ps1` と比較した。表のパスは当時のローカル記録を指す。[現在のワーカー比較手順](../developer/worker-comparison.md)

| 検証 | 観測結果 | ローカル記録 |
|---|---|---|
| WPFの合成UIA画面で全10要求 | 0.8.0のAHK通信コードからPowerShell版とZig版に要求。フォーカス証明は1回限り。不正な登録スナップショットの拒否後も既存の登録を使い、確認・拒否・ホバーの送信は0回。指定ボタン4だけが1回操作された。パイプを閉じ、所有ハンドルを解放し、再起動後に登録が消えていることを確認した。 | `dist/migration/worker/wpf-final.txt` |
| 合成画面で入力欄とアドレス欄を差し替え | 同じHWNDの別の入力欄を古い証明で拒否し、新しい入力欄は通常の確認で認識。アドレス欄の置換後は新しい動画IDを取得。メタデータ取得中の動画変更は `changed`、オフライン時は `unavailable`。メタデータ取得処理の応答をテスト用に差し替えた。 | `dist/migration/worker/transitions.txt` |
| タイムアウト・実行直後の通信喪失 | 隔離ビルドの遅延要求で、後始末を含め入力確認2,800 ms、別の要求8,292 ms。ボタン操作後に応答を失う条件では `unknown`、ボタン4のイベントは1回。次の要求で別ワーカーを起動した。 | `dist/migration/worker/fault-comparison.txt` |
| 異常フレームとパイプ終了 | パイプなし、イベントなし、EOF、ゼロ長、32 KiB超過、切断したフレーム、不正UTF-8の7条件で終了コード1、起動側のハンドル解放。 | `dist/migration/worker/pipe-lifetime.txt` |
| Braveのローカル試験ページ | 通常チャット、コメント、検索欄、アドレス欄、別窓チャット形式、動画不一致、対象外サイトの7条件。各3組の2要求、合計42組がPowerShell版と独立した期待値に一致。チャット画面の動画判定初回中央値は557.213 → 64.090 ms、後続の入力欄確認は79.981 → 14.810 ms。 | `dist/migration/worker/brave-8b03ecd4/` |
| 公開YouTubeのoEmbed応答 | 合成画面のアドレス欄に既知の公開動画を設定し、両版が実際に公開oEmbedを取得。2要求とも動画ID、著者、チャンネルが一致し、入力画面への操作は0回。 | `dist/migration/worker/live-metadata-final.txt` |

互換確認では、0.8.0のAHKコードにZigの実行ファイルを直接起動する分岐だけを入れた一時コピーを使った。旧版と新ワーカーを起動するたびに実装を選び、パイプ、プロセス所有権、応答連番の処理は製品の処理を通した。合成UIAのボタン動作は提供側のイベント数で確認した。実ブラウザーやライブ配信での入力送信・リアクション操作の確認範囲は移行計画のM6を参照。

SDKの呼出試験では、Invokeが利用可能なら1回実行し、代替が必要なら役割がボタンのLegacyIAccessibleだけを1回実行し、その他の役割では実行しないことを確認した。oEmbedはWindowsの自動プロキシ設定を使う。公開oEmbedの試験環境には個別のPAC設定を用意していない。

## 2026年11月18日の確認

- 対象なしの `HWND=0` を使い、独立した期待値を両要求とも `unavailable` として比較した。ホストでは先頭順ごとに2組、計4試行が成功し、先頭・後続の8組の比較結果が一致した。証拠は `dist/migration/tools/compare-host-520c907bfbb74f319bb26e919df8bcb0/headless/comparison.json`。制限された実行環境で旧PowerShellワーカーが早期終了・タイムアウトした初回結果は `dist/migration/tools/compare-b04ea293206b46f0af7dae5366b50c49/headless/comparison.json` に保持した。
- 0.8.0と異なる入力を渡し、出力先やワーカーを作る前に拒否することを確認した。
- `test_child.zig` の試験ワーカーを使い、先頭順ごとに誤PID、誤連番、誤HWND、32,769バイト、後続要求中の終了を独立に試した。すべて期待した通信エラーとなり、後続要求中の終了では総起動回数が2回だった。試験用のURLと動画IDが公開レポートに含まれないことも確認した。証拠は `dist/migration/tools/compare-faults-6b2c6aaafc6f4ccdb5f1f61e0cd757ec`。
- 無応答の試験ワーカーを使い、8秒の動画判定と2.5秒の入力欄確認が別々にタイムアウトし、後続要求と異常な後始末がなかったことを確認した。全体は12,244 ms。証拠は `dist/migration/tools/compare-deadline-e66c29398e49488d90ab249eacbcb8be/measured/comparison.json`。
- 実ブラウザーでの比較はWindowsの入力可能なデスクトップで、対象ウィンドウと入力欄を明示して行う。
