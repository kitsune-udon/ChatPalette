const std = @import("std");
const win = @import("windows.zig");
const uia = @import("uia.zig");
const pages = @import("pages.zig");
const sdk = win.sdk;
const eq = std.mem.eql;
const contains = std.ascii.indexOfIgnoreCase;

pub const Token = struct {
    name: []const u8,
    id: []const u8,
    class: []const u8,
    type: i32,

    fn equal(a: Token, b: Token) bool {
        return a.type == b.type and eq(u8, a.name, b.name) and eq(u8, a.id, b.id) and eq(u8, a.class, b.class);
    }
};

pub const Registration = struct { browser: []const u8, tokens: [5]Token };
const Snapshot = struct {
    version: u8,
    profiles: []struct {
        browser: []const u8,
        tokens: [5]struct {
            name: []const u8,
            id: []const u8,
            class: []const u8,
            // Typed integer decoding also accepts JSON strings and integral floats.
            type: std.json.Value,
        },
    },
};
const Group = [5]*win.Element;

fn validTokens(tokens: [5]Token) bool {
    for (tokens, 0..) |token, i| {
        if (token.type < 50000 or token.type > 50040) return false;
        for (tokens[0..i]) |previous| if (token.equal(previous)) return false;
    }
    return true;
}

pub const Scope = struct { document: *win.Element, token: [32]u8 };
const CacheEntry = struct { hwnd: usize, page: ?[32]u8, group: Group };

pub const Registry = struct {
    allocator: std.mem.Allocator,
    arena: ?std.heap.ArenaAllocator = null,
    profiles: []Registration = &.{},
    cache: [8]CacheEntry = undefined,
    cache_count: usize = 0,

    fn clearCache(self: *Registry) void {
        for (self.cache[0..self.cache_count]) |entry| releaseGroup(entry.group);
        self.cache_count = 0;
    }

    pub fn deinit(self: *Registry) void {
        self.clearCache();
        if (self.arena) |*arena| arena.deinit();
    }

    pub fn configure(self: *Registry, json: []const u8) !void {
        var candidate = std.heap.ArenaAllocator.init(self.allocator);
        errdefer candidate.deinit();
        const arena = candidate.allocator();
        const value = try std.json.parseFromSliceLeaky(Snapshot, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (value.version != 1) return error.InvalidRegistrationSnapshot;
        const profiles = try arena.alloc(Registration, value.profiles.len);
        for (value.profiles, 0..) |profile, i| {
            if (!validBrowser(profile.browser)) return error.InvalidRegistrationEntry;
            var tokens: [5]Token = undefined;
            for (profile.tokens, &tokens) |raw, *token| {
                if (raw.type != .integer) return error.InvalidRegistrationEntry;
                const kind = std.math.cast(i32, raw.type.integer) orelse return error.InvalidRegistrationEntry;
                token.* = .{ .name = raw.name, .id = raw.id, .class = raw.class, .type = kind };
            }
            if (!validTokens(tokens)) return error.InvalidRegistrationEntry;
            for (value.profiles[0..i]) |p| {
                if (eq(u8, p.browser, profile.browser)) return error.DuplicateBrowser;
            }
            profiles[i] = .{ .browser = profile.browser, .tokens = tokens };
        }
        self.deinit();
        self.arena = candidate;
        self.profiles = profiles;
    }

    pub fn registration(self: Registry, browser: []const u8) ?Registration {
        for (self.profiles) |profile| if (eq(u8, browser, profile.browser)) return profile;
        return null;
    }

    // Returned group borrows references owned by this registry.
    pub fn find(self: *Registry, allocator: std.mem.Allocator, client: *uia.Client, window: *uia.Window, profile: Registration, page: ?Scope) !Lookup {
        const page_token = if (page) |scope| scope.token else null;
        for (self.cache[0..self.cache_count], 0..) |entry, i| {
            if (entry.hwnd != window.hwnd or !std.meta.eql(entry.page, page_token)) continue;
            if (validGroup(allocator, window, entry.group, profile.tokens) catch false) return .{ .group = entry.group };
            releaseGroup(entry.group);
            self.cache_count -= 1;
            self.cache[i] = self.cache[self.cache_count];
            break;
        }
        const found = try lookup(allocator, client, window, profile.tokens, if (page) |scope| scope.document else null);
        if (found.group) |group| {
            if (self.cache_count == self.cache.len) self.clearCache();
            self.cache[self.cache_count] = .{ .hwnd = window.hwnd, .page = page_token, .group = group };
            self.cache_count += 1;
        }
        return found;
    }
};

fn releaseGroup(group: Group) void {
    for (group) |element| win.release(element);
}

fn validBrowser(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or !std.ascii.isLower(value[0])) return false;
    for (value[1..]) |ch| {
        if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-')) return false;
    }
    return true;
}

pub fn browserName(allocator: std.mem.Allocator, hwnd: usize) ![]const u8 {
    const pid = win.windowProcessId(hwnd);
    if (pid == 0) return error.WindowUnavailable;
    const process = sdk.OpenProcess(sdk.PROCESS_QUERY_LIMITED_INFORMATION, sdk.FALSE, pid) orelse return error.BrowserUnavailable;
    defer _ = sdk.CloseHandle(process);
    var path: [32768]u16 = undefined;
    var len: u32 = path.len;
    if (sdk.QueryFullProcessImageNameW(process, 0, &path, &len) == sdk.FALSE) return error.BrowserUnavailable;
    const name = path[if (std.mem.lastIndexOfScalar(u16, path[0..len], '\\')) |slash| slash + 1 else 0..len];
    const without_extension = if (std.mem.lastIndexOfScalar(u16, name, '.')) |dot| name[0..dot] else name;
    const result = try std.unicode.utf16LeToUtf8Alloc(allocator, without_extension);
    errdefer allocator.free(result);
    for (result) |*ch| ch.* = std.ascii.toLower(ch.*);
    if (!validBrowser(result)) return error.BrowserUnavailable;
    return result;
}

const labels = [_][]const u8{ "ハート", "笑顔", "お祝い", "驚き", "100点" };
const aliases = [_][]const []const u8{
    &.{ "heart", "ハート", "❤", "♥" },
    &.{ "smil", "grin", "happy", "笑", "😀", "😁", "😄", "😊" },
    &.{ "party", "celebrat", "tada", "お祝い", "祝", "🎉" },
    &.{ "surpris", "shock", "astonish", "flushed", "openmouth", "open_mouth", "open-mouth", "open mouth", "驚", "びっくり", "赤面", "赤らめ", "😮", "😲", "😯", "😳" },
    &.{ "100", "hundred", "perfect", "💯" },
};

fn aliasMatches(token: Token, kind: usize) bool {
    for (aliases[kind]) |item| {
        if (contains(token.name, item) != null or contains(token.id, item) != null) return true;
    }
    return kind == 3 and (pages.containsWord(token.name, "wow") or pages.containsWord(token.id, "wow"));
}

fn record(allocator: std.mem.Allocator, comptime prefix: enum { current, cached }, element: *win.Element) !Token {
    const getName = switch (prefix) {
        .current => "get_CurrentName",
        .cached => "get_CachedName",
    };
    const getId = switch (prefix) {
        .current => "get_CurrentAutomationId",
        .cached => "get_CachedAutomationId",
    };
    const getClass = switch (prefix) {
        .current => "get_CurrentClassName",
        .cached => "get_CachedClassName",
    };
    const getType = switch (prefix) {
        .current => "get_CurrentControlType",
        .cached => "get_CachedControlType",
    };
    return .{
        .name = try win.string(allocator, getName, element),
        .id = try win.string(allocator, getId, element),
        .class = try win.string(allocator, getClass, element),
        .type = try win.get(i32, getType, element, .{}),
    };
}

fn recordCache(client: *uia.Client) !*sdk.IUIAutomationCacheRequest {
    const cache = try win.object(sdk.IUIAutomationCacheRequest, "CreateCacheRequest", client.automation, .{});
    errdefer win.release(cache);
    const properties = [_]i32{ sdk.UIA_NamePropertyId, sdk.UIA_AutomationIdPropertyId, sdk.UIA_ClassNamePropertyId, sdk.UIA_ControlTypePropertyId, sdk.UIA_IsOffscreenPropertyId, sdk.UIA_IsEnabledPropertyId };
    for (properties) |property| try win.check(win.call("AddProperty", cache, .{property}));
    return cache;
}

fn validGroup(allocator: std.mem.Allocator, window: *uia.Window, group: Group, tokens: [5]Token) !bool {
    var identities: [5][]const i32 = undefined;
    for (group, tokens, 0..) |element, token, i| {
        if (!try enabled(element) or !try window.belongs(element) or !token.equal(try record(allocator, .current, element))) return false;
        const identity = try runtimeId(allocator, element);
        if (identity.len == 0) return false;
        for (identities[0..i]) |other| if (eq(i32, other, identity)) return false;
        identities[i] = identity;
    }
    return true;
}

fn runtimeId(allocator: std.mem.Allocator, element: *win.Element) ![]const i32 {
    const array = try win.get([*c]sdk.SAFEARRAY, "GetRuntimeId", element, .{});
    if (array == null) return &.{};
    defer _ = sdk.SafeArrayDestroy(array);
    if (sdk.SafeArrayGetDim(array) != 1 or sdk.SafeArrayGetElemsize(array) != @sizeOf(i32)) return error.InvalidAutomationIdentity;
    var first: i32 = 0;
    var last: i32 = 0;
    try win.check(sdk.SafeArrayGetLBound(array, 1, &first));
    try win.check(sdk.SafeArrayGetUBound(array, 1, &last));
    if (last < first) return &.{};
    const len: usize = @intCast(@as(i64, last) - first + 1);
    if (len > 1024) return error.InvalidAutomationIdentity;
    var bytes: ?*anyopaque = null;
    try win.check(sdk.SafeArrayAccessData(array, &bytes));
    defer _ = sdk.SafeArrayUnaccessData(array);
    const data: [*]const i32 = @ptrCast(@alignCast(bytes orelse return error.InvalidAutomationIdentity));
    return allocator.dupe(i32, data[0..len]);
}

fn enabled(element: *win.Element) !bool {
    return try win.flag("get_CurrentIsEnabled", element) and !try win.flag("get_CurrentIsOffscreen", element);
}

pub const Lookup = struct { group: ?Group = null, detail: []const u8 = "" };

fn lookup(allocator: std.mem.Allocator, client: *uia.Client, window: *uia.Window, tokens: [5]Token, page: ?*win.Element) !Lookup {
    var condition: ?*win.Condition = null;
    defer if (condition) |c| win.release(c);
    for (tokens) |token| {
        const name = try win.textCondition(client.automation, sdk.UIA_NamePropertyId, token.name);
        defer win.release(name);
        const control = try win.integerCondition(client.automation, sdk.UIA_ControlTypePropertyId, token.type);
        defer win.release(control);
        const both = try win.object(win.Condition, "CreateAndCondition", client.automation, .{ name, control });
        defer win.release(both);
        if (condition) |previous| {
            condition = try win.object(win.Condition, "CreateOrCondition", client.automation, .{ previous, both });
            win.release(previous);
        } else {
            win.retain(both);
            condition = both;
        }
    }
    const cache = try recordCache(client);
    defer win.release(cache);
    const root = page orelse try client.root(window.hwnd);
    defer if (page == null) win.release(root);
    const list = try win.object(win.Elements, "FindAllBuildCache", root, .{ sdk.TreeScope_Descendants, condition.?, cache });
    defer win.release(list);
    const count = try win.get(i32, "get_Length", list, .{});
    var selected = [_]?*win.Element{null} ** 5;
    defer for (selected) |entry| {
        if (entry) |element| win.release(element);
    };
    var counts = [_]usize{0} ** 5;
    var identities = [_]std.ArrayList([]const i32){.empty} ** 5;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const element = win.object(win.Element, "GetElement", list, .{i}) catch continue;
        defer win.release(element);
        const actual = record(allocator, .cached, element) catch continue;
        for (tokens, 0..) |expected, n| {
            if (!expected.equal(actual)) continue;
            counts[n] += 1;
            if ((win.get(sdk.BOOL, "get_CachedIsEnabled", element, .{}) catch 0) == 0 or
                (win.get(sdk.BOOL, "get_CachedIsOffscreen", element, .{}) catch 1) != 0 or
                !(window.belongs(element) catch false)) continue;
            const identity = runtimeId(allocator, element) catch continue;
            for (identities[n].items) |previous| {
                if (eq(i32, previous, identity)) break;
            } else {
                try identities[n].append(allocator, identity);
            }
            if (selected[n] == null) {
                win.retain(element);
                selected[n] = element;
            }
        }
    }
    var detail: std.ArrayList(u8) = .empty;
    try detail.appendSlice(allocator, "登録したボタンを直接検索: ");
    var passed = true;
    var group: Group = undefined;
    for (tokens, 0..) |token, n| {
        if (n != 0) try detail.appendSlice(allocator, " / ");
        const visible = identities[n].items;
        try detail.print(allocator, "[{s}] 一致={d}、表示中={d}", .{ token.name, counts[n], visible.len });
        if (visible.len != 1) {
            passed = false;
            continue;
        }
        var distinct = visible[0].len != 0;
        for (identities[0..n]) |previous| {
            if (previous.items.len == 1 and eq(i32, previous.items[0], visible[0])) distinct = false;
        }
        if (!distinct) {
            try detail.print(allocator, " / [{s}] 識別情報が不明または重複", .{token.name});
            passed = false;
        }
        group[n] = selected[n].?;
    }
    if (!passed) return .{ .detail = detail.items };
    @memset(&selected, null);
    return .{ .group = group };
}

pub const Capture = struct { tokens: ?[5]Token = null, detail: []const u8 = "" };

const CaptureRecord = struct { token: Token, element: *win.Element, bounds: sdk.RECT = undefined };

fn horizontallyNear(a: sdk.RECT, b: sdk.RECT) bool {
    const width = @as(i64, a.right) - a.left;
    return @abs(@as(i64, a.left) - b.left) <= width;
}

fn appendLimited(text: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8, limit: usize) !void {
    var length = @min(value.len, limit);
    if (length < value.len) {
        while (length > 0 and value[length] & 0xc0 == 0x80) length -= 1;
    }
    try text.appendSlice(allocator, value[0..length]);
}

fn captureDetail(
    allocator: std.mem.Allocator,
    candidates: []CaptureRecord,
    matches: [5]usize,
    selected: [5]usize,
    out: *std.ArrayList(u8),
) !void {
    var recognized: usize = 0;
    for (matches) |count| if (count == 1) {
        recognized += 1;
    };
    try out.print(allocator, "操作対象={d}、識別={d}/5、不足=", .{ candidates.len, recognized });
    for ([_]bool{ false, true }) |duplicate| {
        if (duplicate) try out.appendSlice(allocator, "、重複=");
        var comma = false;
        for (labels, matches) |label, count| {
            if (if (duplicate) count > 1 else count == 0) {
                if (comma) try out.append(allocator, ',');
                try out.appendSlice(allocator, label);
                comma = true;
            }
        }
    }
    var bounds_available = recognized >= 2;
    if (bounds_available) {
        for (candidates) |*candidate| {
            candidate.bounds = win.get(sdk.RECT, "get_CurrentBoundingRectangle", candidate.element, .{}) catch {
                bounds_available = false;
                break;
            };
        }
    }
    var reference: ?sdk.RECT = null;
    var top: i64 = std.math.maxInt(i32);
    var bottom: i64 = std.math.minInt(i32);
    if (bounds_available) {
        for (matches, selected) |count, index| {
            if (count != 1) continue;
            const rect = candidates[index].bounds;
            if (reference == null and rect.right > rect.left) reference = rect;
            top = @min(top, rect.top);
            bottom = @max(bottom, rect.bottom);
        }
    }
    var names: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "、近くのボタン名=[");
    for (candidates, 0..) |candidate, n| {
        if (reference) |ref| {
            const height = @as(i64, ref.bottom) - ref.top;
            if (!horizontallyNear(ref, candidate.bounds) or candidate.bounds.top < top - height or candidate.bounds.bottom > bottom + height) continue;
        } else if (n >= 40) break;
        if (names.items.len != 0) try names.appendSlice(allocator, " | ");
        const label = try std.fmt.allocPrint(allocator, "{s} {{{s}}}", .{ candidate.token.name, candidate.token.id });
        try appendLimited(&names, allocator, label, 80);
        if (names.items.len >= 700) break;
    }
    try appendLimited(out, allocator, names.items, 700);
    try out.append(allocator, ']');
}

fn imageBelongsToButton(client: *uia.Client, image: *win.Element, button: *win.Element) !bool {
    var current = try win.objectOrNull(win.Element, "GetParentElement", client.raw, .{image});
    defer if (current) |element| win.release(element);
    for (0..7) |_| {
        const element = current orelse return false;
        if (try client.same(element, button)) return true;
        if (try win.get(i32, "get_CurrentControlType", element, .{}) == sdk.UIA_ButtonControlTypeId) return false;
        current = try win.objectOrNull(win.Element, "GetParentElement", client.raw, .{element});
        win.release(element);
    }
    return false;
}

fn matchingButton(client: *uia.Client, candidates: []const CaptureRecord, first: usize, second: usize, reaction_kind: usize) ?usize {
    const button, const image = if (candidates[first].token.type == sdk.UIA_ButtonControlTypeId)
        .{ first, second }
    else
        .{ second, first };
    if (candidates[button].token.type != sdk.UIA_ButtonControlTypeId or candidates[image].token.type != sdk.UIA_ImageControlTypeId)
        return null;
    for (0..labels.len) |kind| {
        if (kind != reaction_kind and (aliasMatches(candidates[button].token, kind) or aliasMatches(candidates[image].token, kind)))
            return null;
    }
    // Some providers expose an invokable image with the same label inside its button.
    if (!(imageBelongsToButton(client, candidates[image].element, candidates[button].element) catch false)) return null;
    return button;
}

pub fn capture(allocator: std.mem.Allocator, client: *uia.Client, window: *uia.Window, point: win.Point, page: ?*win.Element) !Capture {
    const invoke = try win.booleanCondition(client.automation, sdk.UIA_IsInvokePatternAvailablePropertyId);
    defer win.release(invoke);
    const button = try win.integerCondition(client.automation, sdk.UIA_ControlTypePropertyId, sdk.UIA_ButtonControlTypeId);
    defer win.release(button);
    const condition = try win.object(win.Condition, "CreateOrCondition", client.automation, .{ invoke, button });
    defer win.release(condition);
    const cache = try recordCache(client);
    defer win.release(cache);
    var current = try win.objectOrNull(win.Element, "ElementFromPoint", client.automation, .{point});
    defer if (current) |element| win.release(element);
    if (current == null or !try window.belongs(current.?)) return error.WrongWindow;
    var diagnostics: std.ArrayList(u8) = .empty;
    for (0..7) |depth| {
        const element = current orelse break;
        if (!try window.belongs(element)) break;
        if (page) |doc| {
            if (!try client.inDocument(window, element, doc)) {
                if (depth == 0) return error.WrongWindow;
                break;
            }
        }
        const list = try win.object(win.Elements, "FindAllBuildCache", element, .{ sdk.TreeScope_Descendants, condition, cache });
        defer win.release(list);
        const count = try win.get(i32, "get_Length", list, .{});
        var tokens: [5]Token = undefined;
        var matches = [_]usize{0} ** 5;
        var selected = [_]usize{0} ** 5;
        var duplicates: [5]usize = undefined;
        var candidates: std.ArrayList(CaptureRecord) = .empty;
        defer for (candidates.items) |candidate| win.release(candidate.element);
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            const row = win.object(win.Element, "GetElement", list, .{i}) catch continue;
            defer win.release(row);
            if ((win.get(sdk.BOOL, "get_CachedIsEnabled", row, .{}) catch 0) == 0 or
                (win.get(sdk.BOOL, "get_CachedIsOffscreen", row, .{}) catch 1) != 0) continue;
            const token = record(allocator, .cached, row) catch continue;
            const index = candidates.items.len;
            try candidates.append(allocator, .{ .token = token, .element = row });
            win.retain(row);
            for (0..5) |n| {
                if (!aliasMatches(token, n)) continue;
                matches[n] += 1;
                if (matches[n] == 1) {
                    tokens[n] = token;
                    selected[n] = index;
                }
                if (matches[n] == 2) duplicates[n] = index;
            }
        }
        for (0..5) |n| {
            if (matches[n] != 2) continue;
            const button_index = matchingButton(client, candidates.items, selected[n], duplicates[n], n) orelse continue;
            matches[n] = 1;
            selected[n] = button_index;
            tokens[n] = candidates.items[button_index].token;
        }
        if (std.mem.allEqual(usize, &matches, 1) and validTokens(tokens)) return .{ .tokens = tokens };
        if (depth != 0) try diagnostics.appendSlice(allocator, " / ");
        try diagnostics.print(allocator, "階層{d}: ", .{depth});
        try captureDetail(allocator, candidates.items, matches, selected, &diagnostics);
        current = try win.objectOrNull(win.Element, "GetParentElement", client.control, .{element});
        win.release(element);
    }
    var limit: std.ArrayList(u8) = .empty;
    try appendLimited(&limit, allocator, diagnostics.items, 5000);
    return .{ .detail = limit.items };
}

test "registration counts a reaction button and its image once but rejects other duplicates" {
    const provider = @import("uia_test_provider.zig");
    var client = provider.client();
    var menu: provider.Node = .{ .kind = sdk.UIA_GroupControlTypeId };
    var button: provider.Node = .{ .kind = sdk.UIA_ButtonControlTypeId, .parent = &menu };
    var other_button: provider.Node = .{ .kind = sdk.UIA_ButtonControlTypeId, .parent = &menu };
    var wrapper: provider.Node = .{ .kind = sdk.UIA_GroupControlTypeId, .parent = &button };
    var image: provider.Node = .{ .kind = sdk.UIA_ImageControlTypeId, .parent = &wrapper };
    var candidates = [_]CaptureRecord{
        .{ .token = .{ .name = "Heart", .id = "", .class = "", .type = button.kind }, .element = &button.element },
        .{ .token = .{ .name = "Heart", .id = "", .class = "", .type = image.kind }, .element = &image.element },
    };
    try std.testing.expectEqual(@as(?usize, 0), matchingButton(&client, &candidates, 0, 1, 0));
    try std.testing.expectEqual(@as(?usize, 0), matchingButton(&client, &candidates, 1, 0, 0));

    candidates[1].token.name = "Heart Smile";
    try std.testing.expect(matchingButton(&client, &candidates, 0, 1, 0) == null);
    candidates[1].token.name = "Heart";

    image.parent = &other_button;
    try std.testing.expect(matchingButton(&client, &candidates, 0, 1, 0) == null);
    image.parent = &wrapper;
    wrapper.parent_fails = true;
    try std.testing.expect(matchingButton(&client, &candidates, 0, 1, 0) == null);
    candidates[1].element = &other_button.element;
    candidates[1].token.type = other_button.kind;
    try std.testing.expect(matchingButton(&client, &candidates, 0, 1, 0) == null);
    for ([_]*provider.Node{ &menu, &button, &other_button, &wrapper, &image }) |node|
        try node.expectReleased();
}

test "a bad registration cannot replace live selectors and aliases cover all five kinds" {
    const json =
        \\{"version":1,"profiles":[{"browser":"brave","tokens":[{"name":"ハート","id":"","class":"btn","type":50000},{"name":"😀","id":"","class":"btn","type":50000},{"name":"お祝い","id":"","class":"btn","type":50000},{"name":"😯","id":"","class":"btn","type":50000},{"name":"100 points","id":"","class":"btn","type":50000}]}]}
    ;
    var registry: Registry = .{ .allocator = std.testing.allocator };
    defer registry.deinit();
    try registry.configure(json);
    try std.testing.expectError(error.InvalidRegistrationSnapshot, registry.configure("{\"version\":2,\"profiles\":[]}"));
    const saved = registry.registration("brave").?;
    for (saved.tokens, 0..) |token, kind| try std.testing.expect(aliasMatches(token, kind));
    try std.testing.expect(registry.registration("Brave") == null);
}

test "registration requires a JSON integer control type and preserves empty class names" {
    const allocator = std.testing.allocator;
    const registration =
        \\{"version":1,"profiles":[{"browser":"firefox","tokens":[
        \\{"name":"Heart","id":"","class":"","type":50000,"extension":{"keep":true}},
        \\{"name":"Smile","id":"","class":"","type":50000},
        \\{"name":"Party","id":"","class":"","type":50000},
        \\{"name":"Surprise","id":"","class":"","type":50000},
        \\{"name":"100 points","id":"","class":"","type":50000}]}]}
    ;
    var registry: Registry = .{ .allocator = allocator };
    defer registry.deinit();
    try registry.configure(registration);

    const changed = try std.mem.replaceOwned(u8, allocator, registration, "Heart", "Rejected");
    defer allocator.free(changed);
    for ([_][]const u8{ "\"50000\"", "50000.0", "5e4", "true", "null", "2147483648" }) |invalid_type| {
        const payload = try std.mem.replaceOwned(u8, allocator, changed, "50000", invalid_type);
        defer allocator.free(payload);
        try std.testing.expectError(error.InvalidRegistrationEntry, registry.configure(payload));
        const token = registry.registration("firefox").?.tokens[0];
        try std.testing.expectEqualStrings("Heart", token.name);
        try std.testing.expectEqualStrings("", token.class);
        try std.testing.expectEqual(@as(i32, 50000), token.type);
    }
}
