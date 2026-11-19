const std = @import("std");
const windows = @import("desktop/win.zig");
const input = @import("desktop/input.zig");
const process = @import("tools/process.zig");
const win = windows.api;
const tsf = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cDefine("NONAMELESSUNION", "1");
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cInclude("windows.h");
    @cInclude("imm.h");
    @cInclude("msctf.h");
});

const alloc = std.heap.page_allocator;
const class = windows.wide("ChatPalette.ImeFixture");
const literal = "日本語あ👏𠮷";
const expected = windows.wide(literal);
const ja = 0x0411;
// Windows SDK msctf.h values not exported by the MinGW header.
const profile_for_process = 0x10000000;
const profile_manager_iid = guid(0x71c6e74c, 0x0f28, 0x11d8, .{ 0xa8, 0x2a, 0x00, 0x06, 0x5b, 0x84, 0x43, 0x5c });
const keyboard_category = guid(0x34745c63, 0xb2f0, 0x4784, .{ 0x8b, 0x67, 0x5e, 0x12, 0xc8, 0x70, 0x1a, 0x31 });
// Microsoft IME for Japanese, listed in the Windows default input profiles.
const microsoft_ime = guid(0x03b5835f, 0xf03c, 0x411b, .{ 0x9c, 0xe2, 0xaa, 0x23, 0xe1, 0x17, 0x1e, 0x36 });
const japanese_profile = guid(0xa76c93d9, 0x5523, 0x4e90, .{ 0xaa, 0xfa, 0x4d, 0xb1, 0x12, 0xf9, 0xac, 0x76 });

fn guid(data1: u32, data2: u16, data3: u16, data4: [8]u8) tsf.GUID {
    return .{ .Data1 = data1, .Data2 = data2, .Data3 = data3, .Data4 = data4 };
}

fn call(comptime method: []const u8, object: anytype, args: anytype) tsf.HRESULT {
    return @call(.auto, @field(object.lpVtbl.*, method).?, .{object} ++ args);
}

fn release(object: anytype) void {
    _ = object.lpVtbl.*.Release.?(object);
}

fn knownIme(value: tsf.TF_INPUTPROCESSORPROFILE) bool {
    return value.dwProfileType == tsf.TF_PROFILETYPE_INPUTPROCESSOR and value.langid == ja and
        std.meta.eql(value.clsid, microsoft_ime) and std.meta.eql(value.guidProfile, japanese_profile);
}

const Profiles = struct {
    base: *tsf.ITfInputProcessorProfiles,
    manager: *tsf.ITfInputProcessorProfileMgr,

    fn open() !Profiles {
        if (tsf.CoInitializeEx(null, tsf.COINIT_APARTMENTTHREADED) < 0) return error.ImeComUnavailable;
        errdefer tsf.CoUninitialize();
        var raw_base: [*c]tsf.ITfInputProcessorProfiles = null;
        if (tsf.TF_CreateInputProcessorProfiles(&raw_base) != tsf.S_OK or raw_base == null) return error.ImeProfilesUnavailable;
        const base: *tsf.ITfInputProcessorProfiles = raw_base;
        errdefer release(base);
        var manager: ?*anyopaque = null;
        if (call("QueryInterface", base, .{ &profile_manager_iid, &manager }) != tsf.S_OK or manager == null)
            return error.ImeProfileManagerUnavailable;
        return .{ .base = base, .manager = @ptrCast(@alignCast(manager.?)) };
    }

    fn close(self: Profiles) void {
        release(self.manager);
        release(self.base);
        tsf.CoUninitialize();
    }

    fn active(self: Profiles) !tsf.TF_INPUTPROCESSORPROFILE {
        var value = std.mem.zeroes(tsf.TF_INPUTPROCESSORPROFILE);
        if (call("GetActiveProfile", self.manager, .{ &keyboard_category, &value }) != tsf.S_OK)
            return error.ActiveImeProfileUnavailable;
        return value;
    }

    fn stockEnabled(self: Profiles) !bool {
        var enabled: tsf.BOOL = 0;
        if (call("IsEnabledLanguageProfile", self.base, .{ &microsoft_ime, @as(tsf.LANGID, ja), &japanese_profile, &enabled }) != tsf.S_OK)
            return error.MicrosoftImeProfileUnavailable;
        return enabled != 0;
    }

    fn selectStock(self: Profiles) tsf.HRESULT {
        return call("ActivateProfile", self.manager, .{
            @as(tsf.DWORD, tsf.TF_PROFILETYPE_INPUTPROCESSOR), @as(tsf.LANGID, ja), &microsoft_ime, &japanese_profile, @as(tsf.HKL, null), @as(tsf.DWORD, profile_for_process),
        });
    }

    fn selectPrevious(self: Profiles, value: tsf.TF_INPUTPROCESSORPROFILE) tsf.HRESULT {
        return call("ActivateProfile", self.manager, .{
            value.dwProfileType,                                                               value.langid,                        &value.clsid, &value.guidProfile,
            if (value.dwProfileType == tsf.TF_PROFILETYPE_KEYBOARDLAYOUT) value.hkl else null, @as(tsf.DWORD, profile_for_process),
        });
    }
};

const State = struct {
    foreground: usize,
    focus: usize,
    layout: usize,
    microsoft_ime: bool,
    open: bool,
};

const Counts = struct {
    enter_down: u32 = 0,
    enter_up: u32 = 0,
    carriage_or_line_feed: u32 = 0,
    open_status_notifications: u32 = 0,
};

const Report = struct {
    passed: bool = false,
    probe: bool,
    failure: ?[]const u8 = null,
    restore_failure: ?[]const u8 = null,
    microsoft_ime_enabled: ?bool = null,
    active_before_is_microsoft: ?bool = null,
    original_profile_open: ?bool = null,
    profile_activation_hresult: ?i32 = null,
    owner_pid: ?u32 = null,
    window: ?usize = null,
    edit: ?usize = null,
    before_open: ?State = null,
    closed_baseline: ?State = null,
    opened: ?State = null,
    after_insert: ?State = null,
    expected_text: []const u8 = literal,
    actual_text: ?[]const u8 = null,
    actual_utf16: ?[]const u16 = null,
    counts: Counts = .{},
    restored_open: ?bool = null,
    restored_profile: ?bool = null,
    restored_original_open: ?bool = null,
};

pub fn main() !void {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const probe = args.len == 3 and equal(args[2], "--probe");
    if (args.len != 2 and !probe) {
        std.debug.print("chatpalette-ime-input-test <新規結果フォルダー> [--probe]\n", .{});
        std.process.exit(2);
    }
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const owned = arena.allocator();
    try std.fs.cwd().makeDir(args[1]);
    const path = try std.fs.cwd().realpathAlloc(owned, args[1]);
    var report: Report = .{ .probe = probe };
    verify(owned, &report) catch |failure| {
        report.failure = @errorName(failure);
    };
    report.passed = !probe and report.failure == null and report.restore_failure == null;
    try process.saveResult(owned, path, report);
    if (report.failure != null or report.restore_failure != null) {
        std.debug.print("IME入力試験 {s} {s}\n", .{ report.failure orelse "", report.restore_failure orelse "" });
        std.process.exit(1);
    }
}

const Fixture = struct {
    host: win.HWND,
    edit: win.HWND,
    pid: u32,
    thread: u32,

    fn open(counts: *Counts) !Fixture {
        var wc = std.mem.zeroes(win.WNDCLASSW);
        wc.hInstance = win.GetModuleHandleW(null);
        wc.lpfnWndProc = hostProc;
        wc.lpszClassName = class;
        wc.hbrBackground = win.GetSysColorBrush(win.COLOR_WINDOW);
        if (win.RegisterClassW(&wc) == 0) return error.RegisterImeFixtureWindow;
        const host = win.CreateWindowExW(win.WS_EX_TOOLWINDOW, class, windows.wide("ChatPalette IME 検証"), win.WS_OVERLAPPEDWINDOW, win.CW_USEDEFAULT, win.CW_USEDEFAULT, 500, 192, null, null, wc.hInstance, null) orelse return error.CreateImeFixtureWindow;
        errdefer _ = win.DestroyWindow(host);
        const edit = win.CreateWindowExW(win.WS_EX_CLIENTEDGE, windows.wide("EDIT"), windows.wide(""), win.WS_CHILD | win.WS_VISIBLE | win.ES_MULTILINE, 20, 20, 432, 90, host, null, wc.hInstance, null) orelse return error.CreateImeFixtureEdit;
        if (win.SetWindowSubclass(edit, editProc, 1, @intFromPtr(counts)) == 0) return error.ObserveImeFixtureEdit;
        return .{ .host = host, .edit = edit, .pid = win.GetCurrentProcessId(), .thread = win.GetCurrentThreadId() };
    }

    fn close(self: Fixture) void {
        if (self.ownsBoth()) _ = win.DestroyWindow(self.host);
    }

    fn ownsBoth(self: Fixture) bool {
        var host_pid: u32 = 0;
        var edit_pid: u32 = 0;
        return win.GetWindowThreadProcessId(self.host, &host_pid) == self.thread and host_pid == self.pid and
            win.GetWindowThreadProcessId(self.edit, &edit_pid) == self.thread and edit_pid == self.pid and
            win.GetAncestor(self.edit, win.GA_ROOT) == self.host;
    }

    fn front(self: Fixture) !void {
        if (!self.ownsBoth()) return error.ImeFixtureWindowNotOwned;
        if (win.GetForegroundWindow() != self.host or win.GetFocus() != self.edit) return error.ImeFixtureFocusChanged;
    }

    fn show(self: Fixture) !void {
        if (!self.ownsBoth()) return error.ImeFixtureWindowNotOwned;
        _ = win.ShowWindow(self.host, win.SW_SHOWNORMAL);
        _ = win.SetForegroundWindow(self.host);
        if (win.GetForegroundWindow() != self.host) {
            const other = win.GetWindowThreadProcessId(win.GetForegroundWindow(), null);
            const linked = other != 0 and other != self.thread and win.AttachThreadInput(self.thread, other, 1) != 0;
            defer if (linked) {
                _ = win.AttachThreadInput(self.thread, other, 0);
            };
            if (!self.ownsBoth()) return error.ImeFixtureWindowNotOwned;
            _ = win.BringWindowToTop(self.host);
            _ = win.SetForegroundWindow(self.host);
        }
        if (win.GetForegroundWindow() != self.host) return error.ImeFixtureFocusChanged;
        _ = win.SetFocus(self.edit);
        try self.front();
    }

    fn context(self: Fixture) !tsf.HIMC {
        if (!self.ownsBoth()) return error.ImeFixtureWindowNotOwned;
        return tsf.ImmGetContext(@ptrCast(self.edit)) orelse error.ImeContextUnavailable;
    }

    fn setOpen(self: Fixture, enabled: bool) !void {
        const ctx = try self.context();
        defer _ = tsf.ImmReleaseContext(@ptrCast(self.edit), ctx);
        if (tsf.ImmSetOpenStatus(ctx, @intFromBool(enabled)) == 0) return error.ImeOpenStateCouldNotBeSet;
    }

    fn readOpen(self: Fixture) !bool {
        const ctx = try self.context();
        defer _ = tsf.ImmReleaseContext(@ptrCast(self.edit), ctx);
        return tsf.ImmGetOpenStatus(ctx) != 0;
    }

    fn snapshot(self: Fixture, profiles: Profiles) !State {
        try self.front();
        return .{
            .foreground = windows.number(win.GetForegroundWindow()),
            .focus = windows.number(win.GetFocus()),
            .layout = if (win.GetKeyboardLayout(self.thread)) |handle| @intFromPtr(handle) else 0,
            .microsoft_ime = knownIme(try profiles.active()),
            .open = try self.readOpen(),
        };
    }

    fn text(self: Fixture, buffer: []u16) ![]const u16 {
        const length = win.GetWindowTextLengthW(self.edit);
        if (length < 0 or length >= buffer.len) return error.ImeFixtureTextTooLong;
        const copied = win.GetWindowTextW(self.edit, buffer.ptr, @intCast(buffer.len));
        if (copied != length) return error.ImeFixtureTextChanged;
        return buffer[0..@intCast(copied)];
    }
};

fn verify(owned: std.mem.Allocator, report: *Report) !void {
    const profiles = try Profiles.open();
    defer profiles.close();
    report.microsoft_ime_enabled = try profiles.stockEnabled();
    if (!report.microsoft_ime_enabled.?) return error.MicrosoftImeNotEnabled;
    if (report.probe) {
        if (profiles.active()) |active| report.active_before_is_microsoft = knownIme(active) else |_| {}
        return;
    }

    var raw_thread_mgr: [*c]tsf.ITfThreadMgr = null;
    if (tsf.TF_CreateThreadMgr(&raw_thread_mgr) != tsf.S_OK or raw_thread_mgr == null) return error.ImeThreadManagerUnavailable;
    const thread_mgr: *tsf.ITfThreadMgr = raw_thread_mgr;
    defer release(thread_mgr);
    var client_id: tsf.TfClientId = 0;
    if (call("Activate", thread_mgr, .{&client_id}) != tsf.S_OK) return error.ImeThreadManagerInactive;
    defer _ = call("Deactivate", thread_mgr, .{});

    const fixture = try Fixture.open(&report.counts);
    defer fixture.close();
    report.owner_pid = fixture.pid;
    report.window = windows.number(fixture.host);
    report.edit = windows.number(fixture.edit);
    try fixture.show();
    try dispatchFor(fixture, 125);
    for ([_]c_int{ win.VK_CONTROL, win.VK_MENU, win.VK_SHIFT, win.VK_LWIN, win.VK_RWIN }) |key|
        if (win.GetAsyncKeyState(key) < 0) return error.ImeFixtureModifierHeld;

    const previous = try profiles.active();
    report.active_before_is_microsoft = knownIme(previous);
    if (previous.langid != ja) return error.JapaneseInputLanguageInactive;
    report.original_profile_open = try fixture.readOpen();
    const switch_needed = !knownIme(previous);
    defer restoreProfile(fixture, profiles, previous, switch_needed and report.profile_activation_hresult == tsf.S_OK, report) catch |failure| recordRestoreFailure(report, failure);
    if (switch_needed) {
        try fixture.front();
        report.profile_activation_hresult = profiles.selectStock();
        if (report.profile_activation_hresult != tsf.S_OK) return error.MicrosoftImeActivationFailed;
        try dispatchFor(fixture, 125);
        if (!knownIme(try profiles.active())) return error.MicrosoftImeNotActive;
    }
    report.before_open = try fixture.snapshot(profiles);
    defer restoreOpen(fixture, report.before_open.?.open, report) catch |failure| recordRestoreFailure(report, failure);
    try fixture.front();
    if (report.before_open.?.open) {
        try fixture.setOpen(false);
        try dispatchFor(fixture, 100);
    }
    report.closed_baseline = try fixture.snapshot(profiles);
    if (report.closed_baseline.?.open or !report.closed_baseline.?.microsoft_ime) return error.MicrosoftImeBaselineNotClosed;
    try fixture.setOpen(true);
    try dispatchFor(fixture, 100);
    report.opened = try fixture.snapshot(profiles);
    if (!report.opened.?.open or !report.opened.?.microsoft_ime) return error.MicrosoftImeDidNotOpen;

    try fixture.front();
    try input.insert(alloc, fixture.host, literal);
    var buffer: [128]u16 = undefined;
    const deadline = win.GetTickCount64() + 4500;
    while (win.GetTickCount64() < deadline) {
        try dispatchFor(fixture, 20);
        if (!(try fixture.readOpen()) and std.mem.eql(u16, try fixture.text(&buffer), expected)) break;
    }
    try dispatchFor(fixture, 160);
    report.after_insert = try fixture.snapshot(profiles);
    const value = try fixture.text(&buffer);
    report.actual_utf16 = try owned.dupe(u16, value);
    report.actual_text = std.unicode.utf16LeToUtf8Alloc(owned, value) catch null;
    if (report.after_insert.?.open or !report.after_insert.?.microsoft_ime) return error.MicrosoftImeDidNotClose;
    if (!std.mem.eql(u16, value, expected)) return error.ImeLiteralTextMismatch;
    if (report.counts.enter_down != 0 or report.counts.enter_up != 0 or report.counts.carriage_or_line_feed != 0)
        return error.UnexpectedEnterInImeFixture;
}

fn recordRestoreFailure(report: *Report, failure: anyerror) void {
    if (report.restore_failure == null) report.restore_failure = @errorName(failure);
}

fn restoreOpen(fixture: Fixture, open: bool, report: *Report) !void {
    if (try fixture.readOpen() != open) {
        try fixture.setOpen(open);
        if (win.GetForegroundWindow() == fixture.host and win.GetFocus() == fixture.edit) try dispatchFor(fixture, 100);
    }
    report.restored_open = (try fixture.readOpen()) == open;
    if (!report.restored_open.?) return error.ImeOpenStateNotRestored;
}

fn restoreProfile(fixture: Fixture, profiles: Profiles, previous: tsf.TF_INPUTPROCESSORPROFILE, switched: bool, report: *Report) !void {
    if (!fixture.ownsBoth()) return error.ImeFixtureWindowNotOwned;
    if (switched) {
        if (profiles.selectPrevious(previous) != tsf.S_OK) return error.ImeProfileNotRestored;
        if (win.GetForegroundWindow() == fixture.host) try dispatchFor(fixture, 125);
    }
    const current = try profiles.active();
    report.restored_profile = current.dwProfileType == previous.dwProfileType and current.langid == previous.langid and
        std.meta.eql(current.clsid, previous.clsid) and std.meta.eql(current.guidProfile, previous.guidProfile) and current.hkl == previous.hkl;
    if (!report.restored_profile.?) return error.ImeProfileNotRestored;
    report.restored_original_open = (try fixture.readOpen()) == report.original_profile_open.?;
    if (!report.restored_original_open.?) return error.OriginalImeOpenStateChanged;
}

fn dispatchFor(fixture: Fixture, delay: u32) !void {
    const until = win.GetTickCount64() + delay;
    var message: win.MSG = undefined;
    while (true) {
        try fixture.front();
        while (win.PeekMessageW(&message, null, 0, 0, win.PM_REMOVE) != 0) {
            if (message.message == win.WM_QUIT) return error.ImeFixtureClosed;
            _ = win.TranslateMessage(&message);
            _ = win.DispatchMessageW(&message);
        }
        const now = win.GetTickCount64();
        if (now >= until) return;
        _ = win.MsgWaitForMultipleObjectsEx(0, null, @intCast(until - now), win.QS_ALLINPUT, win.MWMO_INPUTAVAILABLE);
    }
}

fn hostProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    if (message == win.WM_CLOSE) {
        win.PostQuitMessage(0);
        return 0;
    }
    return win.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn editProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: win.UINT_PTR, data: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
    const counts: *Counts = @ptrFromInt(data);
    switch (message) {
        win.WM_KEYDOWN, win.WM_SYSKEYDOWN => if (wparam == win.VK_RETURN) {
            counts.enter_down += 1;
        },
        win.WM_KEYUP, win.WM_SYSKEYUP => if (wparam == win.VK_RETURN) {
            counts.enter_up += 1;
        },
        win.WM_CHAR, win.WM_IME_CHAR => if (wparam == '\r' or wparam == '\n') {
            counts.carriage_or_line_feed += 1;
        },
        win.WM_IME_NOTIFY => if (wparam == tsf.IMN_SETOPENSTATUS) {
            counts.open_status_notifications += 1;
        },
        win.WM_NCDESTROY => _ = win.RemoveWindowSubclass(hwnd, editProc, id),
        else => {},
    }
    return win.DefSubclassProc(hwnd, message, wparam, lparam);
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "provider selection validates both Microsoft identifiers and the Japanese profile type" {
    var value = std.mem.zeroes(tsf.TF_INPUTPROCESSORPROFILE);
    value.langid = ja;
    value.dwProfileType = tsf.TF_PROFILETYPE_INPUTPROCESSOR;
    value.clsid = microsoft_ime;
    value.guidProfile = japanese_profile;
    try std.testing.expect(knownIme(value));
    value.guidProfile.Data1 +%= 1;
    try std.testing.expect(!knownIme(value));
}

test {
    _ = input;
}
