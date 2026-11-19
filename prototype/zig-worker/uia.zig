const std = @import("std");
const rules = @import("rules.zig");

// The bridge uses the COM interface definitions shipped with Zig's MinGW headers.
// Returned objects own one reference, including when they refer to the same element.
const Object = opaque {};
const HResult = i32;
const Bstr = ?[*]u16;
extern fn cp_client(*?*Object) HResult;
extern fn cp_uninit() void;
extern fn cp_release(*Object) void;
extern fn cp_retain(*Object) void;
extern fn cp_free_string(Bstr) void;
extern fn cp_string_length(Bstr) u32;
extern fn cp_edit_condition(*Object, *?*Object) HResult;
extern fn cp_window_walker(*Object, usize, *?*Object) HResult;
extern fn cp_raw(*Object, *?*Object) HResult;
extern fn cp_control(*Object, *?*Object) HResult;
extern fn cp_root(*Object, usize, *?*Object) HResult;
extern fn cp_focused(*Object, *?*Object) HResult;
extern fn cp_same(*Object, *Object, *Object, *i32) HResult;
extern fn cp_normalize(*Object, *Object, *?*Object) HResult;
extern fn cp_parent(*Object, *Object, *?*Object) HResult;
extern fn cp_find_edits(*Object, *Object, *?*Object) HResult;
extern fn cp_length(*Object, *i32) HResult;
extern fn cp_at(*Object, i32, *?*Object) HResult;
extern fn cp_hwnd(*Object, *usize) HResult;
extern fn cp_type(*Object, *i32) HResult;
extern fn cp_id(*Object, *Bstr) HResult;
extern fn cp_name(*Object, *Bstr) HResult;
extern fn cp_class(*Object, *Bstr) HResult;
extern fn cp_has_focus(*Object, *i32) HResult;
extern fn cp_enabled(*Object, *i32) HResult;
extern fn cp_hidden(*Object, *i32) HResult;
extern fn cp_editable(*Object, *i32) HResult;
extern fn cp_address_value(*Object, *Bstr) HResult;

fn check(hr: HResult) !void {
    if (hr < 0) return error.AutomationUnavailable;
}

fn objectOrNull(comptime method: anytype, args: anytype) !?*Object {
    var result: ?*Object = null;
    try check(@call(.auto, method, args ++ .{&result}));
    return result;
}

fn object(comptime method: anytype, args: anytype) !*Object {
    return (try objectOrNull(method, args)) orelse error.AutomationUnavailable;
}

fn scalar(comptime T: type, comptime method: anytype, args: anytype) !T {
    var result: T = 0;
    try check(@call(.auto, method, args ++ .{&result}));
    return result;
}

fn flag(comptime method: anytype, element: *Object) !bool {
    return try scalar(i32, method, .{element}) != 0;
}

fn string(allocator: std.mem.Allocator, comptime method: anytype, element: *Object) ![]const u8 {
    var result: Bstr = null;
    try check(method(element, &result));
    defer cp_free_string(result);
    const ptr = result orelse return "";
    return std.unicode.utf16LeToUtf8Alloc(allocator, ptr[0..cp_string_length(result)]);
}

const document = 50030; // UIA_DocumentControlTypeId
const Window = struct {
    hwnd: usize,
    walker: *Object,
    address: ?*Object = null,

    fn belongs(self: Window, element: *Object) !bool {
        const normalized = try objectOrNull(cp_normalize, .{ self.walker, element });
        if (normalized) |owned| cp_release(owned);
        return normalized != null;
    }
};

pub const Result = struct {
    state: []const u8 = "unavailable",
    video: [11]u8 = .{0} ** 11,
    has_video: bool = false,
    detail: []const u8 = "",
};

pub const Client = struct {
    automation: *Object,
    raw: *Object,
    control: *Object,
    edits: *Object,
    windows: [16]Window = undefined,
    window_count: usize = 0,

    pub fn init() !Client {
        const automation = try object(cp_client, .{});
        errdefer {
            cp_release(automation);
            cp_uninit();
        }
        const raw = try object(cp_raw, .{automation});
        errdefer cp_release(raw);
        const control = try object(cp_control, .{automation});
        errdefer cp_release(control);
        return .{
            .automation = automation,
            .raw = raw,
            .control = control,
            .edits = try object(cp_edit_condition, .{automation}),
        };
    }

    pub fn deinit(self: *Client) void {
        self.clearWindows();
        cp_release(self.edits);
        cp_release(self.control);
        cp_release(self.raw);
        cp_release(self.automation);
        cp_uninit();
    }

    fn clearWindows(self: *Client) void {
        for (self.windows[0..self.window_count]) |window| {
            if (window.address) |address| cp_release(address);
            cp_release(window.walker);
        }
        self.window_count = 0;
    }

    fn windowFor(self: *Client, hwnd: usize) !*Window {
        for (self.windows[0..self.window_count]) |*window| {
            if (window.hwnd == hwnd) return window;
        }
        const walker = try object(cp_window_walker, .{ self.automation, hwnd });
        if (self.window_count == self.windows.len) self.clearWindows();
        const entry = &self.windows[self.window_count];
        entry.* = .{ .hwnd = hwnd, .walker = walker };
        self.window_count += 1;
        return entry;
    }

    // A page can contain an Edit named "Address". Require the target's native
    // window in the control-view ancestry before crossing any Document boundary.
    fn isAddress(self: *Client, element: *Object, hwnd: usize) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const id = try string(arena.allocator(), cp_id, element);
        const name = try string(arena.allocator(), cp_name, element);
        if (!rules.addressLabel(id, name)) return false;

        var current: ?*Object = element;
        cp_retain(element);
        defer if (current) |node| cp_release(node);
        for (0..30) |_| {
            const node = current orelse return false;
            if (try scalar(i32, cp_type, .{node}) == document) return false;
            if (try scalar(usize, cp_hwnd, .{node}) == hwnd) return true;
            current = try objectOrNull(cp_parent, .{ self.control, node });
            cp_release(node);
        }
        return false;
    }

    fn currentVideo(address: *Object) !?[11]u8 {
        if (try flag(cp_hidden, address)) return error.StaleAddress;
        if (try flag(cp_has_focus, address)) return null;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        return rules.videoId(try string(arena.allocator(), cp_address_value, address));
    }

    fn readVideo(self: *Client, window: *Window) !?[11]u8 {
        if (window.address) |address| {
            if (window.belongs(address) catch false) {
                // A focused address bar or a non-video URL is a valid empty result.
                if (currentVideo(address)) |video| return video else |_| {}
            }
            cp_release(address);
            window.address = null;
        }
        const root = try object(cp_root, .{ self.automation, window.hwnd });
        defer cp_release(root);
        const list = try object(cp_find_edits, .{ root, self.edits });
        defer cp_release(list);
        const length = try scalar(i32, cp_length, .{list});
        var i: i32 = 0;
        while (i < length) : (i += 1) {
            const element = object(cp_at, .{ list, i }) catch continue;
            defer cp_release(element);
            if (!(self.isAddress(element, window.hwnd) catch false)) continue;
            const video = currentVideo(element) catch continue;
            cp_retain(element);
            window.address = element;
            return video;
        }
        return null;
    }

    fn isFocusedEditor(element: *Object) !bool {
        return try flag(cp_has_focus, element) and try flag(cp_enabled, element) and
            !try flag(cp_hidden, element) and try flag(cp_editable, element);
    }

    fn inputKind(self: *Client, field: *Object, window: *Window) ![]const u8 {
        if (!try window.belongs(field) or !try isFocusedEditor(field)) return "";
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const id = try string(allocator, cp_id, field);
        const name = try string(allocator, cp_name, field);
        if (rules.rejectField(id, name)) return "";

        var current: ?*Object = field;
        cp_retain(field);
        defer if (current) |node| cp_release(node);
        var chat = false;
        var comment = false;
        for (0..45) |depth| {
            const node = current orelse break;
            const node_id = if (depth == 0) id else try string(allocator, cp_id, node);
            const class = try string(allocator, cp_class, node);
            chat = chat or rules.chatAncestor(node_id) or rules.chatAncestor(class);
            comment = comment or rules.commentAncestor(node_id) or rules.commentAncestor(class);
            if (try scalar(i32, cp_type, .{node}) == document) return rules.classify(id, name, chat, comment);
            if (try scalar(usize, cp_hwnd, .{node}) == window.hwnd) break;
            current = try objectOrNull(cp_parent, .{ self.raw, node });
            cp_release(node);
        }
        return "";
    }

    fn stillFocused(self: *Client, window: *Window, original: *Object, check_editable: bool) !bool {
        const latest = (try objectOrNull(cp_focused, .{self.automation})) orelse return false;
        defer cp_release(latest);
        if (try scalar(i32, cp_same, .{ self.automation, original, latest }) == 0) return false;
        if (!try window.belongs(latest)) return false;
        return !check_editable or try isFocusedEditor(latest);
    }

    pub fn inspect(self: *Client, hwnd: usize, verify: bool, expected: []const u8) !Result {
        if (hwnd == 0) return .{};
        const window = try self.windowFor(hwnd);
        const video = (try self.readVideo(window)) orelse return .{};
        var reply = Result{ .state = "ok", .has_video = true, .video = video };
        if (!verify) return reply;
        reply.state = "changed";
        if (expected.len != 0 and !std.mem.eql(u8, &video, expected)) return reply;
        reply.state = "wrong_input";
        const focused = (try objectOrNull(cp_focused, .{self.automation})) orelse return reply;
        defer cp_release(focused);
        const kind = try self.inputKind(focused, window);
        if (kind.len == 0 or !try self.stillFocused(window, focused, false)) return reply;
        reply.state = "changed";
        const latest = (try self.readVideo(window)) orelse return reply;
        if (!std.mem.eql(u8, &latest, &video)) return reply;
        reply.state = "wrong_input";
        if (!try self.stillFocused(window, focused, true)) return reply;
        reply.state = "ok";
        reply.detail = kind;
        return reply;
    }
};
