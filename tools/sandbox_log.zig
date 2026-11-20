const std = @import("std");

pub const Tail = struct {
    inode: ?std.fs.File.INode = null,
    scanned: u64 = 0,
    emitted: u64 = 0,

    pub fn update(
        self: *Tail,
        root: std.fs.Dir,
        file_name: []const u8,
        writer: *std.Io.Writer,
        complete: bool,
    ) !void {
        const log = root.openFile(file_name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (self.inode != null) return error.SandboxLogReplaced;
                return;
            },
            else => return err,
        };
        defer log.close();
        const snapshot = try log.stat();
        if (snapshot.kind != .file) return error.SandboxLogIsNotAFile;
        if (self.inode) |existing| {
            if (existing != snapshot.inode) return error.SandboxLogReplaced;
        } else {
            self.inode = snapshot.inode;
        }
        if (snapshot.size < self.scanned) return error.SandboxLogTruncated;

        var buffer: [8192]u8 = undefined;
        // Scan only new bytes. Unfinished lines stay in the file until a newline or completion.
        var end = self.emitted;
        while (self.scanned < snapshot.size) {
            const length: usize = @intCast(@min(buffer.len, snapshot.size - self.scanned));
            const n = try log.pread(buffer[0..length], self.scanned);
            if (n == 0) return error.SandboxLogTruncated;
            if (std.mem.lastIndexOfScalar(u8, buffer[0..n], '\n')) |newline| {
                end = self.scanned + newline + 1;
            }
            self.scanned += n;
        }
        if (complete) end = self.scanned;
        while (self.emitted < end) {
            const length: usize = @intCast(@min(buffer.len, end - self.emitted));
            const n = try log.pread(buffer[0..length], self.emitted);
            if (n == 0) return error.SandboxLogTruncated;
            try writer.writeAll(buffer[0..n]);
            self.emitted += n;
        }
        try writer.flush();
    }
};

test "Sandbox logs forward complete Unicode lines once and drain their final fragment" {
    const alloc = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var tail: Tail = .{};
    var capture = std.Io.Writer.Allocating.init(alloc);
    defer capture.deinit();
    try tail.update(temporary.dir, "stdout.txt", &capture.writer, false);
    const log = try temporary.dir.createFile("stdout.txt", .{});
    defer log.close();
    const first = "first 日本語 🧪\r\n";
    const split = first.len - 4;
    try log.writeAll(first[0..split]);
    try tail.update(temporary.dir, "stdout.txt", &capture.writer, false);
    try std.testing.expectEqualStrings("", capture.written());
    try log.writeAll(first[split..]);
    try tail.update(temporary.dir, "stdout.txt", &capture.writer, false);
    try tail.update(temporary.dir, "stdout.txt", &capture.writer, false);
    try std.testing.expectEqualStrings(first, capture.written());
    try log.writeAll("\r\nsecond\ntail 日本語 🧪");
    try tail.update(temporary.dir, "stdout.txt", &capture.writer, false);
    try std.testing.expectEqualStrings(first ++ "\r\nsecond\n", capture.written());
    try tail.update(temporary.dir, "stdout.txt", &capture.writer, true);
    try tail.update(temporary.dir, "stdout.txt", &capture.writer, true);
    try std.testing.expectEqualStrings(first ++ "\r\nsecond\ntail 日本語 🧪", capture.written());
    try log.setEndPos(0);
    try std.testing.expectError(error.SandboxLogTruncated, tail.update(temporary.dir, "stdout.txt", &capture.writer, false));
}
