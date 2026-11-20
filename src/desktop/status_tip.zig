const std = @import("std");
const windows = @import("win.zig");
const win = windows.api;

pub const StatusTip = struct {
    window: win.HWND = null,
    font: windows.GuiFont = .{},
    deadline: ?u64 = null,

    pub fn show(self: *StatusTip, owner: win.HWND, message: []const u8, now: u64, duration_ms: u32) !void {
        if (message.len == 0) {
            self.close();
            return;
        }
        const dpi = windows.Dpi.system();
        if (self.window == null) {
            const style = @as(win.DWORD, 0x8000_0000) | @as(win.DWORD, win.WS_BORDER) | @as(win.DWORD, win.SS_NOPREFIX);
            self.window = win.CreateWindowExW(
                win.WS_EX_NOACTIVATE | win.WS_EX_TOOLWINDOW | win.WS_EX_LAYERED | win.WS_EX_TRANSPARENT,
                windows.wide("STATIC"),
                windows.wide(""),
                style,
                0,
                0,
                0,
                0,
                owner,
                null,
                win.GetModuleHandleW(null),
                null,
            ) orelse return error.CreateStatusTip;
            errdefer self.close();
            if (win.SetLayeredWindowAttributes(self.window, 0, 255, win.LWA_ALPHA) == 0)
                return error.StatusTipTransparency;
            self.font = try windows.GuiFont.init(dpi);
            self.font.apply(self.window);
        }
        errdefer self.close();
        const monitor = win.MonitorFromWindow(win.GetForegroundWindow(), win.MONITOR_DEFAULTTOPRIMARY);
        var info = std.mem.zeroes(win.MONITORINFO);
        info.cbSize = @sizeOf(win.MONITORINFO);
        if (win.GetMonitorInfoW(monitor, &info) == 0) return error.StatusTipWorkArea;
        const area = info.rcWork;
        const margin = dpi.pixels(14);
        const width = @max(1, @min(dpi.pixels(430), area.right - area.left - 2 * margin));
        const height = @max(1, @min(dpi.pixels(54), area.bottom - area.top - 2 * margin));
        windows.setText(self.window, message);
        if (win.SetWindowPos(self.window, win.HWND_TOPMOST, area.right - margin - width, area.bottom - margin - height, width, height, win.SWP_NOACTIVATE | win.SWP_SHOWWINDOW) == 0)
            return error.ShowStatusTip;
        self.deadline = if (duration_ms == 0) null else now + duration_ms;
    }

    pub fn close(self: *StatusTip) void {
        if (self.window != null) _ = win.DestroyWindow(self.window);
        self.font.deinit();
        self.* = .{};
    }

    pub fn expire(self: *StatusTip, now: u64) void {
        const deadline = self.deadline orelse return;
        if (deadline <= now) self.close();
    }
};

test "status messages expire from their latest replacement, unless persistent or cleared" {
    var tip: StatusTip = .{};
    defer tip.close();
    const foreground = win.GetForegroundWindow();
    try tip.show(null, "old", 0, 150);
    try tip.show(null, "new", 50, 500);
    tip.expire(300);
    const caption = try windows.text(tip.window, std.testing.allocator);
    defer std.testing.allocator.free(caption);
    try std.testing.expectEqualStrings("new", caption);
    try std.testing.expect(win.IsWindowVisible(tip.window) != 0);
    try std.testing.expectEqual(foreground, win.GetForegroundWindow());
    tip.expire(550);
    try std.testing.expect(tip.window == null);

    try tip.show(null, "temporary", 550, 150);
    try tip.show(null, "waiting", 550, 0);
    tip.expire(800);
    try std.testing.expect(win.IsWindowVisible(tip.window) != 0);
    try tip.show(null, "", 800, 0);
    try std.testing.expect(tip.window == null);
}
