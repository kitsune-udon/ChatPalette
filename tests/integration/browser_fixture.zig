const std = @import("std");
const files = @import("tool_support").files;
const process = @import("tool_support").process;
const storage = @import("chatpalette").storage;
const sqlite = @import("chatpalette").sqlite;
const fixture_browser = @import("tool_support").fixture_browser;
const cdp = @import("browser_fixture/cdp.zig");
const driver = @import("browser_fixture/win.zig");
const sdk = driver.sdk;
const uia = @import("chatpalette").uia;
const automation = @import("chatpalette").worker.win_api;
const transport = @import("chatpalette").worker_client;
const keyboard_io = @import("chatpalette").keyboard;
const operations = @import("chatpalette").operations;

const observations = @import("browser_fixture/observations.zig");
const Event = observations.Event;
const State = observations.State;
const Observation = observations.Observation;
const Modifiers = observations.Modifiers;
const Case = observations.Case;
const PageDiagnostic = observations.PageDiagnostic;
const Report = observations.Report;

const allocator = std.heap.page_allocator;
const browser_class = driver.wide("Chrome_WidgetWin_1");
const host_class = driver.wide("ChatPalette.Host");
const palette_class = driver.wide("ChatPalette.Palette");
const manager_class = driver.wide("ChatPalette.Management");
const library_editor_class = driver.wide("ChatPalette.LibraryEditor");
const overlay_class = driver.wide("ChatPalette.ReactionProgress");
const dialog_class = driver.wide("ChatPalette.Support");
const reaction_start_id = 109;
const reaction_kind_id = 110;
const reaction_count_id = 111;
const reaction_interval_id = 112;
const reaction_save_id = 113;
const open_management_command = 4;
const shortcut_settings_command = 5;
const diagnostics_command = 7;
const add_library_item_id = 227;
const edit_allowed_message = sdk.WM_APP + 23;
const database = "data/settings.db";
const alpha = "甲👏";
const beta = "乙";
const manual_a = "fixture-manual-a";
const manual_b = "fixture-manual-b";
const a1 = "配信者A・一🎈";
const a2 = "配信者A・二🌸";
const b1 = "配信者B・一🎆";
const b2 = "配信者B・二🌿";
const restarted_keys: [storage.action_count][]const u8 = .{
    "^+q", "^+1", "^+2", "^+3", "^+4", "^+f", "^+w", "^+r", "^+t", "^+e", "^+s",
};
const original_video = "ZigTest0001";
const changed_video = "ZigTest0002";
const context_completion_ms = 8250;

const Arguments = struct {
    candidate: []const u8,
    output: []const u8,
    browser_exe: ?[]const u8,
    ime_only: bool,
};

fn arguments(args: []const []const u8) !Arguments {
    const ime_only = args.len > 2 and equal(args[args.len - 1], "--ime-only");
    const paths = args[0 .. args.len - @intFromBool(ime_only)];
    if (paths.len < 2 or paths.len > 3 or paths[1].len == 0) return error.FixtureUsage;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(args[0]), "ChatPalette.exe")) return error.ExpectedChatPaletteExecutable;
    if (paths.len == 3) {
        if (!std.fs.path.isAbsolute(paths[2])) return error.ExpectedAbsoluteBrowserExecutable;
        _ = try fixture_browser.Browser.fromPath(paths[2]);
    }
    return .{ .candidate = paths[0], .output = paths[1], .browser_exe = if (paths.len == 3) paths[2] else null, .ime_only = ime_only };
}

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const config = arguments(args[1..]) catch |failure| {
        std.debug.print("chatpalette-browser-fixture <ChatPalette.exe> <新規結果フォルダー> [<ブラウザーEXEの絶対パス>] [--ime-only]\n{s}\n", .{@errorName(failure)});
        std.process.exit(2);
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cwd = std.fs.cwd();
    const source = try cwd.realpathAlloc(alloc, config.candidate);
    const browser_exe = try fixture_browser.installed(alloc, config.browser_exe);
    try cwd.makeDir(config.output);
    const output = try cwd.realpathAlloc(alloc, config.output);
    var report: Report = .{};
    const selected: []const Scenario = if (config.ime_only) &ime_cases else &cases;
    verify(alloc, source, browser_exe, output, selected, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    report.passed = report.failure == null and report.cleanup_error == null and report.cases.items.len == selected.len;
    try process.saveResult(alloc, output, try report.serialized(alloc));
    if (!report.passed) {
        std.debug.print("合成ブラウザー試験失敗 {s} {s}\n", .{ report.failure orelse "", report.cleanup_error orelse "" });
        std.process.exit(1);
    }
    var summary: [128]u8 = undefined;
    try std.fs.File.stdout().writeAll(try std.fmt.bufPrint(&summary, "合成ブラウザー試験 {d}件成功\n", .{report.cases.items.len}));
}

fn verify(alloc: std.mem.Allocator, source: []const u8, browser_exe: []const u8, output: []const u8, selected: []const Scenario, report: *Report) !void {
    var dir = try std.fs.cwd().openDir(output, .{});
    defer dir.close();
    const archived = try files.openImmutable(alloc, source);
    defer archived.close();
    const image = try archived.readToEndAlloc(alloc, 64 * 1024 * 1024);
    const digest = files.digest(image);
    report.sha256 = files.hex(digest);
    try dir.makeDir("candidate");
    var candidate = try dir.openDir("candidate", .{});
    defer candidate.close();
    try files.writeNew(candidate, "ChatPalette.exe", image);
    if (!std.mem.eql(u8, &digest, &(try files.readDigest(candidate, "ChatPalette.exe")))) return error.FixtureCandidateCopy;
    const candidate_dir = try std.fs.path.join(alloc, &.{ output, "candidate" });
    const candidate_path = try std.fs.path.join(alloc, &.{ candidate_dir, "ChatPalette.exe" });
    try candidate.makeDir("data");
    try seed(try std.fs.path.join(alloc, &.{ candidate_dir, database }));
    try dir.makeDir("profile");
    const profile = try std.fs.path.join(alloc, &.{ output, "profile" });

    // A bound, never-serviced loopback proxy plus resolver denial covers Chromium before Fetch is armed.
    var sink = try (try std.net.Address.parseIp4("127.0.0.1", 0)).listen(.{});
    defer sink.deinit();
    const proxy_arg = try std.fmt.allocPrint(alloc, "--proxy-server=http://127.0.0.1:{d}", .{sink.listen_address.getPort()});
    const browser = try startBrowser(alloc, browser_exe, output, profile, proxy_arg);
    defer browser.deinit();
    defer closeChild(browser, browser_class, &report.browser_exit, report);
    report.browser_pid = browser.pid;
    const browser_hwnd = try browser.waitWindow(browser_class, true, 10000);
    report.browser_hwnd = driver.number(browser_hwnd);
    const port = try debuggingPort(alloc, browser, profile);
    var page = try waitPage(browser, browser_hwnd, port, &report.devtools_page_attempts);
    defer page.close();
    try page.navigate();
    try browser.activate(browser_hwnd, browser_class);

    const app = try driver.Child.start(&.{ candidate_path, "--quiet" }, candidate_dir, false);
    defer app.deinit();
    defer closeChild(app, host_class, &report.app_exit, report);
    report.app_pid = app.pid;
    const host = try app.waitWindow(host_class, false, 6000);
    _ = try app.waitWindow(palette_class, false, 6000);
    try app.waitForDispatch(host, host_class);
    var runner = Runner{
        .alloc = alloc,
        .browser_exe = browser_exe,
        .output = output,
        .proxy_arg = proxy_arg,
        .report = report,
        .browser = browser,
        .browser_hwnd = browser_hwnd,
        .app = app,
        .host = host,
        .page = &page,
        .started = sdk.GetTickCount64(),
    };
    defer runner.keyboard.release(browser, browser_hwnd, browser_class) catch |failure| {
        if (report.cleanup_error == null) report.cleanup_error = @errorName(failure);
    };
    const original_pointer = pointer: {
        var point: sdk.POINT = undefined;
        break :pointer if (sdk.GetCursorPos(&point) != 0) point else null;
    };
    defer if (original_pointer) |point| {
        const front = sdk.GetForegroundWindow();
        if (front == browser_hwnd or driver.windowPid(front) == app.pid) _ = sdk.SetCursorPos(point.x, point.y);
    };
    try runner.waitFixture();
    try driver.clearModifiers();
    var progress: [256]u8 = undefined;
    for (selected) |test_case| {
        try report.cases.append(alloc, .{ .name = test_case.name });
        runner.current = &report.cases.items[report.cases.items.len - 1];
        test_case.run(&runner) catch |failure| {
            runner.current.failure = @errorName(failure);
            _ = runner.observe("failure", true) catch null;
            if (runner.progress()) |overlay| {
                if (runner.progressText(overlay)) |summary| {
                    runner.record("progress at failure", .{ .text = summary, .hwnd = driver.number(overlay), .pid = app.pid }) catch {};
                } else |_| {}
            }
            runner.keyboard.release(browser, browser_hwnd, browser_class) catch |cleanup| {
                if (report.cleanup_error == null) report.cleanup_error = @errorName(cleanup);
            };
            std.debug.print("FAIL {s} {s}\n", .{ test_case.name, @errorName(failure) });
            // A failed case may leave a shortcut queued in the owned app. Do not mix its effects with the next case.
            return error.BrowserFixtureCasesFailed;
        };
        runner.current.passed = true;
        try std.fs.File.stdout().writeAll(try std.fmt.bufPrint(&progress, "PASS {s}\n", .{test_case.name}));
    }
}

fn startBrowser(alloc: std.mem.Allocator, browser_exe: []const u8, directory: []const u8, profile: []const u8, proxy_arg: []const u8) !driver.Child {
    const profile_arg = try std.fmt.allocPrint(alloc, "--user-data-dir={s}", .{profile});
    return driver.Child.start(&.{
        browser_exe,                            profile_arg,                             proxy_arg,
        "--proxy-bypass-list=<-loopback>",      "--host-resolver-rules=MAP * ~NOTFOUND", "--remote-debugging-port=0",
        "--remote-debugging-address=127.0.0.1", "--disable-background-networking",       "--disable-sync",
        "--disable-component-update",           "--disable-background-mode",             "--disable-extensions",
        "--disable-quic",                       "--force-renderer-accessibility",        "--no-first-run",
        "--no-default-browser-check",           "about:blank",
    }, directory, true);
}

fn closeChild(child: driver.Child, class: []const u16, exit: *?u32, report: *Report) void {
    defer child.finishJob() catch |failure| {
        if (report.cleanup_error == null) report.cleanup_error = @errorName(failure);
    };
    exit.* = child.closeGracefully(class) catch |failure| {
        if (report.cleanup_error == null) report.cleanup_error = @errorName(failure);
        return;
    };
    if (exit.*.? != 0 and report.cleanup_error == null) report.cleanup_error = "UnexpectedFixtureProcessExit";
}

fn seed(path: []const u8) !void {
    var db = try storage.Store.open(allocator, path);
    defer db.close();
    try db.save(.{
        .preferences = .{ .auto_mode = false, .input_profile_id = manual_a, .reaction_count = 10, .reaction_interval_ms = 1000 },
        .profiles = &.{
            .{ .id = manual_a, .name = "配信者A", .items = &.{
                .{ .id = "fixture-a1", .name = "配信者A 1", .text = a1, .slot = 1 },
                .{ .id = "fixture-a2", .name = "配信者A 2", .text = a2, .slot = 2 },
            } },
            .{ .id = manual_b, .name = "配信者B", .items = &.{
                .{ .id = "fixture-b1", .name = "配信者B 1", .text = b1, .slot = 1 },
                .{ .id = "fixture-b2", .name = "配信者B 2", .text = b2, .slot = 2 },
            } },
        },
        .shared_items = &.{
            .{ .id = "fixture-a", .name = "Alpha", .text = alpha, .slot = 1 },
            .{ .id = "fixture-b", .name = "Beta", .text = beta, .slot = 2 },
        },
    });
}

fn debuggingPort(alloc: std.mem.Allocator, browser: driver.Child, profile: []const u8) !u16 {
    const path = try std.fs.path.join(alloc, &.{ profile, "DevToolsActivePort" });
    const until = sdk.GetTickCount64() + 15000;
    while (browser.running() and sdk.GetTickCount64() < until) {
        if (std.fs.cwd().readFileAlloc(allocator, path, 4096)) |data| {
            defer allocator.free(data);
            if (parsePort(data)) |port| {
                if (try driver.ownsLocalListener(browser, port)) return port;
            } else |_| {}
        } else |failure| switch (failure) {
            error.FileNotFound, error.AccessDenied, error.SharingViolation => {},
            else => return failure,
        }
        sdk.Sleep(25);
    }
    return error.FixtureDebuggingPortUnavailable;
}

fn waitPage(browser: driver.Child, hwnd: sdk.HWND, port: u16, attempts: *u32) !cdp.Page {
    const until = sdk.GetTickCount64() + 10000;
    while (sdk.GetTickCount64() < until) {
        if (!browser.owned(hwnd, browser_class)) return error.FixtureWindowOwnership;
        if (!try driver.ownsLocalListener(browser, port)) return error.FixtureListenerOwnership;
        attempts.* += 1;
        if (cdp.Page.open(allocator, port)) |page| return page else |failure| {
            if (failure != error.DevToolsTabPending) return failure;
        }
        sdk.Sleep(35);
    }
    return error.FixtureDevToolsPageTimeout;
}

fn parsePort(data: []const u8) !u16 {
    var lines = std.mem.tokenizeAny(u8, data, "\r\n");
    const value = lines.next() orelse return error.InvalidDebuggingPort;
    const path = lines.next() orelse return error.InvalidDebuggingPort;
    if (!std.mem.startsWith(u8, path, "/devtools/browser/") or lines.next() != null) return error.InvalidDebuggingPort;
    for (value) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidDebuggingPort;
    const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidDebuggingPort;
    if (port == 0) return error.InvalidDebuggingPort;
    return port;
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Want = union(enum) {
    active: []const u8,
    chat: []const u8,
    event: []const u8,
    enter,
    reactions: usize,

    fn matches(self: Want, state: State) bool {
        return switch (self) {
            .active => |value| equal(state.active, value),
            .chat => |value| equal(state.chat, value),
            .event => |value| state.count(value) > 0,
            .enter => state.count("Enter") > 0,
            .reactions => |value| state.reactions.len >= value,
        };
    }
};

const Runner = struct {
    alloc: std.mem.Allocator,
    browser_exe: []const u8,
    output: []const u8,
    proxy_arg: []const u8,
    report: *Report,
    browser: driver.Child,
    browser_hwnd: sdk.HWND,
    app: driver.Child,
    host: sdk.HWND,
    page: *cdp.Page,
    started: u64,
    keyboard: driver.Keyboard = .{},
    current: *Case = undefined,

    fn record(self: *Runner, label: []const u8, detail: Observation) !void {
        var data = detail;
        data.at_ms = sdk.GetTickCount64() - self.started;
        data.label = label;
        data.foreground = driver.number(sdk.GetForegroundWindow());
        try self.current.observations.append(self.alloc, data);
    }

    fn front(self: *Runner) !void {
        if (!self.app.running()) return error.FixtureAppExited;
        if (!self.browser.owned(self.browser_hwnd, browser_class)) return error.FixtureWindowOwnership;
        var active = sdk.GetForegroundWindow();
        if (active == self.browser_hwnd) return;
        const first_active = active;
        const until = sdk.GetTickCount64() + 200;
        while (driver.windowPid(active) == self.browser.pid and sdk.GetAncestor(active, sdk.GA_ROOTOWNER) == self.browser_hwnd) {
            if (sdk.GetTickCount64() >= until) break;
            sdk.Sleep(10);
            active = sdk.GetForegroundWindow();
            if (active == self.browser_hwnd) {
                try self.browser.foreground(active, browser_class);
                return self.record("owned browser child returned focus to the browser", .{ .hwnd = driver.number(first_active), .pid = self.browser.pid });
            }
        }
        const pid = driver.windowPid(active);
        const title: ?[]const u8 = if (pid == self.browser.pid) driver.text(self.alloc, self.browser, active) catch null else null;
        try self.record("unexpected foreground window", .{ .hwnd = driver.number(active), .pid = pid, .text = title orelse driver.processName(self.alloc, pid) });
        return error.FixtureForegroundChanged;
    }

    fn waitFixture(self: *Runner) !void {
        try self.front();
        try waitDocument(self.alloc, self.browser, self.browser_hwnd, self.page);
    }

    fn selectTab(self: *Runner, page: *cdp.Page) !void {
        try self.front();
        if (!try driver.ownsLocalListener(self.browser, page.port)) return error.FixtureListenerOwnership;
        try page.bringToFront();
        try self.front();
        const until = sdk.GetTickCount64() + 3500;
        while (sdk.GetTickCount64() < until) {
            try self.front();
            const shown = try page.evaluate(self.alloc, "document.visibilityState === 'visible' && location.href === '" ++ cdp.fixture_url ++ "'");
            if (shown == .bool and shown.bool) return;
            sdk.Sleep(30);
        }
        return error.FixtureTabNotSelected;
    }

    fn eval(self: *Runner, expression: []const u8) !std.json.Value {
        if (!self.browser.owned(self.browser_hwnd, browser_class)) return error.FixtureWindowOwnership;
        return self.page.evaluate(self.alloc, expression);
    }

    fn action(self: *Runner, expression: []const u8) !void {
        try self.front();
        try self.fixtureAction(expression);
    }

    fn fixtureAction(self: *Runner, expression: []const u8) !void {
        const value = try self.eval(expression);
        if (value != .bool or !value.bool) return error.BrowserFixtureDocumentChanged;
    }

    fn reset(self: *Runner, field: enum { input, search, comment }, value: []const u8) !void {
        const literal = try std.json.Stringify.valueAlloc(self.alloc, value, .{});
        const command = try std.fmt.allocPrint(self.alloc, "window.fixture.reset('{s}', {s})", .{ @tagName(field), literal });
        try self.action(command);
    }

    fn observe(self: *Runner, label: []const u8, outcome: bool) !State {
        if (!outcome) try self.front();
        const raw = try self.eval("window.fixture.state()");
        const state = try std.json.parseFromValueLeaky(State, self.alloc, raw, .{});
        try self.record(label, .{ .state = state });
        return state;
    }

    fn observeOther(self: *Runner, other: driver.Child, window: sdk.HWND, page: *cdp.Page, label: []const u8) !State {
        if (!other.owned(window, browser_class)) return error.FixtureWindowOwnership;
        const value = try page.evaluate(self.alloc, "window.fixture.state()");
        const state = try std.json.parseFromValueLeaky(State, self.alloc, value, .{});
        try self.record(label, .{ .pid = other.pid, .hwnd = driver.number(window), .state = state });
        return state;
    }

    fn waitState(self: *Runner, want: Want, label: []const u8, timeout: u32) !State {
        const until = sdk.GetTickCount64() + timeout;
        while (sdk.GetTickCount64() < until) {
            const state = try self.observe(label, false);
            if (want.matches(state)) return state;
            sdk.Sleep(30);
        }
        return error.BrowserFixtureStateTimeout;
    }

    fn keys(self: *Runner, keys_requested: []const i16) !void {
        try self.front();
        try self.record("browser keys", .{ .keys = try self.alloc.dupe(i16, keys_requested), .pid = self.browser.pid, .hwnd = driver.number(self.browser_hwnd) });
        try self.keyboard.send(self.browser, self.browser_hwnd, browser_class, keys_requested);
    }

    fn modifiers(self: *Runner, label: []const u8) !Modifiers {
        try self.front();
        const state: Modifiers = .{
            .ctrl = sdk.GetAsyncKeyState(sdk.VK_CONTROL) < 0,
            .alt = sdk.GetAsyncKeyState(sdk.VK_MENU) < 0,
            .left_ctrl = sdk.GetAsyncKeyState(sdk.VK_LCONTROL) < 0,
            .left_alt = sdk.GetAsyncKeyState(sdk.VK_LMENU) < 0,
        };
        try self.record(label, .{ .modifiers = state });
        return state;
    }

    fn chord(self: *Runner, key: i16) !void {
        try self.chordWith(key, sdk.VK_LMENU);
    }

    fn chordWith(self: *Runner, key: i16, modifier: i16) !void {
        try self.keys(&.{ sdk.VK_LCONTROL, modifier, key, -key, -modifier, -sdk.VK_LCONTROL });
    }

    fn returnFromOwnedUi(self: *Runner) !void {
        const foreground = sdk.GetForegroundWindow();
        if (foreground != self.browser_hwnd and driver.windowPid(foreground) != self.app.pid) return error.FixtureForegroundChanged;
        try self.browser.activate(self.browser_hwnd, browser_class);
        try self.front();
    }

    fn foregroundPalette(self: *Runner, palette: sdk.HWND) !void {
        if (sdk.GetForegroundWindow() != palette) {
            try self.front();
            try self.record("isolated palette activation fallback", .{ .pid = self.app.pid, .hwnd = driver.number(palette) });
            try self.app.activate(palette, palette_class);
        }
        try self.app.foreground(palette, palette_class);
    }

    fn closePalette(self: *Runner, palette: sdk.HWND) !void {
        try self.app.post(palette, palette_class, sdk.WM_CLOSE, 0, 0);
        const until = sdk.GetTickCount64() + 1500;
        while (sdk.IsWindowVisible(palette) != 0) {
            if (sdk.GetTickCount64() >= until) return error.PaletteDidNotClose;
            sdk.Sleep(20);
        }
        try self.returnFromOwnedUi();
    }

    fn menu(self: *Runner, position: u8) !void {
        try self.chord('Q');
        const palette = self.app.waitWindow(palette_class, true, 1200) catch retry: {
            try self.front();
            try self.record("isolated host menu-open fallback", .{ .pid = self.app.pid, .hwnd = driver.number(self.host) });
            try self.app.post(self.host, host_class, sdk.WM_APP + 2, 0, sdk.WM_LBUTTONDBLCLK);
            break :retry try self.app.waitWindow(palette_class, true, 3500);
        };
        try self.foregroundPalette(palette);
        const support = sdk.GetDlgItem(palette, 106);
        if (driver.windowPid(support) != self.app.pid or sdk.GetAncestor(support, sdk.GA_ROOT) != palette) return error.FixtureWindowOwnership;
        try self.app.post(support, driver.wide("Button"), sdk.BM_CLICK, 0, 0);
        const until = sdk.GetTickCount64() + 4500;
        while (!driver.supportMenuTracked(self.app, palette, palette_class)) {
            if (sdk.GetTickCount64() >= until) return error.FixtureMenuNotOwned;
            sdk.Sleep(20);
        }
        var navigation: [4 + 2 * 12]i16 = undefined;
        const length = 4 + @as(usize, position) * 2;
        if (length > navigation.len) return error.FixtureMenuPosition;
        navigation[0..2].* = .{ sdk.VK_HOME, -sdk.VK_HOME };
        for (0..position) |i| navigation[2 + i * 2 ..][0..2].* = .{ sdk.VK_DOWN, -sdk.VK_DOWN };
        navigation[length - 2 ..][0..2].* = .{ sdk.VK_RETURN, -sdk.VK_RETURN };
        try self.record("verified support menu keys", .{ .pid = self.app.pid, .hwnd = driver.number(palette), .keys = try self.alloc.dupe(i16, navigation[0..length]) });
        if (!driver.supportMenuTracked(self.app, palette, palette_class)) return error.FixtureMenuNotOwned;
        try self.keyboard.send(self.app, palette, palette_class, navigation[0..length]);
    }

    fn progress(self: *Runner) sdk.HWND {
        return self.app.window(overlay_class, true);
    }

    fn waitStatusTip(self: *Runner, expected: []const u8) !void {
        const deadline = sdk.GetTickCount64() + 3500;
        var last: ?[]const u8 = null;
        while (sdk.GetTickCount64() < deadline) {
            try self.front();
            if (self.app.window(driver.wide("Static"), true)) |tip| {
                const value = try driver.text(self.alloc, self.app, tip);
                last = value;
                if (std.mem.startsWith(u8, value, expected)) {
                    try self.record("owned status tip", .{ .text = value, .pid = self.app.pid, .hwnd = driver.number(tip) });
                    return;
                }
            }
            sdk.Sleep(30);
        }
        try self.record("status tip timeout", .{ .text = last, .hwnd = driver.number(self.app.window(palette_class, true)) });
        return error.FixtureStatusTipTimeout;
    }

    fn supportDocument(self: *Runner, position: u8, label: []const u8) ![]const u8 {
        try self.menu(position);
        return self.readSupportDocument(label);
    }

    fn expectPageDiagnostic(self: *Runner, label: []const u8, expected: PageDiagnostic) !void {
        try self.waitUntilEditable();
        try self.app.post(self.host, host_class, sdk.WM_COMMAND, diagnostics_command, 0);
        const document = try self.readSupportDocument(label);
        const lines = try std.fmt.allocPrint(self.alloc, "ブラウザー {s}\r\n直近の操作 {s}\r\n結果 {s}\r\n処理段階 {s}\r\n補助プロセスの要求 {s}\r\n", .{
            (try fixture_browser.Browser.fromPath(self.browser_exe)).label(), expected.action, expected.state, expected.stage, expected.worker,
        });
        try require(std.mem.indexOf(u8, document, lines) != null);
    }

    fn readSupportDocument(self: *Runner, label: []const u8) ![]const u8 {
        const dialog = try self.app.waitWindow(dialog_class, true, 4000);
        errdefer self.app.post(dialog, dialog_class, sdk.WM_CLOSE, 0, 0) catch {};
        const activation_deadline = sdk.GetTickCount64() + 750;
        while (sdk.GetForegroundWindow() != dialog and self.app.owned(dialog, dialog_class) and sdk.GetTickCount64() < activation_deadline)
            sdk.Sleep(15);
        if (sdk.GetForegroundWindow() != dialog) {
            const foreground = sdk.GetForegroundWindow();
            try self.record("support dialog did not take the foreground", .{ .hwnd = driver.number(foreground), .pid = driver.windowPid(foreground) });
            if (foreground != self.browser_hwnd and driver.windowPid(foreground) != self.app.pid) return error.FixtureForegroundChanged;
            try self.app.activate(dialog, dialog_class);
        }
        try self.app.foreground(dialog, dialog_class);
        const document = try driver.text(self.alloc, self.app, sdk.FindWindowExW(dialog, null, driver.wide("Edit"), null));
        try self.record(label, .{ .text = document, .pid = self.app.pid, .hwnd = driver.number(dialog) });
        try self.returnFromOwnedUi();
        try self.closeOwnedDialog(dialog, dialog_class, .hide);
        return document;
    }

    fn closeOwnedDialog(self: *Runner, dialog: sdk.HWND, class: []const u16, closure: enum { hide, destroy }) !void {
        try self.app.post(dialog, class, sdk.WM_CLOSE, 0, 0);
        const until = sdk.GetTickCount64() + 2000;
        while (self.app.owned(dialog, class) and (closure == .destroy or sdk.IsWindowVisible(dialog) != 0)) {
            if (sdk.GetTickCount64() >= until) return error.FixtureDialogDidNotClose;
            sdk.Sleep(20);
        }
        try self.returnFromOwnedUi();
    }

    fn progressText(self: *Runner, overlay: sdk.HWND) ![]const u8 {
        if (!self.app.owned(overlay, overlay_class)) return error.FixtureWindowOwnership;
        const title = sdk.FindWindowExW(overlay, null, driver.wide("Static"), null);
        if (title == null) return error.FixtureProgressSummary;
        return driver.text(self.alloc, self.app, sdk.FindWindowExW(overlay, title, driver.wide("Static"), null));
    }

    fn waitProgress(self: *Runner, contains: []const u8, label: []const u8, timeout: u32) ![]const u8 {
        const until = sdk.GetTickCount64() + timeout;
        while (sdk.GetTickCount64() < until) {
            if (self.progress()) |hwnd| {
                const summary = try self.progressText(hwnd);
                if (summary.len != 0 and std.mem.indexOf(u8, summary, contains) != null) {
                    try self.front();
                    try self.record(label, .{ .text = summary, .hwnd = driver.number(hwnd), .pid = self.app.pid });
                    return summary;
                }
            }
            sdk.Sleep(30);
        }
        if (self.progress()) |hwnd| try self.record("last progress", .{ .text = try self.progressText(hwnd), .hwnd = driver.number(hwnd), .pid = self.app.pid });
        return error.FixtureProgressTimeout;
    }

    fn waitPriorReaction(self: *Runner) !void {
        const deadline = sdk.GetTickCount64() + 11000;
        while (sdk.GetTickCount64() < deadline) {
            try self.front();
            const overlay = self.app.window(overlay_class, false) orelse return;
            const summary = try self.progressText(overlay);
            if (std.mem.indexOf(u8, summary, "操作済み") == null) return;
            if (std.mem.indexOf(u8, summary, "YouTube側で受理された回数は未確認です。") != null) {
                try self.record("prior reaction reached a terminal state before event reset", .{ .text = summary, .hwnd = driver.number(overlay), .pid = self.app.pid });
                return;
            }
            sdk.Sleep(30);
        }
        return error.PriorReactionDidNotFinish;
    }

    fn editAllowed(self: *Runner) !bool {
        if (!self.app.owned(self.host, host_class)) return error.FixtureWindowOwnership;
        var result: sdk.DWORD_PTR = 0;
        if (sdk.SendMessageTimeoutW(self.host, edit_allowed_message, 0, 0, sdk.SMTO_ABORTIFHUNG, 1000, &result) == 0 or result > 1)
            return error.FixtureOperationStateUnavailable;
        return result == 1;
    }

    fn waitUntilEditable(self: *Runner) !void {
        const deadline = sdk.GetTickCount64() + 5000;
        while (!(try self.editAllowed())) {
            if (sdk.GetTickCount64() >= deadline) return error.FixtureOperationDidNotFinish;
            sdk.Sleep(20);
        }
        try self.front();
    }

    fn recordRestartFailure(self: *Runner) !void {
        try self.front();
        try self.app.post(self.host, host_class, sdk.WM_COMMAND, diagnostics_command, 0);
        _ = try self.readSupportDocument("replacement diagnostics after remapped shortcut failure");
    }

    fn paletteReactionButton(self: *Runner, palette: sdk.HWND) !sdk.HWND {
        if (!self.app.owned(palette, palette_class) or sdk.IsWindowVisible(palette) == 0) return error.FixtureWindowOwnership;
        const start = sdk.GetDlgItem(palette, reaction_start_id) orelse return error.FixtureReactionButtonMissing;
        if (driver.windowPid(start) != self.app.pid or sdk.GetParent(start) != palette or sdk.IsWindowEnabled(start) == 0)
            return error.FixtureWindowOwnership;
        return start;
    }

    fn pointToButton(self: *Runner, name: []const u8) !void {
        const deadline = sdk.GetTickCount64() + 5000;
        var reported_hit = false;
        while (true) {
            const point = try self.visibleElementCenter(name);
            driver.placePointer(self.browser, self.browser_hwnd, browser_class, point) catch |failure| {
                if (failure != error.FixturePointerTarget or self.progress() == null or sdk.GetTickCount64() >= deadline)
                    return failure;
                if (!reported_hit) {
                    const hit = sdk.GetAncestor(sdk.WindowFromPhysicalPoint(point), sdk.GA_ROOT);
                    try self.record("pointer hit while the reaction overlay is visible", .{
                        .hwnd = driver.number(hit),
                        .pid = driver.windowPid(hit),
                        .text = if (hit == self.progress()) "reaction overlay" else "other target",
                    });
                    reported_hit = true;
                }
                // An interactive overlay can temporarily occupy the page element's position.
                sdk.Sleep(50);
                continue;
            };
            try self.record("verified browser pointer", .{
                .hwnd = driver.number(self.browser_hwnd),
                .pid = self.browser.pid,
                .text = try std.fmt.allocPrint(self.alloc, "{s} at {d},{d}", .{ name, point.x, point.y }),
            });
            return;
        }
    }

    fn visibleElementCenter(self: *Runner, name: []const u8) !sdk.POINT {
        return (try self.waitFixtureElement(name, true)).?;
    }

    fn waitFixtureElement(self: *Runner, name: []const u8, visible: bool) !?sdk.POINT {
        try self.front();
        try self.record(if (visible) "wait for visible fixture element in UI Automation" else "wait for hidden fixture element in UI Automation", .{ .text = name });
        var client = try uia.Client.init();
        defer client.deinit();
        const root = try client.root(driver.number(self.browser_hwnd));
        defer automation.release(root);
        const cond = try automation.textCondition(client.automation, automation.sdk.UIA_NamePropertyId, name);
        defer automation.release(cond);
        // Chromium updates the UIA tree asynchronously after DOM visibility changes.
        const until = sdk.GetTickCount64() + 1500;
        while (sdk.GetTickCount64() < until) {
            try self.front();
            var center: ?sdk.POINT = null;
            if (try automation.objectOrNull(automation.Element, "FindFirst", root, .{ automation.sdk.TreeScope_Descendants, cond })) |element| {
                defer automation.release(element);
                const bounds = try automation.get(automation.sdk.RECT, "get_CurrentBoundingRectangle", element, .{});
                if (bounds.right > bounds.left and bounds.bottom > bounds.top) {
                    center = .{ .x = @divTrunc(bounds.left + bounds.right, 2), .y = @divTrunc(bounds.top + bounds.bottom, 2) };
                }
            }
            if ((center != null) == visible) return center;
            sdk.Sleep(30);
        }
        return if (visible) error.FixtureElementNotVisibleToAutomation else error.FixtureElementStillVisibleToAutomation;
    }
};

fn waitDocument(alloc: std.mem.Allocator, browser: driver.Child, hwnd: sdk.HWND, page: *cdp.Page) !void {
    const until = sdk.GetTickCount64() + 6000;
    while (sdk.GetTickCount64() < until) {
        try browser.foreground(hwnd, browser_class);
        const value = try page.evaluate(alloc, "location.href === '" ++ cdp.fixture_url ++ "' && window.fixture?.identity === 'chatpalette-zig-offline-1'");
        if (value == .bool and value.bool) return;
        sdk.Sleep(30);
    }
    return error.BrowserFixtureDocumentMissing;
}

fn require(ok: bool) !void {
    if (!ok) return error.FixtureObservationMismatch;
}

fn focus(self: *Runner) !void {
    try self.reset(.search, "");
    try self.chord('F');
    const state = try self.waitState(.{ .active = "input" }, "chat focused", 3500);
    try require(equal(state.search, "KEEP") and state.chat.len == 0);
    try self.waitStatusTip("チャット欄へ移動しました。");
    try self.expectPageDiagnostic("diagnostic after a successful focus", .{
        .action = "chat_focus",
        .state = "focused",
        .stage = "フォーカス",
        .worker = "chat_focus",
    });
}

fn releaseOrder(self: *Runner) !void {
    try self.reset(.input, "");
    try self.keys(&.{ sdk.VK_LCONTROL, sdk.VK_LMENU, '3', '4' });
    sdk.Sleep(180);
    try require((try self.observe("while held", false)).chat.len == 0);
    try self.keys(&.{-'4'});
    _ = try self.waitState(.{ .chat = beta }, "slot four first", 3500);
    try self.keys(&.{ -'3', -sdk.VK_LMENU, -sdk.VK_LCONTROL });
    const state = try self.waitState(.{ .chat = beta ++ alpha }, "slot three follows", 3500);
    try require(state.count("Enter") == 0);
}

fn longPress(self: *Runner) !void {
    try self.reset(.input, "");
    try self.keys(&.{ sdk.VK_LCONTROL, sdk.VK_LMENU, '3' });
    for (0..5) |_| {
        try self.keys(&.{'3'});
        sdk.Sleep(55);
    }
    try require((try self.observe("repeat before release", false)).chat.len == 0);
    try self.keys(&.{ -'3', -sdk.VK_LMENU, -sdk.VK_LCONTROL });
    _ = try self.waitState(.{ .chat = alpha }, "one insertion", 3500);
    sdk.Sleep(250);
    const state = try self.observe("no delayed repeat", false);
    try require(equal(state.chat, alpha) and state.count("Enter") == 0);
}

fn explicitSend(self: *Runner) !void {
    try self.reset(.input, "TO_SEND");
    try self.keys(&.{ sdk.VK_LCONTROL, sdk.VK_LMENU, 'E' });
    sdk.Sleep(180);
    try require((try self.observe("E still held", false)).count("Enter") == 0);
    try require((try self.modifiers("Ctrl and Alt held before E release")).all(true));
    try self.keys(&.{-'E'});
    _ = try self.waitState(.enter, "explicit Enter with Ctrl and Alt physically held", 3500);
    sdk.Sleep(200);
    const state = try self.observe("Enter count and target", false);
    try require(state.count("Enter") == 1);
    for (state.events) |entry| {
        if (!equal(entry.type, "Enter")) continue;
        try require(equal(entry.id, "input") and equal(entry.value orelse "", "TO_SEND") and
            entry.ctrl == false and entry.alt == false and entry.shift == false and entry.meta == false);
    }
    try require((try self.modifiers("Ctrl and Alt restored after Enter")).all(true));
    try self.keys(&.{ -sdk.VK_LMENU, -sdk.VK_LCONTROL });
    sdk.Sleep(120);
    try require((try self.modifiers("Ctrl and Alt released by fixture")).all(false));
    try require((try self.observe("no second Enter after modifier release", false)).count("Enter") == 1);
    try self.waitStatusTip("チャット欄へEnterキーを送りました（送信受理は未確認）。");
    try self.expectPageDiagnostic("diagnostic after sending one Enter key", .{
        .action = "chat_send",
        .state = "enter_sent",
        .stage = "Enterキー送信",
        .worker = "chat_enter",
    });
}

fn rejectSearch(self: *Runner) !void {
    try self.reset(.search, "KEEP_CHAT");
    try self.chord('E');
    sdk.Sleep(3000);
    const state = try self.observe("search remained unchanged", false);
    try require(equal(state.active, "search") and equal(state.search, "KEEP") and equal(state.chat, "KEEP_CHAT") and state.count("Enter") == 0);
    try self.expectPageDiagnostic("diagnostic after rejecting Enter in search", .{
        .action = "chat_send",
        .state = "wrong_input",
        .stage = "送信前の確認",
        .worker = "verify_input",
    });
}

fn clearChat(self: *Runner) !void {
    try self.reset(.search, "CLEAR_ME");
    try self.chord('W');
    const state = try self.waitState(.{ .chat = "" }, "clear only identified chat", 3500);
    try require(equal(state.active, "input") and equal(state.search, "KEEP") and state.count("Enter") == 0);
    try self.waitStatusTip("クリアキーを送りました（内容は未取得）。");
    try self.expectPageDiagnostic("diagnostic after sending the clear keys", .{
        .action = "chat_clear",
        .state = "cleared",
        .stage = "クリアキー送信",
        .worker = "chat_clear",
    });

    try self.reset(.comment, "KEEP_CHAT");
    try self.chord('E');
    try self.waitStatusTip("現在の入力欄を操作できません。");
    const rejected = try self.observe("explicit Enter was rejected in the comment editor", false);
    try require(equal(rejected.active, "comment") and equal(rejected.comment, "KEEP_COMMENT") and
        equal(rejected.chat, "KEEP_CHAT") and equal(rejected.search, "KEEP") and rejected.noDelivery());
    try self.waitUntilEditable();

    for ([_]struct { setup: []const u8, message: []const u8, result: []const u8, second: []const u8, redirect: bool = false }{
        .{ .setup = "window.fixture.setChatCount(0)", .message = "入力可能なチャット欄が見つかりません。", .result = "chat_missing", .second = "" },
        .{ .setup = "window.fixture.setChatCount(2)", .message = "チャット入力欄が複数あります。", .result = "chat_ambiguous", .second = "KEEP_SECOND_CHAT" },
        .{
            .setup = "window.fixture.armFocusFault('search')",
            .message = "チャット欄へのフォーカス移動を確認できませんでした。",
            .result = "focus_failed",
            .second = "",
            .redirect = true,
        },
    }) |scenario| {
        try self.reset(if (scenario.redirect) .search else .comment, "KEEP_CHAT");
        try self.action(scenario.setup);
        if (equal(scenario.result, "chat_missing")) {
            _ = try self.waitFixtureElement("Chat", false);
            try self.record("hidden chat is no longer visible to UI Automation before clear", .{});
        }
        if (scenario.second.len != 0) {
            _ = try self.visibleElementCenter("Type a message");
            try self.record("second chat is visible to UI Automation before clear", .{});
        }
        try self.chord('W');
        self.waitStatusTip(scenario.message) catch |failure| {
            _ = self.supportDocument(8, "diagnostic after unexpected clear refusal") catch {};
            return failure;
        };
        const observed = try self.observe("clear refused without touching any field", false);
        try require(equal(observed.active, if (scenario.redirect) "search" else "comment") and equal(observed.chat, "KEEP_CHAT") and equal(observed.search, "KEEP") and
            equal(observed.comment, "KEEP_COMMENT") and equal(observed.second_chat orelse "", scenario.second) and observed.noDelivery());
        if (scenario.redirect) try require(observed.count("focus_redirected") == 1);
        try self.expectPageDiagnostic("diagnostic preserves rejected clear at the focus stage", .{
            .action = "chat_clear",
            .state = scenario.result,
            .stage = "フォーカス",
            .worker = "chat_focus",
        });
    }
    try self.reset(.search, "CLEAR_AFTER_RECOVERY");
    try self.chord('W');
    const recovered = try self.waitState(.{ .chat = "" }, "fresh clear succeeds after rejected attempts", 3500);
    try require(equal(recovered.active, "input") and equal(recovered.search, "KEEP") and equal(recovered.comment, "KEEP_COMMENT") and recovered.noEnter());
    try self.waitUntilEditable();
    try pageKeysDuringShortcutSettings(self);
    try pageKeysDuringLibraryEdit(self);
}

fn pageKeysDuringShortcutSettings(self: *Runner) !void {
    try self.pointToButton("Search");
    try self.reset(.search, "KEEP_WHILE_EDITING_KEYS");
    try self.app.post(self.host, host_class, sdk.WM_COMMAND, shortcut_settings_command, 0);
    const dialog = try self.app.waitWindow(dialog_class, true, 3500);
    errdefer self.app.post(dialog, dialog_class, sdk.WM_CLOSE, 0, 0) catch {};
    try self.app.waitForDispatch(dialog, dialog_class);
    const title = try driver.text(self.alloc, self.app, dialog);
    try require(equal(title, "ショートカットを管理") and sdk.IsWindowEnabled(self.host) == 0 and !try self.editAllowed());
    try self.record("owned shortcut editor has made the app modal", .{ .text = title, .pid = self.app.pid, .hwnd = driver.number(dialog) });
    try self.returnFromOwnedUi();
    for ([_]i16{ 'F', 'W', 'R' }) |key| try self.chord(key);
    const blocked = try self.waitState(.{ .event = "Control" }, "page keys while shortcut settings stay open", 3000);
    try require(self.app.owned(dialog, dialog_class) and sdk.IsWindowVisible(dialog) != 0 and !try self.editAllowed());
    try self.closeOwnedDialog(dialog, dialog_class, .destroy);
    try self.waitUntilEditable();
    const closed = try self.observe("page keys did not target the browser after settings closed", false);
    for ([_]State{ blocked, closed }) |observed| {
        try require(equal(observed.active, "search") and equal(observed.chat, "KEEP_WHILE_EDITING_KEYS") and
            equal(observed.search, "KEEP") and observed.noDelivery() and observed.count("launcher_hover") == 0);
    }
    try self.chord('W');
    _ = try self.waitState(.{ .chat = "" }, "new page key works after editor closes", 3500);
    try self.waitUntilEditable();
}

fn pageKeysDuringLibraryEdit(self: *Runner) !void {
    try self.pointToButton("Search");
    try self.reset(.search, "KEEP_WHILE_EDITING_LIBRARY");
    try self.app.post(self.host, host_class, sdk.WM_COMMAND, open_management_command, 0);
    const manager = try self.app.waitWindow(manager_class, true, 3500);
    errdefer self.app.post(manager, manager_class, sdk.WM_CLOSE, 0, 0) catch {};
    const add = sdk.GetDlgItem(manager, add_library_item_id);
    if (sdk.GetAncestor(add, sdk.GA_ROOT) != manager or sdk.IsWindowEnabled(add) == 0) return error.FixtureWindowOwnership;
    try self.app.post(add, driver.wide("Button"), sdk.BM_CLICK, 0, 0);
    const editor = try self.app.waitWindow(library_editor_class, true, 3500);
    errdefer self.app.post(editor, library_editor_class, sdk.WM_CLOSE, 0, 0) catch {};
    try self.app.waitForDispatch(editor, library_editor_class);
    const title = try driver.text(self.alloc, self.app, editor);
    try require(equal(title, "弾幕を追加") and sdk.GetWindow(editor, sdk.GW_OWNER) == manager and sdk.IsWindowEnabled(manager) == 0);
    try self.record("owned library editor has disabled its parent", .{ .text = title, .hwnd = driver.number(editor), .pid = self.app.pid });
    try self.returnFromOwnedUi();
    for ([_]i16{ 'F', 'W', 'R' }) |key| try self.chord(key);
    const blocked = try self.waitState(.{ .event = "Control" }, "page keys while the library editor stays open", 3000);
    try require(self.app.owned(editor, library_editor_class) and sdk.IsWindowVisible(editor) != 0);
    try self.closeOwnedDialog(editor, library_editor_class, .destroy);
    try self.app.post(manager, manager_class, sdk.WM_CLOSE, 0, 0);
    const until = sdk.GetTickCount64() + 2000;
    while (sdk.IsWindowVisible(manager) != 0) {
        if (sdk.GetTickCount64() >= until) return error.FixtureManagementDidNotHide;
        sdk.Sleep(20);
    }
    try self.waitUntilEditable();
    const closed = try self.observe("page keys did not take effect after library editing", false);
    for ([_]State{ blocked, closed }) |observed| {
        try require(equal(observed.active, "search") and equal(observed.chat, "KEEP_WHILE_EDITING_LIBRARY") and
            equal(observed.search, "KEEP") and observed.noDelivery() and observed.count("launcher_hover") == 0);
    }
    try self.chord('W');
    _ = try self.waitState(.{ .chat = "" }, "fresh clear works after closing the library editor", 3500);
    try self.waitUntilEditable();
}

fn probeBrowserIme(self: *Runner, prefix: []const u8, label: []const u8) !bool {
    try self.action("window.fixture.clearEvents()");
    try self.keys(&.{ 'A', -'A' });
    _ = try self.waitState(.{ .event = "input" }, label, 2000);
    const observed = try self.observe(label, false);
    try require(equal(observed.active, "input") and equal(observed.search, "KEEP") and observed.noEnter());
    for (observed.events) |event| {
        if (!equal(event.type, "compositionupdate")) continue;
        if (equal(event.id, "input") and (event.value orelse "").len != 0) return true;
    }
    const expected = try std.fmt.allocPrint(self.alloc, "{s}a", .{prefix});
    if (!std.ascii.eqlIgnoreCase(observed.chat, expected) or observed.count("compositionstart") != 0)
        return error.UnexpectedBrowserImeInput;
    return false;
}

fn cancelBrowserComposition(self: *Runner) !void {
    try self.keys(&.{ sdk.VK_ESCAPE, -sdk.VK_ESCAPE });
    _ = try self.waitState(.{ .event = "compositionend" }, "IME composition cancelled in owned chat", 2000);
}

fn restoreBrowserIme(self: *Runner, original: bool) !void {
    try self.reset(.input, "");
    const restore_key: i16 = if (original) sdk.VK_IME_ON else sdk.VK_IME_OFF;
    try self.keys(&.{ restore_key, -restore_key });
    if (try probeBrowserIme(self, "", "original browser IME mode restored") != original)
        return error.BrowserImeModeNotRestored;
    if (original) try cancelBrowserComposition(self);
    try self.reset(.input, "");
}

fn browserIme(self: *Runner) !void {
    try self.front();
    const thread = sdk.GetWindowThreadProcessId(self.browser_hwnd, null);
    const layout = sdk.GetKeyboardLayout(thread) orelse return error.BrowserKeyboardLayoutUnavailable;
    try self.record("owned browser keyboard layout", .{
        .pid = self.browser.pid,
        .hwnd = driver.number(self.browser_hwnd),
        .text = try std.fmt.allocPrint(self.alloc, "0x{x}", .{@intFromPtr(layout)}),
    });
    if (@as(u16, @truncate(@intFromPtr(layout))) != 0x0411) return error.JapaneseBrowserKeyboardLayoutRequired;
    try self.reset(.input, "");
    const original = try probeBrowserIme(self, "", "original browser IME mode");
    defer restoreBrowserIme(self, original) catch |failure| {
        if (self.report.cleanup_error == null) self.report.cleanup_error = @errorName(failure);
    };
    if (original) try cancelBrowserComposition(self);

    try self.reset(.input, "");
    try self.keys(&.{ sdk.VK_IME_ON, -sdk.VK_IME_ON });
    if (!try probeBrowserIme(self, "", "Japanese IME composed in the chat input"))
        return error.BrowserJapaneseImeDidNotCompose;
    try cancelBrowserComposition(self);
    try self.reset(.input, "");
    try self.chord('3');
    _ = try self.waitState(.{ .chat = alpha }, "literal from the shared slot reached chat", 4500);
    try self.waitUntilEditable();
    const inserted = try self.observe("literal unchanged and no Enter before the IME probe", false);
    try require(equal(inserted.active, "input") and equal(inserted.chat, alpha) and equal(inserted.search, "KEEP") and
        inserted.noEnter() and inserted.count("input") != 0 and inserted.count("compositionstart") == 0);
    if (try probeBrowserIme(self, alpha, "direct typing after insertion shows the IME is closed"))
        return error.BrowserJapaneseImeWasStillOpen;
}

fn stopKeys(self: *Runner) !void {
    try self.reset(.input, "");
    {
        try self.front();
        var paused = try driver.Paused.init(self.app);
        defer paused.unpause();
        try self.record("owned pipe worker paused", .{ .pid = paused.pid });
        try self.chord('F');
        sdk.Sleep(100);
        try self.chord('3');
        try self.chord('E');
        try self.keys(&.{sdk.VK_ESCAPE});
        sdk.Sleep(100);
    }
    sdk.Sleep(600);
    const state = try self.observe("stopped pending input and Enter", false);
    try require(state.chat.len == 0 and state.count("Enter") == 0 and state.count("Escape") == 0);
    try self.keys(&.{-sdk.VK_ESCAPE});
    try self.chord('4');
    _ = try self.waitState(.{ .chat = beta }, "new shortcut accepted", 3500);
    sdk.Sleep(500);
}

fn faultDuringFocus(self: *Runner, fault: enum { video, chat }) !State {
    try self.reset(.search, "SOURCE_CHAT");
    defer self.fixtureAction("window.fixture.restore()") catch |failure| {
        if (self.report.cleanup_error == null) self.report.cleanup_error = @errorName(failure);
    };
    try self.action(switch (fault) {
        .video => "window.fixture.armFocusFault('video')",
        .chat => "window.fixture.armFocusFault('chat')",
    });
    {
        try self.front();
        var paused = try driver.Paused.init(self.app);
        defer paused.unpause();
        try self.record("owned worker paused while focus, input, and Enter are queued", .{ .pid = paused.pid });
        try self.chord('F');
        try self.chord('3');
        try self.chord('E');
        sdk.Sleep(125);
        const before = try self.observe("before worker resumes", false);
        try require(equal(before.active, "search") and equal(before.video, original_video) and equal(before.chat, "SOURCE_CHAT") and before.noDelivery());
    }
    const marker = switch (fault) {
        .video => "video_replaced",
        .chat => "chat_replaced",
    };
    const changed = try self.waitState(.{ .event = marker }, "DOM changes target inside candidate's chat-focus action", 5000);
    try require(changed.count(marker) == 1 and changed.noDelivery());
    // Keep the changed target through the outstanding browser request's deadline.
    sdk.Sleep(context_completion_ms);
    const after = try self.observe("after the queued actions had time to run", false);
    try require(after.count(marker) == 1 and after.noDelivery() and equal(after.search, "KEEP"));
    return after;
}

fn changeVideo(self: *Runner) !void {
    const after = try faultDuringFocus(self, .video);
    try require(equal(after.video, changed_video) and equal(after.chat, "SOURCE_CHAT"));
}

fn changeChat(self: *Runner) !void {
    const after = try faultDuringFocus(self, .chat);
    try require(equal(after.video, original_video) and equal(after.active, "input") and
        equal(after.chat, "REPLACEMENT") and equal(after.retired_chat orelse "", "SOURCE_CHAT"));
}

fn changeWindow(self: *Runner) !void {
    try self.front();
    const profile = try std.fs.path.join(self.alloc, &.{ self.output, "profile-secondary" });
    try std.fs.cwd().makeDir(profile);
    const other = try startBrowser(self.alloc, self.browser_exe, self.output, profile, self.proxy_arg);
    defer other.deinit();
    defer closeChild(other, browser_class, &self.report.second_browser_exit, self.report);
    defer if (other.owned(sdk.GetForegroundWindow(), browser_class)) {
        self.browser.activate(self.browser_hwnd, browser_class) catch |failure| {
            if (self.report.cleanup_error == null) self.report.cleanup_error = @errorName(failure);
        };
    };
    const window = try other.waitWindow(browser_class, true, 10000);
    try require(other.pid != self.browser.pid and window != self.browser_hwnd);
    const port = try debuggingPort(self.alloc, other, profile);
    var attempts: u32 = 0;
    var other_page = try waitPage(other, window, port, &attempts);
    defer other_page.close();
    errdefer _ = self.observeOther(other, window, &other_page, "second window at failure") catch null;
    try other_page.navigate();
    try other.activate(window, browser_class);
    try waitDocument(self.alloc, other, window, &other_page);
    const reset = try other_page.evaluate(self.alloc, "window.fixture.reset('input', 'DESTINATION_CHAT')");
    if (reset != .bool or !reset.bool) return error.BrowserFixtureDocumentChanged;
    try focusSecondaryChat(self, other, window, &other_page);
    try self.record("verified second isolated browser window", .{ .pid = other.pid, .hwnd = driver.number(window) });

    try self.browser.activate(self.browser_hwnd, browser_class);
    try self.reset(.input, "SOURCE_CHAT");
    {
        try self.front();
        var paused = try driver.Paused.init(self.app);
        defer paused.unpause();
        try self.record("owned worker paused before original-window requests", .{ .pid = paused.pid });
        try self.chord('3');
        try self.chord('E');
        sdk.Sleep(125);
        const before = try self.observe("before the other window takes foreground", false);
        try require(before.noDelivery() and equal(before.chat, "SOURCE_CHAT") and equal(before.video, original_video));
        try self.front();
        try other.activate(window, browser_class);
        try other.foreground(window, browser_class);
        try self.record("second browser foreground before worker resumes", .{ .pid = other.pid, .hwnd = driver.number(window) });
    }
    sdk.Sleep(context_completion_ms);
    try other.foreground(window, browser_class);
    const source = try self.observe("original window in background after worker resumes", true);
    const destination = try self.observeOther(other, window, &other_page, "second window after worker resumes");
    try other.foreground(window, browser_class);
    try require(source.noDelivery() and equal(source.chat, "SOURCE_CHAT") and equal(source.search, "KEEP"));
    try require(destination.noDelivery() and equal(destination.chat, "DESTINATION_CHAT") and equal(destination.search, "KEEP"));
    try rejectOldKeyRelease(self, other, window, &other_page);
    try rejectReactionAfterForegroundChange(self, other, window, &other_page);
    // Restore the original foreground before closing the secondary window, so Windows does not choose the next foreground.
    try self.browser.activate(self.browser_hwnd, browser_class);
    try other.post(window, browser_class, sdk.WM_CLOSE, 0, 0);
    if (sdk.WaitForSingleObject(other.handle, 6000) != sdk.WAIT_OBJECT_0) return error.SecondBrowserDidNotExit;
    try self.front();
}

fn rejectOldKeyRelease(self: *Runner, other: driver.Child, window: sdk.HWND, other_page: *cdp.Page) !void {
    try self.browser.activate(self.browser_hwnd, browser_class);
    try self.waitUntilEditable();
    try self.reset(.input, "SOURCE_CHAT");
    {
        var paused = try driver.Paused.init(self.app);
        defer paused.unpause();
        try self.chord('3');
        const started = sdk.GetTickCount64() + 1250;
        while (try self.editAllowed()) {
            try self.front();
            if (sdk.GetTickCount64() >= started) return error.FixtureOperationDidNotStart;
            sdk.Sleep(15);
        }
        // W owns its release in the original window even if the modifiers go up first.
        try self.keys(&.{ sdk.VK_LCONTROL, sdk.VK_LMENU, 'W', -sdk.VK_LMENU, -sdk.VK_LCONTROL });
        try other.activate(window, browser_class);
        try focusSecondaryChat(self, other, window, other_page);
        const keys: []const i16 = &.{ sdk.VK_LCONTROL, sdk.VK_LMENU, 'E', -'E', -sdk.VK_LMENU, -sdk.VK_LCONTROL, -'W' };
        try self.record("new window releases its Enter shortcut before the old window's held W", .{ .pid = other.pid, .hwnd = driver.number(window), .keys = keys });
        try self.keyboard.send(other, window, browser_class, keys);
        sdk.Sleep(80);
        const before = try self.observeOther(other, window, other_page, "new window before the blocked request returns");
        try require(before.noDelivery() and !try self.editAllowed());
    }

    const deadline = sdk.GetTickCount64() + 5000;
    while (true) {
        try other.foreground(window, browser_class);
        const state = try self.observeOther(other, window, other_page, "new window after the old key release");
        try require(state.count("input") == 0 and state.count("Backspace") == 0 and equal(state.chat, "DESTINATION_CHAT"));
        var enter_released = false;
        for (state.events) |event| {
            if (!equal(event.type, "keyup")) continue;
            const key = event.key orelse "";
            try require(!std.ascii.eqlIgnoreCase(key, "w"));
            if (equal(key, "Enter")) enter_released = true;
        }
        if (enter_released and try self.editAllowed()) {
            try require(state.count("Enter") == 1 and equal(state.active, "input"));
            break;
        }
        if (sdk.GetTickCount64() >= deadline) return error.FixtureNewWindowEnterMissing;
        sdk.Sleep(30);
    }
    const source = try self.observe("old window after its captured W is discarded", true);
    try require(source.noDelivery() and source.count("Backspace") == 0 and equal(source.chat, "SOURCE_CHAT"));
    const reset = try other_page.evaluate(self.alloc, "window.fixture.reset('input', 'DESTINATION_CHAT')");
    try require(reset == .bool and reset.bool);
    try self.browser.activate(self.browser_hwnd, browser_class);
    try self.reset(.input, "SOURCE_CHAT");
}

fn focusSecondaryChat(self: *Runner, other: driver.Child, window: sdk.HWND, page: *cdp.Page) !void {
    try waitDocument(self.alloc, other, window, page);
    try page.bringToFront();
    const focused = "document.hasFocus() && document.activeElement?.id === 'input'";
    const initial = try page.evaluate(self.alloc, focused);
    if (initial == .bool and initial.bool) return;

    // Foreground activation can leave keyboard focus in the browser chrome.
    var client = try uia.Client.init();
    defer client.deinit();
    const condition = try automation.textCondition(client.automation, automation.sdk.UIA_NamePropertyId, "Chat");
    defer automation.release(condition);
    const deadline = sdk.GetTickCount64() + 3500;
    while (sdk.GetTickCount64() < deadline) {
        try other.foreground(window, browser_class);
        const value = try page.evaluate(self.alloc, focused);
        if (value == .bool and value.bool) return;
        const root = try client.root(driver.number(window));
        defer automation.release(root);
        if (try automation.objectOrNull(automation.Element, "FindFirst", root, .{ automation.sdk.TreeScope_Descendants, condition })) |element| {
            defer automation.release(element);
            try other.foreground(window, browser_class);
            try automation.check(automation.call("SetFocus", element, .{}));
        }
        sdk.Sleep(30);
    }
    return error.FixtureChatFocusMissing;
}

fn rejectReactionAfterForegroundChange(self: *Runner, other: driver.Child, window: sdk.HWND, other_page: *cdp.Page) !void {
    try self.browser.activate(self.browser_hwnd, browser_class);
    try self.chord('Q');
    const palette = try self.app.waitWindow(palette_class, true, 3500);
    try self.foregroundPalette(palette);
    const start = try self.paletteReactionButton(palette);
    try require(try self.editAllowed());

    {
        var paused = try driver.Paused.init(self.app);
        defer paused.unpause();
        try self.app.foreground(palette, palette_class);
        if (sdk.PostMessageW(start, sdk.BM_CLICK, 0, 0) == 0) return error.FixtureWindowMessage;
        const until = sdk.GetTickCount64() + 2000;
        while (try self.editAllowed()) {
            try self.app.foreground(palette, palette_class);
            if (sdk.GetTickCount64() >= until) return error.FixtureReactionRequestDidNotStart;
            sdk.Sleep(20);
        }
        try require(self.progress() == null);
        try self.record("operation is waiting for its paused worker before countdown", .{ .pid = paused.pid });
        try other.activate(window, browser_class);
        try other.foreground(window, browser_class);
        try self.record("another owned browser has foreground before the reaction reply", .{ .pid = other.pid, .hwnd = driver.number(window) });
    }
    const first_result = try waitReactionRejectionInOtherWindow(self, other, window, palette, "reaction started from the palette rejects foreground change during its request");
    try self.app.post(first_result, overlay_class, sdk.WM_CLOSE, 0, 0);
    const closed = sdk.GetTickCount64() + 2000;
    while (self.progress() != null) {
        if (sdk.GetTickCount64() >= closed) return error.FixtureProgressDidNotHide;
        sdk.Sleep(20);
    }

    try other.foreground(window, browser_class);
    // A click notification can still be in the palette's message queue after it loses foreground.
    try self.app.post(palette, palette_class, sdk.WM_COMMAND, reaction_start_id, @bitCast(driver.number(start)));
    _ = try waitReactionRejectionInOtherWindow(self, other, window, palette, "a queued start from the background palette is rejected");
    const source = try self.observe("original browser after both rejected reaction starts", true);
    const destination = try self.observeOther(other, window, other_page, "foreground browser after both rejected reaction starts");
    try require(source.reactions.len == 0 and destination.reactions.len == 0 and source.noDelivery() and destination.noDelivery());
    try self.app.post(palette, palette_class, sdk.WM_CLOSE, 0, 0);
}

fn waitReactionRejectionInOtherWindow(self: *Runner, other: driver.Child, window: sdk.HWND, palette: sdk.HWND, label: []const u8) !sdk.HWND {
    const until = sdk.GetTickCount64() + 4500;
    while (sdk.GetTickCount64() < until) {
        try other.foreground(window, browser_class);
        try require(sdk.IsWindowVisible(palette) != 0);
        if (self.progress()) |overlay| {
            const summary = try self.progressText(overlay);
            if (std.mem.indexOf(u8, summary, "操作先が変わったため中止しました") != null) {
                try self.record(label, .{ .pid = other.pid, .hwnd = driver.number(window), .text = summary });
                return overlay;
            }
            if (std.mem.indexOf(u8, summary, "秒後に実行します") != null) return error.FixtureStaleReactionStarted;
        }
        sdk.Sleep(20);
    }
    return error.FixtureProgressTimeout;
}

fn pipePump(signal: sdk.HANDLE, milliseconds: u32) !void {
    if (sdk.WaitForSingleObject(signal, milliseconds) == sdk.WAIT_FAILED) return error.FixturePipeWait;
}

fn waitTabChat(self: *Runner, page: *cdp.Page, label: []const u8) !State {
    const until = sdk.GetTickCount64() + 3500;
    while (sdk.GetTickCount64() < until) {
        try self.front();
        const state = try self.observeOther(self.browser, self.browser_hwnd, page, label);
        if (state.visible and state.focused and equal(state.active, "input") and equal(state.url, cdp.fixture_url))
            return state;
        sdk.Sleep(30);
    }
    return error.FixtureTabNotSelected;
}

fn sameVideoTab(self: *Runner, action: enum { send, slot, reaction }) !void {
    try self.front();
    const source_page = self.page;
    if (!try driver.ownsLocalListener(self.browser, source_page.port)) return error.FixtureListenerOwnership;
    var destination = try source_page.openTab();
    defer destination.close();
    defer {
        self.page = source_page;
        self.selectTab(source_page) catch |failure| {
            if (self.report.cleanup_error == null) self.report.cleanup_error = @errorName(failure);
        };
        if (self.browser.owned(self.browser_hwnd, browser_class) and sdk.GetForegroundWindow() == self.browser_hwnd)
            source_page.closeTab(destination.target_id) catch |failure| {
                if (self.report.cleanup_error == null) self.report.cleanup_error = @errorName(failure);
            };
    }
    try self.front();
    try require(!equal(&source_page.target_id, &destination.target_id));
    try destination.navigate();
    try waitDocument(self.alloc, self.browser, self.browser_hwnd, &destination);
    self.page = &destination;
    try self.reset(.input, "DESTINATION_CHAT");
    try self.selectTab(source_page);
    self.page = source_page;
    try self.reset(.input, "SOURCE_CHAT");
    const original = try waitTabChat(self, source_page, "original selected tab");
    try require(original.noDelivery() and equal(original.chat, "SOURCE_CHAT") and equal(original.video, original_video));
    try self.record("different CDP targets for the same owned browser HWND", .{
        .pid = self.browser.pid,
        .hwnd = driver.number(self.browser_hwnd),
        .text = try std.fmt.allocPrint(self.alloc, "{s} to {s}", .{ &source_page.target_id, &destination.target_id }),
    });
    if (action == .reaction) return rejectReactionOnNewTab(self, source_page, &destination);

    var pipe_worker: transport.Client = .{};
    defer pipe_worker.stop() catch |failure| {
        if (self.report.cleanup_error == null) self.report.cleanup_error = @errorName(failure);
    };
    const executable = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, self.app.path);
    const hwnd = driver.number(self.browser_hwnd);
    try self.front();
    const bound = try pipe_worker.request(self.alloc, executable, .browser_context, hwnd, "", &.{.{ .name = "PageToken", .value = "bind" }}, pipePump);
    defer bound.deinit();
    try require(bound.is("ok") and equal(bound.field("Video"), original_video));
    const page_token = operations.pageToken(bound.field("PageToken")) orelse return error.FixturePageProof;
    try self.record("named-pipe worker bound the original visible document", .{ .pid = sdk.GetProcessId(pipe_worker.process) });
    const scoped = [_]transport.Field{.{ .name = "PageToken", .value = &page_token }};
    const confirmed = try pipe_worker.request(self.alloc, executable, .verify_input, hwnd, original_video, &scoped, pipePump);
    defer confirmed.deinit();
    try require(confirmed.is("ok") and equal(confirmed.field("Detail"), "chat") and equal(confirmed.field("PageToken"), &page_token));

    if (action == .slot) {
        const rejected = try requestFixtureInsertion(self, &pipe_worker, executable, scoped[0], "unsafe\ttext");
        defer rejected.deinit();
        try require(rejected.is("invalid_text"));
        const unchanged = try self.observe("an existing body with an editing key is rejected before sending", false);
        try require(unchanged.noDelivery() and equal(unchanged.chat, "SOURCE_CHAT"));
        const prepared = try pipe_worker.request(self.alloc, executable, .verify_input, hwnd, original_video, &scoped, pipePump);
        defer prepared.deinit();
        try require(prepared.is("ok") and equal(prepared.field("PageToken"), &page_token));
    }

    try self.selectTab(&destination);
    self.page = &destination;
    const selected = try waitTabChat(self, &destination, "second tab selected with the same video and URL");
    try require(selected.noDelivery() and equal(selected.chat, "DESTINATION_CHAT") and equal(selected.video, original_video));
    if (action == .send) {
        const cancellation = try keyboard_io.Cancellation.create();
        defer cancellation.close();
        const enter_fields = [_]transport.Field{
            scoped[0],
            .{ .name = "CancelToken", .value = &cancellation.token },
        };
        const refused = try pipe_worker.request(self.alloc, executable, .chat_enter, hwnd, original_video, &enter_fields, pipePump);
        defer refused.deinit();
        try require(refused.is("changed") and refused.field("PageToken").len == 0);
        try self.record("Enter commit rejects the other tab using the original input proof", .{ .pid = sdk.GetProcessId(pipe_worker.process) });
        try self.selectTab(source_page);
        const shown = try waitTabChat(self, source_page, "the original tab is shown again without preparing a new Enter");
        try require(shown.noDelivery() and equal(shown.chat, "SOURCE_CHAT"));
        const replay = try pipe_worker.request(self.alloc, executable, .chat_enter, hwnd, original_video, &enter_fields, pipePump);
        defer replay.deinit();
        try require(replay.is("changed") and replay.field("PageToken").len == 0);
        try self.record("reselecting the original tab does not restore the consumed input proof", .{ .pid = sdk.GetProcessId(pipe_worker.process) });
        try self.selectTab(&destination);
        _ = try waitTabChat(self, &destination, "the second tab is shown again after the refused Enter attempts");
    } else {
        const rejected_input = try requestFixtureInsertion(self, &pipe_worker, executable, scoped[0], alpha);
        defer rejected_input.deinit();
        try require(rejected_input.is("changed") and rejected_input.field("PageToken").len == 0);
        try self.record("input commit rejects the other tab using the original input proof", .{ .pid = sdk.GetProcessId(pipe_worker.process) });
    }
    const baseline = try pipe_worker.request(self.alloc, executable, .verify_input, hwnd, original_video, &.{}, pipePump);
    defer baseline.deinit();
    try require(baseline.is("ok") and equal(baseline.field("Detail"), "chat") and baseline.field("PageToken").len == 0);
    try self.record("HWND and video alone approve the new tab", .{ .pid = sdk.GetProcessId(pipe_worker.process), .text = try self.alloc.dupe(u8, baseline.field("State")) });
    const verified = try pipe_worker.request(self.alloc, executable, .verify_input, hwnd, original_video, &scoped, pipePump);
    defer verified.deinit();
    try require(verified.is("changed") and equal(verified.field("Video"), original_video) and verified.field("PageToken").len == 0);
    try self.record("original document proof rejects the other tab before input", .{ .pid = sdk.GetProcessId(pipe_worker.process), .text = try self.alloc.dupe(u8, verified.field("State")) });
    const source = try self.observeOther(self.browser, self.browser_hwnd, source_page, "original document after rejected verification");
    const target = try self.observe("destination document after rejected verification", false);
    try require(!source.visible and source.noDelivery() and equal(source.chat, "SOURCE_CHAT") and equal(source.url, cdp.fixture_url));
    try require(target.visible and target.noDelivery() and equal(target.chat, "DESTINATION_CHAT") and equal(target.search, "KEEP"));

    if (action == .send) {
        try pipe_worker.stop();
        const restarted = try pipe_worker.request(self.alloc, executable, .verify_input, hwnd, original_video, &scoped, pipePump);
        defer restarted.deinit();
        try require(restarted.is("changed") and restarted.field("PageToken").len == 0);
        try self.record("an old page proof is rejected after worker restart", .{ .pid = sdk.GetProcessId(pipe_worker.process), .text = try self.alloc.dupe(u8, restarted.field("State")) });

        _ = try waitTabChat(self, &destination, "confirm the destination before pressing the fresh Enter shortcut");
        try self.chord('E');
        _ = try self.waitState(.enter, "fresh Enter shortcut delivered in the new tab", 3500);
        sdk.Sleep(150);
        const positive = try self.observe("fresh explicit Enter was delivered exactly once", false);
        try require(positive.visible and positive.count("Enter") == 1 and positive.count("input") == 0 and equal(positive.chat, "DESTINATION_CHAT"));
        var releases: usize = 0;
        for (positive.events) |event| {
            if (equal(event.type, "keyup") and equal(event.key orelse "", "Enter")) releases += 1;
        }
        try require(releases == 1);
    } else {
        try self.reset(.input, "");
        _ = try waitTabChat(self, &destination, "confirm the destination before pressing the fresh slot shortcut");
        try self.chord('3');
        _ = try self.waitState(.{ .chat = alpha }, "fresh slot shortcut delivered in the new tab", 3500);
        sdk.Sleep(150);
        const positive = try self.observe("fresh slot inserted without Enter in the new tab", false);
        try require(positive.visible and positive.count("input") > 0 and positive.count("Enter") == 0 and equal(positive.chat, alpha));
        for (positive.events) |event| try require(!(equal(event.type, "keyup") and equal(event.key orelse "", "Enter")));
    }
    const untouched = try self.observeOther(self.browser, self.browser_hwnd, source_page, "original tab remains untouched after a new shortcut");
    try require(!untouched.visible and untouched.noDelivery() and equal(untouched.chat, "SOURCE_CHAT"));
}

fn requestFixtureInsertion(self: *Runner, worker: *transport.Client, executable: [:0]const u16, scope: transport.Field, body: []const u8) !transport.Reply {
    const cancellation = try keyboard_io.Cancellation.create();
    defer cancellation.close();
    const payload = try keyboard_io.Payload.create(&cancellation.token, body);
    defer payload.close();
    var buffer: [20]u8 = undefined;
    const size = try std.fmt.bufPrint(&buffer, "{d}", .{body.len});
    return worker.request(self.alloc, executable, .input_insert, driver.number(self.browser_hwnd), original_video, &.{
        scope,
        .{ .name = "CancelToken", .value = &cancellation.token },
        .{ .name = "PayloadBytes", .value = size },
    }, pipePump);
}

fn sameVideoTabSend(self: *Runner) !void {
    try sameVideoTab(self, .send);
}

fn sameVideoTabSlot(self: *Runner) !void {
    try sameVideoTab(self, .slot);
}

fn rejectReactionOnNewTab(self: *Runner, source: *cdp.Page, destination: *cdp.Page) !void {
    const setup = "window.fixture.resetReactions() && window.fixture.showReactions(true)";
    try self.action(setup);
    const ready = try destination.evaluate(self.alloc, setup);
    try require(ready == .bool and ready.bool);
    try self.chord('Q');
    const palette = try self.app.waitWindow(palette_class, true, 3500);
    try self.foregroundPalette(palette);
    const start = try self.paletteReactionButton(palette);
    if (sdk.PostMessageW(start, sdk.BM_CLICK, 0, 0) == 0) return error.FixtureWindowMessage;
    _ = try self.waitProgress("秒後に実行します", "palette starts the owned original tab countdown", 4000);
    try self.selectTab(destination);
    self.page = destination;
    _ = try waitTabChat(self, destination, "new tab is active before the original countdown expires");
    const reason = try self.waitProgress("タブが変わったため中止しました", "stale reaction stops on the same video in the other tab", 6500);
    try require(std.mem.indexOf(u8, reason, "0 /") != null);
    const original = try self.observeOther(self.browser, self.browser_hwnd, source, "original tab received no reaction");
    const replacement = try self.observe("replacement tab received no reaction from the old request", false);
    try require(!original.visible and replacement.visible and equal(original.video, original_video) and equal(replacement.video, original_video));
    try require(original.reactions.len == 0 and replacement.reactions.len == 0 and original.noDelivery() and replacement.noDelivery());
}

fn sameVideoTabReaction(self: *Runner) !void {
    try sameVideoTab(self, .reaction);
}

fn slots(self: *Runner, modifier: i16, payloads: [4][]const u8) !void {
    const keys = [_]i16{ '1', '2', '3', '4' };
    const labels = [_][]const u8{ "manual caster slot 1", "manual caster slot 2", "shared slot 1", "shared slot 2" };
    for (keys, labels, payloads) |key, label, payload| {
        try self.reset(.input, "");
        try self.chordWith(key, modifier);
        _ = try self.waitState(.{ .chat = payload }, label, 3500);
        sdk.Sleep(150);
        const stable = try self.observe(label, false);
        try require(equal(stable.active, "input") and equal(stable.chat, payload) and equal(stable.search, "KEEP") and stable.count("input") > 0);
        for (stable.events) |event| {
            if (equal(event.type, "Enter") or (equal(event.type, "keyup") and equal(event.key orelse "", "Enter")))
                return error.UnexpectedEnterForSlot;
        }
    }
}

fn defaultSlots(self: *Runner) !void {
    try slots(self, sdk.VK_LMENU, .{ a1, a2, alpha, beta });
}

fn paletteDoubleClick(self: *Runner) !void {
    try self.reset(.input, "leftREMOVEright");
    try self.action("(document.getElementById('input').setSelectionRange(4, 10), true)");
    try self.chord('Q');
    const palette = try self.app.waitWindow(palette_class, true, 3500);
    const list_id = 102;
    const list = sdk.GetDlgItem(palette, list_id) orelse return error.FixturePaletteListMissing;
    try require(driver.windowPid(list) == self.app.pid and sdk.GetParent(list) == palette);
    const notification = (@as(usize, sdk.LBN_DBLCLK) << 16) | list_id;
    try self.app.post(palette, palette_class, sdk.WM_COMMAND, notification, @bitCast(driver.number(list)));
    _ = try self.waitState(.{ .chat = "left" ++ a1 ++ "right" }, "palette double-click replaces only the selection", 4000);
    try self.waitUntilEditable();
    const inserted = try self.observe("palette double-click inserted without sending Enter", false);
    try require(equal(inserted.chat, "left" ++ a1 ++ "right") and equal(inserted.search, "KEEP"));
    try require(inserted.count("Enter") == 0 and inserted.count("input") > 0);
    for (inserted.events) |event| try require(!equal(event.key orelse "", "Enter"));
}

fn paletteAndReactionHover(self: *Runner) !void {
    try self.reset(.input, "UNCHANGED");
    try self.action("window.fixture.resetReactions() && window.fixture.showReactions(false)");
    try require(self.app.window(palette_class, true) == null);
    try self.chord('Q');
    const palette = try self.app.waitWindow(palette_class, true, 3500);
    try self.record("default palette key opened the owned palette", .{ .pid = self.app.pid, .hwnd = driver.number(palette) });
    try self.closePalette(palette);
    const after_palette = try self.observe("palette key has no input or Enter effect", false);
    try require(after_palette.noDelivery() and equal(after_palette.chat, "UNCHANGED") and equal(after_palette.search, "KEEP") and after_palette.reactions.len == 0);

    try self.pointToButton("Search");
    try self.reset(.input, "UNCHANGED");
    const before_hover = try self.observe("pointer starts away from the reaction launcher", false);
    try require(before_hover.count("launcher_hover") == 0);
    try self.chord('R');
    _ = try self.waitState(.{ .event = "launcher_hover" }, "reaction display key hovered the launcher", 3500);
    sdk.Sleep(200);
    const after_hover = try self.observe("launcher hover did not input, press Enter, or click", false);
    try require(after_hover.noDelivery() and after_hover.count("launcher_click") == 0 and after_hover.reactions.len == 0 and
        after_hover.pointers.len == 0 and equal(after_hover.chat, "UNCHANGED") and equal(after_hover.search, "KEEP"));
    try self.waitStatusTip("表示用UIへマウスを移動しました（表示は未確認）。");
    try self.expectPageDiagnostic("diagnostic after moving to the reaction launcher", .{
        .action = "reactions_show",
        .state = "hovered",
        .stage = "表示操作",
        .worker = "reactions_show",
    });
}

fn changeFixturePreferences(path: []const u8) !void {
    var db = try storage.Store.open(allocator, path);
    defer db.close();
    var snapshot = try db.load(allocator);
    defer snapshot.deinit();
    var prefs = snapshot.data.preferences;
    if (prefs.auto_mode or !equal(prefs.input_profile_id, manual_a)) return error.FixtureManualCasterMismatch;
    for (prefs.shortcut_keys, storage.default_shortcut_keys) |saved, expected| {
        if (!equal(saved, expected)) return error.FixtureDefaultBindingMismatch;
    }
    prefs.shortcut_keys = restarted_keys;
    prefs.input_profile_id = manual_b;
    try db.savePreferences(prefs);
}

fn restartedSlots(self: *Runner) !void {
    const until = sdk.GetTickCount64() + 2000;
    while (self.app.window(dialog_class, true) != null) {
        if (sdk.GetTickCount64() >= until) return error.FixtureResultDialogDidNotClose;
        sdk.Sleep(20);
    }
    try self.returnFromOwnedUi();
    const previous = self.app;
    const previous_host = self.host;
    if (!previous.owned(previous_host, host_class)) return error.FixtureWindowOwnership;
    try self.reset(.input, "");
    try self.chord('3');
    _ = try self.waitState(.{ .chat = alpha }, "original candidate inserted with its live worker", 4500);
    const previous_worker = try driver.ownedWorker(previous);
    defer _ = sdk.CloseHandle(previous_worker.handle);

    const candidate_dir = std.fs.path.dirname(previous.path) orelse return error.FixtureCandidateCopy;
    try changeFixturePreferences(try std.fs.path.join(self.alloc, &.{ candidate_dir, database }));
    const image = try files.openImmutable(self.alloc, previous.path);
    defer image.close();
    const digest = files.hex(try files.fileDigest(image));
    if (!std.mem.eql(u8, &digest, &self.report.sha256.?)) return error.FixtureCandidateCopy;
    try self.record("isolated DB saved manual caster B and all eleven remapped shortcuts", .{});

    if (!previous.running() or sdk.WaitForSingleObject(previous_worker.handle, 0) != sdk.WAIT_TIMEOUT) return error.FixtureWorkerMissing;
    try self.record("original worker is alive before same-path restart", .{ .pid = previous_worker.pid });
    const code = try previous.closeGracefully(host_class);
    if (code != 0) return error.FixtureOriginalAppDidNotExitCleanly;
    self.report.app_exit = code;
    if (sdk.WaitForSingleObject(previous_worker.handle, 0) != sdk.WAIT_OBJECT_0) return error.FixturePreviousWorkerSurvivedRestart;
    var worker_exit: sdk.DWORD = undefined;
    if (sdk.GetExitCodeProcess(previous_worker.handle, &worker_exit) == 0 or worker_exit != 1)
        return error.FixtureUnexpectedPreviousWorkerExit;
    self.report.previous_worker_exit = worker_exit;
    try previous.finishJob();
    try self.record("original app exited before same-path relaunch", .{ .pid = previous.pid, .hwnd = driver.number(previous_host) });
    try self.record("original worker exited with the disconnect code", .{ .pid = previous_worker.pid });

    // A duplicate quiet launch recalls the resident. Relaunch after closing it.
    const replacement = try driver.Child.start(&.{ previous.path, "--quiet" }, candidate_dir, false);
    defer replacement.deinit();
    defer closeChild(replacement, host_class, &self.report.restarted_app_exit, self.report);
    try require(replacement.pid != previous.pid);
    self.report.restarted_app_pid = replacement.pid;
    const host = try replacement.waitWindow(host_class, false, 9500);
    _ = try replacement.waitWindow(palette_class, false, 6000);
    try replacement.waitForDispatch(host, host_class);
    self.app = replacement;
    self.host = host;
    defer {
        self.app = previous;
        self.host = previous_host;
    }
    try self.returnFromOwnedUi();
    try self.record("same candidate running under a new PID", .{ .pid = replacement.pid, .hwnd = driver.number(host), .text = try self.alloc.dupe(u8, &digest) });
    errdefer self.recordRestartFailure() catch {};

    try self.reset(.input, "UNCHANGED");
    for ([_]i16{ '1', '2', '3', '4' }) |key| try self.chord(key);
    sdk.Sleep(3000);
    const obsolete = try self.observe("old Ctrl+Alt bindings perform no insertion or Enter after restart", false);
    try require(obsolete.noDelivery() and equal(obsolete.chat, "UNCHANGED") and equal(obsolete.search, "KEEP"));
    try slots(self, sdk.VK_LSHIFT, .{ b1, b2, alpha, beta });
    try verifyRestartedPageKeys(self);
}

fn verifyRestartedPageKeys(self: *Runner) !void {
    const shift = sdk.VK_LSHIFT;
    try self.chordWith('Q', shift);
    const palette = try self.app.waitWindow(palette_class, true, 3500);
    try self.foregroundPalette(palette);
    try self.record("remapped palette shortcut opened the owned palette", .{ .hwnd = driver.number(palette), .pid = self.app.pid });
    try self.closePalette(palette);

    try self.reset(.search, "KEEP_CHAT");
    try self.chordWith('F', shift);
    const focused = try self.waitState(.{ .active = "input" }, "remapped focus shortcut moved to chat", 3500);
    try require(focused.noDelivery() and equal(focused.chat, "KEEP_CHAT"));
    // Finish the request that changed focus before using CDP to move it again.
    try self.waitUntilEditable();

    try self.reset(.search, "CLEAR_CHAT");
    try self.chordWith('W', shift);
    const cleared = try self.waitState(.{ .chat = "" }, "remapped clear shortcut emptied only chat", 3500);
    try require(equal(cleared.active, "input") and equal(cleared.search, "KEEP") and cleared.count("Enter") == 0);
    try self.waitUntilEditable();

    try self.reset(.input, "SEND_CHAT");
    try self.chordWith('E', shift);
    _ = try self.waitState(.enter, "remapped explicit Enter shortcut reached chat", 3500);
    sdk.Sleep(150);
    const sent = try self.observe("remapped explicit Enter produced one Enter and no insertion", false);
    try require(sent.count("Enter") == 1 and sent.count("input") == 0 and equal(sent.chat, "SEND_CHAT"));
    try self.waitUntilEditable();

    try self.action("window.fixture.resetReactions() && window.fixture.showReactions(true)");
    try self.pointToButton("Heart");
    try self.reset(.input, "KEEP_CHAT");
    try self.chordWith('T', shift);
    _ = try self.waitState(.{ .reactions = 1 }, "remapped reaction shortcut started a real operation", 4500);
    try self.keys(&.{ sdk.VK_LCONTROL, shift, 'S' });
    const result = try self.waitProgress("中止しました", "remapped stop took effect while its keys were held", 4500);
    try self.keys(&.{ -'S', -shift, -sdk.VK_LCONTROL });
    const stopped = try self.observe("remapped stop retained the acknowledged count", false);
    try require(stopped.reactions.len > 0 and stopped.reactions.len < 10 and stopped.noDelivery());
    var counts: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&counts, "{d} / 10", .{stopped.reactions.len});
    try require(std.mem.indexOf(u8, result, expected) != null);
    sdk.Sleep(1150);
    try require((try self.observe("no later operation followed the remapped stop", false)).reactions.len == stopped.reactions.len);
    try self.waitUntilEditable();

    try self.action("window.fixture.resetReactions() && window.fixture.showReactions(false)");
    const result_overlay = self.progress() orelse return error.FixtureProgressMissing;
    try self.pointToButton("Search");
    try require(self.progress() == result_overlay);
    try self.record("browser pointer reached Search before the result overlay closed", .{ .hwnd = driver.number(result_overlay), .pid = self.app.pid });
    try self.reset(.input, "KEEP_CHAT");
    try self.chordWith('R', shift);
    _ = try self.waitState(.{ .event = "launcher_hover" }, "remapped show shortcut hovered the reaction launcher", 3500);
    try self.waitUntilEditable();
    const hovered = try self.observe("remapped hover did not click or deliver", false);
    try require(hovered.noDelivery() and hovered.reactions.len == 0 and hovered.count("launcher_click") == 0 and hovered.pointers.len == 0);
}

fn register(self: *Runner) !void {
    try self.action("window.fixture.resetReactions() && window.fixture.showReactions(false)");
    try self.menu(4);
    _ = try self.waitProgress("登録を待っています", "registration starts with buttons hidden", 5000);
    try self.pointToButton("Show reactions");
    sdk.Sleep(1300);
    const overlay = self.progress() orelse return error.FixtureProgressMissing;
    if (sdk.IsWindowEnabled(sdk.GetDlgItem(overlay, 1)) == 0) return error.FixtureRegistrationDidNotRetry;
    _ = try self.waitProgress("登録を待っています", "registration retries", 2000);
    try self.action("window.fixture.showReactions(true)");
    try self.pointToButton("Heart");
    _ = try self.waitProgress("登録しました", "registration saved", 5000);
    try require((try self.observe("no registration operations", false)).reactions.len == 0);

    const path = try std.fs.path.join(self.alloc, &.{ self.output, "candidate", database });
    const saved = try registrationPayload(self.alloc, path, try fixture_browser.Browser.fromPath(self.browser_exe));
    try self.action("(document.getElementById('fixture-heart').setAttribute('aria-label', 'ハート'), true)");
    {
        // A competing write transaction leaves the committed registration available to readers.
        var lock = try sqlite.Connection.open(self.alloc, path, .read_write);
        defer lock.close();
        try lock.exec("BEGIN IMMEDIATE");
        defer lock.rollback();
        try self.menu(4);
        _ = try self.waitProgress("登録を待っています", "capture with the database locked", 5000);
        try self.pointToButton("ハート");
        _ = try self.waitProgress("以前の登録を保持しています", "save failure preserves registration", 6000);
    }
    const detail = try self.supportDocument(6, "database lock was reported after capture");
    try require(std.mem.indexOf(u8, detail, "DatabaseLocked") != null);
    try require(equal(saved, try registrationPayload(self.alloc, path, try fixture_browser.Browser.fromPath(self.browser_exe))));
    try require((try self.observe("no reaction from the failed capture", false)).reactions.len == 0);
    try self.action("(document.getElementById('fixture-heart').setAttribute('aria-label', 'Heart'), true)");
    try diagnosisWhileRegistering(self);
}

fn diagnosisWhileRegistering(self: *Runner) !void {
    try self.reset(.input, "KEEP_CHAT");
    try self.action("window.fixture.resetReactions() && window.fixture.showReactions(false)");
    try self.menu(4);
    _ = try self.waitProgress("登録を待っています", "registration is pending before opening diagnostics", 5000);
    try self.app.post(self.host, host_class, sdk.WM_COMMAND, diagnostics_command, 0);
    const dialog = try self.app.waitWindow(dialog_class, true, 3000);
    errdefer self.app.post(dialog, dialog_class, sdk.WM_CLOSE, 0, 0) catch {};
    try require(equal(try driver.text(self.alloc, self.app, dialog), "診断情報"));
    try self.front();
    try require(!try self.editAllowed());
    const edit = sdk.GetDlgItem(dialog, 100);
    const waiting = try driver.text(self.alloc, self.app, edit);
    try require(std.mem.indexOf(u8, waiting, "(waiting)") != null);
    try self.record("visible diagnostics while registration waits", .{ .text = waiting, .pid = self.app.pid, .hwnd = driver.number(dialog) });

    const sequence = sdk.GetClipboardSequenceNumber();
    try self.app.post(dialog, dialog_class, sdk.WM_COMMAND, 3, 0);
    const copy_until = sdk.GetTickCount64() + 2000;
    while (sdk.GetClipboardSequenceNumber() == sequence or sdk.OpenClipboard(null) == 0) {
        if (sdk.GetTickCount64() >= copy_until) return error.FixtureDiagnosticCopyUnavailable;
        sdk.Sleep(20);
    }
    {
        defer _ = sdk.CloseClipboard();
        const data = sdk.GetClipboardData(sdk.CF_UNICODETEXT) orelse return error.FixtureClipboardTextMissing;
        const locked = sdk.GlobalLock(data) orelse return error.FixtureClipboardTextUnavailable;
        defer _ = sdk.GlobalUnlock(data);
        const units: [*:0]const u16 = @ptrCast(@alignCast(locked));
        const copied = try std.unicode.utf16LeToUtf8Alloc(self.alloc, std.mem.span(units));
        try require(equal(copied, waiting));
    }
    try self.front();
    try require(!try self.editAllowed());

    try self.app.activate(dialog, dialog_class);
    const stop_until = sdk.GetTickCount64() + 4000;
    while (!try self.editAllowed()) {
        if (sdk.GetTickCount64() >= stop_until) return error.FixtureRegistrationIgnoredForegroundChange;
        sdk.Sleep(25);
    }
    try self.app.foreground(dialog, dialog_class);
    const overlay = self.progress() orelse return error.FixtureProgressMissing;
    const stopped = try self.progressText(overlay);
    try require(std.mem.indexOf(u8, stopped, "操作先が変わったため中止しました") != null);
    try self.app.post(dialog, dialog_class, sdk.WM_COMMAND, 4, 0);
    const refresh_until = sdk.GetTickCount64() + 2000;
    while (true) {
        const updated = try driver.text(self.alloc, self.app, edit);
        if (std.mem.indexOf(u8, updated, "(finished)") != null) {
            try self.record("diagnostic refresh after foreground interruption", .{ .text = updated, .pid = self.app.pid, .hwnd = driver.number(dialog) });
            break;
        }
        if (sdk.GetTickCount64() >= refresh_until) return error.FixtureDiagnosticDidNotRefresh;
        sdk.Sleep(20);
    }
    const chord_keys = [_]i16{ sdk.VK_LCONTROL, sdk.VK_LMENU, 'Q', -'Q', -sdk.VK_LMENU, -sdk.VK_LCONTROL };
    try self.keyboard.send(self.app, dialog, dialog_class, &chord_keys);
    const palette = try self.app.waitWindow(palette_class, true, 3000);
    try self.app.foreground(palette, palette_class);
    try require(sdk.IsWindowVisible(dialog) != 0);
    var child: sdk.HWND = null;
    while (sdk.FindWindowExW(palette, child, driver.wide("Static"), null)) |next| {
        child = next;
        if (std.mem.startsWith(u8, try driver.text(self.alloc, self.app, child), "設定済み")) break;
    } else return error.FixtureDiagnosticLostOriginalBrowser;
    try self.closeOwnedDialog(dialog, dialog_class, .hide);
    try self.closePalette(palette);
    const state = try self.observe("registration interruption sent no page operation", false);
    try require(state.noDelivery() and state.reactions.len == 0);
    try self.action("window.fixture.showReactions(true)");
}

fn registrationPayload(alloc: std.mem.Allocator, path: []const u8, browser: fixture_browser.Browser) ![]u8 {
    var reader = try sqlite.Connection.open(alloc, path, .read_only);
    defer reader.close();
    return reader.scalarText(alloc, "SELECT payload FROM reaction_registrations WHERE browser=?", &.{.{ .text = @tagName(browser) }});
}

fn confirm(self: *Runner) !void {
    try self.menu(5);
    _ = try self.waitProgress("送信せずに確認", "confirmation countdown", 4000);
    _ = try self.waitProgress("確認しました", "confirmation succeeded", 8500);
    try require((try self.observe("no confirmation operations", false)).reactions.len == 0);
}

// These are user-visible choices. Keep them independent of the application's option table.
const expected_intervals = [_]u32{ 0, 25, 50, 100, 150, 200, 250, 500, 1000 };
const reaction_buttons = [_][]const u8{ "fixture-heart", "fixture-smile", "fixture-party", "fixture-wow", "fixture-hundred" };

fn saveReactionDefaults(self: *Runner, reader: *sqlite.Connection, kind: u8, interval_index: usize) !void {
    try self.chord('Q');
    const palette = try self.app.waitWindow(palette_class, true, 3500);
    try self.foregroundPalette(palette);
    for ([_]c_int{ reaction_kind_id, reaction_count_id, reaction_interval_id }, [_]usize{ kind - 1, 1, interval_index }) |id, index| {
        const control = sdk.GetDlgItem(palette, id);
        if (!self.app.owned(control, driver.wide("ComboBox")) or sdk.GetParent(control) != palette)
            return error.FixtureWindowOwnership;
        var result: sdk.DWORD_PTR = undefined;
        if (sdk.SendMessageTimeoutW(control, sdk.CB_SETCURSEL, index, 0, sdk.SMTO_ABORTIFHUNG, 1000, &result) == 0 or result != index)
            return error.FixtureReactionChoice;
    }
    const save = sdk.GetDlgItem(palette, reaction_save_id);
    if (sdk.GetParent(save) != palette) return error.FixtureWindowOwnership;
    try self.app.foreground(palette, palette_class);
    try self.app.post(save, driver.wide("Button"), sdk.BM_CLICK, 0, 0);
    const interval = expected_intervals[interval_index];
    const until = sdk.GetTickCount64() + 3000;
    while (true) {
        const saved = reader.scalarInt("SELECT count(*) FROM preferences WHERE reaction_kind=? AND reaction_count=10 AND reaction_interval=?", &.{ .{ .int = kind }, .{ .int = interval } }) catch |failure| switch (failure) {
            error.DatabaseLocked => 0,
            else => return failure,
        };
        if (saved == 1) break;
        if (sdk.GetTickCount64() >= until) return error.FixtureReactionDefaultsNotSaved;
        sdk.Sleep(30);
    }
    try self.closePalette(palette);
}

fn reactionTiming(self: *Runner) !void {
    const path = try std.fs.path.join(self.alloc, &.{ self.output, "candidate", database });
    var reader = try sqlite.Connection.open(self.alloc, path, .read_only);
    defer reader.close();
    try self.action("window.fixture.showReactions(true)");
    for (expected_intervals, 0..) |interval, index| {
        const kind: u8 = if (index == 0) 6 else @intCast((index - 1) % reaction_buttons.len + 1);
        try saveReactionDefaults(self, &reader, kind, index);
        try self.action("window.fixture.resetReactions()");
        try self.chord('T');
        const until = sdk.GetTickCount64() + 5000 + @as(u64, interval) * 10;
        while (true) {
            try self.front();
            const enough = try self.eval("window.fixture.state().reactions.length >= 10");
            if (enough == .bool and enough.bool) break;
            if (sdk.GetTickCount64() >= until) return error.FixtureReactionCountTimeout;
            sdk.Sleep(50);
        }
        const label = try std.fmt.allocPrint(self.alloc, "{d} ms interval, kind {d}", .{ interval, kind });
        const progress = try self.waitProgress("完了しました", label, 3000);
        const state = try self.observe(label, false);
        try require(state.reactions.len == 10 and std.mem.indexOf(u8, progress, "10 / 10") != null);
        const prefix = "平均開始間隔 ";
        const mean_start = (std.mem.indexOf(u8, progress, prefix) orelse return error.FixtureMeanIntervalMissing) + prefix.len;
        const mean_end = std.mem.indexOfPos(u8, progress, mean_start, " ms") orelse return error.FixtureMeanIntervalMissing;
        const mean = try std.fmt.parseInt(u32, progress[mean_start..mean_end], 10);
        try require(mean >= interval);
        for (state.reactions) |event| {
            if (kind != 6) {
                try require(equal(event.id, reaction_buttons[kind - 1]));
            } else {
                for (reaction_buttons) |button| {
                    if (equal(event.id, button)) break;
                } else return error.FixtureRandomReactionOutsideButtons;
            }
        }
    }
    try saveReactionDefaults(self, &reader, 1, expected_intervals.len - 1);
}

fn buttonStop(self: *Runner) !void {
    try self.reset(.input, "KEEP_IF_STOPPED");
    try self.action("window.fixture.resetReactions()");
    try self.chord('T');
    _ = try self.waitState(.{ .reactions = 1 }, "first observed reaction", 5000);
    const overlay = self.progress() orelse return error.FixtureProgressMissing;
    const before = try self.progressText(overlay);
    try self.record("progress initially visible", .{ .hwnd = driver.number(overlay), .pid = self.app.pid, .text = before });
    try self.app.post(overlay, overlay_class, sdk.WM_CLOSE, 0, 0);
    const until = sdk.GetTickCount64() + 1300;
    while (self.progress() != null and sdk.GetTickCount64() < until) sdk.Sleep(20);
    try require(self.progress() == null);
    try self.chord('Q');
    _ = try self.waitProgress("操作済み", "palette key returns the nonactivating overlay", 1500);
    try require(self.progress() == overlay);
    _ = try self.waitState(.{ .reactions = 2 }, "second observed reaction", 3500);
    try self.chord('W');
    const waiting = try self.observe("clear cannot take effect while the reaction owns its queue", false);
    try require(equal(waiting.chat, "KEEP_IF_STOPPED") and waiting.noDelivery() and !try self.editAllowed());
    try self.record("foreground before physical stop click", .{ .hwnd = driver.number(overlay), .pid = self.app.pid });
    var proof: driver.MouseProof = .{};
    driver.clickStop(self.browser, self.browser_hwnd, browser_class, self.app, overlay, overlay_class, &proof) catch |failure| {
        try self.record("owned physical stop click failed", .{ .pointer = proof, .text = @errorName(failure) });
        return failure;
    };
    try self.record("owned physical stop click sent", .{ .pointer = proof });
    const result = try self.waitProgress("中止しました", "stopped at the button without moving focus", 5000);
    const stopped = try self.observe("state after stop", false);
    try require(stopped.reactions.len >= 2 and stopped.reactions.len < 10 and std.mem.indexOf(u8, result, "平均開始間隔") != null);
    var count_buffer: [32]u8 = undefined;
    const count = try std.fmt.bufPrint(&count_buffer, "{d} / 10", .{stopped.reactions.len});
    try require(std.mem.indexOf(u8, result, count) != null);
    sdk.Sleep(1250);
    const after_stop = try self.observe("no operation after stop", false);
    try require(after_stop.reactions.len == stopped.reactions.len and equal(after_stop.chat, "KEEP_IF_STOPPED") and after_stop.noDelivery());
}

fn completedAndUnknown(self: *Runner) !void {
    try self.waitPriorReaction();
    try self.reset(.input, "CLEAR_AFTER_REACTION");
    try self.action("window.fixture.resetReactions()");
    try self.chord('T');
    _ = try self.waitState(.{ .reactions = 1 }, "first event from fresh completion job", 5000);
    try self.chord('W');
    const waiting = try self.observe("clear waits for the live reaction to finish", false);
    try require(equal(waiting.chat, "CLEAR_AFTER_REACTION") and waiting.noDelivery() and !try self.editAllowed());
    const completed = try self.waitProgress("完了しました", "all ten complete", 16000);
    const observed = try self.observe("complete count", false);
    try require(observed.reactions.len == 10 and std.mem.indexOf(u8, completed, "10 / 10") != null and std.mem.indexOf(u8, completed, "平均開始間隔") != null);
    const cleared = try self.waitState(.{ .chat = "" }, "one deferred clear after the tenth reaction", 3500);
    try require(cleared.reactions.len == 10 and cleared.count("input") == 1 and cleared.noEnter() and equal(cleared.active, "input"));
    try self.waitUntilEditable();
    try self.action("window.fixture.resetReactions()");
    try self.chord('T');
    _ = try self.waitProgress("1 / 10", "first acknowledged operation before fault", 4000);
    try require((try self.observe("partial operation count before fault", false)).reactions.len == 1);
    {
        try self.front();
        var paused = try driver.Paused.init(self.app);
        defer paused.unpause();
        try self.record("same-job child paused after first operation", .{ .pid = paused.pid });
        const failed = try self.waitProgress("自動再送しません", "result unknown after timeout", 15500);
        try require(std.mem.indexOf(u8, failed, "1 / 10") != null);
    }
    try require((try self.observe("no more operations after timeout", false)).reactions.len == 1);
    const document = try self.supportDocument(6, "retained result dialog");
    try require(std.mem.indexOf(u8, document, "自動再送しません") != null and std.mem.indexOf(u8, document, "1 / 10") != null and std.mem.indexOf(u8, document, "WorkerTimeout") != null);
    const diagnostic = try self.supportDocument(8, "diagnostic after the timed-out reaction");
    for ([_][]const u8{ "直近の操作 reaction_send", "結果 unknown", "WorkerTimeout" }) |expected|
        try require(std.mem.indexOf(u8, diagnostic, expected) != null);
}

const Scenario = struct { name: []const u8, run: *const fn (*Runner) anyerror!void };
const cases = [_]Scenario{
    .{ .name = "chat focus from search", .run = focus },
    .{ .name = "two held chords run in release order", .run = releaseOrder },
    .{ .name = "held chord ignores repeat", .run = longPress },
    .{ .name = "explicit Enter reaches chat once", .run = explicitSend },
    .{ .name = "explicit send rejects search", .run = rejectSearch },
    .{ .name = "clear only modifies chat", .run = clearChat },
    .{ .name = "Escape suppresses queued input and Enter", .run = stopKeys },
    .{ .name = "video change during focus request suppresses input and Enter", .run = changeVideo },
    .{ .name = "different foreground window suppresses input, Enter and reaction starts", .run = changeWindow },
    .{ .name = "focus replacement during request suppresses input and Enter", .run = changeChat },
    .{ .name = "same-video tab proof rejects stale Enter and allows a fresh Enter shortcut", .run = sameVideoTabSend },
    .{ .name = "same-video tab proof rejects stale insertion and allows a fresh slot shortcut", .run = sameVideoTabSlot },
    .{ .name = "default keys select both manual caster slots and both shared slots without Enter", .run = defaultSlots },
    .{ .name = "palette double-click replaces the selected text without sending Enter", .run = paletteDoubleClick },
    .{ .name = "default palette and reaction display keys open and hover without sending", .run = paletteAndReactionHover },
    .{ .name = "registration retries and captures at the physical pointer", .run = register },
    .{ .name = "confirmation shows progress and sends nothing", .run = confirm },
    .{ .name = "the palette reaction countdown cannot send to a same-video replacement tab", .run = sameVideoTabReaction },
    .{ .name = "all reaction intervals and the random choice send exactly ten operations", .run = reactionTiming },
    .{ .name = "palette key recalls progress and physical stop does not activate", .run = buttonStop },
    .{ .name = "completion and timeout preserve distinct counts and diagnostics", .run = completedAndUnknown },
    .{ .name = "same-path restart retires the live worker and publishes saved slot keys", .run = restartedSlots },
};

const ime_cases = [_]Scenario{
    .{ .name = "browser IME closes on literal slot insertion without Enter", .run = browserIme },
};

test "browser fixture refuses invalid executable arguments and malformed debugging ports before any GUI work" {
    try std.testing.expectError(error.FixtureUsage, arguments(&.{}));
    try std.testing.expectError(error.ExpectedChatPaletteExecutable, arguments(&.{ "Other.exe", "result" }));
    try std.testing.expectError(error.ExpectedAbsoluteBrowserExecutable, arguments(&.{ "ChatPalette.exe", "result", "brave.exe" }));
    try std.testing.expectError(error.UnsupportedFixtureBrowser, arguments(&.{ "ChatPalette.exe", "result", "C:\\Apps\\firefox.exe" }));
    try std.testing.expect(!(try arguments(&.{ "ChatPalette.exe", "result" })).ime_only);
    try std.testing.expect((try arguments(&.{ "ChatPalette.exe", "result", "--ime-only" })).ime_only);
    try std.testing.expectEqualStrings("C:\\Apps\\brave.exe", (try arguments(&.{ "ChatPalette.exe", "result", "C:\\Apps\\brave.exe", "--ime-only" })).browser_exe.?);
    try std.testing.expectEqual(@as(u16, 65535), try parsePort("65535\r\n/devtools/browser/fixture\r\n"));
    try std.testing.expectError(error.InvalidDebuggingPort, parsePort("0\n/devtools/browser/fixture"));
    try std.testing.expectError(error.InvalidDebuggingPort, parsePort("80\nhttp://example.invalid"));
    try std.testing.expectError(error.InvalidDebuggingPort, parsePort("+80\n/devtools/browser/fixture"));
}

test "delivery checks detect DOM input plus both Enter edges" {
    var state: State = .{ .active = "input", .chat = "", .search = "", .video = original_video, .retired_chat = null, .events = &.{}, .reactions = &.{}, .pointers = &.{} };
    try std.testing.expect(state.noDelivery());
    for ([_]Event{
        .{ .type = "input", .id = "input" },
        .{ .type = "Enter", .id = "input" },
        .{ .type = "keyup", .id = "input", .key = "Enter" },
    }) |event| {
        var observed = [_]Event{event};
        state.events = &observed;
        try std.testing.expect(!state.noDelivery());
    }
}

test "restart preferences preserve all remapped keys and distinct caster and shared slot bodies" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "slots.db" });
    defer std.testing.allocator.free(path);
    try seed(path);
    try changeFixturePreferences(path);
    var db = try storage.Store.open(allocator, path);
    defer db.close();
    var snapshot = try db.load(std.testing.allocator);
    defer snapshot.deinit();
    const data = snapshot.data;
    try std.testing.expect(!data.preferences.auto_mode);
    try std.testing.expectEqualStrings(manual_b, data.preferences.input_profile_id);
    for (restarted_keys, data.preferences.shortcut_keys) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    const selected = try data.itemsFor(data.preferences.input_profile_id);
    try std.testing.expectEqualStrings(b1, selected[0].text);
    try std.testing.expectEqualStrings(b2, selected[1].text);
    try std.testing.expectEqualStrings(a1, (try data.itemsFor(manual_a))[0].text);
    const shared = try data.itemsFor("");
    try std.testing.expectEqualStrings(alpha, shared[0].text);
    try std.testing.expectEqualStrings(beta, shared[1].text);
}

test {
    _ = cdp;
    _ = driver;
}
