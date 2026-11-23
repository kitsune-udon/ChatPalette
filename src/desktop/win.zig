const std = @import("std");

pub const api = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("NONAMELESSUNION", "1");
    // Win32 encodes handles as values. Avoid inferring pointee alignment from SDK tag structs.
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
    @cInclude("commctrl.h");
    @cInclude("commdlg.h");
    @cInclude("objbase.h");
});

// NO_STRICT leaves the Windows SDK callback untyped. Keep the WNDENUMPROC signature.
extern "user32" fn EnumChildWindows(api.HWND, *const fn (api.HWND, api.LPARAM) callconv(.winapi) api.BOOL, api.LPARAM) callconv(.winapi) api.BOOL;

pub fn wide(comptime value: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(value);
}

pub fn copyText(destination: []u16, source: []const u8) void {
    if (destination.len == 0) return;
    var iter = std.unicode.Utf8View.initUnchecked(source).iterator();
    var length: usize = 0;
    while (iter.nextCodepoint()) |point| {
        const needed: usize = if (point <= 0xffff) 1 else 2;
        if (length + needed >= destination.len) break;
        if (needed == 1) {
            destination[length] = @intCast(point);
        } else {
            const adjusted = point - 0x10000;
            destination[length] = @intCast(0xd800 + (adjusted >> 10));
            destination[length + 1] = @intCast(0xdc00 + (adjusted & 0x3ff));
        }
        length += needed;
    }
    destination[length] = 0;
}

pub fn recallOwnedWindow(window: api.HWND) void {
    if (window == null or api.IsWindow(window) == 0) return;
    var target = window;
    while (api.IsWindowEnabled(target) == 0) {
        const popup = api.GetWindow(target, api.GW_ENABLEDPOPUP);
        if (popup == null or popup == target or api.GetWindow(popup, api.GW_OWNER) != target or api.IsWindowVisible(popup) == 0) return;
        target = popup;
    }
    if (api.IsIconic(target) != 0) {
        _ = api.ShowWindow(target, api.SW_RESTORE);
    } else if (api.IsWindowVisible(target) == 0) {
        _ = api.ShowWindow(target, api.SW_SHOWNOACTIVATE);
    }
    _ = api.SetForegroundWindow(target);
}

/// Enable Per-Monitor DPI v2 awareness, falling back to system DPI awareness.
pub fn enableSystemDpi() !void {
    const pmv2 = api.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2;
    if (api.AreDpiAwarenessContextsEqual(api.GetThreadDpiAwarenessContext(), pmv2) != 0) return;
    if (api.SetProcessDpiAwarenessContext(pmv2) != 0) return;
    const system_ctx = api.DPI_AWARENESS_CONTEXT_SYSTEM_AWARE;
    if (api.AreDpiAwarenessContextsEqual(api.GetThreadDpiAwarenessContext(), system_ctx) != 0) return;
    if (api.SetProcessDpiAwarenessContext(system_ctx) != 0) return;
    if (api.GetLastError() != api.ERROR_ACCESS_DENIED) return error.SetSystemDpiAwareness;
    switch (api.GetAwarenessFromDpiAwarenessContext(api.GetThreadDpiAwarenessContext())) {
        api.DPI_AWARENESS_UNAWARE, api.DPI_AWARENESS_SYSTEM_AWARE, api.DPI_AWARENESS_PER_MONITOR_AWARE => {},
        else => return error.SetSystemDpiAwareness,
    }
}

pub fn surfaceBrush() api.HBRUSH {
    return api.GetSysColorBrush(api.COLOR_3DFACE);
}

pub fn handleCtlColor(message: api.UINT, wparam: api.WPARAM) ?api.LRESULT {
    if (message != api.WM_CTLCOLORSTATIC and message != api.WM_CTLCOLORBTN) return null;
    const hdc: api.HDC = @ptrFromInt(wparam);
    _ = api.SetBkColor(hdc, api.GetSysColor(api.COLOR_3DFACE));
    _ = api.SetTextColor(hdc, api.GetSysColor(api.COLOR_WINDOWTEXT));
    return @bitCast(number(surfaceBrush()));
}

pub const Dpi = struct {
    value: u32 = 96,

    pub fn system() Dpi {
        const dpi = api.GetDpiForSystem();
        return if (dpi == 0) .{} else .{ .value = dpi };
    }

    pub fn forWindow(hwnd: api.HWND) Dpi {
        if (hwnd == null) return system();
        const dpi = api.GetDpiForWindow(hwnd);
        return if (dpi == 0) system() else .{ .value = dpi };
    }

    pub fn fromDpiChanged(wparam: api.WPARAM) Dpi {
        const dpi: u32 = low(wparam);
        return if (dpi == 0) system() else .{ .value = dpi };
    }

    pub fn applyDpiChanged(hwnd: api.HWND, wparam: api.WPARAM, lparam: api.LPARAM) Dpi {
        const next = fromDpiChanged(wparam);
        if (lparam != 0) {
            const rect: *const api.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = api.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                api.SWP_NOZORDER | api.SWP_NOACTIVATE,
            );
        }
        return next;
    }

    pub fn pixels(self: Dpi, units: i32) i32 {
        return api.MulDiv(units, @intCast(self.value), 96);
    }

    pub fn fittingUnits(self: Dpi, dimension: i32) i32 {
        // Invert the positive MulDiv rounding so the result still fits in the measured pixels.
        return @intCast(@divFloor(@as(i64, dimension) * 96 + 47, self.value));
    }

    fn fontHeight(self: Dpi) i32 {
        return -api.MulDiv(10, @intCast(self.value), 72);
    }

    fn headingHeight(self: Dpi) i32 {
        return -api.MulDiv(11, @intCast(self.value), 72);
    }

    fn captionHeight(self: Dpi) i32 {
        return -api.MulDiv(9, @intCast(self.value), 72);
    }
};

pub const GuiFont = struct {
    handle: api.HFONT = null,
    heading: api.HFONT = null,
    caption: api.HFONT = null,
    line_height: i32 = 16,

    pub fn init(dpi: Dpi) !GuiFont {
        const body = createFont(dpi.fontHeight(), api.FW_NORMAL) orelse return error.CreateDesktopFont;
        errdefer _ = api.DeleteObject(body);
        const heading = createFont(dpi.headingHeight(), api.FW_SEMIBOLD) orelse return error.CreateDesktopFont;
        errdefer _ = api.DeleteObject(heading);
        const caption = createFont(dpi.captionHeight(), api.FW_NORMAL) orelse return error.CreateDesktopFont;
        errdefer _ = api.DeleteObject(caption);
        return .{
            .handle = body,
            .heading = heading,
            .caption = caption,
            .line_height = measureLineHeight(body, dpi.pixels(16)),
        };
    }

    pub fn reinit(self: *GuiFont, dpi: Dpi) !void {
        const next = try GuiFont.init(dpi);
        self.deinit();
        self.* = next;
    }

    pub fn deinit(self: *GuiFont) void {
        if (self.handle) |font| _ = api.DeleteObject(font);
        if (self.heading) |font| _ = api.DeleteObject(font);
        if (self.caption) |font| _ = api.DeleteObject(font);
        self.* = .{};
    }

    pub fn apply(self: GuiFont, window: api.HWND) void {
        _ = api.SendMessageW(window, api.WM_SETFONT, number(self.handle), 1);
    }

    pub fn applyHeading(self: GuiFont, window: api.HWND) void {
        if (window == null) return;
        _ = api.SendMessageW(window, api.WM_SETFONT, number(self.heading orelse self.handle), 1);
    }

    pub fn applyCaption(self: GuiFont, window: api.HWND) void {
        if (window == null) return;
        _ = api.SendMessageW(window, api.WM_SETFONT, number(self.caption orelse self.handle), 1);
    }

    pub fn applyChildren(self: GuiFont, window: api.HWND) void {
        _ = EnumChildWindows(window, applyChild, @bitCast(number(self.handle)));
    }

    fn applyChild(child: api.HWND, font: api.LPARAM) callconv(.winapi) api.BOOL {
        _ = api.SendMessageW(child, api.WM_SETFONT, @bitCast(font), 1);
        return 1;
    }

    fn createFont(height: i32, weight: c_int) api.HFONT {
        return api.CreateFontW(
            height,
            0,
            0,
            0,
            weight,
            0,
            0,
            0,
            api.DEFAULT_CHARSET,
            api.OUT_DEFAULT_PRECIS,
            api.CLIP_DEFAULT_PRECIS,
            api.CLEARTYPE_QUALITY,
            api.DEFAULT_PITCH,
            wide("Yu Gothic UI"),
        );
    }

    fn measureLineHeight(font: api.HFONT, fallback: i32) i32 {
        const dc = api.GetDC(null) orelse return fallback;
        defer _ = api.ReleaseDC(null, dc);
        const previous = api.SelectObject(dc, font);
        defer _ = api.SelectObject(dc, previous);
        var metrics = std.mem.zeroes(api.TEXTMETRICW);
        if (api.GetTextMetricsW(dc, &metrics) == 0) return fallback;
        return @max(1, metrics.tmHeight + metrics.tmExternalLeading);
    }
};

pub fn setText(hwnd: api.HWND, value: []const u8) void {
    const allocator = std.heap.page_allocator;
    const buffer = std.unicode.utf8ToUtf16LeAllocZ(allocator, value) catch return;
    defer allocator.free(buffer);
    _ = api.SetWindowTextW(hwnd, buffer);
}

pub fn setTextChecked(hwnd: api.HWND, value: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const buffer = std.unicode.utf8ToUtf16LeAllocZ(allocator, value) catch return false;
    defer allocator.free(buffer);
    // These controls are owned by this thread. Use their acknowledgement of the text update.
    return api.SendMessageW(hwnd, api.WM_SETTEXT, 0, @bitCast(@intFromPtr(buffer.ptr))) > 0;
}

pub fn text(hwnd: api.HWND, allocator: std.mem.Allocator) ![]const u8 {
    const size: usize = @intCast(api.GetWindowTextLengthW(hwnd));
    const buffer = try allocator.alloc(u16, size + 1);
    defer allocator.free(buffer);
    const actual = api.GetWindowTextW(hwnd, buffer.ptr, @intCast(buffer.len));
    return std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..@intCast(actual)]);
}

pub fn currentExecutable(allocator: std.mem.Allocator) ![:0]u16 {
    var buffer: [32768]u16 = undefined;
    const count = api.GetModuleFileNameW(null, &buffer, buffer.len);
    if (count == 0 or count >= buffer.len) return error.ExecutablePath;
    return allocator.dupeZ(u16, buffer[0..count]);
}

pub fn number(handle: ?*anyopaque) usize {
    return if (handle) |ptr| @intFromPtr(ptr) else 0;
}

pub fn low(value: usize) u16 {
    return @truncate(value);
}

pub fn high(value: usize) u16 {
    return @truncate(value >> 16);
}

pub fn workArea(window: api.HWND) ?api.RECT {
    var info = std.mem.zeroes(api.MONITORINFO);
    info.cbSize = @sizeOf(api.MONITORINFO);
    const monitor = api.MonitorFromWindow(window, api.MONITOR_DEFAULTTONEAREST);
    if (api.GetMonitorInfoW(monitor, &info) == 0) return null;
    return info.rcWork;
}

pub fn fitWindow(window: api.HWND, owner: api.HWND) void {
    const anchor = owner orelse window;
    var own: api.RECT = undefined;
    var reference: api.RECT = undefined;
    if (api.GetWindowRect(window, &own) == 0 or api.GetWindowRect(anchor, &reference) == 0) return;
    const area = workArea(anchor) orelse return;
    const width = @min(own.right - own.left, area.right - area.left);
    const height = @min(own.bottom - own.top, area.bottom - area.top);
    const left = if (owner != null) reference.left + @divTrunc(reference.right - reference.left - width, 2) else own.left;
    const top = if (owner != null) reference.top + @divTrunc(reference.bottom - reference.top - height, 2) else own.top;
    const x = std.math.clamp(left, area.left, area.right - width);
    const y = std.math.clamp(top, area.top, area.bottom - height);
    _ = api.SetWindowPos(window, null, x, y, width, height, api.SWP_NOZORDER | api.SWP_NOACTIVATE);
}

test "desktop DPI converts 96-unit layout and ten-point fonts at Windows scale factors" {
    const cases = [_]struct { dpi: u32, extent: i32, step: i32, font_height: i32 }{
        .{ .dpi = 96, .extent = 360, .step = 24, .font_height = -13 },
        .{ .dpi = 120, .extent = 450, .step = 30, .font_height = -17 },
        .{ .dpi = 144, .extent = 540, .step = 36, .font_height = -20 },
        .{ .dpi = 192, .extent = 720, .step = 48, .font_height = -27 },
    };
    for (cases) |record| {
        const dpi: Dpi = .{ .value = record.dpi };
        try std.testing.expectEqual(record.extent, dpi.pixels(360));
        try std.testing.expectEqual(@as(i32, 360), dpi.fittingUnits(record.extent));
        const edge = dpi.pixels(535);
        try std.testing.expectEqual(@as(i32, 535), dpi.fittingUnits(edge));
        try std.testing.expectEqual(@as(i32, 534), dpi.fittingUnits(edge - 1));
        try std.testing.expectEqual(record.step, dpi.pixels(24));
        try std.testing.expectEqual(record.font_height, dpi.fontHeight());
    }
    try std.testing.expectEqual(@as(u32, 144), Dpi.fromDpiChanged((@as(usize, 144) << 16) | 144).value);
    var fonts = try GuiFont.init(.{ .value = 96 });
    defer fonts.deinit();
    try std.testing.expect(fonts.handle != null);
    try std.testing.expect(fonts.heading != null);
    try std.testing.expect(fonts.caption != null);
    try std.testing.expect(fonts.line_height > 0);
    const old_height = fonts.line_height;
    try fonts.reinit(.{ .value = 192 });
    try std.testing.expect(fonts.line_height >= old_height);
}
