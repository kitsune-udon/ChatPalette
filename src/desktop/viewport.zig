const std = @import("std");
const windows = @import("win.zig");
const win = windows.api;

pub const wm_focus_changed = win.WM_APP + 55;
pub const wm_reflow = win.WM_APP + 56;

pub fn minimumTrack(window: win.HWND, dpi: windows.Dpi, limits: *win.MINMAXINFO) void {
    // The legacy minimum is a DPI-scaled client size. Its outer frame
    // should stay fixed while the viewport's scrollbars appear or disappear.
    const client = dpi.pixels(160);
    var outer = win.RECT{ .left = 0, .top = 0, .right = client, .bottom = client };
    const style: u32 = @bitCast(win.GetWindowLongW(window, win.GWL_STYLE));
    const ex_style: u32 = @bitCast(win.GetWindowLongW(window, win.GWL_EXSTYLE));
    const frame = style & ~@as(u32, win.WS_VSCROLL | win.WS_HSCROLL);
    if (win.AdjustWindowRectExForDpi(&outer, frame, @intFromBool(win.GetMenu(window) != null), ex_style, dpi.value) == 0) return;
    const area = windows.workArea(window);
    const width = if (area) |work| work.right - work.left else std.math.maxInt(i32);
    const height = if (area) |work| work.bottom - work.top else std.math.maxInt(i32);
    limits.ptMinTrackSize.x = trackAxis(outer.right - outer.left, limits.ptMinTrackSize.x, limits.ptMaxTrackSize.x, width);
    limits.ptMinTrackSize.y = trackAxis(outer.bottom - outer.top, limits.ptMinTrackSize.y, limits.ptMaxTrackSize.y, height);
}

fn trackAxis(requested: i32, system_minimum: i32, system_maximum: i32, work_area: i32) i32 {
    const ceiling = if (system_maximum > 0) @min(system_maximum, work_area) else work_area;
    return @max(system_minimum, @min(requested, ceiling));
}

pub fn trackFocus(child: win.HWND, parent: win.HWND, styles: win.DWORD) !void {
    if (styles & win.WS_TABSTOP == 0) return;
    if (win.SetWindowSubclass(child, focusProcedure, 1, windows.number(parent)) == 0) return error.TrackViewportFocus;
}

fn focusProcedure(child: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: usize, parent: usize) callconv(.winapi) win.LRESULT {
    if (message == win.WM_NCDESTROY) _ = win.RemoveWindowSubclass(child, focusProcedure, id);
    const result = win.DefSubclassProc(child, message, wparam, lparam);
    if (message == win.WM_SETFOCUS and win.GetFocus() == child)
        _ = win.SendMessageW(@ptrFromInt(parent), wm_focus_changed, 0, 0);
    return result;
}

pub const Viewport = struct {
    x: i32 = 0,
    y: i32 = 0,
    owner: win.HWND = null,
    updating: bool = false,
    repaint: bool = false,
    follow_focus: bool = false,
    pending_scroll: ?Position = null,
    posted: bool = false,
    scroll_revision: u64 = 0,
    const Position = struct { x: i32, y: i32 };

    pub fn arrange(self: *Viewport, window: win.HWND, owner: anytype, comptime draw: fn (@TypeOf(owner)) void) void {
        if (self.owner != window) self.* = .{ .owner = window };
        if (self.updating) {
            self.repaint = true;
            return;
        }
        self.updating = true;
        for (0..2) |_| {
            self.repaint = false;
            if (self.pending_scroll) |position| {
                self.x = position.x;
                self.y = position.y;
                self.pending_scroll = null;
            }
            var before: win.RECT = undefined;
            const measured = win.GetWindowRect(window, &before) != 0;
            draw(owner);
            if (self.owner != window) return;
            if (win.IsWindow(window) == 0) {
                self.* = .{};
                return;
            }
            var after: win.RECT = undefined;
            if (measured and win.GetWindowRect(window, &after) != 0 and
                (before.right - before.left != after.right - after.left or before.bottom - before.top != after.bottom - after.top))
                self.repaint = true;
            if (!self.repaint and self.follow_focus) {
                self.follow_focus = false;
                self.repaint = self.revealFocusNow(window);
            }
            if (!self.repaint) break;
        }
        self.updating = false;
        if (self.repaint and !self.posted) self.posted = win.PostMessageW(window, wm_reflow, 0, 0) != 0;
    }

    pub fn takeReflow(self: *Viewport, window: win.HWND) bool {
        if (!self.posted or self.owner != window) return false;
        self.posted = false;
        return self.repaint;
    }

    fn acceptScroll(self: *Viewport, destination: Position, changed: bool) bool {
        self.scroll_revision +%= 1;
        self.follow_focus = false;
        if (self.updating) {
            if (changed) self.pending_scroll = destination;
        } else {
            self.pending_scroll = null;
            self.x = destination.x;
            self.y = destination.y;
        }
        return changed;
    }

    fn scrollPosition(self: Viewport) Position {
        return self.pending_scroll orelse .{ .x = self.x, .y = self.y };
    }

    pub const Size = struct { width: i32, height: i32 };
    pub const Compact = struct { below_width: i32, minimum_height: i32 };

    pub fn layout(self: *Viewport, window: win.HWND, dpi: windows.Dpi, normal: Size, compact: ?Compact) ?Size {
        var client: win.RECT = undefined;
        if (win.GetClientRect(window, &client) == 0 or client.right <= 0 or client.bottom <= 0) return null;
        const style: u32 = @bitCast(win.GetWindowLongW(window, win.GWL_STYLE));
        const vertical = win.GetSystemMetricsForDpi(win.SM_CXVSCROLL, dpi.value);
        const horizontal = win.GetSystemMetricsForDpi(win.SM_CYHSCROLL, dpi.value);
        const available: Size = .{
            .width = client.right + if (style & win.WS_VSCROLL != 0) vertical else @as(i32, 0),
            .height = client.bottom + if (style & win.WS_HSCROLL != 0) horizontal else @as(i32, 0),
        };
        const visible, const content = measure(dpi, available, normal, compact, vertical, horizontal);
        setBar(window, win.SB_HORZ, &self.x, visible.width, content.width);
        setBar(window, win.SB_VERT, &self.y, visible.height, content.height);
        return content;
    }

    pub fn place(self: Viewport, dpi: windows.Dpi, hwnd: win.HWND, x: i32, y: i32, width: i32, height: i32) void {
        if (hwnd == null) return;
        const left = dpi.pixels(x);
        const top = dpi.pixels(y);
        _ = win.MoveWindow(hwnd, left - self.x, top - self.y, dpi.pixels(x + width) - left, dpi.pixels(y + height) - top, 1);
    }

    pub fn scroll(self: *Viewport, window: win.HWND, bar: c_int, wparam: win.WPARAM, dpi: windows.Dpi) bool {
        const info = scrollInfo(window, bar) orelse return false;
        var destination = self.scrollPosition();
        const offset = if (bar == win.SB_HORZ) &destination.x else &destination.y;
        const page: i32 = @intCast(info.nPage);
        const line = dpi.pixels(24);
        const next = switch (windows.low(wparam)) {
            win.SB_LINEUP => offset.* - line,
            win.SB_LINEDOWN => offset.* + line,
            win.SB_PAGEUP => offset.* - page,
            win.SB_PAGEDOWN => offset.* + page,
            win.SB_TOP => info.nMin,
            win.SB_BOTTOM => info.nMax,
            win.SB_THUMBTRACK => info.nTrackPos,
            win.SB_THUMBPOSITION => if (info.nMax <= std.math.maxInt(u16)) @as(i32, windows.high(wparam)) else offset.*,
            else => return false,
        };
        const changed = moveOffset(offset, info, next);
        return self.acceptScroll(destination, changed);
    }

    pub fn wheel(self: *Viewport, window: win.HWND, wparam: win.WPARAM) bool {
        const info = scrollInfo(window, win.SB_VERT) orelse return false;
        // Match the legacy viewport: one wheel notch is 96 client pixels.
        const delta: i16 = @bitCast(windows.high(wparam));
        var destination = self.scrollPosition();
        const changed = moveOffset(&destination.y, info, destination.y - win.MulDiv(delta, 96, win.WHEEL_DELTA));
        return self.acceptScroll(destination, changed);
    }

    pub fn revealFocus(self: *Viewport, window: win.HWND) bool {
        if (self.owner != window or window == null) return false;
        if (self.updating or self.repaint) {
            self.pending_scroll = null;
            self.follow_focus = true;
            return false;
        }
        return self.revealFocusNow(window);
    }

    fn revealFocusNow(self: *Viewport, window: win.HWND) bool {
        const focus = win.GetFocus();
        if (focus == null or win.IsChild(window, focus) == 0) return false;
        var child: win.RECT = undefined;
        var client: win.RECT = undefined;
        if (win.GetWindowRect(focus, &child) == 0 or win.GetClientRect(window, &client) == 0) return false;
        _ = win.MapWindowPoints(null, window, @ptrCast(&child), 2);
        const dx = revealOffset(child.left, child.right, client.right);
        const dy = revealOffset(child.top, child.bottom, client.bottom);
        self.x += dx;
        self.y += dy;
        return dx != 0 or dy != 0;
    }

    fn setBar(window: win.HWND, bar: c_int, offset: *i32, visible: i32, content: i32) void {
        offset.* = std.math.clamp(offset.*, 0, content - visible);
        var info = std.mem.zeroes(win.SCROLLINFO);
        info.cbSize = @sizeOf(win.SCROLLINFO);
        info.fMask = win.SIF_RANGE | win.SIF_PAGE | win.SIF_POS;
        info.nMax = content - 1;
        info.nPage = @intCast(visible);
        info.nPos = offset.*;
        _ = win.SetScrollInfo(window, bar, &info, 1);
    }
};

fn scrollInfo(window: win.HWND, bar: c_int) ?win.SCROLLINFO {
    var info = std.mem.zeroes(win.SCROLLINFO);
    info.cbSize = @sizeOf(win.SCROLLINFO);
    info.fMask = win.SIF_ALL;
    return if (win.GetScrollInfo(window, bar, &info) != 0) info else null;
}

fn moveOffset(offset: *i32, info: win.SCROLLINFO, next: i32) bool {
    if (info.nPage == 0) return false;
    const clipped = std.math.clamp(next, info.nMin, @max(info.nMin, info.nMax + 1 - @as(i32, @intCast(info.nPage))));
    if (offset.* == clipped) return false;
    offset.* = clipped;
    return true;
}

fn measure(dpi: windows.Dpi, available: Viewport.Size, normal: Viewport.Size, compact: ?Viewport.Compact, vertical: i32, horizontal: i32) struct { Viewport.Size, Viewport.Size } {
    var minimum: Viewport.Size = .{ .width = dpi.pixels(normal.width), .height = dpi.pixels(normal.height) };
    var visible = pageSize(available, minimum, vertical, horizontal);
    if (compact) |rule| {
        if (visible.width < dpi.pixels(rule.below_width)) {
            minimum.height = @max(minimum.height, dpi.pixels(rule.minimum_height));
            visible = pageSize(available, minimum, vertical, horizontal);
        }
    }
    return .{ visible, .{ .width = @max(minimum.width, visible.width), .height = @max(minimum.height, visible.height) } };
}

fn pageSize(available: Viewport.Size, minimum: Viewport.Size, vertical: i32, horizontal: i32) Viewport.Size {
    var width = available.width;
    var height = available.height;
    if (width < minimum.width) height = @max(1, available.height - horizontal);
    if (height < minimum.height) width = @max(1, available.width - vertical);
    if (width < minimum.width) height = @max(1, available.height - horizontal);
    return .{ .width = width, .height = height };
}

fn revealOffset(near: i32, far: i32, extent: i32) i32 {
    if (far - near >= extent or near < 0) return near;
    return @max(far - extent, 0);
}

test "one scrollbar reserves space for the other only when necessary" {
    const minimum: Viewport.Size = .{ .width = 344, .height = 405 };
    try std.testing.expectEqual(Viewport.Size{ .width = 343, .height = 388 }, pageSize(.{ .width = 360, .height = 405 - 1 }, minimum, 17, 16));
    try std.testing.expectEqual(Viewport.Size{ .width = 360, .height = 405 }, pageSize(.{ .width = 360, .height = 405 }, minimum, 17, 16));
    try std.testing.expectEqual(Viewport.Size{ .width = 340, .height = 424 }, pageSize(.{ .width = 340, .height = 440 }, minimum, 17, 16));
}

test "desktop DPI scales compact viewport thresholds and scrollbar pages once" {
    const dpi: windows.Dpi = .{ .value = 144 };
    const normal: Viewport.Size = .{ .width = 344, .height = 373 };
    const compact: Viewport.Compact = .{ .below_width = 535, .minimum_height = 405 };
    const width = dpi.pixels(compact.below_width);
    const height = dpi.pixels(normal.height);
    const wide_page, const wide_content = measure(dpi, .{ .width = width, .height = height }, normal, compact, 26, 24);
    try std.testing.expectEqual(wide_content, wide_page);
    const narrow_page, const narrow_content = measure(dpi, .{ .width = width - 1, .height = height }, normal, compact, 26, 24);
    try std.testing.expectEqual(width - 1 - 26, narrow_page.width);
    try std.testing.expectEqual(height, narrow_page.height);
    try std.testing.expectEqual(@as(i32, 608), narrow_content.height);
}

test "viewport minimum track preserves the OS floor and respects the available ceiling" {
    try std.testing.expectEqual(@as(i32, 192), trackAxis(192, 100, 1400, 1000));
    try std.testing.expectEqual(@as(i32, 212), trackAxis(192, 212, 1400, 1000));
    try std.testing.expectEqual(@as(i32, 180), trackAxis(192, 100, 180, 1000));
    try std.testing.expectEqual(@as(i32, 170), trackAxis(192, 100, 1400, 170));
    try std.testing.expectEqual(@as(i32, 100), trackAxis(192, 100, 1400, 60));
}
