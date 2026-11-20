const std = @import("std");
const win = @import("chatpalette").windows.api;
const ui = @import("clean_install_scenario.zig");

const WindowSize = struct { width: i32, height: i32 };
pub const TrackObservation = struct {
    window_dpi: u32,
    getminmaxinfo_px: WindowSize,
    constrained_resize_px: WindowSize,
};

fn resizeOwned(window: win.HWND, width: i32, height: i32) !void {
    const flags = win.SWP_NOACTIVATE | win.SWP_NOZORDER | win.SWP_NOMOVE | win.SWP_NOSENDCHANGING;
    if (win.SetWindowPos(window, null, 0, 0, width, height, flags) == 0) return error.CannotResizeProductWindow;
    // Fence the owned UI thread after SetWindowPos sourced its WM_SIZE.
    _ = try ui.message(window, win.WM_NULL, 0, 0);
}

pub fn windowExtent(window: win.HWND) !WindowSize {
    var bounds: win.RECT = undefined;
    if (win.GetWindowRect(window, &bounds) == 0) return error.CannotReadProductWindowBounds;
    return .{ .width = bounds.right - bounds.left, .height = bounds.bottom - bounds.top };
}

pub fn resizeWithTrackLimits(window: win.HWND, size: WindowSize) !void {
    const flags = win.SWP_NOACTIVATE | win.SWP_NOZORDER | win.SWP_NOMOVE;
    if (win.SetWindowPos(window, null, 0, 0, size.width, size.height, flags) == 0) return error.CannotResizeProductWindow;
    _ = try ui.message(window, win.WM_NULL, 0, 0);
}

pub fn observeMinimumTrack(window: win.HWND) !TrackObservation {
    const dpi = win.GetDpiForWindow(window);
    if (dpi == 0) return error.ProductWindowDpiMissing;
    const previous = win.SetThreadDpiAwarenessContext(win.GetWindowDpiAwarenessContext(window)) orelse
        return error.CannotMatchProductDpiCoordinates;
    defer _ = win.SetThreadDpiAwarenessContext(previous);
    const original = try windowExtent(window);
    errdefer resizeWithTrackLimits(window, original) catch {};
    const style: u32 = @bitCast(win.GetWindowLongW(window, win.GWL_STYLE));
    if (style & win.WS_THICKFRAME == 0) return error.ProductWindowHasNoResizeFrame;
    const ex_style: u32 = @bitCast(win.GetWindowLongW(window, win.GWL_EXSTYLE));
    const system_min: win.POINT = .{
        .x = win.GetSystemMetricsForDpi(win.SM_CXMINTRACK, dpi),
        .y = win.GetSystemMetricsForDpi(win.SM_CYMINTRACK, dpi),
    };
    var limits = std.mem.zeroes(win.MINMAXINFO);
    limits.ptMinTrackSize = system_min;
    limits.ptMaxTrackSize = .{
        .x = win.GetSystemMetricsForDpi(win.SM_CXMAXTRACK, dpi),
        .y = win.GetSystemMetricsForDpi(win.SM_CYMAXTRACK, dpi),
    };
    _ = try ui.message(window, win.WM_GETMINMAXINFO, 0, @bitCast(@intFromPtr(&limits)));

    const client = win.MulDiv(160, @intCast(dpi), 96);
    var frame = win.RECT{ .left = 0, .top = 0, .right = client, .bottom = client };
    if (win.AdjustWindowRectExForDpi(&frame, style & ~@as(u32, win.WS_VSCROLL | win.WS_HSCROLL), 0, ex_style, dpi) == 0)
        return error.CannotCalculateExpectedTrackFrame;
    const measured: WindowSize = .{ .width = limits.ptMinTrackSize.x, .height = limits.ptMinTrackSize.y };
    if (measured.width != @max(system_min.x, frame.right - frame.left) or
        measured.height != @max(system_min.y, frame.bottom - frame.top)) return error.ProductMinimumTrackMismatch;
    const requested: WindowSize = .{ .width = 1, .height = 1 };
    // Use normal window positioning so DefWindowProc applies WM_GETMINMAXINFO.
    try resizeWithTrackLimits(window, requested);
    const actual = try windowExtent(window);
    try resizeWithTrackLimits(window, original);
    if (!std.meta.eql(measured, actual)) return error.ProductResizeDidNotApplyMinimumTrack;
    return .{ .window_dpi = dpi, .getminmaxinfo_px = measured, .constrained_resize_px = actual };
}

pub fn clientContains(window: win.HWND, child: win.HWND, allow_oversized: bool) !bool {
    var rect: win.RECT = undefined;
    var client: win.RECT = undefined;
    if (win.GetWindowRect(child, &rect) == 0 or win.GetClientRect(window, &client) == 0) return error.CannotReadProductWindowBounds;
    _ = win.MapWindowPoints(null, window, @ptrCast(&rect), 2);
    return axisVisible(rect.left, rect.right, client.right, allow_oversized) and axisVisible(rect.top, rect.bottom, client.bottom, allow_oversized);
}

fn axisVisible(start: i32, end: i32, client: i32, allow_oversized: bool) bool {
    if (allow_oversized and end - start > client) return start == 0;
    return start >= 0 and end <= client;
}

pub fn verifyNarrowPalette(palette: win.HWND) !void {
    const find_focus = struct {
        fn get(window: win.HWND) !win.HWND {
            const thread = win.GetWindowThreadProcessId(window, null);
            var gui = std.mem.zeroes(win.GUITHREADINFO);
            gui.cbSize = @sizeOf(win.GUITHREADINFO);
            if (thread == 0 or win.GetGUIThreadInfo(thread, &gui) == 0 or gui.hwndFocus == null or win.IsChild(window, gui.hwndFocus) == 0)
                return error.ProductPaletteHasNoKeyboardFocus;
            return gui.hwndFocus;
        }
    }.get;
    try resizeOwned(palette, 292, 248);
    const defaults = try ui.control(palette, 114);
    if (try clientContains(palette, defaults, false)) return error.PaletteViewportWasNotNarrowed;
    var touched: usize = 0;
    for (0..14) |_| {
        const from = try find_focus(palette);
        if (from == defaults) break;
        if (win.PostMessageW(from, win.WM_KEYDOWN, win.VK_TAB, 1) == 0) return error.CannotQueuePaletteTab;
        const start = win.GetTickCount64();
        while (try find_focus(palette) == from) {
            if (win.GetTickCount64() - start >= 1200) return error.PaletteTabDidNotAdvance;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        _ = try ui.message(palette, win.WM_NULL, 0, 0);
        if (!try clientContains(palette, try find_focus(palette), true)) return error.PaletteTabStoppedOutsideViewport;
        touched += 1;
    }
    if (touched < 3 or try find_focus(palette) != defaults or !try clientContains(palette, defaults, false)) return error.PaletteDidNotRevealTabFocus;
    try resizeOwned(palette, 580, 665);
    try resizeOwned(palette, 292, 248);
    if (try find_focus(palette) != defaults or !try clientContains(palette, defaults, false)) return error.PaletteResizeLostFocusVisibility;
    try resizeOwned(palette, 580, 665);
}

pub fn verifyNarrowManagement(manager: win.HWND) !void {
    try resizeOwned(manager, 310, 278);
    const support = try ui.control(manager, 236);
    if (try clientContains(manager, support, false)) return error.ManagementViewportWasNotNarrowed;
    _ = try ui.message(manager, win.WM_VSCROLL, win.SB_BOTTOM, 0);
    _ = try ui.message(manager, win.WM_HSCROLL, win.SB_RIGHT, 0);
    if (!try clientContains(manager, support, false)) return error.ManagementActionsOutsideViewport;
    try resizeOwned(manager, 760, 620);
}
