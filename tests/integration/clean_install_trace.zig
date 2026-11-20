const std = @import("std");
const win = @import("chatpalette").windows.api;
const allocator = std.heap.page_allocator;

pub const Owned = struct { handle: win.HANDLE, pid: u32 };
pub const Creation = struct { pid: u32, image: []const u8 };

pub const Trace = struct {
    exe: [:0]const u16,
    command: [:0]u16,
    cwd: [:0]const u16,
    job: win.HANDLE,
    ready: win.HANDLE = null,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    first: anyerror!Owned = error.DesktopTraceNotStarted,
    outcome: anyerror!void = error.DesktopTraceNotStarted,
    creations: std.ArrayList(Creation) = .empty,

    pub fn start(self: *Trace) !Owned {
        self.ready = win.CreateEventW(null, 1, 0, null) orelse return error.CannotCreateTraceSignal;
        self.thread = try std.Thread.spawn(.{}, Trace.run, .{self});
        if (win.WaitForSingleObject(self.ready, 8000) != win.WAIT_OBJECT_0) return error.DesktopTraceStartTimedOut;
        return self.first;
    }

    pub fn deinit(self: *Trace) void {
        if (self.thread != null) {
            _ = win.TerminateJobObject(self.job, 124);
            _ = self.finish() catch &.{};
        }
        if (self.first) |launched| {
            _ = win.CloseHandle(launched.handle);
        } else |_| {}
        for (self.creations.items) |created| allocator.free(created.image);
        self.creations.deinit(allocator);
        if (self.ready != null) _ = win.CloseHandle(self.ready);
    }

    pub fn finish(self: *Trace) ![]const Creation {
        self.finished.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        try self.outcome;
        return self.creations.items;
    }

    fn run(self: *Trace) void {
        self.first = self.launch();
        _ = win.SetEvent(self.ready);
        _ = self.first catch |err| {
            self.outcome = err;
            return;
        };
        self.outcome = self.readEvents();
    }

    fn launch(self: *Trace) !Owned {
        var startup = std.mem.zeroes(win.STARTUPINFOW);
        startup.cb = @sizeOf(win.STARTUPINFOW);
        startup.dwFlags = win.STARTF_USESTDHANDLES;
        startup.hStdInput = win.GetStdHandle(win.STD_INPUT_HANDLE);
        startup.hStdOutput = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        startup.hStdError = win.GetStdHandle(win.STD_ERROR_HANDLE);
        var info: win.PROCESS_INFORMATION = undefined;
        const flags = win.CREATE_NO_WINDOW | win.CREATE_SUSPENDED | win.DEBUG_PROCESS;
        if (win.CreateProcessW(self.exe, self.command, null, null, 1, flags, null, self.cwd, &startup, &info) == 0)
            return error.CannotLaunchTracedExecutable;
        defer _ = win.CloseHandle(info.hThread);
        errdefer {
            _ = win.TerminateProcess(info.hProcess, 125);
            _ = win.CloseHandle(info.hProcess);
        }
        if (win.AssignProcessToJobObject(self.job, info.hProcess) == 0 or win.ResumeThread(info.hThread) == std.math.maxInt(u32))
            return error.CannotStartTracedExecutable;
        return .{ .handle = info.hProcess, .pid = info.dwProcessId };
    }

    fn readEvents(self: *Trace) !void {
        var first_error: ?anyerror = null;
        while (true) {
            var event: win.DEBUG_EVENT = undefined;
            if (win.WaitForDebugEvent(&event, 75) == 0) {
                const failure = win.GetLastError();
                if (failure != win.ERROR_SEM_TIMEOUT) return error.CannotReadDesktopDebugEvent;
                if (self.finished.load(.acquire)) break;
                continue;
            }
            const code: win.DWORD = switch (event.dwDebugEventCode) {
                win.CREATE_PROCESS_DEBUG_EVENT => result: {
                    self.record(event.dwProcessId, event.u.CreateProcessInfo.hProcess, event.u.CreateProcessInfo.hFile) catch |failure| {
                        if (first_error == null) first_error = failure;
                    };
                    if (event.u.CreateProcessInfo.hFile != null) _ = win.CloseHandle(event.u.CreateProcessInfo.hFile);
                    break :result win.DBG_CONTINUE;
                },
                win.LOAD_DLL_DEBUG_EVENT => result: {
                    if (event.u.LoadDll.hFile != null) _ = win.CloseHandle(event.u.LoadDll.hFile);
                    break :result win.DBG_CONTINUE;
                },
                win.EXCEPTION_DEBUG_EVENT => switch (event.u.Exception.ExceptionRecord.ExceptionCode) {
                    win.EXCEPTION_BREAKPOINT, win.EXCEPTION_SINGLE_STEP => win.DBG_CONTINUE,
                    else => win.DBG_EXCEPTION_NOT_HANDLED,
                },
                else => win.DBG_CONTINUE,
            };
            if (win.ContinueDebugEvent(event.dwProcessId, event.dwThreadId, code) == 0)
                return error.CannotContinueTracedProcess;
        }
        if (first_error) |failure| return failure;
    }

    fn record(self: *Trace, pid: u32, process: win.HANDLE, file: win.HANDLE) !void {
        if (self.creations.items.len >= 64) return error.TooManyTracedProcesses;
        var buffer: [32768]u16 = undefined;
        var length: win.DWORD = buffer.len;
        if (win.QueryFullProcessImageNameW(process, 0, &buffer, &length) == 0) {
            if (file == null) return error.TracedImagePathUnavailable;
            length = win.GetFinalPathNameByHandleW(file, &buffer, buffer.len, 0);
            if (length == 0 or length >= buffer.len) return error.TracedImagePathUnavailable;
        }
        const path = try std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..length]);
        errdefer allocator.free(path);
        try self.creations.append(allocator, .{ .pid = pid, .image = path });
    }
};
