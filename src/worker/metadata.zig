const std = @import("std");
const sdk = @import("windows.zig").sdk;
const Video = @import("uia.zig").Video;
const resolution = @import("../resolve_deadline.zig");

pub const Metadata = struct {
    author: []const u8,
    channel: []const u8,

    fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.author);
        allocator.free(self.channel);
    }
};

const Entry = struct { time: i64, result: anyerror!Metadata };
const Fetch = *const fn (std.mem.Allocator, Video, u64) anyerror!Metadata;
const Clock = *const fn () i64;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(Video, Entry) = .empty,
    fetch: Fetch = fetchMetadata,
    clock: Clock = std.time.milliTimestamp,

    pub fn deinit(self: *Cache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            if (entry.result) |value| value.deinit(self.allocator) else |_| {}
        }
        self.entries.deinit(self.allocator);
    }

    pub fn resolve(self: *Cache, video: Video, deadline: u64, target: anytype) !?Metadata {
        try resolution.check(deadline);
        const now_ms = self.clock();
        var expired: std.ArrayList(Video) = .empty;
        defer expired.deinit(self.allocator);
        var it = self.entries.iterator();
        var oldest: ?Video = null;
        var oldest_time: i64 = now_ms;
        var success_count: usize = 0;
        var failure_count: usize = 0;
        while (it.next()) |item| {
            const entry = item.value_ptr.*;
            const available = if (entry.result) |_| true else |_| false;
            const lifetime: i64 = if (available) 12 * 60 * 60 * 1000 else 5 * 1000;
            if (now_ms < entry.time or now_ms - entry.time >= lifetime) {
                try expired.append(self.allocator, item.key_ptr.*);
                continue;
            }
            if (available) {
                success_count += 1;
                if (oldest == null or entry.time < oldest_time) {
                    oldest = item.key_ptr.*;
                    oldest_time = entry.time;
                }
            } else failure_count += 1;
        }
        for (expired.items) |id| self.remove(id);
        if (self.entries.get(video)) |entry| {
            const current = try target.confirm(if (entry.result) |_| true else |_| false);
            try resolution.check(deadline);
            if (!current) return null;
            return try entry.result;
        }

        const value = self.fetch(self.allocator, video, deadline);
        if (value) |_| {} else |failure| if (failure == error.ResolveDeadlineExceeded) return failure;
        errdefer if (value) |meta| meta.deinit(self.allocator) else |_| {};
        try resolution.check(deadline);
        const current = try target.confirm(if (value) |_| true else |_| false);
        try resolution.check(deadline);
        if (!current) {
            if (value) |meta| meta.deinit(self.allocator) else |_| {}
            return null;
        }
        if (value) |_| {
            if (success_count >= 128) self.remove(oldest.?);
        } else |_| {
            if (failure_count >= 128) {
                expired.clearRetainingCapacity();
                it = self.entries.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.result) |_| {} else |_| try expired.append(self.allocator, entry.key_ptr.*);
                }
                for (expired.items) |id| self.remove(id);
            }
        }
        try resolution.check(deadline);
        try self.entries.put(self.allocator, video, .{ .time = self.clock(), .result = value });
        // From this point the cache owns the successful fetch.
        return if (value) |meta| meta else |failure| failure;
    }

    fn remove(self: *Cache, video: Video) void {
        if (self.entries.fetchRemove(video)) |removed| {
            if (removed.value.result) |meta| meta.deinit(self.allocator) else |_| {}
        }
    }
};

fn channelKey(allocator: std.mem.Allocator, address: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, address, "\r\n\t\\") != null) return error.InvalidChannel;
    const uri = try std.Uri.parse(address);
    const host = (uri.host orelse return error.InvalidChannel).percent_encoded;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or
        !(std.ascii.eqlIgnoreCase(host, "youtube.com") or std.ascii.eqlIgnoreCase(host, "www.youtube.com"))) return error.InvalidChannel;
    const raw = try uri.path.toRawMaybeAlloc(allocator);
    const key = std.mem.trimEnd(u8, raw, "/");
    for ([_][]const u8{ "/@", "/channel/", "/user/", "/c/" }) |prefix| {
        if (!std.ascii.startsWithIgnoreCase(key, prefix)) continue;
        const segment = key[prefix.len..];
        if (segment.len != 0 and std.mem.indexOfAny(u8, segment, "/\r\n\x00") == null) return key;
    }
    return error.InvalidChannel;
}

fn copyMetadata(allocator: std.mem.Allocator, json: []const u8) !Metadata {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const payload = try std.json.parseFromSliceLeaky(struct {
        author_name: []const u8,
        author_url: []const u8,
    }, scratch, json, .{ .ignore_unknown_fields = true });
    if (payload.author_name.len == 0) return error.MissingAuthor;
    const key = try channelKey(scratch, payload.author_url);
    const author = try allocator.dupe(u8, payload.author_name);
    errdefer allocator.free(author);
    return .{ .author = author, .channel = try allocator.dupe(u8, key) };
}

const RequestState = struct {
    event: sdk.HANDLE,
    refs: std.atomic.Value(u32) = .init(1),
    completion: std.atomic.Value(u32) = .init(0),
    read_count: std.atomic.Value(u32) = .init(0),
    chunk: [4096]u8 = undefined,

    fn create() !*RequestState {
        const state = try std.heap.page_allocator.create(RequestState);
        errdefer std.heap.page_allocator.destroy(state);
        state.* = .{ .event = sdk.CreateEventW(null, 0, 0, null) orelse return error.HttpSetupFailed };
        return state;
    }

    fn release(self: *RequestState) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = sdk.CloseHandle(self.event);
        std.heap.page_allocator.destroy(self);
    }

    fn register(self: *RequestState, request: sdk.HINTERNET) !void {
        var context = @intFromPtr(self);
        if (sdk.WinHttpSetOption(request, sdk.WINHTTP_OPTION_CONTEXT_VALUE, &context, @sizeOf(usize)) == sdk.FALSE)
            return error.HttpSetupFailed;
        _ = self.refs.fetchAdd(1, .monotonic);
        errdefer self.release();
        const flags = sdk.WINHTTP_CALLBACK_FLAG_SENDREQUEST_COMPLETE | sdk.WINHTTP_CALLBACK_FLAG_HEADERS_AVAILABLE |
            sdk.WINHTTP_CALLBACK_FLAG_READ_COMPLETE | sdk.WINHTTP_CALLBACK_FLAG_REQUEST_ERROR | sdk.WINHTTP_CALLBACK_FLAG_HANDLES;
        const previous = sdk.WinHttpSetStatusCallback(request, callback, flags, 0);
        if (@intFromPtr(previous) == std.math.maxInt(usize)) return error.HttpSetupFailed;
    }

    fn callback(_: sdk.HINTERNET, context: sdk.DWORD_PTR, status: sdk.DWORD, _: sdk.LPVOID, size: sdk.DWORD) callconv(.winapi) void {
        if (context == 0) return;
        const self: *RequestState = @ptrFromInt(context);
        _ = self.refs.fetchAdd(1, .monotonic);
        defer self.release();
        switch (status) {
            // WinHTTP may call back after WinHttpCloseHandle returns.
            sdk.WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING => self.release(),
            sdk.WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE,
            sdk.WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE,
            sdk.WINHTTP_CALLBACK_STATUS_READ_COMPLETE,
            sdk.WINHTTP_CALLBACK_STATUS_REQUEST_ERROR,
            => {
                self.read_count.store(size, .monotonic);
                self.completion.store(status, .release);
                _ = sdk.SetEvent(self.event);
            },
            else => {},
        }
    }

    fn awaitCompletion(self: *RequestState, expected: u32, deadline: u64, failure: anyerror) !void {
        while (true) {
            const remaining = resolution.remaining(deadline, resolution.now());
            if (remaining == 0) return error.ResolveDeadlineExceeded;
            const state = sdk.WaitForSingleObject(self.event, @intCast(@min(remaining, resolution.total_ms)));
            if (state == sdk.WAIT_TIMEOUT) continue;
            try resolution.check(deadline);
            if (state != sdk.WAIT_OBJECT_0 or self.completion.load(.acquire) != expected) return failure;
            return;
        }
    }
};

fn fetchMetadata(allocator: std.mem.Allocator, video: Video, deadline: u64) !Metadata {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    var path: [112]u8 = undefined;
    const uri = try std.fmt.bufPrint(&path, "/oembed?format=json&url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D{s}", .{&video});
    var uri_wide: [113]u16 = undefined;
    for (uri, 0..) |ch, i| uri_wide[i] = ch;
    uri_wide[uri.len] = 0;
    return fetchHttp(allocator, wide("www.youtube.com"), sdk.INTERNET_DEFAULT_HTTPS_PORT, uri_wide[0..uri.len :0], sdk.WINHTTP_FLAG_SECURE, sdk.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, deadline);
}

fn fetchHttp(allocator: std.mem.Allocator, host: [:0]const u16, port: u16, path: [*:0]const u16, flags: u32, proxy: u32, deadline: u64) !Metadata {
    try resolution.check(deadline);
    const session = sdk.WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral("ChatPalette"), proxy, null, null, sdk.WINHTTP_FLAG_ASYNC) orelse
        return error.HttpOpenFailed;
    defer _ = sdk.WinHttpCloseHandle(session);
    if (sdk.WinHttpSetTimeouts(session, 4000, 4000, 4000, 4000) == sdk.FALSE) return error.HttpSetupFailed;
    const conn = sdk.WinHttpConnect(session, host, port, 0) orelse return error.HttpConnectionFailed;
    defer _ = sdk.WinHttpCloseHandle(conn);
    const state = try RequestState.create();
    defer state.release();
    const request = sdk.WinHttpOpenRequest(conn, std.unicode.utf8ToUtf16LeStringLiteral("GET"), path, null, null, null, flags) orelse
        return error.HttpRequestFailed;
    defer _ = sdk.WinHttpCloseHandle(request);
    // Keep the request on the known HTTPS origin, which is also the only
    // oEmbed destination exposed by the UI.
    var redirect: u32 = sdk.WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (sdk.WinHttpSetOption(request, sdk.WINHTTP_OPTION_REDIRECT_POLICY, &redirect, @sizeOf(u32)) == sdk.FALSE)
        return error.HttpSetupFailed;
    try state.register(request);
    try resolution.check(deadline);
    if (sdk.WinHttpSendRequest(request, null, 0, null, 0, 0, @intFromPtr(state)) == sdk.FALSE) return error.HttpRequestFailed;
    try state.awaitCompletion(sdk.WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE, deadline, error.HttpRequestFailed);
    if (sdk.WinHttpReceiveResponse(request, null) == sdk.FALSE) return error.HttpRequestFailed;
    try state.awaitCompletion(sdk.WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE, deadline, error.HttpRequestFailed);
    var status: u32 = 0;
    var status_size: u32 = @sizeOf(u32);
    if (sdk.WinHttpQueryHeaders(request, sdk.WINHTTP_QUERY_STATUS_CODE | sdk.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null) == sdk.FALSE or
        status != 200) return error.HttpResponseFailed;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    while (true) {
        try resolution.check(deadline);
        if (sdk.WinHttpReadData(request, &state.chunk, state.chunk.len, null) == sdk.FALSE) return error.HttpReadFailed;
        try state.awaitCompletion(sdk.WINHTTP_CALLBACK_STATUS_READ_COMPLETE, deadline, error.HttpReadFailed);
        const count = state.read_count.load(.monotonic);
        if (count == 0) break;
        if (body.items.len + count > 256 * 1024) return error.MetadataTooLarge;
        try body.appendSlice(allocator, state.chunk[0..count]);
    }
    try resolution.check(deadline);
    return copyMetadata(allocator, body.items);
}

test "channel links are bound to HTTPS YouTube and the known path types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    try std.testing.expectEqualStrings("/@日本語", try channelKey(temp, "https://www.youtube.com/@%E6%97%A5%E6%9C%AC%E8%AA%9E/"));
    try std.testing.expectError(error.InvalidChannel, channelKey(temp, "https://www.youtube.com.example.com/@name"));
    try std.testing.expectError(error.InvalidChannel, channelKey(temp, "https://youtube.com/channel/foo%2fbar"));
    try std.testing.expectError(error.InvalidChannel, channelKey(temp, "http://youtube.com/@name"));
}

const Counter = struct {
    var requests: usize = 0;
    var now: i64 = 0;
    var timed_out: bool = false;

    fn clock() i64 {
        return now;
    }

    fn fetch(allocator: std.mem.Allocator, video: Video, _: u64) !Metadata {
        requests += 1;
        if (timed_out) return error.ResolveDeadlineExceeded;
        if (video[0] == 'F') return error.HttpResponseFailed;
        return copyMetadata(allocator, "{\"author_name\":\"作者\",\"author_url\":\"https://youtube.com/@name\"}");
    }
};

const TestTarget = struct {
    valid: bool = true,

    pub fn confirm(self: TestTarget, _: bool) !bool {
        return self.valid;
    }
};

test "successful and failed oEmbed requests have independent TTLs" {
    var cache: Cache = .{ .allocator = std.testing.allocator, .fetch = Counter.fetch, .clock = Counter.clock };
    defer cache.deinit();
    Counter.requests = 0;
    Counter.now = 0;
    const good = "Successful1".*;
    const bad = "FailedVideo".*;
    const deadline = resolution.now() + resolution.total_ms;
    _ = try cache.resolve(good, deadline, TestTarget{});
    try std.testing.expectError(error.HttpResponseFailed, cache.resolve(bad, deadline, TestTarget{}));
    Counter.now = 4999;
    _ = try cache.resolve(good, deadline, TestTarget{});
    try std.testing.expectError(error.HttpResponseFailed, cache.resolve(bad, deadline, TestTarget{}));
    try std.testing.expectEqual(@as(usize, 2), Counter.requests);
    Counter.now = 5000;
    try std.testing.expectError(error.HttpResponseFailed, cache.resolve(bad, deadline, TestTarget{}));
    Counter.now = 12 * 60 * 60 * 1000;
    _ = try cache.resolve(good, deadline, TestTarget{});
    try std.testing.expectEqual(@as(usize, 4), Counter.requests);
}

test "deadline expiration and obsolete targets do not publish cached metadata" {
    var cache: Cache = .{ .allocator = std.testing.allocator, .fetch = Counter.fetch, .clock = Counter.clock };
    defer cache.deinit();
    Counter.requests = 0;
    Counter.timed_out = true;
    defer Counter.timed_out = false;
    const video = "Successful1".*;
    const deadline = resolution.now() + resolution.total_ms;
    try std.testing.expectError(error.ResolveDeadlineExceeded, cache.resolve(video, 0, TestTarget{}));
    try std.testing.expectEqual(@as(usize, 0), Counter.requests);
    try std.testing.expectError(error.ResolveDeadlineExceeded, cache.resolve(video, deadline, TestTarget{}));
    Counter.timed_out = false;
    try std.testing.expectEqual(@as(?Metadata, null), try cache.resolve(video, deadline, TestTarget{ .valid = false }));
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
    try std.testing.expect((try cache.resolve(video, deadline, TestTarget{})) != null);
    try std.testing.expectEqual(@as(usize, 3), Counter.requests);
}

test "WinHTTP cancels a slow streaming response and can fetch again" {
    const Fixture = struct {
        const sockets = std.os.windows.ws2_32;
        const body = "{\"author_name\":\"Test\",\"author_url\":\"https://youtube.com/@name\"}";
        const header = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});

        fn waitReadable(stream: std.net.Stream) !void {
            var fds = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 5000) == 0) return error.FixtureTimeout;
        }

        fn send(stream: std.net.Stream, bytes: []const u8) !void {
            var remaining = bytes;
            while (remaining.len != 0) {
                const sent = sockets.send(stream.handle, remaining.ptr, @intCast(remaining.len), 0);
                if (sent <= 0) return error.FixtureSendFailed;
                remaining = remaining[@intCast(sent)..];
            }
        }

        fn handle(server: *std.net.Server, slow: bool) !void {
            try waitReadable(server.stream);
            const stream = (try server.accept()).stream;
            defer stream.close();
            try waitReadable(stream);
            var request: [2048]u8 = undefined;
            if (sockets.recv(stream.handle, &request, request.len, 0) <= 0) return error.FixtureRequestMissing;
            if (slow) std.Thread.sleep(250 * std.time.ns_per_ms);
            try send(stream, header);
            if (!slow) return send(stream, body);
            for (body[0..12], 0..) |_, i| {
                send(stream, body[i..][0..1]) catch break;
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        fn run(server: *std.net.Server, failure: *?anyerror) void {
            handle(server, true) catch |err| {
                failure.* = err;
                return;
            };
            handle(server, false) catch |err| {
                failure.* = err;
            };
        }
    };
    var server = try (try std.net.Address.parseIp4("127.0.0.1", 0)).listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();
    var failure: ?anyerror = null;
    const host = std.unicode.utf8ToUtf16LeStringLiteral("127.0.0.1");
    const path = std.unicode.utf8ToUtf16LeStringLiteral("/oembed");
    const alloc = std.testing.allocator;
    const thread = try std.Thread.spawn(.{}, Fixture.run, .{ &server, &failure });
    {
        defer thread.join();
        const start = resolution.now();
        try std.testing.expectError(error.ResolveDeadlineExceeded, fetchHttp(alloc, host, port, path, 0, sdk.WINHTTP_ACCESS_TYPE_NO_PROXY, start + 750));
        try std.testing.expect(resolution.now() - start < 1750);
        const meta = try fetchHttp(alloc, host, port, path, 0, sdk.WINHTTP_ACCESS_TYPE_NO_PROXY, resolution.now() + 5000);
        defer meta.deinit(alloc);
        try std.testing.expectEqualStrings("Test", meta.author);
        try std.testing.expectEqualStrings("/@name", meta.channel);
    }
    if (failure) |err| return err;
}
