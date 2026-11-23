const std = @import("std");

/// 4 DIP spacing grid tokens (96 DPI logical units).
pub const Space = struct {
    pub const xs: i32 = 4;
    pub const sm: i32 = 8;
    pub const md: i32 = 12;
    pub const lg: i32 = 16;
};

/// Standard control heights in 96 DPI logical units.
pub const Metrics = struct {
    pub const label: i32 = 20;
    pub const heading: i32 = 22;
    pub const input: i32 = 26;
    pub const button: i32 = 28;
    pub const combo: i32 = 26;
    pub const caption: i32 = 20;
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn inset(self: Rect, padding: i32) Rect {
        return .{
            .x = self.x + padding,
            .y = self.y + padding,
            .width = @max(0, self.width - 2 * padding),
            .height = @max(0, self.height - 2 * padding),
        };
    }

    pub fn withHeight(self: Rect, height: i32) Rect {
        return .{ .x = self.x, .y = self.y, .width = self.width, .height = height };
    }
};

/// Returns a Win32 placement rect for a ComboBox by adding dropdown list height
/// without affecting the single-line height tracked by VStack/HStack.
pub fn comboDropdown(rect: Rect, dropdown_height: i32) Rect {
    return .{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height + dropdown_height,
    };
}

/// Vertical stack layout builder in logical DIP units.
pub const VStack = struct {
    x: i32,
    cursor_y: i32,
    width: i32,
    gap: i32,
    has_item: bool = false,

    pub fn init(area: Rect, gap: i32) VStack {
        return .{
            .x = area.x,
            .cursor_y = area.y,
            .width = area.width,
            .gap = gap,
        };
    }

    pub fn row(self: *VStack, height: i32) Rect {
        if (self.has_item) self.cursor_y += self.gap;
        const rect: Rect = .{
            .x = self.x,
            .y = self.cursor_y,
            .width = self.width,
            .height = height,
        };
        self.cursor_y += height;
        self.has_item = true;
        return rect;
    }

    pub fn optionalRow(self: *VStack, visible: bool, height: i32) ?Rect {
        if (!visible) return null;
        return self.row(height);
    }

    pub fn spacer(self: *VStack, amount: i32) void {
        self.cursor_y += amount;
    }

    pub fn remaining(self: VStack, bottom_y: i32, reserved_below: i32, min_height: i32) i32 {
        const next_y = if (self.has_item) self.cursor_y + self.gap else self.cursor_y;
        return @max(min_height, bottom_y - next_y - reserved_below);
    }

    pub fn bottom(self: VStack) i32 {
        return self.cursor_y;
    }
};

/// Horizontal row layout builder supporting left-fixed, right-fixed, and flex-fill slots.
pub const HStack = struct {
    left: i32,
    right: i32,
    y: i32,
    height: i32,
    gap: i32,
    has_left: bool = false,
    has_right: bool = false,

    pub fn init(area: Rect, gap: i32) HStack {
        return .{
            .left = area.x,
            .right = area.x + area.width,
            .y = area.y,
            .height = area.height,
            .gap = gap,
        };
    }

    pub fn fixed(self: *HStack, width: i32) Rect {
        if (self.has_left) self.left += self.gap;
        const available = @max(0, self.right - self.left);
        const clamped = @min(width, available);
        const rect: Rect = .{
            .x = self.left,
            .y = self.y,
            .width = clamped,
            .height = self.height,
        };
        self.left += clamped;
        self.has_left = true;
        return rect;
    }

    pub fn fixedRight(self: *HStack, width: i32) Rect {
        if (self.has_right) self.right -= self.gap;
        const available = @max(0, self.right - self.left);
        const clamped = @min(width, available);
        self.right -= clamped;
        self.has_right = true;
        return .{
            .x = self.right,
            .y = self.y,
            .width = clamped,
            .height = self.height,
        };
    }

    pub fn fill(self: *HStack) Rect {
        const start = if (self.has_left) self.left + self.gap else self.left;
        const end = if (self.has_right) self.right - self.gap else self.right;
        const width = @max(0, end - start);
        self.left = start + width;
        self.has_left = true;
        return .{
            .x = start,
            .y = self.y,
            .width = width,
            .height = self.height,
        };
    }
};

test "VStack stacks rows, skips hidden rows, and calculates remaining flex height" {
    const area = (Rect{ .x = 0, .y = 0, .width = 400, .height = 300 }).inset(Space.md);
    var stack = VStack.init(area, Space.sm);
    const r1 = stack.row(20);
    try std.testing.expectEqual(Rect{ .x = 12, .y = 12, .width = 376, .height = 20 }, r1);
    try std.testing.expectEqual(@as(?Rect, null), stack.optionalRow(false, 60));
    const r2 = stack.row(26);
    try std.testing.expectEqual(Rect{ .x = 12, .y = 40, .width = 376, .height = 26 }, r2);
    const flex_h = stack.remaining(area.y + area.height, 40, 28);
    // next_y = 66 + 8 = 74, bottom_y = 288, reserved = 40 -> 174
    try std.testing.expectEqual(@as(i32, 174), flex_h);
    const r3 = stack.row(flex_h);
    try std.testing.expectEqual(@as(i32, 74), r3.y);
    try std.testing.expectEqual(@as(i32, 174), r3.height);
}

test "HStack allocates left, right, and fill slots without overlap" {
    var row = HStack.init(.{ .x = 12, .y = 12, .width = 500, .height = 28 }, Space.sm);
    const left = row.fixed(100);
    const right = row.fixedRight(110);
    const middle = row.fill();
    try std.testing.expectEqual(Rect{ .x = 12, .y = 12, .width = 100, .height = 28 }, left);
    try std.testing.expectEqual(Rect{ .x = 402, .y = 12, .width = 110, .height = 28 }, right);
    try std.testing.expectEqual(Rect{ .x = 120, .y = 12, .width = 274, .height = 28 }, middle);
    const combo = comboDropdown(middle, 180);
    try std.testing.expectEqual(@as(i32, 208), combo.height);
}
