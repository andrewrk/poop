const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "poop",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.strip = b.option(bool, "strip", "strip the binary") orelse switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    b.installArtifact(exe);
}
