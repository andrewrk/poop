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

    const release = b.step("release", "make an upstream binary release");
    const release_targets = &[_][]const u8{
        "aarch64-linux", "x86_64-linux", "x86-linux", "riscv64-linux",
    };
    for (release_targets) |target_string| {
        const rel_exe = b.addExecutable(.{
            .name = "poop",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = std.zig.CrossTarget.parse(.{
                .arch_os_abi = target_string,
            }) catch unreachable,
            .optimize = .ReleaseSafe,
        });
        rel_exe.strip = true;

        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .prefix;
        install.dest_sub_path = b.fmt("{s}-{s}", .{ target_string, rel_exe.name });

        release.dependOn(&install.step);
    }
}
