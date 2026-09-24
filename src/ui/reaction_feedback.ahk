InitializeReactionFeedback() {
    global ReactionOverlayBuilding := false
    global ReactionOverlay := 0, ReactionOverlayText := 0, ReactionOverlayStop := 0, ReactionOverlayHint := 0
}

RenderReactionStatus() {
    static updating := false
    if updating {
        SetTimer(RenderReactionStatus,-1)
        return
    }
    updating := true
    try RenderLatestReactionStatus()
    finally updating := false
}

RenderLatestReactionStatus() {
    static lastRenderedAt := 0, lastPhase := ""
    snapshot := ReactionExecutionStatus
    phase := snapshot.Phase
    remaining := 100-(A_TickCount-lastRenderedAt)
    if !snapshot.Final && phase = lastPhase && remaining > 0 {
        SetTimer(RenderReactionStatus,-remaining)
        return
    }
    SetTimer(RenderReactionStatus,0)
    lastRenderedAt := A_TickCount, lastPhase := phase
    message := snapshot.Message, final := snapshot.Final
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
    if ReactionOverlay
        RenderReactionOverlay(snapshot)
    if final
        SetTimer(HideFinishedReactionProgress, -4000)
    if snapshot != ReactionExecutionStatus
        SetTimer(RenderReactionStatus,-1)
}


RenderReactionOverlay(snapshot) {
    ReactionOverlayText.Text := snapshot.Message
    ReactionOverlayHint.Text := ReactionProgressHint(snapshot)
    ReactionOverlayStop.Visible := !snapshot.Final
    ReactionOverlayStop.Enabled := !snapshot.Final
}

ReactionProgressHint(snapshot) {
    return snapshot.Final ? "4秒後に表示を消します。結果は" ShortcutKeyLabel(GetShortcutKey("palette")) " → 管理・ヘルプ → リアクションの実行結果。"
        : "" ShortcutKeyLabel(GetShortcutKey("stop")) "：処理を停止　" ShortcutKeyLabel(GetShortcutKey("palette")) "：進捗を表示"
}


HideFinishedReactionProgress() {
    if !ActiveReactionJob && ReactionOverlay
        ReactionOverlay.Hide()
}


ShowReactionProgress(*) {
    global ReactionOverlay, ReactionOverlayText, ReactionOverlayStop, ReactionOverlayHint
    global ReactionOverlayBuilding
    if ReactionOverlayBuilding
        return
    if !ReactionOverlay {
        ReactionOverlayBuilding := true
        try {
            view := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000", "リアクション進捗")
            view.SetFont("s10", "Yu Gothic UI")
            view.AddText("w360 h24", "リアクションの進捗").SetFont("bold")
            text := view.AddText("w360 r6", "")
            hint := view.AddText("w360 r3 c526174", "")
            stop := view.AddButton("w160", "停止")
            stop.OnEvent("Click",CancelReaction)
            ; Publish a complete view; no renderer observes construction in progress.
            previousCritical := A_IsCritical
            Critical("On")
            try {
                ReactionOverlayText := text, ReactionOverlayHint := hint, ReactionOverlayStop := stop
                ReactionOverlay := view
            } finally Critical(previousCritical)
        } catch as failure {
            if IsSet(view)
                view.Destroy()
            throw failure
        } finally ReactionOverlayBuilding := false
    }
    snapshot := ReactionExecutionStatus
    RenderReactionOverlay(snapshot)
    PresentWindow(ReactionOverlay,"x20 y20",0,false)
    if snapshot.Final
        SetTimer(HideFinishedReactionProgress, -4000)
    if snapshot != ReactionExecutionStatus
        SetTimer(RenderReactionStatus,-1)
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
        "sync_failed", "登録情報を操作用プロセスへ反映できませんでした。送信せずに停止しました。次の操作で再同期します。",
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
    if suffix = "" && job && job.Mode = "reaction_send"
        suffix := " 操作済み " job.Completed " / " job.Total " 回で停止。"
    message := messages.Get(state, messages["unavailable"]) suffix
    SetReactionStatus(message, true,"",detail,job,state)
    ShowStatusTip(message,4000)
}
