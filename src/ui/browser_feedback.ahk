; Result wording is shared by notifications and diagnostics.
BrowserOperationLabel(mode) {
    static modes := Map("なし","まだ実行していません", "resolve","配信者の自動判別", "verify","動画の確認",
        "verify_input","チャット欄・コメント欄の確認", "browser_context","現在の動画の確認",
        "chat_clear","チャット欄のクリア", "chat_focus","チャット欄への移動", "verify_chat","チャット欄の確認", "reactions_show","リアクションUIの表示操作",
        "reaction_capture","リアクションボタンの登録", "reaction_check","リアクションの検出確認",
        "reaction_send","リアクションボタンの操作", "reaction_status","リアクションの設定状態の確認")
    return modes.Get(mode,"不明な操作：" mode)
}
BrowserResultInfo(state) {
    static states := Map("inserted","保留した弾幕を入力しました", "input_cancelled","対象変更・期限切れなどにより保留した弾幕入力を中止しました", "未実行","まだ実行していません", "ok","確認できました", "registered","登録できました",
        "cleared","クリアキーを送りました（内容は未取得）", "focused","チャット欄へ移動しました", "hovered","表示用UIへマウスを移動しました（表示は未確認）",
        "configured","設定済み（認識は未確認）", "ready","操作対象を確認できました", "operated","ボタンを操作しました（受理は未確認）",
        "chat_missing","入力可能なチャット欄が見つかりません", "chat_ambiguous","チャット入力欄が複数あります",
        "focus_failed","チャット欄へのフォーカス移動を確認できませんでした",
        "wrong_input","入力欄を確認できませんでした", "changed","動画が変わったため中止しました",
        "wrong_window","操作先が変わったため中止しました", "unavailable","情報を取得できませんでした",
        "unknown","操作結果を確認できませんでした", "cancelled","中止しました", "not_registered","操作ボタンが未登録です",
        "menu_closed","リアクションメニューが見つかりません", "unsupported","操作対象を識別できませんでした",
        "cooldown","操作間隔が短いため停止しました", "save_failed","登録情報を保存できませんでした", "sync_failed","登録情報を同期できませんでした")
    static advice := Map("chat_missing","チャットの表示と入力可能な状態を確認してください。",
        "chat_ambiguous","操作する欄をクリックしてください。", "focus_failed","入力欄をクリックしてください。",
        "wrong_input","入力欄をクリックしてやり直してください。", "unsupported","YouTube側の操作対象を確認してください。",
        "unknown","自動では再実行しません。", "unavailable","YouTubeの動画ページを最前面にしてやり直してください。")
    return {Summary:states.Get(state,"不明な結果：" state),Advice:advice.Get(state,"")}
}
RecordBrowserOperation(values) {
    global LastBrowserOperation
    record := {Mode:"なし",State:"未実行",Window:0,Stage:"単一処理",Duration:0}
    for key,value in values.OwnProps()
        record.%key% := value
    LastBrowserOperation := record
}
