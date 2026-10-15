const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const sandbox = @import("sandbox.zig");

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
    slug: []const u8,
    dir: []const u8,
    solution: []const u8,
    checker: ?[]const u8,
    checker_required: bool,
    /// Per-lang default tmpfs `size=` for the request's /tmp. In the Linux
    /// sandbox this also caps everything else the request writes (workspace
    /// and cache overlays live in the same tmpfs). Overridable via
    /// `RUN_TMP_SIZE_<UPPER_SLUG>` > `RUN_SANDBOX_TMP_SIZE`.
    tmp_size: []const u8,
    /// Per-lang default cgroup memory.max for one run, tmpfs writes
    /// included. Overridable via `RUN_MEM_MAX_<UPPER_SLUG>` > `RUN_SANDBOX_MEM_MAX`.
    mem_max: []const u8,
    /// Image directories the toolchain writes to at run time. Each gets a
    /// per-request copy-on-write overlay (pre-warmed contents shared
    /// read-only, writes private). Missing paths are skipped. Overridable via
    /// `RUN_OVERLAY_PATHS_<UPPER_SLUG>=/a,/b`.
    overlay_paths: []const []const u8 = &.{},
};

// zig fmt: off
const all_langs = [_]LangConfig{
    // Sizes are generous on purpose for the popular langs (python/cpp/golang/
    // java); tmpfs pages and cgroup charges are lazy, so over-provisioning
    // costs nothing at idle.
    .{ .slug = "python",  .dir = "check", .solution = "solution.py",  .checker = null,             .checker_required = false, .tmp_size = "256m", .mem_max = "512m" },
    .{ .slug = "js",      .dir = "check", .solution = "solution.js",  .checker = null,             .checker_required = false, .tmp_size = "64m",  .mem_max = "512m" },
    .{ .slug = "ts",      .dir = "check", .solution = "solution.js",  .checker = null,             .checker_required = false, .tmp_size = "64m",  .mem_max = "512m" },
    .{ .slug = "ruby",    .dir = "check", .solution = "solution.rb",  .checker = null,             .checker_required = false, .tmp_size = "64m",  .mem_max = "512m" },
    .{ .slug = "php",     .dir = "check", .solution = "solution.php", .checker = null,             .checker_required = false, .tmp_size = "64m",  .mem_max = "512m" },
    .{ .slug = "elixir",  .dir = "check", .solution = "solution.exs", .checker = null,             .checker_required = false, .tmp_size = "128m", .mem_max = "512m" },
    .{ .slug = "clojure", .dir = "check", .solution = "solution.clj", .checker = null,             .checker_required = false, .tmp_size = "256m", .mem_max = "512m" },
    // Native compiles.
    .{ .slug = "cpp",     .dir = "check", .solution = "solution.cpp", .checker = "checker.cpp",    .checker_required = true,  .tmp_size = "512m", .mem_max = "1g" },
    .{ .slug = "zig",     .dir = "check", .solution = "solution.zig", .checker = "checker.zig",    .checker_required = true,  .tmp_size = "128m", .mem_max = "1g" },
    // D via ldc2: object files and the checker binary go to /tmp.
    .{ .slug = "dlang",   .dir = "check", .solution = "solution.d",   .checker = "checker.d",      .checker_required = true,  .tmp_size = "256m", .mem_max = "768m" },
    .{ .slug = "rust",    .dir = "check", .solution = "solution.rs",  .checker = "checker.rs",     .checker_required = true,  .tmp_size = "512m", .mem_max = "1g",
        .overlay_paths = &.{ "/opt/cargo", "/opt/cargo-target" } },
    .{ .slug = "swift",   .dir = "check", .solution = "solution.swift", .checker = "checker.swift",.checker_required = true,  .tmp_size = "256m", .mem_max = "1g" },
    .{ .slug = "haskell", .dir = "check", .solution = "Solution.hs",  .checker = "Checker.hs",     .checker_required = true,  .tmp_size = "256m", .mem_max = "1g" },
    .{ .slug = "golang",  .dir = "check", .solution = "solution.go",  .checker = "checker.go",     .checker_required = true,  .tmp_size = "512m", .mem_max = "1g",
        .overlay_paths = &.{ "/opt/go/cache", "/opt/go/mod" } },
    .{ .slug = "dart",    .dir = "lib",   .solution = "solution.dart", .checker = "checker.dart",  .checker_required = true,  .tmp_size = "128m", .mem_max = "768m" },
    // JVM family.
    .{ .slug = "java",    .dir = "check", .solution = "Solution.java", .checker = "Checker.java", .checker_required = true,  .tmp_size = "256m", .mem_max = "768m" },
    .{ .slug = "kotlin",  .dir = "check", .solution = "solution.kt",  .checker = "checker.kt",     .checker_required = true,  .tmp_size = "256m", .mem_max = "1g" },
    // .NET: heaviest single-file workload we host.
    .{ .slug = "csharp",  .dir = "check", .solution = "Solution.cs",  .checker = "Checker.cs",     .checker_required = true,  .tmp_size = "1g",   .mem_max = "1536m" },
};
// zig fmt: on

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

    const memory_max = resolveMemoryMax(env);

    // Clear the file-creation umask process-wide, before anything creates
    // files. In the Linux sandbox this gives the workspace skeleton and the
    // overlay upper dirs their exact 0o777 modes, so the slot UID can write
    // into pre-restored dirs (.NET's `obj/`, swift's `check/`, ...). On the
    // non-root fallback path copyDirRecursive relies on it the same way.
    // Must be process-wide and set at startup because umask isn't
    // thread-local.
    if (builtin.os.tag == .linux) _ = linux.syscall1(.umask, 0);

    // Linux + root: the full per-request sandbox (see sandbox.zig). Setup
    // failures are fatal; we never fall back to weaker isolation. Otherwise
    // (macOS, non-root dev) requests run unsandboxed via runCommandSimple.
    var sandbox_state: ?sandbox.Sandbox = null;
    defer if (sandbox_state) |sb| sb.deinit(gpa);
    var lang_opts: []sandbox.LangOpts = &.{};
    defer freeLangOpts(gpa, lang_opts);
    if (builtin.os.tag == .linux and isRoot()) {
        lang_opts = try buildLangOpts(gpa, env);
        sandbox_state = try sandbox.Sandbox.init(gpa, io, run_concurrency);
    }

    // Build envp once for the sandboxed child. We do NOT forward the parent's
    // full environment — user code must not see operator-injected secrets (DB
    // creds, API keys, etc.). Only an allowlist of benign keys (PATH, HOME,
    // LANG, LC_ALL, TZ) plus operator-listed extras from RUN_ENV_ALLOW=K1,K2
    // are passed through. HOME is force-set to /sandbox so user code's home
    // points at the per-request workspace.
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
        memory_max,
        if (sandbox_state) |*sb| sb else null,
        lang_opts,
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
    slot_count: u7,
    /// Base for per-run UID. Run on slot N executes as `uid_base + N`.
    uid_base: u32,
    input_max: usize,
    output_max: usize,
    debug_enabled: bool,
    /// RLIMIT_AS cap for user code (bytes). 0 ⇒ unlimited (cgroup expected).
    memory_max: u64,
    /// Linux sandbox state; null when running unsandboxed (non-root/macOS).
    sandbox: ?*const sandbox.Sandbox,
    /// Per-lang sandbox settings, indexed like `all_langs`. Empty when
    /// `sandbox` is null.
    lang_opts: []const sandbox.LangOpts,
    runner_cmd: RunnerCmd,
    /// Sentinel-terminated envp built once at startup from a curated allowlist
    /// (see buildChildEnvp). Passed to every sandboxed `execve`.
    child_envp: [:null]?[*:0]const u8,

    pub fn init(
        io: Io,
        allow_shutdown: bool,
        run_concurrency: usize,
        input_max: usize,
        output_max: usize,
        debug_enabled: bool,
        uid_base: u32,
        memory_max: u64,
        sandbox_state: ?*const sandbox.Sandbox,
        lang_opts: []const sandbox.LangOpts,
        runner_cmd: RunnerCmd,
        child_envp: [:null]?[*:0]const u8,
    ) ServerState {
        // u7, not u6: 64 is a valid slot count but does not fit in a u6.
        const n: u7 = @intCast(run_concurrency);
        const initial: u64 = if (n == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
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
            .memory_max = memory_max,
            .sandbox = sandbox_state,
            .lang_opts = lang_opts,
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
                std.log.err("receive head failed: {s}", .{@errorName(err)});
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

/// Curated allowlist of env keys that may be forwarded to user code. Anything
/// not on this list (or in RUN_ENV_ALLOW=KEY1,KEY2) is dropped, so operator
/// secrets (DB_PASSWORD, API_KEY, ...) never reach the sandboxed child.
const default_env_allow = [_][]const u8{ "PATH", "LANG", "LC_ALL", "TZ" };

/// Builds a NULL-terminated `envp` for the sandboxed child. Includes:
///   - Keys from `default_env_allow` if present in the parent env.
///   - Keys listed in RUN_ENV_ALLOW (comma-separated) if present in parent env.
///   - A forced `HOME=/sandbox` so user code's home points at the per-request
///     workspace (the parent's HOME, typically /root, is read-only and not
///     readable by the slot UID).
/// Caller frees with `freeChildEnvp`.
fn buildChildEnvp(gpa: Allocator, env: *const Environ.Map) ![:null]?[*:0]const u8 {
    var keep: std.ArrayList([:0]u8) = .empty;
    defer keep.deinit(gpa);
    errdefer for (keep.items) |kv| gpa.free(kv);

    inline for (default_env_allow) |k| {
        if (env.get(k)) |v| {
            const kv = try gpa.printSentinel("{s}={s}", .{ k, v }, 0);
            // If the append below OOMs we'd otherwise leak kv (it isn't in
            // keep.items yet, so the top errdefer wouldn't free it).
            errdefer gpa.free(kv);
            try keep.append(gpa, kv);
        }
    }

    if (env.get("RUN_ENV_ALLOW")) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const key = std.mem.trim(u8, part, " \t");
            if (key.len == 0) continue;
            if (isDefaultAllowed(key)) continue;
            if (std.mem.eql(u8, key, "HOME")) continue; // we set HOME ourselves
            if (env.get(key)) |v| {
                const kv = try gpa.printSentinel("{s}={s}", .{ key, v }, 0);
                errdefer gpa.free(kv);
                try keep.append(gpa, kv);
            }
        }
    }

    const home = try gpa.dupeSentinel(u8, "HOME=/sandbox", 0);
    {
        errdefer gpa.free(home);
        try keep.append(gpa, home);
    }

    var envp = try gpa.allocSentinel(?[*:0]const u8, keep.items.len, null);
    for (keep.items, 0..) |kv, i| envp[i] = kv.ptr;
    // Ownership of each kv string transferred to envp; clear the list so the
    // errdefer above doesn't double-free on the success path.
    keep.clearRetainingCapacity();
    return envp;
}

fn isDefaultAllowed(key: []const u8) bool {
    inline for (default_env_allow) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
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

/// Bytes; 0 means "do not set RLIMIT_AS" — defer to container cgroup memory.
/// Opt-in because some toolchains (JVM, .NET, Go) reserve enormous virtual
/// address space upfront, which RLIMIT_AS would reject.
fn resolveMemoryMax(env: *const Environ.Map) u64 {
    const value = env.get("RUN_MEMORY_MAX") orelse return 0;
    return std.fmt.parseUnsigned(u64, value, 10) catch 0;
}

/// Resolves every language's sandbox settings (env overrides applied) once
/// at startup; the result is indexed like `all_langs`.
fn buildLangOpts(gpa: Allocator, env: *const Environ.Map) ![]sandbox.LangOpts {
    var list = try gpa.alloc(sandbox.LangOpts, all_langs.len);
    errdefer gpa.free(list);
    var built: usize = 0;
    errdefer for (list[0..built]) |entry| entry.deinit(gpa);

    for (all_langs) |lang| {
        // Without `size=` tmpfs defaults to ~50% of host RAM.
        const tmp_size = resolveLangSetting(env, "RUN_TMP_SIZE_", lang.slug, "RUN_SANDBOX_TMP_SIZE") orelse lang.tmp_size;
        const mem_max = resolveLangSetting(env, "RUN_MEM_MAX_", lang.slug, "RUN_SANDBOX_MEM_MAX") orelse lang.mem_max;

        var overlay_buf: [16][]const u8 = undefined;
        var overlay_paths: []const []const u8 = lang.overlay_paths;
        if (resolveLangSetting(env, "RUN_OVERLAY_PATHS_", lang.slug, null)) |raw| {
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, raw, ", ");
            while (it.next()) |path| {
                if (n == overlay_buf.len) return error.TooManyOverlayPaths;
                overlay_buf[n] = path;
                n += 1;
            }
            overlay_paths = overlay_buf[0..n];
        }

        list[built] = try .init(gpa, tmp_size, mem_max, overlay_paths);
        built += 1;
    }
    return list;
}

fn freeLangOpts(gpa: Allocator, list: []sandbox.LangOpts) void {
    for (list) |entry| entry.deinit(gpa);
    gpa.free(list);
}

/// Looks up `<prefix><UPPER_SLUG>`, then the global `fallback_key` (if any).
fn resolveLangSetting(env: *const Environ.Map, comptime prefix: []const u8, slug: []const u8, fallback_key: ?[]const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (prefix.len + slug.len <= buf.len) {
        @memcpy(buf[0..prefix.len], prefix);
        for (slug, 0..) |c, i| buf[prefix.len + i] = std.ascii.toUpper(c);
        if (env.get(buf[0 .. prefix.len + slug.len])) |override| return override;
    }
    if (fallback_key) |key| return env.get(key);
    return null;
}

fn resolveDebugEnabled(env: *const Environ.Map) bool {
    const value = env.get("DEBUG") orelse return false;
    if (value.len == 0) return true;
    return !(std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false"));
}

const RunnerCmd = struct {
    raw: [:0]const u8,
    argv: []const []const u8,
    /// Same argv as NUL-terminated pointers for the sandbox's raw execve.
    argv_z: [:null]const ?[*:0]const u8,

    fn deinit(self: RunnerCmd, allocator: Allocator) void {
        allocator.free(self.raw);
        allocator.free(self.argv);
        allocator.free(self.argv_z);
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

    const raw = try gpa.dupeSentinel(u8, trimmed, 0);
    errdefer gpa.free(raw);
    const argv = try gpa.alloc([]const u8, 3);
    errdefer gpa.free(argv);
    // Absolute path: the sandbox execs via raw execve, which does no PATH
    // lookup.
    argv[0] = "/bin/sh";
    argv[1] = "-c";
    argv[2] = raw;
    const argv_z = try gpa.allocSentinel(?[*:0]const u8, 3, null);
    argv_z[0] = "/bin/sh";
    argv_z[1] = "-c";
    argv_z[2] = raw.ptr;
    return .{ .raw = raw, .argv = argv, .argv_z = argv_z };
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
    // RFC 9112 §6.3: a request with neither Content-Length nor
    // Transfer-Encoding has a zero-length body. std.http.Server instead
    // asserts one of them is present for POST/PUT/PATCH when responding, so a
    // bare `curl -X POST` would otherwise panic and take the server down.
    if (req.head.method.requestHasBody() and req.head.transfer_encoding == .none and req.head.content_length == null) {
        req.head.content_length = 0;
    }

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
        try sendJson(req, .bad_request, "{\"error\":\"invalid request body\"}");
        return;
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

    const timeout_ns = parseTimeoutNs(data.timeout) catch {
        try sendJson(req, .bad_request, "{\"error\":\"invalid timeout\"}");
        return;
    };

    const slot = state.acquireSlot() orelse {
        std.log.warn("run rejected: runner busy", .{});
        try sendJson(req, .too_many_requests, "{\"error\":\"runner busy\"}");
        return;
    };

    const start_ts = Io.Timestamp.now(io, .awake);
    // Release the slot the moment the run completes — before JSON
    // serialization, before sendJson writes to the socket, before the
    // function returns. Otherwise a client firing the next request the
    // instant it receives a response can arrive before our `defer` would
    // have released the slot, hitting a spurious 429. The slot represents
    // "an in-flight run", not "the entire HTTP exchange."
    const result_or_err = runInTemp(allocator, gpa, io, state, slot, lang, data, timeout_ns);
    state.releaseSlot(slot);
    const result = result_or_err catch |err| {
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
    // result.stdout/stderr come from gpa (the pipe-reader ArrayLists run on
    // their own threads and use gpa for thread-safety) — free with gpa.
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const response = RunResponse{
        .exit_code = result.exit_code,
        .stdout = try sanitizeUtf8(allocator, result.stdout),
        .stderr = try sanitizeUtf8(allocator, result.stderr),
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

/// std.json.Stringify passes bytes >= 0x80 through verbatim, so raw binary
/// output from user code (e.g. `print(b"\xff")`) would produce a response that
/// is not valid JSON. Replace ill-formed sequences with U+FFFD. The common
/// valid case returns `bytes` unchanged without allocating.
fn sanitizeUtf8(allocator: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    return allocator.print("{f}", .{std.unicode.fmtUtf8(bytes)});
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

fn parseTimeoutNs(timeout: ?[]const u8) error{InvalidTimeout}!u64 {
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

    const value = std.fmt.parseUnsigned(u64, number_text, 10) catch return error.InvalidTimeout;
    // Checked: an unchecked multiply panics (and aborts the whole server in
    // ReleaseSafe) on inputs like "99999999999999999m".
    const ns = std.math.mul(u64, value, unit_ns) catch return error.InvalidTimeout;
    if (ns == 0) return error.InvalidTimeout;
    return ns;
}

fn langIndex(slug: []const u8) ?usize {
    for (all_langs, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.slug, slug)) return i;
    }
    return null;
}

fn getLangConfig(slug: []const u8) ?LangConfig {
    for (all_langs) |entry| {
        if (std.mem.eql(u8, entry.slug, slug)) return entry;
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
    if (state.sandbox) |sb| {
        // The workspace is an overlay built inside the sandbox's own mount
        // namespace: no temp dir, no copy, nothing to clean up afterwards.
        const index = langIndex(lang.slug) orelse return error.UnknownLangSlug;
        return runCommandSandboxed(allocator, gpa, io, state, sb, slot, lang, &state.lang_opts[index], data, timeout_ns);
    }

    // Unsandboxed fallback (non-root / macOS dev): copy the workspace into a
    // temp dir and run there as the current user.
    const layout = try makeTempLayout(gpa, io, slot);
    // Hand cleanup off to a detached thread after `runCommandSimple` returns
    // so the HTTP response is on the wire before any rmdir/unlink work
    // happens. `layout` owns gpa-allocated paths, so it can outlive the
    // per-request arena.
    var layout_to_clean = layout;
    errdefer layout_to_clean.deinit(io, gpa);

    try copyWorkspace(io, layout.target_dir);
    try writeInputs(io, layout.target_dir, lang, data);

    const cfg = RunCommandConfig{
        .target_path = layout.target_path,
        .timeout_ns = timeout_ns,
        .output_max = state.output_max,
        .argv = state.runner_cmd.argv,
    };
    const result = runCommandSimple(gpa, io, cfg) catch |err| {
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

/// Unsandboxed fallback only; the Linux sandbox path takes its settings from
/// ServerState and sandbox.LangOpts.
const RunCommandConfig = struct {
    /// Per-request working dir: a fresh /tmp/runner-N-XXX populated by copying
    /// the runner's workspace and then writing the request's input files.
    target_path: []const u8,
    timeout_ns: u64,
    output_max: usize,
    argv: []const []const u8,
};

/// Per-request scratch dir under /tmp for the unsandboxed fallback, populated
/// by copying the runner's workspace and writing the request's input files.
const TempLayout = struct {
    target_path: []u8,
    target_dir: Io.Dir,

    /// Idempotent: safe to call multiple times. After the first call (or after
    /// `scheduleCleanup` moves the contents to a heap copy) this is a no-op.
    fn deinit(self: *TempLayout, io: Io, gpa: Allocator) void {
        if (self.target_path.len == 0) return;
        self.target_dir.close(io);
        deleteTreeAbsolute(gpa, io, self.target_path) catch |err| {
            std.log.warn("workspace cleanup failed for {s}: {s}", .{ self.target_path, @errorName(err) });
        };
        gpa.free(self.target_path);
        self.* = .{ .target_path = &.{}, .target_dir = .{ .handle = -1 } };
    }
};

fn makeTempLayout(gpa: Allocator, io: Io, slot: u6) !TempLayout {
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
        const target_name = try gpa.print("runner-{d}-{s}", .{ slot_u8, suffix });
        defer gpa.free(target_name);

        tmp_parent.createDir(io, target_name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };

        const target_path = try gpa.print("/tmp/{s}", .{target_name});
        errdefer {
            tmp_parent.deleteDir(io, target_name) catch {};
            gpa.free(target_path);
        }

        const target_dir = try tmp_parent.openDir(io, target_name, .{ .iterate = true });
        errdefer (target_dir).close(io);

        return .{ .target_path = target_path, .target_dir = target_dir };
    }

    return error.TempDirUnavailable;
}

fn copyWorkspace(io: Io, dst_dir: Io.Dir) !void {
    // `codebattle_runner` is this server's own ~4.5 MB binary (see the
    // Containerfile ENTRYPOINT); copying it made up most of the per-request
    // copy time and user code has no use for it.
    const ignore = [_][]const u8{ ".git", "zig-cache", ".zig-cache", "zig-out", "codebattle_runner" };
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

/// Removes the per-request workspace in O(entries) time with bounded stack
/// and fd usage, whatever shape user code left it in:
/// - iterative, with a fixed-depth frame stack on the heap (the old recursive
///   version overflowed the 64 KiB cleanup-thread stack at ~30 levels and
///   crashed the server);
/// - subdirectories found at the depth cap are renamed up into the workspace
///   root and handled by a later pass, so a 100k-deep chain costs O(n) rather
///   than the O(depth²) of std's `deleteTree` fallback;
/// - never follows symlinks: we run as root over a tree the sandboxed user
///   controlled.
fn deleteTreeAbsolute(gpa: Allocator, io: Io, abs_path: []const u8) !void {
    const parent_path = std.fs.path.dirname(abs_path) orelse return error.InvalidPath;
    const name = std.fs.path.basename(abs_path);
    var parent = try Io.Dir.openDirAbsolute(io, parent_path, .{});
    defer parent.close(io);
    {
        var root = parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer root.close(io);
        const frames = try gpa.alloc(DeleteFrame, delete_max_depth);
        defer gpa.free(frames);
        var next_id: usize = 0;
        while (try deletePass(io, root, frames, &next_id)) {}
    }
    try parent.deleteDir(io, name);
}

const delete_max_depth = 32;

const DeleteFrame = struct {
    dir: Io.Dir,
    it: Io.Dir.Iterator,
    /// This dir's name inside the previous frame's dir. Points into the
    /// previous frame's iterator buffer, which is not advanced until we pop
    /// back to it.
    name: []const u8,
};

/// One depth-first sweep of `root`. Returns true if it hoisted any subtree
/// into `root`; the caller then sweeps again, since an in-progress directory
/// iteration may or may not observe entries added to it.
fn deletePass(io: Io, root: Io.Dir, frames: []DeleteFrame, next_id: *usize) !bool {
    var hoisted = false;
    frames[0] = .{ .dir = root, .it = root.iterate(), .name = "" };
    var depth: usize = 1;
    errdefer for (frames[1..depth]) |f| f.dir.close(io);

    while (depth > 0) {
        const top = &frames[depth - 1];
        const entry = (try top.it.next(io)) orelse {
            depth -= 1;
            if (depth > 0) {
                top.dir.close(io);
                frames[depth - 1].dir.deleteDir(io, top.name) catch {};
            }
            continue;
        };
        if (entry.kind != .directory) {
            top.dir.deleteFile(io, entry.name) catch {};
            continue;
        }
        if (depth == frames.len) {
            // Too deep: move the subtree up to the root for a later pass.
            var buf: [32]u8 = undefined;
            while (true) : (next_id.* += 1) {
                const new_name = std.fmt.bufPrint(&buf, ".runner-rm-{d}", .{next_id.*}) catch unreachable;
                Io.Dir.rename(top.dir, entry.name, root, new_name, io) catch |err| switch (err) {
                    // Name taken by something user code created; try the next.
                    error.DirNotEmpty, error.NotDir => continue,
                    else => return err,
                };
                next_id.* += 1;
                break;
            }
            hoisted = true;
            continue;
        }
        const child = top.dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        frames[depth] = .{ .dir = child, .it = child.iterate(), .name = entry.name };
        depth += 1;
    }
    return hoisted;
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
    var status: i32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        const errno = linux.errno(rc);
        if (errno == .SUCCESS) {
            wait.status.store(@bitCast(status), .release);
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
        .signal => |sig| @backingInt(sig) & 0x7f,
        .stopped => |sig| (@as(u32, @backingInt(sig)) << 8) | 0x7f,
        .unknown => |u| u,
    };
    ctx.wait.status.store(encoded, .release);
    ctx.wait.exit_event.set(io);
}

fn isRoot() bool {
    if (builtin.os.tag != .linux) return false;
    return linux.getuid() == 0;
}

/// Unsandboxed fallback. `gpa` is used for the pipe-reader ArrayLists and the
/// returned stdout/stderr slices — the readers run on separate threads and the
/// per-request arena is not thread-safe. The caller (handleRun) must free
/// RunResult.stdout/stderr with `gpa`.
fn runCommandSimple(gpa: Allocator, io: Io, cfg: RunCommandConfig) !RunResult {
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
    defer stdout.deinit(gpa);
    defer stderr.deinit(gpa);

    var out_truncated = false;
    var err_truncated = false;
    var out_ctx = ReadPipeCtx{
        .file = stdout_file,
        .list = &stdout,
        .allocator = gpa,
        .max_bytes = cfg.output_max,
        .truncated = &out_truncated,
        .io = io,
    };
    var err_ctx = ReadPipeCtx{
        .file = stderr_file,
        .list = &stderr,
        .allocator = gpa,
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

    // Split the toOwnedSlice chain so an OOM on stderr doesn't strand stdout.
    const out_slice = try stdout.toOwnedSlice(gpa);
    errdefer gpa.free(out_slice);
    const err_slice = try stderr.toOwnedSlice(gpa);
    return RunResult{
        .exit_code = exit_code,
        .stdout = out_slice,
        .stderr = err_slice,
    };
}

fn runCommandSandboxed(
    allocator: Allocator,
    gpa: Allocator,
    io: Io,
    state: *ServerState,
    sb: *const sandbox.Sandbox,
    slot: u6,
    lang: LangConfig,
    lang_opts: *const sandbox.LangOpts,
    data: RunRequest,
    timeout_ns: u64,
) !RunResult {
    // Everything the children need is prepared here: no allocation after fork.
    var inputs: [3]sandbox.Input = undefined;
    var input_count: usize = 0;
    inputs[input_count] = .{ .path = try sandbox.inputPath(allocator, lang.dir, lang.solution), .contents = data.solution_text };
    input_count += 1;
    if (data.checker_text) |checker| if (lang.checker) |checker_name| {
        inputs[input_count] = .{ .path = try sandbox.inputPath(allocator, lang.dir, checker_name), .contents = checker };
        input_count += 1;
    };
    if (data.asserts) |asserts| {
        inputs[input_count] = .{ .path = try sandbox.inputPath(allocator, lang.dir, "asserts.json"), .contents = asserts };
        input_count += 1;
    }

    // Pipes for child stdout/stderr. CLOEXEC is essential: other requests fork
    // concurrently from this multi-threaded process, and without it their
    // sandboxed children would inherit these fds — letting one tenant read
    // (or hold open, stalling EOF for) another tenant's output. dup2 onto 1/2
    // in our own inner child clears CLOEXEC on the copies it needs.
    // `*_write_closed` flips to true once the parent closes its copy of the
    // write end after the fork (which it always does before any further
    // fallible work); the read ends are always closed via the unconditional
    // `defer`s below.
    var stdout_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&stdout_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    var stdout_write_closed = false;
    errdefer {
        if (!stdout_write_closed) _ = linux.close(stdout_pipe[1]);
    }
    defer _ = linux.close(stdout_pipe[0]);

    var stderr_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&stderr_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    var stderr_write_closed = false;
    errdefer {
        if (!stderr_write_closed) _ = linux.close(stderr_pipe[1]);
    }
    defer _ = linux.close(stderr_pipe[0]);

    const plan: sandbox.ChildPlan = .{
        .sandbox = sb,
        .lang = lang_opts,
        .slot = slot,
        .uid = state.uid_base + @as(u32, slot),
        .stdout_r = stdout_pipe[0],
        .stdout_w = stdout_pipe[1],
        .stderr_r = stderr_pipe[0],
        .stderr_w = stderr_pipe[1],
        .input_dir = try sandbox.inputDir(allocator, lang.dir),
        .inputs = inputs[0..input_count],
        .argv = state.runner_cmd.argv_z.ptr,
        .envp = state.child_envp.ptr,
        .timeout_ns = timeout_ns,
        .address_space_max = state.memory_max,
    };
    const oom_kills_before = try sb.beginRun(slot, lang_opts);

    const pid = try sandbox.forkIntoSlot(sb, slot);
    if (pid == 0) sandbox.outerChild(&plan);

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
            var status: i32 = 0;
            while (true) {
                const r = linux.waitpid(pid, &status, 0);
                const e = linux.errno(r);
                if (e != .INTR) break;
            }
        }
        _ = sb.endRun(slot, oom_kills_before);
    }

    const stdout_file: Io.File = .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } };
    const stderr_file: Io.File = .{ .handle = stderr_pipe[0], .flags = .{ .nonblocking = false } };

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stdout.deinit(gpa);
    defer stderr.deinit(gpa);

    var out_truncated = false;
    var err_truncated = false;
    // ReadPipeCtx.allocator is gpa, not the per-request arena: two reader
    // threads call appendSlice concurrently, and ArenaAllocator is not
    // thread-safe. gpa is. The returned stdout/stderr slices are freed by
    // handleRun with gpa (see RunResult contract on runCommandSimple).
    var out_ctx = ReadPipeCtx{
        .file = stdout_file,
        .list = &stdout,
        .allocator = gpa,
        .max_bytes = state.output_max,
        .truncated = &out_truncated,
        .io = io,
    };
    var err_ctx = ReadPipeCtx{
        .file = stderr_file,
        .list = &stderr,
        .allocator = gpa,
        .max_bytes = state.output_max,
        .truncated = &err_truncated,
        .io = io,
    };

    threads[0] = try std.Thread.spawn(.{}, readPipe, .{&out_ctx});
    threads[1] = try std.Thread.spawn(.{}, readPipe, .{&err_ctx});

    var wait_state: ExitWait = .{};
    threads[2] = try std.Thread.spawn(.{}, rawWaiterThread, .{ pid, io, &wait_state });

    var exit_code: ?i32 = null;
    var timed_out = false;
    wait_state.exit_event.waitTimeout(io, .{ .duration = .{ .raw = .fromNanoseconds(@intCast(timeout_ns)), .clock = .awake } }) catch |err| switch (err) {
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
    const oom_killed = sb.endRun(slot, oom_kills_before);

    if (out_truncated or err_truncated) return error.OutputTooLarge;
    if (oom_killed) {
        stderr.appendSlice(gpa, "\nrunner: killed: memory limit (") catch {};
        stderr.appendSlice(gpa, lang_opts.mem_max) catch {};
        stderr.appendSlice(gpa, ") exceeded\n") catch {};
    }

    // Split the toOwnedSlice chain so an OOM on stderr doesn't strand stdout.
    const out_slice = try stdout.toOwnedSlice(gpa);
    errdefer gpa.free(out_slice);
    const err_slice = try stderr.toOwnedSlice(gpa);
    return RunResult{
        .exit_code = exit_code,
        .stdout = out_slice,
        .stderr = err_slice,
    };
}

fn decodeExitCode(status: u32) ?i32 {
    if (status == 0xFFFF_FFFF) return null;
    if (posix.W.IFEXITED(status)) {
        return @intCast(posix.W.EXITSTATUS(status));
    }
    if (posix.W.IFSIGNALED(status)) {
        return 128 + @as(i32, @intCast(@backingInt(posix.W.TERMSIG(status))));
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
        // Once truncated, keep draining without storing: stopping early would
        // leave the child blocked on a full pipe until the timeout fires.
        if (ctx.truncated.*) continue;
        const to_copy = if (ctx.max_bytes == 0) n else @min(n, ctx.max_bytes - ctx.list.items.len);
        // OOM is reported as truncation rather than silently returning a
        // partial (but "successful") output.
        ctx.list.appendSlice(ctx.allocator, buf[0..to_copy]) catch {
            ctx.truncated.* = true;
            continue;
        };
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
