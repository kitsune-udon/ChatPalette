; Pure policy: callers decide where to display a refusal. Stop is never blocked.
EvaluateOperation(action, state) {
    if action = "stop"
        return {Allowed:true, Reason:"", Message:""}
    if action != "input" && action != "edit" && action != "reaction" && action != "preferences"
        throw Error("不明な操作です：" action)
    if state.Refreshing
        return {Allowed:false, Reason:"refreshing", Message:"一覧を更新しています。完了後にもう一度操作してください。"}
    if action != "preferences" && state.EditorLabel != ""
        return {Allowed:false, Reason:"editor", Message:"「" state.EditorLabel "」を閉じてから実行してください。"}
    if state.ReactionActive
        return {Allowed:false, Reason:"reaction", Message:"リアクション処理中です。停止してから押してください。"}
    if state.BrowserBusy
        return {Allowed:false, Reason:"browser", Message:"前の処理を確認中です。完了後にもう一度押してください。"}
    return {Allowed:true, Reason:"", Message:""}
}
CurrentOperationState() {
    return {Refreshing:PaletteRefresh.Active || ManagementRefresh.Active, BrowserBusy:IsBrowserOperationBusy || !!ActiveChatFocus,
        ReactionActive:!!ActiveReactionJob, EditorLabel:ActiveEditorDialog ? ActiveEditorDialog.Label : (DanmakuEditorWindow ? "弾幕の編集" : "")}
}
OperationPolicy(action) {
    return EvaluateOperation(action,CurrentOperationState())
}
OperationAllowed(action) {
    return OperationPolicy(action).Allowed
}
