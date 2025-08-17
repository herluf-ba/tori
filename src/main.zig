//! Tori editor.

// TODO: Hide cursor, draw it manually some day
// TODO: App is blocked on reading input.
// Do I need like an input thread or what? Or like a render thread maybe?

pub fn main() !void {
    var should_quit = false;

    const stdin = std.io.getStdIn();
    const stdout_file = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout_file.writer());
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();

    // Get current window size
    try term.listenForResize();
    const terminal_size = try term.getSize(stdout_file);

    try term.rawOn();
    try stdout.writeAll(VT100.GO_TOP_LEFT ++ VT100.CLEAR);

    // Setup UI
    var UI = try ui.Hierachy.init(allocator);
    defer UI.deinit();
    try ui.defaultUI(&UI, terminal_size, ui.GRUVBOX);
    UI.computeLayout();

    // Draw UI
    const root = UI.root().?;
    try draw(stdout, root);

    try bw.flush();

    while (!should_quit) {
        if (term.NEEDS_RESIZE) {
            const new_size = try term.getSize(stdout_file);
            UI = try ui.Hierachy.init(allocator);
            defer UI.deinit();
            try ui.defaultUI(&UI, new_size, ui.GRUVBOX);
            UI.computeLayout();

            // Redraw
            try stdout.writeAll(VT100.GO_TOP_LEFT ++ VT100.CLEAR ++ VT100.CURSOR_HIDE);
            try draw(stdout, root);
            try bw.flush();
            term.NEEDS_RESIZE = false;
        }

        // Read input
        var ingest: [256]u8 = undefined;
        const bytes_read = try stdin.read(&ingest);
        if (bytes_read == ingest.len) return error.CommandTooLong;

        const command = ingest[0..bytes_read];
        switch (command[0]) {
            'q' => {
                should_quit = true;
            },
            else => {},
        }
    }

    // Now we should quit: clear the screen and turn off raw mode.
    try stdout.writeAll(VT100.FGWhite ++ VT100.BGBlack ++ VT100.GO_TOP_LEFT ++ VT100.CLEAR ++ VT100.CURSOR_SHOW);
    try bw.flush();
    try term.rawOff();
}

fn draw(out: anytype, element: *ui.Element) !void {
    // Move the cursor to the position of the element.
    // VT100 is one-indexed by the way.
    try out.print(VT100.GO_TO, .{ element.position.y + 1, element.position.x + 1 });

    // Set colors.
    if (element.style.foreground) |color| {
        try out.print(VT100.FG, .{ color.r, color.g, color.b });
    }
    if (element.style.background) |color| {
        try out.print(VT100.BG, .{ color.r, color.g, color.b });
    }

    // Draw the element.
    for (0..element.size.height) |_| {
        for (0..element.size.width) |_| {
            try out.writeByte(' ');
        }
        try out.writeAll(VT100.DOWN);
        try out.print(VT100.LEFT_N, .{element.size.width});
    }

    // Now draw it's children
    for (element.children.items) |child| {
        try draw(out, child);
    }
}

const std = @import("std");
const ui = @import("ui.zig");
const Size = ui.Size;
const Direction = ui.Direction;

const term = @import("term.zig");
const VT100 = term.VT100;

const editor = @import("editor.zig");
