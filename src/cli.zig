//! Command-line argument parsing and validation.

const std = @import("std");
const catalog_mod = @import("catalog.zig");

pub const Error = error{
    DuplicatePath,
    EmptySelection,
    InvalidArgument,
    InvalidSectionPath,
    MutuallyExclusiveFlags,
    UnknownSection,
};

pub const ListOptions = struct {
    section: ?[]const u8 = null,
};

pub const GenerateOptions = struct {
    output_dir: []const u8,
    snippets_root: ?[]const u8 = null,
    quick_summary: std.ArrayListUnmanaged([]const u8) = .empty,
    mindset: std.ArrayListUnmanaged([]const u8) = .empty,
    tooling: std.ArrayListUnmanaged([]const u8) = .empty,
    testing: std.ArrayListUnmanaged([]const u8) = .empty,
    language: std.ArrayListUnmanaged([]const u8) = .empty,
    communication: std.ArrayListUnmanaged([]const u8) = .empty,
    environment: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *GenerateOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.output_dir);
        if (self.snippets_root) |root| allocator.free(root);
        deinitPathList(allocator, &self.quick_summary);
        deinitPathList(allocator, &self.mindset);
        deinitPathList(allocator, &self.tooling);
        deinitPathList(allocator, &self.testing);
        deinitPathList(allocator, &self.language);
        deinitPathList(allocator, &self.communication);
        deinitPathList(allocator, &self.environment);
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

    try appendResolvedSectionPaths(allocator, &result, &seen, catalog, "quick-summary", options.quick_summary.items);
    try appendResolvedSectionPaths(allocator, &result, &seen, catalog, "mindset", options.mindset.items);
    try appendResolvedSectionPaths(allocator, &result, &seen, catalog, "tooling", options.tooling.items);
    try appendResolvedSectionPaths(allocator, &result, &seen, catalog, "testing", options.testing.items);
    try appendResolvedSectionPaths(allocator, &result, &seen, catalog, "language", options.language.items);
    try appendResolvedSectionPaths(allocator, &result, &seen, catalog, "communication", options.communication.items);
    try appendResolvedSectionPaths(allocator, &result, &seen, catalog, "environment", options.environment.items);

    if (result.items.len == 0) return Error.EmptySelection;
    return try result.toOwnedSlice(allocator);
}

fn parseList(allocator: std.mem.Allocator, args: [][]const u8) !ListOptions {
    var options = ListOptions{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--section")) {
            index += 1;
            if (index >= args.len) return Error.InvalidArgument;
            options.section = try allocator.dupe(u8, args[index]);
            continue;
        }
        return Error.InvalidArgument;
    }
    return options;
}

fn parseGenerate(allocator: std.mem.Allocator, args: [][]const u8) !GenerateOptions {
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
            allocator.free(options.output_dir);
            options.output_dir = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--snippets")) {
            index += 1;
            if (index >= args.len) return Error.InvalidArgument;
            options.snippets_root = try allocator.dupe(u8, args[index]);
            continue;
        }

        const target = sectionListForFlag(&options, arg) orelse return Error.InvalidArgument;
        index += 1;
        if (index >= args.len) return Error.InvalidArgument;
        while (index < args.len and !std.mem.startsWith(u8, args[index], "--")) : (index += 1) {
            try target.append(allocator, try allocator.dupe(u8, args[index]));
        }
        index -= 1;
    }

    if (options.snippets_root != null and hasAnyExplicitFlags(options)) return Error.MutuallyExclusiveFlags;
    if (options.snippets_root == null and !hasAnyExplicitFlags(options)) return Error.EmptySelection;
    return options;
}

fn hasAnyExplicitFlags(options: GenerateOptions) bool {
    return options.quick_summary.items.len > 0 or
        options.mindset.items.len > 0 or
        options.tooling.items.len > 0 or
        options.testing.items.len > 0 or
        options.language.items.len > 0 or
        options.communication.items.len > 0 or
        options.environment.items.len > 0;
}

fn sectionListForFlag(options: *GenerateOptions, flag: []const u8) ?*std.ArrayListUnmanaged([]const u8) {
    if (std.mem.eql(u8, flag, "--quick-summary")) return &options.quick_summary;
    if (std.mem.eql(u8, flag, "--mindset")) return &options.mindset;
    if (std.mem.eql(u8, flag, "--tooling")) return &options.tooling;
    if (std.mem.eql(u8, flag, "--testing")) return &options.testing;
    if (std.mem.eql(u8, flag, "--language")) return &options.language;
    if (std.mem.eql(u8, flag, "--communication")) return &options.communication;
    if (std.mem.eql(u8, flag, "--environment")) return &options.environment;
    return null;
}

fn appendResolvedSectionPaths(
    allocator: std.mem.Allocator,
    result: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    catalog: *const catalog_mod.Catalog,
    expected_section: []const u8,
    paths: [][]const u8,
) !void {
    for (paths) |path| {
        const relative_path = try normalizeSelectionPath(allocator, catalog.root_path, path);
        defer allocator.free(relative_path);

        var parts = std.mem.splitScalar(u8, relative_path, std.fs.path.sep);
        const top_level = parts.next() orelse {
            return Error.InvalidSectionPath;
        };
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
    if (absolute_path.len == root_path.len) return Error.InvalidSectionPath;

    const offset = if (absolute_path[root_path.len] == std.fs.path.sep) root_path.len + 1 else root_path.len;
    return try allocator.dupe(u8, absolute_path[offset..]);
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

test "generate rejects snippets root mixed with explicit selection" {
    const allocator = std.testing.allocator;
    var options = GenerateOptions{
        .output_dir = try allocator.dupe(u8, "."),
        .snippets_root = try allocator.dupe(u8, "snippets"),
    };
    defer options.deinit(allocator);
    try options.tooling.append(allocator, try allocator.dupe(u8, "tooling/make.md"));
    try std.testing.expect(hasAnyExplicitFlags(options));
}
