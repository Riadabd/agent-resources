//! Output file naming and writing.

const std = @import("std");

pub const Error = error{
    InvalidOutputDir,
};

pub const DateStamp = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const Preview = struct {
    output_dir: []const u8,
    filename: []const u8,
    path: []const u8,
    has_agents_file: bool,

    pub fn deinit(self: Preview, allocator: std.mem.Allocator) void {
        allocator.free(self.output_dir);
        allocator.free(self.filename);
        allocator.free(self.path);
    }
};

pub const WriteResult = struct {
    preview: Preview,

    pub fn deinit(self: WriteResult, allocator: std.mem.Allocator) void {
        self.preview.deinit(allocator);
    }
};

pub fn previewOutputPath(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    maybe_date: ?DateStamp,
) !Preview {
    const resolved_dir = std.fs.cwd().realpathAlloc(allocator, output_dir) catch return Error.InvalidOutputDir;
    errdefer allocator.free(resolved_dir);

    var dir = std.fs.openDirAbsolute(resolved_dir, .{}) catch return Error.InvalidOutputDir;
    defer dir.close();

    const has_agents_file = fileExists(dir, "AGENTS.md");
    const date = maybe_date orelse try currentLocalDate();
    const filename = try nextAvailableFilename(allocator, dir, date);
    errdefer allocator.free(filename);
    const full_path = try std.fs.path.join(allocator, &.{ resolved_dir, filename });
    errdefer allocator.free(full_path);

    return .{
        .output_dir = resolved_dir,
        .filename = filename,
        .path = full_path,
        .has_agents_file = has_agents_file,
    };
}

pub fn writeGeneratedMarkdown(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    markdown: []const u8,
    maybe_date: ?DateStamp,
) !WriteResult {
    std.fs.cwd().makePath(output_dir) catch return Error.InvalidOutputDir;

    const preview = try previewOutputPath(allocator, output_dir, maybe_date);
    errdefer preview.deinit(allocator);

    try writeMarkdownToPreview(&preview, markdown);

    return .{ .preview = preview };
}

pub fn writeMarkdownToPreview(preview: *const Preview, markdown: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(preview.output_dir, .{});
    defer dir.close();

    var file = try dir.createFile(preview.filename, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(markdown);
}

fn nextAvailableFilename(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    date: DateStamp,
) ![]const u8 {
    const base_name = try std.fmt.allocPrint(
        allocator,
        "AGENTS-{d:0>2}-{d:0>2}-{d:0>2}.md",
        .{ @mod(date.year, 100), date.month, date.day },
    );
    errdefer allocator.free(base_name);

    if (!fileExists(dir, base_name)) return base_name;
    allocator.free(base_name);

    var suffix: usize = 1;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(
            allocator,
            "AGENTS-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}.md",
            .{ @mod(date.year, 100), date.month, date.day, suffix },
        );
        if (!fileExists(dir, candidate)) return candidate;
        allocator.free(candidate);
    }
}

fn fileExists(dir: std.fs.Dir, sub_path: []const u8) bool {
    dir.access(sub_path, .{}) catch return false;
    return true;
}

fn currentLocalDate() !DateStamp {
    const c = @cImport({
        @cInclude("time.h");
    });

    var now = c.time(null);
    var local_tm: c.struct_tm = undefined;
    if (c.localtime_r(&now, &local_tm) == null) return Error.InvalidOutputDir;

    return .{
        .year = @intCast(local_tm.tm_year + 1900),
        .month = @intCast(local_tm.tm_mon + 1),
        .day = @intCast(local_tm.tm_mday),
    };
}

test "preview warns about AGENTS.md and increments same-day filenames" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "existing\n" });
    try temp.dir.writeFile(.{ .sub_path = "AGENTS-26-04-22.md", .data = "one\n" });

    const root_path = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    const preview = try previewOutputPath(
        std.testing.allocator,
        root_path,
        .{ .year = 2026, .month = 4, .day = 22 },
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expect(preview.has_agents_file);
    try std.testing.expectEqualStrings("AGENTS-26-04-22-01.md", preview.filename);
}

test "write creates output directory and returns owned preview" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const root_path = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const output_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "generated" });
    defer std.testing.allocator.free(output_dir);

    const result = try writeGeneratedMarkdown(
        std.testing.allocator,
        output_dir,
        "content\n",
        .{ .year = 2026, .month = 4, .day = 22 },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("AGENTS-26-04-22.md", result.preview.filename);
    try temp.dir.access("generated/AGENTS-26-04-22.md", .{});
}
