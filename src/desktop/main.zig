const std = @import("std");
const builtin = @import("builtin");
const windows = @import("win.zig");
const win = windows.api;
const input = @import("input.zig");
const keyboard = @import("../worker/keyboard.zig");
const shortcuts = @import("shortcuts.zig");
const operations = @import("operations.zig");
const feedback = @import("reaction_progress.zig");
const StatusTip = @import("status_tip.zig").StatusTip;
const transport = @import("worker_client.zig");
const instance = @import("instance.zig");
const storage = @import("../storage/store.zig");
const view = @import("palette.zig");
const management = @import("management.zig");
const support = @import("support.zig");
const diagnostic = @import("diagnostics.zig");
const version = @import("app_info").version;

const allocator = std.heap.page_allocator;
pub const Startup = enum { normal, quiet, smoke };
const PaletteTarget = union(enum) { active_window, previous_target: enum { keep_options, load_defaults }, shortcut: operations.Command };
const tray_message = win.WM_APP + 2;
const drain_message = win.WM_APP + 3;
const advance_reaction_message = win.WM_APP + 4;
const timer_reaction_feedback = 3;
const timer_status_tip = 4;
const first_reaction_timer_id = timer_status_tip + 1;
const reaction_summary_capacity = 600;
const menu_open = 1;
const menu_quit = 2;
const menu_restart = 3;
const menu_manage = 4;
const menu_keys = 5;
const menu_help = 6;
const menu_diag = 7;
const menu_import = 8;
const menu_export = 9;
const menu_capture = 10;
const menu_check = 11;
const menu_reaction_result = 12;
const worker_exit_notice = "補助プロセスの終了を確認できませんでした。原因は診断情報で確認できます。";

var current: ?*App = null;

pub fn run(mode: Startup) !void {
    try windows.enableSystemDpi();
    const executable = try windows.currentExecutable(allocator);
    defer allocator.free(executable);
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, executable);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.ExecutablePath;
    const instance_id = try std.ascii.allocLowerString(allocator, dir);
    defer allocator.free(instance_id);
    const owner = try instance.Instance.acquire(instance_id, if (mode == .smoke) .fail_if_running else .take_over);
    defer owner.release();
    const data_dir = try std.fs.path.join(allocator, &.{ dir, "data" });
    defer allocator.free(data_dir);
    std.fs.cwd().makePath(data_dir) catch |failure| {
        std.debug.print("データフォルダーの準備失敗: {s}\n", .{@errorName(failure)});
        if (mode != .smoke) {
            const guidance = "データフォルダーを準備できません。同じ名前のファイルがないか、書き込み権限があるかを確認してください。";
            if (std.fmt.allocPrint(allocator, "{s}\r\n対象: {s}\r\n原因: {s}", .{ guidance, data_dir, @errorName(failure) })) |details| {
                defer allocator.free(details);
                messageBox(null, details, windows.wide("起動エラー"), win.MB_ICONWARNING);
            } else |_| {
                messageBox(null, guidance, windows.wide("起動エラー"), win.MB_ICONWARNING);
            }
        }
        return failure;
    };
    const db_path = try std.fs.path.join(allocator, &.{ data_dir, "settings.db" });
    defer allocator.free(db_path);
    const opened = try openSettings(db_path, mode);
    var db = opened.db;
    defer db.close();
    var app = App{
        .executable = executable,
        .db = &db,
        .snapshot = opened.snapshot,
        .history = storage.LibraryHistory.init(allocator),
        .running_digest = readExecutableDigest(executable) catch null,
    };
    defer app.deinit();
    current = &app;
    defer current = null;
    app.open(&owner.window_name) catch |failure| {
        if (failure == error.InstallKeyboardHook and mode != .smoke) {
            const details = hookFailureMessage(allocator, app.keyboard.install_error_code) catch return failure;
            defer allocator.free(details);
            messageBox(app.window, details, windows.wide("ショートカットを利用できません"), win.MB_ICONERROR);
        }
        return failure;
    };
    if (mode == .smoke) return;
    if (mode == .normal) app.show(.active_window);
    var message: win.MSG = undefined;
    while (true) {
        const result = win.GetMessageW(&message, null, 0, 0);
        if (result == -1) return error.DesktopMessageLoop;
        if (result == 0) break;
        dispatch(&message);
    }
    if (app.restarting) try restart(executable);
}

const Settings = struct { db: storage.Store, snapshot: storage.Snapshot };

fn openSettings(path: []const u8, mode: Startup) !Settings {
    while (true) {
        var rejected: ?storage.RejectedClose = null;
        if (readSettingsReporting(path, &rejected)) |settings| return settings else |failure| {
            const reason = settingsReadReason(failure);
            if (rejected) |report| {
                var buffer: [512]u8 = undefined;
                const details = std.fmt.bufPrint(&buffer, "{s}\r\n原因: {s} (SQLite {d})\r\n接続の終了を確認できませんでした (SQLite {d})。", .{ reason, @errorName(report.cause), report.sqlite_code, report.close_code }) catch unreachable;
                std.debug.print("{s}\n", .{details});
                if (mode != .smoke) messageBox(null, details, windows.wide("設定の読み込み失敗"), win.MB_ICONERROR);
                // Returning terminates this startup. Do not move the DB or retry an uncertain handle.
                return failure;
            }
            if (mode == .smoke) {
                std.debug.print("設定の読み込み失敗: {s}\n{s}\n", .{ @errorName(failure), reason });
                return failure;
            }
            var buffer: [640]u8 = undefined;
            const details = std.fmt.bufPrint(&buffer, "{s}\r\n原因: {s}\r\n\r\n再試行で読み直し、無視で元の設定を退避して新規起動します。", .{ reason, @errorName(failure) }) catch unreachable;
            var wide: [buffer.len + 1]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&wide, details) catch unreachable;
            wide[len] = 0;
            const choice = win.MessageBoxW(null, wide[0..len :0].ptr, windows.wide("設定の復旧"), win.MB_ABORTRETRYIGNORE | win.MB_ICONERROR | win.MB_DEFBUTTON1);
            if (choice == win.IDRETRY) continue;
            if (choice != win.IDIGNORE) return failure;
            if (win.MessageBoxW(null, windows.wide("DBと付随ファイルを退避し、空の設定で起動しますか？"), windows.wide("初期化の確認"), win.MB_YESNO | win.MB_ICONWARNING | win.MB_DEFBUTTON2) != win.IDYES) continue;
            var report = storage.backupForReset(allocator, path) catch |cause| {
                reportBackupFailure(path, cause);
                return cause;
            };
            defer report.deinit();
            if (report.failure) |cause| {
                const source = if (report.failure_index) |index| report.files[index].source else path;
                reportBackupFailure(source, cause);
                for (report.files) |file| {
                    if (file.failed_to_restore) |restore| {
                        const message = try std.fmt.allocPrint(allocator, "{s}\r\n退避先 {s}\r\n{s}", .{ file.source, file.destination, backupFailureReason(restore) });
                        defer allocator.free(message);
                        messageBox(null, message, windows.wide("元に戻せなかったファイル"), win.MB_ICONERROR);
                    }
                }
                return cause;
            }
        }
    }
}

fn settingsReadReason(cause: anyerror) []const u8 {
    return switch (cause) {
        error.UnsupportedDatabaseVersion => "未対応の設定形式です。対応するChatPaletteで開いてください。",
        error.WrongApplication => "ChatPaletteの設定データベースではありません。",
        error.InvalidPreferences => "共通設定が見つからないか、保存されている設定値が不正です。",
        error.InvalidDatabase => "設定データベースの形式または保存されている値が不正です。",
        error.DatabaseLocked => "設定データベースが使用中です。",
        else => "設定を読み込めませんでした。",
    };
}

fn backupFailureReason(cause: anyerror) []const u8 {
    return if (cause == error.FileInUse) "ファイルが使用中です。" else @errorName(cause);
}

fn reportBackupFailure(source: []const u8, cause: anyerror) void {
    const reason = backupFailureReason(cause);
    const title = windows.wide("設定を退避できませんでした");
    const message = std.fmt.allocPrint(allocator, "{s}\r\n{s}", .{ reason, source }) catch {
        messageBox(null, reason, title, win.MB_ICONERROR);
        return;
    };
    defer allocator.free(message);
    messageBox(null, message, title, win.MB_ICONERROR);
}

fn readSettings(path: []const u8) !Settings {
    return readSettingsReporting(path, null);
}

fn readSettingsReporting(path: []const u8, rejected: ?*?storage.RejectedClose) !Settings {
    var db = try storage.Store.openReporting(allocator, path, rejected);
    errdefer |cause| db.finish(cause, rejected);
    const snapshot = try db.load(allocator);
    return .{ .db = db, .snapshot = snapshot };
}

fn messageBox(parent: win.HWND, value: []const u8, title: []const u16, flags: win.UINT) void {
    const buffer = std.unicode.utf8ToUtf16LeAllocZ(allocator, value) catch return;
    defer allocator.free(buffer);
    _ = win.MessageBoxW(parent, buffer, @ptrCast(title.ptr), flags);
}

fn hookFailureMessage(alloc: std.mem.Allocator, code: ?win.DWORD) ![]u8 {
    const guidance = "ショートカットの入力を監視できませんでした。ChatPaletteを再起動してください。";
    if (code) |reported| return std.fmt.allocPrint(alloc, "{s}\r\nWindows エラー {d}", .{ guidance, reported });
    return alloc.dupe(u8, guidance);
}

fn saveFailureMessage(alloc: std.mem.Allocator, failure: anyerror, codes: storage.FailureCodes) ![]u8 {
    if (codes.rollback == null and codes.close == null) return alloc.dupe(u8, @errorName(failure));
    var message = std.Io.Writer.Allocating.init(alloc);
    errdefer message.deinit();
    try message.writer.print("{s}\r\nSQLite エラー {d}", .{ @errorName(failure), codes.original });
    if (codes.rollback) |code| try message.writer.print("\r\nロールバック エラー {d}", .{code});
    if (codes.close) |code| try message.writer.print("\r\n接続終了 エラー {d}", .{code});
    try message.writer.writeAll("\r\n設定の変更を取り消す処理でエラーが発生しました。ChatPaletteを再起動して設定を確認してください。");
    return message.toOwnedSlice();
}

fn readExecutableDigest(executable: [:0]const u16) ![32]u8 {
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, executable);
    defer allocator.free(path);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16384]u8 = undefined;
    while (true) {
        const n = try file.read(&buffer);
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }
    return hash.finalResult();
}

fn restart(executable: [:0]const u16) !void {
    const full_name = try std.unicode.utf16LeToUtf8Alloc(allocator, executable);
    defer allocator.free(full_name);
    const command = try std.fmt.allocPrint(allocator, "\"{s}\"", .{full_name});
    defer allocator.free(command);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command);
    defer allocator.free(wide);
    var startup = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    var child: win.PROCESS_INFORMATION = undefined;
    if (win.CreateProcessW(executable, wide, null, null, 0, 0, null, null, &startup, &child) == 0) return error.RestartApplication;
    _ = win.CloseHandle(child.hThread);
    _ = win.CloseHandle(child.hProcess);
}

const App = struct {
    executable: [:0]const u16,
    db: *storage.Store,
    snapshot: storage.Snapshot,
    running_digest: ?[32]u8,
    test_foreground: if (builtin.is_test) win.HWND else void = if (builtin.is_test) null else {},
    window: win.HWND = null,
    palette: view.Palette = .{},
    manager: management.Management = .{},
    help: support.Document = .{},
    diagnostic_view: support.Document = .{},
    reaction_details: support.Document = .{},
    history: storage.LibraryHistory,
    prefs_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(allocator),
    tray: bool = false,
    keyboard: input.Hook = .{ .context = keyboardContext, .enqueue = shortcut },
    queue: operations.Queue = .{},
    worker: transport.Client = .{},
    input_cancellation: ?struct { target: usize, signal: keyboard.Cancellation } = null,
    starting_reaction: ?operations.Command = null,
    reaction: ?operations.Reaction = null,
    reaction_clock: ?std.time.Timer = null,
    preparation: ?Preparation = null,
    reaction_generation: u64 = 0,
    // New attempts and results can take ownership without changing the timer generation.
    reaction_revision: u64 = 0,
    reaction_timer: ?ReactionTimer = null,
    pending_reaction_start: ?ReactionStart = null,
    next_reaction_timer_id: win.UINT_PTR = first_reaction_timer_id,
    reaction_progress: feedback.Overlay = .{},
    pending_reaction_progress: ?ReactionProgressUpdate = null,
    rendering_reaction_progress: bool = false,
    updating_reaction_buttons: bool = false,
    status_tip: StatusTip = .{},
    reaction_result: ?feedback.Result = null,
    reaction_hide_at: ?u64 = null,
    reaction_render_at: u64 = 0,
    target: win.HWND = null,
    library_revision: u64 = 0,
    input_settings_revision: u64 = 0,
    quitting: bool = false,
    restarting: bool = false,
    modal: bool = false,
    last_mode: ?transport.Mode = null,
    last_page: ?diagnostic.PageOperation = null,
    last_registration: ?diagnostic.RegistrationOperation = null,
    last_state: []const u8 = "未実行",
    last_elapsed: u64 = 0,
    last_worker_failure: ?diagnostic.WorkerFailure = null,
    last_resolve_failure: ?diagnostic.ResolveFailure = null,
    last_stop_failure: ?anyerror = null,

    const Preparation = struct {
        mode: transport.Mode,
        target: usize,
        video: operations.VideoId,
        page: operations.PageToken,
        generation: u64,
        due: u64,
        committed: bool = false,
        browser: diagnostic.Browser = .unselected,
        started_at: ?u64 = null,

        fn retries(mode: transport.Mode, state: []const u8) bool {
            return mode == .reaction_capture and
                (std.mem.eql(u8, state, "unsupported") or std.mem.eql(u8, state, "wrong_window"));
        }
    };

    fn open(self: *App, owner: [:0]const u16) !void {
        var window_class = std.mem.zeroes(win.WNDCLASSW);
        window_class.hInstance = win.GetModuleHandleW(null);
        window_class.lpszClassName = instance.class_name;
        window_class.lpfnWndProc = messageHandler;
        if (win.RegisterClassW(&window_class) == 0) return error.RegisterDesktopWindow;
        self.window = win.CreateWindowExW(0, instance.class_name, owner, 0, 0, 0, 0, 0, null, null, window_class.hInstance, null) orelse return error.CreateDesktopWindow;
        try self.palette.open(self.window);
        self.refreshPalette();
        self.palette.resetReaction(self.snapshot.data.preferences);
        self.updateReactionButtons();
        try self.keyboard.install(try shortcuts.validate(self.snapshot.data.preferences.shortcut_keys));
        self.installTray();
    }

    fn deinit(self: *App) void {
        self.keyboard.remove();
        self.removeTray();
        self.help.close();
        self.diagnostic_view.close();
        self.reaction_details.close();
        self.reaction_progress.close();
        self.status_tip.close();
        if (self.reaction_result) |result| result.deinit();
        self.palette.close();
        self.manager.close();
        if (self.window != null) _ = win.DestroyWindow(self.window);
        self.worker.stop() catch |failure| std.debug.print("補助プロセス終了: {s}\n", .{@errorName(failure)});
        self.queue.deinit(allocator);
        self.history.deinit();
        self.snapshot.deinit();
        self.prefs_arena.deinit();
    }

    fn trayData(self: *const App) win.NOTIFYICONDATAW {
        var icon = std.mem.zeroes(win.NOTIFYICONDATAW);
        icon.cbSize = @sizeOf(win.NOTIFYICONDATAW);
        icon.hWnd = self.window;
        icon.uID = 1;
        return icon;
    }

    fn trayTip(self: *const App, text: []u16) void {
        const prefix = windows.wide("ChatPalette：");
        @memcpy(text[0..prefix.len], prefix);
        const name = if (self.palette.inputProfile()) |profile| profile.name else "配信者未選択";
        windows.copyText(text[prefix.len..], name);
    }

    fn installTray(self: *App) void {
        var icon = self.trayData();
        icon.uFlags = win.NIF_ICON | win.NIF_TIP | win.NIF_MESSAGE;
        icon.uCallbackMessage = tray_message;
        icon.hIcon = win.LoadIconW(null, @ptrFromInt(32512));
        self.trayTip(&icon.szTip);
        self.tray = win.Shell_NotifyIconW(win.NIM_ADD, &icon) != 0;
    }

    fn refreshTray(self: *const App) void {
        if (!self.tray) return;
        var icon = self.trayData();
        icon.uFlags = win.NIF_TIP;
        self.trayTip(&icon.szTip);
        _ = win.Shell_NotifyIconW(win.NIM_MODIFY, &icon);
    }

    fn removeTray(self: *App) void {
        if (!self.tray) return;
        var icon = self.trayData();
        _ = win.Shell_NotifyIconW(win.NIM_DELETE, &icon);
        self.tray = false;
    }

    fn contextMenu(self: *App) void {
        const menu = win.CreatePopupMenu() orelse return;
        defer _ = win.DestroyMenu(menu);
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_open, windows.wide("ChatPaletteを開く"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_manage, windows.wide("弾幕を追加・編集"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_keys, windows.wide("ショートカットを管理…"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_capture, windows.wide("① ボタンを設定…"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_check, windows.wide("② 送らずに確認"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_reaction_result, windows.wide("リアクションの実行結果"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_help, windows.wide("使い方"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_diag, windows.wide("診断情報"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_import, windows.wide("ユーザーデータをインポート…"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_export, windows.wide("ユーザーデータをエクスポート…"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_restart, windows.wide("アプリを再起動"));
        _ = win.AppendMenuW(menu, win.MF_STRING, menu_quit, windows.wide("終了"));
        var at: win.POINT = undefined;
        if (win.GetCursorPos(&at) == 0) return;
        const menu_owner = self.dialogParent();
        _ = win.SetForegroundWindow(menu_owner);
        const command = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY | win.TPM_RIGHTBUTTON, at.x, at.y, 0, menu_owner, null);
        if (command != 0) _ = win.SendMessageW(self.window, win.WM_COMMAND, @intCast(command), 0);
    }

    fn menuCommand(self: *App, command: u16) void {
        switch (command) {
            menu_open => self.show(.active_window),
            menu_quit => self.quit(false),
            menu_restart => self.requestRestart(),
            menu_manage => self.openManagement(false),
            menu_help, menu_diag, menu_reaction_result => self.showInformation(command),
            menu_keys, menu_import, menu_export => self.dialogCommand(command, null),
            menu_capture => self.startPreparation(.reaction_capture),
            menu_check => self.startPreparation(.reaction_check),
            else => {},
        }
    }

    fn show(self: *App, target_source: PaletteTarget) void {
        if (self.quitting) return;
        if (target_source == .shortcut) {
            const command = target_source.shortcut;
            if (!self.commandCurrent(command) or command.library != self.library_revision) return;
        }
        if (self.modal) {
            if (target_source == .active_window) {
                if (support.shortcutEditorAwayFrom(win.GetForegroundWindow())) |editor| windows.recallOwnedWindow(editor);
            }
            return;
        }
        if (self.manager.isEditing()) {
            self.manager.show();
            return;
        }
        if (self.reaction != null or self.preparation != null) {
            if (target_source != .previous_target or target_source.previous_target == .keep_options) self.reaction_progress.show();
            return;
        }
        if (self.worker.active or (self.queue.active and target_source != .shortcut)) return;
        const returning_from = if (target_source == .previous_target) self.manager.window else null;
        if (returning_from != null and self.updatingViews()) return;
        const active_window = self.foregroundWindow();
        if (target_source != .previous_target) {
            if (target_source == .shortcut and windows.number(active_window) != target_source.shortcut.event.window) return;
            if (input.browser(active_window) != null) {
                self.target = active_window;
            } else {
                var owner: win.DWORD = 0;
                _ = win.GetWindowThreadProcessId(active_window, &owner);
                if (owner != win.GetCurrentProcessId()) self.target = null;
            }
        }
        self.palette.detected_profile = false;
        if (self.snapshot.data.preferences.auto_mode) {
            if (self.target != null and active_window != null) {
                const context = self.paletteContext();
                self.detectProfile(context, active_window);
                if (!self.quitting and (!self.paletteContextCurrent(context) or !self.foreground(windows.number(active_window)))) return;
            } else self.palette.status("YouTubeの入力欄からパレットを開いてください。");
        }
        if (self.quitting) return self.finishQuit();
        if (returning_from != null and (self.manager.window != returning_from or self.manager.isEditing())) return;
        self.refreshPalette();
        self.refreshRegistrationStatus();
        self.status_tip.close();
        if (target_source == .previous_target and target_source.previous_target == .load_defaults)
            self.palette.loadReactionDefaults(self.snapshot.data.preferences);
        self.palette.show();
        if (returning_from != null and self.manager.window == returning_from and
            !self.manager.isEditing() and win.IsWindowVisible(self.palette.window) != 0)
            _ = win.ShowWindow(returning_from, win.SW_HIDE);
    }

    fn registrationLabel(self: *const App, browser: ?[]const u8, buffer: []u8) []const u8 {
        const kind = browser orelse return "対象ブラウザー：未選択";
        const configured = self.db.hasReactionRegistration(kind) catch |failure|
            return std.fmt.bufPrint(buffer, "設定状態：未確認（{s}）", .{@errorName(failure)}) catch "設定状態：未確認";
        return if (configured) "設定済み（メニューの認識は未確認）" else "未設定（管理・ヘルプから設定）";
    }

    fn refreshRegistrationStatus(self: *App) void {
        var buffer: [192]u8 = undefined;
        self.palette.registrationStatus(self.registrationLabel(input.browser(self.target), &buffer));
    }

    fn ensureManagement(self: *App) bool {
        if (self.manager.window == null) {
            self.manager.create(self.window, self.db, &self.snapshot, &self.history) catch {
                self.manager.close();
                self.report("管理画面を開けませんでした。");
                return false;
            };
        }
        return true;
    }

    fn openManagement(self: *App, from_palette: bool) void {
        const first_display = self.manager.window == null;
        if (!self.canEdit() or !self.ensureManagement()) return;
        if (from_palette) {
            const lost_automatic_target = self.snapshot.data.preferences.auto_mode and input.browser(self.target) == null;
            const row = if (self.palette.selectedRow()) |selected|
                if (lost_automatic_target and selected.profile_id.len != 0) null else selected
            else
                null;
            self.manager.selectForEditing(
                if (row) |value| value.profile_id else if (lost_automatic_target) "" else self.palette.visibleProfileId(),
                if (row) |value| value.item.id else "",
            ) catch return self.report("編集する弾幕を選択できませんでした。");
            if (lost_automatic_target) {
                self.palette.detected_profile = false;
                self.refreshTray();
            }
        } else if (first_display and self.snapshot.data.shared_items.len != 0) {
            self.manager.selectForEditing("", self.snapshot.data.shared_items[0].id) catch
                return self.report("編集する弾幕を選択できませんでした。");
        }
        _ = win.ShowWindow(self.palette.window, win.SW_HIDE);
        self.manager.show();
    }

    fn linkFromPalette(self: *App) void {
        if (!self.canEdit() or !self.ensureManagement()) return;
        _ = win.ShowWindow(self.palette.window, win.SW_HIDE);
        self.manager.show();
        self.manager.linkFromPalette();
    }

    fn canEdit(self: *const App) bool {
        return self.operationIdle() and !self.updatingViews();
    }

    fn operationIdle(self: *const App) bool {
        return !self.quitting and !self.modal and !self.worker.active and
            !self.queue.busy() and self.reaction == null and self.preparation == null;
    }

    fn paletteOperationsAllowed(self: *const App) bool {
        // The palette itself owns its transient refresh/search guard.
        return self.operationIdle() and !self.manager.refreshing and !self.manager.isEditing();
    }

    fn updatingViews(self: *const App) bool {
        return self.manager.refreshing or self.palette.refreshing or self.palette.resetting_search;
    }

    fn shortcutAllowed(self: *const App, action: shortcuts.Action) bool {
        return !self.modal and !self.updatingViews() and (action == .palette or !self.manager.isEditing());
    }

    fn resolveChannel(self: *App, channel: *management.ChannelRequest) void {
        self.resolveChannelUsing(channel, input.browser, transport.Client.request);
    }

    const ChannelLookupOrigin = struct {
        target: win.HWND,
        owner: win.DWORD,
        foreground: win.HWND,
        generation: u64,
    };

    fn channelLookupCurrent(self: *const App, origin: ChannelLookupOrigin) bool {
        if (!self.canEdit() or self.target != origin.target or self.queue.generation != origin.generation or
            win.GetForegroundWindow() != origin.foreground) return false;
        var owner: win.DWORD = 0;
        _ = win.GetWindowThreadProcessId(origin.target, &owner);
        return owner == origin.owner;
    }

    fn resolveChannelUsing(self: *App, channel: *management.ChannelRequest, comptime browser: @TypeOf(input.browser), comptime exchange: @TypeOf(transport.Client.request)) void {
        channel.failure = error.ChannelLookupStale;
        const target = self.target;
        if (!self.canEdit()) return;
        if (browser(target) == null) {
            channel.failure = error.ChannelMissing;
            return;
        }
        var owner: win.DWORD = 0;
        _ = win.GetWindowThreadProcessId(target, &owner);
        if (owner == 0) return;
        const origin: ChannelLookupOrigin = .{
            .target = target,
            .owner = owner,
            .foreground = win.GetForegroundWindow(),
            .generation = self.queue.generation,
        };
        defer self.finishQuit();
        const reply = self.requestUsing(.resolve, windows.number(target), "", &.{}, exchange) catch |failure| {
            if (!self.channelLookupCurrent(origin)) return;
            channel.failure = if (self.cleanupNotice(failure) != null)
                error.ChannelLookupWorkerExit
            else if (failure == error.WorkerTimeout)
                error.ChannelLookupTimeout
            else
                error.ChannelLookupCommunication;
            return;
        };
        defer reply.deinit();
        if (!self.channelLookupCurrent(origin) or reply.is("changed") or reply.is("cancelled")) return;
        channel.failure = error.ChannelLookupResult;
        if (!reply.is("ok")) {
            if (diagnostic.ResolveFailure.fromWorker(reply.field("Detail"))) |reason| {
                channel.failure = switch (reason) {
                    .network => error.ChannelLookupNetwork,
                    .metadata => error.ChannelLookupMetadata,
                    .automation => error.ChannelLookupAutomation,
                };
            }
            return;
        }
        if (reply.field("Channel").len == 0) return;
        const author = channel.allocator.dupe(u8, reply.field("Author")) catch return;
        const key = channel.allocator.dupe(u8, reply.field("Channel")) catch {
            channel.allocator.free(author);
            return;
        };
        channel.author = author;
        channel.channel = key;
        channel.target = windows.number(target);
        channel.target_pid = owner;
        channel.failure = null;
    }

    fn libraryChanged(self: *App) void {
        self.library_revision +%= 1;
        self.refreshSavedPalette();
    }

    fn refreshPalette(self: *App) void {
        self.palette.refresh(self.snapshot.data);
        self.refreshTray();
    }

    fn refreshSavedPalette(self: *App) void {
        if (win.IsWindowVisible(self.palette.window) == 0) {
            self.palette.deferHiddenRefresh(self.snapshot.data);
            self.refreshTray();
            return;
        }
        self.refreshPalette();
        if (management.savedViewWarning(false, self.palette.refresh_failed)) |notice| self.report(notice);
    }

    fn writePreferences(self: *App, requested: storage.Preferences) !void {
        try self.commitPreferences(requested, .user_setting);
    }

    const PreferenceChange = enum { user_setting, automatic_profile };

    fn commitPreferences(self: *App, requested: storage.Preferences, change: PreferenceChange) !void {
        const bindings = try storage.validatePreferences(requested);
        var owned = std.heap.ArenaAllocator.init(allocator);
        errdefer owned.deinit();
        const memory = owned.allocator();
        var next = requested;
        next.input_profile_id = try memory.dupe(u8, requested.input_profile_id);
        for (&next.shortcut_keys) |*key| key.* = try memory.dupe(u8, key.*);
        // The process owns one OS hook. Publishing a validated binding table cannot fail.
        try self.db.savePreferences(next);
        var previous = self.prefs_arena;
        self.prefs_arena = owned;
        self.snapshot.data.preferences = next;
        switch (change) {
            .user_setting => {
                self.input_settings_revision +%= 1;
                if (!std.meta.eql(self.keyboard.tracker.bindings, bindings))
                    self.keyboard.tracker.replace(bindings);
                self.libraryChanged();
            },
            .automatic_profile => {
                // The palette borrows the preferences even while row publication is deferred.
                self.palette.data.preferences = next;
                self.palette.detected_profile = true;
            },
        }
        previous.deinit();
    }

    fn changeMode(self: *App, automatic: bool) void {
        if (!self.canEdit()) return self.refreshPalette();
        if (automatic == self.snapshot.data.preferences.auto_mode) return;
        var preferences = self.snapshot.data.preferences;
        preferences.auto_mode = automatic;
        self.palette.detected_profile = false;
        self.writePreferences(preferences) catch {
            self.refreshPalette();
            return self.report("自動判別の設定を保存できませんでした。");
        };
        self.palette.status("");
        if (automatic and self.target != null) {
            self.detectProfile(self.paletteContext(), win.GetForegroundWindow());
            if (!self.quitting) self.refreshPalette();
        }
        self.finishQuit();
    }

    fn changeProfile(self: *App, index: usize) void {
        if (self.palette.refreshing) return;
        if (!self.canEdit()) return self.refreshPalette();
        const id = self.palette.profile_choices.resolve(self.snapshot.data, index) orelse {
            self.refreshPalette();
            return self.report("対象が見つかりません。配信者を選び直してください。");
        };
        var preferences = self.snapshot.data.preferences;
        preferences.input_profile_id = id;
        self.writePreferences(preferences) catch {
            self.refreshPalette();
            self.report("配信者を選択できませんでした。");
        };
    }

    const PaletteContext = struct {
        target: win.HWND,
        generation: u64,
        library: u64,
    };

    fn paletteContext(self: *const App) PaletteContext {
        return .{ .target = self.target, .generation = self.queue.generation, .library = self.library_revision };
    }

    fn paletteTargetCurrent(self: *const App, context: PaletteContext) bool {
        return !self.quitting and self.target == context.target and self.queue.generation == context.generation;
    }

    fn paletteContextCurrent(self: *const App, context: PaletteContext) bool {
        return self.paletteTargetCurrent(context) and self.library_revision == context.library;
    }

    fn detectProfile(self: *App, context: PaletteContext, origin: win.HWND) void {
        const foreground_window = windows.number(origin);
        if (!self.foreground(foreground_window)) return;
        if (input.browser(context.target) == null) return self.report("unavailable");
        const response = self.request(.resolve, windows.number(context.target), "", &.{}) catch |failure| {
            if (!self.paletteContextCurrent(context) or !self.foreground(foreground_window)) return;
            self.report(self.cleanupNotice(failure) orelse if (failure == error.WorkerTimeout)
                "配信者を確認する補助プロセスの応答が時間内に届きませんでした。"
            else
                "補助プロセスと通信できず、配信者情報を確認できませんでした。");
            return;
        };
        defer response.deinit();
        if (!self.paletteContextCurrent(context) or !self.foreground(foreground_window)) return;
        const channel = response.field("Channel");
        if (!response.is("ok") or channel.len == 0) return self.report(self.resolveFailureNotice());
        if ((self.selectDetectedProfile(channel, .deferred) catch return self.report("自動選択を保存できませんでした。")) == null)
            return self.report("配信者が未連携です。管理からチャンネルを連携できます。");
        self.palette.status("");
    }

    fn selectDetectedProfile(self: *App, channel: []const u8, update: enum { immediate, deferred }) !?storage.Profile {
        const profile = if (channel.len == 0) null else for (self.snapshot.data.profiles) |entry| {
            if (std.mem.eql(u8, entry.channel, channel)) break entry;
        } else null;
        if (profile) |entry| {
            var preferences = self.snapshot.data.preferences;
            if (!std.mem.eql(u8, preferences.input_profile_id, entry.id)) {
                preferences.input_profile_id = entry.id;
                // The automatic selection changes no item, manual assignment, binding or mode.
                try self.commitPreferences(preferences, .automatic_profile);
                if (update == .immediate) self.refreshSavedPalette();
                return entry;
            }
        }
        if (self.palette.detected_profile != (profile != null)) {
            self.palette.detected_profile = profile != null;
            if (update == .immediate) {
                if (win.IsWindowVisible(self.palette.window) != 0) self.refreshPalette() else self.refreshTray();
            }
        }
        return profile;
    }

    fn dialogParent(self: *const App) win.HWND {
        if (self.manager.window != null and win.IsWindowVisible(self.manager.window) != 0) return self.manager.window;
        if (self.palette.window != null and win.IsWindowVisible(self.palette.window) != 0) return self.palette.window;
        return self.window;
    }

    fn showInformation(self: *App, command: u16) void {
        if (self.quitting or self.modal or self.manager.isEditing()) return;
        const parent = self.dialogParent();
        const activate = self.canEdit();
        switch (command) {
            menu_help => {
                if (!activate) return;
                self.help.show(parent, .{ .help = .{ .context = self, .open = openShortcutsFromHelp } }, true) catch |failure|
                    self.notify(if (failure == error.HelpParentRestoreUnavailable) support.help_restore_notice else "使い方を表示できませんでした。");
            },
            menu_diag => self.diagnostic_view.show(parent, .{ .diagnostic = .{
                .source = .{ .context = self, .read = readDiagnosticSnapshot },
                .version = version,
            } }, activate) catch self.notify("診断情報を表示できませんでした。"),
            menu_reaction_result => self.showReactionDetails(parent, activate) catch
                self.notify("リアクションの実行結果を表示できませんでした。"),
            else => unreachable,
        }
    }

    fn showReactionDetails(self: *App, parent: win.HWND, activate: bool) !void {
        if (activate) self.reaction_progress.hide();
        const text = if (self.reaction_result) |result| try result.document(allocator) else null;
        defer if (text) |value| allocator.free(value);
        try self.reaction_details.show(parent, .{ .reaction = text }, activate);
    }

    fn dialogCommand(self: *App, command: win.BOOL, shortcut_help: win.HWND) void {
        if (!self.canEdit() or self.manager.isEditing()) return;
        self.modal = true;
        defer {
            self.modal = false;
            self.updateReactionButtons();
            self.finishQuit();
        }
        self.updateReactionButtons();
        if (shortcut_help != null) {
            if (self.quitting or !self.help.suspendOwnerForShortcuts(shortcut_help)) return;
            defer if (!self.help.resumeOwnerAfterShortcuts()) self.notify(support.help_restore_notice);
            if (self.quitting) return;
            self.help.openShortcuts(shortcut_help, &self.snapshot, self, saveShortcutDraft, saveShortcutItemsDraft) catch |failure|
                self.saveFailure(shortcut_help, failure);
            return;
        }
        self.runDialog(command) catch |failure| self.saveFailure(self.dialogParent(), failure);
    }

    fn saveFailure(self: *App, parent: win.HWND, failure: anyerror) void {
        const codes = self.db.failureCodes();
        const title = windows.wide("操作に失敗しました");
        const details = saveFailureMessage(allocator, failure, codes) catch
            return messageBox(parent, @errorName(failure), title, win.MB_ICONERROR);
        defer allocator.free(details);
        messageBox(parent, details, title, win.MB_ICONERROR);
    }

    fn saveShortcutDraft(context: *anyopaque, dialog: win.HWND, keys: [storage.action_count][]const u8) bool {
        const self: *App = @ptrCast(@alignCast(context));
        if (self.quitting) return false;
        var next = self.snapshot.data.preferences;
        next.shortcut_keys = keys;
        self.writePreferences(next) catch |failure| {
            self.saveFailure(dialog, failure);
            return false;
        };
        self.manager.refresh();
        if (management.savedViewWarning(self.manager.refreshFailed(), self.palette.refresh_failed)) |notice|
            messageBox(dialog, notice, windows.wide("ショートカットを管理"), win.MB_ICONWARNING);
        return true;
    }

    fn saveShortcutItemsDraft(context: *anyopaque, dialog: win.HWND, scope: []const u8, first: []const u8, second: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(context));
        if (self.quitting) return false;
        const changed = self.history.assign(self.db, &self.snapshot, scope, first, second) catch |failure| {
            self.saveFailure(dialog, failure);
            return false;
        };
        if (changed) {
            self.manager.refresh();
            self.libraryChanged();
            if (management.savedViewWarning(self.manager.refreshFailed(), self.palette.refresh_failed)) |notice|
                messageBox(dialog, notice, windows.wide("ショートカットを管理"), win.MB_ICONWARNING);
        }
        return true;
    }

    fn openShortcuts(self: *App, parent: win.HWND) !void {
        try support.shortcuts(parent, &self.snapshot, self, saveShortcutDraft, saveShortcutItemsDraft);
    }

    fn openShortcutsFromHelp(context: *anyopaque, help: win.HWND) void {
        const self: *App = @ptrCast(@alignCast(context));
        self.dialogCommand(menu_keys, help);
    }

    fn runDialog(self: *App, command: win.BOOL) !void {
        const parent = self.dialogParent();
        switch (command) {
            menu_keys => try self.openShortcuts(parent),
            menu_export => {
                const path = (try support.selectJson(parent, true)) orelse return;
                defer allocator.free(path);
                if (self.quitting) return;
                try self.db.exportJson(path);
                self.report("ユーザーデータを保存しました。");
            },
            menu_import => try self.importData(parent),
            else => unreachable,
        }
    }

    fn importData(self: *App, parent: win.HWND) !void {
        const path = (try support.selectJson(parent, false)) orelse return;
        defer allocator.free(path);
        if (self.quitting) return;
        var incoming = try storage.readJson(allocator, path);
        errdefer incoming.deinit();
        const bindings = try shortcuts.validate(incoming.data.preferences.shortcut_keys);
        var item_count = incoming.data.shared_items.len;
        for (incoming.data.profiles) |profile| item_count += profile.items.len;
        const confirmation = try std.fmt.allocPrint(allocator, "{s}\r\n弾幕 {d}件、配信者 {d}件、登録 {d}件\r\n\r\nキー設定を含む全データを置き換えます。インポートしますか？", .{
            std.fs.path.basename(path), item_count, incoming.data.profiles.len, incoming.data.registrations.len,
        });
        defer allocator.free(confirmation);
        const prompt = try std.unicode.utf8ToUtf16LeAllocZ(allocator, confirmation);
        defer allocator.free(prompt);
        if (win.MessageBoxW(parent, prompt, windows.wide("ユーザーデータのインポート"), win.MB_YESNO | win.MB_ICONWARNING | win.MB_DEFBUTTON2) != win.IDYES or self.quitting) {
            incoming.deinit();
            return;
        }
        var nonce: [16]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        const backup = try std.fmt.allocPrint(allocator, "{s}.before-import-{x}.json", .{ self.db.path, &nonce });
        defer allocator.free(backup);
        const outcome = try self.commitImportedData(incoming, bindings, backup);
        const details = std.fmt.allocPrint(allocator, "{s}\r\n\r\n取込前のバックアップ\r\n{s}", .{ outcome, backup }) catch return;
        defer allocator.free(details);
        messageBox(parent, details, windows.wide("ユーザーデータのインポート"), win.MB_ICONINFORMATION);
    }

    // On success the app owns the incoming snapshot even if a view fails to refresh.
    fn commitImportedData(self: *App, incoming: storage.Snapshot, bindings: shortcuts.Bindings, backup: []const u8) ![]const u8 {
        try self.db.replaceFromBackup(incoming.data, backup);
        self.input_settings_revision +%= 1;
        var previous = self.snapshot;
        self.snapshot = incoming;
        previous.deinit();
        self.history.clear();
        self.worker.registrations_current = false;
        self.keyboard.tracker.replace(bindings);
        self.palette.detected_profile = false;
        self.palette.resetSearch();
        self.manager.resetSelection();
        self.libraryChanged();
        self.palette.resetReaction(self.snapshot.data.preferences);
        self.refreshRegistrationStatus();
        self.manager.refresh();
        const outcome = management.savedViewWarning(self.manager.refreshFailed(), self.palette.refresh_failed) orelse "ユーザーデータを取り込みました。";
        self.report(outcome);
        return outcome;
    }

    fn readDiagnosticSnapshot(context: *const anyopaque) diagnostic.Snapshot {
        const self: *const App = @ptrCast(@alignCast(context));
        return self.diagnosticSnapshot(win.GetTickCount64());
    }

    fn diagnosticSnapshot(self: *const App, now: u64) diagnostic.Snapshot {
        return .{
            .distribution = self.distributionStatus(),
            .browser = diagnostic.Browser.fromName(input.browser(self.target)),
            .operation = self.last_mode,
            .page_operation = self.last_page,
            .registration_operation = self.last_registration,
            .state = diagnostic.State.fromCode(self.last_state),
            .elapsed_ms = self.last_elapsed,
            .worker_failure = self.last_worker_failure,
            .resolve_failure = self.last_resolve_failure,
            .stop_failure = self.last_stop_failure,
            .phase = self.diagnosticReactionPhase(now),
            .worker_running = self.worker.process != null and win.WaitForSingleObject(self.worker.process, 0) == win.WAIT_TIMEOUT,
            .automatic = self.snapshot.data.preferences.auto_mode,
        };
    }

    fn distributionStatus(self: *const App) diagnostic.Distribution {
        const running = self.running_digest orelse return .running_unknown;
        const on_disk = readExecutableDigest(self.executable) catch return .disk_unknown;
        return if (std.mem.eql(u8, &on_disk, &running)) .matching else .modified;
    }

    fn diagnosticReactionPhase(self: *const App, now: u64) diagnostic.Phase {
        if (self.reaction) |job| {
            if (job.stop_requested) return .stopping;
            if (!job.active_request and job.shortcut == null and job.completed == 0) {
                if (self.reaction_clock) |clock| {
                    var reading = clock;
                    if (reading.read() < job.due_ns) return .waiting;
                }
            }
            return .running;
        }
        if (self.preparation) |pending| {
            if (pending.generation != self.reaction_generation) return .stopping;
            return if (!self.worker.active and now < pending.due) .waiting else .running;
        }
        if (self.quickReactionStarting()) return .running;
        if (self.reactionQueued()) return .queued;
        return if (self.reaction_result != null) .finished else .idle;
    }

    fn quickReactionStarting(self: *const App) bool {
        const command = self.starting_reaction orelse return false;
        return self.queue.active and command.generation == self.queue.generation;
    }

    fn reactionQueued(self: *const App) bool {
        for (self.queue.pending.items) |command| {
            if (command.event.action == .reaction) return true;
        }
        return false;
    }

    fn requestRestart(self: *App) void {
        if (self.quitting) return;
        if (self.updatingViews()) return self.notify("一覧を更新しています。完了後にもう一度操作してください。");
        if (!self.manager.isEditing()) {
            if (self.reaction != null or self.preparation != null or self.reactionQueued())
                return self.notify("リアクション処理中です。停止してから押してください。");
            if (self.worker.active or self.queue.busy() or self.modal)
                return self.notify("前の処理を確認中です。完了後にもう一度押してください。");
        }
        self.quit(true);
    }

    fn quit(self: *App, restarting: bool) void {
        if (self.manager.isEditing()) {
            self.manager.show();
            return self.report("編集中の内容を保存または破棄してから終了してください。");
        }
        self.quitting = true;
        self.restarting = restarting;
        self.stop();
        self.finishQuit();
    }

    fn finishQuit(self: *App) void {
        if (!self.quitting or self.worker.active or self.queue.active or self.modal) return;
        self.worker.stop() catch |failure| {
            const notice = if (self.restarting)
                "補助プロセスの終了を確認できませんでした。もう一度再起動してください。"
            else
                "補助プロセスの終了を確認できませんでした。もう一度終了してください。";
            self.last_stop_failure = failure;
            self.quitting = false;
            self.restarting = false;
            self.notify(notice);
            return;
        };
        self.last_stop_failure = null;
        win.PostQuitMessage(0);
    }

    fn stop(self: *App) void {
        defer self.syncOperationButtons();
        const stop_quick_start = self.preparation == null and self.reaction == null and
            (self.quickReactionStarting() or self.reactionQueued());
        if (self.input_cancellation) |pending| pending.signal.cancel();
        self.queue.cancel();
        self.reaction_generation +%= 1;
        if (self.preparation) |pending| {
            if (pending.committed) {
                if (!self.quitting) self.updateReactionProgress("登録は保存済みです。ワーカーへの反映を確認しています。", .stopping);
            } else self.finishPreparation(.stopped, "");
            return;
        }
        if (self.reaction) |*job| {
            job.stop();
            if (job.active_request) {
                if (!self.quitting) self.showReactionCounts("停止を受け付けました。", job.*, .stopping);
            } else self.finishReaction(.stopped, "");
            return;
        }
        if (stop_quick_start) {
            _ = self.failReactionStart(.stopped, "");
            self.updateReactionButtons();
        }
    }

    fn report(self: *App, state: []const u8) void {
        const message = if (std.mem.eql(u8, state, "unavailable"))
            "動画・入力欄を確認できませんでした。"
        else if (std.mem.eql(u8, state, "changed"))
            "動画・タブ・ウィンドウが切り替わりました。"
        else if (std.mem.eql(u8, state, "cancelled"))
            "操作を中止しました。"
        else if (std.mem.eql(u8, state, "wrong_input"))
            "現在の入力欄を操作できません。"
        else if (std.mem.eql(u8, state, "invalid_text"))
            "本文に入力できない制御文字が含まれています。弾幕を編集し、制御文字を取り除いてください。"
        else if (std.mem.eql(u8, state, "chat_missing"))
            "入力可能なチャット欄が見つかりません。チャットの表示と入力可能な状態を確認してください。"
        else if (std.mem.eql(u8, state, "chat_ambiguous"))
            "チャット入力欄が複数あります。操作する欄をクリックし、手動で入力・編集してください。"
        else if (std.mem.eql(u8, state, "focus_failed"))
            "チャット欄へのフォーカス移動を確認できませんでした。入力欄をクリックしてください。"
        else if (std.mem.eql(u8, state, "unknown"))
            "操作結果を確認できませんでした。自動では再実行しません。画面で結果を確認してください。"
        else
            state;
        self.palette.status(message);
        if (win.IsWindowVisible(self.palette.window) != 0 or win.IsWindowVisible(self.reaction_progress.window) != 0) return;
        self.showStatusTip(message);
    }

    fn notify(self: *App, message: []const u8) void {
        self.palette.status(message);
        if (win.IsWindowVisible(self.palette.window) == 0) self.showStatusTip(message);
    }

    fn showStatusTip(self: *App, message: []const u8) void {
        if (self.quitting or self.window == null) return;
        self.status_tip.show(self.window, message, win.GetTickCount64(), 3500) catch return;
        if (win.SetTimer(self.window, timer_status_tip, 100, null) == 0) self.status_tip.close();
    }

    fn expireStatusTip(self: *App) void {
        self.status_tip.expire(win.GetTickCount64());
        if (self.status_tip.deadline == null) _ = win.KillTimer(self.window, timer_status_tip);
    }

    fn request(self: *App, mode: transport.Mode, target: usize, expected: []const u8, fields: []const transport.Field) !transport.Reply {
        return self.requestUsing(mode, target, expected, fields, transport.Client.request);
    }

    fn requestUsing(self: *App, mode: transport.Mode, target: usize, expected: []const u8, fields: []const transport.Field, comptime exchange: @TypeOf(transport.Client.request)) !transport.Reply {
        if (self.worker.active) return error.WorkerBusy;
        defer self.syncOperationButtons();
        const generation = self.queue.generation;
        const started = win.GetTickCount64();
        const exchanged = exchange(&self.worker, allocator, self.executable, mode, target, expected, fields, pump);
        if (self.shortcutSuperseded(generation)) {
            if (exchanged) |_| {} else |failure| {
                const cleanup: ?anyerror = self.worker.cleanup_failure orelse if (failure == error.WorkerDidNotExit) failure else null;
                if (cleanup) |cause| self.last_stop_failure = cause;
            }
            return exchanged;
        }
        if (self.last_page) |*page_operation| page_operation.latest = false;
        if (self.last_registration) |*registration| registration.latest = false;
        self.last_resolve_failure = null;
        self.last_mode = mode;
        self.last_elapsed = win.GetTickCount64() - started;
        const reply = exchanged catch |failure| {
            self.last_state = if (self.worker.request_may_have_arrived) "unknown" else "unavailable";
            self.last_worker_failure = .{
                .cause = failure,
                .cleanup = self.worker.cleanup_failure orelse if (failure == error.WorkerDidNotExit) failure else null,
                .may_have_arrived = self.worker.request_may_have_arrived,
            };
            if (self.cleanupNotice(failure)) |notice| self.notify(notice);
            return failure;
        };
        self.last_worker_failure = null;
        self.last_stop_failure = null;
        const state = reply.field("State");
        if (mode == .resolve and reply.is("unavailable"))
            self.last_resolve_failure = diagnostic.ResolveFailure.fromWorker(reply.field("Detail"));
        self.last_state = if (mode.inputOutcome()) |outcome|
            (if (reply.is(outcome)) outcome else @tagName(diagnostic.State.fromWorker(state)))
        else
            @tagName(diagnostic.State.fromWorker(state));
        return reply;
    }

    fn cleanupNotice(self: *const App, cause: anyerror) ?[]const u8 {
        const failure = self.last_worker_failure orelse return null;
        if (failure.cause != cause or failure.cleanup == null) return null;
        return worker_exit_notice;
    }

    fn resolveFailureNotice(self: *const App) []const u8 {
        return if (self.last_resolve_failure) |failure| failure.message() else "配信者情報を確認できませんでした。";
    }

    fn workerFailureDetail(self: *const App, cause: anyerror, buffer: *[256]u8) []const u8 {
        if (self.last_worker_failure) |failure| {
            if (failure.cause == cause) return failure.format(buffer) catch @errorName(cause);
        }
        return @errorName(cause);
    }

    fn workerFailureReason(self: *const App, cause: anyerror) feedback.Reason {
        if (cause == error.PageProofMissing) return .changed;
        const failure = self.last_worker_failure orelse return .unknown;
        if (failure.cause == cause and !failure.may_have_arrived) return .unavailable;
        return .unknown;
    }

    fn shortcutFailureNotice(self: *const App, slot_input: bool, cause: anyerror, buffer: *[512]u8) []const u8 {
        if (self.cleanupNotice(cause)) |notice| return notice;
        const page_recorded = if (self.last_page) |page_operation| page_operation.latest else false;
        const fallback = if (page_recorded) self.last_state else @tagName(self.workerFailureReason(cause));
        if (!slot_input) return fallback;
        const failure = self.last_worker_failure orelse return fallback;
        if (failure.cause != cause) return fallback;
        const notice = switch (self.last_mode orelse return fallback) {
            .browser_context => "動画を確認できなかったため、弾幕は入力していません。",
            .resolve => "配信者を確認できなかったため、弾幕は入力していません。",
            .verify_input, .verify_chat => "入力欄を確認できなかったため、弾幕は入力していません。",
            else => return fallback,
        };
        var detail: [256]u8 = undefined;
        const reason = failure.format(&detail) catch return notice;
        return std.fmt.bufPrint(buffer, "{s} {s}", .{ notice, reason }) catch notice;
    }

    fn requestOnPage(self: *App, mode: transport.Mode, target: usize, video: []const u8, page_proof: []const u8, extra: []const transport.Field) !transport.Reply {
        const generation = self.queue.generation;
        var fields: [3]transport.Field = undefined;
        fields[0] = .{ .name = "PageToken", .value = page_proof };
        @memcpy(fields[1 .. 1 + extra.len], extra);
        const reply = try self.request(mode, target, video, fields[0 .. 1 + extra.len]);
        errdefer reply.deinit();
        const input_sent = if (mode.inputOutcome()) |outcome| reply.is(outcome) else false;
        if (reply.is("ok") or reply.is("focused") or reply.is("hovered") or reply.is("captured") or reply.is("ready") or reply.is("operated") or input_sent) {
            const returned = reply.field("PageToken");
            const valid = if (std.mem.eql(u8, page_proof, "bind"))
                operations.pageToken(returned) != null
            else
                std.mem.eql(u8, page_proof, returned);
            if (!valid) {
                if (input_sent) {
                    if (!self.shortcutSuperseded(generation)) self.last_state = "unknown";
                    return error.InputOutcomeUnknown;
                }
                if (!self.shortcutSuperseded(generation)) self.last_state = "changed";
                return error.PageProofMissing;
            }
        }
        return reply;
    }

    fn foregroundWindow(self: *const App) win.HWND {
        if (builtin.is_test and self.test_foreground != null) return self.test_foreground;
        return win.GetForegroundWindow();
    }

    fn foreground(self: *App, target: usize) bool {
        return !self.quitting and target != 0 and windows.number(self.foregroundWindow()) == target;
    }

    fn syncRegistration(self: *App, target: usize, detail: *[256]u8) ?[]const u8 {
        if (self.worker.registrationsReady()) return null;
        const json = self.db.loadRegistrationSnapshot(allocator) catch |failure| return @errorName(failure);
        defer allocator.free(json);
        const reply = self.request(.reaction_configure, target, "", &.{.{ .name = "Payload", .value = json }}) catch |failure|
            return self.workerFailureDetail(failure, detail);
        defer reply.deinit();
        self.worker.acceptRegistrationReply(reply) catch |failure| {
            const reason = reply.field("Detail");
            if (reason.len == 0) return "登録情報の同期に失敗しました。";
            return std.fmt.bufPrint(detail, "{s}", .{reason}) catch @errorName(failure);
        };
        return null;
    }

    fn drain(self: *App) void {
        if (self.worker.active or self.reaction != null or self.preparation != null or self.quitting) return;
        if (self.modal) {
            if (!self.queue.active and self.queue.pending.items.len != 0) self.queue.cancel();
            return;
        }
        const command = self.queue.next() orelse return;
        const quick = command.event.action == .reaction;
        if (quick) {
            self.starting_reaction = command;
            self.updateReactionButtons();
        }
        const success = self.execute(command) catch |failure| result: {
            if (quick) {
                var detail: [256]u8 = undefined;
                if (!self.quitting and self.quickReactionStarting())
                    _ = self.failReactionStart(self.workerFailureReason(failure), self.workerFailureDetail(failure, &detail));
            } else if (!self.shortcutSuperseded(command.generation)) {
                var notice: [512]u8 = undefined;
                self.report(self.shortcutFailureNotice(command.slot != null, failure, &notice));
            }
            break :result false;
        };
        // Quick start can hand off to a timer job or release the command before publishing a failure.
        if (!quick or self.starting_reaction != null) {
            self.starting_reaction = null;
            self.queue.finish(command, success);
        }
        if (self.reaction != null) return;
        self.updateReactionButtons();
        self.finishQuit();
        if (!self.quitting and self.queue.busy()) _ = win.PostMessageW(self.window, drain_message, 0, 0);
    }

    fn commandCurrent(self: *App, command: operations.Command) bool {
        return self.reaction == null and self.preparation == null and
            self.shortcutAllowed(command.event.action) and self.foreground(command.event.window) and
            self.queue.accepts(command, command.event.window);
    }

    fn shortcutSuperseded(self: *const App, generation: u64) bool {
        return self.queue.generation != generation and self.queue.pending.items.len != 0;
    }

    fn checkCommandTarget(self: *App, command: operations.Command) bool {
        if (self.commandCurrent(command)) return true;
        if (command.event.action == .reaction and self.shortcutAllowed(.reaction) and !self.quitting and
            self.queue.active and command.generation == self.queue.generation)
            return self.failReactionStart(.wrong_window, "");
        return false;
    }

    fn execute(self: *App, command: operations.Command) !bool {
        const target = command.event.window;
        if (!self.checkCommandTarget(command)) return false;
        const action = command.event.action;
        if (action == .palette) {
            self.show(.{ .shortcut = command });
            return true;
        }
        const browser = input.browser(@ptrFromInt(target)) orelse
            return if (action == .reaction) self.failReactionStart(.wrong_window, "") else false;
        const scope_page = switch (action) {
            .chat_focus, .chat_clear, .chat_send, .reactions_show, .profile1, .profile2, .shared1, .shared2, .reaction => true,
            else => false,
        };
        const previous_page = self.queue.page;
        const context = if (scope_page)
            try self.requestOnPage(.browser_context, target, "", if (previous_page) |*known| known else "bind", &.{})
        else
            try self.request(.browser_context, target, "", &.{});
        defer context.deinit();
        if (!self.checkCommandTarget(command)) return false;
        if (!context.is("ok")) {
            if (action == .reaction) return self.failReactionStart(feedback.Reason.fromReply(context.field("State")), context.field("Detail"));
            self.report(context.field("State"));
            return false;
        }
        const video = operations.videoId(context.field("Video")) orelse {
            if (action == .reaction) return self.failReactionStart(.unavailable, context.field("Detail"));
            self.report("unavailable");
            return false;
        };
        if (!self.queue.bindVideo(video)) {
            if (action == .reaction) return self.failReactionStart(.changed, context.field("Detail"));
            self.report("changed");
            return false;
        }
        const page_token = if (scope_page) operations.pageToken(context.field("PageToken")) orelse return false else null;
        if (page_token) |token| {
            if (!self.queue.bindPage(token)) {
                if (action == .reaction) return self.failReactionStart(.changed, context.field("Detail"));
                self.report("changed");
                return false;
            }
        }
        switch (action) {
            .chat_focus, .chat_clear, .reactions_show, .chat_send => return self.page(command, video, page_token, diagnostic.Browser.fromName(browser)),
            .profile1, .profile2, .shared1, .shared2 => return self.slot(command, video, page_token.?),
            .reaction => {
                const prefs = self.snapshot.data.preferences;
                return self.startReaction(.{
                    .target = target,
                    .video = video,
                    .page = page_token.?,
                    .kind = prefs.reaction_kind,
                    .count = prefs.reaction_count,
                    .interval = prefs.reaction_interval_ms,
                    .shortcut = command,
                }, 0);
            },
            .palette, .stop => unreachable,
        }
    }

    fn page(self: *App, command: operations.Command, video: operations.VideoId, page_token: ?operations.PageToken, browser: diagnostic.Browser) !bool {
        const target = command.event.window;
        const action = command.event.action;
        const started = win.GetTickCount64();
        var stage: diagnostic.PageStage = switch (action) {
            .chat_focus, .chat_clear => .focus,
            .chat_send => .send_check,
            .reactions_show => .show_reactions,
            else => unreachable,
        };
        defer if (!self.shortcutSuperseded(command.generation)) {
            self.last_page = .{
                .action = action,
                .browser = browser,
                .stage = stage,
                .state = diagnostic.State.fromCode(self.last_state),
                .elapsed_ms = win.GetTickCount64() - started,
            };
        };
        errdefer |failure| if (!self.shortcutSuperseded(command.generation)) {
            if (failure == error.ForegroundChanged) {
                self.last_state = "cancelled";
            } else if (failure == error.PageProofMissing) {
                self.last_state = "changed";
            } else if (self.last_worker_failure == null) {
                self.last_state = "unknown";
            }
        };
        const result = switch (action) {
            .chat_focus, .chat_clear => reply: {
                self.queue.focus.len = 0;
                break :reply try self.requestOnPage(.chat_focus, target, &video, &page_token.?, &.{});
            },
            .chat_send => try self.verifyShortcutInput(target, video, page_token.?),
            .reactions_show => try self.requestOnPage(.reactions_show, target, &video, &page_token.?, &.{}),
            else => unreachable,
        };
        defer result.deinit();
        if (!self.pageCommandCurrent(command)) return false;
        const expected_state: diagnostic.State = switch (action) {
            .chat_focus, .chat_clear => .focused,
            .chat_send => .ok,
            .reactions_show => .hovered,
            else => unreachable,
        };
        if (!self.pageReplySucceeded(result, video, expected_state)) return false;
        switch (action) {
            .chat_focus, .chat_clear => {
                if (action == .chat_clear) stage = .clear_check;
                if (!self.queue.focus.save(result.field("Detail"))) return self.rejectPage(if (action == .chat_clear) .wrong_input else .focus_failed);
                if (action == .chat_focus) {
                    self.report("チャット欄へ移動しました。");
                    return true;
                }
                const checked = try self.verifyShortcutInput(target, video, page_token.?);
                defer checked.deinit();
                if (!self.pageCommandCurrent(command) or !self.pageReplySucceeded(checked, video, .ok)) return false;
                stage = .clear_keys;
                const outcome = try self.commitInput(.chat_clear, target, video, page_token.?, null);
                if (self.shortcutSuperseded(command.generation)) return false;
                if (outcome != .cleared) {
                    if (outcome != .unknown) stage = .clear_check;
                    return self.rejectPage(outcome);
                }
                self.report("クリアキーを送りました（内容は未取得）。");
            },
            .chat_send => {
                if (!std.mem.eql(u8, result.field("Detail"), "chat")) return self.rejectPage(.wrong_input);
                stage = .enter_key;
                const outcome = try self.commitInput(.chat_enter, target, video, page_token.?, null);
                if (self.shortcutSuperseded(command.generation)) return false;
                if (outcome != .enter_sent) {
                    if (outcome != .unknown) stage = .send_check;
                    return self.rejectPage(outcome);
                }
                self.report("チャット欄へEnterキーを送りました（送信受理は未確認）。");
            },
            .reactions_show => self.report("表示用UIへマウスを移動しました（表示は未確認）。"),
            else => unreachable,
        }
        return true;
    }

    fn commitInput(self: *App, mode: transport.Mode, target: usize, video: operations.VideoId, page_token: operations.PageToken, text: ?[]const u8) !diagnostic.State {
        const generation = self.queue.generation;
        const cancellation = try keyboard.Cancellation.create();
        self.input_cancellation = .{ .signal = cancellation, .target = target };
        defer {
            self.input_cancellation = null;
            cancellation.close();
        }
        var fields: [2]transport.Field = undefined;
        fields[0] = .{ .name = "CancelToken", .value = &cancellation.token };
        var size_buffer: [20]u8 = undefined;
        const payload = if (text) |value| try keyboard.Payload.create(&cancellation.token, value) else null;
        defer if (payload) |present| present.close();
        if (text) |value| fields[1] = .{ .name = "PayloadBytes", .value = try std.fmt.bufPrint(&size_buffer, "{d}", .{value.len}) };
        const reply = try self.requestOnPage(mode, target, &video, &page_token, fields[0..if (payload != null) 2 else 1]);
        defer reply.deinit();
        const success = mode.inputOutcome().?;
        if (reply.is(success)) {
            if (std.mem.eql(u8, reply.field("Video"), &video)) return diagnostic.State.fromCode(success);
            if (!self.shortcutSuperseded(generation)) self.last_state = "unknown";
            return error.InputOutcomeUnknown;
        }
        return switch (diagnostic.State.fromWorker(reply.field("State"))) {
            .changed, .cancelled, .wrong_input, .invalid_text, .unavailable => |state| state,
            else => .unknown,
        };
    }

    fn pageCommandCurrent(self: *App, command: operations.Command) bool {
        if (self.commandCurrent(command)) return true;
        if (self.shortcutSuperseded(command.generation)) return false;
        if (!self.quitting) return self.rejectPage(.cancelled);
        self.last_state = "cancelled";
        return false;
    }

    fn pageReplySucceeded(self: *App, reply: transport.Reply, video: operations.VideoId, expected_state: diagnostic.State) bool {
        const state = diagnostic.State.fromWorker(reply.field("State"));
        if (state != expected_state) return self.rejectPage(if (state == .ok) .wrong_input else state);
        if (!std.mem.eql(u8, reply.field("Video"), &video)) return self.rejectPage(.changed);
        return true;
    }

    fn rejectPage(self: *App, state: diagnostic.State) bool {
        self.last_state = @tagName(state);
        self.report(self.last_state);
        return false;
    }

    const InputPlan = struct {
        arena: std.heap.ArenaAllocator,
        scope: []const u8,
        id: []const u8,
        text: []const u8,
        channel: []const u8,
        settings_revision: u64,

        fn capture(app: *const App, scope: []const u8, item: storage.Item) !InputPlan {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const owned = arena.allocator();
            const channel = if (scope.len != 0)
                (app.snapshot.data.findProfile(scope) orelse return error.ProfileChanged).channel
            else
                "";
            const owned_scope = try owned.dupe(u8, scope);
            const owned_id = try owned.dupe(u8, item.id);
            const owned_text = try owned.dupe(u8, item.text);
            const owned_channel = try owned.dupe(u8, channel);
            return .{
                .arena = arena,
                .scope = owned_scope,
                .id = owned_id,
                .text = owned_text,
                .channel = owned_channel,
                .settings_revision = app.input_settings_revision,
            };
        }

        fn current(self: *const InputPlan, app: *const App) bool {
            return app.input_settings_revision == self.settings_revision and self.itemCurrent(app);
        }

        fn itemCurrent(self: *const InputPlan, app: *const App) bool {
            const data = app.snapshot.data;
            if (self.scope.len != 0) {
                const profile = data.findProfile(self.scope) orelse return false;
                if (!std.mem.eql(u8, self.channel, profile.channel)) return false;
                if (!data.preferences.auto_mode and !std.mem.eql(u8, self.scope, data.preferences.input_profile_id)) return false;
            }
            const items = data.itemsFor(self.scope) catch return false;
            for (items) |item| {
                if (std.mem.eql(u8, self.id, item.id)) return std.mem.eql(u8, self.text, item.text);
            }
            return false;
        }
    };

    fn slot(self: *App, command: operations.Command, video: operations.VideoId, page_token: operations.PageToken) !bool {
        const source = command.slot orelse return false;
        if (!source.scope.current(self.snapshot.data.preferences)) return false;
        const target = command.event.window;
        const action = command.event.action;
        const slot_number: u8 = if (action == .profile1 or action == .shared1) 1 else 2;
        const profile_id = switch (source.scope) {
            .shared => "",
            .manual => |id| if (id.len != 0) id else return false,
            .automatic => detected: {
                const reply = self.requestOnPage(.resolve, target, &video, &page_token, &.{}) catch |failure| {
                    if (!self.commandCurrent(command) or !source.scope.current(self.snapshot.data.preferences)) return false;
                    return failure;
                };
                defer reply.deinit();
                if (!self.commandCurrent(command) or !source.scope.current(self.snapshot.data.preferences)) return false;
                if (reply.is("unavailable")) {
                    self.report(self.resolveFailureNotice());
                    return false;
                }
                if (!self.pageReplySucceeded(reply, video, .ok)) return false;
                const channel = reply.field("Channel");
                if ((self.selectDetectedProfile(channel, .immediate) catch {
                    self.report("自動選択を保存できませんでした。");
                    return false;
                }) == null) {
                    self.report("配信者が未連携です。管理からチャンネルを連携できます。");
                    return false;
                }
                if (!self.commandCurrent(command) or !source.scope.current(self.snapshot.data.preferences)) return false;
                // Publishing the selection can dispatch window messages. Read the committed profile again.
                const data = self.snapshot.data;
                const selected = data.findProfile(data.preferences.input_profile_id) orelse return self.rejectPage(.changed);
                if (!std.mem.eql(u8, selected.channel, channel)) return self.rejectPage(.changed);
                break :detected selected.id;
            },
        };
        const items = source.library.read().itemsFor(profile_id) catch return self.rejectPage(.changed);
        const item = for (items) |item| {
            if (item.slot == slot_number) break item;
        } else {
            self.report("このキーに弾幕が割り当てられていません。");
            return false;
        };
        var plan = try InputPlan.capture(self, profile_id, item);
        defer plan.arena.deinit();
        if (!plan.itemCurrent(self)) return self.rejectPage(.changed);
        const verification = try self.verifyShortcutInput(target, video, page_token);
        defer verification.deinit();
        if (!self.commandCurrent(command) or !source.scope.current(self.snapshot.data.preferences) or !plan.itemCurrent(self)) return false;
        if (!self.pageReplySucceeded(verification, video, .ok)) return false;
        const outcome = try self.commitInput(.input_insert, target, video, page_token, plan.text);
        if (self.shortcutSuperseded(command.generation)) return false;
        if (outcome != .inserted) return self.rejectPage(outcome);
        self.report("弾幕を入力しました。");
        return true;
    }

    fn enqueueShortcut(self: *App, event: shortcuts.Event, video: ?operations.VideoId) !void {
        const scope: operations.SlotSource.Scope = switch (event.action) {
            .shared1, .shared2 => .shared,
            .profile1, .profile2 => scope: {
                const data = self.snapshot.data;
                if (data.preferences.auto_mode) break :scope .automatic;
                const selected = data.findProfile(data.preferences.input_profile_id);
                break :scope .{ .manual = if (selected) |profile| profile.id else "" };
            },
            else => return self.queue.enqueue(allocator, event, self.library_revision, video),
        };
        const library = try self.snapshot.retainLibrary();
        errdefer library.release();
        try self.queue.enqueueWithSlot(allocator, event, self.library_revision, video, .{
            .library = library,
            .scope = scope,
        });
    }

    fn verifyShortcutInput(self: *App, target: usize, video: operations.VideoId, page_token: operations.PageToken) !transport.Reply {
        var buffer: [64]u8 = undefined;
        const focus = self.queue.focus.take(&buffer);
        return if (focus.len == 0)
            self.requestOnPage(.verify_input, target, &video, &page_token, &.{})
        else
            self.requestOnPage(.verify_chat, target, &video, &page_token, &.{.{ .name = "FocusToken", .value = focus }});
    }

    fn insertFromPalette(self: *App, index: usize) void {
        if (self.updating_reaction_buttons or !self.paletteOperationsAllowed() or
            self.palette.refreshing or self.palette.resetting_search or self.palette.refresh_failed or self.palette.search_due != null) return;
        const context = self.paletteContext();
        self.deliverPaletteItem(index, context) catch |failure| {
            if (self.paletteContextCurrent(context) and (self.foreground(windows.number(context.target)) or
                self.foreground(windows.number(self.palette.window))))
            {
                self.refreshPalette();
                self.report(switch (failure) {
                    error.ProfileChanged => "配信者が変わりました。弾幕を選び直してください。",
                    error.ProfileSelectionNotSaved => "自動選択を保存できませんでした。",
                    error.ProfileLookupFailed => self.resolveFailureNotice(),
                    error.TargetChanged, error.ForegroundChanged => "changed",
                    error.VideoUnavailable => "unavailable",
                    else => self.cleanupNotice(failure) orelse @tagName(self.workerFailureReason(failure)),
                });
                self.palette.show();
            }
        };
        self.updateReactionButtons();
        self.finishQuit();
        if (self.queue.busy()) _ = win.PostMessageW(self.window, drain_message, 0, 0);
    }

    fn deliverPaletteItem(self: *App, index: usize, owner: PaletteContext) !void {
        if (self.modal or self.manager.isEditing()) return;
        if (self.quitting or self.queue.active or self.worker.active or self.reaction != null or index >= self.palette.count) return;
        const target = owner.target;
        if (input.browser(target) == null) return self.report("unavailable");
        const row = self.palette.rows[index];
        var plan = try InputPlan.capture(self, row.profile_id, row.item);
        defer plan.arena.deinit();
        const auto_profile = plan.scope.len != 0 and self.snapshot.data.preferences.auto_mode;
        _ = win.ShowWindow(self.palette.window, win.SW_HIDE);
        _ = win.SetForegroundWindow(target);
        const hwnd = windows.number(target);
        if (!self.foreground(hwnd)) return error.ForegroundChanged;
        if (auto_profile) self.palette.detected_profile = false;
        const context = try self.requestOnPage(if (auto_profile) .resolve else .browser_context, hwnd, "", "bind", &.{});
        defer context.deinit();
        if (self.modal or self.manager.isEditing()) return;
        if (!self.foreground(hwnd) or !self.paletteTargetCurrent(owner) or !plan.current(self)) return error.TargetChanged;
        if (!context.is("ok")) return if (auto_profile and context.is("unavailable"))
            error.ProfileLookupFailed
        else
            error.VideoUnavailable;
        const video = operations.videoId(context.field("Video")) orelse return error.VideoUnavailable;
        const page_token = operations.pageToken(context.field("PageToken")) orelse return error.TargetChanged;
        if (auto_profile) {
            _ = (self.selectDetectedProfile(context.field("Channel"), .immediate) catch return error.ProfileSelectionNotSaved) orelse
                return error.ProfileChanged;
            if (!self.paletteTargetCurrent(owner) or !plan.current(self)) return error.TargetChanged;
            if (!std.mem.eql(u8, context.field("Channel"), plan.channel)) return error.ProfileChanged;
        }
        const checked = try self.requestOnPage(.verify_input, hwnd, &video, &page_token, &.{});
        defer checked.deinit();
        if (self.modal or self.manager.isEditing()) return;
        if (!self.foreground(hwnd) or !self.paletteTargetCurrent(owner) or !plan.current(self)) return error.TargetChanged;
        if (!checked.is("ok") or !std.mem.eql(u8, checked.field("Video"), &video)) {
            self.report(checked.field("State"));
            self.palette.show();
            return;
        }
        const outcome = try self.commitInput(.input_insert, hwnd, video, page_token, plan.text);
        if (outcome != .inserted and !self.modal and !self.manager.isEditing() and
            self.paletteTargetCurrent(owner) and self.foreground(hwnd) and plan.current(self))
        {
            _ = self.rejectPage(outcome);
            self.palette.show();
        }
    }

    fn failReactionStart(self: *App, reason: feedback.Reason, detail: []const u8) bool {
        const revision = self.reaction_revision;
        const command = self.starting_reaction;
        self.starting_reaction = null;
        if (command) |starting| self.queue.finish(starting, false);
        self.updateReactionButtons();
        if (self.reaction_revision == revision) self.showReactionResult(feedback.Result.quickStart(reason, detail));
        return false;
    }

    fn reactionSetupFailed(self: *App, job: operations.Reaction, detail: []const u8) bool {
        if (job.shortcut != null) return self.failReactionStart(.unavailable, detail);
        self.publishReactionResult(.unavailable, null, detail);
        return false;
    }

    fn startReaction(self: *App, job: operations.Reaction, delay: u32) bool {
        if (self.reaction != null or self.quitting or job.count == 0) return false;
        const before_open = self.reaction_generation;
        const revision = self.reaction_revision;
        const clock = std.time.Timer.start() catch |failure| return self.reactionSetupFailed(job, @errorName(failure));
        self.openReactionProgress() catch |failure| {
            if (self.reaction_generation != before_open or (job.shortcut == null and self.reaction_revision != revision)) return false;
            if (job.shortcut) |command| if (!self.checkCommandTarget(command)) return false;
            return self.reactionSetupFailed(job, @errorName(failure));
        };
        if (self.reaction_generation != before_open or (job.shortcut == null and self.reaction_revision != revision)) return false;
        if (job.shortcut) |command| if (!self.checkCommandTarget(command)) return false;
        const generation = before_open +% 1;
        self.reaction_generation = generation;
        self.reaction_revision +%= 1;
        self.starting_reaction = null;
        self.reaction = job;
        self.reaction.?.due_ns = @as(u64, delay) * std.time.ns_per_ms;
        self.reaction_clock = clock;
        self.pending_reaction_start = .{ .generation = generation, .kind = .send, .wait_ms = @min(delay, 1000) };
        if (self.queue.target == job.target) {
            _ = self.queue.bindVideo(job.video);
            _ = self.queue.bindPage(job.page);
        }
        self.updateReactionButtons();
        // EnableWindow can dispatch a stop before control returns here.
        if (self.reaction_generation != generation or self.reaction == null) return true;
        if (delay == 0) {
            self.showReactionCounts("標準設定で実行します。", job, .running);
        } else self.showReactionCountdown(job, delay);
        return true;
    }

    fn reactionButtonsActive(self: *const App) bool {
        return self.reaction != null or self.preparation != null or self.quickReactionStarting() or self.reactionQueued();
    }

    fn updateReactionButtons(self: *App) void {
        if (self.updating_reaction_buttons) return;
        self.updating_reaction_buttons = true;
        defer self.updating_reaction_buttons = false;
        while (true) {
            const active = self.reactionButtonsActive();
            const can_edit = self.canEdit();
            const palette_allowed = self.paletteOperationsAllowed();
            self.palette.operationButtons(palette_allowed, active);
            self.manager.updateActions();
            if (active == self.reactionButtonsActive() and can_edit == self.canEdit() and
                palette_allowed == self.paletteOperationsAllowed()) return;
        }
    }

    fn syncOperationButtons(self: *App) void {
        if (self.palette.operations_allowed != self.paletteOperationsAllowed()) self.updateReactionButtons();
    }

    fn scheduleReactionAdvance(self: *App, generation: u64, wait_ms: u32) bool {
        if (wait_ms != 0) return self.setReactionTimer(.send, wait_ms);
        self.cancelReactionTimer();
        return win.PostMessageW(self.window, advance_reaction_message, generation, 0) != 0;
    }

    const ReactionTimer = struct {
        const Kind = enum { preparation, send };
        id: win.UINT_PTR,
        kind: Kind,
    };

    const ReactionStart = struct {
        generation: u64,
        kind: ReactionTimer.Kind,
        wait_ms: u32,
    };

    fn currentReactionStart(self: *const App, generation: u64) bool {
        return !self.quitting and self.pending_reaction_start != null and self.reaction_generation == generation;
    }

    fn completeReactionStart(self: *App, generation: u64, text_updated: bool) void {
        if (!self.currentReactionStart(generation)) return;
        const shown = text_updated and self.reaction_progress.showChecked();
        if (!self.currentReactionStart(generation)) return;
        const kind = self.pending_reaction_start.?.kind;
        const wait_ms = self.pending_reaction_start.?.wait_ms;
        self.pending_reaction_start = null;
        if (!shown) {
            switch (kind) {
                .send => self.finishReaction(.unavailable, "ShowReactionProgress"),
                .preparation => self.finishPreparation(.unavailable, "ShowReactionProgress"),
            }
            return;
        }
        switch (kind) {
            .send => if (!self.scheduleReactionAdvance(generation, wait_ms)) {
                self.finishReaction(.unavailable, "リアクションのタイマーを開始できませんでした。");
            },
            .preparation => if (!self.setReactionTimer(.preparation, wait_ms)) {
                self.finishPreparation(.unavailable, "リアクションの登録・確認のタイマーを開始できませんでした。");
            },
        }
    }

    fn setReactionTimer(self: *App, kind: ReactionTimer.Kind, wait_ms: u32) bool {
        self.cancelReactionTimer();
        // KillTimer does not remove a WM_TIMER that is already queued.
        const id = self.next_reaction_timer_id;
        self.next_reaction_timer_id = @max(first_reaction_timer_id, id +% 1);
        if (win.SetTimer(self.window, id, wait_ms, null) == 0) return false;
        self.reaction_timer = .{ .id = id, .kind = kind };
        return true;
    }

    fn cancelReactionTimer(self: *App) void {
        const timer = self.reaction_timer orelse return;
        self.reaction_timer = null;
        _ = win.KillTimer(self.window, timer.id);
    }

    fn openReactionProgress(self: *App) !void {
        try self.reaction_progress.open(self.window);
        self.reaction_hide_at = null;
        _ = win.KillTimer(self.window, timer_reaction_feedback);
    }

    const ReactionProgressUpdate = struct {
        text: [reaction_summary_capacity]u8 = undefined,
        len: usize,
        phase: feedback.Phase,
        revision: u64,
    };

    fn updateReactionProgress(self: *App, message: []const u8, phase: feedback.Phase) void {
        var update: ReactionProgressUpdate = .{ .len = message.len, .phase = phase, .revision = self.reaction_revision };
        @memcpy(update.text[0..update.len], message);
        self.pending_reaction_progress = update;
        // Win32 control updates are synchronous. A newer, nested update takes precedence.
        if (self.rendering_reaction_progress) return;
        self.rendering_reaction_progress = true;
        defer self.rendering_reaction_progress = false;
        while (self.pending_reaction_progress) |current_update| {
            self.pending_reaction_progress = null;
            const terminal = current_update.phase == .finished;
            if (terminal and current_update.revision != self.reaction_revision) continue;
            const start_generation = if (current_update.phase == .running and self.pending_reaction_start != null)
                self.pending_reaction_start.?.generation
            else
                null;
            const text = current_update.text[0..current_update.len];
            const status_updated = self.palette.reaction_notice == null or windows.setTextChecked(self.palette.reaction_notice, text);
            if (self.pending_reaction_progress != null or (terminal and current_update.revision != self.reaction_revision)) continue;
            const overlay_updated = self.reaction_progress.update(text, self.keyboard.tracker.bindings, current_update.phase);
            self.reaction_render_at = win.GetTickCount64();
            // Only the first visible update may arm this operation. Either Win32 call can reenter and stop it.
            if (start_generation) |generation| self.completeReactionStart(generation, status_updated and overlay_updated);
        }
    }

    fn reactionCounts(job: operations.Reaction) feedback.Counts {
        return .{ .completed = job.completed, .total = job.count, .mean_ms = job.meanStartIntervalMs() };
    }

    fn showReactionCounts(self: *App, caption: []const u8, job: operations.Reaction, phase: feedback.Phase) void {
        var counts: [120]u8 = undefined;
        var message: [360]u8 = undefined;
        const text = reactionCounts(job).text(&counts) catch unreachable;
        self.updateReactionProgress(std.fmt.bufPrint(&message, "{s}\r\n{s}", .{ caption, text }) catch unreachable, phase);
    }

    fn showReactionCountdown(self: *App, job: operations.Reaction, remaining: u64) void {
        var buffer: [180]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "今回の設定で{d}秒後に実行します。♡のメニューを開いてください。", .{(remaining + 999) / 1000}) catch unreachable;
        self.showReactionCounts(text, job, .running);
    }

    fn publishReactionResult(self: *App, reason: feedback.Reason, counts: ?feedback.Counts, detail: []const u8) void {
        self.showReactionResult(feedback.Result.init(reason, counts, detail));
    }

    fn showReactionResult(self: *App, result: feedback.Result) void {
        self.reaction_revision +%= 1;
        const revision = self.reaction_revision;
        if (self.reaction_result) |previous| previous.deinit();
        self.reaction_result = result;
        if (self.quitting) return;
        self.reaction_progress.open(self.window) catch {};
        if (self.reaction_revision != revision) return;
        var summary: [reaction_summary_capacity]u8 = undefined;
        self.updateReactionProgress(result.summary(&summary), .finished);
        if (self.reaction_revision != revision or self.quitting or self.reaction != null or self.preparation != null or self.reaction_progress.window == null) return;
        self.reaction_hide_at = win.GetTickCount64() + 4000;
        if (win.SetTimer(self.window, timer_reaction_feedback, 4000, null) == 0) {
            self.reaction_progress.hide();
            self.reaction_hide_at = null;
        } else self.reaction_progress.show();
    }

    fn hideFinishedReaction(self: *App) void {
        const due = self.reaction_hide_at orelse return;
        const now = win.GetTickCount64();
        if (now < due) {
            _ = win.SetTimer(self.window, timer_reaction_feedback, @intCast(due - now), null);
            return;
        }
        self.reaction_hide_at = null;
        _ = win.KillTimer(self.window, timer_reaction_feedback);
        self.reaction_progress.hide();
    }

    const ReactionContext = struct { video: operations.VideoId, page: operations.PageToken };
    const ReactionOrigin = struct { target: win.HWND, foreground: win.HWND, generation: u64, revision: u64 };

    fn reactionOrigin(self: *const App) ReactionOrigin {
        return .{ .target = self.target, .foreground = win.GetForegroundWindow(), .generation = self.reaction_generation, .revision = self.reaction_revision };
    }

    fn reactionContextCurrent(self: *const App, origin: ReactionOrigin) bool {
        return !self.quitting and self.target == origin.target and self.reaction_generation == origin.generation and
            self.reaction_revision == origin.revision;
    }

    fn reactionContext(self: *App, origin: ReactionOrigin) ?ReactionContext {
        if (origin.foreground == null or win.GetForegroundWindow() != origin.foreground or input.browser(origin.target) == null) {
            self.publishReactionResult(.wrong_window, null, "");
            return null;
        }
        defer {
            self.finishQuit();
            if (!self.quitting and self.queue.busy()) _ = win.PostMessageW(self.window, drain_message, 0, 0);
        }
        const response = self.requestOnPage(.browser_context, windows.number(origin.target), "", "bind", &.{}) catch |failure| {
            var detail: [256]u8 = undefined;
            if (self.reactionContextCurrent(origin)) self.publishReactionResult(.unavailable, null, self.workerFailureDetail(failure, &detail));
            return null;
        };
        defer response.deinit();
        if (!self.reactionContextCurrent(origin)) return null;
        if (win.GetForegroundWindow() != origin.foreground) {
            self.publishReactionResult(.wrong_window, null, "");
            return null;
        }
        if (!response.is("ok")) {
            self.publishReactionResult(feedback.Reason.fromReply(response.field("State")), null, response.field("Detail"));
            return null;
        }
        const video = operations.videoId(response.field("Video")) orelse {
            self.publishReactionResult(.unavailable, null, "");
            return null;
        };
        const page_proof = operations.pageToken(response.field("PageToken")) orelse unreachable;
        return .{ .video = video, .page = page_proof };
    }

    fn saveReactionDefaults(self: *App, options: view.ReactionOptions) !void {
        var prefs = self.snapshot.data.preferences;
        if (prefs.reaction_kind == options.kind and prefs.reaction_count == options.count and
            prefs.reaction_interval_ms == options.interval) return;
        prefs.reaction_kind = options.kind;
        prefs.reaction_count = options.count;
        prefs.reaction_interval_ms = options.interval;
        try self.writePreferences(prefs);
    }

    fn paletteReaction(self: *App, options: view.ReactionOptions, save: bool) void {
        if (self.updating_reaction_buttons or !self.canEdit() or self.manager.isEditing()) return;
        if (save) {
            self.saveReactionDefaults(options) catch return self.palette.settingsStatus("標準設定を保存できませんでした。");
            return self.palette.settingsStatus("リアクションの標準設定を保存しました。ショートカット実行にも使います。");
        }
        const origin = self.reactionOrigin();
        if (origin.foreground != self.palette.window) return self.publishReactionResult(.wrong_window, null, "");
        const context = self.reactionContext(origin) orelse return;
        const delay = 3000;
        _ = win.ShowWindow(self.palette.window, win.SW_HIDE);
        _ = win.SetForegroundWindow(origin.target);
        if (!self.reactionContextCurrent(origin)) return;
        _ = self.startReaction(.{
            .target = windows.number(origin.target),
            .video = context.video,
            .page = context.page,
            .kind = options.kind,
            .count = options.count,
            .interval = options.interval,
        }, delay);
    }

    fn startPreparation(self: *App, mode: transport.Mode) void {
        if (!self.canEdit() or self.manager.isEditing()) return;
        const origin = self.reactionOrigin();
        if (origin.foreground != null and origin.foreground == self.manager.window and input.browser(origin.target) == null) {
            const notice = "YouTubeを前面にし、パレットを開いて対象を選んでください。";
            const result = feedback.Result.init(.wrong_window, null, notice);
            self.manager.setNotice(notice);
            if (self.reactionContextCurrent(origin)) self.showReactionResult(result) else result.deinit();
            return;
        }
        const target = windows.number(origin.target);
        const context = self.reactionContext(origin) orelse return;
        _ = win.ShowWindow(self.palette.window, win.SW_HIDE);
        if (self.manager.window != null) _ = win.ShowWindow(self.manager.window, win.SW_HIDE);
        _ = win.SetForegroundWindow(origin.target);
        if (!self.reactionContextCurrent(origin)) return;
        self.openReactionProgress() catch |failure| {
            if (self.reactionContextCurrent(origin)) self.publishReactionResult(.unavailable, null, @errorName(failure));
            return;
        };
        if (!self.reactionContextCurrent(origin)) return;
        const delay: u32 = if (mode == .reaction_capture) 1000 else 5000;
        self.reaction_generation +%= 1;
        self.reaction_revision +%= 1;
        self.pending_reaction_start = .{ .generation = self.reaction_generation, .kind = .preparation, .wait_ms = 1000 };
        self.preparation = .{
            .mode = mode,
            .target = target,
            .video = context.video,
            .page = context.page,
            .generation = self.reaction_generation,
            .due = win.GetTickCount64() + delay,
            .browser = diagnostic.Browser.fromName(input.browser(origin.target)),
        };
        const pending = self.preparation.?;
        if (self.queue.target == target) {
            _ = self.queue.bindVideo(context.video);
            _ = self.queue.bindPage(context.page);
        }
        self.updateReactionButtons();
        if (!self.preparationCurrent(pending)) return;
        if (mode == .reaction_capture) {
            self.updateReactionProgress("登録を待っています。♡のメニューを開き、マウスをメニューに重ねてください。", .running);
        } else self.showPreparationCountdown(delay);
    }

    fn preparationCurrent(self: *const App, pending: Preparation) bool {
        return !self.quitting and self.preparation != null and self.reaction_generation == pending.generation;
    }

    fn schedulePreparation(self: *App, pending: Preparation, wait: u32) bool {
        if (!self.preparationCurrent(pending)) return false;
        if (self.setReactionTimer(.preparation, wait)) return true;
        self.finishPreparation(.unavailable, "リアクションの準備タイマーを再開できませんでした。");
        return false;
    }

    fn prepareNow(self: *App) void {
        if (self.pending_reaction_start != null) return;
        if (self.worker.active) return;
        const pending = self.preparation orelse return;
        if (!self.foreground(pending.target)) return self.finishPreparation(.wrong_window, "");
        const now = win.GetTickCount64();
        if (now < pending.due) {
            if (pending.mode == .reaction_check) self.showPreparationCountdown(pending.due - now);
            const wait: u32 = @intCast(@min(pending.due - now, 1000));
            _ = self.schedulePreparation(pending, wait);
            return;
        }
        self.cancelReactionTimer();
        self.preparation.?.started_at = now;
        defer self.finishQuit();
        self.updateReactionProgress(if (pending.mode == .reaction_capture) "ボタンを登録しています。" else "5種類のボタンを確認しています。", .running);
        if (!self.preparationCurrent(pending)) return;
        const retry = self.captureOrCheck(pending) catch |failure| {
            var detail: [256]u8 = undefined;
            if (self.preparationCurrent(pending)) self.finishPreparation(.unavailable, self.workerFailureDetail(failure, &detail));
            return;
        };
        if (!retry or !self.preparationCurrent(pending)) return;
        self.updateReactionProgress("登録を待っています。♡のメニューを開き、マウスをメニューに重ねてください。", .running);
        if (self.schedulePreparation(pending, 1000)) self.preparation.?.due = win.GetTickCount64() + 1000;
    }

    fn showPreparationCountdown(self: *App, remaining: u64) void {
        var buffer: [180]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}秒後に、送信せずに確認します。♡のメニューを開いてください。", .{(remaining + 999) / 1000}) catch unreachable;
        self.updateReactionProgress(text, .running);
    }

    fn finishPreparation(self: *App, reason: feedback.Reason, detail: []const u8) void {
        const pending = self.preparation orelse return;
        const revision = self.reaction_revision;
        self.preparation = null;
        self.pending_reaction_start = null;
        self.cancelReactionTimer();
        self.updateReactionButtons();
        // A committed registration still needs its confirmation even if another key is waiting.
        if (self.reaction_revision == revision and (pending.committed or !self.reactionQueued() or self.queue.target == pending.target)) {
            if (pending.mode == .reaction_capture) {
                if (self.last_page) |*page_operation| page_operation.latest = false;
                self.last_registration = .{
                    .browser = pending.browser,
                    .state = switch (reason) {
                        .saved => .registered,
                        .saved_sync_failed => .sync_failed,
                        .stopped => .cancelled,
                        else => diagnostic.State.fromCode(@tagName(reason)),
                    },
                    .elapsed_ms = if (pending.started_at) |started| win.GetTickCount64() -| started else 0,
                };
            }
            self.publishReactionResult(reason, null, detail);
        }
        if (!self.quitting) _ = win.PostMessageW(self.window, drain_message, 0, 0);
    }

    fn captureOrCheck(self: *App, pending: Preparation) !bool {
        if (!self.foreground(pending.target)) {
            self.finishPreparation(.wrong_window, "");
            return false;
        }
        var sync_detail: [256]u8 = undefined;
        if (self.syncRegistration(pending.target, &sync_detail)) |detail| {
            if (self.preparationCurrent(pending)) self.finishPreparation(.sync_failed, detail);
            return false;
        }
        if (!self.preparationCurrent(pending)) return false;
        if (!self.foreground(pending.target)) {
            self.finishPreparation(.wrong_window, "");
            return false;
        }
        var x_buffer: [11]u8 = undefined;
        var y_buffer: [11]u8 = undefined;
        var capture_fields: [2]transport.Field = undefined;
        const fields: []const transport.Field = if (pending.mode == .reaction_capture) fields: {
            var point: win.POINT = undefined;
            if (win.GetPhysicalCursorPos(&point) == 0) return error.CursorPosition;
            capture_fields = captureFields(point, &x_buffer, &y_buffer);
            break :fields &capture_fields;
        } else &.{};
        const reply = try self.requestOnPage(pending.mode, pending.target, &pending.video, &pending.page, fields);
        defer reply.deinit();
        if (!self.preparationCurrent(pending)) return false;
        if (Preparation.retries(pending.mode, reply.field("State"))) return true;
        if (!self.foreground(pending.target)) {
            self.finishPreparation(.wrong_window, "");
            return false;
        }
        if (pending.mode == .reaction_capture and reply.is("captured")) {
            self.db.saveRegistration(reply.field("Detail")) catch |failure| {
                self.finishPreparation(.save_failed, @errorName(failure));
                return false;
            };
            self.preparation.?.committed = true;
            self.worker.registrations_current = false;
            self.refreshRegistrationStatus();
            self.updateReactionProgress("登録を保存しました。ワーカーへ反映しています。", .running);
            if (self.syncRegistration(pending.target, &sync_detail)) |detail| {
                self.finishPreparation(.saved_sync_failed, detail);
                return false;
            }
            self.finishPreparation(.saved, "");
        } else self.finishPreparation(feedback.Reason.fromReply(reply.field("State")), reply.field("Detail"));
        return false;
    }

    fn advanceReaction(self: *App) void {
        if (self.pending_reaction_start != null) return;
        if (self.worker.active) return;
        const job = if (self.reaction) |*job| job else return;
        if (job.active_request) return;
        if (!self.reactionTargetCurrent(job)) return self.finishReaction(.wrong_window, "");
        const generation = self.reaction_generation;
        const now = self.reaction_clock.?.read();
        if (!job.begin(now)) {
            const wait = job.remainingMs(now);
            if (wait != 0) {
                if (job.completed == 0 and job.shortcut == null) self.showReactionCountdown(job.*, wait);
                if (self.reaction_generation != generation or self.reaction == null) return;
                // A Win32 timer may wake early. Register only the remaining wait.
                if (!self.scheduleReactionAdvance(generation, @min(wait, 1000)))
                    self.finishReaction(.unavailable, "リアクションのタイマーを再開できませんでした。");
            }
            return;
        }
        self.cancelReactionTimer();
        defer self.finishQuit();
        const reply = (self.operateReaction(job) catch |failure| {
            _ = job.acknowledge(false);
            var detail: [256]u8 = undefined;
            return self.finishReaction(switch (failure) {
                error.Stopped => .stopped,
                error.TargetChanged => .wrong_window,
                else => self.workerFailureReason(failure),
            }, self.workerFailureDetail(failure, &detail));
        }) orelse return;
        defer reply.deinit();
        const operated = reply.is("operated");
        if (job.shortcut) |command| {
            if (!self.queue.accepts(command, job.target)) job.stop();
        }
        if (!job.acknowledge(operated)) {
            const reason: feedback.Reason = if (!operated)
                feedback.Reason.fromReply(reply.field("State"))
            else if (job.stop_requested)
                .stopped
            else
                .completed;
            return self.finishReaction(reason, reply.field("Detail"));
        }
        const observed_at = win.GetTickCount64();
        if (observed_at - self.reaction_render_at >= 100 or job.remainingMs(self.reaction_clock.?.read()) >= 100)
            self.showReactionCounts("リアクションを実行中です。", job.*, .running);
        if (self.reaction_generation != generation or self.reaction == null) return;
        const wait = job.remainingMs(self.reaction_clock.?.read());
        if (!self.scheduleReactionAdvance(generation, wait))
            self.finishReaction(.unavailable, "リアクションのタイマーを再開できませんでした。");
    }

    fn reactionTargetCurrent(self: *App, job: *const operations.Reaction) bool {
        if (job.stop_requested or !self.foreground(job.target)) return false;
        return if (job.shortcut) |command| self.queue.accepts(command, job.target) else true;
    }

    fn operateReaction(self: *App, job: *operations.Reaction) !?transport.Reply {
        var sync_detail: [256]u8 = undefined;
        const synchronization_failure = self.syncRegistration(job.target, &sync_detail);
        if (job.stop_requested) return error.Stopped;
        if (!self.reactionTargetCurrent(job)) return error.TargetChanged;
        if (synchronization_failure) |detail| {
            _ = job.acknowledge(false);
            self.finishReaction(.sync_failed, detail);
            return null;
        }
        const kind = if (job.kind == 6) std.crypto.random.intRangeAtMost(u8, 1, 5) else job.kind;
        const digit = [_]u8{'0' + kind};
        job.markSendStart(self.reaction_clock.?.read());
        return try self.requestOnPage(.reaction_send, job.target, &job.video, &job.page, &.{.{ .name = "Reaction", .value = &digit }});
    }

    fn finishReaction(self: *App, reason: feedback.Reason, detail: []const u8) void {
        const job = self.reaction orelse return;
        const revision = self.reaction_revision;
        const superseded = job.stop_requested or self.queue.target != job.target or
            if (job.shortcut) |command| command.generation != self.queue.generation else false;
        self.reaction = null;
        self.reaction_clock = null;
        self.pending_reaction_start = null;
        self.cancelReactionTimer();
        if (job.shortcut) |command| self.queue.finish(command, job.succeeded());
        self.updateReactionButtons();
        // A replacement queued during the old request owns the next result and progress display.
        if (self.reaction_revision == revision and !(superseded and self.reactionQueued())) {
            var result = feedback.Result.init(reason, reactionCounts(job), detail);
            result.settings = .{ .kind = job.kind, .standard = job.shortcut != null };
            self.showReactionResult(result);
        }
        if (!self.quitting) _ = win.PostMessageW(self.window, drain_message, 0, 0);
    }
};

fn captureFields(point: win.POINT, x: *[11]u8, y: *[11]u8) [2]transport.Field {
    return .{
        .{ .name = "X", .value = std.fmt.bufPrint(x, "{d}", .{point.x}) catch unreachable },
        .{ .name = "Y", .value = std.fmt.bufPrint(y, "{d}", .{point.y}) catch unreachable },
    };
}

test "registration sends signed physical coordinates and only retries registration misses" {
    var x: [11]u8 = undefined;
    var y: [11]u8 = undefined;
    const fields = captureFields(.{ .x = -2147483648, .y = 1200 }, &x, &y);
    try std.testing.expectEqualStrings("X", fields[0].name);
    try std.testing.expectEqualStrings("-2147483648", fields[0].value);
    try std.testing.expectEqualStrings("Y", fields[1].name);
    try std.testing.expectEqualStrings("1200", fields[1].value);
    try std.testing.expect(App.Preparation.retries(.reaction_capture, "unsupported"));
    try std.testing.expect(App.Preparation.retries(.reaction_capture, "wrong_window"));
    try std.testing.expect(!App.Preparation.retries(.reaction_capture, "changed"));
    try std.testing.expect(!App.Preparation.retries(.reaction_capture, "captured"));
    try std.testing.expect(!App.Preparation.retries(.reaction_check, "unsupported"));
    try std.testing.expect(!App.Preparation.retries(.reaction_check, "wrong_window"));
}

test "diagnostics publish version and runtime conditions without sharing user data" {
    const testing = std.testing;
    const heap = testing.allocator;
    const body = "PRIVATE-DANMAKU-BODY-5C23";
    const url = "https://www.youtube.com/watch?v=Private0099";
    const name = "PRIVATE-CHANNEL-NAME-5C23";
    const settings_path = "C:\\PRIVATE-SETTINGS-5C23\\settings.db";
    const install_name = "PRIVATE-INSTALL-5C23.exe";
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(.{ .sub_path = install_name, .data = "startup binary bytes" });
    const path = try directory.dir.realpathAlloc(heap, install_name);
    defer heap.free(path);
    const executable = try std.unicode.utf8ToUtf16LeAllocZ(heap, path);
    defer heap.free(executable);
    var stored_path = settings_path.*;
    var db: storage.Store = undefined;
    db.path = &stored_path;

    const detail = body ++ "\r\n" ++ url ++ "\r\n" ++ name ++ "\r\n" ++ settings_path;
    var app: App = .{
        .executable = executable,
        .db = &db,
        .snapshot = .{
            .arena = std.heap.ArenaAllocator.init(heap),
            .data = .{
                .profiles = &.{.{ .id = "caster", .name = name, .channel = "/@secret-caster" }},
                .shared_items = &.{.{ .id = "shared", .name = "合成弾幕", .text = body }},
            },
        },
        .history = undefined,
        .running_digest = try readExecutableDigest(executable),
        .last_mode = .reaction_send,
        .last_state = "menu_closed",
        .last_elapsed = 1234,
        .reaction_result = feedback.Result.init(.unknown, null, detail),
    };
    defer app.snapshot.deinit();
    defer if (app.reaction_result) |result| result.deinit();

    var buffer: [1024]u8 = undefined;
    const published = try app.diagnosticSnapshot(5000).format(&buffer, version);
    try testing.expect(std.mem.startsWith(u8, published, "ChatPalette " ++ version ++ "\r\n"));
    for ([_][]const u8{
        "起動時の配布物と一致",
        "直近の操作 reaction_send",
        "結果 menu_closed",
        "処理時間 1234 ms",
        "リアクション 終了 (finished)",
        "再起動は現在の展開先の ChatPalette.exe",
    }) |expected| try testing.expect(std.mem.indexOf(u8, published, expected) != null);
    for ([_][]const u8{ body, url, name, settings_path, install_name, path, "/@secret-caster" }) |private| {
        try testing.expect(std.mem.indexOf(u8, published, private) == null);
    }

    // Unknown protocol values are summarized rather than copied as text.
    app.last_state = detail;
    const sanitized = try app.diagnosticSnapshot(5000).format(&buffer, version);
    try testing.expect(std.mem.indexOf(u8, sanitized, "結果 unknown") != null);
    try testing.expect(std.mem.indexOf(u8, sanitized, body) == null);
    try testing.expectEqual(diagnostic.Browser.unselected, diagnostic.Browser.fromName(url));

    try directory.dir.writeFile(.{ .sub_path = install_name, .data = "replaced binary bytes" });
    try testing.expectEqual(diagnostic.Distribution.modified, app.diagnosticSnapshot(5000).distribution);
    app.executable = windows.wide("");
    try testing.expectEqual(diagnostic.Distribution.disk_unknown, app.diagnosticSnapshot(5000).distribution);
    app.running_digest = null;
    try testing.expectEqual(diagnostic.Distribution.running_unknown, app.diagnosticSnapshot(5000).distribution);
}

test "desktop: a page acknowledgement requires the expected video and reports the rejection" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    var app: App = .{
        .executable = windows.wide(""),
        .db = undefined,
        .snapshot = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .data = .{} },
        .history = undefined,
        .running_digest = null,
        .last_mode = .verify_chat,
    };
    defer app.snapshot.deinit();
    try app.palette.open(null);
    defer app.palette.close();
    const expected = operations.videoId("ZigTest0001").?;
    const accepted: transport.Reply = .{ .alloc = testing.allocator, .payload = "State=ok\nVideo=ZigTest0001\n" };
    try testing.expect(app.pageReplySucceeded(accepted, expected, .ok));
    for ([_][]const u8{ "ZigTest0002", "" }) |video| {
        const frame = try std.fmt.allocPrint(testing.allocator, "State=ok\nVideo={s}\n", .{video});
        defer testing.allocator.free(frame);
        try testing.expect(!app.pageReplySucceeded(.{ .alloc = testing.allocator, .payload = frame }, expected, .ok));
        try testing.expectEqual(diagnostic.State.changed, app.diagnosticSnapshot(0).state);
        const notice = try windows.text(app.palette.message, testing.allocator);
        defer testing.allocator.free(notice);
        try testing.expectEqualStrings("動画・タブ・ウィンドウが切り替わりました。", notice);
    }
    for ([_]diagnostic.State{ .wrong_input, .changed, .unavailable, .unknown }) |state| {
        const frame = try std.fmt.allocPrint(testing.allocator, "State={s}\nVideo=ZigTest0001\n", .{@tagName(state)});
        defer testing.allocator.free(frame);
        try testing.expect(!app.pageReplySucceeded(.{ .alloc = testing.allocator, .payload = frame }, expected, .ok));
        try testing.expectEqual(state, app.diagnosticSnapshot(0).state);
    }
}

test "desktop: palette operation buttons follow the worker wait, search publication and stop" {
    try @import("test_mode.zig").requireDesktop();
    const Probe = struct {
        const inspect = win.WM_APP + 155;
        var observed_waits: usize = 0;
        var observed_draws: usize = 0;
        var forwarded: usize = 0;
        var blocked = true;

        fn buttons(p: *const view.Palette, insert: bool, options: bool) bool {
            return (win.IsWindowEnabled(p.insert_button) != 0) == insert and
                (win.IsWindowEnabled(p.start_button) != 0) == options and
                (win.IsWindowEnabled(p.save_defaults) != 0) == options;
        }

        fn click(p: *const view.Palette) void {
            for ([_]win.HWND{ p.insert_button, p.start_button, p.save_defaults }) |button| {
                _ = win.SendMessageW(p.window, win.WM_COMMAND, @intCast(win.GetDlgCtrlID(button)), @bitCast(@intFromPtr(button)));
            }
        }

        fn host(hwnd: win.HWND, message: win.UINT, w: win.WPARAM, l: win.LPARAM, _: usize, _: usize) callconv(.winapi) win.LRESULT {
            if (message == inspect) {
                const p = &current.?.palette;
                observed_waits += 1;
                blocked = blocked and buttons(p, false, false);
                windows.setText(p.search, "absent");
                windows.setText(p.search, "");
                blocked = blocked and buttons(p, false, false);
                click(p);
                return 0;
            }
            if (message == view.wm_insert or message == view.wm_start_reaction or message == view.wm_save_defaults) {
                forwarded += 1;
                return 0;
            }
            return win.DefSubclassProc(hwnd, message, w, l);
        }

        fn list(hwnd: win.HWND, message: win.UINT, w: win.WPARAM, l: win.LPARAM, _: usize, _: usize) callconv(.winapi) win.LRESULT {
            if (message == win.LB_ADDSTRING) {
                const p = &current.?.palette;
                observed_draws += 1;
                blocked = blocked and buttons(p, false, false);
                click(p);
            }
            return win.DefSubclassProc(hwnd, message, w, l);
        }

        fn exchange(client: *transport.Client, alloc: std.mem.Allocator, _: [:0]const u16, _: transport.Mode, fail: usize, _: []const u8, _: []const transport.Field, wait: transport.Pump) !transport.Reply {
            client.active = true;
            defer client.active = false;
            const signal = win.CreateEventW(null, 1, 1, null) orelse return error.CreateTestEvent;
            defer _ = win.CloseHandle(signal);
            if (win.PostMessageW(current.?.window, inspect, 0, 0) == 0) return error.PostTestMessage;
            try wait(signal, 0);
            if (fail != 0) return error.ReadWorkerReply;
            return .{ .alloc = alloc, .payload = try alloc.dupe(u8, "State=ok\n") };
        }
    };
    var app: App = .{ .executable = windows.wide("fixture"), .db = undefined, .snapshot = undefined, .history = undefined, .running_digest = null };
    const previous = current;
    current = &app;
    defer current = previous;
    app.window = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), 0, 0, 0, 10, 10, null, null, win.GetModuleHandleW(null), null) orelse return error.CreateTestWindow;
    defer _ = win.DestroyWindow(app.window);
    defer app.queue.deinit(allocator);
    try app.palette.open(app.window);
    defer app.palette.close();
    try std.testing.expect(win.SetWindowSubclass(app.window, Probe.host, 87, 0) != 0);
    defer _ = win.RemoveWindowSubclass(app.window, Probe.host, 87);
    try std.testing.expect(win.SetWindowSubclass(app.palette.list, Probe.list, 87, 0) != 0);
    defer _ = win.RemoveWindowSubclass(app.palette.list, Probe.list, 87);
    const data: storage.Data = .{ .shared_items = &.{.{ .id = "fixture", .name = "one", .text = "text", .slot = 0 }} };
    app.palette.resetReaction(data.preferences);
    app.palette.refresh(data);
    try std.testing.expect(Probe.buttons(&app.palette, true, true));
    windows.setText(app.palette.search, "absent");
    try std.testing.expect(Probe.buttons(&app.palette, false, true));
    windows.setText(app.palette.search, "");
    const reply = try app.requestUsing(.browser_context, 0, "", &.{}, Probe.exchange);
    defer reply.deinit();
    try std.testing.expect(Probe.buttons(&app.palette, true, true));
    try std.testing.expectError(error.ReadWorkerReply, app.requestUsing(.browser_context, 1, "", &.{}, Probe.exchange));
    try std.testing.expect(Probe.buttons(&app.palette, true, true));
    try app.queue.enqueue(allocator, .{ .action = .chat_focus, .window = 1 }, 0, null);
    app.syncOperationButtons();
    try std.testing.expect(Probe.buttons(&app.palette, false, false));
    app.stop();
    try std.testing.expect(Probe.buttons(&app.palette, true, true));
    defer app.reaction_progress.close();
    defer if (app.reaction_result) |result| result.deinit();
    app.reaction = .{ .target = 1, .video = "Fixture0001".*, .page = @splat(0), .kind = 1, .count = 5, .interval = 200 };
    app.updateReactionButtons();
    try std.testing.expect(Probe.buttons(&app.palette, false, false) and win.IsWindowEnabled(app.palette.stop_button) != 0);
    app.stop();
    try std.testing.expect(Probe.buttons(&app.palette, true, true) and win.IsWindowEnabled(app.palette.stop_button) == 0);
    try std.testing.expect(Probe.observed_waits == 2 and Probe.observed_draws >= 4 and Probe.blocked and Probe.forwarded == 0);
}

fn expectModeless(condition: bool, comptime message: []const u8, args: anytype) !void {
    if (condition) return;
    std.debug.print("Modeless document check: " ++ message ++ "\n", args);
    return error.TestUnexpectedResult;
}

test "desktop: modeless diagnostics and reaction details leave waiting and palette ownership intact" {
    try @import("test_mode.zig").requireDesktop();
    const ActivationProbe = struct {
        threadlocal var activated: win.HWND = null;

        fn observe(code: c_int, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
            if (code == win.HCBT_ACTIVATE) activated = @ptrFromInt(wparam);
            return win.CallNextHookEx(null, code, wparam, lparam);
        }
    };
    const CopyProbe = struct {
        shown: []const u8,
        copied_snapshot: bool = false,

        fn observe(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, context: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            if (message != win.WM_COPY) return win.DefSubclassProc(hwnd, message, wparam, lparam);
            const self: *@This() = @ptrFromInt(context);
            const text = windows.text(hwnd, std.testing.allocator) catch return 0;
            defer std.testing.allocator.free(text);
            self.copied_snapshot = std.mem.eql(u8, self.shown, text);
            return 0; // Observe the native copy request without writing the clipboard.
        }
    };
    const t = std.testing;
    var directory = t.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.db" });
    defer t.allocator.free(path);
    var db = try storage.Store.open(t.allocator, path);
    defer db.close();
    try db.save(.{ .preferences = .{ .auto_mode = false } });
    var wc = std.mem.zeroes(win.WNDCLASSW);
    wc.hInstance = win.GetModuleHandleW(null);
    wc.lpszClassName = windows.wide("ChatPalette.ModelessInformationTest");
    wc.lpfnWndProc = messageHandler;
    if (win.RegisterClassW(&wc) == 0) return error.RegisterInformationHost;
    defer _ = win.UnregisterClassW(wc.lpszClassName, wc.hInstance);
    var app: App = .{
        .executable = windows.wide("information-fixture.exe"),
        .db = &db,
        .snapshot = try db.load(t.allocator),
        .history = storage.LibraryHistory.init(t.allocator),
        .running_digest = null,
    };
    var live = true;
    defer if (live) app.deinit();
    current = &app;
    defer current = null;
    app.window = win.CreateWindowExW(0, wc.lpszClassName, windows.wide(""), 0, 0, 0, 1, 1, null, null, wc.hInstance, null) orelse
        return error.CreateInformationHost;
    try app.palette.open(app.window);
    const palette = app.palette.window;
    _ = win.ShowWindow(palette, win.SW_SHOWNOACTIVATE);
    const target = app.window;
    app.target = target;
    app.preparation = .{
        .mode = .reaction_capture,
        .target = windows.number(target),
        .video = "ZigTest0001".*,
        .page = @splat('a'),
        .generation = app.reaction_generation,
        .due = win.GetTickCount64() + 60_000,
    };
    // Capture activation on this GUI thread, independently of other desktop windows.
    const activation_hook = win.SetWindowsHookExW(win.WH_CBT, @ptrCast(&ActivationProbe.observe), null, win.GetCurrentThreadId()) orelse
        return error.InstallDocumentActivationProbe;
    defer _ = win.UnhookWindowsHookEx(activation_hook);
    ActivationProbe.activated = null;
    app.menuCommand(menu_diag);
    const diagnostics_window = app.diagnostic_view.dialog.window orelse return error.ShowDiagnosticView;
    try expectModeless(ActivationProbe.activated == null, "diagnostic display activated window {x}", .{windows.number(ActivationProbe.activated)});
    const diagnostic_edit = win.GetDlgItem(diagnostics_window, 100);
    const registration_text = try windows.text(diagnostic_edit, t.allocator);
    defer t.allocator.free(registration_text);
    try expectModeless(std.mem.indexOf(u8, registration_text, "(waiting)") != null, "registration snapshot omitted waiting", .{});
    try expectModeless(!app.modal and app.preparation != null and !app.canEdit(), "registration changed after opening diagnostics: modal={} preparation={} allowed={}", .{ app.modal, app.preparation != null, app.canEdit() });
    const owner = win.GetWindow(diagnostics_window, win.GW_OWNER);
    try expectModeless(owner == palette and win.IsWindowEnabled(palette) != 0, "diagnostics owner: palette={x} owner={x} enabled={d}", .{ windows.number(palette), windows.number(owner), win.IsWindowEnabled(palette) });

    app.preparation = null;
    app.reaction_clock = try std.time.Timer.start();
    app.reaction = .{
        .target = windows.number(target),
        .video = "ZigTest0001".*,
        .page = @splat('a'),
        .kind = 1,
        .count = 3,
        .interval = 2000,
        .due_ns = 60 * std.time.ns_per_s,
    };
    app.worker.active = true;
    app.last_mode = .reaction_send;
    app.last_state = "menu_closed";
    app.menuCommand(menu_diag);
    try t.expectEqual(diagnostics_window, app.diagnostic_view.dialog.window);
    try expectModeless(app.worker.active and app.reaction.?.completed == 0 and !app.reaction.?.active_request, "reopening diagnostics changed an active worker or send", .{});
    app.worker.active = false;
    _ = win.SendMessageW(diagnostics_window, win.WM_COMMAND, 4, 0);
    const shown = try windows.text(diagnostic_edit, t.allocator);
    defer t.allocator.free(shown);
    try expectModeless(std.mem.indexOf(u8, shown, "結果 menu_closed") != null and std.mem.indexOf(u8, shown, "(waiting)") != null, "refreshed diagnostics omitted result or waiting", .{});
    var copy: CopyProbe = .{ .shown = shown };
    try expectModeless(win.SetWindowSubclass(diagnostic_edit, CopyProbe.observe, 93, @intFromPtr(&copy)) != 0, "diagnostic edit subclass could not be installed", .{});
    app.last_state = "changed";
    _ = win.SendMessageW(diagnostics_window, win.WM_COMMAND, 3, 0);
    _ = win.RemoveWindowSubclass(diagnostic_edit, CopyProbe.observe, 93);
    try expectModeless(copy.copied_snapshot and !app.queue.busy() and !app.modal and app.target == target, "diagnostic copy: snapshot={} queue_busy={} modal={} target_preserved={}", .{ copy.copied_snapshot, app.queue.busy(), app.modal, app.target == target });

    ActivationProbe.activated = null;
    app.menuCommand(menu_reaction_result);
    const result_window = app.reaction_details.dialog.window orelse return error.ShowReactionDetails;
    try expectModeless(ActivationProbe.activated == null, "reaction details activated window {x}", .{windows.number(ActivationProbe.activated)});
    try expectModeless(win.IsWindowEnabled(win.GetDlgItem(result_window, 3)) == 0, "copy enabled with no reaction result", .{});
    try expectModeless(app.reaction != null and app.reaction.?.completed == 0, "showing previous result changed the waiting send", .{});
    app.reaction = null;
    app.reaction_result = feedback.Result.init(.wrong_window, null, "fixture detail");
    app.menuCommand(menu_reaction_result);
    try t.expectEqual(result_window, app.reaction_details.dialog.window);
    const result_text = try windows.text(win.GetDlgItem(result_window, 100), t.allocator);
    defer t.allocator.free(result_text);
    try expectModeless(std.mem.indexOf(u8, result_text, "fixture detail") != null and win.IsWindowEnabled(win.GetDlgItem(result_window, 3)) != 0, "reaction result did not refresh its text and copy action", .{});
    app.menuCommand(menu_help);
    const help_window = app.help.dialog.window orelse return error.ShowModelessHelp;
    for ([_]win.HWND{ diagnostics_window, result_window, help_window }) |document_window| {
        _ = win.ShowWindow(palette, win.SW_HIDE);
        // Drive the real shortcut path with the foreground snapshot a hook would supply.
        const event: shortcuts.Event = .{ .action = .palette, .window = windows.number(document_window) };
        app.test_foreground = palette;
        shortcut(event);
        try t.expect(!app.queue.busy());
        app.test_foreground = document_window;
        shortcut(event);
        var posted: win.MSG = undefined;
        if (win.PeekMessageW(&posted, app.window, drain_message, drain_message, win.PM_REMOVE) == 0 or
            posted.message != drain_message) return error.ModelessPaletteShortcutNotPosted;
        dispatch(&posted);
        try expectModeless(win.IsWindowVisible(palette) != 0 and win.IsWindowVisible(document_window) != 0, "palette shortcut visibility: from_diagnostic={} palette={d} document={d}", .{ document_window == diagnostics_window, win.IsWindowVisible(palette), win.IsWindowVisible(document_window) });
        try expectModeless(app.target == target and !app.modal, "palette shortcut changed target or installed a modal lock", .{});
    }

    app.quit(false);
    try expectModeless(app.quitting, "normal app quit did not begin with documents visible", .{});
    try t.expectEqual(@as(?win.WPARAM, 0), testTakeQuitMessage());
    app.deinit();
    live = false;
    try expectModeless(win.IsWindow(diagnostics_window) == 0 and win.IsWindow(result_window) == 0 and
        win.IsWindow(help_window) == 0 and win.IsWindow(palette) == 0, "normal app quit left a document or palette alive", .{});
}

test "desktop: modeless help releases its original palette after shortcut editing" {
    try @import("test_mode.zig").requireDesktop();
    const Probe = struct {
        app: *App,
        help: win.HWND,
        button: win.HWND,
        from_help: bool = true,
        opens: usize = 0,
        attempted_close: bool = false,
        locked: bool = false,
        fail_help: bool = false,
        fail_owner: bool = false,
        help_enable_attempts: usize = 0,
        owner_enable_attempts: usize = 0,
        editor: win.HWND = null,

        var active: ?*@This() = null;
        extern "user32" fn SetTimer(win.HWND, win.UINT_PTR, win.UINT, *const fn (win.HWND, win.UINT, win.UINT_PTR, win.DWORD) callconv(.winapi) void) callconv(.winapi) win.UINT_PTR;

        fn observeEnable(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, context: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            const self: *@This() = @ptrFromInt(context);
            if (message == win.WM_ENABLE and wparam != 0) {
                if (hwnd == self.help) {
                    self.help_enable_attempts += 1;
                    if (self.fail_help) _ = win.EnableWindow(hwnd, 0);
                } else if (hwnd == self.app.palette.window) {
                    self.owner_enable_attempts += 1;
                    if (self.fail_owner) _ = win.EnableWindow(hwnd, 0);
                }
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }

        fn closeEditor(_: win.HWND, _: win.UINT, timer: win.UINT_PTR, _: win.DWORD) callconv(.winapi) void {
            const self = active orelse return;
            if (self.attempted_close) {
                _ = win.KillTimer(null, timer);
                win.PostQuitMessage(1);
                return;
            }
            self.attempted_close = true;
            const parent = self.app.palette.window;
            const editor = support.shortcutEditorAwayFrom(parent) orelse {
                _ = win.KillTimer(null, timer);
                win.PostQuitMessage(1);
                return;
            };
            self.opens += 1;
            self.editor = editor;
            self.locked = self.app.modal and win.IsWindowEnabled(parent) == 0 and
                win.GetWindow(editor, win.GW_OWNER) == (if (self.from_help) self.help else parent);
            if (self.from_help) {
                // The owner's nested callbacks cannot start another editor or close help.
                _ = win.SendMessageW(self.help, win.WM_COMMAND, 5, @bitCast(windows.number(self.button)));
                _ = win.SendMessageW(self.help, win.WM_CLOSE, 0, 0);
                self.locked = self.locked and win.IsWindowEnabled(self.help) == 0 and win.IsWindowVisible(self.help) != 0;
            }
            if (self.fail_help and self.fail_owner) {
                windows.setText(win.GetDlgItem(editor, 100), "^+F12");
                _ = win.SendMessageW(editor, win.WM_COMMAND, 1, 0);
            }
            _ = win.SendMessageW(editor, win.WM_CLOSE, 0, 0);
            if (win.IsWindowVisible(editor) == 0) _ = win.KillTimer(null, timer);
        }
    };
    const t = std.testing;
    var directory = t.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.db" });
    defer t.allocator.free(path);
    var db = try storage.Store.open(t.allocator, path);
    defer db.close();
    var app: App = .{
        .executable = windows.wide("modeless-help-fixture.exe"),
        .db = &db,
        .snapshot = try db.load(t.allocator),
        .history = storage.LibraryHistory.init(t.allocator),
        .running_digest = null,
    };
    defer app.deinit();
    current = &app;
    defer current = null;
    const module = win.GetModuleHandleW(null);
    app.window = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), 0, 0, 0, 1, 1, null, null, module, null) orelse
        return error.CreateModelessHelpHost;
    try app.palette.open(app.window);
    const parent = app.palette.window;
    _ = win.ShowWindow(parent, win.SW_SHOWNOACTIVATE);
    app.menuCommand(menu_help);
    const help_window = app.help.dialog.window orelse return error.ShowModelessHelp;
    const button = win.GetDlgItem(help_window, 5) orelse return error.MissingHelpShortcutButton;
    const document_control = win.GetDlgItem(help_window, 100) orelse return error.MissingHelpDocument;
    const owner = win.GetWindow(help_window, win.GW_OWNER);
    try expectModeless(owner == parent and win.IsWindowEnabled(parent) != 0 and app.canEdit(), "help owner: parent={x} owner={x} enabled={d} allowed={}", .{ windows.number(parent), windows.number(owner), win.IsWindowEnabled(parent), app.canEdit() });

    var probe: Probe = .{ .app = &app, .help = help_window, .button = button };
    Probe.active = &probe;
    defer Probe.active = null;
    try t.expect(win.SetWindowSubclass(help_window, Probe.observeEnable, 95, @intFromPtr(&probe)) != 0);
    defer _ = win.RemoveWindowSubclass(help_window, Probe.observeEnable, 95);
    try t.expect(win.SetWindowSubclass(parent, Probe.observeEnable, 95, @intFromPtr(&probe)) != 0);
    defer _ = win.RemoveWindowSubclass(parent, Probe.observeEnable, 95);
    for ([_]struct { from_help: bool = true, fail_help: bool = false, fail_owner: bool = false, newer_help_owner: bool = false }{
        .{},
        .{ .from_help = false },
        .{ .fail_help = true },
        .{ .fail_owner = true },
        .{ .fail_help = true, .fail_owner = true },
        .{ .fail_help = true, .newer_help_owner = true },
    }) |scenario| {
        probe.from_help = scenario.from_help;
        probe.fail_help = scenario.fail_help;
        probe.fail_owner = scenario.fail_owner;
        probe.help_enable_attempts = 0;
        probe.owner_enable_attempts = 0;
        probe.attempted_close = false;
        probe.locked = false;
        // The editor is created synchronously before its nested queue first services this timer.
        const timer = Probe.SetTimer(null, 0, 10, Probe.closeEditor);
        try expectModeless(timer != 0, "could not arm timer for shortcut editor", .{});
        defer _ = win.KillTimer(null, timer);
        if (scenario.from_help)
            _ = win.SendMessageW(help_window, win.WM_COMMAND, 5, @bitCast(windows.number(button)))
        else
            app.menuCommand(menu_keys);
        var quit_message: win.MSG = undefined;
        try expectModeless(win.PeekMessageW(&quit_message, null, win.WM_QUIT, win.WM_QUIT, win.PM_REMOVE) == 0, "timer could not close shortcut editor: from_help={} opens={d}", .{ scenario.from_help, probe.opens });
        try expectModeless(probe.locked and win.IsWindow(probe.editor) == 0 and app.canEdit() and !app.modal, "shortcut editor did not release its modal ownership", .{});
        try t.expectEqual(!scenario.fail_owner, win.IsWindowEnabled(parent) != 0);
        try t.expectEqual(!scenario.fail_help, win.IsWindowEnabled(help_window) != 0);
        try t.expectEqual(@as(usize, 1), probe.owner_enable_attempts);
        try t.expectEqual(@as(usize, @intFromBool(scenario.from_help)), probe.help_enable_attempts);
        try t.expect(win.IsWindowVisible(help_window) != 0);
        try t.expectEqual(document_control, win.GetDlgItem(help_window, 100));
        if (scenario.fail_help or scenario.fail_owner) {
            const title = try windows.text(help_window, t.allocator);
            defer t.allocator.free(title);
            try t.expectEqualStrings(support.help_restore_notice, title);
            probe.fail_help = false;
            probe.fail_owner = false;
            if (scenario.newer_help_owner) {
                const successor = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), win.WS_POPUP, 0, 0, 1, 1, help_window, null, module, null) orelse
                    return error.CreateHelpRestoreSuccessor;
                _ = win.ShowWindow(successor, win.SW_SHOWNOACTIVATE);
                app.menuCommand(menu_help);
                try t.expectEqual(@as(usize, 1), probe.help_enable_attempts);
                try t.expect(win.IsWindowEnabled(help_window) == 0 and win.IsWindowVisible(successor) != 0);
                _ = win.DestroyWindow(successor);
                _ = win.EnableWindow(help_window, 1);
                std.debug.print("HELP_RESTORE successor_kept_lock=true\n", .{});
                continue;
            }
            app.menuCommand(menu_help);
            try t.expectEqual(help_window, app.help.dialog.window);
            try t.expect(win.IsWindowEnabled(parent) != 0 and win.IsWindowEnabled(help_window) != 0);
            try t.expectEqual(@as(usize, 1) + @intFromBool(scenario.fail_owner), probe.owner_enable_attempts);
            try t.expectEqual(@as(usize, 1) + @intFromBool(scenario.fail_help), probe.help_enable_attempts);
            std.debug.print("HELP_RESTORE help_fault={} owner_fault={} editor_closed=true help_attempts={d} owner_attempts={d}\n", .{
                scenario.fail_help, scenario.fail_owner, probe.help_enable_attempts, probe.owner_enable_attempts,
            });
        }
    }
    try t.expectEqual(@as(usize, 6), probe.opens);
    var persisted = try db.load(t.allocator);
    defer persisted.deinit();
    try t.expectEqualStrings("^+F12", persisted.data.preferences.shortcut_keys[0]);
    try t.expectEqualStrings("^+F12", app.snapshot.data.preferences.shortcut_keys[0]);

    const other = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), win.WS_OVERLAPPEDWINDOW, 0, 0, 1, 1, null, null, module, null) orelse
        return error.CreateAlternateHelpWindow;
    defer _ = win.DestroyWindow(other);
    _ = win.ShowWindow(other, win.SW_SHOW);
    _ = win.SetForegroundWindow(other);
    const foreground = win.GetForegroundWindow();
    _ = win.SendMessageW(help_window, win.WM_CLOSE, 0, 0);
    if (foreground == other) try t.expectEqual(other, win.GetForegroundWindow());
    try expectModeless(win.IsWindowVisible(help_window) == 0 and win.IsWindowEnabled(parent) != 0, "help close: visible={d} parent_enabled={d}", .{ win.IsWindowVisible(help_window), win.IsWindowEnabled(parent) });
    app.menuCommand(menu_help);
    const reopened = app.help.dialog.window orelse return error.ReopenModelessHelp;
    try expectModeless(win.GetWindow(reopened, win.GW_OWNER) == parent and win.IsWindowVisible(reopened) != 0, "reopened help owner or visibility changed", .{});
    app.help.close();
    try expectModeless(win.IsWindow(reopened) == 0 and win.IsWindowEnabled(parent) != 0, "destroying help left a window or parent lock", .{});
}

test "desktop: management channel lookup distinguishes current failures and drops obsolete notifications" {
    try @import("test_mode.zig").requireDesktop();
    const Probe = struct {
        const Case = enum { no_target, no_result, network, metadata, automation, transport_error, timeout, changed_page, retargeted, stopped };
        threadlocal var scenario: Case = .no_target;
        threadlocal var requests: usize = 0;
        threadlocal var alternate: win.HWND = null;

        fn browser(hwnd: win.HWND) ?[]const u8 {
            return if (hwnd != null) "brave" else null;
        }

        fn exchange(client: *transport.Client, heap: std.mem.Allocator, _: [:0]const u16, mode: transport.Mode, target: usize, expected: []const u8, fields: []const transport.Field, _: transport.Pump) !transport.Reply {
            const app = current.?;
            try std.testing.expect(mode == .resolve and target == windows.number(app.target));
            try std.testing.expect(expected.len == 0 and fields.len == 0);
            requests += 1;
            client.active = true;
            defer client.active = false;
            const data = switch (scenario) {
                .no_target => return error.UnexpectedChannelLookup,
                .no_result => "State=unavailable\nDetail=unrecognized detail",
                .network => "State=unavailable\nDetail=HttpResponseFailed",
                .metadata => "State=unavailable\nDetail=MissingAuthor",
                .automation => "State=unavailable\nDetail=AutomationUnavailable",
                .transport_error => return error.WorkerWaitFailed,
                .timeout => return error.WorkerTimeout,
                .changed_page => "State=changed\nDetail=old detail",
                .retargeted => {
                    app.target = alternate;
                    return error.WorkerWaitFailed;
                },
                .stopped => {
                    app.stop();
                    return error.WorkerTimeout;
                },
            };
            return .{ .alloc = heap, .payload = try heap.dupe(u8, data) };
        }

        fn host(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
            const app = current orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
            if (message == management.wm_edit_allowed) return @intFromBool(app.canEdit());
            if (message == management.wm_resolve_channel) {
                const request: *management.ChannelRequest = @ptrFromInt(@as(usize, @bitCast(lparam)));
                app.resolveChannelUsing(request, browser, exchange);
                return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        }
    };
    const t = std.testing;
    var directory = t.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.db" });
    defer t.allocator.free(path);
    var db = try storage.Store.open(t.allocator, path);
    defer db.close();
    var app: App = .{
        .executable = windows.wide("channel-lookup-fixture.exe"),
        .db = &db,
        .snapshot = try db.load(t.allocator),
        .history = storage.LibraryHistory.init(t.allocator),
        .running_digest = null,
    };
    defer app.deinit();
    current = &app;
    defer current = null;
    var wc = std.mem.zeroes(win.WNDCLASSW);
    wc.hInstance = win.GetModuleHandleW(null);
    wc.lpszClassName = windows.wide("ChatPalette.ChannelLookupNoticeTest");
    wc.lpfnWndProc = Probe.host;
    try t.expect(win.RegisterClassW(&wc) != 0);
    app.window = win.CreateWindowExW(0, wc.lpszClassName, windows.wide(""), 0, 0, 0, 1, 1, null, null, wc.hInstance, null) orelse
        return error.CreateChannelLookupHost;
    Probe.alternate = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), 0, 0, 0, 1, 1, null, null, wc.hInstance, null) orelse
        return error.CreateAlternateChannelTarget;
    defer _ = win.DestroyWindow(Probe.alternate);
    try app.manager.open(app.window, &db, &app.snapshot, &app.history);
    const prior = "以前の管理通知";
    for ([_]struct { scenario: Probe.Case, expected: []const u8 }{
        .{ .scenario = .no_target, .expected = "通知：YouTubeを前面にし、Ctrl+Alt+Q でパレットを開いて連携してください。" },
        .{ .scenario = .no_result, .expected = "通知：チャンネルを確認できませんでした。YouTubeの動画を開いてやり直してください。" },
        .{ .scenario = .network, .expected = "通知：YouTubeから配信者情報を受け取れませんでした。" },
        .{ .scenario = .metadata, .expected = "通知：YouTubeから受け取った配信者情報を確認できませんでした。" },
        .{ .scenario = .automation, .expected = "通知：ブラウザーから動画情報を確認できませんでした。" },
        .{ .scenario = .transport_error, .expected = "通知：補助プロセスと通信できず、チャンネルを確認できませんでした。" },
        .{ .scenario = .timeout, .expected = "通知：チャンネルを確認する補助プロセスの応答が時間内に届きませんでした。" },
        .{ .scenario = .changed_page, .expected = prior },
        .{ .scenario = .retargeted, .expected = prior },
        .{ .scenario = .stopped, .expected = prior },
    }) |sample| {
        Probe.scenario = sample.scenario;
        Probe.requests = 0;
        app.target = if (sample.scenario == .no_target) null else app.window;
        windows.setText(app.manager.notice, prior);
        app.manager.linkFromPalette();
        const notice = try windows.text(app.manager.notice, t.allocator);
        defer t.allocator.free(notice);
        try t.expectEqualStrings(sample.expected, notice);
        try t.expectEqual(@as(usize, if (sample.scenario == .no_target) 0 else 1), Probe.requests);
        try t.expect(!app.manager.isEditing() and !app.worker.active);
    }
    try t.expectEqual(@as(usize, 0), app.history.length);
}

test "slot lookup failures distinguish verification from a lost input acknowledgement" {
    const Probe = struct {
        var requests: usize = 0;
        fn loseReply(client: *transport.Client, _: std.mem.Allocator, _: [:0]const u16, _: transport.Mode, _: usize, _: []const u8, _: []const transport.Field, _: transport.Pump) !transport.Reply {
            requests += 1;
            client.request_may_have_arrived = true;
            return error.WorkerTimeout;
        }
    };
    const t = std.testing;
    var app: App = .{ .executable = windows.wide("fixture"), .snapshot = undefined, .db = undefined, .history = undefined, .running_digest = null };
    for ([_]struct { mode: transport.Mode, notice: []const u8 }{
        .{ .mode = .browser_context, .notice = "動画を確認できなかったため、弾幕は入力していません。 補助プロセスの要求失敗 WorkerTimeout" },
        .{ .mode = .verify_input, .notice = "入力欄を確認できなかったため、弾幕は入力していません。 補助プロセスの要求失敗 WorkerTimeout" },
        .{ .mode = .input_insert, .notice = "unknown" },
    }) |case| {
        Probe.requests = 0;
        try t.expectError(error.WorkerTimeout, app.requestUsing(case.mode, 1, "", &.{}, Probe.loseReply));
        var buffer: [512]u8 = undefined;
        try t.expectEqualStrings(case.notice, app.shortcutFailureNotice(true, error.WorkerTimeout, &buffer));
        try t.expectEqualStrings("unknown", app.shortcutFailureNotice(false, error.WorkerTimeout, &buffer));
        try t.expectEqual(case.mode, app.last_mode.?);
        try t.expectEqual(@as(usize, 1), Probe.requests);
        app.last_worker_failure.?.cleanup = error.WorkerDidNotExit;
        try t.expectEqualStrings(worker_exit_notice, app.shortcutFailureNotice(true, error.WorkerTimeout, &buffer));
    }
}

test "desktop: desktop records the communication cause and an unconfirmed worker exit together" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    const Probe = struct {
        fn request(client: *transport.Client, alloc: std.mem.Allocator, executable: [:0]const u16, mode: transport.Mode, hwnd: usize, expected: []const u8, fields: []const transport.Field, dispatch_messages: transport.Pump) !transport.Reply {
            std.debug.assert(hwnd == 0 and expected.len == 0);
            return transport.LifecycleProbe.requestWithUnconfirmedExit(client, alloc, .{ .executable = executable }, mode, fields, dispatch_messages);
        }

        fn recovered(_: *transport.Client, alloc: std.mem.Allocator, _: [:0]const u16, _: transport.Mode, _: usize, _: []const u8, _: []const transport.Field, _: transport.Pump) !transport.Reply {
            return .{ .alloc = alloc, .payload = try alloc.dupe(u8, "State=ok\n") };
        }
    };

    const heap = testing.allocator;
    const path = try std.fs.selfExePathAlloc(heap);
    defer heap.free(path);
    const executable = try std.unicode.utf8ToUtf16LeAllocZ(heap, path);
    defer heap.free(executable);
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const db_path = try std.fs.path.join(heap, &.{ root, "settings.db" });
    defer heap.free(db_path);
    var db = try storage.Store.open(heap, db_path);
    defer db.close();
    var app: App = .{
        .executable = executable,
        .db = &db,
        .snapshot = try db.load(heap),
        .history = storage.LibraryHistory.init(heap),
        .running_digest = null,
        .last_mode = .chat_focus,
        .last_state = "focused",
    };
    defer app.deinit();
    try app.palette.open(null);
    try app.manager.open(null, &db, &app.snapshot, &app.history);

    // The new process executes no code. The transport terminates it using the
    // owned handle, then the injected observer withholds the wait confirmation.
    var startup = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    var child: win.PROCESS_INFORMATION = undefined;
    if (win.CreateProcessW(executable, null, null, null, 0, win.CREATE_SUSPENDED | win.CREATE_NO_WINDOW, null, null, &startup, &child) == 0)
        return error.FailedToCreateSuspendedTestWorker;
    app.worker.process = child.hProcess;
    _ = win.CloseHandle(child.hThread);
    const endpoint = win.CreateEventW(null, 0, 0, null) orelse return error.FailedToCreateTestWorkerEndpoint;
    app.worker.pipe = endpoint;
    const signal = win.CreateEventW(null, 0, 0, null) orelse return error.FailedToCreateTestWorkerEndpoint;
    app.worker.signal = signal;

    const oversized = [_]u8{'x'} ** 32768;
    const fields = &.{transport.Field{ .name = "Payload", .value = &oversized }};
    try testing.expectError(error.InvalidWorkerRequestSize, app.requestUsing(.verify_input, 0, "", fields, Probe.request));
    try testing.expectEqual(@as(u64, 1), app.worker.sequence);
    try testing.expectEqual(child.hProcess, app.worker.process);
    try testing.expectEqual(win.WAIT_OBJECT_0, win.WaitForSingleObject(app.worker.process, 0));
    try testing.expect(app.worker.pipe == null and app.worker.signal == null);
    try testing.expect(app.canEdit());
    try testing.expect(win.IsWindowEnabled(app.palette.window) != 0 and win.IsWindowEnabled(app.manager.window) != 0);

    var buffer: [1024]u8 = undefined;
    const observed = try app.diagnosticSnapshot(win.GetTickCount64()).format(&buffer, version);
    for ([_][]const u8{ "直近の操作 verify_input", "結果 unavailable", "InvalidWorkerRequestSize", "WorkerDidNotExit" }) |expected|
        try testing.expect(std.mem.indexOf(u8, observed, expected) != null);
    try testing.expectEqual(feedback.Reason.unavailable, app.workerFailureReason(error.InvalidWorkerRequestSize));
    try testing.expect(app.cleanupNotice(error.InvalidWorkerRequestSize) != null);
    try testing.expect(app.cleanupNotice(error.WorkerBusy) == null);
    app.worker.active = true;
    try testing.expectError(error.WorkerBusy, app.request(.reaction_check, 0, "", &.{}));
    app.worker.active = false;
    try testing.expectEqual(transport.Mode.verify_input, app.last_mode.?);
    try testing.expectEqual(error.InvalidWorkerRequestSize, app.last_worker_failure.?.cause);

    try app.worker.stop();
    try testing.expect(app.worker.process == null);

    // A query-only handle is valid, but the OS denies waiting on it. Do not
    // stop the test process or let a failed restart schedule another instance.
    const query_only = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, win.GetCurrentProcessId()) orelse
        return error.FailedToOpenQueryOnlyProcessHandle;
    defer _ = win.CloseHandle(query_only);
    try testing.expectEqual(win.WAIT_FAILED, win.WaitForSingleObject(query_only, 0));
    app.worker.process = query_only;
    defer if (app.worker.process == query_only) {
        app.worker.process = null;
    };
    for ([_]bool{ false, true }) |restarting| {
        app.quit(restarting);
        try testing.expect(!app.quitting and !app.restarting and app.canEdit());
        try testing.expectEqual(query_only, app.worker.process);
        const notice = try windows.text(app.palette.message, heap);
        defer heap.free(notice);
        try testing.expectEqualStrings(if (restarting)
            "補助プロセスの終了を確認できませんでした。もう一度再起動してください。"
        else
            "補助プロセスの終了を確認できませんでした。もう一度終了してください。", notice);
    }
    const after_quit = try app.diagnosticSnapshot(win.GetTickCount64()).format(&buffer, version);
    for ([_][]const u8{ "InvalidWorkerRequestSize", "補助プロセスの終了失敗 WorkerDidNotExit" }) |expected|
        try testing.expect(std.mem.indexOf(u8, after_quit, expected) != null);

    app.worker.process = null;
    app.last_page = .{ .action = .chat_clear, .browser = .brave, .stage = .clear_keys, .state = .cleared, .elapsed_ms = 42 };
    const reply = try app.requestUsing(.browser_context, 0, "", &.{}, Probe.recovered);
    defer reply.deinit();
    try testing.expectEqual(transport.Mode.browser_context, app.last_mode.?);
    try testing.expectEqualStrings("ok", app.last_state);
    try testing.expect(app.last_worker_failure == null and app.last_stop_failure == null);
    const retained = try app.diagnosticSnapshot(win.GetTickCount64()).format(&buffer, version);
    for ([_][]const u8{ "直近の操作 browser_context\r\n結果 ok", "直近のページ操作 chat_clear", "ページ操作の処理段階 クリアキー送信", "ページ操作の結果 cleared", "ページ操作のブラウザー Brave" }) |expected|
        try testing.expect(std.mem.indexOf(u8, retained, expected) != null);
}

fn testTakeQuitMessage() ?win.WPARAM {
    // The queue delivers PostQuitMessage after pending posted messages have been serviced.
    var message: win.MSG = undefined;
    while (win.PeekMessageW(&message, null, 0, 0, win.PM_REMOVE) != 0) {
        if (message.message == win.WM_QUIT) return message.wParam;
        dispatch(&message);
    }
    return null;
}

test "the restart menu refuses active work while a same-path launch can drain it" {
    const testing = std.testing;
    var app: App = .{
        .executable = undefined,
        .db = undefined,
        .snapshot = undefined,
        .history = undefined,
        .running_digest = null,
    };
    defer app.queue.deinit(allocator);
    const previous = current;
    current = &app;
    defer current = previous;
    const signal = try keyboard.Cancellation.create();
    defer signal.close();
    app.input_cancellation = .{ .target = 1, .signal = signal };

    app.manager.opening_editor = true;
    _ = messageHandler(null, win.WM_COMMAND, menu_restart, 0);
    try testing.expect(!app.quitting and !app.restarting);
    app.manager.opening_editor = false;
    app.worker.active = true;
    _ = messageHandler(null, win.WM_COMMAND, menu_restart, 0);
    try testing.expect(!app.quitting and !app.restarting);
    try testing.expectEqual(@as(win.DWORD, win.WAIT_TIMEOUT), win.WaitForSingleObject(signal.handle, 0));
    app.worker.active = false;

    try app.queue.enqueue(allocator, .{ .action = .reaction, .window = 1 }, 0, null);
    const generation = app.queue.generation;
    _ = messageHandler(null, win.WM_COMMAND, menu_restart, 0);
    try testing.expect(!app.quitting and !app.restarting);
    try testing.expectEqual(@as(usize, 1), app.queue.pending.items.len);
    try testing.expectEqual(generation, app.queue.generation);
    try testing.expectEqual(@as(?win.WPARAM, null), testTakeQuitMessage());

    app.worker.active = true;
    _ = messageHandler(null, instance.take_over, 0, 0);
    try testing.expect(app.quitting and !app.restarting);
    try testing.expectEqual(@as(usize, 0), app.queue.pending.items.len);
    try testing.expectEqual(@as(win.DWORD, win.WAIT_OBJECT_0), win.WaitForSingleObject(signal.handle, 0));
    try testing.expectEqual(@as(?win.WPARAM, null), testTakeQuitMessage());
    app.worker.active = false;
    app.finishQuit();
    try testing.expectEqual(@as(?win.WPARAM, 0), testTakeQuitMessage());
}

test "the idle restart menu requests an exit with restart intent" {
    const testing = std.testing;
    var app: App = .{
        .executable = undefined,
        .db = undefined,
        .snapshot = undefined,
        .history = undefined,
        .running_digest = null,
    };
    const previous = current;
    current = &app;
    defer current = previous;
    _ = messageHandler(null, win.WM_COMMAND, menu_restart, 0);
    try testing.expect(app.quitting and app.restarting);
    try testing.expectEqual(@as(?win.WPARAM, 0), testTakeQuitMessage());
    try testing.expectEqual(@as(?win.WPARAM, null), testTakeQuitMessage());
}

test "diagnostics derive phases from pending and live reaction work" {
    const testing = std.testing;
    var app: App = .{
        .executable = undefined,
        .db = undefined,
        .snapshot = undefined,
        .history = undefined,
        .running_digest = null,
    };
    defer app.queue.deinit(testing.allocator);
    try testing.expectEqual(diagnostic.Phase.idle, app.diagnosticReactionPhase(1000));
    try app.queue.enqueue(testing.allocator, .{ .action = .reaction, .window = 1 }, 0, null);
    try testing.expectEqual(diagnostic.Phase.queued, app.diagnosticReactionPhase(1000));

    app.reaction_clock = try std.time.Timer.start();
    app.reaction = .{ .target = 1, .video = "Fixture0001".*, .page = @splat(0), .kind = 1, .count = 10, .interval = 200, .due_ns = 3000 * std.time.ns_per_ms };
    try testing.expectEqual(diagnostic.Phase.waiting, app.diagnosticReactionPhase(1000));
    app.reaction.?.active_request = true;
    try testing.expectEqual(diagnostic.Phase.running, app.diagnosticReactionPhase(3000));
    app.reaction.?.stop_requested = true;
    try testing.expectEqual(diagnostic.Phase.stopping, app.diagnosticReactionPhase(3000));
    app.reaction = null;
    app.queue.cancel();

    app.preparation = .{ .mode = .reaction_capture, .target = 1, .video = "Fixture0001".*, .page = @splat(0), .generation = 0, .due = 5000 };
    try testing.expectEqual(diagnostic.Phase.waiting, app.diagnosticReactionPhase(4000));
    app.worker.active = true;
    try testing.expectEqual(diagnostic.Phase.running, app.diagnosticReactionPhase(5000));
    app.reaction_generation += 1;
    try testing.expectEqual(diagnostic.Phase.stopping, app.diagnosticReactionPhase(5000));
    app.preparation = null;
    app.reaction_result = feedback.Result.init(.stopped, null, "");
    defer app.reaction_result.?.deinit();
    try testing.expectEqual(diagnostic.Phase.finished, app.diagnosticReactionPhase(5000));
}

test "desktop: reaction progress preserves palette input and settings notices" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    var app: App = .{ .executable = undefined, .db = undefined, .snapshot = undefined, .history = undefined, .running_digest = null };
    try app.palette.open(null);
    defer app.palette.close();
    app.window = app.palette.window;
    app.palette.status("入力欄を確認してください。");
    app.palette.loadReactionDefaults(.{});
    try app.openReactionProgress();
    defer app.reaction_progress.close();
    app.updateReactionProgress("リアクションの操作が完了しました。", .finished);
    const input_notice = try windows.text(app.palette.message, testing.allocator);
    defer testing.allocator.free(input_notice);
    const reaction_notice = try windows.text(app.palette.reaction_notice, testing.allocator);
    defer testing.allocator.free(reaction_notice);
    const settings_notice = try windows.text(app.palette.settings_notice, testing.allocator);
    defer testing.allocator.free(settings_notice);
    try testing.expectEqualStrings("入力欄を確認してください。", input_notice);
    try testing.expectEqualStrings("リアクションの操作が完了しました。", reaction_notice);
    try testing.expectEqualStrings("標準設定を読み込みました。変更は今回の実行だけに適用します。", settings_notice);
}

test "stop invalidates a reaction context even before a preparation or send job exists" {
    var app: App = .{
        .executable = undefined,
        .db = undefined,
        .snapshot = undefined,
        .history = undefined,
        .running_digest = null,
        .target = @ptrFromInt(42),
    };
    const old = app.reactionOrigin();
    try std.testing.expect(app.reactionContextCurrent(old));
    app.stop();
    try std.testing.expect(!app.reactionContextCurrent(old));
    const next = app.reactionOrigin();
    try std.testing.expect(app.reactionContextCurrent(next));
    app.target = @ptrFromInt(43);
    try std.testing.expect(!app.reactionContextCurrent(next));
    app.target = next.target;
    app.reaction_revision +%= 1;
    try std.testing.expect(!app.reactionContextCurrent(next));
}

test "desktop: a due reaction posts an immediate continuation to the current generation" {
    try @import("test_mode.zig").requireDesktop();
    const handle = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), 0, 0, 0, 16, 16, null, null, win.GetModuleHandleW(null), null) orelse
        return error.TestReactionWindow;
    defer _ = win.DestroyWindow(handle);
    var app: App = .{ .executable = undefined, .db = undefined, .snapshot = undefined, .history = undefined, .running_digest = null, .window = handle };
    try std.testing.expect(app.scheduleReactionAdvance(42, 0));
    var message: win.MSG = undefined;
    try std.testing.expect(win.PeekMessageW(&message, handle, advance_reaction_message, advance_reaction_message, win.PM_REMOVE) != 0);
    try std.testing.expectEqual(@as(win.WPARAM, 42), message.wParam);
    try std.testing.expectEqual(@as(win.BOOL, 0), win.PeekMessageW(&message, handle, win.WM_TIMER, win.WM_TIMER, win.PM_REMOVE));
}

test "desktop: queued timers from finished reactions and preparations cannot finish later operations" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    const handle = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), 0, 0, 0, 16, 16, null, null, win.GetModuleHandleW(null), null) orelse
        return error.TestReactionWindow;
    defer _ = win.DestroyWindow(handle);
    var app: App = .{
        .executable = undefined,
        .db = undefined,
        .snapshot = undefined,
        .history = undefined,
        .running_digest = null,
        .window = handle,
        .quitting = true,
    };
    defer app.cancelReactionTimer();
    defer if (app.reaction_result) |result| result.deinit();
    current = &app;
    defer current = null;

    const job: operations.Reaction = .{ .target = 1, .video = "Fixture0001".*, .page = @splat(0), .kind = 1, .count = 2, .interval = 100 };
    app.reaction = job;
    try testing.expect(app.scheduleReactionAdvance(0, 60000));
    const obsolete_send = app.reaction_timer.?.id;
    app.finishReaction(.stopped, "");
    try testing.expect(app.reaction_timer == null);

    app.reaction_generation = 1;
    app.preparation = .{ .mode = .reaction_check, .target = 1, .video = job.video, .page = job.page, .generation = 1, .due = 0 };
    try testing.expect(app.setReactionTimer(.preparation, 60000));
    const obsolete_preparation = app.reaction_timer.?.id;
    _ = messageHandler(handle, win.WM_TIMER, obsolete_send, 0);
    try testing.expect(app.preparation != null and app.reaction_result.?.reason == .stopped);
    _ = messageHandler(handle, win.WM_TIMER, obsolete_preparation, 0);
    try testing.expect(app.preparation == null and app.reaction_result.?.reason == .wrong_window);

    app.reaction_generation = 2;
    app.reaction = job;
    try testing.expect(app.scheduleReactionAdvance(2, 60000));
    const current_send = app.reaction_timer.?.id;
    try testing.expect(current_send != obsolete_send and current_send != obsolete_preparation);
    _ = messageHandler(handle, win.WM_TIMER, obsolete_send, 0);
    _ = messageHandler(handle, win.WM_TIMER, obsolete_preparation, 0);
    _ = messageHandler(handle, advance_reaction_message, 0, 0);
    try testing.expectEqualDeep(job, app.reaction.?);
    _ = messageHandler(handle, win.WM_TIMER, current_send, 0);
    try testing.expect(app.reaction == null and app.reaction_timer == null);
}

test "desktop: a stop reentered from progress rendering leaves the terminal controls and retires the clock" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    const Reentry = struct {
        fn stopDuringText(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: win.UINT_PTR, data: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            if (message == win.WM_SETTEXT) {
                _ = win.RemoveWindowSubclass(hwnd, stopDuringText, id);
                const app: *App = @ptrFromInt(data);
                app.stop();
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }
    };

    const module = win.GetModuleHandleW(null);
    const host = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), 0, 0, 0, 40, 40, null, null, module, null) orelse
        return error.TestReactionWindow;
    defer _ = win.DestroyWindow(host);
    const status = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), win.WS_CHILD, 0, 0, 20, 20, host, null, module, null) orelse
        return error.TestReactionStatusControl;
    var app: App = .{
        .executable = undefined,
        .db = undefined,
        .snapshot = undefined,
        .history = undefined,
        .running_digest = null,
        .window = host,
    };
    defer app.reaction_progress.close();
    defer if (app.reaction_result) |result| result.deinit();
    app.palette.reaction_notice = status;
    app.reaction_clock = try std.time.Timer.start();
    app.reaction = .{
        .target = 1,
        .video = "Fixture0001".*,
        .page = @splat(0),
        .kind = 1,
        .count = 10,
        .interval = 200,
        .completed = 1,
    };
    try app.openReactionProgress();
    try testing.expect(app.scheduleReactionAdvance(app.reaction_generation, 60000));
    try testing.expect(win.SetWindowSubclass(status, Reentry.stopDuringText, 1, @intFromPtr(&app)) != 0);
    defer _ = win.RemoveWindowSubclass(status, Reentry.stopDuringText, 1);
    app.updateReactionProgress("実行中の古い表示", .running);

    try testing.expect(app.reaction == null and app.reaction_clock == null and app.reaction_timer == null);
    const result = app.reaction_result orelse return error.TestReactionResultMissing;
    try testing.expectEqual(feedback.Reason.stopped, result.reason);
    try testing.expectEqual(@as(u32, 1), result.counts.?.completed);
    const palette_status = try windows.text(status, testing.allocator);
    defer testing.allocator.free(palette_status);
    const overlay_status = try windows.text(app.reaction_progress.summary, testing.allocator);
    defer testing.allocator.free(overlay_status);
    try testing.expect(std.mem.indexOf(u8, palette_status, "中止しました。") != null);
    try testing.expectEqualStrings(palette_status, overlay_status);
    try testing.expect(win.IsWindowEnabled(app.reaction_progress.stop) == 0);
    try testing.expect(win.GetWindowLongW(app.reaction_progress.stop, win.GWL_STYLE) & win.WS_VISIBLE == 0);

    const pending: App.Preparation = .{
        .mode = .reaction_check,
        .target = 1,
        .video = "Fixture0001".*,
        .page = @splat(0),
        .generation = app.reaction_generation,
        .due = 0,
    };
    app.preparation = pending;
    try testing.expect(app.schedulePreparation(pending, 60000));
    try testing.expect(win.SetWindowSubclass(status, Reentry.stopDuringText, 1, @intFromPtr(&app)) != 0);
    app.showPreparationCountdown(3000);
    try testing.expect(app.preparation == null and app.reaction_timer == null);
    try testing.expect(!app.schedulePreparation(pending, 1000));
    try testing.expectEqual(feedback.Reason.stopped, app.reaction_result.?.reason);
}

test "desktop: reaction buttons reconcile a stop while starting and a replacement while releasing" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    const Reentry = struct {
        app: *App,
        replacement: ?operations.Reaction = null,
        replacement_started: bool = false,
        replacement_enqueue_error: ?anyerror = null,

        fn duringEnable(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: win.UINT_PTR, data: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            if (message == win.WM_ENABLE) {
                _ = win.RemoveWindowSubclass(hwnd, duringEnable, id);
                const probe: *@This() = @ptrFromInt(data);
                if (probe.replacement) |job| probe.replacement_started = probe.app.startReaction(job, 1000);
                probe.app.stop();
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }

        fn duringTerminalStatus(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, id: win.UINT_PTR, data: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            if (message == win.WM_SETTEXT) {
                _ = win.RemoveWindowSubclass(hwnd, duringTerminalStatus, id);
                const probe: *@This() = @ptrFromInt(data);
                probe.app.queue.enqueue(allocator, .{ .action = .reaction, .window = 1 }, 0, null) catch |failure| {
                    probe.replacement_enqueue_error = failure;
                    return win.DefSubclassProc(hwnd, message, wparam, lparam);
                };
                probe.app.reaction_revision +%= 1;
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }
    };

    const module = win.GetModuleHandleW(null);
    const host = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), 0, 0, 0, 40, 40, null, null, module, null) orelse
        return error.TestReactionWindow;
    defer _ = win.DestroyWindow(host);
    const start = win.CreateWindowExW(0, windows.wide("BUTTON"), windows.wide(""), win.WS_CHILD, 0, 0, 20, 20, host, null, module, null) orelse
        return error.TestReactionStartControl;
    const stop_button = win.CreateWindowExW(0, windows.wide("BUTTON"), windows.wide(""), win.WS_CHILD, 0, 0, 20, 20, host, null, module, null) orelse
        return error.TestReactionStopControl;
    const status = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), win.WS_CHILD, 0, 0, 20, 20, host, null, module, null) orelse
        return error.TestReactionStatusControl;
    var app: App = .{ .executable = undefined, .db = undefined, .snapshot = undefined, .history = undefined, .running_digest = null, .window = host };
    defer app.reaction_progress.close();
    defer app.cancelReactionTimer();
    defer if (app.reaction_result) |result| result.deinit();
    defer app.queue.deinit(allocator);
    app.palette.start_button = start;
    app.palette.stop_button = stop_button;
    app.updateReactionButtons();
    var probe: Reentry = .{ .app = &app };
    const job: operations.Reaction = .{ .target = 1, .video = "Fixture0001".*, .page = @splat(0), .kind = 1, .count = 10, .interval = 200 };

    try testing.expect(win.SetWindowSubclass(start, Reentry.duringEnable, 1, @intFromPtr(&probe)) != 0);
    defer _ = win.RemoveWindowSubclass(start, Reentry.duringEnable, 1);
    try testing.expect(app.startReaction(job, 1000));
    try testing.expectEqual(feedback.Reason.stopped, app.reaction_result.?.reason);
    try testing.expect(app.reaction == null and app.reaction_clock == null and app.reaction_timer == null);
    try testing.expect(win.IsWindowEnabled(start) != 0 and win.IsWindowEnabled(stop_button) == 0);
    const summary = try windows.text(app.reaction_progress.summary, testing.allocator);
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.indexOf(u8, summary, "中止しました。") != null);

    try testing.expect(app.startReaction(job, 1000));
    probe.replacement = job;
    probe.replacement.?.count = 5;
    try testing.expect(win.SetWindowSubclass(start, Reentry.duringEnable, 1, @intFromPtr(&probe)) != 0);
    app.finishReaction(.completed, "obsolete result");
    try testing.expect(probe.replacement_started);
    try testing.expectEqual(feedback.Reason.stopped, app.reaction_result.?.reason);
    try testing.expectEqual(@as(u32, 5), app.reaction_result.?.counts.?.total);
    try testing.expect(app.reaction == null and app.reaction_clock == null and app.reaction_timer == null);
    try testing.expect(win.IsWindowEnabled(start) != 0 and win.IsWindowEnabled(stop_button) == 0);

    app.palette.reaction_notice = status;
    try app.queue.enqueue(allocator, .{ .action = .reaction, .window = 1 }, 0, null);
    const generation = app.queue.generation;
    try testing.expect(win.SetWindowSubclass(status, Reentry.duringTerminalStatus, 2, @intFromPtr(&probe)) != 0);
    defer _ = win.RemoveWindowSubclass(status, Reentry.duringTerminalStatus, 2);
    app.drain();
    try testing.expectEqual(@as(?anyerror, null), probe.replacement_enqueue_error);
    try testing.expectEqual(@as(usize, 1), app.queue.pending.items.len);
    try testing.expect(!app.queue.active and app.queue.pending.items[0].generation != generation);
    try testing.expectEqual(feedback.Reason.wrong_window, app.reaction_result.?.reason);
    try testing.expectEqual(@as(u32, 0), app.reaction_result.?.counts.?.completed);
    try testing.expect(win.IsWindowEnabled(start) == 0 and win.IsWindowEnabled(stop_button) != 0);
}

test "registration display reads only the selected browser and preserves operation state on read failure" {
    const testing = std.testing;
    const heap = testing.allocator;
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const path = try std.fs.path.join(heap, &.{ root, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    var app: App = .{
        .executable = undefined,
        .db = &db,
        .snapshot = undefined,
        .history = undefined,
        .running_digest = null,
        .last_mode = .reaction_send,
        .last_state = "menu_closed",
        .worker = .{ .active = true },
    };

    var buffer: [192]u8 = undefined;
    try testing.expectEqualStrings("対象ブラウザー：未選択", app.registrationLabel(null, &buffer));
    try testing.expectEqualStrings("未設定（管理・ヘルプから設定）", app.registrationLabel("brave", &buffer));
    try db.saveRegistration(
        \\{"browser":"brave","tokens":[{"name":"one","id":"","class":"","type":50000},{"name":"two","id":"","class":"","type":50000},{"name":"three","id":"","class":"","type":50000},{"name":"four","id":"","class":"","type":50000},{"name":"five","id":"","class":"","type":50000}]}
    );
    try testing.expectEqualStrings("未設定（管理・ヘルプから設定）", app.registrationLabel("firefox", &buffer));
    try testing.expectEqualStrings("設定済み（メニューの認識は未確認）", app.registrationLabel("brave", &buffer));

    const missing = try std.fs.path.join(heap, &.{ root, "missing.db" });
    defer heap.free(missing);
    var unreadable = db;
    unreadable.path = missing;
    app.db = &unreadable;
    try testing.expect(std.mem.startsWith(u8, app.registrationLabel("brave", &buffer), "設定状態：未確認"));
    app.db = &db;
    try testing.expectEqualStrings("設定済み（メニューの認識は未確認）", app.registrationLabel("brave", &buffer));
    try testing.expect(app.worker.active and !app.worker.registrations_current);
    try testing.expectEqual(transport.Mode.reaction_send, app.last_mode.?);
    try testing.expectEqualStrings("menu_closed", app.last_state);
}

test "registration diagnostics retain the outcome of saving and synchronizing" {
    const testing = std.testing;
    var app: App = .{ .executable = undefined, .db = undefined, .snapshot = .init(testing.allocator), .history = undefined, .running_digest = null, .quitting = true };
    defer app.snapshot.deinit();
    defer if (app.reaction_result) |result| result.deinit();
    var out: [1600]u8 = undefined;
    for ([_]struct { reason: feedback.Reason, state: diagnostic.State, mode: transport.Mode, reply: []const u8, committed: bool }{
        .{ .reason = .saved, .state = .registered, .mode = .reaction_configure, .reply = "configured", .committed = true },
        .{ .reason = .save_failed, .state = .save_failed, .mode = .reaction_capture, .reply = "captured", .committed = false },
        .{ .reason = .saved_sync_failed, .state = .sync_failed, .mode = .reaction_configure, .reply = "unavailable", .committed = true },
        .{ .reason = .stopped, .state = .cancelled, .mode = .reaction_capture, .reply = "captured", .committed = false },
    }) |scenario| {
        app.last_mode = scenario.mode;
        app.last_state = scenario.reply;
        app.preparation = .{ .mode = .reaction_capture, .target = 1, .video = "Fixture0001".*, .page = @splat('0'), .generation = 1, .due = 0, .committed = scenario.committed, .browser = .firefox };
        app.finishPreparation(scenario.reason, "PRIVATE-TOKEN-LABEL");
        const record = app.last_registration orelse return error.TestRegistrationOutcomeMissing;
        try testing.expectEqual(scenario.state, record.state);
        try testing.expect(app.preparation == null and record.latest);
        const snapshot = app.diagnosticSnapshot(win.GetTickCount64());
        const text = try snapshot.format(&out, version);
        try testing.expect(std.mem.indexOf(u8, text, "ブラウザー Firefox\r\n直近の操作 reaction_capture") != null);
        var expected: [256]u8 = undefined;
        const outcome = try std.fmt.bufPrint(&expected, "結果 {s}\r\n補助プロセスの要求 {s}\r\n補助プロセスの応答 {s}", .{ @tagName(scenario.state), @tagName(scenario.mode), scenario.reply });
        try testing.expect(std.mem.indexOf(u8, text, outcome) != null);
        try testing.expect(std.mem.indexOf(u8, text, "PRIVATE-TOKEN-LABEL") == null);
    }
}

test "desktop: automatic profile selection persists the match before exposing its input and preserves queued shortcuts" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    const heap = testing.allocator;
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const path = try std.fs.path.join(heap, &.{ root, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    try db.save(.{
        .preferences = .{ .input_profile_id = "profile-a" },
        .profiles = &.{
            .{ .id = "profile-a", .name = "A", .channel = "/channel/a" },
            .{ .id = "profile-b", .name = "B", .channel = "/channel/b", .items = &.{
                .{ .id = "slot-b", .name = "Slot B", .text = "body B", .slot = 1 },
            } },
        },
    });
    var app: App = .{
        .executable = undefined,
        .db = &db,
        .snapshot = try db.load(heap),
        .history = storage.LibraryHistory.init(heap),
        .running_digest = null,
    };
    defer app.deinit();
    const bindings = try shortcuts.validate(app.snapshot.data.preferences.shortcut_keys);
    try app.palette.open(null);
    app.keyboard.tracker.replace(bindings);
    const held = bindings[@intFromEnum(shortcuts.Action.shared1)].?;
    const vk = shortcuts.virtualKey(held.key);
    try testing.expect(app.keyboard.tracker.key(vk, false, held.modifiers, 42, true, false).consume);
    try app.queue.enqueue(allocator, .{ .action = .profile1, .window = 42 }, app.library_revision, null);

    try testing.expect((try app.selectDetectedProfile("/channel/missing", .immediate)) == null);
    try testing.expectEqualStrings("profile-a", app.snapshot.data.preferences.input_profile_id);
    const displayed = app.palette.items_revision;
    const selection = (try app.selectDetectedProfile("/channel/b", .deferred)).?;
    try testing.expectEqualStrings("profile-b", selection.id);
    try testing.expectEqualStrings("body B", selection.items[0].text);
    try testing.expectEqual(displayed, app.palette.items_revision);
    try testing.expectEqualStrings("profile-b", app.palette.data.preferences.input_profile_id);
    app.refreshPalette();
    try testing.expectEqual(displayed + 1, app.palette.items_revision);
    try testing.expectEqualStrings(selection.id, app.palette.visibleProfileId());
    try testing.expectEqual(app.queue.next().?.library, app.library_revision);
    try testing.expectEqual(shortcuts.Action.shared1, app.keyboard.tracker.key(vk, true, 0, 42, true, false).event.?.action);

    var other = try storage.Store.open(heap, path);
    defer other.close();
    var saved = try other.load(heap);
    defer saved.deinit();
    try testing.expectEqualStrings("profile-b", saved.data.preferences.input_profile_id);
    var changed = saved.data.preferences;
    changed.reaction_count = 10;
    try other.savePreferences(changed);

    try testing.expectError(error.DatabaseChanged, app.selectDetectedProfile("/channel/a", .immediate));
    try testing.expectEqualStrings("profile-b", app.snapshot.data.preferences.input_profile_id);
    var readback = try other.load(heap);
    defer readback.deinit();
    try testing.expectEqualStrings("profile-b", readback.data.preferences.input_profile_id);
    try testing.expectEqual(changed.reaction_count, readback.data.preferences.reaction_count);
}

test "a rejected settings save leaves the active bindings and database shortcut keys intact" {
    const testing = std.testing;
    const heap = testing.allocator;
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const path = try std.fs.path.join(heap, &.{ root, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    var app: App = .{
        .executable = undefined,
        .db = &db,
        .snapshot = try db.load(heap),
        .history = storage.LibraryHistory.init(heap),
        .running_digest = null,
    };
    defer app.deinit();
    const original = app.snapshot.data.preferences;
    const active = try shortcuts.validate(original.shortcut_keys);
    app.keyboard.tracker.replace(active);

    var other = try storage.Store.open(heap, path);
    defer other.close();
    var other_change = original;
    other_change.reaction_count = 10;
    try other.savePreferences(other_change);

    var requested = original;
    requested.shortcut_keys[0] = "^+q";
    try testing.expectError(error.DatabaseChanged, app.writePreferences(requested));
    try testing.expectEqualDeep(active, app.keyboard.tracker.bindings);
    try testing.expectEqualStrings(original.shortcut_keys[0], app.snapshot.data.preferences.shortcut_keys[0]);
    try testing.expectEqual(@as(u64, 0), app.library_revision);
    var stored = try other.load(heap);
    defer stored.deinit();
    try testing.expectEqualStrings(original.shortcut_keys[0], stored.data.preferences.shortcut_keys[0]);
    try testing.expectEqual(other_change.reaction_count, stored.data.preferences.reaction_count);
}

test "shortcut save publishes committed keys including swaps and the stop binding" {
    const testing = std.testing;
    const heap = testing.allocator;
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const path = try std.fs.path.join(heap, &.{ root, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    var app: App = .{
        .executable = undefined,
        .db = &db,
        .snapshot = try db.load(heap),
        .history = storage.LibraryHistory.init(heap),
        .running_digest = null,
    };
    defer app.deinit();
    app.keyboard.tracker.replace(try shortcuts.validate(app.snapshot.data.preferences.shortcut_keys));

    var changed = app.snapshot.data.preferences;
    const palette = @intFromEnum(shortcuts.Action.palette);
    const focus = @intFromEnum(shortcuts.Action.chat_focus);
    const clear = @intFromEnum(shortcuts.Action.chat_clear);
    const stop = @intFromEnum(shortcuts.Action.stop);
    changed.shortcut_keys[palette] = "^+q";
    changed.shortcut_keys[focus] = "^!q";
    changed.shortcut_keys[stop] = "^+s";
    try app.writePreferences(changed);
    try testing.expectEqualDeep(try shortcuts.validate(changed.shortcut_keys), app.keyboard.tracker.bindings);

    var duplicate = changed;
    duplicate.shortcut_keys[clear] = "!^Q";
    try testing.expectError(error.DuplicateShortcut, app.writePreferences(duplicate));
    try testing.expectEqualDeep(try shortcuts.validate(changed.shortcut_keys), app.keyboard.tracker.bindings);
    try testing.expectEqual(@as(u64, 1), app.library_revision);

    std.mem.swap([]const u8, &changed.shortcut_keys[focus], &changed.shortcut_keys[clear]);
    try app.writePreferences(changed);
    try testing.expectEqualDeep(try shortcuts.validate(changed.shortcut_keys), app.keyboard.tracker.bindings);
    try testing.expectEqual(@as(u64, 2), app.library_revision);
    var reopened = try storage.Store.open(heap, path);
    defer reopened.close();
    var saved = try reopened.load(heap);
    defer saved.deinit();
    try testing.expect(storage.Data.eql(.{ .preferences = changed }, saved.data));

    const pressed = app.keyboard.tracker.key('Q', false, shortcuts.ctrl | shortcuts.shift, 42, false, false);
    try testing.expect(pressed.consume and pressed.event == null);
    app.paletteReaction(.{ .kind = 2, .count = 10, .interval = 25 }, true);
    const released = app.keyboard.tracker.key('Q', true, 0, 42, false, false);
    try testing.expect(released.consume);
    try testing.expectEqual(@as(?shortcuts.Event, .{ .action = .palette, .window = 42 }), released.event);
}

test "unchanged reaction defaults and detection mode skip database writes" {
    const testing = std.testing;
    const heap = testing.allocator;
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const path = try std.fs.path.join(heap, &.{ root, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    var app: App = .{
        .executable = undefined,
        .db = &db,
        .snapshot = try db.load(heap),
        .history = storage.LibraryHistory.init(heap),
        .running_digest = null,
    };
    defer app.deinit();
    const prefs = app.snapshot.data.preferences;
    const unchanged: view.ReactionOptions = .{ .kind = prefs.reaction_kind, .count = prefs.reaction_count, .interval = prefs.reaction_interval_ms };
    const changed: view.ReactionOptions = .{ .kind = 2, .count = unchanged.count, .interval = unchanged.interval };

    try db.db.exec("PRAGMA query_only=ON");
    try app.saveReactionDefaults(unchanged);
    app.palette.detected_profile = true;
    app.changeMode(prefs.auto_mode);
    try testing.expect(app.palette.detected_profile);
    try testing.expectError(error.DatabaseReadOnly, app.saveReactionDefaults(changed));
    try testing.expectEqual(unchanged.kind, app.snapshot.data.preferences.reaction_kind);
    try testing.expectEqual(@as(u64, 0), app.input_settings_revision);
    try testing.expectEqual(@as(u64, 0), app.library_revision);
    var original = try db.load(heap);
    defer original.deinit();
    try testing.expectEqual(unchanged.kind, original.data.preferences.reaction_kind);

    try db.db.exec("PRAGMA query_only=OFF");
    try app.saveReactionDefaults(changed);
    try testing.expectEqual(changed.kind, app.snapshot.data.preferences.reaction_kind);
    try testing.expectEqual(@as(u64, 1), app.input_settings_revision);
    app.changeMode(!prefs.auto_mode);
    try testing.expectEqual(@as(u64, 2), app.input_settings_revision);
    var saved = try db.load(heap);
    defer saved.deinit();
    try testing.expectEqual(changed.kind, saved.data.preferences.reaction_kind);
    try testing.expectEqual(!prefs.auto_mode, saved.data.preferences.auto_mode);
}

test "desktop: return from management keeps its window open until the palette can be shown" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    const heap = testing.allocator;
    const Probe = struct {
        fn click(owner: win.HWND, button: win.HWND) void {
            _ = win.SendMessageW(owner, win.WM_COMMAND, @intCast(win.GetDlgCtrlID(button)), @bitCast(@intFromPtr(button)));
        }

        fn expectOptions(palette: view.Palette, indices: [3]win.LRESULT) !void {
            for ([_]win.HWND{ palette.reaction_kind, palette.reaction_count, palette.reaction_interval }, indices) |control, index|
                try testing.expectEqual(index, win.SendMessageW(control, win.CB_GETCURSEL, 0, 0));
        }

        fn expectProfile(app: *const App, label: []const u8, tooltip: []const u16) !void {
            const shown = try windows.text(app.palette.input_context, heap);
            defer heap.free(shown);
            try testing.expectEqualStrings(label, shown);
            var tip: [128]u16 = undefined;
            app.trayTip(&tip);
            try testing.expectEqualSlices(u16, tooltip, std.mem.sliceTo(&tip, 0));
        }
    };
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const path = try std.fs.path.join(heap, &.{ root, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    try db.save(.{
        .preferences = .{ .auto_mode = false, .input_profile_id = "profile", .reaction_kind = 3, .reaction_count = 100, .reaction_interval_ms = 150 },
        .profiles = &.{.{ .id = "profile", .name = "試験配信者", .items = &.{.{ .id = "entry", .name = "試験用", .text = "本文" }} }},
    });
    var app: App = .{
        .executable = undefined,
        .db = &db,
        .snapshot = try db.load(heap),
        .history = storage.LibraryHistory.init(heap),
        .running_digest = null,
    };
    defer app.deinit();
    const previous = current;
    current = &app;
    defer current = previous;
    var wc = std.mem.zeroes(win.WNDCLASSW);
    wc.hInstance = win.GetModuleHandleW(null);
    wc.lpfnWndProc = messageHandler;
    wc.lpszClassName = windows.wide("ChatPalette.TestManagementReturn");
    if (win.RegisterClassW(&wc) == 0) return error.TestManagementReturnClass;
    app.window = win.CreateWindowExW(0, wc.lpszClassName, windows.wide("test"), 0, 0, 0, 0, 0, null, null, wc.hInstance, null) orelse return error.TestManagementReturnHost;
    try app.palette.open(app.window);
    try app.manager.open(app.window, &db, &app.snapshot, &app.history);
    app.manager.show();
    app.target = @ptrFromInt(42);
    app.palette.resetReaction(.{ .reaction_kind = 2, .reaction_count = 10, .reaction_interval_ms = 25 });
    for ([_]enum { worker, page, modal }{ .worker, .page, .modal }) |blocked| {
        app.worker.active = blocked == .worker;
        app.queue.active = blocked == .page;
        app.modal = blocked == .modal;
        for ([_]win.HWND{ app.manager.back, app.manager.load_defaults }) |button| {
            Probe.click(app.manager.window, button);
            try testing.expect(win.IsWindowVisible(app.manager.window) != 0);
            try testing.expect(win.IsWindowVisible(app.palette.window) == 0);
            try testing.expectEqual(@as(usize, 42), windows.number(app.target));
            try Probe.expectOptions(app.palette, .{ 1, 1, 1 });
        }
    }
    app.modal = false;
    Probe.click(app.manager.window, app.manager.back);
    try testing.expect(win.IsWindowVisible(app.palette.window) != 0);
    try testing.expect(win.IsWindowVisible(app.manager.window) == 0);
    try testing.expectEqual(@as(usize, 42), windows.number(app.target));
    try Probe.expectOptions(app.palette, .{ 1, 1, 1 });
    try Probe.expectProfile(&app, "手動選択：試験配信者", windows.wide("ChatPalette：試験配信者"));

    app.openManagement(false);
    Probe.click(app.manager.window, app.manager.load_defaults);
    try testing.expect(win.IsWindowVisible(app.palette.window) != 0 and win.IsWindowVisible(app.manager.window) == 0);
    try Probe.expectOptions(app.palette, .{ 2, 2, 4 });
    try testing.expectEqual(@as(u64, 0), app.input_settings_revision);

    var detected = app.snapshot.data.preferences;
    detected.auto_mode = true;
    app.palette.detected_profile = true;
    try app.writePreferences(detected);
    try testing.expectEqualStrings("profile", (app.palette.selectedRow() orelse return error.MissingSelectedProfileRow).profile_id);
    try Probe.expectProfile(&app, "自動判別：試験配信者", windows.wide("ChatPalette：試験配信者"));
    app.openManagement(true);
    try testing.expect(win.IsWindowVisible(app.manager.window) != 0);
    try testing.expect(app.manager.editing == null and app.manager.selection == null);
    try testing.expectEqualStrings("profile", app.snapshot.data.preferences.input_profile_id);
    app.target = null;
    Probe.click(app.manager.window, app.manager.back);
    try testing.expect(app.palette.count == 0);
    try Probe.expectProfile(&app, "自動判別：共通の弾幕のみ", windows.wide("ChatPalette：配信者未選択"));
    try testing.expectEqualStrings("profile", app.snapshot.data.preferences.input_profile_id);
}

test "desktop: saved library edits and imports report view failures and recover without replaying the save" {
    try @import("test_mode.zig").requireDesktop();
    const testing = std.testing;
    const heap = testing.allocator;
    const Fault = struct {
        fn rejectRefresh(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: usize, _: usize) callconv(.winapi) win.LRESULT {
            if (message == win.CB_ADDSTRING) return win.CB_ERRSPACE;
            if (message == win.LB_ADDSTRING) return win.LB_ERRSPACE;
            if (message == win.LVM_SETITEMCOUNT) return 0;
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }
    };
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const path = try std.fs.path.join(heap, &.{ root, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    try db.save(.{ .shared_items = &.{.{ .id = "alpha", .name = "Alpha", .text = "first" }} });

    var class = std.mem.zeroes(win.WNDCLASSW);
    class.hInstance = win.GetModuleHandleW(null);
    class.lpszClassName = windows.wide("ChatPalette.TestSavedRefresh");
    class.lpfnWndProc = messageHandler;
    try testing.expect(win.RegisterClassW(&class) != 0);
    defer _ = win.UnregisterClassW(class.lpszClassName, class.hInstance);
    var app: App = .{
        .executable = undefined,
        .db = &db,
        .snapshot = try db.load(heap),
        .history = storage.LibraryHistory.init(heap),
        .running_digest = null,
    };
    defer app.deinit();
    current = &app;
    defer current = null;
    app.window = win.CreateWindowExW(0, class.lpszClassName, windows.wide("test"), 0, 0, 0, 0, 0, null, null, class.hInstance, null) orelse return error.TestHost;
    try app.palette.open(app.window);
    app.palette.refresh(app.snapshot.data);
    _ = win.ShowWindow(app.palette.window, win.SW_SHOWNOACTIVATE);
    try app.manager.open(app.window, &db, &app.snapshot, &app.history);
    var row = std.mem.zeroes(win.LVITEMW);
    row.stateMask = win.LVIS_SELECTED | win.LVIS_FOCUSED;
    row.state = row.stateMask;
    try testing.expect(win.SendMessageW(app.manager.list, win.LVM_SETITEMSTATE, 0, @bitCast(@intFromPtr(&row))) != 0);
    const duplicate = win.FindWindowExW(app.manager.window, null, windows.wide("Button"), windows.wide("複製")) orelse return error.TestDuplicateButton;
    const duplicate_id: win.WPARAM = @intCast(win.GetDlgCtrlID(duplicate));

    {
        try testing.expect(win.SetWindowSubclass(app.palette.list, Fault.rejectRefresh, 1, 0) != 0);
        defer _ = win.RemoveWindowSubclass(app.palette.list, Fault.rejectRefresh, 1);
        _ = win.SendMessageW(app.manager.window, win.WM_COMMAND, duplicate_id, @bitCast(@intFromPtr(duplicate)));
        const duplicate_notice = try windows.text(app.manager.notice, heap);
        defer heap.free(duplicate_notice);
        try testing.expectEqualStrings("通知：保存済みです。パレットを更新できませんでした。パレットを開き直してください。", duplicate_notice);
        try testing.expect(app.palette.refresh_failed and !app.manager.list_update_failed);
        try testing.expectEqual(@as(win.LRESULT, 2), win.SendMessageW(app.manager.list, win.LVM_GETITEMCOUNT, 0, 0));
        var duplicated = try db.load(heap);
        defer duplicated.deinit();
        try testing.expectEqual(@as(usize, 2), duplicated.data.shared_items.len);
        try testing.expectEqual(@as(usize, 1), app.history.length);

        try testing.expect(win.SetWindowSubclass(app.manager.list, Fault.rejectRefresh, 2, 0) != 0);
        defer _ = win.RemoveWindowSubclass(app.manager.list, Fault.rejectRefresh, 2);
        const undo = app.manager.undo_button;
        _ = win.SendMessageW(app.manager.window, win.WM_COMMAND, @intCast(win.GetDlgCtrlID(undo)), @bitCast(@intFromPtr(undo)));
        const undo_notice = try windows.text(app.manager.notice, heap);
        defer heap.free(undo_notice);
        try testing.expectEqualStrings("通知：保存済みです。管理画面とパレットを更新できませんでした。両方の画面を開き直してください。", undo_notice);
        try testing.expect(app.palette.refresh_failed and app.manager.list_update_failed);
        try testing.expectEqual(@as(win.LRESULT, 2), win.SendMessageW(app.manager.list, win.LVM_GETITEMCOUNT, 0, 0));
        try testing.expectEqual(@as(usize, 0), app.history.length);
    }
    app.manager.refresh();
    app.palette.refresh(app.snapshot.data);
    try testing.expect(!app.palette.refresh_failed and !app.manager.list_update_failed);
    try testing.expectEqual(@as(win.LRESULT, 1), win.SendMessageW(app.manager.list, win.LVM_GETITEMCOUNT, 0, 0));
    try testing.expectEqual(@as(usize, 1), app.palette.count);
    var restored = try db.load(heap);
    defer restored.deinit();
    try testing.expectEqual(@as(usize, 1), restored.data.shared_items.len);
    try testing.expectEqualStrings("alpha", restored.data.shared_items[0].id);
    try testing.expectEqual(@as(u64, 2), app.library_revision);

    {
        try testing.expect(win.SetWindowSubclass(app.manager.scope, Fault.rejectRefresh, 3, 0) != 0);
        defer _ = win.RemoveWindowSubclass(app.manager.scope, Fault.rejectRefresh, 3);
        try testing.expect(win.SendMessageW(app.manager.list, win.LVM_SETITEMSTATE, 0, @bitCast(@intFromPtr(&row))) != 0);
        _ = win.SendMessageW(app.manager.window, win.WM_COMMAND, duplicate_id, @bitCast(@intFromPtr(duplicate)));
        const scope_notice = try windows.text(app.manager.notice, heap);
        defer heap.free(scope_notice);
        try testing.expectEqualStrings("通知：保存済みです。管理画面を更新できませんでした。管理画面を開き直してください。", scope_notice);
        try testing.expect(app.manager.refreshFailed() and !app.manager.list_update_failed and !app.palette.refresh_failed);
        try testing.expect(win.IsWindowEnabled(app.manager.scope) == 0);
        try testing.expect(win.IsWindowEnabled(duplicate) != 0);
        // A row button may retry the failed view, but the stale row cannot trigger another write.
        _ = win.SendMessageW(app.manager.window, win.WM_COMMAND, duplicate_id, @bitCast(@intFromPtr(duplicate)));
        try testing.expect(app.manager.refreshFailed() and !app.manager.isEditing());
        try testing.expectEqual(@as(usize, 2), app.palette.count);
        var saved = try db.load(heap);
        defer saved.deinit();
        try testing.expectEqual(@as(usize, 2), saved.data.shared_items.len);
        try testing.expectEqual(@as(usize, 1), app.history.length);
    }
    _ = win.SendMessageW(app.manager.window, win.WM_COMMAND, duplicate_id, @bitCast(@intFromPtr(duplicate)));
    try testing.expect(!app.manager.refreshFailed() and win.IsWindowEnabled(app.manager.scope) != 0);
    try testing.expectEqual(@as(win.LRESULT, 1), win.SendMessageW(app.manager.scope, win.CB_GETCOUNT, 0, 0));
    try testing.expectEqual(@as(win.LRESULT, -1), win.SendMessageW(app.manager.list, win.LVM_GETNEXTITEM, std.math.maxInt(usize), win.LVNI_SELECTED));
    try testing.expectEqual(@as(usize, 1), app.history.length);
    try testing.expectEqual(@as(u64, 3), app.library_revision);

    const backup_path = try std.fs.path.join(heap, &.{ root, "before-import.json" });
    defer heap.free(backup_path);
    var before_import = try db.load(heap);
    defer before_import.deinit();
    var imported: storage.Data = .{ .shared_items = &.{.{ .id = "imported", .name = "Imported", .text = "replacement" }} };
    imported.preferences.shortcut_keys[@intFromEnum(shortcuts.Action.palette)] = "^+F12";
    const bindings = try shortcuts.validate(imported.preferences.shortcut_keys);
    app.worker.registrations_current = true;
    {
        try testing.expect(win.SetWindowSubclass(app.manager.list, Fault.rejectRefresh, 2, 0) != 0);
        defer _ = win.RemoveWindowSubclass(app.manager.list, Fault.rejectRefresh, 2);
        const warning = commit: {
            var incoming = storage.Snapshot.init(heap);
            errdefer incoming.deinit();
            incoming.data = imported;
            break :commit try app.commitImportedData(incoming, bindings, backup_path);
        };
        try testing.expectEqualStrings("保存済みです。管理画面を更新できませんでした。管理画面を開き直してください。", warning);
        try testing.expect(app.manager.list_update_failed and !app.palette.refresh_failed);
        try testing.expectEqual(@as(win.LRESULT, 2), win.SendMessageW(app.manager.list, win.LVM_GETITEMCOUNT, 0, 0));
        try testing.expectEqual(@as(usize, 1), app.palette.count);
        try testing.expectEqual(@as(usize, 0), app.history.length);
        try testing.expect(!app.worker.registrations_current);
        try testing.expectEqualDeep(bindings, app.keyboard.tracker.bindings);
        var saved = try db.load(heap);
        defer saved.deinit();
        try testing.expect(storage.Data.eql(imported, saved.data));
    }
    var backup = try storage.readJson(heap, backup_path);
    defer backup.deinit();
    try testing.expect(storage.Data.eql(before_import.data, backup.data));
    app.manager.refresh();
    try testing.expect(!app.manager.refreshFailed());
    try testing.expectEqual(@as(win.LRESULT, 1), win.SendMessageW(app.manager.list, win.LVM_GETITEMCOUNT, 0, 0));
    try testing.expectEqual(@as(u64, 4), app.library_revision);
}

test "SQLite commit and recovery failures preserve the live shortcuts and expose the failure to the editor" {
    const testing = std.testing;
    const heap = testing.allocator;
    const Connection = @FieldType(storage.Store, "db");
    const SqliteApi = @FieldType(Connection, "api");
    const Exec = @FieldType(SqliteApi, "sqlite3_exec");
    const Close = @FieldType(SqliteApi, "sqlite3_close_v2");
    const Args = @typeInfo(@typeInfo(Exec).pointer.child).@"fn".params;
    const Fault = struct {
        const Mode = enum { observe, rollback, rollback_and_close };
        threadlocal var mode: Mode = undefined;
        threadlocal var exec_original: Exec = undefined;
        threadlocal var close_original: Close = undefined;
        threadlocal var commits: usize = 0;
        threadlocal var rollbacks: usize = 0;
        threadlocal var recovery_closes: usize = 0;

        fn exec(
            db: Args[0].type.?,
            sql: Args[1].type.?,
            callback: Args[2].type.?,
            context: Args[3].type.?,
            message: Args[4].type.?,
        ) callconv(.c) c_int {
            const text = std.mem.span(sql);
            if (std.mem.eql(u8, text, "COMMIT")) commits += 1;
            if (std.mem.eql(u8, text, "ROLLBACK")) {
                rollbacks += 1;
                if (mode != .observe) return 10; // SQLITE_IOERR
            }
            return exec_original(db, sql, callback, context, message);
        }

        fn close(db: Args[0].type.?) callconv(.c) c_int {
            recovery_closes += 1;
            if (mode == .rollback_and_close) return 5; // SQLITE_BUSY
            return close_original(db);
        }
    };
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(root);
    const default_data: storage.Data = .{};
    const original_bindings = try shortcuts.validate(default_data.preferences.shortcut_keys);
    var requested = default_data.preferences;
    requested.shortcut_keys[@intFromEnum(shortcuts.Action.palette)] = "^+q";
    requested.shortcut_keys[@intFromEnum(shortcuts.Action.chat_focus)] = "^+f";
    requested.shortcut_keys[@intFromEnum(shortcuts.Action.stop)] = "^+s";
    requested.reaction_count = 10;

    for (std.meta.tags(Fault.Mode)) |mode| {
        const path = try std.fmt.allocPrint(heap, "{s}\\shortcut-{s}.db", .{ root, @tagName(mode) });
        defer heap.free(path);
        {
            var db = try storage.Store.open(heap, path);
            defer db.close();
            var app: App = .{
                .executable = undefined,
                .db = &db,
                .snapshot = try db.load(heap),
                .history = storage.LibraryHistory.init(heap),
                .running_digest = null,
            };
            defer app.deinit();
            app.keyboard.tracker.replace(original_bindings);
            try db.db.exec(
                \\CREATE TABLE verify_key_commit_parent(id INTEGER PRIMARY KEY);
                \\CREATE TABLE verify_key_commit_child(id INTEGER REFERENCES verify_key_commit_parent(id) DEFERRABLE INITIALLY DEFERRED);
                \\CREATE TRIGGER reject_test_draft AFTER UPDATE OF key ON shortcut_bindings
                \\WHEN NEW.action='palette' AND NEW.key='^+q'
                \\BEGIN INSERT INTO verify_key_commit_child(id) VALUES(1); END;
            );
            const exec_original = db.db.api.sqlite3_exec;
            const close_original = db.db.api.sqlite3_close_v2;
            defer {
                db.db.api.sqlite3_exec = exec_original;
                db.db.api.sqlite3_close_v2 = close_original;
            }
            Fault.mode = mode;
            Fault.exec_original = exec_original;
            Fault.close_original = close_original;
            Fault.commits = 0;
            Fault.rollbacks = 0;
            Fault.recovery_closes = 0;
            db.db.api.sqlite3_exec = Fault.exec;
            db.db.api.sqlite3_close_v2 = Fault.close;

            try testing.expectError(error.ConstraintViolation, app.writePreferences(requested));
            try testing.expectEqual(@as(usize, 1), Fault.commits);
            try testing.expectEqual(@as(usize, 1), Fault.rollbacks);
            try testing.expectEqual(@as(usize, if (mode == .observe) 0 else 1), Fault.recovery_closes);
            try testing.expectEqualDeep(original_bindings, app.keyboard.tracker.bindings);
            try testing.expect(storage.Data.eql(default_data, app.snapshot.data));
            try testing.expectEqual(@as(u64, 0), app.library_revision);
            const codes = db.failureCodes();
            try testing.expectEqual(@as(c_int, 19), codes.original & 0xff); // SQLITE_CONSTRAINT
            try testing.expectEqual(@as(?c_int, if (mode == .observe) null else 10), codes.rollback);
            try testing.expectEqual(@as(?c_int, if (mode == .rollback_and_close) 5 else null), codes.close);

            const text = try saveFailureMessage(heap, error.ConstraintViolation, codes);
            defer heap.free(text);
            try testing.expect(std.mem.startsWith(u8, text, "ConstraintViolation"));
            if (mode == .observe) {
                try testing.expectEqualStrings("ConstraintViolation", text);
            } else {
                try testing.expect(std.mem.indexOf(u8, text, "ロールバック エラー 10") != null);
                try testing.expect(std.mem.indexOf(u8, text, "再起動して設定を確認") != null);
                try testing.expectEqual(mode == .rollback_and_close, std.mem.indexOf(u8, text, "接続終了 エラー 5") != null);
                try testing.expectError(error.DatabaseClosedAfterRollbackFailure, app.writePreferences(requested));
                try testing.expectEqualDeep(codes, db.failureCodes());
            }
        }
        var reopened = try storage.Store.open(heap, path);
        defer reopened.close();
        var saved = try reopened.load(heap);
        defer saved.deinit();
        try testing.expect(storage.Data.eql(default_data, saved.data));
        try testing.expectEqual(@as(i64, 0), try reopened.db.scalarInt("SELECT COUNT(*) FROM verify_key_commit_child", &.{}));
    }
}

test "startup keyboard-hook failure advice includes the native cause" {
    const heap = std.testing.allocator;
    const text = try hookFailureMessage(heap, win.ERROR_ACCESS_DENIED);
    defer heap.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "再起動") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Windows エラー 5") != null);
}

fn keyboardContext() input.ShortcutContext {
    const app = current orelse return .{ .window = 0, .browser = false, .stoppable = false };
    const target = win.GetForegroundWindow();
    return .{
        .window = windows.number(target),
        .browser = !app.modal and input.browser(target) != null,
        .stoppable = !app.modal and (app.queue.busy() or app.reaction != null or app.preparation != null or app.worker.active),
        .suspended = app.modal and (app.quitting or support.shortcutEditorAwayFrom(target) == null),
    };
}

fn shortcut(event: shortcuts.Event) void {
    const app = current orelse return;
    if (event.action == .stop) {
        app.stop();
        return;
    }
    // The hook owns a captured key's release even after its window loses foreground.
    if (!app.foreground(event.window)) return;
    if (app.modal) {
        if (event.action == .palette) {
            if (support.shortcutEditorAwayFrom(@ptrFromInt(event.window))) |editor| windows.recallOwnedWindow(editor);
        }
        return;
    }
    if (app.manager.isEditing()) {
        if (event.action == .palette) app.manager.show();
        return;
    }
    if (!app.shortcutAllowed(event.action)) return;
    if (event.action == .palette and (app.reaction != null or app.preparation != null)) {
        _ = win.PostMessageW(app.window, feedback.wm_present, 0, 0);
        return;
    }
    const video = if (app.reaction) |job|
        (if (job.target == event.window) job.video else null)
    else if (app.preparation) |pending|
        (if (pending.target == event.window) pending.video else null)
    else
        null;
    const generation = app.queue.generation;
    app.enqueueShortcut(event, video) catch {
        app.queue.cancel();
        if (app.input_cancellation) |pending| pending.signal.cancel();
        return;
    };
    if (event.action == .reaction) app.reaction_revision +%= 1;
    if (app.input_cancellation) |pending| {
        if (app.queue.generation != generation or pending.target != event.window) pending.signal.cancel();
    }
    _ = win.PostMessageW(app.window, drain_message, 0, 0);
}

fn messageHandler(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    const app = current orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win.WM_CLOSE, instance.take_over => app.quit(false),
        win.WM_COMMAND => {
            if (lparam != 0 or windows.high(wparam) != 0) return win.DefWindowProcW(hwnd, message, wparam, lparam);
            app.menuCommand(windows.low(wparam));
        },
        tray_message => switch (lparam) {
            win.WM_LBUTTONDBLCLK => app.show(.active_window),
            win.WM_RBUTTONUP => app.contextMenu(),
            else => {},
        },
        win.WM_TIMER => switch (wparam) {
            timer_reaction_feedback => app.hideFinishedReaction(),
            timer_status_tip => app.expireStatusTip(),
            else => if (app.reaction_timer) |timer| {
                if (wparam == timer.id) switch (timer.kind) {
                    .preparation => app.prepareNow(),
                    .send => app.advanceReaction(),
                };
            },
        },
        drain_message => app.drain(),
        advance_reaction_message => if (wparam == app.reaction_generation) app.advanceReaction(),
        view.wm_insert => app.insertFromPalette(wparam),
        view.wm_stop, feedback.wm_stop => app.stop(),
        feedback.wm_present => if (!app.quitting and (app.reaction != null or app.preparation != null or app.reaction_hide_at != null)) app.reaction_progress.show(),
        view.wm_manage => app.openManagement(true),
        view.wm_link => app.linkFromPalette(),
        view.wm_support => app.contextMenu(),
        view.wm_mode => app.changeMode(wparam == 0),
        view.wm_profile => app.changeProfile(wparam),
        view.wm_start_reaction, view.wm_save_defaults => if (lparam != 0) {
            const choice: *const view.ReactionOptions = @ptrFromInt(@as(usize, @bitCast(lparam)));
            app.paletteReaction(choice.*, message == view.wm_save_defaults);
        },
        management.wm_changed => {
            app.libraryChanged();
            return @intFromBool(app.palette.refresh_failed);
        },
        management.wm_back => app.show(.{ .previous_target = if (wparam == 0) .keep_options else .load_defaults }),
        management.wm_support => app.contextMenu(),
        management.wm_edit_allowed => {
            app.syncOperationButtons();
            return @intFromBool(app.canEdit());
        },
        management.wm_resolve_channel => if (lparam != 0) app.resolveChannel(@ptrFromInt(@as(usize, @bitCast(lparam)))),
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
    return 0;
}

fn dispatch(message: *win.MSG) void {
    defer if (current) |app| app.syncOperationButtons();
    if (current) |app| {
        app.syncOperationButtons();
        if (app.manager.filterMessage(message)) return;
        if (app.palette.filterMessage(message)) return;
        if (app.help.filterMessage(message)) return;
        if (app.diagnostic_view.filterMessage(message)) return;
        if (app.reaction_details.filterMessage(message)) return;
    }
    _ = win.TranslateMessage(message);
    _ = win.DispatchMessageW(message);
}

fn pump(signal: win.HANDLE, milliseconds: u32) !void {
    if (current) |app| app.syncOperationButtons();
    if (win.MsgWaitForMultipleObjectsEx(1, &signal, milliseconds, win.QS_ALLINPUT, win.MWMO_INPUTAVAILABLE) == win.WAIT_FAILED)
        return error.WorkerWaitFailed;
    var message: win.MSG = undefined;
    var count: usize = 0;
    while (count < 32 and win.PeekMessageW(&message, null, 0, 0, win.PM_REMOVE) != 0) : (count += 1) {
        if (message.message == win.WM_QUIT) {
            win.PostQuitMessage(@intCast(message.wParam));
            return;
        }
        dispatch(&message);
    }
}
