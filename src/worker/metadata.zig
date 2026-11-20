const std = @import("std");
const sdk = @import("windows.zig").sdk;
const Video = @import("uia.zig").Video;

pub const Metadata = struct {
    author: []const u8,
    channel: []const u8,

    fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.author);
        allocator.free(self.channel);
    }
};

const Entry = struct { time: i64, result: anyerror!Metadata };
const Fetch = *const fn (std.mem.Allocator, Video) anyerror!Metadata;
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

    pub fn resolve(self: *Cache, video: Video) !Metadata {
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
        if (self.entries.get(video)) |entry| return entry.result;

        const value = self.fetch(self.allocator, video);
        errdefer if (value) |meta| meta.deinit(self.allocator) else |_| {};
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

fn fetchMetadata(allocator: std.mem.Allocator, video: Video) !Metadata {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    const session = sdk.WinHttpOpen(wide("ChatPalette"), sdk.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.HttpOpenFailed;
    defer _ = sdk.WinHttpCloseHandle(session);
    if (sdk.WinHttpSetTimeouts(session, 4000, 4000, 4000, 4000) == sdk.FALSE) return error.HttpSetupFailed;
    const conn = sdk.WinHttpConnect(session, wide("www.youtube.com"), sdk.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse
        return error.HttpConnectionFailed;
    defer _ = sdk.WinHttpCloseHandle(conn);
    var path: [112]u8 = undefined;
    const uri = try std.fmt.bufPrint(&path, "/oembed?format=json&url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D{s}", .{&video});
    var uri_wide: [113]u16 = undefined;
    for (uri, 0..) |ch, i| uri_wide[i] = ch;
    uri_wide[uri.len] = 0;
    const request = sdk.WinHttpOpenRequest(conn, wide("GET"), &uri_wide, null, null, null, sdk.WINHTTP_FLAG_SECURE) orelse
        return error.HttpRequestFailed;
    defer _ = sdk.WinHttpCloseHandle(request);
    // Keep the request on the known HTTPS origin, which is also the only
    // oEmbed destination exposed by the UI.
    var redirect: u32 = sdk.WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (sdk.WinHttpSetOption(request, sdk.WINHTTP_OPTION_REDIRECT_POLICY, &redirect, @sizeOf(u32)) == sdk.FALSE or
        sdk.WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == sdk.FALSE or
        sdk.WinHttpReceiveResponse(request, null) == sdk.FALSE) return error.HttpRequestFailed;
    var status: u32 = 0;
    var status_size: u32 = @sizeOf(u32);
    if (sdk.WinHttpQueryHeaders(request, sdk.WINHTTP_QUERY_STATUS_CODE | sdk.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null) == sdk.FALSE or
        status != 200) return error.HttpResponseFailed;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        var count: u32 = 0;
        if (sdk.WinHttpReadData(request, &chunk, chunk.len, &count) == sdk.FALSE) return error.HttpReadFailed;
        if (count == 0) break;
        if (body.items.len + count > 256 * 1024) return error.MetadataTooLarge;
        try body.appendSlice(allocator, chunk[0..count]);
    }
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

    fn clock() i64 {
        return now;
    }

    fn fetch(allocator: std.mem.Allocator, video: Video) !Metadata {
        requests += 1;
        if (video[0] == 'F') return error.HttpResponseFailed;
        return copyMetadata(allocator, "{\"author_name\":\"作者\",\"author_url\":\"https://youtube.com/@name\"}");
    }
};

test "successful and failed oEmbed requests have independent TTLs" {
    var cache: Cache = .{ .allocator = std.testing.allocator, .fetch = Counter.fetch, .clock = Counter.clock };
    defer cache.deinit();
    Counter.requests = 0;
    Counter.now = 0;
    const good = "Successful1".*;
    const bad = "FailedVideo".*;
    _ = try cache.resolve(good);
    try std.testing.expectError(error.HttpResponseFailed, cache.resolve(bad));
    Counter.now = 4999;
    _ = try cache.resolve(good);
    try std.testing.expectError(error.HttpResponseFailed, cache.resolve(bad));
    try std.testing.expectEqual(@as(usize, 2), Counter.requests);
    Counter.now = 5000;
    try std.testing.expectError(error.HttpResponseFailed, cache.resolve(bad));
    Counter.now = 12 * 60 * 60 * 1000;
    _ = try cache.resolve(good);
    try std.testing.expectEqual(@as(usize, 4), Counter.requests);
}
