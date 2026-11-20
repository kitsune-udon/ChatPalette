const std = @import("std");
const files = @import("files.zig");
const zip = @import("zip.zig");

const max_file_bytes = 256 * 1024 * 1024;
const manifest_limit = 4 * 1024 * 1024;
const app_name = "ChatPalette.exe";
pub const source_roots = [_][]const u8{ "src", "tools", "tests/integration" };
pub const packaged_files = [_][]const u8{
    "CHANGELOG.md",
    "LICENSE",
    "README.md",
    "VERSION",
    "docs/user/guide.md",
    "docs/user/maintenance.md",
    "docs/user/reactions.md",
    "docs/user/reference.md",
};

fn validIdentifiers(list: []const u8, forbid_numeric_leading_zero: bool) bool {
    var parts = std.mem.splitScalar(u8, list, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        var numeric = true;
        for (part) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
            numeric = numeric and std.ascii.isDigit(ch);
        }
        if (forbid_numeric_leading_zero and numeric and part.len > 1 and part[0] == '0') return false;
    }
    return true;
}

pub fn validVersion(version: []const u8) bool {
    // Three ASCII numeric fields, optionally followed by SemVer identifiers.
    const plus = std.mem.indexOfScalar(u8, version, '+') orelse version.len;
    if (plus < version.len and !validIdentifiers(version[plus + 1 ..], false)) return false;
    const dash = std.mem.indexOfScalar(u8, version[0..plus], '-') orelse plus;
    if (dash < plus and !validIdentifiers(version[dash + 1 .. plus], true)) return false;
    var parts = std.mem.splitScalar(u8, version[0..dash], '.');
    for (0..3) |_| {
        const part = parts.next() orelse return false;
        if (part.len == 0 or (part.len > 1 and part[0] == '0')) return false;
        for (part) |ch| if (!std.ascii.isDigit(ch)) return false;
    }
    return parts.next() == null and version.len <= 120;
}

fn sourcePaths(alloc: std.mem.Allocator, project: std.fs.Dir) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(alloc, "build.zig");
    if (project.access("build.zig.zon", .{})) |_| {
        try paths.append(alloc, "build.zig.zon");
    } else |err| if (err != error.FileNotFound) {
        return err;
    }
    for (packaged_files) |name| try paths.append(alloc, name);
    for (source_roots) |root| {
        var dir = try project.openDir(root, .{ .iterate = true, .no_follow = true });
        defer dir.close();
        var walk = try dir.walk(alloc);
        defer walk.deinit();
        while (try walk.next()) |entry| {
            if (entry.kind != .file or !std.mem.eql(u8, std.fs.path.extension(entry.basename), ".zig")) continue;
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, entry.path });
            std.mem.replaceScalar(u8, path, '\\', '/');
            try paths.append(alloc, path);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return paths.toOwnedSlice(alloc);
}

fn sourceManifest(alloc: std.mem.Allocator, project: std.fs.Dir, packaged: []const zip.Entry) ![]u8 {
    const paths = try sourcePaths(alloc, project);
    var result = std.Io.Writer.Allocating.init(alloc);
    for (paths) |path| {
        const sha = frozen: {
            for (packaged) |item| {
                if (std.mem.eql(u8, path, item.name)) break :frozen files.digest(item.bytes);
            }
            break :frozen try files.readDigest(project, path);
        };
        try result.writer.print("{s}  {s}\r\n", .{ files.hex(sha), path });
    }
    return result.toOwnedSlice();
}

/// All input paths and the returned manifest belong to the caller's scratch allocator.
pub fn captureSources(alloc: std.mem.Allocator, project: std.fs.Dir, snapshot: std.fs.Dir) ![]u8 {
    const paths = try sourcePaths(alloc, project);
    for (paths) |path| {
        if (std.fs.path.dirname(path)) |parent| try snapshot.makePath(parent);
        const bytes = try project.readFileAlloc(alloc, path, max_file_bytes);
        defer alloc.free(bytes);
        try files.writeNew(snapshot, path, bytes);
    }
    return sourceManifest(alloc, snapshot, &.{});
}

pub fn requireSources(alloc: std.mem.Allocator, project: std.fs.Dir, expected: []const u8) !void {
    const current = try sourceManifest(alloc, project, &.{});
    if (!std.mem.eql(u8, expected, current)) return error.CandidateSourcesChanged;
}

pub const VerifiedEvidence = struct {
    source_manifest: []const u8,
    original_source: std.fs.Dir,
    files: []const zip.Entry,
    clean_output: []const u8,
};

pub fn makeCandidate(allocator: std.mem.Allocator, app: []const u8, expected_sha: []const u8, root: []const u8, output: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var expected: files.Digest = undefined;
    if (expected_sha.len != 64) return error.InvalidTestedExecutableDigest;
    _ = std.fmt.hexToBytes(&expected, expected_sha) catch return error.InvalidTestedExecutableDigest;
    return package(alloc, app, expected, root, output, null, files.writeNew);
}

pub fn makeVerifiedCandidate(
    allocator: std.mem.Allocator,
    app: []const u8,
    expected_sha: files.Digest,
    root: []const u8,
    output: []const u8,
    verified: VerifiedEvidence,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return package(arena.allocator(), app, expected_sha, root, output, verified, files.writeNew);
}

fn package(
    alloc: std.mem.Allocator,
    app: []const u8,
    expected: files.Digest,
    root: []const u8,
    output: []const u8,
    verified: ?VerifiedEvidence,
    comptime writeRecord: fn (std.fs.Dir, []const u8, []const u8) anyerror!void,
) !void {
    var project = try std.fs.cwd().openDir(root, .{});
    defer project.close();
    const executable = try std.fs.cwd().readFileAlloc(alloc, app, max_file_bytes);
    const app_sha = files.digest(executable);
    if (!std.mem.eql(u8, &expected, &app_sha)) return error.ExecutableChangedSinceTesting;

    var entries: [packaged_files.len + 2]zip.Entry = undefined;
    entries[0] = .{ .name = app_name, .bytes = executable };
    var version: []const u8 = "";
    for (packaged_files, entries[1 .. 1 + packaged_files.len]) |name, *entry| {
        const bytes = try project.readFileAlloc(alloc, name, max_file_bytes);
        entry.* = .{ .name = name, .bytes = bytes };
        if (std.mem.eql(u8, name, "VERSION")) version = std.mem.trim(u8, bytes, " \t\r\n");
    }
    if (!validVersion(version)) return error.InvalidReleaseVersion;
    const bundled = entries[0 .. entries.len - 1];
    const manifest = try zip.makeManifest(alloc, bundled);
    entries[entries.len - 1] = .{ .name = zip.manifest_name, .bytes = manifest };
    const sources = try sourceManifest(alloc, project, bundled[1..]);
    if (verified) |evidence| {
        if (!std.mem.eql(u8, sources, evidence.source_manifest)) return error.CandidateSourcesChanged;
    }

    const out_absolute = try std.fs.path.resolve(alloc, &.{ try std.process.getCwdAlloc(alloc), output });
    const parent = std.fs.path.dirname(out_absolute) orelse return error.InvalidOutputDirectory;
    if (std.fs.cwd().access(out_absolute, .{})) |_| {
        return error.OutputExists;
    } else |err| if (err != error.FileNotFound) {
        return err;
    }
    try std.fs.cwd().makePath(parent);
    const stage_path = try files.newDirectory(alloc, parent, "candidate-");
    errdefer std.debug.print("候補の作業ファイルを保持しました {s}\n", .{stage_path});

    const archive_name = try std.fmt.allocPrint(alloc, "ChatPalette-{s}.zip", .{version});
    const report_name = try std.fmt.allocPrint(alloc, "ChatPalette-{s}.{s}.json", .{
        version, if (verified != null) "validation" else "rehearsal",
    });
    {
        var stage = try std.fs.cwd().openDir(stage_path, .{});
        defer stage.close();
        {
            const file = try stage.createFile(archive_name, .{ .exclusive = true });
            defer file.close();
            var buffer: [64 * 1024]u8 = undefined;
            var writer = file.writer(&buffer);
            try zip.create(alloc, &writer.interface, &entries);
            try file.sync();
        }
        const archive_path = try std.fs.path.join(alloc, &.{ stage_path, archive_name });
        const archive = try files.openImmutable(alloc, archive_path);
        defer archive.close(); // Windows requires the child to be closed before renaming the stage.
        const archive_sha = try zip.verify(alloc, archive, manifest);
        try files.writeNew(stage, zip.manifest_name, manifest);
        try files.writeNew(stage, "SOURCE-SHA256SUMS", sources);
        const evidence_digest: ?files.HexDigest = checked: {
            const evidence = verified orelse break :checked null;
            try extractVerified(alloc, archive, manifest, evidence.clean_output);
            try stage.makeDir("evidence");
            var destination = try stage.openDir("evidence", .{ .no_follow = true });
            defer destination.close();
            const checksums = try zip.makeManifest(alloc, evidence.files);
            for (evidence.files) |proof| try files.writeNew(destination, proof.name, proof.bytes);
            try files.writeNew(destination, zip.manifest_name, checksums);
            break :checked files.hex(files.digest(checksums));
        };
        const report = try std.json.Stringify.valueAlloc(alloc, .{
            .Version = version,
            .Archive = archive_name,
            .ArchiveSHA256 = files.hex(archive_sha),
            .ExecutableSHA256 = files.hex(app_sha),
            .ArchiveManifestSHA256 = files.hex(files.digest(manifest)),
            .SourceManifestSHA256 = files.hex(files.digest(sources)),
            .Verification = if (verified != null) "FrozenSourceAutomatedChecks" else "Rehearsal",
            .TestEvidenceManifestSHA256 = evidence_digest,
        }, .{ .whitespace = .indent_2 });
        if (verified) |evidence| {
            try requireSources(alloc, project, evidence.source_manifest);
            try requireSources(alloc, evidence.original_source, evidence.source_manifest);
        }
        try writeRecord(stage, report_name, report);
    }
    try files.publish(alloc, stage_path, out_absolute);
}

pub fn verifyCandidate(allocator: std.mem.Allocator, archive: []const u8, manifest_path: []const u8) !files.Digest {
    const manifest = try std.fs.cwd().readFileAlloc(allocator, manifest_path, manifest_limit);
    defer allocator.free(manifest);
    const archive_path = try std.fs.cwd().realpathAlloc(allocator, archive);
    defer allocator.free(archive_path);
    const file = try files.openImmutable(allocator, archive_path);
    defer file.close();
    return zip.verify(allocator, file, manifest);
}

/// Verify against the detached manifest before opening any archive path for extraction.
pub fn extractCandidate(allocator: std.mem.Allocator, archive: []const u8, manifest_path: []const u8, output: []const u8) !files.Digest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const manifest = try std.fs.cwd().readFileAlloc(alloc, manifest_path, manifest_limit);
    const archive_path = try std.fs.cwd().realpathAlloc(alloc, archive);
    const file = try files.openImmutable(alloc, archive_path);
    defer file.close();
    const archive_hash = try zip.verify(alloc, file, manifest);
    try extractVerified(alloc, file, manifest, output);
    return archive_hash;
}

fn extractVerified(alloc: std.mem.Allocator, file: std.fs.File, manifest: []const u8, output: []const u8) !void {
    const out_absolute = try std.fs.path.resolve(alloc, &.{ try std.process.getCwdAlloc(alloc), output });
    const parent = std.fs.path.dirname(out_absolute) orelse return error.InvalidOutputDirectory;
    try std.fs.cwd().makePath(parent);
    const stage_path = try files.newDirectory(alloc, parent, "extracted-");
    errdefer std.debug.print("展開検証の作業ファイルを保持しました {s}\n", .{stage_path});
    {
        var directory = try std.fs.cwd().openDir(stage_path, .{ .iterate = true, .no_follow = true });
        defer directory.close();
        var read_buffer: [8192]u8 = undefined;
        var reader = file.reader(&read_buffer);
        try std.zip.extract(directory, &reader, .{});
        try zip.verifyTree(alloc, directory, manifest);
    }
    try files.publish(alloc, stage_path, out_absolute);
}

test "archive validation holds the same immutable Windows handle for verification and hashing" {
    const alloc = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const entries = [_]zip.Entry{.{ .name = "README.md", .bytes = "verified release instructions" }};
    const manifest = try zip.makeManifest(alloc, &entries);
    defer alloc.free(manifest);
    {
        const file = try temporary.dir.createFile("owned.zip", .{ .exclusive = true });
        defer file.close();
        var buffer: [2048]u8 = undefined;
        var writer = file.writer(&buffer);
        try zip.create(alloc, &writer.interface, &(entries ++ .{zip.Entry{ .name = zip.manifest_name, .bytes = manifest }}));
    }
    const original = try files.readDigest(temporary.dir, "owned.zip");
    const archive = try temporary.dir.realpathAlloc(alloc, "owned.zip");
    defer alloc.free(archive);
    const replacement = try std.mem.concat(alloc, u8, &.{ archive, ".original" });
    defer alloc.free(replacement);
    {
        const file = try files.openImmutable(alloc, archive);
        defer file.close();
        if (temporary.dir.createFile("owned.zip", .{ .truncate = true })) |writer| {
            writer.close();
            return error.ImmutableArchiveWasWritable;
        } else |_| {}
        if (files.publish(alloc, archive, replacement)) |_| {
            return error.ImmutableArchiveWasMovable;
        } else |_| {}
        try std.testing.expectEqual(original, try zip.verify(alloc, file, manifest));
    }
    try files.publish(alloc, archive, replacement);
    const writer = try temporary.dir.openFile("owned.zip.original", .{ .mode = .write_only });
    writer.close();
    try std.testing.expectEqual(original, try files.readDigest(temporary.dir, "owned.zip.original"));
}

test "SemVer only permits portable archive names" {
    for ([_][]const u8{ "0.8.0", "1.0.0-rc.1", "1.0.0+007", "1.0.0-rc.0+20261118" }) |value| {
        try std.testing.expect(validVersion(value));
    }
    for ([_][]const u8{ "1.02.0", "1.0", "1.0.0-01", "1.0.0+", "1.0.0-rc..1", "1.0.0+../data" }) |value| {
        try std.testing.expect(!validVersion(value));
    }
}

test "candidate packaging requires tested bytes and excludes the user's data" {
    const alloc = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const absolute = try temporary.dir.realpathAlloc(alloc, ".");
    defer alloc.free(absolute);
    try temporary.dir.makePath("docs/user");
    try temporary.dir.makeDir("src");
    try temporary.dir.makeDir("tools");
    try temporary.dir.makePath("tests/integration");
    try temporary.dir.makePath("tests/.tmp");
    try temporary.dir.makeDir("data");
    try files.writeNew(temporary.dir, "data/settings.db", "private");
    try files.writeNew(temporary.dir, "src/main.zig", "pub fn main() void {}");
    try files.writeNew(temporary.dir, "tools/main.zig", "pub fn main() void {}");
    try files.writeNew(temporary.dir, "tests/integration/startup_test.zig", "pub fn main() void {}");
    try files.writeNew(temporary.dir, "tests/.tmp/old.zig", "old test output");
    try files.writeNew(temporary.dir, "tests/unregistered.zig", "outside integration sources");
    try files.writeNew(temporary.dir, "build.zig", "");
    try files.writeNew(temporary.dir, "Fixture.exe", "fixture bytes");
    for (packaged_files) |name| {
        try files.writeNew(temporary.dir, name, if (std.mem.eql(u8, name, "VERSION")) "1.0.0-rc.1\n" else "provided");
    }
    const app = try std.fs.path.join(alloc, &.{ absolute, "Fixture.exe" });
    defer alloc.free(app);
    const candidate = try std.fs.path.join(alloc, &.{ absolute, "candidate" });
    defer alloc.free(candidate);
    const bad = files.hex(files.digest("different executable"));
    try std.testing.expectError(error.ExecutableChangedSinceTesting, makeCandidate(alloc, app, &bad, absolute, candidate));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("candidate", .{}));
    const trusted = files.hex(files.digest("fixture bytes"));
    try makeCandidate(alloc, app, &trusted, absolute, candidate);
    try std.testing.expectError(error.OutputExists, makeCandidate(alloc, app, &trusted, absolute, candidate));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("candidate/ChatPalette-1.0.0-rc.1.validation.json", .{}));
    const rehearsal = try temporary.dir.readFileAlloc(alloc, "candidate/ChatPalette-1.0.0-rc.1.rehearsal.json", 4096);
    defer alloc.free(rehearsal);
    try std.testing.expect(std.mem.indexOf(u8, rehearsal, "\"Verification\": \"Rehearsal\"") != null);

    const manifest = try std.fs.path.join(alloc, &.{ candidate, zip.manifest_name });
    defer alloc.free(manifest);
    const archive = try std.fs.path.join(alloc, &.{ candidate, "ChatPalette-1.0.0-rc.1.zip" });
    defer alloc.free(archive);
    const clean = try std.fs.path.join(alloc, &.{ absolute, "clean" });
    defer alloc.free(clean);
    const verified = try verifyCandidate(alloc, archive, manifest);
    const extracted = try extractCandidate(alloc, archive, manifest, clean);
    try std.testing.expectEqual(verified, extracted);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("clean/data/settings.db", .{}));
    const copied = try temporary.dir.readFileAlloc(alloc, "clean/ChatPalette.exe", 100);
    defer alloc.free(copied);
    try std.testing.expectEqualStrings("fixture bytes", copied);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    try temporary.dir.makeDir("snapshot");
    var snapshot = try temporary.dir.openDir("snapshot", .{});
    defer snapshot.close();
    const source_manifest = try captureSources(scratch, temporary.dir, snapshot);
    try requireSources(scratch, temporary.dir, source_manifest);
    try std.testing.expectError(error.FileNotFound, snapshot.access("data/settings.db", .{}));
    try snapshot.access("src/main.zig", .{});
    try snapshot.access("tools/main.zig", .{});
    try snapshot.access("tests/integration/startup_test.zig", .{});
    try std.testing.expectError(error.FileNotFound, snapshot.access("tests/.tmp/old.zig", .{}));
    try std.testing.expectError(error.FileNotFound, snapshot.access("tests/unregistered.zig", .{}));
    const proved = try std.fs.path.join(scratch, &.{ absolute, "publication", "proved" });
    const snapshot_path = try std.fs.path.join(scratch, &.{ absolute, "snapshot" });
    const proof = VerifiedEvidence{
        .source_manifest = source_manifest,
        .original_source = temporary.dir,
        .files = &.{.{ .name = "test-list.json", .bytes = "{}" }},
        .clean_output = try std.fs.path.join(scratch, &.{ absolute, "proved-clean" }),
    };
    const collision = struct {
        const existing_record = "created by another writer";

        fn write(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
            try files.writeNew(dir, name, existing_record);
            try files.writeNew(dir, name, bytes);
        }
    };
    const executable_sha = files.digest("fixture bytes");
    try std.testing.expectError(error.PathAlreadyExists, package(scratch, app, executable_sha, snapshot_path, proved, proof, collision.write));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("publication/proved", .{}));
    try std.testing.expectEqual(executable_sha, try files.readDigest(temporary.dir, "proved-clean/ChatPalette.exe"));
    const archive_name = "ChatPalette-1.0.0-rc.1.zip";
    const record_name = "ChatPalette-1.0.0-rc.1.validation.json";
    const staged_path = found: {
        var publication = try temporary.dir.openDir("publication", .{ .iterate = true });
        defer publication.close();
        var entries = publication.iterate();
        const stage = (try entries.next()) orelse return error.MissingFailedStage;
        try std.testing.expect(stage.kind == .directory and std.mem.startsWith(u8, stage.name, "candidate-"));
        const path = try publication.realpathAlloc(scratch, stage.name);
        try std.testing.expect((try entries.next()) == null);
        break :found path;
    };
    var failed_stage = try std.fs.cwd().openDir(staged_path, .{});
    defer failed_stage.close();
    const existing_record = try failed_stage.readFileAlloc(scratch, record_name, 1024);
    try std.testing.expectEqualStrings(collision.existing_record, existing_record);
    const staged_sha = try files.readDigest(failed_stage, archive_name);
    const staged_evidence_sha = try files.readDigest(failed_stage, "evidence/SHA256SUMS");

    var retry = proof;
    retry.clean_output = try std.fs.path.join(scratch, &.{ absolute, "retry-clean" });
    try makeVerifiedCandidate(alloc, app, executable_sha, snapshot_path, proved, retry);
    var published = try std.fs.cwd().openDir(proved, .{});
    defer published.close();
    const record_bytes = try published.readFileAlloc(scratch, record_name, 4096);
    const report = try std.json.parseFromSliceLeaky(struct {
        Verification: []const u8,
        ArchiveSHA256: []const u8,
        ExecutableSHA256: []const u8,
        ArchiveManifestSHA256: []const u8,
        SourceManifestSHA256: []const u8,
        TestEvidenceManifestSHA256: []const u8,
    }, scratch, record_bytes, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("FrozenSourceAutomatedChecks", report.Verification);
    try std.testing.expectEqual(staged_sha, try files.readDigest(published, archive_name));
    try std.testing.expectEqual(verified, staged_sha);
    try std.testing.expectEqualStrings(&files.hex(staged_sha), report.ArchiveSHA256);
    try std.testing.expectEqual(executable_sha, try files.readDigest(temporary.dir, "retry-clean/ChatPalette.exe"));
    try std.testing.expectEqualStrings(&files.hex(executable_sha), report.ExecutableSHA256);
    try std.testing.expectEqualStrings(&files.hex(try files.readDigest(published, zip.manifest_name)), report.ArchiveManifestSHA256);
    try std.testing.expectEqualStrings(&files.hex(try files.readDigest(published, "SOURCE-SHA256SUMS")), report.SourceManifestSHA256);
    try std.testing.expectEqual(staged_evidence_sha, try files.readDigest(published, "evidence/SHA256SUMS"));
    try std.testing.expectEqualStrings(&files.hex(staged_evidence_sha), report.TestEvidenceManifestSHA256);
    {
        const modified = try snapshot.createFile("build.zig", .{ .truncate = true });
        defer modified.close();
        try modified.writeAll("// changed after validation\n");
    }
    try std.testing.expectError(error.CandidateSourcesChanged, requireSources(scratch, snapshot, source_manifest));
    {
        const restored = try snapshot.createFile("build.zig", .{ .truncate = true });
        restored.close();
    }
    try requireSources(scratch, snapshot, source_manifest);
    try snapshot.deleteFile("src/main.zig");
    try std.testing.expectError(error.CandidateSourcesChanged, requireSources(scratch, snapshot, source_manifest));
    try files.writeNew(snapshot, "src/main.zig", "pub fn main() void {}");
    try files.writeNew(snapshot, "tests/integration/late.zig", "pub const late = true;\n");
    try std.testing.expectError(error.CandidateSourcesChanged, requireSources(scratch, snapshot, source_manifest));
    const rejected = try std.fs.path.join(scratch, &.{ absolute, "rejected" });
    try std.testing.expectError(error.CandidateSourcesChanged, makeVerifiedCandidate(alloc, app, files.digest("fixture bytes"), snapshot_path, rejected, proof));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("rejected", .{}));
}
