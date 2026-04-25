//! Minimal raw-terminal helpers for the shell-inline picker.

const std = @import("std");

pub const Error = error{
    NotATerminal,
};

pub const Key = enum {
    up,
    down,
    left,
    right,
    enter,
    escape,
    backspace,
    space,
    q,
    ctrl_c,
    other,
};

pub const Terminal = struct {
    const Self = @This();

    overlay_rows: usize,
    stdin_file: std.fs.File = std.fs.File.stdin(),
    stdout_file: std.fs.File = std.fs.File.stdout(),
    original_termios: ?std.posix.termios = null,
    did_render: bool = false,

    pub fn init(overlay_rows: usize) !Self {
        if (!std.posix.isatty(std.fs.File.stdin().handle)) return Error.NotATerminal;
        if (!std.posix.isatty(std.fs.File.stdout().handle)) return Error.NotATerminal;
        return .{ .overlay_rows = overlay_rows };
    }

    pub fn enterRaw(self: *Self) !void {
        const current = try std.posix.tcgetattr(self.stdin_file.handle);
        self.original_termios = current;
        var raw = current;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(self.stdin_file.handle, .NOW, raw);
    }

    pub fn leaveRaw(self: *Self) void {
        if (self.original_termios) |original| {
            std.posix.tcsetattr(self.stdin_file.handle, .FLUSH, original) catch {};
        }
        self.original_termios = null;
    }

    pub fn redraw(self: *Self, allocator: std.mem.Allocator, lines: [][]const u8) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        if (self.did_render and self.overlay_rows > 1) {
            try out.writer.print("\x1b[{d}A", .{self.overlay_rows - 1});
        }

        for (0..self.overlay_rows) |row| {
            try out.writer.writeAll("\r\x1b[2K");
            if (row < lines.len) {
                try out.writer.writeAll(lines[row]);
            }
            if (row + 1 < self.overlay_rows) {
                try out.writer.writeByte('\n');
            }
        }

        const buffer = try out.toOwnedSlice();
        defer allocator.free(buffer);
        try self.stdout_file.writeAll(buffer);
        self.did_render = true;
    }

    pub fn clear(self: *Self, allocator: std.mem.Allocator) !void {
        if (!self.did_render) return;

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        if (self.overlay_rows > 1) {
            try out.writer.print("\x1b[{d}A", .{self.overlay_rows - 1});
        }
        for (0..self.overlay_rows) |row| {
            try out.writer.writeAll("\r\x1b[2K");
            if (row + 1 < self.overlay_rows) {
                try out.writer.writeByte('\n');
            }
        }
        if (self.overlay_rows > 1) {
            try out.writer.print("\x1b[{d}A", .{self.overlay_rows - 1});
        }

        const buffer = try out.toOwnedSlice();
        defer allocator.free(buffer);
        try self.stdout_file.writeAll(buffer);
        self.did_render = false;
    }

    pub fn readKey(self: *Self) !Key {
        return readKeyFromFd(self.stdin_file.handle);
    }
};

fn readKeyFromFd(fd: std.posix.fd_t) !Key {
    const maybe_byte = try readByte(fd);
    const byte = maybe_byte orelse return .other;

    return switch (byte) {
        3 => .ctrl_c,
        '\r', '\n' => .enter,
        127, 8 => .backspace,
        ' ' => .space,
        'q' => .q,
        0x1b => try readEscapeSequence(fd),
        else => .other,
    };
}

fn readEscapeSequence(fd: std.posix.fd_t) !Key {
    if (!try hasPendingInput(fd, 25)) return .escape;

    const introducer = (try readByte(fd)) orelse return .escape;
    if (introducer != '[' and introducer != 'O') return .escape;

    while (true) {
        if (!try hasPendingInput(fd, 25)) return .escape;
        const byte = (try readByte(fd)) orelse return .escape;
        return switch (byte) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            '0'...'9', ';' => continue,
            else => .other,
        };
    }
}

fn hasPendingInput(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return try std.posix.poll(&fds, timeout_ms) != 0;
}

fn readByte(fd: std.posix.fd_t) !?u8 {
    var byte: [1]u8 = undefined;
    const read_count = try std.posix.read(fd, &byte);
    if (read_count == 0) return null;
    return byte[0];
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += try std.posix.write(fd, bytes[written..]);
    }
}

fn readKeyFromBytes(bytes: []const u8) !Key {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    errdefer std.posix.close(fds[1]);

    try writeAllFd(fds[1], bytes);
    std.posix.close(fds[1]);

    return try readKeyFromFd(fds[0]);
}

test "read key parses single byte controls" {
    try std.testing.expectEqual(Key.space, try readKeyFromBytes(" "));
    try std.testing.expectEqual(Key.enter, try readKeyFromBytes("\r"));
    try std.testing.expectEqual(Key.q, try readKeyFromBytes("q"));
}

test "read key parses bare escape as a key" {
    try std.testing.expectEqual(Key.escape, try readKeyFromBytes("\x1b"));
}

test "read key parses arrow escape sequences byte by byte" {
    try std.testing.expectEqual(Key.up, try readKeyFromBytes("\x1b[A"));
    try std.testing.expectEqual(Key.down, try readKeyFromBytes("\x1b[B"));
    try std.testing.expectEqual(Key.right, try readKeyFromBytes("\x1b[C"));
    try std.testing.expectEqual(Key.left, try readKeyFromBytes("\x1b[D"));
}

test "read key accepts modified csi arrow sequences" {
    try std.testing.expectEqual(Key.up, try readKeyFromBytes("\x1b[1;5A"));
}
