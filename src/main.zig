const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

pub const std_options: std.Options = .{
    .log_level = .info,
};

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
    file: Io.File,
    list: *std.ArrayList(u8),
    allocator: Allocator,
    max_bytes: usize,
    truncated: *bool,
    io: Io,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const port = resolvePort(env);
    const allow_shutdown = resolveAllowShutdown(env);
    const run_concurrency = resolveRunConcurrency(env);
    const input_max = resolveInputMax(env);
    const output_max = resolveOutputMax(env);
    const debug_enabled = resolveDebugEnabled(env);
    const uid_base = resolveUidBase(env);
    const runner_cmd = try resolveRunnerCmd(gpa, io);
    defer runner_cmd.deinit(gpa);

    if (run_concurrency == 0 or run_concurrency > 64) return error.RunConcurrencyOutOfRange;

    // Build envp once for the sandboxed child to pass to execve. 0.16 removed
    // `std.os.environ`; the environment is only reachable via init.environ_map.
    const child_envp = try buildChildEnvp(gpa, env);
    defer freeChildEnvp(gpa, child_envp);

    var state: ServerState = .init(
        io,
        allow_shutdown,
        run_concurrency,
        input_max,
        output_max,
        debug_enabled,
        uid_base,
        runner_cmd,
        child_envp,
    );

    try serve(gpa, port, &state);
}

pub const ServerState = struct {
    io: Io,
    allow_shutdown: bool,
    shutdown: std.atomic.Value(bool),
    /// Bitmap: bit N set ⇒ slot N is free. Up to 64 slots.
    free_slots: std.atomic.Value(u64),
    slot_count: u6,
    /// Base for per-run UID. Run on slot N executes as `uid_base + N`.
    uid_base: u32,
    input_max: usize,
    output_max: usize,
    debug_enabled: bool,
    runner_cmd: RunnerCmd,
    /// Sentinel-terminated envp built once at startup from `init.environ_map`
    /// and passed to every sandboxed `execve`. 0.16 removed std.os.environ, so
    /// we capture it once instead of reaching for the global.
    child_envp: [:null]?[*:0]const u8,

    pub fn init(
        io: Io,
        allow_shutdown: bool,
        run_concurrency: usize,
        input_max: usize,
        output_max: usize,
        debug_enabled: bool,
        uid_base: u32,
        runner_cmd: RunnerCmd,
        child_envp: [:null]?[*:0]const u8,
    ) ServerState {
        const n: u6 = @intCast(run_concurrency);
        const initial: u64 = if (n == 64) ~@as(u64, 0) else (@as(u64, 1) << n) - 1;
        return .{
            .io = io,
            .allow_shutdown = allow_shutdown,
            .shutdown = .init(false),
            .free_slots = .init(initial),
            .slot_count = n,
            .uid_base = uid_base,
            .input_max = input_max,
            .output_max = output_max,
            .debug_enabled = debug_enabled,
            .runner_cmd = runner_cmd,
            .child_envp = child_envp,
        };
    }

    /// Atomically reserve a free slot. Returns the slot index or null if all
    /// slots are in use.
    pub fn acquireSlot(self: *ServerState) ?u6 {
        var cur = self.free_slots.load(.monotonic);
        while (cur != 0) {
            const slot: u6 = @intCast(@ctz(cur));
            const bit: u64 = @as(u64, 1) << slot;
            const next = cur & ~bit;
            cur = self.free_slots.cmpxchgWeak(cur, next, .acquire, .monotonic) orelse return slot;
        }
        return null;
    }

    pub fn releaseSlot(self: *ServerState, slot: u6) void {
        const bit: u64 = @as(u64, 1) << slot;
        _ = self.free_slots.fetchOr(bit, .release);
    }
};

pub fn serve(gpa: Allocator, port: u16, state: *ServerState) !void {
    const io = state.io;
    var address: Io.net.IpAddress = try .parse("0.0.0.0", port);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    std.log.info("listening on 0.0.0.0:{d}", .{port});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            if (state.shutdown.load(.seq_cst)) break;
            continue;
        };
        const args = ConnectionArgs{ .gpa = gpa, .stream = stream, .state = state };
        const thread = std.Thread.spawn(.{}, handleConnection, .{args}) catch |err| {
            std.log.err("spawn connection handler failed: {s}", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();

        if (state.shutdown.load(.seq_cst)) break;
    }
}

const ConnectionArgs = struct {
    gpa: Allocator,
    stream: Io.net.Stream,
    state: *ServerState,
};

fn handleConnection(args: ConnectionArgs) void {
    const io = args.state.io;
    var arena = std.heap.ArenaAllocator.init(args.gpa);
    defer arena.deinit();
    defer args.stream.close(io);

    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var stream_reader = args.stream.reader(io, &read_buf);
    var stream_writer = args.stream.writer(io, &write_buf);
    var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        // Reset arena per request: prevents unbounded growth on HTTP keep-alive.
        _ = arena.reset(.{ .retain_with_limit = 256 * 1024 });
        const allocator = arena.allocator();

        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => {
                std.log.err("accept failed: {s}", .{@errorName(err)});
                break;
            },
        };

        handleRequest(allocator, args.gpa, io, &req, args.state) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
            sendJson(&req, .internal_server_error, "{\"error\":\"internal\"}") catch {};
        };

        if (args.state.shutdown.load(.seq_cst)) break;
    }
}

fn resolvePort(env: *const Environ.Map) u16 {
    const value = env.get("PORT") orelse return 4040;
    return std.fmt.parseUnsigned(u16, value, 10) catch 4040;
}

fn resolveAllowShutdown(env: *const Environ.Map) bool {
    const value = env.get("ALLOW_SHUTDOWN") orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
}

fn resolveRunConcurrency(env: *const Environ.Map) usize {
    const value = env.get("RUN_CONCURRENCY") orelse return 10;
    return std.fmt.parseUnsigned(usize, value, 10) catch 10;
}

fn resolveOutputMax(env: *const Environ.Map) usize {
    const value = env.get("RUN_OUTPUT_MAX") orelse return 1024 * 1024;
    return std.fmt.parseUnsigned(usize, value, 10) catch 1024 * 1024;
}

fn resolveInputMax(env: *const Environ.Map) usize {
    const value = env.get("RUN_INPUT_MAX") orelse return 1024 * 1024;
    return std.fmt.parseUnsigned(usize, value, 10) catch 1024 * 1024;
}

/// Builds a NULL-terminated `envp` (array of "KEY=VALUE\0" C strings) from
/// the process's `environ_map`. Caller frees with `freeChildEnvp`.
fn buildChildEnvp(gpa: Allocator, env: *const Environ.Map) ![:null]?[*:0]const u8 {
    const n = env.count();
    var envp = try gpa.allocSentinel(?[*:0]const u8, n, null);
    errdefer gpa.free(envp);

    var written: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < written) : (i += 1) {
            const ptr = envp[i].?;
            const len = std.mem.len(ptr);
            gpa.free(ptr[0 .. len + 1]);
        }
    }

    var it = env.iterator();
    while (it.next()) |entry| : (written += 1) {
        const kv = try std.fmt.allocPrintSentinel(
            gpa,
            "{s}={s}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
            0,
        );
        envp[written] = kv.ptr;
    }
    return envp;
}

fn freeChildEnvp(gpa: Allocator, envp: [:null]?[*:0]const u8) void {
    for (envp) |slot_opt| {
        const ptr = slot_opt orelse continue;
        const len = std.mem.len(ptr);
        gpa.free(ptr[0 .. len + 1]);
    }
    gpa.free(envp);
}

fn resolveUidBase(env: *const Environ.Map) u32 {
    const value = env.get("RUN_UID_BASE") orelse return 10001;
    return std.fmt.parseUnsigned(u32, value, 10) catch 10001;
}

fn resolveDebugEnabled(env: *const Environ.Map) bool {
    const value = env.get("DEBUG") orelse return false;
    if (value.len == 0) return true;
    return !(std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false"));
}

const RunnerCmd = struct {
    raw: []const u8,
    argv: []const []const u8,

    fn deinit(self: RunnerCmd, allocator: Allocator) void {
        allocator.free(self.raw);
        allocator.free(self.argv);
    }
};

fn resolveRunnerCmd(gpa: Allocator, io: Io) !RunnerCmd {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "make", "-n", "test" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Ensure child does not leak on error paths between spawn and wait.
    var spawned = true;
    errdefer if (spawned) {
        child.kill(io);
        _ = child.wait(io) catch {};
    };

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(gpa);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(gpa);

    try readAllIntoList(io, gpa, child.stdout.?, &stdout);
    try readAllIntoList(io, gpa, child.stderr.?, &stderr);

    const term = try child.wait(io);
    spawned = false;
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                if (stderr.items.len > 0) std.log.err("make -n test failed: {s}", .{stderr.items});
                return error.MakeDryRunFailed;
            }
        },
        else => {
            if (stderr.items.len > 0) std.log.err("make -n test failed: {s}", .{stderr.items});
            return error.MakeDryRunFailed;
        },
    }

    const trimmed = std.mem.trim(u8, stdout.items, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidRunnerCmd;

    const raw = try gpa.dupe(u8, trimmed);
    errdefer gpa.free(raw);
    const argv = try gpa.alloc([]const u8, 3);
    // Absolute path: runCommandSandboxed execs via raw execve, which does no
    // PATH lookup. cwd at that point is the overlay mount, which has no `sh`.
    argv[0] = "/bin/sh";
    argv[1] = "-c";
    argv[2] = raw;
    return .{ .raw = raw, .argv = argv };
}

fn readAllIntoList(io: Io, gpa: Allocator, file: Io.File, list: *std.ArrayList(u8)) !void {
    var buf: [8192]u8 = undefined;
    while (true) {
        var bufs: [1][]u8 = .{buf[0..]};
        const n = file.readStreaming(io, &bufs) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (n == 0) return;
        try list.appendSlice(gpa, buf[0..n]);
    }
}

fn handleRequest(allocator: Allocator, gpa: Allocator, io: Io, req: *std.http.Server.Request, state: *ServerState) !void {
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
        try handleRun(allocator, gpa, io, req, state);
        return;
    }

    try req.respond("not found\n", .{ .status = .not_found });
}

fn handleRun(allocator: Allocator, gpa: Allocator, io: Io, req: *std.http.Server.Request, state: *ServerState) !void {
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

    const slot = state.acquireSlot() orelse {
        std.log.warn("run rejected: runner busy", .{});
        try sendJson(req, .too_many_requests, "{\"error\":\"runner busy\"}");
        return;
    };
    defer state.releaseSlot(slot);

    const start_ts = Io.Timestamp.now(io, .awake);
    const result = runInTemp(allocator, gpa, io, state, slot, lang, data, timeout_ns) catch |err| {
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
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(response, .{}, &out.writer);
    const json_body = try out.toOwnedSlice();
    defer allocator.free(json_body);

    const end_ts = Io.Timestamp.now(io, .awake);
    const elapsed_ns: u64 = blk: {
        const a: i128 = @intCast(start_ts.nanoseconds);
        const b: i128 = @intCast(end_ts.nanoseconds);
        const d = b - a;
        if (d < 0) break :blk 0;
        break :blk @intCast(d);
    };
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
    reader: *Io.Reader,
    max_bytes: usize,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var buf: [16 * 1024]u8 = undefined;
    var too_large = false;
    while (true) {
        var bufs: [1][]u8 = .{buf[0..]};
        const n = reader.readVec(&bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        if (too_large) continue;
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
    if (timeout == null) return 30 * std.time.ns_per_s;

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
    gpa: Allocator,
    io: Io,
    state: *ServerState,
    slot: u6,
    lang: LangConfig,
    data: RunRequest,
    timeout_ns: u64,
) !RunResult {
    const uid: u32 = state.uid_base + @as(u32, slot);
    const layout = try makeTempLayout(gpa, io, slot, uid);
    // Hand cleanup off to a detached thread after `runCommand` returns so the
    // HTTP response is on the wire before any rmdir/unlink work happens.
    // `layout` owns gpa-allocated paths, so it can outlive the per-request arena.
    var layout_to_clean = layout;
    errdefer layout_to_clean.deinit(io, gpa);

    try copyWorkspace(io, layout.target_dir);
    try writeInputs(io, layout.target_dir, lang, data);

    const cfg = RunCommandConfig{
        .target_path = layout.target_path,
        .uid = uid,
        .timeout_ns = timeout_ns,
        .output_max = state.output_max,
        .argv = state.runner_cmd.argv,
        .envp = state.child_envp,
    };
    const result = runCommand(allocator, io, cfg) catch |err| {
        layout_to_clean.deinit(io, gpa);
        return err;
    };

    // Try to schedule background cleanup. On any failure (OOM, thread limit),
    // fall back to inline cleanup — correctness over latency.
    scheduleCleanup(gpa, io, &layout_to_clean) catch {
        layout_to_clean.deinit(io, gpa);
    };
    return result;
}

const CleanupCtx = struct {
    layout: *TempLayout,
    io: Io,
    gpa: Allocator,
};

fn scheduleCleanup(gpa: Allocator, io: Io, layout: *TempLayout) !void {
    const heap = try gpa.create(TempLayout);
    heap.* = layout.*;
    // The caller's `layout` is now logically moved; zero the source's
    // owned-pointer fields so a stray deinit there is a no-op.
    layout.* = .{ .target_path = &.{}, .target_dir = .{ .handle = -1 } };

    const ctx = CleanupCtx{ .layout = heap, .io = io, .gpa = gpa };
    const t = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, cleanupThread, .{ctx}) catch |err| {
        // Move ownership back so the caller can clean up.
        layout.* = heap.*;
        gpa.destroy(heap);
        return err;
    };
    t.detach();
}

fn cleanupThread(ctx: CleanupCtx) void {
    ctx.layout.deinit(ctx.io, ctx.gpa);
    ctx.gpa.destroy(ctx.layout);
}

const RunResult = struct {
    exit_code: ?i32,
    stdout: []u8,
    stderr: []u8,
};

const RunCommandConfig = struct {
    /// Per-request working dir: a fresh /tmp/runner-N-XXX populated by copying
    /// the runner's workspace and then writing the request's input files.
    target_path: []const u8,
    /// UID the child runs as. Equals `state.uid_base + slot` on Linux; ignored
    /// on other targets (which just inherit).
    uid: u32,
    timeout_ns: u64,
    output_max: usize,
    argv: []const []const u8,
    /// Sentinel-terminated envp for `execve` (Linux sandboxed path only).
    envp: [:null]?[*:0]const u8,
};

/// Per-request scratch dir under /tmp, populated by copying the runner's
/// workspace and writing the request's input files. On Linux it is chowned to
/// the slot's UID so the unprivileged sandboxed child can read/write inside.
const TempLayout = struct {
    target_path: []u8,
    target_dir: Io.Dir,

    /// Idempotent: safe to call multiple times. After the first call (or after
    /// `scheduleCleanup` moves the contents to a heap copy) this is a no-op.
    fn deinit(self: *TempLayout, io: Io, gpa: Allocator) void {
        if (self.target_path.len == 0) return;
        self.target_dir.close(io);
        deleteTreeAbsolute(io, self.target_path) catch {};
        gpa.free(self.target_path);
        self.* = .{ .target_path = &.{}, .target_dir = .{ .handle = -1 } };
    }
};

fn makeTempLayout(gpa: Allocator, io: Io, slot: u6, uid: u32) !TempLayout {
    var tmp_parent = try Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp_parent.close(io);

    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var random_bytes: [9]u8 = undefined;
        io.random(&random_bytes);
        var suffix: [std.fs.base64_encoder.calcSize(random_bytes.len)]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&suffix, &random_bytes);
        // Some base64 url-safe chars are filesystem-safe but `=` padding may
        // appear; calcSize(9) = 12 (no padding). Keep the assertion implicit.

        const slot_u8: u8 = slot;
        const target_name = try std.fmt.allocPrint(gpa, "runner-{d}-{s}", .{ slot_u8, suffix });
        defer gpa.free(target_name);

        tmp_parent.createDir(io, target_name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };

        const target_path = try std.fmt.allocPrint(gpa, "/tmp/{s}", .{target_name});
        errdefer {
            tmp_parent.deleteDir(io, target_name) catch {};
            gpa.free(target_path);
        }

        const target_dir = try tmp_parent.openDir(io, target_name, .{ .iterate = true });
        errdefer (target_dir).close(io);

        if (isRoot()) {
            // Chown the top-level scratch dir to the slot UID so the unprivileged
            // sandboxed child can chdir/read inside. The workspace tree is copied
            // in next as root; its files inherit root ownership but copyDirRecursive
            // creates dirs as 0o777 and files as 0644 → other (uid) gets read/x.
            // Non-root (e.g. host-side unit tests) skips this — runCommand will
            // pick runCommandSimple instead, which runs as the inheriting UID.
            try chownAbsolute(gpa, target_path, uid);
        }

        return .{ .target_path = target_path, .target_dir = target_dir };
    }

    return error.TempDirUnavailable;
}

fn chownAbsolute(gpa: Allocator, abs_path: []const u8, uid: u32) !void {
    const path_z = try gpa.dupeZ(u8, abs_path);
    defer gpa.free(path_z);
    if (linux.errno(linux.chown(path_z.ptr, uid, uid)) != .SUCCESS) return error.ChownFailed;
}

fn copyWorkspace(io: Io, dst_dir: Io.Dir) !void {
    const ignore = [_][]const u8{ ".git", "zig-cache", ".zig-cache", "zig-out" };
    var src_dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer src_dir.close(io);
    try copyDirRecursive(io, src_dir, dst_dir, &ignore);
}

fn copyDirRecursive(io: Io, src: Io.Dir, dst: Io.Dir, ignore: []const []const u8) !void {
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (isIgnored(entry.name, ignore)) continue;

        switch (entry.kind) {
            .directory => {
                dst.createDir(io, entry.name, .fromMode(0o777)) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                var src_child = try src.openDir(io, entry.name, .{ .iterate = true });
                defer src_child.close(io);
                var dst_child = try dst.openDir(io, entry.name, .{ .iterate = true });
                defer dst_child.close(io);
                try copyDirRecursive(io, src_child, dst_child, ignore);
            },
            .file => {
                try src.copyFile(entry.name, dst, entry.name, io, .{});
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

/// 0.16 removed std.fs.deleteTreeAbsolute. Roll our own using Io.Dir.walkSelectively.
fn deleteTreeAbsolute(io: Io, abs_path: []const u8) !void {
    var dir = Io.Dir.openDirAbsolute(io, abs_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    try deleteDirContents(io, dir);
    // Now remove the (empty) directory itself.
    const parent_path = std.fs.path.dirname(abs_path) orelse return;
    const name = std.fs.path.basename(abs_path);
    var parent = try Io.Dir.openDirAbsolute(io, parent_path, .{});
    defer parent.close(io);
    parent.deleteDir(io, name) catch {};
}

fn deleteDirContents(io: Io, dir: Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(io);
                deleteDirContents(io, child) catch {};
                dir.deleteDir(io, entry.name) catch {};
            },
            else => {
                dir.deleteFile(io, entry.name) catch {};
            },
        }
    }
}

fn writeInputs(io: Io, root: Io.Dir, lang: LangConfig, data: RunRequest) !void {
    try root.createDirPath(io, lang.dir);
    var lang_dir = try root.openDir(io, lang.dir, .{});
    defer lang_dir.close(io);

    try writeFile(io, lang_dir, lang.solution, data.solution_text);

    if (data.checker_text) |checker| {
        if (lang.checker) |checker_name| {
            try writeFile(io, lang_dir, checker_name, checker);
        }
    }

    if (data.asserts) |asserts| {
        try writeFile(io, lang_dir, "asserts.json", asserts);
    }
}

fn writeFile(io: Io, dir: Io.Dir, name: []const u8, contents: []const u8) !void {
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

const ExitWait = struct {
    exit_event: Io.Event = .unset,
    status: std.atomic.Value(u32) = .init(0),
};

/// Raw-syscall waiter, used by the sandboxed fork-exec path.
fn rawWaiterThread(pid: posix.pid_t, io: Io, wait: *ExitWait) void {
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        const errno = linux.errno(rc);
        if (errno == .SUCCESS) {
            wait.status.store(status, .release);
            wait.exit_event.set(io);
            return;
        }
        if (errno == .INTR) continue;
        wait.status.store(0xFFFF_FFFF, .release);
        wait.exit_event.set(io);
        return;
    }
}

const ChildWaitCtx = struct {
    child: *std.process.Child,
    io: Io,
    wait: *ExitWait,
};

/// Cross-platform waiter for processes spawned via std.process.spawn.
fn childWaiterThread(ctx: ChildWaitCtx) void {
    const io = ctx.io;
    const term = ctx.child.wait(io) catch {
        ctx.wait.status.store(0xFFFF_FFFF, .release);
        ctx.wait.exit_event.set(io);
        return;
    };
    const encoded: u32 = switch (term) {
        .exited => |code| (@as(u32, code) << 8),
        .signal => |sig| @intFromEnum(sig) & 0x7f,
        .stopped => |sig| (@as(u32, @intFromEnum(sig)) << 8) | 0x7f,
        .unknown => |u| u,
    };
    ctx.wait.status.store(encoded, .release);
    ctx.wait.exit_event.set(io);
}

fn runCommand(allocator: Allocator, io: Io, cfg: RunCommandConfig) !RunResult {
    // Sandboxed path needs root: it calls unshare(CLONE_NEW*) (CAP_SYS_ADMIN)
    // and the inner child setuid()s to the slot UID. Without root, fall back
    // to the same simple path macOS uses — correct for host-side unit tests
    // and for non-privileged dev setups.
    if (builtin.os.tag == .linux and isRoot()) return runCommandSandboxed(allocator, io, cfg);
    return runCommandSimple(allocator, io, cfg);
}

fn isRoot() bool {
    if (builtin.os.tag != .linux) return false;
    return linux.getuid() == 0;
}

fn runCommandSimple(allocator: Allocator, io: Io, cfg: RunCommandConfig) !RunResult {
    var child = try std.process.spawn(io, .{
        .argv = cfg.argv,
        .cwd = .{ .path = cfg.target_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });

    // Transfer ownership of stdout/stderr fds out of the Child struct so child.wait
    // (called from childWaiterThread) won't try to close them itself. We close
    // them ourselves via `defer` below.
    const stdout_file = child.stdout.?;
    const stderr_file = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer stdout_file.close(io);
    defer stderr_file.close(io);

    // Errdefer that fires on any failure between spawn and successful join.
    // `reaped` is set to true only after we've successfully joined the waiter.
    var reaped = false;
    var threads: [3]?std.Thread = .{ null, null, null };
    errdefer {
        // Signal the child (and through it the reader threads via EOF) to exit.
        if (child.id) |cid| _ = posix.kill(-cid, .KILL) catch {};
        for (threads) |t_opt| if (t_opt) |t| t.join();
        // If the waiter thread was never spawned or already reaped, child.wait
        // is either a no-op (waiter reaped it, set child.id=null) or the right
        // thing to do (waiter never ran, child still has resources to clean).
        if (!reaped) _ = child.wait(io) catch {};
    }

    const pid = child.id orelse return error.SpawnFailed;

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    defer stderr.deinit(allocator);

    var out_truncated = false;
    var err_truncated = false;
    var out_ctx = ReadPipeCtx{
        .file = stdout_file,
        .list = &stdout,
        .allocator = allocator,
        .max_bytes = cfg.output_max,
        .truncated = &out_truncated,
        .io = io,
    };
    var err_ctx = ReadPipeCtx{
        .file = stderr_file,
        .list = &stderr,
        .allocator = allocator,
        .max_bytes = cfg.output_max,
        .truncated = &err_truncated,
        .io = io,
    };

    threads[0] = try std.Thread.spawn(.{}, readPipe, .{&out_ctx});
    threads[1] = try std.Thread.spawn(.{}, readPipe, .{&err_ctx});

    var wait_state: ExitWait = .{};
    const child_ctx = ChildWaitCtx{ .child = &child, .io = io, .wait = &wait_state };
    threads[2] = try std.Thread.spawn(.{}, childWaiterThread, .{child_ctx});

    var exit_code: ?i32 = null;
    var timed_out = false;
    wait_state.exit_event.waitTimeout(io, .{ .duration = .{ .raw = .fromNanoseconds(@intCast(cfg.timeout_ns)), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => timed_out = true,
        else => |e| return e,
    };

    if (timed_out) {
        std.log.warn("run timed out; killing process group", .{});
        _ = posix.kill(-pid, .KILL) catch {};
        wait_state.exit_event.wait(io) catch {};
    } else {
        exit_code = decodeExitCode(wait_state.status.load(.acquire));
    }

    threads[0].?.join();
    threads[1].?.join();
    threads[2].?.join();
    threads = .{ null, null, null };
    reaped = true;

    if (out_truncated or err_truncated) return error.OutputTooLarge;

    return RunResult{
        .exit_code = exit_code,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

fn runCommandSandboxed(allocator: Allocator, io: Io, cfg: RunCommandConfig) !RunResult {
    // Build a NULL-terminated argv array for execve.
    var argv_storage = try allocator.alloc([:0]u8, cfg.argv.len);
    var initialized: usize = 0;
    defer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) allocator.free(argv_storage[i]);
        allocator.free(argv_storage);
    }
    var argv_z = try allocator.allocSentinel(?[*:0]const u8, cfg.argv.len, null);
    defer allocator.free(argv_z);
    while (initialized < cfg.argv.len) : (initialized += 1) {
        argv_storage[initialized] = try allocator.dupeZ(u8, cfg.argv[initialized]);
        argv_z[initialized] = argv_storage[initialized].ptr;
    }

    // Pre-build NUL-terminated path strings; we can't allocate after fork.
    const target_path_z = try allocator.dupeZ(u8, cfg.target_path);
    defer allocator.free(target_path_z);
    const uid_for_child: posix.uid_t = @intCast(cfg.uid);

    // Pipes for child stdout/stderr. `*_write_closed` flips to true once the parent
    // closes its copy of the write end after the fork (which it always does before
    // any further fallible work); the read ends are always closed via the unconditional
    // `defer`s below.
    var stdout_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&stdout_pipe, .{})) != .SUCCESS) return error.PipeFailed;
    var stdout_write_closed = false;
    errdefer {
        if (!stdout_write_closed) _ = linux.close(stdout_pipe[1]);
    }
    defer _ = linux.close(stdout_pipe[0]);

    var stderr_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&stderr_pipe, .{})) != .SUCCESS) return error.PipeFailed;
    var stderr_write_closed = false;
    errdefer {
        if (!stderr_write_closed) _ = linux.close(stderr_pipe[1]);
    }
    defer _ = linux.close(stderr_pipe[0]);

    const fork_rc = linux.fork();
    const fork_errno = linux.errno(fork_rc);
    if (fork_errno != .SUCCESS) return error.ForkFailed;
    const pid: posix.pid_t = @bitCast(@as(u32, @truncate(fork_rc)));

    if (pid == 0) {
        // Outer child: become its own process group, unshare namespaces, then fork the real child.
        _ = linux.close(stdout_pipe[0]);
        _ = linux.close(stderr_pipe[0]);
        _ = linux.setpgid(0, 0);

        unshareNamespaces() catch sandboxFatal(stderr_pipe[1], "unshare", 121);

        const child_rc = linux.fork();
        if (linux.errno(child_rc) != .SUCCESS) sandboxFatal(stderr_pipe[1], "fork", 122);
        const child_pid: posix.pid_t = @bitCast(@as(u32, @truncate(child_rc)));

        if (child_pid == 0) {
            // Inner child: set up stdio, drop privs, exec.
            _ = linux.dup2(stdout_pipe[1], 1);
            _ = linux.dup2(stderr_pipe[1], 2);
            const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(devnull) == .SUCCESS) {
                const dn_fd: i32 = @bitCast(@as(u32, @truncate(devnull)));
                _ = linux.dup2(dn_fd, 0);
                _ = linux.close(dn_fd);
            }
            _ = linux.close(stdout_pipe[1]);
            _ = linux.close(stderr_pipe[1]);

            _ = linux.chdir(target_path_z.ptr);
            _ = linux.setgid(uid_for_child);
            _ = linux.setuid(uid_for_child);
            _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
            applyRlimits(cfg.timeout_ns);

            _ = linux.execve(argv_z[0].?, @ptrCast(argv_z.ptr), @ptrCast(cfg.envp.ptr));
            sandboxFatal(2, "execve /bin/sh", 124);
        }

        // Outer-child: wait for inner-child, propagate exit code.
        var status: u32 = 0;
        while (true) {
            const r = linux.waitpid(child_pid, &status, 0);
            const e = linux.errno(r);
            if (e == .SUCCESS) break;
            if (e == .INTR) continue;
            sandboxFatal(stderr_pipe[1], "waitpid inner", 125);
        }
        const code = decodeExitCode(status) orelse 255;
        linux.exit(@intCast(@min(code, 255)));
    }

    // Parent: close write ends (child has its own copies).
    _ = linux.close(stdout_pipe[1]);
    stdout_write_closed = true;
    _ = linux.close(stderr_pipe[1]);
    stderr_write_closed = true;

    // Errdefer that fires on any failure between fork-success and successful
    // join. `reaped` is set to true only after we've successfully joined the
    // waiter thread (which is what does the waitpid).
    var reaped = false;
    var threads: [3]?std.Thread = .{ null, null, null };
    errdefer {
        // Kill the whole process group so readers see EOF and the child
        // gets reaped by either the waiter (if it spawned) or our manual
        // waitpid below.
        _ = posix.kill(-pid, .KILL) catch {};
        for (threads) |t_opt| if (t_opt) |t| t.join();
        if (!reaped) {
            var status: u32 = 0;
            while (true) {
                const r = linux.waitpid(pid, &status, 0);
                const e = linux.errno(r);
                if (e != .INTR) break;
            }
        }
    }

    const stdout_file: Io.File = .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } };
    const stderr_file: Io.File = .{ .handle = stderr_pipe[0], .flags = .{ .nonblocking = false } };

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    defer stderr.deinit(allocator);

    var out_truncated = false;
    var err_truncated = false;
    var out_ctx = ReadPipeCtx{
        .file = stdout_file,
        .list = &stdout,
        .allocator = allocator,
        .max_bytes = cfg.output_max,
        .truncated = &out_truncated,
        .io = io,
    };
    var err_ctx = ReadPipeCtx{
        .file = stderr_file,
        .list = &stderr,
        .allocator = allocator,
        .max_bytes = cfg.output_max,
        .truncated = &err_truncated,
        .io = io,
    };

    threads[0] = try std.Thread.spawn(.{}, readPipe, .{&out_ctx});
    threads[1] = try std.Thread.spawn(.{}, readPipe, .{&err_ctx});

    var wait_state: ExitWait = .{};
    threads[2] = try std.Thread.spawn(.{}, rawWaiterThread, .{ pid, io, &wait_state });

    var exit_code: ?i32 = null;
    var timed_out = false;
    wait_state.exit_event.waitTimeout(io, .{ .duration = .{ .raw = .fromNanoseconds(@intCast(cfg.timeout_ns)), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => timed_out = true,
        else => |e| return e,
    };

    if (timed_out) {
        std.log.warn("run timed out; killing process group", .{});
        _ = posix.kill(-pid, .KILL) catch {};
        wait_state.exit_event.wait(io) catch {};
    } else {
        exit_code = decodeExitCode(wait_state.status.load(.acquire));
    }

    threads[0].?.join();
    threads[1].?.join();
    threads[2].?.join();
    threads = .{ null, null, null };
    reaped = true;

    if (out_truncated or err_truncated) return error.OutputTooLarge;

    return RunResult{
        .exit_code = exit_code,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

/// Diagnostic helper for the sandboxed child: write a short tag to `fd`,
/// then exit with `code`. Uses raw write+exit only (post-fork, must be
/// async-signal-safe). `fd` is typically 2 (stderr) once dup2 has run, or the
/// stderr-pipe write end before stdio is set up.
fn sandboxFatal(fd: i32, tag: []const u8, code: u8) noreturn {
    const prefix: []const u8 = "sandbox: ";
    const nl: []const u8 = "\n";
    _ = linux.write(fd, prefix.ptr, prefix.len);
    _ = linux.write(fd, tag.ptr, tag.len);
    _ = linux.write(fd, nl.ptr, nl.len);
    linux.exit(code);
}

fn unshareNamespaces() !void {
    const flags = linux.CLONE.NEWNS | linux.CLONE.NEWPID | linux.CLONE.NEWIPC | linux.CLONE.NEWUTS | linux.CLONE.NEWNET;
    if (linux.errno(linux.unshare(flags)) != .SUCCESS) return error.UnshareFailed;
    const root: [:0]const u8 = "/";
    if (linux.errno(linux.mount(null, root.ptr, null, linux.MS.REC | linux.MS.PRIVATE, 0)) != .SUCCESS) return error.MountPrivateFailed;
}

fn applyRlimits(timeout_ns: u64) void {
    const cpu_seconds: u64 = @max(1, @divTrunc(timeout_ns + std.time.ns_per_s - 1, std.time.ns_per_s));
    posix.setrlimit(.CPU, .{ .cur = cpu_seconds, .max = cpu_seconds }) catch {};
    posix.setrlimit(.NOFILE, .{ .cur = 256, .max = 256 }) catch {};
    posix.setrlimit(.NPROC, .{ .cur = 256, .max = 256 }) catch {};
    posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
}

fn decodeExitCode(status: u32) ?i32 {
    if (status == 0xFFFF_FFFF) return null;
    if (posix.W.IFEXITED(status)) {
        return @intCast(posix.W.EXITSTATUS(status));
    }
    if (posix.W.IFSIGNALED(status)) {
        return 128 + @as(i32, @intCast(@intFromEnum(posix.W.TERMSIG(status))));
    }
    return null;
}

fn readPipe(ctx: *ReadPipeCtx) void {
    const io = ctx.io;
    // Note: the caller owns `ctx.file` and is responsible for closing it after
    // joining this thread. We intentionally do NOT close it here so the fd
    // does not leak in the error path where `Thread.spawn` for this thread
    // failed and readPipe never runs.
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        var bufs: [1][]u8 = .{buf[0..]};
        const n = ctx.file.readStreaming(io, &bufs) catch break;
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
        if (to_copy < n) ctx.truncated.* = true;
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
