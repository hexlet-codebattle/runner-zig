//! Linux per-request sandbox (used when the runner runs as root on Linux).
//!
//! Isolation model, per request:
//! - Namespaces: mount, pid, ipc, uts, net and cgroup.
//! - Filesystem: the whole root is remounted read-only. The only writable
//!   places are a fresh size-capped tmpfs on /tmp, /dev/shm, and copy-on-write
//!   overlays whose writable layer lives in that /tmp tmpfs:
//!     /sandbox  = request inputs + runner workspace (read-only lower) + skeleton
//!     per-lang cache dirs (e.g. GOCACHE) = image contents (lower) + scratch
//!   Nothing a request writes is visible to any other request, and everything
//!   it wrote disappears with its mount namespace (no cleanup pass).
//! - /dev is a minimal tmpfs (null, zero, full, random, urandom), so host
//!   devices exposed to a privileged pod never reach user code.
//! - Resources: each slot has its own cgroup (memory.max, no swap, pids.max,
//!   OOM kills the whole group). All slots sit under `jobs/`, capped below the
//!   container limit, so user code can never OOM-kill the runner.
//! - Credentials: setgroups([]) + setres[ug]id to the slot UID, no_new_privs,
//!   rlimits, seccomp. Every step fails closed.
//!
//! Everything named `*Child` runs after fork() in a multi-threaded process:
//! raw syscalls only, no allocation, no locks.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Where each request's workspace is mounted, and the child's cwd and HOME.
pub const sandbox_root = "/sandbox";

/// Root-only (0700) tmpfs holding the workspace skeleton and our cgroup2
/// mount. Masked inside the sandbox.
const state_dir = "/run/codebattle-runner";
const skel_dir = state_dir ++ "/skel";
const cgroup_dir = state_dir ++ "/cgroup";

/// Per-request scratch inside the request's /tmp tmpfs: overlay upper/work
/// dirs and the /dev staging dir. 0700 root, so user code cannot touch the
/// overlay layers directly.
const scratch = "/tmp/.runner";
const ws_upper = scratch ++ "/ws/upper";
const ws_work = scratch ++ "/ws/work";
const dev_stage = scratch ++ "/dev";

/// Directories never mirrored into the skeleton (they stay non-writable).
const skeleton_ignore = [_][]const u8{ ".git", "zig-cache", ".zig-cache", "zig-out" };

/// Read-only empty tmpfs mounted over these (when they exist): the runner's
/// own files and orchestrator-provided secrets (e.g. the k8s service-account
/// token, which is world-readable by default).
const masked_paths = [_][*:0]const u8{ "/app", "/run/secrets", "/var/run/secrets", state_dir };

/// Device nodes bind-mounted into the sandbox's private /dev.
const dev_nodes = [_][]const u8{ "null", "zero", "full", "random", "urandom" };

/// Per-slot task limit (threads count). RLIMIT_NPROC is a second layer.
const pids_max = "512";
/// Memory left to the runner when capping `jobs/` below the container limit.
const runner_memory_reserve: u64 = 64 * 1024 * 1024;

pub const Overlay = struct {
    /// Mount point, e.g. "/opt/go/cache".
    target: [:0]u8,
    /// "lowerdir=<target>,upperdir=...,workdir=..."
    opts: [:0]u8,
    /// Dirs created inside the request tmpfs before mounting.
    root: [:0]u8,
    upper: [:0]u8,
    work: [:0]u8,

    fn deinit(self: Overlay, gpa: Allocator) void {
        gpa.free(self.target);
        gpa.free(self.opts);
        gpa.free(self.root);
        gpa.free(self.upper);
        gpa.free(self.work);
    }
};

/// Per-language sandbox settings, resolved once at startup.
pub const LangOpts = struct {
    /// tmpfs options for /tmp, e.g. "size=256m,mode=1777". The workspace and
    /// overlay writes live in this tmpfs too, so `size=` caps all writes.
    tmp_opts: [:0]u8,
    /// Value written to the slot's memory.max, e.g. "512m".
    mem_max: [:0]u8,
    /// Copy-on-write views over image directories the toolchain writes to.
    /// Only paths that exist at startup are kept.
    overlays: []Overlay,

    pub fn init(gpa: Allocator, tmp_size: []const u8, mem_max: []const u8, overlay_paths: []const []const u8) !LangOpts {
        const tmp_opts = try gpa.printSentinel("size={s},mode=1777", .{tmp_size}, 0);
        errdefer gpa.free(tmp_opts);
        const mem = try gpa.dupeSentinel(u8, mem_max, 0);
        errdefer gpa.free(mem);

        var overlays: std.ArrayList(Overlay) = .empty;
        errdefer {
            for (overlays.items) |o| o.deinit(gpa);
            overlays.deinit(gpa);
        }
        for (overlay_paths) |path| {
            if (path.len == 0 or path[0] != '/') return error.OverlayPathNotAbsolute;
            const path_z = try gpa.dupeSentinel(u8, path, 0);
            defer gpa.free(path_z);
            if (linux.errno(linux.access(path_z, posix.F_OK)) != .SUCCESS) continue;

            const i = overlays.items.len;
            const target = try gpa.dupeSentinel(u8, path, 0);
            errdefer gpa.free(target);
            const root = try gpa.printSentinel(scratch ++ "/o{d}", .{i}, 0);
            errdefer gpa.free(root);
            const upper = try gpa.printSentinel(scratch ++ "/o{d}/upper", .{i}, 0);
            errdefer gpa.free(upper);
            const work = try gpa.printSentinel(scratch ++ "/o{d}/work", .{i}, 0);
            errdefer gpa.free(work);
            const opts = try gpa.printSentinel("lowerdir={s},upperdir={s},workdir={s}", .{ path, upper, work }, 0);
            errdefer gpa.free(opts);
            try overlays.append(gpa, .{ .target = target, .opts = opts, .root = root, .upper = upper, .work = work });
        }
        return .{ .tmp_opts = tmp_opts, .mem_max = mem, .overlays = try overlays.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: LangOpts, gpa: Allocator) void {
        gpa.free(self.tmp_opts);
        gpa.free(self.mem_max);
        for (self.overlays) |o| o.deinit(gpa);
        gpa.free(self.overlays);
    }
};

const Slot = struct {
    /// O_PATH fd of the slot's cgroup dir, for clone3(CLONE_INTO_CGROUP).
    dir_fd: i32,
    memory_max: [:0]u8,
    events: [:0]u8,

    fn deinit(self: Slot, gpa: Allocator) void {
        _ = linux.close(self.dir_fd);
        gpa.free(self.memory_max);
        gpa.free(self.events);
    }
};

/// Startup state shared by every request.
pub const Sandbox = struct {
    /// "lowerdir=<skeleton>:<runner cwd>,upperdir=...,workdir=..."
    workspace_opts: [:0]u8,
    slots: []Slot,

    /// One-time setup. Any failure is fatal: the runner must not serve
    /// requests with weaker isolation than documented.
    pub fn init(gpa: Allocator, io: Io, slot_count: usize) !Sandbox {
        // Mount targets may be missing when the binary is dropped into a
        // foreign base image (e.g. python:alpine).
        try mkdirIfMissing(sandbox_root, 0o755);
        try mkdirIfMissing("/app", 0o755);
        try mkdirIfMissing("/run", 0o755);
        try mkdirIfMissing(state_dir, 0o700);
        try check(linux.mount("runner-state", state_dir, "tmpfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, @intFromPtr("mode=0700,size=64m")), error.StateMountFailed);

        var cwd_buf: [posix.PATH_MAX]u8 = undefined;
        const cwd_rc = linux.getcwd(&cwd_buf, cwd_buf.len);
        if (linux.errno(cwd_rc) != .SUCCESS) return error.GetCwdFailed;
        const template = std.mem.sliceTo(&cwd_buf, 0);
        if (std.mem.indexOfAny(u8, template, ",:") != null) return error.UnsupportedWorkspacePath;

        try buildSkeleton(gpa, io, template);
        const workspace_opts = try gpa.printSentinel("lowerdir=" ++ skel_dir ++ ":{s},upperdir=" ++ ws_upper ++ ",workdir=" ++ ws_work, .{template}, 0);
        errdefer gpa.free(workspace_opts);

        const slots = try setupCgroups(gpa, slot_count);
        errdefer {
            for (slots) |s| s.deinit(gpa);
            gpa.free(slots);
        }

        // Extra layer on top of the cgroup layout: make a node-level OOM
        // kill prefer user code (children reset to 1000) over the runner.
        // Lowering needs CAP_SYS_RESOURCE, which unprivileged containers lack.
        writeFile("/proc/self/oom_score_adj", "-900") catch
            std.log.warn("could not lower runner oom_score_adj (needs CAP_SYS_RESOURCE); relying on cgroup limits", .{});

        std.log.info("sandbox ready: workspace={s} slots={d}", .{ template, slot_count });
        return .{ .workspace_opts = workspace_opts, .slots = slots };
    }

    pub fn deinit(self: Sandbox, gpa: Allocator) void {
        gpa.free(self.workspace_opts);
        for (self.slots) |s| s.deinit(gpa);
        gpa.free(self.slots);
    }

    /// Parent side, before fork: apply the language's memory limit to the
    /// slot and snapshot its OOM-kill counter.
    pub fn beginRun(self: *const Sandbox, slot: u6, lang: *const LangOpts) !u64 {
        const s = self.slots[slot];
        try writeFile(s.memory_max, lang.mem_max);
        return readOomKills(s.events);
    }

    /// Parent side, after the sandbox's init process was reaped: report
    /// whether the run hit its memory limit. No cgroup.kill here: nothing can
    /// outlive the run (the pid namespace dies with its init), and on some
    /// kernels (seen on 6.12) a cgroup that was ever cgroup.kill'ed SIGKILLs
    /// every later CLONE_INTO_CGROUP child (kill_seq mismatch).
    pub fn endRun(self: *const Sandbox, slot: u6, oom_kills_before: u64) bool {
        const s = self.slots[slot];
        const after = readOomKills(s.events) catch return false;
        return after > oom_kills_before;
    }
};

/// fork() straight into the slot's cgroup. Writing a pid to cgroup.procs
/// instead migrates a running task, which takes cgroup_threadgroup_rwsem for
/// writing and waits out an RCU grace period: ~20 ms on a third of requests.
/// Returns the child's pid in the parent and 0 in the child, like fork().
pub fn forkIntoSlot(sb: *const Sandbox, slot: u6) !posix.pid_t {
    var args: CloneArgs = .{
        .flags = linux.CLONE.INTO_CGROUP,
        .exit_signal = @backingInt(linux.SIG.CHLD),
        .cgroup = @intCast(sb.slots[slot].dir_fd),
    };
    const rc = linux.syscall2(.clone3, @intFromPtr(&args), @sizeOf(CloneArgs));
    if (linux.errno(rc) != .SUCCESS) {
        std.log.err("clone3(CLONE_INTO_CGROUP) failed: errno={d}", .{@backingInt(linux.errno(rc))});
        return error.ForkFailed;
    }
    return @bitCast(@as(u32, @truncate(rc)));
}

const CloneArgs = extern struct {
    flags: u64 = 0,
    pidfd: u64 = 0,
    child_tid: u64 = 0,
    parent_tid: u64 = 0,
    exit_signal: u64 = 0,
    stack: u64 = 0,
    stack_size: u64 = 0,
    tls: u64 = 0,
    set_tid: u64 = 0,
    set_tid_size: u64 = 0,
    cgroup: u64 = 0,
};

pub const Input = struct {
    path: [*:0]const u8,
    contents: []const u8,
};

/// Everything the forked children need, prepared before fork().
pub const ChildPlan = struct {
    sandbox: *const Sandbox,
    lang: *const LangOpts,
    slot: u6,
    uid: u32,
    /// Pipe ends: the children write into *_w; *_r belong to the parent.
    stdout_r: i32,
    stdout_w: i32,
    stderr_r: i32,
    stderr_w: i32,
    /// `ws_upper/<lang dir>`, created before writing `inputs`.
    input_dir: [*:0]const u8,
    inputs: []const Input,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    timeout_ns: u64,
    /// RLIMIT_AS bytes; 0 = unset.
    address_space_max: u64,
};

/// Builds `ws_upper/<dir>` and `ws_upper/<dir>/<name>` paths (arena-owned).
pub fn inputDir(arena: Allocator, dir: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, dir, '/') != null) return error.NestedLangDir;
    return arena.printSentinel(ws_upper ++ "/{s}", .{dir}, 0);
}

pub fn inputPath(arena: Allocator, dir: []const u8, name: []const u8) ![:0]u8 {
    return arena.printSentinel(ws_upper ++ "/{s}/{s}", .{ dir, name }, 0);
}

// --- post-fork -------------------------------------------------------------

/// The sandbox's outer child, already in the slot cgroup (forkIntoSlot):
/// enters fresh namespaces, builds the mount view, then forks the inner child (PID 1 of
/// the new pid namespace stays root only to wait for it).
pub fn outerChild(plan: *const ChildPlan) noreturn {
    const err_fd = plan.stderr_w;
    _ = linux.close(plan.stdout_r);
    _ = linux.close(plan.stderr_r);
    _ = linux.setpgid(0, 0);

    writeOrDie(err_fd, "/proc/self/oom_score_adj", "1000", "oom_score_adj");

    const unshare_flags = linux.CLONE.NEWNS | linux.CLONE.NEWPID | linux.CLONE.NEWIPC |
        linux.CLONE.NEWUTS | linux.CLONE.NEWNET | linux.CLONE.NEWCGROUP;
    checkChild(err_fd, linux.unshare(unshare_flags), "unshare");
    // Denied by Docker's default AppArmor profile even with CAP_SYS_ADMIN;
    // operators must run with `--security-opt apparmor=unconfined`.
    checkChild(err_fd, linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0), "ms_private remount /");
    setupMountsChild(plan);

    const child_rc = linux.fork();
    checkChild(err_fd, child_rc, "fork");
    const child_pid: posix.pid_t = @bitCast(@as(u32, @truncate(child_rc)));
    if (child_pid == 0) innerChild(plan);

    var status: i32 = 0;
    while (true) {
        const e = linux.errno(linux.waitpid(child_pid, &status, 0));
        if (e == .SUCCESS) break;
        if (e != .INTR) fatal(err_fd, "waitpid inner", 125);
    }
    const s: u32 = @bitCast(status);
    const code: u8 = if (posix.W.IFEXITED(s))
        posix.W.EXITSTATUS(s)
    else if (posix.W.IFSIGNALED(s))
        @intCast(@min(255, 128 + @as(u32, @backingInt(posix.W.TERMSIG(s)))))
    else
        255;
    linux.exit(code);
}

fn setupMountsChild(plan: *const ChildPlan) void {
    const fd = plan.stderr_w;
    const MS = linux.MS;

    // 1. Everything inherited becomes read-only and nosuid. Mounts created
    //    below are new and therefore writable where we want them to be.
    const attr = MountAttr{ .attr_set = MOUNT_ATTR_RDONLY | MOUNT_ATTR_NOSUID };
    checkChild(fd, linux.syscall5(
        .mount_setattr,
        @bitCast(@as(isize, linux.AT.FDCWD)),
        @intFromPtr("/"),
        AT_RECURSIVE,
        @intFromPtr(&attr),
        @sizeOf(MountAttr),
    ), "mount_setattr ro /");

    // 2. Per-request /tmp. Its `size=` bounds every write the request makes:
    //    /tmp itself, the workspace upper layer and the cache overlays.
    checkChild(fd, linux.mount("tmpfs", "/tmp", "tmpfs", MS.NOSUID | MS.NODEV, @intFromPtr(plan.lang.tmp_opts.ptr)), "mount /tmp");
    mkdirChild(fd, scratch, 0o700);
    mkdirChild(fd, scratch ++ "/ws", 0o700);
    // The merged root dir takes the upper dir's attributes: keep it writable.
    mkdirChild(fd, ws_upper, 0o777);
    mkdirChild(fd, ws_work, 0o700);

    // 3. Request inputs go straight into the workspace's upper layer.
    const dir_rc = linux.mkdir(plan.input_dir, 0o777);
    if (linux.errno(dir_rc) != .SUCCESS and linux.errno(dir_rc) != .EXIST) checkChild(fd, dir_rc, "mkdir input dir");
    for (plan.inputs) |input| writeNewFileChild(fd, input.path, input.contents);

    // 4. /sandbox: inputs + skeleton (makes template dirs writable) + the
    //    runner's workspace as the read-only bottom layer. No per-request copy.
    checkChild(fd, linux.mount("overlay", sandbox_root, "overlay", MS.NOSUID | MS.NODEV, @intFromPtr(plan.sandbox.workspace_opts.ptr)), "mount workspace overlay");

    // 5. Copy-on-write views over image dirs the toolchain writes to
    //    (GOCACHE, CARGO_TARGET_DIR, ...): pre-warmed contents stay shared
    //    and read-only; this request's writes land in its own /tmp.
    for (plan.lang.overlays) |o| {
        mkdirChild(fd, o.root, 0o700);
        mkdirChild(fd, o.upper, 0o777);
        mkdirChild(fd, o.work, 0o700);
        checkChild(fd, linux.mount("overlay", o.target, "overlay", MS.NOSUID | MS.NODEV, @intFromPtr(o.opts.ptr)), "mount cache overlay");
    }

    // 6. Minimal /dev, staged in the request tmpfs then moved into place.
    mkdirChild(fd, dev_stage, 0o755);
    checkChild(fd, linux.mount("tmpfs", dev_stage, "tmpfs", MS.NOSUID | MS.NOEXEC, @intFromPtr("size=64k,mode=0755")), "mount /dev tmpfs");
    inline for (dev_nodes) |name| {
        const node = dev_stage ++ "/" ++ name;
        const created = linux.open(node, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o666);
        checkChild(fd, created, "create /dev node");
        _ = linux.close(@bitCast(@as(u32, @truncate(created))));
        checkChild(fd, linux.mount("/dev/" ++ name, node, null, MS.BIND, 0), "bind /dev node");
    }
    symlinkChild(fd, "/proc/self/fd", dev_stage ++ "/fd");
    symlinkChild(fd, "/proc/self/fd/0", dev_stage ++ "/stdin");
    symlinkChild(fd, "/proc/self/fd/1", dev_stage ++ "/stdout");
    symlinkChild(fd, "/proc/self/fd/2", dev_stage ++ "/stderr");
    mkdirChild(fd, dev_stage ++ "/shm", 0o1777);
    checkChild(fd, linux.mount(dev_stage, "/dev", null, MS.MOVE, 0), "move /dev");
    checkChild(fd, linux.mount("tmpfs", "/dev/shm", "tmpfs", MS.NOSUID | MS.NODEV, @intFromPtr("size=64m,mode=1777")), "mount /dev/shm");
    checkChild(fd, linux.mount(null, "/dev", null, MS.REMOUNT | MS.BIND | MS.RDONLY | MS.NOSUID | MS.NOEXEC, 0), "remount /dev ro");

    // 7. Hide the runner's own state and orchestrator secrets.
    for (masked_paths) |path| {
        const rc = linux.mount("tmpfs", path, "tmpfs", MS.RDONLY | MS.NOSUID | MS.NODEV | MS.NOEXEC, @intFromPtr("size=4k,mode=0555"));
        if (linux.errno(rc) != .NOENT) checkChild(fd, rc, "mask path");
    }

    // 8. procfs for the new pid namespace (otherwise the host's view leaks).
    checkChild(fd, linux.mount("proc", "/proc", "proc", MS.NOSUID | MS.NODEV | MS.NOEXEC, 0), "mount /proc");

    // 9. cgroupfs rooted at the slot cgroup (new cgroup namespace), so JVM,
    //    .NET, Go and BEAM size themselves from the request's own limits.
    //    Mounting cgroup2 straight over the inherited cgroup2 mount is EBUSY
    //    (same superblock), and umount2 would cost an RCU grace period
    //    (~20 ms) per request, so stack it on a throwaway tmpfs instead.
    const cg_base = linux.mount("tmpfs", "/sys/fs/cgroup", "tmpfs", MS.RDONLY | MS.NOSUID | MS.NODEV | MS.NOEXEC, @intFromPtr("size=4k,mode=0555"));
    if (linux.errno(cg_base) != .NOENT) {
        checkChild(fd, cg_base, "mount /sys/fs/cgroup base");
        checkChild(fd, linux.mount("cgroup2", "/sys/fs/cgroup", "cgroup2", MS.RDONLY | MS.NOSUID | MS.NODEV | MS.NOEXEC, 0), "mount /sys/fs/cgroup");
    }
}

fn innerChild(plan: *const ChildPlan) noreturn {
    const fd = plan.stderr_w;
    checkChild(fd, linux.dup2(plan.stdout_w, 1), "dup2 stdout");
    checkChild(fd, linux.dup2(plan.stderr_w, 2), "dup2 stderr");
    const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    checkChild(2, devnull, "open /dev/null");
    const dn_fd: i32 = @bitCast(@as(u32, @truncate(devnull)));
    checkChild(2, linux.dup2(dn_fd, 0), "dup2 stdin");
    // Drop every other inherited fd (client sockets, the listener, other
    // requests' pipes) before user code runs. Our pipes are CLOEXEC too.
    _ = linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });

    checkChild(2, linux.chdir(sandbox_root), "chdir /sandbox");
    dropPrivilegesChild(plan.uid);
    checkChild(2, linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0), "no_new_privs");
    applyRlimitsChild(plan.timeout_ns, plan.address_space_max);
    checkChild(2, applySeccompFilter(), "seccomp");

    _ = linux.execve(plan.argv[0].?, plan.argv, plan.envp);
    fatal(2, "execve /bin/sh", 124);
}

/// Switch every credential to the slot UID/GID or die. setgroups(0) matters:
/// without it the child kept root's supplementary groups (in the alpine image:
/// root, disk, adm, wheel, ...), and in a privileged pod `disk` reaches the
/// host's block devices.
fn dropPrivilegesChild(id: posix.uid_t) void {
    const no_groups = [_]linux.gid_t{};
    checkChild(2, linux.setgroups(0, &no_groups), "setgroups");
    checkChild(2, linux.setresgid(id, id, id), "setresgid");
    checkChild(2, linux.setresuid(id, id, id), "setresuid");
    // Belt and braces: never exec user code with any root credential left.
    var r: linux.uid_t = undefined;
    var e: linux.uid_t = undefined;
    var sv: linux.uid_t = undefined;
    checkChild(2, linux.getresuid(&r, &e, &sv), "getresuid");
    if (r == 0 or e == 0 or sv == 0) fatal(2, "uid check", 132);
    const ngroups = linux.getgroups(0, null);
    if (linux.errno(ngroups) != .SUCCESS or ngroups != 0) fatal(2, "groups check", 132);
}

fn applyRlimitsChild(timeout_ns: u64, address_space_max: u64) void {
    const cpu_seconds: u64 = @max(1, @divTrunc(timeout_ns +| (std.time.ns_per_s - 1), std.time.ns_per_s));
    setRlimitChild(.CPU, cpu_seconds);
    setRlimitChild(.NOFILE, 256);
    setRlimitChild(.NPROC, 256);
    setRlimitChild(.CORE, 0);
    // RLIMIT_AS caps virtual address space, not RSS; opt-in via env because
    // JVM, .NET and Go reserve huge VAS upfront. The cgroup is the real limit.
    if (address_space_max != 0) setRlimitChild(.AS, address_space_max);
}

fn setRlimitChild(resource: posix.rlimit_resource, value: u64) void {
    posix.setrlimit(resource, .{ .cur = value, .max = value }) catch fatal(2, "setrlimit", 133);
}

fn mkdirChild(fd: i32, path: [*:0]const u8, mode: linux.mode_t) void {
    checkChild(fd, linux.mkdir(path, mode), "mkdir");
}

fn symlinkChild(fd: i32, target: [*:0]const u8, path: [*:0]const u8) void {
    checkChild(fd, linux.symlink(target, path), "symlink");
}

fn writeNewFileChild(fd: i32, path: [*:0]const u8, contents: []const u8) void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o666);
    checkChild(fd, rc, "create input file");
    const file: i32 = @bitCast(@as(u32, @truncate(rc)));
    var written: usize = 0;
    while (written < contents.len) {
        const n = linux.write(file, contents[written..].ptr, contents.len - written);
        switch (linux.errno(n)) {
            .SUCCESS => written += n,
            .INTR => {},
            else => |e| fatalErrno(fd, "write input file", e, 126),
        }
    }
    _ = linux.close(file);
}

fn writeOrDie(fd: i32, path: [*:0]const u8, data: []const u8, tag: []const u8) void {
    writeFile(path, data) catch fatal(fd, tag, 126);
}

fn checkChild(fd: i32, rc: usize, tag: []const u8) void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) fatalErrno(fd, tag, e, 126);
}

/// Write a short tag to `fd`, then exit with `code`. Async-signal-safe.
fn fatal(fd: i32, tag: []const u8, code: u8) noreturn {
    const prefix: []const u8 = "sandbox: ";
    _ = linux.write(fd, prefix.ptr, prefix.len);
    _ = linux.write(fd, tag.ptr, tag.len);
    _ = linux.write(fd, "\n", 1);
    linux.exit(code);
}

fn fatalErrno(fd: i32, tag: []const u8, err: linux.E, code: u8) noreturn {
    const prefix: []const u8 = "sandbox: ";
    const sep: []const u8 = " errno=";
    _ = linux.write(fd, prefix.ptr, prefix.len);
    _ = linux.write(fd, tag.ptr, tag.len);
    _ = linux.write(fd, sep.ptr, sep.len);
    var buf: [16]u8 = undefined;
    const n = std.fmt.printInt(&buf, @backingInt(err), 10, .lower, .{});
    _ = linux.write(fd, &buf, n);
    _ = linux.write(fd, "\n", 1);
    linux.exit(code);
}

// --- mount_setattr ---------------------------------------------------------

const MountAttr = extern struct {
    attr_set: u64 = 0,
    attr_clr: u64 = 0,
    propagation: u64 = 0,
    userns_fd: u64 = 0,
};
const MOUNT_ATTR_RDONLY: u64 = 0x1;
const MOUNT_ATTR_NOSUID: u64 = 0x2;
const AT_RECURSIVE: usize = 0x8000;

// --- startup helpers -------------------------------------------------------

/// Mirrors every directory of the runner's workspace (`template`) as an empty
/// 0777 dir under `skel_dir`. As the middle overlay layer it gives merged
/// directories the same "writable by the slot UID" mode the old per-request
/// copy produced, while file contents still come from the template.
fn buildSkeleton(gpa: Allocator, io: Io, template: []const u8) !void {
    try mkdirIfMissing(skel_dir, 0o777);
    var skel = try Io.Dir.openDirAbsolute(io, skel_dir, .{});
    defer skel.close(io);
    var src = try Io.Dir.openDirAbsolute(io, template, .{ .iterate = true });
    defer src.close(io);

    var walker = try src.walkSelectively(gpa);
    defer walker.deinit();
    var dirs: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (isIgnored(entry.basename)) continue;
        try skel.createDir(io, entry.path, .fromMode(0o777));
        dirs += 1;
        try walker.enter(io, entry);
    }
    std.log.info("workspace skeleton: {d} dirs", .{dirs});
}

fn isIgnored(name: []const u8) bool {
    for (skeleton_ignore) |item| {
        if (std.mem.eql(u8, name, item)) return true;
    }
    return false;
}

/// cgroup v2 layout under our private mount of the container's cgroup:
///   <root>/runner      the runner process itself
///   <root>/jobs        memory.max = container limit - reserve
///   <root>/jobs/slot-N one per slot; memory.max set per request
fn setupCgroups(gpa: Allocator, slot_count: usize) ![]Slot {
    try mkdirIfMissing(cgroup_dir, 0o700);
    check(linux.mount("cgroup2", cgroup_dir, "cgroup2", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, 0), error.CgroupMountFailed) catch |err| {
        std.log.err("cannot mount cgroup2 (cgroup v2 + CAP_SYS_ADMIN required)", .{});
        return err;
    };

    var buf: [4096]u8 = undefined;
    const controllers = try readFile(cgroup_dir ++ "/cgroup.controllers", &buf);
    for ([_][]const u8{ "memory", "pids" }) |c| {
        if (!hasWord(controllers, c)) {
            std.log.err("cgroup controller '{s}' unavailable (have: {s})", .{ c, std.mem.trim(u8, controllers, "\n") });
            return error.CgroupControllerMissing;
        }
    }
    const enable = if (hasWord(controllers, "cpu")) "+memory +pids +cpu" else "+memory +pids";

    // cgroup v2 forbids enabling controllers for children of a cgroup that
    // has processes, so first move everything (us included) into runner/.
    try mkdirIfMissing(cgroup_dir ++ "/runner", 0o755);
    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        const procs = try readFile(cgroup_dir ++ "/cgroup.procs", &buf);
        var it = std.mem.tokenizeScalar(u8, procs, '\n');
        var moved = false;
        while (it.next()) |pid| {
            moved = true;
            writeFile(cgroup_dir ++ "/runner/cgroup.procs", pid) catch {}; // ESRCH: exited
        }
        if (!moved) break;
    }
    try writeFileLogged(cgroup_dir ++ "/cgroup.subtree_control", enable);
    try mkdirIfMissing(cgroup_dir ++ "/jobs", 0o755);
    try writeFileLogged(cgroup_dir ++ "/jobs/cgroup.subtree_control", enable);

    const limit_text = std.mem.trim(u8, try readFile(cgroup_dir ++ "/memory.max", &buf), " \n");
    if (std.fmt.parseUnsigned(u64, limit_text, 10)) |limit| {
        const jobs_max = limit - @min(runner_memory_reserve, limit / 4);
        var num: [32]u8 = undefined;
        try writeFileLogged(cgroup_dir ++ "/jobs/memory.max", try std.fmt.bufPrint(&num, "{d}", .{jobs_max}));
    } else |_| {} // "max": no container limit to stay under

    var slots: std.ArrayList(Slot) = .empty;
    errdefer {
        for (slots.items) |s| s.deinit(gpa);
        slots.deinit(gpa);
    }
    for (0..slot_count) |i| {
        const dir = try gpa.printSentinel(cgroup_dir ++ "/jobs/slot-{d}", .{i}, 0);
        defer gpa.free(dir);
        try mkdirIfMissing(dir, 0o755);
        try writeAt(gpa, dir, "pids.max", pids_max);
        try writeAt(gpa, dir, "memory.oom.group", "1");
        writeAt(gpa, dir, "memory.swap.max", "0") catch |err| switch (err) {
            error.FileNotFound => {}, // kernel without swap accounting
            else => return err,
        };

        const dir_rc = linux.open(dir, .{ .ACCMODE = .RDONLY, .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0);
        try check(dir_rc, error.CgroupOpenFailed);
        const dir_fd: i32 = @bitCast(@as(u32, @truncate(dir_rc)));
        errdefer _ = linux.close(dir_fd);
        const memory_max = try gpa.printSentinel("{s}/memory.max", .{dir}, 0);
        errdefer gpa.free(memory_max);
        const events = try gpa.printSentinel("{s}/memory.events", .{dir}, 0);
        errdefer gpa.free(events);
        try slots.append(gpa, .{ .dir_fd = dir_fd, .memory_max = memory_max, .events = events });
    }
    return slots.toOwnedSlice(gpa);
}

fn writeAt(gpa: Allocator, dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try gpa.printSentinel("{s}/{s}", .{ dir, name }, 0);
    defer gpa.free(path);
    if (std.mem.eql(u8, name, "memory.swap.max")) return writeFile(path, data);
    try writeFileLogged(path, data);
}

fn readOomKills(events_path: [*:0]const u8) !u64 {
    var buf: [512]u8 = undefined;
    const text = try readFile(events_path, &buf);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "oom_kill ")) {
            return std.fmt.parseUnsigned(u64, line["oom_kill ".len..], 10) catch 0;
        }
    }
    return 0;
}

fn hasWord(haystack: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, haystack, " \n");
    while (it.next()) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn mkdirIfMissing(path: [*:0]const u8, mode: linux.mode_t) !void {
    const e = linux.errno(linux.mkdir(path, mode));
    if (e != .SUCCESS and e != .EXIST) {
        std.log.err("mkdir {s} failed: errno={d}", .{ path, @backingInt(e) });
        return error.MkdirFailed;
    }
}

fn check(rc: usize, err: anyerror) anyerror!void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        std.log.err("{s}: errno={d}", .{ @errorName(err), @backingInt(e) });
        return err;
    }
}

/// Raw-syscall file write: safe both at startup and post-fork.
fn writeFile(path: [*:0]const u8, data: []const u8) error{ FileNotFound, WriteFailed }!void {
    const e = writeFileErrno(path, data);
    return switch (e) {
        .SUCCESS => {},
        .NOENT => error.FileNotFound,
        else => error.WriteFailed,
    };
}

fn writeFileErrno(path: [*:0]const u8, data: []const u8) linux.E {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return linux.errno(rc);
    const fd: i32 = @bitCast(@as(u32, @truncate(rc)));
    defer _ = linux.close(fd);
    while (true) {
        const n = linux.write(fd, data.ptr, data.len);
        switch (linux.errno(n)) {
            .SUCCESS => return if (n == data.len) .SUCCESS else .IO,
            .INTR => continue,
            else => |e| return e,
        }
    }
}

/// Startup-only: like writeFile, but logs which file failed and why.
fn writeFileLogged(path: [*:0]const u8, data: []const u8) error{ FileNotFound, WriteFailed }!void {
    const e = writeFileErrno(path, data);
    if (e == .SUCCESS) return;
    std.log.err("write {s} <- \"{s}\" failed: errno={d}", .{ path, data, @backingInt(e) });
    return if (e == .NOENT) error.FileNotFound else error.WriteFailed;
}

fn readFile(path: [*:0]const u8, buf: []u8) error{ReadFailed}![]const u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
    const fd: i32 = @bitCast(@as(u32, @truncate(rc)));
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = linux.read(fd, buf[len..].ptr, buf.len - len);
        switch (linux.errno(n)) {
            .SUCCESS => if (n == 0) break else {
                len += n;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return buf[0..len];
}

// --- seccomp ---------------------------------------------------------------
// Classic BPF program installed in the inner child after PR_SET_NO_NEW_PRIVS.
// Built at comptime from std.os.linux.SYS so syscall numbers match the target
// arch; syscalls a target lacks (e.g. kexec_file_load on arm64) are skipped.

const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

const BPF_LD: u16 = 0x00;
const BPF_JMP: u16 = 0x05;
const BPF_RET: u16 = 0x06;
const BPF_W: u16 = 0x00;
const BPF_ABS: u16 = 0x20;
const BPF_JEQ: u16 = 0x10;
const BPF_JGE: u16 = 0x30;
const BPF_JSET: u16 = 0x40;
const BPF_K: u16 = 0x00;

inline fn bpfStmt(code: u16, k: u32) SockFilter {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}
inline fn bpfJump(code: u16, k: u32, jt: u8, jf: u8) SockFilter {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

// AUDIT_ARCH_* from <linux/audit.h>: (EM_machine | __AUDIT_ARCH_64BIT | __AUDIT_ARCH_LE).
const AUDIT_ARCH_X86_64: u32 = 0xC000003E;
const AUDIT_ARCH_AARCH64: u32 = 0xC00000B7;

const target_audit_arch: u32 = switch (builtin.cpu.arch) {
    .x86_64 => AUDIT_ARCH_X86_64,
    .aarch64 => AUDIT_ARCH_AARCH64,
    else => 0, // seccomp filter only installed on Linux x86_64/aarch64
};

// Syscalls denied with RET_KILL_PROCESS: container-escape / kernel-manipulation
// primitives that no legitimate user program should attempt. Hitting one is a
// strong signal of a compromise attempt, so we drop the whole process. The
// new mount API (open_tree .. mount_setattr) has the same power as mount(2).
// `prctl` is intentionally allowed — language runtimes use it and
// PR_SET_SECCOMP can only narrow.
const denied_kill_syscall_names = [_][]const u8{
    "mount",             "umount2",           "pivot_root",      "chroot",
    "unshare",           "setns",             "seccomp",         "bpf",
    "keyctl",            "add_key",           "request_key",     "init_module",
    "finit_module",      "delete_module",     "kexec_load",      "kexec_file_load",
    "swapon",            "swapoff",           "reboot",          "acct",
    "quotactl",          "quotactl_fd",       "perf_event_open", "ptrace",
    "process_vm_readv",  "process_vm_writev", "process_madvise", "pidfd_getfd",
    "kcmp",              "userfaultfd",       "iopl",            "ioperm",
    "name_to_handle_at", "open_by_handle_at", "lookup_dcookie",  "nfsservctl",
    "personality",       "uselib",            "vhangup",         "open_tree",
    "open_tree_attr",    "move_mount",        "fsopen",          "fsconfig",
    "fsmount",           "fspick",            "mount_setattr",
};

/// Syscalls denied with RET_ERRNO: runtimes probe for these and fall back
/// gracefully when they fail, so KILL would break them.
/// - io_uring: Node 25's libuv 1.51 calls `io_uring_setup` at init regardless
///   of UV_USE_IO_URING; EPERM makes it pick epoll instead.
/// - clone3: its flags live behind a pointer seccomp cannot inspect, so we
///   cannot filter CLONE_NEW* there. ENOSYS makes glibc/musl/Go/JVM fall back
///   to clone(2), whose flags we can check (same approach as Docker's
///   default profile).
const DeniedErrno = struct { name: []const u8, errno: linux.E };
const denied_errno_syscalls = [_]DeniedErrno{
    .{ .name = "io_uring_setup", .errno = .PERM },
    .{ .name = "io_uring_enter", .errno = .PERM },
    .{ .name = "io_uring_register", .errno = .PERM },
    .{ .name = "clone3", .errno = .NOSYS },
};

/// clone(2) with any of these is refused with EPERM. Creating a user
/// namespace hands user code a full set of capabilities over a fresh
/// namespace tree, the starting point of most kernel privilege escalations;
/// unshare(2) is already killed above, but clone(2) reaches the same place.
const clone_namespace_flags: u32 = linux.CLONE.NEWNS | linux.CLONE.NEWCGROUP | linux.CLONE.NEWUTS |
    linux.CLONE.NEWIPC | linux.CLONE.NEWUSER | linux.CLONE.NEWPID | linux.CLONE.NEWNET;

/// x32 syscalls run under AUDIT_ARCH_X86_64 with this bit set in `nr`, so a
/// per-number denylist misses them (x32 `mount` is not `mount`). Kill them all.
const x32_syscall_bit: u32 = 0x4000_0000;

const denied_kill_syscall_nrs: []const u32 = blk: {
    @setEvalBranchQuota(20_000);
    var list: []const u32 = &.{};
    for (denied_kill_syscall_names) |name| {
        if (@hasField(linux.SYS, name)) {
            list = list ++ &[_]u32{@backingInt(@field(linux.SYS, name))};
        }
    }
    break :blk list;
};

const DeniedErrnoNr = struct { nr: u32, errno: u16 };
const denied_errno_syscall_nrs: []const DeniedErrnoNr = blk: {
    @setEvalBranchQuota(20_000);
    var list: []const DeniedErrnoNr = &.{};
    for (denied_errno_syscalls) |d| {
        if (@hasField(linux.SYS, d.name)) {
            list = list ++ &[_]DeniedErrnoNr{.{ .nr = @backingInt(@field(linux.SYS, d.name)), .errno = @backingInt(d.errno) }};
        }
    }
    break :blk list;
};

const check_x32 = builtin.cpu.arch == .x86_64;

const seccomp_program_len: usize = 4 + (if (check_x32) 2 else 0) + denied_kill_syscall_nrs.len * 2 +
    denied_errno_syscall_nrs.len * 2 + 5;

const seccomp_program: [seccomp_program_len]SockFilter = blk: {
    const arch_offset: u32 = @offsetOf(linux.SECCOMP.data, "arch");
    const nr_offset: u32 = @offsetOf(linux.SECCOMP.data, "nr");
    // Low 32 bits of args[0] (little-endian targets only: x86_64, aarch64).
    const arg0_offset: u32 = @offsetOf(linux.SECCOMP.data, "arg0");
    const kill = linux.SECCOMP.RET.KILL_PROCESS;
    var prog: [seccomp_program_len]SockFilter = undefined;
    // [0] load arch
    prog[0] = bpfStmt(BPF_LD | BPF_W | BPF_ABS, arch_offset);
    // [1] arch match? jt=1 jumps over the KILL at [2] (to LD nr at [3]).
    prog[1] = bpfJump(BPF_JMP | BPF_JEQ | BPF_K, target_audit_arch, 1, 0);
    // [2] arch mismatch → kill (blocks 32-bit-compat syscall confusion).
    prog[2] = bpfStmt(BPF_RET | BPF_K, kill);
    // [3] load syscall number
    prog[3] = bpfStmt(BPF_LD | BPF_W | BPF_ABS, nr_offset);
    var idx: usize = 4;
    if (check_x32) {
        prog[idx] = bpfJump(BPF_JMP | BPF_JGE | BPF_K, x32_syscall_bit, 0, 1);
        prog[idx + 1] = bpfStmt(BPF_RET | BPF_K, kill);
        idx += 2;
    }
    for (denied_kill_syscall_nrs) |nr| {
        // jt=0 (fall through to RET on match), jf=1 (skip RET on miss).
        prog[idx] = bpfJump(BPF_JMP | BPF_JEQ | BPF_K, nr, 0, 1);
        prog[idx + 1] = bpfStmt(BPF_RET | BPF_K, kill);
        idx += 2;
    }
    for (denied_errno_syscall_nrs) |d| {
        prog[idx] = bpfJump(BPF_JMP | BPF_JEQ | BPF_K, d.nr, 0, 1);
        // The low 16 bits of an ERRNO verdict are returned as errno.
        prog[idx + 1] = bpfStmt(BPF_RET | BPF_K, linux.SECCOMP.RET.ERRNO | @as(u32, d.errno));
        idx += 2;
    }
    // clone(flags, ...): EPERM if any namespace flag is set, else allow.
    prog[idx] = bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @backingInt(linux.SYS.clone), 0, 3);
    prog[idx + 1] = bpfStmt(BPF_LD | BPF_W | BPF_ABS, arg0_offset);
    prog[idx + 2] = bpfJump(BPF_JMP | BPF_JSET | BPF_K, clone_namespace_flags, 0, 1);
    prog[idx + 3] = bpfStmt(BPF_RET | BPF_K, linux.SECCOMP.RET.ERRNO | @as(u32, @backingInt(linux.E.PERM)));
    prog[idx + 4] = bpfStmt(BPF_RET | BPF_K, linux.SECCOMP.RET.ALLOW);
    idx += 5;
    if (idx != prog.len) @compileError("seccomp program length mismatch");
    break :blk prog;
};

/// Installs the seccomp filter on the current task. Must be called after
/// PR_SET_NO_NEW_PRIVS=1 (so an unprivileged uid can install it) and before
/// execve.
fn applySeccompFilter() usize {
    const fprog = SockFprog{
        .len = @intCast(seccomp_program.len),
        .filter = &seccomp_program,
    };
    return linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &fprog);
}
