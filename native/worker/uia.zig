const std = @import("std");
const rules = @import("rules.zig");

const win = @import("windows.zig");
const sdk = win.sdk;
const object = win.object;
const objectOrNull = win.objectOrNull;
const release = win.release;
const retain = win.retain;
const flag = win.flag;
const string = win.string;

const document = sdk.UIA_DocumentControlTypeId;
pub const Video = [11]u8;
pub const DocumentLookup = enum { foreground, browser_context };
const Address = struct {
    element: *win.Element,
    check_descendant_focus: bool,
};

pub const Window = struct {
    hwnd: usize,
    walker: *win.Walker,
    address: ?Address = null,

    pub fn belongs(self: Window, element: *win.Element) !bool {
        const normalized = try objectOrNull(win.Element, "NormalizeElement", self.walker, .{element});
        if (normalized) |owned| release(owned);
        return normalized != null;
    }
};

pub const Client = struct {
    automation: *win.Automation,
    raw: *win.Walker,
    control: *win.Walker,
    address_controls: *win.Condition,
    focused_descendant: ?*win.Condition = null,
    windows: [16]Window = undefined,
    window_count: usize = 0,

    pub fn init() !Client {
        const automation = try win.acquire();
        errdefer {
            release(automation);
            sdk.CoUninitialize();
        }
        const raw = try object(win.Walker, "get_RawViewWalker", automation, .{});
        errdefer release(raw);
        const control = try object(win.Walker, "get_ControlViewWalker", automation, .{});
        errdefer release(control);
        return .{
            .automation = automation,
            .raw = raw,
            .control = control,
            .address_controls = try addressCondition(automation),
        };
    }

    pub fn deinit(self: *Client) void {
        self.clearWindows();
        if (self.focused_descendant) |condition| release(condition);
        release(self.address_controls);
        release(self.control);
        release(self.raw);
        release(self.automation);
        sdk.CoUninitialize();
    }

    fn clearWindows(self: *Client) void {
        for (self.windows[0..self.window_count]) |window| {
            if (window.address) |address| release(address.element);
            release(window.walker);
        }
        self.window_count = 0;
    }

    pub fn windowFor(self: *Client, hwnd: usize) !*Window {
        for (self.windows[0..self.window_count]) |*window| {
            if (window.hwnd == hwnd) return window;
        }
        const condition = try win.integerCondition(self.automation, sdk.UIA_NativeWindowHandlePropertyId, @bitCast(@as(u32, @truncate(hwnd))));
        defer release(condition);
        const walker = try object(win.Walker, "CreateTreeWalker", self.automation, .{condition});
        if (self.window_count == self.windows.len) self.clearWindows();
        const entry = &self.windows[self.window_count];
        entry.* = .{ .hwnd = hwnd, .walker = walker };
        self.window_count += 1;
        return entry;
    }

    fn addressCondition(automation: *win.Automation) !*win.Condition {
        const edit = try win.integerCondition(automation, sdk.UIA_ControlTypePropertyId, sdk.UIA_EditControlTypeId);
        defer release(edit);
        // Firefox exposes its address input as a ComboBox.
        const combo = try win.integerCondition(automation, sdk.UIA_ControlTypePropertyId, sdk.UIA_ComboBoxControlTypeId);
        defer release(combo);
        const urlbar = try win.textCondition(automation, sdk.UIA_AutomationIdPropertyId, "urlbar-input");
        defer release(urlbar);
        const firefox = try object(win.Condition, "CreateAndCondition", automation, .{ combo, urlbar });
        defer release(firefox);
        return object(win.Condition, "CreateOrCondition", automation, .{ edit, firefox });
    }

    // A page can contain an Edit named "Address". Require the target's native
    // window in the control-view ancestry before crossing any Document boundary.
    fn addressInWindow(self: *Client, element: *win.Element, hwnd: usize) !?Address {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const id = try string(arena.allocator(), "get_CurrentAutomationId", element);
        const name = try string(arena.allocator(), "get_CurrentName", element);
        if (!rules.addressLabel(id, name)) return null;

        var current: ?*win.Element = element;
        var check_descendant_focus = false;
        retain(element);
        defer if (current) |node| release(node);
        for (0..30) |depth| {
            const node = current orelse return null;
            const role = try win.get(i32, "get_CurrentControlType", node, .{});
            if (role == document) return null;
            if (depth == 0) check_descendant_focus = role == sdk.UIA_ComboBoxControlTypeId;
            if (try win.get(sdk.UIA_HWND, "get_CurrentNativeWindowHandle", node, .{}) == @as(sdk.UIA_HWND, @ptrFromInt(hwnd)))
                return .{ .element = element, .check_descendant_focus = check_descendant_focus };
            current = try objectOrNull(win.Element, "GetParentElement", self.control, .{node});
            release(node);
        }
        return null;
    }

    fn currentVideoContext(self: *Client, address: Address) !?rules.VideoContext {
        if (try flag("get_CurrentIsOffscreen", address.element)) return error.StaleAddress;
        if (try flag("get_CurrentHasKeyboardFocus", address.element)) return null;
        if (address.check_descendant_focus) {
            // An editable combo can give keyboard focus to an inner field.
            const condition = self.focused_descendant orelse focus: {
                const value = try win.booleanCondition(self.automation, sdk.UIA_HasKeyboardFocusPropertyId);
                self.focused_descendant = value;
                break :focus value;
            };
            if (try objectOrNull(win.Element, "FindFirst", address.element, .{ sdk.TreeScope_Descendants, condition })) |child| {
                release(child);
                return null;
            }
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        return rules.videoContext(try win.address(arena.allocator(), address.element));
    }

    pub fn readVideo(self: *Client, window: *Window) !?Video {
        const context = (try self.readVideoContext(window)) orelse return null;
        return context.id;
    }

    pub fn readVideoContext(self: *Client, window: *Window) !?rules.VideoContext {
        if (window.address) |address| {
            if (window.belongs(address.element) catch false) {
                // A focused address bar or a non-video URL is a valid empty result.
                if (self.currentVideoContext(address)) |context| return context else |_| {}
            }
            release(address.element);
            window.address = null;
        }
        const root_element = try self.root(window.hwnd);
        defer release(root_element);
        const list = try object(win.Elements, "FindAll", root_element, .{ sdk.TreeScope_Descendants, self.address_controls });
        defer release(list);
        const length = try win.get(i32, "get_Length", list, .{});
        var i: i32 = 0;
        while (i < length) : (i += 1) {
            const element = object(win.Element, "GetElement", list, .{i}) catch continue;
            defer release(element);
            const address = (self.addressInWindow(element, window.hwnd) catch null) orelse continue;
            const context = self.currentVideoContext(address) catch continue;
            retain(element);
            window.address = address;
            return context;
        }
        return null;
    }

    fn isEditor(element: *win.Element) !bool {
        return try flag("get_CurrentIsEnabled", element) and
            !try flag("get_CurrentIsOffscreen", element) and try win.editable(element);
    }

    pub fn inputKind(self: *Client, field: *win.Element, window: *Window) ![]const u8 {
        if (!try window.belongs(field) or !try isEditor(field)) return "";
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const id = try string(allocator, "get_CurrentAutomationId", field);
        const name = try string(allocator, "get_CurrentName", field);
        if (rules.rejectField(id, name)) return "";

        var current: ?*win.Element = field;
        retain(field);
        defer if (current) |node| release(node);
        var chat = false;
        var comment = false;
        for (0..45) |depth| {
            const node = current orelse break;
            const node_id = if (depth == 0) id else try string(allocator, "get_CurrentAutomationId", node);
            const class = try string(allocator, "get_CurrentClassName", node);
            chat = chat or rules.chatAncestor(node_id) or rules.chatAncestor(class);
            comment = comment or rules.commentAncestor(node_id) or rules.commentAncestor(class);
            if (try win.get(i32, "get_CurrentControlType", node, .{}) == document) return rules.classify(id, name, chat, comment);
            if (try win.get(sdk.UIA_HWND, "get_CurrentNativeWindowHandle", node, .{}) == @as(sdk.UIA_HWND, @ptrFromInt(window.hwnd))) break;
            current = try objectOrNull(win.Element, "GetParentElement", self.raw, .{node});
            release(node);
        }
        return "";
    }

    /// Use the outer browser document so an embedded chat keeps the same page identity.
    pub fn documentOf(self: *Client, window: *Window, element: *win.Element) !?*win.Element {
        var current: ?*win.Element = element;
        retain(element);
        defer if (current) |node| release(node);
        var outer: ?*win.Element = null;
        defer if (outer) |node| release(node);
        for (0..60) |_| {
            const node = current orelse return null;
            if (try win.get(i32, "get_CurrentControlType", node, .{}) == document) {
                if (outer) |inner| release(inner);
                retain(node);
                outer = node;
            }
            if (try win.get(sdk.UIA_HWND, "get_CurrentNativeWindowHandle", node, .{}) == @as(sdk.UIA_HWND, @ptrFromInt(window.hwnd))) {
                const result = outer;
                outer = null;
                return result;
            }
            current = try objectOrNull(win.Element, "GetParentElement", self.raw, .{node});
            release(node);
        }
        return null;
    }

    pub fn findDocument(self: *Client, window: *Window, lookup: DocumentLookup) !?*win.Element {
        const hwnd: sdk.HWND = @ptrFromInt(window.hwnd);
        if (sdk.GetForegroundWindow() == hwnd) {
            if (try self.focused()) |focused_element| {
                defer release(focused_element);
                if (!try window.belongs(focused_element)) return null;
                if (try self.documentOf(window, focused_element)) |doc| {
                    errdefer release(doc);
                    if (!try flag("get_CurrentIsOffscreen", doc)) return doc;
                    release(doc);
                    return null;
                }
            }
        } else if (lookup != .browser_context or sdk.IsWindowVisible(hwnd) == 0 or sdk.IsIconic(hwnd) != 0) {
            return null;
        }
        // A background browser or a focused browser toolbar cannot identify a
        // page by global focus. Require one visible outer document in this HWND.
        return self.uniqueVisibleDocument(window);
    }

    fn uniqueVisibleDocument(self: *Client, window: *Window) !?*win.Element {
        const root_element = try self.root(window.hwnd);
        defer release(root_element);
        const condition = try win.integerCondition(self.automation, sdk.UIA_ControlTypePropertyId, document);
        defer release(condition);
        const list = try object(win.Elements, "FindAll", root_element, .{ sdk.TreeScope_Descendants, condition });
        defer release(list);
        const count = try win.get(i32, "get_Length", list, .{});
        var found: ?*win.Element = null;
        defer if (found) |doc| release(doc);
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            const candidate = try object(win.Element, "GetElement", list, .{i});
            defer release(candidate);
            if (try flag("get_CurrentIsOffscreen", candidate)) continue;
            const outer = try self.documentOf(window, candidate) orelse return null;
            var keep = false;
            defer if (!keep) release(outer);
            if (try flag("get_CurrentIsOffscreen", outer)) continue;
            if (found) |previous| {
                if (!try self.same(previous, outer)) return null;
            } else {
                found = outer;
                keep = true;
            }
        }
        const result = found;
        found = null;
        return result;
    }

    pub fn documentIsActive(self: *Client, window: *Window, expected: *win.Element) !bool {
        return self.documentMatches(window, expected, .foreground);
    }

    pub fn documentMatches(self: *Client, window: *Window, expected: *win.Element, lookup: DocumentLookup) !bool {
        const current = try self.findDocument(window, lookup) orelse return false;
        defer release(current);
        return try self.same(expected, current) and
            (lookup == .browser_context or sdk.GetForegroundWindow() == @as(sdk.HWND, @ptrFromInt(window.hwnd)));
    }

    pub fn inDocument(self: *Client, window: *Window, element: *win.Element, expected: *win.Element) !bool {
        const current = try self.documentOf(window, element) orelse return false;
        defer release(current);
        return self.same(expected, current);
    }

    pub fn stillFocused(self: *Client, window: *Window, original: *win.Element, check_editable: bool) !bool {
        const latest = (try self.focused()) orelse return false;
        defer release(latest);
        if (!try self.same(original, latest)) return false;
        if (!try window.belongs(latest)) return false;
        return !check_editable or (try flag("get_CurrentHasKeyboardFocus", latest) and try isEditor(latest));
    }

    pub fn root(self: *Client, hwnd: usize) !*win.Element {
        return object(win.Element, "ElementFromHandle", self.automation, .{@as(sdk.UIA_HWND, @ptrFromInt(hwnd))});
    }

    pub fn focused(self: *Client) !?*win.Element {
        return objectOrNull(win.Element, "GetFocusedElement", self.automation, .{});
    }

    pub fn foreground(self: *Client, window: *Window) !bool {
        const element = (try self.focused()) orelse return false;
        defer release(element);
        return window.belongs(element);
    }

    pub fn same(self: *Client, a: *win.Element, b: *win.Element) !bool {
        return try win.get(sdk.BOOL, "CompareElements", self.automation, .{ a, b }) != sdk.FALSE;
    }

    pub const FocusedInput = struct { kind: []const u8, element: *win.Element };

    pub fn focusedInput(self: *Client, window: *Window) !?FocusedInput {
        const element = (try self.focused()) orelse return null;
        var kept = false;
        defer if (!kept) release(element);
        if (!try flag("get_CurrentHasKeyboardFocus", element)) return null;
        const kind = try self.inputKind(element, window);
        if (kind.len == 0 or !try self.stillFocused(window, element, false)) return null;
        kept = true;
        return .{ .kind = kind, .element = element };
    }
};
