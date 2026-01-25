const std = @import("std");
const server = @import("main.zig");

const RunResponse = struct {
    exit_code: ?i32,
    stdout: []const u8,
    stderr: []const u8,
};

test "run executes zig solution via http" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try pickFreePort();
    var state = server.ServerState.init(true, 10, 1024 * 1024, false);

    var thread = try std.Thread.spawn(.{}, server.serve, .{ allocator, port, &state });
    defer thread.join();

    try waitForHealth(allocator, port);

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

    const body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
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
