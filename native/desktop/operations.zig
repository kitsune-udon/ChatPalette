const std = @import("std");
const shortcuts = @import("shortcuts.zig");
const model = @import("../storage/model.zig");

const max_video_id = 11;
pub const VideoId = [max_video_id]u8;
pub const PageToken = [32]u8;

pub fn pageToken(value: []const u8) ?PageToken {
    if (value.len != @sizeOf(PageToken)) return null;
    for (value) |ch| if (!std.ascii.isHex(ch)) return null;
    return value[0..@sizeOf(PageToken)].*;
}

pub fn videoId(value: []const u8) ?VideoId {
    if (value.len != max_video_id) return null;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
    }
    return value[0..max_video_id].*;
}

pub const FocusProof = struct {
    text: [64]u8 = undefined,
    len: usize = 0,

    pub fn save(self: *FocusProof, token: []const u8) bool {
        self.len = 0;
        if (token.len == 0 or token.len > self.text.len) return false;
        for (token) |ch| if (!std.ascii.isHex(ch)) return false;
        @memcpy(self.text[0..token.len], token);
        self.len = token.len;
        return true;
    }

    pub fn take(self: *FocusProof, buffer: *[64]u8) []const u8 {
        const token = buffer[0..self.len];
        @memcpy(token, self.text[0..self.len]);
        self.len = 0;
        return token;
    }
};

pub const Command = struct {
    event: shortcuts.Event,
    generation: u64,
    /// The library revision at acceptance, used by the palette shortcut.
    library: u64,
    slot: ?SlotSource = null,

    fn release(self: Command) void {
        if (self.slot) |source| source.library.release();
    }
};

pub const SlotSource = struct {
    pub const Scope = union(enum) {
        shared,
        automatic,
        manual: []const u8,

        pub fn current(self: Scope, preferences: model.Preferences) bool {
            return switch (self) {
                .shared => true,
                .automatic => preferences.auto_mode,
                .manual => |id| !preferences.auto_mode and std.mem.eql(u8, preferences.input_profile_id, id),
            };
        }
    };

    library: model.Snapshot.LibraryLease,
    scope: Scope,
};

pub const Queue = struct {
    pending: std.ArrayList(Command) = .empty,
    generation: u64 = 0,
    target: usize = 0,
    video: ?VideoId = null,
    page: ?PageToken = null,
    focus: FocusProof = .{},
    active: bool = false,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.cancel();
        self.pending.deinit(allocator);
    }

    pub fn busy(self: Queue) bool {
        return self.active or self.pending.items.len > 0;
    }

    pub fn enqueue(self: *Queue, allocator: std.mem.Allocator, event: shortcuts.Event, library: u64, operation_video: ?VideoId) !void {
        try self.enqueueWithSlot(allocator, event, library, operation_video, null);
    }

    /// On success the queue owns the slot source until the operation finishes or is discarded.
    pub fn enqueueWithSlot(self: *Queue, allocator: std.mem.Allocator, event: shortcuts.Event, library: u64, operation_video: ?VideoId, source: ?SlotSource) !void {
        if (self.target != 0 and self.target != event.window) self.cancel();
        try self.pending.append(allocator, .{ .event = event, .generation = self.generation, .library = library, .slot = source });
        self.target = event.window;
        if (self.video == null) self.video = operation_video;
    }

    pub fn next(self: *Queue) ?Command {
        if (self.active or self.pending.items.len == 0) return null;
        self.active = true;
        return self.pending.orderedRemove(0);
    }

    pub fn accepts(self: Queue, command: Command, foreground: usize) bool {
        return self.active and command.generation == self.generation and command.event.window == foreground and
            self.target == foreground and foreground != 0;
    }

    pub fn bindVideo(self: *Queue, actual: VideoId) bool {
        if (self.video) |bound| return std.mem.eql(u8, &bound, &actual);
        self.video = actual;
        return true;
    }

    pub fn bindPage(self: *Queue, actual: PageToken) bool {
        if (self.page) |bound| return std.mem.eql(u8, &bound, &actual);
        self.page = actual;
        return true;
    }

    pub fn finish(self: *Queue, command: Command, succeeded: bool) void {
        command.release();
        self.active = false;
        if (command.generation != self.generation) return;
        if (!succeeded or self.pending.items.len == 0) self.cancel();
    }

    pub fn cancel(self: *Queue) void {
        self.generation +%= 1;
        for (self.pending.items) |command| command.release();
        self.pending.clearRetainingCapacity();
        self.target = 0;
        self.video = null;
        self.page = null;
        self.focus.len = 0;
    }
};

test "cancelling queued slots keeps only the running command's library alive" {
    const allocator = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(allocator);
    {
        var snapshot = try model.Snapshot.clone(allocator, .{
            .shared_items = &.{.{ .id = "admitted", .name = "item", .text = "original", .slot = 1 }},
        });
        defer snapshot.deinit();
        for (0..2) |_| {
            const library = try snapshot.retainLibrary();
            errdefer library.release();
            try queue.enqueueWithSlot(allocator, .{ .action = .shared1, .window = 2 }, 1, null, .{
                .library = library,
                .scope = .shared,
            });
        }
    }

    const running = queue.next() orelse return error.MissingSlotCommand;
    defer queue.finish(running, false);
    try queue.enqueue(allocator, .{ .action = .chat_focus, .window = 3 }, 2, null);
    try std.testing.expectEqual(@as(usize, 1), queue.pending.items.len);
    try std.testing.expectEqualStrings("original", running.slot.?.library.read().shared_items[0].text);
    try std.testing.expect(!queue.accepts(running, 2));
}

test "queued input retains its tab proof and a new generation may bind another tab" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    const first = pageToken("0123456789abcdef0123456789abcdef").?;
    const second = pageToken("abcdef0123456789abcdef0123456789").?;
    try std.testing.expect(pageToken("bind") == null);
    try std.testing.expect(pageToken("x123456789abcdef0123456789abcdef") == null);
    try queue.enqueue(std.testing.allocator, .{ .action = .shared1, .window = 2 }, 1, null);
    try queue.enqueue(std.testing.allocator, .{ .action = .chat_send, .window = 2 }, 1, null);
    const running = queue.next().?;
    try std.testing.expect(queue.bindPage(first));
    try std.testing.expect(!queue.bindPage(second));
    queue.finish(running, true);
    const stale = queue.next().?;
    try std.testing.expectEqual(first, queue.page.?);
    queue.finish(stale, false);
    try std.testing.expect(queue.page == null);
    try queue.enqueue(std.testing.allocator, .{ .action = .chat_send, .window = 2 }, 1, null);
    try std.testing.expect(queue.bindPage(second));
}

test "a window change discards old page proofs and preserves the waiting successor" {
    const allocator = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(allocator);
    try queue.enqueue(allocator, .{ .action = .chat_clear, .window = 23 }, 1, null);
    const old = queue.next().?;
    try std.testing.expect(queue.bindVideo("ZigTest0001".*));
    try std.testing.expect(queue.bindPage(pageToken("0123456789abcdef0123456789abcdef").?));
    try std.testing.expect(queue.focus.save("a1b2c3"));
    try queue.enqueue(allocator, .{ .action = .chat_focus, .window = 23 }, 1, null);

    try queue.enqueue(allocator, .{ .action = .chat_send, .window = 24 }, 1, null);
    try std.testing.expect(!queue.accepts(old, 23));
    try std.testing.expect(queue.next() == null);
    try std.testing.expect(queue.video == null and queue.page == null and queue.focus.len == 0);

    queue.finish(old, false);
    const successor = queue.next().?;
    try std.testing.expectEqual(shortcuts.Action.chat_send, successor.event.action);
    try std.testing.expect(queue.accepts(successor, 24));
    try std.testing.expect(queue.bindVideo("ZigTest0002".*));
    try std.testing.expect(queue.bindPage(pageToken("abcdef0123456789abcdef0123456789").?));
    queue.finish(successor, true);
    try std.testing.expect(!queue.busy());
}

pub const Reaction = struct {
    target: usize,
    video: VideoId,
    page: PageToken,
    kind: u8,
    count: u32,
    interval: u32,
    due_ns: u64 = 0,
    shortcut: ?Command = null,
    completed: u32 = 0,
    started_ns: u64 = 0,
    first_acknowledged_start_ns: u64 = 0,
    last_acknowledged_start_ns: u64 = 0,
    stop_requested: bool = false,
    active_request: bool = false,

    pub fn stop(self: *Reaction) void {
        self.stop_requested = true;
    }

    pub fn begin(self: *Reaction, now_ns: u64) bool {
        if (self.stop_requested or self.active_request or self.completed >= self.count or now_ns < self.due_ns) return false;
        self.active_request = true;
        self.markSendStart(now_ns);
        return true;
    }

    pub fn markSendStart(self: *Reaction, now_ns: u64) void {
        self.started_ns = now_ns;
        self.due_ns = now_ns + @as(u64, self.interval) * std.time.ns_per_ms;
    }

    pub fn remainingMs(self: Reaction, now_ns: u64) u32 {
        const remaining = self.due_ns -| now_ns;
        return @intCast(std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch unreachable);
    }

    /// Count the acknowledged operation even when stop was requested during the request.
    pub fn acknowledge(self: *Reaction, operated: bool) bool {
        self.active_request = false;
        if (operated) {
            if (self.completed == 0) self.first_acknowledged_start_ns = self.started_ns;
            self.last_acknowledged_start_ns = self.started_ns;
            self.completed += 1;
        }
        return operated and !self.stop_requested and self.completed < self.count;
    }

    pub fn meanStartIntervalMs(self: Reaction) ?u64 {
        if (self.completed < 2) return null;
        const intervals: u64 = self.completed - 1;
        const elapsed = self.last_acknowledged_start_ns - self.first_acknowledged_start_ns;
        const divisor = intervals * std.time.ns_per_ms;
        return (elapsed + divisor / 2) / divisor;
    }

    pub fn succeeded(self: Reaction) bool {
        return !self.stop_requested and self.completed == self.count;
    }
};

test "the queue binds the video to one target and discards only the stale session" {
    const allocator = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(allocator);
    try queue.enqueue(allocator, .{ .action = .chat_focus, .window = 23 }, 7, null);
    try queue.enqueue(allocator, .{ .action = .shared1, .window = 23 }, 7, null);
    const first = queue.next().?;
    try std.testing.expect(queue.accepts(first, 23) and !queue.accepts(first, 24));
    try std.testing.expect(queue.bindVideo("ZigTest0001".*));
    try std.testing.expect(!queue.bindVideo("ZigTest0002".*));
    try std.testing.expect(queue.focus.save("a1b2c3"));
    queue.finish(first, true);
    const old = queue.next().?;
    try std.testing.expectEqual(shortcuts.Action.shared1, old.event.action);
    var token: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a1b2c3", queue.focus.take(&token));
    try std.testing.expectEqualStrings("", queue.focus.take(&token));
    queue.cancel();
    try queue.enqueue(allocator, .{ .action = .shared2, .window = 24 }, 8, null);
    try std.testing.expect(!queue.accepts(old, 24));
    queue.finish(old, false);
    try std.testing.expectEqual(shortcuts.Action.shared2, queue.next().?.event.action);
}

test "a quick reaction keeps its video and queue until it reaches a terminal result" {
    const allocator = std.testing.allocator;
    const video = "ZigTest0001".*;
    var queue: Queue = .{};
    defer queue.deinit(allocator);

    try queue.enqueue(allocator, .{ .action = .reaction, .window = 23 }, 7, null);
    const command = queue.next().?;
    try std.testing.expect(queue.bindVideo(video));
    var job: Reaction = .{ .target = 23, .video = video, .page = @splat(0), .kind = 1, .count = 2, .interval = 0, .shortcut = command };
    try queue.enqueue(allocator, .{ .action = .shared1, .window = 23 }, 7, video);
    try std.testing.expect(queue.next() == null);
    try std.testing.expect(job.begin(0) and job.acknowledge(true));
    try std.testing.expect(!job.succeeded());
    try std.testing.expect(queue.next() == null);
    try std.testing.expect(job.begin(1) and !job.acknowledge(true));
    queue.finish(job.shortcut.?, job.succeeded());
    const following = queue.next().?;
    try std.testing.expectEqual(shortcuts.Action.shared1, following.event.action);
    try std.testing.expect(!queue.bindVideo("ZigTest0002".*));
    queue.finish(following, false);
    try std.testing.expect(!queue.busy());
}

test "a failed quick reaction clears its own generation and preserves a replacement" {
    const allocator = std.testing.allocator;
    const video = "ZigTest0001".*;
    var queue: Queue = .{};
    defer queue.deinit(allocator);

    try queue.enqueue(allocator, .{ .action = .reaction, .window = 23 }, 7, video);
    const failed = queue.next().?;
    try queue.enqueue(allocator, .{ .action = .shared1, .window = 23 }, 7, video);
    queue.finish(failed, false);
    try std.testing.expect(!queue.busy());

    try queue.enqueue(allocator, .{ .action = .reaction, .window = 23 }, 7, video);
    const stale = queue.next().?;
    try queue.enqueue(allocator, .{ .action = .shared2, .window = 24 }, 7, "ZigTest0002".*);
    try std.testing.expect(!queue.accepts(stale, 23));
    queue.finish(stale, false);
    const successor = queue.next().?;
    try std.testing.expectEqual(shortcuts.Action.shared2, successor.event.action);
    try std.testing.expect(!queue.bindVideo(video));
    try std.testing.expect(queue.bindVideo("ZigTest0002".*));
}

test "reaction intervals count from request start and stop retains the in-flight result" {
    const ms = std.time.ns_per_ms;
    var reaction: Reaction = .{ .target = 23, .video = "ZigTest0001".*, .page = @splat(0), .kind = 1, .count = 10, .interval = 200, .due_ns = 3000 * ms };
    try std.testing.expect(!reaction.begin(3000 * ms - 1));
    try std.testing.expect(reaction.begin(3000 * ms));
    try std.testing.expect(!reaction.begin(3200 * ms));
    try std.testing.expect(reaction.acknowledge(true));
    try std.testing.expectEqual(@as(u32, 1), reaction.remainingMs(3200 * ms - 1));
    try std.testing.expect(!reaction.begin(3200 * ms - 1));
    try std.testing.expect(reaction.begin(3200 * ms));
    reaction.stop();
    try std.testing.expect(!reaction.acknowledge(true));
    try std.testing.expectEqual(@as(u32, 2), reaction.completed);
    try std.testing.expect(!reaction.begin(3400 * ms));
    reaction.count = reaction.completed;
    try std.testing.expect(!reaction.succeeded());
}

test "reaction timing excludes registration synchronization and unacknowledged attempts" {
    const ms = std.time.ns_per_ms;
    var reaction: Reaction = .{ .target = 23, .video = "ZigTest0001".*, .page = @splat(0), .kind = 1, .count = 10, .interval = 200 };
    try std.testing.expect(reaction.begin(0));
    reaction.markSendStart(150 * ms);
    try std.testing.expect(reaction.acknowledge(true));
    try std.testing.expectEqual(null, reaction.meanStartIntervalMs());
    try std.testing.expect(!reaction.begin(349 * ms));
    try std.testing.expect(reaction.begin(350 * ms));
    reaction.markSendStart(350 * ms + ms / 2);
    try std.testing.expect(reaction.acknowledge(true));
    try std.testing.expectEqual(@as(u32, 0), reaction.remainingMs(600 * ms));
    try std.testing.expect(reaction.begin(600 * ms));
    reaction.markSendStart(600 * ms);
    try std.testing.expect(!reaction.acknowledge(false));
    try std.testing.expectEqual(@as(?u64, 201), reaction.meanStartIntervalMs());
}
