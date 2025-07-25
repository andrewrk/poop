const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "poop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = b.option(bool, "strip", "strip the binary"),
        }),
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
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = .ReleaseSafe,
                .strip = true,
            }),
        });

        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .prefix;
        install.dest_sub_path = b.fmt("{s}-{s}-{s}", .{
            @tagName(t.cpu.arch), @tagName(t.os.tag), rel_exe.name,
        });

        release.dependOn(&install.step);
    }
}

const builtin = @import("builtin");
comptime { // check current Zig version is compatible
    const min: std.SemanticVersion = .{ .major = 0, .minor = 15, .patch = 0 }; // .pre and .build default to null
    const max: std.SemanticVersion = .{ .major = 0, .minor = 15, .patch = 0 };
    const current = builtin.zig_version;
    if (current.order(min) == .lt) {
        const error_message =
            \\Your version of zig is too old ({d}.{d}.{d}).
            \\This project requires Zig minimum version {d}.{d}.{d}.
        ;
        @compileError(std.fmt.comptimePrint(error_message, .{
            current.major,
            current.minor,
            current.patch,
            min.major,
            min.minor,
            min.patch,
        }));
    }
    if (current.order(max) == .gt) {
        const error_message =
            \\Your version of zig is too recent ({d}.{d}.{d}).
            \\This project requires Zig maximum version to be {d}.{d}.{d}.
        ;
        @compileError(std.fmt.comptimePrint(error_message, .{
            current.major,
            current.minor,
            current.patch,
            max.major,
            max.minor,
            max.patch,
        }));
    }
}
