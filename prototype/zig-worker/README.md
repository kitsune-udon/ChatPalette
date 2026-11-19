# Zig版ブラウザーワーカーの試作

Windows x64で、既存のワーカー要求 `browser_context`（現在の動画ID）と `verify_input`（その動画でフォーカスされているチャット欄・コメント欄）を処理する。試作はこのフォルダーに置き、通常起動と配布には従来のPowerShellワーカーを使う。

判定と通信はZigで実装した。Windows UI AutomationのCOM呼び出しには、Zig同梱のWindowsヘッダーを使う薄いCブリッジがある。アドレス欄の要素だけをキャッシュし、値は要求ごとに読む。入力欄は所有ウィンドウ、編集可否、文書内の位置を確認し、応答直前に動画IDとフォーカス先の同一性を再確認する。確認中に本文を取得したり書き込んだりする処理はない。URLの判定はブラウザーに通常表示される形式を対象とし、ドットセグメントなどを含む非正規のパスは保守的に拒否する。[現行ワーカー](../../src/browser/browser_worker.ps1)・[入力欄の判定](uia.zig)

## ビルドと再計測

Windows x64、Zig 0.15.2、Windows PowerShell 5.1を使う。リポジトリ直下のPowerShellでビルドする。

```powershell
zig build install test --build-file prototype/zig-worker/build.zig --prefix "$PWD/dist/zig-worker" -Doptimize=ReleaseSafe
```

次の例は専用のChromiumプロファイルを開き、ブラウザー内で返すローカルHTMLを使って7条件を測る。入力可能なWindowsデスクトップで実行し、計測中は試験ウィンドウにフォーカスを置く。Brave、Edge、Chromeの順に検出し、`-BrowserPath` でも指定できる。各JSONの出力先には新しいファイル名が必要。

```powershell
$out = Join-Path "$PWD/dist/zig-worker" ([guid]::NewGuid().ToString('N'))
$exe = "$PWD/dist/zig-worker/bin/chatpalette-zig-worker.exe"
& ./prototype/zig-worker/fixture.ps1 -Scenario Chat,Comment,Search,Address,Popout,Changed,NonYouTube -Run {
    param($handle, $case)
    foreach ($first in 'browser_context','verify_input') {
        $path = Join-Path $out ($case.Scenario + '-' + $first + '.json')
        $null = & ./prototype/zig-worker/compare.ps1 -ZigExe $exe -WindowHandle $handle `
            -FixtureExpectation $case -FirstMode $first -Repeats 6 -OutputPath $path
        if ($LASTEXITCODE) { throw "比較失敗 $path" }
    }
}
```

既に開いているブラウザーも `compare.ps1 -WindowHandle` で指定できる。対象HWNDは `scripts/check-browser.ps1 -List` で取得する。公開ページでの再計測は、比較の開始前に対象画面へ戻る時間を設け、動画ページ本体または検査したい入力欄にフォーカスを置く。`-ExpectedVideo` は期待する11文字の動画ID。レポートは新旧の動画IDを実値で照合し、URL・動画ID・入力値を出力しない。`-FixtureExpectation` を付けると、新旧が同じ誤答を返した場合も終了コード1になる。

## 比較結果

2026年11月18日、Windowsビルド26300、Brave 157.1.99.57で、0.8.0（`b85df1c`）のWindows PowerShell 5.1版と比較した。条件・先頭の要求ごとに6組測り、先に起動する実装を交互に入れ替えた。毎回新しいワーカープロセスを起動し、同じHWNDへ2種類の要求を送った。各応答の連番・HWNDに加え、状態・動画ID・入力欄の種類を照合した。8条件 × 2通りの順序 × 6組 × 2要求の **192組すべて** で、新旧の判定と各条件の期待値が一致した。

表の時間は各要求を**最初に送った6回の中央値**。単位はミリ秒、各組の左がPowerShell、右がZig。プロセス起動の直前から最初の応答フレームの全受信までを測っている。ブラウザーはすでに起動済みで、OSのファイルキャッシュは消していない。表には拒否結果を返すまでの時間も載せた。[各試行の値](measurements.json)

| 条件 | 動画判定 | 動画判定の初回 ms（PS / Zig） | 入力欄確認 | 入力欄確認の初回 ms（PS / Zig） |
|---|---|---:|---|---:|
| 公開YouTube動画・ページ本体にフォーカス | ok | 540.3 / 63.5 | wrong_input | 572.8 / 67.0 |
| ローカル通常ページ・チャット欄 | ok | 524.3 / 58.4 | ok・chat | 586.5 / 66.5 |
| ローカル通常ページ・コメント欄 | ok | 516.4 / 54.3 | ok・comment | 587.6 / 66.9 |
| ローカル通常ページ・検索欄 | ok | 520.0 / 55.4 | wrong_input | 562.4 / 59.1 |
| アドレス欄にフォーカス | unavailable | 510.5 / 57.0 | unavailable | 500.9 / 55.7 |
| ローカルの別窓チャット形式（live_chat） | ok | 516.6 / 54.4 | ok・chat | 587.1 / 66.7 |
| ローカル動画と要求の動画IDが異なる | ok | 515.0 / 55.0 | changed | 523.5 / 55.9 |
| YouTube以外のローカルページ | unavailable | 525.1 / 59.5 | unavailable | 523.7 / 56.5 |

同一プロセス内の2要求目は別に計測した。たとえばローカルのチャット欄で動画を判定した直後の入力欄確認は、PowerShellが72.8 ms、Zigが15.5 msだった。初回の差には言語処理系の起動と各ワーカーの初期化も含む。実測JSONの `firstMs` と `followingMs` にそれぞれの全試行を収録した。各組の列順はPowerShell、Zigで固定している。

公開YouTubeでは未ログインの専用プロファイルで通常の動画ページを開き、動画のDOMとプレーヤー状態を確認した。最初の計測ではページ読み込み後も文書にフォーカスがなく、両版とも動画を検出できず、成功を期待した検査が失敗した。再計測ではアドレス欄のフォーカスを確認してからUI Automationでページ本体へ移し、6組とも既知の動画IDを得た。チャット・コメントの肯定例は実ブラウザーに表示したローカル試験ページによるもの。実ライブ配信の入力欄、他ブラウザー、送信動作は今回の計測範囲外。

Zigのテストは4件成功した。別途、起動先だけを試作EXEに切り替えた製品のAutoHotkey通信コードでも、実際の `youtube-helper-{GUID}` パイプ、readyイベント、連番、接続元PIDを通る2要求と、終了後のハンドル解放を確認した。[製品側の通信処理](../../src/browser/worker_client.ahk)
