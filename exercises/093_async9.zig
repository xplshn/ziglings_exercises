//
// We've been using io.async() to launch tasks. But there's a
// stronger variant: io.concurrent().
//
// The difference:
//
//   io.async():
//     * The function MAY run on a separate unit of concurrency,
//       or it may run immediately on the caller (synchronously).
//     * Never fails — if no concurrency is available, it just
//       runs the function right away.
//     * More portable, works with all Io backends.
//
//   io.concurrent():
//     * GUARANTEES a separate unit of concurrency.
//     * Can fail with error.ConcurrencyUnavailable if resources
//       are exhausted or the backend doesn't support it.
//     * Use when you NEED the task to run independently of the
//       caller.
//
// What is a "unit of concurrency"? That depends on the backend!
// The Threaded backend uses OS threads. But the Evented backends
// (Uring, Kqueue, Dispatch) use M:N green threads / fibers,
// which can provide concurrency even on a SINGLE OS thread.
// Your code doesn't need to know the difference.
//
// Because concurrent() can fail, you must handle the error:
//
//     var future = try io.concurrent(myFn, .{args});
//     defer _ = future.cancel(io);
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

    // Launch with a guaranteed separate unit of concurrency.
    // Which Io method guarantees this?
    // (Hint: unlike io.async, this one can fail!)
    var future = try io.???(compute, .{io});
    defer _ = future.cancel(io);

    // Note: All breaks in this excercise (using sleep)
    // are only necessary for a deterministic result.
    io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};

    print("Main continues...\n", .{});

    // Wait 1 second for the output order.
    io.sleep(std.Io.Duration.fromMilliseconds(200), .awake) catch {};

    print("Main done waiting.\n", .{});

    const result = future.await(io);
    print("Result: {}\n", .{result});
}

fn compute(io: std.Io) u32 {
    print("Computing concurrently!\n", .{});
    // Simulate some work.
    io.sleep(std.Io.Duration.fromMilliseconds(400), .awake) catch return 0;
    return 123;
}
