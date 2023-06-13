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

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writeAll(usage_text);
            return std.process.cleanExit();
        }
    }

    const cmd = args[1];
    var cmd_argv = std.ArrayList([]const u8).init(arena);
    try parseCmd(&cmd_argv, cmd);

    var perf_fds = [1]fd_t{-1} ** perf_measurements.len;
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

    var child = std.process.Child.init(cmd_argv.items, arena);

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.request_resource_usage_statistics = true;

    try child.spawn();
    var timer = try std.time.Timer.start();
    const term = try child.wait();
    const elapsed_ns = timer.read();
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

    const cpu_cycles = readPerfFd(perf_fds[0]);
    const instructions = readPerfFd(perf_fds[1]);
    const cache_references = readPerfFd(perf_fds[2]);
    const cache_misses = readPerfFd(perf_fds[3]);
    const branch_misses = readPerfFd(perf_fds[4]);

    std.debug.print("time={d} peak_rss={d} cpu_cycles={d} instructions={d} cache_references={d} cache_misses={d} branch_misses={d}\n", .{
        elapsed_ns, peak_rss, cpu_cycles, instructions, cache_references, cache_misses, branch_misses,
    });
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
