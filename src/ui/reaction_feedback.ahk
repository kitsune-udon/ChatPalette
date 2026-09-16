InitializeReactionFeedback() {
    global ReactionOverlay := 0, ReactionOverlayText := 0, ReactionOverlayStop := 0, ReactionOverlayHint := 0
}

RenderReactionStatus() {
    static lastRenderedAt := 0, lastPhase := ""
    phase := ReactionExecutionStatus.Phase
    remaining := 100-(A_TickCount-lastRenderedAt)
    if !ReactionExecutionStatus.Final && phase = lastPhase && remaining > 0 {
        SetTimer(RenderReactionStatus,-remaining)
        return
    }
    SetTimer(RenderReactionStatus,0)
    lastRenderedAt := A_TickCount, lastPhase := phase
    message := ReactionExecutionStatus.Message, final := ReactionExecutionStatus.Final
    SetTimer(HideFinishedReactionProgress, 0)
    PaletteStatusControl.Text := message
    layoutChanged := PaletteStop.Visible != !final
    PaletteStop.Visible := !final
    PaletteStop.Enabled := !final
    if layoutChanged && DllCall("IsWindowVisible","Ptr",PaletteWindow.Hwnd) {
        PaletteWindow.GetClientPos(,,&width,&height)
        if width > 0
            ResizePalette(PaletteWindow,0,width,height)
    }
    if ReactionOverlayText {
        ReactionOverlayText.Text := message
        ReactionOverlayHint.Text := ReactionProgressHint()
        ReactionOverlayStop.Visible := !final
        ReactionOverlayStop.Enabled := !final
    }
    if final
        SetTimer(HideFinishedReactionProgress, -4000)
}


ReactionProgressHint() {
    return ReactionExecutionStatus.Final ? "4秒後に表示を消します。結果はCtrl＋Alt＋Q → 管理・ヘルプ → リアクションの実行結果。"
        : "Esc：処理を停止　Ctrl＋Alt＋Q：進捗を表示"
}


HideFinishedReactionProgress() {
    if !ActiveReactionJob && ReactionOverlay
        ReactionOverlay.Hide()
}


ShowReactionProgress(*) {
    global ReactionOverlay, ReactionOverlayText, ReactionOverlayStop, ReactionOverlayHint
    if !ReactionOverlay {
        ReactionOverlay := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000", "リアクション進捗")
        ReactionOverlay.SetFont("s10", "Yu Gothic UI")
        ReactionOverlay.AddText("w360 h24", "リアクションの進捗").SetFont("bold")
        ReactionOverlayText := ReactionOverlay.AddText("w360 r6", "")
        ReactionOverlayHint := ReactionOverlay.AddText("w360 r3 c526174", "")
        ReactionOverlayStop := ReactionOverlay.AddButton("w160", "停止")
        ReactionOverlayStop.OnEvent("Click",CancelReaction)
    }
    ReactionOverlayText.Text := ReactionExecutionStatus.Message
    ReactionOverlayHint.Text := ReactionProgressHint()
    ReactionOverlayStop.Visible := !ReactionExecutionStatus.Final
    ReactionOverlayStop.Enabled := !ReactionExecutionStatus.Final
    PresentWindow(ReactionOverlay,"x20 y20",0,false)
    if ReactionExecutionStatus.Final
        SetTimer(HideFinishedReactionProgress, -4000)
}


ShowReactionDetails(*) {
    result := LastReactionResult
    details := Gui("+Owner" PaletteWindow.Hwnd, "リアクションの実行結果")
    details.SetFont("s10", "Yu Gothic UI")
    content := "最終結果：" result.Message "`r`n`r`n検出の詳細：`r`n" result.Detail
    tabs := details.AddTab3("w520 h300",["結果","調査用の詳細"])
    tabs.UseTab(1)
    details.AddText("x28 y48 w480 h24","直近の結果・操作回数・停止理由").SetFont("bold")
    details.AddEdit("x28 y80 w480 h156 ReadOnly",result.Message)
    details.AddText("x28 y246 w480 h48","回数・平均間隔はボタン操作の記録です。`nYouTube側で受理された回数・間隔ではありません。")
    tabs.UseTab(2)
    details.AddEdit("x28 y48 w480 h238 ReadOnly",result.Detail != "" ? result.Detail : "調査用の詳細はありません。")
    tabs.UseTab()
    details.AddButton("x12 y324 w180","結果と詳細をコピー").OnEvent("Click", (*) => A_Clipboard := content)
    details.OnEvent("Escape", (*) => details.Destroy())
    details.OnEvent("Close", (*) => details.Destroy())
    PresentWindow(details)
}


ReactionNotice(state, detail := "", suffix := "", job := 0) {
    messages := Map(
        "registered", "リアクションボタンを設定しました。「② 送らずに確認」で試せます。",
        "ready", "5種類のリアクションを検出できました。送信はしていません。",
        "operated", "リアクションボタンを1回操作しました。YouTube側の受理は確認できません。",
        "save_failed", "登録情報を保存できませんでした。以前の登録は保持しています。フォルダーの書き込み権限を確認してください。",
        "not_registered", "このブラウザーの初回設定が必要です。管理・ヘルプ → 操作・サポート → ① ボタンを設定…を開いてください。",
        "menu_closed", "登録したメニューが見つかりません。♡にマウスを重ねて5種類を表示してください。",
        "changed", "動画が変わったため中止しました。",
        "wrong_window", "操作先が変わったため中止しました。",
        "unsupported", "リアクションボタンを確認できませんでした。YouTubeの♡にマウスを重ね、メニューを開いて再試行してください。",
        "cooldown", "直前に操作したため、今回の入力は受け付けませんでした。",
        "unknown", "操作結果を確認できませんでした。重複防止のため自動再送しません。",
        "unavailable", "動画またはリアクションボタンを確認できませんでした。YouTubeを開いてやり直してください。")
    if !job && ActiveReactionJob
        job := ActiveReactionJob
    if suffix = "" && job && job.HasOwnProp("Completed") && job.Mode = "reaction_send"
        suffix := " 操作済み " job.Completed " / " job.Total " 回で停止。"
    message := messages.Get(state, messages["unavailable"]) suffix
    SetReactionStatus(message, true,"",detail,job,state)
    ToolTip(message)
    SetTimer(() => ToolTip(), -4000)
}
