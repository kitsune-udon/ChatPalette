const std = @import("std");
const windows = @import("win.zig");
const win = windows.api;
const shortcuts = @import("shortcuts.zig");

const allocator = std.heap.page_allocator;
const class = windows.wide("ChatPalette.ReactionProgress");
const stop_id = 1;
pub const wm_present = win.WM_APP + 18;
pub const wm_stop = win.WM_APP + 19;
pub const Phase = enum { running, stopping, finished };

pub const Reason = enum {
    completed,
    stopped,
    unknown,
    wrong_window,
    changed,
    not_registered,
    menu_closed,
    unsupported,
    unavailable,
    sync_failed,
    save_failed,
    saved,
    saved_sync_failed,
    ready,

    pub fn fromReply(state: []const u8) Reason {
        return std.meta.stringToEnum(Reason, state) orelse .unavailable;
    }

    fn message(self: Reason) []const u8 {
        return switch (self) {
            .completed => "リアクションの操作が完了しました。",
            .stopped => "中止しました。",
            .unknown => "操作結果を確認できませんでした。重複防止のため自動再送しません。",
            .wrong_window => "操作先が変わったため中止しました。",
            .changed => "動画またはタブが変わったため中止しました。",
            .not_registered => "このブラウザーのボタン設定が必要です。管理・ヘルプから設定できます。",
            .menu_closed => "登録したメニューが見つかりません。♡にマウスを重ねて5種類を表示してください。",
            .unsupported => "リアクションボタンを確認できませんでした。♡のメニューを開いてください。",
            .unavailable => "動画またはリアクションボタンを確認できませんでした。",
            .sync_failed => "登録情報をワーカーへ反映できなかったため、操作を中止しました。次回の操作時に再同期します。",
            .save_failed => "登録を保存できませんでした。以前の登録を保持しています。",
            .saved => "リアクションボタンを登録しました。「送らずに確認」で試せます。",
            .saved_sync_failed => "登録を保存しました。次回の操作時にワーカーへ再同期します。",
            .ready => "5種類のリアクションを確認しました。送信はしていません。",
        };
    }
};

pub const Counts = struct {
    completed: u32,
    total: u32,
    mean_ms: ?u64,

    pub fn text(self: Counts, buffer: []u8) ![]const u8 {
        return if (self.mean_ms) |ms|
            std.fmt.bufPrint(buffer, "操作済み {d} / {d} 回（平均開始間隔 {d} ms）", .{ self.completed, self.total, ms })
        else
            std.fmt.bufPrint(buffer, "操作済み {d} / {d} 回", .{ self.completed, self.total });
    }
};

pub const Result = struct {
    reason: Reason,
    counts: ?Counts = null,
    detail: ?[]u8 = null,
    stage: enum { queued, finished } = .finished,

    pub fn init(reason: Reason, counts: ?Counts, detail: []const u8) Result {
        return .{ .reason = reason, .counts = counts, .detail = if (detail.len == 0) null else allocator.dupe(u8, detail) catch null };
    }

    pub fn quickStart(reason: Reason, detail: []const u8) Result {
        var result = init(reason, .{ .completed = 0, .total = 0, .mean_ms = null }, detail);
        result.stage = .queued;
        return result;
    }

    pub fn deinit(self: Result) void {
        if (self.detail) |owned| allocator.free(owned);
    }

    pub fn summary(self: Result, buffer: []u8) []const u8 {
        const reason = self.reason.message();
        if (self.stage == .queued)
            return std.fmt.bufPrint(buffer, "{s}\r\nショートカットの開始前に終了しました。操作済み 0 回。", .{reason}) catch reason;
        const counts = self.counts orelse return reason;
        var count_buffer: [120]u8 = undefined;
        const count_text = counts.text(&count_buffer) catch return reason;
        return std.fmt.bufPrint(buffer, "{s}\r\n{s}\r\nYouTube側で受理された回数は未確認です。", .{ reason, count_text }) catch reason;
    }

    pub fn document(self: Result, alloc: std.mem.Allocator) ![]u8 {
        var buffer: [600]u8 = undefined;
        return std.fmt.allocPrint(alloc, "{s}\r\n\r\n調査用の詳細\r\n{s}", .{
            self.summary(&buffer), self.detail orelse "調査用の詳細はありません。",
        });
    }
};

pub const Overlay = struct {
    window: win.HWND = null,
    font: windows.GuiFont = .{},
    summary: win.HWND = null,
    hint: win.HWND = null,
    stop: win.HWND = null,

    pub fn open(self: *Overlay, host: win.HWND) !void {
        if (self.window != null) return;
        const owner = host orelse return error.CreateReactionProgress;
        var wc = std.mem.zeroes(win.WNDCLASSW);
        wc.hInstance = win.GetModuleHandleW(null);
        wc.lpfnWndProc = handle;
        wc.lpszClassName = class;
        wc.hbrBackground = win.GetSysColorBrush(win.COLOR_WINDOW);
        wc.hCursor = win.LoadCursorW(null, @ptrFromInt(32512));
        if (win.RegisterClassW(&wc) == 0 and win.GetLastError() != win.ERROR_CLASS_ALREADY_EXISTS) return error.RegisterReactionProgress;
        const border: win.DWORD = win.WS_BORDER;
        const dpi = windows.Dpi.system();
        self.window = win.CreateWindowExW(win.WS_EX_NOACTIVATE | win.WS_EX_TOOLWINDOW | win.WS_EX_TOPMOST, class, windows.wide("リアクションの進捗"), 0x8000_0000 | border, dpi.pixels(20), dpi.pixels(20), dpi.pixels(400), dpi.pixels(228), null, null, wc.hInstance, null) orelse return error.CreateReactionProgress;
        errdefer self.close();
        self.font = try windows.GuiFont.init(dpi);
        _ = try control(self.window, dpi, "STATIC", "リアクションの進捗", 14, 12, 370, 22, 0);
        self.summary = try control(self.window, dpi, "STATIC", "", 14, 42, 370, 86, 0);
        self.hint = try control(self.window, dpi, "STATIC", "", 14, 136, 370, 38, 0);
        self.stop = try control(self.window, dpi, "BUTTON", "停止", 14, 180, 120, 30, stop_id);
        self.font.applyChildren(self.window);
        if (win.SetWindowSubclass(self.stop, stopButton, stop_id, @intFromPtr(owner)) == 0)
            return error.CreateReactionStopButton;
    }

    pub fn close(self: *Overlay) void {
        if (self.window != null) _ = win.DestroyWindow(self.window);
        self.font.deinit();
        self.* = .{};
    }

    pub fn update(self: Overlay, message: []const u8, keys: shortcuts.Bindings, state: Phase) bool {
        if (self.window == null) return false;
        var stop_buffer: [30]u8 = undefined;
        var palette_buffer: [30]u8 = undefined;
        var hint_buffer: [240]u8 = undefined;
        const stop = shortcuts.label(keys[@intFromEnum(shortcuts.Action.stop)], &stop_buffer);
        const palette = shortcuts.label(keys[@intFromEnum(shortcuts.Action.palette)], &palette_buffer);
        const hint = switch (state) {
            .running => std.fmt.bufPrint(&hint_buffer, "{s} で停止　{s} で進捗を表示", .{ stop, palette }) catch unreachable,
            .stopping => "現在の操作結果を確認しています。",
            .finished => "4秒後に閉じます。結果は「管理・ヘルプ」から確認できます。",
        };
        const summary_updated = windows.setTextChecked(self.summary, message);
        const hint_updated = windows.setTextChecked(self.hint, hint);
        _ = win.EnableWindow(self.stop, @intFromBool(state == .running));
        _ = win.ShowWindow(self.stop, if (state == .finished) win.SW_HIDE else win.SW_SHOWNA);
        return summary_updated and hint_updated;
    }

    pub fn show(self: Overlay) void {
        _ = self.showChecked();
    }

    pub fn showChecked(self: Overlay) bool {
        if (self.window == null) return false;
        const shown = win.SetWindowPos(self.window, win.HWND_TOPMOST, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE | win.SWP_SHOWWINDOW);
        return shown != 0 and win.IsWindowVisible(self.window) != 0;
    }

    pub fn hide(self: Overlay) void {
        if (self.window != null) _ = win.ShowWindow(self.window, win.SW_HIDE);
    }
};

fn control(parent: win.HWND, dpi: windows.Dpi, comptime kind: []const u8, comptime text: []const u8, x: c_int, y: c_int, width: c_int, height: c_int, id: usize) !win.HWND {
    return win.CreateWindowExW(0, windows.wide(kind), windows.wide(text), win.WS_CHILD | win.WS_VISIBLE, dpi.pixels(x), dpi.pixels(y), dpi.pixels(width), dpi.pixels(height), parent, if (id != 0) @ptrFromInt(id) else null, win.GetModuleHandleW(null), null) orelse error.CreateReactionProgressControl;
}

fn handle(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    return switch (message) {
        win.WM_MOUSEACTIVATE => win.MA_NOACTIVATE,
        win.WM_CLOSE => blk: {
            _ = win.ShowWindow(hwnd, win.SW_HIDE);
            break :blk 0;
        },
        else => win.DefWindowProcW(hwnd, message, wparam, lparam),
    };
}

fn stopButton(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: win.UINT_PTR, host: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
    switch (message) {
        win.WM_MOUSEACTIVATE => return win.MA_NOACTIVATE,
        win.WM_LBUTTONDOWN, win.BM_CLICK => {
            // The button's default pointer handler can request focus. Stopping never needs focus.
            if (win.IsWindowEnabled(hwnd) != 0) _ = win.SendMessageW(@ptrFromInt(host), wm_stop, 0, 0);
            return 0;
        },
        win.WM_LBUTTONUP, win.WM_LBUTTONDBLCLK => return 0,
        win.WM_NCDESTROY => _ = win.RemoveWindowSubclass(hwnd, stopButton, id),
        else => {},
    }
    return win.DefSubclassProc(hwnd, message, wparam, lparam);
}

test "reaction results distinguish an unknown operation from a stop and preserve details" {
    var detail = "fixture detail".*;
    const result = Result.init(.unknown, .{ .completed = 2, .total = 10, .mean_ms = 201 }, &detail);
    defer result.deinit();
    detail[0] = 'x';
    const document = try result.document(std.testing.allocator);
    defer std.testing.allocator.free(document);
    try std.testing.expect(std.mem.indexOf(u8, document, "自動再送しません") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "操作済み 2 / 10 回（平均開始間隔 201 ms）") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "fixture detail") != null);
    try std.testing.expectEqual(Reason.menu_closed, Reason.fromReply("menu_closed"));
    try std.testing.expect(!std.mem.eql(u8, Reason.stopped.message(), Reason.unknown.message()));
    var key_buffer: [30]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+F12", shortcuts.label(try shortcuts.parse("^+F12"), &key_buffer));
}
