; Task-oriented instructions, separate from shared UI runtime.
Help(*) {
    ShowInfoDialog("使い方",BuildHelp)
}
BuildHelp(view) {
    topics := view.AddTab3("w500 h300",["弾幕を使う","弾幕を管理","リアクション","ページ操作"])
    topics.UseTab(1)
    view.AddText("x28 y52 w456 h210","1. YouTubeのチャット欄・コメント欄をクリック。`n`n2. パレットを開く。`n`n3. 弾幕を選び「選んだ弾幕を入力」。`n`n4. 内容を確認して、YouTube側で送信。`n`nパレットを開くキーや弾幕キーは、下の「ショートカットを管理」で確認・変更できます。")
    topics.UseTab(2)
    view.AddText("x28 y52 w456 h210","1. パレットの「弾幕を追加・編集」を開く。`n`n2. 編集する対象を選ぶ。共通は全チャンネル用。`n`n3. 「追加…」で弾幕名と本文を入力して保存。`n`n配信者別は「チャンネル連携…」で自動選択できます。編集対象を変えても入力対象は変わりません。`n`n一覧の変更は自動保存。「取り消す」で直前へ戻せます。")
    topics.UseTab(3)
    view.AddText("x28 y52 w456 h230","初回の準備`n「管理・ヘルプ」→「操作・サポート」。①で設定し、YouTubeの♡にマウスを重ねます。②で送らずに確認。`n`n実行`nパレットで種類・回数・間隔を選び、開始。3秒以内に♡へマウスを重ねます。停止ボタンか停止キーで中止。`n`n標準設定はキー実行に適用。「標準設定に保存」で今回の条件を保存できます。")
    topics.UseTab(4)
    view.AddText("x28 y52 w456 h230","チャット欄へフォーカス`n表示中のチャット入力欄へ移動します。`n`nチャット欄をクリア`nチャット欄へ移動し、未送信の内容を消します。`n`nリアクションUIを表示`nYouTubeの♡へマウスを移動します。クリック・送信はしません。`n`nフォーカス・クリアはコメント欄を対象にしません。現在のキーは下の「ショートカットを管理」で確認できます。")
    topics.UseTab()
    view.AddButton("x12 y324 w240 h32","ショートカットを管理…").OnEvent("Click",(*) => ShowShortcutManager())
    view.AddText("x12 y368 w500 h44","×：画面を閉じて常駐を継続。`nアプリを終了：パレットの「管理・ヘルプ」→「終了」。")
    if ManagementWindow && DllCall("IsWindowVisible","Ptr",ManagementWindow.Hwnd)
        topics.Choose(ManagementTabs.Value = 1 ? 2 : 3)
}
