const std = @import("std");
const sdk = @import("win.zig").sdk;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const Value = std.json.Value;
const maximum_message = 1024 * 1024;

pub const fixture_url = "https://www.youtube.com/watch?v=ZigTest0001&fixture=Native";
const html = @import("page.zig").html;

pub const Page = struct {
    allocator: std.mem.Allocator,
    session: sdk.HINTERNET,
    connection: sdk.HINTERNET,
    socket: sdk.HINTERNET,
    base64: []u8,
    port: u16,
    target_id: [32]u8,
    next_id: i64 = 0,

    pub fn open(allocator: std.mem.Allocator, port: u16) !Page {
        return openSelected(allocator, port, null);
    }

    fn openSelected(allocator: std.mem.Allocator, port: u16, selected: ?[32]u8) !Page {
        if (port == 0) return error.InvalidDebuggingPort;
        const session = sdk.WinHttpOpen(wide("ChatPalette offline fixture"), sdk.WINHTTP_ACCESS_TYPE_NO_PROXY, null, null, 0) orelse return error.DevToolsHttp;
        errdefer _ = sdk.WinHttpCloseHandle(session);
        if (sdk.WinHttpSetTimeouts(session, 2000, 2000, 5000, 5000) == 0) return error.DevToolsHttp;
        const connection = sdk.WinHttpConnect(session, wide("127.0.0.1"), port, 0) orelse return error.DevToolsHttp;
        errdefer _ = sdk.WinHttpCloseHandle(connection);

        const list = try request(connection, wide("/json/list"), false);
        defer _ = sdk.WinHttpCloseHandle(list);
        if (try status(list) != 200) return error.DevToolsHttp;
        const raw = try body(allocator, list);
        defer allocator.free(raw);
        const tabs = try std.json.parseFromSlice(Value, allocator, raw, .{});
        defer tabs.deinit();
        const path = try pagePath(tabs.value, port, selected);
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);
        const upgrade = try request(connection, path_w, true);
        defer _ = sdk.WinHttpCloseHandle(upgrade);
        if (try status(upgrade) != 101) return error.DevToolsUpgrade;
        const socket = sdk.WinHttpWebSocketCompleteUpgrade(upgrade, 0) orelse return error.DevToolsUpgrade;
        errdefer _ = sdk.WinHttpCloseHandle(socket);
        const base64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(html.len));
        _ = std.base64.standard.Encoder.encode(base64, html);
        return .{
            .allocator = allocator,
            .session = session,
            .connection = connection,
            .socket = socket,
            .base64 = base64,
            .port = port,
            .target_id = path[path.len - 32 ..][0..32].*,
        };
    }

    pub fn close(self: Page) void {
        _ = sdk.WinHttpCloseHandle(self.socket);
        _ = sdk.WinHttpCloseHandle(self.connection);
        _ = sdk.WinHttpCloseHandle(self.session);
        self.allocator.free(self.base64);
    }

    pub fn navigate(self: *Page) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        _ = try self.command(scratch, "Fetch.enable", .{ .patterns = .{.{ .urlPattern = "*", .requestStage = "Request" }} });
        _ = try self.command(scratch, "Page.bringToFront", .{});
        const reply = try self.command(scratch, "Page.navigate", .{ .url = fixture_url });
        if (string(reply, "errorText").len != 0) return error.FixtureNavigation;
    }

    pub fn openTab(self: *Page) !Page {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const reply = try self.command(arena.allocator(), "Target.createTarget", .{ .url = "about:blank", .newWindow = false });
        const id = try targetId(string(reply, "targetId"));
        errdefer self.closeTab(id) catch {};
        const until = sdk.GetTickCount64() + 5000;
        while (sdk.GetTickCount64() < until) {
            return openSelected(self.allocator, self.port, id) catch |failure| {
                if (failure != error.DevToolsTabPending) return failure;
                sdk.Sleep(30);
                continue;
            };
        }
        return error.DevToolsTabPending;
    }

    pub fn closeTab(self: *Page, id: [32]u8) !void {
        if (equal(&self.target_id, &id)) return error.DevToolsTab;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const reply = try self.command(arena.allocator(), "Target.closeTarget", .{ .targetId = &id });
        const result = get(reply, "success");
        if (result != .bool or !result.bool) return error.DevToolsTab;
    }

    pub fn bringToFront(self: *Page) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        _ = try self.command(arena.allocator(), "Page.bringToFront", .{});
    }

    pub fn evaluate(self: *Page, alloc: std.mem.Allocator, expression: []const u8) !Value {
        const reply = try self.command(alloc, "Runtime.evaluate", .{ .expression = expression, .returnByValue = true });
        if (get(reply, "exceptionDetails") != .null) return error.FixtureJavaScript;
        return get(get(reply, "result"), "value");
    }

    fn command(self: *Page, alloc: std.mem.Allocator, method: []const u8, parameters: anytype) !Value {
        const id = try self.send(method, parameters);
        var count: usize = 0;
        while (count < 256) : (count += 1) {
            const bytes = try self.read(alloc);
            const message = try std.json.parseFromSliceLeaky(Value, alloc, bytes, .{ .allocate = .alloc_always });
            if (get(message, "id") == .integer and get(message, "id").integer == id) {
                if (get(message, "error") != .null) return error.DevToolsCommand;
                return get(message, "result");
            }
            if (equal(string(message, "method"), "Fetch.requestPaused")) try self.onRequest(get(message, "params"));
        }
        return error.DevToolsReplyFlood;
    }

    fn onRequest(self: *Page, parameters: Value) !void {
        const req = get(parameters, "request");
        const id = string(parameters, "requestId");
        if (id.len == 0) return error.DevToolsRequest;
        if (shouldFulfill(string(parameters, "resourceType"), string(req, "method"), string(req, "url"))) {
            _ = try self.send("Fetch.fulfillRequest", .{
                .requestId = id,
                .responseCode = @as(u16, 200),
                .body = self.base64,
                .responseHeaders = .{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                    .{ .name = "Cache-Control", .value = "no-store" },
                },
            });
        } else {
            _ = try self.send("Fetch.failRequest", .{ .requestId = id, .errorReason = "BlockedByClient" });
        }
    }

    fn send(self: *Page, method: []const u8, parameters: anytype) !i64 {
        self.next_id += 1;
        const raw = try std.json.Stringify.valueAlloc(self.allocator, .{ .id = self.next_id, .method = method, .params = parameters }, .{});
        defer self.allocator.free(raw);
        if (sdk.WinHttpWebSocketSend(self.socket, sdk.WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, @constCast(raw.ptr), @intCast(raw.len)) != 0)
            return error.DevToolsSend;
        return self.next_id;
    }

    fn read(self: *const Page, alloc: std.mem.Allocator) ![]u8 {
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(alloc);
        while (true) {
            var chunk: [8192]u8 = undefined;
            var size: u32 = 0;
            var kind: sdk.WINHTTP_WEB_SOCKET_BUFFER_TYPE = undefined;
            if (sdk.WinHttpWebSocketReceive(self.socket, &chunk, chunk.len, &size, &kind) != 0) return error.DevToolsReceive;
            if (kind != sdk.WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE and kind != sdk.WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE)
                return error.DevToolsMessageType;
            if (data.items.len + size > maximum_message) return error.DevToolsMessageTooLarge;
            try data.appendSlice(alloc, chunk[0..size]);
            if (kind == sdk.WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE) return data.toOwnedSlice(alloc);
        }
    }
};

fn request(connection: sdk.HINTERNET, path: [:0]const u16, upgrade: bool) !sdk.HINTERNET {
    const handle = sdk.WinHttpOpenRequest(connection, wide("GET"), path, null, null, null, 0) orelse return error.DevToolsHttp;
    errdefer _ = sdk.WinHttpCloseHandle(handle);
    var redirect: u32 = sdk.WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (sdk.WinHttpSetOption(handle, sdk.WINHTTP_OPTION_REDIRECT_POLICY, &redirect, @sizeOf(u32)) == 0) return error.DevToolsHttp;
    if (upgrade and sdk.WinHttpSetOption(handle, sdk.WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, null, 0) == 0) return error.DevToolsUpgrade;
    if (sdk.WinHttpSendRequest(handle, null, 0, null, 0, 0, 0) == 0 or sdk.WinHttpReceiveResponse(handle, null) == 0) return error.DevToolsHttp;
    return handle;
}

fn status(handle: sdk.HINTERNET) !u32 {
    var code: u32 = 0;
    var size: u32 = @sizeOf(u32);
    if (sdk.WinHttpQueryHeaders(handle, sdk.WINHTTP_QUERY_STATUS_CODE | sdk.WINHTTP_QUERY_FLAG_NUMBER, null, &code, &size, null) == 0)
        return error.DevToolsHttp;
    return code;
}

fn body(allocator: std.mem.Allocator, handle: sdk.HINTERNET) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        var size: u32 = 0;
        if (sdk.WinHttpReadData(handle, &chunk, chunk.len, &size) == 0) return error.DevToolsHttp;
        if (size == 0) return data.toOwnedSlice(allocator);
        if (data.items.len + size > maximum_message) return error.DevToolsMessageTooLarge;
        try data.appendSlice(allocator, chunk[0..size]);
    }
}

fn singlePagePath(tabs: Value, port: u16) ![]const u8 {
    return pagePath(tabs, port, null);
}

fn pagePath(tabs: Value, port: u16, selected: ?[32]u8) ![]const u8 {
    if (tabs != .array) return error.DevToolsTab;
    var destination: ?[]const u8 = null;
    for (tabs.array.items) |tab| {
        const kind = string(tab, "type");
        if (kind.len == 0) return error.DevToolsTab;
        if (!equal(kind, "page")) continue;
        if (selected) |id| if (!equal(string(tab, "id"), &id)) continue;
        if (destination != null) return error.DevToolsMultiplePages;
        if (!equal(string(tab, "url"), "about:blank")) return error.DevToolsUnexpectedPage;
        const path = try validateEndpoint(string(tab, "webSocketDebuggerUrl"), port);
        if (selected) |id| if (!equal(path[path.len - id.len ..], &id)) return error.DevToolsEndpoint;
        destination = path;
    }
    return destination orelse error.DevToolsTabPending;
}

fn validateEndpoint(url: []const u8, port: u16) ![]const u8 {
    var origin: [30]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&origin, "ws://127.0.0.1:{d}", .{port});
    if (!std.mem.startsWith(u8, url, prefix)) return error.DevToolsEndpoint;
    const path = url[prefix.len..];
    const page_prefix = "/devtools/page/";
    if (!std.mem.startsWith(u8, path, page_prefix)) return error.DevToolsEndpoint;
    _ = try targetId(path[page_prefix.len..]);
    return path;
}

fn targetId(id: []const u8) ![32]u8 {
    if (id.len != 32) return error.DevToolsEndpoint;
    for (id) |ch| if (!std.ascii.isHex(ch)) return error.DevToolsEndpoint;
    return id[0..32].*;
}

fn shouldFulfill(resource: []const u8, method: []const u8, url: []const u8) bool {
    return equal(resource, "Document") and equal(method, "GET") and equal(url, fixture_url);
}

pub fn get(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

pub fn string(value: Value, key: []const u8) []const u8 {
    const item = get(value, key);
    return if (item == .string) item.string else "";
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "DevTools rejects remote or substituted loopback endpoints and denies other requests" {
    const id = "0123456789abcdef0123456789abcdef";
    const valid = "/devtools/page/" ++ id;
    try std.testing.expectEqualStrings(valid, try validateEndpoint("ws://127.0.0.1:8123" ++ valid, 8123));
    try std.testing.expectError(error.DevToolsEndpoint, validateEndpoint("wss://127.0.0.1:8123" ++ valid, 8123));
    try std.testing.expectError(error.DevToolsEndpoint, validateEndpoint("ws://127.0.0.1:81230" ++ valid, 8123));
    try std.testing.expectError(error.DevToolsEndpoint, validateEndpoint("ws://127.0.0.1:8123@elsewhere.invalid" ++ valid, 8123));
    try std.testing.expectError(error.DevToolsEndpoint, validateEndpoint("ws://127.0.0.1:8123" ++ valid ++ "?x=1", 8123));
    try std.testing.expectError(error.DevToolsEndpoint, validateEndpoint("ws://localhost:8123" ++ valid, 8123));
    try std.testing.expect(shouldFulfill("Document", "GET", fixture_url));
    try std.testing.expect(!shouldFulfill("Document", "POST", fixture_url));
    try std.testing.expect(!shouldFulfill("Document", "GET", fixture_url ++ "x"));
    try std.testing.expect(!shouldFulfill("Script", "GET", fixture_url));
}

test "only the absence of a DevTools page permits waiting for startup" {
    const allocator = std.testing.allocator;
    const id = "0123456789abcdef0123456789abcdef";
    const path = "/devtools/page/" ++ id;
    const tab = "{\"type\":\"page\",\"url\":\"about:blank\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:8123" ++ path ++ "\"}";
    const expected = [_]struct { json: []const u8, failure: anyerror }{
        .{ .json = "[]", .failure = error.DevToolsTabPending },
        .{ .json = "[{\"type\":\"service_worker\"}]", .failure = error.DevToolsTabPending },
        .{ .json = "[{}]", .failure = error.DevToolsTab },
        .{ .json = "[{\"type\":\"page\",\"url\":\"https://example.invalid/\"}]", .failure = error.DevToolsUnexpectedPage },
        .{ .json = "[" ++ tab ++ "," ++ tab ++ "]", .failure = error.DevToolsMultiplePages },
    };
    for (expected) |item| {
        const parsed = try std.json.parseFromSlice(Value, allocator, item.json, .{});
        defer parsed.deinit();
        try std.testing.expectError(item.failure, singlePagePath(parsed.value, 8123));
    }
    const parsed = try std.json.parseFromSlice(Value, allocator, "[" ++ tab ++ "]", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(path, try singlePagePath(parsed.value, 8123));
}

test "the additional fixture tab must match the request and the loopback websocket target" {
    const allocator = std.testing.allocator;
    const id = "0123456789abcdef0123456789abcdef";
    const other_id = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";
    const path = "/devtools/page/" ++ id;
    const original = "{\"type\":\"page\",\"url\":\"" ++ fixture_url ++ "\",\"id\":\"" ++ other_id ++ "\"}";
    const tab = "{\"type\":\"page\",\"url\":\"about:blank\",\"id\":\"" ++ id ++ "\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:8123" ++ path ++ "\"}";
    const parsed = try std.json.parseFromSlice(Value, allocator, "[" ++ original ++ "," ++ tab ++ "]", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(path, try pagePath(parsed.value, 8123, id.*));
    try std.testing.expectError(error.DevToolsUnexpectedPage, pagePath(parsed.value, 8123, other_id.*));
    const redirected = "{\"type\":\"page\",\"url\":\"about:blank\",\"id\":\"" ++ id ++ "\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:8123/devtools/page/" ++ other_id ++ "\"}";
    const wrong = try std.json.parseFromSlice(Value, allocator, "[" ++ redirected ++ "]", .{});
    defer wrong.deinit();
    try std.testing.expectError(error.DevToolsEndpoint, pagePath(wrong.value, 8123, id.*));
}
