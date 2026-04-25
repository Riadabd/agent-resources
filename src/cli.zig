//! Command-line argument parsing and validation.

const std = @import("std");
const catalog_mod = @import("catalog.zig");

const section_count = catalog_mod.known_sections.len;

pub const Error = error{
    DuplicatePath,
    EmptySelection,
    InvalidArgument,
    InvalidSectionPath,
    MutuallyExclusiveFlags,
};

pub const ListOptions = struct {
    section: ?[]const u8 = null,
};

pub const GenerateOptions = struct {
    output_dir: []const u8,
    snippets_root: ?[]const u8 = null,
    selections: [section_count]std.ArrayListUnmanaged([]const u8) =
        [_]std.ArrayListUnmanaged([]const u8){.empty} ** section_count,

    pub fn deinit(self: *GenerateOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.output_dir);
        if (self.snippets_root) |root| allocator.free(root);
        for (&self.selections) |*selection| {
            deinitPathList(allocator, selection);
        }
    }
};

pub const Command = union(enum) {
    interactive,
    list: ListOptions,
    generate: GenerateOptions,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .interactive => {},
            .list => |*list| {
                if (list.section) |section| allocator.free(section);
            },
            .generate => |*generate| generate.deinit(allocator),
        }
    }
};

pub fn parseArgs(allocator: std.mem.Allocator) !Command {
    var args = try collectArgs(allocator);
    defer freeArgs(allocator, args);

    if (args.len <= 1) return .interactive;

    if (std.mem.eql(u8, args[1], "list")) {
        return .{ .list = try parseList(allocator, args[2..]) };
    }
    if (std.mem.eql(u8, args[1], "generate")) {
        return .{ .generate = try parseGenerate(allocator, args[2..]) };
    }

    return Error.InvalidArgument;
}

pub fn resolveExplicitSelectionPaths(
    allocator: std.mem.Allocator,
    catalog: *const catalog_mod.Catalog,
    options: GenerateOptions,
) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (catalog_mod.known_sections, 0..) |section, index| {
        try appendResolvedSectionPaths(
            allocator,
            &result,
            &seen,
            catalog,
            section.key,
            options.selections[index].items,
        );
    }

    if (result.items.len == 0) return Error.EmptySelection;
    return try result.toOwnedSlice(allocator);
}

fn parseList(allocator: std.mem.Allocator, args: []const []const u8) !ListOptions {
    var options = ListOptions{};
    errdefer if (options.section) |section| allocator.free(section);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--section")) {
            index += 1;
            if (index >= args.len) return Error.InvalidArgument;
            const section = try allocator.dupe(u8, args[index]);
            if (options.section) |existing| allocator.free(existing);
            options.section = section;
            continue;
        }
        return Error.InvalidArgument;
    }
    return options;
}

fn parseGenerate(allocator: std.mem.Allocator, args: []const []const u8) !GenerateOptions {
    var options = GenerateOptions{
        .output_dir = try allocator.dupe(u8, "."),
    };
    errdefer options.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--output-dir")) {
            index += 1;
            if (index >= args.len) return Error.InvalidArgument;
            const output_dir = try allocator.dupe(u8, args[index]);
            allocator.free(options.output_dir);
            options.output_dir = output_dir;
            continue;
        }
        if (std.mem.eql(u8, arg, "--snippets")) {
            index += 1;
            if (index >= args.len) return Error.InvalidArgument;
            const snippets_root = try allocator.dupe(u8, args[index]);
            if (options.snippets_root) |existing| allocator.free(existing);
            options.snippets_root = snippets_root;
            continue;
        }

        const target = sectionListForFlag(&options, arg) orelse return Error.InvalidArgument;
        const original_len = target.items.len;
        index += 1;
        if (index >= args.len) return Error.InvalidArgument;
        while (index < args.len and !std.mem.startsWith(u8, args[index], "--")) : (index += 1) {
            try target.append(allocator, try allocator.dupe(u8, args[index]));
        }
        if (target.items.len == original_len) return Error.InvalidArgument;
        index -= 1;
    }

    if (options.snippets_root != null and hasAnyExplicitFlags(options)) return Error.MutuallyExclusiveFlags;
    if (options.snippets_root == null and !hasAnyExplicitFlags(options)) return Error.EmptySelection;
    return options;
}

fn hasAnyExplicitFlags(options: GenerateOptions) bool {
    for (options.selections) |selection| {
        if (selection.items.len > 0) return true;
    }
    return false;
}

fn sectionListForFlag(options: *GenerateOptions, flag: []const u8) ?*std.ArrayListUnmanaged([]const u8) {
    const prefix = "--";
    if (!std.mem.startsWith(u8, flag, prefix)) return null;
    const key = flag[prefix.len..];
    const index = catalog_mod.knownSectionIndex(key) orelse return null;
    if (!std.mem.eql(u8, catalog_mod.known_sections[index].key, key)) return null;
    return &options.selections[index];
}

fn appendResolvedSectionPaths(
    allocator: std.mem.Allocator,
    result: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    catalog: *const catalog_mod.Catalog,
    expected_section: []const u8,
    paths: []const []const u8,
) !void {
    for (paths) |path| {
        const relative_path = try normalizeSelectionPath(allocator, catalog.root_path, path);
        defer allocator.free(relative_path);

        var parts = std.mem.splitScalar(u8, relative_path, std.fs.path.sep);
        const top_level = parts.next() orelse return Error.InvalidSectionPath;
        if (!catalog_mod.sectionMatchesFilter(top_level, expected_section)) {
            return Error.InvalidSectionPath;
        }

        const node = catalog.findFileByRelativePath(relative_path) orelse return Error.InvalidSectionPath;
        if (seen.contains(node.relative_path)) return Error.DuplicatePath;
        try seen.put(allocator, node.relative_path, {});
        try result.append(allocator, node.relative_path);
    }
}

fn normalizeSelectionPath(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    user_path: []const u8,
) ![]const u8 {
    const absolute_path = std.fs.cwd().realpathAlloc(allocator, user_path) catch blk: {
        const joined = try std.fs.path.join(allocator, &.{ root_path, user_path });
        defer allocator.free(joined);
        break :blk try std.fs.cwd().realpathAlloc(allocator, joined);
    };
    defer allocator.free(absolute_path);

    if (!std.mem.startsWith(u8, absolute_path, root_path)) return Error.InvalidSectionPath;
    if (absolute_path.len <= root_path.len) return Error.InvalidSectionPath;
    if (absolute_path[root_path.len] != std.fs.path.sep) return Error.InvalidSectionPath;

    return try allocator.dupe(u8, absolute_path[root_path.len + 1 ..]);
}

fn collectArgs(allocator: std.mem.Allocator) ![][]const u8 {
    var iterator = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iterator.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    while (iterator.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    return try args.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: [][]const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn deinitPathList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |path| allocator.free(path);
    list.deinit(allocator);
}

fn sectionSelection(options: *GenerateOptions, section_key: []const u8) *std.ArrayListUnmanaged([]const u8) {
    const index = catalog_mod.knownSectionIndex(section_key) orelse unreachable;
    return &options.selections[index];
}

test "generate rejects snippets root mixed with explicit selection" {
    const allocator = std.testing.allocator;
    var options = GenerateOptions{
        .output_dir = try allocator.dupe(u8, "."),
        .snippets_root = try allocator.dupe(u8, "snippets"),
    };
    defer options.deinit(allocator);
    try sectionSelection(&options, "tooling").append(allocator, try allocator.dupe(u8, "tooling/make.md"));
    try std.testing.expect(hasAnyExplicitFlags(options));
}

test "generate rejects section flags without paths" {
    try std.testing.expectError(
        Error.InvalidArgument,
        parseGenerate(std.testing.allocator, &.{ "--tooling", "--language", "languages/python.md" }),
    );
}

test "generate stores explicit selections by known section" {
    var options = try parseGenerate(
        std.testing.allocator,
        &.{ "--language", "languages/python.md", "--tooling", "tooling/task-runner.md" },
    );
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), sectionSelection(&options, "language").items.len);
    try std.testing.expectEqualStrings("languages/python.md", sectionSelection(&options, "language").items[0]);
    try std.testing.expectEqual(@as(usize, 1), sectionSelection(&options, "tooling").items.len);
    try std.testing.expectEqualStrings("tooling/task-runner.md", sectionSelection(&options, "tooling").items[0]);
}

test "selection path normalization rejects sibling path prefixes" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.makePath("snippets/tooling");
    try temp.dir.writeFile(.{ .sub_path = "snippets/tooling/task-runner.md", .data = "make\n" });
    try temp.dir.makePath("snippets-other/tooling");
    try temp.dir.writeFile(.{ .sub_path = "snippets-other/tooling/task-runner.md", .data = "make\n" });

    const root_path = try temp.dir.realpathAlloc(std.testing.allocator, "snippets");
    defer std.testing.allocator.free(root_path);
    const sibling_path = try temp.dir.realpathAlloc(std.testing.allocator, "snippets-other/tooling/task-runner.md");
    defer std.testing.allocator.free(sibling_path);

    try std.testing.expectError(
        Error.InvalidSectionPath,
        normalizeSelectionPath(std.testing.allocator, root_path, sibling_path),
    );
}
