const std = @import("std");
const RunResponse = struct {
    exit_code: ?i32,
    stdout: []const u8,
    stderr: []const u8,
};

var test_mutex = std.Thread.Mutex{};

test "run executes zig solution via http" {
    test_mutex.lock();
    defer test_mutex.unlock();
    logTest("basic zig run over HTTP");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreePort();
    var proc = try startServer(allocator, port, .{});
    defer stopServer(allocator, port, &proc);

    try waitForHealth(allocator, port);

    const body = try buildZigPayload(allocator);
    defer allocator.free(body);

    const response = try httpRequest(allocator, port, "POST", "/run", body);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status);

    var parsed = try std.json.parseFromSlice(RunResponse, allocator, response.body, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.exit_code != null);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.exit_code.?);
    try std.testing.expect(parsed.value.stderr.len == 0);

    const shutdown_response = try httpRequest(allocator, port, "POST", "/shutdown", "{}");
    defer allocator.free(shutdown_response.body);
}

test "run rejects payloads larger than limit" {
    test_mutex.lock();
    defer test_mutex.unlock();
    logTest("payload size limit enforced");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreePort();
    var proc = try startServer(allocator, port, .{ .input_max = 1024 });
    defer stopServer(allocator, port, &proc);

    try waitForHealth(allocator, port);

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

    const response = try httpRequest(allocator, port, "POST", "/run", body);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 413), response.status);
}

test "run rejects output larger than limit" {
    test_mutex.lock();
    defer test_mutex.unlock();
    logTest("output size limit enforced");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreePort();
    var proc = try startServer(allocator, port, .{ .output_max = 1 });
    defer stopServer(allocator, port, &proc);

    try waitForHealth(allocator, port);

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

    const response = try httpRequest(allocator, port, "POST", "/run", body);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 413), response.status);
}

test "run rejects unsupported language" {
    test_mutex.lock();
    defer test_mutex.unlock();
    logTest("unsupported language rejected");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreePort();
    var proc = try startServer(allocator, port, .{});
    defer stopServer(allocator, port, &proc);

    try waitForHealth(allocator, port);

    const payload = .{
        .timeout = "5s",
        .solution_text = "print(1)",
        .lang_slug = "unknown-lang",
    };

    const body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(body);

    const response = try httpRequest(allocator, port, "POST", "/run", body);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 400), response.status);
}

test "run handles concurrent load" {
    test_mutex.lock();
    defer test_mutex.unlock();
    logTest("concurrent load test");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreePort();
    const thread_count = resolveEnvUsize(allocator, "RUNNER_TEST_THREADS", 8);
    const requests_per_thread = resolveEnvUsize(allocator, "RUNNER_TEST_REQUESTS", 6);
    std.debug.print("[TEST] load params: threads={d} requests_per_thread={d}\n", .{ thread_count, requests_per_thread });
    var proc = try startServer(allocator, port, .{ .run_concurrency = thread_count });
    defer stopServer(allocator, port, &proc);

    try waitForHealth(allocator, port);

    const body = try buildZigPayload(allocator);
    defer allocator.free(body);

    var failures = std.atomic.Value(usize).init(0);

    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, runLoadWorker, .{
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

const HttpResponse = struct {
    status: u16,
    body: []u8,
};

fn httpRequest(allocator: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, body: []const u8) !HttpResponse {
    var client = std.http.Client{ .allocator = allocator };
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
        std.mem.copyForwards(u8, body_buf, body);
        try req.sendBodyComplete(body_buf);
    } else {
        try req.sendBodiless();
    }
    var response = try req.receiveHead(&.{});
    var transfer_buf: [8 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const res_body = try reader.allocRemaining(allocator, .limited(2 << 20));
    return .{ .status = @intFromEnum(response.head.status), .body = res_body };
}

fn waitForHealth(allocator: std.mem.Allocator, port: u16) !void {
    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        const result = httpRequest(allocator, port, "GET", "/health", "") catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(result.body);
        if (result.status == 200) return;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return error.ServerNotReady;
}

fn pickFreePort() !u16 {
    const address = std.net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 0);
    var server_stream = try std.net.Address.listen(address, .{ .reuse_address = true });
    defer server_stream.deinit();
    return server_stream.listen_address.getPort();
}

fn logTest(message: []const u8) void {
    std.debug.print("\n[TEST] {s}\n", .{message});
}

fn runLoadWorker(
    port: u16,
    body: []const u8,
    requests_per_thread: usize,
    failures: *std.atomic.Value(usize),
    worker_id: usize,
) void {
    _ = worker_id;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var i: usize = 0;
    while (i < requests_per_thread) : (i += 1) {
        const response = httpRequest(allocator, port, "POST", "/run", body) catch {
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
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    var file = try std.fs.cwd().openFile("asserts.json", .{});
        \\    defer file.close();
        \\    const data = try file.readToEndAlloc(allocator, 1 << 20);
        \\    defer allocator.free(data);
        \\
        \\    const Case = struct { a: i64, b: i64, expected: i64 };
        \\    var parsed = try std.json.parseFromSlice([]Case, allocator, data, .{});
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
    if (std.process.getEnvVarOwned(allocator, name)) |value| {
        defer allocator.free(value);
        return std.fmt.parseUnsigned(usize, value, 10) catch fallback;
    } else |_| {
        return fallback;
    }
}

const ServerProcess = struct {
    child: std.process.Child,
    env: std.process.EnvMap,
};

const ServerOptions = struct {
    input_max: usize = 1024 * 1024,
    output_max: usize = 1024 * 1024,
    run_concurrency: usize = 10,
};

fn startServer(allocator: std.mem.Allocator, port: u16, options: ServerOptions) !ServerProcess {
    const bin_path = "zig-out/bin/runner-zig";
    std.fs.cwd().access(bin_path, .{}) catch return error.RunnerBinaryMissing;

    var env = std.process.EnvMap.init(allocator);
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

    var child = std.process.Child.init(&[_][]const u8{bin_path}, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.cwd = ".";
    child.env_map = &env;
    try child.spawn();
    return .{ .child = child, .env = env };
}

fn stopServer(allocator: std.mem.Allocator, port: u16, proc: *ServerProcess) void {
    var shutdown_sent = false;
    if (httpRequest(allocator, port, "POST", "/shutdown", "{}")) |resp| {
        allocator.free(resp.body);
        shutdown_sent = true;
    } else |_| {}
    if (shutdown_sent) {
        if (httpRequest(allocator, port, "GET", "/health", "")) |resp| {
            allocator.free(resp.body);
        } else |_| {}
        if (!waitForExit(proc.child.id, 2 * std.time.ns_per_s)) {
            _ = std.posix.kill(proc.child.id, std.posix.SIG.KILL) catch {};
        }
    } else {
        _ = std.posix.kill(proc.child.id, std.posix.SIG.KILL) catch {};
    }
    _ = proc.child.wait() catch {};
    if (proc.child.stdout) |file| file.close();
    if (proc.child.stderr) |file| file.close();
    proc.env.deinit();
}

fn waitForExit(pid: std.posix.pid_t, timeout_ns: u64) bool {
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
    while (std.time.nanoTimestamp() < deadline) {
        const alive = std.posix.kill(pid, 0);
        if (alive) |_| {
            // still running
        } else |err| switch (err) {
            error.ProcessNotFound => return true,
            error.PermissionDenied => return true,
            else => {},
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return false;
}
