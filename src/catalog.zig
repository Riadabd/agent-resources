//! Catalog discovery and snippet tree handling.

const std = @import("std");

const max_file_bytes = 1024 * 1024;

pub const Error = error{
    InvalidCatalogRoot,
    NoSnippetsFound,
};

pub const NodeKind = enum {
    directory,
    file,
};

pub const FileSource = struct {
    content: []const u8,
    promoted_title: ?[]const u8,
};

pub const Node = struct {
    kind: NodeKind,
    name: []const u8,
    relative_path: []const u8,
    title: []const u8,
    parent: ?*Node,
    children: std.ArrayListUnmanaged(*Node) = .empty,
    source: ?FileSource = null,

    pub fn fileCount(self: *const Node) usize {
        return switch (self.kind) {
            .file => 1,
            .directory => blk: {
                var count: usize = 0;
                for (self.children.items) |child| {
                    count += child.fileCount();
                }
                break :blk count;
            },
        };
    }
};

pub const Section = struct {
    name: []const u8,
    title: []const u8,
    root: *Node,
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    root_path: []const u8,
    sections: std.ArrayListUnmanaged(*Section) = .empty,
    files_by_path: std.StringHashMapUnmanaged(*Node) = .empty,

    pub fn discover(allocator: std.mem.Allocator, root_path: []const u8) !Catalog {
        const resolved_root = std.fs.cwd().realpathAlloc(allocator, root_path) catch {
            return Error.InvalidCatalogRoot;
        };
        defer allocator.free(resolved_root);

        var catalog = Catalog{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .root_path = undefined,
        };
        errdefer catalog.deinit();
        const arena_allocator = catalog.arena.allocator();
        catalog.root_path = try arena_allocator.dupe(u8, resolved_root);

        var dir = std.fs.openDirAbsolute(catalog.root_path, .{ .iterate = true }) catch {
            return Error.InvalidCatalogRoot;
        };
        defer dir.close();

        var walker = try dir.walk(arena_allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
            try catalog.addFileEntry(dir, entry.path);
        }

        if (catalog.files_by_path.count() == 0) {
            return Error.NoSnippetsFound;
        }

        sortCatalog(&catalog);
        return catalog;
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn collectAllFilePaths(self: *const Catalog, allocator: std.mem.Allocator) ![][]const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);

        for (self.sections.items) |section| {
            try collectFilePaths(&paths, allocator, section.root);
        }

        return try paths.toOwnedSlice(allocator);
    }

    pub fn findFileByRelativePath(self: *const Catalog, relative_path: []const u8) ?*Node {
        return self.files_by_path.get(relative_path);
    }

    pub fn findSection(self: *const Catalog, name: []const u8) ?*Section {
        for (self.sections.items) |section| {
            if (sectionMatchesFilter(section.name, name)) return section;
        }
        return null;
    }

    fn addFileEntry(self: *Catalog, dir: std.fs.Dir, relative_path: []const u8) !void {
        const arena_allocator = self.arena.allocator();
        var parts_iter = std.mem.splitScalar(u8, relative_path, std.fs.path.sep);
        const section_name_raw = parts_iter.next() orelse return;
        const section = try self.getOrCreateSection(section_name_raw);

        var current = section.root;
        var path_builder: std.ArrayList(u8) = .empty;
        defer path_builder.deinit(arena_allocator);
        try path_builder.appendSlice(arena_allocator, section.name);

        while (parts_iter.next()) |part| {
            const is_last = parts_iter.peek() == null;
            try path_builder.append(arena_allocator, std.fs.path.sep);
            try path_builder.appendSlice(arena_allocator, part);
            const full_relative_path = try arena_allocator.dupe(u8, path_builder.items);

            if (is_last) {
                const content = try dir.readFileAlloc(arena_allocator, relative_path, max_file_bytes);
                const promoted_title = leadingTitle(content);
                const title = if (promoted_title) |value|
                    try arena_allocator.dupe(u8, value)
                else
                    try formatSegmentTitleAlloc(arena_allocator, std.fs.path.stem(part));

                const node = try arena_allocator.create(Node);
                node.* = .{
                    .kind = .file,
                    .name = try arena_allocator.dupe(u8, part),
                    .relative_path = full_relative_path,
                    .title = title,
                    .parent = current,
                    .source = .{
                        .content = content,
                        .promoted_title = if (promoted_title) |value|
                            try arena_allocator.dupe(u8, value)
                        else
                            null,
                    },
                };
                try current.children.append(arena_allocator, node);
                try self.files_by_path.put(arena_allocator, node.relative_path, node);
            } else {
                current = try getOrCreateDirectoryNode(arena_allocator, current, part, full_relative_path);
            }
        }
    }

    fn getOrCreateSection(self: *Catalog, raw_name: []const u8) !*Section {
        for (self.sections.items) |section| {
            if (std.mem.eql(u8, section.name, raw_name)) return section;
        }

        const arena_allocator = self.arena.allocator();
        const section_name = try arena_allocator.dupe(u8, raw_name);
        const root_node = try arena_allocator.create(Node);
        root_node.* = .{
            .kind = .directory,
            .name = section_name,
            .relative_path = section_name,
            .title = try sectionTitleAlloc(arena_allocator, section_name),
            .parent = null,
        };

        const section = try arena_allocator.create(Section);
        section.* = .{
            .name = section_name,
            .title = root_node.title,
            .root = root_node,
        };
        try self.sections.append(arena_allocator, section);
        return section;
    }
};

pub fn writeCatalogListing(
    writer: *std.Io.Writer,
    catalog: *const Catalog,
    maybe_section: ?[]const u8,
) !void {
    for (catalog.sections.items) |section| {
        if (maybe_section) |filter| {
            if (!sectionMatchesFilter(section.name, filter)) continue;
        }

        try writer.print("{s}\n", .{section.title});
        try writeSectionListing(writer, section.root, 1);
        try writer.writeAll("\n");
    }
}

pub fn sectionTitleAlloc(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (sectionMatchesFilter(name, "quick-summary")) return allocator.dupe(u8, "Quick Summary");
    if (sectionMatchesFilter(name, "mindset")) return allocator.dupe(u8, "Mindset");
    if (sectionMatchesFilter(name, "tooling")) return allocator.dupe(u8, "Tooling");
    if (sectionMatchesFilter(name, "testing")) return allocator.dupe(u8, "Testing");
    if (sectionMatchesFilter(name, "language")) return allocator.dupe(u8, "Languages");
    if (sectionMatchesFilter(name, "communication")) return allocator.dupe(u8, "Communication Preferences");
    if (sectionMatchesFilter(name, "environment")) return allocator.dupe(u8, "Environment And Setup");
    return formatSegmentTitleAlloc(allocator, name);
}

pub fn sectionMatchesFilter(section_name: []const u8, filter: []const u8) bool {
    const normalized_section = canonicalSectionKey(section_name);
    const normalized_filter = canonicalSectionKey(filter);
    return std.mem.eql(u8, normalized_section, normalized_filter);
}

pub fn canonicalSectionKey(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "quick-summary")) return "quick-summary";
    if (std.mem.eql(u8, value, "mindset")) return "mindset";
    if (std.mem.eql(u8, value, "tooling")) return "tooling";
    if (std.mem.eql(u8, value, "testing")) return "testing";
    if (std.mem.eql(u8, value, "language") or std.mem.eql(u8, value, "languages")) return "language";
    if (std.mem.eql(u8, value, "communication") or std.mem.eql(u8, value, "communication-preferences")) return "communication";
    if (std.mem.eql(u8, value, "environment") or std.mem.eql(u8, value, "environment-and-setup")) return "environment";
    return value;
}

pub fn formatSegmentTitleAlloc(allocator: std.mem.Allocator, segment: []const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var capitalize_next = true;
    for (segment) |char| {
        switch (char) {
            '-', '_' => {
                try writer.writer.writeByte(' ');
                capitalize_next = true;
            },
            else => {
                var output_char = char;
                if (capitalize_next and char >= 'a' and char <= 'z') {
                    output_char = char - ('a' - 'A');
                }
                try writer.writer.writeByte(output_char);
                capitalize_next = char == ' ';
            },
        }
        if (char != '-' and char != '_') {
            capitalize_next = false;
        }
    }
    return try writer.toOwnedSlice();
}

fn sectionRank(name: []const u8) usize {
    const key = canonicalSectionKey(name);
    if (std.mem.eql(u8, key, "quick-summary")) return 0;
    if (std.mem.eql(u8, key, "mindset")) return 1;
    if (std.mem.eql(u8, key, "tooling")) return 2;
    if (std.mem.eql(u8, key, "testing")) return 3;
    if (std.mem.eql(u8, key, "language")) return 4;
    if (std.mem.eql(u8, key, "communication")) return 5;
    if (std.mem.eql(u8, key, "environment")) return 6;
    return std.math.maxInt(usize);
}

fn leadingTitle(content: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    var first_line = content[0..line_end];
    first_line = std.mem.trimRight(u8, first_line, "\r");
    if (first_line.len < 3) return null;
    if (!std.mem.startsWith(u8, first_line, "# ")) return null;
    return std.mem.trim(u8, first_line[2..], " \t");
}

fn sortCatalog(catalog: *Catalog) void {
    std.mem.sort(*Section, catalog.sections.items, {}, lessThanSection);
    for (catalog.sections.items) |section| {
        sortNode(section.root);
    }
}

fn sortNode(node: *Node) void {
    if (node.kind == .file) return;
    std.mem.sort(*Node, node.children.items, {}, lessThanNode);
    for (node.children.items) |child| {
        sortNode(child);
    }
}

fn lessThanSection(_: void, lhs: *Section, rhs: *Section) bool {
    const lhs_rank = sectionRank(lhs.name);
    const rhs_rank = sectionRank(rhs.name);
    if (lhs_rank != rhs_rank) return lhs_rank < rhs_rank;
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn lessThanNode(_: void, lhs: *Node, rhs: *Node) bool {
    if (lhs.kind != rhs.kind) return lhs.kind == .directory;
    return std.mem.lessThan(u8, lhs.relative_path, rhs.relative_path);
}

fn getOrCreateDirectoryNode(
    allocator: std.mem.Allocator,
    parent: *Node,
    part: []const u8,
    relative_path: []const u8,
) !*Node {
    for (parent.children.items) |child| {
        if (child.kind != .directory) continue;
        if (std.mem.eql(u8, child.name, part)) return child;
    }

    const node = try allocator.create(Node);
    node.* = .{
        .kind = .directory,
        .name = try allocator.dupe(u8, part),
        .relative_path = relative_path,
        .title = try formatSegmentTitleAlloc(allocator, part),
        .parent = parent,
    };
    try parent.children.append(allocator, node);
    return node;
}

fn collectFilePaths(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    node: *const Node,
) !void {
    switch (node.kind) {
        .file => try list.append(allocator, node.relative_path),
        .directory => for (node.children.items) |child| {
            try collectFilePaths(list, allocator, child);
        },
    }
}

fn writeSectionListing(writer: *std.Io.Writer, node: *const Node, depth: usize) !void {
    for (node.children.items) |child| {
        const indent = depth * 2;
        switch (child.kind) {
            .directory => {
                try writer.print("{s}- {s}/\n", .{ spaces(indent), child.relative_path });
                try writeSectionListing(writer, child, depth + 1);
            },
            .file => try writer.print("{s}- {s}\n", .{ spaces(indent), child.relative_path }),
        }
    }
}

fn spaces(count: usize) []const u8 {
    return "                                "[0..@min(count, 32)];
}

test "section aliases map to the same canonical key" {
    try std.testing.expect(sectionMatchesFilter("languages", "language"));
    try std.testing.expect(sectionMatchesFilter("communication-preferences", "communication"));
    try std.testing.expect(sectionMatchesFilter("environment-and-setup", "environment"));
}

test "title is read from the first markdown heading" {
    try std.testing.expectEqualStrings("Python", leadingTitle("# Python\nBody").?);
    try std.testing.expect(leadingTitle("## Not promoted\nBody") == null);
}

test "catalog discovers nested files and literal language names" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.makePath("languages/c++");
    try temp.dir.writeFile(.{ .sub_path = "languages/c++/core.md", .data = "# C++\ncontent\n" });
    try temp.dir.makePath("tooling");
    try temp.dir.writeFile(.{ .sub_path = "tooling/make.md", .data = "make\n" });

    const root_path = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    var catalog = try Catalog.discover(std.testing.allocator, root_path);
    defer catalog.deinit();

    try std.testing.expect(catalog.findSection("language") != null);
    try std.testing.expect(catalog.findFileByRelativePath("languages/c++/core.md") != null);
    try std.testing.expect(catalog.findFileByRelativePath("tooling/make.md") != null);
}
