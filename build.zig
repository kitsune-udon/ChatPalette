const std = @import("std");
const test_registry = @import("tools/test_registry.zig");
const AppTestMode = enum { all, headless, desktop };

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimize mode") orelse .ReleaseSafe;
    const version = b.addOptions();
    version.addOption([]const u8, "version", std.mem.trim(u8, @embedFile("VERSION"), " \r\n\t"));
    const default_test_options = b.addOptions();
    default_test_options.addOption(AppTestMode, "mode", .all);
    const headless_test_options = b.addOptions();
    headless_test_options.addOption(AppTestMode, "mode", .headless);
    const desktop_test_options = b.addOptions();
    desktop_test_options.addOption(AppTestMode, "mode", .desktop);
    const shortcut_domain = b.createModule(.{
        .root_source_file = b.path("src/domain/shortcuts.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app_module = createAppModule(b, target, optimize, version, shortcut_domain, default_test_options);
    const app = b.addExecutable(.{ .name = "ChatPalette", .root_module = app_module });
    app.subsystem = .Windows;
    const app_install = b.addInstallArtifact(app, .{});
    b.getInstallStep().dependOn(&app_install.step);

    const product = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    product.addImport("shortcut_domain", shortcut_domain);
    product.addOptions("app_test_options", default_test_options);
    const tool_support = b.createModule(.{
        .root_source_file = b.path("tools/support.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tools_module = b.createModule(.{
        .root_source_file = b.path("tools/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tools_module.addImport("chatpalette", product);
    for ([_][]const u8{ "version", "advapi32", "ole32", "oleaut32", "user32", "winhttp" }) |library|
        tools_module.linkSystemLibrary(library, .{});
    const tools = b.addExecutable(.{ .name = "chatpalette-tools", .root_module = tools_module });
    const tools_step = b.step("tools", "Build the Zig validation and packaging tools");
    tools_step.dependOn(&b.addInstallArtifact(tools, .{}).step);
    const standalone_tools = [_]struct { name: []const u8, source: []const u8, libraries: []const []const u8 }{
        .{
            .name = "chatpalette-benchmark-ui",
            .source = "tools/desktop_benchmark.zig",
            .libraries = &.{ "user32", "gdi32", "comctl32" },
        },
        .{
            .name = "chatpalette-startup-test",
            .source = "tests/integration/startup_test.zig",
            .libraries = &.{"user32"},
        },
        .{
            .name = "chatpalette-rollback-test",
            .source = "tests/integration/rollback_test.zig",
            .libraries = &.{"user32"},
        },
        .{
            .name = "chatpalette-clean-install-test",
            .source = "tests/integration/clean_install_test.zig",
            .libraries = &.{ "user32", "ole32", "oleaut32" },
        },
        .{
            .name = "chatpalette-transfer-test",
            .source = "tests/integration/transfer_test.zig",
            .libraries = &.{ "user32", "ole32", "oleaut32" },
        },
        .{
            .name = "chatpalette-upgrade-rollback-test",
            .source = "tests/integration/upgrade_rollback_test.zig",
            .libraries = &.{"user32"},
        },
        .{
            .name = "chatpalette-browser-fixture",
            .source = "tests/integration/browser_fixture.zig",
            .libraries = &.{ "user32", "ole32", "oleaut32", "winhttp", "iphlpapi", "ws2_32" },
        },
        .{
            .name = "chatpalette-worker-lifecycle-test",
            .source = "tests/integration/worker_client_lifecycle_test.zig",
            .libraries = &.{"ole32"},
        },
        .{
            .name = "chatpalette-ime-input-test",
            .source = "tests/integration/ime_input_test.zig",
            .libraries = &.{ "user32", "imm32", "ole32", "comctl32", "msctf" },
        },
    };
    var installs: [standalone_tools.len + 3]*std.Build.Step.InstallArtifact = undefined;
    for (standalone_tools, installs[0..standalone_tools.len]) |tool, *install| {
        const module = b.createModule(.{
            .root_source_file = b.path(tool.source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        module.addImport("chatpalette", product);
        module.addImport("tool_support", tool_support);
        for (tool.libraries) |library| module.linkSystemLibrary(library, .{});
        const executable = b.addExecutable(.{ .name = tool.name, .root_module = module });
        install.* = b.addInstallArtifact(executable, .{});
        tools_step.dependOn(&install.*.step);
    }

    const app_tests = b.addTest(.{ .name = "chatpalette-app-tests", .root_module = app_module });
    const headless_app_tests = b.addTest(.{
        .name = "chatpalette-app-headless-tests",
        .root_module = createAppModule(b, target, optimize, version, shortcut_domain, headless_test_options),
    });
    const desktop_app_tests = b.addTest(.{
        .name = "chatpalette-app-desktop-tests",
        .root_module = createAppModule(b, target, optimize, version, shortcut_domain, desktop_test_options),
        .filters = &.{"test.desktop: "},
    });
    b.step("test-app-headless", "Run app unit tests that do not require a desktop").dependOn(&b.addRunArtifact(headless_app_tests).step);
    b.step("test-app-desktop", "Run app unit tests that require a desktop").dependOn(&b.addRunArtifact(desktop_app_tests).step);
    const tool_tests = b.addTest(.{ .name = "chatpalette-tools-tests", .root_module = tools_module });
    const test_step = b.step("test", "Run native tests on Windows x64");
    const shortcut_tests = b.addTest(.{ .name = "chatpalette-shortcut-tests", .root_module = shortcut_domain });
    const run_shortcut_tests = b.addRunArtifact(shortcut_tests);
    const run_tool_tests = b.addRunArtifact(tool_tests);
    b.step("test-shortcuts", "Run shortcut unit tests").dependOn(&run_shortcut_tests.step);
    b.step("test-tools", "Run validation tool unit tests").dependOn(&run_tool_tests.step);
    test_step.dependOn(&run_shortcut_tests.step);
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    test_step.dependOn(&run_tool_tests.step);
    const test_artifacts = b.step("test-artifacts", "Install the native executables for release verification");
    for (installs[standalone_tools.len..], [_]*std.Build.Step.Compile{ app_tests, shortcut_tests, tool_tests }) |*install, executable| {
        install.* = b.addInstallArtifact(executable, .{});
        test_artifacts.dependOn(&install.*.step);
    }

    addFocusedCheck(b, tools, app_install, &installs);
}

fn createAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: *std.Build.Step.Options,
    shortcut_domain: *std.Build.Module,
    test_options: *std.Build.Step.Options,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addOptions("app_info", version);
    module.addOptions("app_test_options", test_options);
    module.addImport("shortcut_domain", shortcut_domain);
    module.addWin32ResourceFile(.{ .file = b.path("src/desktop/app.rc") });
    for ([_][]const u8{ "user32", "shell32", "comctl32", "comdlg32", "gdi32", "ole32", "oleaut32", "winhttp" }) |library|
        module.linkSystemLibrary(library, .{});
    return module;
}

fn addFocusedCheck(
    b: *std.Build,
    tools: *std.Build.Step.Compile,
    app: *std.Build.Step.InstallArtifact,
    artifacts: []const *std.Build.Step.InstallArtifact,
) void {
    const name = b.option([]const u8, "test-case", "Registered native test for the check step");
    const output = b.option([]const u8, "test-results", "New directory for check results");
    const session = b.option(test_registry.Session, "test-session", "Select desktop explicitly for tests that use the current interactive session");
    const browser_exe = b.option([]const u8, "browser-exe", "Path to a browser executable for the browser fixture");
    const legacy_browser_exe = b.option([]const u8, "brave-exe", "Legacy alias for -Dbrowser-exe");
    const check = b.step("check", "Build and run one registered native test with the source check");
    if (name == null or output == null or output.?.len == 0) {
        check.dependOn(&b.addFail("check requires -Dtest-case=<name> and -Dtest-results=<new-dir>").step);
        return;
    }
    const index = test_registry.indexOf(name.?) orelse {
        check.dependOn(&b.addFail(b.fmt("Unknown native test '{s}'. See chatpalette-tools test-list.", .{name.?})).step);
        return;
    };
    const selected = test_registry.cases[index];
    const artifact = for (artifacts) |entry| {
        if (std.mem.eql(u8, entry.dest_sub_path, selected.executable)) break entry;
    } else @panic("A registered native test has no install artifact");

    const run = b.addRunArtifact(tools);
    run.has_side_effects = true;
    run.step.dependOn(&artifact.step);
    if (selected.kind.usesApplication()) run.step.dependOn(&app.step);
    if (selected.kind == .browser and session == null) {
        const browser_path = browser_exe orelse legacy_browser_exe orelse {
            check.dependOn(&b.addFail("The browser fixture runs in Windows Sandbox by default. Pass -Dbrowser-exe=<path-to-browser-exe>.").step);
            return;
        };
        const source = b.addRunArtifact(tools);
        source.has_side_effects = true;
        source.addArgs(&.{ "source-check", b.pathFromRoot(".") });
        run.step.dependOn(&source.step);
        run.addArgs(&.{
            "sandbox-browser",
            b.getInstallPath(.bin, app.dest_sub_path),
            b.getInstallPath(.bin, artifact.dest_sub_path),
            b.pathFromRoot(browser_path),
            b.pathFromRoot(output.?),
        });
    } else {
        const required_session = selected.session.?;
        if ((session orelse .headless) != required_session) {
            check.dependOn(&b.addFail(b.fmt("{s} requires -Dtest-session={s}", .{ selected.name, @tagName(required_session) })).step);
            return;
        }
        run.addArgs(&.{ "test-run", b.pathFromRoot("."), b.getInstallPath(.bin, ""), b.pathFromRoot(output.?), "--name", selected.name, "--session", @tagName(required_session) });
        if (selected.kind == .browser) {
            if (browser_exe orelse legacy_browser_exe) |path| run.addArgs(&.{ "--browser-exe", b.pathFromRoot(path) });
        }
    }
    check.dependOn(&run.step);
}
