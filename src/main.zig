const std = @import("std");

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
    var child = std.process.Child.init(cmd_argv.items, arena);

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.request_resource_usage_statistics = true;

    try child.spawn();
    var timer = try std.time.Timer.start();
    const term = try child.wait();
    const elapsed_ns = timer.read();
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

    std.debug.print("time={d} peak_rss={d}\n", .{
        elapsed_ns, peak_rss,
    });
}

fn parseCmd(list: *std.ArrayList([]const u8), cmd: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (it.next()) |s| try list.append(s);
}

const usage_text =
    \\Usage: poop <command> <command>
    \\
    \\Compares the performance of the provided commands.
;
