# Code Execution HTTP Service

## Overview
This service accepts source code and optional test/checker data over HTTP, executes the code in a temporary workspace copy, and returns the execution result. It is designed to be fast, stateless, and container-friendly.

## HTTP API

### `POST /run`
Execute user code.

Request JSON:
- `timeout` (optional string): Execution limit, e.g. `"30s"`. Defaults to 30 seconds.
- `solution_text` (string): Source code to run.
- `lang_slug` (string): Language identifier. Supported values:
  - `clojure`, `cpp`, `csharp`, `dart`, `dlang`, `elixir`, `golang`, `haskell`, `java`, `js`, `kotlin`, `php`, `python`, `ruby`, `rust`, `swift`, `ts`, `zig`
- `asserts` (optional string): JSON test data, stored as `asserts.json`.
- `checker_text` (optional string): Checker code. Required for:
  - `cpp`, `csharp`, `dart`, `java`, `golang`, `haskell`, `kotlin`, `rust`, `swift`, `zig`

Response JSON:
- `exit_code` (integer or null): Process exit code, if available.
- `stdout` (string): Captured standard output.
- `stderr` (string): Captured standard error.

### `GET /health`
Returns HTTP 200 when the service is ready.

### `POST /shutdown`
Sets a shutdown flag and returns HTTP 200 when `ALLOW_SHUTDOWN` is enabled.

## Execution Flow
1. Validate request parameters (reject non-identity content-encoding and oversized bodies).
2. Prepare the request's inputs in the language directory (`check/` or `lib/`):
   - `solution_text` → language-specific filename (e.g. `solution.py`, `Solution.java`).
   - `checker_text` (if provided) → language-specific checker file.
   - `asserts` (if provided) → `asserts.json`.
3. Build the workspace. In the Linux sandbox (root) it is an overlay at `/sandbox`: the runner's working dir is the read-only lower layer, and the inputs plus all writes live in a per-request tmpfs, so nothing is copied. Without root, the working dir is copied into a temp dir under `/tmp` instead.
4. Execute the test command resolved from `make -n test` via `sh -c` in the workspace.
5. Enforce timeout; on expiration, terminate the process group.
6. Capture `stdout` and `stderr`; if either stream exceeds 1MB, return an error.

## Files and Layout Expectations
The service runs `make test` in its working directory. That directory is expected to contain language-specific runner logic. The service writes files into a subdirectory:
- `check/` for most languages
- `lib/` for Dart

## Language File Rules
For each request, the service writes the solution and (if required) checker files into the language directory (`check/` or `lib/`). It then runs `make test`, which is responsible for compiling/executing the solution and checker for that language.

Filename mapping and checker requirement:
- `clojure`: `solution.clj` (no checker)
- `cpp`: `solution.cpp` + `checker.cpp` (checker required)
- `csharp`: `Solution.cs` + `Checker.cs` (checker required)
- `dart`: `solution.dart` + `checker.dart` (checker required)
- `elixir`: `solution.exs` (no checker)
- `golang`: `solution.go` + `checker.go` (checker required)
- `haskell`: `Solution.hs` + `Checker.hs` (checker required)
- `java`: `Solution.java` + `Checker.java` (checker required)
- `js`: `solution.js` (no checker)
- `kotlin`: `solution.kt` + `checker.kt` (checker required)
- `php`: `solution.php` (no checker)
- `python`: `solution.py` (no checker)
- `ruby`: `solution.rb` (no checker)
- `rust`: `solution.rs` + `checker.rs` (checker required)
- `swift`: `solution.swift` + `checker.swift` (checker required)
- `zig`: `solution.zig` + `checker.zig` (checker required)
- `ts`: `solution.js` (no checker)

## Configuration
Environment variables:
- `PORT` (default `4040`): Listener port.
- `ALLOW_SHUTDOWN` (default `false`): Enable the `/shutdown` endpoint when set to `1` or `true`.
- `RUN_CONCURRENCY` (default `10`): Max concurrent `/run` handlers; requests return 429 when busy.
- `RUN_INPUT_MAX` (default `1048576` bytes): Max request body size.
- `RUN_OUTPUT_MAX` (default `1048576` bytes): Max bytes allowed per stream (0 disables the limit).
- `DEBUG` (default `false`): Enable request header logging; empty value enables it too.
- `RUN_UID_BASE` (default `10001`): Per-slot run UID is `RUN_UID_BASE + slot_index`.
- `RUN_ENV_ALLOW` (default empty): Comma-separated list of additional env keys to forward to user code. The baseline allowlist is `PATH`, `LANG`, `LC_ALL`, `TZ`; `HOME` is always force-set to `/sandbox`. Anything not on either list is dropped, so operator secrets in env never reach the sandbox.
- `RUN_MEMORY_MAX` (default `0` = disabled): If non-zero, applies `RLIMIT_AS` (bytes) to user code. Opt-in because JVM/.NET/Go reserve enormous virtual address space upfront. The per-request cgroup `memory.max` (below) is the real memory limit.
- `RUN_TMP_SIZE_<UPPER_SLUG>` / `RUN_SANDBOX_TMP_SIZE` (per-lang override > global fallback): `size=` of the per-request tmpfs, e.g. `RUN_TMP_SIZE_CSHARP=2g`. It caps **everything** a request writes: `/tmp`, the workspace's writable layer, and the cache overlays.
- `RUN_MEM_MAX_<UPPER_SLUG>` / `RUN_SANDBOX_MEM_MAX` (per-lang override > global fallback): cgroup `memory.max` for one run, e.g. `RUN_MEM_MAX_JAVA=1g`. tmpfs writes count towards it. Exceeding it kills the run and appends `runner: killed: memory limit (...) exceeded` to stderr.
- `RUN_OVERLAY_PATHS_<UPPER_SLUG>` (comma-separated absolute paths): image directories the toolchain must write to at run time (build caches). Each gets a per-request copy-on-write overlay, so the pre-warmed contents are shared read-only and the writes stay private to the request. Replaces the per-lang default list. Missing paths are skipped.
- Per-lang defaults are baked into `all_langs` in `src/main.zig`:

  | lang | tmp size | memory.max | cache overlays |
  |---|---|---|---|
  | python | 256m | 512m | |
  | js, ts, ruby, php | 64m | 512m | |
  | elixir | 128m | 512m | |
  | clojure | 256m | 512m | |
  | cpp | 512m | 1g | |
  | zig | 128m | 1g | |
  | dlang | 256m | 768m | |
  | rust | 512m | 1g | `/opt/cargo`, `/opt/cargo-target` |
  | swift, haskell | 256m | 1g | |
  | golang | 512m | 1g | `/opt/go/cache`, `/opt/go/mod` |
  | dart | 128m | 768m | |
  | java | 256m | 768m | |
  | kotlin | 256m | 1g | |
  | csharp | 1g | 1536m | |

## Timeout Rules
`timeout` accepts a string with units: `ms`, `s`, or `m` (defaults to `30s` when omitted).

## Payload Limits
- Request body limit: `RUN_INPUT_MAX` (HTTP 413 on overflow).
- Output limit: `RUN_OUTPUT_MAX` per stream (HTTP 413 when exceeded).

## Isolation and Safety
On Linux when running as root (the production deployment), each `/run` request runs in a fresh sandbox, implemented in `src/sandbox.zig`. Every setup step fails closed: if the runner cannot build the sandbox at startup it refuses to start, and if a per-request step fails, user code never runs (stderr shows `sandbox: <step> errno=N`).

**Requirements.** Linux ≥ 5.12 (`mount_setattr`; `clone3` + `CLONE_INTO_CGROUP` needs 5.7), cgroup v2 with the `memory` and `pids` controllers, and a container with `CAP_SYS_ADMIN`, unconfined AppArmor and seccomp (the k8s chart runs privileged, which covers all of this). `scripts/isolation_test.py` checks all of the guarantees below against a running container and runs in `make test-integration`.

**Startup (once).**
- A root-only (0700) tmpfs at `/run/codebattle-runner` holds the workspace *skeleton* (every directory of the working dir, recreated empty with mode 0777) and a private cgroup2 mount.
- cgroups: the runner moves itself into `runner/`. One cgroup per slot is created under `jobs/`, with `memory.swap.max=0`, `pids.max=512` and `memory.oom.group=1`. When the container has a memory limit, `jobs/` is capped 64 MiB below it, so user code can never OOM-kill the runner.

**Per request.** The parent writes the language's `memory.max` into the slot cgroup. It then forks with `clone3(CLONE_INTO_CGROUP)`, so the child starts inside its cgroup; migrating via `cgroup.procs` costs an RCU grace period, ~20 ms. The outer child sets `oom_score_adj=1000` and unshares mount, PID, IPC, UTS, network and cgroup namespaces. It sets mount propagation private, builds the mount view below, then forks the inner child that becomes user code. The outer child (PID 1 of the namespace) stays root only to `waitpid`. When it exits, the kernel kills everything left in the PID namespace.

**Mount view (per request, ~20 mount syscalls, ~0.1 ms):**
1. `mount_setattr(/, AT_RECURSIVE, RDONLY|NOSUID)`: the entire inherited filesystem becomes read-only. This includes the template working dir, `/var/tmp`, every 0777 dir baked into the image, and the shared Go/Cargo caches.
2. A fresh tmpfs on `/tmp` with the per-lang `size=`. A root-only `/tmp/.runner` inside it holds the overlay layers, so this single size cap bounds every write.
3. The request inputs are written into the workspace's upper layer.
4. `/sandbox` = overlay with layers inputs/writes (upper) : skeleton : working dir. The skeleton makes template directories writable for the slot UID, exactly like the old per-request copy did, while file contents are served from the read-only template. Renaming a template *directory* returns `EXDEV`, and tools fall back to copying.
5. Per-lang cache overlays (`RUN_OVERLAY_PATHS_*`). For example, `GOCACHE` stays pre-warmed but the request's writes are private: no cross-request cache poisoning.
6. A minimal `/dev`: tmpfs with bind mounts of `null`, `zero`, `full`, `random`, `urandom`, the `fd`/`stdin`/`stdout`/`stderr` symlinks, and a fresh 64m `/dev/shm`. Host devices exposed to a privileged pod never reach user code.
7. Empty read-only tmpfs over `/app`, `/run/secrets`, `/var/run/secrets` (k8s service-account token) and the runner's state dir.
8. A fresh `/proc` for the new PID namespace.
9. `cgroup2` at `/sys/fs/cgroup`, rooted at the slot cgroup. JVM, .NET, Go and BEAM therefore size themselves from the request's own `memory.max`.

There is nothing to clean up afterwards: every mount, including the tmpfs holding all writes, disappears with the mount namespace.

**Privilege drop (inner child, fail-closed).** `setgroups([])` (otherwise root's supplementary groups such as `disk` and `adm` would leak), `setresgid`/`setresuid` to `RUN_UID_BASE + slot`, a check that no root id remains, `PR_SET_NO_NEW_PRIVS`, then `close_range(3, ~0)` so no inherited fd reaches user code. All of the runner's own fds are `O_CLOEXEC` as well.

**Environment.** Only an explicit allowlist of keys is passed to `execve` (see `RUN_ENV_ALLOW` above). Operator-injected secrets like `DB_PASSWORD` or `API_KEY` never reach user code. `HOME` is force-set to `/sandbox`.

**Seccomp-bpf.** Installed last, before `execve`:
- Arch audit: any non-native syscall ABI is killed. On x86_64, x32 syscalls (`nr & 0x40000000`) are killed too, because they would otherwise bypass the per-number denylist.
- `SECCOMP_RET_KILL_PROCESS` for container-escape / kernel-manipulation primitives:
  - `mount`, `umount2`, `pivot_root`, `chroot`, `unshare`, `setns`, `seccomp`, `bpf`
  - `keyctl`, `add_key`, `request_key`
  - `init_module`, `finit_module`, `delete_module`, `kexec_load`, `kexec_file_load`
  - `swapon`, `swapoff`, `reboot`, `acct`, `quotactl`, `quotactl_fd`, `perf_event_open`
  - `ptrace`, `process_vm_readv`, `process_vm_writev`, `process_madvise`, `pidfd_getfd`, `kcmp`, `userfaultfd`
  - `iopl`, `ioperm`, `name_to_handle_at`, `open_by_handle_at`, `lookup_dcookie`, `nfsservctl`, `personality`, `uselib`, `vhangup`
  - the new mount API: `open_tree`, `open_tree_attr`, `move_mount`, `fsopen`, `fsconfig`, `fsmount`, `fspick`, `mount_setattr`
- `clone(2)` with any `CLONE_NEW*` flag → `EPERM`. This stops user code from creating user namespaces, the usual entry point for kernel privilege escalation.
- `clone3` → `ENOSYS`. Its flags can't be inspected, and libc/Go/JVM fall back to `clone(2)`.
- `io_uring_*` → `EPERM`. Node 25's libuv probes io_uring at init and falls back to epoll; KILL would SIGSYS it.

**Rlimits (inner child).** `RLIMIT_CPU` = timeout, `RLIMIT_NOFILE` 256, `RLIMIT_NPROC` 256, `RLIMIT_CORE` 0, and `RLIMIT_AS` only if `RUN_MEMORY_MAX` is set.

**Cross-request guarantee.** Concurrent requests run as different UIDs in separate namespaces. Each request sees only its own `/tmp`, `/dev/shm`, workspace upper layer and cache upper layers. Everything shared (the template, images, caches) is read-only. Nothing a request writes survives it. One request cannot starve another of memory or PIDs, and it gets at most a fair share of CPU under contention, since every slot cgroup has equal `cpu.weight`.

**Out of scope for the runner itself** (handled at deploy/infra layer):
- Kernel-escape isolation: all requests share the host kernel. A kernel 0-day reachable through the allowed syscalls is the remaining risk; gVisor / Kata / Firecracker at the pod level closes it.
- Hardware side channels (Spectre-class) between co-located requests.
- Host-level CPU isolation / dedicated worker nodes.
- Egress firewalling (the runner unshares netns as defense in depth, but the pod should still block egress).

## Runtime Notes
- The service is stateless. In the Linux sandbox, a request's workspace exists only inside its mount namespace and vanishes with it. In the unsandboxed fallback, a temp copy is deleted by a background thread after the response is sent.
