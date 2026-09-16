; Shared option values and defaults. No GUI or runtime-controller dependencies.
global ReactionCounts := [1, 10, 100, 1000, 10000]
global ReactionIntervals := [25, 50, 100, 200, 500, 1000]
global ReactionDefaults := {Choice: 1, Count: 1, Interval: 25, Shortcut: "^!r"}

SettingOptionLabels(values, suffix) {
    labels := []
    for value in values
        labels.Push(value suffix)
    return labels
}
