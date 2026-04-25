const std = @import("std");
const agents_gen = @import("agents_gen");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var command = try agents_gen.cli.parseArgs(gpa);
    defer command.deinit(gpa);

    switch (command) {
        .interactive => try runInteractive(gpa),
        .list => |opts| try runList(gpa, opts),
        .generate => |opts| try runGenerate(gpa, opts),
    }
}

fn runInteractive(allocator: std.mem.Allocator) !void {
    var catalog = try agents_gen.catalog.Catalog.discover(allocator, "snippets");
    defer catalog.deinit();

    const maybe_result = try agents_gen.interactive.run(allocator, &catalog, ".");
    defer if (maybe_result) |result| result.deinit(allocator);

    if (maybe_result) |result| {
        const rendered = try agents_gen.render.renderSelection(allocator, &catalog, result.paths);
        defer allocator.free(rendered);

        try agents_gen.output.writeMarkdownToPreview(&result.preview, rendered);

        var buf: [4096]u8 = undefined;
        var writer = std.fs.File.stdout().writer(&buf);
        defer writer.interface.flush() catch {};
        if (result.preview.has_agents_file) {
            try writer.interface.print(
                "warning: existing AGENTS.md left untouched in {s}\n",
                .{result.preview.output_dir},
            );
        }
        try writer.interface.print("generated {s}\n", .{result.preview.path});
    }
}

fn runList(allocator: std.mem.Allocator, options: agents_gen.cli.ListOptions) !void {
    var catalog = try agents_gen.catalog.Catalog.discover(allocator, "snippets");
    defer catalog.deinit();

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    defer writer.interface.flush() catch {};

    try agents_gen.catalog.writeCatalogListing(&writer.interface, &catalog, options.section);
}

fn runGenerate(allocator: std.mem.Allocator, options: agents_gen.cli.GenerateOptions) !void {
    const root_path = options.snippets_root orelse "snippets";
    var catalog = try agents_gen.catalog.Catalog.discover(allocator, root_path);
    defer catalog.deinit();

    const selected_paths = if (options.snippets_root != null)
        try catalog.collectAllFilePaths(allocator)
    else
        try agents_gen.cli.resolveExplicitSelectionPaths(allocator, &catalog, options);
    defer allocator.free(selected_paths);

    const rendered = try agents_gen.render.renderSelection(allocator, &catalog, selected_paths);
    defer allocator.free(rendered);

    const write_result = try agents_gen.output.writeGeneratedMarkdown(
        allocator,
        options.output_dir,
        rendered,
        null,
    );
    defer write_result.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    defer writer.interface.flush() catch {};

    if (write_result.preview.has_agents_file) {
        try writer.interface.print(
            "warning: existing AGENTS.md left untouched in {s}\n",
            .{write_result.preview.output_dir},
        );
    }
    try writer.interface.print("generated {s}\n", .{write_result.preview.path});
}
