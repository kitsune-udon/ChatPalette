const std = @import("std");
const windows = @import("chatpalette").windows;
const win = windows.api;
const transport = @import("chatpalette").worker_client;
const automation = @import("chatpalette").worker.win_api;
const files = @import("tool_support").files;
const process = @import("tool_support").process;
const storage = @import("chatpalette").storage;
const tracing = @import("clean_install_trace.zig");
const Owned = tracing.Owned;

const toolhelp = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("tlhelp32.h");
});

const JobPids = extern struct {
    assigned: u32,
    len: u32,
    pids: [16]usize,
};

const allocator = std.heap.page_allocator;
const executable = "ChatPalette.exe";
const item_name = "クリーン展開の合成弾幕🎉";
const item_text = "最初の保存と再起動後の再読を確認";
const wait_ms: u32 = 8000;

const Observation = struct {
    role: []const u8,
    pid: u32,
    executable_path: []const u8,
    modules: []const []const u8,
    exit_code: ?u32 = null,
};

const Report = struct {
    passed: bool = false,
    failure: ?[]const u8 = null,
    initial_database_created: bool = false,
    saved_using_management: bool = false,
    observed_diagnostics: bool = false,
    diagnostic_clipboard_sha256: ?files.HexDigest = null,
    restart_used_same_executable: bool = false,
    reopened_saved_item: bool = false,
    named_pipe_reply_state: ?[]const u8 = null,
    desktop_job_total_processes: ?u32 = null,
    desktop_job_active_processes_after_exit: ?u32 = null,
    job_total_processes: ?u32 = null,
    job_active_processes_after_test: ?u32 = null,
    unexpected_module: ?[]const u8 = null,
    module_snapshot_retries: u32 = 0,
    module_snapshot_error: ?u32 = null,
    module_observation_failed_role: ?[]const u8 = null,
    ambient_text_service: ?[]const u8 = null,
    additional_job_processes: []const []const u8 = &.{},
    database_sha256_after_save: ?files.HexDigest = null,
    database_sha256_after_reopen: ?files.HexDigest = null,
};

pub fn run(scratch: std.mem.Allocator, installed: []const u8, output: []const u8, expected_sha: []const u8, version: []const u8, clipboard: bool) !void {
    var in_job: win.BOOL = 0;
    if (win.IsProcessInJob(win.GetCurrentProcess(), null, &in_job) == 0 or in_job == 0) return error.ExpectedOwnedTestJob;
    var observations: std.ArrayList(Observation) = .empty;
    var desktop_creations: []const tracing.Creation = &.{};
    var report: Report = .{};
    exercise(scratch, installed, output, expected_sha, version, clipboard, &report, &observations, &desktop_creations) catch |failure| {
        report.failure = @errorName(failure);
    };
    report.passed = report.failure == null;
    try process.saveResult(allocator, output, .{ .passed = report.passed, .checks = report, .processes = observations.items, .desktop_process_creations = desktop_creations });
    if (report.failure != null) return error.ScenarioFailed;
}

fn exercise(scratch: std.mem.Allocator, installed: []const u8, output: []const u8, expected_sha: []const u8, version: []const u8, clipboard: bool, report: *Report, observations: *std.ArrayList(Observation), desktop_creations: *[]const tracing.Creation) !void {
    var directory = try std.fs.cwd().openDir(installed, .{});
    defer directory.close();
    if (directory.access("data", .{})) |_| {
        return error.InstallationNotEmpty;
    } else |failure| {
        if (failure != error.FileNotFound) return failure;
    }
    const actual_sha = files.hex(try files.readDigest(directory, executable));
    if (!std.mem.eql(u8, &actual_sha, expected_sha)) return error.UnexpectedExecutableHash;
    const exe = try std.fs.path.join(scratch, &.{ installed, executable });
    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(scratch, exe);
    const title = try hostTitle(scratch, installed);
    const windows_root = try windowsDirectory(scratch);
    // Measure the two real desktop launches in their own nested Job. This
    // excludes processes used by UI Automation and the verification supervisor.
    const desktop_job = win.CreateJobObjectW(null, null) orelse return error.CannotCreateDesktopJob;
    defer _ = win.CloseHandle(desktop_job);
    var trace: tracing.Trace = .{
        .exe = exe_w,
        .command = try std.unicode.utf8ToUtf16LeAllocZ(scratch, try std.fmt.allocPrint(scratch, "\"{s}\"", .{exe})),
        .cwd = try std.unicode.utf8ToUtf16LeAllocZ(scratch, installed),
        .job = desktop_job,
    };
    defer trace.deinit();
    const first = try trace.start();
    const host = try waitWindow(windows.wide("ChatPalette.Host"), title, first.pid);
    _ = try waitWindow(windows.wide("ChatPalette.Palette"), null, first.pid);
    const first_slot = try observe(scratch, observations, report, "first-desktop", first, desktop_job, exe, windows_root);
    const db_path = try std.fs.path.join(scratch, &.{ installed, "data", "settings.db" });
    const created = try directory.statFile("data/settings.db");
    if (created.kind != .file or created.size == 0) return error.InitialDatabaseNotCreated;
    try requireItems(db_path, false);
    report.initial_database_created = true;

    const manager = try management(host, first.pid);
    try click(manager, 227);
    const editor = try waitWindow(windows.wide("ChatPalette.LibraryEditor"), null, first.pid);
    try setText(try control(editor, 220), item_name);
    try setText(try control(editor, 221), item_text);
    try click(editor, win.IDOK);
    try waitClosed(editor, first.pid);
    try countManagementRows(manager, 1);
    try requireItems(db_path, true);
    report.saved_using_management = true;
    report.database_sha256_after_save = files.hex(try files.readDigest(directory, "data/settings.db"));

    report.diagnostic_clipboard_sha256 = try displayDiagnostics(scratch, host, first.pid, output, version, installed, clipboard);
    report.observed_diagnostics = true;
    const after_diag = try observe(scratch, observations, report, "first-desktop-after-diagnostics", first, desktop_job, exe, windows_root);
    try menuExit(host, first, "アプリを再起動");
    observations.items[first_slot].exit_code = try exitCode(first.handle, 0);
    observations.items[after_diag].exit_code = observations.items[first_slot].exit_code;

    const replacement = try waitWindow(windows.wide("ChatPalette.Host"), title, null);
    const restarted = try openProcess(replacement);
    defer _ = win.CloseHandle(restarted.handle);
    if (first.pid == restarted.pid) return error.RestartReusedOriginalProcess;
    _ = try waitWindow(windows.wide("ChatPalette.Palette"), null, restarted.pid);
    const restarted_slot = try observe(scratch, observations, report, "restarted-desktop", restarted, desktop_job, exe, windows_root);
    report.restart_used_same_executable = true;
    const reopened = try management(replacement, restarted.pid);
    try countManagementRows(reopened, 1);
    try requireItems(db_path, true);
    try menuExit(replacement, restarted, "終了");
    observations.items[restarted_slot].exit_code = try exitCode(restarted.handle, 0);
    report.database_sha256_after_reopen = files.hex(try files.readDigest(directory, "data/settings.db"));
    if (!std.mem.eql(u8, &report.database_sha256_after_save.?, &report.database_sha256_after_reopen.?)) return error.ReopenChangedDatabase;
    report.reopened_saved_item = true;

    const desktop_accounting = try jobAccounting(desktop_job);
    report.desktop_job_total_processes = desktop_accounting.TotalProcesses;
    report.desktop_job_active_processes_after_exit = desktop_accounting.ActiveProcesses;
    const traced = try trace.finish();
    const creations = try scratch.alloc(tracing.Creation, traced.len);
    for (creations, traced) |*output_entry, entry| {
        output_entry.* = .{ .pid = entry.pid, .image = try scratch.dupe(u8, entry.image) };
    }
    desktop_creations.* = creations;
    if (desktop_accounting.TotalProcesses != creations.len or desktop_accounting.ActiveProcesses != 0)
        return error.DesktopJobTraceIncomplete;
    if (creations.len != 2 or creations[0].pid != first.pid or creations[1].pid != restarted.pid)
        return error.UnexpectedDesktopJobProcesses;

    try probeWorker(scratch, observations, report, exe_w, exe, windows_root);
    const accounting = try jobAccounting(null);
    report.job_total_processes = accounting.TotalProcesses;
    report.job_active_processes_after_test = accounting.ActiveProcesses;
    report.additional_job_processes = try additionalJobProcesses(scratch);
    if (report.additional_job_processes.len > 1) return error.UnexpectedJobProcesses;
    const console_host = try std.fmt.allocPrint(scratch, "{s}System32\\conhost.exe", .{windows_root});
    for (report.additional_job_processes) |path| {
        if (!std.ascii.eqlIgnoreCase(path, console_host)) return error.UnexpectedJobProcesses;
    }
    // Remaining processes in this outer Job may only be the supervisor and its
    // Windows console host. The nested Job independently counts desktop launches.
    const system_process_count: u32 = @intCast(report.additional_job_processes.len);
    if (accounting.ActiveProcesses != 1 + system_process_count)
        return error.UnexpectedJobProcesses;
}

fn jobAccounting(job: win.HANDLE) !win.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
    var accounting: win.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = undefined;
    if (win.QueryInformationJobObject(job, win.JobObjectBasicAccountingInformation, &accounting, @sizeOf(@TypeOf(accounting)), null) == 0)
        return error.MissingJobAccounting;
    return accounting;
}

fn requireItems(db_path: []const u8, expected: bool) !void {
    // Load through the production DB5 decoder for the durable verification.
    var db = try storage.Store.open(allocator, db_path);
    defer db.close();
    var snapshot = try db.load(allocator);
    defer snapshot.deinit();
    const rows = snapshot.data.shared_items;
    if (snapshot.data.profiles.len != 0 or snapshot.data.registrations.len != 0) return error.UnexpectedInitialData;
    if (rows.len != @intFromBool(expected)) return error.UnexpectedItemCount;
    if (expected and (!std.mem.eql(u8, rows[0].name, item_name) or !std.mem.eql(u8, rows[0].text, item_text)))
        return error.SavedItemMismatch;
}

fn openProcess(window: win.HWND) !Owned {
    const pid = windowPid(window);
    if (pid == 0) return error.MissingWindowProcess;
    const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION | win.SYNCHRONIZE, 0, pid) orelse return error.CannotOpenProductProcess;
    errdefer _ = win.CloseHandle(handle);
    if (windowPid(window) != pid) return error.ProductWindowOwnerChanged;
    return .{ .handle = handle, .pid = pid };
}

fn observe(scratch: std.mem.Allocator, observations: *std.ArrayList(Observation), report: *Report, role: []const u8, owned: Owned, job: win.HANDLE, path: []const u8, windows_root: []const u8) !usize {
    const pids = try jobPids(job);
    if (std.mem.indexOfScalar(usize, pids.pids[0..pids.len], owned.pid) == null) return error.ForeignProductProcess;
    const image = try processImage(scratch, owned.handle);
    if (!std.ascii.eqlIgnoreCase(image, path)) return error.UnexpectedProductImage;
    const dlls = modules(scratch, owned, report) catch |failure| {
        report.module_observation_failed_role = role;
        return failure;
    };
    try observations.append(scratch, .{ .role = role, .pid = owned.pid, .executable_path = image, .modules = dlls });
    for (dlls) |module| {
        if (std.ascii.eqlIgnoreCase(module, image)) continue;
        if (try isHostTextService(scratch, module)) {
            report.ambient_text_service = module;
            continue;
        }
        if (!std.ascii.startsWithIgnoreCase(module, windows_root) or
            !std.ascii.eqlIgnoreCase(std.fs.path.extension(module), ".dll") or
            std.ascii.indexOfIgnoreCase(module, "powershell") != null or
            std.ascii.indexOfIgnoreCase(module, "autohotkey") != null)
        {
            report.unexpected_module = module;
            return error.UnexpectedDependencyModule;
        }
    }
    return observations.items.len - 1;
}

pub fn processImage(scratch: std.mem.Allocator, handle: win.HANDLE) ![]const u8 {
    var buffer: [32768]u16 = undefined;
    var length: win.DWORD = buffer.len;
    if (win.QueryFullProcessImageNameW(handle, 0, &buffer, &length) == 0) return error.ProductImagePathUnavailable;
    return std.fs.cwd().realpathAlloc(scratch, try std.unicode.utf16LeToUtf8Alloc(scratch, buffer[0..length]));
}

fn jobPids(job: win.HANDLE) !JobPids {
    var ids = std.mem.zeroes(JobPids);
    if (win.QueryInformationJobObject(job, win.JobObjectBasicProcessIdList, &ids, @sizeOf(JobPids), null) == 0 or ids.len > ids.pids.len)
        return error.CannotReadJobProcessIds;
    return ids;
}

fn additionalJobProcesses(scratch: std.mem.Allocator) ![]const []const u8 {
    const pids = try jobPids(null);
    const self_pid = win.GetCurrentProcessId();
    var result: std.ArrayList([]const u8) = .empty;
    for (pids.pids[0..pids.len]) |pid| {
        if (pid == self_pid) continue;
        const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, @intCast(pid)) orelse return error.CannotReadAdditionalJobProcess;
        defer _ = win.CloseHandle(handle);
        try result.append(scratch, try processImage(scratch, handle));
    }
    return result.items;
}

fn isHostTextService(scratch: std.mem.Allocator, module: []const u8) !bool {
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(module), "GoogleIMEJaTIP64.dll")) return false;
    // Native edit controls can load the host's registered Japanese input service.
    // Guest evidence records whether this development-host component was present.
    const program_files = std.process.getEnvVarOwned(scratch, "ProgramFiles(x86)") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    const installed = try std.fs.path.join(scratch, &.{ program_files, "Google", "Google Japanese Input", "GoogleIMEJaTIP64.dll" });
    return std.ascii.eqlIgnoreCase(module, installed);
}

fn modules(scratch: std.mem.Allocator, owned: Owned, report: *Report) ![]const []const u8 {
    const deadline = win.GetTickCount64() + 1500;
    var retry = false;
    const snapshot = while (true) {
        switch (win.WaitForSingleObject(owned.handle, 0)) {
            win.WAIT_TIMEOUT => {},
            win.WAIT_OBJECT_0 => return error.ProductExitedBeforeModuleSnapshot,
            win.WAIT_FAILED => {
                report.module_snapshot_error = win.GetLastError();
                return error.CannotConfirmProductBeforeModuleSnapshot;
            },
            else => return error.CannotConfirmProductBeforeModuleSnapshot,
        }
        if (retry) {
            if (win.GetTickCount64() >= deadline) {
                report.module_snapshot_error = toolhelp.ERROR_BAD_LENGTH;
                return error.CannotEnumerateProductModules;
            }
            report.module_snapshot_retries += 1;
        }
        const current = toolhelp.CreateToolhelp32Snapshot(toolhelp.TH32CS_SNAPMODULE | toolhelp.TH32CS_SNAPMODULE32, owned.pid);
        if (current != null and @intFromPtr(current) != std.math.maxInt(usize)) break current;
        const failure = toolhelp.GetLastError();
        // The module list can change while the restarted process loads its UI.
        if (failure != toolhelp.ERROR_BAD_LENGTH or win.GetTickCount64() >= deadline) {
            report.module_snapshot_error = failure;
            return error.CannotEnumerateProductModules;
        }
        retry = true;
        win.Sleep(25);
    };
    defer _ = toolhelp.CloseHandle(snapshot);
    var entry = std.mem.zeroes(toolhelp.MODULEENTRY32W);
    entry.dwSize = @sizeOf(@TypeOf(entry));
    var result: std.ArrayList([]const u8) = .empty;
    var more = toolhelp.Module32FirstW(snapshot, &entry);
    while (more != 0) : (more = toolhelp.Module32NextW(snapshot, &entry)) {
        const len = std.mem.indexOfScalar(u16, &entry.szExePath, 0) orelse entry.szExePath.len;
        try result.append(scratch, try std.unicode.utf16LeToUtf8Alloc(scratch, entry.szExePath[0..len]));
    }
    const enumeration_error = toolhelp.GetLastError();
    if (enumeration_error != toolhelp.ERROR_NO_MORE_FILES or result.items.len < 2) {
        report.module_snapshot_error = enumeration_error;
        return error.ProductModuleEnumerationIncomplete;
    }
    std.mem.sort([]const u8, result.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    return result.items;
}

fn windowsDirectory(scratch: std.mem.Allocator) ![]const u8 {
    var buffer: [32768]u16 = undefined;
    const length = win.GetWindowsDirectoryW(&buffer, buffer.len);
    if (length == 0 or length >= buffer.len) return error.WindowsDirectoryUnavailable;
    const path = try std.unicode.utf16LeToUtf8Alloc(scratch, buffer[0..length]);
    return try std.fmt.allocPrint(scratch, "{s}\\", .{path});
}

fn exitCode(handle: win.HANDLE, expected: u32) !u32 {
    if (win.WaitForSingleObject(handle, wait_ms) != win.WAIT_OBJECT_0) return error.ProductProcessDidNotExit;
    var code: win.DWORD = undefined;
    if (win.GetExitCodeProcess(handle, &code) == 0) return error.CannotReadProductExitCode;
    if (code != expected) return error.UnexpectedProductExit;
    return code;
}

fn probeWorker(scratch: std.mem.Allocator, observations: *std.ArrayList(Observation), report: *Report, exe_w: [:0]const u16, exe: []const u8, windows_root: []const u8) !void {
    var client: transport.Client = .{};
    defer client.stop() catch {};
    const response = try client.request(scratch, exe_w, .browser_context, 0, "", &.{}, waitPipe);
    defer response.deinit();
    if (!response.is("unavailable") or response.field("Video").len != 0) return error.UnexpectedWorkerResponse;
    report.named_pipe_reply_state = "unavailable";
    const pid = win.GetProcessId(client.process);
    const retained = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION | win.SYNCHRONIZE, 0, pid) orelse return error.CannotObserveWorkerProcess;
    defer _ = win.CloseHandle(retained);
    const index = try observe(scratch, observations, report, "named-pipe-worker", .{ .handle = retained, .pid = pid }, null, exe, windows_root);
    try client.stop();
    observations.items[index].exit_code = try exitCode(retained, 1);
}

fn waitPipe(event: win.HANDLE, timeout: u32) !void {
    if (win.WaitForSingleObject(event, timeout) == win.WAIT_FAILED) return error.WaitForPipeWorker;
}

pub fn hostTitle(scratch: std.mem.Allocator, directory: []const u8) ![:0]u16 {
    const lower = try std.ascii.allocLowerString(scratch, directory);
    const title = try std.fmt.allocPrint(scratch, "ChatPalette.{s}", .{files.hex(files.digest(lower))});
    return std.unicode.utf8ToUtf16LeAllocZ(scratch, title);
}

pub fn management(host: win.HWND, pid: u32) !win.HWND {
    if (windowPid(host) != pid) return error.ProductWindowOwnerChanged;
    _ = try message(host, win.WM_APP + 12, 0, 0);
    return waitWindow(windows.wide("ChatPalette.Management"), null, pid);
}

fn countManagementRows(manager: win.HWND, expected: win.LRESULT) !void {
    if ((try message(try control(manager, 224), win.LVM_GETITEMCOUNT, 0, 0)) != expected) return error.UnexpectedManagementRowCount;
}

const MenuAction = struct {
    host: win.HWND,
    pid: u32,
    label: []const u8,
    result: anyerror!void = error.MenuNotInvoked,

    fn run(self: *MenuAction) void {
        self.result = self.invoke();
    }

    fn invoke(self: MenuAction) !void {
        if (windowPid(self.host) != self.pid or win.PostMessageW(self.host, win.WM_APP + 13, 0, 0) == 0)
            return error.CannotOpenProductMenu;
        const popup = try waitWindow(windows.wide("#32768"), null, self.pid);
        errdefer if (windowPid(popup) == self.pid) {
            _ = win.PostMessageW(popup, win.WM_CANCELMODE, 0, 0);
        };
        const uia = try automation.acquire();
        defer automation.sdk.CoUninitialize();
        defer automation.release(uia);
        const root = try automation.object(automation.Element, "ElementFromHandle", uia, .{@as(automation.sdk.UIA_HWND, @ptrFromInt(windows.number(popup)))});
        defer automation.release(root);
        const condition = try automation.textCondition(uia, automation.sdk.UIA_NamePropertyId, self.label);
        defer automation.release(condition);
        const item = try automation.object(automation.Element, "FindFirst", root, .{ automation.sdk.TreeScope_Descendants, condition });
        defer automation.release(item);
        const pattern = (try automation.invoker(item)) orelse return error.MenuItemNotInvokable;
        defer pattern.releasePattern();
        try pattern.operate();
    }
};

fn displayDiagnostics(scratch: std.mem.Allocator, host: win.HWND, pid: u32, output: []const u8, version: []const u8, installed: []const u8, clipboard: bool) !?files.HexDigest {
    var action: MenuAction = .{ .host = host, .pid = pid, .label = "診断情報" };
    const thread = try std.Thread.spawn(.{}, MenuAction.run, .{&action});
    const displayed = readDiagnostics(scratch, pid, output, version, installed, clipboard);
    thread.join();
    try action.result;
    return displayed;
}

fn readDiagnostics(scratch: std.mem.Allocator, pid: u32, output: []const u8, version: []const u8, installed: []const u8, clipboard: bool) !?files.HexDigest {
    const title = windows.wide("診断情報");
    const dialog = try waitWindow(windows.wide("ChatPalette.Support"), title, pid);
    errdefer _ = win.PostMessageW(dialog, win.WM_CLOSE, 0, 0);
    const text = try readText(scratch, try control(dialog, 100));
    const version_label = try std.fmt.allocPrint(scratch, "ChatPalette {s}\r\n", .{version});
    if (!std.mem.startsWith(u8, text, version_label) or
        std.mem.indexOf(u8, text, "起動時の配布物と一致") == null or
        std.mem.indexOf(u8, text, "DB形式 5") == null or
        std.mem.indexOf(u8, text, "現在の展開先") == null or
        std.ascii.indexOfIgnoreCase(text, installed) != null or
        std.mem.indexOf(u8, text, item_name) != null or std.mem.indexOf(u8, text, item_text) != null)
        return error.UnexpectedDiagnosticText;
    var clipboard_digest: ?files.HexDigest = null;
    if (clipboard) clipboard_digest = try copyDiagnostics(scratch, dialog, text);
    const path = try std.fs.path.join(scratch, &.{ output, "diagnostics.txt" });
    try files.writeNew(std.fs.cwd(), path, text);
    try click(dialog, win.IDCANCEL);
    try waitClosed(dialog, pid);
    return clipboard_digest;
}

fn copyDiagnostics(scratch: std.mem.Allocator, dialog: win.HWND, text: []const u8) !files.HexDigest {
    const sequence = toolhelp.GetClipboardSequenceNumber();
    try click(dialog, 3);
    if (toolhelp.GetClipboardSequenceNumber() == sequence) return error.DiagnosticClipboardUnchanged;
    const started = win.GetTickCount64();
    while (toolhelp.OpenClipboard(null) == 0) {
        if (win.GetTickCount64() - started >= wait_ms) return error.DiagnosticClipboardUnavailable;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    defer _ = toolhelp.CloseClipboard();
    const buffer = toolhelp.GetClipboardData(toolhelp.CF_UNICODETEXT) orelse return error.DiagnosticClipboardTextMissing;
    const bytes = toolhelp.GlobalSize(buffer);
    if (bytes < @sizeOf(u16) or bytes > 128 * 1024) return error.DiagnosticClipboardTextSize;
    const locked = toolhelp.GlobalLock(buffer) orelse return error.DiagnosticClipboardLock;
    defer _ = toolhelp.GlobalUnlock(buffer);
    const units = @as([*]const u16, @ptrCast(@alignCast(locked)))[0 .. bytes / @sizeOf(u16)];
    const len = std.mem.indexOfScalar(u16, units, 0) orelse return error.DiagnosticClipboardTextUnterminated;
    const copied = try std.unicode.utf16LeToUtf8Alloc(scratch, units[0..len]);
    if (!std.mem.eql(u8, copied, text)) return error.DiagnosticClipboardTextMismatch;
    return files.hex(files.digest(copied));
}

fn menuExit(host: win.HWND, instance: Owned, label: []const u8) !void {
    var action: MenuAction = .{ .host = host, .pid = instance.pid, .label = label };
    const thread = try std.Thread.spawn(.{}, MenuAction.run, .{&action});
    const waited = win.WaitForSingleObject(instance.handle, wait_ms);
    thread.join();
    try action.result;
    if (waited != win.WAIT_OBJECT_0) return error.MenuDidNotExitProduct;
}

pub fn windowPid(window: win.HWND) u32 {
    var pid: win.DWORD = 0;
    _ = win.GetWindowThreadProcessId(window, &pid);
    return pid;
}

pub fn waitWindow(class: [:0]const u16, name: ?[:0]const u16, pid: ?u32) !win.HWND {
    const started = win.GetTickCount64();
    const hidden_host = std.mem.eql(u16, class, windows.wide("ChatPalette.Host"));
    while (win.GetTickCount64() - started < wait_ms) {
        var previous: win.HWND = null;
        while (win.FindWindowExW(null, previous, class, if (name) |text| text.ptr else null)) |window| {
            if ((pid == null or windowPid(window) == pid.?) and (hidden_host or win.IsWindowVisible(window) != 0)) return window;
            previous = window;
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.ProductWindowNotFound;
}

pub fn waitClosed(window: win.HWND, pid: u32) !void {
    const started = win.GetTickCount64();
    while (win.GetTickCount64() - started < wait_ms) {
        if (windowPid(window) != pid or win.IsWindowVisible(window) == 0) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.ProductDialogDidNotClose;
}

pub fn control(parent: win.HWND, id: c_int) !win.HWND {
    const window = win.GetDlgItem(parent, id) orelse return error.ProductControlNotFound;
    if (windowPid(window) != windowPid(parent)) return error.ForeignProductControl;
    return window;
}

pub fn click(parent: win.HWND, id: u16) !void {
    const window = try control(parent, id);
    _ = try message(parent, win.WM_COMMAND, id, @bitCast(windows.number(window)));
}

pub fn setText(window: win.HWND, value: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
    defer allocator.free(wide);
    if ((try message(window, win.WM_SETTEXT, 0, @bitCast(@intFromPtr(wide.ptr)))) == 0) return error.ProductEditRejectedText;
}

pub fn readText(scratch: std.mem.Allocator, edit: win.HWND) ![]const u8 {
    const length = try message(edit, win.WM_GETTEXTLENGTH, 0, 0);
    if (length <= 0 or length > 65536) return error.ProductDiagnosticTextUnavailable;
    const buffer = try scratch.alloc(u16, @as(usize, @intCast(length)) + 1);
    const read = try message(edit, win.WM_GETTEXT, buffer.len, @bitCast(@intFromPtr(buffer.ptr)));
    if (read <= 0 or read > length) return error.ProductDiagnosticTextUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(scratch, buffer[0..@intCast(read)]);
}

pub fn message(window: win.HWND, id: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) !win.LRESULT {
    var result: win.DWORD_PTR = 0;
    if (win.SendMessageTimeoutW(window, id, wparam, lparam, win.SMTO_ABORTIFHUNG | win.SMTO_BLOCK, 3000, &result) == 0)
        return error.ProductUiMessageFailed;
    return @bitCast(result);
}
