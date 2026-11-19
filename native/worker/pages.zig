const std = @import("std");
const win = @import("windows.zig");
const uia = @import("uia.zig");
const sdk = win.sdk;
const eq = std.mem.eql;
const contains = std.ascii.indexOfIgnoreCase;

pub const ChatSearch = union(enum) {
    missing,
    ambiguous,
    target: *win.Element,
};

pub fn findChat(client: *uia.Client, window: *uia.Window) !ChatSearch {
    return findChatIn(client, window, null);
}

pub fn findChatIn(client: *uia.Client, window: *uia.Window, page: ?*win.Element) !ChatSearch {
    const root = page orelse try client.root(window.hwnd);
    defer if (page == null) win.release(root);
    const focusable = try win.booleanCondition(client.automation, sdk.UIA_IsKeyboardFocusablePropertyId);
    defer win.release(focusable);
    const value = try win.booleanCondition(client.automation, sdk.UIA_IsValuePatternAvailablePropertyId);
    defer win.release(value);
    const text = try win.booleanCondition(client.automation, sdk.UIA_IsTextPatternAvailablePropertyId);
    defer win.release(text);
    const editable = try win.object(win.Condition, "CreateOrCondition", client.automation, .{ value, text });
    defer win.release(editable);
    const condition = try win.object(win.Condition, "CreateAndCondition", client.automation, .{ focusable, editable });
    defer win.release(condition);
    const list = try win.object(win.Elements, "FindAll", root, .{ sdk.TreeScope_Descendants, condition });
    defer win.release(list);
    const count = try win.get(i32, "get_Length", list, .{});
    var found: ?*win.Element = null;
    defer if (found) |element| win.release(element);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const candidate = win.object(win.Element, "GetElement", list, .{i}) catch continue;
        defer win.release(candidate);
        const kind = client.inputKind(candidate, window) catch continue;
        if (!eq(u8, kind, "chat")) continue;
        if (found != null) return .ambiguous;
        win.retain(candidate);
        found = candidate;
    }
    const target = found orelse return .missing;
    found = null;
    return .{ .target = target };
}

pub fn waitChatFocus(client: *uia.Client, window: *uia.Window, target: *win.Element, video: uia.Video) ![]const u8 {
    var timer = try std.time.Timer.start();
    while (true) {
        if (!try client.foreground(window)) return "wrong_window";
        if (try client.focusedInput(window)) |focused| {
            defer win.release(focused.element);
            if (!eq(u8, focused.kind, "chat") or !try client.same(target, focused.element)) return "focus_failed";
            const latest = try client.readVideo(window) orelse return "changed";
            if (!eq(u8, &latest, &video)) return "changed";
            if (!try client.foreground(window)) return "wrong_window";
            return if (try client.stillFocused(window, target, true)) "focused" else "focus_failed";
        }
        if (timer.read() >= 350 * std.time.ns_per_ms) break;
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    const latest = try client.readVideo(window) orelse return "changed";
    return if (eq(u8, &latest, &video)) "focus_failed" else "changed";
}

const Launcher = enum { collapsed, panel, labelled };
const Candidate = struct { kind: Launcher, panel_id: bool };

pub fn containsWord(haystack: []const u8, word: []const u8) bool {
    var offset: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(haystack, offset, word)) |start| {
        const end = start + word.len;
        if ((start == 0 or !isWord(haystack[start - 1])) and (end == haystack.len or !isWord(haystack[end]))) return true;
        offset = end;
    }
    return false;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn classifyLauncher(id: []const u8, class: []const u8, name: []const u8) ?Launcher {
    if (containsWord(class, "yt-reaction-control-panel-button-view-model")) return .collapsed;
    if (std.ascii.eqlIgnoreCase(id, "reaction-control-panel") or std.ascii.eqlIgnoreCase(id, "reaction-button")) return .panel;
    for ([_][]const u8{ "リアクション", "リアクションを送信", "リアクションを表示", "Send a reaction", "Show reactions", "React" }) |label| {
        if (std.ascii.eqlIgnoreCase(name, label)) return .labelled;
    }
    return null;
}

pub fn launcher(client: *uia.Client, window: *uia.Window, element: *win.Element) !?Candidate {
    if (!try win.flag("get_CurrentIsEnabled", element) or try win.flag("get_CurrentIsOffscreen", element)) return null;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try win.string(allocator, "get_CurrentAutomationId", element);
    const class = try win.string(allocator, "get_CurrentClassName", element);
    const name = try win.string(allocator, "get_CurrentName", element);
    const kind = classifyLauncher(id, class, name) orelse return null;
    if (!try window.belongs(element)) return null;
    var contextual = false;
    var collapsed = false;
    var current: ?*win.Element = element;
    win.retain(element);
    defer if (current) |node| win.release(node);
    for (0..45) |depth| {
        const node = current orelse break;
        const found_id = if (depth == 0) id else try win.string(allocator, "get_CurrentAutomationId", node);
        const found_class = if (depth == 0) class else try win.string(allocator, "get_CurrentClassName", node);
        for ([_][]const u8{ found_id, found_class }) |value| {
            contextual = contextual or contains(value, "yt-live-chat") != null or contains(value, "yt-reaction-control-panel") != null;
            collapsed = collapsed or containsWord(value, "collapsed-button");
        }
        const control_type = try win.get(i32, "get_CurrentControlType", node, .{});
        if (control_type == sdk.UIA_DocumentControlTypeId) {
            if (!contextual or (kind == .collapsed and !collapsed)) return null;
            return .{ .kind = kind, .panel_id = std.ascii.eqlIgnoreCase(id, "reaction-control-panel") };
        }
        if (try win.get(sdk.UIA_HWND, "get_CurrentNativeWindowHandle", node, .{}) == @as(sdk.UIA_HWND, @ptrFromInt(window.hwnd))) break;
        current = try win.objectOrNull(win.Element, "GetParentElement", client.raw, .{node});
        win.release(node);
    }
    return null;
}

const Choice = struct {
    element: ?*win.Element = null,
    count: usize = 0,

    fn record(self: *Choice, element: *win.Element) void {
        self.count += 1;
        if (self.count != 1) return;
        win.retain(element);
        self.element = element;
    }

    fn result(self: Choice) ?*win.Element {
        if (self.count != 1) return null;
        const element = self.element.?;
        win.retain(element);
        return element;
    }

    fn deinit(self: Choice) void {
        if (self.element) |element| win.release(element);
    }
};

pub fn findLauncher(client: *uia.Client, window: *uia.Window) !?*win.Element {
    const root = try client.root(window.hwnd);
    defer win.release(root);
    const button = try win.integerCondition(client.automation, sdk.UIA_ControlTypePropertyId, sdk.UIA_ButtonControlTypeId);
    defer win.release(button);
    const panel = try win.textCondition(client.automation, sdk.UIA_AutomationIdPropertyId, "reaction-control-panel");
    defer win.release(panel);
    const condition = try win.object(win.Condition, "CreateOrCondition", client.automation, .{ button, panel });
    defer win.release(condition);
    const list = try win.object(win.Elements, "FindAll", root, .{ sdk.TreeScope_Descendants, condition });
    defer win.release(list);
    const count = try win.get(i32, "get_Length", list, .{});
    var buttons: Choice = .{};
    defer buttons.deinit();
    var panels: Choice = .{};
    defer panels.deinit();
    var all: Choice = .{};
    defer all.deinit();
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const element = win.object(win.Element, "GetElement", list, .{i}) catch continue;
        defer win.release(element);
        const match = (launcher(client, window, element) catch continue) orelse continue;
        if (match.kind == .collapsed) buttons.record(element);
        if (match.panel_id) panels.record(element);
        all.record(element);
    }
    if (buttons.count != 0) return buttons.result();
    return panels.result() orelse all.result();
}

pub fn hoverPoint(client: *uia.Client, target: *win.Element) !?win.Point {
    var point: win.Point = undefined;
    var known: sdk.BOOL = sdk.FALSE;
    try win.check(win.call("GetClickablePoint", target, .{ &point, &known }));
    if (known == sdk.FALSE) return null;
    var hit = try win.objectOrNull(win.Element, "ElementFromPoint", client.automation, .{point});
    defer if (hit) |element| win.release(element);
    for (0..12) |_| {
        const element = hit orelse return null;
        if (try client.same(target, element)) return point;
        hit = try win.objectOrNull(win.Element, "GetParentElement", client.raw, .{element});
        win.release(element);
    }
    return null;
}

test "launcher labels preserve priority and require complete class words" {
    try std.testing.expectEqual(Launcher.collapsed, classifyLauncher("reaction-control-panel", "icon yt-reaction-control-panel-button-view-model active", "React").?);
    try std.testing.expectEqual(Launcher.panel, classifyLauncher("reaction-control-panel", "", "Other").?);
    try std.testing.expectEqual(Launcher.labelled, classifyLauncher("", "", "リアクションを表示").?);
    try std.testing.expect(classifyLauncher("", "not_yt-reaction-control-panel-button-view-model", "") == null);
}
