const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Config = @import("../config/Config.zig");
const Event = @import("../Context.zig").Event;

const Timer = std.Io.Clock.Timestamp;

mutex: std.Io.Mutex = .init,
condition: std.Io.Condition = .init,
thread: ?std.Thread,
should_quit: bool,
loop: ?*vaxis.Loop(Event),
reload_indicator_duration_ns: u64,
reload_timer: ?Timer,
generation: usize,
pending: bool,
config: *Config,

pub fn init(config: *Config) Self {
    return .{
        .mutex = .init,
        .condition = .init,
        .thread = null,
        .should_quit = false,
        .loop = null,
        .reload_indicator_duration_ns = 0,
        .reload_timer = null,
        .generation = 0,
        .pending = false,
        .config = config,
    };
}

pub fn deinit(self: *Self, io: std.Io) void {
    self.mutex.lock(io) catch {};
    self.should_quit = true;
    self.condition.signal(io);
    self.mutex.unlock(io);

    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

pub fn start(self: *Self, loop: ?*vaxis.Loop(Event), io: std.Io) !void {
    try self.mutex.lock(io);
    self.reload_indicator_duration_ns = @as(u64, @intFromFloat(@as(f32, self.config.file_monitor.reload_indicator_duration) * std.time.ns_per_s));
    self.loop = loop;
    self.reload_timer = Timer.now(io, .awake);
    self.pending = false;
    self.mutex.unlock(io);

    if (self.thread == null) {
        self.thread = try std.Thread.spawn(.{}, run, .{ self, io });
    }
}

fn run(self: *Self, io: std.Io) void {
    const check_interval_ns = self.reload_indicator_duration_ns / 4;
    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration{ .nanoseconds = check_interval_ns } } };

    while (true) {
        self.mutex.lock(io) catch {};

        if (self.should_quit) {
            self.mutex.unlock(io);
            break;
        }

        _ = self.condition.waitTimeout(io, &self.mutex, timeout) catch {};

        const current_loop = self.loop;
        const generation = self.generation;
        const pending = self.pending;

        var elapsed_ns: i96 = 0;
        if (self.reload_timer) |timer_start| {
            const duration = timer_start.untilNow(io);
            elapsed_ns = duration.raw.toNanoseconds();
        }

        self.mutex.unlock(io);

        if (pending and (elapsed_ns >= self.reload_indicator_duration_ns)) {
            if (current_loop) |loop| loop.postEvent(.{ .reload_done = generation }) catch {};

            self.mutex.lock(io) catch {};
            if (self.generation == generation) {
                self.pending = false;
                if (self.reload_timer != null) {
                    self.reload_timer = Timer.now(io, .awake);
                }
            }
            self.mutex.unlock(io);
        }
    }
}

pub fn notifyChange(self: *Self, io: std.Io) void {
    self.mutex.lock(io) catch {};
    self.generation += 1;
    if (self.reload_timer != null) {
        self.reload_timer = Timer.now(io, .awake);
    }
    self.pending = true;
    self.condition.signal(io);
    self.mutex.unlock(io);
}
