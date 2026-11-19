const std = @import("std");
const process = @import("../tools/process.zig");

pub const sdk = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cDefine("NONAMELESSUNION", "1");
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cInclude("winsock2.h");
    @cInclude("windows.h");
    @cInclude("tlhelp32.h");
    @cInclude("iphlpapi.h");
    @cInclude("winhttp.h");
});

pub const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const invalid = std.os.windows.INVALID_HANDLE_VALUE;
const allocator = std.heap.page_allocator;
extern "user32" fn EnumWindows(*const fn (sdk.HWND, sdk.LPARAM) callconv(.winapi) sdk.BOOL, sdk.LPARAM) callconv(.winapi) sdk.BOOL;

pub const Child = struct {
    handle: sdk.HANDLE,
    pid: u32,
    job: sdk.HANDLE,
    path: []const u8,

    pub fn start(argv: []const []const u8, cwd: []const u8, visible: bool) !Child {
        const exe = try std.unicode.utf8ToUtf16LeAllocZ(allocator, argv[0]);
        defer allocator.free(exe);
        const directory = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd);
        defer allocator.free(directory);
        const args = try process.commandLine(allocator, argv);
        defer allocator.free(args);
        const job = sdk.CreateJobObjectW(null, null) orelse return error.CreateFixtureJob;
        errdefer _ = sdk.CloseHandle(job);
        var limits = std.mem.zeroes(sdk.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        limits.BasicLimitInformation.LimitFlags = sdk.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (sdk.SetInformationJobObject(job, sdk.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0)
            return error.ConfigureFixtureJob;
        var startup = std.mem.zeroes(sdk.STARTUPINFOW);
        startup.cb = @sizeOf(sdk.STARTUPINFOW);
        var info: sdk.PROCESS_INFORMATION = undefined;
        const console: sdk.DWORD = if (visible) 0 else sdk.CREATE_NO_WINDOW;
        const flags: sdk.DWORD = @as(sdk.DWORD, sdk.CREATE_SUSPENDED) | console;
        if (sdk.CreateProcessW(exe, args, null, null, 0, flags, null, directory, &startup, &info) == 0)
            return error.StartFixtureProcess;
        errdefer {
            _ = sdk.TerminateProcess(info.hProcess, 125);
            _ = sdk.WaitForSingleObject(info.hProcess, 5000);
            _ = sdk.CloseHandle(info.hProcess);
        }
        defer _ = sdk.CloseHandle(info.hThread);
        if (sdk.AssignProcessToJobObject(job, info.hProcess) == 0) return error.AssignFixtureJob;
        if (sdk.ResumeThread(info.hThread) == std.math.maxInt(u32)) return error.ResumeFixtureProcess;
        return .{ .handle = info.hProcess, .pid = info.dwProcessId, .job = job, .path = argv[0] };
    }

    pub fn deinit(self: Child) void {
        _ = sdk.CloseHandle(self.job);
        _ = sdk.WaitForSingleObject(self.handle, 5000);
        _ = sdk.CloseHandle(self.handle);
    }

    pub fn running(self: Child) bool {
        return sdk.WaitForSingleObject(self.handle, 0) == sdk.WAIT_TIMEOUT and sdk.GetProcessId(self.handle) == self.pid;
    }

    pub fn owned(self: Child, hwnd: sdk.HWND, class: []const u16) bool {
        return self.running() and hwnd != null and windowPid(hwnd) == self.pid and classIs(hwnd, class);
    }

    pub fn foreground(self: Child, hwnd: sdk.HWND, class: []const u16) !void {
        if (!self.owned(hwnd, class)) return error.FixtureWindowOwnership;
        if (hwnd != sdk.GetForegroundWindow()) return error.FixtureForegroundChanged;
    }

    pub fn waitWindow(self: Child, class: []const u16, visible: bool, timeout: u32) !sdk.HWND {
        const until = sdk.GetTickCount64() + timeout;
        while (self.running() and sdk.GetTickCount64() < until) {
            if (self.window(class, visible)) |found| return found;
            sdk.Sleep(25);
        }
        return error.FixtureWindowMissing;
    }

    pub fn window(self: Child, class: []const u16, visible: bool) sdk.HWND {
        if (!self.running()) return null;
        var search = WindowSearch{ .pid = self.pid, .class = class, .visible = visible };
        _ = EnumWindows(findWindow, @bitCast(@intFromPtr(&search)));
        return if (search.multiple) null else search.match;
    }

    pub fn activate(self: Child, hwnd: sdk.HWND, class: []const u16) !void {
        if (!self.owned(hwnd, class) or sdk.IsWindowVisible(hwnd) == 0) return error.FixtureWindowOwnership;
        if (hwnd == sdk.GetForegroundWindow()) return;
        _ = sdk.SetForegroundWindow(hwnd);
        if (hwnd == sdk.GetForegroundWindow()) return;

        var message: sdk.MSG = undefined;
        _ = sdk.PeekMessageW(&message, null, 0, 0, sdk.PM_NOREMOVE);
        const thread = sdk.GetCurrentThreadId();
        const active = sdk.GetWindowThreadProcessId(sdk.GetForegroundWindow(), null);
        const attached = active != 0 and active != thread and sdk.AttachThreadInput(thread, active, 1) != 0;
        defer if (attached) {
            _ = sdk.AttachThreadInput(thread, active, 0);
        };
        if (!self.owned(hwnd, class)) return error.FixtureWindowOwnership;
        _ = sdk.BringWindowToTop(hwnd);
        _ = sdk.SetForegroundWindow(hwnd);
        const until = sdk.GetTickCount64() + 500;
        while (sdk.GetTickCount64() < until and sdk.GetForegroundWindow() != hwnd) sdk.Sleep(10);
        try self.foreground(hwnd, class);
    }

    pub fn post(self: Child, hwnd: sdk.HWND, class: []const u16, message: u32, a: sdk.WPARAM, b: sdk.LPARAM) !void {
        if (!self.owned(hwnd, class)) return error.FixtureWindowOwnership;
        if (sdk.PostMessageW(hwnd, message, a, b) == 0) return error.FixtureWindowMessage;
    }

    pub fn waitForDispatch(self: Child, hwnd: sdk.HWND, class: []const u16) !void {
        if (!self.owned(hwnd, class)) return error.FixtureWindowOwnership;
        var response: sdk.DWORD_PTR = 0;
        if (sdk.SendMessageTimeoutW(hwnd, sdk.WM_NULL, 0, 0, sdk.SMTO_BLOCK | sdk.SMTO_ABORTIFHUNG, 3000, &response) == 0)
            return error.FixtureHostNotResponding;
    }

    pub fn closeGracefully(self: Child, class: []const u16) !u32 {
        if (self.running()) {
            const hwnd = self.window(class, true) orelse self.window(class, false) orelse return error.FixtureWindowMissing;
            try self.post(hwnd, class, sdk.WM_CLOSE, 0, 0);
        }
        if (sdk.WaitForSingleObject(self.handle, 6000) != sdk.WAIT_OBJECT_0) return error.FixtureProcessDidNotExit;
        var code: u32 = undefined;
        if (sdk.GetExitCodeProcess(self.handle, &code) == 0) return error.FixtureProcessStatus;
        return code;
    }

    pub fn finishJob(self: Child) !void {
        if (try self.activeProcesses() == 0) return;
        if (sdk.TerminateJobObject(self.job, 125) == 0) return error.FixtureJobTermination;
        const until = sdk.GetTickCount64() + 5000;
        while (try self.activeProcesses() != 0) {
            if (sdk.GetTickCount64() >= until) return error.FixtureJobDidNotExit;
            sdk.Sleep(25);
        }
    }

    fn activeProcesses(self: Child) !u32 {
        var account: sdk.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = undefined;
        if (sdk.QueryInformationJobObject(self.job, sdk.JobObjectBasicAccountingInformation, &account, @sizeOf(@TypeOf(account)), null) == 0)
            return error.FixtureJobStatus;
        return account.ActiveProcesses;
    }
};

const WindowSearch = struct {
    pid: u32,
    class: []const u16,
    visible: bool,
    match: sdk.HWND = null,
    multiple: bool = false,
};

fn findWindow(hwnd: sdk.HWND, data: sdk.LPARAM) callconv(.winapi) sdk.BOOL {
    const self: *WindowSearch = @ptrFromInt(@as(usize, @bitCast(data)));
    if (windowPid(hwnd) != self.pid or !classIs(hwnd, self.class) or (self.visible and sdk.IsWindowVisible(hwnd) == 0)) return 1;
    if (self.match != null) {
        self.multiple = true;
        return 0;
    }
    self.match = hwnd;
    return 1;
}

pub fn windowPid(hwnd: sdk.HWND) u32 {
    var pid: u32 = 0;
    if (hwnd != null) _ = sdk.GetWindowThreadProcessId(hwnd, &pid);
    return pid;
}

pub fn processName(alloc: std.mem.Allocator, pid: u32) ?[]const u8 {
    const handle = sdk.OpenProcess(sdk.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = sdk.CloseHandle(handle);
    var path: [32768]u16 = undefined;
    var length: u32 = path.len;
    if (sdk.QueryFullProcessImageNameW(handle, 0, &path, &length) == 0) return null;
    const name = if (std.mem.lastIndexOfScalar(u16, path[0..length], '\\')) |separator| path[separator + 1 .. length] else path[0..length];
    return std.unicode.utf16LeToUtf8Alloc(alloc, name) catch null;
}

fn classIs(hwnd: sdk.HWND, class: []const u16) bool {
    var buffer: [128]u16 = undefined;
    const n = sdk.GetClassNameW(hwnd, &buffer, buffer.len);
    return n > 0 and std.mem.eql(u16, class, buffer[0..@intCast(n)]);
}

pub fn number(hwnd: sdk.HWND) usize {
    return if (hwnd) |value| @intFromPtr(value) else 0;
}

pub fn ownsLocalListener(owner: Child, port: u16) !bool {
    if (!owner.running() or port == 0) return false;
    var needed: u32 = 0;
    const class = sdk.TCP_TABLE_OWNER_PID_LISTENER;
    if (sdk.GetExtendedTcpTable(null, &needed, 0, sdk.AF_INET, class, 0) != sdk.ERROR_INSUFFICIENT_BUFFER or needed > 1024 * 1024)
        return error.FixtureListenerTable;
    const buffer = try allocator.alignedAlloc(u8, .of(sdk.MIB_TCPTABLE_OWNER_PID), needed);
    defer allocator.free(buffer);
    if (sdk.GetExtendedTcpTable(buffer.ptr, &needed, 0, sdk.AF_INET, class, 0) != 0) return error.FixtureListenerTable;
    const table: *const sdk.MIB_TCPTABLE_OWNER_PID = @ptrCast(buffer.ptr);
    const offset = @offsetOf(sdk.MIB_TCPTABLE_OWNER_PID, "table");
    if (needed < offset or table.dwNumEntries > (needed - offset) / @sizeOf(sdk.MIB_TCPROW_OWNER_PID)) return error.FixtureListenerTable;
    const rows: [*]const sdk.MIB_TCPROW_OWNER_PID = @ptrCast(&table.table);
    for (rows[0..table.dwNumEntries]) |row| {
        if (row.dwLocalAddr == 0x0100007f and @byteSwap(@as(u16, @truncate(row.dwLocalPort))) == port)
            return row.dwOwningPid == owner.pid and owner.running();
    }
    return false;
}

pub fn clearModifiers() !void {
    for ([_]c_int{ sdk.VK_CONTROL, sdk.VK_MENU, sdk.VK_SHIFT, sdk.VK_LWIN, sdk.VK_RWIN }) |key|
        if (sdk.GetAsyncKeyState(key) < 0) return error.UserModifierHeld;
}

pub const Keyboard = struct {
    held: [256]bool = @splat(false),

    pub fn send(self: *Keyboard, owner: Child, hwnd: sdk.HWND, class: []const u16, keys: []const i16) !void {
        if (keys.len == 0 or keys.len > 64) return error.BadFixtureKey;
        var events: [64]sdk.INPUT = undefined;
        for (keys, events[0..keys.len]) |key, *event| event.* = try keyboardEvent(key);
        try owner.foreground(hwnd, class);
        const written = sdk.SendInput(@intCast(keys.len), &events, @sizeOf(sdk.INPUT));
        for (keys[0..written]) |key| self.held[@abs(key)] = key > 0;
        if (written != keys.len) return error.FixtureKeyboardIncomplete;
    }

    pub fn release(self: *Keyboard, owner: Child, hwnd: sdk.HWND, class: []const u16) !void {
        var keys: [64]i16 = undefined;
        var n: usize = 0;
        for ([_]bool{ false, true }) |modifiers| {
            for (self.held, 0..) |held, key| {
                if (held and modifiers == (key == sdk.VK_LCONTROL or key == sdk.VK_LMENU)) {
                    if (n == keys.len) return error.FixtureKeyboardIncomplete;
                    keys[n] = -@as(i16, @intCast(key));
                    n += 1;
                }
            }
        }
        if (n == 0) return;
        try owner.activate(hwnd, class);
        try self.send(owner, hwnd, class, keys[0..n]);
    }
};

fn keyboardEvent(key: i16) !sdk.INPUT {
    if (key == 0 or @abs(key) > 255) return error.BadFixtureKey;
    var event = std.mem.zeroes(sdk.INPUT);
    event.type = sdk.INPUT_KEYBOARD;
    event.u.ki.wVk = @abs(key);
    event.u.ki.dwFlags = if (key < 0) sdk.KEYEVENTF_KEYUP else 0;
    return event;
}

pub fn supportMenuTracked(owner: Child, hwnd: sdk.HWND, class: []const u16) bool {
    if (owner.foreground(hwnd, class)) |_| {} else |_| return false;
    const thread = sdk.GetWindowThreadProcessId(hwnd, null);
    var info = std.mem.zeroes(sdk.GUITHREADINFO);
    info.cbSize = @sizeOf(sdk.GUITHREADINFO);
    return sdk.GetGUIThreadInfo(thread, &info) != 0 and info.hwndMenuOwner == hwnd and info.flags & sdk.GUI_INMENUMODE != 0;
}

pub fn text(alloc: std.mem.Allocator, owner: Child, control: sdk.HWND) ![]const u8 {
    if (control == null or !owner.running() or windowPid(control) != owner.pid) return error.FixtureWindowOwnership;
    var content: [8192]u16 = undefined;
    var written: sdk.DWORD_PTR = 0;
    if (sdk.SendMessageTimeoutW(control, sdk.WM_GETTEXT, content.len, @bitCast(@intFromPtr(&content)), sdk.SMTO_ABORTIFHUNG, 1500, &written) == 0 or written >= content.len)
        return error.FixtureWindowText;
    return std.unicode.utf16LeToUtf8Alloc(alloc, content[0..written]);
}

pub fn placePointer(owner: Child, hwnd: sdk.HWND, class: []const u16, point: sdk.POINT) !void {
    try owner.foreground(hwnd, class);
    if (sdk.GetAncestor(sdk.WindowFromPhysicalPoint(point), sdk.GA_ROOT) != hwnd) return error.FixturePointerTarget;
    if (sdk.SetPhysicalCursorPos(point.x, point.y) == 0) return error.FixturePointerTarget;
}

pub const MouseProof = struct {
    button: usize = 0,
    before: ?sdk.POINT = null,
    target: ?sdk.POINT = null,
    observed: ?sdk.POINT = null,
    hit: usize = 0,
    foreground_capture: usize = 0,
    button_thread_capture: usize = 0,
    events_sent: u32 = 0,
};

pub fn clickStop(browser: Child, browser_window: sdk.HWND, browser_class: []const u16, app: Child, overlay: sdk.HWND, overlay_class: []const u16, proof: *MouseProof) !void {
    try browser.foreground(browser_window, browser_class);
    if (!app.owned(overlay, overlay_class) or sdk.IsWindowVisible(overlay) == 0) return error.FixtureWindowOwnership;
    const button = sdk.GetDlgItem(overlay, 1);
    proof.button = number(button);
    const dpi = sdk.SetThreadDpiAwarenessContext(sdk.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) orelse return error.FixtureDpiContext;
    defer _ = sdk.SetThreadDpiAwarenessContext(dpi);
    var bounds: sdk.RECT = undefined;
    if (windowPid(button) != app.pid or sdk.GetAncestor(button, sdk.GA_ROOT) != overlay or
        !classIs(button, wide("Button")) or sdk.IsWindowEnabled(button) == 0 or sdk.IsWindowVisible(button) == 0 or sdk.GetWindowRect(button, &bounds) == 0)
        return error.FixtureStopButton;
    const center: sdk.POINT = .{ .x = @divTrunc(bounds.left + bounds.right, 2), .y = @divTrunc(bounds.top + bounds.bottom, 2) };
    proof.target = center;
    var actual: sdk.POINT = undefined;
    if (sdk.GetPhysicalCursorPos(&actual) == 0) return error.FixtureCursorPosition;
    proof.before = actual;
    if (sdk.WindowFromPhysicalPoint(center) != button or sdk.SetPhysicalCursorPos(center.x, center.y) == 0) return error.FixturePointerTarget;
    sdk.Sleep(35);
    try browser.foreground(browser_window, browser_class);
    if (!app.owned(overlay, overlay_class) or windowPid(button) != app.pid or sdk.IsWindowEnabled(button) == 0) return error.FixturePointerTarget;
    proof.foreground_capture = number(try captureWindow(0));
    proof.button_thread_capture = number(try captureWindow(sdk.GetWindowThreadProcessId(button, null)));
    if ((proof.foreground_capture != 0 and proof.foreground_capture != proof.button) or
        (proof.button_thread_capture != 0 and proof.button_thread_capture != proof.button) or sdk.GetAsyncKeyState(sdk.VK_LBUTTON) < 0)
        return error.FixtureMouseCaptured;
    if (sdk.GetPhysicalCursorPos(&actual) == 0) return error.FixtureCursorPosition;
    proof.observed = actual;
    proof.hit = number(sdk.WindowFromPhysicalPoint(actual));
    if (actual.x != center.x or actual.y != center.y or proof.hit != proof.button) return error.FixturePointerTarget;
    const normalized = sdk.POINT{
        .x = try absoluteCoordinate(actual.x, sdk.GetSystemMetrics(sdk.SM_XVIRTUALSCREEN), sdk.GetSystemMetrics(sdk.SM_CXVIRTUALSCREEN)),
        .y = try absoluteCoordinate(actual.y, sdk.GetSystemMetrics(sdk.SM_YVIRTUALSCREEN), sdk.GetSystemMetrics(sdk.SM_CYVIRTUALSCREEN)),
    };
    var events = [_]sdk.INPUT{
        mouseEvent(normalized, sdk.MOUSEEVENTF_MOVE | sdk.MOUSEEVENTF_ABSOLUTE | sdk.MOUSEEVENTF_VIRTUALDESK),
        mouseEvent(.{ .x = 0, .y = 0 }, sdk.MOUSEEVENTF_LEFTDOWN),
        mouseEvent(.{ .x = 0, .y = 0 }, sdk.MOUSEEVENTF_LEFTUP),
    };
    try browser.foreground(browser_window, browser_class);
    const written = sdk.SendInput(events.len, &events, @sizeOf(sdk.INPUT));
    proof.events_sent = written;
    if (written == 2 and app.owned(overlay, overlay_class) and sdk.GetForegroundWindow() == browser_window)
        _ = sdk.SendInput(1, &events[2], @sizeOf(sdk.INPUT));
    if (written != events.len) return error.FixtureMouseIncomplete;
}

fn captureWindow(thread: u32) !sdk.HWND {
    var info = std.mem.zeroes(sdk.GUITHREADINFO);
    info.cbSize = @sizeOf(sdk.GUITHREADINFO);
    if (sdk.GetGUIThreadInfo(thread, &info) == 0) return error.FixtureMouseCaptureCheck;
    return info.hwndCapture;
}

fn absoluteCoordinate(pixel: i32, origin: i32, size: i32) !i32 {
    const relative = @as(i64, pixel) - origin;
    if (size <= 0 or size > 65536 or relative < 0 or relative >= size) return error.FixtureVirtualDesktop;
    return @intCast(@divTrunc((relative * 2 + 1) * 65536, @as(i64, size) * 2));
}

fn mouseEvent(point: sdk.POINT, flags: u32) sdk.INPUT {
    var event = std.mem.zeroes(sdk.INPUT);
    event.type = sdk.INPUT_MOUSE;
    event.u.mi.dx = point.x;
    event.u.mi.dy = point.y;
    event.u.mi.dwFlags = flags;
    return event;
}

pub const Paused = struct {
    handles: std.ArrayList(sdk.HANDLE) = .empty,
    pid: u32,

    pub fn init(owner: Child) !Paused {
        const worker = try ownedWorker(owner);
        defer _ = sdk.CloseHandle(worker.handle);
        var paused = Paused{ .pid = worker.pid };
        errdefer paused.unpause();
        const snapshot = sdk.CreateToolhelp32Snapshot(sdk.TH32CS_SNAPTHREAD, 0);
        if (snapshot == invalid or snapshot == null) return error.FixtureThreadSnapshot;
        defer _ = sdk.CloseHandle(snapshot);
        var entry = std.mem.zeroes(sdk.THREADENTRY32);
        entry.dwSize = @sizeOf(sdk.THREADENTRY32);
        var more = sdk.Thread32First(snapshot, &entry);
        while (more != 0) : (more = sdk.Thread32Next(snapshot, &entry)) {
            if (entry.th32OwnerProcessID != worker.pid) continue;
            const handle = sdk.OpenThread(sdk.THREAD_SUSPEND_RESUME | sdk.THREAD_QUERY_LIMITED_INFORMATION, 0, entry.th32ThreadID) orelse return error.FixtureWorkerThread;
            paused.handles.append(allocator, handle) catch |failure| {
                _ = sdk.CloseHandle(handle);
                return failure;
            };
            if (sdk.GetProcessIdOfThread(handle) != worker.pid or sdk.WaitForSingleObject(worker.handle, 0) != sdk.WAIT_TIMEOUT or sdk.SuspendThread(handle) == std.math.maxInt(u32)) {
                _ = sdk.CloseHandle(paused.handles.pop().?);
                return error.FixtureWorkerThread;
            }
        }
        if (paused.handles.items.len == 0) return error.FixtureWorkerThread;
        return paused;
    }

    pub fn unpause(self: *Paused) void {
        for (self.handles.items) |handle| {
            _ = sdk.ResumeThread(handle);
            _ = sdk.CloseHandle(handle);
        }
        self.handles.deinit(allocator);
        self.handles = .empty;
    }
};

const Worker = struct { pid: u32, handle: sdk.HANDLE };

pub fn ownedWorker(owner: Child) !Worker {
    if (!owner.running()) return error.FixtureAppExited;
    const snapshot = sdk.CreateToolhelp32Snapshot(sdk.TH32CS_SNAPPROCESS, 0);
    if (snapshot == invalid or snapshot == null) return error.FixtureProcessSnapshot;
    defer _ = sdk.CloseHandle(snapshot);
    var entry = std.mem.zeroes(sdk.PROCESSENTRY32W);
    entry.dwSize = @sizeOf(sdk.PROCESSENTRY32W);
    var match: ?Worker = null;
    errdefer if (match) |item| {
        _ = sdk.CloseHandle(item.handle);
    };
    const path = try std.unicode.utf8ToUtf16LeAllocZ(allocator, owner.path);
    defer allocator.free(path);
    var actual: [32768]u16 = undefined;
    var more = sdk.Process32FirstW(snapshot, &entry);
    while (more != 0) : (more = sdk.Process32NextW(snapshot, &entry)) {
        if (entry.th32ParentProcessID != owner.pid) continue;
        const handle = sdk.OpenProcess(sdk.PROCESS_QUERY_LIMITED_INFORMATION | sdk.SYNCHRONIZE, 0, entry.th32ProcessID) orelse continue;
        var keep = false;
        defer if (!keep) {
            _ = sdk.CloseHandle(handle);
        };
        var length: u32 = actual.len;
        var in_job: sdk.BOOL = 0;
        if (sdk.IsProcessInJob(handle, owner.job, &in_job) == 0 or in_job == 0 or
            sdk.QueryFullProcessImageNameW(handle, 0, &actual, &length) == 0 or
            sdk.CompareStringOrdinal(path.ptr, @intCast(path.len), &actual, @intCast(length), 1) != sdk.CSTR_EQUAL)
            continue;
        if (match != null) return error.FixtureWorkerAmbiguous;
        keep = true;
        match = .{ .pid = entry.th32ProcessID, .handle = handle };
    }
    return match orelse error.FixtureWorkerMissing;
}

test "fixture keyboard rejects invalid keys and encodes only the requested release" {
    try std.testing.expectError(error.BadFixtureKey, keyboardEvent(0));
    try std.testing.expectError(error.BadFixtureKey, keyboardEvent(256));
    try std.testing.expectError(error.BadFixtureKey, keyboardEvent(std.math.minInt(i16)));
    const release_event = try keyboardEvent(-27);
    try std.testing.expectEqual(@as(u16, 27), release_event.u.ki.wVk);
    try std.testing.expectEqual(@as(u32, sdk.KEYEVENTF_KEYUP), release_event.u.ki.dwFlags);
}

test "absolute mouse moves preserve pixels on a virtual desktop with a negative origin" {
    const origin = -1600;
    const width = 4160;
    for ([_]i32{ origin, -1, 0, 20, 2559 }) |pixel| {
        const normalized = try absoluteCoordinate(pixel, origin, width);
        try std.testing.expectEqual(pixel, origin + @divTrunc(normalized * width, 65536));
    }
    try std.testing.expectError(error.FixtureVirtualDesktop, absoluteCoordinate(-1601, origin, width));
    try std.testing.expectError(error.FixtureVirtualDesktop, absoluteCoordinate(2560, origin, width));
}

test "a missing HWND or a different process identity blocks input and debugging access" {
    const owner = Child{ .handle = sdk.GetCurrentProcess(), .pid = sdk.GetCurrentProcessId(), .job = null, .path = "" };
    var keyboard: Keyboard = .{};
    try std.testing.expectError(error.FixtureWindowOwnership, keyboard.send(owner, null, wide("Chrome_WidgetWin_1"), &.{27}));
    try std.testing.expect(!keyboard.held[27]);
    try std.testing.expect(!try ownsLocalListener(owner, 0));
    var server = try (try std.net.Address.parseIp4("127.0.0.1", 0)).listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();
    try std.testing.expect(try ownsLocalListener(owner, port));
    var other = owner;
    other.pid +%= 1;
    try std.testing.expect(!try ownsLocalListener(other, port));
}
