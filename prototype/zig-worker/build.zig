const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    mod.addCSourceFile(.{ .file = b.path("uia_bridge.c") });
    mod.linkSystemLibrary("ole32", .{});
    mod.linkSystemLibrary("oleaut32", .{});
    b.installArtifact(b.addExecutable(.{ .name = "chatpalette-zig-worker", .root_module = mod }));
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "Run protocol and decision-rule tests").dependOn(&tests.step);
}
