const std = @import("std");
const prometheus = @import("prometheus");

const WorkerSample = struct { labels: struct { worker: u16 }, value: u64 };

test "gather a family into caller-owned words" {
    // 16 bytes per sample, so each one takes two words.
    comptime std.debug.assert(@sizeOf(WorkerSample) == 16);
    const worker_count = 3;
    var words: [worker_count * 2]u64 = undefined;

    const samples = prometheus.scratch(WorkerSample, &words, worker_count);
    for (samples, 0..) |*sample, i| {
        sample.* = .{ .labels = .{ .worker = @intCast(i) }, .value = 7 };
    }

    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.family(&w, .{ .name = "worker_queue", .kind = .gauge }, samples);

    try std.testing.expectEqualStrings(
        "# TYPE worker_queue gauge\n" ++
            "worker_queue{worker=\"0\"} 7\n" ++
            "worker_queue{worker=\"1\"} 7\n" ++
            "worker_queue{worker=\"2\"} 7\n",
        w.buffered(),
    );
}
