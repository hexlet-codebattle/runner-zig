const std = @import("std");
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Allocator = std.mem.Allocator;

const RunRequest = struct {
    timeout: ?[]const u8 = null,
    solution_text: []const u8,
    lang_slug: []const u8,
    asserts: ?[]const u8 = null,
    checker_text: ?[]const u8 = null,
};

const RunResponse = struct {
    exit_code: ?i32,
    stdout: []const u8,
    stderr: []const u8,
};

const LangConfig = struct {
    dir: []const u8,
    solution: []const u8,
    checker: ?[]const u8,
    checker_required: bool,
};

const ReadPipeCtx = struct {
    file: std.fs.File,
    list: *std.ArrayList(u8),
    allocator: Allocator,
    max_bytes: usize,
    truncated: *bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try resolvePort(allocator);
    const allow_shutdown = resolveAllowShutdown(allocator);
    const run_concurrency = resolveRunConcurrency(allocator);
    const input_max = resolveInputMax(allocator);
    const output_max = resolveOutputMax(allocator);
    const debug_enabled = resolveDebugEnabled(allocator);
    const runner_cmd = try resolveRunnerCmd(allocator);
    defer runner_cmd.deinit(allocator);
    var state = ServerState.init(allow_shutdown, run_concurrency, input_max, output_max, debug_enabled, runner_cmd);

    try serve(allocator, port, &state);
}

pub const ServerState = struct {
    allow_shutdown: bool,
    shutdown: std.atomic.Value(bool),
    semaphore: std.Thread.Semaphore,
    input_max: usize,
    output_max: usize,
    debug_enabled: bool,
    runner_cmd: RunnerCmd,

    pub fn init(
        allow_shutdown: bool,
        run_concurrency: usize,
        input_max: usize,
        output_max: usize,
        debug_enabled: bool,
        runner_cmd: RunnerCmd,
    ) ServerState {
        return .{
            .allow_shutdown = allow_shutdown,
            .shutdown = std.atomic.Value(bool).init(false),
            .semaphore = .{ .permits = run_concurrency },
            .input_max = input_max,
            .output_max = output_max,
            .debug_enabled = debug_enabled,
            .runner_cmd = runner_cmd,
        };
    }
};

pub fn serve(_: Allocator, port: u16, state: *ServerState) !void {
    const address = try std.net.Address.parseIp("0.0.0.0", port);
    var listener = try std.net.Address.listen(address, .{ .reuse_address = true });
    defer listener.deinit();
    std.log.info("listening on 0.0.0.0:{d}", .{port});

    while (true) {
        var conn = try listener.accept();
        const thread = std.Thread.spawn(.{}, handleConnection, .{
            ConnectionArgs{ .conn = conn, .state = state },
        }) catch |err| {
            std.log.err("spawn connection handler failed: {s}", .{@errorName(err)});
            conn.stream.close();
            continue;
        };
        thread.detach();

        if (state.shutdown.load(.seq_cst)) break;
    }
}

const ConnectionArgs = struct {
    conn: std.net.Server.Connection,
    state: *ServerState,
};

fn handleConnection(args: ConnectionArgs) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    defer args.conn.stream.close();

    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var conn_reader = args.conn.stream.reader(&read_buf);
    var conn_writer = args.conn.stream.writer(&write_buf);
    var server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

    while (true) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => {
                std.log.err("accept failed: {s}", .{@errorName(err)});
                break;
            },
        };

        handleRequest(allocator, &req, args.state) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
            sendJson(&req, .internal_server_error, "{\"error\":\"internal\"}") catch {};
        };

        if (args.state.shutdown.load(.seq_cst)) break;
    }
}

fn resolvePort(allocator: Allocator) !u16 {
    if (std.process.getEnvVarOwned(allocator, "PORT")) |port_text| {
        defer allocator.free(port_text);
        return std.fmt.parseUnsigned(u16, port_text, 10) catch 4040;
    } else |_| {
        return 4040;
    }
}

fn resolveAllowShutdown(allocator: Allocator) bool {
    if (std.process.getEnvVarOwned(allocator, "ALLOW_SHUTDOWN")) |value| {
        defer allocator.free(value);
        return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
    } else |_| {
        return false;
    }
}

fn resolveRunConcurrency(allocator: Allocator) usize {
    if (std.process.getEnvVarOwned(allocator, "RUN_CONCURRENCY")) |value| {
        defer allocator.free(value);
        return std.fmt.parseUnsigned(usize, value, 16) catch 16;
    } else |_| {
        return 16;
    }
}

fn resolveOutputMax(allocator: Allocator) usize {
    if (std.process.getEnvVarOwned(allocator, "RUN_OUTPUT_MAX")) |value| {
        defer allocator.free(value);
        return std.fmt.parseUnsigned(usize, value, 10) catch 1024 * 1024;
    } else |_| {
        return 1024 * 1024;
    }
}

fn resolveInputMax(allocator: Allocator) usize {
    if (std.process.getEnvVarOwned(allocator, "RUN_INPUT_MAX")) |value| {
        defer allocator.free(value);
        return std.fmt.parseUnsigned(usize, value, 10) catch 1024 * 1024;
    } else |_| {
        return 1024 * 1024;
    }
}

fn resolveDebugEnabled(allocator: Allocator) bool {
    if (std.process.getEnvVarOwned(allocator, "DEBUG")) |value| {
        defer allocator.free(value);
        if (value.len == 0) return true;
        return !(std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false"));
    } else |_| {
        return false;
    }
}

const RunnerCmd = struct {
    raw: []const u8,
    argv: []const []const u8,

    fn deinit(self: RunnerCmd, allocator: Allocator) void {
        allocator.free(self.raw);
        allocator.free(self.argv);
    }
};

fn resolveRunnerCmd(allocator: Allocator) !RunnerCmd {
    var child = std.process.Child.init(&[_][]const u8{ "make", "-n", "test" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    try readAllIntoList(allocator, child.stdout.?, &stdout);
    try readAllIntoList(allocator, child.stderr.?, &stderr);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (stderr.items.len > 0) {
                    std.log.err("make -n test failed: {s}", .{stderr.items});
                }
                return error.MakeDryRunFailed;
            }
        },
        else => {
            if (stderr.items.len > 0) {
                std.log.err("make -n test failed: {s}", .{stderr.items});
            }
            return error.MakeDryRunFailed;
        },
    }

    const trimmed = std.mem.trim(u8, stdout.items, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidRunnerCmd;

    const raw = try allocator.dupe(u8, trimmed);
    const argv = try allocator.alloc([]const u8, 3);
    argv[0] = "sh";
    argv[1] = "-c";
    argv[2] = raw;
    return .{ .raw = raw, .argv = argv };
}

fn readAllIntoList(allocator: Allocator, file: std.fs.File, list: *std.ArrayList(u8)) !void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
}

fn handleRequest(allocator: Allocator, req: *std.http.Server.Request, state: *ServerState) !void {
    if (req.head.method == .GET and std.mem.eql(u8, req.head.target, "/health")) {
        try req.respond("ok\n", .{ .status = .ok });
        return;
    }

    if (req.head.method == .POST and std.mem.eql(u8, req.head.target, "/shutdown") and state.allow_shutdown) {
        state.shutdown.store(true, .seq_cst);
        try req.respond("shutdown\n", .{ .status = .ok });
        return;
    }

    if (req.head.method == .POST and std.mem.eql(u8, req.head.target, "/run")) {
        try handleRun(allocator, req, state);
        return;
    }

    try req.respond("not found\n", .{ .status = .not_found });
}

fn handleRun(allocator: Allocator, req: *std.http.Server.Request, state: *ServerState) !void {
    if (state.debug_enabled) {
        std.log.info("request headers: method={s} target={s} content_type={s} transfer_encoding={s} content_encoding={s} content_length={any}", .{
            @tagName(req.head.method),
            req.head.target,
            req.head.content_type orelse "none",
            @tagName(req.head.transfer_encoding),
            @tagName(req.head.transfer_compression),
            req.head.content_length,
        });
    }
    var body_buf: [16 * 1024]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&body_buf);
    if (req.head.transfer_compression != .identity) {
        std.log.warn("run rejected: unsupported content-encoding={s}", .{
            @tagName(req.head.transfer_compression),
        });
        try sendJson(req, .unsupported_media_type, "{\"error\":\"content-encoding not supported\"}");
        return;
    }
    const body = readBodyLimited(allocator, body_reader, state.input_max) catch |err| switch (err) {
        error.StreamTooLong => {
            try sendJson(req, .payload_too_large, "{\"error\":\"payload too large\"}");
            return;
        },
        else => return err,
    };
    defer allocator.free(body);

    var parsed = std.json.parseFromSlice(RunRequest, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        const preview_len = @min(body.len, 512);
        std.log.err("run request parse failed: {s}; body[0..{d}]={s}", .{
            @errorName(err),
            preview_len,
            body[0..preview_len],
        });
        return err;
    };
    defer parsed.deinit();

    const data = parsed.value;
    const lang_slug = data.lang_slug;
    const timeout_text = data.timeout orelse "default";
    const body_len = body.len;
    const lang = getLangConfig(data.lang_slug) orelse {
        try sendJson(req, .bad_request, "{\"error\":\"unsupported lang_slug\"}");
        return;
    };

    if (lang.checker_required and data.checker_text == null) {
        try sendJson(req, .bad_request, "{\"error\":\"checker_text is required\"}");
        return;
    }

    const timeout_ns = try parseTimeoutNs(data.timeout);

    state.semaphore.timedWait(0) catch |err| switch (err) {
        error.Timeout => {
            std.log.warn("run rejected: runner busy", .{});
            try sendJson(req, .too_many_requests, "{\"error\":\"runner busy\"}");
            return;
        },
    };
    defer state.semaphore.post();

    const start_ns = std.time.nanoTimestamp();
    const result = runInTemp(allocator, lang, data, timeout_ns, state.output_max, state.runner_cmd.argv) catch |err| {
        switch (err) {
            error.OutputTooLarge => {
                try sendJson(req, .payload_too_large, "{\"error\":\"output too large\"}");
                return;
            },
            else => {
                std.log.err("run failed: {s}", .{@errorName(err)});
                return err;
            },
        }
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const response = RunResponse{
        .exit_code = result.exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(response, .{}, &out.writer);
    const json_body = try out.toOwnedSlice();
    defer allocator.free(json_body);

    const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_ns));
    std.log.info("run complete: lang={s} timeout={s} body_bytes={d} run_ms={d} response_bytes={d}", .{
        lang_slug,
        timeout_text,
        body_len,
        @divTrunc(elapsed_ns, std.time.ns_per_ms),
        json_body.len,
    });

    try sendJson(req, .ok, json_body);
}

fn readBodyLimited(
    allocator: Allocator,
    reader: *std.Io.Reader,
    max_bytes: usize,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var buf: [16 * 1024]u8 = undefined;
    var too_large = false;
    while (true) {
        var bufs = [_][]u8{buf[0..]};
        const n = reader.readVec(&bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        if (too_large) {
            continue;
        }
        if (max_bytes > 0 and list.items.len + n > max_bytes) {
            too_large = true;
            continue;
        }
        try list.appendSlice(allocator, buf[0..n]);
    }

    if (too_large) return error.StreamTooLong;
    return try list.toOwnedSlice(allocator);
}

fn parseTimeoutNs(timeout: ?[]const u8) !u64 {
    if (timeout == null) {
        return 30 * std.time.ns_per_s;
    }

    const text = timeout.?;
    if (text.len < 2) return error.InvalidTimeout;

    var unit_ns: u64 = 0;
    var number_text: []const u8 = text;

    if (std.mem.endsWith(u8, text, "ms")) {
        unit_ns = std.time.ns_per_ms;
        number_text = text[0 .. text.len - 2];
    } else if (std.mem.endsWith(u8, text, "s")) {
        unit_ns = std.time.ns_per_s;
        number_text = text[0 .. text.len - 1];
    } else if (std.mem.endsWith(u8, text, "m")) {
        unit_ns = 60 * std.time.ns_per_s;
        number_text = text[0 .. text.len - 1];
    } else {
        return error.InvalidTimeout;
    }

    const value = try std.fmt.parseUnsigned(u64, number_text, 10);
    return value * unit_ns;
}

fn getLangConfig(slug: []const u8) ?LangConfig {
    if (std.mem.eql(u8, slug, "clojure")) {
        return .{ .dir = "check", .solution = "solution.clj", .checker = null, .checker_required = false };
    }
    if (std.mem.eql(u8, slug, "cpp")) {
        return .{ .dir = "check", .solution = "solution.cpp", .checker = "checker.cpp", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "csharp")) {
        return .{ .dir = "check", .solution = "Solution.cs", .checker = "Checker.cs", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "dart")) {
        return .{ .dir = "lib", .solution = "solution.dart", .checker = "checker.dart", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "elixir")) {
        return .{ .dir = "check", .solution = "solution.exs", .checker = null, .checker_required = false };
    }
    if (std.mem.eql(u8, slug, "golang")) {
        return .{ .dir = "check", .solution = "solution.go", .checker = "checker.go", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "haskell")) {
        return .{ .dir = "check", .solution = "Solution.hs", .checker = "Checker.hs", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "java")) {
        return .{ .dir = "check", .solution = "Solution.java", .checker = "Checker.java", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "js")) {
        return .{ .dir = "check", .solution = "solution.js", .checker = null, .checker_required = false };
    }
    if (std.mem.eql(u8, slug, "kotlin")) {
        return .{ .dir = "check", .solution = "solution.kt", .checker = "checker.kt", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "php")) {
        return .{ .dir = "check", .solution = "solution.php", .checker = null, .checker_required = false };
    }
    if (std.mem.eql(u8, slug, "python")) {
        return .{ .dir = "check", .solution = "solution.py", .checker = null, .checker_required = false };
    }
    if (std.mem.eql(u8, slug, "ruby")) {
        return .{ .dir = "check", .solution = "solution.rb", .checker = null, .checker_required = false };
    }
    if (std.mem.eql(u8, slug, "rust")) {
        return .{ .dir = "check", .solution = "solution.rs", .checker = "checker.rs", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "swift")) {
        return .{ .dir = "check", .solution = "solution.swift", .checker = "checker.swift", .checker_required = true };
    }
    if (std.mem.eql(u8, slug, "ts")) {
        return .{ .dir = "check", .solution = "solution.js", .checker = null, .checker_required = false };
    }
    if (std.mem.eql(u8, slug, "zig")) {
        return .{ .dir = "check", .solution = "solution.zig", .checker = "checker.zig", .checker_required = true };
    }
    return null;
}

fn runInTemp(
    allocator: Allocator,
    lang: LangConfig,
    data: RunRequest,
    timeout_ns: u64,
    output_max: usize,
    runner_argv: []const []const u8,
) !RunResult {
    var temp = try makeTempDir(allocator);
    defer temp.deinit();

    try copyWorkspace(temp.dir);

    try writeInputs(temp.dir, lang, data);

    return try runCommand(allocator, temp.path, timeout_ns, output_max, runner_argv);
}

const RunResult = struct {
    exit_code: ?i32,
    stdout: []u8,
    stderr: []u8,
};

const TempDir = struct {
    dir: std.fs.Dir,
    path: []u8,

    fn deinit(self: *TempDir) void {
        self.dir.close();
        std.fs.deleteTreeAbsolute(self.path) catch {};
    }
};

fn makeTempDir(allocator: Allocator) !TempDir {
    var tmp_parent = try std.fs.openDirAbsolute("/tmp", .{});
    defer tmp_parent.close();

    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var random_bytes: [12]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var suffix: [std.fs.base64_encoder.calcSize(random_bytes.len)]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&suffix, &random_bytes);

        var name_buf: [7 + suffix.len]u8 = undefined;
        std.mem.copyForwards(u8, name_buf[0..7], "runner-");
        std.mem.copyForwards(u8, name_buf[7..], &suffix);
        const name = name_buf[0..];

        std.posix.mkdirat(tmp_parent.fd, name, 0o777) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        _ = std.posix.fchmodat(tmp_parent.fd, name, 0o777, 0) catch {};

        const dir = try tmp_parent.openDir(name, .{ .iterate = true });
        const path = try tmp_parent.realpathAlloc(allocator, name);
        return TempDir{ .dir = dir, .path = path };
    }

    return error.TempDirUnavailable;
}

fn copyWorkspace(dst_dir: std.fs.Dir) !void {
    const ignore = [_][]const u8{ ".git", "zig-cache", "zig-out" };
    var src_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer src_dir.close();
    try copyDirRecursive(src_dir, dst_dir, &ignore);
}

fn copyDirRecursive(src: std.fs.Dir, dst: std.fs.Dir, ignore: []const []const u8) !void {
    var it = src.iterate();
    while (try it.next()) |entry| {
        if (isIgnored(entry.name, ignore)) continue;

        switch (entry.kind) {
            .directory => {
                std.posix.mkdirat(dst.fd, entry.name, 0o777) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                _ = std.posix.fchmodat(dst.fd, entry.name, 0o777, 0) catch {};
                var src_child = try src.openDir(entry.name, .{ .iterate = true });
                defer src_child.close();
                var dst_child = try dst.openDir(entry.name, .{ .iterate = true });
                defer dst_child.close();
                try copyDirRecursive(src_child, dst_child, ignore);
            },
            .file => {
                try src.copyFile(entry.name, dst, entry.name, .{});
            },
            else => {},
        }
    }
}

fn isIgnored(name: []const u8, ignore: []const []const u8) bool {
    for (ignore) |item| {
        if (std.mem.eql(u8, name, item)) return true;
    }
    return false;
}

fn writeInputs(root: std.fs.Dir, lang: LangConfig, data: RunRequest) !void {
    try root.makePath(lang.dir);
    var lang_dir = try root.openDir(lang.dir, .{});
    defer lang_dir.close();

    try writeFile(lang_dir, lang.solution, data.solution_text);

    if (data.checker_text) |checker| {
        if (lang.checker) |checker_name| {
            try writeFile(lang_dir, checker_name, checker);
        }
    }

    if (data.asserts) |asserts| {
        try writeFile(lang_dir, "asserts.json", asserts);
    }
}

fn writeFile(dir: std.fs.Dir, name: []const u8, contents: []const u8) !void {
    var file = try dir.createFile(name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

const WaitState = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    status: u32 = 0,
};

fn waiterThread(pid: std.posix.pid_t, state: *WaitState) void {
    const wait_result = std.posix.waitpid(pid, 0);
    state.mutex.lock();
    state.status = wait_result.status;
    state.done = true;
    state.cond.signal();
    state.mutex.unlock();
}

fn runCommand(
    allocator: Allocator,
    cwd_path: []const u8,
    timeout_ns: u64,
    output_max: usize,
    argv: []const []const u8,
) !RunResult {
    if (builtin.os.tag == .linux) {
        return runCommandSandboxed(allocator, cwd_path, timeout_ns, output_max, argv);
    }
    return runCommandSimple(allocator, cwd_path, timeout_ns, output_max, argv);
}

fn runCommandSimple(
    allocator: Allocator,
    cwd_path: []const u8,
    timeout_ns: u64,
    output_max: usize,
    argv: []const []const u8,
) !RunResult {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd_path;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const pid = child.id;
    _ = std.posix.setpgid(pid, pid) catch {};

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    defer stderr.deinit(allocator);

    var out_truncated = false;
    var err_truncated = false;
    var out_ctx = ReadPipeCtx{
        .file = child.stdout.?,
        .list = &stdout,
        .allocator = allocator,
        .max_bytes = output_max,
        .truncated = &out_truncated,
    };
    var err_ctx = ReadPipeCtx{
        .file = child.stderr.?,
        .list = &stderr,
        .allocator = allocator,
        .max_bytes = output_max,
        .truncated = &err_truncated,
    };

    var out_thread = try std.Thread.spawn(.{}, readPipe, .{&out_ctx});
    var err_thread = try std.Thread.spawn(.{}, readPipe, .{&err_ctx});

    var wait_state = WaitState{};
    var waiter = try std.Thread.spawn(.{}, waiterThread, .{ pid, &wait_state });

    var exit_code: ?i32 = null;
    var timed_out = false;

    wait_state.mutex.lock();
    if (!wait_state.done) {
        wait_state.cond.timedWait(&wait_state.mutex, timeout_ns) catch |err| switch (err) {
            error.Timeout => timed_out = true,
        };
    }
    if (!timed_out and wait_state.done) {
        exit_code = decodeExitCode(wait_state.status);
    }
    wait_state.mutex.unlock();

    if (timed_out) {
        std.log.warn("run timed out; killing process group", .{});
        _ = std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        wait_state.mutex.lock();
        while (!wait_state.done) {
            wait_state.cond.wait(&wait_state.mutex);
        }
        wait_state.mutex.unlock();
        exit_code = null;
    }

    out_thread.join();
    err_thread.join();
    waiter.join();

    if (out_truncated or err_truncated) {
        return error.OutputTooLarge;
    }

    return RunResult{
        .exit_code = exit_code,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

fn runCommandSandboxed(
    allocator: Allocator,
    cwd_path: []const u8,
    timeout_ns: u64,
    output_max: usize,
    argv: []const []const u8,
) !RunResult {
    const linux = std.os.linux;
    var argv_storage = try allocator.alloc([:0]u8, argv.len);
    defer {
        for (argv_storage) |item| allocator.free(item);
        allocator.free(argv_storage);
    }
    var argv_z = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    defer allocator.free(argv_z);
    for (argv, 0..) |arg, i| {
        argv_storage[i] = try allocator.dupeZ(u8, arg);
        argv_z[i] = argv_storage[i].ptr;
    }
    argv_z[argv.len] = null;

    const env_in = std.os.environ;
    var envp = try allocator.allocSentinel(?[*:0]const u8, env_in.len, null);
    defer allocator.free(envp);
    for (env_in, 0..) |item, i| envp[i] = item;
    envp[env_in.len] = null;

    const stdout_pipe = try std.posix.pipe();
    const stderr_pipe = try std.posix.pipe();

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(stdout_pipe[0]);
        std.posix.close(stderr_pipe[0]);
        _ = std.posix.setpgid(0, 0) catch {};

        try unshareNamespaces();

        const child_pid = try std.posix.fork();
        if (child_pid == 0) {
            _ = std.posix.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO) catch {};
            _ = std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO) catch {};
            const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch -1;
            if (devnull >= 0) {
                _ = std.posix.dup2(devnull, std.posix.STDIN_FILENO) catch {};
                std.posix.close(devnull);
            }
            std.posix.close(stdout_pipe[1]);
            std.posix.close(stderr_pipe[1]);

            std.posix.chdir(cwd_path) catch {};
            _ = std.posix.setgid(10001) catch {};
            _ = std.posix.setuid(10001) catch {};
            _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
            applyRlimits(timeout_ns) catch {};

            const argv_ptr = @as([*:null]const ?[*:0]const u8, @ptrCast(argv_z.ptr));
            const envp_ptr = @as([*:null]const ?[*:0]const u8, @ptrCast(envp.ptr));
            _ = std.posix.execvpeZ(argv_z[0].?, argv_ptr, envp_ptr) catch {};
            std.posix.exit(127);
        }

        const wait_result = std.posix.waitpid(child_pid, 0);
        const exit_code = decodeExitCode(wait_result.status) orelse 255;
        std.posix.exit(@as(u8, @intCast(@min(exit_code, 255))));
    }

    std.posix.close(stdout_pipe[1]);
    std.posix.close(stderr_pipe[1]);

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    defer stderr.deinit(allocator);

    var out_truncated = false;
    var err_truncated = false;
    var out_ctx = ReadPipeCtx{
        .file = std.fs.File{ .handle = stdout_pipe[0] },
        .list = &stdout,
        .allocator = allocator,
        .max_bytes = output_max,
        .truncated = &out_truncated,
    };
    var err_ctx = ReadPipeCtx{
        .file = std.fs.File{ .handle = stderr_pipe[0] },
        .list = &stderr,
        .allocator = allocator,
        .max_bytes = output_max,
        .truncated = &err_truncated,
    };

    var out_thread = try std.Thread.spawn(.{}, readPipe, .{&out_ctx});
    var err_thread = try std.Thread.spawn(.{}, readPipe, .{&err_ctx});

    var wait_state = WaitState{};
    var waiter = try std.Thread.spawn(.{}, waiterThread, .{ pid, &wait_state });

    var exit_code: ?i32 = null;
    var timed_out = false;

    wait_state.mutex.lock();
    if (!wait_state.done) {
        wait_state.cond.timedWait(&wait_state.mutex, timeout_ns) catch |err| switch (err) {
            error.Timeout => timed_out = true,
        };
    }
    if (!timed_out and wait_state.done) {
        exit_code = decodeExitCode(wait_state.status);
    }
    wait_state.mutex.unlock();

    if (timed_out) {
        std.log.warn("run timed out; killing process group", .{});
        _ = std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        wait_state.mutex.lock();
        while (!wait_state.done) {
            wait_state.cond.wait(&wait_state.mutex);
        }
        wait_state.mutex.unlock();
        exit_code = null;
    }

    out_thread.join();
    err_thread.join();
    waiter.join();

    if (out_truncated or err_truncated) {
        return error.OutputTooLarge;
    }

    return RunResult{
        .exit_code = exit_code,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

fn unshareNamespaces() !void {
    const linux = std.os.linux;
    const flags = linux.CLONE.NEWNS | linux.CLONE.NEWPID | linux.CLONE.NEWIPC | linux.CLONE.NEWUTS | linux.CLONE.NEWNET;
    if (linux.unshare(flags) != 0) return error.UnshareFailed;
    const root: [:0]const u8 = "/";
    if (linux.mount(null, root.ptr, null, linux.MS.REC | linux.MS.PRIVATE, 0) != 0) return error.MountPrivateFailed;
}

fn applyRlimits(timeout_ns: u64) !void {
    const cpu_seconds: u64 = @max(1, @divTrunc(timeout_ns + std.time.ns_per_s - 1, std.time.ns_per_s));
    _ = std.posix.setrlimit(.CPU, .{ .cur = cpu_seconds, .max = cpu_seconds }) catch {};
    _ = std.posix.setrlimit(.NOFILE, .{ .cur = 256, .max = 256 }) catch {};
    _ = std.posix.setrlimit(.NPROC, .{ .cur = 256, .max = 256 }) catch {};
    _ = std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
}

fn decodeExitCode(status: u32) ?i32 {
    if (std.posix.W.IFEXITED(status)) {
        return @as(i32, @intCast(std.posix.W.EXITSTATUS(status)));
    }
    if (std.posix.W.IFSIGNALED(status)) {
        return 128 + @as(i32, @intCast(std.posix.W.TERMSIG(status)));
    }
    return null;
}

fn readPipe(ctx: *ReadPipeCtx) void {
    defer ctx.file.close();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = ctx.file.read(&buf) catch break;
        if (n == 0) break;
        if (ctx.max_bytes == 0) {
            ctx.list.appendSlice(ctx.allocator, buf[0..n]) catch break;
            continue;
        }
        if (ctx.list.items.len >= ctx.max_bytes) {
            ctx.truncated.* = true;
            continue;
        }
        const remaining = ctx.max_bytes - ctx.list.items.len;
        const to_copy = if (n > remaining) remaining else n;
        if (to_copy > 0) {
            ctx.list.appendSlice(ctx.allocator, buf[0..to_copy]) catch break;
        }
        if (to_copy < n) {
            ctx.truncated.* = true;
        }
    }
}

fn sendJson(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };
    try req.respond(body, .{
        .status = status,
        .extra_headers = &headers,
    });
}
