const std = @import("std");
const release = @import("release.zig");

fn utf8(bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.startsWith(u8, bytes, "\xef\xbb\xbf") or
        std.mem.indexOfScalar(u8, bytes, '\r') != null) return error.ExpectedUtf8LfWithoutBom;
}

fn knownLink(path: []const u8) bool {
    if (std.mem.eql(u8, path, "ChatPalette.exe")) return true;
    for (release.packaged_files) |item| {
        if (std.mem.eql(u8, path, item)) return true;
    }
    return false;
}

fn scheme(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "http://");
}

fn nextProseLine(lines: *std.mem.SplitIterator(u8, .scalar), fenced: *bool) ?[]const u8 {
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "\x60\x60\x60")) {
            fenced.* = !fenced.*;
        } else if (!fenced.*) return line;
    }
    return null;
}

fn hasHeading(markdown: []const u8, fragment: []const u8) bool {
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var fenced = false;
    while (nextProseLine(&lines, &fenced)) |line| {
        const text = std.mem.trimStart(u8, line, "#");
        const markers = line.len - text.len;
        if (markers == 0 or markers > 6 or text.len == 0 or !std.ascii.isWhitespace(text[0])) continue;
        var index: usize = 0;
        for (std.mem.trim(u8, text, " \t")) |byte| {
            const slug = if (std.ascii.isWhitespace(byte)) '-' else std.ascii.toLower(byte);
            if (!std.ascii.isAlphanumeric(slug) and std.ascii.isAscii(slug) and slug != '-' and slug != '_') continue;
            if (index == fragment.len or slug != fragment[index]) break;
            index += 1;
        } else if (index == fragment.len) return true;
    }
    return false;
}

fn links(alloc: std.mem.Allocator, project: std.fs.Dir, path: []const u8, markdown: []const u8) !void {
    const directory = std.fs.path.dirname(path) orelse ".";
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var fenced = false;
    while (nextProseLine(&lines, &fenced)) |line| {
        var rest = line;
        while (std.mem.indexOf(u8, rest, "](")) |start| {
            const target_and_tail = rest[start + 2 ..];
            const end = std.mem.indexOfScalar(u8, target_and_tail, ')') orelse break;
            const target = std.mem.trim(u8, target_and_tail[0..end], "<>");
            rest = target_and_tail[end + 1 ..];
            if (target.len == 0 or scheme(target)) continue;
            var parts = std.mem.splitScalar(u8, target, '#');
            const relative = try alloc.dupe(u8, parts.first());
            defer alloc.free(relative);
            const normalized = if (relative.len == 0)
                try alloc.dupe(u8, path)
            else
                try std.fs.path.resolve(alloc, &.{ directory, std.Uri.percentDecodeInPlace(relative) });
            defer alloc.free(normalized);
            std.mem.replaceScalar(u8, normalized, '\\', '/');
            if (!knownLink(normalized)) {
                std.debug.print("{s} は同梱されない文書を参照しています {s}\n", .{ path, target });
                return error.DocumentLinkOutsideCandidate;
            }
            const anchor = parts.rest();
            if (anchor.len == 0 or !std.mem.endsWith(u8, normalized, ".md")) continue;
            const fragment = try alloc.dupe(u8, anchor);
            defer alloc.free(fragment);
            const same_document = std.mem.eql(u8, path, normalized);
            const headings = if (same_document) markdown else try project.readFileAlloc(alloc, normalized, 4 * 1024 * 1024);
            defer if (!same_document) alloc.free(headings);
            if (!hasHeading(headings, std.Uri.percentDecodeInPlace(fragment))) {
                std.debug.print("{s} の参照先に見出しがありません {s}\n", .{ path, target });
                return error.DocumentHeadingMissing;
            }
        }
    }
}

fn legacyExtension(extension: []const u8) bool {
    for ([_][]const u8{ ".ahk", ".ps1", ".psm1", ".cmd", ".bat", ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp" }) |legacy| {
        if (std.ascii.eqlIgnoreCase(extension, legacy)) return true;
    }
    return false;
}

fn legacyInterpreter(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    const extension = std.fs.path.extension(name);
    if (extension.len != 0 and !std.ascii.eqlIgnoreCase(extension, ".exe")) return false;
    for ([_][]const u8{ "powershell", "pwsh", "autohotkey", "autohotkey32", "autohotkey64", "autohotkeyux" }) |command| {
        if (std.ascii.eqlIgnoreCase(std.fs.path.stem(name), command)) return true;
    }
    return false;
}

fn legacyBuildInput(path: []const u8) bool {
    if (legacyExtension(std.fs.path.extension(path)) or legacyInterpreter(path)) return true;
    var parts = std.mem.splitScalar(u8, path, '/');
    const top = parts.first();
    if (std.ascii.eqlIgnoreCase(top, "tests")) {
        return !std.ascii.eqlIgnoreCase(parts.next() orelse "", "integration");
    }
    for ([_][]const u8{ "legacy", "native", "scripts", "prototype" }) |directory| {
        if (std.ascii.eqlIgnoreCase(top, directory)) return true;
    }
    return false;
}

fn snapshottedInput(path: []const u8) bool {
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return true;
    if (std.mem.endsWith(u8, path, ".zig")) {
        inline for (release.source_roots) |root| {
            if (std.mem.startsWith(u8, path, root ++ "/")) return true;
        }
    }
    for (release.packaged_files) |name| if (std.mem.eql(u8, path, name)) return true;
    return false;
}

fn checkInput(alloc: std.mem.Allocator, directory: []const u8, input: []const u8, build_graph: bool, comptime kind: enum { import, embed, graph }) !void {
    const path = try std.fs.path.resolve(alloc, &.{ directory, input });
    defer alloc.free(path);
    std.mem.replaceScalar(u8, path, '\\', '/');
    if (build_graph and legacyBuildInput(path)) return error.LegacyBuildDependency;
    switch (kind) {
        .graph => if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".zig")) return,
        .import => if (std.mem.indexOfAny(u8, input, "/\\") == null and std.fs.path.extension(input).len == 0) return,
        .embed => {},
    }
    if (!snapshottedInput(path)) return error.SourceInputOutsideSnapshot;
}

fn reportAt(tree: std.zig.Ast, path: []const u8, token: std.zig.Ast.TokenIndex, message: []const u8) void {
    const location = tree.tokenLocation(0, token);
    std.debug.print("{s}:{d}:{d} {s} {s}\n", .{ path, location.line + 1, location.column + 1, message, tree.tokenSlice(token) });
}

const Ast = std.zig.Ast;

fn isLiteralString(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .string_literal => true,
        .grouped_expression => isLiteralString(tree, tree.nodeData(node).node_and_token[0]),
        .array_cat => both: {
            const operands = tree.nodeData(node).node_and_node;
            break :both isLiteralString(tree, operands[0]) and isLiteralString(tree, operands[1]);
        },
        else => false,
    };
}

fn literalString(alloc: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) !?[]u8 {
    return switch (tree.nodeTag(node)) {
        .string_literal => try std.zig.string_literal.parseAlloc(alloc, tree.tokenSlice(tree.nodeMainToken(node))),
        .grouped_expression => literalString(alloc, tree, tree.nodeData(node).node_and_token[0]),
        .array_cat => combined: {
            const operands = tree.nodeData(node).node_and_node;
            const left = (try literalString(alloc, tree, operands[0])) orelse break :combined null;
            defer alloc.free(left);
            const right = (try literalString(alloc, tree, operands[1])) orelse break :combined null;
            defer alloc.free(right);
            break :combined try std.mem.concat(alloc, u8, &.{ left, right });
        },
        else => null,
    };
}

fn firstArgument(tree: Ast, initial: Ast.Node.Index) ?Ast.Node.Index {
    const argv = if (tree.nodeTag(initial) == .address_of) tree.nodeData(initial).node else initial;
    var buffer: [2]Ast.Node.Index = undefined;
    const list = tree.fullArrayInit(&buffer, argv) orelse return null;
    return if (list.ast.elements.len != 0) list.ast.elements[0] else null;
}

// Detect a PATH lookup when a standard child launch has a literal argument list.
// Ordinary string values such as the clean-install module audit remain allowed.
fn literalChildImage(tree: Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return null;
    if (call.ast.params.len == 0 or tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const method = tree.nodeData(call.ast.fn_expr).node_and_token;
    const child = switch (tree.nodeTag(method[0])) {
        .identifier => tree.nodeMainToken(method[0]),
        .field_access => tree.nodeData(method[0]).node_and_token[1],
        else => return null,
    };
    if (!std.mem.eql(u8, tree.tokenSlice(child), "Child")) return null;
    const operation = tree.tokenSlice(method[1]);
    if (std.mem.eql(u8, operation, "init")) return firstArgument(tree, call.ast.params[0]);
    if (!std.mem.eql(u8, operation, "run")) return null;
    var field_buffer: [2]Ast.Node.Index = undefined;
    const options = tree.fullStructInit(&field_buffer, call.ast.params[0]) orelse return null;
    for (options.ast.fields) |field| {
        const value = tree.firstToken(field);
        if (tree.tokenTag(value - 1) == .equal and std.mem.eql(u8, tree.tokenSlice(value - 2), "argv"))
            return firstArgument(tree, field);
    }
    return null;
}

fn checkZig(alloc: std.mem.Allocator, path: []const u8, content: [:0]const u8, mode: std.zig.Ast.Mode) !void {
    try utf8(content);
    var tree = try std.zig.Ast.parse(alloc, content, mode);
    defer tree.deinit(alloc);
    if (tree.errors.len != 0) {
        var message = std.Io.Writer.Allocating.init(alloc);
        defer message.deinit();
        try tree.renderError(tree.errors[0], &message.writer);
        reportAt(tree, path, tree.errors[0].token, message.written());
        return error.InvalidZigSource;
    }
    const directory = std.fs.path.dirname(path) orelse ".";
    const build_graph = std.fs.path.dirname(path) == null;
    const explicit_legacy_test = std.mem.eql(u8, path, "tools/compare.zig") or
        std.mem.eql(u8, path, "tests/integration/rollback_test.zig");
    // Check a complete static path once. A path fragment need not be a valid path.
    var fragments = try std.DynamicBitSetUnmanaged.initEmpty(alloc, tree.nodes.len);
    defer fragments.deinit(alloc);
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        switch (tree.nodeTag(node)) {
            .array_cat => {
                const pair = tree.nodeData(node).node_and_node;
                if (isLiteralString(tree, pair[0]) and isLiteralString(tree, pair[1])) {
                    fragments.set(@intFromEnum(pair[0]));
                    fragments.set(@intFromEnum(pair[1]));
                }
            },
            .grouped_expression => if (isLiteralString(tree, node)) {
                fragments.set(@intFromEnum(tree.nodeData(node).node_and_token[0]));
            },
            else => {},
        }
    }
    for (0..tree.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(index);
        const token = tree.nodeMainToken(node);
        if (build_graph and tree.nodeTag(node) == .field_access) {
            const method = tree.nodeData(node).node_and_token[1];
            const name = tree.tokenSlice(method);
            if (std.mem.eql(u8, name, "addCSourceFile") or std.mem.eql(u8, name, "addCSourceFiles")) {
                reportAt(tree, path, method, @errorName(error.LegacyBuildDependency));
                return error.LegacyBuildDependency;
            }
        }
        if (!explicit_legacy_test) {
            if (!fragments.isSet(index)) if (try literalString(alloc, tree, node)) |input| {
                defer alloc.free(input);
                if (build_graph) {
                    checkInput(alloc, directory, input, true, .graph) catch |err| {
                        reportAt(tree, path, token, @errorName(err));
                        return err;
                    };
                } else if (std.ascii.eqlIgnoreCase(std.fs.path.extension(input), ".exe") and legacyInterpreter(input)) {
                    reportAt(tree, path, token, @errorName(error.LegacyRuntimeDependency));
                    return error.LegacyRuntimeDependency;
                }
            };
            if (!build_graph) {
                if (literalChildImage(tree, node)) |image| {
                    const input = (try literalString(alloc, tree, image)) orelse continue;
                    defer alloc.free(input);
                    if (legacyInterpreter(input)) {
                        reportAt(tree, path, tree.firstToken(image), @errorName(error.LegacyRuntimeDependency));
                        return error.LegacyRuntimeDependency;
                    }
                }
            }
        }
        if (tree.tokenTag(token) == .builtin) {
            const builtin = tree.tokenSlice(token);
            const embeds = std.mem.eql(u8, builtin, "@embedFile");
            if (!embeds and !std.mem.eql(u8, builtin, "@import")) continue;
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            const args = tree.builtinCallParams(&buffer, node) orelse continue;
            if (args.len != 1) continue;
            const input_token = tree.firstToken(args[0]);
            const input = (try literalString(alloc, tree, args[0])) orelse continue;
            defer alloc.free(input);
            const checked = if (embeds)
                checkInput(alloc, directory, input, build_graph, .embed)
            else
                checkInput(alloc, directory, input, build_graph, .import);
            checked catch |err| {
                reportAt(tree, path, input_token, @errorName(err));
                return err;
            };
        }
    }
}

fn checkZigFile(alloc: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, path: []const u8, mode: std.zig.Ast.Mode) !void {
    const content = try dir.readFileAllocOptions(alloc, name, 16 * 1024 * 1024, null, .of(u8), 0);
    defer alloc.free(content);
    try checkZig(alloc, path, content, mode);
}

pub fn run(alloc: std.mem.Allocator, root: []const u8) !void {
    var project = try std.fs.cwd().openDir(root, .{});
    defer project.close();
    try checkPackagedDocuments(alloc, project);
    try checkBuildGraph(alloc, project);
    for (release.source_roots) |source_root| try checkSourceTree(alloc, project, source_root);
}

fn checkPackagedDocuments(alloc: std.mem.Allocator, project: std.fs.Dir) !void {
    const version = try project.readFileAlloc(alloc, "VERSION", 1024);
    defer alloc.free(version);
    try utf8(version);
    if (!release.validVersion(std.mem.trim(u8, version, " \t\n"))) return error.InvalidReleaseVersion;

    for (release.packaged_files) |path| {
        const bytes = try project.readFileAlloc(alloc, path, 4 * 1024 * 1024);
        defer alloc.free(bytes);
        try utf8(bytes);
        if (std.mem.endsWith(u8, path, ".md")) try links(alloc, project, path, bytes);
    }
}

fn checkBuildGraph(alloc: std.mem.Allocator, project: std.fs.Dir) !void {
    try checkZigFile(alloc, project, "build.zig", "build.zig", .zig);
    checkZigFile(alloc, project, "build.zig.zon", "build.zig.zon", .zon) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

fn checkSourceTree(alloc: std.mem.Allocator, project: std.fs.Dir, source_root: []const u8) !void {
    var dir = try project.openDir(source_root, .{ .iterate = true, .no_follow = true });
    defer dir.close();
    var walk = try dir.walk(alloc);
    defer walk.deinit();
    while (try walk.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.UnexpectedNativeSource;
        const extension = std.fs.path.extension(entry.basename);
        if (std.mem.eql(u8, extension, ".zig")) {
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ source_root, entry.path });
            defer alloc.free(path);
            std.mem.replaceScalar(u8, path, '\\', '/');
            try checkZigFile(alloc, entry.dir, entry.basename, path, .zig);
        } else if (legacyExtension(extension)) {
            std.debug.print("{s}/{s}\n", .{ source_root, entry.path });
            return error.LegacyExecutableSource;
        }
    }
}

test "active Zig imports and embedded files stay inside the source snapshot" {
    const alloc = std.testing.allocator;
    try checkZig(alloc, "tools/smoke.zig",
        \\const std = @import("std");
        \\const worker = @import("worker");
        \\const storage = @import("../src/storage/store.zig");
        \\const data = @embedFile("../VERSION");
        \\const version = @cImport(@cInclude("windows.h"));
        \\const legacy_evidence = "tests/test-sandbox.ps1";
    , .zig);
    try std.testing.expectError(error.SourceInputOutsideSnapshot, checkZig(alloc, "tools/smoke.zig",
        \\const old = @import("../prototype/zig-worker/main.zig");
    , .zig));
    try std.testing.expectError(error.SourceInputOutsideSnapshot, checkZig(alloc, "src/smoke.zig",
        \\const script = @embedFile("../src/browser/browser_worker.ps1");
    , .zig));
    try std.testing.expectError(error.SourceInputOutsideSnapshot, checkZig(alloc, "src/smoke.zig",
        \\const asset = @embedFile("fixture.html");
    , .zig));
    try std.testing.expectError(error.SourceInputOutsideSnapshot, checkZig(alloc, "tests/integration/probe.zig",
        \\const stale = @import("../.tmp/main.zig");
    , .zig));
    try std.testing.expectError(error.LegacyRuntimeDependency, checkZig(alloc, "tools/future.zig",
        \\const argv = .{"C:\\Windows\\System32\\powershell.exe", "-File"};
    , .zig));
    try checkZig(alloc, "tools/compare.zig",
        \\const interpreter = "powershell.exe";
    , .zig);
    try checkZig(alloc, "tests/integration/rollback_test.zig",
        \\const interpreter = "AutoHotkey64.exe";
    , .zig);
}

test "the active build and optional package manifest reject legacy source or command paths" {
    const alloc = std.testing.allocator;
    try checkZig(alloc, "build.zig",
        \\const description = "Build tools";
        \\const shape = .{ .source = "tests/integration/browser_fixture.zig" };
        \\const version = @embedFile("VERSION");
    , .zig);
    try std.testing.expectError(error.LegacyBuildDependency, checkZig(alloc, "build.zig",
        \\const bridge = b.path("prototype\\zig-worker\\uia_bridge.c");
    , .zig));
    try std.testing.expectError(error.LegacyBuildDependency, checkZig(alloc, "build.zig",
        \\const child = b.addSystemCommand(&.{"PowerShell.EXE", "-File"});
    , .zig));
    try std.testing.expectError(error.SourceInputOutsideSnapshot, checkZig(alloc, "build.zig",
        \\const table = .{ .source = "./experimental/main.zig" };
    , .zig));
    try std.testing.expectError(error.LegacyBuildDependency, checkZig(alloc, "build.zig.zon",
        \\.{ .dependencies = .{ .old = .{ .path = "./prototype/zig-worker" } } }
    , .zon));
    try std.testing.expectError(error.LegacyBuildDependency, checkZig(alloc, "build.zig",
        \\const outside = b.path("tests/integration-old/fixture.zig");
    , .zig));
    try std.testing.expectError(error.InvalidZigSource, checkZig(alloc, "build.zig", "const value = ;\n", .zig));
}

test "the source gate rejects constant legacy paths and explicit C registration" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.LegacyBuildDependency, checkZig(alloc, "build.zig",
        \\const command = b.addSystemCommand(&.{ ("power" ++ "shell") ++ ".exe", "-NoProfile" });
    , .zig));
    try std.testing.expectError(error.LegacyBuildDependency, checkZig(alloc, "build.zig",
        \\const name = "bridge" ++ ".c";
    , .zig));
    try std.testing.expectError(error.LegacyBuildDependency, checkZig(alloc, "build.zig",
        \\pub fn build(b: *Build) void {
        \\    b.root_module.addCSourceFiles(.{ .files = source_names });
        \\}
    , .zig));
    try std.testing.expectError(error.SourceInputOutsideSnapshot, checkZig(alloc, "src/main.zig",
        \\const script = @embedFile(("../scripts/" ++ "probe") ++ ".ps1");
    , .zig));
    try checkZig(alloc, "build.zig",
        \\const source = "src/" ++ "powershell.zig";
        \\const version = @embedFile("VER" ++ "SION");
    , .zig);
}

test "the source gate catches a legacy PATH lookup in a direct child launch" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.LegacyRuntimeDependency, checkZig(alloc, "src/main.zig",
        \\const child = std.process.Child.init(&.{"powershell", "-NoProfile"}, allocator);
    , .zig));
    try std.testing.expectError(error.LegacyRuntimeDependency, checkZig(alloc, "src/main.zig",
        \\const child = std.process.Child.run(.{ .allocator = allocator, .argv = &.{("pw" ++ "sh"), "-NoProfile"} });
    , .zig));
    try checkZig(alloc, "src/main.zig",
        \\const expected_absent = "powershell";
        \\const child = std.process.Child.init(&.{"ChatPalette.exe", "--smoke"}, allocator);
        \\const bound = @cImport(@cInclude("windows.h"));
    , .zig);
}

test "release documentation links stay inside the archive" {
    const alloc = std.testing.allocator;
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    try root.dir.makePath("docs/user");
    try root.dir.writeFile(.{ .sub_path = "docs/user/reference.md", .data = "# Usage\n## アプリを起動する\n\x60\x60\x60\n## Hidden\n\x60\x60\x60\n" });
    const guide = "docs/user/guide.md";
    try links(alloc, root.dir, guide, "## 0.8.0へ戻す\n[help](reference.md#usage), [日本語](reference.md#%E3%82%A2プリを起動する), [back](#080へ戻す), [home](../../README.md), [file](../../ChatPalette.exe)");
    try std.testing.expectError(error.DocumentHeadingMissing, links(alloc, root.dir, guide, "[bad](reference.md#hidden)"));
    try std.testing.expectError(error.DocumentLinkOutsideCandidate, links(alloc, root.dir, guide, "[outside](../index.md)"));
}
