const std = @import("std");
const storage = @import("../storage/store.zig");
const windows = @import("win.zig");
const viewport = @import("viewport.zig");
const Viewport = viewport.Viewport;
const win = windows.api;
const allocator = std.heap.page_allocator;
const class = windows.wide("ChatPalette.Palette");
const search_timer = 1;
extern "kernel32" fn FindStringOrdinal(win.DWORD, [*]const u16, c_int, [*]const u16, c_int, win.BOOL) callconv(.winapi) c_int;
pub const wm_insert = win.WM_APP + 10;
pub const wm_stop = win.WM_APP + 11;
pub const wm_manage = win.WM_APP + 12;
pub const wm_support = win.WM_APP + 13;
pub const wm_mode = win.WM_APP + 14;
pub const wm_profile = win.WM_APP + 15;
pub const wm_start_reaction = win.WM_APP + 16;
pub const wm_save_defaults = win.WM_APP + 17;
pub const wm_link = win.WM_APP + 25;

const Id = enum(u16) { search = 101, list, insert, stop, manage, support, auto_mode, profile, start, reaction_kind, reaction_count, reaction_interval, save_defaults, load_defaults, link };

pub const ReactionOptions = struct { kind: u8, count: u32, interval: u32 };
pub const reaction_counts = [_]u32{ 1, 10, 100, 1000, 10000 };
pub const reaction_intervals = [_]u32{ 0, 25, 50, 100, 150, 200, 250, 500, 1000 };

pub const Palette = struct {
    const Row = struct { item: storage.Item, profile_id: []const u8 };

    window: win.HWND = null,
    dpi: windows.Dpi = .{},
    font: windows.GuiFont = .{},
    host: win.HWND = null,
    search: win.HWND = null,
    list: win.HWND = null,
    preview: win.HWND = null,
    insert_button: win.HWND = null,
    stop_button: win.HWND = null,
    manage_button: win.HWND = null,
    support_button: win.HWND = null,
    link_button: win.HWND = null,
    mode: win.HWND = null,
    profile: win.HWND = null,
    profile_choices: @import("profile_choices.zig") = .{},
    reaction_heading: win.HWND = null,
    reaction_registration: win.HWND = null,
    reaction_kind: win.HWND = null,
    reaction_count: win.HWND = null,
    reaction_interval: win.HWND = null,
    start_button: win.HWND = null,
    save_defaults: win.HWND = null,
    load_defaults: win.HWND = null,
    message: win.HWND = null,
    search_hint: win.HWND = null,
    viewport: Viewport = .{},
    laying_out: bool = false,
    data: storage.Data = .{},
    rows: [500]Row = undefined,
    count: usize = 0,
    selected_id: ?[]u8 = null,
    search_due: ?u64 = null,
    refreshing: bool = false,
    resetting_search: bool = false,
    refresh_failed: bool = false,
    scope_refresh_failed: bool = false,
    detected_profile: bool = false,

    pub fn open(self: *Palette, host: win.HWND) !void {
        self.host = host;
        self.dpi = windows.Dpi.system();
        var window_class = std.mem.zeroes(win.WNDCLASSW);
        window_class.lpfnWndProc = handle;
        window_class.hInstance = win.GetModuleHandleW(null);
        window_class.hCursor = win.LoadCursorW(null, @ptrFromInt(32512));
        window_class.hbrBackground = win.GetSysColorBrush(win.COLOR_WINDOW);
        window_class.lpszClassName = class;
        if (win.RegisterClassW(&window_class) == 0 and win.GetLastError() != win.ERROR_CLASS_ALREADY_EXISTS)
            return error.RegisterPalette;
        self.window = win.CreateWindowExW(win.WS_EX_CONTROLPARENT, class, windows.wide("ChatPalette"), win.WS_OVERLAPPEDWINDOW | win.WS_CLIPCHILDREN, win.CW_USEDEFAULT, win.CW_USEDEFAULT, self.dpi.pixels(580), self.dpi.pixels(665), null, null, window_class.hInstance, self) orelse return error.CreatePalette;
        errdefer self.close();
        self.font = try windows.GuiFont.init(self.dpi);
        self.mode = try control(self.window, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP, .auto_mode);
        self.profile = try control(self.window, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP | win.WS_VSCROLL, .profile);
        self.support_button = try control(self.window, "BUTTON", "管理・ヘルプ", win.WS_TABSTOP, .support);
        _ = addText(self.mode, win.CB_ADDSTRING, "自動判別");
        _ = addText(self.mode, win.CB_ADDSTRING, "手動選択");
        self.search = try control(self.window, "EDIT", "", win.ES_AUTOHSCROLL | win.WS_TABSTOP | win.WS_BORDER, .search);
        self.link_button = try control(self.window, "BUTTON", "チャンネル連携…", win.WS_TABSTOP, .link);
        self.list = try control(self.window, "LISTBOX", "", win.LBS_NOTIFY | win.WS_VSCROLL | win.WS_TABSTOP | win.WS_BORDER, .list);
        self.preview = try control(self.window, "EDIT", "", win.ES_READONLY | win.ES_MULTILINE | win.WS_VSCROLL | win.WS_BORDER, null);
        self.insert_button = try control(self.window, "BUTTON", "選んだ弾幕を入力", win.BS_DEFPUSHBUTTON | win.WS_TABSTOP, .insert);
        self.manage_button = try control(self.window, "BUTTON", "弾幕を追加・編集", win.WS_TABSTOP, .manage);
        self.stop_button = try control(self.window, "BUTTON", "停止", win.WS_TABSTOP, .stop);
        self.reaction_heading = try control(self.window, "STATIC", "今回のリアクション", 0, null);
        self.reaction_registration = try control(self.window, "STATIC", "対象ブラウザー：未選択", win.SS_NOPREFIX, null);
        self.reaction_kind = try control(self.window, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP, .reaction_kind);
        self.reaction_count = try control(self.window, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP, .reaction_count);
        self.reaction_interval = try control(self.window, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP, .reaction_interval);
        self.start_button = try control(self.window, "BUTTON", "リアクションを開始（3秒後）", win.WS_TABSTOP, .start);
        self.save_defaults = try control(self.window, "BUTTON", "標準設定に保存", win.WS_TABSTOP, .save_defaults);
        self.load_defaults = try control(self.window, "BUTTON", "標準設定を読み込む", win.WS_TABSTOP, .load_defaults);
        for ([_][]const u8{ "❤️ ハート", "😁 笑顔", "🎉 お祝い", "😲 驚き", "💯 100点", "ランダム（毎回）" }) |kind|
            _ = addText(self.reaction_kind, win.CB_ADDSTRING, kind);
        var label: [24]u8 = undefined;
        for (reaction_counts) |value| _ = addText(self.reaction_count, win.CB_ADDSTRING, try std.fmt.bufPrint(&label, "{d} 回", .{value}));
        for (reaction_intervals) |value|
            _ = addText(self.reaction_interval, win.CB_ADDSTRING, if (value == 0) "待機なし" else try std.fmt.bufPrint(&label, "{d} ms", .{value}));
        self.message = try control(self.window, "STATIC", "YouTubeの入力欄を選んでから弾幕を入力します。", 0, null);
        self.search_hint = try control(self.window, "STATIC", "", 0, null);
        _ = win.SendMessageW(self.search, win.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(windows.wide("弾幕名・本文を検索").ptr)));
        self.font.applyChildren(self.window);
        self.resize();
    }

    pub fn close(self: *Palette) void {
        self.profile_choices.clear();
        if (self.window != null) _ = win.DestroyWindow(self.window);
        self.font.deinit();
        if (self.selected_id) |id| allocator.free(id);
        self.selected_id = null;
        self.window = null;
    }

    pub fn show(self: *Palette) void {
        if (win.IsIconic(self.window) != 0) _ = win.ShowWindow(self.window, win.SW_RESTORE);
        if (win.IsZoomed(self.window) == 0) windows.fitWindow(self.window, null);
        const state: c_int = if (win.IsZoomed(self.window) != 0) win.SW_SHOW else win.SW_SHOWNORMAL;
        _ = win.ShowWindow(self.window, state);
        _ = win.SetForegroundWindow(self.window);
        _ = win.SetFocus(self.search);
        if (self.viewport.revealFocus(self.window)) self.resize();
    }

    pub fn filterMessage(self: *Palette, message: *win.MSG) bool {
        if (self.window == null or win.IsWindowVisible(self.window) == 0 or
            (message.hwnd != self.window and win.IsChild(self.window, message.hwnd) == 0)) return false;
        if (message.message == win.WM_KEYDOWN and message.wParam == win.VK_ESCAPE) {
            _ = win.SendMessageW(self.window, win.WM_CLOSE, 0, 0);
            return true;
        }
        const tab = message.message == win.WM_KEYDOWN and message.wParam == win.VK_TAB;
        if (win.IsDialogMessageW(self.window, message) == 0) return false;
        if (tab and self.viewport.revealFocus(self.window)) self.resize();
        return true;
    }

    pub fn status(self: Palette, value: []const u8) void {
        windows.setText(self.message, value);
    }

    pub fn registrationStatus(self: Palette, value: []const u8) void {
        windows.setText(self.reaction_registration, value);
    }

    pub fn refresh(self: *Palette, data: storage.Data) void {
        const refreshing = self.refreshing;
        self.refreshing = true;
        defer self.refreshing = refreshing;
        self.scope_refresh_failed = false;
        self.data = data;
        _ = win.SendMessageW(self.mode, win.CB_SETCURSEL, if (data.preferences.auto_mode) 0 else 1, 0);
        if (!self.profile_choices.sameNames(data.profiles)) {
            self.profile_choices.clear();
            _ = win.SendMessageW(self.profile, win.CB_RESETCONTENT, 0, 0);
            if (!addText(self.profile, win.CB_ADDSTRING, "配信者未選択")) self.scope_refresh_failed = true;
            for (data.profiles) |profile| {
                if (!addText(self.profile, win.CB_ADDSTRING, profile.name)) self.scope_refresh_failed = true;
            }
        }
        const profile_id = self.visibleProfileId();
        var selected: usize = 0;
        for (data.profiles, 1..) |profile, index| {
            if (std.mem.eql(u8, profile.id, profile_id)) {
                selected = index;
                break;
            }
        }
        if (self.window != null and !self.scope_refresh_failed) self.profile_choices.publish(data.profiles) catch {
            self.scope_refresh_failed = true;
        };
        _ = win.EnableWindow(self.profile, @intFromBool(!data.preferences.auto_mode and !self.scope_refresh_failed));
        if (win.SendMessageW(self.profile, win.CB_GETCURSEL, 0, 0) != @as(win.LRESULT, @intCast(selected)))
            _ = win.SendMessageW(self.profile, win.CB_SETCURSEL, selected, 0);
        self.refreshItems();
    }

    pub fn visibleProfileId(self: *const Palette) []const u8 {
        if (self.data.preferences.auto_mode and !self.detected_profile) return "";
        return self.data.preferences.input_profile_id;
    }

    pub fn resetReaction(self: Palette, defaults: storage.Preferences) void {
        _ = win.SendMessageW(self.reaction_kind, win.CB_SETCURSEL, defaults.reaction_kind - 1, 0);
        _ = win.SendMessageW(self.reaction_count, win.CB_SETCURSEL, std.mem.indexOfScalar(u32, &reaction_counts, defaults.reaction_count) orelse 0, 0);
        _ = win.SendMessageW(self.reaction_interval, win.CB_SETCURSEL, std.mem.indexOfScalar(u32, &reaction_intervals, defaults.reaction_interval_ms) orelse 0, 0);
    }

    pub fn reactionButtons(self: Palette, active: bool) void {
        _ = win.EnableWindow(self.start_button, @intFromBool(!active));
        _ = win.EnableWindow(self.stop_button, @intFromBool(active));
    }

    pub fn flushSearch(self: *Palette) void {
        if (self.search_due != null) self.refreshItems();
    }

    fn cancelSearch(self: *Palette) void {
        self.search_due = null;
        _ = win.KillTimer(self.window, search_timer);
    }

    fn queueSearch(self: *Palette) void {
        const profile = self.data.findProfile(self.visibleProfileId());
        const count = self.data.shared_items.len + if (profile) |value| value.items.len else 0;
        if (count <= 200) {
            self.refreshItems();
            return;
        }
        self.search_due = win.GetTickCount64() + 100;
        _ = win.EnableWindow(self.insert_button, 0);
        windows.setText(self.search_hint, "検索を更新しています…");
        if (win.SetTimer(self.window, search_timer, 100, null) == 0) self.refreshItems();
    }

    fn searchTimer(self: *Palette, now: u64, visible: bool) void {
        const due = self.search_due orelse return;
        if (!visible) self.cancelSearch() else if (now >= due) self.refreshItems();
    }

    fn settleSearchForAction(self: *Palette) bool {
        if (self.search_due == null) return false;
        self.refreshItems();
        if (!self.refresh_failed)
            windows.setText(self.search_hint, "検索結果を更新しました。弾幕を選んで操作してください。");
        return true;
    }

    pub fn resetSearch(self: *Palette) void {
        self.cancelSearch();
        // Import can release the previous library before publishing the new one.
        self.resetting_search = true;
        defer self.resetting_search = false;
        _ = win.SetWindowTextW(self.search, windows.wide(""));
        if (self.selected_id) |id| allocator.free(id);
        self.selected_id = null;
    }

    pub fn selectedRow(self: *Palette) ?Row {
        self.flushSearch();
        if (self.refresh_failed) return null;
        const index = win.SendMessageW(self.list, win.LB_GETCURSEL, 0, 0);
        if (index < 0 or index >= self.count) return null;
        return self.rows[@intCast(index)];
    }

    fn reactionCommand(self: Palette, message: win.UINT) void {
        const kind = win.SendMessageW(self.reaction_kind, win.CB_GETCURSEL, 0, 0);
        const count = win.SendMessageW(self.reaction_count, win.CB_GETCURSEL, 0, 0);
        const interval = win.SendMessageW(self.reaction_interval, win.CB_GETCURSEL, 0, 0);
        if (kind < 0 or kind >= 6 or count < 0 or count >= reaction_counts.len or interval < 0 or interval >= reaction_intervals.len) return;
        var choice: ReactionOptions = .{ .kind = @intCast(kind + 1), .count = reaction_counts[@intCast(count)], .interval = reaction_intervals[@intCast(interval)] };
        _ = win.SendMessageW(self.host, message, 0, @bitCast(@intFromPtr(&choice)));
    }

    pub fn refreshItems(self: *Palette) void {
        if (self.list == null) return;
        const refreshing = self.refreshing;
        self.refreshing = true;
        defer self.refreshing = refreshing;
        self.cancelSearch();
        const raw_query = windows.text(self.search, allocator) catch return self.failItemRefresh();
        defer allocator.free(raw_query);
        const query = std.mem.trim(u8, raw_query, " \t");
        _ = win.SendMessageW(self.list, win.WM_SETREDRAW, 0, 0);
        defer {
            _ = win.SendMessageW(self.list, win.WM_SETREDRAW, 1, 0);
            _ = win.InvalidateRect(self.list, null, 1);
        }
        _ = win.SendMessageW(self.list, win.LB_RESETCONTENT, 0, 0);
        self.count = 0;
        var truncated = false;
        if (self.data.findProfile(self.visibleProfileId())) |profile| {
            for (profile.items) |item| {
                if (self.addMatch(query, item, profile.name, profile.id) catch return self.failItemRefresh()) {
                    truncated = true;
                    break;
                }
            }
        }
        if (!truncated) {
            for (self.data.shared_items) |item| {
                if (self.addMatch(query, item, "共通", "") catch return self.failItemRefresh()) {
                    truncated = true;
                    break;
                }
            }
        }
        self.refresh_failed = self.scope_refresh_failed;
        windows.setText(self.search_hint, if (truncated)
            "先頭500件を表示しています。検索で絞り込んでください。"
        else if (self.count > 0)
            "弾幕は入力のみです。内容を確認してYouTubeで送信します。"
        else if (query.len != 0)
            "一致する弾幕がありません。"
        else
            "弾幕を追加・編集できます。");
        if (self.count > 0) {
            const index = if (self.selected_id) |id| for (self.rows[0..self.count], 0..) |row, n| {
                if (std.mem.eql(u8, row.item.id, id)) break n;
            } else 0 else 0;
            _ = win.SendMessageW(self.list, win.LB_SETCURSEL, index, 0);
        }
        self.showSelection();
    }

    fn failItemRefresh(self: *Palette) void {
        self.refresh_failed = true;
        self.count = 0;
        _ = win.SendMessageW(self.list, win.LB_RESETCONTENT, 0, 0);
        windows.setText(self.search_hint, "弾幕一覧を更新できませんでした。検索し直してください。");
        self.showSelection();
    }

    fn addMatch(self: *Palette, query: []const u8, item: storage.Item, scope: []const u8, profile_id: []const u8) !bool {
        if (!matchesQuery(query, item)) return false;
        if (self.count == self.rows.len) return true;
        const key = if (item.slot == 0) "" else self.data.preferences.shortcut_keys[(if (profile_id.len == 0) @as(usize, 3) else 1) + item.slot - 1];
        const text = try std.fmt.allocPrint(allocator, "{s}　{s}{s}{s}{s}", .{ scope, item.name, if (key.len > 0) "　[" else "", key, if (key.len > 0) "]" else "" });
        defer allocator.free(text);
        if (!addText(self.list, win.LB_ADDSTRING, text)) return error.RenderPaletteRow;
        self.rows[self.count] = .{ .item = item, .profile_id = profile_id };
        self.count += 1;
        return false;
    }

    fn showSelection(self: *Palette) void {
        const selected = win.SendMessageW(self.list, win.LB_GETCURSEL, 0, 0);
        const item = if (selected >= 0 and selected < self.count) self.rows[@intCast(selected)].item else null;
        _ = win.EnableWindow(self.insert_button, @intFromBool(item != null and !self.refresh_failed and self.search_due == null));
        windows.setText(self.preview, if (item) |value| value.text else "");
        if (self.selected_id) |id| allocator.free(id);
        self.selected_id = if (item) |value| allocator.dupe(u8, value.id) catch null else null;
    }

    fn insert(self: *Palette) void {
        if (self.refreshing or self.settleSearchForAction() or self.refresh_failed) return;
        const index = win.SendMessageW(self.list, win.LB_GETCURSEL, 0, 0);
        if (!self.refreshing and !self.refresh_failed and index >= 0 and index < self.count)
            _ = win.SendMessageW(self.host, wm_insert, @intCast(index), 0);
    }

    fn resize(self: *Palette) void {
        if (self.search_hint == null or self.laying_out) return;
        self.laying_out = true;
        defer self.laying_out = false;
        const content = self.viewport.layout(self.window, self.dpi, .{ .width = 344, .height = 373 }, .{ .below_width = 535, .minimum_height = 405 }) orelse return;
        self.layout(self.dpi.fittingUnits(content.width), self.dpi.fittingUnits(content.height));
    }

    fn place(self: Palette, hwnd: win.HWND, x: i32, y: i32, width: i32, height: i32) void {
        self.viewport.place(self.dpi, hwnd, x, y, width, height);
    }

    fn layout(self: Palette, width: i32, height: i32) void {
        const padding: i32 = 12;
        const full = width - 2 * padding;
        const compact = width < 535;
        const extra: i32 = if (compact) 32 else 0;
        const registration_row: i32 = 21;
        const list_height = @max(height - 324 - extra - registration_row, 28);
        self.place(self.mode, padding, 12, 112, 180);
        self.place(self.profile, 134, 12, width - 264, 242);
        self.place(self.support_button, width - 122, 11, 110, 29);
        const link_width: i32 = 132;
        self.place(self.search, padding, 51, full - link_width - 8, 27);
        self.place(self.link_button, width - padding - link_width, 51, link_width, 27);
        self.place(self.list, padding, 85, full, list_height);
        self.place(self.preview, padding, 93 + list_height, full, 48);
        self.place(self.insert_button, padding, 149 + list_height, 164, 30);
        self.place(self.manage_button, padding + 173, 149 + list_height, 148, 30);
        self.place(self.reaction_heading, padding, 188 + list_height, full, 20);
        self.place(self.reaction_registration, padding, 209 + list_height, full, registration_row);
        const kind_width: i32 = if (compact) 134 else 142;
        const count_width: i32 = if (compact) 80 else 100;
        const interval_x = padding + kind_width + count_width + 16;
        const controls_top = list_height + registration_row;
        self.place(self.reaction_kind, padding, 209 + controls_top, kind_width, 210);
        self.place(self.reaction_count, padding + kind_width + 8, 209 + controls_top, count_width, 190);
        self.place(self.reaction_interval, interval_x, 209 + controls_top, @min(112, width - interval_x - padding), 235);
        self.place(self.start_button, padding, 242 + controls_top, 186, 27);
        self.place(self.stop_button, padding + 192, 242 + controls_top, 58, 27);
        const defaults_x: i32 = if (compact) padding else padding + 255;
        self.place(self.save_defaults, defaults_x, 242 + controls_top + extra, 111, 27);
        self.place(self.load_defaults, defaults_x + 117, 242 + controls_top + extra, 135, 27);
        self.place(self.message, padding, 276 + controls_top + extra, full, 25);
        self.place(self.search_hint, padding, 300 + controls_top + extra, full, 22);
    }
};

fn matchesQuery(query: []const u8, item: storage.Item) bool {
    if (query.len == 0) return true;
    var fallback = std.heap.stackFallback(2048, allocator);
    const scratch = fallback.get();
    const joined = std.fmt.allocPrint(scratch, "{s} {s}", .{ item.name, item.text }) catch return false;
    defer scratch.free(joined);
    if (std.ascii.indexOfIgnoreCase(joined, query) != null) return true;
    if (asciiOnly(joined) and asciiOnly(query)) return false;
    const source = std.unicode.utf8ToUtf16LeAlloc(scratch, joined) catch return false;
    defer scratch.free(source);
    const target = std.unicode.utf8ToUtf16LeAlloc(scratch, query) catch return false;
    defer scratch.free(target);
    return FindStringOrdinal(win.FIND_FROMSTART, source.ptr, @intCast(source.len), target.ptr, @intCast(target.len), 1) >= 0;
}

fn asciiOnly(value: []const u8) bool {
    for (value) |ch| if (!std.ascii.isAscii(ch)) return false;
    return true;
}

fn control(parent: win.HWND, comptime kind: []const u8, comptime text: []const u8, styles: win.DWORD, id: ?Id) !win.HWND {
    const menu: win.HMENU = if (id) |value| @ptrFromInt(@intFromEnum(value)) else null;
    const common: win.DWORD = win.WS_CHILD | win.WS_VISIBLE;
    const hwnd = win.CreateWindowExW(0, windows.wide(kind), windows.wide(text), common | styles, 0, 0, 1, 1, parent, menu, win.GetModuleHandleW(null), null) orelse return error.CreatePaletteControl;
    try viewport.trackFocus(hwnd, parent, styles);
    return hwnd;
}

fn addText(hwnd: win.HWND, message: win.UINT, value: []const u8) bool {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(allocator, value) catch return false;
    defer allocator.free(utf16);
    return win.SendMessageW(hwnd, message, 0, @bitCast(@intFromPtr(utf16.ptr))) >= 0;
}

fn handle(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    if (message == win.WM_NCCREATE) {
        const parameters: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(parameters.lpCreateParams)));
    }
    const ptr: usize = @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA));
    if (ptr == 0) return win.DefWindowProcW(hwnd, message, wparam, lparam);
    const palette: *Palette = @ptrFromInt(ptr);
    switch (message) {
        win.WM_CLOSE => {
            palette.cancelSearch();
            _ = win.ShowWindow(hwnd, win.SW_HIDE);
        },
        win.WM_KEYDOWN => if (wparam == win.VK_ESCAPE) {
            _ = win.SendMessageW(hwnd, win.WM_CLOSE, 0, 0);
        },
        win.WM_SHOWWINDOW => if (wparam == 0) palette.cancelSearch(),
        win.WM_SIZE => if (!palette.laying_out and wparam != win.SIZE_MINIMIZED) {
            palette.resize();
            if (palette.viewport.revealFocus(hwnd)) palette.resize();
        },
        viewport.wm_focus_changed => if (!palette.laying_out and palette.viewport.revealFocus(hwnd)) palette.resize(),
        win.WM_HSCROLL, win.WM_VSCROLL => if (lparam == 0 and palette.viewport.scroll(hwnd, if (message == win.WM_HSCROLL) win.SB_HORZ else win.SB_VERT, wparam, palette.dpi)) palette.resize(),
        win.WM_TIMER => if (wparam == search_timer) palette.searchTimer(win.GetTickCount64(), win.IsWindowVisible(hwnd) != 0),
        win.WM_GETMINMAXINFO => {
            const limits: *win.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            viewport.minimumTrack(hwnd, palette.dpi, limits);
        },
        win.WM_COMMAND => {
            const id = windows.low(wparam);
            const code = windows.high(wparam);
            if (id == @intFromEnum(Id.search) and code == win.EN_CHANGE and !palette.resetting_search) palette.queueSearch();
            if (id == @intFromEnum(Id.list) and code == win.LBN_SELCHANGE) palette.showSelection();
            if (id == @intFromEnum(Id.insert) and code == win.BN_CLICKED or id == @intFromEnum(Id.list) and code == win.LBN_DBLCLK) palette.insert();
            if (id == @intFromEnum(Id.stop) and code == win.BN_CLICKED) _ = win.SendMessageW(palette.host, wm_stop, 0, 0);
            if (id == @intFromEnum(Id.manage) and code == win.BN_CLICKED and !palette.settleSearchForAction())
                _ = win.SendMessageW(palette.host, wm_manage, 0, 0);
            if (id == @intFromEnum(Id.link) and code == win.BN_CLICKED) _ = win.SendMessageW(palette.host, wm_link, 0, 0);
            if (id == @intFromEnum(Id.support) and code == win.BN_CLICKED) _ = win.SendMessageW(palette.host, wm_support, 0, 0);
            if (id == @intFromEnum(Id.auto_mode) and code == win.CBN_SELCHANGE)
                _ = win.SendMessageW(palette.host, wm_mode, @intCast(@max(0, win.SendMessageW(palette.mode, win.CB_GETCURSEL, 0, 0))), 0);
            if (id == @intFromEnum(Id.profile) and code == win.CBN_SELCHANGE and !palette.refreshing)
                _ = win.SendMessageW(palette.host, wm_profile, @bitCast(win.SendMessageW(palette.profile, win.CB_GETCURSEL, 0, 0)), 0);
            if (id == @intFromEnum(Id.start) and code == win.BN_CLICKED) palette.reactionCommand(wm_start_reaction);
            if (id == @intFromEnum(Id.save_defaults) and code == win.BN_CLICKED) palette.reactionCommand(wm_save_defaults);
            if (id == @intFromEnum(Id.load_defaults) and code == win.BN_CLICKED) palette.resetReaction(palette.data.preferences);
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
    return 0;
}

test "palette matches across name and text and folds Unicode case" {
    const item = storage.Item{ .id = "1", .name = "Ä弾幕", .text = "日本語 😀", .slot = 0 };
    try std.testing.expect(matchesQuery("ä弾幕 日", item));
    try std.testing.expect(matchesQuery("日本語", item));
    try std.testing.expect(!matchesQuery("別", item));
}

test "palette keeps unchanged native labels and replaces their displayed ID mapping" {
    const Probe = struct {
        fn countResets(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, reference: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            const resets: *usize = @ptrFromInt(reference);
            if (message == win.CB_RESETCONTENT) resets.* += 1;
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }
    };
    var palette: Palette = .{};
    defer palette.close();
    try palette.open(null);
    var resets: usize = 0;
    try std.testing.expect(win.SetWindowSubclass(palette.profile, Probe.countResets, 6, @intFromPtr(&resets)) != 0);
    defer _ = win.RemoveWindowSubclass(palette.profile, Probe.countResets, 6);

    var profiles = [_]storage.Profile{ .{ .id = "one", .name = "Same" }, .{ .id = "two", .name = "Same" } };
    var data: storage.Data = .{ .profiles = &profiles, .preferences = .{ .auto_mode = false, .input_profile_id = "two" } };
    palette.refresh(data);
    palette.refresh(data);
    try std.testing.expectEqual(@as(usize, 1), resets);
    try std.testing.expectEqual(@as(win.LRESULT, 2), win.SendMessageW(palette.profile, win.CB_GETCURSEL, 0, 0));
    profiles[1].id = "replacement";
    data.preferences.input_profile_id = "replacement";
    palette.refresh(data);
    try std.testing.expectEqual(@as(usize, 1), resets);
    try std.testing.expectEqualStrings("replacement", palette.profile_choices.resolve(data, 2).?);
    profiles[1].name = "same";
    palette.refresh(data);
    try std.testing.expectEqual(@as(usize, 2), resets);
    try std.testing.expectEqual(@as(win.LRESULT, 2), win.SendMessageW(palette.profile, win.CB_GETCURSEL, 0, 0));
}

test "compact palette leaves room for the registration row and the bottom guidance" {
    var palette: Palette = .{};
    defer palette.close();
    try palette.open(null);
    const width = 344;
    const height = 410;
    palette.layout(width, height);

    var origin = std.mem.zeroes(win.POINT);
    try std.testing.expect(win.ClientToScreen(palette.window, &origin) != 0);
    for ([_]win.HWND{ palette.reaction_registration, palette.search_hint, palette.message, palette.load_defaults }) |control_window| {
        var bounds: win.RECT = undefined;
        try std.testing.expect(win.GetWindowRect(control_window, &bounds) != 0);
        try std.testing.expect(bounds.left >= origin.x and bounds.right <= origin.x + width);
        try std.testing.expect(bounds.top >= origin.y and bounds.bottom <= origin.y + height);
    }
    var list: win.RECT = undefined;
    try std.testing.expect(win.GetClientRect(palette.list, &list) != 0);
    try std.testing.expect(list.bottom >= win.SendMessageW(palette.list, win.LB_GETITEMHEIGHT, 0, 0));
}

test "short palette can scroll to every operation and clears its offsets when enlarged" {
    var palette: Palette = .{};
    defer palette.close();
    try palette.open(null);
    const flags = win.SWP_NOACTIVATE | win.SWP_NOZORDER | win.SWP_NOMOVE | win.SWP_NOSENDCHANGING;
    try std.testing.expect(win.SetWindowPos(palette.window, null, 0, 0, 285, 248, flags) != 0);
    _ = win.SendMessageW(palette.window, win.WM_VSCROLL, (@as(usize, 27) << 16) | win.SB_THUMBPOSITION, 0);
    try std.testing.expectEqual(@as(i32, 27), palette.viewport.y);
    _ = win.SendMessageW(palette.window, win.WM_HSCROLL, win.SB_RIGHT, 0);
    _ = win.SendMessageW(palette.window, win.WM_VSCROLL, win.SB_BOTTOM, 0);
    try std.testing.expect(palette.viewport.x > 0 and palette.viewport.y > 0);

    var client_bounds: win.RECT = undefined;
    var bottom: win.RECT = undefined;
    try std.testing.expect(win.GetClientRect(palette.window, &client_bounds) != 0);
    try std.testing.expect(win.GetWindowRect(palette.load_defaults, &bottom) != 0);
    _ = win.MapWindowPoints(null, palette.window, @ptrCast(&bottom), 2);
    try std.testing.expect(bottom.left >= 0 and bottom.right <= client_bounds.right);
    try std.testing.expect(bottom.top >= 0 and bottom.bottom <= client_bounds.bottom);

    try std.testing.expect(win.SetWindowPos(palette.window, null, 0, 0, 580, 620, flags) != 0);
    try std.testing.expectEqual(@as(i32, 0), palette.viewport.x);
    try std.testing.expectEqual(@as(i32, 0), palette.viewport.y);
    const style: u32 = @bitCast(win.GetWindowLongW(palette.window, win.GWL_STYLE));
    try std.testing.expectEqual(@as(u32, 0), style & (win.WS_HSCROLL | win.WS_VSCROLL));
}

test "palette searches beyond the visible 500 rows and retains the selected ID after reorder" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var palette: Palette = .{};
    defer palette.close();
    try palette.open(null);
    var items: [502]storage.Item = undefined;
    for (&items, 0..) |*item, index| item.* = .{
        .id = try std.fmt.allocPrint(memory.allocator(), "item-{d}", .{index}),
        .name = "共通の弾幕",
        .text = "前の検索対象",
    };
    items[501].text = "末尾の弾幕👏";
    palette.refresh(.{ .shared_items = &items });
    try std.testing.expectEqual(@as(usize, 500), palette.count);
    windows.setText(palette.search, "末尾");
    palette.flushSearch();
    try std.testing.expectEqual(@as(usize, 1), palette.count);
    try std.testing.expectEqualStrings("item-501", palette.selectedRow().?.item.id);
    std.mem.swap(storage.Item, &items[0], &items[501]);
    windows.setText(palette.search, "");
    palette.refresh(.{ .shared_items = &items });
    try std.testing.expectEqualStrings("item-501", palette.selectedRow().?.item.id);
}

test "scheduled palette search delays only large current scopes and settles before input or editing" {
    const Probe = struct {
        inputs: usize = 0,
        edits: usize = 0,
        redraws: usize = 0,
        reject_row: bool = false,

        fn observeList(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, reference: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            const self: *@This() = @ptrFromInt(reference);
            if (message == win.LB_RESETCONTENT) self.redraws += 1;
            if (message == win.LB_ADDSTRING and self.reject_row) return win.LB_ERRSPACE;
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }

        fn handleHost(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
            if (message == win.WM_NCCREATE) {
                const params: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(params.lpCreateParams)));
            }
            if (message == wm_insert or message == wm_manage) {
                const self: *@This() = @ptrFromInt(@as(usize, @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))));
                if (message == wm_insert) self.inputs += 1 else self.edits += 1;
                return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        }
    };
    var probe: Probe = .{};
    var wc = std.mem.zeroes(win.WNDCLASSW);
    wc.hInstance = win.GetModuleHandleW(null);
    wc.lpszClassName = windows.wide("ChatPalette.SearchTest");
    wc.lpfnWndProc = Probe.handleHost;
    try std.testing.expect(win.RegisterClassW(&wc) != 0 or win.GetLastError() == win.ERROR_CLASS_ALREADY_EXISTS);
    const host = win.CreateWindowExW(0, wc.lpszClassName, windows.wide(""), 0, 0, 0, 1, 1, null, null, wc.hInstance, &probe) orelse
        return error.CreateSearchTestHost;
    defer _ = win.DestroyWindow(host);
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var palette: Palette = .{};
    defer palette.close();
    try palette.open(host);
    try std.testing.expect(win.SetWindowSubclass(palette.list, Probe.observeList, 2, @intFromPtr(&probe)) != 0);
    var items: [201]storage.Item = undefined;
    for (&items, 0..) |*row, i| row.* = .{
        .id = try std.fmt.allocPrint(memory.allocator(), "item-{d}", .{i}),
        .name = "fixture",
        .text = if (i == 0) "alpha" else if (i == 1) "beta" else if (i == 200) "final" else "other",
    };
    palette.refresh(.{ .shared_items = items[0..200] });
    const before_small = probe.redraws;
    windows.setText(palette.search, "alpha");
    try std.testing.expect(palette.search_due == null);
    try std.testing.expectEqual(@as(usize, 1), palette.count);
    try std.testing.expectEqual(before_small + 1, probe.redraws);
    const data: storage.Data = .{
        .profiles = &.{.{ .id = "P", .name = "fixture", .items = &items }},
        .preferences = .{ .auto_mode = true, .input_profile_id = "P" },
    };
    palette.refresh(data);
    windows.setText(palette.search, "beta");
    try std.testing.expect(palette.search_due == null);
    try std.testing.expectEqual(@as(usize, 0), palette.count);
    palette.detected_profile = true;
    palette.refresh(data);
    try std.testing.expectEqualStrings("item-1", palette.rows[0].item.id);

    const before_rapid = probe.redraws;
    windows.setText(palette.search, "fi");
    palette.searchTimer(palette.search_due.? - 1, true);
    windows.setText(palette.search, "final");
    try std.testing.expectEqual(before_rapid, probe.redraws);
    try std.testing.expectEqualStrings("item-1", palette.rows[0].item.id);
    const list_change = (@as(usize, win.LBN_SELCHANGE) << 16) | @intFromEnum(Id.list);
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, list_change, 0);
    try std.testing.expect(win.IsWindowEnabled(palette.insert_button) == 0);
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, @intFromEnum(Id.manage), 0);
    try std.testing.expect(palette.search_due == null and probe.edits == 0);
    try std.testing.expectEqual(before_rapid + 1, probe.redraws);
    try std.testing.expectEqualStrings("item-200", palette.rows[0].item.id);
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, @intFromEnum(Id.manage), 0);
    try std.testing.expectEqual(@as(usize, 1), probe.edits);

    windows.setText(palette.search, "alpha");
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, @intFromEnum(Id.insert), 0);
    try std.testing.expect(palette.search_due == null and probe.inputs == 0);
    try std.testing.expectEqualStrings("item-0", palette.rows[0].item.id);
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, @intFromEnum(Id.insert), 0);
    try std.testing.expectEqual(@as(usize, 1), probe.inputs);

    const before_hide = probe.redraws;
    windows.setText(palette.search, "beta");
    palette.searchTimer(palette.search_due.?, false);
    try std.testing.expectEqualStrings("item-0", palette.rows[0].item.id);
    try std.testing.expect(palette.search_due == null);
    try std.testing.expectEqual(before_hide, probe.redraws);
    palette.refresh(data);
    palette.searchTimer(win.GetTickCount64(), true);
    try std.testing.expectEqualStrings("item-1", palette.rows[0].item.id);
    try std.testing.expectEqual(before_hide + 1, probe.redraws);

    windows.setText(palette.search, "final");
    const due = palette.search_due.?;
    palette.searchTimer(due, true);
    palette.searchTimer(due + 100, true);
    try std.testing.expectEqualStrings("item-200", palette.rows[0].item.id);
    try std.testing.expectEqual(before_hide + 2, probe.redraws);

    probe.reject_row = true;
    windows.setText(palette.search, "alpha");
    palette.flushSearch();
    try std.testing.expect(palette.refresh_failed and palette.count == 0);
    try std.testing.expectEqual(@as(win.LRESULT, 0), win.SendMessageW(palette.list, win.LB_GETCOUNT, 0, 0));
    palette.insert();
    try std.testing.expectEqual(@as(usize, 1), probe.inputs);

    probe.reject_row = false;
    windows.setText(palette.search, "beta");
    palette.flushSearch();
    try std.testing.expect(!palette.refresh_failed and win.IsWindowEnabled(palette.insert_button) != 0);
    palette.insert();
    try std.testing.expectEqual(@as(usize, 2), probe.inputs);
}

test "resetting the imported library clears the native search and drops the old selection" {
    var palette: Palette = .{};
    defer palette.close();
    try palette.open(null);
    var old = try storage.Snapshot.clone(allocator, .{ .shared_items = &.{.{ .id = "old-item", .name = "old", .text = "old text" }} });
    palette.refresh(old.data);
    windows.setText(palette.search, "stale search");
    old.deinit();
    palette.selected_id = try allocator.dupe(u8, "old-item");
    palette.resetSearch();
    try std.testing.expectEqual(@as(c_int, 0), win.GetWindowTextLengthW(palette.search));
    try std.testing.expect(palette.selected_id == null and palette.search_due == null);
}
