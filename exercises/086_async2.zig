//
// Now that we know how to get an Io value, let's use it for
// asynchronous execution!
//
// io.async() launches a function and returns a Future. The result
// won't necessarily be available until you call .await() on it:
//
//     var future = io.async(someFunction, .{ arg1, arg2 });
//     // ... do other work here ...
//     const result = future.await(io);
//
// The function *may* run immediately or on another thread -
// your code doesn't need to care! That's the beauty of the
// Io abstraction. (In the Threaded backend, if no thread is
// available, the function runs synchronously right away and
// .await() just returns the already-computed result.)
//
// io.async() returns a Future(T) where T is the return type
// of the function you passed in. Future has two key methods:
//
//     .await(io)  - block until the result is ready, return it
//     .cancel(io) - request cancellation, then return the result
//
// Fix this program so that computeAnswer runs asynchronously
// and its result is properly awaited.
//
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Launch computeAnswer asynchronously.
    // io.async() takes a function and a tuple of its arguments.
    var future = io.async(computeAnswer, .{ 6, 7 });

    // Meanwhile, print something to show we're not blocked.
    std.debug.print("Computing... ", .{});

    // Now collect the result. What method on Future gives us
    // the value, blocking if it isn't ready yet?
    const answer = future.???(io);

    std.debug.print("The answer is: {}\n", .{answer});
}

fn computeAnswer(a: u32, b: u32) u32 {
    return a * b;
}
