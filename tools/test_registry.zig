const std = @import("std");

pub const Session = enum { headless, desktop };
const Kind = enum {
    source,
    unit,
    browser,
    ime,
    startup,
    transfer,
    worker_lifecycle,

    pub fn usesApplication(self: Kind) bool {
        return self == .browser or self == .startup or self == .transfer or self == .worker_lifecycle;
    }
};
pub const Case = struct {
    name: []const u8,
    session: ?Session,
    executable: []const u8,
    kind: Kind,
    timeout_ms: u32,
};

// These are the executables installed by build.zig, not names from the legacy suite.
pub const cases = [_]Case{
    .{ .name = "app-unit", .session = .headless, .executable = "chatpalette-app-tests.exe", .kind = .unit, .timeout_ms = 180_000 },
    .{ .name = "browser-fixture", .session = .desktop, .executable = "chatpalette-browser-fixture.exe", .kind = .browser, .timeout_ms = 180_000 },
    .{ .name = "ime-input", .session = .desktop, .executable = "chatpalette-ime-input-test.exe", .kind = .ime, .timeout_ms = 30_000 },
    .{ .name = "shortcut-unit", .session = .headless, .executable = "chatpalette-shortcut-tests.exe", .kind = .unit, .timeout_ms = 30_000 },
    .{ .name = "startup", .session = .desktop, .executable = "chatpalette-startup-test.exe", .kind = .startup, .timeout_ms = 180_000 },
    .{ .name = "tools-unit", .session = .headless, .executable = "chatpalette-tools-tests.exe", .kind = .unit, .timeout_ms = 180_000 },
    .{ .name = "transfer", .session = .desktop, .executable = "chatpalette-transfer-test.exe", .kind = .transfer, .timeout_ms = 120_000 },
    .{ .name = "worker-lifecycle", .session = .headless, .executable = "chatpalette-worker-lifecycle-test.exe", .kind = .worker_lifecycle, .timeout_ms = 60_000 },
};

pub fn indexOf(name: []const u8) ?usize {
    const canonical = if (std.mem.eql(u8, name, "brave-fixture")) "browser-fixture" else name;
    for (cases, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, canonical)) return index;
    }
    return null;
}
