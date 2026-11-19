const std = @import("std");
const uia = @import("uia.zig");

const Handle = std.os.windows.HANDLE;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn OpenEventW(u32, i32, [*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn SetEvent(Handle) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(Handle, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const max_frame = 32768;

const Request = struct {
    seq: []const u8,
    window: []const u8,
    hwnd: usize,
    mode: []const u8,
    expected: []const u8,
};

fn decimal(comptime T: type, digits: []const u8) !T {
    if (digits.len > 20) return error.InvalidNumber;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidNumber;
    return std.fmt.parseUnsigned(T, digits, 10);
}

fn parseRequest(frame: []const u8) !Request {
    if (!std.unicode.utf8ValidateSlice(frame)) return error.InvalidEncoding;
    var seq: []const u8 = "";
    var window: []const u8 = "";
    var mode: []const u8 = "";
    var expected: []const u8 = "";
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |line| {
        const index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..index];
        const value = line[index + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, "Seq")) {
            seq = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Window")) {
            window = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Mode")) {
            mode = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Video")) {
            expected = value;
        }
    }
    _ = try decimal(u64, seq);
    return .{ .seq = seq, .window = window, .hwnd = try decimal(usize, window), .mode = mode, .expected = expected };
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

fn writeExactly(pipe: Handle, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        var count: u32 = 0;
        if (WriteFile(pipe, data[offset..].ptr, @intCast(data.len - offset), &count, null) == 0 or count == 0)
            return error.WriteFailed;
        offset += count;
    }
}

fn serve(pipe: Handle, ready: Handle) !void {
    if (SetEvent(ready) == 0) return error.SignalFailed;
    var client = try uia.Client.init();
    defer client.deinit();
    var frame: [max_frame]u8 = undefined;
    while (true) {
        var header: [4]u8 = undefined;
        readExactly(pipe, &header) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        const size = std.mem.readInt(u32, &header, .little);
        if (size == 0 or size > frame.len) return error.InvalidFrame;
        try readExactly(pipe, frame[0..size]);
        const req = try parseRequest(frame[0..size]);
        const verify = std.ascii.eqlIgnoreCase(req.mode, "verify_input");
        var state: []const u8 = "unavailable";
        var video: [11]u8 = undefined;
        var has_video = false;
        var detail: []const u8 = "";
        if (verify or std.ascii.eqlIgnoreCase(req.mode, "browser_context")) {
            if (client.inspect(req.hwnd, verify, req.expected)) |result| {
                state = result.state;
                if (result.has_video) video = result.video;
                has_video = result.has_video;
                detail = result.detail;
            } else |_| {
                // A stale window or provider failure cannot authorize input.
            }
        }
        var reply: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(reply[4..], "Seq={s}\nState={s}\nAuthor=\nChannel=\nVideo={s}\nWindow={s}\nDetail={s}", .{
            req.seq, state, if (has_video) &video else "", req.window, detail,
        });
        std.mem.writeInt(u32, reply[0..4], @intCast(body.len), .little);
        try writeExactly(pipe, reply[0 .. 4 + body.len]);
        if (SetEvent(ready) == 0) return error.SignalFailed;
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
    const name = args[2];
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
    try std.testing.expectEqualStrings("verify_input", req.mode);
    try std.testing.expectEqualStrings("Abc-def_012", req.expected);
    try std.testing.expectError(error.InvalidNumber, parseRequest("Seq=1\nWindow=+12\n"));
}

test {
    _ = @import("rules.zig");
}
