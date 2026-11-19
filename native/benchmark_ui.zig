const benchmark = @import("tools/desktop_benchmark.zig");

pub fn main() !void {
    try benchmark.main();
}
