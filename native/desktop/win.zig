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

/// Match the legacy desktop: draw at system DPI and let Windows scale across monitors.
pub fn enableSystemDpi() !void {
    const context = api.DPI_AWARENESS_CONTEXT_SYSTEM_AWARE;
    if (api.AreDpiAwarenessContextsEqual(api.GetThreadDpiAwarenessContext(), context) != 0) return;
    if (api.SetProcessDpiAwarenessContext(context) != 0) return;
    if (api.GetLastError() != api.ERROR_ACCESS_DENIED) return error.SetSystemDpiAwareness;
    // Windows may have locked the process default before our entry point. Let
    // its unaware modes provide 96-unit coordinates. For a per-monitor process
    // default, create the desktop windows on a system-aware UI thread.
    switch (api.GetAwarenessFromDpiAwarenessContext(api.GetThreadDpiAwarenessContext())) {
        api.DPI_AWARENESS_UNAWARE, api.DPI_AWARENESS_SYSTEM_AWARE => {},
        api.DPI_AWARENESS_PER_MONITOR_AWARE => _ = api.SetThreadDpiAwarenessContext(context),
        else => return error.SetSystemDpiAwareness,
    }
}

pub const Dpi = struct {
    value: u32 = 96,

    pub fn system() Dpi {
        const dpi = api.GetDpiForSystem();
        return if (dpi == 0) .{} else .{ .value = dpi };
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
};

pub const GuiFont = struct {
    handle: api.HFONT = null,

    pub fn init(dpi: Dpi) !GuiFont {
        const font = api.CreateFontW(dpi.fontHeight(), 0, 0, 0, api.FW_NORMAL, 0, 0, 0, api.DEFAULT_CHARSET, api.OUT_DEFAULT_PRECIS, api.CLIP_DEFAULT_PRECIS, api.DEFAULT_QUALITY, api.DEFAULT_PITCH, wide("Yu Gothic UI")) orelse
            return error.CreateDesktopFont;
        return .{ .handle = font };
    }

    pub fn deinit(self: *GuiFont) void {
        if (self.handle) |font| _ = api.DeleteObject(font);
        self.handle = null;
    }

    pub fn apply(self: GuiFont, window: api.HWND) void {
        _ = api.SendMessageW(window, api.WM_SETFONT, number(self.handle), 1);
    }

    pub fn applyChildren(self: GuiFont, window: api.HWND) void {
        _ = EnumChildWindows(window, applyChild, @bitCast(number(self.handle)));
    }

    fn applyChild(child: api.HWND, font: api.LPARAM) callconv(.winapi) api.BOOL {
        _ = api.SendMessageW(child, api.WM_SETFONT, @bitCast(font), 1);
        return 1;
    }
};

pub fn setText(hwnd: api.HWND, value: []const u8) void {
    const allocator = std.heap.page_allocator;
    const buffer = std.unicode.utf8ToUtf16LeAllocZ(allocator, value) catch return;
    defer allocator.free(buffer);
    _ = api.SetWindowTextW(hwnd, buffer);
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
}
