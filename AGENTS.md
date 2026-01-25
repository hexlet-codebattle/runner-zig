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

## Timeout Rules
`timeout` accepts a string with units: `ms`, `s`, or `m` (defaults to `30s` when omitted).

## Payload Limits
- Request body limit: `RUN_INPUT_MAX` (HTTP 413 on overflow).
- Output limit: `RUN_OUTPUT_MAX` per stream (HTTP 413 when exceeded).

## Isolation and Safety
- The execution occurs in a temporary directory under `/tmp` built by copying the current workspace.
- The service runs commands in a separate process group for reliable termination.

## Runtime Notes
- The service is stateless; each request creates a fresh temp workspace and cleans it up after execution.
