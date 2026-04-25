//! Markdown rendering for selected snippets.

const std = @import("std");
const catalog_mod = @import("catalog.zig");

pub const Error = error{
    UnknownSnippetPath,
};

pub fn renderSelection(
    allocator: std.mem.Allocator,
    catalog: *const catalog_mod.Catalog,
    selected_paths: []const []const u8,
) ![]u8 {
    var selected: std.StringHashMapUnmanaged(void) = .empty;
    defer selected.deinit(allocator);

    for (selected_paths) |path| {
        const node = catalog.findFileByRelativePath(path) orelse return Error.UnknownSnippetPath;
        try selected.put(allocator, node.relative_path, {});
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var wrote_any = false;
    for (catalog.sections.items) |section| {
        if (!nodeHasSelection(section.root, &selected)) continue;
        if (wrote_any) try writer.writer.writeAll("\n");
        wrote_any = true;
        try writeHeading(&writer.writer, 1, section.title);
        try writer.writer.writeAll("\n\n");
        try renderChildren(&writer.writer, section.root, 2, &selected);
    }

    return try writer.toOwnedSlice();
}

fn renderChildren(
    writer: *std.Io.Writer,
    node: *const catalog_mod.Node,
    depth: usize,
    selected: *const std.StringHashMapUnmanaged(void),
) !void {
    for (node.children.items) |child| {
        if (!nodeHasSelection(child, selected)) continue;
        switch (child.kind) {
            .directory => {
                try writeHeading(writer, depth, child.title);
                try writer.writeAll("\n\n");
                try renderChildren(writer, child, depth + 1, selected);
            },
            .file => try renderFile(writer, child, depth),
        }
    }
}

fn renderFile(writer: *std.Io.Writer, node: *const catalog_mod.Node, depth: usize) !void {
    try writeHeading(writer, depth, node.title);
    try writer.writeAll("\n\n");

    const source = node.source orelse return;
    const rewritten = try rewriteBody(std.heap.page_allocator, source.content, depth, source.promoted_title != null);
    defer std.heap.page_allocator.free(rewritten);

    if (rewritten.len > 0) {
        try writer.writeAll(rewritten);
        if (!std.mem.endsWith(u8, rewritten, "\n")) {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("\n");
}

fn rewriteBody(
    allocator: std.mem.Allocator,
    content: []const u8,
    heading_depth: usize,
    had_promoted_title: bool,
) ![]u8 {
    var body = content;
    if (had_promoted_title) {
        const line_end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
        body = if (line_end < body.len) body[line_end + 1 ..] else "";
    }

    const shift_amount: usize = if (had_promoted_title) heading_depth - 1 else heading_depth;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var index: usize = 0;
    while (index < body.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, body, index, '\n') orelse body.len;
        const line = body[index..next_newline];
        try writeShiftedLine(&writer.writer, line, shift_amount);
        if (next_newline < body.len) {
            try writer.writer.writeByte('\n');
        }
        index = if (next_newline < body.len) next_newline + 1 else body.len;
    }

    return try writer.toOwnedSlice();
}

fn writeShiftedLine(writer: *std.Io.Writer, line: []const u8, shift_amount: usize) !void {
    const parsed = parseAtxHeading(line) orelse {
        try writer.writeAll(line);
        return;
    };

    const new_level = @min(6, parsed.level + shift_amount);
    var prefix_index: usize = 0;
    while (prefix_index < parsed.prefix_len) : (prefix_index += 1) {
        try writer.writeByte(line[prefix_index]);
    }
    var hash_index: usize = 0;
    while (hash_index < new_level) : (hash_index += 1) {
        try writer.writeByte('#');
    }
    try writer.writeAll(line[parsed.content_start - 1 ..]);
}

const HeadingParse = struct {
    prefix_len: usize,
    level: usize,
    content_start: usize,
};

fn parseAtxHeading(line: []const u8) ?HeadingParse {
    var prefix_len: usize = 0;
    while (prefix_len < line.len and prefix_len < 3 and line[prefix_len] == ' ') : (prefix_len += 1) {}
    var index = prefix_len;
    while (index < line.len and line[index] == '#') : (index += 1) {}
    const level = index - prefix_len;
    if (level == 0 or level > 6) return null;
    if (index >= line.len) return null;
    if (line[index] != ' ' and line[index] != '\t') return null;
    return .{
        .prefix_len = prefix_len,
        .level = level,
        .content_start = index + 1,
    };
}

fn writeHeading(writer: *std.Io.Writer, depth: usize, title: []const u8) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) {
        try writer.writeByte('#');
    }
    try writer.print(" {s}", .{title});
}

fn nodeHasSelection(
    node: *const catalog_mod.Node,
    selected: *const std.StringHashMapUnmanaged(void),
) bool {
    return switch (node.kind) {
        .file => selected.contains(node.relative_path),
        .directory => blk: {
            for (node.children.items) |child| {
                if (nodeHasSelection(child, selected)) break :blk true;
            }
            break :blk false;
        },
    };
}

test "rendering promotes titles and shifts nested headings" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.makePath("languages");
    try temp.dir.writeFile(.{
        .sub_path = "languages/python.md",
        .data = "# Python\n## Style\nUse uv.\n",
    });

    const root_path = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    var catalog = try catalog_mod.Catalog.discover(std.testing.allocator, root_path);
    defer catalog.deinit();

    const rendered = try renderSelection(
        std.testing.allocator,
        &catalog,
        &.{"languages/python.md"},
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "# Languages") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "## Python") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "### Style") != null);
}
