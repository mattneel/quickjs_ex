const std = @import("std");

pub fn build(b: *std.Build) void {
    // This build.zig is for standalone zig build usage / development.
    // For Elixir NIF compilation, Zigler drives the build via mix compile.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_quickjs_ng = b.dependency("zig_quickjs_ng", .{});
    _ = zig_quickjs_ng;

    const quickjs_lib = b.addLibrary(.{
        .name = "quickjs_ng",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    quickjs_lib.linkLibC();
    quickjs_lib.addIncludePath(b.path("c_src/quickjs_ng"));
    quickjs_lib.installHeader(b.path("c_src/quickjs_ng/quickjs.h"), "quickjs.h");

    quickjs_lib.addCSourceFiles(.{
        .root = b.path("c_src/quickjs_ng"),
        .files = &.{
            "quickjs.c",
            "cutils.c",
            "dtoa.c",
            "libregexp.c",
            "libunicode.c",
        },
        .flags = &.{
            "-D_GNU_SOURCE",
            "-funsigned-char",
            "-fno-omit-frame-pointer",
            "-fno-sanitize=undefined",
            "-fno-sanitize-trap=undefined",
            "-fvisibility=hidden",
        },
    });

    b.installArtifact(quickjs_lib);

    const tests = b.addTest(.{
        .root_source_file = b.path("test_ping.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run standalone zig smoke tests.");
    test_step.dependOn(&run_tests.step);
}
