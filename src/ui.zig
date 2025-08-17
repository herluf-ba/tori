//! Simple UI Heirachy definition.
//! The `Heirachy` type let's you define tree-structures representing nested UI elements.
//! There's a basic styling system using a single axis flex-box implementation.

pub const Direction = enum { horizontal, vertical };
pub const Size = union(enum) { fixed: usize, fit, grow };
pub const Color = struct { r: u8, g: u8, b: u8 };
pub const Padding = struct { left: usize, right: usize, top: usize, bottom: usize };

/// The styling of a UI element.
pub const ElementStyle = struct {
    /// Sizing mode of this elements width.
    width: Size = .fit,
    /// Sizing mode of this elements height.
    height: Size = .fit,
    /// Children will be layed out in this direction
    direction: Direction = .horizontal,
    /// Internal spacing around the border of this element.
    padding: Padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    /// Spacing between children.
    gap: usize = 0,
    /// Background color.
    background: ?Color = null,
    /// Foreground (text) color.
    foreground: ?Color = null,
};

/// A node in the UI Hierachy.
pub const Element = struct {
    /// Computed x and y coordinates of the element.
    position: struct { x: usize, y: usize },
    /// Computed size of the element.
    size: struct { width: usize, height: usize },
    /// Styles used to compute position and size.
    style: ElementStyle,
    /// The node above this one in the hierachy.
    parent: ?*Element = null,
    /// Children of this node.
    children: ArrayList(*Element),
};

pub const Hierachy = struct {
    allocator: Allocator,

    /// Pointers to elements in this hierachy in depth first post order.
    /// This is the order the nodes were closed in and is used to calculate
    /// the size of each element.
    depth_first_post_order: ArrayList(*Element),

    /// The curently open element. Calling `open` will make child elements of this element.
    open_element: ?*Element,

    const Self = @This();

    /// Initialize a UI Hierachy.
    /// Use `open` and `close` to create a tree structure of `Element`s.
    pub fn init(allocator: Allocator) !Self {
        return .{ .allocator = allocator, .depth_first_post_order = ArrayList(*Element).init(allocator), .open_element = null };
    }

    pub fn deinit(self: *Self) void {
        for (self.depth_first_post_order.items) |element| {
            element.children.deinit();
            self.allocator.destroy(element);
        }
        self.depth_first_post_order.deinit();
    }

    /// Create a new `Element` in the hierachy and make it the currently 'open' element.
    /// Calling `open` again, creates a child of this element.
    /// Remember to call `close` to finish the element, when you are done adding children.
    pub fn open(self: *Self, style: ElementStyle) !void {
        // TODO: Validate styling:
        // - padding.left + padding.right < width
        // - padding.bottom + padding.top < height

        const elem = try self.allocator.create(Element);

        // Fill in size for fixed dimensions.
        const width = switch (style.width) {
            .fixed => |w| w,
            else => 0,
        };
        const height = switch (style.height) {
            .fixed => |h| h,
            else => 0,
        };

        elem.* = .{
            // We will compute the position relative to the parent element later.
            .position = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
            .style = style,
            .parent = self.open_element,
            .children = ArrayList(*Element).init(self.allocator),
        };
        self.open_element = elem;
    }

    /// Close the currently open element, making its parent the open element.
    pub fn close(self: *Self) !void {
        // TODO: Grow styling needs to fit first.

        if (self.open_element) |element| {
            try self.depth_first_post_order.append(element);
            self.open_element = element.parent;

            // Elements styled with fit sizing should add their padding to their final size.
            // They also need to add the accumulated child gap.
            const es = element.style;
            const accumulated_gap = if (element.children.items.len > 0) (element.children.items.len - 1) * es.gap else 0;
            if (es.width != .fixed) {
                element.size.width += es.padding.left + es.padding.right;
                if (es.direction == .horizontal) {
                    element.size.width += accumulated_gap;
                }
            }

            if (element.style.height != .fixed) {
                element.size.height += element.style.padding.top + element.style.padding.bottom;
                if (es.direction == .vertical) {
                    element.size.height += accumulated_gap;
                }
            }

            if (element.parent) |parent| {
                try parent.children.append(element);

                const ps = parent.style;
                // If the parent is not fixed size on its primary axis,
                // add width of closed child to the size of the parent on that axis.
                var maybe_on_axis: ?*usize = null;
                if (ps.direction == .horizontal and ps.width != .fixed) {
                    maybe_on_axis = &parent.size.width;
                }
                if (ps.direction == .vertical and ps.height != .fixed) {
                    maybe_on_axis = &parent.size.height;
                }

                if (maybe_on_axis) |on_axis| {
                    const element_size = switch (ps.direction) {
                        .horizontal => element.size.width,
                        .vertical => element.size.height,
                    };
                    on_axis.* += element_size;
                }

                // If the parent is not fixed size on its secondary axis,
                // grow parent size to hold child size if necessary.
                var maybe_cross_axis: ?*usize = null;
                if (ps.direction == .horizontal and ps.height != .fixed) {
                    maybe_cross_axis = &parent.size.height;
                }
                if (ps.direction == .vertical and ps.width != .fixed) {
                    maybe_cross_axis = &parent.size.width;
                }

                if (maybe_cross_axis) |cross_axis| {
                    const element_size = switch (ps.direction) {
                        .horizontal => element.size.height,
                        .vertical => element.size.width,
                    };
                    cross_axis.* = @max(cross_axis.*, element_size);
                }
            }
        } else return error.NO_OPEN_ELEMENT;
    }

    /// Computes the final size and position of all elements in the layout.
    /// You _must_ have closed all elements before calling `computeLayout`.
    pub fn computeLayout(self: *Self) void {
        // Must have closed the last element.
        std.debug.assert(self.open_element == null);
        // Must have atleast one element in the hierachy.
        std.debug.assert(self.depth_first_post_order.items.len > 0);

        // Compute the size of children with grow sizing.
        growChildren(self.root().?);

        // Compute positions of all elements.
        positionChildren(self.root().?);
    }

    pub fn root(self: *Self) ?*Element {
        return self.depth_first_post_order.getLastOrNull();
    }
};

/// Iterate through this elements children and grow children to distribute,
/// remaining space on the primary axis.
fn growChildren(element: *Element) void {
    if (element.children.items.len == 0) return; // No children to grow.

    const es = element.style;
    var remaining_on_axis = if (es.direction == .horizontal) element.size.width else element.size.height;
    remaining_on_axis -= if (es.direction == .horizontal) es.padding.left + es.padding.right else es.padding.top + es.padding.bottom;
    if (element.children.items.len > 0) {
        remaining_on_axis -= (element.children.items.len - 1) * es.gap;
    }
    for (element.children.items) |child| {
        remaining_on_axis -= if (es.direction == .horizontal) child.size.width else child.size.height;
    }

    // Grow the smallest children until all the remaining on axis space is distributed.
    brk: while (remaining_on_axis > 0) {
        // Determine the smallest and second smallest growable children.
        var smallest = @as(usize, std.math.maxInt(usize));
        var second_smallest = @as(usize, std.math.maxInt(usize));
        var width_to_add = remaining_on_axis;
        var num_children_with_grow = @as(usize, 0);
        for (element.children.items) |child| {
            const child_grows_on_axis = es.direction == .horizontal and child.style.width == .grow or es.direction == .vertical and child.style.height == .grow;
            if (!child_grows_on_axis) continue;
            num_children_with_grow += 1;

            const on_axis_size = if (es.direction == .horizontal) child.size.width else child.size.height;
            if (on_axis_size < smallest) {
                second_smallest = smallest;
                smallest = on_axis_size;
            }

            if (on_axis_size > smallest) {
                second_smallest = @min(second_smallest, on_axis_size);
                width_to_add = second_smallest - smallest;
            }
        }

        if (num_children_with_grow == 0) break :brk; // No growable children, no need to continue.

        // Grow all smallest children to be as larges as the second smallest.
        // If all growable children are the same size, distribute the remaining space evenly.
        width_to_add = @min(width_to_add, remaining_on_axis / num_children_with_grow);
        for (element.children.items) |child| {
            const child_grows_on_axis = es.direction == .horizontal and child.style.width == .grow or es.direction == .vertical and child.style.height == .grow;
            const on_axis_size = if (es.direction == .horizontal) child.size.width else child.size.height;
            // Grow the smallest children
            if (child_grows_on_axis and on_axis_size == smallest) {
                if (es.direction == .horizontal) {
                    child.size.width += width_to_add;
                } else {
                    child.size.height += width_to_add;
                }
                remaining_on_axis -= width_to_add;
            }
        }
    }

    // Now grow children that are growable along the cross axis.
    var remaining_cross_axis = if (es.direction == .horizontal) element.size.height else element.size.width;
    remaining_cross_axis -= if (es.direction == .horizontal) es.padding.top + es.padding.bottom else es.padding.left + es.padding.right;

    for (element.children.items) |child| {
        const child_grows_cross_axis = es.direction == .vertical and child.style.width == .grow or es.direction == .horizontal and child.style.height == .grow;
        if (child_grows_cross_axis) {
            if (es.direction == .horizontal) {
                child.size.height += (remaining_cross_axis - child.size.height);
            } else {
                child.size.width += (remaining_cross_axis - child.size.width);
            }
        }

        growChildren(child);
    }
}

fn positionChildren(element: *Element) void {
    // Iterate through this elements children and compute their on_axis positions.
    var offset = @as(usize, 0);
    for (element.children.items) |child| {
        child.position.x += element.position.x + element.style.padding.left;
        child.position.y += element.position.y + element.style.padding.top;
        switch (element.style.direction) {
            .horizontal => {
                child.position.x += offset;
                offset += child.size.width;
            },
            .vertical => {
                child.position.y += offset;
                offset += child.size.height;
            },
        }
        offset += element.style.gap;

        positionChildren(child);
    }
}

/// Create default editor UI within the passed hierachy.
pub fn defaultUI(UI: *Hierachy, terminal_size: term.TermSize, theme: anytype) !void {
    try UI.open(.{
        .direction = .vertical,
        .width = .{ .fixed = terminal_size.width },
        .height = .{ .fixed = terminal_size.height },
        .background = theme.bg0,
    });

    // Top-bar
    {
        try UI.open(.{
            .width = .grow,
            .height = .{ .fixed = 1 },
            .background = theme.bg1,
        });

        // Like a logo or something.
        try UI.open(.{
            .width = .{ .fixed = 2 },
            .height = .grow,
            .background = theme.blue0,
        });
        try UI.close();

        try UI.open(.{ .width = .grow });
        try UI.close();

        // Some button idk
        try UI.open(.{
            .width = .{ .fixed = 2 },
            .height = .grow,
            .background = theme.green0,
        });
        try UI.close();

        try UI.close();
    }

    // Main content area
    {
        try UI.open(.{
            .width = .grow,
            .height = .grow,
            .background = theme.bg0,
        });

        try UI.close();
    }

    // Bottom bar
    {
        try UI.open(.{
            .width = .grow,
            .height = .{ .fixed = 1 },
            .background = theme.bg1,
        });

        try UI.close();
    }

    try UI.close();
}

/// Parse a hex color. For ergonomics, invalid hex strings just return pink.
pub fn hex(comptime str: *const [6]u8) Color {
    const hot_pink = Color{ .r = 255, .g = 20, .b = 147 };
    const r = std.fmt.parseUnsigned(u8, str[0..2], 16) catch return hot_pink;
    const g = std.fmt.parseUnsigned(u8, str[2..4], 16) catch return hot_pink;
    const b = std.fmt.parseUnsigned(u8, str[4..6], 16) catch return hot_pink;
    return Color{ .r = r, .g = g, .b = b };
}

test "hex parse '000000'" {
    const c = hex("000000");
    try std.testing.expectEqual(0, c.r);
    try std.testing.expectEqual(0, c.g);
    try std.testing.expectEqual(0, c.b);
}

test "hex parse 'FFFFFF'" {
    const c = hex("FFFFFF");
    try std.testing.expectEqual(255, c.r);
    try std.testing.expectEqual(255, c.g);
    try std.testing.expectEqual(255, c.b);
}

test "hex parse '696969'" {
    const c = hex("696969");
    try std.testing.expectEqual(105, c.r);
    try std.testing.expectEqual(105, c.g);
    try std.testing.expectEqual(105, c.b);
}

test "hex parse gives pink on bad hex string" {
    const c = hex("FFFFFG");
    try std.testing.expectEqual(255, c.r);
    try std.testing.expectEqual(20, c.g);
    try std.testing.expectEqual(147, c.b);
}

test "hex parse gruvbox green" {
    const c = hex("98971A");
    try std.testing.expectEqual(152, c.r);
    try std.testing.expectEqual(151, c.g);
    try std.testing.expectEqual(26, c.b);
}

pub const GRUVBOX = struct {
    pub const bg0 = hex("282828"); // main background
    pub const bg0_s = hex("32302F");
    pub const bg1 = hex("3C3836");
    pub const bg2 = hex("504945");
    pub const bg3 = hex("665C54");
    pub const bg4 = hex("7C6F64");
    pub const fg0 = hex("FBF1C7");
    pub const fg1 = hex("EBDBB2"); // main foreground
    pub const fg2 = hex("D5C4A1");
    pub const fg3 = hex("BDAE93");
    pub const fg4 = hex("A89984");
    pub const gray = hex("928374");
    pub const red0 = hex("CC241D"); // neutral
    pub const red1 = hex("FB4934"); // bright
    pub const green0 = hex("98971A");
    pub const green1 = hex("B8BB26");
    pub const yellow0 = hex("D79921");
    pub const yellow1 = hex("FABD2F");
    pub const blue0 = hex("458588");
    pub const blue1 = hex("83A598");
    pub const purple0 = hex("B16286");
    pub const purple1 = hex("D3869B");
    pub const aqua0 = hex("689D6A");
    pub const aqua1 = hex("8EC07C");
    pub const orange0 = hex("D65D0E");
    pub const orange1 = hex("FE8019");
};

const std = @import("std");
const term = @import("term.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
