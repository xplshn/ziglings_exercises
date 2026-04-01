//
// The real power of async shows when you launch MULTIPLE tasks!
//
// With io.async(), you can start several operations, then await
// them all. The Io backend may run them concurrently:
//
//     var f1 = io.async(taskA, .{});
//     var f2 = io.async(taskB, .{});
//
//     // Both tasks may be running now!
//     const a = f1.await(io);
//     const b = f2.await(io);
//
// There's also io.concurrent() which provides a STRONGER guarantee:
// it ensures the function gets its own unit of concurrency (e.g. a
// real OS thread). But it can fail with error.ConcurrencyUnavailable
// if resources are exhausted.
//
// io.async() is more portable: if no thread is available, it simply
// runs the function synchronously. This makes it the right default
// for most code.
//
// Fix this program to launch both tasks and collect their results.
//
const std = @import("std");
const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Launch both tasks asynchronously.
    var future_a = io.async(slowAdd, .{ 10, 20 });
    var future_b = ???(slowMul, .{ 6, 7 });

    // Await both results.
    const sum = future_a.await(io);
    const product = future_b.???(io);

    print("{} + {} = {}\n", .{ 1, 2, sum });
    print("{} * {} = {}\n", .{ 6, 7, product });
    print("Total: {}\n", .{sum + product});
}

fn slowAdd(a: u32, b: u32) u32 {
    return a + b;
}

fn slowMul(a: u32, b: u32) u32 {
    return a * b;
}
