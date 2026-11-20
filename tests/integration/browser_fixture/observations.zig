const std = @import("std");
const files = @import("tool_support").files;
const driver = @import("win.zig");

pub const Event = struct {
    type: []const u8,
    id: []const u8,
    value: ?[]const u8 = null,
    key: ?[]const u8 = null,
    ctrl: ?bool = null,
    alt: ?bool = null,
    shift: ?bool = null,
    meta: ?bool = null,
};
const Reaction = struct { id: []const u8, ms: f64, click_count: u32 };
const Pointer = struct { type: []const u8, id: []const u8, ms: f64, x: f64, y: f64 };
pub const State = struct {
    active: []const u8,
    chat: []const u8,
    search: []const u8,
    comment: []const u8 = "",
    second_chat: ?[]const u8 = null,
    video: []const u8,
    url: []const u8 = "",
    visible: bool = false,
    focused: bool = false,
    retired_chat: ?[]const u8,
    events: []Event,
    reactions: []Reaction,
    pointers: []Pointer,

    pub fn count(self: State, event: []const u8) usize {
        var result: usize = 0;
        for (self.events) |item| if (std.mem.eql(u8, item.type, event)) {
            result += 1;
        };
        return result;
    }

    pub fn noDelivery(self: State) bool {
        return self.count("input") == 0 and self.noEnter();
    }

    pub fn noEnter(self: State) bool {
        for (self.events) |event| {
            if (std.mem.eql(u8, event.type, "Enter") or
                (std.mem.eql(u8, event.type, "keyup") and std.mem.eql(u8, event.key orelse "", "Enter"))) return false;
        }
        return true;
    }
};

pub const Observation = struct {
    at_ms: u64 = 0,
    label: []const u8 = "",
    foreground: usize = 0,
    hwnd: ?usize = null,
    pid: ?u32 = null,
    keys: ?[]const i16 = null,
    modifiers: ?Modifiers = null,
    pointer: ?driver.MouseProof = null,
    text: ?[]const u8 = null,
    state: ?State = null,
};
pub const Modifiers = struct {
    ctrl: bool,
    alt: bool,
    left_ctrl: bool,
    left_alt: bool,

    pub fn all(self: Modifiers, expected: bool) bool {
        return self.ctrl == expected and self.alt == expected and self.left_ctrl == expected and self.left_alt == expected;
    }
};
pub const Case = struct {
    name: []const u8,
    passed: bool = false,
    failure: ?[]const u8 = null,
    observations: std.ArrayList(Observation) = .empty,

    fn serial(value: Case) Serialized {
        return .{ .name = value.name, .passed = value.passed, .failure = value.failure, .observations = value.observations.items };
    }
    const Serialized = struct { name: []const u8, passed: bool, failure: ?[]const u8, observations: []Observation };
};

pub const PageDiagnostic = struct {
    action: []const u8,
    stage: []const u8,
    state: []const u8,
    worker: []const u8,
};
pub const Report = struct {
    passed: bool = false,
    failure: ?[]const u8 = null,
    cleanup_error: ?[]const u8 = null,
    sha256: ?files.HexDigest = null,
    browser_pid: ?u32 = null,
    browser_hwnd: ?usize = null,
    devtools_page_attempts: u32 = 0,
    app_pid: ?u32 = null,
    restarted_app_pid: ?u32 = null,
    browser_exit: ?u32 = null,
    second_browser_exit: ?u32 = null,
    app_exit: ?u32 = null,
    restarted_app_exit: ?u32 = null,
    previous_worker_exit: ?u32 = null,
    cases: std.ArrayList(Case) = .empty,

    pub fn serialized(self: Report, alloc: std.mem.Allocator) !Serialized {
        const run = try alloc.alloc(Case.Serialized, self.cases.items.len);
        for (self.cases.items, run) |item, *slot| slot.* = item.serial();
        return .{
            .passed = self.passed,
            .failure = self.failure,
            .cleanup_error = self.cleanup_error,
            .sha256 = self.sha256,
            .browser_pid = self.browser_pid,
            .browser_hwnd = self.browser_hwnd,
            .devtools_page_attempts = self.devtools_page_attempts,
            .app_pid = self.app_pid,
            .restarted_app_pid = self.restarted_app_pid,
            .browser_exit = self.browser_exit,
            .second_browser_exit = self.second_browser_exit,
            .app_exit = self.app_exit,
            .restarted_app_exit = self.restarted_app_exit,
            .previous_worker_exit = self.previous_worker_exit,
            .run = run,
        };
    }

    const Serialized = struct {
        passed: bool,
        failure: ?[]const u8,
        cleanup_error: ?[]const u8,
        sha256: ?files.HexDigest,
        browser_pid: ?u32,
        browser_hwnd: ?usize,
        devtools_page_attempts: u32,
        app_pid: ?u32,
        restarted_app_pid: ?u32,
        browser_exit: ?u32,
        second_browser_exit: ?u32,
        app_exit: ?u32,
        restarted_app_exit: ?u32,
        previous_worker_exit: ?u32,
        run: []const Case.Serialized,
    };
};
