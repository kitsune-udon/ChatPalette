const std = @import("std");
const files = @import("files.zig");
const samples = @import("samples.zig");
const transport = @import("worker_client");
const eql = std.mem.eql;
const Mode = transport.Mode;
const legacy_hash = "7e071f90a371964fe8cdf244d4730eaae9473430caad2392024dded5afd56b19";

const Backend = enum { powershell, zig };
const State = enum { ok, unavailable, wrong_input, changed };
const Detail = enum { empty, chat, comment, other };
const Phase = enum { first, subsequent };

const Expectation = struct {
    request_video: []const u8 = "",
    detected_video: []const u8 = "",
    browser_context: State,
    verify_input: State,
    input_detail: Detail = .empty,

    fn valid(self: Expectation) bool {
        return (self.request_video.len == 0 or validVideo(self.request_video)) and
            (self.detected_video.len == 0 or validVideo(self.detected_video)) and
            (self.browser_context == .ok or self.browser_context == .unavailable) and self.input_detail != .other;
    }

    fn observes(self: Expectation, mode: Mode, observed: Response) bool {
        const state = if (mode == .browser_context) self.browser_context else self.verify_input;
        const detail = if (mode == .browser_context) .empty else self.input_detail;
        const video: []const u8 = if (observed.video) |*id| id else "";
        return state == observed.public.state and detail == observed.public.detail and eql(u8, self.detected_video, video);
    }
};

const PublicResponse = struct {
    state: State,
    has_video: bool,
    detail: Detail,
    milliseconds: f64,
};

const Response = struct {
    public: PublicResponse,
    video: ?[11]u8,
    detail_digest: files.Digest,

    fn same(a: Response, b: Response) bool {
        if (a.public.state != b.public.state or !eql(u8, &a.detail_digest, &b.detail_digest)) return false;
        if (a.video) |value| {
            return if (b.video) |other| eql(u8, &value, &other) else false;
        }
        return b.video == null;
    }
};

fn validVideo(value: []const u8) bool {
    if (value.len != 11) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

const Fields = enum { Seq, State, Author, Channel, Video, Window, Detail };

fn classifyReply(reply: transport.Reply, mode: Mode, ms: f64) !Response {
    var seen: std.EnumSet(Fields) = .initEmpty();
    var lines = std.mem.splitScalar(u8, reply.payload, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidReplyField;
        if (std.mem.indexOfScalar(u8, line, '\r') != null) return error.InvalidReplyField;
        const field = std.meta.stringToEnum(Fields, line[0..eq]) orelse return error.InvalidReplyField;
        if (seen.contains(field)) return error.DuplicateReplyField;
        seen.insert(field);
    }
    if (!seen.contains(.Seq) or !seen.contains(.Window) or !seen.contains(.State) or !seen.contains(.Video)) {
        return error.MissingReplyField;
    }
    const state = std.meta.stringToEnum(State, reply.field("State")) orelse return error.InvalidReplyState;
    if (mode == .browser_context and state != .ok and state != .unavailable) return error.InvalidReplyState;
    const raw_video = reply.field("Video");
    const video = if (raw_video.len == 0) null else blk: {
        if (!validVideo(raw_video)) return error.InvalidReplyVideo;
        break :blk raw_video[0..11].*;
    };
    if (state != .unavailable and video == null) return error.MissingReplyVideo;
    const raw_detail = reply.field("Detail");
    const detail: Detail = if (raw_detail.len == 0) .empty else if (eql(u8, raw_detail, "chat")) .chat else if (eql(u8, raw_detail, "comment")) .comment else .other;
    if (mode == .verify_input and state == .ok and detail != .chat and detail != .comment) {
        return error.InvalidReplyDetail;
    }
    return .{
        .public = .{ .state = state, .has_video = video != null, .detail = detail, .milliseconds = ms },
        .video = video,
        .detail_digest = files.digest(raw_detail),
    };
}

fn pump(signal: ?*anyopaque, milliseconds: u32) !void {
    const awake = signal orelse return error.MissingWorkerSignal;
    std.os.windows.WaitForSingleObject(awake, milliseconds) catch |err| {
        if (err != error.WaitTimeOut) return err;
    };
}

const Trial = struct {
    replies: [2]?Response = @splat(null),
    failure: ?[]const u8 = null,
    cleanup: ?[]const u8 = null,

    fn succeeded(self: Trial) bool {
        return self.failure == null and self.cleanup == null and self.replies[0] != null and self.replies[1] != null;
    }
};

fn trial(allocator: std.mem.Allocator, launch: transport.Launch, modes: [2]Mode, hwnd: usize, expected_video: []const u8) Trial {
    var client: transport.Client = .{};
    var result: Trial = .{};
    for (modes, 0..) |mode, index| {
        var timer = std.time.Timer.start() catch |err| {
            result.failure = @errorName(err);
            break;
        };
        const reply = client.requestWithLaunch(allocator, launch, index == 0, mode, hwnd, expected_video, &.{}, pump) catch |err| {
            result.failure = @errorName(err);
            break;
        };
        const elapsed = samples.milliseconds(&timer);
        defer reply.deinit();
        const limit: f64 = @floatFromInt(mode.deadlineMs());
        if (elapsed > limit) {
            result.failure = "WorkerTimeout";
            break;
        }
        result.replies[index] = classifyReply(reply, mode, elapsed) catch |err| {
            result.failure = @errorName(err);
            break;
        };
    }
    if (client.cleanup_failure) |failure| result.cleanup = @errorName(failure);
    client.stop() catch |err| {
        result.cleanup = @errorName(err);
    };
    return result;
}

const Pair = struct {
    mode: Mode,
    phase: Phase,
    powershell: ?PublicResponse,
    zig: ?PublicResponse,
    agrees: bool,
    powershell_matches_expectation: ?bool,
    zig_matches_expectation: ?bool,
};

const Round = struct {
    number: usize,
    first_mode: Mode,
    backend_order: [2]Backend,
    measurements: [2]Pair,
    powershell_failure: ?[]const u8,
    zig_failure: ?[]const u8,
    powershell_cleanup: ?[]const u8,
    zig_cleanup: ?[]const u8,
    passed: bool,
};

const Summary = struct {
    mode: Mode,
    phase: Phase,
    pairs: usize,
    powershell: ?samples.Sample,
    zig: ?samples.Sample,
};

fn agreesWith(requirements: ?Expectation, mode: Mode, response: ?Response) ?bool {
    const expected = requirements orelse return null;
    return if (response) |value| expected.observes(mode, value) else false;
}

fn summarize(allocator: std.mem.Allocator, rounds: []const Round, mode: Mode, phase: Phase) !Summary {
    var old: std.ArrayList(f64) = .empty;
    var new: std.ArrayList(f64) = .empty;
    for (rounds) |round| {
        if (!round.passed) continue;
        for (round.measurements) |pair| {
            if (pair.mode != mode or pair.phase != phase) continue;
            if (pair.powershell.?.state != .ok) continue;
            try old.append(allocator, pair.powershell.?.milliseconds);
            try new.append(allocator, pair.zig.?.milliseconds);
        }
    }
    return .{
        .mode = mode,
        .phase = phase,
        .pairs = old.items.len,
        .powershell = if (old.items.len == 0) null else try samples.summarize(allocator, 0, @tagName(mode), old.items),
        .zig = if (new.items.len == 0) null else try samples.summarize(allocator, 0, @tagName(mode), new.items),
    };
}

fn compare(allocator: std.mem.Allocator, legacy: transport.Launch, native: transport.Launch, hwnd: usize, repeats: usize, expected: ?Expectation) !struct {
    rounds: []Round,
    passed: bool,
} {
    const request_video = if (expected) |value| value.request_video else "";
    const orders = [_][2]Mode{ .{ .browser_context, .verify_input }, .{ .verify_input, .browser_context } };
    const rounds = try allocator.alloc(Round, repeats * orders.len);
    var all_pass = true;
    for (orders, 0..) |modes, permutation| {
        for (0..repeats) |index| {
            const backend_order: [2]Backend = if (index % 2 == 0) .{ .powershell, .zig } else .{ .zig, .powershell };
            var results: std.EnumArray(Backend, Trial) = undefined;
            for (backend_order) |backend| {
                results.set(backend, trial(allocator, if (backend == .powershell) legacy else native, modes, hwnd, request_video));
            }
            const old = results.get(.powershell);
            const new = results.get(.zig);
            var pairs: [2]Pair = undefined;
            var pass = old.succeeded() and new.succeeded();
            for (modes, &pairs, 0..) |mode, *pair, position| {
                const a = old.replies[position];
                const b = new.replies[position];
                const equal = if (a != null and b != null) a.?.same(b.?) else false;
                const old_expected = agreesWith(expected, mode, a);
                const new_expected = agreesWith(expected, mode, b);
                pass = pass and equal and (old_expected orelse true) and (new_expected orelse true);
                pair.* = .{
                    .mode = mode,
                    .phase = if (position == 0) .first else .subsequent,
                    .powershell = if (a) |value| value.public else null,
                    .zig = if (b) |value| value.public else null,
                    .agrees = equal,
                    .powershell_matches_expectation = old_expected,
                    .zig_matches_expectation = new_expected,
                };
            }
            rounds[permutation * repeats + index] = .{
                .number = index + 1,
                .first_mode = modes[0],
                .backend_order = backend_order,
                .measurements = pairs,
                .powershell_failure = old.failure,
                .zig_failure = new.failure,
                .powershell_cleanup = old.cleanup,
                .zig_cleanup = new.cleanup,
                .passed = pass,
            };
            all_pass = all_pass and pass;
        }
    }
    return .{ .rounds = rounds, .passed = all_pass };
}

fn readExpectation(allocator: std.mem.Allocator, path: []const u8) !Expectation {
    const file = try std.fs.cwd().readFileAlloc(allocator, path, 65536);
    const parsed = try std.json.parseFromSliceLeaky(Expectation, allocator, file, .{});
    if (!parsed.valid()) return error.InvalidComparisonExpectation;
    return parsed;
}

pub fn run(
    allocator: std.mem.Allocator,
    legacy_zip: []const u8,
    native_path: []const u8,
    window_handle: []const u8,
    repeat_count: []const u8,
    output_path: []const u8,
    expectation_path: ?[]const u8,
) !bool {
    for (window_handle) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidWindowHandle;
    const hwnd = try std.fmt.parseUnsigned(usize, window_handle, 10);
    const repeats = try std.fmt.parseUnsigned(usize, repeat_count, 10);
    if (repeats < 1 or repeats > 1000) return error.InvalidComparisonRepeats;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const legacy_abs = try std.fs.cwd().realpathAlloc(alloc, legacy_zip);
    const archive = try files.openImmutable(alloc, legacy_abs);
    defer archive.close();
    const archive_sha = files.hex(try files.fileDigest(archive));
    if (!eql(u8, &archive_sha, legacy_hash)) return error.ExpectedVerifiedLegacyArchive;

    const candidate_abs = try std.fs.cwd().realpathAlloc(alloc, native_path);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(candidate_abs), ".exe")) return error.ExpectedNativeExecutable;
    const candidate = try files.openImmutable(alloc, candidate_abs);
    defer candidate.close();
    const candidate_sha = files.hex(try files.fileDigest(candidate));
    const expectation = if (expectation_path) |path| try readExpectation(alloc, path) else null;

    if (std.fs.path.dirname(output_path)) |parent| try std.fs.cwd().makePath(parent);
    try std.fs.cwd().makeDir(output_path);
    var output = try std.fs.cwd().openDir(output_path, .{ .no_follow = true });
    defer output.close();
    try output.makeDir("legacy-0.8.0");
    var snapshot = try output.openDir("legacy-0.8.0", .{ .no_follow = true });
    defer snapshot.close();
    var buffer: [8192]u8 = undefined;
    var reader = archive.reader(&buffer);
    try std.zip.extract(snapshot, &reader, .{});
    const workdir = try snapshot.realpathAlloc(alloc, ".");
    const script = try std.fs.path.join(alloc, &.{ workdir, "src", "browser", "browser_worker.ps1" });
    const system_root = try std.process.getEnvVarOwned(alloc, "SystemRoot");
    const ps = try std.fs.path.join(alloc, &.{ system_root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe" });

    const legacy: transport.Launch = .{
        .executable = try std.unicode.utf8ToUtf16LeAllocZ(alloc, ps),
        .arguments_before_pipe = try std.fmt.allocPrint(alloc, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{s}\"", .{script}),
        .working_directory = try std.unicode.utf8ToUtf16LeAllocZ(alloc, workdir),
    };
    const native: transport.Launch = .{
        .executable = try std.unicode.utf8ToUtf16LeAllocZ(alloc, candidate_abs),
        .working_directory = legacy.working_directory,
    };
    const result = try compare(alloc, legacy, native, hwnd, repeats, expectation);
    const summary = [4]Summary{
        try summarize(alloc, result.rounds, .browser_context, .first),
        try summarize(alloc, result.rounds, .browser_context, .subsequent),
        try summarize(alloc, result.rounds, .verify_input, .first),
        try summarize(alloc, result.rounds, .verify_input, .subsequent),
    };
    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .passed = result.passed,
        .independent_expectation = expectation != null,
        .repeats_per_order = repeats,
        .legacy_sha256 = &archive_sha,
        .native_sha256 = &candidate_sha,
        .summary = summary,
        .rounds = result.rounds,
    }, .{ .whitespace = .indent_2 });
    try files.writeNew(output, "comparison.json", json);
    return result.passed;
}

test "comparison keeps provider details and video IDs out of public evidence" {
    const source: []const u8 = "Seq=1\nState=ok\nWindow=123\nVideo=ZigTest0001\nDetail=chat";
    const reply: transport.Reply = .{ .payload = source, .alloc = undefined };
    const value = try classifyReply(reply, .verify_input, 42);
    const report = try std.json.Stringify.valueAlloc(std.testing.allocator, value.public, .{});
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "ZigTest0001") == null);
    const private: transport.Reply = .{
        .payload = "Seq=1\nState=unavailable\nWindow=123\nVideo=\nDetail=https://private.example/",
        .alloc = undefined,
    };
    const failed = try classifyReply(private, .verify_input, 42);
    try std.testing.expectEqual(Detail.other, failed.public.detail);
    try std.testing.expectError(error.DuplicateReplyField, classifyReply(.{
        .payload = "Seq=1\nSeq=2\nState=ok\nWindow=123\nVideo=ZigTest0001",
        .alloc = undefined,
    }, .browser_context, 1));
}
