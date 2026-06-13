const std = @import("std");
const upstream = @import("zcheck_upstream");

pub const MAX_STRING_LEN = upstream.MAX_STRING_LEN;
pub const String = upstream.String;
pub const Id = upstream.Id;
pub const FilePath = upstream.FilePath;
pub const Config = upstream.Config;
pub const GenerateConfig = upstream.GenerateConfig;
pub const Failure = upstream.Failure;
pub const BoundedSlice = upstream.BoundedSlice;
pub const generateWithConfig = upstream.generateWithConfig;
pub const intRange = upstream.intRange;
pub const bytes = upstream.bytes;

pub fn check(comptime property: anytype, config: Config) !void {
    const failure = checkResult(property, config);
    if (failure) |details| {
        if (config.expect_failure) return;
        if (config.print_failures) printFailure(details);
        return error.PropertyFailed;
    }
    if (config.expect_failure) return error.ExpectedFailure;
}

pub fn checkResult(comptime property: anytype, config: Config) ?Failure(argsType(property)) {
    const Args = argsType(property);
    var seed: u64 = config.seed;
    var prng: std.Random.DefaultPrng = undefined;
    var random: std.Random = undefined;

    if (config.random) |external| {
        random = external;
    } else {
        if (seed == 0) seed = fallbackSeed();
        prng = std.Random.DefaultPrng.init(seed);
        random = prng.random();
    }

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const args = upstream.generateWithConfig(Args, random, .{ .use_default_values = config.use_default_values });
        if (!property(args)) {
            return .{
                .seed = seed,
                .iteration = i,
                .original = args,
                .shrunk = args,
            };
        }
    }
    return null;
}

fn argsType(comptime property: anytype) type {
    return @typeInfo(@TypeOf(property)).@"fn".params[0].type.?;
}

fn fallbackSeed() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 1;
    const sec: u64 = @bitCast(@as(i64, @intCast(ts.sec)));
    const nsec: u64 = @intCast(ts.nsec);
    return (sec << 32) ^ nsec;
}

fn printFailure(failure: anytype) void {
    std.debug.print("\n=== Property failed ===\n", .{});
    std.debug.print("Seed: {}\n", .{failure.seed});
    std.debug.print("Iteration: {}\n", .{failure.iteration});
    std.debug.print("Original: {any}\n", .{failure.original});
    std.debug.print("Shrunk:   {any}\n", .{failure.shrunk});
}
