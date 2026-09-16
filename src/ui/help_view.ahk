; Task-oriented instructions, separate from shared UI runtime.
Help(*) {
    view := Gui("+Owner" PaletteWindow.Hwnd,"使い方")
    view.SetFont("s10","Yu Gothic UI")
    topics := view.AddTab3("w500 h300",["弾幕を使う","弾幕を管理","リアクション"])
    topics.UseTab(1)
    view.AddText("x28 y52 w456 h210","1. YouTubeのチャット欄・コメント欄をクリック。`n`n2. Ctrl＋Alt＋Qでパレットを開く。`n`n3. 弾幕を選び「選んだ弾幕を入力」。`n`n4. 内容を確認して、YouTube側で送信。`n`n配信者の弾幕はCtrl＋Alt＋1／2、共通は3／4でも入力できます。")
    topics.UseTab(2)
    view.AddText("x28 y52 w456 h210","1. パレットの「弾幕を追加・編集」を開く。`n`n2. 編集する対象を選ぶ。共通は全チャンネル用。`n`n3. 「追加…」で弾幕名と本文を入力して保存。`n`n配信者別は「チャンネル連携…」で自動選択できます。編集対象を変えても入力対象は変わりません。`n`n一覧の変更は自動保存。「取り消す」で直前へ戻せます。")
    topics.UseTab(3)
    view.AddText("x28 y52 w456 h230","初回の準備`n操作・サポート → ① ボタンを設定… → YouTubeの♡にマウスを重ねる。②で送信せずに確認できます。`n`n実行`nパレットで種類・回数・間隔を選び、開始。3秒以内に♡へマウスを重ねます。Escで停止できます。`n`n標準設定はキー実行に適用。今回の設定を保存するには「標準設定に保存」を使います。")
    topics.UseTab()
    view.AddText("x12 y324 w500 h44","×：画面を閉じて常駐を継続。`nアプリを終了：パレットの「管理・ヘルプ」→「終了」。")
    if ManagementWindow && DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd)
        topics.Choose(ManagementTabs.Value = 1 ? 2 : 3)
    view.OnEvent("Close",(*) => view.Destroy())
    view.OnEvent("Escape",(*) => view.Destroy())
    PresentWindow(view)
}
