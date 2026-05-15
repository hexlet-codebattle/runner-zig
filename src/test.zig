const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;

const RunResponse = struct {
    exit_code: ?i32,
    stdout: []const u8,
    stderr: []const u8,
};

test "run executes zig solution via http" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    logTest("basic zig run over HTTP");

    const port = try pickFreePort(io);
    var proc = try startServer(allocator, io, port, .{});
    defer stopServer(allocator, io, port, &proc);

    try waitForHealth(allocator, io, port);

    const body = try buildZigPayload(allocator);
    defer allocator.free(body);

    const response = try httpRequest(allocator, io, port, "POST", "/run", body);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status);

    var parsed = try std.json.parseFromSlice(RunResponse, allocator, response.body, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.exit_code != null);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.exit_code.?);
    try std.testing.expect(parsed.value.stderr.len == 0);

    const shutdown_response = try httpRequest(allocator, io, port, "POST", "/shutdown", "{}");
    defer allocator.free(shutdown_response.body);
}

test "run rejects payloads larger than limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    logTest("payload size limit enforced");

    const port = try pickFreePort(io);
    var proc = try startServer(allocator, io, port, .{ .input_max = 1024 });
    defer stopServer(allocator, io, port, &proc);

    try waitForHealth(allocator, io, port);

    const big_solution = try allocator.alloc(u8, 1200);
    defer allocator.free(big_solution);
    @memset(big_solution, 'a');

    const payload = .{
        .timeout = "5s",
        .solution_text = big_solution,
        .lang_slug = "python",
    };

    const body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(body);

    const response = try httpRequest(allocator, io, port, "POST", "/run", body);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 413), response.status);
}

test "run rejects output larger than limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    logTest("output size limit enforced");

    const port = try pickFreePort(io);
    var proc = try startServer(allocator, io, port, .{ .output_max = 1 });
    defer stopServer(allocator, io, port, &proc);

    try waitForHealth(allocator, io, port);

    const solution_text =
        \\print("a" * 2000)
    ;

    const payload = .{
        .timeout = "5s",
        .solution_text = solution_text,
        .lang_slug = "python",
    };

    const body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(body);

    const response = try httpRequest(allocator, io, port, "POST", "/run", body);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 413), response.status);
}

test "run rejects unsupported language" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    logTest("unsupported language rejected");

    const port = try pickFreePort(io);
    var proc = try startServer(allocator, io, port, .{});
    defer stopServer(allocator, io, port, &proc);

    try waitForHealth(allocator, io, port);

    const payload = .{
        .timeout = "5s",
        .solution_text = "print(1)",
        .lang_slug = "unknown-lang",
    };

    const body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(body);

    const response = try httpRequest(allocator, io, port, "POST", "/run", body);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 400), response.status);
}

test "run handles concurrent load" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    logTest("concurrent load test");

    const port = try pickFreePort(io);
    const thread_count = resolveEnvUsize(allocator, "RUNNER_TEST_THREADS", 8);
    const requests_per_thread = resolveEnvUsize(allocator, "RUNNER_TEST_REQUESTS", 6);
    var proc = try startServer(allocator, io, port, .{ .run_concurrency = thread_count });
    defer stopServer(allocator, io, port, &proc);

    try waitForHealth(allocator, io, port);

    const body = try buildZigPayload(allocator);
    defer allocator.free(body);

    var failures = std.atomic.Value(usize).init(0);

    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, runLoadWorker, .{
            io,
            port,
            body,
            requests_per_thread,
            &failures,
            i,
        });
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, 0), failures.load(.seq_cst));
}

test "server rss does not grow under sustained load" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    logTest("rss growth check");

    const port = try pickFreePort(io);
    var proc = try startServer(allocator, io, port, .{ .run_concurrency = 8 });
    defer stopServer(allocator, io, port, &proc);

    try waitForHealth(allocator, io, port);

    const body = try buildZigPayload(allocator);
    defer allocator.free(body);

    const pid = proc.child.id orelse return error.NoPid;

    // Warmup: drive enough requests that the allocator high-water mark, the
    // per-connection arenas, and any one-shot startup buffers reach steady
    // state. Without this, the initial growth from cold caches would look
    // like a leak.
    const warmup_count: usize = resolveEnvUsize(allocator, "RUNNER_RSS_WARMUP", 30);
    var i: usize = 0;
    while (i < warmup_count) : (i += 1) {
        const r = try httpRequest(allocator, io, port, "POST", "/run", body);
        allocator.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
    // Give detached cleanup threads a chance to drain before sampling baseline.
    io.sleep(.fromNanoseconds(200 * std.time.ns_per_ms), .awake) catch {};

    const rss_before_kb = try readRssKb(allocator, io, pid);

    // Bulk phase.
    const bulk_count: usize = resolveEnvUsize(allocator, "RUNNER_RSS_BULK", 300);
    i = 0;
    while (i < bulk_count) : (i += 1) {
        const r = try httpRequest(allocator, io, port, "POST", "/run", body);
        allocator.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
    io.sleep(.fromNanoseconds(500 * std.time.ns_per_ms), .awake) catch {};

    const rss_after_kb = try readRssKb(allocator, io, pid);

    // Tolerance: a real leak shows up as RSS growth that scales with request
    // count. A few MB of allocator hold-back is normal; >32 KB per request
    // sustained is suspicious.
    const max_growth_kb_per_req: usize = resolveEnvUsize(allocator, "RUNNER_RSS_MAX_KB_PER_REQ", 32);
    const min_floor_kb: usize = resolveEnvUsize(allocator, "RUNNER_RSS_MIN_FLOOR_KB", 2 * 1024);
    const budget_kb = @max(min_floor_kb, bulk_count * max_growth_kb_per_req);

    if (rss_after_kb > rss_before_kb + budget_kb) {
        std.debug.print(
            "[LEAK] rss before={d} KB after={d} KB delta={d} KB budget={d} KB ({d} requests)\n",
            .{ rss_before_kb, rss_after_kb, rss_after_kb - rss_before_kb, budget_kb, bulk_count },
        );
        return error.MemoryLeaked;
    }
}

/// Returns the runner process's resident set size in KB. Uses `ps`, which
/// works the same on macOS and Linux.
fn readRssKb(allocator: std.mem.Allocator, io: Io, pid: std.posix.pid_t) !usize {
    const pid_str = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_str);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "ps", "-o", "rss=", "-p", pid_str },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.RssNotAvailable;
    return std.fmt.parseUnsigned(usize, trimmed, 10);
}

const HttpResponse = struct {
    status: u16,
    body: []u8,
};

fn httpRequest(allocator: std.mem.Allocator, io: Io, port: u16, method: []const u8, path: []const u8, body: []const u8) !HttpResponse {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer allocator.free(url);

    const method_enum = if (std.mem.eql(u8, method, "POST")) std.http.Method.POST else std.http.Method.GET;
    const uri = try std.Uri.parse(url);

    var req = try client.request(method_enum, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    defer req.deinit();

    if (method_enum == .POST) {
        const body_buf = try allocator.alloc(u8, body.len);
        defer allocator.free(body_buf);
        @memcpy(body_buf, body);
        try req.sendBodyComplete(body_buf);
    } else {
        try req.sendBodiless();
    }
    var redirect_buf: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    var transfer_buf: [8 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const res_body = try reader.allocRemaining(allocator, .limited(2 << 20));
    return .{ .status = @intFromEnum(response.head.status), .body = res_body };
}

fn waitForHealth(allocator: std.mem.Allocator, io: Io, port: u16) !void {
    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        const result = httpRequest(allocator, io, port, "GET", "/health", "") catch {
            io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
            continue;
        };
        defer allocator.free(result.body);
        if (result.status == 200) return;
        io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    }
    return error.ServerNotReady;
}

fn pickFreePort(io: Io) !u16 {
    var address: Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

fn logTest(message: []const u8) void {
    // Intentionally silent: writing to stderr here makes Zig 0.16's build
    // runner print "failed command:" after passing tests. The zig-test runner
    // already announces each test by name.
    _ = message;
}

fn runLoadWorker(
    io: Io,
    port: u16,
    body: []const u8,
    requests_per_thread: usize,
    failures: *std.atomic.Value(usize),
    worker_id: usize,
) void {
    _ = worker_id;
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const allocator = dbg.allocator();

    var i: usize = 0;
    while (i < requests_per_thread) : (i += 1) {
        const response = httpRequest(allocator, io, port, "POST", "/run", body) catch {
            _ = failures.fetchAdd(1, .seq_cst);
            continue;
        };
        defer allocator.free(response.body);
        if (response.status != 200) {
            _ = failures.fetchAdd(1, .seq_cst);
            continue;
        }
    }
}

fn buildZigPayload(allocator: std.mem.Allocator) ![]u8 {
    const solution_text =
        \\pub fn solution(a: i64, b: i64) i64 {
        \\    return a + b;
        \\}
    ;

    const checker_text =
        \\const std = @import("std");
        \\const solution = @import("solution.zig");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const gpa = init.gpa;
        \\    const io = init.io;
        \\
        \\    var file = try std.Io.Dir.cwd().openFile(io, "asserts.json", .{});
        \\    defer file.close(io);
        \\    const data = try file.readToEndAlloc(io, gpa, 1 << 20);
        \\    defer gpa.free(data);
        \\
        \\    const Case = struct { a: i64, b: i64, expected: i64 };
        \\    var parsed = try std.json.parseFromSlice([]Case, gpa, data, .{});
        \\    defer parsed.deinit();
        \\
        \\    for (parsed.value) |item| {
        \\        const got = solution.solution(item.a, item.b);
        \\        if (got != item.expected) {
        \\            std.debug.print("expected {d} got {d}\\n", .{ item.expected, got });
        \\            return error.AssertionFailed;
        \\        }
        \\    }
        \\}
    ;

    const asserts_text = "[{\"a\":1,\"b\":1,\"expected\":2}]";

    const payload = .{
        .timeout = "5s",
        .solution_text = solution_text,
        .lang_slug = "zig",
        .asserts = asserts_text,
        .checker_text = checker_text,
    };

    return std.json.Stringify.valueAlloc(allocator, payload, .{});
}

fn resolveEnvUsize(allocator: std.mem.Allocator, name: []const u8, fallback: usize) usize {
    _ = allocator;
    const value = std.testing.environ.getPosix(name) orelse return fallback;
    return std.fmt.parseUnsigned(usize, value, 10) catch fallback;
}

const ServerProcess = struct {
    child: std.process.Child,
    env: Environ.Map,
};

const ServerOptions = struct {
    input_max: usize = 1024 * 1024,
    output_max: usize = 1024 * 1024,
    run_concurrency: usize = 10,
};

fn startServer(allocator: std.mem.Allocator, io: Io, port: u16, options: ServerOptions) !ServerProcess {
    const bin_path = "zig-out/bin/runner-zig";
    Io.Dir.cwd().access(io, bin_path, .{}) catch return error.RunnerBinaryMissing;

    var env: Environ.Map = .init(allocator);
    errdefer env.deinit();

    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_text);
    try env.put("PORT", port_text);
    try env.put("ALLOW_SHUTDOWN", "true");
    const output_max_text = try std.fmt.allocPrint(allocator, "{d}", .{options.output_max});
    defer allocator.free(output_max_text);
    const input_max_text = try std.fmt.allocPrint(allocator, "{d}", .{options.input_max});
    defer allocator.free(input_max_text);
    const concurrency_text = try std.fmt.allocPrint(allocator, "{d}", .{options.run_concurrency});
    defer allocator.free(concurrency_text);
    try env.put("RUN_INPUT_MAX", input_max_text);
    try env.put("RUN_OUTPUT_MAX", output_max_text);
    try env.put("RUN_CONCURRENCY", concurrency_text);

    // Discard server stdio: inheriting it makes Zig 0.16's build runner think
    // the test step produced stderr (and then print a misleading "failed command:"
    // line even when all tests pass).
    const child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .cwd = .{ .path = "." },
        .environ_map = &env,
    });
    return .{ .child = child, .env = env };
}

fn stopServer(allocator: std.mem.Allocator, io: Io, port: u16, proc: *ServerProcess) void {
    var shutdown_sent = false;
    if (httpRequest(allocator, io, port, "POST", "/shutdown", "{}")) |resp| {
        allocator.free(resp.body);
        shutdown_sent = true;
    } else |_| {}
    if (shutdown_sent) {
        if (httpRequest(allocator, io, port, "GET", "/health", "")) |resp| {
            allocator.free(resp.body);
        } else |_| {}
        if (proc.child.id) |pid| {
            if (!waitForExit(io, pid, 2 * std.time.ns_per_s)) {
                _ = std.posix.kill(pid, .KILL) catch {};
            }
        }
    } else if (proc.child.id) |pid| {
        _ = std.posix.kill(pid, .KILL) catch {};
    }
    _ = proc.child.wait(io) catch {};
    proc.env.deinit();
}

fn waitForExit(io: Io, pid: std.posix.pid_t, timeout_ns: u64) bool {
    const start = Io.Timestamp.now(io, .awake);
    const limit_ns: i128 = @intCast(timeout_ns);
    while (true) {
        const elapsed: i128 = @as(i128, @intCast(Io.Timestamp.now(io, .awake).nanoseconds)) - @as(i128, @intCast(start.nanoseconds));
        if (elapsed >= limit_ns) return false;
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return true,
            error.PermissionDenied => return true,
            else => {},
        };
        io.sleep(.fromNanoseconds(20 * std.time.ns_per_ms), .awake) catch {};
    }
}
