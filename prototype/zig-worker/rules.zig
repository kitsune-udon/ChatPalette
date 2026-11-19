const std = @import("std");

const equalFold = std.ascii.eqlIgnoreCase;

fn among(value: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (equalFold(value, option)) return true;
    }
    return false;
}

fn validId(value: []const u8) ?[11]u8 {
    if (value.len != 11) return null;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
    }
    return value[0..11].*;
}

/// Receives the current address bar value, including addresses displayed without a scheme.
pub fn videoId(address: []const u8) ?[11]u8 {
    if (address.len == 0 or std.mem.indexOfAny(u8, address, "\r\n\t\\") != null) return null;
    var fallback = std.heap.stackFallback(512, std.heap.page_allocator);
    const alloc = fallback.get();
    const has_scheme = std.ascii.startsWithIgnoreCase(address, "https://") or std.ascii.startsWithIgnoreCase(address, "http://");
    const full = if (has_scheme) address else std.fmt.allocPrint(alloc, "https://{s}", .{address}) catch return null;
    defer if (!has_scheme) alloc.free(full);
    const uri = std.Uri.parse(full) catch return null;
    if (uri.port != null) {
        // std.Uri accepts Zig integer syntax in a port, while System.Uri requires decimal digits.
        const start = (std.mem.indexOf(u8, full, "://") orelse return null) + 3;
        const end = std.mem.indexOfAnyPos(u8, full, start, "/?#") orelse full.len;
        const authority = full[start..end];
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return null;
        for (authority[colon + 1 ..]) |ch| if (!std.ascii.isDigit(ch)) return null;
    }
    const host = (uri.host orelse return null).percent_encoded;
    const path = uri.path.percent_encoded;
    // Leave non-canonical paths unclassified rather than treating an intermediate segment as a video.
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..") or
            std.ascii.indexOfIgnoreCase(segment, "%2e") != null) return null;
    }
    if (equalFold(host, "youtu.be")) return validId(std.mem.trim(u8, path, "/"));
    if (!among(host, &.{ "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com" })) return null;
    for ([_][]const u8{ "/live/", "/shorts/", "/embed/" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(path, prefix)) {
            const rest = path[prefix.len..];
            return validId(rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len]);
        }
    }
    if (!among(path, &.{ "/watch", "/live_chat", "/live_chat_replay" })) return null;
    const query = std.mem.trimStart(u8, (uri.query orelse return null).percent_encoded, "?");
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len > 2 and std.mem.startsWith(u8, pair, "v=")) return validId(pair[2..]);
    }
    return null;
}

pub fn addressLabel(id: []const u8, name: []const u8) bool {
    if (among(id, &.{ "addressEditBox", "urlbar-input", "urlbar" })) return true;
    for ([_][]const u8{ "address", "アドレス", "search or enter" }) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return true;
    }
    const term = "検索または";
    const index = std.mem.indexOf(u8, name, term) orelse return false;
    return std.ascii.indexOfIgnoreCase(name[index + term.len ..], "URL") != null;
}

fn startsWithSpace(value: []const u8) bool {
    if (value.len == 0) return true;
    const len = std.unicode.utf8ByteSequenceLength(value[0]) catch return false;
    if (value.len < len) return false;
    const ch = std.unicode.utf8Decode(value[0..len]) catch return false;
    return switch (ch) {
        9...13, 32, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

pub fn rejectField(id: []const u8, name: []const u8) bool {
    for ([_][]const u8{ "search", "urlbar", "address" }) |word| {
        if (std.ascii.indexOfIgnoreCase(id, word) != null) return true;
    }
    for ([_][]const u8{ "検索", "Search" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(name, prefix) and startsWithSpace(name[prefix.len..])) return true;
    }
    return false;
}

pub fn chatAncestor(value: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(value, "yt-live-chat-text-input-field-renderer") != null;
}

pub fn commentAncestor(value: []const u8) bool {
    for ([_][]const u8{ "ytd-comment-simplebox-renderer", "ytd-comment-reply-renderer", "ytd-comment-dialog-renderer" }) |name| {
        if (std.ascii.indexOfIgnoreCase(value, name) != null) return true;
    }
    return false;
}

fn trimPunctuation(name: []const u8, allow_full_stop: bool) []const u8 {
    var s = name;
    while (s.len > 0) {
        if (s[s.len - 1] == '.') {
            s = s[0 .. s.len - 1];
        } else if (std.mem.endsWith(u8, s, "…") or (allow_full_stop and std.mem.endsWith(u8, s, "。"))) {
            s = s[0 .. s.len - 3];
        } else break;
    }
    return s;
}

pub fn classify(id: []const u8, name: []const u8, chat_ancestor: bool, comment_ancestor: bool) []const u8 {
    if (rejectField(id, name)) return "";
    if (equalFold(id, "input") and chat_ancestor) return "chat";
    const label = trimPunctuation(name, true);
    if (among(label, &.{ "チャット", "チャットを入力", "メッセージを入力" }) or
        among(trimPunctuation(name, false), &.{ "Chat", "Say something", "Type a message" })) return "chat";
    if (equalFold(id, "contenteditable-root") and comment_ancestor) return "comment";
    if (among(label, &.{ "コメントを追加", "公開コメントを入力", "返信を追加", "返信を入力", "Add a comment", "Add a public comment", "Add a reply", "Write a reply" })) return "comment";
    return "";
}

test "video identity retains case and accepts watch, popout, short and path URLs" {
    for ([_][]const u8{
        "www.YouTube.com/watch?list=1&v=Abc-def_012#comments",
        "https://www.youtube.com:443/watch??v=Abc-def_012&v=ZigTest0002",
        "https://youtube.com/live_chat?v=Abc-def_012",
        "http://m.youtube.com/live_chat_replay?v=Abc-def_012",
        "https://music.youtube.com/embed/Abc-def_012",
        "https://youtube.com/shorts/Abc-def_012",
        "https://youtube.com/live/Abc-def_012/",
        "youtu.be/Abc-def_012/",
    }) |url| try std.testing.expectEqualStrings("Abc-def_012", &(videoId(url) orelse return error.MissingId));
    for ([_][]const u8{
        "https://youtube.com.example.org/watch?v=Abc-def_012",
        "https://youtube.com@invalid.example/watch?v=Abc-def_012",
        "https://youtube.com:+443/watch?v=Abc-def_012",
        "https://youtube.com:4_43/watch?v=Abc-def_012",
        "https://invalid.example\\@youtube.com/watch?v=Abc-def_012",
        "https://youtube.com/watch?V=Abc-def_012",
        "https://youtube.com/watch?v=short&v=Abc-def_012",
        "https://youtube.com/live/Abc-def_012/../../other",
        "https://youtube.com/watch#v=Abc-def_012",
    }) |url| try std.testing.expect(videoId(url) == null);
}

test "input labels, structural matches and exclusions" {
    try std.testing.expectEqualStrings("chat", classify("", "チャットを入力。…", false, false));
    try std.testing.expectEqualStrings("chat", classify("Input", "", true, false));
    try std.testing.expectEqualStrings("comment", classify("contenteditable-root", "", false, true));
    try std.testing.expectEqualStrings("comment", classify("", "Add a reply...", false, false));
    try std.testing.expectEqualStrings("", classify("search-box", "チャット", true, false));
    try std.testing.expectEqualStrings("", classify("input", "検索　動画", true, false));
    try std.testing.expectEqualStrings("", classify("", "Chat。", false, false));
}
