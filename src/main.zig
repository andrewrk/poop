const std = @import("std");
const PERF = std.os.linux.PERF;
const fd_t = std.posix.fd_t;
const pid_t = std.os.pid_t;
const assert = std.debug.assert;
const progress = @import("./progress.zig");
const MAX_SAMPLES = 10000;

const usage_text =
    \\Usage: poop [options] <command1> ... <commandN>
    \\
    \\Compares the performance of the provided commands.
    \\
    \\Options:
    \\ -d, --duration <ms>    (default: 5000) how long to repeatedly sample each command
    \\ --color <when>         (default: auto) color output mode
    \\                            available options: 'auto', 'never', 'ansi'
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
    raw_cmd: []const u8,
    argv: []const []const u8,
    measurements: Measurements,
    sample_count: usize,

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

const ColorMode = enum {
    auto,
    never,
    ansi,
};

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    const stdout = std.io.getStdOut();
    var stdout_bw = std.io.bufferedWriter(stdout.writer());
    const stdout_w = stdout_bw.writer();

    var commands = std.ArrayList(Command).init(arena);
    var max_nano_seconds: u64 = std.time.ns_per_s * 5;
    var color: ColorMode = .auto;

    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (!std.mem.startsWith(u8, arg, "-")) {
            var cmd_argv = std.ArrayList([]const u8).init(arena);
            try parseCmd(&cmd_argv, arg);
            try commands.append(.{
                .raw_cmd = arg,
                .argv = try cmd_argv.toOwnedSlice(),
                .measurements = undefined,
                .sample_count = undefined,
            });
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll(usage_text);
            return std.process.cleanExit();
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a duration in milliseconds.\n{s}", .{ arg, usage_text });
                std.process.exit(1);
            }
            const next = args[arg_i];
            const max_ms = std.fmt.parseInt(u64, next, 10) catch |err| {
                std.debug.print("unable to parse --duration argument '{s}': {s}\n", .{
                    next, @errorName(err),
                });
                std.process.exit(1);
            };
            max_nano_seconds = std.time.ns_per_ms * max_ms;
        } else if (std.mem.eql(u8, arg, "--color")) {
            arg_i += 1;
            if (arg_i >= args.len) {
                std.debug.print("'{s}' requires a mode; options are 'auto', 'never', and 'ansi'.\n{s}", .{ arg, usage_text });
                std.process.exit(1);
            }
            const next = args[arg_i];
            if (std.meta.stringToEnum(ColorMode, next)) |when| {
                color = when;
            } else {
                std.debug.print(
                    \\unable to parse --color argument '{s}'
                    \\
                    \\available options are 'auto', 'never' and 'ansi'
                    \\
                , .{next});
                std.process.exit(1);
            }
        } else {
            std.debug.print("unrecognized argument: '{s}'\n{s}", .{ arg, usage_text });
            std.process.exit(1);
        }
    }

    if (commands.items.len == 0) {
        try stdout.writeAll(usage_text);
        std.process.exit(1);
    }

    var bar = try progress.ProgressBar.init(arena, stdout);

    const tty_conf: std.io.tty.Config = switch (color) {
        .auto => std.io.tty.detectConfig(stdout),
        .never => .no_color,
        .ansi => .escape_codes,
    };

    var perf_fds = [1]fd_t{-1} ** perf_measurements.len;
    var samples_buf: [MAX_SAMPLES]Sample = undefined;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_fba = std.heap.FixedBufferAllocator.init(&stderr_buffer);

    var timer = std.time.Timer.start() catch @panic("need timer to work");

    for (commands.items, 1..) |*command, command_n| {
        stderr_fba.reset();

        const max_prog_name_len = 50;
        const prog_name = blk: {
            if (command.raw_cmd.len > max_prog_name_len) {
                break :blk try std.fmt.allocPrint(arena, "'{s}...'", .{command.raw_cmd[0 .. max_prog_name_len - 3]});
            }
            break :blk try std.fmt.allocPrint(arena, "'{s}'", .{command.raw_cmd});
        };
        _ = prog_name;

        const min_samples = 3;

        const first_start = timer.read();
        var sample_index: usize = 0;
        while ((sample_index < min_samples or
            (timer.read() - first_start) < max_nano_seconds) and
            sample_index < samples_buf.len) : (sample_index += 1)
        {
            if (tty_conf != .no_color) try bar.render();
            for (perf_measurements, &perf_fds) |measurement, *perf_fd| {
                var attr: std.os.linux.perf_event_attr = .{
                    .type = PERF.TYPE.HARDWARE,
                    .config = @intFromEnum(measurement.config),
                    .flags = .{
                        .disabled = true,
                        .exclude_kernel = true,
                        .exclude_hv = true,
                        .inherit = true,
                        .enable_on_exec = true,
                    },
                };
                perf_fd.* = std.posix.perf_event_open(&attr, 0, -1, perf_fds[0], PERF.FLAG.FD_CLOEXEC) catch |err| {
                    std.debug.panic("unable to open perf event: {s}\n", .{@errorName(err)});
                };
            }

            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.DISABLE, PERF.IOC_FLAG_GROUP);
            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.RESET, PERF.IOC_FLAG_GROUP);

            var child = std.process.Child.init(command.argv, arena);

            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Pipe;
            child.request_resource_usage_statistics = true;

            const start = timer.read();
            try child.spawn();

            var poller = std.io.poll(stderr_fba.allocator(), enum { stderr }, .{ .stderr = child.stderr.? });
            defer poller.deinit();

            const child_stderr = poller.fifo(.stderr);
            var stderr_truncated = false;

            while (true) {
                const keep_polling = poller.poll() catch {
                    stderr_truncated = true;
                    break;
                };
                if (!keep_polling) break;
            }

            if (stderr_truncated) {
                // continue reading to consume all stderr to prevent deadlocking
                var overflow_buffer: [4096]u8 = undefined;

                while (true) {
                    const amt = child.stderr.?.read(&overflow_buffer) catch break;
                    if (amt == 0) break;
                }
            }

            const term = child.wait() catch |err| {
                std.debug.print("\nerror: Couldn't execute {s}: {s}\n", .{ command.argv[0], @errorName(err) });
                std.process.exit(1);
            };
            const end = timer.read();
            _ = std.os.linux.ioctl(perf_fds[0], PERF.EVENT_IOC.DISABLE, PERF.IOC_FLAG_GROUP);
            const peak_rss = child.resource_usage_statistics.getMaxRss() orelse 0;

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        if (tty_conf != .no_color)
                            bar.clear() catch {};
                        std.debug.print("\nerror: Benchmark {d} command '{s}' failed with exit code {d}:\n", .{
                            command_n,
                            command.raw_cmd,
                            code,
                        });
                        if (stderr_truncated) {
                            std.debug.print(
                                \\────────────── truncated stderr ──────────────
                                \\{s}
                                \\──────────────────────────────────────────────
                                \\
                            ,
                                .{child_stderr.buf[child_stderr.head..][0..child_stderr.count]},
                            );
                        } else {
                            std.debug.print(
                                \\─────────────────── stderr ───────────────────
                                \\{s}
                                \\──────────────────────────────────────────────
                                \\
                            ,
                                .{child_stderr.buf[child_stderr.head..][0..child_stderr.count]},
                            );
                        }
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
                std.posix.close(perf_fd.*);
                perf_fd.* = -1;
            }

            if (tty_conf != .no_color) {
                bar.estimate = est_total: {
                    const cur_samples: u64 = sample_index + 1;
                    const ns_per_sample = (timer.read() - first_start) / cur_samples;
                    const estimate = std.math.divCeil(u64, max_nano_seconds, ns_per_sample) catch unreachable;
                    break :est_total @intCast(@min(MAX_SAMPLES, @max(cur_samples, estimate, min_samples)));
                };
                bar.current += 1;
            }
        }

        if (tty_conf != .no_color) {
            // reset bar for next command
            try bar.clear();
            bar.current = 0;
            bar.estimate = 1;
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
            try stdout_w.writeAll("\n");

            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeAll("  measurement");
            try stdout_w.writeByteNTimes(' ', 23 - "  measurement".len);
            try tty_conf.setColor(stdout_w, .bright_green);
            try stdout_w.writeAll("mean");
            try tty_conf.setColor(stdout_w, .reset);
            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeAll(" ± ");
            try tty_conf.setColor(stdout_w, .green);
            try stdout_w.writeAll("σ");
            try tty_conf.setColor(stdout_w, .reset);

            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeByteNTimes(' ', 12);
            try tty_conf.setColor(stdout_w, .cyan);
            try stdout_w.writeAll("min");
            try tty_conf.setColor(stdout_w, .reset);
            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeAll(" … ");
            try tty_conf.setColor(stdout_w, .magenta);
            try stdout_w.writeAll("max");
            try tty_conf.setColor(stdout_w, .reset);

            try tty_conf.setColor(stdout_w, .bold);
            try stdout_w.writeByteNTimes(' ', 20 - " outliers".len);
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

    try stdout_bw.flush(); // 💩
}

fn parseCmd(list: *std.ArrayList([]const u8), cmd: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (it.next()) |s| try list.append(s);
}

fn readPerfFd(fd: fd_t) usize {
    var result: usize = 0;
    const n = std.posix.read(fd, std.mem.asBytes(&result)) catch |err| {
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
    sample_count: u64,
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
        const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(samples.len));
        var std_dev: f64 = 0;
        for (samples) |s| {
            const v = @field(s, field);
            const delta: f64 = @as(f64, @floatFromInt(v)) - mean;
            std_dev += delta * delta;
        }
        if (samples.len > 1) {
            std_dev /= @floatFromInt(samples.len - 1);
            std_dev = @sqrt(std_dev);
        }

        const q1 = @field(samples[samples.len / 4], field);
        const q3 = if (samples.len < 4) @field(samples[samples.len - 1], field) else @field(samples[samples.len - samples.len / 4], field);
        // Tukey's Fences outliers
        var outlier_count: u64 = 0;
        const iqr: f64 = @floatFromInt(q3 - q1);
        const low_fence = @as(f64, @floatFromInt(q1)) - 1.5 * iqr;
        const high_fence = @as(f64, @floatFromInt(q3)) + 1.5 * iqr;
        for (samples) |s| {
            const v: f64 = @floatFromInt(@field(s, field));
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
            .sample_count = samples.len,
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

    const color_enabled = tty_conf != .no_color;
    const spaces = 32 - ("  (mean  ):".len + name.len + 2);
    try w.writeByteNTimes(' ', spaces);
    try tty_conf.setColor(w, .bright_green);
    try printUnit(fbs.writer(), m.mean, m.unit, m.std_dev, color_enabled);
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);
    try w.writeAll(" ± ");
    try tty_conf.setColor(w, .green);
    try printUnit(fbs.writer(), m.std_dev, m.unit, 0, color_enabled);
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);

    try w.writeByteNTimes(' ', 64 - ("  measurement      ".len + count + 3));
    count = 0;

    try tty_conf.setColor(w, .cyan);
    try printUnit(fbs.writer(), @floatFromInt(m.min), m.unit, m.std_dev, color_enabled);
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);
    try w.writeAll(" … ");
    try tty_conf.setColor(w, .magenta);
    try printUnit(fbs.writer(), @floatFromInt(m.max), m.unit, m.std_dev, color_enabled);
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);

    try w.writeByteNTimes(' ', 46 - (count + 1));
    count = 0;

    const outlier_percent = @as(f64, @floatFromInt(m.outlier_count)) / @as(f64, @floatFromInt(m.sample_count)) * 100;
    if (outlier_percent >= 10)
        try tty_conf.setColor(w, .yellow)
    else
        try tty_conf.setColor(w, .dim);
    try fbs.writer().print("{d: >4.0} ({d: >2.0}%)", .{ m.outlier_count, outlier_percent });
    try w.writeAll(fbs.getWritten());
    count += fbs.pos;
    fbs.pos = 0;
    try tty_conf.setColor(w, .reset);

    try w.writeByteNTimes(' ', 19 - (count + 1));

    // ratio
    if (command_count > 1) {
        if (first_m) |f| {
            const half = blk: {
                const z = getStatScore95(m.sample_count + f.sample_count - 2);
                const n1: f64 = @floatFromInt(m.sample_count);
                const n2: f64 = @floatFromInt(f.sample_count);
                const normer = std.math.sqrt(1.0 / n1 + 1.0 / n2);
                const numer1 = (n1 - 1) * (m.std_dev * m.std_dev);
                const numer2 = (n2 - 1) * (f.std_dev * f.std_dev);
                const df = n1 + n2 - 2;
                const sp = std.math.sqrt((numer1 + numer2) / df);
                break :blk (z * sp * normer) * 100 / f.mean;
            };
            const diff_mean_percent = (m.mean - f.mean) * 100 / f.mean;
            // significant only if full interval is beyond abs 1% with the same sign
            const is_sig = blk: {
                if (diff_mean_percent >= 1 and (diff_mean_percent - half) >= 1) {
                    break :blk true;
                } else if (diff_mean_percent <= -1 and (diff_mean_percent + half) <= -1) {
                    break :blk true;
                } else {
                    break :blk false;
                }
            };
            if (m.mean > f.mean) {
                if (is_sig) {
                    try w.writeAll("💩");
                    try tty_conf.setColor(w, .bright_red);
                } else {
                    try tty_conf.setColor(w, .dim);
                    try w.writeAll("  ");
                }
                try w.writeAll("+");
            } else {
                if (is_sig) {
                    try tty_conf.setColor(w, .bright_yellow);
                    try w.writeAll("⚡");
                    try tty_conf.setColor(w, .bright_green);
                } else {
                    try tty_conf.setColor(w, .dim);
                    try w.writeAll("  ");
                }
                try w.writeAll("-");
            }
            try fbs.writer().print("{d: >5.1}% ± {d: >4.1}%", .{ @abs(diff_mean_percent), half });
            try w.writeAll(fbs.getWritten());
            count += fbs.pos;
            fbs.pos = 0;
        } else {
            try tty_conf.setColor(w, .dim);
            try w.writeAll("0%");
        }
    }

    try tty_conf.setColor(w, .reset);
    try w.writeAll("\n");
}

fn printNum3SigFigs(w: anytype, num: f64) !void {
    if (num >= 1000 or @round(num) == num) {
        try w.print("{d: >4.0}", .{num});
        // TODO Do we need special handling here since it overruns 3 sig figs?
    } else if (num >= 100) {
        try w.print("{d: >4.0}", .{num});
    } else if (num >= 10) {
        try w.print("{d: >3.1}", .{num});
    } else {
        try w.print("{d: >3.2}", .{num});
    }
}

fn printUnit(w: anytype, x: f64, unit: Measurement.Unit, std_dev: f64, color_enabled: bool) !void {
    _ = std_dev; // TODO something useful with this
    const num = x;
    var val: f64 = 0;
    const color: []const u8 = progress.EscapeCodes.dim ++ progress.EscapeCodes.white;
    var ustr: []const u8 = "  ";
    if (num >= 1000_000_000_000) {
        val = num / 1000_000_000_000;
        ustr = switch (unit) {
            .count => "T ",
            .nanoseconds => "ks",
            .bytes => "TB",
        };
    } else if (num >= 1000_000_000) {
        val = num / 1000_000_000;
        ustr = switch (unit) {
            .count => "G ",
            .nanoseconds => "s ",
            .bytes => "GB",
        };
    } else if (num >= 1000_000) {
        val = num / 1000_000;
        ustr = switch (unit) {
            .count => "M ",
            .nanoseconds => "ms",
            .bytes => "MB",
        };
    } else if (num >= 1000) {
        val = num / 1000;
        ustr = switch (unit) {
            .count => "K ",
            .nanoseconds => "us",
            .bytes => "KB",
        };
    } else {
        val = num;
        ustr = switch (unit) {
            .count => "  ",
            .nanoseconds => "ns",
            .bytes => "  ",
        };
    }
    try printNum3SigFigs(w, val);
    if (color_enabled) {
        try w.print("{s}{s}{s}", .{ color, ustr, progress.EscapeCodes.reset });
    } else {
        try w.writeAll(ustr);
    }
}

// Gets either the T or Z score for 95% confidence.
// If no `df` variable is provided, Z score is provided.
pub fn getStatScore95(df: ?u64) f64 {
    if (df) |dff| {
        const dfv: usize = @intCast(dff);
        if (dfv <= 30) {
            return t_table95_1to30[dfv - 1];
        } else if (dfv <= 120) {
            const idx_10s = @divFloor(dfv, 10);
            return t_table95_10s_10to120[idx_10s - 1];
        }
    }
    return 1.96;
}

const t_table95_1to30 = [_]f64{
    12.706,
    4.303,
    3.182,
    2.776,
    2.571,
    2.447,
    2.365,
    2.306,
    2.262,
    2.228,
    2.201,
    2.179,
    2.16,
    2.145,
    2.131,
    2.12,
    2.11,
    2.101,
    2.093,
    2.086,
    2.08,
    2.074,
    2.069,
    2.064,
    2.06,
    2.056,
    2.052,
    2.045,
    2.048,
    2.042,
};

const t_table95_10s_10to120 = [_]f64{
    2.228,
    2.086,
    2.042,
    2.021,
    2.009,
    2,
    1.994,
    1.99,
    1.987,
    1.984,
    1.982,
    1.98,
};
