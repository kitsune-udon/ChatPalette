const std = @import("std");
const windows = @import("win.zig");
const win = windows.api;
const allocator = std.heap.page_allocator;
const max_payload = 32768;
const invalid_handle = std.os.windows.INVALID_HANDLE_VALUE;
const StopWait = fn (*Client, u32) win.DWORD;

fn waitForProcess(handle: win.HANDLE, milliseconds: u32) win.DWORD {
    return win.WaitForSingleObject(handle, milliseconds);
}

fn waitForOwnedProcess(client: *Client, milliseconds: u32) win.DWORD {
    return waitForProcess(client.process, milliseconds);
}

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

    pub fn deadlineMs(self: Mode) u64 {
        return switch (self) {
            .verify_input, .verify_chat, .chat_enter, .chat_clear, .input_insert => 2500,
            else => 8000,
        };
    }

    pub fn inputOutcome(self: Mode) ?[]const u8 {
        return switch (self) {
            .chat_enter => "enter_sent",
            .chat_clear => "cleared",
            .input_insert => "inserted",
            else => null,
        };
    }
};

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Reply = struct {
    payload: []const u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: Reply) void {
        self.alloc.free(self.payload);
    }

    pub fn field(self: Reply, name: []const u8) []const u8 {
        var lines = std.mem.splitScalar(u8, self.payload, '\n');
        while (lines.next()) |line| {
            const end = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, name, line[0..end])) return line[end + 1 ..];
        }
        return "";
    }

    pub fn is(self: Reply, state: []const u8) bool {
        return std.mem.eql(u8, self.field("State"), state);
    }

    fn matches(self: Reply, seq: u64, hwnd: usize) bool {
        return self.field("State").len != 0 and
            decimal(u64, self.field("Seq")) == seq and decimal(usize, self.field("Window")) == hwnd;
    }
};

fn decimal(comptime T: type, digits: []const u8) ?T {
    for (digits) |digit| if (!std.ascii.isDigit(digit)) return null;
    return std.fmt.parseUnsigned(T, digits, 10) catch null;
}

/// The caller keeps request ownership while the message pump processes stop and window events.
pub const Pump = *const fn (signal: win.HANDLE, milliseconds: u32) anyerror!void;

pub const Launch = struct {
    executable: [:0]const u16,
    arguments_before_pipe: []const u8 = "",
    working_directory: ?[:0]const u16 = null,
};

const StartupHandles = struct {
    pipe: win.HANDLE = null,
    signal: win.HANDLE = null,
    before_listen: ?*const fn ([]const u8) anyerror!void = null,
};

pub const Client = struct {
    pipe: win.HANDLE = null,
    process: win.HANDLE = null,
    signal: win.HANDLE = null,
    sequence: u64 = 0,
    active: bool = false,
    request_may_have_arrived: bool = false,
    registrations_current: bool = false,
    cleanup_failure: ?anyerror = null,

    fn running(self: Client) bool {
        return self.process != null and win.WaitForSingleObject(self.process, 0) == win.WAIT_TIMEOUT;
    }

    pub fn registrationsReady(self: Client) bool {
        return self.registrations_current and self.running();
    }

    pub fn acceptRegistrationReply(self: *Client, reply: Reply) !void {
        self.registrations_current = reply.is("configured") and self.running();
        if (!self.registrations_current) return error.WorkerRegistrationSyncFailed;
    }

    pub fn stop(self: *Client) !void {
        return self.stopWithWait(waitForOwnedProcess);
    }

    fn stopWithWait(self: *Client, comptime observe: StopWait) !void {
        self.registrations_current = false;
        if (self.pipe != null) {
            _ = win.CloseHandle(self.pipe);
            self.pipe = null;
        }
        if (self.signal != null) {
            _ = win.CloseHandle(self.signal);
            self.signal = null;
        }
        if (self.process != null) {
            var state = observe(self, 250);
            if (state == win.WAIT_TIMEOUT) {
                _ = win.TerminateProcess(self.process, 1);
                state = observe(self, 2000);
            }
            if (state != win.WAIT_OBJECT_0) return error.WorkerDidNotExit;
            _ = win.CloseHandle(self.process);
            self.process = null;
        }
    }

    fn ensure(self: *Client, launch: Launch, comptime observe: StopWait) !void {
        if (self.running() and self.pipe != null) return;
        try self.stopWithWait(observe);
        const name = try newPipeName(allocator);
        defer allocator.free(name);
        try self.startNamed(launch, name, observe, null);
    }

    fn startNamed(self: *Client, launch: Launch, name: []const u8, comptime observe: StopWait, acquired: ?*StartupHandles) !void {
        errdefer self.stopWithWait(observe) catch |failure| {
            self.cleanup_failure = failure;
        };
        const pipe = try createPipe(name);
        self.pipe = pipe;
        if (acquired) |record| {
            record.pipe = pipe;
            if (record.before_listen) |prepare| try prepare(name);
        }
        try listen(pipe);

        const signal_w = try readyName(allocator, name);
        defer allocator.free(signal_w);
        win.SetLastError(0);
        self.signal = win.CreateEventW(null, 0, 0, signal_w);
        const signal_error = win.GetLastError();
        if (acquired) |record| record.signal = self.signal;
        if (self.signal == null or signal_error == win.ERROR_ALREADY_EXISTS) return error.CreateWorkerSignal;

        self.process = try spawnWorker(launch, name);
    }

    pub fn request(
        self: *Client,
        alloc: std.mem.Allocator,
        executable: [:0]const u16,
        mode: Mode,
        hwnd: usize,
        expected: []const u8,
        fields: []const Field,
        pump: Pump,
    ) !Reply {
        return self.requestWithLaunch(alloc, .{ .executable = executable }, true, mode, hwnd, expected, fields, pump);
    }

    pub fn requestWithLaunch(
        self: *Client,
        alloc: std.mem.Allocator,
        launch: Launch,
        allow_start: bool,
        mode: Mode,
        hwnd: usize,
        expected: []const u8,
        fields: []const Field,
        pump: Pump,
    ) !Reply {
        return self.requestObserved(alloc, launch, allow_start, mode, hwnd, expected, fields, pump, waitForOwnedProcess);
    }

    fn requestObserved(
        self: *Client,
        alloc: std.mem.Allocator,
        launch: Launch,
        allow_start: bool,
        mode: Mode,
        hwnd: usize,
        expected: []const u8,
        fields: []const Field,
        pump: Pump,
        comptime observe: StopWait,
    ) !Reply {
        if (self.active) return error.WorkerBusy;
        self.active = true;
        defer self.active = false;
        self.request_may_have_arrived = false;
        self.cleanup_failure = null;
        if (allow_start) {
            try self.ensure(launch, observe);
        } else if (!self.running() or self.pipe == null) {
            return error.WorkerExited;
        }
        self.sequence +%= 1;
        errdefer self.stopWithWait(observe) catch |failure| {
            self.cleanup_failure = failure;
        };
        var buffer: [max_payload + 4]u8 = undefined;
        const request_bytes = try formatRequest(&buffer, self.sequence, hwnd, mode, expected, fields);
        return self.exchange(alloc, mode, request_bytes, hwnd, pump);
    }

    fn exchange(self: *Client, alloc: std.mem.Allocator, mode: Mode, request_bytes: []const u8, hwnd: usize, pump: Pump) !Reply {
        var timer = try std.time.Timer.start();
        const limit = mode.deadlineMs() * std.time.ns_per_ms;
        var sent = false;
        while (timer.read() < limit) {
            if (!self.running()) return error.WorkerExited;
            if (!sent) {
                var pid: win.ULONG = undefined;
                if (win.GetNamedPipeClientProcessId(self.pipe, &pid) != 0) {
                    if (pid != win.GetProcessId(self.process)) return error.WrongWorkerProcess;
                    var written: win.DWORD = 0;
                    // A failed or partial write can still have reached the pipe.
                    self.request_may_have_arrived = true;
                    if (win.WriteFile(self.pipe, request_bytes.ptr, @intCast(request_bytes.len), &written, null) == 0 or written != request_bytes.len)
                        return error.WriteWorkerRequest;
                    sent = true;
                }
            } else if (try self.read(alloc)) |reply| {
                errdefer reply.deinit();
                if (!reply.matches(self.sequence, hwnd)) return error.MismatchedWorkerReply;
                return reply;
            }
            const remaining = limit -| timer.read();
            if (remaining == 0) break;
            const wait_ms = std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch unreachable;
            try pump(self.signal, @intCast(@min(50, wait_ms)));
        }
        return error.WorkerTimeout;
    }

    fn read(self: Client, alloc: std.mem.Allocator) !?Reply {
        var header: [4]u8 = undefined;
        var copied: win.DWORD = 0;
        var available: win.DWORD = 0;
        if (win.PeekNamedPipe(self.pipe, &header, 4, &copied, &available, null) == 0) return error.WorkerPipeClosed;
        if (copied < 4) return null;
        const size = std.mem.readInt(u32, &header, .little);
        if (size == 0 or size > max_payload) return error.InvalidWorkerFrame;
        if (available < size + 4) return null;
        if (win.ReadFile(self.pipe, &header, 4, &copied, null) == 0 or copied != 4) return error.ReadWorkerReply;
        const payload = try alloc.alloc(u8, size);
        errdefer alloc.free(payload);
        if (win.ReadFile(self.pipe, payload.ptr, size, &copied, null) == 0 or copied != size) return error.ReadWorkerReply;
        if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidWorkerEncoding;
        return .{ .payload = payload, .alloc = alloc };
    }
};

fn newPipeName(alloc: std.mem.Allocator) ![]u8 {
    var guid: win.GUID = undefined;
    if (win.CoCreateGuid(&guid) < 0) return error.PipeIdentifier;
    var guid_text: [39]u16 = undefined;
    if (win.StringFromGUID2(&guid, &guid_text, guid_text.len) != guid_text.len) return error.PipeIdentifier;
    const text = try std.unicode.utf16LeToUtf8Alloc(alloc, guid_text[0..38]);
    defer alloc.free(text);
    return std.fmt.allocPrint(alloc, "youtube-helper-{s}", .{text});
}

fn pipePath(name: []const u8) ![:0]u16 {
    var buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "\\\\.\\pipe\\{s}", .{name});
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
}

fn createPipe(name: []const u8) !win.HANDLE {
    const path_w = try pipePath(name);
    defer allocator.free(path_w);
    const pipe = win.CreateNamedPipeW(path_w, win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_FIRST_PIPE_INSTANCE, win.PIPE_NOWAIT | win.PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, null);
    if (pipe == invalid_handle or pipe == null) return error.CreateWorkerPipe;
    return pipe;
}

fn listen(pipe: win.HANDLE) !void {
    if (win.ConnectNamedPipe(pipe, null) != 0) return;
    switch (win.GetLastError()) {
        win.ERROR_PIPE_LISTENING, win.ERROR_PIPE_CONNECTED => {},
        else => return error.ListenWorkerPipe,
    }
}

fn readyName(alloc: std.mem.Allocator, name: []const u8) ![:0]u16 {
    var buffer: [96]u8 = undefined;
    const signal = try std.fmt.bufPrint(&buffer, "{s}-ready", .{name});
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, signal);
}

fn spawnWorker(launch: Launch, name: []const u8) !win.HANDLE {
    const exe = try std.unicode.utf16LeToUtf8Alloc(allocator, launch.executable);
    defer allocator.free(exe);
    const args = try std.fmt.allocPrint(allocator, "\"{s}\" {s} -PipeName {s}", .{ exe, launch.arguments_before_pipe, name });
    defer allocator.free(args);
    const command = try std.unicode.utf8ToUtf16LeAllocZ(allocator, args);
    defer allocator.free(command);
    var startup = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    var child: win.PROCESS_INFORMATION = undefined;
    const directory = if (launch.working_directory) |cwd| cwd.ptr else null;
    if (win.CreateProcessW(launch.executable, command, null, null, 0, win.CREATE_NO_WINDOW, null, directory, &startup, &child) == 0)
        return error.StartWorker;
    _ = win.CloseHandle(child.hThread);
    return child.hProcess;
}

fn formatRequest(buffer: *[max_payload + 4]u8, sequence: u64, hwnd: usize, mode: Mode, expected: []const u8, fields: []const Field) ![]const u8 {
    if (std.mem.indexOfAny(u8, expected, "\r\n") != null) return error.InvalidWorkerField;
    var output = std.Io.Writer.fixed(buffer[4..]);
    output.print("Seq={d}\nWindow={d}\nMode={s}\nVideo={s}\n", .{ sequence, hwnd, @tagName(mode), expected }) catch return error.InvalidWorkerRequestSize;
    for (fields) |field| {
        if (field.name.len == 0 or std.mem.indexOfAny(u8, field.value, "\r\n") != null) return error.InvalidWorkerField;
        for (field.name) |ch| if (!std.ascii.isAlphabetic(ch)) return error.InvalidWorkerField;
        output.print("{s}={s}\n", .{ field.name, field.value }) catch return error.InvalidWorkerRequestSize;
    }
    const length = output.end;
    std.mem.writeInt(u32, buffer[0..4], @intCast(length), .little);
    return buffer[0 .. length + 4];
}

/// Used by the headless lifecycle test executable to exercise the production acquisition and wait paths.
pub const LifecycleProbe = struct {
    pub const Acquisition = enum { pipe_collision, disconnected_before_listen, ready_event_collision, missing_executable };

    pub fn checkAcquisition(alloc: std.mem.Allocator, missing: Launch, point: Acquisition) !void {
        const name = try newPipeName(alloc);
        defer alloc.free(name);
        const ready = try readyName(alloc, name);
        defer alloc.free(ready);

        const held = switch (point) {
            .pipe_collision => try createPipe(name),
            .ready_event_collision => win.CreateEventW(null, 0, 0, ready) orelse return error.CreateFixtureEvent,
            .disconnected_before_listen, .missing_executable => null,
        };
        defer if (held != null) {
            _ = win.CloseHandle(held);
        };

        var client: Client = .{};
        defer client.stop() catch {};
        var acquired: StartupHandles = .{
            .before_listen = if (point == .disconnected_before_listen) closeFixturePeer else null,
        };
        const expected = switch (point) {
            .pipe_collision => error.CreateWorkerPipe,
            .disconnected_before_listen => error.ListenWorkerPipe,
            .ready_event_collision => error.CreateWorkerSignal,
            .missing_executable => error.StartWorker,
        };
        if (client.startNamed(missing, name, waitForOwnedProcess, &acquired)) |_| {
            return error.UnexpectedWorkerStart;
        } else |failure| {
            if (failure != expected) return failure;
        }
        if (client.pipe != null or client.signal != null or client.process != null or client.cleanup_failure != null)
            return error.WorkerStartupResourcesRetained;
        switch (point) {
            .pipe_collision => {
                if (acquired.pipe != null or acquired.signal != null) return error.PipeCollisionAcquiredWorkerResources;
                var flags: win.DWORD = 0;
                if (win.GetHandleInformation(held, &flags) == 0) return error.FixturePipeWasClosed;
            },
            .disconnected_before_listen => {
                try confirmHandleClosed(acquired.pipe);
                if (acquired.signal != null) return error.PipeListenFailureAcquiredReadyEvent;
                try confirmPipeClosed(name);
            },
            .ready_event_collision => {
                try confirmHandleClosed(acquired.pipe);
                try confirmHandleClosed(acquired.signal);
                if (win.SetEvent(held) == 0 or win.WaitForSingleObject(held, 0) != win.WAIT_OBJECT_0)
                    return error.FixtureEventWasClosed;
                try confirmPipeClosed(name);
            },
            .missing_executable => {
                try confirmHandleClosed(acquired.pipe);
                try confirmHandleClosed(acquired.signal);
                try confirmPipeClosed(name);
                if (win.OpenEventW(win.SYNCHRONIZE, 0, ready)) |unexpected| {
                    _ = win.CloseHandle(unexpected);
                    return error.FailedStartLeftReadyEvent;
                }
                if (win.GetLastError() != win.ERROR_FILE_NOT_FOUND) return error.ReadyEventStatusUnavailable;
            },
        }
    }

    fn closeFixturePeer(name: []const u8) !void {
        const path = try pipePath(name);
        defer allocator.free(path);
        const peer = win.CreateFileW(path, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, 0, null);
        if (peer == null or peer == invalid_handle) return error.OpenFixturePeer;
        // A peer that closes before the server listens leaves ConnectNamedPipe reporting ERROR_NO_DATA.
        if (win.CloseHandle(peer) == 0) return error.CloseFixturePeer;
    }

    fn confirmHandleClosed(handle: win.HANDLE) !void {
        var flags: win.DWORD = 0;
        if (handle == null or win.GetHandleInformation(handle, &flags) != 0 or win.GetLastError() != win.ERROR_INVALID_HANDLE)
            return error.WorkerStartupHandleWasNotReleased;
    }

    fn confirmPipeClosed(name: []const u8) !void {
        const reopened = try createPipe(name);
        defer _ = win.CloseHandle(reopened);
        try listen(reopened);
    }

    pub fn requestWithUnconfirmedExit(
        client: *Client,
        alloc: std.mem.Allocator,
        launch: Launch,
        mode: Mode,
        fields: []const Field,
        pump: Pump,
    ) !Reply {
        return client.requestObserved(alloc, launch, true, mode, 0, "", fields, pump, unconfirmedExit);
    }

    // Withhold the OS confirmation only if cleanup still owns the request and
    // rejects a concurrent entry before changing its sequence or ownership.
    fn unconfirmedExit(client: *Client, milliseconds: u32) win.DWORD {
        const state = waitForOwnedProcess(client, milliseconds);
        if (state != win.WAIT_OBJECT_0) return state;
        const process = client.process;
        const sequence = client.sequence;
        const launch: Launch = .{ .executable = windows.wide("") };
        const nested = client.requestWithLaunch(allocator, launch, false, .browser_context, 0, "", &.{}, unexpectedPump) catch |failure| {
            return if (failure == error.WorkerBusy and client.process == process and client.sequence == sequence and client.active)
                win.WAIT_FAILED
            else
                state;
        };
        nested.deinit();
        return state;
    }

    fn unexpectedPump(_: win.HANDLE, _: u32) anyerror!void {
        return error.NestedRequestEnteredMessagePump;
    }

    pub fn checkMissingEndpoint(alloc: std.mem.Allocator, launch: Launch, missing: enum { pipe, ready_event }) !u32 {
        const name = try newPipeName(alloc);
        defer alloc.free(name);
        const observed = try missingEndpoint(launch, name, missing == .ready_event);
        try confirmHandleClosed(observed.child);
        if (observed.server != null) try confirmHandleClosed(observed.server);
        if (observed.exit_code != 1) return error.MissingWorkerEndpointWasAccepted;
        return observed.exit_code;
    }

    fn missingEndpoint(launch: Launch, name: []const u8, listen_without_event: bool) !struct { exit_code: u32, child: win.HANDLE, server: win.HANDLE } {
        const server = if (listen_without_event) try createPipe(name) else null;
        defer if (server != null) {
            _ = win.CloseHandle(server);
        };
        if (server != null) try listen(server);
        const child = try spawnWorker(launch, name);
        defer _ = win.CloseHandle(child);
        if (waitForProcess(child, 8000) != win.WAIT_OBJECT_0) {
            _ = win.TerminateProcess(child, 1);
            _ = waitForProcess(child, 2000);
            return error.WorkerEndpointExitUnconfirmed;
        }
        var exit_code: win.DWORD = 0;
        if (win.GetExitCodeProcess(child, &exit_code) == 0) return error.WorkerExitCodeUnavailable;
        return .{ .exit_code = exit_code, .child = child, .server = server };
    }
};

test "host frames use the production field names, byte count and ownership checks" {
    var storage: [max_payload + 4]u8 = undefined;
    const bytes = try formatRequest(&storage, 12, 84, .verify_chat, "ZigTest0001", &.{.{ .name = "FocusToken", .value = "once" }});
    try std.testing.expectEqual(bytes.len - 4, std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqualStrings("Seq=12\nWindow=84\nMode=verify_chat\nVideo=ZigTest0001\nFocusToken=once\n", bytes[4..]);
    const reply = Reply{ .alloc = undefined, .payload = "Seq=12\nWindow=84\nState=ok\nVideo=ZigTest0001\nDetail=chat" };
    try std.testing.expect(reply.matches(12, 84) and reply.is("ok"));
    try std.testing.expect(!reply.matches(12, 85));
    try std.testing.expectError(error.InvalidWorkerField, formatRequest(&storage, 12, 84, .reaction_send, "ZigTest0001\nState=ok", &.{}));
    const too_large = [_]u8{'x'} ** max_payload;
    try std.testing.expectError(error.InvalidWorkerRequestSize, formatRequest(&storage, 12, 84, .verify_input, "", &.{
        .{ .name = "Payload", .value = &too_large },
    }));
}

test "native child acquisition releases the pipe and the ready event at each failure boundary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const missing = try std.fs.path.join(alloc, &.{ root, "missing-worker.exe" });
    defer alloc.free(missing);
    const missing_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, missing);
    defer alloc.free(missing_w);
    for (std.meta.tags(LifecycleProbe.Acquisition)) |case| {
        try LifecycleProbe.checkAcquisition(alloc, .{ .executable = missing_w }, case);
    }
}
