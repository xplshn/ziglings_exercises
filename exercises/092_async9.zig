//
// We've been using io.async() to launch tasks. But there's a
// stronger variant: io.concurrent().
//
// The difference:
//
//   io.async():
//     * The function MAY run on another thread, or it may run
//       immediately on the current thread (synchronously).
//     * Never fails — if no thread is available, it just runs
//       the function right away.
//     * More portable, works with all Io backends.
//
//   io.concurrent():
//     * GUARANTEES a separate unit of concurrency (a real thread
//       in the Threaded backend).
//     * Can fail with error.ConcurrencyUnavailable if resources
//       are exhausted or the backend doesn't support it.
//     * Use when you NEED true parallelism.
//
// Because concurrent() can fail, you must handle the error:
//
//     var future = try io.concurrent(myFn, .{args});
//     const result = future.await(io);
//
// Notice the 'try' — that's the key difference in usage!
//
// Fix this program to launch the computation concurrently.
//
const std = @import("std");
const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Launch with a guaranteed separate thread.
    // Which Io method guarantees true concurrency?
    // (Hint: unlike io.async, this one can fail!)
    var future = try io.???(compute, .{io});

    print("Main thread continues...\n", .{});

    // Wait 100 millisecond so the output order is deterministic.
    io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};

    print("Main thread done waiting.\n", .{});

    const result = future.await(io);
    print("Result: {}\n", .{result});
}

fn compute(io: std.Io) u32 {
    print("Computing on a separate thread!\n", .{});
    // Simulate some work.
    io.sleep(std.Io.Duration.fromMilliseconds(200), .awake) catch return 0;
    return 123;
}
