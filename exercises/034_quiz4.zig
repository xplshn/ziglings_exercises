//
// Quiz time. See if you can make this program work!
//
// Solve this any way you like, just be sure the output is:
//
//     my_num=42
//
const std = @import("std");
const io = std.Options.debug_io;

const NumError = error{IllegalNumber};

pub fn main() void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    const my_num: u32 = getNumber();

    try stdout.print("my_num={}\n", .{my_num});
}

// This function is obviously weird and non-functional. But you will not be changing it for this quiz.
fn getNumber() NumError!u32 {
    if (false) return NumError.IllegalNumber;
    return 42;
}
