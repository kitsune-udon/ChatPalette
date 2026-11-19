const std = @import("std");
const storage = @import("../storage/store.zig");
const windows = @import("win.zig");
const shortcuts = @import("shortcuts.zig");
const viewport = @import("viewport.zig");
const Viewport = viewport.Viewport;
const win = windows.api;
const allocator = std.heap.page_allocator;
const wide = windows.wide;

/// Refresh the palette after a saved edit and return 1 if its update fails.
pub const wm_changed = win.WM_APP + 20;
pub const wm_back = win.WM_APP + 21;
pub const wm_resolve_channel = win.WM_APP + 22;
pub const wm_edit_allowed = win.WM_APP + 23;
pub const wm_support = win.WM_APP + 24;

pub fn savedViewWarning(management_failed: bool, palette_failed: bool) ?[]const u8 {
    if (management_failed and palette_failed) return "保存済みです。管理画面とパレットを更新できませんでした。両方の画面を開き直してください。";
    if (management_failed) return "保存済みです。管理画面を更新できませんでした。管理画面を開き直してください。";
    if (palette_failed) return "保存済みです。パレットを更新できませんでした。パレットを開き直してください。";
    return null;
}

pub const ChannelRequest = struct {
    allocator: std.mem.Allocator,
    author: ?[]u8 = null,
    channel: ?[]u8 = null,
    target: usize = 0,
    target_pid: u32 = 0,

    fn deinit(self: *ChannelRequest) void {
        if (self.author) |text| self.allocator.free(text);
        if (self.channel) |text| self.allocator.free(text);
    }
};

const view_class = wide("ChatPalette.Management");
const editor_class = wide("ChatPalette.LibraryEditor");

const Button = struct { id: Id, text: [:0]const u16 };
const buttons = [_]Button{
    .{ .id = .add, .text = wide("追加…") },
    .{ .id = .edit, .text = wide("編集…") },
    .{ .id = .duplicate, .text = wide("複製") },
    .{ .id = .delete, .text = wide("削除…") },
    .{ .id = .up, .text = wide("上へ") },
    .{ .id = .down, .text = wide("下へ") },
    .{ .id = .move, .text = wide("別の対象へ移動…") },
    .{ .id = .assignment, .text = wide("キーの割当…") },
};

const Id = enum(u16) {
    confirm = win.IDOK,
    cancel = win.IDCANCEL,
    name = 220,
    body,
    choice,
    scope,
    list,
    add_profile,
    profile_menu,
    add,
    edit,
    duplicate,
    delete,
    up,
    down,
    move,
    assignment,
    undo,
    support,
    back,
};

const EditorMode = enum { add_item, edit_item, move_item, add_profile, rename_profile, link_profile };

const Editor = struct {
    window: win.HWND = null,
    mode: EditorMode = .add_item,
    arena: std.heap.ArenaAllocator = undefined,
    origin: []const u8 = "",
    id: []const u8 = "",
    original_name: []const u8 = "",
    original_text: []const u8 = "",
    original_slot: u8 = 0,
    channel: []const u8 = "",
    browser_target: usize = 0,
    browser_pid: u32 = 0,
    link_profiles: []const []const u8 = &.{},
    name: win.HWND = null,
    text: win.HWND = null,
    choice: win.HWND = null,
    name_label: win.HWND = null,
    choice_label: win.HWND = null,
    body_label: win.HWND = null,
    heading: win.HWND = null,
    details: win.HWND = null,
    status: win.HWND = null,
    save: win.HWND = null,
    cancel: win.HWND = null,
    parent: win.HWND = null,
    parent_was_enabled: bool = false,
    viewport: Viewport = .{},
};

// Win32 asks for virtual item values independently of model commits. The
// published scope owns its strings even after the model releases its arena.
const PublishedList = struct {
    arena: std.heap.ArenaAllocator,
    references: usize = 1,
    scope_id: []const u8,
    rows: []const storage.Item,
    slot_labels: [2][]const u8,

    fn capture(memory: std.mem.Allocator, scope_id: []const u8, rows: []const storage.Item, labels: [2][]const u8) !*PublishedList {
        var arena = std.heap.ArenaAllocator.init(memory);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const result = try owned.create(PublishedList);
        const copies = try owned.alloc(storage.Item, rows.len);
        var bytes = scope_id.len + labels[0].len + labels[1].len;
        for (rows) |row| bytes += row.id.len + row.name.len + row.text.len;
        var strings = try owned.alloc(u8, bytes);
        const scope = copyString(&strings, scope_id);
        const owned_labels = [2][]const u8{ copyString(&strings, labels[0]), copyString(&strings, labels[1]) };
        for (rows, copies) |row, *copy| {
            copy.* = .{
                .id = copyString(&strings, row.id),
                .name = copyString(&strings, row.name),
                .text = copyString(&strings, row.text),
                .slot = row.slot,
            };
        }
        result.* = .{ .arena = arena, .scope_id = scope, .rows = copies, .slot_labels = owned_labels };
        return result;
    }

    fn copyString(remaining: *[]u8, source: []const u8) []const u8 {
        const value = remaining.*[0..source.len];
        @memcpy(value, source);
        remaining.* = remaining.*[source.len..];
        return value;
    }

    fn matches(self: *const PublishedList, scope_id: []const u8, rows: []const storage.Item, labels: [2][]const u8) bool {
        const equal = std.mem.eql;
        if (self.rows.len != rows.len or !equal(u8, self.scope_id, scope_id) or
            !equal(u8, self.slot_labels[0], labels[0]) or !equal(u8, self.slot_labels[1], labels[1])) return false;
        for (self.rows, rows) |old, new| {
            if (old.slot != new.slot or !equal(u8, old.id, new.id) or
                !equal(u8, old.name, new.name) or !equal(u8, old.text, new.text)) return false;
        }
        return true;
    }

    fn retain(self: *PublishedList) *PublishedList {
        self.references += 1;
        return self;
    }

    fn release(self: *PublishedList) void {
        self.references -= 1;
        if (self.references != 0) return;
        const arena = self.arena;
        arena.deinit();
    }

    fn slotLabel(self: *const PublishedList, slot: u8) []const u8 {
        return if (slot > 0 and slot <= self.slot_labels.len) self.slot_labels[slot - 1] else "";
    }
};

pub const Management = struct {
    window: win.HWND = null,
    dpi: windows.Dpi = .{},
    font: windows.GuiFont = .{},
    host: win.HWND = null,
    db: *storage.Store = undefined,
    snapshot: *storage.Snapshot = undefined,
    history: *storage.LibraryHistory = undefined,
    editing: ?[]u8 = null,
    selection: ?[]u8 = null,
    published_list: ?*PublishedList = null,
    list_update_failed: bool = false,
    scope_update_failed: bool = false,
    refreshing: bool = false,
    refresh_pending: bool = false,
    viewport: Viewport = .{},
    opening_editor: bool = false,
    saving_editor: bool = false,
    confirming: bool = false,
    scope: win.HWND = null,
    scope_choices: @import("profile_choices.zig") = .{},
    profile_add: win.HWND = null,
    profile_menu: win.HWND = null,
    list: win.HWND = null,
    manual: win.HWND = null,
    channel: win.HWND = null,
    undo_button: win.HWND = null,
    support: win.HWND = null,
    back: win.HWND = null,
    notice: win.HWND = null,
    item_buttons: [buttons.len]win.HWND = @splat(null),
    dialog: Editor = .{},
    editor_generation: u64 = 0,

    pub fn open(self: *Management, host: win.HWND, db: *storage.Store, snapshot: *storage.Snapshot, history: *storage.LibraryHistory) !void {
        self.host = host;
        self.dpi = windows.Dpi.system();
        self.db = db;
        self.snapshot = snapshot;
        self.history = history;
        var controls = win.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(win.INITCOMMONCONTROLSEX), .dwICC = win.ICC_LISTVIEW_CLASSES };
        if (win.InitCommonControlsEx(&controls) == 0) return error.ManagementControls;
        try register(view_class, viewProcedure);
        try register(editor_class, editorProcedure);
        const style = win.WS_OVERLAPPEDWINDOW | win.WS_CLIPCHILDREN;
        self.window = win.CreateWindowExW(win.WS_EX_CONTROLPARENT, view_class, wide("ChatPalette — 弾幕・配信者"), style, win.CW_USEDEFAULT, win.CW_USEDEFAULT, self.dpi.pixels(760), self.dpi.pixels(620), null, null, win.GetModuleHandleW(null), self) orelse return error.CreateManagementWindow;
        errdefer self.close();
        self.font = try windows.GuiFont.init(self.dpi);
        self.manual = try control(self.window, "STATIC", "編集する配信者", 0, null);
        self.scope = try control(self.window, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP | win.WS_VSCROLL, .scope);
        self.profile_add = try control(self.window, "BUTTON", "配信者を追加…", win.WS_TABSTOP, .add_profile);
        self.profile_menu = try control(self.window, "BUTTON", "配信者の設定…", win.WS_TABSTOP, .profile_menu);
        self.channel = try control(self.window, "STATIC", "", 0, null);
        self.list = try control(self.window, "SysListView32", "", win.WS_TABSTOP | win.WS_BORDER | win.LVS_REPORT | win.LVS_SINGLESEL | win.LVS_OWNERDATA | win.LVS_NOSORTHEADER | win.LVS_SHOWSELALWAYS, .list);
        _ = win.SendMessageW(self.list, win.CCM_SETUNICODEFORMAT, 1, 0);
        _ = win.SendMessageW(self.list, win.LVM_SETEXTENDEDLISTVIEWSTYLE, 0, win.LVS_EX_FULLROWSELECT | win.LVS_EX_DOUBLEBUFFER);
        for ([_][:0]const u16{ wide("弾幕名"), wide("本文"), wide("キー") }, 0..) |title, column| {
            var info = std.mem.zeroes(win.LVCOLUMNW);
            info.mask = win.LVCF_TEXT | win.LVCF_WIDTH;
            info.pszText = @constCast(title.ptr);
            info.cx = 100;
            if (win.SendMessageW(self.list, win.LVM_INSERTCOLUMNW, column, pointerParam(&info)) < 0) return error.ManagementColumns;
        }
        for (buttons, &self.item_buttons) |button, *hwnd| {
            hwnd.* = try controlText(self.window, wide("BUTTON"), button.text, win.WS_TABSTOP, button.id);
        }
        self.undo_button = try control(self.window, "BUTTON", "直前の変更を元に戻す", win.WS_TABSTOP, .undo);
        self.support = try control(self.window, "BUTTON", "操作・サポート…", win.WS_TABSTOP, .support);
        self.back = try control(self.window, "BUTTON", "パレットへ戻る", win.WS_TABSTOP, .back);
        self.notice = try control(self.window, "STATIC", "", 0, null);
        self.font.applyChildren(self.window);
        self.resize();
        self.refresh();
    }

    pub fn close(self: *Management) void {
        self.closeDialog();
        if (self.window != null) _ = win.DestroyWindow(self.window);
        self.scope_choices.clear();
        if (self.published_list) |previous| previous.release();
        self.font.deinit();
        self.resetSelection();
        self.* = .{};
    }

    pub fn resetSelection(self: *Management) void {
        if (self.editing) |id| allocator.free(id);
        if (self.selection) |id| allocator.free(id);
        self.editing = null;
        self.selection = null;
    }

    pub fn show(self: *Management) void {
        if (self.window == null) return;
        if (self.raiseEditor()) return;
        self.refresh();
        if (win.IsIconic(self.window) != 0) _ = win.ShowWindow(self.window, win.SW_RESTORE);
        if (win.IsZoomed(self.window) == 0) windows.fitWindow(self.window, null);
        _ = win.ShowWindow(self.window, if (win.IsZoomed(self.window) != 0) win.SW_SHOW else win.SW_SHOWNORMAL);
        _ = win.SetForegroundWindow(self.window);
        _ = win.SetFocus(self.list);
        if (self.viewport.revealFocus(self.window)) self.resize();
    }

    pub fn selectForEditing(self: *Management, profile_id: []const u8, item_id: []const u8) !void {
        _ = try self.snapshot.data.itemsFor(profile_id);
        try setIdentity(&self.editing, profile_id);
        try setIdentity(&self.selection, item_id);
    }

    pub fn isEditing(self: *const Management) bool {
        return self.dialog.window != null or self.opening_editor or self.confirming;
    }

    pub fn filterMessage(self: *Management, message: *win.MSG) bool {
        const target = if (self.dialog.window != null) self.dialog.window else self.window;
        if (target == null or win.IsWindowVisible(target) == 0 or
            (message.hwnd != target and win.IsChild(target, message.hwnd) == 0)) return false;
        // Dialog navigation leaves ListView arrows and incremental search to the control.
        const tab = message.message == win.WM_KEYDOWN and message.wParam == win.VK_TAB;
        if (win.IsDialogMessageW(target, message) == 0) return false;
        if (tab) {
            if (target == self.window) {
                if (self.viewport.revealFocus(target)) self.resize();
            } else if (self.dialog.viewport.revealFocus(target)) self.resizeEditor();
        }
        return true;
    }

    fn raiseEditor(self: Management) bool {
        if (self.dialog.window == null) return false;
        _ = win.ShowWindow(self.dialog.window, win.SW_SHOWNORMAL);
        _ = win.SetForegroundWindow(self.dialog.window);
        return true;
    }

    fn editAllowed(self: Management) bool {
        return win.SendMessageW(self.host, wm_edit_allowed, 0, 0) == 1;
    }

    fn editingId(self: Management) []const u8 {
        return self.editing orelse "";
    }

    fn items(self: Management) []const storage.Item {
        return if (self.published_list) |content| content.rows else &.{};
    }

    fn selectedIndex(self: Management) ?usize {
        const selected = win.SendMessageW(self.list, win.LVM_GETNEXTITEM, std.math.maxInt(usize), win.LVNI_SELECTED);
        if (selected < 0 or selected >= self.items().len) return null;
        return @intCast(selected);
    }

    fn setIdentity(existing: *?[]u8, value: []const u8) !void {
        const copy = if (value.len == 0) null else try allocator.dupe(u8, value);
        if (existing.*) |old| allocator.free(old);
        existing.* = copy;
    }

    pub fn refresh(self: *Management) void {
        if (self.list == null) return;
        self.refresh_pending = true;
        if (self.refreshing) return;
        self.refreshing = true;
        defer {
            self.refreshing = false;
            self.updateActions();
        }
        while (self.refresh_pending) {
            self.refresh_pending = false;
            self.refreshView();
        }
    }

    fn refreshView(self: *Management) void {
        const current = self.editingId();
        const data = self.snapshot.data;
        var choice: usize = 0;
        for (data.profiles, 1..) |profile, i| {
            if (std.mem.eql(u8, current, profile.id)) {
                choice = i;
                break;
            }
        }
        if (current.len != 0 and choice == 0) {
            setIdentity(&self.editing, "") catch {};
            setIdentity(&self.selection, "") catch {};
        }
        var text: []const u8 = "共通の弾幕はすべてのチャンネルで使えます。";
        if (choice != 0) {
            const profile = data.profiles[choice - 1];
            text = if (profile.channel.len == 0) "チャンネル未連携" else profile.channel;
        }
        windows.setText(self.channel, text);
        const scope_was_failed = self.scope_update_failed;
        self.scope_update_failed = false;
        self.scope_choices.clear();
        fillScopes(self.scope, data.profiles, "共通の弾幕") catch {
            self.scope_update_failed = true;
        };
        if (!self.scope_update_failed) self.scope_choices.publish(data.profiles) catch {
            self.scope_update_failed = true;
        };
        _ = win.EnableWindow(self.scope, @intFromBool(!self.scope_update_failed));
        if (!self.scope_update_failed) choose(self.scope, choice);
        self.refreshList();
        if (self.scope_update_failed) {
            windows.setText(self.notice, "配信者一覧を更新できませんでした。管理画面を開き直してください。");
        } else if (scope_was_failed and !self.list_update_failed) {
            windows.setText(self.notice, "");
        }
    }

    pub fn refreshFailed(self: *const Management) bool {
        return self.scope_update_failed or self.list_update_failed;
    }

    fn refreshList(self: *Management) void {
        if (self.list == null) return;
        self.publishList() catch {
            self.list_update_failed = true;
            windows.setText(self.notice, "管理一覧を更新できませんでした。管理画面を開き直してください。");
            return;
        };
        if (self.list_update_failed) windows.setText(self.notice, "");
        self.list_update_failed = false;
    }

    fn publishList(self: *Management) !void {
        const scope = self.editingId();
        const data = self.snapshot.data;
        const source = try data.itemsFor(scope);
        var key_buffers: [2][48]u8 = undefined;
        const labels = [2][]const u8{
            slotText(&key_buffers[0], data.preferences, scope.len != 0, 1),
            slotText(&key_buffers[1], data.preferences, scope.len != 0, 2),
        };
        const previous = self.published_list;
        const replacement = if (previous == null or !previous.?.matches(scope, source, labels))
            try PublishedList.capture(allocator, scope, source, labels)
        else
            null;
        errdefer if (replacement) |content| content.release();

        _ = win.SendMessageW(self.list, win.WM_SETREDRAW, 0, 0);
        defer {
            _ = win.SendMessageW(self.list, win.WM_SETREDRAW, 1, 0);
            _ = win.InvalidateRect(self.list, null, 1);
        }
        // Count changes can call back into the ListView owner. Give that call
        // one complete generation and keep the preceding owner on refusal.
        if (replacement) |content| self.published_list = content;
        const rows = self.items();
        if (win.SendMessageW(self.list, win.LVM_SETITEMCOUNT, rows.len, win.LVSICF_NOINVALIDATEALL | win.LVSICF_NOSCROLL) == 0) {
            self.published_list = previous;
            return error.UpdateManagementListCount;
        }
        if (replacement != null) {
            if (previous) |content| content.release();
        }
        var state = std.mem.zeroes(win.LVITEMW);
        state.stateMask = win.LVIS_SELECTED | win.LVIS_FOCUSED;
        _ = win.SendMessageW(self.list, win.LVM_SETITEMSTATE, std.math.maxInt(usize), pointerParam(&state));
        const previous_selection = self.selection orelse return;
        if (rows.len == 0) return setIdentity(&self.selection, "") catch {};
        const retained: ?usize = for (rows, 0..) |item, index| {
            if (std.mem.eql(u8, item.id, previous_selection)) break index;
        } else null;
        // An explicitly cleared selection stays empty. A row that disappeared
        // on refresh falls back to the first row of the current nonempty scope.
        if (retained == null) setIdentity(&self.selection, rows[0].id) catch {
            setIdentity(&self.selection, "") catch {};
            return;
        };
        const index = retained orelse 0;
        state.state = state.stateMask;
        _ = win.SendMessageW(self.list, win.LVM_SETITEMSTATE, index, pointerParam(&state));
        _ = win.SendMessageW(self.list, win.LVM_ENSUREVISIBLE, index, 0);
    }

    pub fn updateActions(self: *Management) void {
        if (self.list == null or self.refreshing) return;
        const permission = self.editAllowed() and !self.isEditing() and !self.refreshFailed();
        const selected = self.selectedIndex();
        const count = self.items().len;
        for (buttons, self.item_buttons) |button, hwnd| {
            const enabled = permission and switch (button.id) {
                .add => true,
                .up => selected != null and selected.? > 0,
                .down => selected != null and selected.? + 1 < count,
                .move => selected != null and (self.editingId().len != 0 or self.snapshot.data.profiles.len != 0),
                else => selected != null,
            };
            _ = win.EnableWindow(hwnd, @intFromBool(enabled));
        }
        _ = win.EnableWindow(self.undo_button, @intFromBool(permission and self.history.length != 0));
        _ = win.EnableWindow(self.profile_add, @intFromBool(permission));
        _ = win.EnableWindow(self.profile_menu, @intFromBool(permission));
    }

    fn selectScope(self: *Management) !void {
        const i = currentChoice(self.scope) orelse return error.ProfileMissing;
        const id = self.scope_choices.resolve(self.snapshot.data, i) orelse return error.ProfileMissing;
        try setIdentity(&self.editing, id);
        try setIdentity(&self.selection, "");
        const current_channel = if (self.snapshot.data.findProfile(self.editingId())) |profile|
            (if (profile.channel.len == 0) "チャンネル未連携" else profile.channel)
        else
            "共通の弾幕はすべてのチャンネルで使えます。";
        self.refreshing = true;
        windows.setText(self.channel, current_channel);
        self.refreshList();
        self.refreshing = false;
        if (self.refresh_pending) self.refresh() else self.updateActions();
    }

    fn hide(self: *Management) void {
        if (!self.isEditing()) _ = win.ShowWindow(self.window, win.SW_HIDE);
    }

    fn hideAndReturn(self: *Management) void {
        if (self.raiseEditor() or self.isEditing()) return;
        self.hide();
        _ = win.SendMessageW(self.host, wm_back, 0, 0);
    }

    fn changed(self: *Management, new_selection: ?[]const u8) void {
        self.changedWithNotice(new_selection, "保存しました。");
    }

    fn changedWithNotice(self: *Management, new_selection: ?[]const u8, success: []const u8) void {
        setIdentity(&self.selection, new_selection orelse "") catch {};
        self.refresh();
        const palette_failed = win.SendMessageW(self.host, wm_changed, 0, 0) != 0;
        windows.setText(self.notice, savedViewWarning(self.refreshFailed(), palette_failed) orelse success);
    }

    fn showError(self: Management, err: anyerror) void {
        const label = if (self.dialog.window != null) self.dialog.status else self.notice;
        if (err == error.ChannelMissing) {
            const key = self.snapshot.data.preferences.shortcut_keys[@intFromEnum(shortcuts.Action.palette)];
            const chord = shortcuts.parse(key) catch null;
            var key_buffer: [30]u8 = undefined;
            var message: [240]u8 = undefined;
            const details = std.fmt.bufPrint(&message, "YouTubeを前面にし、{s} でパレットを開いて連携してください。", .{shortcuts.label(chord, &key_buffer)}) catch unreachable;
            windows.setText(label, details);
            return;
        }
        const failure = self.db.failureCodes();
        if (failure.rollback) |rollback| {
            var buffer: [256]u8 = undefined;
            const details = if (failure.close) |close_code|
                std.fmt.bufPrint(&buffer, "保存失敗 ({d})。ロールバック ({d})、接続終了 ({d}) に失敗しました。再起動してください。", .{ failure.original, rollback, close_code })
            else
                std.fmt.bufPrint(&buffer, "保存失敗 ({d})。ロールバック ({d}) に失敗しました。再起動してください。", .{ failure.original, rollback });
            if (details) |status| {
                windows.setText(label, status);
                return;
            } else |_| {}
        }
        windows.setText(label, switch (err) {
            error.InvalidText => "名前と1行の本文を入力してください。",
            error.DuplicateChannel => "このチャンネルはすでに別の配信者に連携されています。",
            error.DatabaseChanged => "設定が別の接続で変更されました。再起動して読み直してください。",
            error.DatabaseFull => "保存できませんでした。設定サイズまたは空き容量を確認してください。",
            error.ItemMissing, error.ProfileMissing => "対象が見つかりません。選び直してください。",
            error.ChannelChanged => "チャンネルが変わりました。画面を閉じてもう一度開いてください。",
            error.SameProfile => "別の移動先を選んでください。",
            else => "変更を保存できませんでした。",
        });
    }

    fn command(self: *Management, id: u16, notification: u16) !void {
        if (id == @intFromEnum(Id.scope) and notification == win.CBN_SELCHANGE) {
            if (!self.isEditing() and self.editAllowed() and !self.scope_update_failed) {
                self.selectScope() catch |failure| {
                    self.refresh();
                    return failure;
                };
            } else self.refresh();
            return;
        }
        if (notification != win.BN_CLICKED) return;
        if (id == @intFromEnum(Id.cancel)) {
            self.hide();
            return;
        }
        if (id == @intFromEnum(Id.back)) {
            self.hideAndReturn();
            return;
        }
        if (id == @intFromEnum(Id.support)) {
            if (!self.raiseEditor()) _ = win.SendMessageW(self.host, wm_support, 0, 0);
            return;
        }
        if (self.opening_editor or self.confirming or self.raiseEditor() or !self.editAllowed() or self.refreshFailed() or self.refreshing) return;
        const selected = self.selectedIndex();
        const row: ?storage.Item = if (selected) |i| self.items()[i] else null;
        switch (id) {
            @intFromEnum(Id.add) => try self.openDialog(.add_item, null),
            @intFromEnum(Id.edit) => if (row) |item| try self.openDialog(.edit_item, item),
            @intFromEnum(Id.move) => if (row) |item| try self.openDialog(.move_item, item),
            @intFromEnum(Id.duplicate) => if (row) |item| try self.runItemCommand(.{ .duplicate = item.id }),
            @intFromEnum(Id.up) => if (row) |item| try self.runItemCommand(.{ .up = item.id }),
            @intFromEnum(Id.down) => if (row) |item| try self.runItemCommand(.{ .down = item.id }),
            @intFromEnum(Id.delete) => if (row) |item| {
                const id_copy = try allocator.dupe(u8, item.id);
                defer allocator.free(id_copy);
                if (self.confirm(self.window, "選んだ弾幕を削除します。元に戻すことができます。", "弾幕を削除") and self.editAllowed())
                    try self.runItemCommand(.{ .delete = id_copy });
            },
            @intFromEnum(Id.assignment) => if (row) |item| try self.assignmentMenu(item),
            @intFromEnum(Id.add_profile) => try self.openDialog(.add_profile, null),
            @intFromEnum(Id.profile_menu) => try self.profileMenu(),
            @intFromEnum(Id.undo) => {
                const previous = try allocator.dupe(u8, self.selection orelse "");
                defer allocator.free(previous);
                if (try self.history.undo(self.db, self.snapshot)) self.changed(previous);
            },
            else => {},
        }
    }

    fn runItemCommand(self: *Management, value: storage.ItemCommand) !void {
        const selected = try self.history.item(self.db, self.snapshot, self.editingId(), value);
        if (selected == null and (value == .up or value == .down)) return;
        self.changedWithNotice(selected, if (value == .delete) "削除しました。" else "保存しました。");
    }

    fn profileMenu(self: *Management) !void {
        const menu = win.CreatePopupMenu() orelse return error.ManagementMenu;
        defer _ = win.DestroyMenu(menu);
        const enabled: u32 = if (self.editingId().len != 0) win.MF_STRING else win.MF_STRING | win.MF_GRAYED;
        _ = win.AppendMenuW(menu, enabled, 1, wide("名前を変更…"));
        _ = win.AppendMenuW(menu, win.MF_STRING, 2, wide("現在のチャンネルと連携…"));
        _ = win.AppendMenuW(menu, enabled, 3, wide("チャンネル連携を解除"));
        _ = win.AppendMenuW(menu, enabled, 4, wide("配信者と弾幕を削除…"));
        switch (popup(self.window, self.profile_menu, menu)) {
            1 => try self.openDialog(.rename_profile, null),
            2 => try self.openDialog(.link_profile, null),
            3 => {
                _ = try self.history.profile(self.db, self.snapshot, .{ .unbind = self.editingId() });
                self.changed(null);
            },
            4 => if (self.confirm(self.window, "この配信者と配信者別の弾幕を削除します。元に戻すことができます。", "配信者を削除") and self.editAllowed()) {
                _ = try self.history.profile(self.db, self.snapshot, .{ .delete = self.editingId() });
                self.changed(null);
            },
            else => {},
        }
    }

    pub fn linkFromPalette(self: *Management) void {
        self.openDialogAt(.link_profile, null, "") catch |failure| self.showError(failure);
    }

    fn assignmentMenu(self: *Management, item: storage.Item) !void {
        const selected = try allocator.dupe(u8, item.id);
        defer allocator.free(selected);
        const menu = win.CreatePopupMenu() orelse return error.ManagementMenu;
        defer _ = win.DestroyMenu(menu);
        _ = win.AppendMenuW(menu, win.MF_STRING, 1, wide("弾幕キー 1 に割当"));
        _ = win.AppendMenuW(menu, win.MF_STRING, 2, wide("弾幕キー 2 に割当"));
        _ = win.AppendMenuW(menu, win.MF_STRING, 3, wide("この弾幕の割当を解除"));
        const choice = popup(self.window, self.item_buttons[7], menu);
        if (choice == 0 or !self.editAllowed()) return;
        var ids: [2][]const u8 = .{ "", "" };
        for (self.items()) |row| {
            if (row.slot != 0 and !std.mem.eql(u8, row.id, selected)) ids[row.slot - 1] = row.id;
        }
        if (choice <= 2) ids[choice - 1] = selected;
        if (try self.history.assign(self.db, self.snapshot, self.editingId(), ids[0], ids[1])) self.changed(selected);
    }

    fn resolveChannel(self: Management, on: std.mem.Allocator) !ChannelRequest {
        var request = ChannelRequest{ .allocator = on };
        errdefer request.deinit();
        _ = win.SendMessageW(self.host, wm_resolve_channel, 0, pointerParam(&request));
        if (request.channel == null or request.channel.?.len == 0 or request.target == 0 or request.target_pid == 0) return error.ChannelMissing;
        return request;
    }

    fn openDialog(self: *Management, mode: EditorMode, initial: ?storage.Item) !void {
        try self.openDialogAt(mode, initial, self.editingId());
    }

    fn openDialogAt(self: *Management, mode: EditorMode, initial: ?storage.Item, origin: []const u8) !void {
        if (self.opening_editor or self.raiseEditor()) return;
        self.opening_editor = true;
        defer {
            self.opening_editor = false;
            if (mode == .link_profile) self.updateActions();
        }
        var dialog: Editor = .{ .mode = mode, .arena = std.heap.ArenaAllocator.init(allocator) };
        defer dialog.arena.deinit();
        const owned = dialog.arena.allocator();
        dialog.origin = try owned.dupe(u8, origin);
        if (initial) |item| {
            dialog.id = try owned.dupe(u8, item.id);
            dialog.original_name = try owned.dupe(u8, item.name);
            dialog.original_text = try owned.dupe(u8, item.text);
            dialog.original_slot = item.slot;
        }
        if (mode == .rename_profile) {
            const profile = self.snapshot.data.findProfile(dialog.origin) orelse return error.ProfileMissing;
            dialog.original_name = try owned.dupe(u8, profile.name);
        } else if (mode == .link_profile) {
            var candidate = try self.resolveChannel(allocator);
            defer candidate.deinit();
            if (!self.editAllowed()) return;
            if (dialog.origin.len != 0 and self.snapshot.data.findProfile(dialog.origin) == null) return error.ProfileMissing;
            dialog.channel = try owned.dupe(u8, candidate.channel.?);
            const author = candidate.author orelse "";
            dialog.original_name = try owned.dupe(u8, if (author.len != 0) author else candidate.channel.?);
            dialog.browser_target = candidate.target;
            dialog.browser_pid = candidate.target_pid;
        }
        const title: [:0]const u16 = switch (mode) {
            .add_item => wide("弾幕を追加"),
            .edit_item => wide("弾幕を編集"),
            .move_item => wide("弾幕の移動先"),
            .add_profile => wide("配信者を追加"),
            .rename_profile => wide("配信者名を変更"),
            .link_profile => wide("このチャンネルと連携"),
        };
        const styles = win.WS_OVERLAPPED | win.WS_CAPTION | win.WS_SYSMENU | win.WS_CLIPCHILDREN;
        const ex_style = win.WS_EX_DLGMODALFRAME | win.WS_EX_CONTROLPARENT;
        const height: i32 = switch (mode) {
            .add_item, .edit_item => 350,
            .link_profile => 386,
            else => 268,
        };
        dialog.parent = self.window;
        dialog.window = win.CreateWindowExW(ex_style, editor_class, title, styles, win.CW_USEDEFAULT, win.CW_USEDEFAULT, self.dpi.pixels(500), self.dpi.pixels(height), dialog.parent, null, win.GetModuleHandleW(null), self) orelse return error.CreateEditorWindow;
        self.dialog = dialog;
        self.editor_generation +%= 1;
        const generation = self.editor_generation;
        const editor_window = dialog.window;
        // The local arena no longer owns the content after publishing the editor.
        dialog.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer if (self.editor_generation == generation and self.dialog.window == editor_window) self.closeDialog();
        try self.editorControls();
        self.font.applyChildren(self.dialog.window);
        windows.fitWindow(self.dialog.window, self.dialog.parent);
        self.resizeEditor();
        if (self.editor_generation != generation or self.dialog.window != editor_window) return;
        self.dialog.parent_was_enabled = win.IsWindowEnabled(self.dialog.parent) != 0;
        if (self.dialog.parent_was_enabled) _ = win.EnableWindow(self.dialog.parent, 0);
        if (self.editor_generation != generation or self.dialog.window != editor_window) return;
        _ = win.ShowWindow(editor_window, win.SW_SHOWNORMAL);
        if (self.editor_generation != generation or self.dialog.window != editor_window) return;
        if (win.IsWindowVisible(editor_window) == 0) return error.ShowEditorWindow;
        _ = win.SetForegroundWindow(editor_window);
        if (self.editor_generation != generation or self.dialog.window != editor_window) return;
        _ = win.SetFocus(switch (mode) {
            .move_item, .link_profile => self.dialog.choice,
            else => self.dialog.name,
        });
    }

    fn editorControls(self: *Management) !void {
        const editor = &self.dialog;
        const parent = editor.window;
        editor.heading = try control(parent, "STATIC", "", 0, null);
        const profile = self.snapshot.data.findProfile(editor.origin);
        const label = if (profile) |target| target.name else "共通の弾幕";
        const heading = switch (editor.mode) {
            .add_item, .edit_item => label,
            .move_item => editor.original_name,
            .link_profile => try std.fmt.allocPrint(editor.arena.allocator(), "YouTubeのチャンネル：{s}", .{editor.original_name}),
            else => "アプリ内で表示する配信者名を設定します。",
        };
        windows.setText(editor.heading, heading);
        switch (editor.mode) {
            .add_item, .edit_item => {
                editor.name_label = try control(parent, "STATIC", "弾幕名", 0, null);
                editor.name = try control(parent, "EDIT", "", win.WS_TABSTOP | win.WS_BORDER | win.ES_AUTOHSCROLL, .name);
                editor.body_label = try control(parent, "STATIC", "本文（1行）", 0, null);
                editor.text = try control(parent, "EDIT", "", win.WS_TABSTOP | win.WS_BORDER | win.ES_AUTOHSCROLL, .body);
                editor.choice_label = try control(parent, "STATIC", "キーの割当", 0, null);
                editor.choice = try control(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP, .choice);
                try addChoice(editor.choice, "割当なし");
                const prefs = self.snapshot.data.preferences;
                for (0..2) |i| {
                    const first: storage.Action = if (editor.origin.len == 0) .shared1 else .profile1;
                    const key = prefs.shortcut_keys[@intFromEnum(first) + i];
                    var current: []const u8 = "未割当";
                    for (self.items()) |item| {
                        if (item.slot == i + 1) current = item.name;
                    }
                    const choice = try std.fmt.allocPrint(editor.arena.allocator(), "{d}  {s} — {s}", .{ i + 1, key, current });
                    try addChoice(editor.choice, choice);
                }
                choose(editor.choice, editor.original_slot);
            },
            .move_item => {
                editor.choice_label = try control(parent, "STATIC", "移動先を選んでください。移動するとキー割当を解除します。", 0, null);
                editor.choice = try control(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP, .choice);
                try fillScopes(editor.choice, self.snapshot.data.profiles, "共通の弾幕");
                choose(editor.choice, if (editor.origin.len == 0) 1 else 0);
            },
            .add_profile, .rename_profile => {
                editor.name_label = try control(parent, "STATIC", "配信者名", 0, null);
                editor.name = try control(parent, "EDIT", "", win.WS_TABSTOP | win.WS_BORDER | win.ES_AUTOHSCROLL, .name);
            },
            .link_profile => {
                editor.choice_label = try control(parent, "STATIC", "このチャンネルで自動選択する配信者", 0, null);
                editor.choice = try control(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_TABSTOP, .choice);
                try fillScopes(editor.choice, self.snapshot.data.profiles, "新しい配信者を登録");
                const owned = editor.arena.allocator();
                const link_profiles = try owned.alloc([]const u8, self.snapshot.data.profiles.len + 1);
                link_profiles[0] = "";
                var selected: usize = 0;
                for (self.snapshot.data.profiles, 1..) |candidate, i| {
                    link_profiles[i] = try owned.dupe(u8, candidate.id);
                    const equal = std.mem.eql;
                    if (equal(u8, candidate.id, editor.origin) or
                        (editor.origin.len == 0 and equal(u8, candidate.channel, editor.channel))) selected = i;
                }
                editor.link_profiles = link_profiles;
                choose(editor.choice, selected);
                editor.name_label = try control(parent, "STATIC", "アプリ内で表示する名前", 0, null);
                editor.name = try control(parent, "EDIT", "", win.WS_TABSTOP | win.WS_BORDER | win.ES_AUTOHSCROLL, .name);
                editor.details = try control(parent, "STATIC", "", win.SS_NOPREFIX, null);
            },
        }
        if (editor.name != null) {
            _ = win.SendMessageW(editor.name, win.EM_LIMITTEXT, 16 * 1024 * 1024, 0);
            windows.setText(editor.name, editor.original_name);
        }
        if (editor.text != null) {
            _ = win.SendMessageW(editor.text, win.EM_LIMITTEXT, 16 * 1024 * 1024, 0);
            windows.setText(editor.text, editor.original_text);
        }
        editor.status = try control(parent, "STATIC", "", 0, null);
        editor.save = try controlText(parent, wide("BUTTON"), if (editor.mode == .link_profile) wide("連携する") else wide("保存"), win.BS_DEFPUSHBUTTON | win.WS_TABSTOP, .confirm);
        editor.cancel = try control(parent, "BUTTON", "キャンセル", win.WS_TABSTOP, .cancel);
        self.updateEditorChoice();
    }

    fn updateEditorChoice(self: *Management) void {
        const mode = self.dialog.mode;
        const selected = if (self.dialog.choice != null) currentChoice(self.dialog.choice) else null;
        if (mode == .link_profile) {
            const enable = @intFromBool(selected != null and selected.? == 0);
            _ = win.EnableWindow(self.dialog.name, enable);
            _ = win.EnableWindow(self.dialog.name_label, enable);
            const index = selected orelse return;
            if (index >= self.dialog.link_profiles.len) return;
            const profile = self.snapshot.data.findProfile(self.dialog.link_profiles[index]);
            const prior = if (profile) |value| value.channel else "";
            var details: [640]u8 = undefined;
            const summary = std.fmt.bufPrint(&details, "{s}\r\n現在：{s}\r\n変更後：{s}\r\n{s}", .{
                if (index == 0) "新しい配信者を登録します。" else "選んだ配信者の連携を設定します。",
                if (prior.len == 0) "未連携" else prior,
                self.dialog.channel,
                if (prior.len != 0 and !std.mem.eql(u8, prior, self.dialog.channel))
                    "以前のチャンネルでは自動選択されなくなります。"
                else
                    "このチャンネルで弾幕を自動選択します。",
            }) catch "このチャンネルで弾幕を自動選択します。";
            windows.setText(self.dialog.details, summary);
        } else if (mode == .add_item or mode == .edit_item) {
            if (selected) |slot| {
                var message: []const u8 = "";
                for (self.items()) |item| {
                    if (slot != self.dialog.original_slot and slot != 0 and slot == item.slot) {
                        message = "保存すると、この弾幕にキーを付け替えます。";
                        break;
                    }
                }
                windows.setText(self.dialog.status, message);
            }
        }
    }

    fn resizeEditor(self: *Management) void {
        const e = &self.dialog;
        if (e.save == null) return;
        e.viewport.arrange(e.window, self, placeEditor);
    }

    fn placeEditor(self: *Management) void {
        const e = &self.dialog;
        const dpi = self.dpi;
        const height: i32 = switch (e.mode) {
            .add_item, .edit_item => 300,
            .link_profile => 344,
            else => 232,
        };
        const content = e.viewport.layout(e.window, dpi, .{ .width = 344, .height = height }, null) orelse return;
        const margin = dpi.pixels(12);
        const pad = margin - e.viewport.x;
        const top = -e.viewport.y;
        const full = content.width - 2 * margin;
        move(e.heading, pad, top + dpi.pixels(10), full, dpi.pixels(26));
        switch (e.mode) {
            .add_item, .edit_item => {
                move(e.name_label, pad, top + dpi.pixels(46), full, dpi.pixels(23));
                move(e.name, pad, top + dpi.pixels(69), full, dpi.pixels(27));
                move(e.body_label, pad, top + dpi.pixels(106), full, dpi.pixels(23));
                move(e.text, pad, top + dpi.pixels(129), full, dpi.pixels(27));
                move(e.choice_label, pad, top + dpi.pixels(166), full, dpi.pixels(23));
                move(e.choice, pad, top + dpi.pixels(189), full, dpi.pixels(128));
            },
            .move_item => {
                move(e.choice_label, pad, top + dpi.pixels(46), full, dpi.pixels(38));
                move(e.choice, pad, top + dpi.pixels(89), full, dpi.pixels(140));
            },
            .add_profile, .rename_profile => {
                move(e.name_label, pad, top + dpi.pixels(46), full, dpi.pixels(23));
                move(e.name, pad, top + dpi.pixels(69), full, dpi.pixels(27));
            },
            .link_profile => {
                move(e.choice_label, pad, top + dpi.pixels(42), full, dpi.pixels(23));
                move(e.choice, pad, top + dpi.pixels(66), full, dpi.pixels(140));
                move(e.name_label, pad, top + dpi.pixels(105), full, dpi.pixels(23));
                move(e.name, pad, top + dpi.pixels(128), full, dpi.pixels(27));
                move(e.details, pad, top + dpi.pixels(166), full, dpi.pixels(100));
            },
        }
        const bottom = top + content.height - dpi.pixels(39);
        const button_width = dpi.pixels(112);
        move(e.status, pad, bottom - dpi.pixels(32), full, dpi.pixels(31));
        move(e.save, pad, bottom, button_width, dpi.pixels(27));
        move(e.cancel, pad + button_width + dpi.pixels(8), bottom, button_width, dpi.pixels(27));
    }

    fn editorDirty(self: Management) !bool {
        const e = self.dialog;
        if (e.name == null) return false;
        const name_value = try windows.text(e.name, allocator);
        defer allocator.free(name_value);
        if (!std.mem.eql(u8, name_value, e.original_name)) return true;
        if (e.text == null) return false;
        const content = try windows.text(e.text, allocator);
        defer allocator.free(content);
        return !std.mem.eql(u8, content, e.original_text) or currentChoice(e.choice) != e.original_slot;
    }

    fn cancelDialog(self: *Management) void {
        if (self.confirming or (self.saving_editor and self.dialog.mode != .link_profile)) return;
        if (self.editorDirty() catch true) {
            if (!self.confirm(self.dialog.window, "保存せずに閉じますか？", "未保存の変更"))
                return;
        }
        self.closeDialog();
        self.updateActions();
    }

    fn confirm(self: *Management, owner: win.HWND, comptime message: []const u8, comptime title: []const u8) bool {
        self.confirming = true;
        defer self.confirming = false;
        return win.MessageBoxW(owner, wide(message), wide(title), win.MB_YESNO | win.MB_DEFBUTTON2 | win.MB_ICONQUESTION) == win.IDYES;
    }

    fn closeDialog(self: *Management) void {
        const editor = self.dialog.window orelse return;
        var closing = self.dialog;
        const generation = self.editor_generation;
        self.dialog = .{};
        defer closing.arena.deinit();
        const was_foreground = win.GetForegroundWindow() == editor;
        const parent = closing.parent;
        if (closing.parent_was_enabled and win.IsWindow(parent) != 0) _ = win.EnableWindow(parent, 1);
        _ = win.DestroyWindow(editor);
        if (self.editor_generation != generation or self.dialog.window != null) return;
        if (was_foreground and parent == self.window and win.IsWindowVisible(parent) != 0 and win.IsWindowEnabled(parent) != 0) {
            _ = win.SetForegroundWindow(parent);
            _ = win.SetFocus(self.list);
            if (self.viewport.revealFocus(self.window)) self.resize();
        }
    }

    fn saveDialog(self: *Management) !void {
        if (self.saving_editor or !self.editAllowed()) return;
        const mode = self.dialog.mode;
        self.saving_editor = true;
        defer {
            self.saving_editor = false;
            if (mode == .link_profile) self.updateActions();
        }
        const request_window = self.dialog.window;
        const request_generation = self.editor_generation;
        const name = if (self.dialog.name != null) try windows.text(self.dialog.name, allocator) else null;
        defer if (name) |value| allocator.free(value);
        const content = if (self.dialog.text != null) try windows.text(self.dialog.text, allocator) else null;
        defer if (content) |value| allocator.free(value);
        const selected = if (self.dialog.choice != null) currentChoice(self.dialog.choice) else null;
        var item_selection: ?[]const u8 = null;
        switch (mode) {
            .add_item, .edit_item => {
                const values: @FieldType(storage.ItemCommand, "add") = .{
                    .name = name.?,
                    .text = content.?,
                    .slot = @intCast(selected orelse return error.InvalidSlot),
                };
                const value: storage.ItemCommand = if (mode == .add_item) .{ .add = values } else .{ .edit = .{ .id = self.dialog.id, .values = values } };
                item_selection = try self.history.item(self.db, self.snapshot, self.dialog.origin, value);
            },
            .move_item => {
                const destination = try scopeAt(self.snapshot.data, selected orelse return error.ProfileMissing);
                _ = try self.history.item(self.db, self.snapshot, self.dialog.origin, .{ .move = .{ .id = self.dialog.id, .destination = destination } });
            },
            .add_profile, .rename_profile => {
                const value: storage.ProfileCommand = if (mode == .add_profile)
                    .{ .add = .{ .name = name.? } }
                else
                    .{ .rename = .{ .id = self.dialog.origin, .name = name.? } };
                const id = try self.history.profile(self.db, self.snapshot, value);
                if (id) |profile_id| setIdentity(&self.editing, profile_id) catch {};
            },
            .link_profile => {
                const index = selected orelse return error.ProfileMissing;
                if (index >= self.dialog.link_profiles.len) return error.ProfileMissing;
                const target = try allocator.dupe(u8, self.dialog.link_profiles[index]);
                defer allocator.free(target);
                var latest = self.resolveChannel(allocator) catch |failure| {
                    if (self.dialog.window != request_window or self.editor_generation != request_generation) return;
                    return failure;
                };
                defer latest.deinit();
                if (self.dialog.window != request_window or self.editor_generation != request_generation or !self.editAllowed()) return;
                const channel = latest.channel.?;
                if (latest.target != self.dialog.browser_target or latest.target_pid != self.dialog.browser_pid or
                    !std.mem.eql(u8, channel, self.dialog.channel)) return error.ChannelChanged;
                const value: storage.ProfileCommand = if (target.len == 0)
                    .{ .add = .{ .name = name.?, .channel = channel } }
                else
                    .{ .bind = .{ .id = target, .channel = channel } };
                const id = try self.history.profile(self.db, self.snapshot, value);
                if (id) |profile_id| setIdentity(&self.editing, profile_id) catch {};
            },
        }
        self.closeDialog();
        self.changed(item_selection);
    }

    fn resize(self: *Management) void {
        if (self.list == null or self.back == null) return;
        self.viewport.arrange(self.window, self, placeControls);
    }

    fn placeControls(self: *Management) void {
        const dpi = self.dpi;
        const content = self.viewport.layout(self.window, dpi, .{ .width = 344, .height = 372 }, null) orelse return;
        const top = -self.viewport.y;
        const margin = dpi.pixels(12);
        const pad = margin - self.viewport.x;
        const full = content.width - margin * 2;
        const gap = dpi.pixels(6);
        const half = @max(@divTrunc(full - gap, 2), 0);
        move(self.manual, pad, top + dpi.pixels(10), full, dpi.pixels(24));
        move(self.scope, pad, top + dpi.pixels(36), full, dpi.pixels(220));
        move(self.profile_add, pad, top + dpi.pixels(69), half, dpi.pixels(28));
        move(self.profile_menu, pad + half + gap, top + dpi.pixels(69), half, dpi.pixels(28));
        move(self.channel, pad, top + dpi.pixels(102), full, dpi.pixels(26));
        const list_top = dpi.pixels(131);
        const list_bottom = @max(list_top + dpi.pixels(56), content.height - dpi.pixels(182));
        const foot = top + list_bottom;
        move(self.list, pad, top + list_top, full, list_bottom - list_top);
        _ = win.SendMessageW(self.list, win.LVM_SETCOLUMNWIDTH, 0, @divTrunc(full * 3, 10));
        _ = win.SendMessageW(self.list, win.LVM_SETCOLUMNWIDTH, 1, @max(@divTrunc(full * 7, 10) - dpi.pixels(105), dpi.pixels(90)));
        _ = win.SendMessageW(self.list, win.LVM_SETCOLUMNWIDTH, 2, dpi.pixels(90));
        const button_space = full - gap * 3;
        const width = @divTrunc(button_space, 4);
        for (self.item_buttons[0..4], 0..) |button, i| {
            move(button, pad + @as(i32, @intCast(i)) * (width + gap), foot + dpi.pixels(7), width, dpi.pixels(27));
        }
        var left = pad;
        for (self.item_buttons[4..], lowerButtonWidths(dpi, button_space)) |button, button_width| {
            move(button, left, foot + dpi.pixels(38), button_width, dpi.pixels(27));
            left += button_width + gap;
        }
        move(self.undo_button, pad, foot + dpi.pixels(72), full, dpi.pixels(27));
        move(self.notice, pad, foot + dpi.pixels(106), full, dpi.pixels(28));
        move(self.back, pad, foot + dpi.pixels(140), half, dpi.pixels(27));
        move(self.support, pad + half + gap, foot + dpi.pixels(140), half, dpi.pixels(27));
    }

    fn notify(self: *Management, header: *const win.NMHDR) win.LRESULT {
        if (header.hwndFrom != self.list) return 0;
        switch (@as(i32, @bitCast(header.code))) {
            -177 => self.provideText(@ptrCast(@constCast(header))), // LVN_GETDISPINFOW
            -179 => return self.findName(@ptrCast(header)), // LVN_ODFINDITEMW
            -101 => { // LVN_ITEMCHANGED
                if (!self.refreshing) {
                    const selection = self.selectedIndex();
                    const id = if (selection) |index| self.items()[index].id else "";
                    setIdentity(&self.selection, id) catch {};
                    self.updateActions();
                }
            },
            -3 => { // NM_DBLCLK
                self.command(@intFromEnum(Id.edit), win.BN_CLICKED) catch |err| self.showError(err);
            },
            else => {},
        }
        return 0;
    }

    fn provideText(self: *Management, display: *win.NMLVDISPINFOW) void {
        const view = &display.item;
        if (view.mask & win.LVIF_TEXT == 0 or view.pszText == null or view.cchTextMax <= 0) return;
        const buffer: []u16 = view.pszText[0..@intCast(view.cchTextMax)];
        buffer[0] = 0;
        const content = self.published_list orelse return;
        if (view.iItem < 0 or view.iItem >= content.rows.len) return;
        const item = content.rows[@intCast(view.iItem)];
        const description = switch (view.iSubItem) {
            0 => item.name,
            1 => item.text,
            2 => content.slotLabel(item.slot),
            else => "",
        };
        copyText(buffer, description);
    }

    fn findName(self: *Management, find: *const win.NMLVFINDITEMW) win.LRESULT {
        const flags = find.lvfi.flags;
        if (find.lvfi.psz == null or flags & (win.LVFI_PARAM | win.LVFI_NEARESTXY) != 0) return -1;
        const until: [*:0]const u16 = @ptrCast(find.lvfi.psz);
        const rows = self.items();
        if (rows.len == 0) return -1;
        const query = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(until)) catch return -1;
        defer allocator.free(query);
        const start: usize = @intCast(@max(0, find.iStart));
        const wrap = flags & win.LVFI_WRAP != 0;
        // Both prefix flags imply a text search even without LVFI_STRING.
        const prefix = flags & (win.LVFI_PARTIAL | win.LVFI_SUBSTRING) != 0;
        for (0..rows.len) |offset| {
            var index = start + offset;
            if (index >= rows.len) {
                if (!wrap) break;
                index %= rows.len;
            }
            const candidate = rows[index].name;
            if (if (prefix) std.ascii.startsWithIgnoreCase(candidate, query) else std.ascii.eqlIgnoreCase(candidate, query))
                return @intCast(index);
        }
        return -1;
    }
};

fn slotText(out: []u8, prefs: storage.Preferences, profile: bool, slot: u8) []const u8 {
    if (slot == 0 or slot > 2) return "";
    const first: storage.Action = if (profile) .profile1 else .shared1;
    const key = prefs.shortcut_keys[@intFromEnum(first) + slot - 1];
    if (key.len == 0) return "無効";
    const chord = (shortcuts.parse(key) catch return key).?;
    if (chord.key == .escape) return key;
    return shortcuts.label(chord, out);
}

fn copyText(destination: []u16, source: []const u8) void {
    if (destination.len == 0) return;
    const view = std.unicode.Utf8View.initUnchecked(source);
    var iter = view.iterator();
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

fn register(name: [:0]const u16, callback: win.WNDPROC) !void {
    var info = std.mem.zeroes(win.WNDCLASSW);
    info.lpfnWndProc = callback;
    info.hInstance = win.GetModuleHandleW(null);
    info.hCursor = win.LoadCursorW(null, @ptrFromInt(32512));
    info.hbrBackground = win.GetSysColorBrush(win.COLOR_WINDOW);
    info.lpszClassName = name;
    if (win.RegisterClassW(&info) == 0 and win.GetLastError() != win.ERROR_CLASS_ALREADY_EXISTS)
        return error.RegisterManagementWindow;
}

fn control(parent: win.HWND, comptime kind: []const u8, comptime value: []const u8, flags: u32, id: ?Id) !win.HWND {
    return controlText(parent, wide(kind), wide(value), flags, id);
}

fn controlText(parent: win.HWND, kind: [:0]const u16, value: [:0]const u16, flags: u32, id: ?Id) !win.HWND {
    const menu: win.HMENU = if (id) |which| @ptrFromInt(@intFromEnum(which)) else null;
    const child_visible: u32 = @intCast(win.WS_CHILD | win.WS_VISIBLE);
    const hwnd = win.CreateWindowExW(0, kind, value, child_visible | flags, 0, 0, 1, 1, parent, menu, win.GetModuleHandleW(null), null) orelse return error.CreateManagementControl;
    try viewport.trackFocus(hwnd, parent, flags);
    return hwnd;
}

fn fillScopes(box: win.HWND, profiles: []const storage.Profile, shared: []const u8) !void {
    _ = win.SendMessageW(box, win.WM_SETREDRAW, 0, 0);
    defer {
        _ = win.SendMessageW(box, win.WM_SETREDRAW, 1, 0);
        _ = win.InvalidateRect(box, null, 1);
    }
    _ = win.SendMessageW(box, win.CB_RESETCONTENT, 0, 0);
    try addChoice(box, shared);
    for (profiles) |entry| try addChoice(box, entry.name);
}

fn addChoice(box: win.HWND, value: []const u8) !void {
    const text = try std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
    defer allocator.free(text);
    if (win.SendMessageW(box, win.CB_ADDSTRING, 0, pointerParam(text.ptr)) < 0) return error.ManagementChoices;
}

fn scopeAt(data: storage.Data, index: usize) ![]const u8 {
    if (index == 0) return "";
    if (index > data.profiles.len) return error.ProfileMissing;
    return data.profiles[index - 1].id;
}

fn choose(box: win.HWND, index: usize) void {
    _ = win.SendMessageW(box, win.CB_SETCURSEL, index, 0);
}

fn currentChoice(box: win.HWND) ?usize {
    const item = win.SendMessageW(box, win.CB_GETCURSEL, 0, 0);
    return if (item < 0) null else @intCast(item);
}

fn popup(owner: win.HWND, button: win.HWND, menu: win.HMENU) usize {
    var rect: win.RECT = undefined;
    if (win.GetWindowRect(button, &rect) == 0) return 0;
    return @intCast(win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, rect.left, rect.bottom, 0, owner, null));
}

fn move(hwnd: win.HWND, x: i32, y: i32, width: i32, height: i32) void {
    if (hwnd != null) _ = win.MoveWindow(hwnd, x, y, width, height, 1);
}

fn lowerButtonWidths(dpi: windows.Dpi, button_space: i32) [4]i32 {
    const equal = @divTrunc(button_space, 4);
    // On narrow windows, the reorder captions need less space than move and shortcut assignment.
    const move_width = @max(equal, dpi.pixels(114));
    const binding = @max(equal, dpi.pixels(80));
    const order = @divTrunc(button_space - move_width - binding, 2);
    return .{ order, order, move_width, binding };
}

fn pointerParam(ptr: anytype) win.LPARAM {
    return @bitCast(@intFromPtr(ptr));
}

fn dataFromWindow(hwnd: win.HWND, message: win.UINT, lparam: win.LPARAM) ?*Management {
    if (message == win.WM_NCCREATE) {
        const parameters: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, pointerParam(parameters.lpCreateParams));
    }
    const ptr: usize = @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA));
    return if (ptr == 0) null else @ptrFromInt(ptr);
}

fn viewProcedure(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    const self = dataFromWindow(hwnd, message, lparam) orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win.WM_SIZE => if (!self.viewport.updating and wparam != win.SIZE_MINIMIZED) {
            const revision = self.viewport.scroll_revision;
            self.resize();
            if (revision == self.viewport.scroll_revision and self.viewport.revealFocus(hwnd)) self.resize();
        },
        viewport.wm_reflow => if (self.viewport.takeReflow(hwnd)) self.resize(),
        viewport.wm_focus_changed => if (self.viewport.revealFocus(hwnd)) self.resize(),
        win.WM_GETMINMAXINFO => {
            const info: *win.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            viewport.minimumTrack(hwnd, self.dpi, info);
        },
        win.WM_HSCROLL, win.WM_VSCROLL => if (lparam == 0 and self.viewport.scroll(hwnd, if (message == win.WM_HSCROLL) win.SB_HORZ else win.SB_VERT, wparam, self.dpi)) self.resize(),
        win.WM_ACTIVATE => self.updateActions(),
        win.WM_CLOSE => self.hide(),
        win.WM_NOTIFY => return self.notify(@ptrFromInt(@as(usize, @bitCast(lparam)))),
        win.WM_COMMAND => self.command(windows.low(wparam), windows.high(wparam)) catch |err| self.showError(err),
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
    return 0;
}

fn editorProcedure(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    const self = dataFromWindow(hwnd, message, lparam) orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    if (self.dialog.window != hwnd) return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win.WM_SIZE => if (!self.dialog.viewport.updating and wparam != win.SIZE_MINIMIZED) {
            const revision = self.dialog.viewport.scroll_revision;
            self.resizeEditor();
            if (revision == self.dialog.viewport.scroll_revision and self.dialog.viewport.revealFocus(hwnd)) self.resizeEditor();
        },
        viewport.wm_reflow => if (self.dialog.viewport.takeReflow(hwnd)) self.resizeEditor(),
        viewport.wm_focus_changed => if (self.dialog.viewport.revealFocus(hwnd)) self.resizeEditor(),
        win.WM_HSCROLL, win.WM_VSCROLL => if (lparam == 0 and self.dialog.viewport.scroll(hwnd, if (message == win.WM_HSCROLL) win.SB_HORZ else win.SB_VERT, wparam, self.dpi)) self.resizeEditor(),
        win.DM_GETDEFID => return (win.DC_HASDEFID << 16) | @intFromEnum(Id.confirm),
        win.WM_CLOSE => self.cancelDialog(),
        win.WM_COMMAND => {
            const id = windows.low(wparam);
            const command_code = windows.high(wparam);
            if (id == @intFromEnum(Id.cancel)) self.cancelDialog();
            if (id == @intFromEnum(Id.confirm)) self.saveDialog() catch |err| self.showError(err);
            if (id == @intFromEnum(Id.choice) and command_code == win.CBN_SELCHANGE) self.updateEditorChoice();
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
    return 0;
}

test "desktop DPI keeps space for long management actions at the viewport minimum" {
    for ([_]u32{ 96, 120, 144, 192 }) |scale| {
        const dpi: windows.Dpi = .{ .value = scale };
        const button_space = dpi.pixels(344) - 2 * dpi.pixels(12) - 3 * dpi.pixels(6);
        const widths = lowerButtonWidths(dpi, button_space);
        try std.testing.expect(widths[0] >= dpi.pixels(49));
        try std.testing.expectEqual(widths[0], widths[1]);
        try std.testing.expectEqual(dpi.pixels(114), widths[2]);
        try std.testing.expectEqual(dpi.pixels(80), widths[3]);
        try std.testing.expect(widths[0] + widths[1] + widths[2] + widths[3] <= button_space);
    }
}

test "virtual row buffers terminate before splitting emoji surrogate pairs" {
    var small: [3]u16 = undefined;
    copyText(&small, "A👏B");
    try std.testing.expectEqual(@as(u16, 'A'), small[0]);
    try std.testing.expectEqual(@as(u16, 0), small[1]);
    var bigger: [5]u16 = undefined;
    copyText(&bigger, "A👏B");
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0xd83d, 0xdc4f, 'B', 0 }, &bigger);
}

fn testHost(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    switch (message) {
        wm_edit_allowed => return 1,
        wm_changed => {
            const prior = win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA);
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, prior + 1);
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

test "native owner-data rows stay published until explicit refresh" {
    const testing = std.testing;
    const heap = testing.allocator;
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const home = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(home);
    const path = try std.fs.path.join(heap, &.{ home, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    try db.save(.{ .shared_items = &.{.{ .id = "alpha", .name = "Alpha 日本語", .text = "first", .slot = 1 }} });
    var snapshot = try db.load(heap);
    defer snapshot.deinit();
    var history = storage.LibraryHistory.init(heap);
    defer history.deinit();
    const host_class = wide("ChatPalette.TestManagement");
    try register(host_class, testHost);
    const host = win.CreateWindowExW(0, host_class, wide("test"), 0, 0, 0, 0, 0, null, null, win.GetModuleHandleW(null), null) orelse return error.TestHost;
    defer _ = win.DestroyWindow(host);
    var view: Management = .{};
    try view.open(host, &db, &snapshot, &history);
    defer view.close();
    try testing.expect(win.IsWindowVisible(view.window) == 0);
    const first = (view.published_list orelse return error.ManagementListWasNotPublished).retain();
    defer first.release();
    var buffer: [64]u16 = undefined;
    try testing.expectEqualSlices(u16, wide("Alpha 日本語"), try readTestCell(view.list, 0, &buffer));
    try testing.expectEqualSlices(u16, wide("first"), try readTestCell(view.list, 1, &buffer));
    try testing.expectEqualSlices(u16, wide("Ctrl+Alt+3"), try readTestCell(view.list, 2, &buffer));
    _ = try history.item(&db, &snapshot, "", .{ .edit = .{ .id = "alpha", .values = .{ .name = "Changed", .text = "replacement", .slot = 1 } } });
    snapshot.data.preferences.shortcut_keys[@intFromEnum(storage.Action.shared1)] = "^+F12";
    try testing.expectEqualStrings("replacement", snapshot.data.shared_items[0].text);
    try testing.expectEqualSlices(u16, wide("Alpha 日本語"), try readTestCell(view.list, 0, &buffer));
    try testing.expectEqualSlices(u16, wide("first"), try readTestCell(view.list, 1, &buffer));
    try testing.expectEqualSlices(u16, wide("Ctrl+Alt+3"), try readTestCell(view.list, 2, &buffer));
    try testing.expectEqual(@as(i32, 0), findTestText(view.list, wide("Alpha 日本語")));
    try testing.expectEqual(@as(i32, -1), findTestText(view.list, wide("Changed")));
    {
        if (win.SetWindowSubclass(view.list, refuseTestListCount, 2, 0) == 0) return error.CannotSetNativeRenderFault;
        defer _ = win.RemoveWindowSubclass(view.list, refuseTestListCount, 2);
        view.refresh();
        try testing.expect(view.list_update_failed);
        try testing.expect(view.published_list.? == first);
        try testing.expect(win.IsWindowEnabled(view.item_buttons[0]) == 0);
        try testing.expectEqualSlices(u16, wide("first"), try readTestCell(view.list, 1, &buffer));
    }
    view.refresh();
    const second = view.published_list orelse return error.ManagementListWasNotPublished;
    try testing.expect(second != first and !view.list_update_failed);
    try testing.expect(win.IsWindowEnabled(view.item_buttons[0]) != 0);
    try testing.expectEqualSlices(u16, wide("Changed"), try readTestCell(view.list, 0, &buffer));
    try testing.expectEqualSlices(u16, wide("replacement"), try readTestCell(view.list, 1, &buffer));
    try testing.expectEqualSlices(u16, wide("Ctrl+Shift+F12"), try readTestCell(view.list, 2, &buffer));
    try testing.expectEqual(@as(i32, 0), findTestText(view.list, wide("Changed")));
    try testing.expectEqual(@as(i32, -1), findTestText(view.list, wide("Alpha 日本語")));
    try testing.expectEqualStrings("alpha", snapshot.data.shared_items[0].id);
    try testing.expectEqualStrings("alpha", second.rows[0].id);
    try testing.expectEqualStrings("Alpha 日本語", first.rows[0].name);
    try testing.expectEqualStrings("first", first.rows[0].text);
    try testing.expectEqualStrings("Ctrl+Alt+3", first.slotLabel(1));
    view.refresh();
    try testing.expect(view.published_list.? == second);
}

fn refuseTestListCount(window: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: usize, _: usize) callconv(.winapi) win.LRESULT {
    if (message == win.LVM_SETITEMCOUNT) return 0;
    return win.DefSubclassProc(window, message, wparam, lparam);
}

fn findTestText(list: win.HWND, query: [:0]const u16) i32 {
    var request = std.mem.zeroes(win.LVFINDINFOW);
    request.flags = win.LVFI_STRING;
    request.psz = query.ptr;
    return @truncate(win.SendMessageW(list, win.LVM_FINDITEMW, std.math.maxInt(win.WPARAM), pointerParam(&request)));
}

fn readTestCell(list: win.HWND, column: c_int, buffer: []u16) ![]const u16 {
    @memset(buffer, 0xa5a5);
    var cell = std.mem.zeroes(win.LVITEMW);
    cell.mask = win.LVIF_TEXT;
    cell.iItem = 0;
    cell.iSubItem = column;
    cell.pszText = buffer.ptr;
    cell.cchTextMax = @intCast(buffer.len);
    if (win.SendMessageW(list, win.LVM_GETITEMW, 0, pointerParam(&cell)) == 0) return error.CannotReadVirtualCell;
    const end = std.mem.indexOfScalar(u16, buffer, 0) orelse return error.UnterminatedVirtualCell;
    return buffer[0..end];
}

test "native owner-data ListView searches support the legacy text flags" {
    const testing = std.testing;
    const heap = testing.allocator;
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const home = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(home);
    const path = try std.fs.path.join(heap, &.{ home, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    try db.save(.{ .shared_items = &.{
        .{ .id = "alpha", .name = "Alpha 日本語", .text = "first" },
        .{ .id = "beta", .name = "Beta", .text = "second" },
        .{ .id = "gamma", .name = "Gamma", .text = "third" },
    } });
    var snapshot = try db.load(heap);
    defer snapshot.deinit();
    var history = storage.LibraryHistory.init(heap);
    defer history.deinit();
    const host_class = wide("ChatPalette.TestManagement");
    try register(host_class, testHost);
    const host = win.CreateWindowExW(0, host_class, wide("test"), 0, 0, 0, 0, 0, null, null, win.GetModuleHandleW(null), null) orelse return error.TestHost;
    defer _ = win.DestroyWindow(host);
    var view: Management = .{};
    try view.open(host, &db, &snapshot, &history);
    defer view.close();
    try testing.expect(win.GetWindowLongW(view.list, win.GWL_STYLE) & win.LVS_OWNERDATA != 0);

    const searches = [_]struct {
        query: [:0]const u16,
        after: i32,
        flags: u32,
        expected: i32,
    }{
        .{ .query = wide("BETA"), .after = -1, .flags = win.LVFI_STRING, .expected = 1 },
        .{ .query = wide("Al"), .after = -1, .flags = win.LVFI_PARTIAL, .expected = 0 },
        .{ .query = wide("Al"), .after = 1, .flags = win.LVFI_PARTIAL, .expected = -1 },
        .{ .query = wide("Al"), .after = 1, .flags = win.LVFI_PARTIAL | win.LVFI_WRAP, .expected = 0 },
        .{ .query = wide("et"), .after = -1, .flags = win.LVFI_SUBSTRING, .expected = -1 },
        .{ .query = wide("Be"), .after = -1, .flags = win.LVFI_SUBSTRING, .expected = 1 },
        .{ .query = wide("missing"), .after = -1, .flags = win.LVFI_STRING, .expected = -1 },
        .{ .query = wide("ALPHA 日本語"), .after = -1, .flags = win.LVFI_STRING, .expected = 0 },
        .{ .query = wide("BETA"), .after = 1, .flags = win.LVFI_WRAP, .expected = 1 },
    };
    var expected: [searches.len]i32 = undefined;
    var observed: [searches.len]i32 = undefined;
    for (searches, &expected, &observed) |search, *want, *actual| {
        var request = std.mem.zeroes(win.LVFINDINFOW);
        request.flags = search.flags;
        request.psz = search.query.ptr;
        actual.* = @truncate(win.SendMessageW(view.list, win.LVM_FINDITEMW, @bitCast(@as(isize, search.after)), pointerParam(&request)));
        want.* = search.expected;
    }
    try testing.expectEqualSlices(i32, &expected, &observed);

    // Exercise native notification fields that the control normally supplies,
    // plus rejection of non-text and incomplete requests.
    var notification = std.mem.zeroes(win.NMLVFINDITEMW);
    notification.hdr.hwndFrom = view.list;
    notification.hdr.code = @bitCast(@as(i32, -179));
    notification.iStart = -1;
    notification.lvfi.psz = wide("BETA").ptr;
    notification.lvfi.flags = 0;
    try testing.expectEqual(@as(win.LRESULT, 1), win.SendMessageW(view.window, win.WM_NOTIFY, 0, pointerParam(&notification)));
    for ([_]u32{ win.LVFI_PARAM, win.LVFI_NEARESTXY }) |non_text| {
        notification.lvfi.flags = @as(u32, win.LVFI_STRING) | non_text;
        try testing.expectEqual(@as(win.LRESULT, -1), win.SendMessageW(view.window, win.WM_NOTIFY, 0, pointerParam(&notification)));
    }
    notification.lvfi.flags = win.LVFI_STRING;
    notification.lvfi.psz = null;
    try testing.expectEqual(@as(win.LRESULT, -1), win.SendMessageW(view.window, win.WM_NOTIFY, 0, pointerParam(&notification)));

    // The callback terminates inside the supplied capacity for empty and
    // out-of-range cells, and leaves both guards untouched.
    var display = std.mem.zeroes(win.NMLVDISPINFOW);
    display.hdr.hwndFrom = view.list;
    display.hdr.code = @bitCast(@as(i32, -177));
    display.item.mask = win.LVIF_TEXT;
    const name = wide("Alpha 日本語");
    for ([_]usize{ 1, 2, 8 }) |capacity| {
        var guarded: [10]u16 = @splat(0xa5a5);
        display.item.pszText = guarded[1..].ptr;
        display.item.cchTextMax = @intCast(capacity);
        _ = win.SendMessageW(view.window, win.WM_NOTIFY, 0, pointerParam(&display));
        try testing.expectEqual(@as(u16, 0xa5a5), guarded[0]);
        try testing.expectEqual(@as(u16, 0xa5a5), guarded[capacity + 1]);
        try testing.expectEqual(@as(u16, 0), guarded[capacity]);
        try testing.expectEqualSlices(u16, name[0 .. capacity - 1], guarded[1..capacity]);
    }
    var output = [_]u16{ 0xa5a5, 0xa5a5, 0xa5a5 };
    display.item.pszText = output[1..].ptr;
    display.item.cchTextMax = 1;
    display.item.iItem = @intCast(snapshot.data.shared_items.len);
    _ = win.SendMessageW(view.window, win.WM_NOTIFY, 0, pointerParam(&display));
    try testing.expectEqualSlices(u16, &.{ 0xa5a5, 0, 0xa5a5 }, &output);

    view.show();
    var state = std.mem.zeroes(win.LVITEMW);
    state.stateMask = win.LVIS_SELECTED | win.LVIS_FOCUSED;
    state.state = state.stateMask;
    _ = win.SendMessageW(view.list, win.LVM_SETITEMSTATE, 0, pointerParam(&state));
    _ = win.SetFocus(view.list);
    _ = win.SendMessageW(view.list, win.WM_CHAR, 'b', 1);
    try testing.expectEqual(@as(?usize, 1), view.selectedIndex());
    try testing.expectEqualStrings("beta", view.selection orelse return error.NativeSearchDidNotUpdateIdentity);

    snapshot.data.shared_items = &.{};
    view.refresh();
    var empty_find = std.mem.zeroes(win.LVFINDINFOW);
    empty_find.flags = win.LVFI_PARTIAL | win.LVFI_WRAP;
    empty_find.psz = wide("A").ptr;
    const empty_result: i32 = @truncate(win.SendMessageW(view.list, win.LVM_FINDITEMW, std.math.maxInt(win.WPARAM), pointerParam(&empty_find)));
    try testing.expectEqual(@as(i32, -1), empty_result);
    try testing.expectEqual(@as(win.LRESULT, 0), win.SendMessageW(view.list, win.LVM_GETITEMCOUNT, 0, 0));
    try testing.expectEqual(@as(?usize, null), view.selectedIndex());
}

test "management stores list changes, restores selection by ID, and keeps the input profile separate" {
    const testing = std.testing;
    const heap = testing.allocator;
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const home = try directory.dir.realpathAlloc(heap, ".");
    defer heap.free(home);
    const path = try std.fs.path.join(heap, &.{ home, "settings.db" });
    defer heap.free(path);
    var db = try storage.Store.open(heap, path);
    defer db.close();
    try db.save(.{
        .preferences = .{ .input_profile_id = "b" },
        .profiles = &.{
            .{ .id = "a", .name = "編集対象" },
            .{ .id = "b", .name = "入力対象" },
        },
        .shared_items = &.{
            .{ .id = "first", .name = "第一👏", .text = "本文" },
            .{ .id = "second", .name = "第二", .text = "body" },
        },
    });
    var snap = try db.load(heap);
    defer snap.deinit();
    var history = storage.LibraryHistory.init(heap);
    defer history.deinit();
    const host_class = wide("ChatPalette.TestManagement");
    try register(host_class, testHost);
    const host = win.CreateWindowExW(0, host_class, wide("test"), 0, 0, 0, 0, 0, null, null, win.GetModuleHandleW(null), null) orelse return error.TestHost;
    defer _ = win.DestroyWindow(host);
    var view: Management = .{};
    try view.open(host, &db, &snap, &history);
    defer view.close();
    try testing.expectEqual(@as(win.LRESULT, 2), win.SendMessageW(view.list, win.LVM_GETITEMCOUNT, 0, 0));

    var stored = std.mem.zeroes(win.LVITEMW);
    stored.stateMask = win.LVIS_SELECTED;
    stored.state = win.LVIS_SELECTED;
    _ = win.SendMessageW(view.list, win.LVM_SETITEMSTATE, 0, pointerParam(&stored));
    _ = win.SendMessageW(view.window, win.WM_COMMAND, @intFromEnum(Id.down), 0);
    try testing.expectEqualStrings("first", snap.data.shared_items[1].id);
    try testing.expectEqual(@as(?usize, 1), view.selectedIndex());
    try testing.expectEqual(@as(win.LONG_PTR, 1), win.GetWindowLongPtrW(host, win.GWLP_USERDATA));

    choose(view.scope, 1);
    _ = win.SendMessageW(view.window, win.WM_COMMAND, (@as(usize, win.CBN_SELCHANGE) << 16) | @intFromEnum(Id.scope), 0);
    try testing.expectEqualStrings("a", view.editingId());
    try testing.expectEqualStrings("b", snap.data.preferences.input_profile_id);
    try testing.expectEqual(@as(win.LRESULT, 0), win.SendMessageW(view.list, win.LVM_GETITEMCOUNT, 0, 0));

    try view.selectForEditing("", "first");
    view.refresh();
    try testing.expectEqualStrings("", view.editingId());
    try testing.expectEqual(@as(?usize, 1), view.selectedIndex());
    try testing.expectEqualStrings("b", snap.data.preferences.input_profile_id);

    var arena = std.heap.ArenaAllocator.init(heap);
    defer arena.deinit();
    const db_data = snap.data;
    defer snap.data = db_data;
    const scratch = arena.allocator();
    const rows = try scratch.alloc(storage.Item, 1000);
    for (rows, 1..) |*row, i| {
        row.* = .{
            .id = try std.fmt.allocPrint(scratch, "item-{d}", .{i}),
            .name = try std.fmt.allocPrint(scratch, "row {d}", .{i}),
            .text = "body",
        };
    }
    const removed = rows[0 .. rows.len - 1];
    const moved = try scratch.alloc(storage.Item, rows.len);
    moved[0] = rows[rows.len - 1];
    @memcpy(moved[1..], removed);

    var reads: NativeManagementReads = .{};
    if (win.SetWindowSubclass(view.list, NativeManagementReads.observe, 2, @intFromPtr(&reads)) == 0)
        return error.CannotTrackNativeManagementReads;
    errdefer _ = win.RemoveWindowSubclass(view.list, NativeManagementReads.observe, 2);
    for ([_][]const storage.Item{ rows, moved, removed }, [_]usize{ 999, 0, 0 }, [_][]const u8{ "item-1000", "item-1000", "item-1" }) |next, index, id| {
        snap.data.shared_items = rows;
        try view.selectForEditing("", "item-1000");
        view.refresh();
        try testing.expectEqual(@as(?usize, 999), view.selectedIndex());

        snap.data.shared_items = next;
        reads.text_messages = 0;
        view.refresh();
        try testing.expectEqual(@as(usize, 0), reads.text_messages);
        try testing.expectEqual(@as(?usize, index), view.selectedIndex());
        try testing.expectEqualStrings(id, view.selection orelse return error.SelectionWasNotRestored);
        try testing.expectEqualStrings(id, view.items()[view.selectedIndex().?].id);

        var cell = std.mem.zeroes(win.LVITEMW);
        var text_buffer: [20]u16 = @splat(0);
        cell.mask = win.LVIF_TEXT;
        cell.iItem = @intCast(index);
        cell.pszText = &text_buffer;
        cell.cchTextMax = text_buffer.len;
        _ = win.SendMessageW(view.list, win.LVM_GETITEMW, 0, pointerParam(&cell));
        try testing.expectEqual(@as(usize, 1), reads.text_messages);
    }
    try testing.expect(win.RemoveWindowSubclass(view.list, NativeManagementReads.observe, 2) != 0);

    // A new scope uses its own selection even if it has rows. Explicit
    // clearing and a newly empty scope must also remain unselected.
    const profiles = try scratch.dupe(storage.Profile, snap.data.profiles);
    profiles[0].items = &.{.{ .id = "scope-row", .name = "scope row", .text = "profile body" }};
    snap.data.profiles = profiles;
    view.refresh();
    choose(view.scope, 1);
    _ = win.SendMessageW(view.window, win.WM_COMMAND, (@as(usize, win.CBN_SELCHANGE) << 16) | @intFromEnum(Id.scope), 0);
    try testing.expectEqualStrings("a", view.editingId());
    try testing.expectEqual(@as(win.LRESULT, 1), win.SendMessageW(view.list, win.LVM_GETITEMCOUNT, 0, 0));
    try testing.expect(view.selectedIndex() == null and view.selection == null);

    try view.selectForEditing("", "");
    view.refresh();
    try testing.expect(view.selectedIndex() == null and view.selection == null);
    try view.selectForEditing("", "item-1");
    snap.data.shared_items = &.{};
    view.refresh();
    try testing.expect(view.selectedIndex() == null and view.selection == null);
    try testing.expectEqualStrings("b", snap.data.preferences.input_profile_id);
}

const NativeManagementReads = struct {
    text_messages: usize = 0,

    fn observe(window: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: usize, context: usize) callconv(.winapi) win.LRESULT {
        const count: *NativeManagementReads = @ptrFromInt(context);
        if (message == win.LVM_GETITEMTEXTW) {
            count.text_messages += 1;
        } else if (message == win.LVM_GETITEMW and lparam != 0) {
            const item: *const win.LVITEMW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (item.mask & win.LVIF_TEXT != 0) count.text_messages += 1;
        }
        return win.DefSubclassProc(window, message, wparam, lparam);
    }
};

const LinkFixture = struct {
    const Transition = enum { none, edit_choice, cancel, replace_with_error, changed_channel, changed_window, changed_owner };

    management: *Management,
    channel: []const u8 = "/@linked",
    transition: Transition = .none,
    requests: usize = 0,
    replacement_error: ?anyerror = null,
    busy: bool = false,
    actions_disabled_while_waiting: bool = false,

    fn response(self: *LinkFixture, request: *ChannelRequest) void {
        self.requests += 1;
        const change = self.transition;
        self.transition = .none;
        switch (change) {
            .edit_choice => choose(self.management.dialog.choice, 2),
            .cancel, .replace_with_error => {
                self.busy = true;
                _ = win.SendMessageW(self.management.dialog.window, win.WM_CLOSE, 0, 0);
                self.actions_disabled_while_waiting = win.IsWindowEnabled(self.management.item_buttons[0]) == 0 and
                    win.IsWindowEnabled(self.management.undo_button) == 0;
                self.busy = false;
                if (change == .replace_with_error) {
                    self.management.openDialogAt(.link_profile, null, "") catch |failure| {
                        self.replacement_error = failure;
                    };
                    return;
                }
            },
            else => {},
        }
        request.channel = request.allocator.dupe(u8, if (change == .changed_channel) "/@FRESH" else self.channel) catch return;
        request.author = request.allocator.dupe(u8, "合成配信者") catch return;
        request.target = if (change == .changed_window) 27 else 26;
        request.target_pid = if (change == .changed_owner) 91 else 90;
    }

    fn procedure(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
        if (message == wm_edit_allowed or (message == wm_resolve_channel and lparam != 0)) {
            const raw: usize = @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA));
            if (raw == 0) return 0;
            const fixture: *LinkFixture = @ptrFromInt(raw);
            if (message == wm_edit_allowed) return @intFromBool(!fixture.busy);
            fixture.response(@ptrFromInt(@as(usize, @bitCast(lparam))));
            return 0;
        }
        return win.DefWindowProcW(hwnd, message, wparam, lparam);
    }
};

test "channel linking uses the displayed identity and drops results after cancel or replacement" {
    const test_alloc = std.testing.allocator;
    var fixture_dir = std.testing.tmpDir(.{});
    defer fixture_dir.cleanup();
    const root = try fixture_dir.dir.realpathAlloc(test_alloc, ".");
    defer test_alloc.free(root);
    const path = try std.fs.path.join(test_alloc, &.{ root, "settings.db" });
    defer test_alloc.free(path);
    var db = try storage.Store.open(test_alloc, path);
    defer db.close();
    try db.save(.{ .profiles = &.{
        .{ .id = "fan-a", .name = "same", .channel = "/@old" },
        .{ .id = "fan-A", .name = "same", .channel = "/@linked" },
    } });
    var snapshot = try db.load(test_alloc);
    defer snapshot.deinit();
    var history = storage.LibraryHistory.init(test_alloc);
    defer history.deinit();
    var view: Management = .{};
    var fixture: LinkFixture = .{ .management = &view };
    const host_class = wide("ChatPalette.TestChannelLink");
    try register(host_class, LinkFixture.procedure);
    const host = win.CreateWindowExW(0, host_class, wide("channel link fixture"), 0, 0, 0, 0, 0, null, null, win.GetModuleHandleW(null), null) orelse return error.TestHost;
    defer _ = win.DestroyWindow(host);
    _ = win.SetWindowLongPtrW(host, win.GWLP_USERDATA, pointerParam(&fixture));
    try view.open(host, &db, &snapshot, &history);
    defer view.close();
    try view.selectForEditing("fan-a", "");

    view.linkFromPalette();
    try std.testing.expectEqual(@as(?usize, 2), currentChoice(view.dialog.choice));
    try std.testing.expectEqualStrings("fan-a", view.editingId());
    try std.testing.expectEqual(@as(win.BOOL, 0), win.IsWindowEnabled(view.window));
    view.cancelDialog();
    try std.testing.expect(view.dialog.window == null and win.IsWindowEnabled(view.window) != 0);

    fixture.channel = "/@fresh";
    try view.openDialog(.link_profile, null);
    try std.testing.expectEqual(@as(?usize, 1), currentChoice(view.dialog.choice));
    fixture.transition = .edit_choice;
    try view.saveDialog();
    try std.testing.expectEqualStrings("/@fresh", snapshot.data.findProfile("fan-a").?.channel);
    try std.testing.expectEqualStrings("/@linked", snapshot.data.findProfile("fan-A").?.channel);
    try std.testing.expectEqual(@as(usize, 1), history.length);
    try std.testing.expect(view.dialog.window == null);

    for ([_]LinkFixture.Transition{ .changed_channel, .changed_window, .changed_owner }) |change| {
        view.linkFromPalette();
        fixture.transition = change;
        try std.testing.expectError(error.ChannelChanged, view.saveDialog());
        try std.testing.expect(view.dialog.window != null and win.IsWindowEnabled(view.window) == 0);
        view.cancelDialog();
    }

    for ([_]LinkFixture.Transition{ .cancel, .replace_with_error }) |change| {
        fixture.channel = "/@uncommitted";
        view.linkFromPalette();
        const prior = view.editor_generation;
        fixture.transition = change;
        try view.saveDialog();
        if (change == .replace_with_error) {
            try std.testing.expect(fixture.replacement_error == null);
            try std.testing.expect(view.dialog.window != null and view.editor_generation != prior and win.IsWindowEnabled(view.window) == 0);
            view.cancelDialog();
        }
        try std.testing.expect(view.dialog.window == null and win.IsWindowEnabled(view.window) != 0);
        try std.testing.expect(fixture.actions_disabled_while_waiting);
        try std.testing.expect(win.IsWindowEnabled(view.item_buttons[0]) != 0 and win.IsWindowEnabled(view.undo_button) != 0);
        try std.testing.expectEqual(@as(usize, 1), history.length);
    }

    var stored = try db.load(test_alloc);
    defer stored.deinit();
    try std.testing.expectEqualStrings("/@fresh", stored.data.findProfile("fan-a").?.channel);
    try std.testing.expectEqualStrings("/@linked", stored.data.findProfile("fan-A").?.channel);
    try std.testing.expectEqual(@as(usize, 14), fixture.requests);
}
