const std = @import("std");
const windows = @import("win.zig");
const storage = @import("../storage/store.zig");
const bindings = @import("shortcuts.zig");
const diagnostics = @import("diagnostics.zig");
const viewport = @import("viewport.zig");
const Viewport = viewport.Viewport;
const win = windows.api;
const allocator = std.heap.page_allocator;
const class_name = windows.wide("ChatPalette.Support");
const ok_id = 1;
const cancel_id = 2;
const reset_id = 3;
const scope_id = 200;
const first_slot_id = 201;
const second_slot_id = 202;
const save_items_id = 203;
const key_status_id = 204;
const item_status_id = 205;

const action_labels = [_][]const u8{
    "パレットを開く",             "配信者の弾幕 1",        "配信者の弾幕 2",          "共通の弾幕 1",           "共通の弾幕 2",
    "チャット欄へフォーカス", "チャット欄をクリア", "リアクションUIを表示", "リアクションを実行", "チャット送信",
    "停止",
};

/// Returns true once the caller has committed the draft. On failure the
/// caller can display its error using the still-open editor as the owner.
pub const ShortcutSaver = *const fn (context: *anyopaque, dialog: win.HWND, keys: [storage.action_count][]const u8) bool;
pub const ShortcutItemSaver = *const fn (context: *anyopaque, dialog: win.HWND, scope: []const u8, first: []const u8, second: []const u8) bool;

const ShortcutEditor = struct {
    baseline: ShortcutDraft,
    snapshot: *const storage.Snapshot,
    context: *anyopaque,
    save: ShortcutSaver,
    save_items: ShortcutItemSaver,
};

const ShortcutDraft = struct {
    keys: [storage.action_count][]const u8,

    fn copy(keys: [storage.action_count][]const u8) !ShortcutDraft {
        var result: ShortcutDraft = undefined;
        for (keys, &result.keys, 0..) |key, *value, i| {
            value.* = allocator.dupe(u8, key) catch |failure| {
                for (result.keys[0..i]) |owned| allocator.free(owned);
                return failure;
            };
        }
        return result;
    }

    fn deinit(self: ShortcutDraft) void {
        for (self.keys) |value| allocator.free(value);
    }

    fn preserveEquivalent(self: *ShortcutDraft, baseline: ShortcutDraft) !void {
        for (&self.keys, baseline.keys) |*value, previous| {
            if (std.mem.eql(u8, value.*, previous) or !sameKey(previous, value.*)) continue;
            const unchanged = try allocator.dupe(u8, previous);
            allocator.free(value.*);
            value.* = unchanged;
        }
    }
};

const ItemChoices = struct {
    arena: std.heap.ArenaAllocator,
    scope: []const u8,
    scope_index: usize,
    ids: []const []const u8,
    baseline: [2]usize,
};

fn sameKey(old: []const u8, new: []const u8) bool {
    if (std.mem.eql(u8, old, new)) return true;
    const previous = bindings.parse(old) catch return false;
    const current = bindings.parse(new) catch return false;
    return std.meta.eql(previous, current);
}

fn sameKeys(before: [storage.action_count][]const u8, after: [storage.action_count][]const u8) bool {
    for (before, after) |old, new| if (!sameKey(old, new)) return false;
    return true;
}

fn keyError(failure: anyerror) []const u8 {
    return switch (failure) {
        error.DuplicateShortcut => "キーの割当が重複しています。",
        else => "キーの割当を確認してください。パレット、リアクションの実行、停止にはキーが必要です。",
    };
}

fn comboChoice(hwnd: win.HWND) ?usize {
    return std.math.cast(usize, win.SendMessageW(hwnd, win.CB_GETCURSEL, 0, 0));
}

fn addChoice(hwnd: win.HWND, label: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, label);
    defer allocator.free(wide);
    if (win.SendMessageW(hwnd, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(wide.ptr))) < 0)
        return error.ShortcutChoicesUnavailable;
}

const Dialog = struct {
    window: win.HWND = null,
    disabled_parent: win.HWND = null,
    original_focus: win.HWND = null,
    dpi: windows.Dpi = .{},
    font: windows.GuiFont = .{},
    labels: [storage.action_count]win.HWND = @splat(null),
    edits: [storage.action_count]win.HWND = @splat(null),
    key_states: [storage.action_count]win.HWND = @splat(null),
    key_status: win.HWND = null,
    item_heading: win.HWND = null,
    scope: win.HWND = null,
    slot_labels: [2]win.HWND = @splat(null),
    slots: [2]win.HWND = @splat(null),
    save_items: win.HWND = null,
    item_status: win.HWND = null,
    item_choices: ?ItemChoices = null,
    document: win.HWND = null,
    instructions: win.HWND = null,
    reset: win.HWND = null,
    save: win.HWND = null,
    cancel: win.HWND = null,
    viewport: Viewport = .{},
    editor: ?ShortcutEditor = null,
    finishing: bool = false,

    fn open(self: *Dialog, parent: win.HWND, comptime title: []const u8, width: c_int, height: c_int) !void {
        self.dpi = windows.Dpi.system();
        var wc = std.mem.zeroes(win.WNDCLASSW);
        wc.hInstance = win.GetModuleHandleW(null);
        wc.lpszClassName = class_name;
        wc.lpfnWndProc = handle;
        wc.hbrBackground = win.GetSysColorBrush(win.COLOR_WINDOW);
        wc.hCursor = win.LoadCursorW(null, @ptrFromInt(32512));
        if (win.RegisterClassW(&wc) == 0 and win.GetLastError() != win.ERROR_CLASS_ALREADY_EXISTS)
            return error.RegisterSupportDialog;
        const resize_frame: win.DWORD = if (self.editor != null) win.WS_THICKFRAME else 0;
        const frame = @as(win.DWORD, win.WS_CAPTION | win.WS_SYSMENU) | resize_frame;
        self.window = win.CreateWindowExW(win.WS_EX_DLGMODALFRAME | win.WS_EX_CONTROLPARENT, class_name, windows.wide(title), 0x8000_0000 | frame, win.CW_USEDEFAULT, win.CW_USEDEFAULT, self.dpi.pixels(width), self.dpi.pixels(height), parent, null, wc.hInstance, self) orelse
            return error.CreateSupportDialog;
        self.font = try windows.GuiFont.init(self.dpi);
    }

    fn close(self: *Dialog) void {
        if (self.window != null) _ = win.DestroyWindow(self.window);
        if (self.editor) |editor| editor.baseline.deinit();
        if (self.item_choices) |*choices| choices.arena.deinit();
        self.font.deinit();
        self.window = null;
    }

    fn draft(self: *const Dialog) !ShortcutDraft {
        var result: ShortcutDraft = undefined;
        for (self.edits, &result.keys, 0..) |edit, *value, i| {
            value.* = windows.text(edit, allocator) catch |failure| {
                for (result.keys[0..i]) |owned| allocator.free(owned);
                return failure;
            };
        }
        return result;
    }

    fn readFailure(self: *const Dialog) void {
        windows.setText(self.key_status, "変更したキーを読み取れませんでした。");
        _ = win.EnableWindow(self.save, 0);
    }

    fn itemSelection(self: *const Dialog) ?[2]usize {
        const choices = self.item_choices orelse return null;
        const first = comboChoice(self.slots[0]) orelse return null;
        const second = comboChoice(self.slots[1]) orelse return null;
        if (first >= choices.ids.len or second >= choices.ids.len) return null;
        return .{ first, second };
    }

    fn itemsDirty(self: *const Dialog) bool {
        const current = self.itemSelection() orelse return false;
        return !std.meta.eql(current, self.item_choices.?.baseline);
    }

    fn askDiscard(self: *Dialog, comptime prompt: []const u8) bool {
        return win.MessageBoxW(self.window, windows.wide(prompt), windows.wide("ショートカットを管理"), win.MB_YESNO | win.MB_ICONQUESTION | win.MB_DEFBUTTON2) == win.IDYES;
    }

    fn requestClose(self: *Dialog) void {
        if (self.finishing) return;
        self.finishing = true;
        defer self.finishing = false;
        if (self.editor) |editor| {
            const pending = self.draft() catch return self.readFailure();
            defer pending.deinit();
            if ((self.itemsDirty() or !sameKeys(editor.baseline.keys, pending.keys)) and
                !self.askDiscard("未保存の変更を破棄して閉じますか？")) return;
        }
        self.releaseParent();
        _ = win.ShowWindow(self.window, win.SW_HIDE);
    }

    fn saveKeys(self: *Dialog) void {
        const editor = if (self.editor) |*value| value else return;
        if (self.finishing) return;
        self.finishing = true;
        defer self.finishing = false;
        var pending = self.draft() catch return self.readFailure();
        var published = false;
        defer if (!published) pending.deinit();
        if (sameKeys(editor.baseline.keys, pending.keys)) return;
        _ = bindings.validate(pending.keys) catch |failure| {
            windows.setText(self.key_status, keyError(failure));
            return;
        };
        pending.preserveEquivalent(editor.baseline) catch return self.readFailure();
        if (!editor.save(editor.context, self.window, pending.keys)) {
            windows.setText(self.key_status, "キー設定を保存できませんでした。");
            return;
        }
        editor.baseline.deinit();
        editor.baseline = pending;
        published = true;
        for (self.edits, pending.keys) |field, key| windows.setText(field, key);
        self.updateKeys();
        self.updateSlotLabels();
        windows.setText(self.key_status, "キー設定を保存し、反映しました。");
    }

    fn updateKeys(self: *Dialog) void {
        const editor = self.editor orelse return;
        if (self.key_status == null or self.edits[self.edits.len - 1] == null) return;
        const pending = self.draft() catch return self.readFailure();
        defer pending.deinit();
        var chords: [storage.action_count]?bindings.Chord = undefined;
        for (pending.keys, &chords) |key, *chord| chord.* = bindings.parse(key) catch null;
        var dirty = false;
        for (pending.keys, editor.baseline.keys, self.key_states, chords, 0..) |draft_key, saved, state, possible, index| {
            const changed = !sameKey(saved, draft_key);
            dirty = dirty or changed;
            var duplicate = false;
            if (possible) |chord| for (chords, 0..) |other, other_index| {
                if (other_index != index and other != null and chord.eql(other.?)) {
                    duplicate = true;
                    break;
                }
            };
            windows.setText(state, if (duplicate) "重複" else if (changed) "変更あり" else "");
        }
        _ = bindings.validate(pending.keys) catch |failure| {
            _ = win.EnableWindow(self.save, 0);
            windows.setText(self.key_status, keyError(failure));
            return;
        };
        _ = win.EnableWindow(self.save, @intFromBool(dirty));
        windows.setText(self.key_status, if (dirty) "未保存のキー変更があります。" else "キー設定に未保存の変更はありません。");
    }

    fn updateSlotLabels(self: *Dialog) void {
        const editor = self.editor orelse return;
        const choices = self.item_choices orelse return;
        const base = @intFromEnum(if (choices.scope.len == 0) storage.Action.shared1 else storage.Action.profile1);
        for (self.slot_labels, 0..) |label, index| {
            var key_buffer: [40]u8 = undefined;
            const key = bindings.label(bindings.parse(editor.baseline.keys[base + index]) catch null, &key_buffer);
            var text_buffer: [100]u8 = undefined;
            const text = std.fmt.bufPrint(&text_buffer, "枠{d}　{s}", .{ index + 1, key }) catch return;
            windows.setText(label, text);
        }
    }

    fn updateItems(self: *Dialog) void {
        _ = win.EnableWindow(self.save_items, 0);
        const selected = self.itemSelection() orelse return;
        if (selected[0] != 0 and selected[0] == selected[1]) {
            windows.setText(self.item_status, "同じ弾幕を両方のキーには割り当てられません。");
            return;
        }
        const dirty = self.itemsDirty();
        _ = win.EnableWindow(self.save_items, @intFromBool(dirty));
        windows.setText(self.item_status, if (dirty) "未保存の弾幕割当があります。" else "弾幕の割当に未保存の変更はありません。");
    }

    fn loadScope(self: *Dialog, index: usize) !void {
        const editor = self.editor orelse return;
        for (self.slots) |slot| _ = win.EnableWindow(slot, 0);
        _ = win.EnableWindow(self.save_items, 0);
        if (self.item_choices) |*previous| previous.arena.deinit();
        self.item_choices = null;
        const data = editor.snapshot.data;
        if (index > data.profiles.len) return error.ProfileMissing;
        const scope = if (index == 0) "" else data.profiles[index - 1].id;
        const items = try data.itemsFor(scope);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const ids = try memory.alloc([]const u8, items.len + 1);
        ids[0] = "";
        const owner = try memory.dupe(u8, scope);
        var baseline: [2]usize = .{ 0, 0 };
        for (self.slots) |slot| {
            _ = win.SendMessageW(slot, win.CB_RESETCONTENT, 0, 0);
            try addChoice(slot, "未割当");
        }
        for (items, 1..) |item, position| {
            ids[position] = try memory.dupe(u8, item.id);
            for (self.slots) |slot| try addChoice(slot, item.name);
            if (item.slot != 0) baseline[item.slot - 1] = position;
        }
        self.item_choices = .{ .arena = arena, .scope = owner, .scope_index = index, .ids = ids, .baseline = baseline };
        for (self.slots, baseline) |slot, position| {
            _ = win.SendMessageW(slot, win.CB_SETCURSEL, position, 0);
            _ = win.EnableWindow(slot, 1);
        }
        self.updateSlotLabels();
        self.updateItems();
    }

    fn changeScope(self: *Dialog) void {
        if (self.finishing) return;
        const index = comboChoice(self.scope) orelse return;
        self.finishing = true;
        defer self.finishing = false;
        if (self.item_choices) |choices| {
            if (index == choices.scope_index) return;
            if (self.itemsDirty() and !self.askDiscard("未保存の弾幕割当を破棄して対象を変更しますか？")) {
                _ = win.SendMessageW(self.scope, win.CB_SETCURSEL, choices.scope_index, 0);
                return;
            }
        }
        self.loadScope(index) catch windows.setText(self.item_status, "弾幕の候補を更新できませんでした。対象を選び直してください。");
    }

    fn saveItems(self: *Dialog) void {
        const editor = self.editor orelse return;
        if (self.finishing) return;
        const choices = if (self.item_choices) |*value| value else return;
        const selected = self.itemSelection() orelse return;
        if (comboChoice(self.scope) != choices.scope_index or !self.itemsDirty() or
            (selected[0] != 0 and selected[0] == selected[1])) return;
        self.finishing = true;
        defer self.finishing = false;
        if (!editor.save_items(editor.context, self.window, choices.scope, choices.ids[selected[0]], choices.ids[selected[1]])) {
            windows.setText(self.item_status, "弾幕の割当を保存できませんでした。");
            return;
        }
        choices.baseline = selected;
        self.updateItems();
        windows.setText(self.item_status, "弾幕の割当を保存しました。");
    }

    fn place(self: Dialog, hwnd: win.HWND, x: c_int, y: c_int, width: c_int, height: c_int) void {
        self.viewport.place(self.dpi, hwnd, x, y, width, height);
    }

    fn resize(self: *Dialog) void {
        if (self.cancel == null) return;
        self.viewport.arrange(self.window, self, placeControls);
    }

    fn placeControls(self: *Dialog) void {
        const is_document = self.document != null;
        const content = self.viewport.layout(self.window, self.dpi, .{
            .width = if (is_document) 344 else 408,
            .height = if (is_document) 178 else 700,
        }, null) orelse return;
        const width = self.dpi.fittingUnits(content.width);
        const footer = self.dpi.fittingUnits(content.height) - 44;
        if (is_document) {
            self.place(self.document, 12, 12, width - 24, footer - 20);
            self.place(self.reset, 12, footer, 213, 30);
            self.place(self.cancel, width - 104, footer, 92, 30);
            return;
        }
        const input_width = @min(166, @divTrunc(width, 3));
        const input_x = width - 100 - input_width;
        self.place(self.instructions, 16, 12, width - 32, 34);
        for (self.labels, self.edits, self.key_states, 0..) |label, edit, state, index| {
            const y: c_int = @intCast(50 + index * 30);
            self.place(label, 16, y + 3, input_x - 24, 25);
            self.place(edit, input_x, y, input_width, 24);
            self.place(state, width - 90, y + 3, 74, 24);
        }
        self.place(self.key_status, 16, 386, width - 32, 40);
        self.place(self.save, 16, 430, 146, 30);
        self.place(self.reset, 172, 430, 148, 30);
        self.place(self.item_heading, 16, 476, width - 32, 24);
        const column = @divTrunc(width - 42, 2);
        self.place(self.scope, 16, 505, width - 32, 176);
        for (self.slot_labels, self.slots, 0..) |label, slot, i| {
            const x = 16 + @as(c_int, @intCast(i)) * (column + 10);
            self.place(label, x, 543, column, 22);
            self.place(slot, x, 567, column, 176);
        }
        self.place(self.save_items, 16, 609, 155, 30);
        self.place(self.item_status, 182, 604, width - 198, 42);
        self.place(self.cancel, width - 106, footer, 90, 30);
    }

    fn releaseParent(self: *Dialog) void {
        const parent = self.disabled_parent orelse return;
        self.disabled_parent = null;
        if (win.IsWindow(parent) == 0) return;
        const owned = win.GetForegroundWindow() == self.window;
        _ = win.EnableWindow(parent, 1);
        if (!owned or win.IsWindowVisible(parent) == 0 or win.IsWindowEnabled(parent) == 0) return;
        const current = win.GetForegroundWindow();
        if (current != self.window and current != parent) return;
        _ = win.SetForegroundWindow(parent);
        const focus = self.original_focus;
        if (win.GetForegroundWindow() == parent and focus != null and win.IsChild(parent, focus) != 0 and
            win.IsWindowVisible(focus) != 0 and win.IsWindowEnabled(focus) != 0) _ = win.SetFocus(focus);
    }

    fn run(self: *Dialog, parent: win.HWND) !void {
        self.font.applyChildren(self.window);
        windows.fitWindow(self.window, parent);
        self.resize();
        if (parent != null and win.IsWindowEnabled(parent) != 0) {
            self.disabled_parent = parent;
            self.original_focus = win.GetFocus();
            _ = win.EnableWindow(parent, 0);
        }
        defer self.releaseParent();
        _ = win.ShowWindow(self.window, win.SW_SHOW);
        _ = win.SetForegroundWindow(self.window);
        _ = win.SetFocus(if (self.document != null) self.document else self.edits[0]);
        var message: win.MSG = undefined;
        while (win.IsWindowVisible(self.window) != 0) {
            const received = win.GetMessageW(&message, null, 0, 0);
            if (received == -1) return error.SupportMessageLoop;
            if (received == 0) {
                win.PostQuitMessage(@intCast(message.wParam));
                return;
            }
            if (self.scrollShortcutsWithWheel(message)) continue;
            if (self.capture(message)) continue;
            if (message.message == win.WM_KEYDOWN and message.wParam == win.VK_ESCAPE and
                (message.hwnd == self.window or win.IsChild(self.window, message.hwnd) != 0))
            {
                self.requestClose();
                continue;
            }
            const tab = message.message == win.WM_KEYDOWN and message.wParam == win.VK_TAB;
            if (win.IsDialogMessageW(self.window, &message) != 0) {
                if (tab and self.viewport.revealFocus(self.window)) self.resize();
                continue;
            }
            _ = win.TranslateMessage(&message);
            _ = win.DispatchMessageW(&message);
        }
    }

    fn scrollShortcutsWithWheel(self: *Dialog, message: win.MSG) bool {
        if (self.editor == null or message.message != win.WM_MOUSEWHEEL or
            (message.hwnd != self.window and win.IsChild(self.window, message.hwnd) == 0)) return false;
        // The key fields correspond to the legacy Hotkey controls. The
        // multiline document's own wheel handling is outside this editor.
        if (self.viewport.wheel(self.window, message.wParam)) self.resize();
        return true;
    }

    fn capture(self: *Dialog, message: win.MSG) bool {
        if (message.message != win.WM_KEYDOWN and message.message != win.WM_SYSKEYDOWN) return false;
        const focused = win.GetFocus();
        for (self.edits, 0..) |edit, index| {
            if (edit == null or edit != focused) continue;
            if (message.wParam == win.VK_ESCAPE and index == @intFromEnum(storage.Action.stop)) {
                windows.setText(edit, "Esc");
                return true;
            }
            const ctrl = win.GetKeyState(win.VK_CONTROL) < 0;
            const alt = win.GetKeyState(win.VK_MENU) < 0;
            const shift = win.GetKeyState(win.VK_SHIFT) < 0;
            if (!ctrl or !(alt or shift)) return false;
            var key: [3]u8 = undefined;
            const suffix = switch (message.wParam) {
                'A'...'Z', '0'...'9' => blk: {
                    key[0] = std.ascii.toLower(@intCast(message.wParam));
                    break :blk key[0..1];
                },
                win.VK_F1...win.VK_F12 => std.fmt.bufPrint(&key, "F{d}", .{message.wParam - win.VK_F1 + 1}) catch return false,
                else => return false,
            };
            var output: [7]u8 = undefined;
            const value = std.fmt.bufPrint(&output, "^{s}{s}{s}", .{ if (alt) "!" else "", if (shift) "+" else "", suffix }) catch return false;
            windows.setText(edit, value);
            return true;
        }
        return false;
    }
};

fn handle(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    if (message == win.WM_NCCREATE) {
        const parameters: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(parameters.lpCreateParams)));
    }
    const pointer: usize = @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA));
    if (pointer == 0) return win.DefWindowProcW(hwnd, message, wparam, lparam);
    const dialog: *Dialog = @ptrFromInt(pointer);
    if (message == win.WM_CLOSE) {
        dialog.requestClose();
        return 0;
    }
    if (message == win.WM_SIZE) {
        if (!dialog.viewport.updating and wparam != win.SIZE_MINIMIZED) {
            const revision = dialog.viewport.scroll_revision;
            dialog.resize();
            if (revision == dialog.viewport.scroll_revision and dialog.viewport.revealFocus(hwnd)) dialog.resize();
        }
        return 0;
    }
    if (message == win.WM_GETMINMAXINFO and dialog.editor != null) {
        const limits: *win.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
        viewport.minimumTrack(hwnd, dialog.dpi, limits);
        return 0;
    }
    if (message == viewport.wm_reflow) {
        if (dialog.viewport.takeReflow(hwnd)) dialog.resize();
        return 0;
    }
    if (message == viewport.wm_focus_changed) {
        if (dialog.viewport.revealFocus(hwnd)) dialog.resize();
        return 0;
    }
    if ((message == win.WM_HSCROLL or message == win.WM_VSCROLL) and lparam == 0) {
        if (dialog.viewport.scroll(hwnd, if (message == win.WM_HSCROLL) win.SB_HORZ else win.SB_VERT, wparam, dialog.dpi)) dialog.resize();
        return 0;
    }
    if (message == win.WM_COMMAND) {
        const command = windows.low(wparam);
        const notification = windows.high(wparam);
        switch (command) {
            ok_id => dialog.saveKeys(),
            cancel_id => dialog.requestClose(),
            reset_id => if (dialog.document != null) {
                if (dialog.reset != null and !dialog.finishing) {
                    _ = win.SendMessageW(dialog.document, win.EM_SETSEL, 0, -1);
                    _ = win.SendMessageW(dialog.document, win.WM_COPY, 0, 0);
                }
            } else if (!dialog.finishing) {
                for (dialog.edits, storage.default_shortcut_keys) |edit, key| windows.setText(edit, key);
                dialog.updateKeys();
            },
            100...(100 + storage.action_count - 1) => if (notification == win.EN_CHANGE and !dialog.finishing) dialog.updateKeys(),
            scope_id => if (notification == win.CBN_SELCHANGE) dialog.changeScope(),
            first_slot_id, second_slot_id => if (notification == win.CBN_SELCHANGE and !dialog.finishing) dialog.updateItems(),
            save_items_id => dialog.saveItems(),
            else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
        }
        return 0;
    }
    return win.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn control(parent: win.HWND, comptime kind: []const u8, text: []const u8, id: usize, styles: win.DWORD) !win.HWND {
    const common: win.DWORD = win.WS_CHILD | win.WS_VISIBLE;
    const hwnd = win.CreateWindowExW(0, windows.wide(kind), windows.wide(""), common | styles, 0, 0, 1, 1, parent, if (id == 0) null else @ptrFromInt(id), win.GetModuleHandleW(null), null) orelse return error.CreateSupportControl;
    windows.setText(hwnd, text);
    try viewport.trackFocus(hwnd, parent, styles);
    return hwnd;
}

pub fn shortcuts(parent: win.HWND, snapshot: *const storage.Snapshot, context: *anyopaque, save: ShortcutSaver, save_items: ShortcutItemSaver) !void {
    const current_keys = snapshot.data.preferences.shortcut_keys;
    var dialog: Dialog = .{ .editor = .{
        .baseline = try ShortcutDraft.copy(current_keys),
        .snapshot = snapshot,
        .context = context,
        .save = save,
        .save_items = save_items,
    } };
    defer dialog.close();
    try dialog.open(parent, "ショートカットを管理", 560, 748);
    dialog.instructions = try control(dialog.window, "STATIC", "欄を選んでCtrl＋AltまたはCtrl＋Shiftを押しながらキーを入力します。", 0, 0);
    for (action_labels, current_keys, &dialog.labels, &dialog.edits, &dialog.key_states, 0..) |label, value, *label_window, *edit, *state, index| {
        label_window.* = try control(dialog.window, "STATIC", label, 0, 0);
        edit.* = try control(dialog.window, "EDIT", value, index + 100, win.WS_TABSTOP | win.WS_BORDER | win.ES_AUTOHSCROLL);
        state.* = try control(dialog.window, "STATIC", "", index + 300, 0);
    }
    dialog.key_status = try control(dialog.window, "STATIC", "", key_status_id, 0);
    dialog.save = try control(dialog.window, "BUTTON", "キー設定を保存", ok_id, win.WS_TABSTOP | win.BS_DEFPUSHBUTTON);
    dialog.reset = try control(dialog.window, "BUTTON", "標準の割当に戻す", reset_id, win.WS_TABSTOP);
    dialog.item_heading = try control(dialog.window, "STATIC", "弾幕キーで入力する内容", 0, 0);
    const combo_flags = win.CBS_DROPDOWNLIST | win.WS_VSCROLL | win.WS_TABSTOP;
    dialog.scope = try control(dialog.window, "COMBOBOX", "", scope_id, combo_flags);
    try addChoice(dialog.scope, "共通の弾幕");
    for (snapshot.data.profiles) |profile| try addChoice(dialog.scope, profile.name);
    for (&dialog.slot_labels, &dialog.slots, 0..) |*label, *slot, i| {
        label.* = try control(dialog.window, "STATIC", "", 0, 0);
        slot.* = try control(dialog.window, "COMBOBOX", "", first_slot_id + i, combo_flags);
    }
    dialog.save_items = try control(dialog.window, "BUTTON", "弾幕の割当を保存", save_items_id, win.WS_TABSTOP);
    dialog.item_status = try control(dialog.window, "STATIC", "", item_status_id, 0);
    dialog.cancel = try control(dialog.window, "BUTTON", "閉じる", cancel_id, win.WS_TABSTOP);
    _ = win.SendMessageW(dialog.scope, win.CB_SETCURSEL, 0, 0);
    try dialog.loadScope(0);
    dialog.updateKeys();
    try dialog.run(parent);
}

pub fn document(parent: win.HWND, comptime title: []const u8, value: []const u8, allow_copy: bool) !void {
    const text = try std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
    defer allocator.free(text);
    var dialog: Dialog = .{};
    defer dialog.close();
    try dialog.open(parent, title, 604, 530);
    dialog.document = try control(dialog.window, "EDIT", "", 100, win.ES_READONLY | win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.WS_BORDER | win.WS_VSCROLL | win.WS_TABSTOP);
    // WM_COPY always reads this completed, read-only document on the UI thread.
    if (win.SetWindowTextW(dialog.document, text) == 0) return error.PaintSupportDocument;
    if (allow_copy) dialog.reset = try control(dialog.window, "BUTTON", "表示中の診断情報をコピー", reset_id, win.WS_TABSTOP);
    dialog.cancel = try control(dialog.window, "BUTTON", "閉じる", cancel_id, win.WS_TABSTOP | win.BS_DEFPUSHBUTTON);
    try dialog.run(parent);
}

pub fn diagnosticDocument(parent: win.HWND, snapshot: diagnostics.Snapshot, comptime version: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    try document(parent, "診断情報", try snapshot.format(&buffer, version), true);
}

pub const help =
    "弾幕を使う\r\nYouTubeのチャット・コメント欄を選んでパレットを開き、弾幕を選びます。弾幕は入力のみです。\r\n\r\n" ++
    "弾幕と配信者の管理\r\n「弾幕を追加・編集」から登録、並べ替え、配信者連携、キー割当を行います。\r\n\r\n" ++
    "リアクション\r\n管理・ヘルプから5種類のボタンを登録し、「送らずに確認」を実行します。開始後の停止には停止キーか停止ボタンを使います。\r\n\r\n" ++
    "終了\r\n×を押しても常駐します。アプリを閉じるには「管理・ヘルプ」の「終了」を使います。";

pub fn selectJson(parent: win.HWND, export_data: bool) !?[]const u8 {
    var name: [32768]u16 = @splat(0);
    if (export_data) {
        const proposed = windows.wide("ChatPalette.json");
        @memcpy(name[0..proposed.len], proposed);
    }
    var params = std.mem.zeroes(win.OPENFILENAMEW);
    params.lStructSize = @sizeOf(win.OPENFILENAMEW);
    params.hwndOwner = parent;
    params.lpstrFilter = windows.wide("ChatPalette JSON (*.json)\x00*.json\x00");
    params.lpstrFile = &name;
    params.nMaxFile = name.len;
    params.lpstrDefExt = windows.wide("json");
    const base_flags: win.DWORD = win.OFN_EXPLORER | win.OFN_PATHMUSTEXIST | win.OFN_NOCHANGEDIR;
    const path_flags: win.DWORD = if (export_data) win.OFN_NOREADONLYRETURN else win.OFN_FILEMUSTEXIST;
    params.Flags = base_flags | path_flags;
    const selected = if (export_data) win.GetSaveFileNameW(&params) else win.GetOpenFileNameW(&params);
    if (selected == 0) {
        if (win.CommDlgExtendedError() != 0) return error.JsonFileDialog;
        return null;
    }
    const end = std.mem.indexOfScalar(u16, &name, 0) orelse return error.JsonFileDialog;
    return try std.unicode.utf16LeToUtf8Alloc(allocator, name[0..end]);
}

test "the key editor honors semantic changes, including invalid unsaved drafts" {
    var draft = storage.default_shortcut_keys;
    draft[0] = "!^Q";
    try std.testing.expect(sameKeys(storage.default_shortcut_keys, draft));
    draft[0] = "q";
    try std.testing.expect(!sameKeys(storage.default_shortcut_keys, draft));
    draft[0] = "^+q";
    try std.testing.expect(!sameKeys(storage.default_shortcut_keys, draft));
}

test "saving a mixed key draft retains the spelling of every unchanged chord" {
    var prior = storage.default_shortcut_keys;
    prior[@intFromEnum(storage.Action.chat_focus)] = "!^F";
    prior[@intFromEnum(storage.Action.stop)] = "eSC";
    const saved = try ShortcutDraft.copy(prior);
    defer saved.deinit();
    var staged = storage.default_shortcut_keys;
    staged[@intFromEnum(storage.Action.profile1)] = "";
    var draft = try ShortcutDraft.copy(staged);
    defer draft.deinit();
    try std.testing.expect(!sameKeys(saved.keys, draft.keys));
    try draft.preserveEquivalent(saved);
    try std.testing.expectEqualStrings("!^F", draft.keys[@intFromEnum(storage.Action.chat_focus)]);
    try std.testing.expectEqualStrings("eSC", draft.keys[@intFromEnum(storage.Action.stop)]);
    try std.testing.expectEqualStrings("", draft.keys[@intFromEnum(storage.Action.profile1)]);
}
