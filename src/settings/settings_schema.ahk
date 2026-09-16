; Shared option values and defaults. No GUI or runtime-controller dependencies.
global ReactionCounts := [1, 10, 100, 1000, 10000]
global ReactionIntervals := [0, 25, 50, 100, 200, 500, 1000]
global ReactionDefaults := {Choice: 1, Count: 1, Interval: 100, Shortcut: "^!r"}

SettingOptionLabels(values, suffix) {
    labels := []
    for value in values
        labels.Push(value suffix)
    return labels
}

ReactionIntervalLabel(value) {
    return value = 0 ? "待機なし" : value " ms"
}

ReactionIntervalLabels() {
    labels := []
    for value in ReactionIntervals
        labels.Push(ReactionIntervalLabel(value))
    return labels
}

; Explicit reaction options for defaults and one palette execution.
CreateReactionOptions(choice, count, interval, key) {
    return {Reaction: choice, Count: count, Interval: interval, Key: key}
}

global ReactionNames := ["❤️ ハート", "😁 笑顔", "🎉 お祝い", "😲 驚き", "💯 100点"]
