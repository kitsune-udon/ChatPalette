const std = @import("std");
const storage = @import("../storage/store.zig");
const windows = @import("win.zig");
const shortcuts = @import("shortcuts.zig");
const reaction_progress = @import("reaction_progress.zig");
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

const Id = enum(u16) { search = 101, list, insert, stop, manage, support, auto_mode, profile, start, reaction_kind, reaction_count, reaction_interval, save_defaults, load_defaults, link, sort };
const SortOrder = enum {
    saved,
    name_text_asc,
    name_text_desc,
    scope_asc,
    key_desc,

    fn label(self: SortOrder) []const u8 {
        return switch (self) {
            .saved => "保存順",
            .name_text_asc => "名前・本文 昇順",
            .name_text_desc => "名前・本文 降順",
            .scope_asc => "対象 昇順",
            .key_desc => "キー 降順",
        };
    }
};
const sort_row = 32;
const interval_hint_row = 24;
const notice_row = 34;
const reaction_detail_rows = interval_hint_row + 3 * notice_row - 24;
const minimum_width = 344;
const compact_width = 535;
const minimum_height = 394 + sort_row + reaction_detail_rows;
const compact_minimum_height = 426 + sort_row + reaction_detail_rows;

pub const ReactionOptions = struct { kind: u8, count: u32, interval: u32 };
pub const reaction_counts = storage.Preferences.reaction_counts;
pub const reaction_intervals = storage.Preferences.reaction_intervals;

pub const Palette = struct {
    const max_rows = 500;
    const Row = struct { item: storage.Item, profile_id: []const u8 };
    const ListPosition = struct { top: usize = 0, id: ?[]u8 = null };
    const ItemRows = struct {
        rows: [max_rows]Row = undefined,
        count: usize = 0,

        fn collect(self: *ItemRows, items: []const storage.Item, profile_id: []const u8, query: []const u8) bool {
            for (items) |item| {
                if (!matchesQuery(query, item)) continue;
                if (self.count == self.rows.len) return true;
                self.rows[self.count] = .{ .item = item, .profile_id = profile_id };
                self.count += 1;
            }
            return false;
        }
    };

    const SortContext = struct {
        order: SortOrder,
        preferences: *const storage.Preferences,
        profile_name: []const u8,

        fn lessThan(self: SortContext, lhs: Row, rhs: Row) bool {
            return switch (self.order) {
                .saved => false,
                .name_text_asc => nameTextOrder(lhs, rhs) == .lt,
                .name_text_desc => nameTextOrder(lhs, rhs) == .gt,
                .scope_asc => std.ascii.orderIgnoreCase(scopeText(lhs, self.profile_name), scopeText(rhs, self.profile_name)) == .lt,
                .key_desc => blk: {
                    var left: [32]u8 = undefined;
                    var right: [32]u8 = undefined;
                    break :blk std.ascii.orderIgnoreCase(keyText(lhs, self.preferences, &left), keyText(rhs, self.preferences, &right)) == .gt;
                },
            };
        }
    };

    window: win.HWND = null,
    dpi: windows.Dpi = .{},
    font: windows.GuiFont = .{},
    host: win.HWND = null,
    search: win.HWND = null,
    sort_label: win.HWND = null,
    sort_selector: win.HWND = null,
    list: win.HWND = null,
    preview: win.HWND = null,
    insert_button: win.HWND = null,
    stop_button: win.HWND = null,
    manage_button: win.HWND = null,
    support_button: win.HWND = null,
    link_button: win.HWND = null,
    mode: win.HWND = null,
    profile: win.HWND = null,
    input_context: win.HWND = null,
    profile_choices: @import("profile_choices.zig") = .{},
    reaction_heading: win.HWND = null,
    reaction_registration: win.HWND = null,
    reaction_kind: win.HWND = null,
    reaction_count: win.HWND = null,
    reaction_interval: win.HWND = null,
    interval_hint: win.HWND = null,
    start_button: win.HWND = null,
    save_defaults: win.HWND = null,
    load_defaults: win.HWND = null,
    message: win.HWND = null,
    reaction_notice: win.HWND = null,
    settings_notice: win.HWND = null,
    search_hint: win.HWND = null,
    viewport: Viewport = .{},
    data: storage.Data = .{},
    rows: [max_rows]Row = undefined,
    count: usize = 0,
    items_revision: u64 = 0,
    selected_id: ?[]u8 = null,
    row_ids_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(allocator),
    row_ids: []const []const u8 = &.{},
    saved_refresh_pending: bool = false,
    was_presented: bool = false,
    sort_order: SortOrder = .saved,
    search_due: ?u64 = null,
    operations_allowed: bool = true,
    refreshing: bool = false,
    items_refreshing: bool = false,
    items_pending: bool = false,
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
        self.input_context = try control(self.window, "STATIC", "", win.SS_NOPREFIX, null);
        _ = addText(self.mode, win.CB_ADDSTRING, "自動判別");
        _ = addText(self.mode, win.CB_ADDSTRING, "手動選択");
        self.search = try control(self.window, "EDIT", "", win.ES_AUTOHSCROLL | win.WS_TABSTOP | win.WS_BORDER, .search);
        self.link_button = try control(self.window, "BUTTON", "チャンネル連携…", win.WS_TABSTOP, .link);
        self.sort_label = try control(self.window, "STATIC", "並べ替え", 0, null);
        self.sort_selector = try control(self.window, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP, .sort);
        for (std.meta.tags(SortOrder)) |order|
            if (!addText(self.sort_selector, win.CB_ADDSTRING, order.label())) return error.CreatePaletteSortChoices;
        _ = win.SendMessageW(self.sort_selector, win.CB_SETCURSEL, @intFromEnum(self.sort_order), 0);
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
        self.interval_hint = try control(self.window, "STATIC", "", win.SS_NOPREFIX, null);
        self.start_button = try control(self.window, "BUTTON", "リアクションを開始（3秒後）", win.WS_TABSTOP, .start);
        self.save_defaults = try control(self.window, "BUTTON", "標準設定に保存", win.WS_TABSTOP, .save_defaults);
        self.load_defaults = try control(self.window, "BUTTON", "標準設定を読み込む", win.WS_TABSTOP, .load_defaults);
        for (reaction_progress.kind_labels) |kind|
            _ = addText(self.reaction_kind, win.CB_ADDSTRING, kind);
        var label: [24]u8 = undefined;
        for (reaction_counts) |value| _ = addText(self.reaction_count, win.CB_ADDSTRING, try std.fmt.bufPrint(&label, "{d} 回", .{value}));
        for (reaction_intervals) |value|
            _ = addText(self.reaction_interval, win.CB_ADDSTRING, if (value == 0) "待機なし" else try std.fmt.bufPrint(&label, "{d} ms", .{value}));
        self.message = try control(self.window, "STATIC", "YouTubeの入力欄を選んでから弾幕を入力します。", win.SS_NOPREFIX, null);
        self.reaction_notice = try control(self.window, "STATIC", "", win.SS_NOPREFIX, null);
        self.settings_notice = try control(self.window, "STATIC", "", win.SS_NOPREFIX, null);
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
        self.row_ids_arena.deinit();
        self.row_ids_arena = std.heap.ArenaAllocator.init(allocator);
        self.row_ids = &.{};
        self.saved_refresh_pending = false;
        self.was_presented = false;
        self.window = null;
        self.viewport = .{};
    }

    pub fn show(self: *Palette) void {
        if (self.saved_refresh_pending) self.refresh(self.data);
        if (win.IsIconic(self.window) != 0) _ = win.ShowWindow(self.window, win.SW_RESTORE);
        if (win.IsZoomed(self.window) == 0) windows.fitWindow(self.window, null);
        const state: c_int = if (win.IsZoomed(self.window) != 0) win.SW_SHOW else win.SW_SHOWNORMAL;
        _ = win.ShowWindow(self.window, state);
        self.was_presented = true;
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

    pub fn settingsStatus(self: Palette, value: []const u8) void {
        windows.setText(self.settings_notice, value);
    }

    pub fn registrationStatus(self: Palette, value: []const u8) void {
        windows.setText(self.reaction_registration, value);
    }

    pub fn deferHiddenRefresh(self: *Palette, data: storage.Data) void {
        self.saved_refresh_pending = true;
        self.cancelSearch();
        self.data = data;
        // Old native labels can stay hidden, but their row values borrow the old snapshot.
        self.count = 0;
        self.items_revision +%= 1;
        if (self.items_refreshing) self.items_pending = true;
        self.refresh_failed = false;
    }

    fn commandsSuspended(self: *const Palette) bool {
        return self.saved_refresh_pending or (self.was_presented and win.IsWindowVisible(self.window) == 0);
    }

    pub fn refresh(self: *Palette, data: storage.Data) void {
        const refreshing = self.refreshing;
        self.refreshing = true;
        defer self.restoreInteraction(refreshing);
        self.saved_refresh_pending = false;
        self.scope_refresh_failed = false;
        self.data = data;
        if (!refreshing) self.updateCommandButtons();
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
        const mode = if (self.data.preferences.auto_mode) "自動判別" else "手動選択";
        const scope = if (self.inputProfile()) |profile| profile.name else "共通の弾幕のみ";
        if (std.fmt.allocPrint(allocator, "{s}：{s}", .{ mode, scope })) |label| {
            defer allocator.free(label);
            windows.setText(self.input_context, label);
        } else |_| {}
        self.refreshItems();
    }

    pub fn visibleProfileId(self: *const Palette) []const u8 {
        if (self.data.preferences.auto_mode and !self.detected_profile) return "";
        return self.data.preferences.input_profile_id;
    }

    pub fn inputProfile(self: *const Palette) ?*const storage.Profile {
        return self.data.findProfile(self.visibleProfileId());
    }

    pub fn resetReaction(self: Palette, defaults: storage.Preferences) void {
        _ = win.SendMessageW(self.reaction_kind, win.CB_SETCURSEL, defaults.reaction_kind - 1, 0);
        _ = win.SendMessageW(self.reaction_count, win.CB_SETCURSEL, std.mem.indexOfScalar(u32, &reaction_counts, defaults.reaction_count) orelse 0, 0);
        _ = win.SendMessageW(self.reaction_interval, win.CB_SETCURSEL, std.mem.indexOfScalar(u32, &reaction_intervals, defaults.reaction_interval_ms) orelse 0, 0);
        self.updateIntervalHint();
    }

    pub fn loadReactionDefaults(self: Palette, defaults: storage.Preferences) void {
        self.resetReaction(defaults);
        self.settingsStatus("標準設定を読み込みました。変更は今回の実行だけに適用します。");
    }

    fn updateIntervalHint(self: Palette) void {
        const interval = win.SendMessageW(self.reaction_interval, win.CB_GETCURSEL, 0, 0);
        windows.setText(self.interval_hint, if (interval == 0)
            "前の操作が終わり次第、次を実行します。"
        else
            "指定間隔には処理時間を含みます。");
    }

    pub fn operationButtons(self: *Palette, allowed: bool, active: bool) void {
        self.operations_allowed = allowed;
        self.updateCommandButtons();
        _ = win.EnableWindow(self.stop_button, @intFromBool(active));
    }

    fn commandsAvailable(self: *const Palette) bool {
        return self.operations_allowed and !self.refreshing and !self.resetting_search and !self.items_pending;
    }

    fn updateCommandButtons(self: *Palette) void {
        _ = win.EnableWindow(self.start_button, @intFromBool(self.commandsAvailable()));
        _ = win.EnableWindow(self.save_defaults, @intFromBool(self.commandsAvailable()));
        const selected = self.commandsAvailable() and !self.refresh_failed and self.search_due == null and self.selectedIndex() != null;
        _ = win.EnableWindow(self.insert_button, @intFromBool(selected and self.commandsAvailable() and !self.refresh_failed and self.search_due == null));
    }

    fn restoreInteraction(self: *Palette, refreshing: bool) void {
        self.refreshing = refreshing;
        if (!refreshing) self.updateCommandButtons();
    }

    pub fn flushSearch(self: *Palette) void {
        if (self.search_due != null) self.refreshItems();
    }

    fn cancelSearch(self: *Palette) void {
        self.search_due = null;
        _ = win.KillTimer(self.window, search_timer);
    }

    fn queueSearch(self: *Palette) void {
        if (self.refreshing) {
            self.items_pending = true;
            return;
        }
        const profile = self.inputProfile();
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
        self.updateCommandButtons();
        _ = win.SetWindowTextW(self.search, windows.wide(""));
        if (self.selected_id) |id| allocator.free(id);
        self.selected_id = null;
    }

    pub fn selectedRow(self: *Palette) ?Row {
        if (self.refreshing or self.commandsSuspended()) return null;
        self.flushSearch();
        if (self.refresh_failed) return null;
        const index = self.selectedIndex() orelse return null;
        return self.rows[index];
    }

    fn selectedIndex(self: *const Palette) ?usize {
        if (self.saved_refresh_pending) return null;
        const revision = self.items_revision;
        const count = win.SendMessageW(self.list, win.LB_GETCOUNT, 0, 0);
        const index = win.SendMessageW(self.list, win.LB_GETCURSEL, 0, 0);
        if (self.items_pending or self.items_revision != revision or count < 0 or @as(usize, @intCast(count)) != self.count or
            index < 0 or index >= self.count) return null;
        return @intCast(index);
    }

    fn reactionCommand(self: Palette, message: win.UINT) void {
        if (!self.commandsAvailable()) return;
        const kind = win.SendMessageW(self.reaction_kind, win.CB_GETCURSEL, 0, 0);
        const count = win.SendMessageW(self.reaction_count, win.CB_GETCURSEL, 0, 0);
        const interval = win.SendMessageW(self.reaction_interval, win.CB_GETCURSEL, 0, 0);
        if (kind < 0 or kind >= 6 or count < 0 or count >= reaction_counts.len or interval < 0 or interval >= reaction_intervals.len) return;
        var choice: ReactionOptions = .{ .kind = @intCast(kind + 1), .count = reaction_counts[@intCast(count)], .interval = reaction_intervals[@intCast(interval)] };
        _ = win.SendMessageW(self.host, message, 0, @bitCast(@intFromPtr(&choice)));
    }

    pub fn refreshItems(self: *Palette) void {
        if (self.list == null or self.saved_refresh_pending) return;
        self.items_pending = true;
        if (self.items_refreshing) return;
        const refreshing = self.refreshing;
        self.refreshing = true;
        self.items_refreshing = true;
        defer {
            self.items_refreshing = false;
            self.restoreInteraction(refreshing);
        }
        if (!refreshing) self.updateCommandButtons();
        const position = self.captureListPosition();
        defer if (position.id) |id| allocator.free(id);
        while (self.items_pending and !self.saved_refresh_pending) {
            self.items_pending = false;
            self.refreshItemsPass(position);
        }
    }

    fn changeSort(self: *Palette) void {
        const selected = win.SendMessageW(self.sort_selector, win.CB_GETCURSEL, 0, 0);
        if (selected < 0 or selected >= std.meta.tags(SortOrder).len) return;
        const order: SortOrder = @enumFromInt(selected);
        if (order == self.sort_order) return;
        self.sort_order = order;
        if (self.refreshing) {
            self.items_pending = true;
        } else self.refreshItems();
    }

    fn captureListPosition(self: *const Palette) ListPosition {
        const current = win.SendMessageW(self.list, win.LB_GETTOPINDEX, 0, 0);
        if (current < 0) return .{};
        const top: usize = @intCast(current);
        const count = win.SendMessageW(self.list, win.LB_GETCOUNT, 0, 0);
        if (count < 0 or @as(usize, @intCast(count)) != self.row_ids.len) return .{};
        const id = if (top < self.row_ids.len) allocator.dupe(u8, self.row_ids[top]) catch null else null;
        return .{ .top = top, .id = id };
    }

    fn restoreListPosition(self: *Palette, position: ListPosition) void {
        const fallback = @min(position.top, self.count - 1);
        const top = if (position.id) |id| for (self.row_ids, 0..) |current, index| {
            if (std.mem.eql(u8, current, id)) break index;
        } else fallback else fallback;
        _ = win.SendMessageW(self.list, win.LB_SETTOPINDEX, top, 0);
    }

    fn refreshItemsPass(self: *Palette, position: ListPosition) void {
        self.cancelSearch();
        const raw_query = windows.text(self.search, allocator) catch return self.failItemRefresh();
        defer allocator.free(raw_query);
        if (self.items_pending) return;
        const query = std.mem.trim(u8, raw_query, " \t");
        const profile = self.inputProfile();
        const profile_name = if (profile) |value| value.name else "";
        var next: ItemRows = .{};
        const profile_truncated = if (profile) |value| next.collect(value.items, value.id, query) else false;
        const truncated = profile_truncated or next.collect(self.data.shared_items, "", query);
        if (self.sort_order != .saved) {
            const context: SortContext = .{ .order = self.sort_order, .preferences = &self.data.preferences, .profile_name = profile_name };
            std.mem.sort(Row, next.rows[0..next.count], context, SortContext.lessThan);
        }
        var row_ids_arena = std.heap.ArenaAllocator.init(allocator);
        defer row_ids_arena.deinit();
        const row_memory = row_ids_arena.allocator();
        const ids = row_memory.alloc([]const u8, next.count) catch return self.failItemRefresh();
        for (next.rows[0..next.count], ids) |row, *id|
            id.* = row_memory.dupe(u8, row.item.id) catch return self.failItemRefresh();
        _ = win.SendMessageW(self.list, win.WM_SETREDRAW, 0, 0);
        defer {
            _ = win.SendMessageW(self.list, win.WM_SETREDRAW, 1, 0);
            _ = win.InvalidateRect(self.list, null, 1);
        }
        if (self.items_pending) return;
        _ = win.SendMessageW(self.list, win.LB_RESETCONTENT, 0, 0);
        if (self.items_pending) return;
        for (next.rows[0..next.count], 0..) |row, index| {
            self.appendRow(row, profile_name, index) catch return self.failItemRefresh();
            if (self.items_pending) return;
        }
        // Keep the published identities until the corresponding native rows are complete.
        std.mem.swap(std.heap.ArenaAllocator, &self.row_ids_arena, &row_ids_arena);
        self.row_ids = ids;
        @memcpy(self.rows[0..next.count], next.rows[0..next.count]);
        self.count = next.count;
        self.items_revision +%= 1;
        self.refresh_failed = self.scope_refresh_failed;
        windows.setText(self.search_hint, if (truncated)
            "先頭500件を表示しています。検索で絞り込んでください。"
        else if (self.count > 0)
            "弾幕は入力のみです。内容を確認してYouTubeで送信します。"
        else if (query.len != 0)
            "一致する弾幕がありません。"
        else
            "弾幕を追加・編集できます。");
        if (self.items_pending) return;
        if (self.count > 0) {
            const retained = if (self.selected_id) |id| for (self.rows[0..self.count], 0..) |row, n| {
                if (std.mem.eql(u8, row.item.id, id)) break n;
            } else null else null;
            _ = win.SendMessageW(self.list, win.LB_SETCURSEL, retained orelse 0, 0);
            if (!self.items_pending and retained != null) self.restoreListPosition(position);
        }
        self.showSelection();
    }

    fn failItemRefresh(self: *Palette) void {
        if (self.items_pending) return;
        self.refresh_failed = true;
        self.count = 0;
        self.items_revision +%= 1;
        _ = win.SendMessageW(self.list, win.LB_RESETCONTENT, 0, 0);
        windows.setText(self.search_hint, "弾幕一覧を更新できませんでした。検索し直してください。");
        self.showSelection();
    }

    fn nameTextOrder(lhs: Row, rhs: Row) std.math.Order {
        const names = std.ascii.orderIgnoreCase(lhs.item.name, rhs.item.name);
        return if (names == .eq) std.ascii.orderIgnoreCase(lhs.item.text, rhs.item.text) else names;
    }

    fn keyText(row: Row, preferences: *const storage.Preferences, buffer: []u8) []const u8 {
        if (row.item.slot == 0 or row.item.slot > 2) return "";
        const first: storage.Action = if (row.profile_id.len == 0) .shared1 else .profile1;
        const key = preferences.shortcut_keys[@intFromEnum(first) + row.item.slot - 1];
        const chord = (shortcuts.parse(key) catch return key) orelse return "";
        return shortcuts.label(chord, buffer);
    }

    fn scopeText(row: Row, profile_name: []const u8) []const u8 {
        return if (row.profile_id.len == 0) "共通" else profile_name;
    }

    fn appendRow(self: *Palette, row: Row, profile_name: []const u8, index: usize) !void {
        var key_buffer: [32]u8 = undefined;
        const key = keyText(row, &self.data.preferences, &key_buffer);
        const scope = scopeText(row, profile_name);
        const text = try std.fmt.allocPrint(allocator, "{s}　{s}{s}{s}{s}", .{ scope, row.item.name, if (key.len > 0) "　[" else "", key, if (key.len > 0) "]" else "" });
        defer allocator.free(text);
        const added = appendNativeText(self.list, win.LB_ADDSTRING, text) orelse return error.RenderPaletteRow;
        if (added != index) return error.RenderPaletteRow;
    }

    fn showSelection(self: *Palette) void {
        if (self.items_pending) return;
        const selected = self.selectedIndex();
        if (self.items_pending) return;
        const item = if (selected) |index| self.rows[index].item else null;
        windows.setText(self.preview, if (item) |value| value.text else "");
        if (self.items_pending) return;
        if (self.selected_id) |id| allocator.free(id);
        self.selected_id = if (item) |value| allocator.dupe(u8, value.id) catch null else null;
    }

    fn selectionChanged(self: *Palette) void {
        if (self.refreshing) return;
        self.refreshing = true;
        self.updateCommandButtons();
        self.showSelection();
        self.restoreInteraction(false);
        if (self.items_pending) self.refreshItems();
    }

    fn insert(self: *Palette) void {
        if (!self.commandsAvailable() or self.settleSearchForAction() or self.refresh_failed) return;
        const index = self.selectedIndex() orelse return;
        if (self.commandsAvailable() and !self.refresh_failed and !self.settleSearchForAction())
            _ = win.SendMessageW(self.host, wm_insert, index, 0);
    }

    fn resize(self: *Palette) void {
        if (self.search_hint == null) return;
        self.viewport.arrange(self.window, self, placeControls);
    }

    fn placeControls(self: *Palette) void {
        const content = self.viewport.layout(self.window, self.dpi, .{ .width = minimum_width, .height = minimum_height }, .{ .below_width = compact_width, .minimum_height = compact_minimum_height }) orelse return;
        self.layout(self.dpi.fittingUnits(content.width), self.dpi.fittingUnits(content.height));
    }

    fn place(self: Palette, hwnd: win.HWND, x: i32, y: i32, width: i32, height: i32) void {
        self.viewport.place(self.dpi, hwnd, x, y, width, height);
    }

    fn layout(self: Palette, width: i32, height: i32) void {
        const padding: i32 = 12;
        const full = width - 2 * padding;
        const compact = width < compact_width;
        const extra: i32 = if (compact) 32 else 0;
        const context_row: i32 = 21;
        const registration_row: i32 = 21;
        const list_height = @max(height - 324 - extra - registration_row - context_row - sort_row - reaction_detail_rows, 28);
        const below_list = context_row + sort_row + list_height;
        self.place(self.mode, padding, 12, 112, 180);
        self.place(self.profile, 134, 12, width - 264, 242);
        self.place(self.support_button, width - 122, 11, 110, 29);
        self.place(self.input_context, padding, 43, full, 21);
        const link_width: i32 = 132;
        self.place(self.search, padding, 51 + context_row, full - link_width - 8, 27);
        self.place(self.link_button, width - padding - link_width, 51 + context_row, link_width, 27);
        self.place(self.sort_label, padding, 88 + context_row, 74, 24);
        self.place(self.sort_selector, padding + 80, 85 + context_row, 160, 160);
        self.place(self.list, padding, 85 + context_row + sort_row, full, list_height);
        self.place(self.preview, padding, 93 + below_list, full, 48);
        self.place(self.insert_button, padding, 149 + below_list, 164, 30);
        self.place(self.manage_button, padding + 173, 149 + below_list, 148, 30);
        self.place(self.reaction_heading, padding, 188 + below_list, full, 20);
        self.place(self.reaction_registration, padding, 209 + below_list, full, registration_row);
        const kind_width: i32 = if (compact) 134 else 142;
        const count_width: i32 = if (compact) 80 else 100;
        const interval_x = padding + kind_width + count_width + 16;
        const controls_top = below_list + registration_row;
        self.place(self.reaction_kind, padding, 209 + controls_top, kind_width, 210);
        self.place(self.reaction_count, padding + kind_width + 8, 209 + controls_top, count_width, 190);
        self.place(self.reaction_interval, interval_x, 209 + controls_top, @min(112, width - interval_x - padding), 235);
        self.place(self.interval_hint, padding, 239 + controls_top, full, 22);
        const buttons_top = 242 + controls_top + interval_hint_row;
        self.place(self.start_button, padding, buttons_top, 186, 27);
        self.place(self.stop_button, padding + 192, buttons_top, 58, 27);
        const defaults_x: i32 = if (compact) padding else padding + 255;
        self.place(self.save_defaults, defaults_x, buttons_top + extra, 111, 27);
        self.place(self.load_defaults, defaults_x + 117, buttons_top + extra, 135, 27);
        const notices_top = buttons_top + extra + 34;
        self.place(self.message, padding, notices_top, full, notice_row - 2);
        self.place(self.reaction_notice, padding, notices_top + notice_row, full, notice_row - 2);
        self.place(self.settings_notice, padding, notices_top + 2 * notice_row, full, notice_row - 2);
        self.place(self.search_hint, padding, notices_top + 3 * notice_row, full, 22);
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
    return appendNativeText(hwnd, message, value) != null;
}

fn appendNativeText(hwnd: win.HWND, message: win.UINT, value: []const u8) ?usize {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(allocator, value) catch return null;
    defer allocator.free(utf16);
    const index = win.SendMessageW(hwnd, message, 0, @bitCast(@intFromPtr(utf16.ptr)));
    return if (index < 0) null else @intCast(index);
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
        win.WM_SHOWWINDOW => if (wparam == 0) {
            palette.cancelSearch();
        } else {
            palette.was_presented = true;
            if (palette.saved_refresh_pending) palette.refresh(palette.data);
        },
        win.WM_SIZE => if (!palette.viewport.updating and wparam != win.SIZE_MINIMIZED) {
            const revision = palette.viewport.scroll_revision;
            palette.resize();
            if (revision == palette.viewport.scroll_revision and palette.viewport.revealFocus(hwnd)) palette.resize();
        },
        viewport.wm_reflow => if (palette.viewport.takeReflow(hwnd)) palette.resize(),
        viewport.wm_focus_changed => if (palette.viewport.revealFocus(hwnd)) palette.resize(),
        win.WM_HSCROLL, win.WM_VSCROLL => if (lparam == 0 and palette.viewport.scroll(hwnd, if (message == win.WM_HSCROLL) win.SB_HORZ else win.SB_VERT, wparam, palette.dpi)) palette.resize(),
        win.WM_TIMER => if (wparam == search_timer) palette.searchTimer(win.GetTickCount64(), win.IsWindowVisible(hwnd) != 0),
        win.WM_GETMINMAXINFO => {
            const limits: *win.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            viewport.minimumTrack(hwnd, palette.dpi, limits);
        },
        win.WM_COMMAND => {
            if (palette.commandsSuspended()) return 0;
            const id = windows.low(wparam);
            const code = windows.high(wparam);
            if (id == @intFromEnum(Id.search) and code == win.EN_CHANGE and !palette.resetting_search) palette.queueSearch();
            if (id == @intFromEnum(Id.sort) and code == win.CBN_SELCHANGE) palette.changeSort();
            if (id == @intFromEnum(Id.list) and code == win.LBN_SELCHANGE) palette.selectionChanged();
            if (id == @intFromEnum(Id.insert) and code == win.BN_CLICKED or id == @intFromEnum(Id.list) and code == win.LBN_DBLCLK) palette.insert();
            if (id == @intFromEnum(Id.stop) and code == win.BN_CLICKED) _ = win.SendMessageW(palette.host, wm_stop, 0, 0);
            if (id == @intFromEnum(Id.manage) and code == win.BN_CLICKED and !palette.refreshing and !palette.settleSearchForAction())
                _ = win.SendMessageW(palette.host, wm_manage, 0, 0);
            if (id == @intFromEnum(Id.link) and code == win.BN_CLICKED) _ = win.SendMessageW(palette.host, wm_link, 0, 0);
            if (id == @intFromEnum(Id.support) and code == win.BN_CLICKED) _ = win.SendMessageW(palette.host, wm_support, 0, 0);
            if (id == @intFromEnum(Id.auto_mode) and code == win.CBN_SELCHANGE)
                _ = win.SendMessageW(palette.host, wm_mode, @intCast(@max(0, win.SendMessageW(palette.mode, win.CB_GETCURSEL, 0, 0))), 0);
            if (id == @intFromEnum(Id.profile) and code == win.CBN_SELCHANGE and !palette.refreshing)
                _ = win.SendMessageW(palette.host, wm_profile, @bitCast(win.SendMessageW(palette.profile, win.CB_GETCURSEL, 0, 0)), 0);
            if (id == @intFromEnum(Id.reaction_interval) and code == win.CBN_SELCHANGE) palette.updateIntervalHint();
            if (id == @intFromEnum(Id.start) and code == win.BN_CLICKED) palette.reactionCommand(wm_start_reaction);
            if (id == @intFromEnum(Id.save_defaults) and code == win.BN_CLICKED) palette.reactionCommand(wm_save_defaults);
            if (id == @intFromEnum(Id.load_defaults) and code == win.BN_CLICKED)
                palette.loadReactionDefaults(palette.data.preferences);
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
    const Probe = struct {
        fn resizeClient(palette: *Palette, width: i32, height: i32) !void {
            const dpi = palette.dpi;
            var outer = win.RECT{ .left = 0, .top = 0, .right = dpi.pixels(width), .bottom = dpi.pixels(height) };
            const style: u32 = @bitCast(win.GetWindowLongW(palette.window, win.GWL_STYLE));
            const frame = style & ~@as(u32, win.WS_VSCROLL | win.WS_HSCROLL);
            const extended: u32 = @bitCast(win.GetWindowLongW(palette.window, win.GWL_EXSTYLE));
            try std.testing.expect(win.AdjustWindowRectExForDpi(&outer, frame, 0, extended, dpi.value) != 0);
            const flags = win.SWP_NOACTIVATE | win.SWP_NOZORDER | win.SWP_NOMOVE;
            try std.testing.expect(win.SetWindowPos(palette.window, null, 0, 0, outer.right - outer.left, outer.bottom - outer.top, flags) != 0);
            palette.resize();
        }

        fn boundsInClient(palette: *const Palette, child: win.HWND) !win.RECT {
            var bounds: win.RECT = undefined;
            try std.testing.expect(win.GetWindowRect(child, &bounds) != 0);
            _ = win.MapWindowPoints(null, palette.window, @ptrCast(&bounds), 2);
            return bounds;
        }
    };
    const expect = std.testing.expect;
    var palette: Palette = .{};
    defer palette.close();
    try palette.open(null);
    palette.resetReaction(.{ .reaction_interval_ms = 0 });
    const no_wait = try windows.text(palette.interval_hint, std.testing.allocator);
    defer std.testing.allocator.free(no_wait);
    try std.testing.expect(std.mem.indexOf(u8, no_wait, "前の操作") != null);
    _ = win.SendMessageW(palette.reaction_interval, win.CB_SETCURSEL, 1, 0);
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, (@as(usize, win.CBN_SELCHANGE) << 16) | @intFromEnum(Id.reaction_interval), @bitCast(@intFromPtr(palette.reaction_interval)));
    const timed = try windows.text(palette.interval_hint, std.testing.allocator);
    defer std.testing.allocator.free(timed);
    try std.testing.expect(std.mem.indexOf(u8, timed, "処理時間") != null);
    try Probe.resizeClient(&palette, minimum_width, compact_minimum_height);
    var client: win.RECT = undefined;
    try expect(win.GetClientRect(palette.window, &client) != 0);
    for ([_]win.HWND{
        palette.mode,              palette.profile,               palette.support_button, palette.input_context,
        palette.search,            palette.link_button,           palette.sort_label,     palette.sort_selector,
        palette.list,              palette.preview,               palette.insert_button,  palette.manage_button,
        palette.reaction_heading,  palette.reaction_registration, palette.reaction_kind,  palette.reaction_count,
        palette.reaction_interval, palette.interval_hint,         palette.start_button,   palette.stop_button,
        palette.save_defaults,     palette.load_defaults,         palette.message,        palette.reaction_notice,
        palette.settings_notice,   palette.search_hint,
    }) |control_window| {
        const bounds = try Probe.boundsInClient(&palette, control_window);
        try expect(bounds.left >= 0 and bounds.right <= client.right);
        try expect(bounds.top >= 0 and bounds.bottom <= client.bottom);
    }
    var list: win.RECT = undefined;
    try expect(win.GetClientRect(palette.list, &list) != 0);
    try expect(list.bottom >= win.SendMessageW(palette.list, win.LB_GETITEMHEIGHT, 0, 0));
    try Probe.resizeClient(&palette, minimum_width, 410);
    _ = win.SendMessageW(palette.window, win.WM_VSCROLL, win.SB_BOTTOM, 0);
    try expect(palette.viewport.y > 0 and win.GetClientRect(palette.window, &client) != 0);
    for ([_]win.HWND{ palette.load_defaults, palette.message, palette.reaction_notice, palette.settings_notice, palette.search_hint }) |tail| {
        const bounds = try Probe.boundsInClient(&palette, tail);
        try expect(bounds.top >= 0 and bounds.bottom <= client.bottom);
    }
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

test "palette defers hidden saves and restores the visible list position" {
    const Probe = struct {
        resets: usize = 0,
        commands: usize = 0,

        fn observe(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, context: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            const self: *@This() = @ptrFromInt(context);
            switch (message) {
                win.LB_RESETCONTENT => self.resets += 1,
                wm_insert, wm_manage, wm_profile => self.commands += 1,
                else => {},
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }
    };
    const t = std.testing;
    const host = win.CreateWindowExW(0, windows.wide("STATIC"), windows.wide(""), 0, 0, 0, 1, 1, null, null, win.GetModuleHandleW(null), null) orelse
        return error.CreatePaletteRefreshHost;
    defer _ = win.DestroyWindow(host);
    var palette: Palette = .{};
    defer palette.close();
    try palette.open(host);
    var probe: Probe = .{};
    try t.expect(win.SetWindowSubclass(host, Probe.observe, 97, @intFromPtr(&probe)) != 0);
    defer _ = win.RemoveWindowSubclass(host, Probe.observe, 97);
    try t.expect(win.SetWindowSubclass(palette.list, Probe.observe, 97, @intFromPtr(&probe)) != 0);
    defer _ = win.RemoveWindowSubclass(palette.list, Probe.observe, 97);

    var items: [60]storage.Item = undefined;
    var identifiers: [60][16]u8 = undefined;
    for (&items, &identifiers, 0..) |*item, *id, index| {
        const identity = try std.fmt.bufPrint(id, "fixture-{d}", .{index});
        item.* = .{ .id = identity, .name = identity, .text = "before", .slot = 0 };
    }
    var previous = try storage.Snapshot.clone(t.allocator, .{ .shared_items = &items });
    var previous_alive = true;
    defer if (previous_alive) previous.deinit();
    palette.refresh(previous.data);
    _ = win.ShowWindow(palette.window, win.SW_SHOWNOACTIVATE);
    _ = win.SendMessageW(palette.list, win.LB_SETCURSEL, 40, 0);
    palette.selectionChanged();
    _ = win.SendMessageW(palette.list, win.LB_SETTOPINDEX, 12, 0);
    try t.expectEqual(@as(win.LRESULT, 12), win.SendMessageW(palette.list, win.LB_GETTOPINDEX, 0, 0));

    _ = win.ShowWindow(palette.window, win.SW_HIDE);
    previous.deinit();
    previous_alive = false;
    var latest = items;
    std.mem.swap(storage.Item, &latest[12], &latest[20]);
    latest[40].text = "saved while hidden";
    palette.deferHiddenRefresh(.{ .shared_items = &latest });
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, @intFromEnum(Id.insert), @bitCast(@intFromPtr(palette.insert_button)));
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, @intFromEnum(Id.manage), @bitCast(@intFromPtr(palette.manage_button)));
    _ = win.SendMessageW(palette.window, win.WM_COMMAND, (@as(usize, win.CBN_SELCHANGE) << 16) | @intFromEnum(Id.profile), @bitCast(@intFromPtr(palette.profile)));
    try t.expectEqual(@as(usize, 0), probe.commands);
    try t.expectEqual(@as(usize, 1), probe.resets);
    try t.expect(palette.selectedRow() == null);

    palette.show();
    try t.expectEqual(@as(usize, 2), probe.resets);
    try t.expectEqualStrings("fixture-40", (palette.selectedRow() orelse return error.LostPaletteSelection).item.id);
    try t.expectEqualStrings("saved while hidden", palette.rows[40].item.text);
    try t.expectEqual(@as(win.LRESULT, 20), win.SendMessageW(palette.list, win.LB_GETTOPINDEX, 0, 0));

    latest[20].id = "replacement-id";
    palette.refresh(.{ .shared_items = &latest });
    try t.expectEqual(@as(usize, 3), probe.resets);
    try t.expectEqual(@as(win.LRESULT, 20), win.SendMessageW(palette.list, win.LB_GETTOPINDEX, 0, 0));
    try t.expectEqualStrings("fixture-40", (palette.selectedRow() orelse return error.LostPaletteSelection).item.id);
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
    items[501].name = "A";
    items[501].text = "末尾の弾幕👏";
    palette.refresh(.{ .shared_items = &items });
    try std.testing.expectEqual(@as(usize, 500), palette.count);
    _ = win.SendMessageW(palette.sort_selector, win.CB_SETCURSEL, @intFromEnum(SortOrder.name_text_asc), 0);
    palette.changeSort();
    try std.testing.expectEqual(@as(usize, 500), palette.count);
    for (palette.rows[0..palette.count]) |row| try std.testing.expect(!std.mem.eql(u8, row.item.id, "item-501"));
    windows.setText(palette.search, "末尾");
    palette.flushSearch();
    try std.testing.expectEqual(@as(usize, 1), palette.count);
    try std.testing.expectEqualStrings("item-501", palette.selectedRow().?.item.id);
    std.mem.swap(storage.Item, &items[0], &items[501]);
    windows.setText(palette.search, "");
    palette.refresh(.{ .shared_items = &items });
    try std.testing.expectEqualStrings("item-501", palette.selectedRow().?.item.id);
}

test "palette sort preserves native preview and action identities in all five orders" {
    const Probe = struct {
        palette: *Palette,
        inputs: usize = 0,
        edits: usize = 0,
        edited: ?Palette.Row = null,
        input: ?Palette.Row = null,
        switch_on_add: bool = false,
        saw_pending: bool = false,

        fn chooseOrder(palette: *Palette, order: SortOrder) void {
            _ = win.SendMessageW(palette.sort_selector, win.CB_SETCURSEL, @intFromEnum(order), 0);
            command(palette, .sort, win.CBN_SELCHANGE);
        }

        fn command(palette: *Palette, id: Id, notification: u16) void {
            _ = win.SendMessageW(palette.window, win.WM_COMMAND, @as(usize, notification) << 16 | @intFromEnum(id), 0);
        }

        fn observeList(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, userdata: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            const self: *@This() = @ptrFromInt(userdata);
            if (message == win.LB_ADDSTRING and self.switch_on_add) {
                self.switch_on_add = false;
                chooseOrder(self.palette, .key_desc);
                self.saw_pending = self.palette.items_pending and self.palette.refreshing;
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }

        fn handleHost(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
            if (message == win.WM_NCCREATE) {
                const params: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(params.lpCreateParams)));
            }
            if (message == wm_insert or message == wm_manage) {
                const self: *@This() = @ptrFromInt(@as(usize, @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))));
                if (message == wm_manage) {
                    self.edits += 1;
                    self.edited = self.palette.selectedRow();
                } else {
                    self.inputs += 1;
                    self.input = if (wparam < self.palette.count) self.palette.rows[wparam] else null;
                }
                return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        }
    };
    const t = std.testing;
    const profile = [_]storage.Item{
        .{ .id = "profile-z", .name = "Z", .text = "profile-z", .slot = 1 },
        .{ .id = "case-item", .name = "Same", .text = "same", .slot = 2 },
    };
    const shared = [_]storage.Item{
        .{ .id = "shared-a", .name = "A", .text = "shared-a", .slot = 2 },
        .{ .id = "CASE-ITEM", .name = "Same", .text = "same", .slot = 1 },
        .{ .id = "body-order", .name = "Same", .text = "first" },
    };
    const Fixture = struct { row: storage.Item, scope: []const u8, text: []const u8 };
    const fixtures = [_]Fixture{
        .{ .row = profile[0], .scope = "caster", .text = "配信者テスト　Z　[Ctrl+Alt+1]" },
        .{ .row = profile[1], .scope = "caster", .text = "配信者テスト　Same　[Ctrl+Alt+2]" },
        .{ .row = shared[0], .scope = "", .text = "共通　A　[Ctrl+Alt+4]" },
        .{ .row = shared[1], .scope = "", .text = "共通　Same　[Ctrl+Alt+3]" },
        .{ .row = shared[2], .scope = "", .text = "共通　Same" },
    };
    const data: storage.Data = .{
        .profiles = &.{.{ .id = "caster", .name = "配信者テスト", .items = &profile }},
        .shared_items = &shared,
        .preferences = .{ .auto_mode = false, .input_profile_id = "caster" },
    };
    var palette: Palette = .{};
    var probe: Probe = .{ .palette = &palette };
    var wc = std.mem.zeroes(win.WNDCLASSW);
    wc.hInstance = win.GetModuleHandleW(null);
    wc.lpszClassName = windows.wide("ChatPalette.SortTest");
    wc.lpfnWndProc = Probe.handleHost;
    try t.expect(win.RegisterClassW(&wc) != 0 or win.GetLastError() == win.ERROR_CLASS_ALREADY_EXISTS);
    const host = win.CreateWindowExW(0, wc.lpszClassName, windows.wide(""), 0, 0, 0, 1, 1, null, null, wc.hInstance, &probe) orelse
        return error.CreateSortTestHost;
    defer _ = win.DestroyWindow(host);
    defer palette.close();
    try palette.open(host);
    palette.refresh(data);
    const expected = [_][5]usize{
        .{ 0, 1, 2, 3, 4 },
        .{ 2, 4, 1, 3, 0 },
        .{ 0, 1, 3, 4, 2 },
        .{ 2, 3, 4, 0, 1 },
        .{ 2, 3, 1, 0, 4 },
    };
    for (std.meta.tags(SortOrder), expected) |order, positions| {
        const previous = palette.selectedRow().?.item.id;
        Probe.chooseOrder(&palette, order);
        try t.expectEqual(order, palette.sort_order);
        try t.expectEqualStrings(previous, palette.selectedRow().?.item.id);
        try t.expectEqual(@as(win.LRESULT, 5), win.SendMessageW(palette.list, win.LB_GETCOUNT, 0, 0));
        for (positions, 0..) |fixture_index, index| {
            const fixture = fixtures[fixture_index];
            var native: [80]u16 = undefined;
            const length = win.SendMessageW(palette.list, win.LB_GETTEXT, index, @bitCast(@intFromPtr(&native)));
            try t.expect(length > 0 and length < native.len);
            const caption = try std.unicode.utf16LeToUtf8Alloc(t.allocator, native[0..@intCast(length)]);
            defer t.allocator.free(caption);
            try t.expectEqualStrings(fixture.text, caption);
            _ = win.SendMessageW(palette.list, win.LB_SETCURSEL, index, 0);
            Probe.command(&palette, .list, win.LBN_SELCHANGE);
            const preview = try windows.text(palette.preview, t.allocator);
            defer t.allocator.free(preview);
            try t.expectEqualStrings(fixture.row.text, preview);
            Probe.command(&palette, .manage, win.BN_CLICKED);
            try t.expectEqualStrings(fixture.scope, probe.edited.?.profile_id);
            try t.expectEqualStrings(fixture.row.id, probe.edited.?.item.id);
            palette.refresh(data);
            try t.expectEqualStrings(fixture.row.id, palette.selectedRow().?.item.id);
            const before = probe.inputs;
            Probe.command(&palette, .insert, win.BN_CLICKED);
            try t.expectEqual(before + 1, probe.inputs);
            try t.expectEqualStrings(fixture.row.id, probe.input.?.item.id);
            try t.expectEqualStrings(fixture.row.text, probe.input.?.item.text);
        }
    }
    try t.expectEqual(@as(usize, 25), probe.edits);
    try t.expectEqualStrings("caster", palette.data.preferences.input_profile_id);

    try t.expect(win.SetWindowSubclass(palette.list, Probe.observeList, 74, @intFromPtr(&probe)) != 0);
    defer _ = win.RemoveWindowSubclass(palette.list, Probe.observeList, 74);
    probe.switch_on_add = true;
    Probe.chooseOrder(&palette, .name_text_asc);
    try t.expect(probe.saw_pending and !probe.switch_on_add and !palette.refresh_failed);
    try t.expectEqual(SortOrder.key_desc, palette.sort_order);
    try t.expectEqualStrings("shared-a", palette.rows[0].item.id);

    var alternate = data;
    alternate.profiles = &.{.{ .id = "caster", .name = "Alpha Caster", .items = &profile }};
    palette.refresh(alternate);
    Probe.chooseOrder(&palette, .scope_asc);
    try t.expectEqualStrings("profile-z", palette.rows[0].item.id);
    try t.expectEqualStrings("case-item", palette.rows[1].item.id);
    try t.expectEqualStrings("shared-a", palette.rows[2].item.id);
    Probe.chooseOrder(&palette, .saved);
    for (fixtures, palette.rows[0..palette.count]) |fixture, row|
        try t.expectEqualStrings(fixture.row.id, row.item.id);

    const outside = appendNativeText(palette.list, win.LB_ADDSTRING, "Unpublished fixture").?;
    for ([_]usize{ outside, 0 }) |index| {
        _ = win.SendMessageW(palette.list, win.LB_SETCURSEL, index, 0);
        Probe.command(&palette, .list, win.LBN_SELCHANGE);
        try t.expect(palette.selectedRow() == null and win.GetWindowTextLengthW(palette.preview) == 0);
        try t.expect(win.IsWindowEnabled(palette.insert_button) == 0);
        Probe.command(&palette, .insert, win.BN_CLICKED);
        try t.expectEqual(@as(usize, 25), probe.inputs);
        Probe.command(&palette, .manage, win.BN_CLICKED);
        try t.expect(probe.edited == null);
    }
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

test "palette defers reentrant search and publishes matching native text and identity" {
    const Probe = struct {
        palette: *Palette,
        trigger: usize = 0,
        appends: usize = 0,
        calls: usize = 0,
        stale_failure: bool,
        replacement: ?storage.Data = null,
        reject: bool = false,
        updating: bool = false,
        count_before: usize = 0,
        count_after: usize = 0,
        selected_during: bool = false,
        preview_unchanged: bool = false,
        inputs: usize = 0,
        edits: usize = 0,
        input_id: []const u8 = "",
        edit_id: []const u8 = "",

        fn command(palette: *Palette, id: Id, notification: u16) void {
            _ = win.SendMessageW(palette.window, win.WM_COMMAND, @as(usize, notification) << 16 | @intFromEnum(id), 0);
        }

        fn textMatches(hwnd: win.HWND, expected: []const u8) bool {
            const actual = windows.text(hwnd, std.testing.allocator) catch return false;
            defer std.testing.allocator.free(actual);
            return std.mem.eql(u8, expected, actual);
        }

        fn observeList(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, reference: win.DWORD_PTR) callconv(.winapi) win.LRESULT {
            const self: *@This() = @ptrFromInt(reference);
            if (message == win.LB_ADDSTRING) {
                if (self.reject) return win.LB_ERRSPACE;
                if (self.trigger != 0) {
                    self.appends += 1;
                    if (self.appends == self.trigger) {
                        self.trigger = 0;
                        self.calls += 1;
                        self.updating = self.palette.refreshing;
                        self.count_before = self.palette.count;
                        if (self.replacement) |data| self.palette.refresh(data);
                        windows.setText(self.palette.search, "intermediate");
                        windows.setText(self.palette.search, "latest");
                        command(self.palette, .insert, win.BN_CLICKED);
                        command(self.palette, .manage, win.BN_CLICKED);
                        command(self.palette, .list, win.LBN_SELCHANGE);
                        self.selected_during = self.palette.selectedRow() != null;
                        self.preview_unchanged = textMatches(self.palette.preview, "prior body");
                        self.count_after = self.palette.count;
                        if (self.stale_failure) return win.LB_ERRSPACE;
                    }
                }
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        }

        fn handleHost(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
            if (message == win.WM_NCCREATE) {
                const params: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(params.lpCreateParams)));
            }
            if (message == wm_insert or message == wm_manage) {
                const self: *@This() = @ptrFromInt(@as(usize, @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))));
                if (message == wm_insert) {
                    self.inputs += 1;
                    if (wparam < self.palette.count) self.input_id = self.palette.rows[wparam].item.id;
                } else {
                    self.edits += 1;
                    if (self.palette.selectedRow()) |row| self.edit_id = row.item.id;
                }
                return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        }
    };
    const expect = std.testing.expect;
    var wc = std.mem.zeroes(win.WNDCLASSW);
    wc.hInstance = win.GetModuleHandleW(null);
    wc.lpszClassName = windows.wide("ChatPalette.ReentrantSearchTest");
    wc.lpfnWndProc = Probe.handleHost;
    try expect(win.RegisterClassW(&wc) != 0 or win.GetLastError() == win.ERROR_CLASS_ALREADY_EXISTS);
    for ([_]struct { total: usize, trigger: usize, stale_failure: bool }{
        .{ .total = 4, .trigger = 1, .stale_failure = false },
        .{ .total = 504, .trigger = 500, .stale_failure = true },
    }) |sample| {
        var palette: Palette = .{};
        var probe: Probe = .{ .palette = &palette, .stale_failure = sample.stale_failure };
        const host = win.CreateWindowExW(0, wc.lpszClassName, windows.wide(""), 0, 0, 0, 1, 1, null, null, wc.hInstance, &probe) orelse
            return error.CreateReentrantSearchTestHost;
        defer _ = win.DestroyWindow(host);
        defer palette.close();
        try palette.open(host);
        try expect(win.SetWindowSubclass(palette.list, Probe.observeList, 63, @intFromPtr(&probe)) != 0);
        defer _ = win.RemoveWindowSubclass(palette.list, Probe.observeList, 63);
        var ids = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer ids.deinit();
        var items: [504]storage.Item = undefined;
        for (items[0..sample.total], 0..) |*item, index| item.* = .{
            .id = try std.fmt.allocPrint(ids.allocator(), "old-{d}", .{index}),
            .name = "earlier",
            .text = "same body",
        };
        items[0] = .{ .id = "previous-id", .name = "prior", .text = "prior body" };
        items[sample.total - 2] = .{ .id = "pending-id", .name = "intermediate", .text = "same body" };
        items[sample.total - 1] = .{ .id = "latest-id", .name = "latest", .text = "same body" };
        var replacement: [4]storage.Item = undefined;
        if (sample.total == replacement.len) {
            @memcpy(&replacement, items[0..sample.total]);
            items[sample.total - 1].id = "retired-latest-id";
            probe.replacement = .{ .shared_items = &replacement };
        }
        palette.refresh(.{ .shared_items = items[0..sample.total] });
        try std.testing.expectEqual(@min(sample.total, 500), palette.count);
        try std.testing.expectEqual(@as(win.LRESULT, @intCast(palette.count)), win.SendMessageW(palette.list, win.LB_GETCOUNT, 0, 0));
        windows.setText(palette.search, "prior");
        palette.flushSearch();
        try expect(Probe.textMatches(palette.preview, "prior body"));
        probe.trigger = sample.trigger;
        windows.setText(palette.search, "earlier");
        palette.flushSearch();
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try expect(probe.updating and !probe.selected_during and probe.preview_unchanged);
        try expect(probe.count_before == 1 and probe.count_after == 1);
        try expect(probe.inputs == 0 and probe.edits == 0);
        try expect(!palette.refresh_failed and !palette.refreshing and palette.search_due == null);
        try std.testing.expectEqual(@as(usize, 1), palette.count);
        try std.testing.expectEqual(@as(win.LRESULT, 1), win.SendMessageW(palette.list, win.LB_GETCOUNT, 0, 0));
        var label: [80]u16 = undefined;
        const length = win.SendMessageW(palette.list, win.LB_GETTEXT, 0, @bitCast(@intFromPtr(&label)));
        try expect(length > 0 and length < label.len);
        try std.testing.expectEqualSlices(u16, windows.wide("共通　latest"), label[0..@intCast(length)]);
        try std.testing.expectEqualStrings("latest-id", palette.selectedRow().?.item.id);
        try expect(Probe.textMatches(palette.preview, "same body"));
        Probe.command(&palette, .insert, win.BN_CLICKED);
        Probe.command(&palette, .manage, win.BN_CLICKED);
        try expect(probe.inputs == 1 and probe.edits == 1);
        try std.testing.expectEqualStrings("latest-id", probe.input_id);
        try std.testing.expectEqualStrings("latest-id", probe.edit_id);

        probe.reject = true;
        windows.setText(palette.search, "earlier");
        palette.flushSearch();
        try expect(palette.refresh_failed and !palette.refreshing and palette.selectedRow() == null);
        try std.testing.expectEqual(@as(win.LRESULT, 0), win.SendMessageW(palette.list, win.LB_GETCOUNT, 0, 0));
        Probe.command(&palette, .insert, win.BN_CLICKED);
        try std.testing.expectEqual(@as(usize, 1), probe.inputs);
        probe.reject = false;
        windows.setText(palette.search, "latest");
        palette.flushSearch();
        try expect(!palette.refresh_failed and win.IsWindowEnabled(palette.insert_button) != 0);
        Probe.command(&palette, .insert, win.BN_CLICKED);
        try std.testing.expectEqual(@as(usize, 2), probe.inputs);
        try std.testing.expectEqualStrings("latest-id", probe.input_id);
    }
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
