//! Process fixture used by the runner tests. It has no access to application data.
const std = @import("std");
const win = std.os.windows;
extern "kernel32" fn GetProcessId(win.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn OpenEventW(win.DWORD, win.BOOL, win.LPCWSTR) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn SetEvent(win.HANDLE) callconv(.winapi) win.BOOL;

fn field(line: []const u8, name: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, line, '\n');
    while (fields.next()) |entry| {
        const divider = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..divider], name)) return entry[divider + 1 ..];
    }
    return null;
}

fn pipeFault(allocator: std.mem.Allocator, pipe_name: []const u8, fault: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\{s}", .{pipe_name});
    defer allocator.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(path_w);
    const pipe = win.kernel32.CreateFileW(path_w.ptr, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, 0, null);
    if (pipe == win.INVALID_HANDLE_VALUE) return error.CouldNotConnectFixture;
    const file: std.fs.File = .{ .handle = pipe };
    defer file.close();
    const event = try std.fmt.allocPrint(allocator, "{s}-ready", .{pipe_name});
    defer allocator.free(event);
    const event_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, event);
    defer allocator.free(event_w);
    const signal = OpenEventW(2, win.FALSE, event_w.ptr) orelse return error.MissingFixtureEvent;
    defer win.CloseHandle(signal);
    _ = SetEvent(signal);

    for (0..2) |i| {
        var header: [4]u8 = undefined;
        if (try file.readAll(&header) != header.len) return;
        const length = std.mem.readInt(u32, &header, .little);
        var request_storage: [32768]u8 = undefined;
        if (length < 1 or length > request_storage.len) return error.InvalidFixtureRequest;
        const request = request_storage[0..length];
        if (try file.readAll(request) != length) return;
        if (std.mem.eql(u8, fault, "timeout")) {
            std.Thread.sleep(12 * std.time.ns_per_s);
            return;
        }
        if (std.mem.eql(u8, fault, "exit-after-one") and i == 1) return;
        const sequence = if (std.mem.eql(u8, fault, "wrong-seq")) "9999" else field(request, "Seq") orelse return error.MissingFixtureField;
        const hwnd = if (std.mem.eql(u8, fault, "wrong-window")) "9999" else field(request, "Window") orelse return error.MissingFixtureField;
        var buffer: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&buffer, "Seq={s}\nWindow={s}\nState=unavailable\nVideo=\nDetail=fixture-private https://private.example/ ZigTest0001", .{ sequence, hwnd });
        if (std.mem.eql(u8, fault, "exit-after-one")) {
            const marker = try std.fs.cwd().createFile("fixture-worker-starts.txt", .{ .truncate = false, .read = true });
            defer marker.close();
            try marker.seekFromEnd(0);
            try marker.writeAll("start\n");
        }
        const size: u32 = if (std.mem.eql(u8, fault, "oversized")) 32769 else @intCast(response.len);
        std.mem.writeInt(u32, &header, size, .little);
        try file.writeAll(&header);
        if (size < 32769) try file.writeAll(response);
        _ = SetEvent(signal);
    }
    var discarded: [1]u8 = undefined;
    _ = file.read(&discarded) catch return;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len == 3 and std.mem.eql(u8, args[1], "-PipeName")) {
        const fault = std.fs.path.stem(args[0]);
        if (std.mem.eql(u8, fault, "wrong-pid")) {
            var child = std.process.Child.init(&.{ args[0], "--relay", args[2] }, allocator);
            try child.spawn();
            _ = try child.wait();
            return;
        }
        return pipeFault(allocator, args[2], fault);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "--relay")) return pipeFault(allocator, args[2], "relay");
    if (args.len != 2) return error.InvalidFixtureArguments;
    if (std.mem.eql(u8, args[1], "--smoke")) {
        try std.fs.File.stdout().writeAll("PASS\n");
        return;
    }
    if (std.mem.eql(u8, args[1], "stderr")) {
        try std.fs.File.stderr().writeAll("synthetic failure\n");
        return;
    }
    if (std.mem.eql(u8, args[1], "linger")) {
        var descendant = std.process.Child.init(&.{ args[0], "sleep" }, allocator);
        try descendant.spawn();
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{d}\n", .{GetProcessId(descendant.id)});
        try std.fs.File.stdout().writeAll(line);
        _ = try descendant.wait();
        return;
    }
    if (std.mem.eql(u8, args[1], "sleep")) {
        std.Thread.sleep(60 * std.time.ns_per_s);
        return;
    }
    return error.InvalidFixtureArguments;
}
