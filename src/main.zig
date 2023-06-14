const std = @import("std");
const PERF = std.os.linux.PERF;
const fd_t = std.os.fd_t;
const pid_t = std.os.pid_t;
const assert = std.debug.assert;

const usage_text =
    \\Usage: poop [options] <command1> ... <commandN>
    \\
    \\Compares the performance of the provided commands.
    \\
    \\Options:
    \\
    \\    -h, --help
    \\            Display this help information.
    \\
    \\        --duration <ms>
    \\            (default: 5000) how long to repeatedly sample each command
    \\
    \\    -w, --warmup <num>
    \\            (default: 0) Perform NUM warmup runs before the actual benchmark. This can be used to
    \\            fill caches for I/O-heavy programs.
    \\
;

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
    sample_count: usize,
    run_count: usize,

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

    pub fn lessThanContext(comptime field: []const u8) type {
        return struct {
            fn lessThan(
                _: void,
                lhs: Sample,
                rhs: Sample,
            ) bool {
                return @field(lhs, field) < @field(rhs, field);
            }
        };
    }
};

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    const tty_conf = std.io.tty.detectConfig(std.io.getStdErr());
    const stderr = std.io.getStdErr();
    const stderr_w = stderr.writer();
    const stdout = std.io.getStdOut();
    var stdout_bw = std.io.bufferedWriter(stdout.writer());
    const stdout_w = stdout_bw.writer();

    var commands = std.ArrayList(Command).init(arena);
    var max_nano_seconds: u64 = std.time.ns_per_s * 5;
    var warmup_count: u64 = 0;

    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (!std.mem.startsWith(u8, arg, "-")) {
            var cmd_argv = std.ArrayList([]const u8).init(arena);
            try parseCmd(&cmd_argv, arg);
            try commands.append(.{
                .argv = try cmd_argv.toOwnedSlice(),
                .measurements = undefined,
                .sample_count = undefined,
            });
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll(usage_text);
            return std.process.cleanExit();
        } else if (std.mem.eql(u8, arg, "--duration")) {
            arg_i += 1;
            const next = args[arg_i];
            const max_ms = std.fmt.parseInt(u64, next, 10) catch |err| {
                std.debug.print("unable to parse --duration argument '{s}': {s}\n", .{
                    next, @errorName(err),
                });
                std.process.exit(1);
            };
            max_nano_seconds = std.time.ns_per_ms * max_ms;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warmup")) {
            arg_i += 1;
            const next = args[arg_i];
            warmup_count = std.fmt.parseInt(u64, next, 10) catch |err| {
                std.debug.print("unable to parse --warmup argument '{s}': {s}\n", .{ next, @errorName(err) });
                std.process.exit(1);
            };
        } else {
            std.debug.print("unrecognized argument: '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    var perf_fds = [1]fd_t{-1} ** perf_measurements.len;
    var samples_buf: [10000]Sample = undefined;

    var timer = std.time.Timer.start() catch @panic("need timer to work");

    for (commands.items, 1..) |*command, command_n| {
        for (0..warmup_count) |_| {
            var child = std.process.Child.init(command.argv, arena);

            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            try child.spawn();
            const term = try child.wait();

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
        }

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

        command.measurements = .{
            .wall_time = Measurement.compute(all_samples, "wall_time", .nanoseconds),
            .peak_rss = Measurement.compute(all_samples, "peak_rss", .bytes),
            .cpu_cycles = Measurement.compute(all_samples, "cpu_cycles", .count),
            .instructions = Measurement.compute(all_samples, "instructions", .count),
            .cache_references = Measurement.compute(all_samples, "cache_references", .count),
            .cache_misses = Measurement.compute(all_samples, "cache_misses", .count),
            .branch_misses = Measurement.compute(all_samples, "branch_misses", .count),
        };
        command.sample_count = all_samples.len;

        {
            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.print("Benchmark {d}", .{command_n});
            try tty_conf.setColor(stdout_w, .dim);
            try stdout_w.print(" ({d} runs)", .{command.sample_count});
            try tty_conf.setColor(stdout_w, .reset);
            try stdout_w.writeAll(":");
            for (command.argv) |arg| try stdout_w.print(" {s}", .{arg});
            try stdout_w.writeAll(":\n");

            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeAll("  measurement");
            try stdout_w.writeByteNTimes(' ', 19 - "  measurement".len);
            try tty_conf.setColor(stdout_w, .bright_green);
            try stdout_w.writeAll("mean");
            try tty_conf.setColor(stdout_w, .reset);
            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeAll(" ± ");
            try tty_conf.setColor(stdout_w, .green);
            try stdout_w.writeAll("σ");
            try tty_conf.setColor(stdout_w, .reset);

            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeByteNTimes(' ', 15);
            try tty_conf.setColor(stdout_w, .cyan);
            try stdout_w.writeAll("min");
            try tty_conf.setColor(stdout_w, .reset);
            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeAll(" … ");
            try tty_conf.setColor(stdout_w, .magenta);
            try stdout_w.writeAll("max");
            try tty_conf.setColor(stdout_w, .reset);

            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeByteNTimes(' ', 28 - " outliers".len);
            try tty_conf.setColor(stdout_w, .bright_yellow);
            try stdout_w.writeAll("outliers");
            try tty_conf.setColor(stdout_w, .reset);

            if (commands.items.len >= 2) {
                try tty_conf.setColor(stdout_w, .bold);
                try stdout_w.writeByteNTimes(' ', 9);
                try stdout_w.writeAll("delta");
                try tty_conf.setColor(stdout_w, .reset);
            }

            try stdout_w.writeAll("\n");

            inline for (@typeInfo(Command.Measurements).Struct.fields) |field| {
                const measurement = @field(command.measurements, field.name);
                const first_measurement = if (command_n == 1)
                    null
                else
                    @field(commands.items[0].measurements, field.name);
                try printMeasurement(tty_conf, stdout_w, measurement, field.name, first_measurement, commands.items.len);
            }

            try stdout_bw.flush(); // 💩
        }
    }

    _ = stderr_w;
    try stdout_bw.flush(); // 💩
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

const Measurement = struct {
    q1: u64,
    median: u64,
    q3: u64,
    min: u64,
    max: u64,
    mean: f64,
    std_dev: f64,
    outlier_count: u64,
    outlier_frac: f64,
    unit: Unit,

    const Unit = enum {
        nanoseconds,
        bytes,
        count,
    };

    fn compute(samples: []Sample, comptime field: []const u8, unit: Unit) Measurement {
        std.mem.sort(Sample, samples, {}, Sample.lessThanContext(field).lessThan);
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
        const mean = @intToFloat(f64, total) / @intToFloat(f64, samples.len);
        var std_dev: f64 = 0;
        for (samples) |s| {
            const v = @field(s, field);
            const delta = @intToFloat(f64, v) - mean;
            std_dev += delta * delta;
        }
        if (samples.len > 1) {
            std_dev /= @intToFloat(f64, samples.len - 1);
            std_dev = @sqrt(std_dev);
        }

        const q1 = @field(samples[samples.len / 4], field);
        const q3 = if (samples.len < 4) @field(samples[samples.len - 1], field) else @field(samples[samples.len - samples.len / 4], field);
        // Tukey's Fences outliers
        var outlier_count: u64 = 0;
        const iqr = @intToFloat(f64, q3 - q1);
        const low_fence = @intToFloat(f64, q1) - 1.5 * iqr;
        const high_fence = @intToFloat(f64, q3) + 1.5 * iqr;
        for (samples) |s| {
            const v = @intToFloat(f64, @field(s, field));
            if (v < low_fence or v > high_fence) outlier_count += 1;
        }
        return .{
            .q1 = q1,
            .median = @field(samples[samples.len / 2], field),
            .q3 = q3,
            .mean = mean,
            .min = min,
            .max = max,
            .std_dev = std_dev,
            .outlier_count = outlier_count,
            .outlier_frac = @intToFloat(f64, outlier_count) / @intToFloat(f64, samples.len),
            .unit = unit,
        };
    }
};

fn printMeasurement(
    tty_conf: std.io.tty.Config,
    w: anytype,
    m: Measurement,
    name: []const u8,
    first_m: ?Measurement,
    command_count: usize,
) !void {
    try w.print("  {s}", .{name});

    var buf: [200]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var count: usize = 0;

    const spaces = 30 - ("  (mean  ):".len + name.len + 2);
    try w.writeByteNTimes(' ', spaces);
    try tty_conf.setColor(w, .bright_green);
    try printUnit(fbs.writer(), m.mean, m.unit, m.std_dev);
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);
    try w.writeAll(" ± ");
    try tty_conf.setColor(w, .green);
    try printUnit(fbs.writer(), m.std_dev, m.unit, 0);
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);

    try w.writeByteNTimes(' ', 42 - ("  measurement      ".len + count + 3));
    count = 0;

    try tty_conf.setColor(w, .cyan);
    try printUnit(fbs.writer(), @intToFloat(f64, m.min), m.unit, m.std_dev);
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);
    try w.writeAll(" … ");
    try tty_conf.setColor(w, .magenta);
    try printUnit(fbs.writer(), @intToFloat(f64, m.max), m.unit, m.std_dev);
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);

    try w.writeByteNTimes(' ', 25 - (count + 1));
    count = 0;

    if (m.outlier_frac >= 0.1)
        try tty_conf.setColor(w, .yellow)
    else
        try tty_conf.setColor(w, .dim);
    try fbs.writer().print("{d: >4.0} ({d: >2.0}%)", .{ m.outlier_count, m.outlier_frac * 100 });
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);

    try w.writeByteNTimes(' ', 19 - (count + 1));

    // ratio
    if (command_count > 1) {
        if (first_m) |f| {
            const percent = (m.mean - f.mean) / f.mean;
            const is_sig = @fabs(percent) >= 0.01;
            if (m.mean > f.mean) {
                if (is_sig) {
                    try w.writeAll("💩");
                    try tty_conf.setColor(w, .bright_red);
                } else {
                    try tty_conf.setColor(w, .dim);
                    try w.writeAll("  ");
                }
                try fbs.writer().print("+{d: >4.1}%", .{percent * 100});
                try w.writeAll(fbs.getWritten());
                count += fbs.pos;
                fbs.pos = 0;
            } else {
                if (is_sig) {
                    try tty_conf.setColor(w, .bright_yellow);
                    try w.writeAll("⚡");
                    try tty_conf.setColor(w, .bright_green);
                } else {
                    try tty_conf.setColor(w, .dim);
                    try w.writeAll("  ");
                }
                try fbs.writer().print("-{d: >4.1}%", .{@fabs(percent) * 100});
                try w.writeAll(fbs.getWritten());
                count += fbs.pos;
                fbs.pos = 0;
            }
        } else {
            try tty_conf.setColor(w, .dim);
            try w.writeAll("0%");
        }
    }

    try tty_conf.setColor(w, .reset);
    try w.writeAll("\n");
}

fn printUnit(w: anytype, x: f64, unit: Measurement.Unit, std_dev: f64) !void {
    _ = std_dev; // TODO something useful with this
    const int = @floatToInt(u64, @round(x));
    switch (unit) {
        .count => {
            try w.print("{d}", .{int});
        },
        .nanoseconds => {
            try w.print("{}", .{std.fmt.fmtDuration(int)});
        },
        .bytes => {
            if (int >= 1000_000_000) {
                try w.print("{d}G", .{int / 1000_000_000});
            } else if (int >= 1000_000) {
                try w.print("{d}M", .{int / 1000_000});
            } else if (int >= 1000) {
                try w.print("{d}K", .{int / 1000});
            } else {
                try w.print("{d}B", .{int});
            }
        },
    }
}
