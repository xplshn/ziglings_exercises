//
// When there are multiple defers in a single block, they are executed in reverse order.
//
const std = @import("std");

pub fn main() void {
    var x: u32 = 100;
    {
        // Try reordering the statements to get the answer 42
        defer x = x / 10;
        defer x = x + 11;
        defer x = x * 2;

        // It might seem silly in this example, but it's important to know when
        // deinitializing containers whose elements need to be deinitialized first.
    }
    std.debug.print("{d}\n", .{x});
}
