const std = @import("std");
const worker = @import("worker");
const files = @import("files.zig");
const win = std.os.windows;
const api = worker.win_api.sdk;

extern "user32" fn EnumWindows(*const fn (?win.HANDLE, isize) callconv(.winapi) win.BOOL, isize) callconv(.winapi) win.BOOL;
extern "user32" fn IsWindowVisible(win.HANDLE) callconv(.winapi) win.BOOL;
extern "user32" fn GetWindowThreadProcessId(win.HANDLE, *u32) callconv(.winapi) u32;
extern "version" fn GetFileVersionInfoSizeW(win.LPCWSTR, *u32) callconv(.winapi) u32;
extern "version" fn GetFileVersionInfoW(win.LPCWSTR, u32, u32, *anyopaque) callconv(.winapi) win.BOOL;
extern "version" fn VerQueryValueW(*const anyopaque, win.LPCWSTR, *?*anyopaque, *u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn CreateMutexW(?*win.SECURITY_ATTRIBUTES, win.BOOL, win.LPCWSTR) callconv(.winapi) ?win.HANDLE;

const FixedFileInfo = extern struct {
    signature: u32,
    structure_version: u32,
    file_version_msb: u32,
    file_version_lsb: u32,
};

const PageKind = enum { Auto, Watch, Popout, unknown };
const Window = struct { Browser: []const u8, WindowHandle: usize };
const Report = struct {
    TimeUnixMs: i64,
    Browser: []const u8 = "",
    BrowserVersion: []const u8 = "",
    PageKind: PageKind = .unknown,
    Foreground: bool = false,
    AddressDetected: bool = false,
    VideoDetected: bool = false,
    ChatState: []const u8 = "not-run",
    ChatDetected: bool = false,
    LauncherDetected: bool = false,
    Focus: []const u8 = "not-run",
    Hover: []const u8 = "not-run",
    Display: []const u8 = "not-verified",
    Error: []const u8 = "",
    ErrorKind: []const u8 = "",
};

const Enumeration = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window) = .empty,
    failed: bool = false,

    fn callback(window: ?win.HANDLE, token: isize) callconv(.winapi) win.BOOL {
        const self: *Enumeration = @ptrFromInt(@as(usize, @bitCast(token)));
        const found = window orelse return 1;
        if (IsWindowVisible(found) == 0) return 1;
        const number = @intFromPtr(found);
        const image = worker.browserName(self.allocator, number) catch return 1;
        defer self.allocator.free(image);
        const name = worker.supportedBrowser(image) orelse return 1;
        self.windows.append(self.allocator, .{ .Browser = name, .WindowHandle = number }) catch {
            self.failed = true;
            return 0;
        };
        return 1;
    }
};

pub fn list(allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var result: Enumeration = .{ .allocator = arena.allocator() };
    if (EnumWindows(&Enumeration.callback, @bitCast(@intFromPtr(&result))) == 0) {
        return if (result.failed) error.OutOfMemory else error.CouldNotEnumerateBrowserWindows;
    }
    return std.json.Stringify.valueAlloc(allocator, result.windows.items, .{ .whitespace = .indent_2 });
}

fn fileVersion(alloc: std.mem.Allocator, hwnd: usize) ![]const u8 {
    var id: u32 = 0;
    _ = GetWindowThreadProcessId(@ptrFromInt(hwnd), &id);
    if (id == 0) return error.WindowUnavailable;
    const process = api.OpenProcess(api.PROCESS_QUERY_LIMITED_INFORMATION, api.FALSE, id) orelse return error.BrowserUnavailable;
    defer _ = api.CloseHandle(process);
    var path: [32768]u16 = undefined;
    var length: u32 = path.len - 1;
    if (api.QueryFullProcessImageNameW(process, 0, &path, &length) == 0) return error.BrowserUnavailable;
    path[length] = 0;
    return versionFromPath(alloc, path[0..length :0]);
}

pub fn executableVersion(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    return versionFromPath(alloc, wide);
}

fn versionFromPath(alloc: std.mem.Allocator, path: win.LPCWSTR) ![]const u8 {
    var unused: u32 = 0;
    const needed = GetFileVersionInfoSizeW(path, &unused);
    if (needed == 0 or needed > 1024 * 1024) return error.BrowserVersionUnavailable;
    const data = try alloc.alloc(u8, needed);
    defer alloc.free(data);
    if (GetFileVersionInfoW(path, 0, needed, data.ptr) == 0) return error.BrowserVersionUnavailable;
    var raw: ?*anyopaque = null;
    var size: u32 = 0;
    if (VerQueryValueW(data.ptr, std.unicode.utf8ToUtf16LeStringLiteral("\\"), &raw, &size) == 0 or
        size < @sizeOf(FixedFileInfo)) return error.BrowserVersionUnavailable;
    const value: *align(1) const FixedFileInfo = @ptrCast(raw orelse return error.BrowserVersionUnavailable);
    if (value.signature != 0xfeef04bd) return error.BrowserVersionUnavailable;
    return std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{
        value.file_version_msb >> 16,
        value.file_version_msb & 0xffff,
        value.file_version_lsb >> 16,
        value.file_version_lsb & 0xffff,
    });
}

fn expectedPage(value: []const u8) !PageKind {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .Auto;
    if (std.ascii.eqlIgnoreCase(value, "watch")) return .Watch;
    if (std.ascii.eqlIgnoreCase(value, "popout")) return .Popout;
    return error.InvalidPageKind;
}

const Probe = struct {
    allocator: std.mem.Allocator,
    hwnd: usize,
    browser_worker: worker.Worker,
    window: *worker.UiaClientWindow = undefined,
    context: ?worker.VideoContext = null,

    fn open(self: *Probe, report: *Report) !void {
        if (self.hwnd == 0) return error.InvalidWindowHandle;
        const image = try worker.browserName(self.allocator, self.hwnd);
        defer self.allocator.free(image);
        report.Browser = worker.supportedBrowser(image) orelse return error.UnsupportedBrowser;
        report.BrowserVersion = try fileVersion(self.allocator, self.hwnd);
        self.window = try self.browser_worker.client.windowFor(self.hwnd);
    }

    fn foreground(self: *Probe) !bool {
        // Read-only inspection must also work if UI Automation cannot resolve
        // the focused element. Page actions still check focus in the worker.
        return @intFromPtr(api.GetForegroundWindow()) == self.hwnd;
    }

    fn detectAddress(self: *Probe, report: *Report) !void {
        self.context = try self.browser_worker.client.readVideoContext(self.window);
        report.VideoDetected = self.context != null;
        report.AddressDetected = self.window.address != null;
    }

    fn kind(self: *Probe) !PageKind {
        const context = self.context orelse return error.VideoUnavailable;
        return switch (context.page) {
            .watch => .Watch,
            .popout => .Popout,
        };
    }

    fn chatState(self: *Probe) ![]const u8 {
        switch (try worker.pages_api.findChat(&self.browser_worker.client, self.window)) {
            .target => |element| {
                worker.win_api.release(element);
                return "ok";
            },
            .ambiguous => return "chat_ambiguous",
            .missing => return "chat_missing",
        }
    }

    fn launcher(self: *Probe) !bool {
        const element = try worker.pages_api.findLauncher(&self.browser_worker.client, self.window) orelse return false;
        worker.win_api.release(element);
        return true;
    }

    fn pageAction(self: *Probe, mode: worker.Mode) ![]const u8 {
        const context = self.context orelse return error.VideoUnavailable;
        var reply: worker.Reply = .{};
        try self.browser_worker.execute(self.allocator, .{ .mode = mode, .hwnd = self.hwnd, .video = &context.id }, &reply);
        return reply.state;
    }
};

fn check(observations: anytype, expected: PageKind, exercise: bool, stage: *[]const u8, report: *Report) !void {
    try observations.open(report);
    stage.* = "foreground";
    report.Foreground = try observations.foreground();
    stage.* = "address";
    try observations.detectAddress(report);
    if (report.VideoDetected) {
        stage.* = "page-kind";
        report.PageKind = try observations.kind();
        if (expected != .Auto and expected != report.PageKind) return error.UnexpectedPageKind;
    }

    stage.* = "chat";
    report.ChatState = "unknown";
    report.ChatState = try observations.chatState();
    report.ChatDetected = std.mem.eql(u8, report.ChatState, "ok");
    stage.* = "launcher";
    report.LauncherDetected = try observations.launcher();

    if (exercise) {
        stage.* = "exercise-precondition";
        if (!report.VideoDetected) return error.VideoUnavailable;
        if (!report.Foreground) return error.BrowserNotForeground;
        stage.* = "focus";
        report.Focus = "unknown";
        report.Focus = try observations.pageAction(.chat_focus);
        stage.* = "hover";
        report.Hover = "unknown";
        report.Hover = try observations.pageAction(.reactions_show);
    }
}

fn observe(allocator: std.mem.Allocator, hwnd: usize, page: PageKind, exercise: bool, stage: *[]const u8, report: *Report) !void {
    if (hwnd == 0) return error.InvalidWindowHandle;
    var probe: Probe = .{ .allocator = allocator, .hwnd = hwnd, .browser_worker = try worker.Worker.init() };
    defer probe.browser_worker.deinit();
    return check(&probe, page, exercise, stage, report);
}

fn reserveExercise(alloc: std.mem.Allocator, destination: []const u8) !win.HANDLE {
    const folded = try std.unicode.utf8ToUtf16LeAlloc(alloc, destination);
    defer alloc.free(folded);
    for (folded) |*unit| unit.* = win.nls.upcaseW(unit.*);
    const digest = files.hex(files.digest(std.mem.sliceAsBytes(folded)));
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\ChatPaletteBrowserExercise-");
    var key: [name.len + digest.len:0]u16 = undefined;
    @memcpy(key[0..name.len], name);
    for (digest, name.len..) |byte, i| key[i] = byte;
    key[key.len] = 0;
    // The object's lifetime is the reservation. Windows releases it on process exit.
    const handle = CreateMutexW(null, win.FALSE, &key) orelse return error.BrowserReportReservationUnavailable;
    if (win.GetLastError() == .ALREADY_EXISTS) {
        win.CloseHandle(handle);
        return error.PathAlreadyExists;
    }
    return handle;
}

pub fn inspect(allocator: std.mem.Allocator, raw_hwnd: []const u8, expected: []const u8, output_path: []const u8, exercise: bool) !bool {
    const number = try std.fmt.parseInt(i64, raw_hwnd, 10);
    const hwnd = if (number <= 0) 0 else @as(usize, @intCast(number));
    const page = try expectedPage(expected);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const absolute = try std.fs.path.resolve(alloc, &.{ try std.process.getCwdAlloc(alloc), output_path });
    const parent = std.fs.path.dirname(absolute) orelse return error.InvalidReportPath;
    try cwd.makePath(parent);
    const directory = try cwd.realpathAlloc(alloc, parent);
    const destination = try std.fs.path.join(alloc, &.{ directory, std.fs.path.basename(absolute) });
    const reservation = if (exercise) try reserveExercise(alloc, destination) else null;
    defer if (reservation) |handle| win.CloseHandle(handle);
    if (cwd.access(destination, .{})) |_| {
        return error.PathAlreadyExists;
    } else |err| if (err != error.FileNotFound) {
        return err;
    }

    const random = std.crypto.random.int(u128);
    const temp_name = try std.fmt.allocPrint(alloc, ".chatpalette-report-{x:0>32}.tmp", .{random});
    const temp_path = try std.fs.path.join(alloc, &.{ directory, temp_name });
    const output = try cwd.createFile(temp_path, .{ .exclusive = true });
    errdefer cwd.deleteFile(temp_path) catch {};
    var report: Report = .{ .TimeUnixMs = std.time.milliTimestamp() };
    var stage: []const u8 = "window";
    {
        defer output.close();
        observe(alloc, hwnd, page, exercise, &stage, &report) catch |failure| {
            // Fixed names only. Provider messages and element contents never enter a report.
            report.Error = try std.fmt.allocPrint(alloc, "Inspection failed at {s}. Verify the target window and this inspection step.", .{stage});
            report.ErrorKind = @errorName(failure);
        };
        const bytes = try std.json.Stringify.valueAlloc(alloc, report, .{ .whitespace = .indent_2 });
        try output.writeAll(bytes);
        try output.sync();
    }
    files.publish(alloc, temp_path, destination) catch |err| switch (err) {
        error.OutputExists => return error.PathAlreadyExists,
        else => return err,
    };
    return report.Error.len == 0 and report.VideoDetected and report.ChatDetected and report.LauncherDetected and
        (!exercise or (std.mem.eql(u8, report.Focus, "focused") and std.mem.eql(u8, report.Hover, "hovered")));
}

test "page report uses the captured video context and omits the video ID" {
    const alloc = std.testing.allocator;
    var probe: Probe = .{ .allocator = alloc, .hwnd = 0, .browser_worker = undefined };
    try std.testing.expectError(error.VideoUnavailable, probe.kind());
    probe.context = .{ .id = "Fixture0001".*, .page = .popout };
    var report: Report = .{ .TimeUnixMs = 0 };
    report.VideoDetected = true;
    report.PageKind = try probe.kind();
    try std.testing.expectEqual(PageKind.Popout, report.PageKind);
    const encoded = try std.json.Stringify.valueAlloc(alloc, report, .{});
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "Fixture0001") == null);
    probe.context.?.page = .watch;
    try std.testing.expectEqual(PageKind.Watch, try probe.kind());
}

test "browser report rejects invalid options and preserves a published report" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const destination = try std.fs.path.join(alloc, &.{ root, "new dir", "diagnosis.json" });
    defer alloc.free(destination);
    try std.testing.expectError(error.InvalidCharacter, inspect(alloc, "bad-handle", "auto", destination, false));
    try std.testing.expectError(error.InvalidPageKind, inspect(alloc, "0", "bad-page", destination, false));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("new dir", .{}));
    try std.testing.expect(!(try inspect(alloc, "0", "auto", destination, false)));
    const data = try tmp.dir.readFileAlloc(alloc, "new dir/diagnosis.json", 4096);
    defer alloc.free(data);
    const parsed = try std.json.parseFromSlice(Report, alloc, data, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.AddressDetected and !parsed.value.VideoDetected and !parsed.value.ChatDetected);
    try std.testing.expectEqualStrings("not-run", parsed.value.ChatState);
    try std.testing.expectEqualStrings("not-run", parsed.value.Focus);
    try std.testing.expectEqualStrings("not-run", parsed.value.Hover);
    try std.testing.expect(std.mem.startsWith(u8, parsed.value.Error, "Inspection failed at window."));
    try std.testing.expectError(error.PathAlreadyExists, inspect(alloc, "0", "popout", destination, true));
    const retained = try tmp.dir.readFileAlloc(alloc, "new dir/diagnosis.json", 4096);
    defer alloc.free(retained);
    try std.testing.expectEqualStrings(data, retained);
}

test "browser exercise reservation covers case aliases and releases the report path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const first = try std.fs.path.join(alloc, &.{ root, "Café.json" });
    defer alloc.free(first);
    const alias = try std.fs.path.join(alloc, &.{ root, ".", "CAFÉ.JSON" });
    defer alloc.free(alias);
    {
        const reservation = try reserveExercise(alloc, first);
        defer win.CloseHandle(reservation);
        try std.testing.expectError(error.PathAlreadyExists, inspect(alloc, "0", "auto", alias, true));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access("Café.json", .{}));
    }
    try std.testing.expect(!(try inspect(alloc, "0", "auto", alias, true)));
    try tmp.dir.access("Café.json", .{});
}

test "report retains the distinction between chat states and partial failures" {
    const Fake = struct {
        chat: []const u8 = "ok",
        fault: []const u8 = "",
        is_foreground: bool = true,

        fn open(_: @This(), report: *Report) !void {
            report.Browser = "brave";
        }

        fn foreground(self: @This()) !bool {
            return self.is_foreground;
        }

        fn detectAddress(_: @This(), report: *Report) !void {
            report.AddressDetected = true;
            report.VideoDetected = true;
        }

        fn kind(_: @This()) !PageKind {
            return .Watch;
        }

        fn chatState(self: @This()) ![]const u8 {
            if (std.mem.eql(u8, self.fault, "chat")) return error.PrivateProviderFailure;
            return self.chat;
        }

        fn launcher(_: @This()) !bool {
            return true;
        }

        fn pageAction(self: @This(), mode: worker.Mode) ![]const u8 {
            return switch (mode) {
                .chat_focus => if (std.mem.eql(u8, self.fault, "focus")) error.PrivateProviderFailure else "focused",
                .reactions_show => if (std.mem.eql(u8, self.fault, "hover")) error.PrivateProviderFailure else "hovered",
                else => error.UnexpectedPageAction,
            };
        }
    };

    for ([_][]const u8{ "ok", "chat_missing", "chat_ambiguous" }) |chat| {
        var report: Report = .{ .TimeUnixMs = 0 };
        var stage: []const u8 = "window";
        try check(Fake{ .chat = chat }, .Watch, false, &stage, &report);
        try std.testing.expectEqualStrings(chat, report.ChatState);
        try std.testing.expectEqual(std.mem.eql(u8, chat, "ok"), report.ChatDetected);
        try std.testing.expectEqualStrings("not-run", report.Focus);
    }
    {
        var report: Report = .{ .TimeUnixMs = 0 };
        var stage: []const u8 = "window";
        try check(Fake{ .is_foreground = false }, .Watch, false, &stage, &report);
        try std.testing.expect(!report.Foreground and report.VideoDetected and report.ChatDetected);
        try std.testing.expectError(error.BrowserNotForeground, check(Fake{ .is_foreground = false }, .Watch, true, &stage, &report));
        try std.testing.expectEqualStrings("not-run", report.Focus);
    }
    for ([_][]const u8{ "chat", "focus", "hover" }) |fault| {
        var report: Report = .{ .TimeUnixMs = 0 };
        var stage: []const u8 = "window";
        try std.testing.expectError(error.PrivateProviderFailure, check(Fake{ .fault = fault }, .Watch, true, &stage, &report));
        try std.testing.expectEqualStrings(fault, stage);
        try std.testing.expect(report.VideoDetected);
        try std.testing.expectEqualStrings("not-verified", report.Display);
    }
}
