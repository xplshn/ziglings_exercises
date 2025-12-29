//
// Great news! Now we know enough to understand a "real" Hello World
// program in Zig - one that uses the system Standard Out resource...which
// can fail!
//
const std = @import("std");

// Instance for input/output operations, we'll learn how to create them later.
const io = std.Options.debug_io;

// Take note that this main() definition now returns "!void" rather
// than just "void". Since there's no specific error type, this means
// that Zig will infer the error type. This is appropriate in the case
// of main(), but can make a function harder (function pointers) or
// even impossible to work with (recursion) in some situations.
//
// You can find more information at:
// https://ziglang.org/documentation/master/#Inferred-Error-Sets
//
pub fn main() !void {
    // We get a Writer for Standard Out...
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    // ...and extract its interface so we can print() to it.
    const stdout = &stdout_writer.interface;

    // Unlike std.debug.print(), the Standard Out writer can fail
    // with an error. We don't care _what_ the error is, we want
    // to be able to pass it up as a return value of main().
    //
    // We just learned of a single statement which can accomplish this.
    stdout.print("Hello world!\n", .{});
}
