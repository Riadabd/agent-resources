//! Core library for the agents-gen tool.

pub const catalog = @import("catalog.zig");
pub const cli = @import("cli.zig");
pub const interactive = @import("interactive.zig");
pub const output = @import("output.zig");
pub const render = @import("render.zig");
pub const terminal = @import("terminal.zig");

test {
    _ = catalog;
    _ = cli;
    _ = interactive;
    _ = output;
    _ = render;
    _ = terminal;
}
