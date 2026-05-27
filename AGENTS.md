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
  - `clojure`, `cpp`, `csharp`, `dart`, `elixir`, `golang`, `haskell`, `java`, `js`, `kotlin`, `php`, `python`, `ruby`, `rust`, `swift`, `ts`, `zig`
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
2. Create a temporary directory under `/tmp` and copy the current workspace into it.
3. Write input files into a language-specific working directory:
   - `solution_text` → language-specific filename (e.g. `solution.py`, `Solution.java`).
   - `checker_text` (if provided) → language-specific checker file.
   - `asserts` (if provided) → `asserts.json`.
4. Execute the test command resolved from `make -n test` via `sh -c` in the temp workspace.
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
- `RUN_MEMORY_MAX` (default `0` = disabled): If non-zero, applies `RLIMIT_AS` (bytes) to user code. Opt-in because JVM/.NET/Go reserve enormous virtual address space upfront. Prefer the container's memory cgroup over `RLIMIT_AS` when possible.
- `RUN_TMP_SIZE_<UPPER_SLUG>` (no default; per-lang override): `size=` for the per-request /tmp tmpfs for a specific language, e.g. `RUN_TMP_SIZE_CSHARP=2g`, `RUN_TMP_SIZE_JAVA=256m`. Highest precedence.
- `RUN_SANDBOX_TMP_SIZE` (no default; global fallback): `size=` applied to every lang that doesn't have its own `RUN_TMP_SIZE_<SLUG>` override.
- Per-lang defaults (when neither env above is set) are baked into `all_langs` in `src/main.zig`. Current values:
  - **Popular langs (generous):** python 256m, cpp 512m, golang 512m, java 256m.
  - Other interpreted (js, ts, ruby, php): 64m.
  - Other native (zig, dart): 128m. JVM family (kotlin, clojure) and Rust/Swift/Haskell/Elixir: 256m.
  - csharp: 1g.

## Timeout Rules
`timeout` accepts a string with units: `ms`, `s`, or `m` (defaults to `30s` when omitted).

## Payload Limits
- Request body limit: `RUN_INPUT_MAX` (HTTP 413 on overflow).
- Output limit: `RUN_OUTPUT_MAX` per stream (HTTP 413 when exceeded).

## Isolation and Safety
On Linux when running as root (the production deployment), each `/run` request is executed in a fresh sandbox:

**Namespaces (per request).** New PID, mount, IPC, UTS, and network namespaces via `unshare(2)`. Root mount propagation is set private. The new netns has no interfaces, so user code has no network even if a pod-level egress rule is misconfigured.

**Mount-namespace masking (per request, ~4 mount syscalls).** Performed in the outer child after `unshare`, before the inner fork. The runner mkdirs `/sandbox` and `/app` once at startup (idempotent — EEXIST OK), so the bind/tmpfs targets exist even when the binary is dropped into a foreign base image (e.g. runner-python's `python:alpine`):
- `/tmp/runner-N-XXX` (the per-request workspace) is bind-mounted to `/sandbox`. The inner child `chdir`s to `/sandbox`, so the original `/tmp/...` path becomes irrelevant.
- `tmpfs` is mounted over `/tmp` (`MS_NOSUID | MS_NODEV`, per-lang `size=` resolved from `RUN_TMP_SIZE_<SLUG>` env > `RUN_SANDBOX_TMP_SIZE` env > per-lang code default in `all_langs`). This hides every other slot's workspace and side-steps the async-cleanup window — even if the previous request's `/tmp/runner-N-YYY` hasn't been deleted yet, it's invisible in this namespace. The size cap bounds how much RAM a single request can pin via /tmp writes; the budget is calibrated per-lang because (e.g.) dotnet builds need ~1g of intermediate state while a Python solution needs only a few MB.
- `tmpfs` (RO, empty) is mounted over `/app`. Hides the runner's own source from user code without affecting the runner process itself.
- Fresh `procfs` is mounted on `/proc` (`MS_NOSUID | MS_NODEV | MS_NOEXEC`). Required because the new PID namespace would otherwise still expose the host's procfs view via the inherited mount.

**Privilege drop.** The inner child does `setgid` + `setuid` to `RUN_UID_BASE + slot` (default 10001+N), then `PR_SET_NO_NEW_PRIVS`. The outer (PID 1 of the new pid_ns) stays as root only long enough to `waitpid` the inner child.

**Environment.** Only an explicit allowlist of keys is passed to `execve` (see `RUN_ENV_ALLOW` above). Operator-injected secrets like `DB_PASSWORD` or `API_KEY` never reach user code. `HOME` is force-set to `/sandbox`.

**Seccomp-bpf denylist.** Installed in the inner child after `PR_SET_NO_NEW_PRIVS` and before `execve`. Two verdicts:
- `SECCOMP_RET_KILL_PROCESS` (drop the process) for the container-escape / kernel-manipulation primitives: `mount`, `umount2`, `pivot_root`, `chroot`, `unshare`, `setns`, `seccomp`, `bpf`, `keyctl`, `add_key`, `request_key`, `init_module`, `finit_module`, `delete_module`, `kexec_load`, `kexec_file_load`, `swapon`, `swapoff`, `reboot`, `acct`, `quotactl`, `perf_event_open`, `ptrace`, `process_vm_readv`, `process_vm_writev`, `kcmp`, `userfaultfd`, `iopl`, `ioperm`, `name_to_handle_at`, `open_by_handle_at`, `lookup_dcookie`, `nfsservctl`, `personality`.
- `SECCOMP_RET_ERRNO=EPERM` (fail the syscall, keep the process) for `io_uring_setup`, `io_uring_enter`, `io_uring_register`. Modern runtimes (e.g. Node 25's libuv 1.51) probe io_uring at init and fall back to epoll on EPERM; a KILL_PROCESS verdict here silently SIGSYS-kills them before the fallback runs. EPERM still prevents user code from using io_uring as a seccomp-bypass primitive, so the security property is preserved.

Filter starts with an arch audit that kills the process on any non-native syscall ABI (blocks 32-bit-compat ABI-confusion attacks).

**Rlimits applied in the inner child:**
- `RLIMIT_CPU`: equals the request timeout (rounded up to whole seconds).
- `RLIMIT_NOFILE`: 256 open files.
- `RLIMIT_NPROC`: 256 processes/threads.
- `RLIMIT_CORE`: 0 (no core dumps).
- `RLIMIT_AS`: only if `RUN_MEMORY_MAX` is set; otherwise rely on the container's memory cgroup.

**Cross-tenant guarantee.** Two requests cannot read each other's workspaces because (a) different slots run as different UIDs and per-slot temp dirs are mode 0700, and (b) the per-request mount-ns tmpfs over `/tmp` makes other slots' workspace paths invisible regardless of UID. Background cleanup race is not exploitable.

**Out of scope for the runner itself** (handled at deploy/infra layer):
- Memory limits via cgroup v2 (`memory.max`).
- Kernel-escape isolation (Firecracker / gVisor / Kata).
- Host-level CPU isolation / dedicated worker nodes.
- Egress firewalling (the runner unshares netns as defense in depth, but the pod should still block egress).

## Runtime Notes
- The service is stateless; each request creates a fresh temp workspace and cleans it up after execution.
