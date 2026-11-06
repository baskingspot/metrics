const std = @import("std");
const prometheus = @import("prometheus");

const Sample = struct { labels: struct { worker: u16 }, value: u64 };

/// A family that does not exist as a slice: it yields one sample per worker.
const WorkerSamples = struct {
    workers: u16,
    next_worker: u16 = 0,

    pub fn next(self: *WorkerSamples) ?Sample {
        if (self.next_worker >= self.workers) return null;
        const worker = self.next_worker;
        self.next_worker += 1;
        return .{ .labels = .{ .worker = worker }, .value = 7 };
    }
};

test "stream a family from an iterator" {
    var samples = WorkerSamples{ .workers = 2 };

    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.family(&w, .{ .name = "worker_queue", .kind = .gauge }, &samples);

    try std.testing.expectEqualStrings(
        "# TYPE worker_queue gauge\n" ++
            "worker_queue{worker=\"0\"} 7\n" ++
            "worker_queue{worker=\"1\"} 7\n",
        w.buffered(),
    );
}
