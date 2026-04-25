//! Shell-inline interactive selection flow.

const std = @import("std");
const catalog_mod = @import("catalog.zig");
const output_mod = @import("output.zig");
const terminal_mod = @import("terminal.zig");

const overlay_rows = 18;

const Stage = enum {
    section_select,
    snippet_select,
    review,
};

const SelectionState = enum {
    none,
    partial,
    all,
};

const SectionEntry = struct {
    section: *catalog_mod.Section,
    selected: bool = false,
};

const VisibleNode = struct {
    node: *catalog_mod.Node,
    depth: usize,
};

pub const RunResult = struct {
    paths: [][]const u8,
    preview: output_mod.Preview,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.paths);
        self.preview.deinit(allocator);
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    catalog: *const catalog_mod.Catalog,
    output_dir: []const u8,
) !?RunResult {
    var terminal = try terminal_mod.Terminal.init(overlay_rows);
    try terminal.enterRaw();
    defer terminal.leaveRaw();
    defer terminal.clear(allocator) catch {};

    var section_entries: std.ArrayList(SectionEntry) = .empty;
    defer section_entries.deinit(allocator);
    for (catalog.sections.items) |section| {
        try section_entries.append(allocator, .{ .section = section });
    }

    var selected_files: std.StringHashMapUnmanaged(void) = .empty;
    defer selected_files.deinit(allocator);
    var expanded_dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded_dirs.deinit(allocator);

    var stage: Stage = .section_select;
    var cursor: usize = 0;
    var section_cursor: usize = 0;
    var review_preview: ?output_mod.Preview = null;
    defer if (review_preview) |preview| preview.deinit(allocator);

    while (true) {
        const lines = try buildLines(
            allocator,
            catalog,
            section_entries.items,
            &selected_files,
            &expanded_dirs,
            stage,
            cursor,
            section_cursor,
            if (review_preview) |*preview| preview else null,
        );
        defer freeLines(allocator, lines);
        try terminal.redraw(allocator, lines);

        switch (try terminal.readKey()) {
            .ctrl_c, .q => return null,
            .up => {
                if (cursor > 0) cursor -= 1;
            },
            .down => {
                const length = itemCount(section_entries.items, &expanded_dirs, stage, section_cursor);
                if (cursor + 1 < length) cursor += 1;
            },
            .space => try handleSpace(
                allocator,
                section_entries.items,
                &selected_files,
                &expanded_dirs,
                stage,
                cursor,
                &section_cursor,
            ),
            .right => try handleRight(
                allocator,
                section_entries.items,
                &expanded_dirs,
                stage,
                cursor,
                section_cursor,
            ),
            .left => try handleLeft(
                section_entries.items,
                &expanded_dirs,
                stage,
                cursor,
                &section_cursor,
            ),
            .escape, .backspace => {
                if (!handleBack(&stage, &cursor, section_cursor)) return null;
            },
            .enter => switch (stage) {
                .section_select => {
                    if (!beginSnippetStageFromSections(section_entries.items, cursor, &section_cursor)) continue;
                    stage = .snippet_select;
                    cursor = 0;
                },
                .snippet_select => {
                    try ensureCurrentSnippetSelected(
                        allocator,
                        section_entries.items,
                        &selected_files,
                        &expanded_dirs,
                        cursor,
                        &section_cursor,
                    );
                    const next_section = nextSelectedSection(section_entries.items, section_cursor + 1);
                    if (next_section) |value| {
                        section_cursor = value;
                        cursor = 0;
                    } else if (selected_files.count() > 0) {
                        if (review_preview == null) {
                            review_preview = try output_mod.previewOutputPath(allocator, output_dir, null);
                        }
                        stage = .review;
                        cursor = 0;
                    }
                },
                .review => {
                    if (selected_files.count() == 0) continue;
                    const paths = try collectSelectedPaths(allocator, catalog, &selected_files);
                    errdefer allocator.free(paths);
                    const preview = review_preview orelse return error.MissingReviewPreview;
                    review_preview = null;
                    return .{ .paths = paths, .preview = preview };
                },
            },
            else => {},
        }

        const max_cursor = itemCount(section_entries.items, &expanded_dirs, stage, section_cursor);
        if (max_cursor == 0) {
            cursor = 0;
        } else if (cursor >= max_cursor) {
            cursor = max_cursor - 1;
        }
    }
}

fn buildLines(
    allocator: std.mem.Allocator,
    catalog: *const catalog_mod.Catalog,
    section_entries: []SectionEntry,
    selected_files: *const std.StringHashMapUnmanaged(void),
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
    stage: Stage,
    cursor: usize,
    section_cursor: usize,
    review_preview: ?*const output_mod.Preview,
) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;

    try lines.append(allocator, try std.fmt.allocPrint(allocator, "--- agents-gen ---", .{}));
    try lines.append(allocator, try std.fmt.allocPrint(
        allocator,
        "Use arrows to move, Space to toggle, Enter to choose/continue, q to cancel.",
        .{},
    ));

    switch (stage) {
        .section_select => try buildSectionStageLines(allocator, &lines, section_entries, cursor),
        .snippet_select => try buildSnippetStageLines(
            allocator,
            &lines,
            section_entries,
            selected_files,
            expanded_dirs,
            cursor,
            section_cursor,
        ),
        .review => try buildReviewLines(
            allocator,
            &lines,
            catalog,
            section_entries,
            selected_files,
            review_preview orelse return error.MissingReviewPreview,
        ),
    }

    while (lines.items.len < overlay_rows) {
        try lines.append(allocator, try allocator.dupe(u8, ""));
    }

    return try lines.toOwnedSlice(allocator);
}

fn buildSectionStageLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    section_entries: []SectionEntry,
    cursor: usize,
) !void {
    const current_index = if (section_entries.len == 0) 0 else cursor + 1;
    try lines.append(allocator, try std.fmt.allocPrint(
        allocator,
        "Select sections ({d}/{d})",
        .{ current_index, section_entries.len },
    ));
    if (section_entries.len == 1) {
        try lines.append(allocator, try allocator.dupe(u8, "Only one section found; press Enter to choose it."));
    }
    var visible = sliceWindow(section_entries.len, cursor, overlay_rows - lines.items.len);
    while (visible.start < visible.end) : (visible.start += 1) {
        const entry = section_entries[visible.start];
        const marker = if (entry.selected) "x" else " ";
        const pointer = if (visible.start == cursor) ">" else " ";
        try lines.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s} [{s}] {s}",
            .{ pointer, marker, entry.section.title },
        ));
    }
}

fn buildSnippetStageLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    section_entries: []SectionEntry,
    selected_files: *const std.StringHashMapUnmanaged(void),
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
    cursor: usize,
    section_cursor: usize,
) !void {
    const current = section_entries[section_cursor];
    const items = try flattenVisibleNodes(allocator, current.section.root, expanded_dirs);
    defer allocator.free(items);

    const current_index = if (items.len == 0) 0 else cursor + 1;
    try lines.append(allocator, try std.fmt.allocPrint(
        allocator,
        "Choose snippets for {s} ({d}/{d})",
        .{ current.section.title, current_index, items.len },
    ));
    if (items.len == 1) {
        try lines.append(allocator, try allocator.dupe(u8, "Only one snippet found; press Enter to choose it."));
    }

    const visible = sliceWindow(items.len, cursor, overlay_rows - lines.items.len);
    var index = visible.start;
    while (index < visible.end) : (index += 1) {
        const item = items[index];
        const pointer = if (index == cursor) ">" else " ";
        const state = selectionState(item.node, selected_files);
        const marker = switch (state) {
            .none => " ",
            .partial => "-",
            .all => "x",
        };
        const expand_marker = if (item.node.kind == .directory)
            if (expanded_dirs.contains(item.node.relative_path)) "v" else ">"
        else
            " ";
        const indent = try allocator.alloc(u8, item.depth * 2);
        defer allocator.free(indent);
        @memset(indent, ' ');
        try lines.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s} [{s}] {s}{s} {s}",
            .{ pointer, marker, indent, expand_marker, item.node.title },
        ));
    }
}

fn buildReviewLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    catalog: *const catalog_mod.Catalog,
    section_entries: []SectionEntry,
    selected_files: *const std.StringHashMapUnmanaged(void),
    preview: *const output_mod.Preview,
) !void {
    try lines.append(allocator, try allocator.dupe(u8, "Review and generate"));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "Output: {s}", .{preview.filename}));
    if (preview.has_agents_file) {
        try lines.append(allocator, try std.fmt.allocPrint(
            allocator,
            "Warning: AGENTS.md already exists and will not be touched.",
            .{},
        ));
    }

    try lines.append(allocator, try allocator.dupe(u8, "Selected sections:"));
    for (section_entries) |entry| {
        if (!entry.selected and !nodeHasSelectedFile(entry.section.root, selected_files)) continue;
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "  - {s}", .{entry.section.title}));
    }

    try lines.append(allocator, try allocator.dupe(u8, "Selected files:"));
    for (catalog.sections.items) |section| {
        try appendSelectedFiles(allocator, lines, section.root, selected_files);
    }
}

fn handleSpace(
    allocator: std.mem.Allocator,
    section_entries: []SectionEntry,
    selected_files: *std.StringHashMapUnmanaged(void),
    expanded_dirs: *std.StringHashMapUnmanaged(void),
    stage: Stage,
    cursor: usize,
    section_cursor: *usize,
) !void {
    switch (stage) {
        .section_select => {
            section_entries[cursor].selected = !section_entries[cursor].selected;
        },
        .snippet_select => {
            const current = section_entries[section_cursor.*];
            const item = visibleNodeAt(current.section.root, expanded_dirs, cursor) orelse return;
            switch (item.node.kind) {
                .file => try toggleFile(allocator, item.node, selected_files),
                .directory => try toggleDirectory(allocator, item.node, selected_files),
            }
        },
        .review => {},
    }
}

fn handleRight(
    allocator: std.mem.Allocator,
    section_entries: []SectionEntry,
    expanded_dirs: *std.StringHashMapUnmanaged(void),
    stage: Stage,
    cursor: usize,
    section_cursor: usize,
) !void {
    if (stage != .snippet_select) return;
    const current = section_entries[section_cursor];
    const item = visibleNodeAt(current.section.root, expanded_dirs, cursor) orelse return;
    if (item.node.kind == .directory) {
        try expandedDirsPut(allocator, expanded_dirs, item.node.relative_path);
    }
}

fn handleLeft(
    section_entries: []SectionEntry,
    expanded_dirs: *std.StringHashMapUnmanaged(void),
    stage: Stage,
    cursor: usize,
    section_cursor: *usize,
) !void {
    if (stage != .snippet_select) return;
    const current = section_entries[section_cursor.*];
    const item = visibleNodeAt(current.section.root, expanded_dirs, cursor) orelse return;
    if (item.node.kind == .directory and expanded_dirs.contains(item.node.relative_path)) {
        _ = expanded_dirs.remove(item.node.relative_path);
        return;
    }
    if (item.depth == 0 and section_cursor.* > 0) {
        section_cursor.* -= 1;
    }
}

fn handleBack(stage: *Stage, cursor: *usize, section_cursor: usize) bool {
    switch (stage.*) {
        .section_select => return false,
        .snippet_select => {
            stage.* = .section_select;
            cursor.* = section_cursor;
            return true;
        },
        .review => {
            stage.* = .snippet_select;
            cursor.* = 0;
            return true;
        },
    }
}

fn itemCount(
    section_entries: []SectionEntry,
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
    stage: Stage,
    section_cursor: usize,
) usize {
    return switch (stage) {
        .section_select => section_entries.len,
        .snippet_select => blk: {
            const current = section_entries[section_cursor];
            break :blk visibleNodeCount(current.section.root, expanded_dirs);
        },
        .review => 1,
    };
}

fn nextSelectedSection(section_entries: []const SectionEntry, start: usize) ?usize {
    var index = start;
    while (index < section_entries.len) : (index += 1) {
        if (section_entries[index].selected) return index;
    }
    return null;
}

fn beginSnippetStageFromSections(
    section_entries: []const SectionEntry,
    cursor: usize,
    section_cursor: *usize,
) bool {
    if (section_entries.len == 0) return false;
    section_cursor.* = nextSelectedSection(section_entries, 0) orelse cursor;
    return true;
}

fn ensureCurrentSnippetSelected(
    allocator: std.mem.Allocator,
    section_entries: []SectionEntry,
    selected_files: *std.StringHashMapUnmanaged(void),
    expanded_dirs: *std.StringHashMapUnmanaged(void),
    cursor: usize,
    section_cursor: *usize,
) !void {
    const current = section_entries[section_cursor.*];
    if (nodeHasSelectedFile(current.section.root, selected_files)) return;
    try handleSpace(
        allocator,
        section_entries,
        selected_files,
        expanded_dirs,
        .snippet_select,
        cursor,
        section_cursor,
    );
}

fn flattenVisibleNodes(
    allocator: std.mem.Allocator,
    root: *catalog_mod.Node,
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
) ![]VisibleNode {
    var items: std.ArrayList(VisibleNode) = .empty;
    defer items.deinit(allocator);
    for (root.children.items) |child| {
        try appendVisibleNode(&items, allocator, child, expanded_dirs, 0);
    }
    return try items.toOwnedSlice(allocator);
}

fn appendVisibleNode(
    items: *std.ArrayList(VisibleNode),
    allocator: std.mem.Allocator,
    node: *catalog_mod.Node,
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
    depth: usize,
) !void {
    try items.append(allocator, .{ .node = node, .depth = depth });
    if (node.kind == .directory and expanded_dirs.contains(node.relative_path)) {
        for (node.children.items) |child| {
            try appendVisibleNode(items, allocator, child, expanded_dirs, depth + 1);
        }
    }
}

fn visibleNodeCount(
    root: *catalog_mod.Node,
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
) usize {
    var count: usize = 0;
    for (root.children.items) |child| {
        count += visibleNodeCountFrom(child, expanded_dirs);
    }
    return count;
}

fn visibleNodeCountFrom(
    node: *catalog_mod.Node,
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
) usize {
    var count: usize = 1;
    if (node.kind == .directory and expanded_dirs.contains(node.relative_path)) {
        for (node.children.items) |child| {
            count += visibleNodeCountFrom(child, expanded_dirs);
        }
    }
    return count;
}

fn visibleNodeAt(
    root: *catalog_mod.Node,
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
    target_index: usize,
) ?VisibleNode {
    var remaining = target_index;
    for (root.children.items) |child| {
        if (visibleNodeAtFrom(child, expanded_dirs, &remaining, 0)) |node| return node;
    }
    return null;
}

fn visibleNodeAtFrom(
    node: *catalog_mod.Node,
    expanded_dirs: *const std.StringHashMapUnmanaged(void),
    remaining: *usize,
    depth: usize,
) ?VisibleNode {
    if (remaining.* == 0) return .{ .node = node, .depth = depth };
    remaining.* -= 1;

    if (node.kind == .directory and expanded_dirs.contains(node.relative_path)) {
        for (node.children.items) |child| {
            if (visibleNodeAtFrom(child, expanded_dirs, remaining, depth + 1)) |result| return result;
        }
    }
    return null;
}

fn selectionState(
    node: *catalog_mod.Node,
    selected_files: *const std.StringHashMapUnmanaged(void),
) SelectionState {
    return switch (node.kind) {
        .file => if (selected_files.contains(node.relative_path)) .all else .none,
        .directory => blk: {
            var selected_count: usize = 0;
            const total = node.fileCount();
            countSelectedDescendants(node, selected_files, &selected_count);
            if (selected_count == 0) break :blk .none;
            if (selected_count == total) break :blk .all;
            break :blk .partial;
        },
    };
}

fn nodeHasSelectedFile(
    node: *const catalog_mod.Node,
    selected_files: *const std.StringHashMapUnmanaged(void),
) bool {
    return switch (node.kind) {
        .file => selected_files.contains(node.relative_path),
        .directory => blk: {
            for (node.children.items) |child| {
                if (nodeHasSelectedFile(child, selected_files)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn countSelectedDescendants(
    node: *catalog_mod.Node,
    selected_files: *const std.StringHashMapUnmanaged(void),
    count: *usize,
) void {
    switch (node.kind) {
        .file => {
            if (selected_files.contains(node.relative_path)) count.* += 1;
        },
        .directory => for (node.children.items) |child| {
            countSelectedDescendants(child, selected_files, count);
        },
    }
}

fn toggleFile(
    allocator: std.mem.Allocator,
    node: *catalog_mod.Node,
    selected_files: *std.StringHashMapUnmanaged(void),
) !void {
    if (selected_files.contains(node.relative_path)) {
        _ = selected_files.remove(node.relative_path);
    } else {
        try selected_files.put(allocator, node.relative_path, {});
    }
}

fn toggleDirectory(
    allocator: std.mem.Allocator,
    node: *catalog_mod.Node,
    selected_files: *std.StringHashMapUnmanaged(void),
) !void {
    switch (selectionState(node, selected_files)) {
        .all => deselectDescendants(node, selected_files),
        .none, .partial => try selectDescendants(allocator, node, selected_files),
    }
}

fn selectDescendants(
    allocator: std.mem.Allocator,
    node: *catalog_mod.Node,
    selected_files: *std.StringHashMapUnmanaged(void),
) !void {
    switch (node.kind) {
        .file => try selected_files.put(allocator, node.relative_path, {}),
        .directory => for (node.children.items) |child| {
            try selectDescendants(allocator, child, selected_files);
        },
    }
}

fn deselectDescendants(node: *catalog_mod.Node, selected_files: *std.StringHashMapUnmanaged(void)) void {
    switch (node.kind) {
        .file => _ = selected_files.remove(node.relative_path),
        .directory => for (node.children.items) |child| {
            deselectDescendants(child, selected_files);
        },
    }
}

fn appendSelectedFiles(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    node: *catalog_mod.Node,
    selected_files: *const std.StringHashMapUnmanaged(void),
) !void {
    switch (node.kind) {
        .file => if (selected_files.contains(node.relative_path)) {
            try lines.append(allocator, try std.fmt.allocPrint(allocator, "  - {s}", .{node.relative_path}));
        },
        .directory => for (node.children.items) |child| {
            try appendSelectedFiles(allocator, lines, child, selected_files);
        },
    }
}

fn collectSelectedPaths(
    allocator: std.mem.Allocator,
    catalog: *const catalog_mod.Catalog,
    selected_files: *const std.StringHashMapUnmanaged(void),
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    for (catalog.sections.items) |section| {
        try collectSelectedFromNode(&list, allocator, section.root, selected_files);
    }

    return try list.toOwnedSlice(allocator);
}

fn collectSelectedFromNode(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    node: *catalog_mod.Node,
    selected_files: *const std.StringHashMapUnmanaged(void),
) !void {
    switch (node.kind) {
        .file => if (selected_files.contains(node.relative_path)) {
            try list.append(allocator, node.relative_path);
        },
        .directory => for (node.children.items) |child| {
            try collectSelectedFromNode(list, allocator, child, selected_files);
        },
    }
}

fn expandedDirsPut(
    allocator: std.mem.Allocator,
    expanded_dirs: *std.StringHashMapUnmanaged(void),
    key: []const u8,
) !void {
    try expanded_dirs.put(allocator, key, {});
}

fn sliceWindow(total: usize, cursor: usize, available_rows: usize) struct { start: usize, end: usize } {
    if (total <= available_rows) return .{ .start = 0, .end = total };
    const half = available_rows / 2;
    var start = cursor -| half;
    if (start + available_rows > total) {
        start = total - available_rows;
    }
    return .{ .start = start, .end = start + available_rows };
}

fn freeLines(allocator: std.mem.Allocator, lines: [][]const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

test "selection state is partial when only one descendant is selected" {
    const allocator = std.testing.allocator;
    var root = catalog_mod.Node{
        .kind = .directory,
        .name = "tooling",
        .relative_path = "tooling",
        .title = "Tooling",
        .parent = null,
    };
    var a = catalog_mod.Node{
        .kind = .file,
        .name = "a.md",
        .relative_path = "tooling/a.md",
        .title = "A",
        .parent = &root,
        .source = .{ .content = "", .promoted_title = null },
    };
    var b = catalog_mod.Node{
        .kind = .file,
        .name = "b.md",
        .relative_path = "tooling/b.md",
        .title = "B",
        .parent = &root,
        .source = .{ .content = "", .promoted_title = null },
    };
    try root.children.append(allocator, &a);
    try root.children.append(allocator, &b);
    defer root.children.deinit(allocator);

    var selected: std.StringHashMapUnmanaged(void) = .empty;
    defer selected.deinit(allocator);
    try selected.put(allocator, "tooling/a.md", {});

    try std.testing.expectEqual(SelectionState.partial, selectionState(&root, &selected));
}

test "file toggle uses caller-owned selection map allocation" {
    const allocator = std.testing.allocator;
    var file = catalog_mod.Node{
        .kind = .file,
        .name = "python.md",
        .relative_path = "languages/python.md",
        .title = "Python",
        .parent = null,
        .source = .{ .content = "", .promoted_title = null },
    };

    var selected: std.StringHashMapUnmanaged(void) = .empty;
    defer selected.deinit(allocator);

    try toggleFile(allocator, &file, &selected);
    try std.testing.expect(selected.contains(file.relative_path));

    try toggleFile(allocator, &file, &selected);
    try std.testing.expect(!selected.contains(file.relative_path));
}

test "directory expansion uses caller-owned expansion map allocation" {
    const allocator = std.testing.allocator;
    var root = catalog_mod.Node{
        .kind = .directory,
        .name = "languages",
        .relative_path = "languages",
        .title = "Languages",
        .parent = null,
    };
    var directory = catalog_mod.Node{
        .kind = .directory,
        .name = "python",
        .relative_path = "languages/python",
        .title = "Python",
        .parent = &root,
    };
    try root.children.append(allocator, &directory);
    defer root.children.deinit(allocator);

    var section = catalog_mod.Section{
        .name = "languages",
        .title = "Languages",
        .root = &root,
    };
    var entries = [_]SectionEntry{.{ .section = &section, .selected = true }};

    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded.deinit(allocator);

    try handleRight(allocator, &entries, &expanded, .snippet_select, 0, 0);
    try std.testing.expect(expanded.contains(directory.relative_path));
}

test "entering highlighted section without explicit selection is transient" {
    var language_root = catalog_mod.Node{
        .kind = .directory,
        .name = "languages",
        .relative_path = "languages",
        .title = "Languages",
        .parent = null,
    };
    var language_section = catalog_mod.Section{
        .name = "languages",
        .title = "Languages",
        .root = &language_root,
    };
    var tooling_root = catalog_mod.Node{
        .kind = .directory,
        .name = "tooling",
        .relative_path = "tooling",
        .title = "Tooling",
        .parent = null,
    };
    var tooling_section = catalog_mod.Section{
        .name = "tooling",
        .title = "Tooling",
        .root = &tooling_root,
    };
    var entries = [_]SectionEntry{
        .{ .section = &language_section },
        .{ .section = &tooling_section },
    };

    var section_cursor: usize = 0;
    try std.testing.expect(beginSnippetStageFromSections(&entries, 1, &section_cursor));
    try std.testing.expectEqual(@as(usize, 1), section_cursor);
    try std.testing.expect(!entries[1].selected);
}

test "back from snippet selection returns to the current section" {
    var stage: Stage = .snippet_select;
    var cursor: usize = 0;

    try std.testing.expect(handleBack(&stage, &cursor, 1));
    try std.testing.expectEqual(Stage.section_select, stage);
    try std.testing.expectEqual(@as(usize, 1), cursor);
}

test "enter selects highlighted snippet when none are selected" {
    const allocator = std.testing.allocator;
    var root = catalog_mod.Node{
        .kind = .directory,
        .name = "languages",
        .relative_path = "languages",
        .title = "Languages",
        .parent = null,
    };
    var file = catalog_mod.Node{
        .kind = .file,
        .name = "python.md",
        .relative_path = "languages/python.md",
        .title = "Python",
        .parent = &root,
        .source = .{ .content = "", .promoted_title = null },
    };
    try root.children.append(allocator, &file);
    defer root.children.deinit(allocator);

    var section = catalog_mod.Section{
        .name = "languages",
        .title = "Languages",
        .root = &root,
    };
    var entries = [_]SectionEntry{.{ .section = &section, .selected = true }};

    var selected: std.StringHashMapUnmanaged(void) = .empty;
    defer selected.deinit(allocator);
    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded.deinit(allocator);
    var section_cursor: usize = 0;

    try ensureCurrentSnippetSelected(allocator, &entries, &selected, &expanded, 0, &section_cursor);
    try std.testing.expect(selected.contains(file.relative_path));
}

test "enter selects highlighted snippet for the current section" {
    const allocator = std.testing.allocator;
    var first_root = catalog_mod.Node{
        .kind = .directory,
        .name = "tooling",
        .relative_path = "tooling",
        .title = "Tooling",
        .parent = null,
    };
    var first_file = catalog_mod.Node{
        .kind = .file,
        .name = "task-runner.md",
        .relative_path = "tooling/task-runner.md",
        .title = "Task Runner",
        .parent = &first_root,
        .source = .{ .content = "", .promoted_title = null },
    };
    try first_root.children.append(allocator, &first_file);
    defer first_root.children.deinit(allocator);

    var second_root = catalog_mod.Node{
        .kind = .directory,
        .name = "languages",
        .relative_path = "languages",
        .title = "Languages",
        .parent = null,
    };
    var second_file = catalog_mod.Node{
        .kind = .file,
        .name = "python.md",
        .relative_path = "languages/python.md",
        .title = "Python",
        .parent = &second_root,
        .source = .{ .content = "", .promoted_title = null },
    };
    try second_root.children.append(allocator, &second_file);
    defer second_root.children.deinit(allocator);

    var first_section = catalog_mod.Section{
        .name = "tooling",
        .title = "Tooling",
        .root = &first_root,
    };
    var second_section = catalog_mod.Section{
        .name = "languages",
        .title = "Languages",
        .root = &second_root,
    };
    var entries = [_]SectionEntry{
        .{ .section = &first_section, .selected = true },
        .{ .section = &second_section, .selected = true },
    };

    var selected: std.StringHashMapUnmanaged(void) = .empty;
    defer selected.deinit(allocator);
    try selected.put(allocator, first_file.relative_path, {});
    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded.deinit(allocator);
    var section_cursor: usize = 1;

    try ensureCurrentSnippetSelected(allocator, &entries, &selected, &expanded, 0, &section_cursor);
    try std.testing.expect(selected.contains(first_file.relative_path));
    try std.testing.expect(selected.contains(second_file.relative_path));
}
