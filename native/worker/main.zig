const std = @import("std");
const uia = @import("uia.zig");
const win = @import("windows.zig");
const pages = @import("pages.zig");
const reactions = @import("reactions.zig");
const metadata = @import("metadata.zig");
const keyboard = @import("keyboard.zig");
const eq = std.mem.eql;

pub const UiaClient = uia.Client;
pub const UiaClientWindow = uia.Window;
pub const VideoContext = @import("rules.zig").VideoContext;
pub const pages_api = pages;
pub const win_api = win;
pub const browserName = reactions.browserName;
pub const supportedBrowser = @import("rules.zig").supportedBrowser;

const Handle = std.os.windows.HANDLE;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn OpenEventW(u32, i32, [*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn SetEvent(Handle) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(Handle, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const max_frame = 32768;

pub const Mode = enum {
    browser_context,
    resolve,
    verify_input,
    verify_chat,
    chat_focus,
    reactions_show,
    reaction_configure,
    reaction_capture,
    reaction_check,
    reaction_send,
    chat_enter,
    chat_clear,
    input_insert,
    unsupported,

    fn parse(value: []const u8) Mode {
        inline for (std.meta.fields(Mode)) |field| {
            if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
        }
        return .unsupported;
    }

    fn inputOutcome(self: Mode) ?[]const u8 {
        return switch (self) {
            .chat_enter => "enter_sent",
            .chat_clear => "cleared",
            .input_insert => "inserted",
            else => null,
        };
    }
};

pub const Request = struct {
    seq: []const u8 = "",
    window: []const u8 = "",
    hwnd: usize = 0,
    mode: Mode = .unsupported,
    video: []const u8 = "",
    token: []const u8 = "",
    page: []const u8 = "",
    cancel_token: []const u8 = "",
    payload_bytes: []const u8 = "",
    payload: []const u8 = "",
    reaction: []const u8 = "",
    x: []const u8 = "",
    y: []const u8 = "",

    fn documentBinding(self: Request) ?uia.DocumentLookup {
        if (!eq(u8, self.page, "bind")) return null;
        return switch (self.mode) {
            .browser_context => .browser_context,
            .resolve => .foreground,
            else => null,
        };
    }
};

fn decimal(comptime T: type, digits: []const u8) !T {
    if (digits.len > 20) return error.InvalidNumber;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidNumber;
    return std.fmt.parseUnsigned(T, digits, 10);
}

fn parseRequest(frame: []const u8) !Request {
    if (!std.unicode.utf8ValidateSlice(frame)) return error.InvalidEncoding;
    var req: Request = .{};
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |line| {
        const index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..index];
        const value = line[index + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, "Seq")) {
            req.seq = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Window")) {
            req.window = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Mode")) {
            req.mode = Mode.parse(value);
        } else if (std.ascii.eqlIgnoreCase(key, "Video")) {
            req.video = value;
        } else if (std.ascii.eqlIgnoreCase(key, "FocusToken")) {
            req.token = value;
        } else if (std.ascii.eqlIgnoreCase(key, "PageToken")) {
            req.page = value;
        } else if (std.ascii.eqlIgnoreCase(key, "CancelToken")) {
            req.cancel_token = value;
        } else if (std.ascii.eqlIgnoreCase(key, "PayloadBytes")) {
            req.payload_bytes = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Payload")) {
            req.payload = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Reaction")) {
            req.reaction = value;
        } else if (std.ascii.eqlIgnoreCase(key, "X")) {
            req.x = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Y")) {
            req.y = value;
        }
    }
    _ = try decimal(u64, req.seq);
    req.hwnd = try decimal(usize, req.window);
    return req;
}

fn readExactly(pipe: Handle, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        var count: u32 = 0;
        if (ReadFile(pipe, buffer[offset..].ptr, @intCast(buffer.len - offset), &count, null) == 0) {
            if (GetLastError() == 109 and offset == 0) return error.EndOfStream;
            return error.ReadFailed;
        }
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

fn frameSize(header: *const [4]u8) !usize {
    const size = std.mem.readInt(u32, header, .little);
    if (size == 0 or size > max_frame) return error.InvalidFrame;
    return size;
}

fn writeExactly(pipe: Handle, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        var count: u32 = 0;
        if (WriteFile(pipe, data[offset..].ptr, @intCast(data.len - offset), &count, null) == 0 or count == 0)
            return error.WriteFailed;
        offset += count;
    }
}

pub const Reply = struct {
    state: []const u8 = "unavailable",
    video: ?uia.Video = null,
    author: []const u8 = "",
    channel: []const u8 = "",
    detail: []const u8 = "",
    page: ?[32]u8 = null,
};

const FocusProof = struct {
    hwnd: usize,
    element: *win.Element,
    token: [32]u8,
    video: uia.Video,
};

const PageProof = struct {
    hwnd: usize,
    element: *win.Element,
    token: [32]u8,
    video: uia.Video,
};

const PreparedInput = struct {
    element: *win.Element,
    page_token: [32]u8,
    kind: []const u8,
    used_focus_proof: bool,
};

pub const Worker = struct {
    client: uia.Client,
    focus: ?FocusProof = null,
    prepared_input: ?PreparedInput = null,
    input_pipe: ?Handle = null,
    page_proofs: [4]?PageProof = @splat(null),
    next_page: usize = 0,
    registry: reactions.Registry = .{ .allocator = std.heap.page_allocator },
    cache: metadata.Cache = .{ .allocator = std.heap.page_allocator },

    pub fn init() !Worker {
        return .{ .client = try uia.Client.init() };
    }

    pub fn deinit(self: *Worker) void {
        if (self.focus) |focus| win.release(focus.element);
        if (self.prepared_input) |prepared| win.release(prepared.element);
        for (self.page_proofs) |page| if (page) |proof| win.release(proof.element);
        self.registry.deinit();
        self.cache.deinit();
        self.client.deinit();
    }

    pub fn execute(self: *Worker, allocator: std.mem.Allocator, req: Request, reply: *Reply) !void {
        const prepared_input = self.prepared_input;
        self.prepared_input = null;
        defer if (prepared_input) |prepared| win.release(prepared.element);
        const committed_state = req.mode.inputOutcome();
        if (req.mode == .unsupported) return;
        if (req.mode == .reaction_configure) {
            try self.registry.configure(req.payload);
            reply.state = "configured";
            return;
        }
        var proof: ?FocusProof = null;
        defer if (proof) |value| win.release(value.element);
        if (req.mode == .chat_focus or req.mode == .verify_chat) {
            proof = self.focus;
            self.focus = null;
        }
        if (req.mode == .verify_chat) {
            const value = proof orelse {
                reply.state = "wrong_input";
                return;
            };
            if (value.hwnd != req.hwnd or !eq(u8, req.token, &value.token)) {
                reply.state = "wrong_input";
                return;
            }
        }
        const changes_page = req.mode == .chat_focus or req.mode == .reactions_show;
        if (req.hwnd == 0) {
            if (changes_page) reply.state = "wrong_window";
            return;
        }
        const scoped = req.page.len != 0;
        const binding = req.documentBinding();
        const existing = if (scoped and binding == null) self.pageProof(req.hwnd, req.page) else null;
        if (committed_state != null and (existing == null or prepared_input == null or
            !eq(u8, req.page, &prepared_input.?.page_token)))
        {
            reply.state = "changed";
            return;
        }
        if (scoped and binding == null and existing == null) {
            reply.state = "changed";
            return;
        }
        const window = try self.client.windowFor(req.hwnd);
        if (changes_page and !try self.client.foreground(window)) {
            reply.state = "wrong_window";
            return;
        }
        // Reading the browser chrome first also makes its accessibility tree available on a cold request.
        const video = try self.client.readVideo(window) orelse return;
        reply.video = video;
        const new_document = if (binding) |lookup| try self.client.findDocument(window, lookup) else null;
        defer if (new_document) |doc| win.release(doc);
        const page = if (existing) |saved| saved.element else new_document;
        if (scoped and page == null) {
            reply.state = "changed";
            return;
        }
        if (existing) |saved| {
            if (!eq(u8, &saved.video, &video)) {
                reply.state = "changed";
                return;
            }
        }
        const reaction_action = req.mode == .reaction_capture or req.mode == .reaction_check or req.mode == .reaction_send;
        if (req.mode != .browser_context and req.mode != .resolve) {
            if ((reaction_action or committed_state != null or req.video.len != 0) and !eq(u8, &video, req.video)) {
                reply.state = "changed";
                return;
            }
        }
        if (page) |doc| {
            if (binding != null and !try self.sameVideo(window, video)) {
                reply.state = "changed";
                return;
            }
            if (!reaction_action and req.mode != .verify_input and req.mode != .verify_chat and committed_state == null and
                !try self.client.documentMatches(window, doc, binding orelse .foreground))
            {
                reply.state = "changed";
                return;
            }
        }
        switch (req.mode) {
            .browser_context => reply.state = "ok",
            .resolve => {
                const value = try self.cache.resolve(video);
                if (!try self.sameVideo(window, video)) {
                    reply.state = "changed";
                    return;
                }
                if (page) |doc| if (!try self.client.documentIsActive(window, doc)) {
                    reply.state = "changed";
                    return;
                };
                reply.state = "ok";
                reply.author = value.author;
                reply.channel = value.channel;
            },
            .verify_input, .verify_chat => {
                const focus_proof = if (req.mode == .verify_chat) proof else null;
                if (focus_proof) |confirmed| {
                    if (!eq(u8, &confirmed.video, &video)) {
                        reply.state = "wrong_input";
                        return;
                    }
                }
                try self.verify(window, video, if (focus_proof) |confirmed| confirmed.element else null, req.mode == .verify_chat, page, if (existing) |saved| saved.token else null, reply);
            },
            .chat_enter, .chat_clear, .input_insert => try self.commitInput(allocator, req, window, video, page.?, prepared_input.?, committed_state.?, reply),
            .chat_focus => try self.moveFocus(window, video, page, reply),
            .reactions_show => try self.hover(window, video, page, reply),
            .reaction_capture => try self.captureReaction(allocator, window, video, req, page, reply),
            .reaction_check, .reaction_send => try self.react(allocator, window, video, req, if (existing) |saved|
                .{ .document = saved.element, .token = saved.token }
            else
                null, reply),
            .reaction_configure, .unsupported => unreachable,
        }
        if (page) |doc| {
            if (eq(u8, reply.state, "ok") or eq(u8, reply.state, "focused") or eq(u8, reply.state, "hovered") or
                eq(u8, reply.state, "captured") or eq(u8, reply.state, "ready") or eq(u8, reply.state, "operated") or
                (committed_state != null and eq(u8, reply.state, committed_state.?)))
            {
                reply.page = if (existing) |saved| saved.token else self.bindPage(window, doc, video);
            }
        }
    }

    fn pageProof(self: *const Worker, hwnd: usize, token: []const u8) ?PageProof {
        for (self.page_proofs) |entry| {
            const proof = entry orelse continue;
            if (proof.hwnd == hwnd and eq(u8, token, &proof.token)) return proof;
        }
        return null;
    }

    fn bindPage(self: *Worker, window: *uia.Window, doc: *win.Element, video: uia.Video) [32]u8 {
        for (self.page_proofs) |entry| {
            const saved = entry orelse continue;
            if (saved.hwnd == window.hwnd and eq(u8, &saved.video, &video) and
                (self.client.same(saved.element, doc) catch false)) return saved.token;
        }
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        const token = std.fmt.bytesToHex(bytes, .lower);
        const slot = &self.page_proofs[self.next_page];
        if (slot.*) |old| win.release(old.element);
        win.retain(doc);
        slot.* = .{ .hwnd = window.hwnd, .element = doc, .token = token, .video = video };
        self.next_page = (self.next_page + 1) % self.page_proofs.len;
        return token;
    }

    fn sameVideo(self: *Worker, window: *uia.Window, video: uia.Video) !bool {
        const latest = try self.client.readVideo(window) orelse return false;
        return eq(u8, &latest, &video);
    }

    fn verify(self: *Worker, window: *uia.Window, video: uia.Video, expected_input: ?*win.Element, require_chat: bool, page: ?*win.Element, prepare: ?[32]u8, reply: *Reply) !void {
        reply.state = "wrong_input";
        const hwnd: win.sdk.HWND = @ptrFromInt(window.hwnd);
        if (win.sdk.GetForegroundWindow() != hwnd) return;
        const focused = try self.client.focusedInput(window) orelse return;
        defer win.release(focused.element);
        if (page) |expected| {
            const document = try self.client.documentOf(window, focused.element) orelse return;
            defer win.release(document);
            if (!try self.client.same(expected, document)) {
                reply.state = "changed";
                return;
            }
        }
        if (require_chat and !eq(u8, focused.kind, "chat")) return;
        if (expected_input) |element| {
            if (!try self.client.foreground(window) or !try self.client.same(element, focused.element)) return;
        }
        if (!try self.sameVideo(window, video)) {
            reply.state = "changed";
            return;
        }
        if (!try self.client.stillFocused(window, focused.element, true)) return;
        if (win.sdk.GetForegroundWindow() != hwnd) return;
        reply.state = "ok";
        reply.detail = focused.kind;
        if (prepare) |token| {
            win.retain(focused.element);
            self.prepared_input = .{
                .element = focused.element,
                .page_token = token,
                .kind = focused.kind,
                .used_focus_proof = require_chat,
            };
        }
    }

    fn commitInput(self: *Worker, allocator: std.mem.Allocator, req: Request, window: *uia.Window, video: uia.Video, page: *win.Element, prepared: PreparedInput, committed_state: []const u8, reply: *Reply) !void {
        if (req.mode == .chat_clear and !prepared.used_focus_proof) {
            reply.state = "wrong_input";
            return;
        }
        const permit = keyboard.Authorization.open(req.cancel_token, self.input_pipe) catch {
            reply.state = "cancelled";
            return;
        };
        defer permit.close();
        if (!permit.live()) {
            reply.state = "cancelled";
            return;
        }
        const payload: ?keyboard.PayloadView = if (req.mode == .input_insert)
            try keyboard.PayloadView.open(req.cancel_token, try decimal(usize, req.payload_bytes))
        else
            null;
        defer if (payload) |view| view.close();
        const effect: keyboard.Effect = switch (req.mode) {
            .chat_enter => .enter,
            .chat_clear => .clear,
            .input_insert => .{ .insert = payload.?.text },
            else => unreachable,
        };
        var batch = keyboard.Batch.prepare(allocator, effect) catch |failure| switch (failure) {
            error.TextContainsEditingKey => {
                reply.state = "invalid_text";
                return;
            },
            else => return failure,
        };
        defer batch.deinit();
        try self.verify(window, video, prepared.element, req.mode != .input_insert, page, null, reply);
        if (!eq(u8, reply.state, "ok")) return;
        if (!eq(u8, reply.detail, prepared.kind)) {
            reply.state = "changed";
            reply.detail = "";
            return;
        }
        reply.state = "unknown";
        reply.detail = "";
        batch.send(@ptrFromInt(window.hwnd), permit) catch |failure| switch (failure) {
            error.ForegroundChanged, error.InputCancelled => {
                reply.state = "cancelled";
                return;
            },
            else => return failure,
        };
        reply.state = committed_state;
    }

    fn validContext(self: *Worker, window: *uia.Window, video: uia.Video, reply: *Reply) !bool {
        if (!try self.sameVideo(window, video)) {
            reply.state = "changed";
            return false;
        }
        if (!try self.client.foreground(window)) {
            reply.state = "wrong_window";
            return false;
        }
        return true;
    }

    fn moveFocus(self: *Worker, window: *uia.Window, video: uia.Video, page: ?*win.Element, reply: *Reply) !void {
        const target = switch (try pages.findChatIn(&self.client, window, page)) {
            .missing => {
                reply.state = "chat_missing";
                return;
            },
            .ambiguous => {
                reply.state = "chat_ambiguous";
                return;
            },
            .target => |element| element,
        };
        defer win.release(target);
        if (!try window.belongs(target)) {
            reply.state = "wrong_window";
            return;
        }
        if (!eq(u8, try self.client.inputKind(target, window), "chat")) {
            reply.state = "chat_missing";
            return;
        }
        if (!try self.validContext(window, video, reply)) return;
        if (page) |doc| if (!try self.client.documentIsActive(window, doc)) {
            reply.state = "changed";
            return;
        };
        reply.state = "unknown";
        try win.check(win.call("SetFocus", target, .{}));
        reply.state = try pages.waitChatFocus(&self.client, window, target, video);
        if (!eq(u8, reply.state, "focused")) return;
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        win.retain(target);
        self.focus = .{ .hwnd = window.hwnd, .element = target, .video = video, .token = std.fmt.bytesToHex(bytes, .lower) };
        reply.detail = &self.focus.?.token;
    }

    fn hover(self: *Worker, window: *uia.Window, video: uia.Video, page: ?*win.Element, reply: *Reply) !void {
        const target = (try pages.findLauncher(&self.client, window)) orelse {
            reply.state = "unsupported";
            return;
        };
        defer win.release(target);
        const point = (try pages.hoverPoint(&self.client, target)) orelse {
            reply.state = "unsupported";
            return;
        };
        if ((try pages.launcher(&self.client, window, target)) == null) {
            reply.state = "unsupported";
            return;
        }
        if (!try self.validContext(window, video, reply)) return;
        if (!try self.reactionPageCurrent(window, page, reply)) return;
        if (page) |doc| {
            if (!try self.client.inDocument(window, target, doc)) {
                reply.state = "changed";
                return;
            }
        }
        reply.state = "unknown";
        if (win.sdk.SetPhysicalCursorPos(point.x, point.y) != win.sdk.FALSE) reply.state = "hovered";
    }

    fn reactionPageCurrent(self: *Worker, window: *uia.Window, page: ?*win.Element, reply: *Reply) !bool {
        if (page) |doc| {
            if (!try self.client.documentIsActive(window, doc)) {
                reply.state = "changed";
                return false;
            }
        }
        return true;
    }

    fn captureReaction(self: *Worker, allocator: std.mem.Allocator, window: *uia.Window, video: uia.Video, req: Request, page: ?*win.Element, reply: *Reply) !void {
        if (!try self.reactionPageCurrent(window, page, reply)) return;
        const point: win.Point = .{ .x = try signedCoordinate(req.x), .y = try signedCoordinate(req.y) };
        const captured = reactions.capture(allocator, &self.client, window, point, page) catch |err| {
            if (err != error.WrongWindow) return err;
            if (try self.reactionPageCurrent(window, page, reply)) reply.state = "wrong_window";
            return;
        };
        const detail = if (captured.tokens) |tokens| detail: {
            if (!try self.sameVideo(window, video)) {
                reply.state = "changed";
                return;
            }
            const entry: reactions.Registration = .{ .browser = try reactions.browserName(allocator, window.hwnd), .tokens = tokens };
            break :detail try std.json.Stringify.valueAlloc(allocator, entry, .{});
        } else captured.detail;
        if (!try self.reactionPageCurrent(window, page, reply)) return;
        reply.state = if (captured.tokens == null) "unsupported" else "captured";
        reply.detail = detail;
    }

    fn react(self: *Worker, allocator: std.mem.Allocator, window: *uia.Window, video: uia.Video, req: Request, scope: ?reactions.Scope, reply: *Reply) !void {
        const page = if (scope) |bound| bound.document else null;
        if (!try self.reactionPageCurrent(window, page, reply)) return;
        const browser = try reactions.browserName(allocator, window.hwnd);
        const registration = self.registry.registration(browser) orelse {
            reply.state = "not_registered";
            return;
        };
        const found = try self.registry.find(allocator, &self.client, window, registration, scope);
        const group = found.group orelse {
            if (!try self.reactionPageCurrent(window, page, reply)) return;
            reply.state = "menu_closed";
            reply.detail = found.detail;
            return;
        };
        const send = req.mode == .reaction_send;
        const index = if (send) reactionIndex(req.reaction) orelse return else 0;
        if (!try self.client.foreground(window)) {
            reply.state = "wrong_window";
            return;
        }
        var pattern: ?win.Invoker = null;
        defer if (pattern) |invoke| invoke.releasePattern();
        if (send) {
            const element = group[index];
            if (try win.flag("get_CurrentIsOffscreen", element) or !try win.flag("get_CurrentIsEnabled", element)) {
                reply.state = "menu_closed";
                return;
            }
            pattern = try win.invoker(element);
            if (pattern == null) {
                reply.state = "unsupported";
                return;
            }
        }
        if (page) |doc| {
            const selected = if (send) group[index .. index + 1] else &group;
            for (selected) |element| {
                if (!try self.client.inDocument(window, element, doc)) {
                    reply.state = "changed";
                    return;
                }
            }
        }
        if (!try self.validContext(window, video, reply)) return;
        if (!try self.reactionPageCurrent(window, page, reply)) return;
        if (pattern) |invoke| {
            reply.state = "unknown";
            try invoke.operate();
            reply.state = "operated";
        } else reply.state = "ready";
    }
};

fn reactionIndex(value: []const u8) ?usize {
    return if (value.len == 1 and value[0] >= '1' and value[0] <= '5') value[0] - '1' else null;
}

fn signedCoordinate(value: []const u8) !i32 {
    // Requests carry signed integral desktop coordinates. Empty denotes zero, as in PowerShell.
    if (value.len == 0) return 0;
    const digits = if (value[0] == '-' or value[0] == '+') value[1..] else value;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidNumber;
    return std.fmt.parseInt(i32, value, 10);
}

fn serve(pipe: Handle, ready: Handle) !void {
    if (SetEvent(ready) == 0) return error.SignalFailed;
    var worker = try Worker.init();
    defer worker.deinit();
    worker.input_pipe = pipe;
    var frame: [max_frame]u8 = undefined;
    while (true) {
        var header: [4]u8 = undefined;
        // The legacy worker exits with code 1 when its owner closes the pipe.
        try readExactly(pipe, &header);
        const size = try frameSize(&header);
        try readExactly(pipe, frame[0..size]);
        const req = try parseRequest(frame[0..size]);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var result: Reply = .{};
        worker.execute(arena.allocator(), req, &result) catch |failure| {
            switch (req.mode) {
                .chat_focus, .reactions_show, .reaction_capture, .reaction_check, .reaction_send, .chat_enter, .chat_clear, .input_insert => {},
                else => result = .{},
            }
            result.detail = @errorName(failure);
        };
        var reply: [4 + max_frame]u8 = undefined;
        const body = serialize(&reply, req, &result) catch blk: {
            // Preserve the outcome of an issued action even when diagnostic
            // data is too large to send.
            if (eq(u8, result.state, "captured") or eq(u8, result.state, "ok")) result.state = "unavailable";
            result.detail = "ReplyTooLarge";
            result.author = "";
            result.channel = "";
            result.page = null;
            break :blk try serialize(&reply, req, &result);
        };
        try writeExactly(pipe, reply[0 .. 4 + body.len]);
        if (SetEvent(ready) == 0) return error.SignalFailed;
    }
}

fn serialize(reply: *[4 + max_frame]u8, req: Request, result: *const Reply) ![]const u8 {
    var out: std.Io.Writer = .fixed(reply[4..]);
    try out.print("Seq={s}\nState={s}\nAuthor=", .{ req.seq, result.state });
    try writeField(&out, result.author);
    try out.writeAll("\nChannel=");
    try writeField(&out, result.channel);
    try out.print("\nVideo={s}\nWindow={s}\nDetail=", .{
        if (result.video) |*video| video else "", req.window,
    });
    try writeField(&out, result.detail);
    if (result.page) |*token| try out.print("\nPageToken={s}", .{token});
    const body = out.buffered();
    std.mem.writeInt(u32, reply[0..4], @intCast(body.len), .little);
    return body;
}

fn writeField(out: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        try out.writeByte(if (byte == '\r' or byte == '\n') ' ' else byte);
    }
}

fn validPipeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_{}", ch) == null) return false;
    }
    return true;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3 or !std.ascii.eqlIgnoreCase(args[1], "-PipeName")) return error.ExpectedPipeName;
    try run(args[2]);
}

pub fn run(name: []const u8) !void {
    const allocator = std.heap.page_allocator;
    if (!validPipeName(name)) return error.InvalidPipeName;
    var pipe_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pipe_buf, "\\\\.\\pipe\\{s}", .{name});
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(path_w);
    const pipe = CreateFileW(path_w, 0xc0000000, 0, null, 3, 0, null); // GENERIC_READ | GENERIC_WRITE, OPEN_EXISTING
    if (pipe == std.os.windows.INVALID_HANDLE_VALUE) return error.OpenPipe;
    defer _ = CloseHandle(pipe);
    const event_name = try std.fmt.bufPrint(&pipe_buf, "{s}-ready", .{name});
    const event_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, event_name);
    defer allocator.free(event_w);
    const ready = OpenEventW(2, 0, event_w) orelse return error.OpenReadyEvent; // EVENT_MODIFY_STATE
    defer _ = CloseHandle(ready);
    try serve(pipe, ready);
}

test "production frames preserve identifiers and the expected video" {
    try std.testing.expect(validPipeName("youtube-helper-{A8CEE5B6-7D53-47B6-A981-1A8844CC2489}"));
    try std.testing.expect(!validPipeName("other\\pipe"));
    const req = try parseRequest("Seq=2\nWindow=1234\nMode=verify_input\nVideo=Abc-def_012\n");
    try std.testing.expectEqual(@as(usize, 1234), req.hwnd);
    try std.testing.expectEqualStrings("2", req.seq);
    try std.testing.expectEqual(Mode.verify_input, req.mode);
    try std.testing.expectEqualStrings("Abc-def_012", req.video);
    try std.testing.expectEqualStrings("", req.page);
    try std.testing.expectError(error.InvalidNumber, parseRequest("Seq=1\nWindow=+12\n"));
}

test "page proofs appear only in opted-in frames and a fresh worker rejects old proofs" {
    const proof = "0123456789abcdef0123456789abcdef";
    const bind = try parseRequest("Seq=1\nWindow=1234\nMode=browser_context\nPageToken=bind\n");
    try std.testing.expectEqualStrings("bind", bind.page);
    var buffer: [4 + max_frame]u8 = undefined;
    const body = try serialize(&buffer, bind, &.{ .state = "ok", .video = "ZigTest0001".*, .page = proof.* });
    try std.testing.expect(std.mem.endsWith(u8, body, "\nPageToken=" ++ proof));
    const subsequent = try parseRequest("Seq=2\nWindow=1234\nMode=verify_input\nVideo=ZigTest0001\nPageToken=" ++ proof ++ "\n");
    try std.testing.expectEqualStrings(proof, subsequent.page);
    var fresh: Worker = .{ .client = undefined };
    var refused: Reply = .{};
    try fresh.execute(std.testing.allocator, subsequent, &refused);
    try std.testing.expectEqualStrings("changed", refused.state);
    try std.testing.expectEqual(@as(?[32]u8, null), refused.page);
}

test "only a new browser context proof can inspect a background document" {
    const bind = try parseRequest("Seq=1\nWindow=1234\nMode=browser_context\nPageToken=bind\n");
    try std.testing.expectEqual(@as(?uia.DocumentLookup, .browser_context), bind.documentBinding());
    const resolve = try parseRequest("Seq=1\nWindow=1234\nMode=resolve\nPageToken=bind\n");
    try std.testing.expectEqual(@as(?uia.DocumentLookup, .foreground), resolve.documentBinding());
    const legacy: Request = .{ .mode = .browser_context, .hwnd = 1234 };
    try std.testing.expect(legacy.documentBinding() == null);
    const saved: Request = .{ .mode = .browser_context, .hwnd = 1234, .page = "0123456789abcdef0123456789abcdef" };
    try std.testing.expect(saved.documentBinding() == null);
    for ([_]Mode{ .reaction_capture, .reaction_check, .reaction_send, .chat_focus, .verify_input }) |mode| {
        const req: Request = .{ .mode = mode, .hwnd = 1234, .page = "bind" };
        try std.testing.expect(req.documentBinding() == null);
    }
}

test "all scoped reaction modes reject missing page proof before accessibility lookup" {
    var fresh: Worker = .{ .client = undefined };
    for ([_]Mode{ .reaction_capture, .reaction_check, .reaction_send }) |mode| {
        for ([_][]const u8{ "bind", "0123456789abcdef0123456789abcdef" }) |token| {
            var refused: Reply = .{};
            try fresh.execute(std.testing.allocator, .{ .mode = mode, .hwnd = 1234, .video = "ZigTest0001", .page = token }, &refused);
            try std.testing.expectEqualStrings("changed", refused.state);
            try std.testing.expectEqual(@as(?[32]u8, null), refused.page);
        }
    }
}

test "action request fields and framed replies cannot insert another field" {
    const request = try parseRequest("Seq=98\nWindow=4294967400\nMode=REACTION_SEND\nVideo=ZigTest0001\nReaction=5\nX=-12\nY=25\n");
    try std.testing.expectEqual(Mode.reaction_send, request.mode);
    try std.testing.expectEqual(@as(usize, 4294967400), request.hwnd);
    try std.testing.expectEqual(@as(usize, 4), reactionIndex(request.reaction).?);
    try std.testing.expectEqual(@as(i32, -12), try signedCoordinate(request.x));
    try std.testing.expectEqual(@as(i32, 25), try signedCoordinate(request.y));
    try std.testing.expectError(error.InvalidNumber, signedCoordinate("0x20"));
    try std.testing.expectError(error.InvalidEncoding, parseRequest("Seq=1\nWindow=0\nDetail=\xff"));
    var buffer: [4 + max_frame]u8 = undefined;
    const body = try serialize(&buffer, request, &.{
        .state = "unknown",
        .video = "ZigTest0001".*,
        .detail = "一回の呼出\r\nState=operated",
    });
    try std.testing.expectEqual(body.len, try frameSize(buffer[0..4]));
    try std.testing.expectEqualStrings("Seq=98\nState=unknown\nAuthor=\nChannel=\nVideo=ZigTest0001\nWindow=4294967400\nDetail=一回の呼出  State=operated", body);
    const zero = [4]u8{ 0, 0, 0, 0 };
    const oversized = [4]u8{ 1, 0x80, 0, 0 };
    const limit = [4]u8{ 0, 0x80, 0, 0 };
    try std.testing.expectError(error.InvalidFrame, frameSize(&zero));
    try std.testing.expectError(error.InvalidFrame, frameSize(&oversized));
    try std.testing.expectEqual(@as(usize, max_frame), try frameSize(&limit));
}

test "chat discovery skips invalid UIA candidates and stops after two valid targets" {
    const provider = @import("uia_test_provider.zig");
    const sdk = win.sdk;
    const Node = provider.Node;
    var root: Node = .{ .kind = sdk.UIA_WindowControlTypeId, .handle = provider.hwnd };
    var document: Node = .{ .kind = sdk.UIA_DocumentControlTypeId, .parent = &root };
    var chat: Node = .{ .kind = sdk.UIA_GroupControlTypeId, .parent = &document, .class = provider.text("yt-live-chat-text-input-field-renderer") };
    var comment: Node = .{ .kind = sdk.UIA_GroupControlTypeId, .parent = &document, .class = provider.text("ytd-comment-simplebox-renderer") };
    var valid: Node = .{ .kind = sdk.UIA_EditControlTypeId, .parent = &chat, .editable = true, .id = provider.text("input") };
    var duplicate = valid;
    var broken = valid;
    broken.parent_fails = true;
    var hidden = valid;
    hidden.offscreen = true;
    var disabled = valid;
    disabled.enabled = false;
    var read_only = valid;
    read_only.read_only = true;
    var foreign = valid;
    foreign.foreign = true;
    var outside_document = valid;
    outside_document.parent = &root;
    var comment_field = valid;
    comment_field.parent = &comment;
    comment_field.id = provider.text("contenteditable-root");

    var worker: Worker = .{ .client = provider.client() };
    var window = provider.window();
    const rejected = [_]*Node{ &broken, &hidden, &disabled, &read_only, &foreign, &outside_document, &comment_field };
    provider.setCandidates(&root, &rejected);
    var reply: Reply = .{};
    try worker.moveFocus(&window, "ZigTest0001".*, null, &reply);
    try std.testing.expectEqualStrings("chat_missing", reply.state);
    for (rejected) |invalid| {
        for ([_][2]*Node{ .{ invalid, &valid }, .{ &valid, invalid } }) |order| {
            provider.setCandidates(&root, &order);
            const found = try pages.findChat(&worker.client, &window);
            try std.testing.expect(found == .target);
            win.release(found.target);
            try std.testing.expectEqual(&valid.element, found.target);
            try std.testing.expectEqual(@as(usize, 2), provider.candidate_reads);
        }
        try std.testing.expectEqual(@as(usize, 0), invalid.focus_calls);
        try invalid.expectReleased();
    }
    const ambiguous = [_]*Node{ &valid, &broken, &duplicate, &comment_field };
    provider.setCandidates(&root, &ambiguous);
    try worker.moveFocus(&window, "ZigTest0001".*, null, &reply);
    try std.testing.expectEqualStrings("chat_ambiguous", reply.state);
    try std.testing.expectEqual(@as(usize, 3), provider.candidate_reads);
    try std.testing.expect(worker.focus == null);
    for ([_]*Node{ &valid, &duplicate, &broken, &chat, &comment, &document, &root }) |node| {
        try std.testing.expectEqual(@as(usize, 0), node.focus_calls);
        try node.expectReleased();
    }
}

test "focused input publishes only the verified element and rejects failed ancestry" {
    const provider = @import("uia_test_provider.zig");
    const sdk = win.sdk;
    const Node = provider.Node;
    var document: Node = .{ .kind = sdk.UIA_DocumentControlTypeId };
    var chat: Node = .{ .kind = sdk.UIA_GroupControlTypeId, .parent = &document, .class = provider.text("yt-live-chat-text-input-field-renderer") };
    var field: Node = .{ .kind = sdk.UIA_EditControlTypeId, .parent = &chat, .editable = true, .id = provider.text("input") };
    var comment: Node = .{ .kind = sdk.UIA_EditControlTypeId, .parent = &document, .editable = true, .name = provider.text("Add a reply…") };
    var outside = field;
    outside.foreign = true;
    var unfocused = field;
    unfocused.focused = false;
    var search = field;
    search.id = provider.text("search");
    var detached = field;
    detached.parent_fails = true;

    var client = provider.client();
    var window = provider.window();
    for ([_]struct { target: *Node, kind: []const u8 }{ .{ .target = &field, .kind = "chat" }, .{ .target = &comment, .kind = "comment" } }) |example| {
        provider.setFocusObservations(example.target, example.target);
        const observed = (try client.focusedInput(&window)) orelse return error.ExpectedInput;
        win.release(observed.element);
        try std.testing.expectEqual(&example.target.element, observed.element);
        try std.testing.expectEqualStrings(example.kind, observed.kind);
    }
    for ([_][2]?*Node{ .{ null, null }, .{ &field, &comment }, .{ &field, null }, .{ &outside, &outside }, .{ &search, &search }, .{ &unfocused, &unfocused } }) |example| {
        provider.setFocusObservations(example[0], example[1]);
        try std.testing.expect(try client.focusedInput(&window) == null);
    }
    provider.setFocusObservations(&detached, &detached);
    try std.testing.expectError(error.AutomationUnavailable, client.focusedInput(&window));
    for ([_]*Node{ &field, &comment, &chat, &document, &outside, &search, &unfocused, &detached }) |node|
        try node.expectReleased();
}

test "address lookup checks document ownership, editing focus, and cached navigation" {
    const provider = @import("uia_test_provider.zig");
    const sdk = win.sdk;
    const Node = provider.Node;
    var root: Node = .{ .kind = sdk.UIA_WindowControlTypeId, .handle = provider.hwnd };
    var document: Node = .{ .kind = sdk.UIA_DocumentControlTypeId, .parent = &root };
    var child: Node = .{ .kind = sdk.UIA_EditControlTypeId, .focused = false };
    var address: Node = .{
        .kind = sdk.UIA_ComboBoxControlTypeId,
        .id = provider.text("urlbar-input"),
        .value = provider.text("https://www.youtube.com/watch?v=ZigTest0001"),
        .parent = &root,
        .editable = true,
        .focused = false,
        .focus_child = &child,
    };
    var decoy = address;
    decoy.parent = &document;
    decoy.value = provider.text("https://www.youtube.com/watch?v=ZigTest0003");
    var replacement: Node = .{
        .kind = sdk.UIA_EditControlTypeId,
        .id = provider.text("addressEditBox"),
        .value = provider.text("https://www.youtube.com/watch?v=ZigTest0004"),
        .parent = &root,
        .editable = true,
        .focused = false,
    };

    var client = provider.client();
    var window = provider.window();
    const candidates = [_]*Node{ &decoy, &address, &replacement };
    provider.setCandidates(&root, &candidates);
    const first = (try client.readVideoContext(&window)).?;
    try std.testing.expectEqualStrings("ZigTest0001", &first.id);
    try std.testing.expect(first.page == .watch);
    try std.testing.expectEqual(@as(usize, 0), decoy.value_reads);
    try std.testing.expectEqual(@as(usize, 2), provider.candidate_reads);

    child.focused = true;
    try std.testing.expect(try client.readVideoContext(&window) == null);
    try std.testing.expectEqual(@as(usize, 1), address.value_reads);
    child.focused = false;
    address.focused = true;
    try std.testing.expect(try client.readVideoContext(&window) == null);
    try std.testing.expectEqual(@as(usize, 1), address.value_reads);
    address.focused = false;
    address.value = provider.text("https://www.youtube.com/live_chat?v=ZigTest0002&is_popout=1");
    const navigated = (try client.readVideoContext(&window)).?;
    try std.testing.expectEqualStrings("ZigTest0002", &navigated.id);
    try std.testing.expect(navigated.page == .popout);
    address.value = provider.text("https://example.test/");
    try std.testing.expect(try client.readVideoContext(&window) == null);
    try std.testing.expectEqual(@as(usize, 2), provider.candidate_reads);
    try std.testing.expectEqual(@as(usize, 0), replacement.value_reads);

    address.foreign = true;
    provider.setCandidates(&root, candidates[2..]);
    const recovered = (try client.readVideoContext(&window)).?;
    try std.testing.expectEqualStrings("ZigTest0004", &recovered.id);
    try std.testing.expectEqual(@as(usize, 3), address.value_reads);
    replacement.offscreen = true;
    provider.setCandidates(&root, &.{});
    try std.testing.expect(try client.readVideoContext(&window) == null);
    try std.testing.expectEqual(@as(usize, 1), replacement.value_reads);
    for ([_]*Node{ &root, &document, &child, &address, &decoy, &replacement }) |node|
        try node.expectReleased();
}

test "launcher discovery tolerates unreadable ancestor attributes but rejects ambiguous launchers" {
    const provider = @import("uia_test_provider.zig");
    const sdk = win.sdk;
    const Node = provider.Node;
    var root: Node = .{ .kind = sdk.UIA_WindowControlTypeId, .handle = provider.hwnd };
    var document: Node = .{ .kind = sdk.UIA_DocumentControlTypeId, .parent = &root, .leaf_attributes_fail = true };
    var chat: Node = .{ .kind = sdk.UIA_GroupControlTypeId, .parent = &document, .class = provider.text("yt-live-chat-renderer"), .leaf_attributes_fail = true };
    var collapsed_parent: Node = .{ .kind = sdk.UIA_GroupControlTypeId, .parent = &chat, .id = provider.text("collapsed-button"), .leaf_attributes_fail = true };
    var labelled: Node = .{ .kind = sdk.UIA_ButtonControlTypeId, .parent = &chat, .name = provider.text("Send a reaction") };
    var panel: Node = .{ .kind = sdk.UIA_GroupControlTypeId, .parent = &chat, .id = provider.text("reaction-control-panel") };
    var collapsed: Node = .{ .kind = sdk.UIA_ButtonControlTypeId, .parent = &collapsed_parent, .class = provider.text("yt-reaction-control-panel-button-view-model") };
    var other_collapsed = collapsed;
    var other_panel = panel;
    var broken = labelled;
    broken.parent_fails = true;

    var worker: Worker = .{ .client = provider.client() };
    var window = provider.window();
    for ([_]struct { order: []const *Node, expected: *Node }{
        .{ .order = &.{ &broken, &labelled }, .expected = &labelled },
        .{ .order = &.{ &labelled, &panel }, .expected = &panel },
        .{ .order = &.{ &collapsed, &panel, &labelled }, .expected = &collapsed },
        .{ .order = &.{ &labelled, &panel, &collapsed }, .expected = &collapsed },
    }) |example| {
        provider.setCandidates(&root, example.order);
        const target = (try pages.findLauncher(&worker.client, &window)) orelse return error.ExpectedLauncher;
        win.release(target);
        try std.testing.expectEqual(&example.expected.element, target);
    }
    for ([_][]const *Node{ &.{&broken}, &.{ &collapsed, &other_collapsed, &panel, &labelled }, &.{ &panel, &other_panel, &labelled } }) |order| {
        provider.setCandidates(&root, order);
        var reply: Reply = .{};
        try worker.hover(&window, "ZigTest0001".*, null, &reply);
        try std.testing.expectEqualStrings("unsupported", reply.state);
    }
    // A chat-looking subtree under browser chrome still needs a document.
    chat.parent = &root;
    provider.setCandidates(&root, &.{&labelled});
    try std.testing.expect(try pages.findLauncher(&worker.client, &window) == null);
    for ([_]*Node{ &collapsed_parent, &chat, &document, &root }) |ancestor|
        try std.testing.expectEqual(@as(usize, 0), ancestor.leaf_reads);
    for ([_]*Node{ &labelled, &panel, &collapsed, &other_collapsed, &other_panel, &broken, &collapsed_parent, &chat, &document, &root }) |node| {
        try std.testing.expectEqual(@as(usize, 0), node.geometry_reads);
        try node.expectReleased();
    }
}

test {
    _ = @import("rules.zig");
    _ = win;
    _ = pages;
    _ = reactions;
    _ = metadata;
}
