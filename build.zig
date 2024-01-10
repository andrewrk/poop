const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "poop",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .strip = b.option(bool, "strip", "strip the binary"),
    });

    b.installArtifact(exe);

    const release = b.step("release", "make an upstream binary release");
    const release_targets = [_]std.Target.Query{
        .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .riscv64,
            .os_tag = .linux,
        },
    };
    for (release_targets) |target_query| {
        const resolved_target = b.resolveTargetQuery(target_query);
        const t = resolved_target.result;
        const rel_exe = b.addExecutable(.{
            .name = "poop",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = resolved_target,
            .optimize = .ReleaseSafe,
            .strip = true,
        });

        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .prefix;
        install.dest_sub_path = b.fmt("{s}-{s}-{s}", .{
            @tagName(t.cpu.arch), @tagName(t.os.tag), rel_exe.name,
        });

        release.dependOn(&install.step);
    }
}
