const std = @import("std");

const Spinner = struct {
    const Self = @This();
    pub const frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    pub const frame1 = "⠋";
    pub const frame_count = frames.len / frame1.len;

    frame_idx: usize,

    pub fn init() Self {
        return Self{ .frame_idx = 0 };
    }

    pub fn get(self: *const Self) []const u8 {
        return frames[self.frame_idx * frame1.len ..][0..frame1.len];
    }

    pub fn next(self: *Self) void {
        self.frame_idx = (self.frame_idx + 1) % frame_count;
    }
};

const bar = "━";
const half_bar_left = "╸";
const half_bar_right = "╺";
const TIOCGWINSZ: u32 = 0x5413; // https://docs.rs/libc/latest/libc/constant.TIOCGWINSZ.html
const WIDTH_PADDING: usize = 100;

const Winsize = extern struct {
    ws_row: c_ushort,
    ws_col: c_ushort,
    ws_xpixel: c_ushort,
    ws_ypixel: c_ushort,
};

pub fn getScreenWidth(stdout: std.posix.fd_t) usize {
    var winsize: Winsize = undefined;
    _ = std.os.linux.ioctl(stdout, TIOCGWINSZ, @intFromPtr(&winsize));
    return @intCast(winsize.ws_col);
}

pub const EscapeCodes = struct {
    pub const dim = "\x1b[2m";
    pub const pink = "\x1b[38;5;205m";
    pub const white = "\x1b[37m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const green = "\x1b[32m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const reset = "\x1b[0m";
    pub const erase_line = "\x1b[2K\r";
};

pub const ProgressBar = struct {
    const Self = @This();

    spinner: Spinner,
    current: u64,
    estimate: u64,
    stdout: std.fs.File,
    buf: std.ArrayList(u8),
    last_rendered: std.time.Instant,

    pub fn init(allocator: std.mem.Allocator, stdout: std.fs.File) !Self {
        const width = getScreenWidth(stdout.handle);
        const buf = try std.ArrayList(u8).initCapacity(allocator, width + WIDTH_PADDING);
        return Self{
            .spinner = Spinner.init(),
            .last_rendered = try std.time.Instant.now(),
            .current = 0,
            .estimate = 1,
            .stdout = stdout,
            .buf = buf,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buf.deinit();
    }

    /// Clears then renders bar if enough time has passed since last render.
    pub fn render(self: *Self) !void {
        const now = try std.time.Instant.now();
        if (now.since(self.last_rendered) < 50 * std.time.ns_per_ms) {
            return;
        }
        try self.clear();
        self.last_rendered = now;
        const width = getScreenWidth(self.stdout.handle);
        if (width + WIDTH_PADDING > self.buf.capacity) {
            try self.buf.resize(width + WIDTH_PADDING);
        }
        var writer = self.buf.writer();
        const bar_width = width - Spinner.frame1.len - " 10000 runs ".len - " 100% ".len;
        const prog_len = (bar_width * 2) * self.current / self.estimate;
        const full_bars_len: usize = @intCast(prog_len / 2);

        try writer.print("{s}{s}{s} {d: >5} runs ", .{ EscapeCodes.cyan, self.spinner.get(), EscapeCodes.reset, self.current });
        self.spinner.next();

        try writer.print("{s}", .{EscapeCodes.pink}); // pink
        for (0..full_bars_len) |_| {
            try writer.print(bar, .{});
        }
        if (prog_len % 2 == 1) {
            try writer.print(half_bar_left, .{});
        }
        try writer.print("{s}{s}", .{ EscapeCodes.white, EscapeCodes.dim }); // white
        if (prog_len % 2 == 0) {
            try writer.print(half_bar_right, .{});
        }
        for (0..(bar_width - full_bars_len - 1)) |_| {
            try writer.print(bar, .{});
        }
        try writer.print("{s}", .{EscapeCodes.reset}); // reset
        try writer.print(" {d: >3.0}% ", .{
            @as(f64, @floatFromInt(self.current)) * 100 / @as(f64, @floatFromInt(self.estimate)),
        });
        try self.stdout.writeAll(self.buf.items[0..self.buf.items.len]);
    }

    pub fn clear(self: *Self) !void {
        try self.stdout.writeAll(EscapeCodes.erase_line); // clear and reset line
        self.buf.clearRetainingCapacity();
    }
};
