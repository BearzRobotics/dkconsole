const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Drop debug information (default: all builds but Debug)") orelse (optimize != .debug);

    // simd=false leaves out simdutf and highway, which are C++ (spec: Dependencies).
    const dkterm = b.dependency("dkterm", .{ .target = target, .optimize = optimize, .simd = false });
    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", opts);
    mod.addImport("termcore", dkterm.module("termcore"));
    mod.addImport("toml", toml.module("toml"));
    mod.addImport("ghostty-vt", dkterm.module("ghostty-vt"));
    mod.addAnonymousImport("terminus16", .{ .root_source_file = b.path("third_party/terminus/Uni3-Terminus16.psf") });
    mod.addAnonymousImport("terminus24", .{ .root_source_file = b.path("third_party/terminus/Uni3-Terminus24x12.psf") });
    mod.addAnonymousImport("terminus32", .{ .root_source_file = b.path("third_party/terminus/Uni3-Terminus32x16.psf") });
    mod.addImport("truetype", b.createModule(.{ .root_source_file = b.path("src/truetype.zig"), .target = target, .optimize = optimize, .link_libc = true }));

    const exe = b.addExecutable(.{ .name = "dkconsole", .root_module = mod });
    // A rescue system must not need a dynamic loader.
    if (target.result.abi.isMusl()) exe.linkage = .static;
    b.installArtifact(exe);
    b.installFile("data/config.example.toml", "share/dkconsole/config.example.toml");

    const tests = b.step("test", "Run the tests");
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
