const std = @import("std");
const files = @import("files.zig");
const zip = std.zip;

pub const manifest_name = "SHA256SUMS";
const utf8_flag: u16 = 1 << 11;
const zip_version = 20;
const dos_date = 33; // 1980-01-01

pub const Entry = struct {
    name: []const u8,
    bytes: []const u8,
};

const EntryHeader = struct {
    offset: u32,
    size: u32,
    crc: u32,
    name_len: u16,
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 512 or !std.unicode.utf8ValidateSlice(name)) return false;
    if (std.mem.indexOfAny(u8, name, "\\:*?\"<>|") != null) return false;
    for (name) |byte| if (byte < 32) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
        const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$" }) |device| {
            if (std.ascii.eqlIgnoreCase(stem, device)) return false;
        }
        if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "com") or std.ascii.startsWithIgnoreCase(stem, "lpt")) and
            std.ascii.isDigit(stem[3])) return false;
    }
    return true;
}

fn checkNames(entries: []const Entry) !void {
    if (entries.len >= std.math.maxInt(u16)) return error.TooManyEntries;
    for (entries, 0..) |entry, index| {
        if (!validName(entry.name)) return error.InvalidEntryPath;
        for (entries[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(entry.name, previous.name)) return error.DuplicateEntry;
        }
    }
}

/// Emit stored ZIP entries with stable timestamps and flat, portable separators.
pub fn create(allocator: std.mem.Allocator, out: *std.Io.Writer, entries: []const Entry) !void {
    try checkNames(entries);
    const headers = try allocator.alloc(EntryHeader, entries.len);
    defer allocator.free(headers);
    var cursor: u64 = 0;
    for (entries, headers) |entry, *info| {
        info.* = .{
            .offset = std.math.cast(u32, cursor) orelse return error.ZipTooLarge,
            .size = std.math.cast(u32, entry.bytes.len) orelse return error.ZipTooLarge,
            .crc = std.hash.Crc32.hash(entry.bytes),
            .name_len = @intCast(entry.name.len),
        };
        const header: zip.LocalFileHeader = .{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = zip_version,
            .flags = @bitCast(utf8_flag),
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = dos_date,
            .crc32 = info.crc,
            .compressed_size = info.size,
            .uncompressed_size = info.size,
            .filename_len = info.name_len,
            .extra_len = 0,
        };
        try out.writeAll(std.mem.asBytes(&header));
        try out.writeAll(entry.name);
        try out.writeAll(entry.bytes);
        cursor += @as(u64, @sizeOf(zip.LocalFileHeader)) + @as(u64, info.name_len) + info.size;
    }
    const central_start = std.math.cast(u32, cursor) orelse return error.ZipTooLarge;
    for (entries, headers) |entry, info| {
        const header: zip.CentralDirectoryFileHeader = .{
            .signature = zip.central_file_header_sig,
            .version_made_by = zip_version,
            .version_needed_to_extract = zip_version,
            .flags = @bitCast(utf8_flag),
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = dos_date,
            .crc32 = info.crc,
            .compressed_size = info.size,
            .uncompressed_size = info.size,
            .filename_len = info.name_len,
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = info.offset,
        };
        try out.writeAll(std.mem.asBytes(&header));
        try out.writeAll(entry.name);
        cursor += @sizeOf(zip.CentralDirectoryFileHeader) + @as(u64, info.name_len);
    }
    const end: zip.EndRecord = .{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(entries.len),
        .record_count_total = @intCast(entries.len),
        .central_directory_size = std.math.cast(u32, cursor - central_start) orelse return error.ZipTooLarge,
        .central_directory_offset = central_start,
        .comment_len = 0,
    };
    try out.writeAll(std.mem.asBytes(&end));
    try out.flush();
}

pub fn makeManifest(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    try checkNames(entries);
    var builder = std.Io.Writer.Allocating.init(allocator);
    errdefer builder.deinit();
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, manifest_name)) return error.ReservedEntryName;
        try builder.writer.print("{s}  {s}\r\n", .{ files.hex(files.digest(entry.bytes)), entry.name });
    }
    return builder.toOwnedSlice();
}

const Check = struct {
    digest: files.Digest,
    seen: bool = false,
};

fn addCheck(
    allocator: std.mem.Allocator,
    expected: *std.StringArrayHashMapUnmanaged(Check),
    name: []const u8,
    digest: files.Digest,
) !void {
    if (!validName(name)) return error.InvalidEntryPath;
    for (expected.keys()) |previous| {
        if (std.ascii.eqlIgnoreCase(previous, name)) return error.DuplicateEntry;
    }
    try expected.put(allocator, name, .{ .digest = digest });
}

fn expectedEntries(allocator: std.mem.Allocator, manifest: []const u8) !std.StringArrayHashMapUnmanaged(Check) {
    if (!std.mem.endsWith(u8, manifest, "\r\n")) return error.InvalidManifest;
    var expected: std.StringArrayHashMapUnmanaged(Check) = .{};
    errdefer expected.deinit(allocator);
    var lines = std.mem.splitSequence(u8, manifest[0 .. manifest.len - 2], "\r\n");
    while (lines.next()) |line| {
        if (line.len < 67 or !std.mem.eql(u8, line[64..66], "  ")) return error.InvalidManifest;
        var digest: files.Digest = undefined;
        _ = try std.fmt.hexToBytes(&digest, line[0..64]);
        try addCheck(allocator, &expected, line[66..], digest);
    }
    try addCheck(allocator, &expected, manifest_name, files.digest(manifest));
    return expected;
}

/// Compare names and SHA-256 against the original manifest using a single open file.
/// The post-build verifier accepts the canonical stored ZIP layout emitted above.
pub fn verify(allocator: std.mem.Allocator, file: std.fs.File, manifest: []const u8) !files.Digest {
    var expected = try expectedEntries(allocator, manifest);
    defer expected.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(&buffer);
    const archive_size = try reader.getSize();
    if (archive_size < @sizeOf(zip.EndRecord)) return error.UnexpectedArchiveData;
    try reader.seekTo(archive_size - @sizeOf(zip.EndRecord));
    const end = try reader.interface.takeStruct(zip.EndRecord, .little);
    if (!std.mem.eql(u8, &end.signature, &zip.end_record_sig) or end.comment_len != 0 or end.need_zip64()) {
        return error.UnexpectedArchiveData;
    }
    var iter = try zip.Iterator.init(&reader);
    if (iter.cd_record_count != expected.count()) return error.WrongEntryCount;
    if (archive_size != iter.cd_zip_offset + iter.cd_size + @sizeOf(zip.EndRecord)) return error.UnexpectedArchiveData;

    var local_end: u64 = 0;
    while (try iter.next()) |entry| {
        if (entry.compression_method != .store or entry.compressed_size != entry.uncompressed_size or
            @as(u16, @bitCast(entry.flags)) != utf8_flag or entry.file_offset != local_end)
        {
            return error.NonCanonicalEntry;
        }
        var name_buf: [512]u8 = undefined;
        if (entry.filename_len > name_buf.len) return error.InvalidEntryPath;
        const name = name_buf[0..entry.filename_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(name);
        const check = expected.getPtr(name) orelse return error.UnexpectedEntry;
        if (check.seen) return error.DuplicateEntry;
        check.seen = true;

        try reader.seekTo(entry.file_offset);
        const header = try reader.interface.takeStruct(zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &header.signature, &zip.local_file_header_sig) or
            header.compression_method != .store or header.extra_len != 0 or
            @as(u16, @bitCast(header.flags)) != utf8_flag or
            header.filename_len != entry.filename_len or
            header.compressed_size != entry.compressed_size or
            header.uncompressed_size != entry.uncompressed_size or header.crc32 != entry.crc32)
        {
            return error.InconsistentLocalHeader;
        }
        var local_name_buf: [512]u8 = undefined;
        try reader.interface.readSliceAll(local_name_buf[0..name.len]);
        if (!std.mem.eql(u8, name, local_name_buf[0..name.len])) return error.InconsistentLocalHeader;
        local_end = entry.file_offset + @sizeOf(zip.LocalFileHeader) + @as(u64, entry.filename_len) + entry.uncompressed_size;
        if (local_end > iter.cd_zip_offset) return error.TruncatedEntry;
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        var crc = std.hash.Crc32.init();
        var data_buffer: [64 * 1024]u8 = undefined;
        var remaining = entry.uncompressed_size;
        while (remaining != 0) {
            const count: usize = @intCast(@min(remaining, data_buffer.len));
            const data = data_buffer[0..count];
            try reader.interface.readSliceAll(data);
            sha.update(data);
            crc.update(data);
            remaining -= count;
        }
        const actual = sha.finalResult();
        if (!std.mem.eql(u8, &actual, &check.digest) or crc.final() != entry.crc32) return error.EntryHashMismatch;
    }
    if (local_end != iter.cd_zip_offset) return error.UnexpectedArchiveData;
    for (expected.values()) |check| {
        if (!check.seen) return error.MissingEntry;
    }
    try file.seekTo(0);
    return files.fileDigest(file);
}

pub fn verifyTree(allocator: std.mem.Allocator, dir: std.fs.Dir, manifest: []const u8) !void {
    var expected = try expectedEntries(allocator, manifest);
    defer expected.deinit(allocator);
    var walk = try dir.walk(allocator);
    defer walk.deinit();
    var name_buf: [512]u8 = undefined;
    while (try walk.next()) |item| {
        if (item.kind == .directory) continue;
        if (item.kind != .file or item.path.len > name_buf.len) return error.UnexpectedEntry;
        const name = name_buf[0..item.path.len];
        @memcpy(name, item.path);
        std.mem.replaceScalar(u8, name, '\\', '/');
        const result = expected.getPtr(name) orelse return error.UnexpectedEntry;
        if (result.seen) return error.DuplicateEntry;
        const digest = try files.readDigest(item.dir, item.basename);
        if (!std.mem.eql(u8, &digest, &result.digest)) return error.EntryHashMismatch;
        result.seen = true;
    }
    for (expected.values()) |expected_entry| {
        if (!expected_entry.seen) return error.MissingEntry;
    }
}

test "verified packed payload detects corruption on the same handle" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const payload = [_]Entry{.{ .name = "ChatPalette.exe", .bytes = "known test executable" }};
    const manifest = try makeManifest(alloc, &payload);
    defer alloc.free(manifest);
    const file = try temp.dir.createFile("candidate.zip", .{ .read = true });
    defer file.close();
    var buffer: [2048]u8 = undefined;
    var writer = file.writer(&buffer);
    try create(alloc, &writer.interface, &(payload ++ .{Entry{ .name = manifest_name, .bytes = manifest }}));
    _ = try verify(alloc, file, manifest);
    try file.pwriteAll("X", @sizeOf(zip.LocalFileHeader) + payload[0].name.len);
    try std.testing.expectError(error.EntryHashMismatch, verify(alloc, file, manifest));
}

test "ZIP creation rejects duplicate and escaping paths" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.DuplicateEntry, makeManifest(alloc, &.{
        .{ .name = "docs/LICENSE", .bytes = "one" },
        .{ .name = "docs/license", .bytes = "two" },
    }));
    try std.testing.expectError(error.InvalidEntryPath, makeManifest(alloc, &.{
        .{ .name = "../private", .bytes = "" },
    }));
}

test "verification rejects every legacy package mutation against the pinned manifest" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const readme: Entry = .{ .name = "README.md", .bytes = "known release instructions" };
    const license: Entry = .{ .name = "LICENSE", .bytes = "known license" };
    const substituted: Entry = .{ .name = readme.name, .bytes = "changed instructions" };
    const extra: Entry = .{ .name = "OTHER.txt", .bytes = "extra content" };
    const manifest = try makeManifest(alloc, &.{ readme, license });
    defer alloc.free(manifest);
    const forged_manifest = try makeManifest(alloc, &.{ substituted, license });
    defer alloc.free(forged_manifest);
    const original: Entry = .{ .name = manifest_name, .bytes = manifest };
    const cases = [_]struct { entries: []const Entry, failure: anyerror }{
        .{ .entries = &.{ substituted, license, original }, .failure = error.EntryHashMismatch },
        .{ .entries = &.{ license, original }, .failure = error.WrongEntryCount },
        .{ .entries = &.{ readme, license, extra, original }, .failure = error.WrongEntryCount },
        .{ .entries = &.{ readme, license, .{ .name = manifest_name, .bytes = "incorrect manifest" } }, .failure = error.EntryHashMismatch },
        .{ .entries = &.{ substituted, license, .{ .name = manifest_name, .bytes = forged_manifest } }, .failure = error.EntryHashMismatch },
        .{ .entries = &.{ .{ .name = "readme.md", .bytes = readme.bytes }, license, original }, .failure = error.UnexpectedEntry },
    };
    for (cases) |item| {
        const archive = try temp.dir.createFile("variant.zip", .{ .read = true });
        defer archive.close();
        var buffer: [2048]u8 = undefined;
        var writer = archive.writer(&buffer);
        try create(alloc, &writer.interface, item.entries);
        try testing.expectError(item.failure, verify(alloc, archive, manifest));
    }

    const duplicate = try temp.dir.createFile("duplicate.zip", .{ .read = true, .exclusive = true });
    defer duplicate.close();
    var buffer: [2048]u8 = undefined;
    var writer = duplicate.writer(&buffer);
    try create(alloc, &writer.interface, &.{ readme, extra, original });
    try duplicate.seekTo(0);
    const contents = try duplicate.readToEndAlloc(alloc, buffer.len);
    defer alloc.free(contents);
    const local = std.mem.indexOf(u8, contents, extra.name) orelse return error.MissingFixtureEntry;
    const central = std.mem.indexOfPos(u8, contents, local + extra.name.len, extra.name) orelse return error.MissingFixtureEntry;
    try testing.expectEqual(readme.name.len, extra.name.len);
    try duplicate.pwriteAll(readme.name, local);
    try duplicate.pwriteAll(readme.name, central);
    try testing.expectError(error.DuplicateEntry, verify(alloc, duplicate, manifest));
}
