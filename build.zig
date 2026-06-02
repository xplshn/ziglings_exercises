const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const print = std.debug.print;

// When changing this version, be sure to also update README.md in two places:
//     1) Getting Started
//     2) Version Changes
comptime {
    const required_zig = "0.17.0-dev.607";
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        const error_message =
            \\Sorry, it looks like your version of zig is too old. :-(
            \\
            \\Ziglings requires development build
            \\
            \\{s}
            \\
            \\or higher.
            \\
            \\Please download a development ("master") build from
            \\
            \\https://ziglang.org/download/
            \\
            \\
        ;
        @compileError(std.fmt.comptimePrint(error_message, .{required_zig}));
    }
}

// Elrond the Wise owns the entire Ziglings logic now!
// build.zig only builds it and forwards the chosen options as CLI flags.
// Building just this one Run step keeps the build output readable and lets
// Elrond iterate without the configure-phase cache getting in the way.
pub fn build(b: *Build) !void {
    const io = b.graph.io;

    // Remove the standard install and uninstall steps.
    b.top_level_steps = .{};

    const healed = b.option(bool, "healed", "Run exercises from patches/healed") orelse false;
    const override_healed_path = b.option([]const u8, "healed-path", "Override healed path");
    const exno = b.option(usize, "n", "Select exercise");
    const rand = b.option(bool, "random", "Select random exercise");
    const start = b.option(usize, "s", "Start at exercise");
    const reset = b.option(bool, "reset", "Reset exercise progress");
    const logo = b.option(bool, "logo", "Display Ziglings logo");

    const sep = std.fs.path.sep_str;
    const healed_path = if (override_healed_path) |path|
        path
    else
        "patches" ++ sep ++ "healed";
    const work_path = if (healed) healed_path else "exercises";

    const elrond = b.addExecutable(.{
        .name = "elrond",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/elrond.zig"),
            .target = b.graph.host,
        }),
    });

    // -Dreset is a plain file delete; no need to launch Elrond.
    if (reset) |_| {
        std.Io.Dir.cwd().deleteFile(io, ".progress.txt") catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                print("Unable to remove progress file: {}\n", .{err});
                return err;
            },
        };
        print("Progress reset, .progress.txt removed.\n", .{});
        const noop = b.step("ziglings", "Reset progress");
        b.default_step = noop;
        return;
    }

    const run = b.addRunArtifact(elrond);
    run.addArg(b.fmt("--zig={s}", .{b.graph.zig_exe}));
    run.addArg(b.fmt("--work-path={s}", .{work_path}));

    if (exno) |n| {
        run.addArg(b.fmt("--only={d}", .{n}));
    } else if (rand) |_| {
        run.addArg("--random");
    } else if (start) |s| {
        run.addArg(b.fmt("--start={d}", .{s}));
    } else if (logo) |_| {
        run.addArg("--logo");
    }

    const ziglings_step = b.step("ziglings", "Run ziglings");
    ziglings_step.dependOn(&run.step);
    b.default_step = ziglings_step;
}
