// Elrond: Ziglings' exercise checker and guide.
//
// In the reworked Zig build system (configurer/maker split) a build Step no
// longer carries a `makeFn`, and the configure phase is cached and not re-run
// when build.zig is unchanged. So Elrond is a standalone program that owns
// the entire Ziglings logic: it holds the exercise list, reads/writes
// .progress.txt, and iterates through exercises itself -- compiling (via
// `zig run`), checking output, printing progress and hints.
// The build only ever launches this one program.
//
// Exit codes:
//   0  all requested exercises passed (or skipped, or --logo)
//   1  an exercise failed (compile error, output mismatch, runtime error)

const std = @import("std");
const builtin = @import("builtin");

const Process = std.process;
const print = std.debug.print;

const progress_filename = ".progress.txt";

pub const logo =
    \\         _       _ _
    \\     ___(_) __ _| (_)_ __   __ _ ___
    \\    |_  | |/ _' | | | '_ \ / _' / __|
    \\     / /| | (_| | | | | | | (_| \__ \
    \\    /___|_|\__, |_|_|_| |_|\__, |___/
    \\           |___/           |___/
    \\
    \\    "Look out! Broken programs below!"
    \\
    \\
;

// How Elrond was invoked.
const Mode = enum {
    // `zig build`: iterate from after the last solved exercise to the first
    // unsolved one (or the end).
    normal,
    // `zig build -Dn=n`: check exactly one exercise.
    named,
    // `zig build -Drandom`: check one random exercise.
    random,
    // `zig build -Ds=n`: iterate starting at exercise n.
    start,
};

const Kind = enum {
    // Run the artifact as a normal executable.
    exe,
    // Run the artifact as a test.
    @"test",
};

pub const Exercise = struct {
    // main_file must have the format key_name.zig.
    main_file: []const u8,

    // Desired output. A program passes if its output, excluding trailing
    // whitespace, equals this string.
    output: []const u8,

    // Optional hint shown if the program does not succeed.
    hint: ?[]const u8 = null,

    // By default, output is verified against stderr; set to check stdout.
    check_stdout: bool = false,

    // This exercise uses C functions; compile with libc.
    link_libc: bool = false,

    // Exercise kind.
    kind: Kind = .exe,

    // Not supported by the current Zig compiler.
    skip: bool = false,

    // Why this has been skipped.
    skip_hint: ?[]const u8 = null,

    timestamp: bool = false,

    // Name of the main file with .zig stripped.
    pub fn name(self: Exercise) []const u8 {
        return std.fs.path.stem(self.main_file);
    }

    // Key of the main file: the string before the '_' with zero padding
    // removed. "001_hello.zig" -> "1".
    pub fn key(self: Exercise) []const u8 {
        const end_index = std.mem.indexOfScalar(u8, self.main_file, '_') orelse
            unreachable;
        var start_index: usize = 0;
        while (self.main_file[start_index] == '0') start_index += 1;
        return self.main_file[start_index..end_index];
    }

    // Exercise key as an integer.
    pub fn number(self: Exercise) usize {
        return std.fmt.parseInt(usize, self.key(), 10) catch unreachable;
    }
};

var use_color_escapes = false;
var red_text: []const u8 = "";
var red_bold_text: []const u8 = "";
var red_dim_text: []const u8 = "";
var green_text: []const u8 = "";
var bold_text: []const u8 = "";
var reset_text: []const u8 = "";

fn setupColors(io: std.Io) void {
    use_color_escapes = false;
    const stderr = std.Io.File.stderr();
    if (stderr.supportsAnsiEscapeCodes(io)) |ok| {
        if (ok) use_color_escapes = true;
    } else |_| {}
    if (!use_color_escapes and builtin.os.tag == .windows) {
        if (stderr.enableAnsiEscapeCodes(io)) {
            use_color_escapes = true;
        } else |_| {}
    }
    if (use_color_escapes) {
        red_text = "\x1b[31m";
        red_bold_text = "\x1b[31;1m";
        red_dim_text = "\x1b[31;2m";
        green_text = "\x1b[32m";
        bold_text = "\x1b[1m";
        reset_text = "\x1b[0m";
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    const args = try init.minimal.args.toSlice(gpa);

    setupColors(io);

    if (!validateExercises()) std.process.exit(1);

    var zig_exe: []const u8 = "zig";
    var work_path: []const u8 = "exercises";
    var mode: Mode = .normal;
    var only_n: ?usize = null;
    var start_n: ?usize = null;

    for (1..args.len) |n| {
        const arg = args[n];
        if (std.mem.eql(u8, arg, "--logo")) {
            print("{s}", .{logo});
            return;
        } else if (std.mem.eql(u8, arg, "--reset")) {
            std.Io.Dir.cwd().deleteFile(io, progress_filename) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    print("Unable to remove progress file: {}\n", .{err});
                    std.process.exit(1);
                },
            };
            print("Progress reset, {s} removed.\n", .{progress_filename});
            return;
        } else if (prefix(arg, "--zig=")) |v| {
            zig_exe = v;
        } else if (prefix(arg, "--work-path=")) |v| {
            work_path = v;
        } else if (prefix(arg, "--only=")) |v| {
            only_n = std.fmt.parseInt(usize, v, 10) catch {
                print("invalid --only value: {s}\n", .{v});
                std.process.exit(1);
            };
            mode = .named;
        } else if (prefix(arg, "--start=")) |v| {
            start_n = std.fmt.parseInt(usize, v, 10) catch {
                print("invalid --start value: {s}\n", .{v});
                std.process.exit(1);
            };
            mode = .start;
        } else if (std.mem.eql(u8, arg, "--random")) {
            mode = .random;
        } else {
            print("unknown argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    print("{s}", .{logo});

    const ctx: Context = .{ .io = io, .gpa = gpa, .zig_exe = zig_exe, .work_path = work_path };

    switch (mode) {
        .named => {
            const n = only_n.?;
            if (n == 0 or n > exercises.len - 1) {
                print("unknown exercise number: {}\n", .{n});
                std.process.exit(1);
            }
            runOne(ctx, exercises[n - 1], .named) catch std.process.exit(1);
        },
        .random => {
            var prng = std.Random.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                io.random(std.mem.asBytes(&seed));
                break :blk seed;
            });
            const num = prng.random().intRangeLessThan(usize, 0, exercises.len);
            print("random exercise: {s}\n", .{exercises[num].main_file});
            runOne(ctx, exercises[num], .random) catch std.process.exit(1);
        },
        .start => {
            const s = start_n.?;
            if (s == 0 or s > exercises.len - 1) {
                print("unknown exercise number: {}\n", .{s});
                std.process.exit(1);
            }
            // Iterate from exercise s to the end (or first failure).
            iterateFrom(ctx, s - 1) catch std.process.exit(1);
        },
        .normal => {
            // Start after the last solved exercise recorded in .progress.txt.
            const solved = readProgress(io, gpa);
            var start_index: usize = 0;
            for (exercises, 0..) |ex, idx| {
                if (solved < ex.number()) {
                    start_index = idx;
                    break;
                }
            } else {
                // All solved.
                print("{s}All exercises completed!{s}\n", .{ green_text, reset_text });
                return;
            }
            iterateFrom(ctx, start_index) catch std.process.exit(1);
        },
    }
}

fn prefix(arg: []const u8, pre: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, pre)) return arg[pre.len..];
    return null;
}

// Shared, read-only run context threaded through the helpers.
const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    work_path: []const u8,
};

const Error = error{Failed};

// Iterates exercises from `start_index` to the end, stopping at the first
// failure. Progress is written after each passed exercise.
fn iterateFrom(ctx: Context, start_index: usize) Error!void {
    for (exercises[start_index..]) |ex| {
        try runOne(ctx, ex, .normal);
    }
}

// Checks a single exercise: progress bar, compile+run (or test), output
// verification, progress file update on success, hint on failure.
fn runOne(ctx: Context, ex: Exercise, mode: Mode) Error!void {
    if (ex.skip) {
        print("Skipping {s}", .{ex.main_file});
        if (ex.skip_hint) |hint|
            print("\n{s}Reason: {s}{s}\n", .{ bold_text, hint, reset_text });
        print("\n\n", .{});
        return;
    }

    printProgress(ex.number(), exercises.len - 1);

    switch (ex.kind) {
        .exe => runExe(ctx, ex) catch {
            hintAndHelp(ex, mode);
            return Error.Failed;
        },
        .@"test" => runTest(ctx, ex) catch {
            hintAndHelp(ex, mode);
            return Error.Failed;
        },
    }

    writeProgress(ctx.io, ctx.gpa, ex.number()) catch {};
}

fn hintAndHelp(ex: Exercise, mode: Mode) void {
    if (ex.hint) |hint|
        print("\n{s}Ziglings hint: {s}{s}", .{ bold_text, hint, reset_text });
    help(ex, mode);
}

fn printProgress(num: usize, max: usize) void {
    const bar_width = 60;
    const safe_max = if (max == 0) 1 else max;
    const filled_len_u64 = (@as(u64, num) * bar_width) / safe_max;
    const filled_len = @as(u32, @intCast(filled_len_u64));

    var bar_buf: [bar_width]u8 = undefined;
    for (0..bar_width) |n| {
        const ord = std.math.order(n, filled_len);
        bar_buf[n] = switch (ord) {
            .lt => '#',
            .eq => '>',
            .gt => '-',
        };
    }
    print("\rProgress: [{s}]  {d}/{d}\n\n", .{ &bar_buf, num, max });
}

fn runExe(ctx: Context, ex: Exercise) !void {
    const io = ctx.io;
    const gpa = ctx.gpa;
    print("Compiling {s}...\n", .{ex.main_file});

    const path = std.fs.path.join(gpa, &.{ ctx.work_path, ex.main_file }) catch
        @panic("OOM");

    var argv = std.ArrayList([]const u8).initCapacity(gpa, 8) catch @panic("OOM");
    defer argv.deinit(gpa);
    argv.append(gpa, ctx.zig_exe) catch @panic("OOM");
    argv.append(gpa, "run") catch @panic("OOM");
    if (ex.link_libc) {
        argv.append(gpa, "-lc") catch @panic("OOM");
        argv.append(gpa, "-fllvm") catch @panic("OOM");
    }
    argv.append(gpa, path) catch @panic("OOM");

    // `zig run` compiles and runs in one step using Zig's own cache.
    const result = Process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        print("{s}error:{s} unable to run {s}: {s}\n", .{
            red_bold_text, reset_text, ex.main_file, @errorName(err),
        });
        return err;
    };

    resetLine();
    print("Checking {s}...\n", .{ex.main_file});

    return checkOutput(io, gpa, ex, result);
}

fn runTest(ctx: Context, ex: Exercise) !void {
    const io = ctx.io;
    const gpa = ctx.gpa;
    print("Compiling {s}...\n", .{ex.main_file});

    const path = std.fs.path.join(gpa, &.{ ctx.work_path, ex.main_file }) catch
        @panic("OOM");

    var argv = std.ArrayList([]const u8).initCapacity(gpa, 8) catch @panic("OOM");
    defer argv.deinit(gpa);
    argv.append(gpa, ctx.zig_exe) catch @panic("OOM");
    argv.append(gpa, "test") catch @panic("OOM");
    if (ex.link_libc) {
        argv.append(gpa, "-lc") catch @panic("OOM");
        argv.append(gpa, "-fllvm") catch @panic("OOM");
    }
    argv.append(gpa, path) catch @panic("OOM");

    const result = Process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        print("{s}error:{s} unable to run test {s}: {s}\n", .{
            red_bold_text, reset_text, ex.main_file, @errorName(err),
        });
        return err;
    };

    resetLine();
    print("Checking {s}...\n", .{ex.main_file});

    return checkTest(ex, result);
}

fn checkOutput(io: std.Io, gpa: std.mem.Allocator, ex: Exercise, result: Process.RunResult) !void {
    switch (result.term) {
        .exited => |code| if (code != 0) {
            // `zig run` puts both compile errors and runtime panics on stderr;
            // show them so the "read the compiler messages above" hint applies.
            const diag = std.mem.trimEnd(u8, result.stderr, " \r\n");
            if (diag.len > 0) print("{s}\n", .{diag});
            return Error.Failed;
        },
        else => {
            print("{s}{s} terminated unexpectedly{s}\n", .{
                red_bold_text, ex.main_file, reset_text,
            });
            return Error.Failed;
        },
    }

    const raw_output = if (ex.check_stdout) result.stdout else result.stderr;
    const output = trimLines(gpa, raw_output) catch @panic("OOM");

    var exercise_output = ex.output;
    if (ex.timestamp) {
        var ts_buf: [20]u8 = undefined;
        const ts_slice = output[14..24];
        const ts_value = try std.fmt.parseInt(i64, ts_slice, 10);
        const ts_build = std.Io.Timestamp.now(io, .real).toSeconds();
        const ts_diff = @abs(ts_build - ts_value);
        const timestamp = std.fmt.bufPrint(
            &ts_buf,
            "{}",
            .{if (ts_diff < 5) ts_value else ts_build},
        ) catch unreachable;

        var buf: [100]u8 = undefined;
        const prefix_len = 14;
        const placeholder_len = 11;
        @memcpy(buf[0..prefix_len], exercise_output[0..prefix_len]);
        @memcpy(buf[prefix_len..][0..timestamp.len], timestamp);
        const suffix = exercise_output[prefix_len + placeholder_len ..];
        const suffix_dest_start = prefix_len + timestamp.len;
        @memcpy(buf[suffix_dest_start..][0..suffix.len], suffix);
        const total_len = prefix_len + timestamp.len + suffix.len;
        exercise_output = buf[0..total_len];
    }

    if (!std.mem.eql(u8, output, exercise_output)) {
        const red = red_bold_text;
        const reset = reset_text;
        print(
            \\
            \\{s}========= expected this output: =========={s}
            \\{s}
            \\{s}========= but found: ====================={s}
            \\{s}
            \\{s}=========================================={s}
        ++ "\n", .{ red, reset, exercise_output, red, reset, output, red, reset });
        return Error.Failed;
    }

    print("{s}PASSED:\n{s}{s}\n\n", .{ green_text, output, reset_text });
}

fn checkTest(ex: Exercise, result: Process.RunResult) !void {
    switch (result.term) {
        .exited => |code| if (code != 0) {
            const stderr = std.mem.trimEnd(u8, result.stderr, " \r\n");
            print("\n{s}\n", .{stderr});
            return Error.Failed;
        },
        else => {
            print("{s}{s} terminated unexpectedly{s}\n", .{
                red_bold_text, ex.main_file, reset_text,
            });
            return Error.Failed;
        },
    }
    print("{s}PASSED{s}\n\n", .{ green_text, reset_text });
}

fn help(ex: Exercise, mode: Mode) void {
    const cmd = switch (mode) {
        .normal, .start => "zig build",
        .named => "zig build -Dn=...",
        .random => "zig build -Drandom",
    };
    print("\n{s}Edit exercises/{s} and run '{s}' again.{s}\n", .{
        red_bold_text, ex.main_file, cmd, reset_text,
    });
}

fn resetLine() void {
    if (use_color_escapes) print("{s}", .{"\x1b[2K\r"});
}

// Removes trailing whitespace per line and any trailing LF at the end.
fn trimLines(gpa: std.mem.Allocator, buf: []const u8) ![]const u8 {
    var list = try std.ArrayList(u8).initCapacity(gpa, buf.len);
    errdefer list.deinit(gpa);

    var iter = std.mem.splitSequence(u8, buf, " \n");
    while (iter.next()) |line| {
        const data = std.mem.trimEnd(u8, line, " \r");
        try list.appendSlice(gpa, data);
        try list.append(gpa, '\n');
    }
    const result = try list.toOwnedSlice(gpa);
    return std.mem.trimEnd(u8, result, "\n");
}

// Reads the last solved exercise number from .progress.txt; 0 if absent.
fn readProgress(io: std.Io, gpa: std.mem.Allocator) u32 {
    const file = std.Io.Dir.cwd().openFile(io, progress_filename, .{}) catch return 0;
    defer file.close(io);

    const size = file.length(io) catch return 0;
    if (size == 0) return 0;
    const contents = gpa.alloc(u8, size) catch return 0;
    var file_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const n = reader.interface.readSliceShort(contents) catch return 0;
    const trimmed = std.mem.trim(u8, contents[0..n], " \r\n");
    return std.fmt.parseInt(u32, trimmed, 10) catch 0;
}

fn writeProgress(io: std.Io, gpa: std.mem.Allocator, number: usize) !void {
    const progress = try std.fmt.allocPrint(gpa, "{d}", .{number});
    const file = try std.Io.Dir.cwd().createFile(
        io,
        progress_filename,
        .{ .read = true, .truncate = true },
    );
    defer file.close(io);
    try file.writeStreamingAll(io, progress);
    try file.sync(io);
}

// Checks that each exercise number (except the last) forms the sequence
// [1, exercises.len), and that output lines have no trailing whitespace.
fn validateExercises() bool {
    var i: usize = 0;
    for (exercises[0..]) |ex| {
        const exno = ex.number();
        const last = 999;
        i += 1;

        if (exno != i and exno != last) {
            print("exercise {s} has an incorrect number: expected {}, got {s}\n", .{
                ex.main_file, i, ex.key(),
            });
            return false;
        }

        var iter = std.mem.splitScalar(u8, ex.output, '\n');
        while (iter.next()) |line| {
            const out = std.mem.trimEnd(u8, line, " \r");
            if (out.len != line.len) {
                print("exercise {s} output field lines have trailing whitespace\n", .{
                    ex.main_file,
                });
                return false;
            }
        }

        if (!std.mem.endsWith(u8, ex.main_file, ".zig")) {
            print("exercise {s} is not a zig source file\n", .{ex.main_file});
            return false;
        }
    }
    return true;
}

const exercises = [_]Exercise{
    .{
        .main_file = "001_hello.zig",
        .output = "Hello world!",
        .hint =
        \\DON'T PANIC!
        \\Read the compiler messages above. (Something about 'main'?)
        \\Open up the source file as noted below and read the comments.
        \\
        \\(Hints like these will occasionally show up, but for the
        \\most part, you'll be taking directions from the Zig
        \\compiler itself.)
        \\
        , // pay attention to the comma
    },
    .{
        .main_file = "002_std.zig",
        .output = "Standard Library.",
    },
    .{
        .main_file = "003_assignment.zig",
        .output = "55 314159 -11",
        .hint = "There are three mistakes in this one!",
    },
    .{
        .main_file = "004_arrays.zig",
        .output = "First: 2, Fourth: 7, Length: 8",
        .hint = "There are two things to complete here.",
    },
    .{
        .main_file = "005_arrays2.zig",
        .output = "LEET: 1337, Bits: 100110011001",
        .hint = "Fill in the two arrays.",
    },
    .{
        .main_file = "006_strings.zig",
        .output = "d=d Major Tom",
        .hint = "Each '???' needs something filled in.",
    },
    .{
        .main_file = "007_strings2.zig",
        .output =
        \\Ziggy played guitar
        \\Jamming good with Andrew Kelley
        \\And the Spiders from Mars
        , // pay attention to the comma
        .hint = "Please fix the lyrics!",
    },
    .{
        .main_file = "008_quiz.zig",
        .output = "Program in Zig!",
        .hint = "See if you can fix the program!",
    },
    .{
        .main_file = "009_if.zig",
        .output = "Foo is 42!",
    },
    .{
        .main_file = "010_if2.zig",
        .output = "With the discount, the price is $17.",
    },
    .{
        .main_file = "011_while.zig",
        .output = "2 4 8 16 32 64 128 256 512 n=1024",
        .hint = "You probably want a 'less than' condition.",
    },
    .{
        .main_file = "012_while2.zig",
        .output = "2 4 8 16 32 64 128 256 512 n=1024",
        .hint = "It might help to look back at the previous exercise.",
    },
    .{
        .main_file = "013_while3.zig",
        .output = "1 2 4 7 8 11 13 14 16 17 19",
    },
    .{
        .main_file = "014_while4.zig",
        .output = "n=4",
    },
    .{
        .main_file = "015_for.zig",
        .output = "A Dramatic Story: :-)  :-)  :-(  :-|  :-)  The End.",
    },
    .{
        .main_file = "016_for2.zig",
        .output = "The value of bits '1101': 13.",
    },
    .{
        .main_file = "017_quiz2.zig",
        .output = "1, 2, Fizz, 4, Buzz, Fizz, 7, 8, Fizz, Buzz, 11, Fizz, 13, 14, FizzBuzz, 16,",
        .hint = "This is a famous game!",
    },
    .{
        .main_file = "018_functions.zig",
        .output = "Answer to the Ultimate Question: 42",
        .hint = "Can you help write the function?",
    },
    .{
        .main_file = "019_functions2.zig",
        .output = "Powers of two: 2 4 8 16",
    },
    .{
        .main_file = "020_quiz3.zig",
        .output = "32 64 128 256",
        .hint = "Unexpected pop quiz! Help!",
    },
    .{
        .main_file = "021_errors.zig",
        .output = "2<4. 3<4. 4=4. 5>4. 6>4.",
        .hint = "What's the deal with fours?",
    },
    .{
        .main_file = "022_errors2.zig",
        .output = "I compiled!",
        .hint = "Get the error union type right to allow this to compile.",
    },
    .{
        .main_file = "023_errors3.zig",
        .output = "a=64, b=22",
    },
    .{
        .main_file = "024_errors4.zig",
        .output = "a=20, b=14, c=10",
    },
    .{
        .main_file = "025_errors5.zig",
        .output = "a=0, b=19, c=0",
    },
    .{
        .main_file = "026_hello2.zig",
        .output = "Hello world!",
        .hint = "Try using a try!",
        .check_stdout = true,
    },
    .{
        .main_file = "027_defer.zig",
        .output = "One Two",
    },
    .{
        .main_file = "028_defer2.zig",
        .output =
        \\(Goat) (Cat) (Dog) (Dog) (Goat) (Unknown) done.
        \\Answer to everything? 42
        , // pay attention to the comma
    },
    .{
        .main_file = "029_errdefer.zig",
        .output = "Getting number...got 5. Getting number...failed!",
    },
    .{
        .main_file = "030_switch.zig",
        .output = "ZIG?",
    },
    .{
        .main_file = "031_switch2.zig",
        .output = "ZIG!",
    },
    .{
        .main_file = "032_unreachable.zig",
        .output = "1 2 3 9 8 7",
    },
    .{
        .main_file = "033_iferror.zig",
        .output = "2<4. 3<4. 4=4. 5>4. 6>4.",
        .hint = "Seriously, what's the deal with fours?",
    },
    .{
        .main_file = "034_quiz4.zig",
        .output = "my_num=42",
        .hint = "Can you make this work?",
        .check_stdout = true,
    },
    .{
        .main_file = "035_enums.zig",
        .output = "1 2 3 9 8 7",
        .hint = "This problem seems familiar...",
    },
    .{
        .main_file = "036_enums2.zig",
        .output =
        \\<p>
        \\  <span style="color: #ff0000">Red</span>
        \\  <span style="color: #00ff00">Green</span>
        \\  <span style="color: #0000ff">Blue</span>
        \\</p>
        , // pay attention to the comma
        .hint = "I'm feeling blue about this.",
    },
    .{
        .main_file = "037_structs.zig",
        .output = "Your wizard has 90 health and 25 gold.",
    },
    .{
        .main_file = "038_structs2.zig",
        .output =
        \\Character 1 - G:20 H:100 XP:10
        \\Character 2 - G:10 H:100 XP:20
        , // pay attention to the comma
    },
    .{
        .main_file = "039_pointers.zig",
        .output = "num1: 5, num2: 5",
        .hint = "Pointers aren't so bad.",
    },
    .{
        .main_file = "040_pointers2.zig",
        .output = "a: 12, b: 12",
    },
    .{
        .main_file = "041_pointers3.zig",
        .output = "foo=6, bar=11",
    },
    .{
        .main_file = "042_pointers4.zig",
        .output = "num: 5, more_nums: 1 1 5 1",
    },
    .{
        .main_file = "043_pointers5.zig",
        .output =
        \\Wizard (G:10 H:100 XP:20)
        \\  Mentor: Wizard (G:10000 H:100 XP:2340)
        , // pay attention to the comma
    },
    .{
        .main_file = "044_quiz5.zig",
        .output = "Elephant A. Elephant B. Elephant C.",
        .hint = "Oh no! We forgot Elephant B!",
    },
    .{
        .main_file = "045_optionals.zig",
        .output = "The Ultimate Answer: 42.",
    },
    .{
        .main_file = "046_optionals2.zig",
        .output = "Elephant A. Elephant B. Elephant C.",
        .hint = "Elephants again!",
    },
    .{
        .main_file = "047_methods.zig",
        .output = "5 aliens. 4 aliens. 1 aliens. 0 aliens. Earth is saved!",
        .hint = "Use the heat ray. And the method!",
    },
    .{
        .main_file = "048_methods2.zig",
        .output = "A  B  C",
        .hint = "This just needs one little fix.",
    },
    .{
        .main_file = "049_quiz6.zig",
        .output = "A  B  C  Cv Bv Av",
        .hint = "Now you're writing Zig!",
    },
    .{
        .main_file = "050_no_value.zig",
        .output = "That is not dead which can eternal lie / And with strange aeons even death may die.",
    },
    .{
        .main_file = "051_values.zig",
        .output = "1:false!. 2:true!. 3:true!. XP before:0, after:200.",
    },
    .{
        .main_file = "052_slices.zig",
        .output =
        \\Hand1: A 4 K 8
        \\Hand2: 5 2 Q J
        , // pay attention to the comma
    },
    .{
        .main_file = "053_slices2.zig",
        .output = "'all your base are belong to us.' 'for great justice.'",
    },
    .{
        .main_file = "054_manypointers.zig",
        .output = "Memory is a resource.",
    },
    .{
        .main_file = "055_unions.zig",
        .output = "Insect report! Ant alive is: true. Bee visited 15 flowers.",
    },
    .{
        .main_file = "056_unions2.zig",
        .output = "Insect report! Ant alive is: true. Bee visited 16 flowers.",
    },
    .{
        .main_file = "057_unions3.zig",
        .output = "Insect report! Ant alive is: true. Bee visited 17 flowers.",
    },
    .{
        .main_file = "058_quiz7.zig",
        .output = "Archer's Point--2->Bridge--1->Dogwood Grove--3->Cottage--2->East Pond--1->Fox Pond",
        .hint = "This is the biggest program we've seen yet. But you can do it!",
    },
    .{
        .main_file = "059_integers.zig",
        .output = "Zig is cool.",
    },
    .{
        .main_file = "060_floats.zig",
        .output = "Shuttle liftoff weight: 2.032e3 metric tons",
    },
    .{
        .main_file = "061_coercions.zig",
        .output = "Letter: A",
    },
    .{
        .main_file = "062_loop_expressions.zig",
        .output = "Current language: Zig",
        .hint = "Surely the current language is 'Zig'!",
    },
    .{
        .main_file = "063_labels.zig",
        .output = "Enjoy your Cheesy Chili!",
    },
    .{
        .main_file = "064_builtins.zig",
        .output = "1101 + 0101 = 0010 (true). Without overflow: 00010010. Furthermore, 11110000 backwards is 00001111.",
    },
    .{
        .main_file = "065_builtins2.zig",
        .output = "A Narcissus loves all Narcissuses. He has room in his heart for: me myself.",
    },
    .{
        .main_file = "066_comptime.zig",
        .output = "Immutable: 12345, 987.654; Mutable: 54321, 456.789; Types: comptime_int, comptime_float, u32, f32",
        .hint = "It may help to read this one out loud to your favorite stuffed animal until it sinks in completely.",
    },
    .{
        .main_file = "067_comptime2.zig",
        .output = "A BB CCC DDDD",
    },
    .{
        .main_file = "068_comptime3.zig",
        .output =
        \\Minnow (1:32, 4 x 2)
        \\Shark (1:16, 8 x 5)
        \\Whale (1:1, 143 x 95)
        ,
    },
    .{
        .main_file = "069_comptime4.zig",
        .output = "s1={ 1, 2, 3 }, s2={ 1, 2, 3, 4, 5 }, s3={ 1, 2, 3, 4, 5, 6, 7 }",
    },
    .{
        .main_file = "070_comptime5.zig",
        .output =
        \\"Quack." ducky1: true, "Squeek!" ducky2: true, ducky3: false
        ,
        .hint = "Have you kept the wizard hat on?",
    },
    .{
        .main_file = "071_comptime6.zig",
        .output = "Narcissus has room in his heart for: me myself.",
    },
    .{
        .main_file = "072_comptime7.zig",
        .output = "26",
    },
    .{
        .main_file = "073_comptime8.zig",
        .output = "My llama value is 25.",
    },
    .{
        .main_file = "074_comptime9.zig",
        .output = "MouseLlama joins the crew!",
    },
    .{
        .main_file = "075_quiz8.zig",
        .output = "Archer's Point--2->Bridge--1->Dogwood Grove--3->Cottage--2->East Pond--1->Fox Pond",
        .hint = "Roll up those sleeves. You get to WRITE some code for this one.",
    },
    .{
        .main_file = "076_sentinels.zig",
        .output = "Array:123056. Many-item pointer:123.",
    },
    .{
        .main_file = "077_sentinels2.zig",
        .output = "Weird Data!",
    },
    .{
        .main_file = "078_sentinels3.zig",
        .output = "Weird Data!",
    },
    .{
        .main_file = "079_quoted_identifiers.zig",
        .output = "Sweet freedom: 55, false.",
        .hint = "Help us, Zig Programmer, you're our only hope!",
    },
    .{
        .main_file = "080_anonymous_structs.zig",
        .output = "[Circle(i32): 25,70,15] [Circle(f32): 25.2,71.0,15.7]",
    },
    .{
        .main_file = "081_anonymous_structs2.zig",
        .output = "x:205 y:187 radius:12",
    },
    .{
        .main_file = "082_anonymous_structs3.zig",
        .output =
        \\"0"(bool):true "1"(bool):false "2"(i32):42 "3"(f32):3.141592
        , // pay attention to the comma
        .hint = "This one is a challenge! But you have everything you need.",
    },
    .{
        .main_file = "083_anonymous_lists.zig",
        .output = "I say hello!",
    },
    .{
        .main_file = "084_interfaces.zig",
        .output =
        \\=== Doctor Zoraptera's Insect Report ===
        \\Ant is alive.
        \\Bee visited 17 flowers.
        \\Grasshopper hopped 32 meters.
        , // pay attention to the comma
    },

    // Skipped because of https://github.com/ratfactor/ziglings/issues/163
    // direct link: https://github.com/ziglang/zig/issues/6025
    .{
        .main_file = "085_async.zig",
        .output = "Current time: <timestamp>s since epoch",
        .timestamp = true,
    },
    .{
        .main_file = "086_async2.zig",
        .output = "Computing... The answer is: 42",
    },
    .{
        .main_file = "087_async3.zig",
        .output =
        \\1 + 2 = 3
        \\6 * 7 = 42
        \\Total: 45
        , // pay attention to the comma
    },
    .{
        .main_file = "088_async4.zig",
        .output =
        \\Task 1 done.
        \\Task 2 done.
        \\Task 3 done.
        \\All tasks finished!
        , // pay attention to the comma
    },
    .{
        .main_file = "089_async5.zig",
        .output =
        \\Starting long computation...
        \\Canceling slow task...
        \\Task was canceled, cleaning up.
        \\Task returned: 0
        , // pay attention to the comma
    },
    .{
        .main_file = "090_async6.zig",
        .output = "Hare: I'm fast!",
    },
    .{
        .main_file = "091_async7.zig",
        .output = "Counter: 400",
    },
    .{
        .main_file = "092_async8.zig",
        .output = "Sum of 1..10 = 55",
    },
    .{
        .main_file = "093_async9.zig",
        .output = "Worker 1 found signal start over threshold at index 12!",
    },
    .{
        .main_file = "094_async10.zig",
        .output =
        \\Starting critical section...
        \\Critical section completed safely.
        \\Task result: All data saved.
        , // pay attention to the comma
    },
    .{
        .main_file = "095_quiz_async.zig",
        .output =
        \\=== Doctor Zoraptera's Garden Report ===
        \\Temperature : 23C
        \\Humidity    : 63%
        \\Wind        : 13 km/h
        \\Readings    : 9
        \\Bee-friendly conditions! Expect high pollination.
        , // pay attention to the comma
    },
    .{
        .main_file = "096_hello_c.zig",
        .output = "Hello C from Zig! - C result is 17 chars written.",
        .link_libc = true,
        .skip = true,
        .skip_hint = "Skipped until we have found a solution for the removed '@cImport'",
    },
    .{
        .main_file = "097_c_math.zig",
        .output = "The normalized angle of 765.2 degrees is 45.2 degrees.",
        .link_libc = true,
        .skip = true,
        .skip_hint = "Skipped until we have found a solution for the removed '@cImport'",
    },
    .{
        .main_file = "098_for3.zig",
        .output = "1 2 4 7 8 11 13 14 16 17 19\n1 2 3 4 5 6 7 8 9 10 11 12 13 14 15",
    },
    .{
        .main_file = "099_memory_allocation.zig",
        .output = "Running Average: 0.30 0.25 0.20 0.18 0.22",
    },
    .{
        .main_file = "100_bit_manipulation.zig",
        .output = "x = 1011; y = 1101",
    },
    .{
        .main_file = "101_bit_manipulation2.zig",
        .output = "Is this a pangram? true!",
    },
    .{
        .main_file = "102_formatting.zig",
        .output =
        \\
        \\ X |  1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
        \\---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
        \\ 1 |  1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
        \\
        \\ 2 |  2   4   6   8  10  12  14  16  18  20  22  24  26  28  30
        \\
        \\ 3 |  3   6   9  12  15  18  21  24  27  30  33  36  39  42  45
        \\
        \\ 4 |  4   8  12  16  20  24  28  32  36  40  44  48  52  56  60
        \\
        \\ 5 |  5  10  15  20  25  30  35  40  45  50  55  60  65  70  75
        \\
        \\ 6 |  6  12  18  24  30  36  42  48  54  60  66  72  78  84  90
        \\
        \\ 7 |  7  14  21  28  35  42  49  56  63  70  77  84  91  98 105
        \\
        \\ 8 |  8  16  24  32  40  48  56  64  72  80  88  96 104 112 120
        \\
        \\ 9 |  9  18  27  36  45  54  63  72  81  90  99 108 117 126 135
        \\
        \\10 | 10  20  30  40  50  60  70  80  90 100 110 120 130 140 150
        \\
        \\11 | 11  22  33  44  55  66  77  88  99 110 121 132 143 154 165
        \\
        \\12 | 12  24  36  48  60  72  84  96 108 120 132 144 156 168 180
        \\
        \\13 | 13  26  39  52  65  78  91 104 117 130 143 156 169 182 195
        \\
        \\14 | 14  28  42  56  70  84  98 112 126 140 154 168 182 196 210
        \\
        \\15 | 15  30  45  60  75  90 105 120 135 150 165 180 195 210 225
        ,
    },
    .{
        .main_file = "103_for4.zig",
        .output = "Arrays match!",
    },
    .{
        .main_file = "104_for5.zig",
        .output =
        \\1. Wizard (Gold: 25, XP: 40)
        \\2. Bard (Gold: 11, XP: 17)
        \\3. Bard (Gold: 5, XP: 55)
        \\4. Warrior (Gold: 7392, XP: 21)
        , // pay attention to the comma
    },
    .{
        .main_file = "105_testing.zig",
        .output = "",
        .kind = .@"test",
    },
    .{
        .main_file = "106_tokenization.zig",
        .output =
        \\My
        \\name
        \\is
        \\Ozymandias
        \\King
        \\of
        \\Kings
        \\Look
        \\on
        \\my
        \\Works
        \\ye
        \\Mighty
        \\and
        \\despair
        \\This little poem has 15 words!
        , // pay attention to the comma
    },
    .{
        .main_file = "107_threading.zig",
        .output =
        \\Starting work...
        \\thread 1: started.
        \\thread 2: started.
        \\thread 3: started.
        \\Some weird stuff, after starting the threads.
        \\thread 2: finished.
        \\thread 1: finished.
        \\thread 3: finished.
        \\Zig is cool!
        , // pay attention to the comma
    },
    .{
        .main_file = "108_threading2.zig",
        .output = "PI ≈ 3.14159265",
    },
    .{
        .main_file = "109_files.zig",
        .output = "Successfully wrote 18 bytes.",
    },
    .{
        .main_file = "110_files2.zig",
        .output =
        \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        \\Successfully Read 18 bytes: It's zigling time!
        , // pay attention to the comma
    },
    .{
        .main_file = "111_labeled_switch.zig",
        .output = "The pull request has been merged.",
    },
    .{
        .main_file = "112_vectors.zig",
        .output =
        \\Max difference (old fn): 0.014
        \\Max difference (new fn): 0.014
        , // pay attention to the comma
    },
    .{ .main_file = "113_quiz9.zig", .output =
    \\Toggle pins with XOR on PORTB
    \\-----------------------------
    \\  1100 // (initial state of PORTB)
    \\^ 0101 // (bitmask)
    \\= 1001
    \\
    \\  1100 // (initial state of PORTB)
    \\^ 0011 // (bitmask)
    \\= 1111
    \\
    \\Set pins with OR on PORTB
    \\-------------------------
    \\  1001 // (initial state of PORTB)
    \\| 0100 // (bitmask)
    \\= 1101
    \\
    \\  1001 // (reset state)
    \\| 0100 // (bitmask)
    \\= 1101
    \\
    \\Clear pins with AND and NOT on PORTB
    \\------------------------------------
    \\  1110 // (initial state of PORTB)
    \\& 1011 // (bitmask)
    \\= 1010
    \\
    \\  0111 // (reset state)
    \\& 1110 // (bitmask)
    \\= 0110
    },
    .{
        .main_file = "114_packed.zig",
        .output = "",
    },
    .{
        .main_file = "115_packed2.zig",
        .output = "",
    },
    .{
        .main_file = "999_the_end.zig",
        .output =
        \\
        \\This is the end for now!
        \\We hope you had fun and were able to learn a lot, so visit us again when the next exercises are available.
        , // pay attention to the comma
    },
};
