; Draft data and validation: independent of GUI controls.
CreateProfileReactionDraft(profile) {
    return {Profile: profile, Reaction: profile.Reaction}
}

BeginProfileReactionDraft() {
    global ProfileReactionDraft, HasUnsavedProfileReaction := false, HasUnsavedReactionSettings
    ProfileReactionDraft := GetSelectedProfile() ? CreateProfileReactionDraft(GetSelectedProfile()) : 0
    HasUnsavedReactionSettings := IsSet(HasUnsavedSharedReaction) ? HasUnsavedSharedReaction : false
}

BeginSharedReactionDraft() {
    global SharedReactionDraft, HasUnsavedSharedReaction := false, HasUnsavedReactionSettings
    SharedReactionDraft := CreateSharedReactionDraft(ReactionDefault, ReactionCount, ReactionInterval, ReactionShortcut)
    HasUnsavedReactionSettings := IsSet(HasUnsavedProfileReaction) ? HasUnsavedProfileReaction : false
}

BeginReactionEditing() {
    BeginSharedReactionDraft()
    BeginProfileReactionDraft()
}

CreateSharedReactionDraft(choice, count, interval, key) {
    return {Reaction: choice, Count: count, Interval: interval, Key: key}
}
