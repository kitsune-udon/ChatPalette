const std = @import("std");
const windows = std.os.windows;

pub const digest_len = std.crypto.hash.sha2.Sha256.digest_length;
pub const Digest = [digest_len]u8;
pub const HexDigest = [digest_len * 2]u8;

extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, windows.DWORD) callconv(.winapi) windows.BOOL;

pub fn digest(bytes: []const u8) Digest {
    var value: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &value, .{});
    return value;
}

pub fn hex(bytes: Digest) HexDigest {
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn fileDigest(file: std.fs.File) !Digest {
    var state = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const size = try file.read(&buffer);
        if (size == 0) break;
        state.update(buffer[0..size]);
    }
    return state.finalResult();
}

pub fn readDigest(dir: std.fs.Dir, path: []const u8) !Digest {
    const file = try dir.openFile(path, .{});
    defer file.close();
    return fileDigest(file);
}

/// The retained handle denies writes and replacement by another process during examination.
pub fn openImmutable(allocator: std.mem.Allocator, absolute_path: []const u8) !std.fs.File {
    const path = try std.unicode.utf8ToUtf16LeAllocZ(allocator, absolute_path);
    defer allocator.free(path);
    const handle = windows.kernel32.CreateFileW(
        path.ptr,
        windows.GENERIC_READ,
        windows.FILE_SHARE_READ,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .SHARING_VIOLATION => error.InputInUse,
        .ACCESS_DENIED => error.AccessDenied,
        else => error.CouldNotReadImmutableInput,
    };
    return .{ .handle = handle };
}

pub fn writeNew(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

pub fn newDirectory(allocator: std.mem.Allocator, parent: []const u8, prefix: []const u8) ![]u8 {
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const encoded = std.fmt.bytesToHex(random, .lower);
    const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, encoded });
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ parent, name });
    errdefer allocator.free(path);
    try std.fs.cwd().makeDir(path);
    return path;
}

/// Windows refuses to replace an existing destination when MOVEFILE_REPLACE_EXISTING is absent.
pub fn publish(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    const source_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, source);
    defer allocator.free(source_w);
    const destination_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, destination);
    defer allocator.free(destination_w);
    for (0..5) |attempt| {
        if (MoveFileExW(source_w.ptr, destination_w.ptr, windows.MOVEFILE_WRITE_THROUGH) != 0) return;
        const cause = windows.GetLastError();
        switch (cause) {
            .ALREADY_EXISTS, .FILE_EXISTS => return error.OutputExists,
            .SHARING_VIOLATION, .ACCESS_DENIED => {
                // Windows can briefly hold a newly created executable for scanning.
                if (std.fs.cwd().access(destination, .{})) |_| {
                    return error.OutputExists;
                } else |_| {}
                if (attempt < 4) {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    continue;
                }
            },
            else => {},
        }
        std.debug.print("MoveFileExW {d}\n", .{@intFromEnum(cause)});
        return error.PublishFailed;
    }
    unreachable;
}
