const std = @import("std");

/// The fixture uses Chromium's CDP transport. Product browser support is separate.
pub const Browser = enum {
    chrome,
    msedge,
    brave,

    pub fn fromPath(path: []const u8) !Browser {
        const name = std.fs.path.basename(path);
        inline for (std.meta.tags(Browser)) |browser| {
            if (std.ascii.eqlIgnoreCase(name, browser.executable())) return browser;
        }
        return error.UnsupportedFixtureBrowser;
    }

    pub fn executable(self: Browser) []const u8 {
        return switch (self) {
            .chrome => "chrome.exe",
            .msedge => "msedge.exe",
            .brave => "brave.exe",
        };
    }

    pub fn runtimeDll(self: Browser) []const u8 {
        return if (self == .msedge) "msedge.dll" else "chrome.dll";
    }

    pub fn label(self: Browser) []const u8 {
        return switch (self) {
            .chrome => "Chrome",
            .msedge => "Edge",
            .brave => "Brave",
        };
    }

    fn installation(self: Browser) []const u8 {
        return switch (self) {
            .chrome => "Google/Chrome/Application",
            .msedge => "Microsoft/Edge/Application",
            .brave => "BraveSoftware/Brave-Browser/Application",
        };
    }
};

pub fn installed(alloc: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |path| {
        _ = try Browser.fromPath(path);
        return std.fs.cwd().realpathAlloc(alloc, path);
    }
    for (std.meta.tags(Browser)) |browser| {
        for ([_][]const u8{ "ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA" }) |variable| {
            const folder = std.process.getEnvVarOwned(alloc, variable) catch continue;
            defer alloc.free(folder);
            const path = try std.fs.path.join(alloc, &.{ folder, browser.installation(), browser.executable() });
            defer alloc.free(path);
            if (std.fs.cwd().realpathAlloc(alloc, path)) |resolved| return resolved else |_| continue;
        }
    }
    return error.FixtureBrowserUnavailable;
}

test "fixture browser selection preserves the executable and its runtime DLL" {
    const testing = std.testing;
    try testing.expectEqual(Browser.chrome, try Browser.fromPath("chrome.exe"));
    try testing.expectEqual(Browser.msedge, try Browser.fromPath("MSEDGE.EXE"));
    try testing.expectEqual(Browser.brave, try Browser.fromPath("brave.exe"));
    try testing.expectEqualStrings("msedge.dll", Browser.msedge.runtimeDll());
    try testing.expectEqualStrings("chrome.dll", Browser.chrome.runtimeDll());
    try testing.expectError(error.UnsupportedFixtureBrowser, Browser.fromPath("firefox.exe"));
}
