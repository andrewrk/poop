const std = @import("std");

pub fn build(b: *std.Build) !void {
    const install_step = b.getInstallStep();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_os = target.result.os.tag;

    const version_str = "0.2.0";
    const version = try std.SemanticVersion.parse(version_str);

    const root_source_file = b.path("src/main.zig");

    // Dependencies
    const scoop_dep_lazy = if (target_os.isDarwin()) b.lazyDependency("scoop", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const scoop_mod = if (scoop_dep_lazy) |scoop_dep| scoop_dep.module("scoop") else undefined;

    // Executable
    const exe_step = b.step("exe", "Run executable");

    const exe = b.addExecutable(.{
        .name = "poop",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = root_source_file,
            .strip = b.option(bool, "strip", "strip the binary"),
        }),
    });
    switch (target_os) {
        .linux => {},
        .macos => exe.root_module.addImport("scoop", scoop_mod),
        else => std.debug.panic("Unsupported OS: {s}", .{@tagName(target_os)}),
    }
    b.installArtifact(exe);

    const exe_run = b.addRunArtifact(exe);
    if (b.args) |args| {
        exe_run.addArgs(args);
    }
    exe_step.dependOn(&exe_run.step);

    // Formatting check
    const fmt_step = b.step("fmt", "Check formatting");

    const fmt = b.addFmt(.{
        .paths = &.{
            "src/",
            "examples/",
            "build.zig",
            "build.zig.zon",
        },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
    install_step.dependOn(fmt_step);

    // Binary release
    const release = b.step("release", "Install and archive release binaries");

    inline for (RELEASE_TRIPLES) |RELEASE_TRIPLE| {
        const RELEASE_NAME = "poop-" ++ version_str ++ "-" ++ RELEASE_TRIPLE;
        const RELEASE_EXE_ARCHIVE_BASENAME = RELEASE_NAME ++ ".tar.xz";

        const release_exe = b.addExecutable(.{
            .name = RELEASE_NAME,
            .version = version,
            .root_module = b.createModule(.{
                .target = b.resolveTargetQuery(try std.Build.parseTargetQuery(.{ .arch_os_abi = RELEASE_TRIPLE })),
                .optimize = .ReleaseSafe,
                .root_source_file = root_source_file,
                .strip = true,
            }),
        });

        const release_exe_install = b.addInstallArtifact(release_exe, .{});

        const release_exe_archive = b.addSystemCommand(&.{ "tar", "-cJf" });
        release_exe_archive.setCwd(release_exe.getEmittedBinDirectory());
        release_exe_archive.setEnvironmentVariable("XZ_OPT", "-9");
        const release_exe_archive_path = release_exe_archive.addOutputFileArg(RELEASE_EXE_ARCHIVE_BASENAME);
        release_exe_archive.addArg(release_exe.out_filename);
        release_exe_archive.step.dependOn(&release_exe_install.step);

        const release_exe_archive_install = b.addInstallFileWithDir(
            release_exe_archive_path,
            .{ .custom = "release" },
            RELEASE_EXE_ARCHIVE_BASENAME,
        );
        release_exe_archive_install.step.dependOn(&release_exe_archive.step);

        release.dependOn(&release_exe_archive_install.step);
    }
}

const RELEASE_TRIPLES = .{
    "aarch64-linux",
    "riscv64-linux",
    "x86-linux",
    "x86_64-linux",
};
