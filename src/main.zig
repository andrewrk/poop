const std = @import("std");
const PERF = std.os.linux.PERF;
const fd_t = std.os.fd_t;
const pid_t = std.os.pid_t;
const assert = std.debug.assert;

const PerfMeasurement = struct {
    name: []const u8,
    config: PERF.COUNT.HW,
};

const perf_measurements = [_]PerfMeasurement{
    .{ .name = "cpu_cycles", .config = PERF.COUNT.HW.CPU_CYCLES },
    .{ .name = "instructions", .config = PERF.COUNT.HW.INSTRUCTIONS },
    .{ .name = "cache_references", .config = PERF.COUNT.HW.CACHE_REFERENCES },
    .{ .name = "cache_misses", .config = PERF.COUNT.HW.CACHE_MISSES },
    .{ .name = "branch_misses", .config = PERF.COUNT.HW.BRANCH_MISSES },
};

const Command = struct {
    argv: []const []const u8,
    measurements: Measurements,

    const Measurements = struct {
        wall_time: Measurement,
        peak_rss: Measurement,
        cpu_cycles: Measurement,
        instructions: Measurement,
        cache_references: Measurement,
        cache_misses: Measurement,
        branch_misses: Measurement,
    };
};

const Sample = struct {
    wall_time: u64,
    cpu_cycles: u64,
    instructions: u64,
    cache_references: u64,
    cache_misses: u64,
    branch_misses: u64,
    peak_rss: u64,
};

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    var commands = std.ArrayList(Command).init(arena);

    for (args[1..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            var cmd_argv = std.ArrayList([]const u8).init(arena);
            try parseCmd(&cmd_argv, arg);
            try commands.append(.{
                .argv = try cmd_argv.toOwnedSlice(),
                .measurements = undefined,
            });
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writeAll(usage_text);
            return std.process.cleanExit();
        }
    }

    var perf_fds = [1]fd_t{-1} ** perf_measurements.len;
    var samples_buf: [10000]Sample = undefined;
    const max_nano_seconds = std.time.ns_per_s * 3;

    var timer = std.time.Timer.start() catch @panic("need timer to work");

    for (commands.items) |*command| {
        const first_start = timer.read();
        var sample_index: usize = 0;
        while ((sample_index < 3 or
            (timer.read() - first_start) < max_nano_seconds) and
            sample_index < samples_buf.len) : (sample_index += 1)
        {
            for (perf_measurements, &perf_fds) |measurement, *perf_fd| {
                var attr: std.os.linux.perf_event_attr = .{
                    .type = PERF.TYPE.HARDWARE,
                    .config = @enumToInt(measurement.config),
                    .flags = .{
                        .disabled = true,
                        .exclude_kernel = true,
                        .exclude_hv = true,
                        .inherit = true,
                        .enable_on_exec = true,
                    },
                };
                perf_fd.* = std.os.perf_event_open(&attr, 0, -1, perf_fds[0], PERF.FLAG.FD_CLOEXEC) catch |err| {
                    std.debug.panic("unable to open perf event: {s}\n", .{@errorName(err)});
                };
            }

            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.DISABLE, PERF.IOC_FLAG_GROUP);
            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.RESET, PERF.IOC_FLAG_GROUP);

            var child = std.process.Child.init(command.argv, arena);

            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.request_resource_usage_statistics = true;

            const start = timer.read();
            try child.spawn();
            const term = try child.wait();
            const end = timer.read();
            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.DISABLE, PERF.IOC_FLAG_GROUP);
            const peak_rss = child.resource_usage_statistics.getMaxRss() orelse 0;

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        std.debug.print("error: exit code {d}\n", .{code});
                        std.process.exit(1);
                    }
                },
                else => {
                    std.debug.print("error: terminated unexpectedly\n", .{});
                    std.process.exit(1);
                },
            }

            samples_buf[sample_index] = .{
                .wall_time = end - start,
                .peak_rss = peak_rss,
                .cpu_cycles = readPerfFd(perf_fds[0]),
                .instructions = readPerfFd(perf_fds[1]),
                .cache_references = readPerfFd(perf_fds[2]),
                .cache_misses = readPerfFd(perf_fds[3]),
                .branch_misses = readPerfFd(perf_fds[4]),
            };
            for (&perf_fds) |*perf_fd| {
                std.os.close(perf_fd.*);
                perf_fd.* = -1;
            }
        }

        const all_samples = samples_buf[0..sample_index];
        const S = struct {
            fn order(context: void, a: Sample, b: Sample) bool {
                _ = context;
                return a.wall_time < b.wall_time;
            }
        };
        // Remove the 2 outliers, always according to wall_time.
        std.mem.sortUnstable(Sample, all_samples, {}, S.order);
        const samples = all_samples[1 .. all_samples.len - 1];

        command.measurements = .{
            .wall_time = Measurement.compute(samples, "wall_time"),
            .peak_rss = Measurement.compute(samples, "peak_rss"),
            .cpu_cycles = Measurement.compute(samples, "cpu_cycles"),
            .instructions = Measurement.compute(samples, "instructions"),
            .cache_references = Measurement.compute(samples, "cache_references"),
            .cache_misses = Measurement.compute(samples, "cache_misses"),
            .branch_misses = Measurement.compute(samples, "branch_misses"),
        };

        {
            std.debug.print("command:", .{});
            for (command.argv) |arg| std.debug.print(" {s}", .{arg});
            std.debug.print(":\n", .{});

            inline for (@typeInfo(Command.Measurements).Struct.fields) |field| {
                const measurement = @field(command.measurements, field.name);
                printMeasurement(measurement, field.name);
            }
        }
    }
}

fn parseCmd(list: *std.ArrayList([]const u8), cmd: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (it.next()) |s| try list.append(s);
}

fn readPerfFd(fd: fd_t) usize {
    var result: usize = 0;
    const n = std.os.read(fd, std.mem.asBytes(&result)) catch |err| {
        std.debug.panic("unable to read perf fd: {s}\n", .{@errorName(err)});
    };
    assert(n == @sizeOf(usize));
    return result;
}

const usage_text =
    \\Usage: poop <command> <command>
    \\
    \\Compares the performance of the provided commands.
;

const Measurement = struct {
    median: u64,
    mean: u64,
    min: u64,
    max: u64,

    fn compute(samples: []const Sample, comptime field: []const u8) Measurement {
        // Compute stats
        var total: u64 = 0;
        var min: u64 = std.math.maxInt(u64);
        var max: u64 = 0;
        for (samples) |s| {
            const v = @field(s, field);
            total += v;
            if (v < min) min = v;
            if (v > max) max = v;
        }
        return .{
            .median = @field(samples[samples.len / 2], field),
            .mean = total / samples.len,
            .min = min,
            .max = max,
        };
    }
};

fn printMeasurement(m: Measurement, name: []const u8) void {
    std.debug.print("  {s}: {d} +/- {d}\n", .{ name, m.mean, (m.max - m.min) / 2 });
}
